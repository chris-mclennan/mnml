---
severity: SEV-3
status: fixed
---
# Every `gt` / `gT` / `:tabnew` spawns a persistent `tab N/M` toast; they stack until `+6 more…`

**Command ids:** `tab.next`, `tab.prev`, `tab.new`, `tab.close`.

**Reproduction**:
```
{"cmd":"type","text":":tabnew\n"}
{"cmd":"key","key":"g T"}
{"cmd":"key","key":"g t"}
{"cmd":"key","key":"g T"}
{"cmd":"snapshot"}
```
**screen.txt** (right edge, all still visible after several seconds):
```
26|  │ tab 1/2          │
29|  │ tab 2/2          │
32|  │ tab 1/2          │
35|  │ tab 1/1          │
```
With more activity the stack collapses to `│ +6 more… │` and hides newer, useful toasts (`unsaved changes …`, `no language server …`).

**Expected**: vim shows nothing on a tab switch (the tabline already changes); at most a transient statusline message. A toast per navigation keystroke is noise for a keyboard-driven user and crowds out real errors.

**Actual**: one long-lived toast per switch. Seen in every session with tab pages.

## Fix

`5063074` — `App.toastReplace(id, …)`: every tab-page move replaces the previous `tab N/M` toast (id `"tab"`) and the toast expires normally, so at most one is ever on screen. Kept rather than removed because the chrome has no tab-page strip — the toast is the only cue. Pinned by `tests/e2e-zig/vim_tab_switch_toast.test` and a `cmd_tab.zig` unit test.
