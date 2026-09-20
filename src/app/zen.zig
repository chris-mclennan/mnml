//! Full screen (zen) — the editor and nothing else. `view.fullscreen`
//! flips `App.zen`; `render.zig` then skips the palette bar, the tree,
//! the right panel, the tab strips and the statusline. The `:` line
//! stays (it is how a vim user leaves). The flag rides along in
//! `session.zon`, so quitting full screen comes back full screen.
//!
//! The way out has to be easy to find with the chrome gone: entering
//! (a restore too) toasts how to leave; a plain Esc that nothing else
//! wants toasts the hint and a second Esc within the chord timeout
//! leaves (`escKey`, called from `dispatch.zig`); `:fullscreen` /
//! `:zen` toggle it from the `:` line; `view.reset_layout`
//! (`:resetview`) leaves it along with everything else that hides the
//! frame.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const side = @import("side.zig");
const settings = @import("settings.zig");
const Config = @import("../config/Config.zig");

pub const table = .{
    .@"view.fullscreen" = &toggle,
    .@"view.toggle_zoom" = &toggleZoom,
    .@"view.reset_layout" = &resetLayout,
};

/// The toast ids: the enter reminder and the Esc hint replace their
/// predecessor rather than stack.
const enter_toast_id = "zen.enter";
const esc_toast_id = "zen.esc";

/// The chord that toggles full screen under the active profile, as a
/// ` · ` suffix for the toasts — the standard profile's `Ctrl+K Z`;
/// the vim profile has none (the `:` line is its door).
fn chordSuffix(app: *const App) []const u8 {
    return switch (app.input_style) {
        .vim => "",
        .standard => " · Ctrl+K Z",
    };
}

/// The palette title / menu label reads the way out while inside.
pub fn title(app: *const App) []const u8 {
    return if (app.zen) "Exit full screen" else "Enter full screen";
}

pub fn toggle(app: *App) CommandError!void {
    if (app.zen) {
        set(app, false);
        app.toast("full screen off", .{});
    } else set(app, true);
}

/// Enter (`on`) or leave. Entering — from the command, the strip's
/// button or a restored session — toasts the way out once.
pub fn set(app: *App, on: bool) void {
    const was = app.zen;
    app.zen = on;
    app.zen_esc_ms = null;
    if (on) {
        // Entering lands the keyboard on the pane so typing starts at
        // once; the tree and the panels are not painted, so they cannot
        // hold it.
        if (app.active) |a| app.focus = .{ .pane = a };
        if (!was) app.toastReplace(enter_toast_id, "Full screen · Esc Esc or {s} leaves", .{
            @as([]const u8, if (app.input_style == .vim) ":fullscreen" else "Ctrl+K Z"),
        });
    } else app.dismissToast(enter_toast_id);
    app.needs_render = true;
}

/// `view.toggle_zoom` (`space z z`, the strip's maximize button's
/// menu): the active pane's leaf alone fills the body; the same call
/// on it restores; on another leaf the zoom moves there (Rust's
/// `toggle_zoom_active_leaf`). The split tree is untouched, so
/// `Ctrl+W` and the dividers still address the real layout.
fn toggleZoom(app: *App) CommandError!void {
    const active = app.active orelse {
        app.toast("nothing to maximize — open a pane first", .{});
        return;
    };
    app.zoomed_leaf = if (app.zoomed_leaf == active) null else active;
    app.needs_render = true;
}

// ─── the strip's maximize button ────────────────────────────────────────
//
// The button has two modes because the two commands answer two
// different asks, and the one a click should run is not the same for
// everybody. `ui.maximize_click` picks; the right button lists both and
// ticks the pick (`app/context_menus.zig`).
//
// There is no third mode. The split tree's only scope between one pane
// and the whole window is the leaf, and a leaf IS the tab group — the
// tabs it holds are its own. So "zoom this pane" and "zoom this tab
// group" name the same rect, and a second row running the same command
// would be a row that does nothing new.

/// What `ui.maximize_click` names, for the hover line and the menu.
pub fn modeLabel(mode: Config.MaximizeClick) []const u8 {
    return switch (mode) {
        .zoom_pane => "Zoom this pane",
        .fullscreen => "Full screen",
    };
}

