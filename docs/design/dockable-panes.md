# Dockable panes — design + phased roadmap

**Status:** design (2026-08-07). Phase 1 (bottom panel) queued;
Phase 2 (corner docking on Layout) is the full feature.

## Motivation

Today mnml has three UI surfaces where content can live:

- **Layout tree** (`src/layout.rs::Layout`) — Empty | Leaf | Split.
  Fills the central editor area. Every "real" pane
  (`Pane::Editor`, `Pane::Pty`, `Pane::Coverage`, `Pane::Request`,
  `Pane::AiPanel`, …) is hosted in a Leaf.
- **Right panel** (`App::right_panel_panes`) — a docked column on
  the right edge. Hosts arbitrary panes; can show Outline /
  Diagnostics / AI / Grep / Test / anything routed to it. Drag-
  resizable edge. Session-persisted width + visibility.
- **Left activity bar** (`src/ui/tree_view.rs` etc.) — the
  narrow sidebar with sections (files, git, integrations, agents,
  http, notes, todos, sessions). Not a pane host; each section is
  hand-coded.
- **Dock widgets** (`src/dock.rs::DockWidget`) — small corner
  overlays with `Text` or `LogTail` content. Not a pane host.

**Gap:** there's no general "dock any pane to a screen edge or
corner" surface. User asks that pull a viewer up in a fixed spot
(e.g. coverage detail belongs bottom-right; a log tail belongs
bottom; a mini terminal belongs bottom-left) currently have to
either (a) live in a split, which resizes the editor and disrupts
the code area, or (b) shoehorn into a `DockContent` variant that
only supports flat text.

## Terminology (for anyone reading)

- **Buffer** — the file/content behind the scenes.
  `Pane::Editor(Buffer)` holds one.
- **Pane** — a viewport type (`Editor`, `Pty`, `Coverage`,
  `Request`, `AiPanel`, …). One "thing you can look at".
- **Leaf** — the `Layout::Leaf` node that hosts one visible pane
  and (optionally) background tabs on the same leaf.
- **Split** — the layout tree that divides the central area
  (`Layout::Split` with `dir = Horizontal | Vertical`).
- **Dock surface** — a fixed region carved off an edge/corner
  that hosts a pane outside the split tree.

## Phase 1 — Bottom panel (mirrors right_panel)

Smallest useful slice. Reuses the exact same pattern
`right_panel_panes` uses today; adds a bottom sibling.

**State (on `App`):**

```rust
pub bottom_panel_panes: Vec<PaneId>,       // mirrors right_panel_panes
pub bottom_panel_active_idx: usize,
pub bottom_panel_visible: bool,
pub bottom_panel_height: u16,              // default 12, drag to resize
```

**Persistence** — `session.json` gets three new keys mirroring the
right-panel ones: `bottom_panel_visible`, `bottom_panel_height`,
`bottom_panel_tabs`, `bottom_panel_active_idx`.

**Rendering** — in `ui::draw`, after the left activity bar carves
its column and the right panel carves its column, the bottom
panel carves `bottom_panel_height` rows from the bottom of the
remaining area (above the statusline). The split tree renders in
the rest.

**Palette commands:**
- `view.toggle_bottom_panel` — show / hide
- `view.dock_to_bottom_panel` — move focused pane into bottom
- `view.close_bottom_pane` — pop the active bottom tab (parallels
  right-panel semantics)

**Right-click extension** on any pane tab → new "Dock to →"
submenu with entries: *Right panel · Bottom panel*. Selecting one
moves the pane into that surface (removes from split leaf, adds
to `<x>_panel_panes`).

**Coverage use case:**
`coverage.open` currently opens `Pane::Coverage` in the focused
leaf. Change to: if `bottom_panel_visible`, route into bottom
panel; else fall back to the leaf. Add a `[coverage]
default_dock = "bottom" | "leaf"` config knob.

**Effort:** ~2-3 hours. All patterns already exist (right_panel),
mostly copy-adapt.

## Phase 2 — Corner docking on `Layout`

The full generalization. Any pane can be docked to any of the
four corners with a chosen size, above/below other splits.

**Layout enum addition:**

