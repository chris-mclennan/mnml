#!/usr/bin/env bash
# Usage: ./run.sh <test-name> <workspace> <commands-file> [--input vim|standard]
set -euo pipefail
FINDINGS=/Users/chrismclennan/Projects/mnml/findings/nvchad-2nd-2026-06-28
BIN=/Users/chrismclennan/Projects/mnml/target/release/mnml
NAME="$1"
WS="$2"
CMDS="$3"
INPUT_FLAG="${4:---input}"
INPUT_KIND="${5:-vim}"
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

perl -e 'alarm 30; exec @ARGV' "$BIN" --headless $INPUT_FLAG $INPUT_KIND "$WS" \
  > "$FINDINGS/results/$NAME/stdout.txt" 2> "$FINDINGS/results/$NAME/stderr.txt" &
MNML_PID=$!

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 0.2
  if [ -f "$IPC/events.jsonl" ] && grep -q '"start"' "$IPC/events.jsonl" 2>/dev/null; then
    break
  fi
done

cat "$CMDS" >> "$IPC/command"

wait $MNML_PID 2>/dev/null || true

cp "$IPC/screen.txt" "$FINDINGS/results/$NAME/screen.txt" 2>/dev/null || true
cp "$IPC/status.json" "$FINDINGS/results/$NAME/status.json" 2>/dev/null || true
cp "$IPC/events.jsonl" "$FINDINGS/results/$NAME/events.jsonl" 2>/dev/null || true

echo "=== $NAME done ==="
