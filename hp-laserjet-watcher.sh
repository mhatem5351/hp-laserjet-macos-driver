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
# Optional user configuration.
#
# ~/.config/hp-laserjet/config is a plain KEY=value shell fragment sourced by
# the watcher. The watcher runs unsandboxed as the user, so sourcing the user's
# own file crosses no privilege boundary — it is treated like any other dotfile
# the user controls. All keys are optional; if the file is absent the defaults
# below are used and behaviour is byte-for-byte identical to having no config.
#
#   PAPER=letter|a4|auto     paper size (default auto = detect from the PDF)
#   DENSITY=<n>              print density; unset = driver default (no flag)
#   DEFAULT_COPIES=<n>       default copy count for a job (default 1)
#   PRINTER=<pid|name>       when several supported printers are attached, which
#                            one to use: a USB PID (e.g. 0x002a) or a substring
#                            of the product name (e.g. m1005). Ignored when only
#                            one supported printer is present. Default unset.
#
# See docs/CONFIG.md for the full description and the per-job .opts sidecar.
# ---------------------------------------------------------------------------
CONFIG_FILE="${HP_LASERJET_CONFIG:-$HOME/.config/hp-laserjet/config}"

# Config-backed settings, with safe defaults. Populated by load_config().
PAPER=auto
DENSITY=""
DEFAULT_COPIES=1
PRINTER=""

load_config() {
    # Keep the no-config path a strict no-op: only source when the file exists.
    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    # Re-assert safe defaults for anything the file left blank or set oddly.
    case "$PAPER" in letter|a4|auto) ;; *) PAPER=auto ;; esac
    [ -n "$DEFAULT_COPIES" ] || DEFAULT_COPIES=1
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

# --- multi-printer support -------------------------------------------------
# detect_all_pids() enumerates EVERY connected HP (0x03f0) product id we have a
# model_row for, in ioreg order, one per line. This is the exact same ioreg+awk
# scan detect_by_pid() uses (ioreg only — system_profiler is broken on Tahoe),
# just without the "stop at first" cutoff. Used solely to decide whether more
# than one supported printer is attached; when only one is, the original
# single-printer path below runs unchanged.
detect_all_pids() {
    ioreg -p IOUSB -w0 -l 2>/dev/null \
      | awk '/"idProduct" =/ {printf "0x%04x\n", $NF}' \
      | while read -r p; do
            [ -n "$(model_row "$p")" ] && echo "$p"
        done
}

# select_printer() picks the target PID when SEVERAL supported printers are on
# the bus. Preference order, all restricted to PIDs actually present ($1..$N):
#   1. a value matching $WANT (per-job .opts PRINTER=, else config PRINTER=),
#      matched first as an exact PID, then as a product-name substring;
#   2. otherwise a deterministic primary: the lexicographically-lowest PID.
# Echoes the chosen PID. $WANT is read from the caller's $WANT variable.
# pid_names() emits "0xPID<TAB>lowercased-product-name" pairs, one per USB
# device node that has both a product id and a product-name string. It walks the
# same ioreg tree; nodes begin with "+-o", so we reset per node and print when
# the node closes (or the next node starts). Used to resolve a PRINTER= name
# substring back to a concrete present PID. ioreg only (Tahoe-safe).
pid_names() {
    ioreg -p IOUSB -w0 -l 2>/dev/null | awk '
        function flush() { if (pid != "" && nm != "") printf "%s\t%s\n", pid, tolower(nm) }
        /\+-o /                    { flush(); pid=""; nm="" }
        /"idProduct" =/            { pid = sprintf("0x%04x", $NF) }
        /"USB Product Name" =/ ||
        /"kUSBProductString" =/    { n=$0; sub(/^[^=]*= /,"",n); gsub(/"/,"",n); nm=n }
        END                        { flush() }
    '
}

# select_printer() picks the target PID when SEVERAL supported printers are on
# the bus, restricted to the PIDs actually present ($1..$N):
#   1. $WANT as an exact PID;
#   2. $WANT as a product-name substring, mapped back to a present PID;
#   3. otherwise a deterministic primary: the lexicographically-lowest PID.
# Echoes the chosen PID. $WANT is read from the caller's $WANT variable.
select_printer() {   # $@ = list of present supported PIDs
    local want="$WANT" want_lc p np name
    if [ -n "$want" ]; then
        want_lc=$(printf '%s' "$want" | tr 'A-Z' 'a-z')
        # (a) exact PID match against the present set.
        for p in "$@"; do
            [ "$p" = "$want_lc" ] && { echo "$p"; return 0; }
        done
        # (b) product-name substring match, mapped back to a present PID.
        while IFS="$(printf '\t')" read -r np name; do
            case "$name" in
                *"$want_lc"*)
                    for p in "$@"; do
                        [ "$p" = "$np" ] && { echo "$p"; return 0; }
                    done ;;
            esac
        done <<EOF
$(pid_names)
EOF
        # (c) M1005 fallback: its documented PID may be present even when the
        #     name line is absent from this node walk.
        case "$want_lc" in
            *m1005*)
                for p in "$@"; do
                    [ "$p" = "0x3b17" ] && { echo "$p"; return 0; }
                done ;;
        esac
    fi
    # Deterministic primary: lowest PID present (stable across ioreg ordering).
    printf '%s\n' "$@" | sort | head -n1
}

