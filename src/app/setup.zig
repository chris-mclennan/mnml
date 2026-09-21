//! The install-and-layout commands: `setup.install_to_path` links this
//! executable into a bin directory, `app.choose_data_layout` picks the
//! portable or the home data root behind a confirm box, and
//! `app.reset_to_defaults` renames the home config aside and restarts.
//! The two boxes route through `ConfirmPurpose` like every other one
//! (`dispatch.acceptConfirm`); the file work is in `applyLayout` /
//! `resetConfig` so a test can point them at a temp dir.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Confirm = app_mod.Confirm;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const data_root = @import("../config/data_root.zig");
const settings = @import("settings.zig");

pub const table = .{
    .@"setup.install_to_path" = &installToPath,
    .@"app.choose_data_layout" = &chooseDataLayout,
    .@"app.reset_to_defaults" = &resetToDefaults,
};

/// The name the link gets.
pub const link_name = "mnml-zig";

// ─── install to PATH ─────────────────────────────────────────────────────

fn realPathOr(app: *App, arena: Allocator, path: []const u8) []const u8 {
    return Io.Dir.cwd().realPathFileAlloc(app.io, path, arena) catch path;
}

/// Whether a `mnml-zig` or `mnml` on PATH is this very executable.
fn alreadyOnPath(app: *App, arena: Allocator, exe_real: []const u8) Allocator.Error!bool {
    const path_var = app.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for ([_][]const u8{ link_name, "mnml" }) |name| {
            const full = try std.fs.path.join(arena, &.{ dir, name });
            Io.Dir.cwd().access(app.io, full, .{}) catch continue;
            if (std.mem.eql(u8, realPathOr(app, arena, full), exe_real)) return true;
        }
    }
    return false;
}

fn dirOnPath(app: *App, dir: []const u8) bool {
    const path_var = app.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |d| if (std.mem.eql(u8, std.mem.trimEnd(u8, d, "/"), std.mem.trimEnd(u8, dir, "/"))) return true;
    return false;
}

/// `path` with `$HOME` as `~`, for a toast or a note.
pub fn tilde(app: *App, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const home = app.env.get("HOME") orelse return path;
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    return std.mem.concat(arena, u8, &.{ "~", path[home.len..] });
}

/// `<dir>/mnml-zig` → `exe`, replacing what was there. Any failure is
/// "not writable" to the caller.
fn linkInto(app: *App, arena: Allocator, dir: []const u8, exe: []const u8) ![]const u8 {
    try Io.Dir.cwd().createDirPath(app.io, dir);
    const link = try std.fs.path.join(arena, &.{ dir, link_name });
    Io.Dir.cwd().deleteFile(app.io, link) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try Io.Dir.cwd().symLink(app.io, exe, link, .{});
    return link;
}

/// `setup.install_to_path`: nothing when a `mnml-zig` / `mnml` on PATH
/// already is this executable; else a symlink in the first writable of
/// `~/.local/bin` (created) and `/usr/local/bin`; else the sudo line,
/// on the clipboard. Windows gets the PowerShell line that appends the
/// executable's directory to the user PATH.
fn installToPath(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const exe = std.process.executablePathAlloc(app.io, arena) catch |err| return app.diag.fail(arena, "cannot find this executable: {s}", .{@errorName(err)});
    const exe_real = realPathOr(app, arena, exe);
    if (try alreadyOnPath(app, arena, exe_real)) {
        app.toast("mnml-zig is already on PATH ✓", .{});
        return;
    }
    if (builtin.os.tag == .windows) {
        const dir = std.fs.path.dirname(exe) orelse exe;
        const line = try std.fmt.allocPrint(arena, "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';{s}', 'User')", .{dir});
        try app.clipboard.set(line, false);
        app.toast("run this in PowerShell to put mnml-zig on PATH (copied to the clipboard): {s}", .{line});
        return;
    }
    var candidates: [2]?[]const u8 = .{ null, "/usr/local/bin" };
    if (app.env.get("HOME")) |home| if (home.len > 0) {
        candidates[0] = try std.fs.path.join(arena, &.{ home, ".local", "bin" });
    };
    for (candidates) |maybe| {
        const dir = maybe orelse continue;
        const link = linkInto(app, arena, dir, exe_real) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const shown = try tilde(app, arena, link);
        if (dirOnPath(app, dir)) app.toast("linked {s} → {s}", .{ shown, exe_real }) else app.toast("linked {s} → {s} — add {s} to PATH", .{ shown, exe_real, try tilde(app, arena, dir) });
        return;
    }
    const cmd = try std.fmt.allocPrint(arena, "sudo ln -sf {s} /usr/local/bin/{s}", .{ exe_real, link_name });
    try app.clipboard.set(cmd, false);
    app.toast("no writable bin directory — run this (copied to the clipboard): {s}", .{cmd});
}

// ─── the data layout ─────────────────────────────────────────────────────

