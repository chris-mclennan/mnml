//! Installed integrations: the manifests under
//! `<data root>/integrations/*.zon` and `<workspace>/.mnml/integrations/*.zon`,
//! scanned at startup and on `integrations.refresh`. Each manifest
//! command becomes a `DynCommand` owned by the integration — one that
//! opens the binary as a `Pane.mount` (or a pty when `mode = .pty`), or
//! runs the manifest's `ex` line — and each `chip` becomes a button on
//! the palette bar. `Pane.integrations` lists them; the settings
//! overlay grows a row per manifest `settings[]` entry, stored in
//! `<data root>/integration-settings.zon` and handed to the binary as
//! `MNML_SETTING_<KEY>`.
//!
//! The filesystem is the interface: install is a file appearing,
//! uninstall is deleting it, enable / disable rewrites `chip.enabled`.

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
const launch_profiles = @import("launch_profiles.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const Manifest = manifest_mod.Manifest;
const mount_pane = @import("mount_pane.zig");
const pty_pane = @import("pty_pane.zig");
const cmd_picker = @import("cmd_picker.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/integrations_view.zig");
const config = @import("../config/root.zig");

pub const settings_file = "integration-settings.zon";

pub const Source = enum { home, workspace };

/// One manifest as scanned. Everything borrows the snapshot arena.
pub const Installed = struct {
    manifest: Manifest,
    path: []const u8,
    source: Source,
    /// The binary resolves (absolute, or on PATH).
    binary_found: bool,
    /// The dyn slots its commands took, in manifest order.
    slots: []u32,

    pub fn enabled(self: *const Installed) bool {
        return if (self.manifest.chip) |c| c.enabled else true;
    }

    pub fn id(self: *const Installed) []const u8 {
        return self.manifest.id;
    }
};

/// A palette-bar chip: an installed integration's, or a config icon.
pub const Chip = struct {
    id: []const u8,
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8,
    tooltip: []const u8,
    enabled: bool,
    /// What a click runs.
    action: union(enum) { dyn: u32, named: []const u8, none },
    /// The row in `State.list`, for the context menu.
    installed: ?usize,
};

pub const State = struct {
    snapshot: alloc.SnapshotArena,
    list: []Installed = &.{},
    /// `<id>.<key>` → value, gpa-owned both sides.
    settings: std.StringHashMapUnmanaged([]u8) = .empty,
    /// The row a context menu was opened on.
    menu_row: ?usize = null,
    scanned: bool = false,
    /// The last scan's problems, one line each (snapshot arena).
    problems: [][]const u8 = &.{},
    generation: u32 = 0,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = .init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        var it = self.settings.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.settings.deinit(gpa);
        self.snapshot.deinit();
    }

    pub fn find(self: *const State, id: []const u8) ?usize {
        for (self.list, 0..) |*i, idx| if (std.mem.eql(u8, i.id(), id)) return idx;
        return null;
    }
};

/// `Pane.integrations`: the installed list.
pub const IntegrationsPane = struct {
    cursor: usize = 0,
    scroll: usize = 0,
    /// The detail block for the selected row is open.
    detail: bool = false,
    sort: Sort = .name,

    pub const Sort = enum { name, category };
};

pub const table = .{
    .@"integrations.refresh" = &refreshCmd,
    .@"integrations.refresh_binary_cache" = &refreshCmd,
    .@"integrations.show_installed" = &showInstalled,
    .@"integrations.show_details" = &showDetails,
    .@"integrations.show_manifest" = &showManifest,
    .@"integrations.edit" = &editCmd,
    .@"integrations.toggle_enabled" = &toggleEnabled,
    .@"integrations.remove" = &removeCmd,
    .@"integrations.copy_id" = &copyId,
    .@"integrations.cycle_sort" = &cycleSort,
    .@"integrations.toggle_tab" = &toggleTab,
    .@"integrations.show_in_dev" = &noDevTab,
    .@"integrations.toggle_dev_tab" = &noDevTab,
};

// ─── discovery ──────────────────────────────────────────────────────────

/// The `.startup` hook: the first scan.
pub fn onStartup(app: *App, _: @import("../core/hooks.zig").HookArgs) void {
    refresh(app) catch {};
}

/// Where manifests live, in precedence order (workspace after home so
/// a workspace manifest with the same id wins).
fn dirs(app: *App, arena: Allocator) Allocator.Error![2]?[]const u8 {
    const home: ?[]const u8 = if (app.data_root.len > 0) try std.fs.path.join(arena, &.{ app.data_root, manifest_mod.subdir }) else null;
    const ws = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", manifest_mod.subdir });
    return .{ home, ws };
}

