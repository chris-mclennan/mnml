//! The rendered-markdown view: a line-oriented renderer (no tree — the
//! markdown that reaches a preview is what people write in READMEs,
//! and a line renderer handles every construct of it) into styled
//! segments, then a paint that word-wraps each line to the pane width
//! and scrolls in display rows.
//!
//! `render` is pure: source in, `Line`s out on the arena. `draw` lays
//! them out for one area. Both take a `Theme` for colors only; the
//! roles are the highlighter's (headings paint like `title`, code like
//! `string`) so a theme swap re-skins the preview with the editor.

const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const Canvas = @import("canvas.zig");
const text_mod = @import("text.zig");
const scrollbar = @import("scrollbar.zig");
const ids = @import("../core/ids.zig");

pub const Segment = vaxis.Segment;
pub const Style = vaxis.Style;
pub const PaneId = ids.PaneId;

pub const Line = struct {
    segs: []const Segment,
    /// Cells a wrapped continuation row is indented by.
    indent: u16 = 0,
    /// Cells the whole line stands in from the margin: a nested list
    /// item, two per level. Painted as an offset, never as text — the
    /// word wrap trims a row's leading blanks.
    lead: u16 = 0,
    /// // changed (ui-polish): a standalone `![alt](src)` line renders as
    /// a caption carrying `image = src`, followed by `image_rows - 1`
    /// blank `filler` lines the terminal draws the image over.
    image: ?[]const u8 = null,
    filler: bool = false,
};

/// Where `drawWith` painted an image's rows: the box (below the
/// caption, clipped to the visible rows) and the source as written.
pub const Placement = struct {
    src: []const u8,
    rect: Rect,
};

/// The `src` of a line that is only an image, else null.
pub fn imageLine(trimmed: []const u8) ?struct { src: []const u8, alt: []const u8 } {
    if (!std.mem.startsWith(u8, trimmed, "![")) return null;
    const lk = linkParts(trimmed[1..]) orelse return null;
    if (1 + lk.len != trimmed.len) return null;
    return .{ .src = lk.url, .alt = lk.label };
}

const Kind = enum { body, code, quote, heading, rule, list, table, blank };

fn bodyStyle(t: *const Theme) Style {
    return t.fg;
}

fn codeStyle(t: *const Theme) Style {
    return Theme.onBg(t.syntax.string, t.panel_bg.bg);
}

fn headingStyle(t: *const Theme, level: usize) Style {
    var s = switch (level) {
        1 => t.syntax.function,
        2 => t.syntax.escape,
        3 => t.syntax.string,
        4 => t.syntax.type,
        else => t.syntax.keyword,
    };
    s.bold = true;
    if (level <= 2) s.ul_style = .single;
    return s;
}

/// The inline grammar: `**strong**`, `*em*` / `_em_`, `` `code` ``,
/// `~~struck~~`, `[label](url)`, `![alt](src)`. Anything unmatched is
/// text in `base`.
pub fn inlineSegs(arena: Allocator, t: *const Theme, s: []const u8, base: Style) Allocator.Error![]const Segment {
    var out: std.ArrayListUnmanaged(Segment) = .empty;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const rest = s[i..];
        if (std.mem.startsWith(u8, rest, "**")) {
            if (std.mem.indexOf(u8, rest[2..], "**")) |end| if (end > 0) {
                try flush(arena, &out, &buf, base);
                var st = base;
                st.bold = true;
                try out.append(arena, .{ .text = rest[2 .. 2 + end], .style = st });
                i += 2 + end + 2;
                continue;
            };
        }
        if (std.mem.startsWith(u8, rest, "~~")) {
            if (std.mem.indexOf(u8, rest[2..], "~~")) |end| if (end > 0) {
                try flush(arena, &out, &buf, base);
                var st = base;
                st.strikethrough = true;
                try out.append(arena, .{ .text = rest[2 .. 2 + end], .style = st });
                i += 2 + end + 2;
                continue;
            };
        }
        if (rest[0] == '`') {
            if (std.mem.indexOfScalar(u8, rest[1..], '`')) |end| if (end > 0) {
                try flush(arena, &out, &buf, base);
                try out.append(arena, .{ .text = rest[1 .. 1 + end], .style = codeStyle(t) });
                i += 1 + end + 1;
                continue;
            };
        }
        if ((rest[0] == '*' or rest[0] == '_') and rest.len > 1 and rest[1] != ' ' and rest[1] != rest[0]) {
            if (std.mem.indexOfScalar(u8, rest[1..], rest[0])) |end| if (end > 0 and rest[end] != ' ') {
                try flush(arena, &out, &buf, base);
                var st = base;
                st.italic = true;
                try out.append(arena, .{ .text = rest[1 .. 1 + end], .style = st });
                i += 1 + end + 1;
                continue;
            };
        }
        if (std.mem.startsWith(u8, rest, "![")) {
            if (linkParts(rest[1..])) |lk| {
                try flush(arena, &out, &buf, base);
                const alt = lk.label;
                const caption = if (alt.len == 0) "[image]" else try std.fmt.allocPrint(arena, "[image: {s}]", .{alt});
                var st = t.muted;
                st.italic = true;
                try out.append(arena, .{ .text = caption, .style = st });
                i += 1 + lk.len;
                continue;
            }
        }
        if (rest[0] == '[') {
            if (linkParts(rest)) |lk| {
                try flush(arena, &out, &buf, base);
                var st = t.accent;
                st.ul_style = .single;
                try out.append(arena, .{ .text = lk.label, .style = st, .link = .{ .uri = lk.url } });
                if (lk.url.len > 0 and !std.mem.eql(u8, lk.url, lk.label)) {
                    try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, " ({s})", .{lk.url}), .style = t.muted });
                }
                i += lk.len;
                continue;
            }
        }
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        try buf.appendSlice(arena, rest[0..@min(n, rest.len)]);
        i += @min(n, rest.len);
    }
    try flush(arena, &out, &buf, base);
    if (out.items.len == 0) try out.append(arena, .{ .text = "", .style = base });
    return out.items;
}

