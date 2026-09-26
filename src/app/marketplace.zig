//! The marketplace — what can be installed, from the sources in
//! `cfg.marketplace.sources` (plus mnml's defaults when `use_defaults`).
//! The INTEGRATIONS section's Marketplace tab (`integrations.zig`) lists
//! `State.entries`; the detail pane's Install button and the row menu
//! run `install`. A fetch runs on a worker in the state's `Io.Group`
//! and lands as one `.marketplace` event; an install runs the same way
//! and refreshes the installed list when it is done.
//!
//! Five source shapes do work in this build:
//!
//!   release_index            THE DEFAULT for a released mnml
//!                            (`Config.default_marketplace_sources`):
//!                            the `integrations.json` its own release
//!                            carries (`marketplace_release.zig`). One
//!                            row per integration built on an SDK this
//!                            mnml's is compatible with and released
//!                            for this platform; install downloads the
//!                            archive, checks its sha256, writes the
//!                            binary to `<data root>/integrations/<id>/
//!                            bin/`, links it into `<data root>/bin/`
//!                            and runs `<binary> --install`.
//!   mnml                     The catalogue of integrations this
//!                            checkout builds (`marketplace_catalogue.zig`,
//!                            `data/marketplace.zon` — also packaged as
//!                            `share/mnml/marketplace.zon`). The binary
//!                            already exists, so install is
//!                            `<binary> --install` plus the link
//!                            `<data root>/bin/<name>` → PREFIX's copy,
//!                            else the checkout's `zig-out/bin`. A row
//!                            the release index also lists is dropped:
//!                            the index's download is the install.
//!   github_launcher_folder   every `*.zon` under `<repo>/<path>` is a
//!                            manifest; install = write it under
//!                            `<data root>/integrations/`. For a binary
//!                            already on PATH this is the whole install.
//!   github_monorepo_apps     every directory under `<repo>/<apps_dir>` is
//!                            a Zig integration; install = shallow-clone
//!                            the repo, `zig build` the app into
//!                            `<data root>/integrations/<name>/`, link the
//!                            binary into `<data root>/bin/`, run
//!                            `<binary> --install`.
//!   local_folder             a folder on this machine — the private
//!                            path: every `*.zon` in it is a manifest
//!                            (installed as a launcher is), every
//!                            subfolder with a `build.zig` and a
//!                            `manifest.zon` a Zig integration (built
//!                            in place, no clone).
//!
//! `crates_keyword` is kept in the config so a 0.2 file still loads,
//! but integrations are no longer crates: it is reported and lists
//! nothing. The 0.2 GitHub sources are gone for the same reason — they
//! listed integrations on the old bridge, which this host cannot mount.
//!
//! What `use_defaults` puts first: the release index for this mnml's
//! version — skipped by a dev build, which has no release — then the
//! `mnml` catalogue. And with no config at all, whatever is in
//! `<data root>/marketplace/local/` (`localRoot`): a folder of
//! manifests and integration folders, listed as the `local` source with
//! the `private` badge. Symlink a private integrations repo there and
//! it shows up for its author, nowhere else.
//!
//! Four environment overrides, for an offline or private setup and
//! for the corpus and the UI specs, which cannot write config:
//!
//!   MNML_MARKETPLACE_CATALOGUE=<file>   the `mnml` source reads this
//!       catalogue instead of the shipped one.
//!   MNML_MARKETPLACE_INDEX=<url>        a `release_index` named
//!       `index` — the release index at a URL of your choosing.
//!   MNML_MARKETPLACE_LOCAL=<folder>     a `local_folder` named
//!       `local`, relative to the workspace.
//!   MNML_MARKETPLACE_GITHUB=<owner>/<repo>[:<apps dir>]
//!       a `github_monorepo_apps` source named `github`.
//!
//! The last three REPLACE every other source while they are set, so a
//! scripted run never fetches what the machine's own config names;
//! `MNML_MARKETPLACE_API` replaces `https://api.github.com` under them
//! (the tests point it at a local server). A local folder that is this
//! build's own `launchers/` (the repo's, `build_options.launchers_dir`)
//! lists as `✓ Official` rather than `Private`: it is the official set.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const config = @import("../config/root.zig");
const Config = config.Config;
const http_client = @import("../http/client.zig");
const http_parse = @import("../http/parse.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const integrations = @import("integrations.zig");
const catalogue = @import("marketplace_catalogue.zig");
const release = @import("marketplace_release.zig");
const build_options = @import("build_options");

pub const default_api = "https://api.github.com";
pub const max_body = 4 * 1024 * 1024;

/// `builtin` is a `mnml`-source row: a binary mnml ships, whose
/// install is `--install` plus a link rather than a download or a build.
/// `release` is a release-index row: a download, checked against its
/// sha256, then the same link and `--install`.
pub const Kind = enum { launcher, app, builtin, release };

/// One row of the listing. Borrows the result's arena.
pub const Entry = struct {
    source: []const u8,
    kind: Kind,
    id: []const u8,
    label: []const u8,
    description: []const u8,
    version: []const u8 = "",
    /// launcher: the manifest's download URL (or its path, for a local
    /// folder). app: the repo slug (or the folder's path).
    url: []const u8,
    /// app: the directory under the repo; empty for a local folder.
    subpath: []const u8 = "",
    /// From one of mnml's default sources.
    official: bool = false,
    /// From a `local_folder` source — the private path.
    private: bool = false,
    /// builtin: the binary the catalogue names (a bare name, or the
    /// `$VAR` / absolute path the corpus points an entry at).
    binary: []const u8 = "",
    /// builtin: where the entry is documented.
    docs: []const u8 = "",
    /// builtin: the checkout the catalogue came from, whose
    /// `zig-out/bin` an install falls back to. Empty for a packaged one.
    repo: []const u8 = "",
    /// release: the SDK version the binary was built on, and this
    /// platform's asset — its file name and sha256 (`url` is its URL).
    sdk: []const u8 = "",
    asset_name: []const u8 = "",
    sha256: []const u8 = "",
    /// The manifest's chip, when the source had the manifest to read.
    glyph: []const u8 = "",
    fallback: []const u8 = "",
    color: []const u8 = "",
};

/// A source as the worker sees it (gpa-owned copy of the config).
pub const SourceSpec = struct {
    id: []u8,
    kind: enum { mnml, launcher_folder, monorepo_apps, crates, local_folder, release_index },
    /// mnml: the checkout the catalogue came from, or empty.
    repo: []u8,
    /// The repo path, the keyword, the local folder (absolute), the
    /// catalogue file (mnml), or the index's URL with this mnml's
    /// version in it — empty when a dev build has none to fill in.
    path: []u8,
    official: bool = false,

    fn deinit(s: SourceSpec, gpa: Allocator) void {
        gpa.free(s.id);
        gpa.free(s.repo);
        gpa.free(s.path);
    }
};

/// What a worker posts. Owned; `handle` adopts the listing's arena.
pub const Result = struct {
    generation: u32,
    kind: union(enum) {
        listing: struct { arena: std.heap.ArenaAllocator, entries: []Entry, problems: [][]const u8 },
        /// An install finished; `id` names the entry.
        installed: struct { id: []u8, detail: []u8 },
        failed: []u8,
    },

    pub fn destroy(self: *Result, gpa: Allocator) void {
        switch (self.kind) {
            .listing => |*l| l.arena.deinit(),
            .installed => |i| {
                gpa.free(i.id);
                gpa.free(i.detail);
            },
            .failed => |s| gpa.free(s),
        }
        gpa.destroy(self);
    }
};

pub const State = struct {
    group: Io.Group = .init,
    generation: u32 = 0,
    /// The listing's arena, adopted from the last result.
    arena: ?std.heap.ArenaAllocator = null,
    entries: []Entry = &.{},
    problems: [][]const u8 = &.{},
    fetching: bool = false,
    /// The id being installed, gpa-owned.
    installing: ?[]u8 = null,
    /// Ids waiting for the install ahead of them (`enqueue`), gpa-owned
    /// — the first-launch setup asks for two at once.
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    fetched_at_ms: ?i64 = null,
    /// Where a release install's bytes come from; a test swaps in a
    /// table (`marketplace_release.FakeFetcher`).
    fetcher: release.Fetcher = release.http,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.arena) |*a| a.deinit();
        if (self.installing) |i| gpa.free(i);
        for (self.queue.items) |q| gpa.free(q);
        self.queue.deinit(gpa);
    }
};

pub const table = .{
    .@"marketplace.refresh" = &refreshCmd,
    .@"marketplace.install_focused" = &installFocused,
    .@"marketplace.open_detail_focused" = &detailFocused,
    .@"marketplace.copy_id_focused" = &copyIdFocused,
};

// ─── fetch ──────────────────────────────────────────────────────────────

fn apiBase(app: *App) []const u8 {
    if (app.env.get("MNML_MARKETPLACE_API")) |v| if (v.len > 0) return v;
    return default_api;
}

