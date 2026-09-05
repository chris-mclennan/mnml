---
severity: SEV-3
status: fixed
---
# `q{A-Z}` (append to a macro register) is not accepted; the pending `q` then turns the next `:` into `q:`

**Command ids:** vim `q` (`src/input/vim.zig` `.macro_record_target`), `view.cmdline_history`.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"qaI- "}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"q"}
{"cmd":"type","text":"qAA!"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"q"}
{"cmd":"snapshot"}
{"cmd":"type","text":":reg a\n"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after qAA!<Esc>q:  1 - alpha bravo charlie!     statusline left edge shows  q   (recording pending)
after :reg a⏎:     panes [a.txt, "cmdline history"], mode none
  cmdline history · 0 entries · enter re-runs · esc closes
```

**Expected**: `qA` appends to register `a` (`:help q`: `q{0-9a-zA-Z"}` — "uppercase letter appends"); `A!<Esc>` is recorded, `q` stops, `:reg a` shows `I- <esc>A!<esc>`.

**Actual**: `A` is rejected as a register: the first `q` is dropped, `A!<Esc>` runs live, the trailing `q` starts a *new* pending record, and the `:` of `:reg a` completes it as `q:` — the cmdline-history pane opens and `reg a⏎` is typed into it. Two launches.

**Source pointer**: `src/input/vim.zig:1005` — `if (c >= 'a' and c <= 'z')` only; no `'A'..'Z'` branch (and no `"`/digit registers); the `return .consumed` on line 1009 leaves nothing recording but the `q` at line ~997 has already been consumed.

## Fix

Commit `4809409` — `q{A-Z}` records into the lowercase register, appending; `@{A-Z}` replays it. Test: `tests/e2e-zig/vim_macro_append_upper.test`.
