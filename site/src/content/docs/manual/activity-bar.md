---
title: Activity bar
description: The vscode-style 4-cell icon strip on the far left of the rail — one icon per section (Explorer, Search, Git, Debug, Integrations). Click an icon to switch what fills the rest of the rail.
---

mnml's rail now opens with a **vscode-style activity bar** — a 4-cell vertical strip pinned to the far left, with one icon per top-level *section*. Click an icon to switch which content fills everything to the right of the strip. v1 only wires the **Explorer** section fully (the file tree + GIT sub-section + integrations rows that already existed pre-activity-bar); the other four icons render a `Coming soon` placeholder so the shape is visible from day one — their content lands as independent follow-ups.

## Layout

The activity bar reserves a fixed-width column on the left edge of the rail; the existing tree / section content reflows into the remaining width. `Ctrl+B` still hides the whole rail (activity bar + content together) the way it did before.

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

| Section | Nerd-font glyph | ASCII fallback | Command id | Status |
|---|---|---|---|---|
| Explorer | `nf-fa-folder_open` | `E` | `view.activity_explorer` | **v1** — file tree + GIT + integrations rows |
| Search | `nf-fa-search` | `S` | `view.activity_search` | v2 — placeholder |
| Source control (Git) | `nf-md-source_branch` | `G` | `view.activity_git` | v2 — placeholder |
| Run and debug | `nf-fa-bug` | `D` | `view.activity_debug` | v2 — placeholder |
| Integrations | `nf-md-puzzle` | `I` | `view.activity_integrations` | v2 — placeholder |

The fallback letter is what renders when `[ui] ascii_icons = true` (or when the terminal isn't running a Nerd Font); the glyph otherwise.

Two notes on overlap with what already exists:

- **Git.** The Explorer section already contains a `── GIT ──` sub-section (branches + worktrees), and the existing git graph / commit / log views are unchanged. The dedicated **Source control** activity-bar section is the planned home for a richer, full-rail-height git surface — log + commit detail + staging — without crowding the file tree.
- **Debug.** mnml's existing DAP pane stays where it is. The **Run and debug** activity-bar section will eventually hold breakpoints, the call stack, watch expressions, and a launch-config picker as a permanent rail surface (rather than a pane you open and close).

## Interaction

- **Click** any icon to switch to that section. If `Ctrl+B` had hidden the rail, switching re-opens it — every `view.activity_*` command calls `set_activity_section`, which first sets `tree_visible = true` if needed, then flips the active section.
- Clicking the **already-active** icon is idempotent: it leaves the section showing rather than toggling it off. Use `Ctrl+B` to hide the rail entirely.
- All five commands are **palette-runnable** (`Ctrl+P`-style) — type `Activity:` to see them grouped together.
- No default keybindings ship with v1 — bind them yourself if you want chord access. The commands themselves are stable; the eventual default chords are deferred until the v2 sections have content worth binding to.

## Placeholders

When a non-Explorer section is active, the content pane paints:

```
 Search

 Coming soon
```

with the section's label in bold and `Coming soon` in dim italic. Mouse clicks inside the placeholder do nothing — the placeholder also clears the tree-view click rects so a stale click from a prior frame can't accidentally fire on the file tree.

## Roadmap

Each v2 section will land as an independent feature so the activity-bar shape can stabilise without blocking on any one of them:

- **Search.** Workspace-wide ripgrep with live results + jump-to-match.
- **Source control.** Full-rail-height git log + commit detail + staging UI (today's GIT sub-section stays inside Explorer regardless).
- **Run and debug.** Breakpoints, call stack, watch expressions, launch configs — keeps the existing DAP pane as the runtime surface.
- **Integrations.** A dedicated home for `host.launch` integrations (`mnml-tickets-jira`, `mnml-db-postgres`, etc.) — independent from the Explorer's existing INTEGRATIONS sub-section header.

Add `view.activity_*` to your keybindings now if you want the muscle memory ready when the v2 content lands.
