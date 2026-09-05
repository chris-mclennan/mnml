//! `Pane.mount`: an integration hosted over a mount socket (E5). The
//! pane owns a `bridge.host.Mount` (socket + child + reader task) and a
//! UI-side copy of the sibling's grid; `handle` answers the reader's
//! events, the key / mouse / paste entry points turn what the user did
//! into `HostMessage.input`, and `draw` keeps the sibling's geometry and
//! focus in step with the rect the layout hands the pane.
//!
//! The sibling owns its keys the way a pty does: a modified chord the
//! keymap binds goes to the chord chain; everything else is forwarded.
//! Once the sibling is gone (`bye`, EOF, a spawn failure) the pane shows
//! the banner and any key closes it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const Chord = key_mod.Chord;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const host = @import("../bridge/host.zig");
const wire = @import("../bridge/wire.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/mount_view.zig");
const pty_pane = @import("pty_pane.zig");
const build_options = @import("build_options");

pub const supported = host.supported;

pub const MountPane = struct {
    gpa: Allocator,
    mount: ?*host.Mount,
    /// The tab label until the sibling sets a title. Owned.
    label: []u8,
    /// The sibling's title. Owned.
    title_buf: ?[]u8 = null,
    /// The manifest id that opened it, if any. Owned.
    integration: ?[]u8 = null,
    /// The UI's copy of the sibling's screen.
    grid: host.Grid = .{},
    cursor: ?wire.Cursor = null,
    /// Why the sibling is gone; the banner text. Owned.
    exit: ?[]u8 = null,
    /// A frame has landed.
    painted: bool = false,
    /// The geometry the sibling last heard.
    cols: u16 = 0,
    rows: u16 = 0,
    focus_sent: ?bool = null,
    generation: u32,

    pub fn deinit(self: *MountPane, gpa: Allocator) void {
        if (self.mount) |m| {
            m.close();
            m.destroy();
        }
        self.grid.deinit(gpa);
        gpa.free(self.label);
        if (self.title_buf) |t| gpa.free(t);
        if (self.integration) |i| gpa.free(i);
        if (self.exit) |e| gpa.free(e);
    }

    pub fn title(self: *const MountPane) []const u8 {
        return self.title_buf orelse self.label;
    }

    pub fn alive(self: *const MountPane) bool {
        return self.exit == null and self.mount != null;
    }

    fn send(self: *MountPane, msg: wire.HostMessage) void {
        const m = self.mount orelse return;
        if (!m.connected) return;
        m.send(msg) catch {};
    }

    fn setExit(self: *MountPane, reason: []const u8) Allocator.Error!void {
        if (self.exit != null) return;
        self.exit = try std.fmt.allocPrint(self.gpa, "[{s}] — any key closes", .{reason});
    }
};

pub const OpenOptions = struct {
    argv: []const []const u8,
    /// The tab label; argv[0]'s basename when null.
    label: ?[]const u8 = null,
    /// The manifest that opened it.
    integration: ?[]const u8 = null,
    /// Absolute; the workspace when null.
    cwd: ?[]const u8 = null,
    /// `MNML_SETTING_<KEY>` and friends.
    extra_env: []const EnvPair = &.{},
};

pub const EnvPair = struct { name: []const u8, value: []const u8 };

var next_id: u32 = 0;

/// Where the file-IPC channel is for this app: `MNML_IPC_DIR`, else
/// `<workspace>/.mnml/<ipc_subdir>`. On the frame arena.
pub fn ipcDir(app: *App) Allocator.Error![]const u8 {
    if (app.env.get("MNML_IPC_DIR")) |d| if (d.len > 0) return d;
    return std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".mnml", build_options.ipc_subdir });
}

/// Spawn `argv` as a mount and show it as a tab.
pub fn open(app: *App, opts: OpenOptions) CommandError!PaneId {
    if (!supported) return app.diag.fail(app.frame.allocator(), "mount: no Unix sockets on this platform", .{});
    if (opts.argv.len == 0) return app.diag.fail(app.frame.allocator(), "mount: nothing to run", .{});
    const gpa = app.gpa;
    const label = try gpa.dupe(u8, opts.label orelse std.fs.path.basename(opts.argv[0]));
    errdefer gpa.free(label);
    const integration: ?[]u8 = if (opts.integration) |i| try gpa.dupe(u8, i) else null;
    errdefer if (integration) |i| gpa.free(i);

    next_id += 1;
    const id = app.panes.peekId();
    const ipc_dir = try ipcDir(app);
    const sock = try host.socketPath(gpa, ipc_dir, next_id);
    defer gpa.free(sock);
    var env = try host.envFor(gpa, &app.env, .{ .socket_path = sock, .workspace = app.workspace, .theme = app.theme.name, .ipc_dir = ipc_dir });
    defer env.deinit();
    for (opts.extra_env) |pair| try env.put(pair.name, pair.value);

    const mount = host.Mount.spawn(gpa, app.io, &app.events, .{
        .argv = opts.argv,
        .cwd = opts.cwd orelse app.workspace,
        .env = &env,
        .socket_path = sock,
        .pane = id,
        .generation = next_id,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot run {s}", .{opts.argv[0]}),
        error.BindFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot bind {s}", .{sock}),
        error.ListenFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot start the reader", .{}),
        error.Unsupported => return app.diag.fail(app.frame.allocator(), "mount: no Unix sockets on this platform", .{}),
    };
    errdefer {
        mount.close();
        mount.destroy();
    }
    const got = try app.panes.add(.{ .mount = .{
        .gpa = gpa,
        .mount = mount,
        .label = label,
        .integration = integration,
        .generation = next_id,
    } });
    std.debug.assert(got == id);
    app.showPane(id);
    app.needs_render = true;
    return id;
}

/// `mount.open`: the binary (and args) typed into a prompt.
fn openCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Mount integration (binary and args)"), .purpose = .mount_open } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptPrompt(app: *App, text: []const u8) CommandError!void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| try argv.append(app.frame.allocator(), tok);
    if (argv.items.len == 0) return app.diag.fail(app.frame.allocator(), "mount: nothing to run", .{});
    _ = try open(app, .{ .argv = argv.items });
}

