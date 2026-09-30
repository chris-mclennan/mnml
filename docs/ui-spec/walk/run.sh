#!/bin/bash
# run.sh SLOT NAME [COLSxROWS] [vim|standard] [extra-args]
# Runs docs/ui-spec/walk/steps-NAME.jsonl (or /private/tmp/walk/steps/steps-NAME.jsonl)
# through both binaries on slot SLOT, output to /private/tmp/walk/out/NAME[-SIZE][-INPUT]/
set -u
ROOT=/private/tmp/walk
SLOT=$1; NAME=$2; SIZE=${3:-120x40}; INPUT=${4:-standard}; EXTRA=${5:-}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
STEPS=$ROOT/steps/steps-$NAME.jsonl
[ -f "$STEPS" ] || { echo "no steps: $STEPS"; exit 64; }
OUT=$ROOT/out/$NAME; [ "$SIZE" = 120x40 ] || OUT=$OUT-$SIZE; [ "$INPUT" = standard ] || OUT=$OUT-$INPUT; [ "${FRESH:-0}" = 1 ] && OUT=$OUT-fresh
rm -rf "$OUT"; mkdir -p "$OUT"
RUST=${MNML_RUST_BIN:-$HOME/Projects/mnml/target/release/mnml}
ZIG=${MNML_ZIG_BIN:-$HOME/Projects/mnml-zig/zig-out/bin/mnml-zig}
S=$ROOT/slot$SLOT
export HOME=$ROOT/home
export PATH=$ROOT/home/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
unset ANTHROPIC_API_KEY GITHUB_TOKEN
reset_slot() {
  rsync -a --delete "$ROOT/pristine/ws/" "$S/ws/"
  rsync -a --delete "$ROOT/pristine/rs-data/" "$S/rs-data/"
  rsync -a --delete "$ROOT/pristine/zig-data/" "$S/zig-data/"
  if [ "${FRESH:-0}" = 1 ]; then rm -rf "$S/rs-data" "$S/zig-data"; mkdir -p "$S/rs-data" "$S/zig-data"; fi
}
reset_slot
python3 "$ROOT/walk-drive.py" --side rust --bin "$RUST" --ws "$S/ws" --data "$S/rs-data" --ipc "$S/ws/.mnml/ipc" \
  --steps "$STEPS" --out "$OUT" --cols "$COLS" --rows "$ROWS" --input "$INPUT" --args "$EXTRA"
reset_slot
python3 "$ROOT/walk-drive.py" --side zig --bin "$ZIG" --ws "$S/ws" --data "$S/zig-data" --ipc "$S/ws/.mnml/ipc-zig" \
  --steps "$STEPS" --out "$OUT" --cols "$COLS" --rows "$ROWS" --input "$INPUT" --args "$EXTRA"
python3 "$ROOT/walk-report.py" "$OUT" "$COLS" "$ROWS"
