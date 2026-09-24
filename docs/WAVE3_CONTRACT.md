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
    // changed (welcome): `welcome: WelcomeRow` — `struct { kind: enum { recent, shortcut }, idx: u16 }`,
    // the welcome pane's rows (`ui/welcome.zig`); label `welcome:recent:0`. `dispatch.mouse`
    // opens the `idx`-th recent file (newest first) or runs the `idx`-th shortcut shown.
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

## `src/ui/welcome.zig` (ui)

```zig
// changed (welcome): new. The editor area when no pane is open — the Rust `welcome.rs` look:
// the figlet logo, `workspace · <name>`, `on <branch>`, Recent Files, Shortcuts, `mnml <version>`,
// every row centred on its own width, the stack centred on the pane, Rust's height ladder
// (nothing under 6 rows, the word for the logo under 19, recent files from 21, at most 8).
pub const Shortcut = struct { chord: []const u8, label: []const u8 };      // chord in display spelling: `^P`, `SPC`
pub const Props = struct {
    workspace: []const u8, branch: ?[]const u8 = null, changed: u32 = 0,
    recent: []const []const u8 = &.{},                                       // workspace-relative, newest first
    shortcuts: []const Shortcut = &.{}, version: []const u8,
};
pub fn draw(ui: Ui, area: Rect, p: Props) void;   // registers `.welcome` hits on recent + shortcut rows
```
The app side (`render.zig`, the `// ── welcome ──` block) builds the props: `welcomeShortcuts(app, arena)`
resolves each row's chord from `command.spec(id).keys` under the active profile (shared before own,
a modified chord before a bare key, a single chord before a sequence; an unbound row is dropped),
`welcomeRecent` / `welcomeRecentPath` map the recent list newest-first, and the block calls
`git_app.requireRepo` once so the branch row has a repo to name.

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
// changed: `Doc.scrollbar: bool = false` paints a one-cell vertical bar in the
// pane's last column (`.scrollbar{ .pane, .v }`, `scrollbar_w = 1`) when the
// text outgrows the rows; `ViewState.pin: ?usize` + `pinAt(cursor)` let the app
// scroll the viewport away from the cursor (a wheel notch in standard mode) —
// the view is not pulled back while the cursor stays at the pinned byte.
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
// changed: the mode chip, the file name and the position chip register
// `.statusline_seg` hits — `seg_mode = 0`, `seg_file = 1`, `seg_position = 2`
// — so a click on the mode chip toggles the keymap (`mouse_statusline_mode`).
```

## `src/ui/bufferline.zig` (ui)

```zig
pub const Tab = struct { id: PaneId, title: []const u8, dirty: bool, active: bool };
/// One row of tabs; registers `.tab{leaf, idx}` hits. Active tab uses
/// `theme.tab_active`; dirty tabs get a trailing `●`.
// changed: the strip is per leaf (a tab drags between leaves), so `draw`
// takes `Opts{ leaf: u32 = 0, new_tab: ?u32 = null }` — the leaf the hits
// carry, and the `.button` id of a ` + ` painted after the last tab.
// `slots(ui, area, tabs, out)` reports each painted tab's `x`/`w` without
// painting, for the drop router.
pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) void;
pub fn slots(ui: Ui, area: Rect, tabs: []const Tab, out: []Slot) []Slot;
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
// changed (2026-09-07, lsp-fixture): the box is Rust's `toast_stack` shape —
// a square `┌ … × ┐` frame with ` × ` set into the top edge, ONE text row
// clipped at 60 chars with `…` (chars, not cells, as Rust counts; a newline
// in a server's text costs a char and paints nothing), width = text + 4
// capped at 64 and the area less 2, no spacer row: the newest box sits on
// the statusline. `App.toastLevel` coalesces an identical non-persistent
// text still on screen (`Toast.repeats`, expiry refreshed) instead of
// stacking a twin — rust-analyzer says `Failed to discover workspace` twice.

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
  - changed (app): the frame is Rust mnml's, which the `.test` mouse coordinates assume: **row 0 palette bar (screens ≥ 80 wide), a tab strip on the first row of every leaf, statusline on row H-2, the `:` line on row H-1** (`render.frameRects`). The palette bar registers `.button` ids from `render.Button`; each strip's ` + ` is `Button.newTab(leaf)`.
  - changed (app): `Pane` gained `.cheatsheet` (`src/app/cheatsheet.zig`) and `.list` (`ListPane`: the `q:` history and the quickfix); their rows register `.script_hit{ pane, id }`.
  - changed (app): `Pane.editor` holds an `EditorPane` (`Buffer` + `ViewState` + find state + wrap override + syntax cache + block anchor), not a bare `Buffer` — the per-pane view state the contract lists as "persistent per pane" has to live somewhere.
- Mouse: `switch (app.hits.at(x, y))` is the one routing point (`dispatch.mouse`). A press may open a gesture in `App.drag` (divider resize, tab reorder / drag-to-split, tree-file drag, text selection by click count, scrollbar thumb) that the drag events feed and the release completes. Wheel events are folded per tick by `src/app/scroll.zig` (`App.wheel`) and scroll the pane under the pointer. A mouse event re-renders a dirty frame before it routes, so the previous frame's rects never take a click after a layout change.
- Implements the `e2e.Driver` vtable (`src/e2e/driver.zig`) and sets `main.app_factory`.
- Fills `ipc.Status` (`src/ipc/screen.zig`).
- Chrome strings the gate asserts and the app supplies: toast `"mark 'a set"`, `"→ 'a 3:1"`, `"no mark 'z"`; the find bar's `Info`; `"Go to line"` prompt title; `"Unsaved changes"` confirm title with choices Save/Discard/Cancel; which-key entries from the keymap prefix.

---

## Language layer (Phase 2) — `// changed:` notes (2026-09-04)

- `// changed (ui):` `Theme` gains ten syntax slots — `syn_comment, syn_default,
  syn_variable, syn_constant, syn_type, syn_string, syn_special, syn_function,
  syn_keyword, syn_punctuation` (base16 03/05/08/09/0A/0B/0C/0D/0E/0F) — and
  `Theme.syntax(role)`, which maps a `highlight.Role` (the capture→role table in
  `src/highlight/role.zig`) to a `Style`; the text modifiers (`strong`,
  `emphasis`, `title`, `uri`) are a slot plus an SGR attribute. New fields and
  their `default` values only; the loader is untouched.
- `// changed (app):` `Pane` has two more variants — `outline: OutlinePane`
  (`src/app/outline.zig`) and `md_preview: MdPreviewPane`
  (`src/app/md_preview.zig`). Both reuse the `.editor_cell{pane, line, col}`
  hit: on an outline row it names the symbol's source position (a click jumps),
  on a preview row the logical line (the wheel scrolls). `PaneStore` gains
  `findPreview(path)` / `findOutline(source)`.
- `// changed (app):` `App.openPath` routes a markdown file to its rendered
  preview (`Config.markdown_opens_rendered`, default on) unless an editor already
  holds it; `App.openEditor` is the raw path. `Config` gains `auto_md_preview`,
  `markdown_opens_rendered`, `sticky_context` (the `[ui]` keys of the same names).
- `// changed (app):` the bufferline strip carries one chip at its right end —
  `✏ Edit` on a preview, ` Preview` on a markdown editor — registered as
  `.button(md_preview.button_edit / button_preview)`; `dispatch` runs
  `markdown.edit_raw` / `markdown.preview` for them.
- `// changed (editor):` `Editor.edits: EditLog` — every `splice` leaves a
  `Splice` record (pre-edit bytes plus row/byte-col points); `setText` and an undo
  restore mark the log lost. Consumers pull by seq (`since`, `head`,
  `lostSince`) and the render trims it. This is the incremental-parse contract's
  source of truth; `EditOutcome.text_edits` is still filled but the highlighter
  and the snippet session read the log instead.
- `// changed (editor):` `Editor.objects: ?ObjectProvider` — the app installs
  it (`App.attachSeams`) so `select_inner/around_function` and `_class` ask the
  pane's syntax tree; `select_inner/around_argument` is text-only. No new
  `EditOp`.
- `// changed (spec):` the brief named `view.outline` / `view.md_preview`
  toggles; those ids are not in `commands/specs.zig` and the registry is a
  closed set, so the shipped surface is `outline.show` (open / refresh; `q` on
  the pane closes), `markdown.preview`, `markdown.edit_raw`,
  `view.toggle_auto_md_preview`, `view.toggle_sticky_context` (also
  `:set stickycontext`), `snippet.expand` / `next_placeholder` /
  `prev_placeholder`. `snippet.pick` / `snippet.pick_all` are not in this build.
- Highlighting precedence follows tree-sitter-highlight (the grammars' own
  queries assume it): inner node over outer, first pattern keeps a node,
  injected layer over host. `#set! injection.combined` and
  `injection.include-children` are parsed but each content node is parsed on
  its own; the highlight idle gate is 120 ms from the frame that first sees a
  dirty pane (a throttle while typing), with the cached spans shifted every
  frame so nothing drifts in between.

---

## Merge notes — mouse ⨯ (config-wire + lang) (2026-09-04)

- `// changed (app):` `Config` is the ZON `config.Config`; mouse's stand-in
  struct is gone. Its two frame fields live in `[ui]`: `scrollbar` (already
  there) and `wheel_lines: u8 = 3` (lines per wheel notch, `App.wheel`).
  The input style the app runs is `App.input_style`; `cfg.editor.input_style`
  is the config's enum and `setInputStyle` keeps the two level.
- `// changed (app):` `App.openPath` notes the file in the recent list and
  then routes (markdown → preview per `markdown_opens_rendered`);
  `App.openEditor` is the raw path. Every caller that opens "the file" uses
  `openPath`; only the preview machinery reaches for `openEditor`.
- `// changed (app):` the settings overlay is `app/settings.zig` +
  `ui/settings.zig` (the ZON-writing one); the `ui.wrap` row is labelled
  `Soft wrap` as in Rust (`overlays.test` asserts it). A press on it routes
  to the row (`.overlay_item`), a press anywhere else keeps the writes and
  closes; a press outside a picker cancels it (a themes picker restores its
  preview) before the press goes on.
- `// changed (app):` the markdown chip rides the active leaf's tab strip
  (`render.drawMdChip`), and the outline / preview panes take the wheel
  through `wheelOnPane` like every other pane.

---

## Merge notes — runners ⨯ (config-wire + lang + mouse) (2026-09-04)

- `// changed (app):` `Pane` gains `pty: PtyPane` (`app/pty_pane.zig`,
  painted by `ui/pty_view.zig`) beside `editor / outline / md_preview /
  cheatsheet / list`; `Pane.deinit` takes the gpa. `PromptPurpose` keeps
  its tagged-union shape and adds `npm_run_script` / `go_run_path`;
  `ConfirmPurpose` adds `install_tool: u16`; `PickerKind` adds
  `go_run_cmd / tools / tasks`.
- `// changed (app):` runners' flat-config reads are repointed at the ZON
  sections (`cfg.ui.ascii_icons`, `app.editorConfig()`); the `.tasks` /
  `.startup.tasks` tables come from the config the App already owns —
  `tui/loop.zig` calls `tasks.installFromConfig(&app, &app.cfg)` right
  after `App.initWith` and before the `startup` hook, instead of loading
  the config a second time. `InitOptions.env` (the children's
  environment) rides alongside `cfg` / `loaded`.
- `// changed (app):` the pty pane sits inside mouse's frame: the render
  switch paints it into the strip-subtracted rect; `dispatch.key`'s
  non-editor block routes it to `ptyKey` (plain keys to the child,
  bound modified chords to the chord chain, `childOwned` chords to the
  child, any key closes an exited pane); the `.pane` hit feeds SGR
  reports to a child that tracks the mouse (origin below the tab
  strip) and otherwise lets `wheelOnPane` scroll the scrollback.
- `// changed (app):` the statusline's pty row (TERM / EXITED, the
  grid's own cursor) lives in `render.drawStatusline`; `App.tick` runs
  `pty_pane.tickAll` and `watch.tick` after the theme poll; `deinit`
  frees runners / tasks state with the other lists, `env` after the
  panes, and the `Loaded` config last.

---

## Git (Phase 4) — `// changed:` notes (2026-09-04)

- `// changed (ui):` `editor_view.Doc` gains two fields. `gutter_marks:
  []const GutterMark = &.{}` (`GutterMark{ line: u32, kind: enum { added,
  modified, deleted } }`, 0-based, sorted by line) paints a coloured bar in
  the gutter's last cell — `▎` for added / modified, `▁` for a deleted run,
  ascii `+ ~ _`; with line numbers off the gutter is one cell wide while
  marks exist. `blame: []const []const u8 = &.{}` is blame mode: one label
  per line (`<sha7> <author> <age>`) painted INSTEAD of the line number,
  the gutter widened to the widest label (capped at `blame_max_w = 32`).
  Both empty = the old paint, byte for byte.
- `// changed (ui):` three new views, all app-data-only (they import
  `src/git/parse.zig`, a pure text module, never `App`):
  `ui/git_status_view.zig` (`Row`, `paintRow` for the rail's `ListPanel`,
  `drawPane` for `Pane.git_status` with `.script_hit{pane, row}` hits),
  `ui/diff_view.zig` (`Row`, `flatten(arena, files)`, `State{scroll}`,
  `draw(ui, pane, area, &state, Doc{files, rows, cursor, focused,
  header})`), `ui/git_graph_view.zig` (`layout(arena, commits) []Lane` —
  lanes from parent ids — and `draw` with `Doc.lane_spacing` from
  `cfg.git_graph`).
- `// changed (core):` `PanelId` gains `.git`; `AppEvent.git` is
  `*git.client.Result` (the placeholder is gone), destroyed by
  `freeEvent` and adopted by `app/git.zig`'s `handle`.
- `// changed (app):` `Pane` gains `git_status: git.StatusPane`, `diff:
  git.DiffPane`, `git_graph: git.GraphPane`. `PickerKind`, `PromptPurpose`
  and `ConfirmPurpose` each gain one `git` variant; what it means lives in
  `git.State.{pick, prompt, confirm}` so the trunk has one prong per
  overlay, not one per git command. Seven Zig-only ids (`git.refresh`,
  `git.stage`, `git.unstage`, `git.stage_all`, `git.unstage_all`,
  `git.discard`, `git.open_file`) give the row menu enums to name; the
  spec count pins read 812.
- `// changed (app):` no git runs on the UI thread. `src/git/client.zig`
  is one worker per repo (`Repo` in its own `Io.Group`, a `Job` queue,
  `std.process.run` per job); the operation-level undo / redo stack is
  the worker's, so `commit` then `undo` serialise through the queue.
  `App.tick` asks for a fresh status 3 s after the last one landed;
  `save_post` asks at once; the `open` hook switches the active repo to
  the one holding the file.

---

## Phase 7 — AI, agents, spend — `// changed:` notes (2026-09-04)

- `// changed (core):` `AppEvent.ai` is real: `.{ job: u64, msg: AiMsg }` with
  `AiMsg = union(enum){ suggestion{pane, generation, text}, text, done, failed,
  confirm }` — every slice gpa-owned by the event (`event.freeAiMsg`). Two
  more payloads: `agents: *agents.ScanResult` and `spend: *spend.Result`,
  adopted by the pane that asked (`generation` + pane id checked) or freed.
- `// changed (app):` `Pane` gains `ai: ai.AiPane` (`src/app/ai.zig`),
  `claude_agents: agents.AgentsPane` (`src/app/agents.zig`) and
  `spend_report: spend.SpendPane` (`src/app/spend.zig`). The two dashboards
  each own an `Io.Group`, so `Pane.deinit(gpa, io)` takes the io and
  `PaneStore.init(gpa, io)` carries it — a pane closing cancels its scan
  before its arena goes. Their rows / chips register `.script_hit{pane, id}`
  (ids in each module), routed by the `.script_hit` prong.
- `// changed (app):` the D3 reverse channel's first real use: `ai.Job`
  (heap, freed at `ai.State.deinit`) owns an `Io.Queue(bool)`; the API
  worker posts `.confirm` and parks on `getOne`; the confirm box
  (`ConfirmPurpose.ai_tool`) answers with `putOne`. `dispatch.closeOverlay`
  calls `ai.overlayClosing` first so a box dismissed any other way answers
  no — a worker is never left parked.
- `// changed (app):` ghost text is painted by `render.drawGhost` after
  `editor_view.draw` — `Doc` is untouched; the suggestion's first line sits
  at the returned cursor with the rest of the line pushed right, further
  lines on the rows below. `dispatch.key` hands a key to `ai.interceptKey`
  before the chord chain whenever the editor holds a ghost (Tab / ctrl+→ /
  ctrl+↓ accept; anything else dismisses and goes on). `feedEditor`'s
  `.edited` arms `ai.noteEdit` (the 300 ms debounce, a generation per fire).
- `// changed (app):` `PromptPurpose` gains `ai_ask / ai_chat / ai_search /
  ai_branch_name / ai_token`; `ConfirmPurpose` gains `ai_tool: u64` and
  `kill_pids: []u32` (owned); `PickerKind` gains `ai_suggest_backend` and
  `ai_session`. `ai.session_search` fills the quickfix `ListPane`.
