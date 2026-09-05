---
severity: SEV-1
status: fixed
---
# Workspace grep panics (`integer overflow` in `gwidth`) as soon as a hit lands on a line wider than 65535 cells — `data/nerd-glyphnames.json` in this repo does it for any common word

**Command id:** `find.grep` (`ctrl+shift+f`). Reproduced on four fresh launches, 4/4 (`foo`, `gamma` against the repo's own `data/nerd-glyphnames.json`, a 545,559-byte single line; and a synthetic 70,000-char line).

**Reproduction** (synthetic, self-contained):
```
# python3 -c "print('zzlong ' + 'y'*70000)" > vscode-scratch/longline.txt
{"cmd":"open","path":"vscode-scratch/bravo.txt"}
{"cmd":"key","key":"ctrl+shift+f"}
{"cmd":"type","text":"zzlong"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":2500}
{"cmd":"snapshot"}
```
Repo-native variant: the same with `"gamma"` or `"foo"` (both occur in `data/nerd-glyphnames.json`, `wc -L` = 545559).

**screen.txt** (last frame): the Search pane shows `SEARCH · grep: "zzlong" · 0 matches in 0 files · searching…`; no frame after the results land. `events.jsonl` ends without `exit`; the process is gone (rc 134, `Abort trap: 6`). stderr:
```
thread 441223023 panic: integer overflow
zig-pkg/vaxis-0.6.0-…/src/gwidth.zig:116:27: in gwidth
                    total += @max(0, width);
src/ui/clip.zig:46:31: in width
src/ui/clip.zig:53:14: in clipCells
src/ui/canvas.zig:79:30: in clipCells
src/ui/context.zig:109:31: in clipStr
src/ui/grep_view.zig:134:48: in paintHit
    var w = ui.putStr(x, r.y, avail, ui.clipStr(before, avail), fg);
src/ui/grep_view.zig:103:33: in draw
src/app/render.zig:577:31: in drawBody
```

**Expected**: the hit row is clipped to the pane (VS Code's search view truncates long lines with `…` and never dies).
**Actual**: `paintHit` passes the whole `before` prefix of the line to `clipStr`, which measures the entire string first; vaxis' `gwidth` sums cells into a `u16` and overflows past 65535, aborting the process — every unsaved buffer is lost. Any workspace with a minified JSON/JS file and a search term that appears in it crashes the editor on Enter.

**Source pointer**: `src/ui/grep_view.zig:134` (`clipStr(before, avail)` on the unbounded prefix); `src/ui/clip.zig:46-53` (`width` before `clipCells`); the walker in `src/app/grep.zig` also stores the full line rather than a window around the match.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(grep): a hit on a 545k-char line no longer overflows the cell sum`.

- The one choke point was `src/ui/clip.zig`'s `width`, which handed the whole
  string to vaxis' `gwidth` (a `u16` sum). It now sums per grapheme,
  saturating; `clipCells` measures through a new `fits` that stops at the
  first grapheme past the budget, so a clip costs `max_cells` of work.
- `Ui.clipStr` measures through `fitsIn` (bounded); `putStrRight` uses the
  new `widthUpTo`.
- `grep.zig` stores a window of the line around the match (`windowLine`,
  128 bytes before / 512 after, `Hit.text_off`); `grep_view.paintHit`
  paints `…` + the last ~40 cells before the match (`tailWindow`), the
  match, and the tail clipped to the row — nothing measures more than the
  row can paint.
- clipStr audit — every painter that can receive a whole file line has a
  100k-char unit test: `grep_view.paintHit`, `diagnostics_view.paintRow`,
  `todos.paintRow`, `http_panel.paintRow`, `outline_view.draw`, the
  quickfix / location list (`render.drawListPane` via `loclist`). Three of
  them (diagnostics, todos, http) summed two saturated widths past `u16`
  and now measure with `widthUpTo`. The find bar paints counts only (no
  match preview) and its chips are literals.
- `tests/e2e-zig/grep_long_line.test` crashed the runner on the unfixed
  tree (`79ecd9a`) and passes now.
