# The mnml API — one protocol, three faces

*2026-10-02 · a design pass; nothing here is built. Every mnml claim was
read in this tree (main, `4d1ab3f1`). The user's brief: let other
programs — shells, test runners, git hooks, and above all the Claude Code
and Codex sessions running in mnml's own panes — drive and query mnml,
without letting a session use mnml to get around the user's own
approvals, and without slowing the single-window hot paths. Designed
together with `docs/research/two-monitors.md`: one socket, one discovery.*

## 1. The problem, and the three faces

**The problem.** A session in a pane is blind to the editor around it.
It cannot see what you selected, cannot show you a diff in the editor
instead of a wall of terminal text, cannot read the diagnostics the
language server already computed, and cannot ask which other session is
waiting on you. A shell or a git hook is in the same position: the only
door today is appending JSON to `.mnml/ipc/command`, a test-harness file
that is unversioned, fire-and-forget, answers in another file, and has
no idea who wrote the line.

**Face 1 — a local socket speaking JSON-RPC 2.0** (`mnml/1`). One per
running instance, one line of JSON per message. Every method in §3 lives
here; the other two faces are thin adapters onto it. It is also the
socket `mnml attach` hands its terminal to (two-monitors option f), so
there is one thing to find per instance, not two.

**Face 2 — `mnml remote <verb>`.** The CLI on top: `mnml remote open
src/x.zig:42`, `mnml remote run git.stage_all`, `mnml remote status
--json`. What a shell, a test runner (`open` the failing line) or a git
hook (`open --wait` as `GIT_EDITOR`) uses. Same verbs, same permissions.

**Face 3 — the agent face, and the headline.** A Claude Code session
started in an mnml pane connects to mnml **with no setup**, because mnml
speaks Claude Code's existing IDE protocol — the one its VS Code and
JetBrains extensions and the Neovim plugin `claudecode.nvim` speak. The
session then gets your selection as context, shows its edits as diffs in
mnml's review pane, and reads mnml's diagnostics. Alongside it, an **MCP
server** (`mnml mcp`, stdio) exposes twelve methods as tools for Codex
and anything else that speaks MCP. The work is ordered by this face.

## 2. What exists today, and what is reused

| surface | transport | what it is | decision |
|---|---|---|---|
| file IPC (`src/ipc/`) | `<ws>/.mnml/ipc/command` JSONL, tailed every 200 ms (`tui/loop.zig` `ipc_poll_ms`); acks in `events.jsonl`; `screen.txt` / `status.json` / `rects.json` out | the test harness and the integrations' "tier 2" (BRIDGE.md). 32 commands (below). Input verbs are refused in the live loop unless `.ipc.allow_input`; **`run-command` and `open-pty` are always taken** | **Keep as is** for `.test` and headless. Its verbs seed the method list. Its ungated `run-command`/`open-pty` is the hole this design closes (§5.7) |
| Bridge mount (`src/bridge/`, `docs/BRIDGE.md`) | Unix socket per mounted pane, 4-byte LE length + JSON, externally tagged unions | an integration paints a pane from another process | **Reuse the precedent, not the wire**: AF_UNIX on all three OSes (Windows 10 1803+, `Io.net.has_unix_sockets`), the `sun_path` 104/108 fallback (`host.socketPath`) |
| API broker (`sdk/mnml-sdk/src/broker.zig`, `src/app/broker.zig`) | Unix socket, one JSON line per message, request/reply | rate-limit queue; election lock; "absent is the normal case" | **Reuse the framing** (NDJSON — "the other end is as likely to be twenty lines of Python") and the socket-path resolution |
| `src/rpc/jsonrpc.zig` | stdio, `Content-Length` | LSP/DAP client: reader task → `Incoming` → sink; **writer task** so the UI thread never blocks on a pipe; 16 MiB `max_body` | **Reuse** `Incoming`, the reader/writer-task shape and the size cap; swap the framing |
| `src/http/ws.zig` | RFC 6455 by hand | the WebSocket pane's and CDP's client; already has `serverAccept` (server handshake) for tests | **Reuse** for the IDE face's WebSocket server; `serverAccept` must also return the auth header |
| Lua (`src/scripting/api.zig`, `docs/LUA.md`) | in-process | `mnml.run`, `mnml.commands`, `mnml.ex`, `mnml.buf.selection`, `mnml.toast`, `mnml.diagnostics.set`, hooks | **One verb table behind both** (§3.3). Lua stays ungated: it is code the user trusted |
| command registry (`src/core/command.zig`, `src/commands/specs.zig`) | in-process | 1176 static commands in 50 groups (`docs/commands.md`) + dynamic ones (IPC / manifest / Lua); `CommandFn = fn (*App)`, no args | **Reuse**; add one field, `effect`, so a call can be classed (§5.3) |
| hooks (`src/core/hooks.zig`) | in-process | `open`, `save_post`, `buffer_change`, `cursor_idle`, `diagnostics`, `pane_focus`, `git_status`, … UI-thread emits | **Reuse** as the event source for `events.subscribe` |
| `ai_apply` pane (`src/app/ai_apply.zig`) | in-process | a proposal shown as a hunk-by-hunk reviewed diff; Enter applies the accepted hunks as one `EditOp.replace_range`, one undo step; anchored ranges | **Reuse** as the screen behind `ui.diff` / Claude Code's `openDiff` |
| confirm box + reverse channel (`ui/confirm.zig`, CONVENTIONS "Reverse channels") | in-process | one-look yes/no; a worker parks on a one-slot queue, every close path answers "no" | **Reuse** for the grant prompt, `ui.ask` and a blocking `ui.diff` |
| `pty_env.build` (`src/app/pty_env.zig`) | env at spawn | the one place a pane child's environment is built (`MNML_PANE=1`, `MNML_WORKSPACE`, prompt vars) | **Reuse**: the per-pane token and the agent-face variables go here |
| launch profiles (`src/app/launch_profiles.zig`, `.ai.launch_profiles`) | config | named ways to start a session (binary, args, env, cwd) through a shim | **Reuse**: a profile names its agent face as data |
| marker (`src/tui/marker.zig`) | one file per user | `${TMPDIR}/mnml-zig-running-${USER}.workspace` — the last instance started | **Extend** to one marker per instance (§4.2) |
| web demo gate (`demo/cloudflare/src/control.ts`) | Worker | `view` / `ask` / `open`, a secret that unlocks | **Prior art** for read / ask / allowlist |