- `// changed (config):` `[ai] suggest_backend / suggest_model / model /
  system_prompt / api_tools / api_write_tools / max_tokens / layout_mode` are
  read from `Ai.extra` (the decoder's unknown-key bag); the setup picker
  persists `suggest_backend` through `settings.persist`. `suggest_backend =
  "local"` toasts the migration note (local FIM is API-only in 0.3.0).
- `// changed (app):` the statusline's right segments carry the AI meter
  (`ai.meterSegment`, `claude_meter_mode` off / compact / ticker) once
  `ai.refresh_usage` or the spend pane has computed a snapshot. The quota
  endpoint (OAuth usage) is not in this build; the meter is the local 24 h
  spend.
- Cloud agents (`cloud_agents.*`) are registered and say "not in this build";
  `ai.canary`, `ai.claude_rename_account`, `ai.show_last_response`,
  `agents.new_from_pr` likewise.

---

## LSP + DAP (Phase 5) — `// changed:` notes (2026-09-04)

- `// changed (ui):` `editor_view.Doc` gains two slices the app fills per
  frame: `marks: []const GutterMark` (`{ line, glyph, style }` — one sign
  painted in the gutter's first column on that line; the app resolves
  priority by ordering the list, the view paints the first match) and
  `underlines: []const Underline` (`{ start, end, style }` — byte ranges
  drawn over the syntax style with the style's `fg` as the underline
  colour and its `ul_style`, `.curly` when unset). The debugger's
  breakpoints (`● ◆ ◈`) and the stop arrow (`▶`) are marks; a diagnostic's
  severity dot is a mark on the lines the debugger leaves; a diagnostic's
  range is an underline.
- `// changed (core):` `PanelId` gains `diagnostics` — the LSP problems
  list is a `ListPanel(DiagRow)` in the right slot like TODOS
  (`lsp.diagnostics` shows it; `lsp.diagnostics_filter` cycles the
  severity chip; Enter opens the row). `cmd_view.showRightPanel` is pub
  so a command can route a panel there.
- `// changed (app):` `Pane` gains `debug: dap.DebugPane` and
  `dap_repl: dap.DapReplPane` (`src/app/dap.zig`), painted by
  `ui/dap_view.zig` and `ui/dap_repl_view.zig`; their rows register
  `.script_hit{ pane, id }` (a frame is its index, a variable row is
  `vars_base + i`, a watch is `watch_base + i`, the REPL's input row is
  `input_hit`). Both open beside the active pane and are singletons.
- `// changed (app):` `PromptPurpose` gains `dap_add_watch`,
  `dap_bp_condition` / `dap_hit_count` (`BpTarget{ path, line }`),
  `dap_set_variable`, `lsp_rename`, `lsp_workspace_symbol`; `PickerKind`
  gains `dap_remove_watch`, `dap_exceptions`, `dap_threads`,
  `lsp_locations`, `lsp_code_actions`, `lsp_symbols`.
- `// changed (app):` the completion popup, the hover / signature box and
  the peek overlay are `app.lsp` state, not `Overlay` variants — the
  popup coexists with typing. Their rows register `.overlay_item(i)` with
  no overlay up; `dispatch` routes those to the popup. `lsp.interceptKey`
  runs after the find bar and before any pane routing.
- `// changed (app):` document sync reads `Editor.edits` (the `EditLog`
  the highlighter and the snippet session already read), not
  `EditOutcome.text_edits`: one splice on an incremental server goes as
  a range when it converts exactly (an insertion, or utf-8 positions),
  anything else as the full text. It runs from the frame (`drawEditor`),
  so every mutation path — ops, `setText`, undo — is covered.
- `// changed (app, 2026-09-07 lsp-fixture):` the root falls back to the
  file's own directory when no marker is found — Rust's `find_root` — so a
  lone `.rs` outside a crate still starts rust-analyzer (which then says
  `Failed to discover workspace…` itself, toasted as `LSP: …`). The
  `initialize` capabilities are all objects (an empty `.{}` went out as
  `[]`, rust-analyzer's serde refused it and the server exited before
  answering). `window/showMessage` toasts only MessageType 1 (Error), with
  Rust's `LSP: ` prefix, at the plain (info) level, the text verbatim.
  The `LSP N` statusline count is the live (`!transport.isDead()`) entries
  of `app.lsp.servers`, unchanged. After a `didChange` the file's
  `documentSymbol` is asked again once edits pause 150 ms
  (`symbols_due`, `lsp.tick`) — the set behind the outline and the
  statusline's `› name` follows the buffer; Rust's chip reads a live
  regex outline instead. `$NAME` in `.lsp.<x>.cmd` / `.args` expands
  from the environment (as a debug adapter's); an `.lsp` table written
  to `.mnml/config.zon` after launch is read on the first miss
  (`refreshServers`, trusted workspaces). `Server.deinit` waits up to
  250 ms for the child to leave on `exit` before the pipes close.
  `tools/fake_lsp/` (`mnml-fake-lsp`, `$MNML_FAKE_LSP`,
  `build_options.fake_lsp_exe`) is the deterministic server the
  `lsp_fake_*.test` scripts and the app integration test drive.
- `// changed (render, 2026-09-07 lsp-fixture):` the toast stack moves up
  one row while the flash cue is armed, as it does for the Undo chip —
  both take the panes' last row, which the stack now sits on.
- `// changed (app):` [superseded above] a language server is spawned only when a root
  marker is found for it (or its spec has none); the missing-binary toast
  (`LSP: <cmd> not installed — \`<hint>\``, once per server per session)
  is decided by a PATH probe independent of the root, so a marker-less
  temp workspace never launches a server it would only confuse. The
  `.open` / `save_pre` / `save_post` hooks carry attach, format-on-save
  and `didSave`; `forceClosePane` sends `didClose` for the last editor on
  a file.
- `// changed (app):` the outline prefers a server's `documentSymbol`
  list (`lsp.symbolsFor`) to the tree-sitter walk when one has landed;
  `lsp.highlight_symbol` lands in the pane's find matches (same paint);
  `lsp.fold_all` fills `Buffer.folds`.
- `// changed (spec):` `dap.attach` is a launch body with
  `.request = "attach"` (no process picker); `lsp.inlay_hints_toggle`
  flips the config flag and says painting is a later slice.

---

## Fake DAP adapter — `// changed:` notes (2026-09-07)

- `// changed (tools):` `tools/fake_dap/` is `mnml-fake-dap`, a
  deterministic Debug Adapter over stdio that runs the launched file as
  a tiny line-oriented program (`README.md` there). `zig build` installs
  it beside the exe; `build_options.fake_dap_exe` is its path for the
  unit tests; `gate-build` carries it so it cross-builds like the app.
- `// changed (app):` `dap/client.expandEnv` — `$NAME` / `${NAME}` in a
  `.dap.<name>.cmd` or argument expands from the App's environment
  before the spawn. `dap.run` that finds no adapter for the file reads
  the config layers again (`config.load.load`, trusted workspaces only,
  the App's own data root) and takes their `.dap` table
  (`State.adapters_loaded` keeps the arena) — an adapter added to
  `.mnml/config.zon` after launch is found without a restart.
- `// changed (e2e):` `e2e.Config.env` / `runner.Options.env` carry the
  environment an App's children inherit; `mnml-zig test` exports
  `MNML_FAKE_DAP` (the adapter beside the runner, else the install
  path) into it. The `dap_session_*.test` scripts seed
  `.dap.dbg.cmd = "$MNML_FAKE_DAP"` and drive a real session.

---

## Merge notes — lsp-dap ⨯ (git + ai) (2026-09-04)

- `// changed (ui):` git's `gutter_marks: []const GutterMark` and
  lsp-dap's `marks: []const GutterMark` were the same concept — a per-line
  mark the view paints in the gutter — with two struct shapes, so `Doc`
  keeps ONE field, git's `gutter_marks`, and `GutterMark` is the union of
  both: `{ line, kind: MarkKind, glyph = "", style = .{} }` with
  `MarkKind = { added, modified, deleted, sign }`. A change mark carries
  only `kind`; a `.sign` (a breakpoint `● ◆ ◈`, the stop's `▶`, a
  diagnostic's dot) carries its `glyph` + `style`. The two paint in
  different cells — the change bar in the gutter's LAST cell, the sign in
  its FIRST — so with line numbers on both show on the same line. The
  list is in priority order, not necessarily sorted (`render.gutterMarks`
  concatenates dap, lsp, git): per column the view paints the first match
  on a line. With line numbers off the gutter is one cell while marks
  exist (git's rule, now covering signs), the two columns coincide, and
  the sign wins — a diagnostics dot beats a change mark. lsp-dap's
  writers (`lsp.marksFor`, `dap.marksFor`) say `.kind = .sign`;
  `git.viewMarks` is unchanged. `blame` and `underlines` stay as each
  side wrote them.
- `// changed (app):` `Pane` is 14 variants — the six git / ai ones and
  `debug` / `dap_repl`; every exhaustive switch names all of them.
  `Pane.deinit(gpa, io)` / `PaneStore.init(gpa, io)` are main's (the
  agents / spend panes need the io); `dap.openSingleton`'s errdefer was
  the one lsp-dap call on the old shape. `PanelId` is `todos notes
  findings sessions git diagnostics`; `AppEvent` keeps `.git .ai .agents
  .spend` and has `.lsp .dap` real; `PromptPurpose` / `PickerKind` are
  the unions; the runner tables list git, ai, agents, spend, dap and lsp.
  The count pin stays 812 — lsp-dap added no Zig-only ids.
- `// changed (app):` key routing in `dispatch.key`: overlay → find bar →
  `lsp.interceptKey` (completion / hover / peek) → the tree and the
  right panel → the non-editor pane blocks → the ghost's accept keys →
  the chord chain → the buffer. An open completion popup therefore owns
  Tab / Enter ahead of a ghost's Tab; with no popup the ghost keeps Tab /
  ctrl+→ / ctrl+↓. A completion accept that edited the text leaves the
  ghost stale, so the dispatcher drops it when `Editor.edits.head()`
  moved under a consumed key.
- `// changed (app):` the statusline's right segments are git's branch
  segment, then lsp's `✗ N  ⚠ M` chip, then ai's meter, then the input
  style. `App.tick` runs git's TTL and ai's timers; lsp / dap have no
  pump — their reader tasks post `.lsp` / `.dap` events and `App.handle`
  is their only entry — so `nextDeadlineMs` folds git and ai only.
- `// changed (app):` `App.deinit` retires the workers first, in this
  order: ai, todos, git, dap, lsp — then the rest as before.

## HTTP track (Phase 6) — `// changed:` notes (2026-09-04, branch `http`)

- `// changed (core):` `AppEvent.http` is `*http.client.JobResult` (a
  finished send: status / headers / decoded body / timing, or a one-line
  transport error); `AppEvent.cdp` is `*app.browser_pane.CdpEvent`
  (connected / a raw JSON-RPC message / closed) and `AppEvent.ws` is
  `*app.ws_pane.WsEvent` (open / a message / an error / closed). All three
  are owned boxes: `freeEvent` destroys them, the handler adopts or drops.
  `AppEvent.sse` stays a placeholder — SSE is parsed off a finished body
  (`sse.parse_active_response`); a progressive stream is a later slice.
- `// changed (app):` `Pane` gains `request: RequestPane`
  (`app/request_pane.zig`), `websocket: WebsocketPane` (`app/ws_pane.zig`)
  and `browser: BrowserPane` (`app/browser_pane.zig`), painted by
  `ui/request_view.zig`, `ui/ws_view.zig`, `ui/browser_view.zig`. Each view
  takes a plain `Model` the app assembles on the frame arena — the ui side
  never sees `App`, a `Request` or a socket. Hits are `.script_hit{ pane, id }`
  with per-view `hit_*` id constants; the response body goes through
  `editor_view.draw` with `ViewState.pinAt(0)` so the wheel scrolls it.
- `// changed (app):` `App.openPath` routes `.http` / `.rest` / `.curl` to a
  request pane on the file's first block (`http.openFile`); a file the parser
  cannot read falls through to the editor. `file.save` on a request pane is
  `http.saveToSource`: a multi-block `.http` gets its block spliced
  (`parse.splice`), anything else is overwritten as a curl one-liner.
- `// changed (app):` `App.http: http.State` — one `Io.Group` of send
  workers, the session env override, the cookie jar (loaded on first use),
  the picker arena behind the history / captured pickers, the fan-out /
  bench / sync bookkeeping. `PickerKind` gains 16 http/ws/browser kinds and
  `PromptPurpose` 19 purposes; `cmd_picker.accept` and `dispatch.acceptPrompt`
  route the new kinds to `cmd_http` / `ws_pane` / `cmd_browser`.
- `// changed (spec):` every `http.*`, `ws.*`, `browser.*`, `auth.*`,
  `cookies.*`, `jwt.*`, `sse.*` id in `commands/specs.zig` has a runner (125).
  Three run as honest refusals in this build: `http.toggle_edit_split`,
  `http.toggle_split_orientation`, `http.toggle_collapse_all` (the split edit
  view and the HTTP sidebar are not in this build) and `browser.dock_toggle`
  (window docking). `http.ai_build` / `http.ai_debug` say the Claude
  integration lands in Phase 7; `http.copy_ai_prompt` works today.
- `// changed (config):` `[http] auto_format_body` / `sync_normalize` seed
  `App.http`; `[ws] subprotocols / ping_interval_secs / reconnect_max_attempts`
  and `[browser] headless / autocapture_to_log / profile_mode` are read where
  the Rust app read them. `browser.toggle_headless` and
  `browser.autocapture_toggle` flip the live config, not the file.
- Edit-tab order is Body / Headers / Params / Auth / Vars / Script
  (`Ctrl+1..6`, `Ctrl+]` / `Ctrl+[`), as the gate files spell it; `Tab`
  flips Request ⇄ Response, `Ctrl+Enter` sends, `Ctrl+S` writes back.
- Files: `.rqst/history.jsonl` (the Rust line shape; sensitive headers keep
  their `{{VAR}}` or are redacted), `.rqst/captured/log.jsonl`,
  `<source>.mock.json`, `.mnml/cookies.json` (`{"host":{"name":"value"}}`),
  `.mnml/auth/<name>.txt`, `.mnml/env/<name>.env` over `.rqst/env/<name>.env`,
  `.mnml/chains/*.chain.json`, `.mnml/sources.json` (or `.rqst/`),
  `<data>/history-global.jsonl`, `<data>/ws-history/<host>/history.jsonl`,
  `.mnml/screenshots/shot-<ts>.png|pdf`.
- Dependencies, as DESIGN.md decided: HTTP/TLS is `std.http.Client` +
  `std.crypto.tls` (gzip / deflate / zstd decoded by std; **no brotli**, the
  `accept-encoding` says so); WebSocket is RFC 6455 by hand over
  `std.Io.net.Stream` + `std.crypto.tls` (`http/ws.zig`); JSON Schema is the
  ~300-line subset in `http/schema.zig` (`pattern` matches as a literal — no
  regex engine); YAML is the block/flow subset in `http/yaml.zig`
  (no anchors / aliases / tags / multi-document). `-k` / `--insecure` is
  parsed and carried but the std client verifies certificates regardless —
  a self-signed dev host needs its CA in the bundle.
- CLI: `mnml-zig run FILE [--env] [--workspace]`, `chain run FILE`,
  `discover SPEC [--out] [--base-url] [--normalize] [--force]`,
  `sync [--workspace] [--normalize]`, `sync-check`, `proxy --url URL
  [--seconds] [--idle-ms] [--quiet]` (`http/cli.zig`).

## Merge notes — http ⨯ (git + ai + lsp-dap) (2026-09-04)

- `// changed (app):` `Pane` is 17 variants — the fourteen main had and
  `request` / `websocket` / `browser`; every exhaustive switch (`deinit`,
  `title`, `dirty`, the render arm, the key blocks, `md_preview` /
  `outline`'s "not an editor" prongs, the wheel and `script_hit` arms)
  names them all. `Pane.deinit(gpa, io)` / `PaneStore.init(gpa, io)`
  stay main's; `http.openFile`'s preview-replace was the one http call
  on the old shape.
- `// changed (core):` `AppEvent` keeps `.git .agents .spend .ai .lsp
  .dap` and has `.http .ws .cdp` as the owned boxes above; the `_todo`
  placeholders for those three are gone, `.sse` is still one.
  `freeEvent` destroys all of them.
- `// changed (app):` `PickerKind` is the union (18 + 16) and
  `PromptPurpose` the union (main's ai / dap / lsp purposes + http's 19);
  `dispatch.acceptPrompt` names http's purposes explicitly instead of
  an `else` prong so a new purpose is a compile error, not a silent
  route into `cmd_http`. The runner tables list http, cmd_http, ws_pane
  and cmd_browser after lsp. The count pin stays 812 — http added no
  Zig-only ids.
- `// changed (app):` `App.openPath` routes a request file ahead of the
  markdown-preview rule; `openEditor` stays raw. Key routing keeps main's
  order (overlay → find bar → `lsp.interceptKey` → tree / right panel →
  non-editor pane blocks → ghost accept keys → chord chain → buffer) with
  the request / ws / browser blocks among the non-editor panes. The
  `script_hit` button gate is main's — left or right on every pane — and
  the browser pane's click is left-only.
- `// changed (app):` the statusline's right segments are still git's
  branch, lsp's chip, ai's meter; http's `HTTP` / `SENDING` / `WS` / `CDP`
  labels are the active pane's mode chip, like `TERM`. `App.tick` runs
  pty, ws, watch, git and ai; `nextDeadlineMs` folds git's busy count and
  TTL, ai's timers, http's sender count and the ws pane's timers.
  `App.deinit` retires the workers as ai, todos, http, git, dap, lsp.

## Lua (Phase 8, D10) — `// changed:` notes (2026-09-04, branch `lua`)

- `// changed (build):` zlua's `build.zig` and the translate-c package
  it pins fail analysis on 0.16.0, so its `src/lib.zig` + `define.zig`
  are vendored under `vendor/zlua/` (the tree-sitter precedent) and
  `build.zig`'s `addLua` compiles the `lua54` tarball, translates
  `lua_all.h`, and declares the `config` options the lib reads. The
  vendored lib still used `Type.Struct.field_names` / `Type.Fn.param_types`
  at the sites `pushAny`, `toAny` and `wrap` reach; those read `.fields`
  / `.params` now.
- `// changed (app):` D10 has `Lua{ state, app }`; the App struct moves
  after `initWith` returns, so the back-pointer cannot be set at create.
  `App.lua: ?*Lua` is reached through `App.script()`, which points the
  state at the App of the call in flight; every Zig entry (a command
  runner, a hook emit, a render, a tick) goes through it. Nothing on the
  Lua side holds `*App`.
- `// changed (core):` `command.runDyn`'s `.lua` prong and
  `hooks.emit`'s `.lua` prong are filled (`callCommand` /
  `callHook`); the hook payload is the flat `HookArgs` table plus
  `hook = "<name>"`, since one function may subscribe to several.
  `script.reload` and `script.edit_init` are static specs — count pin
  814.
- `// changed (app):` script reload (`Lua.reset`) unregisters
  `owner == .script` wholesale as D10 says, which takes the config
  tasks' `task.<name>` commands with it (they register as `.script` /
  `.ex`); `reset` reinstalls them from `app.cfg`. The state is closed and
  reopened rather than swept, so no ref can outlive a reload.
- `// changed (config):` `trust.Sink.init_lua` — `<ws>/.mnml/init.lua`
  is a claim without a config key; `trust.claimsWith(arena, p, Facts)`
  carries whether the loader saw the file, `load` decides trust when the
  file exists even with no `config.zon`, and `strip` has nothing to
  remove (the file is gated by `Loaded.workspace_trusted`, mirrored on
  `App.workspace_trusted`). `InitOptions.workspace_trusted` overrides
  the derivation; the `.test` driver sets it for the temp workspace it
  made.
- `// changed (app):` `Pane.script` is the 18th variant
  (`app/script_pane.zig`, painted by `ui/script_view.zig`); the
  exhaustive switches in `pane`, `render` (`drawMdChip`, `drawBody`),
  `dispatch` (keys, `script_hit`, wheel), `md_preview` and `outline`
  name it. `PickerKind.lua` is the picker prong; `cmd_picker.accept`
  calls the row's `on_accept` and `cancel` drops the refs. The
  statusline's right cluster takes a script's `left` segments at its
  inner edge and `right` ones after ai's meter.
- `// changed (docs):` `docs/LUA.md` is the API reference;
  `docs/examples/init.lua` the reference script (run by a unit test);
  `tests/e2e/lua_init.test` the e2e. Corpus 226/227 — the one
  failure is main's `settings_persist_to_workspace.test`.
## Bridge v2 (Phase 8) — `// changed:` notes (2026-09-04, branch `bridge`)

- `// changed (core):` `AppEvent.mount` is `*bridge.host.Event` (connected /
  frame / title / cursor / command / toast / bye / closed) and
  `AppEvent.marketplace` is `*app.marketplace.Result` (a listing with its
  arena, an install outcome, a failure); the `MarketResult` placeholder is
  gone. `freeEvent` destroys both. `Source` gains `.mount`.
- `// changed (core):` `DynRunner` gains `.mount: MountRun{ binary, args,
  pty, label }` — what a manifest command opens; `DynInit.Runner` is now a
  named union with the same variant. `runDyn` routes it to
  `integrations.runMount`, which resolves a bare binary through
  `<data root>/bin/` (the marketplace's links) before PATH.
- `// changed (app):` `Pane` is 20 variants: `mount: MountPane`
  (`app/mount_pane.zig`, painted by `ui/mount_view.zig`), `integrations:
  IntegrationsPane` (`app/integrations.zig` + `ui/integrations_view.zig`),
  `marketplace: MarketplacePane` (`app/marketplace.zig` +
  `ui/marketplace_view.zig`). Every exhaustive switch names them. The
  mount registers one `.script_hit{ pane, id = row }` per row so a click
  is turned back into pane-relative cells from the hit's rect; the wheel
  and pointer motion are forwarded through the same prong.
  *// changed 2026-09-07 (sample-integration):* `Pane.marketplace` and
  `ui/marketplace_view.zig` are gone; `Pane.integrations` is the detail
  pane for one entry (`IntegrationsPane{ target: installed | marketplace
  | dev, cursor }`, an owned key, `title()` the id); the listing is the
  INTEGRATIONS **section** — `PanelId.integrations`, a column surface
  (`side.surface`), painted by `integrations_view.drawSection` with the
  Rust chrome (header, `Inst / Mkt / ` tabs as `.button = tab_base + i`,
  the filter pill, the sort chip `.chip{ .integrations, .sort }`, three
  rows per entry as `.row{ .integrations, idx }`, a scrollbar). Dispatch
  routes the panel's keys and the five mouse prongs to
  `app/integrations.zig`; `set_panel_sort` maps `ListSort` onto the
  tab's own order (`InstalledSort` / `MarketSort`). `App.tick` calls
  `integrations.tick` for a Dev install's task pane. `Config.Integrations.dev_roots`
  and `MarketplaceSource.local_folder` are the two config keys;
  `MNML_MARKETPLACE_LOCAL` the environment's; `$VAR` manifest binaries
  resolve through the environment; a manifest's `statusline[]` sets
  `ipc_fx` segments keyed `<id>.<seg>`. `integrations/<id>/` beside
  `sdk/mnml-sdk` is where the official Zig integrations live —
  `integrations/sample` first, built as `zig-out/bin/mnml-sample`
  (`build_options.sample_integration_exe`, `$MNML_SAMPLE_INTEGRATION`).
  Three ids: `integrations.dev_build` / `dev_install` / `dev_rebuild`.
- `// changed (app):` `App.integrations: integrations.State` (the manifest
  snapshot arena, the dyn slots, the `<id>.<key>` settings map read from
  `<data root>/integration-settings.zon`) and `App.marketplace:
  marketplace.State` (one `Io.Group` of fetch / install workers).
  `App.deinit` retires panes before `integrations` — a mount runner
  borrows the manifest arena. The `.startup` hook runs the first
  manifest scan (`integrations.onStartup`); tests call `refresh`.
- `// changed (app):` `PromptPurpose.mount_open`, `ConfirmPurpose.remove_integration`
  (owned id), five `PickerKind.integrations_*` kinds routed to
  `integrations.acceptPicker`.
- `// changed (ui):` the palette bar paints the integration chips
  (`integrations_view.drawChips`) between the search chip and the
  right-panel toggle, right-to-left, dropping whole chips that do not
  fit; hits are `.button = chip_base + i` with `chip_base = 0x10` — kept
  under `render.Button.new_tab_base` (0x100), which `newTabLeaf` treats as
  everything above it. `dispatch` routes them to `integrations.chipClick`
  (left runs the first command, right opens the row menu).
- `// changed (settings):` the overlay's *Integrations* section appends one
  discrete-choice row per installed manifest `settings[]` entry
  (`settings.integ_base + k`); adjust / set / reset branch on the id and
  write `integration-settings.zon`, not the config.
- `// changed (build):` a delimited `// ── sdk ──` block: `sdk/mnml-sdk`
  is imported by the host as `mnml_sdk` (one definition of the wire and
  the manifest), `zig build sdk-example` installs `mnml-hello`, and the
  unit-test step depends on it — `build_options.sdk_example_exe` is the
  path the host's integration test spawns (the test skips when the file
  is absent or the platform has no Unix sockets).
- Manifests are ZON at `~/.config/mnml/integrations/<id>.zon` (and
  `<ws>/.mnml/integrations/`); the shape is the SDK's `Manifest`
  (`docs/SDK.md`). Enable / disable rewrites `chip.enabled` through
  `manifest.render`; remove deletes the file after a confirm.
- The marketplace's `crates_keyword` source is accepted and reported as
  "not searched"; `github_launcher_folder` lists `*.zon` manifests
  (install = write the file), `github_monorepo_apps` lists directories
  (install = clone + `zig build --prefix` + link into `<data root>/bin` +
  `--install`, on a worker). `MNML_MARKETPLACE_API` overrides
  `https://api.github.com` for the fake-server test.
- Known: `zig build gate-build -Dtarget=x86_64-linux-gnu` trips a Zig
  0.16.0 compiler TODO (`writeToPackedMemory`) on this branch's base
  commit too (checked on a scratch worktree of 76ccf5b); the Windows
  gate builds. Not introduced here.

## HTTP, more (Phase 6 follow-up) — `// changed:` notes (2026-09-05, branch `http-more`)

- `// changed (core):` `PanelId` gains `http` — the seven-section HTTP
  sidebar lives in the right slot like TODOS / GIT / DIAGNOSTICS.
  `view.activity_http` shows it (it was an honest refusal); every
  exhaustive switch on `PanelId` (`render.drawRightPanel`, the key /
  row / kebab / chip / filter / scrollbar prongs in `dispatch`) names it.
- `// changed (app):` `App.http_panel: http_panel.State`
  (`app/http_panel.zig`): one `ListPanel(Row)` whose rows are section
  headers (`▼ COLLECTIONS (n)`, `▸` folded) and their items —
  COLLECTIONS (every `.http` / `.rest` / `.curl` under the workspace,
  walk capped at 500, dot-dirs and the usual build dirs skipped), ENVS
  (the active one marked), CHAINS (`.mnml/chains/*.chain.json`), MOCKS
  (`*.mock.json`), COOKIES (the jar), RECENT (`.rqst/history.jsonl`,
  newest first, 50), CAPTURED (`.rqst/captured/log.jsonl`, 50). The
  snapshot is one arena `refresh` replaces; the scan is synchronous.
  The `/` filter is a case-insensitive substring over label + detail
  across every section; a header's count is what survived, and a
  section the filter empties is dropped. Enter / double-click: header
  folds, file or mock opens (`App.openPath`), env becomes the session
  override, chain runs (`cmd_http.runChainNamed`, now `pub`), cookie
  copies `name=value`, recent / captured re-open as a scratch request.
  `←` / `h` folds, `→` / `l` opens, `r` rescans, `c` folds or unfolds
  all, `n` starts a request. Row menus (right-click, kebab) carry
  registered ids only; three Zig-only ids were added —
  `http.panel_open`, `http.panel_toggle_section`, `http.panel_copy_path`
  — and `http.toggle_collapse_all` / `http.refresh` now act on the
  panel. The pin is 830.
- `// changed (app):` the request pane's edit split is pane state:
  `RequestPane.split / split_tab / split_ratio / split_scroll /
  orientation`, `toggleSplit()` (the second tab defaults to Vars, or
  Body when Vars is primary), `showTab()` swaps the halves when the
  right tab is brought left so both stay visible. `http.toggle_edit_split`
  and `http.toggle_split_orientation` (auto → vertical → horizontal)
  are real runners. A press on the divider arms a drag; every drag inside
  the edit area (`rp.edit_area`, measured at draw) re-derives the ratio,
  clamped 10–90.
- `// changed (ui):` `request_view.Model` gains `url_vars / body_vars /
  headers_vars: []const VarSpan`, `split: ?SplitModel{ tab, ratio,
  scroll }` and `orientation`. The view paints the right half with its
  own tab strip and a `│` divider (`hit_split_divider`,
  `hit_split_tab_base + i`, `hit_split_content`, `hit_split_toggle` — the
  `⇔` chip on the strip row), degrades to one half under 16 cells, and
  overpaints every `{{VAR}}` of a field in the theme's `syntax.variable`
  role (resolved) or `error_fg` (not), registering `hit_var_base + id`.
  `fieldScroll` mirrors `text_field.draw`'s one-row scroll so the
  overpaint lines up. `drawVarTip` paints the hover tip under the
  span (above when there is no room). `zones` splits Request / Response
  side by side when `orientation == .horizontal` and the pane is ≥ 40 wide.
- `// changed (ui):` `editor_view.Doc.var_spans: []const VarSpan` — the
  one delimited `{{VAR}} hook` block: spans painted over the syntax
  spans in the same two roles and registered as
  `.script_hit{ pane, var_hit_base + id }` (`var_hit_base = 100_000`).
  Nothing else in the view knows what a request is.
- `// changed (app):` `http.varTokens` classifies every token of the
  three fields against the active env (`VarToken{ name, shown, resolved,
  dynamic }`; a `{{$uuid}}` is resolved and shows `(built-in)`); a
  secret shows `••••••••`. `env.EnvSet.secrets` is filled by
  `# @secret A B` lines; `isSecret` also matches credential-shaped names
  (`looksSecret`: token / secret / password / passwd / api_key / apikey /
  auth / private). `env.lineOfKey` finds the 0-based line of `KEY=`.
  `http.jumpToVarDef` opens the active env file on that line, or at its
  end with a toast when undefined (the `.mnml` file is created then);
  `http.jump_to_env_var` uses it and `lsp.gotoDefinition` tries it first
  (`http.jumpVarAtCursor`) so `gd` on a `{{VAR}}` in a request buffer
  lands in the env file. Left-click a span → the jump; right-click → the
  quick-fix menu (`http.quick_fix`: Define in env… / Jump to definition /
  Pick env… / Inline value / Copy variable name; a built-in drops the
  first two). `http.define_var` seeds the env-value prompt,
  `http.inline_var` replaces the token in the pane's fields (or expands
  the whole buffer in an editor), `http.copy_var_name` copies it.
- `// changed (app):` `App.http.quick_fix_var` is the token a quick-fix
  menu was opened on; `http.takeQuickFix` consumes it. `dispatch.closeOverlay`
  calls `http.overlayClosing` so a menu dismissed by Esc drops it (the
  next caret-based var command must not act on a stale token), and
  `runMenuAction` carries it across the close to the row's command.
  `currentVar` always returns a copy on the frame arena — `inline_var`
  edits the field the caret's slice pointed into.
- `// changed (app):` `dispatch.mouse`'s `.script_hit` arm routes an
  editor pane's hits (only `var_hit_base` and above exist) to
  `http.editorVarClick`; `render.drawEditor` passes `var_spans` and
  paints the hover tip after the view.
- Not done, by design: the Rust panel's FILES-stragglers section (files
  are one flat COLLECTIONS list, folder dim like the GIT rail), its
  drag-to-resize section headers, and the `+ New request` / `Paste
  curl…` / `Import…` action rows (all reachable from the row menus and
  the palette).

## Miscellaneous parity rows — `// changed:` notes (2026-09-05, branch `misc`)

- `// changed (app):` `Pane.ai_apply` (`app/ai_apply.zig`): `a` in an
  AI pane opens a review of the first code block as a unified line
  diff against the editor *now* — arena-owned copies of both texts,
  common prefix / suffix trimmed, an LCS over the middle (deletions
  before insertions, as git orders a hunk; a middle past 4M cells is
  one replacing hunk), three lines of context, hunks closer than that
  merged, a missing final newline as a diffable sentinel line. Accepted
  hunks land through one `App.splice`, so undo is one step. With no
  selection the proposal is for the whole buffer, not the cursor's
  zero-width range. `ui/ai_apply_view.zig` paints the tally, the
  `[✓ accept]` / `[  skip  ]` badges and signed lines, one
  `.script_hit{ pane, row }` per row.
- `// changed (ui, ipc-tier2):` `statusline.Info.dyn_left` / `dyn_right`
  and `seg_dyn_base` — a host's `statusline-set-segment` chips with
  their own colour and a `.statusline_seg = seg_dyn_base + index` hit
  (the index is the segment's slot in `App.ipc_fx.segments`, so a click
  finds its `click_command` without frame-owned state). The left lane
  ends the left cluster; the right lane is innermost of the right
  cluster after the selection chip, so it drops before the position.
  `src/ui/statusline.zig` is outside the touch list; this was the only
  way to give the chips colour and clicks.
- `// changed (app):` `App.ipc_fx: ipc.effects.State` (segments +
  badges) and `App.native_notify` (`InitOptions.native_notify`; only
  `tui/loop.zig` passes true — one line outside the touch list — so
  headless and the tests never spawn `osascript` / `notify-send` /
  PowerShell). `ipc/effects.zig` owns the pack (priority desc, ties in
  registration order; `max_width` truncation with `…` / `...`;
  `min_width` drop), `notify` (an `error` pins under `source` or
  `notify:<title>`), `open-pty` (a pane below, labelled by basename)
  and `apply`, which `app/driver.zig`'s `vIpcCommand` routes to. The
  palette bar paints a host `git` badge in place of the repo's count
  and the other sections' sum as `•N`. Acks unchanged;
  `src/ipc/golden/tier2.*.jsonl` are the Rust shapes and a headless run
  through the real `App` must reproduce them byte for byte.
- `// changed (config, core):` `Config.LaunchProfile { name, product,
  binary, args, env, cwd_mode }`, `Config.DefaultProfile`,
  `Ai.launch_profiles` / `Ai.default_profile`; `MenuAction.ai_profile`
  (`AiProfileAction`, one core touch) carries the product and the
  menu row's index. Rust's `[[launch_profile]]` lived in the
  integration manifest (TOML, two scopes, a `wrapper` legacy key); E1
  makes config ZON the one place, the built-in `default` (the bare
  binary) implicit. A profile runs through `<data root>/bin/mnml-ai-<name>`
  (`.cmd` on Windows), rewritten before every spawn; `findSession`
  recognises a profile shim by name. `ai.State.owned_default` holds a
  default set this session until the next load.
- `// changed (build):` `-Dtest-filter` narrows the `.test` files as it
  narrows the unit tests (`mnml-zig test --filter`); `zig build test`
  depends on the gate subset (so `check`'s nested Debug + ReleaseSafe
  runs cover it twice more); `zig build e2e [-- ARGS]` is the whole
  corpus; `zig build check` ends with the full corpus minus
  `settings_persist_to_workspace` (`--skip`, announced), the file that
  asserts TOML by design. `runner.Options.name_filter` / `skip`,
  `runner.stemOf`.
- `// changed (build):` a `── glyph audit ──` block: `tools/glyph_audit.zig`
  bakes `data/nerd-glyphnames.json` into a `<hex>\t<name>` table at
  build time and audits `src/` with `--strict`; its tests get
  `build_options.src_root` / `glyph_json` and one walks the real `src/`
  under `zig build test`. Sites are `\u{XXXX}` escapes in the
  private-use planes; assertion lines are tests, not sites. The SVG
  preview and font patching stay cut.
- `// changed (main, dist):` `--startup-picker` sets
  `MNML_STARTUP_PICKER=1` for the process (`startup_picker.wanted`
  reads the environment; the flag is its spelling). `dist/macos/` is
  the bundle: a plist template stamped by `sed` (no `plutil`, so the
  Linux release runner can build it), a launcher that opens the bundled
  binary in ghostty (CLI or `/Applications/Ghostty.app`) else
  Terminal.app via `osascript`, with the picker on;
  `scripts/package.sh --macos-app` ships `mnml-<triple>.app.zip` as an
  optional `macos-app` asset. No icon yet.
- `// changed (core, app):` `AppEvent.tests` (`tests_pane.Result`);
  `tests_pane.zig` and `flaky.zig` in `runner_tables`; six Zig-only ids
  — `test.run_playwright`, `test.run_playwright_file`,
  `test.run_playwright_at_cursor`, `test.rerun_playwright_failed`,
  `test.open_trace`, `test.sort` — because the generic `test.run_*` are
  the cargo / npm / go / pytest runners here (Rust's were the
  Playwright runner). The pin is 836. `App.flaky: flaky.State` is the
  workspace's history, loaded once per process from
  `<ws>/.mnml/flaky.zon` (ZON, never JSON: E1). `Pane.tests` /
  `Pane.flaky` in every exhaustive switch. The trace viewer is a
  launcher: `npx playwright show-trace <trace.zip>` in a pane below.
- `// changed (test):` the tier-2 golden's `open-pty` runs `sleep 30`,
  not `ls -la`: the pty reader is a detached thread sharing a refcount
  with its session, and a child gone before the loop quits can race the
  leak check (seen once under ReleaseSafe). Not fixed here —
  `src/pty/` is outside the touch list; noted in
  `docs/parity-notes/misc.md` (folded into `docs/PARITY.md` by
  `5498f872`).
## File manager — `// changed:` notes (2026-09-05, branch `files`)

- `// changed (app):` `Pane.files: FilesPane` (`src/app/files_pane.zig`)
  and `Pane.asFiles()`. A directory listing is a pane: `files.open`
  opens one at the workspace, `files.open_split` two side by side,
  `files.trash` one at the trash. State is the pane (`cwd`, a
  `SnapshotArena` listing replaced on every `reload`, `visible` indices
  under the `/` filter, `sort`, `show_hidden`, `marks` keyed by absolute
  path, `anchor` for a range, `preview_pane`, the `preview_text` head of
  the cursor file, the vim `pending` verb byte). Every exhaustive
  `switch (pane.*)` gained a `.files` arm (`md_preview`, `outline`,
  `render.drawMdChip`, `Pane.dirty`).
- `// changed (ui):` `src/ui/files_view.zig` — `draw(ui, pane, area,
  Doc, *scroll) ?Caret`. `Doc` is plain data (`crumbs`, `rows: []Row{
  name, is_dir, is_link, size, mtime, marked, git }`, `cursor`,
  `focused`, `sort_label`, `show_hidden`, `filter`, `marked`, `total`,
  `err`, `preview`, `now_s`, `empty`). Every target registers a
  `.script_hit{ pane, id }` in the same statement as its paint; `Hit`
  splits the id space (rows below `0x1000_0000`; `crumb_base`,
  `chip_base` + `Chip{ sort, hidden, refresh, up }`, `kebab_base`,
  `body`, `filter`, `column_base` + `Column{ name, size, modified,
  kind }`) and `Hit.decode` reverses it. The preview column paints at
  ≥ 80 cells (`2/5` of the width); the filter pill reuses
  `filter_input.draw` and re-registers its rect under the pane's id.
  `humanBytes` / `humanAge` are `pub` (the transfer chip uses the first).
- `// changed (app):` `dispatch.key`'s pane switch routes `.files` to
  `files_pane.handleKey` before the chord chain (false = fall through:
  `delete` → `file.delete`, `f2` → `file.rename`, `ctrl+p`…);
  `dispatch.mouse`'s `.script_hit` arm routes `.files` to
  `files_pane.click`; `wheelOnPane` to `files_pane.scrollBy`.
- `// changed (app):` the subject of every file verb is
  `file_clipboard.targetPaths(app, arena)`: a FOCUSED Files pane's marks
  (visible ones first, in display order), else its cursor row, else the
  tree's cursor row — never a browser that is merely open. `targetDir`
  is where a paste lands (the pane's directory, else the tree row's).
  `tree.zig`'s `file.rename` / `file.move_to` / `file.new_folder` /
  `file.delete` runners defer to the pane when one has focus.
- `// changed (app):` `App.file_clipboard: file_clipboard.State{ paths,
  cut }`. `file.cut` / `file.copy` stage; `file.paste` resolves
  (source, destination) pairs on the UI thread — `-copy` / `-copy-N`
  names beside the source (`copyName`), an existing destination skipped
  with a toast, a cut pasted home a no-op that keeps the clipboard, a
  folder into itself refused — and hands them to ONE background
  transfer. `file.duplicate` is a copy to `copyName` beside each target.
- `// changed (app):` `App.transfers: transfers.State{ group: Io.Group,
  jobs, next_id }` (`src/app/transfers.zig`); `AppEvent.transfer:
  *transfers.Event{ id, msg: total | progress | done | failed |
  cancelled }`, `Source.transfer`, destroyed by `transfers.handle` on
  every path (D1). `transfers.start(app, kind, items) !u64` copies the
  items for the worker and returns at once; the worker sizes first
  (`total`), credits per file (`progress` at most every 32 files), and a
  move on one filesystem is a rename. A cancel (`transfer.cancel_all`,
  or `State.deinit`) is a flag read between files; what THIS transfer
  created is removed, recorded per entry only when it was not already
  there. `transfers.clash` refuses a second paste into a tree one is
  still writing. `App.transfersRunning()`; `nextDeadlineMs` keeps a
  frame due every 80 ms while one runs.
- `// changed (ui):` `render.drawStatusline` gains `transfer_seg`
  between the AI meter and the bell: `⇄ 42% 3.1M/s` (`⇄2 …` for two,
  `sizing…` first, `<>` in ASCII), nothing at rest. A focused Files pane
  puts `FILES` (or `TRASH`) in the mode chip and its directory, cursor
  row and count in the file / line segments.
- `// changed (app):` `ex.zig` — the `:qa` guard, one delimited block
  (`── files: the :qa transfer guard ──` … `── end files ──`): with
  transfers running `:qa` fails with a toast naming `transfer.cancel_all`
  and `:qa!`; `:qa!` quits.
- `// changed (app):` `App.trash: trash.State{ last_prune_ms, bounds }`
  (`src/app/trash.zig`). `trash.dir` is `<data root>/trash/<wyhash of
  the workspace>/` (`<workspace>/.mnml/trash` with no data root); the
  origin index is `<that dir>.index.zon` beside it. `ConfirmPurpose.
  delete_path: []u8` became `delete_paths: DeletePaths{ paths: [][]u8,
  permanent_only }` plus `empty_trash`; `dispatch.acceptConfirm` routes
  both to `trash.acceptDelete / acceptEmpty`. `trash.confirmDelete(app,
  paths)` builds the three-button confirm (`Delete` / `Delete
  permanently` / `Cancel`, Cancel selected; two buttons inside the
  trash); `trash.deletePaths(app, paths, permanent)` moves each entry to
  `<stamp>-<name>` (a counter within one second), records its origin,
  closes buffers on the path, drops it from `recent`, prunes, and
  refreshes the tree + every Files pane. `tree.acceptDelete` now goes
  through it. `trash.restore` puts an entry back (refuses when the
  origin exists again); `trash.prune(app, now_s, bounds)` enforces the
  age / total / per-entry bounds; `App.tick` calls `trash.tick` (the
  first tick, then every ten minutes).
- `// changed (app):` `PromptPurpose.move_paths: [][]u8` — `file.move_to`
  from a Files pane prompts once for a folder and moves every marked
  path there as one background move (`files_pane.acceptMoveTo`).
- `// changed (app):` `files_pane.refreshAfterFsChange(app)` is the one
  place a filesystem change announces itself (the tree + every Files
  pane). `App.closePane` calls `files_pane.onPaneClosed` so a browser
  forgets a preview pane that closed. `Tree.setExpanded` is `pub`;
  `Tree.pending: ?u8` holds vim's first `y` / `d`.
- `// changed (app):` the tree's Ctrl+X/C/V/D fire in both profiles;
  vim also gets `yy` / `dd` / `P` on the tree and the Files pane
  (`docs/KEYMAP_PROFILES.md`).
- Eighteen Zig-only ids (`files.up / refresh / toggle_hidden /
  cycle_sort / sort_name / sort_size / sort_modified / activate / preview
  / mark_toggle / mark_all / mark_invert / mark_clear / copy_path /
  new_file / new_folder / destinations / empty_trash`); the pin is 854
  (836 after the `misc` merge + 18).
  `docs/commands.md` regenerated.
- Not done, by design: the destinations picker's volumes / recents
  sections; an editor breadcrumb row (its PARITY row stays partial).
## Panels + dock (2026-09-05, branch `panels`) — `// changed:` notes

- `// changed (D8):` three more modules on the `todos.zig` shape —
  `src/notes.zig`, `src/findings.zig`, `src/sessions.zig` — each with
  its scan worker, snapshot arena, `handle`, `pub const table`, a
  `ListPanel` draw and the dispatch prongs. `AppEvent` gains `.notes`,
  `.findings`, `.sessions`, `.dock` (all owned, adopted-or-freed);
  `Source` gains the same names. All four tables — and `findings.zig`
  in particular, which the first cut left out — are listed in
  `command.runner_tables`; the e2e driver swallows a failed runner by
  design, so a panel's unit tests now run at least one of its
  commands through `command.run`.
- `// changed (todos):` `ui.todo_keywords` is the marker list (a
  custom word paints as `.custom`); the `.fixme(` / `.fail(` / `.skip(`
  scan is always on. `todos.mark_done` rewrites the marker to `DONE`
  (a test call loses its `.fixme`); `todos.fix_with_agent` /
  `open_claude` / `open_codex` hand the marker to a pty. The watcher
  queues a rescan 500 ms after the last change (`noteFileChanged` /
  `tick`); `App.nextDeadlineMs` knows about it.
- `// changed (notes):` a note is `<ws>/.mnml/notes/*.md`; the title
  is the first heading, else the first line. `notes.new` seeds the
  next free `note-N.md`; `PromptPurpose.new_note` / `new_finding` carry
  the directory. The `open` and `save_post` hooks rescan a used panel;
  `tree.acceptDelete`'s confirm calls `onPathRemoved`.
  `list_panel.paintSpinner` and `ageText` are shared by every panel.
- `// changed (findings):` frontmatter `severity:` / `status:` (with
  the `SEV-n` / `Sn` / `Pn` / blocker / fixed / wontfix aliases), or a
  bare `Severity:` / `Status:` line in the first forty lines. Sort
  ties break by severity. `findings.resolve` rewrites `status:
  resolved` in place (`setStatusInText` adds the line or the block).
  `findings.new` writes the frontmatter template before the tree
  opens the file. Header: `(N open of M)`.
- `// changed (sessions):` SESSIONS lists the transcripts
  `agents.scanInto` reads (`~/.claude/projects`, `~/.codex/sessions`),
  narrowed to this workspace by cwd / label; `w` widens. The axis is
  `Config.SessionsSort` (State / Manual) — the sort menu names
  `sessions.sort_auto` / `sort_manual`, so `MenuAction` did not grow.
  `needs_approval` = a live session whose last tool use has no result
  and whose file has gone quiet — ranked first. Aliases and the manual
  order live in `State.aliases` / `order` and round-trip through
  `session.zon` (`sessions_aliases`, `sessions_order`);
  `session.parse` needed `@setEvalBranchQuota(8000)`.
  `PromptPurpose.sessions_rename`, `ConfirmPurpose.delete_session`
  (an absolute transcript path). A shown panel rescans every 3 s. The
  `.test` runner's apps have no home: the panel says so instead of
  scanning; `State.home` lets a test point at a fixture.
- `// changed (ui):` the header ladder is now: full chip + count →
  icon + count → full chip alone → icon alone → no chip. The first
  cut only dropped the count when the refresh chip needed the room,
  so a wide count deleted the sort chip at the shipped width (the
  Rust bug the header's comment describes). FINDINGS' full chip with
  its count needs 49 cells; at the default 40 the count sits beside
  the icon. Break-checked ("a wide subtitle gives way to the chip").
- `// changed (dock, core):` `src/core/dock.zig` holds `Corner`,
  `Placement { overlay, @"inline" }`, `Opacity`, `Size` (five presets
  as percentages, 15–90 clamp) and `Setting`; `MenuAction.dock_set{
  id, setting }` is what a kebab row carries. `HitTarget.dock{ id,
  part: DockPart { body, title, kebab, close } }` — `rects.json`
  labels read `dock:<id>:<part>`. `Drag.dock: DockDrag{ id, x, y,
  moved }`. `PromptPurpose.dock_new_text` / `dock_new_log` (a
  `Corner`), `dock_edit` / `dock_rename` (a widget id).
- `// changed (dock, app):` `App.dock: dock.State`, `App.dock_area`
  (the body before the inline strips came off). `render.zig` takes
  the strips off `panes_area` before `drawBody` and calls `dock.draw`
  after it (never in zen). Overlay widgets stack per corner inside the
  shrunken body, capped at half its height; inline widgets tile their
  strip, each edge capped at a quarter. The tail is a worker in the
  dock's `Io.Group` posting `.dock = *TailResult`; `remove`, `closeAll`,
  `acceptEdit` (a re-pointed path) and `apply` cancel the group before
  freeing what a worker borrows. `dock.tick` starts one read per widget
  per second; `nextDeadlineMs` keeps a clock and a tail ticking.
  `Translucent` blends rgb grounds at 45 % (`dock.blend`) and leaves
  indexed / default cells as they were; the text is written over the
  blend cell by cell. Drop: within `snap_cells` (8) of another
  widget's centre → its corner, inserted beside it (above / below by
  the pointer, which for a bottom corner means after / before in the
  list); else the quadrant. `session.Saved.dock` / `dock_hidden`.
  The `+` menu's Dock ▸ group is Rust's (Note / Log tail). Six ids
  beyond the Rust seven: `dock.toggle` / `add` / `add_preset` (a
  `.custom` picker) / `remove` / `edit` / `rename`. Pin 857.
- Not done, by design: the `⟳` chip's right-click menu and
  `ui.auto_refresh_off` (every panel's chip is a left-click rescan);
  the Rust SESSIONS strip's per-row transcript summary lines, bells
  and ticket detection; the clock is UTC (no `localtime` in std).

## EDITOR / EX tier — `// changed:` notes (2026-09-05, branch `editor-ex`)

The full row-by-row account was `docs/parity-notes/editor-ex.md` (its
rows now stand in `docs/PARITY.md`, `5498f872`); this is the
contract-level list of what moved.

- `// changed (config):` `Config.Editor.clipboard: Clipboard = .auto`
  (`.auto | .os | .internal`). Rust routed the unnamed register through
  arboard unconditionally; here only `"+` / `"*` and the standard
  profile's Ctrl+C / X / V reach the OS, and a headless / `.test` run
  never does. `:set clipboard=…` re-selects the sink at runtime.
- `// changed (core):` `src/core/clipboard_os.zig` — `Sink{ none, osc52,
  tool }`, `select(mode, live_writer, tool)`, `probe(io, env)` (stats
  `$PATH` only), `writeOsc52`. The tool pair per platform: pbcopy /
  pbpaste, wl-copy / wl-paste, xclip, xsel, clip.exe / Get-Clipboard.
- `// changed (editor):` `Clipboard.attach(io, writer, tool, mode)` /
  `selectMode`; a `"+` / `"*` write lands in the unnamed register first,
  then the sink; a read asks the sink and falls back. OS text is
  linewise on a trailing newline (vim's rule; Rust was charwise).
  `Clipboard.macros` / `last_macro` / `putMacro` / `macro`: macro
  registers moved off `Buffer` (D4 said buffer state; that made them
  per-file). `Buffer` keeps only the recording in flight.
- `// changed (input):` `input.Config.use_tabs`; `InputHandler.configure`
  re-reads the scalars after construction. The standard profile's
  Ctrl+C / X / V emit `set_register_hint = '+'`. Vim's `.window` prong
  binds `H J K L = r _ | + - > < n d f` (it swallowed everything but
  `w q c s v o h j k l`). `s<a><b>` arms flash labels through
  `AppCommand.flash_start` as before; the interception of the label key
  is `flash.interceptKey` at the top of `dispatch.key`.
- `// changed (tui):` `src/tui/loop.zig` attaches the session's buffered
  writer and the probed tool one line after `App.initWith` — OSC 52 goes
  out between frames through the writer `term.render` already uses.
- `// changed (ui):` `editor_view.Doc.labels: []const Label{ byte, text }`
  — one delimited block in the cell loop paints a one-cell label over
  the glyph at a byte, so the label is exactly the cell the byte
  occupies under wrap, folds, tabs and wide glyphs. `render.drawFlashCue`
  paints `ab → press a label to jump · Esc cancels` on the pane's last
  row in `theme.current_match`. `ListPane.Kind.location` is a third list
  kind under its own header, the quickfix row layout otherwise.
- `// changed (app):` `App` state: `flash: ?flash.State`, `global_marks`,
  `user_commands`, `last_shell_cmd`, `shell_pane`, `last_substitute`,
  `replace_confirm`, `ex_depth`, `in_global`; `ConfirmPurpose.replace_confirm`.
  `EditorPane.loclist` / `loc_idx`. Hooks: `ex_verbs.onStartup`
  (`commands.zon`), `macros_store` and `marks_store` on `startup` /
  `exit`. `closeOverlay` cancels a `:s///c` in flight. `setActive`
  cancels flash.
- `// changed (app):` `src/app/ex_verbs.zig` holds every verb that
  reaches past one line — `ex.zig` parses the range and verb and hands
  the rest over in one delimited block of dispatch lines. `:g` keeps
  line numbers right by remapping line-start bytes through
  `Editor.edits` after each command (not vim's per-line marks); a
  wholesale `setText` stops the loop with a toast. `:norm` types through
  `App.handle` with an Esc after each line and needs `<esc>` notation
  (the `:` line cannot carry a raw Esc). `:command` persists per data
  root. `:!` writes to a reused scratch pane; `:[range]!` filters; `:r
  !cmd` inserts. `:s///c` is the confirm overlay (`y n a q l`, Esc keeps
  what was done); `:s///n` counts; `:&` / `:&&` / a bare `:s` repeat.
  Matching is plain substring — `TODO(regex)` marks where the search
  track's engine plugs in (`scanMatches`, `lineHas`).
- `// changed (app):` global marks live in `<data root>/marks.zon` (Rust:
  the per-workspace session file) — `'A` reaches the same place from any
  workspace; `'A` is also an ex address (E20 in another file).
  Uppercase `m` / `'` / `` ` `` bubble out of `Buffer.handleApp` as
  `.app` and land in `dispatch.handleAppCommand`.
- `// changed (app):` `Layout.moveToEdge(pane, edge)` detaches the
  pane's leaf (or the pane alone, when it shares a leaf) and re-hangs it
  as one half of a new root split; `view.move_split_*` are its runners.
- `// changed (editor):` `src/editor/editorconfig.zig` — the walk, the
  parser, the spec's glob (`*`, `**`, `?`, classes, nested braces,
  `{n..m}`, slash-anchoring). `Buffer` gains `trim_trailing_ws_on_save`,
  `eol`, `indent_unit`, `applyEditorconfig`, `setIndent`; `load`
  normalises CRLF / CR to LF and remembers, `save` trims (one undo
  step, cursor kept), fixes the final newline, and writes the
  remembered / configured EOL. `Editor.use_tabs` drives `line.indent`.
  `App.applyBufferPrefs` runs on every open / scratch / duplicate: the
  config's `trim_trailing_ws_on_save` and `ensure_trailing_newline`
  (both unread before this branch) seed the buffer, then the file's
  `.editorconfig` overrides. `Buffer.setInputStyle` re-applies the
  file's indent to the rebuilt handler — `editor.use_vim` used to reset
  it to the config's.
- `// changed (tools):` `tools/break-check.sh` with a filter that starts
  with `:` matches nothing and prints "still passes" — the tool is not
  in this branch's file list; use a colon-free substring.

---

## LSP, more (Phase 5 follow-up) — `// changed:` notes (2026-09-05, branch `lsp-more`)

- `// changed (ui):` `editor_view.Doc` gains `virtual_text:
  []const VirtualText` (`{ byte, text, style }` — cells painted BEFORE
  the grapheme at `byte`, taking columns but no bytes; `byte == line
  end` paints after the last grapheme; a click on them lands on `byte`)
  and `virtual_lines: []const VirtualLine` (`{ line, segments }` — a row
  painted ABOVE `line`, counted in the scroll math and the
  keep-cursor-visible pass; a segment with a `hit` registers
  `.script_hit{ pane, hit }`). One delimited block; the view knows
  nothing of hints or lenses.
- `// changed (highlight):` `engine.layerSpans(T, arena, base, over)` is
  the one merge for two sorted span lists: `over` wins where it covers,
  `base` keeps every byte `over` leaves alone. Semantic tokens paint
  OVER the grammar, never instead of it; `lsp_decor.mergeUnderlines`
  uses the same function to let a diagnostic's squiggle win a link.
- `// changed (app):` `App.lsp` gains `decor` (`FileDecor` per absolute
  path: four replace-wholesale sets — hints, lenses, colours, links —
  each tagged with the edit-log seq its reply describes; a set whose seq
  no longer matches the buffer is NOT painted, stale hints beside moved
  text being worse than none), `decor_track` (per pane: the seq last
  asked for, the debounce clock, the hint window), `semantic` (`SemFile`
  per path: raw `data[]`, `resultId`, decoded tokens, seq), `lint_group`
  and `rename`. `lsp_decor.onFrame` runs from `render.drawEditor` after
  `syncPane`: every set refreshes once the buffer has been idle 250 ms,
  the hints also when the view leaves their window (visible lines ±1
  screen). Requests carry the seq's low word in `Ctx.extra`.
- `// changed (app):` a code lens row's segments register
  `.script_hit{ pane, lens_hit_base + index }` (`0x4C45_0000`, far above
  http's `var_hit_base`); `dispatch`'s editor `.script_hit` arm splits
  on it. Enter in vim's Normal mode on a line that carries a lens runs
  it (`decor.interceptKey`, reached from `lsp.interceptKey` when no popup
  is up); Insert / standard-mode Enter stays a newline — the lens is a
  click or `lsp.code_lens_run` there. A lens without a `command` goes
  through `codeLens/resolve` first; the resolved title lands on the set.
- `// changed (app):` `gx` / `editor.open_url_at_cursor` answers with
  the server's document link under the cursor, else a `scheme://` token
  on the line (`decor.urlAt`); the OS opener is `open` / `xdg-open` /
  `cmd /c start`.
- `// changed (app):` semantic tokens ask `full/delta` when a `resultId`
  is held and the server takes deltas, `full` otherwise, `range` (the
  visible lines ±1 screen) when that is all it offers — a range reply
  marks the cache `partial` so the next ask is not a delta. The legend
  is decoded once at `initialize` into `Caps.token_types: []Role` /
  `token_modifiers: []Modifier` (owned by `Caps`, which now has a
  `deinit`). No theme names modifier styles, so the mapping is fixed:
  `declaration` bold, `static` italic, `deprecated` struck through,
  `documentation` in the comment colour. `editor.semantic_tokens` is a
  new master switch (the Rust config had only
  `semantic_tokens_viewport`, which stays parsed and unused).
- `// changed (app):` `willSaveWaitUntil` cannot hold the write: the
  `save_pre` hook is fire-and-forget and no server is ever awaited (D3).
  Behind `editor.will_save_wait_until` the request goes out before the
  write; the reply's edits are applied and the buffer written again, so
  the disk is right within a round-trip. On-type formatting runs behind
  `editor.format_on_type` on the server's trigger characters
  (`Caps.on_type_triggers`, owned). `lsp.format_selection` is range
  formatting on the visual selection.
- `// changed (app):` `lsp.format` (and `editor.format`, which aliases
  it) prefers the attached server and falls back to the external tool
  (`lsp_format.formatDocument`); `editor.format_external` is always the
  tool; format-on-save uses the tool when no server formats. The tool
  table is `src/lsp/tools.zig`: `.formatters.<ext>` / `.linters.<ext>`
  override a builtin list (rustfmt, prettier, ruff, gofmt, shfmt,
  stylua, `zig fmt --stdin`, nixfmt; eslint, ruff, shellcheck). `{file}`
  in an argument becomes the workspace-relative path. `Formatter.in_place`
  is new (the Rust formatter was stdin → stdout only): the buffer is
  written, the tool runs on `{file}`, the result is read back. A run is
  synchronous so a save-time format lands before the write; the whole
  text is one splice trimmed to the changed middle (`replaceWhole`), one
  undo step, cursor kept.
- `// changed (app):` external linters run on a worker in
  `app.lsp.lint_group` on open and on save (`lintOnHook`; a builtin tool
  that is not on PATH is skipped without a spawn) and on
  `editor.lint_external` (refuses a dirty buffer). The worker posts its
  findings as a `textDocument/publishDiagnostics` notification on the
  `.lsp` lane with `server = 0` (`linter_server_id`; real servers start
  at 1) — workers never touch app state (D3). `FileDiags` keeps two
  sources (`server_items` on `arena`, `lint_items` on `lint_arena`),
  each replaced wholesale by its own next delivery, merged sorted into
  `items` for every reader. `Linter.parser = .pattern` with
  `Linter.pattern` (a template of `{file} {line} {col} {severity}
  {message} {_}` placeholders matched literally between them) replaces
  the Rust `regex` option — Zig's std has no regex, and a linter's line
  format is fields in a fixed order.
- `// changed (app):` the rename preview (`src/app/lsp_rename.zig`) is
  `app.lsp.rename` state like the peek overlay, not an `Overlay`
  variant: its rows register `.overlay_item(row)` while no overlay is
  up (`dispatch` routes those to `rename_app.click` before the
  completion popup), and `lsp.interceptKey` gives it the keys first.
  `handleResponse(.rename)` opens it when the `WorkspaceEdit` touches
  more than one file (`rename_app.fileCount`); one file still applies at
  once. Space / `x` toggles the row's file, `a` all, `j`/`k` move,
  Enter applies, Esc / `q` cancels. Applying: an open buffer takes its
  edits through `lsp.applyEditsToPane` (one undo step, dirty, synced on
  the next frame); a closed file is read, spliced last-first and written
  back, refused with a toast when its end line is gone or its end column
  is past the line as it now reads on disk. Not done, by design: the
  Rust overlay that repaints every whole-word occurrence while the
  prompt is open — the box's hunk rows show `Lnn  before → after`.
- `// changed (spec):` `lsp.format_selection` and `lsp.code_lens_run`
  are new ids (the pin is 883); `editor.format_external`,
  `editor.lint_external` and `editor.open_url_at_cursor` had specs and
  no runner (a `-Dpartial` build let them through) and are runners now,
  all in `cmd_lsp.zig`'s table. `lsp.inlay_hints_toggle` moved to
  `lsp_decor.zig` and paints.
- `// changed (test):` `lsp.TestRig` wires the scripted server into an
  `App` for the app-side modules' tests (`start` / `stop` / `openFile`
  / `pump`, which ticks AND renders — the decorations are asked for
  from the frame, so a wait that never paints never asks); the fake
  server answers every request of this tier and announces a
  `workspace/executeCommand` as a `window/showMessage` warning so the
  toast proves it ran. A rename whose new name starts `multi` also
  touches `/tmp/mnml-zig-fake-lsp-other.ts`.
- `// changed (test):` a file's tests reach `-Dtest-filter` (and so
  `tools/break-check.sh`) only when a `test {}` block references the
  file; a file-scope `@import` puts them in the full suite but not in
  front of the filter, and a break-check against such a file reports
  "still passes" while running nothing. `src/app/lsp.zig` ends with a
  `test {}` naming the four `lsp_*.zig` modules, `lsp/semantic.zig` and
  `lsp/tools.zig`. A new module with tests needs the same line
  somewhere on the `test {}` chain from `main.zig`.
## Git, more (Phase 4 follow-up) — `// changed:` notes (2026-09-05, branch `git-more`)

- `// changed (ui):` `diff_view` has three views. `Doc` gains `shown` /
  `split_rows` / `split_shown` (the filter's index lists), `mode`,
  `filter` / `filter_mode`, `ratio` and `intraline`; `draw` returns
  `Painted{ body, strip_cells }` for the app's drag and strip clicks.
  `flatten` is unchanged; `pairs` aligns a removed run with the added
  run after it (the longer tail against a filler); `filterRows` /
  `filterSplitRows` keep every row of a hunk holding the needle plus its
  file header; `density` folds row kinds into bands for the strip on
  the right edge (the visible window is its thumb). Rows register
  `.script_hit{ pane, id = row }`; the chips, the divider, the filter
  banner and the strip cells use ids above `special_base`
  (`chipId`, `divider_id`, `filter_id`, `stripId`). Intraline ranges
  come from `src/git/intraline.zig` (prefix / suffix peel, then an LCS
  table capped at 64 K cells; ranges snap to UTF-8 edges) for a lone
  `-` directly followed by a lone `+`.
- `// changed (app):` `DiffPane` keeps `mode`, `full` (the loaded diff
  carries every line — Inline and Split ask the worker for `-U999999`
  through `Job.diff.full`), `ratio`, the owned `shown` / `split_shown`,
  the `/` filter buffer and `body` / `strip_cells` from the last frame.
  `git.setDiffMode` carries the cursor's hunk across the two row lists
  and refetches when the context depth changes; `stepDiff` / `diffHome`
  / `moveHunk` / `moveFile` walk the shown rows; `diffClick` routes
  chips / divider / strip / banner / rows; `Drag.git_divider` drags the
  split. `git.State.diff_mode` remembers the last view for new panes.
  Two Zig-only ids: `git.diff_toggle_view`, `git.diff_filter`.
- `// changed (git):` `src/git/remote.zig` is the pure remote-URL
  module: `parseRemote`, `providerOf`, `fileUrl(…, line: ?u32)`,
  `commitUrl`; it replaces `client.browseUrl`. GitHub (and enterprise
  hosts), GitLab (any host naming it), Bitbucket Cloud and Server
  (`/scm/PROJ/repo` → `/projects/PROJ/repos/repo`), Azure DevOps
  (`dev.azure.com`, `*.visualstudio.com`, the `ssh.dev.azure.com:v3/…`
  form) each get their own shape; an unknown host gets GitHub's.
  `Job.browse` is `{ kind: file | line | commit, path, line, rev }`.
  The `.status` payload carries `remote` (`remote.origin.url`), kept in
  `git.State.remote` / `provider`; the status pane's header paints the
  badge (`status_view.badge_id`, a click runs `git.browse_commit`) and
  the rail subtitle names the forge. `git.openExternal` hands a plain
  http(s) URL to `open` / `xdg-open` / `cmd /c start`; the `.url`
  result goes through it and is toasted.
- `// changed (git):` `for-each-ref` spells its hex escape `%1f`; the
  `%x1f` in `parse.ref_format` was coming out literally, so every branch
  row was one unsplit field (the picker showed the raw line). Fixed on
  this branch; `ref_format` also carries `%(upstream:track,nobracket)`,
  read by `parse.parseTrack` into `Branch.ahead / behind / gone`.
- `// changed (ui):` `git_graph_view.Doc` walks *virtual* rows: the WIP
  row first when `has_wip`, then `commits` in `order` (from `sortOrder`
  under `Sort{ col, asc }`; off git's order the lanes fold to a dot). A
  column-chip row (`GRAPH / DATE / AUTHOR / SUBJECT`, `sortId`) sits
  under the title. `Doc.detail: ?DetailDoc` paints the right panel
  (`detail_w` wide, min 60-column body; a commit's title, its message
  wrapped, `files (n)` with `detailRowId` hits — or the working tree's
  entries with the staging buttons); `divider_id` is the drag handle.
  The WIP row registers its row hit *before* its buttons (`wipButtonId`)
  so the buttons win the click. `findByHashPrefix` is the prompt's
  resolver. `draw` returns `Painted{ body, list, detail }`.
- `// changed (app):` `GraphPane` gains `order`, `sort`, the detail
  (`detail_arena`, `detail`, `detail_pending / open / focus / cursor /
  w`), `has_wip` / `wip_known` and `body`. `syncWip` (on every status
  result, key, click and paint) shows or drops the WIP row and shifts
  the cursor so it keeps its commit — except the first status a pane
  sees, which leaves the cursor on the top row. `Job.commit_detail`
  (`show -s --format=%B` + `diff-tree --root --name-status`) lands in
  `.commit_detail`; a stale one re-asks for the commit the cursor moved
  to. Keys: enter opens the detail, tab focuses it (j/k over the files,
  enter opens that file's diff in the commit, esc / tab back), `d` the
  commit's diff, `s` cycles the sort, `/` the hash prompt
  (`PromptKind.graph_hash`); on the WIP row `a` / `A` / `c` stage all /
  unstage all / commit, elsewhere `c` cherry-picks. `graphClick` routes
  chips, buttons, divider, detail rows and list rows (right → the
  commit menu); `Drag.graph_divider`. Three Zig-only ids:
  `git.graph_detail`, `git.graph_sort`, `git.graph_jump_hash`. The
  detail width is `[ui] git_graph_detail_col` (default 40) until dragged.
- `// changed (app):` the branch rail lives in the GIT rail's own list:
  `status_view.Row` gains `kind` (`status | section | branch | worktree
  | pr | note`), `detail`, `current`, `remote`, `section`, `folded`;
  `appendRailRows` adds three folding sections (`▾ Branches (n)`,
  Worktrees, Pull requests) after the status groups when
  `State.rail_open`. The data is one `Job.rail{ gh }` → `.rail` result
  (branches with tracking counts, `worktree list --porcelain`, and `gh
  pr list --json number,title,headRefName,url` when the UI found `gh`
  on PATH — otherwise a one-time toast), adopted into
  `State.rail_snapshot`. Enter on a branch asks before checkout
  (`Confirm.checkout`), `x` before delete, enter on a PR opens it,
  `n` prompts a new branch, `b` toggles the rail, `r` refreshes it too;
  right-click on a rail row opens the Branches menu. One Zig-only id:
  `git.branch_rail_toggle`.
- `// changed (app):` AI commit messages go through the AI track's job:
  `ai.askProduct(app, product, …)` (the one `// ── git ──` block in
  `src/app/ai.zig`; `ask` is now its `.claude` wrapper) starts a
  `claude -p` / API / `codex exec` job and its `Pane.ai`. `git.askAi`
  first asks the worker for the text (`Job.ai_context = .staged |
  .head` → `.ai_context{ diff, message }`, no git on the UI thread),
  builds the prompt in `aiContextReady`, and records `State.ai_wait`;
  `git.tick` → `pollAiWait` watches the pane: `.done` closes it and
  opens the commit prompt (or the amend prompt, `PromptKind.amend` →
  `Job.amend` with an undo entry) with the subject line, keeping a body
  in `State.ai_body` for the accept; `.failed` toasts the AI track's
  reason and closes it. A missing key / an off route fails fast in
  `askProduct` with its own message; Codex's `api` route is refused.
  `git.ai_recompose` on an open commit prompt recomposes from the
  staged diff instead of amending. `git.overlayClosing` (called from
  `dispatch.closeOverlay`) drops a body whose prompt was dismissed.
- Not done, by design: the Rust WIP detail's multi-line commit
  textarea (the prompt line plus the attached body covers the flow);
  the Rust rail's `/`-prefix folder grouping and its stashes / tags
  sections (the pickers cover both).

## LSP, more (Phase 5 follow-up) — `// changed:` notes (2026-09-05, branch `lsp-more`)

- `// changed (ui):` `editor_view.Doc` gains `virtual_text:
  []const VirtualText` (`{ byte, text, style }` — cells painted BEFORE
  the grapheme at `byte`, taking columns but no bytes; `byte == line
  end` paints after the last grapheme; a click on them lands on `byte`)
  and `virtual_lines: []const VirtualLine` (`{ line, segments }` — a row
  painted ABOVE `line`, counted in the scroll math and the
  keep-cursor-visible pass; a segment with a `hit` registers
  `.script_hit{ pane, hit }`). One delimited block; the view knows
  nothing of hints or lenses.
- `// changed (highlight):` `engine.layerSpans(T, arena, base, over)` is
  the one merge for two sorted span lists: `over` wins where it covers,
  `base` keeps every byte `over` leaves alone. Semantic tokens paint
  OVER the grammar, never instead of it; `lsp_decor.mergeUnderlines`
  uses the same function to let a diagnostic's squiggle win a link.
- `// changed (app):` `App.lsp` gains `decor` (`FileDecor` per absolute
  path: four replace-wholesale sets — hints, lenses, colours, links —
  each tagged with the edit-log seq its reply describes; a set whose seq
  no longer matches the buffer is NOT painted, stale hints beside moved
  text being worse than none), `decor_track` (per pane: the seq last
  asked for, the debounce clock, the hint window), `semantic` (`SemFile`
  per path: raw `data[]`, `resultId`, decoded tokens, seq), `lint_group`
  and `rename`. `lsp_decor.onFrame` runs from `render.drawEditor` after
  `syncPane`: every set refreshes once the buffer has been idle 250 ms,
  the hints also when the view leaves their window (visible lines ±1
  screen). Requests carry the seq's low word in `Ctx.extra`.
- `// changed (app):` a code lens row's segments register
  `.script_hit{ pane, lens_hit_base + index }` (`0x4C45_0000`, far above
  http's `var_hit_base`); `dispatch`'s editor `.script_hit` arm splits
  on it. Enter in vim's Normal mode on a line that carries a lens runs
  it (`decor.interceptKey`, reached from `lsp.interceptKey` when no popup
  is up); Insert / standard-mode Enter stays a newline — the lens is a
  click or `lsp.code_lens_run` there. A lens without a `command` goes
  through `codeLens/resolve` first; the resolved title lands on the set.
- `// changed (app):` `gx` / `editor.open_url_at_cursor` answers with
  the server's document link under the cursor, else a `scheme://` token
  on the line (`decor.urlAt`); the OS opener is `open` / `xdg-open` /
  `cmd /c start`.
- `// changed (app):` semantic tokens ask `full/delta` when a `resultId`
  is held and the server takes deltas, `full` otherwise, `range` (the
  visible lines ±1 screen) when that is all it offers — a range reply
  marks the cache `partial` so the next ask is not a delta. The legend
  is decoded once at `initialize` into `Caps.token_types: []Role` /
  `token_modifiers: []Modifier` (owned by `Caps`, which now has a
  `deinit`). No theme names modifier styles, so the mapping is fixed:
  `declaration` bold, `static` italic, `deprecated` struck through,
  `documentation` in the comment colour. `editor.semantic_tokens` is a
  new master switch (the Rust config had only
  `semantic_tokens_viewport`, which stays parsed and unused).
- `// changed (app):` `willSaveWaitUntil` cannot hold the write: the
  `save_pre` hook is fire-and-forget and no server is ever awaited (D3).
  Behind `editor.will_save_wait_until` the request goes out before the
  write; the reply's edits are applied and the buffer written again, so
  the disk is right within a round-trip. On-type formatting runs behind
  `editor.format_on_type` on the server's trigger characters
  (`Caps.on_type_triggers`, owned). `lsp.format_selection` is range
  formatting on the visual selection.
- `// changed (app):` `lsp.format` (and `editor.format`, which aliases
  it) prefers the attached server and falls back to the external tool
  (`lsp_format.formatDocument`); `editor.format_external` is always the
  tool; format-on-save uses the tool when no server formats. The tool
  table is `src/lsp/tools.zig`: `.formatters.<ext>` / `.linters.<ext>`
  override a builtin list (rustfmt, prettier, ruff, gofmt, shfmt,
  stylua, `zig fmt --stdin`, nixfmt; eslint, ruff, shellcheck). `{file}`
  in an argument becomes the workspace-relative path. `Formatter.in_place`
  is new (the Rust formatter was stdin → stdout only): the buffer is
  written, the tool runs on `{file}`, the result is read back. A run is
  synchronous so a save-time format lands before the write; the whole
  text is one splice trimmed to the changed middle (`replaceWhole`), one
  undo step, cursor kept.
- `// changed (app):` external linters run on a worker in
  `app.lsp.lint_group` on open and on save (`lintOnHook`; a builtin tool
  that is not on PATH is skipped without a spawn) and on
  `editor.lint_external` (refuses a dirty buffer). The worker posts its
  findings as a `textDocument/publishDiagnostics` notification on the
  `.lsp` lane with `server = 0` (`linter_server_id`; real servers start
  at 1) — workers never touch app state (D3). `FileDiags` keeps two
  sources (`server_items` on `arena`, `lint_items` on `lint_arena`),
  each replaced wholesale by its own next delivery, merged sorted into
  `items` for every reader. `Linter.parser = .pattern` with
  `Linter.pattern` (a template of `{file} {line} {col} {severity}
  {message} {_}` placeholders matched literally between them) replaces
  the Rust `regex` option — Zig's std has no regex, and a linter's line
  format is fields in a fixed order.
- `// changed (app):` the rename preview (`src/app/lsp_rename.zig`) is
  `app.lsp.rename` state like the peek overlay, not an `Overlay`
  variant: its rows register `.overlay_item(row)` while no overlay is
  up (`dispatch` routes those to `rename_app.click` before the
  completion popup), and `lsp.interceptKey` gives it the keys first.
  `handleResponse(.rename)` opens it when the `WorkspaceEdit` touches
  more than one file (`rename_app.fileCount`); one file still applies at
  once. Space / `x` toggles the row's file, `a` all, `j`/`k` move,
  Enter applies, Esc / `q` cancels. Applying: an open buffer takes its
  edits through `lsp.applyEditsToPane` (one undo step, dirty, synced on
  the next frame); a closed file is read, spliced last-first and written
  back, refused with a toast when its end line is gone or its end column
  is past the line as it now reads on disk. Not done, by design: the
  Rust overlay that repaints every whole-word occurrence while the
  prompt is open — the box's hunk rows show `Lnn  before → after`.
- `// changed (spec):` `lsp.format_selection` and `lsp.code_lens_run`
  are new ids (the pin is 883); `editor.format_external`,
  `editor.lint_external` and `editor.open_url_at_cursor` had specs and
  no runner (a `-Dpartial` build let them through) and are runners now,
  all in `cmd_lsp.zig`'s table. `lsp.inlay_hints_toggle` moved to
  `lsp_decor.zig` and paints.
- `// changed (test):` `lsp.TestRig` wires the scripted server into an
  `App` for the app-side modules' tests (`start` / `stop` / `openFile`
  / `pump`, which ticks AND renders — the decorations are asked for
  from the frame, so a wait that never paints never asks); the fake
  server answers every request of this tier and announces a
  `workspace/executeCommand` as a `window/showMessage` warning so the
  toast proves it ran. A rename whose new name starts `multi` also
  touches `/tmp/mnml-zig-fake-lsp-other.ts`.
- `// changed (test):` a file's tests reach `-Dtest-filter` (and so
  `tools/break-check.sh`) only when a `test {}` block references the
  file; a file-scope `@import` puts them in the full suite but not in
  front of the filter, and a break-check against such a file reports
  "still passes" while running nothing. `src/app/lsp.zig` ends with a
  `test {}` naming the four `lsp_*.zig` modules, `lsp/semantic.zig` and
  `lsp/tools.zig`. A new module with tests needs the same line
  somewhere on the `test {}` chain from `main.zig`.

## UI & theming (Phase 8 follow-up) — `// changed:` notes (2026-09-05, branch `ui-polish`)

- `// changed (ui):` `statusline.Info.right` is `[]const Seg` — text,
  an optional hit id, an optional style and a `low` flag. Every
  right-hand segment with an id registers `.statusline_seg`; the input
  style chip has its own (`seg_input_style`); `Info.restricted` paints
  the `RESTRICTED` chip after the file name (`seg_restricted`). Low
  segments sit outside the input-style chip and drop before it, so the
  keymap chip survives at 48 cells with the indent, encoding and idle
  bell chips present. The app's ids start at `seg_app_base`
  (`render.SegId`, `transfer` included — a right-click is
  `transfer.cancel_all`) and end below `seg_dyn_base`, where the
  `misc` branch's host lanes (`dyn_left` / `dyn_right`) live; both
  coexist in one `draw`.
- `// changed (app):` the bell is always drawn — `○` in muted when
  nothing is unread; `messages.bellSegment` is unchanged. Two chips on
  a text buffer: indent (`⇥ 4`, click → `editor.set_tab_width`, a
  prompt) and encoding (`utf-8`).
- `// changed (app):` `App.toast_ctx` carries the right-clicked toast's
  index to `toast.dismiss_clicked` / `toast.copy_clicked`; `App.undo_chip`
  (`armUndo` / `takeUndo` / `dropUndo`, `undo_chip_ttl_ms`) is the Undo
  offer, painted by `toast.drawUndo` on the toasts' spacer row with the
  `toast.undo_button` hit; `buffer.close_others` / `close_right` arm it
  with `.reopen = n` (runs `buffer.reopen` n times).
- `// changed (app):` `src/app/workspace_trust.zig` — `workspace.review_trust`
  re-opens the first dialog when untrusted, otherwise a Keep / Forget
  confirm (`ConfirmPurpose.review_trust`) over the claims re-read from
  `.mnml/config.zon` via `config.load.parseLayer` + `trust.claimsWith`;
  `trusted.forget` deletes the store line (`removeEntry`) and
  `reloadConfig(.ask)`. `RESTRICTED` = `loaded.trust_prompt != null`.
- `// changed (core):` `MenuItem` gains `icon: ?[]const u8`, its
  `icon_ascii` twin and `submenu: []const MenuItem` (additive,
  defaulted). `MenuState` gains `curatable` and `sub: ?SubMenu{ parent,
  items (gpa copy), cursor, rect }`; `Overlay.deinit` frees the copy.
  `render.drawMenu` paints the glyph column (`ui/menu_glyph.zig` —
  since the menus pass, Rust's `command_glyph` rule: an action glyph by
  the id's last segment, a domain glyph by its first, the play triangle
  last, each with an ASCII twin under `ui.ascii_icons`; the glyph audit
  holds every site to it), `▸` on a
  parent row, the child beside its parent (`.menu_item{1, i}`), and the
  ⋯ kebab on the focused leaf of a curatable menu (`.menu_item{2, i}` /
  `{3, i}`). Keys: → / l / Enter open a parent, ← / h close the child,
  → on a leaf of a curatable menu opens the curation list.
- `// changed (app):` `context_menus.plus_sections` is the curated `+`
  (New / Open / Panels / Tools / Integrations); `App.plus_pinned` /
  `plus_hidden` are the runtime lists (seeded from `ui.plus_menu_pinned`
  / `plus_menu_hidden`, re-seeded on reload, written back through
  `settings.persist` to the home config); `App.menu_ctx` carries the
  row's command to `menu.pin_row` / `unpin_row` / `hide_row` / `copy_id`.
- `// changed (app):` `src/app/discovery.zig` — `describe(target)` is the
  one source of hover / F1 words; `App.hover_live` (set by `.motion` /
  `.drag`, cleared by a press) gates the hover surfaces so a scripted
  click never grows a box; the rail's `ui.hover_help` box reads the
  previous frame's hits (the rows are reserved before the rail paints)
  and is only reserved while a tip exists. F1 is `view.discovery`
  (`view.help` keeps the palette); the overlay registers no hits, so
  the press under it resolves to the real target, which `explain`
  toasts. Overlay labels live on the frame arena — the cell grid
  borrows the bytes.
- `// changed (app):` `src/image/` — `Transport` (`detect(env, kitty_probe)`),
  `Loaded` (`ensurePng` transcodes through zigimg), `PaintRequest`,
  `kitty` (transmit-by-id, `q=2`, `C=1`, `delete_placements`), `iterm2`,
  `sixel` (decode / fit / 6×6×6 / RLE), `Painter` (owned by
  `tui/loop.zig`, takes the writer — the `tui` module cannot import
  `src/image`). `App.image_transport` is `.none` until the loop sets
  it; `App.image_paints` is reset at the top of `render`.
- `// changed (app):` `Pane.image` (`src/app/image_pane.zig`): a preview
  tab replaced in place by the next image (`PaneStore.findImagePreview`);
  `App.openPath` routes image extensions to it; `view.image_open`
  prompts (`PromptPurpose.image_open`). Header / text-fallback /
  `cellBox` (1:2 cell aspect).
- `// changed (ui):` `md_view.Line.image` / `filler`, `renderWith(…, image_rows)`,
  `drawWith(…, placements)` and `Placement`; `MdPreviewPane.images` caches
  `Loaded` per resolved path; `md_preview.draw` reserves
  `ui.md_image_rows` only when a transport exists.
- `// changed (app):` settings number rows (`RowSpec.number`, `Row.Number`,
  `‹ [v] ›`, `optionHit(id, 0 / 1)` on the arrows) — nine integer
  fields; `ui.right_panel_visible` / `ui.right_panel_width` seed the
  slot at init (the session restore overrides). The config default
  becomes 40 — what `App` already shipped before the key was read, and
  what the panels' header chrome is tuned to; the Rust 32 sizes a
  right panel that never held these panels.
- Spec: nine ids added (pin 901 over main's 892, 47 groups) — `trusted.forget`,
  `toast.dismiss_clicked`, `toast.copy_clicked`, `perf.copy_stress`,
  `menu.pin_row` / `unpin_row` / `hide_row` / `copy_id`,
  `editor.set_tab_width`; `view.discovery` gets `f1`.
- Not done, by design: the clock chip (`ui.clock` stays unread), the
  stress meter's bufferline copy, `menu.glyph_audit`, the encoding
  chip's prompt (utf-8 is the only encoding; a click says so), the Undo
  chip for file deletes (the tree is the panels track's).
## Pty ownership (2026-09-05, branch `pty-race`) — `// changed:` notes

- `// changed (pty):` `Session.deinit` no longer returns with the reader
  still holding the shared block. The reader is still a detached
  `std.Thread.spawn` (D3 — its lifetime is the child's), but `deinit`
  pops its `poll` with a byte down a wake pipe (`Shared.wake`, polled
  beside the master), waits for the reader's `fetchSub`
  (`Shared.awaitReader` — a short spin, then 1 ms naps; nothing on the
  reader's way out blocks), and drops the last reference itself. The
  block is always freed by `deinit`, before it returns, so a
  leak-checked caller can tear its allocator down right after — the
  race the tier-2 golden had been dodging with `sleep 30` (restored to
  `ls -la`; twenty ReleaseSafe runs green, where the previous session
  crashed on the first). The reader copies the pid out before its
  release and does its possibly-blocking `waitpid` after, on the copy;
  `Shared.reaped` is a swap-claimed token so a pid is never waited for
  twice, and the SIGHUP is decided from the session's own `exit`. The
  master fd is closed with the block, not at the reader's EOF (a
  `write` after the child is gone lands on EIO, never on a recycled
  fd). `SpawnError` gains `PipeFailed`. `Options.poll_interval_ms` is
  now only the reader's fallback cadence. `session_windows.zig` waits
  for its reader and watcher the same way (`Shared.awaitThreads`);
  compile-checked for `x86_64-windows-gnu`, untested on a box.
- `// changed (tests):` `session_posix.zig` gains a 200-iteration stress
  test — each session on its own `DebugAllocator`, torn down the
  moment `deinit` returns; half close before the reader has polled,
  half after EOF. Before the fix: 98 of 100 immediate closes released
  late in ReleaseSafe (1 of 100 in Debug). The two existing close tests
  drop the sleeps they used to wait out the reader. Still dodging with
  `sleep 30`, outside this branch's touch list: `tests/e2e/pty_tabs.test`
  and the unit tests in `src/app/cmd_term.zig` / `cmd_buffer.zig` —
  harmless now, and free to shorten.

## Search (Phase 8 follow-up) — `// changed:` notes (2026-09-05, branch `search`)

- `// changed (build):` a regex engine. Oniguruma, reached as a
  sub-dependency of the ghostty dependency already fetched for the
  terminal core (`ghostty_dep.builder.lazyDependency("oniguruma")`), so
  no second copy and no new hash in `build.zig.zon`. `src/regex/regex.zig`
  is the one interface (`Regex.compile(pattern, .{ .ignore_case })`,
  `find(haystack, from)`, `findAll`, `expandReplacement`); nothing
  outside `src/regex/` imports `oniguruma`. Oniguruma's global init is
  an atomic once-hand-off (`ensureInit`) because a compile has no `Io`
  in reach and the in-process grep compiles on its worker thread.
- `// changed (core):` patterns are vim's, not Oniguruma's.
  `src/regex/vim.zig` translates once per compile into a caller buffer
  (`max_pattern = 4096`): the four magic modes, `\{n,m}` / `\{-n,m}`,
  `\(` `\%(` `\|`, `\<` `\>`, the classes and their `\_` forms, `\zs`
  / `\ze` (lookbehind / lookahead), `\@=` `\@!` `\@<=` `\@<!` `\@>`,
  `\1`–`\9`, `\%^` `\%$` `\%d` `\%x` `\%u`, `\c` / `\C`. `\&`, `\%V`,
  `\%#` and the cursor-relative items are `error.Unsupported` and the
  caller toasts which. The conformance table in `regex.zig` is 106
  rows checked against vim's `matchstr()`.
- `// changed (ui):` `find_bar`'s `regex` toggle (`ctrl+r`, the `.*`
  chip, `find.toggle_regex`) now recomputes live and is sticky per
  editor (`Editor.find.regex`); `Editor.find.bad_pattern: ?regex.Error`
  is why a regex query has no matches. `find.replace` / `replace_all`
  in regex mode re-find each match for its groups and expand `&`,
  `\0`–`\9`, `\u \l \U \L \E`. `:s` takes the same pattern and
  replacement grammar (`ex.substitute`, `ex.compilePattern`); so do
  `:g` / `:v` (`ex_verbs.lineHas`), `:s///n` and `:s///c`
  (`ex_verbs.scanMatches` walks the regex per line) — the
  `TODO(regex)` plug-points editor-ex left. Under `c` each match's
  replacement is expanded at scan time (`ReplaceConfirm.expansions`),
  so `\1` means the groups of the match being asked about.
  `find.Range` aliases `regex.Range`.
- `// changed (core):` `Pane.grep` (`grep.GrepPane`), `AppEvent.grep:
  *grep.Result` (a batch of ≤ 64 hits, the last says `done`; owned by
  the event, `handle` copies onto the pane's snapshot arena and
  destroys it), `Source.grep`. Every exhaustive `Pane` switch
  (`md_preview`, `outline`, `pane.isEditorLike`, `render`) names it.
- `// changed (app):` `find.grep` prompts (`PromptPurpose.grep_query`)
  and opens the pane in a horizontal split beside the active editor;
  a second run re-uses the pane (`grep.find(app)`), cancels the worker
  (`Abort.generation` + `Io.Group.cancel`) and restarts it. Backend:
  `rg --json --no-config --no-require-git --max-filesize 1M` when
  ripgrep is on PATH (a stand-in `rg` is tested), else an in-process
  walk honouring `.gitignore` at every depth (`app/gitignore.zig`:
  negation, anchoring, dir-only, `**`, a stack whose innermost wins)
  plus the artifact dirs the tree hides; `max_hits = 5000` then
  `truncated`. Smart case; `flags.regex` starts from the active
  editor's find-bar toggle (rg's syntax under rg, a vim pattern under
  the walk). The `/` filter is a vim pattern over line + path.
  Keys: `j k g G`, `h l` / `← →` fold, `E` / `C` all, `n` / `N` step
  and open, Enter opens (the pane stays), `y` copies, Space toggles a
  hit, `A` enables all, `D` disables all, `r` reruns, Esc closes.
  `view.activity_search` focuses (or opens) the pane.
- `// changed (app):` `find.grep_replace` (`PromptPurpose.grep_replace`)
  → `grep.replaceAll`: per file, newest-first byte ranges located by
  line + column against the current text (`locate` guards against a
  line that moved). An open clean buffer takes `EditOp.replace_range`s
  through `Editor.apply` and is saved — one undo step; a closed file is
  rewritten on disk; a dirty buffer is skipped and counted
  (`ReplaceReport.skipped_dirty` → "N unsaved buffers skipped — save
  first", `.warn`). A disabled hit is kept. Under `flags.regex` the
  replacement expands group references per hit.
- `// changed (app):` `App.jumplist: jumplist.State` — `back` /
  `forward` stacks of `Point{ path, row, col }` (gpa-owned, `cap = 100`),
  `prev` for `''` / ``` `` ```. Push points: `dispatch.key` snapshots the
  active editor's file + cursor before and after every key and records
  a file switch or a move of ≥ 3 rows (`row_threshold`), which covers
  `G` `gg` `{N}G` `/`+`n` `%` `:N` `gd` marks `{` `}`; `App.openEditor`
  records when another file was active. `in_jump` marks a key that
  *is* a `nav.back` / `nav.forward` / `nav.jump_toggle_prev` so its
  landing is not a push; a nav command run without a key (IPC, the
  palette) clears it on the next snapshot.
- `// changed (specs):` `picker.files` had `ctrl+o` in `both`; it is
  now `standard` only. The chord chain runs before the vim handler, so
  a `both` binding shadowed vim's `Ctrl+O` (jumplist back; `Ctrl+I` —
  a ctrl-modified Tab — forward, in `input/vim.zig`; plain Tab stays
  `buffer.next`). `docs/KEYMAP_PROFILES.md`
  has the row. The pin stays 901.
- `// changed (app):` multi-root. `Tree.roots: []Root{ name, path,
  expanded }` from `cfg.workspaces` (`syncRoots`, once; `~` expanded,
  the workspace itself and a missing dir skipped) and
  `view.add_workspace` (`addRoot`: canonicalised, duplicates and files
  refused). Each root is a section header row (the folder glyph of
  `ui.expand_indicator` + the name; `Row.header`, `Row.root` = index + 1; the primary is root 0 and
  gains its own header only when extras exist); rows under an extra
  root carry absolute `rel`s, which `App.absPath` passes through.
  `←` at a root's top lands on its header; Enter / `l` / `h` on a
  header opens / folds the section. The add prompt Tab-completes a
  directory segment and cycles the candidates (`dispatch.promptPathComplete`,
  reusing `App.cmd_complete`). `view.switch_workspace` is a `.custom`
  picker over primary + roots (`*` marks an open one); `Tree.switchTo`
  opens the pick, folds the rest and lands the cursor on its header.
  `git.discover` appends every extra root's repo (or the repos under it)
  after the primary's, so the GIT rail and `git.switch_repo` see each
  root; the workspace-root rule ("the workspace is a repo → that alone")
  applies to the primary's tree only.
- Not done, by design: a grep pane per query (one pane is re-used);
  `\&`, `\%V` and the cursor-relative vim items; rg's own `--type`
  filters.
## Vim profile parity (2026-09-05, branch `vim-profile`) — `// changed:` notes

- `// changed (keymap):` D4b's reserved list grows to
  `ctrl+w/g/d/u/e/y/r/n/h/j/t/f/b/o` — `view.toggle_tree`'s `ctrl+b` and
  `picker.files`' `ctrl+o` were still `both`, so the chord chain took a
  page-back and an insert-mode `i_CTRL-O` away from the handler. Both are
  `standard` only; the profile isolation test pins them.
- `// changed (dispatch):` a pending chord owns the next key in every
  editor state (`editor_first` requires `app.chord.len == 0`, the rule
  `ptyKey` already had). Without it `<leader>e` typed at speed ran `e` as
  a motion. Esc on a pending chord cancels it without its fallback.
  CONVENTIONS' "keys reach the editor first" paragraph carries the rule.
- `// changed (view):` the sidebar is the leftmost window for
  `view.focus_left` / `focus_right` / `focus_next_split` — NvChad's
  `<C-h>` into nvim-tree and `<C-l>` back. Before, `ctrl+l` from the tree
  was a no-op too (no neighbour → return), contrary to the finding's note.
- `// changed (view):` `view.only` (spec pin 902): `:only` / `Ctrl-W o`
  close the other leaves and re-home their panes as background tabs of
  the kept leaf; a clean duplicate of a file this leaf shows is dropped.
  `view.close_others` stays the standard profile's `ctrl+k w`.
- `// changed (input):` `AppCommand.tab_page{count, back}` (23 fields) —
  `{count}gt` / `{count}gT`; `cmd_tab.gotoPage` resolves it (past the end
  ⇒ the last page, `:help gt`).
- `// changed (app):` `App.toastReplace(id, …)` — an id'd toast with a
  normal TTL that replaces its predecessor; the expiry sweep no longer
  skips id'd toasts (persistent ones sit at maxInt). Tab-page moves use
  it, so `tab N/M` never stacks.
- Deferred, by design: `:vsplit` opening a second buffer. Rust does the
  same (from disk); a shared-buffer window model needs `Editor` split
  into document + view — see the finding for the design and estimate.

## Vim editing semantics (2026-09-05, branch `vim-edit`) — `// changed:` notes

Fourteen findings from the nvchad-persona hunt, editing-semantics
half. `docs/DESIGN.md` D4 / D4b say the vim profile is Neovim /
NvChad-exact; these are the places the editor was not, and what moved.

- `// changed (D4, EditOp):` 137 tags, not 131. `move_right_no_cross_line`
  / `move_left_no_cross_line` are `l` / `h` as operator targets (`x` is
  `dl`, `X` is `dh` — real deletes, so the char reaches `""` and `"-`);
  `move_word_end_cw` / `move_big_word_end_cw` carry `cw`'s count in the
  op (the current word's end even when the cursor is already on it, `e`
  for the rest, a `w` on blanks — `:help cw`); `block_eol` is `$` in
  V-BLOCK; `reindent` is the `=` operator. `EditOp.countPtr` names the
  count a `{count}.` rewrites. The Lua bridge reads a `bool` payload as
  `value`.
- `// changed (registers):` the small-delete register `"-` exists: a
  delete of less than a line fills it and leaves `"1`–`"9` alone
  (`:help quote-`); a linewise or multi-line delete shifts the history
  as before. A selection delete / replace snapshots the cursor at the
  range's start with no live anchor, so `xu` and `cwu` come back where
  the text began.
- `// changed (dot-repeat):` a count given to `.` replaces the recorded
  change's count in place (the first counted op — the handler now always
  puts an operator's motion under a `repeat`, count 1 included) and
  sticks for the next bare `.`; a record with nothing counted is
  replayed count times. The key that entered Insert is part of the
  record even when it only moved (`A` = `move_line_end` + text). A
  visual operator's record is prefixed with ops that reselect the same
  extent from the cursor, captured in rows / columns before the key
  applies (`:help visual-repeat`). A replay is one undo step.
- `// changed (undo):` one Insert / Replace session is one undo step
  (`:help undo-blocks`): `Buffer` anchors the undo depth past the first
  snapshot the entering key pushed and truncates back to it when a later
  key finds the handler in Normal. Arrow keys do not split the session
  (vim would); nothing asked for that yet.
- `// changed (folds):` closed folds are one line to `j` / `k` / `+` /
  `-` and to `dd` / `<n>dd` / `dj` / `yy` / `<n>yy`: `Buffer.foldAwareOps`
  rewrites the handler's list before it is applied, dropping the folds a
  delete takes with it; the dot record keeps the handler's own list.
- `// changed (indent):` `editor.auto_indent` reaches the buffers
  (`applyBufferPrefs`, `App.syncAutoIndent` on `:set ai` / the settings
  row) and carries NvChad's `smartindent` brace habits: one level deeper
  after a line ending in `{`, a `}` typed first on a line takes the indent
  of the line holding its `{`. `=` re-indents by the same brace rules
  (`line.reindent`), vim's `=` without an `indentexpr`; `=G` / `>G` /
  `cG` take the last line whole, `=gg` / `>gg` / `cgg` reach back from
  the end of the cursor's line. `editor.auto_pair` is still never copied
  onto an `Editor` at open (only the toggle sets it) — left alone, it is
  outside these findings and the corpus types brackets as if it were off.
- `// changed (view):` `Lines` carries the painted count: a trailing
  `\n` opens no phantom line N+1 unless the cursor, the anchor or an
  extra cursor sits at EOF. `Doc.block_eol` paints a ragged-right block
  to each line's text. *2026-09-05 (branch `save-cursor`):* a save
  used to put the cursor exactly there (after the `\n` it appends), so
  every save of a newline-less file painted that phantom line; the save
  keeps the cursor now — see "Save-time cursor and Esc from Insert".
- `// changed (macros):` a macro is its register. `qa…q` writes the keys
  in `parseKeys` notation as the charwise text of `"a`; `@a` parses what
  the register holds when it runs; a register yanked back with `yy`
  replays its newline as Enter, as vim executes it. `Clipboard.macros`
  is gone; `macros.zon` carries the named registers `a`–`z` (plus the
  anonymous `'@'` slot, which `:reg` never lists) — any `"ayy` travels
  too.
- `// changed (ex):` `:w !cmd` / `:[range]w !cmd` pipe to the shell
  through `:!`'s runner and output pane and write nothing. `:t` / `:m`
  (address `0` = the top; E134 into its own range), `:new` / `:vnew`,
  `:update`, `:saveas`, `:bfirst` / `:blast`, `:cq` (exit code 1 —
  `App.exit_code`, returned by `tui/loop.run`), `:b N` / `:b name` /
  `:b#`. `buffer.last` (`Ctrl-^`) had a spec and no runner; it has one,
  on `App.prev_active`, which `setActive` records. The verb scanner keeps
  taking dots and digits (command ids), so the copy / move verbs split at
  their first non-letter. `number` / `nu` are aliases of `ui.line_numbers`
  through the config table, so `:set number?` / `!` work like `wrap?`.
- `// changed (tests):` `tests/e2e/vim_*.test`, one per finding
  (fourteen files), each watched failing on the unfixed tree first; unit
  rows in `src/editor/buffer.zig`'s vim tables and in `block`, `line`,
  `insert`, `clipboard`, `editor_view`, `cmd_buffer`, `ex`. Break-checks
  run: `tools/break-check.sh "small-delete register" src/editor/clipboard.zig
  "s/putNamed('-', /putNamed('1', /"` and
  `tools/break-check.sh "vim undo, redo, dot-repeat" src/editor/buffer.zig
  's/if (countedOp(d)) |n| n\.\* = count else times = count;/times = count;/'`
  — both fail with the break in place.

## Git graph, tree and prompts (2026-09-05, branch `fix-git-tree`) — `// changed:` notes

Six findings from the VS Code-persona hunt; each `.test` was watched
failing on the unfixed tree first.

- `// changed (clip):` `clipCells` marks a cut with "…", which can make
  the clipped form longer in bytes than its source — a caller slicing
  the original by that length walks off its end (the commit detail
  panel panicked on a body line one cell wider than itself). The wrap
  primitive is `clip.fitCells(s, max_cells, method)`: the byte length
  of the longest grapheme prefix that fits, no ellipsis, never past the
  text. `git_graph_view.wrapTake` uses it and cuts back to the last
  space when the line continues. `clipStr` stays the display primitive
  — it is for painting, not for slicing.
- `// changed (launch):` `ensureWorkspaceGitignore` treats any rule
  whose first path segment is the state directory as the user's
  decision about it — `.mnml/*`, `.mnml/ipc/`, `!.mnml/findings/`,
  `**/.mnml/` — and leaves the file alone. Appending a trailing
  `.mnml/` after `.mnml/*` + `!.mnml/findings/` stopped git from
  re-including the carve-out. The writer runs from `Channel.init`,
  which the `.test` runner's in-process driver does not construct, so
  its regression lives in the unit test only.
- `// changed (tree keys):` the file clipboard's Ctrl+X/C/V/D are plain
  Ctrl; a shifted form falls through to the chord chain (`ctrl+shift+d`
  is Activity: Debug in both profiles — its runner is still missing
  and toasts, a separate concern). F2 with the tree focused runs
  `file.rename` from `Tree.handleKey` — that is how a tree-focused key
  beats the global `lsp.rename` chord; the spec keeps `f2` on
  `lsp.rename`, whose title now says which F2 it is.
- `// changed (prompt):` `Prompt.State.select_all` + `Prompt.seed`: a
  pre-filled line as a selection (typing or a paste replaces it,
  backspace / delete clear it, a motion drops it, enter keeps it),
  painted on `theme.selection`. NOTES and FINDINGS `n` seed with it;
  `setText` is unchanged and a rename still continues its path. Both
  accept paths append `.md` to a bare name (`notes.withMdExt`) so a
  typed-over seed lands where the panel lists it. The picker's Ctrl+A
  (home, not select-all) is not touched.
- `// changed (trash):` the delete confirm's default is the action
  (`selected = 0`) in both forms — to the trash, or the permanent
  delete inside the trash — so Enter does what every other confirm's
  Enter does and toasts; Esc is the silent way out. The earlier Cancel
  default made right-click → Delete… → Enter a silent no-op. `Empty
  trash` keeps Cancel focused.
- `// changed (tests):` `tests/e2e/git_graph_detail_wrap.test`,
  `tree_ctrl_shift_keys.test`, `tree_f2_rename.test`,
  `notes_new_prefill_replaced.test`, `tree_delete_enter.test`; unit
  rows in `clip`, `git_graph_view`, `channel`, `tree`, `prompt`,
  `notes`, `trash`. Break-checks run and failing with the break in
  place: `tools/break-check.sh "wrapTake" src/ui/clip.zig
  's/if (used + w > max_cells) break;/if (used + w > max_cells + 2) break;/'`
  and `tools/break-check.sh "seeded line" src/ui/prompt.zig
  's/if (!typed and !erase) return false;/if (typed or erase) return false;/'`
  (plus one each for the gitignore, the shift guard, F2 and the delete
  default, quoted in their commits).
## Chrome fixes (2026-09-05, branch `fix-chrome`) — `// changed:` notes

Five findings from the VS Code-persona hunt, each a `.test` watched
failing on the unfixed tree first.

- `// changed (settings hits):` a row registers its `.overlay_item(id)`
  rect *before* its chips and arrows, not after. D6's scan is back to
  front, so the order is the z-order: the row is the floor, every chip
  a target on top of it. A painted chip that the row swallowed was the
  finding; the draw test now walks every registered chip and asserts
  `hits.at` on its own cells resolves to it.
- `// changed (settings wheel):` `ui/settings.State.wheel(items, delta)`
  slides the window and pulls the cursor inside it (`draw` scrolls to the
  cursor, so a cursor left outside would drag the window straight back).
  `app/settings.wheel` wraps it; the dispatcher's `.overlay_item` arm
  routes `.scroll_up` / `.scroll_down` there while `.settings` is up —
  the one wheel path an overlay item has.
- `// changed (settings rows):` a listed-choice row that overflows paints
  a window: `choiceWindow(ui, options, current, avail)` grows from the
  active value outward (right, left, right…) while `a / [b] / c` plus a
  `‹ ` / ` ›` per hidden side still fits. The marks are hits on the
  nearest hidden choice each way (`optionHit(id, lo - 1)` /
  `optionHit(id, hi)`). The row never drops the bracketed value, so `→`
  never steps onto a choice that is not on screen. `max_listed_options`
  (the `[x] ‹ i/n ›` form) is unchanged. The box keeps its width: the
  `widest` estimate still measures each row by its own label rather than
  the label column, which is why rows are cramped at 71 cells — left as
  is on purpose, the family box is 60 % of the screen and the finding's
  chip coordinates hold.
- `// changed (menus):` a context menu is the topmost layer. `render`
  paints the `.menu` overlay after the toasts (the overlay pass skips
  it), clamped to `Rect(full.x, full.y, full.w, fr.upper.bottom())` —
  the rows above the statusline and the `:` line, whichever panel the
  click was in. `menuTop(screen, anchor_y, h)`: below the pointer when
  it fits, else above it with the frame's bottom row on the pointer's
  row, else as low as the area allows. A menu that fit below its anchor
  opens where it always did.
- `// changed (layout):` `ratioAt(len, pos)` returns the percent whose
  `firstLen` lands on `pos`: `⌈100·pos/len⌉`, and past 100 cells (where
  a whole percent is wider than a cell) the nearer of that and the one
  below. The old floor-then-floor round trip lost a cell whenever the
  division was inexact. The ratio stays a percent (session.zon carries
  it), so on a 200-column pane a drag can still settle a cell off; the
  unit test pins exactness to 100 cells and ±1 beyond.
- `// changed (tests):` `tests/e2e/settings_chip_click.test`,
  `settings_wheel.test`, `settings_row_window.test`,
  `toast_menu_fits.test`, `split_divider_lands_on_pointer.test`. Unit
  rows in `src/ui/settings.zig` (chip walk, wheel, window),
  `src/app/render.zig` (toast menu, `menuTop`), `src/app/layout.zig`
  (`ratioAt` round trip). Break-checks in each commit body; the
  paint-order one first "passed" by crashing the test (a break that
  read `app.overlay.menu` under `.none`) — `tools/break-check.sh` counts
  a crash as a fail through the build summary's `(1 failed)`, so a
  break has to be re-read for *why* it failed before it counts.
## Multilang hunt — five findings (2026-09-05, branch `fix-lsp-lists`) — `// changed:` notes

- `// changed (lsp):` D5 has no notion of "the command running now".
  `App.running_cmd` is that — set and restored around `command.run` —
  so `requireServer` can keep a command that finds its server still
  answering `initialize` (`lsp.State.deferred`, one per session, the
  latest) instead of bouncing it. The kept command goes out when the
  server is ready *and quiet*: `Server.progress_open` counts `$/progress`
  begins without their end, `lsp.tick` sends after `deferred_grace_ms`
  when nothing is loading, on the last end when something is, and at
  `deferred_max_wait_ms` regardless. Why quiet: tsserver answered a
  `references` sent straight after `initialize` with one row where
  three exist — its "Initializing JS/TS language features" progress had
  not ended. The hunt's SEV-1 ("list pickers never render") was this
  window plus a missed toast; the pickers and both symbol-shape decoders
  were sound. `initialized` goes out as `{}` (a tuple stringified as
  `[]`, which tsserver logged); a `document_symbol` error reaches the
  user when `lsp.symbols` asked (the outline's own refresh stays quiet).
- `// changed (view):` `view.close_split` on the last window closes its
  buffer through `closePane` (the Rust build's `close_active_pane`
  semantics: a dirty buffer asks, a pty takes its process, the layout may
  be empty). It used to toast "only one split" and keep a sole pty pane
  that only Ctrl-C could end.
- `// changed (commands):` `project.todos` had a spec and no runner
  ("not implemented yet"); it runs `view.activity_todos`'s runner — one
  panel, two palette names.
- `// changed (git):` the worktree prompt (`<path> [new-branch]`) is a
  path prompt: `promptPathComplete` took a `first_word` flag so the
  add-workspace prompt (whole line) and the worktree prompt (first word,
  the branch rides along) share it; `dispatch.overlayKey` routes the
  `.git` purpose there when `app.git.prompt == .worktree_add`.
- `// changed (findings):` `http.history` / `http.history_global` were
  reported silent with a populated log; replayed on the hunt's build in
  its own workspace and data root both pickers open — rejected, and
  `tests/e2e/http_history_picker.test` pins it.
- `// changed (tests):` `tests/e2e/{close_split_sole_pane,
  project_todos,git_worktree_add_tab}.test`, each watched failing on the
  unfixed binary first; unit tests in `src/app/lsp.zig` (two, on the
  scripted server — which now answers `references` and both symbol
  shapes, and brackets its load in `$/progress`), `src/app/cmd_view.zig`
  and `src/app/git.zig`. No `.test` reaches a language server (the corpus
  has only the no-server toasts), so the LSP coverage is unit-level.
  Break-checks run, all four failing with the break in place:
  `tools/break-check.sh "asked for while the server starts" src/app/lsp.zig
  's/app\.lsp\.deferred = \.{ \.server = s\.id, \.cmd = ref\.static };/app.lsp.deferred = null;/'`,
  `tools/break-check.sh "held command waits out" src/app/lsp.zig
  's/(now >= d\.not_before_ms and s\.progress_open == 0)/(now >= d.not_before_ms)/'`,
  `tools/break-check.sh "close_split on the last window" src/app/cmd_view.zig
  's/if (leaves\.len < 2) return app\.closePane(cur, false);/if (leaves.len < 2) return;/'`,
  `tools/break-check.sh "worktree_add: Tab completes" src/app/dispatch.zig
  's/else if (p\.purpose == \.git and app\.git\.prompt == \.worktree_add) true else null/else null/'`.

## The standard profile's editor chrome (2026-09-05, branch `fix-editor`) — `// changed:` notes

Three findings from the vscode-persona hunt plus two of its
"observed, not filed" notes. D4b says the standard profile is VS Code;
these are the places the editor's chrome still spoke vim, and what
moved.

- `// changed (find bar):` Enter no longer submits-and-closes under the
  standard profile. The first Enter lands on the current match, the
  ones after step (`FindBarState.landed`, cleared by a query edit);
  ↓ / ↑ / Shift+Enter / F3 keep stepping; Esc closes. A landing moves
  the bar's snapshot up to itself, so Esc after Enter keeps the query
  and the jump, and Esc on a draft typed over it goes back to the last
  landing. Ctrl+F on an open bar selects the whole query
  (`FindBar.State.select_all`, painted in `theme.selection`): the next
  typed char replaces it, Backspace clears it, a move keeps it. vim's
  `/` + Enter and a bar chained into the replace prompt still close.
- `// changed (widgets and the keymap):` `FindBar.handleKey` and
  `Picker.handleKey` report `.ignored` for a key neither the widget nor
  its field wanted; `dispatch.widgetFallthrough` resolves such a key
  through the keymap as a single chord when it carries a modifier or is
  a function key, so `ctrl+s` saves from the find bar and the palette
  and the widget keeps focus. A leader prefix (`ctrl+k …`) stays with
  the widget; plain keys never leave it. The prompt overlay was not
  changed.
- `// changed (toggle_line_comment):` a selection survives the toggle,
  both ends kept by (row, col) — VS Code's Ctrl+/ twice is a no-op.
  The vim handler adds `move_cursor_to_selection_start` before its
  `select_clear` on `gc{motion}` / `gcip`, so those still end on the
  range's first line; Neovim's Visual `gc` is bound (widened like `>`).
- `// changed (D4, EditOp):` 138 tags. `normalize_linewise_selection_inner`
  is `V…c` / `V…s` / Visual `R`: the range's lines with the last `\n`
  left out, so the replace leaves one empty line — `cc`'s shape. Esc
  leaving Insert still steps left across a line start (the pinned
  Rust-parity row `i<cr><esc>`, and `vim_replace_mode.test`'s save-then-
  `A` chain depends on it); `Vc<esc>` lands where `cc<esc>` does.
  *Resolved 2026-09-05 (branch `save-cursor`):* Esc no longer crosses
  a line start, and the save no longer moves the cursor — see the
  "Save-time cursor and Esc from Insert" section below.
- `// changed (Undo chip):` `UndoChip.Action.reopen` carries the kept
  tab and the index it had. `closeTabs` closes right to left so the
  pops of the closed list land in strip order; a markdown preview goes
  on the closed list too (`forceClosePane`), and `buffer.reopen` drops
  the entry it used since a preview never passes through the editor
  load that does it for buffers.
- `// changed (tests):` `tests/e2e/vscode_ctrl_slash_selection.test`,
  `vscode_find_enter_stays_open.test`, `vscode_ctrl_s_in_widgets.test`,
  `vim_visual_line_change.test`, `ui_undo_close_others_order.test`, each
  watched failing on the unfixed tree first. Break-checks run (all fail
  with the break in place): `tools/break-check.sh "toggle comment keeps"
  src/editor/line.zig 's/ed.anchor = ed.byteAtCol(@min(sp\[0\].row, last), sp\[0\].col);/ed.anchor = null;/'`,
  `tools/break-check.sh "standard Enter steps" src/app/cmd_find.zig
  's/if (app.input_style == .vim or fb.chain_to_replace) return acceptAndClose(app);/if (true) return acceptAndClose(app);/'`,
  `tools/break-check.sh "Ctrl+S saves" src/app/dispatch.zig '…runTarget(app, t),/… _ = t,/'`,
  `tools/break-check.sh "vim Vc keeps" src/editor/apply.zig '…normalizeLinewiseSelectionInner(ed),/…normalizeLinewiseSelection(ed),/'`,
  `tools/break-check.sh "close others: the Undo" src/app/context_menus.zig
  's/        const id = tabs\[i\];/        const id = tabs[tabs.len - 1 - i];/'`.

## Merging the `remaining` track (2026-09-05, on `main`) — `// changed:` notes

- `// changed (app):` `MenuState.title` is gpa-owned: `openMenu` copies
  the opener's title and `Overlay.deinit` frees it. The SEARCH row menu
  titled itself with a frame-arena `path:line`; the next frame's arena
  reset left the title pointing at reused memory and `@memcpy` aborted
  the runner on `refresh_chip_row_menus.test`. A title may now come from
  any arena.
- `// changed (ui):` the settings box no longer grows to fit the widest
  choice list — a row asks only for its bracketed active value and the
  two window arrows, so the box stays the family's 60 % and
  `choiceWindow` does its job. Number rows and long lists are unchanged.
- `// changed (app):` `coverage.readJson` resolves `.tattle-claude-artifacts`
  under `MNML_ARTIFACTS_HOME` when set, else the home directory; the e2e
  driver sets it to the test's data root, so a developer's real coverage
  never paints a chip into a test's statusline (it had shifted every
  hard-coded statusline column in `ui_statusline_clicks.test`).
- `// changed (app):` `find_history.push` moves the recall cursor past
  the newest entry on every push — the bar stays open across Enter in
  the standard profile now, so the cursor set at open went stale.
- `// changed (tests):` the palette bar paints from 40 columns (the
  `remaining` track's change), so the 60-column test apps in `flash`,
  `sticky`, and the render overlay test gained a row or moved a row
  index; the settings box is centred vertically, so the two settings
  scripts moved six rows down; the clock chip (`ui.clock = true`, as in
  Rust) sits in the statusline's right cluster, so the input-style chip
  is at column 92, not 100.

## Shared-buffer windows (2026-09-05, branch `split-buffers`) — `// changed:` notes

The finding `nvchad-vsplit-clones-buffer` (`:vsplit` opened a second
copy of the file): vim's one buffer, N windows.

```zig
// src/editor/document.zig — NEW
pub const Document = struct {
    text, line_starts, history: undo.History, change_list, edits: EditLog,   // the text and its record
    path: ?[]u8, dirty, saved_text, marks, language, read_only,             // the file (moved off Buffer)
    eol, ensure_trailing_newline, trim_trailing_ws_on_save, indent_unit,     // save settings (moved off Buffer)
    disk: ?DiskStamp,          // the watcher's stamp (moved off EditorPane)
    lsp_seen: ?u64,            // the language server's sync point (was App.lsp.synced per pane)
    views: []*Editor, refs: u32, owner: ?Owner,                             // refcounted by its views
    pub fn spliceBy(self, start, end, new, by: ?*const Editor) — THE mutation chokepoint; tells every other view
    pub fn setTextBy(self, text, by)                                        — wholesale; the other views clamp
    pub fn hasOtherView(self, me: *const Editor) bool
};
// src/editor/editor.zig
pub const Editor = struct {        // one window's view; a heap box (`init` / `initOn` return *Editor)
    doc: *Document, cursor, anchor, goal_col, last_selection, block_anchor, block_eol,
    extra_cursors, extra_anchors, replace_stack, ghost_suggestion,
    folds: AutoArrayHashMap(usize, usize),        // moved off Buffer: a window's, in vim
    pub fn onForeignSplice(self, sp: Splice)      // cursor/anchors/extras/folds shift; row delta queued
    pub fn takeLineShifts(self, arena) []LineShift  // the frame moves the pane's scroll by it
};
// src/editor/buffer.zig
pub const Buffer = struct { editor: *Editor, doc: *Document, input: InputHandler, dot…, recording… };
pub fn initOn(gpa, doc: *Document, style, cfg) Buffer;   // the split's window
// src/app/doc_store.zig — NEW, `App.docs: *DocStore` (a heap box: the owner callback survives the App moving)
pub const DocStore = struct { entries: []*Entry,  pub const Entry = struct { doc: *Document, syntax: Syntax } };
pub fn adopt(self, doc) *Entry;   pub fn find(self, path) ?*Entry;   // the last view's release drops the entry
// src/app/pane.zig
pub const EditorPane = struct { buf: Buffer, view, find, wrap, syntax: *Syntax, … };  // syntax shared per document
// src/app/syntax.zig
pub const Syntax = struct { dirty: bool, since_ms: ?i64, … };   // was EditorPane.hl_dirty / hl_since_ms
```

// changed: `Editor` is a view, not the text. `buf.editor.cursor` sites are
// unchanged; the text-and-file sites read `buf.doc.*` (`path`, `dirty`,
// `marks`, `eol`, …). `Editor.apply` runs on the view and splices through
// `Document.spliceBy`, which pushes the byte delta to every other view.
// changed: `App.duplicatePane` no longer copies the text into a fresh
// `Buffer`; it makes a second window on the same document (cursor, scroll
// and folds copied). `hasTwin` is `Document.hasOtherView` — a twin window
// closes on `view.close_split` / `view.only` dirty or not, since the
// document stays. `App.closePane` on a shared view skips the unsaved box;
// `App.closeDocument` (`:bd`) closes every window. `:q` refuses a dirty
// buffer only from its last window.
// changed: the bufferline strip lists documents — a second window on a file
// already in the strip folds into that tab (active when either is).
// changed: `session.openSaved` gets the ids restored so far; a path already
// among them comes back as a second window (`duplicatePane`), not a reveal.
// changed: `watch.reload` keeps every window's row, not only the reloading one.
// changed: `lsp.syncPane` keys on `Document.lsp_seen`; `App.lsp.synced` is gone.
// changed: the highlight reparse is per document: `Syntax.dirty` / `since_ms`
// live on the shared state; `EditorPane` no longer deinit's its syntax — the
// `DocStore` does, after the pane's buffer releases the document.

## Save-time cursor and Esc from Insert (2026-09-05, branch `save-cursor`) — `// changed:` notes

Two coupled Rust-parity deviations that the `vim-edit` and
`fix-editor` tracks each flagged and left alone: the save-time cursor
jump and the Esc that crossed a line start. `docs/DESIGN.md` D4 / D4b
say the vim profile is Neovim-exact; parity with a Rust bug is not a
goal.

- `// changed (save):` `Buffer.save` appends the missing final newline
  (`editor.ensure_trailing_newline`) without moving anything. Cursor,
  anchor and goal column are snapshotted around the `replace_range` and
  put back — all are at or before the old end, so all stay on the last
  line. A cursor past the last char keeps its byte, now the position
  before the appended `\n` (an Insert / standard cursor at EOF stays
  after the last char, VS Code's behaviour); in vim Normal mode, where
  a cursor never sits past the last char, it steps back onto that char.
  Before: `replace_range` parked the cursor after the `\n`, on a
  phantom line N+1 (`Ln 2/1`), and a Normal `A` / `o` from there edited
  the wrong place. Rust mnml has the same jump.
- `// changed (Esc):` leaving Insert or Replace is
  `cursor = max(line_start, cursor - 1)` in grapheme terms
  (`:help i_<Esc>`): the Insert Esc, the Replace Esc and Insert's
  `Ctrl-[` emit `move_left_no_cross_line`, not `move_left`. So
  `i<CR><Esc>` stays at column 0 of the new line, `o<Esc>` sits on the
  opened line, `i<Esc>` at column 0 stays, `A<Esc>` lands on the last
  char, `R<CR><Esc>` stays on the new line. `move_left_no_cross_line` /
  `move_right_no_cross_line` fan out over extra cursors like `h` / `l`
  (they did not; `x` / `X` are built on them and follow).
- `// changed (tests that pinned the bugs):` `buffer.zig` "save adds the
  trailing newline …" asserted `cursor == len` after a save and an
  `A<esc>R!` chain that appended only through the jump — it asserts the
  kept byte and vim's overwrite (`XYZde!`, checked against vim 9);
  `driver.zig`'s status test asserted `cursor_line == 2` after a save;
  the vim row `i<cr><esc>` "ab|c" → "ab|\nc" ("move_left crosses lines
  (Rust parity)") and the multi-cursor row `i` + below + `<cr><esc>`
  asserted the crossing. All four now assert the vim behaviour. New:
  `tests/e2e/save_keeps_cursor.test`,
  `tests/e2e/vim_esc_from_insert.test` (both watched failing on the
  unfixed tree), a save test for an Insert cursor at EOF and a
  standard-mode selection, vim rows for `A<esc>` / `i<esc>` / `o<esc>` /
  `O<esc>` / `A<cr><esc>` / `RX<esc>` / `R<cr><esc>`.
- `// changed (put):` charwise `p` on an empty line (or with the cursor
  past the end) puts at the cursor, on that line; it stepped past the
  `\n` onto the next line. The Esc fix unmasked it:
  `tests/e2e/vim_macro_register.test`'s `o<Esc>"ap` had only landed
  on the opened line because Esc crossed back onto the line above and
  `p` then jumped forward over its `\n`. Vim's `p` on an empty line
  puts there; the test asserts that, the code was wrong. The
  multi-cursor distribute put follows the same rule. Row: `yljp`
  "|ab\n\nc" → "ab\na|\nc". Break-check:
  `tools/break-check.sh "vim registers, yank and put" src/editor/register.zig
  's/where == \.after and !on_newline/where == .after or on_newline/'`.
- **Open — the Rust oracle asserts the deviation.**
  `tests/e2e/vim_replace_mode.test:26` expects `XYZdef!` after
  `RXYZ<Esc>`, save, `A<Esc>R!<Esc>`, save on `abcdef`. Its comment
  says "`A` puts cursor in Insert mode past 'f'; Esc steps back. Then
  `R` + `!` at EOF appends past the end" — but after `A<Esc>` vim's
  cursor is *on* `f`, and `R!` overwrites it: vim 9 writes `XYZde!`
  with the cursor on `!`. `XYZdef!` is reachable only through both bugs
  (the save parks the cursor on the phantom line, `A<Esc>` then crosses
  back onto the `\n`, and Replace inserts before a newline). The file
  is the oracle and is not edited on this branch; until the Rust side
  corrects it (its own `R!` after a save has the same jump) the gate
  reads 46/47 and the corpus is one below the line, with that single
  line the only failure. Break-checks run (both fail with the break in
  place): `tools/break-check.sh "save adds the trailing newline"
  src/editor/buffer.zig 's/else @min(cursor, n);/else @max(cursor, n + 1);/'`
  and `tools/break-check.sh "vim inserts, opens and appends" src/input/vim.zig
  's/break :blk ops(arena, &.{.move_left_no_cross_line});/break :blk ops(arena, \&.{.move_left});/'`.
## The `fix-http-parse` track (2026-09-05) — `// changed:` notes

Three findings from the API-developer hunt (`.mnml/findings/api-*.md`).

- `// changed (http.parse):` a `# @…` / `// @…` line is a directive
  wherever it sits in a block — before the request line, among the
  headers, or after the body — and is cut from the body region before
  `req.body` is set. Rust mnml's `parse_block` keeps every line past
  the blank line, directives included; that rule is kept for plain
  `#` / `//` comment lines after the boundary (a text body may carry
  one on purpose, and Rust ships it) and departed from for directive
  lines only, since the documented placement of `@assert` / `@capture`
  is after the body. `script.isDirectiveLine` is the one predicate.
- `// changed (http.client):` redirects are followed in `sendInner`
  with `.redirect_behavior = .unhandled`, not by the std client — its
  auto-follow consumes each hop's `Set-Cookie` before the caller sees
  the head. `Response.hop_cookies` (`HopCookie{host, value}`) carries
  every hop's cookies keyed by the hop's host; `HeadInfo` and
  `StreamChunk.head` carry them for a streamed send; `afterResponse`
  jars them by that host before the final response's own. Rules:
  `Location` resolves against the hop (`Uri.resolveInPlace`); 303, and
  301 / 302 on POST, become GET without the body (RFC 9110 §15.4, what
  browsers and curl do); 307 / 308 resend method and body;
  `max_redirects = 10`, then `redirect: TooManyHttpRedirects`. A cookie
  set by a hop rides to the next hop on the same host; a hop to another
  host carries neither the jar's `Cookie`, nor `Authorization`, nor a
  pinned `Host`. Rust (reqwest) also follows ten hops and rewrites
  303 / 301 / 302 the same way; it never jarred hop cookies either.
- `// changed (http.client):` a body on a bodyless method (GET, HEAD,
  DELETE, OPTIONS, TRACE) goes out with its `content-length`, the
  bytes written on the connection past `sendBodilessUnflushed` — std's
  `sendBodyUnflushed` asserts `requestHasBody()` and aborted the
  process; curl and reqwest (Rust mnml) send it, and Elasticsearch-style
  `DELETE` bodies are real. A POST with no body is `content-length: 0`
  (std's `sendBodiless` asserts the mirror). No user input reaches a
  std assert from `send`, `mnml-zig run` or `chain run`.
- `// changed (http.mock):` `Canned.next` chains answers so a test
  server can say 302 then 200; the last link answers every request
  after it.
- `// changed (tests):` `tests/e2e/http_directives_not_body.test`
  — the GET with trailing directives opens with an empty Body tab and
  fails soft on a closed port (it took the runner down before); the
  POST shows its JSON alone. Break-checks in the commit bodies of
  `fd4fae7` (parser) and the client commit.

## The `vim-round2` track (2026-09-05, on `main`) — `// changed:` notes

Twenty-three findings from the second NvChad hunt: 20 fixed, 1
rejected against Vim (`vim -es` reproduces mnml-zig's V-BLOCK edge),
2 parked (the doubled-case cursor sits on a Rust corpus line in the
gate; see the finding). Each fix has a `tests/e2e/vim_*.test`
repro and, for seven of them, a `vim()` case in the buffer harness.

- `// changed (editor):` the buffer-local marks are byte offsets on
  the `Document`, moved by `spliceBy` — the one place every edit from
  every window passes — with `Document.markPos` / `setMarkPos` for the
  session file, `:marks`, the picker and the `'a` address. A mark in a
  deleted range lands at the deletion's start; a wholesale replacement
  (undo, reload) snaps them to a boundary.
- `// changed (editor):` `EditOp` has 139 tags: `restore_last_selection`
  carries a `SelectionShape` (charwise / linewise / block) and
  `change_numbers_in_selection` is `v_CTRL-A`. `EditCtx` has 13 scalars
  again — `register_empty`, so a Visual `p` can refuse before it
  deletes. `AppCommand` has 26 variants: `operator_to_mark`,
  `split_resize`, `fold_after` (ops that select, then
  `editor.fold_selection`).
- `// changed (editor):` `ip` / `ap` name lines, the operator widens
  them (`dip` leaves no empty line, `cip` opens one, `vip` is V-LINE);
  `dap` on the last paragraph takes the blank lines before it. Two
  buffer tests that pinned the Rust "charwise paragraph" shape pin
  Vim's, as does the `vlp` case (nothing to put ⇒ nothing deleted).
- `// changed (editor):` a `repeat` of a put is one put of the text
  `count` times; a `repeat` of `delete_line` takes only the lines that
  exist. `dd` / `V…d` on the last line clamp onto the new last line.
- `// changed (app):` toasts are dropped while `in_global` is set —
  `:g` reports once. `:g` is one undo step. `:v` with every line
  matching says "Pattern found in every line".
- `// changed (app):` the chord chain consults the which-key tree when
  a leader chain bottoms out in the keymap (a leaf runs, a group opens
  the popup at that path), and a pending leader prefix that times out
  with no fallback resolves the same way. The tree arms `Ctrl-W` under
  the vim profile. `zj` / `zk` walk every bracket block
  (`cmd_editor.allFoldRanges`) plus the closed folds.
- `// changed (app):` `:tabmove`, `:resize`, `:vertical resize` /
  `split`; `{count} Ctrl-W >` is `count` cells (the bare chord keeps its
  5 % step). `/pat/e` is a search offset kept on the pane's find state.
  `Ctrl-V` on the `:` line quotes the next key (the paste is `Ctrl-R "`).
  `q{A-Z}` appends to the register.

## Round two of the VS Code hunt (`fix-vscode2`)

Fourteen findings, each with a `tests/e2e/*.test` repro and, where a
painter or a pure function is the fix, a unit test with a landed
break-check.

- `// changed (ui):` `clip.width` sums cells per grapheme, saturating at
  `u16`, and `clipCells` measures through `clip.fits`, which stops at the
  first grapheme past the budget — a grep hit on a 545k-char line (the
  repo's own `data/nerd-glyphnames.json`) used to hand the whole prefix to
  vaxis' `gwidth` and overflow the process to death. `Ui.clipStr` /
  `widthUpTo` / `fitsIn` are the bounded front. Every painter that can
  receive a whole file line is guarded and unit-tested at 100k chars:
  `grep_view.paintHit` (which now paints a `…`-windowed line around the
  match, the walker storing a `grep.windowLine` window in `Hit.text_off`),
  `diagnostics_view` / `todos` / `http_panel` (which summed two saturated
  widths), `outline_view`, and the location list.
- `// changed (app):` `transfers.quitGuard(app, force)` is the one quit
  guard both `app.quit` (Ctrl+Q, the palette) and `:qa` ask; a copy in
  flight refuses either. (`:qa` keeps its inline copy in `ex.zig`, the
  vim-round2 file — fold it onto `quitGuard` after that merge.)
- `// changed (ui):` `Prompt` has `return_focus: ?FocusId` (as the menu
  overlay already did); `closeOverlay` honours it, so a tree-opened rename
  prompt hands focus back to the tree. Ctrl+A in a prompt is select-all
  (VS Code), and the grep prompt seeds the last query as a selection.
- `// changed (app):` `dock.layout` overflows a widget its corner cannot
  hold to the next corner clockwise with room (`placeInCorner`); a drop on
  a full corner snaps to the nearest with room and toasts, never leaving
  the widget unpainted. `dock.move_corner_next` asks the same
  `cornerWithRoom`.
- `// changed (app):` `files.open_split` reuses the focused browser as the
  left pane (one new pane, not two). The trash view is a singleton titled
  `Trash`: `crumbs` reads `Trash › …` under the workspace trash and
  `FilesPane.up` stops there, so `↑` never climbs into the data root.
  `files_view` paints a marked row's tick on the cursor row too.
- `// changed (app):` the tree's right-click menu carries Cut / Copy /
  Paste here / Duplicate (the Files pane's ids). `search.toggle_regex`
  flips the Search pane's regex and reruns; `view.activity_integrations`
  (ctrl+shift+x) opens the Integrations pane; `view.image_open` is a
  picker of the workspace's images — its runner table was never listed in
  `command.runner_tables`, so it is now.
- `// changed (render):` a menu row's curation kebab (`⋯`) registers its
  hit after the row hit and the row hit stops where the kebab starts, so a
  click on the glyph opens Pin / Hide / Copy rather than running the row.
- `// changed (app):` `watch.check` ends in `checkDirs`: a Files pane
  (`FilesPane.dir_stamp`) and the tree (`Tree.dir_stamps` / `dirsChanged`)
  re-read when a directory's mtime moves on disk — a file added by a build,
  a git checkout or another editor.
- `// changed (ui):` the tab strip is a window. `bufferline.draw` takes
  `Opts.first` (default `fitActive`, so the active tab is the last one
  shown) and returns the `Window`; hidden tabs show `‹` / `›` that register
  per-leaf `render.Button.tabScroll` buttons, and the `+` keeps its place.
  `Leaf` holds `strip_first` / `strip_anchor` / `strip_hidden_right`; a
  wheel over the strip (a gap between tabs routes through the pane's strip
  row) and a marker click step it a tab at a time (`dispatch.tabStripStep`).

## The real terminal (2026-09-06, on `main`) — `// changed:` notes

- `// changed (tui):` `Term.init` forces `caps.sgr_pixels = false` before
  enabling the mouse. ghostty, kitty and WezTerm answer the DECRQM 1016
  probe, vaxis then requested pixel-coordinate reports (mode 1016), and
  the loop's `translateMouse` — which never calls vaxis's pixel→cell
  `translateMouse` — treated pixels as cells: every click landed off
  screen. Cell coordinates (1006) always; the Rust editor took cells
  from crossterm and mnml has no use for sub-cell positions. This shipped
  because every mouse test injected clicks through the IPC channel;
  `tools/pty-mouse-check.py` now drives the real binary in a pty,
  answers the probes as ghostty does, and asserts the requested mode and
  a working click / right-click / wheel.
- `// changed (tools):` `tools/ui-diff.sh` runs the Rust and Zig
  binaries headless on one workspace with one config and diffs the two
  screens row by row. The Rust screen is the spec for how mnml-zig
  looks; the UI tracks use the diff as their gate.

## The activity bar (2026-09-06, branch `rail`) — `// changed:` notes

- `// changed (render):` `FrameRects` gained the sidebar's columns —
  `rail`, `rail_border`, `sidebar`, `sidebar_divider`, `body` — and
  `frameRects(full, Chrome)` takes what it needs to lay them out
  (`Chrome{ sidebar: ?u16, rail: bool }`, `render.chrome(app)` builds
  it). The rail (3 cells) and its `│` (1) are carved from the sidebar's
  own `tree_width`, as Rust's `ui/mod.rs` carves them from `tree_area`:
  the tree's divider stays at column 30 with or without the rail, the
  tree's text moves right by four. `render` paints the sidebar from
  those rects; the `// ── rail ──` block in `frameRects` and in `render`
  is the whole of it. `zenRects` fills `body` too.
- `// changed (ui):` `src/ui/activity_bar.zig` — `Section` (Rust's
  twelve builtins, Rust's order and codepoints, an ASCII twin each),
  `layout` (Rust's rows: sections from `y + 1`, step 2 or 1 by the
  density rule, the gear on `bottom - 2`, nothing below `bottom - 3`),
  `draw(ui, area, Props)`. The pinned launcher slots are not painted —
  they need the integrations — but `Props.extra_items` counts them so a
  config that packs the Rust rail packs this one the same way (the
  fixture's six pins put the sections on rows 2..13, not 2,4,..24).
- `// changed (hit):` `HitTarget.rail: activity_bar.Part` (`section: Section`
  / `gear`), labelled `rail:todos` / `rail:gear`. One prong in
  `dispatch.mouse` → `app/activity_bar.mouse`.
- `// changed (app):` `src/app/activity_bar.zig`. Rust keeps
  `active_section` as state and swaps the sidebar on it; here the
  sections already have surfaces (the tree, the right-panel slot, a
  pane), so `active(app)` reads the mark off them — the focused surface,
  then the open right panel, then the tree. A click runs the section's
  `view.activity_*` id, the same one the right-click menu's first row
  names. `view.activity_debug` (the DAP pane), `view.activity_agents`
  (the agents dashboard) and `view.activity_cloud_agents` (the honest
  "not in this build") had specs and no runners; they run here. A click
  on the active section does not collapse the sidebar — Rust's
  `set_activity_section` only ever shows it, and this follows Rust.
- `// changed (menus):` `context_menus.openRailMenu` (Rust
  `right_click.rs`: "Show X" + the section's quick verbs; Explorer's
  reveal row is `view.reveal_in_tree`, the in-app reveal Rust moved to)
  and `openGearMenu` (Settings / Command Palette / Cheatsheet / Themes /
  About). `discovery.describe` has a `.rail` arm (Rust `tooltip.rs`'s
  click hint + what the section holds) so the hover tooltip, the info
  box and the F1 overlay all explain the rail.
- `// changed (config):` `ui.activity_bar: .always | .auto | .hidden`
  (`Config.ActivityBar`, the menu bar's three words per the Rust
  header's TODO). `hidden` hands the tree its four columns back; `auto`
  paints the rail while the pointer is in column 0 or resting on the
  rail (the previous frame's hits, read before the frame resets them);
  a menu opened from it may see it go when the pointer leaves for the
  menu. Settings row "Activity bar"; `view.activity_bar_cycle` (Zig-only,
  the twin of `view.menu_bar_cycle`; the spec count pin is 914).
- `// changed (badges):` a host's `set-activity-badge` count paints
  over the section's glyph on Rust's pulse (four seconds glyph, one
  second count — `app.now_ms`), `•` for one, the digit to nine, `+` past
  it. Same keys as `ipc/effects.known_sections`.

## Statusline (2026-09-06, branch `statusline`) — `// changed:` notes

- `// changed (ui):` `statusline.Info` is two lanes of `Seg` plus the
  centred pending chord: `Seg{ text, fg, bg, bold, hit, sticky, accent,
  tail }`. The component paints powerline arrows (U+E0B0 / U+E0B2)
  wherever two neighbours' grounds differ — the colour hand-off — and
  none between two on one ground, so a two-seg chip (the vim glyph and
  its label) is one pill. `draw` registers every `Seg.hit` as
  `.statusline_seg`. The fixed ids are `seg_mode = 0`, `seg_file = 1`,
  `seg_position = 2`, `seg_language = 3`, `seg_restricted = 4`;
  `seg_app_base = 16` up is the app's (`app/statusline.zig` `SegId`),
  `seg_dyn_base + i` a host segment's slot. `seg_input_style` is gone —
  the mode chip is where the keymap is toggled, as in Rust. Overflow:
  the right lane is measured whole, the longest left chip clips (floor
  three cells), then right chips drop leftmost-first, a `sticky` one
  (Ln/Col) last; Rust instead lets the screen edge cut the right lane
  (the 60-column dump loses ` ws` and the language).
- `// changed (app):` `app/statusline.zig` builds the lanes — mode,
  host segments, branch (`⇡N ⇣N` + NvChad file counts), PR, file glyph
  + name + `●`, diagnostics, symbol, macro, find | host segments,
  tests, Claude, Codex, coverage (`F 57% ▲1.0` with the tinted delta),
  transfer, LSP, RESTRICTED, WRAP, autosave, size, Ln/Col, Sel, stress,
  bell, clock, workspace, language — and `render.drawStatusline` is one
  call into it. `render.SegId` is an alias of `statusline.SegId`.
  `modeOf` is the one paint-side read of the editing mode: TREE / PANEL
  / EDIT / VIEW for the standard profile (a Pty, Files or HTTP pane is
  VIEW, as Rust), the vim mode with the U+E7C5 glyph otherwise. The
  replaced builders are deleted: `lsp.statusSegment`,
  `git.statusSegment`, `ai.meterSegment`, `messages.bellSegment`
  (their tests now read the painted row). The WRAP chip reads the
  active editor's own wrap (`EditorPane.wrap`) before the config's, so
  its click (`view.toggle_wrap`) is visible on the chip.
  `coverage.shown` / `delta` / `featureAt` / `codePrev` give the chip
  its ▲▼± deltas (feature: seven days back; code: the previous point).
  `git.tick` runs `discover` on the first tick so the branch chip shows
  before any git pane is opened.
- `// changed (app):` `dispatch.mouse` routes every chip: mode →
  keymap toggle / menu, position → go to line, file → the Buffer menu
  on the right button (left does nothing, as Rust; the "Reveal in
  tree" row waits on a `view.reveal_in_tree` runner — the id is spec'd
  with none, and `-Dpartial` hides that), language → a toast, branch →
  status pane / git menu, PR → the browser, symbol → outline, macro →
  stop, find → the find bar, tests → the pane, AI → spend report,
  coverage → toast / mode menu, LSP → symbols, WRAP → toggle, autosave
  / size → toasts, bell → history / menu, clock → local ⇄ UTC / menu,
  workspace → switch workspace (or repo, with several), a host
  segment → its `click_command`. `discovery.describe` has words for
  each. `context_menus.openFileChipMenu` is new.
- `// changed (ui):` `ui/file_glyph.zig` is the file chip's devicon
  lookup (name, then extension, in the language's colour). The tree
  track is building the full table as `ui/icons.zig`; this folds into
  it at the merge — same codepoints, same colours.
- `// changed (tools):` `tools/ui-diff.sh` snapshots `$WS/.mnml/
  session*` before each run and restores it after, so a STEPS file
  that opens a file is not restored by the next run. `docs/ui-spec/
  rust-80x24.txt` is the Rust screen at 80×24; both dumps are embedded
  (`build.zig`, `ui_spec_rust_120x40` / `ui_spec_rust_80x24`) and the
  statusline tests compare the painted row with the spec's — clock
  normalised, the cut now-playing cluster removed (or put back at the
  component level, where the 80-column row is Rust's cell for cell).
- `// changed (app, 2026-09-07):` the now-playing cluster is back —
  `app/now_playing.zig`. Rust always paints it: idle it is the preferred
  player's mark (`ui.preferred_music_app`: mnml's baked Beatport B /
  nf-fa-apple / nf-fa-spotify) and nf-md-play_box_outline on the
  player's colour, the `󱼀 󰐎` every Rust dump carries; with a track it is
  the transport (nf-md-pause or play, nf-md-skip_next, `artist - title`
  cut at 28 with `…` or scrolled under `ui.now_playing_marquee`). The
  poller is an `Io.Group` task the terminal loop alone starts
  (`native_notify`): mixr's `~/.mixr/quick.txt` when fresh, `osascript`
  for Music / Spotify on macOS, `auto` prefers whichever plays, the
  ten-second mixr stickiness kept. Headless and the tests paint the idle
  form, so the dumps compare; `MNML_NOW_PLAYING="<track>|playing|
  <source>|<detail>"` puts a track on the row (Rust has no such
  override — the name is Zig's), and a `.test` sets it with a `# env:
  NAME=value` header line (`e2e/parser.zig` `Header.env`, applied per
  file in `e2e/runner.zig`). Clicks are Rust's: the transport chips
  drive a macOS player by `osascript`, the brand / title open it
  (`mixr.show` / `activate`), the idle play chip starts it
  (`mixr.play_now` / `playpause`), the right button is the player menu
  with the preferred-app radio rows. `mixr.set_preferred_*` and
  `mixr.copy_track` now run (they left `cmd_app.zig`'s cut table); the
  mixr transport, `mixr.show*`, `play_now` and `show_auth_status` stay
  cut, so on a machine preferring mixr the idle clicks toast the cut.
  `SegId` gains `np_brand` / `np_play` / `np_next` / `np_track`;
  `--ascii` paints `B` / `A` / `S`, `>`, `||`, `>|` and Rust's one-cell
  breather. docs/PARITY.md's "now-playing cut" entry is the docs
  track's to amend.
- `// changed (ui, 2026-09-07):` the overflow rule is Rust's, whole.
  The right lane is measured whole; the longest left chip clips to what
  it leaves less four cells of air (floor three); and when the row is
  still too narrow the right lane follows the left lane directly and
  the screen edge cuts it — Rust's one `Line` of spans. The Rust editor
  at 60×24 on the fixture reads ` TREE  … [no file]  F 57% ▲1.0  󱼀 󰐎
  WRAP    18:00` and stops: the workspace and the language are past the
  edge, and `ui/statusline.zig` / `app/statusline.zig` pin that row and
  the 100- and 80-column ones (identical to Rust's — `tools/ui-diff.sh`
  at 100×40 shows no difference) at four widths. The earlier drop rule
  (right chips leftmost-first, a `sticky` cursor position) is gone with
  the field; at the gate sizes the two rules never differed.
- `// changed (app, 2026-09-07):` `coverage.artifactsHome` reads only
  `MNML_ARTIFACTS_HOME` under the test runner (`builtin.is_test`), never
  HOME: a unit test that builds an App on the process environment was
  painting the developer's own trends file into its row — fifteen cells
  that, with the cluster's six, cut the cursor position out of a
  48-column frame on one machine and no other (`render.zig`, `lsp.zig`
  tests). The e2e driver already set the variable; the unit tests now
  match it.
- `// changed (app, 2026-09-07):` the LSP chip's clicks are Rust's.
  The left button is `:LspStatus` — one toast naming every live server
  and its root relative to the workspace (`LSP: rust (.) · typescript
  (web)`), `LSP: no servers running` without one — as the new
  `lsp.status` command (`app/statusline.zig` `table`; the id is Rust's
  ex verb as a palette command, since Zig's menus run command ids). The
  right button is Rust's nine-row LSP menu (Status, symbols in file /
  workspace, diagnostics, references, rename, format, code actions,
  inlay hints), `openLspChipMenu`. The chip's text, colour and place
  (after the now-playing cluster, before WRAP — `rust-goto-120x40.txt`)
  were already Rust's; a test proves all of it on a fake server
  (`lsp.TestRig`, read-only use of `app/lsp.zig`). Before, the left
  click opened the symbols picker. `docs/commands.md` wants a `zig
  build docs` for the new id — the docs track's file.
- `// changed (tests, 2026-09-07):` the `.test` runner's workspace is
  `mnml-e2e-` and six hex digits (fifteen characters), near the ten of
  Rust's `tempfile::tempdir()` name. The 41-character one was 45 cells
  of every 120-column row: with the now-playing cluster beside it the
  row overflowed and Rust's rule clipped the mode chip (`vim_gv_mode`
  read `V-LI…`) where Rust's runner never reaches that width.
  `ui_statusline_clicks.test` and `statusline_now_playing.test` carry
  the recomputed columns (the position chip is 70–83 now).
- `// changed (app, 2026-09-07):` the coverage chip's `ticker` flips on
  the wall clock, as Rust's does (`SystemTime` seconds / 4 % 2 —
  `coverage.wallMs`): `app.now_ms` is monotonic since boot, so the two
  editors on one machine showed opposite halves at the same moment and
  every `ui-diff` on the fixture (whose config is the ticker) read `F
  57% ▲1.0` against `C 74% ±0.0`. They now agree whenever both dumps
  fall in one four-second window; the tool starts them about five
  seconds apart, so a run can still straddle a flip — pinning the
  fixture configs to `coverage_chip_mode = .feature` would make the
  sweep deterministic (the fixture is the harness's, not this track's).
  `State.ticker_clock_ms` pins the clock in tests.
- `// changed (residue, 2026-09-07):` with the fixture's ticker pinned
  to `feature`, `tools/ui-diff.sh` on every steps file loses its two
  statusline lines (esc 4 → 2, http / graph2 2 → 0, palette 34 → 32,
  picker 4 → 2, discovery 4 → 2, help 6 → 4, todos 24 → 22, notes 26 →
  24, findings 26 → 24, whichkey 0); the seven that open `main.rs`
  (editor, diff, goto, close, delete, rename, outline) keep exactly one
  pair, Rust's ` LSP 1 ` — the lsp-fixture track's rust-analyzer. The
  three `zig-debug-*` dumps (and the 80×24 one) are regenerated with the
  cluster on row 38. Unpinned, the ticker straddles the dumps' start
  times as it would for two Rust editors five seconds apart.
- Cut, per the spec: the Sonos cluster. Not in this build: the Claude
  chip's quota percent (`W 99% 18m …`) — Zig's meter is the local 24h
  spend until the usage endpoint is called; the LSP progress (`⟳ …`),
  background-task spinner and `AI` suggestion chips.
## The file tree sidebar (2026-09-06, branch `tree`) — `// changed:` notes

The spec is `docs/ui-spec/rust-120x40.txt`, columns 4–29 of rows 1–37;
`tools/ui-diff.sh` on the chrome fixture shows them identical at rest, with
`README.md` opened, and at 80×24.

- `// changed (ui):` `src/ui/tree_view.zig` paints the sidebar from a flat
  list of items — a section header, an entry, the blank row between
  sections, the trailing `Add workspace` row — one per screen row, every
  hit registered with its cells. The primary header is ` ▾ ~/path/ ` (bold
  green, italic while hidden files show, the path `…`-cut to what the
  cluster leaves, never under four cells) with the chips right-aligned —
  new folder `EA80`, new file `EA7F`, pull `EB40`, collapse `EAC5` /
  expand `F0AB4`, then refresh `EB37` — dropped from the right of the
  cluster until label, a cell, cluster, refresh and one cell of margin
  fit (three of the four at the stock width; the refresh chip outlives
  them). An extra root is ` ▸ name ` cut to width − 4. An entry is the
  Rust row: one cell of the rail's ground, two cells of indent, mnml's
  baked `│` (`F1F04`) down each ancestor level from the second that has
  siblings to come, the Octicons chevron (`F47C` / `F460`) on a folder or
  `│` / `└` (`F1F05`) in a file's slot under the parent's icon, the icon
  and its colour (`src/ui/icons.zig`, nvim-web-devicons' table as comptime
  data; folders in the theme's yellow), the name (folders bold blue, git
  states yellow / green / red, dot entries dim, the cursor row bold on
  `bg2`), the badge right-aligned (`M` `A` `?` `!`, the unsaved `●`
  first). `ui.expand_indicator = .triangle` and `ui.show_workspace_dots`
  apply as in Rust. Every glyph has its `ui.ascii_icons` twin beside it.
- `// changed (app):` `src/app/tree.zig` builds the items and keeps the
  state. Dot entries show by default and `H` hides them (Rust); `.git` and
  the artifact directories never show, and `H` no longer reveals the
  latter (Rust hides them unconditionally); each directory's `.gitignore`
  is honoured through `gitignore.Stack` as the listing descends; names
  sort case-blind after directories; the primary section folds on its
  header (`primary_expanded` now empties the rows without extra roots
  too) and the primary's top-level directories open on first sight under
  extra roots as well. The tree asks `git.discover` / `requestStatus`
  itself when it has no snapshot, so the badges paint without a git
  surface open. One click opens a file (the release, so a hold is still
  a drag), a press on a folder row folds it, a press on a header folds
  the section (Alt folds or opens every directory with it), a chip runs
  its command with the tree focused. The tree's scrollbar is an
  `Owner.tree`; the wheel steps the cursor.
- `// changed (hit):` `tree_root: u8`, `tree_chip: tree_view.Chip`,
  `info_view: InfoPart` (`body` / `kebab` / `try_it: n`), `Owner.tree`;
  labels `tree_root:0`, `tree_chip:new_file`, `info_view:try_it:0`,
  `scrollbar:tree:v`. `discovery.describe` has words for each.
- `// changed (info view):` `src/ui/info_view.zig` + `src/app/info_view.zig`
  replace the tooltip help box. The panel's bottom `ui.hover_help_height`
  rows are the info view whenever the panel has eight rows to spare
  (Rust `ui/mod.rs`): the rule, the title band on `bg2` with the `⋮`
  kebab (its menu is the one Rust row — turn the panel off), a spacer,
  the copy wrapped at width − 2 with a one-cell gutter, `[Chord] Label`
  rows, `→ label` links that run a command, a scrollbar when it overflows
  (the wheel scrolls). The copy is Rust's ladder: the hovered chip / row /
  target (the previous frame's hits), else the tree's cursor row past
  the first (flattened with its chords), else the active pane's summary
  (`name  ·  LANG  ·  L:C  ·  N lines`, or the identifier under the
  cursor), else `Sidebar` / `Editor` / `Right panel`. The dictionary
  carries Rust's tree-row entries (directories, `.d.ts`, the filename
  rows, the extension rows) and the header chips' entries with a `Run it`
  link. `tooltip.drawHelpBox` and `discovery.drawHelpBox` are gone.
- `// changed (tests):` `tests/e2e/tree_click_open.test` (one click
  opens, the chevron folds), `tree_header_chip.test` (the chips prompt,
  the header folds); `tools/pty-mouse-check.py` clicks once. Corpus
  flips from the Rust look: `jumplist_workspaces` / `vim_ctrl_b_pages_back`
  / `vim_leader_second_key` (the header shows the path, with the dot, not
  the bare name), `tree_move_to_complete` (dot files show, `End` finds
  the row), `plus_menu_kebab` (the info view's `[F2] Rename` chord is not
  the menu's `Rename…`), `files_pane` (unchanged, still green).
## Menu bar + chrome row (2026-09-06, branch `menu-bar`) — `// changed:` notes

- `// changed (ui):` new `src/ui/menu_bar.zig` paints row 0 as the Rust
  `draw_palette_bar` does, cell for cell against `docs/ui-spec/
  rust-120x40.txt` and the new `rust-80x24.txt`: the menu words
  (` ❯_  mnml  File  Edit …`, ` » ` once one no longer fits — Rust's
  50-cell cluster estimate and 3-cell overflow slot), the centred 48-cell
  nav cluster (sidebar toggle · ` ← ` ` → ` · `  󰍉  <workspace padded to
  24>  ` · ` ▾ ` · right-panel toggle), the chip alone below 48 columns.
  Props in, `Layout` out (`palette_right_edge`, `first_hidden`,
  `words_end`, each word's x); every element registers the `.button`
  the caller names. The old painter in `render.drawPaletteBar` — the
  `search files · run commands` label, the git / IPC badges, the stress
  copy, the green Marketplace `+`, the AI chips on row 0 — is gone; the
  Rust row shows none of them.
- `// changed (ui):` `bufferline.zig` gains Rust's right cluster
  (`Cluster` / `drawCluster` / `clusterWidth` / `pickCluster`: ` + `,
  ` TABS ` and a chip per tab page with ` × ` on the active one in the
  full mode, the theme pill `●━ `, the ` × ` that quits; compact drops
  the label and shows chips from the second page; `ui.top_bar_cluster_
  mode` picks as Rust's `pick_cluster_mode_tiered`) and the strip's split
  buttons (`drawSplitButtons`: the enabled AI chips, ` $ `, `  `, `  `
  at the right end of the strip in the body's top-right corner — Rust's
  `paint_split_buttons`). The strip's `+` is nf-md-plus `󰐕` (`+` under
  `--ascii`), as Rust paints it; three `.test` files that expected the
  ASCII `+` on the strip were updated.
- `// changed (app):` `src/app/menu_bar.zig` holds the ten menus —
  brand, File, Edit, Selection, View, Go, Run, Terminal, Window, Help —
  with Rust's rows, glyphs (each with a one-character `--ascii` twin) and
  commands, mapped to Zig ids. Left out, with a note in the source: rows
  whose id has no runner yet (`view.toggle_bottom_panel`,
  `view.commands_reference`, `layout.merge_to_tabs`,
  `layout.spread_to_splits`, `view.ai_layout_grid` / `_tabs`). The File
  menu's "Open recent file" submenu is built per open from `app.recent`
  (`file.open_recent_N`, "Clear recent files"); every command row carries
  its first chord under the active profile as `MenuItem.hint`. `App.
  menu_bar: menu_bar.State` replaces `menu_bar_open` / `menu_bar_x`
  (the open menu, each word's x, the `»`'s first hidden index, an arena
  for the per-open rows). `ui.menu_bar = auto` also shows the words while
  the pointer rests on the row (Rust 2026-09-03).
- `// changed (keys):` F10 opens File (not while a DAP session owns
  step-over, an overlay is up, or a pty pane has focus); Alt+<letter>
  opens the menu with that initial (`m` is the brand menu; Shift / Ctrl
  combinations are left to the keymap); ← / → step between menus while
  one is open, → on a submenu row opens it. `dispatch.keyInner` calls
  `menu_bar.interceptKey` after the flash intercept; the `.menu` overlay
  prong calls `menu_bar.menuKey` first.
- `// changed (core):` `command.MenuItem.hint: ?[]const u8` (painted
  right-aligned in the muted colour by `render.paintMenuRows`; `menuSize`
  widens for it) and `MenuAction.menu_bar: u8` (a row of the ` » `
  overflow menu opens that menu-bar menu; `runMenuAction` prong). Both
  additive.
- `// changed (ids):` `render.Button` is renumbered: `back` / `forward`
  / `dropdown` / `new_tab_page` / `tabs_label` / `theme_toggle` /
  `window_close` / `split_term` / `split_right` / `split_down` join;
  `add_integration` and `stress` (the row-0 stress copy) go; tab-page
  chips are `tab_page_base + i` (0x40) and their `×` `tab_page_close_base
  + i` (0x60), so `integrations_view.max_chips` shrinks to 0x30. Clicks:
  back / forward → `buffer.prev` / `buffer.next`, dropdown →
  `picker.recent`, `+` → `tab.new`, TABS → `tab.picker`, a page chip →
  `cmd_tab.switchTab`, its `×` → `tab.close`, the pill → `theme.toggle`
  (or `theme.pick` without `ui.theme_toggle`), `×` → `app.quit`, the
  split buttons → `term.shell` / `view.split_right` / `view.split_down`.
  The gap between the toggle and the cluster paints the enabled
  integration chips on Rust's 5-cell stride (`render.drawGapChips`; the
  browser globe by default) — `integrations.chipClick` unchanged.
- `// changed (help):` `discovery.describeButton` routes the bar's ids to
  `menu_bar.describeButton` — Rust `tooltip.rs`'s copy for the words
  (with the Alt accelerator), the `»`, the toggles, the arrows (disabled
  copy with one buffer), the chip, the dropdown, the cluster and the
  split buttons.
- Tests: `ui/menu_bar.zig` pins row 0 at 120 and 80 columns
  (`rust_row_120` / `rust_row_80`, built from the glyph constants) and
  every hit; `render.zig` pins the whole row against both dumps including
  the globe and the cluster, the strip's `+` at 32 / 1 and the split
  buttons; `app/menu_bar.zig` walks every row of every menu for a
  runner; `tests/e2e/menu_bar_top_row.test` clicks the chip, the
  `+`, File, a row, the `»` and a hidden menu.

## Editor, diff and request panes to the Rust spec (2026-09-06, branch `editor-panes`) — `// changed:` notes

The three pane specs (`docs/ui-spec/rust-editor-120x40.txt`,
`rust-diff-120x40.txt`, `rust-request-120x40.txt`) and their step
files, painted cell for cell. What moved, and where the Zig side still
differs on purpose.

- `// changed (bufferline):` a chip is Rust's ` glyph name badge ` —
  the file's devicon, the name cut at `name_cap`, the close `󰅖` on every
  tab (red on the active one), three cells to the next chip, the ` 󰐕 `
  after the last; a Request tab has no glyph and a method pill; the
  ` 󰅁  󰅂 ` pair sits at the right whenever a leaf holds two or more
  tabs, dim and inert with nothing to scroll to. The empty strip keeps
  Rust's three split buttons (the maximize button is gone). Pty tabs
  lost the `│` divider and the `$` suffix the old strip invented; the
  `HitTarget.tab_close` doc now says badge cells. Six zig-only `.test`
  files that asserted the old strip (`close_split_sole_pane`,
  `files_open_split`, `plus_menu_kebab`, `pty_tabs`, `tab_strip_overflow`,
  `ui_undo_close_others_order`) now assert the Rust geometry, each
  checked against the Rust binary through `tools/ui-diff.sh` first
  (sixteen-tab overflow and a four-tab strip are cell-identical).
- `// changed (tab drop):` `dispatch.dropTab` uses Rust's
  `tab_strip_insert_idx`: the slot before the first chip whose
  three-quarter point is right of the pointer, applied after the dragged
  tab is taken out — a drop past a neighbour's middle lands after it.
  The centre rule with the same-leaf decrement made the Rust corpus's
  `mouse_tab_reorder.test` a no-op on the new chip widths.
- `// changed (strip wheel):` the wheel over a strip scrolls it a tab
  at a time and clamps at the fill. Rust lets the strip overshoot the
  fill and then paints a `+N hidden` count chip for the tabs scrolled
  off the left; the Zig chip counts filtered tabs only. Not in any
  pane spec; left as is.
- `// changed (breadcrumb):` the editor's ` src › main.rs ` row under
  the strip (`editor_view.zig`) registers `HitTarget.breadcrumb{ pane,
  idx }`; a click opens a Files pane at the directory the segment
  names, the F1 overlay explains it. Pinned rows and the sticky
  header moved one row down with it.
- `// changed (git toolbar, diff pane):` `git_toolbar.zig` is the row
  of ` icon label ` buttons above a diff pane and the git graph,
  centred, buttons dropping from the right until the rest fit, `Pop`
  after `Stash` while there is a stash. `diff_view.zig` paints Rust's
  three views — Inline (the whole file, the default), Hunk (`@@`
  headers with their own chips, three lines of context), Split (old
  left, new right, a header across both, a `·` filler) — under the
  diff toolbar (`Hunk   Inline   Split  │  Wrap … ×`) and the
  `Hunk N/M  file` banner with Stage / Discard (Unstage on a staged
  scope); the `/` filter keeps the hunks holding the needle; the right
  edge is the change-density strip. `App.git_divider` is gone.
- `// changed (request pane):` `request_view.zig` paints Rust's boxes
  — Method / URL / Send (Env / Save / Clear / Copy as… from 95 cells),
  the Request box with its `━`-underlined strip and `[⇔]─[A ▥ ▤]`
  chips, the Response box with the status title on its border and its
  own strip, the AI box. The tab title cuts the scheme and the query
  as Rust does. Under the Body / Headers / Source rows Rust
  `draw_edit`'s tail is painted: a blank row, then `⟳  sending…`,
  `▶ streaming · N events received` or `✗ last send: <error>`; the
  Params / Auth / Vars tabs do not paint it (their row count is not
  known to the caller). A JSON response is re-indented for the view
  only — `RequestPane.resp_pretty` / `displayBody()` feed the
  highlighter and the painter; `Response.body` stays the wire body
  (history, the diff, copy, the byte count on the title). The first
  cut had rewritten the body in `setResponse`, which broke two
  `http.zig` tests and would have put the pretty text into history.
- `// changed (send failure text):` `client.describe` takes the URL:
  a connect-class failure (refused, unreachable, a name that does not
  resolve) reads `connection failed: error sending request for url
  (<url>): <cause>` — reqwest's words in Rust, so the corpus's
  `env-resolution-mnml-overrides-rqst.test` finds the expanded host on
  the screen; the Zig cause is kept after it.
- `// changed (headless startup):` `e2e.driver.Config.startup_hook`
  — the headless loop runs the terminal loop's `startup` hook (config
  tasks, then the session restore); the `.test` runner leaves it off.
  A restored tree replaces the expanded set and keeps the top-level
  directories the session left shut (`tree.restored`).
- `// changed (residue):` the `ui-diff` runs differ from Rust in the
  LSP toast, the `LSP 1` chip and the `󱼀 󰐎` chips (cut), the version
  and the sampled system chip, and — on the diff run — the info panel:
  Rust still shows `fn · RS · main.rs` with the LSP chords there because
  its hover-help debounce (350 ms, committed on a later frame) never
  saw a redraw before the dump; a live Rust window shows `diff:
  worktree`, which is what Zig paints at once. The diff spec needs
  the fixture's `src/main.rs` dirty (`z` appended); the editor and
  request specs need it clean.
- `// changed (tests):` `tests/e2e/editor_tab_breadcrumb.test`,
  `git_diff_toolbar.test`, `git_diff_views.test`, `http_request_pane.test`
  (new), `http_edit_split.test`, `http_plus_chip.test` (updated) —
  each fails on main's binary. Unit tests: the spec snapshots with
  their hits in `bufferline.zig`, `diff_view.zig`, `git_toolbar.zig`,
  `request_view.zig`, `editor_view.zig` (the breadcrumb row); the
  wire-body / view-text test in `request_pane.zig` and the send-state
  rows in `request_view.zig`, each watched failing with a break in the
  painter first.

## Git mode (2026-09-07, branch `git-mode`) — `// changed:` notes

The Git activity section as the Rust editor has it — the palette in
the sidebar, one graph tab per repo, the detail column on the graph's
right — painted cell for cell against `docs/ui-spec/rust-git-120x40.txt`
(`steps-graph2.jsonl`) and the new `rust-git-80x24.txt`.

- `// changed (mode):` `src/app/git_palette.zig` — `State.active` is
  Rust's `active_section == Git`, `State.pre` its `pre_git_layout`.
  `view.activity_git` / `git.graph` / `git.branch_rail_toggle` enter:
  `git.discover` runs again (the workspace roots may have landed after
  the first tick's look), the sidebar snaps to a fifth of the screen,
  the current layout is stashed and replaced by one leaf holding a
  `git_graph` tab per discovered repo (reused when it exists, skipped
  when its tab was closed this session — `App.forceClosePane` records
  the repo, the strip's `+` and the pill's `Reopen:` rows bring it
  back through `git.reopen_repo`), the focus lands on the graph as
  Rust's `open_git_graph` leaves it. `activity_bar.enter(app, s)` is
  the first line of every `view.activity_*` runner: any other section
  leaves, which puts the stashed layout back (the graph panes stay in
  the store). `activity_bar.active` reports Git while the mode is on,
  whatever has the focus. The right-panel GIT rail and its branch-rail
  rows are gone; `PanelId.git` now names the palette (its `.row` /
  `.filter_input` / `.chip` / `.scrollbar` hits), and `git.State` lost
  `rail`, `filtered`, `rail_open`, `rail_folded`, `selectedRow`.
- `// changed (palette):` `src/ui/git_palette.zig` — the caps header
  with the refresh chip, the ` repo 󰅀 ` pill (`HitTarget.git_palette =
  .repo`, the Repos menu: switch / reopen / add workspace), the `⎇`
  row with `↑n ↓n` (`.branch`, the checkout picker), Rust's filter row
  (the glyph at the second cell, the `…` tail clip keeping `max_text`
  code points), then WORKTREES / LOCAL / REMOTE / PULL REQUESTS: a
  header row per section with its count two cells in from the edge,
  `/`-prefix folder rows, `⌂ · ● ○ ☁` markers, a gap row after each.
  The rows come flat from `git_palette.rows` — the same list the click
  and key handlers rebuild, so an index means the same thing in both;
  the scroll skips item rows and keeps headers, as Rust does. A left
  click / Enter selects the ref and jumps the graph to its commit
  (`sha` from the rail's `for-each-ref`, no rev-parse round trip);
  right-click / `m` opens Rust's row menus through
  `MenuAction.git_palette` (`core/command.GitPaletteAct`).
- `// changed (graph):` `src/ui/git_graph_view.zig` rewritten to the
  spec: the git toolbar row (`git_toolbar.zig`, dropped under 40
  cells or 6 rows), the list on the left with Rust's column header and
  `compute_column_widths` (sha 9, date 13/11/6, author 8..22 from the
  visible window, branch chips 8..24), rows as `▌` in the lane colour,
  `▶ `, chips, the graph cells with `lane_spacing` pads joining `─`
  runs, ` │ ` separators, the subject padded, the author and the
  `MM/DD HH:MM` date (the statusline clock's zone — the machine's, or
  UTC after `clock.utc`; Rust's `TZ_OFFSET_HOURS` knob is gone — 2026-09-22)
  right-aligned, the nine-char sha, two pad cells. `layout` is Rust's
  lane walk: rounded corners `╭╮╰╯`, a freed lane cools for five rows,
  `┼` where a `─` run crosses a passing lane, colour = lane index.
  The detail column at Rust's width (drag → `ui.git_graph_detail_col`
  → a third clamped 28..60, none under 80) shows the working tree on
  the WIP row — `─ WIP @ branch · summary`, `▾ Unstaged Files (n)` with
  ` Stage All ` at the edge and a ` [+] ` per row, `▾ Staged Files (n)`
  with ` Unstage All ` and ` [−] `, the commit box pinned to the bottom
  (`▾ Commit · …`, the textarea, ` Commit  AI Message  Clear `, the
  hint) — and a commit's `─ sha · author · age ─` rule, reflowed and
  wrapped message, parents and `changed files (n):` otherwise. The
  hit ids: rows by virtual index, `sortId`, `divider_id`,
  `wipButtonId` (the two section buttons, the box's three, the
  textarea), `wipFileId` (a row / its button, unstaged / staged),
  `detailRowId` moved to `0xF800_0000` — `0xF300_0000` is the toolbar's.
  A cut button keeps its visible cells as a hit (Rust drops the rect
  whole: a 31-cell column's Stage All is dead there).
- `// changed (graph state):` `GraphPane` gained `name` (the tab's
  title — the repo's), the commit box (`wip_text` / `wip_cursor` /
  `wip_focused` / `wip_ai`) and lost `detail_open`: the column is
  always there. `SortCol` is Rust's `none / author / date / sha`.
  Keys: Enter opens the selected commit's diff (the WIP row's: HEAD's),
  Tab walks the detail column's files (`s` / `u` stage and unstage a
  working-tree row, Enter opens the file's diff), `c` on the WIP row
  commits the box's text (the prompt when it is empty), `C` asks for
  an AI message (`git.ai_commit` — the reply still lands in the
  prompt, not the box), Ctrl+Enter in the box commits, Esc blurs.
  `git.graph_detail` focuses the column. `wipFiles` is the one list —
  unstaged (modified / untracked `?` / conflicted `!`) then staged,
  A–Z — the painter, the keys and the clicks share; an untracked
  directory shows as its name (git's own untracked mode: `git status`
  no longer runs `--untracked-files=all`, so the status pane and the
  tree marks list `requests/` once, as Rust reads it). `git log` runs
  `--date-order`, Rust's order.
- `// changed (chrome):` `pane.title()` of a graph is its repo's name;
  `info_view` says nothing for a graph pane and shows the sidebar's
  words in git mode (Rust's box); the statusline's mode chip reads
  `VIEW` there as Rust's does. `discovery.describe` explains the pill
  and the branch row. `git_status_view.zig` paints status rows only.
- `// changed (residue):` the `ui-diff` git runs differ from Rust in
  the statusline's cut `󱼀 󰐎` cells only; at 80×24 also in the
  statusline's narrow rule (Rust `main …`, Zig `main  󰐙 2`), which is
  the statusline track's. `steps-editor` / `steps-diff` / `steps-http`
  are at main's counts (8 / 28 / 2). Not in this cut: stashes and tags
  sections (the rail has no such data yet), the `+N more` branch cap,
  the hash-typing header chip (the jump stays a prompt), the AI
  message streaming into the box.
- `// changed (tests):` `git_palette.zig` (spec rows, hits, colours,
  scroll, folders), `git_graph_view.zig` (the spec's rows at 95, the
  lane table, the detail width precedence, the sort arrows, the
  helpers, the commit detail and the caret), `app/git_palette.zig`
  (rows, filter, folds, activate), `app/git.zig` (enter / leave /
  reuse; the smoke, graph and WIP tests re-aimed); `tests/e2e/
  git_mode.test` (enters, stages from the detail column, types in the
  box, leaves), `git_graph_detail.test` and `git_graph_detail_wrap.test`
  re-aimed. Corpus 360/361 (the designed skip); no `git_*.test` flipped.

## Overlays (2026-09-07, branch `overlays`) — `// changed:` notes

The prompts, confirms, pickers, the palette, which-key, the help
overlay and click discovery painted as the Rust editor paints them,
against `docs/ui-spec/rust-{palette,picker,rename,delete,goto,whichkey,
help,discovery,close}-120x40.txt` (the steps beside each).

- `// changed (frames):` `ui/overlay.zig` gained `Look` — `popup`
  (rounded, the tooltip / menu / hover), `menu` (square, the title in
  plain bold: Rust's `popup_menu` — prompt, confirm, which-key) and
  `modal` (square, the title an accent chip: Rust's `modal_panel` —
  picker, help, discovery). `frameLook` / `boxLook`; `frame` / `box`
  stay `.popup`. `render.drawOverlay` places the prompt, the confirm,
  the picker and which-key on the whole screen, as Rust's
  `frame.area()` does — they sat on the pane area before.
- `// changed (confirm):` `ui/confirm.zig` has two button rows —
  `.bracket` (the close prompt: `  [S]ave  ` from the left, gap 2, six
  rows) and `.plain` (a delete: `  Delete  ` / ` Delete permanently ` /
  ` Cancel ` right-aligned, gap 1, five rows). The tree's delete asks
  Rust's `Delete <rel>?` (a directory: `recursively? (n entries)`,
  an entry in the trash: `(permanent — already in the trash)`) with
  Cancel focused — Enter is not the destructive act (`tree_delete_enter`
  / `files_trash_clipboard` re-aimed). `Overlay.confirm.return_focus`
  as the prompt's, so the mode chip reads TREE under it.
- `// changed (prompt):` the rename is `Rename <rel>` seeded with the
  name (`tree.acceptRename`: a bare name stays beside the source);
  go-to-line is `Go to line  (currently N)`. The close-prompt and
  quit messages lost their two leading spaces — the painter indents.
- `// changed (tree):` `Tree.previewCursor` — under the standard profile
  with `ui.tree_preview_on_arrow` an arrow / page / home / end / j k g G
  / ← → opens the file under the cursor as the preview (`App.openPreview`
  replaces the last clean preview pane, `App.preview_pane`) and hands
  focus back to the tree. The first cursor row is the first entry, not
  the section header (Rust's header is not a row). The rename / delete
  specs need both; the tree track owns the italic preview tab, not here.
- `// changed (which-key):` the title is `<leader>` / `<leader> f`;
  labels carry their own `+`; the root reads as Rust's (`e explorer`,
  `q close buffer`, `w write/save`, no `x`); `+pr` is there with two
  `dead` leaves (`whichkey.Node.dead` — a row for a command neither
  editor has; a press says so). Zero differing lines.
- `// changed (picker):` `ui/fuzzy.zig` is Rust's `fuzzy_match` bonus
  for bonus, counting code points; `Picker.rank` is Rust's `refilter`
  (`RankOpts`: priority, score_bonus, the palette's ids for the exact-id
  pin and the substring +100) and `dispatch.refilterPicker` calls it —
  the label alone is scored. The box is Rust's geometry (`Picker.place`,
  `ui.picker_position`), the row Rust's budget (marker, label with the
  matched characters in the accent, gap, ` detail `, the bar column).
  The wheel walks the cursor; the bar's track pages. `Overlay.picker`
  carries `priority` / `score_bonus`.
- `// changed (palette / files):` the palette row is `group  ·  title
  ·  id`, the detail the default chords joined by ` / `
  (`cmd_picker.chordHint`), the pane-scoped +20; `Open file` is Rust's
  list (`cmd_picker.walkTree`: recents, the tree's order with dotfiles
  and `.gitignore`, cross-workspace recents a tier below) with the
  directory as the detail. Residue: the palette's count and three git
  rows are commands only mnml-zig has (914 vs 796).
- `// changed (help):` `ui/help_overlay.zig` (state, keys, painter) and
  `app/help.zig` (Rust's `build_help` rows from the registry and the
  active keymap reversed — `Chord.unpack` / `format` — plus the modes
  and stress-meter sections); `Overlay.help`. F1 is `view.help`
  (toggle), as in Rust; `view.discovery` is unbound. The cheatsheet
  pane stays on `<leader>ch` / `view.cheatsheet`. Residue: section
  counts (Zig's registry is larger).
- `// changed (discovery):` `Overlay.discovery` — Rust's panel
  (`discovery.Category`, eleven rows with the frame's hit counts, a row
  press flashes the family for two seconds via `App.discovery_flash`,
  F1 / Esc / a press elsewhere close). The old label-every-hit overlay
  and `discovery.explain` are gone; `describe` stays for the tooltip and
  the info view. The GIT rail header, gutter, fold and code-lens rows
  count nothing — those register no hit here.
- `// changed (tests):` unit tests in `overlay.zig`, `confirm.zig`,
  `fuzzy.zig` (Rust's table), `picker.zig` (geometry at 80 / 120 / 200,
  the palette row, rank), `which_key.zig`, `help_overlay.zig`,
  `app/help.zig`, `app/discovery.zig`, `app/trash.zig`, `cmd_picker.zig`;
  e2e `overlay_{help,palette,picker,prompts,whichkey}.test`,
  `ui_discovery_f1.test` re-aimed.

## Git status (2026-09-07, branch `git-status`) — `// changed:` notes

The staging pane painted as the Rust editor paints it
(`docs/ui-spec/rust-git-status-120x40.txt` and `-80x24.txt`, from
`steps-status.jsonl`). Status diff 74 → 2 lines at 120×40 (the rail
marker, below) plus the statusline's live cells.

- `// changed (git status view):` `ui/git_status_view.zig` is Rust's
  `git_status_view.rs` cell for cell: `on <branch>   N unstaged · M
  staged`, the hint row — clipped at the pane's edge, never dropped
  word by word (Rust at 80 columns shows `⏎ di█`) — `Unstaged changes
  (N)` / `Staged changes (N)` with `(none)`, `▶ X path` on the cursor's
  row with only its text on `bg2`, the scrollbar column from eight
  cells, `✓ working tree clean`. Every entry row is `.script_hit{ pane,
  flat index }`; every hint word is `.script_hit{ pane, hintId(action)
  }` — Rust registers no hint hits, this one does, so a click on `s`
  is the key. The provider badge, the rail's grouped rows (headers,
  collapsed groups) and `Reading git status…` went with the pane that
  painted them.
- `// changed (git status keys):` `app/git.zig` `statusPaneKey` is
  Rust's `Pane::GitStatus` arm: `j k ↑ ↓`, page up / down, `g G home
  end`, `space s u a A ⏎ c C r`, `b B w` (checkout / new branch /
  worktrees), esc back to the tree (the pane closes instead when the
  tree is hidden). `s` on a staged row and `u` on an unstaged one toast
  Rust's words; enter on an untracked file toasts `no diff for that
  file`. The cursor keeps its flat index across a stage (Rust's
  `selected`). The old `x o n q` letters are gone.
- `// changed (git status model):` `app/git.zig` `collectFiles` is one
  pass over the snapshot for both the status pane (`statusFiles`:
  porcelain order, `?` / `U`) and the graph's detail column
  (`wipFiles`: A–Z, `!`, the untracked directory's slash dropped);
  `Row` is `git_status_view.Entry` (`path`, `letter`, `staged`).
  `State.rows`, `collapsed` and `rebuildRows` are deleted; `cmd_git`'s
  `selectedRow` reads the pane's cursor through `statusPaneRow`.
- `// changed (dispatch):` the wheel arm for `.git_status` calls
  `statusPaneWheel` (the flat count, not the old rail rows) — one line.
- Residue: the rail marker. `app/activity_bar.zig` `sectionOfPane`
  maps `.git_status` to `.git`; Rust leaves the marker on Files for
  the status pane (only the graph moves it). One line, section-side's
  file. At 80×24 also the info view's `Sidebar` hover text and the
  statusline's narrow branch chip, both other tracks'.
- `// changed (tests):` unit tests in `git_status_view.zig` (lines, the
  spec's rows at 89 and 49 cells, hits, colours, scroll, ASCII) and
  `app/git.zig` (`statusFiles`); e2e `git_status_{stage_keys,toggle,
  all,enter_diff,click}.test`; `git_status_pane.test` unchanged.

## Section sides (2026-09-07, branch `section-side`) — `// changed:` notes

Every activity section has a side; the frame has a left column (the
rail down its edge) and a right column, and each shows one section.
Rust's sidebar + tabbed right panel became one idea.

- `// changed (model):` `app/side.zig` — `Side`, `surface(s)` (the
  tree, git mode's palette, a list panel; null for the pane-backed
  sections), `State { of, open, last, prev, right_width }` on
  `App.side`. `tree.visible` stays the explorer's own open flag (Rust's
  `tree_visible`); `shown(side)` reconciles it. `place` / `remove` are
  the only writes. `App.right_panel` and `App.right_panel_width` are
  gone; `render.frameRects` carves both columns (`Chrome.right`,
  `FrameRects.right` / `right_divider`) under Rust's 21-column clamp.
- `// changed (defaults):` TODOS / NOTES / FINDINGS start on the left
  (Rust's `ActivitySection`); the outline and the diagnostics on the
  right (Rust's `right_panel_panes`). `ui.right_panel_width` is Rust's
  32 now, not 40 — the panels' 40-cell chrome is the panel track's.
- `// changed (sections):` `Section` gained `diagnostics` and `outline`
  — a side and a column, no rail row (`Section.rail` is what paints);
  `PanelId.outline`. `outline.show` keeps Rust's rule (the column when
  it is open, else a split) through `App.outline_panel`, a pane in the
  store outside the layout; the right column's walk always uses the
  column (`outline.showInColumn`). `lsp.diagnostics` places its section.
- `// changed (commands):` `view.move_section_left` / `_right` act on
  the focused section, else the rail's mark; a shown section closes on
  one side and opens on the other with the keys, and the vacated
  column falls back to what it showed before (the explorer). The
  `view.toggle_right_panel` / `focus_right_panel` /
  `right_panel_{next,prev,close}_tab` ids act on the right column; a
  toggle and a tab walk leave the keys where they are (Rust's panel).
  `view.toggle_tree` toggles the left column whatever it shows.
- `// changed (ui):` the rail menu's second row is "Move to right side"
  / "Move to left side" (`MenuAction.move_section` names the section the
  menu was opened on); the palette lists the pair; vim `Ctrl-W H` / `L`
  in a section or the tree move it (`side.ctrlWCommand`, shared with the
  tree's pending flag; an editor keeps the split moves); which-key
  `+split` `H` / `L`; `:sidebar left|right`. A left-column section reads
  `TREE` in the mode chip and `tree` on the wire (Rust's sidebar), the
  right column `PANEL`; the info box is titled with the section. The
  right column carries Rust's strip row — the title and a `×`
  (`Button.right_close`) — so its content lands where Rust's does.
- `// changed (config / session):` `ui.sidebar_side` (the Settings row
  "Default sidebar side", beside the width rows) and `ui.section_side`
  (a typed struct of optional sides, the loader's `Patch` overlays it);
  `session.zon` keeps every section's side (`sides`) and both columns
  (`left` / `right`, `tree_visible` still the explorer's).
- `// changed (git):` git mode places its section: on the right the
  snap takes the right column to a fifth and the palette paints there;
  leaving puts the explorer back only in its own column. `steps-graph2`
  stays at 2.
- `// changed (specs):` `steps-{todos,notes,findings,outline}.jsonl` +
  `rust-*-120x40.txt`; the columns match, the rows inside are the
  panel track's (`docs/ui-spec/README.md`).
- `// changed (tests):` `app/side.zig` (defaults, config resolution,
  move, the right column's walk and focus rules, the layout with
  sections on one side / both / none, the vim chords, git on the
  right), `activity_bar.zig` (the menu rows), `session.zig` and
  `settings.zig` re-aimed; `tests/e2e/section_move_{command,
  rail_rightclick,vim_ctrl_w,ex_sidebar}.test`. The `todos_panel` /
  `notes_panel` / `findings_panel` corpus files drag the left column
  out to 60 (the 26-cell header keeps only the chips' icons).

## debug-ui (2026-09-07) — the debugger, Zig-authored

The one deliberate departure from same-look: the Rust debug pane was
never driven by anyone, so `docs/ui-spec/zig-debug-*.txt` are the spec
(`tools/zig-spec.sh`).

- `// changed (section):` `PanelId.debug` / `Section.debug` own a column
  surface (`side.surface`), so the section moves sides, takes the keys,
  and reads TREE / PANEL like the rest. `view.activity_debug` places it;
  `dap.show` places it and opens the console pane; `dap.toggle_panel`
  (`<leader>du`) toggles it. `src/app/debug_panel.zig` + `src/ui/debug_panel.zig`:
  one `ListPanel(Row)` list — a status row (`● prog.dbg:4 · main` at the
  sidebar's width), VARIABLES / WATCH / CALL STACK / BREAKPOINTS as
  foldable headers with counts, every row a hit with a right-click menu
  of command ids, the `dap.*_selected` family (`toggle_section`,
  `toggle_selected`, `edit_selected`, `remove_selected`, `open_selected`,
  `watch_selected`, `copy_value`, `edit_watch`) so a key, a menu row and
  the palette share one runner. A variable whose value changed since the
  last resume paints in the warning colour (`State.prev`, snapshotted on
  `continued`).
- `// changed (breakpoints):` `types.Breakpoint` gains `enabled`,
  `log_message`, `verified`; `Session.setBreakpoints` sends the enabled
  ones with `logMessage` and the reply's `verified` lands per file through
  `bp_paths` slots. New ids: `dap.toggle_breakpoint_enabled`,
  `dap.remove_breakpoint`, `dap.set_breakpoint_log_message`,
  `dap.enable_all_breakpoints`, `dap.disable_all_breakpoints`. The
  `dap.*breakpoint*` prompts act on the section's selected row when it
  has the keys, else the cursor line (`bpTarget`). Gutter glyphs: `●`
  plain, `◐` conditional / hit-counted, `◆` logpoint, `○` disabled;
  unverified paints muted (was `◆` / `◈`).
- `// changed (pane):` `Pane.dap_repl` and `ui/dap_repl_view.zig` are
  gone. `Pane.debug` is the step toolbar (`ui/debug_toolbar.zig`:
  Start/Continue/Pause · Step over · Step into · Step out · Restart ·
  Stop, nf-md glyphs, a drop rule) over the Debug Console
  (`ui/dap_view.zig`): output, `> expr` echoes, results (a composite
  folds on click), errors, `── started / exited ──` notes in one
  scrollback (`dap.State.console`, kept across sessions), an input row
  with ↑↓ history (the typed line comes back) and Tab completion of
  variable / watch names. `dap.repl` focuses it; `dap.clear_console` /
  Ctrl+L empties it. The same toolbar paints as a strip over the active
  editor while a session is live (`ui.debug_toolbar` auto/always/hidden);
  its buttons are `.script_hit` ids above `lsp_decor.lens_hit_base`.
- `// changed (editor):` `HitTarget.gutter{pane,line}` over each row's
  gutter: a left press on the sign cell toggles the breakpoint, a right
  press opens the Breakpoint menu (`context_menus.openGutterMenu`);
  `Doc.stopped_line` wears the band; `editor.inline_values` paints
  `  name = value` after every line up to the stop naming a scope
  variable (`dap.inlineValuesFor`, merged with the LSP's virtual text);
  the hover tooltip on a cell shows the variable's value from the
  fetched scopes (`dap.hoverValue`); `lsp.hover` (vim `K`) evaluates the
  word through the adapter first while stopped (`dap.evaluate_hover`,
  `Session.EvalContext.hover`, into the LSP hover box). A frame chosen
  in CALL STACK sets `Session.frame_id`; evaluations and scopes follow.
  `dap.continue` starts a session when there is none (nvim-dap);
  `dap.restart` starts the last file again.
- `// changed (keys):` the vim profile gets nvim-dap's chords as `.vim`
  keys (`<leader>d b B l c o i O p R t r w u h`) plus a `+debug`
  which-key group; the F-keys stay `.both`. Pinned in
  `src/app/cmd_dap.zig`; the table is in `docs/KEYMAP_PROFILES.md`. The
  group is `vim_only` (`whichkey.Entry`): `lookupIn` / `continuations`
  take the profile, so the standard `Ctrl+K` popup keeps Rust's rows
  (`steps-whichkey` stays at 0) and `<leader>d` is a vim door only.
- `// changed (config / settings):` `editor.inline_values` (Settings →
  Editor "Inline debugger values"), `ui.debug_toolbar` (Settings → UI
  "Debug toolbar strip"); `docs/CONFIG.md`.
- `// changed (tests):` six REPL-era scripts re-aimed at the console
  (`dap_session_repl`, `dap_repl_filter`, `dap_repl_pane`,
  `dap_repl_selection`, `dap_session_output`, `dap_session_terminate`);
  ten `debug_*.test` scripts; `render.zig`'s hit test reads the gutter
  as `.gutter`; two settings tests run taller (the UI section grew).

## Info view focus rule (2026-09-07, branch `info-view`) — `// changed:` notes

- `// changed (info view):` the ladder in `src/app/info_view.zig` reads
  the surface under an overlay — `focusUnder`: the prompt's, the
  confirm's or the menu's way back, else the active pane, else the tree
  — where it used to return nothing on `.overlay` and fall to the
  `Editor` one-liner. Rust has no overlay focus (`app.focus` stays on the
  surface while a picker or a confirm is up), so its box keeps the
  `Sidebar` line under the picker / discovery / palette / help with
  nothing open, and the walked row's doc under the tree's delete and
  rename boxes. A file open with the tree focused at its first row still
  falls through to the editor's summary — that is Rust's ladder too
  (`describe_focus_target` says nothing at cursor 0), checked on the
  Rust binary. The `.overlay` arm of the one-liner is unreachable now.
  Residue: the picker's own way back is the pane (`cmd_picker`), so a
  picker over a tree walked past its first row with a file open shows
  the file's summary where Rust shows the row's doc.
- `// changed (tests):` a unit test for each rung under an overlay (the
  picker with nothing open, the delete confirm with and without a way
  back, the kebab's menu from the tree, a hovered chip over a walked
  row, the file open at the first row and past it, the pane, the git
  palette from its panel and from a prompt over it);
  `tests/e2e/info_view_focus_under_overlay.test`. `ui-diff` box rows at
  120×40: picker 12 → 4, delete 24 → 10, rename 24 → 10, discovery
  12 → 4, palette 42 → 34, help 16 → 6; the editor screen's 8 were never
  the box (the LSP toast and the statusline's chips).
## The outline pane and the right column's strip (2026-09-07)

`docs/ui-spec/rust-outline-120x40.txt` at residue: 76 → 8 differing
lines, all of them the LSP toast and the statusline's stock / now-playing
/ `LSP 1` chips (the fixture has no server for Zig).

- `// changed (outline):` `ui/outline_view.zig` is Rust's
  `outline_view.rs` cell for cell — the two-cell arrow column (`▶` the
  pane's cursor, `●` the row the source cursor is in, in Rust's purple
  / yellow), the kind right-aligned in ten cells in its family's colour
  (`kindColor`), the name bold on the selected row, the hint in Rust's
  three width tiers (`hint`: `⏎ jump   r refresh   / filter   esc back`
  ≥ 52, `⏎ jump · / filter · esc back` ≥ 30, `⏎ / r / esc`), the
  `  / query█` line while a filter is typed or held, `(no symbols)` /
  `(no matches)`, and a scrollbar column reserved down the whole right
  edge from eight cells (`bar_min_w`) so the body never reflows. The
  one departure: the header stays put and the list scrolls under it
  (Rust scrolls the header lines off with the rows); the bar measures
  the list alone.
- `// changed (outline / keys):` `OutlinePane.query` + `filter_mode`
  (Rust's `/` type-to-narrow): `/` enters; in filter mode `⏎` leaves
  holding the filter, `esc` clears and leaves, Backspace pops a
  character, everything else appends; outside it `esc` with a filter
  held clears it before a second `esc` returns to the source. The
  cursor is an index into the filtered view (`visible`, `fuzzy.score`
  on the name); `jump` / `clickRow` resolve through it. `q` closes
  (Zig's; Rust has no key for it).
- `// changed (2026-09-07, strip rule):` the strip row is painted only
  over the pane-backed sections Rust's right panel tabbed — the outline
  and diagnostics (`side.hasStrip`). A section MOVED to the right (TODOS,
  NOTES, HTTP, the explorer …) is still a section: it starts with its
  caps header on either side and gets no strip, so its title is not
  painted twice. The scripts that used `TODOs  ` (the strip's chip) as
  the right column's fingerprint now use "the tree's file and the
  section's rows both on screen"; the header's ⟳ / `+` sit on row 1.
- `// changed (section-side / strip):` `ui/side_strip.zig` paints the
  right column's strip row as Rust's tab strip: the chip ` title `
  (bold on `bg2`, the outline's live `tabTitle` — `main.rs ⌥1`, `main.rs
  ⌥` when empty), a one-cell gap, the green ` 󰐕 ` on `bg_dark`, the
  `bg2` bridge from the chip to the `×` one cell in from the edge, the
  edge cell on the column's ground; a chip that does not fit clips to
  ` lab… `. Hits: the chip → `Button.right_tab` (`view.focus_right_panel`
  — one section shows at a time, so the chip focuses rather than
  selects), the plus → `Button.right_new` (`context_menus.openAddPanelMenu`:
  Rust's five rows Outline / Problems / AI chat / Grep / Tests), the
  `×` → `Button.right_close`. `render.drawRightStrip` is the one call.
- `// changed (buttons):` `integrations_view.chip_base` moves from
  `0x10` to `0x0300` (`max_chips` stays 0x30). Dispatch tests the chip
  range before the `Button` switch, so ids 16..63 — `split_max`,
  `hidden_tabs`, `right_close` and the two new strip buttons — were
  routed to the palette bar's integration chips; every chip id is
  `chip_base + i`, so nothing else moves.
- `// changed (tests):` `outline_view.zig`'s three tests re-aimed at
  the two-cell arrow / ten-cell kind / always-reserved bar (the old
  `▶       fn` / `selection` bg on the current row); new: the hint
  tiers, the query line, the empty states, `side_strip.zig` at 32 / 14
  / 12 / 4 cells, the strip through `App` (title, plus → menu, close);
  e2e `outline_filter_jump.test`, `right_strip_add_panel.test`.

## TODOS / NOTES / FINDINGS — the `+ New …` row (2026-09-07)

The user kept Zig's rows on the three list panels (the `󰍉 / filter`
pill, the `TODOS (0)` spacing, the one-line empty state, the info
copy); the one addition is Rust's `+ New …` action row, with a blank
row directly under the filter (the user's ask) and Rust's blank row
after the chip. So the three specs stay at residue, not zero:
`steps-todos` 22 → 24, `steps-notes` 24 → 26, `steps-findings` 24 → 26
— the row shift from the extra blank, the filter pill, the header
spacing, the empty state's `…` clip, the info copy, the version and
the statusline chips. `docs/ui-spec/README.md` lists the hunks.

- `// changed (list-panel):` `ListPanel.Props.new_label` paints the
  row once for every panel that asks (`ui/list_panel.zig`): a blank
  row, ` label ` on the green fill at `x + 1` (`chip.newRowStyle`,
  Rust's `action_button::primary`), a blank row, then the list; in
  the empty state too. Its hit is `.chip{panel, .new}` over the chip
  cells alone (Rust's rect), which the panels already route to
  `todos.new` / `notes.new` / `findings.new`. `State.on_new` is the
  cursor on the row: `k` / `↑` / `PgUp` / `Ctrl-p` from row 0 climb
  onto it (in the filter too), `j` / `↓` / `Ctrl-n` drop back to row
  0, `g` / `G` / Home / End leave it, typing in the filter puts the
  cursor back on row 0, and `⏎` there is `Outcome.new_activate` — the
  three panels run their `newCmd` (the prompt), the other five
  `ListPanel` users get a no-op arm. A row click clears `on_new`
  (`rowMouse` / `kebabMouse`).
- `// changed (verified, no change):` the `sort:` chip family was
  already Rust's — click cycles (`todos.sort` …), right-click lists
  every mode with a ✓ (`openSortMenu`), the icon rung under the full
  form's width (`header.zig`'s ladder, tested at 26 / 30 / 34 and 60),
  persisted as `ui.<panel>_sort` and read back at `App.init`.
- `// changed (tests):` `list_panel.zig` gains the New-row test
  (paint, hit, the cursor ladder, the empty state, a 6-cell clip);
  e2e `panel_new_row` (keys + click, all three panels, empty and
  populated), `panel_sort_chip` (click cycles + persists
  `ui.todos_sort`, the right-click menu with ✓), `panel_filter_keeps_refresh`
  (typing grows the count without deleting the ⟳), `panel_kebab_menu`
  (a click on a row leaves the pointer there; the kebab opens the row
  menu). `panel_new_row` was break-checked (the todos label removed →
  "screen does not contain `+ New todo`").
---

## The branches panel (2026-09-07, branch `git-palette`) — `// changed:` notes

The git column is rebuilt as a branches panel — the second deliberate
departure from same-look after the debugger. The spec is the Zig
screen (`docs/ui-spec/zig-git-palette-*.txt`, `tools/zig-spec-git.sh`).

- `// changed (worker):` `Result.rail` carries `worktrees:
  []parse.Worktree` (path, branch, head, detached, bare, locked +
  reason, main, dirty — the worker runs `status --porcelain` inside
  each tree), `remotes: []parse.Remote` (name, url, `Provider`),
  `stashes: []parse.Stash` (sha, `stash@{N}`, message) and `tags:
  []parse.Tag` (name, the peeled sha, annotated; newest first, the
  version as the tie-break). `parse.zig` gains the four parsers with
  canned-output tests; the worktrees picker reads `parseWorktrees`.
  `Job.stash_pop` takes `?[]u8` — the stash to pop, null for the
  newest. `git.State` gains `rail_remotes` / `rail_stashes` /
  `rail_tags`; `rail_prs` stays for the statusline's PR chip.
- `// changed (ui):` `ui/git_palette.zig` is the panel: `Row` is
  `section | branch | remote | remote_branch | worktree | stash | tag |
  gap`; `Props{rows, repo, viewing, filter, filter_caret,
  filter_focused, cursor, scroll}`; `draw` returns `Painted{scroll,
  visible, caret}`. The pill row keeps the refresh chip (`.chip{.git,
  .refresh}`) at its right edge; `Viewing N` is row 1; the filter row
  is `filter_input.draw` with `.panel = .git`; the list is one
  `list_panel.scrollWindow` over every row, the scrollbar in the last
  column on overflow. Column 0 is the gutter (check / lock / the cursor
  marker); the right edge holds the section count, the ahead / behind
  (`trackText`) and the dirty dot, one cell in. `currentBg` is the
  checked-out row's ground (the theme's green over the panel, as
  `diff_view.addedRowBg`). `Part` is `repo` alone — the branch row is
  gone, and `discovery.zig`'s hover for it with it.
- `// changed (app):` `app/git_palette.zig` builds the five sections
  in a fixed order (always all five, the count the filtered one), folds
  through `State.collapsed` for the run, and keeps `filter` /
  `filter_caret` / `filter_focused` / `cursor` / `scroll` / `visible` /
  `total` flat (as before, so `context_menus.zig` reads the cursor
  unchanged). `select` (a click) moves the cursor and jumps the graph to
  the row's commit — a branch's sha, a worktree's HEAD, a stash's
  commit, a tag's peeled sha; `activate` (Enter, or a click on the
  cursor's row) acts: `checkout`, the tracking branch of a remote's
  short name, `openWorktree` (the tree joins the workspace roots
  through `tree.addRoot`, the repos are rediscovered, the graph tab
  switches), `stash_apply`, the checkout confirm for a tag. The wheel
  and the scrollbar keep the cursor inside the window so the paint's
  clamp does not pull the scroll back.
- `// changed (core):` `GitPaletteAct.what` gains `remote_fetch`,
  `remote_copy_url`, `worktree_open`, `stash_apply`, `stash_pop`,
  `stash_drop`, `tag_checkout`, `tag_delete`, `tag_copy` and loses
  `pr_open` / `pr_copy`. `git.Confirm` gains `tag_delete`. A worktree's
  shell opens a `pty_pane` with the tree as `cwd`.
- `// changed (spec):` `steps-graph2.jsonl` now differs from
  `rust-git-120x40.txt` on the sidebar rows only; the pane columns
  still match line for line.
- `// changed (tests):` five painter tests (the 26-cell spec column,
  the cursor / caret, the one-list scroll, 16 / 20 / 24-cell clipping,
  ascii), four state tests (rows, filter + folds, select / act / keys,
  every row menu resolves), a worker integration test on a seeded repo,
  seven `git_palette_*.test` scripts; `git_mode.test` and the git-mode
  unit test re-aimed at the new rows.
- `// changed (header):` the panel starts with the caps `GIT` header
  every panel in the column has (`header.draw`, `.panel = .git`, the
  refresh chip at the right edge — the header owns the chip and its
  `.chip{.git, .refresh}` hit now, the pill row has only the pill).
  The rows then follow TODOS' order: header, filter, blank, pill,
  `Viewing N`, blank, the list — `head_rows` 4 → 6; every
  `git_palette_*.test` click moved with them, and `git_mode.test`
  asserts the header instead of its absence.
- `// changed (repos):` the pill is followed by the tab strip's two
  chevrons (`bufferline.arrow_*`, 3-cell slots, the same lit / dim
  styles; `Part` gains `repo_prev` / `repo_next`): the previous / next
  repo in discovery order, wrapping, dim and inert with one repo. `[`
  / `]` on the focused panel and `git.repo_prev` / `git.repo_next` do
  the same (`stepRepo`); a switch also brings the repo's graph tab to
  the front (`selectRepo`), as the pill menu's rows now do.
- `// changed (all repos):` the pill menu leads with `All repos`
  (`GitPaletteAct.all_repos`, `git.palette_all` toggles it,
  `State.all`, saved as `Saved.git_all` in `session.zig`): every open
  repo's rail is listed at once — `rows` builds each section from a
  `RailView` per repo and puts a `.repo` sub-header (muted, indented
  like a remote's name; `Props.grouped` indents the item rows one
  level further) above each repo's rows, the count the sum, `Viewing
  N` over every row. `git.State` gains `rails: AutoHashMap(repo id,
  RepoRail)` — the rails of the repos that are not the active one,
  each on its own arena (`requestRailFor` asks, the `.rail` result for
  a non-active repo lands there); `switchTo` MOVES the active rail into
  `rails` and the target's out (`parkRail` / `unparkRail`), so a row's
  slices stay valid across the switch. Under All repos a row's action
  is its own repo's: `select` / `activate` / `openRowMenu` first make
  that repo the active one (`switchToRowRepo`, the graph tab follows)
  and then run as with one repo; the chevrons step to the first / last
  repo and leave All repos. `afterChange` on a non-active repo refreshes
  its parked rail. Spec: `zig-git-palette-all-120x40.txt`,
  `tools/zig-spec-git.sh <name>-all` seeds `ws/alpha` + `ws/beta`.

## Session workspace compare (2026-09-07, branch `session-realpath`) — `// changed:` notes

- `// changed (session):` `session.restore` compares `saved.workspace` to
  `app.workspace` by realpath (`sameWorkspace`: literal first, then both
  sides through `realPathFile`, a side that no longer resolves falls back
  to the literal), so a workspace opened through a symlinked or
  unresolved spelling (`/tmp/x` vs `/private/tmp/x`) keeps its session;
  `capture` stores the resolved workspace so new files are canonical.
  A genuinely different directory still gets the "belongs to" toast.

## The HTTP section (2026-09-07, branch `http-panel`) — `// changed:` notes

The left column's HTTP section rebuilt to Rust's element list
(`src/ui/http_panel.rs`, `rust-http-panel-120x40.txt`): the user's
ask was Rust's helpfulness — the blank row under the filter, a chip
ladder on every section header, the words and the green `+ New …`
link under an empty section, the collections as a folder tree with a
`+` per folder, `+ New request` / `↓ Paste curl…` / `↓ Import…` at the
bottom, and a blank request pane opened in the centre on entry.

- `// changed (ui):` `src/ui/http_panel.zig` is the painter, split out
  of `app/http_panel.zig` (state + actions stay there, D6). It owns
  `Section`, `Row{ kind: header | folder | item | empty | link | gap, … }`,
  `Panel = ListPanel(Row)`, `Link`, `ChipKind`, `Part` and `draw` /
  `paintRow`. The header ladder (`ladder`) is Rust's
  `draw_section_header` rule verbatim — `need = 1 + chevron + label +
  " (n)" + gaps + 2 + 3·chips ≤ the row's content width`, dropping
  clear → refresh → filter → new → capture — with Rust's per-section
  sets: COLLECTIONS ≡ ⟳ ✕ +, ENVS ≡ +, CHAINS none (Rust's gate never
  draws a lone filter chip; mirrored as the drawn set), MOCKS /
  RECENT ≡ ⟳ ✕, CAPTURED ≡ ⟳ 🌐 ✕, COOKIES (Zig's) RECENT's set.
  Tested at 26 / 30 / 34 (content 25 / 29 / 33) and at the shipped
  width with a scrollbar (24: RECENT loses its ✕ — the drop rule, not
  a bug). Glyphs are Rust's codepoints: EB83 / EB37 / EB01 / EA76 /
  EA60 chips, F07B / F114 folders, F15C members, F1D8 loose files,
  F085 chains, F0C0 mocks, ▼ / ▶ headers, ▾ / ▸ folders, ● / ○ envs,
  ↓ on the two action rows; every one has its `--ascii` twin.
- `// changed (ui):` `hit.HitTarget` gains `http: http_panel.Part` —
  `chip{ section, kind }`, `link: Link`, `folder_new: idx` — labelled
  `http:chip:envs:new` / `http:link:paste_curl` / `http:folder_new:2`;
  `dispatch.mouse` routes it to `http_panel.partMouse`,
  `discovery.describe` gives each Rust's `info_view_copy.rs` words.
- `// changed (list-panel):` `Props.filter_gap` — one blank row between
  the filter and the list when there is no `+ New` row (the user's
  pattern, which TODOS gets from its New row). And the `.row` hit is
  now registered BEFORE `paintRow`: it was after, so a painter's own
  targets (a header's chips, a link) could never win a click.
- `// changed (app):` `State.folders: []Folder{ rel, name, hidden,
  members }` + `loose` — every directory holding request files is a
  collection (Rust's rule is ≥ 2 files; one is enough here, so the
  fixture's `requests/demo.http` is `▾ 󰉋 requests (1)` and Rust's
  FILES-stragglers section is only the root-level files, listed under
  COLLECTIONS with the F1D8 glyph); `.mnml/collections/<name>/**` is
  walked too (the workspace walk skips dot-dirs) and shows as the
  hidden kind. `collapsed_dirs` folds a folder (`←` / `→` / a press on
  its row); the filter unfolds every folder and shows a folder's
  members when its name matches. Under no filter an empty section
  gets its words (`Section.emptyText`, Rust's; COOKIES Zig's) and
  COLLECTIONS (when empty) / ENVS / CHAINS their link; a gap row
  follows every section; the three action links close the list. The
  cursor never rests on a gap or the words (`settle`, after every
  `ListPanel` motion, wheel and scrollbar jump). `chipAction` is
  Rust's routing (filter focuses the pill, refresh `http.refresh`,
  capture `http.capture_start`, clear truncates RECENT / CAPTURED or
  empties the jar and otherwise clears the filter, new `http.new_env`
  / `http.new_collection`); `linkAction` opens what the palette
  command opens (`http.new`, `http.paste_curl`, the `Import from:`
  menu → `http.import_postman` / `http.import_har`, `http.new_env`,
  `http.new_chain`, `http.new_collection`); `newRequestInFolder`
  opens a blank pane whose `source_path` is the first free
  `req-N.http` in the folder (Ctrl+S lands it there). The header row
  menus carry the section's verbs (start capture, clear, pick env…);
  every menu id resolves (tested). The kebab is off for this panel:
  its hover glyph would sit where the ladder paints.
- `// changed (app):` `http_panel.enter` — `view.activity_http`
  (`cmd_view.activityHttp`) opens a blank request pane when no request
  pane is active (Rust's `entering_http`), so the keys land in the
  pane and the info box says `Request pane — Enter to send, Ctrl+S
  saves as .http/.curl.`; a re-entry with one active opens nothing;
  leaving does not close it (Rust closes an untouched preview — not
  mirrored, by the brief).
- `// changed (tests):` `tests/e2e/http_panel.test` re-aimed — the
  files sit under `▾ 󰉋 api (2)` as `users.http`, `dev` is `●` (the
  resolved default), the keys go to the pane so the script clicks the
  pill first, and the walk to `prod` counts the folder row and skips
  the gap. `tests/e2e/http_panel/` (no headers): entering opens `new
  request`, `+ New env` opens its prompt and `G ⏎` the Import menu,
  the folder `+` opens `req-1.http` and a folder press folds, the
  `Paste curl…` link fills the blank pane, a RECENT double-click opens
  the request, the filter narrows. Break-checked: `enter` disabled →
  `entering_opens_request.test` fails on `GET  new request`.
- Not mirrored: Rust's `HTTP` header (no count, a collapse-all chip)
  — Zig keeps `HTTP (n)  +  ⟳`; Rust's blank between the two action
  rows and the bottom-pinned rows (the list scrolls instead); the
  ≥ 2-files collection rule.

---

## SESSIONS — Rust's cards (2026-09-07, branch `sessions`) — `// changed:` notes

- `// changed (ui):` `ListPanel.Props` gains `row_h` / `row_gap` — rows
  per item and blank rows between them; the scroll window, the hits
  and the paging count items, an item's hit covers all its rows, the
  kebab sits on its first — and `own_marker`: the row paints its own
  selection signal (no cursor-line ground, no marker; `paintRow` gets
  the item rect from `x`). Every other panel is unchanged at the
  defaults (`1` / `0` / `false`).
- `// changed (app):` `src/sessions.zig` paints Rust's card
  (`sessions_panel.rs`, `TAB_H = 4` and a blank row): ` ▌ <name>` with
  the pin `󰐃 ` (U+F0403) before a pinned name, the name clipped hard at
  the edge; ` ▌ you: …` / ` ▌ claude: …` from the transcript's last
  exchange (`Item` gains `last_assistant_msg`; runs of whitespace
  collapsed as Rust's), `exited` alone for an ended session, `—` for
  none, each clipped to `width − 6` with the ellipsis; ` · TICKET` after
  the first summary row from `ui.ticket_prefixes` (Rust's
  `detect_ticket`, on the display name, hidden by an alias). The accent
  is cyan on the cursor's card while the panel has focus, green on the
  card whose pty pane is the active one (its argv names the id), else
  the ground — Rust paints a user colour first; there is none here. No
  source glyph, state badge or age on the row (Rust's has none); no
  bell and no ports chip (nothing here feeds them). The rows are
  measured against `docs/ui-spec/rust-sessions-120x40.txt` rows 3–18 in
  the unit test, cell for cell.
- `// changed (app):` the top block is the Zig idiom, per the user: the
  caps header with the sort / refresh chips, the filter pill, a blank,
  the green `+ New session` row (`Props.new_label`; Enter and its click
  run `ai.claude_code_new`, what Rust's chip runs; its right click is
  Rust's batch menu ×2 / ×4 / ×8), a blank — so every card sits one row
  lower than Rust's (`docs/ui-spec/README.md`, `rust-sessions-*.txt`).
- `// added (app):` `sessions.pin` (`p`; the row menu's first row —
  Rust's order: Pin / Unpin, Move up, Move down, Rename…, then this
  panel's Resume / transcript / copy / delete rows): pinned ids lead the
  list on either axis, in memory for the launch as Rust's
  `sessions_pinned`. Spec count 935.
- `// changed (app):` `$HOME` for the scan is the loader's, else the
  children's (`App.env`, where a `.test` file's `# env:` lines land,
  the runner loading no file); a relative HOME is under the workspace,
  so `tests/e2e/sessions_*.test` seed `home/.claude/projects/…` with
  `write` and `# env: HOME=home`. `tools/seed-sessions-home.sh` is the
  spec's fake home, with a fake `claude` both editors spawn.
- Kept from the Zig panel, hover- or width-only or Rust-less: the
  `/ filter` pill, the scrollbar column when the cards overflow (Rust
  clips), the kebab on the hovered card, `w` for every workspace, `f`
  for the state filter, the rename / delete flows.
## Menus — the four user reports (2026-09-07, menus)

The user compared the Zig menus with Rust's on a real screen: the
icons sat against the labels, a hovered row did not light, hovering
another title did not switch the open menu, and the `+` was a bare
list. Every glyph is Rust's codepoint; Rust dumps of the open File
menu and the `+` menu are in `docs/ui-spec/` (`rust-menu-file-120x40.txt`,
`rust-menu-plus-120x40.txt`) and both diff clean.

- `// changed (menus):` `app/render.zig`'s `drawMenu` paints Rust's
  two row shapes. A context menu (`ui/context_menu.rs`): a square
  frame with the title in the top border and Rust's blank row above
  the bottom edge (Rust reserves a title row the border holds), the
  inner width `max(label + 3 (+ 2 on a parent), title) + 2`, floor 12;
  each row ` <glyph>  label ` padded, `▸ ` ending a parent row, `⋮ `
  ending the focused leaf of a curatable menu — only where the label
  leaves it room (Rust's marker runs off the row; the label wins
  there too). A menu-bar dropdown (`MenuState.dropdown`, `ui/menu_bar.rs`):
  no title, a two-cell marker column (`▸ ` on the highlighted row),
  the three-cell icon column in the muted colour when any row has an
  icon, the label, ` ▸` ending a parent row, width
  `max(label (+ 2) + icon column + 4, 20)`; a separator is a
  full-width rule in the muted colour. Both: `bg2` ground, the
  highlight `bg_dark` on cyan, bold. Zig keeps its separators (Rust's
  context menus have none) and its ASCII twins in the glyph column
  (Rust paints no column under `ascii_icons`).
- `// changed (menus):` `MenuItem.hint` is gone — the dropdown's chord
  column was a Zig addition; Rust's rows carry none.
- `// changed (menus):` `ui/menu_glyph.zig` is Rust's `command_glyph`:
  `by_action` (a substring of the id's last dotted segment, first
  match) then `by_domain` (the first segment, exact) then
  `fallback_glyph` (the play triangle), `width` 3; each entry carries
  its one-character ASCII twin.
- `// changed (menus):` `MenuState` gains `dropdown`, `highlight` (the
  cursor row paints highlighted only once the menu was interacted with
  — a mouse-opened dropdown starts without; Enter still runs the
  cursor row) and `mem: ?ArenaAllocator` (labels built per open, freed
  with the menu); `SubMenu` gains `highlight` (a fresh child paints
  none until hovered or arrowed — Rust's un-`interacted` child). The
  first arrow on an un-highlighted menu lights the cursor row rather
  than moving it (`dispatch.menuMove` / `subMove`).
- `// changed (menus):` `dispatch.mouse` no longer returns on `.motion`
  before the overlay: `menuHover` moves the cursor to the row under
  the pointer, opens a hovered parent's child and closes it on a
  hovered leaf (a curation child stays while the pointer is on its
  own row); the keyboard and the pointer share the cursor, the last
  input wins. A right press on a leaf of a curatable menu opens its
  curation (`openCuration`), as the kebab and `→` do.
- `// changed (menu-bar):` `menu_bar.open(app, m, x, y, keyboard)`;
  `openIndexAs`; `State.keyboard` / `overflow_open`; `hoverSwitch(app,
  id, rect)` — with a dropdown or the ` » ` list open, the pointer on
  another word (the brand included) or the ` » ` opens that instead,
  keeping how the menu was summoned (Rust `new_mouse` / `new_keyboard`).
- `// changed (plus-menu):` `context_menus.plus_tree` is Rust's
  `Create…` tree (New / Open / AI / Dock ▸, the leaves under them);
  `openNewTabMenu` prepends "Reopen last closed (N)" (`buffer.reopen`)
  while `app.closed` has entries, appends Integrations ▸ from the
  enabled `integrations.chips` (the chip's glyph; a chip whose command
  resolves to neither a static nor a dynamic id is left out — a
  dynamic row is not curatable, `rowId` names static ids only), and
  applies Rust's `apply_plus_menu_curation` over the whole tree
  (`curate`). It opens titled `Create…`, curatable, highlighted, from
  the strip's `+` on either button and from the top-right `+`'s right
  click (its left click stays `tab.new`). The old Panels / Tools /
  Integrations-panel sections and the rule under pinned rows are gone
  — Rust has neither.
- `// changed (e2e):` `.test` scripts gain `hover X Y` (a pointer
  motion, no button — `Driver.mouse(.motion)`); the headless IPC
  `hover` already existed.

## HTTP hooks + Headers completion (2026-09-07, branch `http-hooks`) — `// changed:` notes

`docs/research/http-vs-posting.md` §3 rows 1–2 and §4-A. Additive
throughout: two hook variants, one `mnml.http` table in a block of its
own at the end of `scripting/api.zig`, one new file
(`src/http/header_table.zig`), and the Headers tab's painter prong.

- `// changed (core):` `Hook` gains `http_request` / `http_response`;
  their payloads (`HttpRequestArgs`, `HttpResponseArgs`) are not flat —
  `headers` is a `[]HttpHeader` the Lua bridge turns into a name → value
  table, and `http_request` carries `rewrite: *HttpRewrite` (gpa-owned
  `method` / `url` / `headers` / `body`, `clear_body`) that subscribers
  fill and the emitter applies. `hooks.emit` is unchanged;
  `Lua.callHook` routes the two to `api.callHttpHook` before its
  `pushAny` prong, so D10's "flat payloads" rule holds for every other
  hook and these two are marshalled by hand (`pushHeaderTable`,
  `readRewrite`). `hooks.http_body_cap` (1 MB) caps the body a
  subscriber sees; `body_truncated` says so.
- `// changed (app):` `cmd_http.beforeSend(app, id, rp, &req, env)` is
  called from `http.fire` after `applyPre` and `expandWith` — the order
  is directives → expansion → hook, and a returned field goes on the
  wire as-is (no second expansion; the jar's `Cookie` is added by the
  transport after). `afterResponse` ends with `emitResponseHook`: jar →
  schema → `@assert` / `@capture` → `http_response`, so `set_var` lands
  after the captures. `replayMockFrom` fires `http_response` too.
  `http.State` gains `hook` (`none` / `request` / `response`) and
  `resend_pane`: `mnml.http.send` from inside `http_response` is
  deferred until the hook returns; from inside `http_request` it is a
  Lua error. Chains, fan-out, bench and the CLI fire neither hook.
  `cmd_http.setEnvVar` is `writeEnvVar` returning its refusal
  (`InvalidKey` / `InvalidValue` / `WriteFailed`) for `mnml.http.set_var`.
- `// changed (app):` `RequestPane.sent_headers` keeps the wire headers
  (`setSentHeaders`, from `beforeSend`); `ResponseModel.sent_headers`
  carries them and the Timeline tab lists them under a `Sent` label
  with `sent_line` — the one place the user sees what a hook or a
  `@set-header` did.
- `// changed (app):` the Headers tab is a table. `headers_text` stays
  the storage (`commit`, `syncHeadersText`, `inlineVar`,
  `http.insert_header`, the Auth tab's `auth_current` all read it as
  before); `headerRows` parses it live for the painter with each row's
  byte range and value offset, so `commitHeaderDraft` rewrites one
  line, `removeHeaderRow` drops one, and the `{{VAR}}` spans (offsets
  into the whole text) land in the value cells. `Draft.edit_row` marks
  an in-place edit; `startHeaderDraft(edit_row)` prefills. `activeBuf`
  is null on `.headers` (no caret in the text any more): `paste` on the
  tab appends `Name: value` lines; `varAtCaret` has nothing on the tab
  — the painted spans' hits still open the quick-fix. Keys
  (`headersKey`): `j` / `k` / arrows, Enter edits, `a` / `+` adds, `d`
  / Delete / Backspace drops, `?` toggles the description tip; in a
  draft Tab flips the cell, Enter commits (an empty name cancels).
- `// changed (app):` `RequestPane.completion` (`Completion`: the
  candidates on their own arena, `on_value`, `selected`, `scroll`) is
  the Headers popup; `refreshCompletion` opens it on the first name
  character and as soon as the caret lands on the value cell (an empty
  value lists every known value), rebuilds it when the column changes,
  closes it when the name cell empties or nothing is known;
  `visibleCompletion` filters with `ui/fuzzy.zig` every frame, source
  order preserved among equal scores; Up / Down / Tab / Enter go to the
  popup first, Esc closes it before the draft. `acceptCompletion` on a
  name moves the caret on to the value and opens its popup. The popup
  is painted by `ui/completion_view.zig` from `request_pane.draw`,
  anchored on the draft cell's caret (`KvPainted.caret`, Headers only);
  its rows' `.overlay_item` hits are not routed (the LSP popup's
  `dispatch` prong checks `app.lsp.completion`), so it is keyboard-only.
- `// changed (app):` the sources, `http.zig`: `headerNameCandidates(app,
  rp, arena, present, editing)` — the request headers the last
  response's headers call for (`header_table.pairings`: `ETag` →
  `If-None-Match`, `Content-Type` → `Accept`, …), the response's own
  names, the workspace's names most-used first, the table; names
  already on the tab are left out except the row being edited.
  `headerValueCandidates(app, rp, arena, name)` — the paired response
  header's value, the same name's value, a `Set-Cookie`'s `name=value`
  for `Cookie`, the workspace's values for the name, the table's, the
  env's `{{VAR}}`s. `headerScan` reads every file `http_panel.files`
  lists (refreshing the panel once if it never scanned), parses each
  block, counts names and values; cached on `http.State.header_scan`
  for `header_scan_ttl_ms` (5 s). `headerDoc(name)` is the `?` / hover
  copy; `hoveredHitIn` / `hitRectOf` find a hit by id range / id.
- `// changed (ui):` `drawKvTable` takes a `KvOpts` (kind, hits, add,
  cursor, focus, and for Headers `value_offs` + `vars` + `tip`) and
  returns `KvPainted{ rows, caret }`; the `.headers` prong of
  `drawEdit` paints it on `Model.headers` / `header_value_offs` /
  `header_tip` (new fields, defaulted). `hit_header_row = 600 + row`,
  `hit_header_del = 700 + row`. `drawTip` is the one-row tip
  (`drawVarTip`'s shape) under a row. The old `(Name: value per line)`
  text area is gone; `tests/e2e/http_request_pane.test` re-aimed at the
  cells.
- `// changed (docs):` `docs/LUA.md` — the two hook rows, "The HTTP
  hooks" (payloads, the returned table, the order, the 1 MB cut,
  `mnml.http`); `docs/examples/init.lua` carries both hooks.
- Tests: `hooks:` ×3 in `cmd_http.zig` (the rewrite on the wire after
  the directives, the response hook after the captures, `set_var`'s
  round-trip and refusals, the deferred re-send, `body = false`, the
  truncation rule), `HttpRewrite` in `hooks.zig`, `header_table`'s
  self-check, `Headers completion:` in `http.zig` (the source order,
  both columns), `Headers tab:` + `headerRows:` in `request_pane.zig`
  (the keys), `the Headers table:` in `request_view.zig` (cells, spans,
  the draft caret, the tip); `tests/e2e/lua_http_hooks.test`,
  `tests/e2e/http/http-headers-complete-name.test`,
  `http-headers-complete-value.test`, `http-headers-describe.test`.

---

## HTTP options, response search, `{{` completion (2026-09-07, branch `http-options`) — `// changed:` notes

- `// changed (http):` `parse.Request` keeps its transport options as
  the block's own `# @…` lines — `@insecure`, `@timeout 5s` (`500ms`,
  `2m`, a bare number is ms), `@no-redirect` / `@follow-redirects`,
  `@max-redirects 3`, `@proxy host:port` — read by `parse.options`,
  written by `parse.setDirective` (replace / add / remove one word's
  line, `insecure` kept in step). `parseCurl` makes the same lines of
  `-k`, `--max-time`, `--max-redirs`, `-L`, `-x`; `toCurl` writes the
  flags back; `toHttpBlock` writes a line for a hand-set `insecure`.
  `parse` merges the text's directive lines with the flag-made ones
  (the text's word wins), so block ↔ curl ↔ block round-trips.
- `// changed (http):` `client.Transport` (`insecure`, `timeout_ms`,
  `follow_redirects`, `max_redirects`, `proxy`) with `fromRequest(req,
  defaults)` — the request's directives over the config's defaults;
  `SendOptions.transport` carries the defaults. `send` runs the whole
  send (redirects included) under an `Io.Select` race with a timer when
  a timeout is set; the loser is cancelled, the outcome reads
  `timeout: no response within N ms`. A proxy is two `std.http.Client.Proxy`s
  on the per-send client: absolute-form for a plain origin, `CONNECT`
  for https. `follow_redirects` / `max_redirects` gate the hop loop;
  `final_url` is the resolved hop's text, not the wire's.
- `// added (http):` `src/http/insecure.zig` — `req.insecure` was parsed
  and never read. `std.http.Client` builds its TLS with the system
  bundle and the URL's host and has no switch, so an https hop under
  `-k` goes to `Shim`: a loopback listener that opens the real host
  (through the proxy's `CONNECT` when set), shakes hands with
  `.ca = .no_verification` and pumps bytes both ways; the client speaks
  plain HTTP to it with the real `Host`. The name is checked with SNI
  first; a `CertificateHostMismatch` retries with no name check and no
  SNI — as far as std's client goes toward curl's `-k`. A failed
  handshake is named on the outcome: `tls (insecure): Tls…`. `JunkOrigin`
  is the test origin (answers any bytes, keeps what it saw).
- `// changed (config):` `Config.Http` gains `insecure`, `timeout_ms`,
  `follow_redirects`, `max_redirects`, `proxy` (`docs/CONFIG.md`);
  `http.transportDefaults` reads them; `spawnWith` resolves the
  request's directives over them before the worker starts and owns the
  proxy string (`Job.proxy_owned`).
- `// changed (ui):` the Auth tab is a scrolled row list (`drawAuth`,
  through `m.edit_scroll`): the current header, the four auth rows,
  `── Options ──`, five rows in the settings idiom — `▸ Verify TLS:
  [on] / off`, `Timeout: [5s]  Enter to set`, `Follow redirects`,
  `Max redirects: ‹ [10] ›`, `Proxy: [none]` — the `*` after a row the
  block sets. `Model.options: OptionsModel`; hits `hit_auth_row +
  auth_rows.len + i`; `authRowCount()`.
- `// changed (app):` `http.optionsModel`, `authRowAdjust` (`←` `→` /
  `h` `l`: flip a toggle, step the cap or the timeout by a second),
  `authRowReset` (`r`: the line goes, the config decides),
  `openOptionPrompt` / `applyOptionPrompt` (`PromptPurpose.http_option`,
  seeded with the block's value; empty removes the line). Verify TLS
  cannot be turned on for one request when the config says `insecure =
  true` — a toast says so. Five ids: `http.toggle_insecure`,
  `set_timeout`, `toggle_follow_redirects`, `set_max_redirects`,
  `set_proxy`.
- `// changed (app):` `cmd_find` works on a `Target` — `.editor` (the
  buffer, the offset landing) or `.request` (`RequestPane.resp_find`,
  `resp_cursor`, `respFindText()`: the body as shown, or the Headers
  tab's `name: value` lines) — so `openBar`, `liveUpdate`, the accepts,
  `stepFind`, `toggleRegex`, the history and `App.closeFindBar`'s
  restore are one path. `find.find` on a request pane focuses the
  Response block; `/` `?` there (vim) open the bar, `n` / `N` walk in
  both profiles, Esc drops the matches; a tab change re-targets
  (`retargetFind`), a new response clears. `revealFind` scrolls the
  hit's row into the response (`resp_rows` measured at draw). The bar
  docks under the pane as under an editor, with the count.
- `// changed (ui):` `ResponseModel.headers_text`, `matches`,
  `current_match`; the Headers tab draws from the joined text when
  given (the pairs otherwise), and `overlayMatches` splits every
  segment that is a slice of the searched line at the matches —
  `theme.match` / `theme.current_match` grounds over the syntax
  spans, wrapped chunks included.
- `// added (app):` the `{{` completion: `http.State.completion:
  ?VarCompletion` (pane, `CompletionField` — url / body / headers /
  source / a params draft cell —, `start`, an arena of `Item{ name,
  kind, detail }`). `afterFieldEdit` runs after every field edit: a
  `{{` just typed opens it (`buildVarItems`: the env file's names with
  `env.masked` values, the seven `$` built-ins with a fresh sample,
  the block's `@capture` names with what the env has or `(set by the
  response)`), an open popup follows the word (`fuzzy.score`) or
  closes on `}` / a space / the caret leaving. `varCompletionKey`
  owns ↑ ↓ PgUp PgDn Tab Enter Esc and Ctrl+N/P/E ahead of the field;
  `acceptVarCompletion` writes `name}}` over the word (a `}}` already
  after the caret is not doubled; the braces too when summoned bare
  by `http.complete_var`); `clickVarCompletion` from `dispatch`'s
  `.overlay_item` arm; `drawVarCompletion` paints
  `ui/completion_view.zig` at the field's caret — no second popup.
- `// added (e2e):` `serve <port> <status> [delay=<ms>] <text>` in
  `src/e2e/parser.zig` / `runner.zig`: `mock.Server` on the loopback
  for the file (headers, a blank line, the body; a delay sends the
  body late with no length), stopped after the script. Tests:
  `tests/e2e/http/http-auth-options-rows.test`,
  `http-response-search.test`, `http-var-completion.test`,
  `http-timeout-trips.test`, `http-no-redirect-302.test`.
- Coordination: the option directives live in `Request.script` beside
  `@set-*` / `@assert` / `@capture`; a Script tab that keeps its own
  text must write it through `request.script` (or re-derive from it)
  so the Options rows and the tab agree.

## HTTP — env reload, request verbs, the request picker, path params, multipart, description + tags (2026-09-08, branch `http-more2`) — `// changed:` notes

`docs/research/http-vs-posting.md` §3 rows 7, 8, 9, 10, 11 and 15.
Additive throughout: one new app file (`src/app/http_ops.zig`), one
new http file (`src/http/multipart.zig`), seven `# @…` directive
readers / writers in `parse.zig`, a `.block` row kind on the panel, a
`Path` group on the Params tab, a chip on the Body strip, a row under
the URL, and thirteen ids (spec count 1000). Nothing renamed.

- `// changed (http):` `env.digest(io, ws, name)` stamps the active
  env's two files and every `.mnml/env/*.env` (name, mtime, size).
  `http.State.env_watch` keeps the last stamp; `http.tick` (from
  `App.tick`, every 80 ms) takes a new one, and on a move rescans the
  HTTP panel (the ENVS `●`, the counts) and toasts `env: dev reloaded`
  once. The first look sets the baseline in silence. The var tips and
  the Vars tab read the file at paint time, so they follow on their own.
- `// changed (http):` path params. `parse.pathParamNames(url)` — a
  `:name` right after a `/` in the path, `::` a literal colon, the
  host's port and the query never; `substitutePath(url, values)`
  writes the values in and makes `::` a `:`; the values are the block's
  `# @path name=value` lines (`pathParams`, `pathParamValue`,
  `setPathParam` — one line per name, replaced in place). The URL
  keeps `:id` through `.http` and curl. `http.expandWith` substitutes
  before the `{{}}` expansion, so fire, fan-out, bench, the CLI `run`
  and chains all see it, and a value may hold a `{{VAR}}`. The Params
  tab paints a `Path` group (`KvKind.path`, `hit_path_row = 800 + row`,
  an unset value reads `(unset — Enter sets it)`) above `Query` when
  the URL has any; the row cursor runs down both; Enter or a click on a
  path row opens the value prompt (`PromptPurpose.http_path_param`,
  seeded), Delete / `d` clears the line; `http.set_path_param` from
  the palette.
- `// changed (http):` the body type. `parse.BodyType` (raw / json /
  form / multipart; `word`, `label`, `next`, `fromWord`), read from
  `# @body-type` (`bodyType`, `setBodyType`). `parseCurl` turns `-F`
  into `name = value` rows (a `@file` kept as one) plus the multipart
  directive and `--data-urlencode` into rows plus the form directive
  (`-G --data-urlencode` stays the query string); `toCurl` writes `-F`
  / `--data-urlencode` back. `src/http/multipart.zig`: `parseRows` /
  `renderRows`, `resolve` (a file row read relative to the source
  file's directory — the workspace for a scratch — `error.FileNotFound`
  naming the file), `encode(parts, boundary)` (CRLF framing, a
  `filename` and a guessed `Content-Type` on a file part; the tests
  fix the boundary), `makeBoundary`, `urlencode`. `http.applyBodyType`
  runs in `fire` after the expansion and before the `http_request`
  hook: JSON pretty-printed under `http.auto_format_body` and typed
  `application/json`, the rows encoded and typed; a `Content-Type` the
  request carries is kept. The chip (`hit_body_type = 58`, `[raw] JSON
  form multipart` at the strip's right) paints when the Body tab has
  the keyboard or the mode is not raw — the default screen stays
  Rust's; a click cycles, a right-click lists the four (`checked`).
  Ids: `http.cycle_body_type`, `http.body_type_raw` / `_json` / `_form`
  / `_multipart`.
- `// changed (app):` the COLLECTIONS tree lists a multi-block file's
  blocks under it (`Kind.block`, `Row.idx` into
  `http_panel.State.blocks`, painted `GET  name  #tag #tag` with the
  verb's colour two cells deeper than the file). `refresh` scans every
  listed file (`scanBlocks`, 1 MB each) into `BlockInfo{ file, idx,
  name, method, url, label, tags, description, multi }`. The filter is
  a `Query` (`tag:x` → the tag, else the substring); a file matches by
  name or by any block's name / method / URL / description / tags, a
  multi-block file lists the matching blocks (all when its own name
  or its folder's matched); `tag:x` keeps only the blocks tagged `x`
  (a prefix, case-insensitive) and their files. Enter on a block row
  opens that block (`http.openFileBlock(app, path, idx)` — the pane
  already on it when there is one).
- `// added (app):` `src/app/http_ops.zig` — `http.rename_request` /
  `duplicate_request` / `delete_request` / `move_request` on a
  `Target{ path, block }` resolved from the panel's selected row when
  the panel has the keys, else the active pane's source (its block
  when the file has several). Rename prompts (`PromptPurpose.http_rename`,
  seeded with the `###` name or the file's basename; a `/` moves the
  file, a missing extension keeps the old) and the open pane's
  `block_name` / `source_path` follows; duplicate writes
  `parse.duplicateBlock` (`### name-copy`, `-copy-2` …) or
  `stem-copy.ext`; delete confirms (`ConfirmPurpose.http_delete_request`,
  Delete / Cancel) then `parse.deleteBlock` — the file goes when it
  held nothing else; move opens a picker of the collection folders and
  `(workspace root)` (`PickerKind.http_move_target`,
  `http.State.move_target`) and `parse.extractBlock` appends the block
  to the file of the same name there (a whole file is renamed into the
  folder). The panel refreshes after each. The row menus of a file and
  a block carry the four verbs and *Find request…*.
- `// added (app):` `http.find_request` (`ctrl+shift+r` standard,
  `<leader>hr` vim — the `+http` which-key group): a picker over
  `State.blocks`, `METHOD · name · file`, the tags as the dimmed
  detail; Enter opens that block (`PickerKind.http_find_request`,
  `http.State.find_rows` on `picker_arena`).
- `// changed (http, ui):` `# @description …` / `# @tags a b c`
  (`parse.description`, `tags`, `setDescription`, `setTags` — commas
  and a leading `#` accepted). `request_view.zones` adds a one-row
  `desc` zone under the top bar when the model carries either (from 12
  rows): `▸ description` dim italic, the `#tags` in the accent at the
  row's end. `http.set_description` / `http.set_tags` prompt, seeded.
- `// added (e2e):` the `serve` step's text `@echo` answers with the
  request as it arrived (`mock.Canned.echo`) so a `.test` reads the
  wire: `http-path-param.test`, `http-multipart-send.test`. Also
  `http-env-reload`, `http-rename-block`, `http-duplicate-block`,
  `http-delete-block`, `http-find-request`, `http-tag-filter`.
- Re-aims: `parse.zig`'s `-F multipart` unit test now expects rows +
  the directive (the bytes are made at send time). No `.test` re-aimed.
- Coordination: `App.tick` calls `http_app.tick` (one line); the
  purposes / kinds (`http_path_param`, `http_rename`, `http_description`,
  `http_tags`, `http_delete_request`, `http_find_request`,
  `http_move_target`) and `command.zig`'s table list gained
  `http_ops.zig`; both spec pins are 1000.

---

## Lua — the editor's help, SCRIPTS, Bind in init.lua (2026-09-08, branch `lua-track`) — `// changed:` notes

- `// changed (app):` a save of either `init.lua` reloads the scripts
  through `save_post` (`app/cmd_script.zig`); a script error that names
  a line of one of the files is a third `FileDiags` source beside a
  server's (`lsp.applyScriptDiagnostics`) — the gutter
  dot, the squiggle, the DIAGNOSTICS row — and one persistent toast
  whose click jumps to the line. Every `mnml.*` registration records
  its caller's `file:line` (`Lua.noteOrigin`, `OriginKind`).
- `// added (scripting):` `scripting/complete.zig` — the app completes
  its own API in a `.lua` under `.mnml/`: `api.zig`'s `root_fns` /
  `tables` spec (which `install()` now builds the `mnml` table from, so
  the list cannot drift), the hooks (`hookDoc`), the command ids, the
  key specs one token at a time, the theme roles. The rows ride the
  server popup as a `Completion` with no server
  (`lsp.openLocalCompletion`; `Completion.server` / `.incoming` are
  optional). `K` on an id / API path / hook name is `script_complete.hover`.
  The request pane's `{{` popup is `http.State.completion`, its own
  state on the same view — the three clients never meet on one pane.
- `// changed (lsp):` `lua-language-server` joins the default server
  table (`lsp/client.zig`). json / yaml / html / css were tried and
  taken out again: a default server that is not installed toasts, and
  `package.json` is in every workspace — the statusline spec row
  (`app/statusline.zig`) caught it as a bell count. The four are a
  follow-up behind a quieter missing-default path.
- `// added (core):` `script.run_selection` (vim `space s r`, standard
  `ctrl+alt+enter`) — the selected lines or the cursor line run in the
  script state, an expression first; `script.new_init` — the workspace
  `.mnml/init.lua` from the commented template; `view.activity_scripts`.
  Spec count 959.
- `// added (ui):` `ui/scripts_panel.zig` — the SCRIPTS row
  (`<kind> <name>  <file:line>`, the location clipped from the left and
  shrinking to six cells before the name gives way; the link row in the
  accent); `app/scripts_panel.zig` — a `ListPanel` in the left slot
  with the rail entry `Section.scripts`, keys Enter / `r` / `n` / the
  filter, the refresh chip and its right-click (`auto_refresh`), the
  link row `+ create init.lua` (sized for the default `tree_width`).
- `// changed (core):` `MenuAction` gains `diag_row_open`,
  `set_severity_filter`, `script_row_open`, `lua_bind` (the id, on the
  menu's `mem` arena); `PromptPurpose` gains `lua_bind: LuaBind{ id,
  title }` (both owned — `Prompt.State.title` is borrowed).
  `menu_glyph.forItem` paints each.
- `// changed (app):` right-click on a DIAGNOSTICS row (`lsp.rowMouse`
  → `openRowMenu`: Open, Copy message, Copy location, next / previous,
  the three filters ✓) and on the severity chip (`lsp.chipMouse` →
  `openFilterMenu`; `setFilter` sets one outright, `cycleFilter` stays
  the click); on a SCRIPTS row and its kebab (`scripts_panel.openRowMenu`:
  Run, Bind in init.lua…, Open file:line, Copy id, Reload scripts; the
  link row's is Create init.lua); on a palette command row
  (`cmd_picker.openRowMenu`: Run, Bind in init.lua…, Copy id — the menu
  takes the palette's place; `right_click_of[.overlay_item]` is `.here`).
  `context_menus.openOwned` is pub for the three.
- `// added (app):` *Bind in init.lua…* — `scripts_panel.promptBind`
  / `acceptBind`: the spec through `keymap.parseKeySeqBuf`, then
  `mnml.map("<spec>", "<id>")` on a new last line of the workspace
  `init.lua` (the template first), `watch.reload` on its editor when
  open and clean (refused when dirty), `script.reload`. `mnml.map`'s
  second argument may be a command id (`api.zig` `map`).
- `// changed (api):` `mnml.http` joined the `tables` spec (completion
  and hover know it); the two HTTP hooks have `hookDoc` lines; the
  `hook` completion column widened with `http_response`
  (`tests/e2e/lua_completion.test`).
- Tests: `app/scripts_panel.zig` (the rows, Enter, the link row, `r`;
  the row menu, the bind — a bad key, a new last line, the chord runs,
  a dirty file refused), `app/lsp.zig` (the row menu, the chip menu,
  `setFilter`), `app/cmd_picker.zig` (the palette row menu),
  `ui/scripts_panel.zig` (the row's clipping at 40 cells),
  `tests/e2e/lua_run_selection.test`, `lua_error_diagnostic.test`,
  `lua_completion.test`.

## Git — interactive rebase, the operation in progress, amend, reset (2026-09-07)

- `// changed (git):` `parse.Status` gains `in_progress: InProgress`
  (`none rebase merge cherry_pick revert bisect`), `step` and `total`.
  The status job reads the git dir (`rev-parse --absolute-git-dir`,
  cached on the `Repo`) for `rebase-merge` / `rebase-apply` /
  `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD` / `BISECT_LOG` and
  the rebase's `msgnum` / `end` (`next` / `last` for an am-rebase);
  `parse.progressFrom` is the pure half. `parse.parseTodo` reads a
  `rebase -i` todo (long and one-letter words, `exec` lines skipped).
- `// added (git):` `src/git/sequence_editor.zig` — mnml as git's
  editors. `mnml-zig --rebase-todo <plan> <todo>` replaces git's todo
  with the plan after checking both name the same commits (a mismatch
  exits 1: git aborts with the reason); `mnml-zig --commit-msg <queue>
  <target>` hands a reword its new message, keyed by the commit's OLD
  subject (git opens the editor once per reword and once per run of
  squashes, so a positional queue would misfire). `main.zig` dispatches
  the two flags before anything else. The worker sets
  `GIT_SEQUENCE_EDITOR` / `GIT_EDITOR` in the child's environment
  (`client.gitEnv`) — the variables beat `core.editor`, and the app's
  own environment may carry one.
- `// changed (git):` `client.Job` gains `op_continue` / `op_abort` /
  `op_skip: InProgress` (`git <verb> --continue / --abort / --skip`, no
  editor; bisect maps to `bisect reset` / `bisect skip`),
  `rebase_plan{base: ?sha, ops: []sequence_editor.Op}` (`rebase -i
  --autostash <base>` or `--root`), `amend_noedit`, `amend_to: sha`
  (`commit --fixup` + `rebase -i --autosquash --autostash <sha>^` with
  `true` as both editors) and `reset{mode, rev}`. `client.Action` gains
  `reset_hard{sha, stash: ?sha}`: every tree-touching job records HEAD
  and a `stash create` BEFORE it runs (`snapshot` / `pushSnapshotUndo`)
  and `git.undo` is `reset --hard` + `stash apply --index` (plain
  `apply` when the index will not go). `amend_noedit` and `reset --soft`
  keep the `reset_soft` pair.
- `// changed (ui):` `git_toolbar.Action` gains `cont abort skip`;
  `Props.in_progress` swaps the row to `Continue · Abort · Skip ·
  Refresh` (`Skip` only where git has `--skip`). `git_graph_view.Doc`
  gains `in_progress`, `marks: ?[]const bool`, `range: ?[2]usize` and
  `plan_actions: ?[]const u8`; the cursor column's second cell is the
  mark cell (`✓` on a selected row, the action's letter while the plan
  is open; at rest the space Rust paints). `drawPlan` paints the plan
  modal over the list (`overlay.boxLook(.modal)`), rows `▶ pick
  abc1234  subject`, the hint row, one `planRowId` hit per row.
- `// changed (app):` `GraphPane` gains `marks` (commit indices),
  `anchor` (the `v` range's start) and `plan: ?Plan` (rows oldest-first,
  cursor, `base`), all dropped when the log reloads. Keys: space toggles
  a mark, `v` starts / folds a range, `*` selects the branch's commits
  since its upstream (`git.select_branch`), `r` opens the plan
  (`git.rebase_plan`), Esc clears the selection before it closes the
  pane; refresh moved to `R`, revert to `V`; on the WIP row `A` is
  `git.amend` and `U` unstage-all, on a commit `A` is `git.amend_to`.
  The plan modal (`planKey`): `↑↓` / `j k`, `←→` / `h l` cycle the
  action, `p r e s f d` set it (`r` opens the `plan_reword` prompt),
  `J` / `K` or alt+`↑↓` move the row, Enter runs, Esc cancels; a
  squash / fixup first in the plan refuses. `git.fixup` / `squash` /
  `drop` / `reword` build the one-line plan and run it (`directVerb`);
  `reword`'s prompt opens with the old subject. `git.reset_soft` /
  `_mixed` / `_hard` read the branches panel's row when it has the
  focus, else the graph's selected commit, else a rev prompt; hard is
  behind `Confirm.reset_hard`. `PromptKind` gains `plan_reword reword
  reset_soft reset_mixed reset_hard`. The graph row menu gains Rebase
  plan… / Fixup / Squash / Reword… / Drop / Amend with the staged
  changes / Reset --soft / --mixed / --hard… / Select the branch's
  commits; the branches panel's local and remote rows gain the three
  Reset rows (`git_palette.cursorBranch`). Statusline: the branch chip
  reads `main | REBASE 2/5` while an operation waits.
- `// added (spec):` fourteen ids — `git.op_continue` `git.op_abort`
  `git.op_skip` `git.rebase_plan` `git.fixup` `git.squash` `git.drop`
  `git.reword` `git.select_branch` `git.amend` `git.amend_to`
  `git.reset_soft` `git.reset_mixed` `git.reset_hard`. Spec count 950.
- Tests: `parse.zig` (`progressFrom`, `parseTodo`),
  `sequence_editor.zig` (the child modes on real files, the plan → todo
  round-trip, the subject-keyed queue), `git_toolbar.zig` (the
  mid-operation row), `app/git.zig` (undo of amend / reset --hard /
  reset --soft / amend_to on a seeded repo; the plan modal's keys and a
  row off the first-parent line), and `tests/e2e/git_rebase_plan_squash
  / _reword / _drop`, `git_rebase_abort`, `git_amend_wip`,
  `git_reset_hard_undo.test`.

## LSP — the default rows and the quiet missing-default path (2026-09-08, branch `lsp-defaults`) — `// changed:` notes

- `// changed (lsp):` the four rows the lua-track took out are in the
  default table (`lsp/client.zig`) with a fifth: `json`
  (`vscode-json-language-server --stdio`, `.json` `.jsonc`, roots
  `package.json` / `.git`), `yaml` (`yaml-language-server --stdio`,
  `.yml` `.yaml`), `html` (`vscode-html-language-server --stdio`,
  `.html` `.htm`), `css` (`vscode-css-language-server --stdio`, `.css`
  `.scss` `.less`) and `csharp` (`csharp-ls`, `.cs` `.csx`, roots
  `*.sln` → `*.csproj` → `global.json`). The binary names are the npm
  registry's `bin` entries for `vscode-langservers-extracted` and
  `yaml-language-server`; `--stdio` is documented for yaml and is the
  vscode family's only LSP transport; `csharp-ls` is a dotnet tool
  whose README shows it run bare (stdio, no flag — unverified against
  a running install). Rust runs OmniSharp `-lsp` for C#; the markers
  are Rust's. `languageIdFor` gains `jsonc` / `htm` → html / `less` /
  `csx` → csharp. Install hints: `csharp-ls` joins `installHint`; the
  five join `runners.known_tools` so the tools picker lists them.
- `// changed (app):` a root marker starting with `*` is a glob —
  Rust's `marker_matches` — `client.markerMatches` / `isGlobMarker`;
  `findRoot` scans the directory for one (`dirHasMarker`). Nearest
  directory holding ANY marker still wins, as under Rust.
- `// changed (app):` the missing-default path. `ensureServer` on a
  binary not on PATH asks whether the spec came from the default table
  (`app.cfg.lsp` has no entry of that name). A default row follows
  `.editor.lsp_missing_defaults` — `.quiet` (the default) records a
  `lsp.Missing` (`name`, `cmd`, `installHint`, `from_default`) in
  `lsp.State.missing`, once per server per session, and says nothing;
  `.toast` warns as before; `.ignore` records nothing. A server the
  user named in `.lsp` always toasts and is recorded too. `dead` still
  stops the second visit. Why: `package.json` is in every workspace,
  the json server in few — a warning every session for every user.
  The key lives under `.editor` (beside `inlay_hints`) because `.lsp`
  is a name → server `Map`; `.lsp.missing_defaults` would read as a
  server named `missing_defaults`. Settings row *Missing default LSP
  servers* (home scope).
- `// changed (ui):` the LSP chip (`app/statusline.zig`): a recorded
  miss paints `?` — a muted run after the live count (` LSP 1? `, the
  `?` in `bg2` on the blue) or the whole chip muted (` LSP? `,
  `comment` on `bg2`) when nothing runs. The `?` form, not a count:
  `lane_gap` is four cells, and ` LSP ?1 ` (nine with its separator)
  left the 120×40 spec row's dirty `package.json ●` two — the file
  chip clipped to `package.json …`; ` LSP? ` leaves exactly four. The
  count and the names are the click — `lsp.status` appends
  ` · missing: <cmd> (<hint>)` per server — and the right-click menu:
  after *Status*, per missing server a `✗ <cmd> — <hint>` row (click
  copies the hint) and *Install <cmd>…*, then the eight verbs.
  `MenuAction.lsp_install` (the binary; the menu's `mem` arena owns
  it) → `runners.installBin`: a `known_tools` binary gets the tools
  installer's *Missing tool* box (Install / Copy command / Not now,
  `installAccept` spawns the line in a pane); one only `installHint`
  knows runs its line straight into a pane; one neither knows is a
  diag. `menu_glyph`: the download glyph, ascii `v`.
- `// changed (test):` `src/app/statusline.zig`'s tests were never
  reachable — the file was only container-imported, and a file
  reached that way contributes no tests. `app.zig`'s test block now
  names it; the spec-row test (`package.json` open at 120×40) runs
  under `zig build test` and asserts the idle bell and the muted chip
  (a `PATH=` scrub makes it hermetic). Tests: `client.zig`
  (`markerMatches`, the five rows' hints), `app/lsp.zig` (quiet /
  toast / ignore, one record per session, the configured server's
  toast + record, the glob root walk on a `*.sln` / `*.csproj`
  layout), `app/statusline.zig` (both chip forms, the status toast,
  the menu rows, Install… → the tools box), and
  `tests/e2e/lsp_missing_default_quiet.test` (`# env: PATH=`, a
  `.json` open → no toast, ` LSP? `, the status names the install).

## The ZON view (2026-09-08, branch `zon-viewer`) — `// changed:` notes

The user's idea: "a zon viewer/editor but interactive and TUI
graphical". A `.zon` file as a tree of fields you walk and edit in
place, beside the raw text.

- `Pane.zon` (`src/app/zon_pane.zig`, painter `src/ui/zon_view.zig`).
  A `.zon` file's `open` still goes to the raw editor; that tab carries
  a ` View as tree ` mode chip (`bufferline.ModeChip.kind` gains
  `view_zon` / `source_zon`) and `zon.view` opens the tree as a tab in
  the same leaf. `zon.source` (the tree's ` Source ` chip, `e`) reveals
  or opens the editor tab — the markdown preview's tab-swap idiom,
  except both tabs stay. Spec count 989 (`zon.view`, `zon.source`).
- The model (`src/config/zon_tree.zig`): the loader's two passes
  (`Ast.parse(.zon)` + `ZonGen`) read for shape — every field and list
  element a node with its literal's byte span, kind and children;
  `keyPath` is the splice path (`.{ "workspaces", "[1]", "group" }`).
- The widget table (`src/config/zon_schema.zig`): a schema-known file
  is walked by key path through its type — `Config` (`config.zon` or
  a shape of config sections), the session's `Saved` (`session.zon`),
  an integration `Manifest` (`integrations/*.zon`, or `id`+`binary`+
  `label`), a theme `Source` (`themes/*.zon`, or `base_30`+`name`).
  A `Map` takes any key, a slice a `[i]`, a union its tag. A `Dynamic`
  subtree and an unknown file **infer** from the literal: `true` →
  bool, `3` → int, `.tag` → an enum with that one choice whose tag may
  be typed, `null` → optional, a one-field struct → union-shaped (the
  field NAME is what Enter edits), `.{}` → struct. `docs/CONFIG.md`
  is embedded (`config_md`, build.zig) and its per-key comments are
  the config's info-box line (`Docs.parseDocs`).
- Widgets: bool — Enter / Space / click toggles, `[true] / false` are
  both hits; enum — `←→` / `h l` cycle, Enter opens a picker (a popup
  under the row, `✓` on the current tag), past six tags the row reads
  `[x] ‹ i/n ›`; int / float — `←→` step (ints clamped to the type's
  range), Enter types, a bad number keeps the field open; string —
  inline `text_field` seeded with the unescaped text (cursor, arrows,
  Home/End, paste), commits a quoted literal; list — `+` adds after
  the row's element (the schema's element default, else a copy of the
  last element), `x` removes, `J` / `K` reorder; struct — folds
  (`h l`, Enter, `E` / `C` all); optional — `null  set…` writes the
  non-null default, `n` clears back to `null`; union — the picker of
  tags, a void tag as `.tag`, a payload tag as `.{ .tag = <default> }`
  with the payload's own row below it (its widget is the payload's
  type).
- Write-back goes through the settings splice: every edit is
  `persist.splice` on the pane's working text, checked by a re-parse
  before it lands; `*` marks a row whose literal differs from the one
  the file had at open (a section containing one is marked too); Esc
  on it splices the opened literal back (a list element the file did
  not have is removed); `Ctrl+S` / `file.save` / the close prompt's
  Save write through `persist.persistText` (a backup beside the file,
  `backups/`), reset the baseline and `watch.reload` the raw editor's
  tab when it is open. **Reordering, adding to and removing from a
  list rewrite the whole list literal** (`persist.listLiteral`, one
  element per line when the list was, else inline) — comments between
  the elements do not come along; a scalar edit inside an element
  keeps them. `r` re-reads the disk when nothing is unsaved.
- `persist.splice` grew a `[i]` key: the i-th element of a list
  literal, so a field inside an element and a union's payload splice
  in place. `error.NotAList` / `NoSuchElement`. `persistText`,
  `listLiteral`, `lineIndent` / `lineStart` are public.
- Chrome: row 0 the breadcrumb (`config.zon › ui › theme`, each crumb
  a jump, the schema label and `· unsaved` at the right), row 1 the
  shared filter pill (`/` focuses; narrows by path substring, ancestors
  kept, containers on the way opened), a hint row at the bottom, a
  scrollbar when the rows overflow. The info box shows the focused
  row's path and doc line. Hits are `.script_hit{pane, id}` — a row,
  each option, an arrow, the value cell, `+`, `x`, a crumb, the
  filter, a picker row; no new `HitTarget`. Right-click on a row
  focuses it and, for an enum / union, opens the picker; on a bool it
  toggles.
- Not in v1 (named cuts): absent schema keys are not listed as ghost
  rows with their defaults (the splice's insert path is ready for it);
  the tree does not watch the file — `r` reloads; no session restore of
  the tree tab (the editor tab restores and its chip is one click);
  CONFIG.md docs only for the config schema (Zig has no doc-comment
  reflection for the other three); a number's `←→` step is 1.
- Tests: `config/zon_tree.zig` (every literal kind, spans, quoted keys,
  paths, errors), `config/zon_schema.zig` (detection, the config
  schema's widgets incl. the nested union and the list of structs, the
  inference table, CONFIG.md docs), `config/persist.zig` (the `[i]`
  key, `listLiteral`, `persistText`), `app/zon_pane.zig` (the tab
  pair, every widget's edit with the comments checked, union / optional
  / list ops, save + editor reload + backup + `r`, an unknown file's
  inference and the filter and folds, a file that does not parse), and
  `tests/e2e/zon_view_{toggle_bool_save, enum_cycle, string_edit,
  list_add, union_swap, unknown_schema}.test` (break-checked).
  `docs/ui-spec/zig-zon-view-120x40.txt` is the dump.

## C# / .NET — runners, the results pane, netcoredbg, the grammar (2026-09-08, branch `dotnet`) — `// changed:` notes

- `// changed (app):` `src/app/dotnet.zig` is the shared .NET
  knowledge, App-free: `find` (the nearest `*.csproj` and `*.sln` at or
  above a directory, never above the workspace; `Project.buildRoot` is
  the solution's directory, `runRoot` the project's), `parseCsproj` /
  `launchBody`, `testAt` / `testAtText` / `filterArg` / `fileFilterArg`.
- `// changed (app):` `runners.zig` gains `dotnet.build` / `run` /
  `test` / `restore` / `watch` (`runDotnet`), `Project.dotnet` (a `.cs`
  file asks for its project before the root's `package.json`), the
  `test.*` dotnet arms, `dotnet` in `known_tools`, and `pathOf` — where
  `findOnPath` found a binary, for a worker that spawns without a
  shell. `offerInstall` is `pub`.
- `// changed (app):` `tests_pane.zig` — `Runner` (`playwright` |
  `dotnet`) on the pane with an owned `cwd`; `argvFor` / `cmdlineFor`
  take the runner (`cmdlineFor` quotes an argument the shell would
  split); the worker takes the runner + the workspace and resolves
  `argv[0]` on the App's PATH; `parseDotnet` / `parseTrx` /
  `trxPathIn` / `locateSources` / `failedFilter`; `TestRun.summary`;
  `runDotnet` / `dotnetAll` / `dotnetFile` / `dotnetAtCursor` /
  `dotnetRerunFailed`; the pane's `a` / `f` / `R` follow its runner;
  the heal prompt names the tool. `ui/tests_view.zig` paints the
  summary row and names the runner in the errored state;
  `render.zig` passes the runner to `cmdlineFor`.
- `// changed (app):` `dap.zig` — `Found` carries an optional derived
  body; `builtin_adapters` / `BuiltinLaunch` / `builtinFor` /
  `builtinAdapterFor` / `resolveAdapter`; `run` → `launchFile`;
  `dotnetDebug` + `State.pending_launch` + `pollPendingLaunch` (called
  from `App.tick` after `pty_pane.tickAll`); the `initialize` reply
  sends the default exception filters when `initialized` already ran.
  `cmd_dap.zig` registers `dotnet.debug`.
- `// changed (highlight):` `structure.Kind.property` (`prop`, not a
  scope); `kinds` gains the c_sharp declaration names; `isLambda`
  knows `lambda_expression` / `anonymous_method_expression`.
- `// changed (app):` `outline.zig` — `cs_rules`, `csMethodName`
  (a signature, not a call), `new` among the modifiers.
- `// changed (e2e):` a `# env:` value expands `$NAME` / `${NAME}`
  from the run's environment (`runner.expandEnv`); `mnml-zig test`
  exports `MNML_SHIMS` = `tools/shims/` (`build_options.shims_dir`);
  `tools/shims/dotnet` is the corpus's `dotnet`.
- `// added (spec):` `dotnet.build` `dotnet.run` `dotnet.test`
  `dotnet.restore` `dotnet.watch` (group `test`), `dotnet.debug`
  (group `dap`). Spec count 993.
- Tests: `dotnet.zig` (the walk, the csproj, the launch body, the test
  at the cursor both ways), `runners.zig` (toasts, roots, the filter
  arguments), `tests_pane.zig` (the console parser with the older
  signs / durations / build errors, the TRX, the source lookup, the
  pane on a project and `R`), `dap.zig` (a netcoredbg-shaped adapter
  in process, the built-in row and a config's precedence,
  `dotnet.debug` both ways), `structure.zig` / `syntax.zig` /
  `outline.zig` (the grammar), `runner.zig` (`expandEnv`), and the
  seven `tests/e2e/dotnet_*.test` scripts.
## Git — diff any two refs, the branch verbs, stash depth, the command log, the detail rows' menu (2026-09-08, branch `git-more2`) — `// changed:` notes

Items 6, 7, 9 and 10 of `docs/research/git-vs-lazygit.md` §3, plus
right-click audit #101.

- `// changed (git):` `client.DiffScope` gains `range` — `rev` holds
  `from..to` (`rangeRev`; `rangeTitle` shortens a full sha on either
  side for the tab) and `path` narrows it to one file. `GraphPane`
  keeps `compare_base` (a sha, so it survives a log reload): `W` sets
  or clears it, the mark cell shows `⚑` on the base (`B` in ascii),
  and the rows in `base..HEAD` (`rangeSet`, reachability over the
  loaded parents) sit on the raised ground (`pal.bg3`) — nothing
  changes at rest, so the pane columns match Rust as before. `d` on
  another row (`diffSelected`) or the row menu's *Diff against ⚑*
  opens the range diff; *Diff this commit* keeps the plain one. The
  branches panel's local and remote rows gain *Diff against current*
  (`GitPaletteAct.diff_current` → `git.diffAgainstCurrent`,
  `current..branch`, HEAD when detached); `git.diff_against_current`
  takes the panel's row or a branch picker (`Pick.diff_current`).
- `// changed (git):` the branch verbs. `Job.new_branch` is `{name,
  start}` and `worktree_add` gains `start` (a `--detach`ed tree when
  no branch is made); `branch_rename` (`branch -m`), `fast_forward`
  (`merge -q --ff-only <upstream>` when checked out — snapshot undo —
  else `fetch <remote> <ref>:<branch>`; null argv when the upstream
  has no `remote/` half), `set_upstream` (`branch -u`),
  `checkout_force` (`checkout -f`, snapshot undo), `delete_remote`
  (`push <remote> --delete <branch>`), `push_force` (`push
  --force-with-lease`). The argv builders `newBranchArgs` /
  `worktreeAddArgs` / `fastForwardArgs` are pure and tested. `git.State`
  gains `verb_branch` / `verb_start` (the branch a prompt or picker
  acts on; the commit a new branch / worktree starts from — taken by
  the prompt's accept); `PromptKind.branch_rename`; `Confirm.
  checkout_force / delete_remote / push_force`; `Pick.set_upstream`
  (remote branches only) / `checkout_force` / `delete_remote`. The
  branches panel's rows carry Rename… / Fast-forward to upstream /
  Set upstream… / Force checkout… / Delete on the remote… / Push
  --force-with-lease… (the current row), a remote row Delete on the
  remote…, a tag row New branch / New worktree from tag…; *New branch
  from here…* on a branch row now starts at that branch, not HEAD; the
  graph row menu gains New branch / New worktree from here…. The
  force-push confirm names the risk — Rust refused a force push
  outright; this is the deliberate change.
- `// changed (git):` `Job.stash` is `StashPush {msg, paths,
  staged_only, keep_index}` (`stashArgs`: `--staged` drops `-u`, which
  git refuses together). The status pane's menu offers Stash this
  file… / staged only… / keeping the index… / everything…
  (`git.stash_file` / `_staged` / `_keep_index` set
  `State.stash_variant` before the stash prompt). A STASHES row's
  Enter is `Job.stash_show` (`stash show --name-status
  --include-untracked`, the flag dropped on an older git) → the
  `.stash_show` result opens a `Pane.list` of kind `stash_files`
  (`State.stash_view` names the stash); Enter on a file opens the
  `.range` diff `ref^..ref` for it. The row menu leads with Show files
  and adds Branch from stash… (`Job.stash_branch`) and Rename…
  (`Job.stash_rename`: `rev-parse`, `stash drop`, `stash store -m` —
  `parse.stashRenameMessage` keeps the `On <branch>: ` half,
  `stashNote` is what the prompt opens with). The stash lists read
  `%gs` (the reflog subject) so a rename shows; `stashMessage` finds a
  ref's message the same way.
- `// changed (app):` `Pane.list` (`ListPane`) gains the kinds
  `stash_files` and `git_log`, a `/` filter (`filters(kind)`, `shown`
  / `entryAt` / `shownCount` over the case-insensitive needle; the
  filter row paints under the header), `y` (the row's path or text —
  the command line on the log), and a right-click row menu on the git
  kinds (`git.openListRowMenu`, on the menu's own arena). Enter on
  the git kinds goes through `git.stashFileEnter` / `git.logEnter`.
- `// changed (git):` the command log. `Repo` keeps `events` from
  `start` and `log_seq`; `gitIn` and `run` time every child and post a
  `.log_line` result (`LogLine {seq, argv, args, cwd, ok, exit, ms,
  stderr}` — the first stderr line) as its own `.git` event, so a
  job's line lands before its outcome. The handler numbers them in
  arrival order and keeps the last 200 on `git.State.log`
  (`LogRing`); a failed child sets `last_failed_seq`. A failed op's
  toast now carries `log_toast_id` and ends in ` · log` (the reason
  clipped so the link stays inside the box); the op handler records
  `log_link_seq` = the last failed child; a click on that toast
  (`dispatch`'s toast arm) or the toast menu's first row opens
  `git.command_log` at the entry. The pane lists newest first; Enter
  re-runs a read-only command (`client.isReadOnly`: the listing verbs,
  and only the listing forms of `branch` / `stash` / `remote` /
  `worktree` / `config`) through `Job.rerun` (the first output line
  rides in the toast) and refuses a writing one by name; an open
  pane refills as lines land, keeping its entry. The ring lives with
  the handler, not the worker: the worker only posts (D3 — nothing on
  the UI thread reads worker memory).
- `// changed (app):` right-click on the graph's detail file rows
  (audit #101 — Rust's embedded diff rows): a working-tree row offers
  Open diff / Open file / Stage or Unstage / Discard… / Stash this
  file… / Copy path; a commit's file row Open the file's diff in this
  commit / Open file at this revision (`Job.show_file` → `.file_text`
  → `App.openScratchWith`, a scratch copy) / Copy commit hash (sha) /
  Copy path / Browse commit on remote (`openDetailRowMenu`). The
  `git.stage` family reads the graph's WIP detail row when its column
  has the keys (`git.wipDetailRow`, `cmd_git.selectedRow`).
- `// added (spec):` twenty-three ids — `git.compare_base`
  `git.diff_against_base` `git.graph_diff` `git.diff_against_current`
  `git.branch_rename` `git.fast_forward` `git.set_upstream`
  `git.checkout_force` `git.delete_remote_branch` `git.new_branch_from`
  `git.worktree_add_from` `git.push_force` `git.stash_staged`
  `git.stash_file` `git.stash_keep_index` `git.stash_show`
  `git.stash_show_diff` `git.stash_branch` `git.stash_rename`
  `git.command_log` `git.command_log_rerun` `git.graph_detail_open`
  `git.graph_file_at_rev`. Spec count 1031 (1008 on main + 23).
- Tests: `client.zig` (`rangeRev` / `rangeTitle`, the branch verbs'
  argv, `stashArgs`, `isReadOnly`), `parse.zig`
  (`stashRenameMessage`), `app/git.zig` (the compare base on a seeded
  repo; the verbs on a seeded bare remote; the stash variants, the
  files pane, rename and branch; the ring's cap and the log's toast
  link, re-run and refusal; the detail rows' menus and the scratch
  copy), and `tests/e2e/git_compare_base`, `git_branch_rename`,
  `git_fast_forward`, `git_new_branch_from`, `git_stash_staged_pop`,
  `git_stash_show`, `git_command_log`,
  `git_graph_detail_rightclick.test`; `git_palette_apply_stash.test`
  re-aimed (a second click shows the files; Apply is the menu's).
