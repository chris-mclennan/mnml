#!/bin/bash
# Continue a stopped rebase (cwd = worktree): docs/ + CHANGELOG.md conflicts keep-both, specs.zig conflicts keep-both + pin re-sum; anything else stops.
S=$(cd "$(dirname "$0")" && pwd)
for _try in $(seq 1 30); do
  U=$(git diff --name-only --diff-filter=U); [ -z "$U" ] && { [ -d "$(git rev-parse --git-dir)/rebase-merge" ] && { GIT_EDITOR=true git rebase --continue 2>&1 | grep -E "Successfully|Could not" | head -1; continue; } || { echo "REBASE CLEAN"; exit 0; }; }
  OTHER=$(echo "$U" | grep -vE "^docs/|^CHANGELOG.md$|^src/commands/specs.zig$|^src/core/command.zig$|^tests/e2e/settings_wheel.test$"); [ -n "$OTHER" ] && { echo "STOP: $OTHER"; exit 1; }
  for f in $U; do if [ "$f" = "tests/e2e/settings_wheel.test" ]; then python3 $S/fixwheel.py; else python3 $S/keepboth.py "$f"; fi; done
  echo "$U" | grep -qE "specs.zig|command.zig" && { $S/fixpins.sh; git add src/commands/specs.zig src/core/command.zig; }
  git add $U; echo "auto-resolved: $(echo $U | tr '\n' ' ')"
  GIT_EDITOR=true git rebase --continue 2>&1 | grep -E "Successfully|Could not" | head -1
done
[ -z "$(git diff --name-only --diff-filter=U)" ] && ! [ -d "$(git rev-parse --git-dir)/rebase-merge" ] && echo "REBASE CLEAN" || { echo "STOP: still dirty"; exit 1; }
