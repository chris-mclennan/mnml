---
title: LSP
description: mnml's Language Server Protocol surface — completion, diagnostics, hover, goto-def, references, rename, code actions, formatting, and how to wire up rust-analyzer / pyright / tsserver / gopls / clangd / lua-language-server.
---

mnml speaks LSP. For each `(project-root, language)` pair it spawns one language-server subprocess, talks JSON-RPC over stdio on a reader thread, and surfaces the results through the editor's normal chrome — gutter signs, popups, the diagnostics pane, pickers. A handful of common languages work out of the box; anything else is a `[lsp.<name>]` table away.

Servers that aren't installed degrade silently — the editor still works, you just don't get language smarts. There's no daemon, no plugin step, no manual `:LspAttach`.

## What you get

- **Real-time diagnostics** — errors, warnings, hints painted in the gutter and underlined inline; the statusline counts and a dedicated "Problems" pane lists them workspace-wide.
- **Autocomplete** — as-you-type popup with documentation, lazy `completionItem/resolve`, snippet-style items with tab-stops.
- **Hover docs** — markdown-rendered docs for the symbol under the cursor.
- **Goto** — definition, declaration, type-definition, implementation; references → picker.
- **Symbols** — file-scoped fuzzy picker, workspace-wide fuzzy picker, a docked Outline pane.
- **Rename** — single prompt with an inline preview at every occurrence, then a cross-file confirmation pane before any file changes.
- **Code actions** — quick-fixes, refactors, organize-imports, with a picker (or a one-shot "apply the first one" gesture).
- **Format** — LSP formatting, opt-in format-on-save, plus external formatters (`prettier` / `rustfmt` / `gofmt` / `ruff` / …) as a fallback.
- **Signature help** — paint the active parameter as you type `(` and `,`.
- **Hierarchies** — call hierarchy (incoming / outgoing) and type hierarchy (super- / sub-types).
- **Inlay hints, semantic tokens, document colors, code lens, document links** — the rest of the standard LSP surface.

## Built-in language servers

mnml ships a default table for the common cases. When you open a file with a matching extension and the server binary is on `$PATH`, the client spawns automatically — no config needed.

| Language     | Server                          | Extensions                         | Root markers                                     | Install hint                                          |
|---           |---                              |---                                 |---                                               |---                                                    |
| Rust         | `rust-analyzer`                 | `.rs`                              | `Cargo.toml`                                     | `rustup component add rust-analyzer`                  |
| Python       | `pyright-langserver --stdio`    | `.py`                              | `pyproject.toml` / `setup.py` / `requirements.txt` | `npm i -g pyright`                                  |
| TypeScript / JS | `typescript-language-server --stdio` | `.ts` `.tsx` `.js` `.jsx`     | `tsconfig.json` / `jsconfig.json` / `package.json` | `npm i -g typescript typescript-language-server`   |
| Go           | `gopls`                         | `.go`                              | `go.mod`                                         | `go install golang.org/x/tools/gopls@latest`         |
| C / C++      | `clangd`                        | `.c` `.h` `.cpp` `.hpp` `.cc`      | `compile_commands.json` / `.clangd`              | `brew install llvm` / `apt install clangd`           |

The tools picker (`:Tools` or `:Mason`) lists every LSP / formatter / linter mnml looks for, with a ✓/✗ "is on PATH" indicator and the install hint copied to your clipboard on Enter. That's the fastest way to see what's wired vs what's missing for a given language. Beyond the five spawn-by-default servers, the tools list also knows about `lua-language-server`, `yaml-language-server`, `bash-language-server`, `vscode-css-language-server`, `vscode-html-language-server`, `vscode-json-language-server`, `tailwindcss-language-server`, `ruby-lsp` — and any of these can be enabled with a one-line `[lsp.<name>]` table (see [Configuration](#configuration) below).

mnml looks up root markers by walking up from the file. The cwd of the spawned server is the matched root — so a monorepo with multiple `Cargo.toml`s gets one `rust-analyzer` per crate, each scoped correctly.

## Diagnostics

Diagnostics arrive as `publishDiagnostics` notifications, flow over an mpsc channel to the event loop, and land on the buffer they belong to.

### How they surface

