//! `Pane.marketplace` — what can be installed, from the sources in
//! `cfg.marketplace.sources` (plus mnml's defaults when `use_defaults`).
//! A fetch runs on a worker in the state's `Io.Group` and lands as one
//! `.marketplace` event; an install runs the same way and refreshes the
//! installed list when it is done.
//!
//! Two source shapes do work in this build:
//!
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
//!
//! `crates_keyword` is kept in the config so a 0.2 file still loads,
//! but integrations are no longer crates: it is reported and lists
//! nothing.
//!
//! `MNML_MARKETPLACE_API` replaces `https://api.github.com` (the tests
//! point it at a local server).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const config = @import("../config/root.zig");
const Config = config.Config;
const http_client = @import("../http/client.zig");
const http_parse = @import("../http/parse.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const integrations = @import("integrations.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/marketplace_view.zig");

pub const default_api = "https://api.github.com";
pub const max_body = 4 * 1024 * 1024;

pub const Kind = enum { launcher, app };

/// One row of the listing. Borrows the result's arena.
pub const Entry = struct {
    source: []const u8,
    kind: Kind,
    id: []const u8,
    label: []const u8,
    description: []const u8,
    version: []const u8 = "",
    /// launcher: the manifest's download URL. app: the repo slug.
    url: []const u8,
    /// app: the directory under the repo.
    subpath: []const u8 = "",
};

/// A source as the worker sees it (gpa-owned copy of the config).
pub const SourceSpec = struct {
    id: []u8,
    kind: enum { launcher_folder, monorepo_apps, crates },
    repo: []u8,
    path: []u8,

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
    fetched_at_ms: ?i64 = null,
    /// The row a context menu was opened on.
    menu_row: ?usize = null,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.arena) |*a| a.deinit();
        if (self.installing) |i| gpa.free(i);
    }
};

pub const MarketplacePane = struct {
    cursor: usize = 0,
    scroll: usize = 0,
    detail: bool = false,
};

pub const table = .{
    .@"integrations.show_marketplace" = &show,
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

/// The sources to list: the defaults first when `use_defaults`, then the config's.
pub fn sources(app: *App, gpa: Allocator) Allocator.Error![]SourceSpec {
    var out: std.ArrayListUnmanaged(SourceSpec) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(gpa);
        out.deinit(gpa);
    }
    if (app.cfg.marketplace.use_defaults) for (Config.default_marketplace_sources) |s| try out.append(gpa, try specOf(gpa, s));
    for (app.cfg.marketplace.sources) |s| try out.append(gpa, try specOf(gpa, s));
    return out.toOwnedSlice(gpa);
}

fn specOf(gpa: Allocator, s: Config.MarketplaceSource) Allocator.Error!SourceSpec {
    return switch (s) {
        .crates_keyword => |c| .{ .id = try gpa.dupe(u8, c.id), .kind = .crates, .repo = try gpa.dupe(u8, ""), .path = try gpa.dupe(u8, c.keyword) },
        .github_launcher_folder => |g| .{ .id = try gpa.dupe(u8, g.id), .kind = .launcher_folder, .repo = try gpa.dupe(u8, g.repo), .path = try gpa.dupe(u8, g.path) },
        .github_monorepo_apps => |g| .{ .id = try gpa.dupe(u8, g.id), .kind = .monorepo_apps, .repo = try gpa.dupe(u8, g.repo), .path = try gpa.dupe(u8, g.apps_dir) },
    };
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
    const api = try gpa.dupe(u8, apiBase(app));
    errdefer gpa.free(api);
    st.group.concurrent(app.io, fetchWorker, .{ &app.events, app.io, gpa, specs, api, st.generation }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "marketplace: cannot start the fetch: {s}", .{@errorName(err)});
    };
    st.fetching = true;
    app.needs_render = true;
}

fn refreshCmd(app: *App) CommandError!void {
    try refresh(app);
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
    post(events, io, gpa, .{ .generation = generation, .kind = .{ .listing = .{
        .arena = arena_state,
        .entries = entries.items,
        .problems = problems.items,
    } } });
}

fn listSource(io: Io, gpa: Allocator, arena: Allocator, api: []const u8, s: SourceSpec, entries: *std.ArrayListUnmanaged(Entry), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    switch (s.kind) {
        .crates => {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: crates.io sources are not searched — integrations are Zig packages now", .{s.id}));
            return;
        },
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
                try entries.append(arena, .{ .source = s.id, .kind = .launcher, .id = m.id, .label = m.label, .description = m.description, .version = m.version, .url = dl });
            },
            .monorepo_apps => {
                if (!std.mem.eql(u8, gh.type, "dir")) continue;
                try entries.append(arena, .{
                    .source = s.id,
                    .kind = .app,
                    .id = gh.name,
                    .label = gh.name,
                    .description = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ s.repo, s.path, gh.name }),
                    .url = s.repo,
                    .subpath = try std.fs.path.join(arena, &.{ s.path, gh.name }),
                });
            },
            .crates => unreachable,
        }
    }
}

