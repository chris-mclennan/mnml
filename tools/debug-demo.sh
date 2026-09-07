#!/usr/bin/env bash
# debug-demo — open mnml-zig in THIS terminal on a throwaway workspace
# wired to the fake debug adapter, so the debugger can be seen and driven
# on a real screen (the same seed tools/zig-spec.sh dumps headlessly).
#
#   tools/debug-demo.sh [vim|standard]      (default: standard)
#
# Inside: open prog.dbg, put the cursor on line 4, then
#   standard: F9 sets a breakpoint, F5 starts, F10 steps over, F11 in,
#             Shift+F11 out, Shift+F5 continues; hover a name for its value;
#             right-click the gutter to edit the breakpoint.
#   vim:      <leader>db breakpoint, <leader>dc start/continue, <leader>do
#             step over, <leader>di into, <leader>dO out, K evaluates the
#             word under the cursor, <leader>du toggles the DEBUG section,
#             <leader>dr focuses the console.
# The workspace is deleted when mnml-zig exits.
set -u
STYLE=${1:-standard}
case "$STYLE" in vim|standard) ;; *) echo "usage: $0 [vim|standard]" >&2; exit 64 ;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
export MNML_FAKE_DAP=${MNML_FAKE_DAP:-$ROOT/zig-out/bin/mnml-fake-dap}
[ -x "$ZIG" ] && [ -x "$MNML_FAKE_DAP" ] || { echo "build first: zig build -Doptimize=ReleaseSafe" >&2; exit 64; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WS=$TMP/ws; DATA=$TMP/data
mkdir -p "$WS" "$DATA"
printf 'let x = 1\nlet p = struct{a=1,b="two"}\nprint "hello"\nx = x + 1\nfn f\n  let y = 10\n  x = x * y\nend\ncall f\nprint x\n' >"$WS/prog.dbg"
cat >"$DATA/config.zon" <<EOF
.{
    .editor = .{ .input_style = .$STYLE, .inline_values = true },
    .ui = .{ .line_numbers = true, .first_launch_complete = true, .hover_tooltip = true },
    .dap = .{ .dbg = .{ .cmd = "\$MNML_FAKE_DAP" } },
}
EOF
MNML_DATA_ROOT=$DATA exec "$ZIG" --input "$STYLE" "$WS"
