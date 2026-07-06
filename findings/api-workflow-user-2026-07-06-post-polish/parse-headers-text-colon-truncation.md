---
finding: parse-headers-text-colon-truncation
severity: SEV-2
surface: editable-headers
---

**Repro**:
1. Open any `.http` file and fire `:http.send`.
2. In the resulting Request pane press `Tab` to enter Edit view, navigate to the Headers tab.
3. Add a header whose value contains a colon — e.g. type a new line:
   `X-Target: https://example.com/api`
4. Press `r` to re-fire.

**Expected**: Request carries `X-Target: https://example.com/api`.

**Actual**: Request carries `X-Target: https`. Everything after the first colon in the value is silently dropped. No warning, no toast.

**Root cause**: `src/request_pane.rs:373`

```rust
let (k, v) = l.split_once(':')?;
```

`str::split_once` splits at the **first** colon and discards the remainder. The variable `v` already has the tail cut off before `v.trim()` is called.

Every path that commits in-pane header edits calls `commit_headers()` → `parse_headers_text()`, so this affects:
- `r` re-fire from a Request pane (`refire_request`)
- `Ctrl+S` write-back to source (`save_request_to_source`)
- Auth-tab "Apply" (sets headers via `http_auth_set`, which rebuilds `headers_buffer` from `request.headers` but downstream `commit_headers` re-parses the buffer)

**Additional scope**:
- `src/ui/request_view.rs:2061` — the inline-cell KV table for the Headers tab renders values truncated at the first colon, so `X-Target: https://example.com` displays as `https` in the table.
- `src/app/http.rs:4117-4118` — the seed pre-populated when the user clicks a header cell to edit it is taken from the same `split_once(':')` on `headers_buffer`, so the edit pre-fill already loses everything after the first colon.

**Fix direction**: Replace `split_once(':')` at that callsite with an explicit first-colon split that preserves the tail:

```rust
let colon_pos = l.find(':')?;
let k = l[..colon_pos].trim();
let v = l[colon_pos + 1..].trim();
```

Apply the same fix to `src/ui/request_view.rs:2061` and `src/app/http.rs:4117`.

**Zero existing tests**: `parse_headers_text` has no unit test in the file. Any round-trip regression test would catch this immediately.