/// Re-scan: drop every integration command and binding, read the
/// manifests again, register what they declare.
pub fn refresh(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    const gpa = app.gpa;
    // Old bindings go before the arena they point into.
    for (st.list) |*inst| for (inst.manifest.commands) |c| for (c.keys) |k| app.keymap.unbind(k);
    _ = app.dyn_commands.unregisterOwner(.integration);
    st.snapshot.reset();
    const arena = st.snapshot.allocator();
    st.list = &.{};
    st.problems = &.{};
    st.generation +%= 1;

    var found: std.ArrayListUnmanaged(Installed) = .empty;
    var problems: std.ArrayListUnmanaged([]const u8) = .empty;
    const roots = try dirs(app, arena);
    for (roots, 0..) |maybe, i| {
        const dir_path = maybe orelse continue;
        const source: Source = if (i == 0) .home else .workspace;
        // A workspace's manifests spawn binaries: they wait for trust
        // (`config/trust.zig`, the `workspace_manifests` sink). Quiet,
        // like every other stripped sink — the RESTRICTED chip says so.
        if (source == .workspace and !app.workspace_trusted) continue;
        try scanDir(app, arena, dir_path, source, &found, &problems);
    }
    std.mem.sort(Installed, found.items, {}, byLabel);
    st.list = try found.toOwnedSlice(arena);
    st.problems = try problems.toOwnedSlice(arena);
    st.scanned = true;

    // Register the commands now that the list is final.
    for (st.list) |*inst| try registerCommands(app, arena, inst);
    try app.keymap.rebuildPrefixes();
    for (st.problems) |p| try app.toastLevel(.warn, "integrations: {s}", .{p});
    app.needs_render = true;
    _ = gpa;
}

fn byLabel(_: void, a: Installed, b: Installed) bool {
    return std.ascii.lessThanIgnoreCase(a.manifest.label, b.manifest.label);
}

fn scanDir(app: *App, arena: Allocator, dir_path: []const u8, source: Source, found: *std.ArrayListUnmanaged(Installed), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const io = app.io;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        const text = dir.readFileAllocOptions(io, entry.name, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, @errorName(err) }));
            continue;
        };
        var why: []const u8 = "";
        const m = manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadManifest => {
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ app.relPath(path), why }));
                continue;
            },
        };
        // A workspace manifest replaces a home one with the same id.
        var replaced = false;
        for (found.items) |*prev| if (std.mem.eql(u8, prev.id(), m.id)) {
            prev.* = .{ .manifest = m, .path = path, .source = source, .binary_found = binaryFound(app, arena, m.binary), .slots = &.{} };
            replaced = true;
        };
        if (replaced) continue;
        try found.append(arena, .{ .manifest = m, .path = path, .source = source, .binary_found = binaryFound(app, arena, m.binary), .slots = &.{} });
    }
}

/// Absolute → exists; bare → somewhere on PATH.
pub fn binaryFound(app: *App, arena: Allocator, binary: []const u8) bool {
    return resolveBinary(app, arena, binary) != null;
}

/// Where a manifest's binary is: itself when absolute, else
/// `<data root>/bin/<name>` (what the marketplace links), else the
/// first PATH hit. Null when nowhere.
pub fn resolveBinary(app: *App, arena: Allocator, binary: []const u8) ?[]const u8 {
    const io = app.io;
    if (std.fs.path.isAbsolute(binary) or std.mem.indexOfScalar(u8, binary, '/') != null) {
        Io.Dir.cwd().access(io, binary, .{}) catch return null;
        return binary;
    }
    if (app.data_root.len > 0) {
        const linked = std.fs.path.join(arena, &.{ app.data_root, "bin", binary }) catch return null;
        if (Io.Dir.cwd().access(io, linked, .{})) |_| return linked else |_| {}
    }
    const path_var = app.env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(arena, &.{ dir, binary }) catch return null;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return full;
    }
    return null;
}

