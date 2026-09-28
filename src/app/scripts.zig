//! Installed scripts — the directory form of a plugin, and the store
//! the SCRIPTS section's three tabs read (`docs/research/
//! lua-platform-design-2026-09-13.md` §3, Decisions 2 and 3).
//!
//! A script is a directory:
//!
//!     <data root>/scripts/<name>/
//!       script.zon     the manifest (`scripting/manifest.zig`)
//!       init.lua       the entry
//!       lib/*.lua      what a scoped `require` may reach
//!       README.md
//!
//! The user's `<data root>/init.lua` and the workspace's
//! `.mnml/init.lua` are unchanged: one file, no `require`, one shared
//! state (`Lua.id == 0`).
//!
//! **Isolation.** Every installed script gets its OWN Lua state — its
//! own 20 ms budget clock, its own decoration namespaces, its own
//! registrations (tagged with the state's id, so `unregisterScript`
//! takes exactly one script's commands), its own `require` root. A
//! script that errors is one toast and a disabled row; nothing else in
//! the app notices.
//!
//! **Where it came from** is a field on the row and a filter in the
//! panel, exactly as the INTEGRATIONS section does it:
//!
//!   installed     `<data root>/scripts/` — whatever has been installed
//!   marketplace   the curated set that ships with mnml — this repo's
//!                 own `lua/`, packaged as `share/mnml/lua` beside the
//!                 binary (`shippedRoot`) — or a folder the user names
//!                 instead; `official` badge
//!   dev           `scripts.dev_roots` — edited live, saved = reloaded
//!
//! and `script.install <git URL | archive | directory>` adds a
//! `community` one, `scripts.private_sources` a `private` one.
//!
//! **Enabled** is a `.disabled` marker file in the script's own
//! directory: no config write, and it survives a restart.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const script_list = @import("script_list.zig");
const alloc_mod = @import("../core/alloc.zig");
const CommandError = command.CommandError;
const lua_mod = @import("../scripting/lua.zig");
const Lua = lua_mod.Lua;
const manifest_mod = @import("../scripting/manifest.zig");
const Manifest = manifest_mod.Manifest;
const Source = manifest_mod.Source;
const build_options = @import("build_options");
const data_root_mod = @import("../config/data_root.zig");
const trust = @import("../config/trust.zig");

/// The marker file that means "installed, but off".
pub const disabled_marker = ".disabled";
/// How big a script's own files may be, in total, before an install is
/// refused — a plugin is text, not a payload.
pub const max_install_bytes: usize = 8 * 1024 * 1024;
pub const max_install_files: usize = 512;

/// One installed (or dev, or private) script. Every slice is gpa-owned.
pub const Entry = struct {
    /// The Lua state id this script's refs carry (1..).
    id: u16,
    name: []u8,
    version: []u8,
    description: []u8,
    author: []u8,
    url: []u8,
    commands: [][]u8,
    hooks: [][]u8,
    source: Source,
    api: u32,
    /// The directory, absolute.
    dir: []u8,
    enabled: bool,
    /// Its own state while loaded; null when disabled, unsupported, or
    /// the last load failed.
    state: ?*Lua = null,
    /// Why it is not running, when it is not.
    err: ?[]u8 = null,
    /// Whether `task.run` appears anywhere in its Lua — the trust
    /// dialog's third claim (it is the only door out of the sandbox).
    runs_tasks: bool = false,
    /// The newest mtime under `dir` when it was last loaded — the Dev
    /// tab's save-reload compares against it.
    stamp: i128 = 0,

    pub fn supported(e: Entry) bool {
        return e.api >= 1 and e.api <= manifest_mod.api_version;
    }

    /// Its entry chunk.
    pub fn entryPath(e: Entry, arena: Allocator) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ e.dir, manifest_mod.entry_file });
    }

    fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.name);
        gpa.free(e.version);
        gpa.free(e.description);
        gpa.free(e.author);
        gpa.free(e.url);
        for (e.commands) |c| gpa.free(c);
        gpa.free(e.commands);
        for (e.hooks) |h| gpa.free(h);
        gpa.free(e.hooks);
        gpa.free(e.dir);
        if (e.err) |m| gpa.free(m);
    }
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The next state id. Never reused: a ref another state still holds
    /// can then never land in a fresh script's registry.
    next_id: u16 = 1,
    scanned: bool = false,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        for (self.entries.items) |*e| {
            if (e.state) |l| l.destroy();
            e.deinit(gpa);
        }
        self.entries.deinit(gpa);
    }

    /// The Lua state with this id, when it is loaded.
    pub fn state(self: *Store, id: u16) ?*Lua {
        for (self.entries.items) |*e| if (e.id == id) return e.state;
        return null;
    }

    pub fn find(self: *Store, name: []const u8) ?*Entry {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// The name of the script that owns `id`, "" when nothing does.
    pub fn nameOf(self: *const Store, id: u16) []const u8 {
        for (self.entries.items) |e| if (e.id == id) return e.name;
        return "";
    }
};

// ─── paths ───────────────────────────────────────────────────────────────

/// Where installed scripts live: `MNML_SCRIPTS_ROOT` when it is set,
/// else `<data root>/scripts`. On `arena`; null when neither is there.
/// The environment wins so a run can keep its installs to itself — the
/// corpus shares one data root across every file, and a script
/// installed by one would otherwise load in all the rest.
pub fn installRoot(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (app.env.get("MNML_SCRIPTS_ROOT")) |v| if (v.len > 0) return try resolveRoot(app, arena, v);
    if (app.data_root.len == 0) return null;
    return try std.fs.path.join(arena, &.{ app.data_root, manifest_mod.subdir });
}

/// A configured folder as an absolute path: `~` expanded, a relative
/// one resolved against the workspace. On `arena`.
pub fn resolveRoot(app: *App, arena: Allocator, spec: []const u8) Allocator.Error![]const u8 {
    if (spec.len == 0) return "";
    const expanded = try app.expandTilde(spec);
    if (std.fs.path.isAbsolute(expanded)) return expanded;
    return std.fs.path.join(arena, &.{ app.workspace, expanded });
}

/// The Dev tab's roots: `MNML_SCRIPTS_DEV_ROOTS` (one or more folders,
/// `:`-separated, `;` on Windows) when it is set, else
/// `scripts.dev_roots`. The environment wins so the corpus — which
/// cannot write the config the App has already read — can point the tab
/// at a folder, the way `MNML_MARKETPLACE_LOCAL` does for integrations.
pub fn devRoots(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (app.env.get("MNML_SCRIPTS_DEV_ROOTS")) |v| if (v.len > 0) {
        const sep: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
        var it = std.mem.splitScalar(u8, v, sep);
        while (it.next()) |part| {
            if (part.len == 0) continue;
            try out.append(arena, try resolveRoot(app, arena, part));
        }
        return out.toOwnedSlice(arena);
    };
    for (app.cfg.scripts.dev_roots) |spec| {
        const root = try resolveRoot(app, arena, spec);
        if (root.len > 0) try out.append(arena, root);
    }
    return out.toOwnedSlice(arena);
}

