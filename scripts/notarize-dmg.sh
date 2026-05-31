#!/usr/bin/env bash
#
# Code-sign + notarize a macOS .app inside a DMG, then staple the
# notarization ticket so Gatekeeper trusts it offline.
#
# Required env vars (set as GitHub secrets, see docs/notarization.md):
#   APPLE_TEAM_ID                       — 10-char alphanumeric team ID
#   APPLE_DEVELOPER_ID_CERT_BASE64      — base64-encoded .p12 export
#   APPLE_DEVELOPER_ID_CERT_PASSWORD    — password protecting the .p12
#   APPLE_ID                            — your Apple ID email
#   APPLE_APP_PASSWORD                  — app-specific password (NOT
#                                          your Apple ID password — generate
#                                          at appleid.apple.com → Sign-In and
#                                          Security → App-Specific Passwords)
#
# Usage:
#   ./scripts/notarize-dmg.sh target/distrib/mnml-rs-aarch64-apple-darwin.dmg
#   ./scripts/notarize-dmg.sh path/to/some.dmg
#
# Behavior:
#   - If APPLE_DEVELOPER_ID_CERT_BASE64 is unset, exits 0 cleanly (no-op).
#     This makes the release pipeline safe to run before the secrets are
#     configured — DMGs ship unsigned but the build doesn't break.
#   - Otherwise: import cert into a temp keychain, sign the .app inside
#     the DMG, repackage, submit to Apple's notary service, staple ticket.

set -euo pipefail

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
    echo "usage: $0 <dmg-path>" >&2
    exit 2
fi

if [ -z "${APPLE_DEVELOPER_ID_CERT_BASE64:-}" ]; then
    echo "[notarize] APPLE_DEVELOPER_ID_CERT_BASE64 not set — skipping (DMG ships unsigned)"
    exit 0
fi

: "${APPLE_TEAM_ID:?required}"
: "${APPLE_DEVELOPER_ID_CERT_PASSWORD:?required}"
: "${APPLE_ID:?required}"
: "${APPLE_APP_PASSWORD:?required}"

# Set up a throwaway keychain so the cert import doesn't pollute the
# default login keychain on the runner.
KEYCHAIN="$RUNNER_TEMP/notary.keychain-db"
KEYCHAIN_PASS="$(openssl rand -base64 16)"
CERT_PATH="$RUNNER_TEMP/developer-id.p12"

cleanup() {
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -f "$CERT_PATH"
}
trap cleanup EXIT

echo "[notarize] importing Developer ID cert into temp keychain"
echo "$APPLE_DEVELOPER_ID_CERT_BASE64" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security import "$CERT_PATH" \
    -k "$KEYCHAIN" \
    -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

# Mount the DMG, sign the .app inside, then re-create the DMG with the
# signed contents (DMGs are read-only after creation — can't sign in-place).
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT_DIR" -nobrowse -readonly >/dev/null
APP_PATH=$(find "$MOUNT_DIR" -maxdepth 2 -name '*.app' | head -1)
if [ -z "$APP_PATH" ]; then
    echo "[notarize] error: no .app found inside $DMG" >&2
    hdiutil detach "$MOUNT_DIR" >/dev/null || true
    exit 1
fi

WORK_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$WORK_DIR/"
hdiutil detach "$MOUNT_DIR" >/dev/null

SIGNED_APP="$WORK_DIR/$(basename "$APP_PATH")"
echo "[notarize] codesigning $(basename "$SIGNED_APP") with team $APPLE_TEAM_ID"
codesign --force --options runtime --deep --timestamp \
    --sign "Developer ID Application: ($APPLE_TEAM_ID)" \
    "$SIGNED_APP"

# Repackage into a new DMG (atomic replace).
NEW_DMG="${DMG%.dmg}.signed.dmg"
DMG_STAGE=$(mktemp -d)
cp -R "$SIGNED_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
VOLNAME="$(basename "$SIGNED_APP" .app) $(basename "$DMG" .dmg | sed -E 's/.*-([0-9.]+).*/\1/')"
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$NEW_DMG" >/dev/null

echo "[notarize] submitting to Apple notary service (this may take 1-5 min)"
xcrun notarytool submit "$NEW_DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

echo "[notarize] stapling ticket to DMG"
xcrun stapler staple "$NEW_DMG"

mv "$NEW_DMG" "$DMG"
echo "[notarize] ✓ signed + notarized: $DMG"
