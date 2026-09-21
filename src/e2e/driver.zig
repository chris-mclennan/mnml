//! What the runner and the headless loop need from an application, and
//! nothing more. The App implements this vtable once it exists; until then
//! `Stub` records every call and returns a canned screen so the runner's
//! mechanics — step order, polling, timeouts, output — are testable on
//! their own.
//!
//! Every text argument is borrowed for the duration of the call.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const input = @import("../core/key.zig");
const ipc = @import("../ipc/root.zig");
const screen_mod = @import("../ipc/screen.zig");
const config = @import("../config/root.zig");

pub const Screen = screen_mod.Screen;

pub const Error = error{
    OutOfMemory,
    /// `command`: no such id.
    NoSuchCommand,
    /// `ghost` / `highlightCount`: the active pane is not an editor.
    NoActiveEditor,
    /// Anything else the App wants to surface; it toasts the reason.
    Failed,
};

/// How a driver is created: the runner makes one per `.test` file (and
/// per size), the headless loop one per process.
pub const Config = struct {
    workspace: []const u8,
    /// The isolated `MNML_DATA_ROOT` this instance persists into.
    data_root: []const u8,
    cols: u16,
    rows: u16,
    /// The merged config the App starts on. The runner never loads a
    /// file: every `.test` runs on `e2e_defaults`.
    cfg: config.Config = e2e_defaults,
    /// What the App's children inherit; the process's own when null.
    /// The runner adds `MNML_FAKE_DAP` for the `dap_session_*` scripts.
    env: ?*const std.process.Environ.Map = null,
    /// The loader's result when `cfg` came from files (the headless
    /// loop). Ownership passes to `Factory.create`, success or failure.
    loaded: ?config.Loaded = null,
    /// Run the terminal loop's `startup` hook once the App is built —
    /// the session restore, the startup tasks. The headless loop sets
    /// it (its screen must be the terminal's); the `.test` runner leaves
    /// it off, a test starts on a fresh workspace.
    startup_hook: bool = false,
};

/// What a `.test` file runs on: the shipped defaults with the breadcrumb
/// off, so row 0 is the bufferline in every expectation — the contract
/// mnml 0.2's runner set and the corpus was written against.
pub const e2e_defaults: config.Config = blk: {
    var c: config.Config = .{};
    c.editor.breadcrumb = false;
    break :blk c;
};

pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Open a file by absolute path in an editor pane and focus it.
        open: *const fn (*anyopaque, path: []const u8) Error!void,
        key: *const fn (*anyopaque, k: input.Key) Error!void,
        mouse: *const fn (*anyopaque, m: input.Mouse) Error!void,
        /// Run a registered command by id.
        command: *const fn (*anyopaque, id: []const u8) Error!void,
        /// Run an ex command line (`bd!`).
        ex: *const fn (*anyopaque, line: []const u8) Error!void,
        snippet: *const fn (*anyopaque, scope: []const u8, trigger: []const u8, expansion: []const u8) Error!void,
        /// Seed a ghost-text suggestion on the active editor.
        ghost: *const fn (*anyopaque, text: []const u8) Error!void,
        /// Drain async work: timers, worker results, pty rings.
        tick: *const fn (*anyopaque) Error!void,
        /// Force an in-flight chord chain to time out now.
        expireChords: *const fn (*anyopaque) Error!void,
        /// The next wheel event starts a gesture of its own: a script's
        /// `scroll` step is one deliberate notch, never part of a spin,
        /// so it moves its plain lines whatever the clock says (Rust's
        /// runner sleeps 50 ms a step, under its accel floor).
        wheelNotch: *const fn (*anyopaque) void,
        /// Draw a frame into the screen.
        render: *const fn (*anyopaque) Error!void,
        /// Leave a picture of the screen under `name` for whoever reads
        /// the run afterwards (the `shot` step). A driver with no pixels
        /// does nothing and succeeds: a hunter's script asks for a shot
        /// where it cares, and must not fail on the driver that cannot
        /// take one.
        shot: *const fn (*anyopaque, name: []const u8) Error!void,
        /// The screen the last `render` drew into.
        screen: *const fn (*anyopaque) *const Screen,
        /// `status.json` fields; slices are allocated from the given allocator.
        status: *const fn (*anyopaque, Allocator) Error!screen_mod.Status,
        /// `rects.json` body.
        rectsJson: *const fn (*anyopaque, Allocator) Error![]u8,
        /// The active editor's dirty flag; null when the active pane is not an editor.
        dirty: *const fn (*anyopaque) ?bool,
        /// The active pane's title, or null when there is no active pane.
        paneTitle: *const fn (*anyopaque, Allocator) Error!?[]u8,
        /// Syntax spans across the active editor; null when it is not an editor.
        highlightCount: *const fn (*anyopaque) ?usize,
        /// Tier-2 IPC commands (toasts, progress, statusline, notify, pty,
        /// badges, register-command) that have no `.test` step.
        ipcCommand: *const fn (*anyopaque, cmd: *const ipc.Command) Error!void,
        /// Plugin-registered command ids invoked since the last call.
        pluginInvocations: *const fn (*anyopaque, Allocator) Error![]const []const u8,
        /// Set `quit`; the headless loop reads it back through `status`.
        requestQuit: *const fn (*anyopaque, restart: bool) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn open(d: Driver, path: []const u8) Error!void {
        return d.vtable.open(d.ptr, path);
    }
    pub fn key(d: Driver, k: input.Key) Error!void {
        return d.vtable.key(d.ptr, k);
    }
    pub fn mouse(d: Driver, m: input.Mouse) Error!void {
        return d.vtable.mouse(d.ptr, m);
    }
    pub fn command(d: Driver, id: []const u8) Error!void {
        return d.vtable.command(d.ptr, id);
    }
    pub fn ex(d: Driver, line: []const u8) Error!void {
        return d.vtable.ex(d.ptr, line);
    }
    pub fn snippet(d: Driver, scope: []const u8, trigger: []const u8, expansion: []const u8) Error!void {
        return d.vtable.snippet(d.ptr, scope, trigger, expansion);
    }
    pub fn ghost(d: Driver, text: []const u8) Error!void {
        return d.vtable.ghost(d.ptr, text);
    }
    pub fn tick(d: Driver) Error!void {
        return d.vtable.tick(d.ptr);
    }
    pub fn expireChords(d: Driver) Error!void {
        return d.vtable.expireChords(d.ptr);
    }
    pub fn wheelNotch(d: Driver) void {
        d.vtable.wheelNotch(d.ptr);
    }
    pub fn render(d: Driver) Error!void {
        return d.vtable.render(d.ptr);
    }
    pub fn shot(d: Driver, name: []const u8) Error!void {
        return d.vtable.shot(d.ptr, name);
    }
    pub fn screen(d: Driver) *const Screen {
        return d.vtable.screen(d.ptr);
    }
    pub fn status(d: Driver, a: Allocator) Error!screen_mod.Status {
        return d.vtable.status(d.ptr, a);
    }
    pub fn rectsJson(d: Driver, a: Allocator) Error![]u8 {
        return d.vtable.rectsJson(d.ptr, a);
    }
    pub fn dirty(d: Driver) ?bool {
        return d.vtable.dirty(d.ptr);
    }
    pub fn paneTitle(d: Driver, a: Allocator) Error!?[]u8 {
        return d.vtable.paneTitle(d.ptr, a);
    }
    pub fn highlightCount(d: Driver) ?usize {
        return d.vtable.highlightCount(d.ptr);
    }
    pub fn ipcCommand(d: Driver, cmd: *const ipc.Command) Error!void {
        return d.vtable.ipcCommand(d.ptr, cmd);
    }
    pub fn pluginInvocations(d: Driver, a: Allocator) Error![]const []const u8 {
        return d.vtable.pluginInvocations(d.ptr, a);
    }
    pub fn requestQuit(d: Driver, restart: bool) void {
        d.vtable.requestQuit(d.ptr, restart);
    }
    pub fn deinit(d: Driver) void {
        d.vtable.deinit(d.ptr);
    }

    /// Type literal text char by char; `\n` is Enter. The one place the
    /// `.test` `type` step, the IPC `type` command and the bridge agree.
    pub fn typeText(d: Driver, text: []const u8) Error!void {
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |c| {
            try d.key(if (c == '\n') input.Key.named(.enter) else input.Key.char(c));
        }
    }

    /// Press + release at one cell.
    pub fn click(d: Driver, x: u16, y: u16, button: input.MouseButton, mods: input.Mods) Error!void {
        try d.mouse(.{ .x = x, .y = y, .kind = .press, .button = button, .mods = mods });
        try d.mouse(.{ .x = x, .y = y, .kind = .release, .button = button, .mods = mods });
    }

    /// A left-button drag: press at the source, one drag event per cell
    /// along the way, release at the destination. Returns the step count.
    pub fn drag(d: Driver, from_x: u16, from_y: u16, to_x: u16, to_y: u16) Error!usize {
        try d.mouse(.{ .x = from_x, .y = from_y, .kind = .press, .button = .left });
        const dx = if (to_x > from_x) to_x - from_x else from_x - to_x;
        const dy = if (to_y > from_y) to_y - from_y else from_y - to_y;
        const steps: usize = @max(dx, dy);
        var s: usize = 1;
        while (s <= steps) : (s += 1) {
            const f: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const cx = lerpCell(from_x, to_x, f);
            const cy = lerpCell(from_y, to_y, f);
            try d.mouse(.{ .x = cx, .y = cy, .kind = .drag, .button = .left });
        }
        try d.mouse(.{ .x = to_x, .y = to_y, .kind = .release, .button = .left });
        return steps;
    }
};

