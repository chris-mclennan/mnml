---
title: HTTP response schema validation
description: Sidecar `.schema.json` files validate every response body — `:http.show_schema_errors` opens the full error list, `:http.revalidate_schema` re-runs after editing the schema.
---

![drop a .schema.json next to a .curl, fire the request — the Response view's footer flips to ✓ Schema valid or ✗ Schema: N errors, and :http.show_schema_errors opens the full list](../../../assets/tapes/http-schema-validate.gif)

mnml validates HTTP response bodies against JSON Schema sidecars dropped next to the request file. Park a `users.schema.json` beside `users.curl`, fire the request, and the Response view paints a one-line footer — `✓ Schema valid (users.schema.json)` or `✗ Schema: 3 errors (users.schema.json) — :http.show_schema_errors`. The full validator output is one ex-command away.

The point is **contract-driven debugging**. When a downstream change quietly drops a field, the assertion arc (`@assert json $.foo`) needs you to remember every field. Schema validation needs the schema — which you already wrote, or generated from the API spec — and surfaces every drift at once.

## The sidecar pattern

For a request file at `<path>/<name>.<ext>`, mnml resolves a sibling schema:

1. **`<path>/<name>.schema.json`** — preferred. For `requests/users.curl`, that's `requests/users.schema.json`.
2. **`<path>/<name>.<ext>.schema.json`** — fallback. For `requests/users.curl`, `requests/users.curl.schema.json`.

The first form is the recommended layout: it reads cleanly next to the source, and it stays meaningful if you migrate the request file's extension (`.curl` → `.http`). The two-suffix form exists for files like `users.http` where stripping the extension leaves you with a less identifiable stem.

```text
requests/
  users.curl                ← the request
  users.schema.json         ← preferred sidecar location

requests/
  users.http                ← the request
  users.http.schema.json    ← fallback location (also accepted)
```

A single schema per source file in v1. Per-block schemas for multi-block `.http` files (`users.<block>.schema.json`) are queued as a v2 follow-up.

### What the schema looks like

Plain JSON Schema (draft-07 onward — mnml uses the `jsonschema` crate's auto-detected validator).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["id", "name", "email"],
  "properties": {
    "id":    { "type": "integer", "minimum": 1 },
    "name":  { "type": "string",  "minLength": 1 },
    "email": { "type": "string",  "format": "email" },
    "role":  { "type": "string",  "enum": ["admin", "member", "viewer"] }
  },
  "additionalProperties": false
}
```

Hand-write them, or generate from your OpenAPI spec — `mnml discover SPEC` doesn't emit schemas yet, but the operation's response schema is sitting right there in the spec for you to copy across.

## When validation runs

Every successful `:http.send` triggers validation. The flow:

1. The HTTP worker returns a `ResponseView` (status + headers + body).
2. `crate::http::schema::validate_for(source_path, body)` resolves the sidecar and runs the validator.
3. The result lands on `ResponseView.schema_result` — a `SchemaResult` carrying status + errors + the schema path.
4. The Response view's footer line reads `schema_result` and renders one of six states.

No sidecar = no footer. No noise — schema validation only surfaces when you've opted in by dropping a schema file.

Validation also runs against `:http.send_streaming` responses (the streaming worker validates the accumulated body once the stream completes). It doesn't run against `:http.replay_mock` or `:http.bench` runs — replay is a UI flip, not a real send; bench results don't materialise per-shot bodies.

## The footer states

The Response view paints exactly one of six footer states:

| State | Footer | Colour |
|---|---|---|
| `Valid` | `✓ Schema valid (users.schema.json)` | green, bold |
| `Invalid` | `✗ Schema: 3 errors (users.schema.json) — :http.show_schema_errors` | red, bold |
| `NoSidecar` | (no footer) | — |
| `ReadError` | `⚠ Schema read error (users.schema.json): <err>` | yellow |
| `SchemaParseError` | `⚠ Schema parse error (users.schema.json): <err>` | yellow |
| `NotJson` | `⚠ Body isn't JSON — schema (users.schema.json) skipped` | yellow |

Each error case shows up distinctly so the failure mode is obvious from the response without opening another buffer:

- **`NotJson`** — the response body wasn't parseable JSON. A schema that expects an `application/json` body but the server returned HTML / plain text / an empty 204. Silent pass-through is the wrong move (the schema was *meant* to apply); the warning makes it visible.
- **`ReadError`** — the sidecar file exists but `read_to_string` failed (permissions, mid-write truncation, weird filesystem). Rare but distinguishable from a malformed schema.
- **`SchemaParseError`** — the sidecar is there and readable but isn't a valid JSON Schema document. Surfaced verbatim from `serde_json` or `jsonschema::validator_for`. Edit the schema, then `:http.revalidate_schema` (below) to re-run without re-firing the request.

## `:http.show_schema_errors`

When the footer reads `✗ Schema: N errors`, this command opens a `[schema-errors]` scratch buffer listing every validator error.

| Surface | Call |
|---|---|
| Palette | `HTTP: open scratch buffer with response schema validation errors` |
| Ex-command | `:http.show_schema_errors` |

The scratch contents:

```text
✗ Schema validation failed (/path/to/requests/users.schema.json)
  3 error(s):

    1. /email: "alice@" is not a "email"
    2. /role: "owner" is not one of ["admin", "member", "viewer"]
    3. /id: 0 is less than the minimum of 1
```

Each entry starts with the JSON Pointer into the response body where validation failed — `/email`, `/role`, `/data/0/id`. mnml prefixes the path so a screenful of errors scans cleanly; jsonschema's own message (`"alice@" is not a "email"`) follows after the colon.

The errors are emitted in the validator's iteration order, which is roughly schema-walk order. For deeply nested schemas this means you read failures from the outermost property inward.

### Edge-case toasts

This command short-circuits to a toast — no scratch — when the response wasn't an `Invalid` schema result:

- `schema: no sidecar (.schema.json) for this request` — never had a sidecar; nothing to show.
- `✓ schema valid (path/to/schema.json)` — the response passed; nothing to show, but you get a confirmation.
- `schema: no completed response` — fired before the response landed (or after a transport error). Wait for `Done`.

The `ReadError` / `SchemaParseError` / `NotJson` states each open a single-line scratch with the matching message, so you can copy-paste the path into a shell and inspect the schema yourself.

## `:http.revalidate_schema`

Edit the sidecar `.schema.json` and want to re-test the **existing** response body? That's `:http.revalidate_schema` — no re-fire needed.

| Surface | Call |
|---|---|
| Palette | `HTTP: re-run schema validation on the active Request pane's last response` |
| Ex-command | `:http.revalidate_schema` |

The flow:

1. Reads the response body and source path off the active `Pane::Request`.
2. Calls `validate_for(source_path, body)` — the same code path the original send took.
3. Writes the fresh `SchemaResult` onto the response.
4. Toasts the new state — `✓ schema re-validated: valid`, `✗ schema re-validated: 3 error(s)`, etc.

The Response footer re-paints on the next frame.

Use it when:

- You're iterating on the schema itself — tightening a `required` list, adding a `format`, narrowing an `enum`. Edit, save, `:http.revalidate_schema`, repeat.
- The original response was `NotJson` because you forgot the `Accept: application/json` header; re-fire normally instead.
- The original response was `NoSidecar` and you just dropped the schema file. (`:http.revalidate_schema` picks it up.)

A re-fire (`r` from Response view) revalidates implicitly — every successful send runs validation. `:http.revalidate_schema` is the schema-only path when the network call is expensive or non-idempotent.

## Workflow

The natural rhythm:

1. **Drop a schema** next to the request. Generated from the OpenAPI spec, hand-written from a `.mock.json` you saved last week, or sketched against a working response body.
2. **Fire the request.** The footer says `✓ Schema valid (file)` or `✗ Schema: N errors (file)`.
3. **Drill in.** If errors, `:http.show_schema_errors` opens the full list.
4. **Iterate.** Either fix the API / the request, or tighten the schema. After a schema edit, `:http.revalidate_schema` re-checks against the in-pane response.

### Pairing with `@assert`

Schema validation and `@assert` directives stack — they validate at different levels:

- **`@assert`** — surgical, one-off checks. `status == 200`, `header.Content-Type contains json`, `json $.data[0].id is number`. Inline in the request file, ergonomic for the rare "this specific value must be X" check.
- **Schema** — structural. *Every* field that ever ships on this endpoint's success response, all at once. Lives in a separate file so the structure is reusable across requests (one `user.schema.json` referenced from every request that returns a user).

Use them together: an `@assert status == 200` plus a schema validates the success-path body shape without typing out a `@assert json` for every leaf field.

### Adding to `.gitignore`?

No. Commit `.schema.json` files. They're contracts, not secrets. Treat them like the OpenAPI spec they probably came from.

## Next

- [HTTP client](/manual/http/) — `.http` / `.curl` / `.rest` files, `:http.send`, the Response view
- [HTTP Request pane — tabs & layout](/manual/http-edit-tabs/) — where the schema footer renders, plus `@assert` / `@capture` rows
- [HTTP mocks](/manual/http-mocks/) — save a known-good response as a sibling `.mock.json` — the obvious starting point for sketching a schema
- [HTTP envs & templating](/manual/http-envs/) — the substitutions that ran before the response landed
