# Menu-bar app (optional)

A small native macOS menu-bar (`NSStatusItem`) utility for the
[hp-laserjet-mac-driver](../README.md) print pipeline. It gives you an at-a-glance
printer icon in the menu bar plus one-click access to the spool and log.

It is a standalone single-file Swift executable (Foundation + AppKit) — **no
Xcode project and no Swift Package needed**. It never touches USB or execs the
drivers; all real printing stays in the unsandboxed launchd watcher. The menu-bar
app only *reads* the spool and detects the printer via `ioreg`.

## What it shows

The menu (refreshed every ~5 s):

- **Printer: `<model / online / offline>`** — scans `ioreg -p IOUSB -l` for an HP
  device (idVendor `1008` / `0x03f0`) with one of the supported product ids, the
  same set the watcher matches (`0x0517`, `0x1317`, `0x4117`, `0x2b17`, `0x002a`,
  `0x092a`, `0x3d17`, `0x3e17`, `0x4817`, `0x4917`, `0x3f17`, `0x4017`, `0x3b17`).
  Shows the USB *Product Name* when the device exposes one.
- **Queue: `N job(s)`** — counts `job-*.pdf` files in `~/HP-LaserJet-spool/`.
- **Retrigger Watcher** — writes then removes a transient file inside the spool
  directory so launchd's `WatchPaths` fires and re-runs the watcher.
- **Open Spool Folder** — opens `~/HP-LaserJet-spool/` in Finder.
- **View Log** — opens `~/HP-LaserJet-spool/watcher.log` in Console.app.
- **Clear Spool…** — after an `NSAlert` confirmation, deletes queued `job-*.pdf`
  and any partial `.incoming-*` files.
- **Quit**.

The app resolves `$HOME` at runtime; no home path, username, or printer serial is
hardcoded.

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
