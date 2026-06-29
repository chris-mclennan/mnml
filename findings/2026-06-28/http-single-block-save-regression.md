---
agent: api-workflow-user
severity: SEV-2
---

**surface**: http.send / editable-headers / request-pane

**Finding**: Ctrl+S on a Request pane opened from a single-block `.http` file silently fails to save, showing a misleading toast.

**Repro**:

1. Create `request.http` with one block (no `###` separator):
   ```
   GET https://api.example.com/health
   ```
2. Open the file in the editor. Run `:http.send`.
3. Tab to Edit view in the Request pane.
4. Edit the URL (append " EDITED").
5. Press Ctrl+S (`file.save`).
6. Check that `request.http` on disk contains the edited URL.

**Expected**: The file is updated to reflect the edit, same as `.curl` files.

**Actual**: The file is NOT updated. A toast fires:
> "can't locate the source block (file changed?) — re-fire from the editor to refresh"

This is misleading: the file has not changed externally. The real issue is `splice_http_block` returns `None` for 1-block files (`blocks.len() < 2` guard at line 152 of `src/http/mock.rs`... actually `src/http/file.rs` via `parse_all`), and `save_request_to_source` treats all None returns as "block not found" instead of "single-block file".

**Root cause** (`src/app/http.rs:4196-4220`):

The fix for the leading-block SEV-1 (commit 5020def) changed the splice-path guard from:

```rust
// before:
if source_block_name.is_some() && matches!(ext.as_str(), "http" | "rest") {
```

to:

```rust
// after:
if matches!(ext.as_str(), "http" | "rest") {
```

This is correct for the multi-block case but now sends single-block `.http` files into `splice_http_block`, which returns `None` because `blocks.len() < 2`. The `else` branch then toasts and returns without saving.

Before the fix, single-block `.http` files fell through to the whole-file overwrite path at the bottom of `save_request_to_source`, which worked correctly.

**Fix direction**: Either (a) add a `source_block_name.is_some() || parse_all(&existing).ok().map_or(false, |b| b.len() > 1)` guard before entering the splice path, or (b) handle the `None` return from `splice_http_block` for single-block files by falling through to whole-file overwrite instead of toasting.

**IPC trace** (from `t02_single_block_http_save` e2e test):

Step `command file.save` runs `save_request_to_source` → `splice_http_block` returns None → toast fires, function returns → `request.http` unchanged.

Assertion: `expect file request.http contains "api.example.com/health EDITED"` — FAILS.

**Notes**:

- `.curl` files are unaffected (they never enter the `if matches!(ext, "http"|"rest")` branch).
- Multi-block `.http` files with a named block (no leading block) are unaffected.
- Multi-block `.http` files with a leading unnamed block now work correctly after 5020def.
- The single-block regression is new with commit 5020def.
- Confirmed via `tests/run_qa_tests.rs::t02_single_block_http_save`.
