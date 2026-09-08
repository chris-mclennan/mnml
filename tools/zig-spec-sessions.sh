#!/usr/bin/env bash
# zig-spec-sessions — dump the sessions table's UI spec: run mnml-zig
# headless on a throwaway workspace whose HOME `tools/seed-sessions-
# home.sh --waiting` seeded (live, idle, ended and waiting sessions,
# fake `claude` processes behind the live ones), feed a steps file,
# keep the screen as docs/ui-spec/zig-<name>-<size>.txt.
#
#   tools/zig-spec-sessions.sh NAME [COLSxROWS] [OUT_DIR]
#
# NAME picks docs/ui-spec/steps-<NAME>.jsonl. The Rust dashboard the
# table replaced was never driven for a spec, so there is nothing to
# diff against: the dump IS the spec. Everything lives under a mktemp
# directory; the fake processes are stopped at exit.
set -u
NAME=$1; SIZE=${2:-120x40}; OUT_DIR=${3:-$(cd "$(dirname "$0")/.." && pwd)/docs/ui-spec}
COLS=${SIZE%x*}; ROWS=${SIZE#*x}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
STEPS=$ROOT/docs/ui-spec/steps-$NAME.jsonl
[ -f "$STEPS" ] || { echo "no steps file: $STEPS" >&2; exit 64; }
[ -x "$ZIG" ] || { echo "build first: zig build" >&2; exit 64; }

TMP=$(mktemp -d)
WS=$TMP/ws; DATA=$TMP/data; H=$TMP/home
mkdir -p "$WS/.mnml" "$DATA"
trap '"$ROOT/tools/seed-sessions-home.sh" stop "$H" 2>/dev/null; rm -rf "$TMP"' EXIT
"$ROOT/tools/seed-sessions-home.sh" --waiting "$H" "$WS" >/dev/null
cat >"$DATA/config.zon" <<'EOF'
.{
    .editor = .{ .input_style = .standard },
    .ui = .{ .line_numbers = true, .first_launch_complete = true },
    .ipc = .{ .write_screen = true },
}
EOF
IPC=$WS/.mnml/ipc-zig
HOME=$H PATH=$H/bin:$PATH MNML_DATA_ROOT=$DATA MNML_COLS=$COLS MNML_ROWS=$ROWS "$ZIG" --headless --input standard "$WS" >"$TMP/zig.log" 2>&1 &
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
OUT=$OUT_DIR/zig-$NAME-${COLS}x${ROWS}.txt
cp "$IPC/screen.txt" "$OUT" 2>/dev/null || { echo "(no screen.txt — see $TMP/zig.log)" >&2; cat "$TMP/zig.log" >&2; exit 1; }
echo '{"cmd":"quit"}' >>"$IPC/command"
for _ in $(seq 1 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "== $OUT   (log: $TMP/zig.log)"