/// The sources to list: the defaults first when `use_defaults`, then
/// the config's — or only the environment's when one of the two
/// overrides is set. The overrides are how the corpus and the UI specs
/// point the tab somewhere without writing a config; they REPLACE
/// everything, so a scripted run never fetches what the machine's own
/// config names.
pub fn sources(app: *App, gpa: Allocator) Allocator.Error![]SourceSpec {
    var out: std.ArrayListUnmanaged(SourceSpec) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(gpa);
        out.deinit(gpa);
    }
    var overridden = false;
    if (app.env.get("MNML_MARKETPLACE_LOCAL")) |folder| if (folder.len > 0) {
        var spec = try specOf(app, gpa, .{ .local_folder = .{ .id = "local", .path = folder } });
        spec.official = officialLocal(app, spec.path);
        try out.append(gpa, spec);
        overridden = true;
    };
    if (app.env.get("MNML_MARKETPLACE_GITHUB")) |v| if (v.len > 0) {
        const g = githubOverride(v);
        try out.append(gpa, try specOf(app, gpa, .{ .github_monorepo_apps = .{ .id = "github", .repo = g.repo, .apps_dir = g.dir } }));
        overridden = true;
    };
    if (app.env.get("MNML_MARKETPLACE_INDEX")) |v| if (v.len > 0) {
        var spec = try specOf(app, gpa, .{ .release_index = .{ .id = "index", .url = v } });
        spec.official = true;
        try out.append(gpa, spec);
        overridden = true;
    };
    if (overridden) return out.toOwnedSlice(gpa);
    if (app.cfg.marketplace.use_defaults) {
        // This mnml's release index leads — what was released for this
        // version is the first thing the tab lists — then the
        // catalogue this checkout builds. A dev build resolves no index
        // URL (it has no release), so the catalogue is all it lists.
        for (Config.default_marketplace_sources) |s| {
            var spec = try specOf(app, gpa, s);
            if (spec.kind == .release_index and spec.path.len == 0) {
                spec.deinit(gpa);
                continue;
            }
            spec.official = true;
            try out.append(gpa, spec);
        }
        if (try mnmlSource(app, gpa)) |spec| try out.append(gpa, spec);
    }
    for (app.cfg.marketplace.sources) |s| {
        var spec = try specOf(app, gpa, s);
        if (spec.kind == .release_index and spec.path.len == 0) {
            spec.deinit(gpa);
            continue;
        }
        if (spec.kind == .local_folder) spec.official = officialLocal(app, spec.path);
        try out.append(gpa, spec);
    }
    // The data root's own local folder, with no config: private.
    if (try localRoot(app, gpa)) |root| {
        errdefer gpa.free(root);
        try out.append(gpa, .{ .id = try gpa.dupe(u8, "local"), .kind = .local_folder, .repo = try gpa.dupe(u8, ""), .path = root });
    }
    return out.toOwnedSlice(gpa);
}

/// `<data root>/marketplace/local` — the folder a private integrations
/// repo is symlinked into — when it is a directory (through a symlink
/// or not); gpa-owned. Null when it is not there.
pub fn localRoot(app: *App, gpa: Allocator) Allocator.Error!?[]u8 {
    if (app.data_root.len == 0) return null;
    const path = try std.fs.path.join(gpa, &.{ app.data_root, local_subdir });
    var d = Io.Dir.cwd().openDir(app.io, path, .{}) catch {
        gpa.free(path);
        return null;
    };
    d.close(app.io);
    return path;
}

/// Under the data root: the folder listed as the private `local` source.
pub const local_subdir = "marketplace" ++ std.fs.path.sep_str ++ "local";

/// `$MNML_MARKETPLACE_GITHUB`: `<owner>/<repo>[:<apps dir>]`, a
/// `github_monorepo_apps` source against `$MNML_MARKETPLACE_API`.
fn githubOverride(v: []const u8) struct { repo: []const u8, dir: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return .{ .repo = v, .dir = "apps" };
    return .{ .repo = v[0..colon], .dir = if (colon + 1 < v.len) v[colon + 1 ..] else "apps" };
}

/// Whether a local folder is mnml's own `launchers/` — the official
/// launcher set, listed as such. Compared by real path, so a relative
/// `MNML_MARKETPLACE_LOCAL=launchers` from the checkout counts.
pub fn officialLocal(app: *App, abs: []const u8) bool {
    const own = build_options.launchers_dir;
    if (std.mem.eql(u8, abs, own)) return true;
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a_n = Io.Dir.cwd().realPathFile(app.io, abs, &a_buf) catch return false;
    const b_n = Io.Dir.cwd().realPathFile(app.io, own, &b_buf) catch return false;
    return std.mem.eql(u8, a_buf[0..a_n], b_buf[0..b_n]);
}

/// The catalogue file behind the `mnml` source:
/// `$MNML_MARKETPLACE_CATALOGUE` first (how the corpus and the UI specs
/// seed the tab), else the shipped one beside the binary. Empty when
/// there is none — a bare binary copied out of its package.
pub fn cataloguePath(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    if (app.env.get("MNML_MARKETPLACE_CATALOGUE")) |v| if (v.len > 0) {
        const expanded = try app.expandTilde(v);
        return if (std.fs.path.isAbsolute(expanded)) expanded else try std.fs.path.join(arena, &.{ app.workspace, expanded });
    };
    const exe_dir = std.process.executableDirPathAlloc(app.io, arena) catch null;
    return (try catalogue.find(app.io, arena, build_options.marketplace_catalogue, exe_dir)) orelse "";
}

/// The `mnml` source, or null when this build has no catalogue to read.
fn mnmlSource(app: *App, gpa: Allocator) Allocator.Error!?SourceSpec {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try cataloguePath(app, arena);
    if (path.len == 0) return null;
    return .{
        .id = try gpa.dupe(u8, "mnml"),
        .kind = .mnml,
        .repo = try gpa.dupe(u8, try catalogue.repoOf(app.io, arena, path)),
        .path = try gpa.dupe(u8, path),
        .official = true,
    };
}

/// How many sources `sources` would list, without building them: the
/// `MNML_MARKETPLACE_LOCAL` folder counts as one, and so does the mnml
/// catalogue when this build has one.
pub fn sourceCount(app: *App) usize {
    var overrides: usize = 0;
    if (app.env.get("MNML_MARKETPLACE_LOCAL")) |folder| if (folder.len > 0) {
        overrides += 1;
    };
    if (app.env.get("MNML_MARKETPLACE_GITHUB")) |v| if (v.len > 0) {
        overrides += 1;
    };
    if (app.env.get("MNML_MARKETPLACE_INDEX")) |v| if (v.len > 0) {
        overrides += 1;
    };
    if (overrides > 0) return overrides;
    var n: usize = 0;
    var buf: [std.fs.max_path_bytes * 4]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    if (app.cfg.marketplace.use_defaults) {
        for (Config.default_marketplace_sources) |s| {
            if (sourceResolves(fba.allocator(), s)) n += 1;
            fba.reset();
        }
        if (cataloguePath(app, fba.allocator())) |p| {
            if (p.len > 0) n += 1;
        } else |_| {}
        fba.reset();
    }
    for (app.cfg.marketplace.sources) |s| {
        if (sourceResolves(fba.allocator(), s)) n += 1;
        fba.reset();
    }
    if (localRoot(app, fba.allocator()) catch null) |_| n += 1;
    return n;
}

/// Whether a configured source lists anything in this build: only a
/// release index whose URL needs this mnml's version, in a dev build
/// that has none, does not.
fn sourceResolves(arena: Allocator, s: Config.MarketplaceSource) bool {
    return switch (s) {
        .release_index => |r| (release.resolveUrl(arena, r.url, build_options.version) catch return true) != null,
        else => true,
    };
}

fn specOf(app: *App, gpa: Allocator, s: Config.MarketplaceSource) Allocator.Error!SourceSpec {
    return switch (s) {
        .crates_keyword => |c| .{ .id = try gpa.dupe(u8, c.id), .kind = .crates, .repo = try gpa.dupe(u8, ""), .path = try gpa.dupe(u8, c.keyword) },
        .github_launcher_folder => |g| .{ .id = try gpa.dupe(u8, g.id), .kind = .launcher_folder, .repo = try gpa.dupe(u8, g.repo), .path = try gpa.dupe(u8, g.path) },
        .github_monorepo_apps => |g| .{ .id = try gpa.dupe(u8, g.id), .kind = .monorepo_apps, .repo = try gpa.dupe(u8, g.repo), .path = try gpa.dupe(u8, g.apps_dir) },
        .local_folder => |l| blk: {
            const expanded = try app.expandTilde(l.path);
            const abs = if (std.fs.path.isAbsolute(expanded)) try gpa.dupe(u8, expanded) else try std.fs.path.join(gpa, &.{ app.workspace, expanded });
            errdefer gpa.free(abs);
            break :blk .{ .id = try gpa.dupe(u8, l.id), .kind = .local_folder, .repo = try gpa.dupe(u8, ""), .path = abs };
        },
        .release_index => |r| blk: {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const url = (try release.resolveUrl(arena_state.allocator(), r.url, build_options.version)) orelse "";
            const id = try gpa.dupe(u8, r.id);
            errdefer gpa.free(id);
            const path = try gpa.dupe(u8, url);
            errdefer gpa.free(path);
            break :blk .{ .id = id, .kind = .release_index, .repo = try gpa.dupe(u8, ""), .path = path };
        },
    };
}

