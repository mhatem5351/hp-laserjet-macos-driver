# p1102-mac-driver

Print to a **host-based HP LaserJet** — the P1000/P1100 "ZjStream" family — on
modern macOS (Apple Silicon & Intel), including macOS versions where Apple ships
no driver and CUPS can no longer drive the printer.

Named after the P1102 (the model it was first built and tested on), it now
auto-detects and drives the whole family:

| Model             | USB PID  | Raster   |
|-------------------|----------|----------|
| P1005             | `0x1317` | 600×600  |
| P1006/P1007/P1008 | `0x1517` | 600×600  |
| P1505             | `0x0d17` | 600×600  |
| **P1102 / P1102w** (tested) | `0x002a` | 1200×600 |
| P1566 / P1606     | `0x092a` | 1200×600 |

The watcher reads the attached printer's USB product id and picks the matching
firmware blob and raster geometry automatically. Only the P1102 is
hardware-tested; the others share the same host-based ZjStream path and firmware
mechanism, so they *should* work — reports welcome (see `CONTRIBUTING.md`).

## Why this exists

The HP LaserJet P1000/P1100 series is **host-based** (GDI / "ZjStream"): it has
no PostScript or PCL interpreter and no on-board firmware. Every time it powers
on it must be fed a firmware blob over USB, and every page must be rasterised on
the computer. On recent macOS this stopped working because:

- Apple no longer bundles an HP driver for this model.
- The printer has **no AirPrint**.
- The macOS CUPS `usb` backend aborts mid-transfer with this printer.
- macOS **sandboxes CUPS filters**, so a third-party filter in `/usr/local`
  can't exec or touch USB (`Operation not permitted`).

So this project skips CUPS entirely. It rasterises with Ghostscript, converts to
ZjStream with `foo2zjs`, and pushes the bytes straight to the printer over
`libusb`. A macOS **PDF Service** wires it into the normal Print dialog.

## How it works

```
Cmd+P ▸ PDF ▾ ▸ "Print on P1102"
        │  (Automator Print Plugin, runs in the print sandbox)
        ▼
  copies the PDF into ~/P1102-spool/
        │
        ▼
  launchd WatchPaths agent  ──►  p1102-watcher.sh   (runs unsandboxed)
        │
        ├─ detect  : read attached printer's USB product id → model/geometry
        ├─ fwload  : upload that model's firmware blob over USB (idempotent)
        ├─ gs      : PDF → monochrome raster (auto A4 / Letter, model geometry)
        ├─ foo2zjs : raster → ZjStream  (-z2 -P -L0)
        └─ fwload  : stream ZjStream to the printer's bulk-OUT endpoint
```

The printer is matched by USB **VID 0x03f0** plus one of the family product ids
(see the table above), so no per-machine serial number is stored anywhere. If
no supported printer is detected, the watcher falls back to P1102 settings.

## Install

```bash
git clone <this-repo> p1102-mac-driver
cd p1102-mac-driver
./install.sh
```

Requirements (the installer checks and installs the Homebrew ones):

- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)
- `ghostscript`, `libusb`, `poppler` (installed automatically)

Then print from any app: **Cmd+P → PDF ▾ (bottom-left) → "Print on P1102"**.

## Notes & limitations

- **First page after power-on** is slow (~20 s) while firmware uploads. Normal.
- Auto-detects **A4** vs **US Letter** from the PDF. Other sizes fall back to
  Letter — add them to the paper table in `p1102-watcher.sh` if you need them.
- **Only the P1102 is hardware-tested.** Other models in the table use the same
  firmware/ZjStream mechanism and *should* work; the `model_row` table in
  `p1102-watcher.sh` (USB PID → firmware + resolution) is where to fix or add a
  model if yours misbehaves.
- **Faint stripes / ghosting** are the toner cartridge (HP **CE285A / 85A**),
  not this software. Shake the cartridge; replace if it persists.
- Monochrome only (they're mono lasers).

## Uninstall

```bash
./uninstall.sh
```

## Credits

- [`foo2zjs`](http://foo2zjs.rkkda.com) by Rick Richardson — the ZjStream
  driver and firmware tooling (GNU GPL).
- Firmware blobs are HP's, extracted from the HPLIP plugin at install time
  (one per supported model).

## License

Installer, watcher, PDF Service and `fwload.c` in this repo: **GPL-2.0**
(matching the bundled `foo2zjs`). Firmware and `foo2zjs` retain their own
licenses.
