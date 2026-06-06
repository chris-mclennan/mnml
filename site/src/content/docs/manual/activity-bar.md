---
title: Activity bar
description: The vscode-style 4-cell icon strip on the far left of the rail — one icon per section (Explorer, Search, Git, Debug, Integrations). Click an icon to switch what fills the rest of the rail.
---

mnml's rail opens with a **vscode-style activity bar** — a 4-cell vertical strip pinned to the far left, with one icon per top-level *section*. Click an icon to switch which content fills everything to the right of the strip. All five sections render real content: **Explorer** (file tree + GIT sub-section + integrations rows), **Search**, **Source control**, **Run and debug**, and **Integrations** each have a v1 surface with a clear v2 follow-up scoped per section.

## Layout

The activity bar reserves a fixed-width column on the left edge of the rail; section content reflows into the remaining width. `Ctrl+B` still hides the whole rail (activity bar + content together) the way it did before.

```
┌────┬──────────────────────┬────────────────────────────────────┐
│ ▌ │ > MY-WORKSPACE       │                                    │
│    │   src/              │                                    │
│ S │     app.rs           │            editor pane             │
│    │     ui.rs           │                                    │
│ G │   tests/             │                                    │
│    │                     │                                    │
│ D │ ── GIT ──            │                                    │
│    │   * main            │                                    │
│ I │                     │                                    │
└────┴──────────────────────┴────────────────────────────────────┘
  └─ activity bar (4 cells wide)
       └─ section content (Explorer here; Search/Git/Debug/Integrations swap in)
```

The strip is exactly **4 cells** wide (`ACTIVITY_BAR_WIDTH`) — 1 cell of left padding, 1 cell for the icon, 1 cell of right padding, 1 spacer. The **active** icon is drawn in `blue`, **bold**, with a left-edge `▌` accent bar. **Inactive** icons render `dim` in the comment colour. The default on launch is **Explorer**.

## Sections

| Section | Nerd-font glyph | ASCII fallback | Command id | v1 content |
|---|---|---|---|---|
| Explorer | `nf-fa-folder_open` | `E` | `view.activity_explorer` | File tree + GIT sub-section + integrations rows |
| Search | `nf-fa-search` | `S` | `view.activity_search` | Inline workspace grep — typed input + grouped per-file results |
| Source control (Git) | `nf-md-source_branch` | `G` | `view.activity_git` | Live branch + ahead/behind + change-count chips + git command launchers |
| Run and debug | `nf-fa-bug` | `D` | `view.activity_debug` | Session status + watch count + DAP command launchers |
| Integrations | `nf-md-puzzle` | `I` | `view.activity_integrations` | Vertical clickable list of `[[ui.integration_icon]]` entries |