fn registerCommands(app: *App, arena: Allocator, inst: *Installed) Allocator.Error!void {
    const m = inst.manifest;
    const slots = try arena.alloc(u32, m.commands.len);
    var n: usize = 0;
    for (m.commands) |c| {
        const args = try std.mem.concat(arena, []const u8, &.{ m.args, c.args });
        const runner: command.DynInit.Runner = if (c.ex) |line|
            .{ .ex = line }
        else
            .{ .mount = .{ .binary = m.binary, .args = args, .pty = m.mode == .pty, .label = m.label } };
        const slot = app.dyn_commands.register(.{
            .id = c.id,
            .title = c.title,
            .group = c.group,
            .keys = c.keys,
            .runner = runner,
            .owner = .{ .integration = m.id },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ShadowsBuiltin => {
                try app.toastLevel(.warn, "integrations: {s}: {s} shadows a built-in command", .{ m.id, c.id });
                continue;
            },
        };
        slots[n] = slot;
        n += 1;
        for (c.keys) |k| try app.keymap.bind(k, c.id);
    }
    inst.slots = slots[0..n];
}

fn refreshCmd(app: *App) CommandError!void {
    try refresh(app);
    app.toast("integrations: {d} installed", .{app.integrations.list.len});
}

// ─── running ────────────────────────────────────────────────────────────

/// What `runMount` opens. Borrowed for the call.
pub const Run = struct {
    /// The manifest id (its settings reach the child), or empty.
    id: []const u8 = "",
    binary: []const u8,
    args: []const []const u8 = &.{},
    pty: bool = false,
    label: []const u8,
};

/// A manifest command's runner: the binary as a mount (or a pty).
pub fn runMount(app: *App, r: Run) CommandError!void {
    const arena = app.frame.allocator();
    const id = r.id;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, resolveBinary(app, arena, r.binary) orelse r.binary);
    for (r.args) |a| try argv.append(arena, a);
    if (r.pty) {
        if (!pty_pane.supported) return app.diag.fail(arena, "{s}: a pty pane is not available on this platform", .{r.label});
        _ = try pty_pane.open(app, .{ .argv = argv.items, .label = r.label, .placement = .tab, .kind = .command });
        return;
    }
    const extra = try settingsEnv(app, arena, id);
    _ = try mount_pane.open(app, .{ .argv = argv.items, .label = r.label, .integration = id, .extra_env = extra });
}

/// `MNML_SETTING_<KEY>` for every setting the manifest declares: the
/// stored choice, else the manifest's default.
fn settingsEnv(app: *App, arena: Allocator, id: []const u8) Allocator.Error![]mount_pane.EnvPair {
    const st = &app.integrations;
    const idx = st.find(id) orelse return &.{};
    const m = st.list[idx].manifest;
    var out: std.ArrayListUnmanaged(mount_pane.EnvPair) = .empty;
    for (m.settings) |s| {
        const value = settingValue(app, id, s);
        const name = try std.fmt.allocPrint(arena, "MNML_SETTING_{s}", .{s.key});
        for (name["MNML_SETTING_".len..]) |*c| c.* = std.ascii.toUpper(c.*);
        try out.append(arena, .{ .name = name, .value = value });
    }
    return out.toOwnedSlice(arena);
}

/// Run the integration's first command (what the chip and Enter do).
fn openRow(app: *App, idx: usize) CommandError!void {
    const st = &app.integrations;
    if (idx >= st.list.len) return;
    const inst = &st.list[idx];
    if (inst.slots.len == 0) {
        // No manifest command: open the binary itself.
        return runMount(app, .{ .id = inst.id(), .binary = inst.manifest.binary, .args = inst.manifest.args, .pty = inst.manifest.mode == .pty, .label = inst.manifest.label });
    }
    return command.run(app, .{ .dyn = inst.slots[0] });
}

// ─── chips ──────────────────────────────────────────────────────────────

