//! The host's view of the integration manifest. The schema is the
//! SDK's (`sdk/mnml-sdk/src/manifest.zig`) so `<binary> --install` and
//! `integrations.refresh` agree on every field; this file names it for
//! the host and adds the parse the host does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");

pub const manifest = sdk.manifest;
pub const Manifest = manifest.Manifest;
pub const Mode = manifest.Mode;
pub const Chip = manifest.Chip;
pub const Command = manifest.Command;
pub const Setting = manifest.Setting;
pub const subdir = manifest.subdir;
pub const validateId = manifest.validateId;
pub const render = manifest.render;
pub const writeUnder = manifest.writeUnder;

pub const ParseError = error{ BadManifest, OutOfMemory };

/// One manifest file's text as a `Manifest` on `arena`. Unknown fields
/// are ignored so a newer SDK's manifest still loads. A diagnostic, when
/// there is one, is rendered onto `arena` for the toast.
pub fn parse(arena: Allocator, text: [:0]const u8, why: *[]const u8) ParseError!Manifest {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    const m = std.zon.parse.fromSliceAlloc(Manifest, arena, text, &diag, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            why.* = std.fmt.allocPrint(arena, "{f}", .{diag}) catch "parse error";
            return error.BadManifest;
        },
    };
    validateId(m.id) catch {
        why.* = "id must be a file name ([A-Za-z0-9_.-])";
        return error.BadManifest;
    };
    if (m.binary.len == 0) {
        why.* = "binary is empty";
        return error.BadManifest;
    }
    return m;
}

test "parse: a manifest with defaults, a bad one with a diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const m = try parse(arena, ".{ .id = \"jira\", .label = \"Jira\", .binary = \"mnml-jira\", .future_field = 1 }", &why);
    try std.testing.expectEqualStrings("jira", m.id);
    try std.testing.expectEqual(Mode.mount, m.mode);
    try std.testing.expectEqual(@as(usize, 0), m.commands.len);
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = \"a/b\", .label = \"x\", .binary = \"y\" }", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "file name") != null);
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = ", &why));
    try std.testing.expect(why.len > 0);
}
