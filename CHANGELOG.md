# Changelog

All notable changes to **mnml** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Day-to-day development history lives in [`CLAUDE.md`](CLAUDE.md) (the Status
block); this file is the curated, user-facing summary.

## [Unreleased]

## [0.2.11] - 2026-08-12

Two flagship features on 8/11 — the **first-launch wizard** and the
**per-integration auth SDK** — plus a big 8/12 add: **L2 demo mode**
(`mnml --demo`), **ghost-text via Claude Code sub**, and a wizard
+ hover-help polish pass driven by user feedback.

### Added

- **First-launch wizard** (`first_launch.show`) — modal that
  auto-opens on first-ever mnml launch, walks new users through
  6 setup questions: AI ghost-text backend (Claude API / Local /
  Skip), input style (vim / standard), Nerd Font check, Claude
  Code + Codex install, VSCode `code` shim, process monitors.
  Install sections spawn a Pty pane running the actual command
  (`npm install -g …`, `sudo ln -sf …`, `brew install …`).
  Esc = "Ask me later"; Enter = "Finish" (persists + suppresses
  future auto-open).
- **Per-integration Settings pane + `[[auth]]` manifest schema.**
  Integration authors declare auth fields (`kind` = secret / text
  / url / email / number, `env_fallback`, `help_url`, `required`)
  via `mnml-bridge 0.7.0`'s new `AuthField`. mnml core drives
  three surfaces from those declarations:
    - **Configure pane**: right-click chip → "Configure…"
      renders a modal form (secrets masked). Ctrl+S writes to
      `[auth_values]` in the same manifest TOML.
    - **First-hit auth guard**: firing a command with a required
      field unset (and no env fallback) opens the Configure pane
      instead of silently spawning a broken Pty.
    - **Pty env-injection**: at spawn time, `[auth_values]` flow
      through as env vars using each field's `env_fallback` name
      — cross-integration, so configuring bitbucket once gives
      jira's Fix Versions view its `$BITBUCKET_ACCESS_TOKEN` for
      free.
- **Pilot siblings** shipped with `[[auth]]`: `mnml-msg-slack
  0.1.3` (bot_token + team_id), `mnml-forge-bitbucket 0.3.3`
  (app_password + username), `mnml-tracker-jira 0.2.3` (site_url
  + email + api_token).
- **`hover-help-writer` agent** (`.claude/agents/`) — audit/fill/
  verify modes over `src/ui/info_view_copy.rs`; enumerates every
  `HoverChip` variant + menu item + tree language, diffs
  against the copy dictionary, reports gaps + drift.
- **`pr-reviewer` agent** — fetches a GitHub PR into an isolated
  worktree, runs cargo build/clippy/test on the branch, stages a
  severity-ranked review at `.mnml/pr-reviews/<N>.md`. Never
  posts to GitHub — user posts after reading.
- **`crates/fim-engine/`** — the local FIM completion engine is
  now a workspace member (was a sibling repo at `../fim-engine/`,
  now vendored via `git subtree` with full history preserved).
  Worktrees under the repo tree work again; no more cross-repo
  coordination.
- **Site manual**: 2 new pages under `site/src/content/docs/manual/`
  — first-launch wizard walkthrough + integration auth deep-dive.
- **L2 demo mode** (`mnml --demo` / `./run.sh demo`). Boots against
  a bundled Loop / Bloom Labs sample workspace (`demo/workspace/`)
  copied to a per-user cache dir + git history seeded from the
  shipped `demo/workspace-git.tar.gz` (fictional 10 commits, 4
  authors, 2 feature branches). Auto-spawns a Python HTTP mock
  server on localhost:7071 that serves 40 JSON fixtures under
  `demo/fixtures/{jira,bitbucket,github}/` — populated Jira
  boards + sprints + tickets, Bitbucket repos + PRs + pipelines,
  GitHub PRs + Actions runs. Env-injects the sibling env vars
  (`JIRA_BASE_URL` etc) so integration panes route through the
  mock. Clears `[[workspaces]]` from the in-memory config so the
  tree rail doesn't leak the user's real workspace favorites.
  Screenshot-ready without exposing real work.
