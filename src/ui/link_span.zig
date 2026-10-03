//! A link inside text a painter already put on screen — the one way a
//! run of plain text becomes clickable where it names a URL or a key an
//! installed integration knows (a ticket, say).
//!
//! Two halves. Finding is the app's (`app/link_rules.zig`): plain
//! `http(s)://` URLs, by the one matcher below (`nextUrl` — what a
//! terminal pane's right-click and the editor's `gx` read too), then
//! the patterns the installed integrations' manifests declare
//! (`links[]`). Core knows no key shape of its own. The app hands its
//! finder to every frame as `Ui.links`; it caches by the text, so a
//! card repainting the same words runs no regex.
//!
//! Marking is this file's: `mark` takes the text a painter just put at
//! (`x`, `y`) and the cells it used, and for each link inside them
//! registers a `.link` hit (a click opens it, a right-click is the
//! Link menu — Copy link / Open link) and restyles the cells: a dotted
//! underline at rest, the accent and a solid underline under the
//! pointer. The painter's colours stay; nothing moves.

const std = @import("std");
const vaxis = @import("vaxis");
const Ui = @import("context.zig");
const Rect = @import("rect.zig");
const utf8 = @import("../core/utf8.zig");

/// A byte range of a text.
pub const Range = struct { start: usize, end: usize };

/// A link in a text: its bytes and the address it opens. `url` is the
/// finder's (a cache that outlives the frame) or the text's own bytes.
pub const Span = struct { start: usize, end: usize, url: []const u8 };

/// What finds the links in a text — the app's rules, behind a pointer
/// so a component sees no `App`.
pub const Finder = struct {
    ctx: *anyopaque,
    find: *const fn (ctx: *anyopaque, text: []const u8) []const Span,

    pub fn spans(f: Finder, text: []const u8) []const Span {
        return f.find(f.ctx, text);
    }
};

// ─── the URL matcher ────────────────────────────────────────────────────

/// The next `scheme://…` URL in `text` at or after byte `from`: the
/// letters before `://`, then up to whitespace, a quote, `>`, `)` or
/// `]`, less a trailing `.` `,` `;` (a sentence's, not the URL's).
pub fn nextUrl(text: []const u8, from: usize) ?Range {
    var start = from;
    while (std.mem.indexOfPos(u8, text, start, "://")) |p| {
        var a = p;
        while (a > from and std.ascii.isAlphabetic(text[a - 1])) a -= 1;
        var b = p + 3;
        while (b < text.len and !std.ascii.isWhitespace(text[b]) and text[b] != '"' and text[b] != '\'' and text[b] != '>' and text[b] != ')' and text[b] != ']') b += 1;
        while (b > p + 3 and (text[b - 1] == '.' or text[b - 1] == ',' or text[b - 1] == ';')) b -= 1;
        if (a < p and b > p + 3) return .{ .start = a, .end = b };
        start = @max(b, p + 3);
    }
    return null;
}

/// The URL covering byte `col` of `line`, if one does.
pub fn urlAt(line: []const u8, col: usize) ?[]const u8 {
    const r = rangeAt(line, col) orelse return null;
    return line[r.start..r.end];
}

/// `urlAt`'s bytes as a range of `line`.
pub fn rangeAt(line: []const u8, col: usize) ?Range {
    var from: usize = 0;
    while (nextUrl(line, from)) |r| {
        if (col >= r.start and col < r.end) return r;
        if (r.start > col) return null;
        from = r.end;
    }
    return null;
}

