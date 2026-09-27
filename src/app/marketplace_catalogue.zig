//! The `mnml` source — the catalogue of integrations this checkout
//! builds. The Marketplace tab's default source for a released mnml is
//! its release index (`marketplace_release.zig`); a dev build, which has
//! no release, lists this instead, and a catalogue row the index also
//! lists is dropped in favour of the index's download.
//!
//! The catalogue is one ZON file, `data/marketplace.zon` in the repo,
//! packaged as `share/mnml/marketplace.zon` beside the binary the way
//! `lua/` ships as `share/mnml/lua` (`app/scripts.zig`'s `shippedRoot`
//! is the same ladder). One entry per BINARY, not per manifest:
//! `mnml-jira --install` writes three manifests, so Jira is one row
//! here and three chips once installed.
//!
//! Install is `<binary> --install` — the binary already exists, so
//! there is nothing to build or download — plus the link that makes it
//! reachable:
//!
//!   `<data root>/bin/<name>`  →  the first `<name>` on PATH
//!                                (`<PREFIX>/bin/<name>` after
//!                                `run.sh install`), else
//!                                `<repo>/zig-out/bin/<name>` in a dev
//!                                checkout.
//!
//! The manifest itself keeps the bare name `--install` writes, and
//! `integrations.resolveBinary` prefers `<data root>/bin/<name>` over
//! PATH — so a manifest never hardcodes a repo path, and a rebuild in
//! the checkout never moves the binary out from under a running stable
//! copy. `run.sh install` relinks the same file for the same reason.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const data_root_mod = @import("../config/data_root.zig");
const build_options = @import("build_options");

/// The chip a catalogue row paints before anything is installed. A
/// subset of the manifest's `Chip` — the catalogue never registers
/// anything, so only what the row draws is here.
pub const Chip = struct {
    glyph: []const u8 = "",
    glyph_codepoint: []const u8 = "",
    fallback: []const u8 = "",
    color: []const u8 = "",
};

/// One catalogue row.
pub const Entry = struct {
    /// The row's id — a file name, and the id a `revealInMarketplace`
    /// carries. NOT a manifest id: one binary may write several.
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    category: []const u8 = "",
    /// What the installed manifests will say. An installed manifest at
    /// a lower version makes the row `update`.
    version: []const u8 = "",
    /// The binary's name (`mnml-jira`), or `$VAR` / an absolute path —
    /// the corpus points an entry at a prebuilt binary that way.
    binary: []const u8,
    docs: []const u8 = "",
    chip: ?Chip = null,
};

pub const Catalogue = struct {
    entries: []const Entry = &.{},
};

pub const ParseError = error{ BadCatalogue, OutOfMemory };

/// The catalogue's text as a `Catalogue` on `arena`. Unknown fields are
/// ignored so an older mnml still reads a newer file.
pub fn parse(arena: Allocator, text: [:0]const u8, why: *[]const u8) ParseError!Catalogue {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    const c = std.zon.parse.fromSliceAlloc(Catalogue, arena, text, &diag, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            why.* = std.fmt.allocPrint(arena, "{f}", .{diag}) catch "parse error";
            return error.BadCatalogue;
        },
    };
    for (c.entries) |e| {
        if (!safeId(e.id)) {
            why.* = std.fmt.allocPrint(arena, "{s}: an entry id must be a file name ([A-Za-z0-9_.-])", .{e.id}) catch "bad id";
            return error.BadCatalogue;
        }
        if (e.binary.len == 0) {
            why.* = std.fmt.allocPrint(arena, "{s}: no binary — every catalogue entry names one", .{e.id}) catch "no binary";
            return error.BadCatalogue;
        }
    }
    return c;
}

fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return !std.mem.eql(u8, id, ".") and !std.mem.eql(u8, id, "..");
}

pub const file_name = "marketplace.zon";

