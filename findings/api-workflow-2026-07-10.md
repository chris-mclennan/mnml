# API-workflow tester — 2026-07-10 session hunt

Verified via headless IPC (`.mnml/ipc/command` → `screen.txt` / `status.json`
/ `events.jsonl`) against a fresh workspace with `multi.http` (3 named
`###` blocks) + `.mnml/env/dev.env` (`BASE_URL`, `TOKEN`, `API_KEY`).

## 1. Multi-block write-back destroys sibling blocks via the new default open path — **SEV-1**
`open_request_pane_from_file` (`src/app/http.rs:694`, the new default when
clicking/opening a `.http` file per item 3) builds its `RequestPane` via
`RequestPane::new(...)` which always sets `source_block_name: None`
(`src/request_pane.rs:550`) — it never captures which `###` block was
parsed. `save_request_to_source` (`src/app/http.rs:5954`) then calls
`splice_http_block(existing, None, ...)`, which only matches an *unnamed*
leading block; since block-one is `### block-one` (named), the splice
returns `None` and the code falls through to **overwrite the whole file
with a single curl command**, silently deleting blocks two and three.
This is the exact "clobbers the file with a single curl" regression class
called out as fixed — it still reproduces via the tree-click/open path.

**Repro**: open `multi.http` (3 named blocks) → it auto-opens as a Request
pane (block-one, preview). Press `r` to fire. Click into the URL field,
type a char, `Esc`, run `file.save`. Result: `multi.http` now contains
only `curl '{{BASE_URL}}/health' ...` — blocks two/three gone.

## 2. Write-back bakes resolved secrets into the source file (template destroyed) — **SEV-1**
`send_request_from_active` (`src/app/http.rs:3808-3823`, the `http.send`
path used from a raw `.http` editor buffer — reached via `http.view_source`
+ `http.next_block`) calls `template::expand()` on `request.url` /
`headers` / `body` **in place**, then stores that same resolved `request`
into the newly-created `RequestPane`. Any later `file.save` write-back
(`as_http_block`) serializes the *resolved* values, permanently replacing
`{{TOKEN}}`/`{{BASE_URL}}` with literal secrets in the tracked file.
Confirmed: editing only the URL of block-three and saving rewrote
`Authorization: Bearer {{TOKEN}}` → `Authorization: Bearer devtoken123` on
disk, though that header was never touched. Contrast: panes opened via the
default tree-click path (`open_request_pane_from_file`) correctly preserve
templates through `r` (refire clones before expanding) — this bug is
scoped to the `view_source`/editor-send path.

**Repro**: `http.view_source` on `multi.http` → `http.next_block` ×2 →
`http.send` (fires block-three) → edit URL field, append `/v2` → `Esc` →
`file.save`. Block-three on disk now shows literal `devtoken123`.

## 3. `http.copy_ai_prompt` doesn't redact secrets in the request body — **SEV-2**
Module doc (`src/http/ai_prompt.rs:5`) claims it "redacts obvious
credentials in headers **+ body**", but only `redact_header_value` exists;
`build_prompt` dumps `rp.request.body` raw via `truncate_with_marker`.
Fired a POST with body `{"apiKey":"{{API_KEY}}"}` (resolves to
`sk-live-abcdef123456`) against `api.example.com` (fails/times out) →
`http.copy_ai_prompt` → clipboard contains
`"apiKey": "sk-live-abcdef123456"` verbatim, alongside correctly-redacted
`Authorization: Bearer <redacted>`.

## Minor / lower confidence
`discover --edge-cases`: `date-time`/`uuid` pass through cleanly now
(fixed). `email` derived via Tier-3 coherence from x-padded
`firstName`/`lastName` inherits the padding in edge-max
(`johnxxx...xxx.smithxxx...@example.com`) — still a syntactically valid
email, so this may be intended interaction rather than a regression; SEV-3
if worth a look. History-append-on-failure works correctly (`status:null`,
`error` populated).
