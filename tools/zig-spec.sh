#!/usr/bin/env bash
# zig-spec — dump a Zig-only UI spec: run mnml-zig headless on a throwaway
# workspace seeded for the fake debug adapter, feed a steps file, keep the
# screen as docs/ui-spec/zig-<name>-<size>.txt.
#
#   tools/zig-spec.sh NAME [COLSxROWS] [OUT_DIR]
#
# NAME picks docs/ui-spec/steps-<NAME>.jsonl. The workspace holds one
# program, `prog.dbg`, and the data root's config.zon names
# `$MNML_FAKE_DAP` (zig-out/bin/mnml-fake-dap) as the `.dbg` adapter —
# the home layer is trusted, so no trust dialog stands in the way. The
# Rust side has no such screen (the debug UI is the one deliberate
# departure from same-look), so there is nothing to diff against: the
# dump IS the spec.
set -u
NAME=$1; SIZE=${2:-120x40}; OUT_DIR=${3:-$(cd "$(dirname "$0")/.." && pwd)/docs/ui-spec}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
export MNML_FAKE_DAP=${MNML_FAKE_DAP:-$ROOT/zig-out/bin/mnml-fake-dap}
STEPS=$ROOT/docs/ui-spec/steps-$NAME.jsonl
[ -f "$STEPS" ] || { echo "no steps file: $STEPS" >&2; exit 64; }
[ -x "$ZIG" ] && [ -x "$MNML_FAKE_DAP" ] || { echo "build first: zig build" >&2; exit 64; }

TMP=$(mktemp -d)
WS=$TMP/ws; DATA=$TMP/data
mkdir -p "$WS" "$DATA"
# The program the specs stop in (the same one src/app/dap.zig's
# integration test debugs): a breakpoint on line 4 stops before
# `x = x + 1` with x = 1 and p a struct.
printf 'let x = 1\nlet p = struct{a=1,b="two"}\nprint "hello"\nx = x + 1\nfn f\n  let y = 10\n  x = x * y\nend\ncall f\nprint x\n' >"$WS/prog.dbg"
# A spec that needs more in its workspace ships it as
# docs/ui-spec/seed-<NAME>/ (the ZON view's config.zon, say); one that
# needs the environment set ships docs/ui-spec/env-<NAME>, sourced here
# with $ROOT in scope (the FONTS section's fixture fonts, say).
[ -d "$ROOT/docs/ui-spec/seed-$NAME" ] && cp -R "$ROOT/docs/ui-spec/seed-$NAME/." "$WS/"
# A spec that needs the environment set ships docs/ui-spec/env-<NAME>,
# sourced here with $ROOT in scope and exported to the run (the fonts
# spec seeds MNML_FONT_DIRS; the launchers spec points
# MNML_MARKETPLACE_LOCAL at the repo's launchers/).
if [ -f "$ROOT/docs/ui-spec/env-$NAME" ]; then set -a; . "$ROOT/docs/ui-spec/env-$NAME"; set +a; fi
cat >"$DATA/config.zon" <<'EOF'
.{
    .editor = .{ .input_style = .standard },
    .ui = .{ .line_numbers = true, .first_launch_complete = true, .hover_tooltip = true },
    .ipc = .{ .write_screen = true },
    .dap = .{ .dbg = .{ .cmd = "$MNML_FAKE_DAP" } },
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
# A `wait_ms` step holds the app for that long; pace the feed to match so
# the screen is copied after the last step has painted.
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
