# Bridge v2 — the mount wire

How an integration and mnml talk once mnml has opened it as a pane.
This is the contract an integration author codes against; the Zig
SDK (`docs/SDK.md`) speaks it for you, but nothing here needs the SDK.

Source of truth: `sdk/mnml-sdk/src/wire.zig` (the host imports the same
file as `src/bridge/wire.zig`). Every example below is what
`std.json` writes for those types.

## Lifecycle

1. mnml binds a Unix socket at `<ipc dir>/mounts/<pid>-<n>.sock`
   (`/tmp/mnml-mount-<pid>-<n>.sock` when the workspace path would not
   fit a `sockaddr_un`) and spawns the integration binary with:

   | variable | value |
   |---|---|
   | `MNML_MOUNT_SOCKET` | the socket path |
   | `MNML_PROTOCOL` | `3` |
   | `MNML_WORKSPACE` | the workspace, absolute |
   | `MNML_THEME` | the theme's name (`onedark`) |
   | `MNML_IPC_DIR` | the file-IPC channel (tier 2, see below) |
   | `MNML_SETTING_<KEY>` | one per `settings[]` entry in the manifest, upper-cased |

   stdin / stdout / stderr are `/dev/null`: paint through the socket.
2. The integration connects. mnml sends `hello`, then `focus`.
3. The integration sends `title` (optional) and a `frame`. From then on
   both sides send whenever they like; the socket is full-duplex.
4. Either side ends it: mnml sends `goodbye` (the tab closed, mnml is
   quitting) and gives the integration 200 ms before it kills the
   process; the integration sends `bye` and exits. EOF without `bye`
   is treated as a crash — the pane shows `[connection closed]`.

Unix sockets are used on Windows too (`std.Io.net.has_unix_sockets`,
Windows 10 1803+).

## Framing

Each message is a 4-byte **little-endian** length followed by that many
bytes of UTF-8 JSON. One message per frame. A length above
**16 MiB** (`16 * 1024 * 1024`) is refused and the connection dropped —
a 200×60 full frame is ~300 KB, so this is not a limit you meet.

```
00 00 00 0b  {"bye":{}}
```

## Encoding — one rule

**Every union is externally tagged**: `{"<tag>": payload}`. A payload
that carries nothing is `{}`. There is no sniffing by shape anywhere —
v1's `RgbOrIndex` (a bare integer or an array) is gone; a colour is
`{"index":4}` or `{"rgb":[r,g,b]}` and nothing else.

Unknown **fields** inside a payload are ignored, so a newer peer may add
fields. An unknown **tag** is an error.

## Host → integration (`HostMessage`)

| tag | payload | when |
|---|---|---|
| `hello` | `{protocol, geometry, theme, workspace, capabilities, palette?}` | once, first |
| `resize` | `{geometry}` | the pane's body changed size |
| `input` | `{event}` | the user did something (below) |
| `focus` | `true` / `false` | the pane gained / lost the keyboard |
| `session_state` | `{key, state, session_id?, detail?}` | a session you asked to watch moved (below) |
| `focus_item` | `{key}` | land the cursor on this one thing you already list (below) |
| `goodbye` | `{}` | leave now |

```json
{"hello":{"protocol":3,"geometry":{"cols":80,"rows":24},"theme":"onedark",
          "workspace":"/Users/me/proj","capabilities":{"rgb":true,"nerd_font":true,"ascii":false}}}
{"resize":{"geometry":{"cols":100,"rows":30}}}
{"focus":true}
{"focus_item":{"key":"acme/api#1198"}}
{"goodbye":{}}
```

`hello.protocol` is the version. **3** adds the optional `action` on a
`toast` (below) and nothing else; every 2 message is unchanged, so a
sibling built against 2 runs on a 3 host and a 3 sibling that never
offers a toast action runs on a 2 host. Refuse a host below the
version whose features you actually need.
`capabilities.rgb=false` means the terminal has no truecolor — mnml
folds rgb onto the 256-cube for you either way, but an integration that
cares can pick indices itself. `nerd_font=false` / `ascii=true` say to
use plain glyphs. `hover_help=true` says the host shows a `hover`
(below) in its info view; a host that predates the message sends no
such field, it reads as `false`, and an integration then sends none —
which is why the message needed no protocol bump.

`geometry` is the pane's **body** in cells: the tab strip is not yours.

### A toast with something to do about it

A message that reports something and then vanishes leaves the reader
holding the consequence: a merge that landed and took its own row off
the list, a refresh that failed and left a stale one. Since protocol 3
a `toast` may carry an `action`, and mnml paints it as the button in
the box:

```json
"action": {"label": "Open PR", "url": "https://bitbucket.org/acme/api/pull-requests/1234"}
"action": {"label": "Retry",   "command": "integrations.retry_refresh"}
```

`label` is what the button says. **Exactly one** of `command` and
`url` is set — a row with neither or both is dropped rather than
guessed at, because a button that does nothing is worse than no
button.

