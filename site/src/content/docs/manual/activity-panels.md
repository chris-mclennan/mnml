---
title: TODOs, Notes & Sessions panels
description: The activity-bar's three list-shaped panels — TODOs (marker scan across the workspace), Notes (persistent `.mnml/notes/*.md` scratches), Sessions (open Pty sessions). All three share the `/`-focus filter idiom and j/k/arrow row navigation.
---

Three of mnml's activity-bar sections are list-shaped: **TODOs** scans source-code comments for `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW` markers, **Notes** lists the workspace's `.mnml/notes/*.md` files, **Sessions** lists every open Pty pane (Claude Code, Codex, shell, task). All three share the same interaction shape as the HTTP / Agents / Cloud Agents panels — `/` focuses a filter input; typing narrows in place; `j` / `k` (or arrows) move the row cursor; `Enter` activates.

This page is the deep tour for those three panels. For the parent activity bar (icons and section switching) see [Activity bar](/manual/activity-bar/). For the HTTP panel's variant of the same idiom see [HTTP Request pane — variables, edit split & panel filter](/manual/http-request-polish/#http-panel--filter).

## The shared filter shape

Every one of TODOs / Notes / Sessions / Agents / CloudAgents / HTTP renders the same filter row directly under its section header:

```
TODOS  (3 of 47)                ← count only appears when filter is active
 / filter                       ← inactive placeholder
```

Focused:

```
TODOS  (3 of 47)
 🔍 database▏                    ← inverted cursor, chip bg lifted to bg2
```

The magnifier glyph is a Nerd Font code (`nf-cod-search`). Filter behavior is case-insensitive substring match against the panel-specific haystack (below).

### Keys when the panel is focused

| Key | Action |
|---|---|
| `/` | Focus the filter input |
| any letter / digit | Append to the filter |
| `Backspace` | Drop the last character |
| `Enter` | Unfocus (keep the filter applied), move focus to row list |
| `Esc` | Clear + unfocus |
| `j` / `↓` (when filter is unfocused) | Move row cursor down |
| `k` / `↑` (when filter is unfocused) | Move row cursor up |
| `Enter` (when filter is unfocused) | Activate the cursored row |

`↑` / `↓` and `Enter` do double duty by intent — while the filter is *focused* they edit the input; while it's *unfocused* they drive row navigation. This matches the HTTP / Agents / Cloud Agents panels for muscle-memory reuse across the activity-bar.

Click the filter row to focus via mouse; click anywhere else in the panel body to unfocus.

## The TODOs panel

`view.activity_todos` (activity bar icon: `nf-fa-check_square`, ASCII fallback `O`) — a workspace-wide scan for marker patterns in comments, one row per hit.

The scan runs on first activation and populates a cache. Re-scan via the `⟳ Rescan` chip at the bottom of the panel or `todos.refresh`.

### Marker patterns

Case-sensitive, matched on a word boundary so `TODOLIST` doesn't false-trip:

| Marker | Color |
|---|---|
| `TODO` | blue |
| `FIXME` | orange |
| `XXX` / `HACK` | red |
| `REVIEW` | purple |

The heuristic for "is this in a comment?" is intentionally rough — the marker gets picked up if any of `//`, `#`, `/*`, `--`, or `<!--` appears before it on the same line. Everything else is skipped, so a `let title = "TODO";` in a Rust literal doesn't count as a marker but the `// TODO: hook this up` above it does.

Per-file constraints:

- Files larger than 1 MB are skipped.
- Non-UTF-8 files (binaries) are skipped.

### Playwright / Jest test-modifier scanner

`.spec.ts` / `.test.ts` / `.spec.js` / `.test.js` files get a second scanner pass that picks up call-site test modifiers — even though they're not comment markers:

| Call | Rendered tag | Behavior |
|---|---|---|
| `test.fixme('title', …)` | `FIXME` | Pending test — needs work |
| `test.fail('title', …)` | `XXX` | Expected-to-fail — flagged as hazard |
| `test.skip('title', …)` | `REVIEW` | Disabled test — needs a decision |

The title is the first quoted string on the same line (single or double quotes). When no title is present the tag reads `.fixme(...)` verbatim so you can still find the row.

FIXME wins if two markers appear on the same line (higher-severity mapping).

Non-test files still use the comment-only path — no false positives on a `.fixme(` in production code.

Example: a Playwright spec with three modifier calls surfaces three rows:

```
FIXME  tests/survey.spec.ts:3   renders survey card
XXX    tests/editor.spec.ts:8   editor accepts nested lists
REVIEW tests/legacy.spec.ts:12  legacy filter
```

### Row shape

```
TAG  path:line  title
```

The tag renders bold in its color; the path renders in the comment color; the title in the foreground color. Long titles truncate to 40 characters.

### Filter haystack

The `/` filter matches (case-insensitive substring) against any of:

- Tag (`TODO` / `FIXME` / etc.)
- Workspace-relative path + line number
- Title text

So typing `db` narrows to every TODO that mentions "db" in any of those three.

Header switches to `TODOS  (N of M)` when the filter is active — N is filtered hits, M is total hits.

### Activation

