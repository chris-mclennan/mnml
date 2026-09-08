#!/usr/bin/env bash
# seed-sessions-home.sh — the fake home behind `rust-sessions-*.txt`.
#
#   seed-sessions-home.sh HOME_DIR WS       seed and start
#   seed-sessions-home.sh stop HOME_DIR     end the fake processes
#
# Both editors list the Claude Code sessions of `$HOME/.claude/projects`
# (Rust: `src/claude_agents.rs`; Zig: `src/app/agents.zig`), so the
# spec is cut on a HOME of our own with three sessions of WS:
#
#   …0001  live   "fix the failing tests"   a process, transcript kept fresh
#   …0002  idle   "add a --json flag"       a process, transcript 2 h old,
#                                           renamed "release train"
#   …0003  ended  "write the release notes" no process, a day old,
#                                           pinned by the steps file
#
# `HOME_DIR/bin/claude` is a fake `claude`: on `--resume <sid>` it titles
# its window `✳ <the session's prompt>` (Claude Code titles its window
# with a summary of the conversation), prints a line, and stays up —
# except the ended session's, which exits at once. Rust spawns it for
# every entry of `claude_sessions` in `WS/.mnml/session.json` (the
# script adds the three); Zig reads the transcripts and pairs the two
# background copies this script starts (`ps` shows `claude … --resume
# <sid>`) with them. Run the harness with `HOME=HOME_DIR`,
# `PATH=HOME_DIR/bin:$PATH` and `--no-copy` (the transcripts name WS;
# Rust finds none under a private copy's path); `stop` when done.
set -eu
if [ "${1:-}" = stop ]; then
  H=$2
  [ -f "$H/pids" ] && while read -r p; do kill "$p" 2>/dev/null || true; done <"$H/pids"
  rm -f "$H/pids"
  # The copies Rust spawned outlive its headless run: end those too.
  pkill -f -- "--resume 5e551011-0000-4000-8000-00000000000" 2>/dev/null || true
  exit 0
fi
H=$1; WS=$2
ENC=$(printf '%s' "$WS" | tr / -)
P="$H/.claude/projects/$ENC"
mkdir -p "$P" "$H/bin" "$H/.fake-claude"
S1=5e551011-0000-4000-8000-000000000001
S2=5e551011-0000-4000-8000-000000000002
S3=5e551011-0000-4000-8000-000000000003
line() { # sid prompt reply
  printf '{"type":"user","cwd":"%s","gitBranch":"main","sessionId":"%s","message":{"role":"user","content":"%s"}}\n' "$WS" "$1" "$2"
  printf '{"type":"assistant","cwd":"%s","sessionId":"%s","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":900,"output_tokens":120},"content":[{"type":"text","text":"%s"}]}}\n' "$WS" "$1" "$3"
}
line $S1 "fix the failing tests in src/main.rs" "Running the suite first to see which ones fail." >"$P/$S1.jsonl"
line $S2 "add a --json flag to the CLI" "Added the flag and a test for it. Anything else?" >"$P/$S2.jsonl"
line $S3 "write the release notes for 0.3" "Drafted them in CHANGELOG.md." >"$P/$S3.jsonl"
touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$P/$S2.jsonl"
touch -t "$(date -v-1d +%Y%m%d%H%M.%S)" "$P/$S3.jsonl"
cat >"$H/.fake-claude/titles" <<EOF
$S1 fix the failing tests in src/main.rs
$S2 add a --json flag to the CLI
$S3 write the release notes for 0.3
EOF
cat >"$H/bin/claude" <<'EOF'
#!/bin/bash
# The fake `claude` of tools/seed-sessions-home.sh (see there).
sid=""
while [ $# -gt 0 ]; do case "$1" in --resume|--session-id) sid=$2; shift 2;; *) shift;; esac; done
title=$(grep "^$sid " "$HOME/.fake-claude/titles" | cut -d' ' -f2-)
printf '\033]0;\342\234\263 %s\007' "$title"
printf 'claude (fake) %s\n' "$sid"
case "$sid" in
  *0003) sleep 1; exit 0 ;;
  *0001) f=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl); exec -a claude /bin/sh -c 'while :; do touch "$0"; sleep 10; done' "$f" --resume "$sid" ;;
  *) exec -a claude /bin/sh -c 'while :; do sleep 1; done' --resume "$sid" ;;
esac
EOF
chmod +x "$H/bin/claude"
# Rust resumes every `claude_sessions` entry at startup (`src/app/session.rs`).
python3 - "$WS/.mnml/session.json" "$S1" "$S2" "$S3" <<'EOF'
import json, sys
p, s1, s2, s3 = sys.argv[1:]
d = json.load(open(p))
d["claude_sessions"] = [
    {"session_id": s1, "accent_color": "orange"},
    {"session_id": s2, "display_name": "release train", "accent_color": "blue"},
    {"session_id": s3, "accent_color": "green"},
]
json.dump(d, open(p, "w"), indent=2)
EOF
# Zig keeps the alias in the session file (`src/app/session.zig`).
Z="$WS/.mnml/session.zon"
grep -q sessions_aliases "$Z" || sed -i '' "s|^}|    .sessions_aliases = .{ .{ .id = \"$S2\", .name = \"release train\" } },\n}|" "$Z"
# The two processes Zig pairs with the live and the idle session.
: >"$H/pids"
for s in $S1 $S2; do
  HOME=$H nohup "$H/bin/claude" --resume "$s" >/dev/null 2>&1 &
  echo $! >>"$H/pids"
done
echo "seeded $H for $WS"