/// Where the catalogue is, tried in order — the ladder `lua/` uses:
///
///   1. `build_path` — `build_options.marketplace_catalogue`, the
///      checkout's own `data/marketplace.zon` baked in at build time,
///      so a dev build lists the shipped set with no config at all;
///   2. `<exe dir>/../share/mnml/marketplace.zon` — the `.deb` / `.rpm`
///      layout (`/usr/bin/mnml` + `/usr/share/…`);
///   3. `<exe dir>/share/mnml/marketplace.zon` — the archive layout;
///   4. `<exe dir>/mnml-data/marketplace.zon` — the portable directory.
///
/// Null when none is there (a bare binary copied out of its package).
/// `build_path` and `exe_dir` are values so a test can hand in a
/// sandbox rather than depend on where it is running.
pub fn find(io: Io, arena: Allocator, build_path: []const u8, exe_dir: ?[]const u8) Allocator.Error!?[]const u8 {
    if (build_path.len > 0 and isFile(io, build_path)) return build_path;
    const dir = exe_dir orelse return null;
    const candidates = [_][]const []const u8{
        &.{ dir, "..", "share", "mnml", file_name },
        &.{ dir, "share", "mnml", file_name },
        &.{ dir, data_root_mod.portable_dir, file_name },
    };
    for (candidates) |parts| {
        const p = std.fs.path.resolve(arena, parts) catch continue;
        if (isFile(io, p)) return p;
    }
    return null;
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file or st.kind == .sym_link;
}

/// The checkout a catalogue came from — `<catalogue>/../..`, when that
/// holds a `zig-out/bin`. Empty for a packaged catalogue, whose
/// `share/mnml/marketplace.zon` has no such parent. This is what makes
/// a dev build link to the binaries it just built.
pub fn repoOf(io: Io, arena: Allocator, catalogue_path: []const u8) Allocator.Error![]const u8 {
    const data_dir = std.fs.path.dirname(catalogue_path) orelse return "";
    const repo = std.fs.path.dirname(data_dir) orelse return "";
    const bin = try std.fs.path.join(arena, &.{ repo, "zig-out", "bin" });
    var d = Io.Dir.cwd().openDir(io, bin, .{}) catch return "";
    d.close(io);
    return repo;
}

/// The binary's file name on this platform (`.exe` on Windows).
pub fn exeName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (builtin.os.tag != .windows) return name;
    if (std.mem.endsWith(u8, name, ".exe")) return name;
    return std.fmt.allocPrint(arena, "{s}.exe", .{name});
}

/// What `<data root>/bin/<name>` should point at, in order:
///
///   1. `binary` itself when it is already a path (an absolute one, or
///      a `$VAR` the caller expanded) and it exists;
///   2. the first `<dir>/<name>` on `path_var` that is not the link
///      under `data_root` — `<PREFIX>/bin/<name>` after `run.sh install`;
///   3. `<repo>/zig-out/bin/<name>` — a dev checkout's own build.
///
/// Null when the binary is nowhere: nothing to link, and the install
/// says so rather than leaving a dangling link behind.
pub fn linkTarget(
    io: Io,
    arena: Allocator,
    binary: []const u8,
    path_var: []const u8,
    data_root: []const u8,
    repo: []const u8,
) Allocator.Error!?[]const u8 {
    if (std.fs.path.isAbsolute(binary) or std.mem.indexOfScalar(u8, binary, '/') != null) {
        return if (exists(io, binary)) binary else null;
    }
    const name = try exeName(arena, binary);
    const link_dir = if (data_root.len > 0) try std.fs.path.join(arena, &.{ data_root, "bin" }) else "";
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // The link itself is not a target: linking it to itself would
        // make the file its own loop the next install cannot read.
        if (link_dir.len > 0 and std.mem.eql(u8, dir, link_dir)) continue;
        const full = try std.fs.path.join(arena, &.{ dir, name });
        if (exists(io, full)) return full;
    }
    if (repo.len > 0) {
        const built = try std.fs.path.join(arena, &.{ repo, "zig-out", "bin", name });
        if (exists(io, built)) return built;
    }
    return null;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Where an install links to, and where the row says it came from.
pub const Where = enum { prefix, dev };

/// A catalogue row's install state.
pub const State = enum {
    not_installed,
    installed,
    /// Installed, but at a lower version than the catalogue's.
    update,

    pub fn text(s: State) []const u8 {
        return switch (s) {
            .not_installed => "not installed",
            .installed => "installed",
            .update => "update available",
        };
    }
};

