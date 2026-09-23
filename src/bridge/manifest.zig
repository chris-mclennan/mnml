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
pub const validate = manifest.validate;
pub const parseCodepoint = manifest.parseCodepoint;
pub const render = manifest.render;
pub const writeUnder = manifest.writeUnder;

pub const ParseError = error{ BadManifest, OutOfMemory };

/// The fields `text` names that no manifest has — each one a typo or a
/// newer SDK's field, dropped by `parse` either way (`core/zon_fields.zig`).
pub fn unknownFields(arena: Allocator, text: [:0]const u8) Allocator.Error![]const []const u8 {
    return @import("../core/zon_fields.zig").unknown(Manifest, arena, text);
}

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
    // The SDK's rule, so `--install` and the scan refuse the same files.
    validate(m, why) catch return error.BadManifest;
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

test "parse: a launcher has no binary and a run line per command; neither is refused with the SDK's reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const m = try parse(arena, ".{ .id = \"htop\", .label = \"htop\", .chip = .{ .glyph_codepoint = \"F1D00\", .fallback = \"H\" }, .commands = .{ .{ .id = \"htop.open\", .title = \"htop: open\", .run = \":term htop\" } } }", &why);
    try std.testing.expect(m.isLauncher());
    try std.testing.expectEqualStrings(":term htop", m.commands[0].line().?);
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\u{F1D00}", m.chip.?.glyphText(&buf));
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = \"e\", .label = \"e\" }", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "no binary and no command") != null);
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = \"e\", .label = \"e\", .commands = .{ .{ .id = \"e.o\", .title = \"o\" } } }", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "run line") != null);
}
