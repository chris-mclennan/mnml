---
title: The API
description: Drive a running mnml from any shell with mnml remote, decide what a program may do through one prompt, and let a Claude Code session in an mnml pane use mnml as its IDE with no setup.
---

Every running mnml serves a local socket. Anything in one of its panes,
or any shell on the same machine, can talk to it: open a file in it, run
one of its commands, ask what it has open. Nothing that changes more
than the view happens without you saying yes.

The same socket is what a Claude Code session in an mnml pane uses to
treat mnml as its IDE.

## `mnml remote`

`mnml remote` — or `mnml r` for short — is the shell client:

```text
mnml remote open PATH[:LINE[:COL]]
mnml remote run COMMAND-ID
mnml remote status
mnml remote panes
mnml remote ping
mnml remote instances
mnml remote call METHOD [JSON]
```

| Verb | What it does |
| ---- | ------------ |
| `open PATH[:LINE[:COL]]` | Opens the file in the active pane, at the line and column if you give them. |
| `run COMMAND-ID` | Runs one of mnml's commands — any id from the [command reference](/docs/reference/commands). It asks you first unless the command only changes the view. |
| `status` | The instance's status. |
| `panes` | The open panes. |
| `ping` | A round trip, to check that mnml answers. |
| `instances` | Every mnml running on the machine. |
| `call METHOD [JSON]` | Any method of the API, raw, with its parameters as JSON. |

For example, from a shell beside a test failure:

```text
mnml r open src/parser.zig:120:8
mnml r run git.refresh
```

Three flags go before the verb:

- `--json` prints the result as JSON, exactly as mnml sent it — for
  scripts.
- `--instance PID` picks the mnml with that process id.
- `--workspace PATH` picks the mnml open on that workspace.

### Which mnml it talks to

Each running mnml leaves a small marker file naming its process id, its
workspace and its socket, and removes it when it exits. `mnml remote`
takes the first of these that matches:

1. **The mnml it runs in.** Every terminal pane tells its programs where
   its own mnml's socket is, so a command run in a pane always reaches
   the mnml that pane belongs to — and acts as that pane.
2. **`--instance` or `--workspace`**, if you gave one.
3. **The directory you are in.** The mnml whose workspace holds the
   current directory (the closest one, if workspaces nest).
4. **The only one running.**

If none of these picks one — nothing is running, or several are and
nothing tells them apart — it stops with exit code 3 and prints the candidates — process id, workspace and start
time — so you can pick one with `--instance` or `--workspace`. A marker
left behind by an mnml that is no longer running is cleaned up by
whoever finds it.

### Exit codes

| Code | Meaning |
| ---- | ------- |
| `0` | Done. |
| `1` | The method failed — no such command, for instance. The reason is on stderr. |
| `2` | Usage: a missing or unknown verb or argument. |
| `3` | No mnml found, or several and none matched. |
| `4` | Not permitted: the caller is not an mnml pane, or the API is off. |
| `5` | You said no, or nobody answered within two minutes. |
| `7` | Protocol mismatch: an mnml that does not speak this version of the API, or no such method. |

## What a program may do

Every command has an **effect class**, listed for each one in the
[command reference](/docs/reference/commands):

| Class | What it can touch |
| ----- | ----------------- |
| `view` | Only what you see. |
| `edit` | A buffer. |
| `write` | The disk, git, the network, config. |
| `exec` | A process. |

A `view` command asked for over the API runs at once. Anything above it
waits for you:

- A **toast** says who is asking and for what — for example
  `pane 4 · zsh asks to run git.commit (write)` — with a **Review**
  button. It never takes the key you are typing.
- **Review** opens a confirm box with four answers: **Allow once**,
  **Allow *write* for the session** (named for the class asked for),
  **Deny**, and **Cancel**, which puts the request back on its toast to
  answer later.
- A request nobody answers in **two minutes** is denied.

A grant for the session covers that one class, for the pane that asked,
until the pane closes. Closing a pane denies whatever it was waiting on.

