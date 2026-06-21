---
finding: http-abort-misses-chain-and-ai-build
severity: SEV-2
surface: http.send
---

**Repro**:
1. Run `:http.run_chain` on a multi-step chain that makes real HTTP calls (e.g. 5 steps × 30s timeout each = 2.5 min worst case).
2. While it is in flight, run `:http.abort`.
3. Observe toast — "http: nothing in flight" OR "http: released UI tracking" only covers bench/sync/lookup.
4. Run `:http.ai_build` on any description while step 1 chain is still running.
5. The `http_chain_in_flight` guard blocks the second chain, but `:http.abort` never clears `http_chain_in_flight`, so a subsequent `:http.run_chain` while the original worker is still alive will be rejected with "a chain is already running" even after `:http.abort`.

**Expected**: `:http.abort` clears all in-flight tracking, including `http_chain_in_flight`, `http_ai_build_in_flight`, and the `sse_chan`'s flying job (no drain rx but the pane stays in `RunState::Sending`).

**Actual**: `http_abort_all` (src/app/http.rs:3158–3170) only drops `http_bench_rx`, `http_sync_rx`, and `lookup_fire_rx`. It does not reset `http_chain_in_flight` or `http_ai_build_in_flight`. After a chain worker runs to completion the flag clears in `drain_http_chain`, but `:http.abort` cannot unblock a frozen chain without also clearing the flag.

Additionally, SSE streaming panes stuck in `RunState::Sending` (e.g. because the SSE worker errored before posting `Open`) have no abort path at all — `:http.abort` doesn't touch `sse_chan` and the pane stays in Sending state permanently until mnml restarts.

**Offending file:line**: `src/app/http.rs:3158` — `http_abort_all` body.
