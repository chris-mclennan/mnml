---
title: Activity panels
description: The shared shape every activity-bar panel wears — caps header, count, top-right refresh chip, `/` filter row — and what each of GIT / TODOS / NOTES / FINDINGS / SESSIONS / HTTP / AGENTS does inside it.
---

Every section of the activity bar renders a panel into the same column, and every one of those panels wears the same three rows of chrome: a **caps title with a count**, a **top-right refresh chip**, and a **`/` filter row**. Learn the shape once and it transfers — the keys, the placeholders, the empty-state copy and the glyphs are identical whether you're looking at GIT, TODOS or SESSIONS.

That consistency is enforced in code rather than by convention. A set of small shared modules under `src/ui/` own the magnifier glyph, the refresh glyph, the two filter placeholders, the caps-label and subtitle styles, the filter-chip background, the empty-state layout, and the `+ New …` action-button role. Before they existed, ~14 filter rows had drifted to two different magnifier codepoints and six refresh chips to four different glyphs. A design change now lands in every panel at once.

This page covers the shared shape first, then what's specific to each panel. For the icon strip that switches between sections, see [Activity bar](/manual/activity-bar/).

## The shared shape

```
GIT                                        ⟳     ← caps header + right-aligned refresh chip
 󰍉 / filter                                       ← filter row (inactive)
                                                  ← body
```

With a filter active, the header grows a dim count and the chip inverts:

```
TODOS  (3 of 47)                           ⟳
 󰍉 database▏
```

### The header row

- **Caps label** — `GIT` / `TODOS` / `NOTES` / `FINDINGS` / `SESSIONS` / `HTTP` / `AGENTS` / `CLOUD AGENTS` / `INTEGRATIONS`. Bold, in the theme's comment color, painted straight on the panel background (not on a chip).
- **Count subtitle** — dim, in parentheses, immediately after the label. Panels with a single flat list always show it: `(N)` unfiltered, `(M of N)` when a filter narrows it. Multi-section panels (GIT, INTEGRATIONS) deliberately show **no** top-level count — each of their sub-sections carries its own, and one number spanning LOCAL / REMOTE / WORKTREES / PRS / STASHES / TAGS wouldn't obviously mean anything.
- **Refresh chip** — a 3-cell icon-only chip (` ⟳ `, codicon-refresh `U+EB37`, ASCII fallback `↺`) pinned to the far right of the header row, cyan on the panel background. Same glyph, same size, same corner in every panel and in the file-tree header.

When the panel is too narrow to fit label + chip without clipping the title, the chip is dropped — **glyph and click rect together**, so a narrow panel never leaves an invisible hit target behind.

Six panels route their header through the shared helper (GIT, TODOS, NOTES, FINDINGS, SESSIONS, INTEGRATIONS). AGENTS, CLOUD AGENTS and HTTP compose their own because they carry an extra chip on the same row — a `view: <mode>` chip on the two agents panels, a collapse-all chip on HTTP — but they use the same glyph, the same styles and the same far-right placement, and they apply the same drop-glyph-and-rect rule when the width runs out.

### What refresh does, per panel

| Panel | Chip action | Palette equivalent |
|---|---|---|
| GIT | Re-discover repos — `git status`, branches, tags, worktrees | `git.refresh_repos` |
| TODOS | Re-scan the workspace for markers | `todos.refresh` |
| NOTES | Re-scan `.mnml/notes/` | `notes.refresh` |
| FINDINGS | Re-scan `.mnml/findings/` | `findings.refresh` |
| SESSIONS | Drop the render caches + the listening-port cache | — (mouse only) |
| HTTP | Re-scan all seven sections' caches | `http.refresh` |
| AGENTS | Force the next poll instead of waiting for the interval | `agents.refresh` |

Each fires a short toast (`todos: rescanned`, `git: refreshed`, …) so a chip click that finds nothing new still reads as having done something.

### The filter row

Row 1 of every panel is a filter input rendered as a full-width pill:

| State | Renders |
|---|---|
| Empty, unfocused | `󰍉 / filter` in the comment color |
| Empty, focused | `󰍉 type to filter…` with a cyan `▏` cursor |
| Non-empty | the text you typed, in the foreground color |

The magnifier is `nf-md-magnify` (`U+F0349`), ASCII fallback `/`. The placeholder pair is noun-form when idle and verb-form when it's waiting on you. Panels that need a scope hint extend it — CLOUD AGENTS reads `type to filter (ticket / runId / state)…`.

Matching is always case-insensitive substring; what it matches against is per-panel (see below).

### Keys when the panel is focused

| Key | Action |
|---|---|
| `/` | Focus the filter input |
| any printable char | Append to the filter |
| `Backspace` | Delete the previous character |
| `Ctrl+W` | Delete the previous word |
| `Ctrl+U` | Clear the whole filter |
| `Ctrl+V` | Paste from the clipboard |
| `Enter` | Unfocus, keeping the filter applied |
| `Esc` | Clear **and** unfocus |
| `j` / `↓` (filter unfocused) | Move the row cursor down |
| `k` / `↑` (filter unfocused) | Move the row cursor up |
| `Enter` (filter unfocused) | Activate the cursored row |

