# nvchad-user round 10 findings

Session date: 2026-07-11. Binary: `~/Projects/mnml/target/release/mnml --input vim`.
Workspace: `/tmp/mnml-nvchad-r10/`.

## Executive summary

- **SEV-1**: 0
- **SEV-2**: 6 (`zj`/`zk` regressed on nested folds, `:norm` leaves buffer in
  insert mode between lines, `|` command chain creates files with `|` in the
  name, `:new` opens Cloud-Agents dialog, `Ctrl-X Ctrl-F` opens Find prompt
  instead of file-path completion, `:make` demands a `[tasks.make]` config)
- **SEV-3**: 8 (`:cd`/`:lcd`, `:tabnew` isn't tab-pages, `:earlier N[sm]`
  parses `s/m` as unit noise but counts steps not time, `:set autoread`
  "not supported" while behavior is already on, many `:set` options missing,
  `!<text-object>` documented no-op, drag-reorder is swap-not-splice, `:tabs`
  silently returns nothing)

Round 9 landed fixes verified live in this build:
- `!!` and `!<motion>` filter operator — prompt opens, shell command pipes
  the linewise range through (`!!` → `tr a-z A-Z` uppercases current line;
  `!j` → `tr a-z A-Z` uppercases 2 lines; `!G` → filters to EOF).
- `Ctrl-R #` (alt-buffer path) — inserts the alternate buffer's filename in
  insert mode.
- `Ctrl-R :` (last ex-command) — inserts the previous ex-command text.
- `[[` / `]]` section nav — `]]` from top of `prog.rs` walks fn foo → fn bar
  → fn baz; `[[` walks back.
- `zM` bracket-scan fallback — toast "zM — folded 5 block(s)"; fn foo, fn bar,
  fn baz + inner blocks all collapse.
- Visual `zf` fold-create — V+3j+zf collapses the 3-line range under a fold
  header.
- `:{range}sort` — `:1,4sort` reorders only lines 1-4.
- `:sort n` (numeric) — 10, 2, 100, 1, 20 → 1, 2, 10, 20, 100.
- `:sort r` (reverse) — reverses (lexical). `:sort nr` — reverse numeric.
- Ctrl+O jumplist — `3G`, `7G`, `10G`, then 3× Ctrl+O walks 10 → 7 → 3 → 1
  (last two are the last two positions plus the very first opened-at-1
  entry).
- `:e! path` — reloads from disk, drops in-memory edits (round 9 SEV-1 fixed
  — reopening the previously-dirty buffer via `:b` shows disk content and
  dirty=false).
- Vim regex grammar in `:%s` and `/…` — `\(color\|colour\)` matches both,
  `\<hello\>` word boundaries match `hello` but not `Hello` (case
  sensitivity respected — with mnml's default ignorecase both `Hello` and
  `hello` match `/hello`).
- Macros with special keys — `qa I<# > Esc j q` records; `3@a` replays,
  Down-arrow inside the recording works.

Round 9 fixes that regressed or are only partly working:

## [SEV-2] `zj` / `zk` silently fail after `zM` produces nested folds

**Reproduction** (fresh workspace with `prog.rs` containing three functions
each with a nested block — see appendix):
```
{"cmd":"open","path":"prog.rs"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"M"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"j"}
```

**Expected**: Cursor jumps to next visible fold header (fn bar at line 8).
**Actual**: Cursor stays at line 1. No toast. No visible change.

**Why**: `fold_all_brackets_in_active` (src/app/mod.rs:9531) writes 5 fold
entries into the BTreeMap for prog.rs — three function bodies + `if x > 0
{ }` inside foo + `for i in a { }` inside baz. `fold_next_in_active`
(src/app/mod.rs:9655) does `folds.keys().find(|&s| s > cur_row)` which lands
on the nested `if` at row 2. `place_cursor(2, 0)` moves to a row that's
hidden inside foo's fold; a subsequent snap/paint keeps the display cursor
at the fold header (row 0) so status.json still reports `line:1` — and no
toast fires because the else branch never runs (both `next` and
`active_editor_mut()` were Some). Verified by creating a single, non-nested
fold via V+3j+zf: `zj` then correctly jumps to it.

**Fix pointer**: filter nested folds out of the walk, e.g. `find(|&s| s >
cur_row && b.fold_owner_of(s).is_none())`.

**Source pointer**: src/app/mod.rs:9655-9668 (also 9670-9684 for `zk`).

---

## [SEV-2] `:{range}norm <cmds>` leaves the buffer in INSERT mode when the last normal-mode command is `A`/`I`/`i`/`o`

