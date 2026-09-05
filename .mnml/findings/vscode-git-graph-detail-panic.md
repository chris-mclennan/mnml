---
severity: SEV-1
status: fixed
---
# Git graph: `Enter` on a commit panics the process (`drawDetail` word-wrap slices past the message)

**Command id:** `git.graph` then `Enter` (`git.graph_detail`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"run-command","id":"git.graph"}
{"cmd":"wait_ms","ms":800}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```
(`down` lands on `4c78faa ex: :w !cmd pipes the buffer to the command`, whose body has 68- and 71-char lines; any commit with a body line wider than the detail panel does it.)

**screen.txt** (last frame before the crash):
```
       │ alpha.zig   git graph   +
       │ hunt · 341 commits   ·   enter detail · tab focus · d diff · s sort · / hash · c
       │  GRAPH   DATE   AUTHOR   SUBJECT
       │●            WIP @ hunt · 13 changes  [stage all] [unstage all] [commit…]
       │●            4c78faa (vim-edit) ex: :w !cmd pipes the buffer to the c…  Chris McLe
```
No `exit` event is written; the process dies. Log:
```
thread 439466125 panic: index out of bounds: index 42, len 41
src/ui/git_graph_view.zig:542:75 in drawDetail
    lines.append(ui.arena, .{ .text = std.mem.trimEnd(u8, rest[0..take], " "), … }) catch return;
src/ui/git_graph_view.zig:358:19 in draw
src/app/git.zig:2612:36 in drawGraphPane
src/app/render.zig:496:53 in drawBody
```

**Expected**: the commit detail panel opens beside the graph (VS Code / GitLens: click a commit → details).
**Actual**: mnml-zig panics and exits; unsaved buffers are gone.

**Source pointer**: `src/ui/git_graph_view.zig:534-543`. `ui.clipStr(rest, inner.w)` appends a 3-byte `…` when it clips, so `fit.len` can exceed `rest.len`; `take = fit.len` is then used to slice `rest[0..take]`. Any wrapped body line whose clipped form (chars + `…`) is longer in bytes than the remaining text overflows.

## Fix

`ef1365e` on branch `fix-git-tree` — git graph: the detail panel wraps a body line by cells, never past its bytes (`clip.fitCells` + `wrapTake`). Regression: `tests/e2e-zig/git_graph_detail_wrap.test` (panicked the runner on the unfixed tree), unit rows in `src/ui/clip.zig` and `src/ui/git_graph_view.zig`; break-checked.
