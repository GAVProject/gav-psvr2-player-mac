/*
 * Чтение поз PSVR2 через libusb. Протокол задокументирован в драйвере
 * Monado (BSL-1.0): src/xrt/drivers/psvr2.
 */
#include "cpsvr2.h"

#include <libusb.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

#define SLAM_INTERFACE 3
#define SLAM_ENDPOINT 0x83
#define STATUS_INTERFACE 7
#define STATUS_ENDPOINT 0x88

#define GYRO_SCALE (2000.0f / 32767.0f)
#define DEG_TO_RAD(d) ((d) * (float)M_PI / 180.0f)

#pragma pack(push, 1)
struct imu_usb_record {
	uint32_t vts_us;
	int16_t accel[3];
	int16_t gyro[3];
	uint16_t dp_frame_cnt;
	uint16_t dp_line_cnt;
	uint16_t imu_ts_us;
	uint16_t status;
};

struct status_record_hdr {
	uint8_t dprx_status;
	uint8_t prox_sensor_flag;
	uint8_t function_button;
	uint8_t empty0[2];
	uint8_t ipd_dial_mm;
	uint8_t remainder[26];
};

struct slam_usb_record {
	char hdr[3];
	uint8_t const1;
	uint32_t pkt_size;
	uint32_t vts_ts_us;
	uint32_t unknown1;
	float pos[3];
	float orient[4];
	uint8_t remainder[468];
};

struct sie_ctrl_pkt {
	uint16_t report_id;
	uint16_t subcmd;
	uint32_t len;
	uint8_t data[512 - 8];
};
#pragma pack(pop)

static libusb_context *g_ctx;
static libusb_device_handle *g_dev;
static pthread_t g_slam_thread, g_status_thread;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_running;
static int g_have_pose;
static float g_quat[4];
static float g_pos[3];
static float g_gyro[3];
static double g_slam_time;
static uint32_t g_slam_vts;
static double g_imu_time;
static int g_proximity;
static int g_function_button;
static int g_ipd_mm = 63;

/* Кольцевой буфер IMU: ~130 мс истории при 2000 Гц */
#define IMU_RING_SIZE 256
#define IMU_DT 0.0005f
struct imu_sample {
	uint32_t vts_us;
	float gyro[3];
};
static struct imu_sample g_imu_ring[IMU_RING_SIZE];
static int g_imu_head; /* индекс следующей записи */
static int g_imu_count;

/* Кватернионы в порядке w,x,y,z */
static void quat_mul(const float a[4], const float b[4], float out[4])
{
	float w = a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3];
	float x = a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2];
	float y = a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1];
	float z = a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0];
	out[0] = w;
	out[1] = x;
	out[2] = y;
	out[3] = z;
}

/* Поворот на вектор угловой скорости за dt (экспонента кватерниона) */
static void quat_from_gyro(const float gyro[3], float dt, float out[4])
{
	float hx = gyro[0] * dt * 0.5f;
	float hy = gyro[1] * dt * 0.5f;
	float hz = gyro[2] * dt * 0.5f;
	float angle = sqrtf(hx * hx + hy * hy + hz * hz);
	if (angle < 1e-9f) {
		out[0] = 1.0f;
		out[1] = hx;
		out[2] = hy;
		out[3] = hz;
		return;
	}
	float s = sinf(angle) / angle;
	out[0] = cosf(angle);
	out[1] = hx * s;
	out[2] = hy * s;
	out[3] = hz * s;
}

static double monotonic_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void *slam_thread_fn(void *arg)
{
	(void)arg;
	uint8_t buf[1024];

	while (g_running) {
		int transferred = 0;
		int ret = libusb_bulk_transfer(g_dev, SLAM_ENDPOINT, buf, sizeof(buf), &transferred, 500);
		if (ret == LIBUSB_ERROR_TIMEOUT) {
			continue;
		}
		if (ret != 0) {
			if (g_running) {
				fprintf(stderr, "psvr2: slam read error: %s\n", libusb_error_name(ret));
			}
			break;
		}
		if (transferred < (int)sizeof(struct slam_usb_record)) {
			continue;
		}

		struct slam_usb_record rec;
		memcpy(&rec, buf, sizeof(rec));

		pthread_mutex_lock(&g_lock);
		/* Непрерывность кватерниона: выбираем ближайший из q/-q */
		float dot = g_quat[0] * rec.orient[0] + g_quat[1] * rec.orient[1] +
		            g_quat[2] * rec.orient[2] + g_quat[3] * rec.orient[3];
		float sign = (g_have_pose && dot < 0.0f) ? -1.0f : 1.0f;
		for (int i = 0; i < 4; i++) {
			g_quat[i] = sign * rec.orient[i];
		}
		memcpy(g_pos, rec.pos, sizeof(g_pos));
		g_slam_time = monotonic_s();
		g_slam_vts = rec.vts_ts_us;
		g_have_pose = 1;
		pthread_mutex_unlock(&g_lock);
	}
	return NULL;
}

