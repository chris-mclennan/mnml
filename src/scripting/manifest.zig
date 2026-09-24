//! `script.zon` — the manifest of an installed script (the directory
//! form, §3 of `docs/research/lua-platform-design-2026-09-13.md`).
//!
//! A script is a directory under `<data root>/scripts/<name>/` holding
//! `script.zon`, `init.lua`, optional `lib/*.lua` and a `README.md`.
//! The manifest is what the SCRIPTS panel's rows read and what the
//! trust dialog shows BEFORE the first run: the commands it says it
//! adds, the hooks it says it subscribes, where it came from.
//!
//! `api` is the contract: the `mnml` table as `docs/LUA.md` documents
//! it for that number. A manifest without one is refused (it predates
//! the contract and we cannot tell what it expects); one asking for a
//! number this build does not know is refused too, with its own row in
//! the panel rather than a silent skip.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The `mnml` table this build implements. A manifest may name this or
/// anything lower; anything higher is a script written for a newer
/// mnml.
pub const api_version: u32 = 1;

/// The manifest's file name inside the script directory.
pub const file_name = "script.zon";
/// The entry chunk.
pub const entry_file = "init.lua";
/// The directory a scoped `require` resolves under.
pub const lib_dir = "lib";
/// The readme a row's Enter opens.
pub const readme_file = "README.md";
/// The directory installed scripts live in, under the data root.
pub const subdir = "scripts";

/// Where a script came from — the row's badge and the panel's filter.
pub const Source = enum {
    /// The curated set that ships with mnml (this repo's `lua/`), or a
    /// folder `scripts.marketplace_local` names — badge `official`.
    marketplace,
    /// A git URL or an archive the user installed by hand.
    community,
    /// A source the user configured (`scripts.private_sources`).
    private,
    /// A folder under `scripts.dev_roots`, edited live.
    dev,

    /// The badge's word.
    pub fn badge(s: Source) []const u8 {
        return switch (s) {
            .marketplace => "official",
            .community => "community",
            .private => "private",
            .dev => "dev",
        };
    }
};

pub const Manifest = struct {
    /// The directory name and the script's identity; `[A-Za-z0-9_-]`.
    name: []const u8 = "",
    version: []const u8 = "0.0.0",
    /// The `mnml` table the script was written against. 0 means the
    /// key was missing, which is refused.
    api: u32 = 0,
    description: []const u8 = "",
    author: []const u8 = "",
    /// The command ids it registers — `user.<id>`, or `<id>` written
    /// bare; the trust dialog lists them as they are written.
    commands: []const []const u8 = &.{},
    /// The hook names it subscribes (`save_post`, `cursor_idle`, …).
    hooks: []const []const u8 = &.{},
    source: Source = .community,
    /// Where it was installed from, verbatim — a git URL, an archive
    /// path, a folder.
    url: []const u8 = "",

    /// Whether this build can run it: the manifest names an api this
    /// build implements.
    pub fn supported(m: Manifest) bool {
        return m.api >= 1 and m.api <= api_version;
    }
};

pub const ParseError = error{ BadManifest, OutOfMemory };

/// The fields `text` names that `script.zon` has no place for — a typo
/// or a later mnml's field, dropped by `parse` either way
/// (`core/zon_fields.zig`).
pub fn unknownFields(arena: Allocator, text: [:0]const u8) Allocator.Error![]const []const u8 {
    return @import("../core/zon_fields.zig").unknown(Manifest, arena, text);
}

/// `script.zon`'s text as a `Manifest` on `arena`. Unknown fields are
/// ignored so a manifest written for a later mnml still reads far
/// enough to say so. A diagnostic lands in `why`.
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
    try validate(m, why);
    return m;
}

/// Everything a manifest must say before the script is a row at all.
/// An `api` this build does not know is NOT an error here — the row
/// exists and says so (`Manifest.supported`).
pub fn validate(m: Manifest, why: *[]const u8) error{BadManifest}!void {
    if (m.name.len == 0) {
        why.* = "script.zon: no .name";
        return error.BadManifest;
    }
    if (!validName(m.name)) {
        why.* = "script.zon: .name must be a plain folder name (letters, digits, `-`, `_`)";
        return error.BadManifest;
    }
    if (m.api == 0) {
        why.* = "script.zon: no .api — every manifest declares the mnml table it was written for (`.api = 1`)";
        return error.BadManifest;
    }
}

