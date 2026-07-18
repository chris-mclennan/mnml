# API-workflow hunt — round 10

Driven headless via the file-IPC channel (`<workspace>/.mnml/ipc/`) against
`./target/debug/mnml` at commit `1ac03cd8`, plus the `mnml run FILE` /
`mnml chain run FILE` / `mnml discover SPEC` CLI subcommands directly. Two
throwaway Python HTTP servers stood in as a fake API: a REST-ish echo/CRUD
server (`127.0.0.1:8931` — `/users`, `/locations`, `/login`) and a
plain body-echo server (`127.0.0.1:8933`) for multipart round-trips, plus a
minimal one-operation OpenAPI spec server (`127.0.0.1:18940`) for
`discover`/`sync` testing. Workspace layout: `.mnml/env/dev.env`,
`.mnml/chains/*.chain.json`, `.mnml/requests/`, a multi-block `multi.http`
(`list-users` / `create-user` / `delete-user`), and `.mnml/sources.json`.
`$MNML_ENV=dev` was exported so both the headless TUI and the CLI resolve
the same active env. Every finding below was reproduced end-to-end (real
request round-trips, real files on disk, `screen.txt` / `rects.json` dumps,
byte-for-byte diff of what actually got sent) — source reading was used
only to *explain* what was observed and to cite exact `file:line`.

**Round-9 fix verification — spot-checked, still holding:**
- Chain unknown-key warning (`if` / `retry` / `parallel`) prints correctly
  before the trace (`src/http/chain.rs:121-129`) — confirmed via
  `mnml chain run` on a 3-step chain with an `if`/`retry` step.
- Bench histogram sub-10ms bucket labels are distinct decimals (not all
  `0–0 ms`) — confirmed with 5 known samples `[10,20,30,40,50]` via the
  existing unit test *and* a live `10×2` `http.bench` fire against the echo
  server.
- `http.sync` / `http.sync_check` double-fire guards ("already running"
  toast) — confirmed live against a 3-second-latency fake swagger source:
  firing `http.sync` twice back-to-back correctly toasts
  `http.sync already running` on the second fire, and the eventual
  completion toast + written stub count is correct (not doubled, not lost).
- `.env` `export KEY=value` parsing in the *template engine*
  (`src/http/template.rs::parse_env_line`) still resolves `{{KEY}}`
  correctly end-to-end. (See Finding 7 below — a **different**, UI-only env
  parser has NOT been kept in sync with this fix.)
- Lookup picker's 3-stage chain (file → item → var-name prompt) still
  Esc-cancels cleanly at every stage, confirmed live with a real
  `.rqst/lookups/locations.curl` → `{{WAREHOUSE_ID}}` write.
- `mnml discover --force` / safe-by-default skip-existing still holds (files
  are genuinely not overwritten without `--force`) — see Finding 4 for a
  **separate** bug in what the CLI *reports* about that same run.

---

## Finding 1 — SEV-2 — `mnml run` / `mnml chain run` resolve `-F name=@relpath` uploads against the process CWD, not the request file's directory (silent `[LOAD-ERROR: …]` in the body, exit 0)

**surface**: cli-mode / multi-block-http (multipart)

### Repro

1. `uploads/upload.curl`:
   ```
   # @assert body contains "hello upload"
   curl -X POST http://127.0.0.1:8933/echo -F "file=@payload.txt"
   ```
   with `uploads/payload.txt` containing `hello upload content` sitting
   right next to it.
