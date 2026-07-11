## [SEV-2] Ctrl+D adds second cursor at wrong byte offset (extra_cursors not rebased after selection delete)

**Reproduction** (clean workspace, `src.py`):

```jsonc
{"cmd":"open","path":"src.py"}       // file is the standard 9-line Python sample
{"cmd":"key","key":"ctrl+home"}
{"cmd":"key","key":"end"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}            // cursor now inside "name" on line 1 col 12
{"cmd":"key","key":"ctrl+d"}          // 1st press: selects "name" (Sel 4)
{"cmd":"key","key":"ctrl+d"}          // 2nd press: should add cursor at "name" on line 2
{"cmd":"type","text":"XX"}
{"cmd":"snapshot"}
```

**Expected** (VS Code): Both occurrences of `name` become `XX`:

```
1 def greet(XX):
2     return f"Hello, {XX}"
```

**Actual**: Line 1 is edited correctly; line 2 is untouched and `XX` is inserted at the START of line 4 instead:

```
1 def greet(XX):
2     return f"Hello, {name}"
3
4 XXdef main():
```

**Source pointer**: `src/editor/mod.rs:2650` `InsertChar` calls `self.delete_selection_if_any(out)` at 2651. `delete_selection_if_any` (`mod.rs:3968`) does `self.text.replace_range(lo..hi, "")` and updates `self.cursor` + `self.anchor` but never rebases `self.extra_cursors` or `self.extra_anchors`. So the extra cursor from `AddCursorAtNextWord` (`mod.rs:2576`), placed at the byte position of the "next `name`", stays at its original offset — after 4 bytes vanish from `[10,14)` the offset now lands at the wrong location (start of `def main():` in this repro).

**Notes**: Sibling of SEV-1 (`is_char_boundary` panic) — same root cause, different failure mode. `Alt+click` multi-cursor works correctly when no selection deletion happens, so users hitting alt-click will feel fine; users on VS Code's Ctrl+D reflex will feel it hard because the second cursor visibly places text in the wrong file location. See VS Code's [`editor.action.addSelectionToNextFindMatch`](https://code.visualstudio.com/docs/editor/codebasics#_multiple-selections-multicursor) for the expected semantic.
