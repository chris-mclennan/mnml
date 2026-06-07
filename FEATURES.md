# mnml — Features

The complete, organised feature inventory. For the front-door overview see
[README.md](README.md); for design rationale see [`CLAUDE.md`](CLAUDE.md).

---

## Editing & input

- **Pluggable input layer** — a modal **vim** keymap and a modeless **standard**
  (VS Code-style) keymap, both first-class and both fully remappable. Switch at
  runtime (`:set input=vim` / `editor.toggle_keymap`). Input handlers translate
  keys into a closed set of edit operations; the editor, buffer, and render
  layers never branch on which handler is active.
- **Vim modal editing** — Normal / Insert / Visual / Visual-Block / Replace
  modes; operators + motions + text objects (`iw`, `ip`, `i(`, `if`/`ic`/`ia`
  tree-sitter objects, indent objects); registers (named, numbered delete-ring,
  yank); macros (named, persisted); marks (buffer-local + global, persisted);
  the `.` repeat; jumplist & change-list; `f`/`t` find-char; vim-surround;
  multi-cursor; flash-motion jumps; abbreviations.
- **Ex-command line** — `:w`/`:q`/`:e`, `:%s/old/new/flags` with ranges and
  marks, `:g/`/`:v/` global commands, `:norm`, `:sort`, `:!cmd`, `:r`, line-range
  ops, user-defined `:command`s, history with completion — a deep `:` surface.
- **Standard keymap** — modeless VS Code-style editing with multi-cursor
  (`Ctrl-D` add-next-occurrence, `Ctrl-Alt-↑/↓` column cursors), familiar
  chords, and the same config-driven rebinding.
- **Editor essentials** — undo/redo (persisted per file), system clipboard,
  word-wrap, auto-indent, auto-pairs, bracket-match highlight, code folding
  (manual + LSP-suggested), `.editorconfig` support, snippets with tab-stops,
  trailing-whitespace tools.

## Panes, splits & tab pages

- **Recursive split tree** — editors, terminals, diffs, and every tool view are
  `Pane`s laid out in a binary split tree. Split side-by-side or stacked.
- **Window management** — vim `Ctrl-W` chords (focus, move, resize, rotate,
  equalize, maximize), mouse click-to-focus and drag-to-resize dividers.
- **Tab pages** — vim-style `:tab*` pages, each with an independent split tree;
  a bufferline tab strip; session-persisted across launches.
- **Buffer management** — a tabline of open buffers, MRU buffer switching,
  reopen-closed-buffer, recent-files picker, alternate-file jump.

## Navigation & search

- **Fuzzy pickers** — file finder, command palette, buffer switcher, symbol
  picker, marks/clipboard/recent-commands pickers — all over one fuzzy core.
- **Which-key leader popup** — a discoverable trie of leader-key chords.
  Root groups: `f` find, `g` git, `b` buffer, `p` picker, `P` PR, `i`
  integrations, `a` AI/term, `s` split, `l` LSP, `I` insert, `t` tab, `w`
  workspace, `u` UI, `h` http, `d` diff/debug. `<leader>i` opens `+integrations`
  with chords for every forge/AWS/DB sibling: `b` Bitbucket, `g` GitHub, `l`
  GitLab, `z` Azure DevOps, `c` CodeBuild, `s` S3, `w` CloudWatch Logs, `a`
  Amplify, `d` DynamoDB, `L` Lambda, `e` EventBridge.
- **Find & replace** — in-buffer find (literal + regex, smart-case,
  incremental), replace, find history.
- **Workspace grep** — ripgrep-backed project search into a results pane, with
  cross-file replace and a per-hit toggle.
- **Quickfix & location lists** — vim-style `:cnext`/`:cprev` navigation.
- **Multi-root workspaces** — several workspace roots and multiple git repos in
  one session, with a repo switcher. The "Open folder…" (`AddWorkspace`) prompt
  shows a live-filtered directory listing (up to 12 suggestions): `↑↓` navigate,
  `Tab` autocomplete from focused row, `Enter` accept. Tilde expansion; dotfiles
  hidden unless the typed prefix asks for them. Other prompt kinds are unaffected.

