---
title: HTTP realistic request generation
description: How mnml turns a swagger spec into ready-to-fire request stubs — faker vocab, dynamic value substitution, coherent object graphs, well-known env-var IDs, login-flow chain starters, and the one-click Reroll chip.
---

`mnml discover` and `mnml sync` turn OpenAPI / Swagger specs into `.curl` stubs. The 2026-07-09 roadmap took those stubs from "types-only placeholder soup" to "ready-to-fire scaffolds" — bodies read like real single records, `{merchantId}` becomes `{{MERCHANT_ID}}` (not `{{merchantId}}`), timestamps refresh on every send, login endpoints ship with `# extract:` hints, and a one-click **Reroll** chip on the Request pane rolls fresh dynamic values without hand-editing JSON.

This page is the tour through the seven tiers of that work, plus the two smaller UX pieces that landed alongside — the auto-format-body toggle and the `⚡ AI` debug-prompt chip on failed responses.

The mental model: the generator has always been schema-driven. What changed is what it does *besides* consulting the schema. Property names now key into a small vocabulary of realistic values. Sibling fields inside the same object cross-reference each other. Path parameters like `{merchantId}` route through a table of well-known env vars so users tune once in `.mnml/env/dev.env` and every stub picks up the value. Login endpoints emit `# extract:` hints and a chain-starter file. Timestamps and UUIDs the swagger author baked in get swapped for `{{$isoTimestamp}}` / `{{$uuid}}` so re-syncs stop reporting cosmetic drift.

## Tier 1 — dynamic value substitution

Swagger authors bake in concrete example values for `createdAt` fields and `id` UUIDs. Every re-sync then reports those as changed even though nothing meaningful moved — the sync workflow drowns in noise. Tier 1 kills that noise.

`mnml discover --normalize` (short `-n`) rewrites two patterns in generated JSON bodies:

| Pattern | Substitution |
|---|---|
| ISO 8601 timestamp string (`"2020-01-01T00:00:00Z"`, `"2020-01-01T00:00:00.123+05:30"`) | `"{{$isoTimestamp}}"` |
| Lowercase UUID string (`"550e8400-e29b-41d4-a716-446655440000"`) | `"{{$uuid}}"` |

Uppercase UUIDs and date-only strings (`"2020-01-01"`) are deliberately excluded — too many false positives on user constants and business data.

At fire time the runtime substitutes fresh values:

- `{{$isoTimestamp}}` (aliases `{{$isoTime}}`, `{{$nowIso}}`) → `2026-07-10T14:32:07.123456789Z` (`.NET`-shape, nanosecond precision)
- `{{$uuid}}` → a fresh v4 UUID

Every send gets a fresh timestamp / UUID. Re-syncs are deterministic — the substitution runs once at discover time; from then on the file compares byte-for-byte across syncs.

### Surface

| Where | How to opt in |
|---|---|
| CLI | `mnml discover SPEC --normalize` (or `-n`) |
| CLI | `mnml sync --normalize` |
| CLI | `mnml sync-check --normalize` |
| Config | `[http] sync_normalize = true` |
| Palette | `http.toggle_sync_normalize` |
| Ex | `:set syncnormalize` / `:set nosyncnormalize` / `:set syncnormalize!` (aliases `sn`) |

Off by default so nothing changes for existing callers.

## Tier 2 — faker vocab

The prior schema-driven synthesizer produced `"firstName": "string"`, `"quantity": 0`, `"currency": "string"`. Tier 2 keys off the property name and returns something plausible.

**Before → After:**

| Property | Before | After |
|---|---|---|
| `firstName` / `givenName` | `"string"` | `"John"` |
| `lastName` / `familyName` | `"string"` | `"Smith"` |
| `email` / `emailAddress` | `"string"` | `"user@example.com"` |
| `phone` / `phoneNumber` | `"string"` | `"555-0100"` |
| `city` | `"string"` | `"San Francisco"` |
| `country` | `"string"` | `"United States"` |
| `currency` | `"string"` | `"USD"` |
| `quantity` / `count` | `0` | `1` |
| `pageSize` / `perPage` / `limit` | `0` | `25` |
| `rating` / `score` | `0` | `5` |
| `status` | `"string"` | `"active"` |
| `enabled` / `active` | `false` | `true` |
| `merchantId` / `restaurantId` | `0` | `"{{MERCHANT_ID}}"` |
| `userId` / `customerId` | `0` | `"{{USER_ID}}"` |
| `orderId` / `transactionId` | `0` | `"{{ORDER_ID}}"` |

