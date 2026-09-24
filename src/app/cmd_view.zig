//! `view.*` and `theme.*` runners: wrap and gutter toggles, splits and
//! split focus, viewport scrolling, the right panel, the read-only
//! overlays (welcome / about / discovery, drawn here beside the commands
//! that open them), and the theme picker with its toggle / reset /
//! follow-the-OS companions. Tab pages are `cmd_tab.zig`; the settings
//! overlay is `settings.zig` + `ui/settings.zig`.

const std = @import("std");
const welcome_app = @import("welcome.zig");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = app_mod.Config;
const Layout = app_mod.Layout;
const layout_mod = @import("layout.zig");
const activity_bar = @import("activity_bar.zig");
const side = @import("side.zig");
const sidebar_auto = @import("sidebar_auto.zig");
const bottom_dock = @import("bottom.zig");
const http_panel = @import("http_panel.zig");
const http_app = @import("http.zig");
const git_palette = @import("git_palette.zig");
const pty_pane = @import("pty_pane.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const overlay_mod = @import("../ui/overlay.zig");
const cmd_picker = @import("cmd_picker.zig");
const settings = @import("settings.zig");
const input = @import("../input/mod.zig");
const build_options = @import("build_options");

pub const table = .{
    .@"view.toggle_wrap" = &toggleWrap,
    .@"view.toggle_line_numbers" = &toggleLineNumbers,
    .@"view.toggle_scrollbar" = &toggleScrollbar,
    .@"view.split_right" = &splitRight,
    .@"view.split_down" = &splitDown,
    .@"view.focus_left" = &focusLeft,
    .@"view.focus_right" = &focusRight,
    .@"view.focus_up" = &focusUp,
    .@"view.focus_down" = &focusDown,
    .@"view.focus_next_split" = &focusNextSplit,
    .@"view.focus_prev_split" = &focusPrevSplit,
    .@"view.focus_top" = &focusTop,
    .@"view.focus_bottom" = &focusBottom,
    .@"view.focus_previous" = &focusPrevious,
    .@"view.close_split" = &closeSplit,
    .@"view.close_others" = &closeOthers,
    .@"view.toggle_auto_equalize_splits" = &toggleAutoEqualize,
    .@"view.only" = &only,
    .@"view.keep_tab" = &keepTab,
    .@"view.equalize_splits" = &equalizeSplits,
    .@"layout.merge_to_tabs" = &mergeToTabs,
    .@"layout.spread_to_splits" = &spreadToSplits,
    .@"view.focus_pane" = &focusPane,
    .@"view.cursor_to_center" = &cursorToCenter,
    .@"view.cursor_to_top" = &cursorToTop,
    .@"view.cursor_to_bottom" = &cursorToBottom,
    .@"view.scroll_buffer_down" = &scrollDown,
    .@"view.scroll_buffer_up" = &scrollUp,
    .@"view.redraw" = &redraw,
    .@"view.reset_tree_width" = &resetTreeWidth,
    .@"view.toggle_right_panel" = &toggleRightPanel,
    .@"view.right_panel_next_tab" = &rightPanelNext,
    .@"view.right_panel_prev_tab" = &rightPanelPrev,
    .@"view.focus_tab_1" = focusTabRunner(1),
    .@"view.focus_tab_2" = focusTabRunner(2),
    .@"view.focus_tab_3" = focusTabRunner(3),
    .@"view.focus_tab_4" = focusTabRunner(4),
    .@"view.focus_tab_5" = focusTabRunner(5),
    .@"view.focus_tab_6" = focusTabRunner(6),
    .@"view.focus_tab_7" = focusTabRunner(7),
    .@"view.focus_tab_8" = focusTabRunner(8),
    .@"view.focus_tab_last" = &focusTabLast,
    .@"view.move_cursor_view_top" = &cursorViewTop,
    .@"view.move_cursor_view_middle" = &cursorViewMiddle,
    .@"view.move_cursor_view_bottom" = &cursorViewBottom,
    .@"view.hscroll_left" = &hscrollLeft,
    .@"view.hscroll_right" = &hscrollRight,
    .@"view.hscroll_left_half" = &hscrollLeftHalf,
    .@"view.hscroll_right_half" = &hscrollRightHalf,
    .@"view.help" = &help,
    .@"view.split_new_scratch" = &splitNewScratch,
    .@"view.split_goto_definition" = &splitGotoDefinition,
    .@"view.split_open_file_under_cursor" = &splitOpenFileUnderCursor,
    .@"view.split_grow_width" = &splitGrowWidth,
    .@"view.split_shrink_width" = &splitShrinkWidth,
    .@"view.split_grow_height" = &splitGrowHeight,
    .@"view.split_shrink_height" = &splitShrinkHeight,
    .@"view.maximize_width" = &maximizeWidth,
    .@"view.maximize_height" = &maximizeHeight,
    .@"view.rotate_splits" = &rotateSplits,
    .@"view.move_split_left" = &moveSplitLeft,
    .@"view.move_split_right" = &moveSplitRight,
    .@"view.move_split_up" = &moveSplitUp,
    .@"view.move_split_down" = &moveSplitDown,
    .@"view.focus_right_panel" = &focusRightPanel,
    .@"view.right_panel_close_tab" = &closeRightPanel,
    .@"view.activity_todos" = &activityTodos,
    .@"project.todos" = &activityTodos,
    .@"view.toggle_sticky_context" = &toggleStickyContext,
    .@"view.toggle_auto_md_preview" = &toggleAutoMdPreview,
    .@"view.activity_notes" = &activityNotes,
    .@"view.activity_findings" = &activityFindings,
    .@"view.activity_sessions" = &activitySessions,
    .@"view.activity_http" = &activityHttp,
    .@"view.activity_git" = &activityGit,
    .@"view.activity_explorer" = &activityExplorer,
    .@"view.welcome" = &welcome,
    .@"view.about" = &about,
    .@"view.discovery" = &discovery,
    .@"view.settings" = &openSettings,
    .@"view.settings_search" = &openSettingsSearch,
    .@"view.cmdline_history" = &cmdlineHistory,
    // changed: `editor.toggle_keymap` is the statusline mode chip's
    // click; it lives with the view code because that is who calls it.
    .@"editor.toggle_keymap" = &toggleKeymap,
    .@"first_launch.show" = &showFirstLaunch,
    .@"theme.pick" = &pickTheme,
    .@"theme.toggle" = &toggleTheme,
    .@"theme.reset" = &resetTheme,
    .@"theme.auto_system" = &autoSystemTheme,
    .@"theme.auto_system_off" = &autoSystemThemeOff,
    .@"view.reveal_active" = &revealActive,
    .@"view.toggle_integrations_section" = &toggleIntegrationsSection,
    .@"view.workspace_menu" = &workspaceMenu,
    .@"view.commands_reference" = &commandsReference,
    // The click inspector reads the hit map the mouse dispatch reads;
    // the toggle lives here with the other view debugging toggles.
    .@"debug.toggle_click_inspector" = &toggleClickInspector,
};

// ─── reveal / sections / menus ──────────────────────────────────────────

/// The argv that shows `path` in the OS file manager: macOS `open -R`,
/// Windows `explorer /select,`, elsewhere `xdg-open` on the parent —
/// the nearest portable form, no desktop-agnostic "select this file"
/// gesture existing there.
pub fn revealArgv(arena: std.mem.Allocator, path: []const u8, os: std.Target.Os.Tag) std.mem.Allocator.Error![]const []const u8 {
    return switch (os) {
        .macos => try arena.dupe([]const u8, &.{ "open", "-R", path }),
        .windows => try arena.dupe([]const u8, &.{ "explorer", try std.fmt.allocPrint(arena, "/select,{s}", .{path}) }),
        else => try arena.dupe([]const u8, &.{ "xdg-open", std.fs.path.dirname(path) orelse path }),
    };
}

/// `view.reveal_active`: the active pane's file in the OS file manager
/// (`view.reveal_in_tree` is the in-app counterpart).
fn revealActive(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = app.active orelse return app.diag.fail(arena, "no file to reveal", .{});
    const p = app.panes.get(id) orelse return app.diag.fail(arena, "no file to reveal", .{});
    const path: ?[]const u8 = switch (p.*) {
        .editor => |*e| e.buf.doc.path,
        .md_preview => |*m| m.path,
        else => null,
    };
    const abs = path orelse return app.diag.fail(arena, "no file to reveal", .{});
    @import("git.zig").runArgv(app, try revealArgv(arena, abs, builtin.os.tag), "the file manager");
}

/// `view.keep_tab`: the active preview tab stops being one, so the
/// next glance in this leaf opens beside it instead of taking it over
/// — VS Code's "Keep Open" (`ctrl+k enter`), and `<leader>b k` in the
/// vim profile, where the tree click that made a preview is the only
/// way to get one at all.
fn keepTab(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(id) orelse return error.NoActivePane;
    if (!pane.preview()) return app.diag.fail(arena, "{s} is already a tab of its own", .{pane.title()});
    pane.setPreview(false);
    app.toast("keeping {s}", .{pane.title()});
    app.needs_render = true;
}

/// `view.toggle_integrations_section`: the INTEGRATIONS column closes
/// or opens, the keys staying where they are (Rust toggles silently).
fn toggleIntegrationsSection(app: *App) CommandError!void {
    if (side.isShown(app, .integrations)) return side.hide(app, .integrations);
    try side.open(app, .integrations, false);
}

/// `view.workspace_menu`: the statusline workspace chip's menu, anchored
/// on the chip as the last frame painted it (the row above it, as a
/// right-click opens it), or at the origin when the chip is off screen.
fn workspaceMenu(app: *App) CommandError!void {
    const statusline_app = @import("statusline.zig");
    var x: u16 = 0;
    var y: u16 = 0;
    for (app.hits.items.items) |e| if (e.target == .statusline_seg and e.target.statusline_seg == statusline_app.SegId.workspace.raw()) {
        x = e.rect.x;
        y = e.rect.y -| 1;
    };
    try @import("context_menus.zig").openWorkspaceChipMenu(app, x, y);
}

/// `view.commands_reference`: the page `zig build docs` writes, as a
/// scratch buffer.
fn commandsReference(app: *App) CommandError!void {
    const reference = @import("../commands/reference.zig");
    const arena = app.frame.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    reference.render(arena, &out.writer) catch return error.OutOfMemory;
    _ = app.openScratchWith(out.written()) catch return error.OutOfMemory;
    app.toast("commands reference: {d} commands", .{command.count});
}

/// `debug.toggle_click_inspector`: the next presses toast what they
/// land on (`dispatch.inspectClick`).
fn toggleClickInspector(app: *App) CommandError!void {
    app.debug_click_inspector = !app.debug_click_inspector;
    app.toast("{s}", .{if (app.debug_click_inspector) "click inspector: ON — next click toasts the hit target" else "click inspector: OFF"});
}

fn toggleWrap(app: *App) CommandError!void {
    if (app.activeEditor()) |e| {
        const on = !(e.wrap orelse app.cfg.ui.wrap);
        e.wrap = on;
        app.toast("wrap {s}", .{if (on) "on" else "off"});
    } else {
        app.cfg.ui.wrap = !app.cfg.ui.wrap;
        app.toast("wrap {s}", .{if (app.cfg.ui.wrap) "on" else "off"});
    }
    app.needs_render = true;
}

fn toggleLineNumbers(app: *App) CommandError!void {
    app.cfg.ui.line_numbers = !app.cfg.ui.line_numbers;
    app.toast("line numbers {s}", .{if (app.cfg.ui.line_numbers) "on" else "off"});
    app.needs_render = true;
}

fn toggleScrollbar(app: *App) CommandError!void {
    app.cfg.ui.scrollbar = !app.cfg.ui.scrollbar;
    app.toast("scrollbar {s}", .{if (app.cfg.ui.scrollbar) "on" else "off"});
    app.needs_render = true;
}

fn redraw(app: *App) CommandError!void {
    app.needs_render = true;
}

fn toggleStickyContext(app: *App) CommandError!void {
    app.cfg.ui.sticky_context = !app.cfg.ui.sticky_context;
    app.toast("sticky context: {s}", .{if (app.cfg.ui.sticky_context) "on" else "off"});
    app.needs_render = true;
}

fn toggleAutoMdPreview(app: *App) CommandError!void {
    app.cfg.ui.auto_md_preview = !app.cfg.ui.auto_md_preview;
    app.toast("auto-preview md: {s}", .{if (app.cfg.ui.auto_md_preview) "on" else "off"});
    app.needs_render = true;
}

fn resetTreeWidth(app: *App) CommandError!void {
    app.tree.width = @import("tree.zig").default_width;
    app.needs_render = true;
}

fn toggleKeymap(app: *App) CommandError!void {
    const next: input.Style = if (app.input_style == .vim) .standard else .vim;
    try app.setInputStyle(next);
    app.toast("keymap: {s}", .{@tagName(next)});
}

// ─── the columns ────────────────────────────────────────────────────────
// Every section has a side (`app/side.zig`); `activity_<x>` places the
// section in its column and focuses it. The `right_panel_*` ids kept
// their names: they act on the right column.

fn toggleRightPanel(app: *App) CommandError!void {
    // // changed (sidebar-autohide): the right column's overlay, on the
    // same rule as `view.toggle_tree`'s.
    if (sidebar_auto.keyboardReach(app, .right, true)) return;
    return side.toggleColumn(app, .right);
}

fn focusRightPanel(app: *App) CommandError!void {
    if (side.shown(app, .right) == null) try side.toggleColumn(app, .right);
    if (side.shown(app, .right)) |s| side.focusSection(app, s);
}

fn closeRightPanel(app: *App) CommandError!void {
    side.hideColumn(app, .right);
}

fn activityTodos(app: *App) CommandError!void {
    activity_bar.enter(app, .todos);
    side.place(app, .todos, true);
}

fn activityNotes(app: *App) CommandError!void {
    activity_bar.enter(app, .notes);
    side.place(app, .notes, true);
}

fn activityFindings(app: *App) CommandError!void {
    activity_bar.enter(app, .findings);
    side.place(app, .findings, true);
}

fn activitySessions(app: *App) CommandError!void {
    activity_bar.enter(app, .sessions);
    side.place(app, .sessions, true);
}

fn activityExplorer(app: *App) CommandError!void {
    activity_bar.enter(app, .explorer);
    side.place(app, .explorer, true);
}

/// Panels whose module is a later phase: say so, change nothing.
fn notInBuild(app: *App, what: []const u8) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "{s} panel: not in this build yet", .{what});
}