`↑` / `↓` and `Enter` do double duty by intent — while the filter is focused they edit the input, while it's unfocused they drive row navigation. The `/` grab is guarded against Ctrl and Alt, and stands down while a picker, prompt or the cmdline is open.

Click the filter row to focus it with the mouse; click elsewhere in the panel body to unfocus.

### Empty states

Empty states come from one shared renderer: a message row, plus an optional dim hint row under it, both indented two cells. Panels distinguish "nothing here at all" from "your filter matched nothing", so you always know whether the filter is what's hiding rows:

```
  No findings yet.
  Stored under .mnml/findings/*.md
```

```
  No findings match /foo — 7 in workspace
```

On a narrow panel the message ellipsizes rather than being clipped mid-word, and below ~10 usable cells it's dropped entirely — an ellipsis alone teaches nothing.

### Action chips

Panels with a create action put it directly under the filter row rather than at the bottom of the list, so it stays one keystroke away when the list scrolls past the panel height. All of them use the same solid-fill "primary action" role: `+ New note`, `+ New session`. The fill *is* the focus signal — there's no foreground swap on cursor, which at one point produced mid-grey text on mid-green.

## The TODOs panel

`view.activity_todos` — a workspace-wide scan for marker patterns in comments, one row per hit. The scan runs on first activation and populates a cache; the header's `⟳` (or `todos.refresh`) re-runs it.

### Marker patterns

Case-sensitive, matched on a word boundary so `TODOLIST` doesn't false-trip:

| Marker | Color |
|---|---|
| `TODO` | blue |
| `FIXME` | orange |
| `XXX` / `HACK` | red |
| `REVIEW` | purple |

The "is this in a comment?" heuristic is intentionally rough — the marker counts if any of `//`, `#`, `/*`, `--`, or `<!--` appears before it on the same line. So `let title = "TODO";` in a Rust literal doesn't count, but the `// TODO: hook this up` above it does.

Per-file constraints: files larger than 1 MB are skipped, and non-UTF-8 files (binaries) are skipped.

### Playwright / Jest test-modifier scanner

`.spec.ts` / `.test.ts` / `.spec.js` / `.test.js` files get a second pass that picks up call-site test modifiers, even though they aren't comment markers:

| Call | Rendered tag | Meaning |
|---|---|---|
| `test.fixme('title', …)` | `FIXME` | Pending test — needs work |
| `test.fail('title', …)` | `XXX` | Expected-to-fail — flagged as a hazard |
| `test.skip('title', …)` | `REVIEW` | Disabled test — needs a decision |

The title is the first quoted string on the same line. When there isn't one, the tag reads `.fixme(...)` verbatim so the row is still findable. FIXME wins when two markers share a line. Non-test files stay on the comment-only path, so a `.fixme(` in production code is never a false positive.

```
FIXME  tests/survey.spec.ts:3   renders survey card
XXX    tests/editor.spec.ts:8   editor accepts nested lists
REVIEW tests/legacy.spec.ts:12  legacy filter
```

### Rows and filtering

Row shape is `TAG  path:line  title` — tag bold in its color, path in the comment color, title in the foreground, truncated at 40 characters.

The filter matches against the tag, the workspace-relative path plus line number, or the title, so typing `db` narrows to every marker mentioning "db" in any of the three.

`Enter` (or a click) opens the file at the marker's line, cursor at column 0.

## The Notes panel

`view.activity_notes` — persistent workspace scratches under `<workspace>/.mnml/notes/*.md`, sorted most-recently-modified first.

