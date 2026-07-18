# nvchad-user round 8 findings — 2026-07-11

Headless hunt against `~/Projects/mnml/target/release/mnml --headless
--input vim` on `/tmp/mnml-nvchad-round8` (fresh workspace).

Two goals: (1) regress-check the 12 round-7 fixes, (2) drill new corners
(visual-mode text objects, live `/search` grammar, inter-fold nav,
insert-mode `Ctrl-R` specials, `!<motion>`, `gv` / back-jumps / section
motions, `:g` / `:v`).

## Executive summary

- **SEV-1**: **0**.
- **SEV-2**: **7** — visual-mode `iX`/`aX` text objects entirely
  broken (`viw`/`viW`/`vi(`/`vi[`/`vi{`/`vi"`/`vip`/`vit`/`vib`/`viB`
  fall through to `_ => Consumed`, the `i`/`a` becomes no-op and the
  next key runs as a raw motion — massive scope); V-BLOCK `r<c>`
  round-7 fix is DOA (prefix set in V-BLOCK, follow-up char still
  routes through `handle_visual_block` which doesn't check the
  prefix — no replacement ever happens); vim regex flavor still
  broken in `/search` prompt (`\<`/`\>`/`\|`/`\(…\)` — round-7 fixed
  `:s` but never wired `buffer::find_all_regex_cased`); `:g`/`:v`
  match by *literal substring* (`line.contains(pattern)`) — vim
  users type `:g/^foo/d` / `:g/\d\+/norm ...` and get "no lines
  match"; `[[`/`]]` / `[]`/`][` section navigation completely
  unbound; `!<motion>` filter operator not implemented (workaround
  `:%!cmd` works); `zf<motion>` and visual `zf` fold-create
  silently no-op.
- **SEV-3**: **5** — `zj` / `zk` inter-fold nav uncommitted (works
  in source, missing from current release binary); `:g/pat/p`
  (print) is a silent nothing — vim shows the matching lines in the
  message area, mnml just toasts "ran on N lines"; insert-mode
  `Ctrl-R #` (alternate file), `Ctrl-R :` (last cmdline), `Ctrl-R .`
  (last inserted) still unwired (round-7 explicitly deferred but
  still hurts every day); `zj`/`zk` toast fires but cursor snaps
  back to origin after ~300ms (only reproduced when the initial
  jump is to a folded row — needs harness re-run to isolate); `viw`
  incidentally over-includes the trailing space (would be fine as
  `vaw` behavior but not `viw`) — this is a downstream symptom of
  the visual-text-object no-op — v enters visual, i is dropped,
  and `w` runs as word-forward motion which stops one char past the
  end of the word.

**How vim-compatible does mnml feel after 45 minutes of round-8
hunting:** the round-7 haul mostly held. `y{N}j` linewise-yank,
`:{range}s`, `:set noic`, `:args`/`:next`/`:prev`, Visual `:` prefill,
`diW`/`ciW`/`daW` big-word text object (operator form), `@@` last-macro,
`:w !cmd` shell pipe, `\1`/`\2`/`&` substitute replacement, `\(…\)`
capture group in `:s`, `:delmarks`, V-BLOCK `I` collapsed undo (2
steps instead of 4 — still not perfect but usable) — all verified
working. But there's a class of bugs that leaks broadly and hurts
core vim ergonomics:

1. **Visual + text object is stone dead.** Every vim user reflexively
   types `vi(` / `vip` / `vit` / `vaW` / `vi"` / `vi{` — mnml turns
   those into `v` + no-op + raw motion. The selection lands on
   whatever the trailing character was meant as (motion, char-find,
   nothing), never the intended text object. Result: user thinks
   they highlighted `foo-bar-baz`, they highlighted `foo `. They hit
   `d`, half a paragraph disappears. Or `y`, the wrong 4 chars go to
   the clipboard. This is the biggest cliff since round-7 landed.
2. **V-BLOCK `r<c>` looks fixed in source but does nothing.** The
   round-7 patch added `Prefix::BlockReplaceChar` in `handle_normal`
   but pressing `r` in V-BLOCK sets that prefix while STAYING in
   V-BLOCK mode — the follow-up char routes back through
   `handle_visual_block` which has no arm for the prefix. Whole
   commit is wasted; user still can't fill a rectangle with `r Z`.
