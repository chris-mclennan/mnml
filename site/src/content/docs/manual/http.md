---
title: HTTP client
description: mnml's baked-in HTTP request client — `.http` / `.curl` / `.rest` files, an editable request pane, `{{var}}` templating, chains, OpenAPI discovery.
---

mnml ships a real HTTP request client inside the editor. Not "shell out to `curl` from a terminal pane" — a parsed-and-typed request layer with its own pane, response view, chain runner, and OpenAPI importer. The request files are plain text (`.http`, `.rest`, or `.curl`) sitting in your repo next to the code they hit, version-controlled with everything else.

The point of baking it in: you can edit a route handler, jump to the `.http` file that calls it, fire the request, see the response — all in the same buffer model, the same fuzzy finder, the same git gutter. No context switch to Postman, no JSON copy-paste round-trip, no second app to keep in sync. And the same files run headlessly from the CLI (`mnml run`) so CI can fire them too.

## The pieces

1. **Request files** — `.http`, `.rest`, `.curl`. Plain text, optionally multi-block.
2. **The request pane** (`Pane::Request`) — an editable form with URL / Method / Headers / Body fields, plus a Response view with status, headers, pretty-printed body, and assertion / capture results.
3. **Templating** (`{{VAR}}`) — workspace-local `.env` files keyed by an active env name, plus dynamic vars like `{{$uuid}}` and `{{$timestamp}}`.
4. **Scripts** — `@`-prefixed directives in `#` comments: `@set-header`, `@set-env` (pre-request), `@assert`, `@capture` (post-response).
5. **Chains** — a `.chain.json` runs a sequence of requests with values extracted between steps.
6. **Discovery** — `mnml discover SPEC` turns an OpenAPI / Swagger spec into one `.curl` stub per operation.

Every piece is shared between the editor (`http.send` opens a Request pane) and the CLI (`mnml run FILE`, `mnml chain run FILE`). The wire format, the env loader, the script directives, the response shape — one implementation, two front-ends.

There's also a file-less front door for the Postman-style "paste a curl from Chrome and just see the response" flow. `:http.new` opens a blank in-memory Request pane; `Ctrl+Shift+V` (or `:http.paste_curl`) populates Method / URL / Headers / Body from the clipboard. The Edit view is tabbed (Body / Headers / Params / Vars / Source) and Method / URL rows carry field-aware right-click menus. See [New request — Postman-style scratch pane](/manual/http-new-request/) for the full surface.

## Request files

mnml's request parser auto-detects between the `.http` / `.rest` REST-Client format and pasted cURL commands. The file extension is a hint (`http.send` requires `.http`, `.rest`, or `.curl`), but inside the file the format is sniffed: a leading HTTP method line means `.http`-format; otherwise it's parsed as cURL.

### `.http` / `.rest`

```http
# requests/users.http
GET https://api.example.com/users/42
Authorization: Bearer {{TOKEN}}
Accept: application/json

###

POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer {{TOKEN}}

{
  "name": "Alice",
  "email": "alice@example.com"
}

### get-orders

GET https://api.example.com/users/42/orders?limit=10
Authorization: Bearer {{TOKEN}}
```

The `###` separator splits a file into independent request blocks. Optional text after `###` (here, `get-orders`) names the block for selectable run + format-preserving writeback. `#` and `//` lines are comments. The first blank line ends the headers and starts the body; the body runs to the next `###` or EOF.

`http.send` (`<leader>hs` in vim, palette **HTTP: send request**) fires the block under your cursor; if there's only one block, it fires that one. The status chip flashes "sending..." and a Request pane splits below the editor with the response when it lands.

### `.curl`

```sh
# requests/auth/login.curl
curl -X POST 'https://api.example.com/auth/login' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-raw '{"email":"{{LOGIN_EMAIL}}","password":"{{LOGIN_PASSWORD}}"}'
```