fn flush(arena: Allocator, out: *std.ArrayListUnmanaged(Segment), buf: *std.ArrayListUnmanaged(u8), style: Style) Allocator.Error!void {
    if (buf.items.len == 0) return;
    try out.append(arena, .{ .text = try arena.dupe(u8, buf.items), .style = style });
    buf.clearRetainingCapacity();
}

const LinkParts = struct { label: []const u8, url: []const u8, len: usize };

/// `[label](url)` at the start of `s`.
fn linkParts(s: []const u8) ?LinkParts {
    if (s.len < 4 or s[0] != '[') return null;
    const rb = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (rb + 1 >= s.len or s[rb + 1] != '(') return null;
    const rp = std.mem.indexOfScalarPos(u8, s, rb + 2, ')') orelse return null;
    return .{ .label = s[1..rb], .url = s[rb + 2 .. rp], .len = rp + 1 };
}

fn leadingSpaces(line: []const u8) u16 {
    var n: u16 = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else if (c == '\t') n += 4 else break;
    }
    return n;
}

fn isRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    var marks: usize = 0;
    for (trimmed) |c| switch (c) {
        '-', '*', '_' => marks += 1,
        ' ' => {},
        else => return false,
    };
    return marks >= 3;
}

fn isTableRow(trimmed: []const u8) bool {
    return trimmed.len >= 2 and trimmed[0] == '|' and std.mem.indexOfScalarPos(u8, trimmed, 1, '|') != null;
}

fn isTableSeparator(trimmed: []const u8) bool {
    if (!isTableRow(trimmed)) return false;
    for (trimmed) |c| switch (c) {
        '|', '-', ':', ' ' => {},
        else => return false,
    };
    return std.mem.indexOfScalar(u8, trimmed, '-') != null;
}

