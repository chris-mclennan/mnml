# Wave 3 contract — `app` ⇄ `ui`

Two branches are built in parallel against this document. `ui` owns
every file under `src/ui/` (plus `src/ui/fuzzy.zig`); `app` owns
`src/app/`, `src/app.zig`, `src/tui/loop.zig`, `src/main.zig`
wiring, and command runners. Neither imports the other's *internals*:
`app` calls only the signatures below; `ui` never imports `App`,
`Buffer`, or `Editor` — it receives plain data views.

Shared, already on `main`: `src/core/ids.zig` (`PaneId`, `FocusId`),
`src/core/panel.zig` (`PanelId`, `ListSort`), `src/core/key.zig`
(`Key`, `Mouse`), `src/ui/{rect,canvas,text,border,clip,color}.zig`.

If a signature here turns out wrong in practice, the owner changes it
**and updates this file in the same commit**; the other side adapts at
merge. Do not silently diverge.

---

## `src/ui/theme.zig` (ui)

```zig
pub const Theme = struct {
    bg: Style, fg: Style, muted: Style, accent: Style, border: Style,
    gutter: Style, cursor_line: Style, selection: Style, match: Style, current_match: Style,
    statusline: Style, bufferline: Style, tab_active: Style, tab_inactive: Style, tab_dirty: Style,
    mode_normal: Style, mode_insert: Style, mode_visual: Style, mode_replace: Style, mode_edit: Style,
    panel_bg: Style, chip: Style, chip_active: Style, overlay_bg: Style, overlay_border: Style, overlay_title: Style,
    error_fg: Style, warn_fg: Style, info_fg: Style, fold: Style, whitespace: Style,
    pub const default: Theme = …;   // a dark theme with rgb colors; Canvas folds to 256 when needed
};
```

## `src/ui/hit.zig` (ui)

```zig
pub const ChipKind = enum { sort, refresh, new, view };
pub const HitTarget = union(enum) {
    pane: PaneId,
    divider: u32,
    tab: struct { leaf: u32, idx: u16 },
    row: struct { panel: PanelId, idx: u32 },
    kebab: struct { panel: PanelId, idx: u32 },
    chip: struct { panel: PanelId, kind: ChipKind },
    filter_input: PanelId,
    scrollbar: struct { owner: Owner, axis: enum { v, h } },   // Owner = union(enum){ pane: PaneId, panel: PanelId }
    button: u32,
    link: struct { url: []const u8 },
    menu_item: struct { menu: u32, idx: u16 },
    statusline_seg: u32,
    tree_node: u32,
    script_hit: struct { pane: PaneId, id: u32 },
    /// A visible editor cell; `line`/`col` are 0-based document coords.
    editor_cell: struct { pane: PaneId, line: u32, col: u32 },
    overlay_item: u32,
};
pub const HitMap = struct {
    pub const Entry = struct { rect: Rect, target: HitTarget };
    items: std.ArrayListUnmanaged(Entry) = .empty,
    pub fn reset(h: *HitMap) void;                                        // frame start; storage is the frame arena
    // changed (app): the frame arena is reset at the top of `App.render`, not the loop iteration,
    // so the map registered during a frame is still valid when the next mouse event is routed.
    pub fn add(h: *HitMap, arena: Allocator, r: Rect, t: HitTarget) Allocator.Error!void;
    pub fn at(h: *const HitMap, x: u16, y: u16) ?HitTarget;                // back-to-front: last painted wins
    pub fn writeRectsJson(h: *const HitMap, w: *std.Io.Writer) std.Io.Writer.Error!void; // [{"label","x","y","w","h"}]
};
```

## `src/ui/context.zig` (ui)

```zig
pub const Ui = struct {
    canvas: Canvas,
    hits: *HitMap,
    theme: *const Theme,
    arena: Allocator,            // frame arena — everything a draw allocates
    focus: FocusId,
    hover: ?struct { x: u16, y: u16 } = null,
    ascii: bool = false,
    nerd_font: bool = true,
};
```
`src/ui/ui.zig` stays the barrel/test root and re-exports all of the above.

## `src/ui/editor_view.zig` (ui)

A plain data view of a buffer — the app fills it from `Buffer`/`Editor` each frame.

