---
finding: cookie-jar-not-injected-into-chain-runs
severity: SEV-2
surface: http.run_chain
---

**Repro**:
1. Set up a chain: step 1 = `POST /login` (server sets `Set-Cookie: session=abc`), step 2 = `GET /protected` (needs `Cookie: session=abc`).
2. Run a plain `:http.send` on step 1 — cookie jar records `session=abc`.
3. Run `:http.run_chain` on the chain.

**Expected**: step 2's request automatically picks up the `session=abc` cookie from the jar, same as a standalone `:http.send` would.

**Actual**: `http/chain.rs`'s `run` function calls `crate::http::send(&req)` directly (src/http/chain.rs:144). This goes to the low-level `http::send` function in `src/http/mod.rs` which knows nothing about the `App`'s `cookie_jar` (it's an `Arc<Mutex<CookieJar>>` on App). Cookie injection only happens in `App::spawn_http_job` (src/app/http.rs:2492–2499) where the jar is locked and a `Cookie` header is prepended. The chain runner never calls `spawn_http_job`.

Similarly, `Set-Cookie` headers in chain step responses are never recorded to the jar (that also happens only in `spawn_http_job`'s worker closure at line 2503–2513).

Result: multi-step authenticated flows that rely on the cookie jar break silently when run via `:http.run_chain`. The chain succeeds at step 1, step 2 gets no cookie, typically returns 401, and the chain stops with "stopping at non-success 401".

**Offending file:line**:
- `src/http/chain.rs:144` — bare `http::send(&req)` with no cookie injection.
- `src/http/chain.rs:171` — `apply_captures` feeds vars into the running env but Set-Cookie is never fed into a cookie jar.

**Notes**: Fixing this requires threading the `Arc<Mutex<CookieJar>>` into `chain::run` or adding a cookie-aware send wrapper. The chain runner has no App reference by design (pure function, easily testable) — the fix might be a new `CookieJar` parameter passed through.
