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
  graphical-Git-GUI-style commit graph, a branch/worktree/PR rail, blame, sync
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

[Unreleased]: https://github.com/chris-mclennan/mnml/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/chris-mclennan/mnml/releases/tag/v0.1.0
