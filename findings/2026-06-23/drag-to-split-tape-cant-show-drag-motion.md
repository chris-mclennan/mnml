---
finding: ipc-drag-synthesizes-events-atomically-no-paint-frames-between
severity: SEV-3
surface: tape-recorder for drag-to-split (recording infrastructure, not the feature itself)
---

**Repro** (while recording the drag-to-split demo via VHS + IPC):

1. Build the release binary (`cargo build --release`).
2. Stage a workspace with `src/main.rs` + `src/editor.rs`, pre-write `.mnml/.welcomed`.
3. Background a driver script that, after mnml renders, writes a single IPC `drag` command from the tree file row (e.g. `from_col=13, from_row=5`) to the right-zone target inside the editor pane (e.g. `col=140, row=20`).
4. Launch mnml under VHS (`Width 1280 / Height 760 / FontSize 13` → 151×41 cells).
5. Render the tape and extract every frame around the drag event.

**Expected**: a sequence of frames showing (a) the ghost chip following the synthesized cursor across the editor area; (b) the gray right-zone drop overlay highlighting the target half-pane; (c) on release, the editor vertical-splits and editor.rs lands in the new right pane.

**Actual**: frames N and N+1 are "before" (single pane, main.rs) and "after" (split, editor.rs in right). Zero intermediate frames showing the drag motion, the ghost chip, or the drop overlay. The feature works mechanically — the split appears in the right place — but the recording reads as a hard cut, not a drag.

**Root cause** (not a feature regression — a recording-infra limitation):

`Ipc::drain_commands` (`src/ipc/mod.rs:789`) processes every queued IPC command in a single pass per main-loop iteration. `IpcCommand::Drag { … }` (`src/ipc/mod.rs:547–600`) synthesizes the entire drag *atomically* inside one `apply()` call: one `MouseEventKind::Down`, ~N (≈97 for a 130-cell diagonal) `MouseEventKind::Drag` events along a Bresenham path, and one `MouseEventKind::Up`. All of those `dispatch_mouse` calls execute back-to-back inside the same `for c in &cmds` iteration of `drain_commands` — no `term.draw(…)` between them. So the ghost-chip + drop-overlay state updates that happen mid-drag get *immediately* overwritten by the final mouse-up state (split created, `tree_drag = None`, `tab_drop_target = None`) before ratatui ever renders a frame.

The same constraint applies to a human user when their terminal forwards a burst of mouse events faster than mnml's 40–120ms poll interval; in practice a real mouse generates events at ~120Hz with milliseconds between them and the OS interleaves draws, so the user *does* see the ghost + overlay. It's only the IPC-driven path (headless tests, file-IPC drives, VHS recordings) that collapses the drag into one frame.

**Offending file:line**: `src/ipc/mod.rs:547–600` (`IpcCommand::Drag` apply); `src/ipc/mod.rs:789–797` (`drain_commands` synchronous loop).

**Suggested fix** (if/when someone wants this recordable):

Add a `Wait`-aware drag — break `IpcCommand::Drag` into a sequence the host can drive itself:

```rust
// Either:
//   1. Expose raw mouse-event IPC commands (`mouse_down`, `mouse_move`, `mouse_up`)
//      so the host can interleave waits between them.
//   2. Add an optional `step_wait_ms` field to `Drag` and yield to the main loop
//      between synthesized events when it's set (drain_commands returns true,
//      next tick draws, then the rest of the drag fires).
```

Either path lets a VHS recording show the actual drag motion — ghost chip, overlay highlight, and all five zones lighting up as the cursor passes through them.

**Impact on the recorded demo**:

The drag-to-split tape (`site/src/assets/tapes/editor-drag-to-split.tape`) currently produces a clean before/after — single pane on the left of the timeline, split state held for ~3s on the right, instant cut between. The split is verifiably correct (editor.rs in the new right pane, main.rs untouched in the left), so the demo proves the feature LANDS correctly. It just doesn't tell the story of *how it gets there*, which is the visually interesting part of the feature.

Either: (a) ship the before/after demo and call out the drag-and-drop mechanic in the manual prose; (b) defer the recording until raw mouse IPC commands land; or (c) record manually with a screen capture tool while a human drives the mouse against a running mnml.
