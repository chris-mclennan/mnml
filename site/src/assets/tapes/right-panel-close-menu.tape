# right-panel-close-menu — right-click an inactive tab to "Close other
# tabs"; then re-fire two tabs and press Ctrl+Alt+W to close the active.
#
# Beats (driven via IPC from
# `right-panel-close-menu-workspace/drive.sh`):
#   1. open src/lib.rs
#   2. view.toggle_right_panel       (empty state)
#   3. outline.show                  (tab #1)
#   4. lsp.diagnostics               (tab #2 — active)
#   5. find.grep "fn"<Enter>         (tab #3 — Grep results, active)
#   6. right-click tab #1 (Outline)  (menu opens: Switch / Close / Close other / Close all / Hide)
#   7. click "Close other tabs"      (only the right-clicked tab remains)
#   8. outline.show + lsp.diagnostics (back to 2 tabs)
#   9. view.right_panel_close_tab    (Ctrl+Alt+W — active tab closes)
#
# Renders to: right-panel-close-menu.gif
#
# Regenerate:
#     cargo build --release
#     vhs site/src/assets/tapes/right-panel-close-menu.tape

Output site/src/assets/tapes/right-panel-close-menu.gif

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
Type "cargo init --quiet --lib --name close-menu-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Background driver — fires every beat (open, panel toggle, 3 hosts,
# right-click, menu pick, 2 hosts again, Ctrl+Alt+W chord-equivalent).
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/right-panel-close-menu-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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
Sleep 23s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
