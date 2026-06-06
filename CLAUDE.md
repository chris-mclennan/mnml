# mnml — a NvChad-style terminal IDE (Rust + ratatui)

Greenfield rewrite of two earlier prototypes — an editor and an in-terminal HTTP
client — folded together. Earlier code is reference for porting logic, not a
dependency. The authoritative design notes live alongside this file (read them
before architectural decisions).

## Architecture spine — keep these load-bearing

- **Pluggable input layer.** `Box<dyn InputHandler>` (`src/input/`) translates key
  events into `Vec<EditOp>` (text editing — `src/edit_op.rs`, interpreted by the
  single chokepoint `src/editor.rs::Editor::apply`) or escalates to a small *closed*
  `AppCommand` / a registered command. The editor/buffer/render layers **never**
  branch on which handler is active — only the statusline (mode chip) and the
  cursor-shape code read the 4-variant `EditingMode`. (`grep -rn EditingMode src/ui`
  should hit only `statusline.rs`.) This is "vim way + standard way without
  conditionals everywhere" — the thing the user explicitly wants done right.
- **`Pane` + `Layout` + `Command` registry are the rest of the spine.** `Pane`
  (`src/pane.rs`) is the open-thing enum (Editor today; Pty/Request/Diff/Ai later —
  each additive). `Layout` (`src/layout.rs`) is the split tree (Empty|Leaf today;
  HSplit/VSplit in P3). `Command` (`src/command.rs`, a process-global `OnceLock`) is
  what the palette / which-key / keybindings / plugins all hang off. Adding a feature
  = register commands + maybe a `Pane`/`EditOp` variant — not a refactor.
- **Headless mode (`src/headless.rs`, renders via ratatui `TestBackend`) + the file-IPC
  channel (`src/ipc/`) share `src/app/` + `ui::draw` + `tui::dispatch_*` with the
  terminal loop (`src/tui.rs`)** so headless behavior matches the real UI. This is the
  substrate for the planned `.test` E2E format. IPC lives at `<workspace>/.mnml/ipc/`:
  `command` (JSONL host→mnml), `screen.txt` / `status.json` / `events.jsonl` (mnml→host).
- **No giant files.** App state is render-free and split across `src/app/mod.rs` plus
  per-subsystem siblings (`src/app/{git,lsp,ai,cdp,dap,…}.rs` — 25 files). `src/tui.rs`
  is *only* the crossterm event loop; chrome lives in `src/ui/`, subsystems get their
  own top-level dirs (`src/git/`, `src/http/`, `src/lsp/`, `src/ai/`, `src/cdp/`).
  Earlier prototypes' top-level files (one ~56k chars, one ~468k) both rotted
  — don't repeat that.
- Storage is a plain `String` + byte cursor in `Editor`; all mutation goes through
  `apply` so a rope can slide in later without touching call sites. Columns are chars
  for now (display-width / tabs / CJK is a P2 refinement).

## Build / run / test

```bash
cargo build            # debug
cargo test             # unit tests
cargo clippy --all-targets   # must be warning-free
cargo fmt              # before committing

./run.sh               # launch mnml in *your* cwd (build + run, relaunch-on-exit-75 loop)
./run.sh ~/some/proj   # launch on a specific workspace
./run.sh restart       # tell the running mnml to rebuild + relaunch (IPC {"cmd":"restart"})
./run.sh stop          # quit the running mnml
./run.sh status        # show the marker (workspace, IPC dir)
./run.sh headless [WS]  # same loop, but --headless (virtual screen + file-IPC)
./dev.sh               # cargo-watch auto-rebuild-on-save loop (needs `cargo install cargo-watch`)

cargo run -- [WS] [--input vim|standard] [--ascii] [--config PATH] [--headless]
cargo run -- run FILE [--env NAME]    # HTTP: send a .http/.curl/.rest file headlessly
cargo run -- chain run FILE           # HTTP: run a .chain.json
cargo run -- discover SPEC [--out DIR]  # HTTP: OpenAPI/Swagger → .curl stubs
cargo run -- test [PATH…]             # run .test E2E scripts (default tests/e2e/); also under `cargo test`
```

