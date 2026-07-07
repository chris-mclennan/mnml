---
finding: http-request-pane-never-expands-template-vars
severity: SEV-1
agent: multilang-dev-user
language: ts | py | go
repro: e2e (live headless, single-process, clean repro; root-caused in source)
---

## Summary

The `{{VAR}}` / env-substitution feature — the entire point of the HTTP client's
`.mnml/env/<name>.env` + `{{VAR}}` system, used for base URLs and auth tokens —
is **dead** on the primary, default way of opening a `.http` / `.curl` / `.rest`
file: `open_request_pane_from_file()` (`src/app/http.rs:624`, the "#polish
2026-07-06" feature, i.e. shipped the day before this test). It parses the raw
file text into a `Request` and stores it **verbatim**, with template
placeholders like `{{baseUrl}}` and `{{authToken}}` still literally embedded —
`http::template::expand()` is never called anywhere in that function.

Firing Send on that pane (`refire_request` → `spawn_http_job` →
`crate::http::send(&request)`, `src/app/http.rs:3549-3608`) sends `rp.request`
**as-is**. No template expansion happens there either. So the literal string
`{{baseUrl}}/users` gets handed to the URL builder, which fails with
`bad request: builder error` (or, for a URL that happens to parse as *some*
valid-but-wrong host, could silently hit the wrong server).

## Repro (headless, single mnml process, verified clean — no stray/duplicate
processes racing the IPC channel)

```
mkdir -p /tmp/ts-test-workspace/.mnml/env
cat > /tmp/ts-test-workspace/.mnml/env/dev.env <<'EOF'
baseUrl=https://jsonplaceholder.typicode.com
authToken=test-secret-123
EOF
cat > /tmp/ts-test-workspace/api.curl <<'EOF'
### GetUsers
curl '{{baseUrl}}/users' -H 'accept: application/json'
EOF
```

1. Launch `./target/debug/mnml /tmp/ts-test-workspace --headless`.
2. `{"cmd":"open","path":"api.curl"}` — opens directly as a `Pane::Request`
   (this is the *default* open behavior for `.curl`/`.http`/`.rest` files).
3. `{"cmd":"run-command","id":"http.pick_env"}` → Enter → picks `dev`. Toast:
   `http env: dev`.
4. `{"cmd":"run-command","id":"http.send"}` → **`request failed: bad request:
   builder error`**. URL field still literally reads `{{baseUrl}}/users`.
5. Closed the pane (`buffer.close`) and reopened `api.curl` *fresh*, with `dev`
   already the active env override going in — **still fails identically**,
   proving this isn't a stale-pane issue; the open path itself never expands.

## Root cause

Contrast with the two code paths that *do* work:
- `parse_active_as_request()` (`src/app/http.rs:2815`) — used by `http.bench`
  when the active pane is a plain `Editor` — calls
  `http::template::expand(&request.url, &env)` on url/headers/body. **But**
  its very first branch (`src/app/http.rs:2819-2821`) is: if the active pane
  is already a `Pane::Request`, just clone `rp.request` — no expansion.
- `accept_lookup_file()` (`src/app/http.rs:2254`) — the `.rqst/lookups/*.curl`
  flow — also calls `expand()` correctly.

So template expansion only ever happens in the *editor-buffer* send path and
the lookup-file path. The moment a `.curl`/`.http` file is opened through the
polished Request-pane UI (Method/URL/Params/Body/Headers/Auth/Vars tabs, the
`[⇔]` edit-split toggle) — which is the UI this task explicitly asked me to
exercise ("Do the new edit-split (`[⇔]`) and var quick-add flows work smoothly
for API composition?") — vars are never substituted, on open *or* on
(re)send, regardless of how many times you switch the active env afterward.

The render layer (`src/ui/request_view.rs`, `has_unresolved_var` /
`unresolved_style`) *does* independently recompute red/cyan coloring for
unresolved vars against the live `EnvSet` at draw time — so the UI can visibly
tell you a var is unresolved — but that's cosmetic; it never feeds back into
`rp.request` before the request actually fires.

Also worth noting while unresolved: the Vars tab is explicitly read-only in
this version (`src/request_pane.rs`/`request_view.rs` comment: "no draft/add-
row support for Vars in v3") — there's no in-pane "quick add" to create a
missing var from a red/unresolved token; you have to know to go find
`.mnml/env/<name>.env` yourself (or `+ New env`) and edit it there. Minor
compared to the above, but relevant to the "var quick-add" flow this task
asked about — it doesn't exist yet.

## Impact

Every `.curl`/`.http`/`.rest` file that uses `{{baseUrl}}`/`{{token}}`-style
vars — which is the headline use case in mnml's own docs/task description
("use `{{VAR}}` for auth tokens... chain requests through captured values")
— fails at the very first Send, from the very first (and default) way of
opening the file. This isn't language-specific (any workspace with a
`.curl`/`.http` file hits it identically), but it's squarely in the HTTP-track
scope this task covers, and it's a total break of the feature's core value
proposition, not a rough edge.

## Suggested fix direction (not applied — task is bug-hunt only)

`open_request_pane_from_file` and `refire_request` both need to run
`http::template::expand()` (url/headers/body) against the current
`EnvSet::select_with_config_default(workspace, http_env_override, ...)`
immediately before building the `RequestPane` / before `spawn_http_job` fires
— i.e. expand at *send* time from the *live* env, not once at parse time, so
switching envs on an already-open pane also self-heals.
