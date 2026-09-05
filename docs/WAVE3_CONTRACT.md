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
