---
agent: api-workflow-user
severity: SEV-3
verifies: 4ab2730
surface: multi-block-http
---

**Finding**: `splice_http_block` consumes the blank separator line between the unnamed leading block and the first `### name` separator. Editing and saving the leading block changes file formatting.

**Repro**:
1. Create `api.http`:
   ```
   GET https://api.example.com/users

   ### create-user
   POST https://api.example.com/users
   Content-Type: application/json

   {"name": "Alice"}
   ```
2. Open in mnml. Cursor is on line 0 (leading block).
3. `:http.send` → Request pane opens.
4. Edit URL (e.g. change `/users` to `/users?page=2`).
5. `Ctrl+S` → saves back.

**Expected**: Both blocks survive. File retains the blank line between the leading block and `### create-user`.

**Actual**: Both blocks survive (the SEV-1 regression from pre-4ab2730 is fixed). However, the blank separator line at line 1 is gone. On-disk result:
```
GET https://api.example.com/users?page=2
### create-user
POST https://api.example.com/users
...
```
Instead of:
```
GET https://api.example.com/users?page=2

### create-user
POST https://api.example.com/users
...
```

**Root cause** (`src/app/http.rs`, `splice_http_block`):

`parse_all` assigns the leading block `end_line = separators[0] - 1`. With `### create-user` at line 2, the leading block's `end_line = 1` — absorbing the blank line. The splice replaces `lines[0..=1]` with the new content from `as_http_block(None)`, which emits `"METHOD URL\n"` with no trailing blank line. Lines `[2..]` are appended next, starting with `### create-user`, with no blank line between.

Named-block saves are unaffected: the blank line before a `### name` separator is in `lines[..start_line]` which is passed through verbatim.

**Test gap**: `splice_http_block_handles_unnamed_leading_block` asserts the named block survives (`.contains("### second\nGET...")`) but does not assert that the blank line between the two blocks is preserved.

**Notes**: The file remains parseable after the blank-line loss. This is a formatting-only regression introduced as a byproduct of fixing the catastrophic overwrite (SEV-1). No data loss.
