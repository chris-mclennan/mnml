---
finding: nvchad-ctrlw-blocked-from-special-panes
severity: SEV-1
agent: nvchad-power-user
repro: headless-ipc
---

# Ctrl+W window-prefix dropped on the floor in every non-editor pane

The NvChad reflex for switching split windows is `Ctrl+W h/j/k/l`.
mnml's window-prefix only fires when the *active pane is an Editor*.
Every special-purpose pane has a self-contained dispatcher that
matches a fixed key set and `_ => {}`-swallows the rest — Ctrl+W
gets consumed, no chord, no toast, no fallthrough.

Confirmed pane families that eat Ctrl+W:

- `Pane::Request` (`src/tui.rs:5440-5456` — Response view `match` has
  no Ctrl+W arm; function returns `true` unconditionally after the
  match, so the chord never bubbles to the window handler)
- `Pane::Diagnostics` (`src/tui.rs:2458-2476`)
- `Pane::Cheatsheet` (`src/tui.rs:2103-2181`)
- `Pane::Websocket` (`src/tui.rs:1791-1836` — and Esc closes the
  *connection*, not the pane, so there's no way out either)
- `Pane::ClaudeAgents` (`src/tui.rs:1885-2066`)
- `Pane::Grep` (`src/tui.rs:2481-2514`)
- `Pane::Quickfix` (`src/tui.rs:2518-2539`)
- `Pane::CmdlineHistory` (`src/tui.rs:2543+`)

## Reproduction

```jsonc
{"cmd":"open","path":"foo.rs"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"vsplit\n"}                  // 2 splits, active=1
{"cmd":"open","path":"api.curl"}
{"cmd":"run-command","id":"http.send"}            // request pane opens
{"cmd":"wait_ms","ms":1500}
{"cmd":"key","key":"ctrl+w"}
{"cmd":"key","key":"h"}                           // expect: focus left pane
{"cmd":"snapshot"}
```

**Expected**: `activePane` moves from the Request pane to the
editor split on the left (vim canon).

**Actual**: `activePane` stays on the Request pane. The Ctrl+W is
silently dropped by `handle_request_key`'s `_ => {}` arm, then
the function returns `true` (line 5456), short-circuiting the
window-prefix chord chain.

The same trap fires from Diagnostics, Cheatsheet, ClaudeAgents,
WS, etc. — every "view" pane is a roach motel for vim window
navigation. The only escape hatches are mouse, `Ctrl+E` (mnml
custom), or `Esc` (which sometimes refocuses the tree, sometimes
closes the connection).

## Source pointer

`src/tui.rs:5323` (`handle_request_key`'s unconditional
`return true;` after the response-mode match — same shape in
every special-pane dispatcher above).

The vim handler for the editor builds up `Prefix::Window`
correctly (`src/input/vim.rs` — line 187 reserves `ctrl+w`), but
the chord chain never reaches it because each special pane
intercepts the leading `Ctrl+W` first.

## Notes

A user with two editor splits + one Diagnostics / Request / Grep
pane open will lose the keyboard route to the editor side any
time their cursor sits in the special pane. The mouse-only escape
collides with the "vim user never touches the mouse" persona that
shipped these chord vocabularies in the first place.

Related to but distinct from the prior `power-user-ws-git-esc-destroys-connection`
finding (Esc-in-WS-closes-connection). Ctrl+W is broader — it's
every special pane and it's the prefix chord, not the close chord.
