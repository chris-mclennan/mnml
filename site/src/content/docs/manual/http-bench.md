---
title: HTTP bench
description: Fire the active request 10× concurrent and read the p50 / p95 / p99 latency breakdown.
---

![:http.bench against httpbin.org/get — headline toast lands, then the full p50/p95/p99 trace opens in a buffer](../../../assets/tapes/http-bench-output.gif)

`http.bench` fires the active editor's request N times across M worker threads, then writes a single trace string to the clipboard with sorted-sample percentiles and a status-class breakdown. It's the "is this endpoint actually fast?" tool — and the "is the failure rate something or nothing?" tool — without leaving the editor.

The defaults (10 requests, 4 concurrent) are deliberately small. They're a quick sanity check, not a load-test rig. For real load testing, use `oha` / `wrk` / `vegeta` in a `:term` pane.

## What "active" means

`http.bench` calls `App::parse_active_as_request`. The resolution chain:

1. If the active pane is a **Request pane**, bench clones the request the pane is holding (post-template-expansion, post-`@set-*`). The Edit-mode field values count — tweak the URL, press bench, get latency for the edited URL.
2. If the active pane is an **Editor pane** with a `.http` / `.rest` extension, bench parses the file with `http::file::parse_all` and picks the block under the cursor.
3. If it's a `.curl` file (or a `.http` file with one block), bench parses the whole buffer.
4. Anything else (`.rs`, `.md`, a `:term` pane) — bench toasts `http.bench: no active .http/.curl/.rest editor` and bails.

The pre-bench substitution pass is identical to `http.send`: `@set-env` + `@set-header` directives run, then `{{VAR}}` and `{{$uuid}}` resolve against the active env. Each of the N firings sees the **same** request body — `{{$uuid}}` resolves once, before the fan-out. If you want a fresh UUID per request, you'd need a wrapper (a future flag) — for now `bench` is "the same request 10 times."

## Running it

| Surface | Call |
|---|---|
| Palette | `HTTP: bench active request 10× (concurrent)` |
| Ex-command | `:http.bench` |
| Right-click context menu | "Bench (10×)" on the Request pane |

No default keybinding. Bind under `[keys.global]` if you want a chord.

Defaults are `n = 10`, `concurrency = 4`. The palette command runs `http_bench_active(10, 4)`. The internal API (`App::http_bench_active(n, concurrency)`) takes arbitrary numbers — bind a custom palette command if you want `100`-shot or single-concurrency runs.

## What gets reported

`http.bench` runs on a background thread (a 30-second timeout × 10 sequential requests would be five minutes of frozen UI without it). `App::tick` drains the result channel and writes the **full trace to the clipboard**, then surfaces the headline summary line as a toast:

```text
bench summary — 10 samples in 1842 ms (rate: 5.4 req/s) (full trace → clipboard)
```

The clipboard payload is the whole trace, ready to paste into a buffer for inspection:

```text
bench  GET https://api.example.com/users
  10 requests · 4 concurrent

bench summary — 10 samples in 1842 ms (rate: 5.4 req/s)
  latency ms — min 142 · p50 178 · p95 412 · p99 412 · max 412 · mean 198
  status: 2xx=9 3xx=0 4xx=0 5xx=1
  errors: 1 (showing up to 3)
    request timed out
```

Per-row meaning:

- **Header** — the request method and URL.
- **Samples / time / rate** — total samples that completed, wall-clock from spawn to last completion, throughput.
- **Latency** — min · p50 · p95 · p99 · max · mean, all in milliseconds. Sample-based — percentiles are calculated by sorting the durations and indexing at `round((N-1) * p)`.
- **Status classes** — `2xx=N 3xx=N 4xx=N 5xx=N`, a count per HTTP status class for the successful sends.
- **Errors** — transport-level errors (timeouts, DNS failures, broken TLS). Up to the first 3 error messages are included; the count is the total.

A zero-sample run (every request errored out, or `n = 0`) still emits the summary block with `0 samples` — useful when the endpoint is completely down, since the errors block lists why.

## Concurrency model

Worker threads pull from a shared `AtomicU32` counter, not a static chunking. The reason: a slow first thread shouldn't bottleneck the whole bench. Each worker loops:

```rust
loop {
    let i = counter.fetch_add(1, Ordering::SeqCst);
    if i >= n { break; }
    let t = Instant::now();
    match http::send(&req) {
        Ok(resp) => results.lock().push((t.elapsed().as_millis() as u64, resp.status)),
        Err(e)   => errors.lock().push(e),
    }
}
```

`concurrency` is clamped to `[1, n]` — asking for 100 workers with 10 requests gives you 10 workers; asking for 0 gives you 1. Spawning more workers than there are requests would be wasted thread overhead.

The HTTP client is `reqwest::blocking::Client::builder().timeout(30s).build()` — same as a normal `:http.send`. Connection pooling is per-thread, not shared across workers, so a 100-shot bench against the same host opens up to `concurrency` distinct TCP connections.

## When to use it

- **"Is this fast enough?"** — p95 of 412 ms tells you what your 95th-percentile user sees, which is the metric you'd quote when arguing for a cache or a query rewrite.
- **"Is this consistent?"** — `min 142 · p50 178 · max 412` shows the slow tail; `min 142 · p50 178 · max 195` shows a tight cluster. Tail latency is where production pages come from.
- **"Is this flaky?"** — `5xx=1` out of 10 samples is a 10% failure rate. The errors block shows whether the failures are transport (timeouts, connection resets) or HTTP-status (5xx counted but no errors block).
- **"Did my change make it worse?"** — bench before and after a code change. The clipboard trace is a paste-into-a-PR-comment shape.

## What it doesn't do

- **Real load testing.** N = 10 is too small to see anything interesting at the tail. For real load characterization, drive `oha` or `wrk` from a `:term` pane.
- **Warm-up.** The first request might pay a DNS lookup + TLS handshake the rest amortize over. Run twice and discard the first run if you're optimizing for warm latency.
- **Cookie / state propagation between samples.** Each send is independent; a bench run against an authenticated endpoint repeats the same Authorization header N times. State that mutates between samples (an idempotency-key-protected POST that 409s on retry) shows up as `4xx` in the breakdown.
- **Per-sample `@assert` evaluation.** Asserts run on the script's bound response in `http.send`; `http.bench` short-circuits past the assertion pass and only records status + duration. The "is this fast?" answer doesn't need assert overhead.

## Next

- [HTTP client](/manual/http/) — the parent overview, including `http.send` (which uses the same request-parse path)
- [HTTP history](/manual/http-history/) — every fired request lands here; bench runs do *not* (they'd bloat the log)
- [HTTP mocks](/manual/http-mocks/) — freeze a response so bench against a flaky endpoint isn't noisy
- [HTTP envs & templating](/manual/http-envs/) — the env that bench's `{{VAR}}` substitutions resolve against
