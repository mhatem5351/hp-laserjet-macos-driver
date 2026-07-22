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
#   PAPER=auto|letter|a4|legal|a5|executive|com10|dl
#                            paper size (default auto = detect from the PDF).
#                            An explicit value forces the size + raster grid.
#   SCALE=<percent>          scale the page during rasterisation (gs); unset =
#                            no scaling (default; identical to prior behaviour).
#   MARGIN=<points>          uniform blank inset applied during rasterisation
#                            (gs); unset = none (default; identical to prior).
#   DENSITY=<1-5>            print density (foo2* -T); unset = driver default
#   ECONOMODE=on|off         toner-save/draft (foo2* -t); unset/off = no flag
#   DEFAULT_COPIES=<n>       default copy count for a job (default 1)
#   DEFAULT_DUPLEX=none|long|short   default duplex mode (default none)
#   DEFAULT_NUP=<n>          default pages per sheet (only 1 is honoured)
#   NOTIFY=all|errors|none   macOS notifications (default all)
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
SCALE=""
MARGIN=""
DENSITY=""
ECONOMODE=""
DEFAULT_COPIES=1
DEFAULT_DUPLEX=none          # none | long | short
DEFAULT_NUP=1                # pages per sheet (converters only support 1)
NOTIFY=all
PRINTER=""

load_config() {
    # Keep the no-config path a strict no-op: only source when the file exists.
    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    # Re-assert safe defaults for anything the file left blank or set oddly.
    case "$PAPER" in
        auto|letter|a4|legal|a5|executive|com10|dl) ;;
        *) PAPER=auto ;;
    esac
    [ -n "$DEFAULT_COPIES" ] || DEFAULT_COPIES=1
    case "$DEFAULT_DUPLEX" in none|long|short) ;; *) DEFAULT_DUPLEX=none ;; esac
    [ -n "$DEFAULT_NUP" ] || DEFAULT_NUP=1
    case "$NOTIFY" in all|errors|none) ;; *) NOTIFY=all ;; esac
}

