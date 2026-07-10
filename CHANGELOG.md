# Changelog

All notable changes to **p1102-mac-driver** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://gitlab.com/pauyedin/p1102-mac-driver/-/compare/v1.0.0...main
[1.0.0]: https://gitlab.com/pauyedin/p1102-mac-driver/-/tags/v1.0.0