/// The folder holding the curated set that SHIPS with mnml — this
/// repo's `lua/`, the way `integrations/` and `launchers/` ship their
/// own — tried in order:
///
///   1. `build_dir` — `build_options.scripts_dir`, the checkout's own
///      `lua/` baked in at build time, so a dev build lists the set
///      with no config and no install step;
///   2. `<exe dir>/../share/mnml/lua` — the system layout the `.deb`
///      and the `.rpm` lay down (`/usr/bin/mnml` + `/usr/share/…`);
///   3. `<exe dir>/share/mnml/lua` — the archive layout: the `.tar.xz`
///      and the Windows `.zip` unpack `share/` beside the binary;
///   4. `<exe dir>/mnml-data/lua` — the portable directory.
///
/// Null when none of the four is there (a bare binary copied out of its
/// package). `build_dir` and `exe_dir` are values so the test can hand
/// in a sandbox rather than depend on where it happens to be running.
pub fn shippedRoot(io: Io, arena: Allocator, build_dir: []const u8, exe_dir: ?[]const u8) Allocator.Error!?[]const u8 {
    if (build_dir.len > 0 and isDir(io, build_dir)) return build_dir;
    const dir = exe_dir orelse return null;
    const candidates = [_][]const []const u8{
        &.{ dir, "..", "share", "mnml", "lua" },
        &.{ dir, "share", "mnml", "lua" },
        &.{ dir, data_root_mod.portable_dir, "lua" },
    };
    for (candidates) |parts| {
        const path = std.fs.path.resolve(arena, parts) catch continue;
        if (isDir(io, path)) return path;
    }
    return null;
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// The folder the Marketplace tab lists. The two overrides first —
/// `MNML_SCRIPTS_MARKETPLACE`, then `scripts.marketplace_local` — and
/// otherwise the set that ships with mnml (`shippedRoot`), so a fresh
/// data root with no config at all still has a populated tab. Empty
/// only when nothing is configured AND no shipped folder is beside the
/// binary.
pub fn marketplaceRoot(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    if (app.env.get("MNML_SCRIPTS_MARKETPLACE")) |v| if (v.len > 0) return try resolveRoot(app, arena, v);
    if (app.cfg.scripts.marketplace_local.len > 0) return try resolveRoot(app, arena, app.cfg.scripts.marketplace_local);
    const exe_dir = std.process.executableDirPathAlloc(app.io, arena) catch null;
    return (try shippedRoot(app.io, arena, build_options.scripts_dir, exe_dir)) orelse "";
}

// ─── scanning ────────────────────────────────────────────────────────────

/// Read `<dir>/script.zon`. Null (with `why` set) when it is missing or
/// will not parse.
fn readManifest(app: *App, arena: Allocator, dir: []const u8, why: *[]const u8) ?Manifest {
    const path = std.fs.path.join(arena, &.{ dir, manifest_mod.file_name }) catch return null;
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(64 * 1024), .of(u8), 0) catch {
        why.* = "no script.zon";
        return null;
    };
    return manifest_mod.parse(arena, text, why) catch null;
}

fn warnUnknownFields(app: *App, arena: Allocator, dir: []const u8) Allocator.Error!void {
    const path = try std.fs.path.join(arena, &.{ dir, manifest_mod.file_name });
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(64 * 1024), .of(u8), 0) catch return;
    for (try manifest_mod.unknownFields(arena, text)) |f| {
        try app.toastLevel(.warn, "scripts: {s}: unknown field `.{s}` in {s} (ignored)", .{ std.fs.path.basename(dir), f, manifest_mod.file_name });
    }
}

