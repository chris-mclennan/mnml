---
finding: schema-revalidate-ignores-streaming-state
severity: SEV-2
surface: http.revalidate_schema | http.show_schema_errors
---

**Repro**:
1. Fire `:http.send_streaming` against a JSON SSE endpoint (each event body happens to be JSON).
2. While in `RunState::Streaming`, run `:http.revalidate_schema`.

**Expected**: Either validates the partial body accumulated so far, or toasts "schema: stream still open — wait for close".

**Actual**: `http_revalidate_schema` (src/app/http.rs:915–961) pattern-matches only `RunState::Done(rv)` — any other state (Sending, Streaming, Failed) falls through to `self.toast("schema: no completed response")`. This is documented behavior.

**BUT** `:http.show_schema_errors` (src/app/http.rs:854–910) has an intentional carve-out for `RunState::Streaming`:
```rust
RunState::Done(rv) | RunState::Streaming(rv) => { ... }
```
This means `show_schema_errors` will try to display schema errors from a stream that has `schema_result: None` (streaming ResponseView is initialized with `schema_result: None` and only set at Close). The `schema_result.as_ref()` check will return `None` and toast "schema: no sidecar (.schema.json) for this request" — but the real reason is that no schema validation has been run yet, not that there's no sidecar. A user seeing this message while streaming could incorrectly conclude the sidecar is missing.

Additionally, the `Done(rv) | Streaming(rv)` match arm in `show_schema_errors` vs the `Done(rv)` only match in `revalidate_schema` creates an asymmetry: you can open the schema-errors pane while streaming (getting a misleading toast), but you can't revalidate while streaming (getting a different toast). Neither explains the true state (stream in progress, no schema run yet).

**Offending file:line**:
- `src/app/http.rs:862–870` — `Done(rv) | Streaming(rv)` match in `show_schema_errors` leads to misleading toast when no sidecar validation has been run during streaming.
- `src/app/http.rs:921–929` — `revalidate_schema` rejects `Streaming` state with a generic "no completed response" toast.
