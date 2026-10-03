# The mnml API

Each running mnml serves one local socket. `mnml remote` is its shell
client; anything that can write a line of JSON to a Unix socket
(`nc -U`, `socat`) is another. The design, and what comes after this
first set of methods, is `docs/research/api-design.md`; this page is what
ships.

## The socket

One AF_UNIX stream socket per instance, on macOS, Linux and Windows:

| OS | directory (0700) |
|---|---|
| macOS | `$TMPDIR/<prefix><user>.api/` |
| Linux | `$XDG_RUNTIME_DIR/<prefix><user>.api/`, else `$TMPDIR`, else `/tmp` |
| Windows | `%LOCALAPPDATA%\<prefix><user>.api\` |

`<prefix>` is the running-instance marker's (`mnml-zig-running-` for a
`run.sh` build, `mnml-running-` for an installed one), so the two never
find each other. In the directory, per instance: `<pid>.sock` (0600) and
`<pid>.zon`, the instance's marker:

```zig
.{ .pid = 4242, .version = "0.3.2", .workspace = "/path/to/ws",
   .roots = .{"/path/to/ws"}, .socket = "/…/4242.sock",
   .started_ms = 1759400000000, .frames = 1 }
```

Written at start, removed on exit. A socket path too long for a
`sockaddr_un` falls back to a short `/tmp/mnml-broker-api-<hash>.sock`, the
broker's rule; the marker always names the real path. `MNML_API_DIR`
names the directory outright. A `--sandbox` run keeps both under its
sandbox directory, so nothing outside it finds the instance. The headless
loop binds nothing. `.api.enabled = false` (Settings → Integrations →
**API**) binds nothing either.

## The protocol

One JSON-RPC 2.0 object per line (NDJSON, UTF-8), one reply line per
request, in order. A line over 16 MiB is dropped with an error.
`initialize` comes first on every connection.

| method | params | result | who may call it |
|---|---|---|---|
| `initialize` | `{token?}` | `{version:"v1", protocol:"mnml/1", instance, workspace, identity}` | anyone |
| `ping` | — | `"pong"` | anyone |
| `state.status` | — | what `status.json` carries | anyone |
| `commands.list` | — | `[{id, title, group, effect}]` | anyone |
| `layout.panes` | — | `[{pane, kind, title, active, dirty, preview}]` | a pane |
| `editor.open` | `{path, line?, col?}` | `{pane}` — opened in the active pane's place | a pane |
| `commands.run` | `{id}` | `{ok:true}` | a pane; above `view`, it asks you |

Errors: `-32601` no such method, `-32602` bad params, `-32600` no
`initialize` yet, `-32000` the command ran and failed, `-32001` not
permitted, `-32002` you said no (or nobody answered in two minutes),
`-32003` no such command or path.

```console
$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"ping"}' | nc -U "$MNML_API"
```

## Who is calling: the pane's token

Every terminal pane's child is told two things beside `MNML_PANE` and
`MNML_WORKSPACE`:

- `MNML_API` — the socket's path;
- `MNML_API_TOKEN` — 128 random bits, made when the pane starts, kept only
  in mnml's memory and that environment, and dropped when the pane closes.
  A restarted pane gets a new one.

A connection whose `initialize` presents the token is that pane —
`pane:<id>` on the audit trail and in the prompt, with the pane's title.
Anything it starts (`make`, a test runner, a session's tools) inherits the
pair and acts as that pane. A connection with no token, or a wrong one, is
`unknown`: it may call `state.status`, `commands.list` and `ping`, and
nothing else.

A pane's `commands.run` of a `view` command runs at once. Anything above
that — `edit`, `write`, `exec`, listed per command in `docs/commands.md` —
raises the same toast the file channel does (`pane 4 · zsh asks to run
git.commit (write)`, with **Review**), and the request waits for your
answer. *Allow for the session* covers that class for that pane until it
closes; a pane closing denies what it was waiting on. `.api.allow_commands`
and a `.api.clients` row named `pane:<id>` let things through unasked
(`docs/CONFIG.md`, "Commands a program asks for"). Every decision is a
line in `.mnml/ipc/audit.jsonl`.

## `mnml remote`

```
mnml remote open PATH[:LINE[:COL]]     # also: mnml r …
mnml remote run COMMAND-ID
mnml remote status | panes | ping | instances
mnml remote call METHOD [JSON]
```

Flags: `--json` prints the result object verbatim; `--instance PID` and
`--workspace PATH` pick an instance.

Which instance, first match:

1. `MNML_API` in the environment — set in every pane, so a command run in
   a pane reaches the mnml it runs in, with that pane's token;
2. `--instance PID`, `--workspace PATH`;
3. the instance whose root is the longest one containing the current
   directory;
4. the only one running.

Otherwise it exits 3 and lists the candidates (`pid  workspace  started`).
A marker whose socket refuses a connection and whose process is gone is
removed by whoever finds it.

| exit | meaning |
|---|---|
| 0 | done |
| 1 | the method failed (no such command, …) — the reason on stderr |
| 2 | usage |
| 3 | no mnml found, or several and none matched |
| 4 | not permitted (no pane token, or the API is off) |
| 5 | you said no, or nobody answered in two minutes |
| 7 | protocol mismatch (an mnml that does not speak `v1`, or no such method) |

`tools/api-bench.sh` times 200 `ping`s through `mnml remote`.
