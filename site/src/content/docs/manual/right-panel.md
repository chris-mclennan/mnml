---
title: Right side panel
description: The mirror of the file rail on the right edge — a fixed-width column that hosts the Outline pane, the Diagnostics list, and (eventually) more panes that read better next to the editor than under it.
---

mnml's chrome wraps the editor on three sides: the file rail and activity bar on the left (toggled by `Ctrl+B`), the statusline + bufferline at top and bottom, and — since 2026-06-28 — a **right side panel** that mirrors the rail on the opposite edge. The right panel is the home for panes that read better as a vertical sidebar than as a horizontal split: the Outline (`outline.show`) and the project-wide Diagnostics list (`lsp.diagnostics`). When the panel is visible, those two commands route their pane *into* the panel instead of carving a split out of the editor body.

![right side panel toggle: empty state → outline hosted → close evicts the pane](../../../assets/tapes/right-panel-toggle.gif)

The panel is opt-in. It opens with `Ctrl+Shift+B` (the natural mirror of `Ctrl+B`), it can be sized by dragging its left edge, it persists across restarts via `session.json`, and it has a one-cell `×` close button on its header so you can evict the hosted pane without closing the column itself.

## Opening and closing

| Gesture | What it does |
|---|---|
| `Ctrl+Shift+B` | Toggle the panel. Fires `view.toggle_right_panel`. |
| `:set rightpanel` | Open the panel (idempotent — already-open stays open). |
| `:set rightpanel!` | Toggle (vim-style `invrightpanel` is the long form; `:set rp!` is the short form). |
| `:set norightpanel` | Close the panel. |
| Click the palette-bar's right-panel chip | Toggle. Same command. |

`Ctrl+Shift+B` is VS Code's "Run Build Task" chord. mnml has no build-task concept yet, so the chord is repurposed for the panel toggle; if a task runner lands later, the binding may need revisiting (`Ctrl+Alt+B` is the next pick). The palette command (`view.toggle_right_panel`) calls this out in its title so a porter sees the conflict.

The panel's visibility, width, and currently-hosted pane id all round-trip through `<workspace>/.mnml/session.json`, so restart mnml and the panel comes back exactly as you left it.

## Hosted panes (v2)

![open lib.rs, open the panel, outline.show hosts in the column, lsp.diagnostics replaces it (last-opened wins), click × to evict the hosted pane while keeping the column open](../../../assets/tapes/right-panel-v2-hosting.gif)

Two commands route their pane into the panel when it's open:

- **`outline.show`** — the LSP Outline pane (symbols sidebar for the active file). Default chord `<leader>lo` (vim) or palette. Header reads ` OUTLINE`.
- **`lsp.diagnostics`** — the workspace-wide Problems list. Default chord `<leader>le` (vim) or palette. Header reads ` DIAGNOSTICS`.

When the panel is **closed**, these commands fall back to their pre-v2 behavior: Outline splits horizontally above the active editor; Diagnostics opens a vertical split below the focused leaf. When the panel is **open**, they push the pane into `app.panes` and store its id in `app.right_panel_pane_id` — the editor body keeps its full width, and the pane renders inside the panel's column instead.

