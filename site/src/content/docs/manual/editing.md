---
title: Editing
description: mnml's pluggable input layer — vim and standard editing without `if vim {}` scattered through the codebase.
---

![mnml quick tour — vim edit, stage + commit via the git status pane, swap to standard mode, edit again](../../../assets/demos/quick-tour.gif)

A ~45-second tour: open a file from the picker, edit in vim mode, save with `:w`, stage + commit through the git status pane, view the commit graph, swap to standard mode with `:set input=standard`, and finish with a `Ctrl+S` save. Both modes are first-class; the editor is the same buffer underneath.

mnml's editing model rests on one decision: **both vim and standard keymaps are first-class**, swappable at runtime, and the editor never branches on which is active. This page covers what each mode offers, how to switch between them, and the edit primitives both modes share.

## The pluggable input layer

mnml ships two `Box<dyn InputHandler>` implementations — one modal (vim), one modeless (standard). Both translate key events into a closed set of `EditOp` operations (`Insert`, `Delete`, `Replace`, `MoveCursor`, etc.) which the editor's single `apply` chokepoint executes. The buffer, render layers, and LSP integration never know which handler produced the operations.

This is the part you don't see but everything else depends on. Adding multi-cursor or a new motion in one mode doesn't need ceremony in the other — input handlers compose into edit ops; ops compose into buffer state; render reads buffer state. Each layer is one concern.

The user-facing consequence: every feature in mnml works identically regardless of which mode you pick. `Ctrl-P` to fuzzy-find a file, `:` to open the ex-command line — same buffer, same LSP completion, same git gutter.

## Picking your mode

```toml
# ~/.config/mnml/config.toml
[editor]
input_style = "vim"        # or "standard"
```

Switch at runtime:

```vim
:set input=vim
:set input=standard
```

Or via the command palette (`Ctrl-Shift-P`): **editor: toggle keymap**.

Per-workspace override at `<workspace>/.mnml/config.toml` if you want vim everywhere except, say, your team's onboarding-friendly Rails repo.

## Vim mode

mnml's vim handler covers modal editing in depth. If you've used vim or Neovim, the muscle memory transfers directly.

### Modes

| Mode | Enter | Use for |
|---|---|---|
| **Normal** | `Esc` | Movement, operators, ex-commands |
| **Insert** | `i` / `a` / `o` / `O` / `S` / `c…` | Typing text |
| **Visual (char)** | `v` | Char-by-char selection |
| **Visual (line)** | `V` | Line selection |
| **Visual block** | `Ctrl-V` | Column / block selection (multi-cursor flavor) |
| **Replace** | `R` | Overwrite-as-you-type |

