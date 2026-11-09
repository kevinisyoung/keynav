#!/usr/bin/env bash
# Builds build/KeyNav.app (and build/KeyNavFixture.app for live tests) from the current checkout.
#
#   scripts/build_app.sh                         # ad-hoc signature
#   SIGN_IDENTITY="Apple Development" scripts/build_app.sh
#
# Signing note: macOS ties the Accessibility grant to the code signature. Ad-hoc builds get a new
# identity on every rebuild, so access must be granted again after each one. A stable certificate
# (e.g. your Apple Development identity) keeps the grant across rebuilds. Neither is notarized.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.2.8}"
# The commit count, plus the 84 commits from before the source went public, so builds keep counting up for Sparkle.
BUILD_NUMBER="${BUILD_NUMBER:-$(( $(git rev-list --count HEAD 2>/dev/null || echo 1) + 84 ))}"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUNDLE_ID="${BUNDLE_ID:-local.keynav.KeyNav}"     # placeholder until the maintainer chooses one
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="${OUT:-build}"

swift build -c release --product KeyNav
swift build -c release --product KeyNavFixture
BIN_DIR="$(swift build -c release --show-bin-path)"

# Builds signed by KeyNav's own Developer ID are the ones sold at keynav.app: they have the trial and license, and
# Sparkle updates them from keynav.app's feed, installing only updates signed with this key, whose private half lives
# in the maintainer's login keychain (scripts/release.sh signs with it). Anyone else's build is free for their own
# use (LICENSE), with no trial and no updates from keynav.app, which would replace it with the store build.
STORE_PLIST=""
if [[ "$SIGN_IDENTITY" == *"(WX2BG839Q3)"* ]]; then
  STORE_PLIST="<key>KeyNavStoreBuild</key><true/>
    <key>SUFeedURL</key><string>https://keynav.app/appcast.xml</string>
    <key>SUPublicEDKey</key><string>tFagIhPFcJX80Hi77evoK2Fyvo5/kWRE6Y6Q29auKBc=</string>
    <key>SUEnableAutomaticChecks</key><true/>"
fi

make_bundle() {
  local name="$1" executable="$2" identifier="$3" icon="$4"
  local extra_plist="${6:-}"
  local app="$OUT/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN_DIR/$executable" "$app/Contents/MacOS/$executable"
  local icon_key=""
  if [[ -n "$icon" ]]; then
    local iconset
    iconset="$(mktemp -d)/AppIcon.iconset"
    # macOS's own Python, where Pillow is installed; Homebrew's may come first on PATH without it.
    "${PYTHON:-/usr/bin/python3}" scripts/assets/make_icon.py "$iconset"
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    icon_key="<key>CFBundleIconFile</key><string>AppIcon</string>"
  fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${executable}</string>
    ${icon_key}
    <key>CFBundleIdentifier</key><string>${identifier}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${name}</string>
    <key>CFBundleDisplayName</key><string>${name}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>KeyNavSourceCommit</key><string>${COMMIT}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Kevin Young.</string>
    ${extra_plist}
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  local identity="${5:-$SIGN_IDENTITY}"
  local hardening=()
  # Notarization requires the hardened runtime and a secure timestamp.
  if [[ "$identity" == "Developer ID"* ]]; then hardening=(--options runtime --timestamp); fi
  # Sparkle's framework goes inside, each of its helpers signed before the app, as its documentation asks.
  if [[ "$name" == "KeyNav" ]]; then
    mkdir -p "$app/Contents/Frameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$executable" 2>/dev/null || true
    local sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} "$sparkle/XPCServices/Installer.xpc"
    codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} "$sparkle/Autoupdate"
    codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} "$sparkle/Updater.app"
    codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} "$app/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --sign "$identity" ${hardening[@]+"${hardening[@]}"} --identifier "$identifier" "$app"
  codesign --verify --strict "$app"
  echo "Built $app"
}

make_bundle "KeyNav" "KeyNav" "$BUNDLE_ID" icon "" "$STORE_PLIST"
# The fixture needs no stable identity; signing it ad hoc saves a second keychain prompt.
make_bundle "KeyNavFixture" "KeyNavFixture" "local.keynav.Fixture" "" "-"
codesign -dv "$OUT/KeyNav.app" 2>&1 | grep -E "Identifier|Authority|Signature" || true
echo "KeyNav $VERSION ($BUILD_NUMBER, commit $COMMIT) signed with: $SIGN_IDENTITY"
