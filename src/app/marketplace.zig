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
const settings = @import("settings.zig");
const child_os = @import("../core/child.zig");
const builtin = @import("builtin");

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
        /// An install finished; `id` names the entry. `rebuilt`: it was
        /// a rebuild of an installed integration from its folder
        /// (`integrations.rebuild_*`), not a first install.
        /// `warn`: it finished, but not as asked — a rebuild whose
        /// manifest is still stamped behind this mnml's SDK.
        installed: struct { id: []u8, detail: []u8, rebuilt: bool = false, warn: bool = false },
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
    /// The listing fetch. A refresh cancels it and starts another.
    fetch_group: Io.Group = .init,
    /// The install or rebuild running, apart from the fetch: a refresh
    /// re-reads the listing and has no business with an install the
    /// user started — cancelling it there blocked the UI thread until
    /// the install's child exited. Only `deinit` cancels this one, and
    /// a cancelled install stops its child (`run`).
    install_group: Io.Group = .init,
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
    /// Owns `cfg.marketplace.sources` once `addSource` has grown it in
    /// memory (the loaded config's arena is not ours to extend).
    cfg_arena: ?std.heap.ArenaAllocator = null,
    /// How an app folder is built in place — `zig build` by default; a
    /// test swaps in one that copies a prebuilt binary, the way it swaps
    /// the fetcher, so the build-then-`--install` path runs whole.
    builder: Builder = zigBuild,
    /// Installed integrations waiting to be rebuilt from their folders
    /// (`integrations.rebuild_stale` / `rebuild_focused`), one at a time
    /// behind whatever install is running. gpa-owned.
    rebuilds: std.ArrayListUnmanaged(Rebuild) = .empty,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.fetch_group.cancel(io);
        self.install_group.cancel(io);
        if (self.cfg_arena) |*a| a.deinit();
        if (self.arena) |*a| a.deinit();
        if (self.installing) |i| gpa.free(i);
        for (self.queue.items) |q| gpa.free(q);
        self.queue.deinit(gpa);
        for (self.rebuilds.items) |r| r.deinit(gpa);
        self.rebuilds.deinit(gpa);
    }
};

/// One queued rebuild: the installed id and the folder it builds from.
pub const Rebuild = struct {
    id: []u8,
    dir: []u8,

    fn deinit(r: Rebuild, gpa: Allocator) void {
        gpa.free(r.id);
        gpa.free(r.dir);
    }
};

/// Builds the integration folder `app_dir` into `prefix` (so its binary
/// lands in `<prefix>/bin/`). A non-zero exit is `Failed` with `why`.
pub const Builder = *const fn (io: Io, gpa: Allocator, arena: Allocator, app_dir: []const u8, prefix: []const u8, env: *const std.process.Environ.Map, why: *[]const u8) InstallError!void;

/// The real build: `zig build -Doptimize=ReleaseSafe --prefix <prefix>`
/// in the folder — what a `local_folder` install and a rebuild both run.
pub fn zigBuild(io: Io, gpa: Allocator, arena: Allocator, app_dir: []const u8, prefix: []const u8, env: *const std.process.Environ.Map, why: *[]const u8) InstallError!void {
    return run(io, gpa, arena, &.{ "zig", "build", "-Doptimize=ReleaseSafe", "--prefix", prefix }, app_dir, env, "zig build", why);
}

/// The file beside an app install's binary that names the folder it was
/// built from: `<root>/integrations/<id>/built-from`. A rebuild reads it
/// to know where to build again.
pub const built_from_file = "built-from";

/// The folder `id` was built from, when an install recorded one.
pub fn builtFrom(io: Io, arena: Allocator, root: []const u8, id: []const u8) ?[]const u8 {
    manifest_mod.validateId(id) catch return null;
    const p = std.fs.path.join(arena, &.{ root, manifest_mod.subdir, id, built_from_file }) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4096)) catch return null;
    const dir = std.mem.trim(u8, text, " \r\n\t");
    if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return null;
    return dir;
}

