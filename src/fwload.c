// Minimal firmware/data loader for host-based HP LaserJet printers, both the
// ZjStream (foo2zjs) and XQX (foo2xqx) families. Opens the printer, selects the
// USB Printer-class interface (falling back to the first bulk-OUT interface for
// single-function models), and streams the given blob (firmware or page data).
// After a transfer it drains the bulk-IN endpoint and parses any PJL/device
// status reply into "status-line: " / "status-kv: " lines for the watcher log.
//
// usage: fwload <blob> [VID] [PID]
//   VID/PID are optional hex (e.g. 0x03f0 0x002a); default to the P1102.
//   This lets one binary drive any model in the family — the watcher passes
//   the detected printer's IDs.
//
// usage: fwload --status [VID] [PID]
//   Skips sending any blob: opens the printer, sends a PJL status query to the
//   bulk-OUT endpoint, then reads and prints the bulk-IN reply the same way as
//   the post-transfer read-back. Lets the watcher / a menu-bar poll device
//   status without printing.
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#define DEFAULT_VID 0x03f0
#define DEFAULT_PID 0x002a

// PJL status query, wrapped in the Universal Exit Language escape. Sent to the
// printer's bulk-OUT in --status mode so the bulk-IN read-back has something to
// report even when we are not printing.
#define PJL_STATUS_QUERY \
    "\x1b%-12345X@PJL INFO STATUS\r\n@PJL INFO PAGECOUNT\r\n"

// Recognizable PJL status tokens. A reply line containing any of these is
// echoed with a "status-kv: " prefix so the watcher log can be parsed for
// device state (online/offline, toner, page count, display messages).
static const char *PJL_TOKENS[] = {
    "CODE=", "DISPLAY=", "ONLINE", "TONER", "PAGECOUNT", "PAGES", NULL
};

// Does a line contain a recognizable PJL status token?
static int has_pjl_token(const char *line) {
    for (int i = 0; PJL_TOKENS[i]; i++)
        if (strstr(line, PJL_TOKENS[i])) return 1;
    return 0;
}

// Drain the bulk-IN endpoint after a transfer (or status query) and report what
// the printer said. Best-effort and purely diagnostic: it must NEVER change the
// caller's exit status. Any bytes back is proof the device reacted; readable
// ASCII lines are echoed as "status-line: " (and "status-kv: " when they carry
// a known PJL token); binary/empty replies keep the byte-count summary.
//
// Bounds match the historical read-back exactly: whole-wMaxPacketSize reads,
// 500ms timeouts, capped at 64 reads so we can never hang.
static void read_status(libusb_device_handle *h, int ep_in, int ep_in_max) {
    if (ep_in < 0) return;

    int bufsz = ep_in_max > 0 ? ep_in_max : 64;
    // Accumulate the whole reply so we can split it into lines afterwards.
    long cap = (long)bufsz * 64;
    unsigned char *reply = malloc(cap);
    unsigned char *pkt = malloc(bufsz);
    long total = 0;
    int sr = 0, reads = 0;
    while (reply && pkt && reads < 64) {    // cap reads so we never hang
        int got = 0;
        sr = libusb_bulk_transfer(h, ep_in, pkt, bufsz, &got, 500);
        if (sr) break;
        if (got > 0 && total < cap) {
            long room = cap - total;
            int copy = got < room ? got : (int)room;
            memcpy(reply + total, pkt, copy);
            total += copy;
        }
        reads++;
        if (got < bufsz) break;             // short packet ends the reply
    }
    free(pkt);

    if (total <= 0) {
        if (sr == LIBUSB_ERROR_TIMEOUT)
            printf("status: no reply within 500ms (printer may still be processing)\n");
        else if (sr)
            printf("status: bulk-IN %s\n", libusb_error_name(sr));
        free(reply);
        return;
    }

    printf("status: read %ld bytes back (printer replied)\n", total);

    // Walk the reply as text lines (split on \r and \n). Emit any line that is
    // wholly printable ASCII as "status-line: "; if it carries a known PJL
    // token, also emit it as "status-kv: ". Lines with non-printable bytes are
    // treated as binary and left to the byte-count summary above.
    int printable_lines = 0;
    long i = 0;
    while (i < total) {
        long start = i;
        while (i < total && reply[i] != '\n' && reply[i] != '\r') i++;
        long linelen = i - start;
        while (i < total && (reply[i] == '\n' || reply[i] == '\r')) i++;
        if (linelen == 0) continue;

        int ok = 1;
        for (long j = 0; j < linelen; j++) {
            unsigned char c = reply[start + j];
            if (!isprint(c) && c != '\t') { ok = 0; break; }
        }
        if (!ok) continue;

        // NUL-terminate a copy of the line for printing / token matching.
        char *line = malloc(linelen + 1);
        if (!line) continue;
        memcpy(line, reply + start, linelen);
        line[linelen] = '\0';

        printf("status-line: %s\n", line);
        printable_lines++;
        if (has_pjl_token(line))
            printf("status-kv: %s\n", line);
        free(line);
    }
    if (printable_lines == 0)
        printf("status: reply is binary (no readable status lines)\n");

    free(reply);
}