/// The entry with `id`, if listed.
pub fn find(app: *App, id: []const u8) ?usize {
    for (app.marketplace.entries, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
    return null;
}

/// Start a fetch; the result lands through the event queue.
pub fn refresh(app: *App) CommandError!void {
    if (!app.cfg.marketplace.enabled) return app.diag.fail(app.frame.allocator(), "marketplace: disabled in config (marketplace.enabled)", .{});
    const st = &app.marketplace;
    const gpa = app.gpa;
    st.group.cancel(app.io);
    st.generation +%= 1;
    const specs = try sources(app, gpa);
    errdefer {
        for (specs) |s| s.deinit(gpa);
        gpa.free(specs);
    }
    // Nothing to fetch: no worker, no spinner — the tab's empty state
    // says why.
    if (specs.len == 0) {
        gpa.free(specs);
        st.fetching = false;
        app.needs_render = true;
        return;
    }
    const api = try gpa.dupe(u8, apiBase(app));
    errdefer gpa.free(api);
    st.group.concurrent(app.io, fetchWorker, .{ app.events, app.io, gpa, specs, api, st.generation }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "marketplace: cannot start the fetch: {s}", .{@errorName(err)});
    };
    st.fetching = true;
    app.needs_render = true;
}

fn refreshCmd(app: *App) CommandError!void {
    try refresh(app);
    if (sourceCount(app) == 0) return app.toast("marketplace: no sources configured (marketplace.sources)", .{});
    app.toast("marketplace: fetching…", .{});
}

fn post(events: *event.EventQueue, io: Io, gpa: Allocator, r: Result) void {
    const box = gpa.create(Result) catch return;
    box.* = r;
    events.post(io, .{ .marketplace = box });
}

fn postFailed(events: *event.EventQueue, io: Io, gpa: Allocator, generation: u32, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    post(events, io, gpa, .{ .generation = generation, .kind = .{ .failed = msg } });
}

pub const Fetched = union(enum) { body: []u8, err: []const u8 };

/// GET `url`; the body when the status is 2xx, else an error string on `arena`.
pub fn fetch(gpa: Allocator, io: Io, arena: Allocator, url: []const u8) Allocator.Error!Fetched {
    var req = try http_parse.Request.init(gpa);
    defer req.deinit(gpa);
    gpa.free(req.url);
    req.url = try gpa.dupe(u8, url);
    try req.addHeader(gpa, "accept", "application/vnd.github+json");
    var outcome = try http_client.send(gpa, io, &req, .{});
    defer outcome.deinit(gpa);
    switch (outcome) {
        .ok => |*resp| {
            if (resp.status < 200 or resp.status >= 300) return .{ .err = try std.fmt.allocPrint(arena, "{s}: HTTP {d}", .{ url, resp.status }) };
            if (resp.body.len > max_body) return .{ .err = try std.fmt.allocPrint(arena, "{s}: body over {d} bytes", .{ url, max_body }) };
            return .{ .body = try arena.dupe(u8, resp.body) };
        },
        .err => |e| return .{ .err = try std.fmt.allocPrint(arena, "{s}: {s}", .{ url, e }) },
        .moved => unreachable,
    }
}

pub const GhEntry = struct { name: []const u8, type: []const u8, download_url: ?[]const u8 = null };

/// The GitHub contents listing as it arrives.
pub fn parseContents(arena: Allocator, body: []const u8) ![]GhEntry {
    return std.json.parseFromSliceLeaky([]GhEntry, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// A directory or file name that may flow into a path or an argv.
pub fn safeName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.' or s[0] == '_') return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn fetchWorker(events: *event.EventQueue, io: Io, gpa: Allocator, specs: []SourceSpec, api: []u8, generation: u32) void {
    defer {
        for (specs) |s| s.deinit(gpa);
        gpa.free(specs);
        gpa.free(api);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var problems: std.ArrayListUnmanaged([]const u8) = .empty;
    for (specs) |s| {
        io.checkCancel() catch {
            arena_state.deinit();
            return;
        };
        listSource(io, gpa, arena, api, s, &entries, &problems) catch {
            arena_state.deinit();
            postFailed(events, io, gpa, generation, "marketplace: out of memory", .{});
            return;
        };
    }
    dropShadowedBuiltins(&entries);
    post(events, io, gpa, .{ .generation = generation, .kind = .{ .listing = .{
        .arena = arena_state,
        .entries = entries.items,
        .problems = problems.items,
    } } });
}

/// A catalogue row the release index also lists goes: the same
/// integration, and the index's download is how it installs.
fn dropShadowedBuiltins(entries: *std.ArrayListUnmanaged(Entry)) void {
    var i: usize = 0;
    while (i < entries.items.len) {
        const e = entries.items[i];
        const shadowed = e.kind == .builtin and for (entries.items) |o| {
            if (o.kind == .release and std.mem.eql(u8, o.id, e.id)) break true;
        } else false;
        if (shadowed) _ = entries.orderedRemove(i) else i += 1;
    }
}

fn listSource(io: Io, gpa: Allocator, arena: Allocator, api: []const u8, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    switch (s.kind) {
        .crates => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: crates.io sources are not searched — integrations are Zig packages now", .{s.id}));
            return;
        },
        .mnml => return listCatalogue(io, arena, s, entries, problems),
        .local_folder => return listLocal(io, arena, s, entries, problems),
        .release_index => return listIndex(io, gpa, arena, s, entries, problems),
        .launcher_folder, .monorepo_apps => {},
    }
    const url = try std.fmt.allocPrint(arena, "{s}/repos/{s}/contents/{s}", .{ api, s.repo, s.path });
    const body = switch (try fetch(gpa, io, arena, url)) {
        .body => |b| b,
        .err => |e| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ s.id, e }));
            return;
        },
    };
    const listing = parseContents(arena, body) catch {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: the contents listing is not what GitHub sends", .{s.id}));
        return;
    };
    for (listing) |gh| {
        io.checkCancel() catch return;
        if (!safeName(gh.name)) continue;
        switch (s.kind) {
            .launcher_folder => {
                if (!std.mem.eql(u8, gh.type, "file") or !std.mem.endsWith(u8, gh.name, ".zon")) continue;
                const dl = gh.download_url orelse continue;
                const text = switch (try fetch(gpa, io, arena, dl)) {
                    .body => |b| b,
                    .err => |e| {
                        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ s.id, e }));
                        continue;
                    },
                };
                const z = try arena.dupeZ(u8, text);
                var why: []const u8 = "";
                const m = manifest_mod.parse(arena, z, &why) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadManifest => {
                        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}: {s}", .{ s.id, gh.name, why }));
                        continue;
                    },
                };
                try entries.append(arena, .{
                    .source = try arena.dupe(u8, s.id),
                    .kind = .launcher,
                    .id = m.id,
                    .label = m.label,
                    .description = m.description,
                    .version = m.version,
                    .url = dl,
                    .official = s.official,
                    .glyph = try integrations.chipGlyph(arena, m.chip),
                    .fallback = if (m.chip) |c| c.fallback else "",
                    .color = if (m.chip) |c| c.color else "",
                });
            },
            .monorepo_apps => {
                if (!std.mem.eql(u8, gh.type, "dir")) continue;
                try entries.append(arena, .{
                    .source = try arena.dupe(u8, s.id),
                    .kind = .app,
                    .id = gh.name,
                    .label = gh.name,
                    .description = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ s.repo, s.path, gh.name }),
                    .url = s.repo,
                    .subpath = try std.fs.path.join(arena, &.{ s.path, gh.name }),
                    .official = s.official,
                });
            },
            .crates, .local_folder, .mnml, .release_index => unreachable,
        }
    }
}

/// The `mnml` source: one ZON file, one row per binary mnml ships.
fn listCatalogue(io: Io, arena: Allocator, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const text = Io.Dir.cwd().readFileAllocOptions(io, s.path, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: cannot read {s}: {s}", .{ s.id, s.path, @errorName(err) }));
        return;
    };
    var why: []const u8 = "";
    const cat = catalogue.parse(arena, text, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadCatalogue => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ s.id, why }));
            return;
        },
    };
    for (cat.entries) |e| {
        io.checkCancel() catch return;
        var glyph: []const u8 = "";
        if (e.chip) |c| {
            const chip: manifest_mod.Chip = .{ .glyph = c.glyph, .glyph_codepoint = c.glyph_codepoint, .fallback = c.fallback, .color = c.color };
            glyph = try integrations.chipGlyph(arena, chip);
        }
        try entries.append(arena, .{
            .source = try arena.dupe(u8, s.id),
            .kind = .builtin,
            .id = e.id,
            .label = e.label,
            .description = e.description,
            .version = e.version,
            // The catalogue file itself is where the row came from; the
            // detail pane shows it as the entry's origin.
            .url = try arena.dupe(u8, s.path),
            .official = true,
            .binary = e.binary,
            .docs = e.docs,
            .repo = try arena.dupe(u8, s.repo),
            .glyph = glyph,
            .fallback = if (e.chip) |c| c.fallback else "",
            .color = if (e.chip) |c| c.color else "",
        });
    }
}