pub const table = .{
    .@"marketplace.refresh" = &refreshCmd,
    .@"marketplace.add_source" = &addSourceCmd,
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
    st.fetch_group.cancel(app.io);
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
    st.fetch_group.concurrent(app.io, fetchWorker, .{ app.events, app.io, gpa, specs, api, st.generation, st.fetcher }) catch |err| {
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

fn fetchWorker(events: *event.EventQueue, io: Io, gpa: Allocator, specs: []SourceSpec, api: []u8, generation: u32, fetcher: release.Fetcher) void {
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
        listSource(io, gpa, arena, api, s, fetcher, &entries, &problems) catch {
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

fn listSource(io: Io, gpa: Allocator, arena: Allocator, api: []const u8, s: SourceSpec, fetcher: release.Fetcher, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    switch (s.kind) {
        .crates => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: crates.io sources are not searched — integrations are Zig packages now", .{s.id}));
            return;
        },
        .mnml => return listCatalogue(io, arena, s, entries, problems),
        .local_folder => return listLocal(io, arena, s, entries, problems),
        .release_index => return listIndex(io, gpa, arena, s, fetcher, entries, problems),
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
fn listIndex(io: Io, gpa: Allocator, arena: Allocator, s: SourceSpec, fetcher: release.Fetcher, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const body = switch (try fetcher.get(fetcher.ctx, gpa, io, arena, s.path)) {
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
/// A folder that is itself an integration (`build.zig` + `manifest.zon`)
/// is that one app, built in place — its `manifest.zon` is never a
/// launcher to copy.
fn listLocal(io: Io, arena: Allocator, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    var dir = Io.Dir.cwd().openDir(io, s.path, .{ .iterate = true }) catch {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} is not a directory", .{ s.id, s.path }));
        return;
    };
    defer dir.close(io);
    // A repo root has a `build.zig` too, but no `manifest.zon`: it is
    // walked for the integrations under it.
    if (isIntegrationDir(io, dir)) {
        const text = dir.readFileAllocOptions(io, "manifest.zon", arena, .limited(1 << 20), .of(u8), 0) catch |err| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/manifest.zon: {s}", .{ s.id, @errorName(err) }));
            return;
        };
        // `s.path` is the worker's, freed when it ends: the row keeps a copy.
        try appendManifest(arena, s, .app, text, "manifest.zon", try arena.dupe(u8, s.path), entries, problems);
        return;
    }
    try listLocalDir(io, arena, s, dir, s.path, 0, entries, problems);
}

/// A Zig integration's folder: `build.zig` and `manifest.zon` side by side.
fn isIntegrationDir(io: Io, dir: Io.Dir) bool {
    _ = dir.statFile(io, "build.zig", .{}) catch return false;
    _ = dir.statFile(io, "manifest.zon", .{}) catch return false;
    return true;
}

/// Parse `text` and list it as a `kind` row at `full`; a manifest that
/// does not parse is a problem named by `name`.
fn appendManifest(arena: Allocator, s: SourceSpec, kind: Kind, text: [:0]const u8, name: []const u8, full: []const u8, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    var why: []const u8 = "";
    const m = manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadManifest => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}: {s}", .{ s.id, name, why }));
            return;
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
        try appendManifest(arena, s, kind, text, entry.name, full, entries, problems);
    }
}

/// Build output and dependency folders a repo scan never walks into.
fn skipDir(name: []const u8) bool {
    const skip = [_][]const u8{ "zig-out", "zig-pkg", "node_modules", "target", "vendor" };
    for (skip) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

// ─── add a source ───────────────────────────────────────────────────────
//
// `addSource` is the one code path behind every "add a private source"
// entry point: the palette's `marketplace.add_source`, the Marketplace
// tab's `+ source` chip and its tab menu (all three open the same
// prompt), and the first-launch wizard's Private integrations row.

/// What `addSource` read its input as.
pub const SourceInput = union(enum) {
    /// A folder: where it is, and what the config keeps — the typed
    /// `~/…` form when it was one, else the absolute path (a relative
    /// path means nothing in the home config, which every workspace
    /// reads).
    folder: struct { abs: []const u8, keep: []const u8 },
    /// `owner/repo[:apps_dir]`, a `github_monorepo_apps` source.
    repo: struct { repo: []const u8, apps_dir: []const u8 },
    /// A URL that names no repo this can add: why, for the toast.
    refused: []const u8,
};

/// What `addSource` added: the id it chose, and for a folder how many
/// integrations it found there (a repo is not fetched to count).
pub const Added = struct { id: []const u8, found: ?usize };

/// The ids mnml's own sources list under (`sources`): a configured one
/// never takes them, so a row's `(source)` is never ambiguous.
const reserved_ids = [_][]const u8{ "mnml", "local", "index", "github" };

/// `input` as a folder or a repo. A path that says it is one (`/`, `~`,
/// `.`, a drive letter) or names a folder that is there is a folder;
/// else `owner/repo[:apps_dir]` is a repo; else it is a folder that is
/// not there, which `addSource` refuses by name.
pub fn parseSourceInput(app: *App, arena: Allocator, input: []const u8) Allocator.Error!SourceInput {
    const raw = std.mem.trim(u8, input, " \t\r\n");
    // A URL is never a folder: `https://…` resolved against the
    // workspace is a path nobody typed.
    const schemed = std.mem.indexOf(u8, raw, "://") != null;
    if (schemed or std.mem.startsWith(u8, raw, "git@")) return urlInput(arena, raw);
    const expanded = try app.expandTilde(raw);
    // Resolved, not joined: `tools/acme` typed on Windows becomes one
    // path with one separator, and `..` collapses, so the file keeps a
    // clean spelling on every platform.
    const abs = try std.fs.path.resolve(arena, &.{ app.workspace, expanded });
    const keep = if (raw.len > 0 and raw[0] == '~') try arena.dupe(u8, raw) else abs;
    const says_path = raw.len > 0 and (raw[0] == '/' or raw[0] == '~' or raw[0] == '.' or raw[0] == '\\' or std.fs.path.isAbsolute(raw));
    if (says_path or isDir(app.io, abs)) return .{ .folder = .{ .abs = abs, .keep = keep } };
    // `github.com/owner/repo` — a browser's address bar without its
    // scheme — once no folder by that name is here.
    if (githubHost(raw)) return urlInput(arena, raw);
    if (repoShape(raw)) |r| return .{ .repo = .{ .repo = try arena.dupe(u8, r.repo), .apps_dir = try arena.dupe(u8, r.dir) } };
    return .{ .folder = .{ .abs = abs, .keep = keep } };
}

/// `path` as the OS spells it — symlinks followed, and on a volume that
/// folds case, the case it was created with. A folder that cannot be
/// resolved (gone) is its own spelling.
fn realFolder(io: Io, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => path,
    };
}

/// Whether `rest` (a URL without its scheme) starts with GitHub's host.
fn githubHost(rest: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..end];
    return std.ascii.eqlIgnoreCase(host, "github.com") or std.ascii.eqlIgnoreCase(host, "www.github.com");
}

const url_forms = "give a folder, owner/repo[:dir], or a GitHub repo URL (github.com/owner/repo, …/tree/<branch>/<dir>)";

/// A URL typed or pasted where a folder or `owner/repo` was asked for:
/// a GitHub repo URL — `https://`, `http://` or none, `www.`, a
/// trailing `.git` or `/`, a `?query` or `#anchor`, `…/tree/<branch>/<dir>`
/// for the apps dir, or `git@github.com:owner/repo.git` — is that repo.
/// The branch is not kept: a source lists the repo's default branch.
/// Anything else is refused by name.
fn urlInput(arena: Allocator, raw: []const u8) Allocator.Error!SourceInput {
    var rest = raw;
    if (std.mem.startsWith(u8, raw, "git@github.com:")) {
        rest = try std.fmt.allocPrint(arena, "github.com/{s}", .{raw["git@github.com:".len..]});
    } else if (std.mem.indexOf(u8, raw, "://")) |i| {
        const scheme = raw[0..i];
        if (!std.ascii.eqlIgnoreCase(scheme, "https") and !std.ascii.eqlIgnoreCase(scheme, "http"))
            return .{ .refused = try std.fmt.allocPrint(arena, "{s} is a URL, not a source \u{2014} {s}", .{ raw, url_forms }) };
        rest = raw[i + 3 ..];
    }
    if (!githubHost(rest))
        return .{ .refused = try std.fmt.allocPrint(arena, "{s} is not a GitHub repo URL \u{2014} {s}", .{ raw, url_forms }) };
    var path = rest[(std.mem.indexOfScalar(u8, rest, '/') orelse rest.len)..];
    if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
    path = std.mem.trim(u8, path, "/");
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| try segs.append(arena, seg);
    const s = segs.items;
    const dir: []const u8 = if (s.len == 2 or (s.len == 4 and std.mem.eql(u8, s[2], "tree")))
        "apps"
    else if (s.len >= 5 and std.mem.eql(u8, s[2], "tree"))
        try std.mem.join(arena, "/", s[4..])
    else
        return .{ .refused = try std.fmt.allocPrint(arena, "{s} names no repo \u{2014} {s}", .{ raw, url_forms }) };
    const name = if (std.mem.endsWith(u8, s[1], ".git")) s[1][0 .. s[1].len - 4] else s[1];
    const shaped = try std.fmt.allocPrint(arena, "{s}/{s}:{s}", .{ s[0], name, dir });
    const r = repoShape(shaped) orelse
        return .{ .refused = try std.fmt.allocPrint(arena, "{s} names no repo \u{2014} {s}", .{ raw, url_forms }) };
    return .{ .repo = .{ .repo = r.repo, .apps_dir = r.dir } };
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// `owner/repo[:apps_dir]` — GitHub's name characters, one slash; the
/// apps dir a relative path with no `..`. Null for anything else.
pub fn repoShape(s: []const u8) ?struct { repo: []const u8, dir: []const u8 } {
    const g = githubOverride(s);
    const slash = std.mem.indexOfScalar(u8, g.repo, '/') orelse return null;
    const owner = g.repo[0..slash];
    const name = g.repo[slash + 1 ..];
    if (!nameOk(owner) or !nameOk(name)) return null;
    if (g.dir.len == 0 or g.dir[0] == '/' or std.mem.indexOf(u8, g.dir, "..") != null) return null;
    for (g.dir) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return null;
    return .{ .repo = g.repo, .dir = g.dir };
}

fn nameOk(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

/// `base`, or `base-2`, `base-3`… — the first no configured source and
/// none of mnml's own uses, in any letter case: two sources whose ids
/// differ only by case read as one in a row's `(source)`.
fn uniqueId(app: *App, arena: Allocator, base: []const u8) Allocator.Error![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const id = if (n == 1) base else try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
        const taken = for (reserved_ids) |r| {
            if (std.ascii.eqlIgnoreCase(r, id)) break true;
        } else for (app.cfg.marketplace.sources) |s| {
            if (std.ascii.eqlIgnoreCase(sourceId(s), id)) break true;
        } else false;
        if (!taken) return id;
    }
}

fn sourceId(s: Config.MarketplaceSource) []const u8 {
    return switch (s) {
        inline else => |v| v.id,
    };
}

/// An id from a folder or repo name, read per codepoint: ASCII letters,
/// digits, `-`, `_` and `.` stay; an accented Latin letter is its base
/// letter (`é` → `e`, `ß` → `ss`); a combining accent (how macOS may
/// spell `é`) goes; any other run is one `-`. Ids stay ASCII, so every
/// row's `(source)` and every toast reads the same in any terminal. A
/// name with nothing left is `private`.
fn idFrom(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var dash = false;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        const cp: u21 = if (len > 1 and i + len <= name.len)
            std.unicode.utf8Decode(name[i .. i + len]) catch 0xFFFD
        else
            name[i];
        i += if (i + len <= name.len) len else 1;
        if (cp >= 0x300 and cp <= 0x36F) continue;
        const keep: []const u8 = if (cp < 0x80 and (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '-' or cp == '_' or cp == '.'))
            name[i - 1 .. i]
        else if (cp >= 0xC0 and cp < 0xC0 + latin_fold.len)
            latin_fold[cp - 0xC0]
        else
            "";
        if (keep.len == 0) {
            dash = true;
            continue;
        }
        if (dash and out.items.len > 0) try out.append(arena, '-');
        dash = false;
        try out.appendSlice(arena, keep);
    }
    if (out.items.len == 0) return arena.dupe(u8, "private");
    return out.items;
}

/// U+00C0…U+017F (Latin-1 Supplement, Latin Extended-A) as ASCII: the
/// base letter, or "" for the two signs (`×`, `÷`) among them.
const latin_fold = [_][]const u8{
    "A", "A", "A", "A", "A", "A", "AE", "C", "E", "E", "E", "E", "I", "I", "I", "I", "D", "N", "O",  "O",  "O", "O", "O", "",  "O", "U", "U", "U", "U", "Y", "TH", "ss",
    "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i", "d", "n", "o",  "o",  "o", "o", "o", "",  "o", "u", "u", "u", "u", "y", "th", "y",
    "A", "a", "A", "a", "A", "a", "C",  "c", "C", "c", "C", "c", "C", "c", "D", "d", "D", "d", "E",  "e",  "E", "e", "E", "e", "E", "e", "E", "e", "G", "g", "G",  "g",
    "G", "g", "G", "g", "H", "h", "H",  "h", "I", "i", "I", "i", "I", "i", "I", "i", "I", "i", "IJ", "ij", "J", "j", "K", "k", "k", "L", "l", "L", "l", "L", "l",  "L",
    "l", "L", "l", "N", "n", "N", "n",  "N", "n", "n", "N", "n", "O", "o", "O", "o", "O", "o", "OE", "oe", "R", "r", "R", "r", "R", "r", "S", "s", "S", "s", "S",  "s",
    "S", "s", "T", "t", "T", "t", "T",  "t", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "U",  "u",  "W", "w", "Y", "y", "Y", "Z", "z", "Z", "z", "Z", "z",  "s",
};

/// Add `input` — a folder (`~` expanded, relative to the workspace) or
/// `owner/repo[:apps_dir]` — to `marketplace.sources`, list it, and show
/// the Marketplace tab. A folder is checked by listing it exactly as the
/// tab will (`listLocal`): one with nothing to install is refused. A
/// repo is checked for its shape only — nothing is fetched here.
///
/// The entry is appended to the HOME `config.zon` through the settings
/// splice (`[+]`, `zon_edit`): the file is edited in place, so its
/// comments, its order and the sources already there keep their bytes.
/// Never the workspace layer: a source is a list of things to build
/// and run, and a workspace layer is what a cloned repo brings with it —
/// the trust stripper (`config/trust.zig`) is there to keep a checkout
/// from choosing what runs, and this path must not hand a checkout a
/// source its owner added for themselves. The home layer is the user's
/// own, the same file the Settings overlay writes.
pub fn addSource(app: *App, input: []const u8) CommandError!Added {
    const arena = app.frame.allocator();
    const raw = std.mem.trim(u8, input, " \t\r\n");
    if (raw.len == 0) return app.diag.fail(arena, "marketplace: give a folder or owner/repo", .{});
    // Refused before anything is written: a source added to a disabled
    // Marketplace would sit in config.zon behind an error toast.
    if (!app.cfg.marketplace.enabled) return app.diag.fail(arena, "marketplace: disabled in config (marketplace.enabled) \u{2014} nothing added", .{});
    const parsed = try parseSourceInput(app, arena, raw);
    var found: ?usize = null;
    // A folder's rows, read to count them: listed at once (`showNow`).
    var rows: []const Entry = &.{};
    var entry: Config.MarketplaceSource = undefined;
    switch (parsed) {
        .refused => |why| return app.diag.fail(arena, "marketplace: {s}", .{why}),
        .folder => |f| {
            if (!isDir(app.io, f.abs)) return app.diag.fail(arena, "marketplace: {s} is not a folder", .{f.keep});
            // Compared by where the folder really is: a symlink to it, or
            // its name in other letters on a volume that folds case, is
            // the same folder (the OS's real path spells it one way).
            const real = try realFolder(app.io, arena, f.abs);
            for (app.cfg.marketplace.sources) |s| if (s == .local_folder) {
                const spec = try specOf(app, arena, s);
                if (std.mem.eql(u8, try realFolder(app.io, arena, spec.path), real)) return app.diag.fail(arena, "marketplace: {s} is already the source {s}", .{ f.keep, s.local_folder.id });
            };
            // What the tab will list, listed now: the count, and the
            // refusal of a folder with nothing in it.
            const probe: SourceSpec = .{ .id = @constCast("probe"), .kind = .local_folder, .repo = @constCast(""), .path = @constCast(f.abs) };
            var entries: std.ArrayListUnmanaged(Entry) = .empty;
            var problems: std.ArrayListUnmanaged([]const u8) = .empty;
            try listLocal(app.io, arena, probe, &entries, &problems);
            if (entries.items.len == 0) {
                return app.diag.fail(arena, "marketplace: nothing to install in {s} — it needs a *.zon manifest, or a folder with build.zig and manifest.zon", .{f.keep});
            }
            found = entries.items.len;
            rows = entries.items;
            const base = std.fs.path.basename(std.mem.trimEnd(u8, f.abs, "/\\"));
            entry = .{ .local_folder = .{ .id = try uniqueId(app, arena, try idFrom(arena, base)), .path = f.keep } };
        },
        .repo => |r| {
            // GitHub owner and repo names are case-insensitive; the apps
            // dir is a path in the repo, which is not.
            for (app.cfg.marketplace.sources) |s| if (s == .github_monorepo_apps and std.ascii.eqlIgnoreCase(s.github_monorepo_apps.repo, r.repo) and std.mem.eql(u8, s.github_monorepo_apps.apps_dir, r.apps_dir)) {
                return app.diag.fail(arena, "marketplace: {s} is already the source {s}", .{ r.repo, s.github_monorepo_apps.id });
            };
            const name = r.repo[std.mem.indexOfScalar(u8, r.repo, '/').? + 1 ..];
            entry = .{ .github_monorepo_apps = .{ .id = try uniqueId(app, arena, try idFrom(arena, name)), .repo = r.repo, .apps_dir = r.apps_dir } };
        },
    }

    // The file first: a source that cannot be saved is not added.
    const path = (try settings.configPath(app, .home)) orelse return app.diag.fail(arena, "marketplace: no home config to add the source to", .{});
    const literal = try config.persist.serializeLiteral(arena, entry);
    _ = config.persist.persistScalar(app.gpa, app.io, path, &.{ "marketplace", "sources", config.persist.append_key }, literal) catch |err| {
        return app.diag.fail(arena, "marketplace: could not write {s}: {s}", .{ path, @errorName(err) });
    };

    // Then the config in memory: the same list plus the entry, owned by
    // the state (the loaded config's arena is not ours to grow).
    const st = &app.marketplace;
    if (st.cfg_arena == null) st.cfg_arena = .init(app.gpa);
    const own = st.cfg_arena.?.allocator();
    const old = app.cfg.marketplace.sources;
    const grown = try own.alloc(Config.MarketplaceSource, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = switch (entry) {
        .local_folder => |l| .{ .local_folder = .{ .id = try own.dupe(u8, l.id), .path = try own.dupe(u8, l.path) } },
        .github_monorepo_apps => |g| .{ .github_monorepo_apps = .{ .id = try own.dupe(u8, g.id), .repo = try own.dupe(u8, g.repo), .apps_dir = try own.dupe(u8, g.apps_dir) } },
        else => unreachable,
    };
    app.cfg.marketplace.sources = grown;
    const id = sourceId(grown[old.len]);

    try refresh(app);
    try showNow(app, id, rows);
    try integrations.showTab(app, .marketplace);
    if (found) |n| {
        app.toast("added {s}: {d} integration{s} found", .{ id, n, if (n == 1) "" else "s" });
    } else {
        app.toast("added {s}: {s} ({s}/) — listing it now", .{ id, entry.github_monorepo_apps.repo, entry.github_monorepo_apps.apps_dir });
    }
    return .{ .id = id, .found = found };
}

/// A folder just added is listed now, beside the rows already shown:
/// listing a folder is quick and was done already to count it, while
/// the fetch `refresh` started re-lists every source and may wait on a
/// slow one. That fetch's listing replaces this one when it lands.
fn showNow(app: *App, id: []const u8, rows: []const Entry) Allocator.Error!void {
    if (rows.len == 0) return;
    const st = &app.marketplace;
    var next = std.heap.ArenaAllocator.init(app.gpa);
    errdefer next.deinit();
    const a = next.allocator();
    const entries = try a.alloc(Entry, st.entries.len + rows.len);
    for (st.entries, 0..) |e, i| entries[i] = try dupeEntry(a, e);
    for (rows, st.entries.len..) |e, i| {
        entries[i] = try dupeEntry(a, e);
        entries[i].source = try a.dupe(u8, id);
    }
    const problems = try a.alloc([]const u8, st.problems.len);
    for (st.problems, 0..) |p, i| problems[i] = try a.dupe(u8, p);
    if (st.arena) |*old| old.deinit();
    st.arena = next;
    st.entries = entries;
    st.problems = problems;
    app.needs_render = true;
}

/// `e` with every string copied onto `a`.
fn dupeEntry(a: Allocator, e: Entry) Allocator.Error!Entry {
    var out = e;
    inline for (std.meta.fields(Entry)) |f| if (f.type == []const u8) {
        @field(out, f.name) = try a.dupe(u8, @field(e, f.name));
    };
    return out;
}

/// The prompt's title and its placeholder — one prompt for every entry
/// point.
pub const add_source_title = "Marketplace: add a private source (a folder or owner/repo)";
pub const add_source_placeholder = "a folder (~/my-integrations) or owner/repo[:apps]";

/// Open the shared prompt; its Enter runs `addSource`
/// (`addSourceAccept`), Esc cancels.
pub fn openAddSourcePrompt(app: *App, from: app_mod.PromptPurpose.AddSourceFrom) void {
    app.overlay.deinit(app.gpa);
    var ps = app_mod.Prompt.init(app.gpa, add_source_title);
    ps.placeholder = add_source_placeholder;
    app.overlay = .{ .prompt = .{ .state = ps, .purpose = .{ .marketplace_add_source = from } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `marketplace.add_source` — the palette, the `+ source` chip and the
/// tab menu.
fn addSourceCmd(app: *App) CommandError!void {
    openAddSourcePrompt(app, .palette);
}

/// The prompt's Enter.
pub fn addSourceAccept(app: *App, text: []const u8) CommandError!void {
    _ = try addSource(app, text);
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
    // A rebuild needs no listing: it names its folder.
    if (st.installing == null and st.rebuilds.items.len > 0) {
        const r = st.rebuilds.orderedRemove(0);
        defer r.deinit(app.gpa);
        try startJob(app, .{ .source = "local", .kind = .app, .id = r.id, .label = r.id, .description = "", .url = r.dir }, true);
    }
}

/// Queue a rebuild of installed `id` from `dir` — the same in-place
/// build a `local_folder` install runs, then `--install` again, so the
/// manifest is stamped with this mnml's SDK. Runs behind whatever
/// install or rebuild is ahead of it.
pub fn enqueueRebuild(app: *App, id: []const u8, dir: []const u8) CommandError!void {
    const st = &app.marketplace;
    if (st.installing) |cur| if (std.mem.eql(u8, cur, id)) return;
    for (st.rebuilds.items) |r| if (std.mem.eql(u8, r.id, id)) return;
    const owned_id = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(owned_id);
    const owned_dir = try app.gpa.dupe(u8, dir);
    errdefer app.gpa.free(owned_dir);
    try st.rebuilds.append(app.gpa, .{ .id = owned_id, .dir = owned_dir });
    try pump(app);
}

/// Install the entry at `idx` on a worker: a launcher's manifest is
/// fetched and written; an app is cloned and built; a release-index
/// row is downloaded and checked.
pub fn install(app: *App, idx: usize) CommandError!void {
    const st = &app.marketplace;
    if (idx >= st.entries.len) return;
    return startJob(app, st.entries[idx], false);
}

fn startJob(app: *App, e: Entry, rebuild: bool) CommandError!void {
    const st = &app.marketplace;
    if (st.installing != null) return app.diag.fail(app.frame.allocator(), "marketplace: an install is already running", .{});
    if (app.data_root.len == 0) return app.diag.fail(app.frame.allocator(), "marketplace: no data root to install into", .{});
    const gpa = app.gpa;
    const job = try gpa.create(InstallJob);
    errdefer gpa.destroy(job);
    job.* = .{ .kind = e.kind, .id = &.{}, .root = &.{}, .url = &.{}, .subpath = &.{}, .binary = &.{}, .repo = &.{}, .asset_name = &.{}, .sha256 = &.{}, .fetcher = st.fetcher, .builder = st.builder, .rebuild = rebuild, .env = undefined };
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
    st.install_group.concurrent(app.io, installWorker, .{ app.events, app.io, gpa, job, st.generation }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "marketplace: cannot start the install: {s}", .{@errorName(err)});
    };
    st.installing = try gpa.dupe(u8, e.id);
    if (rebuild)
        app.toast("rebuilding {s} against SDK {s}…", .{ e.id, sdk_version })
    else
        app.toast("marketplace: installing {s}…", .{e.id});
}

/// The SDK this mnml carries — what a rebuild stamps.
const sdk_version = @import("mnml_sdk").version;

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
    builder: Builder,
    /// A rebuild of an installed integration, not a first install.
    rebuild: bool = false,
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

pub const InstallError = error{ OutOfMemory, Canceled, Failed };

fn installWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *InstallJob, generation: u32) void {
    defer job.destroy(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    var warn = false;
    const detail = installInner(io, gpa, arena, job, &why, &warn) catch |err| switch (err) {
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
    post(events, io, gpa, .{ .generation = generation, .kind = .{ .installed = .{ .id = id, .detail = d, .rebuilt = job.rebuild, .warn = warn } } });
}

fn installInner(io: Io, gpa: Allocator, arena: Allocator, job: *InstallJob, why: *[]const u8, warn: *bool) InstallError![]const u8 {
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
                Io.Dir.cwd().readFileAlloc(io, job.url, arena, .limited(1 << 20)) catch |err| {
                    keepCancel(io, err);
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
            Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch |err| keepCancel(io, err);
            Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
                keepCancel(io, err);
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
                    Io.Dir.cwd().access(io, clone_dir, .{}) catch |err| {
                        keepCancel(io, err);
                        break :e false;
                    };
                    break :e true;
                };
                if (!exists) {
                    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(clone_dir).?) catch |err| keepCancel(io, err);
                    const git_url = try std.fmt.allocPrint(arena, "https://github.com/{s}.git", .{job.url});
                    try run(io, gpa, arena, &.{ "git", "clone", "--depth", "1", git_url, clone_dir }, null, &job.env, "git clone", why);
                } else {
                    // A failed pull builds what is there; a cancel stops.
                    run(io, gpa, arena, &.{ "git", "-C", clone_dir, "pull", "--ff-only" }, null, &job.env, "git pull", why) catch |err| switch (err) {
                        error.Canceled, error.OutOfMemory => |e| return e,
                        error.Failed => {},
                    };
                }
                break :blk try std.fs.path.join(arena, &.{ clone_dir, job.subpath });
            };
            // A folder deleted since it was listed (or queued for a
            // rebuild): said so, not left to the spawn, which blames argv[0].
            Io.Dir.cwd().access(io, app_dir, .{}) catch {
                why.* = try std.fmt.allocPrint(arena, "its folder {s} is gone \u{2014} nothing to build", .{app_dir});
                return error.Failed;
            };
            const prefix = try std.fs.path.join(arena, &.{ job.root, manifest_mod.subdir, job.id });
            try job.builder(io, gpa, arena, app_dir, prefix, &job.env, why);
            // Where it came from, for a rebuild: a folder on this
            // machine is the one source a rebuild can build again.
            if (std.fs.path.isAbsolute(job.url)) {
                const note = try std.fs.path.join(arena, &.{ prefix, built_from_file });
                Io.Dir.cwd().writeFile(io, .{ .sub_path = note, .data = app_dir }) catch |err| keepCancel(io, err);
            }
            // The binary: the one file under <prefix>/bin.
            const bin_dir = try std.fs.path.join(arena, &.{ prefix, "bin" });
            var dir = Io.Dir.cwd().openDir(io, bin_dir, .{ .iterate = true }) catch |err| {
                keepCancel(io, err);
                why.* = "zig build produced no bin/";
                return error.Failed;
            };
            defer dir.close(io);
            var it = dir.iterate();
            var binary: ?[]const u8 = null;
            while (it.next(io) catch |err| n: {
                keepCancel(io, err);
                break :n null;
            }) |entry| {
                if (entry.kind != .file) continue;
                binary = try std.fs.path.join(arena, &.{ bin_dir, entry.name });
                break;
            }
            const exe = binary orelse {
                why.* = "zig build produced no binary";
                return error.Failed;
            };
            _ = linkBinary(io, arena, job.root, exe) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // The binary is still there to `--install`.
                error.LinkFailed => "",
            };
            try run(io, gpa, arena, &.{ exe, "--install" }, null, &job.env, "--install", why);
            if (job.rebuild) return rebuiltStamp(io, arena, job, warn);
            return try std.fmt.allocPrint(arena, "built {s}", .{exe});
        },
    }
}

/// What a rebuild says: the SDK the manifest `--install` just wrote is
/// stamped with — read back, not assumed. A build still behind this
/// mnml's SDK (the folder's build.zig.zon pins an older mnml-sdk) says
/// so, and `warn` is set.
fn rebuiltStamp(io: Io, arena: Allocator, job: *InstallJob, warn: *bool) Allocator.Error![]const u8 {
    const path = manifest_mod.manifest.pathUnder(arena, job.root, job.id) catch return "rebuilt";
    const text = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch {
        warn.* = true;
        return std.fmt.allocPrint(arena, "rebuilt, but --install wrote no manifest at {s}", .{path});
    };
    var why: []const u8 = "";
    const m = manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadManifest => {
            warn.* = true;
            return std.fmt.allocPrint(arena, "rebuilt, but the manifest --install wrote does not parse: {s}", .{why});
        },
    };
    if (!m.staleAgainst(sdk_version)) return std.fmt.allocPrint(arena, "rebuilt against SDK {s}", .{m.sdk});
    warn.* = true;
    const on = if (m.sdk.len == 0) "no SDK stamp" else try std.fmt.allocPrint(arena, "SDK {s}", .{m.sdk});
    return std.fmt.allocPrint(arena, "rebuilt, but still on {s} \u{2014} the mnml-sdk its build.zig.zon depends on is older than {s}; update that and rebuild", .{ on, sdk_version });
}

