#!/usr/bin/env bash
# tools/upstream-watch-check.sh — tools/upstream-watch.sh, offline
#
# Runs the watch against the canned responses in tools/upstream/fixtures/
# (invented data: example-org repositories, made-up shas and versions)
# and checks what it parses and what it decides:
#
#   root/        an invented checkout: build.zig.zon, three workflows
#   week1/       every answer the run asks for
#   week1-info/  overlays week1: only info-level values moved (upstream
#                gained commits) — the fingerprint must not move
#   week2/       overlays week1: a maintainer commented on the thread
#   week3/       overlays week1: the toolchain pull request merged and
#                the issue's last task was ticked
#
# Cases: a pin behind, a pin current, a crate behind (and one current,
# and Lua on its newest 5.4.x), a mirror behind ghostty's, an action tag
# that moved (and an annotated tag that did not), Zig behind, npm counts,
# a thread that gained a maintainer comment, an issue's task list, a
# pull request open and merged (the Zig-move note and the comment's
# headline), zig-next's expected and real failure lines, a release channel that
# disagrees (and one that agrees through a prefixed winget directory),
# identical state → no comment, info-only change → no comment, changed
# state → the comment's text, a first run, and no request without a
# fixture.
#
# `UW_SCRIPT` names the script under test (default tools/upstream-watch.sh)
# — how a break-check points it at a broken copy. Exit 0 when every case
# passes, 1 otherwise. Needs bash and jq; no network.

set -u
cd "$(dirname "$0")/.." || exit 2
script="${UW_SCRIPT:-tools/upstream-watch.sh}"
fx=tools/upstream/fixtures
export UW_ROOT="$fx/root" UW_REPO=example-org/app
# #7 bare (a discussion, the old form), #9 an issue, #8 the pull request
# that moves the toolchain (the ZIG_MOVE_PR role).
export UW_THREADS="example-org/forum#7 issue:example-org/forum#9 pr:example-org/forum#8"
export UW_ZIG_MOVE_PR="example-org/forum#8" UW_ZIG_MOVE_VERSION=0.17
unset UW_CI_GHOSTTY_BUILD UW_CI_TERMINAL_TESTS UW_CI_RESIZE UW_CI_ZIG_NEXT UW_RUN_URL

scratch="$(mktemp -d "${TMPDIR:-/tmp}/uw-check.XXXXXX")" || exit 2
trap 'rm -f "$scratch"/*; rmdir "$scratch"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/         /' | head -8; }
has() { grep -qF -- "$2" "$1"; }

# run <name> <fixture dirs> [now] [--prev-state FILE]: report → <name>.out,
# state JSON → <name>.json, stderr → <name>.err.
run() {
    local name="$1" dirs="$2" now="${3:-2026-01-01T00:00:00Z}"
    shift 3 2> /dev/null || shift $#
    UW_FIXTURES="$dirs" UW_NOW="$now" bash "$script" --dry-run "$@" > "$scratch/$name.out" 2> "$scratch/$name.err"
    sed -n '/^----- state -----$/,/^----- decision/p' "$scratch/$name.out" | sed '1d;/^----- decision/d' > "$scratch/$name.json"
}
q() { jq -r "$2" "$scratch/$1.json" 2> /dev/null; }

echo "upstream-watch-check: $script against $fx"
run w1 "$fx/week1"
run w1again "$fx/week1" 2026-01-08T00:00:00Z
run w1info "$fx/week1-info:$fx/week1" 2026-01-08T00:00:00Z
run w2 "$fx/week2:$fx/week1" 2026-01-08T00:00:00Z --prev-state "$scratch/w1.json"
run w3 "$fx/week3:$fx/week1" 2026-01-15T00:00:00Z --prev-state "$scratch/w1.json"

# ── parsing ──
o="$scratch/w1.out"
if [ ! -s "$scratch/w1.err" ]; then ok "every request had a fixture"; else bad "requests without a fixture" "$(cat "$scratch/w1.err")"; fi
if jq -e . "$scratch/w1.json" > /dev/null 2>&1; then ok "the state is JSON"; else bad "the state is not JSON" "$(head -5 "$scratch/w1.json")"; fi

if has "$o" "- termlib (example-org/termlib): pinned aaaaaaaa (2026-01-02), 12 commits behind main" \
    && [ "$(q w1 '.pins.termlib.info.ahead')" = 12 ] && [ "$(q w1 '.pins.termlib.current')" = "$(printf 'a%.0s' {1..40})" ]; then
    ok "a pin behind: reported with its date and commit count"
else bad "a pin behind" "$(grep termlib "$o")"; fi

if ! has "$o" "steady" && [ "$(q w1 '.pins.steady')" = null ]; then
    ok "a pin current (on a non-main default branch): not reported"
else bad "a pin current" "$(grep steady "$o")"; fi

if has "$o" "- tree-sitter-alpha: 0.1.0 → 0.2.0" && [ "$(q w1 '.pins.ts_alpha.latest')" = 0.2.0 ]; then
    ok "a crate behind: current → newest stable (not the prerelease)"
