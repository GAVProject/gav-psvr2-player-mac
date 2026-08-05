/*
 * psvr2_gaze — проверка айтрекинга PSVR2 через PC-адаптер.
 *
 * Протокол из PSVR2Toolkit (BnuuySolutions, MIT):
 * https://github.com/BnuuySolutions/PSVR2Toolkit
 *   - поток взгляда: интерфейс 5, bulk IN 0x85, пакеты hmd2_gaze_status_t
 *     (0x148 байт, сигнатура 'G','S')
 *   - включение: vendor control 0x09, report_id 0x0C (повторять при таймауте:
 *     поток глохнет после смены DP-сигнала и выхода из passthrough)
 *
 * Калибровка (gaze_calibration_blob.bin) в Toolkit закрыта; без неё
 * направление взгляда может быть неточным, но валидность/моргание/зрачок
 * должны читаться.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE
#define GAZE_INTERFACE 5
#define GAZE_ENDPOINT 0x85

typedef struct { float x, y; } vec2_t;
typedef struct { float x, y, z; } vec3_t;

typedef struct {
	uint32_t is_gaze_origin_valid;
	vec3_t gaze_origin_mm;
	uint32_t is_gaze_dir_valid;
	vec3_t gaze_dir_norm;
	uint32_t is_pupil_dia_valid;
	float pupil_dia_mm;
	uint32_t is_pupil_pos_valid;
	vec2_t pupil_pos_in_sensor_area;
	uint32_t is_pos_guide_valid;
	vec2_t pos_guide;
	uint32_t is_blink_valid;
	uint32_t blink;
} wearable_eye_t;

typedef struct {
	int64_t timestamp;
	uint32_t frame_counter;
	wearable_eye_t left;
	wearable_eye_t right;
	uint32_t is_gaze_origin_combined_valid;
	vec3_t gaze_origin_combined_mm;
	uint32_t is_gaze_dir_combined_valid;
	vec3_t gaze_dir_combined_norm;
	uint32_t is_convergence_distance_valid;
} wearable_data_t;

typedef struct {
	int64_t timestamp;
	uint32_t frame_counter;
	uint32_t tracking_state;
	vec3_t gaze_dir_left_norm;
	vec3_t gaze_dir_right_norm;
	vec3_t gaze_dir_combined_norm;
	float convergence_distance_mm;
} foveated_gaze_t;

typedef struct {
	uint8_t magic[2];   /* 'G','S' */
	uint16_t version;
	uint32_t size;
	float exp_l, exp_r;
	uint32_t led_status;
	uint32_t exp_counter_l, exp_counter_r;
	uint32_t led_counter;
	int32_t dsp_return_code;
	vec3_t lens_left, lens_right;
	uint32_t user_calibration_id;
	vec3_t fr_gaze_origin;
	uint8_t enabled_eye;
	uint8_t motor_sequence;
	uint8_t motor_strength;
	wearable_data_t wearable;
	foveated_gaze_t foveated;
} gaze_status_t;

#pragma pack(push, 1)
struct control_payload {
	uint8_t report_id;
	uint8_t zero;
	uint16_t subcmd;
	uint16_t length;
	uint16_t zero2;
	uint8_t data[504];
};
#pragma pack(pop)

static volatile sig_atomic_t stop = 0;
static void on_sigint(int sig) { (void)sig; stop = 1; }

/* Включение потока взгляда: SET-вариант ControlCommand из Toolkit */
static int gaze_enable(libusb_device_handle *dev)
{
	struct control_payload p;
	memset(&p, 0, sizeof(p));
	p.report_id = 0x0C;
	p.subcmd = 1;
	p.length = 0;

	int ret = libusb_control_transfer(dev, 0x42, 0x09, 0, 0,
	                                  (unsigned char *)&p, 8, 1000);
	return ret < 0 ? ret : 0;
}

int main(void)
{
	signal(SIGINT, on_sigint);
	printf("Размер gaze_status_t: 0x%zx (ожидается 0x148)\n", sizeof(gaze_status_t));

	libusb_context *ctx = NULL;
	libusb_init(&ctx);
	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "PSVR2 не найден\n");
		return 1;
	}
	if (libusb_claim_interface(dev, GAZE_INTERFACE) != 0) {
		fprintf(stderr, "интерфейс %d занят (закрой плеер)\n", GAZE_INTERFACE);
		return 1;
	}

	int ret = gaze_enable(dev);
	printf("Команда включения взгляда: %s\n",
	       ret == 0 ? "отправлена" : libusb_error_name(ret));
	printf("Читаю поток (Ctrl+C для выхода)...\n\n");

	static uint8_t buf[4096];
	int packets = 0, gaze_packets = 0;
	while (!stop && packets < 400) {
		int transferred = 0;
		ret = libusb_bulk_transfer(dev, GAZE_ENDPOINT, buf, sizeof(buf), &transferred, 500);
		if (ret == LIBUSB_ERROR_TIMEOUT) {
			gaze_enable(dev); /* поток глохнет — переспрашиваем */
			continue;
		}
		if (ret != 0) {
			fprintf(stderr, "чтение: %s\n", libusb_error_name(ret));
			break;
		}
		packets++;
		if (transferred < (int)sizeof(gaze_status_t)) {
			if (packets < 4) {
				printf("пакет %d байт, первые: %02x %02x %02x %02x\n",
				       transferred, buf[0], buf[1], buf[2], buf[3]);
			}
			continue;
		}

		gaze_status_t *g = (gaze_status_t *)buf;
		if (g->magic[0] != 'G' || g->magic[1] != 'S') {
			if (packets < 4) {
				printf("не GS-пакет: %c%c (%d байт)\n", g->magic[0], g->magic[1], transferred);
			}
			continue;
		}
		gaze_packets++;
		if (gaze_packets % 30 != 1) {
			continue;
		}
		const wearable_eye_t *l = &g->wearable.left;
		const wearable_eye_t *r = &g->wearable.right;
		printf("кадр %u: взгляд L(%.3f, %.3f, %.3f)%s R(%.3f, %.3f, %.3f)%s\n",
		       g->wearable.frame_counter,
		       l->gaze_dir_norm.x, l->gaze_dir_norm.y, l->gaze_dir_norm.z,
		       l->is_gaze_dir_valid ? "" : " (невалид)",
		       r->gaze_dir_norm.x, r->gaze_dir_norm.y, r->gaze_dir_norm.z,
		       r->is_gaze_dir_valid ? "" : " (невалид)");
		printf("          зрачок L %.2f мм R %.2f мм · моргание L %d R %d · "
		       "общий (%.3f, %.3f, %.3f) · сведение %.0f мм\n",
		       l->pupil_dia_mm, r->pupil_dia_mm, l->blink, r->blink,
		       g->foveated.gaze_dir_combined_norm.x,
		       g->foveated.gaze_dir_combined_norm.y,
		       g->foveated.gaze_dir_combined_norm.z,
		       g->foveated.convergence_distance_mm);
	}

	printf("\nИтого: %d пакетов, из них GS-структур: %d\n", packets, gaze_packets);
	if (gaze_packets > 0) {
		printf("=== АЙТРЕКИНГ РАБОТАЕТ ===\n");
	} else {
		printf("=== Взгляд не пошёл: поток молчит или отдаёт другой формат ===\n");
	}

	libusb_release_interface(dev, GAZE_INTERFACE);
	libusb_close(dev);
	libusb_exit(ctx);
	return 0;
}
