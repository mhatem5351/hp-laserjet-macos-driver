#!/bin/bash
# ============================================================================
#  p1102-mac-driver — installer
#  Print to a host-based HP LaserJet (P1005 / P1006 / P1505 / P1102 / P1566
#  family) on modern macOS (Apple Silicon or Intel), where Apple ships no
#  driver and CUPS can no longer drive these printers.
#
#  What it does:
#    1. checks/installs dependencies (Homebrew ghostscript, libusb, poppler)
#    2. builds foo2zjs + a tiny libusb firmware/data pusher (fwload)
#    3. downloads the firmware blobs for the family from the HPLIP plugin
#    4. installs a launchd watcher + a Print-dialog "PDF Service"
#
#  The watcher auto-detects which supported printer is attached (USB product
#  id) and picks the matching firmware + raster geometry at print time.
#
#  No personal data is embedded — user, home and printer serial are all
#  detected at install time on the machine where this runs.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX=/usr/local/share/foo2zjs
HOME_DIR="$HOME"
USER_NAME="$(id -un)"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "macOS only."

# --- 1. dependencies --------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew required. Install from https://brew.sh then re-run."
fi
BREW_PREFIX="$(brew --prefix)"

say "Checking dependencies (ghostscript, libusb, poppler)…"
for pkg in ghostscript libusb poppler; do
    if ! brew list --formula 2>/dev/null | grep -qx "$pkg"; then
        say "  installing $pkg…"
        brew install "$pkg"
    fi
done

command -v cc >/dev/null 2>&1 || die "No C compiler. Install Xcode Command Line Tools: xcode-select --install"

# --- 2. build foo2zjs + fwload ---------------------------------------------
say "Building foo2zjs…"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
tar xzf "$HERE/vendor/foo2zjs-src.tar.gz" -C "$BUILD"
SRC="$BUILD/foo2zjs-master"
( cd "$SRC" && make foo2zjs >/dev/null 2>&1 )
[ -x "$SRC/foo2zjs" ] || die "foo2zjs build failed."

say "Building fwload (libusb data pusher)…"
cc -O2 -Wall -I"$BREW_PREFIX/include" "$HERE/src/fwload.c" \
   -L"$BREW_PREFIX/lib" -lusb-1.0 -o "$BUILD/fwload" \
   || die "fwload build failed (is libusb installed?)."

# --- 3. firmware blobs (whole host-based family) ---------------------------
# Each supported model needs its own firmware blob, uploaded on every power-on.
# Map: installed name (.dl)  <-  filename inside the HPLIP plugin (.fw.gz)
#   PID 0x1317 P1005 | 0x1517 P1006 | 0x0d17 P1505 | 0x002a P1102 | 0x092a P1566
FW_MAP="
sihpP1005.dl hp_laserjet_p1005.fw.gz
sihpP1006.dl hp_laserjet_p1006.fw.gz
sihpP1505.dl hp_laserjet_p1505.fw.gz
sihpP1102.dl hp_laserjet_professional_p1102.fw.gz
sihpP1566.dl hp_laserjet_professional_p1566.fw.gz
"
FWSTAGE="$BUILD/firmware"
mkdir -p "$FWSTAGE"

say "Preparing firmware for the LaserJet host-based family…"
# Prefer any blobs already bundled in vendor/ (offline install / reproducible).
have_all=1
while read -r dl _; do
    [ -z "$dl" ] && continue
    if [ -f "$HERE/vendor/$dl" ]; then
        cp "$HERE/vendor/$dl" "$FWSTAGE/$dl"
    else
        have_all=0
    fi
done <<EOF
$FW_MAP
EOF

if [ "$have_all" -ne 1 ]; then
    warn "some firmware not bundled; downloading HPLIP plugin…"
    PLUGIN="$BUILD/plugin.run"
    curl -fsSL -o "$PLUGIN" \
      "https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.22.10-plugin.run" \
      || die "firmware download failed."
    off=$(python3 -c "d=open('$PLUGIN','rb').read();print(d.find(b'\x1f\x8b\x08'))")
    tail -c +$((off+1)) "$PLUGIN" > "$BUILD/plugin.tar.gz"
    while read -r dl fw; do
        [ -z "$dl" ] && continue
        [ -f "$FWSTAGE/$dl" ] && continue         # already bundled
        if tar xzf "$BUILD/plugin.tar.gz" -C "$BUILD" "./$fw" 2>/dev/null; then
            gunzip -f "$BUILD/$fw"
            cp "$BUILD/${fw%.gz}" "$FWSTAGE/$dl"
        else
            warn "  $fw not in plugin (skipping — that model won't be supported)"
        fi
    done <<EOF
$FW_MAP
EOF
fi

[ -n "$(ls -A "$FWSTAGE" 2>/dev/null)" ] || die "no firmware obtained."
say "  firmware ready: $(ls "$FWSTAGE" | tr '\n' ' ')"

# --- 4. install into /usr/local (survives reboot, outside SIP filter dir) ---
say "Installing into $PREFIX (sudo)…"
sudo mkdir -p "$PREFIX/firmware"
sudo cp "$SRC/foo2zjs"          "$PREFIX/foo2zjs"
sudo cp "$BUILD/fwload"         "$PREFIX/fwload"
sudo cp "$HERE/p1102-watcher.sh" "$PREFIX/p1102-watcher.sh"
sudo cp "$FWSTAGE"/*.dl          "$PREFIX/firmware/"
sudo chmod 755 "$PREFIX/foo2zjs" "$PREFIX/p1102-watcher.sh"
sudo chmod 644 "$PREFIX/firmware"/*.dl
# setuid root: the launchd watcher runs as the user but must claim the USB iface
sudo chown root:wheel "$PREFIX/fwload"
sudo chmod 4755 "$PREFIX/fwload"

# --- 5. spool + launchd agent ----------------------------------------------
say "Creating spool + launchd watcher…"
mkdir -p "$HOME_DIR/P1102-spool"

AGENT="$HOME_DIR/Library/LaunchAgents/com.p1102.watcher.plist"
mkdir -p "$HOME_DIR/Library/LaunchAgents"
sed -e "s#__HOME__#$HOME_DIR#g" -e "s#__PREFIX__#$PREFIX#g" \
    "$HERE/com.p1102.watcher.plist.in" > "$AGENT"
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

# --- 6. PDF Service (Print-dialog entry) -----------------------------------
say "Installing 'Print on P1102' PDF Service…"
PDFSVC="$HOME_DIR/Library/PDF Services/Print on P1102.workflow"
rm -rf "$PDFSVC"
mkdir -p "$PDFSVC/Contents"
cp "$HERE/PDFService/document.wflow" "$PDFSVC/Contents/document.wflow"
cp "$HERE/PDFService/Info.plist"     "$PDFSVC/Contents/Info.plist"

# --- done -------------------------------------------------------------------
cat <<EOF

$(say "Installed for user '$USER_NAME'.")

  Print from any app:  Cmd+P  ->  PDF ▾ (bottom-left)  ->  "Print on P1102"

  Notes:
    • The P1102 reloads firmware on every power-on; the watcher pushes it
      automatically before each job — nothing to do by hand.
    • First print after powering the printer on takes a few extra seconds
      while the firmware uploads.
    • Faint stripes / ghosting are the toner cartridge (CE285A / 85A),
      not this software.

  Uninstall:  ./uninstall.sh
EOF
