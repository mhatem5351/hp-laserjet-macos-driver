<!--
Thanks for helping verify a model! This turns a ⚠️ untested row in TESTED.md
into ✅ verified or ❌ broken — both are useful. Fill in what you can.

IMPORTANT: scrub personal data before submitting — your macOS username, home
path, hostname, and the printer serial number. The driver stores none of these;
please keep it that way in reports too (see CONTRIBUTING.md).
-->

## Printer

- **Model** (e.g. LaserJet 1020, P1005, M1005 MFP):
- **USB PID** — run `ioreg -p IOUSB -l | grep idProduct` and paste the value for
  the HP printer (VID `0x03f0`); note it in hex (e.g. `0x2b17`):
- **Matched in `model_row()`?** (yes / no / matched by product name):

## Environment

- **macOS version** (e.g. Tahoe 26.5.2):
- **Chip** (Apple Silicon model, e.g. M5 / Intel):
- **Connection** (direct USB / USB hub — note hub speed if relevant):

## Result

- **Firmware uploaded over USB?** (yes / no / error):
- **Did it print?** (yes / no):
- **Page correctness** (scaling, margins, orientation, blank/garbled, missing
  content):
- **Overall status** (✅ verified / ❌ broken):

## Scrubbed `watcher.log` tail

<!--
Paste the relevant tail of ~/HP-LaserJet-spool/watcher.log.
Scrub: username, home path, hostname, printer serial.
-->

```
(paste here)
```

## Anything else

<!-- Workarounds tried, related issues, cartridge/toner notes, etc. -->

/label ~"test report"
