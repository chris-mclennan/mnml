//! `term.*` runners and the `:term` line: shells in the four halves,
//! a command in a pane, paste / clear / restart on the active pty,
//! `:rename` for the tab label, and the scratch strip — one shell per
//! workspace that `term.scratch_toggle` shows below the active pane,
//! hides when it has the focus, and focuses when it is merely visible
//! (VS Code's `` Ctrl+` ``). Hidden means out of the layout but alive
//! in the store: the shell keeps its history across toggles.

const std = @import("std");
/// The one "does this pane have the keys" (`render.paneFocused`).
const paneFocused = @import("render.zig").paneFocused;
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty_pane = @import("pty_pane.zig");
const pty = @import("pty");
const sessions = @import("../sessions.zig");

pub const table = .{
    .@"term.shell" = &shellRight,
    .@"term.shell_left" = &shellLeft,
    .@"term.shell_right" = &shellRight,
    .@"term.shell_top" = &shellTop,
    .@"term.shell_bottom" = &shellBottom,
    .@"term.focus_or_open_shell" = &focusOrOpen,
    .@"term.paste" = &pasteClipboard,
    .@"term.copy" = &copySelection,
    .@"term.prev_prompt" = &prevPrompt,
    .@"term.next_prompt" = &nextPrompt,
    .@"term.clear" = &clear,
    .@"term.restart" = &restart,
    .@"term.rename" = &rename,
    .@"term.scratch_toggle" = &scratchToggle,
};

fn shell(app: *App, placement: pty_pane.Placement) CommandError!void {
    _ = try pty_pane.open(app, .{ .placement = placement, .kind = .shell });
}

fn shellRight(app: *App) CommandError!void {
    return shell(app, .right);
}
fn shellLeft(app: *App) CommandError!void {
    return shell(app, .left);
}
fn shellTop(app: *App) CommandError!void {
    return shell(app, .above);
}
fn shellBottom(app: *App) CommandError!void {
    return shell(app, .below);
}

/// The first live shell pane gets focus; none → a new one below.
fn focusOrOpen(app: *App) CommandError!void {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .pty => |*term| if (term.kind == .shell and term.exit == null) {
            app.showPane(@intCast(i));
            return;
        },
        else => {},
    };
    return shell(app, .below);
}

fn activePty(app: *App) CommandError!*pty_pane.PtyPane {
    const id = app.active orelse return error.NoActivePane;
    return app.panes.pty(id) orelse app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
}

fn pasteClipboard(app: *App) CommandError!void {
    const p = try activePty(app);
    const text = app.clipboard.text();
    if (text.len == 0) return app.diag.fail(app.frame.allocator(), "clipboard is empty", .{});
    try pty_pane.paste(app, p, text);
}

/// The mouse selection (drag, double-click a word, triple a line) to
/// the clipboard — what a release already did, again from the menu.
fn copySelection(app: *App) CommandError!void {
    const p = try activePty(app);
    if (!try pty_pane.copySelection(app, p)) return app.diag.fail(app.frame.allocator(), "nothing is selected — drag across the text first", .{});
}

fn prevPrompt(app: *App) CommandError!void {
    return jump(app, -1);
}
fn nextPrompt(app: *App) CommandError!void {
    return jump(app, 1);
}
fn jump(app: *App, delta: isize) CommandError!void {
    const p = try activePty(app);
    if (!pty_pane.jumpPrompt(app, p, delta)) return app.diag.fail(app.frame.allocator(), "no {s} prompt — the shell marks them with OSC 133 (the mnml prompt does)", .{if (delta < 0) "earlier" else "later"});
}

fn clear(app: *App) CommandError!void {
    const p = try activePty(app);
    p.write("\x0c");
}

fn restart(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    _ = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
    try pty_pane.restart(app, id);
}

// ─── rename ─────────────────────────────────────────────────────────────

