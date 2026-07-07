#!/usr/bin/env bash
# Drives mnml via IPC for the http-edit-split tape.
#
# Flow:
#   1. Open `api.http` — creates a Request pane in Edit view.
#   2. Fire `http.toggle_edit_split` — behaviorally identical to a
#      click on the `[⇔]` chip (both dispatch through
#      `App::http_toggle_edit_split` / `RequestPane::toggle_edit_split`).
#   3. Parse `screen.txt` to locate the split divider column and the
#      right-side "Vars" tab column.
#   4. Click the right-side "Vars" tab.
#   5. Click the divider three times to cycle the ratio.
#   6. Fire `http.toggle_edit_split` again — split closes.
#
# All output suppressed so the bg job doesn't pollute the recorded PTY.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
SCREEN="$WS/.mnml/ipc/screen.txt"
LOG="$WS/.mnml/ipc/drive.log"
: >"$LOG"

# Wait for screen.txt to contain `pattern` (substring, plain). Bounded
# poll: up to 5s. Returns 0 on match, 1 on timeout.
wait_screen_contains() {
  local pattern="$1"
  local i
  for i in $(seq 1 50); do
    if [ -e "$SCREEN" ] && grep -Fq -- "$pattern" "$SCREEN" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Locate the split divider column by inspecting the current screen.
# Prints `ROW COL` (0-based) for a mid-height row that has the
# divider drawn. Silent (empty) on failure.
find_divider_col() {
  python3 - "$SCREEN" <<'PY'
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError:
    print("")
    sys.exit(0)
col_counts = {}
for row_idx, line in enumerate(lines):
    if row_idx < 5:
        continue
    for col_idx, ch in enumerate(line):
        if ch == "│":
            col_counts[col_idx] = col_counts.get(col_idx, 0) + 1
if not col_counts:
    print("")
    sys.exit(0)
best_count = max(col_counts.values())
threshold = max(3, best_count // 2)
candidates = sorted(c for c, n in col_counts.items() if n >= threshold)
if len(candidates) < 3:
    print("")
    sys.exit(0)
lb, rb = candidates[0], candidates[-1]
mid_target = (lb + rb) // 2
divider = min(candidates[1:-1], key=lambda c: abs(c - mid_target))
target = None
for row_idx, line in enumerate(lines):
    if row_idx < 10:
        continue
    if len(line) > divider and line[divider] == "│":
        target = row_idx
        break
if target is None:
    for row_idx, line in enumerate(lines):
        if row_idx < 5:
            continue
        if len(line) > divider and line[divider] == "│":
            target = row_idx
            break
if target is None:
    print("")
else:
    print(f"{target} {divider}")
PY
}

# Locate the "Vars" tab on the RIGHT side of the split (col >= divider).
# Prints `ROW COL` (0-based, center-of-"Vars"). Silent on failure.
find_right_vars() {
  local divider="${1:-0}"
  python3 - "$SCREEN" "$divider" <<'PY'
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError:
    print("")
    sys.exit(0)
try:
    divider = int(sys.argv[2])
except ValueError:
    divider = 0
for row_idx, line in enumerate(lines):
    if "Body" not in line or "Params" not in line:
        continue
    start = max(divider, 0)
    pos = line.find("Vars", start)
    if pos < 0:
        continue
    print(f"{row_idx} {pos + 2}")
    break
PY
}

{
  # Wait for command channel to appear.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  # Wait for the first real render — screen.txt appears + populates.
  # (mnml writes it on every frame; we look for a bufferline / tree
  # element that's definitely in the first paint.)
  wait_screen_contains "workspace" || wait_screen_contains "..."
  echo "IPC_READY $(date +%s.%N)" >>"$LOG"

  # Open the .http file — creates a Request pane in Edit view.
  echo '{"cmd":"open","path":"api.http"}' >> "$CMD"
  # Wait for the file's tab / method to render.
  wait_screen_contains "POST"
  echo "OPENED_HTTP $(date +%s.%N)" >>"$LOG"
  sleep 0.6

  # Toggle the edit-split OPEN.
  echo '{"cmd":"run-command","id":"http.toggle_edit_split"}' >> "$CMD"
  # Wait for the split to actually paint: the right-side tab strip
  # will show additional tab labels (e.g. "Vars" or "Script") that
  # don't appear on the primary side at 50% ratio.
  wait_screen_contains "Vars" || sleep 0.8
  echo "SPLIT_OPEN $(date +%s.%N)" >>"$LOG"
  sleep 0.6

  # Snapshot screen for debugging.
  cp "$SCREEN" "$WS/.mnml/ipc/screen.at-split-open.txt" 2>/dev/null || true

  # Find divider + right-side Vars tab from the freshest screen.txt.
  DIV="$(find_divider_col)"
  DIVIDER_COL=""
  DIVIDER_ROW=""
  if [ -n "$DIV" ]; then
    set -- $DIV
    DIVIDER_ROW=$1
    DIVIDER_COL=$2
  fi
  echo "DIV=$DIV DIVIDER_ROW=$DIVIDER_ROW DIVIDER_COL=$DIVIDER_COL" >>"$LOG"

  RV="$(find_right_vars "${DIVIDER_COL:-0}")"
  echo "RV=$RV" >>"$LOG"
  if [ -n "$RV" ]; then
    set -- $RV
    ROW=$1
    COL=$2
    echo "{\"cmd\":\"click\",\"col\":$COL,\"row\":$ROW}" >> "$CMD"
    sleep 1.4
  fi

  if [ -n "$DIVIDER_COL" ] && [ -n "$DIVIDER_ROW" ]; then
    echo "click divider $DIVIDER_COL,$DIVIDER_ROW x3 $(date +%s.%N)" >>"$LOG"
    # 3 clicks with sleeps → cycles ratio 50 → 70 → 30 → 50.
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER_COL,\"row\":$DIVIDER_ROW}" >> "$CMD"
    sleep 1.0
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER_COL,\"row\":$DIVIDER_ROW}" >> "$CMD"
    sleep 1.0
    echo "{\"cmd\":\"click\",\"col\":$DIVIDER_COL,\"row\":$DIVIDER_ROW}" >> "$CMD"
    sleep 1.2
  fi

  # Toggle the edit-split CLOSED.
  echo '{"cmd":"run-command","id":"http.toggle_edit_split"}' >> "$CMD"
  echo "SPLIT_CLOSED $(date +%s.%N)" >>"$LOG"
  sleep 1.4
} >/dev/null 2>&1
