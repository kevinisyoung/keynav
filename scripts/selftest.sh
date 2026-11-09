#!/usr/bin/env bash
# Live end-to-end self-test inside the real app, against the KeyNav Fixture window.
# Requires: Accessibility granted to the KeyNav.app being tested. Don't type or use the mouse for ~2 minutes.
# Input is synthetic (HID-level CGEvents through KeyNav's real event tap); it is not a hardware test.
#
#   scripts/selftest.sh [path/to/KeyNav.app] [output directory]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Applications/KeyNav.app}"
OUT="${2:-docs/evidence/selftest}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
FIXTURE="$(cd build && pwd)/KeyNavFixture.app"
pkill -x KeyNav || true
sleep 1
open -W -n "$APP" --args --self-test "$OUT" --fixture "$FIXTURE"
cat "$OUT/selftest.md"