- **AI ghost-text via Claude Code subscription** (`SuggestBackend::
  ClaudeCode`) — reuses the OAuth access token Claude Code caches
  (via `crate::ai_usage::read_claude_token`) so ghost-text calls
  bill against Max/Pro plan quota instead of requiring a separate
  `$ANTHROPIC_API_KEY`. Same `/v1/messages` endpoint; `x-api-key`
  header carries the OAuth token (Anthropic 401s Bearer-carried
  OAuth as of early-2026), + `anthropic-beta:
  claude-code-20250219,oauth-2025-04-20` + Claude-Code identity
  system-prompt fragment. Wizard's AI section gains a 4th radio
  ("Claude Code sub — uses your Max/Pro plan") and auto-selects
  it when `claude` CLI + `~/.claude/` are both present. Grey-area
  vs. Anthropic TOS — flagged in the code + docs.
- **`./run.sh demo`** subcommand + interactive-menu entry — mirrors
  `./run.sh` shape (rebuild-on-exit-75 loop). Sets
  `$MNML_DEMO_WORKSPACE` so `./run.sh restart|stop|status` from
  another shell find the running instance's IPC dir at a stable
  path.

### Changed

- **Wizard sections numbered** (1. AI ghost-text / 2. Input style
  / …) with horizontal rules between them — fixes the wall-of-text
  feel; connects with the existing `[1-6] jump section` hint.
- **Wizard input-style row** pre-selects the persisted config value
  but tags the persisted one with `(current)`. `Enter` no longer
  silently overwrites `editor.input_style` — the row must be
  actively cycled (via ←/→/h/l) for the wizard's Finish path to
  persist. Prevents a returning vim user who reopens the wizard
  for the Nerd Font check from losing their vim mode.
- **`hover_tooltip` opt-out** — new `[ui] hover_tooltip` config,
  `view.toggle_hover_tooltip` palette command, `:set
  [no]hovertooltip` ex-command, Settings-overlay row. Info-View
  hover-help covers most surfaces already; the popup was
  annoying users. Off = popup silent, on = original behavior.
- **Wizard AI ghost-text section**: install commands now use
  Anthropic's + OpenAI's official `curl | sh` shell installers
  (`curl -fsSL https://claude.ai/install.sh | bash` +
  `curl -fsSL https://chatgpt.com/codex/install.sh | sh`)
  instead of the outdated npm-global path.
- **Wizard Nerd Font section**: press Space to auto-install
  Symbols Nerd Font Mono (brew / winget / curl per OS) + shows a
  terminal-specific config hint for ghostty / iTerm / Terminal.app
  / WezTerm (font restart warning included).

### Fixed

- **Hover-help panel** 120ms debounce so dragging the mouse across
  tree rows no longer flickers the info-box copy rapid-fire.
  Rapid mouse motion resets a pending timer; content only swaps
  after the fresh target has been stable for the debounce window.
  First paint renders immediately (no lag opening the panel).
- **Wizard headless SEV-1** — portable-choice prompt was covering
  the wizard's first paint in `--headless` because interactive-only
  callers can't dismiss it. Gated `maybe_show_portable_choice_on_launch`
  behind `!args.headless`; headless callers can still choose portable
  via `mnml.choose_data_layout` on the palette.
- **Palette-from-prompt** — Ctrl+Shift+P was consumed by the prompt
  handler when a prompt was open; now dispatches to
  `open_command_palette` first.
- **8 CI-red e2e tests** — space-eating in vim insert / DAP REPL
  / any typed-text surface, plus settings-overlay Esc requiring
  two presses to close and arrow keys not adjusting rows. Root
  cause: R9's `<space>ff` binding made bare space a leader
  prefix. Fix: new `InputHandler::is_op_pending()` trait method
  + broader `pane_wants_bare_space` bypass. 223/223 e2e green.
- **Slack glyph codepoint** — F03EF was NOT slack; the actual
  `nf-md-slack` is U+F04B1. Fixed in `icon_catalog.rs`,
  `marketplace.rs`, installed manifests, AND the msg-slack
  sibling's `install.rs` so future installs write the correct
  codepoint.
- **Hover-help panel** got a 1-row bottom cushion so the last
  content line isn't flush against the statusbar.

### Merged

- **PR #27 from ICodeGorilla** — Windows `zig` target detection
  fix so `x86_64-pc-windows-gnu` builds don't silently ABI-
  mismatch to msvc. Approved via the new `pr-reviewer` agent.

