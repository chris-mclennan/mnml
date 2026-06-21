---
date: 2026-06-21
hunt: vscode-mouse-purist
scope: features shipped this session
driver: headless file-IPC, --input standard, /tmp/mnml-hunt-2026-06-21 workspace
---

# mnml VS Code Mouse-Purist Hunt — 2026-06-21 (this-session features)

**Counts: 0 SEV-1, 8 SEV-2, 4 SEV-3.**

Question driving this hunt: could a VS Code refugee — mouse-everything, keyboard only for typing — discover and use the features shipped this session?

Short answer: **no.** Of the seven feature surfaces I poked at, exactly **one** (the agents dashboard row list) responds to mouse for its primary affordance (row select via click; wheel scrolls). Every other feature this session shipped is **palette-only** — the user has no chip, button, glyph, right-click menu, or hover target that fires it. The cheatsheet's new section-collapse — the very thing this session shipped to fix discoverability — is itself keyboard-only (`z` / `Z`), the title bar doesn't advertise the chord, and clicking on a section header does nothing.

| Feature | Mouse-discoverable? | Notes |
| ------- | ------------------- | ----- |
| Cheatsheet section collapse (1346dba) | **NO** | `z`/`Z` chords only — no clickable section header, header rect not registered, title bar doesn't even mention `z`. SEV-2 (S2-01). |
| Claude Agents dashboard — open | NO mouse path to launch it | `:ai.agents_dashboard` palette-only, no integration chip, no statusline chip, no activity-bar icon · SEV-2 (S2-02). |
| Claude Agents — filter/sort/source/workspace/group/help/view chips | **NO** | header advertises `j/k · / · w ws · > src · s sort · ? help` — every one is a keyboard chord; the `[view: Summary]` chip in the topbar is rendered but unclickable · SEV-2 (S2-03). |
| Claude Agents — right-click row | NO menu | no `OpenTranscript / Resume / Kill / Yank / Export` context menu · SEV-2 (S2-04). |
| Claude Agents — clickable row | YES | `list_rows` rects registered, single-click selects row, double-click opens transcript. |
| Websocket pane — connect | NO mouse path | `:ws.connect` palette-only, no integration sidebar chip, no statusline trigger · SEV-2 (S2-05). |
| Websocket pane — send button | **NO** | the pane has a `▸` input prompt but no send button anywhere; header text reads `enter=send · esc=close · ctrl+e=tree` — every action is keyboard · SEV-2 (S2-06). |
| Websocket pane — log scroll | YES (wheel) | `editor_panes` rect registered + dispatch routes wheel to `p.scroll` · src/app/dispatch.rs:808-817. |
| Websocket state/url chip in title bar | not hoverable | no tooltip, no click affordance · SEV-3 (S3-01). |
| Git merge / rebase / delete_branch / worktree pickers | **NO mouse path** | none of the four are on the GIT-rail action-chip cluster (Fetch/Pull/Push/StageAll/Commit/Graph only), not on the GitGraph 11-button toolbar (Undo/Redo/Pull/Push/Fetch/Branch/Commit/Stash/Pop/Reflog/Term), not in the right-click branch-row menu · SEV-2 (S2-07). |
| Test runners — cargo/npm/pytest/go (17 commands) | **NO mouse path** | every `cargo.*` / `npm.*` / `pytest.*` / `go.*` / `test.*` command is palette-only (`keys: &[]`); no chip in statusline, sidebar, bufferline, or activity bar fires any of them. The `+test` whichkey group exists but whichkey is keyboard-only · SEV-2 (S2-08). |
| Browser nav (reload / navigate / copy_url) | NO mouse path | palette-only · SEV-3 (S3-02). |
| LSP peek_definition / peek_definition_overlay | NO mouse path | palette-only — VS Code muscle memory is Alt+F12 or right-click → Peek Definition, neither works · SEV-3 (S3-03). |
| ai.write_branch_name / ai.write_pr_description / ai.explain_diff / ai.recompose_branch | NO mouse path | palette-only · SEV-3 (S3-04). |

## How mouse-discoverable does mnml feel right now?

Stark. The new session-features were shipped *as palette commands*. A VS Code refugee who tries to "find the buttons" lands on a sidebar with five activity icons, a tree, an INTEGRATIONS section (filtered by binary detection — good), a GIT header chip cluster, and a bufferline strip with arrows + theme toggle + window-close. Every one of these old chips works. None of *this session's* features has a chip.

