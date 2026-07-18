# API-workflow hunt — round 9

Driven headless via the file-IPC channel (`<workspace>/.mnml/ipc/`) against
`./target/debug/mnml` at commit `f1fc84ae` (clean tree except this new
`.findings/` file). Two local Python servers stood in for a real API:
a plain echo server (`127.0.0.1:8919`, reflects method/path/headers/body)
and a variable-latency echo server (`127.0.0.1:8920`, cycles sleeps
`[5,20,40,60,90]ms` for bench testing). Also used `httpbin.org` (real
network, reachable in this sandbox) for a real PNG binary-response probe,
and the `mnml discover` / `mnml chain run` CLI subcommands directly against
a hand-written OpenAPI fixture and `.chain.json` file. Workspace:
`.rqst/env/dev.env` + `.rqst/config` (legacy rqst layout), plus
`.mnml/chains/`. Every finding below was reproduced end-to-end (real
request round-trips, real files on disk, `screen.txt` dumps) — source
reading was used only to *explain* what was observed and to cite exact
`file:line`.

**Round-8 fix verification — all 3 confirmed fixed, end-to-end (not just
unit tests):**

1. **`-F name=value;X` no longer truncates at `;`.** Fired
   `curl -X POST http://127.0.0.1:8919/post -F "notes=Height: 5;Width: 10" -F "file=@upload.txt"`
   from a real Request pane. Body tab shows the full multipart part
   (`Height: 5;Width: 10`, no truncation); the echo server's JSON view of
   what actually arrived on the wire confirms the same — `"Height: 5;Width: 10"`
   intact.
2. **`-F name=@relpath` resolves against the `.curl` file's own dir.**
   Put `subdir/multipart.curl` (referencing `-F file=@upload.txt`) next to
   `subdir/upload.txt`, opened it via the tree (process CWD was
   `/Users/chrismclennan/Projects/mnml`, nowhere near the workspace).
   Response echo shows the uploaded part body as
   `hello-from-sibling-file` (the actual file contents) with
   `filename="upload.txt"` — confirms base_dir resolution, not CWD.
3. **`.env` files with `export KEY=value` parse cleanly.** `.rqst/env/dev.env`
   contained `export TOKEN=abc123`. Fired a request with body
   `{"token":"{{TOKEN}}"}` against the echo server — response body shows
   `"token": "abc123"` (resolved), confirmed by content-length delta (43 vs
   46 bytes for the unresolved-placeholder case). Note: this only works
   when `.rqst/config`'s `default_env=dev` is in the **bare** rqst form: a
   `default_env = "dev"` (quoted, spaced) config — plausible for someone
   hand-writing the file — resolves to a literal env name `"dev"` (with
   quotes) and silently falls through to an empty env set. That's an
   already-documented limitation (`src/http/template.rs:264-269`,
   "Real workspaces use the bare form so this isn't a live bug"), not a
   new regression — flagging here only because I initially tripped over it
   myself and want it distinguished from the three real fixes above.

All 4 new unit tests from the round-8 commit (`33c95474`) also still pass
(`cargo test --lib http::`: 136/136 green).

---

## Finding 1 — SEV-2 — multi-block `.http` Request-pane tab title never refreshes on block navigation; also mis-derives the label from the block delimiter on first open

**surface**: multi-block-http / request-pane

### Repro

1. Write `api.http`:
   ```
   ### get
   GET http://127.0.0.1:8919/get

   ### post
   POST http://127.0.0.1:8919/post
   Content-Type: application/json

   {"hello":"world"}
   ```
2. Open it (auto-opens as a Request pane on block 1 — "get").
3. Look at the tab title. **Already wrong**: shows `GET  ## get` instead
   of something sane like `GET  get` or `GET  /get`.
4. Run `http.next_block` (`]` / the palette command) to move to block 2
   ("post"). The Method/URL/Body fields in the pane correctly update to
   `POST http://127.0.0.1:8919/post` with the JSON body — the underlying
   `RequestPane.request` is genuinely swapped.
5. Look at the tab title again.

### Expected

The tab title reflects whichever block is currently loaded — at minimum
the method chip and the block name/URL summary should be in sync (e.g.
`POST  post` or `POST  /post`), not a stale mix of new-method +
old-block-name.

### Actual

