//! The release index — the Marketplace tab's default source and what
//! the first-launch setup installs from.
//!
//! Each integration ships on its own tag in this repo (`jira-v0.2.0`),
//! one small archive per platform with its sha256
//! (`release-integration.yml`). Each mnml release carries
//! `integrations.json` beside its own archives (`release.yml`,
//! `tools/integrations_index.zig`): for that mnml version, the
//! integrations built for it — id, version, the SDK version each was
//! built on, and per platform the asset's URL and sha256. Nothing is
//! bundled in the mnml archive.
//!
//! An install from it:
//!
//!   1. picks the asset for this build's target (`selectAsset`) — an
//!      integration with none, or built on an SDK this mnml's is not
//!      compatible with (`offered`), is never listed;
//!   2. downloads it through a `Fetcher` (the HTTP client in mnml, a
//!      table in the tests — nothing here needs the network to test);
//!   3. refuses it unless its sha256 is the index's (`verify`);
//!   4. takes the file named after the binary out of the archive
//!      (`.tar.xz`, or `.zip` for Windows) and writes it to
//!      `<data root>/integrations/<id>/bin/<binary>` — the prefix a
//!      marketplace build of an app installs under, so the two paths
//!      leave the same tree;
//!   5. and hands back that path. `marketplace.zig` then links it as
//!      `<data root>/bin/<binary>` and runs `<binary> --install`, which
//!      writes the manifests — the same last two steps every other
//!      install takes.
//!
//! An update is the same install over the top: the row reads
//! `update available` when an installed manifest's version is older
//! than the index's (`marketplace_catalogue.olderThan`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const catalogue = @import("marketplace_catalogue.zig");
const http_client = @import("../http/client.zig");
const http_parse = @import("../http/parse.zig");

/// The index schema this build reads. A newer one is refused rather
/// than half-read.
pub const schema: u32 = 1;

/// The file name the mnml release carries the index as.
pub const index_file = "integrations.json";

/// This mnml's SDK version — what an integration's `sdk` is held to.
pub const host_sdk = sdk.version;

pub const Asset = struct {
    /// The Rust triple the asset was built for (`aarch64-apple-darwin`).
    target: []const u8,
    name: []const u8 = "",
    url: []const u8,
    sha256: []const u8,
};

/// One integration in the index.
pub const Item = struct {
    id: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",
    category: []const u8 = "",
    version: []const u8,
    /// The SDK version the binaries were built on.
    sdk: []const u8,
    /// The binary's name, no `.exe` — what `--install` writes into the
    /// manifests and the archive carries.
    binary: []const u8,
    docs: []const u8 = "",
    /// The integration's own release tag (`jira-v0.2.0`).
    tag: []const u8 = "",
    chip: ?catalogue.Chip = null,
    assets: []const Asset = &.{},
};

pub const Index = struct {
    schema: u32 = schema,
    /// The mnml version the index was cut for.
    mnml: []const u8 = "",
    /// That mnml's SDK version.
    sdk: []const u8 = "",
    integrations: []const Item = &.{},
};

pub const ParseError = error{ BadIndex, OutOfMemory };

/// The index's JSON as an `Index` on `arena`. Unknown fields are
/// ignored so an older mnml still reads a newer file of the same
/// schema; everything that later flows into a path, an argv or a
/// comparison is checked here.
pub fn parse(arena: Allocator, body: []const u8, why: *[]const u8) ParseError!Index {
    const idx = std.json.parseFromSliceLeaky(Index, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = std.fmt.allocPrint(arena, "not an index ({s})", .{@errorName(err)}) catch "not an index";
            return error.BadIndex;
        },
    };
    if (idx.schema != schema) {
        why.* = std.fmt.allocPrint(arena, "index schema {d}; this mnml reads {d}", .{ idx.schema, schema }) catch "schema";
        return error.BadIndex;
    }
    for (idx.integrations) |it| {
        if (!plainName(it.id)) {
            why.* = std.fmt.allocPrint(arena, "{s}: an id must be a file name ([A-Za-z0-9_.-])", .{it.id}) catch "bad id";
            return error.BadIndex;
        }
        if (!plainName(it.binary)) {
            why.* = std.fmt.allocPrint(arena, "{s}: the binary must be a bare file name", .{it.id}) catch "bad binary";
            return error.BadIndex;
        }
        if (it.version.len == 0 or it.sdk.len == 0) {
            why.* = std.fmt.allocPrint(arena, "{s}: no version or no sdk", .{it.id}) catch "no version";
            return error.BadIndex;
        }
        for (it.assets) |a| if (!hexDigest(a.sha256) or a.url.len == 0 or a.target.len == 0) {
            why.* = std.fmt.allocPrint(arena, "{s}: the {s} asset needs a url and a 64-digit sha256", .{ it.id, a.target }) catch "bad asset";
            return error.BadIndex;
        };
    }
    return idx;
}

