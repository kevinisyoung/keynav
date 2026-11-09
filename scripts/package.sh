#!/usr/bin/env bash
# Packages build/KeyNav.app into dist/ as a disk image whose window shows KeyNav, an arrow and Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/KeyNav.app/Contents/Info.plist)"
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print KeyNavSourceCommit' build/KeyNav.app/Contents/Info.plist)"
mkdir -p dist
DMG="dist/KeyNav-${VERSION}-${COMMIT}.dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/.background"
ditto build/KeyNav.app "$STAGE/KeyNav.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/assets/dmg/background.tiff "$STAGE/.background/"
cp scripts/assets/dmg/DS_Store "$STAGE/.DS_Store"
# The window layout names the volume and its items, so keep "KeyNav" and HFS+.
hdiutil create -quiet -srcfolder "$STAGE" -volname KeyNav -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
echo "$DMG"
