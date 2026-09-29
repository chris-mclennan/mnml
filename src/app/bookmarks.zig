//! `bookmarks.open`: env-grouped web bookmarks, a picker whose Enter
//! hands the URL to the browser. The mechanism is mnml's — every
//! developer has dev / staging / prod sites — and the URLs are the
//! user's, in `<data root>/bookmarks.zon` and `<ws>/.mnml/bookmarks.zon`.
//! Both load and ADD UP: a repo's file extends your own set rather than
//! hiding it (a list, not a keyed record like the manifests).
//!
//! ```zig
//! .{
//!     .sites = .{
//!         // One destination in several environments: the three usual
//!         // names as fields, any other under `.envs`.
//!         .{ .name = "Admin console", .dev = "https://admin.dev.example.net", .prod = "https://admin.example.com", .envs = .{ .{ .env = "uat", .url = "https://admin.uat.example.net" } } },
//!     },
//!     .bookmarks = .{
//!         // A one-off; `.env` defaults to "other".
//!         .{ .label = "Metabase", .url = "https://metabase.example.net", .env = "prod" },
//!     },
//! }
//! ```
//!
//! A malformed file is skipped, not fatal — a typo must not stop mnml.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");

pub const table = .{
    .@"bookmarks.open" = &open,
};

pub const file_name = "bookmarks.zon";
/// The env of a `.bookmarks` entry that names none.
pub const default_env = "other";

/// One resolved, openable bookmark; all slices borrowed from the arena
/// `load` was given.
pub const Bookmark = struct { label: []const u8, url: []const u8, env: []const u8 };

const Stored = struct {
    sites: []const Site = &.{},
    bookmarks: []const Entry = &.{},

    const Site = struct {
        name: []const u8,
        dev: ?[]const u8 = null,
        staging: ?[]const u8 = null,
        prod: ?[]const u8 = null,
        envs: []const EnvUrl = &.{},
    };
    const EnvUrl = struct { env: []const u8, url: []const u8 };
    const Entry = struct { label: []const u8, url: []const u8, env: []const u8 = default_env };
};

/// The two files, in load order: the data root's, then the workspace's.
pub fn paths(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (app.data_root.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ app.data_root, file_name }));
    try out.append(arena, try std.fs.path.join(arena, &.{ app.workspace, ".mnml", file_name }));
    return out.items;
}

fn addSite(arena: Allocator, out: *std.ArrayListUnmanaged(Bookmark), name: []const u8, env: []const u8, url: ?[]const u8) Allocator.Error!void {
    const u = std.mem.trim(u8, url orelse return, " \t");
    if (u.len == 0) return;
    try out.append(arena, .{ .label = name, .url = u, .env = env });
}

/// Every bookmark for the workspace, file order, sites expanded env by
/// env (dev, staging, prod, then `.envs` as written). A missing or
/// malformed file contributes nothing.
pub fn load(app: *App, arena: Allocator) Allocator.Error![]const Bookmark {
    var out: std.ArrayListUnmanaged(Bookmark) = .empty;
    for (try paths(app, arena)) |p| {
        const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, p, arena, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const stored = std.zon.parse.fromSliceAlloc(Stored, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => continue,
        };
        for (stored.sites) |s| {
            try addSite(arena, &out, s.name, "dev", s.dev);
            try addSite(arena, &out, s.name, "staging", s.staging);
            try addSite(arena, &out, s.name, "prod", s.prod);
            for (s.envs) |e| try addSite(arena, &out, s.name, e.env, e.url);
        }
        for (stored.bookmarks) |b| try addSite(arena, &out, b.label, b.env, b.url);
    }
    return out.items;
}

