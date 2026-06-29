# vim-operator-inclusive — `cw` now behaves like `ce` (the vim
# canonical): it deletes the word but PRESERVES the trailing
# whitespace. Demoes the 2026-06-29 fix.
#
# Beats (driven via IPC from
# `vim-operator-inclusive-workspace/drive.sh`):
#   1. open demo.txt — "The quick brown fox jumps"
#   2. /brown<Enter><Esc> — cursor at start of "brown"
#   3. cw  — deletes "brown" (excluding the space), enter insert
#   4. BIG — replaces it
#   5. <Esc> — line is now "The quick BIG fox jumps"
#   6. dd  — linewise delete (sanity check)
#   7. u   — undo so :reg has the "1 register populated
#   8. :reg<Enter> — toast shows yank + delete registers
#
# Renders to: vim-operator-inclusive.gif
#
# Regenerate:
#     cargo build --release
#     vhs site/src/assets/tapes/vim-operator-inclusive.tape

Output site/src/assets/tapes/vim-operator-inclusive.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    14
Set Width       1200
Set Height      560
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ────────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d -t mnml-vim.XXXXXX) && cd $MNML_DEMO"
Enter
Type "echo 'The quick brown fox jumps' > demo.txt"
Enter
Type "git init --quiet && git config user.email demo@mnml.sh && git config user.name 'mnml demo' && git add demo.txt && git commit -q -m init"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/vim-operator-inclusive-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml (vim input mode is what's under test) ────────────────────
Type "$HOME/Projects/mnml/target/release/mnml --input vim ."
Sleep 400ms
Enter
Sleep 4s

Escape
Sleep 600ms

# ── all beats fire from the IPC driver ───────────────────────────────────
Sleep 12s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
