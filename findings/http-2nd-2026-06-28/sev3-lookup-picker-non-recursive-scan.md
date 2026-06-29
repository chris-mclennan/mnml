---
finding: lookup-picker-non-recursive-scan-misses-nested-curl-files
severity: SEV-3
surface: http.lookup
---

**Repro**:

1. Create directory structure:
   ```
   .rqst/lookups/top-level.curl      ← visible
   .rqst/lookups/users/get-users.curl ← NOT found
   .rqst/lookups/tags/list-tags.curl  ← NOT found
   ```
2. `:http.lookup`

**Expected**: All three `.curl` files appear in the picker.

**Actual**: Only `top-level.curl` appears. Files under subdirectories are silently omitted.

**Root cause** (`src/app/http.rs:1720`):

`http_lookup_open` uses a flat `std::fs::read_dir`:
```rust
if let Ok(read) = std::fs::read_dir(&dir) {
    for entry in read.flatten() {
        // only iterates direct children, skips directories
    }
}
```

The `read_dir` loop has no recursion: subdirectory entries are silently ignored (they
fail the extension check `.curl | .http | .rest` since directories have no extension).

`src/http/lookup.rs` contains a `LookupPicker` struct with a correct recursive
`scan_lookups` function (uses an explicit stack, visiting subdirectories):
```rust
fn scan_lookups(workspace: &Path) -> Vec<PathBuf> {
    let mut stack: Vec<PathBuf> = vec![lookup_dir];
    while let Some(dir) = stack.pop() {
        // ...
        if is_dir { stack.push(path); }  // recursive
    }
}
```

However `LookupPicker` is never referenced outside of `lookup.rs` itself — it is dead code.
The `http.lookup` command is wired to `http_lookup_open` (app/http.rs line 3389), which
does the flat scan.

**Additional observation**: `scan_lookups` only finds `.curl` files, while `http_lookup_open`
accepts `.curl | .http | .rest`. The two implementations disagree on accepted extensions.

**Fix direction**: Replace the `read_dir` loop in `http_lookup_open` with a call to
`crate::http::lookup::scan_lookups` (or an equivalent recursive walk), or wire `LookupPicker`
to the `http.lookup` command and retire the duplicate inline scanner.
