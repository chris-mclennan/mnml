# tree-up-navigation — click the `..` row at the top of the file tree
# to climb the workspace root one level.
#
# The `..` row sits above the first tree entry (drawn by the tree's
# `paint_up_row` block, gated on `app.workspace.parent().is_some()`).
# Its click rect is exposed as `tree_up_row` (dumped 2026-07-07). The
# click handler in `mouse/down_left.rs` calls
# `App::navigate_workspace_up()` which swaps `app.workspace` for its
# parent, resets the tree cursor, refreshes git, re-picks the active
# repo, and updates the workspace chip in the statusline.
#
# Flow recorded:
#   1. Launch mnml at `<tempdir>/inner/` — a nested workspace so the
#      parent (`<tempdir>/`) has different content and is visibly
#      distinct.
#   2. Wait for first paint. Cursor over the tree.
#   3. Click the `..` row (top of the tree, just above the first
#      folder entry).
#   4. mnml climbs to the parent workspace — the tree, workspace
#      chip (statusline), and git rail all repoint at the new root.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/tree-up-navigation.tape

Output site/src/assets/tapes/tree-up-navigation.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
Hide
# `parent/` has one file layout; `parent/inner/` (where mnml launches) has
# a different one. On up-navigation the tree flips from inner/ contents
# to parent/ contents.
Type "MNML_DEMO=$(mktemp -d) && mkdir -p $MNML_DEMO/parent/inner && cd $MNML_DEMO/parent/inner"
Enter
Sleep 200ms
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
Sleep 100ms
Type `printf 'fn main() {}\n' > inner_main.rs`
Enter
Sleep 100ms
Type `printf '# inner\n' > INNER_NOTES.md`
Enter
Sleep 100ms
# The parent has different files so the climb is visually obvious.
Type `printf '[workspace]\n' > $MNML_DEMO/parent/PARENT.toml`
Enter
Sleep 100ms
Type `printf '# parent\n' > $MNML_DEMO/parent/PARENT_NOTES.md`
Enter
Sleep 100ms
# Also seed a `.mnml/.welcomed` in the parent so climbing there doesn't
# open the welcome overlay.
Type "mkdir -p $MNML_DEMO/parent/.mnml && touch $MNML_DEMO/parent/.mnml/.welcomed"
Enter
Sleep 100ms
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/tree-up-navigation-workspace/drive.sh $MNML_DEMO/parent/inner &) 2>/dev/null"
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

Escape
Sleep 500ms

# ── beat 1: inner workspace visible (~1.5s) ──────────────────────────
Sleep 1.5s

# ── beat 2: click `..` → tree flips to parent (~2.6s) ────────────────
Sleep 3s

# ── settle ──────────────────────────────────────────────────────────
Sleep 1.5s
