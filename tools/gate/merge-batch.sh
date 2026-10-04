#!/bin/bash
# BATCH mode: merge branches one after another, gating each on build + ReleaseSafe unit;
# the full chain (audits, Windows gate, sweep, corpus, integrations, run-sh) runs ONCE after the last.
# A red quick gate stops the queue with the offending branch already merged (fix main, requeue the rest).
# Waits on main's own index.lock, never on a machine-wide `git` process.
set -u -o pipefail
# One batch at a time: two chains share nothing now, but the harness window and the main checkout are single.
LOCKD=/tmp/mnml-batch.lock.d; if ! mkdir "$LOCKD" 2>/dev/null; then if [ -f "$LOCKD/pid" ] && kill -0 "$(cat "$LOCKD/pid")" 2>/dev/null; then echo "ANOTHER BATCH IS RUNNING (pid $(cat "$LOCKD/pid")) — refusing to start"; exit 2; else rm -rf "$LOCKD"; mkdir "$LOCKD"; fi; fi; echo $$ > "$LOCKD/pid"; trap 'rm -rf "$LOCKD"' EXIT
export CHAIN_TMP=$(mktemp -d /tmp/mnml-chain.XXXXXX)
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/../.." && pwd)"; W="$R-worktrees"
# Merge messages are written by hand per branch; logs outlive the run. Both are git-ignored.
M=$S/msgs; L=$S/logs; mkdir -p "$L"
# Zig never prunes its cache; a batch adds gigabytes. Over 40 GB, clear it — only when
# nothing is building in the main checkout (never a worktree's, never a live build's).
if [ -d "$R/.zig-cache" ]; then
  cache_gb=$(du -sg "$R/.zig-cache" 2>/dev/null | cut -f1)
  live=$(ps -Ao command | grep -E '[z]ig (build|test)' | grep -v worktrees | grep -c .)
  if [ "${cache_gb:-0}" -gt 40 ] && [ "$live" -eq 0 ]; then
    echo "== cache guard: $R/.zig-cache is ${cache_gb} GB, no live build — clearing"; rm -rf "$R/.zig-cache"
  elif [ "${cache_gb:-0}" -gt 40 ]; then
    echo "== cache guard: ${cache_gb} GB but a build is live — leaving it"
  fi
fi
waitlock() { local n=0; while [ -e $R/.git/index.lock ]; do sleep 5; n=$((n+1)); [ $n -gt 120 ] && { echo "LOCK STUCK"; return 1; }; done; sleep 2; [ -e $R/.git/index.lock ] && return 1; return 0; }
for b in "$@"; do
  echo "=== $b $(date '+%H:%M')"
  waitlock || exit 1
  cd $W/$b || { echo "no worktree $b"; exit 1; }
  git rebase main 2>&1 | grep -E "CONFLICT|Successfully|up to date" | head -3
  # Doc rows and the command-id pins collide on every track: docs/ keep-both, specs.zig keep-both + pin re-sum; anything else stops the queue.
  $S/resolve-loop.sh | grep -E "auto-resolved|pins=|STOP"
  U=$(git diff --name-only --diff-filter=U)
  if [ -n "$U" ]; then echo "REBASE CONFLICT in $b: $U"; for f in $U; do echo "== $f"; awk '/<<<<<<< /,/>>>>>>> /' $f | cut -c1-200 | head -30; done; exit 1; fi
  cd $R; waitlock || exit 1
  BEFORE=$(git rev-parse HEAD); git checkout -q -- docs/commands.md 2>/dev/null
  git merge --no-ff $b -F $M/merge-msg-$b.txt >/dev/null 2>&1
  AFTER=$(git rev-parse HEAD)
  [ "$BEFORE" != "$AFTER" ] || { echo "MERGE DID NOT LAND: $b"; git merge --abort 2>/dev/null; exit 1; }
  U=$(git diff --name-only --diff-filter=U); [ -z "$U" ] || { echo "MERGE CONFLICT: $U"; exit 1; }
  echo "merged: $(git log -1 --oneline)"
  git worktree remove --force $W/$b && git branch -d $b | tail -1
  # the Settings script pins no total since settings-followups; no re-pin
  zig build docs >/dev/null 2>&1; if ! git diff --quiet -- docs/commands.md; then git commit -q -m "docs(commands): regenerate the command table

