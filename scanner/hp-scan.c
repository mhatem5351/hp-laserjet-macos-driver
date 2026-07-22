// hp-scan — libusb scanner probe/skeleton for host-based HP LaserJet MFPs
// (M1005 and family). This is scaffolding, NOT a working scanner: the real
// scan command/data handshake is proprietary and unknown pending a USB capture
// (see scanner/README.md and scanner/PROTOCOL.md). What this tool does today is
// prove out the USB transport — open the device, select the vendor-specific
// scan interface, enumerate its endpoints, claim it, and run a stubbed probe
// that sends a PLACEHOLDER command and logs whatever the device sends back.
//
// Unlike src/fwload.c (which drives the USB Printer-class interface), the
// scanner lives on the OTHER interface: on an MFP, interface 0 is the
// vendor-specific (class 0xFF) scan interface with its own bulk endpoints.
// fwload deliberately avoids interface 0; this tool deliberately selects it.
//
// usage: hp-scan [VID] [PID]
//   VID/PID are optional hex (e.g. 0x03f0 0x3b17); default to the M1005 MFP.
//   The M1005's PID 0x3b17 is only an example default — pass the PID of any
//   HP host-based MFP to probe it. Nothing here is hardcoded to one serial.
//
// This binary must NOT be installed setuid. It claims the scan interface
// (interface 0) and only reads/writes bulk endpoints for diagnostics.
//
// Copyright (C) 2026 hp-laserjet-mac-driver contributors.
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program; if not, see <https://www.gnu.org/licenses/>.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libusb-1.0/libusb.h>

#define DEFAULT_VID 0x03f0   // HP
#define DEFAULT_PID 0x3b17   // M1005 MFP (example only; pass any MFP PID)

// The scan interface on these MFPs is vendor-specific: class/subclass/protocol
// all 0xFF. We select by class rather than a hardcoded interface number so the
// tool still finds the scan interface if the layout differs on another model.
#define SCAN_IFACE_CLASS 0xFF

// PLACEHOLDER probe command. This is NOT the real scan command — the actual
// byte sequence is unknown and must come from a USB capture or an hpaio port
// (see scanner/PROTOCOL.md). It exists only to exercise the bulk-OUT path and
// give the bulk-IN read-back something to react to during transport bring-up.
static const unsigned char PROBE_PLACEHOLDER[] = { 0x1b, 0x00, 0x00, 0x00 };

// Human-readable USB transfer type for an endpoint's bmAttributes.
static const char *ep_type_name(unsigned char bmAttributes) {
    switch (bmAttributes & 3) {
        case LIBUSB_TRANSFER_TYPE_CONTROL:     return "control";
        case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "isochronous";
        case LIBUSB_TRANSFER_TYPE_BULK:        return "bulk";
        case LIBUSB_TRANSFER_TYPE_INTERRUPT:   return "interrupt";
        default:                               return "?";
    }
}

// Drain a bulk/interrupt IN endpoint after the placeholder command and log the
// bytes. Best-effort and purely diagnostic: never changes the caller's exit
// status. Mirrors the bounded read-back in src/fwload.c (whole-packet reads,
// 500ms timeouts, capped read count so we can never hang). `label` names the
// endpoint role in the log (e.g. "image data", "status").
static void read_back(libusb_device_handle *h, int ep_in, int ep_in_max,
                      const char *label) {
    if (ep_in < 0) {
        printf("read-back (%s): no IN endpoint\n", label);
        return;
    }

    int bufsz = ep_in_max > 0 ? ep_in_max : 64;
    unsigned char *pkt = malloc(bufsz);
    if (!pkt) return;

    long total = 0;
    int sr = 0, reads = 0;
    while (reads < 64) {                     // cap reads so we never hang
        int got = 0;
        sr = libusb_bulk_transfer(h, ep_in, pkt, bufsz, &got, 500);
        if (sr) break;
        if (got > 0) {
            printf("read-back (%s): +%d bytes:", label, got);
            for (int i = 0; i < got && i < 32; i++) printf(" %02x", pkt[i]);
            if (got > 32) printf(" ...");
            printf("\n");
            total += got;
        }
        reads++;
        if (got < bufsz) break;              // short packet ends the reply
    }
    free(pkt);

    if (total <= 0) {
        if (sr == LIBUSB_ERROR_TIMEOUT)
            printf("read-back (%s): no reply within 500ms\n", label);
        else if (sr)
            printf("read-back (%s): IN %s\n", label, libusb_error_name(sr));
    } else {
        printf("read-back (%s): %ld bytes total\n", label, total);
    }
}

// Stubbed scan probe. Sends the PLACEHOLDER command on the scan bulk-OUT, then
// reads back the image-data IN and (if present) the status/interrupt IN, just
// logging bytes. This is where the real capture-derived command sequence goes.
//
// TODO(capture): replace PROBE_PLACEHOLDER + this single OUT/IN exchange with
// the real handshake once a USB capture is available:
//   1. send scan-start / mode / resolution / area command(s) on ep_out
//   2. loop reading scan lines / bands from ep_in until end-of-image
//   3. poll ep_status for progress / button / paper events
// Until then this only validates that the transport (claim + bulk OUT/IN on the
// vendor-specific interface) works. See scanner/PROTOCOL.md for the capture
// procedure and the table to record the observed phases.
static void scan_probe(libusb_device_handle *h, int ep_out, int ep_in,
                       int ep_in_max, int ep_status, int ep_status_max) {
    printf("scan_probe: STUB — sending placeholder command, not a real scan\n");

    int sent = 0, r;
    r = libusb_bulk_transfer(h, ep_out, (unsigned char *)PROBE_PLACEHOLDER,
                             (int)sizeof(PROBE_PLACEHOLDER), &sent, 5000);
    if (r)
        printf("scan_probe: placeholder OUT %s\n", libusb_error_name(r));
    else
        printf("scan_probe: placeholder OUT sent %d/%zu bytes\n",
               sent, sizeof(PROBE_PLACEHOLDER));

    // Log whatever the device returns on the data and status channels.
    read_back(h, ep_in, ep_in_max, "image data");
    if (ep_status >= 0)
        read_back(h, ep_status, ep_status_max, "status");
}

