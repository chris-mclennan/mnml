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

# ── 1. Welcome dwell ──────────────────────────────────────────────
wait_ms 1400

# ── 2. Show the Integrations activity section ────────────────────
# Users see the Integrations panel populate with the sibling chips
# — Jira is one of them.
run "view.activity_integrations"
wait_ms 2400

# ── 3. Open the Jira Boards integration pane ─────────────────────
# `jira_boards.open` (from ~/.config/mnml/integrations/jira_boards.toml)
# runs `:term mnml-tracker-jira --only boards` — spawns the sibling
# as a Pty pane. The sibling talks to the demo mock server at
# localhost:7071 for populated ticket data (per
# demo/workspace/.mnml/integrations/jira.override.toml).
run "jira_boards.open"
wait_ms 4500

# ── 4. Nudge the board a little ──────────────────────────────────
# Give the sibling's keybinds a chance to render — arrow-nav through
# cards, dwell on a highlighted one.
key "down"; wait_ms 600
key "down"; wait_ms 600
key "right"; wait_ms 800
key "down"; wait_ms 700
key "up"; wait_ms 500

# ── 5. Hero shot ──────────────────────────────────────────────────
# Dwell on the loaded board so the ending frame is legible.
wait_ms 3000

# ── 6. Quit ──────────────────────────────────────────────────────
send '{"cmd":"quit"}'
