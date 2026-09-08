# Lua scripting — the `mnml` table

mnml-zig embeds Lua 5.4 (compiled from C inside `zig build`, bound through
zlua). Scripts extend the editor the way an `init.lua` extends Neovim, but
against a small, curated surface: every script can register commands, bind
keys, subscribe to hooks, read and edit buffers through the editor's own
`EditOp`s, add a statusline segment, feed the picker, open a pane it renders
itself, and run a shell command as a task. It cannot reach the file system,
the shell, or the network directly — `os`, `io`, `package`, `debug`,
`require`, `dofile` and `loadfile` are not there — and it never sees a
colour, a pointer, or `*App`.

`docs/examples/init.lua` is the reference script; every surface below appears
in it, and a unit test runs it.

## Where `init.lua` lives, and trust

| file | runs | when |
|---|---|---|
| `<data root>/init.lua` | always | at startup, before the `startup` hook |
| `<workspace>/.mnml/init.lua` | only when the workspace is trusted | after the user's, same moment |

The data root is `~/.config/mnml` (or `MNML_DATA_ROOT`, or the portable
directory beside the binary — `src/config/data_root.zig`). `script.edit_init`
opens the user's file in an editor, creating it on save; `script.reload`
drops everything a script registered (commands and their chords, hooks,
panes, segments, picker sources, task watches), reopens the Lua state, and
runs both files again. Reload is also what a workspace gets the moment it is
trusted.

A workspace `init.lua` is an exec-bearing claim in the trust dialog
(`src/config/trust.zig`, sink `init_lua`), beside the language servers and
formatters a `.mnml/config.zon` may name: a repo with the script and no
config still asks; adding a script to a trusted workspace asks again. There
is nothing to strip — the file simply does not run until the answer is
Trust.

## The budget, and errors

Every call into Lua — a chunk, a command, a hook, a render — runs under a
count hook that fires every 100 000 VM instructions and checks a 20 ms
deadline armed at the outermost entry. Past it the call is aborted with
`mnml: script budget exceeded`; the script sees it as an error, the user as
a toast, and the editor keeps running. `while true do end` in `init.lua`
costs one toast.

An error anywhere (a syntax error in the file, an `error()` call, a wrong
argument to an `mnml.*` function) is caught at the same boundary and toasted
with the chunk name, line and traceback. A command that errors also fails
the command (`error.Failed`), so a `.test` step or an IPC caller sees it. A
pane whose `render` errors paints the message in the pane instead of
toasting every frame.

Scripts run on the UI thread only, between events. There are no threads,
no timers and no coroutine scheduler; a statusline segment's function is
polled, a task's completion arrives through `on_done`.

## Reference

Arguments are checked; a wrong shape raises a Lua error naming the field.
`fn` is any Lua function. Strings are UTF-8 bytes.

### Commands and keys

```lua
mnml.command{ id = "hello", title = "Say hello", group = "user",
              keys = { "ctrl+shift+h" }, run = function() … end }  --> "user.hello"
mnml.map("ctrl+shift+n", function() … end)                          --> "user.map_1"
mnml.run("file.save")          --> true | false, reason   (any command id, built-in or script)
mnml.ex("w")                   --> true | false, reason   (a `:` line without the colon)
```

`mnml.command` registers a dynamic command under `user.<id>` — that is the
name in the palette, in `.keys` bindings, in a `.test` script's `command`
step and over IPC. `title` defaults to the id, `group` to `user`. `keys` is
a chord spec or a list of them, in the grammar `docs/KEYMAP_PROFILES.md`
describes (`ctrl+shift+h`, `space u n`, `<C-p>`); the chords survive an
input-style switch and a config reload. Registering the same id again
replaces the runner and its keys. A script id can never shadow a built-in:
the prefix sees to that.

`mnml.map` is a command with a generated id bound to one chord.

### Hooks

```lua
mnml.on("save_post", function(a) … end)
```

The payload `a` is a flat table with the hook's fields plus `hook = "<name>"`:

