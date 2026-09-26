//! The integration odds and ends that are not the section itself
//! (`integrations.zig`): the mounts re-scan, the settings door, the
//! per-integration diagnosis picker, and the PATH-shadow audit. Each
//! reads the same scan the section shows — a mount manifest is an
//! integration manifest whose commands open the binary.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const integrations = @import("integrations.zig");
const settings = @import("settings.zig");
const cmd_picker = @import("cmd_picker.zig");

pub const table = .{
    .@"mounts.refresh" = &mountsRefresh,
    .@"integrations.configure_picker" = &configurePicker,
    .@"integrations.diag" = &diag,
    .@"integrations.audit_shadowed_binaries" = &auditShadowed,
};

/// Whether one of the manifest's commands opens its binary (a
/// `.mount` runner) — what makes it a mount manifest.
fn isMount(app: *App, inst: *const integrations.Installed) bool {
    for (inst.slots) |slot| if (app.dyn_commands.at(slot)) |dc| if (dc.runner == .mount) return true;
    return false;
}

/// `mounts.refresh`: the integrations re-scan, reported as mounts.
fn mountsRefresh(app: *App) CommandError!void {
    try integrations.refresh(app);
    var n: usize = 0;
    for (app.integrations.list) |*inst| if (isMount(app, inst)) {
        n += 1;
    };
    app.toast("mounts: {d} manifest(s) loaded", .{n});
}

/// `integrations.configure_picker`: the settings overlay on its
/// Integrations section, where the installed manifests' `settings[]`
/// rows live.
fn configurePicker(app: *App) CommandError!void {
    if (!app.integrations.scanned) try integrations.refresh(app);
    const refs = try integrations.settingRefs(app, app.frame.allocator());
    if (refs.len == 0) return app.diag.fail(app.frame.allocator(), "No installed integration declares settings yet.", .{});
    try settings.openAt(app, .integrations);
}

// ─── diag ────────────────────────────────────────────────────────────────

/// The installed integrations with a binary, in list order.
fn withBinary(app: *App, arena: Allocator) Allocator.Error![]usize {
    var out: std.ArrayListUnmanaged(usize) = .empty;
    for (app.integrations.list, 0..) |*inst, i| if (inst.manifest.binary.len > 0) try out.append(arena, i);
    return out.items;
}

/// `integrations.diag`: pick an installed integration with a binary
/// (one → no picker) — its detail pane opens and the toast says whether
/// the binary resolves.
fn diag(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (!app.integrations.scanned) try integrations.refresh(app);
    const idx = try withBinary(app, arena);
    if (idx.len == 0) return app.diag.fail(arena, "No installed integration has a binary to diagnose.", .{});
    if (idx.len == 1) return diagOne(app, idx[0]);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (idx) |i| {
        const inst = &app.integrations.list[i];
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}", .{ inst.manifest.label, inst.id() }));
        const found = integrations.resolveBinary(app, arena, inst.manifest.binary);
        try details.append(gpa, if (found) |p| try std.fmt.allocPrint(gpa, "{s} · found: {s}", .{ inst.manifest.binary, p }) else try std.fmt.allocPrint(gpa, "{s} · missing", .{inst.manifest.binary}));
    }
    try cmd_picker.openPickerWith(app, "Run diagnostics on", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptDiag;
}