/// A name that may be a path component and an argv[0]: letters,
/// digits, `_` `-` `.`, not `.`/`..`, not starting with `.`.
pub fn plainName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or s[0] == '.') return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn hexDigest(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

// ─── the platform ───────────────────────────────────────────────────────

/// The Rust triple the release assets name for `t` — one of the five
/// shipped targets (build.zig's `release_targets`) — or null for a
/// target nothing is released for.
pub fn tripleOf(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => "aarch64-apple-darwin",
            .x86_64 => "x86_64-apple-darwin",
            else => null,
        },
        .linux => if (t.abi.isGnu() or t.abi == .none) switch (t.cpu.arch) {
            .aarch64 => "aarch64-unknown-linux-gnu",
            .x86_64 => "x86_64-unknown-linux-gnu",
            else => null,
        } else null,
        .windows => if (t.cpu.arch == .x86_64) "x86_64-pc-windows-gnu" else null,
        else => null,
    };
}

/// This build's triple, or null when it runs somewhere nothing ships for.
pub const host_triple: ?[]const u8 = tripleOf(builtin.target);

/// The asset built for `triple`.
pub fn selectAsset(item: Item, triple: []const u8) ?Asset {
    for (item.assets) |a| if (std.mem.eql(u8, a.target, triple)) return a;
    return null;
}

/// Why an index row is, or is not, listed.
pub const Offer = enum {
    ok,
    /// Built on an SDK this mnml's is not compatible with.
    sdk_mismatch,
    /// Nothing built for this platform.
    no_asset,
};

/// Whether mnml offers `item` at all: its SDK must be compatible with
/// `host` (`mnml_sdk.compatible`) and it must have an asset for
/// `triple`.
pub fn offered(item: Item, host: []const u8, triple: ?[]const u8) Offer {
    if (!sdk.compatible(host, item.sdk)) return .sdk_mismatch;
    const t = triple orelse return .no_asset;
    if (selectAsset(item, t) == null) return .no_asset;
    return .ok;
}

// ─── the index's URL ────────────────────────────────────────────────────

/// A version a release exists for: no `+build` part and no `-dev`
/// prerelease. `0.3.0` and `0.3.0-rc1` are; `0.3.0-dev+g1a2b3c4` (what
/// a checkout builds) is not.
pub fn isReleaseVersion(v: []const u8) bool {
    if (v.len == 0) return false;
    if (std.mem.indexOfScalar(u8, v, '+') != null) return false;
    if (std.mem.indexOf(u8, v, "-dev") != null) return false;
    return std.ascii.isDigit(v[0]);
}

/// `template` with `{version}` replaced by `version`. Null when the
/// template needs a version and `version` has no release — a source build
/// has no index of its own to read. A template without `{version}` is
/// itself.
pub fn resolveUrl(arena: Allocator, template: []const u8, version: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, template, "{version}") == null) return template;
    if (!isReleaseVersion(version)) return null;
    return try std.mem.replaceOwned(u8, arena, template, "{version}", version);
}

// ─── the download ───────────────────────────────────────────────────────

pub const Fetched = union(enum) { body: []const u8, err: []const u8 };

/// Where an install's bytes come from. `http` in mnml; a table in the
/// tests, so an install is exercised end to end without a socket.
pub const Fetcher = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, arena: Allocator, url: []const u8) Allocator.Error!Fetched,
};

/// The HTTP fetcher: GET, redirects followed (a release asset answers
/// with one), the body when the status is 2xx. The client cuts a body
/// at `http_client.max_body`; a cut archive fails its sha256.
pub const http: Fetcher = .{ .get = httpGet };