## [0.2.10] - 2026-08-09

Re-release of v0.2.9 because the v0.2.9 release workflow scrubbed
the plan output as containing a secret (a stored-secret substring
match on a CHANGELOG phrase) and skipped the entire build matrix
— v0.2.9 shipped with zero binaries. Sanitized the trigger phrase,
plus a small rollup of fixes + one framework addition.

### Fixed

- **Menu-bar Alt+W panic on small terminals.** Window menu is 27
  rows; on a 26-or-shorter terminal the dropdown drew past the
  bottom and panicked in ratatui's Buffer bounds check. Height
  now clamps to screen.
- **Menu-bar Alt+letter for clipped menus was silently broken**
  (initial fix landed as v0.2.9 but the dropdown still bailed
  when the menu chip was clipped). Now paints at a fallback
  origin so keyboard nav works even when the parent chip is
  hidden behind the workspace cluster.
- **Vim Ctrl+O / Ctrl+I stolen by file picker.** The chord
  hijacked the jumplist. Ctrl+O / Ctrl+I now own the vim
  jumplist chord in vim mode; file picker gets Ctrl+Shift+O.
- **`:e file.md` opened MdPreview** instead of the raw editor.
  Ex-command edit paths now route to the raw buffer regardless
  of the config's default markdown-render preference.
- **HTTP panel MOCKS section read a stale in-memory cache** and
  FILES tab surfaced `.mock.json` sidecar files. MOCKS now
  re-reads on refresh; FILES filters `.mock.json` out.
- **Palette ranking now boosts exact-token matches** so a full
  command id wins over a prefix-only hit (`hover-help` no longer
  finds `view.help` first).
- **Browser navigate prompt** — first keystroke now select-all
  replaces the seed URL instead of appending after it.
- **Integration chip color allow-list** rejected white / black
  as "not a color". Both now allowed.
- **CI test flakes on Ubuntu + Windows.** Three tests asserted
  stale hardcoded defaults (integration-glyphs, Claude chip
  color); rewritten to read from the live constant. Fourth
  test (`purge_integration_glyph_state_drops_svg_and_assignment_entry`)
  needed a hermetic HOME+XDG guard so it didn't sniff the CI
  runner's `$HOME/.config/mnml`.

### Added

- **Every runtime UI / editor toggle now persists to user config.**
  Previously toggling workspace dots, wrap, whitespace, rainbow
  brackets, scrollbar, todo highlight, render markdown, sticky
  context, breadcrumb, auto-pair, highlight trailing ws,
  highlight-word, relative numbers, color column, and even the
  vim ↔ standard input style all mutated in-memory config only
  — the toast said "off" but restart reverted to the default.
  New `persist_config_scalar` helper + persist call in every
  `set_*` setter; refactored four inline toggles to the
  `set_ + toggle_` pattern so palette / menu / right-click /
  `:set` all share the same persist path.
- **Marketplace `Reinstall` button** on already-installed
  marketplace entries (previously showed nothing; had to
  uninstall + install).
- **Menu-bar `Toggle bottom panel`** entry under View.
- **Theme chip right-click** now lists all installed themes
  inline instead of opening the picker; also seeds an
  `auto-system` stub (day/night sync with macOS appearance —
  wiring lands in a follow-up).
- **Hover-help info-box separator** at the top of the box
  (dim `───` rule) so it visually detaches from the tree rail
  it shares a background with.
- **Info View v0.3 design doc** in
  `docs/design/info-view-v0.3.md` — the v0.3 flagship: an
  Ableton-style rich hover panel with agent-generated +
  drift-checked copy across ~500 hover targets. Design only,
  not shipped.

### Changed

- **"workspace status dots" → "workspace dots" everywhere.** The
  markers are just visual chips, not status indicators. Palette
  id + config key + ex-command + right-click label all
  consistent now.

## [0.2.9] - 2026-08-09

Same-day rollup on top of v0.2.8 (which was itself the first
cargo-dist success in 9 tag attempts). Two SEV-1 fixes plus a
morning of menu-bar / hover-help / integrations-audit polish.

### Fixed