**The file-IPC command set**, catalogued (`src/ipc/command.zig`): `open`,
`key`, `type`, `run-command`, `register-command`, `click`, `hover`,
`scroll`, `drag`, `mouse_down`, `mouse_move`, `mouse_up`, `wait_ms`,
`expect_screen`, `snapshot`, `toast`, `toast-persistent`,
`toast-dismiss`, `progress-start`, `progress-update`, `progress-end`,
`statusline-set-segment`, `statusline-clear-segment`, `notify`,
`open-pty`, `set-activity-badge`, `focus-session`, `dump-rects`, `ghost`,
`ex`, `quit`, `restart`. The pointer/key verbs, `wait_ms`,
`expect_screen`, `dump-rects` and `ghost` are test-driver verbs and stay
there; the API deliberately does not drive the mouse. `open`,
`run-command`, `ex`, `toast`, `progress-*`, `open-pty`, `focus-session`
and the `status.json` / `screen.txt` reads become methods.

## 3. The methods

29 methods in 7 groups, plus three protocol methods. **Class**: `read`
is free (an unknown client gets the subset marked †); `ui` is free for
any identified client — it moves the view or opens something to look
at, and never changes a file, a process or another pane's input; `ask`
needs a grant (§5.4) unless the allowlist gives it; `allowlist` is never
offered as a prompt — only config grants it. **MCP** marks the twelve
the MCP face exposes; **IDE** names the Claude Code IDE tool it backs.

### Protocol

| method | params | result | class |
|---|---|---|---|
| `initialize` | `{protocol:"mnml/1", client:{name, version}, token?}` | `{protocol, instance:{pid, workspace, roots, version}, identity:{kind, pane?, name}, grants:[class]}` | — |
| `ping` | `{}` | `{}` | — |
| `attach.begin` | `{cols, rows, term, caps}` + the tty fd as `SCM_RIGHTS` (POSIX) | `{frame}`, then the connection is the frame's (two-monitors §3f) | `ask` |

### Editor (6)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `editor.open` | `{path, line?, col?, end_line?, end_col?, preview?, focus?, wait?}` | `{pane}` (`wait`: answers when the buffer closes) | ui | ✓ | `openFile` |
| `editor.reveal` | `{pane?\|path, line, col?}` | `{}` | ui | | |
| `editor.selection` | `{pane?}` | `{path, text, start:{line,col}, end:{line,col}, mode, empty}` | read | ✓ | `getCurrentSelection`, `getLatestSelection` |
| `editor.set_selection` | `{pane?, start, end}` | `{}` | ui | | |
| `editor.text` | `{pane?\|path, start_line?, end_line?}` | `{text, dirty, line_count}` — the buffer as it stands, unsaved edits included | read | ✓ | |
| `editor.save` | `{pane?\|path}` | `{saved, bytes}` | ask | | `saveDocument` |

### Commands (3)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `commands.list` | `{query?, group?}` | `[{id, title, group, keys, effect}]` | read † | ✓ | |
| `commands.run` | `{id}` | `{ok, message?}` | by the command's `effect`: `view` → ui, else ask | ✓ | |
| `commands.ex` | `{line}` | `{ok, message?}` | ask (a `:` line can be `:!cmd`) | | |

### Layout (5)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `layout.panes` | `{}` | `[{pane, kind, title, path?, product?, page, active, zoomed, dirty, preview}]` | read † | ✓ | `getOpenEditors`, `checkDocumentDirty` |
| `layout.focus` | `{pane}` | `{}` | ui | | |
| `layout.split` | `{pane?, dir:"right"\|"down", open?:{path}}` | `{pane}` | ui | | |
| `layout.close` | `{pane?\|kind:"diff"}` | `{closed}` — a dirty editor or a live pty raises mnml's own close confirm | ui, ask for a pty | | `close_tab`, `closeAllDiffTabs` |
| `layout.zoom` | `{pane?, on?}` | `{zoomed}` | ui | | |

