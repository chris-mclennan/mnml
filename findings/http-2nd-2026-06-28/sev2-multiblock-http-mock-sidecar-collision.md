---
finding: multiblock-http-all-blocks-share-mock-sidecar
severity: SEV-2
surface: http.save_mock | http.replay_mock
---

**Repro**:

1. Create `requests.http` with two named blocks:
   ```
   ### list-users
   GET https://api.example.com/users

   ### create-user
   POST https://api.example.com/users
   Content-Type: application/json
   {"name":"alice"}
   ```
2. Cursor in `### list-users` block, `:http.send`. Response: `[{"id":1}]`.
3. `:http.save_mock` — saved to `requests.http.mock.json`.
4. Cursor in `### create-user` block, `:http.send`. Response: `{"id":2,"name":"alice"}`.
5. `:http.save_mock` — overwrites `requests.http.mock.json` with the POST response.
6. Navigate back to the `list-users` Request pane. `:http.replay_mock`.

**Expected**: The `list-users` replay returns `[{"id":1}]` (the GET response captured in step 3).

**Actual**: The `list-users` replay returns `{"id":2,"name":"alice"}` (the POST response from step 5,
which overwrote the same sidecar file).

**Root cause** (`src/app/http.rs:2152` and `src/http/mock.rs:96`):

`sibling_path` is called with `rp.source_path` (the `.http` file path), not a block-qualified path:
```rust
let mock_path = crate::http::mock::sibling_path(&source_path);
// → "requests.http.mock.json"  ← same for ALL blocks in requests.http
```

`sibling_path` just appends `.mock.json` to the file path:
```rust
pub fn sibling_path(request: &Path) -> PathBuf {
    let mut p = request.as_os_str().to_os_string();
    p.push(".mock.json");
    PathBuf::from(p)
}
```

Both `http_save_active_response_as_mock` (line 2152) and `http_replay_active_request_from_mock`
(line 2175) use the same derivation. There is no block-name component in the mock path.

For `.curl` files (one request per file) this is correct. For multi-block `.http`/`.rest` files
every block maps to the same sidecar, so the last `:http.save_mock` wins and earlier mocks
are silently lost.

**Fix direction**: Include `source_block_name` (from `rp.source_block_name`) in the mock filename.
E.g. `requests.http.list-users.mock.json` / `requests.http.create-user.mock.json`. Blocks with
`None` name (leading unnamed block) could fall back to `requests.http.mock.json` or use a
synthetic suffix like `requests.http._leading.mock.json`.

**Notes**: The unit test `sibling_path_appends_mock_json_suffix` (mock.rs:139) only tests `.curl`
files. No test covers the multi-block `.http` collision.
