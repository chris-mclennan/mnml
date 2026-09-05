---
severity: SEV-2
status: fixed
---
# `gv` re-selects in charwise VISUAL regardless of the previous mode; after a V-LINE yank it also extends one line too far

**Command ids:** `gv` (`src/input/vim.zig` `'v'` under the `g` prefix → `editor.restore_last_selection`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"type","text":"jly"}
{"cmd":"type","text":"gv"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"ggVjy"}
{"cmd":"type","text":"gv"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after Ctrl-V j l y, gv:  "mode":"VISUAL","cursor":{"line":2,"col":3}   statusline  Sel 25   (a 2x2 block became a 25-char charwise run)
after V j y, gv:         "mode":"VISUAL","cursor":{"line":3,"col":1}   statusline  Sel 44   (lines 1-2 became 1:1..3:1 charwise)
```

**Expected**: `gv` restores the previous Visual *mode and extent* (`:help gv`): the 2×2 block comes back as V-BLOCK, `Vj` comes back as V-LINE over lines 1–2 with the cursor on line 2.

**Actual**: the mode is always charwise VISUAL; the block reselection is a linear run and the linewise one reaches 3:1, so `gv` then `d` deletes a different region than the one just operated on. `gv` after a charwise `v…y` is correct. Two launches.

**Source pointer**: `src/input/vim.zig:1500-1505` — `self.vmode = .visual` unconditionally before `.restore_last_selection`; the remembered range is stored as two byte offsets with no mode.

## Fix

Commit `eaa1b08` — the handler remembers the Visual mode it left and `restore_last_selection` carries the shape (linewise steps back onto the last line, block sets the block anchor). Test: `tests/e2e-zig/vim_gv_mode.test`.