/// The command the maximize button runs on a left click. Whatever the
/// mode, while something is already maximized the button is the way
/// back, so it undoes what is on — full screen first, since it hides
/// the chrome the zoom keeps. With nothing on, it is the mode.
pub fn clickCommand(app: *const App) command.CommandId {
    if (app.zen) return .@"view.fullscreen";
    if (app.zoomed_leaf != null) return .@"view.toggle_zoom";
    return commandFor(app.cfg.ui.maximize_click);
}

pub fn commandFor(mode: Config.MaximizeClick) command.CommandId {
    return switch (mode) {
        .zoom_pane => .@"view.toggle_zoom",
        .fullscreen => .@"view.fullscreen",
    };
}

/// `view.reset_layout` (`:resetview`, the View menu's last row): the
/// frame as it starts — full screen and the zoom off, the tree shown
/// on its side at the config's width, the menu bar and the activity
/// bar painted when they were hidden (persisted, as their cycle
/// commands do), every split back to equal halves (`Ctrl+W _` / `|`
/// undone), the keyboard on the active pane. The open panes stay.
fn resetLayout(app: *App) CommandError!void {
    set(app, false);
    app.dismissToast(esc_toast_id);
    app.zoomed_leaf = null;
    side.place(app, .explorer, false);
    app.tree.width = app.cfg.ui.tree_width;
    if (app.cfg.ui.menu_bar == .hidden) {
        app.cfg.ui.menu_bar = .always;
        _ = try settings.persist(app, .home, &.{ "ui", "menu_bar" }, app.cfg.ui.menu_bar);
    }
    if (app.cfg.ui.activity_bar == .hidden) {
        app.cfg.ui.activity_bar = .always;
        _ = try settings.persist(app, .home, &.{ "ui", "activity_bar" }, app.cfg.ui.activity_bar);
    }
    app.layouts.current().equalize();
    if (app.active) |a| app.focus = .{ .pane = a };
    app.toast("view reset to default", .{});
    app.needs_render = true;
}

/// A plain Esc while inside, once nothing else wants it — no overlay,
/// no find bar, no pending chord, no insert / visual / cmdline /
/// operator state, no selection to drop. The first press arms and
/// toasts the hint (the key goes on to whatever Esc does anyway); a
/// second within the chord timeout leaves. True only when it left.
pub fn escKey(app: *App, k: Key) bool {
    if (!app.zen or k.code != .esc or !k.mods.eql(.{})) return false;
    if (app.overlay != .none or app.find_bar != null or app.chord.len > 0) return false;
    if (app.activeEditor()) |e| {
        switch (e.buf.input.mode()) {
            .normal, .none => {},
            else => return false,
        }
        if (e.buf.input.isCmdlineOpen() or e.buf.input.isOpPending()) return false;
        if (e.buf.editor.hasSelection() or e.buf.editor.extra_cursors.items.len > 0) return false;
    }
    const timeout: i64 = @intCast(app.cfg.editor.chord_timeout_ms);
    if (app.zen_esc_ms) |t0| if (app.now_ms - t0 <= timeout) {
        app.dismissToast(esc_toast_id);
        set(app, false);
        app.toast("full screen off", .{});
        return true;
    };
    app.zen_esc_ms = app.now_ms;
    app.toastReplace(esc_toast_id, "Esc again leaves full screen · :fullscreen{s}", .{chordSuffix(app)});
    return false;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "zen: the frame drops the tree, the strip and the statusline; a second toggle brings them back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    app.tree.visible = true;
    app.tree.loaded = true; // an empty listing: the test never touches /tmp
    try app.render();
    const screen = @import("../ipc/screen.zig");
    const before = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(before);
    try t.expect(std.mem.indexOf(u8, before, "[scratch]") != null); // the tab strip
    try t.expect(std.mem.indexOf(u8, before, "EDIT") != null); // the statusline's mode chip
    try t.expect(app.panes_area.x > 0); // the tree takes the left
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(app.zen);
    try t.expect(app.focus == .pane);
    try app.render();
    const zen = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(zen);
    try t.expect(std.mem.indexOf(u8, zen, "[scratch]") == null);
    try t.expect(std.mem.indexOf(u8, zen, "EDIT") == null);
    try t.expectEqual(@as(u16, 0), app.panes_area.x); // no tree
    try t.expectEqual(@as(u16, 100), app.panes_area.w);
    try t.expectEqual(@as(u16, 0), app.panes_area.y); // no palette bar
    try t.expectEqual(@as(u16, 23), app.panes_area.h); // only the `:` line is kept
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(!app.zen);
    try app.render();
    const after = try screen.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, "EDIT") != null);
}

