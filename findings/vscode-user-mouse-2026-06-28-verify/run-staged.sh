#!/usr/bin/env bash
# Stage commands one at a time so the headless loop draws between
# them. The IPC drain processes batches synchronously, so back-to-
# back commands in ONE batch share the same rects snapshot. We
# write commands one per line with sleeps in between to force
# multiple drain cycles (= multiple draws).
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

export XDG_CONFIG_HOME="$FINDINGS/test-home/.config"
export COLUMNS="$COLS"
export LINES="$ROWS"
export MNML_COLS="$COLS"
export MNML_ROWS="$ROWS"

perl -e 'alarm 60; exec @ARGV' "$BIN" --headless --input standard "$WS" \
  > "$FINDINGS/results/$NAME/stdout.txt" 2> "$FINDINGS/results/$NAME/stderr.txt" &
MNML_PID=$!

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 0.2
  if [ -f "$IPC/events.jsonl" ] && grep -q '"start"' "$IPC/events.jsonl" 2>/dev/null; then
    break
  fi
done

# Feed each NON-EMPTY line one at a time with a draw cycle between
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" >> "$IPC/command"
  # Sleep long enough for the headless loop to drain + draw at least
  # once. POLL_SLEEP is 40ms; a single command processes in one drain
  # iteration. We give it 150ms to be safe (drain + draw + dump).
  sleep 0.15
done < "$CMDS"

wait $MNML_PID 2>/dev/null || true

# Copy outputs
cp "$IPC/screen.txt" "$FINDINGS/results/$NAME/screen.txt" 2>/dev/null || true
cp "$IPC/status.json" "$FINDINGS/results/$NAME/status.json" 2>/dev/null || true
cp "$IPC/rects.json" "$FINDINGS/results/$NAME/rects.json" 2>/dev/null || true
cp "$IPC/events.jsonl" "$FINDINGS/results/$NAME/events.jsonl" 2>/dev/null || true

echo "=== $NAME done ==="