3. **`:g` / `:v` use literal substring, not regex.** `:g/^foo/d`,
   `:g/\d\+/d`, `:g/  \+/d` (trim trailing spaces) — every regex
   idiom silently reports "no lines match". Vim users type these
   dozens of times a session (whitespace cleanup, doc reformat, `%s`
   preview via `:g/pat/p`).
4. **Live `/search` still flunks vim regex flavor.** Round-7 landed
   `vim_pattern_to_regex` and wired it in `:s` — great — but nobody
   wired it to `buffer::find_all_regex_cased`. So `/\<on\>` and
   `/\(one\|two\)` are both "no regex matches". Same fix, called
   in a second place.

---

## [SEV-2] Visual-mode text objects — `viw`/`viW`/`vi(`/`va[`/`vi"`/`vip`/`vit`/`viB` all silently break

### Reproduction — `vi(`

```jsonl
{"cmd":"open","path":"mixed.txt"}
{"cmd":"wait_ms","ms":150}
{"cmd":"type","text":":4"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"l"}
{"cmd":"type","text":"vi("}
{"cmd":"snapshot"}
```

Line 4 = `(inside parens) done`. Cursor at col 3 (on `n` of "inside").
Expected: 12-char selection of `inside parens` (13 chars if inclusive).
Actual: mnml enters VISUAL, silently consumes `i`, and interprets `(`
as "jump to previous unmatched `(`" — cursor teleports to Ln 1 Col 1
and reports `Sel 47` (from cursor start to newly-landed position).

### Reproduction — `viw`

```jsonl
{"cmd":"open","path":"mixed.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"type","text":"viwd"}
{"cmd":"snapshot"}
```

Line 1 = `foo bar baz`. Expected: delete `foo` → ` bar baz`. Actual:
deletes `foo ` (with trailing space) → `bar baz`. Because `v` enters
visual, `i` is a no-op, `w` runs word-forward motion (which lands on
the START of the next word, one char past the word end). The `d`
then deletes that char-inclusive range.

For contrast, the *operator* form `diw` (no `v` prefix) correctly
deletes just `foo` — the operator-pending path DOES wire text
objects. Only the visual entry path is broken.

### Reproduction — `vi"`

```jsonl
{"cmd":"type","text":":3"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"l"}
{"cmd":"type","text":"vi\""}
{"cmd":"snapshot"}
```

Line 3 = `"hello" "world"`. Cursor inside first quote. Expected:
select `hello`. Actual: VISUAL mode entered, no selection (Sel field
absent from status). The `"` after `i` is silently consumed (not
even a fallback motion). `di"` (operator form) works correctly on
the same setup — deletes `hello`.

Same class covers: `viW`, `vaW`, `vaw`, `vip`, `vap`, `vit`, `vat`,
`vi(`, `va(`, `vib`, `vaB`, `vi[`, `va[`, `vi{`, `va{`, `vi<`, `va<`,
`vi'`, `va'`, `vi\``, `va\``.

### Expected

Vim canonical: after `v` (or `V` / Ctrl-V) enters visual, `i` / `a`
open the text-object prefix identically to operator-pending mode.
`v` + `i` + `(` selects the content INSIDE the enclosing parens
(exclusive of the brackets themselves).

### Source pointer

`src/input/vim.rs:2900-3020` — `handle_visual`. It has arms for `v`,
`V`, `d`, `x`, `c`, `s`, `y`, `o`, `>`, `<`, `g`, `u`, `U`, `~`, `*`,
`#`, `:`, `S`, but nothing for `i` or `a`. The fallthrough
`_ => InputResult::Consumed` at line 3020 eats them. Compare
`handle_normal` at line 2107-2116 where operator-pending `d`/`y`/`c` +
`i`/`a` DO set `Prefix::TextObjectInner` / `TextObjectAround`.

### Fix shape

Add arms in `handle_visual`:

```rust
KeyCode::Char('i') => {
    self.prefix = Prefix::TextObjectInner;
    // No pending op — the visible selection replaces one.
    InputResult::Consumed
}
KeyCode::Char('a') => {
    self.prefix = Prefix::TextObjectAround;
    InputResult::Consumed
}
```