const layout_choices = [_]Confirm.Choice{ .{ .key = 'y', .label = "Yes" }, .{ .key = 'n', .label = "No" } };
const layout_message = "Portable = mnml-data/ next to the binary (self-contained);\nNormal = the home data root (~/.config/mnml).\nUse Portable?";

/// `app.choose_data_layout`: the box; Yes is portable, No is normal.
fn chooseDataLayout(app: *App) CommandError!void {
    const msg = try app.gpa.dupe(u8, layout_message);
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Data layout", .message = msg, .choices = &layout_choices },
        .purpose = .choose_data_layout,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The box's answer: Yes (0) or No (1); anything else is the cancel.
pub fn acceptDataLayout(app: *App, choice: usize) CommandError!void {
    if (choice > 1) return;
    const arena = app.frame.allocator();
    const exe_dir = std.process.executableDirPathAlloc(app.io, arena) catch |err| return app.diag.fail(arena, "cannot find this executable's directory: {s}", .{@errorName(err)});
    return applyLayout(app, exe_dir, choice == 0);
}

/// Portable: `<exe_dir>/mnml-data/` with its `.opted-in` marker. Normal:
/// the marker removed, the directory left alone. Nothing restarts.
pub fn applyLayout(app: *App, exe_dir: []const u8, portable: bool) CommandError!void {
    const arena = app.frame.allocator();
    const env: data_root.Env = .{ .vars = &app.env, .exe_dir = exe_dir };
    const candidate = (try data_root.portableCandidate(arena, env)) orelse return app.diag.fail(arena, "no binary directory to put mnml-data/ in", .{});
    const marker = try std.fs.path.join(arena, &.{ candidate, data_root.portable_opt_in });
    if (portable) {
        Io.Dir.cwd().createDirPath(app.io, candidate) catch |err| return app.diag.fail(arena, "could not create {s}: {s}", .{ candidate, @errorName(err) });
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = marker, .data = "" }) catch |err| return app.diag.fail(arena, "could not write {s}: {s}", .{ marker, @errorName(err) });
    } else {
        Io.Dir.cwd().deleteFile(app.io, marker) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return app.diag.fail(arena, "could not remove {s}: {s}", .{ marker, @errorName(err) }),
        };
    }
    app.toast("data layout: {s} — restart to apply", .{if (portable) "portable" else "normal"});
}

// ─── factory reset ───────────────────────────────────────────────────────

const reset_choices = [_]Confirm.Choice{ .{ .key = 'r', .label = "Reset" }, .{ .key = 'c', .label = "Cancel" } };
const reset_message = "Reset mnml to factory defaults?\nThe config file is renamed to a .bak, per-workspace state is untouched.";