/// The palette-bar chips: config icons and installed manifests with a
/// chip, in `ui.integration_icon_order` first, then by label.
pub fn chips(app: *App, arena: Allocator) Allocator.Error![]Chip {
    var out: std.ArrayListUnmanaged(Chip) = .empty;
    for (app.cfg.ui.integration_icons) |icon| {
        if (!icon.in_palette_bar or icon.id.len == 0) continue;
        try out.append(arena, .{
            .id = icon.id,
            .glyph = icon.glyph,
            .fallback = icon.fallback,
            .color = icon.color,
            .tooltip = icon.label orelse icon.id,
            .enabled = icon.enabled,
            .action = if (icon.command.len > 0) .{ .named = icon.command } else .none,
            .installed = null,
        });
    }
    for (app.integrations.list, 0..) |*inst, i| {
        const c = inst.manifest.chip orelse continue;
        if (!c.in_palette_bar) continue;
        try out.append(arena, .{
            .id = inst.id(),
            .glyph = c.glyph,
            .fallback = c.fallback,
            .color = c.color,
            .tooltip = if (c.tooltip.len > 0) c.tooltip else inst.manifest.label,
            .enabled = c.enabled and inst.binary_found,
            .action = if (inst.slots.len > 0) .{ .dyn = inst.slots[0] } else .none,
            .installed = i,
        });
    }
    const icon_order = app.cfg.ui.integration_icon_order;
    const Ctx = struct {
        order: []const []const u8,
        fn rank(self: @This(), id: []const u8) usize {
            for (self.order, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
            return self.order.len;
        }
        fn less(self: @This(), a: Chip, b: Chip) bool {
            const ra = self.rank(a.id);
            const rb = self.rank(b.id);
            if (ra != rb) return ra < rb;
            return std.ascii.lessThanIgnoreCase(a.id, b.id);
        }
    };
    std.mem.sort(Chip, out.items, Ctx{ .order = icon_order }, Ctx.less);
    return out.toOwnedSlice(arena);
}

/// A press on chip `idx` of the strip as `chips` ordered it.
pub fn chipClick(app: *App, idx: usize, m: Mouse) Allocator.Error!void {
    const list = try chips(app, app.frame.allocator());
    if (idx >= list.len) return;
    const chip = list[idx];
    if (m.button == .right) {
        if (chip.installed) |row| return openRowMenu(app, row, m.x, m.y);
        // The AI chips: their launch profiles.
        if (std.mem.eql(u8, chip.id, "claude_code")) return launch_profiles.openChipMenu(app, .claude, m.x, m.y);
        if (std.mem.eql(u8, chip.id, "codex")) return launch_profiles.openChipMenu(app, .codex, m.x, m.y);
        return;
    }
    if (!chip.enabled) {
        app.toast("{s} is disabled — right-click to enable", .{chip.tooltip});
        return;
    }
    switch (chip.action) {
        .dyn => |slot| command.run(app, .{ .dyn = slot }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .named => |id| command.runNamed(app, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .none => app.toast("{s}: nothing to run", .{chip.tooltip}),
    }
}

// ─── the pane ───────────────────────────────────────────────────────────

fn showInstalled(app: *App) CommandError!void {
    if (!app.integrations.scanned) try refresh(app);
    if (app.panes.findKind(.integrations)) |id| {
        app.showPane(id);
        return;
    }
    const id = try app.panes.add(.{ .integrations = .{} });
    app.showPane(id);
}

fn activePane(app: *App) ?struct { id: PaneId, p: *IntegrationsPane } {
    const id = app.active orelse return null;
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .integrations => |*p| .{ .id = id, .p = p },
        else => null,
    };
}

/// The row a command acts on: the menu's, else the pane's cursor, else
/// null (a picker is opened).
fn focusedRow(app: *App) ?usize {
    const st = &app.integrations;
    if (st.menu_row) |r| {
        st.menu_row = null;
        if (r < st.list.len) return r;
    }
    if (activePane(app)) |ap| if (app.focus == .pane and ap.p.cursor < st.list.len) return ap.p.cursor;
    return null;
}

/// The picker over installed integrations for `kind`.
fn pickRow(app: *App, kind: app_mod.PickerKind, title: []const u8) CommandError!void {
    const st = &app.integrations;
    if (!st.scanned) try refresh(app);
    if (st.list.len == 0) return app.diag.fail(app.frame.allocator(), "no integrations installed", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (st.list) |*inst| try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}", .{ inst.manifest.label, inst.id() }));
    const owned = try labels.toOwnedSlice(gpa);
    errdefer {
        for (owned) |l| gpa.free(l);
        gpa.free(owned);
    }
    try cmd_picker.openPicker(app, title, kind, owned, &.{});
}

/// A picker row chosen: `i` is the installed index.
pub fn acceptPicker(app: *App, kind: app_mod.PickerKind, i: usize) Allocator.Error!void {
    const result: CommandError!void = switch (kind) {
        .integrations_details => detailsAt(app, i),
        .integrations_manifest => manifestAt(app, i),
        .integrations_toggle => toggleAt(app, i),
        .integrations_remove => removeAt(app, i),
        .integrations_copy_id => copyIdAt(app, i),
        else => {},
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("integrations: {s}", .{@errorName(err)}),
    };
}

fn showDetails(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return detailsAt(app, r);
    return pickRow(app, .integrations_details, "Integration details");
}

fn detailsAt(app: *App, i: usize) CommandError!void {
    try showInstalled(app);
    const ap = activePane(app) orelse return;
    ap.p.cursor = i;
    ap.p.detail = true;
}

fn showManifest(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return manifestAt(app, r);
    return pickRow(app, .integrations_manifest, "Open manifest");
}

fn editCmd(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return manifestAt(app, r);
    return pickRow(app, .integrations_manifest, "Edit integration (its manifest)");
}

fn manifestAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    const path = try app.frame.allocator().dupe(u8, st.list[i].path);
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "cannot open {s}: {s}", .{ path, @errorName(err) }),
    };
}