fn lerpCell(from: u16, to: u16, f: f32) u16 {
    const a: f32 = @floatFromInt(from);
    const b: f32 = @floatFromInt(to);
    return @intFromFloat(@round(a + (b - a) * f));
}

/// Creates drivers. The runner calls `create` once per file and size.
pub const Factory = struct {
    ptr: *anyopaque,
    create: *const fn (*anyopaque, gpa: Allocator, io: Io, cfg: Config) anyerror!Driver,

    pub fn make(f: Factory, gpa: Allocator, io: Io, cfg: Config) anyerror!Driver {
        return f.create(f.ptr, gpa, io, cfg);
    }
};

// ─── the recording stub ─────────────────────────────────────────────────

/// A driver with no application behind it. Every call lands in `calls`
/// as one line (`key ctrl+s`, `open /ws/a.txt`, `render`, …); `render`
/// paints `text` — or `late_text` once `late_after` renders have
/// happened, so a test can watch the runner poll.
pub const Stub = struct {
    gpa: Allocator,
    screen: Screen,
    calls: std.ArrayList([]u8) = .empty,
    text: []const u8 = "",
    late_after: ?usize = null,
    late_text: []const u8 = "",
    renders: usize = 0,
    dirty_flag: ?bool = null,
    title: ?[]const u8 = null,
    highlights: ?usize = null,
    /// Ids `command` accepts; anything else is `NoSuchCommand`.
    known_commands: []const []const u8 = &.{},
    /// The id that makes this stub QUIT, as `app.quit` does in the real
    /// App. The runner stops stepping a quit app, and the only way to
    /// test that is a driver a script can actually quit.
    quit_command: ?[]const u8 = null,
    has_editor: bool = true,
    quit: bool = false,
    restart: bool = false,
    /// `status` reports these.
    status_focus: screen_mod.Focus = .pane,
    plugin_pending: []const []const u8 = &.{},
    ticks: usize = 0,
    /// Written on deinit, so a test can read counts after the runner has
    /// destroyed the stub.
    stats_out: ?*Stats = null,

    pub const Stats = struct { renders: usize = 0, ticks: usize = 0 };

    /// What a `StubFactory` copies into every stub it makes.
    pub const Proto = struct {
        text: []const u8 = "",
        late_after: ?usize = null,
        late_text: []const u8 = "",
        dirty: ?bool = null,
        title: ?[]const u8 = null,
        highlights: ?usize = null,
        known_commands: []const []const u8 = &.{},
        quit_command: ?[]const u8 = null,
        has_editor: bool = true,
    };

    pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Stub {
        var s = try Screen.init(gpa, .{ .cols = cols, .rows = rows, .x_pixel = 0, .y_pixel = 0 });
        s.width_method = .unicode;
        return .{ .gpa = gpa, .screen = s };
    }

    pub fn deinit(self: *Stub) void {
        for (self.calls.items) |c| self.gpa.free(c);
        self.calls.deinit(self.gpa);
        self.screen.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn driver(self: *Stub) Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The stub's vtable, for tests that override one entry.
    pub fn vtablePtr() *const Driver.VTable {
        return &vtable;
    }

    /// All recorded calls, one per line.
    pub fn callsJoined(self: *const Stub, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.calls.items, 0..) |c, i| {
            if (i > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, c);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn countCalls(self: *const Stub, name: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.eql(u8, c, name) or (std.mem.startsWith(u8, c, name) and c.len > name.len and c[name.len] == ' ')) n += 1;
        }
        return n;
    }

    fn record(self: *Stub, comptime fmt: []const u8, args: anytype) Error!void {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(s);
        try self.calls.append(self.gpa, s);
    }

    /// Paint `text` row by row, ASCII one cell per byte, blanking the rest.
    fn paint(self: *Stub, text: []const u8) void {
        var y: u16 = 0;
        while (y < self.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.screen.width) : (x += 1) self.screen.writeCell(x, y, .{ .char = .{ .grapheme = " ", .width = 1 } });
        }
        var rows = std.mem.splitScalar(u8, text, '\n');
        y = 0;
        while (rows.next()) |row| : (y += 1) {
            if (y >= self.screen.height) break;
            for (row, 0..) |_, i| {
                if (i >= self.screen.width) break;
                self.screen.writeCell(@intCast(i), y, .{ .char = .{ .grapheme = row[i .. i + 1], .width = 1 } });
            }
        }
    }

    fn cast(ptr: *anyopaque) *Stub {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: Driver.VTable = .{
        .open = vOpen,
        .key = vKey,
        .mouse = vMouse,
        .command = vCommand,
        .ex = vEx,
        .snippet = vSnippet,
        .ghost = vGhost,
        .tick = vTick,
        .expireChords = vExpireChords,
        .wheelNotch = vWheelNotch,
        .render = vRender,
        .shot = vShot,
        .screen = vScreen,
        .status = vStatus,
        .rectsJson = vRectsJson,
        .dirty = vDirty,
        .paneTitle = vPaneTitle,
        .highlightCount = vHighlightCount,
        .ipcCommand = vIpcCommand,
        .pluginInvocations = vPluginInvocations,
        .requestQuit = vRequestQuit,
        .deinit = vDeinit,
    };

    fn vOpen(p: *anyopaque, path: []const u8) Error!void {
        return cast(p).record("open {s}", .{path});
    }
    fn vKey(p: *anyopaque, k: input.Key) Error!void {
        return cast(p).record("key {f}", .{input.Chord.of(k)});
    }
    fn vMouse(p: *anyopaque, m: input.Mouse) Error!void {
        return cast(p).record("mouse {s} {s} {d},{d}", .{ @tagName(m.kind), @tagName(m.button), m.x, m.y });
    }
    fn vCommand(p: *anyopaque, id: []const u8) Error!void {
        const self = cast(p);
        try self.record("command {s}", .{id});
        if (self.quit_command) |q| if (std.mem.eql(u8, q, id)) {
            self.quit = true;
            return;
        };
        for (self.known_commands) |k| if (std.mem.eql(u8, k, id)) return;
        return error.NoSuchCommand;
    }
    fn vEx(p: *anyopaque, line: []const u8) Error!void {
        return cast(p).record("ex {s}", .{line});
    }
    fn vSnippet(p: *anyopaque, scope: []const u8, trigger: []const u8, expansion: []const u8) Error!void {
        return cast(p).record("snippet {s} {s} {s}", .{ scope, trigger, expansion });
    }
    fn vGhost(p: *anyopaque, text: []const u8) Error!void {
        const self = cast(p);
        try self.record("ghost {s}", .{text});
        if (!self.has_editor) return error.NoActiveEditor;
    }
    fn vTick(p: *anyopaque) Error!void {
        const self = cast(p);
        self.ticks += 1;
        return self.record("tick", .{});
    }
    fn vExpireChords(p: *anyopaque) Error!void {
        return cast(p).record("expire", .{});
    }
    fn vWheelNotch(_: *anyopaque) void {}
    fn vRender(p: *anyopaque) Error!void {
        const self = cast(p);
        try self.record("render", .{});
        self.renders += 1;
        const late = if (self.late_after) |n| self.renders > n else false;
        self.paint(if (late) self.late_text else self.text);
    }

    /// The stub has no pixels; it records the ask so a test can see the
    /// step reached the driver, and succeeds.
    fn vShot(p: *anyopaque, name: []const u8) Error!void {
        try cast(p).record("shot {s}", .{name});
    }

    fn vScreen(p: *anyopaque) *const Screen {
        return &cast(p).screen;
    }
    fn vStatus(p: *anyopaque, a: Allocator) Error!screen_mod.Status {
        const self = cast(p);
        const title = self.title orelse "";
        return .{
            .focus = self.status_focus,
            .active_pane = if (self.has_editor) 0 else null,
            .active_file = try a.dupe(u8, title),
            .cursor_line = if (self.has_editor) 1 else 0,
            .cursor_col = if (self.has_editor) 1 else 0,
            .mode = "none",
            .tree_cursor = 0,
            .tree_selection = "",
            .tree_visible = true,
            .right_panel_visible = false,
            .right_panel_panes = &.{},
            .right_panel_active_idx = 0,
            .panes = if (self.has_editor) try a.dupe(screen_mod.PaneStatus, &.{.{ .title = title, .dirty = self.dirty_flag orelse false }}) else &.{},
            .quit = self.quit,
            // The stub's screen is a real one, so it answers the
            // geometry keys honestly. It has no pixels, so `cell_*_px`
            // stays zero and a host refuses to click rather than
            // clicking a guessed spot.
            .cols = self.screen.width,
            .rows = self.screen.height,
        };
    }
    fn vRectsJson(_: *anyopaque, a: Allocator) Error![]u8 {
        return a.dupe(u8, "[]\n");
    }
    fn vDirty(p: *anyopaque) ?bool {
        return cast(p).dirty_flag;
    }
    fn vPaneTitle(p: *anyopaque, a: Allocator) Error!?[]u8 {
        const self = cast(p);
        return if (self.title) |s| try a.dupe(u8, s) else null;
    }
    fn vHighlightCount(p: *anyopaque) ?usize {
        return cast(p).highlights;
    }
    fn vIpcCommand(p: *anyopaque, cmd: *const ipc.Command) Error!void {
        return cast(p).record("ipc {s}", .{@tagName(cmd.*)});
    }
    fn vPluginInvocations(p: *anyopaque, a: Allocator) Error![]const []const u8 {
        const self = cast(p);
        const out = try a.dupe([]const u8, self.plugin_pending);
        self.plugin_pending = &.{};
        return out;
    }
    fn vRequestQuit(p: *anyopaque, restart: bool) void {
        const self = cast(p);
        self.quit = true;
        self.restart = restart;
    }
    fn vDeinit(p: *anyopaque) void {
        const self = cast(p);
        if (self.stats_out) |out| out.* = .{ .renders = self.renders, .ticks = self.ticks };
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }
};

