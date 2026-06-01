---
title: Headless mode & the `.test` E2E format
description: mnml's headless frontend — same App + draw path against a ratatui TestBackend, driven over file IPC at `<workspace>/.mnml/ipc/`. Plus the `.test` end-to-end script format, runnable via `mnml test` and under `cargo test`.
---

mnml has a second frontend that renders into an in-memory ratatui `TestBackend` instead of crossterm. No real terminal. Every other piece — `App`, `ui::draw`, the `tui::dispatch_*` event router, every command, the editor, the panes — is byte-for-byte the same as the terminal binary. You drive it from a sibling process by appending JSON to a file, and you read the rendered screen back as plain text.

That substrate buys mnml three things at once: a deterministic E2E test runner (the `.test` format), a way to script the editor from any language that can append to a file, and headless smoke runs in CI.

## What headless mode is

```bash
mnml --headless                  # headless against $PWD
mnml --headless ~/repo           # headless against a specific workspace
./run.sh headless ~/repo         # same, with the build + restart loop
```

Behavior:

- A `TestBackend` of `120 × 40` is allocated (override with `MNML_COLS` / `MNML_ROWS`).
- Every tick, mnml renders into the virtual screen, then writes `screen.txt` + `status.json` to the workspace's IPC dir.
- mnml polls `command` for new JSONL lines and dispatches them through the same path the terminal loop uses (so a key injected over IPC hits `tui::dispatch_key` exactly like a real keypress).
- On `{"cmd":"quit"}` it shuts down cleanly; on `{"cmd":"restart"}` it exits with status 75 so `./run.sh`'s outer loop knows to rebuild and relaunch.

There's no stdout chatter and no terminal escape codes — headless mode is silent except for the files it writes.

## Why it exists

- **E2E testing.** The `.test` runner (see below) stands on this — every test allocates a tempdir, opens a fresh `App` against the same `TestBackend`, runs a script of steps and expectations, and tears the temp workspace down. 100+ scripts under `tests/e2e/` ship with mnml; `cargo test` runs all of them.
- **Scripting from any language.** A shell script, a Python harness, a CI job, or a sibling Claude Code agent can drive mnml without rendering a UI. The IPC schema is just JSONL into a file and text/JSON files out.
- **CI smoke runs.** The `headless-smoke` skill in `.claude/` builds mnml, launches it headless against a fixture workspace, fires a few IPC commands, and asserts on `screen.txt` + `status.json`. No tmux, no Xvfb.

## File IPC

The IPC directory lives at `<workspace>/.mnml/ipc/`, created on startup. Four files, one purpose each:

| File | Direction | Format | What it carries |
|---|---|---|---|
| `command` | host → mnml | JSONL, append-only | One command per line. mnml tail-reads it, applies each, advances its offset. |
| `screen.txt` | mnml → host | plain text | The most recent rendered virtual screen, rows joined by `\n` with trailing spaces trimmed. Rewritten every tick. |
| `status.json` | mnml → host | JSON object | Focus / active pane / active file / cursor row+col / editing mode / tree state / pane list / quit flag. Rewritten every tick. |
| `events.jsonl` | mnml → host | JSONL, append-only | What happened. `start`, `open`, `key`, `type`, `command_run`, `plugin-command`, `exit`. |

mnml truncates `command`, `screen.txt`, `status.json`, and `events.jsonl` on startup so every session begins clean. The `command` reader keeps a byte offset, so a host that appends a partial line (no trailing newline) won't have it parsed until the newline arrives.

### The `command` schema

```jsonc
{ "cmd": "open",        "path": "src/main.rs" }            // open a file (workspace-relative or absolute)
{ "cmd": "key",         "key": "ctrl+s" }                  // inject a key (parsed by mnml's keyspec grammar)
{ "cmd": "type",        "text": "Hello\nworld" }           // type literal chars; "\n" → Enter
{ "cmd": "run-command", "id":  "file.save" }               // run a registered command by id
{ "cmd": "register-command",                                // register a plugin command at runtime
  "id":    "myplugin.do_thing",
  "title": "Do The Thing",
  "group": "plugin",
  "keys":  ["leader+x"] }
{ "cmd": "snapshot" }                                       // force a fresh screen + status dump
{ "cmd": "quit" }                                           // exit cleanly
{ "cmd": "restart" }                                        // exit with status 75 (run.sh loop rebuilds + relaunches)
```

Unknown commands and malformed JSON aren't fatal — mnml records them as `{"event":"unknown",…}` in `events.jsonl` and keeps polling.

### The `status.json` shape

```jsonc
{
  "focus": "pane",                    // "pane" | "tree"
  "activePane": 0,                    // index into "panes", or null
  "activeFile": "/abs/path/src/main.rs",
  "cursor": { "line": 12, "col": 3 }, // 1-based
  "mode": "Normal",                   // "Normal" | "Insert" | "Visual" | "Command" | "none"
  "treeCursor": 5,
  "treeSelection": "/abs/path/src",
  "treeVisible": true,
  "panes": [
    { "title": "src/main.rs", "dirty": false }
  ],
  "quit": false
}
```

## Driving headless from a shell

The whole surface is `echo` and `cat`:

```bash
# launch headless, scoped to a fixture workspace
./run.sh headless ~/Projects/mnml-fixture &
WS=~/Projects/mnml-fixture
IPC=$WS/.mnml/ipc

# wait for startup
until [ -s "$IPC/status.json" ]; do sleep 0.1; done

# open a file
echo '{"cmd":"open","path":"src/main.rs"}' >> "$IPC/command"

# type and save
echo '{"cmd":"type","text":"// hello from a shell\n"}' >> "$IPC/command"
echo '{"cmd":"key","key":"ctrl+s"}'                    >> "$IPC/command"

# read the screen back
cat "$IPC/screen.txt"

# check state
jq '.cursor, .mode, .panes' "$IPC/status.json"

# tail what happened
tail -f "$IPC/events.jsonl"

# quit
echo '{"cmd":"quit"}' >> "$IPC/command"
```

`status.json` is rewritten every tick (40 ms poll), so re-reading it gives you the current state — no need to wait for a notification.

## The `.test` E2E format

A `.test` file is a line-based script of **steps** (drive the editor) and **expectations** (assert on the rendered screen or the app state). Each test runs against a fresh tempdir + a fresh `App` + a fresh `TestBackend`; on success the temp workspace is dropped. No state leaks between tests.

Two ways to run:

```bash
cargo run -- test                       # everything under tests/e2e/ (default)
cargo run -- test tests/e2e/find.test   # one file
cargo run -- test tests/e2e/dap_*       # globs are shell-expanded
cargo test --test e2e                   # under `cargo test`, same scripts
```

`cargo run -- test` prints a `PASS` / `FAIL` line per file with the failure reason inline; the `cargo test` path bundles them as one `#[test]` and fails with a list of every failing file + step.

### Syntax

One statement per line. Blank lines and `#`-comments are ignored. `<text>` arguments may be wrapped in `"…"` to preserve leading/trailing whitespace; inside the quotes, `\n` `\t` `\\` `\"` are unescaped.

**Steps** (these drive the app):

