#!/usr/bin/env bash
# hero demo driver — pipes IPC commands into a running mnml so the
# hero-recorder script can capture a self-driving walkthrough.
#
# Called via ./demo/tapes/hero.record.sh (which spawns mnml under a
# PTY + asciinema, then runs this driver in the background).
#
# The whole flow is command-based (no keystroke chords) because
# mnml's IPC {"cmd":"run-command","id":"..."} fires registered
# commands directly — bypasses the chord-chain dispatcher, so
# nothing needs to type / land in a picker / race a modal.
#
# References:
#   src/ipc/mod.rs                   — IPC command JSON schema
#   src/command.rs                   — registered command IDs
#   demo/workspace/                  — demo files this drives against
#   demo/tapes/frames/hero/          — 8 sampled review frames (post-render)
#
# Budget: ~85s. Density over leisure — user asked for "show all the
# things off, get people enticed". Each beat gets a comment naming
# the ~timestamp so a downstream frame reviewer can pattern-match
# frame_NN against the intended screen state.
set -euo pipefail

WS="${MNML_DEMO_WORKSPACE:-$(cd "$(dirname "$0")/../workspace" && pwd)}"
CMD="$WS/.mnml/ipc/command"

# ── Wait for mnml to boot ──────────────────────────────────────────
# mnml writes .mnml/ipc/screen.txt on first paint. Poll until it
# exists + has content, then give one extra beat for the welcome
# view to settle.
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
hover() { send "{\"cmd\":\"hover\",\"col\":$1,\"row\":$2}"; }
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Beats (target ~85s)
# t=00.0  1  welcome        ASCII logo + git branch dwell
# t=01.4  2  activity sweep 5 sections — file tree, HTTP, integrations, agents, git, notes
# t=11.4  3  editor         open src/main.ts + LSP diagnostics
# t=14.4  4  picker         Ctrl+P fuzzy pick → store.ts
# t=18.0  5  which-key      Ctrl+K leader menu dwell
# t=21.0  6  ghost-text     seed a ghost suggestion → Tab accepts
# t=25.5  7  statusline     chip tour — 10 hovers × 1.4s each so the
#                              Info View cycles through each chip's help
#                              (#1140, added 2026-08-22)
# t=39.5  8  settings       overlay + row nav
# t=33.5  9  right cluster  claude usage ticker + coverage + mixr — multi-cycle dwell
# t=45.5 10  split right    view.split_right + open notes.http
# t=49.0 11  terminal       term.shell_bottom + run 2 commands
# t=57.0 12  hero shot      dwell on tree · editor · http · terminal composite
# t=61.5 13  quit           recorder trims tail, keeps last mnml frame

# Force standard keymap so `type` writes text directly (vim's
# Normal mode would treat every typed char as a motion command).
# The final GIF still shows the same UI; only the input dispatch
# differs. Users who want a vim-mode demo can start from vim
# default (`--input vim`) and the driver's behaviour stays sane
# because it uses registered commands, not raw chords.
run "editor.use_standard"
wait_ms 300

# ── 1. welcome ────────────────────────────────────────────────────
# Frame ~1: ASCII "mnml" splash + git branch line + right-panel hint
wait_ms 1400

# ── 2. activity-bar sweep ────────────────────────────────────────
# Frame ~2: each section swap shows a different info-panel copy at
# the bottom. Order follows the canonical top-to-bottom rail
# ordering (see ActivitySection::all in src/app/mod.rs) so viewers
# see the sections in the same order they'd walk in the real UI:
# Explorer → Git → Integrations → Sessions → Agents → Http → Notes.
# #1061 (2026-08-22) — was Http-first which was arbitrary and read
# as random when compared to the rail on screen.
run "view.activity_git";           wait_ms 1300
run "view.activity_integrations";  wait_ms 1600
run "view.activity_sessions";      wait_ms 1200
run "view.activity_agents";        wait_ms 1400
run "view.activity_http";          wait_ms 1400
run "view.activity_notes";         wait_ms 1000
run "view.activity_explorer";      wait_ms 600

# ── 3. editor ────────────────────────────────────────────────────
# Frame ~3: editor + LSP diagnostic squiggles + statusline chips
open "src/main.ts"
wait_ms 1600
key "down"; wait_ms 130
key "down"; wait_ms 130
key "down"; wait_ms 130
key "end"
wait_ms 800

# ── 4. Ctrl+P fuzzy file picker ─────────────────────────────────
run "picker.files"
wait_ms 1000
type "store"
wait_ms 700
key "enter"
wait_ms 1400
key "down"; wait_ms 130
key "down"; wait_ms 130
wait_ms 600

