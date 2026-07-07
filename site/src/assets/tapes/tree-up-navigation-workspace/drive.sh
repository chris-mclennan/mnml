#!/usr/bin/env bash
# Drives mnml via IPC for the tree-up-navigation tape.
#
# Flow:
#   1. Click the `..` row at the top of the tree.
#      `mouse/down_left.rs` matches `app.rects.tree_up_row` and
#      calls `App::navigate_workspace_up()`.
#   2. `navigate_workspace_up` swaps `app.workspace` for its parent,
#      rewires the tree, refreshes the git rail, updates the
#      workspace chip in the palette, and toasts the new root.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

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

# Prints `X Y` for the center of a labelled rect.
rect_center() {
  local label="$1"
  python3 - "$RECTS" "$label" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as fh:
        rects = json.load(fh)
except Exception:
    sys.exit(0)
label = sys.argv[2]
for r in rects:
    if r["label"] == label:
        cx = r["x"] + max(1, r["w"] // 3)
        cy = r["y"] + max(0, r["h"] // 2)
        print(f"{cx} {cy}")
        break
PY
}

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  wait_rects_has "\"label\":\"tree_up_row\""
  sleep 0.6

  # Click the `..` row.
  UP="$(rect_center "tree_up_row")"
  if [ -n "$UP" ]; then
    set -- $UP
    echo "{\"cmd\":\"click\",\"col\":$1,\"row\":$2}" >> "$CMD"
    sleep 2.6
  fi
} >/dev/null 2>&1
