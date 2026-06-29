---
agent: vscode-user
severity: SEV-2
---

## SEV-2 Ctrl+End lands at start-of-last-line, not end-of-buffer

**Reproduction**:
```
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"ctrl+end"}
{"cmd":"type","text":"!"}
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```

Workspace lib.rs starts as `fn helper() -> i32 {\n    42\n}\n\nfn unused() {\n    let x = 1;\n}\n` (7 lines + trailing newline).

**Expected**: After `Ctrl+End`, cursor is at line 7 col 2 (just past the final `}`), or one row below if the trailing newline counts as a blank line. Typing `!` produces `... 7 }!` or a new line with just `!`. This is the VS Code behavior.

**Actual**: After `Ctrl+End`, cursor lands at line 7 col 1 — *before* the closing brace. Typing `!` produces `7 !}` (text inserted in front of the brace). Combined with a preceding `Enter`, the `}` is pushed to a new line with the typed text sitting before it on the row that was originally line 7. Reproducible across re-tests and survives undo cycles.

**Source pointer**: behavior originates somewhere in `src/editor.rs` `Editor::apply` end-of-buffer handler; the standard input handler in `src/input/standard.rs` translates `Ctrl+End` into a `MoveTo{end-of-buffer}` op that is implemented as start-of-last-line.

**Notes**: VS Code's Ctrl+End is a fundamental "jump to end" muscle move — every keyboard-heavy editor user fires this dozens of times a day. Currently if you Ctrl+End → Enter → type, your text lands above the close-brace of the last block instead of after it. Bookend partner Ctrl+Home works correctly.
