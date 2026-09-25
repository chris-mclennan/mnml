#!/usr/bin/env bash
# tools/break-check.sh <test-name-substring> <file> <sed-expr>
#
# Proves a unit test can fail. Applies <sed-expr> to a scratch copy of
# <file>, swaps the broken copy in, runs only the tests whose name
# contains <test-name-substring>, asserts that run FAILS, restores the
# original — on every exit path — and runs the same tests once more to
# see them pass on the untouched file.
#
# The tests are selected at run time (`MNML_TEST_FILTER` on the
# `-Dtest-trace` runner, `zig build unit`), not with `-Dtest-filter`: the
# compile-time filter only sees a test whose file something still
# references, so a file no reference block names silently has no tests
# under it — and a green run of nothing looked like a vacuous test.
#
# Four things it refuses to call a pass, because each has shipped as
# "green" before:
#   - the sed expression changed nothing (a `zig fmt` reflow moved the
#     line): exit 2, "the break did not land";
#   - the broken copy does not compile: exit 3 — a compile error is not
#     the test failing;
#   - the filter matched no named test, in either run: exit 4,
#     "filter matched no test — vacuous";
#   - the named test still fails once the file is restored: exit 5 — the
#     failure was never about the break.
# Exit 1 is the verdict the script exists for: the test passes with the
# break in place. Exit 64 is a usage error.
#
#   tools/break-check.sh "isNewer" src/app/update.zig 's/\.eq => l\.pre and !r\.pre/.eq => false/'
#
# `BREAK_CHECK_ZIG` names the `zig` to run (tools/break-check-selftest.sh
# points it at a fake that replays canned runner output).

set -u
usage() { echo "usage: $0 <test-name-substring> <file> <sed-expr>" >&2; }
if [ $# -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
    usage 2>&1
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
fi
if [ $# -ne 3 ]; then
    usage
    exit 64
fi
name=$1
file=$2
expr=$3
zig=${BREAK_CHECK_ZIG:-zig}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
[ -f "$file" ] || { echo "break-check: no such file: $file" >&2; exit 64; }

scratch=$(mktemp -d)
cp "$file" "$scratch/orig"
restore() {
    [ -d "$scratch" ] || return 0
    cp "$scratch/orig" "$file"
    rm -rf "$scratch"
}
trap restore EXIT

# Run the named tests; the log lands in $1. The runner prints one
# `filter <name>: K of M tests matched` line per test binary and a
# `▶ n/M <module>.test.<name>` line per test it runs; unnamed blocks
# print as `<module>.test_N`.
run_tests() {
    # MNML_TEST_STRICT: a break has to fail the first time — the trace
    # runner would otherwise rerun it and call a pass on the retry FLAKY.
    MNML_TEST_STRICT=1 MNML_TEST_FILTER="$name" "$zig" build unit -Dtest-trace > "$1" 2>&1
}
sum() { awk '{ s += $1 } END { print s + 0 }'; }
matched() { grep -E '^filter .*: [0-9]+ of [0-9]+ tests matched$' "$1" | sed -E 's/.*: ([0-9]+) of .*/\1/' | sum; }
named_ran() { grep -E '^▶ [0-9]+/[0-9]+ ' "$1" | grep -vcE '\.test_[0-9]+$'; }
failed() { grep -E '^[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed(; [0-9]+ FLAKY)?\.$' "$1" | sed -E 's/^[0-9]+ passed; [0-9]+ skipped; ([0-9]+) failed.*/\1/' | sum; }
vacuous() {
    echo "break-check: FAIL — filter matched no test — vacuous: no named test contains '$name' ($1 run)"
    grep -E '^filter ' "$2" | head -3
    exit 4
}

sed -e "$expr" "$scratch/orig" > "$file"
if cmp -s "$scratch/orig" "$file"; then
    echo "break-check: FAIL — the sed expression changed nothing in $file; the break did not land"
    exit 2
fi
echo "break-check: broke $file:"
diff "$scratch/orig" "$file" | grep '^[<>]' | head -20

run_tests "$scratch/broken"
broken_rc=$?
if grep -qE '^[^ ]+\.zig:[0-9]+:[0-9]+: error:' "$scratch/broken"; then
    echo "break-check: FAIL — the broken copy does not compile; pick a break that compiles:"
    grep -E 'error:' "$scratch/broken" | head -5
    exit 3
fi
broken_matched=$(matched "$scratch/broken")
broken_named=$(named_ran "$scratch/broken")
if [ "$broken_matched" -lt 1 ] || [ "$broken_named" -lt 1 ]; then
    vacuous broken "$scratch/broken"
fi
broken_failed=$(failed "$scratch/broken")
if [ "$broken_rc" -eq 0 ] && [ "$broken_failed" -eq 0 ]; then
    echo "break-check: FAIL — '$name' still passes with the break in place (is the test vacuous?)"
    grep -E '^filter |passed;' "$scratch/broken" | grep -v ' 0 of ' | head -5
    exit 1
fi
if [ "$broken_failed" -eq 0 ]; then
    echo "break-check: FAIL — the broken run did not fail through the test ($zig build exit $broken_rc):"
    tail -5 "$scratch/broken"
    exit 3
fi
echo "break-check: with the break, $broken_matched matched, $broken_failed failed:"
grep -E '^▶ ' "$scratch/broken" | grep -vE '\.test_[0-9]+$' | sed 's/^▶ [0-9/]* /  /' | cut -c1-120 | head -5

cp "$scratch/orig" "$file"
echo "break-check: restored $file"
run_tests "$scratch/restored"
restored_rc=$?
restored_matched=$(matched "$scratch/restored")
restored_named=$(named_ran "$scratch/restored")
if [ "$restored_matched" -lt 1 ] || [ "$restored_named" -lt 1 ]; then
    vacuous restored "$scratch/restored"
fi
restored_failed=$(failed "$scratch/restored")
if [ "$restored_rc" -ne 0 ] || [ "$restored_failed" -ne 0 ]; then
    echo "break-check: FAIL — '$name' fails on the restored file too ($zig build exit $restored_rc, $restored_failed failed); the failure is not the break's"
    tail -5 "$scratch/restored"
    exit 5
fi
echo "break-check: OK — restored, $restored_matched matched, all pass"
