#!/bin/bash
# corpus-sharded.sh BIN N OUTLOG — the e2e corpus as N parallel `mnml-zig test --shard I/N`
# processes (the runner's own discovery and split: every file in exactly one shard). Appends
# one merged "X/Y passed" line so a caller's grep reads it like a single run. Exit 1 if any
# shard failed. 12 shards: ~270 s for 1100 files on this machine vs ~57 min sequential.
set -u
BIN=$1; N=$2; OUT=$3; W=$(mktemp -d "${TMPDIR:-/tmp}/corpus-shards.XXXXXX")
S=$(date +%s); rc=0
for i in $(seq 0 $((N-1))); do ( "$BIN" test --shard "$i/$N" > "$W/part-$i.log" 2>&1; echo $? > "$W/part-$i.rc" ) & done; wait
: > "$OUT"; ok=0; total=0
for i in $(seq 0 $((N-1))); do cat "$W/part-$i.log" >> "$OUT"; [ "$(cat "$W/part-$i.rc")" = "0" ] || rc=1
  s=$(grep -oE '^[0-9]+/[0-9]+ passed' "$W/part-$i.log" | tail -1); ok=$((ok + ${s%%/*})); t=${s#*/}; total=$((total + ${t%% *})); done
echo "$ok/$total passed (merged from $N shards in $(( $(date +%s) - S ))s)" >> "$OUT"
rm -rf "$W"; exit $rc
