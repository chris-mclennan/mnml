---
title: Tabs, splits & tab pages
description: Per-leaf tab strips with overflow chevrons and the `+N hidden` chip, the split tree and its `Ctrl+W` chords, drag-to-split, zoom, and vim-style tab pages.
---

mnml's layout is a **binary split tree**. Every leaf of that tree holds a list of open panes and shows one of them; each leaf paints its own tab strip across the top row of its area. There is no single global tab bar — the strip you see belongs to the pane under it, which is why splitting the window gives you two independent sets of tabs rather than one shared row that no longer describes either side.

Panes are `Editor` / `Pty` / `Request` / `Diff` / `Browser` / `Outline` / anything else mnml opens; the layout doesn't care which. That means everything on this page applies uniformly — you can split a terminal against a diff, drag an HTTP request into the bottom half, and zoom a browser pane, with the same gestures.

## The per-leaf tab strip

```
 󰈚 main.rs ×   󰈙 README.md   $ claude ×      +    ‹  ›     󰆍  ⊟  ⊞  ⛶
 └─ tab chips ────────────────┘   └ new    └ scroll   └ leaf actions
```

Every leaf strip carries, left to right: its tab chips, a `+` chip, the overflow chevron pair, an optional `+N hidden` chip, an optional markdown mode chip, and the leaf-action cluster.

### Tab chips

A chip renders an icon, the pane name, and — when active or hovered — a close `×`. Editors add a dirty marker and a pin marker; panes with diagnostics get a small `✗3` / `⚠2` badge between the name and the close button; Request panes swap the icon slot for a solid HTTP-verb badge (`GET`, `POST`) and render the rest of the label normally.

Long names clip with `…`. Hovering an *inactive* tab paints its `×` too, so closing a background tab is one click rather than click-to-focus-then-close.

One subtlety that was a real bug: on a chip too narrow for its own spans, the close badge is clipped away by the renderer — and the click rect goes with it. Previously the rect was registered whenever the chip was at least two cells wide, so on a clipped tab those two cells were the last characters of the *filename*, and clicking there closed the tab instead of focusing it.

