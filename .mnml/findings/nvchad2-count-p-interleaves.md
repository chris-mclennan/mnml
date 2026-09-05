---
severity: SEV-2
status: fixed
---
# `{count}p` repeats each line / each char of the register instead of the whole block (`2yy3p`, `yiw3p`)

**Command ids:** vim `p` with a count (`src/input/vim.zig` put path → `src/editor/clipboard.zig`); `P` is correct.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"2yy3p"}
{"cmd":"snapshot"}
{"cmd":"type","text":"u"}
{"cmd":"type","text":"yiw3p"}
{"cmd":"snapshot"}
{"cmd":"type","text":"u"}
{"cmd":"type","text":"2yy2P"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after 2yy3p (cursor Ln 4):            after yiw3p:
  1 alpha bravo charlie                  1 aalphalalphapalphaha bravo charlie
  2 alpha bravo charlie
  3 alpha bravo charlie                after 2yy2P (correct):
  4 alpha bravo charlie                  1 alpha bravo charlie
  5 delta echo foxtrot                   2 delta echo foxtrot
  6 delta echo foxtrot                   3 alpha bravo charlie
  7 delta echo foxtrot                   4 delta echo foxtrot
  8 delta echo foxtrot                   5 alpha bravo charlie
  9 golf hotel india                     6 delta echo foxtrot
```

**Expected**: `3p` puts the register three times in sequence: `alpha / delta / alpha / delta / alpha / delta` below line 1, cursor on the first pasted line (Ln 2). `yiw3p` gives `aalphaalphaalphalpha bravo charlie`.

**Actual**: linewise: the three copies are grouped per line (alpha ×3 then delta ×3), cursor lands on Ln 4; charwise: `alpha` is inserted after each of the next three characters (`a|alpha|l|alpha|p|alpha|ha`). `P` with a count is right, so only the after-cursor loop advances the insertion point wrongly between iterations. `.` after `3p` repeats the same wrong shape.

**Source pointer**: `src/input/vim.zig` `'p'` with count → the repeated put; the linewise/charwise put in `src/editor/clipboard.zig` / `edit_op` `paste` — the iteration re-positions the cursor after each single copy instead of pasting the concatenated text once.

## Fix

Commit `c8f7310` — `[count]p` is one put of the register repeated `count` times (`register.putTimes`, routed from the `repeat` prong). Test: `tests/e2e-zig/vim_count_p_consecutive.test`.
