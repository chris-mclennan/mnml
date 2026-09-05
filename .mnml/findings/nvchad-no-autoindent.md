---
severity: SEV-2
status: fixed
---
# `o` / `O` / Enter never auto-indent, although `editor.auto_indent` defaults to `true` and `:set autoindent?` reports `on`

**Command ids:** insert-mode newline (`src/editor/insert.zig`), `:set autoindent` (`src/app/ex.zig`).

**Reproduction** (b.zig line 12 is `    const x = add(1, 2);`, 4-space indent):
```
{"cmd":"open","path":"hunt/b.zig"}
{"cmd":"type","text":":set autoindent\n"}
{"cmd":"type","text":":12\n"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"X"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"O"}
{"cmd":"type","text":"Y"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"k"}
{"cmd":"key","key":"A"}
{"cmd":"type","text":"\nZ"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
**screen.txt** (toast from the `:set`: `│ editor.auto_indent=on │`):
```
13|  12     const x = add(1, 2);
14|  13 Z
15|  14 Y
16|  15 X
```
All three new lines start at column 1.

**Expected**: with autoindent on, `o`/`O`/Enter copy the 4-space indent of the current line (NvChad has `autoindent` on; PARITY lists "Auto-indent — done — `src/editor/insert.zig`").

**Actual**: no indent, ever. Reproduced twice from fresh launches.

**Source pointer**: `src/editor/editor.zig:159` `auto_indent: bool = false` on the Editor struct; `insert.zig` reads `ed.auto_indent`, but nothing in `src/app/` copies `cfg.editor.auto_indent` into the editor (grep: the only assignments `ed.auto_indent = true` are in `insert.zig` tests at lines 244/262). The config field and the `:set` toast are therefore decorative.

## Fix

`0828358` on branch `vim-edit` — editor: auto_indent reaches the buffers, with smartindent's braces. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