fn toggleEnabled(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return toggleAt(app, r);
    return pickRow(app, .integrations_toggle, "Enable / disable integration");
}

/// Flip `chip.enabled` and write the manifest back.
fn toggleAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    var m = inst.manifest;
    var chip: manifest_mod.Chip = m.chip orelse .{};
    chip.enabled = !chip.enabled;
    m.chip = chip;
    const text = try manifest_mod.render(app.gpa, m);
    defer app.gpa.free(text);
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = inst.path, .data = text }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "cannot write {s}: {s}", .{ app.relPath(inst.path), @errorName(err) });
    };
    const id = try app.frame.allocator().dupe(u8, inst.id());
    const now_enabled = chip.enabled;
    try refresh(app);
    app.toast("{s}: {s}", .{ id, if (now_enabled) "enabled" else "disabled" });
}

fn removeCmd(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return removeAt(app, r);
    return pickRow(app, .integrations_remove, "Remove integration");
}

/// Ask first; `removeAccept` deletes the manifest.
fn removeAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    const msg = try std.fmt.allocPrint(app.gpa, "  Remove {s}? Its manifest {s} is deleted; the binary stays.", .{ inst.manifest.label, app.relPath(inst.path) });
    errdefer app.gpa.free(msg);
    const id = try app.gpa.dupe(u8, inst.id());
    errdefer app.gpa.free(id);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Remove integration", .message = msg, .choices = &remove_choices },
        .purpose = .{ .remove_integration = id },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const remove_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'r', .label = "Remove" }, .{ .key = 'c', .label = "Cancel" } };

pub fn removeAccept(app: *App, id: []const u8) Allocator.Error!void {
    const st = &app.integrations;
    const i = st.find(id) orelse return;
    const path = try app.frame.allocator().dupe(u8, st.list[i].path);
    Io.Dir.cwd().deleteFile(app.io, path) catch |err| {
        app.toast("cannot delete {s}: {s}", .{ app.relPath(path), @errorName(err) });
        return;
    };
    try refresh(app);
    app.toast("removed {s}", .{id});
}

fn copyId(app: *App) CommandError!void {
    if (focusedRow(app)) |r| return copyIdAt(app, r);
    return pickRow(app, .integrations_copy_id, "Copy integration id");
}

fn copyIdAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    try app.clipboard.set(st.list[i].id(), false);
    app.toast("copied {s}", .{st.list[i].id()});
}

fn cycleSort(app: *App) CommandError!void {
    const ap = activePane(app) orelse return app.diag.fail(app.frame.allocator(), "integrations: no list pane is active", .{});
    ap.p.sort = if (ap.p.sort == .name) .category else .name;
    app.toast("integrations: sorted by {s}", .{@tagName(ap.p.sort)});
}

fn toggleTab(app: *App) CommandError!void {
    if (activePane(app) != null) return command.run(app, .{ .static = .@"integrations.show_marketplace" });
    return showInstalled(app);
}

fn noDevTab(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "integrations: the In-Development tab is not in this build", .{});
}

/// The rows in the pane's order (`sort`), as indices into `list`.
pub fn order(app: *App, arena: Allocator, p: *const IntegrationsPane) Allocator.Error![]usize {
    const st = &app.integrations;
    const out = try arena.alloc(usize, st.list.len);
    for (out, 0..) |*o, i| o.* = i;
    if (p.sort == .category) {
        const Ctx = struct {
            list: []Installed,
            fn less(self: @This(), a: usize, b: usize) bool {
                const ca = self.list[a].manifest.category;
                const cb = self.list[b].manifest.category;
                const c = std.ascii.orderIgnoreCase(ca, cb);
                if (c != .eq) return c == .lt;
                return std.ascii.lessThanIgnoreCase(self.list[a].manifest.label, self.list[b].manifest.label);
            }
        };
        std.mem.sort(usize, out, Ctx{ .list = st.list }, Ctx.less);
    }
    return out;
}

pub fn handleKey(app: *App, id: PaneId, p: *IntegrationsPane, k: Key) Allocator.Error!bool {
    const st = &app.integrations;
    const n = st.list.len;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, n -| 1),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = n -| 1,
        .enter => runToast(app, openRow(app, p.cursor)),
        .esc => try app.forceClosePane(id),
        .char => |c| switch (c) {
            'j' => p.cursor = @min(p.cursor + 1, n -| 1),
            'k' => p.cursor -|= 1,
            'g' => p.cursor = 0,
            'G' => p.cursor = n -| 1,
            'q' => try app.forceClosePane(id),
            'd' => p.detail = !p.detail,
            'r' => runToast(app, refreshCmd(app)),
            'e' => runToast(app, toggleAt(app, p.cursor)),
            'm' => runToast(app, manifestAt(app, p.cursor)),
            'y' => runToast(app, copyIdAt(app, p.cursor)),
            'x' => runToast(app, removeAt(app, p.cursor)),
            's' => runToast(app, cycleSort(app)),
            'M' => runToast(app, command.run(app, .{ .static = .@"integrations.show_marketplace" })),
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
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("integrations: {s}", .{@errorName(err)}),
    };
}

