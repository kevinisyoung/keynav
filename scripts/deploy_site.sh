#!/usr/bin/env bash
# Deploys the website, with the latest notarized download, to keynav.app on Cloudflare Workers.
#
# One-time: `npx wrangler@4 login`, wrangler.jsonc names the Worker and its domains.
# Run after scripts/release.sh, which writes dist/KeyNav.dmg.
#
#   scripts/deploy_site.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f dist/KeyNav.dmg && -f dist/appcast.xml ]] || { echo "No dist/KeyNav.dmg or dist/appcast.xml; run scripts/release.sh first." >&2; exit 1; }
OUT="build/site"
rm -rf "$OUT"
mkdir -p "$OUT/download"
cp -R site/. "$OUT/"
rm -rf "$OUT/parked"
cp dist/KeyNav.dmg dist/KeyNav.dmg.sha256 "$OUT/download/"
# The update feed the app checks.
cp dist/appcast.xml "$OUT/appcast.xml"
# Older links to the zip still download.
echo "/download/KeyNav.zip /download/KeyNav.dmg 301" > "$OUT/_redirects"
npx --yes wrangler@4 deploy
