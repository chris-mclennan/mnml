# spend-report-bg-thread — :ai.spend_today opens the SpendReport pane
# with a " · computing…" title-bar chip while the per-workspace ledger
# is summed on a worker thread; when the worker finishes the chip
# disappears and a "today: N sessions · $X.XXXX" toast fires.
#
# Renders to: spend-report-bg-thread.gif
#
# Beats are driven from
# `spend-report-bg-thread-workspace/drive.sh` via IPC:
#   ~1s   open src/lib.rs (background fill)
#   ~3s   ai.spend_today  (pane opens with " · computing…" chip)
#  3-5s   worker drains, snapshot fills body, totals toast appears
#
# Regenerate:
#     cargo build --release
#     vhs site/src/assets/tapes/spend-report-bg-thread.tape

Output site/src/assets/tapes/spend-report-bg-thread.gif

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
Type "cargo init --quiet --lib --name spend-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/spend-report-bg-thread-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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
Sleep 11s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
