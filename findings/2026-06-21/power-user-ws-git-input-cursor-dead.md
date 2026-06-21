---
finding: ws-input-cursor-dead-no-cursor-movement
severity: SEV-3
agent: power-user-ws-git
repro: e2e
---

# WS input has no Left/Right/Home/End — `input_cursor` field is unused

`WebsocketPane` (src/websocket.rs:39-52) carries an `input_cursor:
usize` field, and the key handler (src/tui.rs:1789-1836) carefully
maintains it on push/pop:

```rust
KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
    if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
        p.input.push(c);
        p.input_cursor += c.len_utf8();
    }
}
KeyCode::Backspace => {
    if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
        if let Some(c) = p.input.pop() {
            p.input_cursor = p.input_cursor.saturating_sub(c.len_utf8());
        }
    }
}
```

But:

1. The renderer in `src/ui/ws_view.rs:131` computes cursor x from
   `p.input.chars().count()` — NOT from `input_cursor`. So
   `input_cursor` is dead state.

2. There is no `KeyCode::Left` / `KeyCode::Right` / `KeyCode::Home`
   / `KeyCode::End` / `KeyCode::Delete` handling, so the cursor
   is effectively pinned at end-of-string. The user can only
   append + Backspace from the tail.

3. `ws_send_on_active` (src/app/http.rs:599-601) writes
   `p.input_cursor = message.len()` — using BYTE length where
   the field is also bytes (but conceptually inconsistent with the
   renderer's char-count usage).

4. `input_cursor` and `input.chars().count()` would diverge under
   multi-byte chars (emoji, CJK), but since cursor render doesn't
   use the field, there's no visible bug today — just dead code
   waiting to become a bug when someone wires Left/Right in.

5. Also unhandled: `KeyCode::Tab`, `KeyCode::Insert`. Tab is
   silently dropped (Tab is its own KeyCode, not `Char('\t')`),
   which feels wrong for a payload that might be JSON the user
   wants to indent.

## Repro

```text
# .test script — findings/2026-06-21/probe_ws_no_editing.test
command ws.connect
type ws://127.0.0.1:1
key enter
wait 50
type hello
expect screen contains "hello"
key left
type X
# Test passes — Left does nothing, X is appended at the end
expect screen contains "helloX"
expect screen lacks "helXlo"
```

## Fix sketch

Either:
- Delete `input_cursor` — it's dead state.
- OR wire Left/Right/Home/End/Delete properly and switch the
  renderer to use `input_cursor` (in chars, not bytes — or
  document the byte convention and pick one).

Tab: route through to a literal `'\t'` insertion or, better, a
configurable expand-to-spaces.