else bad "a crate behind" "$(grep alpha "$o")"; fi

if ! has "$o" "tree-sitter-beta" && ! has "$o" "lua"; then
    ok "a crate current and Lua on the newest 5.4.x (5.5.0 is another series): not reported"
else bad "a current crate or Lua was reported" "$(grep -E 'beta|lua' "$o")"; fi

if has "$o" "- uilib: ghostty main uses uilib 22222222; we pin 11111111 (example-org/uilib, 4 commits apart)"; then
    ok "a ghostty mirror: the commit ghostty main pins, and its upstream from the zon comment"
else bad "a ghostty mirror" "$(grep uilib "$o")"; fi

if has "$o" "- example-org/stale-action: pinned 33333333 (v3); v3 is now 44444444" \
    && ! has "$o" "fresh-action" && ! has "$o" "annotated-action" && [ "$(q w1 '.actions | length')" = 1 ]; then
    ok "actions: a moved major tag reported once; a current one and an annotated tag not"
else bad "actions" "$(sed -n '/^## Actions/,/^## npm/p' "$o")"; fi

if has "$o" "- newest stable: 0.17.0 — minimum_zig_version 0.16.0, CI installs 0.16.0"; then
    ok "zig: newest stable against the zon and ci.yml's ZIG_VERSION (master ignored)"
else bad "zig" "$(sed -n '/^## Zig/,/^## Actions/p' "$o")"; fi

if has "$o" "- site: outdated 1 major, 1 minor, 1 patch; audit 0 critical, 0 high, 0 moderate, 1 low" \
    && [ "$(q w1 '.npm.site.major')" = 1 ] && [ "$(q w1 '.npm.site.info.patch')" = 1 ]; then
    ok "npm: outdated by major/minor/patch, audit by severity"
else bad "npm" "$(sed -n '/^## npm/,/^## Upstream/p' "$o")"; fi

if [ "$(q w1 '.channels.disagree | length')" = 1 ] \
    && has "$o" "- Homebrew: example-org/homebrew-tap/Formula/app.rb is 1.3.9, the release is 1.4.0" \
    && ! has "$o" "- winget:" && ! has "$o" "- site: mnml.sh" && ! has "$o" "- demo:"; then
    ok "a release channel that disagrees (the tap); winget's v-prefixed dir, the site and the demo agree"
else bad "release channels" "$(sed -n '/^## Release/,/^State/p' "$o")"; fi

