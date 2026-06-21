---
title: HTTP Request pane — tabs & layout
description: The Postman-style three-panel Request pane — colored Method chip, six Edit tabs (Body / Headers / Params / Auth / Vars / Source), the Auth presets, and every chord that drives it.
---

When you fire `http.send` or open a blank `:http.new`, mnml splits a **Request pane** (`Pane::Request`) into your layout. This page is the deep tour of what's inside it: the three stacked panels, the colored Method chip, the six Edit tabs, and the chords + clicks that drive each.

The pane has one job — let you compose a request, fire it, read the response, and ask Claude about it — without leaving the editor. It's mnml's Postman.

## The three-panel layout

The pane is **vertically stacked**, not tabbed between Edit and Response. From top to bottom:

1. **Request** — the editable form (Method chip + URL + tab strip + active-tab content). This grows from the top.
2. **Response** — status line + headers + body. Scrolls within the middle region.
3. **AI** — a 2-row strip **pinned to the bottom** of the pane. Always visible. Click it to ask Claude a custom question about this request/response pair.

```
┌─ Request ────────────────────────────────────────────────────┐
│  [GET]  https://api.example.com/users/42                     │
│   Body  [Headers]  Params   Auth   Vars   Source             │
│                                                              │
│   Authorization: Bearer eyJhbG...                            │
│   Accept: application/json                                   │
├──────────────────────────────────────────────────────────────┤
│  response                                                    │
│   200 OK   142 ms   18 lines · 3.2 KB                        │
│   content-type: application/json                             │
│   x-trace-id: abc-1234                                       │
│   {                                                          │
│     "id": 42,                                                │
│     "name": "Alice"                                          │
├──────────────────────────────────────────────────────────────┤
│  ai   (click here to ask a custom question · `a` quick debug)│
└──────────────────────────────────────────────────────────────┘
```

