---
severity: SEV-2
status: open
---
# REGRESSED: `<leader>` chords whose second key is a which-key *menu-only* entry (`<leader>w`, `<leader>n`, `<leader>sv`, `<leader>?`…) still hand that key to the vim handler when typed at speed

**Command ids:** `whichkey.leader` (`space`), `file.save` (`<leader>w` — named in the original finding), `view.toggle_line_numbers` (`<leader>n`), `view.split_right` (`<leader>sv`), `view.cheatsheet` (`<leader>?`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/b.zig"}
{"cmd":"type","text":":13\n"}
{"cmd":"type","text":" n"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"space"}
{"cmd":"key","key":"n"}
{"cmd":"snapshot"}
{"cmd":"type","text":"x"}
{"cmd":"type","text":" w"}
{"cmd":"snapshot"}
#sh sed -n 13p nvchad-scratch/b.zig
{"cmd":"type","text":" sv"}
{"cmd":"snapshot"}
{"cmd":"type","text":" ff"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
type " n":            Leader popup open at its ROOT, line numbers still on  (│   2 …)
key space, key n:     │ line numbers off │   (works when the keys arrive in separate ticks)
x, type " w":         panes [("b.zig", dirty:true)]; on disk line 13 is still `    greet("world");`  — not saved
type " sv":           no split (panes unchanged)
type " ff":           Files picker opens  (a REGISTERED chord — fine)
Earlier in the same shape (a15): type " n" → toast │ no active find — use / or Ctrl+F first │ = the `n` ran as search-next.
```

**Expected**: per the original finding: `<leader>e` toggles the tree, `<leader>ff` opens the picker, `<leader>w` saves — "immediately, regardless of typing speed". Every entry the Leader popup lists should resolve the same way.

**Actual**: the fix `155f734` holds for chords that exist in `src/commands/specs.zig` (`space /`, `space c h`, `space e`, `space f b|f|g|m`, `space h`, `space v`, `space w K`, `space x`, `space z z`) — those work fast or slow. Entries that exist only in `src/app/whichkey.zig` (`n`, `?`, `p`, `q`, `m`, `1`–`9`, the `b`/`s`/`t`/`g`/`l`… groups, and `w` alone, which the popup labels `w → save`) are not chord continuations, so with `space` armed the keymap rejects `n`/`w`/`s` and `dispatch.key()` falls through to the vim handler: `n` is search-next, `w` is a word motion, `sv` is substitute-char. The popup then opens at its root after the timeout. Sent as separate `key` commands (each followed by a tick that fires the which-key fallback) the same chords work, which is why the original repro passes while the fix's own `type`-based shape does not for these entries. Two launches (a15, v15).

**Source pointer**: `src/app/dispatch.zig:307` `editor_first = app.chord.len == 0 and …` — the pending-chord guard only helps when `resolveSeq` knows the continuation; `chordChain` (`:477-490`) gets `.no_match` for `space n` and releases the key to the editor instead of consulting the which-key menu (`src/app/whichkey.zig:46` `cmd('n', .@"view.toggle_line_numbers", …)`). Fix direction: either register every which-key leaf as a keymap chord, or make the chain treat any key under an armed which-key prefix as owned by the popup.
