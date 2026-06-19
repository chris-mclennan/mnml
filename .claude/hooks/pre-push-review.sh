#!/usr/bin/env bash
#
# PreToolUse hook for Bash — fires on `git push` to remind the
# assistant to run the `code-reviewer` agent before pushing.
#
# State model: the hook fires ONCE per unique HEAD SHA. On first
# fire it writes a marker at `.claude/state/reviewed-<sha>`, then
# exits 2 with the review-gate marker on stderr. The assistant
# runs the reviewer, addresses any findings (which produces a
# new commit + new SHA + new gate fire), or pushes the same SHA
# (which finds the marker and passes through).
#
# This eliminates the "skip-review" friction without losing the
# review prompt: every distinct commit set gets reviewed exactly
# once. A push that follows a clean review just passes through.
#
# Skips silently for `--dry-run` and `--tags` (no commits to
# review there).

set -eu

input_json="$(cat)"
cmd="$(printf '%s' "$input_json" | jq -r '.tool_input.command // empty')"

# Not a git push? Pass through silently. The matcher recognises
# `git push` as the LEADING command OR following a shell chain
# operator (`&&` / `;` / `|`) — explicitly excluding `git push`
# appearing inside a quoted argument (e.g. a commit-message body
# that happens to contain those two words). A naive `*git\ push*`
# false-matched on commit messages with those words verbatim.
case "$cmd" in
    "git push"*|*"&& git push"*|*"; git push"*|*"| git push"*) ;;
    *) exit 0 ;;
esac

# `git push --dry-run` — no review needed.
case "$cmd" in
    *--dry-run*) exit 0 ;;
esac

# `git push --tags` — pushing tag refs only, no commits to review.
case "$cmd" in
    *--tags*) exit 0 ;;
esac

# Only gate pushes from the mnml repo. Pushing other projects from
# this shell (a workspace folder, a sibling sibling-app repo, etc.)
# shouldn't trigger an mnml-code reviewer. Detect by checking the
# git toplevel against $CLAUDE_PROJECT_DIR.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -n "$toplevel" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && \
   [ "$toplevel" != "${CLAUDE_PROJECT_DIR}" ]; then
    exit 0
fi

# Resolve project state directory + current HEAD SHA. When git
# can't determine HEAD (corrupted .git, empty repo, etc.) we gate
# unconditionally — the safer failure mode for a review prompt
# than silently passing through with a wildcard marker that any
# subsequent push would also hit. Code-reviewer flagged the prior
# `unknown` fallback as a low-severity bypass path.
state_dir="${CLAUDE_PROJECT_DIR:-${PWD}}/.claude/state"
head_sha="$(git -C "${CLAUDE_PROJECT_DIR:-${PWD}}" rev-parse HEAD 2>/dev/null || echo "")"
if [ -z "$head_sha" ]; then
    cat >&2 <<'EOF'
PRE_PUSH_REVIEW_GATE: cannot determine HEAD SHA (broken git state?).
Gate is held closed until the repo state can be resolved. Fix the
underlying issue and retry.
EOF
    exit 2
fi
marker="${state_dir}/reviewed-${head_sha}"

# Already reviewed this exact commit set? Pass through. This is
# the "user re-running the push after a clean review" path —
# nothing has changed, the review's already been done.
if [ -f "$marker" ]; then
    exit 0
fi

# First gate fire for this HEAD. Drop the marker so the NEXT
# attempt (after the reviewer has done its thing) passes through
# automatically. Touch is atomic enough — worst case a concurrent
# push races but the result is identical.
mkdir -p "$state_dir"
touch "$marker"

# Garbage-collect old markers (>7 days old) so this dir doesn't
# grow forever. Best-effort.
find "$state_dir" -name "reviewed-*" -type f -mtime +7 -delete 2>/dev/null || true

cat >&2 <<EOF
PRE_PUSH_REVIEW_GATE: run the \`code-reviewer\` agent on the diff
that's about to be pushed before continuing. If review surfaces
blockers, fix them with a new commit (do not amend). If review is
clean, re-run the push — the gate only fires once per HEAD SHA.

(Reviewed-HEAD marker: ${marker})
EOF
exit 2