Tab title (and `status.json`'s `panes[].title`) shows **`POST  ## get`** —
the *new* block's method (`POST`, correct) glued to the *first* block's
mangled label (`## get`, stale, and wrong even on first load — see root
cause #2). This is user-visible and reproducible via the IPC `status.json`
snapshot:
```json
"panes": [ { "title": "POST  ## get", "dirty": false } ]
```
right after firing `http.next_block` while the Method/URL fields
underneath correctly show `POST http://127.0.0.1:8919/post`. A user
skimming tabs (bufferline, `:bn`/`:bp`, Ctrl+Tab pane switcher, etc.) sees
a tab that looks like it's still on the `get` block when it's actually
loaded `post` — the exact kind of "which block am I actually on"
confusion the brief calls out as a hunt target ("Block-name persistence on
edit + write-back").

### Root cause (two compounding bugs)

1. **Title never re-derived on block switch.**
   `App::move_request_pane_to_next_block` (`src/app/http.rs:2527-2603`)
   updates `rp.request`, `rp.source_block_name`, `rp.script`, `rp.view`,
   `rp.focus`, `rp.state`, cursors, and `rp.headers_buffer` — but never
   touches `rp.summary`. `RequestPane::title()` (`src/request_pane.rs:800`)
   prioritizes `self.summary` over the URL-derived short label
   (`src/request_pane.rs:816-817`), so once `summary` is set on initial
   open it's permanently stuck for the lifetime of the pane regardless of
   which block gets loaded afterward.
2. **`extract_summary` treats the `###` block-delimiter as a `#`-comment
   and mis-strips it.** `extract_summary` (`src/app/http.rs:215-235`) scans
   the raw file text for a leading `#`/`//` comment line to use as a
   human title, via `trimmed.strip_prefix('#')` (only strips **one** `#`).
   For a multi-block `.http` file whose first non-empty line is
   `### get` (the block-name delimiter, not a descriptive comment), this
   produces `"## get"` (two hashes still attached) as the "summary" —
   which is wrong on its face (not a real title) even before block-nav
   makes it doubly stale. `pane.summary = extract_summary(&text)` is set
   once at `src/app/http.rs:801` in `open_request_pane_from_file` and
   never revisited.

### Suggested severity rationale

SEV-2: it's a persistent, visible mismatch between pane chrome and pane
state on one of the three core multi-block-file interactions the brief
explicitly flags, with no workaround short of closing/reopening the file
(which resets to block 1, still showing the mangled `## <name>` label).
Not data-loss, but it actively misleads about *which request is loaded*,
which matters a lot for a workflow where "am I about to fire the login
step or the delete step" is exactly the kind of mistake this class of bug
enables.

---

## Finding 2 — SEV-2 — `mnml discover` CLI unconditionally overwrites existing `.curl` stubs on every re-run, silently discarding manual edits (no dry-run, no diff, no warning)

**surface**: cli-mode / http.sync (discover subcommand specifically)

### Repro

1. `mnml discover spec.json --out discovered` against a 3-endpoint OpenAPI
   fixture. Produces `discovered/untagged/{createWidget,getWidget,listWidgets}.curl`.
2. Hand-edit one stub, e.g. append a header:
   `echo "  -H 'x-custom-header: my-value'" >> discovered/untagged/createWidget.curl`
3. Re-run the **exact same command**: `mnml discover spec.json --out discovered`
   (simulating the realistic case: spec added a 4th endpoint, developer
   re-runs discover to pick it up, expecting their earlier hand-edits on
   the untouched 3 endpoints to survive).
4. `grep -c x-custom-header discovered/untagged/createWidget.curl` → `0`.
   The file is back to the pristine generated form; the hand-added header
   is gone with zero warning, zero backup, zero exit-code signal
   (`mnml discover` still prints `wrote 3 .curl stub(s)` and exits 0).

### Expected

At minimum, one of: (a) a warning/diff when a target file already exists
and differs from what would be (re)generated, (b) a `--force`/`--dry-run`
flag pair so headless/CI callers can opt into either safe-by-default or
explicit-overwrite behavior, or (c) documented equivalent behavior to the
TUI's `:http.sync` flow, which is explicit about this in its own trace
output (`src/http/sources.rs:219`: `"# run \`:http.sync\` to apply
(overwrites existing stubs)"`) and ships a companion dry-run command
(`:http.sync_check`, `src/app/http.rs:3826`) specifically so a user can
review drift before committing to the overwrite.

### Actual

`mnml discover` (the standalone CLI subcommand, `src/main.rs:577-637` →
`mnml::http::discover::run`) has **no** equivalent safety net: `--help`
text (`src/main.rs:578`) lists `[--out DIR] [--base-url URL] [--normalize]
[--edge-cases]` — no `--force`/`--dry-run`/`--no-clobber`. The write sites
(`src/http/discover.rs:165,196,215,280` etc.) call `std::fs::write`
unconditionally with no `Path::exists()` check, no diff, no confirmation.
This is the one CLI-headless entry point the persona brief flags for
"round-trip fidelity", and re-running it against an updated spec — the
entire point of the tool (spec evolves, re-discover, pick up new
endpoints) — silently clobbers every previously-generated file, including
any the developer customized (added an auth header, tweaked a default
body value, etc.).

### Suggested severity rationale

SEV-2: silent, unannounced data loss in a workflow (spec evolves → re-run
discover → pick up new endpoints) that is the CLI's *primary intended
use case*, not an edge case. No corruption of live traffic, but user-authored
edits vanish with a clean exit code and a success message, which is worse
than an error — nothing in the CLI's own output signals anything went
wrong.

---

## Finding 3 — SEV-3 — `http.bench` histogram bucket labels collapse to identical `N–N ms` ranges whenever `max − min < 10` (the common case for fast/local APIs)

**surface**: http.bench

### Repro

1. Fire `http.bench` (default `N=10, concurrency=4`) against a
   near-instant local echo server (`127.0.0.1:8919`, sub-millisecond
   round-trip).
2. Summary line: `min 0 · p50 0 · p95 1 · p99 1 · max 1 · mean 0` — the
   percentile math itself is correct (`p50 ≤ p95 ≤ p99 ≤ max` holds; the
   dedicated unit test with the 5 known samples 10/20/30/40/50ms →
   p50=30/p95=50/p99=50/max=50 also still passes,
   `cargo test --lib http::bench::` green).
3. Look at the histogram below the summary:
   ```
       │  0–0    ms │██████████████████████████████│ 8
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
       │  0–0    ms │                              │ 0
   ```
   (9 of 10 buckets rendered — screen cut off the 10th — all labeled
   identically `0–0 ms`.)

### Expected

10 buckets spanning `[min, max]` with distinct, monotonically increasing
labels (even if narrow, e.g. `0.0–0.1 ms`, or at minimum distinguishable
integer boundaries) so the shape of the distribution is actually legible.

### Actual

Every bucket boundary collapses to the same value due to integer-only
bucket-width math when `range = max - min` is smaller than `BUCKETS`
(10). `src/http/bench.rs:155-174`:

```rust
const BUCKETS: usize = 10;
let range = (max - min).max(1);   // e.g. range = 1 (max=1ms, min=0ms)
...
let lo = min + range * i as u64 / BUCKETS as u64;       // 1*i/10 → 0 for i=0..9 (int div)
let hi = min + range * (i + 1) as u64 / BUCKETS as u64; // 1*(i+1)/10 → 0 until i+1=10
```
With `range=1`, `lo`/`hi` are computed entirely in `u64` integer
arithmetic, so `1 * i / 10` truncates to `0` for every `i` in `0..=8`;
only the very last bucket (`i=9`, `hi = 1*10/10 = 1`) would show a
non-zero boundary. The result: up to 9 of 10 histogram rows render the
literal string `0–0 ms`, which reads as "everything is one bucket" even
though the underlying `counts[]` array (which uses correct proportional
bucketing, `(d - min) * BUCKETS / range`) actually did separate samples
into buckets 0 and 9 correctly — it's specifically the *label formatting*
that's broken, not the bucketing logic itself.

This isn't a contrived edge case — any bench run against a fast local API
or an API with sub-10ms jitter (extremely common: local dev servers,
in-region cloud APIs, cached endpoints) hits this. Confirmed the
percentile-math path is unaffected (separate code path, separately
tested) — this is purely the histogram's cosmetic bucket-range labels.

### Suggested severity rationale

SEV-3: cosmetic / display-only, the underlying counts and percentiles
remain correct and usable, but it actively undermines the one piece of
the bench feature whose entire purpose is visual — the brief specifically
asks to "validate the histogram shape," and for the most common real-world
case (fast APIs) the shape reads as "everything in bucket 0" with 9 rows
of meaningless duplicate labels.

---

## Finding 4 — SEV-3 — chain step `if` / `retry` / `parallel` fields are silently accepted and ignored, not validated or rejected

**surface**: http.run_chain (`.chain.json` format)

### Repro

1. `.mnml/chains/cond.chain.json`:
   ```json
   [
     { "request": "get1.curl" },
     { "request": "get2.curl", "if": "{{NONEXISTENT}} == 1", "retry": 3, "parallel": true }
   ]
   ```
   (`{{NONEXISTENT}}` deliberately references an undefined var — if `if`
   were evaluated at all, this step should either error on the unresolved
   var or be skipped.)
2. `mnml chain run .mnml/chains/cond.chain.json`.

### Expected

One of: the chain actually honors `if`/`retry`/`parallel` (they don't —
confirmed by reading `src/http/chain.rs` end to end, `Step` only has
`request` + `extract`, `src/http/chain.rs:26-30`), **or**, if unsupported,
the parser rejects unknown step keys / at minimum warns
("`if`/`retry`/`parallel` are not supported chain-step keys, ignoring").

### Actual

```
──── step 1/2 — GET http://127.0.0.1:8919/get
  ← 200 OK  (0 ms)
──── step 2/2 — GET http://127.0.0.1:8919/get?x=2
  ← 200 OK  (0 ms)
✓ chain passed
```

Step 2 fires unconditionally (the bogus `if` had zero effect), sequentially
(the `parallel: true` had zero effect — trace shows strict step-1-then-
step-2 ordering, matching `src/http/chain.rs`'s plain `for (i, step) in
steps.iter().enumerate()` loop), and with no retry semantics observable
(not exercised by this probe directly, but `run()` has no retry-count
handling anywhere in `src/http/chain.rs:79-247`). `Step::parse`
(`src/http/chain.rs:32-56`) only reads `.get("request")` and
`.get("extract")` off the JSON object — any other key, including typos,
is silently dropped with no validation pass.

### Suggested severity rationale

SEV-3, not a regression (this was never implemented — `chain.rs`'s own
doc comment at the top of the file honestly documents the supported shape
as `request` + `extract` only, nothing more). Filing because the round-9
brief explicitly asked "do these work?" and the answer is a clean no with
a silent-ignore trap: a user coming from Postman/Insomnia-style chain
runners (where `if`/`retry`/`parallel` are common) who writes one of these
keys expecting it to work gets no signal that it didn't — the chain just
"passes" having done something other than what was configured. Cheap fix
if ever prioritized: reject unknown top-level step keys with a parse
error naming them.

---

## Finding 5 — SEV-3 — binary response bodies (image/PDF/etc) render as raw undecoded byte garbage in the Body tab; no binary detection, no preview, no "save to disk" nudge

**surface**: request-pane (response body viewer)

### Repro

1. Fire a request against a real binary endpoint, e.g.
   `GET https://httpbin.org/image/png` (`content-type: image/png`).
2. Response lands `200 OK`, `14.5 KB`. Look at the Body tab (default
   "Auto" format).

### Expected

Something better than a raw garbage dump — even a minimal
"binary response (image/png, 14.5 KB) — use `:http.save_response` to
write to disk" placeholder would do; `save_response` itself already
writes the correct raw bytes (`Response.body_bytes`, preserved since the
round-7 SEV-1 fix — verified still correct, this finding is about the
*viewer*, not the disk-write path).

### Actual

The Body tab prints the `String::from_utf8_lossy` view of the raw PNG
bytes line-by-line, U+FFFD replacement characters and all:
```
1 �PNG
2
3 IHDRdd��aIDATx��}wXS���J#�� ��JE�tl(��FGGT��\�VԱ�a�
4 �EAQA�&��BEzoI ���c�!�$Dw����99gg�u޳�>{����0`��ǎKJJ������$��
...
```
The sub-tab type chip in the top-right shows **`TEXT`** (not e.g.
`BINARY` or `IMAGE`) — `detect_response_content_type`
(`src/ui/request_view.rs:2007-2042`) checks the content-type header for
`json`/`html`/`xml`/`javascript`/`css`/`plain`/`text/` and otherwise falls
through the body-shape sniff (`{`/`[`/`<` → JSON/XML, else `TEXT`), with
no `image/`, `application/octet-stream`, `application/pdf`, or general
"non-UTF8-heavy" binary detection branch at all. Note: confirmed this is
purely a display/UX issue, not a terminal-corruption risk — ratatui's
`Buffer::set_stringn` filters out literal control characters before
writing cells (`.filter(|symbol| !symbol.contains(char::is_control))`,
`ratatui-core-0.1.2/src/buffer/buffer.rs:351`), so no raw ANSI/OSC escape
sequences from a malicious response body actually reach the real
terminal.

### Suggested severity rationale

SEV-3: no data-loss (save-to-disk still correct), no terminal-safety
risk (ratatui sanitizes), but it's a rough edge directly on the "hit
this workflow daily" surface — any API with an image/file-download
endpoint currently produces a screen of visual noise on send instead of
useful information, and there's no in-pane affordance pointing at
`:http.save_response` for this exact case.

---

## Notes — questions answered without a new bug filed

- **HTML preview (Q2)**: mnml never *renders* HTML in any pane — the
  `HTML`/`XML` response-type chip only selects the tree-sitter `html`
  grammar for syntax-**highlighting the raw source**
  (`src/ui/request_view.rs:3710-3735`). No sixel/kitty-protocol render,
  no "open in browser" action. Confirmed by code inspection (grep for
  `html_preview`/`render_html`/`open_in_browser` across `src/` — no
  hits). Reasonable scope decision for a TUI HTTP client, not filing as
  a bug — flagging so it's not mistaken for a regression.
- **JSON tree collapse/fold (Q3)**: doesn't exist. `http.toggle_collapse_all`
  (`src/command.rs:4258-4269`) only collapses/expands the HTTP-panel
  **sidebar sections** (FILES/RECENT/CAPTURED/…), unrelated to the
  response Body tab. The Body tab is a flat pretty-printed/highlighted
  text view with no fold affordance (no `▸`/`▾` glyphs anywhere in
  `src/ui/request_view.rs`'s body-rendering path). Feature gap, not a
  regression.
- **Mock "server" (Q5)**: confirmed there is no URL-matching mock
  interceptor of any kind — mocks are strictly a 1:1 sidecar file
  (`<source>.curl.mock.json` / `.http.mock.json`) replayed only via
  explicit `:http.replay_mock` on the exact pane whose source file the
  sidecar belongs to (`src/http/mock.rs`). Matches the persona brief's
  own description verbatim; not a new finding.
- **Cookie jar attributes (Q6)**: `CookieJar::record_set_cookie`
  (`src/cookie_jar.rs:84-97`) explicitly, deliberately ignores
  `Domain`/`Path`/`Expires`/`Secure`/`HttpOnly`/`SameSite` — the module
  doc comment says so outright ("No expires/secure/samesite enforcement
  — those would be belt-and-braces for what's effectively a developer
  tool"). Documented scope decision, not a regression.
- **Env layering — `.env.local` (Q7)**: no `.env.local`/dotenv-style
  convention exists anywhere in mnml (`grep -rn "\.env\.local\|dotenv"
  src/` → zero hits). Env files are exclusively keyed by *name*
  (`.rqst/env/<name>.env` / `.mnml/env/<name>.env`, `.mnml` overriding
  `.rqst` on the same key — verified still true), selected via
  `default_env`/`$MNML_ENV`/`--env`, not by a `.env`/`.env.local`
  filename convention. Also confirmed there's no *global* (outside the
  workspace) env-var directory fallback — only the `[http] default_env`
  *selector* can come from `~/.config/mnml/config.toml`
  (`src/http/template.rs:70-77`), the actual key/value pairs are always
  workspace-local. Feature-gap note, not a regression — flagging since
  the brief explicitly asked.
- **HTTP-panel filter persistence (Q8)**: confirmed **correct** —
  filter text survives both pane-focus switches (editor pane ↔ tree) and
  activity-section switches (HTTP → Files → HTTP), only clearing on
  explicit `Esc` while focused (`src/app/layout.rs:1884-1898` only resets
  the four `*_filter_focused` flags on section change, never the filter
  *text*; `src/tui/mod.rs:864-869` is the only text-clearing site, gated
  on `Esc`). Verified live via IPC: typed `/api` → Enter (narrows FILES to
  1/6), switched to Files section and back to HTTP, filter chip still
  showed `api` and FILES stayed narrowed. No finding — matches the
  Cloud Agents/Notes/Sessions panel idiom the codebase already
  standardized on.

---

## Summary

| # | Severity | Surface | One-liner |
|---|----------|---------|-----------|
| 1 | SEV-2 | multi-block-http / request-pane | Tab title stuck on stale, mangled first-block label after `http.next_block` |
| 2 | SEV-2 | cli-mode / http.sync | `mnml discover` silently clobbers hand-edited `.curl` stubs on every re-run |
| 3 | SEV-3 | http.bench | Histogram bucket labels collapse to identical `0–0 ms` for narrow latency ranges |
| 4 | SEV-3 | http.run_chain | `if`/`retry`/`parallel` chain-step keys silently ignored, no validation |
| 5 | SEV-3 | request-pane | Binary responses (PNG/etc) render as raw garbage bytes, no detection/preview |

Round-8's 3 fixes (`-F` semicolon truncation, `-F @relpath` base_dir,
`export KEY=value` env parsing) all verified fixed end-to-end.
