# HTTP — what Posting has that mnml does not

Research note, 2026-09-07. Read-only; every mnml claim below was grepped on
`main` (`80752e94`). Posting is Darren Burns' terminal HTTP client
(`github.com/darrenburns/posting`, docs `posting.sh/guide/`), **v2.10.0,
2026-03-25**. Its docs were fetched page by page; where a page did not
document a capability the cell says so rather than guessing.

Paths: `zig:` = `mnml-zig/src/…`, `rust:` = `mnml/src/…`.

## 1. Feature matrix

Gap: **none** = mnml matches or exceeds · **partial** · **missing**.

### Request editor

| Posting | mnml-zig today | Rust mnml | Gap | Note |
|---|---|---|---|---|
| Method dropdown (`Ctrl+T`), colour per method | `http.cycle_method` (Space on Method), `http.set_method.*`; `methodColor` (`zig:ui/request_view.zig:519`) | yes | none | |
| URL bar with syntax highlight | `paintVarsOnField` (`zig:ui/request_view.zig`), method/URL row | yes | none | |
| URL **domain autocomplete** (history-driven) | — | — | missing | history exists (`zig:http/history.zig`) but is not a completion source |
| Variable **value preview** in URL bar (`show_value_preview`, secrets hidden) | hover tip `drawVarTip` (`request_view.zig:1024`), `sent_line` after send; secrets masked `env.zig:115 looksSecret` | yes | partial | preview is on hover, not inline |
| Variable **autocomplete** `${…}` | — | — | missing | `varRows` (`zig:app/http.zig:224`) is the obvious source |
| Path params `:id` tab (2.9) | — (`{{VAR}}` in the URL covers substitution) | — | missing | |
| Query params table, row add/edit/delete | Params tab: `startDraft`/`commitDraft`/`removeParam` (`zig:app/request_pane.zig:545-577`) | yes | none | |
| Headers as a **table** with row editing (2.6) | Headers is a **text area** `(Name: value per line)` (`request_view.zig:612`) | text | partial | `KvKind.headers` exists (`request_view.zig:773`) but the tab draws text |
| Header **name + value autocomplete** (2.6) | `http.insert_header` picker over 10 canned lines (`zig:app/cmd_http.zig:1093 common_headers`) | same | partial | no per-name value table, no completion while typing |
| **Toggle rows on/off** without deleting (2.4) | — | — (`disabled` only read on Postman import, `rust:app/http.rs:5706`) | missing | |
| Body: raw text / JSON with highlight + auto `Content-Type` | Body tab, `http.format_body`, `auto_format_body` cfg (`zig:app/http.zig:106`); JSON spans | yes | none | auto-insert of `Content-Type` not verified |
| Body: form-data / multipart / file upload | curl `-F` builds multipart (`zig:http/parse.zig:359-375`) — parts are literal, `@file` **not read** | `-F name=@relpath` read files (`rust:app/http.rs:969`) | partial | Posting: file upload is roadmap only |
| Auth: Basic / Bearer (2.5) / Digest | `auth_rows`: Bearer, Basic, X-Api-Key, Clear (`request_view.zig:140`; `AuthKind` `cmd_http.zig:81`); auth presets `authSavePresetCmd` | yes | partial | no Digest; OAuth2 on Posting's roadmap too |
| Info tab: name + description (1.11) | `### name` block names (`zig:http/parse.zig:675 Block`) | yes | partial | no description/tags field |
| Options tab: follow redirects / verify SSL / attach cookies | redirects always followed, cap 10 (`zig:http/client.zig:78`); `-k` parsed into `req.insecure` (`parse.zig:41`) but **client.zig never reads it** (`client.zig:295` plain `std.http.Client`); cookies auto-attached from jar (`cmd_http.zig:91`) | `insecure` honoured (`rust:http/mod.rs:187`), 30 s timeout (`mod.rs:186`) | missing | no per-request timeout, no proxy, no client cert / CA bundle in Zig |
| Scripts tab (Python `setup` / `on_request` / `on_response`, `posting.set_variable`, `notify`, auto-reload, `Ctrl+E` to editor) | Script tab = declarative `# @set-header/@set-var/@set-cookie`, `# @assert`, `# @capture` (`zig:http/script.zig`; run in `cmd_http.zig:133 runScript`, `:107 afterResponse`) | same | partial | Lua exists (`zig:scripting/`, `docs/LUA.md`) but the hook table (`LUA.md:92-103`) has **no http hooks** |
| Curl import by pasting into URL bar (2.1) | `http.paste_curl` (`parseCurl` `parse.zig:265`; `-X -H -d -b -u -F -k -G` …) | yes | none | mnml also opens `.curl` files directly |
| Text-area undo/redo | not verified for request fields | — | ? | |
| New / duplicate / delete request (`Ctrl+N` / `Ctrl+D` / Backspace) | `http.new`, `http.new_request`; no duplicate; delete only via the file tree | same | partial | no row actions in COLLECTIONS beyond open (`zig:app/http_panel.zig:349`) |
| Save (`Ctrl+S`), folder via `/` in name | `http.save` (write-back, splice into multi-block `.http`), `http_save_as` prompt (`cmd_http.zig:1192`) | yes | none | |