/// Cells of a `| a | b |` row, trimmed.
fn tableCells(arena: Allocator, trimmed: []const u8) Allocator.Error![]const []const u8 {
    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    var inner = trimmed;
    if (inner.len > 0 and inner[0] == '|') inner = inner[1..];
    if (inner.len > 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |c| try cells.append(arena, std.mem.trim(u8, c, " \t"));
    return cells.items;
}

fn cellWidth(s: []const u8) u16 {
    return @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
}

/// Source → logical lines. A fenced block's fence lines are dropped and
/// its body painted in code style; a table block is laid out in aligned
/// columns; a heading gets a blank line above it (except the first).
pub fn render(arena: Allocator, t: *const Theme, src: []const u8, ascii: bool) Allocator.Error![]Line {
    return renderWith(arena, t, src, ascii, 0);
}

/// `render` with `image_rows` reserved per standalone image (0 keeps
/// the `[image: alt]` caption alone — the text fallback).
pub fn renderWith(arena: Allocator, t: *const Theme, src: []const u8, ascii: bool, image_rows: u16) Allocator.Error![]Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    const body = bodyStyle(t);
    var in_code = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var table_rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
    var table_header = true;
    // The source columns of the open list items, outermost first: an
    // item's depth is how many of them sit left of it.
    var list_cols: std.ArrayListUnmanaged(u16) = .empty;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        // A table block ends at the first non-table line.
        if (table_rows.items.len > 0 and !isTableRow(trimmed)) {
            try flushTable(arena, t, &out, table_rows.items, table_header, ascii);
            table_rows.clearRetainingCapacity();
            table_header = true;
        }
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_code = !in_code;
            continue;
        }
        if (in_code) {
            const bar = try arena.dupe(Segment, &.{
                .{ .text = if (ascii) "| " else "▏ ", .style = Theme.onBg(t.muted, t.panel_bg.bg) },
                .{ .text = line, .style = codeStyle(t) },
            });
            try out.append(arena, .{ .segs = bar, .indent = 2 });
            continue;
        }
        if (trimmed.len == 0) {
            try out.append(arena, .{ .segs = &.{} });
            continue;
        }
        if (image_rows > 0) if (imageLine(trimmed)) |img| {
            var cap = t.muted;
            cap.italic = true;
            const caption = if (img.alt.len == 0) "[image]" else try std.fmt.allocPrint(arena, "[image: {s}]", .{img.alt});
            try out.append(arena, .{ .segs = try arena.dupe(Segment, &.{.{ .text = caption, .style = cap }}), .image = img.src });
            var k: u16 = 1;
            while (k < image_rows) : (k += 1) try out.append(arena, .{ .segs = &.{}, .filler = true });
            continue;
        };
        if (trimmed[0] == '#') {
            var level: usize = 0;
            while (level < trimmed.len and trimmed[level] == '#' and level < 6) level += 1;
            const rest = std.mem.trim(u8, trimmed[level..], " \t#");
            if (out.items.len > 0 and (out.items[out.items.len - 1].segs.len > 0)) try out.append(arena, .{ .segs = &.{} });
            try out.append(arena, .{ .segs = try inlineSegs(arena, t, rest, headingStyle(t, level)) });
            continue;
        }
        if (isRule(trimmed)) {
            const rule = try arena.dupe(Segment, &.{.{ .text = if (ascii) "-" ** 40 else "─" ** 40, .style = t.border }});
            try out.append(arena, .{ .segs = rule });
            continue;
        }
        if (isTableRow(trimmed)) {
            if (isTableSeparator(trimmed)) {
                table_header = table_rows.items.len == 1;
                continue;
            }
            try table_rows.append(arena, try tableCells(arena, trimmed));
            continue;
        }
        if (trimmed[0] == '>') {
            var quote = t.muted;
            quote.italic = true;
            const content = std.mem.trimStart(u8, trimmed[1..], " ");
            const segs = try prefixed(arena, .{ .text = if (ascii) "| " else "▏ ", .style = t.syntax.keyword }, try inlineSegs(arena, t, content, quote));
            try out.append(arena, .{ .segs = segs, .indent = 2 });
            continue;
        }
        const indent = leadingSpaces(line);
        const is_item = listItem(trimmed) != null or orderedItem(trimmed) != null;
        // A paragraph back at the margin closes every list.
        if (!is_item and indent == 0) list_cols.clearRetainingCapacity();
        if (is_item) {
            while (list_cols.items.len > 0 and list_cols.items[list_cols.items.len - 1] >= indent) _ = list_cols.pop();
            try list_cols.append(arena, indent);
        }
        const lead: u16 = if (is_item) @intCast(@min(2 * (list_cols.items.len - 1), 40)) else 0;
        if (listItem(trimmed)) |item| {
            const segs = try prefixed(arena, .{ .text = item.marker(ascii), .style = t.accent }, try inlineSegs(arena, t, item.rest, body));
            try out.append(arena, .{ .segs = segs, .indent = item.width(ascii), .lead = lead });
            continue;
        }
        if (orderedItem(trimmed)) |n| {
            const label = try std.fmt.allocPrint(arena, "{s} ", .{trimmed[0..n]});
            const segs = try prefixed(arena, .{ .text = label, .style = t.accent }, try inlineSegs(arena, t, std.mem.trimStart(u8, trimmed[n + 1 ..], " "), body));
            try out.append(arena, .{ .segs = segs, .indent = @intCast(n + 1), .lead = lead });
            continue;
        }
        try out.append(arena, .{ .segs = try inlineSegs(arena, t, line, body), .indent = indent });
    }
    if (table_rows.items.len > 0) try flushTable(arena, t, &out, table_rows.items, table_header, ascii);
    return out.items;
}

