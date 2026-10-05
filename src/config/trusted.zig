//! The trust store: `<data root>/trusted_workspaces.zon`, one line per
//! workspace the user has said yes to —
//!
//!     .{
//!         .@"/Users/me/proj" = "3f2a9c0e11d4b7a8",
//!     }
//!
//! keyed by the canonical workspace path, valued by the fingerprint of
//! the exec-bearing claims that were shown (`trust.fingerprintHex`). A
//! workspace whose claims change stops matching and is asked again;
//! ordinary edits to its config leave the fingerprint alone.
//!
//! Reads go through the same Zoir walk as a config layer; writes go
//! through `persist.persistScalar`, so the file keeps any comments the
//! user adds and is backed up like the config is.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const decode = @import("decode.zig");
const diag = @import("diag.zig");
const persist = @import("persist.zig");
const Map = @import("map.zig").Map;

pub const store_file = "trusted_workspaces.zon";

pub fn storePath(alloc: Allocator, data_root: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ data_root, store_file });
}

/// The remembered fingerprint for `workspace`, or null: never trusted,
/// or the store is missing / unreadable (an unreadable store trusts
/// nobody).
pub fn lookup(gpa: Allocator, io: Io, path: []const u8, workspace: []const u8) Allocator.Error!?u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const entries = (try parse(arena, src)) orelse return null;
    const hex = entries.get(workspace) orelse return null;
    return std.fmt.parseInt(u64, hex, 16) catch null;
}

/// Record `fingerprint` for `workspace`, creating the store if needed.
pub fn remember(gpa: Allocator, io: Io, path: []const u8, workspace: []const u8, fingerprint: u64) persist.PersistError!void {
    var lit: [18]u8 = undefined;
    _ = std.fmt.bufPrint(&lit, "\"{x:0>16}\"", .{fingerprint}) catch unreachable;
    _ = try persist.persistScalar(gpa, io, path, &.{workspace}, &lit);
}

fn parse(arena: Allocator, src: [:0]const u8) Allocator.Error!?Map([]const u8) {
    const ast = try compat.parseZonAst(arena, src);
    if (ast.errors.len != 0) return null;
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    if (zoir.hasCompileErrors()) return null;
    var diags = diag.Diagnostics.init(arena);
    var ctx: decode.Context = .{ .arena = arena, .ast = ast, .zoir = zoir, .diags = &diags, .file = store_file };
    return decode.decode(Map([]const u8), &ctx, .root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => return null,
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "remember / lookup round-trip; a changed fingerprint no longer matches; a bad store trusts nobody" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    const path = try storePath(t.allocator, root);
    defer t.allocator.free(path);

    try t.expect((try lookup(t.allocator, t.io, path, "/w/a")) == null); // no store yet
    try remember(t.allocator, t.io, path, "/w/a", 0x0123456789abcdef);
    try remember(t.allocator, t.io, path, "/w/b c", 0xffff);
    try t.expectEqual(@as(?u64, 0x0123456789abcdef), try lookup(t.allocator, t.io, path, "/w/a"));
    try t.expectEqual(@as(?u64, 0xffff), try lookup(t.allocator, t.io, path, "/w/b c"));
    try t.expect((try lookup(t.allocator, t.io, path, "/w/z")) == null);
    // re-remembering replaces in place
    try remember(t.allocator, t.io, path, "/w/a", 1);
    try t.expectEqual(@as(?u64, 1), try lookup(t.allocator, t.io, path, "/w/a"));
    const text = try tmp.dir.readFileAlloc(t.io, store_file, t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings(".{\n    .@\"/w/a\" = \"0000000000000001\",\n    .@\"/w/b c\" = \"000000000000ffff\",\n}\n", text);
    // a store that does not parse trusts nobody
    try tmp.dir.writeFile(t.io, .{ .sub_path = store_file, .data = ".{ oops" });
    try t.expect((try lookup(t.allocator, t.io, path, "/w/a")) == null);
}
