//! The pane's own state between runs — `<config dir>/state.zon`, beside
//! `config.zon` and never the same file: the config is the reference's
//! keys by name, hand-edited and rewritten whole by the keys that
//! persist (`x` / `H` / `s` / `alt+↑↓`); this is what the toolbar's
//! chips were set to, per tab, so a Status or an Author chosen today
//! is still chosen tomorrow. Nothing here is worth a request: a state
//! file that cannot be read is an empty one.
//!
//! ```
//! .{ .tabs = .{
//!     .{ .name = "Open + Draft", .open = true, .draft = true, .merged = false, .declined = false,
//!        .author_kind = .named, .author = "Dana R", .target = "main", .show = .reviewing },
//!     .{ .name = "Pipelines", .run_by = "", .branch = "main", .ptype = "", .pstatus = "failed", .trigger = "" },
//! } }
//! ```
//!
//! Tabs are keyed by name — the one thing a config tab always has —
//! and every field has a default, so a file from an older pane still
//! reads and a tab the file does not name starts on its kind's own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const filters = @import("filters.zig");

pub const file_name = "state.zon";

pub const AuthorKind = enum { all, me, named };

/// One tab's chips, in the file's shape: flat scalars only, so the
/// ZON both parses and serializes without a union in it.
pub const Entry = struct {
    name: []const u8 = "",
    open: bool = true,
    draft: bool = true,
    merged: bool = false,
    declined: bool = false,
    author_kind: AuthorKind = .all,
    author: []const u8 = "",
    target: []const u8 = "",
    show: filters.Show = .all,
    run_by: []const u8 = "",
    branch: []const u8 = "",
    ptype: []const u8 = "",
    pstatus: []const u8 = "",
    trigger: []const u8 = "",

    /// The entry a tab's live filters serialize to.
    pub fn fromFilters(name: []const u8, f: filters.Filters) Entry {
        return .{
            .name = name,
            .open = f.status.open,
            .draft = f.status.draft,
            .merged = f.status.merged,
            .declined = f.status.declined,
            .author_kind = switch (f.author) {
                .all => .all,
                .me => .me,
                .named => .named,
            },
            .author = switch (f.author) {
                .named => |n| n,
                else => "",
            },
            .target = f.target,
            .show = f.show,
            .run_by = f.run_by,
            .branch = f.branch,
            .ptype = f.ptype,
            .pstatus = f.pstatus,
            .trigger = f.trigger,
        };
    }

    /// The live filters an entry stands for. Strings point into the
    /// entry; the caller copies what it keeps.
    pub fn toFilters(e: Entry) filters.Filters {
        return .{
            .status = .{ .open = e.open, .draft = e.draft, .merged = e.merged, .declined = e.declined },
            .author = switch (e.author_kind) {
                .all => .all,
                .me => .me,
                .named => if (e.author.len > 0) .{ .named = e.author } else .all,
            },
            .target = e.target,
            .show = e.show,
            .run_by = e.run_by,
            .branch = e.branch,
            .ptype = e.ptype,
            .pstatus = e.pstatus,
            .trigger = e.trigger,
        };
    }
};

pub const State = struct {
    tabs: []const Entry = &.{},

    pub fn entryFor(s: State, name: []const u8) ?Entry {
        for (s.tabs) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

/// `<dir of config.zon>/state.zon`, owned.
pub fn pathBeside(gpa: Allocator, config_path: []const u8) Allocator.Error![]u8 {
    const dir = std.fs.path.dirname(config_path) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, file_name });
}

pub fn parseText(arena: Allocator, text: [:0]const u8) !State {
    return @import("mnml_sdk").zig_compat.zonParse(State, arena, text, null, .{});
}

/// The file's contents, on `arena`; an empty state when there is no
/// file or it does not read. A state file is a convenience, never a
/// reason the pane does not open.
pub fn load(arena: Allocator, io: Io, path: []const u8) State {
    const text = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch return .{};
    return parseText(arena, text) catch .{};
}

pub fn render(gpa: Allocator, s: State) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.writeAll("// mnml-bitbucket — the toolbar's chips per tab, rewritten by the pane; see the README.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(s, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Write the whole file from `s`.
pub fn save(gpa: Allocator, io: Io, path: []const u8, s: State) !void {
    const text = try render(gpa, s);
    defer gpa.free(text);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a tab's filters round-trip through the file, field for field, and an unnamed tab starts on defaults" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(config_path);
    const path = try pathBeside(t.allocator, config_path);
    defer t.allocator.free(path);
    try t.expect(std.mem.endsWith(u8, path, "state.zon"));

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // No file yet: an empty state, not an error.
    try t.expectEqual(@as(usize, 0), load(arena.allocator(), t.io, path).tabs.len);

    var open: filters.Filters = .{};
    open.status.toggle(.merged);
    open.author = .{ .named = "Dana R" };
    open.target = "main";
    open.show = .reviewing;
    const pipes: filters.Filters = .{ .branch = "main", .pstatus = "failed", .trigger = "schedule" };
    const mine: filters.Filters = .{ .author = .me };
    try save(t.allocator, t.io, path, .{ .tabs = &.{
        Entry.fromFilters("Open + Draft", open),
        Entry.fromFilters("Pipelines", pipes),
        Entry.fromFilters("Mine", mine),
    } });

    const back = load(arena.allocator(), t.io, path);
    try t.expectEqual(@as(usize, 3), back.tabs.len);
    const o = back.entryFor("Open + Draft").?.toFilters();
    try t.expect(o.status.eql(.{ .merged = true }));
    try t.expect(o.author == .named);
    try t.expectEqualStrings("Dana R", o.author.named);
    try t.expectEqualStrings("main", o.target);
    try t.expectEqual(filters.Show.reviewing, o.show);
    const p = back.entryFor("Pipelines").?.toFilters();
    try t.expectEqualStrings("main", p.branch);
    try t.expectEqualStrings("failed", p.pstatus);
    try t.expectEqualStrings("schedule", p.trigger);
    try t.expectEqualStrings("", p.run_by);
    try t.expect(back.entryFor("Mine").?.toFilters().author == .me);
    try t.expect(back.entryFor("Merged") == null);
    // A `named` with no name is nobody: it reads back as `all`.
    try t.expect((Entry{ .author_kind = .named, .author = "" }).toFilters().author == .all);
}

test "a file from an older pane, or a hand-edited one missing fields, still reads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try parseText(arena.allocator(), ".{ .tabs = .{ .{ .name = \"Open + Draft\", .merged = true } } }");
    const f = s.entryFor("Open + Draft").?.toFilters();
    try t.expect(f.status.open and f.status.draft and f.status.merged and !f.status.declined);
    try t.expect(f.author == .all);
    try t.expectEqual(filters.Show.all, f.show);
    // Not ZON at all: nothing, rather than a pane that will not open.
    if (parseText(arena.allocator(), "not zon {")) |_| return error.TestExpectedError else |_| {}
}
