/*
 * psvr2_camera — attempt to get PSVR2 camera frames (passthrough) via the
 * PC adapter and dump what is found to a file.
 *
 * Protocol from PSVR2Toolkit (BnuuySolutions):
 * https://github.com/BnuuySolutions/PSVR2Toolkit
 *   - camera enable: vendor control 0x09, report_id 0x0B,
 *     data {1,0,0,0, 0x10, 0,0,0} (0x05 instead of 0x10 — disable)
 *   - frames: signature 'V','I', 256-byte header,
 *     image_type 11 — passthrough BC4 1024x1016, 6 — eye image
 *   - gaze stream nearby: report_id 0x0C, interface 5 EP 0x85
 *
 * Per Toolkit experience, the enable command does not "stick" — resend it.
 * Iterate over all interfaces, alternate settings and IN endpoints,
 * print the signatures of every stream found (not just VI).
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>
#include <libusb.h>

#define PSVR2_VID 0x054C
#define PSVR2_PID 0x0CDE

#pragma pack(push, 1)
struct image_data_hdr {
	unsigned char magic[2]; /* 'V','I' */
	uint16_t version;
	uint32_t total_size;
	uint32_t timestamp;
	uint8_t unk0[4];
	uint16_t image_type; /* 11 — passthrough, 6 — eye image */
	uint8_t unk1[22];
	uint32_t custom_data_size;
	uint8_t unk2[20];
	uint8_t unk3[192];
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

static int send_cmd(libusb_device_handle *dev, uint8_t report_id,
                    const uint8_t *data, uint16_t len)
{
	struct control_payload p;
	memset(&p, 0, sizeof(p));
	p.report_id = report_id;
	p.subcmd = 1;
	p.length = len;
	if (data != NULL && len > 0) {
		memcpy(p.data, data, len);
	}
	int ret = libusb_control_transfer(dev, 0x42, 0x09, 0, 0,
	                                  (unsigned char *)&p, len + 8, 2000);
	return ret < 0 ? ret : 0;
}

static void camera_power(libusb_device_handle *dev, int on)
{
	uint8_t data[8] = {1, 0, 0, 0, (uint8_t)(on ? 0x10 : 0x05), 0, 0, 0};
	send_cmd(dev, 0x0B, data, sizeof(data));
}

/* Listen on an endpoint, print the packet signatures encountered */
static int listen_ep(libusb_device_handle *dev, int ep, int type, int tries,
                     const char *outPath, int *foundVI)
{
	static uint8_t buf[1048576];
	int packets = 0;
	char seen[8][3] = {{0}};
	int seen_n = 0;

	for (int i = 0; i < tries && !stop; i++) {
		int transferred = 0;
		int ret = (type == LIBUSB_TRANSFER_TYPE_BULK)
		    ? libusb_bulk_transfer(dev, ep, buf, sizeof(buf), &transferred, 250)
		    : libusb_interrupt_transfer(dev, ep, buf, sizeof(buf), &transferred, 250);
		if (ret != 0 || transferred < 4) {
			continue;
		}
		packets++;

		char sig[3] = {isprint(buf[0]) ? buf[0] : '.', isprint(buf[1]) ? buf[1] : '.', 0};
		int known = 0;
		for (int s = 0; s < seen_n; s++) {
			if (strcmp(seen[s], sig) == 0) { known = 1; break; }
		}
		if (!known && seen_n < 8) {
			strcpy(seen[seen_n++], sig);
		}

		if (buf[0] == 'V' && buf[1] == 'I' && transferred > (int)sizeof(struct image_data_hdr)) {
			struct image_data_hdr *h = (struct image_data_hdr *)buf;
			printf("      >>> VI frame! type %u, size %u, packet %d bytes\n",
			       h->image_type, h->total_size, transferred);
			static int saved = 0;
			if (outPath != NULL && saved < 6) {
				char path[512];
				snprintf(path, sizeof(path), "%s.%d", outPath, saved);
				FILE *f = fopen(path, "wb");
				if (f != NULL) {
					fwrite(buf, 1, transferred, f);
					fclose(f);
					printf("      >>> frame %d: %s (hdr %02x %02x %02x %02x %02x %02x)\n",
					       saved, path, buf[16], buf[17], buf[18], buf[19], buf[20], buf[21]);
					saved++;
				}
			}
			*foundVI = 1;
		}
	}

	if (packets > 0) {
		printf("      %d packets, signatures:", packets);
		for (int s = 0; s < seen_n; s++) {
			printf(" '%s'", seen[s]);
		}
		printf("\n");
	}
	return packets;
}

int main(int argc, char **argv)
{
	signal(SIGINT, on_sigint);
	const char *outPath = argc > 1 ? argv[1] : NULL;

	libusb_context *ctx = NULL;
	libusb_init(&ctx);
	libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, PSVR2_VID, PSVR2_PID);
	if (dev == NULL) {
		fprintf(stderr, "PSVR2 not found\n");
		return 1;
	}

	/* Enable both gaze and cameras: image_type 6 comes along with the eye stream */
	send_cmd(dev, 0x0C, NULL, 0);
	camera_power(dev, 1);
	printf("Enable commands sent (0x0C gaze, 0x0B cameras)\n\n");

	libusb_device *d = libusb_get_device(dev);
	struct libusb_config_descriptor *cfg;
	if (libusb_get_active_config_descriptor(d, &cfg) < 0) {
		fprintf(stderr, "config descriptor unavailable\n");
		return 1;
	}

	int foundVI = 0;
	for (int i = 0; i < cfg->bNumInterfaces && !stop; i++) {
		const struct libusb_interface *itf = &cfg->interface[i];
		int num = itf->altsetting[0].bInterfaceNumber;
		if (libusb_claim_interface(dev, num) != 0) {
			continue;
		}
		for (int a = 0; a < itf->num_altsetting && !stop; a++) {
			const struct libusb_interface_descriptor *alt = &itf->altsetting[a];
			if (alt->bNumEndpoints == 0) {
				continue;
			}
			if (libusb_set_interface_alt_setting(dev, num, alt->bAlternateSetting) < 0) {
				continue;
			}
			/* The command does not "stick": repeat on every setting */
			camera_power(dev, 1);
			for (int e = 0; e < alt->bNumEndpoints; e++) {
				const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
				int type = ep->bmAttributes & 0x3;
				if (!(ep->bEndpointAddress & LIBUSB_ENDPOINT_IN)
				    || (type != LIBUSB_TRANSFER_TYPE_BULK
				        && type != LIBUSB_TRANSFER_TYPE_INTERRUPT)) {
					continue;
				}
				printf("intf %2d alt %d EP 0x%02x:\n", num, alt->bAlternateSetting,
				       ep->bEndpointAddress);
				listen_ep(dev, ep->bEndpointAddress, type, 40, outPath, &foundVI);
			}
		}
		libusb_release_interface(dev, num);
	}

	printf("\n%s\n", foundVI
	    ? "=== CAMERA FRAMES AVAILABLE ==="
	    : "=== No VI frames found ===");

	camera_power(dev, 0);
	libusb_free_config_descriptor(cfg);
	libusb_close(dev);
	libusb_exit(ctx);
	return 0;
}
