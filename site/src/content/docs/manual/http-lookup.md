---
title: HTTP lookups
description: Fill an env var from a real API response — a 4-stage picker that fires a `.curl` file, lets you pick an item, and writes the id back to `.rqst/env/<active>.env`.
---

![:http.lookup — pick a file, fire it, pick an item, name the var, write to .env](../../../assets/tapes/http-lookup-flow.gif)

Lookups solve a very specific problem: a request needs an id (a merchant id, a user id, a location id), the id lives in some other endpoint's response, and you keep copy-pasting the value between Postman tabs. The lookup picker chains the two — fire the "list" endpoint, pick the row you want, upsert its id into your env file under a name like `MERCHANT_ID`.

The result: next time you fire any request with `{{MERCHANT_ID}}` in its URL or body, it resolves to the id you just picked. No tab-switching, no clipboard, no editing the env file by hand.

## The setup

Drop a `.curl` (or `.http` / `.rest`) file under `<workspace>/.rqst/lookups/`:

```text
<workspace>/.rqst/lookups/
├── locations.curl
├── merchants.curl
├── delivery-partners.curl
└── orders/
    └── recent.curl
```

The directory is scanned **recursively** by `crate::http::lookup::scan_lookups` (skipping `target`, `node_modules`, and any dotfile-prefixed entries); subdirectories are fine and show up in the picker with their relative path as the label (`orders/recent.curl`). All three extensions (`.curl` / `.http` / `.rest`) are picked up by the same walker. The file's name matters for the var-name suggestion (more on that below) but doesn't have to match anything else.

Each lookup file is a normal request:

```sh
# .rqst/lookups/merchants.curl
curl '{{BASE_URL}}/v2/merchants?limit=50' \
  -H 'Authorization: Bearer {{TOKEN}}' \
  -H 'Accept: application/json'
```

`{{VAR}}` substitution runs against the active env before the lookup fires — the picker can't know which merchant id to pick without a token. The `@set-*` directives also run, same as a normal `:http.send`.

## The flow — `:http.lookup`

| Surface | Call |
|---|---|
| Palette | `HTTP: lookup — fill an env var from a live API response` |
| Ex-command | `:http.lookup` |

No default keybinding. Bind under `[keys.global]` or call from the palette / fuzzy launcher.

The picker walks four stages:

### Stage 1 — pick a file

A standard fuzzy picker over every file under `.rqst/lookups/`:

```text
Lookup file
  ▸ merchants.curl
    locations.curl
    delivery-partners.curl
    orders/recent.curl
```

Type to filter. `Enter` commits the chosen file. `Esc` cancels.

If `.rqst/lookups/` is missing or empty, the picker toasts `no lookups in <path> — add a .curl file under that dir` and exits.

### Stage 2 — fire the request

