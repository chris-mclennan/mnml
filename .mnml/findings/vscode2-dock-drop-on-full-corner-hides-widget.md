---
severity: SEV-2
status: fixed
---
# Dragging a dock widget onto a corner that already stacks two widgets makes it vanish — still counted by `dock.close_all`, never painted, no hit

**Command id:** none (title-bar drag on `dock:N:title`); `dock.add_preset`, `dock.close_all`. Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"run-command","id":"dock.add_preset"}
{"cmd":"key","key":"enter"}
{"cmd":"run-command","id":"dock.add_preset"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"enter"}
{"cmd":"run-command","id":"dock.add_preset"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"enter"}
{"cmd":"type","text":"note"}
{"cmd":"key","key":"enter"}
{"cmd":"dump-rects"}
{"cmd":"drag","from_col":100,"from_row":1,"col":40,"row":30}
{"cmd":"snapshot"}
{"cmd":"dump-rects"}
{"cmd":"run-command","id":"dock.close_all"}
```
(Clock → top-right; Log tail and Text note → bottom-left, stacked at y=29 and y=20.)

**rects.json** before the drag: `dock:1:title x=98 y=1`, `dock:2:* y=29`, `dock:3:* y=20`. After the drag: only `dock:2:*` and `dock:3:*` remain — no `dock:1:*` at all. **screen.txt** shows `Note` (rows 20-21) and `Log: run.log` (rows 29-30) and no Clock anywhere; the drag target corner is where the pointer was released. `dock.close_all` then toasts `closed 3 dock widgets`.

**Expected**: the widget lands in the stack at that corner (a third slot, or the corner refuses the drop and the widget stays where it was). A drop into an empty corner works: the same drag to (60,15) parks the Clock top-left.
**Actual**: the widget is moved into the corner's stack but placed off the paintable area (no rect, no cells), so it is unreachable by mouse, cannot be moved back with its kebab, and only `dock.close_all` reveals it still exists.

**Source pointer**: the corner stacking / drop in `src/app/dock.zig` (`move`/`stackAt` for `.bottom_left` when two widgets already occupy it); painter `src/ui/dock_view.zig`.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(dock): a drop on a full corner parks the widget where there is room`.

- `dock.layout` no longer drops a widget its corner has no room for: an
  overflow pass places it in the next corner clockwise with room
  (`placeInCorner`), so nothing that some corner can hold is ever unpainted.
- `applyDrop` asks `cornerWithRoom` first: a full corner snaps the widget to
  the nearest corner with room and toasts `dock: Bottom-left is full — parked
  Top-left`; with no room anywhere the widget stays put and the toast says
  so. `dock.move_corner_next` uses the same check.
- Unit tests in `dock.zig` (layout overflow, `cornerWithRoom`, the drop);
  `tests/e2e-zig/dock_drop_full_corner.test` is the finding's repro.
