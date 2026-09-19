//! Seeding the dev profile from the stable one.
//!
//! The first launch in the dev profile (`MNML_PROFILE=dev`) finds an
//! empty `~/.config/mnml-dev` and would otherwise be a stranger: no
//! theme, no keymap, none of your integrations. So it copies the few
//! things that *are* your setup and nothing else:
//!
//!   `config.zon` · `integration-settings.zon` · `integrations/` ·
//!   `launchers/` · `themes/`
//!
//! and never:
//!
//!   * anything token-shaped (`skipName`) — a credential is not
//!     duplicated, ever. mnml's own tokens live outside the data root
//!     and an integration's config points at its token file rather than
//!     holding one, so the copy is config, not secrets; the deny-list
//!     is the belt to that pair of braces.
//!   * caches, backups, the trash, request logs, sessions — state, not
//!     setup. The dev profile builds its own.
//!   * `bin/` — those symlinks are the whole reason this exists. The
//!     stable profile's point at what it installed; the dev profile's
//!     point at the integrations built beside the running binary
//!     (`linkBeside`), so a rebuild moves the dev integrations and
//!     leaves the installed ones alone.
//!
//! It is one-shot and idempotent: a dev root that has any state is left
//! alone (`isEmpty`), and `mnml profile seed --force` is how you ask
//! again. Copying never overwrites a file the dev root already has.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const data_root = @import("data_root.zig");

/// The top level of a data root that is setup rather than state.
pub const files = [_][]const u8{ data_root.config_file, "integration-settings.zon" };
pub const dirs = [_][]const u8{ "integrations", "launchers", "themes" };

/// How deep the copy walks (`integrations/<id>/<file>` is 2).
const max_depth = 4;

pub const Outcome = enum {
    /// Files were copied.
    seeded,
    /// The dev root already has state, and `force` was not asked for.
    already,
    /// There is nothing to seed from.
    no_source,
};

pub const Report = struct {
    outcome: Outcome = .no_source,
    /// Files copied, and integration binaries linked.
    copied: usize = 0,
    linked: usize = 0,
};

/// True when `root` holds none of the state `data_root.hasState` looks
/// for — the "this profile has never run" test.
pub fn isEmpty(io: Io, root: []const u8, alloc: Allocator) Allocator.Error!bool {
    for (files) |f| {
        const p = try std.fs.path.join(alloc, &.{ root, f });
        defer alloc.free(p);
        if (exists(io, p)) return false;
    }
    for (dirs) |d| {
        const p = try std.fs.path.join(alloc, &.{ root, d });
        defer alloc.free(p);
        if (exists(io, p)) return false;
    }
    return true;
}

/// A name that is never copied: state, noise, or anything that looks
/// like it holds a credential.
pub fn skipName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const state = [_][]const u8{ "cache", "caches", "backups", "trash", "bin", "sessions", "requests", "ws-history", "chrome-profile", "ratelimit" };
    for (state) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    // A credential never travels between profiles.
    const secret = [_][]const u8{ "token", "secret", "credential", "password", "passwd", "cookie", "apikey", "api_key", "private_key", ".pem", ".p12", ".key" };
    for (secret) |s| if (asciiContains(name, s)) return true;
    // The `.pre-…` / `.bak…` copies mnml leaves beside a file it rewrote.
    if (asciiContains(name, ".pre-") or asciiContains(name, ".bak")) return true;
    return false;
}

fn asciiContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Copy the stable profile's setup into `into`. `force` re-copies over
/// a dev root that already has state; without it a non-empty root is
/// `.already` and nothing is touched. Existing files are never
/// overwritten — `force` is about a second pass, not a rollback.
pub fn seed(gpa: Allocator, io: Io, from: []const u8, into: []const u8, force: bool) Allocator.Error!Report {
    if (!exists(io, from)) return .{ .outcome = .no_source };
    if (!force and !(try isEmpty(io, into, gpa))) return .{ .outcome = .already };
    var report: Report = .{ .outcome = .seeded };
    Io.Dir.cwd().createDirPath(io, into) catch return .{ .outcome = .no_source };
    for (files) |f| {
        const src = try std.fs.path.join(gpa, &.{ from, f });
        defer gpa.free(src);
        const dst = try std.fs.path.join(gpa, &.{ into, f });
        defer gpa.free(dst);
        if (copyFile(io, src, dst)) report.copied += 1;
    }
    for (dirs) |d| {
        const src = try std.fs.path.join(gpa, &.{ from, d });
        defer gpa.free(src);
        const dst = try std.fs.path.join(gpa, &.{ into, d });
        defer gpa.free(dst);
        try copyTree(gpa, io, src, dst, 0, &report);
    }
    return report;
}

