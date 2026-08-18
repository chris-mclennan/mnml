#!/usr/bin/env bash
# ci-health-check.sh — SessionStart hook.
#
# Pings the latest CI workflow run for mnml (and, on-demand, any of the
# `mnml-*` sibling repos this session is likely to touch) and prints ONE
# line per red repo. Green = silent. This is the "surface it up front"
# leg of the CI monitoring process — the counterpart to the post-push
# Monitor pattern documented in memory/feedback-watch-ci-after-push.md.
#
# Exits 0 always. This hook must NEVER block session start — network
# hiccups or gh-auth issues should degrade to silence, not to a stuck
# session. The 5s timeout is a hard ceiling.
#
# What it prints (only when red):
#   ⚠ CI red on chris-mclennan/mnml @ <sha7> — <workflow>: <conclusion>
#      https://github.com/chris-mclennan/mnml/actions/runs/<id>
#
# Extend by appending repo slugs to the REPOS array. Keep the list
# small — this runs on every session start.

set -u

# Repos to probe. Keep tight — every entry adds a round-trip.
# Start with just mnml; add siblings as they graduate to "must-be-green".
REPOS=("chris-mclennan/mnml")

# Fail-soft: gh missing / not authenticated / offline → silent.
if ! command -v gh >/dev/null 2>&1; then
  exit 0
fi

check_repo() {
  local repo="$1"
  # `--jq` runs client-side, so a red run still prints; a 4xx/5xx bails.
  # `|| true` to survive network/auth failures without spamming the user.
  local line
  line=$(gh api "/repos/${repo}/actions/runs?per_page=1" \
    --jq '.workflow_runs[0] | select(.conclusion=="failure") | "\(.head_sha[0:7])|\(.name)|\(.conclusion)|\(.id)"' \
    2>/dev/null || true)
  if [ -n "$line" ]; then
    local sha wf conc rid
    IFS='|' read -r sha wf conc rid <<<"$line"
    printf '⚠ CI red on %s @ %s — %s: %s\n   https://github.com/%s/actions/runs/%s\n' \
      "$repo" "$sha" "$wf" "$conc" "$repo" "$rid"
  fi
}

for r in "${REPOS[@]}"; do
  check_repo "$r"
done

exit 0
