#!/usr/bin/env bash
# zig-spec-git — dump the branches panel's UI spec: run mnml-zig headless
# on a throwaway repo seeded with every kind of row the panel lists, feed
# a steps file, keep the screen as docs/ui-spec/zig-<name>-<size>.txt.
#
#   tools/zig-spec-git.sh NAME [COLSxROWS] [OUT_DIR]
#
# NAME picks docs/ui-spec/steps-<NAME>.jsonl. The workspace `ws` is a
# repo with two local branches (main, one commit ahead of its upstream;
# feature), a remote `origin` with three branches (main, feature,
# hotfix) whose URL names github.com, two linked worktrees beside it —
# `wt-locked` (on feature; locked, clean) and `wt-dirty` (detached at
# v1.0; an untracked file) — one stash and two tags (v1.0 lightweight,
# v2.0 annotated). A NAME ending in `-all` (the All repos dump) puts
# that repo at `ws/alpha` beside a second, smaller one, `ws/beta` (on
# `dev`, a `main` branch, one tag) — the workspace is then no repo
# itself, so discovery lists both. The shared fixture is never touched:
# everything lives under a mktemp directory. The dump IS the spec: the
# panel is a deliberate departure from the Rust sidebar, so there is
# nothing to diff against.
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
case $NAME in *-all) REPO=$WS/alpha; ALL=1 ;; *) REPO=$WS; ALL= ;; esac
mkdir -p "$REPO" "$DATA"
g() { git -C "$REPO" -c user.email=spec@mnml.dev -c user.name=spec -c commit.gpgsign=false "$@"; }
# Fixed dates so the graph's DATE / TIME column is the same every run.
export GIT_AUTHOR_DATE="2026-09-06T20:00:00+0000" GIT_COMMITTER_DATE="2026-09-06T20:00:00+0000"
g init -q -b main
printf 'one\n' >"$REPO/a.txt"
printf '.mnml/\n' >"$REPO/.gitignore"
g add a.txt .gitignore
g commit -q -m "init"
g tag v1.0
printf 'two\n' >>"$REPO/a.txt"
g commit -q -am "second"
g tag -a v2.0 -m "release two"
g branch feature
git init -q --bare "$TMP/remote.git"
g remote add origin "$TMP/remote.git"
g push -q -u origin main feature main:hotfix
# The forge glyph reads the URL; the refs fetched above stay.
g remote set-url origin git@github.com:me/thing.git
# main: one commit ahead of origin/main.
printf 'three\n' >>"$REPO/a.txt"
g commit -q -am "third"
g worktree add -q "$TMP/wt-locked" feature
g worktree lock --reason keep "$TMP/wt-locked"
g worktree add -q --detach "$TMP/wt-dirty" v1.0
printf 'x\n' >"$TMP/wt-dirty/new.txt"
printf 'four\n' >>"$REPO/a.txt"
g stash push -q -m "half done"
if [ -n "$ALL" ]; then
  B=$WS/beta; mkdir -p "$B"
  gb() { git -C "$B" -c user.email=spec@mnml.dev -c user.name=spec -c commit.gpgsign=false "$@"; }
  gb init -q -b dev
  printf 'b\n' >"$B/b.txt"
  gb add b.txt
  gb commit -q -m "beta init"
  gb tag v0.1
  gb branch main
fi
cat >"$DATA/config.zon" <<'EOF'
.{
    .editor = .{ .input_style = .standard },
    .ui = .{ .line_numbers = true, .first_launch_complete = true, .hover_tooltip = true },
    .ipc = .{ .write_screen = true },
}
EOF
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
