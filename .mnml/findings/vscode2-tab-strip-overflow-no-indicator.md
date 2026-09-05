---
severity: SEV-3
status: open
---
# Tab strip overflow: with 15 tabs the hidden tabs have no `‹ ›` / `…` indicator, the wheel does not scroll the strip, and the `+` button and breadcrumb disappear

**Command id:** none (tab strip); `ctrl+tab` re-windows it. Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"open","path":"vscode-scratch/t1.txt"}
… (t2 … t14 the same) …
{"cmd":"open","path":"vscode-scratch/t15.txt"}
{"cmd":"snapshot"}
{"cmd":"dump-rects"}
{"cmd":"scroll","col":60,"row":1,"dy":3}
{"cmd":"snapshot"}
```

**screen.txt** row 1:
```
│ t7.txt   t8.txt   t9.txt   t10.txt   t11.txt   t12.txt   t13.txt   t14.txt   t15.txt
```
`rects.json` lists `tab:0:7 … tab:0:15` only — `alpha.zig`, `t1`–`t6` have no hit, `button:256` (the `+`) is gone, and the `vscode-scratch › t15.txt` breadcrumb is not painted. The wheel over the strip changes nothing; `ctrl+tab` shows `t6 … t14   +` (the window follows the active tab).

**Expected**: an overflow affordance — VS Code scrolls the strip on wheel and shows the hidden count; the brief's `‹ ›` question. Rust mnml draws `‹`/`›` when tabs are clipped.
**Actual**: hidden tabs are unreachable by mouse and there is no sign they exist.

**Source pointer**: `src/ui/bufferline.zig:117` `drawTabs` (windowing without edge markers or a wheel handler).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
