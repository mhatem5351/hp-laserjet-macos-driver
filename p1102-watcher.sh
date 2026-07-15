#!/bin/bash
# Unsandboxed printer worker for host-based HP LaserJet printers of two
# families: ZjStream (foo2zjs) and XQX (foo2xqx).
#
#   ZjStream : LaserJet 1000 / 1005 / 1018 / 1020, P1102 / P1102w, P1566 / P1606
#   XQX      : LaserJet P1005 / P1006 / P1007 / P1008 / P1505, M1005 MFP
#
# Launched by a launchd agent whenever a job appears in the spool dir.
# Converts each queued PDF (PDF -> PBM -> ZjStream|XQX) and pushes it over USB.
#
# Part of hp-laserjet-mac-driver. No CUPS: modern macOS sandboxes CUPS filters
# and its usb backend cannot talk to these printers, so we deliver over libusb.

PREFIX=/usr/local/share/foo2zjs
FOO2ZJS="$PREFIX/foo2zjs"
FOO2XQX="$PREFIX/foo2xqx"
FWLOAD="$PREFIX/fwload"
FWDIR="$PREFIX/firmware"
SPOOL="$HOME/P1102-spool"
LOG="$SPOOL/watcher.log"

VID=0x03f0   # HP — same vendor for the whole family

# ---------------------------------------------------------------------------
# Model table. Keyed by the USB product id (hex, lowercase). Each row is:
#
#   driver      firmware(.dl)   RES        XSCALE
#
# driver : foo2zjs | foo2xqx (which raster protocol this printer speaks)
# RES    : Ghostscript/driver resolution
# XSCALE : width scale of the raster grid (1 = symmetric 600x600;
#          2 = asymmetric 1200x600, printer expects double pixels across)
#
# PIDs verified against foo2zjs `hplj1000` + `hplj10xx.conf` (the driver's own
# authoritative device table). The XQX P-series were previously listed here
# with the wrong PIDs and wrongly as ZjStream — corrected below.
#
# TESTED: only P1102 (0x002a). Every other row is unverified on hardware.
# ---------------------------------------------------------------------------
model_row() {
    case "$1" in
        # --- ZjStream (foo2zjs) ---
        0x0517) echo "foo2zjs sihp1000.dl  600x600  1" ;;   # LaserJet 1000
        0x1317) echo "foo2zjs sihp1005.dl  600x600  1" ;;   # LaserJet 1005
        0x4117) echo "foo2zjs sihp1018.dl  600x600  1" ;;   # LaserJet 1018
        0x2b17) echo "foo2zjs sihp1020.dl  600x600  1" ;;   # LaserJet 1020
        0x002a) echo "foo2zjs sihpP1102.dl 1200x600 2" ;;   # P1102 / P1102w  (TESTED)
        0x092a) echo "foo2zjs sihpP1566.dl 1200x600 2" ;;   # P1566 / P1606
        # --- XQX (foo2xqx) ---
        0x3d17) echo "foo2xqx sihpP1005.dl 1200x600 2" ;;   # P1005
        0x3e17) echo "foo2xqx sihpP1006.dl 1200x600 2" ;;   # P1006
        0x4817) echo "foo2xqx sihpP1005.dl 1200x600 2" ;;   # P1007 (P1005 firmware alias)
        0x4917) echo "foo2xqx sihpP1006.dl 1200x600 2" ;;   # P1008 (P1006 firmware alias)
        0x3f17) echo "foo2xqx sihpP1505.dl 1200x600 2" ;;   # P1505
        0x4017) echo "foo2xqx sihpP1505.dl 1200x600 2" ;;   # P1505n
        0x3b17) echo "foo2xqx sihpP1005.dl 1200x600 2" ;;   # M1005 MFP (P1005 firmware; UNVERIFIED)
        *)      echo "" ;;
    esac
}

# The M1005 MFP's USB product id is not documented in the driver's own device
# table (it is matched there by product string, not PID). 0x3b17 above is the
# widely-reported value; if a connected M1005 reports a different PID, this
# name match catches it and maps it to the same XQX row.
name_row() {   # $1 = lowercased USB product-name string
    case "$1" in
        *m1005*) echo "foo2xqx sihpP1005.dl 1200x600 2" ;;
        *)       echo "" ;;
    esac
}

# Locate Ghostscript + pdfinfo on either Apple Silicon or Intel Homebrew.
find_bin() {
    for p in /opt/homebrew/bin/"$1" /usr/local/bin/"$1" "$(command -v "$1" 2>/dev/null)"; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
}
GS=$(find_bin gs)
PDFINFO=$(find_bin pdfinfo)
SPROFILER=/usr/sbin/system_profiler

# Keep the log from growing forever.
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && : > "$LOG"
echo "=== $(date) watcher woke ===" >> "$LOG"

if [ -z "$GS" ]; then
    echo "  ERROR: ghostscript (gs) not found — run: brew install ghostscript" >> "$LOG"
    exit 1
fi

