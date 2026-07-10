---
title: HTTP sync — sources.json
description: Batch-regenerate `.curl` stubs from a workspace's swagger / OpenAPI sources via `:http.sync` or the `mnml sync` CLI.
---

`mnml discover` turns one OpenAPI spec into a tree of `.curl` stubs. `mnml sync` is the multi-source version: a workspace declares its swagger sources in `<workspace>/.mnml/sources.json` (or the legacy `.rqst/sources.json`), and one command refetches all of them. Useful when a team has six microservices, each with its own swagger endpoint, and you want one `.curl` tree that tracks them all without typing six `mnml discover` lines.

## `sources.json`

```json
[
  {
    "name": "users-service",
    "kind": "swagger",
    "url": "https://users.dev-api.example.com/v3/api-docs",
    "out": ".mnml/requests/users"
  },
  {
    "name": "orders-service",
    "kind": "swagger",
    "url": "https://orders.dev-api.example.com/v3/api-docs",
    "out": ".mnml/requests/orders",
    "base_url_override": "https://staging-orders.example.com"
  },
  {
    "name": "billing-service",
    "kind": "swagger",
    "url": "https://billing.dev-api.example.com/openapi.json",
    "out": ".mnml/requests/billing"
  }
]
```

Per-entry fields:

| Field | Required | What |
|---|---|---|
| `name` | yes | Display name in the trace + the directory name when `out` is omitted. Defaults to `(unnamed)` |
| `kind` | yes | Source type. Only `"swagger"` is wired today; other kinds (`openapi3`, `bruno`, …) parse fine but are silently logged as skipped |
| `url` | yes | The spec URL (HTTPS). A missing `url` skips the row with a stderr warning rather than aborting the whole sync |
| `out` | no | Destination directory for the `.curl` stubs. Relative paths resolve against the workspace root; absolute paths are taken verbatim. Defaults to `.rqst/requests/<name>` for parity with rqst's layout |
| `base_url_override` | no | If set, every generated stub uses this as the base URL instead of the spec's `servers[0].url`. Useful when the swagger doc declares prod but you want stubs that point at staging |

### Where the file lives

mnml checks two paths, in this order:

```text
<workspace>/.mnml/sources.json     ← preferred (mnml-native)
<workspace>/.rqst/sources.json     ← legacy fallback (rqst port-back)
```

`.mnml/sources.json` wins when both exist. The fallback exists so a workspace ported from rqst keeps working — drop a `.mnml/sources.json` next to the original and migrate at your own pace.

When neither file exists, `http.sync` toasts `no sources.json found at <.mnml path> or <.rqst path>` and bails. Same for an empty array: `sources.json is empty`. Both are recoverable — fix the file and retry.

## From the editor — `:http.sync`

The palette command `http.sync` (no default key — bind it under `[keys.global]` if you use it often, or via the palette / fuzzy launcher):

```vim
:http.sync
```

What happens:

1. mnml spawns a background thread (reqwest's blocking client has a 30-second per-request timeout; six sources × 30 seconds is up to three minutes of frozen UI if the work ran on the main thread).
2. The thread loads `sources.json`, walks every entry, and for each `kind: "swagger"` fires `http::discover::run` — the same code path `mnml discover` uses.
3. `App::tick` polls the result channel each frame; when the result lands, mnml toasts `http.sync: wrote N request stub(s) — tree refreshed` and calls `self.tree.refresh()` so the new files appear in the file rail without a manual rescan.

While the worker is running, calling `:http.sync` again is a no-op — mnml toasts `http.sync already running` and ignores the second call. There's one in-flight sync at a time.

Per-source failures don't abort the whole run. If `billing-service` 404s, the trace logs `[sync] billing-service: failed — …` and continues to the remaining entries. The total in the toast counts only successful sources.

## From the CLI — `mnml sync`

```bash
mnml sync
mnml sync --workspace ~/code/api
mnml sync -w .
mnml sync --normalize             # or -n; substitute {{$isoTimestamp}} / {{$uuid}}
```

| Flag | What |
|---|---|
| `--workspace DIR` / `-w DIR` | Workspace to read `sources.json` from. Defaults to the current directory |
| `--normalize` / `-n` | Swap ISO 8601 timestamps + lowercase UUIDs in synthesized bodies for `{{$isoTimestamp}}` / `{{$uuid}}`. See [HTTP realistic request generation → Tier 1](/manual/http-generation/#tier-1--dynamic-value-substitution) |
| `-h` / `--help` | Print usage and exit |

Add `[http] sync_normalize = true` to `~/.config/mnml/config.toml` to enable normalization by default for both the palette command and the CLI.

The CLI streams the same trace to stdout as the TUI puts in its toast — one line per source for the fetch attempt, one line per source for the write count, and a final `ok — N stubs written`:

```text
$ mnml sync --workspace ~/code/api
[sync] users-service: fetch https://users.dev-api.example.com/v3/api-docs → /Users/chris/code/api/.mnml/requests/users
[sync] users-service: wrote 47 stub(s)
[sync] orders-service: fetch https://orders.dev-api.example.com/v3/api-docs → /Users/chris/code/api/.mnml/requests/orders
[sync] orders-service: wrote 31 stub(s)
[sync] billing-service: fetch https://billing.dev-api.example.com/openapi.json → /Users/chris/code/api/.mnml/requests/billing
[sync] billing-service: failed — connect: dns error

[sync] done — 2 source(s), 78 request stub(s) total
ok — 78 stubs written
```

Exit code is `0` when at least one source succeeded (matching `mnml discover`'s convention); non-zero only on a fatal failure (missing `sources.json`, malformed JSON). A workspace where every source 404s exits `0` with `0 stubs written` — `sync` doesn't pre-judge whether some sources matter more than others.

The CLI variant is useful from a cron job, a CI step, or a `[tasks]` entry — the spec endpoints change as backend teams deploy, and `mnml sync` keeps the stub tree synced overnight without anyone opening the editor.

## Dry-run — `mnml sync-check` / `:http.sync_check`

Before overwriting your local `.curl` stubs, `sync-check` reports what *would* change without writing anything:

```bash
mnml sync-check                    # exit 0 = clean, exit 2 = drift found, exit 1 = failure
mnml sync-check --normalize
mnml sync-check -w ~/code/api
```

The palette command `http.sync_check` opens a scratch pane `[sync-check]` with a per-source markdown report — added / removed / changed files, per-source drift counts, an overall summary. Toast: `clean — no drift` (0 drift) or `N file(s) differ` (any drift).

Under the hood each source's stubs regenerate into a `tempfile::TempDir` (auto-cleaned on Drop) and get compared against the real `out` tree. No writes happen anywhere. Same background-worker shape as `http.sync`; concurrent calls report `already running`.

The CLI variant exits with distinct codes so scripts can gate on drift:

| Exit | Meaning |
|---|---|
| `0` | Clean — no drift |
| `2` | Drift found — files differ |
| `1` | Failure — malformed spec, missing `sources.json`, etc. |

Useful as a CI gate: `mnml sync-check --normalize` in a pre-commit hook fails fast if upstream swagger drifted.

## What the generator writes

Each source's `out` directory ends up holding a tree of `.curl` files — one per operation, grouped by the operation's first OpenAPI `tag`:

```text
.mnml/requests/users/
├── auth/
│   ├── login.curl
│   ├── logout.curl
│   └── refresh.curl
├── users/
│   ├── list.curl
│   ├── get-by-id.curl
│   └── update.curl
└── untagged/
    └── healthz.curl
```

The stubs themselves are normal `.curl` files — open one and `:http.send` fires it. They use `{{BASE_URL}}` as the base when the spec's `servers[0].url` is absent and `base_url_override` isn't set, so each stub is dev/staging/prod-portable via a one-key `.env` switch.

**Re-running `mnml sync` overwrites the canonical filenames**. If you edit a stub and want to keep those edits, move the file (rename it, drop it into a sibling directory) — the next sync writes a fresh copy at the canonical path, leaving your edited copy alone. The pre-port-back workflow was identical, so existing rqst muscle memory transfers.

## Skipped kinds

Today only `kind: "swagger"` is wired. Entries with other kinds are logged in the trace and counted as "skipped":

```text
[sync] legacy-bruno-collection: skipping unsupported kind 'bruno'
```

This is a forward-compat hook — drop-in support for other importers (Bruno, Insomnia, generic OpenAPI 3 specs not recognized as swagger) lands without changing the file format. For now, the only kind that does anything is `swagger`.

## Next

- [HTTP realistic request generation](/manual/http-generation/) — the seven tiers of stub-quality work `sync --normalize` unlocks (faker vocab, coherent object graphs, well-known env-var IDs, login-flow chain starters, edge-case variants)
- [HTTP client](/manual/http/) — the parent overview, with `mnml discover` for the single-source case
- [HTTP envs & templating](/manual/http-envs/) — `{{BASE_URL}}` resolution, which the synced stubs rely on
- [HTTP history](/manual/http-history/) — every send the synced stubs fire is logged here
- [Configuration](/reference/configuration/) — TOML schema for the `[http]` section