### State (5)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `state.status` | `{}` | `status.json`'s shape + `{workspace, roots, version}` | read † | ✓ | `getWorkspaceFolders` |
| `state.screen` | `{frame?}` | `{text, cols, rows}` — `screen.txt`'s text, made on demand | read | | |
| `state.diagnostics` | `{path?, min_severity?}` | `[{path, line, col, end_line, end_col, severity, message, source}]` (`lsp.diagnosticsFor` + script namespaces) | read † | ✓ | `getDiagnostics` |
| `state.git` | `{repo?}` | `{branch, ahead, behind, files:[{path, index, worktree}]}` | read † | ✓ | |
| `state.terminal` | `{pane, last_lines?}` | `{text, cursor_row}` — a pty pane's grid and scrollback | read; another session's pane: ask | | |

### Sessions and terminals (5)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `sessions.list` | `{}` | `[{pane, product, name, state:"working"\|"waiting"\|"idle"\|"exited", needs_you, cwd, session_id?}]` | read † | ✓ | |
| `sessions.waiting` | `{}` | the ready ring (`session_ready.zig`) in its order: `[{pane, name, kind:"needs_you"\|"news", since_ms}]` | read † | ✓ | |
| `sessions.start` | `{profile?, cwd?, prompt?, placement?}` | `{pane}` | ask | | |
| `terminal.start` | `{argv?, cwd?, title?, placement?}` (no argv: the shell) | `{pane}` | ask | | |
| `terminal.send` | `{pane, text, enter?, bracketed?}` | `{bytes}` | ask; **allowlist** when the target pane `needsYou` | | |

### UI (4)

| method | params | result | class | MCP | IDE |
|---|---|---|---|---|---|
| `ui.toast` | `{text, level?, action?:{label, command}}` | `{}` (rate-limited per client) | ui | | |
| `ui.progress` | `{id, label?, percent?, end?:"success"\|"failed"\|"cancelled"}` | `{}` | ui | | |
| `ui.ask` | `{title, message, choices:[string], default?}` | `{choice}` or `{choice:null}` — answered by the user, never by a timeout | ui | | |
| `ui.diff` | `{path, proposal, title?, wait?}` | `{result:"accepted"\|"partial"\|"rejected", text?}` | ui — the user's accept *is* the write's approval | ✓ | `openDiff` |

### Events (1)

| method | params | result | class |
|---|---|---|---|
| `events.subscribe` | `{topics:[…]}` | `{}`, then notifications `events.<topic>` until the connection closes or `topics:[]` | read (selection and terminal topics: not †) |

Topics: `open`, `save`, `buffer_change`, `selection` (debounced on the
existing `cursor_idle` 300 ms rest), `diagnostics`, `focus`,
`git_status`, `session_state`, `needs_you`, `command_run`, `client`
(connected / granted / revoked). Every topic is an existing hook or
state edge; `selection` and `session_state` are the two new emit points.

**The twelve on the MCP face**: `editor.open`, `editor.selection`,
`editor.text`, `commands.list`, `commands.run`, `layout.panes`,
`state.status`, `state.diagnostics`, `state.git`, `sessions.list`,
`sessions.waiting`, `ui.diff`. Left out on purpose: `terminal.send`
(typing into another agent), `commands.ex`, `attach.begin`.

**What the IDE face needs**: `editor.open`, `editor.selection`,
`editor.save`, `layout.panes`, `layout.close`, `state.status`,
`state.diagnostics`, `ui.diff`, and `events.subscribe` for the
`selection_changed` / `at_mentioned` notifications. Its twelfth tool,
`executeCode` (a Jupyter kernel), answers "not supported".

### 3.3 One verb table, three callers

The methods are one comptime table, `src/api/verbs.zig`: name, params
type, result type, class, and a `fn (*App, Params) Result`. The socket
dispatches through it; the IDE and MCP adapters translate names onto it;
the Lua functions that overlap (`mnml.run`, `mnml.commands`, `mnml.ex`,
`mnml.buf.selection`, `mnml.toast`, `mnml.pane.active`) are re-pointed at
the same functions, so a verb cannot mean one thing to a script and
another to a socket. A test walks the table and asserts each verb has a
doc line, a class, and — where it has a Lua twin — the same result
shape. Commands stay the registry they are; `commands.run` is
`command.runNamed`.

## 4. Transport

### 4.1 The socket

One AF_UNIX stream socket per instance, on all three OSes — the Bridge
and the broker already run AF_UNIX on Windows (10 1803+), and a named
pipe would be a second transport to test for no reader we have.