/// A press on row `hit` (an index into `order`): left selects, twice
/// opens; right opens the menu.
pub fn click(app: *App, id: PaneId, p: *IntegrationsPane, hit: u32, m: Mouse) Allocator.Error!void {
    _ = id;
    const rows = try order(app, app.frame.allocator(), p);
    if (hit >= rows.len) return;
    const row = rows[hit];
    if (m.button == .right) {
        app.integrations.menu_row = row;
        return openRowMenu(app, row, m.x, m.y);
    }
    if (p.cursor == row) {
        runToast(app, openRow(app, row));
    } else p.cursor = row;
}

pub fn scrollBy(app: *App, p: *IntegrationsPane, delta: i64) void {
    const n = app.integrations.list.len;
    const cur: i64 = @intCast(p.cursor);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(n -| 1))));
}

fn openRowMenu(app: *App, row: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    if (row >= st.list.len) return;
    st.menu_row = row;
    const enabled = st.list[row].enabled();
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Details", .action = .{ .command = .@"integrations.show_details" } },
        .{ .label = if (enabled) "Disable" else "Enable", .action = .{ .command = .@"integrations.toggle_enabled" } },
        .{ .label = "Open manifest", .action = .{ .command = .@"integrations.show_manifest" } },
        .{ .label = "Copy id", .action = .{ .command = .@"integrations.copy_id" } },
        .{ .label = "Remove…", .action = .{ .command = .@"integrations.remove" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu(st.list[row].manifest.label, items, x, y);
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *IntegrationsPane, rect: Rect) Allocator.Error!void {
    const focused = app.active == id and app.focus == .pane;
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const rows = try order(app, ui.arena, p);
    const st = &app.integrations;
    const list = try ui.arena.alloc(view.Row, rows.len);
    for (rows, 0..) |r, i| {
        const inst = &st.list[r];
        const sel = r == p.cursor;
        list[i] = .{
            .glyph = if (inst.manifest.chip) |c| c.glyph else "",
            .fallback = if (inst.manifest.chip) |c| c.fallback else "",
            .color = if (inst.manifest.chip) |c| c.color else "",
            .label = inst.manifest.label,
            .id = inst.id(),
            .version = inst.manifest.version,
            .category = inst.manifest.category,
            .enabled = inst.enabled(),
            .binary_found = inst.binary_found,
            .selected = sel,
            .detail = if (sel and p.detail) .{
                .description = inst.manifest.description,
                .binary = inst.manifest.binary,
                .mode = @tagName(inst.manifest.mode),
                .path = app.relPath(inst.path),
                .commands = inst.manifest.commands,
                .settings = inst.manifest.settings,
                .requires = inst.manifest.requires,
            } else null,
        };
    }
    view.draw(ui, id, rect, .{ .rows = list, .scroll = &p.scroll, .focused = focused, .problems = st.problems, .sort = @tagName(p.sort) });
}

// ─── settings ───────────────────────────────────────────────────────────

/// A stored `<id>.<key>` value, else the manifest default, else the
/// first option.
pub fn settingValue(app: *App, id: []const u8, s: manifest_mod.Setting) []const u8 {
    var kbuf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ id, s.key }) catch return s.default;
    if (app.integrations.settings.get(key)) |v| return v;
    if (s.default.len > 0) return s.default;
    return if (s.options.len > 0) s.options[0] else "";
}

/// One settings row per manifest setting, flattened across the list.
pub const SettingRef = struct { installed: usize, setting: usize };

pub fn settingRefs(app: *App, arena: Allocator) Allocator.Error![]SettingRef {
    var out: std.ArrayListUnmanaged(SettingRef) = .empty;
    for (app.integrations.list, 0..) |*inst, i| for (inst.manifest.settings, 0..) |_, k| try out.append(arena, .{ .installed = i, .setting = k });
    return out.toOwnedSlice(arena);
}

pub fn settingIndex(app: *App, ref: SettingRef) usize {
    const inst = &app.integrations.list[ref.installed];
    const s = inst.manifest.settings[ref.setting];
    const v = settingValue(app, inst.id(), s);
    for (s.options, 0..) |o, i| if (std.mem.eql(u8, o, v)) return i;
    return 0;
}

