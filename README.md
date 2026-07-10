# p1102-mac-driver

Print to an **HP LaserJet P1102 / P1102w** on modern macOS (Apple Silicon &
Intel) — including macOS versions where Apple ships no driver and CUPS can no
longer drive the printer.

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
        ├─ fwload  : upload firmware blob over USB (idempotent)
        ├─ gs      : PDF → 1200×600 monochrome raster (auto A4 / Letter)
        ├─ foo2zjs : raster → ZjStream  (-z2 -P -L0)
        └─ fwload  : stream ZjStream to the printer's bulk-OUT endpoint
```

The printer is matched by USB **VID 0x03f0 / PID 0x002a**, so no per-machine
serial number is stored anywhere.

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
- **Faint stripes / ghosting** are the toner cartridge (HP **CE285A / 85A**),
  not this software. Shake the cartridge; replace if it persists.
- Monochrome only (it's a mono laser).

## Uninstall

```bash
./uninstall.sh
```

## Credits

- [`foo2zjs`](http://foo2zjs.rkkda.com) by Rick Richardson — the ZjStream
  driver and firmware tooling (GNU GPL).
- Firmware blob is HP's, extracted from the HPLIP plugin at install time.

## License

Installer, watcher, PDF Service and `fwload.c` in this repo: **GPL-2.0**
(matching the bundled `foo2zjs`). Firmware and `foo2zjs` retain their own
licenses.
