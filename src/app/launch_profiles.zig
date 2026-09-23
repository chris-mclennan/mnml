//! AI launch profiles — named ways to start the `claude` / `codex`
//! session a chip opens. A profile is config (`.ai.launch_profiles`):
//! a `binary`, its `args`, `env` (`KEY=VALUE` lines) and a `cwd_mode`
//! (workspace / home / the active file's directory). The chip's
//! right-click lists them: *New session: <name>* starts one session
//! with that profile, *Default: <name>* persists it as what a plain
//! click (or `ai.claude_code` / `ai.codex`) spawns.
//!
//! A profile runs through a shim, `<data root>/bin/mnml-ai-<name>`
//! (`.cmd` on Windows), written on demand right before the spawn: it
//! exports the env, then `exec`s the binary with the args and whatever
//! the caller appends. The shim is the pty's argv[0], so a profile
//! session is recognisable by name (`isProfileArgv`) and a user can
//! run the same thing from any shell.
//!
//! // changed: Rust read `[[launch_profile]]` from the integration
//! manifest (TOML, two scopes, a `wrapper` legacy key). E1 makes the
//! config ZON the one place; the built-in `default` profile is the
//! bare binary and needs no entry; `default_profile.<product>` is the
//! persisted choice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const context_menus = @import("context_menus.zig");
const CommandError = command.CommandError;
const settings = @import("settings.zig");
const pty_pane = @import("pty_pane.zig");
const cli = @import("../ai/cli.zig");
const session_worktree = @import("session_worktree.zig");

pub const Product = Config.AiProduct;
pub const Profile = Config.LaunchProfile;

/// The implicit profile every product has: its binary on PATH.
pub const builtin_name = "default";
pub const shim_prefix = "mnml-ai-";

pub fn binaryOf(product: Product) []const u8 {
    return switch (product) {
        .claude => cli.claude_binary,
        .codex => cli.codex_binary,
    };
}

/// The configured profiles of `product`, in config order.
pub fn list(app: *const App, arena: Allocator, product: Product) Allocator.Error![]const Profile {
    var out: std.ArrayListUnmanaged(Profile) = .empty;
    for (app.cfg.ai.launch_profiles) |p| if (p.product == product and p.name.len > 0) try out.append(arena, p);
    return out.toOwnedSlice(arena);
}

pub fn find(app: *const App, product: Product, name: []const u8) ?Profile {
    for (app.cfg.ai.launch_profiles) |p| if (p.product == product and std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The persisted default's name, or `default` when unset or when it
/// names nothing configured.
pub fn defaultName(app: *const App, product: Product) []const u8 {
    const want = switch (product) {
        .claude => app.cfg.ai.default_profile.claude,
        .codex => app.cfg.ai.default_profile.codex,
    } orelse return builtin_name;
    return if (find(app, product, want) != null) want else builtin_name;
}

/// A profile name that is safe as a file name: letters, digits, `-`,
/// `_`, `.`; nothing else, and never empty.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

// ─── the shim ───────────────────────────────────────────────────────────

pub const WriteError = Allocator.Error || error{WriteFailed};

pub const ShimOs = enum { posix, windows };

pub fn shimOs() ShimOs {
    return if (builtin.os.tag == .windows) .windows else .posix;
}

/// `<data root>/bin/mnml-ai-<name>` (`.cmd` on Windows).
pub fn shimPath(arena: Allocator, data_root: []const u8, name: []const u8, os: ShimOs) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ shim_prefix, name, if (os == .windows) ".cmd" else "" });
    return std.fs.path.join(arena, &.{ data_root, "bin", file });
}

