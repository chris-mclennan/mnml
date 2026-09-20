//! The `e2e.Driver` over a real `App`: what the `.test` runner and the
//! headless loop drive. One instance per file (and per size); the App
//! lives on the driver's own allocator so a leak is that file's failure.
//!
//! `status` fills `ipc.Status` the way mnml 0.2 does: 1-based cursor,
//! the mode label or `none`, every live pane's title + dirty flag.

const std = @import("std");
const mem_report = @import("../core/mem_report.zig");
const syntax_mod = @import("syntax.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const side = @import("side.zig");
const ghost_chip = @import("ghost_chip.zig");
const settings_app = @import("settings.zig");
const App = app_mod.App;
const dispatch = @import("dispatch.zig");
const tasks = @import("tasks.zig");
const e2e = @import("../e2e/driver.zig");
const key_mod = @import("../core/key.zig");
const command = @import("../core/command.zig");
const ipc = @import("../ipc/root.zig");
const screen_mod = @import("../ipc/screen.zig");
const input = @import("../input/mod.zig");

const Error = e2e.Error;

pub const AppDriver = struct {
    gpa: Allocator,
    app: App,

    /// `style` is the `--input` flag: set, it overrides the config's
    /// `editor.input_style`; null lets the config decide. `cfg.loaded`
    /// is owned from here on, whatever happens.
    pub fn create(gpa: Allocator, io: Io, cfg: e2e.Config, style: ?input.Style) !*AppDriver {
        var loaded = cfg.loaded;
        const self = gpa.create(AppDriver) catch |err| {
            if (loaded) |*l| l.deinit();
            return err;
        };
        errdefer gpa.destroy(self);
        var c = cfg.cfg;
        if (style) |s| c.editor.input_style = App.configStyleOf(s);
        self.* = .{
            .gpa = gpa,
            .app = try App.initWith(gpa, io, .{
                .cfg = c,
                .loaded = loaded,
                .workspace = cfg.workspace,
                .data_root = cfg.data_root,
                .cols = cfg.cols,
                .rows = cfg.rows,
                .env = cfg.env,
                // The runner made this workspace itself: its `.mnml/init.lua`
                // is the script under test.
                .workspace_trusted = true,
            }),
        };
        loaded = null;
        errdefer self.app.deinit();
        // A test's statusline must not carry the developer's own
        // coverage: the artifacts home is the test's data root. The
        // headless loop runs on a config from files, like the terminal
        // does, and shows the real coverage — the UI diff reads it.
        if (cfg.loaded == null) try self.app.env.put("MNML_ARTIFACTS_HOME", cfg.data_root);
        if (cfg.startup_hook) {
            // As `tui/loop.zig` does before its first frame: the config's
            // tasks, then the hook that restores the session and runs
            // the startup names.
            try tasks.installFromConfig(&self.app, &self.app.cfg);
            self.app.hooks.emit(&self.app, .startup);
        }
        return self;
    }

    pub fn driver(self: *AppDriver) e2e.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(p: *anyopaque) *AppDriver {
        return @ptrCast(@alignCast(p));
    }

    const vtable: e2e.Driver.VTable = .{
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
        const app = &cast(p).app;
        _ = app.openPath(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.toast("open {s}: {s}", .{ app.relPath(path), @errorName(err) });
                return error.Failed;
            },
        };
    }

    fn vKey(p: *anyopaque, k: key_mod.Key) Error!void {
        try cast(p).app.handle(.{ .key = k });
    }

    fn vMouse(p: *anyopaque, m: key_mod.Mouse) Error!void {
        try cast(p).app.handle(.{ .mouse = m });
    }

    fn vWheelNotch(p: *anyopaque) void {
        cast(p).app.accel.endGesture();
    }

    /// An unknown id is the step's failure; a command that ran and
    /// failed has toasted its reason and the script goes on, as under
    /// the Rust runner.
    fn vCommand(p: *anyopaque, id: []const u8) Error!void {
        const app = &cast(p).app;
        const ref = command.resolve(app, id) orelse return error.NoSuchCommand;
        command.run(app, ref) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    fn vEx(p: *anyopaque, line: []const u8) Error!void {
        try dispatch.runExLine(&cast(p).app, line);
    }

    fn vSnippet(p: *anyopaque, scope: []const u8, trigger: []const u8, expansion: []const u8) Error!void {
        try cast(p).app.snippets.seed(scope, trigger, expansion);
    }

    fn vGhost(p: *anyopaque, text: []const u8) Error!void {
        const app = &cast(p).app;
        const e = app.activeEditor() orelse return error.NoActiveEditor;
        try e.buf.editor.setGhostSuggestion(text);
        app.needs_render = true;
    }

    fn vTick(p: *anyopaque) Error!void {
        const app = &cast(p).app;
        try app.tick(App.nowMs(app.io));
    }

    /// Only a chain whose `timeoutlen` has actually run out. The hook
    /// used to fire every pending fallback the moment it was called,
    /// which made a driven run unlike a user's hands: a chord bound on
    /// its own AND a prefix — `ctrl+k`, the standard profile's
    /// which-key leader and the prefix of eighteen `ctrl+k …` chords —
    /// expired into its fallback between one step and the next, so the
    /// popup opened, ate the tail, and none of the eighteen could be
    /// driven at all. `App.tick` has always read the deadline; this
    /// reads the same clock, so the harness resolves a chord the way
    /// the terminal loop does and only a `wait` past `timeoutlen`
    /// opens the popup.
    fn vExpireChords(p: *anyopaque) Error!void {
        const app = &cast(p).app;
        const deadline = app.chord.deadline_ms orelse return;
        if (App.nowMs(app.io) < deadline) return;
        try dispatch.expireChords(app);
    }

    fn vRender(p: *anyopaque) Error!void {
        try cast(p).app.render();
    }

    /// The App renders into a cell grid, not a window: there are no
    /// pixels here to photograph. The step still succeeds, so one script
    /// runs unchanged under both drivers and only the ghostty one
    /// actually leaves a picture (`src/e2e/ghostty_driver.zig`).
    fn vShot(_: *anyopaque, _: []const u8) Error!void {}

    fn vScreen(p: *anyopaque) *const screen_mod.Screen {
        return &cast(p).app.screen;
    }

    fn vStatus(p: *anyopaque, a: Allocator) Error!screen_mod.Status {
        return statusOf(&cast(p).app, a);
    }

    /// The frame's `status.json` for any App — the driver's answer and,
    /// under `ipc.write_screen`, the terminal loop's too, so a live
    /// session says which surface owns the cursor the same way a
    /// headless one does.
    pub fn statusOf(app: *App, a: Allocator) Allocator.Error!screen_mod.Status {
        var panes: std.ArrayListUnmanaged(screen_mod.PaneStatus) = .empty;
        for (app.panes.slots.items) |*slot| if (slot.*) |*pane| {
            try panes.append(a, .{ .title = try a.dupe(u8, pane.title()), .dirty = pane.dirty(), .preview = pane.preview() });
        };
        var st: screen_mod.Status = .{
            // Rust's wire words: a left-column section is the sidebar.
            .focus = switch (app.focus) {
                .tree => .tree,
                .pane, .overlay => .pane,
                .panel => |pid| if (side.sideOf(app, side.sectionOfPanel(pid)) == .left) .tree else .right_panel,
            },
            .active_pane = if (app.active) |id| @as(usize, id) else null,
            .active_file = "",
            .cursor_line = 0,
            .cursor_col = 0,
            .mode = "none",
            .tree_cursor = app.tree.cursor,
            .tree_selection = try a.dupe(u8, try app.tree.selectionPath(app)),
            .tree_visible = app.tree.visible,
            .right_panel_visible = side.shown(app, .right) != null,
            .right_panel_panes = &.{},
            .right_panel_active_idx = 0,
            .panes = panes.items,
            .quit = app.quit,
            // The frame's one cursor: headless draws none, so this is
            // the only way a `.test` script sees which surface owns it.
            .cursor_shape = if (app.cursor_out) |c| @tagName(c.shape) else "hidden",
            // The app's own `:` line. The chip says CMD for a buffer's
            // vim `:` too, but this key is about the one the bottom row
            // owns — the one a click opens and a click off it closes.
            .cmdline = app.cmdline != null,
            // Ghost text is the one subsystem whose whole story is
            // off-screen: the request goes out on a worker and the
            // answer lands seconds later. Without this a `.test` could
            // only poll the screen and hope.
            .ghost = ghost_chip.phase(app).wire(),
            // The screen the frame was drawn into, so a host that drives
            // the real window can turn a cell into a pixel. How big a
            // cell is in pixels is the terminal's to answer, and only
            // the terminal loop has one — it fills `cell_*_px` in after
            // this call (tui/loop.zig); headless leaves them zero.
            .cols = app.screen.width,
            .rows = app.screen.height,
        };
        if (app.activeEditor()) |e| {
            const pos = e.buf.editor.rowCol();
            st.cursor_line = pos.row + 1;
            st.cursor_col = pos.col + 1;
            st.active_file = if (e.buf.doc.path) |path| try a.dupe(u8, path) else "";
            st.mode = e.buf.input.mode().label() orelse "none";
        }
        st.settings = try settingsList(app, a);
        return st;
    }

    /// The Settings overlay's list window for `status.json`. The box's
    /// footer carries the same fact as `22/98`, but the total moves
    /// every time a row lands, so a script that reads the footer is
    /// re-pinned for a change it has nothing to do with. This is the
    /// window on its own: where it starts, how tall it is, and whether
    /// it is against either end.
    fn settingsList(app: *App, a: Allocator) Allocator.Error!?screen_mod.SettingsList {
        if (app.overlay != .settings) return null;
        const ui = &app.overlay.settings.ui;
        // Before the first draw the box has not said how tall its list
        // is; a window of no rows is the honest answer, not a guess.
        const total = (try settings_app.lists(app, a)).visible.len;
        const visible = @min(ui.rows, total);
        return .{
            .top = ui.scroll + 1,
            .visible = visible,
            .at_top = ui.scroll == 0,
            .at_end = ui.scroll + visible >= total,
        };
    }

    fn vRectsJson(p: *anyopaque, a: Allocator) Error![]u8 {
        var out: Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        const app = cast(p).app;
        app.hits.writeRectsJson(&out.writer, app.overlayLabel()) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn vDirty(p: *anyopaque) ?bool {
        const e = cast(p).app.activeEditor() orelse return null;
        return e.buf.doc.dirty;
    }

    fn vPaneTitle(p: *anyopaque, a: Allocator) Error!?[]u8 {
        const app = &cast(p).app;
        const id = app.active orelse return null;
        const pane = app.panes.get(id) orelse return null;
        return try a.dupe(u8, pane.title());
    }

    /// Spans across the visible lines of the active editor — what the
    /// frame just painted, or would paint once the idle gate opens.
    fn vHighlightCount(p: *anyopaque) ?usize {
        const app = &cast(p).app;
        const e = app.activeEditor() orelse return null;
        const ed = e.buf.editor;
        if (e.syntax.dirty and !syntax_mod.Syntax.onWorker(ed.len())) {
            e.syntax.refresh(ed) catch return null;
            e.syntax.dirty = false;
            e.syntax.since_ms = null;
        }
        const first: usize = e.view.scroll_line;
        const last = @min(first + @max(app.pane_rows, 1), ed.lineCount()) -| 1;
        return e.syntax.countIn(ed, ed.lineStart(@min(first, ed.lineCount() - 1)), ed.lineEnd(last)) catch null;
    }

    /// The tier-2 IPC commands: toasts, and command registration.
    /// One dispatcher, `ipc.effects.applyTier2` — the same one the
    /// terminal loop comes through, so nothing can work in a `.test`
    /// and be refused in the real app.
    fn vIpcCommand(p: *anyopaque, cmd: *const ipc.Command) Error!void {
        const app = &cast(p).app;
        if (!try ipc.effects.applyTier2(app, cmd)) app.toast("ipc {s}: not in this build", .{@tagName(cmd.*)});
    }

    fn vPluginInvocations(p: *anyopaque, a: Allocator) Error![]const []const u8 {
        const app = &cast(p).app;
        const out = try a.alloc([]const u8, app.plugin_invocations.items.len);
        for (app.plugin_invocations.items, 0..) |id, i| out[i] = try a.dupe(u8, id);
        for (app.plugin_invocations.items) |id| app.gpa.free(id);
        app.plugin_invocations.clearRetainingCapacity();
        return out;
    }

    fn vRequestQuit(p: *anyopaque, restart: bool) void {
        const app = &cast(p).app;
        app.quit = true;
        app.restart = restart;
    }

    fn vDeinit(p: *anyopaque) void {
        const self = cast(p);
        const gpa = self.gpa;
        if (mem_report.enabled) printMemReport(&self.app);
        self.app.deinit();
        gpa.destroy(self);
    }
};

/// `-Dmem-report`: where the session's memory is as it ends — the two
/// counters, then each open document's parts by their own sizes.
fn printMemReport(app: *App) void {
    const mb = mem_report.mb;
    std.debug.print("mem-report: app live {d} MB (peak {d}) | tree-sitter live {d} MB (peak {d})\n", .{
        mb(mem_report.app.live.load(.monotonic)),         mb(mem_report.app.peak.load(.monotonic)),
        mb(mem_report.tree_sitter.live.load(.monotonic)), mb(mem_report.tree_sitter.peak.load(.monotonic)),
    });
    for (app.docs.entries.items) |e| {
        const d = e.doc;
        const h = &d.history;
        var undo_bytes: usize = 0;
        for (h.undo.items.items[h.undo.head..]) |s| undo_bytes += s.mid.len;
        var redo_bytes: usize = 0;
        for (h.redo.items.items[h.redo.head..]) |s| redo_bytes += s.mid.len;
        std.debug.print("mem-report: doc {s}: text {d} MB (cap {d}) | saved {d} MB | lines {d} MB | undo {d} entries {d} KB | redo {d} entries {d} KB | kept spans {d}\n", .{
            d.path orelse "(scratch)",                   mb(d.text.items.len),
            mb(d.text.capacity),                         mb(d.savedBytes()),
            mb(d.line_starts.capacity * @sizeOf(usize)), h.undoLen(),
            mb(undo_bytes),                              h.redoLen(),
            mb(redo_bytes),                              e.syntax.hl.keptSpanCount(),
        });
    }
}

/// What `main.app_factory` points at. `input_style` is the `--input`
/// flag for the terminal / headless paths (null = the config's choice);
/// `.test` files start on the runner's defaults and switch with
/// `editor.use_vim` themselves.
pub const AppFactory = struct {
    input_style: ?input.Style = null,

    pub fn factory(self: *AppFactory) e2e.Factory {
        return .{ .ptr = self, .create = create };
    }

    fn create(p: *anyopaque, gpa: Allocator, io: Io, cfg: e2e.Config) anyerror!e2e.Driver {
        const self: *AppFactory = @ptrCast(@alignCast(p));
        const d = try AppDriver.create(gpa, io, cfg, self.input_style);
        return d.driver();
    }
};

/// The process-wide factory `main` hands to the runner and the headless loop.
pub var default_factory: AppFactory = .{};

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "driver: open, type, status, dirty, title, rects, quit — the runner's contract" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "first line" });
    var f: AppFactory = .{};
    const d = try f.factory().make(t.allocator, t.io, .{ .workspace = root, .data_root = "", .cols = 60, .rows = 12 });
    defer d.deinit();
    const path = try std.fs.path.join(t.allocator, &.{ root, "notes.txt" });
    defer t.allocator.free(path);
    try d.open(path);
    try d.render();
    const txt = try screen_mod.toTestText(t.allocator, d.screen());
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "first line") != null);
    try t.expectEqual(false, d.dirty().?);
    const title = (try d.paneTitle(t.allocator)).?;
    defer t.allocator.free(title);
    try t.expectEqualStrings("notes.txt", title);
    try d.typeText("TYPED ");
    try t.expectEqual(true, d.dirty().?);
    try t.expectError(error.NoSuchCommand, d.command("nope.nope"));
    try d.command("file.save");
    try t.expectEqual(false, d.dirty().?);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const st = try d.status(arena.allocator());
    // Saving appended the file's terminating newline; the cursor stays
    // after "TYPED " on line 1 (it used to ride the newline onto a
    // phantom line 2 — a Rust bug this test once pinned as parity).
    try t.expectEqual(@as(usize, 1), st.cursor_line);
    try t.expectEqual(@as(usize, 7), st.cursor_col);
    try t.expectEqualStrings("none", st.mode);
    try t.expectEqualStrings(path, st.active_file);
    try t.expectEqual(@as(usize, 1), st.panes.len);
    try t.expectEqualStrings("notes.txt", st.panes[0].title);
    try t.expect(st.focus == .pane);
    // The geometry a host driving the real window reads to turn a cell
    // into a pixel: the screen it was made with, and no pixel size,
    // because nothing here is a terminal.
    try t.expectEqual(@as(u16, 60), st.cols);
    try t.expectEqual(@as(u16, 12), st.rows);
    try t.expectEqual(@as(u32, 0), st.cell_w_px);
    try t.expectEqual(@as(u32, 0), st.cell_h_px);
    const rects = try d.rectsJson(arena.allocator());
    try t.expect(std.mem.indexOf(u8, rects, "\"label\":\"pane:0\"") != null);
    try t.expect(std.mem.indexOf(u8, rects, "editor_cell:0:0:0") != null);
    try t.expect(std.mem.indexOf(u8, rects, "picker:") == null);
    // An overlay's rows are in the dump too, named after the overlay:
    // the file picker's rows read `picker:N`, the palette's `palette:N`.
    try d.command("picker.files");
    try d.render();
    const picker_rects = try d.rectsJson(arena.allocator());
    try t.expect(std.mem.indexOf(u8, picker_rects, "\"label\":\"picker:0\"") != null);
    try t.expect(std.mem.indexOf(u8, picker_rects, "overlay_item:") == null);
    try d.key(key_mod.Key.named(.esc));
    try d.command("palette");
    try d.render();
    const palette_rects = try d.rectsJson(arena.allocator());
    try t.expect(std.mem.indexOf(u8, palette_rects, "\"label\":\"palette:0\"") != null);
    try d.key(key_mod.Key.named(.esc));
    try d.ex("set input=vim");
    const st2 = try d.status(arena.allocator());
    try t.expectEqualStrings("NORMAL", st2.mode);
    try t.expect(d.highlightCount() != null);
    d.requestQuit(true);
    const st3 = try d.status(arena.allocator());
    try t.expect(st3.quit);
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