fn activityHttp(app: *App) CommandError!void {
    activity_bar.enter(app, .http);
    side.place(app, .http, true);
    // Rust's `entering_http`: a blank request pane in the centre when no
    // request pane is active.
    try http_panel.enter(app);
}

/// Git mode (`app/git_palette.zig`): the palette in the sidebar, one
/// graph tab per repo.
fn activityGit(app: *App) CommandError!void {
    try git_palette.enter(app);
}

// ─── splits ─────────────────────────────────────────────────────────────

/// A new leaf beside the active one. `pane` fills it; null puts a
/// companion of the active pane there (`splitCompanion`), so every
/// pane kind splits (vim `:split`; Rust's `split_active`).
pub fn splitWith(app: *App, dir: layout_mod.SplitDir, pane: ?PaneId) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    if (layout.leafOf(cur) == null) return error.NoActivePane;
    const id: PaneId = pane orelse try splitCompanion(app, cur);
    // Never the pane itself: taking it out of its leaf below would
    // empty the leaf, and a pane in no leaf cannot be split — the file
    // gone from both halves (a rendered markdown tab did this on
    // 2026-09-22, its companion having come back as the tab itself).
    if (id == cur) return app.diag.fail(app.frame.allocator(), "split: {s} has nothing to split with", .{app.panes.get(cur).?.title()});
    // A companion that was shown on its way in leaves the leaf it
    // landed in; the split puts it in the new one.
    _ = layout.removePane(id);
    _ = try layout.split(cur, dir, id);
    // Splitting a preview tab keeps it (VS Code promotes the tab a
    // split is made from), and the companion is a kept tab too — a
    // glance elsewhere takes over neither half. A pane the caller
    // hands in (a drag, `files.open_split`) is left as it came.
    if (pane == null) {
        if (app.panes.get(cur)) |p| p.setPreview(false);
        if (app.panes.get(id)) |p| p.setPreview(false);
    }
    app.afterSplitChange();
    app.setActive(id);
}

/// What the other half of a split starts as, by the active pane's
/// kind — Rust's `split_active`: an editor is duplicated (the same
/// document, its own cursor); a markdown preview gets its file's source
/// editor; a request pane gets a blank request beside it, the caret on
/// the URL; anything else (a terminal, a graph, a list…) gets a scratch
/// editor, so the split is never refused.
fn splitCompanion(app: *App, cur: PaneId) CommandError!PaneId {
    const p = app.panes.get(cur) orelse return error.NoActivePane;
    switch (p.*) {
        .editor => return app.duplicatePane(cur) catch |err| splitFail(app, err),
        // The source, not `openPath`: a markdown file routes back to
        // its rendered tab — this one — and the split would have had
        // nothing to put beside it. An editor already open on the file
        // is duplicated rather than pulled out of its own leaf.
        .md_preview => |*m| {
            const path = try app.frame.allocator().dupe(u8, m.path);
            if (app.panes.findPath(path)) |eid| return app.duplicatePane(eid) catch |err| splitFail(app, err);
            return app.openEditor(path) catch |err| splitFail(app, err);
        },
        .request => return http_app.openBlank(app),
        else => return app.openScratch() catch |err| splitFail(app, err),
    }
}

/// The companion could not be made: the reason as a sentence.
fn splitFail(app: *App, err: anyerror) CommandError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return app.diag.fail(app.frame.allocator(), "split: {s}", .{command.reason(err)});
}

/// `view.toggle_auto_equalize_splits`: flip `ui.auto_equalize_splits`,
/// persist it, and even the splits out at once when it went on.
fn toggleAutoEqualize(app: *App) CommandError!void {
    app.cfg.ui.auto_equalize_splits = !app.cfg.ui.auto_equalize_splits;
    _ = try settings.persist(app, .workspace, &.{ "ui", "auto_equalize_splits" }, app.cfg.ui.auto_equalize_splits);
    app.afterSplitChange();
    app.toast("auto-equalize splits: {s}", .{if (app.cfg.ui.auto_equalize_splits) "on" else "off"});
    app.needs_render = true;
}

fn splitRight(app: *App) CommandError!void {
    return splitWith(app, .horizontal, null);
}

fn splitDown(app: *App) CommandError!void {
    return splitWith(app, .vertical, null);
}

const Dir = enum { left, right, up, down };

/// The leaf whose rect is the nearest neighbour of the active one in
/// `dir`, by the rects the last frame gave the split tree. The sidebar
/// counts as the leftmost window (NvChad's nvim-tree is one): left from
/// the leftmost split enters it, right from it returns to the split.
fn focusDir(app: *App, dir: Dir) CommandError!void {
    // // changed (bottom-dock): the dock is a window under everything
    // else, so `Ctrl-W j` steps down into it from any of them and
    // `Ctrl-W k` steps back up to the panes.
    if (bottom_dock.focused(app)) {
        if (dir == .up) leaveDock(app);
        return;
    }
    if (dir == .down and bottom_dock.open(app) and app.focus != .pane) return enterDock(app);
    // // changed (welcome): with the layout empty the start surface is
    // the one window: right from the tree enters it, left leaves it.
    if (welcome_app.full(app)) {
        if (app.focus == .tree and dir == .right) welcome_app.focus(app);
        if (app.focus == .welcome and dir == .left and app.tree.visible) {
            app.focus = .tree;
            app.needs_render = true;
        }
        return;
    }
    const cur = app.active orelse return error.NoActivePane;
    if (app.focus == .tree) {
        if (dir == .right) {
            app.focus = .{ .pane = cur };
            app.needs_render = true;
        }
        return;
    }
    const layout = app.layouts.current();
    const arena = app.frame.allocator();
    const body = if (app.panes_area.isEmpty()) Rect.init(0, 1, app.screen.width, app.screen.height -| 2) else app.panes_area;
    const rects = try layout.computeRects(body, arena);
    var mine: ?Rect = null;
    for (rects.panes) |pr| if (pr.pane == cur) {
        mine = pr.rect;
    };
    const m = mine orelse return;
    var best: ?layout_mod.PaneRect = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (rects.panes) |pr| {
        if (pr.pane == cur) continue;
        const r = pr.rect;
        const ok = switch (dir) {
            .left => r.right() <= m.x and overlaps(r.y, r.bottom(), m.y, m.bottom()),
            .right => r.x >= m.right() and overlaps(r.y, r.bottom(), m.y, m.bottom()),
            .up => r.bottom() <= m.y and overlaps(r.x, r.right(), m.x, m.right()),
            .down => r.y >= m.bottom() and overlaps(r.x, r.right(), m.x, m.right()),
        };
        if (!ok) continue;
        const d: u32 = switch (dir) {
            .left => m.x - r.right(),
            .right => r.x - m.right(),
            .up => m.y - r.bottom(),
            .down => r.y - m.bottom(),
        };
        if (d < best_d) {
            best_d = d;
            best = pr;
        }
    }
    const target = best orelse {
        if (dir == .left and app.tree.visible) {
            app.focus = .tree;
            app.needs_render = true;
        }
        // Nothing below in the split tree: the dock is what is below.
        if (dir == .down and bottom_dock.open(app)) enterDock(app);
        return;
    };
    app.setActive(target.pane);
}

/// The keys go into the dock: its hosted pane, else its section.
/// // changed (bottom-dock).
fn enterDock(app: *App) void {
    if (bottom_dock.activePane(app)) |p| return app.setActive(p);
    if (side.shown(app, .bottom)) |s| side.focusSection(app, s);
}

/// The keys leave the dock for the panes — the most recent one still in
/// the split tree, else the first leaf. // changed (bottom-dock).
fn leaveDock(app: *App) void {
    const layout = app.layouts.current();
    for (app.pane_mru.items) |p| if (layout.leafOf(p) != null) return app.setActive(p);
    if (layout.firstLeaf()) |first| if (layout.leaf(first)) |l| return app.setActive(l.active);
    // The dock holds the only pane: the keys go to a column instead.
    for ([_]side.Side{ .left, .right }) |c| if (side.shown(app, c)) |sec| return side.focusSection(app, sec);
    app.needs_render = true;
}

fn overlaps(a0: u16, a1: u16, b0: u16, b1: u16) bool {
    return a0 < b1 and b0 < a1;
}

fn focusLeft(app: *App) CommandError!void {
    return focusDir(app, .left);
}
fn focusRight(app: *App) CommandError!void {
    return focusDir(app, .right);
}
fn focusUp(app: *App) CommandError!void {
    return focusDir(app, .up);
}
fn focusDown(app: *App) CommandError!void {
    return focusDir(app, .down);
}