// A printer that dozed off (or was left mid-transfer) can wedge its USB
// interface: every control/bulk request fails with LIBUSB_ERROR_IO until the
// device is reset. A port reset revives it without a power cycle. Returns a
// usable handle (possibly a new one if the device re-enumerated) or NULL.
static libusb_device_handle *reset_printer(libusb_context *ctx, libusb_device_handle *h, int vid, int pid) {
    fprintf(stderr, "usb: resetting printer after I/O error\n");
    int r = libusb_reset_device(h);
    if (r == LIBUSB_SUCCESS) return h;
    libusb_close(h);
    for (int attempt = 0; attempt < 10; attempt++) {
        usleep(300 * 1000);
        libusb_device_handle *fresh = libusb_open_device_with_vid_pid(ctx, vid, pid);
        if (fresh) return fresh;
    }
    return NULL;
}

int main(int argc, char **argv) {
    // --status mode: no blob, just query + read the printer's status reply.
    int status_mode = (argc >= 2 && strcmp(argv[1], "--status") == 0);
    // --fwver mode: print the FWVER field of the IEEE-1284 device ID and exit.
    int fwver_mode = (argc >= 2 && strcmp(argv[1], "--fwver") == 0);
    if (fwver_mode) status_mode = 1;    // no blob; VID/PID in argv[2]/argv[3]

    if (!status_mode && argc < 2) {
        fprintf(stderr, "usage: %s blob [VID] [PID]\n", argv[0]);
        fprintf(stderr, "       %s --status [VID] [PID]\n", argv[0]);
        return 2;
    }

    // Optional VID/PID override (hex or decimal via strtol base 0). Both modes
    // take them as argv[2]/argv[3]: in normal mode argv[1] is the blob, in
    // --status mode argv[1] is the "--status" flag, so the positions line up.
    int vid = DEFAULT_VID, pid = DEFAULT_PID;
    if (argc >= 3) vid = (int)strtol(argv[2], NULL, 0);
    if (argc >= 4) pid = (int)strtol(argv[3], NULL, 0);

    unsigned char *buf = NULL;
    long len = 0;
    if (!status_mode) {
        // setuid root is only for USB access: open the blob as the real user so
        // the binary can't be used to read files the caller couldn't read.
        uid_t saved_euid = geteuid();
        if (seteuid(getuid())) { perror("seteuid"); return 2; }
        FILE *f = fopen(argv[1], "rb");
        if (!f) { perror("open firmware"); return 2; }
        fseek(f, 0, SEEK_END); len = ftell(f); fseek(f, 0, SEEK_SET);
        buf = malloc(len);
        if (fread(buf, 1, len, f) != (size_t)len) { perror("read"); return 2; }
        fclose(f);
        if (seteuid(saved_euid)) { perror("seteuid restore"); return 2; }
        printf("firmware: %ld bytes\n", len);
    } else if (!fwver_mode) {
        printf("status query mode (no blob sent)\n");
    }

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, vid, pid);
    if (!h) { fprintf(stderr, "printer not found (VID %04x PID %04x)\n", vid, pid); return 1; }

    // Deliberately NO libusb_set_auto_detach_kernel_driver(). macOS has no
    // kernel driver on these printers' interfaces, but libusb's darwin backend
    // counts ANY IORegistry child (e.g. a user client from Logitech G HUB or a
    // browser's WebUSB) as one. Running as root (setuid), it then "captures"
    // the device: re-enumerates it on claim AND again on release, right after
    // the job was sent. A P1102 busy printing can't answer that second
    // enumeration ("failed to address device, disabling port"), so the port
    // goes dead until the printer is replugged. Plain claim works fine.

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
    int iface = -1, ep_out = -1, ep_in = -1, iface_class = -1, ep_in_max = 64;
    for (int pass = 0; pass < 2 && ep_out < 0; pass++) {
        for (int i = 0; i < cfg->bNumInterfaces && ep_out < 0; i++) {
            const struct libusb_interface_descriptor *id = &cfg->interface[i].altsetting[0];
            // pass 0: only the USB Printer class; pass 1: any class.
            if (pass == 0 && id->bInterfaceClass != LIBUSB_CLASS_PRINTER) continue;
            int cand_out = -1, cand_in = -1, cand_in_max = 64;
            for (int e = 0; e < id->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                int is_bulk = (ep->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_BULK;
                int is_out  = (ep->bEndpointAddress & 0x80) == 0;
                if (!is_bulk) continue;
                if (is_out && cand_out < 0) cand_out = ep->bEndpointAddress;
                if (!is_out && cand_in < 0) {
                    cand_in = ep->bEndpointAddress;
                    if (ep->wMaxPacketSize > 0) cand_in_max = ep->wMaxPacketSize;
                }
            }
            if (cand_out >= 0) {
                iface = id->bInterfaceNumber; ep_out = cand_out;
                ep_in = cand_in; ep_in_max = cand_in_max;
                iface_class = id->bInterfaceClass;
            }
        }
    }
    if (ep_out < 0) { fprintf(stderr, "no bulk-OUT endpoint\n"); return 1; }

    // --fwver: USB printer-class GET_DEVICE_ID, print the FWVER value (e.g.
    // "20120814" when firmware is loaded, "PENDING" when it still needs one).
    // Prints nothing if the device ID has no FWVER field.
    if (fwver_mode) {
        unsigned char id[1024] = {0};
        int n = libusb_control_transfer(h, 0xA1, 0, 0, (uint16_t)(iface << 8),
                                        id, sizeof id - 1, 3000);
        if (n == LIBUSB_ERROR_IO || n == LIBUSB_ERROR_PIPE) {
            h = reset_printer(ctx, h, vid, pid);
            if (!h) { fprintf(stderr, "get_device_id: printer gone after reset\n"); return 1; }
            n = libusb_control_transfer(h, 0xA1, 0, 0, (uint16_t)(iface << 8), id, sizeof id - 1, 3000);
        }
        if (n < 2) { fprintf(stderr, "get_device_id: %s\n", libusb_error_name(n)); return 1; }
        char *v = strstr((char *)id + 2, "FWVER:");
        if (v) { v += 6; printf("%.*s\n", (int)strcspn(v, ";"), v); }
        libusb_close(h);
        libusb_exit(ctx);
        return 0;
    }
    printf("interface %d (class %d), bulk-OUT 0x%02x", iface, iface_class, ep_out);
    if (ep_in >= 0) printf(", bulk-IN 0x%02x", ep_in);
    printf("\n");

    int r = libusb_claim_interface(h, iface);
    if (r) { fprintf(stderr, "claim_interface: %s\n", libusb_error_name(r)); return 1; }

    // In --status mode there is no page/firmware blob: push a PJL status query
    // instead so the bulk-IN read-back below has a reply to parse. In normal
    // mode we point the same send loop at the caller's blob. Either way "sent"
    // must equal the number of bytes we meant to send for a clean exit.
    if (status_mode) {
        buf = (unsigned char *)PJL_STATUS_QUERY;
        len = (long)strlen(PJL_STATUS_QUERY);
    }

    int sent = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        sent = 0;
        while (sent < len) {
            int chunk = len - sent; if (chunk > 4096) chunk = 4096;
            int transferred = 0;
            r = libusb_bulk_transfer(h, ep_out, buf + sent, chunk, &transferred, 10000);
            if (r) { fprintf(stderr, "bulk_transfer: %s (sent %d)\n", libusb_error_name(r), sent); break; }
            sent += transferred;
        }
        // Retry only when nothing reached the printer: resending a partially
        // delivered job could print garbage or duplicate pages.
        if (sent == len || sent > 0 || attempt > 0) break;
        if (r != LIBUSB_ERROR_IO && r != LIBUSB_ERROR_PIPE && r != LIBUSB_ERROR_TIMEOUT) break;
        libusb_release_interface(h, iface);
        h = reset_printer(ctx, h, vid, pid);
        if (!h) { fprintf(stderr, "printer gone after reset\n"); return 1; }
        if ((r = libusb_claim_interface(h, iface))) {
            fprintf(stderr, "claim_interface after reset: %s\n", libusb_error_name(r));
            return 1;
        }
        usleep(500 * 1000);
    }
    if (status_mode)
        printf("sent %d/%ld bytes (PJL status query)\n", sent, len);
    else
        printf("sent %d/%ld bytes\n", sent, len);

    // Best-effort status read-back. A wrong-interface bulk-OUT accepts every
    // byte and returns success, so a clean "sent N/N" alone cannot confirm the
    // printer took the data. If the interface exposes a bulk-IN, drain it: any
    // bytes back is proof the device is reacting, and PJL replies carry
    // human-readable status lines (echoed as "status-line: " / "status-kv: ").
    // Purely diagnostic — never fails the transfer.
    read_status(h, ep_in, ep_in_max);

    libusb_release_interface(h, iface);
    libusb_close(h);
    libusb_exit(ctx);
    return sent == len ? 0 : 1;
}
