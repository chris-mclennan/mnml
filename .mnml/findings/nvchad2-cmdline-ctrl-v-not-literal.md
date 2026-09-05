---
severity: SEV-3
status: open
---
# `Ctrl-V` on the `:` line does not quote the next key — `Ctrl-V Tab` runs completion

**Command ids:** cmdline editing (`src/app/cmdline.zig` / `dispatch.zig` cmdline keys).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"tab"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
statusline cmdline:   :agents.new_from_pr▏      (Tab completed the first command id)
```

**Expected**: `c_CTRL-V` inserts the next key literally (`:help c_CTRL-V`) — a real tab character in the command line, needed for `:s/\t/…/` style edits typed by hand.

**Actual**: `Ctrl-V` is ignored and `Tab` still triggers completion. Two launches.

**Source pointer**: `src/app/dispatch.zig` cmdline key handling — no literal-next state.
