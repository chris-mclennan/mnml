---
severity: SEV-3
status: open
---
# The tree's right-click menu has no Cut / Copy / Paste / Duplicate rows, though the chords work there and the Files pane's menu has them

**Command id:** `file.cut` / `file.copy` / `file.paste` / `file.duplicate` (tree focus: `ctrl+x/c/v/d`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/bravo.txt"}
{"cmd":"run-command","id":"view.focus_tree"}
{"cmd":"key","key":"end"}
{"cmd":"click","col":12,"row":36,"button":"right"}
{"cmd":"snapshot"}
```

**screen.txt** (tree file menu, complete):
```
╭ t9.txt ────────────────╮
│    Open               │
│    Open in split      │
│────────────────────────│
│    New file…          │
│    New folder…        │
│────────────────────────│
│    Move to…           │
│    Rename…            │
│    Delete…            │
│────────────────────────│
│    Reveal in Finder   │
│    Copy path          │
│────────────────────────│
│    Refresh tree       │
╰────────────────────────╯
```
The Files pane's row menu (`files.open` → right-click a file) has `Cut / Copy / Paste here / Duplicate` between `Mark` and `Rename…`.

**Expected**: VS Code's Explorer context menu is where a mouse user finds Cut / Copy / Paste; `docs/KEYMAP_PROFILES.md` binds the chords for "tree and Files pane focus", so the tree already has the actions.
**Actual**: only the keyboard reaches them in the tree; the two menus disagree.

**Source pointer**: `src/app/context_menus.zig` — the tree file/dir menu builder (the Files pane builder in the same file has the four rows).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
