# mnml — demo recording
#
# Regenerate assets/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#
#     vhs assets/demo.tape
#
# Tune the workspace path, keystrokes, and sleeps below before recording —
# this is a sensible starting point, not a finished cut.

Output assets/demo.gif

Require mnml

Set Shell       "bash"
Set FontSize    14
Set Width       1280
Set Height      800
Set Padding     20
Set TypingSpeed 70ms
Set Theme       "Catppuccin Mocha"

# ── launch ───────────────────────────────────────────────────────────────
# Point this at any project worth showing off.
Type "mnml ~/code/demo-project"
Sleep 500ms
Enter
Sleep 2.5s

# ── fuzzy file finder ────────────────────────────────────────────────────
Ctrl+P
Sleep 800ms
Type "main"
Sleep 1.2s
Enter
Sleep 1.8s

# ── command palette ──────────────────────────────────────────────────────
Ctrl+Shift+P
Sleep 800ms
Type "split"
Sleep 1.2s
Enter
Sleep 1.8s

# ── which-key leader popup ───────────────────────────────────────────────
Ctrl+K
Sleep 1.5s
Escape
Sleep 600ms

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 2s