/// `Ctrl-W w`: the next leaf, and past the last one the sidebar when it
/// is open (vim cycles every window, nvim-tree included).
fn focusNextSplit(app: *App) CommandError!void {
    if (try stepSessionTab(app, .next)) return;
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    // From the sidebar the cycle continues into the first window.
    if (app.focus == .tree and leaves.len > 0) {
        app.setActive(layout.leaf(leaves[0]).?.active);
        app.focus = .{ .pane = app.active orelse cur };
        app.needs_render = true;
        return;
    }
    const mine = layout.leafOf(cur) orelse return;
    const idx = std.mem.indexOfScalar(layout_mod.NodeId, leaves, mine) orelse return;
    if (idx + 1 == leaves.len and app.tree.visible) {
        app.focus = .tree;
        app.needs_render = true;
        return;
    }
    if (leaves.len < 2) return;
    const next = leaves[(idx + 1) % leaves.len];
    app.setActive(layout.leaf(next).?.active);
}

/// `Ctrl-W W`: the same cycle backwards — the previous leaf, and before
/// the first one the sidebar when it is open; from the sidebar the last
/// leaf.
fn focusPrevSplit(app: *App) CommandError!void {
    if (try stepSessionTab(app, .prev)) return;
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    // From the sidebar the cycle continues into the last window.
    if (app.focus == .tree and leaves.len > 0) {
        app.setActive(layout.leaf(leaves[leaves.len - 1]).?.active);
        app.focus = .{ .pane = app.active orelse cur };
        app.needs_render = true;
        return;
    }
    const mine = layout.leafOf(cur) orelse return;
    const idx = std.mem.indexOfScalar(layout_mod.NodeId, leaves, mine) orelse return;
    if (idx == 0 and app.tree.visible) {
        app.focus = .tree;
        app.needs_render = true;
        return;
    }
    if (leaves.len < 2) return;
    const prev = leaves[(idx + leaves.len - 1) % leaves.len];
    app.setActive(layout.leaf(prev).?.active);
}

/// Claude / Codex sessions laid out as tabs (`ui.ai_layout_mode = tabs`)
/// share one leaf, where the split walk has nowhere to go: from a
/// session pane on a one-leaf page the pair steps through that leaf's
/// session tabs instead, in strip order, with wrap. False — the split
/// walk runs — anywhere else, and with fewer than two sessions there.
fn stepSessionTab(app: *App, dir: enum { next, prev }) CommandError!bool {
    if (app.focus != .pane) return false;
    const cur = app.active orelse return false;
    if (!isSessionPane(app, cur)) return false;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len != 1) return false;
    const leaf = layout.leaf(leaves[0]) orelse return false;
    var ring: std.ArrayListUnmanaged(PaneId) = .empty;
    for (leaf.tabs.items) |id| if (isSessionPane(app, id)) try ring.append(app.frame.allocator(), id);
    if (ring.items.len < 2) return false;
    const at = std.mem.indexOfScalar(PaneId, ring.items, cur) orelse return false;
    const n = ring.items.len;
    const to = ring.items[if (dir == .next) (at + 1) % n else (at + n - 1) % n];
    // What a SESSIONS card's Enter does (`sessions.openCmd`).
    app.showPane(to);
    app.focus = .{ .pane = to };
    app.needs_render = true;
    return true;
}

fn isSessionPane(app: *App, id: PaneId) bool {
    const p = app.panes.pty(id) orelse return false;
    return pty_pane.productOf(app, p) != null;
}

/// `Ctrl-W t` / `Ctrl-W b` (`:help CTRL-W_t`): the first / last leaf in
/// layout order — the top-left / bottom-right window.
fn focusEdge(app: *App, last: bool) CommandError!void {
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len == 0) return error.NoActivePane;
    const lid = if (last) leaves[leaves.len - 1] else leaves[0];
    const id = layout.leaf(lid).?.active;
    app.setActive(id);
    app.focus = .{ .pane = id };
    app.needs_render = true;
}

fn focusTop(app: *App) CommandError!void {
    return focusEdge(app, false);
}

fn focusBottom(app: *App) CommandError!void {
    return focusEdge(app, true);
}

/// `Ctrl-W p` (`:help CTRL-W_p`): the window that had the keys before
/// this one — from the sidebar, the active pane; from a pane, the most
/// recently active other pane on this page, else the sidebar when it
/// is open.
fn focusPrevious(app: *App) CommandError!void {
    const layout = app.layouts.current();
    if (app.focus != .pane) {
        const id = app.active orelse return error.NoActivePane;
        app.focus = .{ .pane = id };
        app.needs_render = true;
        return;
    }
    const cur = app.active orelse return error.NoActivePane;
    for (app.pane_mru.items) |id| {
        if (id == cur or app.panes.get(id) == null or layout.leafOf(id) == null) continue;
        app.setActive(id);
        app.focus = .{ .pane = id };
        app.needs_render = true;
        return;
    }
    if (app.tree.visible) {
        app.focus = .tree;
        app.needs_render = true;
        return;
    }
    return app.diag.fail(app.frame.allocator(), "no previous window", .{});
}

/// True when another open pane shows the same document — the pane is
/// a split's window and can go without losing anything, edits included.
fn hasTwin(app: *App, id: PaneId) bool {
    return app.isSharedView(id);
}

/// Drop the active leaf. A window on a document open elsewhere closes
/// (the document stays, with its edits); every other tab stays open in
/// the background. The last window has nothing to fall back to, so its
/// buffer closes instead (a dirty one asks first) — a pty that is the
/// only pane goes with its process, and the layout may be empty
/// afterwards.
fn closeSplit(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len < 2) return app.closePane(cur, false);
    const mine = layout.leafOf(cur) orelse return;
    const tabs = try app.frame.allocator().dupe(PaneId, layout.leaf(mine).?.tabs.items);
    for (tabs) |tab| {
        if (hasTwin(app, tab)) {
            try app.forceClosePane(tab);
        } else _ = layout.removePane(tab);
    }
    app.afterSplitChange();
    const first = layout.firstLeaf() orelse return;
    app.setActive(layout.leaf(first).?.active);
}

/// `:only` / `Ctrl-W o`: every other leaf goes; this window stays with
/// its tabs. Buffers are not closed — a window on a document open
/// elsewhere is dropped (the split made it; the document stays),
/// everything else becomes a background tab of this leaf so the
/// bufferline still lists it.
fn only(app: *App) CommandError!void {
    const keep = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const mine = layout.leafOf(keep) orelse return error.NoActivePane;
    const arena = app.frame.allocator();
    const leaves = try layout.leaves(arena);
    if (leaves.len < 2) return;
    for (leaves) |l| {
        if (l == mine) continue;
        const tabs = try arena.dupe(PaneId, layout.leaf(l).?.tabs.items);
        for (tabs) |tab| {
            if (hasTwin(app, tab)) {
                try app.forceClosePane(tab);
            } else _ = try layout.showIn(mine, tab);
        }
    }
    app.setActive(keep);
    app.needs_render = true;
}

/// Every other pane goes (dirty ones stay, with a toast).
fn closeOthers(app: *App) CommandError!void {
    const keep = app.active orelse return error.NoActivePane;
    var ids: std.ArrayListUnmanaged(PaneId) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.* != null and i != keep) try ids.append(app.frame.allocator(), @intCast(i));
    var skipped: usize = 0;
    for (ids.items) |id| {
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            skipped += 1;
            continue;
        }
        if (p.pinned()) continue;
        try app.forceClosePane(id);
    }
    if (skipped > 0) app.toast("kept {d} buffer(s) with unsaved changes", .{skipped});
}

fn equalizeSplits(app: *App) CommandError!void {
    app.layouts.current().equalize();
    app.needs_render = true;
}

/// `layout.merge_to_tabs`: every pane of this page's split tree becomes
/// a tab of one leaf (`Layout.mergeToTabs`); the active pane keeps the
/// focus. One pane, or one leaf already, is nothing to do.
fn mergeToTabs(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const layout = app.layouts.current();
    const panes = try layout.allPanes(arena);
    if (panes.len <= 1) return app.diag.fail(arena, "layout: nothing to merge", .{});
    const leaves = try layout.leaves(arena);
    if (leaves.len <= 1) return app.diag.fail(arena, "layout: already a single leaf", .{});
    const keep = app.active orelse panes[0];
    const merged = try layout.mergeToTabs(arena, keep);
    app.setActive(layout.leaf(layout.root.?).?.active);
    app.toast("layout: merged {d} splits into {d} tabs", .{ merged, panes.len });
    app.needs_render = true;
}

/// `layout.spread_to_splits`: the inverse — this page must be one leaf
/// with two or more tabs; each tab gets a split of its own
/// (`Layout.spreadToSplits`), the active pane keeping the focus.
fn spreadToSplits(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const layout = app.layouts.current();
    const leaves = try layout.leaves(arena);
    if (leaves.len > 1) return app.diag.fail(arena, "layout: already has splits; merge to tabs first", .{});
    const tabs: usize = if (leaves.len == 1) layout.leaf(leaves[0]).?.tabs.items.len else 0;
    if (tabs <= 1) return app.diag.fail(arena, "layout: nothing to spread", .{});
    const keep = app.active;
    const made = try layout.spreadToSplits(arena);
    if (keep) |k| if (layout.leafOf(k) != null) app.setActive(k);
    app.toast("layout: spread {d} tabs into {d} splits", .{ tabs, made });
    app.needs_render = true;
}

fn focusPane(app: *App) CommandError!void {
    // With no pane open the start surface is the window.
    if (welcome_app.full(app)) return welcome_app.focus(app);
    const id = app.active orelse return error.NoActivePane;
    app.focus = .{ .pane = id };
    app.needs_render = true;
}

// ─── viewport ───────────────────────────────────────────────────────────

fn cursorTo(app: *App, where: enum { center, top, bottom }) CommandError!void {
    const e = try app.requireEditor();
    const row = e.buf.editor.currentLine();
    const n_rows = @max(app.pane_rows, 1);
    e.view.scroll_line = @intCast(switch (where) {
        .top => row,
        .center => row -| n_rows / 2,
        .bottom => row -| (n_rows - 1),
    });
    app.needs_render = true;
}

fn cursorToCenter(app: *App) CommandError!void {
    return cursorTo(app, .center);
}
fn cursorToTop(app: *App) CommandError!void {
    return cursorTo(app, .top);
}
fn cursorToBottom(app: *App) CommandError!void {
    return cursorTo(app, .bottom);
}

fn scrollBy(app: *App, delta: i32) CommandError!void {
    const e = try app.requireEditor();
    const max: i64 = @intCast(e.buf.editor.lineCount() -| 1);
    const cur: i64 = e.view.scroll_line;
    e.view.scroll_line = @intCast(std.math.clamp(cur + delta, 0, max));
    // Keep the cursor inside the window so the view does not snap back.
    const row = e.buf.editor.currentLine();
    const top: usize = e.view.scroll_line;
    const bottom = top + @max(app.pane_rows, 1) - 1;
    if (row < top) e.buf.editor.placeCursor(top, e.buf.editor.goalCol());
    if (row > bottom) e.buf.editor.placeCursor(@min(bottom, e.buf.editor.lineCount() - 1), e.buf.editor.goalCol());
    app.needs_render = true;
}

fn scrollDown(app: *App) CommandError!void {
    return scrollBy(app, 1);
}
fn scrollUp(app: *App) CommandError!void {
    return scrollBy(app, -1);
}

// ─── the list panes ─────────────────────────────────────────────────────

