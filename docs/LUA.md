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

## Writing the file in the editor

**Save reloads.** A save of either `init.lua` runs `script.reload`
through the `save_post` hook; the toast counts what came back
(`scripts: reloaded — 2 commands, 1 hook`). A syntax or runtime error
that names a line of one of the files lands in that file's diagnostics
beside a language server's — the gutter dot, the squiggle, the
DIAGNOSTICS row — and in one persistent toast whose click jumps to the
line. A hook that fails later replaces it; a clean reload clears it.

**The app completes its own API.** In an `init.lua` (or any `.lua` under
`.mnml/`) the completion popup fills from the app itself: after `mnml.` /
`mnml.buf.` the functions of the table, after `mnml.on("` the hooks,
inside `mnml.run("` / `mnml.map("…", "` the command ids, inside
`mnml.map("` and `keys = { "` the key specs one token at a time, inside
`fg = "` / `bg = "` the theme roles. `K` (`lsp.hover`) on a command id
shows its title and chords, on an API path its doc line, on a hook name
its fields. `lua-language-server`, when installed, keeps the rest of the
file — it is in the default server table.

**Run a line.** `script.run_selection` (vim `<leader>sr`, standard
`ctrl+alt+enter`) runs the selected lines — or the cursor line — in the
script state: an expression first (`x + 1` answers its value), a
statement chunk otherwise. What comes back is the toast.

**The SCRIPTS section.** The rail's 󰢱 entry (`view.activity_scripts`)
lists everything the scripts registered — `cmd user.hello`, `hook
save_post`, `seg clock`, `pick recent` — with the `file:line` of the
call. Enter (or a double-click) opens the file at that line; `r` reloads;
`n` creates the workspace file from the commented template when there
is none (the `+ create init.lua` row does the same on Enter); the filter
narrows by name. A right-click on a row — or its `⋮` — is the row's
menu: *Run* and *Bind in init.lua…* for a command, *Open file:line*,
*Copy id*, *Reload scripts*. The header's `⟳` reloads; its right-click
is the auto-refresh menu.

**Bind in init.lua…** is also on a right-click over a command in the
palette (`ctrl+shift+p`): it asks for a key spec, refuses one the keymap
cannot parse, and appends `mnml.map("<spec>", "<id>")` on a new last
line of the workspace `init.lua` — the template first when there is
none — then reloads the file in its editor when it is open and clean
(refused while it has unsaved changes: the write would sit under the
buffer) and reloads the scripts, so the chord works at once.

## Reference

Arguments are checked; a wrong shape raises a Lua error naming the field
and the shape it wanted. `fn` is any Lua function. Strings are UTF-8
bytes.

**Changed in.** `api = 1` is the contract, and it is still changing: a
function or a field marked *(api 1, added)* arrived after the first `1`
shipped. Nothing has been removed or changed in place; when `1` is
frozen this page says so.

### Commands and keys

```lua
mnml.command{ id = "hello", title = "Say hello", group = "user",
              keys = { "ctrl+shift+h" }, run = function() … end }  --> "user.hello"
mnml.map("ctrl+shift+n", function() … end)                          --> "user.map_1"
mnml.map("ctrl+shift+s", "file.save")        --> the chord runs that command (what *Bind in init.lua…* writes)
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

`mnml.map` is a command with a generated id bound to one chord. Its second
argument may be a command id instead of a function — built-in or script —
and the chord then runs it through `mnml.run`.

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
| `cursor_idle` | `pane`, `line` (1-based) | 300 ms after the cursor last moved, once per resting place *(api 1, added)* |
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
mnml.task.run{ cmd = "eslint --format compact -- app.js", hidden = true,
               on_line = function(text) … end,
               on_done = function(r) … end }   --> the run's id
```

The one way a script reaches the shell. `cmd` runs through `/bin/sh -c` in
a task pane below the active one, at `cwd` (workspace-relative or absolute;
the workspace by default). `on_done{ ok, code }` — or `{ ok = false,
signal }` — fires from the app's tick once the child exits.

**`hidden = true`** *(api 1, added)* runs it with **no pane at all** and
hands its output to **`on_line(text)`** *(api 1, added)*, a line at a time
as it arrives — the shape a tool wrapper wants, where the output is only
ever parsed. A hidden run's stderr is merged into its stdout (there is no
pane to read it in), its lines arrive stripped of the newline, and it is
capped at 5000 lines of 4 KiB each; past that the run still finishes and
still calls `on_done`. Each `on_line` is its own entry into the script, so
the 20 ms budget applies per line, not per run. `on_line` without `hidden`
is an error: a visible task's output is its pane.

### Decorations

*(api 1, added)* Everything visible a script adds to an editor is one of
four decorations. They live in a **namespace** the script owns, so it can
clear its own without touching anyone else's.

```lua
local ns = mnml.decor.namespace("blame")            -- one per concern
mnml.decor.virtual_text(ns, pane, line, { { text = "  chris · 3d ago", fg = "muted" } }, { at = "eol" })
mnml.decor.gutter(ns, pane, line, "▎", { fg = "accent", priority = 50 })
mnml.decor.highlight(ns, pane, start_byte, end_byte, "match")
mnml.decor.line(ns, pane, line, "cursor_line")
mnml.decor.clear(ns, pane)        --> how many went; without a pane, all of them
```

`ns` is the handle `namespace(name)` answers with — the same name always
gives the same handle until the next reload. `pane` is a pane id (as
`mnml.pane.active()` returns) and must name an **editor**; nil means the
active pane. `line` is 1-based, as `mnml.buf.line` and `mnml.buf.cursor`
count; `start_byte` / `end_byte` are 0-based bytes, `end_byte` exclusive.
A role is a theme role name — the same list script panes use, and an
unknown one paints plain. A wrong argument raises an error naming the
argument and the shape it wanted.

