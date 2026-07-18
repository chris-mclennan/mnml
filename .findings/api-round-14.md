# API-workflow hunt — round 14 (2026-07-16)

Driven headless via the file-IPC channel (`<workspace>/.mnml/ipc/`) against
`./target/debug/mnml` at commit `d63bf3de`. Scratch workspace `ws14`
(under the session scratchpad), plus two local fixture servers (no live
egress this round):

- A Python `http.server`-based echo/edge-case server on
  `127.0.0.1:8977` — `/step1`, `/step2?sid=`, `/empty` (204), `/empty200`
  (200 + empty body), `/plaintext` (50 lines), `/nonjson`, `/html`,
  `/image` (1×1 PNG), `/binary` (256 raw bytes, full 0x00-0xFF range),
  `/bigjson` (20-item nested JSON, compact/single-line), `/deep` (6-level
  nesting), `/status500`, `/login`.
- A hand-rolled raw-socket WebSocket echo server (no `websockets` pip
  package available in this env) on `127.0.0.1:8965` — echoes text
  frames back prefixed `echo:`, replies to ping.

`.mnml/env/dev.env` in `ws14`: `BASE_URL=http://127.0.0.1:8977`,
`TOKEN=devtoken123`, plus `VAR1`..`VAR14` (16 vars total) for the KV
scroll re-check. No `.rqst/config`, no `$MNML_ENV`, no `[http]
default_env` — the exact round-11/12 repro shape.

`websocat` is not installed in this environment, so `:ws.send` (the
`.ws`-file → `websocat` shell-out path) was not exercised this round —
documented dependency gap, not a finding. `:ws.connect` (native
tungstenite, no external binary) was exercised in full instead.

## Executive summary