## Language intelligence (LSP)

- **Completion** — as-you-type popup with documentation, lazy
  `completionItem/resolve`, snippet-format items.
- **Navigation** — go-to definition / declaration / type-definition /
  implementation, find references, document & workspace symbols, an Outline pane.
- **Diagnostics** — inline gutter signs, a Problems pane, `]d`/`[d` navigation,
  external-linter integration (eslint, ruff, shellcheck, …).
- **Code actions** — quick-fix, refactors, organize-imports, with a picker.
- **Rename** — with an inline preview and a cross-file confirmation pane.
- **Hover, signature help, inlay hints, semantic tokens, document colors,
  code lens, document links** — the standard LSP surface.
- **Hierarchies** — call hierarchy (incoming/outgoing) and type hierarchy
  (super/sub-types).
- **Formatting** — LSP formatting, format-on-save, on-type formatting,
  `willSaveWaitUntil`, plus external formatters (rustfmt, prettier, gofmt, …).
- **Tools picker** — a Mason-style installer view listing every LSP / formatter
  / linter mnml looks for, with install hints.

## Git

- **Gutter & statusline** — per-line add/modify/remove signs, a branch chip with
  ahead/behind and file-status counts, a clickable provider badge.
- **Diff pane** — Hunk / Inline / Split views, per-hunk stage / unstage /
  discard, intraline highlighting, a `/`-filter, change-density minimap.
- **Staging view** — `git status` unstaged/staged lists, stage/unstage whole
  files or dive into hunks, commit from inside the IDE.
- **Commit graph** — a coloured-lane commit DAG with a
  right-side detail panel, sortable columns, branch/date/author/subject filters,
  hash-jump, and a working-tree (WIP) row with interactive staging buttons.
- **Branch rail** — a collapsible rail of branches / worktrees / open PRs;
  checkout, create, delete, and worktree management.
- **Sync** — fetch / pull (ff-only) / push, cherry-pick, revert, tags, stash
  list & reflog pickers, an operation-level undo/redo stack.
- **Blame** — a per-line `<sha> <author>` gutter.
- **AI commit messages** — summarise the staged diff into a conventional-commit
  message, recompose `HEAD`'s message, via the `claude` CLI or Codex.
- **Browse** — open the current file / commit on the remote (GitHub, GitLab,
  Bitbucket, Azure DevOps).

## SCM & CI dashboards

- **Pipelines / builds** — recent runs for Bitbucket Pipelines, GitHub Actions,
  GitLab CI, and Azure DevOps, grouped by repo with per-branch and "mine" views.
- **Pull requests** — open PRs / MRs across all four hosts, with reviewer and
  approval counts, a cross-host PR picker, and PR ↔ pipeline cross-navigation.
- **Log viewers** — fetch and tail per-job CI logs with severity colouring.

## AI

> mnml *integrates with* AI tooling — it does not bundle a model. These
> features describe what mnml does; you bring your own CLI / API key.

- **AI panes** — run the `claude` CLI or Codex as embedded panes; tail their
  session transcripts; promote a one-shot answer into an interactive session.
- **On-selection actions** — explain / fix / refactor / write-tests on a
  selection; a free-text "ask"; results stream into a pane and a fix/refactor can
  be applied as a reviewed diff.
- **Two backends** — drive the `claude` CLI in print mode, or talk to the
  Anthropic Messages API directly (with an agentic read-only tool loop). The
  backend, model name, system prompt, and token cap are all config knobs.
- **Inline suggestions** — opt-in Copilot-style ghost text: an API backend, or a
  fully local, in-process FIM model via the sibling `fim-engine` crate (no API
  key, offline after a one-time download).
- **Context-aware chat** — a claude-chat.nvim-style wrapper that seeds a prompt
  with the active file and selection.

## Terminal & process panes

- **Pty panes** — a shell, the `claude` CLI, Codex, or any task as live terminal
  panes, with a multi-session tab strip and `:rename`.
- **Scratch terminal** — a quick docked terminal strip.
- **Tasks** — `[tasks.*]` config + a task launcher; startup tasks.