**Reproduction** (fresh `numbers.txt` = `10\n2\n100\n1\n20`):
```
{"cmd":"open","path":"numbers.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"escape"}
{"cmd":"type","text":":1,3norm A_END\n"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

**Expected**: Every line 1-3 gets `_END` appended (`10_END`, `2_END`,
`100_END`); mode returns to NORMAL between iterations and after the last
one.
**Actual**: Line 1 = `10_END` ✓. Line 2 = `A_END2` ✗ (the whole `A_END`
was typed as literal text at position 0). Line 3 = `A_END100` ✗ (same).
Mode after the command = INSERT. Every subsequent keystroke — including
the next `u` for undo — types as text.

Follow-up damage: the very next `:1,3norm dd` typed becomes literal buffer
text (`u:1,3norm dd\n`) since we're stuck in INSERT.

**Why**: The `:norm` implementation appears to execute the sequence once,
then not synthesize the implicit `Esc` that vim treats as terminating the
`A`/`I`/`i`/`o` after each line iteration. In vim the `norm` command
enforces "start each line in normal mode and end each line in normal mode",
even if the sequence ended in insert.

**Source pointer**: `src/app/ex_commands.rs` — grep for `norm` / `Normal`
range handler. The interpreter needs a "force normal-mode exit" between
iterations and after the last one.

---

## [SEV-2] `|` (command chain) is treated as part of a filename — even creating a file literally named `| e b.txt`

**Reproduction** (fresh workspace with `regex.txt`):
```
{"cmd":"open","path":"regex.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"escape"}
{"cmd":"type","text":":w | e a.txt\n"}
{"cmd":"wait_ms","ms":300}
```

**Expected**: `:w` saves current buffer, then `:e a.txt` opens `a.txt`.
Vim's `:h :bar` — commands separated by `|` execute in sequence.
**Actual**: mnml writes to a file whose literal name is `| e a.txt` (yes,
with the pipe as part of the filename); after this test I found
`/tmp/mnml-nvchad-r10/| e a.txt` on disk. Follow-up `:e a.txt | e b.txt`
opens buffer titled `a.txt | e b.txt` — same pathology, different arm.

**Expected**: at minimum, the `|` should be rejected with an "ex-command
chaining is not supported" toast; ideally it should chain like vim.

**Source pointer**: `src/app/ex_commands.rs` — the `:w` / `:e` argument
parser needs to split on unescaped `|` (respecting `\|`).

**Cleanup**: `rm '/tmp/mnml-nvchad-r10/| e a.txt'`.

---

## [SEV-2] `:new` opens the "+ New Agent from PR" cloud-agents dialog instead of vim's new empty split

**Reproduction**:
```
{"cmd":"key","key":"escape"}
{"cmd":"type","text":":new\n"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

**Expected**: New empty scratch buffer in a horizontal split (vim canon).
Or, if truly unsupported, a toast + no action.
**Actual**: mnml opens a Cloud-Agents pane titled "+ New Agent from PR"
(visible in status.json `panes` list). A vim user who reflexively types
`:new` for a scratch pad ends up in the wrong overlay.

**Source pointer**: `src/app/ex_commands.rs` — the `new` arm needs
disambiguation. `:new` is common enough (part of every vim cheatsheet) that
squatting on the name is user-hostile.

---

## [SEV-2] `Ctrl+X Ctrl+F` opens the Find prompt instead of firing insert-mode file-path completion

**Reproduction**:
```
{"cmd":"open","path":"regex.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"/tm"}
{"cmd":"key","key":"ctrl+x"}
{"cmd":"key","key":"ctrl+f"}
{"cmd":"wait_ms","ms":300}
```

**Expected**: A filename picker suggesting `/tmp/…` completions (vim
`i_CTRL-X_CTRL-F`).
**Actual**: The "Find" prompt overlay opens — Ctrl+F was intercepted as
global find-in-buffer while still in insert mode. Ctrl+X does nothing on
its own so the vim insert-mode chord `Ctrl+X Ctrl+F` has no way to fire.

**Note**: `Ctrl+X Ctrl+N` word completion DOES work (verified — typed `he`
then Ctrl+X Ctrl+N and a popup listed `hello` from the buffer, Tab accepted).
Only the file variant is blocked.

**Source pointer**: `src/input/vim.rs` — the Ctrl+X insert-mode chord table
needs a Ctrl+F arm (or Ctrl+F handling in Insert has to defer to Ctrl+X
being pending).

---

## [SEV-2] `:make` demands a `[tasks.make]` config entry — vim expects it to shell out to `make` and populate quickfix

**Reproduction**:
```
{"cmd":"type","text":":make\n"}
```

**Expected**: Run the workspace's `makeprg` (default `make`), capture
stdout/stderr, populate quickfix, jump to first error. Or if the workspace
has no Makefile, a "no Makefile" toast.
**Actual**: Toast "unknown task: make · :make — no [tasks.make] in
config". mnml overloaded `:make` for its task-runner subsystem instead of
matching vim's build integration.

`:copen` afterwards correctly says "no quickfix / grep results yet" and
`:cnext` says the same. So the quickfix concept exists — just not wired to
`:make`. Adding a shell fallback (`if no [tasks.make], run makeprg`) would
close the vim gap.

**Source pointer**: `src/app/ex_commands.rs` — grep for the `make` arm.

---

## [SEV-3] `:cd` refuses; `:lcd` is unknown

**Reproduction**:
```
{"cmd":"type","text":":cd /tmp\n"}
{"cmd":"type","text":":lcd /tmp/mnml-nvchad-r10\n"}
```

**Actual**:
- `:cd /tmp` → toast ":cd — workspace is per-session; not changed"
- `:lcd /tmp/mnml-nvchad-r10` → toast ":lcd — unknown command"

**Expected (vim)**: `:cd` changes the global working dir; `:lcd` sets a
window-local one. The mnml opinion "workspace is per-session" is fine for
`:cd`; but `:lcd` should exist too (even as a synonym-with-warning) so
users don't feel every-other-command is broken. And even the global `:cd`
could set the shell / pty CWD without moving the workspace root — vim's
`:pwd` already surfaces the value correctly.

---

## [SEV-3] `:tabnew` / `:tabnext` / `:tabprev` / `:tabclose` operate on the bufferline strip, not vim tab pages

**Reproduction**:
```
{"cmd":"type","text":":tabnew\n"}
{"cmd":"type","text":":tabnext\n"}
```

**Actual**: `:tabnew` opens a scratch buffer as another tab in the current
bufferline strip (not a distinct tab page). `:tabnext` / `:tabprev` cycle
between it and the regex.txt (buffer switching). `:tabclose` closes
whichever bufferline tab is focused with the caveat that on a single tab
it toasts "only one tab open".

**Vim expectation**: A tab PAGE is a separate window layout — its own
splits, its own layout tree. Multiple bufferlines. mnml's model doesn't
have this at all (verified: `:tabs` silently returns nothing).

This is a design decision, not a bug per se, but a vim user who reflexively
types `:tabnew` expecting to spin up a fresh split-tree will be surprised.
At minimum toasting "mnml doesn't distinguish tabs from buffers — use
`:vsplit`/`:split` for layouts" would help.

---

## [SEV-3] `:earlier Ns` / `:earlier Nm` counts undo steps, not seconds/minutes

**Reproduction**:
```
{"cmd":"type","text":":earlier 5s\n"}      -> toast ":earlier · 1 step(s)"
{"cmd":"type","text":":earlier 10m\n"}     -> toast ":earlier · 9 step(s)"
```

**Expected (vim)**: `:earlier 5s` walks back to the state 5 seconds ago
(may cross many change-list nodes if you were typing fast; may cross none
if you were idle). `:earlier 10m` walks back 10 minutes.
**Actual**: The `s` / `m` suffix is essentially ignored; the number is used
as a step count. Verified by two runs — `5s` = 1 step, `10m` = 9 steps
regardless of wall-clock timing.

Round 6 flagged the time grammar issue; this build still parses `Ns` /
`Nm` as unit noise and falls back to step-count. If the underlying undo
tree doesn't carry timestamps yet, at minimum "s/m/h suffix not yet
supported" should be surfaced.

---

## [SEV-3] `:set autoread` returns "not supported" but the behavior is on by default

**Reproduction**:
```
{"cmd":"type","text":":set autoread\n"}
```
Then externally: `echo NEW > regex.txt` — mnml auto-reloads and toasts
"regex.txt reloaded".

**Expected**: `:set autoread` → toast "autoread: on" (behavior confirmed).
**Actual**: `:set autoread` → toast ":set autoread — not supported" — but
external changes ARE picked up automatically. The response is misleading;
the user thinks they need to enable it, but it's already on.

Same class of gap for options mnml is opinionated on but doesn't tell the
user "you already have this":
- `:set laststatus` → not supported (mnml has a statusline)
- `:set nofoldenable` → not supported (mnml has folds, so foldenable is
  implicitly on)

---

## [SEV-3] Many core `:set` options missing

**Reproduction**: `:set tabstop`, `:set shiftwidth`, `:set textwidth`,
`:set textwidth=80` all return `— not supported`. Also `:set laststatus`,
`:set nofoldenable`.

**Verified working**: `list` / `nolist`, `hlsearch`, `incsearch`,
`smartcase`, `wrap` / `nowrap`, `nu` / `nonu`, `relativenumber`,
`expandtab`, `colorcolumn=80`.

**Note**: `tabstop`/`shiftwidth`/`expandtab`/`textwidth` are the four
options a vim user reaches for daily. Even a stub that toasts "value read
from config, not per-buffer" would be better than "not supported" (which
implies mnml doesn't have the concept — but it does; expandtab is
recognized).

---

## [SEV-3] `!<text-object>` (e.g. `!ip`, `!ap`) is a documented no-op

**Reproduction**:
```
{"cmd":"key","key":"!"}
{"cmd":"key","key":"i"}
{"cmd":"key","key":"p"}
```

**Actual**: `!ip` (filter inner paragraph) — no prompt opens; the operator
state is consumed silently. Comment at src/input/vim.rs:1747 explicitly says
"Simpler MVP: no-op for text objects".

**Expected**: `!ip` prompts for shell command, then filters the paragraph.
This is a very common idiom (piping a JSON block through `jq .` for
reformatting is the canonical use case). `!<motion>` works — but text
objects hit a bigger set of use cases.

Bonus foot-gun: leaving `!ip` in the language but making it silent puts the
vim handler in a subtly-broken pending state. The `!ip` no-op doesn't reset
`self.op` on all code paths, so the next `type` command lands in a
handler that hasn't fully rehydrated to normal mode (repro'd twice mid-
session — after `!ip` + typed shell command, the following normal-mode
keys landed in insert). Cleanest fix: implement text-object filter (needed
anyway); interim fix: hard `reset_pending()` at src/input/vim.rs:1754.

