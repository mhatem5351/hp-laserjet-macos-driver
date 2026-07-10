// Minimal firmware loader for HP LaserJet P1102 (ZjStream host-based).
// Opens the printer, finds the bulk-OUT endpoint, and streams the .dl blob.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libusb-1.0/libusb.h>

#define VID 0x03f0
#define PID 0x002a

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s firmware.dl\n", argv[0]); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open firmware"); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { perror("read"); return 2; }
    fclose(f);
    printf("firmware: %ld bytes\n", len);

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, VID, PID);
    if (!h) { fprintf(stderr, "printer not found (VID %04x PID %04x)\n", VID, PID); return 1; }

    // macOS: kernel/class driver may hold the interface; detach if possible.
    libusb_set_auto_detach_kernel_driver(h, 1);

    // Find interface + bulk OUT endpoint.
    libusb_device *dev = libusb_get_device(h);
    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(dev, &cfg)) {
        fprintf(stderr, "no config descriptor\n"); return 1;
    }
    int iface = -1, ep_out = -1;
    for (int i = 0; i < cfg->bNumInterfaces && ep_out < 0; i++) {
        const struct libusb_interface_descriptor *id = &cfg->interface[i].altsetting[0];
        for (int e = 0; e < id->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
            int is_bulk = (ep->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_BULK;
            int is_out  = (ep->bEndpointAddress & 0x80) == 0;
            if (is_bulk && is_out) { iface = id->bInterfaceNumber; ep_out = ep->bEndpointAddress; break; }
        }
    }
    if (ep_out < 0) { fprintf(stderr, "no bulk-OUT endpoint\n"); return 1; }
    printf("interface %d, bulk-OUT endpoint 0x%02x\n", iface, ep_out);

    int r = libusb_claim_interface(h, iface);
    if (r) { fprintf(stderr, "claim_interface: %s\n", libusb_error_name(r)); return 1; }

    int sent = 0;
    while (sent < len) {
        int chunk = len - sent; if (chunk > 4096) chunk = 4096;
        int transferred = 0;
        r = libusb_bulk_transfer(h, ep_out, buf + sent, chunk, &transferred, 10000);
        if (r) { fprintf(stderr, "bulk_transfer: %s (sent %d)\n", libusb_error_name(r), sent); break; }
        sent += transferred;
    }
    printf("sent %d/%ld bytes\n", sent, len);

    libusb_release_interface(h, iface);
    libusb_close(h);
    libusb_exit(ctx);
    return sent == len ? 0 : 1;
}
