---
severity: SEV-2
status: deferred
---
# `g~~`, `gUU`, `guu` change the line correctly but leave the cursor one line *below* it

**Command ids:** vim `g~~` / `gUU` / `guu` (`src/input/vim.zig` `.toggle_case` / `.upper` / `.lower` linewise doubled form).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":"3G"}
{"cmd":"type","text":"g~~"}
{"cmd":"snapshot"}
{"cmd":"type","text":"4G"}
{"cmd":"type","text":"gUU"}
{"cmd":"snapshot"}
{"cmd":"type","text":"guu"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after 3G g~~:  3 GOLF HOTEL INDIA       "cursor":{"line":4,"col":1}
after 4G gUU:  4 JULIET KILO LIMA       "cursor":{"line":5,"col":1}
after guu:     (line 5 lowercased — it already was)  "cursor":{"line":6,"col":1}
```

**Expected**: the cursor stays on the changed line at column 1 (`:help g~~`, same as `gUU`/`guu`); `gUU` then `j.` uppercases the next line.

**Actual**: the cursor ends on the following line, so `gUUj.` skips a line and a chain like `jgUU jg~~ jguu` drifts three lines. `gUiw`, `gU$`, `g~w`, `3~` leave the cursor where vim does. Two launches (the first as a drift across a chain, the second isolated per command).

**Source pointer**: `src/input/vim.zig:1625` `.lower, .upper, .toggle_case` doubled-key branch — the linewise range is built as `line start .. next line start` and the cursor is left at the range end instead of being restored to the start.

## Deferred

Confirmed (Vim: `3G3|g~~` leaves the cursor at `3:1`), and the fix is
one line — the doubled case forms in `src/input/vim.zig`
(`handleOperatorPending`, `.lower, .upper, .toggle_case`) end with
`.move_down, .move_line_start`; replacing that with
`.move_cursor_to_selection_start` before the `.select_clear` makes
`gUUj.` reach the next line. It is parked because the Rust corpus line
`tests/e2e/vim_case_ops.test:20` (in the Phase-0 gate) asserts the
cursor-moves-down behaviour — `guu` then `gUU` is expected to uppercase
row 2 — and that file is a symlink into the Rust repo, which this
branch does not edit. Same shape as `save-cursor` parked on
`vim_replace_mode.test:26` (docs/DESIGN.md). When the Rust line is
made position-independent (`type 2G` / `type 3G` before each doubled
op, which holds under both editors), land the one-liner with the test
`tests/e2e-zig/vim_case_linewise_cursor.test` from this branch's
history (`git log --all -- tests/e2e-zig/vim_case_linewise_cursor.test`
has none — recreate: `3l g~~` expects `Ln 1/4 Col 1`, then `j gUU j .`
uppercases the next line, not the one after).
