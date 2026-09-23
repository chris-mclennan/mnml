//! Editor view — paints a `Doc` (a plain data view the app fills from its
//! buffer each frame) into a pane: gutter, text, selection, cursors, find
//! matches, syntax spans, the cursor-line band, and folds.
//!
//! The view is a pure function of `Doc` + `ViewState`: it never reaches
//! into the editor. It owns the two scroll offsets in `ViewState` because
//! keeping the cursor visible is a rendering fact — how many rows a line
//! takes under wrap, how many cells a tab or a CJK glyph takes — and only
//! the painter knows those. Everything else about the cursor is the
//! app's.
//!
//! Every visible grapheme registers an `.editor_cell` hit whose `col` is
//! its byte offset in the line, so a click lands on the right byte even
//! through tabs and wide glyphs; the space past a line's end maps to the
//! line's length. A collapsed fold paints as ONE row: the first line's
//! text and then ` ⋯ folded · N lines hidden` (ascii: ` ... folded - N
//! lines hidden`) — the gate asserts both words.
//!
//! // changed: `Doc.scrollbar` paints the one-cell vertical bar in the
//! pane's last column (registered `.scrollbar{pane, v}`) when the text
//! outgrows the rows, the text stopping a cell short of it, and `ViewState.pin` lets the app scroll the
//! viewport away from the cursor (a wheel in standard mode): while the
//! cursor stays at the pinned byte the view is not pulled back to it.

const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const scrollbar = @import("scrollbar.zig");
const border = @import("border.zig");
const indent_guides = @import("indent_guides.zig");
const blendOver = @import("diff_view.zig").blendOver;

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const PaneId = ids.PaneId;

/// A styled byte range (syntax highlighting). `style.fg` and the SGR
/// flags apply; the background is layered by the view.
pub const Span = struct { start: usize, end: usize, style: Style };
// ── {{VAR}} hook ── a request file's variable tokens, painted over the
// syntax spans (the variable role when the env resolves them, the error
// role when not) and registered as `.script_hit{ pane, var_hit_base + id }`
// so a click or hover reaches the http side. Nothing else in this file
// knows what a request is.
pub const VarSpan = struct { start: usize, end: usize, resolved: bool, id: u32 };
pub const var_hit_base: u32 = 100_000;
// ── end {{VAR}} hook ──
pub const Range = struct { start: usize, end: usize };
/// A collapsed fold: `first_line` stays visible, `first_line+1..=last_line`
/// are hidden. 0-based, inclusive.
pub const Fold = struct { first_line: u32, last_line: u32 };

/// Answers "does a fold START on this line?" for the one line under the
/// pointer — the gutter paints its `▼` there. The app hands over
/// `editor.toggle_fold`'s own rule, so the chevron never offers a fold
/// the command would refuse to make; without it the hover chevron is
/// simply off.
pub const Foldable = struct {
    ctx: *const anyopaque,
    startsFold: *const fn (ctx: *const anyopaque, line: u32) bool,

    pub fn call(f: Foldable, line: u32) bool {
        return f.startsFold(f.ctx, line);
    }
};

pub const CursorShape = enum { block, bar, underline };

/// A byte range underlined over the syntax style — a diagnostic. The
/// style's `fg` colours the line; `ul_style` picks its shape.
pub const Underline = struct { start: usize, end: usize, style: Style };

/// A one-cell label painted OVER the glyph at `byte` in the
/// `current_match` style — flash-motion's jump targets.
pub const Label = struct { byte: usize, text: []const u8 };
// ── virtual text (lsp-more) ──
// changed: `Doc` gains `virtual_text` (an inlay hint, a colour swatch —
// cells painted BEFORE the grapheme at `byte`, taking columns but no
// bytes; a click on them lands on `byte`) and `virtual_lines` (a code
// lens — a row painted ABOVE `line`, counted in the scroll math; each
// segment with a `hit` registers `.script_hit{pane, hit}`).

/// Text painted before the grapheme at `byte` (`byte == line end` paints
/// after the last grapheme). Sorted by `byte`.
pub const VirtualText = struct {
    byte: usize,
    text: []const u8,
    style: Style,
    /// A `.script_hit{pane, hit}` over the text, above the cell's own
    /// `.editor_cell` — for virtual text a press does something with
    /// (the current-line blame opens its commit).
    hit: ?u32 = null,
};
/// One clickable piece of a virtual line.
pub const VirtualSeg = struct { text: []const u8, style: Style, hit: ?u32 = null };
/// A row above `line` (0-based) — or below it when `below`. Sorted by
/// `line`; several rows may name the same line and stack in order.
/// // changed (lua-decor): `below` — `mnml.decor.virtual_text` with
/// `at = "below"` puts the row after the line's last row. A virtual
/// row is counted by the scroll math and never carries the cursor:
/// `j` / `k` move by text lines, so they step over it.
pub const VirtualLine = struct { line: u32, segments: []const VirtualSeg, below: bool = false };
/// A whole-row ground on `line` (0-based) — what `mnml.decor.line`'s
/// role paints. Sorted by `line`; the first entry for a line wins, and
/// the cursor line's own band still wins over it.
pub const LineGround = struct { line: u32, style: Style };

pub const IndentGuides = indent_guides.Mode;

pub const Doc = struct {
    text: []const u8,
    /// The byte offset of every line's first char (`[0] == 0`, one entry
    /// per `\n`), when the caller keeps one — the editor does. Without
    /// it the view walks the whole text for one, every frame.
    line_starts: ?[]const usize = null,
    /// Byte offset.
    cursor: usize,
    /// Selection tail; `null` = no selection.
    anchor: ?usize,
    extra_cursors: []const usize = &.{},
    folds: []const Fold = &.{},
    /// The rule behind the gutter's hover chevron (`Foldable`).
    foldable: ?Foldable = null,
    /// `ui.always_show_fold_arrows`: every foldable line wears its `▼`
    /// whether or not the pointer is on it, so a mouse never has to go
    /// looking for the one it can click.
    always_show_fold_arrows: bool = false,
    /// Sorted by `start`, non-overlapping.
    spans: []const Span = &.{},
    var_spans: []const VarSpan = &.{},
    /// Sorted by `start`.
    matches: []const Range = &.{},
    /// Index into `matches`.
    current_match: ?usize = null,
    wrap: bool,
    tab_width: u8,
    line_numbers: bool = true,
    cursor_shape: CursorShape = .block,
    focused: bool,
    /// Paint a rectangle from anchor→cursor instead of a byte range.
    visual_block: bool = false,
    /// The rectangle runs to every line's end (`$` in V-BLOCK).
    block_eol: bool = false,
    /// A vertical scrollbar in the last column when the text outgrows
    /// the pane.
    scrollbar: bool = false,
    /// The gutter's marks in priority order (`GutterMark`): git's change
    /// bars in the gutter's last cell, the sign column's glyphs in its
    /// first. Empty when there are none.
    gutter_marks: []const GutterMark = &.{},
    /// Blame mode: one label per line (`<sha7> <author> <age>`) painted
    /// INSTEAD of the line number; empty when blame is off. A line past
    /// the slice paints blank.
    blame: []const []const u8 = &.{},
    /// Sorted by `start`, non-overlapping.
    underlines: []const Underline = &.{},
    /// Sorted by `byte`. Each replaces the cell at its byte.
    /// // changed: flash labels are a `Doc` prop the app fills from its
    /// armed state, not an overlay walking the pane rects after the
    /// fact — the view already knows where every byte landed.
    labels: []const Label = &.{},
    /// Sorted by `byte`.
    virtual_text: []const VirtualText = &.{},
    /// Sorted by `line`.
    virtual_lines: []const VirtualLine = &.{},
    /// Sorted by `line`; the first entry for a line paints its ground.
    line_grounds: []const LineGround = &.{},

    // ── ui toggles ──
    // The `ui.*` fields that change what a cell looks like. Every one
    // defaults to the paint that shipped before it existed, so a Doc that
    // does not name it is byte for byte the old frame.
    /// The gutter counts from the cursor line (vim `relativenumber`);
    /// the cursor line itself keeps its absolute number.
    relative_numbers: bool = false,
    /// The cursor line's band (`ui.cursor_line`).
    cursor_line_band: bool = true,
    /// The debugger's current line (0-based): its row wears the band
    /// whatever `cursor_line_band` says, and the gutter's ▶.
    stopped_line: ?u32 = null,
    /// Spaces paint `·`, a tab's first cell `→`, in `theme.whitespace`.
    show_whitespace: bool = false,
    /// Trailing spaces off the cursor line paint on the error colour.
    highlight_trailing_ws: bool = false,
    /// `()[]{}` cycle three colours by nesting depth.
    bracket_rainbow: bool = false,
    /// Every occurrence of the word under the cursor, sorted, underlined.
    word_matches: []const Range = &.{},
    /// `ui.click_echo`: the word just clicked, underlined for a moment.
    echo: ?Range = null,
    /// `TODO` / `FIXME` / `XXX` / `HACK` / `NOTE` / `BUG` after a comment
    /// marker paint bold on the warning (or error) colour.
    todo_keywords: bool = false,
    /// 1-based display column painted on the panel ground; 0 = off.
    color_column: u16 = 0,
    /// Markdown concealed in place on the lines the cursor is not on:
    /// heading marks, emphasis and code fences hidden, the text styled.
    render_markdown: bool = false,
    /// `editor.indent_guides`: a rule at every indent step of a line's
    /// leading white space in `theme.indent_guide`, the cursor's scope in
    /// `theme.indent_guide_active` (`.active` paints only that one).
    /// Never on a wrapped row's continuation, never over a selection.
    indent_guides: IndentGuides = .off,
    /// The columns one indent level takes — the buffer's indent; 0 is
    /// `tab_width` (a tab-indented file).
    indent_step: u8 = 0,
};

/// `added` / `modified` / `deleted` are git's change marks — a coloured
/// bar in the gutter's LAST cell (`deleted` sits on the line after the
/// run). `sign` is a one-cell glyph in the gutter's FIRST cell: a
/// breakpoint, the debugger's ▶, a diagnostic's severity dot.
pub const MarkKind = enum { added, modified, deleted, sign };
/// A mark on `line` (0-based). A change mark needs only `kind`; a
/// `.sign` carries its `glyph` and `style` (the fg is used).
/// // changed (merge git ⨯ lsp-dap): one struct for both shapes. The
/// list is in priority order, not necessarily sorted — per column the
/// view paints the first match on a line. With line numbers off the
/// gutter is one cell while marks exist, both columns coincide, and the
/// sign wins over the change mark.
/// // changed (lua-decor): `priority` says who wins the shared cell
/// when several producers mark the same line. The app sorts the list
/// by it (stable, highest first) before the view walks it, so the
/// order below is the one that paints — see `priority.*` in
/// `app/script_decor.zig` and `docs/LUA.md`.
pub const GutterMark = struct {
    line: u32,
    kind: MarkKind,
    glyph: []const u8 = "",
    style: Style = .{},
    priority: u8 = 50,
};
/// Who wins the shared sign cell. Highest first; a script's gutter mark
/// defaults to `script` and may name any number, so a script can put
/// itself above a diagnostic or below one. `docs/LUA.md` states the
/// same ladder.
pub const mark_priority = struct {
    /// The debugger's ▶ and its breakpoints (`app/dap.zig`).
    pub const breakpoint: u8 = 90;
    /// A fold's chevron — `▶` on a folded line, `▼` on a foldable one
    /// under the pointer. Above a diagnostic and git's bars, so a fold
    /// is never silent on a line that also has one; below the debugger,
    /// whose signs a fold must not hide.
    pub const fold: u8 = 75;
    /// A diagnostic's severity dot (`app/lsp.zig`).
    pub const diagnostic: u8 = 60;
    /// `mnml.decor.gutter`'s default.
    pub const script: u8 = 50;
    /// Git's change bars, which live in the gutter's other column
    /// anyway (`app/git.zig`).
    pub const git_change: u8 = 10;
    /// The chevron a foldable line wears while the pointer is on it —
    /// the last word, so it only ever fills a cell nothing else wanted.
    /// A folded line's own chevron is `fold` above; this is the offer,
    /// not the state, and an offer must not hide a fact.
    pub const fold_hover: u8 = 5;
};

/// The widest blame label the gutter will show.
pub const blame_max_w: u16 = 32;

/// Persistent per pane; `draw` adjusts it to keep the cursor visible —
/// unless `pin` names the cursor's current byte, in which case the
/// scroll offsets are the app's and the cursor may sit off-screen.
pub const ViewState = struct {
    scroll_line: u32 = 0,
    scroll_col: u32 = 0,
    pin: ?usize = null,

    /// Keep the view where the app put it until the cursor moves.
    pub fn pinAt(v: *ViewState, cursor: usize) void {
        v.pin = cursor;
    }
};

/// The text column the bar leaves at the right edge.
pub const scrollbar_w: u16 = 1;

pub const Cursor = struct { x: u16, y: u16 };

pub const fold_marker = " ⋯ folded · ";
pub const fold_marker_ascii = " ... folded - ";
pub const fold_tail = " lines hidden";
pub const fold_tail_one = " line hidden";

/// The closed-fold tail for `n` hidden lines. A fold over two lines hides
/// exactly one, and Neovim's own `foldtext()` gets that singular right.
pub fn foldTail(hidden: usize) []const u8 {
    return if (hidden == 1) fold_tail_one else fold_tail;
}

