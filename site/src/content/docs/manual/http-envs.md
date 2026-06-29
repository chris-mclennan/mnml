---
title: HTTP envs & templating
description: How mnml picks the active env, where it looks for the `.env` file, and the rules for `{{VAR}}` and dynamic `{{$uuid}}` / `{{$timestamp}}` substitution.
---

Every request mnml sends runs through one substitution pass. `{{VAR}}` placeholders in the URL, in every header value, and in the body all resolve against a single `EnvSet` — a named environment loaded from a workspace-local `.env` file plus a small dictionary of dynamic built-ins. Unresolved placeholders are left verbatim, so a misspelled name shows up in the response instead of silently disappearing.

This page is the precise rules — which file gets loaded, in what order, and what each variable kind expands to.

## The resolution chain

`EnvSet::select_with_config_default(workspace, explicit, config_default)` picks the env name in this order:

1. **Explicit** — `--env NAME` on the CLI, or the `LookupVarName` argument when a flow passes one through. The TUI doesn't take an `explicit` argument today — it's CLI-only.
2. **`$MNML_ENV`** — the process env var. Useful as a sticky default for the editor session (`export MNML_ENV=staging` in your shell before launching mnml).
3. **`[http] default_env`** — the mnml-native TOML key. Lives in `<workspace>/.mnml/config.toml` (per-workspace) or `~/.config/mnml/config.toml` (user-global). Per-workspace wins, same as every other config key. Added 2026-06-28 so `$MNML_ENV` (process-wide, shared across every shell tab) isn't the only knob outside the legacy `.rqst/config`.
4. **`<workspace>/.rqst/config`'s `default_env=…`** — the legacy rqst-format config file. If you've imported a workspace from rqst, this lets mnml pick up its `dev` / `staging` default without any extra setup.

```toml
# <workspace>/.mnml/config.toml — sticky workspace env
[http]
default_env = "staging"
```

When none of those resolve, the env name is `None` and the env set is empty — `{{TOKEN}}` falls through to process env vars only, and `{{$timestamp}}` still works (dynamics are independent of the active env).

The empty case is the right default for "I just opened a new workspace and haven't picked an env yet" — your requests still parse, still fire, and unresolved placeholders are visible in the URL bar so it's obvious what's missing.

## The `.env` file

mnml looks for the chosen env in two directories, in this order:

```text
<workspace>/.mnml/env/<name>.env       ← preferred (mnml-native)
<workspace>/.rqst/env/<name>.env       ← legacy fallback (rqst port-back)
```

Both are read; if both exist, **`.mnml/` wins on a per-key basis**. A migrating user can drop a `.mnml/env/dev.env` next to the original `.rqst/env/dev.env` and override individual keys (a new staging token, a different `BASE_URL`) without forking the whole file.

Missing files are silently treated as empty — the env name still records (`env.name()` returns `Some("dev")`) so a future palette command or status chip can show *which* env you're on even when the file is empty or absent.

### File shape

```text
# .mnml/env/dev.env

# Plain KEY=VALUE — whitespace around `=` is trimmed.
BASE_URL=https://dev-api.example.com
TOKEN=eyJhbGciOi...

# Single or double quotes are stripped when they wrap the whole value.
LOGIN_EMAIL="qa+dev@example.com"
LOGIN_PASSWORD='hunter2'

# Comment lines (#) and blanks are skipped.
# Values are NOT shell-expanded — `$HOME` stays literal.
HOMEDIR=$HOME
```

A line without a `=` is dropped. A line with an empty key (`=oops`) is dropped. Everything after the first `=` is the value, trimmed of surrounding whitespace then stripped of one matched pair of surrounding quotes.

The format is intentionally trivial — no `export`, no continuation lines, no variable interpolation. Multi-line values aren't supported. If you need a multi-line body, put it in the request file with a `{{VAR}}` placeholder and keep the env file boring.

## `{{VAR}}` substitution

`{{NAME}}` resolves in this order:

1. The active env's loaded vars (`.mnml/env/<name>.env` merged over `.rqst/env/<name>.env`).
2. Process env vars (`std::env::var`).
3. Dynamic built-ins (handled separately — see below).

Whitespace inside the braces is allowed: `{{ BASE_URL }}` is the same as `{{BASE_URL}}`. Names are `[A-Za-z0-9_]+` (or `$` followed by `[A-Za-z0-9_]+` for dynamics). Anything else inside the braces — a dotted path, a leading digit, a hyphen — disqualifies the candidate, and the `{{…}}` survives verbatim.

`{{FOO}}` that can't be resolved is left in place, **not replaced with an empty string**. This is deliberate — a typo shows up as `https://dev-api.example.com/users/{{USER_ID}}` in the fired request's URL, which is a much louder failure than a 404 from `https://dev-api.example.com/users/`.

To enumerate every unresolved placeholder in a request before firing, `http::template::unresolved(text, &env)` returns them in source order, deduped. This is what a future "missing vars" check would read; today it's available to scripts and tests.

