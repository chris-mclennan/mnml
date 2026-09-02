---
title: Activity lists — TODOs, Notes & Findings
description: The three list panels in mnml's activity bar — how they scan, scroll, filter, sort and create, and why TODOS is the one that's throttled.
---

TODOS, NOTES and FINDINGS are one panel written three times. Each is a flat list of things in the workspace, rendered into the activity-bar column with the same header, the same `/` filter row, the same `+ New …` chip, the same focused-row accent bar and the same scroll model. What differs is where the rows come from: TODOS scans your source for marker comments, NOTES lists `.mnml/notes/*.md`, FINDINGS lists `.mnml/findings/*.md`.

Treating them as a family is deliberate. The scroll arithmetic lives in one helper (`panel_chrome::list_scroll_window`), the sort mode in one enum (`ui::list_sort::ListSort`), the header in one renderer. All three shipped without scrolling at one point — they drew one screenful and dropped the rest silently — which is exactly the class of bug a shared helper stops the fourth panel repeating.

This page is the deep version of those three sections. For the chrome shared with *every* activity panel (including GIT, HTTP, SESSIONS and AGENTS), see [Activity panels](/manual/activity-panels/); for the icon strip that switches between them, see [Activity bar](/manual/activity-bar/).

## The three at a glance

| | TODOS | NOTES | FINDINGS |
|---|---|---|---|
| Section command | `view.activity_todos` | `view.activity_notes` | `view.activity_findings` |
| Rows from | marker comments across the workspace | `.mnml/notes/*.md` | `.mnml/findings/**/*.md` |
| Row shape | `TAG  path:line  title` | `icon  name  age` | `icon  relative/name  age` |
| Filter matches | tag, path:line, or title | file name (no `.md`) | rendered relative name |
| Create action | `+ New todo` → `TODO.md` | `+ New note` | `+ New finding` |
| Row activation | opens the file at that line | opens the note | opens the report |
| Auto-refresh | throttled to 2s | every file operation | every file operation |

## Anatomy of a list panel

```
FINDINGS  (12)                             ⟳     ← caps header, count, refresh chip
 󰍉 / filter                                       ← filter row
 [ + New finding ]                                ← create chip
                                                  ↓ list rows
 ▌󰘣 round-12/mouse-r16                    3h  ▓
  󰘣 round-12/keyboard-r16                 3h  ▓
  󰘣 startup-timings                       2d  ░
```

**Header.** Caps label, then a dim count in parentheses — `(N)` unfiltered, `(M of N)` when the filter narrows it. All three panels always show the count. The `⟳` chip is pinned to the far right; on a panel too narrow to fit label + chip, the chip and its click rect are dropped together, so a narrow panel never leaves an invisible hit target behind.

**Filter row.** A full-width pill reading `󰍉 / filter` when idle and `󰍉 type to filter…` with a cyan `▏` caret when focused. Case-insensitive substring, always.

**Create chip.** `+ New todo` / `+ New note` / `+ New finding`, in the shared solid-fill primary-action role. It sits directly under the filter rather than at the bottom of the list, so it stays put when the list scrolls. FINDINGS and TODOS both used to leave this row blank for want of a create action; both have one now, so all three panels stack the same way.

**Rows.** Two unhighlighted cells of inset, then the focused row's blue `▌` accent bar, then the icon, the name, and — on NOTES and FINDINGS — a right-aligned age column. The highlight band starts at column 1, not column 0, so it never reads as welded to the panel's left edge.

**Scrollbar.** Painted in the rightmost column only when the list is longer than the visible rows, and the row width shrinks by one to make room for it.

### The age column

NOTES and FINDINGS render the file's mtime as a humanized age in the right-hand column, two cells clear of the name:

| Age | Renders |
|---|---|
| under a minute | `now` |
| under an hour | `14m` |
| under a day | `6h` |
| under two weeks | `9d` |
| under nine weeks | `5w` |
| under two years | `7mo` |
| beyond that | `3y` |

The name is budgeted against the row width *minus* the scrollbar column, the 2-cell gap and the age string — so a long note name clips with the age still legible rather than running into it.

TODOS has no age column: its rows spend that width on `path:line` plus the marker title.

## Scrolling

All three lists scroll three ways, and all three ways agree:

- **Keyboard** — `j` / `k` or `↓` / `↑` move the row cursor; the window follows it in both directions.
- **Mouse wheel** — over the list body. The offset is clamped against the list length first, so wheeling past the end can't drag the cursor onto a row you never selected.
- **Scrollbar drag** — grab the bar in the right-hand column and drag it.

