# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS driver for **host-based (GDI) HP LaserJet** printers, on OS versions where
Apple ships no driver and CUPS can no longer talk to the printer. It bypasses CUPS
entirely: rasterises with Ghostscript, converts to the printer's raster protocol,
and streams bytes straight to USB via libusb. A macOS PDF Service wires it into the
normal Cmd+P dialog.

Two host-based raster protocols are supported, auto-detected per attached printer:
- **ZjStream** (`foo2zjs`): LaserJet 1000/1005/1018/1020, P1102/P1102w, P1566/P1606
- **XQX** (`foo2xqx`): LaserJet P1005/P1006/P1007/P1008/P1505, M1005 MFP

**Hardware-tested: P1102 and M1005 MFP only.** All other models share the same code
path but are unverified.

## Build / install / test

No unit tests. This is verified by installing and printing on real hardware.

```bash
./install.sh      # builds everything, installs, loads launchd agent + PDF Service
./uninstall.sh    # removes all of it (leaves spool dir + Homebrew deps)
```

`install.sh` is the build. It: installs Homebrew deps (ghostscript, libusb, poppler);
untars `vendor/foo2zjs-src.tar.gz` and runs `make foo2zjs foo2xqx`; compiles
`src/fwload.c` against libusb; obtains firmware blobs; installs into
`/usr/local/share/foo2zjs`. Requires `sudo` (installs a setuid-root `fwload`).

Compile `fwload` alone while iterating:
```bash
cc -O2 -Wall -I"$(brew --prefix)/include" src/fwload.c \
   -L"$(brew --prefix)/lib" -lusb-1.0 -o /tmp/fwload
```

Drive the printer directly (bypass the watcher) to test USB path:
```bash
/tmp/fwload <blob> 0x03f0 <pid>     # firmware or raw raster; VID/PID hex
```

**Debugging is log-driven.** The watcher and PDF Service write to the spool dir:
- `~/HP-LaserJet-spool/watcher.log` — detection, per-job conversion, fwload results
- `~/HP-LaserJet-spool/stub.log` — PDF Service spooling
- `~/HP-LaserJet-spool/launchd.{out,err}` — launchd stdio

Retrigger the watcher without printing: drop a `job-*.pdf` into the spool dir
(launchd `WatchPaths` fires it).

## Architecture / data flow

```
Cmd+P ▸ PDF ▾ ▸ "Print on HP LaserJet"   (Automator print plugin, sandboxed)
  → copies PDF into ~/HP-LaserJet-spool/job-<ts>.pdf
launchd WatchPaths agent → hp-laserjet-watcher.sh   (unsandboxed)
  → detect model  → fwload firmware  → gs (PDF→pbmraw)  → foo2zjs|foo2xqx  → fwload raster→USB
```

Four moving parts, one per source file — understand them together:

1. **`PDFService/document.wflow`** — Automator print-plugin workflow. Runs *inside*
   the macOS print sandbox, so it can do nothing but copy the PDF macOS hands it on
   stdin into the spool. Writes `.incoming-*` then atomically renames to `job-*.pdf`
   so the watcher never sees a partial file. `Info.plist` registers it.

2. **`com.hp-laserjet.watcher.plist.in`** — launchd agent template. `__HOME__` /
   `__PREFIX__` are substituted by `install.sh`. `WatchPaths` on the spool dir wakes
   the watcher on any change; `ThrottleInterval 5` prevents a respawn loop.

3. **`hp-laserjet-watcher.sh`** — the unsandboxed worker; the brains. Detects the
   attached printer, picks driver+firmware+geometry, converts each queued PDF, and
   pushes it. See "watcher internals" below.

4. **`src/fwload.c`** — minimal libusb pusher. Streams any blob (firmware *or* page
   raster) to the printer's bulk-OUT endpoint. Installed **setuid root** because the
   user-context launchd agent must claim the USB interface.

### Why no CUPS
Modern macOS sandboxes CUPS filters (a filter in `/usr/local` gets
`Operation not permitted` on exec/USB), and the CUPS `usb` backend aborts mid-transfer
with these printers. The sandboxed PDF Service can only spool; all real work happens
in the unsandboxed launchd worker. This split is the central design constraint —
keep anything touching USB or execing binaries out of the PDF Service.