/// Show (or refill) the one list pane of `kind`. Takes `entries` (gpa).
pub fn openListPane(app: *App, kind: app_mod.ListPane.Kind, entries: []app_mod.ListPane.Entry) CommandError!void {
    var lp: app_mod.ListPane = .{ .gpa = app.gpa, .kind = kind };
    lp.entries = .fromOwnedSlice(entries);
    errdefer lp.deinit();
    lp.cursor = entries.len -| 1;
    // One pane per kind: refill an open one.
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .list => |*old| if (old.kind == kind) {
            old.deinit();
            old.* = lp;
            app.showPane(@intCast(i));
            return;
        },
        else => {},
    };
    const id = try app.panes.add(.{ .list = lp });
    app.showPane(id);
}

/// `q:` — the `:` lines run this session, newest last.
fn cmdlineHistory(app: *App) CommandError!void {
    const gpa = app.gpa;
    var entries: std.ArrayListUnmanaged(app_mod.ListPane.Entry) = .empty;
    errdefer {
        for (entries.items) |e| gpa.free(e.text);
        entries.deinit(gpa);
    }
    for (app.cmd_history.items) |line| try entries.append(gpa, .{ .text = try gpa.dupe(u8, line) });
    try openListPane(app, .cmdline_history, try entries.toOwnedSlice(gpa));
}

// ─── the read-only overlays ─────────────────────────────────────────────

fn openInfo(app: *App, kind: app_mod.InfoKind) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .info = kind };
    app.focus = .overlay;
    app.needs_render = true;
}

fn welcome(app: *App) CommandError!void {
    openInfo(app, .welcome);
}

fn about(app: *App) CommandError!void {
    openInfo(app, .about);
}

fn discovery(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .discovery;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The `.overlay_item` id a panel registers for its own body, so a
/// press inside it is not "outside".
pub const panel_item: u32 = std.math.maxInt(u32);

pub const version = "0.3.0-zig";

const welcome_rows = [_][2][]const u8{
    .{ "ctrl+p", "open a file" },
    .{ "ctrl+shift+p", "command palette" },
    .{ "ctrl+b", "toggle the file tree" },
    .{ "ctrl+\\", "split right" },
    .{ "ctrl+f", "find in file" },
    .{ "ctrl+s", "save" },
    .{ "ctrl+,", "settings" },
    .{ "ctrl+q", "quit" },
};

pub fn drawInfo(app: *App, ui: Ui, screen: Rect, kind: app_mod.InfoKind) void {
    const th = ui.theme;
    const title: []const u8 = switch (kind) {
        .welcome => "Welcome to mnml — Esc / click outside to dismiss",
        .about => "About mnml — Esc / click outside to dismiss",
    };
    const w: u16 = @min(@max(ui.width(title) + 4, 56), screen.w);
    const h: u16 = @min(switch (kind) {
        .welcome => welcome_rows.len + 4,
        .about => 8,
    }, screen.h);
    const inner = overlay_mod.box(ui, screen, w, h, title, .center);
    if (inner.isEmpty()) return;
    ui.hit(Rect.init(inner.x - 1, inner.y - 1, inner.w + 2, inner.h + 2), .{ .overlay_item = panel_item });
    const fg = Theme.onBg(th.fg, th.overlay_bg.bg);
    const acc = Theme.onBg(th.accent, th.overlay_bg.bg);
    var row: u16 = 0;
    switch (kind) {
        .welcome => {
            _ = ui.putStr(inner.x + 2, inner.y, inner.w -| 2, "The chords to start with:", fg);
            row = 2;
            for (welcome_rows) |wr| {
                if (row >= inner.h) break;
                const r = inner.row(row);
                const kw = ui.putStr(r.x + 2, r.y, 16, wr[0], acc);
                _ = kw;
                _ = ui.putStr(r.x + 18, r.y, r.w -| 18, wr[1], fg);
                row += 1;
            }
        },
        .about => {
            const lines = [_][]const u8{
                ui.fmt("mnml version {s}", .{version}),
                ui.fmt("workspace: {s}", .{app.workspace}),
                ui.fmt("commands: {d} of {d} implemented", .{ command.implemented, command.count }),
                ui.fmt("keymap: {s} · {d} bindings", .{ @tagName(app.input_style), app.keymap.count() }),
                ui.fmt("built with zig {s}{s}", .{ @import("builtin").zig_version_string, if (build_options.partial) " (partial)" else "" }),
            };
            for (lines) |l| {
                if (row >= inner.h) break;
                const r = inner.row(row);
                _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(l, r.w -| 2), if (row == 0) acc else fg);
                row += 1;
            }
        },
    }
}

fn openSettings(app: *App) CommandError!void {
    return settings.open(app);
}

/// The settings box, filter first. `/` inside the box is the same
/// thing, but a user has to already be in the box to find it — this is
/// the palette's way in.
fn openSettingsSearch(app: *App) CommandError!void {
    return settings.openSearch(app);
}

fn showFirstLaunch(app: *App) CommandError!void {
    return @import("first_launch.zig").show(app);
}

// ─── themes ─────────────────────────────────────────────────────────────
// `ui.theme` names the theme at startup; the picker previews while you
// move and Enter writes the pick to the home config. toggle / reset /
// auto_system change what is painted, not the file — `ui.theme` stays
// the theme you come back to.

/// How often `theme.auto_system` looks at the OS appearance.
pub const system_poll_ms: i64 = 15_000;

fn pickTheme(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    // The detail says which kind a row is, and marks the one you are on
    // — the theme you come back to, not the one the cursor is painting.
    const mark: []const u8 = if (app.cfg.ui.ascii_icons) "*" else "\u{25cf}";
    for (&Theme.all) |*th| {
        try labels.append(gpa, try gpa.dupe(u8, th.name));
        const on = std.mem.eql(u8, th.name, app.theme.name);
        try details.append(gpa, if (on)
            try std.fmt.allocPrint(gpa, "{s} current \u{b7} {s}", .{ mark, @tagName(th.kind) })
        else
            try gpa.dupe(u8, @tagName(th.kind)));
    }
    const current = Theme.byName(app.theme.name);
    try cmd_picker.openPickerWith(app, "Themes", .themes, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.restore_theme = current;
    // Start on the theme that is painted, so Enter is a no-op pick.
    for (app.overlay.picker.filtered.items, 0..) |idx, i| {
        if (std.mem.eql(u8, app.overlay.picker.labels[idx], app.theme.name)) app.overlay.picker.state.cursor = i;
    }
}

/// Paint the candidate under the picker's cursor.
pub fn previewTheme(app: *App) void {
    const name = cmd_picker.cursorLabel(app) orelse return;
    if (Theme.byName(name)) |th| if (!std.mem.eql(u8, th.name, app.theme.name)) app.setTheme(th);
}

/// The pick: paint it, make it `ui.theme`, write it home.
pub fn acceptTheme(app: *App, name: []const u8) CommandError!void {
    const th = Theme.byName(name) orelse return app.diag.fail(app.frame.allocator(), "no theme named {s}", .{name});
    app.setTheme(th);
    app.cfg.ui.theme = th.name;
    _ = try settings.persist(app, .home, &.{ "ui", "theme" }, th.name);
    app.toast("theme: {s}", .{th.name});
}

/// `:set theme=<name>` / `:theme <name>`: the same as a pick.
pub fn useTheme(app: *App, name: []const u8) CommandError!void {
    return acceptTheme(app, std.mem.trim(u8, name, " \t"));
}

/// The other half of the pair: `ui.theme_toggle` when set, otherwise the
/// first bundled theme of the opposite kind.
fn toggleTheme(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const base = app.cfg.ui.theme;
    const on_base = std.ascii.eqlIgnoreCase(app.theme.name, base);
    const other: *const Theme = blk: {
        if (app.cfg.ui.theme_toggle) |name| {
            if (Theme.byName(name)) |th| break :blk th;
            app.toast("ui.theme_toggle \"{s}\" is not a bundled theme", .{name});
        }
        const want: Theme.Kind = if (app.theme.kind == .dark) .light else .dark;
        break :blk Theme.firstOfKind(want, app.theme.name) orelse return app.diag.fail(arena, "no {s} theme to toggle to", .{@tagName(want)});
    };
    const next = if (on_base) other else (Theme.byName(base) orelse other);
    app.setTheme(next);
    app.toast("theme: {s} ({s})", .{ next.name, @tagName(next.kind) });
}

fn resetTheme(app: *App) CommandError!void {
    app.theme_auto_poll_ms = null;
    try app.applyTheme();
    app.toast("theme: {s} (config default)", .{app.theme.name});
}

/// Follow the OS appearance: dark → `ui.theme` when it is dark else the
/// toggle partner; light the other way round. Re-checked every 15 s.
fn autoSystemTheme(app: *App) CommandError!void {
    app.theme_auto_poll_ms = app.now_ms;
    try pollSystemTheme(app);
    app.toast("theme follows the system ({s})", .{@tagName(app.theme.kind)});
}

fn autoSystemThemeOff(app: *App) CommandError!void {
    app.theme_auto_poll_ms = null;
    app.toast("theme frozen on {s}", .{app.theme.name});
}

/// One poll: ask the OS, switch kinds if it disagrees, schedule the next.
pub fn pollSystemTheme(app: *App) std.mem.Allocator.Error!void {
    app.theme_auto_poll_ms = app.now_ms + system_poll_ms;
    const dark = detectSystemDark(app.gpa, app.io) orelse return;
    const want: Theme.Kind = if (dark) .dark else .light;
    if (app.theme.kind == want) return;
    const base = Theme.byName(app.cfg.ui.theme);
    const partner: ?*const Theme = if (app.cfg.ui.theme_toggle) |n| Theme.byName(n) else null;
    const pick: ?*const Theme = if (base != null and base.?.kind == want) base else if (partner != null and partner.?.kind == want) partner else Theme.firstOfKind(want, app.theme.name);
    if (pick) |th| app.setTheme(th);
}

/// Does the OS report a dark appearance? null when it cannot be asked
/// (no tool, not a desktop, spawn refused) — fail closed on "unknown"
/// rather than guessing a switch.
pub fn detectSystemDark(gpa: std.mem.Allocator, io: std.Io) ?bool {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "defaults", "read", "-g", "AppleInterfaceStyle" },
        .linux => &.{ "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" },
        else => return null,
    };
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (builtin.os.tag) {
        // The key only exists when dark; light exits non-zero.
        .macos => result.term == .exited and result.term.exited == 0 and std.mem.indexOf(u8, result.stdout, "Dark") != null,
        .linux => std.mem.indexOf(u8, result.stdout, "prefer-dark") != null,
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Allocator = std.mem.Allocator;

test "theme.pick previews under the cursor, Esc restores, Enter persists ui.theme to the home config" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try t.expectEqualStrings("onedark", app.theme.name);

    try command.run(&app, .{ .static = .@"theme.pick" });
    try t.expect(app.overlay == .picker);
    try t.expect(app.overlay.picker.kind == .themes);
    try t.expectEqualStrings("onedark", app.overlay.picker.labels[app.overlay.picker.filtered.items[app.overlay.picker.state.cursor]]);
    // The theme you came from is marked; the others say their kind.
    const cur_row = app.overlay.picker.filtered.items[app.overlay.picker.state.cursor];
    try t.expect(std.mem.indexOf(u8, app.overlay.picker.details[cur_row], "current") != null);
    // moving previews — the PALETTE in effect changes, not just the name
    const before = app.theme.statusline.bg;
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expect(!std.mem.eql(u8, app.theme.name, "onedark"));
    try t.expect(!std.meta.eql(before, app.theme.statusline.bg));
    // Esc puts it back and writes nothing
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("onedark", app.theme.name);
    try t.expect(std.meta.eql(before, app.theme.statusline.bg));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "config.zon", .{}));
    // typing filters; Enter picks and persists
    try command.run(&app, .{ .static = .@"theme.pick" });
    for ("gruvbox") |c| try app.handle(.{ .key = app_mod.Key.char(c) });
    try t.expectEqualStrings("gruvbox", app.theme.name); // previewed as the filter narrows
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("gruvbox", app.theme.name);
    try t.expectEqualStrings("gruvbox", app.cfg.ui.theme);
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".theme = \"gruvbox\"") != null);
    // the pane is still there and focused
    try t.expect(app.focus == .pane);
}