/// The gutter's fold chevrons. The sign cell speaks in geometric
/// shapes — the breakpoint's `●`, the debugger's `▶` — so the fold
/// joins that family rather than the tree's Octicons, and
/// `ui.expand_indicator` still picks between the chevron and the small
/// triangle as it does for every expander.
pub const fold_closed_chevron = "\u{25B6}";
pub const fold_open_chevron = "\u{25BC}";
pub const fold_closed_triangle = "\u{25B8}";
pub const fold_open_triangle = "\u{25BE}";
pub const fold_closed_ascii = ">";
pub const fold_open_ascii = "v";

/// `closed` = the line is folded (the chevron points at what is hidden).
pub fn foldGlyph(ui: Ui, closed: bool) []const u8 {
    // Geometric shapes, not Nerd Font glyphs — only `--ascii` drops them.
    if (ui.ascii) return if (closed) fold_closed_ascii else fold_open_ascii;
    if (ui.triangle) return if (closed) fold_closed_triangle else fold_open_triangle;
    return if (closed) fold_closed_chevron else fold_open_chevron;
}

// ─── the breadcrumb row ─────────────────────────────────────────────────
//
// Rust's `draw_breadcrumb`: the row between the tab strip and the text,
// on the strip's ground, the file's workspace-relative path as
// ` src › ui › editor_view.rs ` in the comment colour. Each segment is
// a click target while the whole label fits; a label wider than the row
// is cut in the middle with `…`, and a cut row registers nothing — a
// column of it no longer maps to a segment.

/// ` › ` between segments (` > ` under `--ascii`).
pub fn breadcrumbSep(ui: Ui) []const u8 {
    return if (ui.ascii) " > " else " \u{203A} ";
}

/// The row's height: one, when the pane has room for the strip, the
/// crumb and a line of text.
pub const breadcrumb_h: u16 = 1;

/// `names` joined by the separator, on the frame arena.
pub fn breadcrumbLabel(ui: Ui, names: []const []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) out.appendSlice(ui.arena, breadcrumbSep(ui)) catch return "";
        out.appendSlice(ui.arena, n) catch return "";
    }
    return out.items;
}

/// Paints the crumb for `names` into `area` (one row) and registers a
/// `.breadcrumb{pane, idx}` per segment when the label fits.
pub fn drawBreadcrumb(ui: Ui, pane: PaneId, area: Rect, names: []const []const u8) void {
    if (area.isEmpty() or names.len == 0) return;
    const p = ui.theme.palette;
    const ground: Style = .{ .bg = p.bg_darker };
    ui.fill(area, ground);
    const y = area.y;
    const max = area.w -| 2;
    const label = breadcrumbLabel(ui, names);
    const style: Style = .{ .fg = p.comment, .bg = p.bg_darker };
    if (ui.fitsIn(label, max)) {
        var x = area.x + 1;
        const sep = breadcrumbSep(ui);
        for (names, 0..) |n, i| {
            if (i > 0) x += ui.putStr(x, y, area.right() -| x, sep, style);
            const w = ui.putStr(x, y, area.right() -| x, n, style);
            ui.hit(Rect.init(x, y, w, 1), .{ .breadcrumb = .{ .pane = pane, .idx = @intCast(i) } });
            x += w;
        }
        return;
    }
    // Cut in the middle: `head…tail`, no targets.
    if (max <= 3) {
        _ = ui.putStr(area.x + 1, y, max, label, style);
        return;
    }
    const half = (max - 1) / 2;
    const tail_w = max - 1 - half;
    var head_end: usize = 0;
    var it = utf8.graphemeIterator(label);
    var cells: u16 = 0;
    while (it.next()) |g| {
        const b = g.bytes(label);
        const w = ui.canvas.cellWidth(b);
        if (cells + w > half) break;
        cells += w;
        head_end = g.start + b.len;
    }
    // The tail: walk from the end until `tail_w` cells are gathered.
    var tail_start: usize = label.len;
    cells = 0;
    var i: usize = label.len;
    while (i > 0) {
        var j = i - 1;
        while (j > 0 and (label[j] & 0xC0) == 0x80) j -= 1;
        const w = ui.canvas.cellWidth(label[j..i]);
        if (cells + w > tail_w) break;
        cells += w;
        tail_start = j;
        i = j;
    }
    var x = area.x + 1;
    x += ui.putStr(x, y, area.right() -| x, label[0..head_end], style);
    x += ui.putStr(x, y, area.right() -| x, if (ui.ascii) "~" else "\u{2026}", style);
    _ = ui.putStr(x, y, area.right() -| x, label[tail_start..], style);
}

// ── the line index ──

/// Byte ranges of every line, excluding the newline. Built on the frame
/// arena; a document always has at least one line.
/// Bytes of text walked to build a line index (`Lines.build`) since the
/// process started — what a test reads to show a frame over a large
/// document walked none.
pub var line_index_bytes_scanned: usize = 0;

pub const Lines = struct {
    /// Built from the text (`build`) when the caller has no index.
    starts: []const u32 = &.{},
    /// The document's own line index, borrowed (`from`): the editor keeps
    /// one, spliced with every edit, so a frame never rebuilds it.
    index: ?[]const usize = null,
    text_len: u32,
    /// Lines painted: every line, less the phantom line a trailing
    /// `\n` would open — see `hidePhantom`.
    shown: u32,

    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!Lines {
        line_index_bytes_scanned += text.len;
        var n: usize = 1;
        for (text) |c| if (c == '\n') {
            n += 1;
        };
        const starts = try arena.alloc(u32, n);
        starts[0] = 0;
        var i: usize = 1;
        for (text, 0..) |c, off| if (c == '\n') {
            starts[i] = @intCast(off + 1);
            i += 1;
        };
        return .{ .starts = starts, .text_len = @intCast(text.len), .shown = @intCast(n) };
    }

    /// Over an index the caller keeps: `[0] == 0`, one entry per `\n`.
    pub fn from(index: []const usize, text_len: usize) Lines {
        return .{ .index = index, .text_len = @intCast(text_len), .shown = @intCast(index.len) };
    }

    fn total(l: Lines) usize {
        return if (l.index) |ix| ix.len else l.starts.len;
    }

    fn startAt(l: Lines, i: usize) u32 {
        return if (l.index) |ix| @intCast(ix[i]) else l.starts[i];
    }

    /// A trailing `\n` terminates the last line rather than opening an
    /// empty line N+1 (the editor counts it that way; `G` cannot reach
    /// it) — unless the cursor, the anchor or an extra cursor sits at
    /// EOF, in which case the row stays so they have somewhere to paint.
    pub fn hidePhantom(l: *Lines, doc: Doc) void {
        if (l.total() < 2 or l.text_len == 0 or doc.text[l.text_len - 1] != '\n') return;
        const phantom: u32 = @intCast(l.total() - 1);
        if (l.lineOf(doc.cursor) == phantom) return;
        if (doc.anchor) |a| if (l.lineOf(a) == phantom) return;
        for (doc.extra_cursors) |c| if (l.lineOf(c) == phantom) return;
        l.shown = phantom;
    }

    pub fn count(l: Lines) u32 {
        return l.shown;
    }

    pub fn start(l: Lines, line: u32) u32 {
        return l.startAt(line);
    }

    /// One past the last byte of the line's text (the newline's offset,
    /// or the text length on the last line).
    pub fn end(l: Lines, line: u32) u32 {
        if (line + 1 < l.total()) return l.startAt(line + 1) - 1;
        return l.text_len;
    }

    pub fn slice(l: Lines, text: []const u8, line: u32) []const u8 {
        return text[l.start(line)..l.end(line)];
    }

    /// The line containing byte `off` (offsets past the end land on the
    /// last line).
    pub fn lineOf(l: Lines, off: usize) u32 {
        var lo: usize = 0;
        var hi: usize = l.total();
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (l.startAt(mid) <= off) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }
};

// ── folds ──

fn foldStartingAt(folds: []const Fold, line: u32) ?Fold {
    for (folds) |f| if (f.first_line == line and f.last_line > f.first_line) return f;
    return null;
}

/// The fold hiding `line`, if any.
fn foldHiding(folds: []const Fold, line: u32) ?Fold {
    for (folds) |f| if (line > f.first_line and line <= f.last_line) return f;
    return null;
}

/// The next line painted after `line`.
fn nextVisible(folds: []const Fold, line: u32) u32 {
    if (foldStartingAt(folds, line)) |f| return f.last_line + 1;
    return line + 1;
}

/// `line` itself when visible, else the start of the fold hiding it.
fn visibleOwner(folds: []const Fold, line: u32) u32 {
    return if (foldHiding(folds, line)) |f| f.first_line else line;
}

// ── cell layout ──

/// One painted cell of a line: the grapheme, its byte offset within the
/// line, and its width. A tab expands to several one-cell spaces that
/// all carry the tab's offset.
pub const CellInfo = struct {
    bytes: []const u8,
    off: u32,
    w: u8,
    ws: bool,
    /// One of the cells a tab expanded into.
    tab: bool = false,
};

pub fn layoutLine(ui: Ui, line: []const u8, tab_width: u8) Allocator.Error![]CellInfo {
    var out: std.ArrayListUnmanaged(CellInfo) = .empty;
    const tw: u32 = if (tab_width == 0) 1 else tab_width;
    var x: u32 = 0;
    var it = utf8.graphemeIterator(line);
    while (it.next()) |g| {
        // An invalid byte is its own one-cell unit, painted as U+FFFD.
        const bytes = utf8.displayBytes(g.bytes(line));
        const off: u32 = @intCast(g.start);
        if (bytes.len == 1 and bytes[0] == '\t') {
            const n = tw - (x % tw);
            for (0..n) |_| {
                try out.append(ui.arena, .{ .bytes = " ", .off = off, .w = 1, .ws = true, .tab = true });
                x += 1;
            }
            continue;
        }
        const w = ui.canvas.cellWidth(bytes);
        if (w == 0) continue;
        try out.append(ui.arena, .{ .bytes = bytes, .off = off, .w = @intCast(@min(w, 2)), .ws = bytes.len == 1 and bytes[0] == ' ' });
        x += w;
    }
    return out.items;
}

pub const RowSpan = struct { start: u32, end: u32 };

/// Splits `cells` into rows no wider than `width`, breaking after the
/// last space when the row has one, else between graphemes. Always at
/// least one row.
pub fn wrapRows(arena: Allocator, cells: []const CellInfo, width: u16) Allocator.Error![]RowSpan {
    var rows: std.ArrayListUnmanaged(RowSpan) = .empty;
    if (width == 0) {
        try rows.append(arena, .{ .start = 0, .end = @intCast(cells.len) });
        return rows.items;
    }
    var start: u32 = 0;
    var x: u32 = 0;
    var last_ws: ?u32 = null;
    var i: u32 = 0;
    while (i < cells.len) {
        const c = cells[i];
        // A space that overflows hangs off the row end (the paint clips
        // it) so the next row starts on a word, like ratatui's wrapper.
        if (x > 0 and x + c.w > width and !c.ws) {
            const brk: u32 = if (last_ws) |ws| ws + 1 else i;
            try rows.append(arena, .{ .start = start, .end = brk });
            start = brk;
            i = brk;
            x = 0;
            last_ws = null;
            continue;
        }
        x += c.w;
        if (c.ws) last_ws = i;
        i += 1;
    }
    try rows.append(arena, .{ .start = start, .end = @intCast(cells.len) });
    return rows.items;
}

/// Display column of the cell holding byte `off` (the total width when
/// `off` is at or past the end).
fn cellX(cells: []const CellInfo, off: u32) u32 {
    var x: u32 = 0;
    for (cells) |c| {
        if (c.off >= off) return x;
        x += c.w;
    }
    return x;
}

/// Index of the cell holding byte `off`, or `cells.len` at the end.
fn cellIndex(cells: []const CellInfo, off: u32) u32 {
    for (cells, 0..) |c, i| if (c.off >= off) return @intCast(i);
    return @intCast(cells.len);
}

fn rowOfCell(rows: []const RowSpan, idx: u32) u32 {
    for (rows, 0..) |r, i| if (idx < r.end or i == rows.len - 1) return @intCast(i);
    return 0;
}

// ── layering ──

const Selection = struct {
    lo: usize,
    hi: usize,
    /// Rectangle in (line, display col), inclusive.
    block: ?struct { l0: u32, l1: u32, c0: u32, c1: u32, eol: bool = false } = null,
};

fn firstIndexEndingAfter(comptime T: type, items: []const T, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].end <= off) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Sorted-range walker: the span/match covering a byte, advanced
/// monotonically along a line.
fn RangeCursor(comptime T: type) type {
    return struct {
        items: []const T,
        i: usize,

        const Self = @This();

        fn init(items: []const T, from: usize) Self {
            return .{ .items = items, .i = firstIndexEndingAfter(T, items, from) };
        }

        fn at(self: *Self, off: usize) ?usize {
            while (self.i < self.items.len and self.items[self.i].end <= off) self.i += 1;
            if (self.i < self.items.len and self.items[self.i].start <= off) return self.i;
            return null;
        }
    };
}

fn gutterWidth(doc: Doc, total: u32) u16 {
    if (doc.blame.len > 0) {
        // Blame replaces the numbers: the widest label, capped.
        var w: usize = 0;
        for (doc.blame) |l| w = @max(w, std.unicode.utf8CountCodepoints(l) catch l.len);
        return @as(u16, @intCast(@min(w, blame_max_w))) + 2;
    }
    if (!doc.line_numbers) return if (doc.gutter_marks.len > 0) 1 else 0;
    var digits: u16 = 1;
    var n = total;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(digits, 3) + 2;
}

