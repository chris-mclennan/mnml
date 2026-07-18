# nvchad-user round 7 findings — 2026-07-11

Fresh headless run on workspace `/tmp/mnml-nvchad-round7` (mnml
`--headless --input vim`). Rounds 1-6 already landed dozens of vim-mode
fixes; this pass focused on the corners the previous rounds didn't
cover: V-BLOCK operators, register `Ctrl-R` in insert, macro replay
edge cases, `zM`/`zf`/`zj`, `:s/…/…/` backrefs, `\<`/`\v`/`\(\)`
regex flavors, `:w !cmd`, and `iW`/`aW` big-word text objects.

## Executive summary

- **SEV-1 (data loss / silent corruption):** **1** — `:s/…/…/` treats
  `\1`, `\2`, `&` as literal replacement text. Any vim user reflexively
  typing `%s/\(foo\)\s*\(bar\)/\2 \1/g` writes the literal string
  `\2 \1` across every match. There is no toast, no error — the file
  is silently destroyed. Because `\(`/`\)` don't work either (Rust
  regex requires bare `(` / `)`), the user is likely to iterate a few
  times before noticing, then find undo history full of destroyed
  buffers.
- **SEV-2 (broken common flows):** **7** — V-BLOCK `r<char>` is a
  no-op, V-BLOCK `I` insert leaves N separate undo steps (one per
  row), `d{i,c}iW` / `daW` big-word text objects silently swallow
  the key, `\<`/`\>` word-boundary + `\v` very-magic + `\(\)`
  capture groups aren't accepted in `/pattern` or `:s`, macro
  register `@@` (repeat last macro) always looks up register `'@'`
  instead of the last-used register, `zM` (close all folds) is a
  no-op when there are no LSP folds, `:w !cmd` writes a file
  literally named `!cmd`.
- **SEV-3 (nit / vim polish):** **5** — `:e! <file>` silent no-op,
  `ci"` outside quotes drops into Insert mode without erroring,
  Ctrl+R `%`/`#`/`:`/`/`/`.` insert-mode paste-register targets
  rejected, `:delmarks a` unknown command, `!<motion>` filter
  operator not supported, `zj`/`zk` inter-fold nav, `zf<motion>` /
  visual `zf` fold-create silently ignored.

