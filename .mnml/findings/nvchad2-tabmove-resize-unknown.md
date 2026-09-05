---
severity: SEV-3
status: fixed
---
# `:tabmove`, `:resize`, `:vertical resize` are unknown commands; `{count} Ctrl-W >` ignores the count

**Command ids:** the `:` line (`src/app/ex.zig` verb table); `Ctrl-W <`/`>`/`+`/`-` (`src/input/vim.zig` `.window`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/long.zig"}
{"cmd":"type","text":":tabnew\n"}
{"cmd":"type","text":":tabmove 0\n"}
{"cmd":"snapshot"}
{"cmd":"type","text":":tabclose\n"}
{"cmd":"type","text":":vsplit\n"}
{"cmd":"key","key":"ctrl+w <"}
{"cmd":"snapshot"}
{"cmd":"key","key":"5 ctrl+w >"}
{"cmd":"snapshot"}
{"cmd":"type","text":":vertical resize 20\n"}
{"cmd":"type","text":":resize 5\n"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
│ :tabmove — unknown command │   (also :tabm)
divider column in screen.txt row 1:  75 → 79 after Ctrl-W <  → 75 after 5 Ctrl-W >   (moved 4 both times)
│ :vertical — unknown command │
│ :resize — unknown command │
```

**Expected**: `:tabmove N` reorders tab pages, `:resize N` / `:vertical resize N` set a window's height/width, `5 Ctrl-W >` widens by 5 (`:help CTRL-W_>`).

**Actual**: the three ex verbs are unknown (PARITY: "Panes, splits & tab pages — 20 done, 0 missing"); the `Ctrl-W` resize chords work but a count is dropped (both moves are one step of 4 columns), so precise keyboard resizing has no path. Two launches.

**Source pointer**: `src/app/ex.zig` verb table (no `tabm[ove]`, `res[ize]`, `vert[ical]`); `src/input/vim.zig` `.window` `<`/`>`/`+`/`-` do not read the pending count.

## Fix

Commit `5506cb0` — `:tabmove [N]`, `:resize [±]N`, `:vertical resize [±]N` (and `:vertical split`); `{count} Ctrl-W >` / `<` / `+` / `-` resize by `count` cells. Test: `tests/e2e-zig/vim_tabmove_resize.test`.
