/*
 * psvr2_camera — проверка доступа к камерам PSVR2 (passthrough) через
 * PC-адаптер и дамп кадров в файл.
 *
 * Протокол из PSVR2Toolkit (BnuuySolutions):
 * https://github.com/BnuuySolutions/PSVR2Toolkit
 *   - включение камер: vendor control 0x09, report_id 0x0B,
 *     данные {1,0,0,0, 0x10, 0,0,0} (0x05 вместо 0x10 — выключить)
 *   - кадры приходят пакетами с сигнатурой 'V','I': заголовок 256 байт
 *     (image_type 11 — passthrough BC4 1024x1016, 6 — картинка глаз)
 *
 * Ищем поток кадров перебором интерфейсов/эндпоинтов: на macOS номера
 * могут отличаться от Windows-драйвера Sony.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

/* Интерфейс/эндпоинт потока изображений: подбираются перебором */
static const struct { int intf; int ep; } candidates[] = {
	{4, 0x84}, {6, 0x87}, {10, 0x8b}, {12, 0x8d}, {8, 0x89}, {9, 0x8a}, {11, 0x8c},
};

#pragma pack(push, 1)
struct image_data_hdr {
	unsigned char magic[2]; /* 'V','I' */
	uint16_t version;
	uint32_t total_size;
	uint32_t timestamp;
	uint8_t unk0[4];
	uint16_t image_type; /* 11 — passthrough, 6 — изображение глаз */
	uint8_t unk1[22];
	uint32_t custom_data_size;
	uint8_t unk2[20];
	uint8_t unk3[192];
	/* дальше data[] */
};

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

static int camera_power(libusb_device_handle *dev, int on)
{
	struct control_payload p;
	memset(&p, 0, sizeof(p));
	p.report_id = 0x0B;
	p.subcmd = 1;
	p.length = 8;
	p.data[0] = 1;
	p.data[4] = on ? 0x10 : 0x05;

	int ret = libusb_control_transfer(dev, 0x42, 0x09, 0, 0,
	                                  (unsigned char *)&p, 8 + 8, 2000);
	return ret < 0 ? ret : 0;
}

int main(int argc, char **argv)
{
	signal(SIGINT, on_sigint);
	const char *outPath = argc > 1 ? argv[1] : NULL;

	libusb_context *ctx = NULL;
	libusb_init(&ctx);
	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "PSVR2 не найден\n");
		return 1;
	}

	int ret = camera_power(dev, 1);
	printf("Команда включения камер (0x0B): %s\n",
	       ret == 0 ? "отправлена" : libusb_error_name(ret));

	static uint8_t buf[1048576];
	int found = 0;

	for (size_t c = 0; c < sizeof(candidates) / sizeof(candidates[0]) && !stop; c++) {
		int intf = candidates[c].intf, ep = candidates[c].ep;
		if (libusb_claim_interface(dev, intf) != 0) {
			printf("intf %2d: занят\n", intf);
			continue;
		}

		int packets = 0, vi = 0;
		long long bytes = 0;
		uint16_t types = 0;
		for (int i = 0; i < 60 && !stop; i++) {
			int transferred = 0;
			ret = libusb_bulk_transfer(dev, ep, buf, sizeof(buf), &transferred, 300);
			if (ret != 0 || transferred <= 0) {
				continue;
			}
			packets++;
			bytes += transferred;
			if (transferred > (int)sizeof(struct image_data_hdr)) {
				struct image_data_hdr *h = (struct image_data_hdr *)buf;
				if (h->magic[0] == 'V' && h->magic[1] == 'I') {
					vi++;
					types = h->image_type;
					if (vi == 1) {
						printf("  >>> VI-кадр! тип %u, размер %u, ts %u, пакет %d байт\n",
						       h->image_type, h->total_size, h->timestamp, transferred);
						if (outPath != NULL) {
							FILE *f = fopen(outPath, "wb");
							if (f != NULL) {
								fwrite(buf, 1, transferred, f);
								fclose(f);
								printf("  >>> кадр сохранён в %s\n", outPath);
							}
						}
						found = 1;
					}
				}
			}
		}
		printf("intf %2d EP 0x%02x: %d пакетов, %lld байт, VI-кадров %d%s\n",
		       intf, ep, packets, bytes, vi,
		       vi ? "" : (packets ? " (другой формат)" : " (тишина)"));
		if (vi > 0) {
			printf("       последний image_type: %u\n", types);
		}
		libusb_release_interface(dev, intf);
	}

	printf("\n%s\n", found
	    ? "=== КАДРЫ КАМЕР ДОСТУПНЫ ==="
	    : "=== VI-кадров не найдено ===");

	camera_power(dev, 0);
	libusb_close(dev);
	libusb_exit(ctx);
	return 0;
}