## HTTP request client

- **Request files** — send `.http` / `.rest` / `.curl` files, with multi-block
  files, `{{variable}}` templating, environments, and pre/post-request scripts
  (`@set-*`, `@assert`, `@capture`).
- **Request pane** — an editable, form-style pane (method / URL / headers /
  body), re-send, copy-as-curl, and write-back to the source file.
- **Chains** — run a `.chain.json` of dependent requests, extracting values
  between steps.
- **Discover** — turn an OpenAPI / Swagger spec into one `.curl` stub per
  operation.
- **CLI mode** — `mnml run FILE`, `mnml chain run FILE`, `mnml discover SPEC`.

## Browser & CDP capture

- **Browser pane** — launch Chrome over the DevTools Protocol; a live console,
  filtered network log, and navigation log.
- **Inspectors** — network requests (copy-as-curl, re-send as a request pane),
  a DOM tree with live highlight, cookies, web storage, and a performance panel
  — all with type-to-narrow filters.
- **Capture** — full-page and per-node screenshots, print-to-PDF, snapshot
  diffs, device emulation, multi-target and headless support.

## Debugging (DAP)

- **Debug Adapter Protocol** — launch or attach a debug adapter; breakpoints
  (incl. conditional & hit-count), step controls, an exception-breakpoints
  picker.
- **Inspection** — a call-stack pane, a variables tree with set-variable, watch
  expressions, and a REPL pane with lazy-expand. Reverse-debugging where the
  adapter supports it.

## Testing & quality

- **Playwright runner** — run tests, a grouped results pane, jump-to-source, a
  trace timeline viewer, a flaky-test dashboard with run history.
- **`.test` E2E format** — a line-based DSL (`open`, `key`, `type`, `command`,
  `click`, `expect screen …`) that drives the real `App` against a virtual
  backend. Runs via `mnml test` and under `cargo test`.

## UI & theming

- **NvChad-style chrome** — file-tree rail, bufferline, powerline statusline,
  cmdline bar, which-key, indent guides, sticky scope context.
- **94 themes** — the full NvChad base46 set (onedark, gruvbox, catppuccin,
  kanagawa, tokyonight, nord, dracula, …); switch at runtime.
- **Discoverability** — an F1 click-discovery overlay, hover tooltips, right-click
  context menus throughout, a first-launch welcome, About & Settings overlays.
- **Markdown** — a live preview pane with inline image embedding, and optional
  inline-rendered markdown in the editor.
- **Image rendering** — inline images via the Kitty / iTerm2 graphics protocols.
- **Zen mode**, **stacked notifications**, a clickable statusline.

## Headless, IPC & extensibility

- **Headless mode** — `mnml --headless` renders to a virtual screen, driven over
  a file-IPC channel (`command` in, `screen.txt` / `status.json` /
  `events.jsonl` out) — the same `App` and draw path as the terminal UI.
- **Plugins** — out-of-process helpers over the IPC channel can register
  commands that appear in the palette and resolve as keybindings.
- **Blit-host integration** — `:host.launch <binary>` spawns an out-of-process
  binary as a `Pane::BlitHost`; the binary renders into the pane over a Unix
  socket using the `tmnl-protocol` wire format. No changes to mnml needed to add
  an integration — drop a `[[ui.launcher_icon]]` entry in config. `Ctrl+E`
  returns focus to the split tree. Shipped integrations (each also runs
  standalone): `mnml-tickets-jira` (Jira ticket viewer),
  `mnml-aws-cloudwatch-logs` (live CloudWatch log-stream tail, per-tab filter
  patterns), `mnml-aws-amplify` (Amplify apps / branches / deploy-jobs viewer),
  `mnml-db-dynamodb` (DynamoDB table browser, PRIMARY key auto-resolved from
  `describe-table`), `mnml-aws-lambda` (function browser, paginated list +
  detail panel), `mnml-aws-eventbridge` (buses + rules-per-bus browser). The
  integration-icon rail ships default entries for all of
  them; palette commands `forge.open_cloudwatch_logs`, `forge.open_amplify`,
  `forge.open_dynamodb`, `forge.open_lambda`, and `forge.open_eventbridge` are
  also registered.
