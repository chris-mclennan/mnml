#!/usr/bin/env bash
# zig-spec-conflict — dump the conflict-resolution spec: run mnml-zig
# headless on a throwaway repo left in a merge conflict, feed a steps
# file, keep the screen as docs/ui-spec/zig-<name>-<size>.txt.
#
#   tools/zig-spec-conflict.sh NAME [COLSxROWS] [OUT_DIR]
#
# NAME picks docs/ui-spec/steps-<NAME>.jsonl. The workspace is a repo
# whose `c.txt` conflicts in two blocks: `main` and `feature` each
# changed lines 2 and 9 of a ten-line file, `git merge feature` was
# left failing. The dump IS the spec (`app/conflicts.zig` is
# Zig-authored; there is no Rust screen to diff against). The shared
# fixture is never touched: everything lives under a mktemp directory.
set -u
NAME=$1; SIZE=${2:-120x40}; OUT_DIR=${3:-$(cd "$(dirname "$0")/.." && pwd)/docs/ui-spec}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
STEPS=$ROOT/docs/ui-spec/steps-$NAME.jsonl
[ -f "$STEPS" ] || { echo "no steps file: $STEPS" >&2; exit 64; }
[ -x "$ZIG" ] || { echo "build first: zig build" >&2; exit 64; }

TMP=$(mktemp -d)
WS=$TMP/ws; DATA=$TMP/data
mkdir -p "$WS" "$DATA"
g() { git -C "$WS" -c user.email=spec@mnml.dev -c user.name=spec -c commit.gpgsign=false "$@"; }
export GIT_AUTHOR_DATE="2026-09-06T20:00:00+0000" GIT_COMMITTER_DATE="2026-09-06T20:00:00+0000"
g init -q -b main
printf '.mnml/\n' >"$WS/.gitignore"
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >"$WS/c.txt"
g add .gitignore c.txt
g commit -q -m "init"
g checkout -q -b feature
printf 'one\ntwo-theirs\nthree\nfour\nfive\nsix\nseven\neight\nnine-theirs\nten\n' >"$WS/c.txt"
g commit -q -am "theirs"
g checkout -q main
printf 'one\ntwo-ours\nthree\nfour\nfive\nsix\nseven\neight\nnine-ours\nten\n' >"$WS/c.txt"
g commit -q -am "ours"
g merge -q feature >/dev/null 2>&1 || true
cat >"$DATA/config.zon" <<'ZON'
.{
    .editor = .{ .input_style = .standard },
    .ui = .{ .line_numbers = true, .first_launch_complete = true, .hover_tooltip = true },
    .ipc = .{ .write_screen = true },
}
ZON
IPC=$WS/.mnml/ipc-zig
# An empty sessions home: the start surface lists the workspace's
# Claude / Codex sessions from `~/.claude` / `~/.codex`, and the
# developer's own transcripts must never reach a dump.
mkdir -p "$TMP/sessions-home"
MNML_SESSIONS_HOME=$TMP/sessions-home MNML_DATA_ROOT=$DATA MNML_COLS=$COLS MNML_ROWS=$ROWS "$ZIG" --headless --input standard "$WS" >"$TMP/zig.log" 2>&1 &
pid=$!
for _ in $(seq 1 80); do grep -q '"start"' "$IPC/events.jsonl" 2>/dev/null && break; sleep 0.1; done
sleep 0.8
while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "$line" >>"$IPC/command"
  ms=$(printf '%s' "$line" | sed -n 's/.*"ms":\([0-9]*\).*/\1/p')
  sleep "0.4"; [ -n "$ms" ] && sleep "$(awk "BEGIN{print $ms/1000}")"
done <"$STEPS"
sleep 1.0
echo '{"cmd":"dump-rects"}' >>"$IPC/command"
sleep 0.4
OUT=$OUT_DIR/zig-$NAME-${COLS}x${ROWS}.txt
cp "$IPC/screen.txt" "$OUT" 2>/dev/null || { echo "(no screen.txt — see $TMP/zig.log)" >&2; exit 1; }
cp "$IPC/rects.json" "$TMP/rects.json" 2>/dev/null
echo '{"cmd":"quit"}' >>"$IPC/command"
for _ in $(seq 1 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "== $OUT   (rects: $TMP/rects.json, log: $TMP/zig.log)"
