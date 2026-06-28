# right-panel-ai-chat — open a Rust source file, open the right
# panel, fire `:ai.explain` and watch the AI chat host as a tab in
# the panel alongside the bufferline editor.
#
# Demonstrates the v4 AI routing shipped 2026-06-28:
#   1. open src/lib.rs in the editor (full width).
#   2. open the right panel (empty state).
#   3. ai.explain — `Pane::Ai` is created, but instead of splitting
#      the editor body, it lands in `app.right_panel_panes` as a new
#      tab. Header shows the tab strip with the AI chat title +
#      state marker (● asking / ✦ streaming / ✗ error / ✓ done).
#      Body shows the prompt, then streams the answer in-place.
#   4. if the panel column is narrower than 40 cells, a one-line
#      hint at the top of the body suggests "AI chat reads better
#      at 40+ cells — drag edge wider".
#
# Backend: this tape relies on `[ai] backend = "cli"` (mnml's
# default), which shells `claude -p <prompt>`. No ANTHROPIC_API_KEY
# is required. If `claude` isn't on PATH the pane still appears as
# a tab — viewer just sees the Asking → Error transition rather
# than Asking → Done.
#
# Implementation note: VHS's terminal can't send Ctrl+Shift+B and
# standard input mode doesn't accept `:`, so the open + toggle +
# ai.explain beats fire via mnml's file-IPC channel from
# `right-panel-ai-chat-workspace/drive.sh`.
#
# Renders to: right-panel-ai-chat.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/right-panel-ai-chat.tape

Output site/src/assets/tapes/right-panel-ai-chat.gif

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
# Background driver — opens lib.rs, toggles the panel, fires ai.explain.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/right-panel-ai-chat-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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
# ~1s  : driver opens src/lib.rs.
# ~4s  : view.toggle_right_panel (empty state).
# ~7s  : ai.explain (AI chat tab — Asking → Streaming → Done).
Sleep 16s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1.5s
