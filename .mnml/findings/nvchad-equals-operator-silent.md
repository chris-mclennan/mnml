---
severity: SEV-3
status: open
---
# `==` / `gg=G` do nothing and say nothing

**Command ids:** vim `=` operator — no entry in `src/input/vim.zig`; `editor.format` (`docs/commands.md` line 301) has no chord in either profile.

**Reproduction** (b.zig line 4 `    return a + b;`):
```
{"cmd":"open","path":"hunt/b.zig"}
{"cmd":"type","text":":4\n"}
{"cmd":"key","key":"< <"}
{"cmd":"key","key":"= ="}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
**screen.txt**: line 4 stays `return a + b;` at column 1; no toast. `gg=G` likewise only moves the cursor to the last line.

**Expected**: `=` re-indents (vim's built-in indent even without an LSP), or at minimum a toast like the one `K` gives (`no language server for this file (hover)`), so the user knows the chord was heard.

**Actual**: silent no-op. Reproduced twice.