fn resetToDefaults(app: *App) CommandError!void {
    const msg = try app.gpa.dupe(u8, reset_message);
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Reset to defaults", .message = msg, .choices = &reset_choices, .selected = 1 },
        .purpose = .reset_to_defaults,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Reset (0): the home config becomes `config.zon.bak-<unix seconds>`
/// (no file, nothing to rename) and the `app.restart` runner fires.
pub fn acceptReset(app: *App, choice: usize) CommandError!void {
    if (choice != 0) return;
    try resetConfig(app);
    return command.run(app, .{ .static = .@"app.restart" });
}

/// The rename alone; the toast names the backup.
pub fn resetConfig(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const path = (try settings.configPath(app, .home)) orelse return app.diag.fail(arena, "no home config (no $HOME, no data root)", .{});
    if (Io.Dir.cwd().access(app.io, path, .{})) |_| {
        const secs = @divTrunc(Io.Timestamp.now(app.io, .real).toMilliseconds(), 1000);
        const bak = try std.fmt.allocPrint(arena, "{s}.bak-{d}", .{ path, secs });
        Io.Dir.cwd().rename(path, .cwd(), bak, app.io) catch |err| return app.diag.fail(arena, "could not rename {s}: {s}", .{ path, @errorName(err) });
        app.toast("config backed up to {s} — restarting", .{bak});
    } else |_| {
        app.toast("no home config to back up — restarting on the defaults", .{});
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try t.allocator.dupe(u8, pbuf[0..try tmp.dir.realPath(t.io, &pbuf)]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "ws");
        try tmp.dir.createDirPath(t.io, "home");
        try tmp.dir.createDirPath(t.io, "empty");
        const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
        defer t.allocator.free(ws);
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn sub(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }
};

test "install_to_path links the executable into ~/.local/bin, says to add it to PATH, and is a no-op once it is there" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const home = try f.sub("home");
    defer t.allocator.free(home);
    const empty = try f.sub("empty");
    defer t.allocator.free(empty);
    try f.app.env.put("HOME", home);
    try f.app.env.put("PATH", empty);
    try command.run(&f.app, .{ .static = .@"setup.install_to_path" });
    const toast = f.app.lastToast().?;
    try t.expect(std.mem.startsWith(u8, toast, "linked "));
    try t.expect(std.mem.startsWith(u8, toast, "linked ~/.local/bin/mnml-zig → "));
    try t.expect(std.mem.endsWith(u8, toast, " — add ~/.local/bin to PATH"));
    // The link points at this very executable.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.readLink(t.io, "home/.local/bin/mnml-zig", &buf);
    const exe = try std.process.executablePathAlloc(t.io, t.allocator);
    defer t.allocator.free(exe);
    const exe_real = try Io.Dir.cwd().realPathFileAlloc(t.io, exe, t.allocator);
    defer t.allocator.free(exe_real);
    try t.expectEqualStrings(exe_real, buf[0..n]);
    // Again, still off PATH: relinked, same message.
    try command.run(&f.app, .{ .static = .@"setup.install_to_path" });
    try t.expect(std.mem.startsWith(u8, f.app.lastToast().?, "linked "));
    // With the bin dir on PATH the link resolves to us: nothing to do.
    const bin = try f.sub("home/.local/bin");
    defer t.allocator.free(bin);
    try f.app.env.put("PATH", bin);
    try command.run(&f.app, .{ .static = .@"setup.install_to_path" });
    try t.expectEqualStrings("mnml-zig is already on PATH ✓", f.app.lastToast().?);
}

test "choose_data_layout: the box, then Yes writes mnml-data/.opted-in beside the binary dir and No removes it" {
    var f = try Fixture.init();
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"app.choose_data_layout" });
    try t.expect(f.app.overlay == .confirm);
    try t.expect(f.app.overlay.confirm.purpose == .choose_data_layout);
    try t.expect(std.mem.indexOf(u8, f.app.overlay.confirm.state.message, "Use Portable?") != null);
    try t.expectEqualStrings("Yes", f.app.overlay.confirm.state.choices[0].label);
    // Esc: nothing written anywhere.
    try f.app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(f.app.overlay != .confirm);
    // The accept, pointed at a temp "binary dir".
    try f.tmp.dir.createDirPath(t.io, "bin");
    const bin = try f.sub("bin");
    defer t.allocator.free(bin);
    try applyLayout(&f.app, bin, true);
    try t.expectEqualStrings("data layout: portable — restart to apply", f.app.lastToast().?);
    try f.tmp.dir.access(t.io, "bin/mnml-data/.opted-in", .{});
    const env: data_root.Env = .{ .vars = &f.app.env, .exe_dir = bin };
    try t.expectEqual(data_root.PortableState.active, try data_root.portableState(t.allocator, t.io, env));
    try applyLayout(&f.app, bin, false);
    try t.expectEqualStrings("data layout: normal — restart to apply", f.app.lastToast().?);
    try t.expectError(error.FileNotFound, f.tmp.dir.access(t.io, "bin/mnml-data/.opted-in", .{}));
    try t.expectEqual(data_root.PortableState.awaiting_consent, try data_root.portableState(t.allocator, t.io, env));
    // Removing twice is fine.
    try applyLayout(&f.app, bin, false);
}

test "reset_to_defaults: the box, then Reset renames the home config to a .bak and asks for the restart" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "config.zon", .data = ".{ .ui = .{ .line_numbers = false } }\n" });
    try command.run(&f.app, .{ .static = .@"app.reset_to_defaults" });
    try t.expect(f.app.overlay == .confirm);
    try t.expect(f.app.overlay.confirm.purpose == .reset_to_defaults);
    try t.expect(std.mem.startsWith(u8, f.app.overlay.confirm.state.message, "Reset mnml to factory defaults?"));
    // Cancel is the default button; Esc keeps the file.
    try f.app.handle(.{ .key = app_mod.Key.named(.esc) });
    try f.tmp.dir.access(t.io, "config.zon", .{});
    try t.expect(!f.app.restart);
    // Reset.
    try command.run(&f.app, .{ .static = .@"app.reset_to_defaults" });
    try f.app.handle(.{ .key = app_mod.Key.char('r') });
    try t.expect(f.app.restart);
    try t.expect(f.app.quit);
    try t.expectError(error.FileNotFound, f.tmp.dir.access(t.io, "config.zon", .{}));
    var it = try f.tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer it.close(t.io);
    var walk = it.iterate();
    var bak: ?[]u8 = null;
    defer if (bak) |b| t.allocator.free(b);
    while (try walk.next(t.io)) |e| if (std.mem.startsWith(u8, e.name, "config.zon.bak-")) {
        bak = try t.allocator.dupe(u8, e.name);
    };
    try t.expect(bak != null);
    try t.expect(std.mem.indexOf(u8, f.app.lastToast().?, bak.?) != null);
    try t.expect(std.mem.endsWith(u8, f.app.lastToast().?, "— restarting"));
    const text = try f.tmp.dir.readFileAlloc(t.io, bak.?, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "line_numbers = false") != null);
    // No file at all: still restarts.
    f.app.restart = false;
    f.app.quit = false;
    try acceptReset(&f.app, 0);
    try t.expect(f.app.restart);
    try t.expect(std.mem.startsWith(u8, f.app.lastToast().?, "no home config to back up"));
}