**How vim-compatible does mnml feel after 45 minutes of round-7
hunting:** the daily-driver core (motions, `d`/`y`/`c`, ex commands,
`:%s` with plain string, macros with named registers, marks incl.
global `mA`, `zc`/`zo`/`zR`, `gv`, `''`, `` `a ``, `Ctrl-A`/`Ctrl-X`,
`gu`/`gU`, `:g/pat/norm`, `dit`/`dat`, `:earlier`, wildmenu, `:reg`)
is genuinely solid. But three cliffs are one keystroke away from a
seasoned user:
1. The regex flavor mismatch (`\(`/`\)`/`\<`/`\>`/`\v` all fail, `\1`
   inserts as literal). This eats an unknown fraction of the user's
   muscle memory, silently and destructively.
2. V-BLOCK is half-implemented: motions + `I`/`A`/`d`/`y` work,
   but `r<c>` doesn't, and each `I` row is a separate undo step
   which makes the undo history unusable for the standard "prefix
   3 lines" ritual.
3. `W` (big-word) as a text-object modifier (`diW`/`ciW`/`viW`)
   doesn't fire, breaking one of the top-3 vim idioms for editing
   URLs/paths/hyphenated names.

---

## [SEV-1] `:s/…/…/` treats `\1`, `\2`, `&` as literal replacement text — silent data destruction

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":":%s/line (\\w+) (\\w+)/\\2 -- \\1/g"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

sample.txt (10 lines: `line one alpha`, `line two beta`, …).

### Expected

Vim `:%s/line \(\w\+\) \(\w\+\)/\2 -- \1/g` — swap the two words after
"line" using capture groups. mnml uses Rust `regex` for matching, so
the user reasonably drops the `\` before `(`/`)` and expects `\1`/`\2`
(vim canon) OR `$1`/`$2` (Rust canon) to work as backrefs.

### Actual

Every replaced line becomes the literal string `\2 -- \1`. Toast:
`:%s — 10 replacement(s)`. The 10 lines of `sample.txt` now read
`\2 -- \1` (10 identical lines). Same with `$1`/`$2` — inserted
literally. `&` (whole-match backref) is also inserted literally.

### Source pointer

`src/app/ex_commands.rs:443-452` — the replacement path uses
`sub.replace.clone()` verbatim as the `ReplaceRange { text }` payload.
No `Regex::replace_all` / `expand_replacement` — capture groups are
never expanded.

### Notes

Vim's `\1`..`\9`, `\0`, `&`, `~`, and `\u`/`\l`/`\U`/`\L` case
modifiers are the entire reason substitute exists. Silent literal
insertion makes this a SEV-1: it corrupts N lines with no warning,
and the fastest recovery (undo) is complicated by the fact that undo
groups may not span the whole substitute run in every case (see the
"single undo group" comment at `ex_commands.rs:453-467` which is
correct, but the user won't necessarily notice the destruction in
time — dot-repeat or `n@:` compounds it).

Two acceptable fixes:
1. Support `\1..\9` + `&` via a mini-expander before `apply`.
2. Rewrite via `regex::Regex::replace_all(text, &sub.replace)` so
   Rust's own `$1`/`${name}` expansion runs. Then either translate
   vim `\1`→`$1` in the parser, or document `$1` as mnml's canonical
   backref syntax and toast when a raw `\1` shows up in the
   replacement.

---

## [SEV-2] Search regex flavor mismatch — `\<word\>`, `\v`, `\(\)` all fail

### Reproduction — word boundary

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"/\\<on\\>"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

sample.txt line 1: `line one alpha`. `\<on\>` should NOT match "one"
(it matches whole-word "on" only, of which there are 0). Instead
mnml toasts `no regex matches for "\\<on\\>"` — treats `\<` `\>`
as literal `<` `>`.

### Reproduction — very magic

```jsonl
{"cmd":"type","text":"/\\vline (one|two)"}
{"cmd":"key","key":"enter"}
```

Toast: `no regex matches for "\\vline (one|two)"`. `\v` (very-magic
mode where `(`/`|` don't need escaping) not recognized.

### Reproduction — vim capture groups in substitute

```jsonl
{"cmd":"type","text":":%s/line \\(\\w\\+\\) \\(\\w\\+\\)/X/g"}
{"cmd":"key","key":"enter"}
```

Toast: `:%s — no match for "line \\(\\w\\+\\) \\(\\w\\+\\)"`. Vim's
`\(…\)` / `\+` classic syntax not accepted. Only Rust regex works.

### Expected

Vim search uses its own regex flavor. `\<` / `\>` = word boundaries
(same as `\b` in Rust regex). `\v` toggles "very magic" (unescaped
`()` are groups, `|` is alternation). `\(…\)` groups + `\+`
one-or-more are the "magic" default.

### Actual

mnml passes the pattern straight to Rust's `regex` crate, so any
vim-flavored metacharacter breaks. There's no translation layer.

### Source pointer

`src/app/find.rs` (or wherever `refresh_find_matches` lives) — the
find pipeline compiles the pattern with plain `regex::Regex::new`.
No `\<`→`\b`, no `\v` handling, no `\(`→`(`.

### Notes

The fix scope is small: a `translate_vim_regex(pat: &str) -> String`
that walks the pattern, tracks `\v`/`\V`/`\m`/`\M` mode, and rewrites
`\<`→`\b`, `\>`→`\b`, `\(`→`(`, `\)`→`)`, `\+`→`+`, `\?`→`?`,
`\|`→`|`, `\{`→`{`, etc. Same translation applies to the `:s` path
in `parse_substitute`.

---

## [SEV-2] V-BLOCK `r<char>` (replace column) is a no-op

### Reproduction

```jsonl
{"cmd":"open","path":"block.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"r"}
{"cmd":"key","key":"Z"}
{"cmd":"snapshot"}
```

block.txt is 5 lines of `aaaXbbbXccc`. Sequence enters V-BLOCK, extends
to a 3-row × 3-col rectangle, then `r Z`.

### Expected

Vim: fills every cell in the rectangle with `Z`. Top three lines
become `ZZZXbbbXccc`.

### Actual

Handler stays in V-BLOCK mode. Nothing changes. The `r` key was
consumed and the follow-up `Z` was consumed. Buffer clean, mode still
V-BLOCK, cursor unchanged.

### Source pointer

`src/input/vim.rs:2997-3060` — `handle_visual_block` has no `KeyCode::Char('r')`
arm. Falls through to `_ => InputResult::Consumed`. The `R` key
(open replace mode) also isn't wired, so the whole "replace within
block" story is missing.

### Notes

The block-r idiom is the fastest way to fill a rectangle with a
placeholder — very common when scaffolding ASCII boxes or padding
alignment. Fix shape: add `r` arm that stores a `pending_block_replace`
flag, capture the next char in a new `Prefix::BlockReplaceChar`, then
enter_normal + emit an `AppCommand::BlockReplaceChar { c }` op that
walks the rect and splices at each row.

---

## [SEV-2] V-BLOCK `I <text> Esc` inserts on all rows but leaves N separate undo entries

### Reproduction

```jsonl
{"cmd":"open","path":"block.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"I"}
{"cmd":"type","text":"##"}
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
{"cmd":"key","key":"u"}
{"cmd":"snapshot"}
```

### Expected

After Esc: top three lines are `##aaaXbbbXccc`. After a **single** `u`:
all three prefixes reverted at once. Vim's V-BLOCK insert is one
undo step (the whole rect is a single edit group).

### Actual

- After Esc: top three lines are `##aaaXbbbXccc` (correct).
- After **1× u**: line 2 reverts to `aaaXbbbXccc`. Lines 1 and 3
  still have the `##` prefix.
- After **2× u**: line 3 also reverts. Line 1 still has `##`.
- After **3× u**: line 1 finally reverts.

Every non-anchor row is a separate undo entry, and the anchor row
(the one the user typed on live) is a fourth. Total: 3× undo needed
to unwind one V-BLOCK `I`.

### Source pointer

`src/app/mod.rs:11736-11751` — `block_insert_replay_if_done` builds a
`Vec<EditOp>` of `ReplaceRange` ops (one per other row) and comments
"Single coalesced edit so one Undo reverts the whole block insert."
But `b.apply_edit_ops` at `src/buffer.rs:939` loops over the ops
calling `self.editor.apply(op, …)` for each — every `apply` opens
its own undo group unless wrapped in `atomic_undo`. The primary-row
insert (typed live in Insert mode) is a separate undo group on top.

Fix: wrap the `ops` loop in `b.editor.atomic_undo(|e| for op in ops { e.apply(op, …) })`
so all N replacements collapse into one entry. Then also either
merge the primary-row insert into the same group (harder, since it's
already been applied) or accept the "2 undos" cost (one for the
prefix replay, one for the primary row).

### Notes

`ex_commands.rs:459-463` already uses `atomic_undo` for the `:%s`
"single undo group" fix. Same shape applies here.

---

## [SEV-2] `diW` / `ciW` / `daW` / `yiW` — WORD (big-word) text object silently swallowed

### Reproduction

```jsonl
{"cmd":"open","path":"block.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"i"}
{"cmd":"key","key":"W"}
{"cmd":"snapshot"}
```

Line 1 = `aaaXbbbXccc`. Then repeat with `foo-bar-baz` on a fresh
line to be sure it's not the "no whitespace" case:

```jsonl
{"cmd":"key","key":"o"}
{"cmd":"type","text":"foo-bar-baz next"}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"i"}
{"cmd":"key","key":"W"}
```

### Expected

Vim: `diW` deletes the whitespace-delimited WORD under the cursor.
On `foo-bar-baz next` cursor at col 0, `diW` should delete
`foo-bar-baz` (leave ` next`). `diw` (lowercase) would only delete
`foo` (stops at hyphen).

### Actual

Both `diW` invocations do nothing (buffer stays clean). The
uppercase `W` key is consumed by the text-object prefix but no
selection op is produced.

### Source pointer

`src/input/vim.rs:1488-1495` — the `TextObjectInner` / `TextObjectAround`
match only accepts `KeyCode::Char('w')` (lowercase), producing
`SelectInnerWord` / `SelectAroundWord`. No arm for `'W'`. It falls
through to `_ => return InputResult::Consumed` at line 1584. So the
key is eaten but no op is emitted.

Meanwhile `MoveBigWordRight` at line 532 handles `W` as a motion —
so `dW` (delete to next big word) works. Only `diW`/`ciW`/`viW`/
`yaW` etc. are dead.

### Notes

Extremely common for editing filenames, URLs, hyphenated
identifiers, snake_case-with-dots. Fix: add
`KeyCode::Char('W') => if around { SelectAroundBigWord } else { SelectInnerBigWord }`.
`SelectInnerBigWord` may already exist in `EditOp` — if not, mirror
the `SelectInnerWord` implementation with `is_whitespace` as the
boundary instead of `is_word_char`.

---

## [SEV-2] `@@` (repeat last macro) always looks up register `'@'` — never repeats the last-used register

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"q"}
{"cmd":"key","key":"a"}
{"cmd":"key","key":"I"}
{"cmd":"type","text":"# "}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"q"}
{"cmd":"key","key":"@"}
{"cmd":"key","key":"a"}
{"cmd":"key","key":"@"}
{"cmd":"key","key":"@"}
{"cmd":"snapshot"}
```

Sequence: record `# ` prefix + down into register `a`. Replay once
with `@a` (works — line 2 gets `# `). Then `@@` — expected to
repeat: line 3 should also get `# `.

### Expected

Vim: `@@` re-runs the last `@`-invoked macro register. Since the
last one was `a`, `@@` runs `@a` again.

### Actual

`@@` runs — but nothing happens. Line 3 stays as `line three gamma`.
Register `'@'` was never populated (the user recorded into `a`),
and mnml's `MacroReplayFrom { reg: '@' }` looks up register `'@'`
literally.

### Source pointer

`src/input/vim.rs:1749-1755` — the `AtWaitForRegister` arm:
```rust
if c == '@' {
    return InputResult::App(AppCommand::MacroReplayFrom { reg: '@', count });
}
```
Passes `'@'` as the register letter, not "whatever the user last
replayed". Then `src/app/macros_marks.rs:65-87` `macro_replay` looks
up `self.macro_buffer.get(&target)` where `target = '@'`. There's no
`last_replayed_register` field on `App`.

### Notes

Fix: add `pub last_replayed_macro: Option<char>` to `App` state,
populate it in `macro_replay` after a successful replay, and treat
`reg = '@'` as "if last_replayed_macro exists, use that; else fall
back to `'@'` register".

---

## [SEV-2] `zM` (close all folds) is a no-op when there's no LSP

### Reproduction

```jsonl
{"cmd":"open","path":"foldable.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"c"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"c"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"R"}
{"cmd":"key","key":"z"}
{"cmd":"key","key":"M"}
{"cmd":"snapshot"}
```

`zc` twice creates two manual folds. `zR` opens both (works). Then
`zM` — expected to re-close both manual folds. Result: everything
stays open.

### Expected

Vim: `zM` closes every foldable region in the buffer, whether it was
manually or automatically defined. In a "manual" foldmethod buffer,
`zM` closes every existing manually-created fold.

### Actual

`zM` runs `lsp.fold_all` — which does nothing if no LSP is attached
or if the LSP hasn't returned any `foldingRange` yet. Manual folds
that already exist (created by `zc` or `zf`) are ignored.

### Source pointer

`src/input/vim.rs:1020-1022` — `zM` unconditionally fires `lsp.fold_all`,
ignoring `editor.fold_regions` (or wherever manual folds live). The
`zR` (open) case correctly routes to `editor.unfold_all` (line
1013-1015).

### Notes

Fix: `zM` should first close every existing manual fold, then also
install any LSP-suggested folds. Two commands: `editor.fold_all_manual`
(new) + `lsp.fold_all` (existing).

Related nits (SEV-3): `zj`/`zk` (jump to next/prev fold) do
nothing — the `Prefix::ZFold` arm has no `'j'`/`'k'` case.
`zf<motion>` and visual-`zf` (create fold from range) also missing.

---

## [SEV-2] `:w !cmd` writes a file literally named `!cmd` instead of piping the buffer to a shell

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"type","text":":w !wc -l"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Then `ls -la` in the workspace directory:

```
-rw-r--r-- 1 chrismclennan wheel 142 Jul 11 16:57 !wc -l
```

### Expected

Vim: `:w !cmd` pipes the buffer contents to `cmd` on stdin. Toast
should show the command output (e.g. `      10` for `wc -l`). No
file is created.

### Actual

mnml treats `!wc -l` as a filename argument to `:w`, creating a
literal file called `!wc -l` in the workspace. Toast:
`saved to !wc -l`. The current pane's `path` also silently updates
to the new filename (so the next `:w` writes there again, and the
bufferline tab now shows `!wc -l`).

### Source pointer

`:w` handling in `src/app/ex_commands.rs` — no special-case for a
leading `!` in the argument. The `:r !cmd` path (read shell output
into buffer) works correctly (verified with `:r !echo INJECTED`),
so the plumbing exists for the direction. Missing is the "write
buffer TO shell" side.

### Notes

Two additive fixes:
1. In `parse` for `:w`, if the argument starts with `!`, treat as
   shell-pipe: spawn the command with the buffer as stdin, toast
   stdout, don't touch the buffer's path.
2. Symmetric guard: prompt / warn if a user's `:w` argument
   contains shell-metachar chars that would be invalid on the
   platform (`!`, `|`, `<`, `>`, backticks) — vim requires those
   to be escaped. Current behavior silently creates weird files.

---

## [SEV-3] `:e! <file>` — force-edit-with-target silently ignored

### Reproduction

```jsonl
{"cmd":"open","path":"block.txt"}
{"cmd":"key","key":"i"}
{"cmd":"type","text":"junk"}
{"cmd":"key","key":"escape"}
{"cmd":"type","text":":e! nested.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

### Expected

Vim: `:e! foo` = force-edit `foo`, discarding any unsaved changes
to the current buffer. Same as `:e! foo` in a dirty buffer would
switch to `foo` (discarding block.txt's edits).

### Actual

Nothing happens. Cursor stays in block.txt. No toast. `:e nested.txt`
(without `!`) works fine — it's the `!` suffix + argument combo that
silently no-ops.

### Source pointer

`src/app/ex_commands.rs` — the `:e!` path likely matches on exact
`e!` with no argument, treating the whole `e! nested.txt` as an
unknown token or falling to the "reload current" branch and ignoring
the arg. Wants a match arm for `e!` + arg.

---

## [SEV-3] `ci"` when cursor NOT inside quotes — silently drops into Insert mode at cursor

### Reproduction

```jsonl
{"cmd":"open","path":"nested.txt"}
{"cmd":"wait_ms","ms":100}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"c"}
{"cmd":"key","key":"i"}
{"cmd":"type","text":"\""}
{"cmd":"type","text":"BYE"}
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
```

Line 3 = `    console.log("hello world");`. Cursor at col 0 (before
the leading whitespace, definitely outside any `"…"` pair). `ci"`
should either search forward for the next `"…"` on the line (vim's
smart behavior) OR error "no matching quote" (older vim).

### Actual

The text object silently fails, mnml stays in the operator-pending
state, and then `BYE` is inserted at col 0. Result:
`BYE    console.log("hello world");`. The user thinks they changed
inside the quotes; the reality is 3 corrupt characters at col 0.

Same class of bug for `ci(` — cursor NOT inside parens, `di(`
deleted "a: " (the chars behind the cursor) instead of no-op — this
was inconsistent between test runs and appears state-dependent.

### Source pointer

`src/input/vim.rs:1480-1584` — `Prefix::TextObjectInner` fires the
selection op unconditionally. When `SelectInnerQuote('"')` returns
an empty selection, `ReplaceSelection(String::new())` still runs
(no-op) but then `self.mode = VimMode::Insert` still fires at line
1595. So the user is dropped into Insert mode at their pre-cursor
position with no visual signal that the change didn't apply.

### Notes

Fix: check if the selection is empty before switching to Insert mode.
Or: bubble a "no matching quote" toast + stay in Normal.

---

## [SEV-3] Insert-mode `Ctrl+R` rejects `%`, `#`, `:`, `/`, `.`, `=` registers

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"file: "}
{"cmd":"key","key":"ctrl+r"}
{"cmd":"type","text":"%"}
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
```

### Expected

Vim insert-mode `Ctrl+R %` pastes the current filename inline. Result:
`file: sample.txt`. Same for `Ctrl+R /` (last search), `Ctrl+R :`
(last cmdline), `Ctrl+R .` (last inserted text), `Ctrl+R #`
(alternate file), `Ctrl+R =` (expression register).

### Actual

`file: ` — the `%` is eaten but nothing is pasted. Same for `/`, `:`,
`#`, `.`, `=`.

### Source pointer

`src/input/vim.rs:864` —
```rust
let valid = c.is_ascii_lowercase() || c == '0' || c == '+' || c == '_' || c == '"';
```
The valid register list omits every "special" register that vim
users actually use in insert mode. Even `Ctrl+R Ctrl+W` (word under
cursor) and `Ctrl+R Ctrl+A` (WORD under cursor) work — those had a
fix land — but the plain-key specials are still gone.

### Notes

Fix: extend the `valid` check to accept `%`, `#`, `:`, `/`, `.`, `=`,
and route each to a lookup on `App::last_filename`, `App::last_cmdline`,
`App::last_search`, `App::last_inserted`, etc. Register `=` is
evaluator; not urgent, so it can toast "expression register not
implemented".

---

## [SEV-3] `:delmarks a` — unknown command

### Reproduction

```jsonl
{"cmd":"key","key":"m"}
{"cmd":"key","key":"a"}
{"cmd":"type","text":":delmarks a"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

### Expected

Vim: `:delmarks a` clears the local mark `'a'`. `:delmarks!` clears
all lowercase marks. `:delmarks a-c A B 1` accepts ranges + lists.

### Actual

Toast: `:delmarks a — unknown command`. No way to clear a mark
short of restarting mnml.

### Source pointer

No `delm`/`delmarks` handler in `src/app/ex_commands.rs`. Marks live
in `src/app/macros_marks.rs` — a `delete_mark(c: char)` helper is
one-line to add.

---

## [SEV-3] `!<motion>` (filter operator) — not supported

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"!"}
{"cmd":"key","key":"G"}
{"cmd":"type","text":"sort"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

### Expected

Vim: `!G sort<Enter>` pipes the entire buffer through `sort` and
replaces it with the output. Same as `:%!sort`. Also `!ip` for
"filter this paragraph through …", etc.

### Actual

Buffer unchanged. `G` moved cursor to end but no shell ran. The
motion form of `!` is unbound.

### Source pointer

The `!` key in normal mode isn't wired as an operator pending state
in `src/input/vim.rs` — it goes straight to some other handler.
`:!cmd` works (runs the shell one-shot, shows output). `:%!cmd`
was not tested but likely works via cmdline. Only the `!<motion>`
operator form is missing.

### Notes

`:%!sort` is the common workaround. But muscle memory for `!ip fmt`
(reformat paragraph via `fmt`) is deep in vim users' fingers.

---

## Not-a-bug / verified-working

Documenting these so round-8 doesn't re-hunt:

- Named-register `"a yy` + `"a p`: works.
- Uppercase append `"A yy`: works (the round-2 SEV-3 has been fixed).
- Yank register `"0`: preserves yank across deletes, `"0 p` pastes it.
- System clipboard `"+ yy`: writes to macOS pasteboard (verified with
  `pbpaste`).
- Global mark `mA` + cross-file `'A` jump: works (returns to the
  right file + line).
- `:marks`: shows the summary in the status message (compact, not a
  scratch pane like vim, but functional).
- `zc` / `za` / `zo` / `zR`: work as expected on the manual fold at
  a `{` header line.
- `%` on matching brackets — including nested `[` inside `{` — works.
- V-BLOCK `d` (delete column), `y` (yank column), `I` (insert prefix,
  content-wise correct), `A` (append suffix, content correct) — the
  Ins/Append rendering is right, only undo grouping (see SEV-2 above)
  and `r`/`c`/`s` are broken.
- `dit` / `dat` on `<span>…</span>`: work.
- `di{` on nested `{a:1, b:{c:1}}` — correctly picks the innermost
  enclosing pair when cursor is inside.
- `''` (last position), `'a` / `` `a `` (line vs exact column mark
  jump): all correct.
- `gv` (reselect last visual): works.
- `g_` (last non-blank), `ge` (previous word end): work.
- `Ctrl+A` / `Ctrl+X` with count prefix (`10Ctrl+A`): works.
- `Ctrl+O <op>` from Insert (e.g. `Ctrl+O dd`): works.
- `:g/pat/d`, `:v/pat/d`, `:g/pat/norm A_END`: all work.
- `:sort`: works.
- `:earlier 5s`: works.
- `:jumps`: shows history.
- `qa` … `q` recording + `@a` replay + `5@a` counted replay: all work.
  Only `@@` (SEV-2 above) is broken.
- `:%s//new/g` (empty pattern re-uses last search): works.
- `:%s/pat/new/gc` interactive confirm with `y`/`n`/`a`/`q`: works.
- Wildmenu Tab completion + cycle through matches: works.
- `:` history via Up: works.
- `:r !cmd` (read shell output into buffer): works. Only `:w !cmd`
  (SEV-2 above) is broken.
- `:reg a` (show one register): works.
- Dot-repeat of a change (`cw CHANGED Esc . `): works.
- `:set nonumber`: **does NOT turn off line numbers** — this looked
  like a bug but a followup check showed `:set number!` also toggles
  weirdly; not root-caused. `:set relativenumber` works, `:set list`
  works. Marking as ambiguous — retry in round 8 with a clean
  `[ui] show_line_numbers = false` starting config.