/// A `Factory` that hands out `Stub`s configured from `proto`: the runner
/// tests describe the screen a file should see and get a fresh stub per
/// file. `made` counts creations so a test can assert one per size;
/// `stats` holds the counts of the most recently destroyed stub.
pub const StubFactory = struct {
    proto: Stub.Proto = .{},
    made: usize = 0,
    stats: Stub.Stats = .{},

    pub fn factory(self: *StubFactory) Factory {
        return .{ .ptr = self, .create = create };
    }

    fn create(p: *anyopaque, gpa: Allocator, io: Io, cfg_in: Config) anyerror!Driver {
        _ = io;
        var cfg = cfg_in;
        if (cfg.loaded) |*l| l.deinit(); // the stub reads no config
        const self: *StubFactory = @ptrCast(@alignCast(p));
        const s = try gpa.create(Stub);
        errdefer gpa.destroy(s);
        s.* = try Stub.init(gpa, cfg.cols, cfg.rows);
        s.text = self.proto.text;
        s.late_after = self.proto.late_after;
        s.late_text = self.proto.late_text;
        s.dirty_flag = self.proto.dirty;
        s.title = self.proto.title;
        s.highlights = self.proto.highlights;
        s.known_commands = self.proto.known_commands;
        s.quit_command = self.proto.quit_command;
        s.has_editor = self.proto.has_editor;
        s.stats_out = &self.stats;
        self.made += 1;
        return s.driver();
    }
};

