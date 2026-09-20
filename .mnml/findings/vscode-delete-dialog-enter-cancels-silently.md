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

`387d7a9` on branch `fix-git-tree` made Enter the default action. Two
days later `fcb8b5e6` ("prompts and confirms as Rust paints them") put
`trash.zig`'s `.selected` back on Cancel — deliberately, and the source
says why: *a destructive box's Enter must not be the destructive act* —
and rewrote `tests/e2e/tree_delete_enter.test` to assert the behaviour
this finding reported as the bug, silence included. So half of the fix
was reverted on purpose and half was lost with it, and the regression
test pinned the loss (`docs/research/hunt-triage-2026-09-20.md` #2).

`hunt-fixes` (2026-09-20) closes the half that had no defence. Enter
still does not delete — that stays by design — but it is no longer
SILENT: `trash.acceptDelete` toasts

    cancelled — a.txt kept; `d` deletes, `p` permanently

so a torn-down box no longer reads on screen exactly like a delete that
worked, and the toast names the key that does delete. Esc stays quiet.

Regression: `tests/e2e/tree_delete_cancel_toast.test`;
`tree_delete_enter.test` corrected to assert the toast instead of the
silence.