**The user keeps a `mnml` instance running via `./run.sh`.** After a `cargo build`
that **succeeds**, run `./run.sh restart` so it picks up the new code. (A
`PostToolUse` hook in `.claude/settings.json` does this automatically; the manual
command is the fallback.) Do **not** restart on a *failed* build — that would tell
the loop to rebuild, fail, and the instance would disappear. `restart` force-relaunches
(bypasses the unsaved-changes guard) and re-reads files from disk, so flag it if the
user might be mid-edit *inside mnml* on something untouched.

## Conventions

- `cargo fmt` + `cargo clippy --all-targets` clean before every commit. Run the test
  suite. Commit messages end with the `Co-Authored-By: Claude …` trailer.
- **Family settings UI convention.** mnml, tmnl, and mixr each have their
  own settings UI (Option A — no shared crate, see thread). They all
  follow this idiom for visual + interaction consistency:
  - Scrollable sectioned list (overlay, not pane). Sections are
    `── UI ──` / `── Editor ──` / `── Integrations ──` / `── Reset ──`
    style headers.
  - Each row: `▸ <label>:  [active] / other1 / other2  *` —
    `▸` = focused, `[bracket]` = current choice, `*` = modified from
    default. Trailing-space alignment on the colon.
  - Keys: `←→` / `h l` adjust value · `↑↓` / `j k` move row · `r`
    reset focused row to default · `R` reset all · `Enter` save +
    close · `Esc` cancel (revert to opened-state config).
  - v1 supports **discrete-choice rows only** (a fixed list of
    options). Number / Text / Color rows are v2.
  - The settings UI never edits arrays of complex things
    (`[[workspaces]]`, `[[bitbucket.repos]]`) — those stay
    TOML-edited. Settings is for everyday UX toggles.
  - Each app implements its own ~150-200 lines of settings code.
    Drift risk is mitigated by this paragraph + by occasional
    cross-app review when one app's UI changes.
- Work on a branch only if asked / on `main` — this repo's default workflow is small
  commits straight to `main` (the user authorized that).
- Don't copy code verbatim from the earlier prototypes; port + restructure.
- When a track needs something from the core, add a `Command` / `EditOp` / `Pane`
  variant — don't special-case across layers.
