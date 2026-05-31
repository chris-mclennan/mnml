#!/usr/bin/env bash
# Generate mnml's app icon — runs `gen_icon.swift` to produce the
# iconset, then `iconutil` to compile it to `AppIcon.icns`. Outputs
# `scripts/icon/AppIcon.icns`; the bundle build script
# (`scripts/build-app.sh`) copies it into `Contents/Resources/`.

set -euo pipefail
cd "$(dirname "$0")"

ICONSET="AppIcon.iconset"
OUT="AppIcon.icns"

rm -rf "$ICONSET" "$OUT"
swift gen_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ built $(pwd)/$OUT"