`segments` is the script pane's segment shape: a string, or a list of
strings and `{ text=, fg=, bg=, bold=, italic=, underline= }` tables.

| function | changed in |
|---|---|
| `mnml.decor.namespace` | api 1, added |
| `mnml.decor.virtual_text` | api 1, added |
| `mnml.decor.gutter` | api 1, added |
| `mnml.decor.highlight` | api 1, added |
| `mnml.decor.line` | api 1, added |
| `mnml.decor.clear` | api 1, added |

`at` says where the text goes:

| `at` | where |
|---|---|
| `"eol"` (the default) | after the line's last cell, clipped at the pane's right edge |
| `"above"` | a virtual row above the line |
| `"below"` | a virtual row below the line |

A virtual row is counted by the scroll math and never carries the cursor:
`j` / `k` move by text lines, so they step over it, exactly as they do
over a code lens.

**A decoration is data, not a callback.** The renderer reads what is
there; Lua is never entered from the paint loop, which is why the 20 ms
budget cannot be spent painting. Set your decorations from a hook
(`cursor_idle`, `save_post`, a task's `on_done`) and leave them.

**They follow the text.** Every decoration is anchored to a byte, not to
a line number, and the anchor moves with each edit: a line inserted
**above** a decorated line takes the decoration down with its own text,
an edit that **deletes** the line the decoration named takes the
decoration with it, and an **undo** — a change the edit log cannot
describe — puts back what it removed, decorations included. A pane that
opens another file drops what was painted about the old one.

**The sign column is shared**, so a gutter mark carries a `priority`
(0…255) and the highest wins the cell:

| priority | who |
|---|---|
| 90 | the debugger's breakpoints and its ▶ stop marker |
| 60 | a diagnostic's severity dot |
| **50** | **`mnml.decor.gutter`'s default** |
| 10 | git's change bars (which sit in the gutter's other column anyway) |

A namespace holds at most 10000 decorations across the workspace; past
that a set is an error naming the cap. `script.reload` drops every
namespace with the Lua state.

### Diagnostics

*(api 1, added)* A script publishes findings the way a language server
does, and the editor treats them identically — the gutter dot, the
squiggle, the statusline count, the DIAGNOSTICS panel and `]d` / `[d`,
with `source` as the origin:

```lua
mnml.diagnostics.set(ns, "src/app.js", {
  { line = 12, col = 5, end_col = 9, severity = "warning", message = "unused", source = "eslint" },
})
mnml.diagnostics.clear(ns, "src/app.js")   -- without a path: every file's
```

`path` is workspace-relative (or absolute). `line` and `col` are 1-based;
`end_col` defaults to one column past `col`. `severity` is `"error"`,
`"warning"`, `"info"` or `"hint"` (`"error"` by default). `message` is
required; `source` is what the panel and `]d` name as the origin.

| function | changed in |
|---|---|
| `mnml.diagnostics.set` | api 1, added |
| `mnml.diagnostics.clear` | api 1, added |

The store is keyed by `(namespace, path)`: a set **replaces this
namespace's list for that file** and leaves every other namespace's — and
the language server's — alone. An empty list is how a run that found
nothing clears what the last one found. A reload clears them all.

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

## Recipes

Two scripts that ship with mnml, each the whole of one shape. They live
under `docs/examples/scripts/`; paste one into your `init.lua`
(`script.edit_init`) and reload. Each is driven by a `.test` that runs
the file as it is written, so a change that breaks one fails the suite.

### `git-blame-line` — who last touched this line

`docs/examples/scripts/git-blame-line.lua` (56 lines). Virtual text at
the end of the cursor's line, refreshed when the cursor stops
(`cursor_idle`) and when a pane takes focus (`pane_focus`), from a
hidden `git blame` run:

```
   1 alpha   Tester Ttt 1 second ago
   2 beta
   3 gamma
```

The pieces worth stealing: one namespace per concern, so the clear is
safe; `pcall` around `mnml.buf.path` because not every focused pane is
an editor; and a `<path>:<line>` key so the same line is never asked
about twice and two runs are never in flight at once.

### `eslint` — a tool wrapper into the diagnostics sink

`docs/examples/scripts/eslint.lua` (45 lines). On `save_post` for a
`.js` / `.jsx` / `.ts` / `.tsx` file it runs `eslint --format compact`
as a hidden task, turns each output line into a diagnostic and publishes
the lot under its own namespace:

```
●  1 //const x = 1;                     │ DIAGNOSTICS (2)
   2 const y = 2;                       │ ⚠ 'x' is assigned …  … app.js:1
●  3 const z = 3;                       │ ✗ 'z' is not defin…  … app.js:3
```

`]d` then says `warning (eslint): 'x' is assigned a value but never
used`. The pieces worth stealing: `hidden = true` because there is
nothing to watch, a `on_line` parse that simply ignores what does not
match (the tool's summary line), and a `set` on every run — including
the empty one that clears a file the tool is now happy with.

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

A test that drives a script **file** rather than an inline one copies it
in with a `shell` step; the repo root reaches the step through the
header, because a shell resets `PWD` to its own cwd:

```
# env: MNML_REPO=${PWD}
shell mkdir -p .mnml && cp "${MNML_REPO:?}/docs/examples/scripts/eslint.lua" .mnml/init.lua
```

`tests/e2e/lua_example_eslint.test` and `lua_example_git_blame_line.test`
do exactly that, which is what keeps the two recipes above true.
