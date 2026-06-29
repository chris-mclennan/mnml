# Changelog

All notable changes to **mnml** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Day-to-day development history lives in [`CLAUDE.md`](CLAUDE.md) (the Status
block); this file is the curated, user-facing summary.

## [Unreleased]

### Added (2026-06-29)

- **Right panel v5 polish** — `Ctrl+Alt+W` closes the active tab from the
  keyboard (`view.right_panel_close_tab`); tab right-click menus gain
  **Close other tabs** and **Close all tabs** (when ≥2 tabs); right-clicking
  the `×` button opens the same context menu as the active tab; the `×`
  paints two visually distinct states — `bg2` bridge when the active tab is
  rightmost (so the `×` reads as its close button), `bg_dark` + `comment`
  styling when not (so it reads as "acts on the active tab, not this
  chip"); empty-state hint lists all five routable commands clickably
  (`:outline.show`, `:lsp.diagnostics`, `:ai.chat`, `:find.grep`,
  `:test.run`); header now reads lowercase `right panel`.
- **Right panel chip short forms** — when the per-chip budget would
  truncate past the live count / status glyph, the tab label falls back
  to a short form that keeps the information that matters:
  Diagnostics → `✗N⚠M`, Tests → `✓N` / `✗N` / `…`, Grep → `q… N` (or
  `(N)` at the tightest), AI → `AI ✦` (or just the marker), Outline →
  file stem.
- **HTTP `###` block navigation** — `<leader>h]` / `:http.next_block`
  and `<leader>h[` / `:http.prev_block` jump the cursor between blocks
  in multi-block `.http` / `.rest` files. Wraps at EOF/BOF; viewport
  reveals the cursor if it lands offscreen.
- **HTTP `[http] default_env` config key** — set a sticky default env
  per-workspace (`<workspace>/.mnml/config.toml`) or user-global
  (`~/.config/mnml/config.toml`). Resolution chain is now
  `--env` → `$MNML_ENV` → `[http] default_env` → `.rqst/config`.
- **HTTP history headers + body preserved** — every `http.send` entry
  now persists the request headers and body in addition to method / URL
  / status / duration. Re-firing from `:http.history` reconstructs a
  complete curl (`-X`, every `-H`, `--data-raw`) instead of the
  method+URL-only minimal form. Older entries still re-fire as the
  minimal form.
- **Lookup scan is recursive** — `:http.lookup`'s file picker now walks
  subdirectories under `.rqst/lookups/` (the prior flat read_dir
  silently missed nested files). Skips `target`, `node_modules`, and
  dotfile entries. All three extensions (`.curl` / `.http` / `.rest`)
  picked up by the same walker.
- **Per-block mock sidecars** — multi-block `.http` files now save one
  `.mock.json` per `### named` block:
  `requests.<block-name>.http.mock.json`. Unnamed leading blocks fall
  back to the bare sibling path (`requests.http.mock.json`); single-
  block `.http` save still falls through to whole-file overwrite. The
  prior shared-sidecar shape silently overwrote block A's mock when
  block B was saved.
- **Vim operator inclusivity** — `de` / `ye` / `ce` now include the
  destination character (vim's `:help inclusive`). `d$` / `y$` / `c$`
  include the last char of the line. `cw` / `cW` are remapped to `ce`
  / `cE` (vim canon: change-word excludes trailing whitespace).
- **Vim `Ctrl+R Ctrl+W` / `Ctrl+R Ctrl+A` in INSERT** — insert the
  identifier (or full WORD) under the cursor at the caret. Both chords
  are checked before the lowercase-letter register-paste arm, so
  `Ctrl+R W` no longer disappears into a `"w` register read.
- **Vim `Ctrl+Shift+[` / `Ctrl+Shift+]` in NORMAL** — fold / unfold
  chords reach the editor instead of being eaten by the vim bracket
  prefix. The bracket prefix now guards on `!ctrl` so only the bare
  brackets feed `[c` / `]c` (git hunks) and `[d` / `]d` (diagnostics).
- **Spend report runs on a background thread** — `:ai.spend_today`
  opens the pane immediately with `loading = true`; the JSONL scan
  runs in a worker; `App::tick` polls the mpsc channel and swaps the
  snapshot in when the worker drains. Title bar shows
  `· computing…` while pending. Totals toast fires from the drain
  path (was unreachable inline). `r` (refresh) and pane `Drop` set a
  cooperative `Arc<AtomicBool>` abort flag — the worker stops at the
  next per-file check, within a few hundred ms.
- **`Ctrl+P` workspace affinity** — file-picker items carry a
  `PickerItem.priority` field; `refilter` sorts
  `(priority desc, score desc, index asc)`. Current-workspace files
  (priority 2) outrank cross-workspace recents (priority 1) and
  extra-workspace tree entries (priority 0) regardless of fuzzy
  score. Fixes a regression where a shorter cross-workspace label
  (`lib.rs`) beat a longer current-workspace path (`src/lib.rs`)
  even when the user typed the longer pattern.

### Added (2026-06-28)

- **Right side panel** — a collapsible panel on the right editor edge. Toggle
  with `Ctrl+Shift+B`, the EC00 icon in the palette bar, or `:set rightpanel` /
  `:set rp!`. Drag the left-edge grip to resize. Visible state and width persist
  via `session.json`; config defaults: `[ui] right_panel_visible` and
  `[ui] right_panel_width`. Palette command `view.toggle_right_panel`; which-key
  chord `<leader>tr`. Settings overlay gains two new rows (visible + width).
- **Integration `enabled` opt-in** — every integration chip now carries an
  `enabled` flag. Only `browser` is enabled by default. Right-click a chip →
  Enable / Disable; the change is persisted back to TOML. Disabled chips render
  dim and don't fire on click. New palette commands: `integrations.toggle_enabled`,
  `integrations.edit`, `integrations.remove`.
- **External tool launchers** — `tools.htop` / `tools.iftop` / `tools.btop`
  (also `term.htop` / `term.iftop` / `term.btop` aliases) probe `$PATH` and
  open the tool in a Pty pane, or fire a platform-aware install-hint toast
  (Homebrew / apt / winget). Which-key chord `<leader>...b` (btop).
- **Icon picker** — `integrations.icon_picker` (`<leader>ip`) opens a ~70-glyph
  Nerd Font browser organised by category. Accepting a glyph copies the character
  and its `\u{XXXX}` escape to the clipboard.
- **Pty panes in bufferline** — terminal and Claude Code sessions get bufferline
  tabs with a `$` suffix and a close button. `:bn` / `:bp` skip Pty tabs.
- **Palette bar redesign** — sidebar toggle + right-panel toggle + flat
  integration chips in the workspace-to-right-cluster gap + add-integration `+`
  (EA7C codicon). Compact-mode right cluster drops TABS instead of vanishing at
  narrow widths.
- **Drag-to-split improvements** — orphan-pane recovery when the source pane is
  alone in its leaf; rect-clear architecture fixes multiple stale-rect bugs.
- **Hover and right-click coverage** — every palette-bar chip now has a tooltip
  (hover for description) and a context menu (right-click for actions).
- **Right panel v2** — when the panel is visible, `outline.show` and
  `lsp.diagnostics` host inside it instead of splitting the editor body.
  Header switches between OUTLINE / DIAGNOSTICS based on hosted-pane kind, and
  a `×` button on the header evicts the hosted pane (panel stays open, returns
  to the empty-state copy). Below 16 cells the body shows "too narrow — drag
  edge wider" instead of cramped pane content. Empty-state copy now teaches
  the two commands.
- **Shift+F10 opens the context menu for the focused element** — keyboard
  equivalent of right-click. Routes Focus::Tree → tree-row menu, Focus::Pane
  → bufferline tab menu, and falls back to the cursor's most-recent
  `hover_chip` (integration / launcher / gear menus). Palette command
  `view.context_menu_at_focus`. VS Code + macOS convention.
- **Chord-chain leader-letter fix** — in standard input mode the chord chain
  was eating the first leader letter when its fallback opened whichkey, so
  `<leader>tr` required `Ctrl+K t t r` instead of `Ctrl+K t r`. Now the
  opener letter is fed to the just-opened whichkey overlay.
- **`Ctrl+N` in vim INSERT** reaches the keyword-completion handler
  (`editor.keyword_complete`) instead of being stolen by the global
  `file.new` chord. `Ctrl+P` stays bound globally (palette / recents).
- **`:set rightpanel` vim semantics** — `:set rightpanel` enables (idempotent),
  `:set rightpanel!` toggles, `:set norightpanel` disables. Matches `:set
  invrightpanel` for the bang-equivalent.

### Refactored (2026-06-28 evening)

- **9-step file split** — `src/app/mod.rs` shrank from 14,234 → ~11,500 lines
  and `src/tui.rs` from 7,712 → ~1,700 lines. New siblings:
  `src/app/{util,sibling_install_methods,workspace_methods,cloud_agents_methods,cmdline_methods}.rs`
  and `src/tui/{chord,mouse}.rs` plus `src/tui/handlers/{overlay,pane}.rs`.
  Pure non-destructive — every function kept its signature; some private fns
  elevated to `pub(crate)`. 977 → 980 tests pass; verified by a post-split
  regression sweep (0 issues).

### Fixed (2026-06-28)

- `run.sh` and `dev.sh` prepend `/opt/homebrew/opt/zig@0.15/bin` to PATH so
  `libghostty-vt-sys`'s build.rs doesn't silently fail on macOS shells that
  don't have zig in PATH. Without this, `./run.sh restart` would loop on a
  stale binary while appearing to rebuild.

### Removed (2026-06-22)

- **Tmnl integration removed.** Mnml is now terminal-agnostic. Pivoted to
  "mnml runs in any terminal; let the terminal handle rendering quality."
  - `Pane::BlitHost` + the entire blit-protocol client; `mixr_host`,
    `pane_host`, `chrome_chips` modules.
  - `--blit`, `--no-native-promote` CLI flags; `TMNL_TRANSFER_SOCKET`
    auto-promote-to-tmnl-native-tab path; `MNML_BLIT_SOCKET` env var.
  - `:host.launch`, `:tmnl.open-tab`, `:tmnl.pop-pty` ex commands;
    `tmnl.*` palette commands.
  - `tmnl-protocol` Cargo dependency.
- Reset default integration icons from `:host.launch <bin>` to `:term <bin>`
  (sibling tools open as Pty panes now).

### Added (replacing removed behaviour)

- `mixr.show` palette command + `App::open_mixr` — opens mixr as a
  Pty pane (replaces the prior `mixr_host` docked panel).

mnml has not yet had a tagged release. The `0.1.0` line below summarises the
capabilities present in the current `main`.

### Added (2026-06-06) — integration discovery overlay + folder browser

- **`+` "Add integration" discovery overlay** — a `+` chip on the sidebar's
  INTEGRATIONS header (and the palette command `integrations.add`) opens a
  centered overlay listing the full family catalog (15 hardcoded siblings,
  grouped by category: AWS, Databases, Forges, Trackers, Filesystems, Test
  runners). Per-row status: ✓ in rail (green) / ✓ installed (cyan) / ✗ not
  installed (red). Keys: `↑↓`/`jk` move, `Enter` adds to rail, `i` spawns
  a `cargo install` Pty pane live, `y` yanks the install command, `Esc`
  closes. New modules: `src/family_catalog.rs`, `src/app/discovery.rs`,
  `src/ui/discovery_overlay.rs`.
- **Pty install from overlay** — pressing `i` on a not-installed row runs
  `cargo install --git <repo> --tag <ver> <binary>` in a live Pty pane; the
  overlay closes so the pane gets the screen. Re-opening the overlay after
  install picks up the new state (detection cache cleared on open). No-op
  for auto-discovered entries (repo URL unknown).
- **TOML write-back persistence** — `Enter` to add a sibling to the rail now
  also rewrites the `[[ui.integration_icon]]` section of
  `~/.config/mnml/config.toml` via a line-based strip-and-rewrite. Other
  sections, comments, and whitespace are preserved. Idempotent across
  multiple opens/adds. Toast reports the config path on success or an error
  on failure.
- **Auto-discovery of community siblings** — the `+` overlay also surfaces
  any `mnml-<class>-<name>` binary found on `$PATH` or well-known dirs that
  is not in the hardcoded catalog. Category is derived from the class prefix;
  icon uses a cog glyph with a category-appropriate color. These rows render
  with a `· auto-discovered` chip in the status column. `i` and `y` are
  no-ops (repo URL unknown); `Enter` to add to rail works normally.
- **Folder browser for "Open folder…" prompt** — the `AddWorkspace` prompt
  now shows a live-filtered directory listing below the input (capped at 12
  suggestions). `↑↓` navigate rows, `Tab` autocompletes from the focused row,
  `Enter` accepts the focused row or the typed input. Tilde expansion, dotfile
  skip unless prefix asks, case-insensitive prefix match. Other prompt kinds
  (`GitCommit`, `Find`, etc.) are unchanged — controlled by the new
  `is_path_kind()` predicate on `Prompt`.

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

### Added (2026-06-06) — Lambda + EventBridge

- **Two new blit-host integration icons** — `lambda` (nf-md-lambda, orange,
  `:host.launch mnml-aws-lambda`) and `eventbridge` (nf-md-bus, pink,
  `:host.launch mnml-aws-eventbridge`) added to the default
  `integration_icons` list in `src/config.rs`.
- **Two new palette commands** — `forge.open_lambda` and
  `forge.open_eventbridge` (group `forge`).
- **Two new which-key chords** under `<leader>i` (`+integrations`): `L` →
  AWS Lambda browser (capital, because lowercase `l` is GitLab), `e` →
  EventBridge buses + rules browser.
- **Two new Manual pages** — `site/src/content/docs/manual/integrations/
  aws-lambda.md` and `aws-eventbridge.md`.
- **First cross-sibling handoff** — Lambda's `L` chord also launches
  `mnml-aws-cloudwatch-logs`; v0.2 will auto-scope to the function's log
  group.

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
