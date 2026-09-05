---
severity: SEV-2
status: open
---
# `Ctrl+Shift+D` with the tree focused duplicates the selected file/folder on disk (shift is ignored; `ctrl+shift+c/x/v` misfire the same way)

**Command id:** `file.duplicate` fires; `view.activity_debug` (the documented `ctrl+shift+d`) never runs. Reproduced 3/3 across two launches (`echo.txt` → `echo-copy.txt`, `data/` → `data-copy/`, `bravo.txt` → `bravo-copy.txt`).

**Reproduction**:
```
{"cmd":"run-command","id":"view.focus_tree"}
{"cmd":"key","key":"end"}
{"cmd":"key","key":"up"}
{"cmd":"key","key":"ctrl+shift+d"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```
**screen.txt**:
```
│ duplicating vscode-scratch/bravo.txt → bravo-copy.txt │
```
`ls vscode-scratch` → `bravo-copy.txt` exists. With the tree cursor on a directory (`data`) the whole directory is copied. With pane focus the same chord toasts `view.activity_debug: not implemented yet` instead.

**Expected**: `ctrl+shift+d` = Activity: Debug (`docs/commands.md:122`, `docs/KEYMAP_PROFILES.md` lists it as a VS Code chord); a modifier-mismatched chord must never mutate the file system. Likewise `ctrl+shift+c` / `ctrl+shift+v` (VS Code: open terminal / paste) should not cut/copy/paste files.
**Actual**: the tree's clipboard shortcut table matches on `ctrl` + the char and ignores `shift`, so `ctrl+shift+{x,c,v,d}` become `file.cut/copy/paste/duplicate` — silently, since the toast is small and the user asked for a different view.

**Source pointer**: `src/app/tree.zig:313-324` (`if (k.mods.ctrl and !k.mods.alt and !k.mods.super and k.code == .char)` — no `!k.mods.shift`). Secondary: `view.activity_debug` is bound (`src/commands/specs.zig`) but has no runner, so even with pane focus the chord only toasts.