/// `term.rename`: a prompt seeded with the current label.
fn rename(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
    // A Claude / Codex pane's name is its session's: the card and the tab.
    if (try sessions.renamePane(app, id)) return;
    var state = app_mod.Prompt.init(app.gpa, "Rename session");
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.setText(app.gpa, p.tabTitle());
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .term_rename = id } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `:rename <name>` names the active pty outright; bare `:rename` prompts.
pub fn renameEx(app: *App, args: []const u8) CommandError!void {
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0) return rename(app);
    const id = app.active orelse return error.NoActivePane;
    if (try sessions.renamePaneTo(app, id, name)) return;
    return renameAccept(app, id, name);
}

/// The prompt's answer: the pane's label, if the pane is still a pty.
pub fn renameAccept(app: *App, id: PaneId, text: []const u8) CommandError!void {
    const name = std.mem.trim(u8, text, " \t");
    if (name.len == 0) return app.diag.fail(app.frame.allocator(), "the name is empty", .{});
    const p = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "that terminal is gone", .{});
    const copy = try app.gpa.dupe(u8, name);
    app.gpa.free(p.label);
    p.label = copy;
    // The user's name outranks the one the child sets.
    p.renamed = true;
    app.needs_render = true;
}

// ─── the scratch strip ──────────────────────────────────────────────────

/// The live scratch pane, if the id still names one (the slot may have
/// been reused by another pane since it was closed).
fn scratchPane(app: *App) ?PaneId {
    const id = app.scratch_pty orelse return null;
    if (app.panes.pty(id)) |p| if (p.kind == .scratch) return id;
    app.scratch_pty = null;
    return null;
}

/// Focused → hide (out of the layout, still alive); visible → focus;
/// hidden or never opened → show below the active pane.
fn scratchToggle(app: *App) CommandError!void {
    if (scratchPane(app)) |id| {
        const layout = app.layouts.current();
        const shown = layout.leafOf(id) != null;
        if (shown and paneFocused(app, id)) {
            const next = layout.removePane(id);
            app.afterSplitChange();
            const fallback: ?PaneId = next orelse if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
            app.active = null;
            app.setActive(fallback);
            return;
        }
        if (shown) {
            app.showPane(id);
            return;
        }
        if (app.active) |a| app.setActive(a);
        try pty_pane.place(app, id, .below);
        return;
    }
    const id = try pty_pane.open(app, .{ .placement = .below, .kind = .scratch, .label = "scratch" });
    app.scratch_pty = id;
}

/// `:term` opens a shell below; `:term <cmd…>` runs the line through
/// the platform's shell (`sh -c`, `cmd /d /c`) with the line as the tab
/// label.
pub fn termEx(app: *App, args: []const u8) CommandError!void {
    const line = std.mem.trim(u8, args, " \t");
    if (line.len == 0) return shell(app, .below);
    var shell_buf: [4][]const u8 = undefined;
    _ = try pty_pane.open(app, .{
        .argv = pty.shellArgv(&shell_buf, &app.env, line),
        .label = line,
        .placement = .below,
        .kind = .command,
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "headless smoke: `:term printf hi` opens a pane below the editor and the grid shows hi" {
    // `printf` and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try app.runEx("term printf hi");
    const id = app.active.?;
    try t.expect(id != ed);
    try t.expectEqualStrings("printf hi", app.panes.get(id).?.title());
    // Two leaves: the scratch editor on top, the terminal below.
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(try pty_pane.tickUntilScreen(&app, "hi", 5000));
    try t.expect(try pty_pane.tickUntilScreen(&app, "[exited 0]", 5000));
    // The buffers picker lists it with the [term] marker.
    try command.run(&app, .{ .static = .@"picker.buffers" });
    var seen = false;
    for (app.overlay.picker.labels) |l| if (std.mem.eql(u8, l, "printf hi [term]")) {
        seen = true;
    };
    try t.expect(seen);
}

test "term.shell opens the login shell beside the active pane; focus_or_open_shell finds it again" {
    // `printf` and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"term.shell" });
    const sh = app.active.?;
    try t.expect(sh != ed);
    try t.expect(app.panes.pty(sh).?.kind == .shell);
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"term.focus_or_open_shell" });
    try t.expectEqual(sh, app.active.?);
    try t.expectEqual(@as(usize, 2), app.panes.count());
}

test "a child's OSC 2 title names its tab until the user renames it" {
    // `printf` and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try app.runEx("term printf '\\033]2;build-watch\\007'; read x; printf '\\033]0;second\\007'; sleep 30");
    const id = app.active.?;
    try t.expect(try pty_pane.tickUntilScreen(&app, "build-watch", 5000));
    try t.expectEqualStrings("build-watch", app.panes.get(id).?.title());
    // The user's name wins from here on, whatever the child sets next.
    try app.runEx("rename mine");
    try t.expectEqualStrings("mine", app.panes.get(id).?.title());
    try app.handle(.{ .key = @import("../core/key.zig").Key.named(.enter) });
    try t.expect(try pty_pane.tickUntilScreen(&app, "mine", 5000));
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 20) {
        try app.tick(App.nowMs(app.io));
        const p = app.panes.pty(id).?;
        if (p.childTitle()) |ct| if (std.mem.eql(u8, ct, "second")) break;
        app.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    try t.expectEqualStrings("second", app.panes.pty(id).?.childTitle().?);
    try t.expectEqualStrings("mine", app.panes.get(id).?.title());
}

test "term.rename relabels the tab through the prompt and through :rename" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command });
    try command.run(&app, .{ .static = .@"term.rename" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("sh", app.overlay.prompt.state.text());
    try t.expectEqual(id, app.overlay.prompt.purpose.term_rename);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try renameAccept(&app, id, "  build ");
    try t.expectEqualStrings("build", app.panes.get(id).?.title());
    try app.runEx("rename deploy");
    try t.expectEqualStrings("deploy", app.panes.get(id).?.title());
    try t.expectError(error.Failed, renameAccept(&app, id, " "));
    // An editor is not a terminal.
    _ = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"term.rename" }));
}