- **`tmnl` integration** — runs standalone in any terminal; gains native-pane
  hand-off when hosted inside the [`tmnl`](https://github.com/chris-mclennan/tmnl)
  terminal. `:tmnl.open-tab <command>` (alias `:tmnl.tab`) asks tmnl to open a
  command in a new native tab. `:tmnl.pop-pty` (alias `:tmnl.pop`) transfers the
  focused terminal pane's pty fd to tmnl via SCM_RIGHTS, making it a sibling tab
  without killing the child process (Unix only).
- **Settings overlay** — `:settings` / `view.settings` opens a keyboard-driven
  overlay (centered, ~60 % × 70 %) for everyday config toggles. Rows are
  `▸ <label>: [active] / other  *`; section headers `── UI ──` etc. Keys:
  `←→` adjust, `↑↓` move, `r` reset row, `R` reset all, `Enter` save, `Esc`
  cancel.
- **Config-driven launcher-icon strip** — the bufferline's right cluster is
  driven by `[[ui.launcher_icon]]` TOML entries (`id`, `glyph`, `fallback`,
  `command`, `color`, `tooltip`). The `command` field accepts a registered
  command id or a colon-prefixed ex-cmdline string (`:host.launch binary`).
  Setting the key replaces the built-in Claude Code + Codex defaults.
- **Config-driven integration-icon rail** — the file-tree rail's icon strip is
  driven by `[[ui.integration_icon]]` TOML entries (same fields as
  `[[ui.launcher_icon]]`). Each icon launches its sibling binary on click.
  Default entries ship for all first-party siblings; extras can be added via
  TOML or the `+` overlay — no code changes to mnml required.
- **`+` "Add integration" discovery overlay** — the `+` chip on the sidebar's
  INTEGRATIONS header (palette: `integrations.add`) opens a centered overlay
  listing the full family catalog (15 hardcoded siblings grouped by category:
  AWS, Databases, Forges, Trackers, Filesystems, Test runners) plus any
  `mnml-<class>-<name>` binaries auto-discovered on `$PATH` or well-known
  dirs. Per-row status: ✓ in rail / ✓ installed / ✗ not installed.
  Keys: `↑↓`/`jk` move, `Enter` add to rail, `i` spawn `cargo install` Pty
  pane live, `y` yank install command, `Esc` close. `integrations.refresh`
  clears the detection cache outside the overlay. `Enter` to add also
  writes the full `[[ui.integration_icon]]` list back to
  `~/.config/mnml/config.toml` (line-based strip-and-rewrite; other sections
  and comments preserved). Auto-discovered rows render with a
  `· auto-discovered` chip; `i`/`y` are no-ops for them (repo URL unknown).
- **Startup workspace picker** — `--startup-picker` (or `MNML_STARTUP_PICKER=1`)
  shows a chooser overlay on launch: [1] New file, [2] Open file…, [3–9]
  configured `[[workspaces]]` rows. Keys: `↑↓`/`jk` move, `Enter` commit,
  `1`–`9` direct jump, `Esc`/`q` skip. The `mnml.app` launcher enables this by
  default so Finder launches land on the chooser rather than `$HOME`.
- **Update-available check** — on launch, a background thread queries
  `api.github.com/repos/chris-mclennan/mnml/releases/latest` and fires a
  one-shot toast when a newer release tag is found. Opt out with
  `[ui] check_updates = false`. Skipped in headless and blit modes.

## Languages

Tree-sitter syntax highlighting for **39+ languages** — Rust, JavaScript / TSX,
Python, Go, C / C++, Ruby, Java, C#, Lua, HTML / CSS, JSON, YAML, TOML, Markdown,
Bash, Scala, Elixir, Haskell, PHP, Swift, Zig, Nix, OCaml, Dart, SQL, Kotlin,
Dockerfile, HCL / Terraform, Protobuf, Vue, Svelte, Astro, diff, and more — with
**language injection** so fenced code blocks, embedded `<script>` / `<style>`,
and other nested grammars are highlighted too.
