#!/usr/bin/env bash
# Runs inside the container. Copies the read-only repo mount into a
# container-local tree (so the host's .zig-cache / zig-out never take part)
# and runs one phase of the gate.
set -uo pipefail

PHASE=${1:-all}
shift || true

SRC=/repo
WORK=/work

sync_tree() {
  # zig-out and the two caches are host artifacts built for another OS;
  # .git is a worktree pointer the container cannot follow.
  rsync -a --delete \
    --exclude='.zig-cache/' --exclude='zig-out/' --exclude='zig-pkg/' \
    --exclude='.git' --exclude='.git/' --exclude='.DS_Store' \
    "$SRC"/ "$WORK"/
  # build.zig stamps --version from `git rev-parse`, and a few .test files
  # want a repository underfoot. One commit is enough for both.
  if [ ! -d "$WORK/.git" ]; then
    git -C "$WORK" init -q
    git -C "$WORK" config user.email gate@localhost
    git -C "$WORK" config user.name "linux gate"
  fi
  git -C "$WORK" add -A >/dev/null 2>&1
  git -C "$WORK" commit -q -m "linux gate snapshot" >/dev/null 2>&1 || true
}

hr() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

rc_all=0
step() {
  local name=$1; shift
  hr "$name"
  echo "+ $*"
  local t0 rc
  t0=$(date +%s)
  "$@"
  rc=$?
  echo "[exit $rc, $(( $(date +%s) - t0 ))s] $name"
  [ $rc -eq 0 ] || rc_all=$rc
  return $rc
}

sync_tree
cd "$WORK"

case "$PHASE" in
  shell) exec bash -l ;;
  raw)   exec "$@" ;;
esac

if [ "$PHASE" = build ] || [ "$PHASE" = all ]; then
  step "zig build" zig build --summary failures
  step "zig build -Dpartial=false" zig build -Dpartial=false --summary failures
  step "zig build glyph-audit" zig build glyph-audit
  # `arena-audit` landed on main after this branch forked; run it when the
  # tree being tested has it rather than failing on an unknown step.
  if zig build --help 2>/dev/null | grep -q '^ *arena-audit'; then
    step "zig build arena-audit" zig build arena-audit
  else
    hr "zig build arena-audit"; echo "[skipped — no such step in this tree]"
  fi
  # `chrome-audit` likewise: chrome a component owns, drawn by hand.
  if zig build --help 2>/dev/null | grep -q '^ *chrome-audit'; then
    step "zig build chrome-audit" zig build chrome-audit
  else
    hr "zig build chrome-audit"; echo "[skipped — no such step in this tree]"
  fi
  step "zig build -Doptimize=ReleaseSafe" zig build -Doptimize=ReleaseSafe --summary failures
fi

if [ "$PHASE" = unit ] || [ "$PHASE" = all ]; then
  step "zig build test -Doptimize=ReleaseSafe" zig build test -Doptimize=ReleaseSafe --summary failures
fi

# The gate and the corpus run on the ReleaseSafe binary — the one that
# ships, and the one docs/CONTRIBUTING.md's gate names. A Debug binary is
# slow enough that the Lua budget (20 ms an entry) trips on a script the
# example set ships, which looks like a corpus failure and is not one.
if [ "$PHASE" = gate ] || [ "$PHASE" = corpus ]; then
  step "zig build -Doptimize=ReleaseSafe (the binary the gate runs on)" \
    zig build -Doptimize=ReleaseSafe --summary failures
fi

if [ "$PHASE" = gate ] || [ "$PHASE" = all ]; then
  MNML_E2E_ALLOW_SHELL=1 step "gate --sizes 80x24,120x40,200x60" \
    ./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60
fi

if [ "$PHASE" = corpus ] || [ "$PHASE" = all ]; then
  hr "the full corpus"
  echo "+ MNML_E2E_ALLOW_SHELL=1 ./zig-out/bin/mnml-zig test"
  t0=$(date +%s)
  MNML_E2E_ALLOW_SHELL=1 ./zig-out/bin/mnml-zig test
  rc=$?
  echo "[exit $rc, $(( $(date +%s) - t0 ))s] the full corpus"
  [ $rc -eq 0 ] || rc_all=$rc
fi

if [ "$PHASE" = mouse ]; then
  step "pty-mouse-check" python3 tools/pty-mouse-check.py
fi

if [ "$PHASE" = fmt ]; then
  step "zig fmt --check" zig fmt --check build.zig build.zig.zon src themes tools integrations sdk
fi

exit $rc_all
