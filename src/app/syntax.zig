//! Syntax spans for the editor view: one tree-sitter parse + highlights
//! query per editor pane, re-run when the text changed. The spans slice
//! is gpa-owned and rebuilt in place; the view borrows it for a frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const highlight = @import("highlight");
const ts = highlight.ts;
const table = highlight.table;
const editor_view = @import("../ui/editor_view.zig");
const color = @import("../ui/color.zig");

pub const Span = editor_view.Span;
pub const Style = color.Style;

fn rgb(r: u8, g: u8, b: u8) color.Color {
    return .{ .rgb = .{ r, g, b } };
}

/// Capture name prefix → style. First match wins, so `function.method`
/// lands on `function`.
const palette = [_]struct { []const u8, Style }{
    .{ "comment", .{ .fg = rgb(0x6c, 0x70, 0x86), .italic = true } },
    .{ "string", .{ .fg = rgb(0xa6, 0xe3, 0xa1) } },
    .{ "keyword", .{ .fg = rgb(0xcb, 0xa6, 0xf7) } },
    .{ "function", .{ .fg = rgb(0x89, 0xb4, 0xfa) } },
    .{ "method", .{ .fg = rgb(0x89, 0xb4, 0xfa) } },
    .{ "type", .{ .fg = rgb(0xf9, 0xe2, 0xaf) } },
    .{ "constructor", .{ .fg = rgb(0xf9, 0xe2, 0xaf) } },
    .{ "number", .{ .fg = rgb(0xfa, 0xb3, 0x87) } },
    .{ "constant", .{ .fg = rgb(0xfa, 0xb3, 0x87) } },
    .{ "boolean", .{ .fg = rgb(0xfa, 0xb3, 0x87) } },
    .{ "operator", .{ .fg = rgb(0x94, 0xe2, 0xd5) } },
    .{ "punctuation", .{ .fg = rgb(0x93, 0x9a, 0xb7) } },
    .{ "property", .{ .fg = rgb(0xf5, 0xc2, 0xe7) } },
    .{ "attribute", .{ .fg = rgb(0xf9, 0xe2, 0xaf) } },
    .{ "variable", .{ .fg = rgb(0xcd, 0xd6, 0xf4) } },
    .{ "tag", .{ .fg = rgb(0xf3, 0x8b, 0xa8) } },
    .{ "label", .{ .fg = rgb(0x89, 0xdc, 0xeb) } },
    .{ "namespace", .{ .fg = rgb(0xf9, 0xe2, 0xaf) } },
    .{ "module", .{ .fg = rgb(0xf9, 0xe2, 0xaf) } },
    .{ "text", .{ .fg = rgb(0xcd, 0xd6, 0xf4) } },
    .{ "markup", .{ .fg = rgb(0xcd, 0xd6, 0xf4) } },
    .{ "escape", .{ .fg = rgb(0xf3, 0x8b, 0xa8) } },
    .{ "embedded", .{ .fg = rgb(0xcd, 0xd6, 0xf4) } },
};

pub fn styleForCapture(name: []const u8) ?Style {
    for (palette) |p| {
        if (std.mem.startsWith(u8, name, p[0])) return p[1];
    }
    return null;
}

/// Table key for a file, or null when mnml-zig has no grammar for it.
pub fn keyForPath(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    if (table.keyForFilename(base)) |k| return k;
    const ext = std.fs.path.extension(base);
    if (ext.len <= 1) return null;
    var lower: [32]u8 = undefined;
    if (ext.len - 1 > lower.len) return null;
    const e = std.ascii.lowerString(&lower, ext[1..]);
    if (table.keyForExtension(e)) |k| return k;
    return if (table.find(e) != null) e else null;
}

pub const Syntax = struct {
    gpa: Allocator,
    entry: ?usize = null,
    parser: ?*ts.Parser = null,
    query: ?*ts.Query = null,
    spans: std.ArrayListUnmanaged(Span) = .empty,

    pub fn init(gpa: Allocator) Syntax {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Syntax) void {
        if (self.query) |q| q.deinit();
        if (self.parser) |p| p.deinit();
        self.spans.deinit(self.gpa);
    }

    /// Pick the grammar for `path`. A file with no grammar clears the
    /// spans and stays that way until a rename.
    pub fn setLanguage(self: *Syntax, path: ?[]const u8) void {
        const key = if (path) |p| keyForPath(p) else null;
        const idx = if (key) |k| table.find(k) else null;
        if (idx == self.entry and (idx == null or self.query != null)) return;
        if (self.query) |q| q.deinit();
        self.query = null;
        if (self.parser) |p| p.deinit();
        self.parser = null;
        self.spans.clearRetainingCapacity();
        self.entry = idx;
        const i = idx orelse return;
        const e = table.entries[i];
        const parser = ts.Parser.init() catch return;
        parser.setLanguage(e.language()) catch {
            parser.deinit();
            return;
        };
        self.parser = parser;
        self.query = ts.Query.init(e.language(), table.highlightSource(i), null) catch null;
    }

    /// Re-parse `text` and rebuild the spans. Spans are sorted by start,
    /// innermost capture last so a later (more specific) capture wins.
    pub fn refresh(self: *Syntax, text: []const u8) Allocator.Error!void {
        self.spans.clearRetainingCapacity();
        const parser = self.parser orelse return;
        const query = self.query orelse return;
        const tree = parser.parseString(null, text) orelse return;
        defer tree.deinit();
        const cursor = ts.QueryCursor.init() catch return;
        defer cursor.deinit();
        cursor.exec(query, tree.rootNode());
        while (cursor.nextMatch()) |m| {
            for (m.slice()) |cap| {
                const name = query.captureName(cap.index);
                const style = styleForCapture(name) orelse continue;
                const s = cap.node.startByte();
                const e = cap.node.endByte();
                if (e <= s or e > text.len) continue;
                try self.spans.append(self.gpa, .{ .start = s, .end = e, .style = style });
            }
        }
    }
};

test "syntax: a rust file gets spans, an unknown extension gets none" {
    const gpa = std.testing.allocator;
    var s = Syntax.init(gpa);
    defer s.deinit();
    s.setLanguage("/ws/main.rs");
    try s.refresh("fn main() {\n    let s = \"hi\";\n}\n");
    try std.testing.expect(s.spans.items.len > 0);
    s.setLanguage("/ws/notes.xyz");
    try s.refresh("plain");
    try std.testing.expectEqual(@as(usize, 0), s.spans.items.len);
    try std.testing.expectEqualStrings("make", keyForPath("/x/Makefile").?);
}
