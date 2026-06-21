---
title: HTTP build from natural language
description: "`:http.ai_build` turns a plain-English request description into a curl command via Claude — opens a new Request pane on the Source tab so you can audit before firing."
---

`:http.ai_build` is the "describe it, don't type it" path into the Request pane. You ask in English — *"GET the top 5 users from staging, with my bearer token"* — Claude returns a single-line curl, mnml parses it, and a new Request pane opens with Method / URL / Headers / Body already populated.

The pane lands on the **Source tab** so the curl Claude produced is the first thing you see — auditable before you fire it. This isn't "describe-and-send"; it's "describe, inspect, then send".

## Calling it

| Surface | Call |
|---|---|
| Palette | `HTTP: build a request from a natural-language description (Claude)` |
| Ex-command | `:http.ai_build` |

No default keybinding — bind it under `[keys.global]` if you reach for it often.

The flow:

1. mnml checks `$ANTHROPIC_API_KEY`. If unset, toast: `http.ai_build: $ANTHROPIC_API_KEY not set`. Bail.
2. A prompt opens at the bottom of the screen: `Describe the request (NL → curl):`.
3. Type your description, `Enter`.
4. Toast: `http.ai_build: calling Claude…`. A worker thread fires.
5. When the reply lands, mnml parses it as curl, opens a new Request pane, populates fields, lands on Source. Toast: `http.ai_build: ✓ ready (Source tab)`.

If a build is already in flight when you call the command again, you get `http.ai_build: a build is already in flight` and the second call is dropped. One at a time.

## What Claude sees

The system prompt is fixed and unambiguous:

> You are an API request generator. The user describes an HTTP request in natural language; you output the EXACT corresponding `curl` command on a SINGLE LINE — no backslash continuations, no markdown fences, no commentary, no leading `$ ` prompt. Include explicit `-X <METHOD>`, `-H 'Header: …'` for every needed header (Content-Type, Authorization when implied, Accept where useful), and `--data '<json>'` for bodies (always JSON unless the user says otherwise). Prefer `https://`. When auth is implied but not given, use the placeholder `{{TOKEN}}`. When a host is implied but not given, use `https://api.example.com`.

What that means for what you type:

- **"GET /users/42 from staging, with my bearer token"** → `curl -X GET 'https://api.example.com/users/42' -H 'Authorization: Bearer {{TOKEN}}' -H 'Accept: application/json'` — the `{{TOKEN}}` placeholder is on purpose, so your env-driven substitution still applies.
- **"POST a new user with name Alice and email alice@example.com"** → `curl -X POST 'https://api.example.com/users' -H 'Content-Type: application/json' --data '{"name":"Alice","email":"alice@example.com"}'`.
- **"PATCH user 42 to set role admin"** → `curl -X PATCH 'https://api.example.com/users/42' -H 'Content-Type: application/json' -H 'Authorization: Bearer {{TOKEN}}' --data '{"role":"admin"}'`.

Concrete host, route, or token in your description? Claude uses them. Implied auth or hosts? Placeholders, so you can edit later or rely on `{{TOKEN}}` resolving against your active env.

## What lands in the pane

The reply is parsed by `crate::http::parse` (the same parser the `.curl` file format uses) and dropped into a new Request pane:

- **Method** — from the curl's `-X` (or implied `GET` if absent).
- **URL** — the URL argument from the curl line.
- **Headers** — every `-H 'Name: Value'` becomes a header row.
- **Body** — `--data` / `--data-raw` / `--data-binary` content.
- **Source tab** is selected. The full curl text Claude returned sits in the `source_buffer` field.

`rp.view = ViewMode::Edit`, `rp.edit_tab = EditTab::Source`. You're looking at the curl Claude produced from the moment the pane opens — not the parsed fields. That's deliberate: AI output goes through human-readable curl first, *then* into the form. If something looks off, you spot it in the Source view before clicking `r` to fire.

Once you've audited:

- `Ctrl+1` (or click the Body tab) jumps to the parsed Body field.
- `Enter` on the URL row, or `r` from Response view, or `:http.send` from the palette fires the request.
- `:http.copy_curl` round-trips it back out as a curl one-liner.

If the curl Claude returned didn't parse, the toast reads `http.ai_build: parse failed: <reason>` and no pane opens. The model occasionally returns prose despite the system prompt; re-trying with a slightly more concrete description usually fixes it.

## Output cleanup

mnml runs a small post-process on Claude's reply before parsing:

- **Strip ` ``` ` fences.** Despite the system prompt forbidding them, models occasionally wrap the output in markdown. The leading fence + language tag (`` ```bash ``, `` ```sh ``, plain ` ``` `) gets stripped; the trailing fence too.
- **Strip a leading `$ ` prompt.** If the model writes `$ curl …`, the `$ ` is dropped.
- **Strip backslash line continuations.** A `\\\n` becomes a single space, so multi-line curls collapse to one line before being handed to the parser.

These are belt-and-braces — the system prompt instructs against all three, but the cleanup means a stray fence doesn't turn into a parse error.

## Model selection

The worker uses the model from `self.ai_model()` — which respects `[ai] model` in your config:

```toml
# ~/.config/mnml/config.toml
[ai]
model = "claude-opus-4-7"   # or claude-sonnet-4-5, etc.
```

Unset leaves the worker at mnml's `DEFAULT_MODEL` baked into the binary. The same setting drives every AI surface in mnml (`:http.ai_debug`, the AI pane, etc.) — there's no per-command model override.

The call is non-streaming — a single `POST /v1/messages` with `max_tokens: 1024`, blocking until the full reply lands. The 30-second timeout on the underlying reqwest client bounds the worst-case wait; past that, the toast reads `http.ai_build: POST: <timeout error>`.

## Where it differs from `:http.ai_debug`

Two adjacent AI commands; not the same job:

| Command | Input | Output | When |
|---|---|---|---|
| **`:http.ai_build`** | NL description | A new Request pane with parsed curl | Before sending anything — design a request from words |
| **`:http.ai_debug`** | Existing Request pane's request + response | An AI pane with a debug analysis | After a send failed or behaved weirdly |

`ai_build` is generative: it makes a request out of nothing. `ai_debug` is analytical: it explains a request that already exists. They share the same `$ANTHROPIC_API_KEY` requirement and the `[ai] model` config.

## Edge cases

- **No API key** — `http.ai_build: $ANTHROPIC_API_KEY not set` toast. No prompt, no worker. Set the key in your shell before launching mnml, or in your env file.
- **Empty description** — `http.ai_build: empty description` after pressing Enter with nothing typed. The prompt closes; no worker spawned.
- **Build already in flight** — second call within the worker's lifetime is dropped with the in-flight toast. Wait for the previous to land.
- **Network error** — toast carries the underlying transport error (`http.ai_build: POST: <reason>`). The pane doesn't open.
- **Non-2xx from Anthropic** — toast carries the status + first 200 chars of the response body (`http.ai_build: HTTP 401 Unauthorized: …`). The pane doesn't open.
- **Curl Claude returned wasn't parseable** — toast: `http.ai_build: parse failed: <reason>`. The pane doesn't open.

## Next

- [HTTP client](/manual/http/) — `.curl` / `.http` files, `:http.send`, the Source tab the pane lands on
- [HTTP Request pane — tabs & layout](/manual/http-edit-tabs/) — every field the parsed curl populates
- [HTTP envs & templating](/manual/http-envs/) — `{{TOKEN}}` and friends, the placeholders Claude prefers
- [AI panes](/manual/ai-panes/) — the same `$ANTHROPIC_API_KEY` + `[ai] model` config that drives `:http.ai_debug` and the AI pane
