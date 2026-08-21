#!/usr/bin/env bash
# Jira integration demo driver — spawns the Jira integration pane
# (which runs `mnml-tracker-jira --only boards` under a Pty) and
# lets it render against the mock server on localhost:7071.
#
# Prereqs beyond hero.driver.sh's:
#   - `mnml-tracker-jira` on PATH (install with `mnml-tracker-jira --install`
#     from the sibling repo, then `cargo install --path .`)
#   - The mock server auto-spawns via `mnml --demo` (see main.rs:471).
#
# Output → site/public/media/jira.gif via hero.record.sh's TAPE_NAME=jira.
#
# Budget: ~30s. Focused on Jira's key value prop — sprint picker
# + card detail modal — per coordinator direction 2026-08-17.
# Skips the hero's activity-bar sweep (already covered there).
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
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }
# Spawn a Pty pane via IPC — bypasses the integration-manifest
# command registry (which currently doesn't ship `jira_boards.open`
# in the demo workspace because the override.toml filename uses
# the legacy id `jira` not the current sibling id `jira_boards`).
# Env vars come from hero.record.sh's INNER_SCRIPT exports.
open_pty() {
  local argv_json="$1"
  send "{\"cmd\":\"open-pty\",\"command\":$argv_json}"
}

# Beats (target ~30s)
# t=00.0  1  welcome dwell
# t=01.5  2  open Jira Boards pane (mnml-tracker-jira sibling under Pty)
# t=06.5  3  arrow-nav down through card list
# t=10.5  4  open card detail (Enter)
# t=15.5  5  close card, sprint switch nudge
# t=20.5  6  hero shot dwell
# t=26.0  7  quit

# ── 1. Welcome dwell ──────────────────────────────────────────────
wait_ms 1400

# ── 2. Open the Jira Boards integration pane ─────────────────────
# Direct Pty spawn instead of `run "jira_boards.open"` — see the
# rationale in hero.record.sh's `DEMO_SIBLING_HOME` block. The
# sibling hardcodes its config + token paths to $HOME/.config/…,
# so we wrap the invocation with `env HOME=<throwaway>` seeded
# with a demo config pointing at localhost:7071/jira (mock).
# Without this the sibling loads the user's REAL Jira config and
# shows their real tickets in the tape (public leak).
SHOME="${MNML_DEMO_SIBLING_HOME:-}"
if [ -z "$SHOME" ]; then
  echo "[jira.driver] MNML_DEMO_SIBLING_HOME unset — sibling would leak real data" >&2
  send '{"cmd":"quit"}'
  exit 1
fi
open_pty "[\"env\",\"HOME=$SHOME\",\"mnml-tracker-jira\",\"--only\",\"boards\"]"
wait_ms 4500

# ── 3. Arrow-nav through the board ───────────────────────────────
# Give the sibling's keybinds a chance to render — arrow-nav through
# cards, dwell on a highlighted one.
key "down"; wait_ms 500
key "down"; wait_ms 500
key "down"; wait_ms 700

# ── 4. Open card detail (Enter) ──────────────────────────────────
# The sibling opens a detail modal on Enter — description, comments,
# subtasks. Data pulled from the mock's issue/NTL-XXX.json fixtures.
key "enter"
wait_ms 3500

# ── 5. Close card + sprint switch nudge ──────────────────────────
key "escape"; wait_ms 600
key "right"; wait_ms 700
key "down";  wait_ms 500
key "left";  wait_ms 500

# ── 6. Hero shot ──────────────────────────────────────────────────
# Dwell on the loaded board so the ending frame is legible.
wait_ms 3500

# ── 7. Quit ──────────────────────────────────────────────────────
send '{"cmd":"quit"}'
