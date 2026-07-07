#!/usr/bin/env bash
# Drives mnml via IPC for the http-edit-split tape.
#
# Flow:
#   1. Open `api.http` — creates a Request pane in Edit view.
#   2. Fire `http.toggle_edit_split` — behaviorally identical to a
#      click on the `[⇔]` chip (both dispatch through
#      `App::http_toggle_edit_split` / `RequestPane::toggle_edit_split`).
#   3. Parse rects.json to locate the split divider column + right-side
#      "Vars" tab column, then fire the corresponding clicks.
#   4. Click the divider three times → cycle ratio 50 → 70 → 30 → 50.
#   5. Fire `http.toggle_edit_split` again → split closes.
#
# Why rects.json (not screen.txt): mnml's terminal-frontend path writes
# `screen.txt` from `Terminal::current_buffer_mut()` which — post
# `draw()` — holds the stale (empty) buffer. `rects.json` is built from
# `App.rects` (independent of the ratatui backend buffer), so it stays
# valid and is what this driver reads.
#
# All output suppressed so the bg job doesn't pollute the recorded PTY.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

# Wait for rects.json to contain a substring (bounded poll, ~5s).
wait_rects_has() {
  local pattern="$1"
  local i
  for i in $(seq 1 60); do
    if [ -e "$RECTS" ] && grep -Fq -- "$pattern" "$RECTS" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Compute click coords for divider and right-side Vars from rects.json.
# Prints multiple lines suitable for eval:
#   DIVIDER=<col>
#   TAB_ROW=<row>
#   RIGHT_VARS=<col>
compute_click_targets() {
  python3 - "$RECTS" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as fh:
        rects = json.load(fh)
except Exception:
    sys.exit(0)
by_label = {r["label"]: r for r in rects}

body = by_label.get("request_field:0:Body")
if not body:
    sys.exit(0)
# Divider column = right edge of primary Body field.
divider = body["x"] + body["w"]

prim_tab = by_label.get("request_edit_tab:0:Body") or by_label.get("request_edit_tab:0:Params")
if not prim_tab:
    sys.exit(0)
tab_row = prim_tab["y"]

prim_params = by_label.get("request_edit_tab:0:Params")
prim_vars = by_label.get("request_edit_tab:0:Vars")
if not prim_params or not prim_vars:
    sys.exit(0)
vars_offset = prim_vars["x"] - prim_params["x"]
lead_pad = prim_params["x"] - body["x"]
right_vars_x = (divider + 1) + lead_pad + vars_offset + 2  # +2 = center of "Vars"

print(f"DIVIDER={divider}")
print(f"TAB_ROW={tab_row}")
print(f"RIGHT_VARS={right_vars_x}")
PY
}

{
  # Wait for command channel + rects population.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  wait_rects_has "tree_toggle"

  # Open the .http file — creates a Request pane in Edit view.
  echo '{"cmd":"open","path":"api.http"}' >> "$CMD"
  wait_rects_has "request_edit_tab"
  sleep 0.4

  # Toggle the edit-split OPEN.
  echo '{"cmd":"run-command","id":"http.toggle_edit_split"}' >> "$CMD"
  sleep 0.9

  # Compute divider + right-Vars click coords from rects.json.
  eval "$(compute_click_targets)"

  if [ -n "${RIGHT_VARS:-}" ] && [ -n "${TAB_ROW:-}" ]; then
    echo "{\"cmd\":\"click\",\"col\":$RIGHT_VARS,\"row\":$TAB_ROW}" >> "$CMD"
    sleep 1.4
  fi

  if [ -n "${DIVIDER:-}" ]; then
    DIV_ROW=$((TAB_ROW + 8))
    # 3 clicks with sleeps → ratio cycles 50 → 70 → 30 → 50.
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER,\"row\":$DIV_ROW}" >> "$CMD"
    sleep 1.0
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER,\"row\":$DIV_ROW}" >> "$CMD"
    sleep 1.0
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER,\"row\":$DIV_ROW}" >> "$CMD"
    sleep 1.2
  fi

  # Toggle the edit-split CLOSED.
  echo '{"cmd":"run-command","id":"http.toggle_edit_split"}' >> "$CMD"
  sleep 1.4
} >/dev/null 2>&1
