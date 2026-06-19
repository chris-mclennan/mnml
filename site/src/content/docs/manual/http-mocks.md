---
title: HTTP mocks
description: Freeze the active response to a sibling `.mock.json` and replay it offline, no network call.
---

A mock is a frozen response sitting next to its `.curl` / `.http` source file. Save one when an endpoint is being flaky; replay it later when you want to work on the UI that consumes the response without poking the live API. Useful for offline development, for canned data in screenshots / demos, and for the "I want to test how the page handles a 401 without convincing prod to give me a real one" case.

The file format is small and the round-trip is one-key — `http.save_mock` to capture, `http.replay_mock` to serve.

## File shape

```text
requests/auth/login.curl              ← the source
requests/auth/login.curl.mock.json    ← the frozen response
```

A mock is a sibling file with `.mock.json` appended to the source's full filename — extension included, so `login.curl` becomes `login.curl.mock.json` (not `login.mock.json`). This keeps `.http` and `.curl` versions of the same endpoint distinguishable on disk.

```json
{
  "status": 401,
  "status_text": "Unauthorized",
  "headers": [
    ["content-type", "application/json"],
    ["x-trace-id", "abc-123"]
  ],
  "body": "{\"error\":\"token expired\",\"code\":\"AUTH_001\"}",
  "ts": 1734652800123
}
```

Fields:

| Field | What |
|---|---|
| `status` | The numeric HTTP status (`u16`, required) |
| `status_text` | The status reason phrase (`"OK"`, `"Unauthorized"` — empty allowed) |
| `headers` | Array of `[name, value]` pairs, preserving source casing and order |
| `body` | The response body as a string (binary bodies aren't supported — base64-encode externally if you need them) |
| `ts` | Unix millis when the mock was saved. Informational; not read on replay |

A mock with a missing `status` field is rejected on load — that's the one field replay can't fabricate. Everything else has a sensible default (`""` for `status_text`, empty array for `headers`, `""` for `body`).

## Saving a mock — `http.save_mock`

From a Request pane that has a `Done` response:

| Surface | Call |
|---|---|
| Palette | `HTTP: save current response as a sibling .mock.json` |
| Ex-command | `:http.save_mock` |

Requirements:

- The active pane must be a `Pane::Request` (`http.save_mock: needs an active Request pane` if not).
- The pane must have a `source_path` (`http.save_mock: pane has no source file path` if you fired the request from a paste or an in-memory edit — there's no canonical sibling location).
- The response must be ready (`http.save_mock: response not ready yet` if the state is still `Sending` or `Failed`).

When all three check out, mnml writes the sibling file with the response's status, status_text, headers, body, and the current timestamp. The directory is created if missing. Existing mocks are overwritten — there's one mock per request, not a history of them.

Successful save toasts `saved mock → <path>`.

## Replaying a mock — `http.replay_mock`

```vim
:http.replay_mock
```

Or palette `HTTP: replay sibling .mock.json into the active request pane`.

Replay flips the active Request pane straight into `RunState::Done` with the mock's payload. No network call. The pane's view also flips to `Response` so you see the result immediately:

- The status line reads the mock's status + status_text.
- The headers list is the mock's headers.
- The body is rendered with the same pretty-printer the live `http.send` uses (JSON if it parses; raw otherwise).
- `elapsed` is `Duration::ZERO` (the mock didn't take any time).
- The assertions and captures arrays are empty — `@assert` and `@capture` directives are response-driven, not mock-replayed.

The pane retains its `source_path` and `source_block_name`, so `Ctrl+S` after replay still writes the *request* back to the source file. The mock is read-only; saving doesn't touch `.mock.json`.

Error cases:

- No `Pane::Request` active → `http.replay_mock: needs an active Request pane`.
- Pane has no source path → `http.replay_mock: pane has no source file path`.
- Sibling `.mock.json` is missing → `http.replay_mock: read <path>: No such file or directory`.
- Sibling is malformed JSON or missing `status` → `http.replay_mock: parse mock: …` / `http.replay_mock: mock missing status`.

## The save-then-replay loop

```text
1. Open requests/auth/login.curl
2. :http.send → real request, real response, status 401
3. :http.save_mock → writes requests/auth/login.curl.mock.json
4. Edit the UI code that handles 401
5. :http.replay_mock → instant 401 response, no network call
6. Tweak the UI, replay again, iterate
```

The mock survives across mnml restarts because it's a checked-in file. Commit `.mock.json` files for canned demo data; gitignore them when they hold session tokens or PII.

## What mocks aren't

- **A request mocker.** mnml mocks *responses you've seen*. There's no "if the URL contains `/v2/users`, serve this canned response" routing layer. You replay one mock at a time, manually, against a specific request pane.
- **A network mocker.** Replay flips the pane state without going through the HTTP send path — no `reqwest` call, no DNS, no TLS. That means it also doesn't exercise the network stack, so a mock-only test won't catch a misconfigured TLS chain.
- **A history layer.** Each save overwrites. If you want a history of past responses, that's [HTTP history](/manual/http-history/) — a separate JSONL log of every `http.send`.
- **A response template.** Mocks are static JSON. The body field is the literal bytes you got; there's no `{{var}}` substitution on replay. If you want dynamic mock data, write a helper that re-saves the mock with the substituted body.

## Mock files in CI

A useful pattern: commit a `.mock.json` next to every request file that hits a slow / paid / rate-limited endpoint. Run your tests with `mnml run` against the live endpoint when you want freshness; flip to replay during development by editing the `.test` step to load the mock instead of firing. The `.test` E2E runner doesn't know about mocks today — you'd need an explicit step that calls `:http.replay_mock` on the active pane — but the disk layout is set up for it.

## Next

- [HTTP client](/manual/http/) — the parent overview: how `http.send` builds the Request pane that mocks are saved from
- [HTTP history](/manual/http-history/) — for "every response I've ever seen" instead of "one frozen response per request"
- [HTTP captured browser traffic](/manual/http-captured/) — captured traffic is a separate file format; not directly compatible with mocks but useful for grabbing real-world response shapes
- [HTTP envs & templating](/manual/http-envs/) — `.mock.json` files don't substitute `{{VAR}}`, but the `.env` file controls what the *live* `http.send` saw before you froze it