fn lastToast(app: *App) []const u8 {
    return if (app.toasts.items.len > 0) app.toasts.items[app.toasts.items.len - 1].text else "";
}

fn hasToast(app: *App, text: []const u8) bool {
    for (app.toasts.items) |tt| if (std.mem.indexOf(u8, tt.text, text) != null) return true;
    return false;
}

test "zen: entering toasts the way out per profile; leaving says so and drops the reminder" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try app.setInputStyle(.standard);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expectEqualStrings("Full screen · Esc Esc or Ctrl+K Z leaves", lastToast(&app));
    try t.expectEqualStrings("Exit full screen", title(&app));
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(!app.zen);
    try t.expect(!hasToast(&app, "Esc Esc"));
    try t.expectEqualStrings("full screen off", lastToast(&app));
    try t.expectEqualStrings("Enter full screen", title(&app));
    try app.setInputStyle(.vim);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expectEqualStrings("Full screen · Esc Esc or :fullscreen leaves", lastToast(&app));
}

test "zen: Esc Esc leaves — an overlay takes the first Esc; the hint toasts; the timeout and any other key disarm; a selection goes first" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratchWith("alpha beta\n");
    try app.setInputStyle(.vim);
    app.now_ms = 10_000;
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(app.zen);
    // The help overlay owns the first Esc: it closes, full screen stays,
    // nothing is armed.
    try command.run(&app, .{ .static = .@"view.help" });
    try t.expect(app.overlay != .none);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(app.zen);
    try t.expect(app.zen_esc_ms == null);
    // A lone Esc arms and hints (vim: no chord, the `:` door).
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.zen);
    try t.expectEqual(@as(?i64, 10_000), app.zen_esc_ms);
    try t.expectEqualStrings("Esc again leaves full screen · :fullscreen", lastToast(&app));
    // Past the chord timeout the next Esc only re-arms.
    app.now_ms += app.cfg.editor.chord_timeout_ms + 1;
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.zen);
    try t.expectEqual(app.now_ms, app.zen_esc_ms.?);
    // Another key in between disarms.
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(app.zen_esc_ms == null);
    // Esc, Esc within the timeout leaves.
    try app.handle(.{ .key = Key.named(.esc) });
    app.now_ms += 100;
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.zen);
    try t.expect(!hasToast(&app, "Esc again"));
    try t.expectEqualStrings("full screen off", lastToast(&app));
    // Standard profile: the hint names the chord, and a selection is
    // dropped by the first Esc before anything is armed.
    try app.setInputStyle(.standard);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try command.run(&app, .{ .static = .@"editor.select_all" });
    try t.expect(app.activeEditor().?.buf.editor.hasSelection());
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.activeEditor().?.buf.editor.hasSelection());
    try t.expect(app.zen_esc_ms == null);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqualStrings("Esc again leaves full screen · :fullscreen · Ctrl+K Z", lastToast(&app));
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.zen);
}

test "zen: `:fullscreen` and `:zen` toggle it from the `:` line" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try @import("ex.zig").run(&app, "fullscreen");
    try t.expect(app.zen);
    try @import("ex.zig").run(&app, "zen");
    try t.expect(!app.zen);
}

/// The `.pane` hits of the last frame, and the rect of `id`'s.
fn panesPainted(app: *App) usize {
    var n: usize = 0;
    for (app.hits.items.items) |e| if (e.target == .pane) {
        n += 1;
    };
    return n;
}

fn paneRect(app: *App, id: app_mod.PaneId) ?@import("../ui/rect.zig") {
    for (app.hits.items.items) |e| if (e.target == .pane and e.target.pane == id) return e.rect;
    return null;
}

