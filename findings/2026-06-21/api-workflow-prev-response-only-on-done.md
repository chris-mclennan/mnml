---
finding: prev-response-not-captured-from-streaming
severity: SEV-3
surface: http.send
---

**Repro**:
1. Fire `:http.send_streaming` against an SSE endpoint — stream completes, pane flips to `Done`.
2. Fire `:http.send_streaming` again (or any follow-up send).
3. Run `:http.diff_last_two`.

**Expected**: diff shows the previous streaming response body vs the new one.

**Actual**: `drain_http_jobs` (src/app/http.rs:3574–3578) captures `prev_response` with:
```rust
if let RunState::Done(prev) = std::mem::replace(&mut rp.state, RunState::Done(Box::new(rv))) {
    rp.prev_response = Some(prev);
}
```
This pattern only captures a previous `Done` state when the **new result** also arrives via `drain_http_jobs`. But SSE sends arrive via `drain_sse_jobs` — the close handler (line 3507) does `rp.state = RunState::Done(Box::new(rv))` with no check of the prior state and no `rp.prev_response` assignment. So:

- Streaming send 1: state = Done(rv1), prev_response = None (no prior Done via drain_http_jobs).
- Streaming send 2: state = Done(rv2), prev_response = None (drain_sse_jobs never sets prev_response).
- `:http.diff_last_two` toasts "need at least 2 successful sends to diff".

Additionally, a mixed workflow (first `:http.send`, then `:http.send_streaming`) loses `prev_response` on the streaming result because `drain_sse_jobs` doesn't capture the existing Done before overwriting it.

**Offending file:line**: `src/app/http.rs:3497–3508` — `SseStreamMsg::Close` handler missing `prev_response` capture.
