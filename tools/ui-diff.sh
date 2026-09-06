#!/usr/bin/env bash
# ui-diff — run the Rust and Zig binaries headless on one workspace with
# the same config, dump both screens, print a row-by-row diff.
#   ui-diff.sh WS RS_DATA ZIG_DATA [STEPS_FILE] [COLSxROWS]
# STEPS_FILE: optional JSONL of IPC commands sent to BOTH after start.
set -u
WS=$1; RS=$2; ZG=$3; STEPS=${4:-}; SIZE=${5:-120x40}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
RUST=${MNML_RUST_BIN:-/Users/chrismclennan/Projects/mnml/target/debug/mnml}
ZIG=${MNML_ZIG_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/mnml-zig}
OUT=${OUT:-$(mktemp -d)}; mkdir -p "$OUT"
# Both editors persist the session (open files, cursors) under
# `$WS/.mnml/`; a STEPS file that opens a file would otherwise be
# restored by the next run and change its screen. Snapshot before,
# restore after.
SESSION_BAK=$(mktemp -d)
save_session() { rm -rf "$SESSION_BAK"/*; for f in "$WS"/.mnml/session*; do [ -e "$f" ] && cp -R "$f" "$SESSION_BAK/"; done; return 0; }
restore_session() { rm -rf "$WS"/.mnml/session*; cp -R "$SESSION_BAK"/. "$WS/.mnml/" 2>/dev/null; return 0; }
run_one() { # name bin data ipcdir
  local name=$1 bin=$2 data=$3 ipc="$WS/.mnml/$4"
  rm -rf "$ipc"
  save_session
  MNML_DATA_ROOT=$data MNML_COLS=$COLS MNML_ROWS=$ROWS "$bin" --headless --input standard "$WS" >"$OUT/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 80); do grep -q '"start"' "$ipc/events.jsonl" 2>/dev/null && break; sleep 0.1; done
  sleep 0.8
  if [ -n "$STEPS" ]; then while IFS= read -r line; do [ -n "$line" ] && echo "$line" >>"$ipc/command"; sleep 0.4; done <"$STEPS"; sleep 0.8; fi
  cp "$ipc/screen.txt" "$OUT/$name.txt" 2>/dev/null || echo "(no screen.txt)" >"$OUT/$name.txt"
  echo '{"cmd":"quit"}' >>"$ipc/command"
  for _ in $(seq 1 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  restore_session
}
run_one rust "$RUST" "$RS" ipc
run_one zig  "$ZIG"  "$ZG" ipc-zig
echo "== rust: $OUT/rust.txt   zig: $OUT/zig.txt"
diff --label rust --label zig "$OUT/rust.txt" "$OUT/zig.txt" >"$OUT/screen.diff"
n=$(grep -c '^[<>]' "$OUT/screen.diff"); echo "== differing lines: $n  ($OUT/screen.diff)"