/// The first change mark on `line`, if any.
fn changeMarkAt(marks: []const GutterMark, line: u32) ?MarkKind {
    for (marks) |m| if (m.line == line and m.kind != .sign) return m.kind;
    return null;
}

/// The first sign on `line`, if any.
fn signAt(marks: []const GutterMark, line: u32) ?GutterMark {
    for (marks) |m| if (m.line == line and m.kind == .sign) return m;
    return null;
}

/// What the gutter's sign cell shows on `line`: the highest-priority
/// mark there, or the fold chevron when that outranks it. `fold_arrow`
/// says the cell is the fold's, so the paint can register the click.
const Sign = struct { mark: GutterMark, fold_arrow: bool = false };

fn signFor(ui: Ui, doc: Doc, line: u32, folded: bool, hovered: bool) ?Sign {
    const mark = signAt(doc.gutter_marks, line);
    const chevron: ?GutterMark = blk: {
        // A folded line always wears its `▶`: the fold is otherwise
        // only visible as a chip past the end of a long row.
        if (folded) break :blk .{ .line = line, .kind = .sign, .glyph = foldGlyph(ui, true), .style = .{ .fg = ui.theme.fold.fg }, .priority = mark_priority.fold };
        if (hovered or doc.always_show_fold_arrows) if (doc.foldable) |f| if (f.call(line)) break :blk GutterMark{ .line = line, .kind = .sign, .glyph = foldGlyph(ui, false), .style = .{ .fg = ui.theme.muted.fg }, .priority = mark_priority.fold_hover };
        break :blk null;
    };
    const c = chevron orelse return if (mark) |m| Sign{ .mark = m } else null;
    if (mark) |m| if (m.priority > c.priority) return Sign{ .mark = m };
    return .{ .mark = c, .fold_arrow = true };
}

pub fn markStyle(t: *const Theme, kind: MarkKind, base: Style) Style {
    return Theme.withFg(base, switch (kind) {
        .added => t.syntax.string.fg,
        .modified => t.warn_fg.fg,
        .deleted => t.error_fg.fg,
        .sign => t.fg.fg,
    });
}

/// Every virtual line naming `line`, above and below together.
fn virtualLinesOf(doc: Doc, line: u32) []const VirtualLine {
    const vl = doc.virtual_lines;
    var lo: usize = 0;
    var hi: usize = vl.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (vl[mid].line < line) lo = mid + 1 else hi = mid;
    }
    var e = lo;
    while (e < vl.len and vl[e].line == line) e += 1;
    return vl[lo..e];
}

/// How many of `line`'s virtual rows sit on the given side.
fn virtualLineCount(doc: Doc, line: u32, below: bool) u32 {
    var n: u32 = 0;
    for (virtualLinesOf(doc, line)) |vl| {
        if (vl.below == below) n += 1;
    }
    return n;
}

/// The whole-row ground `line` was given, if any (`mnml.decor.line`).
fn lineGroundAt(doc: Doc, line: u32) ?Style {
    for (doc.line_grounds) |g| {
        if (g.line == line) return g.style;
        if (g.line > line) break;
    }
    return null;
}

/// Index of the first virtual text at or past byte `off`.
fn firstVirtualAt(vt: []const VirtualText, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = vt.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (vt[mid].byte < off) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Rows `line` takes at `text_w` (1 when not wrapping or folded), plus
/// the virtual lines above and below it.
fn lineRows(ui: Ui, doc: Doc, lines: Lines, line: u32, text_w: u16) Allocator.Error!u32 {
    const virt: u32 = @intCast(virtualLinesOf(doc, line).len);
    if (!doc.wrap or foldStartingAt(doc.folds, line) != null) return 1 + virt;
    const cells = try layoutLine(ui, lines.slice(doc.text, line), doc.tab_width);
    return @as(u32, @intCast((try wrapRows(ui.arena, cells, text_w)).len)) + virt;
}

/// Paint `line`'s virtual rows on one side, top-down from `y`, and
/// answer the row after them. A segment with a `hit` is clickable
/// where it painted, exactly as in a script pane.
fn drawVirtualRows(ui: Ui, pane: PaneId, area: Rect, doc: Doc, line: u32, below: bool, text_x: u16, text_w: u16, y_in: u16) u16 {
    const t = ui.theme;
    var y = y_in;
    for (virtualLinesOf(doc, line)) |vl| {
        if (vl.below != below) continue;
        if (y >= area.bottom()) break;
        ui.fill(Rect.init(area.x, y, area.w, 1), t.bg);
        var vx: u16 = text_x;
        for (vl.segments) |seg| {
            if (vx >= text_x + text_w) break;
            const used = ui.putStr(vx, y, text_x + text_w - vx, seg.text, Theme.onBg(seg.style, t.bg.bg));
            if (seg.hit) |id| ui.hit(Rect.init(vx, y, used, 1), .{ .script_hit = .{ .pane = pane, .id = id } });
            vx += used + 2;
        }
        y += 1;
    }
    return y;
}

/// Adjusts `view` so the cursor's row is inside `text_h` rows.
fn keepCursorVisible(ui: Ui, doc: Doc, lines: Lines, view: *ViewState, text_w: u16, text_h: u16) Allocator.Error!void {
    const total = lines.count();
    if (view.scroll_line >= total) view.scroll_line = total - 1;
    view.scroll_line = visibleOwner(doc.folds, view.scroll_line);
    if (view.pin) |p| {
        if (p == doc.cursor) return tailClamp(ui, doc, lines, view, text_w, text_h);
        view.pin = null;
    }

    const cur_line = visibleOwner(doc.folds, lines.lineOf(doc.cursor));
    const cur_cells = try layoutLine(ui, lines.slice(doc.text, cur_line), doc.tab_width);
    const cur_off: u32 = if (lines.lineOf(doc.cursor) == cur_line) @intCast(doc.cursor - lines.start(cur_line)) else 0;

    if (cur_line < view.scroll_line) {
        view.scroll_line = cur_line;
    } else if (text_h > 0) {
        // Rows above the cursor's own row, from scroll_line.
        var heights: std.ArrayListUnmanaged(u32) = .empty;
        var starts: std.ArrayListUnmanaged(u32) = .empty;
        var sum: u32 = 0;
        var line = view.scroll_line;
        while (line < cur_line) : (line = nextVisible(doc.folds, line)) {
            const h = try lineRows(ui, doc, lines, line, text_w);
            try heights.append(ui.arena, h);
            try starts.append(ui.arena, line);
            sum += h;
        }
        var subrow: u32 = virtualLineCount(doc, cur_line, false);
        if (doc.wrap and foldStartingAt(doc.folds, cur_line) == null) {
            const rows = try wrapRows(ui.arena, cur_cells, text_w);
            subrow += rowOfCell(rows, cellIndex(cur_cells, cur_off));
        }
        var front: usize = 0;
        while (sum + subrow >= text_h and front < heights.items.len) {
            sum -= heights.items[front];
            front += 1;
            view.scroll_line = if (front < starts.items.len) starts.items[front] else cur_line;
        }
        if (sum + subrow >= text_h) view.scroll_line = cur_line;
    }

    try tailClamp(ui, doc, lines, view, text_w, text_h);
    try followCursorCol(ui, doc, view, cur_cells, cur_off, text_w);
}

/// Never leave rows blank below the last line when an earlier scroll
/// would fill them.
fn tailClamp(ui: Ui, doc: Doc, lines: Lines, view: *ViewState, text_w: u16, text_h: u16) Allocator.Error!void {
    const total = lines.count();
    while (view.scroll_line > 0) {
        var rows: u32 = 0;
        var line = view.scroll_line;
        while (line < total and rows < text_h) : (line = nextVisible(doc.folds, line)) {
            rows += try lineRows(ui, doc, lines, line, text_w);
        }
        if (rows >= text_h) break;
        // Step back one visible line.
        var prev = view.scroll_line - 1;
        prev = visibleOwner(doc.folds, prev);
        const prev_rows = try lineRows(ui, doc, lines, prev, text_w);
        if (rows + prev_rows > text_h) break;
        view.scroll_line = prev;
    }
}

fn followCursorCol(ui: Ui, doc: Doc, view: *ViewState, cur_cells: []const CellInfo, cur_off: u32, text_w: u16) Allocator.Error!void {
    _ = ui;
    if (doc.wrap) {
        view.scroll_col = 0;
    } else if (text_w > 0) {
        const cx = cellX(cur_cells, cur_off);
        if (cx < view.scroll_col) {
            view.scroll_col = cx;
        } else if (cx >= view.scroll_col + text_w) {
            view.scroll_col = cx - text_w + 1;
        }
    }
}

fn selectionOf(ui: Ui, doc: Doc, lines: Lines) Allocator.Error!?Selection {
    const anchor = doc.anchor orelse return null;
    var sel: Selection = .{ .lo = @min(anchor, doc.cursor), .hi = @max(anchor, doc.cursor) };
    if (doc.visual_block) {
        const la = lines.lineOf(anchor);
        const lc = lines.lineOf(doc.cursor);
        const ca = cellX(try layoutLine(ui, lines.slice(doc.text, la), doc.tab_width), @intCast(anchor - lines.start(la)));
        const cc = cellX(try layoutLine(ui, lines.slice(doc.text, lc), doc.tab_width), @intCast(doc.cursor - lines.start(lc)));
        sel.block = .{ .l0 = @min(la, lc), .l1 = @max(la, lc), .c0 = @min(ca, cc), .c1 = @max(ca, cc), .eol = doc.block_eol };
    }
    return sel;
}

/// Paints gutter + text, keeps the cursor visible (adjusting `view`),
/// registers `.editor_cell` hits per visible cell, and returns the
/// cursor's screen position (null when off-screen).
pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *ViewState, doc: Doc) ?Cursor {
    return drawInner(ui, pane, area, view, doc) catch null;
}

