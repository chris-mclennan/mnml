---
severity: SEV-2
status: fixed
---
# `{count}gt` ignores the count and just goes to the next tab page

**Command ids:** `tab.next` (`g t`), `tab.prev` (`g T`).

**Reproduction** (three tab pages):
```
{"cmd":"type","text":":tabnew\n"}
{"cmd":"type","text":":tabnew\n"}
{"cmd":"key","key":"1 g t"}
{"cmd":"snapshot"}
{"cmd":"key","key":"3 g t"}
{"cmd":"snapshot"}
{"cmd":"key","key":"2 g t"}
{"cmd":"snapshot"}
```
**screen.txt** toasts, in order: `│ tab 1/3 │` → `│ tab 2/3 │` → `│ tab 3/3 │`. (`1gt` from tab 3 happened to land on tab 1 because next-with-wrap did.) In a two-tab session `2gt` from tab 2 landed on tab 1.

**Expected**: `{count}gt` goes to tab page number `count` (Vim `:help gt`): `3gt` → tab 3, `2gt` → tab 2.

**Actual**: the count is dropped; every `Ngt` is a plain `gt`. Reproduced in two launches. `gt`/`gT` without a count and `:tabs`/`:tabonly`/`:tabclose` are correct.

**Source pointer**: `src/input/vim.zig` `g t` emits `tab.next` without passing the pending count; `src/app/cmd_tab.zig` has `switchTab(idx)` that could take it.

## Fix

`4dc6f23` — `{count}gt` / `{count}gT` emit `AppCommand.tab_page{count, back}`; `cmd_tab.gotoPage` goes to page N (past the end ⇒ last page) or N pages back with wrap. Pinned by `tests/e2e-zig/vim_count_gt.test`, a `vim.zig` handler test and a `cmd_tab.zig` unit test.
