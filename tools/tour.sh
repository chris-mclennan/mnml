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
# A stale mnml-drive (built before tools/drive/ last changed) is rebuilt
# first; MNML_DRIVE_NO_REBUILD=1 refuses instead. Without --exe, a
# zig-out/bin/mnml-zig older than src/ is a warning, not a stop. Exit 1
# only on a CHANGED shot or a failed assert.
#
# Needs: macOS, ghostty, `zig build -Ddrive`, python3 (stdlib only),
# Accessibility + Screen Recording for the terminal that runs it
# (`zig-out/bin/mnml-drive doctor`). See docs/LOOK.md and docs/DRIVE.md.
#
# `run` and `sweep` without those grants re-run themselves in a new
# Ghostty window, which holds them (tools/tour/ghostty-hop.sh), and relay
# its output and exit code. --in-ghostty / MNML_TOUR_GHOSTTY=1 forces the
# hop; --no-ghostty / MNML_TOUR_GHOSTTY=0 never hops.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$ROOT/zig-out/bin/mnml-drive" ] || { echo "tour.sh: build the driver first: zig build -Ddrive" >&2; exit 64; }
# --in-ghostty / --no-ghostty are this script's, wherever they appear.
hop=${MNML_TOUR_GHOSTTY:-auto}
args=()
for a in "$@"; do
  case "$a" in
    --in-ghostty) hop=1 ;;
    --no-ghostty) hop=0 ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
# A driver older than tools/drive/ is rebuilt (or, under
# MNML_DRIVE_NO_REBUILD=1, refused) before anything launches; `diff` and
# `accept` never launch, so they skip it (tools/tour/stamp.py).
case "${1:-}" in
  diff|accept|-h|--help|help) ;;
  *) MNML_STAMP_WHO=tour.sh python3 "$ROOT/tools/tour/stamp.py" drive || exit $? ;;
esac
# The permissions hop: only for the verbs that drive a window, only on
# macOS, never from inside the hop itself.
case "${1:-}" in
  diff|accept|-h|--help|help) hop=0 ;;
esac
if [ "$hop" != 0 ] && [ -z "${MNML_TOUR_IN_GHOSTTY:-}" ] && [ "$(uname -s)" = Darwin ]; then
  if [ "$hop" = 1 ] || ! "$ROOT/zig-out/bin/mnml-drive" doctor >/dev/null 2>&1; then
    [ "$hop" = 1 ] || echo "tour.sh: this process lacks Accessibility / Screen Recording; running in a Ghostty window that holds them" >&2
    exec "$ROOT/tools/tour/ghostty-hop.sh" "$ROOT/tools/tour.sh" "$@"
  fi
fi
case "${1:-}" in
  run|diff|accept|sweep) exec python3 "$ROOT/tools/tour/tour.py" "$@" ;;
  -h|--help|help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) exec python3 "$ROOT/tools/tour/tour.py" run "$@" ;;
esac
