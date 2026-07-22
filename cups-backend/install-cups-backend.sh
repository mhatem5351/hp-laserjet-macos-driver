#!/bin/bash
# ============================================================================
#  hp-laserjet-mac-driver — OPTIONAL CUPS spooling backend installer
#
#  Installs the `hp-laserjet` CUPS backend (a spool-only job intake) and,
#  optionally, creates a printer queue that points at it. This makes a
#  host-based HP LaserJet show up in System Settings > Printers so it can be
#  AirPrint-shared to iPhones/iPads.
#
#  IMPORTANT: this is OPTIONAL and independent of the core driver. It does NOT
#  reintroduce the CUPS-touches-USB failure this project avoids: the backend
#  only writes a PDF into ~/HP-LaserJet-spool/. The existing unsandboxed
#  launchd watcher still does firmware upload, rasterisation and the USB
#  transfer. The backend never execs fwload and never opens a USB device.
#
#  Requires sudo: CUPS backends must live root-owned under the system CUPS
#  backend directory (mode 0755, or 0700 to run as root), and `lpadmin` needs
#  admin rights to create a queue.
#
#  License: GPL-2.0.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND_SRC="$HERE/hp-laserjet"

# The queue name and the URI the queue is attached to. The URI's scheme MUST
# match the backend's filename (hp-laserjet) — that is how CUPS routes a job
# to this backend.
QUEUE_NAME="${QUEUE_NAME:-HP_LaserJet}"
QUEUE_URI="hp-laserjet://spool"

# ---------------------------------------------------------------------------
# Locate the CUPS backend directory. macOS keeps it under /usr/libexec/cups;
# some CUPS builds use /usr/local/libexec/cups. Prefer whichever exists.
# ---------------------------------------------------------------------------
find_backend_dir() {
    for d in /usr/libexec/cups/backend /usr/local/libexec/cups/backend; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    # Ask cups-config if present.
    if command -v cups-config >/dev/null 2>&1; then
        local sd
        sd="$(cups-config --serverbin 2>/dev/null || true)"
        [ -n "$sd" ] && [ -d "$sd/backend" ] && { echo "$sd/backend"; return 0; }
    fi
    return 1
}

echo "== hp-laserjet OPTIONAL CUPS backend installer =="

[ -f "$BACKEND_SRC" ] || { echo "error: backend script not found at $BACKEND_SRC" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer needs sudo (root-owned backend + lpadmin)." >&2
    echo "Re-run:  sudo $0" >&2
    exit 1
fi

BACKEND_DIR="$(find_backend_dir || true)"
if [ -z "${BACKEND_DIR:-}" ]; then
    echo "error: could not find a CUPS backend directory." >&2
    echo "       Looked in /usr/libexec/cups/backend and /usr/local/libexec/cups/backend." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Install the backend. CUPS runs a backend as root only if it is mode 0700
# (or 0500) and root-owned; a 0755 backend runs as an unprivileged user.
# We install 0755 — the backend needs no privilege, it just writes a file to
# the job owner's spool. This is the least-privilege choice and matches the
# "never touch USB" contract.
# ---------------------------------------------------------------------------
DEST="$BACKEND_DIR/hp-laserjet"
echo "Installing backend -> $DEST"
install -o root -g wheel -m 0755 "$BACKEND_SRC" "$DEST"

echo "Backend installed. Verifying CUPS can enumerate it..."
# `lpinfo -v` lists devices reported by every backend; ours should appear.
if command -v lpinfo >/dev/null 2>&1; then
    if lpinfo -v 2>/dev/null | grep -q '^direct hp-laserjet'; then
        echo "  ok: CUPS sees 'direct hp-laserjet://spool'"
    else
        echo "  note: device not listed yet (CUPS may cache backends; harmless)."
    fi
fi

# ---------------------------------------------------------------------------
# Optionally create the printer queue. Skip with NO_QUEUE=1.
#
# We attach a generic/raw queue: CUPS does no driver conversion, it just hands
# the incoming PDF/PS straight to our backend, which spools it. `-m everywhere`
# (driverless) or a raw queue both work; a raw queue is the most predictable
# for a spool-only path and needs no PPD.
# ---------------------------------------------------------------------------
if [ "${NO_QUEUE:-0}" = "1" ]; then
    echo "NO_QUEUE=1 set — skipping queue creation."
else
    if ! command -v lpadmin >/dev/null 2>&1; then
        echo "warning: lpadmin not found; skipping queue creation." >&2
    else
        echo "Creating raw print queue '$QUEUE_NAME' -> $QUEUE_URI"
        # -E enables and accepts jobs; -o printer-is-shared for AirPrint sharing.
        # Raw queue: no -m/-P PPD, so CUPS passes the job through untouched.
        lpadmin -p "$QUEUE_NAME" \
                -v "$QUEUE_URI" \
                -E \
                -D "HP LaserJet (host-based)" \
                -L "spooled via hp-laserjet-mac-driver" \
                -o printer-is-shared=true
        echo "  queue '$QUEUE_NAME' created, enabled and shared."
        echo
        echo "To finish AirPrint sharing:"
        echo "  System Settings > General > Sharing > Printer Sharing = ON,"
        echo "  then tick '$QUEUE_NAME'. iPhones/iPads on the same network will"
        echo "  then see it as an AirPrint printer."
    fi
fi

echo
echo "Done. The backend only SPOOLS jobs into ~/HP-LaserJet-spool/; the"
echo "unsandboxed launchd watcher performs the actual printing over USB."
echo
echo "Uninstall:"
echo "  sudo lpadmin -x '$QUEUE_NAME'      # remove the queue (if created)"
echo "  sudo rm -f '$DEST'                 # remove the backend"