pub const LinkError = error{ OutOfMemory, LinkFailed };

/// For a best-effort step that cannot return `error.Canceled` (it
/// catches every error): re-arm a cancel it swallowed. The runtime
/// reports a cancel once; dropped, the install's next child ran to the
/// end with the canceller waiting on it.
fn keepCancel(io: Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

/// `<root>/bin/<name>` → `target`, the one indirection that keeps a
/// manifest's bare `binary` name honest: `integrations.resolveBinary`
/// prefers this link over PATH, so relinking it (here, by `run.sh
/// install`, or by `integrations.update`) moves every installed
/// manifest at once and none of them hardcodes a path. A symlink where
/// there are symlinks, a copy where there are not (Windows without the
/// privilege). Returns the link's path.
pub fn linkBinary(io: Io, arena: Allocator, root: []const u8, target: []const u8) LinkError![]const u8 {
    const link_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    Io.Dir.cwd().createDirPath(io, link_dir) catch |err| keepCancel(io, err);
    const link = try std.fs.path.join(arena, &.{ link_dir, std.fs.path.basename(target) });
    // The link is replaced, not written through: deleting it first is
    // what stops a copy overwriting the binary a symlink points at.
    Io.Dir.cwd().deleteFile(io, link) catch |err| keepCancel(io, err);
    Io.Dir.cwd().symLink(io, target, link, .{}) catch |serr| {
        keepCancel(io, serr);
        Io.Dir.cwd().copyFile(target, Io.Dir.cwd(), link, io, .{}) catch |err| {
            keepCancel(io, err);
            return error.LinkFailed;
        };
    };
    return link;
}

/// How long a cancelled install's child gets between SIGTERM and SIGKILL.
/// Quitting mid-install waits this long at most for a child that
/// ignores the SIGTERM — `zig build`, git and a `--install` all act on it.
const cancel_grace: Io.Duration = .fromMilliseconds(500);

/// On POSIX the child leads its own process group, so a cancel stops
/// what it started too — `zig build`'s compiler, a script's `sleep`.
const own_group = builtin.os.tag != .windows;

/// Run a child to completion; a non-zero exit is `Failed` with its stderr tail in `why`.
/// A cancel stops the child and its group and returns `Canceled`: the
/// group's `cancel` (quit) returns at once instead of waiting out the
/// child.
fn run(io: Io, gpa: Allocator, arena: Allocator, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, what: []const u8, why: *[]const u8) InstallError!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .pgid = if (own_group) 0 else null,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = try std.fmt.allocPrint(arena, "{s}: cannot run {s}: {s}", .{ what, argv[0], @errorName(err) });
            return error.Failed;
        },
    };
    // Every early return — a cancel mid-read, out of memory — stops the
    // child and its group; after a finished `wait` this does nothing.
    defer child_os.terminate(io, &child, .{ .group = own_group, .grace = cancel_grace });
    var err_buf: [4096]u8 = undefined;
    var err_reader = child.stderr.?.reader(io, &err_buf);
    var tail: Io.Writer.Allocating = .init(gpa);
    defer tail.deinit();
    // The read is where a cancel lands while the child runs: the
    // runtime reports it once, so it goes up, never into a `catch {}`
    // — swallowed, the `wait` below could not be interrupted and the
    // canceller waited for the child to exit on its own. Any other read
    // failure only costs the tail; the `wait` says how the child ended.
    _ = err_reader.interface.streamRemaining(&tail.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => if (err_reader.err) |e| if (e == error.Canceled) return error.Canceled,
    };
    // A cancelled `wait` clears `child.id` without stopping anything
    // (`core/child.zig`), so the pid is taken first.
    const pid = child.id;
    const term = child.wait(io) catch |err| {
        child_os.reapAbandonedGroup(pid, own_group);
        switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                why.* = try std.fmt.allocPrint(arena, "{s}: wait failed", .{what});
                return error.Failed;
            },
        }
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
            if (i.rebuilt)
                try app.toastLevel(if (i.warn) .warn else .info, "{s}: {s}", .{ i.id, i.detail })
            else
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
    return app.marketplace.fetching or app.marketplace.installing != null or app.marketplace.rebuilds.items.len > 0;
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
const sdk_testing = @import("mnml_sdk").testing;
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
        \\.{{ .entries = .{{ .{{ .id = "sample", .label = "Sample", .description = "The counter", .category = "sample", .version = "0.1.0", .binary = "{f}" }} }} }}
    , .{std.zig.fmtString(exe)});
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
    try sdk_testing.expectPath("apps/mnml-jira", st.entries[1].subpath);
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

