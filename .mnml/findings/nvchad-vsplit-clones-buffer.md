---
severity: SEV-2
status: deferred
---
# `:vsplit` / `:split` / `Ctrl-W s|v` open a second independent copy of the file, not a second window on the same buffer

**Command ids:** `view.split_right` (`:vs`, `ctrl+w v`), `view.split_down` (`:sp`, `ctrl+w s`).

**Reproduction**:
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"type","text":":vsplit\n"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"I"}
{"cmd":"type","text":"R "}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
**status.json**: `"panes":[{"title":"a.txt","dirty":true},{"title":"a.txt","dirty":false}]` — two `a.txt` panes, one dirty. **screen.txt**:
```
 1|│ a.txt   +                                   │ a.txt ●   +
 2|│   1 alpha bravo charlie                     │   1 R alpha bravo charlie
```
Later `:e!` in the left window reloads only the left copy; `:w` in the right window makes the left one report `hunt/a.txt changed on disk — :e! to discard / save to overwrite`.

**Expected**: vim windows are views of one buffer — an edit in either side shows in both; one dirty flag; one undo history; `:w` from either writes the same text.

**Actual**: two buffers with divergent text, separate dirty/undo state. The changed-on-disk toast stops a *silent* overwrite, but its "save to overwrite" advice is exactly how a user loses the other window's edits. Reproduced twice.

**Source pointer**: `src/app/cmd_view.zig` `split_right` / `split_down` → open the path again as a new `EditorPane` (own `Buffer`) instead of sharing the buffer.

## Deferred — a design change, not a fix (branch `vim-profile`, 2026-09-05)

**Parity check.** Rust mnml's `split_active` (`src/app/layout.rs:854`)
re-reads the file from disk into a fresh `Buffer` and toasts "the new
pane reads from disk" when the source is dirty — "v2 will support
live-linked split views". mnml-zig's `App.duplicatePane` copies the
in-memory text (dirty edits included), which is already the safer half of
that. So this is a parity-neutral NvChad gap: vim windows are views of one
buffer; both mnmls open a second buffer.

**Why not a pointer swap.** `Pane.editor` owns `Buffer`, and `Buffer` owns
`Editor`, which fuses what a window model has to keep apart:

- shared per buffer: `text`, `line_starts`, `history` (undo), `change_list`,
  `path` / `dirty` / `saved_text` (123 / 54 / 6 reads), `marks`, `folds`,
  `language`, `eol`, `read_only`, the comment tokens and tab settings;
- per view: `cursor`, `anchor`, `goal_col`, `last_selection`,
  `block_anchor`, `extra_cursors` / `extra_anchors` (multi-cursor),
  `replace_stack`, `ghost_suggestion`, plus what `EditorPane` already keeps
  per pane (`view: ViewState` scroll/pin, `find`, `wrap`, `loclist`), and
  the `InputHandler` mode (`buf.input`, 57 reads — INSERT in one window
  must not put the other in INSERT).

`Editor.apply` reads and writes `self.cursor` and the anchors while it
splices `self.text`, so every op assumes cursor and text live together.
There are 594 `buf.editor` call sites and 73 direct `buf.editor.cursor`
reads.

**What it takes.** Split `Editor` into `Document` (text, line index,
history, change list, settings) and `View` (cursor / anchor / goal /
multi-cursor / block / replace stack), with `apply(doc, view, op)`.
`Buffer` becomes the shared, refcounted document owner (`Pane.editor`
holds `*Buffer` + its own `View` + `InputHandler`); `PaneStore` drops the
last reference. Every splice must shift the *other* views' cursors and
anchors (an edit observer on `Document`, the same adjustment the undo
ring's snapshots already do for one cursor). `:w` / `:e!` / the disk
watcher / `dirty()` / `hasTwin` / `closeSplit` / `view.only` /
`buffer.close` / session save-restore all move from "pane" to "buffer"
grain; the bufferline shows one tab per view (vim) or per buffer (NvChad
bufferline) — a product decision to make first. Estimate: 3–5 days —
one day for the `Editor` split with the unit tests moved over, one for
`Buffer`/`PaneStore` ownership and the observer, one for the ~15 app
call sites that key on identity, one for the `.test` corpus (the splits
tests assert two dirty flags today), plus the bufferline decision.

**Until then.** `duplicatePane` keeps the copy in memory (no re-read from
disk) and the changed-on-disk toast blocks a silent overwrite; the
"save to overwrite" advice on that toast is the part most likely to cost a
user the other window's edits and is worth softening independently.