/// `bookmarks.open`: the picker over every bookmark — `env  ·  label`,
/// the URL as the detail — or, with none defined, the file to write.
fn open(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const all = try load(app, arena);
    if (all.len == 0) {
        const p = try paths(app, arena);
        app.toast("no bookmarks yet — define them in {s}", .{p[0]});
        return;
    }
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (all) |b| {
        // The env on the label keeps a 3-env site's three rows tellable apart.
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  ·  {s}", .{ b.env, b.label }));
        try details.append(gpa, try gpa.dupe(u8, b.url));
    }
    try cmd_picker.openPickerWith(app, "Bookmarks", .bookmarks, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try t.allocator.dupe(u8, pbuf[0..try tmp.dir.realPath(t.io, &pbuf)]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "ws/.mnml");
        try tmp.dir.createDirPath(t.io, "data");
        const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
        defer t.allocator.free(ws);
        const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
        defer t.allocator.free(data);
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = data, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }
};

const home_file =
    \\.{
    \\    .sites = .{
    \\        .{ .name = "Admin", .dev = "https://admin.dev/x", .prod = "https://admin/x", .staging = "  ", .envs = .{ .{ .env = "uat", .url = "https://admin.uat/x" } } },
    \\    },
    \\}
;
const ws_file =
    \\.{
    \\    .bookmarks = .{
    \\        .{ .label = "Metabase", .url = "https://mb/", .env = "prod" },
    \\        .{ .label = "Plain", .url = "not-a-url" },
    \\    },
    \\}
;

test "bookmarks.open: the data root's file then the workspace's, sites expanded dev/staging/prod/envs, env on the label, the URL as the detail; Enter hands the URL to the opener; none defined names the file; a malformed file is skipped" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/bookmarks.zon", .data = home_file });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/bookmarks.zon", .data = ws_file });
    try command.run(&f.app, .{ .static = .@"bookmarks.open" });
    try t.expect(f.app.overlay == .picker);
    const p = &f.app.overlay.picker;
    try t.expect(p.kind == .bookmarks);
    try t.expectEqualStrings("Bookmarks", p.state.title);
    const want_labels = [_][]const u8{ "dev  ·  Admin", "prod  ·  Admin", "uat  ·  Admin", "prod  ·  Metabase", "other  ·  Plain" };
    const want_urls = [_][]const u8{ "https://admin.dev/x", "https://admin/x", "https://admin.uat/x", "https://mb/", "not-a-url" };
    try t.expectEqual(want_labels.len, p.labels.len);
    for (want_labels, want_urls, 0..) |l, u, i| {
        try t.expectEqualStrings(l, p.labels[i]);
        try t.expectEqualStrings(u, p.details[i]);
    }
    // Enter on the last row: the opener gets its URL — one it refuses
    // to spawn for, so the refusal is the proof it arrived.
    for (0..4) |_| try f.app.handle(.{ .key = app_mod.Key.named(.down) });
    try f.app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(f.app.overlay != .picker);
    try t.expectEqualStrings("not a web URL: not-a-url", f.app.lastToast().?);
    // The home file malformed: only the workspace's two remain.
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/bookmarks.zon", .data = ".{ .sites = " });
    try command.run(&f.app, .{ .static = .@"bookmarks.open" });
    try t.expect(f.app.overlay == .picker);
    try t.expectEqual(@as(usize, 2), f.app.overlay.picker.labels.len);
    try t.expectEqualStrings("prod  ·  Metabase", f.app.overlay.picker.labels[0]);
    f.app.overlay.deinit(f.app.gpa);
    f.app.overlay = .none;
    // Neither file: the toast names the data root's.
    var g = try Fixture.init();
    defer g.deinit();
    try command.run(&g.app, .{ .static = .@"bookmarks.open" });
    try t.expect(g.app.overlay != .picker);
    const want = try std.fs.path.join(t.allocator, &.{ g.root, "data", "bookmarks.zon" });
    defer t.allocator.free(want);
    const toast = g.app.lastToast().?;
    try t.expect(std.mem.startsWith(u8, toast, "no bookmarks yet — define them in "));
    try t.expect(std.mem.endsWith(u8, toast, want));
}