test "zoom: the active leaf alone paints over the body; again restores; another leaf moves it; the split tree is untouched; closing the pane clears it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    app.tree.loaded = true;
    // No pane: a word, nothing set.
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try t.expect(app.zoomed_leaf == null);
    try t.expectEqualStrings("nothing to maximize — open a pane first", lastToast(&app));
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try t.expect(a != b);
    try app.render();
    try t.expectEqual(@as(usize, 2), panesPainted(&app));
    try t.expect(paneRect(&app, b).?.w < app.panes_area.w);
    // Zoom: one pane, the whole body; the tree underneath keeps two leaves.
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try t.expectEqual(b, app.zoomed_leaf.?);
    try app.render();
    try t.expectEqual(@as(usize, 1), panesPainted(&app));
    try t.expect(paneRect(&app, a) == null);
    try t.expectEqual(app.panes_area.w, paneRect(&app, b).?.w);
    try t.expectEqual(app.panes_area.h, paneRect(&app, b).?.h);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // Again restores.
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try t.expect(app.zoomed_leaf == null);
    try app.render();
    try t.expectEqual(@as(usize, 2), panesPainted(&app));
    // Zoomed on `a`, the call from `b` moves the zoom rather than
    // asking for an un-zoom of a hidden leaf first.
    app.setActive(a);
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try t.expectEqual(a, app.zoomed_leaf.?);
    app.setActive(b);
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try t.expectEqual(b, app.zoomed_leaf.?);
    // The zoomed pane closing clears the zoom.
    try app.forceClosePane(b);
    try t.expect(app.zoomed_leaf == null);
    try app.render();
    try t.expectEqual(@as(usize, 1), panesPainted(&app));
}

test "reset_layout: leaves full screen and the zoom, shows the tree at the config width, brings hidden bars back, equalizes, keeps the panes; `:resetview` is it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.loaded = true;
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    // Everything the user could have hidden or stretched, at once.
    try command.run(&app, .{ .static = .@"view.toggle_zoom" });
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try command.run(&app, .{ .static = .@"view.maximize_width" });
    app.tree.width = 55;
    app.tree.visible = false;
    app.side.open.set(.left, null);
    app.cfg.ui.menu_bar = .hidden;
    app.cfg.ui.activity_bar = .hidden;
    try t.expect(app.zen);
    try t.expect(app.zoomed_leaf != null);
    try command.run(&app, .{ .static = .@"view.reset_layout" });
    try t.expect(!app.zen);
    try t.expect(app.zoomed_leaf == null);
    try t.expect(app.tree.visible);
    try t.expect(side.shown(&app, .left) == .explorer);
    try t.expectEqual(app.cfg.ui.tree_width, app.tree.width);
    try t.expectEqual(app_mod.Config.MenuBar.always, app.cfg.ui.menu_bar);
    try t.expectEqual(app_mod.Config.ActivityBar.always, app.cfg.ui.activity_bar);
    try t.expect(app.focus == .pane);
    try t.expectEqualStrings("view reset to default", lastToast(&app));
    // The two panes are still open, side by side, at equal widths.
    try t.expect(app.panes.get(a) != null and app.panes.get(b) != null);
    try app.render();
    try t.expectEqual(@as(usize, 2), panesPainted(&app));
    const wa = paneRect(&app, a).?.w;
    const wb = paneRect(&app, b).?.w;
    try t.expect(wa + 1 >= wb and wb + 1 >= wa);
    // The persisted bars.
    const home = (try settings.configPath(&app, .home)).?;
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".menu_bar = .always") != null);
    try t.expect(std.mem.indexOf(u8, text, ".activity_bar = .always") != null);
    // The `:` door.
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try @import("ex.zig").run(&app, "resetview");
    try t.expect(!app.zen);
}

