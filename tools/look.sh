#!/usr/bin/env bash
# look.sh — an agent's real window on a workspace it is already driving
# headless: launch it, send the same channel lines, shoot a PNG to Read,
# sample a pixel, quit. The recipe and its rules: docs/LOOK.md.
#
#   tools/look.sh launch WS [--exe PATH] [--cols N] [--rows N] [--root DIR]
#   tools/look.sh key SPEC | type TEXT | run COMMAND_ID | open PATH
#   tools/look.sh click X Y [right] | hover X Y | send JSON [JSON…]
#   tools/look.sh shot NAME            prints the PNG path
#   tools/look.sh pixel X Y [FX FY]    prints #rrggbb (FX/FY: 0..1 in the cell)
#   tools/look.sh screen | status      the live dumps
#   tools/look.sh quit
#
# Never `mnml-drive focus`; one window per agent; quit when done.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$ROOT/zig-out/bin/mnml-drive" ] || { echo "look.sh: build the driver first: zig build -Ddrive" >&2; exit 64; }
case "${1:-}" in
  ""|-h|--help|help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
exec python3 "$ROOT/tools/tour/tour.py" look "$@"
