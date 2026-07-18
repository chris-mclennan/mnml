# API-workflow hunt — round 7

Driven headless via `<workspace>/.mnml/ipc/` against `./target/debug/mnml`
(commit `87a91cd`, clean tree). Workspace: a scratch dir with
`.mnml/env/dev.env`, `.mnml/chains/`, `requests/*.curl` / `*.http`, and a
tiny local Python HTTP server on `127.0.0.1:8931` standing in for a real
API (login/orders/echo/upload/big/image endpoints). Launched with
`MNML_ENV=dev` so `{{BASE_URL}}` etc. resolve.

Every finding below was reproduced by actually firing requests through the
IPC channel and reading the resulting `screen.txt` / on-disk files — not
inferred from source alone (source reading was used to *explain* what was
observed, and is cited as supporting evidence).

Areas covered per the round-7 brief: response viewer (JSON tree / big
response / image render / HTML preview / save-to-file), multipart
form-data, chains (parallel / if / retry / XML-YAML extraction), env
layering incl. per-request override, var templating (recursion, escaping),
cookie/auth persistence across requests, mock "server" grammar, `.rest` vs
`.http` vs `.curl` parity.

---

## Finding 1 — SEV-1 — opening a bare `curl URL …` `.curl` file corrupts it into method "CURL", silently dropping every flag

**surface**: request-pane / `.curl` file open (tree click, HTTP-panel FILES row, recent-files)

### Repro

1. Write `requests/unquoted-multiline.curl`:
   ```
   curl {{BASE_URL}}/echo \
     -H "X-Test: abc" \
     -d '{"a":1}'
   ```
   (a perfectly normal, hand-typed curl command — URL right after `curl`,
   unquoted since `{{BASE_URL}}` doesn't need shell-quoting in a data file.)
2. In the TUI, `Ctrl+P` → open `unquoted-multiline.curl` (or single-click it
   in the file tree / HTTP-panel FILES section — same code path).
3. Observe the Request pane that opens.

### Expected

Method `GET` (curl's default when no `-X`/`-d` forces POST — actually curl
defaults to POST here because `-d` is present, so `POST` is expected), URL
`{{BASE_URL}}/echo`, header `X-Test: abc`, body `{"a":1}`. Firing it should
reach the server with those headers/body intact — this is exactly the
shape `curl::parse_curl` handles correctly (see `src/http/curl.rs` tests).

### Actual

Method chip shows **`CURL`** (not GET/POST — a nonexistent HTTP verb), URL
is correct, but **the Headers tab and Body tab are both completely empty**
— `-H "X-Test: abc"` and `-d '{"a":1}'` are silently discarded, no error
toast, no parse-failure message. Firing it produces a real request to the
server with method `CURL`, which any HTTP server (my test server included)
rejects with `501 Not Implemented`. A minimal case with just a bare GET
(`curl {{BASE_URL}}/whoami-cookie`, no other flags) reproduces the same
`CURL` method + empty body/headers, and firing it gets the same `501`.

### Root cause (read after reproducing, to explain — not asserted from
static analysis alone)

`App::open_request_pane_from_file` (`src/app/http.rs:694`) tries
`crate::http::file::parse_all(&text)` **first**, regardless of file
extension, and only falls back to the curl-aware `crate::http::parse`
dispatcher if `parse_all` returns `Err`. `http::file::parse_all` /
`parse_block` (`src/http/file.rs:148-210`) is a naive `.http`-file line
parser: `split_request_line` splits the first non-comment line on
whitespace and treats the **first token as the method, second token as
the URL** if the second token "looks like a URL" (`looks_like_url` —
`http://`, `https://`, `{{`, or `/` prefix). For `curl {{BASE_URL}}/echo`,
that's `first="curl"`, `second="{{BASE_URL}}/echo"` — `looks_like_url`
returns `true` (starts with `{{`), so `parse_block` "succeeds" with
`method="CURL"`, and **every remaining token on that line and every
subsequent line's `-H`/`-d` flags are silently ignored** (the header-line
loop only understands `Name: Value` header syntax, not curl flags). Since
`parse_all` returns `Ok`, `open_request_pane_from_file` never falls
through to the correct `http::parse`/`curl::parse_curl` path — no error is
ever surfaced.