# --- detect which supported printer is actually connected ------------------
# Scan USB for an HP (0x03f0) product id we have a row for, then fall back to a
# product-name match (catches the M1005 whose PID is not documented). If both
# fail, default to the P1102 (keeps behaviour for the original model).
DRIVER="" ; FW_NAME="" ; RES="" ; XSCALE="" ; PID=""

detect_by_pid() {
    [ -x "$SPROFILER" ] || return
    "$SPROFILER" SPUSBDataType 2>/dev/null \
      | awk 'tolower($0) ~ /product id:/ {print $NF}' \
      | while read -r p; do
            pl=$(echo "$p" | tr 'A-F' 'a-f')
            [ -n "$(model_row "$pl")" ] && { echo "$pl"; break; }
        done
}

detect_by_name() {
    [ -x "$SPROFILER" ] || return
    "$SPROFILER" SPUSBDataType 2>/dev/null | tr 'A-Z' 'a-z' \
      | grep -qi 'm1005' && echo "m1005"
}

PID=$(detect_by_pid)
if [ -n "$PID" ]; then
    ROW=$(model_row "$PID")
else
    NAME=$(detect_by_name)
    if [ -n "$NAME" ]; then
        ROW=$(name_row "$NAME")
        PID=0x3b17            # best-known M1005 PID for the firmware push
    else
        PID=0x002a            # default: P1102
        ROW=$(model_row "$PID")
    fi
fi

DRIVER=$(echo "$ROW"  | awk '{print $1}')
FW_NAME=$(echo "$ROW" | awk '{print $2}')
RES=$(echo "$ROW"     | awk '{print $3}')
XSCALE=$(echo "$ROW"  | awk '{print $4}')
FW="$FWDIR/$FW_NAME"

# Pick the raster converter for this printer's protocol.
case "$DRIVER" in
    foo2xqx) CONV="$FOO2XQX" ;;
    *)       CONV="$FOO2ZJS" ;;
esac

echo "  printer PID=$PID driver=$DRIVER firmware=$FW_NAME res=$RES xscale=$XSCALE" >> "$LOG"

if [ ! -x "$CONV" ]; then
    echo "  ERROR: converter $CONV missing — re-run install.sh" >> "$LOG"
    exit 1
fi
if [ ! -f "$FW" ]; then
    echo "  ERROR: firmware $FW missing — re-run install.sh with printer attached" >> "$LOG"
    exit 1
fi

# Paper grid, in pixels, for this model's RES. Base (600 dpi) grid is:
#   US Letter  5100 x 6600     A4  4960 x 7016
# The across dimension is multiplied by XSCALE for the 1200x600 models.
grid_for() {   # $1 = base-width  $2 = height
    echo "$(( $1 * XSCALE ))x$2"
}

shopt -s nullglob
for PDF in "$SPOOL"/job-*.pdf; do
    echo "processing $PDF" >> "$LOG"
    TMP=$(mktemp /tmp/p1102.XXXXXX.raster)

    # Firmware is idempotent; push before each job in case of a power cycle.
    "$FWLOAD" "$FW" "$VID" "$PID" >>"$LOG" 2>&1 || true

    # Detect page size (height in points): A4 = 842pt, US Letter = 792pt.
    psize=""
    [ -n "$PDFINFO" ] && psize=$("$PDFINFO" "$PDF" 2>/dev/null | awk -F'x' '/Page size/{print $2+0}')
    if [ -n "$psize" ] && [ "${psize%.*}" -gt 820 ]; then
        PCODE=9;  GDIM=$(grid_for 4960 7016)    # A4       (foo2* paper table)
    else
        PCODE=1;  GDIM=$(grid_for 5100 6600)    # US Letter
    fi
    echo "  page height=${psize:-?}pt -> p$PCODE gdim=$GDIM res=$RES" >> "$LOG"

    # Both gs and the converter share -r/-g/-p; -dPDFFitPage scales into the
    # grid. foo2zjs takes -z (ZjStream compression); foo2xqx has no -z.
    if [ "$DRIVER" = foo2xqx ]; then
        CONV_FLAGS="-P -L0 -r$RES -g$GDIM -p$PCODE"
    else
        CONV_FLAGS="-z2 -P -L0 -r$RES -g$GDIM -p$PCODE -T5"
    fi
    "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
          -sDEVICE=pbmraw -r$RES -g$GDIM \
          -dFIXEDMEDIA -dPDFFitPage \
          -sOutputFile=- "$PDF" 2>>"$LOG" \
      | "$CONV" $CONV_FLAGS > "$TMP" 2>>"$LOG"

    sz=$(wc -c < "$TMP")
    echo "  raster $sz bytes" >> "$LOG"

    if [ "$sz" -ge 32 ]; then
        "$FWLOAD" "$TMP" "$VID" "$PID" >>"$LOG" 2>&1
        echo "  fwload exit $?" >> "$LOG"
    else
        echo "  empty conversion, skipped" >> "$LOG"
    fi
    rm -f "$TMP" "$PDF"
done
