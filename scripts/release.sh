#!/usr/bin/env bash
# Builds a notarized KeyNav: Developer ID signature, hardened runtime, Apple's notary service, stapled tickets,
# then dist/KeyNav.dmg and its SHA-256 for the site's Download button, and dist/appcast.xml, the update feed the
# app checks, signed with the Sparkle key in the login keychain.
#
# One-time setup, after joining the Apple Developer Program:
#   1. Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application.
#   2. xcrun notarytool store-credentials keynav-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com).
#   3. The update key: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account keynav, and its public half in
#      scripts/build_app.sh. Back it up (generate_keys --account keynav -x file); without it no update installs.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" VERSION=x.y.z scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity (security find-identity -v -p codesigning)}"
PROFILE="${NOTARY_PROFILE:-keynav-notary}"

scripts/test.sh
SIGN_IDENTITY="$DEVELOPER_ID" scripts/build_app.sh
# The app is notarized and stapled on its own first, so a copy dragged out of the disk image carries its ticket.
ditto -c -k --keepParent build/KeyNav.app build/KeyNav-notarize.zip
xcrun notarytool submit build/KeyNav-notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/KeyNav.app
spctl --assess --type execute --verbose build/KeyNav.app
rm build/KeyNav-notarize.zip
DMG="$(scripts/package.sh)"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
cp "$DMG" dist/KeyNav.dmg
(cd dist && shasum -a 256 KeyNav.dmg | tee KeyNav.dmg.sha256)

# The update feed: one item, the version just built, pointing at the download the site serves.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' build/KeyNav.app/Contents/Info.plist)"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/KeyNav.app/Contents/Info.plist)"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account keynav dist/KeyNav.dmg)"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>KeyNav</title>
    <item>
      <title>KeyNav ${SHORT}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://keynav.app/download/KeyNav.dmg" ${SIGNATURE} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "Wrote dist/appcast.xml for ${SHORT} (${BUILD})"