### Response viewer

| Posting | mnml-zig today | Rust mnml | Gap | Note |
|---|---|---|---|---|
| Body with tree-sitter highlight, prettified JSON | `responseSpans` (`request_pane.zig:449`), type chip `typeLabel` (`request_view.zig:1046`), `wrap` | yes | none | |
| Vim-style select + copy (`Y`/`C`) | `http.copy_response_body`, `copy` chip; selection in `resp_view` not verified | yes | none/? | |
| Headers / Cookies tabs | Body · Headers · Cookies · **Timeline** · **Tests** (`ResponseTab` `request_view.zig:93`) | yes | none | Posting has no timeline or tests tab |
| Size + time (footer) | title shows bytes; Timeline wait/receive/total (`Timing` `request_view.zig:149`) | yes | none | |
| Scripts output tab | Tests tab shows `@assert` lines + schema result | yes | none | |
| **Response search** | — (`editor_view` has find spans, `zig:ui/editor_view.zig:1446`, not wired to `resp_view`) | — | missing | Posting: **roadmap only** — open field |
| Open in external pager `F3` / `pager_json` (`fx`) | — (`openExternal` is URL-only: `zig:app/git.zig:724`, `lsp_decor.zig:494`) | — | missing | |
| Open field in external editor `F4` | — | — | missing | mnml *is* an editor; see §4 |
| Save response to file | `http.save_response` (`zig:app/http.zig:1564`) | yes | none | Posting lacks it |
| Diff two responses | `http.diff_last_two` (`http.zig:1360`, `keepAsPrev` `request_pane.zig:376`) | yes | none | Posting lacks it |
| Copy as curl (+ `curl_export_extra_args`) | `http.copy_curl`, `http.copy_as` → curl / Python / JS fetch / Go / wget / HTTPie (`cmd_http.zig:1107`) | yes | none | |
| Copy URL, copy KV table (2.10) | `http.field_copy`, `copy_response_headers/cookies/timeline/tests` | yes | none | |
| Export request as YAML (2.9) | n/a — the source *is* a text file | n/a | none | |

### Collections & environments

| Posting | mnml-zig today | Rust mnml | Gap | Note |
|---|---|---|---|---|
| Collection = directory of `.posting.yaml`, sub-collections, tree in sidebar (left/right) | COLLECTIONS section walks every `.http`/`.rest`/`.curl` (cap 500) (`zig:app/http_panel.zig`); plus the normal file tree | yes | none | |
| Default global collection | `collection_root = .hidden (.rqst/) \| .workspace` (`docs/CONFIG.md:264`) | yes | none | |
| Fuzzy **request search** by name (`Ctrl+Shift+P`) | panel `/` substring filter over files (`http_panel.zig:276 rebuild`); `picker.files` | yes | partial | `### block` names inside one file are not indexed |
| `.env` files, `$VAR`/`${VAR}`, `--env` (repeatable), layering, nested refs, auto-load `posting.env` | `.mnml/env/<name>.env` + `.rqst/env/` (`zig:http/env.zig:17`), `{{VAR}}`, `--env`/`$MNML_ENV`/config default (`env.zig:177 select`) | yes | partial | one active name at a time (two dirs layer); nested refs + host-env fallback not verified |
| **Env switching at runtime** | `http.pick_env` / `reset_env` / `new_env` / `edit_env` / `delete_env_key`; ENVS section; `http.fan_envs` | yes | none | Posting: switcher is **roadmap** |
| `watch_env_files` — live reload on disk edit | — (no watch/mtime in `http.zig` / `env.zig` / `http_panel.zig`) | — | missing | |
| Hide secrets in preview | `# @secret` + name heuristics (`env.zig:49,115`) | yes | none | |
| Dynamic values | `{{$uuid}} $guid $timestamp $epochMs $randomInt $isoTimestamp $date` (`env.zig:414`) | + faker vocab (`rust:http/faker.rs`) | none | Posting has none |
| Postman import (+ vars → `.env`) | `http.import_postman` (`zig:http/import.zig:96`) | yes | none/? | whether variables land in an env file not verified |
| OpenAPI import → collection, JSON body generation, securitySchemes | `discover` CLI + `http.sync` sources (`zig:http/discover.zig` `synth`, `sources.zig`) | + faker | none | mnml re-syncs from upstream; Posting is one-shot |

