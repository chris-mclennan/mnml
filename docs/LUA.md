# Lua scripting — the `mnml` table

mnml-zig embeds Lua 5.4 (compiled from C inside `zig build`, bound through
zlua). A script extends the editor the way an `init.lua` extends any editor
that takes one, but against a small, curated surface: it registers commands
and binds keys, subscribes to hooks, reads and edits buffers through the
editor's own `EditOp`s, paints decorations, publishes diagnostics, adds a
statusline segment, feeds the picker, opens a pane or a rail section it
renders itself, registers an operator, and runs a shell command as a task.

It cannot reach the file system, the shell or the network directly — `os`,
`io`, `package`, `debug`, `dofile` and `loadfile` are not there — and it
never sees a colour, a pointer, or the app.

**This page is the reference.** One section per `mnml.*` area, every
function with its signature, a runnable example, when it arrived, and the
argument errors as they read on screen. The five shipped example scripts
are the [Recipes](#recipes) chapter. `docs/examples/init.lua` is a single
file that touches every surface, and a unit test runs it.

A function registered in `src/scripting/api.zig` and missing from this page
— or written here and not registered — fails the test suite
(`src/scripting/doc_check.zig`), so the two cannot drift.

## Contents

| | |
|---|---|
| [The two `init.lua` files, and trust](#the-two-initlua-files-and-trust) | where a script lives and what it is allowed to do |
| [The budget, and errors](#the-budget-and-errors) | 20 ms per entry; what happens past it |
| [Writing a script in the editor](#writing-a-script-in-the-editor) | save-reloads, completion, hover, run-a-line |
| **Reference** | |
| [Commands and keys](#commands-and-keys) | `command` `map` `run` `ex` `commands` |
| [Hooks](#hooks) | `on`, the hook table, the two HTTP hooks, `http.set_var` `http.send` |
| [Buffers](#buffers) | `buf.text` `line` `line_count` `cursor` `path` `apply` `selection` `range` `word_at` |
| [Decorations](#decorations) | `decor.namespace` `virtual_text` `gutter` `highlight` `line` `clear` |
| [Diagnostics](#diagnostics) | `diagnostics.set` `clear` |
| [Toasts and the statusline](#toasts-and-the-statusline) | `toast` `print` `inspect` `statusline.segment` |
| [The picker](#the-picker) | `picker.source` `picker.open` |
| [Lists and sections](#lists-and-sections) | `list` `section` |
| [Panes](#panes) | `pane.open` `pane.close` `pane.active` `redraw` |
| [Operators](#operators) | `operator` |
| [Tasks](#tasks) | `task.run` |
| [The config and the workspace](#the-config-and-the-workspace) | `config.get` `workspace` `data_root` |
| **Around the API** | |
| [The `script.*` commands](#the-script-commands) | what the user runs |
| [Installing scripts](#installing-scripts) | a script as a directory; the three tabs; trust |
| [Publishing a script](#publishing-a-script) | the manifest, the README, the marketplace |
| [Recipes](#recipes) | the five shipped examples |
| [What is deliberately not there](#what-is-deliberately-not-there) | and why |
| [Testing a script](#testing-a-script) | the `.test` shape |

**Changed in.** `api = 1` is the contract, and it is still changing: a
function or field marked *(api 1, added)* arrived after the first `1`
shipped. Nothing has been removed or changed in place. When `1` is frozen
this page says so.

## The two `init.lua` files, and trust

| file | runs | when |
|---|---|---|
| `<data root>/init.lua` | always | at startup, before the `startup` hook |
| `<workspace>/.mnml/init.lua` | only when the workspace is trusted | after the user's, same moment |

The data root is `~/.config/mnml` (or `MNML_DATA_ROOT`, or the portable
directory beside the binary — `src/config/data_root.zig`).

A workspace `init.lua` is an exec-bearing claim in the trust dialog
(`src/config/trust.zig`, sink `init_lua`), beside the language servers and
formatters a `.mnml/config.zon` may name: a repo with the script and no
config still asks; adding a script to a trusted workspace asks again. There
is nothing to strip — the file simply does not run until the answer is
Trust.

Both files are **one file each, with no `require`**. A script you want to
split across files, version and share is an [installed
script](#installing-scripts) instead: a directory with a manifest, its own
Lua state, and a `require` scoped to its own folder.

## The budget, and errors

Every call into Lua — a chunk, a command, a hook, a render, one line of a
hidden task's output — runs under a count hook that fires every 100 000 VM
instructions and checks a **20 ms deadline** armed at the outermost entry.
Past it the call is aborted with `mnml: script budget exceeded`; the user
sees a toast, and the editor keeps running. `while true do end` in an
`init.lua` costs one toast.

The abort cannot be caught. A script's own `pcall` / `xpcall` rethrow it
rather than returning `false`, and from the moment it trips every further
instruction raises it again, so `while true do pcall(loop) end` ends the
same way the bare loop does. An `xpcall` message handler is not run for it.

A pattern match is covered too: the matcher behind `string.find`, `match`,
`gmatch` and `gsub` checks the budget itself, so a quadratic pattern over
a long string is cut inside the call rather than after it. Other library
calls are cut at the next instruction after they return; their cost is
linear (or n log n) in data the script built or a size it named.

The 20 ms is the SHIPPED build's, and it is a frame budget. Most of what
it bounds is host code — `mnml.commands()` walks eleven hundred command
specs and builds a table per row — and unoptimized host code is not a
little slower but much slower: the `recent-commands` example below needs
under 20 ms in a shipped build and over 400 ms in a Debug one. So a Debug
build gets a runaway budget (2 s) rather than a frame budget: long enough
that no finite script trips it, short enough that `while true do end`
still costs one toast. A script that fits in a release build fits in a
debug one.

A script that trips it wears a `⏱ N` chip on its SCRIPTS row — the count for
this session — so a slow script is visible before it is annoying.
`script.doctor` spells the same count out.

An error anywhere (a syntax error in the file, an `error()` call, a wrong
argument to an `mnml.*` function) is caught at the same boundary and toasted
with the chunk name, line and traceback. A command that errors also fails
the command (`error.Failed`), so a `.test` step or an IPC caller sees it. A
pane whose `render` errors paints the message in the pane instead of
toasting every frame.

Scripts run on the UI thread only, between events. There are no threads, no
timers and no coroutine scheduler; a statusline segment's function is
polled, a task's completion arrives through `on_done`.

**Argument errors name the call, the argument and the shape.** Every
`mnml.*` function checks its arguments before it allocates anything, and
says what it wanted:

```
mnml.picker.source: `items` must be a function(query) returning a table of rows
mnml.list: `sort` must be a table of mode names — { "State", "Name" }; the chip cycles them and `rows(sort)` is handed the current one
bad argument #3 to 'gutter' (line must be a 1-based line number, as mnml.buf.cursor() counts)
```

The `bad argument #N to '<fn>'` form is Lua's own frame, used by the
positional helpers the decoration calls share: it names the position and the
function together, which a fixed prefix could not. Every function's own
messages are quoted in its section below.

## Writing a script in the editor

**Save reloads.** A save of either `init.lua` runs `script.reload` through
the `save_post` hook; the toast counts what came back (`scripts: reloaded —
2 commands, 1 hook · 1 file(s) loaded`). A syntax or runtime error that
names a line of one of the files lands in that file's diagnostics beside a
language server's — the gutter dot, the squiggle, the DIAGNOSTICS row — and
in one persistent toast whose click jumps to the line. A hook that fails
later replaces it; a clean reload clears it.

**The app completes its own API.** In an `init.lua` (or any `.lua` under
`.mnml/`) the completion popup fills from the app itself: after `mnml.` the
sub-tables first — `buf`, `statusline`, `picker`, `pane`, `task`, `config`,
`http`, `decor`, `diagnostics` — then the root functions; after `mnml.buf.`
that table's functions; after `mnml.on("` the hooks; inside `mnml.run("` /
`mnml.map("…", "` the command ids; inside `mnml.map("` and `keys = { "` the
key specs one token at a time; inside `fg = "` / `bg = "` the theme roles.
`K` (`lsp.hover`) on a command id shows its title and chords, on an API path
its doc line, on a hook name its fields. `lua-language-server`, when
installed, keeps the rest of the file — it is in the default server table.

**Run a line.** `script.run_selection` (vim `<leader>sr`, standard
`ctrl+alt+enter`) runs the selected lines — or the cursor line — in the
script state: an expression first (`x + 1` answers its value), a statement
chunk otherwise. What comes back is the toast. With
[`mnml.inspect`](#mnmlinspectv) it is a debugger.

---

# Reference

Arguments are checked; `fn` is any Lua function; strings are UTF-8 bytes.
Positions are **bytes, 0-based, `end` exclusive**; line numbers are
**1-based**. `end` is a Lua keyword, so a field called `end` is written
`["end"]`.

## Commands and keys

A command is the unit the palette, the `:` line, a chord, a menu row, a
`.test` step and IPC all name. A script's commands are prefixed `user.`,
which is why one can never shadow a built-in.

#### `mnml.command{ id, title?, group?, keys?, run }`

Registers a palette command under `user.<id>` and binds the chords it
declares. Answers with the full id.

```lua
local id = mnml.command{
  id = "hello",
  title = "Say hello",
  keys = { "ctrl+shift+h" },        -- a chord spec, or a list of them
  run = function() mnml.toast("hello from init.lua") end,
}
assert(id == "user.hello")
```

`title` defaults to the id, `group` to `"user"`. `keys` is a chord spec or a
list, in the grammar `docs/KEYMAP_PROFILES.md` describes (`ctrl+shift+h`,
`space u n`, `<C-p>`); the chords survive an input-style switch and a config
reload. Registering the same id again replaces the runner and its keys.

*Changed in: api 1.*

```
mnml.command takes one table: { id, title?, group?, keys?, run }
mnml.command: `id` is required and must be a bare name — "hello" becomes the command user.hello
mnml.command: `id` must be a bare name — letters, digits and `_`, no spaces or dots ("hello" becomes user.hello)
mnml.command: `run` must be a function() — what the palette row, the chord and `:user.<id>` all run
```

#### `mnml.map(spec, fn_or_id)`

A command with a generated id (`user.map_N`) bound to one chord. The second
argument may be a command id instead of a function — built-in or script —
and the chord then runs it through `mnml.run`. This is what the palette's
*Bind in init.lua…* row writes.

```lua
mnml.map("ctrl+shift+n", function() mnml.picker.open("notes") end)
mnml.map("ctrl+shift+s", "file.save")
```

*Changed in: api 1.*

```
mnml.map: the first argument is a chord spec, a string ("ctrl+shift+n", "space u n")
mnml.map: the second argument is a function(), or a command id as a string ("file.save")
mnml.map: the second argument names no command — `file.saev` is not an id mnml.commands() lists
```

#### `mnml.run(id)`

Runs any command, built-in or script. Answers `true`, or `false` and the
reason (which the app has already toasted).

```lua
local ok, why = mnml.run("file.save")
if not ok then mnml.toast("could not save: " .. why, "warn") end
```

*Changed in: api 1.*

```
mnml.run: takes a command id, a string ("file.save", "user.hello" — mnml.commands() lists them)
```

#### `mnml.ex(line)`

A `:` line without the colon. Answers `true`, or `false` and the reason.

```lua
mnml.ex("w")                        -- :w
mnml.ex("e src/app.zig")            -- :e src/app.zig
```

*Changed in: api 1.*

```
mnml.ex: takes a `:` line without the colon, a string ("w", "e src/app.zig")
```

#### `mnml.commands(query?)`

Every command the app knows, built-in and script, as
`{ id, title, group, keys, rank }`. `query` narrows it by a case-insensitive
substring on the id or the title; without one, all of them. `keys` holds the
chords it answers to under the active profile. `rank` is its place in the
MRU — 1 is the command run most recently, and a command never run has **no**
`rank`, so `if c.rank then` reads as the question it is.

```lua
for _, c in ipairs(mnml.commands("save")) do
  mnml.toast(c.id .. (c.rank and (" · run " .. c.rank .. " ago") or ""))
end
```

The MRU is the app's own — the one the palette and `picker.recent_commands`
order by — so a command run from a chord, a menu or a `:` line counts, and
only a command that *succeeded* is in it.

*Changed in: api 1, added. `rank`: api 1, added.*

```
mnml.commands: takes a query, a string — a substring of an id or a title; without one, every command
```

## Hooks

#### `mnml.on(hook, fn)`

Subscribes to one of the app's hooks. The payload is a flat table of that
hook's fields plus `hook = "<name>"`.

```lua
mnml.on("save_post", function(a)
  mnml.toast(a.path .. " saved (" .. a.bytes .. " bytes)")
end)
```

| hook | fields | fires |
|---|---|---|
| `startup` | — | once, after every `init.lua` and the startup tasks |
| `exit` | — | on quit |
| `open` | `path`, `pane` | a file opened in an editor pane |
| `save_pre` | `path`, `pane`, `auto` (true when an autosave is writing it, not a save you asked for) | before the bytes are written |
| `save_post` | `path`, `pane`, `bytes` | after |
| `buffer_change` | `pane`, `line_count` | 150 ms after the last edit |
| `cursor_idle` | `pane`, `line` (1-based) | 300 ms after the cursor last moved, once per resting place *(api 1, added)* |
| `diagnostics` | `path`, `errors`, `warnings` | a language server published |
| `pane_focus` | `pane` (nil when nothing is focused) | focus moved |
| `lsp_attach` | `server`, `pane` | a server took a buffer |
| `git_status` | `branch`, `dirty` | the status refreshed |
| `http_request` | `pane`, `method`, `url`, `headers`, `body`, `env` | a request pane is about to send — see below |
| `http_response` | `pane`, `status`, `headers`, `body`, `body_truncated`, `timing_ms` | a response landed on a request pane |

`path` is workspace-relative. A hook that errors toasts; the other
subscribers still run. Subscribers are Zig's and then the scripts', in
subscription order.

*Changed in: api 1.*

```
mnml.on: the first argument is a hook name, a string
mnml.on: the second argument is a function(args) — args is a flat table of the hook's fields plus hook = "<name>"
mnml.on: `on_save` is not a hook — the names are startup, exit, open, save_pre, save_post, buffer_change, cursor_idle, diagnostics, pane_focus, lsp_attach, git_status, http_request, http_response
```

That last list is built from the hook enum, so it can never name a hook that
is gone or miss one that is new.

### The two HTTP hooks

```lua
mnml.on("http_request", function(a)
  a.headers["X-Env"] = a.env or "none"                 -- add one
  a.url = a.url:gsub("^http://", "https://")           -- rewrite
  return a                                             -- what returns is what is sent
end)
mnml.on("http_response", function(a)
  if a.status == 401 then mnml.http.set_var("TOKEN", "") end
end)
```

`headers` is a table of name → value (a repeated name keeps the last). An
`http_request` subscriber that **returns a table** replaces the request's
`method`, `url`, `headers` and `body` with the fields the table has —
`headers` replaces the whole set, so add to `a.headers` and return `a`;
`body = false` sends no body. A subscriber that returns nothing changes
nothing; a later subscriber's field wins over an earlier one's.

The order, before a send: the block's `@set-*` directives, then the
`{{VAR}}` expansion, then `http_request` — so a subscriber sees the request
as it would go on the wire, and what it returns goes out as-is (a `{{VAR}}`
in a returned field is not expanded; the cookie jar's `Cookie` header is
added by the transport after the hook). After a response: the cookies into
the jar, the schema sidecar, the block's `@assert` / `@capture` directives,
then `http_response` — so `mnml.http.set_var` lands after the captures and
never under them.

Only a request pane's sends fire the hooks — `http.send`, `r` on the
response, `mnml.http.send` — not chains, the env fan-out, bench or the
`mnml run` CLI. A replayed mock (`http.replay_mock`) fires `http_response`.
A response body past 1 MB reaches the subscriber cut there, with
`body_truncated = true`.

#### `mnml.http.set_var(name, value)`

Writes `NAME=value` into the active env file — the one `@capture` writes:
the file that already holds the name, else `.mnml/env/<env>.env`, created
when new. Answers `true`, or `false` and the reason.

```lua
local ok, why = mnml.http.set_var("TOKEN", "abc123")
```

The name is `[A-Za-z0-9_]`, the value one line.

*Changed in: api 1.*

```
mnml.http.set_var: the first argument is the variable name, a string of [A-Za-z0-9_]
mnml.http.set_var: the second argument is the value, a string of one line
```

#### `mnml.http.send(pane?)`

Fires a request pane — the active one without an argument. Answers `true`,
or `false` and the reason.

```lua
mnml.on("http_response", function(a)
  if a.status == 401 and not retried then
    retried = true
    mnml.http.send(a.pane)          -- the send waits until the hook returns
  end
end)
```

Called from inside `http_response` the send waits until the hook returns — a
retry after a refreshed token; the script guards the loop. From inside
`http_request` it is an error: the send it would start is the one in flight.

*Changed in: api 1.*

```
mnml.http.send: takes a pane id, an integer — the request pane to fire; without one, the active pane
mnml.http.send: there is no pane 99
mnml.http.send: pane 0 is not a request pane (open a .http / .curl / .rest file)
mnml.http.send: not from inside http_request (that send is the one in flight)
```

## Buffers

`pane` is a pane id (as `mnml.pane.active()` answers); without it the active
editor pane is meant, and it is an error when there is none. Every read is a
copy; every write is an `EditOp`.

```
mnml.buf: `pane` must be a pane id (what mnml.pane.active() answers with); 7 is not one
mnml.buf: `pane` must name an editor pane; pane 3 is not one
mnml.buf: no active editor pane — pass a pane id, or open a file first
```

#### `mnml.buf.text(pane?)`

The whole text of the buffer.

```lua
local n = #mnml.buf.text()
```

*Changed in: api 1.*

#### `mnml.buf.line(n, pane?)`

Line `n` (1-based) without its newline, or nil past the end.

```lua
local line = mnml.buf.line(select(1, mnml.buf.cursor()))
```

*Changed in: api 1.*

```
mnml.buf.line: the first argument is a 1-based line number
```

#### `mnml.buf.line_count(pane?)`

How many lines the buffer has.

```lua
mnml.toast(mnml.buf.line_count() .. " lines")
```

*Changed in: api 1.*

#### `mnml.buf.cursor(pane?)`

Three returns: `line`, `col` (both 1-based) and `byte` (0-based).

```lua
local line, col, byte = mnml.buf.cursor()
```

*Changed in: api 1.*

#### `mnml.buf.path(pane?)`

The workspace-relative path, or nil for a scratch buffer.

```lua
local p = mnml.buf.path()
if p and p:match("%.ts$") then mnml.toast("typescript") end
```

*Changed in: api 1.*

#### `mnml.buf.apply(op, pane?)`

**The only way a script changes text.** It goes through the same `EditOp`
the keys produce, so undo, dot-repeat, the change list, the LSP `didChange`
and tree-sitter's incremental reparse all see it. Answers `true` when the
text changed.

```lua
mnml.buf.apply{ op = "insert_str", text = "hello" }
mnml.buf.apply{ op = "replace_range", start = 0, ["end"] = 5, text = "HELLO" }
mnml.buf.apply{ op = "atomic", ops = {                  -- one undo step
  { op = "set_cursor_byte", byte = 0 },
  { op = "insert_str", text = "-- " },
} }
```

`op` names the tag (`src/editor/edit_op.zig` lists all 131); the payload
follows its shape:

| shape | ops | fields |
|---|---|---|
| none | `move_left`, `select_all`, `delete_line`, `undo`, `redo`, `indent`, `toggle_line_comment`, `yank_selection`, `paste`, … | — |
| a string | `insert_str`, `replace_selection` | `text` |
| a char | `insert_char`, `replace_char_at_cursor`, `select_inner_quote`, `delete_surround`, … | `ch = "x"` |
| an integer | `move_to_line`, `move_to_col`, `set_cursor_byte`, `yank_lines_count`, `move_visual_*` | `value`, or the tag's own name: `line` / `col` / `byte` / `count` / `width` |
| a struct | `replace_range` (`start`, `end`, `text`), `join_lines` (`keep_space`), `move_paragraph` (`forward`), `surround_selection` (`open`, `close`, `pad`), `change_number_at_cursor` (`delta`), `reflow_paragraph` (`width`), `find_char_on_line` (`ch`, `forward`, `before`, `inclusive`, `repeat`), … | the struct's fields; defaults apply |
| composed | `select_range` (`start`, `end`), `atomic` (`ops = { … }`), `repeat` (`count`, `inner`) | one undo step |

*Changed in: api 1.*

```
mnml.buf.apply takes one table: { op = "<tag>", … } — see the op table in docs/LUA.md
mnml.buf.apply: `op` is required and must be an edit-op tag, a string ("insert_str", "replace_range", "undo")
mnml.buf.apply: `op` names no edit op — `nope` is not one of the tags in src/editor/edit_op.zig (docs/LUA.md lists them by shape)
mnml.buf.apply: `insert_str` needs `text`, a string
mnml.buf.apply: `move_to_line` needs an integer `value` (or its own name for the field: line / col / byte / count / width)
mnml.buf.apply: `replace_range` needs `end`, an integer
mnml.buf.apply: select_range needs `start` and `end`, both byte offsets (0-based, `end` exclusive; `end` is a Lua keyword, so write ["end"])
mnml.buf.apply: atomic needs `ops`, a list of op tables — { ops = { { op = "…" }, … } }
mnml.buf.apply: repeat needs `inner`, one op table — { op = "repeat", count = 3, inner = { op = "…" } }
```

#### `mnml.buf.selection(pane?)`

`{ start, ["end"], mode }`, or nil when nothing is selected. `mode` is
`"char"`, `"line"` or `"block"` — the shape the handler is in, the one
handler-derived fact a script sees; a modeless (standard) selection is
always `"char"`.

```lua
local s = mnml.buf.selection()
if s then
  local text = mnml.buf.range(s.start, s["end"])
  mnml.buf.apply{ op = "replace_range", start = s.start, ["end"] = s["end"],
                  text = "«" .. text .. "»" }
end
```

*Changed in: api 1, added.*

#### `mnml.buf.range(start, end_, pane?)`

The text between two bytes. Both ends are clamped to the buffer and a
reversed pair reads the same span, so a position kept from before an edit
still answers instead of raising.

```lua
local word = mnml.buf.range(0, 5)
```

*Changed in: api 1, added.*

```
bad argument #1 to 'range' (start must be a byte offset, an integer (0-based, `end` exclusive; mnml.buf.cursor() answers with one))
bad argument #1 to 'range' (start must be a byte offset, 0 or more (0-based, `end` exclusive))
```

#### `mnml.buf.word_at(byte?, pane?)`

`{ text, start, ["end"] }` for the word under `byte` — the cursor's without
one — or nil when that byte is not in a word.

```lua
local w = mnml.buf.word_at()
if w then mnml.toast(w.text) end
```

It uses vim's `iw` classes (a run of word characters, or a run of
punctuation) less the third: a run of whitespace is not a word, so the space
between two words is in neither.

*Changed in: api 1, added.*

```
bad argument #1 to 'word_at' (byte must be a byte offset, an integer (0-based, `end` exclusive; mnml.buf.cursor() answers with one))
```

## Decorations

Everything visible a script adds to an editor is one of four decorations.
They live in a **namespace** the script owns, so it can clear its own
without touching anyone else's.

**A decoration is data, not a callback.** The renderer reads what is there;
Lua is never entered from the paint loop, which is why the 20 ms budget
cannot be spent painting. Set your decorations from a hook (`cursor_idle`,
`save_post`, a task's `on_done`) and leave them.

**They follow the text.** Every decoration is anchored to a byte, not to a
line number, and the anchor moves with each edit: a line inserted **above** a
decorated line takes the decoration down with its own text, an edit that
**deletes** the line the decoration named takes the decoration with it, and
an **undo** puts back what it removed, decorations included. A pane that
opens another file drops what was painted about the old one.

A namespace holds at most 10000 decorations across the workspace; past that
a set is an error naming the cap. `script.reload` drops every namespace with
the Lua state.

The positional arguments these six share:

```
bad argument #1 to 'gutter' (ns must be a handle from mnml.decor.namespace(name))
bad argument #2 to 'line' (pane must name an editor pane)
bad argument #2 to 'line' (pane must be a pane id (mnml.pane.active()); there is no active pane)
bad argument #3 to 'line' (line must be a 1-based line number, as mnml.buf.cursor() counts)
```

#### `mnml.decor.namespace(name)`

The handle every other `decor` and `diagnostics` call takes — one per
concern. The same name always gives the same handle until the next reload.

```lua
local ns = mnml.decor.namespace("blame")
```

*Changed in: api 1, added.*

```
bad argument #1 to 'namespace' (mnml.decor.namespace(name) takes a name, a string)
bad argument #1 to 'namespace' (a namespace name cannot be empty)
```

#### `mnml.decor.virtual_text(ns, pane, line, segments, opts?)`

Text beside — or over, or under — a line. `segments` is a string, or a list
of strings and `{ text=, fg=, bg=, bold=, italic=, underline= }` tables.

```lua
mnml.decor.virtual_text(ns, pane, 1,
  { { text = "  chris · 3d ago", fg = "muted" } }, { at = "eol" })
```

| `at` | where |
|---|---|
| `"eol"` (the default) | after the line's last cell, clipped at the pane's right edge |
| `"above"` | a virtual row above the line |
| `"below"` | a virtual row below the line |

A virtual row is counted by the scroll math and never carries the cursor:
`j` / `k` move by text lines, so they step over it, exactly as they do over a
code lens.

*Changed in: api 1, added.*

```
bad argument #4 to 'virtual_text' (segments must be a string or a list of { text=, fg=, bg=, bold=, italic=, underline= })
bad argument #5 to 'virtual_text' (the options are a table: { at = "eol" | "above" | "below" })
bad argument #5 to 'virtual_text' (at is "eol", "above" or "below")
mnml.decor.virtual_text: too many decorations (the cap is 10000; clear a namespace)
```

#### `mnml.decor.gutter(ns, pane, line, glyph, opts?)`

One cell in the sign column.

```lua
mnml.decor.gutter(ns, pane, 3, "▎", { fg = "accent", priority = 50 })
```

The sign column is shared, so a mark carries a `priority` (0…255) and the
highest wins the cell:

| priority | who |
|---|---|
| 90 | the debugger's breakpoints and its ▶ stop marker |
| 60 | a diagnostic's severity dot |
| **50** | **`mnml.decor.gutter`'s default** |
| 10 | git's change bars |

*Changed in: api 1, added.*

```
bad argument #4 to 'gutter' (glyph must be a string of one cell ("▎", "●"))
bad argument #5 to 'gutter' (the options are a table: { fg = role, priority = n })
bad argument #5 to 'gutter' (priority is 0…255 (50 by default; breakpoints 90, diagnostics 60, git 10))
```

#### `mnml.decor.highlight(ns, pane, start_byte, end_byte, role)`

A theme role over a byte range.

```lua
local s = mnml.buf.selection()
if s then mnml.decor.highlight(ns, pane, s.start, s["end"], "match") end
```

*Changed in: api 1, added.*

```
bad argument #3 to 'highlight' (start_byte must be a byte offset, an integer (0-based, `end` exclusive; mnml.buf.cursor() answers with one))
mnml.decor.highlight: role must be a theme role name, a string ("accent", "error", "syn_string", … — never a colour)
```

#### `mnml.decor.line(ns, pane, line, role)`

A whole-row ground.

```lua
mnml.decor.line(ns, pane, 3, "cursor_line")
```

*Changed in: api 1, added.*

```
mnml.decor.line: role must be a theme role name, a string ("accent", "error", "syn_string", … — never a colour)
```

#### `mnml.decor.clear(ns, pane?)`

Drops the namespace's decorations — all of them, or only the ones in one
pane. Answers how many went.

```lua
mnml.decor.clear(ns)
```

*Changed in: api 1, added.*

## Diagnostics

A script publishes findings the way a language server does, and the editor
treats them identically — the gutter dot, the squiggle, the statusline
count, the DIAGNOSTICS panel and `]d` / `[d`, with `source` as the origin.

The store is keyed by `(namespace, path)`: a set **replaces this namespace's
list for that file** and leaves every other namespace's — and the language
server's — alone. An empty list is how a run that found nothing clears what
the last one found. A reload clears them all.

#### `mnml.diagnostics.set(ns, path, list)`

```lua
mnml.diagnostics.set(ns, "src/app.js", {
  { line = 12, col = 5, end_col = 9, severity = "warning",
    message = "'x' is assigned a value but never used", source = "eslint" },
})
```

`path` is workspace-relative (or absolute). `line` and `col` are 1-based;
`end_col` defaults to one column past `col`. `severity` is `"error"`,
`"warning"`, `"info"` or `"hint"` (`"error"` by default). `message` is
required; `source` is what the panel and `]d` name as the origin.

*Changed in: api 1, added.*

```
bad argument #2 to 'set' (path must be a string (workspace-relative, or absolute))
bad argument #3 to 'set' (the list is a table of { line, col, end_col?, severity, message, source })
bad argument #3 to 'set' (every diagnostic is a table: { line, col, end_col?, severity, message, source })
bad argument #3 to 'set' (a diagnostic needs `line`, a 1-based line number)
bad argument #3 to 'set' (a diagnostic needs `message`, a string)
bad argument #3 to 'set' (severity is "error", "warning", "info" or "hint")
```

#### `mnml.diagnostics.clear(ns, path?)`

This namespace's list for one file, or — without a path — for every file.

```lua
mnml.diagnostics.clear(ns, "src/app.js")
```

*Changed in: api 1, added.*

```
bad argument #2 to 'clear' (path must be a string (workspace-relative, or absolute))
```

## Toasts and the statusline

#### `mnml.toast(text, level?)`

One toast. `level` is `"info"` (the default), `"warn"` or `"error"`.

```lua
mnml.toast("nothing to do", "warn")
```

*Changed in: api 1.*

```
mnml.toast: the first argument is the text, a string
mnml.toast: the second argument is the level, one of "info", "warn", "error"
mnml.toast: the level is "info", "warn" or "error"
```

**`print(...)` toasts too**, with the arguments tab-joined the way Lua's own
`print` joins them. `print` is the log.

#### `mnml.inspect(v)`

Any value as a string, for reading. Tables are walked four deep (the
outermost counted) with the array part in order and every other key sorted;
anything deeper reads `{…}`, and a table that names itself reads `<cycle>`
instead of running until the budget stops it. It prints nothing itself —
pair it with `print` or `mnml.toast`.

```lua
mnml.on("save_post", function(a) print(mnml.inspect(a)) end)
--> { bytes = 11, hook = "save_post", pane = 0, path = "notes.txt" }
```

Sorted keys make it deterministic, which is what makes it worth printing:
the same table reads the same on two runs, and a `.test` can pin it.

*Changed in: api 1, added.*

```
mnml.inspect(v) takes one value — any type, nil included
```

#### `mnml.statusline.segment{ id, side?, fn }`

A segment of the script's own. `fn()` is polled every 250 ms; returning nil
hides it. `side` is `"left"` or `"right"` — both sit in the right-hand
cluster, `left` ones at its inner edge, `right` ones after the built-in chips
(branch, diagnostics, AI meter). Registering an id again replaces its
function.

```lua
mnml.statusline.segment{ id = "notes", side = "right",
  fn = function() return #notes > 0 and ("notes " .. #notes) or nil end }
```

*Changed in: api 1.*

```
mnml.statusline.segment takes one table: { id, side?, fn }
mnml.statusline.segment: `id` is required and must be a name of your own — registering it again replaces the segment
mnml.statusline.segment: `fn` must be a function() returning the text — nil hides the segment; it is polled every 250 ms
mnml.statusline.segment: `side` is "left" or "right"
```

## The picker

#### `mnml.picker.source{ id, title?, items, live?, multi?, preview?, on_accept? }`

Registers a source of rows. A row is a string, or a table
`{ label=, detail=, icon=, data=, on_accept= }`. `icon` is one glyph before
the label, in the accent. `data` is yours: the whole row table is handed back
to `preview` and `on_accept` untouched.

```lua
mnml.picker.source{
  id = "recent",
  title = "Recent commands",
  live = true,
  items = function(query)
    local rows = {}
    for _, c in ipairs(mnml.commands(query)) do
      rows[#rows + 1] = { label = c.title, detail = c.id, data = c }
    end
    return rows
  end,
  preview = function(row) return { { { text = row.data.id, fg = "muted" } } } end,
  on_accept = function(row) mnml.run(row.data.id) end,
}
```

**`live = true`** asks `items(query)` again as the query changes, debounced
80 ms, so a typed word is one call and not one per key. The previous call's
rows stay on screen until the new ones land: the list never blanks while a
source is thinking. Without `live` the source is asked exactly once, when the
picker opens, and the picker's own fuzzy filter narrows from there.

**`preview = fn(row)`** paints the picker's right-hand column with rows in
the script pane's segment shape. The box widens to make room: results left, a
`│` rule, the preview right. It is called when the cursor moves, never from
the paint loop. A box too narrow for two columns keeps all its width for the
rows.

**`multi = true`** makes `Tab` mark the row under the cursor and step on; a
marked row shows a `✓`. Enter then hands `on_accept` the **list** of marked
rows — with nothing marked, the one under the cursor, still as a list, so the
function has one shape to read.

**`on_accept`** on the source is handed the row table (or the list). A
per-row `on_accept(label)` still fires first, so a source may use either or
both.

*Changed in: api 1. `live`, `multi`, `preview`, `on_accept`, and a row's
`icon` and `data`: api 1, added.*

```
mnml.picker.source takes one table: { id, title?, items, live?, multi?, preview?, on_accept? }
mnml.picker.source: `id` is required and must be a name of your own — mnml.picker.open takes it back
mnml.picker.source: `items` must be a function(query) returning a table of rows — a row is a string, or { label, detail?, icon?, data?, on_accept? }
mnml.picker.source: `preview` must be a function(row) returning rows of segments for the preview column
mnml.picker.source: `on_accept` must be a function(row) — or function(rows), the marked ones, when multi = true
```

#### `mnml.picker.open(id, query?)`

Opens the picker over a source's rows, with `query` already typed.

```lua
mnml.command{ id = "recent", run = function() mnml.picker.open("recent") end }
```

*Changed in: api 1.*

```
mnml.picker.open: the first argument is a source id, a string — the `id` mnml.picker.source{} was given
mnml.picker.open: the second argument is the starting query, a string
mnml.picker.open: no source `nope` — mnml.picker.source{ id = … } registers one, and a reload drops them
```

## Lists and sections

`mnml.list{}` hands a script the panel every built-in section is — the caps
header with the refresh and `sort:` chips, the filter pill, `j` / `k` / `g` /
`G` / Enter, the fold headers, the scrollbar, the row menu, the hits — and
asks only for rows.

#### `mnml.list{ title, rows, on_enter?, on_menu?, sort? }`

Answers a handle: `{ id = n, refresh = fn }`, so `l:refresh()` reads.

```lua
local l = mnml.list{
  title = "TODOS",
  sort = { "State", "Name" },
  rows = function(sort)
    return {
      { header = "src/app.zig", count = 1 },
      { label = "widen the column", detail = "src/app.zig:2", icon = "•" },
    }
  end,
  on_enter = function(row) mnml.ex("e " .. row.detail:gsub(":%d+$", "")) end,
  on_menu = function(row)
    return { { label = "Copy", run = function() mnml.toast(row.label) end } }
  end,
}
l:refresh()
```

A row is a string, or one of two tables:

| shape | fields |
|---|---|
| a fold header | `{ header = "src/app.zig", count = 3 }` |
| an item | `{ label=, detail=, icon=, state= }` |

`detail` is muted and right-aligned, clipped from the left so its tail (a
line number, a file) survives; `icon` is one glyph in the accent before the
label; `state` is a short word in a chip after it. A header folds on Enter
(or a click) and hides its items until the next header; `E` opens every fold,
`C` closes every one, and a fold survives a refresh that answers the same
header.

`rows(sort)` is called when the list is made, when `l:refresh()` runs, when
the `⟳` chip is clicked and when the sort changes — never per frame, because
Lua is never entered from the paint loop. `sort` is the current mode's name
from your `sort` list (nil when you named none). Sorting is yours: the names
are labels, and `rows` answers in whatever order the mode means.

`on_enter(row)` is Enter (and a second click) on an item; `on_menu(row)`
answers with the row's menu, which the `⋮` and a right-click open, with the
panel's own *Refresh* under it. `row` carries the fields you wrote plus
`index`, its 1-based place in what `rows()` answered (a fold does not shift
it).

*Changed in: api 1, added.*

```
mnml.list takes one table: { title, rows, on_enter?, on_menu?, sort? }
mnml.list: `title` is required and must be the caps header's words, a string ("TODOS")
mnml.list: `rows` must be a function(sort) returning a table of rows — a row is a string, { header, count } or { label, detail?, icon?, state? }
mnml.list: `sort` must be a table of mode names — { "State", "Name" }; the chip cycles them and `rows(sort)` is handed the current one
mnml.list: `on_enter` must be a function(row) — Enter, and a second click, on an item
mnml.list: `on_menu` must be a function(row) returning { { label, run = fn }, … } — the row's ⋮ menu
```

#### `mnml.section{ id, title?, glyph?, ascii?, list, side?, after? }`

Puts a row of the script's own on the activity bar and hosts a list in that
side's column, with the caps header, the filter, the sort chip and the folds
TODOS has — indistinguishable from a built-in section.

```lua
mnml.section{ id = "todos_lua", title = "TODOS (lua)", glyph = "󰄬", ascii = "T",
              list = l, side = "left", after = "todos" }
```

`glyph` is the rail icon and `ascii` its twin for `ui.ascii_icons`; `after`
names the section its row sits under (`after = "todos"`; no `after` puts it
last). It appears in `rects.json` like any section (`rail:script:0`,
`row:script:2`, `chip:script:refresh`), and `script.reload` drops the
section, its rail row and the list behind it. One column hosts them: several
registered sections each get their own rail row, and the one whose row was
clicked last is the one the column shows.

Every built-in section has a `view.activity_*` command; a script's gets one
too — `user.<id>` — so the palette, `.keys` and a `.test` can reach it.

*Changed in: api 1, added.*

```
mnml.section takes one table: { id, title?, glyph?, ascii?, list, side?, after? }
mnml.section: `id` is required and must be a bare name — it also becomes the command user.<id> that shows the section
mnml.section: `id` must be a bare name — letters, digits and `_`, no spaces
mnml.section: `list` is required and must be what mnml.list{} answered with
mnml.section: `side` is "left" or "right"
mnml: `list` names no live list — make it with mnml.list{} in this run (a reload drops them)
```

## Panes

#### `mnml.pane.open{ title, render, on_hit?, on_key? }`

A pane the script paints itself. Answers the pane id. `render(w, h)` is
called every frame with the pane's text area and returns up to `h` rows; a
row is a string, or a list of segments, and a segment is a string or
`{ text=, fg=, bg=, bold=, italic=, underline=, hit= }`.

```lua
local id = mnml.pane.open{
  title = "Notes",
  render = function(w, h)
    return {
      { { text = " NOTES ", fg = "accent", bold = true } },
      { { text = "  1. ", fg = "muted" }, { text = "write the manual", hit = 1 } },
    }
  end,
  on_hit = function(n, button) mnml.toast("row " .. n .. " " .. button) end,
  on_key = function(k) if k == "a" then return true end end,
}
```

`fg` and `bg` name a **theme role**, never a colour — `fg`, `muted`,
`accent`, `error`, `warn`, `info`, `border`, `gutter`, `selection`, `match`,
`cursor_line`, `chip`, `chip_active`, `title`, and the syntax slots
`syn_comment`, `syn_string`, `syn_keyword`, `syn_function`, `syn_type`,
`syn_number`, `syn_constant`, `syn_operator`, `syn_punctuation`,
`syn_property`, `syn_variable`, `syn_escape` (`src/ui/script_view.zig`). An
unknown role paints plain. Rows past the bottom and text past the right edge
are clipped.

A segment with `hit = n` is a click target: a press on it calls
`on_hit(n, "left" | "right" | "middle")`. While the pane is focused every key
goes to `on_key(name)` first — `name` is the chord spec (`j`, `ctrl+p`,
`enter`, `space`); return true to consume it, anything else lets it fall
through to the chord chain (`space f f` still works from a script pane). The
wheel arrives as `wheel_up` / `wheel_down`.

**Or a list in a pane**: pass `list = l` (a `mnml.list{}` handle) instead of
`render`, and the pane hosts the same panel a section would.

```lua
mnml.pane.open{ title = "Todos", list = l }
```

*Changed in: api 1. `list`: api 1, added.*

```
mnml.pane.open takes one table: { title, render, on_hit?, on_key? } — or { title, list = a mnml.list{} handle }
mnml.pane.open: `render` must be a function(w, h) returning up to h rows — a row is a string or a list of segments; pass `list` instead to host a mnml.list{}
mnml.pane.open: `on_hit` must be a function(hit_id, "left" | "right" | "middle") — a segment with hit = n is the target
mnml.pane.open: `on_key` must be a function(chord) returning true when it consumed the key
```

#### `mnml.pane.close(id)`

Closes a script pane.

```lua
mnml.pane.close(id)
```

*Changed in: api 1.*

```
mnml.pane.close: takes a pane id, an integer (what mnml.pane.open{} answered with)
mnml.pane.close: takes a pane id (what mnml.pane.open{} answered with); -1 is not one
```

#### `mnml.pane.active()`

The focused pane's id, or nil.

```lua
local pane = mnml.pane.active()
```

*Changed in: api 1.*

#### `mnml.redraw()`

Asks for a frame. A key or a click already implies one; this is for a repaint
after something else changed.

```lua
mnml.redraw()
```

*Changed in: api 1.*

## Operators

#### `mnml.operator{ id, title?, keys, run }`

A text operation the user reaches the way they reach a built-in one. Answers
the full command id.

```lua
mnml.operator{
  id = "surround",
  keys = { vim = "gs", standard = "ctrl+shift+s" },
  run = function(range)
    local text = mnml.buf.range(range.start, range["end"])
    mnml.buf.apply{ op = "replace_range", start = range.start,
                    ["end"] = range["end"], text = "(" .. text .. ")" }
  end,
}
```

`run` is handed the range in the shape `mnml.buf.selection()` answers —
`{ start, ["end"], mode }`, bytes, `end` exclusive.

**Under vim it is operator-pending.** `keys.vim` is `g` and one letter, and
every road a built-in operator's range comes from is the same one here: a
motion (`gsw`, `gs$`, `gsj`), a text object (`gsiw`, `gsi"`, `gsap`), a count
(`3gsw`), a mark (`` gs`a ``), a find (`gsf,`), the doubled form for whole
lines (`gss`, like `gUU`), and a live Visual selection (`viw` then `gs`, or
`V` then `gs` — `mode` is `"line"` there). The operator clears the selection
when it is done and Normal resumes, exactly as `gU{motion}` does.

The letter must be one vim does not already use; `gd`, `gc`, `gU`, `gq` and
the rest are refused **by name at registration** rather than registered and
never reached.

**Under standard it is a command.** `keys.standard` is an ordinary chord
spec, and the operator is a `user.<id>` command like any other — in the
palette, in `mnml.run`, bindable in `.keys`. It takes the selection; with
none, the word under the cursor (the `word_at` rule, so a cursor in a run of
whitespace does nothing). The standard chord is bound under both profiles, so
a vim user has both roads.

**One undo step.** Whatever `run` applies — one `replace_range`, or several
ops — a single `u` puts the text back the way it was before the chord.

*Changed in: api 1, added.*

```
mnml.operator takes one table: { id, title?, keys = { vim?, standard? }, run }
mnml.operator: `id` must be a bare name — letters, digits and `_`, no spaces or dots
mnml.operator: `keys` must be a table — { vim = "g<letter>", standard = "a chord spec" }, at least one of the two
mnml.operator: `keys` needs a `vim` chord ("g" and one letter) or a `standard` one (any chord spec), or both
mnml.operator: `keys.vim` must be `g` and one letter vim does not already use — `gd` is not; vim's own are …
mnml.operator: `run` must be a function(range) — range is { start, ["end"], mode }, the shape mnml.buf.selection() answers with
```

## Tasks

#### `mnml.task.run{ cmd, cwd?, label?, hidden?, on_line?, on_done? }`

The one way a script reaches the shell. `cmd` runs through `/bin/sh -c` in a
task pane below the active one, at `cwd` (workspace-relative or absolute; the
workspace by default). Answers the pane id — or the run's id when it is
hidden.

```lua
mnml.task.run{ cmd = "zig build", label = "build",
  on_done = function(r) mnml.toast(r.ok and "built" or "failed") end }

mnml.task.run{ cmd = "eslint --format compact -- app.js", hidden = true,
  on_line = function(text) collect(text) end,
  on_done = function(r) mnml.diagnostics.set(ns, "app.js", found) end }
```

`on_done{ ok, code }` — or `{ ok = false, signal }` — fires from the app's
tick once the child exits.

**`hidden = true`** runs it with **no pane at all** and hands its output to
**`on_line(text)`**, a line at a time as it arrives — the shape a tool
wrapper wants, where the output is only ever parsed. A hidden run's stderr is
merged into its stdout, its lines arrive stripped of the newline, and it is
capped at 5000 lines of 4 KiB each; past that the run still finishes and
still calls `on_done`. Each `on_line` is its own entry into the script, so
the 20 ms budget applies per line, not per run.

*Changed in: api 1. `hidden`, `on_line`: api 1, added.*

```
mnml.task.run takes one table: { cmd, cwd?, label?, hidden?, on_line?, on_done? }
mnml.task.run: `cmd` is required and must be the shell line to run, a string ("zig build")
mnml.task.run: `on_done` must be a function(result) — result is { ok, code } or { ok = false, signal }
mnml.task.run: `on_line` must be a function(text), one output line at a time — it needs hidden = true
mnml.task.run: `on_line` needs `hidden = true` — a visible task's output is its pane
```

## The config and the workspace

#### `mnml.config.get(path?)`

A read-only copy of the merged ZON config (the three layers, after trust)
under the dotted `path`; nil when nothing is there. Without a path, the whole
config as nested tables.

```lua
mnml.config.get("editor.tab_width")      --> 4
mnml.config.get("lsp.rust.cmd")          --> "rust-analyzer"
mnml.config.get("lsp.rust.extensions.2") --> a list index is 1-based
mnml.config.get("keys.global")           --> { ["ctrl+p"] = "picker.files", … }
mnml.config.get("tools.jira.url")        --> a Dynamic section, walked the same way
mnml.config.get()                        --> everything
```

Structs become tables, maps become tables keyed by name, enums become
strings, optionals nil, lists 1-based. Nothing a script changes in the
returned table reaches the config. A key of your own under `tools.` is how a
script takes settings without a second API.

*Changed in: api 1.*

```
mnml.config.get: takes a dotted path, a string ("editor.tab_width", "lsp.rust.cmd"); without one, the whole config
```

#### `mnml.workspace()`

The absolute workspace path.

```lua
mnml.toast(mnml.workspace())
```

*Changed in: api 1.*

#### `mnml.data_root()`

The data root — `~/.config/mnml`, or `MNML_DATA_ROOT`, or the portable
directory beside the binary.

```lua
local scripts = mnml.data_root() .. "/scripts"
```

*Changed in: api 1.*

---

# Around the API

## The `script.*` commands

| command | reached by | what it does |
|---|---|---|
| `script.reload` | the palette, the SCRIPTS header's `⟳` | drops everything script-owned, reopens the states, runs every `init.lua` and every installed script again |
| `script.edit_init` | the palette | opens the data root's `init.lua` in an editor, creating it on save |
| `script.run_selection` | vim `<leader>sr`, standard `ctrl+alt+enter` | runs the selected lines — or the cursor line — in the script state |
| `script.doctor` | `d` in the SCRIPTS section | the report: every state, its api, its source, whether it is enabled, its budget overruns this session, its hooks, its `require` root and its namespaces with live decoration counts — plus the three folders a script can be scanned from |
| `script.install` | `i` in the SCRIPTS section | installs from a path, a git URL or an archive |
| `script.new_init` | `n` in the SCRIPTS section | writes the workspace `init.lua` from the commented template |
| `view.activity_scripts` | the rail's 󰢱 | opens the SCRIPTS section |

The SCRIPTS section's own keys: `1` `2` `3` or `h` `l` / Tab pick a tab, `/`
filters, `s` cycles the sort (its chip's right-click lists every mode with a
✓), `r` refreshes, `i` installs, `e` enables or disables the focused row, `x`
removes it, `d` opens `script.doctor`. Enter opens the focused script's
README — the file itself, for `init.lua`.

A right-click on a row — or its `⋮` — is the row's menu: enable / disable /
reload / update / remove / open folder / open README, and a jump to each
`file:line` the script registered something at.

**Bind in init.lua…** is on a right-click over a command in the palette
(`ctrl+shift+p`): it asks for a key spec, refuses one the keymap cannot
parse, and appends `mnml.map("<spec>", "<id>")` on a new last line of the
workspace `init.lua` — the template first when there is none — then reloads
the file in its editor when it is open and clean, so the chord works at once.

## Installing scripts

A one-file `init.lua` is for what you write for yourself. A script you got
from someone else — or one of your own you want to keep, version and share —
is a **directory**:

```
<data root>/scripts/<name>/
  script.zon     the manifest
  init.lua       the entry
  lib/*.lua      what a scoped `require` may reach
  README.md      what Enter on its SCRIPTS row opens
```

The manifest (`src/scripting/manifest.zig`):

```zon
.{
    .name = "git-blame-line",       // the folder name; letters, digits, `-`, `_`
    .version = "1.0.0",
    .api = 1,                       // the `mnml` table it was written for
    .description = "Who last touched the cursor line",
    .author = "you",
    .commands = .{ "user.blame_toggle" },   // what it says it registers
    .hooks = .{ "cursor_idle", "pane_focus" },
    .source = .marketplace,         // marketplace | community | private | dev
    .url = "https://…",             // where it came from; `script.update` goes back to it
}
```

`.api` is the contract: the `mnml` table as this page describes it for that
number. A manifest without one is refused — we cannot tell what it expects. A
manifest naming a number this build does not implement gets a row that says
so rather than a silent skip, and never runs.

**Each installed script gets its OWN Lua state.** Its own 20 ms budget clock,
its own decoration namespaces (two scripts may both call theirs `"blame"` and
never collide), its own registrations, and a `require` that resolves only
under its own directory. A script that errors is one toast and a disabled
row; the others keep running.

**`require`**, in an installed script only:

```lua
local helper = require("lib.helper")   --> <script dir>/lib/helper.lua
```

Dots separate plain segments. A `..`, a path separator, an absolute path or
an empty part is refused by name — nothing is read. There is no `package`, so
there is no `package.path` to widen. A module that returns nothing caches
`true`, as Lua's own `require` does. `script.doctor` prints each script's
`require` root, and says `require none` for the two `init.lua` files.

*Changed in: `require` (an installed script's own files only): api 1, added.*

### The three tabs

| tab | what it lists | where it reads |
|---|---|---|
| **Installed** | `init.lua` first, then every installed script — name, version, source badge, enabled state, the `⏱ N` budget chip, and the commands it adds | `<data root>/scripts/` (or `MNML_SCRIPTS_ROOT`), plus `scripts.private_sources` |
| **Marketplace** | the curated set that ships with mnml | the shipped `lua/` folder (below), or `scripts.marketplace_local` / `MNML_SCRIPTS_MARKETPLACE` |
| **Dev** | folders you are editing; a save under one reloads that script | `scripts.dev_roots`, or `MNML_SCRIPTS_DEV_ROOTS` |

`script.doctor` names all three resolved paths at the head of its report, so
"why is my script not listed" is one command and not a hunt through the
config.

**The curated set lives in mnml, the way the integrations do.** It is the
repo's own `lua/` folder, and the Marketplace tab lists it out of the box —
no config, no network, nothing to point at. The binary finds it in this
order:

1. `lua/` in the checkout it was built from (baked in at build time), so a
   dev build lists the five straight away;
2. `share/mnml/lua` one level up from the binary — `/usr/bin/mnml` with
   `/usr/share/mnml/lua`, which is what the `.deb` and the `.rpm` lay down;
3. `share/mnml/lua` beside the binary — the `.tar.xz` and the Windows `.zip`
   unpack to exactly that;
4. `mnml-data/lua` beside the binary — the portable directory.

`scripts.marketplace_local` (and `MNML_SCRIPTS_MARKETPLACE`, which wins over
it) points the tab at a folder of your own instead — an offline mirror, a
company set, or a test fixture.

### Where a script comes from, and the trust dialog

```
:script.install <git URL>        cloned shallow with your git client → `community`
:script.install <archive>        .tar/.tar.gz/.tgz/.zip, unpacked    → `community`
:script.install <folder>         copied                              → `community`
```

A folder under `scripts.private_sources` badges `private`; one installed from
the marketplace badges `official`; one under `scripts.dev_roots` badges
`dev`.

Whatever the source, the copy is **staged and read, never run**, and the
manifest's claims go on screen first — through the same `Claim` model the
workspace trust dialog uses (`src/config/trust.zig`, sink `script_install`):

```
Install this script?

greeter 2.1.0 by someone (script api 1)
Says hello
It gets its own Lua state and runs every time mnml starts. It claims:
  • script greeter — runs `user.greet (a command)` every time mnml starts
  • script greeter — runs `save_post (a hook)` every time mnml starts
  • script greeter — runs `task.run — it starts programs` every time mnml starts

                                            [Install]  [Cancel]
```

The last line is not the manifest's word: mnml greps the script's own `.lua`
files for `task.run`, the only door out of the sandbox, and says what it
found. Cancel is the focused choice, and it throws the staged copy away
without running a line.

Enabled / disabled is a `.disabled` marker file in the script's own folder:
no config write, and it survives a restart.

## Publishing a script

Make the directory; fill in `script.zon` (name, version, `.api = 1`, and the
commands and hooks you **actually** register — the trust dialog shows them,
so a manifest that under-declares reads as dishonest the first time someone
opens `script.doctor`); write a `README.md` that says what it does and what
it needs on PATH; push it. Anyone can then `:script.install <your URL>`.

A company set is a folder or repo listed in `scripts.private_sources`; the
curated set is mnml's own `lua/` folder, which ships with the binary.

Before you publish, run `script.doctor` and read your own row: it is the
receipt a user will read too.

## Recipes

Five scripts ship with mnml — `lua/` in the repo, `share/mnml/lua` in the
package — each the whole of one shape. Each is driven by a
`.test` that runs the file **as it is written**, so a change that breaks one
fails the suite. Paste one into your `init.lua` (`script.edit_init`) and
reload, or open the Marketplace tab — they are its rows out of the box — and
install it.

| script | shape | what to steal from it |
|---|---|---|
| [`git-blame-line`](../lua/git-blame-line/) | decorations + a hidden task | one namespace per concern, so the clear is safe; `pcall` around `mnml.buf.path` because not every focused pane is an editor; a `<path>:<line>` key so the same line is never asked about twice and two runs are never in flight at once |
| [`recent-commands`](../lua/recent-commands/) | a live picker with a preview column | `live = true` so the source does the narrowing rather than the picker's fuzzy filter; `data` carrying the whole command row through to `preview` and `on_accept`; `rank` read off `mnml.commands()` instead of an MRU of its own |
| [`todo-list`](../lua/todo-list/) | a rail section of the script's own | the `rows(sort)` shape — headers and items in one list, the sort's name handed in so ordering stays the script's job; `l:refresh()` from the task's `on_done`, so the panel fills when the child answers rather than blocking on it; a row's `detail` doing double duty as the `<path>:<line>` that opening needs |
| [`surround-word`](../lua/surround-word/) | one text operation, both profiles | one `run(range)` serving every road into it, because the range arrives in one shape; `range.mode` telling a linewise application to keep the indentation outside the pair; `mnml.config.get` reading a key of the user's own |
| [`eslint`](../lua/eslint/) | a tool wrapper into the diagnostics sink | `hidden = true` because there is nothing to watch; an `on_line` parse that ignores what does not match (the tool's summary line); a `set` on every run — including the empty one that clears a file the tool is now happy with |

`docs/examples/init.lua` is the sixth: one file that touches every surface at
once, which is what a unit test runs to prove they all still load together.

## What is deliberately not there

- **No `os`, `io`, `package`, `debug`; no `dofile` or `loadfile`.** The two
  `init.lua` files are one file each; an installed script gets a `require`
  scoped to its own directory and nothing wider.
- **No `__gc` finalizers.** `setmetatable` refuses a metatable with a
  `__gc` field. A finalizer runs with Lua's hooks off — when a reload or a
  quit closes the state, or mid-collection — so the budget could never cut
  one, and a looping one hung the reload.
- **No colour values.** Roles only, so a script looks right in every theme.
- **No app handle, no raw buffer pointer.** Reads are copies; writes are
  `EditOp`s through the one chokepoint.
- **No network, no file system.** `mnml.task.run` is the door, and it is
  visible in a task pane or declared `hidden` in the manifest.
- **No threads, timers or blocking calls.** Nothing runs off the UI thread.
- **No per-frame callbacks for decorations.** They are data the renderer
  reads; the budget cannot be spent painting.
- **No reload from inside a script.** `script.reload` is a command for the
  user.

## Testing a script

`tests/e2e/lua_init.test` shows the shape: `write .mnml/init.lua "…"`,
`command script.reload`, then `command user.<id>` and `expect screen contains
…`. The `.test` runner's temp workspace is trusted, so the workspace file
runs. Unit tests reach the state as `app.script()` and run chunks with
`runString`.

A test that drives a script **file** rather than an inline one copies it in
with a `shell` step; the repo root reaches the step through the header,
because a shell resets `PWD` to its own cwd:

```
# env: MNML_REPO=${PWD}
shell mkdir -p .mnml && cp "${MNML_REPO:?}/lua/eslint/init.lua" .mnml/init.lua
```

`lua_example_eslint.test`, `lua_example_git_blame_line.test`,
`lua_example_recent_commands.test`, `lua_example_todo_list.test` and
`lua_example_surround_word.test` do exactly that, which is what keeps the
five recipes true. The surfaces themselves have their own files —
`lua_picker_live.test`, `lua_section.test`, `lua_operator.test`,
`lua_completion.test`, `lua_inspect.test`, `lua_decor.test`,
`lua_diagnostics_sink.test`, `lua_error_diagnostic.test`,
`lua_http_hooks.test`, `lua_run_selection.test`, `lua_init.test`; the SCRIPTS
section has `scripts_doctor.test`, `scripts_install_dir.test`,
`scripts_trust_claims.test`, `scripts_marketplace_default.test` (the shipped
set, with no environment at all), `scripts_marketplace_local.test` (the
override), `scripts_dev_root_reload.test` and `scripts_budget_chip.test`.

A test that installs a script sets `MNML_SCRIPTS_ROOT` in its header: the
corpus shares one data root across every file, and a script installed by one
would otherwise load in all the rest.
