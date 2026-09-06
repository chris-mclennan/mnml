---
severity: SEV-1
status: fixed
---
# `http.send` crashes the whole process for ANY GET (or other bodyless-method) block that has trailing `# @assert` / `# @capture` directives — i.e. the documented directive syntax itself triggers it

**Surface:** `http.send`, `src/http/parse.zig` (`parseHttp`, `parse`), `src/http/client.zig`, `src/app/http.zig` worker thread.

## Repro (deterministic, reproduced 3 times across 2 fresh launches)

1. Fresh workspace, `.env` / env file with `BASE_URL=https://httpbin.org` (any live GET endpoint works, including a local mock server — this is not network-timing-dependent).
2. Write a `.http` file using the *documented* directive syntax
   (straight out of `src/http/script.zig`'s own doc comment, `# @assert`
   / `# @capture`, comment-prefixed exactly as specified) on a GET
   block:
   ```
   ### get-json
   GET {{BASE_URL}}/get
   Accept: application/json

   # @assert status == 200
   # @capture origin = body.origin
   ```
3. Launch headless:
   `MNML_DATA_ROOT=<data> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`
4. IPC:
   ```
   {"cmd":"open","path":"<ws>/requests/basic.http"}
   {"cmd":"run-command","id":"http.send"}
   ```

Also reproduces with a plain, non-directive literal body under a GET
(`GET .../get` + blank line + `some text`) — same crash, same stack —
confirming the underlying defect is generic (see Root cause), but the
*directives* case is the important one because it means the tool's own
documented `.http` script syntax (`docs`, `script.zig` header comment)
is what triggers a full crash on the single most common HTTP method.

**Expected:** A GET request with post-request `# @assert` / `# @capture`
directives sends normally — the directives are metadata, not body, and
must never become the wire body. If a body genuinely ends up set on a
method that can't carry one, the send should fail gracefully (`Outcome.err`
with a clear message) rather than crash.

**Actual:** The Request pane sticks on `sending…` forever, then the
*entire mnml-zig process dies*. Confirmed via `ps -p <pid>` returning
empty immediately after the panic appears in stderr, in both launches
this session. All further IPC is unanswered — not a pane-local
failure, a total crash of the terminal IDE.

## Stack trace (identical across all 3 repros)

```
thread <n> panic: reached unreachable code
.../std/debug.zig:420:14: in assert
    if (!ok) unreachable; // assertion failure
.../std/http/Client.zig:949:15: in sendBodyUnflushed
        assert(r.method.requestHasBody());
src/http/client.zig:261:47: in sendInner
        var bw = try request.sendBodyUnflushed(&.{});
src/http/client.zig:188:21: in send
    return sendInner(gpa, io, req, opts) catch |err| switch (err) {
src/app/http.zig:839:30: in worker
    var outcome = client.send(gpa, io, &job.req, .{ .cookie = job.cookie, .stream = sink }) catch {
```

## Root cause — two independent bugs compound

1. **`parseHttp()` in `src/http/parse.zig` (~line 622-636) never
   distinguishes `# @directive` comment lines from real body content
   once past the header section's blank-line boundary.** It correctly
   skips `#`/`//` comment lines *while still in the headers loop*
   (line 628: `if (t[0] == '#' or startsWith(t, "//")) continue;`), but
   the moment a blank line flips `in_headers = false` and sets
   `body_start`, there is no further per-line filtering at all — every
   subsequent line, comment or not, becomes part of `text[body_start..]`
   and thus `req.body`. Any directive placed after the blank line
   (which is exactly where `docs`/`script.zig`'s own examples put
   `# @assert` / `# @capture` — *after* the request, to assert on the
   response) ends up baked verbatim into the body.

2. **The outer `parse()` (line 226-242) papers over this only partially.**
   It separately extracts directive lines into `req.script` via
   `script_mod.directiveLines(...)` for the *scripting* engine to run —
   but it never strips those same lines back out of `req.body`, which
   `parseHttp()` already populated. So `req.script` and `req.body` both
   end up holding the directive text; the pollution survives into the
   `Request` that reaches the network layer.