fn dupeList(gpa: Allocator, src: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (src) |s| {
        out[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn fileExists(app: *App, path: []const u8) bool {
    return if (Io.Dir.cwd().statFile(app.io, path, .{})) |_| true else |_| false;
}

/// Whether `task.run` appears in any `.lua` under `dir` — the claim the
/// trust dialog makes about a script shelling out. A grep, deliberately:
/// the manifest cannot be trusted to admit it.
pub fn greps(app: *App, arena: Allocator, dir: []const u8, needle: []const u8) bool {
    var d = Io.Dir.cwd().openDir(app.io, dir, .{ .iterate = true }) catch return false;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        const sub = std.fs.path.join(arena, &.{ dir, ent.name }) catch return false;
        switch (ent.kind) {
            .directory => if (greps(app, arena, sub, needle)) return true,
            .file => {
                if (!std.mem.endsWith(u8, ent.name, ".lua")) continue;
                const text = Io.Dir.cwd().readFileAlloc(app.io, sub, arena, .limited(1 << 20)) catch continue;
                if (std.mem.indexOf(u8, text, needle) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

/// The newest mtime under `dir` — what the Dev tab's save-reload
/// compares. 0 when the folder cannot be read.
pub fn stampOf(app: *App, arena: Allocator, dir: []const u8) i128 {
    var newest: i128 = 0;
    var d = Io.Dir.cwd().openDir(app.io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        const sub = std.fs.path.join(arena, &.{ dir, ent.name }) catch continue;
        switch (ent.kind) {
            .directory => newest = @max(newest, stampOf(app, arena, sub)),
            .file => {
                const st = Io.Dir.cwd().statFile(app.io, sub, .{}) catch continue;
                newest = @max(newest, st.mtime.nanoseconds);
            },
            else => {},
        }
    }
    return newest;
}

/// Add (or refresh) the entry for the script directory `dir`. Returns
/// the entry, or null with a toast when the manifest will not read.
fn adopt(app: *App, dir: []const u8, source: Source) Allocator.Error!?*Entry {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    var why: []const u8 = "";
    const m = readManifest(app, arena, dir, &why) orelse {
        if (why.len > 0 and !std.mem.eql(u8, why, "no script.zon")) app.toast("scripts: {s}: {s}", .{ std.fs.path.basename(dir), why });
        return null;
    };
    // A name already known keeps its state id: a re-scan is not a reload.
    if (app.scripts.find(m.name)) |existing| return existing;
    // It loads, but a field `script.zon` has no place for was dropped —
    // `.commmands` would list a script that says it adds nothing. Named
    // once, when the script is first adopted.
    try warnUnknownFields(app, arena, dir);
    const disabled = fileExists(app, try std.fs.path.join(arena, &.{ dir, disabled_marker }));
    var e: Entry = .{
        .id = app.scripts.next_id,
        .name = try gpa.dupe(u8, m.name),
        .version = try gpa.dupe(u8, m.version),
        .description = try gpa.dupe(u8, m.description),
        .author = try gpa.dupe(u8, m.author),
        .url = try gpa.dupe(u8, m.url),
        .commands = try dupeList(gpa, m.commands),
        .hooks = try dupeList(gpa, m.hooks),
        // The folder it was found in wins over what the manifest claims:
        // a community script cannot badge itself `official`.
        .source = source,
        .api = m.api,
        .dir = try gpa.dupe(u8, dir),
        .enabled = !disabled,
        .runs_tasks = greps(app, arena, dir, "task.run"),
    };
    if (!e.supported()) e.err = try std.fmt.allocPrint(gpa, "written for mnml script api {d}; this build implements {d}", .{ e.api, manifest_mod.api_version });
    app.scripts.next_id += 1;
    try app.scripts.entries.append(gpa, e);
    return &app.scripts.entries.items[app.scripts.entries.items.len - 1];
}

/// Every script directory under `root` adopted with `source`.
fn scanRoot(app: *App, root: []const u8, source: Source) Allocator.Error!void {
    var d = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch return;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        const sub = try std.fs.path.join(app.frame.allocator(), &.{ root, ent.name });
        _ = try adopt(app, sub, source);
    }
}

/// The installed set, the private sources and the dev roots, then every
/// enabled, supported one loaded. Idempotent: a second call adds what
/// is new and leaves what is running alone.
pub fn scan(app: *App) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (try installRoot(app, arena)) |root| try scanRoot(app, root, .community);
    for (app.cfg.scripts.private_sources) |spec| {
        const root = try resolveRoot(app, arena, spec);
        if (root.len > 0) try scanRoot(app, root, .private);
    }
    for (try devRoots(app, arena)) |root| try scanRoot(app, root, .dev);
    app.scripts.scanned = true;
    var i: usize = 0;
    while (i < app.scripts.entries.items.len) : (i += 1) {
        const e = &app.scripts.entries.items[i];
        if (e.state != null or !e.enabled or !e.supported()) continue;
        try load(app, e);
    }
}

// ─── loading ─────────────────────────────────────────────────────────────

/// Give `e` its own Lua state and run its `init.lua`. A failure is one
/// toast, the row's `err`, and no state — never another script's
/// problem.
pub fn load(app: *App, e: *Entry) Allocator.Error!void {
    if (e.state != null) return;
    if (!e.supported()) return;
    const arena = app.frame.allocator();
    const l = try Lua.createFor(app.gpa, app.io, app, e.id, e.name, e.dir);
    e.state = l;
    if (e.err) |m| {
        app.gpa.free(m);
        e.err = null;
    }
    const entry = try e.entryPath(arena);
    const ok = l.loadInit(entry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => blk: {
            e.err = try app.gpa.dupe(u8, l.last_error orelse "script error");
            break :blk false;
        },
    };
    if (!ok and e.err == null) e.err = try std.fmt.allocPrint(app.gpa, "no {s}", .{manifest_mod.entry_file});
    if (e.err != null) {
        try unload(app, e);
        return;
    }
    e.stamp = stampOf(app, arena, e.dir);
    app.needs_render = true;
}

/// Everything `e` registered goes and its state is destroyed.
pub fn unload(app: *App, e: *Entry) Allocator.Error!void {
    const l = e.state orelse return;
    l.app = app;
    try l.reset();
    // `reset` reopened the state; nothing is registered under it now,
    // so destroying it frees the registry and the arrays.
    l.destroy();
    e.state = null;
    app.needs_render = true;
}

/// One script off and on again.
pub fn reloadOne(app: *App, e: *Entry) Allocator.Error!void {
    try unload(app, e);
    if (e.enabled) try load(app, e);
}

/// Every installed script off and on again — `script.reload` does this
/// after the `init.lua` files.
pub fn reloadAll(app: *App) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.scripts.entries.items.len) : (i += 1) try reloadOne(app, &app.scripts.entries.items[i]);
}

/// The Dev tab's save-reload: a script under a dev root whose files are
/// newer than when it loaded is reloaded. Returns how many were.
pub fn reloadChangedDev(app: *App) Allocator.Error!usize {
    const arena = app.frame.allocator();
    var n: usize = 0;
    var i: usize = 0;
    while (i < app.scripts.entries.items.len) : (i += 1) {
        const e = &app.scripts.entries.items[i];
        if (e.source != .dev or !e.enabled) continue;
        const now = stampOf(app, arena, e.dir);
        if (now <= e.stamp) continue;
        e.stamp = now;
        try reloadOne(app, e);
        n += 1;
    }
    return n;
}

/// `save_post`: a file saved under a dev root reloads that script.
pub fn onSavePost(app: *App, args: @import("../core/hooks.zig").HookArgs) void {
    const e = app.panes.editor(args.save_post.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    var hit = false;
    for (app.scripts.entries.items) |entry| {
        if (entry.source != .dev) continue;
        if (std.mem.startsWith(u8, path, entry.dir)) hit = true;
    }
    if (!hit) return;
    const n = reloadChangedDev(app) catch return;
    if (n > 0) app.toast("scripts: reloaded {d} dev script{s}", .{ n, if (n == 1) "" else "s" });
}

// ─── enable / disable / remove ───────────────────────────────────────────

pub fn setEnabled(app: *App, e: *Entry, on: bool) Allocator.Error!void {
    const arena = app.frame.allocator();
    const marker = try std.fs.path.join(arena, &.{ e.dir, disabled_marker });
    if (on) {
        Io.Dir.cwd().deleteFile(app.io, marker) catch {};
    } else {
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = marker, .data = "disabled by mnml\n" }) catch {};
    }
    e.enabled = on;
    if (on) try load(app, e) else try unload(app, e);
}

/// Delete the directory and forget the entry.
pub fn removeEntry(app: *App, name: []const u8) Allocator.Error!bool {
    const e = app.scripts.find(name) orelse return false;
    try unload(app, e);
    Io.Dir.cwd().deleteTree(app.io, e.dir) catch {};
    var idx: usize = 0;
    while (idx < app.scripts.entries.items.len) : (idx += 1) {
        if (app.scripts.entries.items[idx].id == e.id) break;
    }
    var gone = app.scripts.entries.orderedRemove(idx);
    gone.deinit(app.gpa);
    app.needs_render = true;
    return true;
}

// ─── installing ──────────────────────────────────────────────────────────

pub const SourceKind = enum { directory, archive, git };

/// What `script.install <src>` is looking at.
pub fn classify(src: []const u8) SourceKind {
    if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://") or
        std.mem.startsWith(u8, src, "git@") or std.mem.startsWith(u8, src, "git://") or
        std.mem.endsWith(u8, src, ".git")) return .git;
    for ([_][]const u8{ ".tar.gz", ".tgz", ".tar", ".zip" }) |ext| {
        if (std.mem.endsWith(u8, src, ext)) return .archive;
    }
    return .directory;
}

pub const InstallError = Allocator.Error || error{Failed};

/// Run `argv` and wait. True on exit 0.
fn runArgv(app: *App, argv: []const []const u8, cwd: []const u8) bool {
    var child = std.process.spawn(app.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &app.env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(app.io) catch return false;
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Copy every file under `from` into `to`, refusing a tree that is too
/// big or has too many files (a script is text, not a payload).
fn copyTree(app: *App, arena: Allocator, from: []const u8, to: []const u8, budget: *usize, files: *usize) error{ Failed, OutOfMemory }!void {
    Io.Dir.cwd().createDirPath(app.io, to) catch return error.Failed;
    var d = Io.Dir.cwd().openDir(app.io, from, .{ .iterate = true }) catch return error.Failed;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        // `.git` and the disable marker never travel.
        if (std.mem.eql(u8, ent.name, ".git") or std.mem.eql(u8, ent.name, disabled_marker)) continue;
        const src = try std.fs.path.join(arena, &.{ from, ent.name });
        const dst = try std.fs.path.join(arena, &.{ to, ent.name });
        switch (ent.kind) {
            .directory => try copyTree(app, arena, src, dst, budget, files),
            .file => {
                files.* += 1;
                if (files.* > max_install_files) return error.Failed;
                const text = Io.Dir.cwd().readFileAlloc(app.io, src, arena, .limited(max_install_bytes)) catch return error.Failed;
                if (text.len > budget.*) return error.Failed;
                budget.* -= text.len;
                Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dst, .data = text }) catch return error.Failed;
            },
            else => {},
        }
    }
}

/// The directory inside a staging area that actually holds a
/// `script.zon`: the staging root itself, or its single subdirectory (a
/// git repo or an archive whose script sits one level down).
fn scriptDirIn(app: *App, arena: Allocator, staged: []const u8) ?[]const u8 {
    if (fileExists(app, std.fs.path.join(arena, &.{ staged, manifest_mod.file_name }) catch return null)) return staged;
    var d = Io.Dir.cwd().openDir(app.io, staged, .{ .iterate = true }) catch return null;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        const sub = std.fs.path.join(arena, &.{ staged, ent.name }) catch continue;
        if (fileExists(app, std.fs.path.join(arena, &.{ sub, manifest_mod.file_name }) catch continue)) return sub;
    }
    return null;
}

pub const Staged = struct {
    /// Where the copy sits until the user accepts it.
    dir: []const u8,
    manifest: Manifest,
    runs_tasks: bool,
};