test "theme.toggle flips to the partner or the other kind; reset returns to ui.theme; :set theme= is a pick" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"theme.toggle" });
    try t.expect(app.theme.kind == .light);
    try command.run(&app, .{ .static = .@"theme.toggle" });
    try t.expectEqualStrings("onedark", app.theme.name);
    app.cfg.ui.theme_toggle = "catppuccin-latte";
    try command.run(&app, .{ .static = .@"theme.toggle" });
    try t.expectEqualStrings("catppuccin-latte", app.theme.name);
    try command.run(&app, .{ .static = .@"theme.reset" });
    try t.expectEqualStrings("onedark", app.theme.name);
    try t.expectEqualStrings("onedark", app.cfg.ui.theme); // toggle never touched the config
    try @import("dispatch.zig").runExLine(&app, "set theme=Gruvbox");
    try t.expectEqualStrings("gruvbox", app.theme.name);
    try t.expectEqualStrings("gruvbox", app.cfg.ui.theme);
    try @import("dispatch.zig").runExLine(&app, "theme nope");
    try t.expectEqualStrings("no theme named nope", app.lastToast().?);
    try t.expectEqualStrings("gruvbox", app.theme.name);
}

test "wrap toggles per pane; splits add leaves; focus moves between them" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(true, app.activeEditor().?.wrap.?);
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(false, app.activeEditor().?.wrap.?);

    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try t.expect(a != b);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_right" });
    try t.expectEqual(b, app.active.?);
    // Past the last leaf the cycle enters the sidebar when it is open
    // (the next test); with it hidden it wraps to the first leaf.
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expectEqual(a, app.active.?);
    app.tree.visible = true;
    try command.run(&app, .{ .static = .@"view.split_down" });
    const c = app.active.?;
    try command.run(&app, .{ .static = .@"view.focus_up" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_down" });
    try t.expectEqual(c, app.active.?);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // The split's window was a second view of the scratch document: it
    // goes with its leaf, the document stays with `a`.
    try t.expectEqual(@as(usize, 2), app.panes.count());
    try t.expect(app.panes.get(a) != null);
}

test "the sidebar is the leftmost window: focus_left from the leftmost split enters it, focus_right leaves it, focus_next_split wraps into it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    app.tree.visible = true;
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expect(app.focus == .tree);
    // Left again stays; right returns to the split it came from.
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expect(app.focus == .tree);
    try command.run(&app, .{ .static = .@"view.focus_right" });
    try t.expect(app.focus == .pane and app.focus.pane == a);
    // With two splits, left from the right one is a split move, not the tree.
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try t.expect(b != a);
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expect(app.focus == .pane and app.active.? == a);
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expect(app.focus == .tree);
    // Ctrl-W w cycles a → b → tree.
    app.focus = .{ .pane = a };
    app.setActive(a);
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expectEqual(b, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expect(app.focus == .tree);
    // A hidden sidebar is never a target.
    app.focus = .{ .pane = a };
    app.setActive(a);
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.focus_left" });
    try t.expect(app.focus == .pane);
}

test "focus_prev_split is focus_next_split backwards: three splits wrap both ways, prev undoes next, and the open sidebar sits before the first split" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try command.run(&app, .{ .static = .@"view.split_right" });
    const c = app.active.?;
    try t.expectEqual(@as(usize, 3), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try t.expect(a != b and b != c and a != c);
    // The sidebar hidden: a pure ring of three, either way.
    app.tree.visible = false;
    app.setActive(a);
    for ([_]PaneId{ b, c, a }) |want| {
        try command.run(&app, .{ .static = .@"view.focus_next_split" });
        try t.expectEqual(want, app.active.?);
    }
    for ([_]PaneId{ c, b, a }) |want| {
        try command.run(&app, .{ .static = .@"view.focus_prev_split" });
        try t.expectEqual(want, app.active.?);
    }
    // Back after forth lands where it started, from every split.
    for ([_]PaneId{ a, b, c }) |from| {
        app.setActive(from);
        try command.run(&app, .{ .static = .@"view.focus_next_split" });
        try command.run(&app, .{ .static = .@"view.focus_prev_split" });
        try t.expectEqual(from, app.active.?);
    }
    // The sidebar open: next runs a → b → c → tree, prev the mirror
    // a → tree → c → b → a.
    app.tree.visible = true;
    app.focus = .{ .pane = a };
    app.setActive(a);
    try command.run(&app, .{ .static = .@"view.focus_prev_split" });
    try t.expect(app.focus == .tree);
    try command.run(&app, .{ .static = .@"view.focus_prev_split" });
    try t.expect(app.focus == .pane and app.active.? == c);
    try command.run(&app, .{ .static = .@"view.focus_prev_split" });
    try t.expectEqual(b, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_prev_split" });
    try t.expectEqual(a, app.active.?);
    // And prev undoes next across the sidebar too.
    app.setActive(c);
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expect(app.focus == .tree);
    try command.run(&app, .{ .static = .@"view.focus_prev_split" });
    try t.expect(app.focus == .pane and app.active.? == c);
}

test "view.only keeps this window and its tabs; the other leaves' panes become background tabs here, a twin window closes" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("dirty");
    app.activeEditor().?.buf.doc.dirty = true;
    const b = try app.openScratch();
    app.setActive(a);
    try splitWith(&app, .horizontal, b);
    try t.expect(b != a);
    const c = try app.openScratch();
    app.setActive(b);
    try splitWith(&app, .vertical, c);
    try t.expectEqual(@as(usize, 3), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // `:only` from c: a and b live on (their own documents) as tabs of c's leaf.
    try command.run(&app, .{ .static = .@"view.only" });
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try t.expectEqual(c, app.active.?);
    try t.expect(app.focus == .pane);
    const tabs = layout.leaf(layout.leafOf(c).?).?.tabs.items;
    try t.expectEqual(@as(usize, 3), tabs.len);
    try t.expect(app.panes.get(a) != null and app.panes.get(b) != null);
    try t.expect(app.panes.get(a).?.dirty());
    // A second window on a document this leaf shows is dropped, not
    // re-homed — dirty or not, the document stays with the window here.
    try app.activeEditor().?.buf.setPath("/tmp/mnml-zig-only.txt");
    try command.run(&app, .{ .static = .@"view.split_right" });
    const dup = app.active.?;
    try t.expect(dup != c);
    try app.activeEditor().?.buf.editor.setText("edited in the split");
    app.activeEditor().?.buf.doc.dirty = true;
    app.setActive(c);
    try command.run(&app, .{ .static = .@"view.only" });
    try t.expect(app.panes.get(dup) == null);
    try t.expectEqual(@as(usize, 3), layout.leaf(layout.leafOf(c).?).?.tabs.items.len);
    try t.expectEqualStrings("edited in the split", app.panes.editor(c).?.buf.editor.bytes());
    try t.expect(app.panes.get(c).?.dirty());
    // One leaf: a no-op.
    try command.run(&app, .{ .static = .@"view.only" });
    try t.expectEqual(c, app.active.?);
}

test "a split opens a second window on the file; closing the split drops the window, not the document" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "alpha.txt", .data = "the alpha file" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    const path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "alpha.txt" });
    defer t.allocator.free(path);
    const a = try app.openPath(path);
    try command.run(&app, .{ .static = .@"view.split_right" });
    const dup = app.active.?;
    try t.expect(dup != a);
    try t.expectEqualStrings("alpha.txt", app.panes.get(dup).?.title());
    try t.expectEqualStrings("the alpha file", app.activeEditor().?.buf.editor.bytes());
    try t.expect(!app.activeEditor().?.buf.doc.dirty);
    try t.expect(app.activeEditor().?.buf.doc == app.panes.editor(a).?.buf.doc);
    // An edit in the split is the document's: the first window shows it
    // and both report dirty; closing the split keeps it.
    try app.splice(app.activeEditor().?, 0, 3, "THE");
    try t.expectEqualStrings("THE alpha file", app.panes.editor(a).?.buf.editor.bytes());
    try t.expect(app.panes.get(a).?.dirty());
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(a, app.active.?);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    try t.expectEqualStrings("THE alpha file", app.panes.editor(a).?.buf.editor.bytes());
    try t.expect(app.panes.get(a).?.dirty());
    try t.expectEqual(@as(usize, 1), app.docs.count());
    // Splitting with an explicit pane puts that pane in the new leaf.
    const s = try app.openScratch();
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqual(a, app.active.?);
    try splitWith(&app, .vertical, s);
    try t.expectEqual(s, app.active.?);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
}

test "view.settings opens the settings overlay; Esc closes it; view.about paints the about box" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.settings" });
    try t.expect(app.overlay == .settings);
    try t.expect(app.focus == .overlay);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(app.focus == .pane);
    try app.render();
    try command.run(&app, .{ .static = .@"view.about" });
    try t.expect(app.overlay == .info);
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "About mnml") != null);
    try t.expect(std.mem.indexOf(u8, txt, "version") != null);
    // any press closes an info overlay
    try app.handle(.{ .mouse = .{ .x = 1, .y = 1, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
}

// ─── tabs of the active leaf ─────────────────────────────────────────────

/// `view.focus_tab_N`: the Nth tab of the active leaf (1-based).
fn focusTabRunner(comptime n: usize) command.CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            const tabs = try activeLeafTabs(app);
            if (n > tabs.len) return app.diag.fail(app.frame.allocator(), "this leaf has {d} tab(s)", .{tabs.len});
            app.showPane(tabs[n - 1]);
        }
    }.run;
}

fn focusTabLast(app: *App) CommandError!void {
    const tabs = try activeLeafTabs(app);
    app.showPane(tabs[tabs.len - 1]);
}

fn activeLeafTabs(app: *App) CommandError![]const PaneId {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const lid = layout.leafOf(cur) orelse return error.NoActivePane;
    return layout.leaf(lid).?.tabs.items;
}

// ─── the viewport ────────────────────────────────────────────────────────

/// `H` / `M` / `L`: the first non-blank of the top / middle / bottom
/// visible row.
fn cursorViewTop(app: *App) CommandError!void {
    return cursorViewAt(app, .top);
}
fn cursorViewMiddle(app: *App) CommandError!void {
    return cursorViewAt(app, .middle);
}
fn cursorViewBottom(app: *App) CommandError!void {
    return cursorViewAt(app, .bottom);
}

fn cursorViewAt(app: *App, where: enum { top, middle, bottom }) CommandError!void {
    const e = try app.requireEditor();
    @import("jumplist.zig").noteJumpMotion(app);
    const ed = e.buf.editor;
    const total = ed.lineCount();
    const top: usize = @min(e.view.scroll_line, total -| 1);
    const rows = @max(app.pane_rows, 1);
    const bottom = @min(top + rows - 1, total -| 1);
    const row = switch (where) {
        .top => top,
        .middle => top + (bottom - top) / 2,
        .bottom => bottom,
    };
    // Vim keeps the column (`nostartofline`, Neovim's default); the
    // standard profile lands on the first non-blank.
    if (app.input_style == .vim) {
        ed.setCursor(ed.byteAtVcol(row, ed.goalCol()));
    } else {
        ed.setCursor(ed.firstNonWs(row));
        ed.goal_col = null;
    }
    app.needs_render = true;
}

