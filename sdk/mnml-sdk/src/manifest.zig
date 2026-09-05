//! The integration manifest — what `<integration> --install` writes to
//! `<data root>/integrations/<id>.zon` and what mnml reads at startup
//! and on `integrations.refresh`. Uninstall is deleting the file; the
//! filesystem is the interface.
//!
//! `Manifest` is the ZON schema on both sides: the SDK serialises it
//! with `std.zon.stringify`, mnml parses it with `std.zon.parse`. Only
//! `id`, `label` and `binary` are required; the rest default.
//!
//! The data root is mnml's: `$MNML_DATA_ROOT`, else
//! `$XDG_CONFIG_HOME/mnml`, else `$HOME/.config/mnml`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How the binary opens when a command has no `ex` line: hosted over
/// the mount socket, or as a plain terminal pane.
pub const Mode = enum { mount, pty };

/// The rail / palette-bar chip. Display strings live on the manifest;
/// the chip is about rendering.
pub const Chip = struct {
    /// A Nerd Font glyph (or any short string).
    glyph: []const u8 = "",
    /// What paints when the glyph cannot: 1–3 plain characters.
    fallback: []const u8 = "",
    /// A theme colour name: red, orange, yellow, green, blue, cyan,
    /// teal, purple, pink, magenta, comment, fg. Unknown → the accent.
    color: []const u8 = "",
    tooltip: []const u8 = "",
    enabled: bool = true,
    in_palette_bar: bool = true,
};

pub const Command = struct {
    /// `<integration>.<verb>`; must not shadow a built-in.
    id: []const u8,
    title: []const u8,
    group: []const u8 = "integrations",
    /// Chords in mnml's spec grammar (`ctrl+k j`, `space i j`).
    keys: []const []const u8 = &.{},
    /// An ex line to run instead of opening the binary (`term foo --x`).
    ex: ?[]const u8 = null,
    /// Extra argv when the command opens the binary.
    args: []const []const u8 = &.{},
};

pub const ContextMenuEntry = struct {
    /// `tree.file` | `tree.dir` | `tab` | `pane`.
    target: []const u8,
    title: []const u8,
    command: []const u8,
};

pub const MenuBarEntry = struct {
    /// `File > Send via Slack`.
    path: []const u8,
    command: []const u8,
};

pub const StatuslineSegment = struct {
    id: []const u8,
    side: enum { left, right } = .right,
    text: []const u8 = "",
    color: ?[]const u8 = null,
    click_command: ?[]const u8 = null,
    priority: u8 = 100,
};

/// A discrete-choice row in mnml's settings overlay, under the
/// integration's name. The chosen value reaches the binary as
/// `MNML_SETTING_<KEY>` (upper-cased) and lives in
/// `<data root>/integration-settings.zon`.
pub const Setting = struct {
    key: []const u8,
    label: []const u8,
    options: []const []const u8,
    default: []const u8 = "",
    help: ?[]const u8 = null,
};

pub const AuthField = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { text, secret, url, email, number } = .text,
    env_fallback: ?[]const u8 = null,
    help_url: ?[]const u8 = null,
    help: ?[]const u8 = null,
    required: bool = false,
};

pub const ValuesSource = struct {
    id: []const u8,
    command: []const u8,
    poll_interval_secs: u32 = 300,
};

pub const Manifest = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    version: []const u8 = "",
    /// On PATH, or absolute.
    binary: []const u8,
    /// msg / forge / tracker / aws / db / …
    category: []const u8 = "",
    mode: Mode = .mount,
    /// Argv the binary always gets.
    args: []const []const u8 = &.{},
    chip: ?Chip = null,
    commands: []const Command = &.{},
    context_menu: []const ContextMenuEntry = &.{},
    menu_bar: []const MenuBarEntry = &.{},
    statusline: []const StatuslineSegment = &.{},
    settings: []const Setting = &.{},
    /// Environment variables that must be set; the chip dims otherwise.
    requires: []const []const u8 = &.{},
    auth: []const AuthField = &.{},
    values_sources: []const ValuesSource = &.{},
};

pub const IdError = error{InvalidId};

/// `[A-Za-z0-9_.-]+` — an id is a file name.
pub fn validateId(id: []const u8) IdError!void {
    if (id.len == 0 or id.len > 64) return error.InvalidId;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return error.InvalidId,
    };
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidId;
}

pub const subdir = "integrations";

/// mnml's data root under this environment.
pub fn dataRoot(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return try gpa.dupe(u8, root);
    if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |xdg| return try std.fs.path.join(gpa, &.{ xdg, "mnml" });
    if (nonEmpty(env.get("HOME"))) |home| return try std.fs.path.join(gpa, &.{ home, ".config", "mnml" });
    return null;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

pub const PathError = error{ NoHome, InvalidId } || Allocator.Error;

/// `<data root>/integrations/<id>.zon`, owned.
pub fn path(gpa: Allocator, env: *const std.process.Environ.Map, id: []const u8) PathError![]u8 {
    try validateId(id);
    const root = (try dataRoot(gpa, env)) orelse return error.NoHome;
    defer gpa.free(root);
    return pathUnder(gpa, root, id);
}

pub fn pathUnder(gpa: Allocator, root: []const u8, id: []const u8) PathError![]u8 {
    try validateId(id);
    const name = try std.fmt.allocPrint(gpa, "{s}.zon", .{id});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ root, subdir, name });
}

