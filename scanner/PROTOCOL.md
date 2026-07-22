# Scan protocol capture — instructions for the hardware owner

We need one clean USB capture of a full flatbed scan on your HP MFP (e.g. the
M1005) to reverse-engineer the proprietary scan handshake. This document is the
template: how to capture, what to record, and where to write down what you see.
Please fill in the tables at the bottom and attach the raw capture file.

The `scanner/hp-scan.c` probe already brings up the USB transport (it selects
the vendor-specific scan interface, enumerates endpoints, and claims it). What
is still missing is the *content* of the command/data phases — that is what this
capture provides.

---

## Step 0 — record the device layout (macOS, no scan yet)

On the Mac the device is attached to, dump the USB descriptors so we can confirm
the interface/endpoint layout the probe expects. Use `ioreg`, not
`system_profiler` (the latter returns empty on recent macOS):

```bash
ioreg -p IOUSB -l -w 0 | grep -iA40 'LaserJet\|M1005\|HP'
```

Also run the probe and paste its full output:

```bash
cc -O2 -Wall -I"$(brew --prefix)/include" scanner/hp-scan.c \
   -L"$(brew --prefix)/lib" -lusb-1.0 -o /tmp/hp-scan
/tmp/hp-scan 0x03f0 <PID>      # e.g. 0x3b17 for the M1005
```

Record the printed interface class/subclass/protocol and the three endpoint
descriptors (address / type / maxpacket) in **Table A** below.

---

## Step 1 — capture a full scan

The scan itself must be captured on a platform that can actually drive the
scanner. Two options:

### Option A — Windows + USBPcap (recommended, no working driver needed)

1. Install **Wireshark** with the **USBPcap** component
   (<https://desowin.org/usbpcap/>).
2. Plug the MFP into the Windows machine. Install HP's Windows driver / HP Smart
   so a scan can be triggered, OR use any TWAIN/WIA scan utility that sees it.
3. Start Wireshark, choose the **USBPcap** interface that lists the HP device,
   and begin capture.
4. Do **one** flatbed scan: place a page, scan at a known resolution and color
   mode (record which — see Table B), let it finish.
5. Stop the capture. Save as `.pcapng`. Note the device's USB address/bus so we
   can filter to just this device.

### Option B — Linux + usbmon + hpaio (validates against the reference backend)

1. Install HPLIP (`hplip` / `hplip-common`) so the SANE `hpaio` backend is
   present; confirm `scanimage -L` lists the device as `hpaio:...`.
2. Load usbmon and capture with Wireshark or tcpdump on the `usbmonN` interface
   for the right bus:
   ```bash
   sudo modprobe usbmon
   # find bus with: lsusb | grep 03f0
   sudo wireshark   # capture on usbmonN, or:
   sudo tcpdump -i usbmonN -w hp-scan.pcap
   ```
3. In another shell, trigger one scan at a known resolution/mode:
   ```bash
   scanimage -d 'hpaio:/usb/...' --resolution 300 --mode Color \
       > scan.pnm
   ```
4. Stop the capture and save the `.pcap`.

Because `hpaio` is the reference implementation (see `scanner/README.md`), an
Option B capture is especially valuable — it shows exactly the byte sequence the
canonical backend uses.

---

## Step 2 — what to send back

Attach all of:

- the raw capture file (`.pcapng` / `.pcap`), filtered to the HP device if
  possible;
- the `ioreg` dump and the `/tmp/hp-scan` output from Step 0;
- Table A and Table B below, filled in;
- as much of Table C as you can read off the capture (we can finish decoding it,
  but your notes on which action produced which burst of traffic are gold).

Do **not** include anything personal in the scanned test page — use a plain test
pattern or lorem-ipsum sheet.

---

## Table A — observed interface / endpoint layout

Fill from `/tmp/hp-scan` output (Step 0).

| Field | Value |
|-------|-------|
| VID / PID | `0x03f0` / `0x____` |
| Scan interface number | |
| Interface class / subclass / protocol | `0x__` / `0x__` / `0x__` |
| Endpoint 1 (address / type / dir / maxpacket) | |
| Endpoint 2 (address / type / dir / maxpacket) | |
| Endpoint 3 (address / type / dir / maxpacket) | |
| Which endpoint carried commands (bulk-OUT) | |
| Which endpoint carried image data (bulk-IN) | |
| Which endpoint carried status (interrupt-IN) | |

## Table B — scan parameters used

| Field | Value |
|-------|-------|
| Platform / tool used to scan | |
| Resolution (DPI) | |
| Color mode (Color / Gray / Lineart) | |
| Scan area (full flatbed / partial) | |
| Approx. output image size (bytes) | |

## Table C — observed protocol phases

For each distinct phase in the capture, record the direction, endpoint, and the
leading bytes of the payload. Add rows as needed.

| # | Phase (your guess) | Dir | Endpoint | Leading bytes (hex) | Notes |
|---|--------------------|-----|----------|---------------------|-------|
| 1 | open / init        | OUT |          |                     |       |
| 2 | set resolution     | OUT |          |                     |       |
| 3 | set mode / area    | OUT |          |                     |       |
| 4 | start scan         | OUT |          |                     |       |
| 5 | status poll        | IN  |          |                     |       |
| 6 | image data (band)  | IN  |          |                     | repeats until end |
| 7 | end / release      | OUT |          |                     |       |

Once Table C is populated we replace the `TODO(capture)` stub in
`scanner/hp-scan.c`'s `scan_probe()` with the real sequence.
