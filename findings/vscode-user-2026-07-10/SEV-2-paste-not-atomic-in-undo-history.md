## [SEV-2] Paste is not atomic in the undo history — one Ctrl+Z reverts only the insert half, leaving the delete of the replaced selection in place

**Reproduction**:

```jsonc
{"cmd":"open","path":"src.py"}
{"cmd":"key","key":"ctrl+home"}
{"cmd":"key","key":"ctrl+a"}         // select all
{"cmd":"key","key":"ctrl+c"}         // copy 158B
{"cmd":"key","key":"ctrl+end"}       // (selection NOT cleared — see the sibling Ctrl+End SEV-3)
{"cmd":"key","key":"ctrl+v"}         // paste replaces selection
{"cmd":"key","key":"ctrl+z"}         // ← one undo
{"cmd":"snapshot"}
```

Status after `ctrl+v`: `Ln 10/10 Col 1  158B → 159B` (paste executed as one op).

Status after **one** `ctrl+z`: file is now **1 byte** (empty buffer with trailing newline). Buffer is not restored to pre-paste content.

Only a **second** `ctrl+z` brings the file back to the 158B pre-paste state.

**Expected** (VS Code): A single Ctrl+Z reverts the entire paste — text goes back to what it was BEFORE Ctrl+V fired.

**Actual**: The paste is split into (a) delete-selection and (b) insert-clipboard, each as its own undo step. The first Ctrl+Z rewinds only (b) — leaving the buffer empty because the selection deletion happened first. A second Ctrl+Z rewinds (a).

**Source pointer**: Likely `Editor::apply` for the paste `EditOp` in `src/editor/mod.rs` — the paste path presumably calls `delete_selection_if_any` (which pushes its own undo checkpoint at `mod.rs:3971 self.checkpoint()`) then inserts the clipboard string as a separate checkpoint. The two should be grouped.

**Notes**: Any VS Code user who paste-replaces text and expects Ctrl+Z to restore the selection they overwrote will be surprised. The intermediate "empty buffer" state on the undo path is nasty — it can look like the file was wiped, tempting the user to close-without-save and lose the original state.
