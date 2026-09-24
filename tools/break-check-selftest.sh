#!/usr/bin/env bash
# tools/break-check-selftest.sh — proves tools/break-check.sh's verdicts
# without a compile. A fake `zig` (BREAK_CHECK_ZIG) replays canned
# `-Dtest-trace` runner output, one scripted reply per `zig build` call,
# against a throwaway fixture file:
#
#   1. a filter that matches no named test → exit 4, "filter matched no
#      test — vacuous" (the verdict three agents got as "still passes")
#   2. the real shape: broken run fails, restored run passes → exit 0
#   3. the break lands but the test still passes → exit 1
#   4. the test fails on the restored file too → exit 5
#   5. the restored run matches nothing → exit 4
#   6. a sed expression that changes nothing → exit 2, zig never called
#   7. the broken copy does not compile → exit 3
#   8. --help → exit 0
# and after every scenario the fixture is byte-identical to the original.
#
#   tools/break-check-selftest.sh            (< 1 s)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/tools/break-check.sh"
TMPDIR_BASE=${TMPDIR:-/tmp}; TMPDIR_BASE=${TMPDIR_BASE%/}
TMP=$(mktemp -d "${TMPDIR_BASE}/break-check-selftest.XXXXXX") || exit 70  # GNU mktemp: a template, not -t NAME
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/fixture.zig"
printf 'const answer = 42;\n' > "$FIXTURE"
cp "$FIXTURE" "$TMP/fixture.orig"

# The fake zig: pops the first line of $TMP/queue — `<reply> <exit>` — and
# prints the canned reply on stderr, the way the runner does.
QUEUE="$TMP/queue"
CALLS="$TMP/calls"
cat > "$TMP/fakezig" <<EOF
#!/bin/sh
echo "\$*" >> "$CALLS"
line=\$(head -n 1 "$QUEUE")
tail -n +2 "$QUEUE" > "$QUEUE.next" && mv "$QUEUE.next" "$QUEUE"
reply=\${line%% *}
rc=\${line##* }
cat "$TMP/reply-\$reply" >&2
exit "\$rc"
EOF
chmod +x "$TMP/fakezig"
export BREAK_CHECK_ZIG="$TMP/fakezig"

# Canned runner output. `nomatch` is what the whole suite prints when the
# filter hits nothing: only the unnamed reference blocks run.
cat > "$TMP/reply-nomatch" <<'EOF'
filter zzz: 0 of 15 tests matched
0 passed; 0 skipped; 0 failed.
filter zzz: 0 of 4 tests matched
0 passed; 0 skipped; 0 failed.
▶ 1/10 main.test_0
  ok   0 ms
▶ 2/10 app.test_0
  ok   0 ms
filter zzz: 0 of 1454 tests matched
0 passed; 0 skipped; 0 failed.
EOF
cat > "$TMP/reply-fail" <<'EOF'
filter isNewer: 0 of 15 tests matched
0 passed; 0 skipped; 0 failed.
▶ 259/1454 app.update.test.isNewer: semver order, v prefix and suffixes, garbage is never newer
  FAIL (TestUnexpectedResult) 1 ms
filter isNewer: 1 of 1454 tests matched
0 passed; 0 skipped; 1 failed.
error: the following command exited with error code 1:
EOF
cat > "$TMP/reply-pass" <<'EOF'
filter isNewer: 0 of 15 tests matched
0 passed; 0 skipped; 0 failed.
▶ 259/1454 app.update.test.isNewer: semver order, v prefix and suffixes, garbage is never newer
  ok   1 ms
filter isNewer: 1 of 1454 tests matched
1 passed; 0 skipped; 0 failed.
EOF
cat > "$TMP/reply-compile" <<'EOF'
src/app/update.zig:150:5: error: expected ';', found '}'
error: the following command failed with 1 compilation errors:
EOF

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

# scenario <label> <expected-exit> <expected-output-substring> <queue-lines...>
# then runs break-check on the fixture with the standard break.
scenario() {
    local label=$1 want_rc=$2 want_out=$3; shift 3
    : > "$QUEUE"; : > "$CALLS"
    for l in "$@"; do echo "$l" >> "$QUEUE"; done
    out=$("$CHECK" "$FILTER" "$FIXTURE" "$EXPR" 2>&1); rc=$?
    if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_out"; then
        ok "$label (exit $rc)"
    else
        bad "$label: want exit $want_rc with '$want_out', got exit $rc" "$out"
    fi
    if cmp -s "$FIXTURE" "$TMP/fixture.orig"; then ok "$label: fixture restored"; else bad "$label: fixture NOT restored"; fi
    [ -s "$QUEUE" ] && bad "$label: $(wc -l < "$QUEUE" | tr -d ' ') scripted reply(s) never consumed"
    calls=$(wc -l < "$CALLS" | tr -d ' ')
}

echo "break-check-selftest: $CHECK on $FIXTURE"

FILTER="zzz"; EXPR='s/answer = 42/answer = 43/'
scenario "1. no-match filter is vacuous" 4 "filter matched no test — vacuous" "nomatch 0"
[ "$calls" -eq 1 ] && ok "1. stopped after the broken run" || bad "1. expected 1 zig call, got $calls"

FILTER="isNewer"
scenario "2. broken fails, restored passes" 0 "break-check: OK" "fail 1" "pass 0"
[ "$calls" -eq 2 ] && ok "2. both runs happened" || bad "2. expected 2 zig calls, got $calls"
grep -q 'MNML_TEST_FILTER' "$CHECK" && ok "2. selects at run time (MNML_TEST_FILTER)" || bad "2. no MNML_TEST_FILTER in the script"
if grep -v '^#' "$CHECK" | grep -q -- '-Dtest-filter'; then bad "2. still passes -Dtest-filter"; else ok "2. never passes -Dtest-filter"; fi
grep -q 'build unit' "$CHECK" && ok "2. builds the unit step, not the gate" || bad "2. does not build the unit step"

scenario "3. still passes with the break" 1 "still passes with the break in place" "pass 0"

scenario "4. fails on the restored file too" 5 "fails on the restored file too" "fail 1" "fail 1"

scenario "5. restored run matches nothing" 4 "vacuous" "fail 1" "nomatch 0"
printf '%s' "$out" | grep -q '(restored run)' && ok "5. names the restored run" || bad "5. does not say which run"

EXPR='s/nothing here/still nothing/'
scenario "6. the break did not land" 2 "the break did not land"
[ "$calls" -eq 0 ] && ok "6. zig never called" || bad "6. expected 0 zig calls, got $calls"

EXPR='s/answer = 42/answer = 43/'
scenario "7. broken copy does not compile" 3 "does not compile" "compile 1"

"$CHECK" --help > /dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "8. --help exits 0" || bad "8. --help exit $rc"
"$CHECK" 2>/dev/null; rc=$?
[ "$rc" -eq 64 ] && ok "8. no arguments exits 64" || bad "8. no arguments exit $rc"

echo "break-check-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
