---
title: HTTP helpers — JWT, bearer, cookies, SSE
description: Four small palette commands — `jwt.decode`, `auth.extract_bearer`, `cookies.normalize_clipboard`, and `sse.parse_active_response`.
---

Four small palette commands that pay for themselves the first time an Authorization header or a Set-Cookie value isn't doing what you expect. Most operate on the clipboard — paste a token (or a header line, or a 401 response), run the command, get the answer as a toast or a re-written clipboard.

The point of having them in mnml: the alternative is opening `jwt.io` in a browser or pasting a token into a one-off Python script. These are one-keystroke versions of the same query, embedded next to the request files they fix.

## `jwt.decode` — inspect a token

| Surface | Call |
|---|---|
| Palette | `JWT: decode clipboard token (claims only, no signature)` |
| Ex-command | `:jwt.decode` |

Reads the clipboard, decodes the middle segment of the JWT (the claims payload), and toasts a one-line summary of the headline claims:

```text
jwt: sub=user_a1b2c3 · email=alice@example.com · exp=2026-04-15 12:00:00Z (in 7 days)
```

When the token is past its expiry, the toast appends `· EXPIRED`:

```text
jwt: sub=user_a1b2c3 · email=alice@example.com · exp=2025-11-15 12:00:00Z (expired 3 days) · EXPIRED
```

Error cases:

- Empty clipboard → `jwt.decode: clipboard is empty`.
- Not three dot-separated segments → `jwt.decode: not a valid JWT (3 dot-separated segments)`.
- Token decodes but has no standard claims → `jwt.decode: (token has no standard claims)`.

### What gets shown

The toast surfaces the four most useful claims, in order:

| Claim | Shown when present |
|---|---|
| `sub` | Subject — the user id or service principal |
| `email` | The user's email if the issuer included it |
| `exp` | Expiry, formatted as `YYYY-MM-DD HH:MM:SS Z (<relative>)` |
| `EXPIRED` | A trailing marker when `exp` is in the past |

Other claims (`iat`, `iss`, `aud`, custom fields) are decoded into `claims.raw` for callers but **not** shown in the toast. The toast surface is deliberately short — at-a-glance "is this token for the right user, and is it still valid?" — not a full JSON dump.

The relative-time formatter handles four ranges:

- Under 60 seconds → `30s`.
- Under an hour → `45m`.
- Under a day → `7 hours` (singular `1 hour`).
- A day or more → `7 days` (singular `1 day`).

Expired tokens get the `expired ` prefix, so `expired 3 hours` is unmistakable.

### What it doesn't do

- **Verify the signature.** mnml never had the signing key — this is purely a display tool for tokens you already have. The third segment of the JWT is ignored. *Don't* use `jwt.decode` to assert that a token is genuine; use it to assert what the token *says about itself*.
- **Decode encrypted (JWE) tokens.** Only signed JWTs (three base64url-encoded segments separated by `.`) are parsed. JWE tokens with five segments aren't recognized.
- **Convert local time zones.** The displayed expiry is UTC. Convert mentally or via your shell — the relative ("in 7 days") is usually what you actually wanted.
- **Modify the clipboard.** `jwt.decode` is read-only. To rewrite a token, use `auth.extract_bearer` (which copies the bare token) and paste it where you need.

## `auth.extract_bearer` — clean up a pasted token

| Surface | Call |
|---|---|
| Palette | `Auth: extract bearer token from clipboard text` |
| Ex-command | `:auth.extract_bearer` |

Reads the clipboard, pulls out the bearer token (regardless of what surrounds it), and writes the **bare token** (no `Bearer ` prefix, no header name, no quotes) back to the clipboard. Toasts a previewed version so you can confirm the extraction worked:

```text
bearer: eyJhbG…aBc8X9 (copied)
```

The preview shows the first 6 + last 6 characters of the token with an ellipsis between. Tokens shorter than 18 chars are shown in full.

### Accepted input shapes

The extractor handles every reasonable copy-paste shape:

```text
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signature   ← bare token
Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signature   ← curl/Authorization shape
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signature   ← full header line
authorization: bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signature   ← lowercased
```

