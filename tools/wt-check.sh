#!/usr/bin/env bash
# tools/wt-check.sh — tools/wt.sh and the gate's worktree lookup on a
# throwaway repository: <tmp>/proj/repo, so the root under test is
# <tmp>/proj/.worktrees/repo and the older location <tmp>/proj/repo-worktrees.
# <tmp> is a fresh `mktemp -d` under this checkout's git-ignored .verify/
# (never /tmp); git runs with no global or system config.
#
# What it proves, in order:
#   1. `root` / `path` print <parent>/.worktrees/<repo>[/<name>], from the
#      main checkout and from inside a worktree alike.
#   2. `add` makes <root>/<name> on a new branch <name>; a bad name (a
#      capital, a slash, `..`, a leading dot, 101 characters), an existing
#      branch and an existing directory are refused, nothing made.
#   3. `gc` reports a fresh worktree not safe, naming "modified within
#      24 h"; the same tree backdated, clean and merged reads safe; a
#      tree at the old location is listed as predating the convention.
#   4. `remove` refuses a dirty tree, a locked tree, a tree a process
#      sits in (a `sleep` with its cwd there — killed by pid after) and an
#      unmerged branch without --abandon; with --abandon the tree goes and
#      the branch stays; a merged one goes with `branch -d`.
#   5. `move` relocates an old-location worktree (dirty is fine) with
#      `git worktree move`, and refuses a locked one.
#   6. `wt_of` — what tools/gate/merge-batch.sh uses — finds a branch's
#      worktree at the new root and at the old location, and nothing for
#      a branch with none; merge-batch.sh really calls it.
#
#   tools/wt-check.sh            (a few seconds; git, and lsof or /proc)
#
# WT_TOOLS=DIR runs the wt.sh / wt-lib.sh in DIR instead (a break-check
# copy). The throwaway directory is left in .verify/ and printed: this
# script never deletes recursively; its worktrees are removed through
# wt.sh and git as part of the checks.
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=${WT_TOOLS:-$ROOT/tools}
WT="$T/wt.sh"
[ -x "$WT" ] || { echo "wt-check: no $WT" >&2; exit 64; }

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR WT_MAIN_BRANCH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=wt-check GIT_AUTHOR_EMAIL=wt-check@example.invalid
export GIT_COMMITTER_NAME=wt-check GIT_COMMITTER_EMAIL=wt-check@example.invalid

mkdir -p "$ROOT/.verify" || exit 70
TMP=$(mktemp -d "$ROOT/.verify/wt-check.XXXXXX") || { echo "wt-check: mktemp failed" >&2; exit 70; }
TMP=$(cd "$TMP" && pwd -P)
P=$TMP/proj; REPO=$P/repo; WROOT=$P/.worktrees/repo; OLDR=$P/repo-worktrees
mkdir -p "$REPO"
git -C "$REPO" init -q -b main && echo a > "$REPO/a" && git -C "$REPO" add a && git -C "$REPO" commit -qm a || { echo "wt-check: could not make the repo" >&2; exit 70; }

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1" ; [ -n "${2:-}" ] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

SPID=
cleanup() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; }
trap cleanup EXIT