// ─── add a source: tests ────────────────────────────────────────────────

const Key = app_mod.Key;

/// A hand-written home config: a comment, a sibling section, and one
/// source already there, with a comment of its own.
const add_source_before =
    \\// my mnml config — hand-written, keep my comments
    \\.{
    \\    .ui = .{ .theme = "onedark" }, // the look
    \\    .marketplace = .{
    \\        .use_defaults = false,
    \\        // the one I had
    \\        .sources = .{
    \\            .{ .local_folder = .{ .id = "other", .path = "other" } }, // keep me
    \\        },
    \\    },
    \\}
    \\
;

/// Where `addSource` inserts into `add_source_before` and anything
/// grown from it: before the sources list's closing line.
const add_source_tail = "        },\n    },\n}\n";

const AddSourceRig = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    ws: []const u8,
    env: std.process.Environ.Map,
    app: App,

    /// `ws/` with `acme/` (two integration folders and a loose manifest),
    /// `tools/acme/` (one manifest), `empty/`, `other/` and `local/`; the
    /// data root holds `add_source_before` as its config.zon. The API
    /// points at a port nothing listens on, so a repo source's fetch
    /// fails at once, offline.
    fn init(self: *AddSourceRig) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try gpa.dupe(u8, pbuf[0..try self.tmp.dir.realPath(io, &pbuf)]);
        errdefer gpa.free(self.root);
        self.ws = try std.fs.path.join(gpa, &.{ self.root, "ws" });
        errdefer gpa.free(self.ws);
        const d = self.tmp.dir;
        for ([_][]const u8{ "ws/acme/one", "ws/acme/two", "ws/tools/acme", "ws/empty/deep", "ws/other", "ws/local", "data" }) |p| try d.createDirPath(io, p);
        try d.writeFile(io, .{ .sub_path = "ws/acme/one/build.zig", .data = "" });
        try d.writeFile(io, .{ .sub_path = "ws/acme/one/manifest.zon", .data = ".{ .id = \"one\", .label = \"One\", .version = \"0.1.0\", .binary = \"mnml-one\" }" });
        try d.writeFile(io, .{ .sub_path = "ws/acme/two/build.zig", .data = "" });
        try d.writeFile(io, .{ .sub_path = "ws/acme/two/manifest.zon", .data = ".{ .id = \"two\", .label = \"Two\", .version = \"0.1.0\", .binary = \"mnml-two\" }" });
        try d.writeFile(io, .{ .sub_path = "ws/acme/hello.zon", .data = hello_zon });
        try d.writeFile(io, .{ .sub_path = "ws/tools/acme/hello.zon", .data = hello_zon });
        try d.writeFile(io, .{ .sub_path = "ws/local/hello.zon", .data = hello_zon });
        // Not a manifest, not an integration folder: still empty.
        try d.writeFile(io, .{ .sub_path = "ws/empty/deep/notes.txt", .data = "hi" });
        try d.writeFile(io, .{ .sub_path = "data/config.zon", .data = add_source_before });
        const data = try std.fs.path.join(gpa, &.{ self.root, "data" });
        defer gpa.free(data);
        self.env = std.process.Environ.Map.init(gpa);
        errdefer self.env.deinit();
        try self.env.put("MNML_MARKETPLACE_API", "http://127.0.0.1:1");
        var cfg: Config = .{};
        cfg.marketplace.use_defaults = false;
        cfg.marketplace.sources = &add_source_existing;
        self.app = try App.initWith(gpa, io, .{ .cfg = cfg, .workspace = self.ws, .data_root = data, .cols = 100, .rows = 24, .env = &self.env });
    }

    fn deinit(self: *AddSourceRig) void {
        self.app.deinit();
        self.env.deinit();
        testing.allocator.free(self.ws);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn config(self: *AddSourceRig) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "data/config.zon", testing.allocator, .unlimited);
    }
};

