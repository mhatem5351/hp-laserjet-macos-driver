# Changelog

All notable changes to **hp-laserjet-mac-driver** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.1-macos27] - Unreleased (fork)

Changes in the [`hp-laserjet-macos-driver`](https://github.com/mhatem5351/hp-laserjet-macos-driver)
fork on top of upstream v0.2.0. Hardware-verified with an HP LaserJet **P1102**
(`FWVER:20120814` unit) on **macOS 27**, Apple Silicon, connected through a USB
hub, printing from the macOS Print dialog and from a spool-folder client
(Folio PDF's "Print to HP LaserJet" sheet with a `job-<ts>.opts` sidecar). The
fixes are offered upstream.

### Fixed
- **Re-sending firmware no longer wedges a P1102 that already has it.** The
  watcher used to push the firmware blob before every job ("idempotent"). A
  P1102 that loaded its own firmware from flash at power-on does *not* treat
  that as a no-op: it drops into `FWVER:PENDING` and every later transfer fails
  with USB error `0xe00002ed` until the printer is power-cycled. The watcher now
  asks the printer first (`fwload --fwver`) and uploads the blob **only** when
  the printer reports no firmware version or `PENDING`; otherwise it logs
  `firmware already loaded (FWVER:…), skipping upload`. If the query itself
  fails, the upload is skipped rather than sent blind.
- **A dozing (idle) printer no longer fails the first job.** After sitting idle
  the printer can reject the first USB request with `LIBUSB_ERROR_IO` / `PIPE` /
  `TIMEOUT`. `fwload` now performs one `libusb_reset_device` (re-opening the
  device if it re-enumerates), re-claims the interface and retries — **only
  when no byte of the job had been sent**, so a partially delivered job is never
  resent (no garbage or duplicate pages). The `--fwver` query gets the same
  single reset-and-retry.
- **The printer no longer drops off USB after a job.** `fwload` asked libusb
  to auto-detach kernel drivers. On macOS, libusb treats any IORegistry child
  of the interface (e.g. a user client from Logitech G HUB or a browser) as a
  driver, and with `fwload` setuid root it "captured" the device by
  re-enumerating it on claim and again on release, just after the page was
  sent. The busy printer failed that re-enumeration ("failed to address
  device, disabling port"), so the next job found no printer until it was
  replugged. `fwload` no longer requests auto-detach; there's no kernel
  driver to detach on these printers.
- **The watcher no longer wakes itself every 5 seconds.** launchd's `WatchPaths`
  fires on any change in the spool dir, including the watcher's own
  `watcher.log` appends, so each run triggered the next one (and re-posted the
  "Printer not detected" banner) for as long as launchd kept it going. A run
  with nothing new to do (empty spool, jobs already reported as deferred, or
  saved failed jobs on the same printer connection) now exits before writing
  anything.
- **A failed job is no longer deleted.** When the USB push fails, the job (and
  its `.opts` sidecar) moves to `~/HP-LaserJet-spool/failed/` instead of being
  removed with the raster.

### Added
- **Two-sided printing on one-sided printers (`DUPLEX=manual`).** The watcher
  prints the front sides, shows a dialog asking you to put the stack back in
  (printed side down, top edge first, order unchanged), then prints the back
  sides in reverse order. Odd page counts get a blank back on the last sheet,
  which feeds first. Each copy starts on a fresh sheet, and a 1-page job prints
  one-sided. An unanswered prompt or a failed back pass saves the job as "back
  sides only" for the reprint prompt. New Print-dialog entry: **Print on HP
  LaserJet (two-sided)**.
- **`PAGES=` per-job key** (e.g. `PAGES=3-7,10`) to print a page subset,
  one-sided or two-sided. In two-sided mode the split follows the pages being
  printed (pages 3–7 → fronts 3 5 7, backs blank 6 4).
- **Reprint prompt for failed jobs.** Once the printer is usable again (it
  re-enumerated on USB after being replugged or power-cycled, or a new job just
  printed), the watcher shows a dialog per saved job with its time, title, page
  count and copies: **Print** queues it again, **Discard** deletes it, **Later**
  (or no answer within 2 minutes) keeps it until the next reconnect or new job.
  Nothing is ever reprinted without asking.
- **`StartInterval 30` on the launchd agent**, so a printer that is plugged in
  or switched on is noticed without printing again: deferred jobs print, and
  saved failed jobs are offered. Idle runs exit at once without touching disk.
- `hp-laserjet-doctor` reports how many failed jobs are waiting.
- **`fwload --fwver VID PID`** prints the `FWVER` field of the printer's
  IEEE-1284 device ID (USB printer-class `GET_DEVICE_ID`), e.g. `20120814` when
  firmware is loaded or `PENDING` when it still needs one; prints nothing if the
  device ID has no `FWVER`.

### Security
- **`fwload` drops privileges while reading the blob.** It is installed
  setuid root only so the user's launchd agent can claim the USB interface; it
  now opens and reads the firmware/raster file with the real user's id
  (`seteuid(getuid())`) and restores root only for USB access, so it can't be
  used to read files the caller couldn't. (No-op when not installed setuid.)

### Changed (repository)
- GitHub issue / PR templates and a CI workflow (shell syntax + `shellcheck`,
  macOS build of `fwload`, `foo2zjs`/`foo2xqx` and the menu-bar app) replace
  the GitLab templates and `.gitlab-ci.yml`. README rewritten for the fork with
  diagrams; upstream's technical documentation is kept. The Homebrew formula
  still installs upstream's release (see `HOMEBREW.md`).

## [0.2.0] - 2026-07-22

### Added
- **Scanner support scaffolding for the M1005 MFP (`scanner/`).** A libusb probe
  skeleton (`hp-scan.c`) plus protocol notes (`README.md`, `PROTOCOL.md`). This
  is **scaffolding only, not a working scanner** — it opens VID `0x03f0` + PID,
  selects the vendor-specific scan interface (interface 0, class `0xFF`), prints
  its endpoint descriptors, and sends only a clearly-marked *placeholder*
  command, logging whatever comes back. The real scan command/data handshake is
  unknown and needs a USB capture (or a port of SANE's `hpaio`); `PROTOCOL.md`
  is the template for a hardware owner to record it. Not built or installed by
  `install.sh`; `hp-scan` is not (and must not be) setuid.
- **`hp-laserjet-doctor` self-test command (`hp-laserjet-doctor.sh`).** A
  standalone diagnostic that mirrors the watcher's own detection and prints a
  PASS/FAIL summary per check: dependencies (ghostscript / libusb / poppler /
  installed `fwload` incl. its setuid bit / the `foo2zjs`+`foo2xqx` converters),
  printer detection over `ioreg` with the matched model row, a firmware-blob
  dry-run, and a dry test-page conversion (`gs` → converter, byte count only —
  no USB writes). With no flags it is entirely read-only; `--push` uploads the
  firmware over USB and `--print` runs the full pipeline and prints a test page.
  Exits non-zero on any failure (including no supported printer). Installed onto
  `PATH` as `hp-laserjet-doctor` by `install.sh` (removed by `uninstall.sh`).
- **Optional CUPS spooling backend (`cups-backend/`).** An independent, opt-in
  CUPS backend that makes the printer appear in **System Settings › Printers**
  and be **AirPrint-shareable** to iPhones/iPads. It **never touches USB and
  never execs the driver** — it only writes the job as `job-<ts>.pdf` into
  `~/HP-LaserJet-spool/` (the same intake the sandboxed PDF Service uses),
  converting PS→PDF via `pstopdf`/Ghostscript and refusing anything it cannot
  turn into a PDF. All real work still happens only in the unsandboxed watcher,
  so it does not reintroduce the "CUPS can't drive this printer" problem.
  Installed separately (`sudo cups-backend/install-cups-backend.sh`); not part
  of `install.sh`. Logs to `~/HP-LaserJet-spool/backend.log`.
- **Menu-bar print manager (`menubar/`).** The optional native `NSStatusItem`
  app gained live **per-job progress**, **queue actions** (cancel a job,
  reprint-last), and a **toner / page-count badge** parsed from the PJL status
  lines in the watcher log. Still a standalone single-file Swift executable
  (built with `swiftc`, no Xcode project), still never touches USB, and still
  not wired into `install.sh`.
- **More paper sizes plus scale and margin controls.** `hp-laserjet-watcher.sh`
  now recognises `legal`, `a5`, `executive`, `com10` (#10 envelope) and `dl`
  (DL envelope) in addition to `letter`/`a4`, each mapped to the converter's
  DMPAPER paper code and correct 600-dpi raster grid, plus `SCALE` (percent) and
  `MARGIN` (points) applied during Ghostscript rasterisation. Settable via the
  config file and per-job `.opts` sidecar. **The `letter`/`a4` defaults are
  byte-for-byte identical to before.** The new `legal`, `a5`, `executive`,
  `com10` and `dl` sizes are **UNTESTED on hardware** — the codes and grids
  match the converters' tables but have not been verified on a real printer.
  Documented in `docs/CONFIG.md`.
- **Homebrew one-line install and public-tap documentation.** `HOMEBREW.md` and
  `README.md` now document a single copy-paste
  `brew tap … && brew install … && hp-laserjet-install` line, and spell out the
  requirement that the `homebrew-hp-laserjet` tap repo be **public** (push-to-
  create leaves it private, which breaks `brew tap` over HTTPS).

## [0.1] - 2026-07-20

### Changed
- **Renamed the p1102-specific identifiers to generic `hp-laserjet` names**, now
  that the driver covers the whole host-based family, not only the P1102:
  `p1102-watcher.sh` → `hp-laserjet-watcher.sh`,
  `com.p1102.watcher` → `com.hp-laserjet.watcher` (launchd label),
  the spool dir `~/P1102-spool` → `~/HP-LaserJet-spool`, and the Print-dialog
  entry "Print on P1102" → "Print on HP LaserJet".
  **Upgrading breaks an existing install** (the launchd label and spool path
  change): run the *old* `./uninstall.sh` first, then the new `./install.sh`.
- **Internal refactor for extensibility (no behaviour change).** The inline
  converter-flag block became a `build_conv_flags()` function, config loading
  moved into `load_config()`, and a `read_job_opts()` per-job hook (currently a
  no-op placeholder) was wired into the job loop. The flag strings emitted are
  byte-identical to before.

### Added
- **Print quality / density controls.** `DENSITY` (`1`–`5`) and `ECONOMODE`
  (`on`/`off`) are now applied to the raster converter — `DENSITY` maps to the
  `foo2zjs`/`foo2xqx` `-T` darkness flag, `ECONOMODE` to `-t` (toner-save /
  draft). Both are settable in `~/.config/hp-laserjet/config` and overridable
  per job in a `job-<ts>.opts` sidecar (which `read_job_opts` now parses).
  Values are validated and out-of-range ones are logged and ignored. When
  neither is set the converter flags are byte-for-byte identical to before.
  Resolution is intentionally not exposed (it is coupled to the per-model paper
  grid via `XSCALE`; see `docs/CONFIG.md`). Documented in `docs/CONFIG.md`.
- **macOS completion notifications.** The watcher now posts a Notification
  Center banner via `osascript` when a job finishes — "Printed on …" on success,
  a short failure reason on error (empty conversion, nonzero USB push, or missing
  Ghostscript/converter/firmware), and a single "Printer not detected — job
  queued" banner when nothing supported is on the bus but a job is waiting. A new
  `NOTIFY=all|errors|none` config key (default `all`) selects the level.
  Notifications are best-effort and never affect job processing or exit codes;
  banner text contains no personal data. Documented in `docs/CONFIG.md`.
- **Multiple supported printers on the bus at once.** The watcher now
  enumerates *every* attached supported HP LaserJet (via `ioreg`), not just the
  first. With exactly one printer, detection and output are byte-for-byte
  identical to before; with none it still defers without guessing a model. With
  several, it routes to the printer named by a new `PRINTER` key — a USB PID
  (e.g. `0x3d17`) or a product-name substring (e.g. `p1005`) — in
  `~/.config/hp-laserjet/config`, or to a per-job `PRINTER=` in the
  `job-<ts>.opts` sidecar for a single job. When `PRINTER` is unset it falls
  back to a deterministic primary (the lowest PID present) and logs which
  printer it chose and which it ignored. Firmware upload and raster geometry
  follow the *selected* printer's model row. Documented in `docs/CONFIG.md`
  ("Selecting a printer when several are connected") and `README.md`.
- **Duplex, N-up and copies options** via the config file and per-job `.opts`
  sidecar. `read_job_opts()` now parses `COPIES`, `DUPLEX` (`none`/`long`/`short`)
  and `NUP` (plus the existing `DENSITY`) with an injection-safe reader, backed by
  `DEFAULT_COPIES` / `DEFAULT_DUPLEX` / `DEFAULT_NUP` config defaults. Copies use
  the converter's `-n` on ZjStream and re-push the raster N times on XQX (whose
  `-n` is a no-op in the stream); duplex passes the converter's `-d` code (`long`=2,
  `short`=3) — most supported models are simplex-only, so a duplex request is
  passed through and logged as a NOTE. N-up is parsed but ignored (neither
  converter supports it) with a logged NOTE. The `.opts` sidecar is removed with
  its PDF after the job. The default path (no config, no sidecar) emits a
  byte-identical converter flag string. Documented in `docs/CONFIG.md`.
- **Optional configuration file.** The watcher now reads
  `~/.config/hp-laserjet/config` (a `KEY=value` shell fragment, overridable via
  `HP_LASERJET_CONFIG`) for defaults such as `PAPER`, `DENSITY` and
  `DEFAULT_COPIES`, and recognises a per-job `job-<ts>.opts` sidecar for per-job
  overrides. Both are optional; with neither present the driver behaves exactly
  as before. Documented in `docs/CONFIG.md`. This is groundwork for upcoming
  duplex, density and multi-printer features.
- **`TESTED.md` compatibility matrix** — a living per-model status table (✅
  verified / ⚠️ untested / ❌ broken) with USB PID, protocol, firmware blob,
  tester and macOS version. Pre-filled from the model table; P1102 and M1005 MFP
  marked verified, all others untested pending community reports.
- **GitLab templates for community verification**: a *Test Report* issue
  template (`.gitlab/issue_templates/`) and an *Add or Fix Model* merge-request
  template (`.gitlab/merge_request_templates/`), both reinforcing the
  personal-data scrubbing policy. README and `CONTRIBUTING.md` now link them.
- **Optional native menu-bar app** (`menubar/`). A standalone single-file
  Swift/AppKit `NSStatusItem` utility (built with `swiftc`, no Xcode project)
  that shows printer online/offline status (via `ioreg`, matching the watcher),
  the queued job count, and actions to retrigger the watcher, open the spool
  folder, view the log, and clear the spool. Ships with a launchd Agent
  template (`com.hp-laserjet.menubar.plist.in`) for optional launch-at-login;
  **not wired into `install.sh`** — see `menubar/README.md`.
- **Homebrew distribution.** A tap formula (`Formula/hp-laserjet-mac-driver.rb`)
  installs the driver via `brew tap`/`brew install`; because the setuid binary,
  launchd agent and PDF Service need `sudo` and per-user setup that can't run in
  `brew install`, the formula stages the repo and its `caveats` point to a
  bundled `install.sh` follow-up. See `HOMEBREW.md`.
- **XQX protocol support (`foo2xqx`)** alongside ZjStream. The host-based
  LaserJets come in two raster dialects; the driver now handles both. XQX
  models: P1005 (`0x3d17`), P1006 (`0x3e17`), P1007 (`0x4817`),
  P1008 (`0x4917`), P1505 (`0x3f17`), P1505n (`0x4017`).
- **HP LaserJet M1005 MFP** support via `foo2xqx` (`0x3b17`, matched by product
  name too since its PID is undocumented). Reuses the P1005 XQX firmware — no
  dedicated M1005 blob exists in the HPLIP plugin. **Untested on hardware.**
- **Multi-model auto-detection.** The watcher reads the attached printer's USB
  product id (or product name) and selects the matching driver, firmware blob
  and raster geometry. Falls back to P1102 when nothing supported is detected.
- Installer builds `foo2xqx` in addition to `foo2zjs`, and fetches the whole
  family's firmware blobs from the HPLIP plugin (using any bundled in
  `vendor/`), skipping any a given plugin release lacks.
- `fwload` accepts optional `VID PID` arguments (`fwload blob [VID] [PID]`);
  the watcher passes the detected printer's ids. Defaults remain the P1102.
- **Parsed printer status read-back.** `fwload` now accumulates the bulk-IN
  reply after a transfer and echoes any human-readable ASCII lines as
  `status-line: `, and any line carrying a recognized PJL token (`CODE=`,
  `DISPLAY=`, `ONLINE`, `TONER`, `PAGECOUNT`, `PAGES`) as `status-kv: `. Binary
  or empty replies keep the previous byte-count summary. These lines flow into
  `~/HP-LaserJet-spool/watcher.log`, so a status poller / menu-bar can parse
  device state without extra plumbing. Read bounds are unchanged (whole
  `wMaxPacketSize` buffers, 500ms timeout, capped at 64 reads) and the read-back
  never affects the exit status.
- **`fwload --status [VID] [PID]` query mode.** Skips sending any blob: opens the
  printer, writes a PJL status query (`@PJL INFO STATUS` / `@PJL INFO PAGECOUNT`
  wrapped in the UEL escape) to bulk-OUT, then reads and prints the reply using
  the same `status-line: ` / `status-kv: ` parsing. Lets the watcher or a
  menu-bar poll status without printing a page. The positional
  `fwload blob [VID] [PID]` mode is unchanged.

### Fixed
- **Never guess a default model when no printer is detected.** The watcher used
  to fall back to the P1102, so a job queued while the printer was off or
  re-enumerating got driven with the wrong protocol/firmware at the wrong
  interface, silently. It now logs "no supported printer detected — deferring"
  and leaves the jobs in the spool for the next print/detection event.
- **Status read-back drains the full reply.** A single 64-byte bulk-IN read got
  `LIBUSB_ERROR_OVERFLOW` because the printer answers with more than that.
  `fwload` now reads whole `wMaxPacketSize` buffers and loops until a short
  packet, reporting the real byte count ("printer replied") — the actual accept
  signal that was the point of the read-back.
- **USB detection now uses `ioreg` instead of `system_profiler SPUSBDataType`.**
  On macOS Tahoe (26.x) `system_profiler SPUSBDataType` returns nothing at all
  (empty, no error), so the watcher mis-detected every printer — including the
  P1102 — and silently fell back to the wrong protocol/firmware. `ioreg -p
  IOUSB` works and reports idProduct/idVendor in decimal (reformatted to hex).
  Fixes detection in both `hp-laserjet-watcher.sh` and `install.sh`.
  Thanks to the M1005 tester for the diagnosis.
- **`fwload` selects the USB Printer-class interface, not interface 0.** On
  multifunction MFPs (M1005, M1120) interface 0 is a vendor-specific (class
  0xFF) scanner/ACL interface that also exposes bulk endpoints; writing there
  succeeds silently but never prints. `fwload` now prefers the interface with
  `bInterfaceClass == 7` (USB Printer), falling back to the first bulk-OUT
  interface for single-function models like the P1102. Adds a best-effort
  bulk-IN status read-back so a wrong-interface write is no longer
  indistinguishable from success.
- **Corrected the model/PID table.** An earlier draft listed the P-series with
  the wrong USB product ids (`0x1317`/`0x1517`/`0x0d17`) and wrongly as
  ZjStream. Those PIDs are actually the old ZjStream LJ 1005 etc.; the P-series
  are XQX at `0x3d17`/`0x3e17`/`0x3f17`. ZjStream firmware names were likewise
  corrected (`sihp1000.dl`…`sihp1020.dl`). Only P1102 (`0x002a`) was right.

### Changed
- Only the P1102 is hardware-tested; every other model (ZjStream or XQX) shares
  the same code path but is unverified. See the `model_row` table in
  `hp-laserjet-watcher.sh`.

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

[0.2.0]: https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/compare/v0.1...v0.2.0
[0.1]: https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/tags/v0.1
[1.0.0]: https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/tags/v1.0.0
