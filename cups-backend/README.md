# Optional CUPS spooling backend

This directory adds an **optional** CUPS *backend* so a host-based HP LaserJet
shows up in **System Settings > Printers** and can be **AirPrint-shared** to
iPhones and iPads on your network.

It is completely independent of the core driver. If you never install it,
nothing changes — you keep printing via **Cmd+P → PDF ▾ → "Print on HP
LaserJet"** exactly as before.

## Why this does NOT reintroduce the "CUPS can't drive this printer" problem

The whole reason this project bypasses CUPS is that, on modern macOS:

- the CUPS `usb` backend **aborts mid-transfer** with these printers, and
- CUPS **sandboxes filters/backends**, so anything in `/usr/local` that tries
  to `exec` a helper or open a USB device gets `Operation not permitted`.

This backend sidesteps all of that because **it never touches USB and never
execs the driver.** It does exactly one thing: it takes the job CUPS hands it
and writes it as `job-<ts>.pdf` into `~/HP-LaserJet-spool/` — the *same* spool
directory the sandboxed PDF Service already writes to (write `.incoming-*`,
then atomically `mv` to `job-*.pdf`).

The real work — model detection, firmware upload, Ghostscript rasterisation,
and the libusb transfer — still happens **only** in the existing unsandboxed
launchd watcher (`hp-laserjet-watcher.sh`), triggered by its `WatchPaths` on
the spool. CUPS becomes just a second **job intake path**, mirroring the PDF
Service. Spooling a file to `$HOME` is not something the CUPS sandbox blocks,
so it works where a USB-touching backend would fail.

```
AirPrint / System Settings print
        │  (CUPS raw queue → hp-laserjet backend, sandboxed)
        ▼
  writes PDF into ~/HP-LaserJet-spool/job-<ts>.pdf   ← backend stops here
        │
        ▼
  launchd WatchPaths → hp-laserjet-watcher.sh  (unsandboxed)
        └─ detect → fwload firmware → gs → foo2zjs|foo2xqx → fwload raster→USB
```

The backend converts PostScript to PDF (via `pstopdf`, falling back to
Ghostscript) when CUPS hands it PS, because the watcher only understands PDF.
It refuses (rather than misprints) anything it cannot turn into a PDF.

## Install

Requires `sudo` — a CUPS backend must be root-owned in the system backend
directory, and `lpadmin` needs admin rights to create the queue.

```bash
sudo ./install-cups-backend.sh
```

This:

1. copies `hp-laserjet` into the CUPS backend dir (`/usr/libexec/cups/backend`
   or `/usr/local/libexec/cups/backend`), root-owned, mode `0755`;
2. creates a raw, shared print queue named `HP_LaserJet` pointing at
   `hp-laserjet://spool`.

Environment overrides:

- `QUEUE_NAME=MyPrinter sudo ./install-cups-backend.sh` — custom queue name.
- `NO_QUEUE=1 sudo ./install-cups-backend.sh` — install the backend only;
  add the queue yourself later.

The core driver (`../install.sh`) must already be installed and its watcher
loaded — this backend does not print on its own; it only feeds the watcher.

## AirPrint-share it to your iPhone/iPad

1. `System Settings > General > Sharing > Printer Sharing` → **On**.
2. Tick **HP_LaserJet** (or your `QUEUE_NAME`).

Devices on the same network will then see it as an AirPrint printer. (macOS
advertises shared CUPS queues over AirPrint automatically.) Because the Mac
still does the rasterisation and USB transfer, the Mac must be awake and the
printer attached to it.

## Uninstall

```bash
sudo lpadmin -x HP_LaserJet                       # remove the queue
sudo rm -f /usr/libexec/cups/backend/hp-laserjet  # remove the backend
# (use /usr/local/libexec/cups/backend if that is where it was installed)
```

Use your `QUEUE_NAME` if you changed it. Removing this leaves the core driver,
watcher and PDF Service untouched.

## Debugging

The backend logs to `~/HP-LaserJet-spool/backend.log` (job id, user, chosen
spool path, conversion result). The watcher's own actions stay in
`watcher.log` as usual.

## License

GPL-2.0, matching the rest of the repo and the bundled `foo2zjs`.
