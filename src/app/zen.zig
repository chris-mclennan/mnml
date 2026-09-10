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

pub const table = .{
    .@"view.fullscreen" = &toggle,
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