fn httpGet(_: ?*anyopaque, gpa: Allocator, io: Io, arena: Allocator, url: []const u8) Allocator.Error!Fetched {
    var req = try http_parse.Request.init(gpa);
    defer req.deinit(gpa);
    gpa.free(req.url);
    req.url = try gpa.dupe(u8, url);
    try req.addHeader(gpa, "accept", "application/octet-stream, application/json");
    var outcome = try http_client.send(gpa, io, &req, .{});
    defer outcome.deinit(gpa);
    switch (outcome) {
        .ok => |*resp| {
            if (resp.status < 200 or resp.status >= 300) return .{ .err = try std.fmt.allocPrint(arena, "{s}: HTTP {d}", .{ url, resp.status }) };
            return .{ .body = try arena.dupe(u8, resp.body) };
        },
        .err => |e| return .{ .err = try std.fmt.allocPrint(arena, "{s}: {s}", .{ url, e }) },
        .moved => unreachable,
    }
}

/// The sha256 of `bytes`, lower-case hex.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Whether `bytes` hash to `expected` (hex, either case).
pub fn verify(bytes: []const u8, expected: []const u8) bool {
    if (!hexDigest(expected)) return false;
    const got = sha256Hex(bytes);
    return std.ascii.eqlIgnoreCase(&got, expected);
}

// ─── the archive ────────────────────────────────────────────────────────

pub const ArchiveKind = enum { tar_xz, zip };

/// Which archive a file name is, by its extension.
pub fn archiveKind(name: []const u8) ?ArchiveKind {
    if (std.mem.endsWith(u8, name, ".tar.xz")) return .tar_xz;
    if (std.mem.endsWith(u8, name, ".zip")) return .zip;
    return null;
}

/// The largest binary an archive may unpack to.
pub const max_unpacked = 256 * 1024 * 1024;

pub const ExtractError = error{ OutOfMemory, BadArchive, NotInArchive, WriteFailed, Canceled };

/// The bytes of the file named `file_name` (a base name — the archive's
/// one directory is ignored) inside a `.tar.xz`, on `arena`.
pub fn fromTarXz(gpa: Allocator, arena: Allocator, bytes: []const u8, file_name: []const u8) ExtractError![]const u8 {
    var in: Io.Reader = .fixed(bytes);
    // xz's reader grows its buffer through `gpa` and frees it on deinit.
    var xz = std.compress.xz.Decompress.init(&in, gpa, &.{}) catch return error.BadArchive;
    defer xz.deinit();
    // The whole tar, unpacked: the xz reader's `discard` is not
    // implemented in this Zig, and the tar walk skips by discarding.
    const tar_bytes = xz.reader.allocRemaining(arena, .limited(max_unpacked)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadArchive,
    };
    var tar_in: Io.Reader = .fixed(tar_bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (it.next() catch return error.BadArchive) |f| {
        if (f.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basenamePosix(f.name), file_name)) continue;
        var out: Io.Writer.Allocating = .init(arena);
        it.streamRemaining(f, &out.writer) catch return error.BadArchive;
        return out.written();
    }
    return error.NotInArchive;
}

/// The same out of a `.zip`: the archive is written under `scratch`,
/// unpacked there, and the file read back; `scratch` is removed after.
pub fn fromZip(io: Io, arena: Allocator, bytes: []const u8, file_name: []const u8, scratch: []const u8) ExtractError![]const u8 {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, scratch) catch |err| keepCancel(io, err);
    defer cwd.deleteTree(io, scratch) catch |err| keepCancel(io, err);
    cwd.createDirPath(io, scratch) catch |err| return failOr(err, error.WriteFailed);
    const zip_path = std.fs.path.join(arena, &.{ scratch, "download.zip" }) catch return error.OutOfMemory;
    cwd.writeFile(io, .{ .sub_path = zip_path, .data = bytes }) catch |err| return failOr(err, error.WriteFailed);
    const unpack = std.fs.path.join(arena, &.{ scratch, "unpacked" }) catch return error.OutOfMemory;
    cwd.createDirPath(io, unpack) catch |err| return failOr(err, error.WriteFailed);
    {
        const file = cwd.openFile(io, zip_path, .{}) catch |err| return failOr(err, error.WriteFailed);
        defer file.close(io);
        var rbuf: [16 * 1024]u8 = undefined;
        var fr = file.reader(io, &rbuf);
        var dest = cwd.openDir(io, unpack, .{}) catch |err| return failOr(err, error.WriteFailed);
        defer dest.close(io);
        std.zip.extract(dest, &fr, .{ .allow_backslashes = true }) catch |err| {
            // A cancel mid-read arrives as ReadFailed, the cause on the reader.
            const e: anyerror = err;
            return failOr(if (e == error.ReadFailed) fr.err orelse e else e, error.BadArchive);
        };
    }
    var dir = cwd.openDir(io, unpack, .{ .iterate = true }) catch |err| return failOr(err, error.WriteFailed);
    defer dir.close(io);
    var walker = dir.walk(arena) catch return error.OutOfMemory;
    defer walker.deinit();
    while (walker.next(io) catch |err| return failOr(err, error.BadArchive)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, file_name)) continue;
        return dir.readFileAlloc(io, entry.path, arena, .limited(max_unpacked)) catch |err| return failOr(err, error.BadArchive);
    }
    return error.NotInArchive;
}

