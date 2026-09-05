---
severity: SEV-2
status: fixed
---
# `Ctrl+/` on a multi-line selection collapses the selection to its start, so the second press only un-comments the first line

**Command id:** `editor.toggle_line_comment` (`ctrl+/`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"key","key":"ctrl+g"}
{"cmd":"type","text":"3"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"shift+down"}
{"cmd":"key","key":"shift+down"}
{"cmd":"key","key":"ctrl+/"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+/"}
{"cmd":"snapshot"}
```
**screen.txt** after the first press (correct — lines 3–4 commented, line 5 excluded because the selection ends at col 1):
```
   3 // pub fn alpha() u32 {
   4     // return 1;
   5 }
```
`status.json`: `"cursor":{"line":3,"col":1}` (was `{"line":5,"col":1}` before the press — the selection is gone).
After the second press:
```
   3 pub fn alpha() u32 {
   4     // return 1;
   5 }
```

**Expected**: VS Code keeps the selection after toggling, so `Ctrl+/` twice is a no-op; a selection-wide toggle is reversible with the same chord.
**Actual**: the selection is dropped and the cursor parked at the selection start; the second press toggles line 3 only, leaving line 4 commented. (Also: mnml inserts `//` at each line's own indent — `    // return 1;` — where VS Code aligns all markers at the block's minimum indent; cosmetic.)

**Source pointer**: `editor.toggle_line_comment` runner in `src/app/cmd_editor.zig` / the `EditOp` it emits — the selection is not restored after the line edits.

## Fix

`75e55a8` on branch `fix-editor` — editor: Ctrl+/ keeps a multi-line selection, so a second press puts it back. Regression: `tests/e2e-zig/vscode_ctrl_slash_selection.test`, plus unit rows in `src/editor/line.zig` and `src/editor/buffer.zig`. The min-indent alignment of the markers (cosmetic) is left as it was.
