# mnml — a NvChad-style terminal IDE (Rust + ratatui)

Greenfield. Supersedes the `../mnml1` prototype and absorbs `../rqst` (a ratatui
Postman-in-the-terminal) — both are **reference implementations to port logic
from, not dependencies**. Full design + phased roadmap: **`.local/PLAN.md`** (the
authoritative spec; read it before architectural decisions).

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
  mnml1's `tui.rs` (~56k chars) and rqst's `app.rs` (~468k chars) both rotted — don't
  repeat that.
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
- Work on a branch only if asked / on `main` — this repo's default workflow is small
  commits straight to `main` (the user authorized that).
- Don't copy code verbatim from `../mnml1` or `../rqst`; port + restructure.
- When a track needs something from the core, add a `Command` / `EditOp` / `Pane`
  variant — don't special-case across layers.
- The user is happy to have Claude pick which track/feature to do next ("keep going,
  you decide the order — we'll do them all eventually") — choose the most valuable;
  don't ask which. Lean toward *bounded* items when starting a fresh session; save the
  big tracks (CDP follow-ups, Git GUI phase 4, Mixr pane) for
  when there's room.
  After each landed feature: update this Status block + commit + `./run.sh restart`.

## Status

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
(`":host.launch private"`) — leading `:` ⇒ dispatched via `run_ex_command`.
New `LauncherIcon` struct in config.rs + `App.rects.launcher_icon_rects:
Vec<(Rect, usize)>` (replaces the named `bufferline_claude_button` /
`bufferline_codex_button` fields). Hover-tooltip works via
`HoverChip::LauncherIcon(usize)` indexing into the config Vec. Bufferline
width math reserves `4 * n_icons` cells dynamically. Drop in
`[[ui.launcher_icon]]` entries for blit-host integrations
(`:host.launch private`, `:host.launch psql-viewer`, etc.) without touching
mnml's code. 773 default tests pass (+3 new config tests), clippy clean
under default + aws-codebuild.

**Phase 3a: the private integration stripped from public mnml (2026-05-23):** Deleted
`src/private/`, `src/app/private.rs`, `src/ui/test_executions_view.rs`,
and the four `examples/private_*.rs`. Extracted the AWS-generic App
methods (`open_codebuilds_pane`, `tail_selected_codebuild_logs*`, etc.)
into a new `src/app/aws.rs` gated on `aws-codebuild`. Removed the
`private` Cargo feature + its `mongodb`/`tokio`/`futures-util`/`bson`
optional deps. Stripped every `#[cfg(feature = "private")]` gate. The
`Pane::TestExecutions` variant + the `App.docdb_handle` /
`private_executions` / `test_executions_rows` fields are gone too.
Hardcoded `exampleorg`/`example-api` test fixtures in `bitbucket.rs`
renamed to `exampleorg`/`example-api` (neutral placeholder data).
Snapshot of the deleted code is at
`~/Projects/internal-app-snapshot-2026-05-23.tar.gz` (25 KB) for the
future Phase 3b — rebuilding it as a private blit-host binary that
mnml hosts via Phase 2's `:host.launch`. mnml's git history still
contains the the private integration code; Phase 3c (later, on explicit go-ahead)
would scrub it via `git filter-repo` before the repo goes public.
Verified clean under default + `aws-codebuild`: 772 / 785 tests
pass, clippy clean on both. Phase 3b (build the `internal-app`
binary) and Phase 3c (history scrub) are separate later sessions.

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
`--features private` + clippy clean under all three feature configs.
Phase 3 will move the private integration code out of the public crate to a private
`internal-app` binary hosted via this facility.

**Phase 1: AWS CodeBuild + CloudWatch generification (2026-05-23):**
Split the AWS-generic CodeBuild + CloudWatch panes out of the
the private integration-specific `private` feature into a new `aws-codebuild` feature.
Code moved from `src/private/{codebuild,codebuilds_pane,log_tail_pane}.rs`
to `src/aws/`, the Pane variants + their match arms re-gated, the
`private` feature now implies `aws-codebuild`. Zero new deps for
aws-codebuild — both panes shell out to the `aws` CLI. `src/app/private.rs`
is currently `#[cfg(any(feature = "private", feature = "aws-codebuild"))]`
with private-only methods inline-gated; Phase 3 will split it to
`src/app/aws.rs` + `src/app/private.rs` when private leaves entirely.

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

> Older entries (everything before 2026-05-21) live in
> [`.local/STATUS-HISTORY.md`](.local/STATUS-HISTORY.md) — kept out of
> this file so the dev-log doesn't bloat every Claude conversation.

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.