| Gesture | Action |
|---|---|
| Click a chip | Focus that pane in this leaf |
| Click the `×` | Close it |
| Middle-click | Close it |
| Right-click | Tab context menu (below) |
| Drag onto another chip | Reorder within the strip |
| Drag onto another strip | Move the pane into that leaf, at the cursor's insert position |
| Drag onto a pane body | Split or replace — see [drag-to-split](#drag-to-split) |

### The tab context menu

Right-click a tab chip (or press `Shift+F10` with the pane focused):

- **Save** — only for a dirty editor with a path, and first in the list because it's the most common, lowest-cost action.
- **Pin tab** / **Unpin tab** — editors only. Pinned tabs stick to the front of the strip.
- **Close** / **Close others** / **Close all**.
- **Preview markdown**, **Copy relative path**, **Copy absolute path**, **Reveal in Finder/Explorer/Files** — for editors with a path. The reveal label follows the OS.
- **View source (as text)** / **Copy path** / **Reveal** — for Request panes with a saved `.http` / `.curl` / `.rest` source.
- **Split right** / **Split down** / **Split left** / **Split up** — the keyboard route to the drag-to-split gesture. The tab moves into a new half of its current leaf.
- **Move to bottom panel** — only for pane kinds the bottom panel can host (Outline, Diagnostics, Integration detail, Claude/Codex usage, Tests, Grep). Hidden for everything else rather than leading you to a dead end.
- **Rename…**, plus terminal-native **Restart** / **Clear** / **Interrupt** for Pty tabs.

### Overflow: chevrons, `+`, and `+N hidden`

When a leaf holds more tabs than fit, the strip scrolls horizontally and a chevron pair sits at the right end of the tab region: `‹` (`U+F0141`) and `›` (`U+F0142`), ASCII `<` and `>`.

Each chevron is *pushed as a click target only when it has somewhere to go* — `‹` needs tabs scrolled off the left, `›` needs tabs past the right edge — so a live chevron is never a dead click. The inert one is still painted, dimmed, because keeping both slots occupied stops the strip reflowing by two cells every time you scroll to an end.

The reservation order matters and is the whole fix behind the feature: the chevrons and the `+` chip carve out their cells **before** the tabs are laid out. Tabs fill right up to the boundary, so anything sized *after* them is the first thing dropped exactly when overflow happens — which is how the affordance whose job is to announce overflow used to disappear the moment there was overflow to announce.

The active tab auto-reveals when it *changes* — not on every paint, which would yank the strip back the instant you scrolled away to look at something else.

A **`+N hidden`** chip appears when tabs are missing from the strip, for either of two reasons:

- The strip clipped them (overflow).
- The HTTP activity section filtered them out. In that section a leaf's strip shows only Request panes; the rest are hidden, not closed, and switching back to Explorer brings them straight back.

Both paths feed the same counter, so a leaf that's filtered *and* overflowing reports the total. **Click the chip to open the buffer picker**, which lists every pane regardless of what fit — the chip exists to say "your tabs are still here", so it has to be able to show them.

If a strip ever looks stranded — one chip visible, `+N hidden`, and a wall of empty cells — that was a stale scroll offset outliving the strip it was scrolled on (the left panel widened, a tab closed, or a section switch rebuilt the leaf). The offset is now clamped before painting to the smallest one whose tail still fills the strip, measured with the same function the paint loop uses, and written back so the chevrons agree. It self-heals regardless of which cause stranded it.

### The `+` chip

A `+` sits immediately after the last tab in every strip. Clicking it focuses that leaf and opens a **Create…** menu:

| Row | Command |
|---|---|
| *Reopen last closed* | `buffer.reopen` — only present when there's something to reopen |
| New scratch buffer | `scratch.new` |
| Open file… | `picker.files` |
| Recent files | `picker.recent` |
| From clipboard | `scratch.from_clipboard` |
| New HTTP request | `http.new` |
| New shell | `term.shell` |
| New browser tab | `browser.open` |
| New Claude Code session | `ai.claude_code_new` |
| New Codex session | `ai.codex_new` |
| New tab page | `tab.new` |

The reopen row is prepended (so it's under the cursor when the menu opens) and only when the closed-buffer list is non-empty — an always-present row that usually toasts "nothing to reopen" just teaches people to skip it.

All three `+` chips share one builder: the per-leaf strip's, the empty-state one on the top row, and the top-right cluster's. That matters because the third used to fire `tab.new` directly with no menu — and with every pane closed it's the *only* `+` on screen, so the one state where you most need "reopen what I just closed" was the state with no menu offering it.

### The leaf-action cluster

Pinned to the right end of every strip:

| Button | Action |
|---|---|
| Claude / Codex chip | Spawn that AI session in this leaf (only for enabled integrations) |
| `󰆍` terminal | Focus this leaf and open a shell |
| `⊟` side-by-side | `view.split_right` on this leaf |
| `⊞` stacked | `view.split_down` on this leaf |
| `⛶` maximize | `view.toggle_zoom` — glyph flips to an inward arrow and turns cyan while zoomed |

The cluster degrades gracefully as the strip narrows: the AI chips are dropped first (one at a time), then the terminal and split buttons hold on. In full-screen mode the maximize button repurposes as "exit full screen" — the tab strip is the only chrome left, so that's where the click target belongs.

## Splits

### Creating and closing

| Chord | Command | Action |
|---|---|---|
| `Ctrl+\` | `view.split_right` | Split side by side |
| `Ctrl+Shift+\` | `view.split_down` | Split stacked |
| `Ctrl+W v` | `view.split_right` | vim vertical split |
| `Ctrl+W s` | `view.split_down` | vim horizontal split |
| `Ctrl+W n` | `view.split_new_scratch` | Fresh empty buffer in a split below |
| `Ctrl+W f` | `view.split_open_file_under_cursor` | Split + open the file under the cursor |
| `Ctrl+W d` | `view.split_goto_definition` | Split + go to definition |
| `Ctrl+W q` / `Ctrl+W c` | `view.close_split` | Close the active split / buffer |
| `Ctrl+W o` / `Ctrl+K W` | `view.close_others` | Close everything but the active pane |

`Ctrl+W` is vim's window prefix and is only a prefix in vim mode — standard mode keeps `Ctrl+W` bound to `buffer.close`. Everything reachable through the prefix is also a registered command, so standard-mode users can bind or palette them.

### Focus, movement and sizing

| Chord | Command |
|---|---|
| `Ctrl+W h` / `j` / `k` / `l` (or arrows) | `view.focus_left` / `_down` / `_up` / `_right` |
| `Ctrl+W w` | `view.focus_next_split` |
| `Ctrl+W p` | `buffer.last` — the previously-active pane |
| `Ctrl+W H` / `J` / `K` / `L` | `view.move_split_left` / `_down` / `_up` / `_right` — move to the far edge of the parent |
| `Ctrl+W r` / `x` / `R` | `view.rotate_splits` — swap the active leaf with its sibling |
| `Ctrl+W =` | `view.equalize_splits` |
| `Ctrl+W +` / `-` | `view.split_grow_height` / `view.split_shrink_height` |
| `Ctrl+W >` / `<` | `view.split_grow_width` / `view.split_shrink_width` |
| `Ctrl+W _` / `\|` | `view.maximize_height` / `view.maximize_width` |
| `Ctrl+W T` | `view.move_to_new_tab` — move this leaf out into a new tab page |

Dividers are also draggable with the mouse, and clicking any pane body focuses it.

### Maximize vs. full screen

Three different things, easy to conflate:

| | What it does | How to get it |
|---|---|---|
| **`view.maximize_height` / `_width`** | Pushes the active split's *ratio* in one axis. Neighbours shrink but stay on screen. | `Ctrl+W _` / `Ctrl+W \|` |
| **`view.toggle_zoom`** | Renders **only** this leaf, full-frame. Chrome stays. Toggle back to restore the exact tree. | `<leader>zz`, or the `⛶` chip |
| **`view.fullscreen`** | Hides the tree, bufferline and statusline. Not about splits at all. | `Ctrl+K Z` (also `F11` when no debug session is running) |

Zoom is a render-layer flip, not a layout mutation — nothing is closed, moved or resized, so toggling it off returns the tree byte-for-byte. Full screen was called "zen mode" until it was renamed for discoverability: VS Code users search "full screen" and reach for `F11`. It is deliberately **not** bound to `Ctrl+Shift+Z`, which is the universal Redo chord — three independent testing rounds flagged that binding as their top muscle-memory trap.

### Splits ↔ tabs

Two commands convert between the two ways of holding several panes:

```vim
:layout.merge_to_tabs      " collapse every split into one leaf's tab strip
:layout.spread_to_splits   " explode the active leaf's tabs into a grid of splits
```

Handy when a layout you built for one task is wrong for the next one, and faster than closing and re-opening panes.

## Drag-to-split

Drag a tab chip out of its strip and onto a **pane body**, and the drop zone under the cursor decides what happens. mnml paints a translucent overlay on the exact landing rect while you drag, so the target is unambiguous before you release.

| Zone | Result |
|---|---|
| **Left / Right / Top / Bottom edge** | Split the target pane in that direction; the dragged pane lands in the new half |
| **Center** | Move the dragged pane into the target's slot. The displaced pane isn't destroyed — it stays open as a background tab |

The middle third on each axis is Center; outside that, the nearest edge wins, with distances normalized so panes of different proportions compare fairly.

Both outcomes are pure layout mutations — the pane list is never touched, so no buffer is closed and no pane id shifts. Dropping a tab onto *its own* pane body is a no-op in the Center zone and a split-off-from-my-own-leaf in the edge zones.

Two related gestures use the same machinery:

- **Drag a file from the tree onto a pane body.** Opens the file (reusing an already-open editor pane if there is one) and places it by the same zone rules. Released off any pane, it behaves like a normal open.
- **Drag a tab onto another leaf's strip.** Chrome / VS Code tab-bar drop — the insert index comes from the cursor's x position relative to the chips on that strip.

## Tab pages

Tab pages (mnml's "desktops") are vim's `:tab*` model: each page owns an **independent split tree**, so switching pages swaps the entire layout rather than one buffer. They're persisted across launches in `session.json`.

| Command | Chord | Action |
|---|---|---|
| `tab.new` | `Ctrl+K n` | New tab page |
| `tab.next` / `tab.prev` | `gt` / `gT` (vim) | Cycle pages. `[N]gt` jumps to page N |
| `tab.goto_1` … | `Alt+1` … | Jump to page N |
| `tab.first` / `tab.last` | — | First / last page |
| `tab.close` / `tab.only` | — | Close this page / close all others |
| `tab.move_left` / `tab.move_right` | — | Reorder |
| `tab.list` / `tab.picker` | — | List pages, or fuzzy-pick one |
| `tab.reopen` | — | Reopen the last closed page |
| `view.move_to_new_tab` | `Ctrl+W T` | Move the active leaf out into a new page |

`Ctrl+K n` sits in the mnml-specific leader-chord family on purpose, so it doesn't collide with VS Code's `Ctrl+T` (workspace symbols) or `Ctrl+N` (new file).

Numbered page chips live in the top bar's right-hand cluster behind a `TABS` label, each with its own close `×`, and they can be dragged to reorder. At narrow widths the cluster falls back to a compact form that drops the `TABS` label and the page chips first, so the most-clicked chrome (theme toggle, `+`, window close) survives longest; narrower still and the whole cluster is dropped, along with its click rects.

## Buffers across leaves

Panes are global; leaves decide which ones they *show*. So a buffer can be open in two leaves at once, and closing a tab in one strip doesn't remove it from another.

| Command | Chord | Notes |
|---|---|---|
| `buffer.next` | `Ctrl+PageDown`, `Ctrl+Alt+→` | Positional cycling forward |
| `buffer.prev` | `Ctrl+PageUp`, `Ctrl+Alt+←`, `Ctrl+Shift+Tab` | Positional cycling back |
| `:bn` / `:bp` | — | Same, from the ex-cmdline |
| `buffer.last` | `Ctrl+Tab` | The previously-active buffer (vim's alternate file, `Ctrl+^`) |
| `buffer.reopen` | `Ctrl+Shift+T` | Re-open the most recently closed buffer |
| `buffer.pin_toggle` | — | Pin the active tab to the front of the strip |
| `buffer.clear_mru` | — | Clear the nav back/forward history |

**Cycling skips Pty and GitGraph panes.** A vim user hitting `:bn` shouldn't get trapped walking through terminal sessions or a commit graph, which have no file semantics. If *every* pane is a Pty, the cycle no-ops rather than misleadingly "moving" to a terminal you just came from.

## Next

- [Editing](/manual/editing/) — the two input modes, and what `Ctrl+W` means in each
- [Right side panel](/manual/right-panel/) — the fixed-width column that hosts Outline and Diagnostics instead of splitting the body
- [Activity panels](/manual/activity-panels/) — the left column's panels, and the rows that open into these tabs
- [AI panes](/manual/ai-panes/) — the Claude / Codex sessions the strip's AI chips spawn
- [Dock widgets](/manual/dock-widgets/) — the middle tier, for things you want beside a buffer rather than instead of it
