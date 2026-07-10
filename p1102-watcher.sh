#!/bin/bash
# Unsandboxed printer worker for host-based HP LaserJet ZjStream printers
# (P1005 / P1006 / P1505 / P1102 / P1566 family).
# Launched by a launchd agent whenever a job appears in the spool dir.
# Converts each queued PDF (PDF -> PBM -> ZjStream) and pushes it over USB.
#
# Part of p1102-mac-driver. No CUPS: modern macOS sandboxes CUPS filters and
# its usb backend cannot talk to these printers, so we deliver over libusb.

PREFIX=/usr/local/share/foo2zjs
FOO2ZJS="$PREFIX/foo2zjs"
FWLOAD="$PREFIX/fwload"
FWDIR="$PREFIX/firmware"
SPOOL="$HOME/P1102-spool"
LOG="$SPOOL/watcher.log"

VID=0x03f0   # HP — same vendor for the whole family

# ---------------------------------------------------------------------------
# Model table. Each row (PID) maps to: firmware blob, foo2zjs resolution, and
# the width scale of the raster grid (1 = symmetric 600x600; 2 = asymmetric
# 1200x600, where the printer expects double the pixels across).
#
#   PID       firmware(.dl)   RES        XSCALE
# ---------------------------------------------------------------------------
model_row() {
    case "$1" in
        0x1317) echo "sihpP1005.dl 600x600 1" ;;   # P1005
        0x1517) echo "sihpP1006.dl 600x600 1" ;;   # P1006 / P1007 / P1008
        0x0d17) echo "sihpP1505.dl 600x600 1" ;;   # P1505
        0x002a) echo "sihpP1102.dl 1200x600 2" ;;  # P1102 / P1102w
        0x092a) echo "sihpP1566.dl 1200x600 2" ;;  # P1566 / P1606
        *)      echo "" ;;
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
# Scan USB for an HP (0x03f0) product ID we have a row for. Fall back to the
# P1102 if detection turns up nothing (keeps behaviour for the original model).
detect_pid() {
    [ -x "$SPROFILER" ] || return
    "$SPROFILER" SPUSBDataType 2>/dev/null \
      | awk 'tolower($0) ~ /product id:/ {print $NF}' \
      | while read -r p; do
            pl=$(echo "$p" | tr 'A-F' 'a-f')
            [ -n "$(model_row "$pl")" ] && { echo "$pl"; break; }
        done
}
PID=$(detect_pid)
[ -z "$PID" ] && PID=0x002a   # default: P1102

ROW=$(model_row "$PID")
FW_NAME=$(echo "$ROW"  | cut -d' ' -f1)
RES=$(echo "$ROW"      | cut -d' ' -f2)
XSCALE=$(echo "$ROW"   | cut -d' ' -f3)
FW="$FWDIR/$FW_NAME"
echo "  printer PID=$PID firmware=$FW_NAME res=$RES xscale=$XSCALE" >> "$LOG"

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
    TMP=$(mktemp /tmp/p1102.XXXXXX.zjs)

    # Firmware is idempotent; push before each job in case of a power cycle.
    "$FWLOAD" "$FW" "$VID" "$PID" >>"$LOG" 2>&1 || true

    # Detect page size (height in points): A4 = 842pt, US Letter = 792pt.
    psize=""
    [ -n "$PDFINFO" ] && psize=$("$PDFINFO" "$PDF" 2>/dev/null | awk -F'x' '/Page size/{print $2+0}')
    if [ -n "$psize" ] && [ "${psize%.*}" -gt 820 ]; then
        PCODE=9;  GDIM=$(grid_for 4960 7016)    # A4       (foo2zjs paper table)
    else
        PCODE=1;  GDIM=$(grid_for 5100 6600)    # US Letter
    fi
    echo "  page height=${psize:-?}pt -> p$PCODE gdim=$GDIM res=$RES" >> "$LOG"

    # Both gs and foo2zjs get identical -r/-g; -dPDFFitPage scales into the grid.
    "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
          -sDEVICE=pbmraw -r$RES -g$GDIM \
          -dFIXEDMEDIA -dPDFFitPage \
          -sOutputFile=- "$PDF" 2>>"$LOG" \
      | "$FOO2ZJS" -z2 -P -L0 -r$RES -g$GDIM -p$PCODE -T5 > "$TMP" 2>>"$LOG"

    sz=$(wc -c < "$TMP")
    echo "  ZjStream $sz bytes" >> "$LOG"

    if [ "$sz" -ge 32 ]; then
        "$FWLOAD" "$TMP" "$VID" "$PID" >>"$LOG" 2>&1
        echo "  fwload exit $?" >> "$LOG"
    else
        echo "  empty conversion, skipped" >> "$LOG"
    fi
    rm -f "$TMP" "$PDF"
done
