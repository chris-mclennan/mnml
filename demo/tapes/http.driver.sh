#!/usr/bin/env bash
# HTTP request-pane demo driver — walks through mnml's .http /
# .curl client end-to-end: activity-bar entry → sidebar `/`
# filter routing → open a real .http file → Send → Response body
# with syntax colors → Timeline waterfall → Cookies (Set-Cookie
# parsed) → Auth tab (Bearer / Basic / API-Key selector).
#
# Deterministic — hits the local mock server at localhost:7071
# (demo/server/server.py) which is auto-spawned by `mnml --demo`
# and serves demo/fixtures/api/session.json with realistic
# Set-Cookie headers so the Cookies tab has something to show.
#
# References:
#   src/ipc/mod.rs                        — IPC command JSON schema
#   src/request_pane.rs                   — EditTab / ResponseTab enums
#   src/tui/handlers/pane.rs              — Ctrl+]/[ + Ctrl+arrow cycles
#   src/app/layout.rs::set_activity_section — HTTP entry opens a pane
#   src/tui/handlers/pane.rs:2989         — `/` on empty URL → sidebar filter
#   demo/workspace/requests/tour.http     — the request this drives
#   demo/fixtures/api/session.json        — the response body
#
# Output → site/public/media/http.gif via hero.record.sh's
# TAPE_NAME=http.
#
# Budget: ~38s. Beat comments name their target timestamp so a
# frame reviewer can pattern-match frame_NN → intended screen state.
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
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Standard keymap so raw `/` land as text (vim Normal mode maps `/`
# to search — would defeat the sidebar-filter-routing beat).
run "editor.use_standard"
wait_ms 300

# Beats (target ~38s)
# t=00.0  1  welcome dwell
# t=01.5  2  activity → HTTP: rail opens + blank Request pane
# t=04.5  3  `/` on empty URL → sidebar filter (2026-08-24 user ask)
# t=05.5  4  type "tour" → FILES narrows to tour.http
# t=07.5  5  Esc → clear + unfocus filter
# t=08.3  6  open requests/tour.http → Request pane populates
# t=10.5  7  http.send → Response fills with JSON body
# t=13.0  8  dwell on syntax-highlighted Body
# t=15.0  9  Ctrl+Right → Headers tab
# t=17.0 10  Ctrl+Right → Cookies tab (session + csrf Set-Cookie rows)
# t=20.0 11  Ctrl+Right → Timeline tab (DNS/Connect/TLS/TTFB waterfall)
# t=23.5 12  Ctrl+] → EditTab cycle Body → Headers
# t=25.0 13  Ctrl+] → EditTab cycle Headers → Auth (Bearer / Basic / API-Key)
# t=28.0 14  dwell on Auth kind selector
# t=32.0 15  quit

# ── 1. welcome dwell ────────────────────────────────────────────
wait_ms 1500

# ── 2. Activity → HTTP ──────────────────────────────────────────
# `view.activity_http` opens the HTTP rail AND (when no Request
# pane exists) auto-spawns a blank Postman-style pane with focus
# on the URL field. Focus lands in Pane (not Tree) so keystrokes
# go to the URL field.
run "view.activity_http"
wait_ms 3000

# ── 3. `/` on empty URL → sidebar filter ────────────────────────
# Recent user-ask feature (2026-08-24 — src/tui/handlers/pane.rs
# L2989): the URL field's first `/` keystroke, when the URL is
# empty AND the Http activity is active, routes to the sidebar's
# filter row instead of typing a literal path separator. Once the
# URL has any content, `/` is a URL literal again.
type "/"
wait_ms 800

# `view.focus_tree` shifts pane focus into the sidebar so subsequent
# chars land in the now-focused filter row. The `/` routing above
# flips `http_panel_filter_focused = true` but doesn't move focus
# (auto-opened Request pane keeps it) — the sidebar's char-absorb
# block gates on Focus::Tree, so without this the filter row stays
# lit but empty while chars keep typing into the URL. This is a
# tape polish, not a mnml UX statement: same net effect as the
# viewer clicking into the filter row after seeing it light up.
run "view.focus_tree"
wait_ms 200

# ── 4. Filter narrows FILES ─────────────────────────────────────
# Typing in the sidebar filter narrows every section
# (FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS /
# COLLECTIONS). "tour" is enough to isolate tour.http from the
# other seed .http files.
type "tour"
wait_ms 2000

# ── 5. Esc → clear + unfocus filter ─────────────────────────────
# Matches the sidebar-filter idiom (task #11 — Esc clears + drops
# focus on every activity panel's `/` filter).
key "escape"
wait_ms 800

# ── 6. Open the request file → pane populates ───────────────────
# .http / .curl / .rest open as Request panes by default (see
# app/layout.rs:508). The auto-opened preview pane gets replaced
# rather than accumulating a tab.
#
# Re-fire view.activity_http right before the open so the sidebar
# panel snaps back to the HTTP rail (Esc-from-Tree-focus on the
# filter drops us back into the workspace tree; without this
# re-arm, frames 3+ would show the workspace tree instead of the
# rail we spent the previous 3 beats setting up).
run "view.activity_http"
wait_ms 200
open "requests/tour.http"
wait_ms 2200

# ── 7. http.send → response fills ──────────────────────────────
# Fires the request against localhost:7071 (mock server auto-
# spawned by `mnml --demo`). Response headers include two
# Set-Cookie rows + X-Request-Id; body is fixtures/api/session.json.
run "http.send"
wait_ms 2500

# ── 8. Dwell on syntax-highlighted Body ─────────────────────────
# Default ResponseTab is Body — JSON pretty-printed with
# tree-sitter colors. Give viewers a beat to register the format
# before we start cycling tabs.
wait_ms 2000

# ── 9. Ctrl+Right → Headers tab ─────────────────────────────────
# ResponseTab order is Body → Headers → Cookies → Timeline → Tests.
# Ctrl+Right advances; the count next to "Headers" reflects the
# response header total.
key "ctrl+right"
wait_ms 2000

# ── 10. Ctrl+Right → Cookies tab ────────────────────────────────
# Task #1167 (2026-08-23) — Set-Cookie headers parsed into a
# name / value / attrs table. session + csrf both render with
# their dim attrs strip (HttpOnly, SameSite, Domain, Path,
# Max-Age).
key "ctrl+right"
wait_ms 3000

# ── 11. Ctrl+Right → Timeline tab ───────────────────────────────
# The Timeline tab is the "waterfall" the user asked to show —
# DNS resolve, TCP connect, TLS handshake, TTFB, download. On
# localhost the bars are tiny (single-digit ms per phase) but
# the shape reads unambiguously.
key "ctrl+right"
wait_ms 3500

# ── 12. Ctrl+] → EditTab Body → Headers ─────────────────────────
# EditTab::ALL order = [Params, Body, Headers, Auth, Vars, Source].
# The .http file parse lands us on Body (single-block file, has a
# body-less GET). Ctrl+] advances one step.
key "ctrl+]"
wait_ms 1500

# ── 13. Ctrl+] → EditTab Headers → Auth ─────────────────────────
# The Auth tab is the Bruno/Postman-style Authorization kind
# selector — Bearer / Basic / API-Key rows with an active-row
# indicator. Populated from the parsed request; None by default
# on a fresh .http file.
key "ctrl+]"
wait_ms 4000

# ── 14. Quit ───────────────────────────────────────────────────
send '{"cmd":"quit"}'