/// Fetch `src` into a staging folder under the install root and read
/// its manifest. Nothing is installed and nothing runs yet: the caller
/// puts the claims on screen first (`promptTrust`).
pub fn stage(app: *App, arena: Allocator, src: []const u8, source: Source) InstallError!Staged {
    const root = (try installRoot(app, arena)) orelse {
        app.toast("scripts: no data root — nowhere to install", .{});
        return error.Failed;
    };
    Io.Dir.cwd().createDirPath(app.io, root) catch {};
    const staging = try std.fs.path.join(arena, &.{ root, ".staging" });
    Io.Dir.cwd().deleteTree(app.io, staging) catch {};
    Io.Dir.cwd().createDirPath(app.io, staging) catch {
        app.toast("scripts: cannot write {s}", .{staging});
        return error.Failed;
    };
    switch (classify(src)) {
        .git => if (!runArgv(app, &.{ "git", "clone", "--depth", "1", "--quiet", src, staging }, root)) {
            app.toast("scripts: git clone failed: {s}", .{src});
            return error.Failed;
        },
        .archive => {
            const abs = try resolveRoot(app, arena, src);
            const ok = if (std.mem.endsWith(u8, src, ".zip"))
                runArgv(app, &.{ "unzip", "-q", abs, "-d", staging }, root)
            else
                runArgv(app, &.{ "tar", "-xf", abs, "-C", staging }, root);
            if (!ok) {
                app.toast("scripts: cannot unpack {s}", .{src});
                return error.Failed;
            }
        },
        .directory => {
            const abs = try resolveRoot(app, arena, src);
            var budget: usize = max_install_bytes;
            var files: usize = 0;
            copyTree(app, arena, abs, staging, &budget, &files) catch {
                app.toast("scripts: cannot copy {s} (missing, too large, or too many files)", .{src});
                return error.Failed;
            };
        },
    }
    const found = scriptDirIn(app, arena, staging) orelse {
        app.toast("scripts: no {s} in {s}", .{ manifest_mod.file_name, src });
        return error.Failed;
    };
    var why: []const u8 = "";
    const m = readManifest(app, arena, found, &why) orelse {
        app.toast("scripts: {s}", .{if (why.len > 0) why else "bad manifest"});
        return error.Failed;
    };
    if (!fileExists(app, try std.fs.path.join(arena, &.{ found, manifest_mod.entry_file }))) {
        app.toast("scripts: {s} has no {s}", .{ m.name, manifest_mod.entry_file });
        return error.Failed;
    }
    _ = source;
    return .{ .dir = found, .manifest = m, .runs_tasks = greps(app, arena, found, "task.run") };
}

/// Move the staged copy to `<install root>/<name>` and adopt it. The
/// trust dialog has already been answered yes.
pub fn commit(app: *App, staged_dir: []const u8, name: []const u8, source: Source, url: []const u8) InstallError!void {
    const arena = app.frame.allocator();
    const root = (try installRoot(app, arena)) orelse return error.Failed;
    const dest = try std.fs.path.join(arena, &.{ root, name });
    if (app.scripts.find(name)) |old| _ = try removeEntry(app, old.name);
    Io.Dir.cwd().deleteTree(app.io, dest) catch {};
    var budget: usize = max_install_bytes;
    var files: usize = 0;
    copyTree(app, arena, staged_dir, dest, &budget, &files) catch {
        app.toast("scripts: cannot write {s}", .{dest});
        return error.Failed;
    };
    Io.Dir.cwd().deleteTree(app.io, try std.fs.path.join(arena, &.{ root, ".staging" })) catch {};
    // The manifest records where it came from, so `script.update` can
    // go back to the same place and the row's badge is honest.
    try stampSource(app, arena, dest, source, url);
    const e = (try adopt(app, dest, source)) orelse return error.Failed;
    try load(app, e);
    // The Marketplace tab's rows carry "installed" — re-read them.
    @import("scripts_panel.zig").refreshMarket(app) catch {};
    app.toast("scripts: installed {s}{s}", .{ name, if (e.err != null) " (it errored — see the SCRIPTS row)" else "" });
}

/// Rewrite the installed manifest's `.source` / `.url` so a re-scan and
/// an update agree with how it actually got here.
fn stampSource(app: *App, arena: Allocator, dir: []const u8, source: Source, url: []const u8) Allocator.Error!void {
    const path = try std.fs.path.join(arena, &.{ dir, manifest_mod.file_name });
    var why: []const u8 = "";
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(64 * 1024), .of(u8), 0) catch return;
    var m = manifest_mod.parse(arena, text, &why) catch return;
    m.source = source;
    m.url = url;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    manifest_mod.render(&w.writer, m) catch return;
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = w.written() }) catch {};
}

// ─── the trust claim ─────────────────────────────────────────────────────

/// What the dialog says before the first run — the manifest's commands
/// and hooks, and whether its files call `task.run`, each rendered
/// through `trust.zig`'s own `Claim` so this dialog and the workspace
/// one read alike.
pub fn claimLines(arena: Allocator, s: Staged) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const m = s.manifest;
    try out.print(arena, "{s} {s}", .{ m.name, m.version });
    if (m.author.len > 0) try out.print(arena, " by {s}", .{m.author});
    try out.print(arena, " (script api {d})", .{m.api});
    if (m.description.len > 0) try out.print(arena, "\n{s}", .{m.description});
    try out.appendSlice(arena, "\nIt gets its own Lua state and runs every time mnml starts. It claims:");
    for (try trust.scriptClaims(arena, m.name, m.commands, m.hooks, s.runs_tasks)) |c| {
        try out.print(arena, "\n  \u{2022} {f}", .{c});
    }
    if (m.commands.len == 0 and m.hooks.len == 0) try out.appendSlice(arena, "\n  \u{2022} its manifest declares no commands and no hooks");
    return out.items;
}

// ─── the commands ────────────────────────────────────────────────────────

pub const table = .{
    .@"script.install" = &installPrompt,
    .@"script.enable" = &enableFocused,
    .@"script.disable" = &disableFocused,
    .@"script.toggle_enabled" = &toggleFocused,
    .@"script.remove" = &removeFocused,
    .@"script.update" = &updateFocused,
    .@"script.reload_one" = &reloadFocused,
    .@"script.open_folder" = &openFolder,
    .@"script.open_readme" = &openReadme,
    .@"script.rescan" = &rescan,
};

/// `script.install`: the prompt for a git URL, an archive or a folder.
fn installPrompt(app: *App) CommandError!void {
    const title = try app.gpa.dupe(u8, "Install script (git URL, archive or folder)");
    errdefer app.gpa.free(title);
    var state = app_mod.Prompt.init(app.gpa, title);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .script_install = title } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// What the prompt's Enter does: stage the source, then put the claims
/// on screen. Nothing has run at this point — the copy is on disk and
/// no Lua state exists for it.
pub fn acceptInstall(app: *App, src_in: []const u8) Allocator.Error!void {
    const src = std.mem.trim(u8, src_in, " \t");
    if (src.len == 0) return;
    try promptTrust(app, src, if (classify(src) == .directory) .community else .community);
}

/// Stage `src` and open the trust dialog for it.
pub fn promptTrust(app: *App, src: []const u8, source: Source) Allocator.Error!void {
    const arena = app.frame.allocator();
    const staged = stage(app, arena, src, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return,
    };
    if (!staged.manifest.supported()) {
        app.toast("scripts: {s} needs script api {d}; this build implements {d}", .{ staged.manifest.name, staged.manifest.api, manifest_mod.api_version });
        return;
    }
    const gpa = app.gpa;
    const msg = try gpa.dupe(u8, try claimLines(arena, staged));
    errdefer gpa.free(msg);
    const dir = try gpa.dupe(u8, staged.dir);
    errdefer gpa.free(dir);
    const name = try gpa.dupe(u8, staged.manifest.name);
    errdefer gpa.free(name);
    const url = try gpa.dupe(u8, src);
    errdefer gpa.free(url);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Install this script?", .message = msg, .choices = &install_choices, .selected = 1 },
        .purpose = .{ .script_install = .{ .dir = dir, .name = name, .url = url, .source = source } },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const install_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'i', .label = "Install" }, .{ .key = 'c', .label = "Cancel" } };
pub const remove_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'r', .label = "Remove" }, .{ .key = 'c', .label = "Cancel" } };

/// The trust dialog's answer. Anything but Install throws the staged
/// copy away without running a line of it.
pub fn answerInstall(app: *App, i: app_mod.ConfirmPurpose.ScriptInstall, choice: usize) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (choice != 0) {
        if (try installRoot(app, arena)) |root| Io.Dir.cwd().deleteTree(app.io, try std.fs.path.join(arena, &.{ root, ".staging" })) catch {};
        app.toast("scripts: {s} not installed", .{i.name});
        return;
    }
    commit(app, i.dir, i.name, i.source, i.url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => {},
    };
}

