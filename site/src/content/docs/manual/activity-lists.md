---
title: Activity lists — TODOs, Notes & Findings
description: The three list panels in mnml's activity bar — how they scan, scroll, filter, sort and create, what the sort chip does, and why TODOS is the one that's throttled and capped.
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
| Sorts on | file mtime / path, then line | file name | rendered relative name |
| Sort command | `todos.sort` | `notes.sort` | `findings.sort` |
| Auto-refresh | throttled to 2s | every file operation | every file operation |

## Anatomy of a list panel

```
FINDINGS  (12)      sort: Newest first     ⟳     ← caps header, count, sort chip, refresh chip
 󰍉 / filter                                       ← filter row
 [ + New finding ]                                ← create chip
                                                  ↓ list rows
 ▌󰘣 round-12/mouse-r16                    3h  ▓
  󰘣 round-12/keyboard-r16                 3h  ▓
  󰘣 startup-timings                       2d  ░
```

**Header.** Caps label, then a dim count in parentheses — `(N)` unfiltered, `(M of N)` when the filter narrows it. All three panels always show the count; on TODOS it can carry a trailing `+`, which means [the scan capped](#the-1000-marker-cap). Then a right-aligned chip cluster: the [`sort:` chip](#the-sort-chip), then the `⟳` chip pinned to the far right.

The cluster's widths resolve right-to-left, and each piece is **dropped rather than clipped** when it won't fit — a half-painted chip is a dead click target, which is worse than an absent one. The glyph and its click rect always go together, so a narrow panel never leaves an invisible hit target behind. The drop order is deliberate: the count subtitle goes first (it's nice), then the sort chip degrades to an icon and then vanishes, and the refresh chip keeps the last cells (it's the older affordance and users reach for it by position). Folding the subtitle into the refresh chip's budget was a regression at one point — typing in the filter grows `(N)` into `(N of M)`, which could delete the refresh chip mid-interaction.

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

**Mouse.** Clicking the filter row focuses it *and* moves focus to the panel — the key router needs both, and setting only the flag once left the row looking focused while every keystroke went to the editor. Clicking a row selects it: on NOTES and FINDINGS that opens the file; on TODOS it previews and keeps focus in the panel, so you can click a marker and then keep arrowing. Right-clicking a row opens its [context menu](#row-context-menus).

## The ⟳ chip: refresh and auto-refresh

**Left-click** the chip re-scans that panel now and fires a toast (`todos: rescanned`, `notes: refreshed`, `findings: refreshed`), so a click that finds nothing new still reads as having done something. The palette equivalents are `todos.refresh`, `notes.refresh` and `findings.refresh`.

**Right-click** the chip opens the panel's settings menu:

```
FINDINGS
  Refresh now
  Auto-refresh: on
✓ Newest first
  Oldest first
  Name (A–Z)
  Name (Z–A)
```

The first two rows are the same on every panel that has a chip — GIT, HTTP, SESSIONS, AGENTS and CLOUD AGENTS included — so the gesture means the same thing everywhere. The four sort rows are appended only for TODOS / NOTES / FINDINGS. They're duplicated here rather than living solely on the `sort:` chip because the question that started this ("not sure what controls order of notes") wants its answer where you already right-click.

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

Clicking `⟳` does **not** reset the cursor. On a 99-row list that used to mean losing your place every time the panel refreshed, which matters much more now that it refreshes on a timer.

## The `sort:` chip

Row order used to be a hard-coded newest-first with no affordance at all. The chip is what makes it visible and changeable without opening a menu first:

```
NOTES  (23)         sort: Name (A–Z)       ⟳
```

It's the same idiom the AGENTS and CLOUD AGENTS panels already wear as `view: status` and `view: compact` — dark text on pale cyan, one cell of air before the `⟳` chip, **left-click cycles, right-click lists**. The chip carries its key (`sort:`) rather than just the value, because a bare ` Newest first ` doesn't say what it controls, and two chips in one header have to be told apart.

**Left-click** advances to the next mode in menu order and wraps at the end. **Right-click** opens a `Sort by` menu with every mode spelled out and a `✓` on the current one:

```
Sort by
✓ Newest first
  Oldest first
  Name (A–Z)
  Name (Z–A)
```

Either way the choice is applied, **persisted immediately**, and toasted (`notes: Name (A–Z)`) — the toast is the feedback that the click landed on a chip small enough to doubt.

The chip is padded to the widest label it can ever hold, so it keeps a fixed width as the mode changes. That's not cosmetic either: the cluster is right-anchored, so a shorter label used to move the chip's left edge rightward and out from under a stationary pointer. Clicking the word `sort:` advanced twice and then went dead — "the button works sometimes".

### On a narrow panel

The full chip needs roughly 38 cells alongside the panel title and count. The default sidebar (`[ui] tree_width = 30`, less the 3-cell activity rail) leaves about 26, so on stock settings the expanded chip never rendered at all and the sorting was invisible to anyone who hadn't widened the sidebar. There are three rungs now, tried widest-first:

| Available width | Renders |
|---|---|
| room for label + count + chip + `⟳` | ` sort: Newest first ` |
| less than that | `  ` — icon only (`U+F0DC`, ASCII fallback ` ~ `) |
| less again | nothing |

Dropping to an icon is what the `⟳` chip beside it already does, so a narrow header reads as one family rather than one chip vanishing. Right-click still opens the full menu with every mode spelled out, which is where the words belong anyway.

### The four modes

Four explicit modes rather than two keys plus a direction flag: these are exactly what the menu lists, and a flag would have to be flattened back into four rows at every call site — and the click-to-cycle chip would need to know how to walk a 2-D space.

| Mode | Config token | Order |
|---|---|---|
| Newest first | `newest` | mtime descending, **name ascending as tiebreak** |
| Oldest first | `oldest` | mtime ascending, name ascending as tiebreak |
| Name (A–Z) | `name` | case-insensitive ascending on the name the row *displays* |
| Name (Z–A) | `name_desc` | case-insensitive descending on the same key |

`newest` is the default for all three panels, because it was already their hard-coded behaviour — changing what a user sees on upgrade is a separate decision from letting them choose.

Two details are load-bearing:

- **The name is Newest's tiebreak, not decoration.** mtime has one-second resolution, so a directory written in one burst — a freshly cloned repo, or a round of agent-written findings — otherwise renders in raw `read_dir` order: `note-24, note-10, note-34`.
- **Oldest mirrors Newest's key, not its comparator.** The name tiebreak stays *ascending* in both directions, so same-second files read A→Z either way. Reversing the whole comparator would flip the tiebreak too, which isn't what "oldest first" means to anyone.

The menu lists each key next to its reverse, so one click of the chip flips direction rather than jumping to an unrelated key.

### What each panel sorts on

The name key is whatever the row **displays**, which isn't always the file name:

- **NOTES** — the file name.
- **FINDINGS** — the path relative to the findings root with `.md` stripped, so `round-12/mouse-r16` sorts where it reads. Sorting by file stem there would order the rows differently from how they render.
- **TODOS** — by *file*, not by marker, since a file's markers should never appear shuffled. Name is path-then-line; Name (Z–A) reverses the *file* order and leaves line order alone; Newest is file-mtime-desc, then path, then line; Oldest is the same with mtime ascending. **Line order within a file is ascending in every mode** — "Z–A" means the file list reverses, not that a file's TODOs read bottom-up.

### Commands and config

One cycle command per panel, not one per (panel, mode) pair — four modes across three panels would put twelve near-identical rows in the palette and bury the commands you actually search for. Picking a *specific* mode stays on the chip's right-click menu, where the options are visible together with a `✓` on the current one.

| Command | Does |
|---|---|
| `todos.sort` | Cycle the TODOS sort order |
| `notes.sort` | Cycle the NOTES sort order |
| `findings.sort` | Cycle the FINDINGS sort order |

```toml
# ~/.config/mnml/config.toml
[ui]
todos_sort = "newest"        # newest | oldest | name | name_desc
notes_sort = "name"
findings_sort = "name_desc"
```

An unrecognised token falls back to `newest` rather than erroring — a typo shouldn't stop a panel drawing — and it's normalised on read, so it isn't stored verbatim only to match nothing later. `newest` and `name` predate the reversed pair and still parse to the modes they always did.

Changing the sort re-scans immediately, because the panels read from a cache. Choosing the mode you're already in writes nothing: each config write stamps a `config.toml.pre-config-*` backup and prunes the oldest, so cycling four modes would otherwise evict four entries of your disaster-recovery history per pass.

### SESSIONS sorts on a different axis

[SESSIONS](/manual/activity-panels/#the-sessions-panel) wears the same chip, but not the same modes. Its rows are live AI panes, not files — there's no mtime to order by, and "A–Z by session name" is a sort nobody asked for. Its axis is **State** vs **Manual**:

| Mode | Config token | Order |
|---|---|---|
| State | `auto` | needs-approval first, then thinking/running, then idle, then exited |
| Manual | `manual` | the order your Move up / down / to top / to bottom commands produced |

Pinned sessions bubble to the top in either mode. The state tiers are evaluated from each pane's live output (with a 500 ms cache, since the sort runs every frame), so a session that finishes thinking drops a tier within half a second.

The palette route is two commands rather than a cycle, since there are only two modes:

| Command | Does |
|---|---|
| `sessions.sort_auto` | Sort by state |
| `sessions.sort_manual` | Sort by your manual order |

```toml
[ui]
sessions_sort = "auto"       # auto | manual
```

One wrinkle worth knowing: the **Auto sort** row on a session card's own right-click menu also *clears* your manual order, because the state rules take over and there's nothing left to preserve. The chip and the two palette commands only change the mode — and unlike the card menu, they persist it.

## TODOS

`view.activity_todos` — every `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW` marker mnml can find in the workspace, one row per hit.

### What gets scanned

The walker starts at the workspace root, descends at most 6 levels, and stops at 1000 hits. It skips every dot-directory plus `target`, `node_modules`, `dist` and `build`. Files over 1 MB are skipped, and so is anything that isn't valid UTF-8.

Only these extensions are read:

```
rs · ts · tsx · js · jsx · py · go · java · kt · swift
cs · cpp · c · h · hpp · rb · sh · yml · yaml · toml · md
```

### The 1000-marker cap

Bounding a recursive scan is the point of the cap. Being *silent* about it was not: the walk stops mid-scan, so **which** markers made it in is decided by raw `read_dir` order. A workspace with 3043 markers reported a flat `(1102)`, and filtering for a package that really had a hundred of them returned zero.

The header count carries a trailing `+` when the walk capped, so the number reads as a floor rather than a total:

```
TODOS  (1102+)              sort: Newest first    ⟳
TODOS  (7 of 1102+)         sort: Newest first    ⟳
```

The `+` also qualifies the sort chip beside it. On a capped scan, "Newest first" is the newest of *what was scanned*, not of the workspace — and "Oldest first" likewise. Narrow the scope (a smaller workspace root, or fewer scanned directories) if you need the order to mean the whole tree.

The count can exceed 1000 slightly: the cap is checked when the walker enters a directory, and a file's markers are collected all at once, so the last file scanned can push the total past the line.

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

The focused row grows a `⋮` kebab at its right edge — hover-reveal, so thirty-nine other rows keep their full width for the path. Click it — or **right-click the row anywhere**, which opens the same menu — for AI actions on that marker. The kebab is the discoverable route; right-click is the fast one:

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

## Row context menus

Right-click a **NOTES** or **FINDINGS** row for the file actions that apply to a markdown file on disk. Both panels list the same kind of thing, so both menus are identical — the title is the file name:

```
finding-3.md
  Open
  Open in split
  Reveal in tree
  Reveal in Finder
  Copy path
  Rename…
  Delete…
```

| Row | Does |
|---|---|
| **Open** | Opens the file in the active leaf — the same as clicking the row |
| **Open in split** | Splits the active pane side by side first, then opens into the new one |
| **Reveal in tree** | Expands every ancestor in mnml's own file tree, selects the row, and focuses the tree |
| **Reveal in Finder** | Hands the path to the OS file manager. Reads *Reveal in Explorer* on Windows and *Reveal in file browser* elsewhere |
| **Copy path** | Copies the workspace-relative path to the clipboard |
| **Rename…** | Opens the rename prompt seeded with the current file name |
| **Delete…** | Opens the delete confirmation, which routes to mnml's trash by default |

Right-clicking also **moves the row cursor to the row you clicked**, so the menu and the highlight always name the same file. Without that, the menu could act on one row while the accent bar sat on another — which NOTES did for a while, even though its comment claimed otherwise.

Two things worth calling out:

- **Both reveal routes are offered, always.** They are separate rows because they do separate things: one navigates mnml's tree, one opens Finder/Explorer. Nine menus across the app once said "Reveal in tree" while firing the OS reveal, so the in-app action didn't exist at all and the label was the only thing claiming it did. A test now asserts the two routes appear an equal number of times.
- **FINDINGS had no right-click branch at all** until 2026-09-03 — the rows had click rects and a left-click handler, but a right-click fell through to the generic pane menu, which reads as the feature being absent. A coverage test now names every rail row family that has a left-click handler, so the next one is a deliberate decision rather than a silent omission.

Rename and Delete go through the same prompts as the file tree, including the trash, so see [File actions & tree up-navigation](/manual/file-actions/) for what they do on disk.

TODOS rows carry a different menu — a marker isn't a file, it's a location inside one — see [the row kebab](#the-row-kebab).

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
| `todos.sort` | Cycle the TODOS sort order |
| `notes.sort` | Cycle the NOTES sort order |
| `findings.sort` | Cycle the FINDINGS sort order |

Every panel with a visible `⟳` chip has a matching palette command, and so does every `sort:` chip — a header affordance that's mouse-only is a gap, and it's the same gap for both chips.

## Configuration

Everything these panels persist lives under `[ui]` in your user config:

```toml
# ~/.config/mnml/config.toml
[ui]
# Row order, per panel: "newest" (default) | "oldest" | "name" | "name_desc".
todos_sort = "newest"
notes_sort = "name"
findings_sort = "name_desc"

# SESSIONS orders on its own axis: "auto" (by run state) or "manual".
sessions_sort = "auto"

# Panels whose auto-refresh you turned off. Empty is the default.
auto_refresh_off = ["todos"]

# Swap the Nerd Font glyphs (⟳, 󰍉, the sort chip, the row icons) for ASCII.
ascii_icons = false
```

The chips write these keys for you and preserve the rest of the file, comments included. See [Settings & configuration](/manual/settings/) for the full schema.

## Next

- [Activity panels](/manual/activity-panels/) — the chrome these three share with GIT, HTTP, SESSIONS and AGENTS
- [Activity bar](/manual/activity-bar/) — the icon strip that switches between sections
- [AI panes](/manual/ai-panes/) — where the TODO kebab's Claude / Codex actions land
- [File actions & tree up-navigation](/manual/file-actions/) — the Rename / Delete / reveal actions the row menus call, and the file operations that trigger auto-refresh
- [Settings & configuration](/manual/settings/) — the `[ui]` keys these panels persist