The lookup is case-insensitive on the normalized property name (`firstName`, `first_name`, `FirstName`, `first-name` all collapse to `firstname`). Multiple names map to the same value.

Deterministic — every call for the same name returns the same value, so re-syncs don't churn.

The full vocab lives in `src/http/faker.rs`. Categories covered:

- **Names / people** — `firstName`, `lastName`, `fullName`, `middleName`, `username`, `nickname`
- **Contact** — `email`, `phone`, `fax`, plus variants
- **Address** — `address1` / `address2`, `city`, `state`, `zipCode`, `country`, `countryCode`
- **Company** — `company`, `brand`, `organization`
- **Web** — `url`, `domain`, `ipAddress`, `userAgent`
- **Commerce** — `currency`, `sku`, `productName`, `orderRef`
- **Locale** — `language`, `locale`, `timezone`
- **Descriptors** — `description`, `comment`, `title`, `slug`, `tag`
- **Status** — `status` → `active`; `kind` / `type` / `category` → `default`
- **Colors** — `color` / `hexColor` → `#4A90E2`

Numeric fields:

- `quantity` / `qty` / `count` / `size` → `1`
- `page` → `1`; `pageSize` / `perPage` / `limit` → `25`; `offset` / `skip` → `0`
- `price` / `amount` / `total` / `subtotal` → `9.99`
- `rating` / `score` / `stars` → `5`
- `year` → `2026`, `month` → `1`, `day` → `1`, `hour` → `12`, `minute` → `30`, `second` → `0`

Boolean fields default to `false` unless the name suggests "on" — `enabled` / `active` / `isEnabled` / `on` → `true`; `disabled` / `inactive` / `cancelled` / `archived` / `off` → `false`.

Unknown property names fall through to the existing generic defaults (`"string"`, `0`, `false`) — nothing changes if no rule matches.

User-provided `example` or `default` values pass through untouched. Faker only fills the naive `"string"` / `0` / `false` fallback.

## Tier 3 — object graph coherence

Sibling fields inside the same object get cross-derived so the record reads as a single plausible entity — not independent faker lookups pasted next to each other.

**Before:**

```json
{
  "firstName": "John",
  "lastName": "Smith",
  "emailAddress": "user@example.com",
  "fullName": "John Smith",
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z",
  "amount": 9.99,
  "quantity": 3,
  "total": 9.99
}
```

**After:**

```json
{
  "firstName": "John",
  "lastName": "Smith",
  "emailAddress": "john.smith@example.com",
  "fullName": "John Smith",
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:30:00Z",
  "amount": 9.99,
  "quantity": 3,
  "total": 29.97
}
```

Rules the coherence pass applies per-object (recursing into nested objects and arrays):

- `email` / `emailAddress` / `emailId` — derived from `firstName` + `lastName` when both present.
- `fullName` / `name` / `displayName` — derived from the same pair.
- `username` — first-initial + lastname (`jsmith`).
- `updatedAt` / `modifiedAt` / `endTime` / `endsAt` — bumped 30 minutes past their `createdAt` / `insertedAt` / `startTime` / `startsAt` counterpart when both are ISO strings.
- `total` — computed from `amount` × `quantity`, or `price` × `quantity`, or `subtotal` + `tax` when total is the naive 9.99 fallback.

Only the canonical faker defaults get overridden — user-provided `example` / `default` values still pass through. Coherence runs before Tier 1 normalize, so ISO timestamps rewritten to `{{$isoTimestamp}}` still show the coherent 30-minute delta at the moment of normalization.

## Tier 4 — well-known env-var IDs in path parameters

Tier 2's `id_env_var` mapping applied to body properties. Tier 4 extends it to path parameters.

**Before:**

```
/merchants/{merchantId}/orders/{orderId}
  →  /merchants/{{merchantId}}/orders/{{orderId}}
```

**After:**