| hook | fields | fires |
|---|---|---|
| `startup` | — | once, after every `init.lua` and the startup tasks |
| `exit` | — | on quit |
| `open` | `path`, `pane` | a file opened in an editor pane |
| `save_pre` | `path`, `pane` | before the bytes are written |
| `save_post` | `path`, `pane`, `bytes` | after |
| `buffer_change` | `pane`, `line_count` | 150 ms after the last edit |
| `diagnostics` | `path`, `errors`, `warnings` | a language server published |
| `pane_focus` | `pane` (nil when nothing is focused) | focus moved |
| `lsp_attach` | `server`, `pane` | a server took a buffer |
| `git_status` | `branch`, `dirty` | the status refreshed |
| `http_request` | `pane`, `method`, `url`, `headers`, `body` (nil when there is none), `env` (the active env's name, or nil) | a request pane is about to send — see below |
| `http_response` | `pane`, `status`, `headers`, `body`, `body_truncated`, `timing_ms` | a response landed on a request pane |

`path` is workspace-relative. A hook that errors toasts; the other
subscribers still run. Subscribers are Zig's and then the scripts', in
subscription order.

#### The HTTP hooks

```lua
mnml.on("http_request", function(a)
  a.headers["X-Env"] = a.env or "none"                       -- add one
  a.url = a.url:gsub("^http://", "https://")                 -- rewrite
  return a                                                   -- what returns is what is sent
end)
mnml.on("http_response", function(a)
  if a.status == 401 then mnml.http.set_var("TOKEN", "") end
end)
```

`headers` is a table of name → value (a repeated name keeps the last).
An `http_request` subscriber that **returns a table** replaces the
request's `method`, `url`, `headers` and `body` with the fields the table
has — `headers` replaces the whole set, so add to `a.headers` and return
`a`; `body = false` sends no body. A subscriber that returns nothing
changes nothing; a later subscriber's field wins over an earlier one's.

The order, before a send: the block's `@set-*` directives, then the
`{{VAR}}` expansion, then `http_request` — so a subscriber sees the
request as it would go on the wire, and what it returns goes out as-is
(a `{{VAR}}` in a returned field is not expanded; the cookie jar's
`Cookie` header is added by the transport after the hook). After a
response: the cookies into the jar, the schema sidecar, the block's
`@assert` / `@capture` directives, then `http_response` — so
`mnml.http.set_var` lands after the captures and never under them. The
Timeline tab of the response lists the headers as they went out.

Only a request pane's sends fire the hooks — `http.send`, `r` on the
response, `mnml.http.send` — not chains, the env fan-out, bench or the
`mnml run` CLI. A replayed mock (`http.replay_mock`) fires
`http_response`. A response body past 1 MB reaches the subscriber cut
there, with `body_truncated = true` (the 20 ms budget stays); the wire's
own 16 MB cut sets the flag too.

```lua
mnml.http.set_var("TOKEN", value)   --> true | false, reason
mnml.http.send(pane?)               --> true | false, reason
```

`set_var` writes `NAME=value` into the active env file — the one
`@capture` writes: the file that already holds the name, else
`.mnml/env/<env>.env`, created when new. The name is `[A-Za-z0-9_]`, the
value one line. `send` fires the request pane (the active one without a
pane id). Called from inside `http_response` the send waits until the
hook returns — a retry after a refreshed token; the script guards the
loop. From inside `http_request` it is an error: the send it would start
is the one in flight.

### Buffers

```lua
mnml.buf.text(pane?)            --> the whole text
mnml.buf.line(n, pane?)         --> line n (1-based) or nil
mnml.buf.line_count(pane?)
mnml.buf.cursor(pane?)          --> line, col (1-based), byte (0-based)
mnml.buf.path(pane?)            --> workspace-relative path, nil for a scratch buffer
mnml.buf.apply({ op = …, … }, pane?)  --> true when the text changed
```

`pane` is a pane id (as `mnml.pane.active()` returns); without it the active
editor pane is meant, and it is an error when there is none.

`apply` is the only way a script changes text, and it goes through the same
`EditOp` the keys produce — so undo, dot-repeat, the change list, the LSP
`didChange` and tree-sitter's incremental reparse all see it. `op` names
the tag (`src/editor/edit_op.zig` lists all 131); the payload follows:

| shape | ops | fields |
|---|---|---|
| none | `move_left`, `select_all`, `delete_line`, `undo`, `redo`, `indent`, `toggle_line_comment`, `yank_selection`, `paste`, … | — |
| a string | `insert_str`, `replace_selection` | `text` |
| a char | `insert_char`, `replace_char_at_cursor`, `select_inner_quote`, `delete_surround`, … | `ch = "x"` |
| an integer | `move_to_line`, `move_to_col`, `set_cursor_byte`, `yank_lines_count`, `move_visual_*` | `value`, or `line` / `col` / `byte` / `count` / `width` |
| a struct | `replace_range` (`start`, `end`, `text`), `join_lines` (`keep_space`), `move_paragraph` (`forward`), `surround_selection` (`open`, `close`, `pad`), `change_number_at_cursor` (`delta`), `reflow_paragraph` (`width`), `find_char_on_line` (`ch`, `forward`, `before`, `inclusive`, `repeat`), … | the struct's fields; defaults apply |
| composed | `select_range` (`start`, `end` — bytes), `atomic` (`ops = { … }`), `repeat` (`count`, `inner`) | one undo step |

`end` is a Lua keyword: write `["end"] = 5`.

### Toasts, the statusline

```lua
mnml.toast("text", "info" | "warn" | "error")
print(...)                                   -- a toast too
mnml.statusline.segment{ id = "notes", side = "right", fn = function() return "notes 3" end }
```

The segment's `fn` is polled every 250 ms; return nil to hide it. `side`
is `left` or `right` — both sit in the right-hand cluster of the
statusline, `left` ones at its inner edge, `right` ones after the built-in
chips (branch, diagnostics, AI meter). Registering an id again replaces
its function.

### The picker

```lua
mnml.picker.source{ id = "notes", title = "Notes", items = function(query)
  return { { label = "…", detail = "…", on_accept = function(label) … end }, "a plain label", … }
end }
mnml.picker.open("notes", query?)
```

`items(query)` runs once when the picker opens (with `query` or `""`); the
picker's own fuzzy filter narrows the rows as the user types. Enter calls
the row's `on_accept(label)`; Esc drops the rows.

### Script panes

```lua
local id = mnml.pane.open{
  title = "Notes",
  render = function(w, h) return rows end,
  on_hit = function(id, button) … end,   -- optional
  on_key = function(name) … return true end,  -- optional
}
mnml.pane.close(id)
mnml.pane.active()   --> the focused pane's id, or nil
mnml.redraw()        -- ask for a frame (a key or click already implies one)
```

`render(w, h)` is called every frame with the pane's text area and returns
up to `h` rows. A row is a string, or a list of segments; a segment is a
string or `{ text=, fg=, bg=, bold=, italic=, underline=, hit= }`. `fg` and
`bg` name a theme role — `fg`, `muted`, `accent`, `error`, `warn`, `info`,
`border`, `gutter`, `selection`, `match`, `cursor_line`, `chip`,
`chip_active`, `title`, and the syntax slots `syn_comment`, `syn_string`,
`syn_keyword`, `syn_function`, `syn_type`, `syn_number`, `syn_constant`,
`syn_operator`, `syn_punctuation`, `syn_property`, `syn_variable`,
`syn_escape` (`src/ui/script_view.zig`). An unknown role paints plain text.
Rows past the bottom and text past the right edge are clipped.

A segment with `hit = n` is a click target: a press on it calls
`on_hit(n, "left" | "right" | "middle")`. While the pane is focused every
key goes to `on_key(name)` first — `name` is the chord spec (`j`, `ctrl+p`,
`enter`, `space`); return true to consume it, anything else lets it fall
through to the chord chain (`space f f` still works from a script pane).
The wheel arrives as `wheel_up` / `wheel_down`.

### Tasks

```lua
mnml.task.run{ cmd = "zig build", cwd = "sub/dir", label = "build",
               on_done = function(r) … end }   --> the pane id
```

The one way a script reaches the shell. `cmd` runs through `/bin/sh -c` in
a task pane below the active one, at `cwd` (workspace-relative or absolute;
the workspace by default). `on_done{ ok, code }` — or `{ ok = false,
signal }` — fires from the app's tick once the child exits.

### The config, the workspace

```lua
mnml.config.get("editor.tab_width")      --> 4
mnml.config.get("lsp.rust.cmd")          --> "rust-analyzer"
mnml.config.get("keys.global")           --> { ["ctrl+p"] = "picker.files", … }
mnml.config.get("tools.jira.url")        --> a Dynamic section, walked the same way
mnml.config.get()                        --> the whole merged config as nested tables
mnml.workspace()                         --> the absolute workspace path
mnml.data_root()
```

`get` is a read-only copy of the merged ZON config (the three layers, after
trust): structs become tables, maps become tables keyed by name, enums
become strings, optionals nil, lists 1-based. A path into a list uses a
1-based index (`lsp.rust.extensions.2`). Nothing a script changes in the
returned table reaches the config.

## What is deliberately not there

- No `os`, `io`, `package`, `debug`; no `require`, `dofile`, `loadfile`.
  A script is one file.
- No colour values: roles only, so a script looks right in every theme.
- No `*App`, no raw buffer pointer: reads are copies, writes are `EditOp`s.
- No threads, timers or blocking calls; nothing runs off the UI thread.
- No reload from inside a script (`script.reload` is a command for the user).

## Testing a script

`tests/e2e/lua_init.test` shows the shape: `write .mnml/init.lua "…"`,
`command script.reload`, then `command user.<id>` and `expect screen
contains …`. The `.test` runner's temp workspace is trusted, so the
workspace file runs. Unit tests reach the state as `app.script()` and run
chunks with `runString`.