Neither is a free hand. `command` is an id the host already knows —
one of mnml's, or one this integration registered in its manifest —
resolved through the same registry a key or the palette uses; a
sibling cannot name a shell line here. `url` is a page, and mnml
applies its own http(s) rule to it. A `command` offer is run with the
pane that offered it focused, so a `Retry` lands on the pane that
failed rather than on whichever one is in front.

`integrations.retry_refresh` is the host command for exactly that: it
sends `r` — the refresh key every pane in the family binds — to the
focused integration pane.

The offer goes when the box does. It is attached to the message,
including the box a repeat coalesced into.

### `focus_item` — land the cursor on one thing

A pane that lists things is sent `{"focus_item":{"key":"…"}}` when a
statusline hover row names one of them and this pane is already the
open one. The key is the pane's own name for the thing — whatever it
accepts on its `--focus` flag, since the same row spells it the same
way both ways: on the argv when the pane has to be started, down the
socket when it is already there. Landing is the pane's to define
(open what was folded, switch tab, put the cursor on it, open its
detail); a key the pane does not hold is the pane's to answer, and
both official integrations say `not in this listing: <key>`.

### `session_state` — what happened to a session you started

A pane that dispatches Claude Code (an `[ Implement ]`, a `[ Merge ]`)
used to lose track of it the moment the line was written: the Bridge
carried input one way and nothing about the host's own state back, so a
button could only say "a session was started", never "it is running" or
"it finished". `watch_session` (below) asks to be told; this is the
answer, one line per **edge**:

| `state` | what the host saw |
|---|---|
| `running` | a process behind it, getting on with the work |
| `waiting` | a tool use with no result and the transcript quiet: it is asking the user something |
| `done` | no process any more, and the transcript did not end on an error |
| `failed` | no process, and it ended on an error |

`key` is the string the `watch_session` carried, echoed back untouched,
so a pane with many buttons knows which one moved. `session_id` is the
host's own name for the session once it has matched one — keep it and
send it back on a `focus-session`. `detail` is the session's last
output line, clipped: the question when it is `waiting`, the reason
when it `failed`.

```json
{"session_state":{"key":"acme/api#1234\u001fmerge","state":"waiting",
                  "session_id":"6f1c…","detail":"Shall I squash these?"}}
```

`hello.palette` (optional) carries the host theme's roles as colours —
`fg`, `bg`, `muted`, `accent`, `border`, `panel_bg`, `cursor_line`,
`chip_fg` / `chip_bg`, `chip_active_fg` / `chip_active_bg`, and the named
`red green yellow orange blue cyan purple comment` — each `{"rgb":[r,g,b]}`
/ `{"index":n}` or null. A sibling that paints with them looks native in
whatever theme it is mounted in; one that ignores them (or a host that
predates the field) gets the terminal palette through `Color.index` as
before.

### `InputEvent`

| tag | payload | notes |
|---|---|---|
| `key` | `{spec}` | mnml's key grammar: `a`, `A`, `enter`, `esc`, `ctrl+p`, `shift+f5`, `alt+left`, `space` |
| `click` | `{col, row, button}` | pane-relative cells; `button` ∈ `left`, `middle`, `right` |
| `scroll` | `{col, row, dy}` | one notch; `dy > 0` is up. mnml folds a burst into one event |
| `hover` | `{col, row}` | the pointer moved over the pane |
| `paste` | `{text}` | a bracketed paste |

```json
{"input":{"event":{"key":{"spec":"ctrl+k"}}}}
{"input":{"event":{"click":{"col":3,"row":4,"button":"left"}}}}
{"input":{"event":{"scroll":{"col":0,"row":0,"dy":-3}}}}
```

Which keys reach you: everything unmodified, and every modified chord
the user has not bound in mnml. `ctrl+c` / `ctrl+d` / `ctrl+z` /
`ctrl+l` are always yours. mnml's own chords (`ctrl+p`, the leader…)
are mnml's — the same rule as a terminal pane.

## Integration → host (`SiblingMessage`)

| tag | payload | notes |
|---|---|---|
| `frame` | `{cells: [[Cell]]}` | a whole screen: rows of cells; short rows are padded |
| `frame_dirty` | `{rows: [{y, cells}]}` | only the rows that changed since the last frame |
| `title` | string | the tab label |
| `cursor` | `{x, y}` or `null` | where the terminal cursor goes while focused; `null` hides it |
| `command` | `{id}` | run an mnml command by id (a built-in, or one you registered) |
| `toast` | `{level, text, action?}` | `level` ∈ `info`, `warn`, `error`; `action` since protocol 3 |
| `watch_session` | `{key, selector}` | "I started this session; tell me what it does" |
| `hover` | `{title, body}` | what the element under the pointer is and does, for the info view; `title:""` clears. Only to a host with `capabilities.hover_help` |
| `bye` | `{}` | a clean exit |

```json
{"title":"Jira · TE-12"}
{"cursor":{"x":4,"y":1}}
{"command":{"id":"file.save"}}
{"toast":{"level":"warn","text":"token expires in 2 days"}}
{"toast":{"level":"info","text":"merged #1234","action":{"label":"Open PR","url":"https://bitbucket.org/acme/api/pull-requests/1234"}}}
{"toast":{"level":"error","text":"refresh failed: 503","action":{"label":"Retry","command":"integrations.retry_refresh"}}}
{"hover":{"title":"assignee:","body":"Whose tickets show. Click opens a picker of the people on the tab."}}
{"watch_session":{"key":"ENG-2\u001ftriage",
                  "selector":{"cwd":"/Users/me/proj","prompt_line":"/agents:developer ENG-2"}}}
```