/// A `release_index` source: the index at `s.path`, one row per
/// integration this mnml offers — built on a compatible SDK, released
/// for this platform (`marketplace_release.offered`). The rest are
/// left out without a word: a row that cannot install is not a row.
fn listIndex(io: Io, gpa: Allocator, arena: Allocator, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const body = switch (try release.http.get(null, gpa, io, arena, s.path)) {
        .body => |b| b,
        .err => |e| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ s.id, e }));
            return;
        },
    };
    var why: []const u8 = "";
    const idx = release.parse(arena, body, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadIndex => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ s.id, why }));
            return;
        },
    };
    try appendIndexRows(arena, s, idx, release.host_sdk, release.host_triple, entries);
}

/// The rows `idx` contributes on a host with SDK `host_sdk` running on
/// `triple` — split out so the gating is tested without a server.
pub fn appendIndexRows(arena: Allocator, s: SourceSpec, idx: release.Index, host_sdk: []const u8, triple: ?[]const u8, entries: *std.ArrayListUnmanaged(Entry)) Allocator.Error!void {
    for (idx.integrations) |it| {
        if (release.offered(it, host_sdk, triple) != .ok) continue;
        const asset = release.selectAsset(it, triple.?).?;
        var glyph: []const u8 = "";
        if (it.chip) |c| {
            const chip: manifest_mod.Chip = .{ .glyph = c.glyph, .glyph_codepoint = c.glyph_codepoint, .fallback = c.fallback, .color = c.color };
            glyph = try integrations.chipGlyph(arena, chip);
        }
        try entries.append(arena, .{
            .source = try arena.dupe(u8, s.id),
            .kind = .release,
            .id = it.id,
            .label = if (it.label.len > 0) it.label else it.id,
            .description = it.description,
            .version = it.version,
            .url = asset.url,
            .official = s.official,
            .binary = it.binary,
            .docs = it.docs,
            .sdk = it.sdk,
            .asset_name = if (asset.name.len > 0) asset.name else std.fs.path.basenamePosix(asset.url),
            .sha256 = asset.sha256,
            .glyph = glyph,
            .fallback = if (it.chip) |c| c.fallback else "",
            .color = if (it.chip) |c| c.color else "",
        });
    }
}

/// A `local_folder` source: the folder's `*.zon` files are manifests
/// (launchers), its subfolders with a `build.zig` + `manifest.zon` are
/// apps to build in place. A subfolder that is neither — a private
/// integrations repo symlinked in whole — is looked into for more of
/// the same, a few levels down (`local_depth`), so its
/// `integrations/<id>/` folders list without being linked one by one.
fn listLocal(io: Io, arena: Allocator, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    var dir = Io.Dir.cwd().openDir(io, s.path, .{ .iterate = true }) catch {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} is not a directory", .{ s.id, s.path }));
        return;
    };
    defer dir.close(io);
    try listLocalDir(io, arena, s, dir, s.path, 0, entries, problems);
}

/// How far below a `local_folder` an integration folder may sit:
/// `<folder>/<repo>/integrations/<id>/` is three.
const local_depth = 3;

fn listLocalDir(io: Io, arena: Allocator, s: SourceSpec, dir: Io.Dir, path: []const u8, depth: usize, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        io.checkCancel() catch return;
        if (!safeName(entry.name)) continue;
        const full = try std.fs.path.join(arena, &.{ path, entry.name });
        var kind: Kind = undefined;
        var text: [:0]const u8 = undefined;
        if ((entry.kind == .file or entry.kind == .sym_link) and std.mem.endsWith(u8, entry.name, ".zon")) {
            // Only the folder itself holds loose manifests; a repo's own
            // `build.zig.zon` is a package, never a manifest.
            if (depth > 0 or std.mem.eql(u8, entry.name, "build.zig.zon")) continue;
            kind = .launcher;
            text = dir.readFileAllocOptions(io, entry.name, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}: {s}", .{ s.id, entry.name, @errorName(err) }));
                continue;
            };
        } else if (entry.kind == .directory or entry.kind == .sym_link) {
            if (skipDir(entry.name)) continue;
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const is_app = if (sub.statFile(io, "build.zig", .{})) |_| true else |_| false;
            if (!is_app) {
                if (depth + 1 < local_depth) try listLocalDir(io, arena, s, sub, full, depth + 1, entries, problems);
                continue;
            }
            kind = .app;
            text = sub.readFileAllocOptions(io, "manifest.zon", arena, .limited(1 << 20), .of(u8), 0) catch continue;
        } else continue;
        var why: []const u8 = "";
        const m = manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadManifest => {
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}: {s}", .{ s.id, entry.name, why }));
                continue;
            },
        };
        try entries.append(arena, .{
            .source = try arena.dupe(u8, s.id),
            .kind = kind,
            .id = m.id,
            .label = m.label,
            .description = m.description,
            .version = m.version,
            .url = full,
            .official = s.official,
            .private = !s.official,
            .glyph = try integrations.chipGlyph(arena, m.chip),
            .fallback = if (m.chip) |c| c.fallback else "",
            .color = if (m.chip) |c| c.color else "",
        });
    }
}

/// Build output and dependency folders a repo scan never walks into.
fn skipDir(name: []const u8) bool {
    const skip = [_][]const u8{ "zig-out", "zig-pkg", "node_modules", "target", "vendor" };
    for (skip) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

// ─── install ────────────────────────────────────────────────────────────

/// Install `id` now, or after the install already running: the
/// first-launch setup asks for several at once, and the state runs one
/// at a time. An id the listing does not have yet waits for it — a
/// fetch still running lands, then the queue moves (`pump`).
pub fn enqueue(app: *App, id: []const u8) CommandError!void {
    const st = &app.marketplace;
    if (st.installing) |cur| if (std.mem.eql(u8, cur, id)) return;
    for (st.queue.items) |q| if (std.mem.eql(u8, q, id)) return;
    const owned = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(owned);
    try st.queue.append(app.gpa, owned);
    try pump(app);
}

/// Start the next queued install when nothing is running and the
/// listing is in. An id the listing does not carry is dropped with a
/// warning — the index this mnml reads has no such integration, or not
/// for this platform.
pub fn pump(app: *App) CommandError!void {
    const st = &app.marketplace;
    while (st.installing == null and !st.fetching and st.queue.items.len > 0) {
        const id = st.queue.orderedRemove(0);
        defer app.gpa.free(id);
        const idx = find(app, id) orelse {
            try app.toastLevel(.warn, "marketplace: {s} is not in the marketplace for this mnml — nothing to install", .{id});
            continue;
        };
        try install(app, idx);
    }
}

/// Install the entry at `idx` on a worker: a launcher's manifest is
/// fetched and written; an app is cloned and built; a release-index
/// row is downloaded and checked.
pub fn install(app: *App, idx: usize) CommandError!void {
    const st = &app.marketplace;
    if (idx >= st.entries.len) return;
    if (st.installing != null) return app.diag.fail(app.frame.allocator(), "marketplace: an install is already running", .{});
    if (app.data_root.len == 0) return app.diag.fail(app.frame.allocator(), "marketplace: no data root to install into", .{});
    const e = st.entries[idx];
    const gpa = app.gpa;
    const job = try gpa.create(InstallJob);
    errdefer gpa.destroy(job);
    job.* = .{ .kind = e.kind, .id = &.{}, .root = &.{}, .url = &.{}, .subpath = &.{}, .binary = &.{}, .repo = &.{}, .asset_name = &.{}, .sha256 = &.{}, .fetcher = st.fetcher, .env = undefined };
    job.id = try gpa.dupe(u8, e.id);
    errdefer gpa.free(job.id);
    job.root = try gpa.dupe(u8, app.data_root);
    errdefer gpa.free(job.root);
    job.url = try gpa.dupe(u8, e.url);
    errdefer gpa.free(job.url);
    job.subpath = try gpa.dupe(u8, e.subpath);
    errdefer gpa.free(job.subpath);
    // `$VAR` resolves against the app's environment, not the worker's.
    job.binary = try gpa.dupe(u8, try integrations.expandEnv(app, app.frame.allocator(), e.binary));
    errdefer gpa.free(job.binary);
    job.repo = try gpa.dupe(u8, e.repo);
    errdefer gpa.free(job.repo);
    job.asset_name = try gpa.dupe(u8, e.asset_name);
    errdefer gpa.free(job.asset_name);
    job.sha256 = try gpa.dupe(u8, e.sha256);
    errdefer gpa.free(job.sha256);
    job.env = try app.env.clone(gpa);
    errdefer job.env.deinit();
    try job.env.put("MNML_DATA_ROOT", app.data_root);
    st.group.concurrent(app.io, installWorker, .{ app.events, app.io, gpa, job, st.generation }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "marketplace: cannot start the install: {s}", .{@errorName(err)});
    };
    st.installing = try gpa.dupe(u8, e.id);
    app.toast("marketplace: installing {s}…", .{e.id});
}

