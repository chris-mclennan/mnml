---
finding: ws-esc-destroys-connection-mid-typing
severity: SEV-2
agent: power-user-ws-git
repro: e2e
---

# Esc in WS pane unconditionally closes the connection — no "back out of typing" affordance

`src/tui.rs:1791-1797`:

```rust
if matches!(app.panes.get(i), Some(Pane::Websocket(_))) {
    match key.code {
        KeyCode::Esc => {
            if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                p.close();
            }
        }
        ...
```

Pressing Esc at ANY time inside the WS pane closes the connection
unconditionally — including mid-typing. This is hostile to two
muscle-memory patterns:

1. **Vim users** Esc to exit insert mode. The WS pane is "always
   inserting" (there's no mode), but vim users will Esc reflexively
   when they want to stop typing — losing their connection in the
   process.

2. **Standard users** Esc to dismiss popups / pickers. Mid-typing,
   Esc usually clears the input or unfocuses. Closing the
   connection is a much heavier action than the user expects.

Compounding the surprise, Esc gives no toast (`p.close()` itself is
silent — only the explicit `:ws.disconnect` palette command toasts
"ws: closing…"). A user who hit Esc by accident sees their tab
silently flip from `● open` to `▼ closing` to `· closed`.

## Repro

```text
# .test script — findings/2026-06-21/probe_ws_esc.test
command ws.connect
type ws://does-not-exist.invalid
key enter
wait 50
type hello
expect screen contains "hello"
key esc
wait 50
expect screen contains "closing"
```

## Fix sketch

Better contract — match what other panes do:

- Esc with non-empty input → clear input (mirror what most
  REPL-shaped UIs do)
- Esc with empty input → focus tree (mirror Ctrl+E)
- `Ctrl+C` already maps to close — keep that as the explicit
  "I want to disconnect" gesture, and surface a toast on close.
- For an even safer floor: gate `:ws.disconnect` and `Ctrl+C` on
  a confirmation when the connection is `Open` and the log has
  unsaved messages (mirror the dirty-buffer pattern).
