---
severity: SEV-2
status: fixed
---
# `zj` from a closed fold lands *inside* it (hidden line 4); `zj` / `zk` from an open fold body do nothing

**Command ids:** `editor.fold_next` (`zj`), `editor.fold_prev` (`zk`) — `src/app/cmd_app.zig` `foldStep`.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/long.zig"}
{"cmd":"type","text":"zMgg"}
{"cmd":"type","text":"zj"}
{"cmd":"snapshot"}
{"cmd":"type","text":"zR"}
{"cmd":"type","text":":12\n"}
{"cmd":"type","text":"zk"}
{"cmd":"snapshot"}
{"cmd":"type","text":":20\n"}
{"cmd":"type","text":"zj"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after zM gg zj:  "cursor":{"line":4,"col":5}   while screen.txt shows
  1 pub fn fn1(a: i32) i32 { ⋯ folded · 7 lines hidden
  9
 10 pub fn fn2(a: i32) i32 { ⋯ folded · 7 lines hidden      <- line 4 is not on screen
after zR :12 zk:  cursor stays 12:5
after :20 zj:     cursor stays 20:5
```

**Expected**: `zj` moves to the start of the next fold, a closed fold counting as one line (`:help zj`) → line 10 from a closed `fn1`; from line 20 (inside `fn3`, folds open) → line 22 (the nested `while` fold). `zk` moves to the *end* of the previous fold → line 8 from line 12.

**Actual**: from the closed fold the cursor goes to hidden line 4 (the nested `while` fold's start inside the closed range — the same class as the fixed `j`-into-fold bug, `1671c9d`), and from an open body line neither `zj` nor `zk` moves. The `zk` that does move (from 13) goes to the *start* of the enclosing fold (10), not the previous fold's end. Two launches.

**Source pointer**: `src/app/cmd_app.zig:336-348` `foldStep` — walks the fold list without skipping ranges hidden by a closed fold and appears to step only between folds at the cursor's nesting level. Docs: PARITY row "Fold navigation `zj` / `zk` — done".

## Fix

Commit `cdf049b` — `foldStep` walks every bracket block plus the closed folds, leaves from a closed fold's edges and skips folds a closed one hides. Test: `tests/e2e-zig/vim_zj_zk.test`.
