# Sessions — what the agent-session managers have that mnml does not

Research note, 2026-09-07. Read-only; every mnml claim below is a grep
against `mnml-zig` main at `aaebf7fb`. Five products were surveyed
from their public sites; product names appear **only** in the matrix
columns — recommendations describe capabilities, never "do what X does".

**Sources fetched** (2026-09-07): `air.dev` + `/changelog`;
`gitkraken.com/kepler`, `help.gitkraken.com/kepler/` (index + *Review
Changes*), the Kepler launch blog post; `warp.dev/terminal`, `/oz`,
`docs.warp.dev/` (index), `/code/code-review/`, `/code/git-worktrees/`;
`kiro.dev`, `/docs/`, `/docs/web/`, `/docs/checkpoints/`, `/pricing/`;
`getfresh.dev`, `/docs/`, `/docs/blog/orchestrator-worktrees/`, the
raw `CHANGELOG.md`.
**Fetches that failed / were empty**: the Air help pages
(`jetbrains.com/help/air/*` render client-side — only a `<title>` came
back; the Air *changelog* was the usable source); the Warp
*agent-management-panel* sub-pages and yearly changelog pages (404 on
the guessed URLs — Warp's agent list / notification claims below are
from the marketing + index pages and my own knowledge, dated mid-2026);
the Kepler *Agent Graph* / *home* sub-pages (404 — the marketing page
and the *Review Changes* page were used). Cells marked `?` are where the
fetched material did not say.

Decided already and designed around, not relitigated: SESSIONS + AGENTS
+ CLOUD AGENTS become one model with two views — the sidebar list
(workspace-scoped by default) and *open Sessions as a table* (batch
actions, summary block, ended sessions hidden past a day, grouped by
workspace) — cloud runs as a third source (`where: local | cloud`), and
`+ New session` offering local / cloud.

---

## 1. Feature matrix

Legend: ✓ has it · ◐ partial · — none · ? not stated in what was fetched.
mnml column cites `file:symbol` on main; gap = S / M / L.