Then `Prefix::TextObjectInner|Around` at line 1520 needs a
"visual mode" branch that EXTENDS the current visual selection to
the text-object bounds instead of emitting `SelectInnerX` fresh.
Vim uses the same underlying select ops but re-anchors to the object
edges. Simplest first-pass: dispatch the same `SelectInnerX` ops —
they overwrite the anchor/cursor pair, which matches vim's "collapse
current selection into the object, then extend" behavior for the
first press.

### Notes

The scope here is broad — every vim tutorial's first substantive
lesson is `ciw`, `di"`, `vi(`, `da{`. Round-7 fixed the operator
form but the visual form was overlooked. High leverage: one arm-pair
addition plus a visual-aware dispatch in the existing
`Prefix::TextObjectInner|Around` handler.

---

## [SEV-2] V-BLOCK `r<c>` — round-7 fix is DOA, next char routes through wrong handler

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
{"cmd":"type","text":"rZ"}
{"cmd":"snapshot"}
```

`block.txt` = 5 lines of `aaaXbbbXccc`. Sequence enters V-BLOCK,
extends to 3×3 rect, then `r` + `Z`.

### Expected

Top three lines become `ZZZXbbbXccc` (vim canonical).

### Actual

Buffer unchanged. Status still shows `V-BLOCK r` (the pending
prefix). The `Z` is consumed and dropped. Nothing writes.

### Source pointer

`src/input/vim.rs:3112-3115` — `handle_visual_block` sets
`self.prefix = Prefix::BlockReplaceChar` on `r`. That's correct.
But the follow-up keystroke still dispatches to `handle_visual_block`
(because `self.mode` is unchanged), and `handle_visual_block` has NO
prefix check — it goes straight into count-parse → motion-match →
default `_ => Consumed`. The `Prefix::BlockReplaceChar` handler at
line 1015-1023 lives inside `handle_normal`, which is never called
while the mode remains `VimMode::VisualBlock`.

### Fix shape

Two options:

1. Add the same `Prefix::BlockReplaceChar` arm at the top of
   `handle_visual_block` (mirror line 1015-1023):
   ```rust
   if matches!(self.prefix, Prefix::BlockReplaceChar) {
       self.reset_pending();
       return match key.code {
           KeyCode::Char(c) => {
               self.enter_normal();
               InputResult::App(AppCommand::BlockReplaceWith { ch: c })
           }
           _ => InputResult::Consumed,
       };
   }
   ```
2. Or, on the `r` arm at line 3112, `self.enter_normal()` first so
   the next char lands in `handle_normal` where the existing prefix
   check picks it up. Downside: dropping the visual block selection
   before the follow-up char confuses `block_replace_with` which
   reads `b.editor.block_selection()`.

Option 1 is safer.

### Notes

Same trap could exist for any prefix set in visual/visual-block that
doesn't call `enter_normal()`. Worth an audit.

---

## [SEV-2] `/pattern` (live search) still doesn't accept vim regex flavor — `\<`/`\>`/`\|`/`\(…\)` fail

### Reproduction

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"/\\<on\\>"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Line 1 = `line one alpha`. `\<on\>` should NOT match "one" (whole-
word "on" only). Vim canonical.

Actual toast: `no regex matches for "\<on\>"`. The pattern is passed
straight to Rust `regex`, where `\<` isn't recognized.

Same failure for:
- `/\(one\|six\)` — `\(…\)` groups + `\|` alternation
- `/\vfoo|bar` — `\v` very-magic mode
- `/\d\+` — `\+` one-or-more
- `/\<word\>` — word boundaries

### Expected

Round-7 shipped `vim_pattern_to_regex` in `src/app/ex_commands.rs:114`
and wired it at line 614 for `:%s/...`. Same translation belongs on
the `/pattern` (find) path so vim users' muscle memory works there
too.

### Actual

`src/buffer.rs:102 find_all_regex_cased` receives `self.query`
verbatim and calls `regex::Regex::new(&prefixed)`. No vim
translation.

Rust-native regex (`/(one|six)`, `/\bon\b`) DOES work — verified.

### Source pointer

`src/buffer.rs:56` — `find_all_regex_cased(scope, &self.query, ...)`.
The `self.query` field on `FindState` is what the vim `/pattern`
handler stores raw. Same one-line fix: translate via
`vim_pattern_to_regex` before the call. Optionally pull the fn out
of `ex_commands.rs` into a `src/vim_regex.rs` sibling so `buffer.rs`
can `use` it without a circular dep.

### Notes

Round-7 called this fixed in the log summary ("`\(…\)` `\|` `\<`/`\>`
find grammar"). Reads like the `:s` fix was miscategorized as "find"
because vim's substitute is regex-based. The live search prompt is a
separate code path.

---

## [SEV-2] `:g` / `:v` use literal-substring match, not regex — `:g/^foo/d` silently no-ops

### Reproduction

```jsonl
{"cmd":"open","path":"mixed.txt"}
{"cmd":"type","text":":g/^foo/d"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Two lines start with `foo` (`foo bar baz` and `foo-bar-baz next`).
Expected: both deleted. Actual toast: `:g — no lines match "^foo"`.

Same failure for `:g/[a-z]/d`, `:g/\d\+/norm ...`, `:v/^\s*$/d`
(delete blank lines), `:g/  \+/s/  \+/ /g` (fold whitespace).

Plain-substring patterns still work: `:g/foo/d`, `:v/six/d` — but
that's the case that reads as broken to a vim user, since `:g` is
DEFINED by its regex support.

### Expected

Vim canonical: `:g/pattern/cmd` runs `cmd` on every line whose regex
match. `:g/^foo/d` should delete every line starting with `foo`.

### Actual

`src/app/mod.rs:9825` — `run_global_cmd` iterates lines and calls
`line.contains(pattern)` (Rust `str::contains` = literal substring).
Regex metacharacters are treated as literal characters.

### Fix shape

```rust
let re = match regex::Regex::new(&crate::app::ex_commands::vim_pattern_to_regex(pattern)) {
    Ok(r) => r,
    Err(e) => { self.toast(format!(":g — bad regex: {e}")); return; }
};
for (i, line) in b.editor.text().split('\n').enumerate() {
    let matched = re.is_match(line);
    if matched != invert { rows.push(i); }
}
```

Same treatment for `:v` (same fn — `invert` already handles it).

### Notes

Because `:g` is one of the top-5 ex commands a vim user reaches for
(alongside `:s`, `:e`, `:w`, `:sort`), the "silently no matches"
result is high-friction: user re-types the pattern three times
convinced they've fat-fingered before checking source and finding
this.

---

## [SEV-2] `[[` / `]]` / `[]` / `][` — vim section navigation completely unbound

### Reproduction

```jsonl
{"cmd":"open","path":"sections.c"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"]]"}
{"cmd":"snapshot"}
```

`sections.c` has `int main` at line 3 and `void helper` at line 8 —
both with `{` at column 0. Cursor at line 1.

Expected: cursor jumps to line 3 (or 8 if line 3 already visited).
Actual: cursor stays at line 1.

### Expected

Vim's `]]` = jump to next `{` at column 0 (default section-start
convention in C/Rust/etc.). `[[` = previous. `][` = next `}` at col 0.
`[]` = previous `}` at col 0. Together they're the fastest way to
skim function boundaries in a source file.

