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
SPOOL="$HOME/HP-LaserJet-spool"
LOG="$SPOOL/watcher.log"

VID=0x03f0   # HP — same vendor for the whole family

# ---------------------------------------------------------------------------
CONFIG_FILE="${HP_LASERJET_CONFIG:-$HOME/.config/hp-laserjet/config}"

# Config-backed settings, with safe defaults. Populated by load_config().
PAPER=auto
DENSITY=""
DEFAULT_COPIES=1
DEFAULT_DUPLEX=none          # none | long | short
DEFAULT_NUP=1                # pages per sheet (converters only support 1)

load_config() {
    # Keep the no-config path a strict no-op: only source when the file exists.
    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    # Re-assert safe defaults for anything the file left blank or set oddly.
    case "$PAPER" in letter|a4|auto) ;; *) PAPER=auto ;; esac
    [ -n "$DEFAULT_COPIES" ] || DEFAULT_COPIES=1
    case "$DEFAULT_DUPLEX" in none|long|short) ;; *) DEFAULT_DUPLEX=none ;; esac
    [ -n "$DEFAULT_NUP" ] || DEFAULT_NUP=1
}

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

# Keep the log from growing forever.
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && : > "$LOG"
echo "=== $(date) watcher woke ===" >> "$LOG"

# Load optional user config (no-op when the file is absent).
load_config

if [ -z "$GS" ]; then
    echo "  ERROR: ghostscript (gs) not found — run: brew install ghostscript" >> "$LOG"
    exit 1
fi

# --- detect which supported printer is actually connected ------------------
# Scan USB for an HP (0x03f0) product id we have a row for, then fall back to a
# product-name match (catches the M1005 whose PID is not documented). If both
# fail, default to the P1102 (keeps behaviour for the original model).
DRIVER="" ; FW_NAME="" ; RES="" ; XSCALE="" ; PID=""

# We read USB via `ioreg`, not `system_profiler SPUSBDataType`: on macOS Tahoe
# (26.x) the latter returns nothing at all (empty, no error), which made the
# watcher mis-detect every printer and fall back to the P1102 default. ioreg
# reports idProduct/idVendor in decimal, so we reformat to 0xXXXX.
detect_by_pid() {
    ioreg -p IOUSB -w0 -l 2>/dev/null \
      | awk '/"idProduct" =/ {printf "0x%04x\n", $NF}' \
      | while read -r p; do
            [ -n "$(model_row "$p")" ] && { echo "$p"; break; }
        done
}

detect_by_name() {
    ioreg -p IOUSB -w0 -l 2>/dev/null | tr 'A-Z' 'a-z' \
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
        # No supported printer on the bus right now (off, mid power-cycle, or
        # re-enumerating). Do NOT guess a default model: driving whatever job
        # is queued as a P1102 would push the wrong protocol/firmware at the
        # wrong interface on any other model. Leave the jobs in the spool and
        # bail — launchd re-runs us when the spool changes, and printing again
        # (or powering the printer on) will re-trigger detection.
        echo "  no supported printer detected — deferring queued jobs" >> "$LOG"
        exit 0
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

# Map a friendly duplex name to the converter's numeric -d code. Both foo2zjs
# and foo2xqx share the same DMDUPLEX_* enum (hiperc.h / hbpl.h):
#   1 OFF   2 LONGEDGE   3 SHORTEDGE   4 MANUALLONG   5 MANUALSHORT
duplex_code() {   # $1 = none|long|short  ->  numeric code on stdout
    case "$1" in
        long)  echo 2 ;;
        short) echo 3 ;;
        *)     echo 1 ;;   # none / unknown -> simplex
    esac
}

# Build the raster-converter flag string for the current job. Reads the same
# per-model values the inline block used ($DRIVER, $RES, $GDIM, $PCODE) and the
# per-job option vars set by read_job_opts ($COPIES, $JOB_DUPLEX). Echoes the
# flags on one line. foo2zjs takes ZjStream compression (-z2) and -T5; foo2xqx
# does not.
#
# Extra per-job flags (appended by job_extra_flags):
#   -n N   copies      — encoded in the ZjStream by foo2zjs. foo2xqx PARSES -n
#                        but never writes it to the stream, so for XQX copies
#                        are realised by pushing the raster N times (see the
#                        job loop); we therefore omit -n there.
#   -d N   duplex code — both converters accept it. These host-based units are
#                        typically simplex-only (no hardware duplexer), so a
#                        duplex request is passed through but WARNED about; on a
#                        printer with no duplexer it simply prints one-sided.
build_conv_flags() {
    local base extra
    if [ "$DRIVER" = foo2xqx ]; then
        base="-P -L0 -r$RES -g$GDIM -p$PCODE"
    else
        base="-z2 -P -L0 -r$RES -g$GDIM -p$PCODE -T5"
    fi
    extra=$(job_extra_flags)
    if [ -n "$extra" ]; then
        echo "$base $extra"
    else
        echo "$base"
    fi
}

