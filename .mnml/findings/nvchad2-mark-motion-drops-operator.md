---
severity: SEV-2
status: fixed
---
# `d'a`, `` y`a ``, `V'a` — `'`/`` ` `` are not accepted as a motion after an operator or in Visual; the operator is dropped and `a` enters Insert

**Command ids:** vim operator + `'{mark}` / `` `{mark} `` motion; V-LINE `'{mark}` (`src/input/vim.zig` operator-pending motion table, `.mark_jump_line` only exists at the top level).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":5\n"}
{"cmd":"type","text":"ma"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"d'a"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"mb"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"V'bd"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after d'a:  status "mode":"INSERT","cursor":{"line":1,"col":2}, buffer clean (nothing deleted)
after V'bd: Ln 1/8 — one line deleted (V, then `b` as back-word, then d), not lines 1-9
```

**Expected**: `d'a` deletes lines 1–5 linewise (`:help '`: a mark is a motion; `d'a` is the textbook way to delete to a mark); `` y`a `` yanks charwise to the mark; `V'b` extends the selection to line 9 so `d` empties the buffer.

**Actual**: `'`/`` ` `` after `d`/`y`/`c` and inside Visual are ignored; the following register letter is then executed as a normal command — `a` → append → Insert mode with the operator lost, `b` → back-word. In a longer session this is how `d'a` followed by `:w⏎` turns into `a:w⏎` typed into the buffer (seen once). Two launches.

**Source pointer**: `src/input/vim.zig:1406-1413` handles `'`/`` ` `` only in the plain-Normal switch (`self.prefix = .mark_jump_line`); the operator-pending motion table and the Visual-mode key switch have no branch for them.

## Fix

Commit `db69c96` — `'` / `` ` `` after `d` / `y` / `c` and in Visual arm the mark prefix with the operator kept; the buffer builds the range (`operator_to_mark`), linewise or exclusive-charwise. Test: `tests/e2e-zig/vim_operator_to_mark.test`.