---

## [SEV-3] Bufferline drag-reorder swaps tabs, doesn't splice

**Reproduction**:
```
# Setup: panes = [a.txt, b.txt, prog.rs]
{"cmd":"drag","from_col":36,"from_row":1,"col":68,"row":1}   # drag tab 0 onto tab 2
```

**Expected (VS Code / most bufferlines)**: a.txt moves to position 2,
others shift: [b.txt, prog.rs, a.txt].
**Actual**: a.txt swaps with prog.rs: [prog.rs, b.txt, a.txt].

For a vim user this is less of a concern (they use `:bn`/`:bp` or the
palette) but for a nvchad user the mouse-drag reorder is a visible feature.
Round 9 noted "no longer overshoots" — that's fixed (a 1→2 drag stops at
2, not 3). But the swap-vs-splice semantics are still unusual.

---

## [SEV-3] `:tabs` silently returns nothing

**Reproduction**:
```
{"cmd":"type","text":":tabs\n"}
```

**Actual**: No output, no toast, no overlay. No `Unknown` either — so the
handler exists but does nothing.

**Expected (vim)**: A textual list of tab pages, each showing which
buffers are in it. Since mnml doesn't have tab pages proper (see the
earlier finding), this could reasonably toast "mnml has no tab pages —
`:ls` lists buffers".

