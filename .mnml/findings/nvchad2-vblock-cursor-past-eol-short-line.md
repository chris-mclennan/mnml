---
severity: SEV-2
status: open
---
# V-BLOCK `j`/`k` onto a shorter line leaves the cursor one past its end, so the block's edge is off by one and `d`/`r`/`c` skip the short line

**Command ids:** V-BLOCK vertical motion + block operators (`src/input/vim.zig` `.visual_block`, `src/editor/select.zig` block range).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"18l"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"type","text":"2j"}
{"cmd":"snapshot"}
{"cmd":"type","text":"d"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
lines 1-3 are 19 / 18 / 16 chars.
after Ctrl-V 2j:  "mode":"V-BLOCK","cursor":{"line":3,"col":17}     <- line 3 has 16 columns
after d:
  1 alpha bravo char       (cols 17-19 removed)
  2 delta echo foxtr       (cols 17-18 removed)
  3 golf hotel india       (untouched)
same with r Z → charZZZ / foxtrZZ / india unchanged; c Q → charQ / foxtrQ / indiaQ
```

**Expected**: in Visual the cursor cannot pass the last character: on line 3 it sits on col 16 (`a`), the block is cols 16–19, and `d` gives `alpha bravo cha` / `delta echo foxt` / `golf hotel indi` (`:help v_$` aside, plain `j` clamps to the line).

**Actual**: the cursor is at col 17 (one past EOL) on the short line; the block's left edge becomes 17, so the short line is not in the block at all and the longer lines lose one column less than they should. Also seen with `gg$ Ctrl-V 2j d/rZ/cQ`. Two launches.

**Source pointer**: `src/input/vim.zig` V-BLOCK `j`/`k` reuse the Normal-mode vertical move whose column clamp allows `len` (the Insert/exclusive position) rather than `len-1`; `src/editor/select.zig` block edges then read that column.
