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
| **Insert** | `i` / `a` / `o` / `O` / `s` / `c…` | Typing text |
| **Visual (char)** | `v` | Char-by-char selection |
| **Visual (line)** | `V` | Line selection |
| **Visual block** | `Ctrl-V` | Column / block selection (multi-cursor flavor) |
| **Replace** | `R` | Overwrite-as-you-type |

The mode chip in the bottom-left of the statusline shows which mode you're in; the cursor shape changes per-mode too (block in Normal, bar in Insert, underline in Replace). The chip distinguishes the three visual flavors — `VISUAL` for char-wise, `V-LINE` for `V`, `V-BLOCK` for `Ctrl-V` — so the geometry is visible at a glance instead of collapsing into one label. The mode-chip tooltip differentiates them too.

### Motion + visual-entry semantics

A handful of motions and visual-entry chords match vim's behavior precisely — worth knowing the edge cases:

- **`$` lands on the last printable char** of the line, not one cell past it. In Normal mode the block cursor sits on the last visible character; a paste lands immediately after it (rather than one column further right). Empty lines collapse to the line start.
- **`G` (bare) lands on the start of the last line.** Past versions could overshoot onto the phantom row after a trailing newline; the cursor now anchors at `line_start(last_line)` cleanly.
- **`V` (visual-line) leaves the cursor where it was.** The anchor moves to `line_start`; the cursor doesn't snap down a row. The full line still reads as selected, and `'<` / `'>` marks reflect the cursor's row after a yank.
- **`*` advances past the current match.** The star chord now genuinely jumps to the *next* occurrence of the word under the cursor (rather than the first match at-or-after, which was the cursor's current word). `#` is the same in the reverse direction.
- **`<N>@<r>` honors the count.** `5@a` replays macro `a` five times. Past versions silently dropped the count and ran the macro once; the count threads through to the App dispatcher's replay loop.

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
:qa!                        " force-quit all
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

Plus flash-motion jumps — `s<char><char>` jumps to the nearest `<char><char>` digraph in view with a single-letter label. Bypasses the `f` / `t` / `/` / `?` chain when you can see the target.

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

- Manual: `zf` / `za` / `zo` / `zc` / `zR` / `zM` (vim-style)
- LSP-suggested folds: when the LSP returns folding ranges, they show as fold markers in the gutter; click or `za` to toggle.
- Indent folds: fall-back fold strategy for languages without LSP fold support — folds at indent boundaries.

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

- [Configuration](/reference/configuration/) — full TOML schema
- [Keybindings](/reference/keybindings/) — every default key in both modes
- [Panes & layout](/manual/panes/) — how to lay out multiple buffers/diffs/terminals side-by-side
- [Language intelligence (LSP)](/manual/lsp/) — completion, navigation, refactors
