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
CMD="$WS/.mnml/ipc/command"

# Wait for the IPC channel to appear. mnml normally creates it in well
# under 0.1s, but the FIRST exec of a freshly-built binary can stall a
# second or more on the macOS Gatekeeper / quarantine scan — so a fixed
# `sleep` is racy (it intermittently failed at 0.5s). Poll up to ~8s,
# bailing early if the process dies.
channel_up() { [ -p "$CMD" ] || [ -f "$CMD" ]; }
for _ in $(seq 1 160); do
  channel_up && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.05
done
if ! channel_up; then
  echo "IPC channel never appeared"
  kill "$PID" 2>/dev/null
  exit 1
fi

drive() { printf '%s\n' "$1" >> "$CMD"; sleep 0.25; }

# A fresh workspace always hits the first-launch welcome overlay; Esc
# dismisses it so the screen dump shows the actual editor, not chrome.
drive '{"cmd":"key","key":"esc"}'
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
# Poll for a clean exit — likewise don't trust a fixed sleep.
for _ in $(seq 1 60); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$PID" 2>/dev/null; then
  echo "did not quit on {\"cmd\":\"quit\"} — killing"
  kill "$PID" 2>/dev/null
  exit 1
fi
wait "$PID" 2>/dev/null || true
echo "== smoke OK =="
