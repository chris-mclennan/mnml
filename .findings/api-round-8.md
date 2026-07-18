# API-workflow hunt — round 8

Driven via the `.test` E2E harness (`mnml test <path>`, `src/e2e/mod.rs`) —
same `App` + `ui::draw` code path as the real TUI/headless runner, just
without the file-IPC transport — plus direct unit tests for parser-only
probes. Built `./target/release/mnml` at commit `d7cdc1d` (clean tree,
after round-7's 4 fixes: `.curl` ext-routing, `@capture` carry-forward,
real multipart `-F` bodies, `{{VAR}}` URL config-default-env).

A tiny local Python `http.server` on `127.0.0.1:8935` stood in for a real
API: `/login` (issues a token), `/use-token` (checks `Authorization: Bearer
tok-from-step-1`), `/echo` (echoes method/content-type/body), `/set-cookie`
+ `/use-cookie`, `/image.png` (tiny real PNG), `/big` (2 MiB JSON). Every
finding below was reproduced end-to-end (real network round-trip to that
server, real files on disk) — screen dumps included. Source reading was
used only to *explain* what was observed.

**Round-7 fix verification — all 4 still hold** (re-run against current
`HEAD`, all passed):
- `.curl` files route to the curl parser first (`tests/e2e/http_curl_multi_block_send_uses_cursor.test` — ok)
- `{{VAR}}` in the URL uses the config-default env (`tests/e2e/http/env-resolution-mnml-overrides-rqst.test` — ok)
- `@capture` persists across `:http.send` fires **within one file** (new probe below — ok; note the actual semantics are file-scoped via `App::http_running_env` keyed by `source_path`, not global — worth being precise about since "within one file" undersells that cross-file captures are NOT expected to carry, by design)
- `.curl`/`.http` mock sidecar path resolution, including per-named-block `.http` sidecars, still correct (new probe below — ok)

---

## Finding 1 — SEV-2 — `-F name=value` silently truncates the part value at the first literal `;`, discarding everything after it

**surface**: http.send / curl-parser (`multipart/form-data` construction via `-F`)

### Repro