/// For a best-effort step that cannot return `error.Canceled` (it
/// catches every error): re-arm a cancel it swallowed. The runtime
/// reports a cancel once; dropped, the worker's next wait — an
/// install's child, a listing's next file — ran to the end with the
/// canceller waiting on it.
pub fn keepCancel(io: Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

/// A failed unpack step's error: a cancel stays a cancel, anything
/// else is `other`.
fn failOr(err: anyerror, other: ExtractError) ExtractError {
    return if (err == error.Canceled) error.Canceled else other;
}

// ─── the install ────────────────────────────────────────────────────────

pub const InstallError = error{ OutOfMemory, Canceled, Failed };

/// What `install` needs from an index row, owned by the caller.
pub const Job = struct {
    id: []const u8,
    binary: []const u8,
    asset: Asset,
};

/// Download `job.asset` through `fetcher`, refuse it unless its sha256
/// is the index's, and write the binary to
/// `<root>/integrations/<id>/bin/<binary>[.exe]`, executable. The path
/// written, on `arena`; `why` says what failed.
pub fn install(io: Io, gpa: Allocator, arena: Allocator, fetcher: Fetcher, root: []const u8, job: Job, why: *[]const u8) InstallError![]const u8 {
    if (!plainName(job.id) or !plainName(job.binary)) {
        why.* = "the id or the binary is not a file name";
        return error.Failed;
    }
    const kind = archiveKind(job.asset.name) orelse archiveKind(job.asset.url) orelse {
        why.* = try std.fmt.allocPrint(arena, "{s}: not a .tar.xz or a .zip", .{job.asset.url});
        return error.Failed;
    };
    const got = try fetcher.get(fetcher.ctx, gpa, io, arena, job.asset.url);
    // A download cut short by a cancel comes back as an `.err` text with
    // the cancel re-armed (`http/client.zig`): it is a cancel, not a
    // failure to report.
    io.checkCancel() catch return error.Canceled;
    const bytes = switch (got) {
        .body => |b| b,
        .err => |e| {
            why.* = e;
            return error.Failed;
        },
    };
    if (!verify(bytes, job.asset.sha256)) {
        why.* = try std.fmt.allocPrint(arena, "sha256 mismatch — the download is not what the index says (want {s}, got {s}); nothing was installed", .{ job.asset.sha256, &sha256Hex(bytes) });
        return error.Failed;
    }
    const file_name = try catalogue.exeName(arena, job.binary);
    const prefix = try std.fs.path.join(arena, &.{ root, "integrations", job.id });
    const binary = switch (kind) {
        .tar_xz => fromTarXz(gpa, arena, bytes, file_name),
        .zip => fromZip(io, arena, bytes, file_name, try std.fs.path.join(arena, &.{ prefix, ".download" })),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.NotInArchive => {
            why.* = try std.fmt.allocPrint(arena, "{s} has no {s}", .{ job.asset.url, file_name });
            return error.Failed;
        },
        error.BadArchive => {
            why.* = try std.fmt.allocPrint(arena, "{s}: the archive does not unpack", .{job.asset.url});
            return error.Failed;
        },
        error.WriteFailed => {
            why.* = try std.fmt.allocPrint(arena, "cannot unpack under {s}", .{prefix});
            return error.Failed;
        },
    };
    const bin_dir = try std.fs.path.join(arena, &.{ prefix, "bin" });
    const dest = try std.fs.path.join(arena, &.{ bin_dir, file_name });
    writeExecutable(io, arena, bin_dir, dest, binary) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        why.* = try std.fmt.allocPrint(arena, "cannot write {s}", .{dest});
        return error.Failed;
    };
    return dest;
}