/// The picker's row `i` is the i-th integration with a binary.
fn acceptDiag(app: *App, i: usize, _: []const u8) Allocator.Error!void {
    const idx = try withBinary(app, app.frame.allocator());
    if (i >= idx.len) return;
    diagOne(app, idx[i]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

fn diagOne(app: *App, i: usize) CommandError!void {
    const arena = app.frame.allocator();
    if (i >= app.integrations.list.len) return;
    const inst = &app.integrations.list[i];
    const id = try arena.dupe(u8, inst.id());
    const found = integrations.resolveBinary(app, arena, inst.manifest.binary) != null;
    try integrations.openDetail(app, .{ .installed = id });
    app.toast("diag: {s} · binary {s}", .{ id, if (found) "found" else "missing" });
}

// ─── the PATH-shadow audit ───────────────────────────────────────────────

/// The first PATH directory holding a file named `name`, as a path.
fn firstOnPath(app: *App, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    const path_var = app.env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(arena, &.{ dir, name });
        Io.Dir.cwd().access(app.io, full, .{}) catch continue;
        return full;
    }
    return null;
}

/// Whether two paths name the same file, links followed.
fn sameFile(app: *App, arena: Allocator, a: []const u8, b: []const u8) bool {
    const ra = Io.Dir.cwd().realPathFileAlloc(app.io, a, arena) catch return std.mem.eql(u8, a, b);
    const rb = Io.Dir.cwd().realPathFileAlloc(app.io, b, arena) catch return std.mem.eql(u8, a, b);
    return std.mem.eql(u8, ra, rb);
}

/// One shadow: `name` on PATH is not the file mnml runs.
pub const Shadow = struct { name: []const u8, on_path: []const u8, ours: []const u8 };

/// Every installed integration whose binary is a bare name and whose
/// first PATH hit is a different file from the one `resolveBinary`
/// picks (`<data root>/bin/<name>` first). On the arena.
pub fn shadows(app: *App, arena: Allocator) Allocator.Error![]Shadow {
    var out: std.ArrayListUnmanaged(Shadow) = .empty;
    for (app.integrations.list) |*inst| {
        const name = inst.manifest.binary;
        if (name.len == 0 or name[0] == '$' or std.mem.indexOfScalar(u8, name, '/') != null or std.fs.path.isAbsolute(name)) continue;
        const ours = integrations.resolveBinary(app, arena, name) orelse continue;
        const on_path = (try firstOnPath(app, arena, name)) orelse continue;
        if (sameFile(app, arena, on_path, ours)) continue;
        try out.append(arena, .{ .name = name, .on_path = on_path, .ours = ours });
    }
    return out.items;
}

/// `integrations.audit_shadowed_binaries`: report only — a scratch
/// buffer names each shadow and what to do about it.
fn auditShadowed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (!app.integrations.scanned) try integrations.refresh(app);
    const hits = try shadows(app, arena);
    if (hits.len == 0) {
        app.toast("no shadowed integration binaries", .{});
        return;
    }
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    w.print("# {d} shadowed integration binar{s}\n\n", .{ hits.len, if (hits.len == 1) "y" else "ies" }) catch return error.OutOfMemory;
    for (hits) |h| w.print("{s}: PATH resolves {s} · mnml uses {s}\n", .{ h.name, h.on_path, h.ours }) catch return error.OutOfMemory;
    w.writeAll("\nmnml runs the second path; a shell runs the first. To make them agree, remove or rename the PATH copy, or put the directory mnml links into (<data root>/bin) earlier on PATH.\n") catch return error.OutOfMemory;
    _ = app.openScratchWith(text.written()) catch return error.OutOfMemory;
    app.toast("{d} shadowed integration binar{s} — see the scratch buffer", .{ hits.len, if (hits.len == 1) "y" else "ies" });
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

const manifest_with_binary =
    \\.{
    \\    .id = "hello",
    \\    .label = "Hello",
    \\    .description = "The sample",
    \\    .version = "0.1.0",
    \\    .binary = "/definitely/not/here/mnml-hello",
    \\    .commands = .{ .{ .id = "hello.open", .title = "Hello: open" } },
    \\    .settings = .{ .{ .key = "greeting", .label = "Greeting", .options = .{ "HELLO", "HOWDY" }, .default = "HELLO" } },
    \\}
    \\
;

const manifest_named_binary =
    \\.{
    \\    .id = "named",
    \\    .label = "Named",
    \\    .description = "A bare binary name",
    \\    .version = "0.1.0",
    \\    .binary = "mnml-named",
    \\    .commands = .{ .{ .id = "named.open", .title = "Named: open" } },
    \\}
    \\
;

const launcher_manifest =
    \\.{
    \\    .id = "lnch",
    \\    .label = "Launcher",
    \\    .description = "No binary",
    \\    .commands = .{ .{ .id = "lnch.go", .title = "Launcher: go", .run = ":term true" } },
    \\}
    \\
;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    app: App,

    fn init(manifests: []const struct { name: []const u8, text: []const u8 }) !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try t.allocator.dupe(u8, pbuf[0..try tmp.dir.realPath(t.io, &pbuf)]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "integrations");
        try tmp.dir.createDirPath(t.io, "ws");
        for (manifests) |m| {
            const rel = try std.fmt.allocPrint(t.allocator, "integrations/{s}.zon", .{m.name});
            defer t.allocator.free(rel);
            try tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = m.text });
        }
        const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
        defer t.allocator.free(ws);
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        try app.env.put("PATH", "/definitely/not/a/dir");
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }
};

test "mounts.refresh re-scans and counts the manifests whose commands open a binary" {
    var f = try Fixture.init(&.{ .{ .name = "hello", .text = manifest_with_binary }, .{ .name = "lnch", .text = launcher_manifest } });
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"mounts.refresh" });
    try t.expectEqual(@as(usize, 2), f.app.integrations.list.len);
    try t.expectEqualStrings("mounts: 1 manifest(s) loaded", f.app.lastToast().?);
}