const ListItem = struct {
    rest: []const u8,
    task: enum { none, open, done },

    fn marker(it: ListItem, ascii: bool) []const u8 {
        return switch (it.task) {
            .none => if (ascii) "* " else "• ",
            .open => if (ascii) "[ ] " else "☐ ",
            .done => if (ascii) "[x] " else "☑ ",
        };
    }

    fn width(it: ListItem, ascii: bool) u16 {
        return if (ascii and it.task != .none) 4 else 2;
    }
};

fn listItem(trimmed: []const u8) ?ListItem {
    if (trimmed.len < 2) return null;
    if ((trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        const rest = trimmed[2..];
        if (std.mem.startsWith(u8, rest, "[ ] ")) return .{ .rest = rest[4..], .task = .open };
        if (std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ")) return .{ .rest = rest[4..], .task = .done };
        return .{ .rest = rest, .task = .none };
    }
    return null;
}

/// Length of the `12.` prefix of an ordered item, or null.
fn orderedItem(trimmed: []const u8) ?usize {
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i == 0 or i + 1 >= trimmed.len or trimmed[i] != '.' or trimmed[i + 1] != ' ') return null;
    return i + 1;
}

fn prefixed(arena: Allocator, first: Segment, rest: []const Segment) Allocator.Error![]const Segment {
    const out = try arena.alloc(Segment, rest.len + 1);
    out[0] = first;
    @memcpy(out[1..], rest);
    return out;
}

fn flushTable(arena: Allocator, t: *const Theme, out: *std.ArrayListUnmanaged(Line), rows: []const []const []const u8, header: bool, ascii: bool) Allocator.Error!void {
    var cols: usize = 0;
    for (rows) |r| cols = @max(cols, r.len);
    const widths = try arena.alloc(u16, cols);
    @memset(widths, 0);
    for (rows) |r| for (r, 0..) |c, i| {
        widths[i] = @max(widths[i], cellWidth(c));
    };
    const sep: []const u8 = if (ascii) " | " else " │ ";
    for (rows, 0..) |r, ri| {
        var segs: std.ArrayListUnmanaged(Segment) = .empty;
        var style = bodyStyle(t);
        if (header and ri == 0) style.bold = true;
        for (0..cols) |i| {
            const cell: []const u8 = if (i < r.len) r[i] else "";
            const pad = widths[i] - cellWidth(cell);
            try segs.append(arena, .{ .text = cell, .style = style });
            if (pad > 0) try segs.append(arena, .{ .text = try spaces(arena, pad), .style = style });
            if (i + 1 < cols) try segs.append(arena, .{ .text = sep, .style = t.border });
        }
        try out.append(arena, .{ .segs = segs.items });
        if (header and ri == 0) {
            var rule: std.ArrayListUnmanaged(u8) = .empty;
            for (0..cols) |i| {
                for (0..widths[i]) |_| try rule.appendSlice(arena, if (ascii) "-" else "─");
                if (i + 1 < cols) try rule.appendSlice(arena, if (ascii) "-+-" else "─┼─");
            }
            try out.append(arena, .{ .segs = try arena.dupe(Segment, &.{.{ .text = rule.items, .style = t.border }}) });
        }
    }
}

fn spaces(arena: Allocator, n: usize) Allocator.Error![]const u8 {
    const s = try arena.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

/// Display rows `lines` take at `width` (word-wrapped).
pub fn totalRows(c: Canvas, lines: []const Line, width: u16) usize {
    var rows: usize = 0;
    for (lines) |l| rows += @max(1, c.measure(l.segs, width -| l.lead, .{ .wrap = .word, .trim = true }));
    return rows;
}

/// Paints `lines` from display row `scroll`, one cell of left margin,
/// with a scrollbar when they overflow. Every painted row registers an
/// `.editor_cell{pane, line = logical line, col = 0}` so the wheel and a
/// click route to the pane. Returns the rows the content takes.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, lines: []const Line, scroll: usize) usize {
    return drawWith(ui, pane, area, lines, scroll, null);
}

/// `draw` that also reports where each image's filler rows landed —
/// the box the terminal paints into, clipped to what is on screen (a
/// scrolled-off caption still gets its visible rows).
pub fn drawWith(ui: Ui, pane: PaneId, area: Rect, lines: []const Line, scroll: usize, placements: ?*std.ArrayListUnmanaged(Placement)) usize {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return 0;
    const total = totalRows(ui.canvas, lines, area.w -| 2);
    const want_bar = total > area.h and area.w > 8;
    const cols = area.splitRight(if (want_bar) 1 else 0);
    const body = cols.left;
    const text_w = body.w -| 2;
    var y: u16 = body.y;
    var skip = scroll;
    // The image whose fillers are being laid out, and its visible box.
    var cur_src: ?[]const u8 = null;
    var box: ?Rect = null;
    for (lines, 0..) |l, li| {
        if (l.image) |src| {
            flushPlacement(ui, placements, cur_src, box);
            cur_src = src;
            box = null;
        } else if (!l.filler) {
            flushPlacement(ui, placements, cur_src, box);
            cur_src = null;
            box = null;
        }
        if (y >= body.bottom()) break;
        const rows = @max(1, ui.canvas.measure(l.segs, text_w -| l.lead, .{ .wrap = .word, .trim = true }));
        if (skip >= rows) {
            skip -= rows;
            continue;
        }
        const r = Rect.init(body.x + 1 + l.lead, y, text_w -| l.lead, body.bottom() - y);
        const painted = if (l.segs.len == 0) 1 else ui.canvas.text(r, l.segs, .{ .wrap = .word, .trim = true, .scroll_y = @intCast(skip) });
        const used: u16 = @max(painted, 1);
        if (l.filler and cur_src != null) {
            // Two cells of margin each side, like the caption's indent.
            const row = Rect.init(body.x + 2, y, text_w -| 2, 1);
            box = if (box) |b| Rect.init(b.x, b.y, b.w, b.h + 1) else row;
            ui.fill(row, t.panel_bg);
        }
        ui.hit(Rect.init(body.x, y, body.w, used), .{ .editor_cell = .{ .pane = pane, .line = @intCast(li), .col = 0 } });
        y += used;
        skip = 0;
    }
    flushPlacement(ui, placements, cur_src, box);
    if (want_bar) scrollbar.drawVertical(ui, cols.rest, .{ .pane = pane }, total, area.h, scroll);
    return total;
}

fn flushPlacement(ui: Ui, placements: ?*std.ArrayListUnmanaged(Placement), src: ?[]const u8, box: ?Rect) void {
    const list = placements orelse return;
    const s = src orelse return;
    const b = box orelse return;
    if (b.isEmpty()) return;
    list.append(ui.arena, .{ .src = s, .rect = b }) catch {};
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn joined(arena: Allocator, line: Line) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (line.segs) |s| try out.appendSlice(arena, s.text);
    return out.items;
}

test "headings strip their marks, emphasis and code drop their markers, lists get bullets" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    const a = f.arena_state.allocator();
    const lines = try render(a, &f.theme, "# Title\n\nSome **bold** and *em* `code` text.\n- item\n1. first\n- [x] done\n", false);
    try testing.expectEqualStrings("Title", try joined(a, lines[0]));
    try testing.expect(lines[0].segs[0].style.bold);
    try testing.expectEqualStrings("Some bold and em code text.", try joined(a, lines[2]));
    try testing.expect(lines[2].segs[1].style.bold);
    try testing.expect(lines[2].segs[3].style.italic);
    try testing.expectEqualStrings("• item", try joined(a, lines[3]));
    try testing.expectEqualStrings("1. first", try joined(a, lines[4]));
    try testing.expectEqualStrings("☑ done", try joined(a, lines[5]));
}

