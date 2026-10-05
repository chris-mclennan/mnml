#!/bin/bash
CHAIN_TMP=${CHAIN_TMP:-$(mktemp -d /tmp/mnml-chain.XXXXXX)}; export CHAIN_TMP
S="$(cd "$(dirname "$0")" && pwd)"
cd "$S/../.." || exit 1
echo "pins: $(grep -ho 'command_count[^;]*' src/commands/specs.zig src/core/command.zig | tr '\n' ' ')"
for _p in $(pgrep -f "mnml-fake-" 2>/dev/null); do [ "$(ps -o ppid= -p $_p 2>/dev/null | tr -d " ")" = "1" ] && kill $_p 2>/dev/null; done; echo "$(date +%H:%M:%S) == work-data-audit"; tools/work-data-audit.sh | tail -1; tools/gate/check.sh | tail -1
echo "$(date +%H:%M:%S) == fmt"; zig fmt --check build.zig build.zig.zon src themes tools integrations sdk && echo fmt-ok
echo "$(date +%H:%M:%S) == arena-audit"; zig build arena-audit 2>&1 | tail -2
echo "$(date +%H:%M:%S) == partial=false"; zig build -Dpartial=false >/dev/null 2>&1; echo "partial exit $?"
echo "$(date +%H:%M:%S) == heavy phase (unit releasesafe + unit debug + gate-targets 2-wide)"; $S/heavy-phase.sh
echo "$(date +%H:%M:%S) == glyph-audit"; zig build glyph-audit 2>&1 | tail -1
echo "$(date +%H:%M:%S) == build"; zig build -Ddrive -Doptimize=ReleaseSafe && echo built
echo "$(date +%H:%M:%S) == sweep"; ./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60 2>&1 | tail -1
echo "$(date +%H:%M:%S) == corpus"; $S/corpus-sharded.sh ./zig-out/bin/mnml-zig 12 $CHAIN_TMP/mnml-zig-corpus.log; grep -E '^\s*FAIL|FLAKY|passed|took' $CHAIN_TMP/mnml-zig-corpus.log; C=$(grep -oE '^[0-9]+/[0-9]+ passed' $CHAIN_TMP/mnml-zig-corpus.log | tail -1); [ -n "$C" ] && [ "${C%%/*}" = "$(echo $C | sed 's#^[0-9]*/\([0-9]*\) passed#\1#')" ] || { echo "CORPUS FAILED ($C)"; exit 1; }
echo "$(date +%H:%M:%S) == pty-mouse"; zig build -Doptimize=ReleaseSafe >/dev/null 2>&1 || true; python3 tools/pty-mouse-check.py > $CHAIN_TMP/mnml-zig-pty-mouse.log 2>&1; P=$?; tail -1 $CHAIN_TMP/mnml-zig-pty-mouse.log; [ $P -eq 0 ] || { echo "PTY MOUSE FAILED"; exit 1; }
# Extra integration roots (the private repo on this machine): built and tested against the SDK as it is now, so an SDK change that breaks a private pane goes red today. Generic script; the root list lives in tools/gate/extra-roots.local (git-ignored) or $MNML_EXTRA_INTEGRATION_ROOTS, never in the repo.
if [ -x tools/check-integration-roots.sh ]; then echo "$(date +%H:%M:%S) == extra-integration-roots"; MNML_EXTRA_INTEGRATION_ROOTS="$(cat "$S/extra-roots.local" 2>/dev/null || printf %s "${MNML_EXTRA_INTEGRATION_ROOTS:-}")" MNML_OPEN_URL=none tools/check-integration-roots.sh 2>&1 | tail -6; [ ${PIPESTATUS[0]} -eq 0 ] || echo "EXTRA ROOTS FAILED"; fi
echo "$(date +%H:%M:%S) == bitbucket-integration"; (cd integrations/bitbucket && zig build test --summary all > $CHAIN_TMP/bb-suite.log 2>&1; rc=$?; grep -E "pass|fail" $CHAIN_TMP/bb-suite.log | tail -2; [ $rc -eq 0 ] || { echo "INTEGRATION SUITE FAILED: bitbucket"; grep -E "error:" $CHAIN_TMP/bb-suite.log | head -3; }); echo "$(date +%H:%M:%S) == jira-integration"; (cd integrations/jira && zig build test --summary all > $CHAIN_TMP/jira-suite.log 2>&1; rc=$?; grep -E "pass|fail" $CHAIN_TMP/jira-suite.log | tail -2; [ $rc -eq 0 ] || { echo "INTEGRATION SUITE FAILED: jira"; grep -E "error:" $CHAIN_TMP/jira-suite.log | head -3; }); echo "$(date +%H:%M:%S) == run-sh-check"; tools/run-sh-check.sh > $CHAIN_TMP/mnml-zig-run-sh-check.log 2>&1; R=$?; tail -1 $CHAIN_TMP/mnml-zig-run-sh-check.log; [ $R -eq 0 ] || { echo "RUN-SH FAILED"; grep -E "^\s*FAIL" $CHAIN_TMP/mnml-zig-run-sh-check.log | head -5; exit 1; }
echo "$(date +%H:%M:%S) == wt-check"; tools/wt-check.sh > $CHAIN_TMP/mnml-zig-wt-check.log 2>&1; R=$?; tail -1 $CHAIN_TMP/mnml-zig-wt-check.log; [ $R -eq 0 ] || { echo "WT-CHECK FAILED"; grep -E "^\s*FAIL" $CHAIN_TMP/mnml-zig-wt-check.log | head -5; exit 1; }
echo "$(date +%H:%M:%S) == docs"; zig build docs >/dev/null 2>&1; git checkout -- docs/commands.md; git status --short | head -3
echo "$(date +%H:%M:%S) == DONE"