`Enter` (or click) on a row opens the file at the marker's line via `open_path` + `goto_line_str`. The cursor lands at column 0 of the marker line.

## The Notes panel

`view.activity_notes` (icon: `nf-fa-sticky_note`, ASCII fallback `N`) — persistent workspace scratches under `.mnml/notes/*.md`.

### What lives there

Markdown files under `<workspace>/.mnml/notes/`. `.mnml/` gitignores itself by default (mnml-scoped state), but you can commit specific notes per-workspace by removing them from `.gitignore`.

### `+ New note` action

A `+ New note` row at the bottom of the panel creates a new markdown file (`.mnml/notes/note-1.md`, incrementing when files exist) and opens it as an MdPreview pane. Palette command: `notes.new_note`.

### Row shape

Flat list of filenames (no directory nesting). Click / Enter opens the file.

### Filter haystack

Case-insensitive substring match against the filename (without the `.md` extension). Header switches to `NOTES  (N of M)` when the filter is active.

Empty filtered state renders `No matches — try clearing (Esc)` instead of the default `no notes yet` copy.

## The Sessions panel

`view.activity_sessions` (icon: `nf-md-tab`, ASCII fallback `T`) — a cmux-style vertical tab strip of every open Pty session in the workspace.

### What appears

Every `Pane::Pty` in the pane list — Claude Code, Codex, shell panes, `:term` binaries, tasks. Each tab shows:

- **Row 1** — session display name (from `:session.rename`, else `[ui] ticket_prefixes` detection, else OSC window title, else profile label). Long names truncate.
- **Row 2** — `⎇ <branch>  ·  <cwd basename>` — the git branch of the pane's cwd + a short cwd label.
- **Row 3** — status chip (`running` / `recent` / `idle` / `exited`) + optional detected-ticket chip + optional listening-port chip (`:3000`).

Status thresholds:

| Elapsed since last output | Status | Color |
|---|---|---|
| <2s | `running` | green |
| <30s | `recent` | comment |
| else | `idle` | grey |
| child exited | `exited` | red |

The port chip lists any TCP ports the child process is listening on (cached via periodic `lsof`), so a Vite / Next / mixr / Playwright session shows `:3000` on the status row without extra work.

### `+ New session` action

`+ New session` at the bottom of the panel opens a new shell Pty pane. Click / Enter activates. Palette: `sessions.new_session` (or the various `ai.claude_code_new_*` variants for placement-specific spawns — see [AI panes](/manual/ai-panes/)).

### Filter haystack

Case-insensitive substring match against any of:

- Session display name (from `:session.rename`)
- Profile label (`claude code` / `codex` / `shell` / user-set)
- Git branch of the cwd
- Cwd basename
- Detected Jira / project ticket (via `[ui] ticket_prefixes`)

The five-way match makes the filter useful for the common case: "show me the Codex tabs" (type `codex`), "show me the TE-1234 sessions" (type `te-1234`), "show me sessions on the `refactor` branch" (type `refactor`).

Header switches to `SESSIONS  (N of M)` when the filter is active. Empty filtered state renders `No matches — Esc clears`.

### Activation

`Enter` (or click) reveals the cursored session's pane — focuses it and scrolls it into view. If the pane is in a different tab page or leaf, the reveal walks up the layout tree until the pane is focused.

## Cross-panel comparison

Since the three panels look and behave similarly, here's the "which one has what" summary:

| Feature | TODOs | Notes | Sessions |
|---|---|---|---|
| Source of rows | scan of workspace comments | files under `.mnml/notes/` | live `Pane::Pty` list |
| Scan trigger | on activation + `⟳ Rescan` | on activation + `notes.refresh` | continuously (live) |
| Filter match | tag / path / title | filename | display name / label / branch / cwd / ticket |
| Row activation | opens file at line | opens file (MdPreview pane) | reveals + focuses pane |
| Action row at bottom | `⟳ Rescan` | `+ New note` | `+ New session` |
| Playwright modifier scan | yes (on `.spec.ts` etc.) | n/a | n/a |

Filter idioms are identical — the same `/` / `Enter` / `Esc` chords, the same header count format, the same "no matches" copy. Muscle memory transfers.

## Related panels

Two more activity-bar panels use the same filter idiom:

- **Agents** (`view.activity_agents`) — cross-workspace Claude / Codex / shell agents dashboard, grouped by status (Action Needed / Running / Done) with an animated spinner glyph on running rows.
- **Cloud Agents** (`view.activity_cloud_agents`) — cloud-only agents (ECS runner rows), with per-row affordances for Copy runId / Open CloudWatch / Open PR.
- **HTTP** (`view.activity_http`) — the seven-section HTTP sidebar (FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS / COLLECTIONS). Covered in depth on [HTTP Request pane — variables, edit split & panel filter](/manual/http-request-polish/#http-panel--filter).

## Next

- [Activity bar](/manual/activity-bar/) — the parent icon strip that switches between all sections
- [AI panes](/manual/ai-panes/) — the Pty sessions that populate the Sessions panel
- [HTTP Request pane — variables, edit split & panel filter](/manual/http-request-polish/) — the HTTP panel's variant of the same filter shape
- [Editing](/manual/editing/) — the buffer TODOs / Notes rows open into
