#!/bin/bash
# (NOT `#!/usr/bin/env bash` — `env bash` on macOS picks /opt/homebrew/bin/bash
# but the `${!var}` indirect expansion below works in either; what matters is
# that /bin/sh / zsh aren't substituted. Stay explicit.)
#
# Propagate the Apple Developer ID signing secrets from your local
# environment to every public mnml-* sibling repo so the prebuild CI
# (see scripts/sibling-prebuild.yml) can codesign macOS binaries.
#
# Usage:
#   export APPLE_DEVELOPER_ID_CERT_BASE64="$(base64 < ~/.config/mnml/developer-id.p12 | tr -d '\n')"
#   export APPLE_DEVELOPER_ID_CERT_PASSWORD="..."
#   export APPLE_TEAM_ID="..."
#   ./scripts/propagate-apple-secrets.sh
#
# Or, if you have a 1Password / Bitwarden CLI, source them inline:
#   APPLE_TEAM_ID="$(op read 'op://Personal/Apple Developer/team id')" \
#     APPLE_DEVELOPER_ID_CERT_BASE64="$(op read 'op://Personal/Developer ID/cert-base64')" \
#     APPLE_DEVELOPER_ID_CERT_PASSWORD="$(op read 'op://Personal/Developer ID/cert-password')" \
#     ./scripts/propagate-apple-secrets.sh
#
# Behavior:
#   - Reads the 3 APPLE_* secrets from the env (errors if any unset)
#   - Iterates SIBLING_REPOS below and calls `gh secret set` on each
#   - Skips a repo if the secret is already present AND the same age
#     (we can't compare values, but updated_at hints)
#   - Idempotent: re-running just re-sets to the current env values

set -euo pipefail

: "${APPLE_DEVELOPER_ID_CERT_BASE64:?missing — see usage at top of script}"
: "${APPLE_DEVELOPER_ID_CERT_PASSWORD:?missing}"
: "${APPLE_TEAM_ID:?missing}"

if ! command -v gh >/dev/null; then
  echo "gh CLI required — install via 'brew install gh'" >&2
  exit 2
fi

OWNER="chris-mclennan"

# Pull the catalog repo list out of family_catalog.rs at runtime so this
# script stays in sync without manual editing.
REPO_LIST=$(
  grep -E 'repo_url:' "$(dirname "$0")/../src/family_catalog.rs" |
    grep -oE "github\.com/${OWNER}/[a-z0-9-]+" |
    sort -u |
    sed "s|^github\.com/${OWNER}/||" |
    grep -v '^mnml$' |
    grep -v '^mixr-rs$'
)

echo "Will propagate Apple secrets to these repos:"
echo "$REPO_LIST" | sed 's/^/  - /'
echo
read -p "Proceed? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }

for repo in $REPO_LIST; do
  echo "[$repo]"
  for s in APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD APPLE_TEAM_ID; do
    val="${!s}"
    if gh secret set "$s" --body "$val" --repo "${OWNER}/$repo" 2>&1 | tail -1; then
      echo "  ✓ $s"
    else
      echo "  ✗ $s (set failed — repo missing, no access, or rate-limited)"
    fi
  done
done

echo
echo "Done. To verify on a single repo:"
echo "  gh secret list --repo ${OWNER}/mnml-aws-cloudwatch-logs"