/// `zh` / `zl` / `zH` / `zL`: the viewport's column, when wrap is off.
fn hscrollLeft(app: *App) CommandError!void {
    return hscroll(app, -1, false);
}
fn hscrollRight(app: *App) CommandError!void {
    return hscroll(app, 1, false);
}
fn hscrollLeftHalf(app: *App) CommandError!void {
    return hscroll(app, -1, true);
}
fn hscrollRightHalf(app: *App) CommandError!void {
    return hscroll(app, 1, true);
}

fn hscroll(app: *App, sign: i8, half: bool) CommandError!void {
    const e = try app.requireEditor();
    if (e.wrap orelse app.cfg.ui.wrap) return app.diag.fail(app.frame.allocator(), "wrap is on — nothing to scroll sideways (:set nowrap)", .{});
    // Before the first frame the pane area is unknown; half of 80 then.
    const width: u32 = if (app.panes_area.w > 0) app.panes_area.w else 80;
    const step: u32 = if (half) @max(width / 2, 1) else 4;
    e.view.scroll_col = if (sign < 0) e.view.scroll_col -| step else e.view.scroll_col + step;
    app.needs_render = true;
}

/// F1: the help overlay (`app/help.zig`), toggled.
fn help(app: *App) CommandError!void {
    @import("help.zig").toggle(app);
}

// ─── splits ──────────────────────────────────────────────────────────────

fn splitNewScratch(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const id = app.openScratch() catch return error.OutOfMemory;
    // openScratch showed it in the current leaf; move it out into the split.
    app.setActive(cur);
    try splitWith(app, .horizontal, id);
}

fn splitGotoDefinition(app: *App) CommandError!void {
    try splitWith(app, .horizontal, null);
    return command.run(app, .{ .static = .@"lsp.goto_definition" });
}

fn splitOpenFileUnderCursor(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const target = try @import("cmd_app.zig").pathUnderCursor(app, e);
    try splitWith(app, .horizontal, null);
    const id = app.openPath(target.abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ app.relPath(target.abs), @errorName(err) }),
    };
    if (target.line) |l| if (app.panes.editor(id)) |ed| ed.buf.editor.placeCursor(l -| 1, (target.col orelse 1) -| 1);
}

/// The host the keys are in when they are not in a pane: a column, or
/// the dock (its section or its hosted pane).
/// // changed (bottom-dock).
fn hostUnderKeys(app: *App) ?side.Side {
    if (bottom_dock.focused(app)) return .bottom;
    const s = side.sectionOfFocus(app) orelse return null;
    if (!side.isShown(app, s)) return null;
    return side.sideOf(app, s);
}

/// The nearest enclosing split of `dir` above the active leaf, and
/// whether the leaf sits in its first half.
fn enclosingSplit(app: *App, dir: layout_mod.SplitDir) CommandError!struct { id: layout_mod.NodeId, first: bool, ratio: u16 } {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    var node = layout.leafOf(cur) orelse return error.NoActivePane;
    while (layout.parentOf(node)) |pid| {
        const s = layout.node(pid).split;
        if (s.dir == dir) return .{ .id = pid, .first = s.first == node, .ratio = s.ratio };
        node = pid;
    }
    return app.diag.fail(app.frame.allocator(), "no {s} split to resize", .{if (dir == .horizontal) "side-by-side" else "stacked"});
}

/// Grow (or shrink) the active leaf's half of its enclosing split by
/// 5 % — or, with the keys in a column or the dock, that host's own
/// measure: two cells across for a column, a row for the dock. The
/// same `Ctrl-W > < + -` chords, whichever window they are pressed in.
/// // changed (bottom-dock): the columns and the dock had no keyboard
/// resize at all; the mouse's divider was the only way.
fn resize(app: *App, dir: layout_mod.SplitDir, grow: bool) CommandError!void {
    if (hostUnderKeys(app)) |host| {
        const wants_width = dir == .horizontal;
        if (wants_width != (host != .bottom)) return app.diag.fail(app.frame.allocator(), "the {s} resizes by {s}", .{ side.sideLabel(host), if (host == .bottom) "rows (ctrl+w + / -)" else "columns (ctrl+w > / <)" });
        const step: i32 = if (host == .bottom) 1 else 2;
        const now: i32 = @intCast(side.size(app, host));
        side.setSize(app, host, @intCast(@max(now + (if (grow) step else -step), 3)));
        app.needs_render = true;
        return;
    }
    const s = try enclosingSplit(app, dir);
    const delta: i32 = if (grow == s.first) 5 else -5;
    const next: i32 = std.math.clamp(@as(i32, s.ratio) + delta, 10, 90);
    app.layouts.current().setRatio(s.id, @intCast(next));
    app.needs_render = true;
}

/// `:resize N` / `:vertical resize N` / `{count} Ctrl-W >`: the active
/// window's height or width in cells — absolute, `+N` / `-N` relative,
/// empty = as much as the split allows — as the ratio of its enclosing
/// split that gives that many cells (`:help :resize`).
pub fn resizeCells(app: *App, width: bool, spec: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const s = try enclosingSplit(app, if (width) .horizontal else .vertical);
    const cur = app.active orelse return error.NoActivePane;
    const rects = try app.layouts.current().computeRects(app.panes_area, arena);
    var have: ?i32 = null;
    for (rects.panes) |pr| if (pr.pane == cur) {
        have = if (width) pr.rect.w else pr.rect.h;
    };
    var all: ?i32 = null;
    for (rects.dividers) |d| if (d.split == s.id) {
        all = if (width) d.area.w else d.area.h;
    };
    const mine = have orelse return error.NoActivePane;
    const total = all orelse return app.diag.fail(arena, "no split to resize", .{});
    const a = std.mem.trim(u8, spec, " \t");
    const want: i32 = if (a.len == 0)
        total
    else if (a[0] == '+' or a[0] == '-')
        mine + (std.fmt.parseInt(i32, a, 10) catch return app.diag.fail(arena, ":resize — not a number: {s}", .{a}))
    else
        std.fmt.parseInt(i32, a, 10) catch return app.diag.fail(arena, ":resize — not a number: {s}", .{a});
    var ratio: i32 = @divTrunc(std.math.clamp(want, 1, total) * 100, @max(total, 1));
    if (!s.first) ratio = 100 - ratio;
    app.layouts.current().setRatio(s.id, @intCast(std.math.clamp(ratio, 10, 90)));
    app.needs_render = true;
}

pub fn resizeByCells(app: *App, width: bool, cells: i32) CommandError!void {
    var buf: [16]u8 = undefined;
    const spec = std.fmt.bufPrint(&buf, "{s}{d}", .{ if (cells >= 0) "+" else "", cells }) catch return;
    return resizeCells(app, width, spec);
}

fn splitGrowWidth(app: *App) CommandError!void {
    return resize(app, .horizontal, true);
}
fn splitShrinkWidth(app: *App) CommandError!void {
    return resize(app, .horizontal, false);
}
fn splitGrowHeight(app: *App) CommandError!void {
    return resize(app, .vertical, true);
}
fn splitShrinkHeight(app: *App) CommandError!void {
    return resize(app, .vertical, false);
}

/// `ctrl+w |` / `ctrl+w _`: the active half takes 90 %.
fn maximize(app: *App, dir: layout_mod.SplitDir) CommandError!void {
    const s = try enclosingSplit(app, dir);
    app.layouts.current().setRatio(s.id, if (s.first) 90 else 10);
    app.needs_render = true;
}

fn maximizeWidth(app: *App) CommandError!void {
    return maximize(app, .horizontal);
}
fn maximizeHeight(app: *App) CommandError!void {
    return maximize(app, .vertical);
}

/// `ctrl+w r`: the two halves of the active leaf's split swap places.
fn rotateSplits(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const lid = layout.leafOf(cur) orelse return error.NoActivePane;
    const pid = layout.parentOf(lid) orelse return app.diag.fail(app.frame.allocator(), "only one pane — nothing to rotate", .{});
    const s = &layout.node(pid).split;
    std.mem.swap(layout_mod.NodeId, &s.first, &s.second);
    // The tree moved under the zoom: the page comes back to show it.
    layout.zoomed = null;
    app.needs_render = true;
}

/// `ctrl+w H/J/K/L`: the active pane becomes a full edge of the whole
/// window (vim moves the window to the far side, not just past its
/// sibling). It keeps focus.
fn moveSplit(app: *App, edge: layout_mod.Edge) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const lid = layout.leafOf(cur) orelse return error.NoActivePane;
    if (layout.parentOf(lid) == null) return app.diag.fail(app.frame.allocator(), "only one pane — nothing to move", .{});
    try layout.moveToEdge(cur, edge);
    app.needs_render = true;
}

fn moveSplitLeft(app: *App) CommandError!void {
    return moveSplit(app, .left);
}
fn moveSplitRight(app: *App) CommandError!void {
    return moveSplit(app, .right);
}
fn moveSplitUp(app: *App) CommandError!void {
    return moveSplit(app, .top);
}
fn moveSplitDown(app: *App) CommandError!void {
    return moveSplit(app, .bottom);
}

// ─── right panel tabs ────────────────────────────────────────────────────

/// The panels that are in this build, in tab order.
fn rightPanelNext(app: *App) CommandError!void {
    return side.step(app, .right, 1);
}
fn rightPanelPrev(app: *App) CommandError!void {
    return side.step(app, .right, -1);
}

