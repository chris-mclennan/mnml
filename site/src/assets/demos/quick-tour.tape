# mnml — quick tour
#
# A ~30s demo showing the core editing + git flow:
#   1. launch in a sample workspace (vim mode)
#   2. open a file via Ctrl+P
#   3. edit in vim mode, `:w` save
#   4. open the git status pane via :git.status_pane
#   5. stage with `s`, commit with `c` + message
#   6. open the commit graph via :git.graph
#   7. swap input mode with `:set input=standard`
#   8. quick standard-mode edit + Ctrl+S save
#
# Vim mode runs first because the demo uses `:`-prefixed ex-commands to
# open the git panes — those only work in vim mode. The standard-mode
# slice at the end demonstrates the modeless flavor in contrast.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#
#     cargo build --release
#     vhs site/src/assets/demos/quick-tour.tape
#
# Then (optional) shrink with gifsicle:
#
#     gifsicle --optimize=3 --lossy=80 \
#         site/src/assets/demos/quick-tour.gif \
#         -o site/src/assets/demos/quick-tour.gif

Output site/src/assets/demos/quick-tour.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 60ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
# Build a fresh sample workspace each run so the tape is reproducible.
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Type "cargo init --quiet --name hello-mnml 2>/dev/null"
Enter
Type "git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Type "git add -A && git commit -q -m 'initial commit'"
Enter
Type "clear"
Enter
Sleep 300ms
Show

# ── launch (vim input style) ─────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml . --input vim"
Sleep 400ms
Enter
Sleep 3s

# Dismiss the first-launch welcome overlay if any.
Escape
Sleep 800ms

# ── 1. open a file via Ctrl+P ────────────────────────────────────────────
Ctrl+P
Sleep 1s
Type "main"
Sleep 800ms
Enter
Sleep 1.5s

# ── 2. vim-mode edit: open a new line under fn main(), type, :w ──────────
# Normal mode — `j` moves down to the `println!` line, `o` opens a new
# line below it and enters insert mode.
Type "j"
Sleep 250ms
Type "o"
Sleep 400ms
Type `    println!("hello from vim mode");`
Escape
Sleep 600ms
Type ":w"
Enter
Sleep 1.2s

# ── 3. open the git status pane via the ex-command ───────────────────────
Type ":git.status_pane"
Enter
Sleep 1.8s

# ── 4. stage the focused change with `s` ─────────────────────────────────
Type "s"
Sleep 1.2s

# ── 5. commit with `c`, then type a one-line message ─────────────────────
Type "c"
Sleep 800ms
Type "demo: greeting from vim mode"
Sleep 400ms
Enter
Sleep 1.8s

# Drop focus out of the GitStatus pane so the next `:` opens vim's
# ex-cmdline (the GitStatus key handler eats letters as its own
# shortcuts, not as cmdline text).
Escape
Sleep 400ms

# Hop back into the editor by re-opening main.rs — Ctrl+P + Enter on
# "main" lands focus on the editor pane in vim NORMAL mode.
Ctrl+P
Sleep 700ms
Type "main"
Sleep 500ms
Enter
Sleep 1s

# ── 6. open the commit graph (vim ex-cmd) ────────────────────────────────
Type ":git.graph"
Enter
Sleep 2.5s
Escape
Sleep 500ms

# ── 7. swap input mode → standard (showing the runtime keymap swap) ─────
# Same Ctrl+P trick to land on main.rs with the editor focused.
Ctrl+P
Sleep 600ms
Type "main"
Sleep 500ms
Enter
Sleep 900ms
Type ":set input=standard"
Enter
Sleep 1.5s

# ── 8. standard-mode edit: arrows + insert + Ctrl+S — no `i` needed ─────
Down
Sleep 200ms
Right@30ms 80
Sleep 200ms
Enter
Type `    println!("hello from standard mode");`
Sleep 400ms
Ctrl+S
Sleep 1.5s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1.5s