| OS | directory (created 0700, checked on open) | socket |
|---|---|---|
| macOS | `$TMPDIR/mnml/` (per-user already) | `<pid>.sock` |
| Linux | `$XDG_RUNTIME_DIR/mnml/`, else `/tmp/mnml-$UID/` | `<pid>.sock` |
| Windows | `%LOCALAPPDATA%\mnml\run\` (owner-only ACL) | `<pid>.sock` |

The directory name carries the profile prefix the marker already uses
(`profile.markerPrefix`), so an installed mnml and a `run.sh` build never
find each other. A path past `sun_path` falls back exactly as
`broker.socketPath` does. A `--sandbox` instance puts its socket under
the sandbox directory and lists itself nowhere shared: its own panes
reach it (they are told the path), nothing outside does. Headless binds
nothing unless asked (`MNML_API=1`), the rule the broker and
`integration_poll` already follow, so a corpus run never binds beside
the user's socket.

**Framing.** One JSON-RPC 2.0 object per line (NDJSON, UTF-8; JSON
escapes every newline so a line is a message). A line over 16 MiB
(`jsonrpc.max_body`) is read and discarded with an error reply.
Requests may be pipelined; replies carry the request `id`; notifications
(`events.*`) have none. `nc -U` or `socat` is a working client.

**Versioning.** `initialize` must come first and names `mnml/1`. `1` is
additive-only — new methods, new optional params, new result fields —
the rule Lua's `api = 1` follows; a `2` would be a new name served
alongside. Unknown method: `-32601`. mnml's own errors: `-32001`
not permitted (policy), `-32002` denied (the user said no), `-32003` no
such pane / path, `-32004` not now (no editor focused, nothing
selected), `-32005` superseded (a newer `ui.diff` for the same path).

### 4.2 Discovery — one marker per instance

Beside each socket, `<pid>.zon`:

```zig
.{ .pid = 4242, .version = "0.3.2", .workspace = "/path/to/ws",
   .roots = .{ "/path/to/ws", "/path/to/other" }, .socket = "4242.sock",
   .started_ms = 1759400000000, .frames = 1 }
