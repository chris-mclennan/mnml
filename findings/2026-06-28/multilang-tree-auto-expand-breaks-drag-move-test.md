---
agent: multilang-dev-user
severity: SEV-2
language: ts
repro: e2e
---

# tree.refresh auto-expand broke mouse_tree_file_move.test

## What failed

`mouse_tree_file_move.test` fails in the full e2e suite with:

```
mouse_tree_file_move.test — line 12: screen does not contain "Move to"
```

## Root cause

The `ac96648` commit introduced auto-expand of all depth-0 directories on `tree.refresh()`. The `mouse_tree_file_move.test` creates a `sub/cc.txt` fixture and then calls `command tree.refresh`. After the fix, `sub/` is auto-expanded, inserting `cc.txt` as a visible row between `sub/` and `aa.txt`.

Before fix — visible tree rows (y-coords):
```
y=1: (workspace header)
y=2: sub/  (collapsed)
y=3: aa.txt
```

After fix — visible tree rows (y-coords):
```
y=1: (workspace header)
y=2: sub/  (auto-expanded)
y=3: cc.txt  ← new row; aa.txt shifted down
y=4: aa.txt
```

The test uses `drag 7 3 7 2` (drag from y=3 to y=2) which now drags `cc.txt` onto `sub/` (its own parent), not `aa.txt` onto `sub/`. The move prompt does not fire for that operation.

## Fix

Update the drag coordinates in `mouse_tree_file_move.test` to account for the expanded sub-directory:

```diff
- drag 7 3 7 2
+ drag 7 4 7 2
```

And update the comment:
```diff
- # Rail: row 1 = workspace header, row 2 = sub/ (folder), row 3 = aa.txt.
+ # Rail: row 1 = workspace header, row 2 = sub/ (folder, auto-expanded),
+ # row 3 = cc.txt (child of sub/), row 4 = aa.txt.
```

## Evidence

Full e2e suite run output:
```
1 of 173 .test file(s) failed:
  mouse_tree_file_move.test — line 12: screen does not contain "Move to"
```