| Capability | Air | Kepler | Warp | Kiro | Fresh | mnml-zig today | Gap | Note |
|---|---|---|---|---|---|---|---|---|
| Start N sessions at once from a prompt / ticket list | ◐ (one task per prompt; multiproject view) | ✓ (Task from issue/PR; Actions) | ◐ (per-tab; cloud triggers) | ✓ (Web: multi-repo autonomous; Automations) | ◐ (`Run Agent…` per workspace) | ◐ `ai.claude_code_new_x2/x4/x8` → `openBatch` in `src/app/ai.zig`; `todos.fix_with_agent` → `openInAgent` in `src/todos.zig` | M | ours opens N *blank* ptys; one marker → one one-shot (`claude -p`) |
| Per-session worktree / branch isolation, auto-created | ✓ (`.air/worktree.json`) | ✓ (one worktree per repo per Task) | ◐ (worktree-aware, not auto-created) | ? | ✓ (New Workspace = worktree + branch) | ◐ `git.worktree_add` (prompt) in `src/app/cmd_git.zig`; WORKTREES section + dirty dot in `src/ui/git_palette.zig` — not tied to a session | M | the pieces exist, unlinked |
| Container / cloud sandbox isolation | ✓ (Docker; cloud "forthcoming") | — (local-first; SSH/WSL) | ✓ (cloud agents) | ✓ (Web sandbox) | ◐ (SSH / k8s sessions) | — `cloud_agents.*` all "not in this build" (`src/app/ai.zig:97-106`, `:1573`) | L | |
| Diff of *each* session's branch beside the session | ✓ (diff review, comments) | ✓ (worktree graph + diffs per Task) | ✓ (Code Review panel per worktree) | ◐ | ◐ (dock shows "git summary") | ◐ `Pane.diff` + `applyHunk` in `src/app/git.zig` — for the *current* repo only, no session link | M | |
| Board / kanban of tasks → sessions | ? | ✓ (Kanban / List / Agent views) | — | ◐ (spec task lists) | — | — | M | our table is the list view |
| Session states incl. **needs input / done / failed** | ✓ | ✓ ("what needs you, what's ready to merge") | ✓ | ✓ | ◐ (status column) | ◐ `AgentState{streaming,tool_call,idle,ended}` in `src/app/agents.zig`; `needs_approval` → `▲ wait` in `src/sessions.zig:264,816` | S | no done-vs-failed; "wait" is inferred from a quiet transcript with a dangling `tool_use` |
| Notification on state change (toast / badge / OS) | ✓ | ✓ | ✓ (tab status) | ✓ | ? | — no state-change toast; `WAVE3_CONTRACT.md:1243` lists "bells" as *not done by design* | S | `app.toast` + `ui/toast.zig` `Level` exist |
| Central approval of tool calls across sessions | ✓ (Proposed Change tab; permission modes) | ◐ ("human-in-the-loop" routing) | ✓ ("approve actions before they execute") | ✓ (permissions) | — | ◐ `ConfirmPurpose.ai_tool` in `src/app/ai.zig` — the in-app API tool loop only, not CLI ptys | L | CLI sessions approve inside their own pty |
| Permission mode per session (plan / ask / auto) | ✓ (Shift+Tab, 4 modes) | ? | ✓ (agent modes) | ✓ (Spec / Autonomous) | — | ◐ only by hand: `Config.LaunchProfile.args` (`src/config/Config.zig:430`) | S | |
| Tokens + cost per session and totals | ✓ (context widgets, quota) | ◐ (Insights: spend to prod) | ? (enterprise usage reporting) | ✓ (credits, dashboard) | — | ✓ `Row.tokens/cost_usd`, `AgentsPane.aggregate` in `src/app/agents.zig`; `ai.spend_today` → `src/app/spend.zig`; `pricePerMt` in `src/ai/transcript.zig` | — | local estimate from JSONL |
| Budget / quota display | ✓ (remaining quota) | — | ? | ✓ (credits remaining) | — | ◐ `ai.claude_usage` → "quota endpoint not in this build" (`src/app/ai.zig:1433,1511`); meter = local 24 h spend | M | |
| Session templates / presets | ◐ (skills + commands shared across agents) | ✓ (Actions: Plan / Review / Address Feedback, editable) | ✓ (Agent Kits, Factories) | ✓ (custom agents, steering files) | — | ◐ `Config.LaunchProfile` (binary/args/env/cwd) in `src/app/launch_profiles.zig` — launch only, no prompt | S | |
| Queue follow-ups / schedule runs | ✓ (queued messages, Apr 2026) | ? | ✓ (cloud triggers + schedules) | ✓ (cron Automations) | — | — (`src/app/tasks.zig` is build tasks) | M | |
| Merge-back: PR per session | ◐ (commit msg gen) | ◐ (agent-published PR attached to Task; no PR button) | ✓ (PR integration) | ✓ (opens PRs, never merges) | ◐ (PR badge in dock) | ◐ `ai.write_pr_description`, `git.push` in `src/commands/specs.zig` — nothing per-session | M | |
| Conflict handling / auto-rebase | ? | ✓ (AI Sync, paid) | ? | ? | — | ◐ `git.rebase` / `git.merge` commands, no conflict UI | L | |
| Auto-commit during a run | ✓ (option, May 2026) | ✓ (Commit Composer) | — | — | — | — | S | |
| Transcript viewing | ✓ | ✓ (turns + tool calls in graph) | ✓ (conversation view) | ✓ | ◐ (the pty scrollback) | ✓ `sessions.open_transcript`, `ai.session_view` (live), `ai.dashboard.export_markdown` (`transcriptMarkdown` in `src/app/agents.zig`) | — | |
| Transcript search across sessions | ? | ? | ? | ? | — | ✓ `ai.session_search` → `sessionSearchAccept` fills quickfix (`src/app/ai.zig:1263`) | — | ours is ahead |
| Resume a session | ✓ | ✓ | ✓ | ✓ | ✓ ("rejoin their conversation" on restart) | ◐ `sessions.open` → `cli.claudeResumeArgv` (`claude --resume <id>`); Codex resumes as a bare `codex` (`src/sessions.zig:454`) | S | |
| Fork / rewind a session | ? | ? | ? | ✓ (Rewind forks; Checkpoints roll files back) | — | — | S | `claude --resume <id> --fork-session` is the CLI flag |
| Share a session | ? | ◐ (team visibility via Insights) | ✓ (session sharing) | ◐ (cloud sessions) | — | — | L | |
| Cloud execution + local ↔ cloud handoff | ◐ (cloud "forthcoming") | — | ✓ (Oz; "seamless handoff") | ✓ (Web ↔ IDE ↔ CLI) | — | — (stubs only) | L | decided: `where: local\|cloud` |
| Start from an issue tracker item | ? | ✓ (Jira / Linear / Trello / GitHub / GitLab) | ✓ (`@warp` mention triggers) | ✓ (GitHub / GitLab) | — | — `cloud_agents.new_run` "for a Jira ticket" is a stub; `agents.new_from_pr` stub (`src/app/agents.zig:1052`) | M | |
| Terminal multiplexing of agent ptys | — (not a terminal) | — | ✓ (tabs, splits) | ◐ | ✓ (per-workspace tabs) | ✓ `pty_pane.Placement{below,right,above,left,tab}`, `ui.ai_layout_mode`, `Tab.kind` in `src/ui/bufferline.zig` | — | |
| Model selection per session | ✓ (remembered globally; 1M ctx) | ✓ (swap per task) | ✓ (curated set) | ✓ (Opus/Sonnet/Haiku/Auto) | — (whatever the CLI does) | ◐ `--model` only in one-shot `cli.claudeArgv`; per-session via profile args | S | |
| Steer mid-run (comments → running agent) | ✓ (Add Comment / Add to Task in diffs; queued msgs) | ✓ ("direct an agent mid-session") | ✓ (inline review comments sent to a running CLI agent) | ✓ | ◐ (type into the pty) | ◐ typing into the pty; `ai_apply.zig` hunk review is for the in-app chat only | M | |
| Agent reviews agent | ✓ (Agent Review, pick agent+model) | ◐ (Review Action) | ? | ? | — | — | S | one command once N-from-prompt exists |
| Open the session's files / jump to its diff (IDE-shaped) | ✓ ("Open In" a JetBrains IDE) | ◐ (file diffs in-app, no editor) | ✓ (editor + review pane synced) | ✓ (it is an IDE) | ✓ (it is an editor) | ◐ `ai.dashboard.yank_cwd`; no open-workspace / jump-to-diff from a row | M | |
| Kill / batch actions | ? | ? | ? | ? | ✓ (delete workspace) | ✓ multi-select + `killCmd` / `killAccept` (`src/app/agents.zig:922-969`) | — | |
| Agent sessions survive an app restart | ✓ | ✓ | ✓ | ✓ (cloud persists) | ✓ | ◐ `session.zig` `PaneKind.pty` persists argv — a `claude --resume <id>` pane comes back; a plain `claude` pane comes back as a **new** session | S | |
| Multi-vendor agents | ✓ (Claude, Codex, Gemini, Junie) | ✓ (6+) | ✓ (5) | — (own agent) | ✓ (claude, codex, opencode, aider, any cmd) | ◐ `Source{claude, codex}` in `src/app/agents.zig:61` | S | |
| Setup / cleanup scripts on worktree create / delete | ✓ (`.air/*.json`, cleanup before delete) | ✓ (worktree init scripts) | — | ✓ (hooks) | — | — `Hook` enum in `src/core/hooks.zig:14` has no session / worktree hooks | S | |
| Mobile / remote control | — | ✓ (mobile, SSH, WSL) | ✓ (cloud) | ✓ (mobile app) | ◐ (SSH sessions) | — (`.mnml/ipc/` is a host→mnml test channel) | L | out of scope |
| Team-wide visibility / audit | — | ✓ (Insights, DORA) | ✓ (Oz "single pane of glass") | ✓ (enterprise dashboards) | — | — | L | out of scope |

