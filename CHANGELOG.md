# Changelog

All notable changes to **hp-laserjet-mac-driver** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Renamed the p1102-specific identifiers to generic `hp-laserjet` names**, now
  that the driver covers the whole host-based family, not only the P1102:
  `p1102-watcher.sh` → `hp-laserjet-watcher.sh`,
  `com.p1102.watcher` → `com.hp-laserjet.watcher` (launchd label),
  the spool dir `~/P1102-spool` → `~/HP-LaserJet-spool`, and the Print-dialog
  entry "Print on P1102" → "Print on HP LaserJet".
  **Upgrading breaks an existing install** (the launchd label and spool path
  change): run the *old* `./uninstall.sh` first, then the new `./install.sh`.
- **Internal refactor for extensibility (no behaviour change).** The inline
  converter-flag block became a `build_conv_flags()` function, config loading
  moved into `load_config()`, and a `read_job_opts()` per-job hook (currently a
  no-op placeholder) was wired into the job loop. The flag strings emitted are
  byte-identical to before.

### Added
- **Optional configuration file.** The watcher now reads
  `~/.config/hp-laserjet/config` (a `KEY=value` shell fragment, overridable via
  `HP_LASERJET_CONFIG`) for defaults such as `PAPER`, `DENSITY` and
  `DEFAULT_COPIES`, and recognises a per-job `job-<ts>.opts` sidecar for per-job
  overrides. Both are optional; with neither present the driver behaves exactly
  as before. Documented in `docs/CONFIG.md`. This is groundwork for upcoming
  duplex, density and multi-printer features.
- **XQX protocol support (`foo2xqx`)** alongside ZjStream. The host-based
  LaserJets come in two raster dialects; the driver now handles both. XQX
  models: P1005 (`0x3d17`), P1006 (`0x3e17`), P1007 (`0x4817`),
  P1008 (`0x4917`), P1505 (`0x3f17`), P1505n (`0x4017`).
- **HP LaserJet M1005 MFP** support via `foo2xqx` (`0x3b17`, matched by product
  name too since its PID is undocumented). Reuses the P1005 XQX firmware — no
  dedicated M1005 blob exists in the HPLIP plugin. **Untested on hardware.**
- **Multi-model auto-detection.** The watcher reads the attached printer's USB
  product id (or product name) and selects the matching driver, firmware blob
  and raster geometry. Falls back to P1102 when nothing supported is detected.
- Installer builds `foo2xqx` in addition to `foo2zjs`, and fetches the whole
  family's firmware blobs from the HPLIP plugin (using any bundled in
  `vendor/`), skipping any a given plugin release lacks.
- `fwload` accepts optional `VID PID` arguments (`fwload blob [VID] [PID]`);
  the watcher passes the detected printer's ids. Defaults remain the P1102.
- **Parsed printer status read-back.** `fwload` now accumulates the bulk-IN
  reply after a transfer and echoes any human-readable ASCII lines as
  `status-line: `, and any line carrying a recognized PJL token (`CODE=`,
  `DISPLAY=`, `ONLINE`, `TONER`, `PAGECOUNT`, `PAGES`) as `status-kv: `. Binary
  or empty replies keep the previous byte-count summary. These lines flow into
  `~/HP-LaserJet-spool/watcher.log`, so a status poller / menu-bar can parse
  device state without extra plumbing. Read bounds are unchanged (whole
  `wMaxPacketSize` buffers, 500ms timeout, capped at 64 reads) and the read-back
  never affects the exit status.
- **`fwload --status [VID] [PID]` query mode.** Skips sending any blob: opens the
  printer, writes a PJL status query (`@PJL INFO STATUS` / `@PJL INFO PAGECOUNT`
  wrapped in the UEL escape) to bulk-OUT, then reads and prints the reply using
  the same `status-line: ` / `status-kv: ` parsing. Lets the watcher or a
  menu-bar poll status without printing a page. The positional
  `fwload blob [VID] [PID]` mode is unchanged.

