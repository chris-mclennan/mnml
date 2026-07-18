# nvchad-round-11 — vim-mode hunt, 2026-07-12

## Executive summary

Ran a 60-minute headless vim-mode session against `~/Projects/mnml/target/release/mnml --input vim`. Muscle memory covered: modal editing, text objects, operators + motions, macros/marks/registers, `.` repeat, jumplist, changelist, find-char, visual + visual-block operations, ex commands (`:s`, `:g`, `:norm`, `:put`, `:earlier`, `:tabnew`, `:sp`/`:vsp`/`:new`/`:vnew`, `:make`, `:!`, `:r !`), `:reg`/`:marks`/`:history`, folds, `<leader>ff`/`fg`/`fb`/`e`/`w`, and recently-landed items (`Ctrl+F` in Insert routes to `picker.files`, `Ctrl+F` in Normal is PageDown, `:set autoread`, `:set foldenable`, `!!` / `!ip` filter, `:%norm`, tree-sitter `if`/`ic`/`ia` text objects, `:e!` reload, `:earlier N[sm]`).

Verdict — mnml feels reliably vim for the everyday chords (i/esc, hjkl, gg/G, cw/dw/cc/dd/yy/p, `.` repeat with count, macros `qa…q` + `N@a`, marks a-z + A-Z, `:s/pat/rep/gc` walk with y/n/a/q, folds `zc`/`zo`/`zR`/`za`, jumplist `Ctrl-o`/`Ctrl-i`, buffer-nav `:b <N>` numeric, tabnav `gt`/`gT`). **The biggest fresh gap is that `V…y` (visual-line yank) stores content characterwise — subsequent `p` glues it onto the current line instead of putting new lines below.** For a NvChad user that pattern (`V<motion>y G p`) is second nature, so this bites early and often. Also new this round: `:new` / `:vnew` double-split (4 panes instead of 2), `ci{`/`ci(` no-op when cursor is exactly on the opening bracket, `` ` ` `` (backtick backtick) walks the jumplist instead of toggling last-two positions, and `:changes` fuzzy-hijacks into `git.commit_staged`. Everything else in the "hunt for" list I checked works, or reads as an acceptable design deviation.

Count by severity: **SEV-1: 0 · SEV-2: 3 · SEV-3: 9** = 12 findings.

Verified fixed since prior rounds: `:b 1` numeric buffer switch (round-2 SEV-2), `j` from fold header lands past the fold (round-2 SEV-2), `Ctrl+I` jumplist forward (round-2 SEV-2), `:new`/`:vnew` as an ex command is at least recognized (round-10 landing note holds), `Ctrl+F` in Insert opens `picker.files` (round-10 recent), `Ctrl+F` in Normal = PageDown (round-10 recent).

---

## [SEV-2] `V<motion>y` stores content characterwise; `p` glues yanked lines onto current line