fn drawInner(ui: Ui, pane: PaneId, area: Rect, view: *ViewState, doc: Doc) Allocator.Error!?Cursor {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return null;

    var lines = if (doc.line_starts) |ix| Lines.from(ix, doc.text.len) else try Lines.build(ui.arena, doc.text);
    lines.hidePhantom(doc);
    const total = lines.count();
    const gutter_w = @min(gutterWidth(doc, total), area.w);
    const num_w: u16 = gutter_w -| 2;
    const text_h = area.h;
    const bar = doc.scrollbar and total > text_h and area.w > gutter_w + 4;
    // The bar's column and a cell of air before it (Rust keeps a pad
    // there too, beside its change strip).
    const text_w = area.w - gutter_w - @as(u16, if (bar) scrollbar_w + 1 else 0);
    const text_x = area.x + gutter_w;

    try keepCursorVisible(ui, doc, lines, view, text_w, text_h);

    const sel = try selectionOf(ui, doc, lines);
    const cursor_line_real = lines.lineOf(doc.cursor);
    const cursor_line = visibleOwner(doc.folds, cursor_line_real);
    const cursor_off: u32 = if (cursor_line_real == cursor_line) @intCast(doc.cursor - lines.start(cursor_line)) else 0;
    var found: ?Cursor = null;
    var label_i: usize = 0;

    const fold_word = if (ui.ascii) fold_marker_ascii else fold_marker;

    // ── indent guides ── the step and the cursor's scope, once a frame
    const guides: ?indent_guides.Frame(Lines) = if (doc.indent_guides != .off)
        indent_guides.Frame(Lines).init(doc.text, lines, if (doc.tab_width == 0) 1 else doc.tab_width, if (doc.indent_step == 0) doc.tab_width else doc.indent_step, cursor_line_real)
    else
        null;
    const guide_glyph = border.ruleGlyph(.v, ui.ascii);

    // ── ui toggles ── the bracket depth at the top of the viewport
    var rainbow_depth: u32 = if (doc.bracket_rainbow) bracketDepthOver(doc.text, 0, lines.start(view.scroll_line), 0) else 0;

    var y: u16 = area.y;
    var line = view.scroll_line;
    while (y < area.bottom() and line < total) : (line = nextVisible(doc.folds, line)) {
        const fold = foldStartingAt(doc.folds, line);
        const line_start = lines.start(line);
        const line_end = lines.end(line);
        const line_text = doc.text[line_start..line_end];
        const cells = try layoutLine(ui, line_text, doc.tab_width);
        const rows: []const RowSpan = if (doc.wrap and fold == null)
            try wrapRows(ui.arena, cells, text_w)
        else
            &.{.{ .start = 0, .end = @intCast(cells.len) }};

        const is_cursor_line = line == cursor_line;
        const is_stopped_line = doc.stopped_line != null and doc.stopped_line.? == line;
        const row_style: Style = if ((is_cursor_line and doc.cursor_line_band) or is_stopped_line)
            t.cursor_line
        else if (lineGroundAt(doc, line)) |g|
            g
        else
            t.bg;
        var spans = RangeCursor(Span).init(doc.spans, line_start);
        var var_spans = RangeCursor(VarSpan).init(doc.var_spans, line_start);
        var matches = RangeCursor(Range).init(doc.matches, line_start);
        var underlines = RangeCursor(Underline).init(doc.underlines, line_start);
        var vti = firstVirtualAt(doc.virtual_text, line_start);

        // ── virtual lines: the rows above this line (a code lens) ──
        y = drawVirtualRows(ui, pane, area, doc, line, false, text_x, text_w, y);
        var words = RangeCursor(Range).init(doc.word_matches, line_start);
        // ── ui toggles ──
        const toggles = try lineToggles(ui, doc, line_text, cells, is_cursor_line, &rainbow_depth);
        // ── indent guides ── the indent this line is drawn with
        const guide_indent: u32 = if (guides) |g| g.indentOf(line) else 0;

        for (rows, 0..) |row, ri| {
            if (y >= area.bottom()) break;
            const row_rect = Rect.init(area.x, y, area.w, 1);
            ui.fill(row_rect, row_style);

            // The pointer anywhere on the line arms its fold chevron, as
            // it does in the Rust gutter — the affordance follows the
            // row, not the one cell.
            // Clamped before the cast: one minified line can wrap to more
            // rows than a u16 holds.
            const line_rect = Rect.init(area.x, y, area.w, @intCast(@min(rows.len, area.bottom() - y)));
            const picked: ?Sign = if (ri == 0 and gutter_w > 0) signFor(ui, doc, line, fold != null, ui.hovered(line_rect)) else null;

            // Gutter: the number on the line's first row, blank after.
            if (gutter_w > 0) {
                const gr = Rect.init(area.x, y, gutter_w, 1);
                const gstyle = if (is_cursor_line) Theme.onBg(Theme.withFg(t.gutter, t.fg.fg), row_style.bg) else t.gutter;
                if (ri == 0 and num_w > 0) {
                    if (doc.blame.len > 0) {
                        const label = if (line < doc.blame.len) doc.blame[line] else "";
                        _ = ui.putStr(area.x + 1, y, num_w, ui.clipStr(label, num_w), Theme.onBg(t.muted, row_style.bg));
                    } else {
                        // ── ui toggles ── relative numbers count from the cursor line
                        const shown: u32 = if (doc.relative_numbers and !is_cursor_line) (if (line > cursor_line) line - cursor_line else cursor_line - line) else line + 1;
                        const num = ui.fmt("{d}", .{shown});
                        _ = ui.putStrRight(area.x + 1 + num_w, y, num_w, num, gstyle);
                    }
                }
                // The change mark takes the gutter's last cell, the sign
                // its first; a one-cell gutter gives the cell to the sign.
                if (ri == 0) {
                    const sign: ?GutterMark = if (picked) |pk| pk.mark else null;
                    if (changeMarkAt(doc.gutter_marks, line)) |kind| if (sign == null or gutter_w > 1) {
                        const mark_glyph: []const u8 = if (ui.ascii) (switch (kind) {
                            .added => "+",
                            .modified => "~",
                            .deleted, .sign => "_",
                        }) else (switch (kind) {
                            .added, .modified => "▎",
                            .deleted, .sign => "▁",
                        });
                        _ = ui.putStr(area.x + gutter_w - 1, y, 1, mark_glyph, markStyle(t, kind, row_style));
                    };
                    if (picked) |pk| _ = ui.putStr(area.x, y, 1, pk.mark.glyph, Theme.onBg(pk.mark.style, row_style.bg));
                }
                ui.hit(gr, .{ .editor_cell = .{ .pane = pane, .line = line, .col = 0 } });
                ui.hit(gr, .{ .gutter = .{ .pane = pane, .line = line } });
                // Last, so the chevron's own cell wins the press the
                // gutter would otherwise take (`at` reads back to front).
                if (picked) |pk| if (pk.fold_arrow) ui.hit(Rect.init(area.x, y, 1, 1), .{ .fold_arrow = .{ .pane = pane, .line = line } });
            }

            // Cells. `abs_x` is the display column within the line (what
            // a block selection is measured in); `rel_x` the column within
            // this row, which is what lands on screen.
            var abs_x: u32 = 0;
            for (cells[0..row.start]) |p| abs_x += p.w;
            var rel_x: u32 = 0;
            var painted_x: u16 = text_x;
            const skip: u32 = if (ri == 0) view.scroll_col else 0;
            // Columns the row's virtual text has taken so far (lsp-more).
            var vx: u32 = 0;
            var i = row.start;
            while (i < row.end) : (i += 1) {
                const c = cells[i];
                // ── ui toggles ── a concealed markdown mark takes no cell
                if (toggles.hidden(i)) continue;
                const x = abs_x;
                const rx = rel_x;
                abs_x += c.w;
                rel_x += c.w;
                const off: usize = line_start + c.off;
                if (rx + c.w <= skip) {
                    while (vti < doc.virtual_text.len and doc.virtual_text[vti].byte <= off) vti += 1;
                    continue;
                }
                if (rx < skip) continue; // a wide glyph straddling the scroll edge
                var cx: u32 = rx - skip;
                // ── virtual text anchored on this grapheme ──
                while (vti < doc.virtual_text.len and doc.virtual_text[vti].byte <= off) : (vti += 1) {
                    const vt = doc.virtual_text[vti];
                    if (vt.byte < line_start) continue;
                    const at: u32 = cx + vx;
                    if (at >= text_w) break;
                    const vsx: u16 = text_x + @as(u16, @intCast(at));
                    const used = ui.putStr(vsx, y, text_w - @as(u16, @intCast(at)), vt.text, Theme.onBg(vt.style, row_style.bg));
                    ui.hit(Rect.init(vsx, y, used, 1), .{ .editor_cell = .{ .pane = pane, .line = line, .col = c.off } });
                    if (vt.hit) |id| ui.hit(Rect.init(vsx, y, used, 1), .{ .script_hit = .{ .pane = pane, .id = id } });
                    vx += used;
                }
                cx += vx;
                if (cx + c.w > text_w) break;
                const sx: u16 = text_x + @as(u16, @intCast(cx));

                var style: Style = row_style;
                // ── ui toggles ── the colour column sits under everything
                if (doc.color_column != 0 and cx + 1 == doc.color_column) style.bg = t.panel_bg.bg;
                if (spans.at(off)) |si| {
                    const s = doc.spans[si].style;
                    style.fg = s.fg;
                    style.bold = s.bold;
                    style.italic = s.italic;
                    style.dim = s.dim;
                    style.ul_style = s.ul_style;
                    style.strikethrough = s.strikethrough;
                    if (s.bg != .default) style.bg = s.bg;
                }
                // ── {{VAR}} hook ──
                var var_hit: ?u32 = null;
                if (var_spans.at(off)) |vi| {
                    const v = doc.var_spans[vi];
                    style.fg = if (v.resolved) t.syntax.variable.fg else t.error_fg.fg;
                    style.bold = true;
                    var_hit = var_hit_base + v.id;
                }
                // ── end {{VAR}} hook ──
                if (underlines.at(off)) |ui_idx| {
                    const u = doc.underlines[ui_idx].style;
                    style.ul = u.fg;
                    style.ul_style = if (u.ul_style == .off) .curly else u.ul_style;
                }
                if (matches.at(off)) |mi| {
                    const ms = if (doc.current_match == mi) t.current_match else t.match;
                    style.bg = ms.bg;
                    if (doc.current_match == mi) {
                        style.fg = ms.fg;
                        style.bold = ms.bold;
                    }
                }
                // A selected cell or an extra caret keeps its paint.
                var covered = false;
                if (sel) |s| {
                    const in_range = s.block == null and off >= s.lo and off < s.hi;
                    const in_block = if (s.block) |b| line >= b.l0 and line <= b.l1 and x >= b.c0 and (b.eol or x <= b.c1) else false;
                    if (in_range or in_block) {
                        style.bg = t.selection.bg;
                        covered = true;
                    }
                }
                for (doc.extra_cursors) |ec| if (ec == off) {
                    style.bg = t.fg.fg;
                    style.fg = t.bg.bg;
                    covered = true;
                };

                // ── ui toggles ── word matches, rainbow, todo words, whitespace, trailing ws, markdown
                var glyph: []const u8 = c.bytes;
                if (words.at(off)) |_| {
                    style.ul_style = .single;
                    style.bold = true;
                }
                if (doc.echo) |ec| if (off >= ec.start and off < ec.end) {
                    style.ul_style = .double;
                };
                if (toggles.styleAt(i)) |o| {
                    if (o.glyph) |g| glyph = g;
                    if (o.fg) |fg| style.fg = fg;
                    if (o.bg) |bg| style.bg = bg;
                    if (o.bold) style.bold = true;
                    if (o.italic) style.italic = true;
                    if (o.underline) style.ul_style = .single;
                    if (o.strike) style.strikethrough = true;
                }
                if (doc.show_whitespace and c.ws) {
                    const first_tab_cell = c.tab and (i == 0 or cells[i - 1].off != c.off);
                    glyph = if (c.tab) (if (first_tab_cell) (if (ui.ascii) ">" else "→") else " ") else (if (ui.ascii) "." else "·");
                    style.fg = t.whitespace.fg;
                }
                if (doc.highlight_trailing_ws and !is_cursor_line and c.ws and i >= toggles.trail_start) {
                    style.bg = t.error_fg.fg;
                }
                // ── indent guides ── in the leading white space, on the
                // line's first row, never over the selection
                if (guides) |g| if (ri == 0 and c.ws and !covered) if (g.at(doc.indent_guides, line, guide_indent, x)) |active| {
                    glyph = guide_glyph;
                    style.fg = (if (active) t.indent_guide_active else t.indent_guide).fg;
                };

                const cell_rect = Rect.init(sx, y, c.w, 1);
                while (label_i < doc.labels.len and doc.labels[label_i].byte < off) label_i += 1;
                if (label_i < doc.labels.len and doc.labels[label_i].byte == off) {
                    ui.canvas.put(sx, y, .{ .char = .{ .grapheme = doc.labels[label_i].text, .width = 1 }, .style = t.current_match });
                    if (c.w > 1) ui.canvas.put(sx + 1, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = t.current_match });
                } else ui.canvas.put(sx, y, .{ .char = .{ .grapheme = glyph, .width = c.w }, .style = style });
                ui.hit(cell_rect, .{ .editor_cell = .{ .pane = pane, .line = line, .col = c.off } });
                if (var_hit) |vh| ui.hit(cell_rect, .{ .script_hit = .{ .pane = pane, .id = vh } }); // {{VAR}} hook
                painted_x = sx + c.w;

                if (is_cursor_line and found == null and c.off == cursor_off and cursor_line_real == cursor_line) {
                    found = .{ .x = sx, .y = y };
                }
            }

            // The EOL cell and the space after it.
            const is_last_row = ri == rows.len - 1;
            if (is_last_row and painted_x < text_x + text_w) {
                const eol_off = line_end - line_start;
                // Where the text stopped, before anything painted after it.
                const text_end_x = painted_x;
                // ── virtual text at the line's end ──
                while (vti < doc.virtual_text.len and doc.virtual_text[vti].byte <= line_end) : (vti += 1) {
                    const vt = doc.virtual_text[vti];
                    if (vt.byte < line_start or painted_x >= text_x + text_w) continue;
                    const used = ui.putStr(painted_x, y, text_x + text_w - painted_x, vt.text, Theme.onBg(vt.style, row_style.bg));
                    ui.hit(Rect.init(painted_x, y, used, 1), .{ .editor_cell = .{ .pane = pane, .line = line, .col = eol_off } });
                    if (vt.hit) |id| ui.hit(Rect.init(painted_x, y, used, 1), .{ .script_hit = .{ .pane = pane, .id = id } });
                    painted_x += used;
                }
                if (painted_x >= text_x + text_w) {
                    // The virtual text filled the row: the cursor's cell
                    // is the last one, and there is no EOL space to hit.
                    if (is_cursor_line and found == null and cursor_line_real == cursor_line and cursor_off >= eol_off) found = .{ .x = text_x + text_w - 1, .y = y };
                    y += 1;
                    continue;
                }
                const eol_x = painted_x;
                var eol_style = row_style;
                var paint_eol = false;
                if (sel) |s| {
                    if (s.block) |b| {
                        // A ragged-right block ends with each line's text.
                        if (line >= b.l0 and line <= b.l1 and !b.eol) {
                            // Block cells past the end of the text.
                            var bx: u32 = abs_x;
                            while (bx <= b.c1 and bx -| skip < text_w) : (bx += 1) {
                                if (bx >= b.c0 and bx >= skip) {
                                    const px: u16 = text_x + @as(u16, @intCast(bx - skip));
                                    ui.canvas.put(px, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = Theme.onBg(row_style, t.selection.bg) });
                                }
                            }
                        }
                    } else if (s.hi > line_end and s.lo <= line_end) {
                        eol_style.bg = t.selection.bg;
                        paint_eol = true;
                    }
                }
                for (doc.extra_cursors) |ec| if (ec == line_end) {
                    eol_style.bg = t.fg.fg;
                    paint_eol = true;
                };
                if (paint_eol) ui.canvas.put(eol_x, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = eol_style });
                // ── ui toggles ── the colour column past the text
                if (doc.color_column != 0 and doc.color_column > skip) {
                    const ccx: u32 = doc.color_column - 1 - skip;
                    if (ccx < text_w and text_x + ccx >= eol_x) ui.canvas.put(text_x + @as(u16, @intCast(ccx)), y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = Theme.onBg(row_style, t.panel_bg.bg) });
                }
                // ── indent guides ── a blank line's guides run on past its
                // (white) text, where a block's lines above and below have
                // them; what the end-of-line text covers, it keeps
                if (guides) |g| if (ri == 0 and guide_indent > abs_x) {
                    var col: u32 = abs_x;
                    while (col < guide_indent) : (col += 1) {
                        const active = g.at(doc.indent_guides, line, guide_indent, col) orelse continue;
                        if (col < skip) continue;
                        const gx: u32 = if (abs_x >= skip) @as(u32, text_end_x) + (col - abs_x) else @as(u32, text_x) + (col - skip);
                        if (gx < painted_x or gx >= text_x + text_w) continue;
                        if (paint_eol and gx == eol_x) continue;
                        if (sel) |s| if (s.block) |b| if (line >= b.l0 and line <= b.l1 and col >= b.c0 and (b.eol or col <= b.c1)) continue;
                        const on_column = doc.color_column != 0 and gx - text_x + skip + 1 == doc.color_column;
                        const gs = Theme.onBg(if (active) t.indent_guide_active else t.indent_guide, if (on_column) t.panel_bg.bg else row_style.bg);
                        ui.canvas.put(@intCast(gx), y, .{ .char = .{ .grapheme = guide_glyph, .width = 1 }, .style = gs });
                    }
                };
                if (is_cursor_line and found == null and cursor_line_real == cursor_line and cursor_off >= eol_off) {
                    found = .{ .x = eol_x, .y = y };
                }
                if (fold) |f| {
                    const hidden = f.last_line - f.first_line;
                    // ── ui toggles ── the brackets inside the fold still nest
                    if (doc.bracket_rainbow) rainbow_depth = bracketDepthOver(doc.text, line_end, lines.end(f.last_line), rainbow_depth);
                    const marker = ui.fmt("{s}{d}{s}", .{ fold_word, hidden, foldTail(hidden) });
                    _ = ui.putStr(eol_x, y, text_x + text_w - eol_x, marker, Theme.onBg(t.fold, row_style.bg));
                    if (is_cursor_line and cursor_line_real != cursor_line) found = .{ .x = eol_x, .y = y };
                }
                ui.hit(Rect.init(eol_x, y, text_x + text_w - eol_x, 1), .{ .editor_cell = .{ .pane = pane, .line = line, .col = eol_off } });
            } else if (!is_last_row and painted_x < text_x + text_w) {
                // Space after a wrapped row maps to the next cell's byte.
                const next_off = if (row.end < cells.len) cells[row.end].off else line_end - line_start;
                ui.hit(Rect.init(painted_x, y, text_x + text_w - painted_x, 1), .{ .editor_cell = .{ .pane = pane, .line = line, .col = next_off } });
            }
            y += 1;
        }
        // ── virtual lines: the rows below this line ──
        y = drawVirtualRows(ui, pane, area, doc, line, true, text_x, text_w, y);
    }
    if (bar) scrollbar.drawVerticalLook(ui, Rect.init(area.right() - scrollbar_w, area.y, scrollbar_w, area.h), .{ .pane = pane }, total, text_h, view.scroll_line, .solid);
    if (!doc.focused) if (found) |c| paintAwayMark(ui, c);
    return found;
}

