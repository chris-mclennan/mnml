#!/usr/bin/env bash
# look.sh — an agent's real window on a workspace it is already driving
# headless: launch it, send the same channel lines, shoot a PNG to Read,
# sample a pixel, quit. The recipe and its rules: docs/LOOK.md.
#
#   tools/look.sh launch WS [--exe PATH] [--cols N] [--rows N] [--root DIR] [--sandbox]
#                  [--env KEY=VALUE]…   (repeatable; `PATH=/dir:$PATH` prepends)
#   tools/look.sh key SPEC | type TEXT | run COMMAND_ID | open PATH
#   tools/look.sh click X Y [right] | hover X Y | send JSON [JSON…]
#   tools/look.sh shot NAME            prints the PNG path
#   tools/look.sh pixel X Y [FX FY]    prints #rrggbb (FX/FY: 0..1 in the cell)
#   tools/look.sh screen | status      the live dumps
#   tools/look.sh quit
#
# Never `mnml-drive focus`; one window per agent; quit when done.
# `launch` rebuilds a stale mnml-drive first (MNML_DRIVE_NO_REBUILD=1
# refuses) and warns when a default zig-out/bin/mnml-zig is older than src/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$ROOT/zig-out/bin/mnml-drive" ] || { echo "look.sh: build the driver first: zig build -Ddrive" >&2; exit 64; }
case "${1:-}" in
  ""|-h|--help|help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  # A driver older than tools/drive/ is rebuilt (MNML_DRIVE_NO_REBUILD=1:
  # refused) before a window opens; the other verbs act on that window.
  launch) MNML_STAMP_WHO=look.sh python3 "$ROOT/tools/tour/stamp.py" drive || exit $? ;;
esac
exec python3 "$ROOT/tools/tour/tour.py" look "$@"
