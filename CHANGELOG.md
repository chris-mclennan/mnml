# Changelog

All notable changes to **mnml** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Day-to-day development history lives in [`CLAUDE.md`](CLAUDE.md) (the Status
block) and the roadmap in [`.local/PLAN.md`](.local/PLAN.md); this file is the
curated, user-facing summary.

## [Unreleased]

mnml has not yet had a tagged release. The `0.1.0` line below summarises the
capabilities present in the current `main`.

### Added (2026-05-24)

- **Blit-host integration** (`Pane::BlitHost`) — `:host.launch <binary> [args…]`
  spawns an out-of-process binary and renders its output into a pane over a Unix
  socket using the `tmnl-protocol` wire format. Key events forward through;
  `Ctrl+E` releases focus. Protocol contract documented in `docs/PLUGINS.md`.
- **Settings overlay** — `:settings` / `view.settings` opens a keyboard-driven
  schema editor for everyday config toggles. Section headers, `▸ row` focus, `*`
  modified marker. Keys: `←→` adjust, `↑↓` move, `r` reset row, `R` reset all,
  `Enter` save, `Esc` cancel.
- **Config-driven launcher-icon strip** — `[[ui.launcher_icon]]` TOML entries
  drive the bufferline right-cluster. Fields: `id`, `glyph`, `fallback`,
  `command`, `color`, `tooltip`. `command` accepts a registered command id or a
  `:host.launch …` ex-string. Setting the key replaces the built-in
  Claude Code + Codex defaults.
- **tmnl tab hand-off** — `:tmnl.open-tab <command>` (alias `:tmnl.tab`),
  palette commands `tmnl.open_claude_in_tab` / `tmnl.open_codex_in_tab`: when
  mnml is hosted under tmnl, asks tmnl to spawn the command as a new native tab.
  No-ops with a toast otherwise.
- **pty fd hand-off** — `:tmnl.pop-pty` (alias `:tmnl.pop`, palette
  `tmnl.pop_pty`): transfers the focused terminal pane's pty master fd to tmnl
  via SCM_RIGHTS, turning it into a sibling native tab without killing the child.
  Unix only.
- **`aws-codebuild` Cargo feature** — `Pane::CodeBuilds` (recent-builds browser)
  and `Pane::LogTail` (CloudWatch log tail) moved out of the removed `private`
  feature into a new, generic `aws-codebuild` feature. Shells out to the `aws`
  CLI; no new crate dependencies. Off by default.
- **`run.sh` family subcommands** — `build`, `release`, `test`, `check`, `watch`,
  `help` (dev wrappers), plus `blit <socket>` (run as tmnl native client) and
  `under-tmnl [WS]` (launch tmnl with mnml as a native tab).

### Removed (2026-05-24)

- **`private` Cargo feature** — stripped from the public crate (`src/private/`,
  `src/app/private.rs`, `Pane::TestExecutions`, the four `examples/private_*.rs`).
  AWS-generic code moved to `src/app/aws.rs` under `aws-codebuild`. The private
  `internal-app` blit-host binary rebuilds the the private integration functionality as an
  out-of-process integration.

## [0.1.0]

### Added

- **Pluggable input layer** — a modal vim keymap and a modeless standard keymap,
  both fully remappable and swappable at runtime.
- **Panes & layout** — a recursive split tree, vim `Ctrl-W` window chords,
  vim-style tab pages, a bufferline, and session restore.
- **Language intelligence** — a config-driven LSP client: completion, hover,
  go-to-definition, references, rename, code actions, diagnostics, inlay hints,
  semantic tokens, hierarchies, signature help, folding, and an Outline pane.
- **Git** — gutter signs, a diff pane with per-hunk staging, a staging view, a
  coloured-lane commit graph, a branch/worktree/PR rail, blame, sync
  operations, and AI-written commit messages.
- **SCM & CI dashboards** — pipelines / builds and pull requests across
  Bitbucket, GitHub, GitLab, and Azure DevOps.
- **AI** — embedded `claude` CLI / Codex panes, on-selection explain / fix /
  refactor / write-tests actions, Copilot-style inline suggestions (API or a
  local FIM backend), and AI commit messages.
- **HTTP client** — `.http` / `.curl` / `.rest` request files, request chains,
  OpenAPI stub discovery, and an editable request pane.
- **Browser & CDP** — a Chrome DevTools Protocol browser pane with network, DOM,
  cookie, storage, and performance inspectors, screenshots, and PDF export.
- **Debugging** — a Debug Adapter Protocol client with breakpoints, stepping, a
  variables tree, watches, and a REPL.
- **Testing** — a Playwright runner with a trace viewer and flaky-test
  dashboard, and a line-based `.test` end-to-end format.
- **UI** — 94 NvChad base46 themes, tree-sitter highlighting for 39+ languages
  with injection, a which-key leader popup, markdown preview, inline image
  rendering, and a fuzzy command palette / file finder.
- **Headless mode** — `mnml --headless` driven over a file-IPC channel, plus an
  out-of-process plugin surface.

[Unreleased]: https://github.com/chris-mclennan/mnml-rs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/chris-mclennan/mnml-rs/releases/tag/v0.1.0