# Enumerate all supported printers to decide single vs multi.
ALL_PIDS=$(detect_all_pids)
N_PIDS=$(printf '%s\n' "$ALL_PIDS" | grep -c '^0x')

if [ "$N_PIDS" -gt 1 ]; then
    # MULTIPLE supported printers attached. Route deliberately instead of
    # silently taking the first. WANT comes from config PRINTER= (a per-job
    # .opts PRINTER= can still override inside the job loop). Log the choice
    # and the ones ignored so behaviour is predictable.
    WANT="$PRINTER"
    # shellcheck disable=SC2086
    PID=$(select_printer $ALL_PIDS)
    ROW=$(model_row "$PID")
    IGNORED=$(printf '%s\n' $ALL_PIDS | grep -v "^$PID$" | tr '\n' ' ')
    echo "  multiple supported printers detected: $(echo $ALL_PIDS | tr '\n' ' ')" >> "$LOG"
    if [ -n "$PRINTER" ]; then
        echo "  PRINTER=$PRINTER -> selected $PID (ignoring: ${IGNORED% })" >> "$LOG"
    else
        echo "  no PRINTER set; defaulting to lowest PID $PID (ignoring: ${IGNORED% }) — set PRINTER in $CONFIG_FILE to choose" >> "$LOG"
    fi
elif [ "$N_PIDS" -eq 1 ]; then
    # Exactly one supported printer: original single-printer path, unchanged.
    PID=$(detect_by_pid)
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

# apply_row() derives the per-model globals (DRIVER/FW_NAME/RES/XSCALE/FW/CONV)
# from a model-table row and logs the active printer. Factored out so a per-job
# PRINTER override can re-point these mid-loop when several printers are
# attached; the single-printer path calls it exactly once, right here, so its
# result is identical to the previous inline assignment.
apply_row() {   # $1 = row string from model_row/name_row
    DRIVER=$(echo "$1"  | awk '{print $1}')
    FW_NAME=$(echo "$1" | awk '{print $2}')
    RES=$(echo "$1"     | awk '{print $3}')
    XSCALE=$(echo "$1"  | awk '{print $4}')
    FW="$FWDIR/$FW_NAME"
    # Pick the raster converter for this printer's protocol.
    case "$DRIVER" in
        foo2xqx) CONV="$FOO2XQX" ;;
        *)       CONV="$FOO2ZJS" ;;
    esac
    echo "  printer PID=$PID driver=$DRIVER firmware=$FW_NAME res=$RES xscale=$XSCALE" >> "$LOG"
}

apply_row "$ROW"

# Remember the default selection so per-job PRINTER overrides don't leak from
# one job to the next (a job with no override always uses the default printer).
DEFAULT_PID="$PID"
DEFAULT_ROW="$ROW"

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

