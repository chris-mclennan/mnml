---
severity: SEV-2
status: fixed
---
# `'a` / `` `a `` go to the mark's original line number after lines are inserted or deleted above it

**Command ids:** `m{a-z}` / `'{a-z}` / `` `{a-z} `` (`src/input/vim.zig` `.mark_set` / `.mark_jump_*`, the marks store).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":5\n"}
{"cmd":"type","text":"wma"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"2Onew"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"'a"}
{"cmd":"snapshot"}
{"cmd":"type","text":"`a"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
toasts: │ mark 'a set │  then  │ → 'a 5:1 │  then  │ → 'a 5:6 │
  1 new
  2 new
  3 alpha bravo charlie
  4 delta echo foxtrot
  5 golf hotel india        <- cursor lands here
  6 juliet kilo lima
  7 mike november oscar     <- where the mark was set (line 5 before the insert)
```

**Expected**: marks move with the text (`:help mark-motions`: "If you make changes to the text, marks are adjusted"): after two lines are inserted above, `'a` goes to line 7 and `` `a `` to 7:6. Deleting a line above moves it up by one.

**Actual**: the mark stays at its numeric (5,6); `'a` lands on `golf hotel india`, two lines above the marked text. `ggdd` afterwards also leaves it at 5. Both launches identical.

**Source pointer**: the marks store keyed on the vim handler's `.mark_set` (`src/input/vim.zig:1402`) — positions are stored as row/col and never shifted by `Editor.splice`.

## Fix

Commit `ae7bee7` — lowercase marks live on the `Editor` as byte offsets and `splice` moves them with every edit; `Editor.markPos` / `setMarkPos` translate for the session file, `:marks` and the picker. Test: `tests/e2e-zig/vim_marks_follow_edits.test`.
