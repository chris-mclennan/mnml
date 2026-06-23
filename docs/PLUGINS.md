# mnml plugins (the file-IPC protocol)

A **plugin** is an *out-of-process* program — bash, python, a tiny binary, whatever —
that talks to a running mnml over the file-IPC channel. It is **not** loaded code:
no Lua, no WASM, no shared library, no in-process "extension host". A plugin can
register commands (they show up in the palette / which-key / keymap), subscribe to
events, and send any IPC command. It **cannot** add a new `Pane` kind, a new
`EditOp`, render code, or a from-scratch keymap — those are core changes by design.

(Want something compiled *into* mnml because it needs a heavy dep or renders its own
UI panel? That's a **Cargo feature**, not a plugin — different mechanism.)

**Sibling tool integrations** (`mnml-forge-*`, `mnml-aws-*`, etc.)
are launched via `:term <binary>` and run as regular Pty panes
inside mnml. They render their own TUI using crossterm and own
their dependency tree. No special protocol — just standalone
binaries that happen to be useful next to an editor.

## The channel

When mnml opens a workspace it creates `<workspace>/.mnml/ipc/`:

| file | direction | contents |
|---|---|---|
| `command` | host → mnml | JSONL — append one command object per line |
| `events.jsonl` | mnml → host | append-only log of what happened (one JSON object per line) |
| `screen.txt` | mnml → host | the most recent rendered virtual screen, as text |
| `status.json` | mnml → host | a snapshot: focus, panes, active file, cursor, mode, tree state |

mnml **truncates `command` and `events.jsonl` on startup**, so a plugin should
`tail -F` (capital F — follow by name, survive truncation) rather than holding a
file descriptor open.

## Sending commands

Append a JSON object (one line, no embedded newlines) to `.mnml/ipc/command`:

```jsonc
{"cmd":"register-command","id":"plugin.foo","title":"Do the foo","group":"plugin","keys":["ctrl+alt+f"]}
{"cmd":"run-command","id":"file.save"}        // run any registered command (builtin or plugin)
{"cmd":"open","path":"src/main.rs"}           // path relative to the workspace, or absolute
{"cmd":"key","key":"ctrl+s"}                  // inject a key by spec ("down","enter","ctrl+shift+p",…)
{"cmd":"type","text":"hello\nworld"}          // type literal text into the focused pane ("\n" ⇒ Enter)
{"cmd":"snapshot"}                            // force a fresh screen.txt / status.json
{"cmd":"quit"}                                // quit mnml (bypasses the unsaved-changes guard)
{"cmd":"restart"}                             // quit with the restart exit code (run.sh rebuilds + relaunches)
```

`register-command`: only `id` is required. `title` defaults to the id, `group` to
`"plugin"`, `keys` to none. Registering the same id again replaces it. Bad keyspecs
are ignored. Registered commands appear in the command palette (`Ctrl+Shift+P` / `F1`)
and resolve as keybindings; they don't appear in the static which-key trie.

## Reacting to events

Tail `.mnml/ipc/events.jsonl`. Every command you send produces an event, plus mnml
logs its own activity. The one a plugin usually cares about:

```jsonc
{"event":"plugin-command","id":"plugin.foo"}   // your registered command was invoked (palette / key / run-command)
```

Others you'll see: `{"event":"command_registered","id":…,"title":…}`,
`{"event":"command_run","id":…,"ok":true}`, `{"event":"open","path":…}`,
`{"event":"key","key":…}`, `{"event":"type","text":…}`, `{"event":"snapshot"}`,
`{"event":"start",…}`, `{"event":"exit",…}`.

So the loop is: **register your command → tail events → on `plugin-command` for your
id, do your thing (often: send more IPC commands).**

## Reading state

`status.json` is rewritten every frame. Shape (fields may grow):

```jsonc
{
  "focus": "pane",                 // "tree" | "pane"
  "activePane": 0,                 // index, or null
  "activeFile": "/abs/path.rs",    // "" if the active pane isn't a file editor
  "cursor": { "line": 12, "col": 3 },   // 1-based; {0,0} if no editor
  "mode": "none",                  // "none" | "NORMAL" | "INSERT" | "VISUAL"
  "treeCursor": 4,
  "treeSelection": "/abs/path",
  "treeVisible": true,
  "panes": [ { "title": "main.rs", "dirty": false }, … ],
  "quit": false
}
```

`screen.txt` is the rendered TUI as plain text (rows, trailing spaces trimmed) — handy
for assertions or "what's on screen right now" logic.

## Example

`examples/plugins/insert-timestamp.sh` — registers `plugin.timestamp` (bound to
`ctrl+alt+t`); when invoked, sends `{"cmd":"type","text":"<ISO-8601 now>"}` so the
timestamp lands at the cursor. Run it alongside mnml:

```sh
./run.sh ~/proj &                              # mnml on a workspace
examples/plugins/insert-timestamp.sh ~/proj    # the plugin (keep it running)
# now: Ctrl+Shift+P → "Insert timestamp", or Ctrl+Alt+T
```

## Notes / limits

- One mnml instance ↔ one `.mnml/ipc/` dir ↔ any number of plugins (they all append to
  `command` and tail `events.jsonl`).
- There's no request/response — a plugin "asks" by appending a command and "hears back"
  by tailing events. Keep that asynchrony in mind.
- mnml processes the `command` file line-by-line each loop tick; partial trailing lines
  are left for the next tick, so always write a complete `…}\n`.
- The same channel powers headless mode (`mnml --headless`) and is the substrate for the
  `.test` E2E format — a plugin and a test driver speak the same protocol.