2. `cd` into `uploads/` (the file's own directory) and run:
   `mnml run upload.curl --workspace <ws>` → 200 OK, echo body shows the
   real file contents (`hello upload content`), assertion passes.
3. `cd /tmp` (anywhere else) and run the *same file* by absolute path:
   `mnml run <ws>/uploads/upload.curl --workspace <ws>`.

### Expected

Same request, same file on disk → same multipart body, regardless of the
shell's current directory — matching how the TUI's Request pane already
behaves (`src/app/http.rs:743`, `parse_with_base(&text, source_dir)`) since
the round-8 `-F @relpath` fix.

### Actual

From `/tmp` the upload silently degrades: the multipart part's value becomes
the literal string `[LOAD-ERROR: can't read payload.txt: No such file or
directory (os error 2)]`, the assertion fails, but the HTTP request still
**fires and returns 200** — the CLI has no idea the upload failed. Same
degradation reproduces through `mnml chain run` on a 1-step chain that
references the same `.curl` file:

```
$ cd /tmp && mnml run /…/uploads/upload.curl --workspace /…/round10-ws
→ POST http://127.0.0.1:8933/echo
← 200 OK  (0 ms)
{
  "received_body": "...Content-Disposition: form-data; name=\"file\"; filename=\"payload.txt\"\r\n...\r\n\r\n[LOAD-ERROR: can't read payload.txt: No such file or directory (os error 2)]\r\n..."
}
  ✗ body contains "hello upload" — not found in body
mnml run: 1 assertion(s) failed

$ mnml chain run /…/.mnml/chains/upload-chain.chain.json --workspace /…/round10-ws
──── step 1/1 — POST http://127.0.0.1:8933/echo
  ← 200 OK  (0 ms)
  ✗ body contains "hello upload" — not found in body
mnml chain: step 1: 1 assertion(s) failed
```

Root cause: both CLI entry points call the base-dir-less parser —
`src/main.rs:687` (`http::parse(&raw)`, `mnml run`) and
`src/http/chain.rs:139` (`super::parse(&raw)`, `mnml chain run` — used both
by the CLI subcommand and by the in-app chain runner's background thread).
`http::parse` forwards to `parse_with_base(input, None)`
(`src/http/mod.rs:78-80`), and with `base_dir: None`,
`load_multipart_file_part` (`src/http/curl.rs:295-304`) falls through to
"relative to the process's CWD — the CLI's behavior" per its own doc
comment. That comment reads as an intentional design note, but it means the
exact same `.curl` file behaves differently depending on whether it's fired
from the Request pane (file-dir-relative) or from `mnml run`/`mnml chain
run` (CWD-relative) — a real footgun for anyone running the same saved
request from both places, which is the whole point of having saved
`.curl` files. Worse, the failure mode is silent 200 OK + a body full of an
error string rather than a hard CLI error, so a chain/CI script checking
only the HTTP status will pass while quietly shipping garbage.

**Notes**: `src/main.rs:687`, `src/http/chain.rs:139`, `src/http/curl.rs:295-304`.
Fix shape: thread `file.parent()` (or the chain step's resolved path's
parent) through as `base_dir` at both call sites, matching what
`src/app/http.rs:743` already does.

---

## Finding 2 — SEV-3 — lookup picker's "suggested env-var name" is fully implemented, tested, and never wired up; the actual prompt always starts empty

**surface**: http.lookup

### Repro

1. `.rqst/lookups/locations.curl` → `GET {{BASE_URL}}/locations`, real API
   returns `{"locations":[{"id":7,"name":"Warehouse A"}, ...]}`.
2. `:http.lookup` → accept the file → accept "Warehouse A" from the item
   picker.
3. Observe the var-name prompt that opens.

### Expected

Per `src/http/lookup.rs`'s own module docs and its `suggest_var_name`
helper (well unit-tested: `locations.curl` → `LOCATION_ID`,
`delivery-partners.curl` → `DELIVERY_PARTNER_ID`), the prompt should open
pre-filled with a sensible suggested name the user can accept or edit —
exactly the UX `Prompt::seeded` (`src/prompt.rs:371-385`, "e.g. an
AI-suggested commit message you can then edit before confirming") exists
for.

### Actual

The prompt opens **completely empty** every time — the user must type the
full var name from scratch (`WAREHOUSE_ID`, `LOCATION_ID`, whatever) with
zero assistance, even though the exact right answer is one function call
away.

```
┌ Env var name for Warehouse A (7): ───────────────────────┐
│                                                          │
│ enter to submit · esc to cancel                         │
└──────────────────────────────────────────────────────────┘
```

Root cause: `App::accept_lookup_item` (`src/app/http.rs:2762-2771`) builds
the prompt with plain `Prompt::new(PromptKind::LookupVarName, format!(...))`
— it never calls `crate::http::lookup::suggest_var_name`, and never uses
`Prompt::seeded`. Grepping the whole tree confirms this is total dead code,
not a partial wiring:

```
$ grep -rn "suggest_var_name\|LookupPicker" src/ | grep -v src/http/lookup.rs
(no output)
```

`suggest_var_name`, `match_lookup_for_var`, the entire `LookupPicker` struct
(with its `Stage` enum and `var_name_suggestion` field), and their unit
tests all live in `src/http/lookup.rs` but are never referenced by the
actual runtime implementation, which instead does its multi-stage flow
ad hoc via `Picker`/`Prompt` overlays directly in `src/app/http.rs`. Looks
like an earlier design (a dedicated `LookupPicker` state machine) was
superseded by the current `Picker`+`Prompt` approach, and the helper
functions/tests were never ported over or deleted.

**Notes**: `src/http/lookup.rs:59` (`var_name_suggestion`, unused),
`src/http/lookup.rs:231-239` (`suggest_var_name`, unused outside its own
tests), `src/app/http.rs:2762-2771` (`accept_lookup_item` — should call
`suggest_var_name(file_path)` and use `Prompt::seeded`).

---

## Finding 3 — SEV-2 — Tab-cycling Request-pane field focus (URL→Method→Headers→Body) is completely decoupled from the visible content tab strip — keystrokes silently land in a buffer the user isn't looking at

**surface**: request-pane / editable-headers

### Repro (clean, isolated — fresh pane, no prior state)

1. Open a fresh `.curl` file (Edit view, default focus = URL, default
   visible tab = **Body**, empty).
2. Click the **Headers** tab-strip label (now `edit_tab == Headers`,
   `focus` still `Url`).
3. Press **Tab** three times: `Url → Method → Headers → Body`
   (`focus_next_field`, `src/request_pane.rs:662-667` /
   `src/tui/handlers/pane.rs:2736`). The visible tab strip is untouched by
   this — still showing **Headers**.
4. Type `{"k":1}`.
5. Click the **Body** tab-strip label to check where the text went.

### Expected

Either (a) Tab-cycling the field focus also switches the visible
`edit_tab` to match (so the user always sees what they're editing), or (b)
at minimum some visible indicator (caret, highlighted tab, status line)
shows which field currently has keyboard focus when it differs from the
displayed tab.

### Actual

Step 5 reveals `{"k":1}` landed in the **Body** buffer — confirmed by
switching to the Body tab afterward:

```
   Params  Body  Headers  Auth  Vars  Script                     ↻ Reroll   { } Format
             ━━━━
 1 {"k":1}
```

But at the moment of typing (step 4), the screen showed the **Headers**
Excel-cell grid, completely unchanged, with zero indication the keystrokes
were going anywhere else:

```
   Params  Body  Headers  Auth  Vars  Script
                 ━━━━━━━
  ┌────────────────────────────┬───────────────────────────────────────────────────┬───│
  │ Name                       │ Value                                             │   │
  ├────────────────────────────┼───────────────────────────────────────────────────┼───│
  │ X-Probe                    │ 1                                                 │ ✕ │
  └────────────────────────────┴───────────────────────────────────────────────────┴───│
  + Add row
```

A user following the documented "Tab cycles URL → Method → Headers → Body"
gesture while looking at any tab OTHER than the one their focus lands on
(which is the common case, since nothing keeps them in sync) will type
their JSON body into what they believe is a no-op moment, with no visual
feedback, and only discover the mistake by manually clicking around
afterward. Same risk in reverse — Tab-ing into Headers focus while the
Body tab is showing silently appends header lines to `headers_buffer` that
never render until the user clicks over to Headers.

Root cause: `rp.focus: EditField` (URL/Method/Headers/Body/Source — what
keystrokes target) and `rp.edit_tab: EditTab` (Params/Body/Headers/Auth/
Vars/Script — what's rendered) are two entirely independent enums.
`focus_next_field`/`focus_prev_field` (`src/request_pane.rs:662-667`) only
ever mutate `self.focus`; nothing anywhere sets `self.edit_tab` to track
it. The Body-tab render path (`src/ui/request_view.rs:3004-3014`) reads
`rp.request.body` unconditionally whenever `cur_tab == EditTab::Body`,
regardless of `rp.focus` — so it's a pure display/input desync, not a
data-corruption bug (the typed characters do go into a real buffer, just
the wrong on-screen one).

**Notes**: `src/request_pane.rs:662-667` (`focus_next_field`/`focus_prev_field`),
`src/tui/handlers/pane.rs:2728-2737` (Tab dispatch), `src/ui/request_view.rs:3004-3014`
(Body-tab render keyed on `cur_tab`, not `rp.focus`). Fix shape: either fold
`EditField` cycling into also setting `rp.edit_tab` to the field's "home"
tab, or (simpler) drop the Tab-cycle-into-invisible-buffers gesture
entirely in favor of clicking tabs directly (the mouse path already works
correctly and is the primary discoverable affordance per the tab strip's
own click handling).

---

## Finding 4 — SEV-3 — `mnml discover`'s "wrote N .curl stub(s)" count includes files that were SKIPPED (not written), because `--force` was off

**surface**: cli-mode (discover)

### Repro

```
$ mnml discover http://127.0.0.1:18940/spec.json --out ./discover-count-test
wrote 1 .curl stub(s) under ./discover-count-test

$ mnml discover http://127.0.0.1:18940/spec.json --out ./discover-count-test
wrote 1 .curl stub(s) under ./discover-count-test (1 existing skipped — use --force to overwrite)
```

(`payload.txt`/spec unchanged between runs; the second run's stub file's
mtime is confirmed untouched — it really was skipped, not rewritten.)

### Expected

The second run should report `wrote 0 .curl stub(s) ... (1 existing
skipped ...)` — the skip-existing feature (round-9 SEV-2 fix,
`src/http/discover.rs:60`) correctly *declines to overwrite* the file, but
the reported "written" count doesn't reflect that at all.

### Actual

`written` and `skipped` sum to the total number of operations processed,
double-counting every skipped file as also "written." A user running
`mnml discover` repeatedly (the exact safe-by-default workflow the round-9
fix was built for — "run this whenever, it won't clobber my edits") gets a
misleading "wrote N stubs" headline every single time, even when N stubs
were *all* skipped and literally zero bytes changed on disk.

Root cause: at all three write sites in `src/http/discover.rs`
(`run` function), `count += 1` happens **unconditionally** after the
skip/write `if`/`else`, instead of only in the `else` (actually-wrote)
branch:

```rust
// src/http/discover.rs:173-178 (same pattern repeats at :208-215 and :231-236)
if !opts.force && file.exists() {
    skipped += 1;
} else {
    std::fs::write(&file, curl)...
}
let rel = format!("{folder}/{file_base}.curl");
...
count += 1;   // ← always runs, even when the branch above was the skip arm
```

`Ok((count, skipped))` (`src/http/discover.rs:261`) is what `main.rs`'s
`wrote {written} ... ({skipped} existing skipped ...)` message
(`src/main.rs:634`) renders directly. Note `http.sync` / `http.sync_check`
are unaffected — `run_sync` always passes `force: true`
(`src/http/sources.rs:307`, "Sync IS the regenerate workflow"), so the skip
branch never fires there; this is isolated to the plain `mnml discover`
CLI / palette flow.

**Notes**: `src/http/discover.rs:119-120,173-178,207-215,230-249,261`,
`src/main.rs:634`. Fix shape: only increment `count` in the actual-write
arm; leave `skipped`-only files out of it (or rename to `processed` and
report `processed - skipped` as "written" at the call site).

---

## Finding 5 — SEV-3 — `mnml run FILE` on a multi-block `.http` file always fires block 1, silently, with no way to target another block and no warning that other blocks exist

**surface**: cli-mode / multi-block-http

### Repro

`multi.http`:
```
### list-users
GET {{BASE_URL}}/users
Authorization: Bearer {{TOKEN}}

### create-user
POST {{BASE_URL}}/users
Content-Type: application/json

{"name": "Ada"}

### delete-user
DELETE {{BASE_URL}}/users/1
Authorization: Bearer {{TOKEN}}
```

```
$ mnml run multi.http --env dev --workspace .
env: dev
→ GET http://127.0.0.1:8931/users     ← always block 1 ("list-users"),
← 200 OK  (1 ms)                         no matter what
...
```

There is no `--block NAME`, `--block N`, or any other CLI flag to select
`create-user` or `delete-user`; `mnml run --help` doesn't mention one
either. `do_run` (`src/main.rs:649-687`) calls `http::parse(&raw)` on the
whole file, which for `.http`/`.rest` content routes to
`file::parse(trimmed)` (`src/http/mod.rs:93-94`), and
`file::parse`/`first_request_block` (`src/http/file.rs:22-29,117-139`) is
explicitly documented as "Parse the first non-empty request block" — there
is no cursor/name concept at the CLI layer at all (that only exists in the
TUI's `parse_at_line`, used for the interactive Request pane's block
navigation).

### Expected

At minimum, a way to say which named block to fire (`--block create-user`),
mirroring the interactive `]`/`[`/`http.next_block` block navigation and
the per-block mock sidecar naming (`sibling_path_for_block`,
`src/http/mock.rs:108-134`) that already treat named blocks as first-class.
Failing that, a loud warning on stderr ("multi.http has 3 blocks; firing
block 1 (list-users) — pass --block NAME to pick another") so a user
scripting `mnml run` in CI/a Makefile doesn't silently fire the wrong
request forever.

### Actual

Completely silent — `mnml run` never even checks `file::parse_all`'s block
count, so there's no signal at all that `create-user`/`delete-user` exist
and are unreachable from this entry point. Since `mnml chain run` steps
resolve to whole files too (`resolve_request_path`,
`src/http/chain.rs:82-97`), a `.chain.json` step pointing at
`multi.http` (rather than a single-block `.curl`) has the exact same
silent block-1-only limitation.

**Notes**: `src/main.rs:649-687` (`do_run`), `src/http/mod.rs:93-94`
(routes to `file::parse`, not `file::parse_all`), `src/http/file.rs:22-29`
(`file::parse` docs: "first non-empty request block"). This may be an
intentional v1 scope cut (CLI historically = single-request files) rather
than a regression — flagging because the `.http` multi-block grammar and
the mock-sidecar naming both already treat named blocks as addressable, so
the CLI's silent single-block-only behavior is the odd one out.

---

## Finding 6 — SEV-2 — `http.params_add` (the Params-tab "+ Add row" / palette flow) splices the raw, un-encoded value into the URL — a value containing `?`, `&`, `=`, or `#` corrupts the query string

**surface**: request-pane

### Repro

1. Open any Request pane, `:http.params_add` (or click **+ Add row** on
   the Params tab).
2. Key: `redirect`, Tab (switch to value field), value:
   `https://x.test/cb?a=1&b=2`, Enter (commit).
3. Inspect the resulting URL.

### Expected

The param value should be percent-encoded before being spliced into the
query string — `redirect=https%3A%2F%2Fx.test%2Fcb%3Fa%3D1%26b%3D2` — so
the URL remains well-formed and the server sees `redirect` as a single
opaque value, exactly the kind of "callback/redirect URL as a query
param" shape that's extremely common in real APIs (OAuth redirects,
webhook callback URLs, deep links, …).

### Actual

```
{{BASE_URL}}/tabtest?redirect=https://x.test/cb?a=1&b=2
```

The URL now contains **two** `?` characters and an unescaped `&`. Any
server (or `mnml` itself re-parsing this as a URL later) will see query
params `redirect=https://x.test/cb?a`, `1` (dangling, no `=`... actually
`a=1` truncated at the embedded `?`), and a **separate top-level** `b=2`
param — the `redirect` value is silently truncated to
`https://x.test/cb?a` and an unrelated `b=2` param appears out of nowhere.
This is a straightforward data-corruption bug for one of the most common
real-world param shapes.

Root cause: `App::http_params_add_commit` (`src/app/http.rs:5377-5421`)
builds the query string with raw string concatenation and no encoding
step at all:

```rust
// src/app/http.rs:5405-5415
let sep = if rp.request.url.contains('?') { '&' } else { '?' };
rp.request.url.push(sep);
rp.request.url.push_str(&key_owned);
rp.request.url.push('=');
rp.request.url.push_str(&value_owned);   // ← raw, unencoded
```

Note `reqwest`/`url` crates are already dependencies elsewhere in the
codebase (used for the actual HTTP send), so a percent-encoding helper is
readily available; this path just doesn't call it.

**Notes**: `src/app/http.rs:5377-5421`, especially `:5414`
(`rp.request.url.push_str(&value_owned)`). Live-verified: fired the
resulting malformed URL is visible directly in the Request pane's URL box
after commit (`{{BASE_URL}}/tabtest?redirect=https://x.test/cb?a=1&b=2`) —
no network round-trip needed to see the corruption, it's already wrong at
rest.

---

## Finding 7 — SEV-3 — the Vars tab's env-file reader is a separate, less-correct re-implementation of `template::parse_env_line` — quoted values display WITH their quotes, `export KEY=value` lines display with the literal `export ` prefix still in the key

**surface**: request-pane (Vars tab) / env-resolution

### Repro

1. `.mnml/env/dev.env`:
   ```
   BASE_URL=http://127.0.0.1:8931
   TOKEN=devtoken123
   export EXPORTED_VAR=hello
   QUOTED_VAR="quoted value"
   ```
2. Open any Request pane in Edit view → click the **Vars** tab.

### Expected

The Vars tab is the UI's live view of "what `{{VAR}}` actually resolves
to right now" — it should match `EnvSet::lookup`/`template::parse_env_line`
(`src/http/template.rs:287-311`) exactly, since that's the ground truth the
request's own `{{…}}` substitution uses. `parse_env_line` already strips
surrounding quotes and an `export ` prefix (the round-8 SEV-2 fix,
`src/http/template.rs:296` + `:303-308`).

### Actual

Live-captured from the Vars tab table:

```
┌────────────────────────────┬───────────────────────────────────────────────────┬───┐
│ Name                       │ Value                                             │   │
├────────────────────────────┼───────────────────────────────────────────────────┼───┤
│ BASE_URL                   │ http://127.0.0.1:8931                             │ ✕ │
├────────────────────────────┼───────────────────────────────────────────────────┼───┤
│ QUOTED_VAR                 │ "quoted value"                                    │ ✕ │
├────────────────────────────┼───────────────────────────────────────────────────┼───┤
│ TOKEN                      │ devtoken123                                       │ ✕ │
└────────────────────────────┴───────────────────────────────────────────────────┴───┘
```

`QUOTED_VAR` shows `"quoted value"` (literal quotes still attached) — but
`{{QUOTED_VAR}}` actually resolves to `quoted value` (no quotes) in any
real request, because that substitution goes through the *correct*
`parse_env_line`. The Vars tab is lying about what the variable's value
actually is. By the same code path (confirmed by reading, not yet by a
second screenshot — the KV table's small viewport in this pane size didn't
scroll far enough to bring `export EXPORTED_VAR` into view), `export
EXPORTED_VAR=hello` would display as a row named literally `export
EXPORTED_VAR` (not `EXPORTED_VAR`) — since the Vars-tab reader does a bare
`split_once('=')` with no `export ` stripping at all, unlike
`parse_env_line`.

Root cause: `src/ui/request_view.rs:3322-3340` (the Vars-tab render) has
its own inline env-file parser instead of calling
`crate::http::template::parse_env_line`:

```rust
// src/ui/request_view.rs:3329-3337
if let Ok(text) = std::fs::read_to_string(&path) {
    for line in text.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = trimmed.split_once('=') {   // ← no export-prefix
            by_key.insert(k.trim().to_string(), v.trim().to_string());  //   strip, no quote strip
        }
    }
}
```

This is the same class of bug as Findings 2/3 above — a helper function
that already does the right thing (`parse_env_line`) exists and is used
correctly elsewhere (the actual request-sending path), but a UI-facing
display path re-implements a subset of the same logic and has drifted out
of sync with the round-8 fix.

**Notes**: `src/ui/request_view.rs:3322-3340` vs the real parser at
`src/http/template.rs:287-311`. Fix shape: call
`crate::http::template::parse_env_line` (or `EnvSet::load`, already the
same thing but with `.rqst`/`.mnml` precedence built in) from the Vars-tab
render instead of the ad hoc `split_once('=')`.