pub fn answerRemove(app: *App, name: []const u8, choice: usize) Allocator.Error!void {
    if (choice != 0) return;
    if (try removeEntry(app, name)) app.toast("scripts: removed {s}", .{name});
}

/// The row the SCRIPTS panel's Installed / Dev tab has the cursor on.
pub fn focused(app: *App) ?*Entry {
    return @import("scripts_panel.zig").focusedEntry(app);
}

fn needFocused(app: *App) CommandError!*Entry {
    return focused(app) orelse app.diag.fail(app.frame.allocator(), "scripts: no script row is focused", .{});
}

fn enableFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    try setEnabled(app, e, true);
    app.toast("scripts: {s} enabled", .{e.name});
}

fn disableFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    try setEnabled(app, e, false);
    app.toast("scripts: {s} disabled", .{e.name});
}

fn toggleFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    try setEnabled(app, e, !e.enabled);
    app.toast("scripts: {s} {s}", .{ e.name, if (e.enabled) "enabled" else "disabled" });
}

fn removeFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    if (e.source == .dev) return app.diag.fail(app.frame.allocator(), "scripts: {s} is a dev folder — remove it from scripts.dev_roots, not from here", .{e.name});
    const name = try app.gpa.dupe(u8, e.name);
    errdefer app.gpa.free(name);
    // The message is gpa-owned (the overlay outlives the frame) and the
    // title is a literal: a frame-arena string would dangle on the next
    // paint.
    const msg = try std.fmt.allocPrint(app.gpa, "{s} {s} and everything in {s} is deleted.", .{ e.name, e.version, e.dir });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Remove this script?", .message = msg, .choices = &remove_choices, .selected = 1 },
        .purpose = .{ .remove_script = name },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn updateFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    if (e.url.len == 0) return app.diag.fail(app.frame.allocator(), "scripts: {s} records no source to update from", .{e.name});
    const url = try app.frame.allocator().dupe(u8, e.url);
    const source = e.source;
    try promptTrust(app, url, source);
}

fn reloadFocused(app: *App) CommandError!void {
    const e = try needFocused(app);
    try reloadOne(app, e);
    app.toast("scripts: reloaded {s}{s}", .{ e.name, if (e.err) |_| " — it errored" else "" });
}

/// The row menu's *Open folder*: the script's directory in the file
/// tree when it sits under a root, its path as a toast otherwise (an
/// installed script lives in the data root, which the tree does not
/// show).
fn openFolder(app: *App) CommandError!void {
    const e = try needFocused(app);
    const dir = try app.frame.allocator().dupe(u8, e.dir);
    app.tree.revealPath(app, dir) catch {
        app.diag.clear();
        app.toast("scripts: {s}", .{dir});
        return;
    };
}

fn openReadme(app: *App) CommandError!void {
    const e = try needFocused(app);
    const arena = app.frame.allocator();
    const path = try std.fs.path.join(arena, &.{ e.dir, manifest_mod.readme_file });
    if (!fileExists(app, path)) return app.diag.fail(arena, "scripts: {s} ships no {s}", .{ e.name, manifest_mod.readme_file });
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "cannot open {s}: {s}", .{ path, @errorName(err) }),
    };
    app.showPane(id);
}

fn rescan(app: *App) CommandError!void {
    try scan(app);
    try @import("scripts_panel.zig").refreshMarket(app);
    app.toast("scripts: {d} installed", .{app.scripts.entries.items.len});
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "classify: a git URL, an archive, a folder" {
    try t.expectEqual(SourceKind.git, classify("https://example.invalid/x.git"));
    try t.expectEqual(SourceKind.git, classify("git@example.invalid:me/x"));
    try t.expectEqual(SourceKind.archive, classify("/tmp/x.tar.gz"));
    try t.expectEqual(SourceKind.archive, classify("/tmp/x.zip"));
    try t.expectEqual(SourceKind.directory, classify("/tmp/x"));
    try t.expectEqual(SourceKind.directory, classify("../elsewhere/todo-list"));
}

test "shippedRoot: build option, then ../share/mnml/lua, then share/mnml/lua, then the portable dir" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `<root>/prefix/bin` is the exe dir for a system-style layout,
    // `<root>/flat` for an unpacked archive.
    try tmp.dir.createDirPath(t.io, "prefix/bin");
    try tmp.dir.createDirPath(t.io, "flat");
    const bin = try std.fs.path.join(a, &.{ root, "prefix", "bin" });
    const flat = try std.fs.path.join(a, &.{ root, "flat" });

    // Nothing laid down yet and no build option: nothing is found.
    try t.expect((try shippedRoot(t.io, a, "", bin)) == null);
    try t.expect((try shippedRoot(t.io, a, "", null)) == null);
    // A build option that does not exist is not a hit either.
    const absent = try std.fs.path.join(a, &.{ root, "no-such-lua" });
    try t.expect((try shippedRoot(t.io, a, absent, bin)) == null);

    // 4. the portable directory beside the binary, lowest of the four.
    try tmp.dir.createDirPath(t.io, "flat/mnml-data/lua");
    try t.expectEqualStrings(
        try std.fs.path.join(a, &.{ flat, "mnml-data", "lua" }),
        (try shippedRoot(t.io, a, "", flat)).?,
    );

    // 3. `share/mnml/lua` beside the binary — the archive layout — wins
    //    over the portable directory.
    try tmp.dir.createDirPath(t.io, "flat/share/mnml/lua");
    try t.expectEqualStrings(
        try std.fs.path.join(a, &.{ flat, "share", "mnml", "lua" }),
        (try shippedRoot(t.io, a, "", flat)).?,
    );

    // 2. `../share/mnml/lua` — the system layout the .deb lays down —
    //    wins over both, and is found from a `bin/` one level down.
    try tmp.dir.createDirPath(t.io, "prefix/share/mnml/lua");
    try tmp.dir.createDirPath(t.io, "prefix/bin/share/mnml/lua");
    try tmp.dir.createDirPath(t.io, "prefix/bin/mnml-data/lua");
    try t.expectEqualStrings(
        try std.fs.path.join(a, &.{ root, "prefix", "share", "mnml", "lua" }),
        (try shippedRoot(t.io, a, "", bin)).?,
    );

    // 1. the build option beats every path beside the binary: a dev
    //    build lists the checkout's own `lua/`, not a stale install's.
    try tmp.dir.createDirPath(t.io, "checkout/lua");
    const checkout = try std.fs.path.join(a, &.{ root, "checkout", "lua" });
    try t.expectEqualStrings(checkout, (try shippedRoot(t.io, a, checkout, bin)).?);
}

test "the Marketplace tab lists the shipped set with no config, and either override takes it back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try writeScript(tmp.dir, t.io, "mine", "ours",
        \\.{ .name = "ours", .api = 1, .version = "0.1.0" }
    ,
        \\mnml.command{ id = "ours", run = function() end }
    );
    try writeScript(tmp.dir, t.io, "theirs", "yours",
        \\.{ .name = "yours", .api = 1, .version = "0.2.0" }
    ,
        \\mnml.command{ id = "yours", run = function() end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .env = &env, .cols = 80, .rows = 24 });
    defer app.deinit();

    // No config, no environment: the set that ships with mnml. Under a
    // test that is `build_options.scripts_dir` — the repo's own `lua/` —
    // and the five example scripts are its rows.
    {
        const arena = app.frame.allocator();
        const got = try marketplaceRoot(&app, arena);
        try t.expectEqualStrings(build_options.scripts_dir, got);
    }
    // The config override.
    app.cfg.scripts.marketplace_local = "mine";
    {
        const arena = app.frame.allocator();
        const got = try marketplaceRoot(&app, arena);
        try t.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "mine" }), got);
    }
    // The environment beats the config.
    try app.env.put("MNML_SCRIPTS_MARKETPLACE", "theirs");
    {
        const arena = app.frame.allocator();
        const got = try marketplaceRoot(&app, arena);
        try t.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "theirs" }), got);
    }
}

