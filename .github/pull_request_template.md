<!--
For adding a new model_row() entry or fixing an existing one (PID, driver,
firmware, or geometry) in hp-laserjet-watcher.sh. Keep the scope tight — one
logical change per PR. For changes other than a model row, delete the sections
that do not apply.
-->

## What this changes

<!-- Which model, and what's added or fixed (PID / driver / firmware / geometry). -->

## Model row

- **Model**:
- **USB PID** (source: `ioreg -p IOUSB -l | grep idProduct`, in hex):
- **Protocol / driver** (`foo2zjs` ZjStream / `foo2xqx` XQX):
- **Firmware blob** (`.dl` name — or which model's blob it reuses):
- **Raster geometry** (`RES` + `XSCALE`, e.g. `1200x600 2`):

## Checklist

- [ ] PID confirmed on real hardware (`ioreg -p IOUSB -l | grep idProduct`), not
      guessed. State the source in the description.
- [ ] `model_row()` entry added/fixed in `hp-laserjet-watcher.sh` (and
      `name_row()` if the PID is undocumented and needs a product-name fallback).
- [ ] Firmware mapping present in `install.sh` `FW_MAP` (blob `.dl` ← plugin
      `.fw.gz`), or the row reuses an already-mapped blob (note which).
- [ ] Tested — note **macOS version + chip** and the **exact printer model** in
      this description.
- [ ] `TESTED.md` row updated (status, tester, macOS version, notes).
- [ ] `CHANGELOG.md` updated under `[Unreleased]`.
- [ ] No personal data (username, home path, hostname, printer serial).

## Tested on

- **macOS version + chip**:
- **Printer model**:
