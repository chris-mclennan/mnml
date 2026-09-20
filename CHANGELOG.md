# Changelog

What changed in **mnml**, release by release, for the people who run it.
Development history is `git log`; design and phasing are `docs/DESIGN.md`.

The top section is the body of the next GitHub release —
`scripts/release-notes.sh` cuts it out, `release.yml` posts it. Two rules for
anything written here: no credential-shaped literals (an auth header goes in
as "an auth header written as a `{{VAR}}` reference", never as the header
itself — GitHub scrubs secret-shaped substrings inside the build manifest and
the release ships one file), and one line per change a user can see.

## v0.3.0 (unreleased)

mnml 0.3.0 is the same editor, rewritten in Zig 0.16.0. One static binary per
platform, no runtime, the same `.test` corpus green on both sides (225 of 226
at 120x40; 80x24 and 200x60 sweeps free of panics, leaks and rects outside
their parent). Everything below is what the 0.2.x user notices; the
architecture behind it is in `docs/DESIGN.md`.

### The editor

- The core: a `String` buffer and a byte cursor behind one `apply` chokepoint;
  vim and standard keymaps as two complete profiles that never leak into the
  render layer. Undo groups, registers, marks, macros, dot-repeat.
- Multi-cursor — every cursor types, deletes, selects and puts. Visual block
  yanks and deletes the rectangle. Surround (`ys` / `ds` / `cs`), align,
  `ctrl+a` / `ctrl+x`, `gq` reflow, `gcc` comment toggle, the `[` `]` pairs, the
  section / method / TODO jumps.
- A save writes the file's terminating newline.
- Incremental tree-sitter highlighting for 43 grammars, compiled in. Spans
  slide with the text as you type; the reparse waits for idle. Language
  injection (fenced code, `<script>` / `<style>`), predicates and roles.
- Sticky context: the enclosing scope's header pinned above the viewport.
  Text objects, the symbol outline, the rendered markdown preview, snippets
  with tab stops that track the text.
- Open files are stat'ed every 2 s — a clean buffer reloads, a dirty one is
  warned.

### The frame

- Splits, tab pages, per-leaf strips, the statusline, the editor scrollbar
  and pin, drag-to-resize dividers and tabs, click-count selection, the wheel
  batch, right-click menus, overlays, the palette — the Rust frame, cell for
  cell.
- The 94 NvChad base46 palettes as ZON, derived into every UI role at compile
  time. `theme.pick` previews as you move; toggle, reset, follow-the-OS.
- The first-launch wizard — seven sections, Enter writes only what was
  touched. The settings overlay — sectioned rows, the file follows the row.
- Build-artifact directories stay hidden in the tree without a `.gitignore`.
- A pane that opens beside another sizes itself by what is already there:
  the first one takes an empty editor area whole, the third makes thirds and
  the fourth quarters, and a stack inside one of the columns keeps its own
  proportions. Integrations, terminals and session panes all follow the one
  rule now. `integrations.arrange = .fixed` — a row under Integrations in the
  settings overlay — puts back the old half-the-active-pane sizing.

### Config — ZON, not TOML

- `config.zon` beside your `config.toml`; mnml 0.3.0 never touches the TOML.
  Run `mnml export-config-zon` on 0.2.22 once to convert. Three layers (user,
  workspace, defaults), a typed schema, `Patch(T)` merges derived at compile
  time, `persistScalar` splices one value back into the file with a backup.
- Workspace trust is decided at load and asked once.
- Two profiles, so one machine can run the mnml you live in and the mnml you
  are working on. `MNML_PROFILE=dev` (or `--profile dev`) moves the data root
  to `~/.config/mnml-dev`, the session file to `.mnml/session-dev.zon`, the
  IPC mailbox and the running-instance marker to their own names, and paints
  a `dev` chip on the statusline with a matching window title. The first dev
  launch seeds itself from your stable setup — config, integration manifests
  and configs, launchers, themes — and never copies a credential, a cache or
  a session; `mnml profile` says which one you are in and `mnml profile seed
  --force` copies again.
- `docs/CONFIG.md` is the complete commented `config.zon`, and a test parses
  it.

### Panes

- `Pane.pty` — a shell or command in a split, painted from the libghostty-vt
  grid. `cargo` / `npm` / `pytest` / `go` runners and `test.*` in a pty pane,
  the tools picker, configured tasks (`task.run`, `task.<name>`, `:task`,
  startup tasks).