Paste the cURL command browsers give you straight in. `{{var}}` substitution works on the URL, headers, and body — so the same file is dev / staging / prod-portable by swapping the env. The parser handles `\` line continuations, single + double quoting, `-X` / `--request`, `-H` / `--header`, `-d` / `--data` / `--data-raw` / `--data-binary`, and `-u` for basic auth.

### `.rest`

Same grammar as `.http` — different extension to play nicely with VS Code's REST Client. mnml treats them identically.

## Running a request

From an open `.http` / `.curl` / `.rest` buffer:

| Key / command | Action |
|---|---|
| `<leader>hs` (vim) or palette **HTTP: send request** | Send the block under the cursor |
| `<leader>hy` or palette **HTTP: copy as curl** | Copy the parsed request as a cURL command (browser-style) |
| `<leader>hd` or palette **HTTP: ask Claude (debug)** | Ask Claude why this request is failing (sends request + response to the AI backend) |

When the send fires, mnml spawns a background thread, opens a `Pane::Request` split below the editor, and parks it in **Sending...** state. On reply the pane flips to **Response** and shows status, elapsed, response headers, and the body.

### Inside the Request pane

| Key | Action (Response view) |
|---|---|
| `Tab` | Flip to **Edit** view |
| `r` | Re-fire the request using the pane's current field values |
| `y` | Copy the request as a curl |
| `Y` | Copy the response body |
| `e` | Same as `Tab` — flip to Edit |
| `Esc` | Return focus to the file tree |

In **Edit** mode the pane is a four-field form (URL / Method / Headers / Body) with a tab strip (Body / Headers / Params / Vars / Source) sitting between the URL row and the field content. `Tab` / `Shift+Tab` cycle which form field has the caret; arrows + Home / End / Backspace edit the focused field; `Space` on the Method field cycles through `GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS`. `Ctrl+]` / `Ctrl+[` cycle the tab strip; `Ctrl+1..5` jump to a specific tab. `Esc` in Edit view flips back to Response (the inverse of Tab) — it doesn't leave the pane.

`Ctrl+Shift+V` in Edit view pastes a curl from the clipboard and populates every field; right-clicking any row opens a field-aware menu with Send / Paste curl / Copy as curl / Switch to Response (and Cycle method on the Method row). The whole Postman-style surface — including `:http.new` to open a blank request — has its own page: [New request — Postman-style scratch pane](/manual/http-new-request/).

Writing back to the source file is automatic — saving the request pane (`Ctrl-S` in standard, `:w` in vim) re-serialises the request as a `.http` block and edits the matched block in the original file, leaving every other block untouched. Multi-block files use the `### name` separator as the match key; single-block files round-trip through a whole-file overwrite.

### The response

The Response view shows:

- **Status line** — `200 OK · 142 ms · 3.2 KB`
- **Headers** — every response header, in arrival order, dimmed
- **Body** — pretty-printed when the `Content-Type` says JSON (or the body starts with `{` / `[`); raw otherwise
- **Assertions** — `✓` / `✗` per `@assert` directive in the source
- **Captures** — `name = value` per `@capture` directive (also pinned into the running env so the next request in the file picks them up)

`Ctrl-Shift-P` → **HTTP: copy the response body** (palette id `http.copy_response_body`) copies the body verbatim to the clipboard.

### From the CLI

```bash
mnml run requests/users.http                    # send the first block
mnml run requests/users.http --env staging      # ditto, with .mnml/env/staging.env active
mnml run requests/auth/login.curl -e prod -w ~/code/api
```

Output is the request line, an arrow, the status line, the response headers, then the body. Exit code is 0 on a 2xx / 3xx response and any successful assertions; non-zero on transport error, parse error, non-success status, or a failed `@assert`. Useful from a Makefile, a CI step, or a `[tasks]` entry.

## Environments & variables

mnml substitutes `{{VAR}}` anywhere in the URL, headers, or body. Resolution order:

1. The active env file — `<workspace>/.mnml/env/<NAME>.env`, picked by `--env NAME` on the CLI or the `MNML_ENV` environment variable in the TUI.
2. Process env vars (`std::env::var`) — your shell's environment.
3. Dynamic built-ins — `{{$uuid}}`, `{{$timestamp}}`, `{{$epoch}}`, `{{$randomInt}}`, `{{$randomHex}}`, `{{$randomString}}`, `{{$randomBool}}`.

An unresolved `{{FOO}}` is left verbatim in the request — the pane shows it as-typed so a missed substitution is obvious in the response (rather than silently sending an empty string).

```text
# .mnml/env/staging.env
TOKEN=eyJhbGciOi…
BASE_URL=https://staging-api.example.com
LOGIN_EMAIL=qa@example.com
LOGIN_PASSWORD=qa-test-pass
```

`.env` files use the standard `NAME=value` shape; `#` comments and blank lines are skipped. Values aren't quoted — the rest of the line after `=` is the value, trimmed.

Per-env files go in `<workspace>/.mnml/env/` — that's a per-workspace directory mnml manages itself; put it in `.gitignore` if it holds secrets, or commit a `dev.env` template and leave `staging.env` / `prod.env` out.

```bash
mnml run requests/users.http --env staging      # one-shot env selection (CLI)
export MNML_ENV=staging && mnml                 # mnml picks up the env in-session
```

Inside the TUI, the env is loaded once per send from `MNML_ENV` (or no env if unset) — change `MNML_ENV` in your shell before launching, or use the CLI for ad-hoc env switching.

### Dynamic variables

Each call returns a fresh value:

| Var | What |
|---|---|
| `{{$uuid}}` / `{{$guid}}` | A new v4 UUID |
| `{{$timestamp}}` / `{{$epochMs}}` | Unix epoch in milliseconds |
| `{{$epoch}}` / `{{$epochS}}` | Unix epoch in seconds |
| `{{$randomInt}}` | A small random integer (< 1,000,000) |
| `{{$randomHex}}` | 8 hex chars |
| `{{$randomString}}` | A 16-char alphanumeric token |
| `{{$randomBool}}` | `true` or `false` |

## Scripts: `@set-*` / `@assert` / `@capture`

`#`-prefixed comment lines starting with `@` carry directives:

```http
# requests/orders.http
# @set-env REQUEST_ID = {{$uuid}}
# @set-header X-Request-Id = {{REQUEST_ID}}
GET https://api.example.com/orders?limit=10
Authorization: Bearer {{TOKEN}}
# @assert status == 200
# @assert header.Content-Type contains json
# @assert json $.data is array
# @assert json $.meta.total > 0
# @capture first_order_id = json $.data[0].id
# @capture trace_id = header X-Request-Id
```

**Pre-request** (run before sending):

- `@set-env NAME = VALUE` — bind `NAME` into the running env so a later `{{NAME}}` (in this file or in a chained step) resolves.
- `@set-header NAME = VALUE` — override or add a header. Values pass through `{{var}}` substitution.

**Post-response** (run against the result):

- `@assert status <op> NUMBER` — status code (`==`, `!=`, `<`, `<=`, `>`, `>=`).
- `@assert header.NAME <op> VALUE` — header value (any of the above, plus `contains`).
- `@assert json $.path <op> VALUE` — JSON-body field at the path. Path syntax is `$.foo.bar[0]` — dotted keys + `[N]` array indexing.
- `@assert json $.path is TYPE` — type check, `TYPE` is `number` / `string` / `bool` / `array` / `object` / `null`.
- `@assert body contains TEXT` — substring match anywhere in the response body.
- `@capture NAME = json $.path` — bind a response value into the env (visible to later steps in a chain).
- `@capture NAME = header NAME` — same, but from a response header.

Directive lines that don't parse are silently treated as plain comments — so a typo doesn't break the request, but it also won't fire. Run with `mnml run` to see the parse trace explicitly.

## Chains: `.chain.json`

A chain runs a sequence of requests; each step can extract values from its response into variables the later steps `{{…}}`.

```json
// .mnml/chains/auth-and-list.chain.json
[
  {
    "request": "auth/login.curl",
    "extract": { "TOKEN": "$.access_token", "USER_ID": "$.user.id" }
  },
  { "request": "users/by-id.http" },
  {
    "request": "merchant/get-locations.curl",
    "extract": { "LOCATION_ID": "$.locations[0].id" }
  }
]
```

Each step's `request` is a path resolved against (in order) the chain file's directory → `<workspace>/.mnml/requests/` → the workspace root. `extract` binds a variable name to a `$.path` into the JSON response body (the same path syntax as `@assert json`). Captures from a step's own `@capture` directives flow into the running env too — `extract` is just a shorter way to spell the common case.

Run with:

```bash
mnml chain run .mnml/chains/auth-and-list.chain.json
mnml chain run .mnml/chains/auth-and-list.chain.json --env staging
```

The chain stops at the first transport error, non-2xx/3xx status, failed `@assert`, or extraction that produces nothing — and prints a step-by-step trace so you can see which step broke and what the partial env looked like.

## Discovery: OpenAPI / Swagger → `.curl`

```bash
mnml discover https://api.example.com/openapi.json --out requests/
mnml discover ./spec/openapi.yaml --out .mnml/requests/
mnml discover ./spec/swagger.json --out .mnml/requests/ --base-url https://staging-api.example.com
```

mnml reads an OpenAPI 3 or Swagger 2 spec (local JSON file, local YAML file, or `http(s)://` URL) and writes one `.curl` stub per operation into `<out>/<tag>/<operationId-or-method-path>.curl`. Operations grouped by their first `tag`; untagged operations land in `<out>/untagged/`.

What the generator fills in:

- **Method + URL** from the operation's `path` + verb, prefixed with the spec's `servers[0].url` (or `--base-url` if you override, falling back to `{{BASE_URL}}` if neither is present).
- **Path parameters** become `{{name}}` — plug them in via `.mnml/env/*.env`.
- **`Authorization: Bearer {{TOKEN}}`** for operations with a `security` requirement.
- **JSON request body** from `requestBody.content."application/json".example`, when the spec provides one.

The result is a tree of editable stubs — open one, fill in any missing query params, fire it. Re-running `discover` won't clobber edits to files that have moved or grown — it writes the canonical filename, so move + rename to keep your edits.

## Saving + organising requests

There's no required layout, but the conventions the chain resolver and discover output settle on are:

```text
.mnml/
  env/
    dev.env
    staging.env
    prod.env
  requests/                      ← discover --out target; chain resolver searches here
    auth/
      login.curl
    users/
      list.http
      by-id.http
  chains/
    auth-and-list.chain.json
    smoke.chain.json
```

`.mnml/` is mnml's per-workspace state dir; it also holds `config.toml`, `session.json`, `undo/`, IPC files when headless. Add `.mnml/env/*.env` to `.gitignore` (or commit a `*.env.example` template); commit the request files and chains.

You can also keep request files alongside the code that serves them — `api/users.http` next to `api/users.rs` — and `http.send` works the same way. The chain resolver only searches `.mnml/requests/` for *relative* step paths; absolute or chain-relative paths work from anywhere.

## Testing: the `.test` E2E format

mnml ships a line-based `.test` format that drives the real `App` against a virtual ratatui backend — the same `App` the terminal UI runs. Tests open files, send keys, run commands, and assert on the screen contents:

```text
# tests/e2e/http.test
open requests/users.http
key normal: <space>hs
expect screen contains "200 OK"
expect screen contains "Alice"
```

Run with `mnml test [PATH…]` (defaults to `tests/e2e/`) — or under `cargo test`, since the `.test` runner is wired into the suite. The `http.send` chord works the same way in a `.test` as it does in your live editor; the request fires against your real API (or a local mock you spun up), the virtual screen catches the response, `expect screen contains` asserts on it.

This is a smoke-test surface — you can run an end-to-end "log in, fetch users, assert the response shape" flow without leaving the IDE's test loop. The full `.test` grammar is its own page.

## Where to go next

Deep-dives on individual surfaces:

- [New request — Postman-style scratch pane](/manual/http-new-request/) — `:http.new`, paste-curl from clipboard, the tabbed Edit view, the field-aware right-click menu
- [HTTP envs & templating](/manual/http-envs/) — the resolution chain (`--env` → `$MNML_ENV` → `.rqst/config`), the `.mnml/env/` over `.rqst/env/` precedence, every `{{$dynamic}}` builtin
- [HTTP sync — sources.json](/manual/http-sync/) — batch-regenerate `.curl` stubs from multiple swagger sources via `:http.sync` or `mnml sync`
- [HTTP bench](/manual/http-bench/) — 10× concurrent fire with p50 / p95 / p99 latency + status-class breakdown
- [HTTP mocks](/manual/http-mocks/) — freeze a response to a sibling `.mock.json` and replay it offline
- [HTTP history](/manual/http-history/) — `.rqst/history.jsonl`, the in-app picker, and shell-side grep / jq queries
- [HTTP captured browser traffic](/manual/http-captured/) — auto-capture from the browser pane, `:http.capture_now`, and the headless `mnml proxy --url` CLI
- [HTTP lookups](/manual/http-lookup/) — the 4-stage picker that fills env vars from real API responses
- [HTTP helpers — JWT & bearer](/manual/http-helpers/) — `:jwt.decode` and `:auth.extract_bearer`

And the surrounding context:

- [Editing](/manual/editing/) — the buffer your `.http` files live in
- [Git](/manual/git/) — version-controlling the request files alongside the code
- [Configuration](/reference/configuration/) — `[keys.global]` for rebinding `http.*` chords; `MNML_ENV` and `--env` semantics
- [AI panes](/manual/ai-panes/) — what `http.ai_debug` plugs into when a request is mis-firing
