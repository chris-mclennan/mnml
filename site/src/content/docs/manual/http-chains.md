---
title: HTTP chains
description: "`.chain.json` runs a sequence of requests, extracting values between steps. `:http.run_chain` is the editor-side picker over `<workspace>/.mnml/chains/*.chain.json`."
---

A **chain** is a sequence of HTTP requests where each step can pull values out of its response and feed them to the next step's `{{var}}` substitution. The canonical example: log in (capture `TOKEN`), fetch a user list (capture `USER_ID`), fetch one user's orders. mnml's chain runner stops at the first transport error, non-2xx/3xx status, failed `@assert`, or extraction that produces nothing — and writes a step-by-step trace of what happened.

This page is the **editor surface**. The chain *runner* + file format are documented in [HTTP client](/manual/http/#chains-chainjson); this page focuses on the in-editor picker (`:http.run_chain`), the `[chain-trace]` scratch the run drops you into, and how it pairs with `:http.import_postman` for collection-based workflows.

## The picker — `:http.run_chain`

| Surface | Call |
|---|---|
| Palette | `HTTP: run a .chain.json from .mnml/chains (multi-step request chain)` |
| Ex-command | `:http.run_chain` |

No default keybinding. Bind it under `[keys.global]` if you run chains often.

The picker reads `<workspace>/.mnml/chains/` and lists every file matching `*.chain.json`, sorted alphabetically. Rows show:

```text
HTTP chains
  ▸ auth-and-list                  3 step(s)
    smoke                          5 step(s)
    user-onboarding                7 step(s)
    nightly-regression             12 step(s)
```

- **Label** — the filename with `.chain.json` stripped (e.g. `auth-and-list.chain.json` → `auth-and-list`).
- **Detail** — the step count, parsed cheaply from the JSON array. `0 step(s)` here means either an empty array or a malformed file (the picker doesn't enforce the schema — the runner does that on Enter).

Fuzzy-match by typing — `auth` narrows to `auth-and-list`; `smoke` jumps to that chain.

### When the directory's empty

If `<workspace>/.mnml/chains/` doesn't exist or contains no `.chain.json` files, the picker doesn't open — a toast reads:

```text
http.run_chain: no chains at /path/to/workspace/.mnml/chains
```

Create the directory and drop a `.chain.json` in, or use `:http.import_postman` to seed one from an exported Postman collection.

### Press Enter to run

Enter on a row spawns a worker thread that runs the chain via `crate::http::chain::run`. mnml toasts immediately:

```text
chain: running auth-and-list.chain.json…
```

Then the worker fires the steps in order, sending each request through the same transport `:http.send` uses. The trace builds up in memory; when the chain finishes (success or first failure), the trace + a one-line summary lands in a `[chain-trace]` scratch buffer:

```text
──── step 1/3 — POST https://api.example.com/auth/login
  ← 200 OK  (134 ms)
  ✓ status == 200
  ⇒ TOKEN = eyJhbGciOiJIUzI1NiJ9...  (extract $.access_token)
──── step 2/3 — GET https://api.example.com/users
  ← 200 OK  (56 ms)
  ⇒ first_user_id = 42  (extract $.data[0].id)
──── step 3/3 — GET https://api.example.com/users/42/orders
  ← 200 OK  (89 ms)
  ✓ json $.data is array
────
✓ chain completed successfully
```

Each step's block shows:

- **`──── step N/M — METHOD URL`** — the resolved URL after `{{var}}` substitution, so you see what actually went on the wire.
- **`  ← STATUS STATUSTEXT (Nms)`** — the response.
- **`  ✓` / `  ✗`** rows — one per `@assert` directive in the step's request file.
- **`  ⇒ NAME = VALUE`** rows — one per `@capture` directive and one per chain-level `extract` entry. `extract` rows also annotate the JSON path used (`(extract $.access_token)`).
- **Final separator + summary** — `✓ chain completed successfully` or `✗ chain failed: <reason>`.

A simultaneous toast carries the summary (`✓ chain completed successfully` or `✗ chain failed: <reason>`).

### One chain at a time

The picker enforces single-flight. If you call `:http.run_chain` while a chain is already running, you get:

```text
http.run_chain: a chain is already running
```

Wait for the in-flight chain to finish (the `[chain-trace]` scratch lands when it does). For genuinely-concurrent chain runs, use the CLI — `mnml chain run FILE` runs in its own process and doesn't share state with the running mnml.

## The `[chain-trace]` scratch

The scratch is a normal buffer — editable, search-able, save-able. It opens in the current pane stack with `[chain-trace]` as the title.

Common moves:

- **`/<query>`** (vim) or **`Ctrl+F`** (standard) — search for a specific step or status code in the trace.
- **`:w trace.txt`** — save the trace as a file for review or sharing.
- **`Ctrl+W q`** — close the scratch when you're done.

The scratch is re-used on subsequent runs — fire another chain, the new trace replaces the old. The previous trace is gone (it wasn't saved); save it before re-running if you want both.

Running the same chain a second time? The scratch's `[chain-trace]` title doesn't tell you which run produced it; check the timestamps or first-step URL to disambiguate.

## How environments resolve

Chains honor `$MNML_ENV` — the picker's worker reads it once when the run starts and passes the env name to `crate::http::chain::run`. The runner then loads `<workspace>/.mnml/env/<MNML_ENV>.env` for `{{var}}` resolution.

```bash
# Launch mnml against the staging env, then run a chain.
export MNML_ENV=staging
mnml ~/code/api
:http.run_chain          # picks up MNML_ENV=staging
```

To run the same chain against a different env, the cleanest path is the CLI:

```bash
mnml chain run .mnml/chains/auth-and-list.chain.json --env prod
```

The editor surface doesn't expose an inline env-override (yet) — `$MNML_ENV` is consulted at run time, not before each step.

## Pairing with `:http.import_postman`

Postman collections are imported into mnml's chain format via `:http.import_postman`. The flow:

1. Export your collection from Postman (`Collection > … > Export > Collection v2.1`).
2. In mnml: `:http.import_postman`, point at the exported JSON.
3. The importer writes:
   - One `.curl` per request into `<workspace>/.mnml/requests/<folder>/<name>.curl`.
   - One `.chain.json` per top-level folder into `<workspace>/.mnml/chains/`.
4. `:http.run_chain`, pick the chain, watch it run.

Captures + extractions from the Postman test scripts translate to `@capture` directives in the `.curl` files and `extract` entries in the chain JSON — the same primitives a hand-written chain uses. Edit either layer to refine.

## The CLI equivalent

The picker is the editor-side surface for the same runner the CLI exposes:

```bash
mnml chain run .mnml/chains/auth-and-list.chain.json
mnml chain run .mnml/chains/auth-and-list.chain.json --env staging
mnml chain run .mnml/chains/auth-and-list.chain.json -w ~/code/other-api
```

CLI output mirrors the `[chain-trace]` scratch — same per-step trace, same final summary. Exit code is 0 on full success, non-zero on the first failure. Useful from a `[tasks]` entry, a CI step, or a Makefile.

The two front-ends share `crate::http::chain::run`. Same parser, same `@assert` evaluator, same `extract` JSON-path semantics. What you debug in the editor runs the same way in CI.

## File-format quick reference

Living in `<workspace>/.mnml/chains/*.chain.json`:

```json
[
  {
    "request": "auth/login.curl",
    "extract": { "TOKEN": "$.access_token" }
  },
  { "request": "users/list.http" },
  {
    "request": "merchant/get-locations.curl",
    "extract": { "LOCATION_ID": "$.locations[0].id" }
  }
]
```

Per step:

- **`request`** (required) — path to a `.curl` / `.http` / `.rest` file. Resolved against the chain file's directory → `<workspace>/.mnml/requests/` → the workspace root. Absolute paths work too.
- **`extract`** (optional) — map of `{ VAR_NAME: "$.json.path" }`. Resolved against the JSON response body and bound into the running env so the next step's `{{VAR_NAME}}` finds it. Missing extraction = chain failure (`extract '<NAME>' from <path> produced nothing`).

The step's own `@capture` directives still fire — they're a richer form of extraction (headers + body, more path syntax). `extract` is the shorter spelling for the common JSON-body case.

See [HTTP client → Chains](/manual/http/#chains-chainjson) for the full format spec.

## Edge cases

- **Empty chain** — `chain has no steps` error. Add a step or delete the file.
- **Missing request file** — `step N: cannot find <path>` error. The resolver tried chain-dir / `.mnml/requests/` / workspace root, none matched. Check the path in the JSON.
- **Unresolved `{{VAR}}`** — `step N: unresolved vars: VAR1, VAR2` error before the request fires. The variable wasn't in the env file, wasn't extracted from a prior step, and wasn't a dynamic built-in.
- **Non-2xx step status** — `step N: stopping at non-success 401` error. The transport succeeded, but the chain treats anything outside 200..400 as a hard stop. Patch the request (or the auth env var) before re-running.
- **Failed `@assert`** — `step N: K assertion(s) failed` error. Each failed `✗` row in the trace explains which assertion fired.

## Next

- [HTTP client → Chains](/manual/http/#chains-chainjson) — the full file format + the assertion / capture / extract grammar
- [HTTP envs & templating](/manual/http-envs/) — `{{var}}` resolution + the dynamic built-ins
- [HTTP history](/manual/http-history/) — every request a chain step fires also lands in `.rqst/history.jsonl`
- [HTTP Request pane — tabs & layout](/manual/http-edit-tabs/) — what the editable form looks like for a single `.curl` you'd later chain
- [Headless & `.test`](/manual/headless/) — chains run identically under `cargo run -- chain run` and the headless test harness