- **SEV-1: Headers tab typing corrupted the last header value on
  the wire.** `headers_buffer` was rebuilt with no trailing `\n` and
  every reload placed the cursor at end-of-buffer — landing INSIDE
  the last header's value. Any keystroke while Headers was focused
  silently mangled the last header, which is often `Authorization`.
  Auth headers were going out with a corrupted value. Fixed by
  appending a fresh newline to the reload; typing now starts on
  an empty row.
- **SEV-1: `:qa` / `:qall` / `:quitall` silently discarded unsaved
  work.** Vim requires `:qa!` to force. mnml's `:qa` set
  `should_quit = true` unconditionally. Now walks every pane; any
  dirty pane refuses with `unsaved changes — use :qa! to discard`.
  `:qa!` still force-quits.
- **HTTP panel MOCKS section always showed `(0)`.** `walk_for_http`
  only accepted `.http`/`.curl`/`.rest`; sidecar `.mock.json` files
  produced by `:http.save_mock` were structurally invisible to the
  panel. Fixed by walking `**/*.mock.json` alongside.
- **Menu bar Alt+letter for clipped menus was silently broken** —
  the initial fix set `menu_open` but `draw_dropdown` bailed on
  missing `menu_bar_words` entry, creating an invisible input
  trap. The proper fix paints the dropdown at a fallback origin
  (column 0 or after last-visible menu word) so keyboard nav works
  even when the parent chip is clipped by the workspace cluster.
- **Alt+letter no-ops when a picker / prompt / cmdline is open.**
  Prior behavior stacked the menu dropdown on top of the overlay
  and swallowed keys between them.
- **Menu-open + top-level chord (Ctrl+P, F1, etc.) closes the menu
  and runs the chord.** Prior behavior silently no-oped.
- **F10 during a DAP session fires `dap.next`, not the File-menu
  summon.** Menu-summon was unconditionally winning the chord race.
- **Palette exact-phrase substring boost.** Query "hover-help" was
  ranking `view.help` above `view.toggle_hover_help`. Boost pushes
  literal-substring matches above pure fuzzy score.
- **Dirty-quit + clean-quit confirm dialogs default focus to
  `[Cancel]`**, not the destructive middle button. Enter is safe.
- **`palette title` ↔ `menu label` drift** — `view.toggle_tree`
  retitled to "Toggle left panel (file tree · Git · Integrations ·
  Agents · HTTP · Findings)" so palette search matches the menu.

### Added

- **Menu-bar left-column glyphs on every menu** (was only File). File
  / Edit / Selection / View / Go / Run / Terminal / Window / Help
  + Brand each get glyph-prefix icons on rows where a widely-
  recognized Nerd Font glyph matches; 3-space spacer preserves
  alignment where nothing fits.
- **Hover-help repositioned as an Ableton-style info box** at the
  bottom of the left panel — 6-row word-wrapped card with a `? Info`
  header. Replaces the old 1-row footer strip. Tree rows show file
  language (`.tsx` → "TypeScript (JSX)"), Agents-dashboard rows get
  their own description, and focus-target takes precedence over the
  always-active-pane fallback.
- **`view.toggle_workspace_dots` — opt-out for the `● / ○` markers.**
  Config key `[ui] show_workspace_dots` (default `true`), palette
  command, `:set wsdots` / `:set nowsdots` / `:set wsdots!` ex-
  commands, AND a right-click item on any workspace-row context
  menu. Three discovery paths.
- **`integrations.audit_glyphs` diagnostic palette command.** Reports
  three drift classes without repair: (a) manifests whose glyph
  won't render in the user's `~/.config/ghostty/config`
  `font-codepoint-map`, (b) id-alias duplicates in
  `integration-glyphs.toml`, (c) orphan `glyph_meta.toml` entries.
  Writes a full report to `.mnml/findings/glyph-audit-<ts>.md`.
- **id-alias dedupe on manifest merge.** Prevents future recurrence
  of the `amplify` + `mnml-aws-amplify` both-at-F1C0E class of
  ledger drift. Auto-cleans existing dupes on next `integrations.refresh`.

### Changed

- **`view.toggle_bufferline` deleted.** The command + `[ui]
  bufferline` config key + `:set [no]bufferline` ex-arms +
  render-gate + `App::bufferline_visible` field are all gone.
  Investigation showed the toggle only affected the launcher-cluster
  row on the empty welcome screen, and the same cluster also renders
  in the welcome body — so toggling it produced no visible change.