- **Gutter sign** — one of `E` / `W` / `I` / `H` (error / warning / info / hint) next to the affected line.
- **Inline underline** — the offending range itself is colored.
- **Hover the line** — the popup shows the full message (which may be multi-line for `rustc` / `clippy`).
- **Statusline counts** — the `E:N W:M` chip shows totals for the active buffer.
- **External-linter merge** — diagnostics from `[linters.<ext>]` (eslint, ruff, shellcheck, …) are blended into the same set, with the source field (`eslint` / `clippy` / `rustc` / …) shown in the diagnostics pane.

### Navigating

| Key | Command | Action |
|---|---|---|
| `]d` (vim) | `lsp.next_diagnostic` | Jump to next diagnostic in this file (wraps) |
| `[d` (vim) | `lsp.prev_diagnostic` | Jump to previous diagnostic (wraps) |
| `<leader>le` | `lsp.diagnostics` | Open the Problems pane |
| `<leader>ln` / `<leader>lp` | `lsp.next_diagnostic` / `lsp.prev_diagnostic` | Same as `]d` / `[d` (works in standard mode too) |

The Problems pane (`Pane::Diagnostics`) is workspace-wide — every diagnostic on every open editor buffer, errors first, then sorted by file and line. `↑↓` / `jk` to move, `Enter` to jump to the source, `r` to refresh.

When the [right side panel](/manual/right-panel/) is open (`Ctrl+Shift+B` or `:set rightpanel`), `lsp.diagnostics` routes the Problems pane **into the panel** instead of carving a split below the focused leaf. The panel header reads ` DIAGNOSTICS` and the same navigation keys work. Closing the panel evicts the pane; firing `lsp.diagnostics` again rehosts it. Useful for keeping the workspace error list visible without giving up editor body height.

## Completion

Completion is automatic as you type. The popup opens at word starts and on the LSP trigger characters `.` and `:`; subsequent keystrokes refilter locally without re-requesting from the server. The reply runs through `completionItem/resolve` on demand, so the documentation panel populates only for the item you're hovering.

### Triggering manually

| Key | Command |
|---|---|
| `<leader>lc` | `lsp.completion` — ask the server explicitly |
| `Ctrl+N` / `Ctrl+P` (vim Insert) | `editor.keyword_complete` — buffer-keyword completion through the same popup |

In vim mode, `Ctrl+N` is reserved for the vim INSERT handler — the global `file.new` binding is stripped from the keymap when `input_style = "vim"` so it doesn't intercept the chord before vim sees it. Vim users create files via `:e <path>` or `:enew` instead. `Ctrl+P` stays bound to the palette / recents picker in both modes (strong NvChad muscle memory), so vim INSERT's `Ctrl+P` (keyword-completion-previous) reaches the same handler via `Ctrl+N` plus the popup's `↑`. Under `input_style = "standard"`, `Ctrl+N` is still `file.new`.

### Accepting

- `Tab` or `Enter` — accept the highlighted item.
- `↑` / `↓` — move within the popup.
- `Esc` — dismiss.
- If the item is a snippet (LSP `insertTextFormat == 2`), accepting expands the snippet syntax — `$1` / `${1:default}` / `$0` become tab stops you can step through.

### Signature help

While inside a function call, typing `(` auto-fires `textDocument/signatureHelp` and the popup shows the parameter list with the active parameter highlighted. `,` re-fires it so the active parameter advances; `)` dismisses the popup. Manually: `lsp.signature_help` (no default key — bind in `[keys.global]` if useful), and `lsp.signature_next` / `lsp.signature_prev` to cycle overloads.

## Hover docs

`K` in vim Normal mode (the classic vim "keyword help" chord) fires `textDocument/hover`; the markdown-shaped reply opens a popup near the cursor with syntax-highlighted code blocks. Same command id under standard mode is `lsp.hover` (bind to whatever — Ctrl+K is the common pick). `<leader>lh` works in both modes.

The popup dismisses on any cursor motion or `Esc`.

## Goto definition / declaration / references / implementation

