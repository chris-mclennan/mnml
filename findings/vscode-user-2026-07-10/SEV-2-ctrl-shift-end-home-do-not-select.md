## [SEV-2] Ctrl+Shift+End and Ctrl+Shift+Home move the cursor but do NOT extend the selection

**Reproduction** (a multi-line buffer, e.g. `app.js` after `console.log('hi')\nline2\nline3`):

```jsonc
{"cmd":"key","key":"ctrl+home"}
{"cmd":"key","key":"ctrl+shift+end"}     // expected: select from top to end-of-buffer
{"cmd":"snapshot"}
// then read status: cursor lands at Ln 3/3 Col 6 — but "Sel N" chip missing
```

Symmetric for `Ctrl+Shift+Home`:

```jsonc
{"cmd":"key","key":"ctrl+end"}
{"cmd":"key","key":"ctrl+shift+home"}   // expected: select from bottom to start-of-buffer
```

Cursor moves to line 1 col 1 but no selection is established.

**Expected** (VS Code): `Ctrl+Shift+End` extends the selection from the current cursor to the end of the file. `Ctrl+Shift+Home` symmetric to start-of-file.

**Actual**: The Ctrl+End / Ctrl+Home motion fires, cursor moves, but no anchor is set — result is a bare motion, no selection. Statusline `Sel N` chip never appears.

**Comparison**: `Shift+End` (line-end select) and `Shift+Ctrl+Right` (word-select) DO extend the selection correctly. So only the Ctrl+Shift+Home / Ctrl+Shift+End pair is missing anchor handling.

**Source pointer**: `src/input/standard.rs` or the command registry entry for `editor.select_to_document_start` / `editor.select_to_document_end` (or their equivalents) — the current binding probably targets the plain `Ctrl+Home` / `Ctrl+End` motion op with modifiers merged into the KeyEvent but the op itself doesn't check `shift` for anchor-set-before-move.

**Notes**: Similar bug family to the Ctrl+End-doesn't-CLEAR-selection cousin (see SEV-3 file). One direction of the pair is broken; the other is broken the opposite way.
