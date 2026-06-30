---
agent: vscode-user
severity: SEV-2
---

# Ctrl+L "select line" behaves like vim `V`, not VS Code Ctrl+L

In standard input mode, Ctrl+L is bound to the `SelectLine` EditOp
(`src/input/standard.rs:83`). The implementation in
`src/editor/mod.rs:2181-2197` is explicit about being modeled on vim's `V`:
it anchors at line-start and **keeps the cursor where it already was on the
line**. That means Ctrl+L on a cursor mid-line selects only `[line_start..cursor]`,
not the whole line.

VS Code's Ctrl+L selects the **entire** line (line_start..line_end+\n) and
parks the cursor at the start of the next line so a second Ctrl+L extends
selection by another line. mnml's behavior makes the next Ctrl+X cut only
part of the current line and leaves a fragment behind.

## Reproduction

```jsonl
{"cmd":"open","path":"main.rs"}
{"cmd":"wait_ms","ms":200}
// main.rs line 3 is "    let x = 1;"  (4 spaces + "let x = 1;")
{"cmd":"click","col":40,"row":4,"button":"left"}    // cursor lands at col 6 of line 3 ("e" of "let")
{"cmd":"key","key":"ctrl+l"}                         // VS Code: select entire line; mnml: select cols 1..6
{"cmd":"key","key":"ctrl+x"}                         // cut selection
{"cmd":"snapshot"}
// Buffer line 3 now reads "et x = 1;" — should be deleted entirely.
```

**Expected**: line 3 disappears, cursor at start of line 4.

**Actual**: only chars 1..6 of line 3 are cut; line 3 becomes `et x = 1;`.

**Source pointer**:
- `src/input/standard.rs:83` — `'l' => InputResult::Ops(vec![SelectLine])`
- `src/editor/mod.rs:2181-2197` — explicit vim-V semantics
- The comment block even references the 2026-06-13 nvchad SEV-3 S3-04 fix
  that intentionally kept this vim shape.

**Notes**: The op is shared between vim mode (`V`) and standard mode (Ctrl+L),
but the two editors disagree about what "select line" means. Likely cleanest
fix is a new `SelectFullLine` op for the standard-mode binding that selects
`[line_start..line_end+1]` and parks the cursor at the next line's start, leaving
`SelectLine` alone for vim.