```
/merchants/{merchantId}/orders/{orderId}
  →  /merchants/{{MERCHANT_ID}}/orders/{{ORDER_ID}}
```

Users tune `.mnml/env/dev.env` once:

```env
MERCHANT_ID=42
ORDER_ID=abc-123
```

…and every stub across the workspace picks up the values. No per-file editing.

The recognized names (case-insensitive, snake/camel/kebab all collapse):

| Path param name(s) | Env var |
|---|---|
| `merchantId` / `restaurantId` / `storeId` | `MERCHANT_ID` |
| `userId` / `accountId` / `customerId` | `USER_ID` |
| `locationId` / `siteId` / `branchId` | `LOCATION_ID` |
| `surveyId` | `SURVEY_ID` |
| `orderId` / `transactionId` | `ORDER_ID` |
| `productId` / `itemId` / `menuItemId` | `PRODUCT_ID` |
| `brandId` | `BRAND_ID` |
| `questionnaireId` | `QUESTIONNAIRE_ID` |
| `campaignId` | `CAMPAIGN_ID` |

Unknown path params fall through to the existing camelCase templating — `/things/{thingId}` still becomes `/things/{{thingId}}`, so nothing regresses.

### `.env.example` seeding

Discover writes a `.env.example` seed next to the generated stub tree listing every env var the vocab knows about, so users see the full menu of overridable IDs at a glance:

```env
# .mnml/env/dev.env.example — generated by mnml discover
BRAND_ID=
CAMPAIGN_ID=
LOCATION_ID=
MERCHANT_ID=
ORDER_ID=
PRODUCT_ID=
QUESTIONNAIRE_ID=
SURVEY_ID=
USER_ID=
```

Copy to `dev.env` and fill in what you use. Empty values still resolve — the runtime substitutes the empty string, which is exactly what a request would send if you'd left `{{MERCHANT_ID}}` unset.

## Tier 5 — query + header params

Discover previously silently dropped swagger `parameters` entries with `in: query` or `in: header`. Tier 5 ports the missing handling.

**Required parameters** are baked into the generated curl:

- `in: query` → appended to the URL as `?name={{name}}` (first) / `&name={{name}}` (subsequent).
- `in: header` → new `-H '<name>: {{name}}'` line.

**Optional parameters** surface as commented-out hints below the curl block:

```sh
curl 'https://api/things?merchantId={{MERCHANT_ID}}' \
  -X GET \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer {{TOKEN}}'

# Optional parameters (uncomment to use):
#   ?cursor={{cursor}}
#   -H 'X-Debug: false'
```

The value fallback ladder per parameter:

1. `example` on the schema
2. `default` on the schema
3. `enum[0]` on the schema
4. `{{paramName}}` template placeholder

`$ref` in the parameters array is resolved through the spec's components. Path-level + operation-level parameters merge (operation wins on name collision).

## Tier 6 — login-flow extract hints + chain starters

Login-shaped endpoints get two things automatically:

1. **`# extract:` hints** — inline comments in the `.curl` file for chain-runner consumption.
2. **A `<tag>-flow.chain.json` starter** — a two-step chain wiring the login into a follow-up call.

A login endpoint is a `POST` to a path ending in `login`, `signin`, `sign-in`, `sign_in`, `token`, `authenticate`, or `sessions`.

### `# extract:` hints in the `.curl`

```sh
# login
# POST /auth/login
# extract: TOKEN=$.access_token
# extract: REFRESH_TOKEN=$.refresh_token
curl 'https://api.example.com/auth/login' \
  -H 'accept: application/json' \
  ...
```

The hints are picked from the response schema — properties named `access_token`, `refresh_token`, `id_token` (any case, hyphen or underscore) map to `TOKEN` / `REFRESH_TOKEN` / `ID_TOKEN`. When the schema is absent or lacks a token field: `TOKEN=$.access_token` (the OAuth 2.0 norm) is the fallback.

Non-login endpoints get no hint — the detection is narrow to avoid false positives on unrelated POSTs.

### Auto-emitted `<tag>-flow.chain.json`

For any swagger tag that contains a login-shaped endpoint, discover writes `<out>/<tag>-flow.chain.json` — the login step (with `extract` map) plus one follow-up step from the same tag:

