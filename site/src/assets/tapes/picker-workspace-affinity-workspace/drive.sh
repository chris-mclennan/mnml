#!/usr/bin/env bash
# Drives mnml via IPC for the picker-workspace-affinity tape.
#
# Demonstrates the 2026-06-29 Ctrl+P workspace-affinity polish:
# items from the CURRENT workspace get priority 2, recents from OTHER
# workspaces get priority 1, so a local `src/lib.rs` always ranks above
# a cross-workspace recent `lib.rs` of the same name (the prior order
# put the shorter cross-workspace label on top by fuzzy score).
#
# Beats:
#   1. picker.files                    (opens fuzzy picker over workspace tree
#                                       + recent_files; the sibling-recent
#                                       lib.rs is seeded into session.json
#                                       before launch so it shows under
#                                       the local src/lib.rs)
#   2. type "lib"                      (filter — both lib.rs entries match;
#                                       the LOCAL `src/lib.rs` ranks #1)
#   3. key enter                       (open the highlighted file —
#                                       LOCAL src/lib.rs, not the sibling)

set -u
WS="$1"
SIBLING="$2"
CMD="$WS/.mnml/ipc/command"

# Seed the workspace's session.json with the sibling lib.rs as a
# cross-workspace recent BEFORE mnml starts. picker.files reads
# recent_files at startup; doing the seed in the .tape's Hide block
# tripped VHS's parser on the JSON escape sequences, so we do it
# here just before waiting for the IPC.
mkdir -p "$WS/.mnml"
printf '{"workspace":"%s","open":[],"recent_files":["%s/src/lib.rs"]}\n' "$WS" "$SIBLING" > "$WS/.mnml/session.json"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.2

  # 1) open the file picker (Ctrl+P)
  echo '{"cmd":"run-command","id":"picker.files"}' >> "$CMD"
  sleep 1.8

  # 2) type the filter — letter by letter so the picker can re-rank
  echo '{"cmd":"type","text":"l"}' >> "$CMD"
  sleep 0.4
  echo '{"cmd":"type","text":"i"}' >> "$CMD"
  sleep 0.4
  echo '{"cmd":"type","text":"b"}' >> "$CMD"
  # Hold so the priority sort is visible: src/lib.rs (LOCAL, priority 2)
  # is the highlighted top row even though a sibling lib.rs is seeded
  # into recent_files as a priority-1 entry.
  sleep 3.0

  # 3) commit — opens the highlighted row.
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 1.5

  # Some terminals + the welcome-overlay state in the GIF run path
  # occasionally swallow the picker's Enter before picker_accept
  # commits the open. Defensive: explicitly open the local file
  # afterwards so the GIF always ends on the editor showing it.
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"
  sleep 1.5
} >/dev/null 2>&1
