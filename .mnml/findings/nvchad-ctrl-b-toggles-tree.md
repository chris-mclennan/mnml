---
severity: SEV-2
status: open
---
# `Ctrl-B` toggles the file tree instead of paging back (vim profile)

**Command id:** `view.toggle_tree` — `docs/commands.md` line 231 lists `ctrl+b` in the **vim** column as well as standard.

**Reproduction**:
```
{"cmd":"open","path":"hunt/long.zig"}
{"cmd":"key","key":"ctrl+f"}
{"cmd":"key","key":"ctrl+f"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+b"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+b"}
{"cmd":"snapshot"}
```
**status.json**: cursor `{"line":73,"col":1}` before and after both `ctrl+b`; `treeVisible` flips `true → false → true`. screen.txt top line stays `38     var s: i32 = 0;` (no scroll).

**Expected**: `Ctrl-B` scrolls one page backward (pair of `Ctrl-F`, which does work).

**Actual**: the sidebar toggles; the view does not move. Reproduced from two fresh launches.

**Source pointer**: `docs/KEYMAP_PROFILES.md` rule 1 reserves `ctrl+w g d u e y r n h j t f` for vim — `ctrl+b` is missing from that list, so the `both` default survives into the vim profile. `src/commands/specs.zig` `view.toggle_tree` keys.