const add_source_existing = [_]Config.MarketplaceSource{.{ .local_folder = .{ .id = "other", .path = "other" } }};

test "addSource: a folder with two integrations and a manifest — 3 found, the id from its name, config.zon gains exactly the entry; a second add appends with a unique id" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;

    const added = try addSource(app, "acme");
    try testing.expectEqualStrings("acme", added.id);
    try testing.expectEqual(@as(?usize, 3), added.found);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "added acme: 3 integrations found") != null);
    const acme_abs = try std.fs.path.join(gpa, &.{ rig.ws, "acme" });
    defer gpa.free(acme_abs);
    // The expected bytes come from the writer's own serializer: a
    // Windows path's backslashes are escaped in the file, and the test
    // must expect the escaped spelling, not the raw one.
    // The serializer writes through an allocating writer, as the real
    // caller's arena expects: give it one here too.
    var lit_arena = std.heap.ArenaAllocator.init(gpa);
    defer lit_arena.deinit();
    const lit1 = try config.persist.serializeLiteral(lit_arena.allocator(), config.Config.MarketplaceSource{ .local_folder = .{ .id = "acme", .path = acme_abs } });
    const line1 = try std.fmt.allocPrint(gpa, "            {s},\n", .{lit1});
    defer gpa.free(line1);
    // Byte for byte: everything before the list's closing line, the one
    // new line, everything after — comments and the sibling untouched.
    const at = std.mem.indexOf(u8, add_source_before, add_source_tail).?;
    const want1 = try std.mem.concat(gpa, u8, &.{ add_source_before[0..at], line1, add_source_before[at..] });
    defer gpa.free(want1);
    const got1 = try rig.config();
    defer gpa.free(got1);
    try testing.expectEqualStrings(want1, got1);
    // In memory too, and listed: the tab is the Marketplace, its rows
    // the folder's three, each Private.
    try testing.expectEqual(@as(usize, 2), app.cfg.marketplace.sources.len);
    try testing.expectEqualStrings("acme", app.cfg.marketplace.sources[1].local_folder.id);
    try testing.expect(app.integrations.tab == .marketplace);
    try settle(app);
    try testing.expectEqual(@as(usize, 3), app.marketplace.entries.len);
    for (app.marketplace.entries) |e| {
        try testing.expectEqualStrings("acme", e.source);
        try testing.expect(e.private);
    }

    // A second folder named `acme`: appended after the first, `acme-2`.
    const again = try addSource(app, "tools/acme");
    try testing.expectEqualStrings("acme-2", again.id);
    try testing.expectEqual(@as(?usize, 1), again.found);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "added acme-2: 1 integration found") != null);
    const tools_abs = try std.fs.path.join(gpa, &.{ rig.ws, "tools", "acme" });
    defer gpa.free(tools_abs);
    const lit2 = try config.persist.serializeLiteral(lit_arena.allocator(), config.Config.MarketplaceSource{ .local_folder = .{ .id = "acme-2", .path = tools_abs } });
    const line2 = try std.fmt.allocPrint(gpa, "            {s},\n", .{lit2});
    defer gpa.free(line2);
    const want2 = try std.mem.concat(gpa, u8, &.{ add_source_before[0..at], line1, line2, add_source_before[at..] });
    defer gpa.free(want2);
    const got2 = try rig.config();
    defer gpa.free(got2);
    try testing.expectEqualStrings(want2, got2);
    try settle(app);
    try testing.expectEqual(@as(usize, 4), app.marketplace.entries.len);

    // A folder named like one of mnml's own sources never takes its id.
    try testing.expectEqualStrings("local-2", (try addSource(app, "./local")).id);
    // The same folder twice is refused by name, nothing written.
    try testing.expectError(error.Failed, addSource(app, "acme"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "already the source acme") != null);
    try settle(app);
}

