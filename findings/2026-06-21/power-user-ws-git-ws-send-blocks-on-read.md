---
finding: ws-send-blocks-on-read
severity: SEV-1
agent: power-user-ws-git
repro: code-review
---

# WS worker thread blocks on `socket.read()` — outgoing sends can deadlock

`src/websocket.rs::worker` (lines 183-234) loops:

```rust
loop {
    // Drain pending outgoing first so user-initiated sends
    // don't sit behind a slow read.
    while let Ok(out) = out_rx.try_recv() { ... }
    // Try a non-blocking-ish read. tungstenite::read blocks;
    // wrap in a thread might be heavier than just sleeping.
    // Compromise: read with a small sleep loop on no data.
    match socket.read() {
        Ok(Message::Text(s)) => { ... }
        ...
    }
}
```

The "compromise" comment promises a non-blocking read with a sleep
loop — but **the read is never set non-blocking** and there is no
sleep loop. `tungstenite::connect()` returns a blocking socket, so
`socket.read()` blocks until the server sends a frame OR the
connection drops.

Concrete consequences:

1. **First-message deadlock for client-initiated protocols.** If
   the server doesn't send a banner on connect, the worker blocks
   on `read()` immediately. The user types a message, hits Enter,
   `OutMsg::Send(text)` lands in the channel — but the worker
   never gets back to `out_rx.try_recv()` to pick it up. The send
   stays queued forever. Nothing toast-fires; the user sees their
   line echo into the log (`send_input` pre-echos the outgoing
   line — line 124) but the server never sees it.

2. **`:ws.disconnect` doesn't actually close.** `App::ws_disconnect`
   sends `OutMsg::Close` and sets `state = Closing`. But the
   worker is blocked in `read()`. The Close message sits in the
   channel; the socket isn't closed; the tab shows `▼ closing`
   forever (until the server-side eventually times out).

3. **Pane drop leaks the worker thread.** When the user closes
   the WS pane, `tx_out` is dropped, the channel goes Disconnected.
   But the worker is blocked on `read()` — it would only notice
   the disconnection during `try_recv`. The thread sticks around
   until the server kills the connection.

## Fix sketch

Two reasonable shapes:

a. **Non-blocking + sleep**, as the comment promised:
   ```rust
   socket.get_mut().set_nonblocking(true)?;
   loop {
       drain_outgoing();
       match socket.read() {
           Err(tungstenite::Error::Io(e)) if e.kind() == WouldBlock => {
               std::thread::sleep(Duration::from_millis(50));
               continue;
           }
           ...
       }
   }
   ```
   Note: `set_nonblocking` requires reaching through the
   `WebSocket` to the underlying TCP stream — the tungstenite API
   for that varies by feature (rustls vs native-tls) so it needs
   case work.

b. **Two-thread split**, similar to the chain runner: one thread
   does blocking reads, the other handles writes. Heavier but
   simpler to reason about.

## Repro (manual)

```
:ws.connect → wss://echo.websocket.events
# wait for "● open"
:ws.send_message
# Type "hello", Enter
# The "→ hello" line appears in the log (local echo only).
# No "← Echo: hello" arrives because the worker is blocked in read
# until the server sends something on its own initiative.
```

This is the same root cause as
`api-workflow-ws-worker-blocking-read.md` (already filed today),
but from a different angle:

- That finding: "`:ws.disconnect` doesn't actually disconnect on
  quiet servers" — worker stays alive until server sends something.
- This finding: "first user-initiated send sits in the channel
  forever if the server hasn't already spoken" — the much more
  common echo / request-response pattern outright deadlocks.

Both are the same blocking-`read()` bug. The fix is the same;
the user-visible failure modes differ enough that both should be
in the report.

Distinct from `api-workflow-ws-send-blocks-ui.md` which is about
the older `ws.send` shell-out blocking the UI thread.