```rust
// What expansion looks like at the call site
let env = EnvSet::select(&workspace, None);          // pick the env name
let url = template::expand(&request.url, &env);      // {{VAR}} → value
for (_, v) in request.headers.iter_mut() {
    *v = template::expand(v, &env);
}
if let Some(body) = request.body.as_mut() {
    *body = template::expand(body, &env);
}
```

Method names aren't templated (`{{$method}}` won't substitute into a request line) — mnml only expands user-supplied text fields.

## Dynamic built-ins (`{{$name}}`)

A `$` prefix marks a placeholder as **dynamic** — a fresh value every call, independent of any `.env` file:

| Placeholder | Value |
|---|---|
| `{{$uuid}}` / `{{$guid}}` | A new v4 UUID (`6f3a-...-...`-shaped, 36 chars) |
| `{{$timestamp}}` / `{{$epochMs}}` | Current Unix epoch in milliseconds |
| `{{$epoch}}` / `{{$epochS}}` | Current Unix epoch in seconds |
| `{{$randomInt}}` | A small random integer (`< 1_000_000`) |
| `{{$randomHex}}` | 8 random hex characters |
| `{{$randomString}}` | A 16-char alphanumeric token (a truncated UUID without dashes) |
| `{{$randomBool}}` | The literal text `true` or `false`, picked uniformly |

An unrecognised `{{$noSuchVar}}` is left verbatim, same as a missing user var. Each occurrence in the same request gets its own evaluation — three `{{$uuid}}`s in one body produce three different UUIDs.

The randomness source is `/dev/urandom` on Unix; on platforms without it, mnml falls back to a `nanoseconds + pid` splitmix64 mixer. **Neither path is cryptographic** — use these for unique-payload generation, not for tokens or passwords.

## Pre-request `@set-env`

Scripts can plant variables into the active env before the request fires:

```http
# requests/orders.http
# @set-env REQUEST_ID = {{$uuid}}
# @set-header X-Request-Id = {{REQUEST_ID}}
GET https://api.example.com/orders?limit=10
Authorization: Bearer {{TOKEN}}
```

`@set-env NAME = VALUE` binds `NAME` for the rest of the substitution pass on *this* request and any chained step that follows in the same `mnml chain run`. The right-hand side passes through the same `{{var}}` expansion — so `@set-env REQUEST_ID = {{$uuid}}` mints a UUID and binds it before any header or body sees `{{REQUEST_ID}}`.

This is the cleanest way to thread a correlation id through one request without polluting `.env` with throwaway state.

## Post-response `@capture`

The mirror image: read a value out of the response and bind it for the *next* step. Captures land in the running env, so chained requests pick them up via `{{NAME}}`:

```http
# @capture TOKEN = json $.access_token
# @capture TRACE_ID = header X-Request-Id
```

The lookup picker (`http.lookup`) uses the same mechanism end-to-end — it fires a request, lets you pick an item, and `upsert`s the chosen id back into `<workspace>/.rqst/env/<active>.env` (the on-disk env file, not just the in-memory `EnvSet`) so it survives across mnml restarts. See [HTTP lookups](/manual/http-lookup/) for the full flow.

## Switching envs

The TUI loads `MNML_ENV` once per send — change your shell's `MNML_ENV` and the next `:http.send` picks it up. Restart mnml only if `$MNML_ENV` was set differently before launch and you want the new value to stick.

From the CLI, every command takes `--env NAME`:

```bash
mnml run requests/users.http --env staging
mnml chain run .mnml/chains/smoke.chain.json --env prod
mnml http sync --workspace ~/code/api
```

`--env` wins over `$MNML_ENV` wins over `[http] default_env` (TOML) wins over `.rqst/config`'s `default_env`. To deliberately ignore all four, leave them unset — mnml runs with the empty env set, and any `{{VAR}}` references show up unresolved in the fired request.

## What lives where

```text
<workspace>/
├── .mnml/
│   ├── env/
│   │   ├── dev.env              ← mnml-native, preferred
│   │   └── staging.env
│   └── config.toml              ← unrelated to envs, but lives here too
└── .rqst/
    ├── env/
    │   ├── dev.env              ← legacy, fallback
    │   └── staging.env
    └── config                   ← legacy `default_env=dev` source
```

The two layers don't fight — `.mnml/` overrides on a per-key basis, so a partial `.mnml/env/dev.env` (just `TOKEN=…`) layered on top of a full `.rqst/env/dev.env` gives you the new token plus everything else the rqst file already had.

`.mnml/env/*.env` files often contain secrets (bearer tokens, basic-auth passwords). Add them to `.gitignore` and commit a `*.env.example` template for the team if you want the keys discoverable.

## Next

- [HTTP client](/manual/http/) — the parent overview: request files, the request pane, `http.send`
- [HTTP lookups](/manual/http-lookup/) — the multi-stage flow that writes captured ids back to `.env`
- [HTTP history](/manual/http-history/) — every fired request is logged whether or not the env resolved cleanly
- [HTTP helpers — JWT & bearer](/manual/http-helpers/) — `jwt.decode` and `auth.extract_bearer` for inspecting and rotating tokens
- [Configuration](/reference/configuration/) — TOML schema for the `[browser]` / `[http]` knobs
