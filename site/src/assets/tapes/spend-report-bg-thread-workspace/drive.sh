#!/usr/bin/env bash
# Drives mnml via IPC for the spend-report-bg-thread tape.
#
# Demonstrates the 2026-06-29 "spend report is computed on a background
# thread" polish. Beats:
#   1. open src/lib.rs  (gives the screen visible content under the report)
#   2. ai.spend_today   (opens SpendReport pane; title bar shows " · computing…"
#                        while the loading worker churns; toast says
#                        "computing spend… (background)")
#   3. wait ~2s         (the worker drains; title bar drops the chip;
#                        body fills with the table; a second toast fires:
#                        "today: N sessions · $X.XXXX")
#
# Why IPC: `ai.spend_today` is palette-driven; in standard mode there's
# no `:` cmdline opener, and we want the toast timing to be deterministic.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.0

  # 1) open lib.rs so the editor body has visible content
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"
  sleep 2.0

  # 2) fire :ai.spend_today
  echo '{"cmd":"run-command","id":"ai.spend_today"}' >> "$CMD"
  # SpendReport pane opens immediately; title shows " · computing…",
  # toast says "computing spend… (background)". Worker fills in
  # asynchronously.
  sleep 1.0
} >/dev/null 2>&1
