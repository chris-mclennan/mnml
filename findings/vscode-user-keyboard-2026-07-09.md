# vscode-user keyboard hunt — 2026-07-09

Headless / file-IPC drive against 4d2a6c0, 45bd338, 278e5bb,
e719498, 27d37ca. Keyboard purist, no mouse.

## Summary

7 issues (0 SEV-1, 3 SEV-2, 4 SEV-3). Two SEV-2s block the "just
switch panels and type /" story these commits sell. Confirm
dialog, AI palette entries, HTTP preview tab all pass.

## SEV-2

**1. `/` filter unreachable after arriving from HTTP.**
`set_activity_section` (`src/app/layout.rs:1857`) never touches
`app.focus`. HTTP auto-opens a Request pane and moves focus to
Pane; switching HTTP → TODOs/Notes/Sessions leaves focus on the
now-hidden pane. Filter guards require `focus == Tree`
(`src/tui/mod.rs:861/900/939`), so `/` types into the pane
instead of focusing the filter. Repro: `view.activity_http` →
`view.activity_todos` → `/` — filter row stays on `/ filter`;
`sample.rs` receives a `/`. `Ctrl+Shift+E` workaround
undiscoverable.

**2. No j/k/arrow nav on TODOs/Notes/Sessions results.**
HTTP panel has `http_panel_cursor_down/up/activate`
(`src/tui/mod.rs:833-856`); grep for the three counterparts
returns zero. After Enter accepts the filter, opening a hit
needs a mouse click. Fails the "j/k after accept" gate.

**3. Esc after Enter-accept doesn't clear the filter.**
Enter defocuses but keeps the query. Subsequent Esc is inert
(guarded by `_filter_focused`). Clearing needs `/` then Esc.

## SEV-3

**4. `/` while focused appends `/`.** Char handler pushes it
(`src/tui/mod.rs:888-895`). Backspace fixes.

**5. Filter rects not in `rects.json`.**
`todos/notes/sessions_panel_filter_input` set in the renderers
but no `one!()` entry in `ipc/mod.rs`. Same class as prior
bufferline-overflow / settings-save fixes. Keyboard unaffected.

**6. First `/` after section switch races paint.** IPC-only.

**7. AI palette titles diverge from chip menu.** Palette says
"AI: open a NEW Claude Code session in the left half"; menu says
"Place new session in left half". Both fire.

## Verified working

- `/` focuses filter on all three sections (focus == Tree);
  Char/Backspace/Enter/Esc wired; header `(N of M hits)`; chip
  cycles placeholder → `type to filter…▏` → typed text.
- Ctrl+P etc. survive filter focus (CONTROL/ALT excluded).
- `/` falls through to pane when `focus == Pane`.
- `integrations.remove` picker → `[ Remove ] [ Cancel ]` dialog,
  Cancel default (`src/app/discovery.rs:275`),
  Left/Right/Tab/BackTab cycle, Enter fires, Esc cancels. Real
  remove verified (`Installed (9) → (8)` via Left+Enter on htop).
- 8 AI palette commands fire; `ai.codex_new_right` opens a Codex
  Pty pane on the right half.
- HTTP preview tab auto-opens on entering HTTP; drops on leaving
  untouched (`panes: []`); promotes on Char/Backspace/Delete/
  Enter. `Ctrl+;` cmdline doesn't leak.
