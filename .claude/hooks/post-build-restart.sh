#!/usr/bin/env bash
# PostToolUse hook (matcher: "Bash"). After a `cargo build` that actually
# rebuilds mnml, bounce the user's running instance so they see the change live.
#
# Robust by design:
#  (1) bails immediately unless the Bash command was a `cargo build`,
#  (2) builds mnml itself, then checks whether the mnml binary's mtime
#      actually changed — so a `cargo build` for a *different* crate (e.g. the
#      sibling tmnl repo) leaves mnml's binary untouched and does NOT bounce
#      the running instance,
#  (3) `./run.sh restart` is a harmless no-op if no instance is running.
#
# The matcher fires on any Bash command containing "cargo build", regardless of
# which repo it ran in — step (2) is what scopes the restart to real mnml
# builds. Requires `jq` to read the command from stdin; if `jq` is missing the
# gate fails closed (no auto-restart) and exits cleanly.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

case "$cmd" in
  *"cargo build"*) : ;;          # a build — proceed
  *) exit 0 ;;                    # anything else — do nothing, fast
esac

repo="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$repo" 2>/dev/null || exit 0

bin="target/debug/mnml"
before="$(stat -f %m "$bin" 2>/dev/null || echo 0)"

# Build mnml itself. A fast no-op when nothing changed; only relinks the
# binary when mnml's own sources changed since the last build.
if ! cargo build --quiet >/dev/null 2>&1; then
  exit 0
fi

after="$(stat -f %m "$bin" 2>/dev/null || echo 0)"

# Only bounce mnml when its binary actually changed — a build of some other
# crate (tmnl, fim-engine, …) leaves it untouched, so the running instance is
# left alone.
if [ "$after" != "0" ] && [ "$before" != "$after" ]; then
  ./run.sh restart >/dev/null 2>&1 || true
fi
exit 0
