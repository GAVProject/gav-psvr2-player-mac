/*
 * psvr2_probe — check USB access to the PSVR2 on macOS.
 *
 * Opens the headset (Sony 0x054C:0x0CDE) via libusb and reads:
 *  - firmware information (control request 0x81)
 *  - lens distortion calibration (control request 0x8f)
 *  - status: proximity sensor, Fn button, IPD, IMU (interrupt EP 0x88)
 *  - SLAM pose: position + quaternion computed on the headset (bulk EP 0x83)
 *
 * Protocol documented in the Monado driver (BSL-1.0):
 * https://gitlab.freedesktop.org/monado/monado, src/xrt/drivers/psvr2
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

#define SLAM_INTERFACE 3
#define SLAM_ENDPOINT 0x83
#define STATUS_INTERFACE 7
#define STATUS_ENDPOINT 0x88

#define GYRO_SCALE (2000.0 / 32767.0)
#define ACCEL_SCALE (4.0 * 9.80665 / 32767.0)

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
	char SLAhdr[3];
	uint8_t const1;
	uint32_t pkt_size;
	uint32_t vts_ts_us;
	uint32_t unknown1;
	float pos[3];
	float orient[4]; /* w, x, y, z in Monado order: orient[0]=w */
	uint8_t remainder[468];
};

struct sie_ctrl_pkt {
	uint16_t report_id;
	uint16_t subcmd;
	uint32_t len;
	uint8_t data[512 - 8];
};

struct pkt_firmware_info {
	uint32_t version;
	uint32_t reserved_0;
	uint8_t commit_hash[40];
	uint32_t unknown_0;
	uint32_t unknown_1;
	char pcb_id[16];
	uint32_t unknown_2;
	uint32_t reserved_1;
	uint32_t recovery_version;
};
#pragma pack(pop)

static volatile sig_atomic_t stop = 0;
static void on_sigint(int sig) { (void)sig; stop = 1; }

static int get_control(libusb_device_handle *dev, uint16_t report_id, uint8_t subcmd,
                       uint8_t *out, uint32_t size)
{
	struct sie_ctrl_pkt pkt = {0};
	pkt.report_id = report_id;
	pkt.subcmd = subcmd;
	pkt.len = size;

	int ret = libusb_control_transfer(dev,
	    LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_ENDPOINT | LIBUSB_ENDPOINT_IN,
	    0x1, report_id, 0x0, (unsigned char *)&pkt, size + 8, 1000);
	if (ret < 0) {
		fprintf(stderr, "control get 0x%x failed: %s\n", report_id, libusb_error_name(ret));
		return ret;
	}
	memcpy(out, pkt.data, size);
	return 0;
}