- Git: status, diff, blame, graph, staging — every call on a worker, results
  posted back as one event. Gutter marks and blame labels on the editor. One
  `Repo` per repository, a job queue, the one-hunk patch writer.
- Git, line by line: select rows in the diff pane (`v`, shift+arrows, a drag)
  and stage, unstage, discard, stash or commit just those lines — the same
  selection for the keys, the chips, the row menu and the palette. `t`
  cycles the diff view now that `v` selects.
- Git, conflicts: a conflicted file resolves in the editor. The status pane
  lists it under `⚠ Conflicts`, enter opens it with every block tinted and a
  row of chips above it (`Ours · Theirs · Both · Edit · Split · AI resolve`);
  vim `co` / `ct` / `cb` and `]x` / `[x`, standard `alt+1..3` and `f8`;
  `Split` shows ours against theirs in the diff pane; saving with no marker
  left stages the file.
- LSP: one stdio JSON-RPC transport shared with DAP. Diagnostics, completion,
  hover, peek, navigation, rename, formatting, code actions, symbols.
- DAP: breakpoints, watches, the debug and REPL panes, the `dap.*` commands. A
  scripted adapter in process drives the whole session under test.
- AI: ghost text, the agentic loop on the confirm channel, Claude Code and
  Codex panes, every `ai.*` runner, the Claude Agents dashboard (sessions
  across workspaces, filters, pause chip, live tail, kill), the 24 h spend
  report and the statusline meter.
- HTTP: `Pane.request` — the tabbed request pane, the send worker, the
  `http.*` commands. The request parser, envs, cookie jar, JWT decoding, SSE,
  a JSON-schema subset, HAR and Postman import, the captured log, chains,
  bench, mocks, history. `Pane.websocket` (a WebSocket client by hand) and
  `Pane.browser` (the CDP wire layer). The CLI: `run`, `chain run`,
  `discover` (JSON and a YAML subset), `sync`, `sync-check`, `proxy`.
- HTTP, beyond 0.2.x: an env file edited on disk reloads on its own
  (a toast says so); COLLECTIONS lists a multi-block file's `###`
  blocks and renames, duplicates, deletes and moves a request or a
  block from the row menu; `http.find_request` (`ctrl+shift+r`,
  `<leader>hr`) is a fuzzy picker over every block of every file;
  `:id` path segments take their `# @path id=…` value on send and get
  a `Path` group on the Params tab; the Body tab has a mode chip —
  raw, JSON (formatted on send), form-urlencoded, multipart with
  `name = @file` parts — that round-trips through curl's `-F` and
  `--data-urlencode`; `# @description` shows under the URL and
  `# @tags` feed the filter (`tag:smoke`) and the picker.
- The TODOS panel, and the reference module behind it — scan worker,
  snapshot, commands, panel, mouse — that every other panel is checked
  against.

### Testing

- `mnml-zig test` runs the shared `.test` corpus headlessly on a
  `DebugAllocator` with safety on; a leak fails the file. `--gate` runs the
  47-file Phase-0 set, `--sizes 80x24,120x40,200x60` sweeps the widths.
- Every unit test runs on `std.testing.allocator`. Leak = failure. The suite
  runs in Debug and ReleaseSafe; every PR cross-compiles the exe and every test
  binary for all five shipped targets.

### Shipping

- Five targets from one runner — `aarch64-apple-darwin`,
  `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`,
  `aarch64-unknown-linux-gnu`, `x86_64-pc-windows-gnu` — all ReleaseSafe, all
  `-Dcpu=baseline`. `.tar.xz` (`.zip` on Windows) with a `.sha256` each,
  `sha256.sum`, `mnml-installer.sh`, `mnml-installer.ps1`, an MSI for winget,
  `.deb` / `.rpm`, a Homebrew tap bump. Asset names drop the `-rs`:
  `mnml-<triple>.tar.xz`.
- `--version` prints the tag and the profile it would run in; a dev build
  prints the manifest version, the git short SHA and `-dirty`.

### Not in 0.3.0 (pin 0.2.x if you need one)

- Integrations (the bridge protocol and every `mnml-*` integration) — back
  when rewritten in Zig with the v2 protocol and SDK, jira and bitbucket
  first.
- Local FIM completion (API-only for now), brotli, WebP, the glyph-builder SVG
  preview.