/// An editor pane that does not have focus: a dim mark on the cell its
/// caret is on.
///
/// The host terminal draws ONE cursor and it belongs to whatever has
/// the typing (`app/cursor.zig`), so without this the other half of a
/// split — or the buffer you left when you stepped into the tree —
/// loses its place entirely. A terminal emulator has the same problem
/// with a second pane and answers it by hollowing the cursor out;
/// `pty_view`'s `.dim` is that answer in cells, and this is the same
/// colour: the cursor's, half-way to the ground it sits on.
fn paintAwayMark(ui: Ui, at: Cursor) void {
    const cell = ui.canvas.screen.readCell(at.x, at.y) orelse return;
    const ground = cell.style.bg;
    const muted = blendOver(ui.theme.fg.fg, ground, 128, ui.theme.fg.fg);
    ui.canvas.put(at.x, at.y, .{ .char = cell.char, .style = .{ .fg = ground, .bg = muted } });
}

// ── ui toggles ──
// The per-line work behind `Doc`'s toggle fields: which cells vanish
// (markdown marks), which cells carry an extra style (a rainbow bracket,
// a TODO word, a heading), and where the trailing whitespace starts.
// Everything here is a pure function of one line's text and cells; the
// paint loop above asks it one cell at a time.

/// What a toggle adds to one cell over the syntax style.
pub const Override = struct {
    fg: ?vaxis.Color = null,
    bg: ?vaxis.Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    /// A replacement grapheme (a list bullet); the cell's byte stays.
    glyph: ?[]const u8 = null,
};

pub const LineToggles = struct {
    overrides: []?Override = &.{},
    hide: []bool = &.{},
    /// Index of the first trailing-whitespace cell; `cells.len` when none.
    trail_start: usize,

    pub fn hidden(self: LineToggles, i: usize) bool {
        return i < self.hide.len and self.hide[i];
    }

    pub fn styleAt(self: LineToggles, i: usize) ?Override {
        return if (i < self.overrides.len) self.overrides[i] else null;
    }
};

/// The nesting depth reached after the brackets in `text[from..to]`,
/// starting from `depth`. `()[]{}` only; a close below zero stays at zero.
pub fn bracketDepthOver(text: []const u8, from: usize, to: usize, depth: u32) u32 {
    var d = depth;
    const end = @min(to, text.len);
    var i = @min(from, end);
    while (i < end) : (i += 1) switch (text[i]) {
        '(', '[', '{' => d += 1,
        ')', ']', '}' => d -|= 1,
        else => {},
    };
    return d;
}

pub const rainbow_levels: usize = 3;

/// The colour of a bracket at nesting `depth` (1-based: the outermost
/// pair is 1).
pub fn rainbowColor(t: *const Theme, depth: u32) vaxis.Color {
    return switch ((depth -| 1) % rainbow_levels) {
        0 => t.syntax.keyword.fg,
        1 => t.syntax.function.fg,
        else => t.syntax.string.fg,
    };
}

pub const todo_words = [_][]const u8{ "TODO", "FIXME", "XXX", "HACK", "NOTE", "BUG" };
const comment_marks = [_][]const u8{ "//", "#", "--", "/*", "*", ";", "<!--" };

/// Byte offset of the first comment marker in `line`, if any.
fn commentStart(line: []const u8) ?usize {
    var best: ?usize = null;
    for (comment_marks) |m| if (std.mem.indexOf(u8, line, m)) |i| {
        if (best == null or i < best.?) best = i;
    };
    return best;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn needOverrides(ui: Ui, tg: *LineToggles, n: usize) Allocator.Error!void {
    if (tg.overrides.len != 0) return;
    const o = try ui.arena.alloc(?Override, n);
    @memset(o, null);
    tg.overrides = o;
}

fn needHide(ui: Ui, tg: *LineToggles, n: usize) Allocator.Error!void {
    if (tg.hide.len != 0) return;
    const h = try ui.arena.alloc(bool, n);
    @memset(h, false);
    tg.hide = h;
}

/// Merge `o` into every cell whose byte offset is in `[from, to)`.
fn styleRange(tg: *LineToggles, cells: []const CellInfo, from: usize, to: usize, o: Override) void {
    for (cells, 0..) |c, i| {
        if (c.off < from or c.off >= to) continue;
        var cur = tg.overrides[i] orelse Override{};
        if (o.fg) |fg| cur.fg = fg;
        if (o.bg) |bg| cur.bg = bg;
        if (o.glyph) |g| cur.glyph = g;
        cur.bold = cur.bold or o.bold;
        cur.italic = cur.italic or o.italic;
        cur.underline = cur.underline or o.underline;
        cur.strike = cur.strike or o.strike;
        tg.overrides[i] = cur;
    }
}

fn hideRange(tg: *LineToggles, cells: []const CellInfo, from: usize, to: usize) void {
    for (cells, 0..) |c, i| if (c.off >= from and c.off < to) {
        tg.hide[i] = true;
    };
}

/// The toggles' verdict on one line. `depth` is the bracket depth at the
/// line's start and is advanced past the line.
pub fn lineToggles(ui: Ui, doc: Doc, line: []const u8, cells: []const CellInfo, is_cursor_line: bool, depth: *u32) Allocator.Error!LineToggles {
    const t = ui.theme;
    var tg: LineToggles = .{ .trail_start = cells.len };
    if (doc.highlight_trailing_ws) {
        var i = cells.len;
        while (i > 0 and cells[i - 1].ws) i -= 1;
        tg.trail_start = i;
    }
    if (doc.bracket_rainbow) {
        try needOverrides(ui, &tg, cells.len);
        for (cells, 0..) |c, i| {
            if (c.bytes.len != 1) continue;
            switch (c.bytes[0]) {
                '(', '[', '{' => {
                    depth.* += 1;
                    tg.overrides[i] = .{ .fg = rainbowColor(t, depth.*) };
                },
                ')', ']', '}' => {
                    tg.overrides[i] = .{ .fg = rainbowColor(t, depth.*) };
                    depth.* -|= 1;
                },
                else => {},
            }
        }
    }
    if (doc.todo_keywords) if (commentStart(line)) |cs| {
        var i = cs;
        while (i < line.len) {
            if (i > 0 and isWordByte(line[i - 1])) {
                i += 1;
                continue;
            }
            var hit: ?usize = null;
            for (todo_words) |w| if (std.mem.startsWith(u8, line[i..], w) and (i + w.len == line.len or !isWordByte(line[i + w.len]))) {
                hit = w.len;
                break;
            };
            if (hit) |n| {
                try needOverrides(ui, &tg, cells.len);
                const urgent = std.mem.startsWith(u8, line[i..], "FIXME") or std.mem.startsWith(u8, line[i..], "BUG");
                styleRange(&tg, cells, i, i + n, .{ .fg = if (urgent) t.error_fg.fg else t.warn_fg.fg, .bold = true });
                i += n;
            } else i += 1;
        }
    };
    if (doc.render_markdown and !is_cursor_line) try concealMarkdown(ui, &tg, line, cells);
    return tg;
}

fn headingColor(t: *const Theme, level: usize) vaxis.Color {
    return switch (level) {
        1 => t.syntax.function.fg,
        2 => t.syntax.escape.fg,
        3 => t.syntax.string.fg,
        4 => t.syntax.type.fg,
        else => t.syntax.keyword.fg,
    };
}

/// `render_markdown`: the marks are hidden and the text between them
/// styled, on a line the cursor is not on (the cursor line stays raw so
/// it can be edited by eye). The grammar is the preview's (`md_view`).
fn concealMarkdown(ui: Ui, tg: *LineToggles, line: []const u8, cells: []const CellInfo) Allocator.Error!void {
    const t = ui.theme;
    try needOverrides(ui, tg, cells.len);
    try needHide(ui, tg, cells.len);
    const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
    const trimmed = line[lead..];
    var body_from: usize = lead;
    // A fence line: the marks go, a language name stays muted.
    if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
        hideRange(tg, cells, lead, lead + 3);
        styleRange(tg, cells, lead + 3, line.len, .{ .fg = t.muted.fg, .italic = true });
        return;
    }
    // Heading: `## ` hidden, the rest bold in the level's colour.
    if (trimmed.len > 0 and trimmed[0] == '#') {
        var level: usize = 0;
        while (level < trimmed.len and trimmed[level] == '#' and level < 6) level += 1;
        if (level < trimmed.len and trimmed[level] == ' ') {
            hideRange(tg, cells, lead, lead + level + 1);
            styleRange(tg, cells, lead + level + 1, line.len, .{ .fg = headingColor(t, level), .bold = true, .underline = level <= 2 });
            body_from = lead + level + 1;
        }
    } else if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        // A list marker becomes a bullet; a task box its glyph.
        styleRange(tg, cells, lead, lead + 1, .{ .fg = t.accent.fg, .glyph = if (ui.ascii) "*" else "•" });
        body_from = lead + 2;
        const rest = trimmed[2..];
        if (std.mem.startsWith(u8, rest, "[ ] ") or std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ")) {
            const done = rest[1] != ' ';
            hideRange(tg, cells, body_from + 1, body_from + 3);
            styleRange(tg, cells, body_from, body_from + 1, .{ .fg = t.accent.fg, .glyph = if (ui.ascii) (if (done) "x" else "_") else (if (done) "☑" else "☐") });
            body_from += 4;
        }
    } else if (trimmed.len >= 1 and trimmed[0] == '>') {
        styleRange(tg, cells, lead, lead + 1, .{ .fg = t.syntax.keyword.fg, .glyph = if (ui.ascii) "|" else "▏" });
        styleRange(tg, cells, lead + 1, line.len, .{ .fg = t.muted.fg, .italic = true });
        body_from = lead + 1;
    }
    // Inline marks.
    var i = body_from;
    while (i < line.len) {
        const rest = line[i..];
        if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "~~")) {
            const mark = rest[0..2];
            if (std.mem.indexOf(u8, rest[2..], mark)) |end| if (end > 0) {
                hideRange(tg, cells, i, i + 2);
                hideRange(tg, cells, i + 2 + end, i + 2 + end + 2);
                styleRange(tg, cells, i + 2, i + 2 + end, if (mark[0] == '*') .{ .bold = true } else .{ .strike = true });
                i += 2 + end + 2;
                continue;
            };
        }
        if (rest[0] == '`') {
            if (std.mem.indexOfScalar(u8, rest[1..], '`')) |end| if (end > 0) {
                hideRange(tg, cells, i, i + 1);
                hideRange(tg, cells, i + 1 + end, i + 1 + end + 1);
                styleRange(tg, cells, i + 1, i + 1 + end, .{ .fg = t.syntax.string.fg, .bg = t.panel_bg.bg });
                i += 1 + end + 1;
                continue;
            };
        }
        if ((rest[0] == '*' or rest[0] == '_') and rest.len > 1 and rest[1] != ' ' and rest[1] != rest[0]) {
            if (std.mem.indexOfScalar(u8, rest[1..], rest[0])) |end| if (end > 0 and rest[end] != ' ') {
                hideRange(tg, cells, i, i + 1);
                hideRange(tg, cells, i + 1 + end, i + 1 + end + 1);
                styleRange(tg, cells, i + 1, i + 1 + end, .{ .italic = true });
                i += 1 + end + 1;
                continue;
            };
        }
        if (rest[0] == '[' or std.mem.startsWith(u8, rest, "![")) {
            const at = if (rest[0] == '!') i + 1 else i;
            if (linkAt(line, at)) |lk| {
                // `[label](url)` → the label alone; `![alt](src)` → the alt, muted.
                hideRange(tg, cells, i, at + 1);
                hideRange(tg, cells, lk.label_end, lk.end);
                if (rest[0] == '!') {
                    styleRange(tg, cells, at + 1, lk.label_end, .{ .fg = t.muted.fg, .italic = true });
                } else {
                    styleRange(tg, cells, at + 1, lk.label_end, .{ .fg = t.accent.fg, .underline = true });
                }
                i = lk.end;
                continue;
            }
        }
        i += 1;
    }
}

