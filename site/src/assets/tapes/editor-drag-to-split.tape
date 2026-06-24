# editor-drag-to-split — drag a file from the tree across the editor area,
# release in the right zone, watch the editor split with the dragged file
# in the new pane.
#
# mnml ships a 5-zone drop overlay for tab / file drag-and-drop (Left,
# Right, Top, Bottom, Center). The cursor's zone within a target pane
# decides what happens on release:
#
#   Left / Right       vertical split (horizontal divider), src in the
#                      named half.
#   Top / Bottom       horizontal split (vertical divider), src in the
#                      named half.
#   Center             merge / move-in-place (src joins the target leaf
#                      as a new tab).
#
# Mouse-driven feature, so this tape uses mnml's file-IPC channel
# (`.mnml/ipc/command`) to synthesize the drag — VHS itself has no
# mouse syntax. A small driver script (`drag-demo-workspace/drive.sh`)
# is backgrounded by the tape; it appends JSONL drag/wait/quit commands
# while mnml renders into the captured PTY.
#
# Per the feature commit (bc4a35c): the drag GHOST chip only paints
# during tree-file drags; drag-between-split-strips is explicitly
# deferred. So this demo uses the tree drag — picks up `src/editor.rs`
# from the file tree and drops it into the right half of the editor
# area.
#
# The driver script uses the raw `mouse_down` / `mouse_move` /
# `mouse_up` IPC commands (commit 715d366) with interleaved sleeps
# between events. mnml drains + paints once per main-loop tick, so
# each event gets its own painted frame — the ghost chip + right-zone
# drop overlay are visible mid-drag in the rendered GIF.
#
# Renders to: editor-drag-to-split.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/editor-drag-to-split.tape

Output site/src/assets/tapes/editor-drag-to-split.gif

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
# Prepare a stable demo workspace cloned from the committed seed dir so
# the GIF is reproducible regardless of where it's regenerated from.
Type "MNML_DEMO=$(mktemp -d) && cp -R $HOME/Projects/mnml/site/src/assets/tapes/drag-demo-workspace/. $MNML_DEMO/ && cd $MNML_DEMO"
Enter
Sleep 200ms
# Pre-write the welcome marker so the first-launch overlay doesn't
# eat the first frames.
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
Sleep 200ms
# Spawn the IPC driver as a detached background process; suppress
# job-control notifications + all output so the bg job stays invisible
# in the recorded PTY. The driver polls for mnml's IPC file before
# writing commands, so the timing self-syncs to mnml's first paint.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/drag-demo-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml ."
Sleep 400ms
Enter

# Let mnml render its first frame + the driver issue `open src/main.rs`.
Sleep 4s

# ── animated drag ────────────────────────────────────────────────────────
# Driver sequences mouse_down → 7 mouse_move steps → mouse_up with
# ~220ms sleeps between events. Ghost chip follows the cursor; the
# right-zone drop overlay highlights the editor's right half as the
# cursor approaches it. Total drag duration ≈ 2.4s.
Sleep 3.2s

# ── settled split ────────────────────────────────────────────────────────
# Hold the final two-pane state (main.rs left, editor.rs right) for a
# read.
Sleep 2.5s
