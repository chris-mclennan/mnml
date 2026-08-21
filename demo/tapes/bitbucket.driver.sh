#!/usr/bin/env bash
# Bitbucket integration demo driver — spawns the Bitbucket PRs pane
# (`mnml-forge-bitbucket --only prs`) against the mock server on
# localhost:7071.
#
# Prereqs beyond hero.driver.sh's:
#   - `mnml-forge-bitbucket` on PATH (install with
#     `mnml-forge-bitbucket --install` from the sibling repo,
#     then `cargo install --path .`)
#   - The mock server auto-spawns via `mnml --demo`.
#
# Output → site/public/media/bitbucket.gif via
# hero.record.sh's TAPE_NAME=bitbucket.
#
# Budget: ~30s. Focused on Bitbucket's key value prop — PR list with
# inline preview (expandable row → diffstat + summary).
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
# command registry (see jira.driver.sh's note on the id mismatch).
# Env vars come from hero.record.sh's INNER_SCRIPT exports.
open_pty() {
  local argv_json="$1"
  send "{\"cmd\":\"open-pty\",\"command\":$argv_json}"
}

# Beats (target ~30s)
# t=00.0  1  welcome dwell
# t=01.5  2  open Bitbucket PRs pane
# t=06.5  3  arrow-nav down through the PR list
# t=10.5  4  expand row (Enter) → diffstat + summary preview
# t=16.0  5  collapse row, move to next PR
# t=20.0  6  hero shot dwell on the list
# t=26.0  7  quit

# ── 1. Welcome dwell ──────────────────────────────────────────────
wait_ms 1400

# ── 2. Open the Bitbucket PRs pane ────────────────────────────────
# Direct Pty spawn with `env HOME=<demo-sibling-home>` — see
# jira.driver.sh + hero.record.sh's DEMO_SIBLING_HOME block. Sibling
# reads mock fixtures at
# demo/fixtures/bitbucket/2.0/repositories/bloomlabs/notely/pullrequests.json.
SHOME="${MNML_DEMO_SIBLING_HOME:-}"
if [ -z "$SHOME" ]; then
  echo "[bitbucket.driver] MNML_DEMO_SIBLING_HOME unset — sibling would leak real data" >&2
  send '{"cmd":"quit"}'
  exit 1
fi
open_pty "[\"env\",\"HOME=$SHOME\",\"mnml-forge-bitbucket\",\"--only\",\"prs\"]"
wait_ms 4500

# ── 3. Arrow-nav through the PR list ─────────────────────────────
key "down"; wait_ms 550
key "down"; wait_ms 550
key "down"; wait_ms 700

# ── 4. Expand row (Enter) → inline preview ───────────────────────
# The sibling toggles the current row from collapsed → expanded with
# Enter — shows the diffstat + summary in-place. Data from
# pullrequests/87.json + 87/comments.json + 87/diffstat.json.
key "enter"
wait_ms 3800

# ── 5. Collapse + move to next PR ────────────────────────────────
key "enter"; wait_ms 500
key "down";  wait_ms 500
key "enter"
wait_ms 2500

# ── 6. Hero shot ─────────────────────────────────────────────────
wait_ms 3000

# ── 7. Quit ──────────────────────────────────────────────────────
send '{"cmd":"quit"}'
