#!/bin/bash
# sessions on a seeded fake home (tools/seed-sessions-home.sh) — slot 4, both sides, in place
set -u
ROOT=/private/tmp/walk; S=$ROOT/slot4; SIZE=${1:-120x40}; COLS=${SIZE%x*}; ROWS=${SIZE#*x}
OUT=$ROOT/out/sessions-seeded; [ "$SIZE" = 120x40 ] || OUT=$OUT-$SIZE; rm -rf "$OUT"; mkdir -p "$OUT"
H=$ROOT/home-seeded; rm -rf "$H"; mkdir -p "$H"
rsync -a --delete "$ROOT/pristine/ws/" "$S/ws/"; rsync -a --delete "$ROOT/pristine/rs-data/" "$S/rs-data/"; rsync -a --delete "$ROOT/pristine/zig-data/" "$S/zig-data/"
bash $HOME/Projects/mnml-zig/tools/seed-sessions-home.sh --waiting "$H" "$S/ws"
cp -R "$S/ws/.mnml/session.json" "$S/ws/.mnml/session.zon" "$ROOT/" 2>/dev/null
export HOME=$H PATH=$H/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin; unset ANTHROPIC_API_KEY GITHUB_TOKEN
python3 "$ROOT/walk-drive.py" --side rust --bin $HOME/Projects/mnml/target/release/mnml --ws "$S/ws" --data "$S/rs-data" --ipc "$S/ws/.mnml/ipc" --steps "$ROOT/steps/steps-sessions.jsonl" --out "$OUT" --cols $COLS --rows $ROWS --input standard
# restore the seeded session files Rust may have rewritten
cp "$ROOT/session.json" "$S/ws/.mnml/session.json"; cp "$ROOT/session.zon" "$S/ws/.mnml/session.zon"
python3 "$ROOT/walk-drive.py" --side zig --bin $HOME/Projects/mnml-zig/zig-out/bin/mnml-zig --ws "$S/ws" --data "$S/zig-data" --ipc "$S/ws/.mnml/ipc-zig" --steps "$ROOT/steps/steps-sessions.jsonl" --out "$OUT" --cols $COLS --rows $ROWS --input standard
bash $HOME/Projects/mnml-zig/tools/seed-sessions-home.sh stop "$H"
python3 "$ROOT/walk-report.py" "$OUT" $COLS $ROWS
