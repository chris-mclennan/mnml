# shift-f10-context-menu — VS Code / macOS Shift+F10 keyboard-equivalent
# for right-click, demonstrated for both focus surfaces:
#
#   1. Focus::Tree → Shift+F10 opens the tree-row context menu over
#      the selected row (Open / Open in split / Reveal in Finder /
#      …). Esc closes it.
#   2. Focus::Pane → open a file so the editor pane is focused +
#      the bufferline tab is active. Shift+F10 opens the bufferline
#      tab context menu (Pin tab / Close / Close others /
#      Split right / …).
#
# Wired by `view.context_menu_at_focus` (registered in command.rs,
# default chord Shift+F10). Anchor for the tree menu is the rail's
# left edge + the selected row's y; anchor for the pane menu is the
# active bufferline tab's rect.
#
# Implementation note: VHS's xterm doesn't reliably forward
# `Shift+F10` as a distinguished modified-CSI sequence — F10 alone
# opens the menu bar instead. The tape uses mnml's file-IPC channel
# to fire `view.context_menu_at_focus` directly via `run-command`,
# which is exactly what the Shift+F10 binding fires. Driver script:
# `shift-f10-context-menu-workspace/drive.sh`.
#
# Renders to: shift-f10-context-menu.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/shift-f10-context-menu.tape

Output site/src/assets/tapes/shift-f10-context-menu.gif

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
Type "cargo init --quiet --name shift-f10-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Background driver — fires view.context_menu_at_focus at two beats
# (~6s after launch for the tree-row menu, ~12s for the tab menu).
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/shift-f10-context-menu-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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
Escape
Sleep 500ms

# ── 1. tree-row context menu ─────────────────────────────────────────────
# Mnml launches with Focus::Tree, so the cursor is already on the
# workspace header row. Step down twice so we land on a real entry
# (e.g. src/ or the cargo init artifacts). The driver fires
# view.context_menu_at_focus ~6s after IPC came up — should land
# right around here.
Down
Sleep 300ms
Down
Sleep 400ms
# Driver fires view.context_menu_at_focus here (tree-row menu).
Sleep 2.5s

# Close the menu.
Escape
Sleep 800ms

# ── 2. shift focus into the editor → bufferline tab menu ─────────────────
# The driver opens src/main.rs via an IPC `open` verb (avoids
# Ctrl+P picking up cross-workspace recent files). open_path's
# reveal_pane sets focus = Focus::Pane, so the next driver beat
# routes through the second branch of open_context_menu_at_focus
# → bufferline tab menu (Pin tab / Close / Split right / …).
Sleep 4s
# Driver fires view.context_menu_at_focus here (tab menu).
Sleep 2.5s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1s