| vim | Command | Action |
|---|---|---|
| `gd` | `lsp.goto_definition` | Jump to the symbol's definition |
| `gD` | `lsp.goto_declaration` | Jump to the declaration (often the same as definition) |
| `Ctrl+]` | `lsp.goto_definition` | Vim's tag-follow chord; aliased here |
| `Ctrl+T` | `nav.back` | Jump back (vim's tag-pop) |
| — | `lsp.goto_type_definition` | Jump to the *type's* definition |
| — | `lsp.goto_implementation` | For trait/interface methods, jump to an implementation |
| — | `lsp.references` | Find references → opens a picker |

Leader equivalents: `<leader>ld` (definition), `<leader>lr` (references). The jumplist (`Ctrl+O` / `Ctrl+I`) walks the history both ways.

`Ctrl+W d` does a vertical split *then* `goto_definition` — the def lands in the new pane, the original stays where it was. Handy for "show me this without leaving."

## Rename

`<leader>lR` (or palette `lsp.rename`) opens a one-line prompt seeded with the identifier under the cursor. As you type the new name, every whole-word occurrence in the active buffer is repainted with the proposed text inline — instant preview, before any request goes out.

On accept, mnml fires `textDocument/rename`. The server replies with a `WorkspaceEdit` covering every affected file; mnml opens a cross-file confirmation pane listing each edit. Approve and the edits are applied atomically across files; cancel and nothing changes on disk.

The inline preview is single-file (the active buffer); the confirmation pane is the cross-file safety net.

## Code actions

`<leader>la` (palette `lsp.code_action`) sends `textDocument/codeAction` for the cursor position (or across the active selection), including any overlapping diagnostics so quick-fixes are offered. The reply lists every action the server has — quick-fixes, refactors, organize-imports, code-action snippets — and a picker lets you choose. Accepting executes the action's `WorkspaceEdit` (and any associated `command`).

Two shortcuts skip the picker for common cases:

- **`lsp.quick_fix`** — same request, but auto-apply the *first* action. Servers front-load the most relevant one, so this matches the "fix this for me" gesture next to an inline diagnostic.
- **`lsp.organize_imports`** — code-action filtered to the `source.organizeImports` kind, auto-applied.

Both are unbound by default; bind in `[keys.global]` (e.g. `"alt-enter" = "lsp.quick_fix"`) or call from `:` (`:LspQuickFix` isn't an alias — call the command id via the palette or a key).

## Format

| Key / command | Action |
|---|---|
| `:Format` / palette `lsp.format` | Run `textDocument/formatting` on the active buffer |
| `:Format!` / `:FormatExternal` / `editor.format_external` | Pipe the buffer through the configured external formatter |
| `[editor] format_on_save = true` | Run LSP formatting before each save |
| `[editor] format_on_type = true` | Apply `textDocument/onTypeFormatting` after `}` / `;` / newline |
| `[editor] will_save_wait_until = true` | Run `textDocument/willSaveWaitUntil` before each save (for eslint --fix / organize-imports-on-save) |

External formatters fall back to a built-in table (`prettier` for js / ts / json / css / md, `rustfmt` for rust, `gofmt` for go, `ruff format -` for python, `black` for python), overridable per extension via `[formatters.<ext>]`. The external path is useful when your LSP doesn't implement formatting, or when you want a different tool than the LSP uses.

## Symbols & outline

| Key | Command | Action |
|---|---|---|
| `<leader>ls` | `lsp.symbols` | Fuzzy picker over symbols in this file |
| `<leader>lS` | `lsp.workspace_symbols` | Prompt for a query, search across every running server |
| `<leader>lo` | `outline.show` | Open the docked Outline pane (live retargets to the active editor) |

The Outline pane mirrors `textDocument/documentSymbol` for the active file as a tree; switching to a different editor pane retargets the outline automatically.

When the [right side panel](/manual/right-panel/) is open, `outline.show` hosts the Outline pane in the panel instead of splitting horizontally above the editor. The header reads ` OUTLINE`. This is the recommended placement when you want the outline always-on — it doesn't eat editor body height, and resizing the panel resizes the outline.

## Configuration

LSP config lives at `[lsp.<name>]` in `~/.config/mnml/config.toml` (and overridden per workspace at `<workspace>/.mnml/config.toml`). Each table is layered on top of the built-in default of the same name — partial overrides fall back field-by-field, so the minimum useful entry is just the field you want to change.

```toml
# ~/.config/mnml/config.toml

# Override the built-in rust entry to pass extra args
[lsp.rust]
args = ["--log-file", "/tmp/ra.log"]

# Add lua (not in the built-in table)
[lsp.lua]
cmd = "lua-language-server"
extensions = ["lua"]
root_markers = [".luarc.json", ".luarc.jsonc"]
language_id = "lua"

# Force a specific tsserver binary
[lsp.typescript]
cmd = "/usr/local/bin/typescript-language-server"
```

Fields:

- **`cmd`** — the executable. Looked up on `$PATH`.
- **`args`** — array of strings.
- **`extensions`** — file extensions (without the dot) this server handles.
- **`root_markers`** — files whose presence marks the project root (walked up from the file).
- **`language_id`** — the LSP `languageId` to tag documents with (`"rust"`, `"python"`, `"typescript"`, …).

Related `[editor]` knobs:

```toml
[editor]
format_on_save = false             # default: off
format_on_type = false             # default: off
will_save_wait_until = false       # default: off
inlay_hints = true                 # type / parameter chips at line ends
semantic_tokens_viewport = false   # for very large files; default uses full / delta
code_lens = true                   # `5 references` / `Run | Debug` chips
```

## Server lifecycle

mnml manages one server per `(root, language)` pair. The first `didOpen` for a file spawns the server (a `Cargo.toml` walk + `rust-analyzer` spawn happens on the *first* `.rs` file you open in that crate, not at workspace open — startup stays cheap). A server that fails to spawn is marked dead — mnml won't retry until you ask.

- **`:LspStatus`** / `:LspInfo` — toast the list of `(server, root)` pairs currently running.
- **`:LspRestart`** / `:LspReset` — kill every running server, clear the dead-set, then re-fire `didOpen` for every editor pane (so the right servers respawn immediately). Use this when a server gets stuck or you've just installed it on `$PATH`.

The statusline carries a small chip showing the live LSP count when at least one server is running, and a spinner during indexing (rust-analyzer's progress notifications).

## Troubleshooting

**No completions / no diagnostics on a file.** Check `:LspStatus`. If the language isn't listed, the server binary probably isn't on `$PATH` — `:Tools` will show ✗ next to it. The toast also fires when a request goes out and no server is attached (`"no language server for this file (completion)"` etc.).

**Server crashes repeatedly.** mnml marks it dead after the first spawn failure and won't retry. Fix the underlying issue (a bad `[lsp.<name>] cmd`, a missing `.cargo/config.toml`, a corrupt `target/`), then `:LspRestart`.

**Stale diagnostics.** Diagnostics are replaced wholesale per file when the server re-publishes — they shouldn't go stale unless the server itself stops emitting. `:LspRestart` is the recovery gesture; if it still doesn't refresh, that's a server bug worth filing upstream.

**Slow `workspace/symbol`.** This is a server-side query, and `rust-analyzer` in particular is fast only after indexing is done (watch the statusline progress). For interim searches use `lsp.symbols` (file-scoped) — that's an in-memory document-symbol query, instant.

**Missing root.** If `find_root` doesn't find any of the configured markers walking up, the file's own directory is used as the server's root — which is usually wrong for a multi-crate / multi-workspace project. Add the right marker to `[lsp.<name>] root_markers` or open the project from its true root.

**LSP off entirely.** Just don't configure any server and don't install any of the defaults. mnml has zero LSP-required code paths — every feature degrades to "the editor without language smarts."

## Known simplifications

mnml's LSP client is intentionally first-cut on a few axes:

- **Full-text sync** — every change re-sends the whole document. No `textDocument/didChange` deltas yet.
- **Char-based columns** — positions are sent as char offsets. LSP technically wants UTF-16 code units; this is fine for ASCII, off by a tiny amount for astral-plane code points.
- **No wait for `initialize`** — mnml fires `initialized` + `didOpen` immediately. Works with rust-analyzer / gopls / pyright / clangd / tsserver in practice; servers that strictly require ordering may emit a warning the first time.

These are deliberate — the savings from not implementing them yet outweigh the cost, and the failure mode is "slightly higher CPU when typing in huge files." They're flagged for revisit when one of them actually bites.

## Next

- [Editing](/manual/editing/) — the buffer whose mutations the LSP sees
- [Git](/manual/git/) — the gutter that shares space with the LSP gutter
- [Configuration](/reference/configuration/) — `[lsp.<name>]` and `[editor]` reference
- [Keybindings](/reference/keybindings/) — every default key, including the leader `<space>l*` group
