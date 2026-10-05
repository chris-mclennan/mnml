#!/usr/bin/env bash
# tools/upstream/ghostty-resize-repro/check.sh [pinned|main] [--main-sha SHA] [--expect broken|fixed]
#
# Builds and runs the resize repro (README.md here) in a scratch copy
# under the repository's .verify/ (git-ignored), not in place: Zig 0.16
# fetches a project's packages into a zig-pkg/ beside its build.zig.zon,
# and one left under tools/ is walked by `zig fmt --check tools`, which
# then fails on ghostty's own sources.
#
#   check.sh pinned                          # the commit mnml pins
#   check.sh main --main-sha <40-hex sha>    # moves ghostty_main to that
#                                            # commit in the scratch copy
#   check.sh main --main-sha <sha> --expect broken
#
# With --expect the exit code is the repro's: 0 when its verdict line
# (`RESIZE-REDRAW: still broken` / `RESIZE-REDRAW: FIXED upstream`) is
# the expected one, 1 when it is not; 3 when the repro did not build or
# run (no verdict line), 64 a usage error. The verdict line goes to
# stdout; the repro's full output to stderr and to out.txt in the scratch.
#
# `UW_REPRO_SCRATCH` names the scratch directory (default
# <repo>/.verify/ghostty-resize-repro).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
which=pinned
main_sha=
expect=
while [ $# -gt 0 ]; do
    case "$1" in
        pinned | main) which="$1" ;;
        --main-sha) main_sha="${2:?--main-sha needs a sha}"; shift ;;
        --expect) expect="${2:?--expect needs broken or fixed}"; shift ;;
        -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check.sh: unknown argument $1" >&2; exit 64 ;;
    esac
    shift
done
case "$expect" in "" | broken | fixed) ;; *) echo "check.sh: --expect is broken or fixed" >&2; exit 64 ;; esac

scratch="${UW_REPRO_SCRATCH:-$repo/.verify/ghostty-resize-repro}"
mkdir -p "$scratch/src" || exit 2
cp "$here/build.zig" "$here/build.zig.zon" "$scratch/" || exit 2
cp "$here/src/main.zig" "$scratch/src/" || exit 2
cd "$scratch" || exit 2

if [ -n "$main_sha" ]; then
    case "$main_sha" in
        *[!0-9a-f]* | "") echo "check.sh: --main-sha is a 40-hex commit" >&2; exit 64 ;;
    esac
    url="https://github.com/ghostty-org/ghostty/archive/$main_sha.tar.gz"
    zig fetch --save=ghostty_main "$url" || exit 3
fi

# `zig build` exits 1 both for a failed compile and for a run that
# exited non-zero, so the verdict is read from the output, not the status.
zig build run -Dghostty="$which" ${expect:+-Dexpect="$expect"} 2>&1 | tee "$scratch/out.txt" >&2
verdict=$(grep -E '^RESIZE-REDRAW: ' "$scratch/out.txt" | tail -1)
if [ -z "$verdict" ]; then
    echo "check.sh: no RESIZE-REDRAW line — the repro did not build or run" >&2
    exit 3
fi
echo "$verdict"
case "$expect:$verdict" in
    ":"*) exit 0 ;;
    "broken:RESIZE-REDRAW: still broken" | "fixed:RESIZE-REDRAW: FIXED upstream") exit 0 ;;
    *) exit 1 ;;
esac
