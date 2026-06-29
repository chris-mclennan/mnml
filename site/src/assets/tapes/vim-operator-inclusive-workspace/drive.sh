#!/usr/bin/env bash
# Drives mnml via IPC for the vim-operator-inclusive tape.
#
# Demonstrates the 2026-06-29 vim operator fix:
#   :help cw  says  cw is identical to ce (and cW to cE) — change
#   word EXCLUDES the trailing whitespace. Earlier mnml deleted the
#   trailing space too (`cw` on "brown " gobbled the space, leaving
#   "The quick foxBIG"). Now the space is preserved.
#
# Beats:
#   1. open demo.txt with "The quick brown fox jumps"
#   2. position cursor at start of "brown"   (`/brown\n` jump)
#   3. cw                                    (deletes "brown", enter insert)
#   4. type "BIG"                            (insert text)
#   5. <Esc>                                 (back to normal)
#                                            line is "The quick BIG fox jumps"
#   6. dd                                    (linewise delete — sanity check)
#                                            buffer now empty (one line removed,
#                                            replaced by the next/blank line)
#   7. u                                     (undo so :reg has something to show)
#   8. :reg <Enter>                          (toast shows yank/delete registers)

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.0

  # 1) open the seed file
  echo '{"cmd":"open","path":"demo.txt"}' >> "$CMD"
  sleep 1.8

  # 2) jump to "brown" via vim search
  echo '{"cmd":"type","text":"/brown"}' >> "$CMD"
  sleep 0.4
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 0.6
  # clear the search highlight (esc) — cursor stays on "brown"
  echo '{"cmd":"key","key":"esc"}' >> "$CMD"
  sleep 0.4

  # 3) cw — delete "brown", enter insert
  echo '{"cmd":"type","text":"cw"}' >> "$CMD"
  sleep 1.0

  # 4) type "BIG" — replaces the word
  echo '{"cmd":"type","text":"BIG"}' >> "$CMD"
  sleep 0.8

  # 5) <Esc> — back to normal. Line: "The quick BIG fox jumps"
  echo '{"cmd":"key","key":"esc"}' >> "$CMD"
  sleep 2.0

  # 6) dd — linewise delete
  echo '{"cmd":"type","text":"dd"}' >> "$CMD"
  sleep 1.5

  # 7) u — undo so the line is back
  echo '{"cmd":"type","text":"u"}' >> "$CMD"
  sleep 1.0

  # 8) :reg<Enter> — toast prints yank/delete register snapshot
  echo '{"cmd":"type","text":":reg"}' >> "$CMD"
  sleep 0.4
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 1.5
} >/dev/null 2>&1