test "nested list items stand in two cells a level, painted as an offset the wrap cannot trim; a paragraph ends the list" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    const a = f.arena_state.allocator();
    const src = "- alpha\n- beta\n  - nested child\n    - grandchild\n- gamma\n\n1. one\n   1. one-a\n2. two\ntext\n  - fresh\n";
    const lines = try render(a, &f.theme, src, false);
    const want_lead = [_]u16{ 0, 0, 2, 4, 0, 0, 0, 2, 0, 0, 0 };
    for (want_lead, 0..) |w, i| testing.expectEqual(w, lines[i].lead) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ i, try joined(a, lines[i]) });
        return err;
    };
    try testing.expectEqualStrings("• nested child", try joined(a, lines[2]));
    try testing.expectEqualStrings("1. one-a", try joined(a, lines[7]));
    _ = draw(f.ui(), 1, f.full(), lines, 0);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(1, &buf), " • beta"));
    try testing.expect(std.mem.startsWith(u8, f.row(2, &buf), "   • nested child"));
    try testing.expect(std.mem.startsWith(u8, f.row(3, &buf), "     • grandchild"));
    try testing.expect(std.mem.startsWith(u8, f.row(7, &buf), "   1. one-a"));
}

test "fences vanish, their body is code; quotes, rules, links and tables" {
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    const a = f.arena_state.allocator();
    const src = "```rust\nfn main() {}\n```\n> quoted\n---\nsee [docs](https://x.y) now\n| a | bb |\n|---|---|\n| 1 | 2 |\n";
    const lines = try render(a, &f.theme, src, false);
    try testing.expectEqualStrings("▏ fn main() {}", try joined(a, lines[0]));
    try testing.expectEqualStrings("▏ quoted", try joined(a, lines[1]));
    try testing.expect(std.mem.startsWith(u8, try joined(a, lines[2]), "───"));
    try testing.expectEqualStrings("see docs (https://x.y) now", try joined(a, lines[3]));
    try testing.expectEqualStrings("a │ bb", try joined(a, lines[4]));
    try testing.expect(lines[4].segs[0].style.bold);
    try testing.expectEqualStrings("1 │ 2 ", try joined(a, lines[6]));
}

