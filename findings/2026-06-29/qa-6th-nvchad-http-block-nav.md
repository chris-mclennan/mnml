---
agent: nvchad-user
severity: SEV-2
---

# `http.next_block` / `http.prev_block` silently no-op on `.curl` files

## Reproduction
Workspace `/tmp/mnml-nvchad-hunt/a.curl`:
```
### get-users
GET https://example.com/users
Accept: application/json

### post-user
POST https://example.com/users
Content-Type: application/json

{"name": "alice"}

### delete-user
DELETE https://example.com/users/1
```

```jsonl
{"cmd":"open","path":"a.curl"}
{"cmd":"wait_ms","ms":250}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"run-command","id":"http.next_block"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

`events.jsonl` shows `{"event":"command_run","id":"http.next_block","ok":"true"}`.

## Expected
Cursor jumps from line 1 (`### get-users`) to line 5 (`### post-user`). Repeating jumps to line 11 (`### delete-user`). `http.prev_block` from line 1 wraps to last block (line 11).

## Actual
`status.json` keeps reporting `cursor:{"line":1,"col":1}` after every call. No toast, no error in `events.jsonl`. `http.prev_block` is identically inert. (Sanity check: `http.send` on the same file at line 1 does fire and returns a 404 from example.com, so the file parses fine.)

## Source pointer
`src/app/http.rs:1752 move_to_http_block` — `place_cursor(target_row, 0)` is reached on the unfocused-pane fall-through path in many headless runs, but in a real session where the `.curl` pane has focus the cursor still doesn't move. The `parse_all` call at line 1775 succeeds for this file (verified via `http.send`), so `target_row` is computed correctly; the regression is likely the `active_editor_mut().is_some_and(...)` path returning the response/outline pane after a previous `http.send` opened those split children — meaning the post-fix d60f36c chord still doesn't move the cursor in the typical workflow (open file → send → next_block).

## Notes
d60f36c added `.curl` to the extension allow-list, but the harness verifies extension-acceptance, not cursor-movement, so the regression slipped past the post-fix test.