3. **`sendInner()` in `src/http/client.zig` (line 259-267) has no guard
   for method vs. body-capability.** It branches only on `if (req.body)
   |body|`, and calls `request.sendBodyUnflushed(...)` unconditionally.
   Zig's std lib asserts `method.requestHasBody()` inside that call, so
   any bodyless-by-spec method (GET confirmed; HEAD / DELETE / OPTIONS /
   TRACE share the same `requestHasBody()` check and are highly likely
   to hit the same `unreachable`, though not independently re-fired
   this session) crashes the process the instant a body is present.

Fixing only #3 (guard on `requestHasBody()`, fail gracefully instead)
would stop the crash but a `# @assert` block would still silently ship
its directive text as the request body over the wire on methods that
*do* accept a body (POST/PUT/PATCH) — a correctness bug of its own,
separate from the crash. Fixing #1/#2 (strip directive lines from body
before `Request` leaves the parser) is the real fix; #3 is the
defense-in-depth guard against the next occurrence of the same class
of bug.

## Also crashes the headless CLI (`mnml-zig run FILE`), not just the TUI

```
$ mnml-zig run requests/getbody.http --env dev
thread <n> panic: reached unreachable code
.../std/http/Client.zig:949:15: in sendBodyUnflushed
src/http/client.zig:261:47: in sendInner
src/http/client.zig:188:21: in send
src/http/cli.zig:125:34: in run
    var outcome = try client.send(a, io, &req, .{});
src/main.zig:196:21: in httpSubcommand
src/main.zig:40:42: in main
```
Exit code **134 (SIGABRT)**. Any CI pipeline or script using
`mnml-zig run` as the headless HTTP runner will hard-abort on this
input with no `mnml-zig`-level error message — just a raw Zig panic
dump on stderr. Confirmed with a background process + `kill -0` poll
(process was gone, exit 134, well before any network timeout could
explain it).

## Notes

- Reproduced 3 times total in the TUI: 2 fresh launches, one with directives after
  a GET (as `basic.http`'s documented-syntax scenario), one with a
  plain literal body after a GET (`getbody.http`, no directives
  involved) — both hit the identical panic location, confirming bug #3
  is generic and bugs #1/#2 are what feed it in the directive case.
- Every `ps -p <pid>` check after a panic came back empty within ~1s —
  this is a full process death, not a hung/zombie thread.
- Not independently re-fired: HEAD / DELETE / OPTIONS / TRACE + body
  (same code path as GET, so very likely, but only GET was actually
  driven through the crash this session).

## Fix

Fixed in two commits on `fix-http-parse`:

- `fd4fae7` — `http: directive lines are never body bytes`. `parseHttp`
  cuts `# @…` / `// @…` lines out of the body region wherever they sit,
  so a GET with trailing directives has no body (bug #1 / #2 above).
- `94beb18` — `http: follow redirects by hand; a body on GET never
  reaches std's assert`. `sendInner` guards on `method.requestHasBody()`:
  a body on GET / HEAD / DELETE / OPTIONS / TRACE goes out with its
  `content-length`, the bytes written past `sendBodilessUnflushed` —
  what curl and reqwest (Rust mnml) send. The mirror (a POST with no
  body hit `sendBodiless`'s assert) is `content-length: 0`. No user
  input reaches a std assert from `http.send`, `mnml-zig run` or
  `chain run`.

Tests: `parse.zig` "directives after the body boundary are script, never
body: a GET keeps no body"; `client.zig` "send: a body on a bodyless
method never reaches std's assert …" (four methods + the bodyless POST)
and "send: thirty malformed blocks parse and go out (or fail soft); none
aborts"; `cli.zig` "run: a GET with trailing directives goes out without
a body …" (was exit 134); `app/http.zig` "send: a GET with trailing
directives sends no body …"; `tests/e2e-zig/http_directives_not_body.test`.