### App-level

| Posting | mnml-zig today | Rust mnml | Gap | Note |
|---|---|---|---|---|
| Jump mode `Ctrl+O` (QWERTY overlay) | — ; leader `<leader>h s/y/d/]/[` (`zig:app/whichkey.zig:170`) | — | partial | different idiom |
| Contextual help `F1` per widget | `whichkey.leader`, `keys.doctor`, `keys.edit` | F1 discovery | partial | per-widget help not verified in Zig |
| Command palette `Ctrl+P` (themes w/ preview, show/hide, export) | palette + ~105 `http.*` ids (`zig:commands/specs.zig:647-749`) | yes | none | |
| Keymap remap (`keymap:` per action id) | `.keys.global/.vim/.standard` (`docs/CONFIG.md:196-199`) | yes | none | |
| Themes: built-ins, YAML custom, live file watch, xresources | 94 NvChad palettes + `themes/*.zon`, picker with live preview, `theme.auto_system` (`docs/CONFIG.md` Themes) | yes | none | no theme-file watch (minor) |
| Layout horizontal / vertical; compact / standard spacing | `Orientation` auto/vertical/horizontal for Request↔Response (`request_view.zig:167`), edit split + drag ratio; `tierFor` (`:342`) | yes | none | |
| Focus config (`on_startup`, `on_response`, `on_request_open`) | — | — | missing | small |
| Config as env vars `POSTING_*` | — (`config.zon` + workspace `.mnml/config.zon`) | — | missing | low value |
| Mouse | full | full | none | |
| SSL: `ca_bundle`, client cert/key/password | — | — | missing | |
| Proxies | — (Posting: httpx env vars) | — | missing | |
| Send from CLI / headless | `mnml-zig run FILE [--env] [--workspace]` (`zig:http/cli.zig:82`) | yes | none | Posting cannot |
| Unsaved-changes warning | Posting: roadmap. mnml: quit guard covers editor panes; request panes not verified | ? | ? | |

## 2. What mnml has that Posting lacks

Posting's own roadmap lists most of these as future work (WebSocket/SSE,
testing framework, cookie editor, env switcher, response search, OAuth2,
file upload, templates, tags).

