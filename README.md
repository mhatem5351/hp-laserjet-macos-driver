# hp-laserjet-mac-driver

Print to a **host-based HP LaserJet** on modern macOS (Apple Silicon & Intel),
including macOS versions where Apple ships no driver and CUPS can no longer
drive the printer.

These printers speak one of two host-based raster protocols. This driver
auto-detects the attached model and drives both:

| Model                       | USB PID  | Protocol / driver | Raster   |
|-----------------------------|----------|-------------------|----------|
| LaserJet 1000               | `0x0517` | ZjStream `foo2zjs`| 600×600  |
| LaserJet 1005               | `0x1317` | ZjStream `foo2zjs`| 600×600  |
| LaserJet 1018               | `0x4117` | ZjStream `foo2zjs`| 600×600  |
| LaserJet 1020               | `0x2b17` | ZjStream `foo2zjs`| 600×600  |
| **P1102 / P1102w** (tested) | `0x002a` | ZjStream `foo2zjs`| 1200×600 |
| P1566 / P1606               | `0x092a` | ZjStream `foo2zjs`| 1200×600 |
| P1005                       | `0x3d17` | XQX `foo2xqx`     | 1200×600 |
| P1006                       | `0x3e17` | XQX `foo2xqx`     | 1200×600 |
| P1007 / P1008               | `0x4817` / `0x4917` | XQX `foo2xqx` | 1200×600 |
| P1505 / P1505n              | `0x3f17` / `0x4017` | XQX `foo2xqx` | 1200×600 |
| **M1005 MFP** (tested)      | `0x3b17`¹ | XQX `foo2xqx`    | 1200×600 |

The watcher reads the attached printer's USB product id (or product name) and
picks the matching **driver**, firmware blob and raster geometry automatically.

> **Hardware-tested: P1102 and M1005 MFP.** The M1005 was verified on macOS
> Tahoe 26.5.2 (Apple M5, via a USB 2.0 hub). Every other row shares the same
> code path but is unverified on real hardware — reports welcome (see
> `CONTRIBUTING.md`).
>
> ¹ The M1005 MFP's USB product id is not published in the driver's own device
> table; `0x3b17` (confirmed on the tested unit) is used, and the watcher also
> matches the M1005 by product name so detection works regardless. Its print
> engine is P1005-class and it reuses the P1005 XQX firmware (`sihpP1005.dl`) —
> there is no dedicated M1005 blob in the HPLIP plugin, and none is needed.

## Why this exists

These HP LaserJets are **host-based** (GDI): no PostScript or PCL interpreter
and no on-board firmware. They come in two raster dialects — ZjStream (LJ
1000–1020, P1102, P1566) and XQX (P1005–P1505, M1005 MFP). Every time such a
printer powers on it must be fed a firmware blob over USB, and every page must
be rasterised on the computer. On recent macOS this stopped working because:

- Apple no longer bundles an HP driver for this model.
- The printer has **no AirPrint**.
- The macOS CUPS `usb` backend aborts mid-transfer with this printer.
- macOS **sandboxes CUPS filters**, so a third-party filter in `/usr/local`
  can't exec or touch USB (`Operation not permitted`).

So this project skips CUPS entirely. It rasterises with Ghostscript, converts to
the printer's protocol with `foo2zjs` (ZjStream) or `foo2xqx` (XQX), and pushes
the bytes straight to the printer over `libusb`. A macOS **PDF Service** wires
it into the normal Print dialog.

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
        ├─ detect  : read attached printer's USB product id/name → model row
        ├─ fwload  : upload that model's firmware blob over USB (idempotent)
        ├─ gs      : PDF → monochrome raster (auto A4 / Letter, model geometry)
        ├─ foo2zjs : raster → ZjStream  (-z2 -P -L0)   [ZjStream models]
        │  foo2xqx : raster → XQX       (-P -L0)       [XQX models]
        └─ fwload  : stream the result to the printer's bulk-OUT endpoint
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
- USB detection uses `ioreg` (not `system_profiler`, which returns nothing on
  macOS Tahoe). `fwload` targets the USB Printer-class interface, so MFPs like
  the M1005 print from the right interface, not the scanner one.
- Auto-detects **A4** vs **US Letter** from the PDF. Other sizes fall back to
  Letter — add them to the paper table in `p1102-watcher.sh` if you need them.
- **Hardware-tested: P1102 and M1005 MFP.** Other models use the same mechanism
  (ZjStream via `foo2zjs`, or XQX via `foo2xqx`) and *should* work; the
  `model_row` table in `p1102-watcher.sh` (USB PID → driver + firmware +
  resolution) is where to fix or add a model if yours misbehaves.
- **Faint stripes / ghosting** are the toner cartridge (HP **CE285A / 85A**),
  not this software. Shake the cartridge; replace if it persists.
- Monochrome only (they're mono lasers).

## Uninstall

```bash
./uninstall.sh
```

## Credits

- [`foo2zjs`](http://foo2zjs.rkkda.com) by Rick Richardson — the ZjStream and
  XQX (`foo2xqx`) drivers and firmware tooling (GNU GPL).
- Firmware blobs are HP's, extracted from the HPLIP plugin at install time
  (one per supported model; the M1005 MFP reuses the P1005 blob).

## License

Installer, watcher, PDF Service and `fwload.c` in this repo: **GPL-2.0**
(matching the bundled `foo2zjs`). Firmware and `foo2zjs` retain their own
licenses.
