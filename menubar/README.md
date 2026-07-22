# Menu-bar app (optional)

A small native macOS menu-bar (`NSStatusItem`) **print manager** for the
[hp-laserjet-mac-driver](../README.md) print pipeline. It gives you an at-a-glance
printer icon in the menu bar, live per-job progress, queue actions (cancel /
reprint), a toner / page-count status line, and one-click access to the spool and
log.

It is a standalone single-file Swift executable (Foundation + AppKit) — **no
Xcode project and no Swift Package needed**. It **never touches USB** or execs the
drivers; all real printing stays in the unsandboxed launchd watcher. The menu-bar
app only *reads* device state (from the spool directory and `watcher.log`) and
*acts* by manipulating spool files — deleting a queued `job-*.pdf` to cancel, or
re-dropping one (atomic `.incoming-*` → `job-<ts>.pdf`, the same move the PDF
Service makes) to reprint. It detects the printer via `ioreg`. It does not open
the USB device, claim an interface, or run `fwload`.

## What it shows

The menu (polled every ~2 s):

- **Printer: `<model / online / offline>`** — scans `ioreg -p IOUSB -l` for an HP
  device (idVendor `1008` / `0x03f0`) with one of the supported product ids, the
  same set the watcher matches (`0x0517`, `0x1317`, `0x4117`, `0x2b17`, `0x002a`,
  `0x092a`, `0x3d17`, `0x3e17`, `0x4817`, `0x4917`, `0x3f17`, `0x4017`, `0x3b17`).
  Shows the USB *Product Name* when the device exposes one.
- **Live progress** — a second line shows `Printing: job-<ts> — <phase>` while the
  watcher is working a job, `Spooling a new job…` when a `.incoming-*` file is
  present, or `Idle`. The phase is inferred from the tail of `watcher.log`
  (`processing` → `page height=` → `raster … bytes` → `fwload exit`), since the
  watcher emits no byte-level progress. A job counts as "active" only while its
  `processing` line has no matching completion after it *and* the job file (or an
  `.incoming-*`) is still on disk.
- **Status: `<N pages · Toner LOW / DISPLAY text>`** — parses the latest
  `status-kv:` / `status-line:` lines the watcher writes to `watcher.log` after
  each job (the same lines `fwload --status` prints). It surfaces the printer's
  `PAGECOUNT` and flags low/empty toner (any `TONER`/`CARTRIDGE`/`SUPPLY` line
  carrying `LOW`/`EMPTY`/`REPLACE`/`OUT`/`DEPLETED`), otherwise showing the
  `DISPLAY` text. When no status is present it shows `Status: —`. On low toner the
  menu-bar icon also switches to a badged variant with a "toner low" tooltip.
- **Queue: `N job(s)`** — counts `job-*.pdf` files in `~/HP-LaserJet-spool/`. It is
  a submenu listing each queued job; under each is **Cancel Job**, which deletes
  that `job-*.pdf` (and its `.opts` sidecar) from the spool.
- **Reprint Last** — copies the most recently seen completed job back into the
  spool as a new `job-<ts>.pdf`, using the atomic `.incoming-*` → rename pattern.
  The app keeps a copy of the newest queued job in
  `~/HP-LaserJet-spool/.menubar-last.pdf` before the watcher deletes the original,
  so this stays available after a job finishes. Disabled when nothing is available
  to reprint.
- **Retrigger Watcher** — writes then removes a transient file inside the spool
  directory so launchd's `WatchPaths` fires and re-runs the watcher.
- **Open Spool Folder** — opens `~/HP-LaserJet-spool/` in Finder.
- **View Log** — opens `~/HP-LaserJet-spool/watcher.log` in Console.app.
- **Clear Spool…** — after an `NSAlert` confirmation, deletes queued `job-*.pdf`
  and any partial `.incoming-*` files.
- **Quit**.

The app resolves `$HOME` at runtime; no home path, username, or printer serial is
hardcoded. It reads log/spool state only and never accesses USB.

## Build

Uses the Swift toolchain shipped with the Xcode Command Line Tools
(`xcode-select --install`). Build the single source file with `swiftc`:

```bash
# System-wide, alongside the rest of the driver:
swiftc -O menubar/HPLaserJetMenu.swift -o /usr/local/share/foo2zjs/hp-laserjet-menu

# …or to a local path for testing:
swiftc -O menubar/HPLaserJetMenu.swift -o /tmp/hp-laserjet-menu
```

## Run

Just launch the executable — a printer icon appears in the menu bar (it is a
menu-bar-only accessory app, so it shows no Dock icon or window):

```bash
/usr/local/share/foo2zjs/hp-laserjet-menu &
```

## Launch at login (optional)

A launchd *Agent* template, `com.hp-laserjet.menubar.plist.in`, is provided so
the app can auto-start at login (`RunAtLoad` + `KeepAlive`). It is intentionally
**not wired into `install.sh`** — install it by hand if you want it:

```bash
# Substitute the placeholders (same convention as the watcher plist):
PREFIX=/usr/local/share/foo2zjs
sed -e "s|__HOME__|$HOME|g" -e "s|__PREFIX__|$PREFIX|g" \
    menubar/com.hp-laserjet.menubar.plist.in \
    > ~/Library/LaunchAgents/com.hp-laserjet.menubar.plist

# Load it:
launchctl load ~/Library/LaunchAgents/com.hp-laserjet.menubar.plist
```

To remove it:

```bash
launchctl unload ~/Library/LaunchAgents/com.hp-laserjet.menubar.plist
rm ~/Library/LaunchAgents/com.hp-laserjet.menubar.plist
```

## License

GPL-2.0-or-later, matching the rest of the repository.
