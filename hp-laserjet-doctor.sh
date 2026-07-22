#!/bin/bash
# ============================================================================
#  hp-laserjet-doctor — self-test / troubleshooting for hp-laserjet-mac-driver
#
#  A standalone diagnostic that mirrors the watcher's own detection so a "PASS"
#  here means the watcher will see the same thing. It:
#    • checks dependencies (ghostscript, libusb, poppler/pdfinfo, fwload)
#    • detects the attached HP LaserJet via ioreg (VID 0x03f0) and prints the
#      matched model row (driver / firmware / RES / XSCALE)
#    • verifies the firmware blob for the detected model is installed
#      (dry-run; --push actually uploads it over USB)
#    • generates a 1-page test PDF and does a dry conversion
#      (gs -> foo2zjs|foo2xqx), reporting byte counts; --print pushes it to USB
#    • prints a PASS/FAIL summary per check
#
#  USB detection is via `ioreg`, NOT `system_profiler SPUSBDataType`, which
#  returns nothing on macOS Tahoe (26.x). If no supported printer is on the
#  bus, we DEFER — we never guess a model (driving a job as the wrong model
#  would push the wrong protocol/firmware). Reuses the exact detection approach
#  of hp-laserjet-watcher.sh so the two stay in agreement.
#
#  Part of hp-laserjet-mac-driver. No personal data is embedded — home, user
#  and printer are detected at run time.
# ============================================================================
set -eu

PREFIX=/usr/local/share/foo2zjs
FOO2ZJS="$PREFIX/foo2zjs"
FOO2XQX="$PREFIX/foo2xqx"
FWLOAD="$PREFIX/fwload"
FWDIR="$PREFIX/firmware"
SPOOL="$HOME/HP-LaserJet-spool"
LOG="$SPOOL/watcher.log"

VID=0x03f0   # HP — same vendor for the whole host-based family

DO_PUSH=0    # --push  : actually run fwload with the firmware blob
DO_PRINT=0   # --print : run the full pipeline and push the test page to USB

