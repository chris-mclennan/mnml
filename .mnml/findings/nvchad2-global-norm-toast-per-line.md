---
severity: SEV-3
status: fixed
---
# `:g/pat/normal …` and `:g/pat/s//…/` raise one toast per matching line (`:norm — 1 line(s)` ×9, `+9 more…`) on top of the `:g` summary

**Command ids:** `:g` (`src/app/ex_verbs.zig` `global`) running `:normal` / `:s` sub-commands; the toast stack.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":g/e/norm A;\n"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
right edge of screen.txt, rows 22-36:
│ +9 more…         │
│ :norm — 1 line(s) │
│ :norm — 1 line(s) │
│ :norm — 1 line(s) │
│ :g — ran on 9 line(s) │
```

**Expected**: one summary (`:g — ran on 9 line(s)`), as Vim prints one message for the whole `:g` (the per-line sub-command output is suppressed inside `:g`).

**Actual**: each sub-command toasts individually; on a 300-line file that is 300 toasts collapsed into `+N more…` that hides the summary and any real error for ~5 s (toasts do expire, so this is noise not a leak). Same class as the fixed tab-switch pile-up (`5063074`). Two launches.

**Source pointer**: `src/app/ex_verbs.zig` `global` — no toast-suppression / `toastReplace` around the per-line dispatch.

## Fix

Commit `db51eb9` — toasts are dropped while `in_global` is set; `:g` clears it before its own summary. Test: `tests/e2e-zig/vim_global_norm_one_toast.test`.
