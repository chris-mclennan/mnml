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
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.2

  # 1) open the file picker (Ctrl+P)
  echo '{"cmd":"run-command","id":"picker.files"}' >> "$CMD"
  sleep 1.5

  # 2) type the filter
  echo '{"cmd":"type","text":"lib"}' >> "$CMD"
  sleep 2.0

  # 3) commit — opens whichever item is highlighted (priority sort puts
  #    the LOCAL src/lib.rs first)
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 1.5
} >/dev/null 2>&1