test "draw wraps to the width, scrolls in rows and registers a hit per row" {
    var f = try Fixture.init(20, 3);
    defer f.deinit();
    const a = f.arena_state.allocator();
    const lines = try render(a, &f.theme, "# T\n\none two three four five six seven\n", false);
    const total = draw(f.ui(), 3, f.full(), lines, 0);
    try testing.expect(total >= 4);
    var row0: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(0, &row0), " T"));
    // Overflow: a scrollbar in the last column.
    try testing.expect(f.hits.at(19, 0).? == .scrollbar);
    try testing.expectEqual(@as(u32, 0), f.hits.at(1, 0).?.editor_cell.line);
    _ = draw(f.ui(), 3, f.full(), lines, 2);
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(0, &buf), " one"));
}

test "images: a standalone ![alt](src) reserves rows; the placement follows the scroll and clips to the pane" {
    var f = try Fixture.init(40, 6);
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "intro\n![a cat](cat.png)\nafter ![inline](x.png) text\n";
    // Without image rows: the caption only, inline images stay inline.
    // (the trailing newline is a fourth, empty line)
    const plain = try render(a, &f.theme, src, false);
    try testing.expectEqual(@as(usize, 4), plain.len);
    try testing.expectEqualStrings("[image: a cat]", try joined(a, plain[1]));
    try testing.expect(plain[1].image == null);
    // With four rows: caption + three fillers; the inline one is untouched.
    const lines = try renderWith(a, &f.theme, src, false, 4);
    try testing.expectEqual(@as(usize, 7), lines.len);
    try testing.expectEqualStrings("cat.png", lines[1].image.?);
    try testing.expect(lines[2].filler and lines[3].filler and lines[4].filler);
    try testing.expect(lines[5].image == null);
    var placements: std.ArrayListUnmanaged(Placement) = .empty;
    _ = drawWith(f.ui(), 0, f.full(), lines, 0, &placements);
    try testing.expectEqual(@as(usize, 1), placements.items.len);
    const p = placements.items[0];
    try testing.expectEqualStrings("cat.png", p.src);
    // Rows 2, 3, 4 (the caption is row 1); two cells in from the margin,
    // and the scrollbar (seven rows on six) takes the last column.
    try testing.expectEqual(@as(u16, 2), p.rect.y);
    try testing.expectEqual(@as(u16, 3), p.rect.h);
    try testing.expectEqual(@as(u16, 2), p.rect.x);
    try testing.expectEqual(@as(u16, 35), p.rect.w);
    // Scrolled past the caption and the first filler: two rows left, at the top.
    placements.clearRetainingCapacity();
    _ = drawWith(f.ui(), 0, f.full(), lines, 3, &placements);
    try testing.expectEqual(@as(usize, 1), placements.items.len);
    try testing.expectEqual(@as(u16, 0), placements.items[0].rect.y);
    try testing.expectEqual(@as(u16, 2), placements.items[0].rect.h);
    // A pane too short for all the fillers clips the box to what it shows.
    var g = try Fixture.init(40, 3);
    defer g.deinit();
    placements.clearRetainingCapacity();
    _ = drawWith(g.ui(), 0, g.full(), lines, 0, &placements);
    try testing.expectEqual(@as(u16, 1), placements.items[0].rect.h);
    try testing.expect(imageLine("![x](y.png) tail") == null);
    try testing.expectEqualStrings("y.png", imageLine("![x](y.png)").?.src);
}
