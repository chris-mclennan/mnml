//! Config diagnostics — `file:line:col: message`, collected, never fatal.
//!
//! A bad layer file, a bad section, or a bad map entry each add one line
//! here and the loader carries on with everything else. The list lives
//! on the loader's arena; `format` renders it for a toast or stderr.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const Diagnostic = struct {
    file: []const u8,
    /// 1-based. 0 = no location (a file-level problem).
    line: u32 = 0,
    col: u32 = 0,
    msg: []const u8,

    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.line == 0) return w.print("{s}: {s}", .{ d.file, d.msg });
        try w.print("{s}:{d}:{d}: {s}", .{ d.file, d.line, d.col, d.msg });
    }
};

pub const Diagnostics = struct {
    arena: Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(arena: Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    pub fn count(self: Diagnostics) usize {
        return self.items.items.len;
    }

    /// `msg` is copied onto the arena; `file` is borrowed.
    pub fn add(self: *Diagnostics, file: []const u8, line: u32, col: u32, msg: []const u8) Allocator.Error!void {
        try self.items.append(self.arena, .{ .file = file, .line = line, .col = col, .msg = try self.arena.dupe(u8, msg) });
    }

    pub fn addFmt(self: *Diagnostics, file: []const u8, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.items.append(self.arena, .{ .file = file, .line = line, .col = col, .msg = try std.fmt.allocPrint(self.arena, fmt, args) });
    }

    /// Location of `token` in `ast`, 1-based.
    pub fn addAt(self: *Diagnostics, file: []const u8, ast: Ast, token: Ast.TokenIndex, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const loc = ast.tokenLocation(0, token);
        try self.addFmt(file, @intCast(loc.line + 1), @intCast(loc.column + 1), fmt, args);
    }

    /// One diagnostic per line.
    pub fn format(self: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.items.items) |d| {
            try d.format(w);
            try w.writeByte('\n');
        }
    }

    /// Everything on one line each, joined — for tests and toasts.
    pub fn render(self: Diagnostics, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        self.format(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

test "diagnostics render as file:line:col: msg" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d = Diagnostics.init(arena_state.allocator());
    try d.add("a.zon", 3, 7, "unknown field 'tab_widht'");
    try d.add("b.zon", 0, 0, "not found");
    const text = try d.render(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a.zon:3:7: unknown field 'tab_widht'\nb.zon: not found\n", text);
}
