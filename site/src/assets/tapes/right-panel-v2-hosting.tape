# right-panel-v2-hosting — open a Rust source file, open the right
# panel, host the Outline pane, swap to Diagnostics ("last-opened
# wins"), then click the panel's `×` to return to the empty state
# while keeping the panel column open.
#
# Flow shipped 2026-06-28:
#   1. open src/lib.rs in the editor (full width).
#   2. open the right panel (empty state).
#   3. outline.show routes the LSP Outline into the panel;
#      editor body keeps its full width — Outline lives in the
#      panel column with " OUTLINE" as the header.
#   4. lsp.diagnostics displaces the Outline (last-opened wins).
#      Header becomes " DIAGNOSTICS"; the Outline pane stays in
#      app.panes but no longer occupies the column.
#   5. click the `×` cell on the panel header — evicts the hosted
#      Diagnostics pane (right_panel_pane_id = None) but the
#      panel column stays open in its empty state.
#
# Implementation note: VHS's terminal can't distinguish
# Ctrl+Shift+B from Ctrl+B without the Kitty keyboard protocol, and
# standard input mode (mnml's default) doesn't accept `:` as the
# cmdline opener. The `×` cell is also mouse-driven. All five beats
# (open file, open panel, outline.show, lsp.diagnostics, click ×)
# are driven via mnml's file-IPC channel from
# `right-panel-v2-hosting-workspace/drive.sh`. The driver reads the
# live rect for `right_panel_close` from `rects.json` for the final
# click so the synthesized coordinate always lines up with the
# rendered button.
#
# Renders to: right-panel-v2-hosting.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/right-panel-v2-hosting.tape

Output site/src/assets/tapes/right-panel-v2-hosting.gif

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
# Use a tmpdir with a real cargo --lib project so lib.rs exists for
# the Outline / Diagnostics surfaces to bind to.
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Type "cargo init --quiet --lib --name right-panel-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Background driver — every meaningful beat is fired via IPC:
# `open` src/lib.rs, `run-command` for the toggle / outline /
# diagnostics, then a `click` on the panel's × button.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/right-panel-v2-hosting-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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

# ── all flow beats fire from the IPC driver ──────────────────────────────
# ~1s after IPC:  driver opens src/lib.rs into the editor.
# ~5s:            driver fires view.toggle_right_panel (empty state).
# ~7.5s:          driver fires outline.show (Outline hosted).
# ~10.5s:         driver fires lsp.diagnostics (joins the tab strip
#                 in v3; replaces the Outline in v2). Header now
#                 reads DIAGNOSTICS.
# ~13.5s:         driver reads `right_panel_close` from rects.json
#                 then synthesizes a `click` on its centre → active
#                 hosted pane is evicted, column stays open in its
#                 empty state.
Sleep 17s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
