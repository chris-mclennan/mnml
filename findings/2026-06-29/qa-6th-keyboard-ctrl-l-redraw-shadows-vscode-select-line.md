---
agent: vscode-user-keyboard
severity: SEV-2
---

# Ctrl+L bound to view.redraw — shadows VS Code "select line"

**Verified on:** HEAD 029b0fe · `--input standard`

**Repro**
1. `mnml --headless --input standard $WS`
2. Open any file with content (e.g. `src/main.rs`).
3. Send `{"cmd":"key","key":"ctrl+l"}`.
4. Inspect `status.json`.

**Expected**
Current line gets selected — VS Code muscle memory (Ctrl+L = `editor.action.selectLine`). Status bar shows "Sel N" where N is the line's char count.

**Actual**
- `cursor` unchanged. No selection appears (statusline shows `Ln 1/12 Col 1` with no `Sel` indicator).
- The chord fires `view.redraw` instead (`src/command.rs:317` binds Ctrl+L to it).

**Why this hurts a VS Code refugee**
Ctrl+L is one of the most-used selection chords in VS Code (often chained with Ctrl+D for multi-line). Binding it to "redraw the screen" is a power-user-only escape hatch that's never the first thing a keyboard purist reaches for. There's no toast, no hint — the chord just appears dead from the user's perspective.

**Suggested fix scope (not implementing)**
Re-bind `view.redraw` to e.g. Ctrl+Shift+R or a chorded `Ctrl+K Ctrl+R`. Bind `ctrl+l` to a new `editor.select_line` command that extends selection to include the entire current line + trailing newline.

**Related**
`src/command.rs:313-321` (view.redraw with `keys: &["ctrl+l"]`).