The wheel and the drag both move the **cursor**, not just the offset. That's not cosmetic: the render window is derived from the cursor every frame, so nudging the offset alone would be snapped straight back on the next draw — which is what made a bottom-to-top scrollbar drag a complete no-op in an earlier version.

## Keys

The panel must have focus (click it, or switch to its section) and the filter must be unfocused for row navigation.

| Key | Action |
|---|---|
| `/` | Focus the filter input |
| any printable char | Append to the filter |
| `Backspace` | Delete the previous character |
| `Ctrl+W` | Delete the previous word |
| `Ctrl+U` | Clear the whole filter |
| `Ctrl+V` | Paste into the filter |
| `Enter` (filter focused) | Unfocus, keeping the filter applied |
| `Esc` (filter focused) | Clear the filter **and** unfocus |
| `j` / `↓` | Move the row cursor down |
| `k` / `↑` | Move the row cursor up |
| `Enter` | Activate the cursored row |

`/` only grabs when no picker, prompt or cmdline is open, and stands down for `Ctrl` / `Alt` combinations. These bindings are the same in vim and standard input modes — the panels are chrome, not a buffer, so the input handler never sees these keys. See [Editing](/manual/editing/) for the modes themselves.

**Mouse.** Clicking the filter row focuses it *and* moves focus to the panel — the key router needs both, and setting only the flag once left the row looking focused while every keystroke went to the editor. Clicking a row selects it: on NOTES and FINDINGS that opens the file; on TODOS it previews and keeps focus in the panel, so you can click a marker and then keep arrowing.

## The ⟳ chip: refresh, auto-refresh and sort

**Left-click** the chip re-scans that panel now and fires a toast (`todos: rescanned`, `notes: refreshed`, `findings: refreshed`), so a click that finds nothing new still reads as having done something. The palette equivalents are `todos.refresh`, `notes.refresh` and `findings.refresh`.

**Right-click** the chip opens the panel's settings menu:

```
FINDINGS
  Refresh now
  Auto-refresh: on
✓ Newest first
  Name (A–Z)
```

Both settings are **per-panel and persisted** to your user config the moment you pick them. Right-clicking the chip is the same gesture on every panel that has one (GIT, HTTP, SESSIONS, AGENTS, CLOUD AGENTS too) — only these three carry the sort rows, because only these three are lists of files with a name and an mtime.

### Auto-refresh

On by default for all three. When it's on, the panel re-scans after a filesystem change mnml makes — creating, deleting, renaming or duplicating a file, a paste, a background copy/move transfer, and **any save** — `Ctrl+S`, `:w`, `:w <path>` or `:saveas`. Before this, a note you created was absent from the panel, and a note you deleted lingered as a row, until you clicked `⟳`.

NOTES and FINDINGS scan one directory, so they re-scan on every such change. **TODOS is throttled to once every two seconds**, because its refresh walks the entire workspace synchronously — running that on every file operation is the per-frame full-scan shape behind mnml's earlier editor freezes. Excluding it outright was the previous policy, and that's why a user who edited `TODO.md` saw nothing until they hit the chip. A throttle keeps it current without the cost landing on a burst of writes.

mnml does not watch the filesystem. Changes made by another process — an agent writing findings, a teammate's `git pull` — appear on the next in-app file operation, the next throttle tick for TODOS, or when you click `⟳`.

Turn it off per panel from the chip menu. The config records only what you changed:

```toml
# ~/.config/mnml/config.toml
[ui]
auto_refresh_off = ["todos"]
```

Valid ids are `"todos"`, `"notes"`, `"findings"`, `"sessions"`, `"agents"`, `"cloud_agents"`, `"git"`, `"http"`.

### Sort

Two modes, per panel, defaulting to `newest`:

```toml
[ui]
todos_sort = "newest"      # or "name"
notes_sort = "name"
findings_sort = "newest"
```

- **Newest first** — most-recently-modified first, with the **displayed name as tiebreak**. mtime has one-second resolution, so a directory written in one burst (a freshly cloned repo, or a round of agent-written findings) otherwise renders in raw `read_dir` order: `note-24, note-10, note-34`. The tiebreak makes that block read alphabetically instead of randomly.
- **Name (A–Z)** — case-insensitive, on the string the row *displays*. That matters for FINDINGS, which shows a path relative to the findings root: sorting by file name there would order the rows differently from how they read.

TODOS sorts by file rather than by marker, since a file's markers should never appear shuffled: **Name** is path-then-line, and **Newest** is file-mtime-desc, then path, then line.

An unrecognised token in config falls back to `newest` rather than erroring — a typo shouldn't stop a panel drawing. Changing the sort re-scans immediately, because the panels read from a cache.

