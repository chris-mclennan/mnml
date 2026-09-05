---
severity: SEV-2
status: fixed
---
# `dip` / `dap` on the last paragraph leave an extra empty line (and `dap` does not take the preceding blank)

**Command ids:** text objects `ip` / `ap` (`src/editor/select.zig`) + linewise delete.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":4\n"}
{"cmd":"type","text":"o"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"dip"}
{"cmd":"snapshot"}
{"cmd":"type","text":"u"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"dap"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
setup: 10 lines — 1-4 text, 5 blank, 6-10 text.
after dip (status Ln 6/6):     after dap (status Ln 6/6):
  4 juliet kilo lima             4 juliet kilo lima
  5                              5
  6                              6
```

**Expected**: `dip` on line 10 deletes lines 6–10 → 5 lines remain (4 text + the blank). `dap` at the end of the file also swallows the blank line *before* the paragraph (`:help ap`: "a paragraph … when there is no following blank line the preceding blank lines are included") → 4 lines remain.

**Actual**: both leave 6 lines: the paragraph text goes but an empty line is left where it was (the range is deleted without its trailing newline), and `dap` never touches line 5. `dG` from line 6 and `Vjjjjd` remove the lines correctly, so it is specific to the paragraph object at EOF.

**Source pointer**: `src/editor/select.zig` paragraph object end (exclusive of the final `\n` when the paragraph is the last one) → `src/editor/delete.zig`.

## Fix

Commit `7559fa9` — `ip` / `ap` name lines; the operator widens them linewise (`dip` → no empty line, `cip` → one, `dap` at EOF takes the preceding blanks, `vip` is V-LINE). Test: `tests/e2e-zig/vim_dap_eof.test`.
