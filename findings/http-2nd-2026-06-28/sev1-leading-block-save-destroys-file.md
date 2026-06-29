---
finding: leading-block-save-destroys-multiblock-http-file
severity: SEV-1
surface: http.send
---

**Repro**:

1. Create `requests.http`:
   ```
   GET https://api.example.com/users
   Accept: application/json

   ### create-user
   POST https://api.example.com/users
   Content-Type: application/json

   {"name":"alice"}
   ```
2. Open `requests.http` in mnml editor. Cursor in the leading `GET` block (lines 0-2).
3. `:http.send` — fires the GET, opens a Request pane.
4. In the Request pane, switch to Edit view, change the URL to `https://api.example.com/users?page=2`.
5. `Ctrl+S` to write back to source.

**Expected**: `requests.http` has its leading block URL updated; the `### create-user` POST block is preserved intact.

**Actual**: `requests.http` is overwritten with a single curl command line:
```
curl 'https://api.example.com/users?page=2' \
  -H 'Accept: application/json'
```
The `### create-user` POST block is permanently deleted.

**Root cause** (`src/app/http.rs:4100`):

The guard for the splice path is:
```rust
if matches!(ext.as_str(), "http" | "rest") && source_block_name.is_some() {
```

For the leading unnamed block, `source_block_name` is captured as `None` at line 2848-2850
(no `###` separator present). The condition is therefore FALSE and the code falls through
to the whole-file curl overwrite at line 4129:
```rust
match std::fs::write(&path, format!("{curl_text}\n")) {
```

`splice_http_block` CAN handle `None` (line 169 of `http.rs`: `None => block_separator_name(b).is_none()`)
but is never reached for this case. Removing `&& source_block_name.is_some()` from the
guard and always attempting the splice path for multi-block `.http`/`.rest` files would fix this.

**IPC trace**: Not a headless-harness-specific failure — pure filesystem write path. Reproduced
via code inspection and confirmed `source_block_name = None` at line 2848-2850 for leading
unnamed blocks in multi-block files. The unit test `splice_http_block_handles_unnamed_leading_block`
(line 4227) validates `splice_http_block` can handle `None` but does NOT test `save_request_to_source`
end-to-end, so the integration gap is not covered.

**Notes**: The comment on line 4126-4128 ("`.http` whose only block is the one we're saving")
is incorrect — the leading unnamed block of a multi-block file reaches this path and the
other blocks are destroyed.