# ---------------------------------------------------------------------------
# macOS user notifications (best-effort UX; never affects job processing).
#
# The watcher runs from a launchd *user agent*, so osascript can post a
# Notification Center banner. A notification must never influence the pipeline
# or a job's exit status, so every path is guarded: we skip when osascript is
# absent and swallow any failure with `|| true`.
#
# Messages carry only the printer model/driver label and the job outcome —
# never a home path, username, or other personal data.
#
# NOTIFY gates what is posted:
#   all     success + failure/defer   (default)
#   errors  failure/defer only
#   none    nothing
# ---------------------------------------------------------------------------
notify() {   # $1 = level (success|error)   $2 = message
    level="$1" ; msg="$2"
    case "$NOTIFY" in
        none)   return 0 ;;
        errors) [ "$level" = success ] && return 0 ;;
    esac
    command -v osascript >/dev/null 2>&1 || return 0
    # Strip characters that would break out of the AppleScript string literal.
    msg=${msg//\\/}
    msg=${msg//\"/}
    osascript -e "display notification \"$msg\" with title \"HP LaserJet\"" \
        >/dev/null 2>&1 || true
    return 0
}

# Short, personal-data-free label for the detected printer (PID + driver).
printer_label() {
    echo "${PID:-?} (${DRIVER:-?})"
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
    notify error "Setup incomplete: Ghostscript missing — run: brew install ghostscript"
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
        # Notify once, but only if a job is actually waiting — otherwise a
        # launchd re-fire on an empty spool would spam the defer banner. This
        # is a failure-class notification (suppressed when NOTIFY=none).
        shopt -s nullglob
        set -- "$SPOOL"/job-*.pdf
        [ "$#" -gt 0 ] && notify error "Printer not detected — job queued"
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
    notify error "Setup incomplete: converter missing — re-run install.sh"
    exit 1
fi
if [ ! -f "$FW" ]; then
    echo "  ERROR: firmware $FW missing — re-run install.sh with printer attached" >> "$LOG"
    notify error "Setup incomplete: firmware missing — re-run install.sh"
    exit 1
fi

# Paper grid, in pixels, for this model's RES. The base grid is the page size
# in 600-dpi pixels (inches * 600); the across dimension is multiplied by
# XSCALE for the 1200x600 models (which expect doubled pixels across).
grid_for() {   # $1 = base-width  $2 = height
    echo "$(( $1 * XSCALE ))x$2"
}

# paper_spec() maps a paper name to "<PCODE> <base_width_px> <height_px>", where
# PCODE is the foo2zjs/foo2xqx -p paper code (DMPAPER_* in hbpl.h / hiperc.h,
# identical in both converters) and the pixel dims are the 600-dpi base grid
# (inches * 600; the across dim is later * XSCALE by grid_for). Codes and sizes:
#
#   name       PCODE  DMPAPER_*        size            600dpi base grid (WxH)
#   letter       1    LETTER           8.5 x 11 in      5100 x 6600
#   legal        5    LEGAL            8.5 x 14 in      5100 x 8400
#   executive    7    EXECUTIVE        7.25 x 10.5 in   4350 x 6300
#   a4           9    A4               210 x 297 mm     4960 x 7016
#   a5          11    A5               148 x 210 mm     3500 x 4960
#   com10       20    ENV_10           4.125 x 9.5 in   2475 x 5700
#   dl          27    ENV_DL           110 x 220 mm     2600 x 5200
#
# a5/dl dims are rounded to the same round-number convention as the pre-existing
# letter/a4 rows (A4's 4960 vs exact 4961). Unknown names => "" (caller falls
# back to Letter, preserving current behaviour).
paper_spec() {   # $1 = paper name  ->  "PCODE BASEW HEIGHT" on stdout
    case "$1" in
        letter)    echo "1 5100 6600" ;;
        legal)     echo "5 5100 8400" ;;
        executive) echo "7 4350 6300" ;;
        a4)        echo "9 4960 7016" ;;
        a5)        echo "11 3500 4960" ;;
        com10)     echo "20 2475 5700" ;;
        dl)        echo "27 2600 5200" ;;
        *)         echo "" ;;
    esac
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
    local flags extra
    if [ "$DRIVER" = foo2xqx ]; then
        flags="-P -L0 -r$RES -g$GDIM -p$PCODE"
    else
        flags="-z2 -P -L0 -r$RES -g$GDIM -p$PCODE -T5"
    fi

    # --- print quality / density (F8) --------------------------------------
    # Both foo2zjs and foo2xqx accept the same geometry-safe quality flags:
    #   -T <1-5>   print density  (foo2*.c usage: "-T density  Print density
    #              (1-5)"; getopt "T:" -> PrintDensity, range-checked 1..5)
    #   -t         draft/toner-save; on these models the driver maps SaveToner
    #              to EconoMode=1 (foo2*.c: "case 't': SaveToner = 1").
    # Neither touches -r/-g, so appending them cannot desync the paper grid.
    #
    # Appended (not woven in) so the no-density path stays byte-identical to
    # the base string above. For foo2zjs the base already carries -T5; a later
    # -T<n> simply overrides it (getopt keeps the last -T), so an explicit
    # DENSITY still wins. When JOB_DENSITY is unset/empty nothing is added.
    if [ -n "$JOB_DENSITY" ]; then
        case "$JOB_DENSITY" in
            [1-5])
                flags="$flags -T$JOB_DENSITY"
                ;;
            *)
                echo "  ignoring DENSITY='$JOB_DENSITY' (want integer 1-5)" >> "$LOG"
                ;;
        esac
    fi

    # Optional toner-save / EconoMode, geometry-safe (-t sets a flag only).
    if [ -n "$JOB_ECONOMODE" ]; then
        case "$JOB_ECONOMODE" in
            1|on|ON|true|yes) flags="$flags -t" ;;
            0|off|OFF|false|no|"") ;;   # default off: emit nothing
            *) echo "  ignoring ECONOMODE='$JOB_ECONOMODE' (want on/off)" >> "$LOG" ;;
        esac
    fi

    # --- copies / duplex (F1) ---------------------------------------------
    # job_extra_flags emits -n (foo2zjs copies) and/or -d (duplex code), or
    # nothing when the job uses the plain defaults. Appended last so the
    # no-option path stays byte-identical to the base string above.
    extra=$(job_extra_flags)
    [ -n "$extra" ] && flags="$flags $extra"

    echo "$flags"
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
#   PAPER=legal    per-job paper size            (auto|letter|a4|legal|a5|...)
#   SCALE=90       per-job page scale (percent)  (gs rasterisation)
#   MARGIN=18      per-job blank inset (points)  (gs rasterisation)
#
# Each iteration first resets the per-job option vars to their config/default
# values so state never leaks between jobs, then — if a sidecar exists — reads
# a small allow-list of KEY=value lines to override them for this job only.
# Jobs with no .opts file are wholly unaffected (the reset alone runs). A single
# injection-safe loop (the sidecar is NOT sourced) handles every feature's keys:
# COPIES, DUPLEX, NUP (F1), DENSITY, ECONOMODE (F8), PRINTER (multi-printer),
# PAPER/SCALE/MARGIN (paper-sizes).
read_job_opts() {   # $1 = path to the job's .opts sidecar (may not exist)
    COPIES="$DEFAULT_COPIES"
    JOB_DENSITY="$DENSITY"        # config DENSITY is the per-job default...
    JOB_ECONOMODE="$ECONOMODE"    # ...and the sidecar may override it below.
    JOB_DUPLEX="$DEFAULT_DUPLEX"
    JOB_NUP="$DEFAULT_NUP"
    JOB_PRINTER=""                # per-job printer routing (multi-printer)
    JOB_PAPER="$PAPER"            # config PAPER is the per-job default...
    JOB_SCALE="$SCALE"            # ...and the sidecar may override each below.
    JOB_MARGIN="$MARGIN"

    local sidecar="$1" line key val
    if [ -f "$sidecar" ]; then
        # Parse only known keys, and only the trailing value on each KEY=value
        # line. We do NOT source the sidecar (avoid arbitrary code / clobbering
        # vars). One shared loop handles every feature's keys.
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *=*) ;; *) continue ;; esac   # no '=' -> skip
            key=${line%%=*}
            val=${line#*=}
            key=$(printf '%s' "$key" | tr -d '[:space:]')
            val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '"'"'"'')
            case "$key" in
                COPIES)    [ -n "$val" ] && COPIES="$val" ;;
                DENSITY)   JOB_DENSITY="$val" ;;
                ECONOMODE) JOB_ECONOMODE="$val" ;;
                DUPLEX)    [ -n "$val" ] && JOB_DUPLEX="$val" ;;
                NUP)       [ -n "$val" ] && JOB_NUP="$val" ;;
                PRINTER)   JOB_PRINTER="$val" ;;
                PAPER)     [ -n "$val" ] && JOB_PAPER="$val" ;;
                SCALE)     JOB_SCALE="$val" ;;
                MARGIN)    JOB_MARGIN="$val" ;;
                *) ;;   # unknown keys ignored so features coexist in one sidecar
            esac
        done < "$sidecar"
    fi

    # Validate / normalise the copies / duplex / N-up values.
    case "$COPIES" in ''|*[!0-9]*) COPIES=1 ;; esac
    [ "$COPIES" -ge 1 ] 2>/dev/null || COPIES=1
    case "$JOB_DUPLEX" in none|long|short) ;; *) JOB_DUPLEX=none ;; esac
    case "$JOB_NUP" in ''|*[!0-9]*) JOB_NUP=1 ;; esac
    [ "$JOB_NUP" -ge 1 ] 2>/dev/null || JOB_NUP=1

    # Paper size: unknown/empty falls back to auto (pdfinfo detect), which in
    # turn falls back to Letter — preserving the original behaviour exactly.
    case "$JOB_PAPER" in
        auto|letter|a4|legal|a5|executive|com10|dl) ;;
        *)
            [ -n "$JOB_PAPER" ] && \
                echo "  ignoring PAPER='$JOB_PAPER' (unknown size) -> auto" >> "$LOG"
            JOB_PAPER=auto ;;
    esac
    # SCALE: positive percent only; anything else is ignored (no scaling).
    case "$JOB_SCALE" in
        ''|auto) JOB_SCALE="" ;;
        *[!0-9]*) echo "  ignoring SCALE='$JOB_SCALE' (want positive integer percent)" >> "$LOG"
                  JOB_SCALE="" ;;
        0) echo "  ignoring SCALE=0 (want positive integer percent)" >> "$LOG"
           JOB_SCALE="" ;;
    esac
    # MARGIN: non-negative points only; anything else is ignored (no inset).
    case "$JOB_MARGIN" in
        ''|0) JOB_MARGIN="" ;;
        *[!0-9]*) echo "  ignoring MARGIN='$JOB_MARGIN' (want non-negative integer points)" >> "$LOG"
                  JOB_MARGIN="" ;;
    esac

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

    # Load any per-job overrides from the sidecar (falls back to config). One
    # parser reads all keys: COPIES/DUPLEX/NUP/DENSITY/ECONOMODE/PRINTER/PAPER/
    # SCALE/MARGIN.
    read_job_opts "$OPTS"

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

    # Paper size. An explicit PAPER (config or sidecar, not "auto") forces the
    # size + raster grid via paper_spec(); PAPER=auto (the default) keeps the
    # original pdfinfo auto-detect below, so the unconfigured path is unchanged.
    PCODE=""; GDIM=""
    if [ "$JOB_PAPER" != auto ]; then
        spec=$(paper_spec "$JOB_PAPER")
        if [ -n "$spec" ]; then
            # shellcheck disable=SC2086
            set -- $spec
            PCODE="$1";  GDIM=$(grid_for "$2" "$3")
            echo "  paper=$JOB_PAPER (explicit) -> p$PCODE gdim=$GDIM res=$RES" >> "$LOG"
        fi
        # A recognised name that somehow yields no spec falls through to auto.
    fi
    if [ -z "$PCODE" ]; then
        # Auto: detect page size (height in points): A4 = 842pt, Letter = 792pt.
        psize=""
        [ -n "$PDFINFO" ] && psize=$("$PDFINFO" "$PDF" 2>/dev/null | awk -F'x' '/Page size/{print $2+0}')
        if [ -n "$psize" ] && [ "${psize%.*}" -gt 820 ]; then
            PCODE=9;  GDIM=$(grid_for 4960 7016)    # A4       (foo2* paper table)
        else
            PCODE=1;  GDIM=$(grid_for 5100 6600)    # US Letter
        fi
        echo "  page height=${psize:-?}pt -> p$PCODE gdim=$GDIM res=$RES" >> "$LOG"
    fi

    # Both gs and the converter share -r/-g/-p; -dPDFFitPage scales into the
    # grid. foo2zjs takes -z (ZjStream compression); foo2xqx has no -z.
    # build_conv_flags() emits the exact flag string for this driver/geometry.
    CONV_FLAGS=$(build_conv_flags)

    # Optional scale/margin, applied ONLY in the Ghostscript rasterisation step
    # via a PostScript prologue injected with -c ... -f. When neither SCALE nor
    # MARGIN is set (the default) GS_XFORM stays empty and the gs command line
    # is byte-identical to the pre-feature invocation below.
    #
    # We fit the PDF into the fixed media grid first (-dPDFFitPage), then apply
    # the transform around the page centre so scaling shrinks/grows about the
    # middle and a margin insets uniformly. The page box is GDIM pixels at $RES
    # dpi; scale/translate operate in the device's default (72dpi) user space,
    # so convert the pixel grid to points: pt = px * 72 / rdpi. For the 1200x600
    # models the across resolution differs from down, so split rx/ry.
    GS_XFORM=""
    if [ -n "$JOB_SCALE" ] || [ -n "$JOB_MARGIN" ]; then
        rx=${RES%x*}; ry=${RES#*x}
        gw=${GDIM%x*}; gh=${GDIM#*x}
        # Page dimensions in PostScript points (1/72"): pt = px * 72 / dpi.
        pw=$(( gw * 72 / rx )); ph=$(( gh * 72 / ry ))
        sc="${JOB_SCALE:-100}"; mg="${JOB_MARGIN:-0}"
        # Compose the transform in the shell (awk, since bash is integer-only)
        # so the emitted PostScript is just a literal `translate` + `scale`
        # applied per page via BeginPage. Semantics, relative to the FitPage'd
        # full-media page (pw x ph pt):
        #   * MARGIN insets a uniform blank border of `mg` pt on all four sides,
        #     shrinking the drawable area to (pw-2mg) x (ph-2mg) and scaling the
        #     content down (uniformly, aspect-preserving) so it still fits.
        #   * SCALE then multiplies that by sc/100 about the (inset) page centre.
        # Net: fx = (sc/100) * min((pw-2mg)/pw, (ph-2mg)/ph); content re-centred
        # via translate = (page - page*fx)/2 per axis (equal to mg when sc=100).
        read -r sxf txf tyf <<EOF
$(awk -v pw="$pw" -v ph="$ph" -v sc="$sc" -v mg="$mg" 'BEGIN {
    mfx = (pw>0)?(pw-2*mg)/pw:1; mfy = (ph>0)?(ph-2*mg)/ph:1;
    mf = (mfx<mfy)?mfx:mfy; if (mf<0) mf=0;
    f = (sc/100.0)*mf;
    printf "%.5f %.3f %.3f\n", f, (pw-pw*f)/2.0, (ph-ph*f)/2.0 }')
EOF
        GS_XFORM=$(printf '<< /BeginPage { %s %s translate %s dup scale } >> setpagedevice' \
            "$txf" "$tyf" "$sxf")
        echo "  gs transform: scale=${JOB_SCALE:-100}% margin=${JOB_MARGIN:-0}pt -> factor=$sxf (page ${pw}x${ph}pt)" >> "$LOG"
    fi

    if [ -n "$GS_XFORM" ]; then
        "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
              -sDEVICE=pbmraw -r$RES -g$GDIM \
              -dFIXEDMEDIA -dPDFFitPage \
              -sOutputFile=- -c "$GS_XFORM" -f "$PDF" 2>>"$LOG" \
          | "$CONV" $CONV_FLAGS > "$TMP" 2>>"$LOG"
    else
    "$GS" -q -dBATCH -dSAFER -dQUIET -dNOPAUSE \
          -sDEVICE=pbmraw -r$RES -g$GDIM \
          -dFIXEDMEDIA -dPDFFitPage \
          -sOutputFile=- "$PDF" 2>>"$LOG" \
      | "$CONV" $CONV_FLAGS > "$TMP" 2>>"$LOG"
    fi

    sz=$(wc -c < "$TMP")
    echo "  raster $sz bytes" >> "$LOG"

    if [ "$sz" -ge 32 ]; then
        # foo2zjs encodes copies in-stream (-n above); foo2xqx does not, so for
        # XQX printers we realise copies by pushing the raster N times. For
        # foo2zjs the raster already carries the copy count, so push once.
        #
        # fwload's stdout (redirected to LOG) also includes the parsed bulk-IN
        # read-back: "status-line: " for any human-readable device text and
        # "status-kv: " for recognized PJL tokens (ONLINE, TONER, PAGECOUNT,
        # CODE=, DISPLAY=, ...). These lines are grep-parseable from watcher.log
        # by a status poller / menu-bar without printing (see `fwload --status`).
        pushes=1
        if [ "$DRIVER" = foo2xqx ] && [ "${COPIES:-1}" -gt 1 ]; then
            pushes="$COPIES"
            echo "  foo2xqx: copies=$COPIES via $pushes raster pushes" >> "$LOG"
        fi
        job_rc=0
        i=1
        while [ "$i" -le "$pushes" ]; do
            "$FWLOAD" "$TMP" "$VID" "$PID" >>"$LOG" 2>&1
            fw_rc=$?
            echo "  fwload exit $fw_rc (push $i/$pushes)" >> "$LOG"
            [ "$fw_rc" -ne 0 ] && job_rc="$fw_rc"
            i=$((i + 1))
        done
        if [ "$job_rc" -eq 0 ]; then
            notify success "Printed on $(printer_label)"
        else
            notify error "Print failed on $(printer_label) (push error)"
        fi
    else
        echo "  empty conversion, skipped" >> "$LOG"
        # Empty raster means gs or the converter produced nothing usable.
        notify error "Print failed on $(printer_label) (conversion produced no output)"
    fi
    rm -f "$TMP" "$PDF" "$OPTS"
done
