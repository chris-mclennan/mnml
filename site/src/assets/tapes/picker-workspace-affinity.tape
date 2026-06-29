# picker-workspace-affinity — Ctrl+P + "lib" lands on the LOCAL
# src/lib.rs even when a cross-workspace recent lib.rs exists. The
# 2026-06-29 polish tags every picker item with a priority (2 = current
# workspace, 1 = cross-workspace recent) and sorts (priority desc,
# score desc) so the local file always wins.
#
# Setup happens in the Hide block:
#   - tmpdir as the active workspace (with a real src/lib.rs)
#   - sibling tmpdir with its own src/lib.rs
#   - seed the active workspace's `.mnml/session.json` with the
#     sibling lib.rs as a recent_files entry
#
# Renders to: picker-workspace-affinity.gif
#
# Regenerate:
#     cargo build --release
#     vhs site/src/assets/tapes/picker-workspace-affinity.tape

Output site/src/assets/tapes/picker-workspace-affinity.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 60ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ────────────────────────────────────────────────────────
Hide
# sibling workspace — a fake "other project" with its own lib.rs
Type "MNML_SIBLING=$(mktemp -d -t mnml-sibling.XXXXXX)"
Enter
Type "mkdir -p $MNML_SIBLING/src && echo 'pub fn sibling() {}' > $MNML_SIBLING/src/lib.rs"
Enter
# active workspace — what mnml will open
Type "MNML_DEMO=$(mktemp -d -t mnml-demo.XXXXXX) && cd $MNML_DEMO"
Enter
Type "cargo init --quiet --lib --name affinity-demo 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
# Seed recent_files with the sibling lib.rs so it shows up as a
# cross-workspace recent (priority 1) — the local src/lib.rs from the
# tree walk gets priority 2, and the sort keeps the local one first.
Type "printf '{\"workspace\":\"%s\",\"open\":[],\"recent_files\":[\"%s/src/lib.rs\"]}' $MNML_DEMO $MNML_SIBLING > .mnml/session.json"
Enter
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/picker-workspace-affinity-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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
Sleep 8s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
