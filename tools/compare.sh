#!/usr/bin/env bash
# compare — the Rust and Zig editors on the same large file, one steps
# file, a snapshot after EVERY step: a navigation harness on top of
# tools/ui-diff.sh's mechanics (a private copy of the chrome fixture,
# both binaries headless, the file-IPC protocol).
#
#   tools/compare.sh NAME [COLSxROWS]
#
# NAME picks docs/ui-spec/steps-NAME.jsonl. Output lands in
# docs/research/compare/NAME[-COLSxROWS]/ (the size suffix only when it
# is not the 120x40 default):
#   step-NNN.rust.txt / step-NNN.zig.txt       screen after step NNN
#   step-NNN.<side>.status.json                status.json after it
#   diff.md      per step: rows differing beyond the rail, each side's
#                cursor line:col and mode (status.json), the top visible
#                line (read off the gutter), a first-guess class
#   timing.md    per side: start event / first frame after spawn, peak
#                RSS (`ps -o rss` every 50 ms), and per step the ms from
#                the command's append to its ack and to the next screen
#                dump (polled at 1 ms) — see tools/compare-drive.py
#   <side>.timing.json / <side>.log            the raw numbers, stderr
#
# The workspace is a private copy of the chrome fixture (FIXTURE=dir,
# else the main checkout's git-ignored .mnml/chrome-fixture — a fixture
# is shared state, not a worktree — else its older place,
# <repo>-worktrees/chrome-fixture beside the main checkout) with
# src/large.rs written into it by tools/gen-large-fixture.py, so a steps
# file opens `src/large.rs`. Both editors get a private data root and a
# private IPC dir: Rust's is <ws>/.mnml/ipc (fixed), the Zig one is
# MNML_IPC_DIR=<ws>/.mnml/ipc-zig. The two run one after the other so
# the timing is not of two editors sharing the cores.
#
# The Rust binary is ~/Projects/mnml/target/release/mnml when it exists,
# else target/debug/mnml; when neither does, `cargo build --release` is
# run in that repo (minutes). timing.md names the one used.
#
# Env: MNML_INPUT=vim|standard (default: standard when NAME contains
# `standard` or `mouse`, else vim), MNML_RUST_BIN / MNML_ZIG_BIN,
# FIXTURE, FIXTURE_LINES=N (the fixture's line count, default 6000; the
# output dir gains a `-Nl` suffix), KEEP=1 keeps the private copy. Every
# spawned binary is killed on exit.
set -u
[ $# -ge 1 ] || { echo "usage: compare.sh NAME [COLSxROWS]" >&2; exit 64; }
NAME=$1; SIZE=${2:-120x40}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STEPS=$ROOT/docs/ui-spec/steps-$NAME.jsonl
[ -f "$STEPS" ] || { echo "compare: no steps file: $STEPS" >&2; exit 64; }
if [ -z "${FIXTURE:-}" ]; then
  . "$ROOT/tools/wt-lib.sh"; MAIN=$(wt_main "$ROOT") || MAIN=$ROOT
  FIXTURE=$MAIN/.mnml/chrome-fixture
  if [ ! -d "$FIXTURE" ] && [ -d "$MAIN-worktrees/chrome-fixture" ]; then
    FIXTURE=$MAIN-worktrees/chrome-fixture
    echo "compare: the fixture is still at its older place $FIXTURE (its home is $MAIN/.mnml/chrome-fixture)" >&2
  fi
fi
[ -d "$FIXTURE/ws" ] && [ -d "$FIXTURE/rs-data" ] && [ -d "$FIXTURE/zig-data" ] || { echo "compare: FIXTURE needs ws/ rs-data/ zig-data/: $FIXTURE" >&2; exit 64; }
case ${MNML_INPUT:-} in
  vim|standard) INPUT=$MNML_INPUT ;;
  "") case $NAME in *standard*|*mouse*) INPUT=standard ;; *) INPUT=vim ;; esac ;;
  *) echo "compare: MNML_INPUT must be vim or standard" >&2; exit 64 ;;
esac

ZIG=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
[ -x "$ZIG" ] || { echo "compare: build first (zig build): $ZIG" >&2; exit 64; }
RUST_REPO=${MNML_RUST_REPO:-$HOME/Projects/mnml}
if [ -n "${MNML_RUST_BIN:-}" ]; then
  RUST=$MNML_RUST_BIN
elif [ -x "$RUST_REPO/target/release/mnml" ]; then
  RUST=$RUST_REPO/target/release/mnml
elif [ -x "$RUST_REPO/target/debug/mnml" ]; then
  RUST=$RUST_REPO/target/debug/mnml
else
  echo "== no Rust binary; cargo build --release in $RUST_REPO (minutes)"
  (cd "$RUST_REPO" && cargo build --release) || { echo "compare: cargo build failed" >&2; exit 70; }
  RUST=$RUST_REPO/target/release/mnml