/// A URL a link may open: `http://` or `https://`, any case. Anything
/// else (`file://`, `javascript:`) is never handed to a browser.
pub fn openable(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

// ─── marking ────────────────────────────────────────────────────────────

/// The links of `text`, painted from (`x`, `y`) over `cells` cells (a
/// clipped paint's count, its ellipsis included): each registers a
/// `.link` hit over its cells and wears the link look. No finder on
/// the frame (a fixture), no text or no cells: nothing.
pub fn mark(ui: Ui, x: u16, y: u16, cells: u16, text: []const u8) void {
    const finder = ui.links orelse return;
    if (cells == 0 or text.len == 0) return;
    markSpans(ui, x, y, cells, text, finder.spans(text));
}

/// `mark` with the spans in hand (sorted, as a finder returns them).
pub fn markSpans(ui: Ui, x: u16, y: u16, cells: u16, text: []const u8, spans: []const Span) void {
    const method = ui.canvas.widthMethod();
    for (spans) |s| {
        if (s.start >= s.end or s.end > text.len) continue;
        const c0 = utf8.width(text[0..s.start], method);
        if (c0 >= cells) break;
        const c1 = @min(utf8.width(text[0..s.end], method), cells);
        paintSpan(ui, x + c0, y, c1 -| c0, s.url);
    }
}

fn paintSpan(ui: Ui, x: u16, y: u16, w: u16, url: []const u8) void {
    if (w == 0) return;
    const r = Rect.init(x, y, w, 1);
    // The hit outlives the cache that owns the URL only until the next
    // frame; the frame arena holds it exactly that long.
    ui.hit(r, .{ .link = .{ .url = ui.arena.dupe(u8, url) catch return } });
    const hot = ui.hovered(r) or if (ui.menu_link) |m| !m.intersect(r).isEmpty() else false;
    var cx = x;
    while (cx < x + w) : (cx += 1) ui.canvas.restyle(cx, y, if (hot) hotPatch(ui) else .{ .ul_style = .dotted });
}

/// The look of a link under the pointer — or the one an open menu is
/// for: the accent and a solid underline over the painter's colours.
fn hotPatch(ui: Ui) @import("canvas.zig").StylePatch {
    return .{ .fg = ui.theme.accent.fg, .ul_style = .single };
}

/// A surface that finds its links itself (a terminal pane's grid)
/// calls this over `area` once its cells are out: the cells of the
/// link the open menu is for (`Ui.menu_link`) that fall in `area`
/// take the hover look. Nothing with no such menu.
pub fn paintMenuLink(ui: Ui, area: Rect) void {
    const m = ui.menu_link orelse return;
    const r = m.intersect(area);
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        var x = r.x;
        while (x < r.right()) : (x += 1) ui.canvas.restyle(x, y, hotPatch(ui));
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "nextUrl: the scheme, the address, never a sentence's last stop; urlAt finds the one under a column" {
    const s = "see https://example.com/a/b. and (http://x.y/z) end";
    const a = nextUrl(s, 0).?;
    try testing.expectEqualStrings("https://example.com/a/b", s[a.start..a.end]);
    const b = nextUrl(s, a.end).?;
    try testing.expectEqualStrings("http://x.y/z", s[b.start..b.end]);
    try testing.expect(nextUrl(s, b.end) == null);
    try testing.expect(nextUrl("no :// here", 0) == null);
    try testing.expectEqualStrings("https://example.com/a/b", urlAt(s, 10).?);
    try testing.expect(urlAt(s, 1) == null);
    try testing.expect(urlAt(s, 27) == null); // the `.`
    try testing.expect(openable("HTTPS://x"));
    try testing.expect(!openable("file:///etc/passwd"));
}

test "mark: a span's cells take the hit and the look; the pointer lights them; clipped cells are not linked" {
    const Fixture = @import("test_fixture.zig");
    var f = try Fixture.init(30, 2);
    defer f.deinit();
    const text = "go ENG-123 now";
    const spans = [_]Span{.{ .start = 3, .end = 10, .url = "https://t.example/ENG-123" }};
    var ui = f.ui();
    _ = ui.putStr(1, 0, 20, text, ui.theme.fg);
    markSpans(ui, 1, 0, 14, text, &spans);
    try testing.expect(f.hits.at(3, 0) == null);
    try testing.expectEqualStrings("https://t.example/ENG-123", f.hits.at(4, 0).?.link.url);
    try testing.expectEqualStrings("https://t.example/ENG-123", f.hits.at(10, 0).?.link.url);
    try testing.expect(f.hits.at(11, 0) == null);
    try testing.expectEqual(vaxis.Style.Underline.dotted, f.cell(4, 0).style.ul_style);
    try testing.expectEqual(vaxis.Style.Underline.off, f.cell(11, 0).style.ul_style);
    // Under the pointer: the accent, a solid underline.
    ui.hover = .{ .x = 6, .y = 0 };
    _ = ui.putStr(1, 1, 20, text, ui.theme.fg);
    markSpans(ui, 1, 1, 14, text, &.{.{ .start = 3, .end = 10, .url = "u" }});
    try testing.expectEqual(vaxis.Style.Underline.dotted, f.cell(6, 1).style.ul_style); // the pointer is on row 0
    ui.hover = .{ .x = 6, .y = 1 };
    markSpans(ui, 1, 1, 14, text, &.{.{ .start = 3, .end = 10, .url = "u" }});
    try testing.expectEqual(vaxis.Style.Underline.single, f.cell(6, 1).style.ul_style);
    try testing.expect(std.meta.eql(ui.theme.accent.fg, f.cell(6, 1).style.fg));
    // The link an open menu is for wears the same look with the
    // pointer elsewhere (on the menu); a menu for another link does not.
    ui.hover = null;
    ui.menu_link = Rect.init(4, 1, 7, 1);
    _ = ui.putStr(1, 1, 20, text, ui.theme.fg);
    markSpans(ui, 1, 1, 14, text, &.{.{ .start = 3, .end = 10, .url = "u" }});
    try testing.expectEqual(vaxis.Style.Underline.single, f.cell(6, 1).style.ul_style);
    try testing.expect(std.meta.eql(ui.theme.accent.fg, f.cell(6, 1).style.fg));
    ui.menu_link = Rect.init(4, 0, 7, 1);
    _ = ui.putStr(1, 1, 20, text, ui.theme.fg);
    markSpans(ui, 1, 1, 14, text, &.{.{ .start = 3, .end = 10, .url = "u" }});
    try testing.expectEqual(vaxis.Style.Underline.dotted, f.cell(6, 1).style.ul_style);
    ui.menu_link = null;
    // Painted into 6 cells: only `ENG` of the key is on screen.
    f.hits.reset();
    markSpans(ui, 1, 0, 6, text, &spans);
    try testing.expect(f.hits.at(6, 0) != null);
    try testing.expect(f.hits.at(7, 0) == null);
}
