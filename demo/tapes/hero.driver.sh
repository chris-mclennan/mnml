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
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Beats ────────────────────────────────────────────────────────────
# 1  welcome        (dwell on the ASCII logo + git branch line)
# 2  activity sweep (five sections — one info-panel copy per beat)
# 3  editor         (open main.ts, LSP diagnostics render)
# 4  picker         (Ctrl+P fuzzy file picker → open store.ts)
# 5  which-key      (Ctrl+K leader menu — discoverable chords)
# 6  settings       (overlay, navigate rows)
# 7  split right    (open notes.http beside the editor)
# 8  terminal       (term.shell_bottom — Pty in bottom half of the
#                    right leaf; runs `ls src`, `cat package.json`)
# 9  hero shot      (dwell on all pane types side-by-side)
# 10 quit           (recorder trims tail so the last drawn frame stays)

# ── 1. welcome ────────────────────────────────────────────────────
wait_ms 1600

# ── 2. activity-bar sweep ────────────────────────────────────────
run "view.activity_http";          wait_ms 2200
run "view.activity_integrations";  wait_ms 2200
run "view.activity_agents";        wait_ms 2000
run "view.activity_git";           wait_ms 1800
run "view.activity_notes";         wait_ms 1400
run "view.activity_explorer";      wait_ms 700

# ── 3. editor ────────────────────────────────────────────────────
open "src/main.ts"
wait_ms 1900
# Nudge the cursor so the statusline column indicator + LSP
# diagnostics dance a little.
key "down"; wait_ms 130
key "down"; wait_ms 130
key "down"; wait_ms 130
key "end"
wait_ms 1000

# ── 4. Ctrl+P fuzzy file picker ─────────────────────────────────
# Shows fuzzy file navigation and the "picker overlay → type →
# Enter" flow. Deferred in the initial hero pass (22f5668d) —
# added 2026-08-17 when we switched away from typing chords
# (`ctrl+p`) to firing the registered command directly (no chord
# race), which sidesteps the previous flakiness.
run "picker.files"
wait_ms 1200
type "store"
wait_ms 900
key "enter"
wait_ms 1600
# Nudge the cursor in the newly-opened store.ts so viewers see
# the second tab is active + the editor is populated.
key "down"; wait_ms 130
key "down"; wait_ms 130
wait_ms 700

# ── 5. Which-key leader menu ─────────────────────────────────────
# `Ctrl+K` opens the leader chord menu (nvchad muscle memory).
# Firing the command directly bypasses the chord dispatcher —
# same win as beat 4, no ctrl-chord flake.
run "whichkey.leader"
wait_ms 2400
key "escape"
wait_ms 700

# ── 6. settings overlay ──────────────────────────────────────────
run "view.settings"
wait_ms 2000
key "down"; wait_ms 320
key "down"; wait_ms 320
key "down"; wait_ms 320
key "down"; wait_ms 450
key "escape"
wait_ms 800

# ── 7. split right → HTTP request pane ───────────────────────────
run "view.split_right"
wait_ms 1200
open "requests/notes.http"
wait_ms 2200

# ── 8. terminal in the bottom half of the right leaf ─────────────
# 2026-08-17 — was `view.split_down` + `term.shell`. That fired
# TWO splits on the notes.http leaf: split_down duplicated the
# HTTP pane into a stacked empty-request pane, then term.shell
# (whose default placement is *beside*, not below — see
# `src/app/pty_methods.rs::open_shell`) added a third pane
# side-by-side. Result was a cramped 5-pane frame with three
# narrow columns on the right.
#
# `term.shell_bottom` splits the *active* leaf vertically with
# the shell on the bottom — one command, one split. Final layout
# is tree · editor · (notes.http top / terminal bottom) — the
# clean 4-pane "all types visible" hero shot the original brief
# called for.
run "term.shell_bottom"
wait_ms 1800
type "ls src"
wait_ms 250
key "enter"
wait_ms 1600
type "cat package.json 2>/dev/null || echo hero.demo"
wait_ms 250
key "enter"
wait_ms 1800

# ── 9. hero shot ─────────────────────────────────────────────────
# Dwell on the composite view: file tree · editor · HTTP request
# · terminal. This is the frame the GIF ends on (recorder trims
# the mnml-quit escape sequence, so this stays visible during the
# loop hold and as the static preview).
wait_ms 3200

# ── 10. quit ─────────────────────────────────────────────────────
send '{"cmd":"quit"}'