# Compute the per-job duplex/copies flags to append to the converter command.
# Emits nothing when the job uses the plain defaults (COPIES=1, no duplex), so
# the default flag string stays byte-identical to the pre-feature output.
job_extra_flags() {
    local flags="" dc
    # Copies: only foo2zjs encodes -n into the stream; for foo2xqx the job loop
    # re-pushes the raster instead, so don't pass -n to it.
    if [ "$DRIVER" != foo2xqx ] && [ "${COPIES:-1}" -gt 1 ] 2>/dev/null; then
        flags="-n $COPIES"
    fi
    # Duplex: pass the code through for both converters when requested.
    if [ "${JOB_DUPLEX:-none}" != none ]; then
        dc=$(duplex_code "$JOB_DUPLEX")
        flags="${flags:+$flags }-d $dc"
    fi
    echo "$flags"
}

# Per-job options.
#
# A job MAY be accompanied by a sidecar file "job-<ts>.opts" sitting next to its
# "job-<ts>.pdf" in the spool dir. The sidecar is a plain KEY=value fragment
# carrying per-job overrides:
#
#   COPIES=2       print N copies                (int; >=1)
#   DUPLEX=long    two-sided: none|long|short    (simplex units: WARNED)
#   NUP=2          N pages per sheet             (converters lack N-up; WARNED)
#   DENSITY=3      per-job print-density override
#
# Only these four keys are honoured; any other line is ignored. Values are read
# with a small, injection-safe parser (the sidecar is NOT sourced). Jobs with
# no .opts file are wholly unaffected: the vars fall back to their config /
# built-in defaults, and job_extra_flags then emits nothing.
read_job_opts() {   # $1 = path to the job's .opts sidecar (may not exist)
    COPIES="$DEFAULT_COPIES"
    JOB_DENSITY="$DENSITY"
    JOB_DUPLEX="$DEFAULT_DUPLEX"
    JOB_NUP="$DEFAULT_NUP"

    local sidecar="$1" key val
    if [ -f "$sidecar" ]; then
        # Read KEY=value lines without executing the file. Ignore blanks and
        # comments; trim surrounding whitespace on the value.
        while IFS='=' read -r key val; do
            key=$(printf '%s' "$key" | tr -d '[:space:]')
            val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            case "$key" in
                ''|\#*) continue ;;
                COPIES)  [ -n "$val" ] && COPIES="$val" ;;
                DENSITY) [ -n "$val" ] && JOB_DENSITY="$val" ;;
                DUPLEX)  [ -n "$val" ] && JOB_DUPLEX="$val" ;;
                NUP)     [ -n "$val" ] && JOB_NUP="$val" ;;
            esac
        done < "$sidecar"
    fi

    # Validate / normalise.
    case "$COPIES" in ''|*[!0-9]*) COPIES=1 ;; esac
    [ "$COPIES" -ge 1 ] 2>/dev/null || COPIES=1
    case "$JOB_DUPLEX" in none|long|short) ;; *) JOB_DUPLEX=none ;; esac
    case "$JOB_NUP" in ''|*[!0-9]*) JOB_NUP=1 ;; esac
    [ "$JOB_NUP" -ge 1 ] 2>/dev/null || JOB_NUP=1

    # Warn about requests these host-based printers / converters can't fulfil.
    if [ "$JOB_DUPLEX" != none ]; then
        echo "  NOTE: duplex=$JOB_DUPLEX requested — most host-based LaserJets are" >> "$LOG"
        echo "        simplex-only (no hardware duplexer); passing -d through anyway" >> "$LOG"
    fi
    if [ "$JOB_NUP" -gt 1 ]; then
        echo "  NOTE: nup=$JOB_NUP requested but neither foo2zjs nor foo2xqx supports" >> "$LOG"
        echo "        N-up; printing 1-up. (No N-up flag exists in either.)" >> "$LOG"
    fi
    return 0
}

shopt -s nullglob
for PDF in "$SPOOL"/job-*.pdf; do
    echo "processing $PDF" >> "$LOG"
    OPTS="${PDF%.pdf}.opts"
    TMP=$(mktemp /tmp/hp-laserjet.XXXXXX.raster)

    # Load any per-job overrides from the sidecar (falls back to config).
    read_job_opts "$OPTS"

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
    # build_conv_flags() emits the exact flag string for this driver/geometry.
    CONV_FLAGS=$(build_conv_flags)
    "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
          -sDEVICE=pbmraw -r$RES -g$GDIM \
          -dFIXEDMEDIA -dPDFFitPage \
          -sOutputFile=- "$PDF" 2>>"$LOG" \
      | "$CONV" $CONV_FLAGS > "$TMP" 2>>"$LOG"

    sz=$(wc -c < "$TMP")
    echo "  raster $sz bytes" >> "$LOG"

    if [ "$sz" -ge 32 ]; then
        # foo2zjs encodes copies in-stream (-n above); foo2xqx does not, so for
        # XQX printers we realise copies by pushing the raster N times. For
        # foo2zjs the raster already carries the copy count, so push once.
        pushes=1
        if [ "$DRIVER" = foo2xqx ] && [ "${COPIES:-1}" -gt 1 ]; then
            pushes="$COPIES"
            echo "  foo2xqx: copies=$COPIES via $pushes raster pushes" >> "$LOG"
        fi
        i=1
        while [ "$i" -le "$pushes" ]; do
            "$FWLOAD" "$TMP" "$VID" "$PID" >>"$LOG" 2>&1
            echo "  fwload exit $? (push $i/$pushes)" >> "$LOG"
            i=$((i + 1))
        done
    else
        echo "  empty conversion, skipped" >> "$LOG"
    fi
    rm -f "$TMP" "$PDF" "$OPTS"
done