The bug does **not** trigger when the URL is quoted (`curl 'https://…'`),
because the quote characters break `looks_like_url`'s prefix check, which
makes `parse_block` return `Err(NoUrl)` and correctly fall through to the
curl parser. It also doesn't trigger when a flag like `-X` comes
immediately after `curl` (`-X` isn't URL-shaped either). So the trigger
condition is specifically: **the first thing after `curl` is an unquoted
URL** — which is a very natural way to hand-write a `.curl` file in an
env-var-templated workspace (no shell-quoting is needed since it's just a
data file, not something you're pasting into a live shell), and is
*exactly* the shape produced when copying a curl command from a terminal
history that already had `{{VAR}}`-style placeholders substituted back in
by hand.

Confirmed **not** present in:
- `mnml run FILE` (CLI) — `src/main.rs:677` calls `http::parse` directly,
  never `file::parse_all`. CLI is safe.
- `App::send_request_from_active` (the Editor-pane + `:http.send` flow,
  `src/app/http.rs:3941`) — its `.curl` branch scans `###` blocks directly
  and calls `http::parse` (the smart dispatcher), never `file::parse_all`.
  Safe.
- `.curl` stubs generated by `mnml discover` / `:http.sync` — always
  single-quote the URL (`src/http/discover.rs:571`), so they don't hit
  this path either.

So the blast radius is specifically: **hand-written `.curl` files opened
via a tree/file/recent-files click**, which given the workspace fixture
conventions this whole hunt program encourages (`.curl` files as the
primary request format) is a very likely, very common path.

### IPC trace (abridged — full command list available in scratch dir)

```
{"cmd":"click","col":21,"row":1}                 # tree refresh icon
{"cmd":"key","key":"ctrl+p"}
... type "unquoted" ...
{"cmd":"key","key":"enter"}                      # opens the file
```
Resulting `screen.txt`:
```
 >_  mnml  File  Edit  Selection             hunt7
    ...                        │ CURL  {{BASE_URL}}/echo 
                                │┌ Method ────┐┌ URL ...────────────┐
                                ││  CURL    ▼ ││ {{BASE_URL}}/echo  │
                                │┌──────────────────────────────────┐
                                ││  Params  Body  Headers  Auth ... │
                                ││ 1                                 │   ← Body: empty (was '{"a":1}')
```
(Headers tab also empty — was `X-Test: abc`.)

**Notes**: `src/app/http.rs:721` (`open_request_pane_from_file`'s
`parse_all`-first ordering) · `src/http/file.rs:198-210`
(`split_request_line` / `looks_like_url` treating `curl` as a method).

---

## Finding 2 — SEV-1 — `@capture`d vars never persist into a later `:http.send`, contradicting the documented behavior; auth flows silently fire with a literal unresolved `{{TOKEN}}`

**surface**: http.send / editable-headers / env-resolution

### Repro

1. `requests/auth-flow.http`:
   ```
   ### login
   # @capture TOKEN = json $.token
   POST {{BASE_URL}}/login
   Content-Type: application/json

   {"user":"qa","pass":"qa"}

   ### orders
   GET {{BASE_URL}}/orders
   Authorization: Bearer {{TOKEN}}
   ```
2. Open the file (tree click), cursor lands on the `login` block. Run
   `http.send`. Response: `200`, body `{"token":"tok-abc-123","user":{"id":42}}`,
   response pane shows `⇒ TOKEN = tok-abc-123`.
3. `http.next_block` (moves to the `orders` block in the same pane/file).
   Run `http.send` again.

### Expected

Per `site/src/content/docs/manual/http.md:126`:
> **Captures** — `name = value` per `@capture` directive (**also pinned
> into the running env so the next request in the file picks them up**)

So the `orders` block's `Authorization: Bearer {{TOKEN}}` should resolve
to `Bearer tok-abc-123`.

### Actual

The server receives the **literal unresolved string**:
```json
{
  "auth_seen": "Bearer {{TOKEN}}",
  "orders": [1, 2, 3]
}
```
No error, no toast, no "unresolved var" warning — the request fires
successfully (200) with a broken `Authorization` header. If the real
target API also just echoes 200 for any bearer value (common for smoke
endpoints, or if auth is enforced downstream), this is the kind of thing
that looks like "it worked" in the response pane while every following
request in the session is unauthenticated.

### Root cause

`App::send_request_from_active` / `App::refire_request`
(`src/app/http.rs`) construct a **fresh `EnvSet`** via
`EnvSet::select_with_config_default` on every single send, and
`App::spawn_http_job` (`src/app/http.rs:4051`) applies `@capture` against
a **throwaway `EnvSet::empty()`** (`src/app/http.rs:4101`) purely so the
`(name, value)` pairs can be shown in the Response pane's "Captures"
section (`src/ui/request_view.rs:3853`). Nothing writes the captured value
back into any persistent structure that a later `{{VAR}}` expansion can
see — there is no `self.running_http_env` (or similar) on `App` at all
(confirmed via `grep -n "captured_vars\|running_env" src/app/*.rs` — no
hits). The **only** place captures actually feed forward into a later
request's `{{VAR}}` resolution is `http::chain::run` (`src/http/chain.rs`,
which explicitly threads a single mutable `EnvSet` through every step) —
i.e. this only works if you wrap the requests in a `.chain.json` and run
them via `:http.run_chain` / `mnml chain run`. The interactive
`:http.send` flow (the primary, most-used surface — single request files,
multi-block `.http` files, the Request pane's `r` re-fire) never carries
captures forward, whether within the *same file* (as the docs explicitly
promise), across a *different block*, or across a *different file*.

### IPC trace

```
{"cmd":"run-command","id":"http.send"}           # login block → 200, TOKEN captured (display-only)
{"cmd":"run-command","id":"http.next_block"}      # → orders block
{"cmd":"run-command","id":"http.send"}            # orders block fires
```
`screen.txt` after the second send:
```
│ 1 {
│ 2   "auth_seen": "Bearer {{TOKEN}}",
│ 3   "orders": [
│ 4     1,
```

**Notes**: `src/app/http.rs:4101` (throwaway `EnvSet::empty()` in
`spawn_http_job`), `src/ui/request_view.rs:3853` (captures are
display-only), `src/http/chain.rs:104` (the only place a mutable running
`EnvSet` actually exists) vs. `site/src/content/docs/manual/http.md:126`
(the doc claim). Either the doc needs the "next request in the file"
promise removed/qualified to "next step in a chain", or `:http.send`
needs an actual running-env carry-over (e.g. keyed per open Request pane
group, or per `.http` file) to match what's documented.

---

## Finding 3 — SEV-1 — multipart file-upload (`-F field=@file`, `-F name=<file;type=…`) is completely unimplemented: file contents are never read, and the literal `@path`/`<path` string is silently POSTed instead

**surface**: editable-headers / http.send (curl multipart parsing)

### Repro

1. `requests/upload.curl`:
   ```
   curl -X POST {{BASE_URL}}/upload -F "field=hello world" -F "file=@requests/tiny.png" -F "json=<requests/meta.json;type=application/json"
   ```
   (`tiny.png` is a real 20-byte PNG file next to the request; `meta.json`
   is a real JSON file — both exist on disk, in the same dir the curl file
   resolves relative paths from.)
2. Open + `http.send`.

### Expected

A real `multipart/form-data; boundary=…` body: `field` as a text part,
`file` as a binary part with `tiny.png`'s actual bytes + a filename, `json`
as a part carrying `meta.json`'s file *contents* with
`Content-Type: application/json` (curl's `<file` syntax reads the file as
the value). At minimum, if multipart truly isn't implemented, a clear
error/toast ("file upload not supported yet") rather than silent
corruption.

### Actual

Server receives:
```json
{
  "content_type": "application/x-www-form-urlencoded",
  "raw_len": 88,
  "raw_preview": "field=hello world&file=@requests/tiny.png&json=<requests/meta.json;type=application/j..."
}
```
i.e. mnml never opens `tiny.png` or `meta.json` at all — the literal
`@requests/tiny.png` and `<requests/meta.json;type=…` strings are
URL-encoded and concatenated as if they were ordinary field values, with
`Content-Type: application/x-www-form-urlencoded` (objectively wrong for
what the user asked for). The response is `200 OK` from my permissive test
server; against a real API this would 400/415, or — worse — silently
"succeed" against an endpoint that doesn't validate strictly, leaving the
user thinking their file-upload integration works when it never sent a
file.

### Root cause

`src/http/curl.rs:88-113` — the `-F`/`--form`/`--form-string` arm's own
comment says:
> `-F field=value` / `-F field=@file` builds multipart form data. We don't
> have a full multipart encoder yet; collect field=value pairs into an
> `application/x-www-form-urlencoded` body as a pragmatic approximation.

That comment (and the one existing unit test,
`dash_capital_f_form_creates_urlencoded_body_and_preserves_url`) only
acknowledges the **plain `field=value`** approximation as an intentional,
documented limitation. It says nothing about — and there is no handling
anywhere for — the `@file` (upload) or `<file` (read-file-as-value) forms;
those are silently swallowed into the same urlencoded-approximation path
with their literal `@`/`<` prefix intact. `grep -rn "multipart::Form\|Form::new"
src/` returns zero hits — there's no multipart encoder in the codebase at
all, confirmed by reading `reqwest`'s usage in `src/http/mod.rs:167-241`
(`client.request(...).body(body.clone())` — plain string body, no
`multipart::Form`).

### IPC trace

```
{"cmd":"run-command","id":"http.send"}
```
`screen.txt`:
```
│ 1 field=hello world&file=@requests/tiny.png&json=<requests/meta.json;type=application/│
...
│ 2   "content_type": "application/x-www-form-urlencoded",
│ 4   "raw_preview": "field=hello world&file=@requests/tiny.png&json=<requests/meta.json│
```

**Notes**: `src/http/curl.rs:88-113`. Recommend either implementing real
multipart via `reqwest::blocking::multipart::Form` (file reads relative to
the `.curl` file's directory, matching curl's own CWD-relative semantics)
or at minimum detecting `@`/`<` values and refusing to send with a loud
error instead of silently mangling the payload.

---

## Finding 4 — SEV-3 — no recursive `{{VAR}}` expansion; `{{A}}` where `A={{B}}` resolves to the literal string `{{B}}`, not further expanded

**surface**: env-resolution / editable-headers (vars)

### Repro

1. `.mnml/env/dev.env`:
   ```
   BASE_URL=http://127.0.0.1:8931
   GREETING={{NAME}}
   NAME=literal-value
   ```
2. `requests/recursive-var2.curl`:
   ```
   curl -X POST {{BASE_URL}}/echo -H "Content-Type: application/json" -d '{"greeting":"{{GREETING}}"}'
   ```
3. Open + `http.send`.

### Expected (arguable — see Notes)

Either a single-pass, well-defined behavior (fine if that's the intended
design), or full resolution to `"literal-value"`.

### Actual

```json
{ "echo": "{\n  \"greeting\": \"{{NAME}}\"\n}" }
```
`{{GREETING}}` expands to the *value* `{{NAME}}` verbatim (one substitution
pass) — it is not itself re-scanned for further `{{…}}` tokens, so the
final wire payload contains a raw, unresolved `{{NAME}}` token that looks
exactly like a *missing* var, even though `NAME` is perfectly well-defined
in the same env file.

### Root cause

`resolve()` in `src/http/template.rs:238` calls `env.lookup(name)` and
returns the raw string — `expand()` (`template.rs:185`) never re-scans the
substituted value for nested `{{…}}`. This is a single top-level scan, not
a fixed-point expansion.

**Notes**: Not documented as supported either way — `site/…/manual/http.md`
only documents "resolution order" for a single lookup, never promises
chained/aliased vars. This is likely intentional (avoids infinite-loop
footguns from a malicious/typo'd env file), but it's worth flagging
because `NAME_HEADER = "Bearer {{TOKEN}}"`-style aliasing is an extremely
common env-file idiom in Postman/Insomnia-migrated workspaces, and the
silent one-level-only behavior produces output that's indistinguishable
from "the var doesn't exist" at first glance. If intentional, consider a
`{{$dev-note}}`-style single doc line saying so; if not, a fixed-point
`expand` (with a hop-count guard against cycles) would match the common
mental model.

---

## Finding 5 — SEV-3 — no per-request env override (`env:` frontmatter / `@env` directive); only whole-app env selection exists

**surface**: env-resolution / `.curl` frontmatter

### Repro / investigation

Searched `src/http/script.rs` (the `@`-directive parser — handles
`@set-header`, `@set-env NAME = VALUE`, `@assert`, `@capture`) and
`src/http/curl.rs` / `src/http/file.rs` for any directive that selects
*which named env file* (`.mnml/env/<name>.env`) a given request should
resolve against. None exists — `@set-env` only binds a single variable
into the currently-active env, it doesn't switch the active env file.
`EnvSet::select_with_config_default` (`src/http/template.rs:83`) is the
only place an env *name* gets chosen, and it's driven entirely by
`--env`/`$MNML_ENV`/config-default/`.rqst/config` — all workspace- or
process-wide, never per-request.

### Expected vs. actual

This may simply be out of scope for mnml's design (some clients — e.g.
Bruno — do support a per-request/per-folder env pin; Postman doesn't
support this either, it's collection-scoped). Flagging per the round's
brief since it was explicitly asked about: **it does not exist**, so a
user migrating from a tool that has it (or assuming `.curl` frontmatter
like `# @env staging` would work because `@set-env`/`@assert`/`@capture`
directives exist in the same comment-directive namespace) will find it
silently ignored — a directive that doesn't parse is treated as a plain
comment (`site/.../http.md:216`), so `# @env staging` is a silent no-op,
not an error.

**Notes**: Not a regression — a genuine gap. No fix recommended unless the
team wants to add the feature; flagging for awareness since a plausible
directive name collides with the existing `@`-prefixed namespace and
would silently no-op if a user guesses it.

---

## Finding 6 — SEV-3 — no mock *server* exists at all (matcher grammar, path params, catch-all, per-mock scripting are all out of scope); `mock.rs` is a strict 1:1 sidecar replay

**surface**: http.save_mock / http.replay_mock

### Investigation

Read `src/http/mock.rs` in full. The entire feature is: `save()` writes one
JSON sidecar (`status`/`status_text`/`headers`/`body`) next to a specific
request file (`<source>.curl.mock.json` /
`<source>.<block>.<ext>.mock.json` for multi-block `.http`); `load()`
reads it back; `App::http_replay_active_request_from_mock`
(`src/app/http.rs:3046`) flips *that exact Request pane* to `Done` with
the mock's payload, no network call. There is:

- no matcher grammar (method+path+query+header matching against arbitrary
  incoming requests),
- no path-param syntax (`/users/:id`),
- no catch-all (`**`),
- no actual listening HTTP server / port at all,
- no per-mock response scripting (delay, conditional status, templated
  response).

`grep -rn "mock server\|mock_server\|MockServer"` across `site/` and `src/`
returns zero hits — this isn't documented as existing anywhere either, so
there's no gap between docs and code here. This is purely a **scope
clarification**: "mock" in mnml means "replay this one canned response for
this one specific request file", not "stand up a fake backend."

**Notes**: Not a bug. Flagging so nobody on the team (or a future hunt
round) assumes a mock-server matcher exists and spends time probing for
matcher-grammar edge cases that have no code to hit.

---

## Finding 7 — SEV-3 — binary (image) response bodies render as garbled lossy-UTF8 text instead of a binary-content placeholder or image preview

**surface**: request-pane (response viewer)

### Repro

1. `requests/image.curl`: `curl -X GET {{BASE_URL}}/image.png` (server
   replies `Content-Type: image/png` with a real, valid 1×1 PNG).
2. Open + `http.send`.

### Expected

At minimum a `[binary content — N bytes — image/png]` placeholder (mnml
already has `body_bytes` — the raw payload — available specifically so
`http.save_response_to` can write it out losslessly, per the 2026-07-11
SEV-1 fix noted in `src/http/mod.rs:216-220`). Ideally an actual inline
sixel/kitty-graphics preview, since mnml already ships a full image
renderer (`src/image/mod.rs`, `src/image/sixel.rs`) used for tree
thumbnails and `md_preview` image blocks.

### Actual

```
│ 1 �PNG
│ 2
│ 3 IHDRĉ
│ 4 IDATx�c`U'IIEND�B`�
```
The raw PNG bytes get lossy-UTF8-decoded (`body`, not `body_bytes`) and
dumped straight into the text response pane, labeled `TEXT` in the
top-right content-type chip (`detect_response_content_type`,
`src/ui/request_view.rs:1998-2033`, has no `image/*` branch at all —
falls through to body-sniff, which only recognizes `{`/`[`/`<` as
JSON/XML and defaults everything else to `TEXT`).

**Notes**: `src/ui/request_view.rs:1998` (no image detection branch),
`src/image/mod.rs` (existing renderer this could reuse). Not
data-corrupting (save-to-file already correctly uses `body_bytes`), just a
bad preview UX for a response shape the round brief specifically asked
about.

---

## Finding 8 — SEV-3 — Response pane has no JSON tree collapse/expand; large responses render as one flat non-foldable block

**surface**: request-pane (response viewer)

### Investigation + repro

`requests/big.curl` → `GET {{BASE_URL}}/big` returns a 1.4 MB / 40,000-item
JSON array. It renders fully (no crash, no obvious hang — a full redraw
came back promptly), pretty-printed with tree-sitter JSON syntax
highlighting and line numbers, via `pretty_body`
(`src/ui/request_view.rs:3926`). But there is no fold/collapse
affordance anywhere in the response body renderer — `grep -n
"fold\|collapse" src/ui/request_view.rs` hits nothing but an unrelated
comment about visual chip spacing. Compare to the Editor pane, which does
support code folding (`za`/`zA`, per a recent commit
`dcf69c3 fix: SEV-3 batch — response Ctrl+D/U, zA fold, right-click fold
arrow`) — but that fold support lives in the vim input handler + editor
buffer, and the Response body viewer is a separate, bespoke
non-interactive text painter (`pretty_body` + `draw_response`,
`request_view.rs:3505`) that never reuses it.

### Expected vs. actual

Not a regression (nothing here ever worked this way), but a genuine gap
for exactly the "big response" scenario this hunt round calls out: a
40,000-element array with no way to collapse to `[ 40000 items ]` or
fold an object to `{ … }` means scrolling through thousands of lines by
hand to find one field.

**Notes**: `src/ui/request_view.rs:3926` (`pretty_body`), `:3505`
(`draw_response`). No fold state exists on `RequestPane` for the response
body at all.

---

## Finding 9 — SEV-3 (cosmetic, not data-corrupting) — Request pane's block-name title chip doesn't update after `http.next_block`/`http.prev_block`

**surface**: multi-block-http / request-pane

### Repro

1. Open `requests/auth-flow.http` (two named blocks: `login`, `orders`).
   Title bar reads `POST  ## login`.
2. `http.next_block` — Method/URL/Body/Headers all correctly flip to the
   `orders` block's values (`GET  {{BASE_URL}}/orders`, `Authorization:
   Bearer {{TOKEN}}`).
3. Title bar still reads **`GET  ## login`** — the block-name chip didn't
   update to `## orders`.

### Verified NOT a data-corruption bug

Edited the URL field while on the (mis-titled) `orders` block
(`{{BASE_URL}}/orders` → `{{BASE_URL}}/orders?debug=1`) and saved
(`Ctrl+S`). The on-disk file correctly updated **only** the `### orders`
block:
```diff
-GET {{BASE_URL}}/orders
+GET {{BASE_URL}}/orders?debug=1
```
`### login` was untouched — so `source_block_name` (the field that
actually drives write-back) is tracked correctly internally; only the
**displayed** title chip lags behind. Low-severity but worth a quick fix
since it's actively misleading about which block is "current" while
staring right at it.

### IPC trace

```
{"cmd":"run-command","id":"http.next_block"}
```
`screen.txt`:
```
    ▼ ● hunt7            │  GET  ## login 󰅖  󰐕
                          │┌ Method ────┐┌ URL ──────────────────────┐
                          ││  GET     ▼ ││ {{BASE_URL}}/orders       │
```
(Method + URL show `orders`; title chip still says `## login`.)

**Notes**: title-chip render is somewhere in the pane title-bar draw path
in `src/ui/request_view.rs` (not the same code that updates
`rp.source_block_name`, which `http_next_block`/`move_to_http_block`
correctly maintain per `src/app/http.rs:2394-2497`).

---

## Summary table

| # | Finding | Severity | Surface |
|---|---|---|---|
| 1 | Bare `curl URL` `.curl` file opened via tree click → method "CURL", drops all flags | **SEV-1** | request-pane / multi-block-http |
| 2 | `@capture` never persists across `:http.send` fires, contradicting docs | **SEV-1** | http.send / env-resolution |
| 3 | Multipart file-upload (`-F @file`, `-F <file`) silently sends garbage, no error | **SEV-1** | editable-headers (curl parse) |
| 4 | No recursive `{{VAR}}` expansion (one pass only) | SEV-3 | env-resolution |
| 5 | No per-request env override directive | SEV-3 | env-resolution |
| 6 | No mock-server matcher grammar (scope clarification, not a bug) | SEV-3 | http.save_mock / http.replay_mock |
| 7 | Binary/image responses render as garbled text, no placeholder/preview | SEV-3 | request-pane |
| 8 | No JSON tree collapse/expand for large responses | SEV-3 | request-pane |
| 9 | Block-name title chip stale after `http.next_block` (cosmetic, write-back unaffected) | SEV-3 | multi-block-http |

Findings 1–3 are the ones worth prioritizing: #1 and #3 are silent,
no-error data-loss bugs on very ordinary inputs; #2 is a documented
feature that flatly doesn't work outside the chain runner, with real auth
implications (silently unauthenticated follow-up requests).