- **Sibling: `mnml-msg-slack v0.1.2` published.** `slack_canvases` →
  `slack_boards` rename (with `PREDECESSOR_IDS` cleanup so upgrading
  users don't end up with 3 chips). Glyph swapped to `\u{F07D2}`
  (mdi-slack, in ghostty's routed range so it renders as the Slack
  logo). Colors: channels = white, boards = yellow.
- **File menu**: `Open recent file (picker)…` row removed (Ctrl+R
  covers keyboard access). `Save all` glyph swapped to a distinct
  double-floppy F0194. Add-folder + switch-workspace + settings +
  quit rows get their own glyphs.
- **View menu**: `Toggle file tree` renamed → `Toggle left panel`
  since the panel hosts Git / Integrations / Agents / HTTP / Findings
  in addition to files.
- **Window menu**: split-right / split-down glyphs match the top-
  right H/V pane-cluster chips (EB56/EB57). Focus-split L/R/U/D get
  matching arrow glyphs. Merge/spread/grow/AI-layout rows all get
  Font-Awesome fallback glyphs (MDI first-picks tofu'd in the user's
  font-codepoint-map).
- **Legacy `family_catalog` install path deleted** (~640 lines).
  CATALOG was `&[]` for months; every entry point was a silent
  no-op. Marketplace is the only install path.
- **Removed dead code**: `AppCommand::CmdlinePopupAcceptCurrentAndCommit`,
  empty `PlaywrightConfig` struct, unreachable `Clone for SpendReportPane`,
  and ~20 archaeology comments referencing subsystems removed months
  ago.

## [0.2.8] - 2026-08-08

First release in eight tags — v0.2.1 through v0.2.7 all had their
tags pushed, but Release-workflow cargo-dist builds silently failed
on the Windows target (unconditional `use std::os::unix::…` in
`src/main.rs` and `src/ai_usage.rs`). Fixed with cfg-gated exec +
secret-file write; the next tag push actually cuts a release.

Rollup of the eight tag arc — see individual commits for detail.

### Added

- **Bake-on-install glyph pipeline (v0.2.0-line finish)** — bridge
  0.5+; each sibling ships its SVG via `ChipSpec::glyph_svg_bytes`,
  mnml bakes into `MnmlSymbols.ttf` at codepoints it owns. Preserves
  user-baked glyphs across rebakes.
- **Auto-refresh Claude OAuth token** — no more "re-link every 8h"
  prompts.
- **Paste into `:` cmdline** — Ctrl+V + bracketed paste route to the
  gutter buffer with control chars stripped.
- **Claude tab thinking spinner** — mnml-owned F1E10..F1E14 frames
  baked at cap-mid, coral brand color.
- **Shared text-input helper** — Ctrl+U/W/K/V + word-nav uniform
  across every text surface.
- **AI usage meter chip** — Claude/Codex quota on the statusline.
- **Verified marketplace chip** — curated allow-list (green ✓ Verified)
  separate from Official/Community authorship.
- **Menu-bar submenus** — `MenuItem::Submenu` variant with hover-open.
- **Left-column glyphs on File menu** (rest of the bar coming next).
- **Findings activity-bar section + `.mnml/findings/*.md` viewer**.
- **Shadow-audit palette command** —
  `integrations.audit_shadowed_binaries` finds stale `mnml-*` in
  `$PATH` ahead of `~/.cargo/bin/`, moves them to a quarantine dir
  so `--install` calls reach the newest binary.

### Changed

- **Marketplace install** uses `cargo install --force` AND explicit
  `$HOME/.cargo/bin/<name> --install` — closes the PATH-shadowing
  loophole where a stale `~/.local/bin/<name>` would win over the
  fresh cargo install and write its old manifest.
- **Tree / integrations chevrons** swapped from Unicode BLACK
  triangles to nf-oct-chevron-right/down (F460/F47C).
- **Findings icon** swapped from `nf-md-magnify_scan` to
  `nf-md-file-search` (F1623).
- **Legacy `family_catalog` install path removed** — CATALOG was
  `&[]` for months; Marketplace is the only install path.
  −680 lines across the delete + audit sweep that followed.
- **Assorted cruft** — dead `AppCommand` variant, empty
  `PlaywrightConfig` struct, unreachable `SpendReportPane` Clone
  impl, dozens of stale archaeology comments.

### Fixed

- **Windows release blocker** (root cause of the eight-tag drought):
  `use std::os::unix::process::CommandExt` in main.rs and
  `use std::io::Write` in ai_usage.rs were unconditional. Cross-
  checked with `cargo check --target x86_64-pc-windows-gnu`.
- **`bake_ai_glyphs` no longer wipes user-custom glyphs** — the
  bake path now seeds from `glyph_meta.toml` first, adds the
  builtins, preserves everything else.
- **Write-then-chmod race** on `ai_token` + `ai_last_response.json`
  — write with `OpenOptions::mode(0o600)` atomically.
- **Redact-before-write** on `ai_last_response.json` (previously
  wrote raw HTTP body then chmod).

## [0.2.3] - 2026-08-08

### Added
- **Auto-refresh of Claude OAuth token** (`src/ai_usage.rs`). On 401/403
  from the usage endpoint, mnml POSTs the on-disk `refreshToken` to
  Anthropic's OAuth token endpoint, persists the new
  `{accessToken, refreshToken, expiresAt}` blob, and re-issues the fetch.
  Kills the "re-link every 8h" prompt users hit daily.
- **`#RRGGBB` hex literals in `IntegrationIcon.color`** (`src/ui/theme.rs`
  `color_from_slot`). Chips can carry an exact brand color without
  needing a new theme slot. Multi-byte-safe (`get(..)` + `is_char_boundary`
  gate), silent fallback to `t.bg2` on parse failure.
- **Paste into the `:` cmdline** (`src/tui/mod.rs`). Ctrl+V + Cmd+V
  (bracketed-paste) both route into the gutter buffer with control
  chars/newlines stripped.

### Changed
- **Claude Code default color** swapped from the `"orange"` theme slot to
  `"#D97757"` (Anthropic Claude brand orange). Applied consistently to
  installed-list row, palette-bar chip, split-cluster AI chip, and Pty
  tab spinner glyph — the tab glyph forces the coral even when the slot
  lookup misses so the animation always reads as Claude regardless of
  theme drift.
- **Claude spark glyph (F1E00)** SVG swapped to the user-supplied Claude
  Code app-icon path (fixed a relative-move bug that produced a
  "thunderbolt right eye"). Sized 1.55×1.55 with a 0.30 vertical anchor.
- **Pty tab spinner spacing** — 2-char gap after the animated glyph
  (`✳ ✢ ✶ ✻ ✽`) so the dingbat char doesn't sit tight against "Claude Code".
- **Integrations panel refresh chip** — nudged 1 cell inward from the
  panel edge so it isn't jammed against the vertical separator.

### Fixed
- **Built-in chip enabled state reset on restart** (`4bcbb331`). Third
  recurrence — the merge path preserved slot's Rust-default `enabled=false`
  for built-ins, dropping the user's `true` from the authored manifest.
  Gated preservation on `!is_builtin_integration_id`.

## [0.2.0] - 2026-08-03

The v0.2.0 line covers a very large stretch of work — the
Integration SDK (2026-07-03), the federated Marketplace + Provenance
tagging (2026-08), portable-mode infrastructure (`mnml-data/` folder
next to the binary as an alternative to `~/.config/mnml/`; task
#858), layout ops (merge splits→tabs / spread tabs→splits), auto
`.gitignore` of `.mnml/env/*.env`, factory reset with backup, sandbox
mode (`--sandbox`), site-build smoke tests, `libghostty-vt` first-
party bindings, one-tap glyph re-bake, and a lot of persona-tester
polish across the palette, tree, HTTP panel, and rail. See CLAUDE.md's
Status block for the day-by-day trail.

Highlights below are from the initial 2026-07-03 Integration SDK
drop (kept verbatim); the additional 2026-07-04 → 2026-08-03 work
is documented in commit history.

### Added (2026-07-03) — Integration SDK

- **File-based integration manifests** — siblings register their rail
  chip + palette commands + chord bindings + context-menu entries +
  statusline segment + notification policy via a single TOML file at
  `~/.config/mnml/integrations/<id>.toml`. mnml discovers on startup +
  on the new `integrations.refresh` palette command. Precedence:
  workspace > user > built-in defaults; user `[[ui.integration_icon]]`
  in config.toml overrides any manifest (users always win).
- **`mnml-bridge` 0.3.0** — install / uninstall / list_installed
  helpers write the manifest without touching IPC. Full runtime IPC
  helper surface for level-tagged toasts, persistent toasts,
  progress notifications, activity badges, statusline segments, OS
  notifications. See [Bridge / Mount protocol](/manual/bridge-mount/).
- **Level-tagged toasts** — `App::toast_info` / `toast_warn` /
  `toast_error`. Per current design: info + warn share the standard
  comment border (calm ambient state); error gets a red border so
  actual failures stand out. Wire supports the level flip if you
  want all three colored later.
- **Persistent toasts** — `toast_persistent(id, msg, level)` pins
  until an explicit `toast_dismiss(id)`. Rendered above the
  ephemeral toast stack; repeat calls with the same id update in
  place.
- **Progress notifications** — `progress_start` / `progress_update`
  / `progress_end`. Animated Braille spinner + label + optional %.
  Terminal-status glyph on end (✓ / ✗ / ⊘) that lingers ~2.5s
  before auto-removal. Failed status also fires `toast_error(label)`.
- **Dynamic statusline segments** — `statusline_set_segment(...)`
  with a hybrid packing model (priority desc, allocate max_width
  while budget allows, drop when below min_width). Left- and
  right-lane segments compete separately for their half of the
  statusline. Losing a sibling segment beats losing canonical state
  (line/col, workspace, language).
- **OS notifications** — `notify(title, body, opts)` fires the
  terminal-native OSC 9 + OSC 777 escape sequences. Ghostty / iTerm2
  / kitty / WezTerm / Windows Terminal route to native OS banners.
  Per-integration policy from the manifest `[notifications]` block:
  `os_notify_on = never | error_only | always` and
  `os_rate_limit_sec`. Terminal-focus suppression deferred to the
  terminal (Ghostty already respects DND).
- **`[jira]` config** — `domain` + `ticket_prefix` fields, with
  `MNML_JIRA_DOMAIN` and `MNML_JIRA_TICKET_PREFIX` env overrides.
  Used to build ticket URLs + validate ticket ids in the ECS
  runner trigger. Empty = feature no-op.
- **`[cloud_agents]` config** — full ECS runner infrastructure
  fields (region, account_id, runs_table, cluster, task_definition,
  sg_export_name, log_group, s3_artifacts_bucket, aws_profile_fallback,
  label, short_id, default_workspace_label). Feature no-ops when
  `region` or `runs_table` is empty. Env overrides for
  `MNML_CLOUD_AGENTS_REGION` and `MNML_AWS_PROFILE`. See
  [Cloud agents runner](/manual/cloud-agents-config/).

### Changed (2026-07-03)

- **`tattle_qwe` → `ecs_runner`** — the AWS Fargate cloud-agent
  runner is now a generic config-driven feature instead of
  Tattle-specific infra hardcoded in source. `AgentSource::TattleQwe`
  → `AgentSource::Ecs` (and matching `CloudRunSource` / `CloudRunner`
  renames). Wizard label reads from config; falls back to
  `"ECS runner"`. Hardcoded AWS account id + `tattle.atlassian.net`
  domain + `tattle-claude-artifacts` bucket + all AWS resource
  names moved to `[cloud_agents]` config. Existing users need to
  populate the config section to keep the feature working.
- **`is_valid_ticket` accepts any `[A-Z]+-\d+`** by default —
  supply a `[jira] ticket_prefix` to constrain to your org's
  canonical prefix. Was hardcoded to `TE-` before.

### Removed (2026-07-03)

- **Private Tattle Inbox surface** — `forge.open_tattle_inbox`
  palette command, `<leader>it` chord binding, and default
  `tattle_inbox` IntegrationIcon. Superseded by the Integration
  SDK: the sibling's own `--install` writes a manifest at
  `~/.config/mnml/integrations/tattle_inbox.toml` and mnml picks
  it up. No mnml-core-shipped mentions of Tattle Inbox anymore.
- **`Category::Tattle` + `tattle_tests` catalog entry** — last
  private-catalog entry removed. `FamilySibling::is_private()` kept
  as an API hook (returns false).

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
