---
finding: websocket-worker-blocking-read-no-close-escape
severity: SEV-2
surface: http.send
---

**Repro**:
1. `:ws.connect wss://some-server` — server connects, sends nothing for minutes (quiet socket).
2. Run `:ws.disconnect`.
3. Check if the WS worker thread terminates promptly.

**Expected**: worker thread sees the `OutMsg::Close`, calls `socket.close(None)`, thread exits.

**Actual**: The WS worker loop (src/websocket.rs:183–234) drains `out_rx` first, then calls `socket.read()` which is a **blocking** call with no timeout. The tungstenite docs note that `WebSocket::read` blocks until a frame arrives. On a quiet server that sends no frames, the worker is stuck in `socket.read()` and never reaches the `out_rx.try_recv()` at the top of the next iteration.

So the sequence is:
1. Worker drains out_rx (empty — no messages pending).
2. Worker calls `socket.read()` — blocks indefinitely.
3. User calls `:ws.disconnect` → `ws_disconnect` → `p.close()` → sends `OutMsg::Close`.
4. `OutMsg::Close` sits in `out_rx` but the worker is blocked on `socket.read()`.
5. Worker never sees the Close message; the thread stays alive forever (or until the server sends a frame, which triggers the `Ok(Message::Close(_))` arm and eventually exits the loop).

The comment at line 201 acknowledges the problem: "Try a non-blocking-ish read. tungstenite::read blocks; wrap in a thread might be heavier than just sleeping." The proposed solution was a sleep loop but none was implemented.

**Observable symptom**: After `:ws.disconnect`, the WS pane state shows `Closing` (set optimistically by `p.close()` at line 135), but the worker thread never sends `WsMsg::State(WsState::Closed)` because it's blocked. The pane stays at `Closing` until the server happens to close or send something. If the user reopens mnml or the workspace runs many WS connections over time, zombie threads accumulate.

**Offending file:line**: `src/websocket.rs:203` — `socket.read()` is blocking with no cooperative cancel path.

**Notes**: The correct fix for tungstenite is either setting a read timeout on the underlying TCP stream (`socket.get_mut().set_read_timeout(Some(Duration::from_millis(100)))`) or using `tungstenite`'s non-blocking API. The current architecture needs a short-polling loop with `select!` or thread-local nonblocking reads. This is a documented v2 item but the symptom is user-visible: `:ws.disconnect` doesn't actually disconnect on quiet servers.
