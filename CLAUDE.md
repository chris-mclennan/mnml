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

## Cutting a release — the CHANGELOG secret-scrub trap

**Never write a credential-shaped literal in the CHANGELOG.** Not
`Authorization: Bearer <anything>`, not `xoxb-…`, not `sk-…`, not a
`token = "…"` line — even as an obviously-fake example.

cargo-dist embeds the CHANGELOG into `plan-dist-manifest.json`. If any
substring matches a stored repo secret's value, GitHub Actions replaces
it with `***` **inside the JSON**, which corrupts the manifest. The
`artifacts_matrix` then fails to parse, `build-local-artifacts` and
`build-global-artifacts` are silently **skipped**, and the Release run
reports **success** while shipping only `dist-manifest.json`. The tap /
winget / nfpm jobs then fail for lack of binaries.

This has now happened twice — v0.2.9 and v0.2.18. Both times the
workflow was green. Describe the shape in prose instead ("an auth
header written as a `{{VAR}}` reference").

**After every release, verify assets — a green run is not enough:**

```bash
gh release view vX.Y.Z --json assets --jq '.assets|length'   # want ~22, not 1
```

A tag that shipped no binaries can't be reused safely; bump the patch
version and re-cut (v0.2.9 → v0.2.10, v0.2.18 → v0.2.19).

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
./run.sh shot [OUT.png] # screenshot the *real* ghostty window (live pixels) → PNG you can Read
./run.sh clean [mode]   # reclaim target/ space — incremental (default, safe) | deps | all
./run.sh watch         # cargo-watch auto-rebuild-on-save loop (needs `cargo install cargo-watch`)
./run.sh menu          # interactive numbered picker (standalone/headless/watch/build/…)

cargo run -- [WS] [--input vim|standard] [--ascii] [--config PATH] [--headless]
cargo run -- run FILE [--env NAME]    # HTTP: send a .http/.curl/.rest file headlessly
cargo run -- chain run FILE           # HTTP: run a .chain.json
cargo run -- discover SPEC [--out DIR]  # HTTP: OpenAPI/Swagger → .curl stubs
cargo run -- test [PATH…]             # run .test E2E scripts (default tests/e2e/); also under `cargo test`
```

**When builds get slow** (`./run.sh restart` takes >2min, or cargo build sits at
"Compiling mnml" forever): check `du -sh target/`. mnml's `target/` can balloon
past 100GB because cargo never GCs its incremental cache or dep rlibs. On
2026-06-30 it hit **238GB** and rebuilds took 22 minutes. Recovery:
`./run.sh clean` (safe default — just incremental, no recompile) or
`./run.sh clean deps` (aggressive, forces full dep rebuild).

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
- **Family settings UI convention.** mnml and mixr each have their
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
  big tracks (CDP follow-ups, Git GUI phase 4) for
  when there's room.
  After each landed feature: update this Status block + commit + `./run.sh restart`.

## Status

**Fonts in Marketplace + UI-managed launch profiles (2026-08-25,
#1202 + #1203 f/u).** `src/font_scan.rs` (seek-based sfnt name-table
reader; TTF/OTF/TTC) scans platform font dirs, reads "Nerd Fonts
X.Y.Z" from name ID 5, collapses variant families (Mono/Propo/NL/NF
abbreviations — NB: NF files carry a duplicate abbreviated platform-3
ID-16 record, first-per-platform wins) and renders a FONTS section
pinned atop the Marketplace tab: version vs latest release (GitHub
API, 24h cache), green ✓ / yellow + "↑ Update" chip → brew upgrade in
a Pty (macOS-only v1). Launch profiles are now fully UI-managed:
chip right-click → "New launch profile…" (two-step name → command
prompts) / "Remove profile: <name>" write the workspace manifest;
`launch_profiles::{add,remove}_profile` are comment-preserving text
edits. Fixed en route: the welcome/About overlays' dismiss-on-click
swallow ran before the context-menu modal handler, so chip-menu items
clicked over the welcome screen were dead (user report — "Set
launcher script… does nothing").

**AI launch profiles (2026-08-25, #1203).** Multiple named launch
commands per Claude/Codex chip replace the "wrapper as a separate
integration" pattern (the `claude_multi` manifest is retired). New
`src/launch_profiles.rs`: `[[launch_profile]] {name, command}` +
`default_profile` in the user-global and workspace integration
manifests (workspace wins per name); the legacy `launcher = "…"`
single-override becomes profile `wrapper` and keeps its always-wins
default (full back-compat — `pty_pane::resolve_launcher` now
delegates here and gained user-scope resolution). Right-click the AI
chip (top-right cluster or split-strip) → flat "New session: <name>"
rows (one-off spawn, label suffixed) + "✓ Default: <name>" rows
(persists to the workspace manifest, top-level key inserted above
tables). Commands are exe paths, not shell lines — flags belong in
wrapper scripts. tattle-claude-workspace's manifest upgraded to the
named form (`multi-repo`). 11 new tests.

**Sonos speaker chip + two ways to send Mac audio (2026-08-22).**
New `src/sonos/` subsystem (`soap` / `discovery` / `ops` / `stream` /
`airplay` / `coreaudio`) plus `src/app/sonos.rs`. Statusline cluster on the
right lane, next to the music cluster: a single constant-width
`[󰓃]` destination chip. State is carried by color — teal streaming /
white playing / dim idle — and room/track/volume by the hover tooltip +
Info View, which draw ABOVE the strip and move nothing. Hover-expansion
was built first and reverted to opt-in the same session (`[sonos]
chip_label` = never (default) | hover | always): the lane is
right-aligned, so any width change slides every neighbouring chip, and
pointer-triggered re-flow reads as the strip twitching. The expanded
form's play/pause is NOT a duplicate of the music cluster's — that
drives the *player*, this drives the *speaker*, the only thing that
works when the Sonos plays its own source with no Mac player involved. Expansion grows LEFTWARD — the lane is
right-aligned, so a pointer inside the cluster stays inside it;
growing rightward would shove the hovered chip out from under the
cursor and oscillate. Click targets: speaker glyph = send this Mac's audio, transport = play/skip,
label = room picker, right-click = everything (volume, mute, favorites,
grouping, re-scan, hide). Discovery is one SSDP `M-SEARCH` +
`GetZoneGroupState`; satellites (bonded Sub / surrounds) are excluded
from the room list, and the chip renders nothing when no household
answers. All network work is on a worker thread behind a
Cmd/Snapshot channel pair — the render loop never waits on a speaker.
Transport goes to the group *coordinator*; volume/mute to the named
room.

**Why two audio paths, and the macOS 26 finding behind it.** AirPlay
target selection is not reachable from an app on macOS 26: Sound
settings lists only CoreAudio devices, an AirPlay target isn't one
until already connected, and Control Center (the sole picker) exposes
an *empty* accessibility tree — verified live, `windows=1` with zero
children. No CLI exists either. So: (a) Music.app has a scriptable
`current AirPlay devices` property, giving a real, cold-capable AirPlay
hand-off for Music.app's own audio; (b) everything else goes out as
`system output → BlackHole loopback → ffmpeg mp3 → mnml HTTP →
x-rincon-mp3radio://`, with the previous output device restored on
stop. `src/sonos/coreaudio.rs` is hand-rolled CoreAudio FFI (no
`coreaudio-sys` dep) for the default-output switch. Note for later: a
CoreAudio device literally named "AirPlay" *does* appear while an
AirPlay session is live, so a device switcher could toggle mid-session
— but never connect cold. ScreenCaptureKit is the driver-free upgrade
path for the capture half.

Scope split: the chip + transport + grouping are Sonos-specific
(port-1400 UPnP); `audio.airplay_music` is NOT (it hands Music.app to
any AirPlay receiver — Apple TV / HomePod / AirPlay TV / another Mac,
no Sonos required), hence the `audio.*` group; the loopback stream IS
Sonos-specific because it works by telling a speaker to fetch a URL.

Config `[sonos]` (`enabled` / `host` / `room` / `poll_secs` /
`prefer_airplay`), `:set sonos`, a Settings **Sonos** section, 16
`sonos.*` palette commands, 4 hover-help/Info-View entries, and
`site/src/content/docs/manual/sonos.md`. 44 new tests (SOAP envelopes,
topology parse incl. satellite exclusion + double-escaped payloads,
AirPlay's `NOT_IMPLEMENTED` metadata fallback, favorite
container-vs-stream routing, ffmpeg device-index parse, live CoreAudio
enumeration, app-level status/picker behavior).



**First-launch wizard + per-integration auth SDK shipped
(2026-08-11).** Task #870 + #892 both landed end-to-end as a
14-commit day (mnml core) + 4 crates.io publishes (mnml-bridge
0.7.0, mnml-msg-slack 0.1.3, mnml-forge-bitbucket 0.3.3,
mnml-tracker-jira 0.2.3).

**First-launch wizard** (`first_launch.show`): centered modal that
auto-opens on first-ever launch (gated by `[ui]
first_launch_complete`). Six sections top-to-bottom, keyboard-
driven, Esc = "Ask me later" (flag stays false), Enter = Finish
(persists + flips true). Sections: (1) AI ghost-text backend
(Claude API / Local / Skip → writes `[ai] suggest_backend` +
`inline_suggestions`), (2) input style (vim / standard → writes
`[editor] input_style`), (3) Nerd Font sample-glyph diagnostic,
(4-6) tool installs (Claude Code + Codex npm install / VSCode
`code` shim / btop+htop+iftop brew install), each Space-fires a
Pty pane running the shell command. Files:
`src/app/first_launch.rs`, `src/ui/first_launch_overlay.rs`. E2E:
`tests/e2e/first_launch_wizard.test`.

**Per-integration Settings pane + `[[auth]]` schema.** Integration
authors declare their auth needs in the manifest via
`mnml-bridge`'s new `AuthField` (0.7.0): `key`, `label`, `kind`
(secret/text/url/email/number), `env_fallback`, `help_url`, `help`,
`required`. mnml core reads them and drives three surfaces:

- **Configure pane**: right-click chip → "Configure…" (only
  surfaced when the manifest declares `[[auth]]`), or palette
  `integrations.configure_picker` for the picker path when 2+
  qualify. Modal form, secrets rendered as `•••`. Ctrl+S writes
  values back to `[auth_values]` in the same manifest TOML.
- **First-hit auth guard**: firing an integration command with a
  required field unset (and no env_fallback env var set)
  intercepts dispatch and opens the Configure pane instead of a
  silent-fail Pty.
- **Pty env-injection**: at spawn time, mnml injects
  `[auth_values]` as env vars using each field's `env_fallback`
  name. Cross-integration sharing — a token saved in ANY
  installed integration flows to every subsequent Pty spawn, so
  configuring bitbucket once gives jira's Fix Versions view its
  `$BITBUCKET_ACCESS_TOKEN` for free. Current-firing integration
  wins on env-var-name conflicts.

Files: `src/integration_manifest.rs` (AuthField), `src/app/integration_settings.rs`, `src/ui/integration_settings_overlay.rs`, `src/app/mod.rs::open_pty_dir` (injection), `src/app/mod.rs::run_dynamic_command` (guard). Site manual: `site/src/content/docs/manual/first-launch.md` + `.../integrations/auth.md`.

**Pilot siblings shipped end-to-end** (each declares `[[auth]]`
via mnml-bridge 0.7): Slack (bot_token + team_id), Bitbucket
(app_password + username), Jira (site_url + email + api_token).
Existing env-var users unaffected — env_fallback preserves
back-compat; skip-if-empty means clearing a pane field falls back
to the shell export.

**Other today** (Aug 11): approved + merged PR #27 (ICodeGorilla
Windows zig-target fix); absorbed fim-engine into
`crates/fim-engine/` as a workspace member (old repo now
private); shipped 8 CI-red e2e-test fixes (space eater + settings
Esc/arrows regressions); 2 new agents (`hover-help-writer`,
`pr-reviewer`); Info View hover-help coverage audit
(`docs/design/info-view-coverage.md`).

