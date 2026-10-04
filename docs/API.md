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

## Agent face: Claude Code's IDE protocol

A Claude Code session started in an mnml pane links to mnml as its IDE
with nothing to set up. The protocol is the one Claude Code speaks to its
editor plugins; `coder/claudecode.nvim`'s `PROTOCOL.md` describes it.

**When.** A terminal pane whose command is Claude Code
(`launch_profiles.productOfArgv`), spawned while the API serves. A Codex
pane, a shell, and every pane while **API** is off get nothing. A
`claude` typed into a shell pane gets nothing either: the link is made
when the pane starts.

**What the pane gets.** Its own listener on `127.0.0.1:<a port the OS
picks>`, one per session pane: Claude Code reads its token from the lock
file its port names, so one shared port would give every session the same
token, and mnml could not tell the sessions apart. The child's
environment gains, beside `MNML_API` / `MNML_API_TOKEN`:

| variable | value |
|---|---|
| `CLAUDE_CODE_SSE_PORT` | the listener's port |
| `ENABLE_IDE_INTEGRATION` | `true` |

**The lock file.** `$CLAUDE_CONFIG_DIR/ide/<port>.lock`, else
`~/.claude/ide/<port>.lock`, mode 0600:

```json
{"pid": 4242, "workspaceFolders": ["/path/to/ws"], "ideName": "mnml",
 "transport": "ws", "authToken": "<32 lowercase hex>"}
```

The token is 128 random bits, made when the pane starts. The lock file is
removed when the pane closes, when it restarts (which makes a new port and
token), and when mnml exits.

**The connection.** A WebSocket upgrade must carry the token in the
`x-claude-code-ide-authorization` header; without it the answer is 401.
Then MCP, one JSON-RPC message per WebSocket message: `initialize`
(`serverInfo.name` `mnml`), `tools/list`, `tools/call`, `ping`.

**The tools.** Every call is made as the pane the lock file belongs to,
`pane:<id>`, through the same gate as the socket, and each is a line in
`.mnml/ipc/audit.jsonl` (`"method":"ide"`).

| tool | what it does | asks? |
|---|---|---|
| `getWorkspaceFolders` | the workspace | no |
| `getOpenEditors` | the open editors: path, label, active, dirty | no |
| `getCurrentSelection`, `getLatestSelection` | the active editor's selection (else the last editor's) | no |
| `getDiagnostics` | language-server diagnostics, one file (`uri`) or every file | no |
| `checkDocumentDirty` | whether a file has unsaved changes | no |
| `openFile` | opens a file, optionally selecting `startText` … `endText` | no |
| `openDiff` | shows the proposal in the review pane; answers when you decide | no: your review is the approval |
| `close_tab`, `closeAllDiffTabs` | closes the session's diff tabs | no |
| `saveDocument` | saves a buffer | **yes**: class `write`, the same toast as a command; *Allow for the session* or `.api.clients` `pane:<id>` with `.allow = .{.write}` lets it through |
| `executeCode` | — | refused: not supported |

**`openDiff`.** The proposed file opens in the review pane — its own tab
beside the buffer, not the git panel, so an untracked file or one outside
any repo is reviewed the same way — titled with the session's `tab_name`,
diffed against the buffer as it stands (unsaved edits included). The
pane is drawn by the git diff pane's own view: the same Hunk / Inline /
Split toolbar, cycled by `t` or `git.diff_toggle_view` as in the git
panel. Until you pick one, a pane at least 80 cells wide opens in
**Split** (the buffer on the left, the proposal on the right) and a
narrower one in **Hunk**. Each hunk's header carries `[✓ accept]` or
`[  skip  ]`, and a skipped hunk paints untinted.