test "view: focus_tab_N, H/M/L, hscroll, split resize / maximize / rotate, right panel tabs" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const s1 = try app.openScratch();
    const s2 = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.focus_tab_1" });
    try t.expectEqual(s1, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_tab_last" });
    try t.expectEqual(s2, app.active.?);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.focus_tab_8" }));
    // H / M / L over a 60-line buffer scrolled to line 20 with 10 rows.
    const e = app.activeEditor().?;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const line = try std.fmt.allocPrint(t.allocator, "  line {d}\n", .{i});
        defer t.allocator.free(line);
        try text.appendSlice(t.allocator, line);
    }
    try e.buf.editor.setText(text.items);
    e.view.scroll_line = 20;
    app.pane_rows = 10;
    try command.run(&app, .{ .static = .@"view.move_cursor_view_top" });
    try t.expectEqual(@as(usize, 20), e.buf.editor.rowCol().row);
    try t.expectEqual(@as(usize, 2), e.buf.editor.rowCol().col);
    try command.run(&app, .{ .static = .@"view.move_cursor_view_bottom" });
    try t.expectEqual(@as(usize, 29), e.buf.editor.rowCol().row);
    try command.run(&app, .{ .static = .@"view.move_cursor_view_middle" });
    try t.expectEqual(@as(usize, 24), e.buf.editor.rowCol().row);
    // Sideways only with wrap off.
    e.wrap = true;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.hscroll_right" }));
    e.wrap = false;
    try app.render();
    try command.run(&app, .{ .static = .@"view.hscroll_right" });
    try t.expectEqual(@as(u32, 4), e.view.scroll_col);
    try command.run(&app, .{ .static = .@"view.hscroll_left_half" });
    try t.expectEqual(@as(u32, 0), e.view.scroll_col);
    // A side-by-side split: grow, maximize, rotate.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.split_grow_width" }));
    try command.run(&app, .{ .static = .@"view.split_right" });
    const layout = app.layouts.current();
    const lid = layout.leafOf(app.active.?).?;
    const pid = layout.parentOf(lid).?;
    try t.expectEqual(@as(u16, 50), layout.node(pid).split.ratio);
    try command.run(&app, .{ .static = .@"view.split_grow_width" });
    // The new leaf is the second half, so growing it shrinks the ratio.
    try t.expectEqual(@as(u16, 45), layout.node(pid).split.ratio);
    try command.run(&app, .{ .static = .@"view.maximize_width" });
    try t.expectEqual(@as(u16, 10), layout.node(pid).split.ratio);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.split_grow_height" }));
    const first_before = layout.node(pid).split.first;
    try command.run(&app, .{ .static = .@"view.rotate_splits" });
    try t.expectEqual(first_before, layout.node(pid).split.second);
    // The right column's tabs walk the sections on the right side
    // (`side.zig` has the walk itself). // changed (bottom-dock): the
    // outline is the only one that lives there out of the box, so the
    // walk stays on it.
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(side.Section.outline, side.shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(side.Section.outline, side.shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(side.Section.outline, side.shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_close_tab" });
    // A scratch in a fresh split beside the current pane.
    const before = app.active.?;
    try command.run(&app, .{ .static = .@"view.split_new_scratch" });
    try t.expect(app.active.? != before);
    try t.expect(app.layouts.current().leafOf(app.active.?).? != app.layouts.current().leafOf(before).?);
}

test "view.move_split_*: the active pane becomes the far edge and keeps focus; alone it fails" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.move_split_left" }));
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try command.run(&app, .{ .static = .@"view.split_down" });
    const c = app.active.?;
    // c is the bottom-right quarter; after `H` it is the whole left edge.
    try command.run(&app, .{ .static = .@"view.move_split_left" });
    try t.expectEqual(c, app.active.?);
    try t.expect(app.focus == .pane);
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    try t.expectEqual(@as(usize, 3), leaves.len);
    try t.expectEqual(c, layout.leaf(leaves[0]).?.active);
    try command.run(&app, .{ .static = .@"view.focus_right" });
    try t.expectEqual(a, app.active.?);
    // `J` from a: full width along the bottom; b is now straight above c.
    try command.run(&app, .{ .static = .@"view.move_split_down" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_up" });
    try t.expect(app.active.? == b or app.active.? == c);
    try command.run(&app, .{ .static = .@"view.focus_down" });
    try t.expectEqual(a, app.active.?);
}

test "view.close_split on the last window closes its buffer: the layout goes empty, a dirty one asks first" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try t.expectEqual(@as(usize, 1), app.panes.count());
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(@as(usize, 0), app.panes.count());
    try t.expect(app.active == null);
    try t.expectEqual(@as(usize, 0), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // Unsaved: the close asks, nothing goes until it is answered.
    _ = try app.openScratch();
    app.activeEditor().?.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expect(app.overlay == .confirm);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
}

test "project.todos opens the TODOS panel — the palette's name for view.activity_todos, not a stub" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    try t.expect(!side.isShown(&app, .todos));
    try command.run(&app, .{ .static = .@"project.todos" });
    try t.expect(side.isShown(&app, .todos));
    try t.expectEqual(side.Section.todos, side.shown(&app, .left).?);
    try t.expect(app.lastToast() == null or std.mem.indexOf(u8, app.lastToast().?, "not implemented") == null);
}

test "ui.auto_equalize_splits: a split or a close evens the ratios; off leaves them; the toggle persists and evens at once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = buf[0..n], .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const layout = app.layouts.current();
    // Skew the one split, then split again: off keeps the skew.
    const split_id = layout.parentOf(layout.leafOf(app.active.?).?).?;
    layout.setRatio(split_id, 20);
    try command.run(&app, .{ .static = .@"view.split_right" });
    try std.testing.expectEqual(@as(u16, 20), layout.node(split_id).split.ratio);
    // The toggle: on, persisted to the workspace config, and even at
    // once — every leaf an equal share, so the first split's left leaf
    // is one of three.
    try command.run(&app, .{ .static = .@"view.toggle_auto_equalize_splits" });
    try std.testing.expect(app.cfg.ui.auto_equalize_splits);
    try std.testing.expectEqual(@as(u16, 33), layout.node(split_id).split.ratio);
    const text = try tmp.dir.readFileAlloc(std.testing.io, ".mnml/config.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".auto_equalize_splits = true") != null);
    // On: a skew is undone by the next split (one leaf of four), and by
    // a close (one of three again).
    layout.setRatio(split_id, 30);
    try command.run(&app, .{ .static = .@"view.split_down" });
    try std.testing.expectEqual(@as(u16, 25), layout.node(split_id).split.ratio);
    layout.setRatio(split_id, 30);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try std.testing.expectEqual(@as(u16, 33), layout.node(split_id).split.ratio);
}

test "layout.merge_to_tabs folds the page's leaves into one strip, the active pane focused; spread_to_splits puts each tab back in a split; each refuses the other's shape and a lone pane" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try app.openScratch();
    // One pane: nothing to merge; one leaf with one tab: nothing to spread.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"layout.merge_to_tabs" }));
    try t.expectEqualStrings("layout: nothing to merge", app.lastToast().?);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"layout.spread_to_splits" }));
    try t.expectEqualStrings("layout: nothing to spread", app.lastToast().?);
    // Two tabs in one leaf, no split: merge has nothing to fold.
    const b = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"layout.merge_to_tabs" }));
    try t.expectEqualStrings("layout: already a single leaf", app.lastToast().?);
    // Split twice: three leaves, four panes; the active one is the last split's.
    try command.run(&app, .{ .static = .@"view.split_right" });
    try command.run(&app, .{ .static = .@"view.split_down" });
    const c = app.active.?;
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 3), (try layout.leaves(app.frame.allocator())).len);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"layout.spread_to_splits" }));
    try t.expectEqualStrings("layout: already has splits; merge to tabs first", app.lastToast().?);
    try command.run(&app, .{ .static = .@"layout.merge_to_tabs" });
    try t.expectEqualStrings("layout: merged 3 splits into 4 tabs", app.lastToast().?);
    try t.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try t.expectEqual(c, app.active.?);
    const strip = layout.leaf(layout.root.?).?;
    try t.expectEqual(@as(usize, 4), strip.tabs.items.len);
    try t.expectEqual(a, strip.tabs.items[0]);
    try t.expectEqual(b, strip.tabs.items[1]);
    try t.expectEqual(c, strip.active);
    // Spread: four leaves side by side, the focus still on `c`.
    try command.run(&app, .{ .static = .@"layout.spread_to_splits" });
    try t.expectEqualStrings("layout: spread 4 tabs into 4 splits", app.lastToast().?);
    try t.expectEqual(@as(usize, 4), (try layout.leaves(app.frame.allocator())).len);
    try t.expectEqual(c, app.active.?);
    try t.expectEqual(@as(usize, 1), layout.leaf(layout.leafOf(a).?).?.tabs.items.len);
}

test "revealArgv: open -R on macOS, explorer /select, on Windows, xdg-open on the parent elsewhere; view.reveal_active refuses a scratch" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mac = try revealArgv(a, "/ws/src/main.zig", .macos);
    try t.expectEqual(@as(usize, 3), mac.len);
    try t.expectEqualStrings("open", mac[0]);
    try t.expectEqualStrings("-R", mac[1]);
    try t.expectEqualStrings("/ws/src/main.zig", mac[2]);
    const win = try revealArgv(a, "C:\\ws\\main.zig", .windows);
    try t.expectEqual(@as(usize, 2), win.len);
    try t.expectEqualStrings("explorer", win[0]);
    try t.expectEqualStrings("/select,C:\\ws\\main.zig", win[1]);
    const lin = try revealArgv(a, "/ws/src/main.zig", .linux);
    try t.expectEqual(@as(usize, 2), lin.len);
    try t.expectEqualStrings("xdg-open", lin[0]);
    try t.expectEqualStrings("/ws/src", lin[1]);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.reveal_active" }));
    try t.expectEqualStrings("no file to reveal", app.lastToast().?);
}

test "view.toggle_integrations_section opens the INTEGRATIONS column without taking the keys, and closes it again" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    try t.expect(!side.isShown(&app, .integrations));
    try command.run(&app, .{ .static = .@"view.toggle_integrations_section" });
    try t.expect(side.isShown(&app, .integrations));
    try t.expect(app.focus == .pane and app.focus.pane == a);
    try command.run(&app, .{ .static = .@"view.toggle_integrations_section" });
    try t.expect(!side.isShown(&app, .integrations));
    try t.expect(side.shown(&app, .left) == null);
}

test "view.workspace_menu opens the workspace chip's menu on the chip the last frame painted; with no frame it opens at the origin" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.workspace_menu" });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(@as(u16, 0), app.overlay.menu.x);
    try t.expectEqual(@as(u16, 0), app.overlay.menu.y);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.focus = .{ .pane = app.active.? };
    try app.render();
    var chip: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .statusline_seg and e.target.statusline_seg == @import("statusline.zig").SegId.workspace.raw()) {
        chip = e.rect;
    };
    try t.expect(chip != null);
    try t.expect(chip.?.y > 0);
    try command.run(&app, .{ .static = .@"view.workspace_menu" });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(chip.?.x, app.overlay.menu.x);
    try t.expectEqual(chip.?.y - 1, app.overlay.menu.y);
    var has_switch = false;
    for (app.overlay.menu.items) |it| if (std.mem.eql(u8, it.label, "Switch workspace…")) {
        has_switch = true;
    };
    try t.expect(has_switch);
}

test "debug.toggle_click_inspector: on, a press toasts its hit target with the cell; off, it does not" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    try app.render();
    try command.run(&app, .{ .static = .@"debug.toggle_click_inspector" });
    try t.expect(app.debug_click_inspector);
    try t.expectEqualStrings("click inspector: ON — next click toasts the hit target", app.lastToast().?);
    try @import("dispatch.zig").mouse(&app, .{ .x = 60, .y = 10, .kind = .press, .button = .left }, 1);
    var seen = false;
    for (app.toasts.items) |toast| if (std.mem.startsWith(u8, toast.text, "click @60,10 → pane:")) {
        seen = true;
    };
    try t.expect(seen);
    try @import("dispatch.zig").mouse(&app, .{ .x = 60, .y = 10, .kind = .press, .button = .right }, 1);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "right-click @60,10 → "));
    try command.run(&app, .{ .static = .@"debug.toggle_click_inspector" });
    try t.expectEqualStrings("click inspector: OFF", app.lastToast().?);
    app.dismissToasts();
    try @import("dispatch.zig").mouse(&app, .{ .x = 60, .y = 10, .kind = .press, .button = .left }, 1);
    try t.expect(app.lastToast() == null or !std.mem.startsWith(u8, app.lastToast().?, "click @"));
}

test "view.commands_reference opens the generated page as a scratch buffer" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.commands_reference" });
    const e = app.activeEditor().?;
    try t.expect(e.buf.doc.path == null);
    const text = e.buf.editor.bytes();
    try t.expect(std.mem.startsWith(u8, text, "# Commands\n"));
    try t.expect(std.mem.indexOf(u8, text, "| `app.quit` |") != null);
    const want = try std.fmt.allocPrint(t.allocator, "commands reference: {d} commands", .{command.count});
    defer t.allocator.free(want);
    try t.expectEqualStrings(want, app.lastToast().?);
}

