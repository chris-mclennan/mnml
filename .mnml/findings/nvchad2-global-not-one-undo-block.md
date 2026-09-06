---
severity: SEV-2
status: fixed
---
# `u` after `:g/pat/normal …` or `:g/pat/s//…/` undoes only the last matching line

**Command ids:** `:g` / `:v` (`src/app/ex_verbs.zig` `global`), `editor.undo`.

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":g/a/norm A;\n"}
{"cmd":"type","text":"u"}
{"cmd":"snapshot"}
{"cmd":"type","text":":g/o/s/o/0/g\n"}
{"cmd":"type","text":"u"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after :g/a/norm A; then u:        after :g/o/s/o/0/g then u:
  1 alpha bravo charlie;            1 alpha brav0 charlie;
  2 delta echo foxtrot;             2 delta ech0 f0xtr0t;
  …                                 …
  8 victor whiskey xray;            8 victor whiskey xray   <- only this line undone
  9 yankee zulu                     9 yankee zulu;
```

**Expected**: one `:g` command is one undo step (`:help :g`, `:help undo-blocks`): a single `u` removes all nine `;` / all the `0`s. (`:%s/…/…/g` *is* a single step here — `u` after it restores every line.)

**Actual**: each per-line sub-command is its own undo entry; `u` peels back one line at a time. A user who runs a wrong `:g/…/norm …` over a 300-line file has to press `u` 300 times or `:e!`. Two launches, both sub-command kinds.

**Source pointer**: `src/app/ex_verbs.zig` `global` — runs the sub-command per line without opening/closing one undo group around the loop; `src/editor/undo.zig` group API exists (the insert-session grouping from `2376e20` uses it).

## Fix

Commit `782e27e` — `global` wraps the per-line loop in one atomic undo group. Test: `tests/e2e-zig/vim_global_one_undo.test`.
