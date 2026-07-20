# Contributing to hp-laserjet-mac-driver

Thanks for helping keep old HP LaserJet P1100-series printers alive on modern
macOS. Contributions of all kinds are welcome: bug reports, fixes, support for
more paper sizes, other host-based printers, and documentation.

## Reporting bugs

Open an issue on GitLab with:

- your macOS version and chip (Apple Silicon / Intel);
- the exact printer model (P1102, P1102w, or a related P1000/P1100 unit);
- what you did, what you expected, what happened;
- the relevant tail of `~/HP-LaserJet-spool/watcher.log`.

**Before pasting logs, scrub anything personal** — your macOS username, home
path, hostname, and the printer serial number. The project is deliberately
built to store none of these; please keep it that way in issues too.

## Submitting a test report

The biggest gap in this project is verification: only the P1102 and M1005 MFP
have been tested on real hardware. If you have any other supported model,
reporting whether it works — or doesn't — is genuinely valuable.

- Open a **Test Report** issue on GitLab (pick the *Test Report* template). It
  asks for your model, USB PID (`ioreg -p IOUSB -l | grep idProduct`), macOS
  version + chip, whether firmware uploaded and the page printed correctly, and
  a scrubbed `watcher.log` tail.
- Check the current per-model status in [`TESTED.md`](TESTED.md) first; your
  report is what moves a ⚠️ row to ✅ or ❌.
- The same scrubbing rule applies (no username, home path, hostname, or printer
  serial).

## Development setup

```bash
git clone git@gitlab.com:pauyedin/hp-laserjet-mac-driver.git
cd hp-laserjet-mac-driver
./install.sh          # builds foo2zjs + fwload, installs launchd + PDF Service
```

You need Homebrew, the Xcode Command Line Tools, and the formulae the installer
pulls in (`ghostscript`, `libusb`, `poppler`).

The moving parts:

| File | Role |
|------|------|
| `src/fwload.c`         | libusb pusher — firmware + ZjStream to bulk-OUT endpoint |
| `hp-laserjet-watcher.sh`     | the pipeline: `gs` → `foo2zjs` → `fwload` |
| `PDFService/`          | Automator Print Plugin (Print-dialog entry) |
| `com.hp-laserjet.watcher.plist.in` | launchd WatchPaths agent template |
| `install.sh` / `uninstall.sh` | setup / teardown |

To test a change to the pipeline without reinstalling, edit the installed copy
at `/usr/local/share/foo2zjs/hp-laserjet-watcher.sh` and drop a PDF into
`~/HP-LaserJet-spool/` as `job-<something>.pdf`.

## Pull / merge requests

- Keep the scope tight; one logical change per MR.
- Match the surrounding style (POSIX-ish bash, C matching `fwload.c`).
- **No personal data in commits** — no usernames, home paths, hostnames, or
  printer serials. `fwload` matches the printer by USB VID/PID only.
- Update `CHANGELOG.md` under `[Unreleased]`.
- Note tested macOS version + printer model in the MR description.

## License

By contributing you agree your contributions are licensed under **GPL-2.0**,
matching the rest of the repo (see `LICENSE`). The bundled `foo2zjs` and the HP
firmware blob retain their own licenses.
