---
finding: ai-build-in-flight-flag-cleared-before-drain-loop-finishes
severity: SEV-3
surface: http.send
---

**Repro**:
1. Run `:http.ai_build` — worker is in flight.
2. Before the worker completes, run `:http.ai_build` again — toast "a build is already in flight".
3. Worker completes and sends two replies on the channel (the channel is reused via `get_or_insert_with` but the Sender is cloned; if the worker somehow sent twice — shouldn't happen — or if two workers ran).

**Expected**: `drain_http_ai_build` processes all replies one by one; `http_ai_build_in_flight` is cleared on the first one; the second is also processed normally.

**Actual (documented behavior)**: `drain_http_ai_build` (src/app/http.rs:481) collects ALL pending replies from the channel into a Vec, then iterates. On the **first** iteration `self.http_ai_build_in_flight = false` is set (line 487). But within the same tick loop, if somehow two results landed (e.g. a retry mechanism was later added, or two workers were somehow spawned), **both** results get processed and both call `open_new_request_pane()` in the same tick. This creates two new Request panes in the same tick, with the layout split twice unexpectedly.

The current code never spawns two workers (the in-flight guard at line 444 prevents it), so this is a latent fragility rather than a current bug. **The actual SEV-3** is: `drain_http_ai_build` clears `http_ai_build_in_flight = false` inside the loop body on each iteration, meaning if the comment "Single-shot per call" (line 484) ever becomes wrong (debug replay, test injection, channel leakage), there's no defense. The flag should be cleared once before the loop, not inside it.

More concretely: there is no timeout on the `http.ai_build` worker. A hung Claude API call (network issue, rate limit with retry, slow connection) blocks the `http_ai_build_in_flight` flag indefinitely. The user sees "a build is already in flight" for every subsequent `:http.ai_build` attempt with no way to cancel (`:http.abort` doesn't clear `http_ai_build_in_flight`). The user must restart mnml to recover.

**Offending file:line**: `src/app/http.rs:483–519` — the drain loop; `src/app/http.rs:3158` — `http_abort_all` which doesn't clear `http_ai_build_in_flight`.