test "addSource refuses an empty folder and a missing one, writing nothing" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    try testing.expectError(error.Failed, addSource(app, "empty"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "nothing to install in") != null);
    app.diag.clear();
    try testing.expectError(error.Failed, addSource(app, "./nope"));
    // The message names the resolved folder: `./nope` under the workspace.
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, std.fs.path.sep_str ++ "nope is not a folder") != null);
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "./nope") == null);
    app.diag.clear();
    try testing.expectError(error.Failed, addSource(app, "   "));
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expectEqualStrings(add_source_before, got);
    try testing.expectEqual(@as(usize, 1), app.cfg.marketplace.sources.len);
}

test "addSource: owner/repo[:apps_dir] is a GitHub monorepo source — shape only, nothing fetched to count; a folder that is there wins over the shape" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    const arena = app.frame.allocator();
    // The shapes.
    const r = (try parseSourceInput(app, arena, "acme-co/tools:integrations")).repo;
    try testing.expectEqualStrings("acme-co/tools", r.repo);
    try testing.expectEqualStrings("integrations", r.apps_dir);
    try testing.expectEqualStrings("apps", repoShape("acme-co/tools").?.dir);
    try testing.expect(repoShape("a/b/c") == null);
    try testing.expect(repoShape("a/b:../x") == null);
    try testing.expect(repoShape("nope") == null);
    try testing.expect(repoShape(".x/y") == null);
    // `tools/acme` has a slash but is a folder here: the folder wins.
    try testing.expect(try parseSourceInput(app, arena, "tools/acme") == .folder);
    try testing.expect(try parseSourceInput(app, arena, "./acme-co/tools") == .folder);

    const added = try addSource(app, "acme-co/tools");
    try testing.expectEqualStrings("tools", added.id);
    try testing.expectEqual(@as(?usize, null), added.found);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "added tools: acme-co/tools (apps/)") != null);
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, ".github_monorepo_apps = .{ .id = \"tools\", .repo = \"acme-co/tools\", .apps_dir = \"apps\"") != null);
    try testing.expect(std.mem.startsWith(u8, got, add_source_before[0..std.mem.indexOf(u8, add_source_before, add_source_tail).?]));
    try testing.expect(app.cfg.marketplace.sources[1] == .github_monorepo_apps);
    // The fetch goes to a port nothing listens on: it fails, offline.
    try settle(app);
}

test "marketplace.add_source resolves, opens the shared prompt, and its Enter adds the folder" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    try testing.expect(command.resolve(app, "marketplace.add_source") != null);
    try command.runNamed(app, "marketplace.add_source");
    try testing.expect(app.overlay == .prompt);
    try testing.expect(app.overlay.prompt.purpose.marketplace_add_source == .palette);
    try app.render();
    const text = try screen_mod.toTestText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, add_source_title) != null);
    try testing.expect(std.mem.indexOf(u8, text, add_source_placeholder) != null);
    for ("acme") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(app.overlay == .none);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "added acme: 3 integrations found") != null);
    try testing.expect(app.integrations.tab == .marketplace);
    try settle(app);
    // Esc cancels: nothing more is written.
    try command.runNamed(app, "marketplace.add_source");
    for ("tools/acme") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.overlay == .none);
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "acme-2") == null);
    try testing.expectEqual(@as(usize, 2), app.cfg.marketplace.sources.len);
}

