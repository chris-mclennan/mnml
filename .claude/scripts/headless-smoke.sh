#!/usr/bin/env bash
# Headless smoke test: builds mnml, spins up `--headless` against a throwaway
# workspace, drives it through the file-IPC channel (open a file, type, undo),
# dumps the rendered screen + status, and quits cleanly. Prints what it saw so a
# human (or the agent) can eyeball it. Exit non-zero only on a hard failure
# (build error, binary didn't start, didn't quit).
#
# Usage: .claude/scripts/headless-smoke.sh [extra mnml flags…]
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

echo "== building =="
cargo build --quiet || { echo "build FAILED"; exit 1; }

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/src"
printf 'fn main() {\n    println!("hello from mnml");\n}\n' > "$WS/src/main.rs"
printf '# Demo workspace\n\nA second line.\n' > "$WS/README.md"
printf '[package]\nname = "demo"\n' > "$WS/Cargo.toml"

echo "== launching headless on $WS =="
MNML_COLS="${MNML_COLS:-100}" MNML_ROWS="${MNML_ROWS:-22}" ./target/debug/mnml --headless "$WS" "$@" &
PID=$!
sleep 0.5
CMD="$WS/.mnml/ipc/command"
[ -p "$CMD" ] || [ -f "$CMD" ] || { echo "IPC channel never appeared"; kill "$PID" 2>/dev/null; exit 1; }

drive() { printf '%s\n' "$1" >> "$CMD"; sleep 0.25; }

drive '{"cmd":"open","path":"src/main.rs"}'
drive '{"cmd":"key","key":"down"}'
drive '{"cmd":"key","key":"down"}'
drive '{"cmd":"key","key":"X"}'
drive '{"cmd":"key","key":"Y"}'
drive '{"cmd":"open","path":"README.md"}'

echo "== screen.txt =="
nl -ba "$WS/.mnml/ipc/screen.txt"
echo "== status.json =="
cat "$WS/.mnml/ipc/status.json"; echo
echo "== events.jsonl =="
cat "$WS/.mnml/ipc/events.jsonl"

drive '{"cmd":"quit"}'
sleep 0.3
if kill -0 "$PID" 2>/dev/null; then
  echo "did not quit on {\"cmd\":\"quit\"} — killing"
  kill "$PID" 2>/dev/null
  exit 1
fi
wait "$PID" 2>/dev/null || true
echo "== smoke OK =="