const LinkAt = struct { label_end: usize, end: usize };

/// `[label](url)` starting at `at` in `line`: where the label ends and
/// where the whole link ends.
fn linkAt(line: []const u8, at: usize) ?LinkAt {
    const s = line[at..];
    if (s.len < 4 or s[0] != '[') return null;
    const rb = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (rb + 1 >= s.len or s[rb + 1] != '(') return null;
    const rp = std.mem.indexOfScalarPos(u8, s, rb + 2, ')') orelse return null;
    return .{ .label_end = at + rb, .end = at + rp + 1 };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn mkDoc(text: []const u8) Doc {
    return .{ .text = text, .cursor = 0, .anchor = null, .wrap = false, .tab_width = 4, .focused = true };
}

test "lines index" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const l = try Lines.build(arena.allocator(), "ab\ncd\n\nlast");
    try testing.expectEqual(@as(u32, 4), l.count());
    try testing.expectEqualStrings("cd", l.slice("ab\ncd\n\nlast", 1));
    try testing.expectEqualStrings("", l.slice("ab\ncd\n\nlast", 2));
    try testing.expectEqualStrings("last", l.slice("ab\ncd\n\nlast", 3));
    try testing.expectEqual(@as(u32, 0), l.lineOf(2));
    try testing.expectEqual(@as(u32, 1), l.lineOf(3));
    try testing.expectEqual(@as(u32, 3), l.lineOf(99));
    const e = try Lines.build(arena.allocator(), "");
    try testing.expectEqual(@as(u32, 1), e.count());
    try testing.expectEqual(@as(u32, 0), e.end(0));
}

test "a borrowed line index answers as the built one does, and a frame drawn over it walks no text for one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "ab\ncd\n\nlast", "", "\n", "one\n", "a\n\n" }) |text| {
        const built = try Lines.build(arena.allocator(), text);
        const ix = try arena.allocator().alloc(usize, built.starts.len);
        for (built.starts, 0..) |v, i| ix[i] = v;
        const borrowed = Lines.from(ix, text.len);
        try testing.expectEqual(built.count(), borrowed.count());
        var line: u32 = 0;
        while (line < built.count()) : (line += 1) {
            try testing.expectEqual(built.start(line), borrowed.start(line));
            try testing.expectEqual(built.end(line), borrowed.end(line));
        }
        for (0..text.len + 2) |off| try testing.expectEqual(built.lineOf(off), borrowed.lineOf(off));
    }
    // The same frame, either way — and only the one without an index
    // walks the text.
    var f = try Fixture.init(20, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a\nb\nc\n");
    const before = line_index_bytes_scanned;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(line_index_bytes_scanned > before);
    try f.expectRows(&.{ "   1 a", "   2 b", "   3 c" });
    d.line_starts = &.{ 0, 2, 4, 6 };
    const mid = line_index_bytes_scanned;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expectEqual(mid, line_index_bytes_scanned);
    try f.expectRows(&.{ "   1 a", "   2 b", "   3 c" });
}

test "gutter width follows the line count with a 3-digit floor" {
    var f = try Fixture.init(20, 3);
    defer f.deinit();
    var view: ViewState = .{};
    _ = draw(f.ui(), 0, f.full(), &view, mkDoc("a\nb\nc"));
    try f.expectRows(&.{ "   1 a", "   2 b", "   3 c" });
    // Line numbers off: no gutter at all.
    var d = mkDoc("a\nb");
    d.line_numbers = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "a", "b" });
    try testing.expectEqual(@as(u16, 6), gutterWidth(mkDoc(""), 1234));
    try testing.expectEqual(@as(u16, 5), gutterWidth(mkDoc(""), 999));
}

test "tabs expand to the next stop and hits carry the tab's byte offset" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a\tb\tc");
    d.line_numbers = false;
    _ = draw(f.ui(), 7, f.full(), &view, d);
    try f.expectRow(0, "a   b   c");
    // Cells 1..3 are the tab at byte 1; cell 4 is `b` at byte 2.
    try testing.expectEqual(@as(u32, 1), f.hits.at(2, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 2), f.hits.at(4, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 7), f.hits.at(4, 0).?.editor_cell.pane);
    // Past the end: the line length.
    try testing.expectEqual(@as(u32, 5), f.hits.at(15, 0).?.editor_cell.col);
}

test "wide glyphs take two cells and one hit each" {
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("漢a字");
    d.line_numbers = false;
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "漢a字");
    try testing.expectEqual(@as(u32, 0), f.hits.at(0, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 0), f.hits.at(1, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 3), f.hits.at(2, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 4), f.hits.at(3, 0).?.editor_cell.col);
    try testing.expectEqual(Cursor{ .x = 0, .y = 0 }, cur.?);
}

test "selection paints a byte range, including the EOL cell across lines" {
    var f = try Fixture.init(12, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abc\ndef\nghi");
    d.line_numbers = false;
    d.anchor = 1;
    d.cursor = 6; // "bc\nde"
    _ = draw(f.ui(), 0, f.full(), &view, d);
    const sel = f.theme.selection;
    try testing.expect(!f.bgEql(0, 0, sel));
    try testing.expect(f.bgEql(1, 0, sel));
    try testing.expect(f.bgEql(2, 0, sel));
    try testing.expect(f.bgEql(3, 0, sel)); // the EOL cell of line 0
    try testing.expect(f.bgEql(0, 1, sel));
    try testing.expect(f.bgEql(1, 1, sel));
    try testing.expect(!f.bgEql(2, 1, sel));
    try testing.expect(!f.bgEql(0, 2, sel));
}

test "indent guides: a rule at every step of the leading white space, the cursor's scope brighter, a blank line's run past its end" {
    var f = try Fixture.init(24, 6);
    defer f.deinit();
    var view: ViewState = .{};
    // The cursor on `y();`: the if's body is the scope, its guide at 4.
    var d = mkDoc("fn a() {\n    if x {\n        y();\n\n        z();\n    }");
    d.line_numbers = false;
    d.cursor_line_band = false;
    d.cursor = 22;
    d.indent_guides = .on;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "fn a() {", "│   if x {", "│   │   y();", "│   │", "│   │   z();", "│   }" });
    const plain = f.theme.indent_guide;
    const active = f.theme.indent_guide_active;
    try testing.expect(f.fgEql(0, 2, plain));
    try testing.expect(f.fgEql(4, 2, active));
    // The blank line between y and z: past its (empty) text, the same pair.
    try testing.expect(f.fgEql(0, 3, plain));
    try testing.expect(f.fgEql(4, 3, active));
    try testing.expect(f.fgEql(0, 1, plain));
    // `.active` paints the one guide and no other.
    d.indent_guides = .active;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "fn a() {", "    if x {", "    │   y();", "    │", "    │   z();", "    }" });
    // `.off` paints none.
    d.indent_guides = .off;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(2, "        y();");
    // ASCII draws the rule's ASCII twin.
    f.ascii = true;
    d.indent_guides = .on;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(2, "|   |   y();");
}

test "indent guides step by the buffer's indent, and stay off a selection and a wrapped row's continuation" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a:\n  b:\n    c: 1");
    d.line_numbers = false;
    d.indent_guides = .on;
    d.indent_step = 2;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "a:", "│ b:", "│ │ c: 1" });
    // A selection over the third line's indent keeps its own paint.
    d.anchor = 8; // the start of `    c: 1`
    d.cursor = 12;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(2, "    c: 1");
    try testing.expect(f.bgEql(0, 2, f.theme.selection));
    // Wrapped: the continuation of an indented line gets no guide, even
    // where it starts with white space of its own.
    var w = try Fixture.init(10, 4);
    defer w.deinit();
    var wv: ViewState = .{};
    var wd = mkDoc("x\n    aaaa bbbb   cc");
    wd.line_numbers = false;
    wd.indent_guides = .on;
    wd.wrap = true;
    _ = draw(w.ui(), 0, w.full(), &wv, wd);
    try w.expectRow(1, "│   aaaa");
    var buf: [64]u8 = undefined;
    const second = w.row(2, &buf);
    try testing.expect(std.mem.indexOf(u8, second, "│") == null);
}

test "a trailing newline opens no phantom line; a cursor at EOF keeps it" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab\ncd\n");
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "   1 ab");
    try f.expectRow(1, "   2 cd");
    try f.expectRow(2, "");
    // A cursor parked at EOF (modeless Ctrl+End) needs its row.
    d.cursor = 6;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(2, "   3");
    // No trailing newline: the last line is a real one.
    d = mkDoc("ab\ncd");
    d.cursor = 5;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(1, "   2 cd");
    try f.expectRow(2, "");
}

test "visual block paints a rectangle in display columns, over EOL too" {
    var f = try Fixture.init(12, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abcdef\nab\nabcdef");
    d.line_numbers = false;
    d.anchor = 2; // line 0 col 2
    d.cursor = 14; // line 2 col 4
    d.visual_block = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    const sel = f.theme.selection;
    for (0..3) |yy| {
        const y: u16 = @intCast(yy);
        try testing.expect(!f.bgEql(1, y, sel));
        try testing.expect(f.bgEql(2, y, sel));
        try testing.expect(f.bgEql(4, y, sel));
        try testing.expect(!f.bgEql(5, y, sel));
    }
    try f.expectRow(1, "ab");
}

test "a ragged-right block ($) paints to each line's end and no further" {
    var f = try Fixture.init(12, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abcdef\nab\nabcd");
    d.line_numbers = false;
    d.anchor = 2; // line 0 col 2
    d.cursor = 13; // line 2 col 3 (its last char)
    d.visual_block = true;
    d.block_eol = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    const sel = f.theme.selection;
    try testing.expect(!f.bgEql(1, 0, sel));
    try testing.expect(f.bgEql(2, 0, sel));
    try testing.expect(f.bgEql(5, 0, sel));
    try testing.expect(!f.bgEql(6, 0, sel));
    try testing.expect(!f.bgEql(2, 1, sel)); // the short row has no cell there
    try testing.expect(f.bgEql(3, 2, sel));
    try testing.expect(!f.bgEql(4, 2, sel));
}

test "extra cursors are painted as inverted cells" {
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abc\ndef");
    d.line_numbers = false;
    d.extra_cursors = &.{ 5, 3 }; // `e`, and the EOL of line 0
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(vaxis.Color.eql(f.style(1, 1).bg, f.theme.fg.fg));
    try testing.expect(vaxis.Color.eql(f.style(3, 0).bg, f.theme.fg.fg));
    try testing.expect(!vaxis.Color.eql(f.style(0, 1).bg, f.theme.fg.fg));
}

test "find matches use match / current_match and spans give the fg" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("alpha beta alpha");
    d.line_numbers = false;
    d.matches = &.{ .{ .start = 0, .end = 5 }, .{ .start = 11, .end = 16 } };
    d.current_match = 1;
    const red: Style = .{ .fg = Theme.onedark.red, .bold = true };
    d.spans = &.{.{ .start = 6, .end = 10, .style = red }};
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.bgEql(0, 0, f.theme.match));
    try testing.expect(f.bgEql(4, 0, f.theme.match));
    try testing.expect(!f.bgEql(5, 0, f.theme.match));
    try testing.expect(f.bgEql(11, 0, f.theme.current_match));
    try testing.expect(f.fgEql(11, 0, f.theme.current_match));
    try testing.expect(vaxis.Color.eql(f.style(6, 0).fg, Theme.onedark.red));
    try testing.expect(f.style(6, 0).bold);
    try testing.expect(!f.style(5, 0).bold);
}

test "the cursor line gets its band across the whole row" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab\ncd");
    d.cursor = 4;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.bgEql(0, 1, f.theme.cursor_line));
    try testing.expect(f.bgEql(9, 1, f.theme.cursor_line));
    try testing.expect(f.bgEql(9, 0, f.theme.bg));
}