| Capability | Where |
|---|---|
| Request files live **beside code** as `.http` / `.rest` / `.curl`; multi-block `###`; `http.next_block`/`prev_block`; `{{VAR}}` highlight + click + hover + quick-fix **inside ordinary editor buffers** | `zig:http/parse.zig`, `zig:app/http.zig:481 editorVarSpans`, `:394 openQuickFixMenu` |
| Chains (`.chain.json`, extract between steps) + `chain run` CLI | `zig:http/chain.zig`, `cmd_http.zig:660`, CHAINS section |
| Mocks: save a response as a sidecar, replay without network; an in-process mock `Server` | `zig:http/mock.zig` (`save`, `Server.start`), `http.save_mock`/`replay_mock` |
| Captured browser traffic (CDP) → replayable `.curl`; `mnml-zig proxy` headless capture | `zig:http/captured.zig`, `proxy.zig`, `http.view_captured`/`capture_now` |
| WebSocket pane (connect/send/history, subprotocols, ping, reconnect) | `zig:http/ws.zig`, `zig:app/ws_pane.zig`, `ws.*` |
| SSE streaming with per-event delivery + cancel; SSE parse helper | `zig:http/sse.zig`, `http.send_streaming`, `http.cancel` |
| Bench 10× concurrent, p50/p95/p99 | `zig:http/bench.zig`, `http.bench` |
| Discover from OpenAPI/Swagger with schema-driven bodies; **sources sync** with drift check | `zig:http/discover.zig`, `sources.zig`, `http.sync`/`sync_check` |
| JWT decode + expiry, bearer extraction | `zig:http/jwt.zig`, `jwt.decode`, `auth.extract_bearer` |
| JSON-Schema validation of responses via sidecar; result in Tests tab | `zig:http/schema.zig`, `cmd_http.zig:164 validateSchema` |
| `@assert` / `@capture` post-scripts → Tests tab (Posting: "testing framework" is roadmap) | `zig:http/script.zig:304 runAsserts`, `:351 runCaptures` |
| Fan one request across every env in parallel | `http.fan_envs` (`cmd_http.zig:542`) |
| History per workspace + global, RECENT section, re-fire as scratch | `zig:http/history.zig`, `http.history`/`history_global` |
| Cookie jar persisted at `.mnml/cookies.json`, auto-attach, COOKIES section, delete/clear/normalize | `zig:http/cookies.zig:119`, `cookies.*` |
| Redirect hops keep `Set-Cookie`, drop `Authorization` cross-host | `client.zig:755,842` tests |
| Response diff, save-to-file, six copy-as targets | `http.diff_last_two`, `save_response`, `copy_as` |
| AI: redacted "debug this failure" prompt; `ai_build`/`ai_debug` reserved (Phase 7) | `http.copy_ai_prompt`, `cmd_http.zig:840` |
| Lookup picker: fill an env var from a live list response | `http.lookup`, `cmd_http.zig:796` |
| HAR import | `zig:http/import.zig:50` |
| Auth presets saved/applied | `cmd_http.zig:939,972` |
| Lua scripting substrate (commands, pickers, panes, tasks) | `zig:scripting/`, `docs/LUA.md` |
| 36 `.test` e2e files under `tests/e2e/http/` | |

## 3. Ranked gap list — to surpass Posting

Effort S < 1 day, M 1–3 days, L > 3.

