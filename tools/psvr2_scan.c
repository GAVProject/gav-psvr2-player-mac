/*
 * psvr2_scan — разведка USB-интерфейсов PSVR2 через PC-адаптер.
 *
 * Вопрос: отдаёт ли адаптер что-то кроме известного (SLAM на intf 3,
 * статус/IMU на intf 7) — например, потоки камер или айтрекинг.
 *
 * Печатает полный конфигурационный дескриптор (интерфейсы, альтернативные
 * настройки, эндпоинты с классами и именами), затем пытается захватить
 * каждый интерфейс и пассивно слушает каждый IN-эндпоинт пару секунд:
 * сколько пакетов, какого размера, первые байты.
 *
 * Запускать при закрытом плеере (иначе интерфейсы 3 и 7 заняты).
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

static const char *type_name(uint8_t attr)
{
	switch (attr & 0x3) {
	case LIBUSB_TRANSFER_TYPE_CONTROL: return "control";
	case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "isoc";
	case LIBUSB_TRANSFER_TYPE_BULK: return "bulk";
	case LIBUSB_TRANSFER_TYPE_INTERRUPT: return "interrupt";
	}
	return "?";
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void listen_endpoint(libusb_device_handle *dev,
                            const struct libusb_endpoint_descriptor *ep)
{
	uint8_t type = ep->bmAttributes & 0x3;
	if (!(ep->bEndpointAddress & LIBUSB_ENDPOINT_IN)) {
		return;
	}
	if (type == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) {
		printf("    EP 0x%02x isoc: пассивно не слушаем (нужен async API) — "
		       "но само наличие изохронного IN намекает на потоковые данные!\n",
		       ep->bEndpointAddress);
		return;
	}
	if (type != LIBUSB_TRANSFER_TYPE_BULK && type != LIBUSB_TRANSFER_TYPE_INTERRUPT) {
		return;
	}

	static uint8_t buf[262144];
	int packets = 0;
	long long bytes = 0;
	int first_len = 0;
	uint8_t first[32] = {0};
	int err = 0;

	double t0 = now_s();
	while (now_s() - t0 < 2.0) {
		int transferred = 0;
		int ret = (type == LIBUSB_TRANSFER_TYPE_BULK)
		    ? libusb_bulk_transfer(dev, ep->bEndpointAddress, buf, sizeof(buf),
		                           &transferred, 300)
		    : libusb_interrupt_transfer(dev, ep->bEndpointAddress, buf, sizeof(buf),
		                                &transferred, 300);
		if (ret == LIBUSB_ERROR_TIMEOUT) {
			continue;
		}
		if (ret != 0) {
			printf("    EP 0x%02x %s: ошибка чтения %s\n",
			       ep->bEndpointAddress, type_name(type), libusb_error_name(ret));
			err = 1;
			break;
		}
		if (transferred > 0) {
			if (packets == 0) {
				first_len = transferred < 32 ? transferred : 32;
				memcpy(first, buf, first_len);
			}
			packets++;
			bytes += transferred;
		}
	}

	if (err) {
		return;
	}
	if (packets == 0) {
		printf("    EP 0x%02x %s: тишина за 2 с\n",
		       ep->bEndpointAddress, type_name(type));
		return;
	}
	printf("    EP 0x%02x %s: %d пакетов, %lld байт (~%.0f КБ/с), первые байты:",
	       ep->bEndpointAddress, type_name(type), packets, bytes,
	       bytes / 2.0 / 1024.0);
	for (int i = 0; i < first_len; i++) {
		printf(" %02x", first[i]);
	}
	printf("\n");
}

int main(void)
{
	libusb_context *ctx = NULL;
	int ret = libusb_init(&ctx);
	if (ret < 0) {
		fprintf(stderr, "libusb_init: %s\n", libusb_error_name(ret));
		return 1;
	}

	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "PSVR2 (%04x:%04x) не найден. Подключён ли USB адаптера?\n",
		        PSVR2_VID, PSVR2_PID);
		return 1;
	}

	libusb_device *d = libusb_get_device(dev);
	struct libusb_device_descriptor dd;
	libusb_get_device_descriptor(d, &dd);

	static const char *speeds[] = {"?", "1.5 Мбит", "12 Мбит", "480 Мбит",
	                               "5 Гбит", "10 Гбит", "20 Гбит"};
	int sp = libusb_get_device_speed(d);
	printf("Устройство %04x:%04x, USB-скорость: %s\n", dd.idVendor, dd.idProduct,
	       (sp >= 0 && sp <= 6) ? speeds[sp] : "?");

	struct libusb_config_descriptor *cfg;
	ret = libusb_get_active_config_descriptor(d, &cfg);
	if (ret < 0) {
		fprintf(stderr, "config descriptor: %s\n", libusb_error_name(ret));
		return 1;
	}
	printf("Интерфейсов в активной конфигурации: %d\n\n", cfg->bNumInterfaces);

	/* Полная карта дескрипторов */
	for (int i = 0; i < cfg->bNumInterfaces; i++) {
		const struct libusb_interface *itf = &cfg->interface[i];
		for (int a = 0; a < itf->num_altsetting; a++) {
			const struct libusb_interface_descriptor *alt = &itf->altsetting[a];
			char name[128] = "";
			if (alt->iInterface != 0) {
				libusb_get_string_descriptor_ascii(
				    dev, alt->iInterface, (unsigned char *)name, sizeof(name));
			}
			printf("intf %2d alt %d  класс %02x/%02x/%02x  эндпоинтов %d  %s\n",
			       alt->bInterfaceNumber, alt->bAlternateSetting,
			       alt->bInterfaceClass, alt->bInterfaceSubClass,
			       alt->bInterfaceProtocol, alt->bNumEndpoints, name);
			for (int e = 0; e < alt->bNumEndpoints; e++) {
				const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
				printf("    EP 0x%02x %-3s %-9s maxpkt %5d interval %d\n",
				       ep->bEndpointAddress,
				       (ep->bEndpointAddress & 0x80) ? "IN" : "OUT",
				       type_name(ep->bmAttributes), ep->wMaxPacketSize,
				       ep->bInterval);
			}
		}
	}

	/* Прослушка: захватываем интерфейсы по одному и слушаем их IN-эндпоинты */
	printf("\n=== Прослушка IN-эндпоинтов (по 2 с) ===\n");
	for (int i = 0; i < cfg->bNumInterfaces; i++) {
		const struct libusb_interface *itf = &cfg->interface[i];
		int num = itf->altsetting[0].bInterfaceNumber;
		ret = libusb_claim_interface(dev, num);
		if (ret < 0) {
			printf("intf %2d: захватить не удалось (%s) — возможно, занят системой\n",
			       num, libusb_error_name(ret));
			continue;
		}
		for (int a = 0; a < itf->num_altsetting; a++) {
			const struct libusb_interface_descriptor *alt = &itf->altsetting[a];
			if (alt->bNumEndpoints == 0) {
				continue;
			}
			if (alt->bAlternateSetting != 0) {
				ret = libusb_set_interface_alt_setting(dev, num, alt->bAlternateSetting);
				if (ret < 0) {
					printf("intf %2d alt %d: не включился (%s)\n",
					       num, alt->bAlternateSetting, libusb_error_name(ret));
					continue;
				}
			}
			printf("intf %2d alt %d:\n", num, alt->bAlternateSetting);
			for (int e = 0; e < alt->bNumEndpoints; e++) {
				listen_endpoint(dev, &alt->endpoint[e]);
			}
		}
		libusb_release_interface(dev, num);
	}

	libusb_free_config_descriptor(cfg);
	libusb_close(dev);
	libusb_exit(ctx);
	printf("\nГотово.\n");
	return 0;
}
