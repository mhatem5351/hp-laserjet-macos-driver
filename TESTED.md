# Tested models — compatibility matrix

A living record of which host-based HP LaserJets have actually been driven by
this driver, on what macOS, by whom. The driver supports ~13 models that share
one of two raster code paths (ZjStream via `foo2zjs`, XQX via `foo2xqx`), but
only two have been verified on real hardware. **Community reports are the way
this table grows** — if yours works (or doesn't), please send a report.

## How to read this

- **Status**
  - ✅ **verified** — confirmed printing correctly on real hardware, with a tester
    and macOS version recorded.
  - ⚠️ **untested** — shares the same code path as a verified model but nobody has
    reported it yet. Should work; unproven. This is the default for most rows.
  - ❌ **broken** — a report showed it does not work as-is (see Notes for what and
    any workaround / open issue).
- **USB PID** is the printer's `idProduct` under USB VID `0x03f0` (HP). It maps to
  a `model_row()` entry in `hp-laserjet-watcher.sh`, which selects driver +
  firmware blob + raster geometry.
- **Firmware blob** is the installed `.dl` name (host-based printers have no
  on-board firmware; a blob is uploaded over USB on every power-on). Some models
  reuse another model's blob — e.g. the M1005 MFP and P1007 reuse P1005's.

## Matrix

| Model            | USB PID   | Protocol | Firmware blob   | Status       | Tester        | macOS version           | Notes |
|------------------|-----------|----------|-----------------|--------------|---------------|-------------------------|-------|
| LaserJet 1000    | `0x0517`  | ZjStream | `sihp1000.dl`   | ⚠️ untested  | —             | —                       | 600×600 symmetric. |
| LaserJet 1005    | `0x1317`  | ZjStream | `sihp1005.dl`   | ⚠️ untested  | —             | —                       | 600×600 symmetric. |
| LaserJet 1018    | `0x4117`  | ZjStream | `sihp1018.dl`   | ⚠️ untested  | —             | —                       | 600×600 symmetric. |
| LaserJet 1020    | `0x2b17`  | ZjStream | `sihp1020.dl`   | ⚠️ untested  | —             | —                       | 600×600 symmetric. |
| P1102 / P1102w   | `0x002a`  | ZjStream | `sihpP1102.dl`  | ✅ verified  | pauyedin      | (hardware-tested)       | 1200×600 asymmetric. Original tested unit. |
| P1566 / P1606    | `0x092a`  | ZjStream | `sihpP1566.dl`  | ⚠️ untested  | —             | —                       | 1200×600 asymmetric. |
| P1005            | `0x3d17`  | XQX      | `sihpP1005.dl`  | ⚠️ untested  | —             | —                       | 1200×600 asymmetric. |
| P1006            | `0x3e17`  | XQX      | `sihpP1006.dl`  | ⚠️ untested  | —             | —                       | 1200×600 asymmetric. |
| P1007            | `0x4817`  | XQX      | `sihpP1005.dl`  | ⚠️ untested  | —             | —                       | Reuses P1005 firmware. |
| P1008            | `0x4917`  | XQX      | `sihpP1006.dl`  | ⚠️ untested  | —             | —                       | Reuses P1006 firmware. |
| P1505            | `0x3f17`  | XQX      | `sihpP1505.dl`  | ⚠️ untested  | —             | —                       | 1200×600 asymmetric. |
| P1505n           | `0x4017`  | XQX      | `sihpP1505.dl`  | ⚠️ untested  | —             | —                       | Reuses P1505 firmware. |
| M1005 MFP        | `0x3b17`¹ | XQX      | `sihpP1005.dl`  | ✅ verified  | M1005 tester  | Tahoe 26.5.2 (Apple M5) | Reuses P1005 firmware; also matched by product name. Verified via a USB 2.0 hub. |

¹ The M1005 MFP's USB product id is not published in the driver's own device
table. `0x3b17` (confirmed on the tested unit) is used, and the watcher also
matches the M1005 by product name (`name_row()`), so detection works even if a
given unit reports a different PID.

## Submit a report

You don't need the hardware you're missing — you need the hardware you *have*.
Every ⚠️ row is one report away from becoming ✅ (or ❌, which is just as useful).

1. Open a **Test Report** issue on GitLab (use the *Test Report* template).
2. Fill in: model, USB PID (`ioreg -p IOUSB -l | grep idProduct`), your macOS
   version + chip, whether firmware uploaded, whether it printed, page
   correctness, and a scrubbed tail of `~/HP-LaserJet-spool/watcher.log`.
3. **Scrub personal data** — username, home path, hostname, printer serial. The
   driver stores none of these; please keep reports the same (see
   `CONTRIBUTING.md`).

If you fix or add a model row, open a merge request using the *Add or Fix Model*
template. Either way, this table gets updated to credit your report.
