#!/bin/bash
# Unsandboxed printer worker for HP LaserJet P1102 (host-based ZjStream).
# Launched by a launchd agent whenever a job appears in ~/P1102-spool/.
# Converts each queued PDF (PDF -> PBM -> ZjStream) and pushes it over USB.
#
# Part of p1102-mac-driver. No CUPS: modern macOS sandboxes CUPS filters and
# its usb backend cannot talk to this printer, so we deliver over libusb.

PREFIX=/usr/local/share/foo2zjs
FOO2ZJS="$PREFIX/foo2zjs"
FWLOAD="$PREFIX/fwload"
FW="$PREFIX/firmware/sihpP1102.dl"
SPOOL="$HOME/P1102-spool"
LOG="$SPOOL/watcher.log"

# Locate Ghostscript + pdfinfo on either Apple Silicon or Intel Homebrew.
find_bin() {
    for p in /opt/homebrew/bin/"$1" /usr/local/bin/"$1" "$(command -v "$1" 2>/dev/null)"; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
}
GS=$(find_bin gs)
PDFINFO=$(find_bin pdfinfo)

# P1102 ZjStream is an asymmetric 1200x600 raster (1200 dpi across, 600 down).
# gs AND foo2zjs must use identical -r and -g or the image squeezes sideways.
RES=1200x600

# Keep the log from growing forever.
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && : > "$LOG"
echo "=== $(date) watcher woke ===" >> "$LOG"

if [ -z "$GS" ]; then
    echo "  ERROR: ghostscript (gs) not found — run: brew install ghostscript" >> "$LOG"
    exit 1
fi

shopt -s nullglob
for PDF in "$SPOOL"/job-*.pdf; do
    echo "processing $PDF" >> "$LOG"
    TMP=$(mktemp /tmp/p1102.XXXXXX.zjs)

    # Firmware is idempotent; push before each job in case of a power cycle.
    "$FWLOAD" "$FW" >>"$LOG" 2>&1 || true

    # Detect page size (height in points): A4 = 842pt, US Letter = 792pt.
    psize=""
    [ -n "$PDFINFO" ] && psize=$("$PDFINFO" "$PDF" 2>/dev/null | awk -F'x' '/Page size/{print $2+0}')
    if [ -n "$psize" ] && [ "${psize%.*}" -gt 820 ]; then
        PCODE=9;  GDIM=9920x7016    # A4       (foo2zjs paper table)
    else
        PCODE=1;  GDIM=10200x6600   # US Letter
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
        "$FWLOAD" "$TMP" >>"$LOG" 2>&1
        echo "  fwload exit $?" >> "$LOG"
    else
        echo "  empty conversion, skipped" >> "$LOG"
    fi
    rm -f "$TMP" "$PDF"
done