/// A script directory under `root`: `script.zon` + `init.lua`, plus any
/// extra files. The tests' fixture builder.
fn writeScript(dir: Io.Dir, io: Io, root: []const u8, name: []const u8, zon: []const u8, lua: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, name });
    try dir.createDirPath(io, d);
    var p: [std.fs.max_path_bytes]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&p, "{s}/script.zon", .{d}), .data = zon });
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&p, "{s}/init.lua", .{d}), .data = lua });
}

test "two installed scripts run in their own states: one erroring leaves the other working, budgets and namespaces are separate" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "scripts", "alpha",
        \\.{ .name = "alpha", .api = 1, .version = "1.0.0", .commands = .{ "user.alpha_go" }, .hooks = .{ "save_post" } }
    ,
        \\ns = mnml.decor.namespace("blame")
        \\mnml.command{ id = "alpha_go", run = function() mnml.toast("alpha") end }
        \\mnml.on("save_post", function() end)
    );
    try writeScript(tmp.dir, t.io, "scripts", "beta",
        \\.{ .name = "beta", .api = 1, .version = "0.2.0", .commands = .{ "user.beta_go" } }
    ,
        \\ns = mnml.decor.namespace("blame")
        \\mnml.command{ id = "beta_go", run = function() mnml.toast("beta") end }
    );
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    try t.expectEqual(@as(usize, 2), app.scripts.entries.items.len);
    const alpha = app.scripts.find("alpha") orelse return notInstalled(&app, "alpha");
    const beta = app.scripts.find("beta") orelse return notInstalled(&app, "beta");
    // Two states, two ids, neither 0 (which is `init.lua`'s).
    try t.expect(alpha.state != null and beta.state != null);
    try t.expect(alpha.state.? != beta.state.?);
    try t.expect(alpha.id != 0 and beta.id != 0 and alpha.id != beta.id);
    // Both commands are live and each routes back to its own state.
    try command.runNamed(&app, "user.alpha_go");
    try t.expectEqualStrings("alpha", app.lastToast().?);
    try command.runNamed(&app, "user.beta_go");
    try t.expectEqualStrings("beta", app.lastToast().?);
    // Both asked for a namespace called "blame" and got different ones.
    const decor = @import("script_decor.zig");
    var ns_a: u32 = 0;
    var ns_b: u32 = 0;
    var found_a = false;
    var found_b = false;
    for (app.script_decor.names.items, 0..) |slot, i| {
        if (!slot.live or !std.mem.eql(u8, slot.name, "blame")) continue;
        if (slot.owner == alpha.id) {
            ns_a = @intCast(i);
            found_a = true;
        }
        if (slot.owner == beta.id) {
            ns_b = @intCast(i);
            found_b = true;
        }
    }
    try t.expect(found_a and found_b and ns_a != ns_b);
    try t.expectEqual(@as(?u16, alpha.id), decor.namespaceOwner(&app, ns_a));
    // Alpha burns its budget: its own counter moves, beta's does not.
    // The script's own `pcall` cannot keep the trip inside Lua — it is
    // rethrown out to the host — and it is charged to alpha once.
    try t.expectError(error.Failed, app.luaState(alpha.id).?.runString("pcall(function() while true do end end)"));
    try t.expectEqual(@as(u32, 1), alpha.state.?.budget_hits);
    try t.expectEqual(@as(u32, 0), beta.state.?.budget_hits);
    try t.expectEqual(@as(u32, 0), app.script().budget_hits);
    // Alpha reloaded with a broken file: its command and its namespace
    // go, beta's stay, and the row says why.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "scripts/alpha/init.lua", .data = "mnml.nope()\n" });
    try reloadOne(&app, alpha);
    try t.expect(app.dyn_commands.get("user.alpha_go") == null);
    try t.expect(app.dyn_commands.get("user.beta_go") != null);
    try t.expect(alpha.err != null);
    try t.expect(alpha.state == null);
    try t.expect(beta.state != null);
    try t.expect(!decor.isNamespace(&app, ns_a));
    try t.expect(decor.isNamespace(&app, ns_b));
    // Beta still runs.
    try command.runNamed(&app, "user.beta_go");
    try t.expectEqualStrings("beta", app.lastToast().?);
}

test "a script's require reaches only its own lib; `..`, a separator and an absolute path are refused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "outside");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside/secret.lua", .data = "return 'leaked'" });
    try writeScript(tmp.dir, t.io, "scripts", "libbed",
        \\.{ .name = "libbed", .api = 1 }
    ,
        \\local helper = require("lib.helper")
        \\loaded = helper.greeting
        \\twice = require("lib.helper") == helper
    );
    try tmp.dir.createDirPath(t.io, "scripts/libbed/lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "scripts/libbed/lib/helper.lua", .data = "return { greeting = 'hi from lib' }" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    const e = app.scripts.find("libbed") orelse return notInstalled(&app, "libbed");
    try t.expect(e.err == null);
    const l = app.luaState(e.id).?;
    _ = l.L.getGlobal("loaded");
    try t.expectEqualStrings("hi from lib", try l.L.toString(-1));
    l.L.pop(1);
    // The cache: the same table comes back.
    _ = l.L.getGlobal("twice");
    try t.expect(l.L.toBoolean(-1));
    l.L.pop(1);
    // Everything that would leave the directory is refused by name, and
    // the refusal is the module system's — no file is read.
    try l.runString(
        \\for _, bad in ipairs{ "..lib.helper", "../outside/secret", "/etc/passwd", "lib/helper", "lib..helper", "" } do
        \\  local ok, err = pcall(require, bad)
        \\  assert(not ok, "require(" .. bad .. ") was allowed")
        \\  assert(not string.find(err, "leaked", 1, true), err)
        \\  assert(string.find(err, "is not a module under this script", 1, true), err)
        \\end
    );
    // A module that is not there names itself rather than reaching out.
    try l.runString(
        \\local ok, err = pcall(require, "lib.nope")
        \\assert(not ok)
        \\assert(string.find(err, "no `lib.nope` under this script", 1, true), err)
    );
    // `init.lua`'s own state has no `require` at all.
    try app.script().runString("assert(require == nil)");
}

test "install from a directory: the trust dialog lists the claims, Cancel runs nothing, Install lands the folder and runs it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "src", "greeter",
        \\.{ .name = "greeter", .api = 1, .version = "2.1.0", .author = "someone",
        \\   .description = "Says hello", .commands = .{ "user.greet" }, .hooks = .{ "save_post" } }
    ,
        \\mnml.command{ id = "greet", run = function() mnml.toast("hello") end }
        \\mnml.on("save_post", function() end)
        \\mnml.task.run{ cmd = "true", hidden = true }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const src = try std.fs.path.join(t.allocator, &.{ root, "src", "greeter" });
    defer t.allocator.free(src);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 100, .rows = 30 });
    defer app.deinit();
    try acceptInstall(&app, src);
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .script_install);
    // Cancel is the focused choice.
    try t.expectEqual(@as(usize, 1), app.overlay.confirm.state.selected);
    const msg = app.overlay.confirm.message;
    try t.expect(std.mem.indexOf(u8, msg, "greeter 2.1.0 by someone (script api 1)") != null);
    try t.expect(std.mem.indexOf(u8, msg, "script greeter — runs `user.greet (a command)` every time mnml starts") != null);
    try t.expect(std.mem.indexOf(u8, msg, "save_post (a hook)") != null);
    try t.expect(std.mem.indexOf(u8, msg, "task.run — it starts programs") != null);
    // Nothing has run: no state, no command.
    try t.expect(app.scripts.find("greeter") == null);
    try t.expect(app.dyn_commands.get("user.greet") == null);
    // Enter takes the focused choice, Cancel, and the staging goes.
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.scripts.find("greeter") == null);
    try t.expectEqualStrings("scripts: greeter not installed", app.lastToast().?);
    // Install: the folder lands under the data root and it runs.
    try acceptInstall(&app, src);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    const e = app.scripts.find("greeter") orelse return notInstalled(&app, "greeter");
    try t.expect(e.state != null);
    try t.expectEqualStrings("2.1.0", e.version);
    try t.expectEqual(Source.community, e.source);
    try t.expectEqualStrings(src, e.url);
    try command.runNamed(&app, "user.greet");
    try t.expectEqualStrings("hello", app.lastToast().?);
    try tmp.dir.access(t.io, "data/scripts/greeter/init.lua", .{});
    // Disable: the marker is written, the command goes, the row stays.
    try setEnabled(&app, e, false);
    try t.expect(app.dyn_commands.get("user.greet") == null);
    try tmp.dir.access(t.io, "data/scripts/greeter/.disabled", .{});
    try setEnabled(&app, e, true);
    try t.expect(app.dyn_commands.get("user.greet") != null);
    // Remove takes the folder with it.
    try t.expect(try removeEntry(&app, "greeter"));
    try t.expect(app.scripts.find("greeter") == null);
    try t.expect(app.dyn_commands.get("user.greet") == null);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "data/scripts/greeter/script.zon", .{}));
}