Only a program running in one of mnml's own panes can ask at all. Each
pane hands its programs a private token, so mnml knows which pane is
calling and names it in the toast. A connection from anywhere else — a
shell in another terminal, say — may read the status, list the commands
and ping, and nothing more: `open`, `panes` and `run` from there exit
with code 4.

### Letting things through unasked

There is no Settings row for this; it goes in `config.zon`:

```zig
.api = .{
    .allow_commands = .{ "git.refresh" },
    .clients = .{ .{ .name = "file-channel", .allow = .{ .edit }, .commands = .{ "test.run_file" } } },
},
```

`.api.allow_commands` lists commands that run without asking, for any
caller allowed to ask in the first place.
Each `.api.clients` row names a caller — `pane:<id>` for a pane,
`file-channel` for the file channel below — and the classes and
commands it may use unasked. The
[configuration reference](/docs/config/reference) has the details.

### The audit trail

Every decision — run freely, allowed by the config, allowed once or for
the session, denied, timed out — is one line in
`<workspace>/.mnml/ipc/audit.jsonl`, readable only by you.

### The file channel

mnml also reads commands a program appends to
`<workspace>/.mnml/ipc/command`. That channel asks the same way, through
the same toast and confirm box, and writes to the same audit file.

## Claude Code, with no setup

A Claude Code session that mnml starts in one of its panes links to mnml
as its IDE, the way it would link to an editor plugin. There is nothing
to install or configure: mnml prepares the link when it starts the pane.
It is made only for panes mnml started as Claude Code sessions — a
`claude` typed into a shell pane, a Codex pane or a plain shell gets no
link — and only while the API is on.

Each session gets a link of its own, so mnml always knows which session
is asking.

### What the session can do

- **Read your selection** — what is selected in the editor you are in,
  or in the last one you used.
- **See what is open** — the workspace, the open editors, and which of
  them have unsaved changes.
- **Read diagnostics** from your language servers, for one file or all
  of them.
- **Open a file**, optionally with a passage selected.
- **Propose a change.** The proposed file opens in the review pane
  beside your buffer, titled with the session's name, diffed against the
  buffer as it stands — unsaved edits included. Accept the hunks you
  want and press Enter: they go into the buffer as one undo step, **the
  file is saved**, and the session is told so. Esc, `q`, closing the
  tab, or Enter with nothing accepted rejects the proposal. A second
  proposal for the same file replaces the first.
- **Ask to save a file.** Saving is a `write`, so it asks you through
  the same toast as a command, unless you have allowed `write` for that
  session.

The proposal is the one change that does not ask first, because your
review of it is the approval.

The review opens where it leaves the session in view. It becomes a tab
in the split that holds the file, or else in a split showing an editor.
When the session is the only split on screen, a new split opens beside
it. Accepting, rejecting or pressing Esc puts the focus back on the
session. To choose a different placement, set `ai.review_placement` or
use its row in Settings ▸ AI: `.beside` always opens a split beside the
session, and `.tab` opens the review as a tab of the focused split, as
earlier versions did.

What it **cannot** do is run code through the link: mnml refuses that
request.

### What you see

- A link mark, **`⇄`** (`=` with `--ascii`), after the session's name on
  its tab while the link is up, and in the gutter beside its card in the
  **SESSIONS** section of the sidebar when no other mark is showing
  there.
- A toast the first time the session connects:
  `Claude Code connected to mnml (pane 4)`.

### Your selection

As you select text in an editor, mnml tells **one** linked session about
it: the one whose pane you looked at most recently. With several
sessions open, look at the one you mean before you select.

`ai.send_selection` goes a step further and points that session at the
selected lines — or the cursor's line, with nothing selected — so you
can ask about them by name. See [AI sessions](/docs/features/ai) for the
sessions themselves.

Every call a session makes goes through the same gate as the socket and
is a line in the audit file.

## Turning it off

Settings → **Integrations** → **API**: `on` / `off`. Off, mnml serves no
socket, `mnml remote` cannot reach it, and Claude Code sessions are not
linked. In `config.zon` it is `.api.enabled`.
