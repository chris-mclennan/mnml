---
finding: http-next-block-cursor-reset-corrupts-headers-body
severity: SEV-2
surface: multi-block-http
---

**Repro**: numbered steps (headless IPC harness, `~/.cargo/bin/mnml --headless <ws>`).

1. Workspace with `requests/multi.http`:
   ```
   ### get-block
   GET {{BASE_URL}}/get HTTP/1.1
   Authorization: Bearer {{TOKEN}}

   ### post-block
   POST {{BASE_URL}}/post HTTP/1.1
   Content-Type: application/json

   {"a":1}

   ### delete-block
   DELETE {{BASE_URL}}/delete HTTP/1.1
   ```
2. `{"cmd":"open","path":"requests/multi.http"}` → opens block 1 (get-block).
3. `{"cmd":"run-command","id":"http.next_block"}` → pane now shows block 2
   (post-block), `edit_tab` defaults to `Body` (shows `{ "a": 1 }`).
4. Tab-cycle keyboard focus into the Headers field: `{"cmd":"key","key":"tab"}`
   ×2 from URL (Url→Method→Headers).
5. Type a new header: `{"cmd":"type","text":"X-Injected: yes"}`.
6. Switch the visible tab to Headers (`{"cmd":"key","key":"ctrl+]"}`) to see
   what was actually typed.

**Expected**: New header text is appended after the existing `Content-Type:
application/json` line (matching every other code path in `src/app/http.rs`
that sets `headers_cursor = rp.headers_buffer.len()` on load — e.g. lines
630, 1135, 1150, 3847, 4478, 4558, 5698, 5858, 5924). The Headers editor
should end up with two rows: `Content-Type: application/json` and
`X-Injected: yes`.

**Actual**: The typed text is inserted at buffer position 0 (start), gluing
onto the existing header line with no separator. The Headers tab renders a
single, corrupted row:

```
Name: X-Injected   Value: yesContent-Type: application/json
```

The original `Content-Type: application/json` header is destroyed — it no
longer exists as its own row. Firing the request (`http.send`) confirms the
corruption is live, not just a display glitch: the outgoing request headers
no longer include `Content-Type`, and the httpbin.org echo shows no
`Content-Type` header on the sent request.

Root cause: `move_request_pane_to_next_block()` (`http.next_block` /
`http.prev_block`) hardcodes the non-URL cursors to 0 instead of
end-of-buffer:

```rust
// src/app/http.rs:2779-2781
rp.url_cursor = rp.request.url.len();   // correct — end of buffer
rp.body_cursor = 0;                     // BUG — should be rp.request.body-derived len
rp.headers_cursor = 0;                  // BUG — should be rp.headers_buffer.len()
```

Every other call site in `src/app/http.rs` that populates `headers_buffer`
on load sets `headers_cursor = rp.headers_buffer.len()` (see lines 630,
1135, 1150, 3847, 4478, 4558, 5698, 5858, 5924) and similarly for
`body_cursor` (1841, 1878, 1947). `http.next_block`/`http.prev_block` is the
one outlier that resets to 0, so any block-to-block navigation in a
multi-block `.http` file leaves the cursor at the wrong end for Headers/Body
edits — the very next keystroke corrupts existing header/body content
instead of appending.

**Secondary/related observation (design gap, not necessarily a bug)**: Tab
cycles `EditField` (Url→Method→Headers→Body→Url per the documented
workflow) but does **not** change the visible `EditTab` strip
(Params/Body/Headers/Auth/Vars/Script), which is only driven by
`Ctrl+]`/`Ctrl+[` or mouse click. So Tab-ing into Headers while the visible
tab is still Body gives **zero visual feedback** — keystrokes silently land
in the invisible `headers_buffer` while the screen continues to show Body
JSON unchanged. This amplified the cursor bug above (a user has no way to
notice the corruption until they explicitly switch to the Headers tab).
Given the task spec's stated workflow ("Tab cycles URL → Method → Headers →
Body → URL. Edit a header line, `r` re-fires with the edited header"), this
looks like an intended keyboard-first flow that the codebase doesn't fully
support — worth a triage call on whether Tab should also flip `edit_tab` to
match `focus`.

**IPC trace** (screen.txt snapshots, abbreviated):
- After step 3 (block 2 loaded): Body tab shows `{ "a": 1 }`.
- After step 5 (typed `X-Injected: yes` while focus=Headers, edit_tab=Body):
  screen is byte-identical to before typing (no visible change — Body pane
  untouched, headers changed invisibly).
- After step 6 (`ctrl+]` → Headers tab visible):
  ```
  │  │ Name                       │ Value                                             │   │
  │  │ X-Injected                 │ yesContent-Type: application/json                 │ ✕ │
  ```

**Notes**: `src/app/http.rs:2779-2781` (`move_request_pane_to_next_block`).
Fix: mirror the pattern used everywhere else in the file —
`rp.body_cursor = rp.request.body.as_deref().map(str::len).unwrap_or(0)` and
`rp.headers_cursor = rp.headers_buffer.len()` (computed after the
`headers_buffer` rebuild a few lines below, so the fix needs to move after
that rebuild or recompute from `next.request.headers`).
