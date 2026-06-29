---
agent: vscode-user-keyboard
severity: SEV-3
---

# Round-6 keyboard QA — what worked, what didn't

**Verified on:** HEAD 029b0fe · `target/release/mnml --headless --input standard /tmp/.../ws`

## Executive summary

3 findings (3 × SEV-2, 0 × SEV-1). mnml feels broadly keyboard-complete for VS Code muscle memory in standard mode — almost every chord exercise this round fired the intended command. The two big keyboard regressions from this week's tracks (right-panel chord chain, `<leader>`-prefixed t/h/a chains, vim operator-inclusive ops) all check out. The three SEV-2s are NOT new this week:

1. `Ctrl+L` permanently bound to `view.redraw` instead of `editor.select_line` — a pre-existing muscle-memory collision.
2. `Shift+F10` chip-context-menu fallback depends on `hover_chip`, which only the mouse can set — pure keyboard users can't reach gear / launcher / integration / 4 statusline chip menus.
3. Vim cmdline `Ctrl+R Ctrl+W` / `Ctrl+R Ctrl+A` (insert word under cursor) is unimplemented — pre-existing.

Could a VS Code-style keyboard purist get a full day's work done? Mostly yes — file picker, save, undo/redo, copy/paste, find/replace, multi-cursor, comment toggle, line-move, line-duplicate, goto-line, rename, peek, MRU buffer toggle, sidebar/right-panel toggle and split control are all keyboard-driven. The two persistent paper cuts are (a) `Ctrl+L` doing the wrong thing and (b) statusline/chip context menus being unreachable from the keyboard. Both are SEV-2 but workaround-able via the palette.

## Verified working this round

| Chord / chain | Result |
|---|---|
| `Ctrl+Shift+B` toggle right panel | `rightPanelVisible` flips both directions |
| `Ctrl+Alt+W` close active right-panel tab | works; panel stays visible with `panes=[]` |
| `<leader>t]` / `<leader>t[` / `<leader>tx` (Ctrl+K → t → ./[/x) | cycle next / prev / close active — all confirmed |
| `<leader>h]` / `<leader>h[` in `.http` | cursor jumps between `###` separators |
| `<leader>ab` (ai.toggle_backend) | toast `ai.backend: cli` |
| `Alt+Left` / `Alt+Right` | nav.back / nav.forward through buffer history |
| `Ctrl+End` | cursor to line 12 col 2 (end of last `}` in 12-line file) |
| `Ctrl+Tab` MRU buffer toggle | `main.rs ⇄ util.rs ⇄ readme.md` MRU stays correct across 3 buffers |
| `Ctrl+P` workspace affinity | top results are current-workspace files; cross-workspace files ranked below |
| `Ctrl+Shift+E` focus tree → `Shift+F10` | tree-row context menu opens correctly |
| Vim NORMAL `cw`, `ce`, `de`, `d$`, `y$`, `c$` | all inclusive of last char; cw leaves trailing space (matches `ce`) |
| Vim NORMAL `Ctrl+H` (MoveLeft) | col decreases by 1 |
| Standard `Ctrl+/` toggle comment | inserts `//` before line content |
| Standard `Alt+Up` / `Alt+Down` move line | swaps with neighbour |
| Standard `Shift+Alt+Down` duplicate line | exact copy added below |
| Standard `Ctrl+D` add next occurrence | first hit selects current word, cursor jumps end-of-word |
| Standard `Ctrl+G` → "5" → Enter | goto line 5 |
| Standard `Ctrl+H` find/replace prompt | overlay opens with hint "Ctrl+H again to replace" |
| Standard `F2` rename | "Rename symbol to" overlay opens |
| `Ctrl+Shift+[` / `Ctrl+Shift+]` fold/unfold | works in BOTH standard + vim NORMAL; "nothing to fold here" toast on empty |
| `Alt+F12` peek overlay | chord delivered, LSP-less so silent (not a regression) |
| 5× `Ctrl+P` toggle | picker still works on 5th press, no stuck state |

## Signal handler

Confirmed:
- `kill -TERM <pid>` → `events.jsonl` ends with `{"event":"exit","reason":"signal","note":"SIGTERM/SIGINT/SIGHUP — early exit"}`
- `kill -INT  <pid>` → same `signal` exit row
- `kill -KILL <pid>` → no exit event (uncatchable, as intended)

Death-cert IPC is working correctly. This is the regression-prevention behaviour the recent `chore(ipc)` aimed for.

## Notes for next round

- The earlier-session ghost exit (`"reason":"signal"` mid-test) is the user's `./run.sh restart` PostToolUse hook reaching into the test workspace's IPC dir after a successful `cargo build` — not an mnml bug. If a future round wants to be paranoid about isolation, point `--headless` at a workspace path the user's `run.sh` watcher doesn't know about (or unset the hook for the duration).

- Stress-test idea for next time: rapid-fire 100× `Ctrl+Z` then 100× `Ctrl+Shift+Z` over a freshly-edited buffer to spot any undo-stack lag or off-by-one stack walk; didn't fit in this round.