test "a fold collapses to one row naming folded and hidden, in both glyph sets" {
    var f = try Fixture.init(50, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn main() {\n    one;\n    two;\n    three;\n}\nlet end = 1;");
    d.folds = &.{.{ .first_line = 0, .last_line = 4 }};
    d.cursor = 21; // inside the fold body
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    // // changed (fold-gutter): the folded line wears its chevron.
    try f.expectRow(0, "\u{25B6}  1 fn main() { ⋯ folded · 4 lines hidden");
    try f.expectRow(1, "   6 let end = 1;");
    try f.expectLacks("two;");
    try f.expectContains("folded");
    try f.expectContains("hidden");
    try testing.expectEqual(Cursor{ .x = 16, .y = 0 }, cur.?);
    try testing.expect(f.fgEql(18, 0, f.theme.fold));

    f.ascii = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, ">  1 fn main() { ... folded - 4 lines hidden");
}

test "vertical scrolling keeps the cursor row on screen, both ways" {
    var f = try Fixture.init(10, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a\nb\nc\nd\ne\nf");
    d.line_numbers = false;
    d.cursor = 8; // line 4 `e`
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "c", "d", "e" });
    try testing.expectEqual(@as(u32, 2), view.scroll_line);
    try testing.expectEqual(Cursor{ .x = 0, .y = 2 }, cur.?);
    d.cursor = 0;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "a", "b", "c" });
    try testing.expectEqual(@as(u32, 0), view.scroll_line);
    // A scroll past the tail is pulled back so no rows sit blank.
    view.scroll_line = 5;
    d.cursor = 10;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "d", "e", "f" });
}

test "vertical scrolling counts folded lines as one row" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a\nb\nc\nd\ne");
    d.line_numbers = false;
    d.folds = &.{.{ .first_line = 1, .last_line = 3 }};
    d.cursor = 8; // `e`, line 4
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expectEqual(@as(u32, 1), view.scroll_line);
    try f.expectContains("folded");
    try f.expectRow(1, "e");
}

test "horizontal scrolling follows the cursor when not wrapping" {
    var f = try Fixture.init(5, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abcdefghij");
    d.line_numbers = false;
    d.cursor = 7;
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "defgh");
    try testing.expectEqual(@as(u32, 3), view.scroll_col);
    try testing.expectEqual(Cursor{ .x = 4, .y = 0 }, cur.?);
    try testing.expectEqual(@as(u32, 5), f.hits.at(2, 0).?.editor_cell.col);
    d.cursor = 1;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "bcdef");
    try testing.expectEqual(@as(u32, 1), view.scroll_col);
}

test "wrap breaks after spaces, keeps the cursor row visible and clears scroll_col" {
    var f = try Fixture.init(7, 2);
    defer f.deinit();
    var view: ViewState = .{ .scroll_col = 3 };
    var d = mkDoc("AAA BBB CCC DDD");
    d.line_numbers = false;
    d.wrap = true;
    d.cursor = 13; // on `DDD`, visual row 3
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expectEqual(@as(u32, 0), view.scroll_col);
    try testing.expect(cur != null);
    try f.expectContains("DDD");
    // Scrolling is line-based; the long line still starts at its top.
    try testing.expectEqual(@as(u32, 0), view.scroll_line);

    var g = try Fixture.init(7, 4);
    defer g.deinit();
    var v2: ViewState = .{};
    d.cursor = 0;
    _ = draw(g.ui(), 0, g.full(), &v2, d);
    try g.expectRows(&.{ "AAA BBB", "CCC DDD" });
    try testing.expectEqual(@as(u32, 8), g.hits.at(0, 1).?.editor_cell.col);
}

test "one line that wraps to more rows than a u16 holds draws its top rows" {
    // A minified bundle: a single line far past 65,535 visual rows.
    const text = try testing.allocator.alloc(u8, 300_000);
    defer testing.allocator.free(text);
    @memset(text, 'a');
    var f = try Fixture.init(3, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc(text);
    d.line_numbers = false;
    d.wrap = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "aaa", "aaa" });
}

test "the gate's wrap case: the tail is clipped without wrap and shown with it" {
    var f = try Fixture.init(30, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("AAA BBB CCC DDD EEE FFF GGG HHH III JJJ KKK LLL MMM NNN OOO PPP QQQ RRR SSS TTT UUU VVV WWW XXX YYY ZZZ");
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectContains("AAA BBB");
    try f.expectLacks("ZZZ");
    d.wrap = true;
    var g = try Fixture.init(30, 6);
    defer g.deinit();
    _ = draw(g.ui(), 0, g.full(), &view, d);
    try g.expectContains("AAA BBB");
    try g.expectContains("ZZZ");
}

test "an empty document paints one numbered row and puts the cursor at its start" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    var view: ViewState = .{};
    const cur = draw(f.ui(), 0, f.full(), &view, mkDoc(""));
    try f.expectRows(&.{ "   1", "" });
    try testing.expectEqual(Cursor{ .x = 5, .y = 0 }, cur.?);
    try testing.expectEqual(@as(u32, 0), f.hits.at(7, 0).?.editor_cell.col);
}

test "virtual text paints before its grapheme, takes no bytes, and its cells hit the anchor byte" {
    var f = try Fixture.init(24, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("let x = f(a)");
    d.line_numbers = false;
    d.cursor = 8; // `f`
    // A type hint after `x` (byte 5 is the space) and a parameter hint before `a`.
    d.virtual_text = &.{ .{ .byte = 5, .text = ": u32", .style = .{ .dim = true } }, .{ .byte = 10, .text = "n:", .style = .{} } };
    const cur = draw(f.ui(), 3, f.full(), &view, d);
    try f.expectRow(0, "let x: u32 = f(n:a)");
    // The hint's cells land on the byte they sit before; the text after
    // it keeps its own offsets.
    try testing.expectEqual(@as(u32, 5), f.hits.at(6, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 5), f.hits.at(10, 0).?.editor_cell.col);
    try testing.expectEqual(@as(u32, 8), f.hits.at(13, 0).?.editor_cell.col); // `f`
    try testing.expectEqual(@as(u32, 10), f.hits.at(15, 0).?.editor_cell.col); // `n:` → a
    try testing.expectEqual(@as(u32, 10), f.hits.at(17, 0).?.editor_cell.col); // a
    // The cursor sits on `f`, shifted right by the hint's width.
    try testing.expectEqual(Cursor{ .x = 13, .y = 0 }, cur.?);
    try testing.expect(f.style(6, 0).dim);
    try testing.expect(!f.style(13, 0).dim);
    // A hint at the line's end paints after the text.
    d.virtual_text = &.{.{ .byte = 12, .text = " → u32", .style = .{} }};
    _ = draw(f.ui(), 3, f.full(), &view, d);
    try f.expectRow(0, "let x = f(a) → u32");
    try testing.expectEqual(@as(u32, 12), f.hits.at(14, 0).?.editor_cell.col);
}

test "a virtual line paints above its line, counts in the scroll math, and its segments register script hits" {
    var f = try Fixture.init(30, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {}\nfn b() {}\nfn c() {}");
    d.line_numbers = false;
    d.virtual_lines = &.{.{ .line = 1, .segments = &.{ .{ .text = "3 references", .style = .{}, .hit = 7 }, .{ .text = "▶ run", .style = .{}, .hit = 8 } } }};
    d.cursor = 10; // line 1
    const cur = draw(f.ui(), 5, f.full(), &view, d);
    try f.expectRows(&.{ "fn a() {}", "3 references  ▶ run", "fn b() {}" });
    try testing.expectEqual(Cursor{ .x = 0, .y = 2 }, cur.?);
    try testing.expectEqual(@as(u32, 7), f.hits.at(2, 1).?.script_hit.id);
    try testing.expectEqual(@as(u32, 8), f.hits.at(15, 1).?.script_hit.id);
    try testing.expectEqual(@as(u32, 5), f.hits.at(15, 1).?.script_hit.pane);
    // Three text rows into two: the lens row costs one, so the cursor
    // on line 2 scrolls line 0 away and keeps the lens above line 1.
    var g = try Fixture.init(30, 3);
    defer g.deinit();
    d.cursor = 20; // line 2
    _ = draw(g.ui(), 5, g.full(), &view, d);
    try g.expectRows(&.{ "3 references  ▶ run", "fn b() {}", "fn c() {}" });
    try testing.expectEqual(@as(u32, 1), view.scroll_line);
}

test "a virtual line below its line paints after it, counts in the scroll math, and the cursor never lands on it" {
    var f = try Fixture.init(30, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {}\nfn b() {}\nfn c() {}");
    d.line_numbers = false;
    d.virtual_lines = &.{.{ .line = 0, .segments = &.{.{ .text = "  chris · 3d ago", .style = .{} }}, .below = true }};
    d.cursor = 0;
    const cur = draw(f.ui(), 5, f.full(), &view, d);
    try f.expectRows(&.{ "fn a() {}", "  chris · 3d ago", "fn b() {}" });
    // The cursor is on line 0's own row, not on the virtual one.
    try testing.expectEqual(Cursor{ .x = 0, .y = 0 }, cur.?);
    // The row costs one: with the cursor on line 2 the top scrolls away.
    d.cursor = 20;
    _ = draw(f.ui(), 5, f.full(), &view, d);
    try testing.expectEqual(@as(u32, 1), view.scroll_line);
    try f.expectRows(&.{ "fn b() {}", "fn c() {}", "" });
}

test "a line ground paints the whole row, and the cursor line's band still wins" {
    var f = try Fixture.init(10, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab\ncd\nef");
    d.cursor = 0;
    d.line_grounds = &.{ .{ .line = 1, .style = .{ .bg = f.theme.match.bg } }, .{ .line = 0, .style = .{ .bg = f.theme.selection.bg } } };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    // Line 1 wears its ground across the row…
    try testing.expect(f.bgEql(0, 1, f.theme.match));
    try testing.expect(f.bgEql(9, 1, f.theme.match));
    // …line 0 is the cursor line, so its band wins over the ground…
    try testing.expect(f.bgEql(9, 0, f.theme.cursor_line));
    // …and a line with no ground is plain.
    try testing.expect(f.bgEql(9, 2, f.theme.bg));
}

test "a folded line wears the gutter's chevron above a diagnostic and a git bar, below the debugger's signs" {
    var f = try Fixture.init(14, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {\nbody\n}\nafter");
    d.folds = &.{.{ .first_line = 0, .last_line = 2 }};
    // Line 0 also carries a diagnostic dot and a git bar: the fold
    // outranks both, and both still paint where they can (the bar has
    // its own column).
    d.gutter_marks = &.{
        .{ .line = 0, .kind = .sign, .glyph = "D", .style = .{}, .priority = mark_priority.diagnostic },
        .{ .line = 0, .kind = .modified, .glyph = "", .style = .{}, .priority = mark_priority.git_change },
    };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "\u{25B6}  1▎fn a() {");
    try testing.expect(f.fgEql(0, 0, .{ .fg = f.theme.fold.fg }));

    // A breakpoint is above it: the debugger keeps the cell.
    d.gutter_marks = &.{.{ .line = 0, .kind = .sign, .glyph = "B", .style = .{}, .priority = mark_priority.breakpoint }};
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "B  1 fn a() {");
}

test "a foldable line wears the open chevron only while the pointer is on it, and only when it starts a fold" {
    var f = try Fixture.init(14, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {\nbody\n}\nafter");
    const Rule = struct {
        fn startsFold(_: *const anyopaque, line: u32) bool {
            return line == 0;
        }
    };
    d.foldable = .{ .ctx = &d, .startsFold = &Rule.startsFold };

    // Pointer away: the sign cell is blank.
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "   1 fn a() {");

    // Anywhere on the line arms it, and it takes the comment grey.
    f.hover = .{ .x = 9, .y = 0 };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "\u{25BC}  1 fn a() {");
    try testing.expect(f.fgEql(0, 0, .{ .fg = f.theme.muted.fg }));

    // A line the rule refuses gets nothing, hovered or not.
    f.hover = .{ .x = 9, .y = 1 };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(1, "   2 body");

    // And a diagnostic outranks a mere hover — the dot is the one that
    // matters while the pointer drifts over its line.
    f.hover = .{ .x = 9, .y = 0 };
    d.gutter_marks = &.{.{ .line = 0, .kind = .sign, .glyph = "D", .style = .{}, .priority = mark_priority.diagnostic }};
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "D  1 fn a() {");
}

test "ui.always_show_fold_arrows wears the offer on every foldable line, pointer or not" {
    var f = try Fixture.init(14, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {\nbody\n}\nafter");
    const Rule = struct {
        fn startsFold(_: *const anyopaque, line: u32) bool {
            return line == 0;
        }
    };
    d.foldable = .{ .ctx = &d, .startsFold = &Rule.startsFold };

    // Off by default: no pointer, no chevron.
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "   1 fn a() {");

    // On: the foldable line wears it with the pointer nowhere near, in
    // the same muted grey, and its cell is a click target all the same.
    d.always_show_fold_arrows = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "\u{25BC}  1 fn a() {");
    try testing.expect(f.fgEql(0, 0, .{ .fg = f.theme.muted.fg }));
    try testing.expect(f.hits.at(0, 0).? == .fold_arrow);
    // A line the rule refuses still gets nothing.
    try f.expectRow(1, "   2 body");
}