const InstallJob = struct {
    kind: Kind,
    id: []u8,
    root: []u8,
    url: []u8,
    subpath: []u8,
    /// builtin: the binary to run `--install` on and link, `$VAR`
    /// already expanded.
    binary: []u8,
    /// builtin: the checkout to fall back to, or empty.
    repo: []u8,
    /// release: the asset's file name and the sha256 it must hash to.
    asset_name: []u8,
    sha256: []u8,
    fetcher: release.Fetcher,
    env: std.process.Environ.Map,

    fn destroy(self: *InstallJob, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.root);
        gpa.free(self.url);
        gpa.free(self.subpath);
        gpa.free(self.binary);
        gpa.free(self.repo);
        gpa.free(self.asset_name);
        gpa.free(self.sha256);
        self.env.deinit();
        gpa.destroy(self);
    }
};

const InstallError = error{ OutOfMemory, Canceled, Failed };

fn installWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *InstallJob, generation: u32) void {
    defer job.destroy(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const detail = installInner(io, gpa, arena, job, &why) catch |err| switch (err) {
        error.OutOfMemory => {
            postFailed(events, io, gpa, generation, "marketplace: out of memory installing {s}", .{job.id});
            return;
        },
        error.Canceled => return,
        error.Failed => {
            postFailed(events, io, gpa, generation, "marketplace: {s}: {s}", .{ job.id, why });
            return;
        },
    };
    const id = gpa.dupe(u8, job.id) catch return;
    const d = gpa.dupe(u8, detail) catch {
        gpa.free(id);
        return;
    };
    post(events, io, gpa, .{ .generation = generation, .kind = .{ .installed = .{ .id = id, .detail = d } } });
}

fn installInner(io: Io, gpa: Allocator, arena: Allocator, job: *InstallJob, why: *[]const u8) InstallError![]const u8 {
    manifest_mod.validateId(job.id) catch {
        why.* = "the id is not a file name";
        return error.Failed;
    };
    switch (job.kind) {
        // A release-index row: download, check the sum, unpack the
        // binary under the data root; then the link and `--install`,
        // as for a binary mnml ships. The link goes down first so the
        // manifests `--install` writes resolve the moment they land.
        .release => {
            const bin = try release.install(io, gpa, arena, job.fetcher, job.root, .{
                .id = job.id,
                .binary = job.binary,
                .asset = .{ .target = "", .name = job.asset_name, .url = job.url, .sha256 = job.sha256 },
            }, why);
            const linked = linkBinary(io, arena, job.root, bin) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkFailed => {
                    why.* = try std.fmt.allocPrint(arena, "cannot link {s} into {s}/bin", .{ bin, job.root });
                    return error.Failed;
                },
            };
            try run(io, gpa, arena, &.{ bin, "--install" }, null, &job.env, "--install", why);
            return try std.fmt.allocPrint(arena, "downloaded, sha256 checked, linked {s}", .{linked});
        },
        // A binary mnml ships: it exists already, so the whole install
        // is the link plus `--install`. The link goes down FIRST, so
        // the manifest `--install` writes (naming the bare binary) is
        // resolvable the moment the scan reads it.
        .builtin => {
            const path_var = job.env.get("PATH") orelse "";
            const target = (try catalogue.linkTarget(io, arena, job.binary, path_var, job.root, job.repo)) orelse {
                why.* = try std.fmt.allocPrint(arena, "{s} is not on PATH and not built in this checkout — `zig build`, or `run.sh install`", .{job.binary});
                return error.Failed;
            };
            const linked = linkBinary(io, arena, job.root, target) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkFailed => {
                    why.* = try std.fmt.allocPrint(arena, "cannot link {s} into {s}/bin", .{ target, job.root });
                    return error.Failed;
                },
            };
            try run(io, gpa, arena, &.{ target, "--install" }, null, &job.env, "--install", why);
            return try std.fmt.allocPrint(arena, "linked {s} \u{2192} {s}", .{ linked, target });
        },
        .launcher => {
            // A local folder's manifest is a file; a GitHub one a download.
            const text = if (std.fs.path.isAbsolute(job.url))
                Io.Dir.cwd().readFileAlloc(io, job.url, arena, .limited(1 << 20)) catch {
                    why.* = "cannot read the manifest";
                    return error.Failed;
                }
            else switch (try fetch(gpa, io, arena, job.url)) {
                .body => |b| b,
                .err => |e| {
                    why.* = e;
                    return error.Failed;
                },
            };
            const path = manifest_mod.manifest.pathUnder(arena, job.root, job.id) catch {
                why.* = "the id is not a file name";
                return error.Failed;
            };
            Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch {};
            Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {
                why.* = "cannot write the manifest";
                return error.Failed;
            };
            return try std.fmt.allocPrint(arena, "wrote {s}", .{path});
        },
        .app => {
            // A local folder builds in place; a repo is cloned (or
            // reused) under <root>/marketplace/<owner>-<repo>.
            const app_dir = if (std.fs.path.isAbsolute(job.url)) job.url else blk: {
                const slug = try arena.dupe(u8, job.url);
                for (slug) |*c| if (c.* == '/') {
                    c.* = '-';
                };
                if (!safeName(slug)) {
                    why.* = "the repo slug is not a path component";
                    return error.Failed;
                }
                const clone_dir = try std.fs.path.join(arena, &.{ job.root, "marketplace", slug });
                const exists = e: {
                    Io.Dir.cwd().access(io, clone_dir, .{}) catch break :e false;
                    break :e true;
                };
                if (!exists) {
                    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(clone_dir).?) catch {};
                    const git_url = try std.fmt.allocPrint(arena, "https://github.com/{s}.git", .{job.url});
                    try run(io, gpa, arena, &.{ "git", "clone", "--depth", "1", git_url, clone_dir }, null, &job.env, "git clone", why);
                } else {
                    run(io, gpa, arena, &.{ "git", "-C", clone_dir, "pull", "--ff-only" }, null, &job.env, "git pull", why) catch {};
                }
                break :blk try std.fs.path.join(arena, &.{ clone_dir, job.subpath });
            };
            const prefix = try std.fs.path.join(arena, &.{ job.root, manifest_mod.subdir, job.id });
            try run(io, gpa, arena, &.{ "zig", "build", "-Doptimize=ReleaseSafe", "--prefix", prefix }, app_dir, &job.env, "zig build", why);
            // The binary: the one file under <prefix>/bin.
            const bin_dir = try std.fs.path.join(arena, &.{ prefix, "bin" });
            var dir = Io.Dir.cwd().openDir(io, bin_dir, .{ .iterate = true }) catch {
                why.* = "zig build produced no bin/";
                return error.Failed;
            };
            defer dir.close(io);
            var it = dir.iterate();
            var binary: ?[]const u8 = null;
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                binary = try std.fs.path.join(arena, &.{ bin_dir, entry.name });
                break;
            }
            const exe = binary orelse {
                why.* = "zig build produced no binary";
                return error.Failed;
            };
            _ = linkBinary(io, arena, job.root, exe) catch "";
            try run(io, gpa, arena, &.{ exe, "--install" }, null, &job.env, "--install", why);
            return try std.fmt.allocPrint(arena, "built {s}", .{exe});
        },
    }
}

pub const LinkError = error{ OutOfMemory, LinkFailed };

/// `<root>/bin/<name>` → `target`, the one indirection that keeps a
/// manifest's bare `binary` name honest: `integrations.resolveBinary`
/// prefers this link over PATH, so relinking it (here, by `run.sh
/// install`, or by `integrations.update`) moves every installed
/// manifest at once and none of them hardcodes a path. A symlink where
/// there are symlinks, a copy where there are not (Windows without the
/// privilege). Returns the link's path.
pub fn linkBinary(io: Io, arena: Allocator, root: []const u8, target: []const u8) LinkError![]const u8 {
    const link_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    Io.Dir.cwd().createDirPath(io, link_dir) catch {};
    const link = try std.fs.path.join(arena, &.{ link_dir, std.fs.path.basename(target) });
    // The link is replaced, not written through: deleting it first is
    // what stops a copy overwriting the binary a symlink points at.
    Io.Dir.cwd().deleteFile(io, link) catch {};
    Io.Dir.cwd().symLink(io, target, link, .{}) catch {
        Io.Dir.cwd().copyFile(target, Io.Dir.cwd(), link, io, .{}) catch return error.LinkFailed;
    };
    return link;
}

/// Run a child to completion; a non-zero exit is `Failed` with its stderr tail in `why`.
fn run(io: Io, gpa: Allocator, arena: Allocator, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, what: []const u8, why: *[]const u8) InstallError!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = try std.fmt.allocPrint(arena, "{s}: cannot run {s}: {s}", .{ what, argv[0], @errorName(err) });
            return error.Failed;
        },
    };
    defer child.kill(io);
    var err_buf: [4096]u8 = undefined;
    var err_reader = child.stderr.?.reader(io, &err_buf);
    var tail: Io.Writer.Allocating = .init(gpa);
    defer tail.deinit();
    _ = err_reader.interface.streamRemaining(&tail.writer) catch {};
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            why.* = try std.fmt.allocPrint(arena, "{s}: wait failed", .{what});
            return error.Failed;
        },
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const t = tail.written();
        const cut = if (t.len > 300) t[t.len - 300 ..] else t;
        why.* = try std.fmt.allocPrint(arena, "{s} failed: {s}", .{ what, std.mem.trim(u8, cut, " \r\n") });
        return error.Failed;
    }
}

