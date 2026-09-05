---
severity: SEV-2
status: open
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
