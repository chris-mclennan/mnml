//! The host's view of the integration manifest. The schema is the
//! SDK's (`sdk/mnml-sdk/src/manifest.zig`) so `<binary> --install` and
//! `integrations.refresh` agree on every field; this file names it for
//! the host and adds the parse the host does.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
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
pub const renderUnstamped = manifest.renderUnstamped;
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
    var diag: []const u8 = "";
    const m = compat.zonParse(Manifest, arena, text, &diag, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => legacy(arena, text) orelse {
            why.* = (if (diag.len == 0) "parse error" else diag);
            return error.BadManifest;
        },
    };
    // The SDK's rule, so `--install` and the scan refuse the same files.
    validate(m, why) catch return error.BadManifest;
    return m;
}

/// A `context_menu[]` row as an older SDK wrote it: a bare string
/// `target` (`tree.file`) and a `title`.
const LegacyEntry = struct { target: []const u8, title: []const u8 = "", label: []const u8 = "", command: []const u8 };

/// `Manifest` with its `context_menu` rows in the older shape.
const LegacyManifest = blk: {
    const fields = @typeInfo(Manifest).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    const empty: []const LegacyEntry = &.{};
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        const swap = std.mem.eql(u8, f.name, "context_menu");
        types[i] = if (swap) []const LegacyEntry else f.type;
        attrs[i] = .{ .default_value_ptr = if (swap) @ptrCast(&empty) else f.default_value_ptr };
    }
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

/// `text` read in the older `context_menu` shape and lifted into a
/// `Manifest`, so a manifest an older SDK wrote still loads; null when
/// it does not parse that way either.
fn legacy(arena: Allocator, text: [:0]const u8) ?Manifest {
    const old = compat.zonParse(LegacyManifest, arena, text, null, .{ .ignore_unknown_fields = true }) catch return null;
    var m: Manifest = undefined;
    inline for (@typeInfo(Manifest).@"struct".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, "context_menu")) @field(m, f.name) = @field(old, f.name);
    }
    const rows = arena.alloc(manifest.ContextMenuEntry, old.context_menu.len) catch return null;
    for (old.context_menu, rows) |o, *r| r.* = .{ .target = .{ .kind = o.target }, .label = o.label, .title = o.title, .command = o.command };
    m.context_menu = rows;
    return m;
}

test "parse: an older manifest's string-target context_menu still loads; the new shape carries label, when and hover" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const old = try parse(arena, ".{ .id = \"s\", .label = \"S\", .binary = \"b\", .context_menu = .{ .{ .target = \"tree.file\", .title = \"Hello\", .command = \"s.hello\" } } }", &why);
    try std.testing.expectEqualStrings("tree.file", old.context_menu[0].target.kind);
    try std.testing.expectEqualStrings("Hello", old.context_menu[0].text());
    try std.testing.expectEqualStrings("b", old.binary);
    const new = try parse(arena, ".{ .id = \"s\", .label = \"S\", .binary = \"b\", .context_menu = .{ .{ .target = .{ .kind = \"pr\" }, .label = \"Watch\", .command = \"s.w\", .when = \"state=OPEN\", .hover = \"Watches it\" } } }", &why);
    try std.testing.expectEqualStrings("pr", new.context_menu[0].target.kind);
    try std.testing.expectEqualStrings("state=OPEN", new.context_menu[0].when.?);
    try std.testing.expectEqualStrings("Watches it", new.context_menu[0].hover.?);
    // A kind no host knows is refused with the SDK's reason, either shape.
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = \"s\", .label = \"S\", .binary = \"b\", .context_menu = .{ .{ .target = .{ .kind = \"issue\" }, .label = \"x\", .command = \"s.x\" } } }", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "target kind") != null);
    try std.testing.expectError(error.BadManifest, parse(arena, ".{ .id = \"s\", .label = \"S\", .binary = \"b\", .context_menu = .{ .{ .target = \"issue\", .title = \"x\", .command = \"s.x\" } } }", &why));
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
