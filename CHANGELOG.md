# Changelog

All notable changes to **mnml** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Day-to-day development history lives in [`CLAUDE.md`](CLAUDE.md) (the Status
block); this file is the curated, user-facing summary.

## [Unreleased]

mnml has not yet had a tagged release. The `0.1.0` line below summarises the
capabilities present in the current `main`.

### Added (2026-06-06)

- **Three new blit-host integration icons** — `cloudwatch_logs`, `amplify`,
  and `dynamodb` added to the default `integration_icons` list in `src/config.rs`.
  Each icon in the file-tree rail launches its sibling binary on click:
  - `cloudwatch_logs` → `:host.launch mnml-aws-cloudwatch-logs` (live log-stream
    tail viewer; per-tab filter patterns)
  - `amplify` → `:host.launch mnml-aws-amplify` (Amplify apps / branches /
    deploy-jobs; `apps` and `app` tab kinds)
  - `dynamodb` → `:host.launch mnml-db-dynamodb` (DynamoDB table browser; smart
    PRIMARY column auto-resolved via `describe-table`)
- **Three new palette commands** — `forge.open_cloudwatch_logs`,
  `forge.open_amplify`, `forge.open_dynamodb` (group `forge`); accessible from
  the command palette and bindable as keychords.
- **Three new which-key chords** under `<leader>i` (`+integrations`): `w` →
  CloudWatch Logs viewer, `a` → AWS Amplify viewer, `d` → DynamoDB browser.

### Fixed (2026-06-06)

- **Which-key `+integrations` was unreachable** — `'i'` was double-registered
  at the root trie with both `+integrations` and `+insert`; `BTreeMap` dedup
  silently dropped `+integrations`. Fixed by moving `+insert` to capital `'I'`.
  Regression test added (`integrations_group_is_reachable`).

### Added (2026-06-02)

- **Startup workspace picker** (`#76`) — `--startup-picker` CLI flag (or
  `MNML_STARTUP_PICKER=1` env var) shows a JetBrains-style chooser on launch:
  [1] New file (current workspace), [2] Open file… (`view.discovery`), [3–9]
  configured `[[workspaces]]` rows. Keys: `↑↓`/`jk` move, `Enter` commit,
  `1`–`9` direct jump, `Esc`/`q` skip. The `mnml.app` and `mnml-nightly.app`
  launchers export `TMNL_LAUNCH_ARGS="--input standard --startup-picker"` so
  clicking the icon from Finder lands on the chooser instead of `$HOME`.
  New modules: `src/app/startup_picker.rs`, `src/ui/startup_picker.rs`.
- **Update-available check** (`#77`) — on launch (skipped in headless/blit
  modes; opt-out via `[ui] check_updates = false`), a background std thread
  GETs `api.github.com/repos/chris-mclennan/mnml/releases/latest`, parses
  `tag_name`, and compares it to `CARGO_PKG_VERSION`. When a newer tag is
  found, `App::tick` fires a one-shot toast with the release URL. New module:
  `src/update_check.rs`.
- **Nightly app bundle** (`#78`) — `./scripts/build-app.sh --nightly` produces
  `target/mnml-nightly.app` with bundle ID `sh.mnml.app.nightly`. Coexists
  with the stable bundle in `/Applications`. The nightly launcher always execs
  `~/Projects/mnml/target/release/mnml` (latest local `cargo build --release`)
  rather than shipping a bundled binary. Icon: blue background + charcoal
  wordmark (stable is the inverse).

### Changed (2026-06-02)

- **`build-app.sh` improvements** — stamps `CFBundleVersion` with a per-build
  timestamp so Finder picks up icon/launcher changes without `killall Dock`.
  Strips icon transparent margin to avoid macOS Tahoe's glass-template grey
  bezel. Bumps `LSMinimumSystemVersion` from `10.14` to `11.0` (removes the
  misleading Tahoe "Support Ending for Intel-based Apps" warning that triggers
  on any pre-Big-Sur app). Hardens `scripts/launcher.sh`: no `set -eu` + zshrc
  sourcing; explicit static PATH; falls back to
  `/Applications/tmnl.app/Contents/MacOS/tmnl` when no CLI symlink is present.

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
  and `Pane::LogTail` (CloudWatch log tail) moved out of a private feature into
  a generic `aws-codebuild` feature. Shells out to the `aws` CLI; no new crate
  dependencies. Off by default.
- **`run.sh` family subcommands** — `build`, `release`, `test`, `check`, `watch`,
  `help` (dev wrappers), plus `blit <socket>` (run as tmnl native client) and
  `under-tmnl [WS]` (launch tmnl with mnml as a native tab).

### Removed (2026-05-24)

- **Private workspace-integration Cargo feature** — stripped from the public
  crate. AWS-generic code moved to `src/app/aws.rs` under `aws-codebuild`. The
  removed integration is rebuilt as an out-of-process blit-host binary (see
  `docs/INTEGRATIONS.md` for the pattern).

## [0.1.2] - 2026-05-31

### Changed

- macOS `.dmg` artifact now ships with cargo-dist's standard naming
  (`mnml-rs-<triple>.dmg`).
- Install page's macOS download button points at the DMG (drag-to-install).
- Smaller fixes (release pipeline cleanup).

## [0.1.1] - 2026-05-31

### Added

- First `.app` bundle + DMG artifacts shipping with releases.
- Refactor: `build-app.sh` / `build-dmg.sh` accept `--bin-path` so CI can
  package the cargo-dist-built binary directly.

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

[Unreleased]: https://github.com/chris-mclennan/mnml/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/chris-mclennan/mnml/releases/tag/v0.1.0
