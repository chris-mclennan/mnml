---
title: HTTP captured browser traffic
description: Every request the in-app browser pane sees is auto-appended to `.rqst/captured/log.jsonl` — review past traffic, re-fire any entry as a `.curl` buffer, or run headless via `mnml proxy`.
---

![mnml proxy --url news.ycombinator.com streams per-request log lines, then :http.view_captured opens the picker over the resulting captures](../../../assets/tapes/http-captured-proxy.gif)

When the in-app Browser pane is open, every `Network.requestWillBeSent` event Chrome forwards is appended to `<workspace>/.rqst/captured/log.jsonl` — a separate JSONL log from the [HTTP history](/manual/http-history/), capturing *what the browser saw* rather than *what mnml fired*. The picker (`:http.view_captured`) lets you browse the log, filter, and re-fire any captured request as a fresh `.curl` buffer.

Same data shape, two ways in: the live browser pane (auto-capture is on by default), and the headless CLI (`mnml proxy --url URL`) which spawns Chrome, drives it to a URL, and appends every observed request to the same log without ever rendering a UI.

## The file

```text
<workspace>/.rqst/captured/log.jsonl
```

One JSON object per line, written by the CDP message handler when the browser pane sees a `Network.requestWillBeSent`. The file is shared between the live capture path (auto-capture, `:http.capture_now`) and the headless path (`mnml proxy`) — they all use the same `CapturedRow` schema:

```json
{"at":1734652803123,"request_id":"82.5","method":"GET","url":"https://api.example.com/v2/users","headers":[["user-agent","Mozilla/5.0..."],["accept","application/json"]],"body":null,"paused":false}
{"at":1734652803567,"request_id":"82.6","method":"POST","url":"https://api.example.com/v2/orders","headers":[["content-type","application/json"]],"body":"{\"sku\":\"A1\"}","paused":false}
```

Schema:

