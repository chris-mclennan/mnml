#!/usr/bin/env bash
#
# Build mnml-<version>.dmg — a drag-to-install disk image containing
# mnml.app + a symlinked /Applications shortcut.
#
#   ./scripts/build-dmg.sh                    # debug profile
#   ./scripts/build-dmg.sh release            # release profile (what ships)
#   ./scripts/build-dmg.sh --bin-path PATH    # skip cargo build, use this binary
#
# Output: target/mnml-<version>.dmg.
#
# This is the consumer install path — DJs / Mac users who expect a
# .dmg, a single "drag this app into that folder" gesture, and a
# clickable icon afterwards. The `curl | sh` installer remains the
# CLI path; both ship in each release.
#
# `--bin-path` is for CI — cargo-dist has already built the binary
# at a known path; we just package it. Forwarded to build-app.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="debug"
BIN_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        debug|release)
            PROFILE="$1"
            shift
            ;;
        --bin-path)
            BIN_PATH="$2"
            shift 2
            ;;
        *)
            echo "usage: $0 [debug|release] [--bin-path PATH]" >&2
            exit 2
            ;;
    esac
done

APP="target/mnml.app"

# Always (re)build the bundle so the DMG ships the latest binary.
if [ -n "$BIN_PATH" ]; then
    ./scripts/build-app.sh --bin-path "$BIN_PATH"
else
    ./scripts/build-app.sh "$PROFILE"
fi

VERSION="$(grep -m1 '^version' Cargo.toml | sed -E 's/version *= *"([^"]+)"/\1/')"
DMG="target/mnml-${VERSION}.dmg"
VOLNAME="mnml ${VERSION}"
STAGE="target/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# `/Applications` symlink — drag-target inside the mounted DMG so the
# user just drops the .app onto it.
ln -s /Applications "$STAGE/Applications"

# Build the DMG. `-format UDZO` is the standard read-only compressed
# format the Mac installer dialog renders nicely.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
xattr -d com.apple.quarantine "$DMG" 2>/dev/null || true

echo "built $DMG"
echo "mount: open $DMG"
