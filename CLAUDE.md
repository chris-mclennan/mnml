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
./run.sh shot [OUT.png] # screenshot the *real* ghostty window (live pixels) → PNG you can Read
./run.sh clean [mode]   # reclaim target/ space — incremental (default, safe) | deps | all
./dev.sh               # cargo-watch auto-rebuild-on-save loop (needs `cargo install cargo-watch`)

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

3. **Build-system fix.** `run.sh` + `dev.sh` now prepend
   `/opt/homebrew/opt/zig@0.15/bin` to PATH so `libghostty-vt-sys`'s build.rs
   doesn't silently fail on macOS shells without zig in PATH.

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