/// `bytes` to `dest`, executable, through a sibling temp file and a
/// rename — a running copy of the old binary keeps its inode, and a
/// failed write never leaves half a binary where the link points.
fn writeExecutable(io: Io, arena: Allocator, dir: []const u8, dest: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{dest});
    const perms: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755);
    {
        const file = try cwd.createFile(io, part, .{ .truncate = true, .permissions = perms });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        file.setPermissions(io, perms) catch |err| keepCancel(io, err);
    }
    // Windows will not rename over a file a process has open; the old
    // one goes first there.
    if (builtin.os.tag == .windows) cwd.deleteFile(io, dest) catch |err| keepCancel(io, err);
    try Io.Dir.rename(cwd, part, cwd, dest, io);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const build_options = @import("build_options");

const demo_tar_xz = @embedFile("testdata/marketplace/mnml-demo.tar.xz");
const demo_zip = @embedFile("testdata/marketplace/mnml-demo.zip");

/// An index body with one integration, its assets at `base`.
pub fn demoIndex(arena: Allocator, base: []const u8, sdk_version: []const u8, tar_sha: []const u8, zip_sha: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"schema":1,"mnml":"0.3.0","sdk":"{s}","integrations":[
        \\ {{"id":"demo","label":"Demo","description":"The demo integration","category":"sample","version":"0.4.0","sdk":"{s}","binary":"mnml-demo","tag":"demo-v0.4.0",
        \\  "chip":{{"glyph":"","fallback":"D","color":"teal"}},
        \\  "assets":[
        \\   {{"target":"aarch64-apple-darwin","name":"mnml-demo-aarch64-apple-darwin.tar.xz","url":"{s}/mnml-demo.tar.xz","sha256":"{s}"}},
        \\   {{"target":"x86_64-apple-darwin","name":"mnml-demo-x86_64-apple-darwin.tar.xz","url":"{s}/mnml-demo.tar.xz","sha256":"{s}"}},
        \\   {{"target":"x86_64-unknown-linux-gnu","name":"mnml-demo-x86_64-unknown-linux-gnu.tar.xz","url":"{s}/mnml-demo.tar.xz","sha256":"{s}"}},
        \\   {{"target":"aarch64-unknown-linux-gnu","name":"mnml-demo-aarch64-unknown-linux-gnu.tar.xz","url":"{s}/mnml-demo.tar.xz","sha256":"{s}"}},
        \\   {{"target":"x86_64-pc-windows-gnu","name":"mnml-demo-x86_64-pc-windows-gnu.zip","url":"{s}/mnml-demo.zip","sha256":"{s}"}}]}}]}}
    , .{ sdk_version, sdk_version, base, tar_sha, base, tar_sha, base, tar_sha, base, tar_sha, base, zip_sha });
}

test "parse reads the index and refuses what would flow into a path, an argv or a compare" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tar_sha = sha256Hex(demo_tar_xz);
    const zip_sha = sha256Hex(demo_zip);
    var why: []const u8 = "";
    const idx = try parse(a, try demoIndex(a, "https://example.invalid/dl", "0.1.0", &tar_sha, &zip_sha), &why);
    try testing.expectEqual(@as(usize, 1), idx.integrations.len);
    const it = idx.integrations[0];
    try testing.expectEqualStrings("demo", it.id);
    try testing.expectEqualStrings("0.4.0", it.version);
    try testing.expectEqualStrings("0.1.0", it.sdk);
    try testing.expectEqualStrings("mnml-demo", it.binary);
    try testing.expectEqualStrings("D", it.chip.?.fallback);
    try testing.expectEqual(@as(usize, 5), it.assets.len);
    // Unknown fields are ignored.
    _ = try parse(a, "{\"schema\":1,\"future\":true,\"integrations\":[]}", &why);

    const bad = [_]struct { body: []const u8, says: []const u8 }{
        .{ .body = "{\"schema\":2,\"integrations\":[]}", .says = "schema 2" },
        .{ .body = "[1,2]", .says = "not an index" },
        .{ .body = "{\"integrations\":[{\"id\":\"../x\",\"version\":\"1.0.0\",\"sdk\":\"0.1.0\",\"binary\":\"b\"}]}", .says = "file name" },
        .{ .body = "{\"integrations\":[{\"id\":\"x\",\"version\":\"1.0.0\",\"sdk\":\"0.1.0\",\"binary\":\"/bin/sh\"}]}", .says = "bare file name" },
        .{ .body = "{\"integrations\":[{\"id\":\"x\",\"version\":\"\",\"sdk\":\"0.1.0\",\"binary\":\"b\"}]}", .says = "no version" },
        .{ .body = "{\"integrations\":[{\"id\":\"x\",\"version\":\"1.0.0\",\"sdk\":\"0.1.0\",\"binary\":\"b\",\"assets\":[{\"target\":\"t\",\"url\":\"u\",\"sha256\":\"abc\"}]}]}", .says = "64-digit sha256" },
    };
    for (bad) |b| {
        try testing.expectError(error.BadIndex, parse(a, b.body, &why));
        if (std.mem.indexOf(u8, why, b.says) == null) {
            std.debug.print("want \"{s}\" in \"{s}\"\n", .{ b.says, why });
            return error.TestUnexpectedResult;
        }
    }
}