- The user is happy to have Claude pick which track/feature to do next ("keep going,
  you decide the order — we'll do them all eventually") — choose the most valuable;
  don't ask which. Lean toward *bounded* items when starting a fresh session; save the
  big tracks (CDP follow-ups, Git GUI phase 4, Mixr pane) for
  when there's room.
  After each landed feature: update this Status block + commit + `./run.sh restart`.

## Status

**Integration detection + `+` Add overlay + folder browser (2026-06-06):**
Lands the user-facing fix for "why is Jira showing in INTEGRATIONS,
did I set it up?" plus the discoverability flow for adding more
siblings + a UX polish on the workspace prompt.

Five commits land this stretch:

1. `fe56e6b` — new `src/integration_detect.rs` does cross-platform
   binary detection: in-process `$PATH` walk (no `which` fork) +
   per-OS well-known install dirs (`~/.cargo/bin` universally;
   Homebrew prefixes on macOS / Linux; `%LOCALAPPDATA%\Programs`
   on Windows). Results cached per-session. Sidebar
   `> INTEGRATIONS` section in `tree_view.rs` filters to only show
   integrations whose binary is actually detected (built-in
   palette commands always pass). The misleading "Jira looks
   configured" state is gone. New palette command
   `integrations.refresh` clears the cache.

2. `4471945` — `+ Add integration` overlay. New `+` chip on the
   INTEGRATIONS sidebar header (mirrors the GIT section's add-repo
   chip). Click → centered overlay listing 15 known family siblings
   from a new `src/family_catalog.rs` (AWS / DB / Forge / Tracker
   / Fs / Test categories). Each row tagged: `✓ in rail` (green) /
   `✓ installed` (cyan) / `✗ not installed` (red). Keys:
   `↑↓ jk` move, `Enter` adds to rail, `y` yanks `cargo install`
   command, `Esc` closes. New modules: `src/app/discovery.rs`
   (state + handlers) + `src/ui/discovery_overlay.rs` (renderer)
   + `src/family_catalog.rs` (catalog).

3. `f31a380` — `i` in the overlay now spawns
   `cargo install --git <url> --tag vN.N.N` in a Pty pane the user
   watches live. Overlay closes during install; reopening picks up
   the new install (cache cleared on open). Cross-sibling
   composition for installation flow.

4. `7de8c9c` — folder browser for the "Open folder…" prompt
   (`AddWorkspace` kind). Prompt now grows vertically to show a
   live-filtered directory listing below the input. `↑↓` navigate
   suggestions, `Tab` autocompletes from focused row (continues
   typing), `Enter` accepts focused row or typed input. Tilde
   expansion, case-insensitive prefix match, skip dotfiles unless
   prefix asks. Caps at 12 suggestions. Other `PromptKind`s
   (commit message, etc.) unchanged via the new `is_path_kind()`
   predicate.

5. `a5d40f6` — TOML write-back. `Enter to add` persists the full
   `integration_icons` list to `~/.config/mnml/config.toml` via a
   line-based strip-and-rewrite of the `[[ui.integration_icon]]`
   section. Other sections, comments, whitespace preserved.
   Idempotent (strip + append twice == once). Best-effort: in-memory
   add always happens; toast reports the persistence target on
   success or the error on failure. Chips survive a restart.

The two surfaces are now distinct and truthful:
- Top-right **bufferline launcher chip strip** — config-driven
  via `[[ui.launcher_icon]]`, explicit user-pinned quick launchers
- Sidebar **`> INTEGRATIONS` section** — config-driven via
  `[[ui.integration_icon]]` AND filtered against install detection,
  so it shows what's actually installed

Manual page `manual/integrations/installing.md` documents the
detection logic, the overlay flow, the Pty install action, and the
TOML persistence semantics.

**Lambda + EventBridge siblings + first cross-sibling handoff (2026-06-06):**
Lands `mnml-aws-lambda` and `mnml-aws-eventbridge`, taking the
AWS family to 5 siblings (codebuild, cloudwatch-logs, amplify,
dynamodb, lambda, eventbridge). Both shell-out pure `aws` CLI.

`mnml-aws-lambda` is a function browser: tab kinds `all` (every
function in region, paginated) and `watched` (explicit name list).
Split body: function list (left 45%) + focused-function detail
(right 55%) showing runtime, handler, memory, timeout, code size,
arch, package type, last modified, role, ARN, description. Keys:
`o`/Enter open console · `y` yank ARN · `l` launch the cloudwatch-
logs sibling · `r` refresh.

`mnml-aws-eventbridge` is a buses + rules browser: tab kinds
`buses` (every event bus in region) and `rules` (rules on a
specified `event_bus_name`). Unified `Item` enum so one renderer
handles both — buses show name/created/ARN/policy; rules show
name/state/bus/schedule/role/managed-by/ARN/description/event-
pattern JSON. Keys: `o` console · `y` yank ARN · `r` refresh.

**First cross-sibling handoff:** Lambda's `l` chord launches
`mnml-aws-cloudwatch-logs`. v0.1 leaves the user to switch tabs;
v0.2 will pass `--log-group` so it auto-scopes to
`/aws/lambda/<focused-fn>`. The family's "siblings composing on
each other" pitch is now real (Lambda's logs ARE CloudWatch logs).

mnml core changes: 2 IntegrationIcon entries in `config.rs`
(lambda — nf-md-lambda orange; eventbridge — nf-md-bus pink), 2
`Command` entries in `command.rs` (`forge.open_lambda` /
`forge.open_eventbridge`), 2 chord entries under `+integrations`
in `whichkey.rs`: `L` (capital — lowercase `l` is GitLab) for
Lambda, `e` for EventBridge. 2 new Manual pages.

Skipped (no evidence of use at Tattle): Step Functions, IAM.

**3 new AWS/DB siblings + chord-conflict fix (2026-06-06):** Lands
the day's family expansion + a long-standing whichkey bug.

Three new siblings shipped end-to-end (own repos, Manual pages,
rail chips, palette commands, chord entries):

- **`mnml-aws-cloudwatch-logs`** — live log-stream tail. Pure
  `aws logs` shell-out (same auth chain as `mnml-aws-codebuild` /
  `-amplify`). Configurable per-tab filter patterns. Rail glyph
  nf-md-text-box-search (yellow). Chord `<leader>iw`. Palette
  `forge.open_cloudwatch_logs`.
- **`mnml-aws-amplify`** — apps + branches + deploy jobs viewer.
  Two tab kinds: `apps` (all apps in region) and `app` (drills into
  one app — branches left + recent deploy jobs right). Stage chips:
  PRODUCTION green / BETA yellow / DEVELOPMENT cyan. Rail glyph
  nf-md-rocket-launch (purple). Chord `<leader>ia`. Palette
  `forge.open_amplify`.
- **`mnml-db-dynamodb`** — first `mnml-db-*` sibling that uses the
  `aws` CLI for auth instead of a vendor driver (right path for
  AWS-native NoSQL). Split view: items table (left, smart PRIMARY
  column auto-resolved from `describe-table` HASH+RANGE keys) +
  focused-item full JSON detail (right). Rail glyph nf-fa-database
  (teal). Chord `<leader>id`. Palette `forge.open_dynamodb`.

mnml core changes: 3 `IntegrationIcon` entries in `config.rs`, 3
`Command` entries in `command.rs`, 3 chord entries under
`+integrations` in `whichkey.rs`. 3 Manual pages under
`/manual/integrations/`. Astro sidebar updated.

Also fixed a pre-existing whichkey bug: `'i'` was double-registered
at root with both `+integrations` and `+insert`. `BTreeMap` dedup
silently killed `+integrations` (declared first → overwritten by
`+insert`), so every existing forge chord (`<leader>i b/g/l/z/c/s`)
had been unreachable for weeks. Moved `+insert` to capital `'I'`
and added a regression test (`integrations_group_is_reachable`).

Family release verified live: mnml v0.1.3 (2026-06-04) + mixr-rs
v0.1.3 (2026-05-31) both shipping; `mnml-rs-installer.sh` and
`mixr-rs-installer.sh` resolve 200. mnml.sh deploy serving the
new Manual pages.

**Startup workspace picker + update-available check + nightly bundle (2026-06-03):**
Lands #76, #77, #78.

#76 — `--startup-picker` CLI flag (also `MNML_STARTUP_PICKER=1`) shows a
JetBrains-style chooser overlay on launch: [1] New file (current workspace),
[2] Open file… (`view.discovery`), [3–9] configured `[[workspaces]]` rows.
Keys: `↑↓`/`jk` move · `Enter` commit · `1`–`9` direct jump · `Esc`/`q`
skip. New modules `src/app/startup_picker.rs` + `src/ui/startup_picker.rs`.
Both app launchers export `TMNL_LAUNCH_ARGS="--input standard --startup-picker"`
so clicking the icon from Finder lands on the chooser instead of `$HOME`.

#77 — background std thread GETs `api.github.com/repos/chris-mclennan/mnml/
releases/latest` on launch, parses `tag_name`, compares to
`CARGO_PKG_VERSION`. `App::tick` fires a one-shot toast with the release URL
when a newer tag is found. Opt-out: `[ui] check_updates = false`. Skipped in
headless and blit modes. New module `src/update_check.rs`; 3 unit tests.

#78 — `./scripts/build-app.sh --nightly` produces `target/mnml-nightly.app`
(bundle ID `sh.mnml.app.nightly`). Nightly launcher always execs
`~/Projects/mnml/target/release/mnml` — no bundled binary. Icon inverted:
blue background + charcoal wordmark vs. stable's charcoal + blue. Coexists
with stable in `/Applications`. `build-app.sh` also now stamps a per-build
`CFBundleVersion` timestamp (fixes stale Finder icon cache), strips icon
transparent margin (avoids Tahoe glass-template grey bezel), bumps
`LSMinimumSystemVersion` to `11.0` (removes misleading Tahoe Intel-app
warning), and hardens `launcher.sh`: no `set -eu`/zshrc sourcing, explicit
static PATH, `/Applications/tmnl.app` fallback.

**mnml-tickets-jira v0.1 — standalone Jira ticket viewer (2026-06-02):**
Lands #54, the first of the planned multi-view integration class.
New sibling repo `chris-mclennan/mnml-tickets-jira` ships a
standalone ratatui TUI (no mnml dependency yet — blit-host mode
follows once the data layer settles). Configurable tabs are either
literal JQL (`jql = "..."`) or auto-resolved from the project's
release list (`mode = "current_release"|"next_release"` with
`project` + optional `component`). Default scaffold ships 5 tabs:
Testing, Current/Next/Mobile releases, Mine. Keys: 1-9 / Tab
switch · ↑↓/jk move · Enter/o open in browser · r refresh · q quit.
Auto-refresh every `refresh_interval_secs` (default 60s; 0 disables).
Config at `~/.config/mnml-tickets-jira.toml`, token at
`~/.config/mnml-tickets-jira/token`. `--check` prints a resolved
config + auth report. 4 config-validation tests pass, clippy clean.
Roadmap: blit-host mode so mnml can `:host.launch` it as a pane,
right-half ticket detail panel, status-transition picker, in-tab
search/filter, watcher toggle, per-tab column override.

**Pty tab auto-naming from ticket prefixes (2026-05-31):** Lands #53.
New `[ui] ticket_prefixes` config knob — when set (e.g. `["TE-",
"MIX-", "PROJ-"]`), pty session tabs without a user-set name get
their label auto-filled from the most-recently-mentioned ticket
token in the session's visible scrollback. Useful primarily for
Claude Code sessions where the assistant is discussing a specific
ticket — the tab strip shows `TE-1234` instead of `claude code`
without manual `:rename`.

Mechanism: `PtySession::tab_label_with_prefixes(&[String])` reads
the vt100 grid into plain text via `screen_to_text`, then
`scan_for_ticket` walks each prefix looking for `<prefix><digits>`
tokens and returns the globally-rightmost match (rightmost in
row-major text = most-recently-rendered line). Priority chain is
unchanged at the top — user `:rename` wins; the ticket scan
inserts between rename and OSC title.

Two callers updated: `ui::pty_view::draw_tab_strip` (the pty pane's
tab strip) and `App::rename_active_pty` (the toast confirmation).
Empty `ticket_prefixes` (the default) skips the scan entirely — no
performance cost for users who don't configure prefixes.

10 new unit tests covering: empty prefixes, no-match, single match,
multi-match-returns-last, multiple-prefixes-globally-rightmost,
empty-prefix-string ignored, prefix-without-digits, prefix-with-
trailing-non-digit, screen_to_text round-trip. 802 lib tests pass,
clippy clean, fmt clean.

**Pty-fd handoff: mnml sender side (`:tmnl.pop-pty`, 2026-05-24):**
Lands #49 — the sender half of the SCM_RIGHTS pty-fd handoff
(receiver was #50, see tmnl). `:tmnl.pop-pty` (alias `:tmnl.pop`)
takes the focused `Pane::Pty`, opens `$TMNL_TRANSFER_SOCKET`
(exported by tmnl), and `send_message_with_fd`s the pty master fd
with `Message::OpenPaneTransfer { command, args }`. On success
`session.mark_released()` is set so `PtySession::Drop` skips
`child.kill()` (the new owner is tmnl) and *detaches* the reader
thread (joining would block forever — the reader holds a duped
master fd that doesn't get EOF when ours closes; no portable_pty
API can interrupt a blocking pty read). New `released: bool`
field on `PtySession`; new `raw_master_fd(&self) -> Option<RawFd>`
+ `mark_released(&mut self)` methods. Palette command
`tmnl.pop_pty`. Toasts on every failure mode (no focused pane,
not a pty, `TMNL_TRANSFER_SOCKET` unset, connect/send error).
v1 known limitation: between the moment of handoff and mnml's own
exit, both processes' reader threads contend for the pty stream
(documented at the `Drop` call site). Typical flow is "pop, then
close mnml", so the window is short. 2 new tests including an
end-to-end socketpair round-trip that spawns a real `cat` pty,
fires the handoff, and asserts the receiver got the
`OpenPaneTransfer` *with* an attached fd. 786 lib tests pass,
clippy clean.

**Phase 3b v1: private blit-host binary scaffold (2026-05-23):**
Built a separate sibling private repo for the workspace integration
that used to ship as a private Cargo feature inside mnml. Mnml hosts it
via `:host.launch <binary>`. Ships ~500 lines: `main.rs` (CLI),
`blit.rs` (tmnl-protocol transport — near-verbatim copy of
`mixr-rs/src/tui/blit.rs`), `app.rs` (stub App + Env + handle_input),
`ui.rs` (ratatui-based placeholder UI). The richer logic (DocumentDB
worker, schema correlation, Playwright launcher) is not yet ported —
queued as Phase 3b.2 / 3b.3 / 3b.4 / 3b.5. v1 proves the architecture
works end-to-end: mnml-as-host + separate binary speaking
tmnl-protocol over UDS. Build + clippy clean.

**Settings overlay — schema-driven, keyboard-first (2026-05-23):** mnml
now has a proper settings overlay (`:settings` / `view.settings`). Replaces
the earlier click-only flag-toggle overlay. New `src/app/settings.rs`
defines `SettingItem` / `SettingRow` / `SettingsOverlayState` + the
`build_settings(&Config) -> Vec<SettingItem>` schema (sectioned: UI /
Editor / Session / Reset) + `apply_setting(&mut Config, key, opt_idx)`
dispatcher. New `src/ui/settings_overlay.rs` paints a centered bordered
overlay (~60% × 70%) with `▸ <label>: [active] / other  *` rows, section
headers `── UI ──` etc., and a `(Enter to reset)` sentinel row at the
bottom for reset-all. Keys: `←→` adjust · `↑↓` move · `r` reset row ·
`R` reset all · `Enter` save · `Esc` cancel (reverts to the opened-state
snapshot). v1 supports discrete-choice rows only — Number/Text/Color
row kinds are v2. Convention captured in CLAUDE.md so tmnl + mixr can
match later. Settings doesn't edit arrays of complex things
(`[[workspaces]]`, `[[bitbucket.repos]]`) — those stay TOML-edited.
8 new unit tests (783 → 784 default pass), clippy clean.

**tmnl-handoff (simple variant) + integrations design doc (2026-05-23):**
Added `App::tmnl_open_tab(command, args)` in `src/app/tmnl.rs` — when mnml
is running as a tmnl `--blit` native client, pushes onto the existing
`pending_open_panes` outbox which the blit loop drains into a
`Message::OpenPane`. tmnl then spawns the command as a new native tab.
No-ops with a toast when mnml isn't under tmnl. Ex-cmdline:
`:tmnl.open-tab <command> [args...]`. Convenience palette commands
`tmnl.open_claude_in_tab` / `tmnl.open_codex_in_tab`. **Note:** this is
the *simple* variant — spawn-in-new-tab. The hard variant (transferring
a *running* pty session from mnml's pane into a new tmnl tab via
`SCM_RIGHTS` fd-passing) needs new tmnl-protocol messages + unsafe Unix;
left as a follow-up.

Also wrote `docs/INTEGRATIONS.md` — design briefs for the three planned
blit-host integration families: database viewers
(`mnml-db-{postgres,mysql,redis,sqlite}`), ticket viewers
(`mnml-tickets-{linear,jira,github,gitlab}`), Playwright runner
(three interpretations flagged; default = richer results browser).
Each entry covers UI shape, auth, what lives in the binary vs in mnml,
open questions. Recommended build order: `mnml-db-postgres` first to
validate the pattern end-to-end. 776 default tests pass (+3 new tmnl
tests), clippy clean.

**Config-driven launcher-icon strip (2026-05-23):** Bufferline's right-cluster
launcher chips are now config-driven via `[[ui.launcher_icon]]`. Each entry
has `id` / `glyph` / `fallback` / `command` / `color` / `tooltip`. Claude
Code + Codex are built-in defaults (no behavior change for existing users).
The `command` field accepts either a registered command id (e.g.
`"ai.claude_code"`, `"mixr.show"`) or a colon-prefixed cmdline string
(`":host.launch myapp"`) — leading `:` ⇒ dispatched via `run_ex_command`.
New `LauncherIcon` struct in config.rs + `App.rects.launcher_icon_rects:
Vec<(Rect, usize)>` (replaces the named `bufferline_claude_button` /
`bufferline_codex_button` fields). Hover-tooltip works via
`HoverChip::LauncherIcon(usize)` indexing into the config Vec. Bufferline
width math reserves `4 * n_icons` cells dynamically. Drop in
`[[ui.launcher_icon]]` entries for blit-host integrations
(`:host.launch myapp`, `:host.launch psql-viewer`, etc.) without touching
mnml's code. 773 default tests pass (+3 new config tests), clippy clean
under default + aws-codebuild.

**Phase 3a: private workspace integration stripped from public mnml
(2026-05-23):** Deleted the private feature's source tree, app methods,
view module, and example files from the crate. Extracted the AWS-generic
App methods (`open_codebuilds_pane`, `tail_selected_codebuild_logs*`,
etc.) into a new `src/app/aws.rs` gated on `aws-codebuild`. Removed the
private feature's Cargo entry + its `mongodb` / `tokio` / `futures-util`
/ `bson` optional deps. Stripped every gated `#[cfg(feature = ...)]`
block. The corresponding `Pane` variant + `App` fields are gone too.
Hardcoded test fixtures in `bitbucket.rs` renamed to
`exampleorg`/`example-api` (neutral placeholder data). Snapshot of the
deleted code archived locally for the Phase 3b rebuild (as a private
blit-host binary that mnml hosts via Phase 2's `:host.launch`). The
git history still contains the deleted code; Phase 3c (later, on
explicit go-ahead) will scrub it via `git filter-repo` before the
repo goes public. Verified clean under default + `aws-codebuild`:
772 / 785 tests pass, clippy clean on both. Phase 3b (build the
private blit-host binary) and Phase 3c (history scrub) are separate
later sessions.

**blit-host integration class — `pane_host` + `Pane::BlitHost` (2026-05-23):**
Added the third class of integration (alongside command-only plugins and
Cargo features): an out-of-process program owns a regular pane and
renders into it via `tmnl-protocol` over a Unix socket. New `src/pane_host.rs`
contains `BlitChannel` (the generic spawn + socket + frame pump), `BlitCell`,
`BlitHostPane`, and the crossterm-input translators. New `src/app/blit_host.rs`
holds the App method `host_launch(binary, args)`; new `src/ui/blit_host_view.rs`
paints the cell grid. Opened via the `:host.launch <binary> [args…]` ex-command.
Key events forward through; `Ctrl+E` releases focus back to the tree. Wheel
forwards via `dispatch.rs`. Mixr's `mixr_host.rs` is left untouched for now —
Phase 2b will consolidate it on `pane_host`'s primitives. The pane_host
machinery is currently a thin wrapper that re-exports `mixr_host`'s key/mouse
translators to avoid duplicating the (already correct) implementations.
Docs: `docs/PLUGINS.md` has a new section describing the integration class
and its protocol contract. 772 lib tests under default + 813 under
the private workspace-integration feature + clippy clean under all
three feature configs. Phase 3 will move the private integration's
code out of the public crate to a separate private binary hosted via
this facility.

**Phase 1: AWS CodeBuild + CloudWatch generification (2026-05-23):**
Split the AWS-generic CodeBuild + CloudWatch panes out of a
workspace-specific private Cargo feature into a new `aws-codebuild`
feature. Code moved into `src/aws/`, the Pane variants + their match
arms re-gated, the private feature now implies `aws-codebuild`. Zero
new deps for aws-codebuild — both panes shell out to the `aws` CLI.
The private workspace-integration module file is currently dual-gated
with `aws-codebuild`; Phase 3 splits it into `src/app/aws.rs` (public)
+ the private piece (out of the public crate entirely).

**mixr panel redesigned — docked bottom-strip/full cycle (2026-05-21):**
the in-mnml mixr panel's state model was reworked. `mixr.show` / the
`♪` chip now cycle a docked 3-state model — **minimized →
bottom-strip → full → minimized** — replacing the earlier 4-state
floating model (short/medium/tall/anchored overlays). Bottom-strip
is a strip docked at the bottom of the body from the file-tree edge
across (`STRIP_ROWS=22`); full is full body height. Both **cap their
width at `MAX_WIDTH=200`** so a very wide screen doesn't blow mixr
out — past the cap they left-align at the tree edge (narrow breaks
mixr's crossfader/transport, so wide-but-capped is the sweet spot).
`Esc` now forwards to mixr (it uses Esc for back-navigation);
`Ctrl+E` releases focus to the editor. The header is a plain
`♪ mixr` title bar. The old floating drag / edge-resize /
anchor-button machinery (`MixrPos`, `overlay_rect`, `MixrPanelDrag`,
`custom_w`, …) is left in `mixr_host.rs` unused — a dead-code tidy +
the planned mnml→mixr palette hand-off (so mixr's theme matches
mnml's) are follow-ups. The `♪` statusline chip also got track-name
sanitising + an 18-char truncation. 715 lib tests + clippy green.

**mixr.show opens a native mixr panel inside mnml (2026-05-21):**
supersedes the day's earlier sibling-tmnl-pane approach — mnml now
*hosts* mixr itself, playing the tmnl-protocol *server* role (the
mirror of its own `blit` client). New `mixr_host` module:
`MixrPanel::launch` binds a Unix socket, spawns `mixr --blit
<socket>`, greets it (Hello + Resize), and a reader thread pumps
`Frame`s; `drain_frames` applies them diff-aware to a `MixrCell`
buffer. `mixr.show` launches the panel on first call, then toggles
shown↔minimized (the `♪` chip is the minimized state, and clicking
it already runs `mixr.show`). `ui::draw` carves the right half of
the body for it — the editor layout reflows into the left half —
and `ui/mixr_view.rs` paints mixr's streamed cells. When the panel
is focused, keys + mouse route to mixr over the wire
(`mixr_host::crossterm_{key,mouse}_to_input`); Esc unfocuses, a
click off the panel blurs it. Works the same whether mnml is
standalone or itself running under tmnl — mnml is always the host.
The earlier `OpenPane` plumbing (tmnl-protocol / tmnl) is left in
place, unused. 713 lib tests + clippy green.

**mixr.show opens mixr as a sibling tmnl pane (2026-05-21):**
completes "Option C" of the mixr-native plan — under tmnl, mixr
runs as its own native pane beside mnml, not nested as an mnml
pty. When mnml is a tmnl native client (`--blit`),
`App.under_tmnl` is set by the blit loop; `open_mixr_pane` then
queues `(command, args)` onto `App.pending_open_panes` instead of
spawning a `Pane::Pty`. The blit loop drains that outbox each tick
into the new `tmnl-protocol` `Message::OpenPane`; tmnl receives it
(`ServerEvent::OpenPane`), splits the focused pane, and launches
`mixr --blit <socket>` as a sibling native pane. Standalone (not
under tmnl), `mixr.show` keeps the old pty-pane behavior.
Four-repo change — tmnl-protocol (new `OpenPane` message; the
crate also got its first git history), tmnl
(`open_pane_with_command`), mixr-rs (its `--blit` dispatch was
written but unwired — now wired + verified against `fake_server`),
mnml (this side). 711 lib tests + clippy green.

**Pluggable now-playing miniplayer + macOS source (2026-05-21):**
the statusline `♪` chip's data layer went pluggable. New
`now_playing` module: a player-agnostic `NowPlaying` (source /
playing / track / detail) + a `Source` enum (`Mixr` / `Macos` /
`Auto`) + per-source sub-modules — `now_playing::mixr` (reads
`~/.mixr/quick.txt`, the former `mixr_status` logic) and
`now_playing::macos` (queries Music / Spotify via an `osascript`
AppleScript — browser-tab audio isn't reachable, Apple locked
`MediaRemote` down on macOS 15.4+; the script guards each app
with `is running` so polling never launches a player).
`Source::Auto` (the default) shows whatever's actually playing —
mixr first (a cheap file read), macOS only when mixr is idle. A
background poller thread (`spawn_poller`, 3s interval) keeps the
`osascript` shell-out off the render path; `App.now_playing` is
the drained snapshot, `App.now_playing_rx` the channel.
`start_now_playing_poller` runs from the real terminal loop only
— headless / e2e skip it, so no `osascript` spawns in tests. The
chip now reads `App.now_playing` instead of reading the file
per-render. `mixr_status` module folded into `now_playing::mixr`.
711 lib tests (+3) + clippy green. Adding a third source = a new
sub-module + one `poll` arm; the `[ui]`-config source picker is
a noted follow-up (`Auto` is wired as the default for now).

> Older Status entries (everything before 2026-05-21) are archived
> separately so the dev-log doesn't bloat every Claude conversation.

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.

## Docs sync

The public site has a Manual section that's part of the deliverable, not a
follow-up task. After landing a feature commit, run the `manual-writer` agent
for the affected area:

```
Use manual-writer to write the <site> manual for <topic>
```

The agent reads `FEATURES.md` + source as ground truth, writes a deep manual
page, updates the Starlight sidebar, builds to verify, and bumps
`site/.docs-sync-marker` to the current HEAD. Review the diff + push manually.

Tag commits with `[skip docs]` (or `[no docs]`) in the message to silence the
post-session reminder for trivial work (fmt, typos, comments).

A Stop hook (`.claude/settings.json` → `Stop` event) runs
`scripts/check-docs-sync.sh` at session end and warns if commits since the
last sync touched feature surface.

For flows that benefit visually from an animated demo, follow up with:

```
Use tape-recorder to record <flow-name> for <site>
```
