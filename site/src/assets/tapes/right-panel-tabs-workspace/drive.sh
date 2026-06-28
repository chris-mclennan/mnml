#!/usr/bin/env bash
# Drives mnml via IPC for the right-panel-tabs tape.
#
# Shows v3's headline: multiple tabs in the right panel. Beats:
#   ~1s  → open src/lib.rs into the editor
#   ~5s  → view.toggle_right_panel       (open panel — empty state)
#   ~8s  → outline.show                  (Outline becomes tab #1 — active)
#  ~11s  → lsp.diagnostics               (Diagnostics joins as tab #2 — active)
#  ~14s  → view.right_panel_prev_tab     (Outline becomes active — Ctrl+Shift+[)
#  ~17s  → view.right_panel_next_tab     (Diagnostics becomes active — Ctrl+Shift+])
#  ~20s  → click the panel's × button    (closes Diagnostics; Outline takes over)
#  ~23s  → click × again                 (closes Outline; panel back to empty state)
#
# Why IPC: VHS's terminal can't send Ctrl+Shift+B, Ctrl+Shift+] or
# Ctrl+Shift+[ distinctly without the Kitty keyboard protocol. Standard
# input mode (mnml's default) doesn't accept `:` as a cmdline opener.
# Tabs + close are all driven via the file-IPC `run-command` + `click`
# verbs so the demo is reproducible.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

read_close_rect() {
  for _ in $(seq 1 60); do
    if [ -f "$RECTS" ]; then
      LINE=$(grep -F '"label":"right_panel_close"' "$RECTS" 2>/dev/null | head -1)
      [ -n "$LINE" ] && { echo "$LINE"; return; }
    fi
    sleep 0.1
  done
}

click_close() {
  LINE=$(read_close_rect)
  [ -z "$LINE" ] && return
  CX=$(echo "$LINE" | sed -E 's/.*"x":([0-9]+).*/\1/')
  CY=$(echo "$LINE" | sed -E 's/.*"y":([0-9]+).*/\1/')
  CW=$(echo "$LINE" | sed -E 's/.*"w":([0-9]+).*/\1/')
  CH=$(echo "$LINE" | sed -E 's/.*"h":([0-9]+).*/\1/')
  COL=$(( CX + CW / 2 ))
  ROW=$(( CY + CH / 2 ))
  printf '{"cmd":"click","col":%d,"row":%d,"button":"left"}\n' "$COL" "$ROW" >> "$CMD"
}

{
  # Wait for mnml to set up its IPC dir.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.0

  # Open lib.rs (Outline / Diagnostics need an active editor to bind to).
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"

  # Open the panel — empty state.
  sleep 4.0
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"

  # Outline becomes tab #1.
  sleep 3.0
  echo '{"cmd":"run-command","id":"outline.show"}' >> "$CMD"

  # Diagnostics joins as tab #2 — strip now shows BOTH.
  sleep 3.0
  echo '{"cmd":"run-command","id":"lsp.diagnostics"}' >> "$CMD"

  # Ctrl+Shift+[ — previous tab → Outline.
  sleep 3.0
  echo '{"cmd":"run-command","id":"view.right_panel_prev_tab"}' >> "$CMD"

  # Ctrl+Shift+] — next tab → Diagnostics.
  sleep 3.0
  echo '{"cmd":"run-command","id":"view.right_panel_next_tab"}' >> "$CMD"

  # Click × — closes Diagnostics; Outline becomes active again.
  sleep 3.0
  click_close

  # Click × again — closes Outline; panel returns to empty state.
  sleep 3.0
  click_close
} >/dev/null 2>&1