### Fixed
- **Never guess a default model when no printer is detected.** The watcher used
  to fall back to the P1102, so a job queued while the printer was off or
  re-enumerating got driven with the wrong protocol/firmware at the wrong
  interface, silently. It now logs "no supported printer detected — deferring"
  and leaves the jobs in the spool for the next print/detection event.
- **Status read-back drains the full reply.** A single 64-byte bulk-IN read got
  `LIBUSB_ERROR_OVERFLOW` because the printer answers with more than that.
  `fwload` now reads whole `wMaxPacketSize` buffers and loops until a short
  packet, reporting the real byte count ("printer replied") — the actual accept
  signal that was the point of the read-back.
- **USB detection now uses `ioreg` instead of `system_profiler SPUSBDataType`.**
  On macOS Tahoe (26.x) `system_profiler SPUSBDataType` returns nothing at all
  (empty, no error), so the watcher mis-detected every printer — including the
  P1102 — and silently fell back to the wrong protocol/firmware. `ioreg -p
  IOUSB` works and reports idProduct/idVendor in decimal (reformatted to hex).
  Fixes detection in both `hp-laserjet-watcher.sh` and `install.sh`.
  Thanks to the M1005 tester for the diagnosis.
- **`fwload` selects the USB Printer-class interface, not interface 0.** On
  multifunction MFPs (M1005, M1120) interface 0 is a vendor-specific (class
  0xFF) scanner/ACL interface that also exposes bulk endpoints; writing there
  succeeds silently but never prints. `fwload` now prefers the interface with
  `bInterfaceClass == 7` (USB Printer), falling back to the first bulk-OUT
  interface for single-function models like the P1102. Adds a best-effort
  bulk-IN status read-back so a wrong-interface write is no longer
  indistinguishable from success.
- **Corrected the model/PID table.** An earlier draft listed the P-series with
  the wrong USB product ids (`0x1317`/`0x1517`/`0x0d17`) and wrongly as
  ZjStream. Those PIDs are actually the old ZjStream LJ 1005 etc.; the P-series
  are XQX at `0x3d17`/`0x3e17`/`0x3f17`. ZjStream firmware names were likewise
  corrected (`sihp1000.dl`…`sihp1020.dl`). Only P1102 (`0x002a`) was right.

### Changed
- Only the P1102 is hardware-tested; every other model (ZjStream or XQX) shares
  the same code path but is unverified. See the `model_row` table in
  `hp-laserjet-watcher.sh`.

## [1.0.0]

First public release.

### Added
- Non-CUPS print pipeline for the HP LaserJet P1102 / P1102w on modern macOS
  (Apple Silicon and Intel), where Apple ships no driver and the CUPS `usb`
  backend can no longer drive the printer.
- `install.sh` — checks/installs Homebrew dependencies (`ghostscript`,
  `libusb`, `poppler`), builds `foo2zjs` and `fwload`, downloads the P1102
  firmware blob from the HPLIP plugin, and wires up a launchd watcher plus a
  Print-dialog PDF Service. No personal data is embedded — user, home and
  printer serial are detected at install time.
- `uninstall.sh` — removes everything the installer created.
- `fwload` — a small `libusb` firmware/data pusher that streams bytes to the
  printer's bulk-OUT endpoint (matched by USB VID `0x03f0` / PID `0x002a`, so
  no per-machine serial is stored).
- `p1102-watcher.sh` — the unsandboxed worker: firmware upload (idempotent),
  Ghostscript rasterisation, `foo2zjs` ZjStream conversion, USB delivery.
  Auto-detects A4 vs US Letter from the PDF and uses the printer's asymmetric
  1200×600 raster.
- `PDFService/` Automator Print Plugin — adds "Print on P1102" to the standard
  macOS Print dialog (Cmd+P → PDF ▾).
- README with full architecture and rationale.

### Known issues
- Faint stripes / ghosting are the toner cartridge (HP CE285A / 85A), not the
  software.
- Page sizes other than A4 / US Letter fall back to Letter.

[Unreleased]: https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/compare/v1.0.0...main
[1.0.0]: https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/tags/v1.0.0
