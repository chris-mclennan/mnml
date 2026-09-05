---
severity: SEV-3
status: open
---
# Find bar: `Enter` closes the bar (vim `/` semantics), so a follow-up `Shift+Enter` inserts a newline into the document

**Command id:** `find.find` (`ctrl+f`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"key","key":"ctrl+f"}
{"cmd":"type","text":"return"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
{"cmd":"key","key":"shift+enter"}
{"cmd":"snapshot"}
```
**screen.txt** after `Enter`: the `Find  return … match 1/2` bar is gone, a `match 1/2` toast shows, cursor at 4:5. After `Shift+Enter`: `Ln 5/15`, tab shows `●`, line 4 split in two (`    ` / `return 1;` — the auto-indent is also lost).

**Expected**: VS Code keeps the find widget open; `Enter` = next match, `Shift+Enter` = previous, `Esc` closes.
**Actual**: `Enter` submits-and-closes (`FindBar.handleKey` → `.submit` → `acceptFromBar` → `closeFindBar`), so the very next navigation chord edits the buffer. While the bar is open `Shift+Enter`/`F3` do work.

**Source pointer**: `src/ui/find_bar.zig:85-89` (`.enter` → `.submit` unless shift/ctrl); `src/app/cmd_find.zig:109` `acceptFromBar`. Standard profile could map plain `Enter` to `.next` and leave close to `Esc`.
