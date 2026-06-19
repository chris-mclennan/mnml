---
title: HTTP history
description: Every `:http.send` is appended to `.rqst/history.jsonl` — picker browse + re-fire any past request from a scratch `.curl` buffer.
---

mnml appends every completed HTTP send to `<workspace>/.rqst/history.jsonl` — one JSON line per request, OK or error, status or transport failure. It's a per-workspace forensic log: grep it from the shell, jq it for slow requests, or open the in-app picker (`:http.history`) and re-fire any of the last 100 with one Enter.

The point: when you fired something interesting an hour ago and now you can't remember the exact URL parameters, the answer is there. Same when a 401 from earlier wasn't actually transient and you want to re-run it post-fix.

## The file

```text
<workspace>/.rqst/history.jsonl
```

One line per request, JSON-encoded, appended by `drain_http_jobs` after every `http.send` completes (success or failure). The file is created on first append; missing directory is created automatically.

```json
{"ts":1734652803123,"method":"POST","url":"https://api.example.com/users/42","status":401,"duration_ms":142,"body_bytes":98,"error":null}
{"ts":1734652811876,"method":"GET","url":"https://api.example.com/users","status":200,"duration_ms":56,"body_bytes":2148,"error":null}
{"ts":1734652815001,"method":"GET","url":"https://broken-host.example.com/","status":null,"duration_ms":null,"body_bytes":null,"error":"connection failed: dns error"}
```

Schema:

| Field | Type | When null |
|---|---|---|
| `ts` | u64 millis | always present |
| `method` | string | always present |
| `url` | string | always present |
| `status` | u16 / null | null when the request errored before the response landed (transport / DNS / TLS) |
| `duration_ms` | u128 / null | null when the request errored before timing was meaningful |
| `body_bytes` | usize / null | null on error; size of the response body otherwise |
| `error` | string / null | one-line transport error message when present; null on success |

`status: null` with `error: "…"` is the transport-failure shape. `status: 401` with `error: null` is "the request completed, the server said 401" — a successful send to the HTTP layer, regardless of what the status means semantically.

Appends are append-mode `open + write`. POSIX guarantees atomic appends for writes under `PIPE_BUF` (4 KB on Linux/macOS); every entry mnml writes is well under that, so concurrent writers (two mnml instances in the same workspace) interleave at line boundaries without corruption.

The log grows forever — there's no rotation. For most workspaces this is fine; a few hundred entries a day is a few hundred KB a month. If you want to trim, truncate `history.jsonl` from the shell — mnml will start appending again on the next send.

## Forensic queries from the shell

The file is intentionally JSONL so it's grep-able and jq-able without leaving the terminal:

```bash
# Every 401 today.
grep '"status":401' .rqst/history.jsonl | jq -c '{ts, url}'

# Anything slower than 1 second.
jq -c 'select(.duration_ms > 1000)' .rqst/history.jsonl

# Every failed send.
jq -c 'select(.error != null) | {ts, url, error}' .rqst/history.jsonl

# Histogram of status codes from the last 50 sends.
tail -50 .rqst/history.jsonl | jq '.status' | sort | uniq -c | sort -rn

# Find the 5 slowest requests this week.
jq -c 'select(.ts > (now - 86400 * 7) * 1000)
     | {url, duration_ms}' .rqst/history.jsonl \
  | sort -t: -k3 -n -r | head -5
```

The `ts` field is milliseconds since Unix epoch — `(.ts / 1000) | strftime("%Y-%m-%d %H:%M")` formats it in jq if you want human-readable dates.

## The picker — `:http.history`

In the editor:

| Surface | Call |
|---|---|
| Palette | `HTTP: open .rqst/history.jsonl (one-line-per-send log)` |
| Ex-command | `:http.history` |

No default keybinding. Bind it under `[keys.global]` or call it from the palette.

The picker loads the **last 100** entries (newest first) and renders them as fuzzy-pickable rows:

