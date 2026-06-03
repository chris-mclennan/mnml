# mnml — demo recording
#
# Regenerate assets/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#
#     cargo build --release          # the tape runs ./target/release/mnml
#     vhs assets/demo.tape           # run from the repo root → assets/demo.gif
#
# Then shrink with gifsicle (visually identical at lossy=80, ~37% smaller):
#
#     gifsicle --optimize=3 --lossy=80 assets/demo.gif -o assets/demo.gif
#
# Tune the keystrokes and Sleep timings to taste before a final cut.

Output assets/demo.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    14
Set Width       1280
Set Height      800
Set Padding     20
Set TypingSpeed 75ms
Set Theme       "Catppuccin Mocha"

# ── setup (not recorded) ─────────────────────────────────────────────────
# Capture the binary path from the repo root, then drop into a throwaway
# temp workspace that's a copy of `src/`. Keeps the demo's `.mnml/` state
# isolated to `/tmp` so re-recording can't disrupt the user's real
# `~/Projects/mnml/.mnml/` (session restore data, IPC of any running
# instance, welcome marker). Mirrors the pattern mixr's tape uses for
# the same reason.
Hide
Type `MNML_BIN="$PWD/target/release/mnml"`
Enter
Type `DEMO_DIR=$(mktemp -d -t mnml-demo) && cp -R src "$DEMO_DIR/" && cd "$DEMO_DIR"`
Enter
Sleep 200ms
# Wipe the scrollback so the resumed recording starts on a clean prompt
# (Hide stops capturing frames, but doesn't clear what the shell echoed).
Type `clear`
Enter
Sleep 100ms
Show

# ── launch ───────────────────────────────────────────────────────────────
# mnml opens on the temp copy of its own source tree — a real, rich Rust
# workspace, but disposable.
Type `"$MNML_BIN" .`
Sleep 500ms
Enter
Sleep 3.5s

# Dismiss the first-launch welcome overlay.
Escape
Sleep 1.2s

# ── fuzzy file finder ────────────────────────────────────────────────────
Ctrl+P
Sleep 1.2s
Type "app.rs"
Sleep 1.5s
Enter
Sleep 2.8s

# ── which-key leader popup ───────────────────────────────────────────────
Ctrl+K
Sleep 2.5s
Escape
Sleep 1s

# ── toggle the file tree ─────────────────────────────────────────────────
Ctrl+B
Sleep 1.5s
Ctrl+B
Sleep 1.2s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2.5s
