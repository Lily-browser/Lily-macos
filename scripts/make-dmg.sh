#!/usr/bin/env bash
# Wraps build/Lily.app in a compressed drag-to-Applications disk image.
# Usage: scripts/make-dmg.sh [output.dmg]   (run `make app` first)
# Signs the image when CODESIGN_IDENTITY names a real certificate.
set -euo pipefail
# Never trust an inherited PATH: only the system tool directories (Xcode tools are shims in /usr/bin).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lily.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
OUT="${1:-$ROOT/build/Lily-$VERSION.dmg}"
IDENTITY="${CODESIGN_IDENTITY:--}"

[ -d "$APP" ] || { echo "$APP missing: run 'make app' first" >&2; exit 1; }

WORK="$(umask 077 && mktemp -d)"
MNT="/Volumes/Lily $VERSION" # Finder only saves the window layout for volumes mounted under /Volumes
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Lily.app"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/make-dmg-background.swift" "$WORK/background"
# tiffutil pairs the images by DPI (72 = 1x, 144 = 2x), which the renderer does not write itself.
sips -s dpiWidth 72 -s dpiHeight 72 "$WORK/background.png" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff"
# The disk's own icon is the app icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

VOL="Lily $VERSION"
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
[ ! -e "$MNT" ] || { echo "$MNT is already mounted: eject it first" >&2; exit 1; }
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
SetFile -a C "$MNT" 2>/dev/null || true # show the custom volume icon

# Window layout through Finder. Needs a GUI session: if it is unavailable (headless CI) the image
# is still built, just with Finder's default layout over the same background.
osascript >/dev/null <<OSA || echo "note: Finder layout skipped (no GUI session)" >&2
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to (POSIX file "$MNT/.background/background.tiff" as alias)
    set position of item "Lily.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "$MNT"

rm -f "$OUT"
hdiutil convert -quiet "$RW" -format ULFO -o "$OUT"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
fi
echo "Built $OUT"
