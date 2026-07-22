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
Cmd+P ▸ PDF ▾ ▸ "Print on HP LaserJet"
        │  (Automator Print Plugin, runs in the print sandbox)
        ▼
  copies the PDF into ~/HP-LaserJet-spool/
        │
        ▼
  launchd WatchPaths agent  ──►  hp-laserjet-watcher.sh   (runs unsandboxed)
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
no supported printer is detected, the watcher leaves the queued jobs in the
spool and defers — it never guesses a model — so a job queued while the printer
is off or re-enumerating is not driven with the wrong protocol/firmware.

### Multiple printers

If **several** supported HP LaserJets are attached at once, the watcher detects
them all and needs to choose a target (the sandboxed Print dialog can't tag a
job with a destination). Set `PRINTER` in `~/.config/hp-laserjet/config` to a
USB product id (`PRINTER=0x3d17`) or a product-name substring (`PRINTER=p1005`)
to pin all jobs to one printer; a `PRINTER=` line in a per-job
`job-<ts>.opts` sidecar routes a single job. With `PRINTER` unset, the watcher
falls back to a deterministic primary (the lowest product id present) and logs
which printer it chose and which it ignored. With only one printer attached this
is all inert — behaviour is unchanged. See
[`docs/CONFIG.md`](docs/CONFIG.md#selecting-a-printer-when-several-are-connected).

## Install

```bash
git clone https://gitlab.com/pauyedin/hp-laserjet-mac-driver.git
cd hp-laserjet-mac-driver
./install.sh
```

Requirements (the installer checks and installs the Homebrew ones):

- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)
- `ghostscript`, `libusb`, `poppler` (installed automatically)

Then print from any app: **Cmd+P → PDF ▾ (bottom-left) → "Print on HP LaserJet"**.

### Install via Homebrew

Prefer `brew`? A Homebrew tap is available. One copy-paste line:

```bash
brew tap pauyedin/hp-laserjet https://gitlab.com/pauyedin/homebrew-hp-laserjet && brew install hp-laserjet-mac-driver && hp-laserjet-install
```

Three stages: **`brew tap`** points Homebrew at the tap repo (needed once —
after that, a bare `brew install hp-laserjet-mac-driver` resolves);
**`brew install`** stages the driver and pulls in `ghostscript`, `libusb`,
`poppler`; and **`hp-laserjet-install`** runs the bundled `install.sh`, which
prompts for your password to do the privileged setup (setuid-root `fwload`,
launchd agent, PDF Service) that can't run inside `brew install`.

> A bare `brew install hp-laserjet-mac-driver` with **no tap** would only work
> if this formula were accepted into `homebrew/core` — unlikely for a
> macOS-only, setuid-root printer driver whose caveats run an installer — so the
> tap is the supported route.

See [`HOMEBREW.md`](HOMEBREW.md) for the full walkthrough, uninstall steps, and
the maintainer release checklist.

## Configuration

The driver works with no configuration. Optionally, an
`~/.config/hp-laserjet/config` file (`KEY=value`) can set defaults such as
`PAPER`, print-quality controls `DENSITY` (`1`–`5`, the converter `-T` darkness
flag) and `ECONOMODE` (`on`/`off`, toner-save `-t`), copies/layout defaults
`DEFAULT_COPIES` / `DEFAULT_DUPLEX` / `DEFAULT_NUP`, and `PRINTER` (which printer
to use when several are attached), paper geometry `PAPER` / `SCALE` / `MARGIN`;
a per-job `job-<ts>.opts` sidecar can carry per-job `COPIES` / `DUPLEX` / `NUP` /
`DENSITY` / `ECONOMODE` / `PRINTER` / `PAPER` / `SCALE` / `MARGIN` overrides. The macOS print dialog's copies/two-sided/layout controls are **not**
read (the PDF Service is sandboxed) — use the config file or sidecar instead.
Note most supported models are simplex-only (duplex is passed through and
logged) and the converters have no N-up (`NUP>1` is ignored). See
[`docs/CONFIG.md`](docs/CONFIG.md) for the full key reference. With neither
config nor sidecar present, behaviour is unchanged.

