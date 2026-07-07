# http-edit-split — the Request pane's `[⇔]` chip opens a side-by-side
# edit split, lets you view + edit two Edit-view tabs at once, and the
# 1-cell divider between them cycles the ratio.
#
# Flow recorded:
#   1. Open `api.http` — Request pane in Edit view (Body tab).
#   2. Click the `[⇔]` chip (top-right of the Request block's border
#      row, immediately left of the `[▥▤]` split-orientation chip).
#      The edit area splits — primary (Body) on the left, secondary
#      copy on the right. Split-open state = cyan `⇔`.
#   3. Click the right-side "Vars" tab — the secondary side now
#      shows Vars while the primary keeps showing Body.
#   4. Click the 1-cell divider three times — ratio cycles
#      50 → 70 → 30 → 50.
#   5. Click the `[⇔]` chip again — split closes; primary Body view
#      spans the full pane width.
#
# Implementation note: VHS has no mouse syntax, so a background driver
# (`http-edit-split-workspace/drive.sh`) uses mnml's file-IPC channel
# to reproduce the interactions. Toggle chip clicks fire the same
# `http.toggle_edit_split` command the chip's mouse-down handler
# runs (identical behavior); divider + secondary-tab clicks are
# fired as `click` IPC commands with columns discovered by parsing
# the current `screen.txt`.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-edit-split.tape

Output site/src/assets/tapes/http-edit-split.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    12
Set Width       1600
Set Height      900
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Sleep 200ms
# Pre-seed a .http request whose Body / Vars tabs are both interesting
# so the split shows meaningfully different content on each side.
Type "mkdir -p .mnml/env && touch .mnml/.welcomed"
Enter
Sleep 100ms
Type `printf '%s\n' 'BASE_URL=https://api.example.com' 'API_TOKEN=demo-token' > .mnml/env/dev.env`
Enter
Sleep 100ms
Type `printf 'default_env = "dev"\n' > .mnml/config.toml`
Enter
Sleep 100ms
Type `printf '%s\n' 'POST {{BASE_URL}}/users' 'Authorization: Bearer {{API_TOKEN}}' 'Content-Type: application/json' '' '{ "name": "Ada", "email": "ada@example.com" }' > api.http`
Enter
Sleep 100ms
Type "git init -q && git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Sleep 100ms
# Background driver — opens the file, toggles the split, clicks the
# right-side Vars tab + divider cycle, toggles the split closed.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/http-edit-split-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Sleep 100ms
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml ."
Sleep 400ms
Enter
Sleep 3s

# Dismiss welcome overlay just in case.
Escape
Sleep 500ms

# ── beat 1: file opens, edit split toggles OPEN (~1.8s + 1.6s) ──────────
# Driver fires `open api.http` at ~t=1.2s (into IPC handshake) and
# `http.toggle_edit_split` at ~t=3.0s. Give both a beat to paint.
Sleep 3s

# ── beat 2: right-side Vars tab click ───────────────────────────────────
Sleep 1.6s

# ── beat 3: divider cycles (three clicks, ~1s apart) ────────────────────
Sleep 3.2s

# ── beat 4: edit split toggles CLOSED ───────────────────────────────────
Sleep 1.6s

# ── settle on the final frame ───────────────────────────────────────────
Sleep 1s
