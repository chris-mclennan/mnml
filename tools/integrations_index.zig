//! integrations_index — write an mnml release's `integrations.json`.
//!
//!   zig run tools/integrations_index.zig -- \
//!       --index integrations/index.zon --catalogue data/marketplace.zon \
//!       --sdk-zon sdk/mnml-sdk/build.zig.zon --mnml-version 0.3.0 \
//!       --releases DIR --out integrations.json [--allow-missing]
//!   zig run tools/integrations_index.zig -- --list
//!       one `<id> <version>` line per index row — what to download
//!
//! `release.yml` runs it after `gh release download <id>-v<version>
//! --pattern integration.json --dir DIR/<id>` for every row of
//! `integrations/index.zon`. Each `integration.json` is what
//! `scripts/package-integration.sh` wrote for that integration's own
//! release: its version, the SDK it was built on, the binary, and per
//! target the asset URL and sha256. This joins them, adds the label,
//! description, category, docs and chip from the catalogue
//! (`data/marketplace.zon`), and writes the index mnml reads
//! (`src/app/marketplace_release.zig`, schema 1).
//!
//! It refuses — exit 1, the reason on stderr — a row whose release is
//! missing (unless `--allow-missing`, the dry run's switch), a release
//! whose version is not the row's, and one built on an SDK this mnml's
//! is not compatible with: an index that points at something mnml would
//! then hide is a release mistake, and this is the last place to catch
//! it before it ships.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const schema: u32 = 1;

const Row = struct { id: []const u8, version: []const u8 };
const IndexZon = struct { integrations: []const Row = &.{} };

const Chip = struct {
    glyph: []const u8 = "",
    glyph_codepoint: []const u8 = "",
    fallback: []const u8 = "",
    color: []const u8 = "",
};
const CatEntry = struct {
    id: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",
    category: []const u8 = "",
    version: []const u8 = "",
    binary: []const u8 = "",
    docs: []const u8 = "",
    chip: ?Chip = null,
};
const Catalogue = struct { entries: []const CatEntry = &.{} };

const Asset = struct { target: []const u8, name: []const u8 = "", url: []const u8, sha256: []const u8 };
/// What `package-integration.sh` writes.
const Release = struct {
    schema: u32 = 1,
    id: []const u8,
    version: []const u8,
    sdk: []const u8,
    binary: []const u8,
    assets: []const Asset = &.{},
};

/// One row of the output — the shape `marketplace_release.Item` reads.
const Item = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    category: []const u8,
    version: []const u8,
    sdk: []const u8,
    binary: []const u8,
    docs: []const u8,
    tag: []const u8,
    chip: ?Chip,
    assets: []const Asset,
};
const Index = struct { schema: u32, mnml: []const u8, sdk: []const u8, integrations: []const Item };

/// The rule mnml's marketplace gates on (`mnml_sdk.compatible`): the
/// same major, and below 1.0 the same minor.
pub fn compatible(host: []const u8, built_on: []const u8) bool {
    const h = majorMinor(host) orelse return false;
    const b = majorMinor(built_on) orelse return false;
    if (h[0] != b[0]) return false;
    return h[0] != 0 or h[1] == b[1];
}

fn majorMinor(v: []const u8) ?[2]u32 {
    const core = v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
    var it = std.mem.splitScalar(u8, core, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    _ = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ major, minor };
}

