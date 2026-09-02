#!/usr/bin/env bash
# Clipboard steward for the http-new-paste-curl tape.
#
# `http.paste_curl` reads the LIVE system clipboard, so the tape can't
# just seed it in the hidden setup block and hope: that leaves a ~7s
# window in which anything the operator copies wins. It does happen —
# a take on 2026-09-02 recorded `paste_curl: populated from 15059`
# with `15059` sitting in the URL field, because an unrelated copy
# landed between the seed and the paste.
#
# So seed it ~1s before paste_curl fires instead of ~7s, then hand the
# operator's clipboard back once the take is done.
#
# Timeline (tape-relative, from the `mnml` Enter):
#   t≈3.0s  Escape (welcome)   t≈4.6s  Ctrl+P → "readme" → Enter
#   t≈6.6s  :http.paste_curl   ← seed must be in place by here
#   t≈11.6s Escape + `r` (fire)
#   t≈19s   end

set -u
WS="$1"
CURL="curl 'https://httpbin.org/headers' -H 'Accept: application/json' -H 'X-Demo: tape'"
CMD="$WS/.mnml/ipc/command"

{
  CLIP_BAK=$(pbpaste 2>/dev/null || true)

  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # IPC is up ~1s after launch; paste_curl fires ~6.6s after launch.
  #
  # A single seed 1s ahead still loses: a 2026-09-02 take recorded
  # `nditions` (a fragment of an unrelated copy) in the URL field.
  # The operator's machine is live during the render, so HOLD the
  # value across the whole read window rather than setting it once.
  sleep 2.5
  for _ in $(seq 1 40); do
    printf '%s' "$CURL" | pbcopy 2>/dev/null || true
    sleep 0.15
  done

  # Stage 2 — fire the request.
  #
  # The tape used to do this with `Escape` (Edit view → Response view)
  # then `r`. That stopped working: after paste_curl the cursor sits
  # IN the URL field, Escape only leaves the field, and the `r` lands
  # as text instead of the Response view's fire chord — takes ended on
  # "not sent yet · press `r` to fire", never showing the 200 OK the
  # tape is supposed to finish on. Fire it over IPC instead.
  sleep 1.5
  echo '{"cmd":"run-command","id":"http.send"}' >> "$CMD"

  # Take is past the paste + the send — give the clipboard back.
  sleep 6.0
  printf '%s' "$CLIP_BAK" | pbcopy 2>/dev/null || true
} >/dev/null 2>&1