# Build the raster-converter flag string for the current job. Reads the same
# per-model values the inline block used ($DRIVER, $RES, $GDIM, $PCODE) and
# echoes the flags on one line. foo2zjs takes ZjStream compression (-z2) and
# -T5; foo2xqx does not. Kept a function so downstream features (density,
# duplex, N-up) have one place to extend the flag string.
build_conv_flags() {
    if [ "$DRIVER" = foo2xqx ]; then
        echo "-P -L0 -r$RES -g$GDIM -p$PCODE"
    else
        echo "-z2 -P -L0 -r$RES -g$GDIM -p$PCODE -T5"
    fi
}

# Per-job options (placeholder).
#
# A job MAY be accompanied by a sidecar file "job-<ts>.opts" sitting next to its
# "job-<ts>.pdf" in the spool dir. The sidecar is a plain KEY=value fragment
# carrying per-job overrides that later features will populate and honour, e.g.:
#
#   COPIES=2       duplicate the job N times     (F1/F8)
#   DUPLEX=long    two-sided printing            (F1)
#   NUP=2          N pages per sheet             (future)
#   DENSITY=3      per-job print-density override(F8)
#
# For now this is a no-op that only establishes the structure: it resets the
# per-job option vars to their config/default values so each iteration starts
# clean, and does NOT read the sidecar yet. Jobs with no .opts file are wholly
# unaffected. Downstream features will parse "$1" here and set the vars.
read_job_opts() {   # $1 = path to the job's .opts sidecar (may not exist)
    COPIES="$DEFAULT_COPIES"
    JOB_DENSITY="$DENSITY"
    JOB_PRINTER=""
    # Minimal, scoped sidecar parsing: this feature only reads PRINTER= (a PID
    # or product-name substring) to route this one job when several printers
    # are attached. Other keys stay unparsed here for downstream features to
    # fill in. We extract PRINTER= with a line-anchored grep rather than
    # sourcing, so a malformed sidecar cannot run arbitrary code per job.
    [ -f "$1" ] || return 0
    JOB_PRINTER=$(grep -E '^[[:space:]]*PRINTER[[:space:]]*=' "$1" 2>/dev/null \
                    | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' \
                    | tr -d '"'"'"'')
    return 0
}

shopt -s nullglob
for PDF in "$SPOOL"/job-*.pdf; do
    echo "processing $PDF" >> "$LOG"
    TMP=$(mktemp /tmp/hp-laserjet.XXXXXX.raster)

    # Load any per-job overrides from the sidecar (COPIES/DENSITY unparsed here;
    # this feature reads only PRINTER=).
    read_job_opts "${PDF%.pdf}.opts"

    # Per-job printer override: only meaningful when several supported printers
    # are attached. Re-select against the present set using this job's PRINTER=
    # and, if it resolves to a different printer than the current one, re-derive
    # the per-model globals for this job. In single-printer mode N_PIDS<=1 so
    # this whole block is skipped and behaviour is byte-identical to before.
    if [ "$N_PIDS" -gt 1 ]; then
        # Start every job from the default selection so an override on one job
        # never leaks to the next.
        if [ "$PID" != "$DEFAULT_PID" ]; then
            PID="$DEFAULT_PID"
            apply_row "$DEFAULT_ROW"
        fi
        if [ -n "$JOB_PRINTER" ]; then
            WANT="$JOB_PRINTER"
            # shellcheck disable=SC2086
            JPID=$(select_printer $ALL_PIDS)
            if [ -n "$JPID" ] && [ "$JPID" != "$PID" ]; then
                echo "  job PRINTER=$JOB_PRINTER -> routing this job to $JPID" >> "$LOG"
                PID="$JPID"
                apply_row "$(model_row "$PID")"
            fi
        fi
    fi

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
        "$FWLOAD" "$TMP" "$VID" "$PID" >>"$LOG" 2>&1
        echo "  fwload exit $?" >> "$LOG"
    else
        echo "  empty conversion, skipped" >> "$LOG"
    fi
    rm -f "$TMP" "$PDF"
done