The match is case-insensitive — `Bearer` / `bearer` / `BEARER` all work. The extractor looks for the substring `bearer ` (case-insensitive); whatever follows up to the next whitespace is the token. Surrounding single or double quotes are trimmed (`'eyJ…'` and `"eyJ…"` both extract cleanly).

If no `bearer` keyword is found, the extractor falls back to "treat the whole clipboard as the token" — but only when the clipboard is a single word with no whitespace. A pasted blob with spaces and newlines fails closed (`no bearer token found`).

### When extraction fails

- Empty / whitespace-only clipboard → `auth.extract_bearer: no bearer token found`.
- Multi-word clipboard with no `bearer` keyword → same toast.

The original clipboard contents are **preserved** on failure — the extractor only writes to clipboard on success.

## Why these are baked in

Both helpers operate on the same clipboard your `:term` pane uses, so they compose with the rest of the editor:

```text
1. Paste 401 response from your terminal into a buffer
2. y the Authorization header from the request
3. :auth.extract_bearer → bare token on clipboard
4. :jwt.decode → "sub=... · exp=... · EXPIRED"
5. Diagnose: token expired; rerun :http.lookup to get a fresh one
```

That diagnosis flow is the case these helpers were built for. Without them, you'd have a tab in `jwt.io`, a shell with `cut -d. -f2 | base64 -d`, or a one-off Python script — and you'd be context-switching out of the editor every time. With them, the whole loop stays in mnml.

A handful of related glue lives in `crate::auth` for power-users:

- **`replace_bearer_in_curl(curl_text, new_token)`** — rewrites the `Authorization: Bearer …` header in a curl command. Useful in a script that auto-rotates tokens across a tree of `.curl` files; not currently exposed as a palette command.

## `cookies.normalize_clipboard` — canonicalise pasted cookies

| Surface | Call |
|---|---|
| Palette | `Cookies: normalize clipboard text → canonical \`name=v; name=v\` form` |
| Ex-command | `:cookies.normalize_clipboard` |

DevTools and various paste sources give you cookies in three different shapes — none of which is the canonical Cookie-header form. The normaliser accepts any of them and rewrites the clipboard with the right shape:

```text
# Shape 1: one cookie per line
session=abc123
csrf_token=xyz789
user_pref=dark

# Shape 2: header-style with colons
Cookie: session=abc123; csrf_token=xyz789

# Shape 3: already canonical (idempotent — no change)
session=abc123; csrf_token=xyz789
```

All three normalise to:

```text
session=abc123; csrf_token=xyz789
```

Paste the output into a `Cookie:` header in your `.curl` or `.http` file. Useful when you've grabbed cookies from Chrome DevTools' Application panel and need them in a request.

A v2 enhancement would auto-fire when typing into a Cookie header value in the Request pane's Edit view — for now, it's a manual palette call.

## `sse.parse_active_response` — verify a Server-Sent Events stream

| Surface | Call |
|---|---|
| Palette | `SSE: parse active Response pane body as Server-Sent Events` |
| Ex-command | `:sse.parse_active_response` |

When an endpoint returns Server-Sent Events (`Content-Type: text/event-stream`), the Response pane just shows raw `data: …` lines — not super readable. `sse.parse_active_response` reads the body, runs it through the SSE reader, and toasts:

- The total event count.
- The first event's `event:` name (if any) and a preview of its `data:` payload.

This confirms the SSE shape is well-formed (mis-quoted JSON, missing blank-line separators, etc. all fall out in the parse) and gives you a fast read on what the endpoint actually sent.

Requirements: an active `Pane::Request` with `RunState::Done`. Otherwise the command toasts an error.

What it doesn't do: progressive display while the stream is still arriving. Today the Request pane buffers the full response before flipping to `Done`, so SSE streams that don't terminate cleanly won't render. A streaming-send mode with progressive event display is queued as a v2 follow-up.

## Next

- [HTTP client](/manual/http/) — where the tokens these helpers inspect end up (the Request pane's Authorization header)
- [HTTP envs & templating](/manual/http-envs/) — `{{TOKEN}}` is usually how you keep the bare token out of the request file
- [HTTP lookups](/manual/http-lookup/) — the natural next step after a `jwt.decode` shows the token is for the wrong subject
- [HTTP history](/manual/http-history/) — every 401 that lands here is a probable case for these helpers