test "a file opened while the scratch strip has the focus opens in the editor area; hiding the strip leaves no split behind" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 14 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const layout = app.layouts.current();
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    const sc = app.scratch_pty.?;
    try t.expectEqual(sc, app.active.?);
    // Ctrl+P from the strip: the file lands beside `ed`, not beside the shell.
    const b = try app.openPath("/tmp/mnml-zig-strip-b.txt");
    try t.expectEqual(b, app.active.?);
    try t.expectEqual(layout.leafOf(ed).?, layout.leafOf(b).?);
    try t.expectEqual(@as(usize, 1), layout.leaf(layout.leafOf(sc).?).?.tabs.items.len);
    // Ctrl+` twice (focus the strip, then hide it): one leaf, both files in it.
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(layout.leafOf(sc) == null);
    try t.expectEqual(b, app.active.?);
    // A terminal opened from the strip may still share it.
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expectEqual(sc, app.active.?);
    // The strip alone on screen: the file takes a leaf above it.
    try app.forceClosePane(ed);
    try app.forceClosePane(b);
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    app.setActive(sc);
    const c = try app.openPath("/tmp/mnml-zig-strip-c.txt");
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(layout.leafOf(c).? != layout.leafOf(sc).?);
    try t.expectEqual(c, app.active.?);
}

test "term.scratch_toggle: open below, hide when focused, focus when visible, show again alive" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 14 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    const sc = app.scratch_pty.?;
    try t.expectEqual(sc, app.active.?);
    try t.expect(app.panes.pty(sc).?.kind == .scratch);
    try t.expectEqualStrings("scratch", app.panes.get(sc).?.title());
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    // Focused: hide. The pane stays in the store.
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(layout.leafOf(sc) == null);
    try t.expect(app.panes.pty(sc) != null);
    try t.expectEqual(ed, app.active.?);
    // Hidden: back below, the same pane.
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expectEqual(sc, app.active.?);
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    try t.expectEqual(sc, app.scratch_pty.?);
    // Visible but not focused: focus it.
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expectEqual(sc, app.active.?);
    // Closed for good: the next toggle opens a fresh one.
    try app.forceClosePane(sc);
    try command.run(&app, .{ .static = .@"term.scratch_toggle" });
    try t.expect(app.scratch_pty != null);
    try t.expect(app.panes.pty(app.scratch_pty.?).?.kind == .scratch);
}