Could I do my day's work without learning a single chord?
- Open files: yes — tree clicks.
- Run a build / a test: **no** — `cargo.test` / `npm.test` / `pytest.run` / `go.test` are 17 palette-only commands. There is no `▶ test` chip anywhere.
- Make a git branch / merge it / delete it: **partial** — the GIT chip cluster has Commit + Graph but not Merge/Rebase/Delete. The new pickers are palette-only.
- Browse Claude sessions: I can open it (if I happen to know `:ai.agents_dashboard`), I can click rows, I can scroll. I cannot filter, sort, change group, open help, or kill / resume / yank without chords. Every modal in the dashboard's title bar is a chord cue, not a button.
- Send a websocket message: I can connect (if I happen to know `:ws.connect`), I can scroll the log, I can read state — but I literally cannot send a message without typing one and hitting Enter. The input "prompt" `▸` is rendered as a static glyph, not a button.

## SEV-2

### S2-01 — Cheatsheet section headers are not clickable; no mouse path to collapse a section

**Repro**: open the cheatsheet (`:view.cheatsheet`); click on the `── ai (2)` header row at col 35, row 3 of the pane. Expected: section collapses (header becomes `▸ ai (collapsed)`). Actual: no state change.

**Source pointer**: `src/ui/cheatsheet_view.rs:81-126`. Each section pushes a header `Line` followed by per-row lines. Only `row_line_indices` (non-header rows) get pushed into `app.rects.list_rows` at L142-157. Header rows have no rect. `src/app/dispatch.rs:959-970` handles `list_rows` clicks for the cheatsheet pane: `flat_idx < n` (visible non-header rows) only — there is no header-hit-test branch.

**Discoverability**: the title bar reads `Cheatsheet · / filter · j/k · esc closes` — **no mention** of `z` for collapse-section or `Z` for collapse-all. A mouse user doesn't know the feature exists. Even when they discover that section collapse is a thing (e.g., reading the commit log), they reach for the click, it doesn't fire, and they're stuck.

**This is the loud one because**: the session shipped section collapse *to improve cheatsheet discoverability* (the cheatsheet is now 300+ rows because it lists every palette-only command). The discoverability fix is itself undiscoverable.

### S2-02 — No mouse path to open the Claude Agents dashboard

**Repro**: launch mnml on a fresh workspace; look for a way to open the dashboard without typing.