// ─── install ────────────────────────────────────────────────────────────

/// Install the entry at `idx` on a worker: a launcher's manifest is
/// fetched and written; an app is cloned and built.
pub fn install(app: *App, idx: usize) CommandError!void {
    const st = &app.marketplace;
    if (idx >= st.entries.len) return;
    if (st.installing != null) return app.diag.fail(app.frame.allocator(), "marketplace: an install is already running", .{});
    if (app.data_root.len == 0) return app.diag.fail(app.frame.allocator(), "marketplace: no data root to install into", .{});
    const e = st.entries[idx];
    const gpa = app.gpa;
    const job = try gpa.create(InstallJob);
    errdefer gpa.destroy(job);
    job.* = .{ .kind = e.kind, .id = &.{}, .root = &.{}, .url = &.{}, .subpath = &.{}, .env = undefined };
    job.id = try gpa.dupe(u8, e.id);
    errdefer gpa.free(job.id);
    job.root = try gpa.dupe(u8, app.data_root);
    errdefer gpa.free(job.root);
    job.url = try gpa.dupe(u8, e.url);
    errdefer gpa.free(job.url);
    job.subpath = try gpa.dupe(u8, e.subpath);
    errdefer gpa.free(job.subpath);
    job.env = try app.env.clone(gpa);
    errdefer job.env.deinit();
    try job.env.put("MNML_DATA_ROOT", app.data_root);
    st.group.concurrent(app.io, installWorker, .{ &app.events, app.io, gpa, job, st.generation }) catch |err| {
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
    env: std.process.Environ.Map,

    fn destroy(self: *InstallJob, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.root);
        gpa.free(self.url);
        gpa.free(self.subpath);
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
        .launcher => {
            const text = switch (try fetch(gpa, io, arena, job.url)) {
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
            // Clone (or reuse) the repo under <root>/marketplace/<owner>-<repo>.
            const slug = try arena.dupe(u8, job.url);
            for (slug) |*c| if (c.* == '/') {
                c.* = '-';
            };
            if (!safeName(slug)) {
                why.* = "the repo slug is not a path component";
                return error.Failed;
            }
            const clone_dir = try std.fs.path.join(arena, &.{ job.root, "marketplace", slug });
            const exists = blk: {
                Io.Dir.cwd().access(io, clone_dir, .{}) catch break :blk false;
                break :blk true;
            };
            if (!exists) {
                Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(clone_dir).?) catch {};
                const git_url = try std.fmt.allocPrint(arena, "https://github.com/{s}.git", .{job.url});
                try run(io, gpa, arena, &.{ "git", "clone", "--depth", "1", git_url, clone_dir }, null, &job.env, "git clone", why);
            } else {
                run(io, gpa, arena, &.{ "git", "-C", clone_dir, "pull", "--ff-only" }, null, &job.env, "git pull", why) catch {};
            }
            const app_dir = try std.fs.path.join(arena, &.{ clone_dir, job.subpath });
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
            // Reachable by its bare name: <root>/bin is on `runMount`'s path.
            const link_dir = try std.fs.path.join(arena, &.{ job.root, "bin" });
            Io.Dir.cwd().createDirPath(io, link_dir) catch {};
            const link = try std.fs.path.join(arena, &.{ link_dir, std.fs.path.basename(exe) });
            Io.Dir.cwd().deleteFile(io, link) catch {};
            Io.Dir.cwd().symLink(io, exe, link, .{}) catch {};
            try run(io, gpa, arena, &.{ exe, "--install" }, null, &job.env, "--install", why);
            return try std.fmt.allocPrint(arena, "built {s}", .{exe});
        },
    }
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
        },
        .installed => |i| {
            defer r.destroy(gpa);
            if (st.installing) |cur| gpa.free(cur);
            st.installing = null;
            try integrations.refresh(app);
            app.toast("marketplace: installed {s} — {s}", .{ i.id, i.detail });
        },
        .failed => |msg| {
            defer r.destroy(gpa);
            st.fetching = false;
            if (st.installing) |cur| gpa.free(cur);
            st.installing = null;
            try app.toastLevel(.err, "{s}", .{msg});
        },
    }
    app.needs_render = true;
}

/// A frame is due while a worker runs (the spinner).
pub fn busy(app: *const App) bool {
    return app.marketplace.fetching or app.marketplace.installing != null;
}

// ─── the pane ───────────────────────────────────────────────────────────

