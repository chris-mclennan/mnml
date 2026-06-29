#!/usr/bin/env bash
# Drives mnml via IPC for the right-panel-close-menu tape.
#
# Demonstrates the 2026-06-29 close-menu polish:
#   1. open src/lib.rs (Outline + Diagnostics + Grep need an editor anchor)
#   2. view.toggle_right_panel                 (empty state)
#   3. outline.show                            (tab #1)
#   4. lsp.diagnostics                         (tab #2 — active)
#   5. find.grep + Hello prompt                (tab #3 — active)
#   6. right-click an INACTIVE tab (tab #1)    (menu opens with Switch/Close/Close other/Close all/Hide)
#   7. click "Close other tabs"                (only the right-clicked tab survives)
#   8. outline.show again + lsp.diagnostics    (back to 2 tabs)
#   9. view.right_panel_close_tab              (Ctrl+Alt+W's command — closes the active tab)
#
# Why IPC: VHS can't send Ctrl+Shift+B / Ctrl+Alt+W without the Kitty
# keyboard protocol, and the right-click coordinates need to come from
# rects.json so they always line up with the rendered tabs.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

read_rect() {
  local LABEL="$1"
  for _ in $(seq 1 60); do
    if [ -f "$RECTS" ]; then
      LINE=$(grep -F "\"label\":\"$LABEL\"" "$RECTS" 2>/dev/null | head -1)
      [ -n "$LINE" ] && { echo "$LINE"; return; }
    fi
    sleep 0.1
  done
}

centre_xy() {
  local LINE="$1"
  CX=$(echo "$LINE" | sed -E 's/.*"x":([0-9]+).*/\1/')
  CY=$(echo "$LINE" | sed -E 's/.*"y":([0-9]+).*/\1/')
  CW=$(echo "$LINE" | sed -E 's/.*"w":([0-9]+).*/\1/')
  CH=$(echo "$LINE" | sed -E 's/.*"h":([0-9]+).*/\1/')
  COL=$(( CX + CW / 2 ))
  ROW=$(( CY + CH / 2 ))
  echo "$COL $ROW"
}

right_click() {
  local LABEL="$1"
  local LINE
  LINE=$(read_rect "$LABEL")
  [ -z "$LINE" ] && return
  read COL ROW <<< "$(centre_xy "$LINE")"
  printf '{"cmd":"click","col":%d,"row":%d,"button":"right"}\n' "$COL" "$ROW" >> "$CMD"
}

click_menu_item_with_text() {
  local NEEDLE="$1"
  # Refresh: walk every context_menu_item:N and find the one whose ROW
  # matches the menu row containing the needle. The simpler signal: the
  # menu items render in the order added — Switch / Close tab / Close
  # other tabs / Close all tabs / Hide side panel. We use the index.
  local IDX="$2"
  local LINE
  LINE=$(read_rect "context_menu_item:$IDX")
  [ -z "$LINE" ] && return
  read COL ROW <<< "$(centre_xy "$LINE")"
  printf '{"cmd":"click","col":%d,"row":%d,"button":"left"}\n' "$COL" "$ROW" >> "$CMD"
}

{
  # Wait for mnml's IPC dir.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.0

  # 1) open src/lib.rs as the anchor file
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"
  sleep 2.5

  # 2) open the right panel (empty state)
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"
  sleep 2.5

  # 3) outline.show — tab #1
  echo '{"cmd":"run-command","id":"outline.show"}' >> "$CMD"
  sleep 2.0

  # 4) lsp.diagnostics — tab #2 (active)
  echo '{"cmd":"run-command","id":"lsp.diagnostics"}' >> "$CMD"
  sleep 2.0

  # 5) find.grep prompt — accept "fn" to host a Grep results tab as tab #3
  echo '{"cmd":"run-command","id":"find.grep"}' >> "$CMD"
  sleep 0.6
  echo '{"cmd":"type","text":"fn"}' >> "$CMD"
  sleep 0.4
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 2.0

  # 6) right-click the FIRST tab (Outline — inactive)
  right_click "right_panel_tab:0"
  sleep 2.5

  # 7) click "Close other tabs" — items are ordered:
  #   0=Switch to this tab  1=Close tab  2=Close other tabs  3=Close all tabs  4=Hide side panel
  click_menu_item_with_text "Close other tabs" 2
  sleep 2.5

  # 8) bring it back to 2 tabs to demo Ctrl+Alt+W. The previous beat
  #    left Outline as the only tab — add Diagnostics back as tab #2.
  echo '{"cmd":"run-command","id":"lsp.diagnostics"}' >> "$CMD"
  sleep 2.5

  # 9) view.right_panel_close_tab — what Ctrl+Alt+W fires
  echo '{"cmd":"run-command","id":"view.right_panel_close_tab"}' >> "$CMD"
  sleep 2.5
} >/dev/null 2>&1
