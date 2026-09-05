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
//! outgrows the rows, and `ViewState.pin` lets the app scroll the
//! viewport away from the cursor (a wheel in standard mode): while the
//! cursor stays at the pinned byte the view is not pulled back to it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const scrollbar = @import("scrollbar.zig");

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

pub const CursorShape = enum { block, bar, underline };

/// A byte range underlined over the syntax style — a diagnostic. The
/// style's `fg` colours the line; `ul_style` picks its shape.
pub const Underline = struct { start: usize, end: usize, style: Style };

/// A one-cell label painted OVER the glyph at `byte` in the
/// `current_match` style — flash-motion's jump targets.
pub const Label = struct { byte: usize, text: []const u8 };

pub const Doc = struct {
    text: []const u8,
    /// Byte offset.
    cursor: usize,
    /// Selection tail; `null` = no selection.
    anchor: ?usize,
    extra_cursors: []const usize = &.{},
    folds: []const Fold = &.{},
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
pub const GutterMark = struct {
    line: u32,
    kind: MarkKind,
    glyph: []const u8 = "",
    style: Style = .{},
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

// ── the line index ──

/// Byte ranges of every line, excluding the newline. Built on the frame
/// arena; a document always has at least one line.
pub const Lines = struct {
    starts: []const u32,
    text_len: u32,

    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!Lines {
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
        return .{ .starts = starts, .text_len = @intCast(text.len) };
    }

    pub fn count(l: Lines) u32 {
        return @intCast(l.starts.len);
    }

    pub fn start(l: Lines, line: u32) u32 {
        return l.starts[line];
    }

    /// One past the last byte of the line's text (the newline's offset,
    /// or the text length on the last line).
    pub fn end(l: Lines, line: u32) u32 {
        if (line + 1 < l.starts.len) return l.starts[line + 1] - 1;
        return l.text_len;
    }

    pub fn slice(l: Lines, text: []const u8, line: u32) []const u8 {
        return text[l.start(line)..l.end(line)];
    }

    /// The line containing byte `off` (offsets past the end land on the
    /// last line).
    pub fn lineOf(l: Lines, off: usize) u32 {
        var lo: usize = 0;
        var hi: usize = l.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (l.starts[mid] <= off) lo = mid else hi = mid;
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
};

pub fn layoutLine(ui: Ui, line: []const u8, tab_width: u8) Allocator.Error![]CellInfo {
    var out: std.ArrayListUnmanaged(CellInfo) = .empty;
    const tw: u32 = if (tab_width == 0) 1 else tab_width;
    var x: u32 = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const bytes = g.bytes(line);
        const off: u32 = @intCast(g.start);
        if (bytes.len == 1 and bytes[0] == '\t') {
            const n = tw - (x % tw);
            for (0..n) |_| {
                try out.append(ui.arena, .{ .bytes = " ", .off = off, .w = 1, .ws = true });
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
    block: ?struct { l0: u32, l1: u32, c0: u32, c1: u32 } = null,
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

pub fn markStyle(t: *const Theme, kind: MarkKind, base: Style) Style {
    return Theme.withFg(base, switch (kind) {
        .added => t.syntax.string.fg,
        .modified => t.warn_fg.fg,
        .deleted => t.error_fg.fg,
        .sign => t.fg.fg,
    });
}

/// Rows `line` takes at `text_w` (1 when not wrapping or folded).
fn lineRows(ui: Ui, doc: Doc, lines: Lines, line: u32, text_w: u16) Allocator.Error!u32 {
    if (!doc.wrap or foldStartingAt(doc.folds, line) != null) return 1;
    const cells = try layoutLine(ui, lines.slice(doc.text, line), doc.tab_width);
    return @intCast((try wrapRows(ui.arena, cells, text_w)).len);
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
        var subrow: u32 = 0;
        if (doc.wrap and foldStartingAt(doc.folds, cur_line) == null) {
            const rows = try wrapRows(ui.arena, cur_cells, text_w);
            subrow = rowOfCell(rows, cellIndex(cur_cells, cur_off));
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
        sel.block = .{ .l0 = @min(la, lc), .l1 = @max(la, lc), .c0 = @min(ca, cc), .c1 = @max(ca, cc) };
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

    const lines = try Lines.build(ui.arena, doc.text);
    const total = lines.count();
    const gutter_w = @min(gutterWidth(doc, total), area.w);
    const num_w: u16 = gutter_w -| 2;
    const text_h = area.h;
    const bar = doc.scrollbar and total > text_h and area.w > gutter_w + 4;
    const text_w = area.w - gutter_w - @as(u16, if (bar) scrollbar_w else 0);
    const text_x = area.x + gutter_w;

    try keepCursorVisible(ui, doc, lines, view, text_w, text_h);

    const sel = try selectionOf(ui, doc, lines);
    const cursor_line_real = lines.lineOf(doc.cursor);
    const cursor_line = visibleOwner(doc.folds, cursor_line_real);
    const cursor_off: u32 = if (cursor_line_real == cursor_line) @intCast(doc.cursor - lines.start(cursor_line)) else 0;
    var found: ?Cursor = null;
    var label_i: usize = 0;

    const fold_word = if (ui.ascii) fold_marker_ascii else fold_marker;

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
        const row_style: Style = if (is_cursor_line) t.cursor_line else t.bg;
        var spans = RangeCursor(Span).init(doc.spans, line_start);
        var var_spans = RangeCursor(VarSpan).init(doc.var_spans, line_start);
        var matches = RangeCursor(Range).init(doc.matches, line_start);
        var underlines = RangeCursor(Underline).init(doc.underlines, line_start);

        for (rows, 0..) |row, ri| {
            if (y >= area.bottom()) break;
            const row_rect = Rect.init(area.x, y, area.w, 1);
            ui.fill(row_rect, row_style);

            // Gutter: the number on the line's first row, blank after.
            if (gutter_w > 0) {
                const gr = Rect.init(area.x, y, gutter_w, 1);
                const gstyle = if (is_cursor_line) Theme.onBg(Theme.withFg(t.gutter, t.fg.fg), row_style.bg) else t.gutter;
                if (ri == 0 and num_w > 0) {
                    if (doc.blame.len > 0) {
                        const label = if (line < doc.blame.len) doc.blame[line] else "";
                        _ = ui.putStr(area.x + 1, y, num_w, ui.clipStr(label, num_w), Theme.onBg(t.muted, row_style.bg));
                    } else {
                        const num = ui.fmt("{d}", .{line + 1});
                        _ = ui.putStrRight(area.x + 1 + num_w, y, num_w, num, gstyle);
                    }
                }
                // The change mark takes the gutter's last cell, the sign
                // its first; a one-cell gutter gives the cell to the sign.
                if (ri == 0) {
                    const sign = signAt(doc.gutter_marks, line);
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
                    if (sign) |m| _ = ui.putStr(area.x, y, 1, m.glyph, Theme.onBg(m.style, row_style.bg));
                }
                ui.hit(gr, .{ .editor_cell = .{ .pane = pane, .line = line, .col = 0 } });
            }

            // Cells. `abs_x` is the display column within the line (what
            // a block selection is measured in); `rel_x` the column within
            // this row, which is what lands on screen.
            var abs_x: u32 = 0;
            for (cells[0..row.start]) |p| abs_x += p.w;
            var rel_x: u32 = 0;
            var painted_x: u16 = text_x;
            const skip: u32 = if (ri == 0) view.scroll_col else 0;
            var i = row.start;
            while (i < row.end) : (i += 1) {
                const c = cells[i];
                const x = abs_x;
                const rx = rel_x;
                abs_x += c.w;
                rel_x += c.w;
                if (rx + c.w <= skip) continue;
                if (rx < skip) continue; // a wide glyph straddling the scroll edge
                const cx: u32 = rx - skip;
                if (cx + c.w > text_w) break;
                const sx: u16 = text_x + @as(u16, @intCast(cx));
                const off: usize = line_start + c.off;

                var style: Style = row_style;
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
                if (sel) |s| {
                    const in_range = s.block == null and off >= s.lo and off < s.hi;
                    const in_block = if (s.block) |b| line >= b.l0 and line <= b.l1 and x >= b.c0 and x <= b.c1 else false;
                    if (in_range or in_block) {
                        style.bg = t.selection.bg;
                    }
                }
                for (doc.extra_cursors) |ec| if (ec == off) {
                    style.bg = t.fg.fg;
                    style.fg = t.bg.bg;
                };

                const cell_rect = Rect.init(sx, y, c.w, 1);
                while (label_i < doc.labels.len and doc.labels[label_i].byte < off) label_i += 1;
                if (label_i < doc.labels.len and doc.labels[label_i].byte == off) {
                    ui.canvas.put(sx, y, .{ .char = .{ .grapheme = doc.labels[label_i].text, .width = 1 }, .style = t.current_match });
                    if (c.w > 1) ui.canvas.put(sx + 1, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = t.current_match });
                } else ui.canvas.put(sx, y, .{ .char = .{ .grapheme = c.bytes, .width = c.w }, .style = style });
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
                const eol_x = painted_x;
                const eol_off = line_end - line_start;
                var eol_style = row_style;
                var paint_eol = false;
                if (sel) |s| {
                    if (s.block) |b| {
                        if (line >= b.l0 and line <= b.l1) {
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
                if (is_cursor_line and found == null and cursor_line_real == cursor_line and cursor_off >= eol_off) {
                    found = .{ .x = eol_x, .y = y };
                }
                if (fold) |f| {
                    const hidden = f.last_line - f.first_line;
                    const marker = ui.fmt("{s}{d}{s}", .{ fold_word, hidden, fold_tail });
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
    }
    if (bar) scrollbar.drawVertical(ui, Rect.init(area.right() - scrollbar_w, area.y, scrollbar_w, area.h), .{ .pane = pane }, total, text_h, view.scroll_line);
    return found;
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
    try f.expectRow(0, "   1 fn main() { ⋯ folded · 4 lines hidden");
    try f.expectRow(1, "   6 let end = 1;");
    try f.expectLacks("two;");
    try f.expectContains("folded");
    try f.expectContains("hidden");
    try testing.expectEqual(Cursor{ .x = 16, .y = 0 }, cur.?);
    try testing.expect(f.fgEql(18, 0, f.theme.fold));

    f.ascii = true;
    _ = draw(f.ui(), 0, f.full(), &view, d);
    try f.expectRow(0, "   1 fn main() { ... folded - 4 lines hidden");
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

test "a degenerate area never panics" {
    var f = try Fixture.init(3, 1);
    defer f.deinit();
    var view: ViewState = .{};
    _ = draw(f.ui(), 0, Rect.init(0, 0, 3, 1), &view, mkDoc("abc\ndef"));
    _ = draw(f.ui(), 0, Rect.empty, &view, mkDoc("abc"));
    _ = draw(f.ui(), 0, Rect.init(0, 0, 1, 1), &view, mkDoc("漢"));
}