test "stub records calls and paints its canned text" {
    var s = try Stub.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    s.text = "hello\nrow2";
    const d = s.driver();
    try d.render();
    try d.typeText("a\n");
    try d.click(3, 1, .right, .{});
    try std.testing.expectEqual(@as(usize, 2), try d.drag(0, 0, 2, 1));
    try std.testing.expectError(error.NoSuchCommand, d.command("x.y"));
    const calls = try s.callsJoined(std.testing.allocator);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings(
        \\render
        \\key a
        \\key enter
        \\mouse press right 3,1
        \\mouse release right 3,1
        \\mouse press left 0,0
        \\mouse drag left 1,1
        \\mouse drag left 2,1
        \\mouse release left 2,1
        \\command x.y
    , calls);
    const txt = try screen_mod.toTestText(std.testing.allocator, d.screen());
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("hello     \nrow2      ", txt);
    try std.testing.expectEqual(@as(usize, 2), s.countCalls("key"));
}

test "drag interpolates like the IPC drag: round-half-away, one event per cell" {
    var s = try Stub.init(std.testing.allocator, 20, 20);
    defer s.deinit();
    const d = s.driver();
    try std.testing.expectEqual(@as(usize, 5), try d.drag(1, 3, 6, 5));
    const calls = try s.callsJoined(std.testing.allocator);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings(
        \\mouse press left 1,3
        \\mouse drag left 2,3
        \\mouse drag left 3,4
        \\mouse drag left 4,4
        \\mouse drag left 5,5
        \\mouse drag left 6,5
        \\mouse release left 6,5
    , calls);
}