**Tmnl integration removed (2026-06-22):** Mnml is now
terminal-agnostic. The entire tmnl-protocol blit client, the
mixr-host docked panel, and the chrome-chips protocol are gone
(~3.7k lines + ~30 call sites cleaned up). Rationale: tmnl's
fontdue rasterizer produces visibly thinner glyphs than Apple
Terminal's CoreText, especially on Nerd Font icons. Pivoted to
"mnml runs in any terminal, let the terminal handle rendering
quality" so users get CoreText-grade icons everywhere for free.

Things removed:

- `Pane::BlitHost` variant + all match arms
- `--blit`, `--no-native-promote` CLI flags
- `TMNL_TRANSFER_SOCKET` / `MNML_BLIT_SOCKET` env-var paths
- Auto-promote-to-tmnl-native-tab on startup
- `:host.launch`, `:tmnl.open-tab`, `:tmnl.pop-pty` ex commands
- `tmnl.*` registered commands + integration `tmnl:<id>` form
- Chrome chips protocol + `under_tmnl` / `inside_tmnl_pty` gates
- `pop_pty_to_tmnl` / SCM_RIGHTS pty-fd handoff
- `tmnl-protocol` Cargo dependency
- `tmnl` from the FamilyOffer sibling-suggestion list

Things preserved:

- `Pane::Pty` (shell panes — unrelated to tmnl). All Claude
  Code / Codex / shell integrations run as Pty panes.
- Headless mode + the file-IPC channel (`src/ipc/`).
- The mixr now-playing chip + `mixr.show` command (now
  opens mixr as a Pty pane via `App::open_mixr`, replacing
  the prior `mixr_host` docked panel).
- All sibling tools (`mnml-forge-*`, `mnml-aws-*`, etc.)
  still launch from rail chips — now via `:term <binary>`
  spawning a Pty pane instead of a blit-host pane.

Net diff: 36 files changed, +238 / -4088 lines. 957 lib tests
pass; clippy clean. Branch `remove-tmnl-integration` (two commits:
c7e37fb bulk removal, ce99b56 audit pass).

**Right panel scaffold + integration `enabled` opt-in + flat palette-bar chrome
shipped 2026-06-28.** Collapsible right side panel (drag-resize, `session.json`
persist, `[ui] right_panel_visible` / `[ui] right_panel_width` config keys,
`:set rightpanel`, `view.toggle_right_panel`); integration chips now have an
`enabled` flag (only `browser` on by default; right-click to toggle, persisted
to TOML); palette bar redesigned with flat chips + sidebar/right-panel toggles +
compact-fallback; icon picker (~70 Nerd Font glyphs); external tool launchers
(`tools.htop/iftop/btop`); Pty tabs in bufferline (`$` suffix, skip in `:bn`/`:bp`);
drag-to-split stale-rect fixes; full hover + right-click coverage on all chips.

