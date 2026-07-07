#!/usr/bin/env bash
# Drives mnml via IPC for the http-vars-highlight-quickadd tape.
#
# Flow:
#   1. Open `api.http` — Request pane in Edit view. The URL contains
#      `{{DATABASE_URL}}`, which is NOT in the active env → red.
#   2. Hover the token so the "not defined" tooltip appears.
#   3. Right-click the token → context menu with "Set value…" opens.
#   4. Click "Set value…" (first menu item) → EnvEditValue prompt seeds.
#   5. Type `postgres://localhost/dev`, Enter → writes to `.mnml/env/dev.env`.
#   6. Token flips from red to cyan (envset resolves next draw).
#
# All coords are discovered from `rects.json` (which mnml writes on
# every frame from `App.rects`). The var-token rect is emitted as
# `request_var:<NAME>`; menu items as `context_menu_item:<N>`.

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

# Prints `X Y` for the center of a rect identified by exact `label`.
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
        cx = r["x"] + max(1, r["w"] // 2)
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
  wait_rects_has "tree_toggle"

  echo '{"cmd":"open","path":"api.http"}' >> "$CMD"
  wait_rects_has "request_var:DATABASE_URL"
  sleep 1.2

  # Coords for the token.
  TOK="$(rect_center "request_var:DATABASE_URL")"
  if [ -n "$TOK" ]; then
    set -- $TOK
    TX=$1
    TY=$2
    # 1. Hover so the tooltip paints.
    #    NOTE: don't left-click the token — left-click on an unresolved
    #    var runs `open_env_var_definition` which opens the env file
    #    in a new editor pane and steals focus.
    echo "{\"cmd\":\"hover\",\"col\":$TX,\"row\":$TY}" >> "$CMD"
    sleep 1.6
    # 2. Right-click → context menu.
    echo "{\"cmd\":\"click\",\"col\":$TX,\"row\":$TY,\"button\":\"right\"}" >> "$CMD"
    sleep 0.9
  fi

  # 4. Click "Set value…" (first menu item, index 0).
  wait_rects_has "context_menu_item:0"
  MENU0="$(rect_center "context_menu_item:0")"
  if [ -n "$MENU0" ]; then
    set -- $MENU0
    echo "{\"cmd\":\"click\",\"col\":$1,\"row\":$2}" >> "$CMD"
    sleep 1.0
  fi

  # 4. Type the value + Enter — mnml writes to .mnml/env/dev.env.
  echo '{"cmd":"type","text":"postgres://localhost/dev"}' >> "$CMD"
  sleep 0.8
  echo '{"cmd":"key","key":"enter"}' >> "$CMD"
  sleep 2.2
} >/dev/null 2>&1