/// The shim's text: the env exported, then the binary with its args
/// and the caller's (`"$@"` / `%*`). POSIX values are single-quoted
/// with the `'\''` escape; Windows values are taken as-is (cmd has no
/// portable quoting of `%`).
pub fn shimText(arena: Allocator, p: Profile, os: ShimOs) WriteError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    switch (os) {
        .posix => {
            try w.print("#!/bin/sh\n# mnml launch profile \"{s}\" — written by mnml; change the profile in config.zon, not here.\n", .{p.name});
            for (p.env) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                try w.print("export {s}={s}\n", .{ kv[0..eq], try shQuote(arena, kv[eq + 1 ..]) });
            }
            try w.print("exec {s}", .{try shQuote(arena, p.binary)});
            for (p.args) |a| try w.print(" {s}", .{try shQuote(arena, a)});
            try w.writeAll(" \"$@\"\n");
        },
        .windows => {
            try w.print("@echo off\r\nrem mnml launch profile \"{s}\" — written by mnml; change the profile in config.zon, not here.\r\n", .{p.name});
            for (p.env) |kv| {
                if (std.mem.indexOfScalar(u8, kv, '=') == null) continue;
                try w.print("set {s}\r\n", .{kv});
            }
            try w.print("\"{s}\"", .{p.binary});
            for (p.args) |a| try w.print(" \"{s}\"", .{a});
            try w.writeAll(" %*\r\n");
        },
    }
    return out.toOwnedSlice();
}

/// Single-quote for `sh`; a plain word stays bare.
fn shQuote(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var plain = s.len > 0;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/' or c == '.' or c == ':' or c == '=' or c == '@' or c == '%' or c == '+')) {
        plain = false;
    };
    if (plain) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// Write the shim for `p` under `data_root` and return its path (on
/// `arena`). Rewritten every time, so a changed profile takes effect
/// at the next launch.
pub fn writeShim(arena: Allocator, io: Io, data_root: []const u8, p: Profile, os: ShimOs) WriteError![]const u8 {
    const path = try shimPath(arena, data_root, p.name, os);
    const text = try shimText(arena, p, os);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, std.fs.path.dirname(path) orelse ".") catch return error.WriteFailed;
    const perms: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755);
    const file = cwd.createFile(io, path, .{ .truncate = true, .permissions = perms }) catch return error.WriteFailed;
    defer file.close(io);
    file.writeStreamingAll(io, text) catch return error.WriteFailed;
    file.setPermissions(io, perms) catch {};
    return path;
}

// ─── sessions ───────────────────────────────────────────────────────────

pub const Launch = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    /// `claude` for the built-in, `claude (name)` for a profile.
    label: []const u8,
};

/// What a session of `product` runs under profile `name` (`default`
/// is the bare binary): the shim is written first. The cwd follows
/// the profile's `cwd_mode`; null is the workspace.
pub fn launch(app: *App, arena: Allocator, product: Product, name: []const u8) CommandError!Launch {
    if (std.mem.eql(u8, name, builtin_name)) {
        return .{ .argv = try withSessionId(app, arena, product, binaryOf(product)), .cwd = null, .label = @tagName(product) };
    }
    const p = find(app, product, name) orelse return app.diag.fail(arena, "launch profile `{s}` is not configured for {s}", .{ name, @tagName(product) });
    if (!validName(p.name)) return app.diag.fail(arena, "launch profile `{s}`: the name must be letters, digits, `-`, `_` or `.`", .{p.name});
    if (p.binary.len == 0) return app.diag.fail(arena, "launch profile `{s}` has no binary", .{p.name});
    if (app.data_root.len == 0) return app.diag.fail(arena, "launch profile `{s}`: no data root to write the shim under", .{p.name});
    const shim = writeShim(arena, app.io, app.data_root, p, shimOs()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return app.diag.fail(arena, "launch profile `{s}`: could not write {s}", .{ p.name, try shimPath(arena, app.data_root, p.name, shimOs()) }),
    };
    const cwd: ?[]const u8 = switch (p.cwd_mode) {
        .workspace => null,
        .home => app.homeDir() orelse app.env.get("HOME"),
        .file_dir => blk: {
            const id = app.last_editor orelse break :blk null;
            const e = app.panes.editor(id) orelse break :blk null;
            const path = e.buf.doc.path orelse break :blk null;
            break :blk std.fs.path.dirname(path);
        },
    };
    return .{
        .argv = try withSessionId(app, arena, product, shim),
        .cwd = cwd,
        .label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ @tagName(product), p.name }),
    };
}