```json
[
  {
    "request": "auth/login.curl",
    "extract": { "TOKEN": "$.access_token" }
  },
  { "request": "auth/getMe.curl" }
]
```

Users edit from there. Never clobbers an existing chain file. Run with `:http.run_chain` (or `mnml chain run <path>`); see [HTTP chains](/manual/http-chains/) for the runner.

## Tier 7 — edge-case body variants (opt-in)

`mnml discover --edge-cases` (short `-e`) emits, for every operation with a JSON body schema, two additional stubs alongside the happy-path:

```
createThing.curl           ← happy path (Tier 2/3 default)
createThing.edge-min.curl  ← boundary minimums
createThing.edge-max.curl  ← boundary maximums
```

Rules for each variant (relative to happy-path):

| Type | `edge-min` | `edge-max` |
|---|---|---|
| String | LAST enum value; else `minLength` chars | FIRST enum value; else `maxLength` chars (max 64) |
| Integer / Number | `minimum` (or `0`); respects `exclusiveMinimum` | `maximum` (or `9999`); respects `exclusiveMaximum` |
| Boolean | `false` | `true` |
| Array | 1 element | 3 elements |
| `oneOf` / `anyOf` | LAST branch | FIRST branch |

Off by default — `sync` doesn't opt in (single flag propagation would need a config toggle too). Users run standalone `mnml discover --edge-cases` to generate an edge-case pack; `.gitignore` the `edge-*.curl` files if you don't want them in your workspace.

The trio per endpoint lets you exercise edge-case handling — 8-char names, max-score ratings, last-enum states — without hand-authoring three curls per endpoint.

## The `↻ Reroll` chip — one-click body regeneration

The Request pane's **Body** tab strip carries an `↻ Reroll` chip (green, left of the `{ } Format` chip). Click it — or run `:http.regenerate_body` — and every ISO 8601 timestamp and lowercase UUID in the body refreshes with fresh values:

- Concrete values (`"2020-01-01T00:00:00Z"`) — normalize to `{{$isoTimestamp}}`, expand through the runtime template layer to a fresh timestamp.
- `{{$dynamic}}` templates already in the body — resolve at expand time too.
- Non-matching strings (business data, static text) — untouched.

The intended flow: fire an order, roll fresh customer / order IDs, fire another. Repeat. No copy-paste, no hand-editing.

The chip only paints when the Body tab is active and the body content parses as JSON. `http.regenerate_body` reuses `discover::normalize_dynamic_values_public` — the exact same detection regex as Tier 1, so behavior stays consistent between generate-time normalization and reroll-time regeneration.

## Auto-format body — `[http] auto_format_body`

Mirrors the existing `SplitOrientation::Auto` idiom: "always pretty" mode for the Request pane's body.

```toml
# ~/.config/mnml/config.toml
[http]
auto_format_body = true   # default
```

When on, the Body auto-prettifies as JSON at three natural touchpoints:

1. **On paste** (`:http.paste_curl` or bracketed-paste of a curl command) — pasted bodies often arrive as compressed one-liners; the pane shows the pretty version.
2. **On send** (`:http.send` or `r` in Response view) — format right before firing so what gets sent matches what's on screen.
3. **On load-from-file** (opening a `.curl` / `.http` via `http.send`) — handles requests saved in prior sessions with compressed bodies.

Not fired on every keystroke — that would fight with typing. The idiom is "prettify at natural pause points"; the user's in-progress edits are never interrupted.

Silent no-op when the body doesn't parse as JSON (raw form-encoded / plain text / XML pass through untouched).

Controls:

| Surface | Call |
|---|---|
| Palette | `http.toggle_auto_format_body` (flips + immediately formats the current pane if turning on) |
| Ex | `:set autoformat` / `:set noautoformat` / `:set autoformat!` (aliases `af` / `noaf` / `af!`) |
| Config | `[http] auto_format_body = false` to opt out |

The existing `{ } Format` chip on the Body tab + the `Shift+Alt+F` chord remain — they're the "format NOW" path (works even when auto is off).

## The `⚡ AI` chip on failed responses