```zig
pub const Span = struct { start: usize, end: usize, style: Style };          // byte range
pub const Range = struct { start: usize, end: usize };
pub const Fold = struct { first_line: u32, last_line: u32 };                  // 0-based, inclusive, collapsed
pub const Doc = struct {
    text: []const u8,
    cursor: usize,                  // byte
    anchor: ?usize,                 // selection tail
    extra_cursors: []const usize = &.{},
    folds: []const Fold = &.{},
    spans: []const Span = &.{},     // syntax
    matches: []const Range = &.{},  // find results
    current_match: ?usize = null,   // index into matches
    wrap: bool,
    tab_width: u8,
    line_numbers: bool = true,
    cursor_shape: enum { block, bar, underline } = .block,
    focused: bool,
    visual_block: bool = false,     // paint a rectangle from anchor→cursor instead of a byte range
};
pub const ViewState = struct { scroll_line: u32 = 0, scroll_col: u32 = 0 };   // persistent per pane
pub const Cursor = struct { x: u16, y: u16 };
/// Paints gutter + text, keeps the cursor visible (adjusting `view`),
/// registers `.editor_cell` hits per visible row, and returns the
/// cursor's screen position (null when off-screen).
pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *ViewState, doc: Doc) ?Cursor;
/// Folded ranges render as ONE row: the first line's text, then
/// " … N lines hidden" in `theme.fold` — the literal words "folded"
/// and "hidden" appear (the gate asserts both): `"⋯ folded · 3 lines hidden"`
/// (ascii: `"... folded - 3 lines hidden"`).
```

## `src/ui/statusline.zig` (ui)