**Priority verifications: both CONFIRMED FIXED.** Round-12's SEV-1
("Send / CLI / bench / hover / click-to-def all disagree with the Vars
tab in a `.mnml`-only workspace") and round-13's SEV-2 A ("KV cell click
doesn't move keyboard focus to the pane") both hold up under a fresh,
independent repro — see the verification scoreboard below.

**6 findings this round: 1 SEV-1 · 3 SEV-2 · 2 SEV-3.** Two are
reconfirms of long-standing, still-unfixed issues (KV table scroll,
mock-replay marker — unchanged since round-11). Four are new:
`mnml discover`'s "wrote N stubs" summary silently double-counts
skipped (already-exists) files as written — on a second `discover` run
against unchanged stubs it reports "wrote 3" when 0 files were actually
written; a response body's byte-size display (UI border AND persisted
`.rqst/history.jsonl`) is inflated for binary/non-UTF8 bodies because it
measures the lossy-UTF8-decoded `String`, not the raw bytes (256 real →
512 shown); the Response pane's "TEXT" format mode (labeled "plain text
(no highlight)" in its own menu) still silently pretty-prints JSON
instead of showing the actual raw bytes; and clicking the Response
sub-tab strip (Body/Headers/Timeline/Tests) neither moves keyboard focus
to the pane nor switches the pane's internal view mode, so the
documented `/`-search + `j`/`k`-scroll + `y`/`Y`/`R` Response-view
keybindings are unreachable via mouse and any subsequent keystroke
silently mutates the URL field instead (the exact class of bug
round-13's KV-cell fix addressed, alive in a sibling click handler the
round-13 sweep didn't reach).

**Swept clean:** chain runner edge cases (mid-chain extract-then-use,
failure propagation at a mid-chain 500, a 204-empty-body step
mid-chain, and a non-JSON response feeding an `@extract` — all four
handled cleanly with no panics and correct error messages), WebSocket
connect/send/receive/disconnect (native tungstenite path) end-to-end,
`ws.history` picker, binary/image response detection (correctly
short-circuits to a safe `[binary … · N bytes · Ctrl+S]` placeholder —
size is wrong per Finding 3 below but no raw bytes hit the terminal),
`Ctrl+S`/`http.save_response` writing the *correct* raw bytes to disk
despite the wrong displayed size, Discover against a malformed/truncated
JSON spec (clean parse error, no panic, exit 1), Discover against a
spec with empty-methods paths and no-operationId GETs (both handled:
skipped / synthesized fallback name), and history-append-on-failure
(a connection-refused send correctly appends `status: null, error:
"connection failed: …"` to `.rqst/history.jsonl`).

## Priority verification scoreboard

- **Round-12 SEV-1 fix (`select_with_full_fallback` / `active_envset()`
  aligning Send / CLI / bench / hover / click-to-def with the Vars tab)
  — VERIFIED FIXED.** Exact round-11/12 repro shape (`.mnml/env/dev.env`
  only, no `.rqst/config`, no `$MNML_ENV`, no `[http] default_env`):
  - Vars tab: `env: dev.env`, `BASE_URL`/`TOKEN` both resolved (green).
  - `:http.send` on the same pane → `200 OK` (was: `✗ bad request:
    builder error`).
  - `mnml run req.curl --workspace ws14` (no `--env`) → `env: dev` →
    `200 OK` with the body echoed back.
  - `mnml chain run midvar.chain.json --workspace ws14` (no `--env`) →
    both steps `200 OK`, chain passed.
  - Hover `{{BASE_URL}}` in the URL field → tooltip reads `=
    http://127.0.0.1:8977 · click to jump to env` (was: false "not
    defined in active env").
  - Left-click `{{BASE_URL}}` → jumps to `dev.env` line 1 (was:
    incorrectly opened the "Set value…" edit prompt).
  All 6 surfaces agree. No resolver drift found this round.
- **Round-13 SEV-2 A fix (KV cell click moves keyboard focus to the
  pane) — VERIFIED FIXED.** Reproduced the exact scenario: single-click
  `req.curl` in the tree (opens as a *preview*, focus stays on
  `Focus::Tree` per `status.json`) → click the Vars tab → click the
  `BASE_URL` value cell (cell renders `value▏`, `status.json.focus`
  flips to `"pane"`) → typed `x`, `y`, `z` → cell shows
  `http://127.0.0.1:8977xyz▏` (characters landed in the cell, not the
  tree). `Esc` cancels cleanly — `.mnml/env/dev.env` unchanged on disk.

## Findings

### SEV-1

#### Finding 1 — `mnml discover`'s "wrote N .curl stub(s)" count silently double-counts skipped (already-exists) files, making the summary lie on every re-run against an unchanged spec

**surface**: cli-mode (discover)

**Repro**:
1. `mnml discover spec.json --out ws14/discover14/out-resync` (fresh dir)
   → `wrote 3 .curl stub(s) under …` — correct, 3 files created.
2. Run the *identical* command again, no `--force` (the default —
   `--force` off is explicitly "prevents silent overwrite of hand-edits"
   per the code's own doc comment at `src/http/discover.rs:51-53`):
   ```
   wrote 3 .curl stub(s) under … (3 existing skipped — use --force to overwrite)
   ```

**Expected**: the second run writes 0 new/changed files (all 3 already
exist, all correctly skipped) — the summary should read something like
`wrote 0 .curl stub(s) … (3 existing skipped)`, or at minimum not claim
"wrote 3" when literally every file in that run hit the skip branch.

**Actual**: "wrote 3" printed both times, identically, regardless of
whether anything was actually written. A user re-running `mnml discover`
to check for upstream API drift (the documented use case per the
`sync-check`-adjacent comment at the top of the file) has no way to tell
from the CLI output whether anything changed — the count is a constant
equal to "total operations processed," not "files actually written."

Also reproduces on a genuine same-run collision: two different paths
(`/a/get-thing`, `/b/get-thing`) sharing an identical `operationId:
"getThing"` (a realistic spec-authoring mistake — copy/paste, merged
specs) produce `wrote 2 .curl stub(s) … (1 existing skipped)` when only
1 file (`getThing.curl`, from whichever path won the filename race)
physically exists afterward — the second operation's endpoint was
silently dropped with no name-collision warning, and the summary still
claims 2 were written.

**Root cause**: `src/http/discover.rs:172-191` (the default single-body
stub path) and `:227-249` (the named-examples multi-stub path) both do:
```rust
if !opts.force && file.exists() {
    skipped += 1;
} else {
    std::fs::write(&file, curl)...?;
}
...
count += 1;   // <-- unconditional, runs even when the write was skipped
```
`count` (printed as "wrote N") increments regardless of which branch of
the `if` ran. Contrast the Tier-7 edge-case block at `:191-213` in the
same function, which gets this right — `count += 1` sits *inside* the
`else` (actually-wrote) branch there, not after the whole `if/else`.

**Notes**: `src/http/discover.rs:172-191`, `:227-249` (bug); `:191-213`
(the correct pattern, for comparison); `src/main.rs:634` (the CLI print
site that surfaces the wrong number verbatim). `mnml sync` (the
`.mnml/sources.json`-driven CLI mirror of `:http.sync`) goes through a
different implementation (`http::sources::run_sync_with_normalize`),
not `discover::run` — not verified to share this bug, and no UI/`App`
call site invokes `discover::run` directly (it's CLI-only), so
`:http.sync`/`:http.discover` from inside the app are not affected by
this specific counter.

---

### SEV-2

#### Finding 2 — Clicking the Response sub-tab strip (Body / Headers / Timeline / Tests) neither focuses the pane nor switches the pane to Response view — the `/`-search, `j`/`k`-scroll, `y`/`Y`/`R` Response-view keybindings are unreachable via mouse, and the next keystroke silently corrupts the URL field instead

**surface**: request-pane / editable-headers

**Repro** (`ws14/bigjson.curl`, `GET {{BASE_URL}}/bigjson`, sent — 200
OK, 1.3 KB body):
1. Click on the "Body" chip in the **Response** pane's own tab strip
   (the row reading `Body  Headers 4  Timeline  Tests … JSON ▼` directly
   above the response body content — NOT the Edit-view's Params/Body/
   Headers/Auth/Vars/Script tabs above it).
2. Press `/` (documented — `src/tui/handlers/pane.rs:2842-2846` comment:
   "`/` focuses the filter input… Filter applies to header rows (Edit-tab
   Headers list, request-summary headers, response headers)").
3. Observe the URL field.

**Expected**: `/` opens the Response-view filter prompt ("type to filter
headers + body…", confirmed working via the *keyboard*-only path below).

**Actual**: `/` is appended as a literal character to the URL field —
`{{BASE_URL}}/bigjson` → `{{BASE_URL}}/bigjson/`. No filter prompt
opens. Repeated 3× independently (once via a body-content click at
row 26, once via clicking directly on the "Body" tab-strip chip at
row 21/col 36 — both land the character in the URL). The mutation isn't
written to disk (the `.curl` file on disk is unaffected — only the live
in-memory buffer), but it's silent, unprompted corruption of an
open/dirty buffer with no undo affordance surfaced (the buffer isn't
even marked dirty in the bufferline — closing the tab produces no "save
changes?" prompt, so the corruption is invisible until the next Send
fires against a broken URL).

**Confirmed working via the correct (keyboard-only) path**, to isolate
the bug to the click handler specifically: from Edit view with the URL
field focused, `Esc` (not a click) correctly switches to Response view
per `src/tui/handlers/pane.rs:2750`; `/` then opens `type to filter
headers + body…`; typing `item-15` + `Enter` correctly filters to `1/5`
matches and shows the matching JSON block (`"id": 15, "name":
"item-15"`) with real line numbers. The underlying filter/search feature
is not broken — it's simply unreachable from the response tab-strip
click, which is the natural, visually-obvious way most mouse users would
try to interact with the Response pane.

**Root cause**: `src/tui/mouse/down_left.rs:673-688` — the Response
sub-tab click handler:
```rust
if let Some((_, tab)) = app.rects.request_response_tabs.iter()
    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
{
    let tab = *tab;
    if let Some(cur) = app.active
        && let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur)
    {
        rp.response_tab = tab;
    }
    return;
}
```
Sets `rp.response_tab` (which of Body/Headers/Timeline/Tests is shown)
but never calls `app.focus_pane()` and never sets `rp.view =
ViewMode::Response`. Compare the *Edit*-tab click handler two blocks up
(`:483-490`, "Click on a request-pane tab chip → switch view (Edit ⇄
Response)") which does call `app.focus_pane()` and does flip `rp.view`
— the Response-side sibling handler is missing both, so `rp.view` stays
whatever it was (typically `Edit`, `rp.focus` typically `Url`), and
every subsequent key falls through to the Edit-view `KeyCode::Char(c) =>
rp.type_char(c)` arm at `pane.rs:2789-2800`. Same bug *class* as
round-13's SEV-2 A (a click that visibly changes state without moving
keyboard ownership to match) — round-13's fix touched the Vars/Params
KV-cell handlers; this is a third, un-swept sibling.

**IPC trace**:
```
{"event":"click","button":"Left","col":"36","row":"21"}   # "Body" response tab chip
{"event":"key","key":"/"}
```
URL field before: `{{BASE_URL}}/bigjson` → after: `{{BASE_URL}}/bigjson/`.

**Notes**: `src/tui/mouse/down_left.rs:673-688` (bug); `:483-490` (the
correct sibling pattern to mirror); `src/tui/handlers/pane.rs:2846`
(the `/`-filter binding, confirmed functional once `rp.view ==
Response`); `:2750` (`Esc`, the only currently-working way to reach
Response view from a freshly-opened/sent request pane).

#### Finding 3 — Response body byte-size is inflated for binary/non-UTF8 payloads, both in the Response pane border/binary-placeholder text and in `.rqst/history.jsonl`'s persisted `body_bytes` field — both read the lossy-UTF8-decoded `String`'s length instead of the raw byte count already available on the struct

**surface**: request-pane / http.history

**Repro**: `ws14/binary.curl` → `GET {{BASE_URL}}/binary` against a
local server returning exactly 256 raw bytes (the full `0x00..0xFF`
range, `Content-Type: application/octet-stream`; confirmed via
`curl -s .../binary | wc -c` → `256`).
1. `:http.send`.
2. Read the Response pane border and the binary placeholder line.
3. Read the most recent line of `.rqst/history.jsonl`.
4. `:http.save_response` → save to `binary.out` → `wc -c binary.out`.

**Expected**: both the UI and the history entry report `256 B` /
`body_bytes: 256` — matching the real response size and the actually-
saved file.

**Actual**:
- Response pane border: `200 OK · 0ms · 512 B`.
- Binary placeholder: `[binary binary · 512 bytes · Ctrl+S to save the
  raw body]`.
- `.rqst/history.jsonl`: `{"...,"body_bytes":512,...}`.
- `binary.out` on disk (the file `Ctrl+S`/`:http.save_response` actually
  writes): **256 bytes** — correct, because the save path uses
  `body_bytes` (the raw `Vec<u8>`), not the lossy string. So this is a
  **display/logging bug only, not data corruption** — the underlying
  bytes are handled correctly for the one operation (save) that matters
  most; it's the byte-count *shown to the user* and *persisted for
  grep/jq workflows* that's wrong.

**Root cause**: `Response.body` (`src/http/mod.rs:231`) is
`String::from_utf8_lossy(&buf).into_owned()` — every invalid UTF-8 byte
becomes a 3-byte `U+FFFD` replacement character, so a 256-byte payload
containing invalid lead/continuation bytes (as most binary content
does) decodes to a *longer* string. Two separate call sites then read
that inflated length instead of the correct `Response.body_bytes.len()`:
  - `src/ui/request_view.rs:3747`: `let size = r.body_bytes.len().max(r.body.len());`
    — the `.max()` picks the *larger*, wrong value whenever the lossy
    string outgrows the raw bytes (which is exactly the binary case).
  - `src/app/http.rs:6329`: `body_bytes: Some(rv.body.len())` — doesn't
    even reference `rv.body_bytes` at all; a plain wrong-field bug (the
    history `Entry.body_bytes` field name collides with the unrelated
    `Response.body_bytes` field name, an easy mix-up).

**IPC trace**:
```
{"event":"command_run","id":"http.send","ok":"true"}
```
`screen.txt`: `┌ … 200 OK · 0ms · 512 B ┐` / `[binary binary · 512
bytes …]`. `.rqst/history.jsonl` tail:
`{"ts":1784235802545,"method":"GET","url":"{{BASE_URL}}/binary","status":200,"duration_ms":0,"body_bytes":512,"error":null,...}`.
Ground truth: `curl -s http://127.0.0.1:8977/binary | wc -c` → `256`;
saved file via `:http.save_response` → `256` bytes.

**Notes**: `src/ui/request_view.rs:3747`, `src/app/http.rs:6329`;
`src/http/mod.rs:226-237` (the lossy-decode comment already flags
`body` as "display-safe," i.e. not meant for size math).

#### Finding 4 — Response pane's "TEXT" body format ("plain text (no highlight)") still silently pretty-prints JSON — there is no way to view the actual raw response bytes as received

**surface**: request-pane

**Repro**: `ws14/bigjson.curl` against a server that returns **compact,
single-line** JSON (`json.dumps(body)`, no `indent=` — confirmed via
`curl -s .../bigjson | wc -l` → `0`, i.e. one line, no trailing
newline).
1. `:http.send` → 200 OK, response shown pretty-printed across ~90
   numbered lines (default `Auto` format correctly detects JSON and
   pretty-prints — expected).
2. Click the format dropdown (`JSON ▼` chip) → select `Text` (menu row
   reads "plain text (no highlight)").
3. Observe the body content.

**Expected**: "plain text (no highlight)" reads as "show me the actual
bytes, unformatted" — i.e. the single compact line the server actually
sent, just without JSON syntax coloring.

**Actual**: content is unchanged — still the same ~90 pretty-printed,
line-numbered rows; only the syntax highlighting is removed (border
chip now reads `TEXT ▼` instead of `JSON ▼`). There is no menu option,
toggle, or keybinding anywhere in the Response pane that shows the
literal raw response body. A user trying to verify exact whitespace,
confirm the server actually sent compact vs. pretty JSON, or inspect a
body that's almost-but-not-quite valid JSON (where `pretty_body`'s
`serde_json::from_str` fails and falls through) has no way to do so —
though in *that* one case (parse failure) `pretty_body` does correctly
fall back to the raw string, so "Text" mode is really "Auto mode minus
color," not "raw."

**Root cause**: `src/ui/request_view.rs:3770`:
```rust
let pretty = pretty_body(&r.body, &r.headers);
```
runs unconditionally, *before* the `rp.response_body_format` match at
`:3774-3801` that only decides which syntax-highlighter language to
apply (`Some("json") | Some("html") | None`). `ResponseBodyFormat::Text`
maps to `None` (no highlighter, confirmed at `:3778`) but the body text
itself — `pretty` — was already re-serialized via
`serde_json::to_string_pretty` inside `pretty_body`
(`src/ui/request_view.rs:4006-4021`) regardless of which format the
user picked. There's no code path that renders `r.body` (the actual
received bytes, modulo the lossy-UTF8 caveat from Finding 3) unmodified.

**Notes**: `src/ui/request_view.rs:3770` (unconditional pretty-print
call site), `:4006-4021` (`pretty_body`, always re-serializes JSON when
detected — no raw-passthrough branch), `:1999` (`ResponseBodyFormat::Text
=> "TEXT"`, the label the dropdown renders — "plain text (no highlight)"
is the menu's own description string, making the gap between label and
actual behavior a UI-authored promise, not just an inference).

---

### SEV-3 (reconfirms — unchanged since round-11)

#### Finding 5 (reconfirm of round-11 F2 / round-12 F4) — Params/Headers/Vars KV tables still have no scroll; overflow rows unreachable, `j` leaks into the URL field

**surface**: request-pane (Vars tab)

Re-ran with 16 vars (`BASE_URL`, `TOKEN`, `VAR1`..`VAR14`) in
`dev.env`. The table renders exactly 3 rows (`BASE_URL`, `TOKEN`,
`VAR1`) at a typical pane height (36-row terminal, KV-table box gets 3
content rows between its header and bottom border) — **13 of 16 vars
(81%) are permanently invisible**, no scrollbar, no "+N more" hint.
Tried all four scroll affordances with the table visually focused
(post-cell-click, per the round-13-fixed focus path):
- `j` → leaks a literal `j` into the URL field (`{{BASE_URL}}/step1` →
  `{{BASE_URL}}/step1j`) — confirmed via `screen.txt` diff.
- `PageDown` → silent no-op, no leak, no scroll.
- Mouse wheel (`{"cmd":"scroll","dy":-3}` at the table) → silent no-op.
- No `edit_tab_scroll`-shaped field found in `src/request_pane.rs`
  (grepped this round too — still absent).

Unfixed across 3+ rounds now (round-11 F2, round-12 F4, this round).

**Notes**: same as round-12 — `src/ui/request_view.rs` KV-table render
path clips to available height with no offset; `j`'s leak confirms
`EditField` focus stays `Url` even though the cell visually "has" the
click.

#### Finding 6 (reconfirm of round-11 F3 / round-12 F5) — Replayed mock responses carry no persistent marker distinguishing them from a live response

**surface**: http.replay_mock

**Repro**: `:http.send` a real request (200 OK, 1.3 KB) → `:http.save_mock`
(writes `bigjson.curl.mock.json` sidecar, confirmed on disk) →
`:http.replay_mock` on the same pane.

**Actual**: Response border and Timeline tab are pixel-identical to a
live response except the elapsed time reads `0ms` — and a genuinely
fast local response (as every response in this round's local-server
fixture was) is *also* `0ms`/`1ms`, making even that one differentiator
useless in practice. No `[MOCK]` badge, no distinct border color, no
marker in the Timeline tab (`Wait`/`Receive`/`Total` rows render
identically), no tab-title indicator. Unfixed since round-11 — `checked
the ResponseView struct again this round; still no `is_mock`/`source`
field exists on it.

**Notes**: `src/app/http.rs:3190-3229` (`http_replay_mock_from_path`).

## Swept clean this round

- **Chain runner edge cases** (4 fixtures, all via `mnml chain run`):
  - **Mid-chain variable set-and-use**: step 1 extracts
    `SESSION_ID=$.session_id` from a 200 response, step 2's URL
    references `{{SESSION_ID}}` in a query param — correctly threaded
    through (`?sid=sess-abc123` echoed back by step 2's own handler).
  - **Failure propagation**: step 1 hits a 500 — chain stops immediately
    (`step 1: stopping at non-success 500`, exit 1), step 2 never fires.
  - **Empty response body (204) mid-chain**: a step returning `204 No
    Content` with zero bytes, followed by a normal step — both succeed,
    chain passes, no panic on the empty-body step.
  - **Non-JSON response feeding an `@extract`**: a step returns
    `200 OK` with a plain-text (non-JSON) body, and its `extract` map
    tries to pull `$.bar` from it — cleanly fails with `step 1: extract
    'FOO' from $.bar produced nothing` (the `serde_json::from_str` in
    `chain.rs:253` returns `None`, handled, no panic). Same clean
    failure for the `200 OK` + **empty** (zero-byte, not just
    non-JSON) body case.
- **WebSocket (native `tungstenite` path, `:ws.connect` /
  `:ws.send_message` / `:ws.disconnect` / `:ws.history`)** — full
  round-trip against a local raw-socket echo server: `:ws.connect`
  prompts for a URL, connects, border shows `ws · ● open ·
  ws://127.0.0.1:8965/ · 0 ms`; `:ws.send_message` sends `hello-mnml`,
  echoes back `echo:hello-mnml` in the transcript; `:ws.disconnect`
  correctly flips the border to `· closed`; `:ws.history` picker
  correctly lists `ws://127.0.0.1:8965/ · 2 msgs` (reads
  `~/.mnml/ws-history/<host>/history.jsonl`, which was correctly
  written during the session). `:ws.send` (the `.ws`-file →
  `websocat` shell-out path) not exercised — `websocat` isn't on PATH
  in this environment; this is a documented external-tool dependency
  (`run_websocat_send` in `src/app/http.rs:106-148` handles the
  missing-binary case with a clear error, not a crash — spot-checked
  the code, not re-run live).
- **Binary/image response detection** — both `image/png` and
  `application/octet-stream` bodies correctly short-circuit to the
  `[binary <kind> · N bytes · Ctrl+S to save the raw body]` placeholder
  (`src/ui/request_view.rs:3748-3768`) before any pretty-print/highlight
  attempt — no garbled terminal output, no attempt to syntax-highlight
  binary data. (The displayed `N` is wrong per Finding 3, but the
  short-circuit itself is correct and safe.) `Ctrl+S`/
  `:http.save_response` on the binary fixture wrote a byte-exact
  256-byte file to disk despite the UI showing 512.
- **Discover — malformed spec**: a truncated/invalid JSON file (`{`,
  unterminated) produces a clean `mnml discover: parse spec: EOF while
  parsing an object at line 5 column 0`, exit 1 — no panic.
- **Discover — partial spec**: a spec with (a) a `GET` operation with no
  `operationId` (falls back to a synthesized `get-users.curl` name,
  method-lowercase + hyphenated path, matching the documented rqst-parity
  convention), (b) a `POST` with only a `schema` (no `example`/
  `examples`) correctly synthesizes a skeleton JSON body
  (`{"name":"John Smith"}` for a `{type: string}` property), and (c) a
  path with an empty methods object (`"/empty-methods": {}`) — correctly
  produces zero stubs for that path, no error.
- **History append on failure** — `GET http://127.0.0.1:19999/nope`
  (connection refused, nothing listening) correctly appends
  `{"...,"status":null,"duration_ms":null,"body_bytes":null,"error":"connection
  failed: error sending request for url (http://127.0.0.1:19999/nope)",...}`
  to `.rqst/history.jsonl` — matches the documented contract exactly
  (`status: null` + populated `error`).

## Testing notes / harness gotchas (for whoever runs this next)

- **`http.server`'s path-prefix matching bites you if you use
  `startswith`-chained `elif`s with overlapping prefixes** — this
  session's own fixture server initially had `/empty200` falling through
  to the `/empty` branch (`"/empty200".startswith("/empty")` is `True`)
  before the `/empty200` check was moved first. Worth flagging in case
  a future round reuses fixture-server code from this or earlier
  rounds' scratchpad artifacts — check branch ordering before trusting
  a "confirmed 200" result against a path that's a prefix of another
  registered path.
- **`open` (IPC) re-focuses an already-open buffer rather than
  reloading from disk** — if a prior action left the in-memory buffer
  dirty (e.g. Finding 2's leaked `/`), a subsequent `{"cmd":"open",...}`
  on the same path does *not* discard the unsaved in-memory edit; you
  have to explicitly close the tab (`bufferline_tab_close` rect) first
  to get a clean reload. Not itself a bug (matches every other editor's
  behavior) — just a harness trap that produced a confusing false
  reading mid-session before being caught.