/// // changed (sessions-card): a Claude session starts with a
/// `--session-id <uuid>` of mnml's own, as Rust's `claude_code` profile
/// does, so the pane knows its transcript from the first frame — the
/// SESSIONS card reads the exchange under that id and the scan pairs
/// the process with it. Codex has no such flag. The shim passes `"$@"`
/// on, so a profile gets the flag too.
fn withSessionId(app: *App, arena: Allocator, product: Product, argv0: []const u8) Allocator.Error![]const []const u8 {
    if (product != .claude) return arena.dupe([]const u8, &.{argv0});
    const sid = try arena.dupe(u8, &cli.genSessionId(app.io));
    return arena.dupe([]const u8, &.{ argv0, "--session-id", sid });
}

/// Whether `argv0` is `product` — its bare binary, or a shim of one of
/// its profiles.
pub fn isProductArgv(app: *const App, argv0: []const u8, product: Product) bool {
    const base = std.fs.path.basename(argv0);
    if (std.mem.eql(u8, base, binaryOf(product))) return true;
    if (!std.mem.startsWith(u8, base, shim_prefix)) return false;
    var name = base[shim_prefix.len..];
    if (std.mem.endsWith(u8, name, ".cmd")) name = name[0 .. name.len - 4];
    return find(app, product, name) != null;
}

/// Open one session with `name`'s profile, beside the active pane. A
/// profile with `.worktree` opens the name prompt instead and returns
/// null: the session starts once the worktree exists
/// (`session_worktree.acceptName`).
pub fn openSessionWith(app: *App, product: Product, name: []const u8, placement: pty_pane.Placement) CommandError!?PaneId {
    if (find(app, product, name)) |p| if (p.worktree) {
        try session_worktree.openNamePrompt(app, product, name);
        return null;
    };
    const l = try launch(app, app.frame.allocator(), product, name);
    return try pty_pane.openSession(app, .{ .argv = l.argv, .cwd = l.cwd, .label = l.label, .placement = placement, .kind = .command });
}

/// Persist `name` as the product's default (`.ai.default_profile.<product>`).
pub fn setDefault(app: *App, product: Product, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (!std.mem.eql(u8, name, builtin_name) and find(app, product, name) == null) return app.diag.fail(arena, "launch profile `{s}` is not configured for {s}", .{ name, @tagName(product) });
    const owned = try app.gpa.dupe(u8, name);
    errdefer app.gpa.free(owned);
    _ = try settings.persist(app, .home, &.{ "ai", "default_profile", @tagName(product) }, name);
    // The in-memory config borrows the loader's arena; a gpa-owned
    // copy lives in the app until the next load replaces it.
    const slot: *?[]const u8 = switch (product) {
        .claude => &app.cfg.ai.default_profile.claude,
        .codex => &app.cfg.ai.default_profile.codex,
    };
    if (app.ai.owned_default) |old| app.gpa.free(old);
    app.ai.owned_default = owned;
    slot.* = owned;
    app.toast("default {s} profile → {s}", .{ @tagName(product), name });
}

// ─── the chip menu ──────────────────────────────────────────────────────

/// The rows the chip's right-click shows: a *New session* per profile
/// (the built-in first), *New session in a worktree…* for the default
/// one, then a *Default* per profile with the current one checked. One
/// profile or none: only the built-in rows.
pub fn menuItems(app: *const App, gpa: Allocator, product: Product) Allocator.Error![]command.MenuItem {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const profiles = try list(app, arena_state.allocator(), product);
    const current = defaultName(app, product);
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer {
        for (items.items) |it| gpa.free(it.label);
        items.deinit(gpa);
    }
    const n: u16 = @intCast(profiles.len + 1);
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const name = if (i == 0) builtin_name else profiles[i - 1].name;
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(gpa, "New session: {s}", .{name}),
            .action = .{ .ai_profile = .{ .product = product, .index = i, .set_default = false } },
        });
    }
    // The worktree lane: the default profile's session in a tree of
    // its own (`session_worktree.zig`).
    var default_index: u16 = 0;
    for (profiles, 0..) |p, pi| if (std.mem.eql(u8, p.name, current)) {
        default_index = @intCast(pi + 1);
    };
    try items.append(gpa, .{
        .label = try gpa.dupe(u8, worktree_label),
        .action = .{ .ai_profile = .{ .product = product, .index = default_index, .set_default = false, .worktree = true } },
    });
    i = 0;
    while (i < n) : (i += 1) {
        const name = if (i == 0) builtin_name else profiles[i - 1].name;
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(gpa, "Default: {s}", .{name}),
            .action = .{ .ai_profile = .{ .product = product, .index = i, .set_default = true } },
            .checked = std.mem.eql(u8, name, current),
            .separator_before = i == 0,
        });
    }
    // The Rust chip's legacy row: a single launcher script. Profiles
    // cover it (`binary` + `args` + `env`), so the row opens the
    // profile picker and says so.
    try items.append(gpa, .{
        .label = try gpa.dupe(u8, legacy_label),
        .action = .{ .ai_profile = .{ .product = product, .index = legacy_index, .set_default = false } },
        .separator_before = true,
    });
    return items.toOwnedSlice(gpa);
}