pub const table = .{
    .@"mount.open" = &openCmd,
};

// ─── events ─────────────────────────────────────────────────────────────

fn paneOf(app: *App, ev: *const host.Event) ?*MountPane {
    const p = app.panes.get(ev.pane) orelse return null;
    const mp = p.asMount() orelse return null;
    if (mp.generation != ev.generation) return null;
    return mp;
}

/// What the reader posted. The event is destroyed here on every path.
pub fn handle(app: *App, ev: *host.Event) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const p = paneOf(app, ev) orelse return;
    const gpa = app.gpa;
    switch (ev.kind) {
        .connected => {
            const m = p.mount orelse return;
            m.onConnected();
            const geometry = currentGeometry(app, ev.pane, p);
            p.cols = geometry.cols;
            p.rows = geometry.rows;
            p.send(.{ .hello = .{
                .geometry = geometry,
                .theme = app.theme.name,
                .workspace = app.workspace,
                .capabilities = .{ .rgb = true, .nerd_font = !app.cfg.ui.ascii_icons, .ascii = app.cfg.ui.ascii_icons },
            } });
            m.greeted = true;
            const focused = app.active == ev.pane and app.focus == .pane;
            p.send(.{ .focus = focused });
            p.focus_sent = focused;
        },
        .frame => {
            const m = p.mount orelse return;
            try m.takeGrid(gpa, &p.grid);
            p.painted = true;
        },
        .title => |t| {
            const copy = try gpa.dupe(u8, t);
            if (p.title_buf) |old| gpa.free(old);
            p.title_buf = copy;
        },
        .cursor => |c| p.cursor = c,
        .command => |id| {
            command.runNamed(app, id) catch {};
        },
        .toast => |t| try app.toastLevel(switch (t.level) {
            .info => .info,
            .warn => .warn,
            .@"error" => .err,
        }, "{s}: {s}", .{ p.title(), t.text }),
        .bye => try p.setExit("exited"),
        .closed => |reason| try p.setExit(reason),
    }
    app.needs_render = true;
}

/// The pane's body size as the last frame laid it out — or the app's
/// pane size before the first frame.
fn currentGeometry(app: *App, id: PaneId, p: *MountPane) wire.Geometry {
    if (p.cols > 0 and p.rows > 0) return .{ .cols = p.cols, .rows = p.rows };
    _ = id;
    return .{ .cols = @intCast(@max(app.pane_cols, 1)), .rows = @intCast(@max(app.pane_rows, 1)) };
}

// ─── input ──────────────────────────────────────────────────────────────

/// Keys: chords the app binds go to the chain; the rest to the sibling.
/// After exit, any key closes the pane. Returns true when handled.
pub fn handleKey(app: *App, id: PaneId, p: *MountPane, k: Key) Allocator.Error!bool {
    if (app.chord.len > 0) return false;
    const modified = k.mods.ctrl or k.mods.alt or k.mods.super;
    if (!p.alive()) {
        if (modified) return false;
        try app.forceClosePane(id);
        return true;
    }
    if (modified and !pty_pane.childOwned(k)) {
        if (app.keymap.resolveSeq(&.{Chord.of(k)}) != .none) return false;
    }
    const spec = try std.fmt.allocPrint(app.frame.allocator(), "{f}", .{Chord.of(k)});
    p.send(.{ .input = .{ .event = .{ .key = .{ .spec = spec } } } });
    return true;
}

pub fn paste(app: *App, p: *MountPane, text: []const u8) void {
    _ = app;
    if (!p.alive()) return;
    p.send(.{ .input = .{ .event = .{ .paste = .{ .text = text } } } });
}

/// A press on row `row` of the pane; `rect` is the row's hit rect so
/// the column is pane-relative.
pub fn click(app: *App, id: PaneId, p: *MountPane, row: u32, m: Mouse, rect: ?Rect) Allocator.Error!void {
    if (!p.alive()) {
        try app.forceClosePane(id);
        return;
    }
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    const button: wire.Button = switch (m.button) {
        .left, .none => .left,
        .right => .right,
        .middle => .middle,
    };
    p.send(.{ .input = .{ .event = .{ .click = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))), .button = button } } } });
}

