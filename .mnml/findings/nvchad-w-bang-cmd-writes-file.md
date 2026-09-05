---
severity: SEV-2
status: open
---
# `:w !cmd` writes a file literally named `!cmd` into the workspace root

**Command ids:** `:w` in `src/app/ex.zig` (write-as path).

**Reproduction**:
```
{"cmd":"open","path":"hunt/b.zig"}
{"cmd":"type","text":":w !wc -l\n"}
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```
Then on disk: `ls /Users/chrismclennan/Projects/mnml-zig-worktrees/hunt` shows `!wc -l` (300 bytes, the buffer contents); `git status` shows `?? "!wc -l"`. A pane titled `!wc -l` also appears in the bufferline. First seen with `:w !cat` → file `!cat`.

**Expected**: `:w !cmd` pipes the buffer to `cmd` (vim) — or, since `:!` / `:r !` are listed as Remaining in PARITY, an "unsupported" toast. It must not create a file whose name starts with `!`.

**Actual**: the argument is taken as a filename; a stray file is created and left in the repo. Reproduced twice.

**Source pointer**: `src/app/ex.zig` `:w <arg>` — no check for a leading `!`.