**File-split refactor + keyboard polish (2026-06-28 evening).** Two waves of
work landed:

1. **9-step file split** of the two biggest source files. `src/app/mod.rs`
   went from 14,234 → ~11,500 lines and `src/tui.rs` went from 7,712 → ~1,700
   lines. The 9 new siblings: `src/app/{util,sibling_install_methods,workspace_methods,cloud_agents_methods,cmdline_methods}.rs`
   and `src/tui/{chord,mouse}.rs` + `src/tui/handlers/{overlay,pane}.rs`.
   Pure non-destructive — every function kept its signature; some private fns
   elevated to `pub(crate)` for cross-sibling calls. 974 → 978 tests pass; no
   behavior change. Verified by a post-split regression sweep (0 issues).

2. **3 keyboard / right-panel features.** (a) Chord chain feeds the opener
   letter to whichkey when its fallback opens the overlay — `<leader>tr`
   needed `Ctrl+K t t r` before; now it's two keys. (b) `Shift+F10` opens the
   context menu for the focused element (tree row or active pane tab) — VS
   Code + macOS convention. (c) Right-panel **v2**: when the panel is visible,
   `outline.show` and `lsp.diagnostics` route into the panel instead of
   splitting the editor body. Header shows the hosted pane's kind (OUTLINE /
   DIAGNOSTICS) with a `×` close button; below 16 cells the body shows a
   "too narrow" hint.