test "the Marketplace tab's + source chip and its menus fire marketplace.add_source: a click opens the prompt; right-click on the chip or a tab is the tab strip's menu, whose row opens it too" {
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    try command.run(app, .{ .static = .@"integrations.show_marketplace" });
    try settle(app);
    try app.render();
    // The chip, found where the paint registered it, never painted by hand.
    const chip_rect = for (app.hits.items.items) |e| {
        if (e.target == .chip and e.target.chip.panel == .integrations and e.target.chip.kind == .new) break e.rect;
    } else return error.TestExpectedChip;
    try app.handle(.{ .mouse = .{ .x = chip_rect.x + 1, .y = chip_rect.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = chip_rect.x + 1, .y = chip_rect.y, .kind = .release, .button = .left } });
    try testing.expect(app.overlay == .prompt);
    try testing.expect(app.overlay.prompt.purpose.marketplace_add_source == .palette);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.overlay == .none);
    try app.render();
    try app.handle(.{ .mouse = .{ .x = chip_rect.x + 1, .y = chip_rect.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Integrations", app.overlay.menu.title);
    try testing.expect(app.overlay.menu.items[3].action.command == .@"marketplace.add_source");
    try app.handle(.{ .key = Key.named(.esc) });
    try app.render();
    const tab_rect = for (app.hits.items.items) |e| {
        if (e.target == .button and e.target.button == @import("../ui/integrations_view.zig").tab_base + 1) break e.rect;
    } else return error.TestExpectedTab;
    try app.handle(.{ .mouse = .{ .x = tab_rect.x + 1, .y = tab_rect.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Integrations", app.overlay.menu.title);
    try testing.expect(app.overlay.menu.items[3].action.command == .@"marketplace.add_source");
    // Picking the row is the same prompt.
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(app.overlay == .prompt);
    try testing.expect(app.overlay.prompt.purpose.marketplace_add_source == .palette);
}

/// The fake build a test swaps in for `zig build`: it leaves a
/// `built.txt` in the folder it was asked to build (so the test can
/// read back WHICH folder was built) and puts the prebuilt sample in
/// `<prefix>/bin/`, so the link and `--install` run for real.
fn fakeBuild(io: Io, gpa: Allocator, arena: Allocator, app_dir: []const u8, prefix: []const u8, env: *const std.process.Environ.Map, why: *[]const u8) InstallError!void {
    _ = gpa;
    _ = env;
    const note = try std.fs.path.join(arena, &.{ app_dir, "built.txt" });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = note, .data = prefix }) catch {
        why.* = "fake build: cannot write built.txt";
        return error.Failed;
    };
    const bin = try std.fs.path.join(arena, &.{ prefix, "bin" });
    Io.Dir.cwd().createDirPath(io, bin) catch {};
    const exe = build_options.sample_integration_exe;
    const dst = try std.fs.path.join(arena, &.{ bin, std.fs.path.basename(exe) });
    Io.Dir.cwd().copyFile(exe, Io.Dir.cwd(), dst, io, .{}) catch {
        why.* = "fake build: cannot copy the sample";
        return error.Failed;
    };
}

// ─── an install's child against a refresh and a quit ────────────────────

/// The `--install` of the slow fixture: it starts a `sleep 30` in the
/// background, writes both pids (each file renamed into place, so a pid
/// file that exists is whole), and waits — an install that is still
/// running when the test acts, with a child of its own.
const slow_install_script =
    \\#!/bin/sh
    \\sleep 30 &
    \\echo $! > "$SLOW_PIDDIR/gc.part" && mv "$SLOW_PIDDIR/gc.part" "$SLOW_PIDDIR/grandchild.pid"
    \\echo $$ > "$SLOW_PIDDIR/c.part" && mv "$SLOW_PIDDIR/c.part" "$SLOW_PIDDIR/child.pid"
    \\wait
    \\
;

/// A builder that "builds" the slow fixture: the script, executable, as
/// the one file under `<prefix>/bin`.
fn slowBuild(io: Io, gpa: Allocator, arena: Allocator, app_dir: []const u8, prefix: []const u8, env: *const std.process.Environ.Map, why: *[]const u8) InstallError!void {
    _ = gpa;
    _ = app_dir;
    _ = env;
    const bin = try std.fs.path.join(arena, &.{ prefix, "bin" });
    Io.Dir.cwd().createDirPath(io, bin) catch {
        why.* = "slow build: cannot make bin/";
        return error.Failed;
    };
    const exe = try std.fs.path.join(arena, &.{ bin, "mnml-slow" });
    const perms: Io.File.Permissions = .fromMode(0o755);
    const file = Io.Dir.cwd().createFile(io, exe, .{ .truncate = true, .permissions = perms }) catch {
        why.* = "slow build: cannot write the script";
        return error.Failed;
    };
    defer file.close(io);
    file.writeStreamingAll(io, slow_install_script) catch {
        why.* = "slow build: cannot write the script";
        return error.Failed;
    };
}

test "addSource: a folder that IS an integration (build.zig + manifest.zon) lists as that one app and Install builds it in place — its manifest is never a launcher" {
    const gpa = testing.allocator;
    const io = testing.io;
    const exe = build_options.sample_integration_exe;
    Io.Dir.cwd().access(io, exe, .{}) catch return error.SkipZigTest;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    const d = rig.tmp.dir;
    try d.createDirPath(io, "ws/slowsrc/slow");
    try d.writeFile(io, .{ .sub_path = "ws/slowsrc/slow/build.zig", .data = "" });
    try d.writeFile(io, .{ .sub_path = "ws/slowsrc/slow/build.zig.zon", .data = ".{ .name = .slow, .version = \"0.1.0\" }" });
    try d.writeFile(io, .{ .sub_path = "ws/slowsrc/slow/manifest.zon", .data = ".{ .id = \"slow\", .label = \"Slow\", .version = \"0.1.0\", .binary = \"mnml-slow\" }" });

    const added = try addSource(app, "slowsrc/slow");
    try testing.expectEqualStrings("slow", added.id);
    try testing.expectEqual(@as(?usize, 1), added.found);
    try settle(app);
    const slow_abs = try std.fs.path.join(gpa, &.{ rig.ws, "slowsrc", "slow" });
    defer gpa.free(slow_abs);
    try testing.expectEqual(@as(usize, 1), app.marketplace.entries.len);
    const e = app.marketplace.entries[0];
    try testing.expectEqual(Kind.app, e.kind);
    try testing.expectEqualStrings("slow", e.id);
    try testing.expectEqualStrings(slow_abs, e.url);

    // Install builds the folder itself, exactly as a subfolder of a
    // source folder would be built.
    app.marketplace.builder = fakeBuild;
    try install(app, 0);
    try settle(app);
    const built = try std.fs.path.join(gpa, &.{ slow_abs, "built.txt" });
    defer gpa.free(built);
    try Io.Dir.cwd().access(io, built, .{});
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "installed slow") != null);
}

test "addSource with the Marketplace disabled refuses before writing: config.zon and the sources in memory are untouched, and the message says nothing was added" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    app.cfg.marketplace.enabled = false;
    try testing.expectError(error.Failed, addSource(app, "acme"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "disabled") != null);
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "nothing added") != null);
    try testing.expectError(error.Failed, addSource(app, "someone/tools"));
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expectEqualStrings(add_source_before, got);
    try testing.expectEqual(@as(usize, 1), app.cfg.marketplace.sources.len);
}

test "addSource: owner/repo is compared case-insensitively, as GitHub does — Someone/Tools after someone/tools is already the source, and an id never differs from another by case alone" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    try testing.expectEqualStrings("tools", (try addSource(app, "someone/tools")).id);
    for ([_][]const u8{ "Someone/Tools", "SOMEONE/TOOLS" }) |again| {
        app.diag.clear();
        try testing.expectError(error.Failed, addSource(app, again));
        try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "already the source tools") != null);
    }
    // Another repo whose name is `tools` in other letters: its own id,
    // not one that reads the same as `tools`.
    try testing.expectEqualStrings("Tools-2", (try addSource(app, "other/Tools")).id);
    try testing.expectEqual(@as(usize, 3), app.cfg.marketplace.sources.len);
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "someone/tools"));
    try testing.expect(std.mem.indexOf(u8, got, "Someone/Tools") == null);
    try settle(app);
}

test "addSource: the same folder by another spelling — a symlink to it, or its name in other letters on a case-insensitive volume — is already the source, nothing written" {
    const gpa = testing.allocator;
    const io = testing.io;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    try testing.expectEqualStrings("acme", (try addSource(app, "acme")).id);
    const before = try rig.config();
    defer gpa.free(before);
    var refused: usize = 0;
    const acme_abs = try std.fs.path.join(gpa, &.{ rig.ws, "acme" });
    defer gpa.free(acme_abs);
    // A symlink, where the platform lets a test make one.
    if (rig.tmp.dir.symLink(io, acme_abs, "ws/link", .{ .is_directory = true })) |_| {
        app.diag.clear();
        try testing.expectError(error.Failed, addSource(app, "link"));
        try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "already the source acme") != null);
        refused += 1;
    } else |_| {}
    // Letter case, where the volume folds it (macOS and Windows by
    // default): `ACME` is then the same folder.
    const upper = try std.fs.path.join(gpa, &.{ rig.ws, "ACME" });
    defer gpa.free(upper);
    if (isDir(io, upper)) {
        for ([_][]const u8{ "ACME", "Acme" }) |spelling| {
            app.diag.clear();
            try testing.expectError(error.Failed, addSource(app, spelling));
            try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "already the source acme") != null);
            refused += 1;
        }
    }
    // A POSIX CI box without either still ran the check above.
    try testing.expect(refused > 0 or @import("builtin").os.tag == .windows);
    const after = try rig.config();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(usize, 2), app.cfg.marketplace.sources.len);
    try settle(app);
}

test "addSource: a pasted GitHub repo URL is that repo — scheme or not, .git, a trailing slash, /tree/<branch>/<dir>; any other URL is refused by name, never read as a folder" {
    const gpa = testing.allocator;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    const arena = app.frame.allocator();
    const Want = struct { in: []const u8, repo: []const u8, dir: []const u8 };
    for ([_]Want{
        .{ .in = "https://github.com/someone/tools", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "http://github.com/someone/tools.git/", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "github.com/someone/tools", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "HTTPS://www.GitHub.com/someone/tools/", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "https://github.com/someone/tools?tab=readme#top", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "https://github.com/someone/tools/tree/main", .repo = "someone/tools", .dir = "apps" },
        .{ .in = "https://github.com/someone/tools/tree/main/integrations", .repo = "someone/tools", .dir = "integrations" },
        .{ .in = "https://github.com/someone/tools/tree/main/pkgs/zig/", .repo = "someone/tools", .dir = "pkgs/zig" },
        .{ .in = "git@github.com:someone/tools.git", .repo = "someone/tools", .dir = "apps" },
    }) |w| {
        const got = try parseSourceInput(app, arena, w.in);
        if (got != .repo) {
            std.debug.print("{s}: read as {s}, not a repo\n", .{ w.in, @tagName(got) });
            return error.TestExpectedRepo;
        }
        try testing.expectEqualStrings(w.repo, got.repo.repo);
        try testing.expectEqualStrings(w.dir, got.repo.apps_dir);
    }
    for ([_][]const u8{ "https://gitlab.com/someone/tools", "ftp://example.com/x", "file:///Users/me/x", "https://github.com/someone", "https://github.com/someone/tools/blob/main/x.zon", "https://github.com/some one/tools" }) |in| {
        const got = try parseSourceInput(app, arena, in);
        try testing.expect(got == .refused);
    }

    const added = try addSource(app, "https://github.com/someone/tools");
    try testing.expectEqualStrings("tools", added.id);
    const got = try rig.config();
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, ".repo = \"someone/tools\", .apps_dir = \"apps\"") != null);
    app.diag.clear();
    try testing.expectError(error.Failed, addSource(app, "github.com/someone/tools/"));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "already the source tools") != null);
    // Refused by what it is, with the forms that work — never a path
    // under the workspace the user did not type.
    app.diag.clear();
    try testing.expectError(error.Failed, addSource(app, "https://gitlab.com/someone/tools"));
    const msg = app.diag.msg.?;
    try testing.expect(std.mem.indexOf(u8, msg, "not a folder") == null);
    try testing.expect(std.mem.indexOf(u8, msg, rig.ws) == null);
    try testing.expect(std.mem.indexOf(u8, msg, "https://gitlab.com/someone/tools") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "owner/repo") != null);
    try testing.expectEqual(@as(usize, 2), app.cfg.marketplace.sources.len);
    try settle(app);
}

