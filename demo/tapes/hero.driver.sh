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
# 4  settings       (overlay, navigate rows)
# 5  splits + reqs  (split → open notes.http on the right)
# 6  terminal       (split_down → open Pty running `ls src`)
# 7  hero shot      (dwell on all three pane types side-by-side)
# 8  quit           (recorder trims tail so the last drawn frame stays)

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

# ── 4. settings overlay ──────────────────────────────────────────
run "view.settings"
wait_ms 2200
key "down"; wait_ms 320
key "down"; wait_ms 320
key "down"; wait_ms 320
key "down"; wait_ms 450
key "escape"
wait_ms 800

# ── 5. split right → HTTP request pane ───────────────────────────
run "view.split_right"
wait_ms 1200
open "requests/notes.http"
wait_ms 2200

# ── 6. split down → Pty terminal ─────────────────────────────────
run "view.split_down"
wait_ms 1100
run "term.shell"
wait_ms 1800
type "ls src"
wait_ms 250
key "enter"
wait_ms 1600
type "cat package.json 2>/dev/null || echo hero.demo"
wait_ms 250
key "enter"
wait_ms 1800

# ── 7. hero shot ─────────────────────────────────────────────────
# Dwell on the composite view: file tree · editor · HTTP request
# · terminal. This is the frame the GIF ends on (recorder trims
# the mnml-quit escape sequence, so this stays visible during the
# loop hold and as the static preview).
wait_ms 3200

# ── 8. quit ──────────────────────────────────────────────────────
send '{"cmd":"quit"}'