3. **Build-system fix.** `run.sh` now prepends
   `/opt/homebrew/opt/zig@0.15/bin` to PATH so `libghostty-vt-sys`'s build.rs
   doesn't silently fail on macOS shells without zig in PATH.

**Integration SDK shipped + mnml 0.2.0 tag-ready (2026-07-03).** The big
release. Community-default `IntegrationIcon` entries move out of mnml core
into sibling-owned manifests, and mnml gains a full runtime-helper surface
for siblings:

- **`mnml-bridge` 0.3.0 on crates.io.** Sibling `Cargo.toml` uses
  `mnml-bridge = "0.3"` (no more path-dep tricks). New SDK API:
  `install_integration()` / `uninstall_integration()` (fs-based, no IPC)
  and IPC helpers `toast_{info,warn,error,persistent}`, `progress_*`,
  `statusline_set_segment`, `notify` (OSC 9 + OSC 777).
- **File-based integration manifests.** `~/.config/mnml/integrations/<id>.toml`
  with workspace override at `<ws>/.mnml/integrations/<id>.toml`. Precedence:
  user config > manifest > built-in default. `integrations.refresh` palette
  command re-scans without restart.
- **37 sibling repos self-install.** Every `mnml-*` on GitHub ships
  `--install` / `--uninstall` subcommands + a check-only CI workflow. The
  older rolling-`latest-build` prebuild workflow (`prebuild.yml`) also
  coexists per sibling for fast install.
- **`tattle_qwe` → `ecs_runner`.** AWS-Fargate cloud-agent runner is now
  generic + config-driven. `AgentSource::TattleQwe` → `AgentSource::Ecs`;
  empty `[cloud_agents]` config = no-op.

Reconciled the 34 sibling repos that had diverged from their remotes:
each got `mnml-bridge = "0.3"` (crates.io), `src/install.rs`, `--install`
dispatch in `src/main.rs`, README setup step, a fresh `ci.yml` (no
clone-mnml step needed). 8 of them were also missing basic deps
(`mnml-bridge` outright, plus `unicode-width` on 4 messaging siblings)
— added during the sweep. `mnml-msg-gcal` created + pushed as a new
public repo (Google Calendar v3 + OAuth loopback flow).

Still user-driven: `cargo publish` the 37 siblings to crates.io + tag
`v0.2.0` on mnml so cargo-dist takes over.

**HTTP Request pane surface polish (2026-07-06 → 2026-07-07).** Two
sessions of feature work landed on top of the 0.2.0 SDK:

- **`[⇔]` edit-split.** New chip on the Request block's border row
  toggles a side-by-side split of the edit content area. Left = current
  primary tab (Body / Params / …), right = secondary tab (defaults to
  Vars; clickable right-side tab strip lets you pick any combination).
  Click the 1-cell divider to cycle the ratio 30/50/70. Palette command
  `http.toggle_edit_split`. Below ~48 cells wide the split gracefully
  degrades to primary-only. Keyboard still targets the primary side;
  the secondary side is click-editable (Vars cells, Params rows).

- **HTTP-panel `/` filter.** The activity-bar HTTP panel now matches
  the Agents / Cloud Agents idiom — `/` focuses the filter row, typing
  narrows across all seven sections (FILES / RECENT / CAPTURED / ENVS
  / CHAINS / MOCKS / COLLECTIONS), Esc clears + unfocuses. For
  COLLECTIONS a request-name hit keeps its collection visible and
  force-expands it.

