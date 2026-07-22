# Scanner support (M1005 MFP) — scaffolding

Status: **skeleton + protocol notes only.** Not a working scanner. Enabling
real scanning needs a USB capture (or a full port of the SANE `hpaio` logic)
that we do not have yet. This directory holds the probe tool and the notes a
hardware owner needs to record that capture.

## Why this is separate from printing

The M1005 is a multifunction device. Its USB configuration exposes two
interfaces:

| Interface | Class / Subclass / Protocol | Role |
|-----------|-----------------------------|------|
| 0         | `0xFF / 0xFF / 0xFF` (vendor-specific) | **scan** — command + image data + status |
| 1         | `0x07` (USB Printer)        | **print** — the raster path `fwload` drives |

The printer path (`fwload`, `hp-laserjet-watcher.sh`) deliberately prefers the
class-7 interface and treats interface 0 as off-limits: writing raster to the
vendor-specific interface silently succeeds but never prints (see the two-pass
scan comment in `src/fwload.c`). The scanner is the mirror image — it must
claim **interface 0** and leave the printer interface alone.

A vendor-specific class (`0xFF/0xFF/0xFF`) with three endpoints is *normal* for
HP host-based MFP scanning. It is not a bug or an undocumented mode: HP never
implemented a standard USB scanner class here. The scan protocol is entirely
proprietary and rides raw bulk transfers on that interface.

## What is known

- **Interface layout** (above): scan is interface 0, vendor-specific.
- **Endpoint count**: three endpoints on interface 0 — expected to be a
  bulk-OUT (host → device commands), a bulk-IN (device → host image data), and
  an interrupt-IN (status/button events). `hp-scan.c` enumerates and prints the
  actual descriptors so this can be confirmed on real hardware; the roles above
  are the *expected* mapping, to be verified against the capture.
- **Family / IDs**: VID `0x03f0` (HP). The M1005 MFP is PID `0x3b17` (the same
  PID the watcher's `name_row()` fallback handles, since it is absent from the
  driver's own device table). `hp-scan.c` takes the PID as an argument so it is
  not hardcoded to one model.

## What is unknown (needs a capture)

- The exact **command handshake**: the byte sequences the host sends on the
  bulk-OUT endpoint to start a scan, set resolution / color mode / area, and
  read status.
- The **image data framing**: how scan lines are delimited, whether there is a
  header, compression, and the pixel format on the bulk-IN endpoint.
- Which endpoint is the **status/interrupt** channel and what it reports
  (button presses, paper state).

None of these are guessed in this scaffolding. `hp-scan.c` sends only a clearly
marked *placeholder* command and logs whatever comes back; it does not pretend
to know the real protocol.

## Reference implementation

The authoritative reference for this family's scan protocol is the SANE
**`hpaio`** backend, part of **HPLIP** (HP Linux Imaging and Printing). HPLIP's
`scan/sane/` sources implement the proprietary command/data handshake for HP
host-based MFPs on Linux, layered over the low-level USB transport in `io/hpmud`.
There is no macOS backend, and CUPS / `sane` cannot reach this device on recent
macOS for the same sandboxing reasons the printer path bypasses CUPS.

- HPLIP project: <https://developers.hp.com/hp-linux-imaging-and-printing>
- SANE `hpaio` backend man page: `man sane-hpaio`

## Path to a working scanner

Two viable routes, not mutually exclusive:

1. **Capture then replay.** Have a hardware owner record one full flatbed scan
   over USB (USBPcap on Windows, or a Linux `usbmon` capture driving `scanimage`
   through `hpaio`). Decode the command/data phases into the table in
   `PROTOCOL.md`, then implement the real sequence where `hp-scan.c` marks the
   TODO.
2. **Port `hpaio`.** Read the relevant HPLIP `scan/sane/` transport for this
   model and reimplement the handshake on libusb directly. A capture is still
   valuable to validate the port against real bytes.

Either way the transport (open device, claim interface 0, bulk OUT/IN) is what
`hp-scan.c` already scaffolds; only the protocol content is missing.

## Files here

- `hp-scan.c` — libusb probe/skeleton. Opens VID `0x03f0` + PID (arg), selects
  the vendor-specific scan interface (interface 0, class `0xFF`), enumerates and
  prints its endpoint descriptors, claims it, and runs a stubbed `scan_probe()`
  that sends a placeholder command and logs the bulk-IN / status read-back.
  Compile:
  ```bash
  cc -O2 -Wall -I"$(brew --prefix)/include" scanner/hp-scan.c \
     -L"$(brew --prefix)/lib" -lusb-1.0 -o /tmp/hp-scan
  ```
  Run (M1005 example): `/tmp/hp-scan 0x03f0 0x3b17`. It claims interface 0; it
  is **not** setuid and must not be installed setuid.
- `PROTOCOL.md` — capture instructions and a table for the hardware owner to
  fill in with observed command/data phases.

## License

GPL-2.0, matching the rest of the project and the bundled foo2zjs.