**Reproduction** (workspace `/tmp/mnml-nvchad-round11` with `a.txt` = `Xalpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"y"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"$"}
{"cmd":"key","key":"p"}
{"cmd":"snapshot"}
```

**Expected**: vim linewise yank + `p` puts the two yanked lines *below* the current line regardless of column. Result:
```
7 eta
8 theta
9 Xalpha
10 beta
```

**Actual**: mnml pastes the yanked buffer characterwise, splicing it into the current line at cursor column:
```
7 eta
8 thetaXalpha
9 beta
```

`yy` (single-line yank in normal mode) correctly keeps the linewise flag, so this is specific to yanks that originate from V / V-LINE mode. Reproducible with any linewise motion span (`Vjj`, `Vip`, `V G`). `V d` (visual-line delete) exhibits the same defect on subsequent `p`.

**Source pointer**: unknown exact file:line. Likely the V-mode `y` codepath in `src/input/vim.rs` doesn't tag the resulting register entry as `RegisterKind::Line`. `Editor::yank_linewise` (or equivalent) presumably stores type; V-mode yank appears to go through the character path.

**Notes**: this is one of the most-used vim gestures for a NvChad refugee — the flow `V}y }p` (yank a paragraph, paste it below next paragraph) is muscle memory. Every attempt currently produces the "glued to current line" surprise.

---

## [SEV-2] `:new` / `:vnew` create 4 panes (3 duplicates of the current file + 1 scratch) instead of a 2-way split with a scratch

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"new"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

Initial `panes` list: `[{title:"a.txt",dirty:false}]` (single leaf).

**Expected**: one horizontal split; the new leaf shows a `[scratch]` buffer. Result: `[a.txt, [scratch]]` — two panes, one on top, one below.

**Actual**: `panes` becomes `[a.txt, a.txt, a.txt, [scratch]]` (four panes; screen shows four horizontal splits stacked vertically, the top three all showing `a.txt`, the bottom one showing `[scratch]`). `:vnew` reproduces the same 4-pane result vertically.

**Source pointer**: `src/app/ex_commands.rs:1463-1472` (the `"new"` arm) calls `view.split_down` *and then* `view.split_new_scratch`. `split_new_scratch` (`src/app/layout.rs:313`) itself calls `split_active`, so the split happens twice; the extra tabs come from re-splitting a leaf that was just split.

**Notes**: fix is one of: drop the leading `view.split_down` call (let `split_new_scratch` do the split), or change `split_new_scratch` to only *add the scratch buffer* to the current leaf and expect the caller to split. Same fix pattern on the `"vnew"` arm below it.

---

## [SEV-2] `` `` `` (backtick backtick) walks the jumplist backward instead of toggling between the last two positions

**Reproduction** (long.txt = the seeded 31-line rust file):

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"5"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"*"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"` `"}
{"cmd":"snapshot"}
{"cmd":"key","key":"` `"}
{"cmd":"snapshot"}
```

**Expected**: vim `` ` ` `` (or `''`) reads the ' mark, which always points at the *position before the last jump*. First `` ` ` `` from line-30 lands at line-5 (before `G`) and updates ' to line-30. Second `` ` ` `` reads ' again and lands back at line-30. Effectively a toggle between two positions.

**Actual**: first `` ` ` `` goes from line-30 → line-5. Second `` ` ` `` from line-5 → line-11 (walks *another* step backward in the jumplist toward the `*` jump). mnml is treating `` ` ` `` like `Ctrl-o` rather than "jump to the ' mark".

**Source pointer**: unknown exact file:line. `src/input/vim.rs` handler for the `` ` `` prefix — the ' mark should not be re-written by every `` ` ` `` invocation.

**Notes**: vim uses this for A→B→A→B round-tripping between two edit spots ("check the header, come back, check again"). Without proper toggle semantics, `` ` ` `` is redundant with `Ctrl-o` and users lose that gesture.

---

## [SEV-3] `ci{` / `ci(` when the cursor is *exactly on the opening bracket* enters INSERT mode without deleting the pair contents

