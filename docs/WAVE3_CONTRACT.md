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
- `// changed (app):` a language server is spawned only when a root
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
  `tests/e2e-zig/lua_init.test` the e2e. Corpus 226/227 — the one
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
  `docs/parity-notes/misc.md`.
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
  The `+` menu has "New dock note". Six ids beyond the Rust seven:
  `dock.toggle` / `add` / `add_preset` (a `.custom` picker) / `remove` /
  `edit` / `rename`. Pin 857.
- Not done, by design: the `⟳` chip's right-click menu and
  `ui.auto_refresh_off` (every panel's chip is a left-click rescan);
  the Rust SESSIONS strip's per-row transcript summary lines, bells
  and ticket detection; the clock is UTC (no `localtime` in std).

## EDITOR / EX tier — `// changed:` notes (2026-09-05, branch `editor-ex`)

The full row-by-row account is `docs/parity-notes/editor-ex.md`; this
is the contract-level list of what moved.

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
  `render.drawMenu` paints the glyph column (`ui/menu_glyph.zig` — one
  glyph and one ASCII twin per command group, the twin under
  `ui.ascii_icons`; the glyph audit holds every site to it), `▸` on a
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
  to each line's text.
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
- `// changed (tests):` `tests/e2e-zig/vim_*.test`, one per finding
  (fourteen files), each watched failing on the unfixed tree first; unit
  rows in `src/editor/buffer.zig`'s vim tables and in `block`, `line`,
  `insert`, `clipboard`, `editor_view`, `cmd_buffer`, `ex`. Break-checks
  run: `tools/break-check.sh "small-delete register" src/editor/clipboard.zig
  "s/putNamed('-', /putNamed('1', /"` and
  `tools/break-check.sh "vim undo, redo, dot-repeat" src/editor/buffer.zig
  's/if (countedOp(d)) |n| n\.\* = count else times = count;/times = count;/'`
  — both fail with the break in place.

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
- `// changed (tests):` `tests/e2e-zig/settings_chip_click.test`,
  `settings_wheel.test`, `settings_row_window.test`,
  `toast_menu_fits.test`, `split_divider_lands_on_pointer.test`. Unit
  rows in `src/ui/settings.zig` (chip walk, wheel, window),
  `src/app/render.zig` (toast menu, `menuTop`), `src/app/layout.zig`
  (`ratioAt` round trip). Break-checks in each commit body; the
  paint-order one first "passed" by crashing the test (a break that
  read `app.overlay.menu` under `.none`) — `tools/break-check.sh` counts
  a crash as a fail through the build summary's `(1 failed)`, so a
  break has to be re-read for *why* it failed before it counts.