// ─── events ─────────────────────────────────────────────────────────────

pub fn handle(app: *App, r: *Result) Allocator.Error!void {
    const st = &app.marketplace;
    const gpa = app.gpa;
    switch (r.kind) {
        .listing => |*l| {
            if (r.generation != st.generation) {
                r.destroy(gpa);
                return;
            }
            if (st.arena) |*old| old.deinit();
            st.arena = l.arena;
            st.entries = l.entries;
            st.problems = l.problems;
            st.fetching = false;
            st.fetched_at_ms = app.now_ms;
            for (l.problems) |p| try app.toastLevel(.warn, "marketplace: {s}", .{p});
            // The arena moved into the state; only the box goes.
            gpa.destroy(r);
            pumpOrToast(app);
        },
        .installed => |i| {
            defer r.destroy(gpa);
            if (st.installing) |cur| gpa.free(cur);
            st.installing = null;
            try integrations.refresh(app);
            app.toast("marketplace: installed {s} — {s}", .{ i.id, i.detail });
            pumpOrToast(app);
        },
        .failed => |msg| {
            defer r.destroy(gpa);
            st.fetching = false;
            // // changed (bottom-row): a failed install carries the way
            // back to the entry, where its source and version say why —
            // the id is gone from the state a line later.
            if (st.installing) |cur| {
                defer gpa.free(cur);
                st.installing = null;
                const action: app_mod.ToastAction = .{ .marketplace = .{
                    .label = try gpa.dupe(u8, "Marketplace"),
                    .id = try gpa.dupe(u8, cur),
                } };
                errdefer action.deinit(gpa);
                try app.toastWithAction(.err, action, "{s}", .{msg});
                app.needs_render = true;
                pumpOrToast(app);
                return;
            }
            st.installing = null;
            try app.toastLevel(.err, "{s}", .{msg});
            pumpOrToast(app);
        },
    }
    app.needs_render = true;
}

/// The next queued install, from an event: a failure to start it is a
/// toast, not the event loop's error.
fn pumpOrToast(app: *App) void {
    pump(app) catch |err| switch (err) {
        error.OutOfMemory => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

/// A frame is due while a worker runs (the spinner).
pub fn busy(app: *const App) bool {
    return app.marketplace.fetching or app.marketplace.installing != null;
}

// ─── the section's hooks ────────────────────────────────────────────────

fn installFocused(app: *App) CommandError!void {
    return install(app, try integrations.marketRow(app));
}

fn detailFocused(app: *App) CommandError!void {
    const i = try integrations.marketRow(app);
    return integrations.openDetail(app, .{ .marketplace = app.marketplace.entries[i].id });
}

fn copyIdFocused(app: *App) CommandError!void {
    const i = try integrations.marketRow(app);
    try app.clipboard.set(app.marketplace.entries[i].id, false);
    app.toast("copied {s}", .{app.marketplace.entries[i].id});
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

/// A tiny HTTP server that answers by path from a table. Shared with
/// `font_scan.zig`'s release-lookup test.
pub const FakeGitHub = struct {
    pub const Route = struct { path: []const u8, body: []const u8, status: u16 = 200 };
    gpa: Allocator,
    io: Io,
    port: u16,
    server: Io.net.Server,
    routes: []const Route,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(gpa: Allocator, io: Io, routes: []const Route) !*FakeGitHub {
        const self = try gpa.create(FakeGitHub);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .port = server.socket.address.getPort(), .server = server, .routes = routes };
        self.thread = try std.Thread.spawn(.{}, loop, .{ self, io });
        return self;
    }

    pub fn stop(self: *FakeGitHub) void {
        const io = self.io;
        self.stopping.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        self.thread.join();
        self.server.deinit(io);
        self.gpa.destroy(self);
    }

    fn loop(self: *FakeGitHub, io: Io) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(io) catch break;
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                break;
            }
            self.serveOne(io, stream) catch {};
            stream.close(io);
        }
    }

    fn serveOne(self: *FakeGitHub, io: Io, stream: Io.net.Stream) !void {
        var rbuf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
        const r = &reader.interface;
        const request_line = try r.takeDelimiterInclusive('\n');
        var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
        _ = parts.next();
        const path = parts.next() orelse "/";
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch break;
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        }
        var route: ?Route = null;
        for (self.routes) |rt| if (std.mem.eql(u8, rt.path, path)) {
            route = rt;
        };
        var wbuf: [16 * 1024]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
        const w = &writer.interface;
        if (route) |rt| {
            try w.print("HTTP/1.1 {d} OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ rt.status, rt.body.len });
            try w.writeAll(rt.body);
        } else {
            try w.writeAll("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        }
        try w.flush();
    }
};

const listing_json =
    \\[{"name":"hello.zon","type":"file","download_url":"BASE/raw/hello.zon"},
    \\ {"name":"README.md","type":"file","download_url":"BASE/raw/README.md"},
    \\ {"name":"broken.zon","type":"file","download_url":"BASE/raw/broken.zon"},
    \\ {"name":"evil;rm.zon","type":"file","download_url":"BASE/raw/evil.zon"}]
;
const apps_json =
    \\[{"name":"mnml-jira","type":"dir"},{"name":".github","type":"dir"},{"name":"README.md","type":"file"},{"name":"bad name","type":"dir"}]
;
const hello_zon =
    \\.{ .id = "hello", .label = "Hello", .description = "The sample", .version = "0.1.0", .binary = "mnml-hello" }
;

test "a dev build's default source is the mnml catalogue: its release index has no version to resolve, and nothing from the 0.2 monorepo, launchers or crates is prepended" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 20 });
    defer app.deinit();
    try testing.expect(app.cfg.marketplace.use_defaults);
    // One source out of the box: the catalogue this build ships, with
    // no config at all.
    try testing.expectEqual(@as(usize, 1), sourceCount(&app));
    const specs = try sources(&app, gpa);
    defer {
        for (specs) |sp| sp.deinit(gpa);
        gpa.free(specs);
    }
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expectEqualStrings("mnml", specs[0].id);
    try testing.expect(specs[0].kind == .mnml);
    try testing.expect(specs[0].official);
    // A dev build's catalogue is the checkout's, so the install has a
    // `zig-out/bin` to fall back to.
    try testing.expect(specs[0].repo.len > 0);
    // The one default is the release index, and a dev build — this
    // one — has no release for it to name.
    try testing.expectEqual(@as(usize, 1), Config.default_marketplace_sources.len);
    try testing.expect(Config.default_marketplace_sources[0] == .release_index);
    try testing.expect(!release.isReleaseVersion(build_options.version));

    // The tab lists the three shipped integrations, each `✓ Official`,
    // each `not installed` in a fresh data root.
    app.tree.visible = false;
    app.tree.width = 70;
    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    var waited: u32 = 0;
    while (app.marketplace.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expectEqual(@as(usize, 3), app.marketplace.entries.len);
    try testing.expectEqual(@as(usize, 0), app.marketplace.problems.len);
    for (app.marketplace.entries) |e| {
        try testing.expectEqual(Kind.builtin, e.kind);
        try testing.expect(e.official and !e.private);
        try testing.expectEqualStrings("mnml", e.source);
        try testing.expect(e.binary.len > 0);
    }
    try app.render();
    const text = try screen_mod.toTestText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Marketplace (3)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Jira") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Bitbucket") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\u{2713} Official  not installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No sources yet") == null);
}