test "Ctrl-W t / b / p: the top and bottom windows, and the one that had the keys before — from the tree too" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_down" });
    const b = app.active.?;
    try command.run(&app, .{ .static = .@"view.split_right" });
    const c = app.active.?;
    try command.run(&app, .{ .static = .@"view.focus_top" });
    try std.testing.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_bottom" });
    try std.testing.expectEqual(c, app.active.?);
    // Previous: c came from a; then a from c.
    try command.run(&app, .{ .static = .@"view.focus_previous" });
    try std.testing.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_previous" });
    try std.testing.expectEqual(c, app.active.?);
    // Into the tree and back with Ctrl-W p, the pane untouched.
    app.tree.visible = true;
    app.focus = .tree;
    try command.run(&app, .{ .static = .@"view.focus_previous" });
    try std.testing.expect(app.focus == .pane and app.focus.pane == c);
    _ = b;
}

test "every pane kind splits: a request pane gets a blank request beside it, a cheatsheet a scratch editor, and no toast names an error tag" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const req = try http_app.openBlank(&app);
    try command.run(&app, .{ .static = .@"view.split_right" });
    const layout = app.layouts.current();
    try t.expect(app.active.? != req);
    try t.expect(app.panes.get(app.active.?).?.* == .request);
    try t.expect(layout.leafOf(req).? != layout.leafOf(app.active.?).?);
    try t.expect(app.lastToast() == null or std.mem.indexOf(u8, app.lastToast().?, "NotAnEditor") == null);
    // A pane with no document of its own: a scratch editor beside it.
    try command.run(&app, .{ .static = .@"view.cheatsheet" });
    const sheet = app.active.?;
    try t.expect(app.panes.get(sheet).?.* == .cheatsheet);
    try command.run(&app, .{ .static = .@"view.split_down" });
    try t.expect(app.panes.get(app.active.?).?.* == .editor);
    try t.expect(layout.leafOf(sheet).? != layout.leafOf(app.active.?).?);
    try t.expect(app.lastToast() == null or std.mem.indexOf(u8, app.lastToast().?, "NotAnEditor") == null);
    // A command that needs an editor, run on the cheatsheet: a sentence, not a tag.
    app.setActive(sheet);
    try t.expectError(error.NotAnEditor, command.run(&app, .{ .static = .@"editor.goto_line" }));
    try t.expect(std.mem.endsWith(u8, app.lastToast().?, ": needs an editor pane"));
    try t.expectEqualStrings("needs an editor pane", command.reason(error.NotAnEditor));
}

// ─── preview tabs (preview-tabs) ────────────────────────────────────────

fn previewWs(tmp: *std.testing.TmpDir, names: []const []const u8) ![]u8 {
    for (names) |n| try tmp.dir.writeFile(t.io, .{ .sub_path = n, .data = "x\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return t.allocator.dupe(u8, buf[0..n]);
}

test "preview tabs: a glance previews, the next glance takes the tab over, and an explicit open keeps it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try previewWs(&tmp, &.{ "a.txt", "b.txt", "c.txt" });
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    const c = try std.fs.path.join(t.allocator, &.{ root, "c.txt" });
    defer t.allocator.free(c);

    // A glance: one italic tab.
    const first = try app.openPreview(a);
    try t.expect(app.panes.get(first).?.preview());
    try t.expectEqualStrings(a, app.panes.editor(first).?.buf.doc.path.?);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    // A glance at another file takes the tab over: still one tab.
    const second = try app.openPreview(b);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    try t.expect(app.panes.get(second).?.preview());
    try t.expectEqualStrings(b, app.panes.editor(second).?.buf.doc.path.?);
    // An explicit open (the picker, `:e`, the IPC `open`) is pinned and
    // opens beside the preview.
    const pinned = try app.openPath(c);
    try t.expect(!app.panes.get(pinned).?.preview());
    try t.expectEqual(@as(usize, 2), app.panes.count());
    // An explicit open of the file the preview is showing keeps it.
    _ = try app.openPath(b);
    try t.expect(!app.panes.get(second).?.preview());
    // …and with no preview left, the next glance opens a third tab.
    _ = try app.openPreview(a);
    try t.expectEqual(@as(usize, 3), app.panes.count());
}

test "preview tabs: an edit keeps the tab, `view.keep_tab` keeps it, and a dirty preview is never taken over" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try previewWs(&tmp, &.{ "a.txt", "b.txt", "c.txt" });
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    const c = try std.fs.path.join(t.allocator, &.{ root, "c.txt" });
    defer t.allocator.free(c);

    // `view.keep_tab` on a preview, and the refusal when there is none.
    const kept = try app.openPreview(a);
    try t.expect(app.panes.get(kept).?.preview());
    try command.run(&app, .{ .static = .@"view.keep_tab" });
    try t.expect(!app.panes.get(kept).?.preview());
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.keep_tab" }));

    // An edit keeps a preview: the tab the glance opened stays behind.
    const glanced = try app.openPreview(b);
    try t.expect(app.panes.get(glanced).?.preview());
    app.panes.editor(glanced).?.buf.doc.dirty = true;
    app.keepEditedPreviews();
    try t.expect(!app.panes.get(glanced).?.preview());
    // Neither tab is a preview now, so the next glance opens beside them.
    _ = try app.openPreview(c);
    try t.expectEqual(@as(usize, 3), app.panes.count());
}

test "splitting a preview tab promotes it: both halves are kept tabs of one document with their own ids; a rendered markdown glance splits into its source editor and the layout never empties" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try previewWs(&tmp, &.{ "a.txt", "b.txt" });
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "# Title\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    const md = try std.fs.path.join(t.allocator, &.{ root, "notes.md" });
    defer t.allocator.free(md);

    // A glance, then the split: the glanced tab is kept, its twin is a
    // kept tab of the same document, and each half holds one of them.
    const glanced = try app.openPreview(a);
    try t.expect(app.panes.get(glanced).?.preview());
    try command.run(&app, .{ .static = .@"view.split_right" });
    const twin = app.active.?;
    try t.expect(twin != glanced);
    const layout = app.layouts.current();
    try t.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
    try t.expect(layout.leafOf(glanced) != null);
    try t.expect(layout.leafOf(twin) != null);
    try t.expect(layout.leafOf(glanced).? != layout.leafOf(twin).?);
    try t.expect(!app.panes.get(glanced).?.preview());
    try t.expect(!app.panes.get(twin).?.preview());
    try t.expect(app.panes.editor(glanced).?.buf.doc == app.panes.editor(twin).?.buf.doc);
    // One document, two cursors: moving the twin's leaves the glanced
    // tab's where it was.
    app.panes.editor(twin).?.buf.editor.setCursor(1);
    try t.expectEqual(@as(usize, 1), app.panes.editor(twin).?.buf.editor.cursor);
    try t.expectEqual(@as(usize, 0), app.panes.editor(glanced).?.buf.editor.cursor);
    // Neither half is a glance any more: a glance at another file
    // opens beside the twin instead of taking it over.
    _ = try app.openPreview(b);
    try t.expect(app.panes.get(twin) != null);
    try t.expectEqual(@as(usize, 3), app.panes.count());

    // A rendered markdown glance: its companion is the file's source
    // editor, not the rendered tab itself — which `removePane` would
    // have emptied the leaf of, leaving the file in no half at all.
    const rendered = try app.openPreview(md);
    try t.expect(app.panes.get(rendered).?.* == .md_preview);
    try t.expect(app.panes.get(rendered).?.preview());
    try command.run(&app, .{ .static = .@"view.split_down" });
    const source = app.active.?;
    try t.expect(source != rendered);
    try t.expect(layout.root != null);
    try t.expect(layout.leafOf(rendered) != null);
    try t.expect(layout.leafOf(source) != null);
    try t.expect(app.panes.get(source).?.* == .editor);
    try t.expectEqualStrings(md, app.panes.editor(source).?.buf.doc.path.?);
    try t.expect(!app.panes.get(rendered).?.preview());
    try t.expect(!app.panes.get(source).?.preview());
    // A pane in its own leaf is what `close_split` needs: the file
    // stays up in the other half.
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expect(layout.leafOf(rendered) != null);
}

test "preview tabs: `ui.preview_tabs = false` and the vim profile open every file pinned" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try previewWs(&tmp, &.{ "a.txt", "b.txt" });
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);

    app.cfg.ui.preview_tabs = false;
    const one = try app.openPreview(a);
    try t.expect(!app.panes.get(one).?.preview());
    const two = try app.openPreview(b);
    try t.expect(!app.panes.get(two).?.preview());
    try t.expectEqual(@as(usize, 2), app.panes.count());

    // The vim profile has no preview tabs at all (Neovim gives every
    // file its own buffer), whatever the setting says.
    app.cfg.ui.preview_tabs = true;
    app.input_style = .vim;
    try t.expect(!app.previewTabs());
}

test "sessions stacked as tabs in one leaf: from a session pane the walk steps the session tabs both ways with wrap, skipping other tabs; off a session or with two splits it is the split walk" {
    if (builtin.os.tag == .windows or !pty_pane.supported) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    // A stand-in `claude` (the basename is what makes it a session).
    try tmp.dir.createDirPath(t.io, "bin");
    const perms: std.Io.File.Permissions = .fromMode(0o755);
    {
        const f = try tmp.dir.createFile(t.io, "bin/claude", .{ .truncate = true, .permissions = perms });
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "#!/bin/sh\nsleep 30\n");
    }
    const claude = try std.fs.path.join(t.allocator, &.{ root, "bin", "claude" });
    defer t.allocator.free(claude);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    app.cfg.ui.ai_layout_mode = .tabs;
    app.tree.visible = true;
    const ed = try app.openScratch();
    const s1 = try pty_pane.open(&app, .{ .argv = &.{claude}, .label = "claude", .kind = .command, .placement = .tab });
    const s2 = try pty_pane.open(&app, .{ .argv = &.{claude}, .label = "claude", .kind = .command, .placement = .tab });
    const s3 = try pty_pane.open(&app, .{ .argv = &.{claude}, .label = "claude", .kind = .command, .placement = .tab });
    try t.expectEqual(@as(usize, 1), (try app.layouts.current().leaves(app.frame.allocator())).len);
    app.showPane(s1);
    app.focus = .{ .pane = s1 };
    // Forward s1 → s2 → s3 → s1, the editor tab skipped, the sidebar
    // never entered.
    for ([_]PaneId{ s2, s3, s1 }) |want| {
        try command.run(&app, .{ .static = .@"view.focus_next_split" });
        try t.expect(app.focus == .pane and app.focus.pane == want);
        try t.expectEqual(want, app.active.?);
        try t.expectEqual(want, app.layouts.current().leaf(app.layouts.current().leafOf(want).?).?.active);
    }
    // Backward s1 → s3 → s2 → s1.
    for ([_]PaneId{ s3, s2, s1 }) |want| {
        try command.run(&app, .{ .static = .@"view.focus_prev_split" });
        try t.expect(app.focus == .pane and app.focus.pane == want);
        try t.expectEqual(want, app.active.?);
    }
    // From the editor tab it is the split walk: one leaf, the sidebar next.
    app.showPane(ed);
    app.focus = .{ .pane = ed };
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expect(app.focus == .tree);
    // Two splits: the split walk again, even from a session.
    app.showPane(s1);
    app.focus = .{ .pane = s1 };
    try splitWith(&app, .horizontal, ed);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    app.setActive(s1);
    app.focus = .{ .pane = s1 };
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expectEqual(ed, app.active.?);
}