`Enter` on a file kicks off a **background** HTTP send (so the UI doesn't freeze for a 30-second `reqwest::send`). A toast confirms `lookup: firing request…` and `App::tick` polls the result channel.

The send goes through the full request pipeline:

- `http::parse` on the file contents (auto-detecting cURL vs `.http` shape).
- `@set-env` and `@set-header` directives run.
- `{{VAR}}` and `{{$uuid}}` substitution against `EnvSet::select(workspace, None)`.
- A blocking `http::send` on a worker thread.

On error (transport, parse, bad URL) — the picker toasts the error and stops. On success, the response body is parsed for list items.

### Stage 3 — pick an item

The picker reads the response body looking for a JSON list shape (more on the heuristic below). When it finds one, every item gets a label and an id, and the second picker opens:

```text
Lookup item · merchants.curl
  ▸ Hot Pizza Co (id: 2148)
    Sushi Spot (id: 1042)
    Tacos & Co (id: 8801)
```

Type to filter (matches label or id). `Enter` commits. `Esc` cancels.

If the body doesn't look like a list:
- `lookup: merchants.curl response wasn't a recognized list shape` — no parseable array found.
- `lookup: merchants.curl returned 0 items` — array was empty.

### Stage 4 — enter the var name

The picker pops a prompt:

```text
Env var name for Hot Pizza Co (2148):
> █
```

Type the env var name you want this id under (`MERCHANT_ID`, `USER_ID`, `LOCATION_ID`, whatever's conventional in your env file), then `Enter`. The prompt starts empty so you can pick whatever name fits — no auto-derived suggestion. Convention in mnml's env files is uppercase-snake-case ending in `_ID`.

The picker writes `<var>=<id>` to `<workspace>/.rqst/env/<active>.env` — preserving every other line, comments and ordering intact. Existing vars with the same name are replaced in place; new vars are appended:

```text
# .rqst/env/dev.env (before)
BASE_URL=https://dev-api.example.com
TOKEN=eyJhbGci...
MERCHANT_ID=1042
```

```text
# .rqst/env/dev.env (after picking Hot Pizza Co)
BASE_URL=https://dev-api.example.com
TOKEN=eyJhbGci...
MERCHANT_ID=2148
```

The active env name comes from `EnvSet::select(workspace, None).name()` — `$MNML_ENV` or `.rqst/config`'s `default_env`, falling back to `"dev"` when neither is set. The write lands in `.rqst/env/`, not `.mnml/env/` — the legacy path, deliberately, so the convention stays portable with rqst.

The toast confirms `wrote <var>=<id> → <env-file>`.

## The list-shape heuristic

Step 3 is the most opinionated piece. Lookup tries four shapes, in order:

```json
// 1. Bare array
[ { "id": 1, "name": "First" } ]

// 2. { "data": [ ... ] }
{ "data": [ { "id": 1, "name": "First" } ] }

// 3. { "items": [ ... ] }
{ "items": [ { "id": 1, "name": "First" } ] }

// 4. { "results": [ ... ] }
{ "results": [ { "id": 1, "name": "First" } ] }

// 5. Single-key object whose value is an array
{ "merchants": [ { "id": 1, "name": "First" } ] }
```

The single-key fallback lets the picker handle the common "REST envelope with a domain-named field" pattern (`{"orders": [...]}`) without per-API config. Multi-key envelopes (`{"data": [...], "meta": {...}}`) match the `data` arm and ignore `meta`.

### Id field

For each item in the array, the id is the first match from:

| Priority | Field |
|---|---|
| 1 | `id` (literal) |
| 2 | `Id` (PascalCase) |
| 3 | `_id` (MongoDB style) |
| 4 | Any field whose lowercased name ends in `id` and is longer than 2 chars (`merchantId`, `userId`, `deliveryPartnerId`) |

The id can be a string or a number — numbers are stringified (`2148` → `"2148"`) for the env write. Objects and arrays and nulls in the id slot disqualify the item (it's silently skipped).

### Label field

The display label uses the first match from:

| Priority | Field |
|---|---|
| 1 | `name` |
| 2 | `displayName` |
| 3 | `label` |
| 4 | `title` |
| 5 | `summary` |
| Fallback | The id itself |

When none of those fields are present, the picker still shows the row — just labeled with its id (`(id: 2148)`).

## What gets written

The env upsert is a line-aware replace:

- Existing line `MERCHANT_ID=1042` → replaced with `MERCHANT_ID=2148`. Surrounding comments and blanks preserved.
- No existing line → appended at end, with a trailing newline guard.
- Var name is rejected when blank (`lookup: var name can't be empty`).
- Value containing a newline is rejected (`lookup: value can't contain newline`) — the env-line format doesn't support multi-line values.

The write is atomic — `std::fs::write` overwrites the file in place. The parent directory is created if missing.

## What lookups aren't

- **A way to pick multiple items.** One Enter, one id, one env write. To pick five merchants, run `:http.lookup` five times with five different var names (`MERCHANT_A_ID`, `MERCHANT_B_ID`, …) — or write a chain that calls the same lookup endpoint and `@capture`s into different vars.
- **A way to pick by anything other than id.** Labels are display-only. If you want to filter by status, name, or anything else, narrow the picker's fuzzy filter — type the name, press Enter on the right row.
- **A way to pick a non-id value.** The fourth stage writes whatever the id field resolved to. To capture, say, a merchant's currency code or hourly rate, you'd need `@capture currency = json $.items[0].currency` in a regular request — see [HTTP envs & templating](/manual/http-envs/) for `@capture`.
- **A way to discover endpoints.** The picker only fires lookups that already exist as files under `.rqst/lookups/`. Adding a new endpoint to the list is `cp some.curl .rqst/lookups/merchants.curl`.

## Practical recipes

### Set up a lookup once, use forever

```bash
# Once, when you start using a new endpoint:
$ mkdir -p .rqst/lookups
$ cat > .rqst/lookups/merchants.curl <<'EOF'
curl '{{BASE_URL}}/v2/merchants?limit=50' \
  -H 'Authorization: Bearer {{TOKEN}}'
EOF

# Every time you need a merchant id:
:http.lookup → merchants.curl → pick a row → Enter

# Now {{MERCHANT_ID}} works in any other request.
```

### Chain a lookup into a real request

```http
# requests/orders/get.http

# @set-env MERCHANT_ID = {{$uuid}}    ← override the lookup-set value with a fresh UUID
GET {{BASE_URL}}/v2/merchants/{{MERCHANT_ID}}/orders?limit=10
Authorization: Bearer {{TOKEN}}
```

The lookup-written `MERCHANT_ID` resolves from `.env` by default, but `@set-env` overrides for a single request — useful for testing with synthetic ids.

### Cascade env files

Pick a merchant id in `dev`, switch to staging, expect the same merchant doesn't exist there. The picker writes to whatever env is *currently active* (`MNML_ENV=staging` → staging env file). Rerun `:http.lookup` to repopulate after switching.

## Next

- [HTTP client](/manual/http/) — the parent overview: how the lookup's chosen `.curl` file is parsed and sent
- [HTTP envs & templating](/manual/http-envs/) — `{{MERCHANT_ID}}` resolution rules and `@capture` (the chain-style equivalent of lookup writes)
- [HTTP history](/manual/http-history/) — lookup's background fires are *not* logged here; the user-facing send is what counts
- [HTTP helpers — JWT & bearer](/manual/http-helpers/) — when the lookup needs a fresh token, `auth.extract_bearer` + `jwt.decode` help debug it