/// A wheel notch over the pane.
pub fn wheel(p: *MountPane, row: u32, m: Mouse, rect: ?Rect, count: u16) void {
    if (!p.alive()) return;
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    const n: i16 = @intCast(@min(@max(count, 1), 100));
    p.send(.{ .input = .{ .event = .{ .scroll = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))), .dy = if (m.kind == .scroll_up) n else -n } } } });
}

pub fn hover(p: *MountPane, row: u32, m: Mouse, rect: ?Rect) void {
    if (!p.alive()) return;
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    p.send(.{ .input = .{ .event = .{ .hover = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))) } } } });
}

// ─── frame ──────────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *MountPane, rect: Rect) Allocator.Error!void {
    const focused = app.active == id and app.focus == .pane;
    if (app.active == id) {
        app.pane_rows = @max(rect.h, 1);
        app.pane_cols = @max(rect.w, 1);
    }
    if (rect.w > 0 and rect.h > 0 and (rect.w != p.cols or rect.h != p.rows)) {
        p.cols = rect.w;
        p.rows = rect.h;
        if (p.mount) |m| if (m.greeted) p.send(.{ .resize = .{ .geometry = .{ .cols = rect.w, .rows = rect.h } } });
    }
    if (p.mount) |m| if (m.greeted and p.focus_sent != focused) {
        p.send(.{ .focus = focused });
        p.focus_sent = focused;
    };
    const cursor = view.draw(ui, id, rect, &p.grid, .{
        .focused = focused,
        .waiting = !p.painted,
        .exit_label = p.exit,
        .cursor = p.cursor,
    });
    if (focused) if (cursor) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Poll `tick` until `pred` holds or `ms` elapse.
fn waitFor(app: *App, ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        if (pred(ctx)) return;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOut;
}

fn screenText(app: *App) ![]u8 {
    try app.render();
    return @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
}

test "a mounted sample integration paints, answers keys and clicks, and leaves on q" {
    if (!supported) return error.SkipZigTest;
    const exe = build_options.sdk_example_exe;
    Io.Dir.cwd().access(testing.io, exe, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .cols = 100, .rows = 14, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    // The command the sample fires on Enter / a click on the selected row.
    _ = try app.dyn_commands.register(.{ .id = "hello.pick", .runner = .ipc, .owner = .ipc });

    const id = try open(&app, .{ .argv = &.{exe}, .label = "hello" });
    const p = app.panes.get(id).?.asMount().?;
    const Ctx = struct {
        fn painted(mp: *MountPane) bool {
            return mp.painted;
        }
        fn exited(mp: *MountPane) bool {
            return mp.exit != null;
        }
    };
    try waitFor(&app, 5000, p, Ctx.painted);
    var txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "HELLO") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "▸ Alpha") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Epsilon") != null);
    try testing.expectEqualStrings("hello", app.panes.get(id).?.title());

    // A key: the selection moves.
    try testing.expect(try handleKey(&app, id, p, .{ .code = .down }));
    const Poll = struct {
        app: *App,
        needle: []const u8,
        fn has(self: @This()) bool {
            self.app.render() catch return false;
            const t = @import("../ipc/screen.zig").toTestText(testing.allocator, &self.app.screen) catch return false;
            defer testing.allocator.free(t);
            return std.mem.indexOf(u8, t, self.needle) != null;
        }
    };
    try waitFor(&app, 5000, Poll{ .app = &app, .needle = "▸ Beta" }, Poll.has);

    // A click on the selected row fires the command; the count shows.
    // The sample paints its rows from `first_row`; the hit for that row
    // says where the pane put it on screen.
    const beta_row: u32 = 2 + 1;
    var rect: ?Rect = null;
    for (app.hits.items.items) |e| switch (e.target) {
        .script_hit => |sh| if (sh.pane == id and sh.id == beta_row) {
            rect = e.rect;
        },
        else => {},
    };
    try testing.expect(rect != null);
    try click(&app, id, p, beta_row, .{ .x = rect.?.x + 3, .y = rect.?.y, .kind = .press, .button = .left }, rect);
    const Picked = struct {
        fn has(a: *App) bool {
            return a.plugin_invocations.items.len > 0;
        }
    };
    try waitFor(&app, 5000, &app, Picked.has);
    try testing.expectEqualStrings("hello.pick", app.plugin_invocations.items[0]);
    try waitFor(&app, 5000, Poll{ .app = &app, .needle = "picks: 1" }, Poll.has);

    // q: bye → the banner; any key then closes the pane.
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'q' } }));
    try waitFor(&app, 5000, p, Ctx.exited);
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "[exited] — any key closes") != null);
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'x' } }));
    try testing.expect(app.panes.get(id) == null);
}

test "a binary that does not exist fails at open with a diag, not a pane" {
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    try testing.expectError(error.Failed, open(&app, .{ .argv = &.{"/nonexistent/mnml-nope"} }));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "cannot run") != null);
    try testing.expectEqual(@as(usize, 0), app.panes.count());
}
