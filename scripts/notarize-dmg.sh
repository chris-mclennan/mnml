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

# Resolve the signing identity by SHA1 — robust to whatever name format
# the cert ended up with ("Developer ID Application: Chris McLennan
# (7RH5JMR8G3)" vs. "Developer ID Application: (7RH5JMR8G3)" etc.). We
# imported exactly one Developer ID Application cert into the temp
# keychain, so a single-match grep is safe.
IDENTITY_SHA=$(security find-identity -v -p codesigning "$KEYCHAIN" \
    | grep "Developer ID Application" \
    | head -1 \
    | awk '{print $2}')
if [ -z "$IDENTITY_SHA" ]; then
    echo "[notarize] error: no Developer ID Application identity found in temp keychain" >&2
    security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
    exit 1
fi

echo "[notarize] codesigning $(basename "$SIGNED_APP") with identity $IDENTITY_SHA"
codesign --force --options runtime --deep --timestamp \
    --keychain "$KEYCHAIN" \
    --sign "$IDENTITY_SHA" \
    "$SIGNED_APP"

# Repackage into a new DMG (atomic replace).
NEW_DMG="${DMG%.dmg}.signed.dmg"
DMG_STAGE=$(mktemp -d)
cp -R "$SIGNED_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
VOLNAME="$(basename "$SIGNED_APP" .app) $(basename "$DMG" .dmg | sed -E 's/.*-([0-9.]+).*/\1/')"
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$NEW_DMG" >/dev/null

echo "[notarize] submitting to Apple notary service (30 min timeout)"
# --wait blocks until verdict, but with NO default timeout — a hung
# Apple endpoint hangs the whole CI run. Bound it at 30 min: typical
# verdicts after the first one arrive in 5-15 min; first-time
# Developer ID submissions get deeper scrutiny and can take 30-60 min.
# 30 covers the common case; if Apple takes longer the script fails
# fast and the next run inherits the same submission queue position.
#
# --output-format json gets a structured response we can inspect on
# failure (status, message, submission id for follow-up via `dist
# notarytool log <id>`).
NOTARY_OUT="$RUNNER_TEMP/notary-out.json"
if ! xcrun notarytool submit "$NEW_DMG" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait \
        --timeout 30m \
        --output-format json > "$NOTARY_OUT" 2>&1; then
    echo "[notarize] notarytool submit FAILED — output below" >&2
    cat "$NOTARY_OUT" >&2
    exit 1
fi
cat "$NOTARY_OUT"
# Verify the verdict was "Accepted"; "Invalid" / "Rejected" / etc. mean signing
# passed but Apple's checks failed — still need to abort.
STATUS=$(jq -r '.status // empty' "$NOTARY_OUT" 2>/dev/null || echo "")
if [ "$STATUS" != "Accepted" ]; then
    echo "[notarize] notarytool returned status: $STATUS" >&2
    echo "[notarize] full output:" >&2
    cat "$NOTARY_OUT" >&2
    exit 1
fi

echo "[notarize] stapling ticket to DMG"
xcrun stapler staple "$NEW_DMG"

mv "$NEW_DMG" "$DMG"
echo "[notarize] ✓ signed + notarized: $DMG"