| Field | Type | What |
|---|---|---|
| `at` | u64 millis | When the request was captured (mnml's wall clock, not Chrome's) |
| `request_id` | string | Chrome's CDP request id; accepts the alias `requestId` for HAR / camelCase imports |
| `method` | string | HTTP method |
| `url` | string | Full URL — query string and fragment included |
| `headers` | array of `[name, value]` | Request headers; HTTP/2 pseudo-headers (`:authority`, `:method`, …) are kept on disk but stripped when rendered as curl |
| `body` | string / null | Request body when present (CDP's `postData`); base64 if Chrome encoded it |
| `paused` | bool | Reserved for future Fetch-domain pause/edit/continue; always `false` today |

Empty lines and lines that fail to parse are skipped silently (so a future field addition doesn't break the loader). The file grows append-only; no rotation.

## Auto-capture from the browser pane

When the Browser pane is open and the page loads, every CDP `Network.requestWillBeSent` for an "interesting" resource type (XHR, fetch, document, script, stylesheet — not images / fonts / media) is fanned out to two destinations:

1. The pane's in-memory `net` list (the right-half network panel, transient — cleared when the pane closes).
2. The on-disk `.rqst/captured/log.jsonl` (persistent across sessions).

The on-disk write is gated by `[browser] autocapture_to_log = true` (default on). Toggle at runtime with:

```vim
:browser.autocapture_toggle
```

Or in your config:

```toml
[browser]
autocapture_to_log = false
```

When auto-capture is off, *only* explicit `:http.capture_now` calls write to the log. The in-memory network panel is unaffected — you can still see live traffic in the pane.

The CDP handler skips write failures silently (a full disk shouldn't poison the browser session). Per-session log dirs are created on demand.

## Manual capture — `:http.capture_now`

Even with auto-capture off, you can flush the browser pane's current network list into the log on demand:

| Surface | Call |
|---|---|
| Palette | `HTTP: append browser pane network entries → captured log` |
| Ex-command | `:http.capture_now` |

Requirements: an active `Pane::Browser`. Otherwise `http.capture_now: needs an active browser pane`.

What gets written:

- Every entry currently in the browser pane's `net` list (including ones that auto-capture already wrote — `capture_now` doesn't dedupe).
- Each row is stamped with `at = <now>` (not the original CDP timestamp), the browser's `request_id`, method, URL, headers, and post-data.

Toasts: `http.capture_now: wrote N/M entries to <path>`. The numerator counts what serialised cleanly; the denominator is the pane's full list. `0 entries yet` if the pane hasn't seen any traffic.

Useful when you've turned auto-capture off (for privacy / log size) but want to grab the current page's traffic as a one-shot.

## The picker — `:http.view_captured`

| Surface | Call |
|---|---|
| Palette | `HTTP: open .rqst/captured/log.jsonl (captured browser traffic)` |
| Ex-command | `:http.view_captured` |

The picker loads every row from `.rqst/captured/log.jsonl` (not just the last 100, unlike [history](/manual/http-history/) — captured logs tend to be longer-lived).

```text
Captured requests
  ▸ GET    api.example.com/v2/users
    POST   api.example.com/v2/orders                   (body: 32 bytes)
    GET    cdn.example.com/static/app.js
    POST   api.example.com/v2/auth/refresh             (body: 84 bytes)
```

Display:

- **Method** (right-padded).
- **Short URL** — host + path, scheme stripped, query stripped.
- **Body marker** — `(body: N bytes)` when the request had a body; blank otherwise.

Fuzzy filter narrows by method, URL, or body marker. Type `POST` to find every POST; type a hostname to scope to one service.

### Re-firing — `Enter`

`Enter` renders the chosen row as a `.curl` command (via `CapturedRow::to_curl`) and opens it in a fresh scratch buffer. The curl includes:

- `curl -X METHOD 'URL'` (or `curl 'URL'` for GET — letting curl infer the verb).
- `-H 'name: value'` per header, with single-quoting and POSIX-safe escaping (`'` becomes `'\''`).
- `--data-raw '<body>'` when the request had a body.
- HTTP/2 pseudo-headers (`:authority`, `:method`, `:path`, `:scheme`) are stripped — they're framing, not real headers.

The scratch buffer is editable, sendable (`:http.send`), and saveable. Re-firing through mnml means the request goes through the normal env / templating pass — paste a captured login request, swap the hardcoded token for `{{TOKEN}}`, and you've extracted a reusable `.curl` file from real traffic.

## Headless capture — `mnml proxy`

The browser pane is the interactive surface. `mnml proxy` is the same capture path without a UI — useful for "drive Chrome to a URL, capture every request, exit":

```bash
mnml proxy --url https://app.example.com/dashboard
mnml proxy --url https://app.example.com --workspace ~/code/api --seconds 60
mnml proxy --url https://app.example.com --idle-ms 5000 --quiet
```

| Flag | What | Default |
|---|---|---|
| `--url URL` | The page to load (required) | — |
| `--workspace DIR` / `-w DIR` | Where `.rqst/captured/log.jsonl` lands | current directory |
| `--seconds N` | Hard timeout; capture exits after N seconds regardless of activity | no cap |
| `--idle-ms N` | Stop after this many milliseconds without a new network event | 2000 |
| `--quiet` | Suppress the per-request progress lines on stderr | verbose |

How the run terminates (any of the three exits the loop):

1. **Hard timeout** — `--seconds` elapsed since spawn.
2. **Quiescence** — no `Network.requestWillBeSent` for `--idle-ms` milliseconds *and* at least one request was already captured (so a slow-to-start page gets a chance).
3. **Session closed** — Chrome exited or the WebSocket dropped.

The output is the same `CapturedRow` JSONL the browser pane writes. Headless Chrome runs with a throwaway `--user-data-dir` (cleaned up on exit) so cached cookies / login state from a prior run don't leak.

Useful from CI: load a page in headless mode, capture every API call the JS bundle made, jq the log for endpoints you expected, fail the build if any are missing.

```bash
$ mnml proxy --url https://staging-app.example.com/checkout --seconds 30
mnml proxy: attached to ws://127.0.0.1:9222/devtools/page/A1B2…
  GET https://staging-app.example.com/checkout
  GET https://staging-cdn.example.com/static/app.f8a2.js
  POST https://staging-api.example.com/v2/cart/validate
  GET https://staging-api.example.com/v2/shipping/options?zip=...
mnml proxy: idle for 2000ms, stopping (4 captured)
ok — 4 requests captured
```

What `mnml proxy` does **not** do today:

- **Pause / edit / continue.** Chrome's Fetch domain (which would let you intercept and rewrite outgoing requests) isn't wired. The CDP session enables `Network.enable` only — observation, not mutation. The `paused` field in `CapturedRow` exists as a forward-compat slot for that future feature.
- **Response capture.** Only the request side is logged; bodies the server returns aren't recorded. For full request + response, use a real proxy (`mitmproxy`, `Charles`); `mnml proxy` is a lightweight "what did the JS hit?" snapshot.
- **Authentication.** No way to pre-warm the headless Chrome with cookies / credentials. The fresh profile starts logged out. A future flag (`--user-data-dir`) is the natural place to plug that in.

## Where captured fits

Three sibling logs in `<workspace>/.rqst/`:

| Log | Source | Records what |
|---|---|---|
| **`history.jsonl`** | Every `http.send` | Requests mnml *fired* |
| **`captured/log.jsonl`** | Browser pane (auto) + `:http.capture_now` + `mnml proxy` | Requests Chrome *observed* |
| **`<source>.mock.json`** | `:http.save_mock` | One frozen *response* per request file |

Auto-capture means a workspace that uses the browser pane regularly will accumulate captured/log.jsonl entries silently. That's the design — it's a free record of what your app does at the network layer. If you don't want it, flip `[browser] autocapture_to_log = false` (or `:browser.autocapture_toggle` at runtime).

## Next

- [HTTP client](/manual/http/) — the parent overview
- [HTTP history](/manual/http-history/) — for what mnml *fired*, distinct from what the browser *saw*
- [HTTP mocks](/manual/http-mocks/) — freeze a response so you can iterate offline
- [HTTP envs & templating](/manual/http-envs/) — when you re-fire a captured request through `http.send`, the env applies
- [Configuration](/reference/configuration/) — `[browser] autocapture_to_log` and the rest of the browser-pane config