/// `a` is older than `b`, comparing dot-separated numbers and falling
/// back to a plain string compare for anything that is not one. A
/// missing component counts as 0, so `0.2` is not older than `0.2.0`.
pub fn olderThan(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const ap = ai.next();
        const bp = bi.next();
        if (ap == null and bp == null) return false;
        const an = std.fmt.parseInt(u32, std.mem.trim(u8, ap orelse "0", " \t"), 10) catch return std.mem.order(u8, a, b) == .lt;
        const bn = std.fmt.parseInt(u32, std.mem.trim(u8, bp orelse "0", " \t"), 10) catch return std.mem.order(u8, a, b) == .lt;
        if (an != bn) return an < bn;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the shipped catalogue parses, and every entry matches the manifests its folder ships" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = (try find(io, arena, build_options.marketplace_catalogue, null)) orelse return error.NoShippedCatalogue;
    const text = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
    var why: []const u8 = "";
    const cat = parse(arena, text, &why) catch {
        std.debug.print("catalogue: {s}\n", .{why});
        return error.BadCatalogue;
    };
    // The three mnml ships today. A new one is this number plus a row.
    try testing.expectEqual(@as(usize, 3), cat.entries.len);

    // Drift guard: the version and the binary here are what
    // `<binary> --install` will write, so they are read back off the
    // folder's own manifests rather than trusted.
    const repo = std.fs.path.dirname(std.fs.path.dirname(path).?).?;
    const manifest_mod = @import("../bridge/manifest.zig");
    for (cat.entries) |e| {
        const folder = try std.fs.path.join(arena, &.{ repo, "integrations", e.id });
        var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch {
            std.debug.print("catalogue: {s}: no integrations/{s}/ in the repo\n", .{ e.id, e.id });
            return error.NoSuchIntegration;
        };
        defer dir.close(io);
        var seen: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind != .file or !std.mem.startsWith(u8, ent.name, "manifest") or !std.mem.endsWith(u8, ent.name, ".zon")) continue;
            const mtext = try dir.readFileAllocOptions(io, ent.name, arena, .limited(1 << 20), .of(u8), 0);
            var mwhy: []const u8 = "";
            const m = try manifest_mod.parse(arena, mtext, &mwhy);
            try testing.expectEqualStrings(e.binary, m.binary);
            try testing.expectEqualStrings(e.version, m.version);
            seen += 1;
        }
        try testing.expect(seen > 0);
    }
}

test "parse refuses an id that is not a file name and an entry with no binary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const ok = try parse(arena, ".{ .entries = .{ .{ .id = \"a\", .label = \"A\", .binary = \"mnml-a\", .future = 1 } } }", &why);
    try testing.expectEqual(@as(usize, 1), ok.entries.len);
    try testing.expectError(error.BadCatalogue, parse(arena, ".{ .entries = .{ .{ .id = \"a/b\", .label = \"A\", .binary = \"x\" } } }", &why));
    try testing.expect(std.mem.indexOf(u8, why, "file name") != null);
    try testing.expectError(error.BadCatalogue, parse(arena, ".{ .entries = .{ .{ .id = \"a\", .label = \"A\", .binary = \"\" } } }", &why));
    try testing.expect(std.mem.indexOf(u8, why, "no binary") != null);
    try testing.expectError(error.BadCatalogue, parse(arena, ".{ .entries = ", &why));
}

test "find: the build option first, then ../share, share, and the portable dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const bin = try std.fs.path.join(arena, &.{ root, "bin" });

    // Nothing anywhere.
    try testing.expect((try find(io, arena, "", bin)) == null);
    try testing.expect((try find(io, arena, "", null)) == null);
    const absent = try std.fs.path.join(arena, &.{ root, "nope.zon" });
    try testing.expect((try find(io, arena, absent, bin)) == null);

    // The archive layout: `<exe dir>/share/mnml/marketplace.zon`.
    try tmp.dir.createDirPath(io, "bin/share/mnml");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/share/mnml/marketplace.zon", .data = ".{}" });
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ bin, "share", "mnml", file_name }), (try find(io, arena, "", bin)).?);

    // The system layout wins over it (`<exe dir>/../share/…`).
    try tmp.dir.createDirPath(io, "share/mnml");
    try tmp.dir.writeFile(io, .{ .sub_path = "share/mnml/marketplace.zon", .data = ".{}" });
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "share", "mnml", file_name }), (try find(io, arena, "", bin)).?);

    // And the build option wins over everything.
    const baked = try std.fs.path.join(arena, &.{ root, "data.zon" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.zon", .data = ".{}" });
    try testing.expectEqualStrings(baked, (try find(io, arena, baked, bin)).?);
}

test "repoOf is the checkout above data/, and empty once the catalogue is packaged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/marketplace.zon", .data = ".{}" });
    const cat = try std.fs.path.join(arena, &.{ root, "repo", "data", file_name });
    // No zig-out yet: not a checkout you can link out of.
    try testing.expectEqualStrings("", try repoOf(io, arena, cat));
    try tmp.dir.createDirPath(io, "repo/zig-out/bin");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "repo" }), try repoOf(io, arena, cat));
    // The packaged layout: share/mnml/marketplace.zon, no zig-out above.
    try tmp.dir.createDirPath(io, "pkg/share/mnml");
    const packaged = try std.fs.path.join(arena, &.{ root, "pkg", "share", "mnml", file_name });
    try testing.expectEqualStrings("", try repoOf(io, arena, packaged));
}

