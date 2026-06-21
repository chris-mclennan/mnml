---
finding: ws-close-silent-no-toast
severity: SEV-3
agent: power-user-ws-git
repro: code-review
---

# Esc / Ctrl+C close the WS pane silently; no toast on close

In `src/tui.rs:1791-1797`:

```rust
KeyCode::Esc => {
    if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
        p.close();
    }
}
...
KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
    if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
        p.close();
    }
}
```

`p.close()` flips state to `Closing` and sends `OutMsg::Close`,
but emits no toast. By contrast, `:ws.disconnect` (palette)
toasts "ws: closing…". A user who hits Esc by accident has no
toast to spot the mistake — only the (subtle) state-chip change
from `● open` to `▼ closing` at the top of the pane.

Symmetric to the `:ws.disconnect` toast — pick one convention
(toast on every close gesture, or none). Toasting feels right
given the irreversible nature of the action (mnml has no
auto-reconnect — once closed, the only path back is `:ws.connect`
+ retype the URL).

This is part of the larger SEV-2 finding about Esc destroying
the connection — but the silent-close is a separate, simpler fix
that helps even if Esc's binding stays the same.