test "a mnml catalogue installs by linking the binary and running --install; the row turns installed, then update when the catalogue moves ahead; uninstall takes both" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    // The prebuilt sample: its `--install` writes the manifest the row
    // then counts, so nothing is built here.
    const exe = build_options.sample_integration_exe;
    Io.Dir.cwd().access(io, exe, .{}) catch return error.SkipZigTest;

    try tmp.dir.createDirPath(io, "cat");
    const cat_text = try std.fmt.allocPrint(gpa,
        \\.{{ .entries = .{{ .{{ .id = "sample", .label = "Sample", .description = "The counter", .category = "sample", .version = "0.1.0", .binary = "{s}" }} }} }}
    , .{exe});
    defer gpa.free(cat_text);
    try tmp.dir.writeFile(io, .{ .sub_path = "cat/marketplace.zon", .data = cat_text });
    const cat_path = try std.fs.path.join(gpa, &.{ root, "cat", "marketplace.zon" });
    defer gpa.free(cat_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_MARKETPLACE_CATALOGUE", cat_path);
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    app.tree.width = 70;
    try testing.expectEqual(@as(usize, 1), sourceCount(&app));
    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    var waited: u32 = 0;
    while (app.marketplace.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const st = &app.marketplace;
    try testing.expectEqual(@as(usize, 1), st.entries.len);
    try testing.expectEqual(Kind.builtin, st.entries[0].kind);
    try testing.expectEqual(catalogue.State.not_installed, try integrations.catalogueState(&app, app.frame.allocator(), st.entries[0].binary, "0.1.0"));

    // Install: the link goes down and `--install` writes the manifest.
    try install(&app, 0);
    waited = 0;
    while (st.installing != null and waited < 30_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(st.installing == null);
    const link = try std.fs.path.join(gpa, &.{ root, "bin", std.fs.path.basename(exe) });
    defer gpa.free(link);
    try Io.Dir.cwd().access(io, link, .{});
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expectEqualStrings("sample", app.integrations.list[0].id());
    // The manifest names the BARE binary; the link is the indirection.
    try testing.expectEqualStrings("mnml-sample", app.integrations.list[0].manifest.binary);
    try testing.expect(app.integrations.list[0].binary_found);
    try testing.expectEqual(catalogue.State.installed, try integrations.catalogueState(&app, app.frame.allocator(), "mnml-sample", "0.1.0"));
    // The catalogue moving ahead is the update signal — and the two
    // sides match on the file name, though this catalogue's binary is
    // an absolute path and the manifest's is the bare name.
    try testing.expectEqual(catalogue.State.update, try integrations.catalogueState(&app, app.frame.allocator(), exe, "0.2.0"));

    // Uninstall takes the manifest AND the link.
    try integrations.removeAccept(&app, "sample");
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, link, .{}));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "the manifest and the link") != null);
}

test "the repo's launchers/ as MNML_MARKETPLACE_LOCAL: four ✓ Official launcher rows with their glyphs; Install copies the file into the data root" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_MARKETPLACE_LOCAL", build_options.launchers_dir);
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    try testing.expectEqual(@as(usize, 1), sourceCount(&app));
    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    var waited: u32 = 0;
    while (app.marketplace.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const st = &app.marketplace;
    try testing.expectEqual(@as(usize, 4), st.entries.len);
    try testing.expectEqual(@as(usize, 0), st.problems.len);
    var htop: ?Entry = null;
    for (st.entries) |e| {
        try testing.expectEqual(Kind.launcher, e.kind);
        try testing.expect(e.official and !e.private);
        if (std.mem.eql(u8, e.id, "htop")) htop = e;
    }
    // htop's chip is pinned by codepoint; the entry carries it decoded.
    try testing.expectEqualStrings("\u{F1D00}", htop.?.glyph);
    try testing.expectEqualStrings("H", htop.?.fallback);
    app.tree.width = 60;
    try app.render();
    const txt = try screen_mod.toTestText(gpa, &app.screen);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "Marketplace (4)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[launcher] btop  \u{2713} Official  (local)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Resource monitor (cpu / mem / disk / net)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[launcher] htop  \u{2713} Official  (local)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Interactive process viewer") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Private") == null);
    // Install btop (the first row): the file lands and the Installed list has it.
    const btop = find(&app, "btop").?;
    try install(&app, btop);
    waited = 0;
    while (st.installing != null and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const written = try tmp.dir.readFileAlloc(io, "integrations/btop.zon", gpa, .unlimited);
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, ".run = \":term btop\"") != null);
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expect(app.integrations.list[0].manifest.isLauncher());
    try testing.expect(app.integrations.list[0].binary_found);
    try testing.expect(command.resolve(&app, "btop.open") != null);
    // A folder that is not the repo's stays Private.
    try testing.expect(!officialLocal(&app, root));
}

test "parseContents keeps the shape GitHub sends; safeName is the path guard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try parseContents(arena_state.allocator(), apps_json);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("mnml-jira", got[0].name);
    try testing.expectEqualStrings("dir", got[0].type);
    try testing.expect(got[0].download_url == null);
    try testing.expectError(error.UnexpectedToken, parseContents(arena_state.allocator(), "{\"message\":\"rate limited\"}"));
    try testing.expect(!safeName("evil;rm"));
    try testing.expect(!safeName(".github"));
    try testing.expect(!safeName("bad name"));
    try testing.expect(safeName("mnml-jira"));
}

test "a fetch lists launchers and apps from a local server; a launcher installs as a manifest" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The routes need the port; the server needs the routes. Bind
    // first on an empty table, then swap the table in before serving.
    const routes = try arena.alloc(FakeGitHub.Route, 4);
    const fake = try FakeGitHub.start(gpa, io, routes);
    defer fake.stop();
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{fake.port});
    const listing = try std.mem.replaceOwned(u8, arena, listing_json, "BASE", base);
    routes[0] = .{ .path = "/repos/acme/launchers/contents/launchers", .body = listing };
    routes[1] = .{ .path = "/raw/hello.zon", .body = hello_zon };
    routes[2] = .{ .path = "/raw/broken.zon", .body = ".{ .id = " };
    routes[3] = .{ .path = "/repos/acme/mono/contents/apps", .body = apps_json };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var cfg: Config = .{};
    cfg.marketplace.use_defaults = false;
    cfg.marketplace.sources = &.{
        .{ .github_launcher_folder = .{ .id = "acme-launchers", .repo = "acme/launchers", .path = "launchers" } },
        .{ .github_monorepo_apps = .{ .id = "acme-apps", .repo = "acme/mono", .apps_dir = "apps" } },
        .{ .crates_keyword = .{ .id = "crates.io", .keyword = "mnml-integration" } },
    };
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_MARKETPLACE_API", base);
    var app = try App.initWith(gpa, io, .{ .cfg = cfg, .workspace = root, .data_root = root, .cols = 100, .rows = 20, .env = &env });
    defer app.deinit();
    app.tree.visible = false;

    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    try testing.expect(app.marketplace.fetching);
    var waited: u32 = 0;
    while (app.marketplace.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(!app.marketplace.fetching);
    const st = &app.marketplace;
    try testing.expectEqual(@as(usize, 2), st.entries.len);
    try testing.expectEqualStrings("hello", st.entries[0].id);
    try testing.expectEqual(Kind.launcher, st.entries[0].kind);
    try testing.expectEqualStrings("mnml-jira", st.entries[1].id);
    try testing.expectEqual(Kind.app, st.entries[1].kind);
    try testing.expectEqualStrings("apps/mnml-jira", st.entries[1].subpath);
    // broken.zon and the crates source are problems, not rows.
    try testing.expectEqual(@as(usize, 2), st.problems.len);
    // The section's Marketplace tab lists both, with their source.
    app.tree.width = 60;
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(gpa, &app.screen);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "INTEGRATIONS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Marketplace (2)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[launcher] Hello  ~ Community  (acme-launchers)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[app] mnml-jira  ~ Community  (acme-apps)") != null);

    // Install the launcher: the manifest lands in the data root and the
    // installed list picks it up.
    try install(&app, 0);
    try testing.expect(st.installing != null);
    waited = 0;
    while (st.installing != null and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(st.installing == null);
    const written = try tmp.dir.readFileAlloc(io, "integrations/hello.zon", gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings(hello_zon, written);
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expectEqualStrings("hello", app.integrations.list[0].id());
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "installed hello") != null);
}

/// Tick until the marketplace's worker is done — fetching and installing.
fn settle(app: *App) !void {
    var waited: u32 = 0;
    while ((app.marketplace.fetching or app.marketplace.installing != null) and waited < 30_000) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    if (app.marketplace.fetching or app.marketplace.installing != null) return error.Timeout;
}

/// An index with three integrations: `demo` (this SDK, every platform),
/// `old` (an SDK this mnml is not compatible with) and `elsewhere`
/// (released for no platform mnml runs on).
fn threeRowIndex(arena: Allocator, base: []const u8, tar_sha: []const u8, zip_sha: []const u8) ![]const u8 {
    const one = try release.demoIndex(arena, base, release.host_sdk, tar_sha, zip_sha);
    // demoIndex's body ends `]}]}`: splice two more rows in before the
    // outer `]}`.
    const head = one[0 .. one.len - 2];
    return std.fmt.allocPrint(arena,
        \\{s},
        \\ {{"id":"old","label":"Old","version":"1.0.0","sdk":"9.0.0","binary":"mnml-old","assets":[{{"target":"{s}","url":"{s}/old.tar.xz","sha256":"{s}"}}]}},
        \\ {{"id":"elsewhere","label":"Elsewhere","version":"1.0.0","sdk":"{s}","binary":"mnml-elsewhere","assets":[{{"target":"riscv64-unknown-linux-gnu","url":"{s}/e.tar.xz","sha256":"{s}"}}]}}]}}
    , .{ head, release.host_triple orelse "none", base, tar_sha, release.host_sdk, base, tar_sha });
}