`selector` names the session the way the `focus-session` IPC verb does,
because they must find the same one: `id` when the host has already
given you one, else `cwd` **and** `prompt_line` together — the only two
names a dispatched `term` line can carry. The host matches the newest
session that fits, then sticks to it, so a second dispatch with the
same prompt does not steal the first button's answers. A second
`watch_session` under the same `key` replaces the first, which is what
a button pressed twice wants.

### `Cell`

```json
{"symbol":"a","fg":{"index":4},"bg":{"rgb":[30,30,46]},"mods":9}
```

* `symbol` — one grapheme. An **empty** symbol is a wide glyph's tail
  (or "leave this cell alone" in a dirty row): the host paints nothing
  there. Default `" "`.
* `fg` / `bg` — a `Color`, or absent for the theme's default.
* `mods` — a bit set, ratatui's `Modifier` layout so old numbers still
  mean the same: bold 1, dim 2, italic 4, underline 8, slow_blink 16,
  rapid_blink 32, reverse 64, hidden 128, strikethrough 256. Absent = 0.

Only what differs from the default needs to be on the wire; a blank
cell is `{"symbol":" "}`.

### Frames and backpressure

mnml keeps one grid per mount. A `frame` replaces it (and its size — the
grid takes the frame's shape, clipped to the pane at paint time); a
`frame_dirty` patches rows in place. The reader paints every message
into that grid as it arrives and asks for one repaint; nothing is
queued per frame, so an integration that streams faster than the
terminal paints simply has its frames coalesced — a dirty row is never
lost under a dropped frame, because nothing is dropped.

Send a full `frame` after `hello` and after every `resize`; send
`frame_dirty` for everything else. The SDK's `Frame` does this for you.

## Tier 2 — the file-IPC channel

`MNML_IPC_DIR` names the channel every mnml-spawned process may write
to, mount or not: append one JSON line to `<dir>/command`. The shapes
are mnml's `src/ipc/command.zig`; the ones an integration uses:

```json
{"cmd":"register-command","id":"jira.pick","title":"Jira: pick a ticket","group":"integrations","keys":["ctrl+k j"]}
{"cmd":"toast","text":"synced","level":"info"}
{"cmd":"toast-persistent","id":"jira-sync","text":"syncing…","level":"info"}
{"cmd":"toast-dismiss","id":"jira-sync"}
{"cmd":"progress-start","id":"p1","text":"Fetching"}   {"cmd":"progress-update","id":"p1","count":40}   {"cmd":"progress-end","id":"p1","text":"success"}
{"cmd":"statusline-set-segment","id":"jira","side":"right","text":"TE-12","priority":100,"min_width":4,"max_width":30}
{"cmd":"statusline-set-segment","id":"jira","text":"\uf0224 43","tooltip":"Jira \u00b7 43 open items assigned to me","items":[{"text":"ENG-12  Fix the login redirect","sub":"In Review","command":"jira_work.open"}]}
{"cmd":"set-activity-badge","section":"integrations","count":3}
{"cmd":"notify","title":"Jira","text":"assigned to you","level":"info","sound":false}
```

`items` is the list behind the figure — what the chip's number
counts, one row per thing. The hover paints the tooltip line as its
title and then one row per item, `text` in the foreground and `sub`
muted at the right; a left click on a row runs its `command`, with
`args` appended to that command's argv when the command mounts a
binary (`--focus <key>` and the like), so a row can open the thing it
names rather than only the pane that holds it — and when the pane that
command opens is ALREADY up, the key comes down this socket as
`focus_item` instead of a second pane opening beside the first. The host keeps at most
24 rows off the wire and paints at most `statusline.hover_items` (8 by
default), with `… and N more` for the rest; a row with no `text` is
dropped, not the line. Leave `items` out and the chip keeps the
one-line hover it always had.

A `register-command` id resolves in the palette, `.keys` and `.test`
scripts; when it runs, mnml writes a `plugin-command` line to
`<dir>/events.jsonl` — the integration tails that file. Over a mount
the same thing is `{"command":{"id":…}}` on the socket, which needs no
file.

## What changed from v1 (Rust `mnml-bridge` 0.8)

* Colours are externally tagged (`{"index":n}` / `{"rgb":[…]}`), never
  a bare integer or an array.
* `hello.protocol` exists; `hello.capabilities` and `hello.workspace`
  are new; `MNML_PROTOCOL=2` is in the environment.
* `frame_dirty`, `cursor`, `command`, `toast` are new messages;
  `focus`, `focus_item` and `hover` are new host messages.
* `mods` keeps ratatui's bit layout.
* The manifest is ZON, not TOML (`docs/SDK.md`).

The Rust crate stays published for 0.2.x hosts; a v1 integration does
not connect to a v2 host (the first message's `protocol` says so) and
must be rebuilt on the SDK.
