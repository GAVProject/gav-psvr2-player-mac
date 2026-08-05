/*
 * psvr2_dump — сырой дамп одного IN-эндпоинта PSVR2 в файл.
 * Использование: psvr2_dump <интерфейс> <эндпоинт hex> <секунды> <файл>
 * Пример: psvr2_dump 11 8c 3 /tmp/st.bin
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "psvr2_dump <intf> <ep_hex> <seconds> <outfile>\n");
		return 2;
	}
	int intf = atoi(argv[1]);
	int ep = (int)strtol(argv[2], NULL, 16) | LIBUSB_ENDPOINT_IN;
	double seconds = atof(argv[3]);

	libusb_context *ctx = NULL;
	libusb_init(&ctx);
	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "PSVR2 не найден\n");
		return 1;
	}
	if (libusb_claim_interface(dev, intf) != 0) {
		fprintf(stderr, "интерфейс %d занят\n", intf);
		return 1;
	}
	FILE *f = fopen(argv[4], "wb");
	if (f == NULL) {
		fprintf(stderr, "не открыть %s\n", argv[4]);
		return 1;
	}

	static uint8_t buf[262144];
	long long total = 0;
	int packets = 0;
	double t0 = now_s();
	while (now_s() - t0 < seconds) {
		int transferred = 0;
		int ret = libusb_bulk_transfer(dev, ep, buf, sizeof(buf), &transferred, 300);
		if (ret == LIBUSB_ERROR_TIMEOUT) {
			continue;
		}
		if (ret != 0) {
			fprintf(stderr, "чтение: %s\n", libusb_error_name(ret));
			break;
		}
		if (transferred > 0) {
			/* Маркер границы transfer'а: длина в файле-компаньоне */
			fprintf(stderr, "%d\n", transferred);
			fwrite(buf, 1, transferred, f);
			total += transferred;
			packets++;
		}
	}
	fclose(f);
	printf("%d transfers, %lld байт\n", packets, total);
	libusb_release_interface(dev, intf);
	libusb_close(dev);
	libusb_exit(ctx);
	return 0;
}