## Notifications

The watcher posts a macOS notification when a job finishes — "Printed on …" on
success, a short failure reason otherwise (including when no supported printer is
on the bus and a job is left queued). Set `NOTIFY` in the config file to
`all` (default), `errors` (failures only), or `none` to silence them. Notifications
are best-effort UX and never change whether or how a job prints.

## Notes & limitations

- **First page after power-on** is slow (~20 s) while firmware uploads. Normal.
- USB detection uses `ioreg` (not `system_profiler`, which returns nothing on
  macOS Tahoe). `fwload` targets the USB Printer-class interface, so MFPs like
  the M1005 print from the right interface, not the scanner one.
- **Paper size** auto-detects **A4** vs **US Letter** from the PDF by default.
  Set `PAPER` (config or per-job sidecar) to force a size: `letter`, `a4`,
  `legal`, `a5`, `executive`, `com10` (#10 envelope) or `dl` (DL envelope) —
  each maps to the printer's paper code and the correct raster grid. Anything
  unrecognised still falls back to Letter. `SCALE` (percent) and `MARGIN`
  (points) further adjust the page during rasterisation. See
  [`docs/CONFIG.md`](docs/CONFIG.md).
  **`letter` and `a4` are hardware-verified; `legal`, `a5`, `executive`,
  `com10` and `dl` are not yet tested on real hardware** — their paper codes and
  grids match the converters' tables but are unproven, so treat them as
  experimental and report results.
- **Hardware-tested: P1102 and M1005 MFP.** Other models use the same mechanism
  (ZjStream via `foo2zjs`, or XQX via `foo2xqx`) and *should* work; the
  `model_row` table in `hp-laserjet-watcher.sh` (USB PID → driver + firmware +
  resolution) is where to fix or add a model if yours misbehaves.
- **Faint stripes / ghosting** are the toner cartridge (HP **CE285A / 85A**),
  not this software. Shake the cartridge; replace if it persists.
- Monochrome only (they're mono lasers).

## Printer status

`fwload` can query the printer's status without printing a page:

```bash
/usr/local/share/foo2zjs/fwload --status 0x03f0 <PID>
```

`<PID>` is the printer's USB product id (e.g. `0x002a` for the P1102; see the
`model_row` table in `hp-laserjet-watcher.sh`). This sends a PJL status query
(`@PJL INFO STATUS` / `@PJL INFO PAGECOUNT`) to the printer and prints its reply:

- `status-line: …` — any human-readable text line the printer returned.
- `status-kv: …` — lines carrying a recognized PJL token (`CODE=`, `DISPLAY=`,
  `ONLINE`, `TONER`, `PAGECOUNT`, `PAGES`), i.e. the parseable status values.
- A byte-count summary if the reply is binary or empty.

The same parsing runs automatically after every job, so these `status-line:` /
`status-kv:` lines also appear in `~/HP-LaserJet-spool/watcher.log` — a status
poller or menu-bar can read device state straight from the log or by calling
`fwload --status`. It is best-effort and never affects whether a job succeeds.

## Compatibility & test reports

Only the P1102 and M1005 MFP are hardware-verified; every other model shares the
same code path but is unproven. [`TESTED.md`](TESTED.md) tracks the full
per-model status (✅ verified / ⚠️ untested / ❌ broken) with tester and macOS
version.

**If you have any of the untested models, a report is the single most useful
contribution you can make** — working *or* not. Open a *Test Report* issue
(GitLab issue template) with your model, USB PID, macOS version and a scrubbed
`watcher.log` tail; to add or fix a `model_row()` entry, use the *Add or Fix
Model* merge-request template. Both live under `.gitlab/`. See
`CONTRIBUTING.md`.

## Menu-bar app (optional)

A small native macOS menu-bar (`NSStatusItem`) utility lives in
[`menubar/`](menubar/). It shows a printer icon with printer online/offline
status, the queued job count, and one-click actions to retrigger the watcher,
open the spool folder, view the log, and clear the spool. It is a standalone
single-file Swift executable (built with `swiftc`, no Xcode project) and never
touches USB — all printing stays in the watcher. See
[`menubar/README.md`](menubar/README.md) for build, run and launch-at-login
instructions. It shows live per-job progress, a toner / page-count badge (read
from the PJL status lines in the log), and queue actions (cancel a job,
reprint-last), in addition to online/offline status and the spool actions.

## System Settings & AirPrint (optional CUPS backend)

An optional CUPS *spooling* backend in [`cups-backend/`](cups-backend/) makes
the printer appear in **System Settings › Printers** and lets you
**AirPrint-share** it to iPhones and iPads on your network. It is completely
independent of the core driver — if you never install it, nothing changes.

Crucially it **never touches USB and never execs the driver**: it only writes
the incoming job as `job-<ts>.pdf` into `~/HP-LaserJet-spool/` — the same intake
the PDF Service uses — so the real work still happens only in the unsandboxed
watcher. That is why it does *not* reintroduce the "CUPS can't drive this
printer" problem. Install it separately:

```bash
sudo cups-backend/install-cups-backend.sh
```

See [`cups-backend/README.md`](cups-backend/README.md) for the queue name,
AirPrint sharing steps, and uninstall.

## Scanner (M1005 MFP) — experimental scaffolding

[`scanner/`](scanner/) holds **scaffolding only — there is no working scan yet.**
It contains a libusb probe skeleton (`hp-scan.c`) that opens the M1005's
vendor-specific scan interface and dumps its endpoint descriptors, plus protocol
notes. The actual scan command/data handshake is not implemented: it needs a USB
capture (or a port of SANE's `hpaio`). `scanner/PROTOCOL.md` is the template a
hardware owner can use to record that capture. It is not built or installed by
`install.sh`. See [`scanner/README.md`](scanner/README.md).

## Self-test / troubleshooting

`hp-laserjet-doctor` runs a quick end-to-end diagnostic and prints a PASS/FAIL
summary per check. `install.sh` puts it on your `PATH`:

```bash
hp-laserjet-doctor
```

(or run it in place: `/usr/local/share/foo2zjs/hp-laserjet-doctor.sh`).

With no flags it is **entirely read-only** — it never touches the printer over
USB. It checks:

- **Dependencies** — `ghostscript` (gs), `libusb`, `poppler` (pdfinfo), and the
  installed `fwload` (including its setuid-root bit) and the `foo2zjs`/`foo2xqx`
  converters.
- **Printer detection** — reads the attached HP LaserJet over `ioreg` (VID
  `0x03f0`), exactly as the watcher does, and prints the matched model row
  (driver / firmware / RES / XSCALE). If **no** supported printer is on the bus
  it reports that and exits non-zero with guidance — it never guesses a model.
- **Firmware (dry-run)** — verifies the firmware blob for the detected model is
  installed and reports its path and size.
- **Test-page conversion** — generates a one-page test PDF and runs a **dry**
  conversion (`gs` → `foo2zjs`|`foo2xqx`), reporting the raster byte count. No
  bytes are written to USB.

Flags for the on-hardware tests:

| Flag       | Effect                                                                 |
|------------|------------------------------------------------------------------------|
| `--push`   | also upload the detected model's firmware blob over USB (`fwload`).    |
| `--print`  | run the full pipeline and print the test page on the detected printer (implies `--push`). |
| `-h`, `--help` | show usage.                                                        |

The exit status is non-zero if any check fails (including no supported printer),
so it is safe to script.

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
