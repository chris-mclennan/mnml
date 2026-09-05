---
severity: SEV-2
status: open
---
# `<leader>` chord's second key is executed as a vim motion when typed within the chord timeout

**Command ids:** `whichkey.leader` (`space`), `view.toggle_tree` (`space e`), `picker.files` (`space f f`), `file.save` (`space w`), `buffer.close` (`space x`) — every `space …` chord in the vim profile.

**Reproduction** (vim profile, editor focused, NORMAL, cursor on `const std = @import("std");` col 1):
```
{"cmd":"open","path":"hunt/b.zig"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"space"}
{"cmd":"key","key":"e"}
{"cmd":"snapshot"}
```
Same with `space` then `w`, and with `space` `f` `f`. A `wait_ms` of any length between `space` and the next key makes the chord resolve (the wait fires `expireChords`, the popup opens, and the popup takes `e`). In the real TUI the fallback only fires after `editor.chord_timeout_ms` (500 ms, `app.zig:1680` checks `now >= deadline`), so any user typing `<leader>e` / `<leader>ff` at normal speed hits this.

**screen.txt / status.json**: after `space` `e`: `"cursor":{"line":1,"col":5}` (the `e` end-of-word motion ran: 1→5), `"treeVisible":true` unchanged, and the Leader popup is open at its root:
```
30|│ ╭ Leader ───────────────────────────────────────────────╮
31|│ │/ → toggle comment  e → file tree   n → line numbers …
```
After `space` `w`: cursor 1→7 (`w` motion), nothing saved. After `space` `f` `f`: no picker, popup at root.

**Expected**: `<leader>e` toggles the tree, `<leader>ff` opens the file picker, `<leader>w` saves — immediately, regardless of typing speed (Neovim resolves the mapping on the second key).

**Actual**: the key after `space` is handed to the vim handler as a normal-mode motion; the chord chain never sees it; 500 ms later the which-key popup opens at its root and stays open.

**Source pointer**: `src/app/dispatch.zig` `key()` — `editor_first = … or (modal and plain and !bare_space)` sends every plain key in vim NORMAL to `feedEditor` first without checking `app.chord.len > 0` (compare `ptyKey`, which does `if (app.chord.len > 0) chordChain(...)`). `chordChain` arms `space` as `pending_with_fallback` but the continuation key never reaches `resolveSeq`.

**Notes**: this also explains why `space x` on a dirty buffer earlier looked like "nothing happened" and later keystrokes went to the wrong place. NvChad parity: `<leader>ff`, `<leader>e`, `<leader>x`, `<leader>/` are muscle memory; all of them are affected.