**Reproduction** (fresh workspace, cursor on the `{` at col 1):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"{alpha, beta, gamma}"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"c i {"}
{"cmd":"type","text":"REPLACED"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```

**Expected**: vim treats cursor-on-`{` as being inside the pair; `ci{` deletes `alpha, beta, gamma` and enters INSERT with cursor between `{` and `}`. Result: `{REPLACED}`.

**Actual**: `ci{` merely enters INSERT mode at col 1 without deleting anything. Typing `REPLACED` prepends it: `REPLACED{alpha, beta, gamma}`. Same defect with `ci(` / `ca(` / `ca{` — cursor-on-opening is not recognized. If the cursor is one char *inside* the pair (e.g. after `l`), `ci{` works correctly.

**Source pointer**: unknown exact file:line. `SelectInner{Paren,Brace,…}` search likely scans strictly outward from cursor and skips the opening if the cursor already sits on it.

**Notes**: NvChad users routinely land at the start of a struct literal (via `f{`) and then `ci{` — they don't step one more char right first. `ca{` from cursor-on-`{` has the same defect. Same class as the pre-existing "cursor-on-quote and `ci\"`" case in general vim semantics.

---

## [SEV-3] `:new` / `:vnew` design: mnml's "extra split" behaviour aside, both commands still don't handle a file argument the vim way

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"new b.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

**Expected**: single horizontal split; new leaf shows `b.txt`.

**Actual**: the code path in `src/app/ex_commands.rs:1463-1472` special-cases the empty-path branch to open scratch, and the non-empty branch calls `open_path` *after* `view.split_down`. But `open_path` opens `b.txt` in the *current* leaf (which is now the just-split *new* leaf — so the file lands OK for `:new b.txt`, aside from the extra-split defect above). This entry is a note that once SEV-2 #2 is fixed, the `:new <file>` path also needs the split-count review — it currently double-splits identically.

**Source pointer**: `src/app/ex_commands.rs:1463-1482`.

**Notes**: bundling this as a SEV-3 rather than folding into #2 because the file-arg path is exercised by `:new %:h/foo.txt` (open sibling) which NvChad users hit constantly.

---

## [SEV-3] `:changes` fuzzy-matches `git.commit_staged` — vim command silently hijacked to open an unrelated commit prompt

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"changes"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

**Expected**: vim `:changes` shows the change list (each change position + text). mnml's honest fallback should be `:changes — unknown command` toast (as it does for `:iabbrev`, `:cnoremap`, `:xyzabc`).

**Actual**: the ex-cmd dispatcher fuzzy-matches "changes" against the palette and finds `git.commit_staged` ("Git: commit staged changes"). Result: the commit-message prompt opens over the buffer. A vim user typing `:changes` gets no indication that mnml misread it — the prompt looks like it belongs to `:changes`.

**Source pointer**: `src/app/ex_commands.rs` — the fallback fuzzy palette lookup at the bottom of the match block. The prefix `changes` matches "commit staged **changes**" and outranks a stricter "no such command" toast.

**Notes**: two-line fix — reserve `changes`/`cha` for either a proper impl or a "no such command in mnml" toast, so the fuzzy fallback can't grab it. Same class of hijack likely applies to any vim command whose prefix appears in a palette title (e.g. `:diff` might grab `git.diff_pane`, `:list` might grab a listy palette entry).

---

## [SEV-3] `:iabbrev` (long form) is "unknown"; only `:ab` (short form) works

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"iabbrev teh the"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

**Expected**: same behavior as `:ab teh the` — registers the abbreviation for INSERT mode.

**Actual**: bottom toast reads `:iabbrev teh the — unknown command`. `:ab teh the` on the same buffer *does* register the abbreviation (verified — typing `teh ` in insert expands to `the `).

**Source pointer**: `src/app/ex_commands.rs` — the `"ab"` match arm doesn't list `iabbrev` / `ia` as aliases.

**Notes**: vim aliases: `:iabbrev` = `:ia` = `:ab` (mode-restricted vs `:abbrev` which covers cmdline+insert). Real vimmers reach for the long form more than the short — muscle memory from `:cabbr`, `:cnoreabbrev`, etc.

---

## [SEV-3] Vim mapping commands (`:nmap`, `:nnoremap`, `:cnoremap`, `:cmap`, `:vmap`, `:xnoremap`, …) all report "unknown command"

**Reproduction**:

```jsonl
{"cmd":"key","key":":"}
{"cmd":"type","text":"nnoremap X dd"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

**Expected**: even if mnml decides not to support runtime rebinding, a vim user expects at least an informative error like `:nnoremap — mnml maps in ~/.config/mnml/keys.toml, not at runtime`. Right now the toast is a bare `:nnoremap X dd — unknown command`, which reads as "mnml doesn't understand vim rebinding syntax" rather than "mnml chose a different rebinding surface".

**Actual**: bare "unknown command" toast; user is left inferring where to look.

**Source pointer**: fallback path in `src/app/ex_commands.rs`.

**Notes**: minor UX — but the ex-command surface is the discovery affordance for users searching for how to remap. A one-line dedicated toast that says "mnml keys are configured in `<path>`" would remove a documentation lookup.

---

## [SEV-3] `:grep <pat>` and `:vimgrep <pat> *` produce no visible feedback (silent no-op)

**Reproduction**:

```jsonl
{"cmd":"key","key":":"}
{"cmd":"type","text":"grep foo"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"vimgrep foo *"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

**Expected**: at minimum a toast pointing to `<leader>fg` / `:Rg foo` (both of which work). Ideally either handler runs the workspace grep with `foo` and drops results in a picker or quickfix pane.

**Actual**: neither command produces any toast, prompt, or state change. Contrast with `:Rg foo` which correctly runs a grep, and `:iabbrev` / `:xyzabc` which produce an "unknown" toast. `:grep`/`:vimgrep` fall into a silent middle ground.

**Source pointer**: unknown exact file:line — likely partial fuzzy-match hits some palette entry that itself no-ops when passed args.

**Notes**: same class as the `:changes` hijack — the fuzzy fallback is too aggressive. Either handle `:grep`/`:vimgrep` explicitly (route to `Rg`/`workspace.grep`) or reserve them for a clear "unknown" toast.

---

## [SEV-3] `dip` (delete inner paragraph) leaves an extra blank line at the top of the buffer — off-by-one

**Reproduction** (`prose.txt` has 7 pangram lines, then a blank line 8, then more paragraphs):

```jsonl
{"cmd":"open","path":"prose.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"d i p"}
{"cmd":"snapshot"}
```

**Expected**: vim `dip` deletes the *inner* paragraph = lines 1..7 (leave the trailing blank separator line 8 alone). New line 1 = the surviving blank; new line 2 = "Second paragraph starts here."

**Actual**: mnml also deletes 7 lines, but the resulting buffer has TWO blank lines at the top before "Second paragraph starts here." lands on line 3. There's one leftover blank that wasn't part of the target range.

**Source pointer**: unknown — likely `SelectInnerParagraph` in `src/input/vim.rs` or its resolver. Either the anchor or the endpoint of the range is off by one row.

**Notes**: hits every text-editor writer — deleting a first paragraph should not leave dangling blanks. `dap` variants I didn't verify here but same suspicion.

---

## [SEV-3] `via` / `vaa` (visual-around/inside argument via tree-sitter) selects a 1-character range when cursor is at the closing paren

**Reproduction** (`long.txt`, cursor placed inside `println!("{}", c);`):

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"/"}
{"cmd":"type","text":"println"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"$"}
{"cmd":"key","key":"h"}
{"cmd":"key","key":"v i a"}
{"cmd":"snapshot"}
```

**Expected**: `via` (inner argument) selects `c` (the second arg of the println!). Status shows Sel 1 or similar.

**Actual**: status shows `Sel 1` but the highlighted range is just the closing paren `)`. Cursor didn't jump to the argument boundary — the selection stays at cursor position. Tree-sitter appears to fail to identify the enclosing arg node at that column.

**Source pointer**: `src/input/vim.rs:3104` (`Char('a')` under `TextObjectInner` maps to `SelectInnerArgument`). The tree-sitter resolver behind `SelectInnerArgument` must be scoping only to the exact node under the cursor rather than the enclosing arg node.

**Notes**: NvChad users use `daa`/`cia`/`via` daily. Regression risk from `via`/`daa` is subtle because Sel 1 looks like a valid state until you check the payload. Same class of gap likely on `if` / `ic` outside the ideal cursor position (verified `cif` on `fn one() {`'s line 4 col 1 also selects only the newline between `{` and inner body).

---

## [SEV-3] Flash-motion `s<a><b>` requires a label keypress even when the match is unique

**Reproduction** (`a.txt` has `epsilon` only once):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"s"}
{"cmd":"type","text":"ep"}
{"cmd":"snapshot"}
```

**Expected**: leap/hop/flash convention — when the two-char query has a single visible match, the cursor auto-jumps without waiting for the label. (This is the entire point of flash for common bigrams.)

**Actual**: mnml paints an overlay label `f` on the unique match and holds the cursor in the labeled-jump state; the user has to press `f` explicitly to consummate the jump. Even for `ep` in a 8-line buffer with one match, the extra keypress is required.

**Source pointer**: `src/input/vim.rs:2596-2600` (`s` → `Prefix::Flash1`), plus the `FlashStart` handler in the app layer (`AppCommand::FlashStart`).

**Notes**: might be intentional to keep muscle-memory consistent between "unique match" and "multi-match" cases; documenting as a finding because the every-day flash cost is 1 wasted keypress. If it's intentional, worth surfacing in the manual so users don't wait for the auto-jump.
