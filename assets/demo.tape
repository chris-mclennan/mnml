# mnml — demo recording
#
# Regenerate assets/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#
#     cargo build --release          # the tape runs ./target/release/mnml
#     vhs assets/demo.tape           # run from the repo root → assets/demo.gif
#
# Tune the keystrokes and Sleep timings to taste before a final cut.

Output assets/demo.gif

Set Shell       "bash"
Set FontSize    14
Set Width       1280
Set Height      800
Set Padding     20
Set TypingSpeed 75ms
Set Theme       "Catppuccin Mocha"

# ── setup (not recorded) ─────────────────────────────────────────────────
# Clear any prior session so the demo launches from a clean state instead
# of replaying whatever buffers were last open.
Hide
Type "rm -rf .mnml"
Enter
Sleep 400ms
Show

# ── launch ───────────────────────────────────────────────────────────────
# mnml opens on its own source tree — a real, rich Rust workspace.
Type "./target/release/mnml ."
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
