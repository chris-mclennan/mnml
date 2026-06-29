#!/usr/bin/env bash
# Drives mnml via IPC for the right-panel-v2-hosting tape.
#
# Two jobs:
#   1. Open `src/lib.rs` once mnml's IPC is up (so the editor pane
#      is populated before the tape's first VHS-driven beat).
#   2. After the tape opens the panel + hosts Diagnostics, wait for
#      `right_panel_close` to appear in `rects.json`, then click
#      the centre of that rect via the `click` IPC command.
#
# All output suppressed so the bg job doesn't pollute the recorded
# PTY once mnml has taken it over.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

{
  # Wait for mnml to create its IPC dir + command file.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # Settle for the first paint.
  sleep 1.0

  # Open lib.rs into the editor pane.
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"

  # Open the right panel — VHS can't send Ctrl+Shift+B distinctly
  # and standard input mode doesn't accept `:`, so fire it via IPC.
  sleep 4.0
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"

  # Host the Outline pane.
  sleep 2.5
  echo '{"cmd":"run-command","id":"outline.show"}' >> "$CMD"

  # Swap to Diagnostics (in v3, joins the tab strip; in v2,
  # displaces the Outline). Either way, header reads DIAGNOSTICS.
  sleep 3.0
  echo '{"cmd":"run-command","id":"lsp.diagnostics"}' >> "$CMD"

  # Hold on the Diagnostics-hosted state so the viewer reads it
  # before the click lands.
  sleep 3.0

  # ── click the panel's `×` ──────────────────────────────────
  # Read the live `right_panel_close` rect (only populated when a
  # pane is hosted) from `rects.json`, then synthesize a click on
  # its centre.
  CLOSE_LINE=""
  for _ in $(seq 1 50); do
    if [ -f "$RECTS" ]; then
      CLOSE_LINE=$(grep -F '"label":"right_panel_close"' "$RECTS" 2>/dev/null | head -1)
      [ -n "$CLOSE_LINE" ] && break
    fi
    sleep 0.1
  done

  if [ -n "$CLOSE_LINE" ]; then
    # Pull x / y / w / h from the JSON line via sed. Format:
    #   {"label":"right_panel_close","x":N,"y":N,"w":N,"h":N}
    CX=$(echo "$CLOSE_LINE" | sed -E 's/.*"x":([0-9]+).*/\1/')
    CY=$(echo "$CLOSE_LINE" | sed -E 's/.*"y":([0-9]+).*/\1/')
    CW=$(echo "$CLOSE_LINE" | sed -E 's/.*"w":([0-9]+).*/\1/')
    CH=$(echo "$CLOSE_LINE" | sed -E 's/.*"h":([0-9]+).*/\1/')
    # Centre of the rect.
    COL=$(( CX + CW / 2 ))
    ROW=$(( CY + CH / 2 ))
    # Brief beat so the viewer sees the Diagnostics-hosted state
    # before the click lands.
    sleep 0.4
    printf '{"cmd":"click","col":%d,"row":%d,"button":"left"}\n' "$COL" "$ROW" >> "$CMD"
  fi
} >/dev/null 2>&1
