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
  channel (`src/ipc/`) share `app.rs` + `ui::draw` + `tui::dispatch_*` with the
  terminal loop (`src/tui.rs`)** so headless behavior matches the real UI. This is the
  substrate for the planned `.test` E2E format. IPC lives at `<workspace>/.mnml/ipc/`:
  `command` (JSONL host→mnml), `screen.txt` / `status.json` / `events.jsonl` (mnml→host).
- **No giant files.** `src/app.rs` is render-free; `src/tui.rs` is *only* the crossterm
  event loop; chrome lives in `src/ui/`, subsystems get their own dirs (`src/git/`,
  later `src/http/`, `src/lsp/`, `src/ai/`, `src/cdp/`). mnml1's `tui.rs` (~56k chars)
  and rqst's `app.rs` (~468k chars) both rotted — don't repeat that.
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

## Status

P0–P3 done. Working: NvChad-ish layout; editable buffers via
either `StandardInputHandler` (VSCode-style, modeless) or `VimInputHandler` (modal:
Normal/Insert/Visual + `:`-line), swappable at runtime (`editor.toggle_keymap` /
`editor.use_vim` / `editor.use_standard` in the palette, or `:set input=vim`);
`:`-commands (`w q wq x q! wa wqa qa bd bn bp e set …`) via `App::run_ex_command`;
selection/undo/clipboard; fuzzy file finder (`Ctrl+P`) + command palette
(`Ctrl+Shift+P` where the terminal supports the kitty protocol, else `F1`) + buffer
switcher (`src/picker.rs` / `src/fuzzy.rs`); config-driven keymap — app-level chords
resolve through `App::keymap` (`src/input/keymap.rs::Keymap`), built from each
`Command`'s default `keys: &[&str]` overlaid with `[keys.global]` / `[keys.<style>]`
config (`"key" = "command.id"`, `= "none"` to unbind); which-key leader popup
(`src/whichkey.rs` trie + `src/ui/whichkey.rs`) — `<space>` in vim Normal or `Ctrl+K`
opens it, keys descend a group, a leaf runs its command (`whichkey.leader` command;
state on `App.whichkey`); editor splits — `Layout` is a binary split tree (`Empty | Leaf |
Split{dir,ratio,first,second}`), `ui::draw` recursively renders one editor per leaf with
1-cell dividers; each leaf shows a distinct buffer, background buffers (in no leaf) are
allowed (bufferline shows all), `App.active` = focused pane = uniquely the focused leaf;
`view.split_right`/`view.split_down`, `view.focus_{left,right,up,down}`,
`view.focus_next_split`, `view.close_split` commands, surfaced in the which-key `+split`
submenu (`<leader>s …` / `Ctrl+K s …`); click a leaf to focus it, drag a divider to
resize it; closing a dirty buffer pops a Save/Discard/Cancel overlay (`src/ui/close_prompt.rs`).
tree-sitter syntax highlight (`src/highlight.rs`, 12 grammars: rs/js/jsx/ts/tsx/py/json/go/
toml/css/bash/html/md) + indent guides. **Theme engine** (`src/ui/theme.rs`): a `Theme`
struct (named UI colours + `base16[16]`) behind an `RwLock`; `theme::cur()` reads it,
`theme::set(name)` swaps it. Themes are all of NvChad's base46 schemes (~90), converted
to `themes/*.toml` (`[base_30]` + `[base_16]` colour tables), enumerated by `build.rs` →
`THEME_SOURCES` and parsed (serde/`toml`) at first use; `onedark` is the default (also
kept hardcoded as the seed/fallback).
`[ui] theme = "…"` at launch, `theme.pick` command / `:set theme=…` at runtime
(re-highlights open buffers). Markdown preview — `Pane::MdPreview` (`src/ui/md_preview.rs`,
a block-level renderer: headings/lists/fenced code/blockquotes/hrules styled, inline
markers unwrapped); `markdown.preview` command (`<leader>m`) opens a rendered, read-only,
scrollable view in a split next to the source, refreshed when the source is saved.
Git: branch + change counts in the statusline + tree tint (P0); **gutter line-signs** —
`src/git/diff.rs` parses `git diff HEAD --unified=0` into per-file added/modified/removed
line marks (kept in `GitStatus`'s ~3s-cached `Snapshot.line_changes`), drawn as a coloured
`▎` in the editor gutter; **diff pane** — `Pane::Diff` (`src/ui/diff_view.rs`) shows parsed
hunks (header + context/`+`/`-` lines), `n`/`p` move the cursor hunk, `s`/`u` stage/unstage
it (`git apply --cached [--reverse]`), `r` refreshes, Enter jumps to the hunk's line in the
source editor; `git.diff_file` (`<leader>g d`, opens in a split next to the source) /
`git.diff` (worktree); **blame gutter** — `git.blame_toggle` (`<leader>g b`) swaps the
line-number gutter on the active editor for a per-line `<sha> <author>` column
(`src/git/blame.rs` parses `git blame --porcelain`), refreshed on save; **commit** —
`git.commit` (`<leader>g c`) opens the single-line text-input overlay (`src/prompt.rs` /
`src/ui/prompt.rs`, a generic "type a string, Enter" sibling of the fuzzy picker) →
`git commit -m`; **commit graph** — `Pane::GitGraph` (`src/git/log.rs` reads `git log --all`
+ `for-each-ref` and computes a single-row-per-commit lane layout — node `●`, pass-through
`│`, corner glyphs at branch/merge points; `src/git/graph.rs` = `GitGraphPane` state w/ a
lazily-loaded per-commit detail; `src/ui/git_graph_view.rs` draws the lane graph + commit rows
[hash · ref chips · subject · age · author, selected row highlit] above a detail panel
[message · parents · changed files]). `git.graph` (`<leader>g l`); in the pane ↑↓/jk select,
PgUp/PgDn/g/G jump, Enter opens that commit's diff (`DiffScope::Commit(hash)` → `git show` —
read-only, staging refused), `r` refresh, `y` copy hash, Esc → tree, wheel moves the selection;
commits refresh open graph panes. **staging view** — `Pane::GitStatus` (`src/git/stage.rs`:
`git status --porcelain` → unstaged/staged file lists, `stage`/`unstage`/`stage_all`/`unstage_all`
[`git add` / `git restore --staged`, `git reset` fallback], `staged_diff`; `GitStatusPane` state;
`src/ui/git_status_view.rs` renders the two sections + branch/counts header). `git.status_pane`
(`<leader>g s`); in the pane ↑↓/jk select, PgUp/PgDn/g/G jump, `s`/`u`/Space stage·unstage·toggle,
`a`/`A` all, Enter → that file's diff, `c` commit prompt, `C` ai-commit, `r` refresh, Esc → tree.
**AI commit message** — `git.ai_commit` (`<leader>g m`, also `C` in the staging pane): `claude -p`
summarises `git diff --cached`; the result lands (via `App.pending_commit_msg_job`, sharing `ai_chan`)
in the commit prompt pre-seeded with its first line (`Prompt::seeded`). Per-hunk staging (diff pane),
commit, and staging-pane ops all run through `App::after_git_change()` (refreshes the cached status +
every open `GitGraph`/`GitStatus` pane). **branches / worktrees** — `src/git/branch.rs` (local/remote
branch lists, `git worktree list --porcelain`, `checkout` / `checkout --track` / `checkout -b`):
`git.checkout` (`<leader>g o`, `b` in the staging pane) — fuzzy picker over local + remote branches
→ `git checkout` (remotes via `--track`); `git.new_branch` (`<leader>g n`, `B`) — prompt → `git checkout
-b`; `git.worktrees` (`<leader>g w`, `w`) — picker over the worktrees → opens a shell pane in the chosen
one; after a checkout `App::after_checkout()` refreshes git + tree and toasts (warns if unsaved editors
are open). headless+IPC (interactive TUI listens too) + the `run.sh`/`dev.sh`
wrappers. The statusline git segment shows branch + `⇡ahead ⇣behind` + `✚staged ●modified
…untracked ⚠conflicts` (only the nonzero parts), from `git status --porcelain -b`. The Git
track is done (phase 4 — branch-rail UI [vs the picker], commit-with-Codex, "recompose commit with AI", multi-repo — is queued; see `.local/PLAN.md`). **HTTP track — in progress:** `src/http/` holds `Request`/`Response` +
`send` (reqwest blocking, rustls), `curl.rs` (parse a pasted cURL), `file.rs` (`.http`/
`.rest`/`.curl` parsing, multi-block via `### name`), `template.rs` (`{{VAR}}` from
`.mnml/env/<name>.env` → process env → dynamic `{{$uuid}}`/`{{$timestamp}}`/…), `script.rs`
(`@set-header`/`@set-env` pre-request + `@assert`/`@capture` post-response directives in `#`
comments, with a `.foo.bar[0]`/`$.path` JSON resolver); wired as `mnml run FILE [--env NAME]
[--workspace DIR]` — apply `@set-*` → expand `{{}}` → parse → send → print body → run
`@assert`s (✓/✗, non-zero exit on any failure; without asserts a non-2xx fails) → show
`@capture`s. Inside the IDE: **`rqst.send`** (`<leader>h s`) on a `.http`/`.rest`/`.curl`
editor (the `### block` under the cursor for multi-block files) parses + applies `@set-*` +
expands `{{}}` (env from `.mnml/env/$MNML_ENV`), opens a `Pane::Request` split, and fires
the send on a **background thread** (`App.http_chan`; `App::tick` drains it) — `src/request_pane.rs`
holds the state (`RunState::Sending|Done|Failed`), `src/ui/request_view.rs` renders the
request line + headers + body, then status/headers/pretty body + ✓/✗ asserts + ⇒ captures
(scroll with `k/j`/PgUp/PgDn, `r` re-fires, `y` copies-as-curl, Esc → tree); `rqst.copy_curl`
(`<leader>h y`) copies the request as a curl command. **Chains** — `src/http/chain.rs` runs a
`.chain.json` (`[{ "request": "a.curl", "extract": { "VAR": "$.path" } }, …]`): each step
expands `{{}}` against the running env, sends, runs its `@assert`/`@capture`, then `extract`s
into env vars for the next step; stops at the first transport error / non-2xx-3xx / failed
assert / empty extract — wired as `mnml chain run FILE [--env NAME] [--workspace DIR]`.
**Discover** — `src/http/discover.rs` reads an OpenAPI/Swagger spec (local JSON or http(s)
URL) and writes one `.curl` stub per operation under `<out>/<tag>/<operationId>.curl` (path
params → `{{name}}`, `security` ⇒ `Authorization: Bearer {{TOKEN}}`, JSON body from a spec
`example`); `mnml discover SPEC [--out DIR] [--base-url URL]` (default out `.mnml/requests`).
Still to do for HTTP: editable request-pane field tabs (right now you edit the `.http` file in
a normal editor). **Pty / AI-CLI panes — first cut done:** `src/pty_pane.rs` (`portable-pty` +
`vt100`) — `PtySession` = a live pty + child + a `Mutex<vt100::Parser>` a reader thread pumps;
`BinaryProfile::shell()/claude_code(ws)/codex(ws)` (claude injects `.mnml/CLAUDE.md` via
`--append-system-prompt`); `Pane::Pty(PtySession)`; `src/ui/pty_view.rs` renders the vt100 grid
(theme bg/fg for the default colours, resizes the session to its area each frame, places the
caret when focused, "[process exited]" banner). `term.shell` (`Ctrl+T` / `<leader>a t`),
`ai.claude_code` (`<leader>a c`), `ai.codex` (`<leader>a x`) open one as a stacked split below
the focused leaf. A focused pty forwards keys→bytes to the child (`tui::pty_key_bytes`,
xterm-ish) — the global chords (esp. `Ctrl+E` cycle-focus, `Ctrl+B` tree) are the way back out
since they resolve before pane dispatch; `Ctrl+W` closes the pane (kills child, joins reader).
The event loop polls at 40 ms while a pty is open. **AI on-selection actions — done:** `src/ai/mod.rs`
runs `claude -p --session-id <uuid> "<prompt>"` (the CLI in print mode — tool use, returns text,
user's auth) on a worker thread; `Pane::Ai(AiPane{title,prompt,session_id,job_id,state:Asking|Done|
Failed,scroll})` shows the answer rendered as markdown (via `md_preview::render_markdown`) —
`src/ui/ai_view.rs`. Commands `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests`
(`<leader>a e/f/r/w`) feed the active editor's selection (or the whole buffer if nothing's
selected) + a task prompt; `ai.ask` (`<leader>a a`) takes a free-text question via the prompt
overlay (`PromptKind::AiAsk`). Results land via `App.ai_chan` / `App::tick` (same pattern as the
request pane). In the AI pane: `r` re-asks (fresh session), Esc → tree, and **`c` promotes it to
an interactive Claude Code pane** — `claude --resume <session_id>` in a `Pane::Pty` below, with
the conversation already loaded (so a quick `-p` answer isn't a dead end — you can drill in /
let it apply edits). **JSONL session tail — done:** `src/ai/transcript.rs` reads
`~/.claude/projects/<dashed-cwd>/<session-id>.jsonl` into `Vec<Turn>` (user / assistant / thinking
preview / tool-use one-liner / truncated tool-result; meta + side-chain lines skipped); `AiState::Live
{path, last_len, turns}` is a live mirror — `App::tick` re-reads when the `.jsonl` grows;
`ui/ai_view.rs` renders the turns (assistant text as markdown). `claude` panes are spawned with a
known `--session-id` (`BinaryProfile.session_id`), so `ai.session_view` (`<leader>a m`) opens a
mirror for the active `claude`/Ai pane; `c`-promoting a `Pane::Ai` also flips that pane into a
live mirror of the (now-interactive) session. `G` follows the bottom. *Follow-ups:* parse a returned
patch into a `Pane::Diff` with accept/reject; request-debug (`Ctrl+.` on a failing request →
`claude -p`); pty scrollback; cancel a running one-shot; incremental JSONL parse from `last_len`.
**Playwright track — runner + results tree done:** `src/playwright/mod.rs` runs `npx playwright test
--reporter=json [args]` on a worker thread (`App.tests_chan` / `App::tick`), parses the JSON report
into a flat `TestRun{tests: Vec<TestCase{title,suite_path,file,line,status,duration_ms,error}>}` (ANSI
stripped from error messages); `Pane::Tests(TestsPane{state:Running|Done|Failed,...})` shows the
command + a ✓/✗/≈/⊘ tally + the tests grouped by file (highlighted selection, failure error inline) —
`src/ui/tests_view.rs`. Commands `test.run_all` / `test.run_file` / `test.run_at_cursor` (Playwright's
`file:line` selector) / `test.rerun_failed` (`--last-failed`) under `<leader>T` (`+test` a/f/t/l); in
the pane ↑↓ select, Enter jumps to the test's source, `r` re-runs (same args), `a`/`f` run all/file,
`R` last-failed, Esc → tree. *Follow-ups (per `.local/PLAN.md`):* trace support (`show-trace` → a native
text-timeline `Pane::Trace`), heal-with-Claude from a failed test, the `[feature: private]` DocDB live
`Pane::TestExecutions` (dev+staging+prod in one panel) + CodeBuild, a flaky-test dashboard.
**Right-click context menus — done:** `src/context_menu.rs` (`ContextMenu{title,items:Vec<MenuItem{label,
action: MenuAction}>,anchor,selected}`) + `src/ui/context_menu.rs` (a bordered floating list at the click,
clamped to screen, selected row highlighted). Right-click a tree file → Open / Open in split / Reveal in
Finder / Copy path; a tree dir → Reveal in Finder / Copy path / Refresh tree; a bufferline tab → Close /
Close others / Close all (dirty editors are kept + counted) / Copy path. Modal like the picker — ↑↓/jk
select, Enter runs, Esc / click-away dismisses, click a row runs it. `App.context_menu` +
`open_tree_context_menu` / `open_tab_context_menu` / `context_menu_accept` / `run_menu_action`;
`tui::dispatch_mouse` handles `Down(Right)` → menu on the tree row / tab under it.
**Tasks / launcher — done (first cut):** `[tasks.<name>]` config (`cmd = "shell line"`, optional `cwd`
— relative to the workspace) + `[startup] tasks = ["name", …]`; `task.run` command (`<leader>o`) opens a
picker over the configured tasks and runs the chosen one via `$SHELL -c` in a pty pane
(`BinaryProfile::task`); `App::run_startup_tasks()` (called once by `tui`/`headless` before the loop)
spawns the `[startup]` ones. Absorbs `../private-playwright/start-launcher.sh`: drop it in as a task /
startup task instead of running it separately (the Playwright track will grow native equivalents later).
Then: LSP, CDP, the `.test` E2E format, plugins, the graphical-Git-GUI-style `Pane::GitGraph` (see `.local/PLAN.md`);
plus queued polish (line-wrapped markdown preview, editable request-pane field tabs). See `.local/PLAN.md`.
Highlight follow-ups: more grammars, incremental tree-sitter parsing, relative line numbers.

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.
