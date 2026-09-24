#!/usr/bin/env bash
# tools/debug-suite-check.sh [ZIG BUILD ARGS…]
#
# The unit suite in Debug, as one verdict a verification chain can stop
# on: `zig build unit-debug` (every unit-test binary, built Debug
# whatever -Doptimize says), then either
#
#   unit debug: ok (Ns)
#   UNIT DEBUG FAILED (exit N, Ns)
#
# on the last line, with zig's exit code. A chain that only runs the
# ReleaseSafe suite misses what shows in Debug alone — a race the
# optimizer hides, a test whose cost the testing allocator's per-alloc
# stack capture multiplies — so this runs beside it (`./run.sh check`).
# Around 5 minutes warm on the machine it was sized on; no test in it
# should take 30 s (docs/CONTRIBUTING.md, "Tests").
#
# Extra arguments reach `zig build` (`-Dtest-trace=true` names each test
# as it runs; `--seed 0x…` reruns a seeded test's seed). MNML_ZIG names
# the zig, as it does for run.sh.
set -u
cd "$(dirname "$0")/.." || exit 2
zig=${MNML_ZIG:-zig}
start=$(date +%s)
"$zig" build unit-debug "$@"
rc=$?
secs=$(( $(date +%s) - start ))
if [ "$rc" -ne 0 ]; then
    echo "UNIT DEBUG FAILED (exit $rc, ${secs}s)"
    exit "$rc"
fi
echo "unit debug: ok (${secs}s)"
