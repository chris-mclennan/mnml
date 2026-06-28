#!/usr/bin/env bash
#
# click — drive the real running mnml's mouse. Thin wrapper that compiles
# scripts/macclick.swift to a cached binary (under target/, rebuilt only when
# the source changes) and forwards args. See macclick.swift for commands.
#
# Coordinates are display POINTS (top-left origin), the same space shot.sh's
# window bounds and screencapture use. Pair with `scripts/shot.sh` to verify.
#
# Usage:  scripts/click.sh <move|click|rclick|dblclick|scroll> X Y [DELTA]
#
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/scripts/macclick.swift"
BIN="$REPO/target/macclick"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  mkdir -p "$REPO/target"
  swiftc -O "$SRC" -o "$BIN"
fi

exec "$BIN" "$@"
