#!/usr/bin/env bash
# Captures every Settings page of the built app as PNGs (light, dark, and minimum size).
# Only the KeyNav window is captured (screencapture -l). The calling terminal needs Screen Recording access.
#
#   scripts/capture_settings.sh [build/KeyNav.app] [docs/screenshots]
set -euo pipefail
APP="${1:-build/KeyNav.app}"
OUT="${2:-docs/screenshots}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT/request"
open -n "$APP" --args --snapshot-settings "$OUT"
seen=""
for _ in $(seq 1 1200); do
  if [[ -f "$OUT/request" ]]; then
    read -r window name < "$OUT/request" || true
    if [[ -n "${name:-}" && "$name" != "$seen" ]]; then
      screencapture -x -o -l"$window" "$OUT/$name.png"
      seen="$name"
      echo "captured $name"
    fi
  elif [[ -n "$seen" ]] && ! pgrep -f -- "--snapshot-settings" >/dev/null; then
    break
  fi
  sleep 0.1
done
