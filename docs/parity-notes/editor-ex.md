# Parity note — the EDITOR / EX tier (`editor-ex`)

The `docs/PARITY.md` rows this branch flips, the file that proves each,
and every `// changed:` the branch introduces. The ledger itself is
edited at merge, not here. The branch folds five tracks — system
clipboard, flash labels, `Ctrl-W` moves + location lists, global marks
+ persisted macros, `.editorconfig` — around the ex-verb work.

## Rows

### Editing & input

| row | was | now | proving file |
|---|---|---|---|
| Macros — named | partial ("not persisted across launches") | **done** | `src/app/macros_store.zig` (`<data root>/macros.zon`, written when `q` ends a recording and on `exit`, read on `startup`; two tests), `src/editor/clipboard.zig` (`putMacro` / `macro` / `last_macro` — registers live on the clipboard so `@a` replays in any buffer; test `macro registers are shared through the clipboard`), `buffer.zig` `formatKeys` / `keysToSpec` round-trip test |
| Global (uppercase) marks | missing | **done** | `src/app/marks_store.zig` (`mA`–`mZ` on the App, `<data root>/marks.zon`, `'A` / `` `A `` open the file, `:marks` / `:delmarks A`, `'A` as an ex address, `picker.marks` lists them; one long test), `src/editor/buffer.zig` (uppercase marks bubble up as `.app`), `src/app/dispatch.zig` `handleAppCommand` |
| Flash-motion `s` + two chars | partial ("no labels, no armed overlay") | **done** | `src/app/flash.zig` (state, `start`, `interceptKey`, eleven tests), `src/app/dispatch.zig` (`flash.interceptKey` first on the editor key path), `src/app/render.zig` (`Doc.labels`, `drawFlashCue`), `src/ui/editor_view.zig` (`Doc.labels`), `tests/e2e-zig/vim_flash_labels.test` |
| Ex `:%s/old/new/flags` | partial ("`g` / `i` only; no `c`, no `n`, no `:&`") | **done** | `src/app/ex_verbs.zig` `substituteEntry` / `substituteConfirm` (the `c` prompt: y / n / a / q / l, Esc keeps what was done), `substituteCount` (`n`), `ampersand` (`:&`, `:&&`, a bare `:s [flags]`, an empty pattern reuses the last); tests `:s///c asks per match…` and `:& repeats…`; `tests/e2e-zig/ex_substitute_confirm.test` |
| Ex `:g/` / `:v/` | missing | **done** | `ex_verbs.global` — targets are line-start bytes remapped through the editor's edit log after every command, so `:g/x/d` and `:g/x/norm o` visit exactly the lines that matched; `:g!` = `:v`; `p` prints to `:messages`; E147 on a nested `:g`, E486 on no match; tests `:g runs a command…`, `:g refuses to nest…`; `tests/e2e-zig/ex_global.test` |
| Ex `:norm` | missing | **done** | `ex_verbs.normal` — keys through the active handler per line with an Esc after each; `<esc>` / `<lt>` / `<c-x>` notation; `ex_depth` bounds `:g` → `:command` → `:norm` → `:`; test `:norm types keys per line…`; `tests/e2e-zig/ex_norm.test` |
| Ex `:!cmd`, `:r`, `:r !cmd`, `:<` / `:>` | missing | **done** | `ex_verbs.shell` (`:!` to a reused scratch pane, `:!!` repeats, `:[range]!` filters), `read` (`:r file`, `:r !cmd`, E484), `shift` (`:>>`, a count, blank lines skipped, one undo step); tests `:! shows output…`, `:> and :< shift…`; `tests/e2e-zig/ex_shell_read_shift.test` |
| User-defined `:command`s | missing | **done** | `ex_verbs.defineCommand` / `deleteCommand` / `runUserCommand` (`<args>` `<q-args>` `<bang>` `<line1>` `<line2>` `<range>`, E174 / E182 / E183 / E184, `<data root>/commands.zon`, Tab completion on the `:` line outranks the registry); test `:command defines, expands…` |
| System clipboard | missing | **done** | `src/core/clipboard_os.zig` (`Sink`, `select`, `probe`, `writeOsc52`, the tool pair), `src/editor/clipboard.zig` (`attach`, `isOsRegister`, the push / read), `src/input/standard.zig` (Ctrl+C / X / V carry the `"+` hint), `src/tui/loop.zig` (the attach), `Config.Editor.clipboard` |
| Registers — named, numbered ring, `0`, blackhole | done | done | note gains: `"+` / `"*` are the OS clipboard; a write lands in the unnamed register and the sink, a read asks the sink first and falls back (OSC 52 cannot read) |
| `.editorconfig` | missing | **done** | `src/editor/editorconfig.zig` (the walk, the parser, the glob, four tests), `src/editor/buffer.zig` `applyEditorconfig` / `save` (test `editorconfig on a buffer…`), `App.applyBufferPrefs` (test `editorconfig reaches an opened buffer…`), `tests/e2e-zig/editorconfig.test` |
| Trailing-whitespace tools | done | done | note gains: `editor.trim_trailing_ws_on_save` and `editor.ensure_trailing_newline` are **read now** — before this branch only the settings row and the LSP format request looked at them; `Buffer.save` honours both, seeded by `App.applyBufferPrefs` |

Totals for Editing & input: done 38 → 48, partial 3 → 0, missing 8 → 1
(the jumplist).

### Panes, splits & tab pages

| row | was | now | proving file |
|---|---|---|---|
| `Ctrl-W` move `H J K L` | missing | **done** | `src/app/layout.zig` `moveToEdge` (test `moveToEdge makes…`), `src/app/cmd_view.zig` `view.move_split_left/right/up/down`, `src/input/vim.zig` `.window` prong, `tests/e2e-zig/ctrl_w_move.test` |
| `Ctrl-W =` equalize | partial ("not bound in the `Ctrl-W` switch") | **done** | `src/input/vim.zig` `.window` binds `=`; `toggle_auto_equalize_splits` is still unread — note it |
| `Ctrl-W` resize `+ - < >`, `_` / `\|` maximize | done | done | note drops "the vim.zig chord table does not bind them yet" — it binds them, plus `r`, `n`, `d`, `f` |

Totals for Panes: done 16 → 18, partial 1 → 0, missing 2 → 1 (MRU).

### Navigation & search

| row | was | now | proving file |
|---|---|---|---|
| Location lists | missing | **done** | `src/app/loclist.zig` (`:lexpr` / `:lopen` / `:lwindow` / `:lclose` / `:lnext` / `:lprev` / `:lfirst` / `:llast`, per `EditorPane`, seeded from LSP diagnostics when empty; three tests), `src/app/pane.zig` (`EditorPane.loclist` / `loc_idx`, `ListPane.Kind.location`), `tests/e2e-zig/loclist.test` |

Totals for Navigation & search: done 18 → 19, missing 9 → 8.

### Remaining list

Drop rows 16–21 of the Remaining table (`Ctrl-W` move, system clipboard,
`:g` / `:v` / `:norm`, flash labels, `:command` / `:!` / `:r` / `:<` /
`:>` / `:&` / `:s///c`, global marks + macros + `.editorconfig` +
location lists). Every one landed.

## Behaviour, in one place

### Clipboard

- `editor.clipboard = .auto` (default): OSC 52 when the terminal loop is
  running, else the first clipboard tool on `$PATH`, else in-process.
  `.os`: the tool first (it can read back), then OSC 52. `.internal`:
  never touches the OS. `:set clipboard=os`, `:set clipboard?` and the
  settings row reach it; a change applies without a restart.
- Tools by platform: macOS `pbcopy` / `pbpaste`; Linux `wl-copy` /
  `wl-paste --no-newline` under `WAYLAND_DISPLAY`, else `xclip
  -selection clipboard [-o]`, else `xsel --clipboard --input|--output`;
  Windows `clip.exe` / `powershell -NoProfile -Command Get-Clipboard`.
- `"+` and `"*` are one sink. A yank or delete through either writes
  the unnamed register first, then pushes — a failed push never loses
  the yank. A `"+p` with a tool sink pastes what the OS holds, linewise
  when it ends in a newline; with OSC 52 or no sink the read falls back
  to the unnamed register.
- Standard profile: Ctrl+C / Ctrl+X / Ctrl+V open their op lists with
  the `"+` hint. Middle click in the editor reads `"*`.
- Headless, `.test` and unit tests: the sink is `.none`; `probe` only
  stats `$PATH`.

### Flash labels

- `s` + two chars in vim Normal; `S` stays substitute-line, as in the
  Rust. The label alphabet is the Rust's, minus the pair's two chars.
- Matching is ASCII-case-insensitive, overlapping, bounded to the rows
  the last frame showed. While armed a label jumps and is consumed, Esc
  disarms and is consumed, any other key disarms and falls through.
- The cue `ab → press a label to jump · Esc cancels` sits on the pane's
  last row in the label style.

### Ex verbs

- `:g` / `:v` collect the matching lines first, then run the command
  with the cursor on each; the remaining targets are byte offsets mapped
  through `Editor.edits` after every run (a target swallowed by an edit
  is skipped; a wholesale replacement stops the loop with a toast).
  Plain substring matching, smart-case unless `app.search_case` says
  otherwise — `TODO(regex)` where the search track's engine plugs in.
- `:norm` types through `App.handle`, so which-key, abbreviations and
  the `:` line all behave as they would live; an overlay opening stops
  the loop.
- `:command Name rhs` persists to `<data root>/commands.zon` on every
  define / delete; the `startup` hook reads it back. Names must start
  uppercase; `!` replaces. A typed range with no placeholder in the
  definition is put in front of the expansion.
- `:!cmd` runs `/bin/sh -c` (`cmd.exe /C` on Windows) in the workspace
  with stderr merged, into a `[scratch]` pane reused across runs;
  `:[range]!cmd` replaces the lines with the command's stdout; `:r !cmd`
  inserts it below the line. `:!!` and `:r !!` repeat the last command.
- `:s///c` selects each match and asks through the confirm overlay
  (`y n a q l`); Esc keeps what was replaced. Matches are byte ranges in
  the original text with a running delta, so a longer replacement never
  shifts a later match off. `c` is never remembered for `:&&`.
- `:s///n` counts (all matches with `g`, one per line without) and
  changes nothing.

### Marks, macros, `.editorconfig`, location lists, `Ctrl-W`

- `mA`–`mZ` name `(file, row, col)` on the App; `'A` / `` `A `` open
  the file when it is not, activate it and place the cursor. Stored in
  `<data root>/marks.zon` on every set / delete and on `exit`; a mark
  whose file is gone is dropped on load. A scratch buffer refuses one.
- Macro registers live on the `Clipboard` (a recording in one buffer
  replays in another) and persist as key-spec text in
  `<data root>/macros.zon` the moment a recording stops.
- `.editorconfig` is resolved on every open (`App.applyBufferPrefs`),
  after the config's `trim_trailing_ws_on_save` /
  `ensure_trailing_newline` seed the buffer. `indent_style` reaches Tab
  in insert mode, `>>` and the indent op; `indent_size` / `tab_width`
  the handler's unit and the editor's display width; `end_of_line` what
  a save writes (a CRLF / CR file is normalised to LF in memory and
  written back as it came); `trim_trailing_whitespace` is one undoable
  edit at save with the cursor kept.
- Location lists are per `EditorPane` (`loclist`, `loc_idx`) and show in
  the `.location` list pane; `:lopen` on an empty list seeds it from the
  file's LSP diagnostics. E553 off either end, E776 with none.
- `Ctrl-W H/J/K/L` detach the focused pane's leaf and re-hang it as one
  half of a new root split, spanning the full edge; every allocation
  happens before the first mutation.

## `// changed:` notes

1. **`Config.Editor.clipboard: Clipboard = .auto`** (`src/config/Config.zig`).
   The Rust build always went through arboard — the unnamed register
   *was* the OS clipboard, tests included. mnml-zig routes only `"+` /
   `"*` (and the standard chords) to the OS, behind a three-way switch,
   so a headless or `.test` run never reaches a clipboard.
2. **Standard profile emits the `"+` hint** (`src/input/standard.zig`).
   Rust's standard profile relied on the unnamed register being the OS
   clipboard. The hint is what makes the chords system-wide; under
   `.internal` it routes to the unnamed register.
3. **The loop seam** (`src/tui/loop.zig`): one line after `App.initWith`
   attaches the session's buffered writer and the probed tool. Rust
   had none.
4. **Vim's `"+p` read is linewise on a trailing newline** — vim's own
   rule; Rust returned OS text charwise always.
5. **Flash labels are nearest-to-cursor first** (Rust: file order); a
   single match jumps at once; the pair under the cursor is not a
   target; no jump-list push (there is no jump list yet); `Doc.labels`
   is a view prop, not an overlay walking pane rects; the armed state
   pins the edit-log head and drops itself on a pane change or an edit.
6. **`:norm` needs `<esc>` notation** — vim types a raw Esc; the `:`
   line cannot carry one.
7. **`:g` line stability is byte-offset remapping through the edit
   log**, not vim's mark-per-line scheme; a command that replaces the
   text wholesale (`setText`) stops the loop instead of guessing.
8. **`:command` definitions persist per data root** (`commands.zon`);
   Rust kept them in the session file. `-nargs` and friends are accepted
   and ignored — every user command takes any args, a bang and a range.
9. **`:!` output goes to a reused scratch pane**, not a modal; the exit
   code is the toast.
10. **Macro registers moved from `Buffer` to `Clipboard`** — D4 placed
    them on the buffer, which made them per-file. `docs/DESIGN.md` D4
    and `docs/CONVENTIONS.md` carry the paragraph.
11. **Global marks persist under the data root**, not the per-workspace
    session file Rust used: `'A` should reach the same place from any
    workspace.
12. **`.editorconfig` honours `indent_style` and `end_of_line`** and a
    slash-in-the-middle glob (`src/**/*.zig`), none of which the Rust
    reader did; `input.Config.use_tabs`, `Editor.use_tabs`,
    `Buffer.eol` / `indent_unit` / `trim_trailing_ws_on_save` are the
    new state. `Buffer.load` normalises CRLF / CR to LF and remembers
    (Rust was LF-only and left the `\r`s in the text). A handler rebuilt
    by `editor.use_vim` keeps the file's indent (`Buffer.setInputStyle`).
13. **The config's `trim_trailing_ws_on_save` / `ensure_trailing_newline`
    are read** — they were dead fields.
14. **Location lists are a third `ListPane.Kind`** sharing the quickfix
    row layout; `:lnext` from the list pane acts on the last-focused
    editor's list.
15. **`Ctrl-W` binds `= r _ | + - > < n d f` too** — the Rust `.window`
    prong and the spec table agree they exist; the Zig prong had
    swallowed them.
16. **`tools/break-check.sh` with a filter starting with `:`** (as in
    `":g runs…"`) matches no test and reports "still passes" — use a
    substring without the leading colon. Not fixed here (the tool is
    outside this branch's file list); noted so nobody trusts that output.

## Tests

Unit tests 748 → 765 on the branch's original base; 807 in the main
test binary after the rebase onto the `panels` merge (Debug and
ReleaseSafe). Gate 47/47, and 141/141 swept at 80x24 / 120x40 / 200x60.
Corpus 247/248 after the rebase (239/240 before it; the one failure is
the TOML assertion, by design). `zig build gate-build
-Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe` builds.

New `.test` files (all zig-only): `ex_global`, `ex_norm`,
`ex_shell_read_shift`, `ex_substitute_confirm`, `vim_flash_labels`,
`ctrl_w_move`, `loclist`, `editorconfig`.

Break-checks on this branch (each `OK — with the break, N pass, 1 fail`):

- `"editorconfig on a buffer"` `src/editor/buffer.zig`
  `s/self\.input\.configure(\.{ \.tab_width = self\.indent_unit, …/…tab_width = 99…/`
  — the handler-rebuild fix.
- `"every matching line"` `src/app/ex_verbs.zig`
  `s/t\.\* = b + sp\.new_end - sp\.old_end;/t.* = b;/` — the `:g` remap.
- The sub-track commits carry their own (layout `moveToEdge`, the vim
  `.window` prong, the macro register, the key-spec round-trip, the
  flash jump column and tie-break, the clipboard chain).
