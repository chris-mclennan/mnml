---
severity: SEV-2
status: fixed
---
# `Ctrl+S` does nothing — no save, no feedback — while the find bar or the command palette has focus

**Command id:** `file.save` (`ctrl+s`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"key","key":"ctrl+end"}
{"cmd":"type","text":"// dirty"}
{"cmd":"key","key":"ctrl+f"}
{"cmd":"type","text":"alpha"}
{"cmd":"key","key":"ctrl+s"}
{"cmd":"snapshot"}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"ctrl+shift+p"}
{"cmd":"key","key":"ctrl+s"}
{"cmd":"snapshot"}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"ctrl+s"}
{"cmd":"snapshot"}
```
`status.json` `panes[].dirty` for alpha.zig after each snapshot: `true`, `true`, `false`. **screen.txt** shows no `saved …` toast after the first two presses; the find bar stays open with `Find  alpha … match 1/2` and the palette stays open.

**Expected**: `Ctrl+S` always saves (VS Code's `workbench.action.files.save` has no `when` clause — it fires with the find widget or quick-open focused). The persona brief calls this out explicitly.
**Actual**: the find bar's `text_field.handleKey` and the picker's input consume the chord; the buffer stays dirty and nothing tells the user. (`Ctrl+S` with multi-cursor active does save.)

**Source pointer**: `src/app/dispatch.zig:937` `findBarKey` → `src/ui/find_bar.zig:82` `handleKey` (ctrl-char table has `r c n p` only; everything else goes to the text field); the picker overlay branch in `dispatch.zig` likewise. Neither falls back to the global keymap for unclaimed ctrl chords.

## Fix

`e75e0b7` on branch `fix-editor` — dispatch: Ctrl+S saves from the find bar and the palette, and the widget stays. Any modified chord the widget's field does not claim now resolves through the keymap as a single chord (leader prefixes stay with the widget). Regression: `tests/e2e-zig/vscode_ctrl_s_in_widgets.test`, plus a unit row in `src/app/cmd_picker.zig`.