test "the platform: five shipped triples, the asset for this one, nothing elsewhere" {
    const q = std.Target.Query;
    const cases = [_]struct { q: []const u8, want: ?[]const u8 }{
        .{ .q = "aarch64-macos", .want = "aarch64-apple-darwin" },
        .{ .q = "x86_64-macos", .want = "x86_64-apple-darwin" },
        .{ .q = "x86_64-linux-gnu", .want = "x86_64-unknown-linux-gnu" },
        .{ .q = "aarch64-linux-gnu", .want = "aarch64-unknown-linux-gnu" },
        .{ .q = "x86_64-windows-gnu", .want = "x86_64-pc-windows-gnu" },
        .{ .q = "x86_64-linux-musl", .want = null },
        .{ .q = "riscv64-linux-gnu", .want = null },
        .{ .q = "x86_64-freebsd", .want = null },
    };
    for (cases) |c| {
        const target = try std.zig.system.resolveTargetQuery(testing.io, try q.parse(.{ .arch_os_abi = c.q }));
        const got = tripleOf(target);
        if (c.want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tar_sha = sha256Hex(demo_tar_xz);
    const zip_sha = sha256Hex(demo_zip);
    var why: []const u8 = "";
    const it = (try parse(a, try demoIndex(a, "https://x", "0.1.0", &tar_sha, &zip_sha), &why)).integrations[0];
    try testing.expectEqualStrings("mnml-demo-x86_64-pc-windows-gnu.zip", selectAsset(it, "x86_64-pc-windows-gnu").?.name);
    try testing.expectEqualStrings("mnml-demo-aarch64-apple-darwin.tar.xz", selectAsset(it, "aarch64-apple-darwin").?.name);
    try testing.expect(selectAsset(it, "riscv64-unknown-linux-gnu") == null);
    // Offered: the SDK must be compatible AND an asset must exist.
    try testing.expectEqual(Offer.ok, offered(it, "0.1.0", "aarch64-apple-darwin"));
    try testing.expectEqual(Offer.ok, offered(it, "0.1.7", "x86_64-pc-windows-gnu"));
    try testing.expectEqual(Offer.sdk_mismatch, offered(it, "0.2.0", "aarch64-apple-darwin"));
    try testing.expectEqual(Offer.no_asset, offered(it, "0.1.0", "riscv64-unknown-linux-gnu"));
    try testing.expectEqual(Offer.no_asset, offered(it, "0.1.0", null));
    // This build is one of the five, so the corpus's installs have a row.
    if (builtin.os.tag == .macos or builtin.os.tag == .windows or builtin.os.tag == .linux) try testing.expect(host_triple != null);
}

test "sha256: a matching sum passes in either case; any other is refused" {
    const sum = sha256Hex("abc");
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &sum);
    try testing.expect(verify("abc", &sum));
    try testing.expect(verify("abc", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    try testing.expect(!verify("abd", &sum));
    try testing.expect(!verify("abc", "ba7816bf"));
    try testing.expect(!verify("abc", ""));
}

test "versions: an update is an older installed version; a source build resolves no versioned index" {
    try testing.expect(catalogue.olderThan("0.2.0", "0.4.0"));
    try testing.expect(!catalogue.olderThan("0.4.0", "0.4.0"));
    try testing.expect(!catalogue.olderThan("0.5.0", "0.4.0"));
    try testing.expect(isReleaseVersion("0.3.0"));
    try testing.expect(isReleaseVersion("0.3.0-rc1"));
    try testing.expect(!isReleaseVersion("0.3.0-dev"));
    try testing.expect(!isReleaseVersion("0.3.0-dev+g1a2b3c4-dirty"));
    try testing.expect(!isReleaseVersion(""));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tpl = "https://github.com/o/r/releases/download/v{version}/integrations.json";
    try testing.expectEqualStrings("https://github.com/o/r/releases/download/v0.3.0/integrations.json", (try resolveUrl(a, tpl, "0.3.0")).?);
    try testing.expect((try resolveUrl(a, tpl, "0.3.0-dev+gabc")) == null);
    try testing.expectEqualStrings("http://127.0.0.1:1/i.json", (try resolveUrl(a, "http://127.0.0.1:1/i.json", "0.3.0-dev")).?);
}

test "the archives: the binary comes out of a .tar.xz and a .zip by its name, whatever directory it is in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(std.mem.startsWith(u8, try fromTarXz(testing.allocator, a, demo_tar_xz, "mnml-demo"), "#!/bin/sh\n# The release-index test fixture"));
    try testing.expectError(error.NotInArchive, fromTarXz(testing.allocator, a, demo_tar_xz, "mnml-other"));
    try testing.expectError(error.BadArchive, fromTarXz(testing.allocator, a, "not xz at all", "mnml-demo"));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const scratch = try std.fs.path.join(a, &.{ root, "scratch" });
    try testing.expectEqualStrings("MZ-demo-exe\n", try fromZip(testing.io, a, demo_zip, "mnml-demo.exe", scratch));
    // The scratch folder does not outlive the unpack.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "scratch", .{}));
    try testing.expectError(error.NotInArchive, fromZip(testing.io, a, demo_zip, "mnml-other.exe", scratch));
    try testing.expectError(error.BadArchive, fromZip(testing.io, a, "PK not a zip", "mnml-demo.exe", scratch));
    try testing.expectEqual(ArchiveKind.tar_xz, archiveKind("mnml-x-aarch64-apple-darwin.tar.xz").?);
    try testing.expectEqual(ArchiveKind.zip, archiveKind("mnml-x-x86_64-pc-windows-gnu.zip").?);
    try testing.expect(archiveKind("mnml-x.tar.gz") == null);
}

/// A fetcher that answers from a table and counts what it was asked.
pub const FakeFetcher = struct {
    pub const Route = struct { url: []const u8, body: []const u8 };
    routes: []const Route,
    calls: usize = 0,
    /// How many times each route was fetched, by its index in `routes`.
    hits: [16]u32 = .{0} ** 16,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn fetcher(self: *FakeFetcher) Fetcher {
        return .{ .ctx = self, .get = get };
    }

    /// Times `url` was fetched.
    pub fn hitsOf(self: *FakeFetcher, url: []const u8) u32 {
        for (self.routes, 0..) |r, i| if (std.mem.eql(u8, r.url, url)) return self.hits[i];
        return 0;
    }

    fn get(ctx: ?*anyopaque, _: Allocator, _: Io, arena: Allocator, url: []const u8) Allocator.Error!Fetched {
        const self: *FakeFetcher = @ptrCast(@alignCast(ctx.?));
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.calls += 1;
        for (self.routes, 0..) |r, i| if (std.mem.eql(u8, r.url, url)) {
            if (i < self.hits.len) self.hits[i] += 1;
            return .{ .body = try arena.dupe(u8, r.body) };
        };
        return .{ .err = try std.fmt.allocPrint(arena, "{s}: HTTP 404", .{url}) };
    }
};

test "install: the asset is fetched, its sha256 checked, and the binary written executable under integrations/<id>/bin; a bad sum installs nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const tar_sha = sha256Hex(demo_tar_xz);
    const zip_sha = sha256Hex(demo_zip);
    var fake: FakeFetcher = .{ .routes = &.{
        .{ .url = "https://dl/mnml-demo.tar.xz", .body = demo_tar_xz },
        .{ .url = "https://dl/mnml-demo.zip", .body = demo_zip },
    } };
    var why: []const u8 = "";

    const tar_job: Job = .{ .id = "demo", .binary = "mnml-demo", .asset = .{ .target = "t", .name = "mnml-demo-t.tar.xz", .url = "https://dl/mnml-demo.tar.xz", .sha256 = &tar_sha } };
    // A wrong sum: refused, and nothing is on disk.
    var wrong = tar_job;
    wrong.asset.sha256 = &zip_sha;
    try testing.expectError(error.Failed, install(testing.io, testing.allocator, a, fake.fetcher(), root, wrong, &why));
    try testing.expect(std.mem.indexOf(u8, why, "sha256 mismatch") != null);
    try testing.expect(std.mem.indexOf(u8, why, "nothing was installed") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "integrations/demo", .{}));

    if (builtin.os.tag != .windows) {
        const path = try install(testing.io, testing.allocator, a, fake.fetcher(), root, tar_job, &why);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "integrations", "demo", "bin", "mnml-demo" }), path);
        const got = try Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1024));
        try testing.expect(std.mem.endsWith(u8, got, "echo demo-binary\n"));
        const st = try Io.Dir.cwd().statFile(testing.io, path, .{});
        try testing.expect(st.permissions.toMode() & 0o111 != 0);
        // Again over the top — what an update is — and no `.part` left.
        _ = try install(testing.io, testing.allocator, a, fake.fetcher(), root, tar_job, &why);
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "integrations/demo/bin/mnml-demo.part", .{}));
    }

    // The zip: the `.exe` name on Windows, the bare one elsewhere — the
    // archive here only carries the `.exe`, so off Windows it is "not
    // in the archive", which is the name check working.
    const zip_job: Job = .{ .id = "demo", .binary = "mnml-demo", .asset = .{ .target = "t", .name = "mnml-demo-t.zip", .url = "https://dl/mnml-demo.zip", .sha256 = &zip_sha } };
    if (builtin.os.tag == .windows) {
        const path = try install(testing.io, testing.allocator, a, fake.fetcher(), root, zip_job, &why);
        try testing.expect(std.mem.endsWith(u8, path, "mnml-demo.exe"));
    } else {
        try testing.expectError(error.Failed, install(testing.io, testing.allocator, a, fake.fetcher(), root, zip_job, &why));
        try testing.expect(std.mem.indexOf(u8, why, "has no mnml-demo") != null);
    }

    // A 404 names the URL; an unknown archive type is refused before any fetch.
    var missing = tar_job;
    missing.asset.url = "https://dl/gone.tar.xz";
    missing.asset.name = "gone.tar.xz";
    try testing.expectError(error.Failed, install(testing.io, testing.allocator, a, fake.fetcher(), root, missing, &why));
    try testing.expect(std.mem.indexOf(u8, why, "HTTP 404") != null);
    const calls = fake.calls;
    var odd = tar_job;
    odd.asset.url = "https://dl/x.tar.gz";
    odd.asset.name = "x.tar.gz";
    try testing.expectError(error.Failed, install(testing.io, testing.allocator, a, fake.fetcher(), root, odd, &why));
    try testing.expectEqual(calls, fake.calls);
    // A binary that is a path is refused outright.
    var sneaky = tar_job;
    sneaky.binary = "../mnml-demo";
    try testing.expectError(error.Failed, install(testing.io, testing.allocator, a, fake.fetcher(), root, sneaky, &why));
}

