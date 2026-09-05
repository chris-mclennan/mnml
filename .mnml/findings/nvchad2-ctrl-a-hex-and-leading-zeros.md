---
severity: SEV-3
status: open
---
# `Ctrl-A` treats `0x0f` as the decimal `0` before the `x` (→ `1x0f`) and `Ctrl-X` on `007` yields `6` (drops the width)

**Command ids:** Normal-mode `Ctrl-A` / `Ctrl-X` number parsing.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"Ohex 0x0f oct 007 neg -0"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"0"}
{"cmd":"key","key":"ctrl+a"}
{"cmd":"snapshot"}
{"cmd":"type","text":"fo"}
{"cmd":"key","key":"ctrl+x"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after 0 Ctrl-A:   1 hex 1x0f oct 007 neg -0
after fo Ctrl-X:  1 hex 1x0f oct 6 neg -0
```

**Expected**: Neovim's default `nrformats=bin,hex`: `0x0f` → `0x10`; `007` is decimal with leading zeros preserved → `006` (`:help CTRL-A`: "leading zeros are kept").

**Actual**: hex is not recognised (the `0` is incremented alone, producing `1x0f`), and a zero-padded decimal collapses to `6`. Decimal, negative (`-3`→`-2`→…→`1`), counts (`5 Ctrl-A`) and `.` are correct. Two launches (`0x0f`→`0x1f` when starting on the `x`, `009`→`8`).

**Source pointer**: the number scanner used by the vim handler's `ctrl+a`/`ctrl+x` — decimal-only, formats with `%d` (no width).