```text
HTTP history
  ▸ GET    api.example.com/users                       200 · 56ms
    POST   api.example.com/users/42                    401 · 142ms
    GET    broken-host.example.com/                    FAILED · -
    PUT    api.example.com/orders/abc                  204 · 89ms
    GET    api.example.com/users?role=admin            200 · 412ms
```

The display format:

- **Method** (right-padded to 6 chars).
- **Short URL** — host + path, scheme stripped, query string stripped.
- **Status · duration** — `200 · 56ms` on success, `FAILED · -` when both status and duration are null, `200` alone when duration is missing, `FAILED · 142ms` when only the duration is present.

Type to filter — the fuzzy match runs over `method` + short URL + the status detail. So `401` narrows to authentication failures; `users/42` narrows to that endpoint.

### Re-firing — `Enter`

Pressing Enter on a row opens a fresh **scratch `.curl` buffer** with the chosen request rendered as a curl command. The buffer is unsaved and unnamed — perfect for tweaking the URL or headers before `:http.send`-ing it again. You can also `Ctrl+S` to save it under a new path if it's worth keeping.

The re-fire happens at the source-buffer level, not as a direct `http.send` — that's deliberate. The history log records the URL that was actually fired, with `{{VAR}}` already substituted; the scratch buffer holds the resolved form. If the original used `{{TOKEN}}`, re-firing from history doesn't re-resolve against the current env — it uses the same baked-in token the original send did. To restore env-driven behavior, edit the buffer to re-introduce the `{{TOKEN}}` placeholder before sending.

The 100-entry cap on the picker is a UI choice, not a data limit — the file still holds every entry. For older entries, grep / jq directly.

## When entries land

A history entry is written from `App::drain_http_jobs` after a background HTTP worker finishes:

- **Success path** (`Ok(ResponseView)`) — `status: Some(status_code)`, `duration_ms: Some(elapsed.as_millis())`, `body_bytes: Some(body.len())`, `error: None`. The pane flips to `RunState::Done` and the entry lands.
- **Failure path** (`Err(transport_error)`) — `status: None`, `duration_ms: None`, `body_bytes: None`, `error: Some(message)`. The pane flips to `RunState::Failed` and the entry still lands — failed sends matter for forensics.

What's *not* logged:

- **`http.bench` runs.** A 10-shot bench would write 10 entries per call and bloat the file. Bench results go to the clipboard instead — see [HTTP bench](/manual/http-bench/).
- **`http.replay_mock` calls.** Replay flips the pane state without firing; nothing crossed the network, nothing gets logged.
- **`http.lookup` background fires.** The lookup flow's "stage 2" background send is also unlogged — it's an internal request used to populate the item picker, not a user-fired send.
- **Browser pane network entries.** CDP-captured requests are *browsing*, not sending — they go to `.rqst/captured/log.jsonl`, the captured browser log. See [HTTP captured](/manual/http-captured/).

## Where history fits

History is the "what did I send and when?" log. Three sibling concepts:

| Concept | File | Records what |
|---|---|---|
| **History** | `.rqst/history.jsonl` | Every `http.send` (success + failure) |
| **Captured** | `.rqst/captured/log.jsonl` | Every Network.requestWillBeSent the browser pane observed |
| **Mocks** | `<source>.curl.mock.json` | One frozen response per request file |

They don't fight — they're observational logs at three different layers. The same URL can show up in history (because you `http.send`-d it) and in captured (because you also opened the browser pane and the page loaded it).

## Next

- [HTTP client](/manual/http/) — the parent overview: how a send produces the entry that lands here
- [HTTP bench](/manual/http-bench/) — explicitly *not* logged here; bench output is clipboard-only
- [HTTP captured browser traffic](/manual/http-captured/) — the browser-pane equivalent: CDP-observed requests in their own JSONL
- [HTTP envs & templating](/manual/http-envs/) — the substitutions that ran before the request was logged