When a response comes back non-2xx, schema-invalid, or a transport error, the Response tab strip grows an `⚡ AI` chip (orange, bold, immediately left of `wrap`). One click copies a structured markdown prompt to the system clipboard — ready to paste into Claude, Codex, ChatGPT, or any AI CLI.

The prompt structure:

```markdown
## Request
METHOD URL
Headers (sensitive values redacted)
Body (truncated to 2 KB)

## Response
HTTP <status>  (elapsed: <ms>ms)
Headers + Body

## Env / context
- active env: <name>
- defined vars used: TOKEN, MERCHANT_ID
- undefined vars: DATABASE_URL

## Schema validation
- <errors>

## What I've tried
(fill me in)
```

### Sensitive-value redaction

Headers matching (case-insensitive) `authorization`, `cookie`, `*api-key`, `*api_key`, `*apikey`, `*token`, `x-*-secret`, `proxy-authorization` get their values replaced with `<redacted>`. Auth schemes survive so the AI still sees the shape — `Authorization: Bearer <redacted>` reads as bearer-token auth, `Authorization: Basic <redacted>` reads as basic auth.

### Env classification

Every `{{VAR}}` referenced in the URL, headers, or body gets bucketed:

- **Defined** — the active env has a value for the key. Reported by name only, not value.
- **Undefined** — the substitution resolves to the literal `{{VAR}}` string at fire time. Named so you can see what's missing before pasting into the AI.

Built-in dynamics (`$uuid`, `$isoTimestamp`, `$timestamp`) are excluded — they can't be undefined.

### Surface

| Surface | Call |
|---|---|
| Chip | `⚡ AI` on the Response tab strip when the response is a failure |
| Palette | `http.copy_ai_prompt` |

Hover the chip: `click: copy a debug prompt to clipboard (redacts Authorization, api keys, cookies)`. No default keybinding — bind it under `[keys.global]` if you reach for it often.

Not shown on 2xx responses that also passed schema validation — for a successful send there's nothing to debug.

## `sync-check` — dry-run drift report

Paired with `sync`, `sync-check` reports what *would* change if you ran `sync` — without writing anything to the `out` directories.

| Surface | Call |
|---|---|
| Palette | `http.sync_check` |
| CLI | `mnml sync-check [--workspace DIR] [--normalize]` |

The palette command opens a `[sync-check]` scratch pane with a markdown report:

```
# http.sync_check — drift report

## payments
  spec: https://api.example.com/openapi.json
  compared against: /workspace/.rqst/requests/payments
  drift: 2 added, 1 removed, 4 changed
    + charges/create-refund.curl
    + subscriptions/pause.curl
    - invoices/mark-paid.curl
    ~ charges/list.curl
    ~ customers/create.curl
    ~ customers/update.curl
    ~ webhooks/list.curl

## billing
  clean — no drift

# summary — 7 file(s) differ across all sources
# run `:http.sync` to apply (overwrites existing stubs)
```

Under the hood: each source's stubs regenerate into a `tempfile::TempDir` (auto-cleaned on Drop), then `walk_curls` snapshots `{relative_path → contents}` for both the temp tree and the real `out` tree and computes added / removed / changed sets. No writes to the real `out` directory.

Toast summary: `clean — no drift` on 0 drift, else `N file(s) differ` so users get the headline without opening the pane.

The CLI variant writes the same trace to stdout and exits with:

- `0` — no drift
- `2` — drift found (distinct from FAILURE=1 so scripts can gate on "drift found" vs "the tool crashed")

Useful as a CI gate: `mnml sync-check --normalize` in a pre-commit hook fails fast if the local `.curl` tree has drifted from upstream, without actually rewriting anything.

## Next

- [HTTP sync — sources.json](/manual/http-sync/) — batch regeneration workflow the tiers are built on
- [HTTP client](/manual/http/) — `mnml discover`, `.curl` files, the file-first surface
- [HTTP envs & templating](/manual/http-envs/) — how `{{MERCHANT_ID}}` and `{{$isoTimestamp}}` resolve at fire time
- [HTTP chains](/manual/http-chains/) — the `.chain.json` runner Tier 6 emits starters for
- [HTTP Request pane — variables, edit split & panel filter](/manual/http-request-polish/) — `{{VAR}}` highlighting + the pane's edit surface the Reroll chip lives on
