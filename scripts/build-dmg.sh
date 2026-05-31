#!/usr/bin/env bash
#
# Build mnml-<version>.dmg — a drag-to-install disk image containing
# mnml.app + a symlinked /Applications shortcut.
#
#   ./scripts/build-dmg.sh         # debug profile
#   ./scripts/build-dmg.sh release # release profile (what ships)
#
# Output: target/mnml-<version>.dmg.
#
# This is the consumer install path — DJs / Mac users who expect a
# .dmg, a single "drag this app into that folder" gesture, and a
# clickable icon afterwards. The `curl | sh` installer remains the
# CLI path; both ship in each release.

set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${1:-debug}"
APP="target/mnml.app"

# Always rebuild the bundle so the DMG ships the latest binary.
./scripts/build-app.sh "$PROFILE"

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
