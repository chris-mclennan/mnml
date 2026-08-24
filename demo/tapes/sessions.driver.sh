#!/usr/bin/env bash
# Sessions rail demo driver — showcases the sessions-rail overhaul
# that landed in `5baa680d feat: sessions rail overhaul + color
# system + placeholder consolidation` (2026-08-23) and its follow-
# ups: batch-spawn menu (#1181), "+ New session" chip at TOP of
# the rail (#1188), auto-cycle color palette (#1179), and the
# per-row / per-tab color-swatch context menu (task #1178 + M-02).
#
# Uses the launcher-override mechanism (see
# `src/pty_pane.rs::resolve_launcher`) to point every Claude Code
# spawn at `demo/tapes/mock-claude.sh` — no real `claude` invocation,
# no API round-trip, no risk of the user's real workspace access
# leaking into the tape. Override is written at start + torn down
# on exit so future demo runs are unaffected.
#
# Output → site/public/media/sessions.gif via hero.record.sh's
# TAPE_NAME=sessions.
#
# Budget: ~40s.
set -euo pipefail

WS="${MNML_DEMO_WORKSPACE:-$(cd "$(dirname "$0")/../workspace" && pwd)}"
CMD="$WS/.mnml/ipc/command"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK="$SCRIPT_DIR/mock-claude.sh"

# ── Launcher override: point Claude Code spawns at the mock ──────
# `resolve_launcher(workspace, "claude_code", "claude")` in
# `src/pty_pane.rs` reads `<workspace>/.mnml/integrations/claude_code.toml`
# and returns the value of the first `launcher = "…"` line. Absolute
# path — no template expansion needed, no PATH lookup risk.
INT_DIR="$WS/.mnml/integrations"
LAUNCHER_TOML="$INT_DIR/claude_code.toml"
mkdir -p "$INT_DIR"
cat > "$LAUNCHER_TOML" <<TOML
# Written by demo/tapes/sessions.driver.sh — tears itself down on
# exit. Points every Claude Code spawn at the mock script so the
# tape is deterministic (no API calls, no login-state leak).
launcher = "$MOCK"
TOML
cleanup() { rm -f "$LAUNCHER_TOML"; }
trap cleanup EXIT

# ── Wait for mnml to boot ──────────────────────────────────────────
for _ in $(seq 1 60); do
  if [ -s "$WS/.mnml/ipc/screen.txt" ]; then
    break
  fi
  sleep 0.1
done
sleep 2.2

send()  { echo "$1" >> "$CMD"; }
run()   { send "{\"cmd\":\"run-command\",\"id\":\"$1\"}"; }
key()   { send "{\"cmd\":\"key\",\"key\":\"$1\"}"; }
type()  { send "{\"cmd\":\"type\",\"text\":\"$1\"}"; }
click() { send "{\"cmd\":\"click\",\"col\":$1,\"row\":$2}"; }
rclick(){ send "{\"cmd\":\"click\",\"col\":$1,\"row\":$2,\"button\":\"right\"}"; }
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Standard keymap so `type` writes literal chars.
run "editor.use_standard"
wait_ms 300

# Beats (target ~40s)
# t=00.0  1  welcome dwell
# t=01.4  2  open Sessions rail — auto-arms filter (focused placeholder)
# t=02.2  3  Esc unfocuses filter (placeholder swaps to unfocused form)
# t=03.4  4  click "+ New session" → 1 Claude spawns (auto-color)
# t=07.0  5  right-click "+ New session" → batch-spawn menu
# t=09.0  6  Esc closes menu; batch cmd fires via IPC (4 more spawn)
# t=13.5  7  click filter chip → focus=Tree + filter armed
#              (placeholder → "type to filter"; done in one click
#              rather than `view.focus_tree` which would also swap
#              section to Explorer)
# t=14.5  8  type "no" → filter narrows (partial-match hits on the
#              mock's `workspace:` line + display name)
# t=16.1  9  Esc clears filter + unfocuses
# t=16.9 10  click a session row → focus flips to that pty pane
# t=18.9 11  right-click same row → full row context menu with the
#              9-color swatch tail
# t=20.9 12  click "Color: Yellow" menu item → row + pane accent +
#              tab color all update live
# t=23.4 13  hero dwell — 5 sessions on rail w/ distinct accents,
#              picked pane w/ new color, bufferline color-matched
# t=31.5 14  quit

# ── 1. Welcome dwell ──────────────────────────────────────────────
wait_ms 1400

# ── 2. Open Sessions rail ─────────────────────────────────────────
# Activity bar icons live at x=1; Sessions sits at y=12 in the
# default 160x42 demo geometry. Entering the section auto-arms the
# filter (layout.rs:2297) — placeholder reads "type to filter…".
click 1 12
wait_ms 800

# ── 3. Unfocus the filter ────────────────────────────────────────
# Esc on a focused-empty filter unfocuses without any content loss.
# Placeholder swaps to the unfocused form (" / filter") via
# `filter_placeholder::for_state` — the two-state placeholder that
# landed with the overhaul commit.
key "escape"
wait_ms 1200