test "zen: from a request pane and a terminal, `Ctrl+K Z` reaches the app (the `z` never lands in the URL field) and Esc Esc leaves" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    try app.setInputStyle(.standard);
    app.now_ms = 10_000;
    // A blank request pane, the URL field focused.
    const req = try @import("http.zig").openBlank(&app);
    try t.expectEqual(req, app.active.?);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try t.expect(app.zen);
    try app.handle(.{ .key = Key.ctrl('k') });
    try t.expectEqual(@as(usize, 1), app.chord.len); // armed, not swallowed
    try app.handle(.{ .key = Key.char('z') });
    try t.expect(!app.zen);
    try t.expectEqualStrings("", app.panes.get(req).?.request.url.items);
    try t.expectEqual(@as(usize, 0), app.chord.len);
    // Esc Esc from the request pane.
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.zen);
    try t.expectEqualStrings("Esc again leaves full screen · :fullscreen · Ctrl+K Z", lastToast(&app));
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.zen);
    // A terminal pane: the chord and Esc Esc both work there too.
    const pty_pane = @import("pty_pane.zig");
    if (!pty_pane.supported) return;
    const term = try pty_pane.open(&app, .{ .argv = &.{"/bin/cat"}, .label = "cat", .kind = .command });
    try t.expectEqual(term, app.active.?);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try app.handle(.{ .key = Key.ctrl('k') });
    try app.handle(.{ .key = Key.char('z') });
    try t.expect(!app.zen);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.zen);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.zen);
}

test "zen: the palette's full-screen row reads Enter outside and Exit inside" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const row = @intFromEnum(command.CommandId.@"view.fullscreen");
    try command.run(&app, .{ .static = .palette });
    try t.expectEqualStrings("view  ·  Enter full screen  ·  view.fullscreen", app.overlay.picker.labels[row]);
    try app.handle(.{ .key = Key.named(.esc) });
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try command.run(&app, .{ .static = .palette });
    // `view.fullscreen` just ran, so its row is a ★-marked recent.
    try t.expectEqualStrings("★ view  ·  Exit full screen  ·  view.fullscreen", app.overlay.picker.labels[row]);
}

test "zen: the corner mark paints at the body's top-right while inside, is a button whose click leaves, and is gone outside" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const render = @import("render.zig");
    const bufferline = @import("../ui/bufferline.zig");
    try app.render();
    try t.expect(if (app.hits.at(99, 0)) |h| (h != .button or h.button != @intFromEnum(render.Button.fullscreen_exit)) else true);
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try app.render();
    const cell = app.screen.readCell(99, 0).?;
    try t.expectEqualStrings(bufferline.restore_glyph, cell.char.grapheme);
    try t.expectEqual(@as(u32, @intFromEnum(render.Button.fullscreen_exit)), app.hits.at(99, 0).?.button);
    // `--ascii`: the twin.
    app.cfg.ui.ascii_icons = true;
    try app.render();
    try t.expectEqualStrings(bufferline.restore_ascii, app.screen.readCell(99, 0).?.char.grapheme);
    // The click leaves; the mark and its hit go with the frame's return.
    try app.handle(.{ .mouse = .{ .x = 99, .y = 0, .kind = .press, .button = .left } });
    try t.expect(!app.zen);
    try app.render();
    try t.expect(if (app.hits.at(99, 0)) |h| (h != .button or h.button != @intFromEnum(render.Button.fullscreen_exit)) else true);
}

test "zen: the editor and tab context menus end with Exit full screen while inside, not outside" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    const context_menus = @import("context_menus.zig");
    try context_menus.openEditorMenu(&app, 5, 5);
    var last = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expectEqualStrings("Save", last.label);
    try app.handle(.{ .key = Key.named(.esc) });
    try command.run(&app, .{ .static = .@"view.fullscreen" });
    try context_menus.openEditorMenu(&app, 5, 5);
    last = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expectEqualStrings("Exit full screen", last.label);
    try t.expectEqual(command.CommandId.@"view.fullscreen", last.action.command);
    try t.expect(last.separator_before);
    try app.handle(.{ .key = Key.named(.esc) });
    try context_menus.openTabMenu(&app, id, 5, 5);
    last = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expectEqualStrings("Exit full screen", last.label);
    // Its row runs the command: the menu's last row, Enter.
    app.overlay.menu.cursor = app.overlay.menu.items.len - 1;
    app.overlay.menu.highlight = true;
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!app.zen);
}