| # | Gap | Surface | Effort | Note |
|---|---|---|---|---|
| 1 | **Programmable pre/post hooks** (Posting: Python `setup`/`on_request`/`on_response`, `set_variable`, `notify`) | Script tab + `init.lua` | M | Add `http_request` / `http_response` to the `mnml.on` table (`docs/LUA.md:92`). Payload: `{ pane, method, url, headers = {…}, body, env }`; a returned table mutates the request. `http_response` adds `status, headers, body, timing_ms` plus `mnml.http.set_var(name, value)` writing through `env.upsert` (`env.zig:243`). Fire from `cmd_http.runScript` (`:133`) and `afterResponse` (`:107`) so `@set-*` / `@assert` and Lua compose. The 20 ms Lua budget (`LUA.md:38`) is fine for header munging; body transforms of MB bodies need the budget raised for that hook. |
| 2 | **Header name + value autocomplete** while typing | Headers tab | M | Turn the Headers text area into the same KV table Params uses (`KvKind.headers` already enumerated, `request_view.zig:773`). Bundled table: ~60 names, per-name value lists (`Accept`, `Content-Type`, `Cache-Control`, `Authorization` schemes…). See §4-A for the part that beats Posting. |
| 3 | **Per-request options**: verify-SSL, timeout, follow-redirects, proxy | new Options rows on the Auth tab (or an Options tab) + `# @no-redirect` / `# @timeout 5s` / `# @insecure` directives | M–L | `req.insecure` is parsed (`parse.zig:41`) but `client.zig:295` ignores it — that is a silent lie today. `std.http.Client` needs a custom TLS init to skip verification; timeout via `Io` deadline; proxy via `std.http.Client` proxy fields. Rust had insecure + 30 s (`rust:http/mod.rs:186`). |
| 4 | **Response search** (Posting roadmap) | Response block, `/` | S | `editor_view` already renders find matches (`editor_view.zig:1446`); wire `editor.find` to `resp_view` when the Response block is focused. |
| 5 | **Variable completion** on `{{` in URL / Body / Headers / Params | request fields | S | Popup from `varRows` (`http.zig:224`) + dynamic `$` names + `@capture` names. |
| 6 | **Row enable/disable** (headers, params) | Params/Headers tables | S–M | Round-trip as a `# ` comment prefix on the header line in the `.http` source so the file stays valid for other tools; Params table gets a `☐` column. |
| 7 | **Env file live reload** | ENVS section, var tips | S | mtime poll on the active env path in the 80 ms tick (`app.zig:2042`); on change re-run `refresh` + re-paint var spans. |
| 8 | **Request rename / duplicate / delete / move** from COLLECTIONS | HTTP panel row menu (`http_panel.zig:580`) | S | Duplicate = clone block + `### name-copy`; rename = edit the `###` line; delete confirms. |
| 9 | **Fuzzy search over request *blocks*** (Posting `Ctrl+Shift+P`) | palette / picker | S | Picker source over `parse.blocks` (`parse.zig:695`) of every COLLECTIONS file: `name · METHOD url · file`. |
| 10 | **Path params** `:id` tab | Params tab, second group | S | Tokenise `:name` in the URL path (escape `::`); rows edit like query params; substitute before `expand`. |
| 11 | **Multipart file upload** + body-type selector (raw / JSON / form-urlencoded / multipart) | Body tab chip | M | Read `@path` relative to the source file's dir (Rust did: `http.rs:969`); Posting has none — a surpass item. |
| 12 | **External editor / pager** (`F4` / `F3`, `pager_json`) | Body + Response | S | Better than Posting: open the field in a real **editor pane** bound to the field (`Pane.editor` on a scratch buffer, write-back on save) — no TUI suspend. Keep `$PAGER` as the escape hatch for >16 MB bodies. |
| 13 | **Digest auth**, then OAuth2 client-credentials / auth-code (Posting roadmap) | Auth tab rows (`auth_rows`) | M | Digest needs a 401 challenge round-trip in `client.zig`; OAuth2 = one extra request + `@capture`-style token cache in the env. |
| 14 | **Jump mode + per-widget F1 help** | whole request pane | M | Overlay letters on the hit ids that already exist (`hit_*` `request_view.zig:273-311`); F1 lists the focused block's keys from `specs.zig`. |
| 15 | **Description + tags** on a request | `# @description` / `# @tags a b` directives; COLLECTIONS filter matches tags | S | Posting: tags are roadmap. |

Also-rans: focus config (`on_response` → jump to Body), Postman import writing variables to an env file (verify `import.zig:96`), nested `${A}` references inside env files (verify `env.zig:332 expand`), theme-file watch.

## 4. Three things to do better than Posting, not just match

**A. Header autocomplete seeded from the wire, not just a table.** Rank
candidates by (1) the bundled name/value table, (2) the **last response's
own headers** for this host (`Response.headers`, `client.zig:80`) — a
server that answered `ETag` / `X-RateLimit-Remaining` is telling you what to
send next (`If-None-Match`, pagination cursors), (3) headers used elsewhere
in the workspace's `.http` files (frequency-ranked from the COLLECTIONS
scan), (4) `@capture`d values as `{{VAR}}` suggestions in the value column.
Hover on a name shows a one-line MDN summary (Posting's roadmap has "in-app
information about headers" and "MDN header link" as unbuilt).

**B. Variable completion with inline resolution and an env story Posting
does not have.** On `{{` pop the completion from the active env, dynamic
`$` vars, chain/`@capture` outputs and cookie-jar names; render the
**resolved value as ghost text** after the token (masked when
`# @secret`); unresolved stays `error_fg` with the existing quick-fix
(`openQuickFixMenu`, `http.zig:394`). mnml already has `pick_env`,
`fan_envs`, `edit_env` and the ENVS section — Posting's roadmap still lists
"collection and environment switchers" and "variable autocompletion and
resolution highlighting". Add hook #1 so a Lua `http_response` can set a
var that the next request's completion immediately offers.

**C. Response search + diff as one investigation tool.** Posting has neither
(search is roadmap). mnml has `http.diff_last_two`; extend it to diff the
current response against **any RECENT entry or a mock sidecar**, make the
JSON diff key-order-insensitive, and give the Response block the editor's
find bar plus a JSONPath filter row (`$.items[*].id`, reusing
`script.resolveJsonPath`, `script.zig:393`) whose matches become the copy
target. Timeline + Tests + diff + search in one block is the "why did this
call change" workflow neither Posting nor Postman's TUI clones ship.