# ── threads ──
o2="$scratch/w2.out"
if [ "$(q w2 '.threads["example-org/forum#7"].maintainer_comments')" = 1 ] \
    && has "$o2" "2 comments (1 from maintainers)" \
    && has "$o2" "**changed since last run:** comments 1 → 2; maintainer_comments 0 → 1"; then
    ok "a thread that gained a maintainer comment: counted, and called out against the last state"
else bad "a thread that gained a maintainer comment" "$(grep forum "$o2")"; fi

# ── the workflow's job results ──
UW_FIXTURES="$fx/week1" UW_CI_GHOSTTY_SHA="$(printf 'e%.0s' {1..40})" UW_CI_GHOSTTY_BUILD=success \
    UW_CI_TERMINAL_TESTS=failure UW_CI_TERMINAL_FAILED=2 UW_CI_RESIZE=fixed UW_CI_ZIG_NEXT=skipped \
    bash "$script" --dry-run --only ci > "$scratch/ci.out" 2>&1
if has "$scratch/ci.out" "- builds against ghostty main (eeeeeeee): yes" \
    && has "$scratch/ci.out" "- terminal tests: fail (2 failed)" \
    && has "$scratch/ci.out" "- resize redraw: FIXED upstream — the workaround in src/pty/common.zig can go" \
    && has "$scratch/ci.out" "- zig: no newer stable release to try"; then
    ok "the ghostty-main and zig-next results: one line each"
else bad "the job-result lines" "$(sed -n '/^## Against/,/^State/p' "$scratch/ci.out")"; fi

if has "$o" "- [example-org/forum#9](https://github.com/example-org/forum/issues/9): issue open, 2 comments, tasks 2/3 done, labels: tracking" \
    && [ "$(q w1 '.threads["example-org/forum#9"].tasks_done')" = 2 ]; then
    ok "an issue with a task list: state, comments, done/total checkboxes (an inline [ ] is not a task)"
else bad "an issue with a task list" "$(grep 'forum#9' "$o")"; fi

if has "$o" "- [example-org/forum#8](https://github.com/example-org/forum/pull/8): pull request open, 33 commits, head 88888888, mergeable: blocked" \
    && has "$o" "- ghostty's Zig 0.17 move: PR #8 open — mnml follows when it merges" \
    && [ "$(q w1 '.threads["example-org/forum#8"].state')" = open ] && [ "$(q w1 '.threads["example-org/forum#8"].head')" = null ]; then
    ok "a pull request open: its line, the Zig 0.17 note, the head sha kept out of the signal"
else bad "a pull request open" "$(grep -E 'forum#8|Zig 0.17 move' "$o")"; fi

o3="$scratch/w3.out"
if has "$o3" "pull request MERGED" && has "$o3" "- ghostty's Zig 0.17 move: PR #8 **MERGED** — mnml can move to Zig 0.17" \
    && has "$o3" "**changed since last run:** state open → merged" && has "$o3" "tasks 3/3 done"; then
    ok "a pull request merged: the report says mnml can move"
else bad "a pull request merged" "$(grep -E 'forum#|Zig 0.17 move' "$o3")"; fi

if has "$o" "- ghostty main requires Zig 0.16.0" && [ "$(q w1 '.zig.ghostty_main_minimum')" = 0.16.0 ]; then
    ok "zig: ghostty main's own minimum_zig_version"
else bad "ghostty main's minimum" "$(sed -n '/^## Zig$/,/^## Zig 0/p' "$o")"; fi

UW_FIXTURES="$fx/week1" UW_CI_GHOSTTY_BUILD=success UW_CI_TERMINAL_TESTS=success UW_CI_RESIZE=broken \
    UW_CI_ZIG_NEXT=failure UW_CI_ZIG_NEXT_VERSION=0.17.0 UW_CI_ZIG_GHOSTTY=0.16.0 \
    bash "$script" --dry-run --only ci > "$scratch/zn.out" 2>&1
UW_FIXTURES="$fx/week1" UW_CI_ZIG_NEXT=failure UW_CI_ZIG_NEXT_VERSION=0.17.0 UW_CI_ZIG_GHOSTTY=0.17.0 \
    bash "$script" --dry-run --only ci > "$scratch/zn2.out" 2>&1
if has "$scratch/zn.out" "- newest Zig 0.17.0: mnml does not build with it yet — ghostty requires 0.16.0 (PR #8)" \
    && has "$scratch/zn2.out" "- newest Zig 0.17.0: mnml does NOT build with it — and ghostty main requires 0.17.0 already"; then
    ok "zig-next: an expected failure says why; once ghostty requires the new Zig it reads as a real one"
else bad "the zig-next lines" "$(grep -h 'newest Zig' "$scratch/zn.out" "$scratch/zn2.out")"; fi

# ── the decision ──
d() { UW_ROOT="$UW_ROOT" bash "$script" --decide "$1" "$2"; }

out=$(d "$scratch/w1.json" "$scratch/w1again.json")
if [ "$out" = unchanged ]; then ok "identical state (a later run, same answers) → no comment"
else bad "identical state should be unchanged" "$out"; fi

out=$(d "$scratch/w1.json" "$scratch/w1info.json")
if [ "$out" = unchanged ] && [ "$(q w1info '.pins.termlib.info.ahead')" = 19 ]; then
    ok "only info moved (main gained 7 commits) → no comment"
else bad "an info-only change should be unchanged" "$out"; fi

out=$(d "$scratch/w1.json" "$scratch/w2.json")
want="changed
Upstream watch: 2 change(s) since the last run.
- threads.example-org/forum#7.comments: 1 → 2
- threads.example-org/forum#7.maintainer_comments: 0 → 1"
if [ "$out" = "$want" ]; then ok "changed state → 'changed' and the comment says what moved"
else bad "changed state's comment" "$out"; fi

out=$(d "$scratch/w1.json" "$scratch/w3.json")
if [ "$(head -1 <<< "$out")" = changed ] \
    && grep -qF "**ghostty's Zig 0.17 move (PR #8) MERGED — mnml can move to Zig 0.17**" <<< "$out" \
    && grep -qF -- '- threads.example-org/forum#8.state: "open" → "merged"' <<< "$out" \
    && grep -qF -- '- threads.example-org/forum#9.tasks_done: 2 → 3' <<< "$out"; then
    ok "the pull request merged → the comment leads with: mnml can move"
else bad "the merged pull request's comment" "$out"; fi

: > "$scratch/empty.json"
out=$(d "$scratch/empty.json" "$scratch/w1.json")
if [ "$(head -1 <<< "$out")" = changed ] && grep -q "First run" <<< "$out"; then ok "no stored state → a first run"
else bad "a first run" "$out"; fi

# More than three changes: three lines and a pointer.
jq '.pins.ts_alpha.latest = "0.9.0" | .zig.latest_stable = "0.18.0" | .actions = [] | .channels.disagree = []' \
    "$scratch/w1.json" > "$scratch/many.json"
out=$(d "$scratch/w1.json" "$scratch/many.json")
if [ "$(grep -c '^- ' <<< "$out")" = 4 ] && grep -q "and [0-9]* more; the issue body has the full report" <<< "$out"; then
    ok "many changes → three lines and a pointer to the issue"
else bad "many changes" "$out"; fi

echo "upstream-watch-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