`.mnml/` is auto-gitignored (it's mnml-scoped state — see [Security & hardening](/manual/security/#auto-gitignore)), so notes are local by default. Remove the line from `.gitignore` if you want to commit a specific one.

**`+ New note`** (chip, or `notes.new`) opens the New file prompt seeded with the next free auto-number — `note-1.md`, `note-2.md`, … Press `Enter` to accept the default, or type over it with a real name. The prompt exists because the chip used to create `note-1.md` silently with no chance to name it.

The filter matches the filename without its `.md` extension. Click or `Enter` opens the note.

## The Findings panel

`view.activity_findings` — a workspace-scoped archive of tester and review reports under `<workspace>/.mnml/findings/*.md`, sorted by modification time descending.

It's zero-config and cross-project: `cd ~/Projects/mixr && mnml .` picks up that repo's `.mnml/findings/` with no setup. Agents and testers write reports there; the panel is where you read them.

Rows are `icon  name  age` — the name is relative to the findings root with the `.md` stripped, so a nested round directory renders `round-12/mouse-r16` rather than losing its context to the file stem, and the right-aligned age is a humanized mtime. Clicking a row opens the markdown in an editor pane.

The filter matches the same rendered relative name the row shows. The panel leaves one blank row between the filter and the first finding — deliberate breathing room, because unlike NOTES and SESSIONS it has no create chip to occupy that slot.

v1 is a flat list plus the filter; right-click actions (archive / delete / mark reviewed) are a follow-up.

## The Sessions panel

`view.activity_sessions` — a cmux-style vertical strip of your **AI sessions**, not every process mnml has spawned.

That scoping was a user report: *"why is bitbucket showing up in sessions? shouldn't a session just be Claude Code or Codex?"*. Sessions lists Pty panes whose profile label is `Claude Code`, `Claude Code (resumed)` or `Codex`. Bare shells, integration binaries (`:term <binary>`), and task launches are excluded — they still appear in their leaf's tab strip as regular Pty tabs, they just don't clutter this view.

### The session card

Each session renders three rows:

- **Name** — from `:session.rename`, else a detected ticket via `[ui] ticket_prefixes`, else the OSC window title, else the profile label.
- **Context** — `⎇ <branch>  ·  <cwd basename>`.
- **Status** — a status chip, plus an optional ticket chip and an optional listening-port chip.

| Elapsed since last output | Status | Color |
|---|---|---|
| < 2s | `running` | green |
| < 30s | `recent` | comment |
| otherwise | `idle` | grey |
| child exited | `exited` | red |

The port chip lists any TCP ports the child is listening on (cached via a periodic `lsof`), so a Vite / Next / Playwright session shows `:3000` without extra work. The header's `⟳` clears that cache along with the render caches.

### Ordering and pinning

Right-click a session card for the per-session menu: **Pin** / **Unpin**, **Move up** / **Move down** / **Move to top** / **Move to bottom**, **Auto sort** (with a `✓` when active), **Rename…**, a session color submenu, and **Close session**.

Pinned sessions always sort first. Below them, **Auto** orders by state (running first) and **Manual** honours the order your move commands produced — any move switches the mode to Manual, and the Auto sort row switches it back.

### `+ New session`

Left-click spawns a fresh Claude Code pane (`ai.claude_code_new` — the always-spawn command, not the reveal-or-open one, which no-opped when a pane was already focused). Right-click opens a batch menu: **New session** / **Open ×2** / **Open ×4** / **Open ×8**, for fanning out parallel Claudes without clicking eight times.

### Filtering

The filter matches five fields at once — display name, profile label, git branch of the cwd, cwd basename, and detected ticket. That covers the common asks directly: type `codex` for the Codex tabs, `te-1234` for one ticket's sessions, `refactor` for everything on that branch.

`Enter` (or a click) reveals the cursored session — focusing its pane and walking up the layout tree if it lives in another leaf or tab page.

## The panels with their own pages

Three more activity sections wear the same chrome but are documented in depth elsewhere:

- **GIT** (`view.activity_git`) — repo header, LOCAL / REMOTE / WORKTREES / PRS / STASHES / TAGS sections, each with its own count. The `⟳` re-discovers repos. See [Git](/manual/git/).
- **HTTP** (`view.activity_http`) — the seven-section sidebar (COLLECTIONS / FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED), a collapse-all chip beside the refresh chip, and per-section chip clusters. Its filter narrows across every section at once, and a matching request name force-expands its collection so hits show without an extra click. See [HTTP variables, edit split & panel filter](/manual/http-request-polish/#http-panel--filter).
- **AGENTS** / **CLOUD AGENTS** (`view.activity_agents`, `view.activity_cloud_agents`) — cross-workspace Claude / Codex dashboards grouped by status, and the ECS runner's cloud rows with per-row Copy runId / Open CloudWatch / Open PR. Both carry a `view:` mode chip to the left of the refresh chip. See [AI panes](/manual/ai-panes/) and [Cloud agents runner (ECS)](/manual/cloud-agents-config/).

## Cross-panel comparison

| | TODOs | Notes | Findings | Sessions |
|---|---|---|---|---|
| Source of rows | scan of workspace comments | `.mnml/notes/*.md` | `.mnml/findings/*.md` | AI Pty panes |
| Order | scan order | mtime desc | mtime desc | pinned, then Auto / Manual |
| Scan trigger | activation + `⟳` | activation + `⟳` | activation + `⟳` | continuous (live) |
| Header count | `(M of N)` when filtered | always | always | always |
| Filter matches | tag / path / title | filename | relative name | name / label / branch / cwd / ticket |
| Row activation | opens file at line | opens the note | opens the report | reveals + focuses the pane |
| Create chip | — | `+ New note` | — | `+ New session` |

## Next

- [Activity bar](/manual/activity-bar/) — the icon strip that switches between these sections
- [AI panes](/manual/ai-panes/) — the Claude Code / Codex panes the Sessions panel lists
- [Git](/manual/git/) — what lives inside the GIT panel's six sections
- [HTTP variables, edit split & panel filter](/manual/http-request-polish/) — the HTTP panel's variant of the same filter shape
- [Tabs, splits & tab pages](/manual/tabs-splits/) — the tab strips these panels' rows open into