```rust
pub enum Layout {
    Empty,
    Leaf { active: PaneId, tabs: Vec<PaneId> },
    Split { dir: SplitDir, ratio: u16, first: Box<Layout>, second: Box<Layout> },
    Docked {                                                    // NEW
        corner: DockCorner,   // reuse src/dock.rs's enum
        w_cells: u16,         // fixed cell width
        h_cells: u16,         // fixed cell height
        pane: Box<Layout>,    // usually a Leaf, could nest for tabs
        inner: Box<Layout>,   // the rest of the tree
    },
}
```

`Docked` is asymmetric: the docked leaf is drawn on top / in the
corner rect, the inner tree fills the rest. Multiple `Docked`
wrappers nest — each layer peels one dock off its assigned corner.

**Layout method updates** — every method that walks the tree
grows a Docked arm. Count from `src/layout.rs`:
- `leaves`, `all_panes`, `leaf_containing` (+ mut variant)
- `focused_leaf_of`, `first_leaf_id`, `depth`, `pane_at_position`
- `split_leaf_with`, `close_pane`, `swap_pane_in_leaf`,
  `move_pane_between_leaves`
- ~10 more `collect_*` helpers

Each is 2-4 line additions (delegate to `pane` for the docked
rect, delegate to `inner` for everything else). Total: ~120 lines
of layout tree changes.

**Rendering** — in `render_layout`:
```rust
Layout::Docked { corner, w_cells, h_cells, pane, inner } => {
    let (dock_rect, inner_rect) = split_for_dock(area, *corner, *w_cells, *h_cells);
    let inner_cursor = render_layout(frame, app, inner, inner_rect, path);
    let dock_cursor = render_layout(frame, app, pane, dock_rect, path);
    dock_cursor.or(inner_cursor)  // whichever has the focused pane
}
```

`split_for_dock` carves a `Rect` in the specified corner and
returns the two halves. Careful: docked rect is always ON TOP —
we render inner first so any overlap on the corner gets covered.

**Drag-to-resize** — `App::rects.dock_edges: Vec<(Rect, DockCorner)>`
records the draggable edges of each docked pane. Mouse-drag
adjusts `w_cells` / `h_cells` on the matching `Layout::Docked`
node.

**Multiple docks per corner** — v1: one dock per corner (four
max). v2: stacking, same rules as `DockWidget`.

**Palette commands + right-click:**
- `view.dock_active_bottom_right / bottom_left / top_right / top_left`
- `view.undock_active`
- `view.dock_all_to_bottom` (bulk move a group)
- Right-click tab → "Dock to →" submenu with the six targets
  (four corners + right panel + bottom panel).

**Session persistence** — `Layout` already serializes (via serde
on the tree elsewhere); adding the variant is additive. Old
sessions without `Docked` nodes deserialize fine.

**Focus + tab semantics** — a docked pane still counts as a
"focused leaf" for keyboard input. Ctrl+W arrow-keys cycle
through leaves including docked ones. Closing the last tab in a
docked pane closes the whole dock (returns to plain layout).

**Edge cases to nail down:**
- What happens to a dock when the terminal shrinks below the dock
  size? Clamp `w_cells` / `h_cells` to `min(configured, area/3)`.
- Can you split a docked leaf? Yes — the `pane` field is a
  `Box<Layout>`, so nested splits inside a dock are legal.
  Renders like a mini-workspace in the corner.
- Can you dock a pane that's mid-drag from the bufferline? No.
  Drop is only valid on split targets in v1; corner dock has to
  come from the palette / context menu.

**Effort:** ~1-1.5 days, mostly `layout.rs` + `render_layout` +
right-click menu wiring. Tests: extend the existing 30+ layout
tests with Docked variants.

## Phase 3 — Polish

- Per-pane preferred dock (e.g., Coverage prefers bottom-right by
  default; user can override).
- Layout-preset TOML (task #878 — declarative window setup): "on
  startup, dock a Pty to bottom, an AI panel to right, open the
  editor in the center".
- Widget-inline mode: a dock that stacks a `DockWidget` (from
  `src/dock.rs`) instead of a full pane, for lightweight info
  cards that don't need a whole `Pane`.

## Recommended path

Ship Phase 1 (bottom panel) as a standalone commit — deliverable,
useful on its own, low risk. Land Phase 2 in a follow-up branch
with adequate test coverage since the layout tree touches
everything. Phase 3 is opportunistic.