# ---------------------------------------------------------------------------
# Pretty output + PASS/FAIL bookkeeping.
# ---------------------------------------------------------------------------
PASS_N=0 ; FAIL_N=0 ; WARN_N=0
if [ -t 1 ]; then
    C_G=$'\033[1;32m' ; C_R=$'\033[1;31m' ; C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m' ; C_0=$'\033[0m'
else
    C_G="" ; C_R="" ; C_Y="" ; C_B="" ; C_0=""
fi

hdr()  { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
pass() { PASS_N=$((PASS_N+1)); printf '    %s[PASS]%s %s\n' "$C_G" "$C_0" "$*"; }
fail() { FAIL_N=$((FAIL_N+1)); printf '    %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
warn() { WARN_N=$((WARN_N+1)); printf '    %s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }

usage() {
    cat <<EOF
Usage: hp-laserjet-doctor [--push] [--print] [-h|--help]

Self-test for hp-laserjet-mac-driver. With no flags it is entirely read-only
and never touches the printer over USB (deps + detection + dry conversion).

  --push    also upload the detected model's firmware blob over USB (fwload)
  --print   run the full pipeline (gs -> foo2zjs|foo2xqx -> fwload) and print
            a one-page test page on the detected printer (implies --push)
  -h, --help  show this help

Exit status is non-zero if any check FAILs (including no supported printer).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --push)     DO_PUSH=1 ;;
        --print)    DO_PRINT=1; DO_PUSH=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Model table — kept byte-identical to hp-laserjet-watcher.sh's model_row().
# Keyed by USB product id (hex, lowercase). Row = driver firmware RES XSCALE.
# This is intentionally the same source of truth; if you edit one, edit both.
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

# Product-name fallback for the M1005, whose PID isn't in the driver's table.
name_row() {   # $1 = lowercased USB product-name string
    case "$1" in
        *m1005*) echo "foo2xqx sihpP1005.dl 1200x600 2" ;;
        *)       echo "" ;;
    esac
}

# ioreg-based detection — the SAME scan the watcher uses (ioreg only; never
# system_profiler, which is empty on Tahoe). idProduct is decimal in ioreg.
detect_all_pids() {
    ioreg -p IOUSB -w0 -l 2>/dev/null \
      | awk '/"idProduct" =/ {printf "0x%04x\n", $NF}' \
      | while read -r p; do
            [ -n "$(model_row "$p")" ] && echo "$p"
        done
}

detect_by_name() {
    ioreg -p IOUSB -w0 -l 2>/dev/null | tr 'A-Z' 'a-z' \
      | grep -qi 'm1005' && echo "m1005"
}

# Locate a Homebrew/PATH binary on either Apple Silicon or Intel (like watcher).
find_bin() {
    for p in /opt/homebrew/bin/"$1" /usr/local/bin/"$1" "$(command -v "$1" 2>/dev/null)"; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
}

# ---------------------------------------------------------------------------
printf '%shp-laserjet-doctor%s — self-test for hp-laserjet-mac-driver\n' "$C_B" "$C_0"
[ "$(uname)" = "Darwin" ] || { fail "macOS only (uname is $(uname))."; exit 1; }

# --- 1. dependencies --------------------------------------------------------
hdr "Dependencies"
GS=$(find_bin gs || true)
PDFINFO=$(find_bin pdfinfo || true)

if [ -n "$GS" ]; then pass "ghostscript (gs): $GS"
else fail "ghostscript (gs) not found — run: brew install ghostscript"; fi

if [ -n "$PDFINFO" ]; then pass "poppler (pdfinfo): $PDFINFO"
else warn "poppler (pdfinfo) not found — paper auto-detect degrades; run: brew install poppler"; fi

# libusb: fwload is linked against it; probe both Homebrew prefixes.
LIBUSB=""
for d in /opt/homebrew/lib /usr/local/lib; do
    for f in "$d"/libusb-1.0.*dylib; do
        [ -e "$f" ] && { LIBUSB="$f"; break; }
    done
    [ -n "$LIBUSB" ] && break
done
if [ -n "$LIBUSB" ]; then pass "libusb: $LIBUSB"
else warn "libusb dylib not found in Homebrew lib dirs — run: brew install libusb"; fi

if [ -x "$FWLOAD" ]; then
    fw_perm=$(stat -f '%Sp' "$FWLOAD" 2>/dev/null || echo '?')
    pass "fwload installed: $FWLOAD ($fw_perm)"
    case "$fw_perm" in
        *s*) : ;;                                  # setuid bit present, good
        *)   warn "fwload is not setuid root; USB claim may fail — re-run install.sh" ;;
    esac
else
    fail "fwload missing at $FWLOAD — run install.sh"
fi

for conv in "$FOO2ZJS" "$FOO2XQX"; do
    if [ -x "$conv" ]; then pass "converter present: $conv"
    else fail "converter missing: $conv — run install.sh"; fi
done

# --- 2. spool + logs --------------------------------------------------------
hdr "Spool and logs"
if [ -d "$SPOOL" ]; then
    pass "spool dir: $SPOOL"
    shopt -s nullglob
    queued=( "$SPOOL"/job-*.pdf )
    info "queued jobs: ${#queued[@]}"
    if [ -f "$LOG" ]; then info "watcher log: $LOG ($(wc -c < "$LOG" | tr -d ' ') bytes)"
    else info "watcher log: none yet ($LOG)"; fi
else
    warn "spool dir missing ($SPOOL) — created by install.sh; the watcher makes it on first run"
fi

# --- 3. printer detection ---------------------------------------------------
hdr "Printer detection (ioreg, VID $VID)"
DRIVER="" ; FW_NAME="" ; RES="" ; XSCALE="" ; PID="" ; ROW=""

