---
severity: SEV-3
status: open
---
# A recorded macro is not visible in `:reg` / `:reg a` and cannot be pasted with `"ap`

**Command ids:** `vim.macro_*` (`qa … q`, `@a`), `:reg` (`src/app/ex.zig` `registers`).

**Reproduction**:
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"q a"}
{"cmd":"key","key":"I"}
{"cmd":"type","text":"- "}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"q"}
{"cmd":"type","text":":reg a\n"}
{"cmd":"snapshot"}
```
**screen.txt**: `│ :reg — empty │`. `@a`, `3@a`, `@@` replay correctly, so the recording exists.

**Expected**: registers and macros are the same store in vim — `:reg a` shows `I- ^[`, `"ap` pastes it (the standard way to edit a macro), `"ayy` after editing re-records it.

**Actual**: macros live in a separate store (`src/editor/buffer.zig` `macroToggle`) invisible to `:reg` and `"ap`. PARITY marks macros `partial` only for persistence, not for this.
