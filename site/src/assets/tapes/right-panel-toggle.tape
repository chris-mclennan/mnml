# right-panel-toggle — open the right side panel, see the empty state,
# host the Outline pane, then close the panel (which evicts the host).
#
# Demonstrates the v2 right-panel shipped 2026-06-28:
#   1. open the panel (Ctrl+Shift+B / view.toggle_right_panel) → body
#      paints the empty-state hint:
#        " SIDE PANEL"
#        "  Nothing here yet."
#        "  :outline.show"
#        "  :lsp.diagnostics"
#        "  Hide with Ctrl+Shift+B."
#   2. `outline.show` routes the Outline pane *into* the panel —
#      header switches to " OUTLINE", editor body keeps full width.
#   3. close the panel — view.toggle_right_panel also nulls
#      right_panel_pane_id, closing the hosted Outline.
#
# Implementation note: VHS's terminal can't distinguish
# Ctrl+Shift+B from Ctrl+B without the Kitty keyboard protocol, and
# standard input mode (mnml's default) doesn't accept `:` as the
# cmdline opener. The tape uses mnml's file-IPC channel to fire
# `view.toggle_right_panel` + `outline.show` directly via the
# `run-command` verb. Driver: `right-panel-toggle-workspace/drive.sh`.
#
# Renders to: right-panel-toggle.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/right-panel-toggle.tape

Output site/src/assets/tapes/right-panel-toggle.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ────────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Type "cargo init --quiet --name right-panel-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Background driver — fires the panel-toggle + outline.show beats.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/right-panel-toggle-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml ."
Sleep 400ms
Enter
Sleep 3s

# Dismiss any first-launch overlay just in case.
Escape
Sleep 400ms

# Open a file so outline.show has an active editor to bind to.
Ctrl+P
Sleep 600ms
Type "main"
Sleep 400ms
Enter
Sleep 1.2s

# ── 1. driver fires view.toggle_right_panel (empty state) ────────────────
Sleep 3.5s

# ── 2. driver fires outline.show (OUTLINE hosted) ────────────────────────
Sleep 3.5s

# ── 3. driver fires view.toggle_right_panel (closes panel + Outline) ─────
Sleep 2s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1.2s