1. `write form.curl "curl -F 'notes=Height: 5;Width: 10' -X POST http://127.0.0.1:8935/echo"`
2. Open it, `:http.send`.
3. Look at the Body tab (the multipart source mnml built) and the response
   (echo server's view of what actually arrived).

### Expected

The part value is the literal string the user typed: `Height: 5;Width: 10`
(curl has no `;type=` special-casing for a field that merely *contains* a
semicolon — `;type=` is only special when it trails the whole `-F` value
in curl's own grammar, and even then only for `@file`/`<file` specs in
real curl. A plain `-F name=value` string containing `;` is just a value.)

### Actual

Confirmed via the real Body pane render and a live server round-trip:

```
1 ------mnmlBoundary7945
2 Content-Disposition: form-data; name="notes"
3
4 Height: 5
5 ------mnmlBoundary7945--
```

`;Width: 10` is gone. The echo server's own JSON confirms the wire bytes
are actually truncated (`body_len` is short and `body` ends at `Height:
5`), so this isn't a display-only issue — the wrong bytes are sent over
the network.

### Root cause

`src/http/curl.rs::parse_multipart_spec` (line ~218) unconditionally does:

```rust
let (body_spec, content_type) = if let Some((left, right)) = spec.split_once(';') {
    let ct = right.trim().strip_prefix("type=").map(|s| s.trim().to_string());
    (left, ct)
} else {
    (spec, None)
};
```

It splits on the **first** `;` in the spec no matter what follows. When
the trailing content isn't actually `type=...`, `ct` becomes `None` and
the `right` half — including whatever the user typed after the semicolon —
is thrown away entirely, with no error/warning. Any part value containing
a literal `;` (dates, CSV-ish text, HTTP-header-shaped strings, INI-style
config blobs, User-Agent strings, `Set-Cookie`-shaped fixtures, etc.)
silently loses everything after the first `;`.

### Verification method

Added a temporary `#[test]` to `src/http/curl.rs`'s test module
(`scratch_semicolon_in_value_probe`), ran it, confirmed the assert failed
with `TRUNCATED: ...Height: 5\r\n...` (no `Width`), then reverted the
temp test (not committed) before moving on. Also independently confirmed
end-to-end through the full `App` + real HTTP round-trip via the `.test`
harness (`multipart-semicolon-truncation.test`, screen dump above).

### Suggested severity rationale

SEV-2: silent data corruption with zero error surfaced, on a currently-
shipping feature (`-F` was the subject of round-7's headline SEV-1 fix),
triggerable by an extremely ordinary input (any value containing `;`).

---

## Finding 2 — SEV-1/2 — `-F name=@relpath` / `-F name=<relpath` resolves the file path against the **mnml process's CWD**, not the workspace — so relative-path uploads fail in the interactive Request pane even though the identical file works via `mnml run FILE`

**surface**: http.send (Request pane) / curl-parser multipart file loading

### Repro

1. In workspace dir `WS`, create `WS/upload.txt` with some text and
   `WS/form.curl`:
   ```
   curl -F 'file=@upload.txt' -X POST http://127.0.0.1:8935/echo
   ```
2. Launch mnml with workspace `WS` from a **different** CWD (e.g. the
   repo root, or literally any directory that isn't `WS` — this is the
   overwhelmingly common way mnml gets launched: `./run.sh ~/some/proj`,
   a saved session, `cargo run -- WS`, etc. — CWD ≠ workspace).
3. Open `form.curl`, `:http.send`.
4. Compare with: `cd WS && mnml run form.curl` (CLI path, CWD == WS).

### Expected

Both fire the same request with the same file contents attached — the
relative path `upload.txt` is workspace-relative (or at minimum,
resolves consistently regardless of the shell's CWD when mnml was
launched), matching how every other relative-path feature in mnml
(`.mnml/env/`, `.rqst/lookups/`, collection roots, etc.) is
workspace-relative, not process-CWD-relative.

### Actual

Confirmed via the `.test` harness (`multipart-file-upload-e2e.test`,
harness CWD ≠ the test's synthesized workspace dir — which is the
realistic case since the harness, like a real launch, doesn't `chdir`
into the workspace):

```
5 [LOAD-ERROR: can't read upload.txt: No such file or directory (os error 2)]
```

The identical `.curl` file + identical relative path, fired via `mnml run
form.curl` with the shell's CWD manually set to the workspace, works
perfectly and uploads the real file bytes (verified separately, plain
`mnml run`, non-headless):

```
"body": "...Content-Disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\n...hello upload contents\n\r\n..."
```

So the exact same file, same relative path, same flag — works from the
CLI, silently fails (inline `[LOAD-ERROR: ...]` placeholder, no toast, no
distinct error state) from the interactive Request pane, purely because
of *where the mnml process happened to be launched from*. `mnml` never
calls `std::env::set_current_dir` anywhere (`grep -rn set_current_dir
src` is empty), so the TUI's long-lived process CWD is whatever the
shell had when the user ran the launch command — routinely NOT the
workspace root.

### Root cause

`src/http/curl.rs::load_multipart_file_part` (line ~260) calls
`std::fs::read(path)` directly on the spec's raw path string with no
workspace/source-dir context. The module's own doc comment already flags
this as a known gap (`src/http/curl.rs:100-105`):

> "`.curl` files opened from a Request pane don't reach here with a
> source-dir hint; that's a follow-up. For the CLI (`mnml run FILE`) CWD
> is typically the workspace, which is the right base for relative
> uploads."

That follow-up was never done — `App::spawn_http_job` /
`send_request_from_active` (`src/app/http.rs`) call `crate::http::parse`
with only the raw file text, never the workspace path or the source
file's parent directory, so there's no way for `parse_multipart_spec` to
resolve relative to anything but the ambient process CWD.

### Why this matters more than a plain "known limitation" note

Round 7's commit `d7cdc1d` ("SEV-1 curl `-F` builds real multipart body —
file uploads work") advertises file uploads as fixed. That's true for the
`mnml run` CLI batch path, but for the primary interactive surface this
whole persona drives daily (open a `.curl` file → `:http.send`), relative
paths — the natural, ergonomic way anyone authors a `-F file=@fixtures/…`
line inside a workspace — silently fail. Absolute paths do work in both
paths (confirmed by the existing unit tests using `tempfile::tempdir()`
absolute paths), so the gap is specifically "interactive pane + relative
path", which is exactly the combination a human would reach for first.

### IPC / harness evidence

`.test` script `multipart-file-upload-e2e.test` — screen dump:
```
5 [LOAD-ERROR: can't read upload.txt: No such file or directory (os error 2)]
```
CLI counter-proof (`cd WS && mnml run form.curl`):
```
"body": "...filename=\"upload.txt\"...hello upload contents\n..."
```

---

## Finding 3 — SEV-2/3 — `.env` files written with the common `export KEY=value` shell-sourcing convention silently fail to resolve; the failure surfaces as a confusing low-level reqwest URL-builder error, not a clear "unresolved var" message

**surface**: env-resolution / `.env` grammar

### Repro

1. `write .rqst/config "default_env=dev"`
2. `write .mnml/env/dev.env "export BASE_HOST=127.0.0.1:8935"`
3. `write api.curl "curl http://{{BASE_HOST}}/one"`
4. Open, `:http.send`.

### Expected

Either (a) mnml strips a leading `export ` token the way most `.env`
tooling / shell-sourceable env files expect (this is an extremely common
convention — env files meant to be both `source`'d in bash *and* read by
tooling routinely use `export KEY=value`), or at minimum (b) a clear
"unresolved var: BASE_HOST" message the same way the Editor-pane /
Chain-run path already produces for genuinely-missing vars
(`template::unresolved` is already wired into the chain-run path and
into the `{{VAR}}` hover/click-to-def UI — see CLAUDE.md's 2026-07-06
polish entry).

### Actual

```
✗ last send: bad request: builder error for url (http://{{base_host}}/one)
```

`{{BASE_HOST}}` is left completely unresolved (lower-cased in the
message because reqwest's URL parser normalizes the host component) and
the request never fires — the user sees a raw reqwest transport error
with no indication their env file has a problem, let alone which line.

### Root cause

`src/http/template.rs::parse_env_line` (line ~287):

```rust
let (k, v) = trimmed.split_once('=')?;
let key = k.trim().to_string();
```

splits on the first `=` with no handling for a leading `export ` (or
`export\t`) token, so for `export BASE_HOST=127.0.0.1:8935` the key
parsed is the literal string `"export BASE_HOST"` (with an embedded
space) — never matches `{{BASE_HOST}}`, and the mis-keyed var sits
harmlessly unused in `EnvSet.vars`.

### Verification

`.test` script `env-export-prefix.test` — full screen dump shows the
literal `{{BASE_HOST}}`/`{{base_host}}` surviving into the failed
request; `expect screen lacks "BASE_HOST"` (i.e. "the var got resolved
away") fails, confirming it's still present verbatim.

### Suggested severity rationale

SEV-2/3 borderline: not a corruption (fails safe — request never fires
with a bogus URL), but it's a silent, confusing failure mode for a very
common file-authoring convention, and the error message actively
obscures the actual cause (points at reqwest/URL syntax, not at the env
file).

---

## Finding 4 — STILL OPEN (round-7 Finding 7, unfixed) — binary/image response bodies still render as garbled lossy-UTF8 text with a mislabeled "TEXT" tab; no binary/content-type-based placeholder

**surface**: response viewer (`src/ui/request_view.rs`)

Re-verified on current `HEAD` (`d7cdc1d`) — **not** among round 7's 4
landed fixes, and still reproducible exactly as round-7 Finding 7
described. Recording here for round-8 visibility rather than as a new
SEV, since it was already staged.

### Repro

1. `write img.curl "curl http://127.0.0.1:8935/image.png"` (real PNG,
   `Content-Type: image/png`).
2. `:http.send`.

### Actual (screen dump)

```
┌───────────────────────────────────────────────────────────────── 200 OK  · 0ms · 82 B ┐
│  Body  Headers 4  Timeline  Tests                               wrap   copy   TEXT ▼  │
│ 1 �PNG
│ 2
│ 3 IHDR�IDATx�cd�'�fIEND�B`�
```

`detect_response_content_type` (`src/ui/request_view.rs:2007`) checks
`content-type` for `json` / `html` / `xml` / `javascript` / `css` /
`text/*` and otherwise sniffs the body's first char for `{`/`[`/`<` — it
has no `image/*` (or generic "non-text") branch, so it falls through and
mislabels the tab `TEXT`. Since `http::send` already stores raw bytes
separately (`Response::body_bytes`, the round-7-adjacent SEV-1 fix for
`:http.save_response`), the raw bytes ARE safely recoverable — but the
Body pane gives zero on-screen indication that what's rendered is
garbage, nor a hint to use `:http.save_response` instead of reading it.

### Notes

`src/ui/request_view.rs:2007` (`detect_response_content_type`),
`src/ui/request_view.rs:3709` (`highlight_lang` match — same gap, no
binary branch).

---

## Verified NOT broken (explicit checks, no regression found)

For completeness — these were on the round-8 hunt list and came back
clean on current `HEAD`:

- **Chain step ordering + extraction**: 2-step chain
  (`login.curl` → extract `TOKEN` via `$.access_token` → `use.curl` with
  `{{TOKEN}}` in an `Authorization` header) round-trips correctly against
  a real server that hard-checks the exact bearer value
  (`chain-extract-and-use.test` — `TOKEN = tok-from-step-1`, step 2 gets
  `"ok": true`, not a 401).
- **Cookie jar cross-request propagation**: `Set-Cookie` from one request
  correctly shows up as `Cookie:` on a later request to the same host
  (`cookie-cross-request.test`). Domain-attribute / subdomain matching is
  NOT implemented (jar keys strictly by exact request host, ignores any
  `Domain=` on `Set-Cookie` — `src/cookie_jar.rs`'s own doc comment
  already documents this as an intentional simplification) — a
  documented limitation, not a regression.
- **`.http` multi-block mock sidecars**: per-named-block sidecar paths
  (`api.GetOne.http.mock.json` / `api.GetTwo.http.mock.json`) don't
  collide (`http-mock-per-block-sidecar.test`).
- **Bench percentiles**: existing unit test
  (`src/http/bench.rs::formats_percentiles_with_known_samples`) already
  covers the exact 10/20/30/40/50ms → p50=30/p95=50/p99=50/max=50 case
  from the hunt brief and passes.
- **Background-thread double-fire guards**: `http.lookup`'s
  `accept_lookup_file` already guards on `self.lookup_fire_rx.is_some()`
  (a prior-round fix, `src/app/http.rs:2643`); `http.sync` / `http.bench`
  have equivalent guards. No double-fire / dropped-result regression
  found.
- **HTTP panel `/` filter + COLLECTIONS nesting**: filtering by a nested
  request name (`create-order` inside `.mnml/collections/orders/`)
  correctly force-shows the match (`http-panel-filter-collections.test`).
- **`.rest` files**: parsed identically to `.http` via
  `http::file::parse_all` (same `###`-block grammar). JetBrains-specific
  extensions (`< file` body refs, `> {% script %}` response handlers,
  `# @name` request references) are explicitly out of scope per
  `src/http/file.rs`'s own module doc comment — a documented limitation,
  not a bug.
- **`.env` quoting**: a value with an escaped inner double-quote
  (`TOK="abc\"def"`) round-trips as the literal `abc\"def` (no
  unescaping) — consistent with `parse_env_line`'s documented "no
  escape-sequence processing" behavior; not flagged as a bug since it's
  an intentional scope cut, not a silent corruption.
- **Auth tab**: Basic-auth preset correctly base64-encodes `user:pass`;
  Bearer/API-key presets round-trip via `auth.save_preset` /
  `auth.apply_preset`. API-key is header-only (`X-Api-Key`), no
  query-param placement option — a scope limitation, not a bug.

---

## Summary / ranking

| # | Finding | Severity |
|---|---|---|
| 1 | `-F name=value` truncates at first literal `;` | SEV-2 |
| 2 | `-F name=@relpath` resolves against process CWD, breaks in interactive pane | SEV-1/2 |
| 3 | `.env` `export KEY=value` silently unresolved, confusing error | SEV-2/3 |
| 4 | Binary/image response renders as garbage (still open from round 7) | SEV-3 (tracked, not new) |