fi
[ -x "$RUST" ] || { echo "compare: no Rust binary: $RUST" >&2; exit 64; }

LINES=${FIXTURE_LINES:-6000}
OUT=$ROOT/docs/research/compare/$NAME
[ "$SIZE" = 120x40 ] || OUT=$OUT-$SIZE
[ "$LINES" = 6000 ] || OUT=$OUT-${LINES}l
rm -rf "$OUT"; mkdir -p "$OUT"

real() { (cd "$1" && pwd -P); }
abs()  { (cd "$1" && pwd); }
COPY_DIR=$(real "$(mktemp -d)")
DRIVER_PID=
cleanup() {
  [ -z "$DRIVER_PID" ] || kill "$DRIVER_PID" 2>/dev/null
  # Anything still running on the private copy (the driver kills its own
  # child; this is the belt for a driver that was itself killed).
  pkill -f -- "--headless --input $INPUT $COPY_DIR" 2>/dev/null
  if [ "${KEEP:-0}" = 1 ]; then echo "== kept private copy: $COPY_DIR"; else rm -rf "$COPY_DIR"; fi
}
trap cleanup EXIT INT TERM

# The private copy, as tools/ui-diff.sh makes it: ws / rs-data / zig-data
# copied, every absolute path inside that names a source directory
# rewritten to the copy's realpath, stale IPC output dropped.
SRC_WS=$(real "$FIXTURE/ws"); SRC_RS=$(real "$FIXTURE/rs-data"); SRC_ZG=$(real "$FIXTURE/zig-data")
ALT_WS=$(abs "$FIXTURE/ws");  ALT_RS=$(abs "$FIXTURE/rs-data");  ALT_ZG=$(abs "$FIXTURE/zig-data")
cp -R "$SRC_WS" "$COPY_DIR/ws"; cp -R "$SRC_RS" "$COPY_DIR/rs-data"; cp -R "$SRC_ZG" "$COPY_DIR/zig-data"
WS=$COPY_DIR/ws; RS=$COPY_DIR/rs-data; ZG=$COPY_DIR/zig-data
rm -rf "$WS/.mnml/ipc" "$WS/.mnml/ipc-zig"
repoint() {
  local from=$1 to=$2 f
  [ "$from" != "$to" ] || return 0
  grep -rIlF -- "$from" "$COPY_DIR" 2>/dev/null | while IFS= read -r f; do
    sed "s|$from|$to|g" "$f" >"$f.compare~" && cat "$f.compare~" >"$f"; rm -f "$f.compare~"
  done
}
printf '%s\t%s\n' "$SRC_WS" "$WS" "$ALT_WS" "$WS" "$SRC_RS" "$RS" "$ALT_RS" "$RS" "$SRC_ZG" "$ZG" "$ALT_ZG" "$ZG" \
  | awk -F'\t' '{ print length($1) "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr | cut -f2- \
  | while IFS=$(printf '\t') read -r from to; do repoint "$from" "$to"; done
for p in "$SRC_WS" "$ALT_WS" "$SRC_RS" "$ALT_RS" "$SRC_ZG" "$ALT_ZG"; do
  case $p in "$COPY_DIR"/*) continue ;; esac
  left=$(grep -rIlF -- "$p" "$COPY_DIR" 2>/dev/null)
  [ -z "$left" ] || { echo "compare: source path $p still named in:" >&2; echo "$left" | sed 's/^/  /' >&2; exit 70; }
done
mkdir -p "$WS/src"
python3 "$ROOT/tools/gen-large-fixture.py" "$WS/src/large.rs" --lines "$LINES" >"$OUT/fixture.txt" || exit 70
echo "== private copy: $COPY_DIR   fixture: $(cat "$OUT/fixture.txt" | sed 's|^[^:]*/||')"
echo "== rust: $RUST"
echo "== zig:  $ZIG"
echo "== steps: $STEPS   size: ${COLS}x${ROWS}   input: $INPUT"

run_side() { # side bin data ipcdir
  python3 "$ROOT/tools/compare-drive.py" run --side "$1" --bin "$2" --ws "$WS" --data "$3" --ipc "$4" \
    --steps "$STEPS" --out "$OUT" --cols "$COLS" --rows "$ROWS" --input "$INPUT" &
  DRIVER_PID=$!
  wait "$DRIVER_PID"; local rc=$?
  DRIVER_PID=
  return $rc
}
run_side rust "$RUST" "$RS" "$WS/.mnml/ipc"     || echo "compare: rust driver exited $?" >&2
run_side zig  "$ZIG"  "$ZG" "$WS/.mnml/ipc-zig" || echo "compare: zig driver exited $?" >&2
python3 "$ROOT/tools/compare-drive.py" report --out "$OUT" --steps "$STEPS" --cols "$COLS" --rows "$ROWS"
