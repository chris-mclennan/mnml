---
finding: sse-streaming-captures-abused-as-event-counter
severity: SEV-2
surface: http.send
---

**Repro**:
1. Fire `:http.send_streaming` against an SSE endpoint that emits events (e.g. `curl https://api.anthropic.com/... -H 'Accept: text/event-stream'` format).
2. While streaming, open the Response pane.
3. After stream closes, open `:http.history` — check the `body_bytes` field.
4. Run `@assert` / `@capture` directives in the source `.http` file; run `:http.send_streaming` on it.

**Expected**: `ResponseView.captures` contains the `@capture` directive results. `body_bytes` in history reflects actual body size.

**Actual**: `drain_sse_jobs` abuses `rv.captures` as an event counter: each SSE event pushes `(String::new(), String::new())` into `captures` (src/app/http.rs:3484), then at stream close clears it with `rv.captures.clear()` (line 3503). This means:

1. **During streaming**, `rv.captures.len()` is the event count — which is used by the Response view renderer to display "N events received". This is intentional and documented in the comment. But if the Response view renderer exposes this via the captures section header, it will show N entries of `("", "")` rather than "N events" with proper labels.

2. **After stream close**, `rv.captures.clear()` on line 3503 discards any real captures from `@capture` directives. The streaming path uses `crate::http::script::Script::default()` (no script parsed at all — `spawn_sse_streaming_job` takes a `_script` parameter that is ignored), so `@assert` / `@capture` directives in the source file are silently dropped for SSE sends.

3. **History**: The streaming path does NOT call `crate::http::history::append_with_global_mirror` after the SSE stream closes. Successful SSE sends are never recorded in `.rqst/history.jsonl`. `drain_http_jobs` handles history for regular sends; `drain_sse_jobs` has no equivalent.

**IPC trace**: After `:http.send_streaming` completes, querying `~/.rqst/history.jsonl` will show zero entries from the SSE send.

**Offending file:line**:
- `src/app/http.rs:3484` — `rv.captures.push((String::new(), String::new()))` (event counter hack).
- `src/app/http.rs:3488–3507` — `SseStreamMsg::Close` handler: clears captures, no history append.
- `src/app/http.rs:3268` — `send_streaming_from_active`: passes `Script::default()` to `spawn_sse_streaming_job`, silently ignoring any `@assert`/`@capture` in the source.
