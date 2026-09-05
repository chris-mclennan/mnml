---
severity: SEV-2
status: fixed
---
# No NvChad-style keyboard path into the file tree: `Ctrl-H` / `Ctrl-W h` from the leftmost split stay in the editor

**Command ids:** `view.focus_left` (`ctrl+h` vim), `focus.cycle` (`f6` only), `view.focus_tree` (`ctrl+shift+e`, `ctrl+0` only).

**Reproduction** (tree visible, single editor):
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"ctrl+h"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+w h"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+w w"}
{"cmd":"snapshot"}
```
**status.json** after each: `"focus":"pane"` — never `"focus":"tree"`. Once the tree *is* focused (via `run-command focus.cycle`), `ctrl+l` correctly returns focus to the pane, so the asymmetry is only inbound. Reproduced in two launches.

**Expected**: NvChad's nvim-tree is a window; `<C-h>` (and `Ctrl-W h` / `Ctrl-W w`) from the leftmost editor moves into it, `j`/`k`/`Enter` then browse. `<leader>e` toggles the tree but does not focus it either.

**Actual**: the only bindings that focus the tree are `F6`, `Ctrl+0`, `Ctrl+Shift+E` — none in the NvChad vocabulary; a vim user's reflexes leave them stuck in the editor.

**Source pointer**: `src/app/cmd_view.zig` `view.focus_left` — treats the tree as outside the split tree; `src/input/vim.zig` `.window` `h`/`w`.

## Fix

`fe9676b` — `view.focus_left` with no neighbour focuses the sidebar when open (`Ctrl-H` and `Ctrl-W h` both route there); `view.focus_next_split` (`Ctrl-W w`) cycles past the last leaf into it; `view.focus_right` from the sidebar returns to the split. Note: `ctrl+l` from the tree did *not* actually return focus before this change either (no neighbour → no-op) — it does now. Pinned by `tests/e2e-zig/vim_ctrl_h_into_tree.test` and a `cmd_view.zig` unit test.
