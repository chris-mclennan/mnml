#!/usr/bin/env bash
#
# PreToolUse hook for Bash — when the command about to run is `git push`,
# ask Claude (via stdout to the hook framework) to invoke the
# `code-reviewer` agent on the staged + most-recent-commit diff before
# the push fires. The hook prints a marker the assistant sees and
# treats as "run the review before continuing."
#
# Why this shape: the actual review needs Claude's reasoning + the
# agent tool. A shell-only review (clippy, fmt) already runs in
# pre-commit hooks; this layer catches the things those can't —
# correctness bugs, missed callers, doc-comment drift, etc.
#
# Triggers only on a literal `git push` (any args / branch). Skips
# `git push --dry-run`, `git push --tags`, and anything that's
# obviously not a "ship this" push. The reviewer reads CLAUDE_TOOL_INPUT
# (PreToolUse contract) to get the command string.

set -eu

input_json="$(cat)"
cmd="$(printf '%s' "$input_json" | jq -r '.tool_input.command // empty')"

# Not a git push? Pass through silently.
case "$cmd" in
    *git\ push*) ;;
    *) exit 0 ;;
esac

# `git push --dry-run` — no review needed.
case "$cmd" in
    *--dry-run*) exit 0 ;;
esac

# `git push --tags` — pushing tag refs only, no commits to review.
# Tag-pushing IS a "ship this" action, but the review window was at
# the underlying commits' push, not the tag.
case "$cmd" in
    *--tags*) exit 0 ;;
esac

# Emit a marker the assistant treats as "stop and review before
# pushing." Returning a non-zero exit code blocks the tool call; the
# assistant sees the marker in stderr and decides what to do.
#
# Per the hook contract, stderr from a PreToolUse exit-2 hook is
# surfaced to the assistant.
cat >&2 <<'EOF'
PRE_PUSH_REVIEW_GATE: run the `code-reviewer` agent on the diff that's
about to be pushed before continuing. If review surfaces blockers, fix
them with a new commit (do not amend). If review is clean, re-run the
push — this hook only fires once per attempt.

To bypass for trivial pushes (docs, comments): preface your next
message with "skip-review" and re-issue the push.
EOF
exit 2