# ── 5. Which-key leader menu ─────────────────────────────────────
run "whichkey.leader"
wait_ms 2000
key "escape"
wait_ms 700

# ── 6. Ghost-text suggestion ─────────────────────────────────────
# Seed a plausible-looking ghost via the IPC `ghost` helper —
# bypasses the AI backend for deterministic timing. Renders as
# dim grey text starting at the cursor; Tab accepts + the text
# lands in the buffer.
#
# Frame ~5: cursor position + dim grey suggestion continuation
# Frame ~6: post-accept — the completion is real text now
open "src/store.ts"
wait_ms 700
# Jump to end-of-buffer via Ctrl+End (works in both vim's insert-
# mapped bindings and standard mode), then newline into a fresh
# blank line so ghost text renders in an obvious spot.
key "ctrl+end"
wait_ms 300
key "enter"; wait_ms 150
type "export function reset("
wait_ms 500
ghost "state: Store): Store {\\n  return { ...state, items: [] };\\n}"
wait_ms 1800
key "tab"
wait_ms 1300

# ── 7. Statusline chip tour ──────────────────────────────────────
# The statusline (row 34 on 140×36 geometry) carries a lot for
# such a thin strip — mode, buffer state, ghost-text backend,
# Jira / Bitbucket counts, Claude + Codex usage, coverage, mixr
# transport, Sonos destination, LSP diagnostics, clock. #1140:
# dwell over each chip cluster so the Info View below populates
# with a new hover-help card at each stop. Coordinates are
# calibrated for the default 140-col layout — each `hover` lands
# on a chip in the right lane. ~1.4s per stop, ~14s total.
#
# Frame ~7: info panel cycles through chip help cards.
#
# LEFT lane (mode + buffer):
hover 4 34;   wait_ms 1400  # mode chip (NORMAL / INSERT)
hover 18 34;  wait_ms 1400  # buffer name + dirty marker
# RIGHT lane (walking right to left along the powerline):
hover 130 34; wait_ms 1400  # clock
hover 122 34; wait_ms 1400  # Sonos destination
hover 114 34; wait_ms 1400  # mixr transport + brand
hover 106 34; wait_ms 1400  # coverage F%/C% cycler
hover 98 34;  wait_ms 1400  # Claude AI usage sparkline + urgency
hover 90 34;  wait_ms 1400  # Codex tokens
hover 82 34;  wait_ms 1400  # Bitbucket PRs count
hover 74 34;  wait_ms 1400  # Jira Work count

# ── 8. settings overlay ──────────────────────────────────────────
run "view.settings"
wait_ms 1700
key "down"; wait_ms 300
key "down"; wait_ms 300
key "down"; wait_ms 300
key "down"; wait_ms 400
key "escape"
wait_ms 700

# ── 9. Right cluster — Claude usage ticker + coverage + mixr ─────
# Dwell here long enough for the wall-clock-driven tickers to visibly
# rotate. Both the coverage chip (F↔C, 4s period) and the Claude usage
# ticker (per-account, 4s period) advance while we sit. ~12s total
# gives ~3 rotations — viewers register the animation without it
# feeling like dead air.
#
# Frame ~8: coverage/mixr/claude cluster mid-rotation
#
# We drive a slow cursor nudge in the current editor so the chip
# refresh cadence stays live (mnml's redraw is idle-throttled;
# without input it can coalesce paints). Each cursor keystroke
# forces a fresh draw, and the chip's ticker index re-samples
# system time on every render.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  key "left"; wait_ms 500
  key "right"; wait_ms 500
done

# ── 10. split right → HTTP request pane ──────────────────────────
run "view.split_right"
wait_ms 1000
open "requests/notes.http"
wait_ms 1800

# ── 11. terminal in the bottom half of the right leaf ────────────
# `term.shell_bottom` splits the *active* leaf vertically with the
# shell on the bottom — one command, one split. Final layout is
# tree · editor · (notes.http top / terminal bottom).
run "term.shell_bottom"
wait_ms 1400
type "ls src"
wait_ms 200
key "enter"
wait_ms 1200
type "cat package.json"
wait_ms 200
key "enter"
wait_ms 1300

# ── 12. hero shot ────────────────────────────────────────────────
# Dwell on the composite view: file tree · editor · HTTP request ·
# terminal. This is the frame the GIF ends on (recorder trims the
# mnml-quit escape sequence, so this stays visible as the static
# preview + the between-loops hold).
#
# Frame ~8 (last): the 4-pane hero composite
wait_ms 3000

# ── 13. quit ─────────────────────────────────────────────────────
send '{"cmd":"quit"}'