---

## Positive: things that work well

The vim-competent surface remains strong. Verified in this session:
- `Ctrl+X Ctrl+N` word completion — popup shows buffer words, Tab accepts.
- `:set list` / `:set nolist` — end-of-line `$` markers render correctly
  (visible in the split test `line·one$`).
- `:!pwd` — runs shell + toasts result.
- `:split <file>` / `:vsplit <file>` — split, opens file in new pane.
- Macros with arrow keys — Down inside a recorded macro replays correctly.
- Ctrl+X modifiers work through — the ipc parser accepts `"ctrl+x"` and
  `"ctrl+n"` as separate chords, no chord-parser regressions.
- `:e! path` reloading own file — buffer content matches disk (validated
  the round 9 SEV-1 fix for the "phantom clean dirty flag" case: dirty
  a.txt, `:e! b.txt`, `:b a.txt` — panes list shows both dirty=false and
  the buffer content is the disk version, not the discarded edit).
- `:sort n` numeric sort, `:sort r` reverse, `:sort nr` reverse numeric —
  all correct.
- File-IPC append behavior — reminder: when hosting IPC scripts, always
  APPEND to `command` (don't overwrite). The `cmd_offset` doesn't reset on
  smaller writes only on truly shorter files, which can leave the loop
  reading mid-line and producing `key_unparsed` events.

## Deep-dig items not fully covered

- `Ctrl+X Ctrl+O` (omni completion) — not tested; would need a language
  server running.
- `gd` (LSP definition), `K` (hover), `gr` (references) — not tested this
  round; would need a project with rust-analyzer.
- Macros with function keys / paste — the ipc parser accepts `"f1"` etc.
  in `parse_key_spec` but I didn't drive a full record/replay with F-keys
  since the mnml keymap has no F-key bindings by default.
- `:diffsplit` / diff mode entrance — not tested.

## Files exercised

Workspace `/tmp/mnml-nvchad-r10/`:
- `a.txt`, `b.txt`, `regex.txt`, `sort.txt`, `numbers.txt`, `prog.rs`
- Appendix `prog.rs`:
```
fn foo() {
    let x = 1;
    if x > 0 {
        println!("positive");
    }
}

fn bar() {
    let y = 2;
    let z = y + 1;
}

fn baz() {
    let a = vec![1, 2, 3];
    for i in a {
        println!("{}", i);
    }
}
```