pub const worktree_label = "New session in a worktree…";
pub const legacy_label = "Set launcher script…";
/// `AiProfileAction.index` of the legacy row.
pub const legacy_index: u16 = std.math.maxInt(u16);
pub const legacy_note = "launcher scripts are launch profiles now — a profile names the binary, its args and env (config `.ai.launch_profiles`); pick one to start";

/// The legacy row: the profiles as a picker (Enter starts a session)
/// and the migration note.
pub fn openProfilePicker(app: *App, product: Product) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const profiles = try list(app, arena, product);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    try labels.append(gpa, try gpa.dupe(u8, builtin_name));
    try details.append(gpa, try std.fmt.allocPrint(gpa, "{s} on PATH", .{binaryOf(product)}));
    for (profiles) |p| {
        try labels.append(gpa, try gpa.dupe(u8, p.name));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ p.binary, try std.mem.join(arena, " ", p.args) }));
    }
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.openPickerWith(app, if (product == .claude) "Claude Code launch profiles" else "Codex launch profiles", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0));
    app.overlay.picker.on_accept = if (product == .claude) &acceptClaudeProfile else &acceptCodexProfile;
    app.toast("{s}", .{legacy_note});
}

fn acceptClaudeProfile(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    return acceptProfile(app, .claude, label);
}

fn acceptCodexProfile(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    return acceptProfile(app, .codex, label);
}

fn acceptProfile(app: *App, product: Product, name: []const u8) Allocator.Error!void {
    _ = openSessionWith(app, product, name, .right) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m});
            app.diag.clear();
        },
    };
}

/// The chip's right-click.
pub fn openChipMenu(app: *App, product: Product, x: u16, y: u16) Allocator.Error!void {
    // Every label carries a profile name, so they are built for this
    // open: the menu's own `mem` arena owns them, which is what frees
    // them again (`MenuState`'s deinit frees the row array and the
    // arena — never the labels one by one).
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const rows = try menuItems(app, mem.allocator(), product);
    const items = try app.gpa.dupe(command.MenuItem, rows);
    errdefer app.gpa.free(items);
    try context_menus.openOwned(app, if (product == .claude) "Claude Code" else "Codex", items, x, y, mem);
}

/// A menu row: `index` 0 is the built-in, else `list()[index - 1]`.
pub fn menuAction(app: *App, a: command.AiProfileAction) CommandError!void {
    const arena = app.frame.allocator();
    if (a.index == legacy_index) return openProfilePicker(app, a.product);
    const profiles = try list(app, arena, a.product);
    const name: []const u8 = if (a.index == 0) builtin_name else (if (a.index - 1 < profiles.len) profiles[a.index - 1].name else return app.diag.fail(arena, "that profile is gone", .{}));
    if (a.set_default) return setDefault(app, a.product, name);
    if (a.worktree) return session_worktree.openNamePrompt(app, a.product, name);
    _ = try openSessionWith(app, a.product, name, .right);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const two_profiles = [_]Profile{
    .{ .name = "multi-repo", .binary = "/opt/bin/claude-multi.sh", .args = &.{ "--add-dir", "../lib" }, .env = &.{ "CLAUDE_CONFIG_DIR=/tmp/cfg", "MODEL=it's" }, .cwd_mode = .home },
    .{ .name = "fast", .product = .codex, .binary = "codex", .args = &.{"--fast"} },
};

test "shim text: env exported, args quoted, the caller's args appended; the Windows twin" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const posix = try shimText(a, two_profiles[0], .posix);
    try t.expectEqualStrings(
        \\#!/bin/sh
        \\# mnml launch profile "multi-repo" — written by mnml; change the profile in config.zon, not here.
        \\export CLAUDE_CONFIG_DIR=/tmp/cfg
        \\export MODEL='it'\''s'
        \\exec /opt/bin/claude-multi.sh --add-dir ../lib "$@"
        \\
    , posix);
    const win = try shimText(a, two_profiles[0], .windows);
    try t.expectEqualStrings("@echo off\r\nrem mnml launch profile \"multi-repo\" — written by mnml; change the profile in config.zon, not here.\r\nset CLAUDE_CONFIG_DIR=/tmp/cfg\r\nset MODEL=it's\r\n\"/opt/bin/claude-multi.sh\" \"--add-dir\" \"../lib\" %*\r\n", win);
    try t.expectEqualStrings("/data/bin/mnml-ai-fast", try shimPath(a, "/data", "fast", .posix));
    try t.expectEqualStrings("/data/bin/mnml-ai-fast.cmd", try shimPath(a, "/data", "fast", .windows));
    try t.expect(validName("multi-repo"));
    try t.expect(!validName("../x"));
    try t.expect(!validName("a b"));
    try t.expect(!validName(""));
}

