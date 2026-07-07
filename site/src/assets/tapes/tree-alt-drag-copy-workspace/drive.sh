#!/usr/bin/env bash
# Drives mnml via IPC for the tree-alt-drag-copy tape.
#
# Flow:
#   1. Alt-hold + mouse-down on the tree row for `Cargo.toml`.
#      `mouse/down_left.rs` reads `KeyModifiers::ALT`, primes
#      `begin_tree_drag_with_mode(..., copy_instead_of_move=true)`.
#   2. Walk the cursor down to the `docs/` row — mouse_move events
#      arm the drag and paint the ghost chip.
#   3. Mouse-up on `docs/`. `end_tree_drag` sees `drag.copy=true`
#      and fires `copy_recursively(Cargo.toml, docs/Cargo.toml)`
#      IMMEDIATELY — no confirmation prompt (that's the plain-drag
#      path). Toast: `copied → docs/Cargo.toml`.
#
# Coords come from `rects.json`'s `tree` rect (the tree body's rect
# without the up/filter chrome). Row `N` sits at `y = tree.y + N`.

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

# Returns `X Y` for a given tree row (0-indexed among visible rows).
# Uses the "tree" rect (x, y = origin of the tree body) + row offset.
row_coord() {
  local row="$1"
  python3 - "$RECTS" "$row" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as fh:
        rects = json.load(fh)
except Exception:
    sys.exit(0)
row = int(sys.argv[2])
for r in rects:
    if r["label"] == "tree":
        # Click mid-column so a name is under the pointer.
        cx = r["x"] + max(8, r["w"] // 3)
        cy = r["y"] + row
        print(f"{cx} {cy}")
        break
PY
}

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  wait_rects_has "\"label\":\"tree\""
  sleep 0.6

  # Tree layout (auto-expanded — .mnml + docs open):
  #   [0] .mnml/
  #   [1]   .welcomed
  #   [2] docs/
  #   [3]   README.md   (inside docs/)
  #   [4] Cargo.toml    ← source
  #   [5] README.md     (workspace root)
  #
  # Get source (Cargo.toml, row 4) and target (docs/, row 2).
  SRC="$(row_coord 4)"
  DST="$(row_coord 2)"
  if [ -z "$SRC" ] || [ -z "$DST" ]; then
    exit 0
  fi
  set -- $SRC; SX=$1; SY=$2
  set -- $DST; DX=$1; DY=$2

  # 1. Alt+MouseDown at Cargo.toml row — primes copy-drag.
  echo "{\"cmd\":\"mouse_down\",\"col\":$SX,\"row\":$SY,\"mods\":\"alt\"}" >> "$CMD"
  sleep 0.4

  # 2. Walk cursor toward docs/ — a couple of hops so the ghost chip
  #    paints between motion events.
  MID_Y=$(( SY - 1 ))
  echo "{\"cmd\":\"mouse_move\",\"col\":$SX,\"row\":$MID_Y}" >> "$CMD"
  sleep 0.25
  echo "{\"cmd\":\"mouse_move\",\"col\":$DX,\"row\":$DY}" >> "$CMD"
  sleep 0.8

  # 3. Release on docs/. Alt-drag skips the confirm prompt and
  #    copies immediately.
  echo "{\"cmd\":\"mouse_up\",\"col\":$DX,\"row\":$DY,\"mods\":\"alt\"}" >> "$CMD"
  sleep 2.4
} >/dev/null 2>&1