/// A name that is safe as a directory and as a Lua chunk label: no
/// separators, no dots, no leading dash.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-') return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// The manifest text a `script.install` writes beside a copied
/// directory that had none, and what `docs/LUA.md` shows.
pub fn render(w: *std.Io.Writer, m: Manifest) std.Io.Writer.Error!void {
    try w.print(".{{\n    .name = \"{s}\",\n    .version = \"{s}\",\n    .api = {d},\n", .{ m.name, m.version, m.api });
    try w.print("    .description = \"{s}\",\n    .author = \"{s}\",\n", .{ m.description, m.author });
    try w.writeAll("    .commands = .{");
    for (m.commands, 0..) |c, i| try w.print("{s} \"{s}\"{s}", .{ if (i == 0) "" else ",", c, if (i + 1 == m.commands.len) " " else "" });
    try w.writeAll("},\n    .hooks = .{");
    for (m.hooks, 0..) |h, i| try w.print("{s} \"{s}\"{s}", .{ if (i == 0) "" else ",", h, if (i + 1 == m.hooks.len) " " else "" });
    try w.print("}},\n    .source = .{t},\n    .url = \"{s}\",\n}}\n", .{ m.source, m.url });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "parse: every field, defaults, and an unknown key ignored" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const m = try parse(arena,
        \\.{
        \\    .name = "git-blame-line",
        \\    .version = "1.2.0",
        \\    .api = 1,
        \\    .description = "Blame the cursor line",
        \\    .author = "mnml",
        \\    .commands = .{ "user.blame_toggle" },
        \\    .hooks = .{ "cursor_idle", "pane_focus" },
        \\    .source = .marketplace,
        \\    .url = "https://example.invalid/mnml-scripts",
        \\    .future_key = 7,
        \\}
    , &why);
    try t.expectEqualStrings("git-blame-line", m.name);
    try t.expectEqualStrings("1.2.0", m.version);
    try t.expectEqual(@as(u32, 1), m.api);
    try t.expectEqualStrings("Blame the cursor line", m.description);
    try t.expectEqualStrings("mnml", m.author);
    try t.expectEqual(@as(usize, 1), m.commands.len);
    try t.expectEqualStrings("user.blame_toggle", m.commands[0]);
    try t.expectEqual(@as(usize, 2), m.hooks.len);
    try t.expectEqualStrings("pane_focus", m.hooks[1]);
    try t.expectEqual(Source.marketplace, m.source);
    try t.expectEqualStrings("https://example.invalid/mnml-scripts", m.url);
    try t.expect(m.supported());
    try t.expectEqualStrings("official", m.source.badge());

    // The defaults: version, description, author, lists, source, url.
    const d = try parse(arena, ".{ .name = \"x\", .api = 1 }", &why);
    try t.expectEqualStrings("0.0.0", d.version);
    try t.expectEqualStrings("", d.description);
    try t.expectEqualStrings("", d.author);
    try t.expectEqual(@as(usize, 0), d.commands.len);
    try t.expectEqual(@as(usize, 0), d.hooks.len);
    try t.expectEqual(Source.community, d.source);
    try t.expectEqualStrings("", d.url);
}

test "parse: a missing api is refused; a higher one parses but is unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    try t.expectError(error.BadManifest, parse(arena, ".{ .name = \"x\" }", &why));
    try t.expect(std.mem.indexOf(u8, why, ".api") != null);
    // Higher than this build: a row that says so, not a parse error.
    const newer = try parse(arena, ".{ .name = \"x\", .api = 99 }", &why);
    try t.expect(!newer.supported());
    try t.expectEqual(@as(u32, 99), newer.api);
    // And the one this build knows is supported.
    const now = try parse(arena, ".{ .name = \"x\", .api = 1 }", &why);
    try t.expect(now.supported());
    try t.expectEqual(api_version, now.api);
}

test "parse: no name, a name with a separator, a broken file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    try t.expectError(error.BadManifest, parse(arena, ".{ .api = 1 }", &why));
    try t.expect(std.mem.indexOf(u8, why, "no .name") != null);
    try t.expectError(error.BadManifest, parse(arena, ".{ .name = \"a/b\", .api = 1 }", &why));
    try t.expect(std.mem.indexOf(u8, why, "plain folder name") != null);
    try t.expectError(error.BadManifest, parse(arena, ".{ .name = \"..\", .api = 1 }", &why));
    try t.expectError(error.BadManifest, parse(arena, ".{ .name = ", &why));
    try t.expect(why.len > 0);
    // The name rule itself.
    try t.expect(validName("todo-list") and validName("a_1"));
    try t.expect(!validName("") and !validName("../x") and !validName("a.b") and !validName("-x"));
}

test "render round-trips through parse" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w, .{
        .name = "todo-list",
        .version = "0.1.0",
        .api = 1,
        .description = "TODOs in a list pane",
        .author = "mnml",
        .commands = &.{ "user.todos", "user.todos_refresh" },
        .hooks = &.{"save_post"},
        .source = .dev,
        .url = "/tmp/dev/todo-list",
    });
    const text = try arena.dupeZ(u8, w.buffered());
    var why: []const u8 = "";
    const m = try parse(arena, text, &why);
    try t.expectEqualStrings("todo-list", m.name);
    try t.expectEqual(@as(usize, 2), m.commands.len);
    try t.expectEqualStrings("user.todos_refresh", m.commands[1]);
    try t.expectEqual(@as(usize, 1), m.hooks.len);
    try t.expectEqual(Source.dev, m.source);
    try t.expectEqualStrings("/tmp/dev/todo-list", m.url);
}