## Watcher internals (`hp-laserjet-watcher.sh`)

- **`model_row()`** is the source of truth: USB PID → `driver firmware RES XSCALE`.
  To add/fix a model, edit this table. `name_row()` is a product-name fallback for
  printers whose PID isn't in the table (the M1005, whose PID `0x3b17` isn't in the
  driver's own device table).
- **`XSCALE`**: `1` = symmetric 600×600; `2` = asymmetric 1200×600 (printer expects
  doubled pixels across). Multiplies the base paper-grid width in `grid_for()`.
- **Protocol flags differ**: `foo2zjs` takes `-z2` (ZjStream compression) and `-T5`;
  `foo2xqx` does not (`-P -L0` only). Branch on `$DRIVER`.
- **USB detection uses `ioreg`, NOT `system_profiler SPUSBDataType`** — the latter
  returns empty (no error) on macOS Tahoe 26.x, which silently broke detection. Same
  in `install.sh`'s `detect_model()`. Do not "simplify" back to system_profiler.
- **No-printer fallback deliberately defers**: if no supported printer is on the bus,
  the watcher leaves jobs queued and exits 0 rather than guessing a model — driving a
  job with the wrong protocol/firmware would misprint. Preserve this; don't add a
  default-model guess.
- Paper size auto-detected via `pdfinfo` page height (A4 842pt vs Letter 792pt);
  anything else falls back to Letter.

## fwload interface selection (`src/fwload.c`)

Two-pass endpoint scan, and it matters: on MFPs (M1005) interface 0 is a
vendor-specific (class 0xFF) scanner interface that *also* has bulk endpoints —
writing there succeeds silently but never prints. Pass 0 prefers a USB Printer-class
interface (`bInterfaceClass == 7`); pass 1 falls back to the first bulk-OUT of any
class (single-function models like the P1102 report no class-7 marker). The bulk-IN
status read-back is purely diagnostic (proves the printer reacted) and never fails
the transfer.

A printer that has dozed off can reject the first request with
`LIBUSB_ERROR_IO`/`PIPE`/`TIMEOUT`. `fwload` then does one `libusb_reset_device`
(re-opening the device if it re-enumerates) and retries — but **only if zero bytes
were sent**; resending a partially delivered job could print garbage or duplicates.
Around opening the blob file it drops to the real uid (`seteuid(getuid())`) and
restores root only for USB access, so the setuid binary can't read files the caller
couldn't.

## Firmware

Host-based printers have no on-board firmware — a blob must be uploaded over USB on
every power-on. Before each job the watcher asks the printer first
(`fwload --fwver VID PID`, the `FWVER` field of the IEEE-1284 device ID) and
uploads the blob **only** when it reports none or `PENDING`. Do not go back to a
blind push: a P1102 that already loaded firmware from its own flash wedges
(`FWVER:PENDING`, USB error `0xe00002ed`) when it is re-sent, until power-cycled.
If the query itself fails, the watcher skips the upload rather than pushing blind.

Blobs are HP's, extracted from the HPLIP plugin at install time (`FW_MAP` in `install.sh` maps
installed `.dl` name ← plugin `.fw.gz`). `install.sh` prefers blobs bundled in
`vendor/` (only `sihpP1102.dl` is committed); otherwise it downloads the HPLIP plugin
and slices the gzip out by magic-byte offset. The M1005 MFP reuses the P1005 blob —
no dedicated M1005 blob exists and none is needed.

## Conventions

- Identifiers are generic **`hp-laserjet`** (label `com.hp-laserjet.watcher`, spool
  `~/HP-LaserJet-spool`), not model-specific — a past refactor renamed the P1102
  originals. Keep new names family-generic.
- **No personal data in the repo**: user, home, and printer are all detected at
  install/run time. Never hardcode a serial, home path, or username.
- Everything in `/usr/local/share/foo2zjs` (outside the SIP-protected CUPS filter
  dir); the spool and launchd agent live under `$HOME`.
- License is **GPL-2.0** (matches bundled foo2zjs).
