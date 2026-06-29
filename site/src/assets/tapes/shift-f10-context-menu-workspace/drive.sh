#!/usr/bin/env bash
# Drives mnml via IPC for the shift-f10-context-menu tape.
#
# Why IPC: VHS's xterm doesn't reliably forward `Shift+F10` as a
# distinguished modified-CSI sequence — the function key arrives as
# plain F10 (which opens the menu bar instead of the context menu).
# We work around by firing `view.context_menu_at_focus` directly
# via the `run-command` IPC verb on the two beats the tape needs:
#   1. ~7s in, while the tree row is focused (tree-row menu).
#   2. ~13s in, after the editor has been opened + focused (tab
#      context menu).
#
# All output suppressed.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  # Wait for mnml's IPC to come up.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # Initial settle while the tape lets mnml render its first
  # frame + dismiss the welcome overlay + nudge the tree cursor
  # to a real entry. Tape timeline:
  #   t=3s   Escape (dismiss welcome)
  #   t=3.5s Down
  #   t=3.8s Down  ← tree cursor lands on .git (or .gitignore)
  #   t=4.2s  (waiting for menu)
  sleep 1.5

  # Beat 1: tree-row context menu.
  echo '{"cmd":"run-command","id":"view.context_menu_at_focus"}' >> "$CMD"

  # The tape's tree-menu paint window is 2.5s, then Escape closes
  # it. Wait through that + the tape's settle (~1s) before opening
  # the file via the safest path: an `open` IPC verb (avoids
  # Ctrl+P which picks up cross-workspace recents). The driver's
  # `open` lands a fresh `main.rs` from the demo workspace itself.
  sleep 4.0
  echo '{"cmd":"open","path":"src/main.rs"}' >> "$CMD"

  # Settle on the editor pane (focus = Focus::Pane via reveal_pane).
  sleep 2.0

  # Beat 2: bufferline-tab context menu.
  echo '{"cmd":"run-command","id":"view.context_menu_at_focus"}' >> "$CMD"
} >/dev/null 2>&1
