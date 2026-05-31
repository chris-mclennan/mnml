#!/usr/bin/env bash
#
# Draft a release-announcement newsletter on Buttondown from a tagged
# release. Reads the matching version's section out of CHANGELOG.md,
# wraps it in a friendly preamble, creates a DRAFT email via the API.
# You review + send from buttondown.com — this script never actually
# fires the send. Editorial control stays with you.
#
# Usage:
#   ./scripts/send-release-newsletter.sh v0.1.2
#
# Requires:
#   BUTTONDOWN_API_KEY in env (already a GitHub secret on each repo;
#   set locally for one-off use:  export BUTTONDOWN_API_KEY=…).
#
# What it does:
#   1. Pulls the version's section from CHANGELOG.md.
#   2. POSTs a new email with status="draft" to Buttondown's API.
#   3. Prints the URL where you review + hit Send.

set -euo pipefail

cd "$(dirname "$0")/.."

# Each repo's send-release-newsletter.sh hard-codes its product name.
PRODUCT="mnml"
INSTALL_URL="https://${PRODUCT}.sh/install/"
CHANGELOG_URL="https://${PRODUCT}.sh/changelog/"
REPO_URL="https://github.com/chris-mclennan/${PRODUCT}"

TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "usage: $0 <tag>" >&2
    echo "  e.g. $0 v0.1.2" >&2
    exit 2
fi

if [ -z "${BUTTONDOWN_API_KEY:-}" ]; then
    echo "error: BUTTONDOWN_API_KEY not set in env" >&2
    echo "  set with: export BUTTONDOWN_API_KEY='your-key'" >&2
    echo "  or pull from a secret manager / 1Password / etc." >&2
    exit 1
fi

VERSION="${TAG#v}"

# Extract the changelog section for this version. Looks for a heading
# like `## [0.1.2]` (Keep a Changelog format) OR `### 0.1.2` (the format
# the site's changelog.mdx uses). Captures up to the next heading of
# the same level OR the file end. Portable across BSD awk (macOS) and
# GNU awk — uses string-concat regexes, not the 3-arg match().
extract_changelog() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk -v v="$VERSION" '
        BEGIN { capture = 0 }
        # Keep-a-Changelog: ## [0.1.2] - 2026-05-31
        $0 ~ "^## \\[" v "\\]" { capture = 1; print; next }
        # Site-style: ### 0.1.2 — 2026-05-31  (or with a trailing space/dash)
        $0 ~ "^### " v "[^0-9]" { capture = 1; print; next }
        # End of section: next same-level heading.
        capture && ($0 ~ "^## " || $0 ~ "^### ") { exit }
        capture { print }
    ' "$file"
}

EXTRACT=$(extract_changelog CHANGELOG.md)

# CHANGELOG.md at repo root might not exist or might not have an entry.
# Fall back to the site's changelog.mdx if so.
if [ -z "$EXTRACT" ]; then
    EXTRACT=$(extract_changelog site/src/content/docs/changelog.mdx)
fi

if [ -z "$EXTRACT" ]; then
    echo "error: no entry for version $VERSION found in CHANGELOG.md or site/src/content/docs/changelog.mdx" >&2
    echo "  add the entry first, then re-run." >&2
    exit 1
fi

SUBJECT="${PRODUCT} ${TAG} released"

# Newsletter body — Markdown. The `<!-- buttondown-editor-mode: markdown -->`
# prefix tells Buttondown to treat the body as Markdown source rather than
# trying to convert it to "Fancy" (rich-text) mode, which mangles headings
# + bullet lists. Without this, drafts surface a "Some content couldn't be
# converted to Fancy mode" warning + render markdown source literally.
BODY=$(/bin/cat <<EOF
<!-- buttondown-editor-mode: markdown -->
Hi,

${PRODUCT} ${TAG} is out.

${EXTRACT}

—

Install or upgrade: ${INSTALL_URL}
Full changelog: ${CHANGELOG_URL}
Source: ${REPO_URL}

Thanks for following along.
EOF
)

# POST to Buttondown's API. status="draft" means the email is created
# but NOT sent — you review at buttondown.com and hit Send manually.
RESPONSE=$(/usr/bin/curl -sS -X POST 'https://api.buttondown.email/v1/emails' \
    -H "Authorization: Token ${BUTTONDOWN_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
        --arg subject "$SUBJECT" \
        --arg body "$BODY" \
        '{subject: $subject, body: $body, status: "draft"}')")

EMAIL_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
if [ -z "$EMAIL_ID" ]; then
    echo "error: Buttondown API didn't return an email id" >&2
    echo "response: $RESPONSE" >&2
    exit 1
fi

echo "✓ draft created: $SUBJECT"
echo "  review + send at: https://buttondown.com/emails/${EMAIL_ID}"
echo
echo "  This script created a DRAFT only. Nothing has been sent."
echo "  Review the email at the URL above; hit Send when ready."
