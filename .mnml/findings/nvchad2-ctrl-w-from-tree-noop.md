---
severity: SEV-2
status: fixed
---
# From the file tree, `Ctrl-W w` and `Ctrl-W l` do nothing — only `Ctrl-L` returns to the editor

**Command ids:** `view.focus_next_split` (`Ctrl-W w`), `view.focus_right` (`Ctrl-W l`, `ctrl+l`) with the sidebar focused.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":vsplit\n"}
{"cmd":"key","key":"ctrl+w h"}
{"cmd":"key","key":"ctrl+w h"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+w w"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+w l"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+l"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
status.json "focus" after each step:  tree → tree (Ctrl-W w) → tree (Ctrl-W l) → pane (Ctrl-L)
```

**Expected**: once `Ctrl-W h` has put focus in the tree (as `fe9676b` intends — nvim-tree is a window), `Ctrl-W w` cycles on to the next window and `Ctrl-W l` moves right into the split, exactly like `Ctrl-L` does.

**Actual**: the `Ctrl-W` chords are inert while the sidebar has focus (the tree's key handler never sees a `Ctrl-W` chain); `Ctrl-L` works because it is a global keymap chord. A vim user whose hands know only `Ctrl-W` is stuck in the tree. Three launches.

**Source pointer**: `src/app/dispatch.zig` — with `focus == .tree` keys go to the tree handler, and the vim handler's `Ctrl-W` table (`src/input/vim.zig` `.window`) is only reached from an editor pane; `cmd_view.zig:331` `focusRight` / `focusNextSplit` themselves handle the sidebar (the unit test at line 857 covers them) but nothing emits them from the tree on `Ctrl-W`.

## Fix

Commit `b6645b2` — the tree arms a pending `Ctrl-W` under the vim profile; `w` / `p` / `h` / `j` / `k` / `l` and the arrows move on; `focus_next_split` from the sidebar enters the first window. Test: `tests/e2e-zig/vim_ctrl_w_from_tree.test`.