# wt.sh run from inside the throwaway repo (or $W_IN when set).
wt() { (cd "${W_IN:-$REPO}" && "$WT" "$@" 2>&1); }
has_branch() { git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"; }

echo "wt-check: $WT on $REPO"

# ── 1. root / path ─────────────────────────────────────────────────────
out=$(wt root)
check "root: <parent>/.worktrees/<repo>" '[ "$out" = "$WROOT" ]' "got: $out"
out=$(wt path feat)
check "path: <root>/<name>" '[ "$out" = "$WROOT/feat" ]' "got: $out"

# ── 2. add ─────────────────────────────────────────────────────────────
out=$(wt add feat); rc=$?
check "add: prints <root>/<name>, exit 0" '[ $rc -eq 0 ] && [ "$out" = "$WROOT/feat" ]' "rc=$rc: $out"
check "add: the tree exists, on branch <name>" '[ "$(git -C "$WROOT/feat" rev-parse --abbrev-ref HEAD 2>/dev/null)" = feat ]'
out=$(W_IN=$WROOT/feat wt root)
check "root: the same from inside a worktree" '[ "$out" = "$WROOT" ]' "got: $out"
for n in Bad a/b a..b .hidden "$(printf 'a%.0s' $(seq 101))"; do
  out=$(wt add "$n"); rc=$?
  check "add: refuses the bad name '${n:0:12}'" '[ $rc -ne 0 ] && echo "$out" | grep -q "bad name" && ! has_branch "$n"' "rc=$rc: $out"
done
out=$(wt add "$(printf 'a%.0s' $(seq 100))"); rc=$?
check "add: 100 characters is allowed" '[ $rc -eq 0 ]' "rc=$rc: $out"
out=$(wt add feat); rc=$?
check "add: refuses an existing branch" '[ $rc -ne 0 ] && echo "$out" | grep -q "branch feat exists"' "rc=$rc: $out"
mkdir -p "$WROOT/taken"
out=$(wt add taken); rc=$?
check "add: refuses an existing directory, makes no branch" '[ $rc -ne 0 ] && echo "$out" | grep -q "exists" && ! has_branch taken' "rc=$rc: $out"
rmdir "$WROOT/taken"

# ── 3. gc ──────────────────────────────────────────────────────────────
out=$(wt gc); rc=$?
check "gc: a fresh worktree is not safe — modified within 24 h" 'echo "$out" | grep -A1 "^not safe  feat " | grep -q "modified within 24 h"' "$out"
check "gc: says it removes nothing; the tree is still there" 'echo "$out" | head -1 | grep -q "report only" && [ -d "$WROOT/feat" ]' "$out"
find "$WROOT/feat" -exec touch -t 202001010000 {} +
out=$(wt gc)
check "gc: the same tree backdated, clean and merged is safe" 'echo "$out" | grep -q "^safe      feat "' "$out"

# ── 4. remove ──────────────────────────────────────────────────────────
echo x > "$WROOT/feat/scratch"
out=$(wt remove feat); rc=$?
check "remove: refuses a dirty tree" '[ $rc -ne 0 ] && echo "$out" | grep -q "dirty" && [ -d "$WROOT/feat" ]' "rc=$rc: $out"
rm "$WROOT/feat/scratch"

git -C "$REPO" worktree lock --reason check "$WROOT/feat"
out=$(wt remove feat); rc=$?
check "remove: refuses a locked tree" '[ $rc -ne 0 ] && echo "$out" | grep -q "locked" && [ -d "$WROOT/feat" ]' "rc=$rc: $out"
git -C "$REPO" worktree unlock "$WROOT/feat"

(cd "$WROOT/feat" && exec sleep 300) & SPID=$!
sleep 0.3
out=$(wt remove feat); rc=$?
check "remove: refuses while a process sits inside, naming its pid" '[ $rc -ne 0 ] && echo "$out" | grep -q "a process inside it: .*pid $SPID " && [ -d "$WROOT/feat" ]' "rc=$rc: $out"
out=$(wt gc)
check "gc: names the process inside" 'echo "$out" | grep -A1 "^[a-z ]* feat " | grep -q "a process inside it"' "$out"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SPID=

echo b > "$WROOT/feat/b" && git -C "$WROOT/feat" add b && git -C "$WROOT/feat" commit -qm b
out=$(wt remove feat); rc=$?
check "remove: refuses an unmerged branch without --abandon" '[ $rc -ne 0 ] && echo "$out" | grep -q "1 commit(s) not in main" && [ -d "$WROOT/feat" ]' "rc=$rc: $out"
out=$(wt remove feat --abandon); rc=$?
check "remove --abandon: the tree goes, the branch stays, and it says so" '[ $rc -eq 0 ] && [ ! -e "$WROOT/feat" ] && has_branch feat && echo "$out" | grep -q "branch feat left in place"' "rc=$rc: $out"

wt add done >/dev/null
out=$(wt remove done); rc=$?
check "remove: a clean merged tree goes, its branch deleted (-d)" '[ $rc -eq 0 ] && [ ! -e "$WROOT/done" ] && ! has_branch done && echo "$out" | grep -q "Deleted branch done"' "rc=$rc: $out"
out=$(wt remove main); rc=$?
check "remove: refuses the main checkout's branch" '[ $rc -ne 0 ] && echo "$out" | grep -q "main checkout"' "rc=$rc: $out"
out=$(wt remove nope); rc=$?
check "remove: no worktree for the branch is a clear stop" '[ $rc -ne 0 ] && echo "$out" | grep -q "no worktree has branch nope"' "rc=$rc: $out"

# ── 5. move (and gc on the old location) ───────────────────────────────
git -C "$REPO" worktree add -q -b old "$OLDR/old" main
git -C "$REPO" worktree add -q -b legacy "$OLDR/legacy" main
echo wip > "$OLDR/old/wip"
out=$(wt gc)
check "gc: an old-location tree predates the convention, with the move to run" 'echo "$out" | grep -q "old location: repo-worktrees/ predates the convention — tools/wt.sh move old"' "$out"

# ── 6. the gate's lookup, at both locations ────────────────────────────
out=$( . "$T/wt-lib.sh"; wt_of "$REPO" legacy )
check "wt_of: finds a branch at the old location" '[ "$out" = "$OLDR/legacy" ]' "got: $out"
out=$( . "$T/wt-lib.sh"; wt_of "$REPO" nope )
check "wt_of: nothing for a branch with no worktree" '[ -z "$out" ]' "got: $out"
check "merge-batch.sh resolves each branch with wt_of and assumes no sibling folder" 'grep -q "WT=\$(wt_of \"\$R\" \"\$b\")" "$ROOT/tools/gate/merge-batch.sh" && ! grep -q -- "-worktrees\"" "$ROOT/tools/gate/merge-batch.sh" "$ROOT/tools/gate/fix-main.sh"'

git -C "$REPO" worktree lock "$OLDR/legacy"
out=$(wt move legacy); rc=$?
check "move: refuses a locked tree" '[ $rc -ne 0 ] && echo "$out" | grep -q "locked" && [ -d "$OLDR/legacy" ]' "rc=$rc: $out"
git -C "$REPO" worktree unlock "$OLDR/legacy"

out=$(wt move old); rc=$?
check "move: an old-location tree lands at <root>/<name>, dirty files with it" '[ $rc -eq 0 ] && [ "$out" = "$WROOT/old" ] && [ ! -e "$OLDR/old" ] && [ "$(cat "$WROOT/old/wip" 2>/dev/null)" = wip ]' "rc=$rc: $out"
out=$( . "$T/wt-lib.sh"; wt_of "$REPO" old )
check "wt_of: finds the moved branch at the new root" '[ "$out" = "$WROOT/old" ]' "got: $out"
out=$(wt move old); rc=$?
check "move: refuses a tree already at the root" '[ $rc -ne 0 ] && echo "$out" | grep -q "already at the root"' "rc=$rc: $out"

echo "wt-check: throwaway left at $TMP"
echo "wt-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
