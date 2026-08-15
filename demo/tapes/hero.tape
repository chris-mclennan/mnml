# mnml hero demo — VHS tape
# Rendered to site/public/media/hero.gif by ./run.sh demo-record.
#
# Design goals (per user 2026-08-15):
# - Feel like a person opening a terminal and running mnml.
# - Not too fast (jarring), not too slow (boring).
# - Show off the flagship surfaces: activity bar sweep, editor,
#   HTTP request, integrations, sessions, Claude/Codex usage chip,
#   menu bar dropdowns, command palette, splits.
# - Hover-help panel should always read as helpful + dynamic.
# - Land under ~90 seconds so it loops naturally.
#
# VHS syntax: https://github.com/charmbracelet/vhs
# Every `Type` is a real keystroke; `Sleep` pauses; `Enter` sends CR;
# `Ctrl+X` sends a chord. Timing is in ms unless otherwise noted.

# ── Terminal setup ─────────────────────────────────────────────────
Output site/public/media/hero.gif
Set Shell zsh
Set FontFamily "Symbols Nerd Font Mono"
Set FontSize 14
Set Width 1600
Set Height 900
Set Padding 0
Set Theme "Catppuccin Mocha"
Set Framerate 30
Set PlaybackSpeed 1.0
Set TypingSpeed 60ms

# ── Setup: cd to the repo root so ./target/release/mnml resolves.
# `Hide` stops capture so users don't see us plumbing.
Hide
Type "cd /Users/chrismclennan/Projects/mnml && clear"
Enter
Sleep 300ms
Show

# ── Boot ───────────────────────────────────────────────────────────
Type "./target/release/mnml --demo"
Sleep 400ms
Enter
Sleep 4000ms

# ── 1. Activity bar sweep — Explorer → HTTP → Integrations → Agents ─
# Cycle each section, pausing so the info panel copy is readable.
Ctrl+K
Sleep 200ms
Type "vh"
Sleep 1800ms

Ctrl+K
Sleep 200ms
Type "vi"
Sleep 1800ms

Ctrl+K
Sleep 200ms
Type "va"
Sleep 1800ms

Ctrl+K
Sleep 200ms
Type "vg"
Sleep 1800ms

Ctrl+K
Sleep 200ms
Type "vn"
Sleep 1200ms

Ctrl+K
Sleep 200ms
Type "vf"
Sleep 1200ms

# Back to Explorer for the file-open + editor demo.
Ctrl+K
Sleep 200ms
Type "ve"
Sleep 800ms

# ── 2. Open a file — Ctrl+P picker ────────────────────────────────
Ctrl+P
Sleep 400ms
Type "store"
Sleep 800ms
Enter
Sleep 2000ms

# Show cursor motion + breadcrumb path.
Down
Down
Down
Down
Down
Sleep 600ms

# ── 3. Command palette walkthrough ─────────────────────────────────
Ctrl+Shift+P
Sleep 500ms
Type "wrap"
Sleep 700ms
Enter
Sleep 1500ms

# Toggle back so subsequent frames aren't wrapped.
Ctrl+Shift+P
Sleep 300ms
Type "wrap"
Sleep 400ms
Enter
Sleep 500ms

# ── 4. Split window — H then V via palette, then close ────────────
# Ctrl+\ isn't a valid VHS chord; use the palette for splits.
Ctrl+Shift+P
Sleep 300ms
Type "split right"
Sleep 400ms
Enter
Sleep 1000ms

Ctrl+Shift+P
Sleep 300ms
Type "split down"
Sleep 400ms
Enter
Sleep 1200ms

# Cycle focus.
Ctrl+W
Sleep 200ms
Type "w"
Sleep 800ms

# Close the extra splits.
Ctrl+W
Sleep 400ms
Ctrl+W
Sleep 800ms

# ── 5. HTTP request — send + copy curl ─────────────────────────────
Ctrl+K
Sleep 200ms
Type "vh"
Sleep 1000ms

# Open a .http file.
Ctrl+P
Sleep 400ms
Type "notes.http"
Sleep 500ms
Enter
Sleep 1500ms

Ctrl+Enter
Sleep 2500ms

# ── 6. Menu bar dropdown ───────────────────────────────────────────
# Alt+F usually opens the File menu.
Alt+F
Sleep 1500ms
Escape
Sleep 300ms

# ── 7. Settings panel via palette (Ctrl+, isn't a valid VHS chord).
Ctrl+Shift+P
Sleep 400ms
Type "view.settings"
Sleep 500ms
Enter
Sleep 2000ms
Escape
Sleep 300ms

# ── 8. Ghostty / terminal pane ─────────────────────────────────────
# Open a Pty. Uses the `term.shell` command.
Ctrl+Shift+P
Sleep 400ms
Type "term shell"
Sleep 500ms
Enter
Sleep 2500ms
Type "ls"
Sleep 300ms
Enter
Sleep 1500ms

# ── 9. Back to editor + zoom out gracefully ────────────────────────
Escape
Sleep 300ms
Ctrl+K
Sleep 200ms
Type "ve"
Sleep 800ms

# ── 10. Fade — leave the info panel on-screen for the loop hook ────
Sleep 2500ms

# End.
