## [SEV-3] Ctrl+End (unshifted) does not clear an active selection

**Reproduction**:

```jsonc
{"cmd":"open","path":"src.py"}
{"cmd":"key","key":"ctrl+a"}          // Sel 158
{"cmd":"key","key":"ctrl+end"}        // expect: motion + selection cleared
{"cmd":"snapshot"}
// statusline still shows Sel 157
```

**Expected** (VS Code): `Ctrl+End` (no Shift) is a motion — it clears any active selection and places the cursor at the end of the buffer.

**Actual**: The cursor moves to the last line's end (`Ln 9/9 Col 11`) but the selection persists with `Sel 157` in the statusline. Follow-on chords like `Ctrl+F` open in "Find in selection" mode because a selection is still live — unexpected for a user who just moved the cursor.

**Comparison**: `End` (plain, single line) DOES clear the selection. `Right`, `Left`, `Ctrl+Home` all clear correctly. Only `Ctrl+End` is broken.

**Source pointer**: `src/editor/mod.rs` — the buffer-end motion op probably jumps cursor without doing `self.anchor = None` when no `shift` modifier is present. Likely a missing anchor clear in the `MoveBufferEnd` (or equivalent) arm.

**Notes**: Cousin of the SEV-2 `Ctrl+Shift+End` doesn't-set-anchor bug. The two are opposite halves of the same modifier-check gap.