test "an installed script's `mnml.list{}` asks ITS state for the rows — the install lands, the rows are there, `l:refresh()` and the row menu reach the same state" {
    // The shipped `todo-list` does this and aborted the process at
    // `script_list.refresh` (`pushRef` asserted the ref's state), because
    // the rows fn was called through `init.lua`'s state.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "src", "lister",
        \\.{ .name = "lister", .api = 1, .version = "1.0.0", .commands = .{ "user.lister" } }
    ,
        \\calls = 0
        \\lst = mnml.list{ title = "L (lua)", sort = { "Name" }, rows = function(sort)
        \\  calls = calls + 1
        \\  return { { label = "row " .. calls, detail = "x:1" } }
        \\end, on_enter = function(row) mnml.toast("enter " .. row.label) end,
        \\on_menu = function(row) return { { label = "Act", run = function() mnml.toast("act " .. row.label) end } } end }
        \\mnml.section{ id = "lister", title = "L (lua)", glyph = "+", ascii = "L", list = lst, side = "left", after = "todos" }
        \\mnml.command{ id = "lister", run = function() lst:refresh() end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const src = try std.fs.path.join(t.allocator, &.{ root, "src", "lister" });
    defer t.allocator.free(src);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 100, .rows = 30 });
    defer app.deinit();
    try acceptInstall(&app, src);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    const e = app.scripts.find("lister") orelse return notInstalled(&app, "lister");
    try t.expect(e.state != null);
    try t.expectEqualStrings("scripts: installed lister", app.lastToast().?);
    // The list is registered in the installed state and its rows landed.
    try t.expectEqual(@as(usize, 1), app.script_lists.lists.items.len);
    const l = &app.script_lists.lists.items[0];
    try t.expectEqual(e.id, l.rows_fn.state);
    try t.expectEqual(@as(usize, 1), l.cache.len);
    try t.expectEqualStrings("row 1", l.cache[0].label);
    // `l:refresh()` from the script's own command, and the app's refresh
    // (the chip, the sort change), both call the rows fn where it lives.
    try command.runNamed(&app, "user.lister");
    try t.expectEqualStrings("row 2", l.cache[0].label);
    try script_list.refresh(&app, l);
    try t.expectEqualStrings("row 3", l.cache[0].label);
    // Enter reaches `on_enter` there too.
    try script_list.activate(&app, l, 0);
    try t.expectEqualStrings("enter row 3", app.lastToast().?);
    // The state is untouched: `init.lua`'s registry never held the ref.
    try t.expectEqual(@as(i32, 0), e.state.?.L.getTop());
}

test "a typo'd field in script.zon loads the script and names the field in a warning" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "scripts", "typo",
        \\.{ .name = "typo", .api = 1, .commmands = .{ "user.typo_go" } }
    ,
        \\mnml.command{ id = "typo_go", run = function() end }
    );
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    const e = app.scripts.find("typo") orelse return notInstalled(&app, "typo");
    try t.expect(e.state != null);
    try t.expect(app.dyn_commands.get("user.typo_go") != null);
    var named = false;
    for (app.toasts.items) |toast| {
        if (std.mem.indexOf(u8, toast.text, "typo: unknown field `.commmands` in script.zon (ignored)") != null) named = true;
    }
    try t.expect(named);
}

test "a manifest whose api is higher than this build's is a row that says so, and never runs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "scripts", "future",
        \\.{ .name = "future", .api = 99, .version = "9.0.0" }
    ,
        \\mnml.command{ id = "future_go", run = function() end }
    );
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    const e = app.scripts.find("future") orelse return notInstalled(&app, "future");
    try t.expect(!e.supported());
    try t.expect(e.state == null);
    try t.expect(app.dyn_commands.get("user.future_go") == null);
    try t.expect(std.mem.indexOf(u8, e.err.?, "written for mnml script api 99") != null);
}

test "a dev root's script reloads when one of its files is saved" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "dev", "wip",
        \\.{ .name = "wip", .api = 1 }
    ,
        \\mnml.command{ id = "one", run = function() end }
    );
    var cfg: @import("../config/Config.zig") = .{};
    cfg.scripts.dev_roots = &.{"dev"};
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    const e = app.scripts.find("wip") orelse return notInstalled(&app, "wip");
    try t.expectEqual(Source.dev, e.source);
    try t.expect(app.dyn_commands.get("user.one") != null);
    // Edit the file in a pane and save: the hook reloads that script.
    const path = try std.fs.path.join(t.allocator, &.{ root, "dev", "wip", "init.lua" });
    defer t.allocator.free(path);
    const id = try app.openEditor(path);
    const ed = app.panes.editor(id).?;
    try app.splice(ed, 0, ed.buf.editor.len(), "mnml.command{ id = 'two', run = function() end }\n");
    try command.run(&app, .{ .static = .@"file.save" });
    try t.expect(app.dyn_commands.get("user.one") == null);
    try t.expect(app.dyn_commands.get("user.two") != null);
}

test "install from an archive and from a local git repo; the manifest records where it came from" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "src", "packed",
        \\.{ .name = "packed", .api = 1, .version = "1.0.0", .commands = .{ "user.packed_go" } }
    ,
        \\mnml.command{ id = "packed_go", run = function() mnml.toast("packed") end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 100, .rows = 30 });
    defer app.deinit();

    // ── an archive ──
    const tar = try std.fs.path.join(t.allocator, &.{ root, "packed.tar" });
    defer t.allocator.free(tar);
    if (!runArgv(&app, &.{ "tar", "-cf", tar, "-C", "src", "packed" }, root)) return error.SkipZigTest;
    try acceptInstall(&app, tar);
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    const packed_e = app.scripts.find("packed") orelse return notInstalled(&app, "packed");
    try t.expect(packed_e.state != null);
    try t.expectEqualStrings(tar, packed_e.url);
    try command.runNamed(&app, "user.packed_go");
    try t.expectEqualStrings("packed", app.lastToast().?);
    // The installed manifest records the source, so `script.update`
    // knows where to go back to.
    const zon = try tmp.dir.readFileAlloc(t.io, "data/scripts/packed/script.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(zon);
    try t.expect(std.mem.indexOf(u8, zon, ".source = .community") != null);
    try t.expect(std.mem.indexOf(u8, zon, tar) != null);

    // ── a local git repo (the `zig-spec-git.sh` recipe: init, add, commit) ──
    try writeScript(tmp.dir, t.io, "repo", "cloned",
        \\.{ .name = "cloned", .api = 1, .version = "0.3.0" }
    ,
        \\mnml.command{ id = "cloned_go", run = function() mnml.toast("cloned") end }
    );
    const repo = try std.fs.path.join(t.allocator, &.{ root, "repo", "cloned" });
    defer t.allocator.free(repo);
    if (!runArgv(&app, &.{ "git", "init", "-q", "." }, repo)) return error.SkipZigTest;
    _ = runArgv(&app, &.{ "git", "config", "user.email", "t@example.invalid" }, repo);
    _ = runArgv(&app, &.{ "git", "config", "user.name", "t" }, repo);
    _ = runArgv(&app, &.{ "git", "add", "-A" }, repo);
    if (!runArgv(&app, &.{ "git", "commit", "-q", "-m", "seed" }, repo)) return error.SkipZigTest;
    // A path ending in `.git` is the git shape even on this machine.
    const url = try std.fmt.allocPrint(t.allocator, "{s}/.git", .{repo});
    defer t.allocator.free(url);
    try t.expectEqual(SourceKind.git, classify(url));
    try acceptInstall(&app, url);
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    const cloned = app.scripts.find("cloned") orelse return notInstalled(&app, "cloned");
    try t.expect(cloned.state != null);
    try command.runNamed(&app, "user.cloned_go");
    try t.expectEqualStrings("cloned", app.lastToast().?);
    // `.git` never travels into the installed copy.
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "data/scripts/cloned/.git", .{}));
}

