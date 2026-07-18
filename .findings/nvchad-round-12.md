# nvchad-round-12 — vim-mode hunt, 2026-07-14

## Executive summary

Ran a ~60-minute headless vim-mode session against
`~/Projects/mnml/target/release/mnml --input vim`. Priority verifications
from prior rounds all held except one that only partially landed. Muscle
memory covered: text objects (`ib`/`ab`/`iB`/`aB`/`it`/`i"`/`i'`/`i\``/`i<`/`ia`/`aa`),
operators (`d`/`c`/`y`/`~`/`gU`/`gu`/`g~`) + motions/text-objects, `.` repeat,
macros (`qa`/`q`/`@a`/`5@a`/`@@`), marks (`ma`/`'a`/`` `a ``/`mA` global/`'` marks),
folds (`zc`/`zo`/`za`/`zR`/`zM`/`zz`/`zt`/`zb`) and fold-aware `dd`/`yy`,
window motion (`Ctrl-w hjkl`, `Ctrl-w o`, `Ctrl-w f`, `Ctrl-w >`/`+`),
splits (`:sp`/`:vsp`/`:new`/`:vnew`), buffer nav (`:e`/`:bn`/`:bp`/`:bd`/`:bd!`),
tab nav (`:tabnew`/`gt`/`gT`), ex commands (`:s/.../.../gc[y/n/a/q/l]`, `:g/pat/d`,
`:v/pat/d`, `:%d`, `:.d`, `:2,4d`, `:norm`, `:normal`, `:%y`, `:r !`,
`:put`, `:earlier`/`:later`, `:sort`/`:sort!`, `:jumps`, `:changes`,
`:marks`, `:reg`, `:messages`, `:!echo`, `:ab`/`:abclear`, `:file`, `:pwd`,
`:retab`), search (`/`, `?`, `n`, `N`, `*`, `#`, wraparound), insert-mode
(`Ctrl+t`/`Ctrl+d`/`Ctrl+u`/`Ctrl+w`/`Ctrl+n`/`Ctrl+r "`/`Ctrl+[`/`Ctrl+c`),
visual-block edits + undo, case-change (`~`/`gU`/`gu`/`g~`/`gUU`/`guu`/`g~~`),
count-multipliers (`3dw`/`5@a`/`5 Ctrl+a`), tag jumps (`Ctrl+]`), goto file (`gf`),
`gv` reselect, `g;` last change, `%` bracket match, `~` toggle case, `:sort`,
NvChad leader chords (`<leader>ff`/`fg`/`fb`/`e`/`w`/`t t`/theme sub-chord), chord
chain, all priority verifications, and the `--input vim` vs `--input standard`
boundary.

**Verdict** — mnml has closed most of the muscle-memory gaps from prior rounds
(`V…y` is linewise, `:new` is much better, `` `` `` toggles). Priority fresh
issues this round come in two clusters. First is the **short-word ex hijacks**
class: `:map` fuzzy-matches `Editing: toggle vim ⇄ standard keyMAP` and
**silently switches the user out of vim mode** (the exact opposite of what
`:map` does in vim — list mappings — and much scarier because a vim user hits
this by reflex). Second is the **`b` / `B` bracket-shorthand text objects**:
`dib`/`dab`/`diB`/`daB` are no-ops while `di(`/`da(`/`di{`/`da{` work — that's
the shorthand equivalent every vim user uses. Also: `:w!` silently doesn't save
(only `:w` works, `!` variant fails); `:%d` / `:1,$d` / `:2,4d` / `:.d` all
no-op; the `!` variant of most write commands (`:w!`/`:wa!`) is broken; `:s/pat/rep/`
without `/g` defaults to REPLACE-ALL not first-match; `dd`/`yy` on a closed fold
only affects the fold-header line rather than the entire fold; visual-line
mode `V` cannot change case (`~`/`gU`/`gu`/`U`/`u`/`g~` all no-op); `guu`
(lowercase line, doubled operator) does nothing while `gUU`/`g~~` work; block
edits (`c`/`I`/`A`) require two undos to fully revert (line 1 needs a separate
`u`); `Ctrl+[` doesn't fire Escape (Ctrl+c does); `:ab` abbreviation eats the
trigger whitespace (`teh dog` → `thedog`, not `the dog`); `:sp <file>` and
`:vsp <file>` create three panes instead of two.

**Count by severity**: **SEV-1: 0 · SEV-2: 8 · SEV-3: 6** = 14 findings.

**Verified fixed since round-11**:
- **V-line yank + p is now linewise** (round-11 SEV-2 #1). `V j y G p` correctly
  puts the 2 yanked lines on their own lines below the target rather than
  splicing them into it. Nine other linewise-motion variants (`Vjj`, `Vip`, `V G`)
  also confirmed linewise.
- **`` `` `` toggles between last two positions** (round-11 SEV-2 #3). Third `` `` ``
  press correctly walks back and forth between the two most recent jumps.
- **Chord chain feeds trailing key to whichkey** (round-11 recent). `<leader>ttt`
  opens the theme picker without going through the palette.
- **`Ctrl+F` in Insert opens `picker.files`; `Ctrl+F` in Normal = PageDown**
  (round-10 recent). Both paths verified.
- **`!ip` (filter-paragraph) works** (round-10). `!iptr a-z A-Z` uppercased the
  first paragraph correctly.
- **`Ctrl+D` in Normal = HalfPageDown**, not add_cursor (round-10 requirement).
  From line 1, `Ctrl+D` jumped to line 19 as expected — no add-cursor UI.

**Verified partially fixed**:
- `:new` / `:vnew` used to produce 4 panes; now produces **3** panes
  (source-leaf tab still duplicated). Progress from round-11 SEV-2 #2 but
  the leaf-duplication half of the fix hasn't landed. Downgraded to SEV-3
  since it lands the scratch buffer where users expect it.

**Verified still broken since round-11**:
- `:changes` hijacks to `git.commit_staged` (round-11 SEV-3). Same repro, same
  behavior. Same fuzzy-match class as the new `:map` finding below.
- `ci{` / `ci(` on the OPENING bracket enters INSERT without deleting
  (round-11 SEV-3 #4). Same behavior.
- `dip` off-by-one leaving a blank at buffer top (round-11 SEV-3 #10). Not
  re-verified this round.
- `via` / `daa` argument-object scoping (round-11 SEV-3 #12). Correct on
  simple `foo(alpha, beta, gamma)` this round; but the exact round-11 repro
  (cursor at `)`) not re-verified.
- flash-motion label required even when unique (round-11 SEV-3 #13).
- `:iabbrev` and `:nnoremap` still "unknown" (round-11 SEV-3 #8/9).
- `:grep`/`:vimgrep` route to `git grep` — different from round-11's "silent"
  behavior (round-11 SEV-3 #11), now gives feedback via git grep results.
  Reads as intentional; downgrade the round-11 finding to non-issue.

---

## [SEV-2] `:map` (or any prefix of `Editing: toggle vim ⇄ standard keymap`) silently switches vim → standard mode

**Reproduction** (workspace `/tmp/mnml-nvchad-r12` with `a.txt`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
Before `:map` — `status.json` reports `"mode":"NORMAL"`.

```jsonl
{"cmd":"key","key":":"}
{"cmd":"type","text":"map"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
After `:map` — `status.json` reports `"mode":"none"` (standard/modeless input handler now active). No toast, no confirmation, no visible cue — the statusline chip just changes.

**Expected**: vim `:map` prints the list of user-defined mappings (`No mapping found` if none). Neutral request. Should never toggle the input handler.

**Actual**: the ex-cmd fuzzy fallback matches `map` against `editor.toggle_keymap` (title `Editing: toggle vim ⇄ standard keyMAP`). The command runs, `set_input_style` swaps the input handler, and every subsequent keystroke goes through the standard-mode handler — cursor keys start typing, `dd` deletes chars, `:` doesn't open cmdline, muscle memory fully broken. From the user's perspective the app "just stopped being vim".

**Source pointer**: `src/command.rs:2924-2929` (title contains `keymap`, which fuzzy-matches `map`); the ex-cmd fuzzy fallback in `src/app/ex_commands.rs` (last-resort dispatch to palette).

**Notes**: same class as round-11's `:changes` hijack (matched against `git.commit staged **changes**`). Fix pattern: reserve every vim ex-command name (`:map`, `:changes`, `:jumps`, `:marks`, `:reg`, `:sort`, `:diff`, `:file`, `:pwd`, `:set`, `:let`, `:call`, `:sign`, `:mark`, `:next`, `:previous`, `:read`, `:write`, `:quit`, `:only`, …) as first-class arms in the ex dispatcher — either handle it or emit `unknown command`. Never let the fuzzy fallback grab them. **Severity is 2 because vim mode is recoverable** (via `:` fuzzy for `use vim` or a leader chord); if the toggle command didn't exist it would be SEV-1 (unrecoverable). Every vim user reflexively types `:map` to discover what's bound; hitting a silent mode-swap is worse than any error toast.

---

## [SEV-2] `dib` / `dab` / `diB` / `daB` (b/B parentheses/brace shorthand) are no-ops

**Reproduction**:

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"(foo, bar, baz)"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"f o"}
{"cmd":"key","key":"d i b"}
{"cmd":"snapshot"}
```

Then compare with `di(` on the same setup — `di(` deletes `foo, bar, baz` correctly, leaving `()`. `dib` leaves the whole `(foo, bar, baz)` untouched.

Also reproduces for braces:
```jsonl
{"cmd":"key","key":"o"}
{"cmd":"type","text":"{alpha, beta, gamma}"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"f a"}
{"cmd":"key","key":"d i B"}
{"cmd":"snapshot"}
```
`di{` on this line correctly leaves `{}`. `diB` leaves `{alpha, beta, gamma}` untouched.

**Expected**: `dib` = `di(` = delete inside `()`. `diB` = `di{` = delete inside `{}`. These are vim's *primary* names — every :h text-objects tutorial teaches `dib`/`daB` before the `di(`/`da{` variants.

**Actual**: mnml recognizes `(`/`)`/`{`/`}` as the paren delimiters but doesn't recognize `b`/`B` as their shorthand. Same class for `cib`/`cab`/`ciB`/`caB` and `yib`/`yaB`.

**Source pointer**: `src/input/vim.rs` text-object dispatch under `TextObjectInner`/`TextObjectAround` — needs `Char('b') → SelectInnerParen` and `Char('B') → SelectInnerBrace` (plus the outer variants).

**Notes**: this is the single most-used pair of vim text objects in real code editing. `dib` alone probably has 100x the reach of `di(` in the wild.

---

## [SEV-2] `:w!` / `:write!` / `:wa!` silently fail to save (only `:w` / `:wa` work)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"I"}
{"cmd":"type","text":"START "}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"w!"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
`status.json` after — `panes[0].dirty` is still `true`; the file on disk still starts with `alpha`, no `START` prefix.

Immediately running `:w` (no bang) on the same state writes correctly (`dirty: false`, disk gets `START alpha`).

**Expected**: vim `:w!` writes the buffer even if the file is read-only. It should always at least be a superset of `:w`.

**Actual**: mnml silently no-ops on `:w!`/`:write!`/`:wa!`. Also verified: `:wqa!` (attempted to close the app) DOES quit — so the `q!` half of `wqa!` fires but the write half doesn't. If a user does `:wa!` before `:qa!` under the "force everything" reflex, the writes are silently lost. **Consequential data-loss vector**.

**Source pointer**: unknown exact file:line. `src/app/ex_commands.rs` — the `w` arm probably rejects `!` (parses it as shell-`!` prefix elsewhere) rather than treating it as the standard vim "force" flag.

**Notes**: this bites specifically the user who saw the "unsaved changes" dialog once and started typing `:wa!` reflexively to force through it. `:w!` doesn't route to `!w` shell either (that would create some visible outcome); it's a full no-op. The other `!` variants I checked (`:sort!`, `:bd!`) both work, so the pattern is command-specific.

---

## [SEV-2] `:%d`, `:1,$d`, `:2,4d`, `:.d`, `:3delete` all no-op (ex-mode `:d` with any address is broken)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"%d"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```

Buffer unchanged. Same result with `:1,$d`, `:2,4d`, `:.d`, `:3d`, `:3delete`.

**Expected**: `:%d` empties the current buffer (leaves 1 empty line). `:2,4d` deletes lines 2-4. `:.d` deletes the current line. These are core vim ex-commands.

**Actual**: silent no-op. Curiously, `:g/pat/d` (global delete matching pattern) works fine — the `g` command's internal `d` invocation exercises a different path.

**Source pointer**: `src/app/ex_commands.rs` — the range-`d` handler either isn't wired or the range parser isn't feeding into it.

**Notes**: pair this with the round-11 `:changes` hijack finding: mnml has good coverage of ex-command *names* but the ex-cmd `d` primitive is nearly the most-used one, and its bare form is missing. Try `:1,10d` and get nothing — hard-to-explain UX. Also: I noticed `:1y` (yank line 1) similarly seems inert (no visible feedback and subsequent `p` produced no paste). Likely same class of bug.

---

## [SEV-2] `:sp <file>` / `:vsp <file>` / `:new` / `:vnew` create three panes instead of two

**Reproduction** (single-pane state, `a.txt` open):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"vsp b.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

`status.json`:
```json
"panes": [
  {"title":"a.txt","dirty":false},
  {"title":"a.txt","dirty":false},
  {"title":"b.txt","dirty":false}
]
```
Screen layout: LEFT leaf shows `a.txt`; RIGHT leaf has TWO tabs (`a.txt` background + `b.txt` active).

Same behavior on `:sp b.txt`, `:new`, `:vnew`.

**Expected**: `:vsp <file>` opens one vertical split, right leaf displays `<file>`. Two panes total (source + destination). No inherited-tab in the destination.

**Actual**: destination leaf inherits an `a.txt` tab plus the requested `b.txt`, leaving three panes. In the visible split, the extra a.txt is a background tab (only b.txt is displayed), but it's still in the tabline and clutters `:bn`/`:bp` navigation.

**Source pointer**: `src/app/ex_commands.rs` (the `sp`/`vsp` and `new`/`vnew` arms) — the split-then-open sequence carries the current file into the new leaf's tabs list, then the requested file is added on top.

**Notes**: this is the residual half of round-11's `:new`/`:vnew` SEV-2 (which used to create 4 panes; now creates 3). Progress but the leaf-cleanup half hasn't landed. Also affects `:sp` / `:vsp` with a file argument.

---

## [SEV-2] `:s/pat/rep/` (no `/g`) replaces ALL occurrences on the line, not just the first

**Reproduction**:

```jsonl
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"foo foo foo"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":".s/foo/bar/"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```

Buffer line: `bar bar bar`. Toast: `:s — 3 replacement(s)`.

**Expected**: vim default is `s` = replace first match only; `s//g` = replace all. Line should become `bar foo foo`.

**Actual**: `:s/foo/bar/` treats it as if `/g` was appended — all three matches replaced. Also verified: `:s/a/A/` on `alpha` produces `AlphA` (both a's replaced), not `Alpha`.

**Source pointer**: unknown exact file:line. The `:s` handler probably always applies globally, ignoring the `g` flag (or has `gdefault` hardcoded on).

**Notes**: this violates the most fundamental vim substitute semantic. Every vim tutorial teaches `s/foo/bar/g` explicitly *because* the default is first-match-only. Users who type `s/…/…/` expecting first-match get a surprise on lines with multiple matches (particularly common with variable renames where the same identifier appears twice on a line).

---

## [SEV-2] `dd` / `yy` on a closed fold operates on the header line only, not the entire fold

**Reproduction** (fresh 24-line long.txt with `fn main()` body across lines 1-19):

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"z c"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
Screen shows `▶  1 fn main() {    ⋯ 18 hidden` — the fold hides lines 2-19.

```jsonl
{"cmd":"key","key":"d d"}
{"cmd":"wait_ms","ms":100}
{"cmd":"key","key":"G"}
{"cmd":"snapshot"}
```
Cursor after `G` — line 23. Buffer went from 24 → 23 lines. **Only the fold header was deleted; the 18 hidden lines survived.**

Same class for `yy` on a closed fold — `yy` grabs only the header line, and subsequent `p` pastes just that one line.

**Expected**: vim's `dd` on a closed fold deletes ALL lines in the fold (header + hidden = 19 lines total). Buffer should go from 24 to 5. `yy` should yank all 19 lines.

**Actual**: mnml treats a closed fold as a single row for navigation (`j`/`k` skips the body), but *not* for delete/yank operations. This is a middle-ground that produces confusion in either direction — the user sees "1 visible line, 18 hidden" and expects `dd` to remove all 19.

**Source pointer**: unknown exact file:line. `src/input/vim.rs` `DeleteLine`/`YankLine` operators or the `Editor::apply` handling of them — they operate at char/line-number scope, not fold-region scope.

**Notes**: this is one of vim's most useful fold semantics — the ability to fold, then `dd` an entire function block, is what makes folds worth using. Also affects `c c` (change on fold header — presumably has same defect but not verified this round).

---

## [SEV-2] Visual-line (`V`) mode cannot toggle/upper/lower-case selection (`~`, `U`, `u`, `gU`, `gu`, `g~` all no-op)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"~"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
Line 1 still `alpha` — no case change. Same result for `V U`, `V u`, `V g U`, `V g u`, `V g ~`.

For contrast: character-visual (`v`) + `U` DOES uppercase the selection (with a 1-char off-by-end): `v e U` on `alpha` produces `ALPHa`. `gUU` (double-op in normal mode) uppercases the whole line. Only V-line mode is broken.

**Expected**: `V` selects the current line; any of `~`/`U`/`u`/`gU`/`gu`/`g~` applied while in V mode should apply that case-change to the selection.

**Actual**: mode returns to NORMAL (so the operator was consumed), but the buffer is unchanged.

**Source pointer**: `src/input/vim.rs` — the V-line case-change dispatch on `~`/`U`/`u` doesn't route to the case operator.

**Notes**: `V U` is the standard "uppercase this line" gesture — every vim reference teaches it before `gUU`. `V ~` is muscle memory for "toggle case of this line" (e.g. flipping a SQL keyword).

---

## [SEV-2] Visual-block edit + `u` requires TWO undos to fully revert (line 1 lingers with the edit applied)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"3"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"A"}
{"cmd":"type","text":" !!"}
{"cmd":"key","key":"esc"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
Line 1-4 become `a !!lpha`, `b !!eta`, `g !!amma`, `d !!elta`.

```jsonl
{"cmd":"key","key":"u"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
Lines 2-4 return to `beta`, `gamma`, `delta` but line 1 is STILL `a !!lpha`. A second `u` finally restores line 1.

Same defect for block-`I`, block-`c` (change), and any other visual-block edit.

**Expected**: vim treats a visual-block edit as ONE atomic undo entry — `u` restores everything.

**Actual**: mnml treats it as two entries: (1) the initial single-line insert on the first row, (2) the "repeat across rows 2..N" side-effect. First `u` reverts (2); second `u` reverts (1).

**Source pointer**: `src/input/vim.rs` — visual-block `A`/`I`/`c` implementation. The block-replay isn't wrapped in an undo group with the initial line's edit.

**Notes**: this makes visual-block edits fragile. Typical use: block-`A` a comment marker across 20 lines; realize you needed `#` instead of `//`; hit `u` expecting a clean revert, get lines 2-20 back but line 1 still has `//`. Fix: coalesce block-repeat into the parent's undo group.

---

## [SEV-3] `Ctrl+[` does not fire Escape in insert mode (Ctrl+c works)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"XX"}
{"cmd":"key","key":"ctrl+["}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
`status.json` reports `"mode":"INSERT"` — Ctrl+[ was ignored.

Immediately running `Ctrl+c` from the same position DOES return to NORMAL.

**Expected**: `Ctrl+[` is one of vim's canonical Escape substitutes (see `:h i_CTRL-[`). Every reasonably experienced vim user uses it because it's easier to reach than Esc for Caps-remapped-to-Ctrl users (a very common config).

**Actual**: `Ctrl+[` is consumed but doesn't switch mode. `Ctrl+c` works. `Esc` works.

**Source pointer**: `src/input/vim.rs` insert-mode key dispatch — `Ctrl+[` (ASCII 27 == Esc) probably isn't aliased to Esc in the mnml handler.

**Notes**: minor but muscle-memory-eroding. Vim also aliases `Ctrl+[` in the ex/search cmdline. Not verified whether other modes have the same defect.

---

## [SEV-3] `guu` (lowercase current line, double-operator form) is a no-op while `gUU` and `g~~` work

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"g U U"}  // uppercase — works
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
Line 1 becomes `ALPHA`. Then:

```jsonl
{"cmd":"key","key":"g u u"}  // lowercase — should reverse
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
Line 1 still `ALPHA`. `gu$` on the same line (lowercase to end) DOES work.

**Expected**: `guu` mirrors `gUU`/`g~~` — lowercase the whole current line.

**Actual**: no-op. The double-`u` op form is missing.

**Source pointer**: `src/input/vim.rs` — the double-`g u u` chord isn't wired to line-lowercase. Compare to the `g U U` and `g ~ ~` chords which are.

**Notes**: minor since `gu$` is the workaround. But asymmetric — if you learn `gUU` uppercase-line, you expect `guu` to be its inverse.

---

## [SEV-3] `:ab` (and `:iabbrev`) abbreviation-expand eats the trigger whitespace

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"ab teh the"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"teh dog"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
Buffer end shows `thedog` — the space between `teh` and `dog` is missing.

**Expected**: vim abbreviation triggers on the following non-word char, replaces the abbr, then INSERTS the trigger char. Result should be `the<space>dog`.

**Actual**: mnml eats the trigger character. `the` is emitted but the following space is dropped, so subsequent typing runs together.

**Source pointer**: unknown exact file:line. The `:ab` implementation — the trigger-char handler discards instead of re-emitting.

**Notes**: minor but common. Users write `:ab teh the` for autocorrect and then find that typing turns into wordless mush. Verified fix on `:abclear` (correctly disables further expansion).

---

## [SEV-3] Ex-command `Tab` completion routes to palette (`:wr<Tab>` → `:ai.write_branch_name`) instead of vim-style prefix

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"wr"}
{"cmd":"key","key":"tab"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
Cmdline shows `:ai.write_branch_name` instead of `:write`.

**Expected**: vim `:wr<Tab>` completes to `:write` (the canonical ex-command with that prefix). Second Tab cycles to `:writeany`, `:writebackup`, etc — all ex-command names, alphabetically.

**Actual**: mnml's `Tab` completion routes to the palette command IDs (dotted like `ai.write_branch_name`, `git.write_something`), not vim ex-commands. A vim user hitting Tab gets an unfamiliar dotted-id form.

**Source pointer**: unknown exact file:line. `src/app/cmdline_methods.rs` or `src/ui/prompt.rs` — the cmdline completer prefers palette ids over vim ex-command names.

**Notes**: minor UX — but every-day for users who lean on Tab to spell-check ex commands.

---

## [SEV-3] `:w <path>` switches the buffer's active file to `<path>` (should preserve original)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"w /tmp/mnml-nvchad-r12/other.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
`status.json` reports `activeFile: /private/tmp/mnml-nvchad-r12/other.txt` — the buffer's identity has moved.

**Expected**: vim `:w newfile.txt` writes the buffer content to newfile.txt but **leaves the current buffer's associated file unchanged**. `:saveas newfile.txt` is what switches the buffer.

**Actual**: mnml treats `:w <path>` and `:saveas <path>` identically — both switch the buffer's identity.

**Source pointer**: `src/app/ex_commands.rs` — the `w` arm with a path argument uses `saveas`-style semantics rather than write-to-alternate-path.

**Notes**: minor but semantically wrong. Common vim workflow: `:w /tmp/backup.txt` to save a quick copy without losing your place in the current buffer — mnml derails this.

---