pub fn settingDefaultIndex(app: *App, ref: SettingRef) usize {
    const s = app.integrations.list[ref.installed].manifest.settings[ref.setting];
    for (s.options, 0..) |o, i| if (std.mem.eql(u8, o, s.default)) return i;
    return 0;
}

/// Set a manifest setting to its `idx`th option and write the file.
pub fn setSetting(app: *App, ref: SettingRef, idx: usize) Allocator.Error!void {
    const gpa = app.gpa;
    const inst = &app.integrations.list[ref.installed];
    const s = inst.manifest.settings[ref.setting];
    if (s.options.len == 0) return;
    const value = s.options[idx % s.options.len];
    const key = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ inst.id(), s.key });
    errdefer gpa.free(key);
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    if (app.integrations.settings.fetchRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value);
    }
    try app.integrations.settings.put(gpa, key, copy);
    try writeSettings(app);
}

const StoredSetting = struct { key: []const u8, value: []const u8 };

fn settingsPath(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (app.data_root.len == 0) return null;
    return try std.fs.path.join(arena, &.{ app.data_root, settings_file });
}

fn writeSettings(app: *App) Allocator.Error!void {
    const arena = app.frame.allocator();
    const path = (try settingsPath(app, arena)) orelse {
        app.toast("nowhere to save integration settings (no data root)", .{});
        return;
    };
    var rows: std.ArrayListUnmanaged(StoredSetting) = .empty;
    var it = app.integrations.settings.iterator();
    while (it.next()) |e| try rows.append(arena, .{ .key = e.key_ptr.*, .value = e.value_ptr.* });
    std.mem.sort(StoredSetting, rows.items, {}, struct {
        fn less(_: void, a: StoredSetting, b: StoredSetting) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);
    var out: Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// Integration settings, one per `<integration>.<key>`; the settings overlay writes this.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(rows.items, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(path).?) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() }) catch |err| {
        app.toast("could not write {s}: {s}", .{ path, @errorName(err) });
    };
}

/// Read `<data root>/integration-settings.zon` into `settings`.
pub fn loadSettings(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const path = (try settingsPath(app, arena)) orelse return;
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(1 << 20), .of(u8), 0) catch return;
    const rows = std.zon.parse.fromSliceAlloc([]StoredSetting, arena, text, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            try app.toastLevel(.warn, "integration settings: {s} did not parse", .{path});
            return;
        },
    };
    for (rows) |r| {
        const key = try gpa.dupe(u8, r.key);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, r.value);
        errdefer gpa.free(value);
        if (app.integrations.settings.fetchRemove(key)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
        try app.integrations.settings.put(gpa, key, value);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const fixture_manifest =
    \\.{
    \\    .id = "hello",
    \\    .label = "Hello",
    \\    .description = "The sample",
    \\    .version = "0.1.0",
    \\    .binary = "/definitely/not/here/mnml-hello",
    \\    .category = "sample",
    \\    .chip = .{ .glyph = "H", .fallback = "H", .color = "cyan", .tooltip = "Hello" },
    \\    .commands = .{
    \\        .{ .id = "hello.open", .title = "Hello: open", .keys = .{ "ctrl+k h" } },
    \\        .{ .id = "hello.shell", .title = "Hello: shell", .ex = "term true" },
    \\    },
    \\    .settings = .{ .{ .key = "greeting", .label = "Greeting", .options = .{ "HELLO", "HOWDY" }, .default = "HELLO" } },
    \\}
    \\
;

fn testApp(tmp: *testing.TmpDir) !App {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/hello.zon", .data = fixture_manifest });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/broken.zon", .data = ".{ .id = " });
    try tmp.dir.createDirPath(testing.io, "ws");
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    return App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 20 });
}

