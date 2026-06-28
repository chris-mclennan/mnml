# right-panel-tabs — open the side panel, host TWO panes as tabs
# (Outline + Diagnostics), cycle with Ctrl+Shift+] / Ctrl+Shift+[,
# then click the × twice to close each tab in turn.
#
# Demonstrates the v3 tab-strip shipped 2026-06-28:
#   1. open src/lib.rs in the editor.
#   2. open the panel (Ctrl+Shift+B / view.toggle_right_panel) →
#      body paints the empty-state hint with the two ex commands.
#   3. outline.show → Outline becomes tab #1, header shows the
#      tab strip with `<file> ⌥<N>`.
#   4. lsp.diagnostics → Diagnostics joins as tab #2 — strip now
#      shows BOTH chips, Diagnostics is the active one.
#   5. Ctrl+Shift+[ (view.right_panel_prev_tab) → Outline active.
#   6. Ctrl+Shift+] (view.right_panel_next_tab) → Diagnostics active.
#   7. click × → active tab (Diagnostics) closes; Outline now active.
#   8. click × → Outline closes; panel returns to empty state.
#
# Implementation note: VHS's terminal can't distinguish Ctrl+Shift+B
# from Ctrl+B (or Ctrl+Shift+] from Ctrl+]) without the Kitty
# keyboard protocol, and standard input mode doesn't accept `:` as
# the cmdline opener. All 8 beats fire via mnml's file-IPC channel
# from `right-panel-tabs-workspace/drive.sh`. The × clicks read the
# live `right_panel_close` rect from `rects.json` so the synthesized
# coordinate always lines up with the rendered button.
#
# Renders to: right-panel-tabs.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/right-panel-tabs.tape

Output site/src/assets/tapes/right-panel-tabs.gif

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
Type "cargo init --quiet --lib --name right-panel-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Background driver — fires every beat (open, panel toggle, outline,
# diagnostics, prev tab, next tab, two × clicks) via IPC.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/right-panel-tabs-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml ."
Sleep 400ms
Enter
Sleep 4s

Escape
Sleep 600ms

# ── all beats fire from the IPC driver ───────────────────────────────────
# ~1s   : driver opens src/lib.rs.
# ~5s   : view.toggle_right_panel (empty state).
# ~8s   : outline.show (Outline tab #1).
# ~11s  : lsp.diagnostics (Diagnostics joins as tab #2).
# ~14s  : view.right_panel_prev_tab (cycle to Outline).
# ~17s  : view.right_panel_next_tab (cycle back to Diagnostics).
# ~20s  : click × (Diagnostics closes, Outline active).
# ~23s  : click × (Outline closes, empty state).
Sleep 25s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
