---
severity: SEV-2
status: fixed
---
# `:b N` / `:b name` are "unknown command"

**Command ids:** the `:` line in `src/app/ex.zig` (verbs `bn`, `bp`, `bd`, `ls` exist; `b`/`buffer` does not).

**Reproduction** (two buffers open):
```
{"cmd":"type","text":":b 2\n"}
{"cmd":"snapshot"}
{"cmd":"type","text":":b a.txt\n"}
{"cmd":"snapshot"}
```
**screen.txt**: `│ :b — unknown command │` both times; `activeFile` unchanged. `:bfirst`, `:blast` are also unknown.

**Expected**: `:b 2` switches to buffer 2, `:b a.txt` (or a unique prefix) switches by name — the everyday way to reach a buffer once `:ls` has shown the list.

**Actual**: only `:bn` / `:bp` cycle; the numbered/named form is missing while `:ls` exists and shows numbers. Reproduced twice.

**Source pointer**: `src/app/ex.zig` lines ~115–123 — no `b`/`buffer` verb.

## Fix

`7f87597` on branch `vim-edit` — ex: :b N, :b name and :b# reach a buffer the way :ls numbers them. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