test "the release index: only what this SDK and platform can run is listed, it shadows the catalogue's row, and Install downloads, checks the sha256, links and runs --install; then update when the index moves ahead" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // the fixture's binary is a shell script
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tar = @embedFile("testdata/marketplace/mnml-demo.tar.xz");
    const zip = @embedFile("testdata/marketplace/mnml-demo.zip");
    const tar_sha = release.sha256Hex(tar);
    const zip_sha = release.sha256Hex(zip);

    const routes = try arena.alloc(FakeGitHub.Route, 4);
    const fake = try FakeGitHub.start(gpa, io, routes);
    defer fake.stop();
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{fake.port});
    routes[0] = .{ .path = "/v1/integrations.json", .body = try threeRowIndex(arena, base, &tar_sha, &zip_sha) };
    routes[1] = .{ .path = "/mnml-demo.tar.xz", .body = tar };
    routes[2] = .{ .path = "/mnml-demo.zip", .body = zip };
    // The same index a version later: 0.5.0 of demo.
    const later = try std.mem.replaceOwned(u8, arena, routes[0].body, "\"version\":\"0.4.0\"", "\"version\":\"0.5.0\"");
    routes[3] = .{ .path = "/v2/integrations.json", .body = later };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    // A catalogue that also lists `demo` — the index's row wins it.
    try tmp.dir.createDirPath(io, "cat");
    try tmp.dir.writeFile(io, .{ .sub_path = "cat/marketplace.zon", .data = ".{ .entries = .{ .{ .id = \"demo\", .label = \"Demo (catalogue)\", .version = \"0.4.0\", .binary = \"mnml-demo\" }, .{ .id = \"cat-only\", .label = \"Cat only\", .version = \"0.1.0\", .binary = \"mnml-cat-only\" } } }" });
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_MARKETPLACE_CATALOGUE", try std.fs.path.join(arena, &.{ root, "cat", "marketplace.zon" }));
    try env.put("PATH", "/bin:/usr/bin");
    var cfg: Config = .{};
    cfg.marketplace.sources = &.{.{ .release_index = .{ .id = "releases", .url = try std.fmt.allocPrint(arena, "{s}/v1/integrations.json", .{base}) } }};
    var app = try App.initWith(gpa, io, .{ .cfg = cfg, .workspace = root, .data_root = root, .cols = 110, .rows = 24, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    app.tree.width = 80;
    // The default index needs this build's version, and a dev build has
    // none: the catalogue and the configured index are the two.
    try testing.expectEqual(@as(usize, 2), sourceCount(&app));

    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    try settle(&app);
    const st = &app.marketplace;
    try testing.expectEqual(@as(usize, 0), st.problems.len);
    // demo from the index; `old` and `elsewhere` not at all; the
    // catalogue's own demo row gone, its other row kept.
    try testing.expectEqual(@as(usize, 2), st.entries.len);
    const demo = find(&app, "demo").?;
    try testing.expectEqual(Kind.release, st.entries[demo].kind);
    try testing.expectEqualStrings("releases", st.entries[demo].source);
    try testing.expectEqualStrings("Demo", st.entries[demo].label);
    try testing.expectEqualStrings(release.host_sdk, st.entries[demo].sdk);
    try testing.expectEqualStrings(&tar_sha, st.entries[demo].sha256);
    try testing.expect(find(&app, "old") == null and find(&app, "elsewhere") == null);
    try testing.expectEqual(Kind.builtin, st.entries[find(&app, "cat-only").?].kind);
    try app.render();
    {
        const text = try screen_mod.toTestText(gpa, &app.screen);
        defer gpa.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "Marketplace (2)") != null);
        try testing.expect(std.mem.indexOf(u8, text, "Demo (catalogue)") == null);
    }

    // Install: downloaded, checked, unpacked under integrations/demo/bin,
    // linked into bin/, and its --install wrote the manifest.
    try install(&app, demo);
    try settle(&app);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "installed demo") != null);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "sha256 checked") != null);
    try Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ root, "integrations", "demo", "bin", "mnml-demo" }), .{});
    try Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ root, "bin", "mnml-demo" }), .{});
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expectEqualStrings("demo", app.integrations.list[0].id());
    try testing.expect(app.integrations.list[0].binary_found);
    try testing.expectEqual(catalogue.State.installed, try integrations.catalogueState(&app, app.frame.allocator(), "mnml-demo", st.entries[demo].version));

    // The index moves to 0.5.0: the row reads `update available`.
    app.cfg.marketplace.sources = &.{.{ .release_index = .{ .id = "releases", .url = try std.fmt.allocPrint(arena, "{s}/v2/integrations.json", .{base}) } }};
    try refresh(&app);
    try settle(&app);
    const moved = find(&app, "demo").?;
    try testing.expectEqualStrings("0.5.0", st.entries[moved].version);
    try testing.expectEqual(catalogue.State.update, try integrations.catalogueState(&app, app.frame.allocator(), "mnml-demo", st.entries[moved].version));
    try app.render();
    {
        const text = try screen_mod.toTestText(gpa, &app.screen);
        defer gpa.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "update available") != null);
    }
}

test "the release index: a download whose sha256 is not the index's installs nothing and says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tar = @embedFile("testdata/marketplace/mnml-demo.tar.xz");
    const zip = @embedFile("testdata/marketplace/mnml-demo.zip");
    // The index names the OTHER archive's sum for every asset.
    const wrong_tar = release.sha256Hex(zip);
    const wrong_zip = release.sha256Hex(tar);
    const routes = try arena.alloc(FakeGitHub.Route, 3);
    const fake = try FakeGitHub.start(gpa, io, routes);
    defer fake.stop();
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{fake.port});
    routes[0] = .{ .path = "/integrations.json", .body = try release.demoIndex(arena, base, release.host_sdk, &wrong_tar, &wrong_zip) };
    routes[1] = .{ .path = "/mnml-demo.tar.xz", .body = tar };
    routes[2] = .{ .path = "/mnml-demo.zip", .body = zip };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_MARKETPLACE_INDEX", try std.fmt.allocPrint(arena, "{s}/integrations.json", .{base}));
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 20, .env = &env });
    defer app.deinit();
    try testing.expectEqual(@as(usize, 1), sourceCount(&app));
    try refresh(&app);
    try settle(&app);
    try testing.expectEqual(@as(usize, 1), app.marketplace.entries.len);
    try testing.expectEqualStrings("index", app.marketplace.entries[0].source);
    try install(&app, 0);
    try settle(&app);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "sha256 mismatch") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "integrations/demo", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin", .{}));
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
}

test "<data root>/marketplace/local lists with no config: loose manifests and integration folders, a symlinked repo's too, each Private" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var cfg: Config = .{};
    cfg.marketplace.use_defaults = false;
    var app = try App.initWith(gpa, io, .{ .cfg = cfg, .workspace = root, .data_root = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    app.tree.width = 70;
    // No folder: no source.
    try testing.expectEqual(@as(usize, 0), sourceCount(&app));

    try tmp.dir.createDirPath(io, "marketplace/local/solo");
    try tmp.dir.writeFile(io, .{ .sub_path = "marketplace/local/hello.zon", .data = hello_zon });
    try tmp.dir.writeFile(io, .{ .sub_path = "marketplace/local/solo/build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "marketplace/local/solo/manifest.zon", .data = ".{ .id = \"solo\", .label = \"Solo\", .version = \"0.1.0\", .binary = \"mnml-solo\" }" });
    // A private repo, elsewhere, linked in whole: its own build.zig.zon
    // is no manifest, and its integrations/<id>/ list.
    try tmp.dir.createDirPath(io, "privrepo/integrations/secret");
    try tmp.dir.createDirPath(io, "privrepo/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "privrepo/build.zig.zon", .data = ".{ .name = .privrepo }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "privrepo/integrations/secret/build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "privrepo/integrations/secret/manifest.zon", .data = ".{ .id = \"secret\", .label = \"Secret\", .version = \"0.3.0\", .binary = \"mnml-secret\", .description = \"Only its author sees it\" }" });
    const linked = if (@import("builtin").os.tag == .windows) false else blk: {
        const target = try std.fs.path.join(gpa, &.{ root, "privrepo" });
        defer gpa.free(target);
        const link = try std.fs.path.join(gpa, &.{ root, "marketplace", "local", "privrepo" });
        defer gpa.free(link);
        Io.Dir.cwd().symLink(io, target, link, .{ .is_directory = true }) catch break :blk false;
        break :blk true;
    };
    try testing.expectEqual(@as(usize, 1), sourceCount(&app));
    const specs = try sources(&app, gpa);
    defer {
        for (specs) |sp| sp.deinit(gpa);
        gpa.free(specs);
    }
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expect(specs[0].kind == .local_folder);
    try testing.expectEqualStrings("local", specs[0].id);
    try testing.expect(!specs[0].official);

    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    try settle(&app);
    const st = &app.marketplace;
    try testing.expectEqual(@as(usize, 0), st.problems.len);
    try testing.expectEqual(@as(usize, if (linked) 3 else 2), st.entries.len);
    for (st.entries) |e| {
        try testing.expect(e.private and !e.official);
        try testing.expectEqualStrings("local", e.source);
    }
    try testing.expectEqual(Kind.launcher, st.entries[find(&app, "hello").?].kind);
    try testing.expectEqual(Kind.app, st.entries[find(&app, "solo").?].kind);
    if (linked) try testing.expectEqual(Kind.app, st.entries[find(&app, "secret").?].kind);
    try app.render();
    const text = try screen_mod.toTestText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Private") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(local)") != null);
}