int main(void)
{
	signal(SIGINT, on_sigint);

	libusb_context *ctx = NULL;
	int ret = libusb_init(&ctx);
	if (ret < 0) {
		fprintf(stderr, "libusb_init: %s\n", libusb_error_name(ret));
		return 1;
	}

	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "Failed to open PSVR2 (%04x:%04x). Is the adapter's USB plugged in?\n",
		        PSVR2_VID, PSVR2_PID);
		return 1;
	}
	printf("[ok] PSVR2 device opened\n");

	ret = libusb_claim_interface(dev, STATUS_INTERFACE);
	if (ret < 0) {
		fprintf(stderr, "claim status interface: %s\n", libusb_error_name(ret));
		return 1;
	}
	ret = libusb_set_interface_alt_setting(dev, STATUS_INTERFACE, 1);
	if (ret < 0) {
		fprintf(stderr, "status alt setting: %s\n", libusb_error_name(ret));
		return 1;
	}
	printf("[ok] Status interface (7, alt 1) claimed\n");

	ret = libusb_claim_interface(dev, SLAM_INTERFACE);
	if (ret < 0) {
		fprintf(stderr, "claim SLAM interface: %s\n", libusb_error_name(ret));
		return 1;
	}
	printf("[ok] SLAM interface (3) claimed\n");

	struct pkt_firmware_info fw;
	if (get_control(dev, 0x81, 0x1, (uint8_t *)&fw, sizeof(fw)) == 0) {
		printf("[ok] Firmware: %08x, PCB: %.16s\n", fw.version, fw.pcb_id);
	}

	uint8_t calib[0x100];
	if (get_control(dev, 0x8f, 0x1, calib, sizeof(calib)) == 0) {
		float params[8];
		memcpy(params, calib + 8, sizeof(params));
		printf("[ok] Calibration (version %u): offsets L(%.4f, %.4f) R(%.4f, %.4f)\n",
		       calib[0], params[0], params[1], params[2], params[3]);
		printf("       scale L(%.4f, %.4f) R(%.4f, %.4f)\n",
		       params[4], params[5], params[6], params[7]);
		FILE *f = fopen("psvr2_calibration.bin", "wb");
		if (f != NULL) {
			fwrite(calib, 1, sizeof(calib), f);
			fclose(f);
			printf("       Saved to psvr2_calibration.bin\n");
		}
	}

	printf("\nReading status and SLAM poses (Ctrl+C to exit)...\n\n");

	uint8_t status_buf[1024];
	uint8_t slam_buf[1024];
	int slam_count = 0, status_count = 0;

	while (!stop && slam_count < 40) {
		int transferred = 0;

		ret = libusb_interrupt_transfer(dev, STATUS_ENDPOINT, status_buf,
		                                sizeof(status_buf), &transferred, 500);
		if (ret == 0 && transferred >= (int)sizeof(struct status_record_hdr)) {
			struct status_record_hdr *hdr = (struct status_record_hdr *)status_buf;
			int n_imu = (transferred - (int)sizeof(*hdr)) / (int)sizeof(struct imu_usb_record);
			status_count++;
			if (status_count % 50 == 1) {
				printf("STATUS dprx=%u prox=%u btn=%u ipd=%umm imu_samples=%d",
				       hdr->dprx_status, hdr->prox_sensor_flag,
				       hdr->function_button, hdr->ipd_dial_mm, n_imu);
				if (n_imu > 0) {
					struct imu_usb_record imu;
					memcpy(&imu, status_buf + sizeof(*hdr), sizeof(imu));
					printf("  gyro=(%.1f, %.1f, %.1f)°/s accel=(%.2f, %.2f, %.2f)m/s²",
					       imu.gyro[0] * GYRO_SCALE, imu.gyro[1] * GYRO_SCALE,
					       imu.gyro[2] * GYRO_SCALE,
					       imu.accel[0] * ACCEL_SCALE, imu.accel[1] * ACCEL_SCALE,
					       imu.accel[2] * ACCEL_SCALE);
				}
				printf("\n");
			}
		} else if (ret != 0 && ret != LIBUSB_ERROR_TIMEOUT) {
			fprintf(stderr, "status read: %s\n", libusb_error_name(ret));
		}

		ret = libusb_bulk_transfer(dev, SLAM_ENDPOINT, slam_buf,
		                           sizeof(slam_buf), &transferred, 500);
		if (ret == 0 && transferred >= (int)sizeof(struct slam_usb_record)) {
			struct slam_usb_record slam;
			memcpy(&slam, slam_buf, sizeof(slam));
			slam_count++;
			printf("SLAM #%d hdr=%.3s ts=%uus pos=(%.3f, %.3f, %.3f) quat wxyz=(%.3f, %.3f, %.3f, %.3f)\n",
			       slam_count, slam.SLAhdr, slam.vts_ts_us,
			       slam.pos[0], slam.pos[1], slam.pos[2],
			       slam.orient[0], slam.orient[1], slam.orient[2], slam.orient[3]);
		} else if (ret != 0 && ret != LIBUSB_ERROR_TIMEOUT) {
			fprintf(stderr, "slam read: %s\n", libusb_error_name(ret));
		}
	}

	printf("\nTotal: %d status packets, %d SLAM poses\n", status_count, slam_count);
	if (slam_count > 0) {
		printf("=== TRACKING WORKS — ready to build the player ===\n");
	} else if (status_count > 0) {
		printf("=== Status is readable but SLAM is silent (headset may be off-head / no lighting) ===\n");
	}

	libusb_release_interface(dev, SLAM_INTERFACE);
	libusb_release_interface(dev, STATUS_INTERFACE);
	libusb_close(dev);
	libusb_exit(ctx);
	return 0;
}
