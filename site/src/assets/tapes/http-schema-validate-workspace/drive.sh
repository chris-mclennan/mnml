#!/usr/bin/env bash
# Drives mnml via IPC for the http-schema-validate tape.
#
# Why IPC: the tape used to TYPE `:http.send` / `:http.replay_mock` /
# `:http.revalidate_schema` / `:http.show_schema_errors` on the vim
# ex-cmdline. That broke — once `http.send` puts a Request pane up,
# the Response view owns the keyboard and `:` never opens the
# cmdline, so the literal characters fall through to the view's
# chords. The `a` in "replay_mock" is the Response view's "AI quick
# debug" chord, so the take opened an AI pane, stole `app.active`,
# and every following http.* command toasted "not a Request pane".
# The request never fired and the schema footer — the entire point
# of the demo — never appeared.
#
# `tests/e2e/http/http-schema-validate.test` drives this same flow
# with `command http.…` rather than keystrokes. Do the same here.
#
# Beats (relative to IPC handshake):
#   ~2.0s → open users.curl
#   ~4.0s → http.send            (fails fast against the dead port)
#   ~7.5s → http.replay_mock     (inject the canned {"name":42} body)
#  ~11.0s → http.revalidate_schema (footer flips to ✗ Schema: N errors)
#  ~15.5s → http.show_schema_errors ([schema-errors] scratch)

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # Let the tape dismiss the welcome overlay + paint the first frame.
  sleep 2.0
  echo '{"cmd":"open","path":"users.curl"}' >> "$CMD"

  sleep 2.0
  echo '{"cmd":"run-command","id":"http.send"}' >> "$CMD"

  sleep 3.5
  echo '{"cmd":"run-command","id":"http.replay_mock"}' >> "$CMD"

  sleep 3.5
  echo '{"cmd":"run-command","id":"http.revalidate_schema"}' >> "$CMD"

  sleep 4.5
  echo '{"cmd":"run-command","id":"http.show_schema_errors"}' >> "$CMD"
} >/dev/null 2>&1