```zig
pub const Info = struct {
    mode_label: ?[]const u8,        // "NORMAL"/"INSERT"/"REPLACE"/"VISUAL"/"V-LINE"/"V-BLOCK", or "EDIT" for the standard handler, null hides the chip
    mode_kind: enum { none, normal, insert, visual, replace, edit },
    file: ?[]const u8, dirty: bool,
    line: u32, col: u32, total_lines: u32,             // 1-based line/col
    input_style: []const u8,                            // "vim" | "standard"
    selection_chars: ?usize = null,                     // renders "Sel N" (the gate asserts "Sel ")
    pending: ?[]const u8 = null,                        // vim pending chord, e.g. `"a` or `2d`
    macro_recording: ?u8 = null,                        // "● rec @q"
    right: []const []const u8 = &.{},                   // extra right-aligned segments
};
/// Left: mode chip, file (+ `●` when dirty). Right: `" Ln {line}/{total} Col {col} "`
/// (exact format; the gate asserts "Ln 3"), then `right` segments.
pub fn draw(ui: Ui, area: Rect, info: Info) void;
```

## `src/ui/bufferline.zig` (ui)

```zig
pub const Tab = struct { id: PaneId, title: []const u8, dirty: bool, active: bool };
/// One row of tabs; registers `.tab{leaf=0, idx}` hits. Active tab uses
/// `theme.tab_active`; dirty tabs get a trailing `●`.
pub fn draw(ui: Ui, area: Rect, tabs: []const Tab) void;
```

## `src/ui/list_panel.zig` (ui) — per DESIGN D6

`ListPanel(Row)` with `State{scroll, cursor, filter: ArrayListUnmanaged(u8), filter_caret, filter_focused, visible, total}`
(`deinit(gpa)`, `filterText()`),
`Props{panel, label, subtitle, sort_chip: ?[]const u8, sort_widest, rows, paintRow, has_kebab, empty: EmptyState, show_filter = true, show_refresh = true}`,
`draw(st: *State, ui: Ui, area: Rect, p: Props) ?Caret`, plus `header.zig`,
`chip.zig` (the width ladder from the Rust `panel_chrome.rs:196-315`:
full label → icon-only → dropped), `scrollbar.zig`, `filter_input.zig`,
`empty_state.zig`, and `text_field.zig` (the editing core every input shares;
`Caret = struct { x: u16, y: u16 }`).

// changed: `draw` returns `?Caret` — the filter's caret cell when it has
// focus, so the app can place the terminal cursor (Rust kept this in
// `rects.*_caret`). Every text-bearing overlay below does the same.
// changed: `paintRow: *const fn (ui: Ui, r: Rect, row: Row, selected: bool) void`
// receives a `Ui` clipped to the row (`Ui.withClip`).
// added: `handleKey(st: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome`
// with `Outcome = union(enum) { ignored, consumed, filter_changed, activate: usize }`
// — `/` focuses the filter, j/k ↑↓ g/G home/end page ctrl+d/u move, enter
// activates, esc clears a stale filter. `visible`/`total` are set by `draw`
// (paging needs them), so `handleKey` takes no geometry.
// `sort_chip` is the sort's LABEL (`ListSort.label()`); the panel composes
// ` sort: <label> ` itself, padded to `sort_widest` (`ListSort.widest_label`).

## Overlays (ui) — components with `State`, `draw`, `handleKey`

All overlays are centered boxes on `theme.overlay_bg` with a
`theme.overlay_border` frame and a title in `theme.overlay_title`.
Text fields support: cursor, ←/→, home/end, backspace/delete,
ctrl+a/e/u/w, **paste** (a `paste(text)` method), and history where
noted. `handleKey` never sees `*App`; the app reads the result from
`State`.

```zig
// src/ui/prompt.zig — a single-line input.
pub const Prompt = struct {
    pub const State = struct { title: []const u8, buf: ArrayListUnmanaged(u8), caret: usize, placeholder: ?[]const u8 = null, history: ArrayListUnmanaged([]u8) = .empty, hist_idx: ?usize = null };
    pub const Outcome = enum { consumed, cancel, submit };
    pub fn init(gpa: Allocator, title: []const u8) State;  pub fn deinit(s: *State, gpa: Allocator) void;
    pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome;   // esc→cancel, enter→submit
    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void;
    pub fn draw(ui: Ui, area: Rect, s: *const State) ?Caret;  // title row + input row; hit `.overlay_item(0)` on the input
};
// changed: `draw` returns the caret cell (`text_field.Caret`) so the app can
// place the terminal cursor; `area` is the screen (the box centers itself).
// `Prompt` is the module (`ui.Prompt == ui.prompt`), so `Prompt.State` /
// `Prompt.init` / `Prompt.draw` read as written. `State` also carries
// `secret: bool = false` (bullets), `text()`, `setText(gpa, value)`,
// `remember(gpa)`; enter remembers the line before returning `.submit`.
// The goto-line prompt's title is exactly "Go to line" (the gate asserts it).

// src/ui/confirm.zig — the unsaved-changes / yes-no box.
pub const Confirm = struct {
    pub const Choice = struct { key: u8, label: []const u8 };   // e.g. {'s',"Save"},{'d',"Discard"},{'c',"Cancel"}
    pub const State = struct { title: []const u8, message: []const u8, choices: []const Choice, selected: usize = 0 };
    pub const Outcome = union(enum) { consumed, cancel, choose: usize };
    pub fn handleKey(s: *State, key: Key) Outcome;   // the choice's key letter, ←/→ + enter, esc→cancel
    pub fn draw(ui: Ui, area: Rect, s: *const State) void;   // registers `.overlay_item(i)` per choice
};
// The close prompt's title is exactly "Unsaved changes" (from the Rust UI).

// src/ui/which_key.zig — stateless hint popup.
pub const Entry = struct { key: []const u8, label: []const u8, is_group: bool = false };
pub fn draw(ui: Ui, area: Rect, title: []const u8, entries: []const Entry) void;   // e.g. title "Leader" / "Vim: g"
// A group entry paints as `+label` — pass `label = "split"`, `is_group = true`
// and the gate's "+split" appears. Entries are sorted by key inside `draw`.
// `area` is the screen; the box docks just above its last row.

// src/ui/find_bar.zig — the find/replace bar docked at the bottom of a pane.
pub const FindBar = struct {
    pub const State = struct { query: ArrayListUnmanaged(u8), caret: usize, replace: ArrayListUnmanaged(u8), replace_caret: usize,
                               focus: enum { query, replace } = .query, regex: bool = false, match_case: bool = false, in_selection: bool = false, show_replace: bool = false };
    pub const Outcome = enum { consumed, cancel, next, prev, submit, toggle_regex, toggle_case, focus_toggle, replace_one, replace_all, changed };
    pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome;  // enter→submit (jumps to next), shift+enter→prev, esc→cancel, ctrl+r regex, ctrl+c case, tab→focus_toggle; typing→changed
    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void;
    pub const Info = struct { current: ?usize, total: usize };               // 0-based current
    /// Two rows max. Row 1: `"Find"` (or "Find (in selection)") label, the query, then
    /// `"match {current+1}/{total}"` or `"no matches"` — exact literals, the gate asserts them.
    pub fn draw(ui: Ui, area: Rect, s: *const State, info: Info) ?Caret;
};
// changed: `draw` returns the focused field's caret; `area` is the bar's own
// rect (1 row, or 2 when `show_replace`). Hits are `.overlay_item(n)` with
// `hit_query = 0`, `hit_replace = 1`, `hit_regex = 2`, `hit_case = 3`.
// ctrl+enter → replace_all (when `show_replace`), ↑/↓ and ctrl+p/n and F3 →
// prev/next. `State` gains `deinit(gpa)`, `setQuery(gpa, text)`,
// `queryText()`, `replaceText()`. `FindBar` is the module.

// src/ui/picker.zig — fuzzy list overlay (buffers, files, commands).
pub const Picker = struct {
    pub const Item = struct { label: []const u8, detail: ?[]const u8 = null, hint: ?[]const u8 = null };
    pub const State = struct { title: []const u8, query: ArrayListUnmanaged(u8), caret: usize, cursor: usize = 0, scroll: usize = 0 };
    pub const Outcome = union(enum) { consumed, cancel, changed, accept: usize };   // accept = index into the ITEMS SLICE PASSED TO DRAW (filtered order)
    pub fn handleKey(s: *State, gpa: Allocator, key: Key, count: usize) Allocator.Error!Outcome;  // ↑↓ / ctrl+p ctrl+n / ctrl+j ctrl+k move, enter accept, esc cancel
    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void;
    pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item) ?Caret;   // registers `.overlay_item(i)` per visible row
    /// Indices into `items` that match `query`, best first; then the slice `draw` takes.
    pub fn rank(arena: Allocator, query: []const u8, items: []const Item) Allocator.Error![]const usize;
    pub fn gather(arena: Allocator, items: []const Item, order: []const usize) Allocator.Error![]const Item;
};
// changed: `draw` returns the query caret; `handleKey`'s last parameter is
// the LENGTH OF THE SLICE last passed to `draw` (paging reads `State.rows`,
// which `draw` sets). `State` gains `total: ?usize = null` (paints
// ` N of M `), `rows`, `deinit(gpa)`, `queryText()`. The scrollbar registers
// `.scrollbar{ .owner = .{ .pane = Picker.scrollbar_owner }, .axis = .v }`.
// `Picker` is the module.
// src/ui/fuzzy.zig — `pub fn score(query: []const u8, text: []const u8) ?u32` (higher is better; null = no match), case-insensitive, subsequence with bonuses for word starts/consecutive runs.
// Also `match(arena, query, text) !?Match{score, positions}` for highlighting. An empty query scores `fuzzy.base`.
```

## Toasts (ui)
`src/ui/toast.zig`: `pub fn draw(ui: Ui, area: Rect, toasts: []const Toast) void` with
`Toast{ text: []const u8, level: enum{info,warn,err} }`, stacked bottom-right.
`area` is the region ABOVE the statusline (the stack keeps one spacer row);
`toasts[0]` is the newest and lands lowest. Toast `i` registers
`.button(toast.button_base + i)` — click to dismiss. At most five paint; past
that the oldest slot reads `+K more…`.

## Also on the `ui` side
- `src/ui/text_field.zig` — the editing core (`handleKey(buf, caret, gpa, key) !Edit`,
  `insert` for paste, `draw`), and `Caret`. `ui.Caret` re-exports it.
- `src/ui/overlay.zig` — `place` / `frame` / `box` / `hint`: the shared popup frame.
- `Ui.withClip(r)` — the same context with the canvas clipped to `r`.
- `list_panel.scrollWindow(&scroll, cursor, total, visible) Window{first, visible, needs_bar}` —
  the Rust `list_scroll_window`, also used by the picker.

---

## App-side obligations (app)

- Layout per frame (row 0 palette/bufferline as in the Rust `breadcrumb=false` layout: **row 0 bufferline, rows 1..H-2 panes, row H-1 statusline** — the `.test` mouse coordinates assume this). `App.render()` builds `Ui` on the frame arena, resets `HitMap`, draws panes → overlays → toasts, sets the terminal cursor from `editor_view.draw`'s return.
  - changed (app): the body is **tree (30 cols) | divider (1) | panes**, as Rust's default layout (`tree_width = 30`); `wrap.test` measures the editor width against it. The tree is `src/app/tree.zig` (state + its own draw glue, `.tree_node` hits); `view.toggle_tree` hides it and the panes take the whole body.
  - changed (app): `Pane.editor` holds an `EditorPane` (`Buffer` + `ViewState` + find state + wrap override + syntax cache + block anchor), not a bare `Buffer` — the per-pane view state the contract lists as "persistent per pane" has to live somewhere.
- Mouse: `switch (app.hits.at(x, y))` is the one routing point.
- Implements the `e2e.Driver` vtable (`src/e2e/driver.zig`) and sets `main.app_factory`.
- Fills `ipc.Status` (`src/ipc/screen.zig`).
- Chrome strings the gate asserts and the app supplies: toast `"mark 'a set"`, `"→ 'a 3:1"`, `"no mark 'z"`; the find bar's `Info`; `"Go to line"` prompt title; `"Unsaved changes"` confirm title with choices Save/Discard/Cancel; which-key entries from the keymap prefix.