fn show(app: *App) CommandError!void {
    if (app.panes.findKind(.marketplace)) |id| {
        app.showPane(id);
    } else {
        const id = try app.panes.add(.{ .marketplace = .{} });
        app.showPane(id);
    }
    if (app.marketplace.fetched_at_ms == null and !app.marketplace.fetching) refresh(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

fn activePane(app: *App) ?struct { id: PaneId, p: *MarketplacePane } {
    const id = app.active orelse return null;
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .marketplace => |*p| .{ .id = id, .p = p },
        else => null,
    };
}

fn focusedRow(app: *App) CommandError!usize {
    const st = &app.marketplace;
    if (st.menu_row) |r| {
        st.menu_row = null;
        if (r < st.entries.len) return r;
    }
    const ap = activePane(app) orelse return app.diag.fail(app.frame.allocator(), "marketplace: open it first (integrations.show_marketplace)", .{});
    if (ap.p.cursor >= st.entries.len) return app.diag.fail(app.frame.allocator(), "marketplace: nothing to act on", .{});
    return ap.p.cursor;
}

fn installFocused(app: *App) CommandError!void {
    return install(app, try focusedRow(app));
}

fn detailFocused(app: *App) CommandError!void {
    const i = try focusedRow(app);
    const ap = activePane(app) orelse return;
    ap.p.cursor = i;
    ap.p.detail = !ap.p.detail;
}

fn copyIdFocused(app: *App) CommandError!void {
    const i = try focusedRow(app);
    try app.clipboard.set(app.marketplace.entries[i].id, false);
    app.toast("copied {s}", .{app.marketplace.entries[i].id});
}

pub fn handleKey(app: *App, id: PaneId, p: *MarketplacePane, k: Key) Allocator.Error!bool {
    const n = app.marketplace.entries.len;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, n -| 1),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = n -| 1,
        .enter => runToast(app, installFocused(app)),
        .esc => try app.forceClosePane(id),
        .char => |c| switch (c) {
            'j' => p.cursor = @min(p.cursor + 1, n -| 1),
            'k' => p.cursor -|= 1,
            'g' => p.cursor = 0,
            'G' => p.cursor = n -| 1,
            'q' => try app.forceClosePane(id),
            'i' => runToast(app, installFocused(app)),
            'd' => p.detail = !p.detail,
            'y' => runToast(app, copyIdFocused(app)),
            'r' => runToast(app, refreshCmd(app)),
            'I', 'M' => runToast(app, command.run(app, .{ .static = .@"integrations.show_installed" })),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| switch (err) {
        error.Canceled => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("marketplace: {s}", .{@errorName(err)}),
    };
}

pub fn click(app: *App, p: *MarketplacePane, hit: u32, m: Mouse) Allocator.Error!void {
    const st = &app.marketplace;
    if (hit >= st.entries.len) return;
    if (m.button == .right) return openRowMenu(app, hit, m.x, m.y);
    if (p.cursor == hit) runToast(app, install(app, hit)) else p.cursor = hit;
}

pub fn scrollBy(app: *App, p: *MarketplacePane, delta: i64) void {
    const n = app.marketplace.entries.len;
    const cur: i64 = @intCast(p.cursor);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(n -| 1))));
}

fn openRowMenu(app: *App, row: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.marketplace;
    if (row >= st.entries.len) return;
    st.menu_row = row;
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Install", .action = .{ .command = .@"marketplace.install_focused" } },
        .{ .label = "Details", .action = .{ .command = .@"marketplace.open_detail_focused" } },
        .{ .label = "Copy id", .action = .{ .command = .@"marketplace.copy_id_focused" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu(st.entries[row].label, items, x, y);
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *MarketplacePane, rect: Rect) Allocator.Error!void {
    const is_focused = app.active == id and app.focus == .pane;
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const st = &app.marketplace;
    const rows = try ui.arena.alloc(view.Row, st.entries.len);
    for (st.entries, 0..) |e, i| rows[i] = .{
        .kind = @tagName(e.kind),
        .id = e.id,
        .label = e.label,
        .description = e.description,
        .version = e.version,
        .source = e.source,
        .installed = app.integrations.find(e.id) != null,
        .installing = if (st.installing) |cur| std.mem.eql(u8, cur, e.id) else false,
        .selected = i == p.cursor,
        .detail = i == p.cursor and p.detail,
    };
    view.draw(ui, id, rect, .{ .rows = rows, .scroll = &p.scroll, .focused = is_focused, .fetching = st.fetching, .problems = st.problems, .enabled = app.cfg.marketplace.enabled });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A tiny HTTP server that answers by path from a table.
const FakeGitHub = struct {
    pub const Route = struct { path: []const u8, body: []const u8, status: u16 = 200 };
    gpa: Allocator,
    io: Io,
    port: u16,
    server: Io.net.Server,
    routes: []const Route,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(gpa: Allocator, io: Io, routes: []const Route) !*FakeGitHub {
        const self = try gpa.create(FakeGitHub);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .port = server.socket.address.getPort(), .server = server, .routes = routes };
        self.thread = try std.Thread.spawn(.{}, loop, .{ self, io });
        return self;
    }

    fn stop(self: *FakeGitHub) void {
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
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(gpa, &app.screen);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "MARKETPLACE") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "mnml-jira") != null);

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
