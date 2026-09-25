#!/usr/bin/env bash
# tour.sh — mnml-zig's real-screen tour: shots of the REAL ghostty window,
# not the headless grid. One window at a time (`mnml-drive`), driven
# through the file channel (`ipc.allow_input`), so it never takes the
# keyboard from whoever is at the machine.
#
#   tools/tour.sh [run] [--exe PATH] [--only a,b] [--ascii] [--out DIR]
#       launch at 120x40 in a private workspace (a small git repo, the
#       offline Jira and Bitbucket), walk the curated states, shoot each
#       to <out>/<nn>-<name>.png (+ its screen.txt), check the pixel
#       asserts (tests/tour/asserts.zon), diff against the baselines
#       (tests/tour/baseline/) and print the review prompt's path.
#       Default out: .verify/tour.
#   tools/tour.sh diff [NAME…] [--out DIR] [--threshold PCT] [--tolerance N]
#       masked pixel diff of the last run against the baselines
#       (masks: tests/tour/masks.zon) — `ok` or `CHANGED n%` per shot.
#   tools/tour.sh accept NAME… | --all [--out DIR]
#       re-baseline shots from the last run (re-encoded as RGB PNG).
#   tools/tour.sh sweep [FILE|DIR…] [--all] [--limit N] [--out DIR]
#       every tests/e2e/*.test through the real window, the last frame
#       shot to <out>/sweep/<file>.png; resumable (skips files with a
#       shot unless --all), tolerant (an erroring file is logged and
#       skipped). Diffs against tests/tour/sweep-baseline/ when present
#       (never committed). Default out: .verify/sweep. Meant to run
#       overnight.
#
# Needs: macOS, ghostty, `zig build -Ddrive`, python3 (stdlib only),
# Accessibility + Screen Recording for the terminal that runs it
# (`zig-out/bin/mnml-drive doctor`). See docs/LOOK.md and docs/DRIVE.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$ROOT/zig-out/bin/mnml-drive" ] || { echo "tour.sh: build the driver first: zig build -Ddrive" >&2; exit 64; }
case "${1:-}" in
  run|diff|accept|sweep) exec python3 "$ROOT/tools/tour/tour.py" "$@" ;;
  -h|--help|help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) exec python3 "$ROOT/tools/tour/tour.py" run "$@" ;;
esac