```

Written at start, rewritten on a workspace switch (roots change), removed
on a clean exit. The old single marker stays — written by the same code,
still "the last one started" — so `run.sh restart` / `stop` /
`scripts/shot.sh` keep working unchanged; `run.sh status` gains a list of
every instance from the directory.

**How `mnml remote` and `mnml attach` pick an instance**, first match:

1. `MNML_API` in the environment — set in every pane child, so a command
   run inside a pane always reaches the mnml it runs in.
2. `--instance PID` or `--workspace PATH`.
3. The instance with the longest root containing the current directory.
4. The only instance running.
5. Otherwise exit 3 and print the candidates (`pid  workspace  started`).

A marker whose socket refuses a connection and whose pid is dead is
removed by whoever found it.

### 4.3 The same socket as `mnml attach`

`mnml attach` connects to the same socket, sends `initialize`, then
`attach.begin` with its tty fd in the ancillary data (`SCM_RIGHTS`); the
reply names the frame, and from then on that connection carries nothing
but the frame's lifetime. On Windows, where a console handle cannot be
sent, the connection turns into the byte relay two-monitors §3f
describes after the reply. So: one socket, one discovery, one
`initialize`, one identity check — and attach is a method that needs the
`ask` grant like anything else that takes over a screen (an attach from
a pane with no grant is refused, so a session cannot open a hidden
second view of your editor).

The IDE face cannot use this socket — Claude Code speaks WebSocket over
loopback TCP — so it is an adapter listener (§6). Its ports are listed in
the instance marker as `.ide_ports` so the CONNECTED panel and `mnml
remote instances` can show them; Claude Code finds them through its own
lock files, which is its discovery, not ours.

## 5. Permissions and identity

### 5.1 The threat this addresses, honestly

A session's own tools are gated by its own permission system: Claude
Code asks before it runs a shell command or writes a file. If mnml
offers "run any command" or "type into any terminal" to that session
without asking, mnml becomes a way around those approvals — a laundering
channel. That is what the gate stops. It is not a sandbox against a
determined process running as the same user: such a process can already
read your files and signal your processes. The socket directory is
0700 and the socket 0600, so another user is out; within one user, the
gate makes mnml an *audited, asked* actuator rather than a silent one.

The file channel is held to the same gate: §5.7.

### 5.2 Identity — who is calling

| caller | how it proves it | identity |
|---|---|---|
| a process in a pane (shell, task, session, anything it spawns) | `MNML_API_TOKEN`, 128 random bits minted per pane at spawn in `pty_env.build`, held only in memory and in the child's environment | `pane:<id>` with its kind (`shell`, `task`, `session:<product>`) and label |
| a Claude Code session over the IDE face | the per-pane WebSocket token (§6.1) | the same `pane:<id>` |
| an integration | its mount (already authenticated by being spawned) | `integration:<id>` |
| a script the user trusts (git hook, test runner, launcher) | a token the user minted: `mnml remote token new pre-commit` prints it once; config keeps its SHA-256 | `client:<name>` |
| anything else | nothing | `unknown` |

`MNML_API` (the socket path) and `MNML_API_TOKEN` ride in every pane's
environment beside `MNML_PANE` and `MNML_WORKSPACE`. A child of the
session (its `make`, its test runner) inherits both and acts as that
pane, which is right: it is that session's work. A session restored
after a restart is a new spawn and gets a new token; nothing about a
token is written to disk.

Hardening (phase 4): on the Unix socket, read the peer pid
(`SO_PEERCRED` on Linux, `LOCAL_PEERPID` on macOS,
`SIO_AF_UNIX_GETPEERPID` on Windows) and check it descends from the
pane's child. A token presented from outside its pane's process tree is
marked so in the audit and the panel, and every `ask` from it prompts
again.

### 5.3 Classing a command

`Spec` gains `effect: Effect = <by group>` — `view` (moves the view,
opens an overlay or a read-only pane), `edit` (changes a buffer, not the
disk), `write` (disk, git, network, config), `exec` (starts or kills a
process). The default comes from the group (`view`, `go`, `find`, `search`,
`grep`, `picker`, `help` → view; `editor`, `edit`, `buffer`, `vim` →
edit; `file`, `files`, `git`, `http`, `integrations`, `zon` → write;
`ai`, `sessions`, `term`, `terminal`, `test`, `dap` → exec), the exceptions are listed per id in
`specs.zig`, and a test fails if any of the 1176 has no effect. A dynamic command (Lua,
manifest, IPC-registered) is `exec` unless it declares one
(`mnml.command{ effect = "view" }`). `commands.run` of a `view` command
is ui class; anything else is ask, and the prompt names the effect.

### 5.4 The grant prompt

A request that needs a grant does **not** raise a modal: a modal that
appears while you are typing takes your next keystroke as its answer.
Instead:

1. A persistent toast with an action — `pane 4 · claude "fix-auth"
   asks to run git.commit (write)  [Review]` — plus a row in the bell's
   menu (the one `session_attention.zig` already fills), and the
   session's card wears the waiting mark.
2. Review opens the one confirm box: the client, the method, the target
   verbatim (the command id, the `:` line, the argv, the first 200 chars
   of the text to send), and four verbs —
   `[A]llow once  ·  Allow [w]rite for this session  ·  [D]eny  ·  Cancel`.
   Cancel holds the focus (the convention for anything consequential).
3. The request waits on a reverse channel (`ai.Job.confirm`'s shape); a
   dismissed box, a closed pane or a disconnect is a deny — never a
   hang, never a timeout that says yes.

"For this session" means *this client, this effect class, until the
client disconnects or mnml quits* — `pane:4` granted `write` does not
grant `exec`, and does not survive the pane. The CONNECTED panel revokes
any grant at any time.

### 5.5 The allowlist — config, not Settings

Settings carries discrete choices only (the family idiom), under
`── API ──`:

- `API:  [on] / off`
- `Agent face (IDE protocol):  [on] / off`
- `Unknown clients:  [read-only] / refused`
- `Grants last:  [until the client leaves] / ask every time`

Everything that is a list is ZON-edited in `config.zon`:

```zig
.api = .{
    // What a pane's own client gets without a prompt, by pane kind.
    .pane_defaults = .{ .shell = .{ .view }, .task = .{ .view }, .session = .{ .view } },
    // Command ids any identified client may run without a prompt.
    .allow_commands = .{ "git.refresh", "test.run_file" },
    // Scripts the user trusts, by a token they minted.
    .clients = .{
        .{ .name = "pre-commit", .token_sha256 = "<printed by mnml remote token new>",
           .allow = .{ .view, .write }, .commands = .{ "git.stage_all" } },
    },
    // Panes a session may type into when that pane is asking a question.
    .send_to_waiting = .{},
},
```

No client is hard-coded: a launcher, a hook, a test runner is a row the
user adds. Products are not special-cased here either — `session` is
whatever `launch_profiles.productOfPane` says a pane runs.

**One rule no prompt can relax:** `terminal.send` into a pane that is
waiting on a question (`sessions.needsYou`) is allowlist-only. A
session answering another session's approval prompt is the purest form
of going around the user, so the only way to permit it is to write it
down.

### 5.6 The audit trail, and who is connected

Every call above `read` writes one line to `<ws>/.mnml/api/audit.jsonl`
(owner-only, rotated at 5 MB) and, when the IPC channel is open, an
`{"event":"api",…}` line in `events.jsonl` for a host watching:

```json
{"ts":1759400000123,"client":"pane:4","as":"session:claude fix-auth","method":"commands.run","target":"git.commit","class":"write","decision":"granted-session","result":"ok"}
```

`decision` is one of `free`, `allowlisted`, `granted-once`,
`granted-session`, `denied`, `refused`. Payloads are never logged — a
`terminal.send` records its byte count, not its text, as `report_input`
never records which key. Reads are counted per client, not logged.

What the user sees: a statusline chip `⇄ 3` (clients connected) that is
absent at zero; its hover lists them; a click opens **CONNECTED** — a
rail section on the `todos.zig` shape: one row per client (identity,
grants, last call, calls), row menu *Revoke grants · Disconnect · Show
audit*. A SESSIONS card whose session is connected over the agent face
wears a small link mark beside its name. Every new piece ships with its
hover-help entry (CONVENTIONS, "Hover help").

**An unknown client** gets the † reads (status, panes, commands,
diagnostics, git, sessions) and nothing else — not screen or terminal
text, not the selection — or nothing at all with *Unknown clients:
refused*. It appears in CONNECTED like anyone else.

### 5.7 The file channel goes through the same gate

The live terminal loop routes the file channel's `run-command` and
`open-pty` through the same classes with identity `file-channel`: a
`view` command still runs, anything else prompts. The headless loop is
the test driver and is untouched. Integrations that run commands move
to their mount (`{"command":{"id":…}}` already exists on the Bridge) or
to the socket with their integration identity. The user chose to do
this in phase 1 and update the few integrations that need it.

## 6. The agent face

### 6.1 Why the IDE protocol first

**It needs nothing from the user.** Claude Code connects to an IDE when
its environment says where — `CLAUDE_CODE_SSE_PORT` and
`ENABLE_IDE_INTEGRATION=true` — and mnml builds that environment for
every pane it spawns (`pty_env.build`). MCP, by contrast, has to be
registered with the agent. And the three headline flows are already
Claude Code's own UI over this protocol: it shows the IDE selection in
its prompt, it routes edits through `openDiff` for accept / reject, and
it reads `getDiagnostics`. mnml supplies the editor half and inherits
the rest.

Codex has a local `/ide` socket too, but it is undocumented, carries
editor context only (no diffs, no tools), and is known only from one
reverse-engineered plugin — not something to build a contract on. Codex
does speak MCP (stdio servers in its config, or `codex mcp add`), so it
gets the MCP face.

### 6.2 The handshake, concretely

Researched from claudecode.nvim's `PROTOCOL.md` and source:

1. **mnml listens**, per session pane, on `127.0.0.1:<random port in
   10000–65535>` — loopback only — a WebSocket server built on
   `http/ws.zig`'s `serverAccept`, extended to return the
   `x-claude-code-ide-authorization` header.
2. **mnml writes the lock file** `~/.claude/ide/<port>.lock` (the
   directory under `CLAUDE_CONFIG_DIR` when that is set — to confirm
   against Claude Code): `{pid, workspaceFolders, ideName, transport:
   "ws", authToken}`, the token 16 random bytes as 32 lowercase hex.
   `ideName` is `mnml · <pane label>` so a list of IDEs reads.
3. **mnml spawns the session** with `CLAUDE_CODE_SSE_PORT=<port>`,
   `ENABLE_IDE_INTEGRATION=true` and `FORCE_CODE_TERMINAL=true` (what
   claudecode.nvim sets), loopback added to `NO_PROXY`, and the usual
   `MNML_API` / `MNML_API_TOKEN`.
4. **Claude Code connects**, presenting the token in that header; a
   wrong or missing token is refused at the upgrade. It then speaks MCP
   over the WebSocket: `initialize` (claudecode.nvim answers protocol
   `2024-11-05` with `tools` and `prompts` capabilities),
   `notifications/initialized`, `tools/list`, `tools/call`. mnml pings
   every 30 s, as claudecode.nvim does.
5. **mnml pushes** `selection_changed` (`{text, filePath, fileUrl,
   selection:{start, end, isEmpty}}`) from the debounced `selection`
   event, and `at_mentioned` (`{filePath, lineStart, lineEnd}`) when you
   send a selection to that session.
6. On pane exit or mnml exit the listener closes and the lock file is
   removed; at start mnml removes only lock files whose `ideName` is its
   own and whose `pid` is dead.

**One port per session pane**, not one per instance. Claude Code reads
the token from the lock file named by its port, so a shared port would
hand every session the same token and mnml could not tell which pane a
connection came from — and the identity is the whole permission model.
The cost is one idle accept task per session pane. The side effect is
that a Claude Code started in some *other* terminal sees each mnml
session as an IDE in its `/ide` list; whether to also publish one
read-only workspace-level lock for such outside sessions is a question
(§10).

**Not hard-coded.** Which face a session gets is data on its launch
profile — `.agent_face = .ide | .mcp | .both | .none` — with the
default per product in one table, and the protocol's env names, lock
directory and header live in one descriptor in `src/api/ide.zig`. A new
agent CLI that speaks the same protocol is a profile, not a patch.

Two things to verify in phase 2 rather than assume: whether Claude Code
exposes an IDE server's *extra* tools to the model (if it only passes a
fixed subset, the commands / sessions tools reach Claude through the
MCP face, which a launch profile can add with Claude Code's
`--mcp-config` flag — still no user setup); and exactly what Claude
Code expects to happen on disk when `openDiff` is accepted (claudecode.nvim
writes and saves the accepted text and answers `FILE_SAVED`).

### 6.3 What the user sees

- The session's tab and its SESSIONS card wear the link mark once the
  session has connected; the `⇄` chip counts it.
- Claude Code's own status shows it is connected to an IDE named
  `mnml · <label>`.
- Nothing else until a flow runs. Every grant prompt arrives as a toast
  first (§5.4).

### 6.4 The three headline flows, end to end

**Selection → context.** You select lines 40–58 of `src/auth.zig`. The
editor's selection rests 300 ms (the `cursor_idle` timer, which already
runs); because at least one agent-face client is subscribed, mnml emits
`selection` and the IDE adapter sends each connected session
`selection_changed`. Claude Code shows "40–58 of auth.zig selected" in
its prompt and includes it with your next message. To point a
*particular* session at it, `ai.send_selection` (a new command, on the
editor's right-click menu and a chord) asks which session — the picker
lists connected sessions, waiting ones first — and sends that one
`at_mentioned`. Reads only; no prompt.

**The agent opens a diff in the editor.** The session decides to edit
`src/auth.zig`. With an IDE connected, Claude Code calls `openDiff`
`{old_file_path, new_file_path, new_file_contents, tab_name}` instead of
writing. mnml opens an `ai_apply` pane (a split beside the file, or the
session's own column in sessions mode) holding the proposal against the
buffer as it stands, hunk by hunk; the call **blocks** on a reverse
channel. You accept some hunks and press Enter: one
`EditOp.replace_range`, one undo step, the buffer saved, and the call
answers `FILE_SAVED` with the final text. Esc, closing the pane or the
session going away answers `DIFF_REJECTED`; Claude Code then asks you
what to do instead. A second `openDiff` for the same path supersedes the
first (`-32005`). The write needed no grant prompt — the review *was*
the approval, and the audit says `decision: "free"` with
`result: "accepted 3/4 hunks"`.

**Diagnostics back to the agent.** The session calls `getDiagnostics`
(optionally with a file URI). mnml answers from
`lsp.diagnosticsFor` for every attached server plus any script
namespace (`mnml.diagnostics.set`), shaped as the protocol expects
(`message`, `severity`, `range`, `source`), and — when the session
asked for one file that has never been opened — opens it in the
background so a server attaches, answering when the first
`diagnostics` hook for it fires or after 3 s with what it has. Read
class; no prompt.

### 6.5 The MCP face

`mnml mcp` is a stdio MCP server — a subcommand of the same binary — that
reads `MNML_API` / `MNML_API_TOKEN` from its environment, connects to the
socket and serves the twelve tools in §3 as `mnml_<group>_<verb>`.
Because it takes its identity from the environment, **one** registration
works for every session: run inside an mnml pane it *is* that pane;
anywhere else it is `unknown` and read-only. For Codex that is one
`[mcp_servers.mnml]` entry with `command = "mnml"`, `args = ["mcp"]` —
which the first-launch wizard offers to add (it writes the user's Codex
config, so it asks). For Claude Code, a launch profile can pass
`--mcp-config` with a file mnml writes in its data root, so even the
MCP tools need no setup there.

## 7. `mnml remote`

```
mnml remote open PATH[:LINE[:COL]] [--wait] [--no-focus]
mnml remote run ID
mnml remote ex LINE
mnml remote status | panes | sessions | waiting | git | diagnostics [PATH]
mnml remote focus PANE | zoom [PANE] | close PANE
mnml remote send PANE TEXT [--enter]
mnml remote toast TEXT [--level warn]
mnml remote ask TITLE --choice A --choice B …      # prints the choice
mnml remote diff PATH --proposal FILE              # blocks until reviewed
mnml remote screen
mnml remote watch [TOPIC…]                         # NDJSON events until ^C
mnml remote call METHOD [JSON]                     # any method, raw
mnml remote instances
mnml remote token new NAME | revoke NAME
mnml mcp                                           # the MCP face, stdio
mnml attach                                        # two-monitors §3f
```

Global flags: `--json` (print the result object verbatim; without it, a
human line — `opened src/x.zig:42 in pane 3`), `--instance PID`,
`--workspace PATH`, `--timeout MS` (calls that wait on you have none by
default).

| exit | meaning |
|---|---|
| 0 | done |
| 1 | the method failed (no such command, not an editor, …) — message on stderr |
| 2 | usage |
| 3 | no mnml found, or several and none matched (candidates printed) |
| 4 | not permitted — policy (unknown client, allowlist-only) |
| 5 | the user said no — a denied grant, a rejected diff, a cancelled `ask` |
| 6 | timed out (`--timeout`) |
| 7 | protocol mismatch (an mnml too old for this verb) |

4 and 5 are separate because a script reacts differently: 4 means fix
the config, 5 means a person decided.

`open --wait` answers when that buffer closes, so `GIT_EDITOR="mnml remote
open --wait"` edits a commit message in the running mnml — inside a
pane or from any terminal.