test "writeShim lands an executable file under <data root>/bin and rewrites it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = try writeShim(a, t.io, root, two_profiles[1], .posix);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ root, "bin", "mnml-ai-fast" }), path);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "exec codex --fast \"$@\"") != null);
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, path, .{});
        try t.expect(st.permissions.toMode() & 0o100 != 0);
    }
    var changed = two_profiles[1];
    changed.args = &.{"--slow"};
    _ = try writeShim(a, t.io, root, changed, .posix);
    const text2 = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    try t.expect(std.mem.indexOf(u8, text2, "--slow") != null);
}

test "launch: the built-in is the bare binary; a profile is its shim with the mode's cwd; the menu lists both lanes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var cfg: Config = .{};
    cfg.ai.launch_profiles = &two_profiles;
    cfg.ai.default_profile.claude = "multi-repo";
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = "/tmp", .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try app.env.put("HOME", "/home/x");
    const a = app.frame.allocator();

    try t.expectEqualStrings("multi-repo", defaultName(&app, .claude));
    try t.expectEqualStrings(builtin_name, defaultName(&app, .codex));
    const bare = try launch(&app, a, .codex, builtin_name);
    try t.expectEqualStrings("codex", bare.argv[0]);
    try t.expectEqualStrings("codex", bare.label);
    try t.expect(bare.cwd == null);

    const l = try launch(&app, a, .claude, defaultName(&app, .claude));
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ root, "bin", "mnml-ai-multi-repo" }), l.argv[0]);
    try t.expectEqualStrings("claude (multi-repo)", l.label);
    try t.expectEqualStrings("/home/x", l.cwd.?);
    try t.expect(isProductArgv(&app, l.argv[0], .claude));
    try t.expect(!isProductArgv(&app, l.argv[0], .codex));
    try t.expect(isProductArgv(&app, "claude", .claude));
    try t.expect(!isProductArgv(&app, "/x/bin/mnml-ai-nope", .claude));
    try t.expectError(error.Failed, launch(&app, a, .claude, "nope"));

    const items = try menuItems(&app, t.allocator, .claude);
    defer {
        for (items) |it| t.allocator.free(it.label);
        t.allocator.free(items);
    }
    try t.expectEqual(@as(usize, 6), items.len);
    try t.expectEqualStrings("New session: default", items[0].label);
    try t.expectEqualStrings(legacy_label, items[5].label);
    try t.expect(items[5].separator_before and items[5].action.ai_profile.index == legacy_index);
    try t.expectEqualStrings("New session: multi-repo", items[1].label);
    // The worktree row names the default profile (multi-repo, index 1).
    try t.expectEqualStrings(worktree_label, items[2].label);
    try t.expect(items[2].action.ai_profile.worktree and items[2].action.ai_profile.index == 1 and !items[2].action.ai_profile.set_default);
    try t.expectEqualStrings("Default: default", items[3].label);
    try t.expect(items[3].separator_before and !items[3].checked);
    try t.expectEqualStrings("Default: multi-repo", items[4].label);
    try t.expect(items[4].checked);
    try t.expect(items[1].action.ai_profile.index == 1 and !items[1].action.ai_profile.set_default and !items[1].action.ai_profile.worktree);
    try t.expect(items[4].action.ai_profile.set_default);

    // Codex has one profile: two rows per lane as well.
    const cx = try menuItems(&app, t.allocator, .codex);
    defer {
        for (cx) |it| t.allocator.free(it.label);
        t.allocator.free(cx);
    }
    try t.expectEqual(@as(usize, 6), cx.len);
    try t.expectEqualStrings("New session: fast", cx[1].label);
    // Codex's default is the built-in: its worktree row says index 0.
    try t.expectEqualStrings(worktree_label, cx[2].label);
    try t.expect(cx[2].action.ai_profile.worktree and cx[2].action.ai_profile.index == 0);
}

