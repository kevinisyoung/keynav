#!/usr/bin/env bash
# Installs build/KeyNav.app into /Applications (or ~/Applications with --user).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="/Applications"
[[ "${1:-}" == "--user" ]] && DEST="$HOME/Applications" && mkdir -p "$DEST"
# A failed signing step can leave a broken bundle; never replace a working install with one.
codesign --verify --strict build/KeyNav.app
osascript -e 'tell application id "local.keynav.KeyNav" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/KeyNav.app"
ditto build/KeyNav.app "$DEST/KeyNav.app"
codesign --verify --strict "$DEST/KeyNav.app"
echo "Installed $DEST/KeyNav.app"
