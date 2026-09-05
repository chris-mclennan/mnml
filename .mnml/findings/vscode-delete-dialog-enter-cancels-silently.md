---
severity: SEV-3
status: fixed
---
# Tree `Delete…` dialog: `Enter` closes it without deleting and without feedback

**Command id:** `file.delete` (tree menu → `Delete…`). Reproduced on two fresh launches, 2/2.

**Reproduction** (right-click any file row, then):
```
{"cmd":"click","col":12,"row":<file row>,"button":"right"}
{"cmd":"click","col":20,"row":<the "Delete…" item row>}
{"cmd":"snapshot"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```
**screen.txt** (dialog):
```
╭ Delete ────────────────────────────────────────────────────╮
│    Delete vscode-scratch/newfile.txt? It goes to the trash.│
│                                                            │
│   [D]elete      Delete [P]ermanently      [C]ancel         │
╰────────────────────────────────────────────────────────────╯
```
After `Enter`: dialog gone, `ls` still shows the file, no `deleted …` toast. `d` (and clicking `[D]elete`, `overlay_item:0`) delete correctly with the toast `deleted … — files.trash restores it`.

**Expected**: VS Code's delete confirmation defaults to "Move to Trash" on Enter; at minimum a default button is marked and Enter does something visible.
**Actual**: Enter is a silent cancel; a VS Code user's muscle memory (right-click → Delete → Enter) leaves the file in place with no indication.

**Source pointer**: the delete confirmation overlay's key handler (`src/app/file_ops*.zig` / the `[D]elete` `[P]ermanently` `[C]ancel` button overlay) — no `.enter` case.

## Fix

`387d7a9` on branch `fix-git-tree` — trash: enter on the delete confirm deletes; the action is the default in both forms and the toast follows. Regression: `tests/e2e-zig/tree_delete_enter.test`, the reworked unit test in `src/app/trash.zig`; break-checked.
