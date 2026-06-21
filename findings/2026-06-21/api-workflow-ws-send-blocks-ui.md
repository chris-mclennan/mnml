---
finding: ws-send-blocks-ui-thread
severity: SEV-1
surface: http.send
---

**Repro**:
1. Open a `.json` editor buffer containing `{ "url": "wss://echo.websocket.org", "message": "hello", "timeout_ms": 5000 }`.
2. Run `:ws.send` from the palette.

**Expected**: the UI remains responsive; the command fires in a background thread and posts a result when done.

**Actual**: `ws_send_active` (src/app/http.rs:624) runs entirely on the **main application thread** — including the `std::thread::scope` polling loop with 50ms sleeps that runs up to `timeout_ms` milliseconds (default 5000ms, user-settable higher). For a 30-second timeout the UI freezes for up to 30 seconds. The scope-thread trick means even the scoped thread blocks `ws_send_active`'s caller from returning.

Contrast with `:grpc.send` (same file, line 735) which also blocks the main thread via `cmd.output()` but typically returns quickly. `ws.send` explicitly provides a `timeout_ms` field and documents the worst-case — making this freeze predictable and user-triggerable.

**IPC trace**: Any `{"cmd":"run-command","id":"ws.send"}` IPC event will be followed by zero screen updates for up to `timeout_ms` ms if the websocat child is slow.

**Notes**: The fix pattern is the one already used for `http.bench`, `http.sync`, `http.run_chain`, and `http.ai_build`: spawn a `std::thread`, send result via `mpsc::channel`, drain in `App::tick`. `grpc.send` has the same structural issue but is a quicker call in practice.

Offending lines: `src/app/http.rs:689–700` (the scope-polling loop).
