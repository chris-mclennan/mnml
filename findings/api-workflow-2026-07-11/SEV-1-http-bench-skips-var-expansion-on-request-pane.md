---
finding: http-bench-skips-var-expansion-on-request-pane
severity: SEV-1
surface: http.bench
---

**Repro**: numbered steps (headless `.test` harness, `cargo run -- test <file>`;
requires a local HTTP server on 127.0.0.1:8931 answering `GET /items` with
JSON, e.g. `python3 -m http.server`-style stub):

1. `write .rqst/config "default_env=dev"`
2. `write .rqst/env/dev.env "BASE_URL=http://127.0.0.1:8931\n"`
3. `write bench.curl "curl '{{BASE_URL}}/items'\n"`
4. `open bench.curl` (`.curl` files auto-promote to a `Pane::Request` on open)
5. `command http.send` — succeeds, response shows the real JSON body (vars
   *do* resolve for a normal send).
6. `command http.bench` (fires `http.bench` = `http_bench_active(10, 4)`).
7. Wait for the bench trace scratch pane.

**Expected**: 10 requests fire against `http://127.0.0.1:8931/items` (the
resolved URL, same as step 5's successful send) and the trace shows real
latency samples with `p50 ≤ p95 ≤ p99 ≤ max`.

**Actual**: All 10 requests fail with `bad request: builder error` — 0
samples, `min 0 · p50 0 · p95 0 · p99 0 · max 0`. The trace's own request-line
echoes the literal, **unexpanded** template: `bench  GET {{BASE_URL}}/items`.
This reproduces even when `http.bench` is fired *after* a successful
`http.send` on the same pane — the pane's stored `request.url` is never
mutated with the resolved value, only a throwaway local copy is (see Notes).

Reproduced twice (fresh Request pane, and Request pane post-`http.send`) —
both times a literal `{{BASE_URL}}/items` goes on the wire, guaranteeing
100% failure and a degenerate histogram whenever the active request uses any
`{{VAR}}` template — which is the common case for anything hitting a
`BASE_URL` / `TOKEN` env var. This defeats the bench feature's entire
purpose for realistic workspaces (as opposed to hand-typed literal-URL
curls).

**IPC trace / IDE-visible evidence**: `.test` runner's screen dump on
failure showed the `[scratch]` bench-trace pane verbatim:
```
1 bench  GET {{BASE_URL}}/items
2   10 requests · 4 concurrent
3
4 bench summary — 0 samples in 2 ms (rate: 0.0 req/s)
5   latency ms — min 0 · p50 0 · p95 0 · p99 0 · max 0 · mean 0
6   status:
7   errors: 10 (showing up to 3)
8     bad request: builder error
9     bad request: builder error
10     bad request: builder error
```

**Notes** (offending file:line): `src/app/http.rs:3166-3172`,
`fn parse_active_as_request`:

```rust
fn parse_active_as_request(&mut self) -> Option<crate::http::Request> {
    use crate::http::{self, template::EnvSet};
    let cur = self.active?;
    // From a Request pane, just clone the in-flight request.
    if let Some(Pane::Request(rp)) = self.panes.get(cur) {
        return Some(rp.request.clone());
    }
    ...
```

This is `http_bench_active`'s only caller for building the request to bench
(`src/app/http.rs:3262-3270`). Every OTHER call site that builds a request
from a `Pane::Request` (`refire_request` at `src/app/http.rs:3974-4009`,
`send_active`/`send_file` per the comment at line 3988-3995) explicitly calls
`http::script::apply_pre` + `http::template::expand` on the URL/headers/body
before sending. The Editor-pane branch further down in this SAME function
(`src/app/http.rs:3235-3248`) also does the expand. Only the Request-pane
early-return at line 3170-3172 skips it — it returns `rp.request` as-is,
and per `RequestPane`'s own doc comment (`src/request_pane.rs:34-37`,
"templates already expanded") that field is *assumed* pre-resolved by every
other consumer, but it factually never gets the expanded copy written back
after a send (`refire_request` expands a local clone, not `rp.request`
itself). `http.bench` is the one caller that takes this doc-comment
assumption at face value and skips its own expansion — the actual gap.

Likely fix shape (not applied — staging only): in `parse_active_as_request`'s
`Pane::Request` branch, run the same `apply_pre` + `template::expand` triplet
used by `refire_request` before returning the clone.