Space (or `a`, or a click on the focused hunk's header) accepts or skips
the focused hunk; `n` / `p` and `]c` / `[c` step hunks, `A` / `R` mark
them all. Enter (or `y`) applies the accepted hunks; **`Y`**, the header's
**Accept all** chip, or the `ai.apply_accept_all` command accepts every
hunk and applies them in one key. Either way the text goes into the
buffer as one undo step, **the file is saved** (the session's next read
or test run must see what it was told was saved), a toast says so, and
the session is answered `FILE_SAVED` with the file's text; undo in the
buffer is still there. Esc, `q`, the toolbar's `×`, closing the tab, or
Enter with nothing accepted answers `DIFF_REJECTED`. A second proposal
for the same file replaces the first, which is answered `DIFF_REJECTED`.

**Where the review opens** (`ai.review_placement`, also a row in
Settings ▸ AI). With the default, `.editor`, the review is a tab in the
split that holds the file, else in a split showing an editor, so the
session stays in view. When the session's split is the only one, a
split opens beside the session for the review, and a file the request
had to open goes there too. `.beside` always opens that split beside
the session. `.tab` is a tab of the focused split, which can cover the
session. A session on another tab page gets a tab of the focused split.
The review takes the focus. Accept, reject or Esc gives the focus back
to the session that asked.

**What mnml tells the session.** `selection_changed` (`text`,
`filePath`, `fileUrl`, `selection` with 0-based lines and characters) when
the selection in an editor changes, at most once per 100 ms, to one
session: the linked session pane you looked at last. `ai.send_selection`
sends that session `at_mentioned` (`filePath`, `lineStart`, `lineEnd`,
0-based) for the selected lines, or the cursor's line.

**What you see.** A link mark, `⇄` (`=` with `--ascii`), after the
session's name on its tab while the link is up, and in the gutter left of
its SESSIONS card when the ready mark and the on-screen dot are not there;
and a toast the first time it connects:
`Claude Code connected to mnml (pane 4)`.

## Claude Code's session registry

mnml reads, and does not write, a file Claude Code keeps for each of its
running sessions: `~/.claude/sessions/<pid>.json`. It is Claude Code's own
format — **undocumented, and liable to change in any release** — so mnml
reads it defensively and treats it as a hint over the transcripts, never
as the listing. `sessions.registry = false` turns it off.

**What mnml reads.** Only `*.json` files, at most 64 KiB each, on the
SESSIONS stat tick (every 500 ms while SESSIONS or the sessions table is
on screen, every 2 s otherwise, never under `ui.dashboard_refresh =
.manual`), and a file only when its size or mtime moved. Of each record:
`pid`, `sessionId`, `cwd`, `name` with `nameSource`, `status` (`busy`,
`idle`, `waiting`) and `messagingSocketPath`. A file that is not a JSON
object, or lacks a positive `pid` or a `sessionId`, is skipped; a field
of another type, or a status it does not know, is ignored. Every other
file in the directory is left unopened.

**What it shows.** A record is matched to a transcript by `sessionId`.
An EXTERNAL row in SESSIONS then reads `<name>  <status>` when the user
named the session (`nameSource: "user"` — `/rename`, `--name`), else
`<branch>  (<short id>)  <status>`; the user's name is the session's name
everywhere else too, under a rename made in mnml. A record no transcript
matches is listed as well, `<name>  <status>  <cwd basename>`, when its
cwd is in the workspace (or every workspace's, under `w`).

**Ask what it is doing** (`sessions.ask_external`, on the session's row
menu in the sessions table). mnml connects to the record's
`messagingSocketPath` and writes one line, the documented cross-session
message shape —
`{"type":"user","message":{"role":"user","content":"…"}}` — asking for
one line on what it is working on and whether it is safe to interrupt.
No auth line is sent: it is optional on macOS and Linux. Windows
inboxes are named pipes and are not supported yet. How a reply reaches a
sender that is not a Claude Code session is not documented, so mnml
binds no inbox of its own: it notes where the session's transcript ends
and polls it every 500 ms for 60 s for the next assistant entry — a
`SendMessage` call's text, else its plain text — and shows it as a
toast. The session's inbound settings decide whether it reads the
message at all; a held or refused message shows as no reply in 60 s.

**Take over** (`sessions.take_over`). Ends the session in its own
terminal and resumes it in a pane here, after a confirm. Only while the
record's `status` is `idle` or `waiting`; a `busy` session is refused
with a toast. On the confirm, mnml reads the registry again, checks the
record's pid still belongs to that session and that the pid's command
line is a `claude` process (`ps -o command=`), sends it SIGTERM, waits
up to 10 s for its record to leave the registry, and resumes it with
`claude --resume <id>` in the session's cwd. One that does not exit in
time is left running, with a toast; mnml never sends SIGKILL. Not on
Windows.