The fallback letter is what renders when `[ui] ascii_icons = true` (or when the terminal isn't running a Nerd Font); the glyph otherwise.

Two notes on overlap with what already exists:

- **Git.** The Explorer section still contains its `── GIT ──` sub-section (branches + worktrees), and the existing git graph / commit / log views are unchanged. The dedicated **Source control** activity-bar section is a higher-density control panel — live branch chip with ahead/behind, added/changed/removed counts, and one-click launchers for the everyday operations.
- **Debug.** mnml's existing DAP pane (Variables / Call-stack / Watches grid) stays where it is. The **Run and debug** activity-bar section is a *control panel*, not a replacement — session status + the run/continue/step family + watch management, with the rich grid still living in `debug_view.rs`.

## Interaction

- **Click** any icon to switch to that section. If `Ctrl+B` had hidden the rail, switching re-opens it — every `view.activity_*` command calls `set_activity_section`, which first sets `tree_visible = true` if needed, then flips the active section.
- Clicking the **already-active** icon is idempotent: it leaves the section showing rather than toggling it off. Use `Ctrl+B` to hide the rail entirely.
- All five commands are **palette-runnable** (`Ctrl+P`-style) — type `Activity:` to see them grouped together.
- No default keybindings ship with v1 — bind them yourself if you want chord access.

## Section details

### Integrations

A vertical list of the configured `[[ui.integration_icon]]` entries from your config. Each entry takes three rows: the glyph (in its configured colour) next to the tooltip / id, then the bound command dim below, then a blank spacer. Both the glyph row and the command row are clickable — they fire the icon's `command` field through the same dispatcher the compact rail-strip icons use, so a palette command id (`mixr.show`), an ex-command (`:host.launch myapp`), or a `tmnl:<host_id>` prefix all just work.

Empty state — when no `[[ui.integration_icon]]` entries are configured, the section paints `No integrations — add [[ui.integration_icon]] in your config` in italic.

**Missing-binary badge.** When an entry's `command` is `:host.launch <binary>`, mnml probes the binary against your `PATH` (via `which`) at render time. If it's not installed, the row's name dims to the comment colour and a dim red `(<bin> not installed)` suffix renders next to it — instead of failing silently when you click. Internal palette commands (no prefix) and tmnl host commands (`tmnl:<host_id>`) are always assumed available because they don't shell out, so they never wear the badge. The probe is cheap and only runs while the Integrations section is the active one.

### Search

An inline workspace grep — typed input box with grouped per-file results streaming below. Replaces v1's launcher panel of `find.*` commands.

Click the Search activity-bar icon (`🔍`) to focus the section; `set_activity_section` switches the section *and* focuses the input in one go, so you can start typing immediately. The layout from top to bottom:

```
 SEARCH

  / your query█
  4 hits (rg)

 src/foo.rs
   42:5  let x = 1;
   55:5  let y = 2;
 src/bar.rs
   18:9  let z = 3;
```

- **Input row** — `/ <query>█` in yellow. The cursor `█` only shows while the input is focused.
- **Status line** — when no query has been run, it reads `type · Enter to run · Esc to blur` (focused) or `click 🔍 icon to focus` (blurred). After a run it shows `<N> hit(s) (<tool>)` where `<tool>` is whichever backend resolved the search (`rg` / `git-grep` / built-in).
- **Grouped results** — each file path renders once in cyan, then its matching lines as `<line>:<col>  <text>` rows. The selected hit gets a bold reverse style.

Keys while the input is focused:
- **Type / backspace** — edits the query (no live search; runs on Enter to avoid paying for half-typed queries).
- **Enter** — runs the grep, populating `search_hits` + `search_used`. If the query is empty, results clear.
- **↑ / ↓** — moves the selection through the hit list.
- **Esc** — blurs the input back to the editor (selection is preserved).

When the input is blurred but results remain, **Enter** jumps to the selected hit (`search_section_open_selected` opens the file and places the cursor at the hit's line/col). Mouse: click any result row to jump straight to that file+line — the click also updates the selection.

Multi-root workspaces are concatenated, so hits from `extra_workspaces` show up under their own file paths.

### Run and debug

A live status line, an inline **WATCHES** list, plus a DAP command launcher.

The status line shows `● session active` (in green) or `○ no session` (dim), followed by the watch count (`{n} watch` / `watches`).

**Inline WATCHES list.** When `app.dap_watches` is non-empty, a `WATCHES` sub-header renders below the status line, followed by one row per watch expression — `<expr> = <value>` (expression in cyan, value in foreground colour). Per row the value shows:

- the latest evaluation from `app.dap_watch_results` when one exists,
- `(not evaluated)` in dim comment colour when no result has come back yet,
- `err: <message>` in dim red when the last evaluation returned an error.

Long values are truncated to fit the rail width with a trailing `…`. The list is capped at **5 rows**; overflow renders `+ N more (use add/remove)` in dim italic and the rest stay reachable via `dap.add_watch` / `dap.remove_watch`. The launcher rows scroll down underneath the watches so adding watches just compresses the trailing actions, it doesn't push them off-screen.

The launcher rows below the watches:

| Row | Chord | Command |
|---|---|---|
| Run | `F5` | `dap.run` |
| Continue | `F5 (running)` | `dap.continue` |
| Step over | `F10` | `dap.next` |
| Step into | `F11` | `dap.step_in` |
| Step out | `Shift+F11` | `dap.step_out` |
| Pause | `F6` | `dap.pause` |
| Toggle breakpoint | `F9` | `dap.toggle_breakpoint` |
| List breakpoints | — | `dap.list_breakpoints` |
| Add watch… | — | `dap.add_watch` |
| Remove watch… | — | `dap.remove_watch` |
| Clear watches | — | `dap.clear_watches` |

The DAP pane (Variables / Call-stack / full Watches grid) is still where the rich tree lives; the activity-bar list is the at-a-glance miniplayer.

### Source control (Git)

A live mini-dashboard, an inline **CHANGES** list, then the high-frequency git launchers. State is read off `app.git.snapshot()` so it reflects whatever the file watcher last saw.

- **Branch chip** — `⎇ <branch>` in purple, with `↑<ahead>` (green) and `↓<behind>` (orange) when nonzero. Reads `(no branch)` when detached / no repo.
- **Change-count chips** — `+<added>` (green), `●<changed>` (yellow), `-<removed>` (red), with a bold red `⚠ <n> conflict(s)` tail when conflicts are nonzero.

**Inline CHANGES list.** When `snap.files` is non-empty, a `CHANGES` sub-header renders below the chips, then up to **12** clickable file rows grouped by state in this order:

| Glyph | State |
|---|---|
| `⚠` (red) | Conflicted |
| `◆` (green) | Staged |
| `●` (yellow) | Modified |
| `?` (cyan) | Untracked |

Each row shows the state glyph followed by the workspace-relative path. Clicking a row dispatches `git.diff_file` against the active editor — v2.x will route the click to the row's *specific* path so the per-file diff opens directly instead of running against the currently-focused buffer.

When more than 12 files are dirty, the overflow renders `+ N more (use git.diff_all)` in dim italic — `git.diff_all` opens the whole-workspace diff if you need to see everything.

Then the action rows:

| Row | Command |
|---|---|
| Commit… | `git.commit` |
| Diff workspace | `git.diff_all` |
| Diff file | `git.diff_file` |
| Pull | `git.pull` |
| Push | `git.push` |
| Fetch | `git.fetch` |
| Stash | `git.stash` |
| Pop stash | `git.stash_pop` |
| Toggle blame | `git.blame_toggle` |
| Switch repo | `git.switch_repo` |
| Refresh repos | `git.refresh_repos` |

## Roadmap

The scoped v2 enhancements for Search, Run and debug, and Integrations all shipped. What's left in the section-by-section follow-up list:

- **Source control** — inline commit-message textarea so the whole commit flow happens in-rail, plus per-row click routing that opens the diff for the row's specific path (today the click dispatches `git.diff_file` against the active editor).
- **Run and debug** — clickable variables / call-stack mini-tree under the watches list, so the DAP pane stays optional for the common case.
- **Search** — streaming results so long-running greps surface hits as they come in rather than blocking on completion.

Bind `view.activity_*` to keys whenever you want chord access — the command ids are stable.
