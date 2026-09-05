#!/usr/bin/env bash
# tools/break-check.sh <test-name-substring> <file> <sed-expr>
#
# Proves a unit test can fail. Applies <sed-expr> to a scratch copy of
# <file>, swaps the broken copy in, runs only the tests whose name
# contains <test-name-substring> (`-Dtest-filter`), asserts that run
# FAILS, and restores the original — on every exit path.
#
# Two things it refuses to call a pass, because both have shipped as
# "green" before:
#   - the sed expression changed nothing (a `zig fmt` reflow moved the
#     line): exit 2, "the break did not land";
#   - the broken copy does not compile: exit 3 — a compile error is not
#     the test failing.
#
#   tools/break-check.sh "isNewer" src/app/update.zig 's/\.eq => l\.pre and !r\.pre/.eq => false/'

set -u
if [ $# -ne 3 ]; then
    echo "usage: $0 <test-name-substring> <file> <sed-expr>" >&2
    exit 64
fi
name=$1
file=$2
expr=$3
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
[ -f "$file" ] || { echo "break-check: no such file: $file" >&2; exit 64; }

scratch=$(mktemp -d)
cp "$file" "$scratch/orig"
restore() { cp "$scratch/orig" "$file"; rm -rf "$scratch"; }
trap restore EXIT

sed -e "$expr" "$scratch/orig" > "$file"
if cmp -s "$scratch/orig" "$file"; then
    echo "break-check: FAIL — the sed expression changed nothing in $file; the break did not land"
    exit 2
fi
echo "break-check: broke $file:"
diff "$scratch/orig" "$file" | grep '^[<>]' | head -20

if zig build test -Dtest-filter="$name" > "$scratch/log" 2>&1; then
    echo "break-check: FAIL — '$name' still passes with the break in place (is the test vacuous?)"
    grep -E 'pass|fail' "$scratch/log" | head -5
    exit 1
fi
if grep -qE '^[^ ]+\.zig:[0-9]+:[0-9]+: error:' "$scratch/log"; then
    echo "break-check: FAIL — the broken copy does not compile; pick a break that compiles:"
    grep -E 'error:' "$scratch/log" | head -5
    exit 3
fi
if ! grep -qE '[0-9]+ fail' "$scratch/log"; then
    echo "break-check: FAIL — no test ran (does any test name contain '$name'?)"
    tail -5 "$scratch/log"
    exit 4
fi
echo "break-check: OK — with the break, $(grep -oE '[0-9]+ pass, [0-9]+ fail' "$scratch/log" | head -1):"
grep -E "^error: '.*' failed:" "$scratch/log" | head -5
echo "break-check: restored $file"