| Statement | Effect |
|---|---|
| `write <relpath> <content>` | Seed a fixture file in the temp workspace. `"\n"` in `<content>` becomes a real newline. |
| `open  <relpath>` | Open the file in a new editor pane (focuses the pane). |
| `key   <keyspec>` | Send a key — `ctrl+s`, `enter`, `down`, `esc`, `a`, … (mnml's full keyspec grammar). |
| `type  <text>` | Type literal text char-by-char. `\n` becomes Enter. |
| `command <id>` | Run a registered command by id (`file.save`, `find.find`, `picker.buffers`, …). |
| `ex <cmdline>` | Run an ex command — `ex bd!` runs `:bd!`. |
| `wait  <ms>` | Sleep + tick (for async / pty steps). |
| `click <x> <y>` | Left-click at screen cell `(x, y)` (0-based). |
| `rightclick <x> <y>` | Right-click (opens context menus). |
| `doubleclick <x> <y>` | Double-click (row activation in list panes). |
| `scroll <x> <y> up\|down` | Mouse-wheel scroll at `(x, y)`. |
| `snippet <scope> <trig> <expansion>` | Seed a `[snippets.<scope>]` entry on `app.config`. |
| `shell <cmd>` | Run `<cmd>` via `$SHELL -c` in the workspace; non-zero exit fails the test. Useful for `git init`, non-text fixtures. |
| `ghost <text>` | Inject an AI ghost-text suggestion onto the active editor (the real worker thread can't run deterministically; this seeds the state directly). |

**Expectations** (these assert):

| Statement | Effect |
|---|---|
| `expect screen contains <text>` | The rendered virtual screen contains the substring. |
| `expect screen lacks <text>` | …does not. |
| `expect dirty <true\|false>` | The active editor's dirty flag. |
| `expect pane <text>` | The active pane's title contains the substring. |
| `expect file <relpath> contains <text>` | The file at `<relpath>` (workspace-rel) contains it. |
| `expect file <relpath> lacks <text>` | …does not. |
| `expect highlights at_least <N>` | The active editor has ≥ N highlight spans across all lines (catches grammar-loading regressions). |

### A minimal example

```text
# Open a seeded file, type into it, save — the dirty marker should clear.
write notes.txt first line
open notes.txt
expect screen contains "first line"
expect dirty false
expect pane "notes.txt"

type "TYPED "
expect dirty true
expect screen contains "TYPED first line"

key ctrl+s
expect dirty false
```

That's `tests/e2e/edit_and_save.test` verbatim. The script renders into a 120×40 `TestBackend`; mnml's normal bufferline, statusline, gutter, and indent guides all render too — `expect screen contains` matches against the same text a real user would see.

### A second example — Find-in-buffer

```text
write notes.txt "alpha\nbeta\nalpha\ngamma\nalpha\n"
open notes.txt

command find.find
expect screen contains "Find"
type alpha
key enter
expect screen contains "match 1/3"

command find.next
expect screen contains "match 2/3"
command find.next
expect screen contains "match 3/3"
command find.next
expect screen contains "match 1/3"     # wraps

command find.find
type zzz
key enter
expect screen contains "no matches"
```

The full set of ~100 scripts under `tests/e2e/` is the best reference for what each command does end-to-end.

## Running tests

```bash
cargo run -- test                          # all scripts under tests/e2e/
cargo run -- test tests/e2e/find.test      # one file
cargo run -- test ./my-scripts             # any directory of `.test` files

cargo test --test e2e                      # the same scripts, as one #[test]
cargo test                                 # full suite (unit + e2e)
```

`cargo run -- test <path>` walks `<path>` for `*.test` files (recursive, `.gitignore`-aware via the `ignore` crate). A single file is run directly; a directory is walked. Exit code is 0 if every test passed, non-zero otherwise.

Under `cargo test`, every `.test` file is bundled into `tests/e2e.rs`'s single `e2e_suite` test — the failure message lists every failing file + step. That's the path CI takes.

## Debugging a failing `.test`

When an `expect` fails, the runner dumps the rendered screen inline:

```text
line 7: screen does not contain "match 2/3"
── rendered screen ──
   1 alpha                                  …
   2 beta
   3 alpha
   4 gamma
   5 alpha
…
[notes.txt] [Normal] no matches
```

That's almost always enough. When it isn't:

- **Run the same script headless** to inspect post-mortem state. Translate the script to IPC commands by hand, point `./run.sh headless` at the fixture workspace, and watch `screen.txt` + `events.jsonl` as you feed commands.
- **Bump the screen size** — `MNML_COLS=200 MNML_ROWS=60 cargo run -- test …` if the assertion is matching against text that wrapped off the default 120×40.
- **Add a `wait`** for async surfaces (LSP, DAP, pty). The renderer ticks synchronously on every step, but a background worker may not have produced output yet.
- **Check `events.jsonl`** in headless mode — every IPC command appears as an event with its result; `command_run` carries an `"ok":"false"` if the command id didn't resolve.

When the screen looks right but the assertion still fails, the substring grammar is your friend — `expect screen contains "match 2/3"` is just `String::contains`, no regex, no whitespace normalisation beyond what `screen.txt` already does (trailing-space-trim per row).

## Next

- [Workspaces & the file rail](/manual/workspaces/) — the same workspace model headless mode rides on
- [Settings & configuration](/manual/settings/) — `MNML_COLS` / `MNML_ROWS` and other env knobs
- [Editing](/manual/editing/) — every editor command id you can use in a `.test` script