static void *status_thread_fn(void *arg)
{
	(void)arg;
	uint8_t buf[1024];

	while (g_running) {
		int transferred = 0;
		int ret = libusb_interrupt_transfer(g_dev, STATUS_ENDPOINT, buf, sizeof(buf), &transferred, 500);
		if (ret == LIBUSB_ERROR_TIMEOUT) {
			continue;
		}
		if (ret != 0) {
			break;
		}
		if (transferred < (int)sizeof(struct status_record_hdr)) {
			continue;
		}
		struct status_record_hdr *hdr = (struct status_record_hdr *)buf;

		int n_imu = (transferred - (int)sizeof(*hdr)) / (int)sizeof(struct imu_usb_record);

		pthread_mutex_lock(&g_lock);
		g_proximity = hdr->prox_sensor_flag;
		g_function_button = hdr->function_button;
		g_ipd_mm = hdr->ipd_dial_mm;
		for (int i = 0; i < n_imu; i++) {
			struct imu_usb_record imu;
			memcpy(&imu, buf + sizeof(*hdr) + i * sizeof(imu), sizeof(imu));

			/* Маппинг осей как в Monado process_imu_record */
			struct imu_sample *s = &g_imu_ring[g_imu_head];
			s->vts_us = imu.vts_us;
			s->gyro[0] = -DEG_TO_RAD(imu.gyro[1] * GYRO_SCALE);
			s->gyro[1] = DEG_TO_RAD(imu.gyro[2] * GYRO_SCALE);
			s->gyro[2] = -DEG_TO_RAD(imu.gyro[0] * GYRO_SCALE);
			memcpy(g_gyro, s->gyro, sizeof(g_gyro));

			g_imu_head = (g_imu_head + 1) % IMU_RING_SIZE;
			if (g_imu_count < IMU_RING_SIZE) {
				g_imu_count++;
			}
		}
		if (n_imu > 0) {
			g_imu_time = monotonic_s();
		}
		pthread_mutex_unlock(&g_lock);
	}
	return NULL;
}

static int get_control(uint16_t report_id, uint8_t subcmd, uint8_t *out, uint32_t size)
{
	struct sie_ctrl_pkt pkt = {0};
	pkt.report_id = report_id;
	pkt.subcmd = subcmd;
	pkt.len = size;

	int ret = libusb_control_transfer(g_dev,
	    LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_ENDPOINT | LIBUSB_ENDPOINT_IN,
	    0x1, report_id, 0x0, (unsigned char *)&pkt, size + 8, 1000);
	if (ret < 0) {
		return ret;
	}
	memcpy(out, pkt.data, size);
	return 0;
}

static int send_control(uint16_t report_id, uint8_t subcmd, const uint8_t *data, uint32_t len)
{
	struct sie_ctrl_pkt pkt = {0};
	pkt.report_id = report_id;
	pkt.subcmd = subcmd;
	pkt.len = len;
	memcpy(pkt.data, data, len);

	int ret = libusb_control_transfer(g_dev,
	    LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_ENDPOINT,
	    0x9, report_id, 0x0, (unsigned char *)&pkt, len + 8, 1000);
	return ret < 0 ? ret : 0;
}

int psvr2_set_brightness(float brightness)
{
	if (g_dev == NULL) {
		return -1;
	}
	if (brightness < 0.0f) brightness = 0.0f;
	if (brightness > 1.0f) brightness = 1.0f;
	uint8_t b = (uint8_t)(brightness * 31.0f);
	return send_control(0x12, 1, &b, 1);
}

int psvr2_get_distortion_calibration(float out[8])
{
	memset(out, 0, 8 * sizeof(float));
	if (g_dev == NULL) {
		return -1;
	}

	uint8_t buf[0x100];
	if (get_control(0x8f, 1, buf, sizeof(buf)) != 0) {
		return -1;
	}

	uint8_t version = buf[0];
	float p[8];
	memcpy(p, buf + 8, sizeof(p));

	/* Преобразование из psvr2_setup_distortion_and_fovs (Monado) */
	if (version < 4) {
		out[0] = -0.09919293f;
		out[2] = 0.09919293f;
	} else {
		out[0] = (((-p[0] - p[6]) * 29.9f + 14.95f) / 1000.0f - 3.22f) / 32.46199f;
		out[1] = (((-p[1] * 29.9f) + 14.95f) / 1000.0f) / 32.46199f;
		out[2] = (((p[6] - p[2]) * 29.9f + 14.95f) / 1000.0f + 3.22f) / 32.46199f;
		out[3] = (((-p[3] * 29.9f) + 14.95f) / 1000.0f) / 32.46199f;

		float left = -p[4] * (float)M_PI / 180.0f;
		out[4] = cosf(left);
		out[5] = sinf(left);

		float right = -p[5] * (float)M_PI / 180.0f;
		out[6] = cosf(right);
		out[7] = sinf(right);
	}
	return 0;
}