test "discovery: manifests become dyn commands with bindings; a broken file is a warning; refresh is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    const st = &app.integrations;
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expectEqualStrings("hello", st.list[0].id());
    try testing.expect(!st.list[0].binary_found);
    try testing.expectEqual(@as(usize, 2), st.list[0].slots.len);
    try testing.expectEqual(@as(usize, 1), st.problems.len);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "broken.zon") != null);
    // The commands resolve by name and the key binds.
    const ref = command.resolve(&app, "hello.open").?;
    try testing.expect(ref == .dyn);
    const dc = app.dyn_commands.at(ref.dyn).?;
    try testing.expect(dc.runner == .mount);
    try testing.expectEqualStrings("/definitely/not/here/mnml-hello", dc.runner.mount.binary);
    try testing.expect(dc.owner == .integration);
    var kbuf: [@import("../core/keymap.zig").max_seq]key_mod.Chord = undefined;
    const seq = @import("../core/keymap.zig").parseKeySeqBuf("ctrl+k h", &kbuf).?;
    try testing.expect(app.keymap.resolveSeq(seq) != .none);
    // The ex-backed command reaches the interpreter.
    try testing.expect(command.resolve(&app, "hello.shell").?.dyn != ref.dyn);
    // Running the mount command with a missing binary fails with a diag, not a pane.
    try testing.expectError(error.Failed, command.run(&app, ref));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "cannot run") != null);
    try testing.expectEqual(@as(usize, 0), app.panes.count());
    // A second scan does not double-register or leak the old bindings.
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expect(command.resolve(&app, "hello.open") != null);
    try testing.expect(app.keymap.resolveSeq(seq) != .none);
    // Chips: the config's browser icon plus the manifest's, with the order honored.
    const c = try chips(&app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("browser", c[0].id);
    try testing.expectEqualStrings("hello", c[1].id);
    try testing.expect(!c[1].enabled); // the binary is missing
}

test "toggle_enabled rewrites the manifest and the list follows; remove deletes it after a confirm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    try testing.expect(app.integrations.list[0].enabled());
    try toggleAt(&app, 0);
    try testing.expect(!app.integrations.list[0].enabled());
    const text = try tmp.dir.readFileAlloc(testing.io, "integrations/hello.zon", testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".enabled = false") != null);
    try toggleAt(&app, 0);
    try testing.expect(app.integrations.list[0].enabled());
    // Remove: the confirm box, then the file goes.
    try removeAt(&app, 0);
    try testing.expect(app.overlay == .confirm);
    try testing.expect(app.overlay.confirm.purpose == .remove_integration);
    try removeAccept(&app, "hello");
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "integrations/hello.zon", .{}));
    try testing.expect(command.resolve(&app, "hello.open") == null);
}

test "settings: a manifest setting reads its default, persists a choice, and reaches the child's env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    const refs = try settingRefs(&app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqual(@as(usize, 0), settingIndex(&app, refs[0]));
    try setSetting(&app, refs[0], 1);
    try testing.expectEqual(@as(usize, 1), settingIndex(&app, refs[0]));
    const env = try settingsEnv(&app, app.frame.allocator(), "hello");
    try testing.expectEqualStrings("MNML_SETTING_GREETING", env[0].name);
    try testing.expectEqualStrings("HOWDY", env[0].value);
    // A fresh app reads the file back.
    var app2 = try App.initWith(testing.allocator, testing.io, .{ .workspace = app.workspace, .data_root = app.data_root, .cols = 80, .rows = 10 });
    defer app2.deinit();
    try refresh(&app2);
    try testing.expectEqual(@as(usize, 1), settingIndex(&app2, refs[0]));
}

test "the pane lists what is installed and its keys act on the cursor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    try testing.expect(app.panes.findKind(.integrations) != null);
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "INTEGRATIONS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "binary missing") != null);
    // `d` opens the detail block; `y` copies the id.
    const id = app.panes.findKind(.integrations).?;
    const p = &app.panes.get(id).?.integrations;
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'd' } }));
    try app.render();
    const txt2 = try @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "hello.open") != null);
    try testing.expect(std.mem.indexOf(u8, txt2, "ctrl+k h") != null);
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'y' } }));
    try testing.expectEqualStrings("hello", app.clipboard.text());
}

test "a workspace manifest waits for trust: skipped while the workspace is untrusted, registered once it is trusted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws/.mnml/integrations");
    const ws_manifest = std.mem.replaceOwned(u8, testing.allocator, fixture_manifest, "hello", "wsonly") catch unreachable;
    defer testing.allocator.free(ws_manifest);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.mnml/integrations/wsonly.zon", .data = ws_manifest });
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .cols = 100, .rows = 20, .workspace_trusted = false });
    defer app.deinit();
    try refresh(&app);
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expect(command.resolve(&app, "wsonly.open") == null);
    // The trust decision lands: the scan takes the manifest.
    app.workspace_trusted = true;
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expectEqualStrings("wsonly", app.integrations.list[0].id());
    try testing.expect(command.resolve(&app, "wsonly.open") != null);
    // The claim the dialog lists: one per file.
    const facts_names = try @import("../config/trust.zig").manifestNames(app.frame.allocator(), app.io, ws);
    try testing.expectEqual(@as(usize, 1), facts_names.len);
    try testing.expectEqualStrings("wsonly.zon", facts_names[0]);
}
