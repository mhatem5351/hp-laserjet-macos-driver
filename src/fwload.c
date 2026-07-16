// Minimal firmware/data loader for host-based HP LaserJet printers, both the
// ZjStream (foo2zjs) and XQX (foo2xqx) families. Opens the printer, selects the
// USB Printer-class interface (falling back to the first bulk-OUT interface for
// single-function models), and streams the given blob (firmware or page data).
//
// usage: fwload <blob> [VID] [PID]
//   VID/PID are optional hex (e.g. 0x03f0 0x002a); default to the P1102.
//   This lets one binary drive any model in the family — the watcher passes
//   the detected printer's IDs.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libusb-1.0/libusb.h>

#define DEFAULT_VID 0x03f0
#define DEFAULT_PID 0x002a

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s blob [VID] [PID]\n", argv[0]);
        return 2;
    }

    // Optional VID/PID override (hex or decimal via strtol base 0).
    int vid = DEFAULT_VID, pid = DEFAULT_PID;
    if (argc >= 3) vid = (int)strtol(argv[2], NULL, 0);
    if (argc >= 4) pid = (int)strtol(argv[3], NULL, 0);

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open firmware"); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { perror("read"); return 2; }
    fclose(f);
    printf("firmware: %ld bytes\n", len);

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, vid, pid);
    if (!h) { fprintf(stderr, "printer not found (VID %04x PID %04x)\n", vid, pid); return 1; }

    // macOS: kernel/class driver may hold the interface; detach if possible.
    libusb_set_auto_detach_kernel_driver(h, 1);

    // Find interface + bulk OUT endpoint.
    libusb_device *dev = libusb_get_device(h);
    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(dev, &cfg)) {
        fprintf(stderr, "no config descriptor\n"); return 1;
    }
    // Pick the interface that has a bulk-OUT endpoint. On multifunction MFPs
    // (M1005, M1120) interface 0 is a vendor-specific (class 0xFF) scanner/ACL
    // interface that ALSO exposes bulk endpoints — writing there silently
    // succeeds but never prints. The actual printer is the USB Printer-class
    // interface (bInterfaceClass == 7). So we scan in two passes: prefer a
    // class-7 interface, and only fall back to the first bulk-OUT of any class
    // if the device declares no printer-class interface (e.g. the P1102, which
    // is single-function and reports interface 0 with no class-7 marker).
    int iface = -1, ep_out = -1, ep_in = -1, iface_class = -1;
    for (int pass = 0; pass < 2 && ep_out < 0; pass++) {
        for (int i = 0; i < cfg->bNumInterfaces && ep_out < 0; i++) {
            const struct libusb_interface_descriptor *id = &cfg->interface[i].altsetting[0];
            // pass 0: only the USB Printer class; pass 1: any class.
            if (pass == 0 && id->bInterfaceClass != LIBUSB_CLASS_PRINTER) continue;
            int cand_out = -1, cand_in = -1;
            for (int e = 0; e < id->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                int is_bulk = (ep->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_BULK;
                int is_out  = (ep->bEndpointAddress & 0x80) == 0;
                if (!is_bulk) continue;
                if (is_out && cand_out < 0) cand_out = ep->bEndpointAddress;
                if (!is_out && cand_in < 0) cand_in = ep->bEndpointAddress;
            }
            if (cand_out >= 0) {
                iface = id->bInterfaceNumber; ep_out = cand_out;
                ep_in = cand_in; iface_class = id->bInterfaceClass;
            }
        }
    }
    if (ep_out < 0) { fprintf(stderr, "no bulk-OUT endpoint\n"); return 1; }
    printf("interface %d (class %d), bulk-OUT 0x%02x", iface, iface_class, ep_out);
    if (ep_in >= 0) printf(", bulk-IN 0x%02x", ep_in);
    printf("\n");

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

    // Best-effort status read-back. A wrong-interface bulk-OUT accepts every
    // byte and returns success, so a clean "sent N/N" alone cannot confirm the
    // printer took the data. If the interface exposes a bulk-IN, read from it
    // with a short timeout: any bytes (or a stall) is a sign the device is
    // actually reacting. Purely diagnostic — never fails the transfer.
    if (ep_in >= 0) {
        unsigned char st[64];
        int got = 0;
        int sr = libusb_bulk_transfer(h, ep_in, st, sizeof st, &got, 500);
        if (sr == 0)
            printf("status: read %d bytes back\n", got);
        else if (sr == LIBUSB_ERROR_TIMEOUT)
            printf("status: no reply within 500ms (printer may still be processing)\n");
        else
            printf("status: bulk-IN %s\n", libusb_error_name(sr));
    }

    libusb_release_interface(h, iface);
    libusb_close(h);
    libusb_exit(ctx);
    return sent == len ? 0 : 1;
}
