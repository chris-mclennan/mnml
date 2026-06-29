#!/usr/bin/env bash
# Helper: run mnml headless with given IPC commands and capture results.
# Usage: ./run.sh <test-name> <workspace> <commands-file>
set -euo pipefail
FINDINGS=/Users/chrismclennan/Projects/mnml/findings/vscode-user-mouse-2026-06-28-verify
BIN=/Users/chrismclennan/Projects/mnml/target/release/mnml
NAME="$1"
WS="$2"
CMDS="$3"
COLS="${COLS:-160}"
ROWS="${ROWS:-50}"

IPC="$WS/.mnml/ipc"
rm -rf "$IPC"
mkdir -p "$IPC"

mkdir -p "$FINDINGS/results/$NAME"

# Run headless with isolated config home + sized terminal
export XDG_CONFIG_HOME="$FINDINGS/test-home/.config"
export COLUMNS="$COLS"
export LINES="$ROWS"
export MNML_COLS="$COLS"
export MNML_ROWS="$ROWS"

# Start mnml in background, then write commands. The init() call
# truncates any pre-queued commands, so we must wait until mnml is
# running before writing.
perl -e 'alarm 30; exec @ARGV' "$BIN" --headless --input standard "$WS" \
  > "$FINDINGS/results/$NAME/stdout.txt" 2> "$FINDINGS/results/$NAME/stderr.txt" &
MNML_PID=$!

# Wait until mnml has initialized (events.jsonl has the start event)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 0.2
  if [ -f "$IPC/events.jsonl" ] && grep -q '"start"' "$IPC/events.jsonl" 2>/dev/null; then
    break
  fi
done

# Now feed commands
cat "$CMDS" >> "$IPC/command"

# Wait for mnml to quit (it will when it processes {"cmd":"quit"})
wait $MNML_PID 2>/dev/null || true

# Copy outputs
cp "$IPC/screen.txt" "$FINDINGS/results/$NAME/screen.txt" 2>/dev/null || true
cp "$IPC/status.json" "$FINDINGS/results/$NAME/status.json" 2>/dev/null || true
cp "$IPC/rects.json" "$FINDINGS/results/$NAME/rects.json" 2>/dev/null || true
cp "$IPC/events.jsonl" "$FINDINGS/results/$NAME/events.jsonl" 2>/dev/null || true

echo "=== $NAME done ==="