`Tab` toggles which view holds the input focus for the legacy `r` / `y` / `Y` chords; Edit-view mouse + keyboard editing fields are always live. The AI strip is genuinely pinned — scroll the body up or down and the strip stays at the bottom of the pane (poor man's independent panel scroll).

The footer hint on the AI row reminds you: clicking the header itself opens a custom-question prompt, while pressing `a` (or `.`) from Response view fires the canned "debug this for me" prompt without asking.

## The Method chip + URL row

The first editable row is the Method-chip + URL line:

```
  [GET]   https://api.example.com/users/42
  [POST]  https://api.example.com/users
  [PUT]   https://api.example.com/users/42
  [PATCH] https://api.example.com/users/42
  [DELETE]https://api.example.com/users/42
  [HEAD]  https://api.example.com/users/42
  [OPTIONS]https://api.example.com/users
```

The Method renders as a **colored chip** — the chip's background changes per verb so the request's shape reads at a glance from across the room:

| Method | Color | Purpose |
|---|---|---|
| `GET` | green | Safe + idempotent — fetching |
| `POST` | orange | Creating / mutating — non-idempotent |
| `PUT` | blue | Replacing — idempotent |
| `PATCH` | cyan | Updating — non-idempotent |
| `DELETE` | red | Removing — explicit destructive |
| `HEAD` | yellow | Headers only |
| `OPTIONS` | purple | Capability probe |

Three ways to change the method:

- **Click the chip** opens the **method dropdown** — a context menu listing all 7 verbs. Click one to set it directly (no cycling through verbs you don't want). Backed by 7 `:http.set_method.<verb>` palette commands.
- **`:http.cycle_method`** (or `Space` when the Method field is focused) walks `GET → POST → PUT → PATCH → DELETE → HEAD → OPTIONS → GET`.
- **`:http.set_method.<verb>`** (one of 7 — `.get`, `.post`, `.put`, `.patch`, `.delete`, `.head`, `.options`) sets a specific verb. Useful as a chord binding (`<leader>hG` → set GET, etc).

The URL fills the rest of the row in normal fg color. Click it to focus the field; `Enter` on the URL row (or the Method chip row) fires the request.

## The Edit tab strip

Between the URL row and the tab content sits a 6-tab strip:

```
 [Body]   Headers   Params   Auth   Vars   Source
```

The active tab carries bracket markers (`[Body]`), bold, and underline. Inactive tabs are dim. Color isn't load-bearing — the brackets + underline + bold survive monochrome themes and stay legible for colorblind users.

### Switching tabs

| Chord | Action |
|---|---|
| `Ctrl+]` | Next tab (Body → Headers → Params → Auth → Vars → Source → Body) |
| `Ctrl+[` | Previous tab |
| `Ctrl+1` | Jump to **Body** |
| `Ctrl+2` | Jump to **Headers** |
| `Ctrl+3` | Jump to **Params** |
| `Ctrl+4` | Jump to **Auth** |
| `Ctrl+5` | Jump to **Vars** |
| `Ctrl+6` | Jump to **Source** |
| Mouse click | Click any chip directly |

`Ctrl+]` / `Ctrl+[` / `Ctrl+1..6` are intercepted before the global chord chain so they work in both input modes — standard mode's keymap binds those chords to indent / outdent globally, but the dispatcher checks for a focused Request pane in Edit view first and steals them.

`Tab` is reserved for cycling **fields** (URL → Method → Headers → Body → URL). It does *not* switch tabs. The tab strip and the field focus are independent.

Switching **to** the Source tab also focuses the Source field so you can immediately type or paste. Switching **away** from Source restores URL focus.

## Per-tab content

### Body

The multi-line Body field. Editable. JSON / XML / form-encoded / plain — anything you can type in.

```
Body  (JSON) — Ctrl+Shift+F formats JSON
   {
     "name": "Alice",
     "email": "alice@example.com"
   }
```

The label hint surfaces a **detected content type** so you see what mnml thinks the body is: `JSON` (starts with `{` or `[`), `XML` (starts with `<`), `form` (looks like `key=val&key=val`), or no label for plain text. The detection is a cheap leading-bytes sniff on the first ~256 chars, run every frame.

`Tab` inside Body inserts a literal `\t` rather than cycling fields — indented bodies are common. Newlines stay newlines; the body is sent verbatim.

#### Formatting JSON

| Surface | Call |
|---|---|
| Palette | `HTTP: pretty-print JSON Body field of the active Request pane` |
| Ex-command | `:http.format_body` |
| Chord (Edit view) | `Ctrl+Shift+F` |

Parses the Body field as JSON and rewrites it with 2-space indent. No-op on non-JSON bodies (the toast explains the parse error). Useful after pasting a minified payload from a browser DevTools panel.

The chord matches what most IDEs use for "format code" — and unlike them, mnml's version is body-scoped: it doesn't try to format your headers or your URL.

### Headers

The `Key: Value` list. Editable as a flat textarea — type `Authorization: Bearer xyz\n` to add a line. Header keys render in cyan + bold, values in foreground; lines without a `:` render dim (a visible hint they're not yet a valid header).

#### Insert a common header

Don't know whether it's `Content-Type` or `ContentType`? Use the picker:

| Surface | Call |
|---|---|
| Palette | `HTTP: insert a common header (Accept, Content-Type, Authorization, …)` |
| Ex-command | `:http.insert_header` |

Opens a picker over **20 IANA-common header names** — `Accept`, `Accept-Encoding`, `Accept-Language`, `Authorization`, `Cache-Control`, `Content-Type`, `Content-Length`, `Content-Encoding`, `Cookie`, `Host`, `If-Match`, `If-None-Match`, `If-Modified-Since`, `Origin`, `Referer`, `User-Agent`, `X-Api-Key`, `X-Forwarded-For`, `X-Requested-With`, `X-Trace-Id`. Enter inserts `Name: ` at the Headers cursor and switches you into the Headers tab so you can immediately type the value.

### Params

A row-per-query-parameter view of whatever's after the `?` in the URL.

```
   + Add new parameter…
   foo = bar
   limit = 10
```

Click rows to interact:

- **`+ Add new parameter…`** (green) — opens a prompt for `KEY=VALUE`; on Enter, appends to the URL with the correct `?` / `&` separator. Same as `:http.params_add`.
- **Any existing row** — clicks the param. v1 deletes the param (`:http.params_delete <key>`); a v2 edit-prompt is queued.

Two palette commands also drive the surface:

| Surface | Call |
|---|---|
| `:http.params_add` | Prompt for KEY=VALUE, append to URL |
| `:http.params_clear` | Strip the entire `?…` portion from the URL |

The Params tab reflects the URL — edit the URL field directly and the Params tab re-renders on the next frame. Empty query string shows `(no query parameters — add ?key=value to URL)`.

### Auth

The Auth tab is **Postman parity** for authentication setup. The current state of the Authorization header summarizes at the top:

```
   Current:  Bearer · eyJhbGciOiJIUzI1NiJ9
   
   + Set Bearer token…
   + Set Basic auth (user:pass)…
   + Set X-Api-Key…
   ↻ Apply saved preset…
   💾 Save current as preset…
   ✗ Clear Authorization
```

The summary shows what kind of auth the active header carries — `Bearer · <token preview>` for bearer tokens, `Basic · (base64 user:pass)` for basic auth, or `(no Authorization header — request will be unauthenticated)` when there isn't one.

Click any action row to dispatch:

| Action | Prompt / dispatch | Result |
|---|---|---|
| **+ Set Bearer token…** | Prompts for the raw token (no `Bearer ` prefix) | Replaces or inserts `Authorization: Bearer <token>` |
| **+ Set Basic auth…** | Prompts for `user:password` | Replaces or inserts `Authorization: Basic <base64>` |
| **+ Set X-Api-Key…** | Prompts for the key value | Replaces or inserts `X-Api-Key: <value>` |
| **↻ Apply saved preset…** | Picker over `.mnml/auth/*.txt` | Replaces Authorization with the preset's content |
| **💾 Save current as preset…** | Prompts for the preset name | Writes the current `Authorization` value to `.mnml/auth/<name>.txt` |
| **✗ Clear Authorization** (red) | No prompt | Removes the Authorization header entirely |

#### Auth presets

Auth presets save a configured `Authorization` header for reuse across requests in the workspace. Two palette commands also drive them outside the Auth tab:

| Surface | Call |
|---|---|
| Palette | `Auth: save current Authorization header as a named preset` |
| Ex-command | `:auth.save_preset` |

Prompts for a name. Writes the current Authorization header content (everything *after* the `Authorization: ` colon) to `.mnml/auth/<name>.txt`. Workspace-local, per-name file.

| Surface | Call |
|---|---|
| Palette | `Auth: apply a saved preset → active Request Authorization header` |
| Ex-command | `:auth.apply_preset` |

Picker over the workspace's `.mnml/auth/*.txt` files. Enter writes (or replaces) the Authorization header on the active Request pane.

Add `.mnml/auth/` to your `.gitignore` if the presets are personal tokens; commit a `*.txt.example` template if they're shared values.

### Vars

A live read-out of the active env file's variables — what `{{VAR}}` substitution sees when you fire this request.

```
   Active env vars — edit with :http.edit_env
   env: dev.env
   
   + Add new variable…
   TOKEN = eyJhbGciOiJIUzI1NiJ9...
   BASE_URL = https://staging-api.example.com
   LOGIN_EMAIL = qa@example.com
```

Reads both `.rqst/env/<active>.env` and `.mnml/env/<active>.env`, with `.mnml/` overriding on the same key (the same precedence the runtime substituter uses).

Click rows:

- **`+ Add new variable…`** (green) — opens the env-editor add prompt (`:http.edit_env` → `+add`).
- **Any existing row** — opens the env-editor edit prompt for that key. The picker is the same one [HTTP envs & templating](/manual/http-envs/) describes.

The active env name is detected at render time via the same resolution chain as a `http.send`: `--env` (when launched headlessly) → `$MNML_ENV` → `.rqst/config`'s `default_env` → `dev`.

### Source

A paste-target hint surface:

```
   Paste a curl command or .http block here.
   Then run :http.paste_curl (or Ctrl+Shift+V) to populate fields.
   (clipboard paste-curl reads your system clipboard directly)
```

The "source" of truth is the clipboard — the tab is documentation for the paste flow, not an editable scratch buffer. Right-clicking anywhere in the Source tab fires the URL-titled field menu with **Paste curl from clipboard** ready.

An editable in-pane source field is a v2 feature; today's Source tab is honest about being a hint surface.

## Cross-tab chords

These chords work in any Edit-view tab:

| Chord | Action |
|---|---|
| `Tab` | Cycle field forward (URL → Method → Headers → Body → URL) |
| `Shift+Tab` | Cycle field backward |
| `Ctrl+]` / `Ctrl+[` | Next / previous tab |
| `Ctrl+1..6` | Jump directly to Body / Headers / Params / Auth / Vars / Source |
| `Ctrl+Shift+V` | Paste curl from clipboard (populate all fields) |
| `Ctrl+V` | Paste plain text into focused field |
| `Ctrl+Shift+F` | Format Body as JSON |
| `Ctrl+Enter` | Parse Source-tab buffer into Method/URL/Headers/Body |
| `Space` (Method focused) | Cycle HTTP verb |
| `Enter` (URL / Method) | Fire the request |
| `Enter` (Headers / Body) | Insert newline |
| `Esc` | Flip to Response view |

## The Response panel

The middle panel renders once the request lands. The status line up top:

```
   200 OK   142 ms   18 lines · 3.2 KB
```

- **Status chip** — `2xx` green, `3xx` cyan, `4xx` yellow, `5xx` red. Bold, on the response's `bg_dark`.
- **Elapsed** — request-to-response wall-clock in ms.
- **Stats** — body line count + human-readable byte count (`B` / `KB` / `MB`). Useful when scanning whether the response was empty (`0 lines · 0 B`) or huge (`8431 lines · 1.4 MB`).

Then headers, in arrival order, dimmed. Then the body — pretty-printed when the `Content-Type` says JSON (or the body starts with `{` / `[`); raw otherwise.

Below the body, when present: `✓` / `✗` rows per `@assert` directive, and `name = value` rows per `@capture` directive.

### Schema-validation footer

When a sibling `<request>.schema.json` exists, the Response view paints a one-line footer below the body summarising JSON Schema validation:

```text
   ✓ Schema valid (users.schema.json)
```

```text
   ✗ Schema: 3 errors (users.schema.json) — :http.show_schema_errors
```

Green-bold on pass; red-bold on fail with the `:http.show_schema_errors` ex-command literally in the footer text so you can copy it. Yellow warnings render for the edge cases:

- `⚠ Body isn't JSON — schema (file) skipped` — the response wasn't parseable JSON, so the schema couldn't run against it.
- `⚠ Schema read error (file): <err>` — the sidecar exists but couldn't be read.
- `⚠ Schema parse error (file): <err>` — the sidecar exists but isn't a valid JSON Schema document.

No sidecar = no footer. The full mechanism (resolution order, the two `:http.show_schema_errors` / `:http.revalidate_schema` commands, edge cases) lives on its own page — [HTTP response schema validation](/manual/http-schema/).

### Response chords (Response-view focus)

| Chord | Action |
|---|---|
| `r` | Re-fire the request using the pane's current field values |
| `y` | Copy the request as a curl |
| `Y` | Copy the response body |
| `e` | Toggle view (legacy — Tab also works) |
| `a` or `.` | Ask Claude about this request/response (canned debug prompt) |
| `j` / `k` / `↑` / `↓` | Scroll the body |
| `g` / `G` | Top / bottom of response |
| `Page Up` / `Page Down` | Page the body |
| `Esc` | Focus the file tree |

### Saving the response body

| Surface | Call |
|---|---|
| Palette | `HTTP: save active Response body to a file (prompt for path)` |
| Ex-command | `:http.save_response` |

Prompts for a destination path; on Enter, writes the active Done response body to that file. Relative paths resolve under the workspace root; absolute paths land where you'd expect. Parent directories are `mkdir -p`'d. Toasts the byte count + full path on success.

### Diffing the last two responses

| Surface | Call |
|---|---|
| Palette | `HTTP: diff the active Request pane's last two responses` |
| Ex-command | `:http.diff_last_two` |

After re-firing a request (`r`), the previous Done response is stashed. This command opens a scratch buffer with a unified-diff of status + headers + body between the old and new responses. Useful for "did re-firing actually change anything?" debugging.

## The AI panel

The bottom strip is a 2-row pinned region:

```
─────────────────────────────────────────────────────────────
  ai   (click here to ask a custom question · `a` quick debug)
```

Two click affordances + two chords:

- **Click the `ai` header row** — opens a prompt: *"Ask Claude about this request/response:"*. Type your question, press Enter, and the request + response (status / headers / body, capped at 4000 chars) ship to the AI backend along with your question. Custom-question debugging.
- **`a` (or `.`) from Response view** — fires the canned `http.ai_debug` prompt with no custom question (just "why isn't this working / how do I fix it"). Useful when the failure is obvious to a model but not to you.

Both routes dispatch through the same AI backend you've configured (claude CLI, Codex, or direct Anthropic API). See [AI panes](/manual/ai-panes/) for backend setup.

Requirements: the pane must hold a Request pane with a `Done` response (or a transport error). Asking about a still-in-flight Sending state toasts `wait for the response first`.

## Field-aware right-click menu

Right-click any form row or any tab content row to get a context menu titled with the field's name:

```
┌─ Request · Method ──────────┐
│  Cycle method               │ ← only on the Method row
│  Send                       │
│  Paste curl from clipboard  │
│  Copy as curl               │
│  Switch to Response         │
└─────────────────────────────┘
```

Common items appear on every field's menu:

| Item | What it does |
|---|---|
| **Send** | Fires the request |
| **Paste curl from clipboard** | `:http.paste_curl` — overwrites fields from clipboard |
| **Copy as curl** | `:http.copy_curl` — copies the current request as a curl one-liner |
| **Switch to Response** | Flips the pane to Response view |

The Method row's menu prepends **Cycle method** so you can change verbs without keyboard focus. The Params / Vars / Source tabs use the URL-titled menu.

## Toasts that reveal panes

Commands that open a scratch pane (`http.bench`, `http.sync`, `http.diff_last_two`, …) toast with a bracketed pane name:

```
bench summary — 10 samples in 1842 ms → [bench-trace]
```

The `[bench-trace]` portion renders in yellow + bold + underlined. Clicking it switches focus to the scratch pane. See [Cmdline popup](/manual/cmdline-popup/#toast-name-mentions) for the full mechanism.

## Quick reference

### Method dropdown surface

| Verb | Color | Palette id |
|---|---|---|
| `GET` | green | `http.set_method.get` |
| `POST` | orange | `http.set_method.post` |
| `PUT` | blue | `http.set_method.put` |
| `PATCH` | cyan | `http.set_method.patch` |
| `DELETE` | red | `http.set_method.delete` |
| `HEAD` | yellow | `http.set_method.head` |
| `OPTIONS` | purple | `http.set_method.options` |

Plus `http.cycle_method` (cycles to next verb) and the Method chip click (opens the dropdown).

### Edit-tab content surface

| Tab | Ctrl+N | Editable | Primary palette helpers |
|---|---|---|---|
| **Body** | `Ctrl+1` | yes (multi-line) | `http.format_body` (Ctrl+Shift+F) |
| **Headers** | `Ctrl+2` | yes (multi-line) | `http.insert_header` |
| **Params** | `Ctrl+3` | click rows | `http.params_add`, `http.params_clear` |
| **Auth** | `Ctrl+4` | click rows | `auth.save_preset`, `auth.apply_preset` |
| **Vars** | `Ctrl+5` | click rows | `http.edit_env` |
| **Source** | `Ctrl+6` | paste target | `http.paste_curl` (Ctrl+Shift+V), `http.paste_source` (Ctrl+Enter) |

### Response surface

| Action | Chord | Palette id |
|---|---|---|
| Re-fire | `r` | `http.send` |
| Copy curl | `y` | `http.copy_curl` |
| Copy body | `Y` | `http.copy_response_body` |
| Save body | — | `http.save_response` |
| Diff last two | — | `http.diff_last_two` |
| Ask Claude (canned) | `a` / `.` | `http.ai_debug` |
| Ask Claude (custom) | click `ai` strip | — |
| Toggle view | `Tab` / `e` | `http.toggle_view` |

## Next

- [HTTP client](/manual/http/) — the file-driven surface (`.http` / `.curl` / `.rest`, `http.send`, the response view)
- [HTTP response schema validation](/manual/http-schema/) — the `.schema.json` sidecar that paints the footer + the two ex-commands that drill into it
- [New request — Postman-style scratch pane](/manual/http-new-request/) — `:http.new`, paste-curl from clipboard, the empty-pane landing
- [HTTP build from natural language](/manual/http-ai-build/) — `:http.ai_build` lands a parsed request on the Source tab
- [HTTP envs & templating](/manual/http-envs/) — `{{var}}` resolution + the `:http.edit_env` picker the Vars tab points at
- [HTTP helpers — JWT, bearer, cookies, SSE](/manual/http-helpers/) — clipboard tooling for tokens, cookies, and SSE diagnostics
- [HTTP bench](/manual/http-bench/) — the histogram + percentile breakdown of `:http.bench`
- [Cmdline popup](/manual/cmdline-popup/) — the floating completion box every `:http.*` command flows through