test "the fold chevrons follow ui.expand_indicator and --ascii" {
    const Rule = struct {
        fn startsFold(_: *const anyopaque, _: u32) bool {
            return true;
        }
    };
    // closed (folded) / open (foldable, hovered), per glyph set.
    for ([_][2][]const u8{
        .{ "\u{25B6}", "\u{25BC}" },
        .{ "\u{25B8}", "\u{25BE}" },
        .{ ">", "v" },
    }, 0..) |want, set| {
        var f = try Fixture.init(14, 4);
        defer f.deinit();
        f.triangle = set == 1;
        f.ascii = set == 2;
        var view: ViewState = .{};
        var d = mkDoc("fn a() {\nbody\n}\nafter");
        d.foldable = .{ .ctx = &d, .startsFold = &Rule.startsFold };
        d.folds = &.{.{ .first_line = 0, .last_line = 2 }};
        _ = draw(f.ui(), 0, f.full(), &view, d);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(want[0], f.row(0, &buf)[0..want[0].len]);

        d.folds = &.{};
        f.hover = .{ .x = 9, .y = 0 };
        _ = draw(f.ui(), 0, f.full(), &view, d);
        try testing.expectEqualStrings(want[1], f.row(0, &buf)[0..want[1].len]);
    }
}

test "the chevron's own cell is a fold_arrow hit, registered over the gutter's" {
    var f = try Fixture.init(14, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("fn a() {\nbody\n}\nafter");
    d.folds = &.{.{ .first_line = 0, .last_line = 2 }};
    _ = draw(f.ui(), 0, f.full(), &view, d);
    // The one cell is the fold's; the rest of the gutter stays the
    // gutter's, so a press on the numbers still selects the line.
    try testing.expect(f.hits.at(0, 0).? == .fold_arrow);
    try testing.expectEqual(@as(u32, 0), f.hits.at(0, 0).?.fold_arrow.line);
    try testing.expect(f.hits.at(2, 0).? == .gutter);
    // A line with no chevron registers none.
    try testing.expect(f.hits.at(0, 1).? == .gutter);
}

test "the gutter paints the highest-priority sign on a line" {
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab\ncd");
    d.cursor = 0;
    // The app hands the list sorted by priority; the view paints the
    // first sign it finds for the line.
    d.gutter_marks = &.{
        .{ .line = 0, .kind = .sign, .glyph = "B", .style = .{}, .priority = mark_priority.breakpoint },
        .{ .line = 0, .kind = .sign, .glyph = "S", .style = .{}, .priority = mark_priority.script },
        .{ .line = 1, .kind = .sign, .glyph = "S", .style = .{}, .priority = mark_priority.script },
        .{ .line = 1, .kind = .added, .glyph = "", .style = .{}, .priority = mark_priority.git_change },
    };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectContains("B");
    try f.expectLacks("BS");
    // The script's sign and git's change bar share line 1's gutter, one
    // column each.
    try f.expectRow(1, "S  2▎cd");
}

test "a degenerate area never panics" {
    var f = try Fixture.init(3, 1);
    defer f.deinit();
    var view: ViewState = .{};
    _ = draw(f.ui(), 0, Rect.init(0, 0, 3, 1), &view, mkDoc("abc\ndef"));
    _ = draw(f.ui(), 0, Rect.empty, &view, mkDoc("abc"));
    _ = draw(f.ui(), 0, Rect.init(0, 0, 1, 1), &view, mkDoc("漢"));
}

// ── ui toggles: one test per toggle, each asserting a cell changed ──

test "relative numbers count from the cursor line, which keeps its own" {
    var f = try Fixture.init(12, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a\nb\nc\nd");
    d.cursor = 4; // line 2
    d.relative_numbers = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "   2 a", "   1 b", "   3 c", "   1 d" });
    d.relative_numbers = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRows(&.{ "   1 a", "   2 b", "   3 c", "   4 d" });
}

test "cursor_line_band off leaves the cursor row on the plain ground" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab\ncd");
    d.cursor = 4;
    d.cursor_line_band = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.bgEql(9, 1, f.theme.bg));
    try testing.expect(!f.bgEql(9, 1, f.theme.cursor_line));
}

test "show_whitespace paints · for spaces and → for a tab's first cell" {
    var f = try Fixture.init(16, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a b\tc");
    d.line_numbers = false;
    d.show_whitespace = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "a·b→c");
    try testing.expect(f.fgEql(1, 0, f.theme.whitespace));
    var e = mkDoc("a\tb");
    e.line_numbers = false;
    e.show_whitespace = true;
    _ = draw(f.ui(), 0, f.full(), &view, e);
    try f.expectRow(0, "a→  b");
    f.ascii = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "a.b>c");
    d.show_whitespace = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "a b c");
}

test "highlight_trailing_ws tints the trailing run off the cursor line only" {
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("ab  \ncd  ");
    d.line_numbers = false;
    d.cursor = 5; // line 1
    d.highlight_trailing_ws = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(vaxis.Color.eql(f.style(2, 0).bg, f.theme.error_fg.fg));
    try testing.expect(vaxis.Color.eql(f.style(3, 0).bg, f.theme.error_fg.fg));
    try testing.expect(!vaxis.Color.eql(f.style(1, 0).bg, f.theme.error_fg.fg));
    // the cursor line is left alone while you type
    try testing.expect(!vaxis.Color.eql(f.style(2, 1).bg, f.theme.error_fg.fg));
    d.highlight_trailing_ws = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(!vaxis.Color.eql(f.style(2, 0).bg, f.theme.error_fg.fg));
}

test "bracket_rainbow colours by depth, across lines and through a fold" {
    var f = try Fixture.init(20, 3);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("f(a[b{c}])\n(\n)");
    d.line_numbers = false;
    d.bracket_rainbow = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    const t = &f.theme;
    try testing.expect(vaxis.Color.eql(f.style(1, 0).fg, rainbowColor(t, 1)));
    try testing.expect(vaxis.Color.eql(f.style(3, 0).fg, rainbowColor(t, 2)));
    try testing.expect(vaxis.Color.eql(f.style(5, 0).fg, rainbowColor(t, 3)));
    try testing.expect(vaxis.Color.eql(f.style(7, 0).fg, rainbowColor(t, 3)));
    try testing.expect(vaxis.Color.eql(f.style(9, 0).fg, rainbowColor(t, 1)));
    try testing.expect(!vaxis.Color.eql(f.style(2, 0).fg, rainbowColor(t, 1)));
    // line 2's `)` closes line 1's `(`: depth 1
    try testing.expect(vaxis.Color.eql(f.style(0, 2).fg, rainbowColor(t, 1)));
    try testing.expectEqual(@as(u32, 2), bracketDepthOver("((a)", 0, 4, 1));
    d.bracket_rainbow = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(!vaxis.Color.eql(f.style(1, 0).fg, rainbowColor(t, 1)) or vaxis.Color.eql(rainbowColor(t, 1), f.theme.bg.fg));
}

test "word_matches underline every occurrence" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("foo bar foo");
    d.line_numbers = false;
    d.word_matches = &.{ .{ .start = 0, .end = 3 }, .{ .start = 8, .end = 11 } };
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.style(0, 0).ul_style == .single);
    try testing.expect(f.style(9, 0).ul_style == .single);
    try testing.expect(f.style(5, 0).ul_style == .off);
    d.word_matches = &.{};
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.style(0, 0).ul_style == .off);
}

test "todo_keywords bold the marker after a comment start; FIXME is urgent" {
    var f = try Fixture.init(30, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("x = 1; // TODO later\nTODO not a comment");
    d.line_numbers = false;
    d.todo_keywords = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.style(10, 0).bold);
    try testing.expect(vaxis.Color.eql(f.style(10, 0).fg, f.theme.warn_fg.fg));
    try testing.expect(!f.style(15, 0).bold);
    try testing.expect(!f.style(0, 1).bold);
    var e = mkDoc("# FIXME now");
    e.line_numbers = false;
    e.todo_keywords = true;
    _ = draw(f.ui(), 0, f.full(), &view, e);
    try testing.expect(vaxis.Color.eql(f.style(2, 0).fg, f.theme.error_fg.fg));
    e.todo_keywords = false;
    _ = draw(f.ui(), 0, f.full(), &view, e);
    try testing.expect(!f.style(2, 0).bold);
}

test "color_column paints the column under and past the text" {
    var f = try Fixture.init(12, 2);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abcdef\nab");
    d.line_numbers = false;
    d.color_column = 4;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(f.bgEql(3, 0, f.theme.panel_bg));
    try testing.expect(!f.bgEql(2, 0, f.theme.panel_bg));
    try testing.expect(f.bgEql(3, 1, f.theme.panel_bg));
    d.color_column = 0;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expect(!f.bgEql(3, 0, f.theme.panel_bg));
}

test "render_markdown conceals the marks off the cursor line and leaves the cursor line raw" {
    var f = try Fixture.init(30, 5);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("# Title\nsome **bold** and `code`\n- item\n[docs](https://x.y)\n## Cursor");
    d.line_numbers = false;
    d.cursor = d.text.len - 1; // on the last line
    d.render_markdown = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "Title");
    try testing.expect(f.style(0, 0).bold);
    try f.expectRow(1, "some bold and code");
    try testing.expect(f.style(5, 1).bold);
    try testing.expect(!f.style(4, 1).bold);
    try testing.expect(f.bgEql(14, 1, f.theme.panel_bg));
    try f.expectRow(2, "• item");
    try f.expectRow(3, "docs");
    try testing.expect(f.style(0, 3).ul_style == .single);
    try f.expectRow(4, "## Cursor");
    // A click on a concealed row still lands on the right byte.
    try testing.expectEqual(@as(u32, 7), f.hits.at(5, 1).?.editor_cell.col);
    d.render_markdown = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "# Title");
    try f.expectRow(1, "some **bold** and `code`");
}

test "the breadcrumb row: ` src › main.rs ` in the comment colour, a hit per segment; a cut label registers none" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    const names = [_][]const u8{ "src", "main.rs" };
    drawBreadcrumb(f.ui(), 3, f.full(), &names);
    try f.expectRow(0, " src \u{203A} main.rs");
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.palette.comment }));
    try testing.expect(f.bgEql(0, 0, .{ .bg = f.theme.palette.bg_darker }));
    try testing.expectEqual(@as(u16, 0), f.hits.at(2, 0).?.breadcrumb.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(10, 0).?.breadcrumb.idx);
    try testing.expectEqual(@as(u32, 3), f.hits.at(10, 0).?.breadcrumb.pane);
    try testing.expect(f.hits.at(5, 0) == null);
    try testing.expect(f.hits.at(0, 0) == null);
    // Too narrow: the middle goes, and with it every target.
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    drawBreadcrumb(g.ui(), 3, g.full(), &names);
    try g.expectRow(0, " src \u{2026}in.rs");
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);
    g.ascii = true;
    drawBreadcrumb(g.ui(), 3, g.full(), &names);
    try g.expectRow(0, " src ~in.rs");
    try testing.expectEqualStrings("a > b", breadcrumbLabel(g.ui(), &.{ "a", "b" }));
    drawBreadcrumb(g.ui(), 3, Rect.empty, &names);
}

test "the scrollbar takes the last column and a cell of air before it; without it the text runs to the edge" {
    var f = try Fixture.init(20, 4);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("a" ** 30 ++ "\n" ++ "b" ** 30 ++ "\n" ++ "c" ** 30 ++ "\nd\ne\nf\ng\nh\ni\nj");
    d.line_numbers = false;
    d.scrollbar = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    // The bar is Rust's editor bar: a styled cell, no glyph — the thumb
    // (rows 0–1 of 4 for 10 lines) on the muted ground, the track on the
    // chip's; the cell before it is air.
    try f.expectRow(0, "a" ** 18);
    try f.expectRow(1, "b" ** 18);
    try testing.expectEqualStrings(" ", f.cell(19, 0).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.style(19, 0).bg, f.theme.muted.fg));
    try testing.expect(vaxis.Color.eql(f.style(19, 3).bg, f.theme.chip.bg));
    try testing.expect(f.hits.at(19, 0).? == .scrollbar);
    d.scrollbar = false;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "a" ** 20);
}

test "an unfocused pane marks where its caret is; a focused one leaves the cell to the terminal" {
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    var view: ViewState = .{};
    var d = mkDoc("abc");
    d.line_numbers = false;
    d.cursor = 1;

    // Focused: the host terminal draws the cursor there, so the cell is
    // painted as ordinary text.
    const cur = draw(f.ui(), 0, f.full(), &view, d);
    try testing.expectEqual(Cursor{ .x = 1, .y = 0 }, cur.?);
    const plain = f.screen.readCell(1, 0).?;
    try testing.expectEqualStrings("b", plain.char.grapheme);

    // Unfocused: the glyph stays, over a muted block — the cursor
    // colour half-way to the ground, as `pty_view`'s `.dim` paints it.
    var view2: ViewState = .{};
    d.focused = false;
    _ = draw(f.ui(), 0, f.full(), &view2, d);
    const marked = f.screen.readCell(1, 0).?;
    try testing.expectEqualStrings("b", marked.char.grapheme);
    try testing.expect(!Theme.Color.eql(plain.style.bg, marked.style.bg));
    try testing.expect(!Theme.Color.eql(f.theme.fg.fg, marked.style.bg));
    // Its neighbours are untouched: one cell, not a band.
    try testing.expect(Theme.Color.eql(plain.style.bg, f.screen.readCell(0, 0).?.style.bg));
    try testing.expect(Theme.Color.eql(plain.style.bg, f.screen.readCell(2, 0).?.style.bg));
}