`s` is deliberately *not* an insert-entry chord in mnml — it triggers [flash motion](#flash-motion-s). Vim's substitute is still `cl`, and `S` still substitutes the whole line.

The mode chip in the bottom-left of the statusline shows which mode you're in; the cursor shape changes per-mode too (block in Normal, bar in Insert, underline in Replace). The chip distinguishes the three visual flavors — `VISUAL` for char-wise, `V-LINE` for `V`, `V-BLOCK` for `Ctrl-V` — so the geometry is visible at a glance instead of collapsing into one label. The mode-chip tooltip differentiates them too.

### Motion + visual-entry semantics

A handful of motions and visual-entry chords match vim's behavior precisely — worth knowing the edge cases:

- **`$` lands on the last printable char** of the line, not one cell past it. In Normal mode the block cursor sits on the last visible character; a paste lands immediately after it (rather than one column further right). Empty lines collapse to the line start.
- **`G` (bare) lands on the start of the last line.** Past versions could overshoot onto the phantom row after a trailing newline; the cursor now anchors at `line_start(last_line)` cleanly.
- **`V` (visual-line) leaves the cursor where it was.** The anchor moves to `line_start`; the cursor doesn't snap down a row. The full line still reads as selected, and `'<` / `'>` marks reflect the cursor's row after a yank.
- **`*` advances past the current match.** The star chord now genuinely jumps to the *next* occurrence of the word under the cursor (rather than the first match at-or-after, which was the cursor's current word). `#` is the same in the reverse direction.
- **`<N>@<r>` honors the count.** `5@a` replays macro `a` five times. Past versions silently dropped the count and ran the macro once; the count threads through to the App dispatcher's replay loop.

### Operator-pending motions are inclusive on `e` / `E` / `$`

Vim's `:help inclusive` says that when an operator (`d` / `y` / `c`) is paired with `e` / `E` / `$`, the destination character is **included** in the operated range. mnml's vim handler now follows that rule end-to-end:

- **`de`** deletes from the cursor up to and including the last char of the current word (e.g. `foo bar` with the cursor on `f` → `de` leaves `bar`). The trailing whitespace stays.
- **`ye`** yanks the same span — registers see the whole word.
- **`ce`** changes it: deletes through the last char and drops into INSERT mode.
- **`d$`** / **`y$`** / **`c$`** include the final character of the line (vs. stopping one cell short).
- **`cw`** is now an alias for **`ce`** (vim canon: change-word excludes the trailing whitespace, so `cw` → `ce` is a substitution at the motion layer). Same for `cW` → `cE`. `dw` and `yw` keep their exclusive semantics (whitespace eats the word boundary).

Exclusive motions (`w`, `W`, `h`, `l`, `0`, `^`, etc.) are unchanged — `[anchor, cursor)` is still the deleted/yanked span. Inclusive motions push an extra `MoveRight` op before `DeleteSelection` so the destination char is part of the range.

This is the kind of behavior you only notice when it's wrong (a `cw` that left the trailing whitespace, then re-typing pushed it across) — but once it's right, the muscle memory works exactly as vim's `:help` documents it.

![cw at "brown" in "The quick brown fox jumps", type BIG, Esc — line becomes "The quick BIG fox jumps" (space preserved); dd then u then :reg shows the unnamed + numbered registers](../../../assets/tapes/vim-operator-inclusive.gif)

### Charwise VISUAL is inclusive too

The same rule governs Visual mode. Vim's charwise Visual selection *includes* the cell the block cursor sits on (`:help visual-mode`) — `v` on its own selects one character, and `v` `l` `l` selects three. mnml's selection is a half-open `[lo, hi)` range internally, so until this was fixed every `v`+motion operation came up one character short:

| Keys (buffer is `abcdefghij`) | mnml now | mnml before |
|---|---|---|
| `v` `y` | yanks `a` | yanked the empty string |
| `v` `l` `l` `y` | yanks `abc` | yanked `ab` |
| `v` `e` `y` | yanks `abcdefghij` | yanked `abcdefghi` |
| `v` `l` `l` `d` | leaves `defghij` | left `cdefghij` |

The bare `v` `y` row is the one that bit: it silently replaced the unnamed register with nothing.

The widening is a dedicated `MakeSelectionInclusive` edit op emitted ahead of `DeleteSelection` / `ReplaceSelection` / `YankSelection`, not an extra `MoveRight` the way the operator-pending motions do it. On a *backward* selection — you pressed `v` then `h` `h`, so the cursor sits before the anchor — moving the cursor right would shrink the range instead of growing it, and vim includes the anchor's own character either way. The op always extends whichever end is higher.

Two guards on top of that:

- **It extends by a whole character, not a byte.** `v` `y` on the `é` of `héllo` yanks `é`, not half a UTF-8 sequence.
- **It never crosses the line terminator.** Vim's charwise selection stops at the last cell of a line; swallowing the newline would make a later `p` split the neighbouring line — the same class of bug the `$`-inclusive guard already fixed for operator-pending motions.

`V` (linewise) and `Ctrl-V` (blockwise) are untouched. Both are inclusive by construction and widening them again would overshoot. Multi-cursor visual widens *every* cursor's selection rather than just the primary — otherwise the primary deletes one character more than its extras and the rows come out different lengths.

Inclusivity applies to the three operators that take a range out of the buffer: `d` / `x`, `c` / `s`, and `y`. `>` / `<` and the Visual case operators (`u` / `U` / `~`) still act on the un-widened range.

### `Ctrl+R Ctrl+W` and `Ctrl+R Ctrl+A` in INSERT mode

Two vim chords for inserting the symbol under the cursor without leaving INSERT:

| Chord | Action | Command |
|---|---|---|
| `Ctrl+R Ctrl+W` | Insert the identifier under the cursor at the caret | `editor.insert_word_under_cursor` |
| `Ctrl+R Ctrl+A` | Same, but for the full WORD (whitespace-separated; includes punctuation) | `editor.insert_bigword_under_cursor` |

Useful when extracting a name into a new declaration — type `let `, then `Ctrl+R Ctrl+W` to pull the symbol you were just looking at, then `= …`. The vim INSERT handler checks for the `Ctrl+W` / `Ctrl+A` follow-up **before** the lowercase-letter register-paste arm (the prior implementation routed the chord into `"a` register paste and the `Ctrl+R` prefix was eaten with no insertion).

### Folding chords in NORMAL mode

Vim's fold chords are **directional and idempotent** (`:help zo`): `zo` opens a fold and leaves it open, `zc` closes one and leaves it closed. Only `za` alternates. mnml used to bind all six of `za` `zA` `zo` `zO` `zc` `zC` to the same toggle, so pressing `zo` twice *closed* a fold — something vim never does. The `z` prefix now routes three ways:

| Chord | Command | Behavior |
|---|---|---|
| `za` / `zA` | `editor.toggle_fold` | Toggle the fold at the cursor |
| `zo` / `zO` | `editor.open_fold` | Open it — no-op if it's already open |
| `zc` / `zC` | `editor.close_fold` | Close it — no-op if it's already closed |
| `zf` | `editor.toggle_fold` | Fold the enclosing bracket pair (in Visual, `editor.fold_selection` folds the selected rows) |
| `zR` / `zE` | `editor.unfold_all` | Drop every fold in the buffer |
| `zM` | `editor.fold_all_brackets` | Fold every multi-line bracket pair |
| `zj` / `zk` | `editor.fold_next` / `editor.fold_prev` | Jump to the next / previous top-level fold |

`zO` / `zC` are vim's *recursive* forms. mnml's folds are line-based with a single level per header, so they reduce to the same action rather than sitting there as dead chords — the same reasoning `zA` already followed.

`editor.open_fold` and `editor.close_fold` are palette commands in their own right (unbound outside the `z` prefix), so you can put them on any chord you like via `[keys.vim]`.

`Ctrl+Shift+[` and `Ctrl+Shift+]` toggle and unfold respectively, mirroring VS Code's canonical fold/unfold chords. The vim handler's bracket prefix (for `[c` / `]c` git hunks, `[d` / `]d` diagnostics) only consumes the bare bracket when `!ctrl` — the modifier-bearing chord falls through to the chord-chain / global keymap so the editor's fold commands can pick it up.

### `:%s/.../.../g` is one undo step

A global substitute that replaces twelve matches is a single undo entry — one `u` reverts the whole substitute. This matches vim's behavior and removes a real footgun (the prior implementation pushed one undo per replaced line, so reverting felt like progress until you noticed nothing had actually finished). The `:s` family rolls every internal `apply` into one checkpoint via `Editor::atomic_undo`.

### Operators + motions + text objects

The standard vim composition rules:

- **Operator** + **motion**: `dw` (delete word), `c$` (change to end of line), `>5j` (indent 5 lines down)
- **Operator** + **text object**: `diw` (delete inner word), `ci(` (change inside parens), `da{` (delete around braces with whitespace)
- **Visual** + **operator**: select first with `v`, then `d` / `c` / `y` / `>`

Standard operators (`d` delete, `c` change, `y` yank, `>` indent, `<` dedent, `=` reformat, `gU` uppercase, `gu` lowercase, `gq` rewrap), all the usual motions (`hjkl`, `wbge`, `0$^`, `f`/`t`/`F`/`T`, `%`, `gg`/`G`, `H`/`M`/`L`, `Ctrl-D`/`Ctrl-U`/`Ctrl-F`/`Ctrl-B`), and a robust text-object inventory:

- **Inner / around**: `i` / `a` modifier — `iw` inner word, `aw` around word; `i(` `i)` `i[` `i]` `i{` `i}` `i<` `i>` paired-delim inner; `a(` etc. around (includes the delimiter); `i"` `i'` `i\`` quoted; `ip` paragraph; `is` sentence.
- **Tree-sitter objects**: `if` / `af` function, `ic` / `ac` class, `ia` / `aa` argument. Powered by tree-sitter, so the boundaries are AST-aware — not regex-based heuristics.
- **Indent objects**: `ii` / `ai` based on indent level — handy in Python and YAML.

### Doubled-form operators

`cc`, `guu`, `gUU`, `g~~` operate on the whole current line — change-line, lowercase-line, uppercase-line, toggle-case-line. After the op the cursor lands at the start of the *next* line, so a chord-chain (`guuguu`, `g~~g~~`) walks down lines one stroke pair at a time. `dd` and `yy` were already line-wise via their own ops; the doubled forms now mirror them precisely.

### Registers, macros, marks

- **Named registers**: `"ay` (yank into register `a`), `"ap` (paste from `a`), `"+y` (yank to system clipboard), `"*y` (yank to primary selection on X11/Wayland).
- **Numbered registers** behave like vim's delete-ring: `"0` is the last yank, `"1`–`"9` are the last 9 deletes (newest first).
- **Macros**: `qa` start recording into register `a`, `q` to stop, `@a` to play back, `@@` to repeat the last. Macros persist across mnml restarts.
- **Marks**: `ma` set mark `a` in this buffer; `'a` jump to mark `a` (line); `` `a `` jump to mark `a` (exact column). Uppercase marks (`mA`) are global across files. Marks persist across restarts.
- **The dot repeat**: `.` repeats the last edit operation. Includes inserted text. Works after `dw`, `cw`, `>j`, `ciw"hello"`, etc.
- **Jumplist + change-list**: `Ctrl-O` / `Ctrl-I` walks the jump history; `g;` / `g,` walks the change history.

### The `:` ex-command line

A deep ex-command surface, beyond just `:w` / `:q`:

```vim
:w                          " write
:wa                         " write all
:q                          " quit
:qa / :qall / :quitall      " quit all — refuses (toast) when any pane is dirty
:qa!                        " force-quit all (discards unsaved work)
:e <path>                   " open file
:bn / :bp                   " buffer next/prev
:b <name>                   " switch to buffer by name (fuzzy)
:tabnew / :tabn / :tabp     " tab pages

:%s/old/new/g               " global substitute
:'<,'>s/foo/bar/g           " substitute in visual selection
:s//repl/g                  " repeat last search, swap replacement
:1,10s/x/y/g                " line-range substitute
:g/pattern/d                " delete all lines matching pattern
:v/pattern/d                " delete all lines NOT matching
:g/^TODO/norm dd            " delete every TODO line via :norm
:'<,'>norm @a               " run macro `a` on every visual-mode line

:sort                       " sort current buffer
:sort u                     " sort + dedupe
:'<,'>sort n                " numeric sort visual selection
:!cmd                       " shell command (output replaces visual; output appended w/ :.!cmd)
:r <path>                   " read file's content at cursor
:r !date                    " insert shell command output
:set input=vim              " runtime config change
:set tab_width=2
```

Ex-command history is searchable: type `:` then `Ctrl-P` / `Ctrl-N` (or `↑` / `↓`) to walk history.

You can define your own commands via `[ex_commands]` in config — mnml expands them as command-id calls so they appear in the palette too.

### vim-surround

mnml ships a built-in vim-surround:

- `cs"'` — change surrounding `"` to `'`
- `cs([` — change surrounding `(` to `[` (note: `(`/`)` differ — `(` adds whitespace inside, `)` doesn't)
- `ds"` — delete surrounding `"`
- `ysiw"` — yank-surround inner word with `"` (i.e., wrap the word in quotes)
- `S"` (visual mode) — surround the selection with `"`

### Multi-cursor in vim

Visual block (`Ctrl-V`) is the native multi-cursor primitive:

- Select a column with `Ctrl-V` then `I` to insert at every line's start, `A` to append at every line's end.
- Use `c` to change every selected cell at once; the change is replicated.

[Flash motion](#flash-motion-s) is the other way out of a repetitive `f` / `t` / `/` `?` chain when the target is already on screen.

### Flash motion (`s`)

mnml gives `s` to a flash/leap-style two-character jump rather than to vim's substitute. That's a deliberate trade: vim's `s` is `cl` with fewer keystrokes, while a screen-local jump earns its key several times a minute. Substitute is still reachable as `cl`, and **`S` still substitutes the whole line** — so the pair is asymmetric. Lowercase `s` navigates; uppercase `S` edits.

The gesture is **three keystrokes, not two**:

1. `s` arms flash. The statusline's pending-chord indicator shows `s`.
2. Type the two characters you can see at the target — the indicator shows `sg`, then flash fires on the second.
3. Every visible occurrence of that pair is overpainted with a one-character **label**. Press a label to jump to it, or `Esc` to cancel.

Step 3 is the one people miss, and it looks alarming the first time. `s` `g` `a` in a buffer containing `gamma` paints an `f` over the `ga`, so the line momentarily *reads* `famma` — and nothing has moved. That is flash working, waiting for the label press. A bug report filed `s` as "dead: it does not substitute and it does not jump" after stopping at step 2. So while labels are up, mnml paints a cue on the right-hand end of the pane's bottom row:

```
 ga → press a label to jump · Esc cancels
```

The cue carries the pair you typed, and it disappears the instant flash does — it never outlives the labels and claims the editor is in a mode it isn't.

The rest of the behavior:

- **Matching is case-insensitive and scoped to what's on screen** in the active pane. Flash is a navigation gesture for the current viewport, not a search — at most 60 matches get labels and the rest are silently dropped.
- **Labels come from a home-row-biased pool** (`f` `j` `d` `k` `s` `l` `a` …, lowercase before uppercase) with both characters you typed filtered out, so the third keystroke can never be mistaken for the second.
- **The cursor lands on the first character of the pair.**
- **A jump pushes the old position onto the navigation back-stack**, so `Alt+Left` (`nav.back`) returns.
- **A key that isn't a label cancels flash and is then re-dispatched normally** — you don't lose the keystroke.
- **No match on screen** ⇒ a toast (`flash: no "ab" on screen`) and the cursor stays put.
- Flash is a **vim-mode, Normal-mode** gesture. In Visual mode `s` keeps its vim meaning (change the selection), and it isn't bound in standard mode at all.

## Standard mode

A modeless VS Code-style keymap. No mode chip in the statusline (the chip shows the mode you'd be in IF you were in vim; in standard mode it's hidden). Everything you type goes in.

| Key | Action |
|---|---|
| `Ctrl-A` | Select all |
| `Ctrl-C` / `Ctrl-V` / `Ctrl-X` | Copy / paste / cut (system clipboard) |
| `Ctrl-Z` / `Ctrl-Shift-Z` | Undo / redo |
| `Ctrl-S` | Save |
| `Ctrl-/` | Toggle line comment |
| `Ctrl-D` | Add next occurrence to selection (multi-cursor) |
| `Ctrl-Alt-↑` / `Ctrl-Alt-↓` | Add cursor on line above / below (column cursors) |
| `Ctrl-Shift-L` | Select all occurrences of current word |
| `Alt-↑` / `Alt-↓` | Move current line up / down |
| `Alt-Shift-↑` / `Alt-Shift-↓` | Duplicate line up / down |
| `Ctrl-]` / `Ctrl-[` | Indent / dedent (standard mode; vim mode keeps `Ctrl-]` as tag-jump) |
| `Ctrl-L` | Select current line (standard mode) |
| `Home` / `End` | Line start / end (smart-home: first non-whitespace then column 0) |
| `Ctrl-Home` / `Ctrl-End` | File start / end |
| `Ctrl-G` | Go to line |
| `Ctrl-F` | Find in buffer |
| `Ctrl-H` | Find & replace |
| `Ctrl-Shift-F` | Workspace grep |

### Standard-mode polish

A few VS-Code-faithful behaviors worth calling out:

- **`Esc` is a no-op from the editor** — it doesn't focus the tree the way it does in vim mode. Press `Esc` reflexively to dismiss "anything" and you stay in the buffer. (Multi-cursor selections still collapse on `Esc` in both modes.)
- **`Ctrl-]` / `Ctrl-[` indent / outdent** — overrides the vim-canonical bracket-match chord for standard mode. `Tab` at line start also indents; the chord is for the explicit case.
- **`Ctrl-L` selects the current line** — the standard-mode `SelectLine` editor op. Past versions silently routed the chord to `view.redraw` (a global default) before the editor handler ever saw it; the standard-mode reservation now keeps the chord on the buffer.
- **`Cmd+…` chords parse** — on terminals that forward the macOS Command key as `KeyModifiers::SUPER` (mostly Kitty / WezTerm protocol), `cmd+shift+t` and friends now parse into the keymap. Terminals that don't forward the modifier let the spec sit inert without spewing startup warnings.

### Multi-cursor in standard mode

The Sublime / VS Code idiom:

- `Ctrl-D` — select current word, then add next occurrence on each press
- `Ctrl-K Ctrl-D` — skip current and add next (when iterating selectively)
- `Ctrl-Shift-L` — select all occurrences in buffer at once
- `Ctrl-Alt-↑` / `↓` — column cursors (one cursor per line above/below current)
- `Esc` — collapse to single cursor

All cursors apply edits in parallel — type and every cursor inserts; press `Backspace` and every cursor deletes.

## Editor essentials (shared by both modes)

These work the same regardless of input mode:

### Undo / redo

- Vim mode: `u` / `Ctrl-R` (or `:u` / `:redo`)
- Standard mode: `Ctrl-Z` / `Ctrl-Shift-Z`

Per-file undo history is persisted to `<workspace>/.mnml/undo/<file-hash>` — reopen a file tomorrow and your undo history is intact. The hash is content-based, so editing the same file externally invalidates the history (rather than producing bogus undos).

### System clipboard

- Vim mode: `"+y` / `"+p` (the `+` register) for system clipboard, `"*y` / `"*p` for the X11/Wayland primary selection.
- Standard mode: `Ctrl-C` / `Ctrl-V` / `Ctrl-X` use the system clipboard directly.

Pasting handles bracketed-paste — long pastes from another terminal don't trigger auto-indent on every line.

### Word wrap

`:set wrap` (vim) or `wrap = true` in config. Visual wrap only — the underlying file isn't modified. Wrap respects indent (continuation lines align with the original line's indent).

### Auto-indent

On (`auto_indent = true` default). Indent on `Enter` matches the previous line's indent + a level if the previous line opens a block (per language). Tree-sitter aware — Python `:` increases the indent expectation; Rust `{` does too.

### Auto-pairs

On (`auto_pairs = true` default). Typing `(` inserts `()` with the cursor between; `[`, `{`, `"`, `'`, `` ` `` likewise. Doesn't fire inside strings or comments (language-aware).

### Bracket-match highlight

Cursor on `(` / `)` / `[` / `]` / `{` / `}` lights up its match in the statusline color. Mismatches show in `error` color.

### Code folding

- Manual: `zf` create, `za` toggle, `zo` open, `zc` close, `zR` unfold-all, `zM` fold-all — see [Folding chords in NORMAL mode](#folding-chords-in-normal-mode) for the directional pair.
- LSP-suggested folds: when the LSP returns folding ranges, they show as fold markers in the gutter; click or `za` to toggle.
- Indent folds: fall-back fold strategy for languages without LSP fold support — folds at indent boundaries.

Folds **persist across buffer close and reopen**, and across mnml restarts. Every time you toggle a fold (or fire `zM` / `zR`), mnml mirrors the buffer's live fold ranges into a workspace-scoped map keyed by file path. Close the buffer with `:bd`, reopen it later with `:e` — the folds come back. Restart mnml — the folds come back too, restored from `<workspace>/.mnml/session.json`.

The map is capped at 200 files with soft-eviction (oldest entries drop when the cap is hit); files with no active folds get their entry removed so a "cleared everything" state doesn't linger and re-apply on next open. If you want to force a clean slate on a file: `zR` (unfold all) then close the buffer — the empty-fold entry gets pruned.

### `.editorconfig`

mnml reads `.editorconfig` files and applies them as per-buffer settings — `indent_style`, `indent_size`, `tab_width`, `end_of_line`, `insert_final_newline`, `trim_trailing_whitespace`. Closer-to-file wins (root `.editorconfig` is overridden by a nested one).

### Snippets with tab-stops

Configurable in `[snippets]`:

```toml
[snippets.rust]
"fn" = "fn ${1:name}(${2:args}) -> ${3:Result<()>} {\n    ${4:todo!()}\n}"
"err" = "Err(${1:anyhow!}(\"${2:message}\"))"
```

Trigger via fuzzy match in the completion popup; `Tab` cycles through stops; `Esc` exits.

### Abbreviations

```toml
[abbreviations.global]
"teh" = "the"
"wuld" = "would"
```

Fires on word boundary (space, punctuation). Vim mode has `:ab` and `:una` to manage them at runtime.

## What both modes share

Everything other than input handling. Specifically:

- LSP completion / hover / go-to-definition / etc. (configured globally per-language)
- Git operations (gutter, diff pane, commit graph)
- Pickers (fuzzy finder, command palette, buffer switcher) — though `Ctrl-P` is the default in standard, and `<space>ff` is the typical vim leader binding
- Splits, tabs, the bufferline, the file tree
- AI panes, HTTP client, browser, debugger
- Themes, statusline, devicons

Everything in this list is keymap-driven by config (`[keys.global]` for cross-mode, `[keys.vim]` / `[keys.standard]` for mode-specific). You can remap any of it.

## Next

- [Configuration](/manual/settings/) — full TOML schema
- [Keybindings](/manual/cheatsheet-all/) — every default key in both modes
- [Panes & layout](/manual/right-panel/) — how to lay out multiple buffers/diffs/terminals side-by-side
- [Language intelligence (LSP)](/manual/lsp/) — completion, navigation, refactors
