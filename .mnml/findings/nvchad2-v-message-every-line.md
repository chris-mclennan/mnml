---
severity: SEV-3
status: fixed
---
# `:v/pat/d` when every line matches reports `E486: pattern not found` (Vim: "Pattern found in every line")

**Command ids:** `:v` / `:g!` (`src/app/ex_verbs.zig` `global` inverted).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":v/a/d\n"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
│ :v — E486: pattern not found: a │      (buffer unchanged — correct)
```

**Expected**: no line is selected and the message is `Pattern found in every line: a` (Vim's `ex_global`: `type == 'v' ? "Pattern found in every line" : "Pattern not found"`); `E486` is reserved for the `:g` case.

**Actual**: the `:g` wording is reused for `:v`, telling the user the opposite of what happened (`a` is on every line). Behaviour (no deletion) is right. Two launches.

**Source pointer**: `src/app/ex_verbs.zig` `global` — the `ndone == 0` message does not branch on `bang`/inverted.

## Fix

Commit `9f5411c` — `:v` with nothing to act on says "Pattern found in every line"; E486 stays with `:g`. Test: `tests/e2e-zig/vim_vglobal_every_line.test`.