**Actual**: not in the activity bar (5 icons: Explorer/Search/Git/Debug/Integrations), not in the INTEGRATIONS sidebar section, not in the bufferline launcher strip (Claude Code + Codex chips exist but those *launch* CC/Codex sessions — they don't open the dashboard), not in the statusline. `keys: &[]` in `command.rs:686`. Palette-only.

**Why it matters**: the dashboard's whole pitch is "live overview of all your CC sessions across workspaces and tmnl tabs." If the user doesn't know `:ai.agents_dashboard` they never get to it. A chip in the bufferline launcher cluster (alongside the Claude Code / Codex chips) labeled `◆ dashboard` would close the gap.

### S2-03 — Claude Agents dashboard: every filter/sort/source/workspace/group/view chip is keyboard-only

**Repro**: open `:ai.agents_dashboard`. Title bar reads:
`Claude Agents · sort:state · j/k · / · w ws · > src · s sort · ? help`. Topbar reads:
`● 0 live  ○ 0 idle  · 96 ended  Σ 98.1M tokens  ≈ $76292.52  [view: Summary]`.

Click any of: `● live`, `○ idle`, `· ended`, the `Σ tokens` chip, the cost chip, the `[view: Summary]` chip, the `sort:state` segment of the title bar.

**Actual**: every click is a no-op. None of these are registered as rects. Confirmed via rects.json (only `list_rows` for selectable rows + `editor_panes` for the body wheel target).

**Source pointer**: `src/ui/claude_agents_view.rs:239-292` (draw_topbar) — emits styled spans straight to a `Paragraph`; never pushes into `app.rects.*`.

**Why it matters**: the topbar literally says `[view: Summary]` — a chip that *looks* like a switcher button — but clicking it changes nothing. The `v` chord cycles the view (Summary → Tools → Files → Files panel). A user staring at `[view: Summary]` will obviously try clicking it. Same for every state-filter chip.

### S2-04 — Claude Agents dashboard: right-click on a row has no context menu

**Repro**: right-click a row in the dashboard. Expected: a menu with Open Transcript / Resume Session / Resume in tmnl / Kill / Yank Session ID / Yank cwd / Export Markdown — these are the 7 `ClaudeAgentsAction` variants the keyboard supports (`o`/`T`/`K`/`y`/`c`/`e`).

**Actual**: nothing. No context menu opens. The right-click event is silently dropped.

**Why it matters**: VS Code's "right-click → action menu" is the universal discovery affordance for per-row operations. Without it, a user who sees an interesting session has no way to act on it short of memorizing 7 chords. Even keyboard users would benefit from the menu doubling as the action discoverability layer.

### S2-05 — No mouse path to open a Websocket connection

**Repro**: look for a connect-websocket button anywhere — sidebar, bufferline, statusline, integration chip. Expected: a chip that fires `ws.connect`.

**Actual**: not in INTEGRATIONS (it lists Claude Code / Codex / HTTP client / HTTP: new blank request / mixr — no ws), not in bufferline launcher (Claude Code + Codex only), nowhere. `command.rs:3318-3326` has `keys: &[]`. Palette-only.

**Why it matters**: this session added a Pane::Websocket. Native tungstenite. Multiple concurrent connections. The whole pitch is "first-class WebSocket testing without leaving mnml." But the entry point is `:ws.connect` typed into the cmdline. A user testing a wss:// URL is exactly the kind of person who's clicking around looking for "new connection."

### S2-06 — Websocket pane has no Send button

**Repro**: open a ws pane (`:ws.connect`, give it a wss:// URL). Look for a Send chip / button anywhere on the pane.

**Actual**: pane is rendered as a log area + a single-row input prompted by `▸`. The prompt glyph is styled but **not registered as a clickable rect**. The pane header text reads `enter=send · esc=close · ctrl+e=tree` — every action is keyboard.

**Source pointer**: `src/ui/ws_view.rs:100-126` paints the input row + prompt as a Paragraph; no rect push.

**Why it matters**: VS Code's "Postman-style" muscle memory is "type message, click ⏵ Send." mnml's ws pane has no such button. A user with a typed message and a connected pane has to know that Enter sends. If they hit Tab thinking it goes to "the send button," nothing happens. Also: Esc *closes the connection* — a user dismissing focus accidentally closes the whole session. (Separate concern, but worth noting.)

### S2-07 — Git merge / rebase / delete_branch / worktree pickers have no mouse path

**Repro**: open mnml in a git workspace. Look for a button anywhere that fires `git.merge`, `git.rebase`, `git.delete_branch`, `git.worktree_add`, `git.worktree_list`, `git.worktree_remove`, or `git.worktrees`.

**Actual**:
- GIT sidebar header chip cluster is exactly: `↺ Fetch  ↓ Pull  ↑ Push  + StageAll  ✓ Commit  ⎇ Graph` (`src/ui/tree_view.rs:220-242` — `chips_full: [ChipSpec; 6]`).
- GitGraph pane toolbar buttons are: `↶ Undo  ↷ Redo  ↓ Pull  ↑ Push  ↺ Fetch  ⎇ Branch  ✓ Commit  ↧ Stash  ↥ Pop  ↺ Reflog  > Term` (11 buttons, `src/ui/git_graph_view.rs:1978-2090`).
- Right-clicking a branch row in the rail: opens a context menu with checkout/rename/delete (already there) but no merge/rebase/worktree.

**Source pointer**: `lib.rs:189-202` `GitRailHeaderAction { Fetch, Pull, Push, StageAll, Commit, Graph }` and `lib.rs:105-...` `GitToolbarAction { Pull, Push, Fetch, BranchPicker, Commit, Stash, StashPop, Terminal, Reflog, ... }` — neither enum has `Merge`, `Rebase`, `DeleteBranch`, or `Worktree`.

**Why it matters**: merge/rebase/worktree are *brand-new this session*. A user who has heard about the new pickers has no way to find them outside the palette. Adding `Merge` + `Rebase` + `Worktree` to the GitGraph toolbar would close half the gap (a user in the GitGraph pane is obviously about to do a branch op). Adding `Worktree` as a chip in the GIT header (or as an icon next to the branch list) would close the other half.

### S2-08 — No mouse path to any test runner (cargo/npm/pytest/go — 17 commands)

**Repro**: open mnml on the workspace I created (has Cargo.toml + package.json + src/main.rs). Look for a Run / Test / Build chip anywhere.

**Actual**: nothing. None of `cargo.test`, `cargo.check`, `cargo.clippy`, `cargo.build`, `cargo.fmt`, `npm.test`, `npm.run`, `npm.build`, `npm.start`, `npm.install`, `npm.lint`, `pytest.run`, `pytest.failed`, `go.test`, `go.build`, `go.vet`, `go.run`, `test.run_all` is exposed in any chip / button / glyph / right-click menu.

The `+test` whichkey group exists at `<leader>t` with 5 entries, but whichkey is a keyboard-triggered overlay — there's no mouse path to open the whichkey root. (Confirmed: no rect for `whichkey_open` anywhere.)

**Source pointer**: callers of `run_cargo_subcommand` / `run_npm_subcommand` / `run_pytest` / `run_go_subcommand` live only in `command.rs` (palette).

**Why it matters**: this is the single biggest missing-UI item from a VS Code-refugee's standpoint. VS Code has a Run/Debug panel in the activity bar; CodeLens annotations above every test fn; a Test Results panel at the bottom. mnml has none of this. A user opening a Cargo workspace would expect *at minimum* a `▶ cargo test` chip somewhere — statusline footer chip, integration sidebar row, gutter glyph, anything. None of the 17 commands has a UI surface.

**Suggested fix**: a statusline chip "▶ test" that fires `test.run_all` (workspace-detect: Cargo → `cargo test`, package.json → `npm test`, pytest available → `pytest`, go.mod → `go test ./...`) plus a per-test gutter glyph CodeLens-style.

## SEV-3

### S3-01 — Websocket state chip / URL / msgs count in title bar are not hoverable

**Repro**: hover over the state chip (`· closed`), the URL, or `1 msgs` in the ws pane title bar. Expected: a tooltip explaining state ("● open = connected; tx/rx ready", "· closed = use ctrl+r to reconnect" or similar), or the chip is a button (clicking state chip reconnects when closed).

**Actual**: no tooltip, no click handler. The state chip is purely informational.

**Why it matters**: a chip that *looks* like a button is a tooltip waiting to happen. The user with a closed ws connection should be able to click the state chip to reconnect (or at least hover for "use :ws.connect to reopen").

### S3-02 — Browser commands (`browser.reload`, `browser.navigate`, `browser.copy_url`) have no mouse path

These are this-session additions (9358ac8). No browser pane glyph / chip / button fires them. The CDP-backed browser pane (when one is open) doesn't expose reload/navigate/copy_url chips. Palette-only.

### S3-03 — LSP peek_definition / peek_definition_overlay have no mouse path

VS Code muscle: right-click a symbol → "Peek Definition" / "Go to Definition" / "Find References." mnml's LSP layer supports go-to-definition via Ctrl+click (verified earlier hunts) but the new `lsp.peek_definition` + `lsp.peek_definition_overlay` (883fd62) don't appear in any right-click menu. Palette-only.

### S3-04 — AI commands (write_branch_name / write_pr_description / explain_diff / recompose_branch) have no mouse path

All four palette-only. The GitGraph toolbar has space for a `✨ AI` chip group; the commit-message prompt has no AI-draft button; the branch picker has no `✨ name this` chip. Each is a small, valuable AI surface that's invisible to mouse users.

---

## Coverage

**Explored**: cheatsheet pane (header click, scroll, row click); Claude Agents dashboard (open via palette, click rows, hover topbar chips, right-click rows, click `[view:]` switcher); Websocket pane (open via palette, hover state chip, look for send button); GIT sidebar header (chip cluster enumeration); GitGraph toolbar (11-button enumeration); statusline (no test/run chips); activity bar (Explorer/Search/Git/Debug/Integrations — no test or run section); INTEGRATIONS sidebar (no ws, no test, no agents); bufferline launcher cluster (Claude Code + Codex only — no agents/ws/test).

**Did not drive**: drag-to-collapse-section (would require a separate drag path that doesn't exist); live websocket session (TLS not compiled into the release binary — `← ERROR: connect failed: URL error: TLS support not compiled in` — separate build concern); mouse-wheel scroll over the cheatsheet (cheatsheet uses `Paragraph::new` with auto-scroll on selected; wheel routing for cheatsheet not exercised).

**Build sanity**: release binary at `~/Projects/mnml/target/release/mnml`, head 883fd62ef, --headless --input standard. Workspace: /tmp/mnml-hunt-2026-06-21. IPC channel responsive throughout (no truncation or unknown events after the first batch — the only `unknown` events were from a malformed JSONL block at the very start; once switched to single-line appends with newline terminators, every command parsed cleanly).
