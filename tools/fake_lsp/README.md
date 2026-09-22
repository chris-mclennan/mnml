# mnml-fake-lsp — a deterministic language server

`zig build` installs `zig-out/bin/mnml-fake-lsp`, a Language Server
Protocol server over stdio (JSON-RPC 2.0, `Content-Length` framing)
whose every answer is a function of the open documents' text. It exists
so the LSP UI — the server chip, the toasts, hover, go-to-definition,
references, completion, rename, diagnostics, code actions, formatting,
`didClose` and the shutdown — can be tested for real on every platform
with no language toolchain installed. No clocks, no environment, no
randomness: the same documents and the same requests give the same
frames, byte for byte.

`main.zig` is the protocol (`Server`) and the stdio loop, with its unit
tests (`zig build test` runs them, leak-checked on
`std.testing.allocator`); the client's integration test in
`src/app/lsp.zig` spawns the installed binary, and the
`tests/e2e/lsp_fake_*.test` scripts drive it through the panes. The
`mnml-zig test` runner exports `$MNML_FAKE_LSP` (the binary beside
itself, or the build's install path), so a script names the server as

```zon
.lsp = .{ .fake = .{ .cmd = "$MNML_FAKE_LSP", .args = .{ "--log", "lsp.log" }, .extensions = .{ "fk" }, .root_markers = .{ ".fkroot" } } }
```

`$NAME` in an LSP `cmd` or argument is expanded from the environment,
as for a debug adapter.

## Options

- `--log PATH` — every incoming method name, one per line, rewritten on
  each message (relative to the server's cwd, which is the project
  root mnml started it in). A script asserts on it with
  `expect file lsp.log contains "textDocument/didClose"`.
- `--sync incremental` — advertise RANGE sync (`textDocumentSync.change:
  2`) instead of full, apply each `contentChanges[]` entry to the stored
  text in order exactly as the protocol says (each change describes the
  document the one before it left; no range means the whole text), and
  write one extra line per change into `--log`: `didChange range
  L:C-L:C len=N`, or `didChange full len=N`. That line is the only way
  a script can tell a range sync from a full one. Without the flag the
  server advertises full sync (`change: 1`) as it always has.
- `--configure` — after `initialized`, send the client a
  `workspace/configuration` request and answer `documentSymbol` with
  `[]` until the client has replied; the reply writes
  `workspace/configuration answered` into `--log`. This is what
  bash-language-server does while it is still configuring, and what
  left mnml's outline empty when the first symbols request went out in
  the same instant as `didOpen`.
- `--symbols rich` — a function's `range` runs to the first later line
  that starts with `}` (a one-liner that holds its own `}` ends where
  it is), and every `let <name>` line is a variable symbol (kind 13) on
  its line — the shape a real server sends, which the breadcrumb chip
  has to place a caret inside. Without it a symbol is one line, as it
  always was.
- `--version`, `--help`.

Two more lines go into `--log` under the method that carried them,
whatever the flags: `didOpen languageId=<id>` (what the client called
the file — `shellscript` for a `bin/run-all` under a bash shebang) and
`formatting tabSize=<n> insertSpaces=<bool>` (the options a formatting
request carried).

## The contract

`initialize` answers `positionEncoding: "utf-8"` (a byte offset is a
character), full-document sync (`change: 1`, or range sync under
`--sync incremental`), and the providers below.
When the root (`rootUri`, else `rootPath`) holds no `Cargo.toml`, one
`window/showMessage` of type 1 (Error) follows the reply, with
rust-analyzer's own wording — `Failed to discover workspace.\nConsider
adding the `Cargo.toml` of the workspace.` — which mnml toasts as
`LSP: Failed to discover workspace.Consider adding the `Cargo.toml`…`
(the newline paints as nothing, as under Rust). A root with a
`Cargo.toml` is quiet.

`initialized`, `textDocument/didSave` and any other notification are
accepted and ignored. `shutdown` answers `null`; `exit` ends the loop.
An unknown request gets `-32601 method not found`.

| request | answer, from the text |
|---|---|
| `textDocument/didOpen` / `didChange` | the document is stored (the last `contentChanges[].text` is the whole text; under `--sync incremental` each change's range is applied in turn), then `publishDiagnostics`: one warning (severity 2, source `fake-lsp`, message `unresolved TODO`) per line holding `TODO`, from the marker to the line's end |
| `textDocument/didClose` | the document is dropped and its diagnostics published empty |
| `textDocument/hover` | the identifier under (or ending at) the position as markdown `**word**`, with its range; `null` on no word |
| `textDocument/definition` | for word `foo`, the `foo` on the first line that starts with `fn foo` (character 3); `null` when there is none |
| `textDocument/references` | every whole-word occurrence of the word in the document, in order |
| `textDocument/completion` | the document's identifiers, unique, sorted bytewise; a name with a `fn name` line is kind 3 (function, detail `fn`), the rest kind 6 (variable, detail `identifier`) |
| `textDocument/rename` | a `WorkspaceEdit` whose `changes[uri]` replaces every whole-word occurrence of the word with `newName` |
| `textDocument/documentSymbol` | one symbol per `fn <name>` line: kind 12 (Function), `range` the line, `selectionRange` the name (`--symbols rich`: the range through the closing `}`, plus a variable per `let`); `[]` under `--configure` until the client has answered `workspace/configuration` |
| `textDocument/codeAction` | when a line in `range.start.line..=range.end.line` holds `TODO` (the first one): one `quickfix` titled `Resolve TODO` whose edit replaces the marker with `DONE`; else `[]` |
| `textDocument/formatting` | one edit replacing the whole document with trailing blanks trimmed on every line and exactly one newline at the end; `[]` when already so |

Identifiers are `[A-Za-z0-9_]+` runs not starting with a digit. Lines
split on `\n`; a trailing `\r` is not part of the line.

## Example

```
fn foo() {
  let x = 1;
  foo(x); // TODO later
}
fn bar() { foo(); }
```

Hover at 2:3 → `**foo**`. Definition of `foo` → line 0, characters
3–6. References → three. Completion → `TODO bar fn foo later let x`.
Rename to `quux` → three edits. Symbols → `foo` (line 0), `bar` (line
4). Diagnostics → one warning at 2:13. Code action at line 2 →
`Resolve TODO`. Formatting → `[]` (nothing trails); with two blanks
after `let x = 1;`, one edit replacing the whole text without them.
