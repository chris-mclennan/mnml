## [SEV-2] Tab drag-reorder uses SWAP semantics instead of INSERT

**Reproduction**:

```jsonc
// open 4 tabs into leaf 0: [deep.txt, readme.md, src.py, app.js]
{"cmd":"open","path":"sub/deep.txt"}
{"cmd":"open","path":"readme.md"}
{"cmd":"open","path":"src.py"}
{"cmd":"open","path":"app.js"}
{"cmd":"dump-rects"}
// tab rects (from rects.json): 0:x=31 1:x=47 2:x=66 3:x=80
{"cmd":"drag","from_col":55,"from_row":1,"col":90,"row":1}   // drag tab 1 (readme.md) onto tab 3 (app.js)
{"cmd":"snapshot"}
```

**Expected** (VS Code): dragging tab 1 past tab 3 removes it and reinserts at the drop target, giving:
`[deep.txt, src.py, app.js, readme.md]`

**Actual**: readme.md and app.js swap places; src.py doesn't move:
`[deep.txt, app.js, src.py, readme.md]`

Confirmed with a second drag (idx 2 → idx 0): before `[deep, app, src, readme]`, drag src (col 68) to col 32, after `[src, app, deep, readme]` — again pure swap of the source and target slots.

**Expected**: `panes` array should show INSERT semantics (drag source removed from its slot, inserted at the drop point, other tabs shift by one).

**Source pointer**: Not chased — the drag-reorder handler lives around `src/tui/mouse/*` where `bufferline_tab_page_chips` are hit-tested and tab positions swapped on drop.

**Notes**: VS Code uses insert semantics ("Move tab") — dragging tab A onto tab B slides B out of the way. Swap semantics matches nothing VS Code does; it feels like Alt-tab-drag in some file managers, not editor tabs. Frequent failure mode for a user who drags a tab to the far end of the bar expecting it to become the last tab.