---

## 2. What mnml has that none of them have

Every one of the five is either a desktop orchestrator without an
editor, an IDE without a session table, or a terminal. None has all of
the following *around* the session:

| Ours | Proof |
|---|---|
| A full editor next to the session (vim + standard profiles, LSP, folds, multi-cursor, undo ring) | `src/editor/{editor,buffer,edit_op,apply}.zig`; 36 `lsp.*` commands in `src/commands/specs.zig` |
| A debugger with a **fake adapter tested in CI** — a session's fix can be stepped through in the same window | `tools/fake_dap/main.zig`, `mnml-fake-dap` in `build.zig:503-510`, `MNML_FAKE_DAP` in `src/dap/client.zig:837`, `src/app/dap.zig` |
| The git graph + WIP row + per-hunk stage / unstage / discard in the diff pane | `git.graph` (`src/ui/git_graph_view.zig`), `applyHunk` in `src/app/git.zig:1412`, `parse.patchForHunk` |
| A branch rail with a WORKTREES section that already paints a dirty dot and lock per worktree | `Section.worktrees`, `dirty_dot` in `src/ui/git_palette.zig:51,197,380` |
| An HTTP client in the same process (85 `http.*` commands: .http/.curl, env, mocks, bench, chains, SSE, WS) | `src/http/*.zig`, `src/commands/specs.zig:647+` |
| TODOS / FINDINGS as **agent inputs** — a marker row hands itself to an agent with the marker as the prompt | `todos.fix_with_agent` → `openInAgent` (`src/todos.zig:716`); `.claude/` detection `hasClaudeDir` picks the product; FINDINGS rows (`src/findings.zig`) have the same list chrome and no agent action yet |
| Lua hooks + scripted commands / panes / segments | `Hook` enum (`startup, exit, open, save_pre/post, buffer_change, diagnostics, pane_focus, lsp_attach, git_status`) in `src/core/hooks.zig:14`; `Lua.callHook` in `src/scripting/lua.zig:340`; `script.reload` |
| Transcript grep across every session into the quickfix list | `ai.session_search` (`src/app/ai.zig:1263`) |
| Hunk-by-hunk review of an AI proposal before it touches the buffer, one undo step | `src/app/ai_apply.zig` |
| Headless + file-IPC harness that drives the *same* UI (the `.test` corpus) | `src/headless.zig`, `src/ipc/{channel,command,screen}.zig` |
| Local token/cost accounting with no vendor account — read straight from the JSONL | `src/ai/transcript.zig:parseClaude/parseCodex/pricePerMt`, `src/app/spend.zig` |

