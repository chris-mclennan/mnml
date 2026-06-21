---
finding: nvchad-ws-pane-no-modal-awareness
severity: SEV-1
agent: nvchad-power-user
repro: headless-ipc
---

# WebSocket pane has no notion of vim modes — every keystroke is text input

The WS pane (`src/tui.rs:1789-1837`) treats *any* printable char
(`KeyCode::Char(c) if !ctrl`) as a literal char appended to the
outgoing message buffer. A vim user reflexively types `i` to enter
insert mode, then `Esc` to leave — instead they get `i` typed
into the WS message and `Esc` closes the live connection.

## Reproduction

```jsonc
{"cmd":"run-command","id":"ws.connect"}
{"cmd":"type","text":"wss://echo.websocket.org\n"}
{"cmd":"wait_ms","ms":1200}
{"cmd":"key","key":"i"}                          // vim: enter insert
{"cmd":"key","key":"h"}                          // vim: cursor left
{"cmd":"key","key":"i"}                          // vim: insert again
{"cmd":"snapshot"}
```

**Expected**: editor-style modality — `i` toggles a text-input
zone, motion keys move the cursor, Esc returns to normal so
chord-driven nav works.

**Actual**: the input buffer literally contains `ihi`. The pane
draws `│ ▸ ihi │` at the bottom. There is no NORMAL state to
escape into — `mode` is reported as `"none"` in `status.json`.

`Esc` next is even worse: it closes the WS connection (state
moves to `Closing`, `src/websocket.rs:133-136`) but leaves the
pane in place — no toast, no warning, and no `Ctrl+W h` escape
hatch (see related finding: Ctrl+W is dropped from this pane
too). A vim user goes Esc → loses TLS handshake → has to retype
the whole URL via `ws.connect`.

## Source pointer

- `src/tui.rs:1828-1832` — bare-char append (no modal gate)
- `src/tui.rs:1793-1797` — Esc → `p.close()`
- `src/websocket.rs:133` — `close()` sends `OutMsg::Close` and
  transitions state, irreversible from this side

## Notes

The pane title strip helpfully prints `esc=close · ctrl+e=tree`
— but a NvChad user pauses to read that exactly never; muscle
memory drives Esc → expected return-to-normal. The pane should
either:

1. Show a `[type | esc | …]` legend with a modal indicator and
   absorb Esc as "stop appending" instead of "close socket", or
2. Adopt a real input-area focus model (Esc → defocus input ring,
   `i` → re-enter input ring) so vim users have a place to land.

Esc-closes-connection is also partly tracked in
`power-user-ws-git-esc-destroys-connection.md` from earlier
today; this finding adds the modal-conflict angle (every other
printable char also dumps into the buffer with no way to
"escape" the typing context the way every editor pane allows).