/// Copy `src` to `dst` unless `dst` is already there. True when a file
/// was written.
fn copyFile(io: Io, src: []const u8, dst: []const u8) bool {
    if (!exists(io, src)) return false;
    if (exists(io, dst)) return false;
    Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), dst, io, .{}) catch return false;
    return true;
}

fn copyTree(gpa: Allocator, io: Io, src: []const u8, dst: []const u8, depth: usize, report: *Report) Allocator.Error!void {
    if (depth > max_depth) return;
    var dir = Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var made = false;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (skipName(entry.name)) continue;
        const child_src = try std.fs.path.join(gpa, &.{ src, entry.name });
        defer gpa.free(child_src);
        const child_dst = try std.fs.path.join(gpa, &.{ dst, entry.name });
        defer gpa.free(child_dst);
        switch (entry.kind) {
            .directory => try copyTree(gpa, io, child_src, child_dst, depth + 1, report),
            .file, .sym_link => {
                if (!made) {
                    Io.Dir.cwd().createDirPath(io, dst) catch return;
                    made = true;
                }
                if (copyFile(io, child_src, child_dst)) report.copied += 1;
            },
            else => {},
        }
    }
}

/// Link every integration binary sitting beside the running mnml into
/// `<root>/bin/`, which is where `integrations.resolveBinary` looks
/// first. A dev launch therefore drives the integrations it just built,
/// not the ones the stable profile installed. The host itself and the
/// test fakes are not integrations and are left out.
pub fn linkBeside(gpa: Allocator, io: Io, exe_dir: []const u8, root: []const u8) Allocator.Error!usize {
    var dir = Io.Dir.cwd().openDir(io, exe_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    const bin = try std.fs.path.join(gpa, &.{ root, "bin" });
    defer gpa.free(bin);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isIntegrationBinary(entry.name)) continue;
        if (n == 0) Io.Dir.cwd().createDirPath(io, bin) catch return 0;
        const target = try std.fs.path.join(gpa, &.{ exe_dir, entry.name });
        defer gpa.free(target);
        const link = try std.fs.path.join(gpa, &.{ bin, entry.name });
        defer gpa.free(link);
        Io.Dir.cwd().deleteFile(io, link) catch {};
        Io.Dir.cwd().symLink(io, target, link, .{}) catch {
            // No symlinks (Windows without the privilege): a copy does.
            Io.Dir.cwd().copyFile(target, Io.Dir.cwd(), link, io, .{}) catch continue;
        };
        n += 1;
    }
    return n;
}