test "the legacy launcher-script row ends the chip menu and opens the profile picker with the migration note" {
    var cfg: Config = .{};
    cfg.ai.launch_profiles = &two_profiles;
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    const items = try menuItems(&app, t.allocator, .claude);
    defer {
        for (items) |it| t.allocator.free(it.label);
        t.allocator.free(items);
    }
    try t.expectEqual(@as(usize, 6), items.len);
    try t.expectEqualStrings(legacy_label, items[5].label);
    try t.expect(items[5].separator_before);
    try t.expectEqual(legacy_index, items[5].action.ai_profile.index);
    try menuAction(&app, items[5].action.ai_profile);
    try t.expect(app.overlay == .picker);
    try t.expectEqual(app_mod.PickerKind.custom, app.overlay.picker.kind);
    try t.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try t.expectEqualStrings(builtin_name, app.overlay.picker.labels[0]);
    try t.expectEqualStrings("multi-repo", app.overlay.picker.labels[1]);
    try t.expectEqualStrings("/opt/bin/claude-multi.sh --add-dir ../lib", app.overlay.picker.details[1]);
    try t.expect(app.overlay.picker.on_accept != null);
    try t.expectEqualStrings(legacy_note, app.lastToast().?);
}

test "setDefault persists to the home config and takes effect at once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var cfg: Config = .{};
    cfg.ai.launch_profiles = &two_profiles;
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = "/tmp", .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try setDefault(&app, .codex, "fast");
    try t.expectEqualStrings("fast", defaultName(&app, .codex));
    const path = try std.fs.path.join(t.allocator, &.{ root, "config.zon" });
    defer t.allocator.free(path);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".codex = \"fast\"") != null);
    try t.expectError(error.Failed, setDefault(&app, .codex, "nope"));
    try setDefault(&app, .codex, builtin_name);
    try t.expectEqualStrings(builtin_name, defaultName(&app, .codex));
}

test "an untrusted workspace config's launch profile is stripped: its binary is never the chip's, and the name does not launch" {
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data =
        \\.{ .ai = .{
        \\    .launch_profiles = .{ .{ .name = "evil", .product = .claude, .binary = "/tmp/evil.sh", .worktree = true } },
        \\    .default_profile = .{ .claude = "evil" },
        \\} }
    });
    const config_load = @import("../config/load.zig");
    var loaded = try config_load.load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars }, .trust = .untrusted });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    loaded = undefined;
    defer app.deinit();
    try t.expectEqual(@as(usize, 0), app.cfg.ai.launch_profiles.len);
    // `.worktree = true` is part of the profile: stripped with it, so an
    // untrusted file cannot make a session open in a worktree either.
    try t.expect(find(&app, .claude, "evil") == null);
    try t.expectEqualStrings(builtin_name, defaultName(&app, .claude));
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try t.expectError(error.Failed, launch(&app, arena_state.allocator(), .claude, "evil"));
    const plain = try launch(&app, arena_state.allocator(), .claude, defaultName(&app, .claude));
    try t.expectEqualStrings(binaryOf(.claude), plain.argv[0]);
    // The same file, trusted, does apply.
    var trusted = try config_load.load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars }, .trust = .trusted });
    var app2 = try App.initWith(t.allocator, t.io, .{ .cfg = trusted.config, .loaded = trusted, .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    trusted = undefined;
    defer app2.deinit();
    try t.expectEqualStrings("evil", defaultName(&app2, .claude));
    try t.expect(find(&app2, .claude, "evil").?.worktree);
}
