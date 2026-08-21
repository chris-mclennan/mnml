#!/usr/bin/env bash
# Ghost-text demo driver — types a plausible function stub in an
# editor pane and lets a seeded ghost suggestion complete it. Uses
# the IPC `ghost` command (src/ipc/mod.rs) to bypass the AI backend
# so the tape is deterministic (no API round-trip variance, no
# API key needed).
#
# The real ghost-text path (Cursor-style inline suggestions from the
# Anthropic API or a local fim-engine model) has the same UX — a dim
# grey continuation appears at the cursor and Tab accepts it — this
# tape just seeds a canned suggestion for reproducibility.
#
# Output → site/public/media/ghost-text.gif via
# hero.record.sh's TAPE_NAME=ghost-text.
#
# Budget: ~25s. Focused on ghost-text's key value prop — type a
# function signature, see a suggestion appear, Tab to accept.
set -euo pipefail

WS="${MNML_DEMO_WORKSPACE:-$(cd "$(dirname "$0")/../workspace" && pwd)}"
CMD="$WS/.mnml/ipc/command"

# ── Wait for mnml to boot ──────────────────────────────────────────
for _ in $(seq 1 60); do
  if [ -s "$WS/.mnml/ipc/screen.txt" ]; then
    break
  fi
  sleep 0.1
done
sleep 2.2

send() { echo "$1" >> "$CMD"; }
run()  { send "{\"cmd\":\"run-command\",\"id\":\"$1\"}"; }
key()  { send "{\"cmd\":\"key\",\"key\":\"$1\"}"; }
type() { send "{\"cmd\":\"type\",\"text\":\"$1\"}"; }
open() { send "{\"cmd\":\"open\",\"path\":\"$1\"}"; }
ghost() { send "{\"cmd\":\"ghost\",\"text\":\"$1\"}"; }
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Standard keymap so `type` writes text directly.
run "editor.use_standard"
wait_ms 300

# Beats (target ~25s)
# t=00.0  1  welcome dwell + open store.ts
# t=03.0  2  jump to EOF, add a blank line
# t=03.8  3  type function signature — cursor blinks at open paren
# t=07.0  4  seed ghost suggestion — dim grey continuation appears
# t=09.5  5  dwell on the ghost text — user reads it
# t=12.0  6  Tab → accept → the completion is real text now
# t=14.0  7  small cursor nudge, dwell on the accepted code
# t=18.0  8  quit

# ── 1. Open store.ts ─────────────────────────────────────────────
open "src/store.ts"
wait_ms 2000

# ── 2. Jump to EOF + add a blank line ────────────────────────────
key "ctrl+end"
wait_ms 400
key "enter"; wait_ms 200
key "enter"
wait_ms 400

# ── 3. Type a plausible function signature ───────────────────────
# Typing char-by-char (mnml renders per keystroke) makes the typing
# feel real. `\n` in a type payload becomes Enter — we avoid it here
# so the whole signature lands on one line.
type "export function reset("
wait_ms 800

# Dismiss any LSP autocomplete popup that opened on `(`. Without
# this the popup overlaps the ghost text in the tape and readers
# can't tell what the ghost is offering. Escape closes the popup
# without moving the cursor.
key "escape"
wait_ms 300

# ── 4. Seed the ghost suggestion ─────────────────────────────────
# `\\n` in the JSON payload becomes a real newline inside the
# suggestion (jq-style escaping — src/ipc/mod.rs's Type / Ghost
# handlers don't unescape further, so the text field carries
# literal characters after JSON parsing).
ghost "state: Store): Store {\\n  return { ...state, items: [] };\\n}"

# ── 5. Dwell on the ghost text ───────────────────────────────────
# 2.5s gives viewers time to see the dim grey completion + read
# the return statement. Longer than a typical IDE glimpse but this
# is a tape, not a live session.
wait_ms 2500

# ── 6. Tab → accept ──────────────────────────────────────────────
# `has_ghost_suggestion()` → `accept_ghost_suggestion()` — see
# src/tui/mod.rs:1997. The ghost text lands in the buffer at the
# cursor position; the ghost overlay clears.
key "tab"
wait_ms 2000

# ── 7. Small cursor nudge + dwell on the accepted code ───────────
key "up"; wait_ms 400
key "up"; wait_ms 400
key "home"
wait_ms 3000

# ── 8. Quit ──────────────────────────────────────────────────────
send '{"cmd":"quit"}'
