---
severity: SEV-2
status: open
---
# `F2` with the tree focused runs `lsp.rename` (toast: no language server), not `file.rename` — though `docs/commands.md` says F2 renames the tree file

**Command id:** `lsp.rename` fires; `file.rename` ("Rename the selected tree file (F2, when tree focused)", `docs/commands.md:734`) has no chord. Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"run-command","id":"view.focus_tree"}
{"cmd":"key","key":"end"}
{"cmd":"key","key":"f2"}
{"cmd":"snapshot"}
```
`status.json`: `"focus":"tree","treeSelection":".../build.zig.zon"`.
**screen.txt**:
```
│ no language server for this file (rename) │
```
No `Rename` prompt. In the first session, typing the new name after this went straight into the previously active editor buffer (`bravo.txt` line 3 became `ode-scratch/renamed.txt`).

**Expected**: F2 on a tree row opens the rename prompt (VS Code Explorer: F2 = rename; the docs claim the same).
**Actual**: the global `f2` → `lsp.rename` binding wins regardless of focus; the tree's `handleKey` has no `f2` case (it only handles `r` = refresh). Rename is reachable only via the right-click menu.

**Source pointer**: `src/app/tree.zig:306` `handleKey` (no `.f` branch); `src/commands/specs.zig` `lsp.rename` keys `f2` in both profiles; `file.rename` keys empty.
