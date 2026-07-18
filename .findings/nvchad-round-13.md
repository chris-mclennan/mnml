# nvchad-round-13 — vim-mode hunt, 2026-07-14

## Executive summary

Ran a ~90-minute headless vim-mode session against a freshly-rebuilt
`~/Projects/mnml/target/release/mnml --input vim` (rebuild forced because a
stale binary initially masked the first several tests — mtime showed source
newer than binary despite cargo saying "Finished"). All six priority
verifications from `polish(vim): 4× nvchad-round-12 SEV-2` (commit fcb88751)
hold after the rebuild:

- `:w!` / `:write!` / `:wa!` / `:wqa!` / `:wall!` / `:xa!` / `:xall!` / `:xa!`
  all save the buffer (previously silent no-op, data-loss vector). Confirmed
  on-disk file content changes + `dirty:false` after each.
- `:map` toasts `unknown command` and leaves `mode:NORMAL` (does not silently
  switch keymap → standard mode).
- `:changes`, `:jumps`, `:marks`, `:reg`, `:registers`, `:cd`, `:chdir`,
  `:signs`, `:colorscheme`, `:hist`, `:history`, `:nmap`, `:imap`, `:iunmap`,
  `:nnoremap`, `:inoremap`, `:sign` — every reserved name I tested either
  hits an explicit arm (`:marks`, `:jumps`, `:reg`, `:let @a='...'` all
  implemented) or toasts `unknown command`. None hijack a sibling palette
  command.
- `dib` / `dab` / `diB` / `daB` all delete inside brackets like the `di(` /
  `di{` variants. `cib`, `yib`, `yaB` etc. work. Visual `vib` / `viB` /
  `vab` / `vaB` select correctly.
- `:s/pat/rep/` (no `/g`) replaces FIRST match per line. `:s/…/…/g` replaces
  all. `:%s/foo/BAR/` on the 4-line `foo bar foo / foo bar foo / …` corpus
  hits first per line. `:%s/foo/BAR/g` hits all. Regex path `:%s/\(foo\)/BAR/`
  honors first-per-line too.
- Also verified: **round-12 SEV-2 range-delete family shipped.** `:%d`,
  `:1,$d`, `:2,4d`, `:.d`, `:3delete`, `:1y` — all work now. Round-12's
  finding is fully resolved.

**Verdict** — priority verifications held cleanly. Round 13 hunt turned up a
mixed bag: three fresh SEV-2 vim-parity gaps (`S`, `<count>yy`/`<count>Y`,
`dG`/`d<num>G` linewise), several SEV-3s that read as "half-implemented", and
seven round-12 findings that are still live. The single-most-annoying-for-a-
vim-user among the new ones is probably `<count>yy` yielding a 1-line paste
instead of `<count>` lines — muscle memory `2yy p` gives half of what you
asked for, silently.

**Count by severity**: **SEV-1: 0 · SEV-2: 3 fresh + 7 carried · SEV-3: 6
fresh** = 16 findings.

**Verified fixed since round-12** (all shipped by fcb88751):
- `:w!` / `:write!` / `:wa!` / `:wall!` / `:wqa!` / `:wqall!` / `:xa!` /
  `:xall!` save (round-12 SEV-2, data-loss vector).
- `:map` toasts unknown (round-12 SEV-2 — was silent keymap switch).
- `dib` / `diB` / `dab` / `daB` (round-12 SEV-2 — was no-op).
- `:s/pat/rep/` first-match-per-line default (round-12 SEV-2 — was global by
  default).
- Range-delete family: `:%d`, `:2,4d`, `:.d`, `:3delete`, `:1y` (round-12
  SEV-2 — all were no-ops).

**Still broken since round-12** (re-verified this round):
- SEV-2: `dd` / `yy` on a closed fold only operates on the header line (18
  hidden lines survive). Extended round-12 finding: `cc` and `>>` / `<<` on
  a closed fold have the **same** class defect — the fold body is untouched.
  See **[SEV-2] fold operator scope** below.
