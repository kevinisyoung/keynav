#!/usr/bin/env bash
# Deterministic tests: no permissions, no UI, safe for CI.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