test "idFrom reads like the name: accented Latin letters fold to their base letter, one - per run of anything else, and a name with nothing ASCII left is `private`" {
    var mem = std.heap.ArenaAllocator.init(testing.allocator);
    defer mem.deinit();
    const a = mem.allocator();
    try testing.expectEqualStrings("integrations", try idFrom(a, "intégrations"));
    // The same word as macOS may hand it over: e + a combining accent.
    try testing.expectEqualStrings("integrations", try idFrom(a, "inte\u{301}grations"));
    try testing.expectEqualStrings("uni-code", try idFrom(a, "ünï cødé"));
    try testing.expectEqualStrings("Strasse-Lodz", try idFrom(a, "Straße Łódź"));
    try testing.expectEqualStrings("my-tools", try idFrom(a, "my  tools"));
    try testing.expectEqualStrings("tools-v2", try idFrom(a, "tools → v2"));
    try testing.expectEqualStrings("acme_co.x", try idFrom(a, "acme_co.x"));
    try testing.expectEqualStrings("private", try idFrom(a, "日本語"));
    try testing.expectEqualStrings("private", try idFrom(a, ""));
}

test "addSource: a folder named with non-ASCII letters gets an id that reads like it" {
    const io = testing.io;
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    const d = rig.tmp.dir;
    try d.createDirPath(io, "ws/intégrations/one");
    try d.writeFile(io, .{ .sub_path = "ws/intégrations/one/build.zig", .data = "" });
    try d.writeFile(io, .{ .sub_path = "ws/intégrations/one/manifest.zon", .data = ".{ .id = \"one\", .label = \"One\", .version = \"0.1.0\", .binary = \"mnml-one\" }" });
    try testing.expectEqualStrings("integrations", (try addSource(app, "intégrations")).id);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "added integrations: 1 integration found") != null);
    try settle(app);
}

test "addSource: a folder's rows are listed the moment it is added, beside the rows already there — not when every source's fetch lands" {
    var rig: AddSourceRig = undefined;
    try rig.init();
    defer rig.deinit();
    const app = &rig.app;
    _ = try addSource(app, "tools/acme");
    try settle(app);
    try testing.expectEqual(@as(usize, 1), app.marketplace.entries.len);
    // No tick in between: nothing the worker posts has been handled.
    const added = try addSource(app, "acme");
    try testing.expectEqualStrings("acme-2", added.id);
    try testing.expect(app.marketplace.fetching);
    try testing.expectEqual(@as(usize, 4), app.marketplace.entries.len);
    var mine: usize = 0;
    for (app.marketplace.entries) |e| {
        if (std.mem.eql(u8, e.source, "acme-2")) {
            try testing.expect(e.private);
            mine += 1;
        } else try testing.expectEqualStrings("acme", e.source);
    }
    try testing.expectEqual(@as(usize, 3), mine);
    // The tab shows them now.
    try app.render();
    const text = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Mkt (4)") != null);
    // The fetch's own listing replaces it with the same rows.
    try settle(app);
    try testing.expectEqual(@as(usize, 4), app.marketplace.entries.len);
}

const SlowPids = struct { child: std.posix.pid_t, grandchild: std.posix.pid_t };

fn readPid(io: Io, arena: Allocator, path: []const u8) ?std.posix.pid_t {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return null;
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \r\n"), 10) catch null;
}

/// An app on a scratch workspace whose only source is a local folder
/// holding the `slow` app integration, with `slowBuild` as its builder
/// and the workspace as its data root.
fn slowApp(gpa: Allocator, io: Io) !App {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/bin:/usr/bin");
    var app = try App.initWith(gpa, io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 24, .env = &env });
    errdefer app.deinit();
    gpa.free(app.data_root);
    app.data_root = try gpa.dupe(u8, app.workspace);
    var ws = try Io.Dir.cwd().openDir(io, app.workspace, .{});
    defer ws.close(io);
    try ws.createDirPath(io, "src/slow");
    try ws.createDirPath(io, "pids");
    try ws.writeFile(io, .{ .sub_path = "src/slow/build.zig", .data = "" });
    try ws.writeFile(io, .{ .sub_path = "src/slow/manifest.zon", .data = ".{ .id = \"slow\", .label = \"Slow\", .description = \"An install that takes a while\", .version = \"0.1.0\", .binary = \"mnml-slow\" }" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try app.env.put("MNML_MARKETPLACE_LOCAL", try std.fmt.bufPrint(&buf, "{s}/src", .{app.workspace}));
    try app.env.put("SLOW_PIDDIR", try std.fmt.bufPrint(&buf, "{s}/pids", .{app.workspace}));
    app.marketplace.builder = slowBuild;
    return app;
}

/// List the fixture, install `slow`, and tick until its `--install` is
/// running: the pids of the script and of its `sleep`.
fn startSlowInstall(app: *App, arena: Allocator) !SlowPids {
    const io = app.io;
    try refresh(app);
    var waited: u32 = 0;
    while (app.marketplace.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const idx = find(app, "slow") orelse return error.TestExpectedSlowRow;
    try install(app, idx);
    const child_path = try std.fs.path.join(arena, &.{ app.workspace, "pids", "child.pid" });
    const gc_path = try std.fs.path.join(arena, &.{ app.workspace, "pids", "grandchild.pid" });
    waited = 0;
    while (waited < 20_000) : (waited += 10) {
        if (readPid(io, arena, child_path)) |c| {
            const g = readPid(io, arena, gc_path) orelse return error.TestExpectedGrandchild;
            return .{ .child = c, .grandchild = g };
        }
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.TestInstallNeverStarted;
}

fn msSince(io: Io, start: Io.Timestamp) i64 {
    return @intCast(@divTrunc(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms));
}

test "a refresh while an install's child runs returns at once, the listing lands, and the install keeps running" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var mem = std.heap.ArenaAllocator.init(gpa);
    defer mem.deinit();
    var app = try slowApp(gpa, io);
    var app_live = true;
    defer if (app_live) app.deinit();
    const pids = try startSlowInstall(&app, mem.allocator());
    const st = &app.marketplace;
    try testing.expect(st.installing != null);

    // The refresh: it used to cancel the group the install shares and
    // block the UI thread until the install's child exited — 30 s here.
    const t0 = Io.Timestamp.now(io, .awake);
    try refresh(&app);
    const refresh_ms = msSince(io, t0);
    try testing.expect(refresh_ms < 1000);

    // The loop keeps ticking: the new listing lands while the install's
    // child is still running, untouched.
    var waited: u32 = 0;
    while (st.fetching and waited < 5_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(!st.fetching);
    try testing.expect(find(&app, "slow") != null);
    try testing.expect(st.installing != null);
    try testing.expect(!child_os.gone(pids.child));
    try testing.expect(!child_os.gone(pids.grandchild));

    // Quit with it still running: prompt, and nothing is left behind.
    app_live = false;
    const t1 = Io.Timestamp.now(io, .awake);
    app.deinit();
    try testing.expect(msSince(io, t1) < 1500);
    try testing.expect(child_os.goneWithin(io, pids.child, .fromSeconds(2)));
    try testing.expect(child_os.goneWithin(io, pids.grandchild, .fromSeconds(2)));
}

test "quitting mid-install stops the install's child and what it started, and returns promptly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var mem = std.heap.ArenaAllocator.init(gpa);
    defer mem.deinit();
    var app = try slowApp(gpa, io);
    var app_live = true;
    defer if (app_live) app.deinit();
    const pids = try startSlowInstall(&app, mem.allocator());
    try testing.expect(!child_os.gone(pids.child));

    // `App.deinit` is what quit runs: it cancels the install's group,
    // which used to wait out the child's 30 s.
    app_live = false;
    const t0 = Io.Timestamp.now(io, .awake);
    app.deinit();
    try testing.expect(msSince(io, t0) < 1500);
    // Reaped, not orphaned: the script and its `sleep` are both gone.
    try testing.expect(child_os.gone(pids.child));
    try testing.expect(child_os.goneWithin(io, pids.grandchild, .fromSeconds(2)));
}
