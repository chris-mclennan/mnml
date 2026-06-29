#!/usr/bin/env bash
# Drives mnml via IPC for the right-panel-toggle tape.
#
# Why IPC: VHS's terminal can't distinguish Ctrl+Shift+B from Ctrl+B
# without the Kitty keyboard protocol, and standard input mode (the
# mnml default) doesn't accept `:` as the cmdline opener. The
# cleanest path is to fire view.toggle_right_panel + outline.show
# via `run-command` IPC at scripted beats.
#
# Beats (relative to IPC handshake):
#   ~5s  → view.toggle_right_panel  (open panel, empty state)
#   ~9s  → outline.show              (host Outline)
#  ~13s  → view.toggle_right_panel  (close panel; close hosted pane)
#
# Suppress all output so the bg job doesn't pollute the recorded PTY.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # Tape opens main.rs via Ctrl+P + Enter ~4s after launch; let
  # that settle before we start manipulating the right column.
  sleep 5.0
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"

  sleep 3.5
  echo '{"cmd":"run-command","id":"outline.show"}' >> "$CMD"

  sleep 3.5
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"
} >/dev/null 2>&1