/// `.version = "…"`'s value out of a build.zig.zon — the first one,
/// which is the package's own.
pub fn zonVersion(text: []const u8) ?[]const u8 {
    const key = ".version = \"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

pub const Inputs = struct {
    index_zon: [:0]const u8,
    catalogue_zon: [:0]const u8,
    sdk: []const u8,
    mnml_version: []const u8,
    /// `integration.json` per row id; null = not downloaded.
    releases: []const ?[]const u8,
    allow_missing: bool = false,
};

/// The index's JSON, or an error with `why` set.
pub fn build(arena: Allocator, in: Inputs, why: *[]const u8, warn: *std.ArrayListUnmanaged([]const u8)) ![]const u8 {
    const index = parseZon(IndexZon, arena, in.index_zon) catch {
        why.* = "integrations/index.zon does not parse";
        return error.Refused;
    };
    const cat = parseZon(Catalogue, arena, in.catalogue_zon) catch {
        why.* = "data/marketplace.zon does not parse";
        return error.Refused;
    };
    if (in.releases.len != index.integrations.len) {
        why.* = "one integration.json slot per index row";
        return error.Refused;
    }
    var items: std.ArrayListUnmanaged(Item) = .empty;
    for (index.integrations, in.releases) |row, rel_text| {
        const text = rel_text orelse {
            if (in.allow_missing) {
                try warn.append(arena, try std.fmt.allocPrint(arena, "{s}-v{s}: no release (skipped, --allow-missing)", .{ row.id, row.version }));
                continue;
            }
            why.* = try std.fmt.allocPrint(arena, "{s}-v{s}: no such release — push the integration's tag before mnml's", .{ row.id, row.version });
            return error.Refused;
        };
        const rel = std.json.parseFromSliceLeaky(Release, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            why.* = try std.fmt.allocPrint(arena, "{s}-v{s}: integration.json does not parse", .{ row.id, row.version });
            return error.Refused;
        };
        if (!std.mem.eql(u8, rel.id, row.id) or !std.mem.eql(u8, rel.version, row.version)) {
            why.* = try std.fmt.allocPrint(arena, "{s}-v{s}: the release says {s} {s}", .{ row.id, row.version, rel.id, rel.version });
            return error.Refused;
        }
        if (!compatible(in.sdk, rel.sdk)) {
            why.* = try std.fmt.allocPrint(arena, "{s}-v{s} was built on SDK {s}; this mnml's is {s} — mnml would hide it. Re-release it on this SDK.", .{ row.id, row.version, rel.sdk, in.sdk });
            return error.Refused;
        }
        if (rel.assets.len == 0) {
            why.* = try std.fmt.allocPrint(arena, "{s}-v{s}: the release lists no assets", .{ row.id, row.version });
            return error.Refused;
        }
        var entry: CatEntry = .{ .id = row.id };
        for (cat.entries) |e| if (std.mem.eql(u8, e.id, row.id)) {
            entry = e;
        };
        try items.append(arena, .{
            .id = row.id,
            .label = if (entry.label.len > 0) entry.label else row.id,
            .description = entry.description,
            .category = entry.category,
            .version = rel.version,
            .sdk = rel.sdk,
            .binary = rel.binary,
            .docs = entry.docs,
            .tag = try std.fmt.allocPrint(arena, "{s}-v{s}", .{ row.id, row.version }),
            .chip = entry.chip,
            .assets = rel.assets,
        });
    }
    const out: Index = .{ .schema = schema, .mnml = in.mnml_version, .sdk = in.sdk, .integrations = items.items };
    return std.json.Stringify.valueAlloc(arena, out, .{ .whitespace = .indent_2 });
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var index_path: []const u8 = "integrations/index.zon";
    var catalogue_path: []const u8 = "data/marketplace.zon";
    var sdk_zon: []const u8 = "sdk/mnml-sdk/build.zig.zon";
    var mnml_version: []const u8 = "";
    var releases: []const u8 = "";
    var out_path: []const u8 = "";
    var allow_missing = false;
    var list = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--allow-missing")) {
            allow_missing = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--list")) {
            list = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--index")) index_path = next else if (std.mem.eql(u8, a, "--catalogue")) catalogue_path = next else if (std.mem.eql(u8, a, "--sdk-zon")) sdk_zon = next else if (std.mem.eql(u8, a, "--mnml-version")) mnml_version = next else if (std.mem.eql(u8, a, "--releases")) releases = next else if (std.mem.eql(u8, a, "--out")) out_path = next else {
            std.debug.print("integrations_index: unknown argument {s}\n", .{a});
            return 2;
        }
        i += 1;
    }
    const cwd = Io.Dir.cwd();
    const index_zon = try cwd.readFileAllocOptions(io, index_path, arena, .limited(1 << 20), .of(u8), 0);
    if (list) {
        const rows = parseZon(IndexZon, arena, index_zon) catch {
            std.debug.print("integrations_index: {s} does not parse\n", .{index_path});
            return 1;
        };
        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        for (rows.integrations) |row| try w.interface.print("{s} {s}\n", .{ row.id, row.version });
        try w.interface.flush();
        return 0;
    }
    if (mnml_version.len == 0 or releases.len == 0 or out_path.len == 0) {
        std.debug.print("integrations_index: --mnml-version, --releases and --out are required\n", .{});
        return 2;
    }
    const catalogue_zon = try cwd.readFileAllocOptions(io, catalogue_path, arena, .limited(1 << 20), .of(u8), 0);
    const sdk_text = try cwd.readFileAlloc(io, sdk_zon, arena, .limited(1 << 20));
    const sdk = zonVersion(sdk_text) orelse {
        std.debug.print("integrations_index: no .version in {s}\n", .{sdk_zon});
        return 1;
    };
    const index = parseZon(IndexZon, arena, index_zon) catch {
        std.debug.print("integrations_index: {s} does not parse\n", .{index_path});
        return 1;
    };
    const texts = try arena.alloc(?[]const u8, index.integrations.len);
    for (index.integrations, texts) |row, *slot| {
        const p = try std.fs.path.join(arena, &.{ releases, row.id, "integration.json" });
        slot.* = cwd.readFileAlloc(io, p, arena, .limited(1 << 20)) catch null;
    }
    var why: []const u8 = "";
    var warn: std.ArrayListUnmanaged([]const u8) = .empty;
    const json = build(arena, .{
        .index_zon = index_zon,
        .catalogue_zon = catalogue_zon,
        .sdk = sdk,
        .mnml_version = mnml_version,
        .releases = texts,
        .allow_missing = allow_missing,
    }, &why, &warn) catch |err| switch (err) {
        error.Refused => {
            std.debug.print("integrations_index: {s}\n", .{why});
            return 1;
        },
        else => return err,
    };
    for (warn.items) |w| std.debug.print("integrations_index: warning: {s}\n", .{w});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = json });
    std.debug.print("integrations_index: wrote {s} ({d} integration(s), SDK {s})\n", .{ out_path, index.integrations.len - warn.items.len, sdk });
    return 0;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const index_zon_fixture: [:0]const u8 =
    \\.{ .integrations = .{ .{ .id = "jira", .version = "0.2.0" }, .{ .id = "sample", .version = "0.1.0" } } }
