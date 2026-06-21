---
finding: ws-send-message-prompt-dispatches-without-pane-check
severity: SEV-3
surface: http.send
---

**Repro**:
1. Open a `Pane::Websocket` and connect to a server.
2. While the WS pane is focused, run `:ws.send_message` — fills in the prompt.
3. Before accepting the prompt, switch focus to a different pane (e.g. click an editor pane) so the active pane is no longer a `Pane::Websocket`.
4. Accept the prompt (Enter).

**Expected**: the message is sent to the WebSocket connection that was active when the prompt was opened. OR: toast "ws: focus a ws pane first".

**Actual**: `ws_send_on_active` (src/app/http.rs:589–602) is the accept handler. It checks `self.active` at the time of **accept**, not at prompt-open time. If the user switched panes, it will find a non-WS pane and toast "ws: focus a ws pane first" — silently discarding the typed message.

This is worse when the WS pane index changed (e.g. a different pane was closed that shifted pane indices) — the active index now points to whatever pane landed there. The pane check `Some(Pane::Websocket(p))` guards against sending to a non-WS pane (no data corruption), but the discarded message gives no explicit "your message was dropped because focus moved" feedback.

**Notes**: The correct fix is to stash the target pane id at prompt-open time (same pattern as `pending_env_edit_key`) so the accept handler sends to the right pane regardless of current focus. The current code is consistent with other prompt handlers, but WS is especially vulnerable because the user is actively switching context while a live connection is running.

**Offending file:line**: `src/app/http.rs:533–544` (`ws_send_message_prompt`), `src/app/http.rs:589` (`ws_send_on_active`).