### Actual

`src/input/vim.rs:1720-1738` — `Prefix::BracketOpen` and
`Prefix::BracketClose` accept `c` (git changes), `d` (LSP diag),
`q` (quickfix), `t` (TODO). No `[`/`]`/`{`/`}` arms for section
motions. Fallthrough is `_ => Consumed`.

### Fix shape

Add:
```rust
KeyCode::Char('[') => // BracketOpen + '[' = `[[` — jump to prev `{` at col 0
    InputResult::App(AppCommand::RunCommand("editor.prev_section_open".into())),
KeyCode::Char(']') => // BracketOpen + ']' = `[]` — jump to prev `}` at col 0
    ...
```

...and the mirrored pair on `BracketClose`. New commands
`editor.prev_section_open`, `editor.next_section_open`, ... scan the
buffer text for the target char at column 0 relative to cursor row.

### Notes

Vim has this for C-family and Lisp — the exact character it looks
for is `foldmarker`-derived and configurable via `sections=`. For
mnml v1, hardcoding `{`/`}` at col 0 covers 95% of the value.

---

## [SEV-2] `!<motion>` filter operator not implemented — no keyboard route to filter a text object through a shell

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

Expected: `!G sort<Enter>` pipes lines 1..end through `sort`, replaces
in-buffer. Same as `:%!sort`. Also `!ip fmt` (filter paragraph),
`!ap prettier` (filter around-paragraph), `!}sort` (filter to end
of paragraph), etc.

### Actual

`!` in normal mode is a silent no-op — no operator-pending state
armed. The following `G` moves cursor to end, `sort` is typed as
literal chars in normal mode (no-op for each), `Enter` no-op.
Buffer unchanged.

`:%!sort` (ex-command form) DOES work — verified.

### Source pointer

`src/input/vim.rs handle_normal` — no `KeyCode::Char('!')` arm that
sets a `PendingOp::Filter` and enters operator-pending state.

### Fix shape

Same shape as `d`/`y`/`c` operator dispatch. `!` sets an operator,
then a motion runs to determine range, then the range is sent
through the shell pipe (already implemented via
`run_filter_through_shell` in `ex_commands.rs:964`).

### Notes

`:%!sort` is a workable escape hatch that mnml supports today. But
`!ip prettier` is deep muscle memory for anyone who edits JSON /
Markdown paragraphs — the operator form matters.

---

## [SEV-2] `zf<motion>` and visual `zf` (create fold from range) — silently no-op

### Reproduction — motion form

```jsonl
{"cmd":"open","path":"sections.c"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"zfG"}
{"cmd":"snapshot"}
```

Expected: fold from line 1 to end. Actual: cursor moves to line 10
(end of file). No fold created. `zf` was consumed as `z` prefix +
`f` (unknown), then `G` ran as raw motion.

### Reproduction — visual form

```jsonl
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"type","text":"zf"}
{"cmd":"snapshot"}
```

Expected: fold lines 1-3. Actual: still V-LINE mode, no fold, `zf`
silently consumed.

### Expected

Vim: `zf<motion>` creates a manual fold spanning cursor to
motion-target. Visual + `zf` folds the visual selection. Users
create ad-hoc "hide this boilerplate" folds constantly.

### Source pointer

`src/input/vim.rs:1025-1088` — `Prefix::ZFold` accepts a, A, c, C,
o, O, R, E, M, z, t, b, h, l, H, L. No `f` arm. Visual mode's `z`
handler doesn't even set the ZFold prefix (looking at
`handle_visual` for a `KeyCode::Char('z')` arm — line 2962 sets
`self.prefix = Prefix::G` which would be wrong for `z`; actually
`handle_visual` has no `z` arm at all, so `z` falls to
`_ => Consumed`).

### Notes

Related fold gaps (SEV-3 elsewhere): `zj`/`zk` (inter-fold nav) —
coded in source but the binary doesn't have the `editor.fold_next`
/ `editor.fold_prev` command registrations (see uncommitted diff
`git diff HEAD -- src/command.rs`). Rebuild + re-test in round 9.

---

## [SEV-3] `zj` / `zk` (inter-fold navigation) — source-tree fix present but not in the release binary

### Reproduction

```jsonl
{"cmd":"open","path":"foldable.rs"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"zc"}
{"cmd":"type","text":":6"}
{"cmd":"key","key":"enter"}
{"cmd":"type","text":"zc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"zj"}
{"cmd":"snapshot"}
```

Two manual folds created (line 1, line 6). Cursor back at line 1.
Expected: `zj` jumps to line 6. Actual: cursor stays at line 1.

Direct route via IPC: `{"cmd":"run-command","id":"editor.fold_next"}`
toasts `no such command: editor.fold_next`.

### Source pointer

`git diff HEAD -- src/command.rs` shows uncommitted additions of
`editor.fold_all_brackets`, `editor.fold_next`, `editor.fold_prev`.
And `src/app/mod.rs` uncommitted `fold_all_brackets_in_active`,
`fold_next_in_active`, `fold_prev_in_active`. And `src/input/vim.rs`
uncommitted `Prefix::ZFold` `KeyCode::Char('j'|'k')` arms.

So the code IS written, just uncommitted. But `target/release/mnml`
was rebuilt at 18:36:44 (after the source edits at 18:34:30 —
timestamps line up), so this SHOULD be in the binary. Something
about the strings check confirmed the names are baked in yet
`run-command` still reports "no such command". Suggests a stale
registry or a shadowed `commands()` accessor — worth a targeted
look in `src/command.rs` for how the registry is initialized (see
line 70 `let commands = builtin_commands()`).

### Actual

`zj` / `zk` / `zM` (bracket fallback) all silently no-op in the
current binary. The source repo says otherwise.

### Notes

Not a code bug per se — a delivery gap. Flag as SEV-3 because the
user's next `./run.sh restart` or `cargo build --release` should
resolve it. But it means round-8's regression checks against the
uncommitted round-7 additions can't happen — flag for round-9
after commit + rebuild.

---

## [SEV-3] `:g/pat/p` (print matching lines) — silent success with no output

### Reproduction

```jsonl
{"cmd":"open","path":"mixed.txt"}
{"cmd":"type","text":":g/foo/p"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Expected: message area shows the two lines starting with `foo`
(vim canonical `:g/pat/p` prints matched lines). Actual toast:
`:g · ran on 2 line(s)` — no lines printed anywhere.

### Source pointer

`src/app/mod.rs:9846` — `run_global_cmd` loops
`self.run_ex_command(&cmd)`. Passing `"p"` as an ex-command isn't
handled — `p` (print) as an ex-command isn't in the vocabulary. So
the sub-command silently no-ops per line.

### Fix shape

Wire an ex `p` / `print` handler that appends the current line to
a message buffer, then dumps it when `:g`'s outer loop completes.
Or extend the global loop's inner call to detect `p`/`P` and route
to a `.messages` echo directly.

### Notes

Related: `:g/foo/#` (print with line numbers), `:g/foo/=` (print
line numbers only). Same class.

