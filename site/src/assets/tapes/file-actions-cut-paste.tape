# file-actions-cut-paste — VS Code / Finder style Ctrl+X / Ctrl+V in
# the tree pane.
#
# mnml's tree pane accepts file-manager clipboard shortcuts when it
# has focus:
#   • Ctrl+X → `file.cut`   — stages the selected row; paste = move
#   • Ctrl+C → `file.copy`  — stages the selected row; paste = copy
#   • Ctrl+V → `file.paste` — pastes into the selected row's dir
#                              (or the workspace root if a file row
#                              is selected)
#   • Ctrl+D → `file.duplicate`
#
# See `src/tui/handlers/pane.rs` for the tree-focus Ctrl+X/C/V/D
# key map, and `src/app/mod.rs::file_paste_into` + `file_stage_clipboard`
# for the semantics (cut vs copy, dest resolution, tree refresh,
# toast).
#
# Flow recorded:
#   1. Focus starts on the tree (fresh workspace, welcome dismissed).
#   2. Walk the cursor to `Cargo.toml` via Down.
#   3. Ctrl+X → toast `cut Cargo.toml`, clipboard staged as move.
#   4. Walk the cursor to `src/` via Down.
#   5. Ctrl+V → paste into src/. `fs::rename(Cargo.toml, src/Cargo.toml)`.
#      Toast: `moved 1 item into src`. Tree refreshes; the row
#      disappears from the workspace root and appears under src/.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/file-actions-cut-paste.tape

Output site/src/assets/tapes/file-actions-cut-paste.gif

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
Type "mkdir -p .mnml src && touch .mnml/.welcomed"
Enter
Sleep 100ms
# Populate the workspace with recognizable file rows.
Type `printf '%s\n' '[package]' 'name = "demo"' 'version = "0.1.0"' > Cargo.toml`
Enter
Sleep 100ms
Type `printf '# demo\n' > README.md`
Enter
Sleep 100ms
Type `printf 'fn main() { println!("hi"); }\n' > src/main.rs`
Enter
Sleep 100ms
# No `git init` here — a `.git` dir would pull ~10 git-internal rows
# into the tree walk and blow the down-count off.

Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/file-actions-cut-paste-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
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

# ── beat 1: cursor walks to Cargo.toml (~2s) ──────────────────────────
Sleep 2s

# ── beat 2: Ctrl+X → cut toast (~1.6s) ───────────────────────────────
Sleep 1.6s

# ── beat 3: cursor walks to src/ (~1s) ────────────────────────────────
Sleep 1s

# ── beat 4: Ctrl+V → moved toast + tree refresh (~2.5s) ──────────────
Sleep 2.5s

# ── settle ──────────────────────────────────────────────────────────
Sleep 1s
