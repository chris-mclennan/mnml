---
severity: SEV-2
status: fixed
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

## Fix — the shared-buffer window model (branch `split-buffers`, 2026-09-05)

`Editor` was split along the line the deferral drew. `Document`
(`src/editor/document.zig`) owns what belongs to the text: the bytes, the
line index, the edit log, the undo history, the change list, the path,
`dirty` / `saved_text`, marks, the language and its comment tokens, the
save settings (`eol`, trailing newline, trim), the disk stamp and the
language server's sync point. `Editor` is now one window's view of a
document — a heap box holding `doc: *Document` plus the cursor, anchor,
goal column, `last_selection`, block anchor, the extra cursors, the
replace stack, the ghost text and the folds. `Buffer` is a window: its
`*Editor`, the `InputHandler`, dot-repeat and the macro recording;
`Buffer.initOn(doc)` is the split's constructor.

Documents are refcounted by their views. The app's `DocStore`
(`src/app/doc_store.zig`, a heap box on `App.docs`) adopts each
document as it is opened and keeps the per-document syntax state (the
tree-sitter tree and spans) beside it, so a reparse runs once per
document; the last view's release calls back and drops both.
`App.duplicatePane` (`:vsplit` / `:split` / `Ctrl-W v` / `Ctrl-W s`)
makes a second `Buffer` on the same document, starting at the source's
cursor, scroll and folds.

Every `Document.spliceBy` tells the other views (`Editor.onForeignSplice`):
cursor, anchor, block anchor, `last_selection`, extra cursors and folds
shift by the byte delta (a position inside the replaced range lands on
its start), and the row delta is queued for the pane's scroll offset,
which the frame applies. A wholesale replacement (undo, `:e!`) clamps
the other views. Undo and redo are the document's; the applying view's
cursor follows the snapshot.

Identity moved from pane to document: `dirty()`, `hasTwin`
(`Document.hasOtherView`), `closeSplit`, `view.only`, the watcher's
stamp and reload (the other windows keep their row), `:w` /
`file.save_all`, the LSP `didChange` sync point (`Document.lsp_seen`
— two windows send an edit once), the highlight dirty flag (on the
shared `Syntax`), the bufferline (a second window on a document folds
into its tab) and the session (a file saved from two windows comes
back as two windows on one document). `:q` / `Ctrl-W c` close the
window and keep the buffer while another window shows it; `:bd`
(`App.closeDocument`) closes every window, the last through the
unsaved-changes box.

Tests: `tests/e2e-zig/vsplit_shared_buffer.test` is this report's
reproduction (fails on the previous code at "screen unexpectedly
contains `1 alpha bravo charlie`", passes now), with
`vsplit_quit_keeps_buffer.test` and `vsplit_bd_closes_both.test`
beside it; the unit tests live in `document.zig`, `editor.zig` and
`doc_store.zig`.