/// The manifest as ZON text, owned. Fields at their default are left
/// out, so the file reads as what the author chose.
pub fn render(gpa: Allocator, m: Manifest) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.writeAll("// Written by `") catch return error.OutOfMemory;
    out.writer.writeAll(m.binary) catch return error.OutOfMemory;
    out.writer.writeAll(" --install`; mnml reads it at startup and on integrations.refresh.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(m, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const WriteError = PathError || error{WriteFailed};

/// Write the manifest; returns the path written (owned).
pub fn write(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, m: Manifest) WriteError![]u8 {
    const root = (try dataRoot(gpa, env)) orelse return error.NoHome;
    defer gpa.free(root);
    return writeUnder(gpa, io, root, m);
}

pub fn writeUnder(gpa: Allocator, io: Io, root: []const u8, m: Manifest) WriteError![]u8 {
    const p = try pathUnder(gpa, root, m.id);
    errdefer gpa.free(p);
    const text = try render(gpa, m);
    defer gpa.free(text);
    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?) catch return error.WriteFailed;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch return error.WriteFailed;
    return p;
}

/// Delete the manifest. True when a file went; false when there was none.
pub fn remove(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8) (PathError || error{RemoveFailed})!bool {
    const p = try path(gpa, env, id);
    defer gpa.free(p);
    Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.RemoveFailed,
    };
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "ids are file names" {
    try validateId("jira");
    try validateId("mnml-forge-bitbucket.v2");
    try testing.expectError(error.InvalidId, validateId(""));
    try testing.expectError(error.InvalidId, validateId("a/b"));
    try testing.expectError(error.InvalidId, validateId(".."));
    try testing.expectError(error.InvalidId, validateId("sp ace"));
}

test "the data root follows MNML_DATA_ROOT, XDG, HOME" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try dataRoot(testing.allocator, &env)) == null);
    try env.put("HOME", "/h");
    const a = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/h/.config/mnml", a);
    try env.put("XDG_CONFIG_HOME", "/x");
    const b = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/x/mnml", b);
    try env.put("MNML_DATA_ROOT", "/r");
    const c = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("/r", c);
    const p = try path(testing.allocator, &env, "jira");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/r/integrations/jira.zon", p);
}

test "write renders ZON that parses back with the same shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const m: Manifest = .{
        .id = "hello",
        .label = "Hello",
        .description = "The sample integration",
        .version = "0.1.0",
        .binary = "mnml-hello",
        .chip = .{ .glyph = "\u{f0a7}", .fallback = "H", .color = "cyan" },
        .commands = &.{
            .{ .id = "hello.open", .title = "Hello: open", .keys = &.{"ctrl+k h"} },
            .{ .id = "hello.shell", .title = "Hello: shell", .ex = "term mnml-hello --shell" },
        },
        .settings = &.{.{ .key = "greeting", .label = "Greeting", .options = &.{ "hi", "hello" }, .default = "hi" }},
        .requires = &.{"HELLO_TOKEN"},
    };
    const p = try writeUnder(testing.allocator, testing.io, root, m);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.endsWith(u8, p, "/integrations/hello.zon"));
    const text = try Io.Dir.cwd().readFileAllocOptions(testing.io, p, testing.allocator, .unlimited, .of(u8), 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "// Written by `mnml-hello --install`"));
    try testing.expect(std.mem.indexOf(u8, text, ".mode") == null); // a default is not written
    // Parsed on an arena: `std.zon.parse.free` would try to free the
    // literal a defaulted field points at.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena_state.allocator());
    const back = try std.zon.parse.fromSliceAlloc(Manifest, arena_state.allocator(), text, &diag, .{ .free_on_error = false });
    try testing.expectEqualStrings("hello", back.id);
    try testing.expectEqual(Mode.mount, back.mode);
    try testing.expectEqualStrings("cyan", back.chip.?.color);
    try testing.expect(back.chip.?.enabled);
    try testing.expectEqual(@as(usize, 2), back.commands.len);
    try testing.expectEqualStrings("ctrl+k h", back.commands[0].keys[0]);
    try testing.expectEqualStrings("term mnml-hello --shell", back.commands[1].ex.?);
    try testing.expectEqualStrings("hello", back.settings[0].options[1]);
    try testing.expectEqualStrings("HELLO_TOKEN", back.requires[0]);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    try testing.expect(try remove(testing.allocator, testing.io, &env, "hello"));
    try testing.expect(!try remove(testing.allocator, testing.io, &env, "hello"));
}
