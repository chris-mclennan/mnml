---
severity: SEV-2
status: fixed
---
# `Ctrl-W o` closes other *buffers* (clean tabs in the leaf) instead of other *windows*

**Command ids:** `Ctrl-W o` in `src/input/vim.zig` `.window` → `view.close_others`.

**Reproduction** (b.zig + scratch + a.txt open, then a vertical split with the right window active):
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"type","text":":vsplit\n"}
{"cmd":"key","key":"ctrl+w o"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```
**status.json** before: `"panes":[{"title":"a.txt",…},{"title":"a.txt",…},{"title":"b.zig",…},{"title":"[scratch]",…}]`; after: `[{"title":"a.txt","dirty":true},{"title":"b.zig","dirty":true},{"title":"[scratch]","dirty":true}]` and the toast `│ kept 2 buffer(s) with unsaved changes │`. **screen.txt** still shows two side-by-side windows:
```
 1|│ [scratch] ●   b.zig ●   +                  │ a.txt ●   +
```

**Expected**: `Ctrl-W o` = `:only` — close every other split, keep the current window; buffers are untouched.

**Actual**: the split stays; the clean tabs in the *other* leaf are closed (dirty ones "kept"). Reproduced twice. `:only` / `:on` are additionally "unknown command", so there is no keyboard way to collapse splits to one except `Ctrl-W c` per window.

**Source pointer**: `src/input/vim.zig` `.window` `'o'` → `view.close_others` (tab-strip semantics) rather than a layout-level "only".

## Fix

`1479f4f` — new `view.only` (vim `:only`): closes every other leaf, keeps this window and its tabs; the other leaves' panes are re-homed as background tabs of the kept leaf (a clean duplicate of a file already shown here is dropped). `Ctrl-W o` and `:on` / `:only` both target it. Pinned by `tests/e2e-zig/vim_ctrl_w_o_only_window.test`, a `cmd_view.zig` unit test and the `Ctrl-W` table test in `vim.zig`.