---

## 3. Ranked gap list (top 15, by value to someone running several Claude Code / Codex sessions on one machine)

Surface key: **list** = sidebar SESSIONS · **table** = Sessions-as-a-table · **wizard** = `+ New session` · **AI pane** · **statusline** · **git**.

| # | Gap | Surface | Data source | Effort | Zig note |
|---|---|---|---|---|---|
| 1 | **Needs-input that interrupts.** Today `needs_approval` is inferred (`pid != null and pending_tool_uses > 0 and state != .streaming`, `src/sessions.zig:264`) and only recolours the row. Promote it to a first-class state (`waiting`) that: raises the session's tab badge, posts a `warn` toast once per transition, rings the terminal bell when configured, and sorts first (already does). Add `done` (process gone, last event `result`/no pending) and `failed` (last assistant text contains an error / non-zero exit) so `ended` stops hiding both. | list · table · statusline | `~/.claude/projects/**.jsonl` last `tool_use` without `tool_result`; the pty's `exit` in `pty_pane.zig:119`; for pty-hosted sessions the OSC title (`pty_pane.zig:183`) and a quiet screen | S | keep the transition edge in `sessions.handle`: diff old vs new `Item.state` by `session_id`, emit one toast per edge; a `Hook.session_state` (see #11) gets the same edge |
| 2 | **One worktree per session, on demand.** The wizard gets a *Where* row: `here` / `new worktree ../<name> -b <branch>` / `existing worktree`. `git.worktree_add` runs first (`submitOp .worktree_add`, `src/app/git.zig:1685`), then the pty opens with `cwd` = that path. The session row carries the branch; the WORKTREES rail row shows the session glyph beside its dirty dot. | wizard · git · list | `git worktree add`; `gitBranch` + `cwd` already parsed in `transcript.zig:57-58` (`Stats.git_branch`) — join on `cwd` | M | `Item` gains `git_branch: ?[]const u8` (already in `Stats`, dropped in `agents.scanInto`); the rail's `Worktree` struct gets `session: ?[]const u8` filled from the sessions snapshot at paint time — no new scan |
| 3 | **Start N sessions from a list.** Wizard row *Prompts*: paste lines / pick TODOS / FINDINGS / a `.md` checklist; one session per line, each with #2's worktree if chosen. Reuse `openBatch` (`src/app/ai.zig:1155`) but pass a prompt: `claude --session-id <uuid> "<prompt>"` interactive (not `-p`), so the session is resumable and shows in the list under a known id. | wizard · TODOS · FINDINGS | `cli.genSessionId` (`src/ai/cli.zig:67`), `claudeArgv` minus `-p`; FINDINGS frontmatter (`src/findings.zig`) | M | `openInAgent` today uses `-p --output-format text` — a one-shot in a pty that ends; switch to interactive with `--session-id` so the row is a real session |
| 4 | **Jump from a session to its diff.** Row action *Diff* opens `Pane.diff` for the session's `cwd` repo (worktree or not) vs its base branch; *Files* sets the tree root / opens the worktree as a workspace (`git.worktree_list` already does the latter). | table · list · git | `Row.cwd`; `git diff <base>...HEAD` + working tree; `app.git.repoById` | S | `Pane.diff` takes a repo id — add `git.repoForPath(cwd)`; the diff pane's stage / discard chips then work per-hunk on the *session's* worktree for free |
| 5 | **Permission mode + model per session.** Wizard rows *Mode* (`plan` / `acceptEdits` / `default` / `bypass` → `--permission-mode`, `--dangerously-skip-permissions`) and *Model* (`--model`), remembered per launch profile and shown as chips on the row (`◐ plan · opus`). | wizard · list | claude CLI flags; `LaunchProfile.args` (`src/config/Config.zig:430`) | S | extend `LaunchProfile` with typed `permission_mode: ?enum`, `model: ?[]const u8`; the shim (`writeShim`) appends them — profiles stay the one place |
| 6 | **Auto-approve rules / central approval for CLI sessions.** Not available through the JSONL (approval lives in the pty). Two honest options: (a) ship a `PreToolUse` hook script that writes `{session, tool, input}` to `.mnml/ipc/approvals/` and blocks on a reply file; mnml shows a confirm (`ConfirmPurpose.ai_tool` shape) and the row goes `waiting`; (b) `--permission-prompt-tool` via an MCP stdio server we ship. (a) needs no MCP. | table · AI pane | Claude Code hooks (`~/.claude/settings.json` `PreToolUse`), the file IPC dir | L | reuse `Io.Queue(bool)` park pattern from `ai.Job` (`WAVE3_CONTRACT.md` Phase 7); the hook script is POSIX `sh` + a Windows `.cmd` twin like the shim |
| 7 | **Per-session PR.** Row action *PR*: `git push -u` the session's branch, draft the body with `ai.write_pr_description` (exists), open via `gh pr create` / provider CLI, store the URL on the row (`pr: #123 ✓ / ✗ checks`). | table · git | `git.push`, `ai.write_pr_description`, `gh` / `glab` on PATH; `Row.git_branch` | M | persist `pr_url` per session id in `session.zon` beside `sessions_aliases` |
| 8 | **Real quota + budget.** `ai.claude_usage` is a stub (`ai.zig:1433`). Read the OAuth usage endpoint (token already linkable: `ai.link_claude_token`) for session/weekly %, and add a per-session soft budget (`$` cap → row turns `warn`, optional SIGTERM). | statusline · table | Anthropic usage API via the linked OAuth token; local `cost_usd` | M | the meter segment (`ai.meterSegment`) already has off / compact / ticker modes |
| 9 | **Fork a session.** Row action *Fork* → `claude --resume <id> --fork-session` in a new pty; the new row shows `⑂ from <alias>`. Cheap, and none of the terminals do it. | list · table | claude CLI flag; parent id kept in `session.zon` | S | `Item.parent: ?[]const u8`; the list groups a fork under its parent when *Manual* sort is off |
| 10 | **Queue a follow-up to a running session.** *Queue…* on a row stores lines; when the session's state edge is `waiting`/`idle`, mnml writes the next line into the pty (`pty_pane` input) — the same mechanism as typing. | table · AI pane | the pty; the state edge from #1 | M | guard with the "quiet for N s and prompt visible" heuristic; never inject while `streaming` |
| 11 | **Session hooks for Lua.** `Hook.session_state{id, from, to}` and `Hook.session_open/close`; a user script can toast, run a task, or `git.push` when a session hits `done`. | Lua | `src/core/hooks.zig` | S | one enum variant + `HookArgs` payload; `todos.zig` shows the subscribe shape |
| 12 | **Session templates with a prompt.** A profile grows `prompt` + `context` (`@files`, selection) so *New session: review-pr* is one click; today profiles are launch-only. | wizard · launch profiles | `LaunchProfile`; `ai.chat` context builder in `src/app/ai.zig` | S | |
| 13 | **Done-but-dirty signal.** A session that ended with uncommitted changes in its cwd is the thing you forget. Row shows `●` dirty count from `git status --porcelain` of the session's cwd; the table's summary block counts "dirty, ended". | table · list · git | `git status` per distinct cwd (cache by cwd, 3 s cadence like the scan) | S | piggyback on `sessions.refresh_ms`; one `git status` per unique cwd, not per row |
| 14 | **Agent-reviews-agent.** Row action *Review with…* spawns a second session (#3 machinery) with the prompt "review the diff on branch X" in the same worktree, linked as a child row. | table | #3 + #4 | S | after #3 |
| 15 | **Codex parity for resume + cost.** `sessions.open` launches a bare `codex` for Codex rows (`src/sessions.zig:458`); `codex resume <id>` exists (CLI ≥ 0.20, 2025) and the rollout JSONL carries `session_id`. | list · table | `~/.codex/sessions/**/rollout-*.jsonl` | S | `cli.codexResumeArgv` mirroring `claudeResumeArgv` |

Explicitly **not** ranked: Docker sandboxes, cloud handoff, mobile,
team audit — the cloud source is already decided (`where: cloud`) and
the rest are not one-machine problems.

---

## 4. Three things to do better than all of them

All three are IDE-shaped: they use the editor, the git rail and the
diff pane that already exist, instead of a new dashboard.

### A. The worktree *is* the session, and the branch rail shows it

`+ New session` → *Where: new worktree* creates `../<ws>-<slug>` on
`-b <slug>` (`git.worktree_add` path), launches the agent with that
`cwd`, and from then on the WORKTREES section of the branch rail
(`src/ui/git_palette.zig`) paints one row per worktree with **the
session glyph, its state badge and the dirty dot on the same line**:

```
WORKTREES
  main                      ✓
  ✦ ▲ wait  wt-auth  (auth) ●      ← a session is waiting, and it is dirty
  ✦ ● live  wt-http  (http)
  ◈ · ended wt-docs  (docs) ●      ← ended dirty: the one you forgot
```

Enter on the row opens the worktree as a workspace (exists:
`git.worktree_list`); `d` opens its diff (gap #4); `x` removes the
worktree *and* offers to delete the transcript (`sessions.delete`
exists). Nothing else surveyed puts the session state on the git
object it is mutating — they all keep a separate task list.
Data: `Stats.git_branch` + `cwd` from the JSONL joined to `git
worktree list --porcelain` (`parse.parseWorktrees`, `src/git/parse.zig:778`).

### B. Review a session's work with per-hunk stage, in the diff pane, and send the rest back

From a session row: *Diff* opens `Pane.diff` on that session's
worktree vs its base. The pane already stages / unstages / discards
**per hunk** (`applyHunk`, the Stage / Discard chips in
`ui/diff_view.zig`). Add one chip: **Send back** — the hunks you
*discarded* (or a line comment typed in the pane) become one message
written into the session's pty: "Rework these: `path:line` …". Stage
what is right, send back what is not, commit from the WIP row, `PR`
from the row (gap #7). The others review in a separate diff window and
send comments to a *chat*; here the review and the commit are the same
pane, and the undo is git's.

### C. FINDINGS rows spawn sessions, and a `waiting` session raises its tab

FINDINGS (`src/findings.zig`) is a list of typed, severity-ranked
markdown files the tester agents already write. Give the row the same
*Fix with agent* action TODOS has (`todos.fix_with_agent`), but
interactive with `--session-id`, one worktree per finding when asked
(A), and **multi-select → N sessions** (the FINDINGS list already has
the list chrome; multi-select comes from the table). The finding's
frontmatter gets `session: <id>` written back, so the FINDINGS row
shows the session's badge (`▲ wait` / `● live` / `· done`) and
`findings.resolve` is offered when the session's branch is merged.

The other half: a `waiting` edge (gap #1) *raises the tab* — the pty
tab's badge turns to the warn colour (`bufferline.zig` `badgeOf`
already does this for dirty), a `warn` toast names the session and
what it is waiting on (the pending tool name — `Row.current_tool` is
already parsed), and `Enter` on the toast focuses that pane. Optional
bell via `ui.session_bell`. This is the one thing every user of
several terminals wants and none of the terminal-shaped products
surveyed states it does for third-party CLIs: the surveyed orchestrators
show a status, they do not bring you to the pty.