Last-opened wins. If the Outline is hosted and you fire `lsp.diagnostics`, the diagnostics pane replaces it. The displaced pane stays in `app.panes` (it isn't dropped); firing the displaced command again rehosts it. There's no tab strip inside the panel — that's a v3 question.

### Empty state

With the panel open but no pane hosted, the body paints a faint hint:

```
 SIDE PANEL

  Nothing here yet.

  :outline.show
  :lsp.diagnostics

  Hide with Ctrl+Shift+B.
```

The hint is comment-colored on the panel's slightly-darker background. The two ex commands are both real — copy-and-paste them into the cmdline and the pane lands inside the panel.

### Header and close button

When a pane is hosted, the panel's header reads ` OUTLINE` or ` DIAGNOSTICS` (bold, dim foreground). The far-right cell of the header is a clickable `×` (or `x` under `[ui] ascii_icons = true`) — clicking it **evicts the hosted pane** (`right_panel_pane_id = None`) but **keeps the panel open** in the empty state. The pane object stays in `app.panes` — firing `outline.show` again immediately re-hosts it.

This is the eviction split mnml makes for the panel:

| Gesture | Panel | Hosted pane |
|---|---|---|
| Click the header's `×` | Stays open (empty state) | Evicted from the panel (still in `app.panes`) |
| `Ctrl+Shift+B` (toggle off) | Closes | Evicted from the panel |
| `:set norightpanel` | Closes | Evicted from the panel |
| `view.toggle_right_panel` from the palette | Toggles | Evicted on close |

Either close path nulls `right_panel_pane_id`. Re-opening the panel returns to the empty-state hint — your hosted pane isn't auto-restored, because the design assumes you'll re-fire `outline.show` or `lsp.diagnostics` for whatever you want next.

## Sizing

The panel takes a fixed cell width carved off the right of the workspace area **before** the rail's left split happens, so the rail and the panel size independently. Default width comes from `[ui] right_panel_width` in TOML (auto-default if unset).

### Drag-resize

The panel's left edge has a 2-row visible grip (`┃` / `|` in ASCII mode) centered vertically. The hit zone is 3 cells wide × 4 rows tall — bigger than the visible grip so trackpad users don't miss. Click the grip and drag horizontally to resize; release commits the width to `app.right_panel_width` and the next session save.

Width is clamped at render time: the panel can't shrink the editor's middle column below 20 cells, and the panel itself can't go below 8 cells.

### "Too narrow" hint

Below **16 cells** the panel's body would render an unusable squeeze of the Outline or Diagnostics — gutter plus a fragment of each line, no room for the symbol names. Instead of painting that, the panel shows:

```
 OUTLINE

  too narrow — drag edge wider
```

The header still renders so you can see what's hosted. The body's hint stays until you drag the grip back past 16 cells or close the panel.

## Layout interaction

The panel column is independent of the split tree. Splits inside the editor body don't propagate into the panel — a vertical split is still a vertical split, just within a slightly-narrower middle column. The hosted Outline / Diagnostics pane lives in `app.panes` like any other pane, but its layout cell is the panel column instead of a leaf in `app.layouts`.

Practically, this means:

- The bufferline (when visible) spans the editor's middle column only, not the panel.
- Per-leaf tab strips (when splits exist) stay within their splits — the panel column has its own one-line header instead.
- Focus moves into the panel the same way it moves into other panes — clicking inside it sets `app.active` to the hosted pane id; `Esc` from inside the pane returns focus to the previous editor leaf.
- The drag-resize grip is checked **before** the left rail's grip in the layout-rect dispatcher, so dragging never accidentally moves the wrong column.

## Configuration

Two TOML keys cover the panel's defaults:

```toml
# ~/.config/mnml/config.toml
[ui]
right_panel_visible = false   # open the panel on startup
right_panel_width   = 32      # initial width in cells
```

Both also round-trip through `<workspace>/.mnml/session.json` — the workspace's last-saved width and visibility override the config defaults on re-open. Delete the session file (`rm .mnml/session.json`) to fall back to the TOML defaults.

The hosted-pane id (`right_panel_pane_id`) is **not** persisted across mnml restarts — re-fire `outline.show` / `lsp.diagnostics` after open to repopulate.

## What's not in v2

The design-critic plan leaves a few items for v3 and beyond:

- **No tab strip.** Hosting a second pane evicts the first. A tab strip would let both Outline and Diagnostics live in the panel and switch with `gt` / `gT`.
- **No pluggable hosts.** Only `Pane::Outline` and `Pane::Diagnostics` route into the panel today. Other panes (chat, dock-widget-as-rail, search) are candidates for v3.
- **No vertical resize hint.** The "too narrow" warning fires for width, but not for very short panels — a 3-row panel still tries to render its pane and just looks squashed.

If you want any of these, open an issue — they're scoped, not unknowns.

## Source

- `src/app/mod.rs` — `right_panel_visible`, `right_panel_width`, `right_panel_pane_id`, `dragging_right_panel_edge`.
- `src/ui/mod.rs` — the layout split that carves the column (`right_panel_area`), the header / `×` / too-narrow / empty-state painters, the drag-grip indicator.
- `src/app/ex_commands.rs` — `:set rightpanel` / `:set rightpanel!` / `:set norightpanel`.
- `src/command.rs` — `view.toggle_right_panel` (`Ctrl+Shift+B`).
- `src/app/lsp.rs` — `open_outline_pane` (routes into the panel when `right_panel_visible`).
- `src/app/mod.rs::open_diagnostics_pane` — same routing for `lsp.diagnostics`.
- `src/app/session.rs` — visibility + width round-trip.

## Next

- [LSP](/manual/lsp/) — the symbols, outline, and diagnostics surfaces that the panel hosts
- [Activity bar](/manual/activity-bar/) — the chrome on the *opposite* edge (rail + activity strip)
- [Dock widgets](/manual/dock-widgets/) — the corner-pinned mini-panels above the editor body
- [Settings & configuration](/manual/settings/) — `[ui]` keys including `right_panel_visible` / `right_panel_width`
- [Chord chains](/manual/chord-chains/) — how `Ctrl+Shift+B` and the rest of the keymap resolve
