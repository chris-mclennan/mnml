---
severity: SEV-2
status: open
---

# `http.history` and `http.history_global` silently do nothing, even with real history data present

## Summary

Both documented HTTP-history commands ack `ok:"true"` but never open
anything — no pane, no picker overlay, no toast — regardless of whether
history data exists on disk. Verified with a real, freshly-populated
`.rqst/history.jsonl` (workspace-scoped) and `history-global.jsonl`
(cross-workspace, under `MNML_DATA_ROOT`), and separately from a totally
clean launch with an *empty* history. Same result both times: nothing
happens.

- `http.history` — "HTTP: open .rqst/history.jsonl (one-line-per-send log)"
- `http.history_global` — "HTTP: history picker across all workspaces
  (~/.config/mnml/history-global.jsonl)"

Sending real HTTP requests through mnml itself (verified working — see
below) correctly populates both files, so this isn't a "no data yet" case;
the *commands that are supposed to surface that data* just don't.

## Repro (verified twice — once with populated history, once fresh/empty)

Workspace: `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt-py`
(Python root, `request.curl` / `request2.curl` fixture files present).

1. Send two real requests through mnml (`.curl` pane, `Ctrl+Enter`):
   - `GET https://api.example.com/users/1` → `dns: UnknownHostName` (error,
     still logged)
   - `GET https://httpbin.org/get` → `200 OK · 141 ms · 305 B` (success)

   Confirmed both landed in
   `<MNML_DATA_ROOT>/history-global.jsonl`:
   ```json
   {"ts":1788630241912,"method":"GET","url":"https://api.example.com/users/1","status":null,"duration_ms":26,"body_bytes":null,"error":"dns: UnknownHostName","headers":[["Accept","application/json"]],"request_body":null,"workspace":"hunt-py"}
   {"ts":1788630258172,"method":"GET","url":"https://httpbin.org/get","status":200,"duration_ms":141,"body_bytes":305,"error":null,"headers":[["Accept","application/json"]],"request_body":null,"workspace":"hunt-py"}
   ```
   and workspace-local `.rqst/history.jsonl` also exists on disk.

2. With the HTTP pane still active/focused (`status.json`
   `"focus":"pane","activePane":2` pointing at the httpbin request):

   ```json
   {"cmd":"run-command","id":"http.history_global"}
   {"cmd":"wait_ms","ms":300}
   {"cmd":"snapshot"}
   ```

   `status.json` before and after is byte-identical apart from focus
   bookkeeping — `panes` unchanged, no new pane, `rightPanelVisible:false`.
   `screen.txt` unchanged.

3. Same result for `http.history`:

   ```json
   {"cmd":"run-command","id":"http.history"}
   {"cmd":"wait_ms","ms":300}
   {"cmd":"snapshot"}
   ```

   No new pane opens for `.rqst/history.jsonl` even though the file exists
   on disk at that exact path.

4. Re-verified from a **completely fresh launch** (no prior session state,
   `panes:[]`, `activePane:null`) — same silent no-op for both commands.

## Expected vs actual

- Expected: `http.history` opens `.rqst/history.jsonl` as a text/log pane;
  `http.history_global` opens a picker over
  `<data-root>/history-global.jsonl` entries (filterable across
  workspaces, matching the doc's "history picker across all workspaces").
- Actual: both ack `ok:"true"` and produce no observable UI change,
  regardless of whether backing data exists.

## Command ids

`http.history`, `http.history_global`
