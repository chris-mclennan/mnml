---
agent: vscode-user
severity: SEV-3
---

## SEV-3 Ctrl+Shift+[ (editor.toggle_fold) is bound but visibly no-op on a simple Rust function body

**Reproduction**:
```
{"cmd":"open","path":"src/lib.rs"}     // 7-line file with `fn helper() {\n  42\n}\n\nfn unused() {\n  let x = 1;\n}\n`
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"ctrl+home"}        // cursor on line 1 ("fn helper() -> i32 {")
{"cmd":"key","key":"ctrl+shift+["}     // editor.toggle_fold
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
// All 7 lines still visible; no fold marker shown.
```

Same result with cursor on line 5 (`fn unused() {`) and with `run-command editor.toggle_fold` direct dispatch (event log shows `ok:true`).

**Expected**: Per the task description ("VS Code fold/unfold on Ctrl+Shift+[/]") and the command's own title (`"Toggle fold at cursor (vim `za`-ish; VS Code Ctrl+Shift+[)"`), the function body should collapse — replacing lines 2-3 (the `helper` body) with a single elided line like `1 fn helper() -> i32 { …}` and a fold marker in the gutter.

**Actual**: No visible change. The `command_run` event reports `ok:true` so the command fires; either the fold engine requires LSP-provided ranges (which aren't attached for a standalone .rs file with no rust-analyzer running), or the fold renderer doesn't surface anything for a single-block function in this layout. `lsp.fold_all` (`Ctrl+K Ctrl+0` analog) also produces no visible change.

**Source pointer**: `src/command.rs:649-657` (editor.toggle_fold) → `app.toggle_fold_at_cursor()` defined somewhere in `src/app/`. The user-facing behavior should at minimum toast "no fold range here" or show a renderer hint, so the VS Code user understands the chord landed but the file has nothing to collapse.

**Notes**: Could plausibly be working-as-intended if folds genuinely require LSP fold ranges and the test scenario doesn't have rust-analyzer available. SEV-3 because either way, the silent no-op is bad VS Code-parity UX. VS Code's Ctrl+Shift+[ at minimum highlights / flashes the gutter even when no fold is available on the current line.