test "the SDK version is build.zig.zon's, and index.zon holds every integration to its manifest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const repo = build_options.repo_dir;
    const zon = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, "sdk", "mnml-sdk", "build.zig.zon" }), a, .limited(1 << 20));
    const want = try std.fmt.allocPrint(a, ".version = \"{s}\"", .{sdk.version});
    try testing.expect(std.mem.indexOf(u8, zon, want) != null);

    const Row = struct { id: []const u8, version: []const u8 };
    const IndexZon = struct { integrations: []const Row };
    const text = try Io.Dir.cwd().readFileAllocOptions(io, try std.fs.path.join(a, &.{ repo, "integrations", "index.zon" }), a, .limited(1 << 20), .of(u8), 0);
    const index = try std.zon.parse.fromSliceAlloc(IndexZon, a, text, null, .{});
    try testing.expect(index.integrations.len >= 2);
    const manifest_mod = @import("../bridge/manifest.zig");
    for (index.integrations) |row| {
        const mtext = try Io.Dir.cwd().readFileAllocOptions(io, try std.fs.path.join(a, &.{ repo, "integrations", row.id, "manifest.zon" }), a, .limited(1 << 20), .of(u8), 0);
        var mwhy: []const u8 = "";
        const m = try manifest_mod.parse(a, mtext, &mwhy);
        try testing.expectEqualStrings(m.version, row.version);
    }
}
