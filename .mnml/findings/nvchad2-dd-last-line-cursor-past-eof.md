---
severity: SEV-2
status: fixed
---
# `dd` / `3dd` / `V…d` ending on the last line leave the cursor on a phantom line past EOF (`Ln 9/8`); `p` there inserts a blank line

**Command ids:** vim `dd`, `{count}dd`, V-LINE `d` (`src/editor/delete.zig` linewise delete; cursor clamp after the edit).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"dd"}
{"cmd":"snapshot"}
{"cmd":"type","text":"p"}
{"cmd":"snapshot"}
{"cmd":"type","text":"uu"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"kVjd"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after Gdd:  status "cursor":{"line":9,"col":1}, statusline  Ln 9/8
  8 victor whiskey xray
  9                         <- phantom row painted under the cursor
after p:    Ln 10/10
  8 victor whiskey xray
  9                         <- a real empty line now exists
 10 yankee zulu
after G k V j d:  Ln 8/7 — same phantom row 8
```

**Expected**: deleting the last line moves the cursor to the new last line (`Ln 8/8`); `ddp` on the last line swaps nothing (re-inserts the line as line 9) and never creates an empty line.

**Actual**: the cursor is left one past the last line (line count 8, cursor line 9); the view paints the phantom row the round-one fix (`71b31e2`) removed; `p` pastes *below* the phantom so an empty line 9 is materialised before `yankee zulu`; `i`/`o` there also materialise it. `dG` from a middle line clamps correctly, so only the operator paths that end exactly on the last line miss the clamp. Reproduced from three launches.

**Source pointer**: `src/editor/delete.zig` `dd` (line ~156, "remove it (including its `\n`, or …") — after removing the last line's *preceding* newline the cursor is not clamped to the new last line; `src/ui/editor_view.zig` then draws the row because the cursor is on it.

## Fix

Commit `15222ed` — `dd` / `V…d` on the last line clamp back onto the new last line (`delete.zig` `clampOffPhantomLine`); a `{count}dd` past EOF takes only the lines that exist. Test: `tests/e2e-zig/vim_dd_last_line.test`.