test "script.remove asks first, and the dialog it opens survives the frame it was opened in" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "scripts", "doomed",
        \\.{ .name = "doomed", .api = 1, .version = "1.0.0", .commands = .{ "user.doomed_go" } }
    ,
        \\mnml.command{ id = "doomed_go", run = function() end }
    );
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    const panel = @import("scripts_panel.zig");
    try command.run(&app, .{ .static = .@"view.activity_scripts" });
    const list = try panel.rows(&app, app.frame.allocator());
    app.scripts_panel.panel.cursor = list.len - 1;
    // The frame arena over a fixed buffer for the open, where a reset
    // hands the SAME bytes back. A `render` on the gpa-backed arena
    // proves nothing: a DebugAllocator reset moves the next frame's node,
    // so the dead bytes are never written over and a borrowed title
    // reads fine in the test and as garbage in the app.
    var frame_buf: [512 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&frame_buf);
    const real_frame = app.frame;
    app.frame = alloc_mod.FrameArena.init(fba.allocator());
    try command.run(&app, .{ .static = .@"script.remove" });
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .remove_script);
    // Cancel is the focused choice.
    try t.expectEqual(@as(usize, 1), app.overlay.confirm.state.selected);
    app.frame.begin();
    for (0..1024) |_| {
        const chunk = try app.frame.allocator().alloc(u8, 16);
        @memset(chunk, 'X');
    }
    try t.expectEqualStrings("Remove this script?", app.overlay.confirm.state.title);
    try t.expect(std.mem.startsWith(u8, app.overlay.confirm.message, "doomed 1.0.0"));
    app.frame.deinit();
    app.frame = real_frame;
    // Cancel keeps it.
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.scripts.find("doomed") != null);
    // Remove takes the folder and the command with it.
    try command.run(&app, .{ .static = .@"script.remove" });
    try app.handle(.{ .key = app_mod.Key.char('r') });
    try t.expect(app.scripts.find("doomed") == null);
    try t.expect(app.dyn_commands.get("user.doomed_go") == null);
    try t.expectEqualStrings("scripts: removed doomed", app.lastToast().?);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "scripts/doomed/script.zon", .{}));
}

test "script.reload takes the installed scripts with init.lua, and a vim operator letter never outlives the App that claimed it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try writeScript(tmp.dir, t.io, "scripts", "surrounder",
        \\.{ .name = "surrounder", .api = 1, .version = "1.0.0" }
    ,
        \\mnml.operator{ id = "wrap", keys = { vim = "gw" }, run = function() end }
        \\mnml.command{ id = "wrap_cmd", run = function() mnml.toast("wrapped") end }
    );
    const script_ops = @import("../input/script_ops.zig");
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = root, .cols = 100, .rows = 30 });
        defer app.deinit();
        const e = app.scripts.find("surrounder") orelse return notInstalled(&app, "surrounder");
        try t.expect(e.state != null);
        // The letter is claimed by the SCRIPT's state, not `init.lua`'s.
        try t.expectEqual(e.id, script_ops.lookup('w').?.state);
        // `script.reload` reloads the installed scripts too, not just
        // the `init.lua` files: the file on disk has changed, and the
        // command that comes back is the new one.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "scripts/surrounder/init.lua", .data = "mnml.operator{ id = 'wrap', keys = { vim = 'gw' }, run = function() end }\nmnml.command{ id = 'wrap_cmd_v2', run = function() mnml.toast('wrapped') end }\n" });
        try command.run(&app, .{ .static = .@"script.reload" });
        try t.expect(app.dyn_commands.get("user.wrap_cmd") == null);
        try t.expect(app.dyn_commands.get("user.wrap_cmd_v2") != null);
        try t.expect(std.mem.indexOf(u8, app.lastToast().?, "1 installed script") != null);
        // Still one claim, and still that script's.
        const after = app.scripts.find("surrounder") orelse return notInstalled(&app, "surrounder");
        try t.expectEqual(after.id, script_ops.lookup('w').?.state);
        try command.runNamed(&app, "user.wrap_cmd_v2");
        try t.expectEqualStrings("wrapped", app.lastToast().?);
    }
    // The first App is gone, and its script's claim went with the state
    // that made it (`closeState` clears its own). A second App in the
    // same process therefore starts with an empty table rather than a
    // letter pointing at a stale operator index.
    {
        var app2 = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
        defer app2.deinit();
        try t.expect(script_ops.lookup('w') == null);
        try t.expectEqual(@as(usize, 0), script_ops.count());
    }
}

test "an installed script's statusline segment polls and paints, and its picker source lists, previews and accepts — all in ITS state, not init.lua's" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try writeScript(tmp.dir, t.io, "src", "peek",
        \\.{ .name = "peek", .api = 1, .version = "1.0.0", .commands = .{ "user.peek" } }
    ,
        \\mnml.statusline.segment{ id = "peek", fn = function() return "PEEK-SEG" end }
        \\mnml.picker.source{ id = "peeks", title = "Peeks",
        \\  items = function(q) return { { label = "peek-item", data = 7 } } end,
        \\  preview = function(row) return { "preview of " .. row.label } end,
        \\  on_accept = function(row) mnml.toast("accepted " .. row.label .. " " .. row.data) end }
        \\mnml.command{ id = "peek", run = function() mnml.picker.open("peeks") end }
    );
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const src = try std.fs.path.join(t.allocator, &.{ root, "src", "peek" });
    defer t.allocator.free(src);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = data, .cols = 120, .rows = 30 });
    defer app.deinit();
    try acceptInstall(&app, src);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    const e = app.scripts.find("peek") orelse return notInstalled(&app, "peek");
    try t.expect(e.state != null);
    // The registrations landed in the installed state, not init.lua's.
    try t.expectEqual(@as(usize, 1), e.state.?.segments.items.len);
    try t.expectEqual(@as(usize, 0), app.script().segments.items.len);
    // The segment: polled by the App's tick and painted on the statusline.
    try app.tick(app.now_ms + 1000);
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "PEEK-SEG") != null);
    // The picker source: the row, its preview, and on_accept on Enter.
    try command.runNamed(&app, "user.peek");
    try t.expect(app.overlay == .picker);
    try t.expectEqual(app_mod.PickerKind.lua, app.overlay.picker.kind);
    try t.expectEqual(@as(usize, 1), app.overlay.picker.labels.len);
    try t.expectEqualStrings("peek-item", app.overlay.picker.labels[0]);
    try t.expectEqual(e.id, app.overlay.picker.lua_state);
    try t.expect(app.overlay.picker.preview.len == 1);
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay != .picker);
    try t.expectEqualStrings("accepted peek-item 7", app.lastToast().?);
}

/// A script the test expected installed is not: name what the app said
/// last, rather than panicking on the missing entry.
fn notInstalled(app: *App, name: []const u8) error{TestUnexpectedResult} {
    std.debug.print("script {s} is not installed; last toast: {s}\n", .{ name, app.lastToast() orelse "(none)" });
    return error.TestUnexpectedResult;
}