- **`{{VAR}}` highlighting + click-to-def + hover.** Vars now render
  cyan (resolved) or bold-red (unresolved) across the URL, Body
  (JSON + plain), Params values, and Headers values. Left-click a
  token → jump to its definition line in `.mnml/env/<active>.env`
  (falls back to `.rqst/env/<active>.env`, opens at EOF when
  undefined). Right-click → context menu with "Set value…" (seeds
  the env-edit prompt so undefined vars can be defined in one step),
  "Jump to definition", "Copy variable name". Hover shows the
  resolved value or "not defined in active env". Dynamic
  `{{$uuid}}` / `{{$timestamp}}` render as resolved but skip the
  "Set value…" menu item (they're built-ins).

- **`tokenize_vars` + `build_var_spans` + `colored_line_with_vars`
  helpers.** New in `src/ui/request_view.rs`. The JSON path merges
  tree-sitter syntax coloring with var styling at the per-character
  level — vars override syntax colors.

**Local file actions pack + tree up-nav (2026-07-07).** Adds the
standard file-manager clipboard + operations that were missing:

- `file.cut` (Ctrl+X), `file.copy` (Ctrl+C), `file.paste` (Ctrl+V),
  `file.duplicate` (Ctrl+D) — Ctrl-shortcuts only fire in tree focus
  so they don't fight standard-input Ctrl+X/C in editor panes.
- `file.move_to` opens a destination-path prompt (workspace-relative
  or absolute, `~` expands, missing intermediates created).
- Right-click tree menu adds Cut / Copy / Paste here / Duplicate /
  Move to…; the Paste entry appears only when the clipboard is
  non-empty.
- **Alt-drag = copy.** Existing tree drag-drop (move with confirm
  prompt) now respects the Alt modifier at drag-start — Alt-drop
  fires an immediate `copy_recursively` (non-destructive, no
  confirmation). Matches Finder / VS Code convention.
- **`..` up-navigation row.** New row at the top of the tree (hidden
  at filesystem root) navigates the workspace root up one level via
  `set_workspace_to`; tree / repos / git / integrations reload
  consistently. Palette `view.workspace_up`.

Copy paths use `fs::copy` for files, recursive walk for directories,
`os::unix::fs::symlink` for symlinks. Same-dir Copy+Paste bumps to
`-copy` / `-copy-N` instead of clobbering. Move = `fs::rename` (single-
filesystem only).

**Layout bug fix (2026-07-06).** `split_leaf_with` used to call
`Layout::leaf(leaf)` for the source side, dropping every background
tab in the source leaf — a pane that was only in the source leaf's
`tabs` list became invisible until the split closed. Fixed by
copying the source leaf's tabs via `leaf_containing` and passing
them to `Layout::leaf_with_tabs`. 5 regression tests added
(`leaf_containing_returns_tab_list_for_background_tab`,
`all_panes_includes_background_tabs_across_splits`,
`split_preserves_background_tabs_in_source_leaf`, +2).

**v0.2.10 + long polish + Info View v0.3 Phase 1 (2026-08-09/10).**
A ~21-commit session covering release repair, a persist sweep, a
dead-code sweep, two file-split extracts, an R9 tester round + its
fixes, and the first shipped slice of the Info View flagship.

Release repair: v0.2.9 tagged but shipped zero binaries because
GitHub Actions scrubbed the cargo-dist plan output as a suspected
secret — the CHANGELOG had a phrase that matched a stored repo
secret's value. Sanitized the phrase, tagged v0.2.10, all 22
release assets uploaded, Homebrew tap auto-updated.

Persist sweep (`0f47e49a`): every runtime UI/editor toggle
(workspace dots, wrap, whitespace, rainbow, scrollbar,
todo highlight, render markdown, sticky context, breadcrumb,
auto-pair, highlight_trailing_ws, highlight_word, relative
numbers, color column, vim ↔ standard input style) now writes
to user config via new `persist_config_scalar` helper + a
`persist_ui_bool` / `persist_ui_int` / `persist_editor_bool` /
`persist_editor_string` surface. Was: interactive toggles
reverted on restart because setters only mutated in-memory.
Post-round follow-up (`996c0478`) caught `view.toggle_hover_help`
and `clock.hide` which the initial sweep missed.

Dead-code sweep (`ee229891`, `e99bc792`): -730 lines net across
15 files. 12 pub App fields with 0 reads/writes, 25 pub methods
with 0 callers (verified by alternation-regex grep — first-pass
audit had false positives from fn-pointer references, so I
re-verified every candidate). Extracted `src/app/toggles.rs`
(all 14 setter+toggle pairs from the persist sweep) and
`src/app/harpoon.rs` from `app/mod.rs`'s midsection.

R9 tester round + fixes (2 SEV-1 items verified fixed pre-round):
- Menu-bar `»` overflow chip when narrow terminals clip menus
  (mouse users couldn't reach View / Go / Run / Terminal /
  Window / Help without Alt+letter).
- `handle_md_preview_key` used to `_ => {}` swallow every key
  it didn't recognize — trap door for vim users landing in a
  preview pane (`:` never opened cmdline, `<leader>` chords
  bounced off). Now returns `false` from the catch-all so
  chord/cmdline dispatch runs.
- Settings-filter auto-focused on overlay open (was dropping
  keystrokes until the user hit `/` first).
- Settings overlay grew rows for `hover_help` /
  `show_workspace_dots` / `highlight_todo_keywords`.
- Menu ↔ palette label alignment ("word wrap" → "line wrap"
  to match the palette title).
- `:q` on dirty buffer names the file in the toast.
- `<leader>ff` bound to `picker.files` (NvChad muscle memory).
- `.mnml/` excluded from Ctrl+P picker (surface state files
  drowning real files).
- `integrations.refresh` also rebuilds HTTP MOCKS cache
  (was `http.refresh`-only).
- Ctrl+Shift+P dismisses any open prompt before opening the
  palette (was a race where palette keystrokes leaked into
  the underneath prompt on Esc).
- WRAP chip right-click menu shows current state + Settings
  jump (was a bare 1-item toggle).

Also: R8-round hover-help `selected_row()` fix for Claude Agents
dashboard when filter/sort is active; Go-menu "Go to definition"
now fires `lsp.goto_definition` (was `lsp.peek_definition`).

Info View v0.3 Phase 1 + 1.5 (design doc `docs/design/info-view-v0.3.md`):
- Framework (`src/ui/info_view.rs`): `InfoViewCopy` /
  `InfoViewTarget` / `describe_info_view` + `empty_state_copy`
  + `to_flat_pair` interim adaptor.
- 49 curated copy entries (`src/ui/info_view_copy.rs`): 27 chip
  variants (Statusline*, Bufferline*, Palette*, MenuBarWord,
  Activity*, Agents*, Http*, Git*, Fold), 10 menu items,
  8 tree-row languages (rs / ts / py / md / go / sh / yaml /
  html / css / sql / dockerfile).
- Phase 1.5 wiring (`d3ab4bb5`): `hover_help.rs` now consumes
  InfoViewCopy via `to_flat_pair` for chip + tree-row targets
  — the 49 entries actually appear in the info panel.
- Rich renderer (Phase 1.6) still TODO — shortcuts / try_it /
  chord glyphs / `:cmd.id` inline hyperlinks are populated in
  data but compressed by `to_flat_pair` in the display.

Related PR merged: `chris-mclennan/mnml-integrations#1` swapped
`mnml-msg-slack`'s slack glyph from U+F07D2 (rendered as a
house on current Nerd Font builds) to U+F03EF (matches
`src/icon_catalog.rs` — the Slack logo).

**For prior history** (the 7-month arc that built tmnl + the
blit protocol + mixr-host + chrome chips integration) see
`git log` before the cleanup commits. Those entries used to live
here as Status snapshots; pruned to keep the dev-log relevant
to current architecture.


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

After the tape lands (either freshly recorded, or before embedding an
existing one in a manual page), review it:

```
Use tape-reviewer to review <tape-name>
```

Writes a severity-ranked report to `.mnml/tape-reviews/<name>.md`.
Verdict `clean` → ship; `needs-reshoot` → run tape-recorder again with
the report's fix list. Task #984 formalized this pattern.