Clicking `⟳` does **not** reset the cursor. On a 99-row list that used to mean losing your place every time the panel refreshed, which matters much more now that it refreshes on a timer.

## TODOS

`view.activity_todos` — every `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW` marker mnml can find in the workspace, one row per hit.

### What gets scanned

The walker starts at the workspace root, descends at most 6 levels, and stops at 1000 hits. It skips every dot-directory plus `target`, `node_modules`, `dist` and `build`. Files over 1 MB are skipped, and so is anything that isn't valid UTF-8.

Only these extensions are read:

```
rs · ts · tsx · js · jsx · py · go · java · kt · swift
cs · cpp · c · h · hpp · rb · sh · yml · yaml · toml · md
```

### Markers

Case-sensitive, and the character after the marker must not be alphanumeric or `_`, so `TODOLIST` doesn't false-trip. One marker per line — the first match wins.

| Marker | Tag color |
|---|---|
| `TODO` | blue |
| `FIXME` | orange |
| `XXX` / `HACK` | red |
| `REVIEW` | purple |

The title is whatever follows the marker with leading `:`, `(`, `)` and spaces trimmed, capped at 120 characters.

**In code**, a marker counts only when it looks like a comment: at least one of `//`, `#`, `/*`, `--` or `<!--` appears before it on the same line. So this scans as one hit, not two:

```rust
// TODO: hook this up          ← collected
let title = "TODO";            ← ignored (no comment char before it)
```

**In markdown** there are no code comments, so the comment rule is relaxed: a marker counts if everything before it on the line is list, heading, quote or numbering punctuation. It's still anchored to the start of the line, so a passing mention of TODO mid-sentence is not collected.

```markdown
- TODO: wire up the export button      ← collected
1. FIXME: the retry loop never backs off   ← collected
> REVIEW: is this still the right shape?   ← collected

We should TODO this later.             ← ignored (mid-sentence)
```

Requiring a comment character used to mean a whole `TODO.md` scanned down to a single hit — the `#` in its own title heading.

### Playwright / Jest test modifiers

`.spec.ts`, `.test.ts`, `.spec.js` and `.test.js` files get a second pass for call-site test modifiers, which aren't comments but belong in this surface anyway:

| Call | Tag | Meaning |
|---|---|---|
| `test.fixme('…')` | `FIXME` | Pending test — needs work |
| `test.fail('…')` | `XXX` | Expected-to-fail — a hazard |
| `test.skip('…')` | `REVIEW` | Disabled test — needs a decision |

The title is the first quoted string after the call; when there isn't one, the row reads `.fixme(...)` verbatim so it's still findable. FIXME wins when a line matches more than one. Non-test files never take this path, so a `.fixme(` in production code is not a false positive.

### Rows and activation

Row shape is `TAG  path:line  title`, path workspace-relative and dim, title capped at 40 characters. The path is clipped first if it alone would fill the row, so a deep path can never squeeze the title out entirely — at least 8 characters of title survive.

Arrowing through the list **previews**: each row opens as a preview tab (so twenty arrow presses reuse one tab, not twenty) and focus stays in the panel. `Enter` **activates**: it opens the file properly and moves into it.

### The row kebab

The focused row grows a `⋮` kebab at its right edge — hover-reveal, so thirty-nine other rows keep their full width for the path. Click it for AI actions on that marker:

```
FIXME handle the empty case
  agent: developer
  /qa-sweep
  skill: rust-review
  Fix with Claude Code
  Fix with Codex
```

The first rows are discovered from the workspace's own `.claude/agents`, `.claude/commands` and `.claude/skills`, falling back to your `~/.claude/` ones (a workspace asset shadows a user-level one of the same kind and name, matching how Claude Code resolves them). The two plain fallbacks are always present — a workspace with a hundred agents still wants "just open Claude Code on this".

Whichever you pick spawns a Pty pane with a prompt that carries the file, line and marker text, so the model doesn't have to search for it:

```
Use the developer agent to Fix the FIXME at src/a.rs:42 — handle the empty case
```

See [AI panes](/manual/ai-panes/) for the panes those launch into.

### `+ New todo`

The chip (or `todos.new`) opens a one-line prompt, **New TODO (appended to TODO.md)**. What you type is appended to `TODO.md` at the workspace root, under an `## Inbox` heading, newest first:

```markdown
# TODO

## Inbox
- TODO: the newest entry lands here
- TODO: yesterday's entry
```

The heading is created if it's missing, and the file is created if it doesn't exist. `TODO.md` rather than `.mnml/todos.md` for two reasons: it's the file that already holds the workspace's backlog, so a todo made here sits beside the ones written by hand instead of splitting the list in two — and the scanner skips every dot-directory, so `.mnml/` would need a special case to be visible at all. `TODO.md` is normally tracked by git, which is right for a project backlog and wrong for a private note. Private notes have their own panel.

