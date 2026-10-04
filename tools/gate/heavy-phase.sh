#!/bin/bash
# heavy-phase.sh — the chain's three heavy, independent steps at once (user-approved
# 2026-09-29): the ReleaseSafe unit suite, the Debug unit suite, and the five cross-target
# gate builds two at a time. Each writes the log the serial chain wrote and prints the same
# verdict lines, so merge-batch's red-line grep is unchanged. ~12 GB per unit compile and
# ~10 GB per cross compile: 2+2 fits a 64 GB machine; never run while an agent is building.
set -u
CHAIN_TMP=${CHAIN_TMP:-$(mktemp -d /tmp/mnml-chain.XXXXXX)}
T0=$(date +%s)
rm -f $CHAIN_TMP/mnml-zig-targets-gate.failed $CHAIN_TMP/chain-unit.rc $CHAIN_TMP/chain-unit-debug.rc $CHAIN_TMP/chain-targets.rc
( zig build test -Doptimize=ReleaseSafe -Dtest-trace > $CHAIN_TMP/chain-unit.log 2>&1; echo $? > $CHAIN_TMP/chain-unit.rc ) &
( tools/debug-suite-check.sh > $CHAIN_TMP/mnml-zig-unit-debug.log 2>&1; echo $? > $CHAIN_TMP/chain-unit-debug.rc ) &
( gate_one() { zig build gate-build -Dtarget="$1" -Doptimize=ReleaseSafe --summary failures --prefix "zig-out/gate-targets/$1" > "$CHAIN_TMP/mnml-zig-targets-gate.$1.log" 2>&1 || { echo "FAILED $1" >> $CHAIN_TMP/mnml-zig-targets-gate.failed; return 1; }; }
  lane() { local r=0; for t in "$@"; do gate_one "$t" || r=1; done; return $r; }
  lane aarch64-macos x86_64-linux-gnu x86_64-windows-gnu & a=$!
  lane x86_64-macos aarch64-linux-gnu & b=$!
  wait $a; ra=$?; wait $b; rb=$?; [ $ra -eq 0 ] && [ $rb -eq 0 ]; echo $? > $CHAIN_TMP/chain-targets.rc ) &
wait
echo "$(date +%H:%M:%S) == heavy phase done in $(( $(date +%s) - T0 ))s"
rc=$(cat $CHAIN_TMP/chain-unit.rc); grep -E "FAIL|passed;|failed:" $CHAIN_TMP/chain-unit.log | tail -6; [ "$rc" -eq 0 ] || { echo "UNIT FAILED (exit $rc)"; grep -E "error:|FAIL" $CHAIN_TMP/chain-unit.log | grep -v "following build" | head -6; }
D=$(cat $CHAIN_TMP/chain-unit-debug.rc); tail -1 $CHAIN_TMP/mnml-zig-unit-debug.log; [ "$D" -eq 0 ] || { echo "UNIT DEBUG FAILED"; grep -E "error:|failed:" $CHAIN_TMP/mnml-zig-unit-debug.log | head -5; }
W=$(cat $CHAIN_TMP/chain-targets.rc); cat $CHAIN_TMP/mnml-zig-targets-gate.*.log > $CHAIN_TMP/mnml-zig-targets-gate.log 2>/dev/null; echo "targets exit $W"; [ "$W" -eq 0 ] || { echo "WINDOWS BUILD FAILED (gate-targets)"; cat $CHAIN_TMP/mnml-zig-targets-gate.failed 2>/dev/null; grep -E "error:" $CHAIN_TMP/mnml-zig-targets-gate.log | head -8; }
