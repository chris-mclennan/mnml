#!/usr/bin/env bash
# PostToolUse hook (matcher: "Bash"). After the agent runs a `cargo build`, bounce
# the user's running `mnml` so they see the change live.
#
# Robust by design: it doesn't trust any particular field shape in the hook
# payload — it (1) bails immediately unless the Bash command was a `cargo build`,
# (2) re-validates by running `cargo build --quiet` itself (a fast no-op when the
# tree is already built) so it ONLY restarts when the project actually builds, and
# (3) `./run.sh restart` is a harmless no-op if no instance is running.
#
# Requires `jq` to read the command from stdin; if `jq` is missing the gate fails
# closed (no auto-restart) and exits cleanly.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

case "$cmd" in
  *"cargo build"*) : ;;          # a build — proceed
  *) exit 0 ;;                    # anything else — do nothing, fast
esac

repo="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$repo" 2>/dev/null || exit 0

# Only restart if the project currently builds (cheap freshness check otherwise).
if cargo build --quiet >/dev/null 2>&1; then
  ./run.sh restart >/dev/null 2>&1 || true
fi
exit 0
