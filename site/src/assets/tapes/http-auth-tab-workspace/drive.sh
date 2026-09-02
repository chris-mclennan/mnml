#!/usr/bin/env bash
# Drives mnml via IPC for the http-auth-tab tape.
#
# Why IPC: the tape used to walk the Edit-view tab strip by pressing
# Ctrl+] a fixed number of times. That silently drifted — the strip
# was reordered to Bruno-style (`EditTab::ALL` in src/request_pane.rs
# now leads with Params, and Source is LABELED "Script"), and a
# 2-press take landed on Vars instead of Auth. The demo shipped
# without ever showing the tab it is named after.
#
# mnml binds Ctrl+1..6 to jump straight to a named tab
# (src/tui/mod.rs — Ctrl+4 = Auth), but VHS's parser rejects `Ctrl+4`
# ("Expected control character with args"). The IPC `key` verb takes
# the chord verbatim, so drive it from here instead.
#
# Beats (relative to IPC handshake):
#   ~2.0s → open README.md          (an editor pane to hang the cmdline off)
#   ~4.0s → http.paste_curl         (mint + populate the Request pane)
#   ~8.0s → ctrl+]                  (one step, so the strip visibly moves)
#  ~10.5s → ctrl+4                  (land ON Auth, deterministically)

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
CURL="curl 'https://api.example.com/v1/me' -H 'Accept: application/json' -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.demo-payload.sig'"

{
  CLIP_BAK=$(pbpaste 2>/dev/null || true)

  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  sleep 2.0
  echo '{"cmd":"open","path":"README.md"}' >> "$CMD"

  # paste_curl reads the LIVE clipboard. The tape seeds it in the
  # hidden setup block, but that is ~5s early and an unrelated copy
  # can win the race (it did on the sibling http-new-paste-curl tape:
  # a take recorded `populated from 15059`). Re-seed immediately
  # before firing, and restore the operator's clipboard at the end.
  sleep 1.5
  printf '%s' "$CURL" | pbcopy 2>/dev/null || true

  sleep 0.5
  echo '{"cmd":"run-command","id":"http.paste_curl"}' >> "$CMD"

  sleep 4.0
  echo '{"cmd":"key","key":"ctrl+]"}' >> "$CMD"

  sleep 2.5
  echo '{"cmd":"key","key":"ctrl+4"}' >> "$CMD"

  # Take is done — hand the clipboard back.
  sleep 4.0
  printf '%s' "$CLIP_BAK" | pbcopy 2>/dev/null || true
} >/dev/null 2>&1