## NOTES

`view.activity_notes` — persistent workspace scratches at `<workspace>/.mnml/notes/*.md`, flat (no recursion), newest first by default.

`.mnml/` is auto-gitignored, so notes are local by default — see [Security & hardening](/manual/security/#auto-gitignore). Remove the line from `.gitignore` if you want to commit one.

**`+ New note`** (chip, or `notes.new`) creates the directory if needed and opens the New file prompt seeded with the next free auto-number — `note-1.md`, `note-2.md`, … with the name pre-selected. Press `Enter` to accept it, or type over it with a real name. The prompt exists because the chip used to create `note-1.md` silently with no chance to name it.

The filter matches the file name (without `.md`). `Enter` or a click opens the note in an editor pane, which routes `.md` through the same markdown path as any other file.

## FINDINGS

`view.activity_findings` — a workspace-scoped archive of tester and review reports at `<workspace>/.mnml/findings/`. Zero-config and cross-project: `cd ~/Projects/mixr && mnml .` picks up that repo's findings with no setup. Agents and testers write reports there; the panel is where you read them.

Unlike NOTES this walk is **recursive** — tester agents commonly nest reports under per-round directories — with a depth cap of 4 and an output cap of 500 rows. A `README.md` at the findings root is skipped, since it's the shipped index rather than a finding; nested READMEs still surface, because their parent directory names them meaningfully.

Rows show the path **relative to the findings root** with `.md` stripped, so a nested round renders `round-12/mouse-r16` rather than losing its context to the file stem. The filter and the A–Z sort both work on that same rendered string, so what you filter is what you see.

**`+ New finding`** (chip, or `findings.new`) mirrors `+ New note` exactly — creates the directory, seeds `finding-1.md`, `finding-2.md`, … into a New file prompt with the name selected. The panel's own docstring referred to this action for a while before it existed.

Right-click row actions — archive, delete, mark reviewed — are still a follow-up.

## Empty states

Each panel distinguishes "nothing here at all" from "your filter matched nothing", so you always know whether the filter is what's hiding rows.

```
  No markers found — click ⟳ in the header to rescan.
  Scans for TODO / FIXME / XXX / HACK / REVIEW.
```

```
  No notes yet — click + New note above.
  Stored under .mnml/notes/*.md
```

```
  No findings match /foo — 7 in workspace
  Stored under .mnml/findings/*.md
```

TODOS and NOTES both read `No matches — Esc clears` when a filter is what emptied the list. On a narrow panel the message ellipsizes rather than clipping mid-word, and below roughly ten usable cells it's dropped entirely.

## Commands

None of these carry a default key binding — reach them from the command palette (`Ctrl-Shift-P`) or bind them yourself in `[keys.global]`.

| Command | Does |
|---|---|
| `view.activity_todos` | Show the TODOS panel |
| `view.activity_notes` | Show the NOTES panel |
| `view.activity_findings` | Show the FINDINGS panel |
| `todos.new` | Prompt, then append to `TODO.md` |
| `notes.new` | Prompt, then create in `.mnml/notes/` |
| `findings.new` | Prompt, then create in `.mnml/findings/` |
| `todos.refresh` | Re-scan the workspace for markers |
| `notes.refresh` | Re-scan `.mnml/notes/` |
| `findings.refresh` | Re-scan `.mnml/findings/` |

Every panel with a visible `⟳` chip has a matching palette command, so keyboard-only users have parity with mouse users.

## Configuration

Everything these panels persist lives under `[ui]` in your user config:

```toml
# ~/.config/mnml/config.toml
[ui]
# Row order, per panel: "newest" (default) or "name".
todos_sort = "newest"
notes_sort = "name"
findings_sort = "newest"

# Panels whose auto-refresh you turned off. Empty is the default.
auto_refresh_off = ["todos"]

# Swap the Nerd Font glyphs (⟳, 󰍉, the row icons) for ASCII.
ascii_icons = false
```

The chip menu writes these keys for you and preserves the rest of the file, comments included. See [Settings & configuration](/manual/settings/) for the full schema.

## Next

- [Activity panels](/manual/activity-panels/) — the chrome these three share with GIT, HTTP, SESSIONS and AGENTS
- [Activity bar](/manual/activity-bar/) — the icon strip that switches between sections
- [AI panes](/manual/ai-panes/) — where the TODO kebab's Claude / Codex actions land
- [File actions & tree up-navigation](/manual/file-actions/) — the file operations that trigger auto-refresh
- [Settings & configuration](/manual/settings/) — the `[ui]` keys these panels persist