ALL_PIDS=$(detect_all_pids || true)
N_PIDS=$(printf '%s\n' "$ALL_PIDS" | grep -c '^0x' || true)

if [ "$N_PIDS" -ge 1 ]; then
    if [ "$N_PIDS" -gt 1 ]; then
        warn "multiple supported printers on the bus: $(echo $ALL_PIDS | tr '\n' ' ')"
        info "the watcher picks one via PRINTER= (config/sidecar) or the lowest PID;"
        info "the doctor tests the lowest PID present."
        PID=$(printf '%s\n' $ALL_PIDS | sort | head -n1)
    else
        PID=$(printf '%s\n' $ALL_PIDS | head -n1)
    fi
    ROW=$(model_row "$PID")
    pass "detected supported printer PID=$PID"
elif detect_by_name >/dev/null 2>&1 && [ -n "$(detect_by_name || true)" ]; then
    # Name fallback (M1005 whose PID may differ from the documented 0x3b17).
    NAME=$(detect_by_name)
    ROW=$(name_row "$NAME")
    PID=0x3b17
    pass "detected printer by product name ($NAME) -> PID $PID"
else
    # DEFER — never guess a model. This mirrors the watcher's no-printer path.
    fail "no supported HP LaserJet detected on USB"
    info "Guidance:"
    info "  • power the printer on and connect it directly by USB (avoid hubs if flaky)"
    info "  • re-run: hp-laserjet-doctor"
    info "  • confirm the OS sees it:  ioreg -p IOUSB -w0 -l | grep -i idProduct"
    info "  • the driver never guesses a model — a wrong protocol/firmware would misprint"
    hdr "Summary"
    printf '    %s%d passed%s, %s%d warned%s, %s%d failed%s\n' \
        "$C_G" "$PASS_N" "$C_0" "$C_Y" "$WARN_N" "$C_0" "$C_R" "$FAIL_N" "$C_0"
    exit 1
fi

# Derive per-model globals from the row (same fields as the watcher's apply_row).
DRIVER=$(echo "$ROW"  | awk '{print $1}')
FW_NAME=$(echo "$ROW" | awk '{print $2}')
RES=$(echo "$ROW"     | awk '{print $3}')
XSCALE=$(echo "$ROW"  | awk '{print $4}')
FW="$FWDIR/$FW_NAME"
case "$DRIVER" in
    foo2xqx) CONV="$FOO2XQX" ;;
    *)       CONV="$FOO2ZJS" ;;
esac
info "model row: driver=$DRIVER firmware=$FW_NAME res=$RES xscale=$XSCALE"

# --- 4. firmware blob -------------------------------------------------------
hdr "Firmware (dry-run)"
if [ -f "$FW" ]; then
    fw_sz=$(wc -c < "$FW" | tr -d ' ')
    pass "firmware blob present: $FW ($fw_sz bytes)"
    if [ "$DO_PUSH" -eq 1 ]; then
        if [ -x "$FWLOAD" ]; then
            info "--push: uploading firmware over USB (fwload)..."
            if "$FWLOAD" "$FW" "$VID" "$PID"; then pass "firmware push OK (fwload exit 0)"
            else fail "firmware push failed (fwload non-zero) — check USB / permissions"; fi
        else
            fail "--push requested but fwload is missing at $FWLOAD"
        fi
    else
        info "(dry-run) firmware NOT pushed; pass --push to upload over USB"
    fi
else
    fail "firmware blob missing: $FW — re-run install.sh with the printer attached"
fi

# --- 5. test page conversion ------------------------------------------------
hdr "Test page conversion"
TMPDIR_D=$(mktemp -d /tmp/hp-laserjet-doctor.XXXXXX)
cleanup() { rm -rf "$TMPDIR_D"; }
trap cleanup EXIT
TESTPDF="$TMPDIR_D/testpage.pdf"
RASTER="$TMPDIR_D/testpage.raster"

