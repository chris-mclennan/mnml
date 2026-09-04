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
const Theme = @import("../ui/theme.zig");

pub const Span = editor_view.Span;
pub const Style = color.Style;

/// Capture name prefix → the theme's syntax role. First match wins, so
/// `function.method` lands on `function`.
const roles = [_]struct { []const u8, []const u8 }{
    .{ "comment", "comment" },
    .{ "string", "string" },
    .{ "keyword", "keyword" },
    .{ "function", "function" },
    .{ "method", "function" },
    .{ "type", "type" },
    .{ "constructor", "constructor" },
    .{ "number", "number" },
    .{ "constant", "constant" },
    .{ "boolean", "constant" },
    .{ "operator", "operator" },
    .{ "punctuation", "punctuation" },
    .{ "property", "property" },
    .{ "attribute", "attribute" },
    .{ "variable", "variable" },
    .{ "tag", "tag" },
    .{ "label", "label" },
    .{ "namespace", "namespace" },
    .{ "module", "namespace" },
    .{ "text", "text" },
    .{ "markup", "text" },
    .{ "escape", "escape" },
    .{ "embedded", "text" },
};

pub fn styleForCapture(name: []const u8, t: *const Theme) ?Style {
    inline for (roles) |r| {
        if (std.mem.startsWith(u8, name, r[0])) return @field(t.syntax, r[1]);
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

    /// Re-parse `text` and rebuild the spans in `t`'s colours. Spans are
    /// sorted by start, innermost capture last so a later (more specific)
    /// capture wins. A theme switch re-runs this on every pane.
    pub fn refresh(self: *Syntax, text: []const u8, t: *const Theme) Allocator.Error!void {
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
                const style = styleForCapture(name, t) orelse continue;
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
    try s.refresh("fn main() {\n    let s = \"hi\";\n}\n", &Theme.default);
    try std.testing.expect(s.spans.items.len > 0);
    s.setLanguage("/ws/notes.xyz");
    try s.refresh("plain", &Theme.default);
    try std.testing.expectEqual(@as(usize, 0), s.spans.items.len);
    try std.testing.expectEqualStrings("make", keyForPath("/x/Makefile").?);
}
