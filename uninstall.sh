#!/bin/bash
# hp-laserjet-mac-driver — uninstaller. Removes everything install.sh created.
set -u
HOME_DIR="$HOME"
PREFIX=/usr/local/share/foo2zjs

echo "==> Unloading launchd watcher…"
AGENT="$HOME_DIR/Library/LaunchAgents/com.hp-laserjet.watcher.plist"
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"

echo "==> Removing PDF Service…"
rm -rf "$HOME_DIR/Library/PDF Services/Print on HP LaserJet.workflow"
rm -rf "$HOME_DIR/Library/PDF Services/Print on HP LaserJet (two-sided).workflow"

echo "==> Removing installed binaries (sudo)…"
sudo rm -rf "$PREFIX"
# Remove the self-test symlink from whichever Homebrew bin holds it (if any).
for b in /opt/homebrew/bin /usr/local/bin; do
    [ -L "$b/hp-laserjet-doctor" ] && sudo rm -f "$b/hp-laserjet-doctor"
done

echo "==> Spool dir left at $HOME_DIR/HP-LaserJet-spool (delete manually if unwanted)."
echo "Done. (Homebrew ghostscript/libusb/poppler left installed.)"
