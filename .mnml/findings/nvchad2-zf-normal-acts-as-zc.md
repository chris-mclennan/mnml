---
severity: SEV-3
status: open
---
# `zf{motion}` in Normal mode closes the fold under the cursor and then runs the motion loose (`zf3j` = `zc` + `3j`, `zfap` ends in Insert)

**Command ids:** `z f` in Normal (`src/input/vim.zig` `z` prefix); `editor.fold_selection` is Visual-only.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/long.zig"}
{"cmd":"type","text":":10\n"}
{"cmd":"type","text":"zfj"}
{"cmd":"snapshot"}
{"cmd":"type","text":"zR"}
{"cmd":"type","text":":10\n"}
{"cmd":"type","text":"zfap"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after :10 zfj:   cursor 18:1;  10 pub fn fn2(a: i32) i32 { ⋯ folded · 7 lines hidden   (fn2 closed, cursor moved past it)
after :10 zfap:  "mode":"INSERT","cursor":{"line":10,"col":3};  10 ppub fn fn2(a: i32) i32 { ⋯ folded
```

**Expected**: `zf{motion}` creates a manual fold over the motion (`:help zf`) — `zfj` folds lines 10–11, `zfap` folds the paragraph; the cursor stays on line 10. If manual folds from Normal mode are out of scope, `zf` should do nothing (or toast), not act as a different fold command.

**Actual**: `zf` behaves as `zc` (closes the syntax fold at the cursor) and the motion keys are then executed on their own: `j` moves to line 18, `a` enters Insert and `p` is typed into the buffer. `zf` in Visual (`Vjjjzf`) does fold the selection. Two launches.

**Source pointer**: `src/input/vim.zig` `z` prefix: `f` is mapped to the close-fold command in Normal mode instead of arming an operator-pending state; PARITY says "Code folding — manual — done" and only documents `zf` for Visual.
