---
finding: curl-multi-block-leading-block-dispatch
severity: SEV-2
surface: multi-block-http
---

**Repro**:
1. Create a `.curl` file with a leading unnamed block followed by a named block:
   ```
   curl 'https://api.com/list'

   ### create-item
   curl -X POST 'https://api.com/items' \
     -H 'Content-Type: application/json' \
     --data-raw '{"name":"test"}'
   ```
2. Open the file in an editor pane. Leave cursor at line 0 (first `curl` line).
3. Fire `:http.send`.

**Expected**: The first block (`/list`) fires.

**Actual**: The `### create-item` block (`/items`) fires.

**Root cause**: `src/app/http.rs` lines 3193-3198 in `send_request_from_active`, the `.curl` multi-block dispatch path:

```rust
let block_start = starts
    .iter()
    .rev()
    .find(|&&s| s <= cursor_row)
    .copied()
    .unwrap_or(starts[0]);  // <-- wrong fallback
```

`starts` contains the line numbers of all `###` separators. When the cursor is at a line before the first separator (e.g., line 0 while the first `###` is on line 3), `.rev().find(|&&s| s <= cursor_row)` returns `None`. The fallback is `starts[0]` — which is the FIRST separator's line number, not the pre-separator leading block.

The code then builds the slice as `lines[block_start..=block_end]` starting from the `### create-item` line, firing the wrong request.

**Note**: This bug is specific to `.curl` files. For `.http`/`.rest` files the code takes the `http::file::parse_all()` branch, which correctly handles leading unnamed blocks via `Block.start_line`.

**Correct fix**: When no separator `s <= cursor_row` is found, the cursor is in the pre-separator content. Extract lines `0..starts[0]` (everything before the first separator) as the slice.

```rust
let (slice, block_name) = if starts.is_empty() {
    (text.clone(), None)
} else {
    let maybe_start = starts.iter().rev().find(|&&s| s <= cursor_row).copied();
    if let Some(block_start) = maybe_start {
        // cursor is inside or after a separator — existing logic
        ...
    } else {
        // cursor is before the first separator — take the leading block
        let end = starts[0].saturating_sub(1);
        (lines[..=end].join("\n"), None)
    }
};
```

**IPC trace**: Not available (static code analysis finding). Deterministic repro from the file content above.

**No test coverage**: The `.curl` multi-block dispatch in `send_request_from_active` has no test. The only multi-block tests are in `src/http/file.rs` for `.http` format.
