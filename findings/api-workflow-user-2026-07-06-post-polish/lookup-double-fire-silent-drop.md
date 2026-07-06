---
finding: lookup-double-fire-silent-drop
severity: SEV-3
surface: http.lookup
---

**Repro**:
1. Have at least two `.curl` files under `.rqst/lookups/`.
2. Fire `:http.lookup`. Stage 1 picker opens.
3. Accept the first file (stage 2 fires the HTTP request; `lookup_fire_rx` is now `Some`).
4. While the HTTP request is in-flight (before the item picker appears), immediately fire `:http.lookup` again and accept a different file.

**Expected**: Toast "lookup: already running" and the second fire is blocked until the first completes.

**Actual**: `accept_lookup_file` is called a second time with no in-flight guard. Line 1997 in `src/app/http.rs`:
```rust
self.lookup_fire_rx = Some(rx);
```
This overwrites the old receiver, dropping it. The first worker thread is still running and will eventually send its result, but the receiver has been dropped, so `tx.send(result)` returns `Err(SendError)` and the first result is silently discarded. The second fire proceeds normally.

**Root cause**: `src/app/http.rs` `accept_lookup_file` at line 1959 has no guard equivalent to the ones in `http_bench_active` (line 2602: `if self.http_bench_rx.is_some()`) or `http_sync_sources` (line 3076: `if self.http_sync_rx.is_some()`).

**Race window**: The HTTP round-trip time. On a slow API (>1-2s) this is a realistic scenario for an impatient user.

**Fix**: Add at the top of `accept_lookup_file`:
```rust
if self.lookup_fire_rx.is_some() {
    self.toast("lookup: already running");
    return;
}
```

**Note**: `close_picker` (line 49) already clears `lookup_fire_rx` when the user Esc-cancels the LookupFile or LookupItem picker, so that Esc path is clean. This finding is specifically about double-accepting the LookupFile picker before the first response arrives, which requires opening a second `:http.lookup` while the first is in-flight.