---

## [SEV-3] Insert-mode `Ctrl-R #` / `Ctrl-R :` / `Ctrl-R .` still unwired

### Reproduction — Ctrl-R #

```jsonl
{"cmd":"open","path":"sample.txt"}
{"cmd":"wait_ms","ms":150}
{"cmd":"open","path":"foldable.rs"}
{"cmd":"wait_ms","ms":150}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"alt: "}
{"cmd":"key","key":"ctrl+r"}
{"cmd":"key","key":"#"}
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
```

Expected: `alt: sample.txt` (previous buffer's rel-path). Actual:
`alt:` — the `#` is consumed but nothing inserts.

Same for `Ctrl-R :` (last cmdline — after running `:set hh` it
should insert `set hh`), and `Ctrl-R .` (last inserted text).

### Source pointer

`src/input/vim.rs:882` — the `valid` register whitelist is
`is_ascii_lowercase() || c == '0' || c == '+' || c == '_' || c == '"'`.
Round-7 landed `%` and `/` at lines 868-877 above, but `#`, `:`, `.`
aren't wired. The round-7 commit note explicitly deferred them
("`#`, `:`, `.`, `=` still fall through to the register-paste arm
and toast 'empty' — their state (alt buffer, cmdline history,
dot-replay text, expression evaluator) isn't threaded yet").

### Notes

Deferred by design. Filing for tracking because vim users type
`Ctrl-R :` every time they draft an inline shell one-liner
(`echo Ctrl-R : | pbcopy` idiom). `Ctrl-R .` unblocks in-line
"repeat what I just typed" without dropping to Normal.

---

## [SEV-3] `viw` incidentally over-includes trailing whitespace — symptom of the visual text-object no-op

### Reproduction

```jsonl
{"cmd":"open","path":"mixed.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"type","text":"viwd"}
{"cmd":"snapshot"}
```

Line 1 = `foo bar baz`. Expected `viw` deletes `foo` → ` bar baz`.
Actual: deletes `foo ` (with trailing space) → `bar baz`.

### Why

Downstream of the visual-text-object break. In visual mode `v` +
`i` (no-op) + `w` (motion) — the `w` motion advances to the start
of the next word, one char past the current word's end. The
selection thus includes the intervening whitespace.

### Notes

Fixed automatically when the parent SEV-2 (visual text objects) is
fixed. Filed separately so the pattern shows up in the top-level
summary — round-8 tester would notice this before understanding
the deeper cause.

---

## Not-a-bug / verified-working (round-8 verify pass)

Round-7 fixes verified in the current release binary:

- **`y{N}j`** — `y2j` + `Gp` correctly pastes 3 linewise lines.
  Verified.
- **`:{range}s/…/…/`** — `:2,4s/line/LINE/` correctly transforms
  the 3-row range. Verified.
- **`:set noic`** — `/LINE` after `:set noic` correctly returns no
  match (cursor stays at Ln 1 Col 1); `/line` matches, `n`
  advances line-by-line. Verified.
- **`:args` + `:next`** — `:args *.txt` sets 3-file arglist,
  `:next` steps to next. Verified. (Multi-arg space-separated
  form `:args a b c` is NOT supported — `arglist_expand` treats
  the whole rest as a single pattern; workaround via glob. Not
  filing as a bug — the glob form works.)
- **`:` from Visual auto-prefills `'<,'>`** — pressing `:` in
  V-LINE opens the cmdline pre-populated with `'<,'>`. Verified.
- **`diW` / `ciW` / `daW` / `yiW` big-WORD** — operator form
  works. On `foo-bar-baz next` cursor col 0, `diW` deletes
  `foo-bar-baz` leaving ` next`. Verified. (Visual form `viW`
  broken — see SEV-2 above.)
- **`@@` last-macro repeat** — `qaI# <Esc>j q @a @@` correctly
  prefixes lines 1, 2, and 3. Verified.
- **`:w !cmd`** — `:w !wc -l` toasts `10` (line count), no `!wc -l`
  file created. Verified.
- **`:s/\1/\2/&/`** — `%s/line (\w+) (\w+)/\2 -- \1/g` correctly
  swaps captures. Verified.
- **Classic vim `\(...\)`** — `%s/line \(\w\+\) \(\w\+\)/\2 -- \1/g`
  works in `:s`. Verified. (But not in `/search` — SEV-2 above.)
- **V-BLOCK `I` — collapsed undo** — replay collapsed to single
  step (2 undos to fully unwind: 1 for the replayed non-anchor
  rows, 1 for the anchor row's live-typed insert). Matches
  round-7 commit's explicit design.
- **`:delmarks a`** — clears the mark. `:marks` then reports
  `:marks — none set`. Verified.
- **Insert-mode `Ctrl-R %`** — inserts `foldable.rs`. Verified.
- **Insert-mode `Ctrl-R /`** — inserts last search query
  (`println`). Verified.
- **Insert-mode `Ctrl-R 0`** — inserts last yank. Verified.
- **Insert-mode `Ctrl-R "`** — inserts unnamed register. Verified.
- **`gv`** — after `V j j y Esc G gv`, visual selection restored
  (V-LINE mode, sel 29). Verified.
- **`` ` `` (backtick) exact mark jump** — `ma`, move, `` `a ``
  jumps to exact row/col. Verified.
- **``` `` ``` back-jump to prev cursor** — after `` `a ``, `` `` ``
  returns to previous position. Verified.
- **`:g/pat/d`** — deletes matching lines. Verified (with literal
  substring only — see SEV-2 above for regex gap).
- **`:v/pat/d`** — inverse-global. `:v/six/d` on 10-line sample
  keeps only "line six zeta". Verified.
- **`:g/pat/s/…/…/`** — nested substitute via global. Verified.
- **`:g/pat/y`** — yank matched lines. Verified via `Gp` paste.
- **`:g/pat/norm ...`** — normal-mode replay on matched lines.
  Verified.
- **`:%!sort`** — pipe whole buffer through shell command.
  Verified.
- **`}` paragraph forward** — jumps past blank lines. Verified.
- **`3n`** — count-prefixed n advances 3 hops (though wraps around
  which is arguably not exactly vim's default behavior).