int psvr2_start(void)
{
	if (g_running) {
		return 0;
	}

	int ret = libusb_init(&g_ctx);
	if (ret < 0) {
		fprintf(stderr, "psvr2: libusb_init: %s\n", libusb_error_name(ret));
		return -1;
	}

	g_dev = libusb_open_device_with_vid_pid(g_ctx, PSVR2_VID, PSVR2_PID);
	if (g_dev == NULL) {
		fprintf(stderr, "psvr2: устройство %04x:%04x не найдено\n", PSVR2_VID, PSVR2_PID);
		libusb_exit(g_ctx);
		g_ctx = NULL;
		return -1;
	}

	ret = libusb_claim_interface(g_dev, STATUS_INTERFACE);
	if (ret == 0) {
		ret = libusb_set_interface_alt_setting(g_dev, STATUS_INTERFACE, 1);
	}
	if (ret == 0) {
		ret = libusb_claim_interface(g_dev, SLAM_INTERFACE);
	}
	if (ret != 0) {
		fprintf(stderr, "psvr2: не удалось захватить интерфейсы: %s\n", libusb_error_name(ret));
		libusb_close(g_dev);
		g_dev = NULL;
		libusb_exit(g_ctx);
		g_ctx = NULL;
		return -1;
	}

	g_have_pose = 0;
	g_running = 1;
	pthread_create(&g_slam_thread, NULL, slam_thread_fn, NULL);
	pthread_create(&g_status_thread, NULL, status_thread_fn, NULL);
	return 0;
}

void psvr2_stop(void)
{
	if (!g_running) {
		return;
	}
	g_running = 0;
	pthread_join(g_slam_thread, NULL);
	pthread_join(g_status_thread, NULL);
	libusb_release_interface(g_dev, SLAM_INTERFACE);
	libusb_release_interface(g_dev, STATUS_INTERFACE);
	libusb_close(g_dev);
	g_dev = NULL;
	libusb_exit(g_ctx);
	g_ctx = NULL;
}

int psvr2_connected(void)
{
	return g_running && g_have_pose;
}

int psvr2_get_pose(float quat_wxyz[4], float pos_xyz[3])
{
	pthread_mutex_lock(&g_lock);
	memcpy(quat_wxyz, g_quat, sizeof(g_quat));
	memcpy(pos_xyz, g_pos, sizeof(g_pos));
	int have = g_have_pose;
	pthread_mutex_unlock(&g_lock);
	return have;
}

int psvr2_get_status(int *proximity, int *ipd_mm)
{
	pthread_mutex_lock(&g_lock);
	*proximity = g_proximity;
	*ipd_mm = g_ipd_mm;
	pthread_mutex_unlock(&g_lock);
	return 0;
}

int psvr2_get_motion(float gyro_radps[3], double *slam_age_s)
{
	pthread_mutex_lock(&g_lock);
	memcpy(gyro_radps, g_gyro, sizeof(g_gyro));
	*slam_age_s = g_have_pose ? monotonic_s() - g_slam_time : 0.0;
	int have = g_have_pose;
	pthread_mutex_unlock(&g_lock);
	return have;
}

int psvr2_get_predicted_quat(float lookahead_s, float out_wxyz[4])
{
	pthread_mutex_lock(&g_lock);
	if (!g_have_pose) {
		pthread_mutex_unlock(&g_lock);
		return 0;
	}

	/* Интегрируем IMU-сэмплы новее SLAM-позы (общая шкала VTS, мкс).
	 * Беззнаковое вычитание корректно при переполнении счётчика. */
	float delta[4] = {1, 0, 0, 0};
	int idx = (g_imu_head - g_imu_count + IMU_RING_SIZE) % IMU_RING_SIZE;
	for (int n = 0; n < g_imu_count; n++) {
		struct imu_sample *s = &g_imu_ring[idx];
		idx = (idx + 1) % IMU_RING_SIZE;
		if ((int32_t)(s->vts_us - g_slam_vts) <= 0) {
			continue;
		}
		float dq[4];
		quat_from_gyro(s->gyro, IMU_DT, dq);
		quat_mul(delta, dq, delta);
	}

	/* Остаток: от последнего IMU-сэмпла до текущего кадра + упреждение */
	double tail = monotonic_s() - g_imu_time + (double)lookahead_s;
	if (tail < 0.0) tail = 0.0;
	if (tail > 0.1) tail = 0.1;
	float dq[4];
	quat_from_gyro(g_gyro, (float)tail, dq);
	quat_mul(delta, dq, delta);

	/* Дельта интегрирована в осях Monado-маппинга — приводим SLAM-кватернион
	 * к тем же осям (как в process_slam_record) и лишь потом умножаем */
	float mapped[4] = {g_quat[0], -g_quat[2], -g_quat[1], g_quat[3]};
	quat_mul(mapped, delta, out_wxyz);

	float len = sqrtf(out_wxyz[0] * out_wxyz[0] + out_wxyz[1] * out_wxyz[1] +
	                  out_wxyz[2] * out_wxyz[2] + out_wxyz[3] * out_wxyz[3]);
	if (len > 1e-6f) {
		for (int i = 0; i < 4; i++) {
			out_wxyz[i] /= len;
		}
	}
	pthread_mutex_unlock(&g_lock);
	return 1;
}

int psvr2_get_button(void)
{
	pthread_mutex_lock(&g_lock);
	int b = g_function_button;
	pthread_mutex_unlock(&g_lock);
	return b;
}