Co-Authored-By: Claude <noreply@anthropic.com>" -- docs/commands.md && echo docs-committed; fi
  echo "== quick gate $b"; (cd $R && zig build -Dpartial=false > $L/quick-$b.log 2>&1); E=$?; echo "build exit $E"
  [ $E -eq 0 ] || { grep -E "error:" $L/quick-$b.log | head -5; echo "QUICK GATE RED after $b (build) — queue stopped; fix main, then requeue the rest"; exit 1; }
  (cd $R && zig build unit -Doptimize=ReleaseSafe --summary all > $L/quick-unit-$b.log 2>&1); E=$?; echo "unit exit $E"; grep -E "tests passed|failed:" $L/quick-unit-$b.log | head -3
  [ $E -eq 0 ] || { echo "QUICK GATE RED after $b (unit) — queue stopped; fix main, then requeue the rest"; exit 1; }
done
LAST=${@: -1}
echo "== full chain after $LAST $(date '+%H:%M')"; cd $R; $S/chain-scrub.sh > $L/chain-$LAST.log 2>&1; CE=$?
grep -E "audit:|passed|FAIL|failed|== DONE" $L/chain-$LAST.log | grep -v "failed command" | tail -12
if [ $CE -ne 0 ] || grep -qE "UNIT FAILED|UNIT DEBUG FAILED|INTEGRATION SUITE FAILED|WINDOWS BUILD FAILED|CORPUS FAILED|PTY MOUSE FAILED|RUN-SH FAILED|EXTRA ROOTS FAILED" $L/chain-$LAST.log || ! grep -qE "^[0-9]+/[0-9]+ passed" $L/chain-$LAST.log; then echo "CHAIN RED after batch ending $LAST — fix main"; exit 1; fi
T=$(date +%Y-%m-%d-%H%M); git bundle create ~/Backups/mnml-zig/mnml-zig-$T-clean.bundle --all 2>&1 | tail -1; echo "BUNDLED $LAST"
# Local main == origin/main since 2026-09-26; a green chain pushes (CI on the public repo is free and runs the Windows/Linux jobs the chain cannot).
(cd $R && git fetch -q origin && [ "$(git rev-list --count main..origin/main)" = 0 ]) || { echo "ORIGIN AHEAD of local main (a GitHub-side merge?) — NOT PUSHING: rebase main onto origin/main and rerun fix-main.sh"; exit 1; }
(cd $R && git push -q origin main 2>&1 | tail -1) && echo "PUSHED $(cd $R && git rev-parse --short main)" || echo "PUSH FAILED"
# The curated real-screen tour after every green chain (user: "you should be doing this automatically"): one window, ~2 min; the verdict line lands here, the flagged shots in .verify/tour.
echo "== tour after $LAST"; (cd $R && tools/tour.sh run > $L/tour-$LAST.log 2>&1); TE=$?; grep -E "ok, .* changed|CHANGED|flagged:|toast lingered|stale" $L/tour-$LAST.log | head -12; [ $TE -eq 0 ] && echo "TOUR OK" || echo "TOUR CHANGED — read $L/tour-$LAST.log and tools/tour-review.md"; if grep -q "permission is missing" $L/tour-$LAST.log; then echo "TOUR NOT RUN — mnml-drive lacks a macOS permission for this process (run zig-out/bin/mnml-drive doctor; see tour-$LAST.log)"; elif grep -q "DriveError" $L/tour-$LAST.log; then echo "TOUR NOT RUN — mnml-drive could not open or drive its window (screen locked/asleep?): $(grep -o "mnml-drive [a-z]*: [^.]*" $L/tour-$LAST.log | head -1)"; fi
echo "QUEUE DONE"
