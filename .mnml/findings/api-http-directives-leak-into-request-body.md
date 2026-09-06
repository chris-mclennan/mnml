---
severity: SEV-1
status: fixed
---
# `# @assert` / `# @capture` post-request directives are silently appended to the actual request body sent over the wire

**Surface:** `http.send`, `src/http/parse.zig` (`parseHttp`), `src/http/script.zig`.

## Repro (deterministic, confirmed against real httpbin.org)

1. Env: `BASE_URL=https://httpbin.org`.
2. `.http` block using the documented post-request directive syntax:
   ```
   ### post-json
   POST {{BASE_URL}}/post
   Content-Type: application/json

   {
     "hello": "world",
     "token": "{{$uuid}}"
   }

   # @assert status == 200
   # @capture origin = body.json.hello
   ```
3. `{"cmd":"run-command","id":"http.send"}` (block focused).

**Expected:** The wire body is exactly the JSON object; `# @assert` /
`# @capture` lines are metadata consumed by mnml-zig's own script
engine and never appear in bytes sent to the server. httpbin (which
echoes the parsed body back as `"json"`) should show the object back,
not `null`.

**Actual:** The response comes back with `"json": null` and
`Content-Length: 134` — far larger than the ~62-byte JSON object —
because the literal text
```
# @assert status == 200
# @capture origin = body.json.hello
```
was appended after the closing `}` of the JSON body, before being sent.
httpbin's JSON decoder chokes on the trailing garbage and reports
`"json": null` (visible directly in the Response pane body,
`view screen.txt` around the send). This means **every POST / PUT /
PATCH request that uses the documented `# @assert` / `# @capture`
directive syntax silently ships a corrupted body** to any real API —
JSON, form, or otherwise — that does strict body parsing. The tool's
own `✓ status == 200` assert row still shows green (status codes are
unaffected), masking the corruption entirely from the user; only a
capture that depends on the (now-broken) response body silently fails
too.

For a bodyless method (GET/HEAD/DELETE/...) the same leak crashes the
whole process instead of just corrupting the body — filed separately
as `api-http-send-get-with-body-crashes-process.md`. This finding is
the body-having-method half of the same root cause; it's just as
important because it produces *silent, wrong-network-traffic* rather
than a loud crash, and will not be noticed without inspecting bytes on
the wire.

## Root cause

Same as `api-http-send-get-with-body-crashes-process.md`'s bugs #1/#2:
`parseHttp()` in `src/http/parse.zig` stops filtering `#`/`//` comment
lines the instant the header section's blank line is crossed
(`in_headers = false; body_start = offset;` around line 622-636) — from
that point every line, directive or not, is folded verbatim into
`req.body`. The outer `parse()` (line 226-242) extracts the same
directive lines into `req.script` for the scripting engine, but never
removes them from `req.body`, so the corrupted body still reaches
`src/http/client.zig`'s `sendInner()` and goes out on the wire exactly
as typed in the source file.

## Suggested fix

`parseHttp()` (or the outer `parse()`, after it already knows which
lines are directives via `script_mod.directiveLines`) must strip
`# @...` directive lines out of the body region before `req.body` is
finalized — not just copy them into `req.script` alongside a body that
still contains them.

## Notes

- Verified via real network round-trip against `https://httpbin.org/post`
  (not a mock), so this reflects exactly what a real API would receive.
- `Content-Length: 134` in the request headers echoed back by httpbin
  confirms the extra ~58 bytes (`# @assert status == 200\n# @capture
  origin = body.json.hello\n`) were physically part of the sent body,
  not a display-only artifact.

## Fix

Fixed in `fd4fae7` — `http: directive lines are never body bytes`
(branch `fix-http-parse`). `parseHttp` now filters the body region:
a `# @…` / `// @…` line is a directive wherever it sits in the block
and is cut before `req.body` is set; every other byte after the
boundary is body verbatim, CR included, so a JSON body is
byte-identical to the source. Plain `#` / `//` comment lines after the
boundary stay body, as in Rust mnml (`parse_block` pushes every line
past the blank line) — the departure from Rust is for directive lines
only.

Tests: `parse.zig` "directives after a POST body: the body is
byte-identical to the JSON, the directives are script" (directives
before, after, CRLF, a body of only directives, a plain comment kept);
thirty malformed shapes; a `std.testing.fuzz` over `parse`; `cli.zig`
"run: … a POST's body is the JSON alone" checks `content-length` and
the bytes on the wire; `tests/e2e-zig/http_directives_not_body.test`
checks the Body tab.
