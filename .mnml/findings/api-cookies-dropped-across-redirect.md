---
severity: SEV-2
status: fixed
---
# `Set-Cookie` from a redirecting response (e.g. the canonical `/cookies/set` pattern) never reaches the cookie jar

**Surface:** `http.send`, `cookies.show`, `src/http/client.zig`.

## Repro (deterministic, reproduced against real httpbin.org and confirmed root cause with a local non-redirecting mock)

1. Env `BASE_URL=https://httpbin.org`.
2. `.http` file:
   ```
   GET {{BASE_URL}}/cookies/set?session=abc123&user=chris
   ```
3. `{"cmd":"run-command","id":"http.send"}` — response comes back
   `200 OK` with body `{"cookies": {}}` (httpbin redirects
   `/cookies/set` → `/cookies`, so the body reflects the follow-up GET,
   not the redirect response that actually carried `Set-Cookie`).
4. `{"cmd":"run-command","id":"cookies.show"}` → jar shows
   `(jar is empty — :http.send accumulates from Set-Cookie)`.

**Control (proves the jar mechanism itself is fine):** the exact same
flow against a local server that sets a cookie *without* a redirect
(`GET http://127.0.0.1:8935/set-cookie` → `200` + `Set-Cookie:
mocksession=xyz`) correctly populates the jar
(`127.0.0.1 · mocksession · xyz`, 1 total) — so the jar/parsing code
(`Response.setCookies` in `src/http/client.zig`) is not the problem;
the `Set-Cookie` header from a *redirected* response never reaches it.

**Expected:** cookies set on any leg of a redirect chain (the
textbook `/cookies/set` shape used across virtually every HTTP test
suite, including this task's own worked example) land in the jar,
same as a direct 200 with `Set-Cookie`.

**Actual:** they are silently dropped. No toast, no indication in the
Response pane that a redirect happened and a `Set-Cookie` header was
lost along the way — the user just sees an unexpectedly empty jar.

## Root cause

`src/http/client.zig` `sendInner()` passes
`.redirect_behavior = if (req.body == null) @enumFromInt(5) else .unhandled`
to `client.request(...)`. For bodyless requests (`@enumFromInt(5)`,
i.e. Zig std's "follow every redirect automatically" behavior), the
`std.http.Client.Request` transparently issues the follow-up request
and returns only the *final* response to caller code. Any `Set-Cookie`
header on an intermediate redirect response is consumed internally by
the std lib and never surfaces in `response.head` / `response.headers`
that `sendInner` sees — so `Response.setCookies()` (line ~120) has
nothing to extract from by the time mnml-zig's own code runs.

## Suggested fix directions

- Switch bodyless requests to `.unhandled` redirect behavior (same as
  the body-having branch) and implement redirect-following in
  `sendInner` itself, collecting `Set-Cookie` from every leg before
  issuing the next request — mirroring what curl / browsers do.
- Or, at minimum, surface a toast/diagnostic when a redirect was
  followed and a `Set-Cookie` header was present on a non-final leg,
  so the silent drop is visible instead of just "the jar is empty" with
  no explanation.

## Notes

- Not a crash; a silent functional gap. Filed SEV-2 because "the
  `/cookies/set` round trip" is an explicitly-named workflow to
  validate and it fails end-to-end with no error surfaced anywhere.
- The jar's own show / delete / persist / clear commands all work
  correctly once a cookie is actually captured (verified separately —
  `cookies.persist` wrote `.mnml/cookies.json` correctly, `cookies.delete`
  opened a working picker over the one captured cookie).

## Fix

Fixed in `94beb18` — `http: follow redirects by hand; a body on GET
never reaches std's assert` (branch `fix-http-parse`). `sendInner`
sends with `.redirect_behavior = .unhandled` and runs the hops itself:
each hop's `Set-Cookie` lands on the response as a `HopCookie` keyed by
the hop's host (`Response.hop_cookies`, also on `HeadInfo` /
`StreamChunk.head` for a streamed send), and `afterResponse` records
them in the jar before the final response's own. `Location` resolves
against the hop; 303, and 301 / 302 on POST, become GET without the
body; 307 / 308 resend it; ten hops is the cap. A cookie a hop sets
rides to the next hop on the same host; a hop to another host carries
neither the jar's cookie nor `Authorization`.

Tests: `client.zig` "send: redirects are followed by hand, so a 302's
Set-Cookie reaches the jar …" (302 + two `Set-Cookie` then 200, the jar
holds both, the second hop carried them), "send: 303 and a 301/302 on
POST rewrite to GET …; ten hops is the cap", "send: a redirect to
another host drops the jar's cookie and the Authorization header";
`app/http.zig` "send: a GET with trailing directives sends no body, and
a 302's Set-Cookie lands in the jar" (through `http.send`, the jar file
written).
