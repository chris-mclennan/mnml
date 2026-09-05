---
severity: SEV-2
status: fixed
---
# `Ctrl-A` / `Ctrl-X` in Visual are read as a pending `a` text-object prefix — nothing is incremented and the next `Esc` is swallowed

**Command ids:** `v_CTRL-A` / `v_CTRL-X` / `v_g_CTRL-A` (`src/input/vim.zig` Visual key switch; the ctrl modifier is dropped for `a`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"Oitem 0\nitem 0\nitem 0"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"ggVjj"}
{"cmd":"key","key":"ctrl+a"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after V j j Ctrl-A:  "mode":"V-LINE"  statusline left edge:  a     lines still  item 0 / item 0 / item 0
after Esc:           "mode":"V-LINE" still (the Esc cancelled the pending text object, not Visual)
```

**Expected**: `v_CTRL-A` adds 1 to the first number on every selected line and returns to Normal (`item 1` ×3); `g Ctrl-A` makes it a progression (`item 1`, `item 2`, `item 3`); `Esc` in Visual always returns to Normal.

**Actual**: the chord is treated as `a` (Visual's around-object prefix): the statusline shows the pending `a`, nothing changes, and the following `Esc` only clears the prefix so the user is still in V-LINE — one extra `Esc` is needed. `g Ctrl-A` likewise does nothing. Normal-mode `Ctrl-A`/`Ctrl-X` with counts and `.` are correct. Three launches.

**Source pointer**: `src/input/vim.zig` Visual-mode `.char` handling — the `a`/`i` text-object branch does not check `key.mods.ctrl` (compare the Normal-mode ctrl table which routes `ctrl+a`).

## Fix

Commit `6d427ca` — `change_numbers_in_selection` (one undo step; `g Ctrl-A` progressive), routed ahead of the `a` / `i` text-object keys. Test: `tests/e2e-zig/vim_visual_ctrl_a.test`.