# ── 4. Single spawn: click "+ New session" chip ──────────────────
# Chip renders at (area.x+1, area.y+2) = (col 4, row 3) — see
# `src/ui/sessions_panel.rs::draw`. col=8 is mid-label. First
# Claude picks up the auto-color palette slot 0.
click 8 3
wait_ms 3600

# ── 5. Right-click "+ New session" → batch-spawn menu ────────────
# `right_click.rs:99` intercepts on the chip → calls
# `open_new_session_batch_menu` → 4-item menu:
#   New session · Open ×2 · Open ×4 · Open ×8
rclick 8 3
wait_ms 2000

# ── 6. Close menu (visual beat done) + fire the batch command ────
# Closing via Esc rather than arrow-nav-then-Enter avoids a focus
# race — after the single spawn in beat 4 focus is on the new
# pty pane, and arrow-key routing through `context_menu_move`
# needs the menu to still own the overlay. Firing the batch via
# `run` bypasses the menu (same command the ×4 item wires to) so
# the 4 new sessions land regardless of where focus currently
# sits.
key "escape"
wait_ms 400
run "ai.claude_code_new_x4"
# Give the 4 mock ptys time to spawn + paint their banners. Batch
# spawn walks `open_claude_code_new` per iteration (auto-tile grid
# grows to 2×2 then to 3×2 with a placeholder), so the layout
# animation is non-trivial.
wait_ms 4100

# ── 7. Click the filter chip → focus Tree + arm the filter ──────
# Batch spawns end with focus on the freshly-spawned pty pane.
# The palette's `view.focus_tree` would work but it ALSO switches
# `active_section` to Explorer (command.rs:468 sets the section
# so `Ctrl+Shift+E` from any activity returns to the file list)
# — that would kill the Sessions rail we're demoing. Clicking on
# the filter chip's rect goes through `down_left.rs:2887` which
# does `focus_tree()` + `sessions_panel_filter_focused = true`
# in one step, staying inside Sessions. Chip lives at row 2
# (filter row, one below the SESSIONS header) so col=8, row=2
# lands mid-chip.
click 8 2
wait_ms 1000

# ── 9. Type filter chars ─────────────────────────────────────────
# The mock's banner prints `workspace: workspace` + a display
# name for each session; the filter matches substrings against
# both. "no" hits the demo workspace name (Notely) via the display
# name path — narrows the visible list without dropping to zero.
type "no"
wait_ms 1600

# ── 10. Clear filter ─────────────────────────────────────────────
key "escape"
wait_ms 800

# ── 11. Click a session row → focus flips to that pty ────────────
# Rows are TAB_H=4 tall starting at y=5; row 2 (second session)
# occupies y=9..12. Clicking mid-row focuses the pane; the main
# editor area (col 33+) grows a matching-color accent bar down its
# left edge — the "picked" visual signal.
click 15 11
wait_ms 2000

# ── 12. Right-click the same row → color swatch menu ─────────────
# `session_tabs` rects intercept the right-click → opens the
# full row context menu. Items (in order): Pin · Move up · Move
# down · Move to top · Move to bottom · Auto sort · Rename… ·
# then the 9-color swatch tail (Green · Blue · Yellow · Orange ·
# Red · Purple · Cyan · Pink · None) with a ✓ on the current
# auto-picked color.
rclick 15 11
wait_ms 2000

# ── 13. Click "Color: Yellow" menu item ──────────────────────────
# Menu opens at anchor (15, 11) and lists 17 items downward. Order
# in the built menu (session_pane_methods.rs:265) plus the color
# tail from `session_color_menu_items_with_active`:
#   y=11+1  Pin
#   y=11+2  Move up
#   y=11+3  Move down
#   y=11+4  Move to top
#   y=11+5  Move to bottom
#   y=11+6  Auto sort
#   y=11+7  Rename…
#   y=11+8  Color: Green
#   y=11+9  Color: Blue
#   y=11+10 Color: Yellow    ← we want this
#   y=11+11 Color: Orange
#   y=11+12 Color: Red
#   y=11+13 Color: Purple
#   y=11+14 Color: Cyan
#   y=11+15 Color: Pink
#   y=11+16 Color: Auto
#   y=11+17 Close session
# Menu is positioned by anchor; menu items rects live in
# `app.rects.context_menu_items` and the click handler routes to
# the correct action. col=20 is well inside the menu chrome.
click 20 21
wait_ms 2500

# ── 14. Hero dwell ───────────────────────────────────────────────
# Composite frame: rail (5 rows w/ distinct color accents, "+ New
# session" chip at top, filter chip below it) + focused pane
# (yellow accent bar + mock Claude Code banner) + bufferline
# showing Pty tabs each color-matched. Frame the GIF ends on.
wait_ms 8000

# ── 15. Quit ─────────────────────────────────────────────────────
send '{"cmd":"quit"}'
