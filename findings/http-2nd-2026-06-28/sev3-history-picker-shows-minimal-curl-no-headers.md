---
finding: history-picker-scratch-omits-headers-and-body
severity: SEV-3
surface: http.history
---

**Repro**:

1. Send a request with custom headers and JSON body:
   ```
   POST https://api.example.com/users
   Authorization: Bearer secret123
   Content-Type: application/json

   {"name":"alice","role":"admin"}
   ```
2. `:http.history` — picker opens, most-recent entry visible.
3. Press Enter to open the scratch buffer for re-fire.

**Expected**: The scratch `.curl` buffer contains all headers and the body that were in
the original request, allowing immediate re-fire without re-entering them.

**Actual**: The scratch buffer contains only:
```
curl -X POST 'https://api.example.com/users'
```
Headers (`Authorization`, `Content-Type`) and the body are absent.

**Root cause** (`src/app/picker.rs:742`):

The accept handler for `PickerKind::HistoryRows` reconstructs the scratch from
the history log entry, which only stores `method` and `url`:
```rust
let curl = format!("curl -X {method} '{url}'");
self.open_curl_scratch(&curl, &method, &url);
```

The history log schema (`src/http/history.rs`) captures only
`method`, `url`, `status`, `duration_ms`, `body_bytes`, `error` —
no `headers` or `body` fields are persisted:
```rust
let payload = serde_json::json!({
    "ts": ts,
    "method": entry.method,
    "url": entry.url,
    "status": entry.status,
    "duration_ms": entry.duration_ms,
    "body_bytes": entry.body_bytes,
    "error": entry.error,
});
```

`body_bytes` is a byte count, not the body content. `headers` is entirely absent.

**Impact**: Re-fire from history is only useful for stateless GET requests. POST/PUT/PATCH
requests with auth headers or bodies require manually re-entering all fields. The
"scratch for re-fire" feature is misleading for the majority of authenticated API
workflows.

**Fix direction**: Extend `history::Entry` with `headers: &'a [(String, String)]` and
`body: Option<&'a str>`. Re-render the scratch with `as_curl()` from the reconstructed
request. Watch for secret-leakage concerns (Authorization header stored in plaintext
in `.rqst/history.jsonl`); consider redacting auth values or making header persistence
opt-in.