# Generate a 1-page US-Letter test PDF from a small PostScript here-doc via gs.
gen_ok=0
if [ -n "$GS" ]; then
    cat > "$TMPDIR_D/testpage.ps" <<'PS'
%!PS-Adobe-3.0
%%Pages: 1
%%BoundingBox: 0 0 612 792
/Helvetica-Bold findfont 28 scalefont setfont
72 700 moveto (hp-laserjet-doctor) show
/Helvetica findfont 14 scalefont setfont
72 670 moveto (Self-test page. If this prints, the full pipeline works.) show
72 645 moveto (gs -> foo2zjs|foo2xqx -> fwload -> USB) show
% a border + alignment marks so a real print is easy to eyeball
2 setlinewidth 40 40 532 712 rectstroke
72 100 moveto (Bottom-left mark) show
440 740 moveto (Top-right mark) show
showpage
PS
    if "$GS" -q -dBATCH -dNOPAUSE -dSAFER -sDEVICE=pdfwrite \
            -sOutputFile="$TESTPDF" "$TMPDIR_D/testpage.ps" >/dev/null 2>&1 \
       && [ -s "$TESTPDF" ]; then
        gen_ok=1
        pass "generated 1-page test PDF ($(wc -c < "$TESTPDF" | tr -d ' ') bytes)"
    else
        fail "test PDF generation failed (gs pdfwrite)"
    fi
else
    fail "cannot generate test PDF — ghostscript missing"
fi

# Dry conversion: PDF -> pbmraw -> raster, reporting byte counts, no USB write.
if [ "$gen_ok" -eq 1 ] && [ -x "$CONV" ]; then
    # US-Letter geometry for the detected model (base 5100x6600, width * XSCALE).
    GDIM="$(( 5100 * XSCALE ))x6600"
    if [ "$DRIVER" = foo2xqx ]; then CONV_FLAGS="-P -L0 -r$RES -g$GDIM -p1"
    else CONV_FLAGS="-z2 -P -L0 -r$RES -g$GDIM -p1 -T5"; fi
    info "converter: $CONV $CONV_FLAGS"
    if "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
             -sDEVICE=pbmraw -r"$RES" -g"$GDIM" \
             -dFIXEDMEDIA -dPDFFitPage \
             -sOutputFile=- "$TESTPDF" 2>/dev/null \
         | "$CONV" $CONV_FLAGS > "$RASTER" 2>/dev/null; then
        sz=$(wc -c < "$RASTER" | tr -d ' ')
        if [ "$sz" -ge 32 ]; then pass "dry conversion produced $sz bytes of $DRIVER raster"
        else fail "dry conversion produced only $sz bytes (empty/short) — pipeline broken"; fi
    else
        fail "dry conversion pipeline failed (gs | $DRIVER)"
    fi
elif [ "$gen_ok" -eq 1 ]; then
    fail "converter $CONV missing — cannot run dry conversion"
fi

# --print: push the raster to the printer over USB (the real end-to-end test).
if [ "$DO_PRINT" -eq 1 ]; then
    hdr "Print test page (--print)"
    if [ -s "$RASTER" ] && [ -x "$FWLOAD" ]; then
        info "pushing test raster to the printer over USB..."
        if "$FWLOAD" "$RASTER" "$VID" "$PID"; then pass "test page pushed (fwload exit 0) — check the printer output"
        else fail "test page push failed (fwload non-zero)"; fi
    else
        fail "--print requested but no raster produced or fwload missing"
    fi
fi

# --- summary ----------------------------------------------------------------
hdr "Summary"
printf '    %s%d passed%s, %s%d warned%s, %s%d failed%s\n' \
    "$C_G" "$PASS_N" "$C_0" "$C_Y" "$WARN_N" "$C_0" "$C_R" "$FAIL_N" "$C_0"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0