## 8. Hot-path cost, and how it is measured

**The claim.** With no client connected, the API costs nothing per frame
and nothing per key:

- The listener is one task in the loop's existing `Io.Group` beside
  `bridgeTask` / `ipcTask` / `signalTask`, parked in `accept`. Each
  session pane's IDE listener is the same: parked.
- Each connection gets a reader task that parses a line into an
  `Incoming` off the UI thread and posts an `.api` event — exactly how
  an IPC line becomes `.ipc` today. The loop handles it in the same drain
  as keys, between frames. Replies are serialised on the UI thread into
  a small buffer and handed to a writer task (`jsonrpc.zig`'s rule), so
  a slow reader never stalls a frame.
- Hook emission gains one branch: no subscriber, return. Hooks are
  already debounced and never per frame. The `selection` topic rides the
  existing `cursor_idle` timer and is computed only when someone
  subscribed.
- `state.screen` builds `screen.txt`'s text from the last rendered
  screen on request; nothing is mirrored per frame.
- Spawn: a pane spawn mints 16 random bytes; a session pane with the IDE
  face also binds a port and writes a lock file — once, at spawn.
- A request is faster than the file channel, not slower: the socket
  wakes the loop at once where `command` is polled every 200 ms.

**The measurement** — two-monitors §5's four checks, single window, main
vs branch, back to back on one machine:

1. `tools/compare.sh compare-keys` and `compare-keys 200x60` — per-step
   ms in `timing.md` inside run-to-run noise.
2. The big-file rows of `docs/research/bench-2026-09-21.md` (10 MB and
   100 MB `.rs` / `.log`): open, edits, search, RSS.
3. The stress meter (`perf.copy_stress`): render p50 / p95.
4. A pty flood in the real loop: wall time and key-echo latency.

Then the same four with **eight connected, idle IDE clients and one
`events.subscribe` on every topic** — that number is the cost of the
feature in use, and is the user's to accept; the zero-client number must
not move. And one new probe, `tools/api-bench.sh` (phase 1): 1000
`state.status` round trips and 100 `editor.open` → screen-dump
latencies over the socket, p50 / p95, at rest and during the pty flood.
Target: a round trip under 2 ms at rest and under one paced frame
(16 ms) during a flood.

## 9. Phased plan

| phase | what | agent-days |
|---|---|---|
| **1 — try it** | `src/api/`: the socket and its directory + per-instance marker; NDJSON JSON-RPC, `initialize`, `ping`; the verb table with `editor.open`, `commands.list`, `commands.run`, `state.status`, `layout.panes`; per-pane tokens in `pty_env.build`; `Spec.effect` by group with the exceptions table and its test; the grant prompt (toast → confirm → reverse channel) with session-long memory; `audit.jsonl`; `mnml remote open / run / status / panes / instances` with `--json` and the exit codes; Settings `API: on / off`; `tools/api-bench.sh`; the §8 checks the file channel through the same gate (§5.7) | 4–5 |
| **2 — the agent face** | the IDE adapter: per-session-pane WebSocket listener on `http/ws.zig`, lock file, env on spawn, MCP `initialize` / `tools/*` over it, ping; `editor.selection`, `editor.save`, `state.diagnostics`, `ui.diff` on `ai_apply` with the blocking reverse channel, `layout.close`, `events.subscribe`; `selection_changed`, `ai.send_selection` → `at_mentioned`; `.agent_face` on launch profiles; the card mark and the `⇄` chip; the two verifications in §6.2; a `.test` driving a fake IDE client | 5–7 |
| **3 — the rest** | the remaining methods (`sessions.*`, `terminal.*`, `ui.ask / toast / progress`, `state.screen / git / terminal`, `layout.focus / split / zoom`, `editor.reveal / set_selection / text`, `commands.ex`); `mnml mcp` with the twelve tools; the Codex profile; allowlist clients and `remote token`; the CONNECTED section; Lua re-pointed at the verb table; the rest of the `remote` verbs | 5–7 |
| **4 — attach and hardening** | `attach.begin` on this socket (two-monitors phase 0 lands on it); the peer-pid check; Windows parity (owner-only ACL, the attach relay) | 3–4, plus two-monitors' own phases |

**Phase 1 is what the user can try**: in a shell pane, `mnml remote open
src/main.zig:120` jumps the editor there; `mnml remote run
view.toggle_tree` toggles the tree; `mnml remote run git.commit` raises
the toast, Review shows the confirm box, Allow-for-this-session runs it
and the next one does not ask; `mnml remote status --json | jq` reads the
cursor; and from a terminal *outside* mnml, `mnml remote open` finds the
instance by the current directory. About a week of agent time.

## 10. Open questions for the user

- Should a session's "allow for this session" end when the pane closes (proposed), or persist per launch profile until revoked?
- Close the existing gap now in phase 1 — any pane can append `run-command` / `open-pty` to `.mnml/ipc/command` today — even if it breaks integrations that rely on it?
- Should Claude Code sessions started outside mnml see mnml in their `/ide` list (one read-only workspace-level lock), or stay unaware of it?
- Is it fine that each mnml session appears as its own IDE (`mnml · <label>`) in an outside session's `/ide` list?
- When you accept a diff an agent proposed, save to disk at once (as claudecode.nvim does), or leave the buffer dirty for your own save?
- May a session ever type into another session's terminal with a prompt, or should `terminal.send` across panes be allowlist-only everywhere, not just to waiting panes?
- Unknown connectors (a git hook with no token): read-only by default, or refused?
- May the first-launch wizard add `mnml mcp` to your Codex config (one global entry), or do you add it by hand?
- Should the selection follow every session automatically (`selection_changed` to all), or only reach a session you point at it?
- Windows: AF_UNIX only (10 1803+, as the broker and Bridge do), or a named-pipe fallback for older Windows?
- Any appetite for a shorter verb than `mnml remote` (`mnml r`)?

## Sources (read for this pass)

- claudecode.nvim — protocol notes, terminal environment and server:
  [PROTOCOL.md](https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md),
  [terminal.lua](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/terminal.lua),
  [server/init.lua](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/server/init.lua),
  [README](https://github.com/coder/claudecode.nvim)
- Claude Code: [IDE integrations](https://docs.anthropic.com/en/docs/claude-code/ide-integrations),
  [CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-reference) (`--mcp-config`)
- Codex: [MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli);
  its `/ide` socket as reverse-engineered by
  [leejh903/codex.nvim](https://github.com/leejh903/codex.nvim)
- [JSON-RPC 2.0](https://www.jsonrpc.org/specification),
  [MCP specification](https://modelcontextprotocol.io/specification)
