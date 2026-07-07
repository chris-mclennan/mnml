# tree-alt-drag-copy — Alt-hold + drag a file row onto a folder row.
# Alt-drag copies immediately; plain drag prompts for confirmation.
#
# Flow recorded:
#   1. Alt-hold + press on `Cargo.toml`.
#   2. Drag over to `docs/`.
#   3. Release on `docs/`. `end_tree_drag` sees the drag was primed
#      with `copy_instead_of_move = true` and calls
#      `copy_recursively(Cargo.toml, docs/Cargo.toml)` — no prompt.
#      Toast: `copied → docs/Cargo.toml`. Tree refreshes and shows
#      Cargo.toml at both the workspace root AND inside docs/.
#
# See `src/app/mod.rs::end_tree_drag` for the two paths:
#   • plain drag  → confirms with `TreeMoveConfirm` prompt
#   • alt-drag    → copies immediately (Finder / VS Code convention)
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/tree-alt-drag-copy.tape

Output site/src/assets/tapes/tree-alt-drag-copy.gif

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
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Sleep 200ms
Type "mkdir -p .mnml docs && touch .mnml/.welcomed"
Enter
Sleep 100ms
Type `printf '%s\n' '[package]' 'name = "demo"' > Cargo.toml`
Enter
Sleep 100ms
Type `printf '# demo\n' > README.md`
Enter
Sleep 100ms
Type `printf '# docs stub\n' > docs/README.md`
Enter
Sleep 100ms
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/tree-alt-drag-copy-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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

# ── beat 1: Alt+MouseDown on Cargo.toml (~0.4s) ─────────────────────────
Sleep 1.5s

# ── beat 2: drag cursor to docs/ (~1s) ──────────────────────────────────
Sleep 1.4s

# ── beat 3: MouseUp on docs/ → immediate copy + toast (~2.4s) ──────────
Sleep 3s

# ── settle ──────────────────────────────────────────────────────────
Sleep 1s