test "linkTarget: a path binary, then PATH (never the link itself), then the checkout's zig-out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const data_root = try std.fs.path.join(arena, &.{ root, "data" });
    const link_dir = try std.fs.path.join(arena, &.{ data_root, "bin" });
    const prefix_bin = try std.fs.path.join(arena, &.{ root, "prefix", "bin" });
    const repo = try std.fs.path.join(arena, &.{ root, "repo" });
    try tmp.dir.createDirPath(io, "data/bin");
    try tmp.dir.createDirPath(io, "prefix/bin");
    try tmp.dir.createDirPath(io, "repo/zig-out/bin");
    const path_var = try std.fmt.allocPrint(arena, "{s}:{s}", .{ link_dir, prefix_bin });

    // Nowhere: no link, and the install says so.
    try testing.expect((try linkTarget(io, arena, "mnml-x", path_var, data_root, repo)) == null);

    // The checkout alone.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/zig-out/bin/mnml-x", .data = "#!/bin/sh\n" });
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ repo, "zig-out", "bin", "mnml-x" }),
        (try linkTarget(io, arena, "mnml-x", path_var, data_root, repo)).?,
    );
    // …and nothing when there is no checkout to fall back to.
    try testing.expect((try linkTarget(io, arena, "mnml-x", path_var, data_root, "")) == null);

    // PREFIX wins once it is installed there.
    try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/mnml-x", .data = "#!/bin/sh\n" });
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ prefix_bin, "mnml-x" }),
        (try linkTarget(io, arena, "mnml-x", path_var, data_root, repo)).?,
    );
    // The link under the data root is never its own target, even though
    // <data root>/bin leads the PATH here.
    try tmp.dir.writeFile(io, .{ .sub_path = "data/bin/mnml-x", .data = "#!/bin/sh\n" });
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ prefix_bin, "mnml-x" }),
        (try linkTarget(io, arena, "mnml-x", path_var, data_root, repo)).?,
    );

    // A binary given as a path is itself — that is how the corpus points
    // an entry at a prebuilt binary — and null when it is not there.
    const abs = try std.fs.path.join(arena, &.{ prefix_bin, "mnml-x" });
    try testing.expectEqualStrings(abs, (try linkTarget(io, arena, abs, "", data_root, repo)).?);
    try testing.expect((try linkTarget(io, arena, "/definitely/not/here/mnml-x", "", data_root, repo)) == null);
}

test "olderThan compares version numbers, pads the short one, and falls back to text" {
    try testing.expect(olderThan("0.1.0", "0.2.0"));
    try testing.expect(olderThan("0.2.0", "0.10.0"));
    try testing.expect(!olderThan("0.2.0", "0.2.0"));
    try testing.expect(!olderThan("0.2", "0.2.0"));
    try testing.expect(olderThan("0.2", "0.2.1"));
    try testing.expect(!olderThan("1.0.0", "0.9.9"));
    // A version that is not numbers at all: a plain compare, and never
    // an update when either side is missing.
    try testing.expect(olderThan("alpha", "beta"));
    try testing.expect(!olderThan("", "0.2.0"));
    try testing.expect(!olderThan("0.2.0", ""));
}

test "State.text is the three words the row paints" {
    try testing.expectEqualStrings("not installed", State.not_installed.text());
    try testing.expectEqualStrings("installed", State.installed.text());
    try testing.expectEqualStrings("update available", State.update.text());
}
