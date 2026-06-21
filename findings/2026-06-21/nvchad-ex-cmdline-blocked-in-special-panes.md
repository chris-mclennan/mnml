---
finding: nvchad-ex-cmdline-blocked-in-special-panes
severity: SEV-2
agent: nvchad-power-user
repro: headless-ipc
---

# `:` (ex-cmdline) silently dropped when focus is on Cheatsheet / Diagnostics / ClaudeAgents / Request / Grep

Same architectural shape as the Ctrl+W finding, different chord.
Every special pane's `match key.code { … _ => {} }` arm swallows
`:` and returns from the dispatcher without falling through to
the global cmdline opener.

NvChad muscle memory: a vim user reaches for `:` to type `:w`,
`:e <file>`, `:q`, `:bn`, `:noh`, etc. as a panic button — it's
the universal "do something" key. mnml's special panes block it.

## Reproduction

```jsonc
{"cmd":"run-command","id":"view.cheatsheet"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":":"}                          // expect: ex-cmdline opens
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```

Run the same fragment for `lsp.diagnostics`, `ai.agents_dashboard`,
and `http.send`-resulting Request pane — none of them open the
cmdline.

**Expected**: a bottom-of-screen `:` prompt appears with the
fuzzy popup of registered commands (the same one the editor
shows on `:`).

**Actual**: no visible change. `events.jsonl` records `key`
fired but `screen.txt` is unchanged. The user types
`:bn<Enter>` to switch buffers and the keystrokes are lost.

Worst case is from Diagnostics — a user typing `:cnext` (vim
quickfix-style "next error") gets nothing, has to mouse to the
list or remember a chord.

## Source pointer

- Cheatsheet: `src/tui.rs:2103-2181` — no `KeyCode::Char(':')` arm.
- Diagnostics: `src/tui.rs:2458-2475` — same.
- ClaudeAgents: `src/tui.rs:1885-2065` — same.
- Request: `src/tui.rs:5440-5455` — same.
- Grep / Quickfix / CmdlineHistory: same.

The Editor pane does handle `:` via the vim handler
(`src/input/vim.rs:1015+`); only special panes are affected.

## Notes

This is functionally the same bug as the Ctrl+W finding —
"special pane dispatchers don't fall through" — but worth
flagging separately because it kills a different muscle-memory
chord and a different set of commands.

A single fix at the pane-dispatcher level (let `:` fall through
to the global cmdline opener before the per-pane match) would
clear this AND Ctrl+W in one stroke. The pattern is one of
those "every pane reinvented its own key handler" smells — a
shared "vim-keymap-aware base dispatcher" would let each pane
add its specific chords without re-blocking the global ones.