;
const catalogue_fixture: [:0]const u8 =
    \\.{ .entries = .{ .{ .id = "jira", .label = "Jira", .description = "Jira: work", .category = "tracker", .version = "0.2.0", .binary = "mnml-jira", .docs = "https://d/jira", .chip = .{ .glyph = "J!", .fallback = "J", .color = "blue" } } } }
;
const jira_rel =
    \\{"schema":1,"id":"jira","version":"0.2.0","sdk":"0.1.0","binary":"mnml-jira","assets":[{"target":"aarch64-apple-darwin","name":"mnml-jira-aarch64-apple-darwin.tar.xz","url":"https://x/jira-v0.2.0/mnml-jira-aarch64-apple-darwin.tar.xz","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}
;
const sample_rel =
    \\{"schema":1,"id":"sample","version":"0.1.0","sdk":"0.1.0","binary":"mnml-sample","assets":[{"target":"x86_64-pc-windows-gnu","name":"mnml-sample-x86_64-pc-windows-gnu.zip","url":"https://x/sample-v0.1.0/mnml-sample-x86_64-pc-windows-gnu.zip","sha256":"1111111111111111111111111111111111111111111111111111111111111111"}]}
;

test "build joins each release with the catalogue into the index mnml reads" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    var warn: std.ArrayListUnmanaged([]const u8) = .empty;
    const json = try build(a, .{ .index_zon = index_zon_fixture, .catalogue_zon = catalogue_fixture, .sdk = "0.1.0", .mnml_version = "0.3.0", .releases = &.{ jira_rel, sample_rel } }, &why, &warn);
    const Parsed = struct { schema: u32, mnml: []const u8, sdk: []const u8, integrations: []const Item };
    const got = try std.json.parseFromSliceLeaky(Parsed, a, json, .{ .ignore_unknown_fields = true });
    try t.expectEqual(@as(u32, 1), got.schema);
    try t.expectEqualStrings("0.3.0", got.mnml);
    try t.expectEqual(@as(usize, 2), got.integrations.len);
    const jira = got.integrations[0];
    try t.expectEqualStrings("Jira", jira.label);
    try t.expectEqualStrings("tracker", jira.category);
    try t.expectEqualStrings("jira-v0.2.0", jira.tag);
    try t.expectEqualStrings("J", jira.chip.?.fallback);
    try t.expectEqualStrings("0.1.0", jira.sdk);
    try t.expectEqualStrings("aarch64-apple-darwin", jira.assets[0].target);
    // Not in the catalogue: the id is the label, no chip.
    try t.expectEqualStrings("sample", got.integrations[1].label);
    try t.expect(got.integrations[1].chip == null);
}

test "build refuses a missing release (unless allowed), a version mismatch and an SDK mnml would hide" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    var warn: std.ArrayListUnmanaged([]const u8) = .empty;
    const base: Inputs = .{ .index_zon = index_zon_fixture, .catalogue_zon = catalogue_fixture, .sdk = "0.1.0", .mnml_version = "0.3.0", .releases = &.{ jira_rel, null } };
    try t.expectError(error.Refused, build(a, base, &why, &warn));
    try t.expect(std.mem.indexOf(u8, why, "sample-v0.1.0: no such release") != null);
    var allowed = base;
    allowed.allow_missing = true;
    const json = try build(a, allowed, &why, &warn);
    try t.expect(std.mem.indexOf(u8, json, "\"sample\"") == null);
    try t.expectEqual(@as(usize, 1), warn.items.len);

    var moved = base;
    moved.releases = &.{ try std.mem.replaceOwned(u8, a, jira_rel, "\"version\":\"0.2.0\"", "\"version\":\"0.2.1\""), sample_rel };
    try t.expectError(error.Refused, build(a, moved, &why, &warn));
    try t.expect(std.mem.indexOf(u8, why, "the release says jira 0.2.1") != null);

    var newer_sdk = base;
    newer_sdk.sdk = "0.2.0";
    newer_sdk.releases = &.{ jira_rel, sample_rel };
    try t.expectError(error.Refused, build(a, newer_sdk, &why, &warn));
    try t.expect(std.mem.indexOf(u8, why, "built on SDK 0.1.0; this mnml's is 0.2.0") != null);
}

test "zonVersion and compatible" {
    try t.expectEqualStrings("0.1.0", zonVersion(".{\n    .name = .mnml_sdk,\n    .version = \"0.1.0\",\n    .x = .{ .version = \"9\" },\n}").?);
    try t.expect(zonVersion(".{}") == null);
    try t.expect(compatible("0.1.0", "0.1.4"));
    try t.expect(!compatible("0.2.0", "0.1.0"));
    try t.expect(compatible("1.2.0", "1.0.0"));
}

/// ZON `src` as a `T` on `arena`, unknown fields ignored. This file is run
/// on its own (`zig run`, release.yml), so it carries the one std spelling
/// that differs between Zig releases itself rather than reaching the SDK's
/// `zig_compat`. (Zig 0.16 form.)
fn parseZon(comptime T: type, arena: std.mem.Allocator, src: [:0]const u8) error{ OutOfMemory, ParseZon }!T {
    return std.zon.parse.fromSliceAlloc(T, arena, src, null, .{ .ignore_unknown_fields = true });
}
