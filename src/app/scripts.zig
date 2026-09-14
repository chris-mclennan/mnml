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
//!   marketplace   the curated index (`scripts.marketplace_url`, or a
//!                 local folder), `official` badge
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
const CommandError = command.CommandError;
const lua_mod = @import("../scripting/lua.zig");
const Lua = lua_mod.Lua;
const manifest_mod = @import("../scripting/manifest.zig");
const Manifest = manifest_mod.Manifest;
const Source = manifest_mod.Source;

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

/// `<data root>/scripts`, on `arena`; null when there is no data root.
pub fn installRoot(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
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

/// The folder the Marketplace tab lists: `MNML_SCRIPTS_MARKETPLACE`,
/// else `scripts.marketplace_local`. Empty when neither is set — the
/// `marketplace_url` default names a repo that is not live yet, so the
/// tab then says so rather than pretending to fetch.
pub fn marketplaceRoot(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    if (app.env.get("MNML_SCRIPTS_MARKETPLACE")) |v| if (v.len > 0) return try resolveRoot(app, arena, v);
    return resolveRoot(app, arena, app.cfg.scripts.marketplace_local);
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
    for (app.cfg.scripts.dev_roots) |spec| {
        const root = try resolveRoot(app, arena, spec);
        if (root.len > 0) try scanRoot(app, root, .dev);
    }
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

/// What the dialog says before the first run: the commands the manifest
/// says it adds, the hooks it says it subscribes, and whether its files
/// contain `task.run` — the only way a script reaches a program.
pub fn claimLines(arena: Allocator, s: Staged) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const m = s.manifest;
    try out.print(arena, "{s} {s}", .{ m.name, m.version });
    if (m.author.len > 0) try out.print(arena, " by {s}", .{m.author});
    try out.print(arena, " (script api {d})", .{m.api});
    if (m.description.len > 0) try out.print(arena, "\n{s}", .{m.description});
    try out.appendSlice(arena, "\n\nIt runs when mnml starts, and claims:");
    if (m.commands.len == 0) {
        try out.appendSlice(arena, "\n  \u{2022} no commands");
    } else for (m.commands) |c| try out.print(arena, "\n  \u{2022} command {s}", .{c});
    if (m.hooks.len == 0) {
        try out.appendSlice(arena, "\n  \u{2022} no hooks");
    } else for (m.hooks) |h| try out.print(arena, "\n  \u{2022} hook {s} \u{2014} runs when mnml does", .{h});
    try out.print(arena, "\n  \u{2022} {s}", .{if (s.runs_tasks)
        "runs programs \u{2014} its files call task.run"
    else
        "runs no programs \u{2014} no task.run in its files"});
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
    const msg = try std.fmt.allocPrint(app.gpa, "{s} and everything in its folder is deleted.", .{e.dir});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = try std.fmt.allocPrint(app.frame.allocator(), "Remove {s}?", .{name}), .message = msg, .choices = &remove_choices, .selected = 1 },
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