int main(int argc, char **argv) {
    int vid = DEFAULT_VID, pid = DEFAULT_PID;
    if (argc >= 2) vid = (int)strtol(argv[1], NULL, 0);
    if (argc >= 3) pid = (int)strtol(argv[2], NULL, 0);
    printf("hp-scan: probing VID %04x PID %04x\n", vid, pid);

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, vid, pid);
    if (!h) {
        fprintf(stderr, "device not found (VID %04x PID %04x)\n", vid, pid);
        libusb_exit(ctx);
        return 1;
    }

    // macOS: a kernel/class driver may hold the interface; detach if possible.
    libusb_set_auto_detach_kernel_driver(h, 1);

    libusb_device *dev = libusb_get_device(h);
    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(dev, &cfg)) {
        fprintf(stderr, "no config descriptor\n");
        libusb_close(h);
        libusb_exit(ctx);
        return 1;
    }

    // Select the vendor-specific SCAN interface. This is the deliberate mirror
    // of src/fwload.c: fwload prefers the USB Printer class (7) and avoids the
    // vendor-specific interface; the scanner wants precisely that interface
    // (class 0xFF), which on an MFP is where the scan endpoints live.
    int iface = -1, iface_class = -1;
    const struct libusb_interface_descriptor *id = NULL;
    for (int i = 0; i < cfg->bNumInterfaces; i++) {
        const struct libusb_interface_descriptor *cand =
            &cfg->interface[i].altsetting[0];
        if (cand->bInterfaceClass == SCAN_IFACE_CLASS) {
            id = cand;
            iface = cand->bInterfaceNumber;
            iface_class = cand->bInterfaceClass;
            break;
        }
    }
    if (!id) {
        fprintf(stderr, "no vendor-specific (class 0x%02x) scan interface — "
                        "not a scanning MFP?\n", SCAN_IFACE_CLASS);
        libusb_free_config_descriptor(cfg);
        libusb_close(h);
        libusb_exit(ctx);
        return 1;
    }
    printf("scan interface %d (class 0x%02x, subclass 0x%02x, protocol 0x%02x), "
           "%d endpoints\n",
           iface, iface_class, id->bInterfaceSubClass, id->bInterfaceProtocol,
           id->bNumEndpoints);

    // Enumerate the endpoints and classify them. We record the first bulk-OUT
    // (command channel), first bulk-IN (image data), and first interrupt-IN
    // (status/button events) — the expected 3-endpoint layout. The descriptor
    // dump is printed regardless so a capture can confirm the real roles.
    int ep_out = -1, ep_in = -1, ep_in_max = 64;
    int ep_status = -1, ep_status_max = 64;
    for (int e = 0; e < id->bNumEndpoints; e++) {
        const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
        int type = ep->bmAttributes & 3;
        int is_in = (ep->bEndpointAddress & 0x80) != 0;
        printf("  endpoint 0x%02x: %-11s %-3s maxpacket %d\n",
               ep->bEndpointAddress, ep_type_name(ep->bmAttributes),
               is_in ? "IN" : "OUT", ep->wMaxPacketSize);

        if (type == LIBUSB_TRANSFER_TYPE_BULK && !is_in && ep_out < 0) {
            ep_out = ep->bEndpointAddress;
        } else if (type == LIBUSB_TRANSFER_TYPE_BULK && is_in && ep_in < 0) {
            ep_in = ep->bEndpointAddress;
            if (ep->wMaxPacketSize > 0) ep_in_max = ep->wMaxPacketSize;
        } else if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT && is_in &&
                   ep_status < 0) {
            ep_status = ep->bEndpointAddress;
            if (ep->wMaxPacketSize > 0) ep_status_max = ep->wMaxPacketSize;
        }
    }

    if (ep_out < 0 || ep_in < 0) {
        fprintf(stderr, "scan interface missing bulk-OUT and/or bulk-IN "
                        "(OUT 0x%02x, IN 0x%02x)\n", ep_out, ep_in);
        libusb_free_config_descriptor(cfg);
        libusb_close(h);
        libusb_exit(ctx);
        return 1;
    }
    printf("using bulk-OUT 0x%02x, bulk-IN 0x%02x", ep_out, ep_in);
    if (ep_status >= 0) printf(", status/interrupt-IN 0x%02x", ep_status);
    printf("\n");

    int r = libusb_claim_interface(h, iface);
    if (r) {
        fprintf(stderr, "claim_interface %d: %s\n", iface, libusb_error_name(r));
        libusb_free_config_descriptor(cfg);
        libusb_close(h);
        libusb_exit(ctx);
        return 1;
    }

    scan_probe(h, ep_out, ep_in, ep_in_max, ep_status, ep_status_max);

    libusb_release_interface(h, iface);
    libusb_free_config_descriptor(cfg);
    libusb_close(h);
    libusb_exit(ctx);
    return 0;
}