- SEV-2: `:sp <file>` / `:vsp <file>` / `:new` / `:vnew` create 3 panes
  (source leaf duplicates a background copy of its file). Not re-tested this
  round.
- SEV-2: Visual-line (`V`) case-change (`~` / `U` / `u` / `gU` / `gu` / `g~`)
  no-op.
- SEV-2: Visual-block edit + `u` requires two undos to revert row 1.
- SEV-3: `Ctrl+[` doesn't fire Escape from Insert (`Ctrl+c` still works).
- SEV-3: `guu` (lowercase current line, double-op) no-op while `gUU` / `g~~`
  work — asymmetric.
- SEV-3: `:ab` abbreviation eats the trigger whitespace.

---

## [SEV-2] `S` (change entire line) doesn't clear the line — only clears from line-start to cursor

**Reproduction** (workspace `/tmp/mnml-nvchad-r13` with `a.txt` = `alpha beta gamma\none two three\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"S"}
{"cmd":"type","text":"NEW"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```

**Expected**: vim `S` = `cc` — clear the entire current line, drop into
Insert mode. Line 1 should be `NEW`.

**Actual**: line 1 becomes `NEWalpha beta gamma`. `S` enters Insert but does
NOT clear the line. Cursor was at col 0 so `NEW` prepends. If cursor was at
`b` in `beta` (col 6), `S` clears `alpha ` (chars 0..5) and `NEW` inserts —
result `NEWbeta gamma`. So `S` behaves like `d0i` (delete to line-start,
insert) instead of vim's `cc`.

**Source pointer**: `src/input/vim.rs:2615-2618`.

```rust
KeyCode::Char('S') => {
    self.enter_insert();
    InputResult::Ops(vec![SelectLine, ReplaceSelection(String::new())])
}
```

`SelectLine` (per `src/editor/mod.rs:2308-2324`) sets `anchor = line_start`
but leaves `cursor` where it was — so if cursor was mid-line, selection is
(line_start, cursor). Missing a `MoveLineEnd` between `SelectLine` and
`ReplaceSelection` to extend the selection through the entire line, just
like the `cc` (doubled operator) branch at vim.rs:2110-2121 does:

```rust
PendingOp::Change => {
    self.mode = VimMode::Insert;
    InputResult::Ops(vec![
        SelectLine,
        MoveLineEnd,   // ← S is missing this line
        ReplaceSelection(String::new()),
    ])
}
```

**Notes**: `S` (a.k.a. `cc` shorthand) is one of vim's more common single-key
edits — every "start rewriting this line from scratch" moment uses it.
Verified via a fresh session with the rebuilt binary. Reflex hit rate is
higher than `cc` for many users because it's one keystroke.

---

## [SEV-2] `<count>yy` / `<count>Y` yanks 1 line, not `<count>` lines (`<count>dd` and `<count>cc` work correctly)

**Reproduction** (workspace with `line1\nline2\nline3\nline4\nline5\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"2"}
{"cmd":"key","key":"y"}
{"cmd":"key","key":"y"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"p"}
{"cmd":"snapshot"}
```

Buffer after paste: `line1 / line2 / line3 / line4 / line5 / line1` — the
paste ONLY added `line1`, not `line1 + line2`. Same result with `2Y`.

Verify counterpart `2dd` DOES work: on the same fresh buffer, `2dd` deletes
lines 1 and 2, leaving `line3 / line4 / line5`. `2cc` also correctly changes
BOTH lines. Only the `Yank` linewise op silently drops the count.

**Expected**: vim `2yy` yanks 2 lines (line1 + line2). Subsequent `p` pastes
both.

**Actual**: only 1 line is captured. `p` inserts one line.

**Source pointer**: `src/input/vim.rs:2107-2109`.

```rust
PendingOp::Delete => InputResult::Ops(Self::repeated(DeleteLine, n)),
PendingOp::Yank   => InputResult::Ops(Self::repeated(YankLine, n)),
```

`Self::repeated(YankLine, n)` fires `YankLine` `n` times, but `YankLine`
(per `src/editor/mod.rs:3808-3820`) **overwrites the clipboard on each
call**. The nvchad-round-6 SEV-2 fix at vim.rs:2288-2291 introduced a
dedicated `YankLinesCount(N)` op that captures a linewise multi-line span
in one shot — but that fix only lives on the operator+motion path (`2yj` /
`3yy... via vertical motion`), not on the doubled-operator path
(`2yy` / `2Y`).

**Fix hint**: replace `Self::repeated(YankLine, n)` with `vec![YankLinesCount(n as usize)]`
for the `PendingOp::Yank` doubled arm. Same as the fix already applied at
vim.rs:2289.

**Notes**: `Y` in Vim 8.0+/Neovim 0.6+ was aliased to `yy` (linewise-from-
cursor); mnml's `Y` fires the doubled-yank path too so it has the same
defect. Muscle memory `2yy p` is one of the most-common quick-copy gestures
in vim — silently yielding half the yank is a real footgun.

---

## [SEV-2] `dG` / `d<count>G` deletes charwise (should be linewise per vim convention)

**Reproduction** (workspace with `line1\nline2\nline3\nline4\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"G"}
{"cmd":"snapshot"}
```

Buffer after: `line1 / line4`. Only line 2 and line 3 were deleted — line 4
survived (should have been included).

Same defect for `d3G` from line 2 — deletes lines 2..2 (not 2..3).

**Expected**: vim `dG` from line 2 = "delete from line 2 through the end of
the buffer" (linewise, inclusive). Result: just `line1`.

**Actual**: mnml treats `G` as a charwise motion under an operator — cursor
moves to line 4 col 0, delete range is (line 2 col 0, line 4 col 0)
excluding the char at the end. So the last line is preserved.

**Source pointer**: `src/input/vim.rs:2266-2272` — vertical-direction
detection only covers `j` / `k` / `+` / `-` / `Enter` / `Down` / `Up`; `G`
(and `gg`) are missing. The linewise-op branch at 2273-2323 also handles
`gg` / `G` in vim (either as bounded or unbounded targets), but mnml's
motion catalog fires `MoveBufferEnd` as a charwise motion, producing an
off-by-one selection.

**Notes**: `dG` and `dgg` (delete to top of buffer) are the two canonical
"nuke a chunk to a buffer edge" gestures. Same class of issue as the
round-11 `dj` linewise fix — that patch added `j`/`k`/`+`/`-` to the
vertical set but stopped short of `gg` / `G`. Also affects `yG`, `cG`, `>G`,
`<G`.

---

## [SEV-2] `dd` / `yy` / `cc` / `>>` / `<<` on a closed fold operate only on the header line, not the fold body (round-12 confirmed + extended)

**Reproduction** (workspace with a 19-line Rust file wrapped in `fn main() {…}`):

```jsonl
{"cmd":"open","path":"long.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"z c"}          // close the outer fold
{"cmd":"key","key":"d d"}          // delete the closed fold
{"cmd":"key","key":"G"}
{"cmd":"snapshot"}
```

Buffer post-`dd`: 18 lines remaining (only `fn main() {` header removed). The
18 hidden fold body lines survived.

Same class extends beyond round-12's scope. Verified this round:

- `yy` on a closed fold yanks only the header line → subsequent `p`
  inserts one line, not the whole fold body.
- `cc` on a closed fold clears + rewrites only the header → the hidden
  lines below the header stay untouched.
- `>>` on a closed fold indents only the header — visible after `zR`, the
  18 body lines have their original indentation.

**Expected**: vim's fold-aware line ops operate on the ENTIRE fold when the
cursor sits on a closed fold header. `dd` on `fn main() {  ⋯ 18 hidden`
deletes 19 lines. `yy` yanks 19. `cc` clears 19 lines and drops one blank
line for insert. `>>` indents all 19.

**Actual**: mnml treats a closed fold as one-cell-wide for navigation
(`j`/`k` skip over it) but as one-line-tall for line operators. The gap
between the two mental models is confusing — a user sees "1 visible line,
18 hidden" and expects `dd` to remove all 19.

**Source pointer**: `src/input/vim.rs` doubled-op linewise arm — the
`PendingOp::Delete` / `Yank` / `Change` / `Indent` / `Outdent` handlers
(vim.rs:2107-2124) don't consult the fold table. `src/editor/mod.rs` `DeleteLine`
etc. operate on the char-count level, not the fold-region level.

**Notes**: this is one of vim's most useful fold semantics — the ability to
fold a function, then `dd` the entire block, is what makes folds worth
using. **Extended round-12 finding** — `cc` / `>>` / `<<` are new this
round (round-12 only tested `dd` / `yy`).

---

## [SEV-3] `d/<pattern><Enter>` doesn't work as a vim operator+search motion — silently drops the op and lets follow-up chars execute as normal-mode chords (produces confusing buffer state)

**Reproduction** (workspace with `alpha\nbeta\ngamma\ndelta\nepsilon\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"d"}
{"cmd":"type","text":"/gamma"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Buffer after: `a\nlpha\nbeta\ngamma\ndelta\nepsilon\n` — line 1 became `a`,
line 2 became `lpha`. Very odd.

**Expected**: vim `d/gamma<CR>` from line 1 col 0 = "delete from cursor to
(exclusive of) the first search match of `gamma`". Should delete
`alpha\nbeta\n` and leave `gamma\ndelta\nepsilon\n`.

**Actual**: The `d` sets pending op, then `/` in `src/input/vim.rs:2415`
falls through to `Self::motion(KeyCode::Char('/'))` which returns None →
`return InputResult::Consumed` at 2415 — silently drops the operator
without opening the Find prompt. Now we're back in Normal with no pending
op. The subsequent `g`, `a`, `m`, `m`, `a` (typed by the IPC `type`
command as individual key events) each execute as normal-mode chords:
`g` starts Prefix::G, `a` in Prefix::G falls to `_ => Consumed` (no-op),
`m` starts Prefix::MarkSet, `m` sets mark `m`, `a` enters Insert mode
(append after cursor). We're now at col 2 in Insert. `Enter` inserts a
newline at col 2, splitting `alpha` into `a\nlpha`. Result matches
observed behavior.

**Source pointer**: `src/input/vim.rs:2966` — the bare `/` handler is only
reached OUTSIDE operator-pending. Under a pending op, `/` needs to open
the Find prompt as an operator-motion (like `df<char>` — vim.rs:2232
handles `f`/`F`/`t`/`T` with pending op; `/` needs the same treatment,
plus a `SearchThen(op)` intermediate state).

**Notes**: same class covers `d?pattern`, `c/pattern`, `y/pattern`. These
are less-used than `dw` / `de` but every experienced vim user knows them.
The silent-drop + weird buffer state is worse than an "unknown motion"
error would be — the user sees line 1 split without any error and has to
figure out why.

---

## [SEV-3] Visual `r<char>` doesn't replace selected chars (only block-visual `r<char>` works)

**Reproduction** (workspace with `alpha beta gamma\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"v"}
{"cmd":"key","key":"e"}
{"cmd":"key","key":"r"}
{"cmd":"key","key":"z"}
{"cmd":"snapshot"}
```

Buffer unchanged (`alpha beta gamma`). Mode is still VISUAL — the `r` was
consumed silently (falls to the `_ => InputResult::Consumed` arm in
handle_visual). Then `z` opens the ZFold prefix overlay.

Contrast with block-visual: `Ctrl+v` + motion + `r Q` correctly replaces
each cell of the block with `Q` — that path IS wired at
`src/input/vim.rs:3428-3431` (Prefix::BlockReplaceChar).

**Expected**: vim visual `r<char>` replaces every char in the selection
with `<char>`. `v e r z` on `alpha` → `zzzzz beta gamma`.

**Actual**: `r` is a no-op in charwise/linewise visual mode. Only
block-visual `r` works.

**Source pointer**: `src/input/vim.rs:3175-3319` (handle_visual) — missing
a `KeyCode::Char('r')` arm that sets a `VisualReplaceChar` prefix analogous
to `BlockReplaceChar`.

**Notes**: minor gap; users can `c<char><esc>` as a workaround for single-
char replaces, but wide visual `r` is a real vim gesture for "capitalize
this selection to `X`" etc.

---

## [SEV-3] `:sp <file>` / `:vsp <file>` / `:new` / `:vnew` and `Ctrl+w n` produce 3 panes (round-12 residual + extension)

**Reproduction** (workspace with `a.txt` and `b.txt`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":sp b.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Status.json panes:
```json
"panes":[{"title":"a.txt","dirty":false},{"title":"a.txt","dirty":false},{"title":"b.txt","dirty":false}]
```

Same for `:vsp b.txt`, `:new`, `:vnew`, and — new this round — **`Ctrl+w n`**
(vim's "new empty buffer in horizontal split" chord). All create three
panes: the original + a duplicated background tab + the requested/new
buffer.

**Expected**: 2 panes. Source leaf shows `a.txt`; destination leaf shows
`b.txt` (or a scratch buffer for `:new`/`Ctrl+w n`). No inherited-tab.

**Actual**: three panes. Extra `a.txt` sits as a background tab in the
destination leaf.

**Source pointer**: `src/app/ex_commands.rs` `sp` / `vsp` / `new` / `vnew`
arms + wherever `Ctrl+w n` splits — the split-then-open sequence carries
the source leaf's active file into the new leaf's tabs list before adding
the requested file on top.

**Notes**: identical class as round-12's SEV-2. Downgraded to SEV-3 since
the destination shows the correct active file — the extra tab just clutters
`:bn` / `:bp` cycles. New this round: **`Ctrl+w n` has the same defect**.

---

## [SEV-3] `:5,10 move 20` (range + move) silently no-ops

**Reproduction** (workspace with 40+ lines):

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":5,7 move 20"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Buffer unchanged. No toast.

**Expected**: vim `:5,7 move 20` moves lines 5-7 to appear after line 20.

**Actual**: silent no-op. Range prefix is parsed, then `move` isn't in the
range-arm dispatch (`d`/`y`/`j`/`>`/`<`/`s`/`sort`/`norm` are the only
supported range-verbs); falls through to a normal-cmd path that can't
parse the `5,7` prefix and eventually toasts unknown — but the toast
apparently gets clobbered by later renders in my test.

**Source pointer**: `src/app/ex_commands.rs:983-1063` (range-arm match) —
add `"m" | "move"` and `"co" | "copy" | "t"` arms that call
`run_move_or_copy_lines_range(start, end, target)` variants of the
existing bare-`:m N` handler at 1591.

**Notes**: `:m` for the cursor's line works. `:{range} m N` (range form) is
a common gesture for reordering code blocks and is unsupported.

---

## [SEV-3] `:g!/pat/d` (inverse-global bang form) toasts "unknown command" — only `:v/pat/d` works

**Reproduction**:

```jsonl
{"cmd":"type","text":":g!/line1/d"}
{"cmd":"key","key":"enter"}
```

Toasts `:g!/line1/d — unknown command`.

Same setup, `:v/line1/d` works correctly (keeps lines matching `line1`,
deletes others).

**Expected**: vim treats `:g!/pat/cmd` and `:v/pat/cmd` as synonyms —
"apply cmd to lines that do NOT match pat".

**Actual**: `:v/pat/…` is wired at `src/app/ex_commands.rs:1108`; `:g!/pat/…`
falls through to the unknown-command toast because the parser looks for
`g/` and `global/` prefixes only, not `g!/` or `global!/`.

**Source pointer**: `src/app/ex_commands.rs:1101-1114`. Add a `g!/` prefix
check that routes to `run_global_cmd(rest, true)` (same as `v/`).

---

## [SEV-3] `:norm` toast displays 0-indexed line range instead of 1-indexed (`:1,2norm` reports "0..1")

**Reproduction**:

```jsonl
{"cmd":"type","text":":1,2norm gUU"}
{"cmd":"key","key":"enter"}
```

Toast: `:0..1norm — 2 line(s)` (should be `:1..2 norm — 2 line(s)`).

**Expected**: vim ex-command line references are 1-based; every toast
should surface 1-based numbers to match `Ln N/M` in the statusline.

**Actual**: `:norm`'s toast is the only ex-command I saw this round
reporting 0-indexed rows. Behavior is correct (lines 1 and 2 uppercased);
only the toast is misleading.

**Source pointer**: `src/app/ex_commands.rs` — search for the format
string emitting the `:{start}..{end}norm` toast (likely near `run_norm_range`).

**Notes**: cosmetic but confusing — makes it look like the range was
off-by-one when it wasn't.

---

## [SEV-3] `:file <newname>` toasts "unknown command" (vim: sets the buffer's associated filename)

**Reproduction**:

```jsonl
{"cmd":"type","text":":file newname.txt"}
{"cmd":"key","key":"enter"}
```

Toast: `:file newname.txt — unknown command`. Bare `:file` (no args) is
also unknown.

**Expected**: vim `:file <name>` renames the current buffer's associated
filename (subsequent `:w` writes to `<name>`); bare `:file` prints the
current filename + line info (similar to `Ctrl+G`).

**Actual**: unknown command. `:file` is in the VIM_RESERVED list at
ex_commands.rs:3286 but there's no explicit arm above it.

**Source pointer**: `src/app/ex_commands.rs` — add an explicit `"file" | "f"`
arm. Argument form should call `save_active_as(name)` (or a dedicated
"just rename the buffer, don't save yet" variant); bare form should toast
the current filename + row.

---

## Priority-verification detail (all pass)

- **`:w!` / `:wa!` / `:xa!` / `:xall!` save**: verified on `a.txt` with
  `START ` prefix — file on disk updated, `dirty:false`.
- **`:map` toasts unknown, mode stays NORMAL**: fresh session, single
  `:map <enter>` — status.json reports `"mode":"NORMAL"` after, toast
  `:map — unknown command`.
- **`dib` / `diB` / `dab` / `daB` / variants**: cursor-inside-`(foo, bar,
  baz)` + `d i b` produces `()`. `d a b` produces empty. Same for `B`
  variants on `{}`. `yib` + `p` yanks + pastes the inner text.
- **Visual `vib` / `viB`**: `v i b` on the same lines enters VISUAL mode
  with the parenthesized content selected; `d` closes it.
- **`:s/pat/rep/` first-match, `:s/…/…/g` all**: `foo foo foo` on line 1
  becomes `bar foo foo` for `.s/foo/bar/`. `.s/foo/bar/g` gives
  `bar bar bar`. `:%s/foo/BAR/` on a multi-line corpus hits FIRST per
  line. Regex path `:%s/\(foo\)/BAR/` honors first-per-line.
- **Range-delete family works (round-12 SEV-2 fix)**: `:%d` empties buffer,
  `:2,4d` deletes lines 2-4, `:.d` deletes current line, `:3delete`
  deletes line 3, `:1y` + `p` at end pastes line 1.

---

## Round-12 still-broken (re-verified quickly)

- **Visual-line `V ~` / `V U` / `V u` / `V gU` / `V gu` / `V g~`**: mode
  returns to NORMAL but buffer unchanged. Verified this round.
- **Block-edit undo needs two undos**: `gg Ctrl+v 3j A " !!" Esc`, then
  `u` — restores lines 2-4 but leaves line 1 with the edit. Second `u`
  completes the revert. Verified this round.
- **`Ctrl+[` doesn't exit Insert mode**: from `o XX`, `Ctrl+[` leaves
  `mode:INSERT`. `Ctrl+c` and `Esc` both work. Verified this round.
- **`guu` no-op**: after `gUU` uppercases line 1 to `ALPHA`, `guu` leaves
  it as `ALPHA`. `gu$` on the same line lowercases correctly. Verified
  this round.
- **`:ab teh the` eats trigger whitespace**: typing `teh dog` produces
  `thedog`. Verified this round.
- **`:sp <file>` produces 3 panes**: see SEV-3 above.
- **`dd` on closed fold**: see SEV-2 above (extended).

---
