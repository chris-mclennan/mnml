---
severity: SEV-3
status: open
---
# Tree `F2` rename: `Esc` closes the prompt but leaves focus on the editor pane, so the next arrow keys edit instead of moving in the tree

**Command id:** `file.rename` (F2 with tree focus — the fix for `vscode-f2-in-tree-is-lsp-rename`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/bravo.txt"}
{"cmd":"run-command","id":"view.focus_tree"}
{"cmd":"key","key":"end"}
{"cmd":"key","key":"f2"}
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
{"cmd":"key","key":"up"}
{"cmd":"snapshot"}
```

**status.json** after `f2`: `"focus":"pane"` (the prompt); after `escape`: still `"focus":"pane"`, `treeSelection` unchanged; `up` then moves the editor cursor (`Ln 1/3` stays because it was already line 1) and the tree cursor does not move.

**Expected**: VS Code returns focus to the Explorer row after cancelling a rename; the tree opened the prompt, the tree should get focus back (the prompt's accept path has the same gap: after a rename the tree is not focused either).
**Actual**: the prompt overlay restores `focus = .pane` unconditionally.

**Source pointer**: `src/app/dispatch.zig:585` `restoreFocus` / the prompt close in `src/app/tree.zig` `handleKey` `.f2` branch (opens with `app.focus = .overlay`, no `prev_focus`).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
