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

**Post-v0.2.21 polish — the panel-chrome + right-click pass
(2026-09-03).** Driven almost entirely by user reports and two rounds of
tester agents.

**A shared `sort:` chip on TODOS / NOTES / FINDINGS / SESSIONS**
(`panel_chrome::draw_caps_header_with_chips`), styled like CLOUD AGENTS'
`view:` chip: click cycles, right-click lists every mode with a ✓.
`ListSort` gained the reversed pairs (Oldest, Z–A). SESSIONS keeps its
own State/Manual axis rather than borrowing one that doesn't fit.

**The chip shipped broken and two independent bug-hunts caught it.** It
needed ~38 cells; the default `tree_width = 30` leaves ~26, so at stock
settings it never rendered at all. The tests bracketed the default (60
and 24) without testing it. Narrow headers now get an icon-only form,
and there is a test at 26/30/34. Three more from the same hunts: the
chip resized with its label and slid out from under a repeat-clicking
pointer; typing in a filter deleted the refresh chip; and the sort was
persisted but never read back, so it did not survive a restart.

**Right-click audit.** Three menu rows fired command ids that do not
exist — including the FIRST row of the LSP chip's menu. A structural
test now resolves every `MenuAction::Command("…")` literal against the
registry; a wrong id compiles, renders and reviews clean, so clicking
was previously the only way to find one. Two more rail row families
(AGENTS, SEARCH) had left-click handlers and no right-click branch.
Nine rows labelled "Reveal in tree" fired the OS reveal — the in-app
action did not exist, and `RevealInFinder` was macOS-only besides.

**Vim parity.** Charwise VISUAL was exclusive, so `v` `y` yanked the
EMPTY STRING and clobbered the register. `zo` / `zc` were both bound to
the toggle, so `zo` twice closed a fold.

**SEV-1:** every picker, `Ctrl+P` included, panicked the process below
30 columns — the clamp comment claimed it would "clip, fine"; ratatui
panics instead. The picker's scrollbar was decorative: every piece
existed, none connected.

**The lesson worth keeping:** two tests in this batch appeared to pass
while broken because the break silently had not landed (`cargo fmt` had
reflowed the line being patched). Break-checking is only evidence if you
confirm the break is really in the file.

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