test "configure_picker opens Settings on the Integrations section, or fails when no manifest declares a setting" {
    var f = try Fixture.init(&.{.{ .name = "hello", .text = manifest_with_binary }});
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"integrations.configure_picker" });
    try t.expect(f.app.overlay == .settings);
    const list = try settings.items(&f.app, f.app.frame.allocator());
    const cur = f.app.overlay.settings.ui.cursor;
    try t.expect(list[cur - 1] == .section);
    try t.expectEqualStrings("Integrations", list[cur - 1].section);
    // The manifest's own row is in that section.
    var k = cur;
    var seen = false;
    while (k < list.len and list[k] != .section) : (k += 1) if (list[k] == .row and std.mem.eql(u8, list[k].row.label, "Hello: Greeting")) {
        seen = true;
    };
    try t.expect(seen);
    var g = try Fixture.init(&.{.{ .name = "lnch", .text = launcher_manifest }});
    defer g.deinit();
    try t.expectError(error.Failed, command.run(&g.app, .{ .static = .@"integrations.configure_picker" }));
    try t.expectEqualStrings("No installed integration declares settings yet.", g.app.diag.msg.?);
    try t.expect(g.app.overlay != .settings);
}

test "diag: one integration with a binary skips the picker; two offer one with found/missing details; none fails" {
    var f = try Fixture.init(&.{ .{ .name = "hello", .text = manifest_with_binary }, .{ .name = "lnch", .text = launcher_manifest } });
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"integrations.diag" });
    try t.expect(f.app.overlay != .picker);
    try t.expect(f.app.panes.findKind(.integrations) != null);
    try t.expectEqualStrings("diag: hello · binary missing", f.app.lastToast().?);
    // A second one with a binary that resolves through <data root>/bin.
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/mnml-named", .data = "#!/bin/sh\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/named.zon", .data = manifest_named_binary });
    try integrations.refresh(&f.app);
    try command.run(&f.app, .{ .static = .@"integrations.diag" });
    try t.expect(f.app.overlay == .picker);
    try t.expectEqual(@as(usize, 2), f.app.overlay.picker.labels.len);
    try t.expectEqualStrings("Hello  hello", f.app.overlay.picker.labels[0]);
    try t.expect(std.mem.endsWith(u8, f.app.overlay.picker.details[0], "· missing"));
    try t.expect(std.mem.indexOf(u8, f.app.overlay.picker.details[1], "found: ") != null);
    try t.expect(sdk_testing.pathEndsWith(f.app.overlay.picker.details[1], "/bin/mnml-named"));
    // Down + Enter picks the second: its detail pane, its toast.
    try f.app.handle(.{ .key = app_mod.Key.named(.down) });
    try f.app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(f.app.overlay != .picker);
    try t.expectEqualStrings("diag: named · binary found", f.app.lastToast().?);
    const detail = f.app.panes.get(f.app.panes.findKind(.integrations).?).?;
    try t.expectEqualStrings("named", detail.integrations.target.installed);
    var g = try Fixture.init(&.{.{ .name = "lnch", .text = launcher_manifest }});
    defer g.deinit();
    try t.expectError(error.Failed, command.run(&g.app, .{ .static = .@"integrations.diag" }));
    try t.expectEqualStrings("No installed integration has a binary to diagnose.", g.app.diag.msg.?);
}

test "audit_shadowed_binaries: a PATH copy that is not the linked binary is reported in a scratch; none is a toast" {
    var f = try Fixture.init(&.{.{ .name = "named", .text = manifest_named_binary }});
    defer f.deinit();
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/mnml-named", .data = "#!/bin/sh\n" });
    try f.tmp.dir.createDirPath(t.io, "shadow");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "shadow/mnml-named", .data = "#!/bin/sh\nexit 1\n" });
    const shadow_dir = try std.fs.path.join(t.allocator, &.{ f.root, "shadow" });
    defer t.allocator.free(shadow_dir);
    // PATH without the shadow: nothing to report.
    try command.run(&f.app, .{ .static = .@"integrations.audit_shadowed_binaries" });
    try t.expectEqualStrings("no shadowed integration binaries", f.app.lastToast().?);
    try t.expectEqual(@as(usize, 0), f.app.panes.count());
    // The shadow first on PATH.
    try f.app.env.put("PATH", shadow_dir);
    try command.run(&f.app, .{ .static = .@"integrations.audit_shadowed_binaries" });
    try t.expectEqualStrings("1 shadowed integration binary — see the scratch buffer", f.app.lastToast().?);
    const e = f.app.activeEditor().?;
    const text = e.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, text, "mnml-named: PATH resolves ") != null);
    try t.expect(sdk_testing.pathContains(text, "/shadow/mnml-named · mnml uses "));
    try t.expect(std.mem.indexOf(u8, text, "/bin/mnml-named\n") != null);
    // The same file through a link is not a shadow.
    const link_dir = try std.fs.path.join(t.allocator, &.{ f.root, "linked" });
    defer t.allocator.free(link_dir);
    try f.tmp.dir.createDirPath(t.io, "linked");
    const ours = try std.fs.path.join(t.allocator, &.{ f.root, "bin", "mnml-named" });
    defer t.allocator.free(ours);
    try f.tmp.dir.symLink(t.io, ours, "linked/mnml-named", .{});
    try f.app.env.put("PATH", link_dir);
    try t.expectEqual(@as(usize, 0), (try shadows(&f.app, f.app.frame.allocator())).len);
}
