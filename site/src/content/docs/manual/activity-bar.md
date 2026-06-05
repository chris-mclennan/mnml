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
| Search | `nf-fa-search` | `S` | `view.activity_search` | Launcher rows for `find.grep` / `find.find` / `find.next` / `find.replace` |
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

### Search

A launcher panel for mnml's existing find/grep commands. Each row shows a label and its chord:

| Row | Chord | Command |
|---|---|---|
| Grep workspace… | `Ctrl+Shift+F` | `find.grep` |
| Find in file… | `Ctrl+F` | `find.find` |
| Find next match | `Ctrl+G` | `find.next` |
| Replace in file… | `Ctrl+H` | `find.replace` |

A dim italic footer at the bottom flags the v2 follow-up: *type-to-grep inline, results stream below*. v1 doesn't render results inside the section — `Pane::Grep` and the editor-local find modeline still own that — the section just makes the entry points discoverable.

### Run and debug

A live status line plus a DAP command launcher. The status line shows `● session active` (in green) or `○ no session` (dim), followed by the watch count (`{n} watch` / `watches`). Below that, clickable rows:

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

v2 follow-up: inline mini-watches list so you can glance at current values without opening the DAP pane.

### Source control (Git)

A live mini-dashboard plus the high-frequency git launchers. Above the rows, three lines render live state straight off `app.git.snapshot()`:

- **Branch chip** — `⎇ <branch>` in purple, with `↑<ahead>` (green) and `↓<behind>` (orange) when nonzero. Reads `(no branch)` when detached / no repo.
- **Change-count chips** — `+<added>` (green), `●<changed>` (yellow), `-<removed>` (red), with a bold red `⚠ <n> conflict(s)` tail when conflicts are nonzero.

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

v2 follow-up: inline file-change list + a commit-message textarea so the whole commit flow happens in-rail.

## Roadmap

v1 lands each section as a working surface with a scoped v2 enhancement:

- **Search** — type-to-grep inline, results stream below the input (replaces the launcher rows when a query is active).
- **Source control** — inline file-change list with stage/unstage toggles + an in-rail commit-message textarea.
- **Run and debug** — inline mini-watches list rendered under the status line, so the DAP pane stays optional.
- **Integrations** — no scoped v2 work; this section's shape is final. New integrations land by appending `[[ui.integration_icon]]` entries.

Bind `view.activity_*` to keys whenever you want chord access — the command ids are stable.