/// `mnml-jira` yes; `mnml-zig`, `mnml`, `mnml-fake-lsp` and anything
/// that is not an `mnml-` tool, no.
pub fn isIntegrationBinary(name_in: []const u8) bool {
    var name = name_in;
    if (std.mem.endsWith(u8, name, ".exe")) name = name[0 .. name.len - 4];
    if (!std.mem.startsWith(u8, name, "mnml-")) return false;
    if (std.mem.startsWith(u8, name, "mnml-fake-")) return false;
    return !std.mem.eql(u8, name, "mnml-zig");
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        return .{ .tmp = tmp, .root = try t.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn put(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn has(f: *Fixture, rel: []const u8) bool {
        f.tmp.dir.access(t.io, rel, .{}) catch return false;
        return true;
    }

    fn sub(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }
};

test "seeding copies the setup, never a token, never a cache, and never twice" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("stable/config.zon", ".{ .ui = .{} }");
    try f.put("stable/integration-settings.zon", ".{}");
    try f.put("stable/integrations/jira_work.zon", ".{ .id = \"jira_work\" }");
    try f.put("stable/integrations/jira/config.zon", ".{ .jira_url = \"https://x\" }");
    try f.put("stable/integrations/jira/config.zon.pre-2026-09-18", "old");
    try f.put("stable/integrations/jira/token", "hunter2");
    try f.put("stable/integrations/jira/cache/tickets.json", "[]");
    try f.put("stable/themes/mine.zon", ".{}");
    try f.put("stable/launchers/btop.zon", ".{}");
    // State, not setup.
    try f.put("stable/ai_token", "sk-nope");
    try f.put("stable/history-global.jsonl", "{}");
    try f.put("stable/bin/mnml-jira", "#!/bin/sh");

    const from = try f.sub("stable");
    defer t.allocator.free(from);
    const into = try f.sub("dev");
    defer t.allocator.free(into);

    try t.expect(try isEmpty(t.io, into, t.allocator));
    const r = try seed(t.allocator, t.io, from, into, false);
    try t.expectEqual(Outcome.seeded, r.outcome);
    // config.zon, integration-settings.zon, the manifest, the jira
    // config, the theme, the launcher — and nothing else in the tree.
    try t.expectEqual(@as(usize, 6), r.copied);

    try t.expect(f.has("dev/config.zon"));
    try t.expect(f.has("dev/integration-settings.zon"));
    try t.expect(f.has("dev/integrations/jira_work.zon"));
    try t.expect(f.has("dev/integrations/jira/config.zon"));
    try t.expect(f.has("dev/themes/mine.zon"));
    try t.expect(f.has("dev/launchers/btop.zon"));
    // The four that must never travel.
    try t.expect(!f.has("dev/integrations/jira/token"));
    try t.expect(!f.has("dev/integrations/jira/cache/tickets.json"));
    try t.expect(!f.has("dev/integrations/jira/config.zon.pre-2026-09-18"));
    try t.expect(!f.has("dev/ai_token"));
    try t.expect(!f.has("dev/history-global.jsonl"));
    try t.expect(!f.has("dev/bin/mnml-jira"));

    // Seeded once: a second launch finds state and leaves it alone,
    // even after the dev profile has edited its own copy.
    try t.expect(!(try isEmpty(t.io, into, t.allocator)));
    try f.put("dev/config.zon", ".{ .ui = .{ .mine = true } }");
    const again = try seed(t.allocator, t.io, from, into, false);
    try t.expectEqual(Outcome.already, again.outcome);
    try t.expectEqual(@as(usize, 0), again.copied);

    // `--force` copies what is missing and still never overwrites.
    try f.tmp.dir.deleteFile(t.io, "dev/themes/mine.zon");
    const forced = try seed(t.allocator, t.io, from, into, true);
    try t.expectEqual(Outcome.seeded, forced.outcome);
    try t.expectEqual(@as(usize, 1), forced.copied);
    const kept = try f.tmp.dir.readFileAlloc(t.io, "dev/config.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(kept);
    try t.expectEqualStrings(".{ .ui = .{ .mine = true } }", kept);
}

test "nothing to seed from is not an error" {
    var f = try Fixture.init();
    defer f.deinit();
    const from = try f.sub("nope");
    defer t.allocator.free(from);
    const into = try f.sub("dev");
    defer t.allocator.free(into);
    const r = try seed(t.allocator, t.io, from, into, true);
    try t.expectEqual(Outcome.no_source, r.outcome);
    try t.expect(!f.has("dev"));
}

test "the dev profile links the integrations built beside it, not the host or the fakes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("zig-out/bin/mnml-zig", "host");
    try f.put("zig-out/bin/mnml-jira", "jira");
    try f.put("zig-out/bin/mnml-bitbucket", "bitbucket");
    try f.put("zig-out/bin/mnml-fake-jira", "fake");
    try f.put("zig-out/bin/build-font", "tool");
    const exe_dir = try f.sub("zig-out/bin");
    defer t.allocator.free(exe_dir);
    const root = try f.sub("dev");
    defer t.allocator.free(root);

    try t.expectEqual(@as(usize, 2), try linkBeside(t.allocator, t.io, exe_dir, root));
    try t.expect(f.has("dev/bin/mnml-jira"));
    try t.expect(f.has("dev/bin/mnml-bitbucket"));
    try t.expect(!f.has("dev/bin/mnml-zig"));
    try t.expect(!f.has("dev/bin/mnml-fake-jira"));
    try t.expect(!f.has("dev/bin/build-font"));
    // A rebuild relinks rather than failing on the existing link.
    try t.expectEqual(@as(usize, 2), try linkBeside(t.allocator, t.io, exe_dir, root));
}

test "skipName knows a credential when it sees one" {
    try t.expect(skipName("token"));
    try t.expect(skipName("ai_token.work"));
    try t.expect(skipName("jira.TOKEN"));
    try t.expect(skipName("client_secret.zon"));
    try t.expect(skipName("server.pem"));
    try t.expect(skipName("cookies"));
    try t.expect(skipName("cache"));
    try t.expect(skipName(".DS_Store"));
    try t.expect(skipName("config.zon.pre-2026-09-18"));
    try t.expect(!skipName("config.zon"));
    try t.expect(!skipName("jira_work.zon"));
    try t.expect(!skipName("jira"));
}

test "isIntegrationBinary" {
    try t.expect(isIntegrationBinary("mnml-jira"));
    try t.expect(isIntegrationBinary("mnml-sample.exe"));
    try t.expect(!isIntegrationBinary("mnml-zig"));
    try t.expect(!isIntegrationBinary("mnml-zig.exe"));
    try t.expect(!isIntegrationBinary("mnml-fake-lsp"));
    try t.expect(!isIntegrationBinary("mnml"));
    try t.expect(!isIntegrationBinary("zig"));
}
