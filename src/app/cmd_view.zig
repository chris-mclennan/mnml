//! `view.*` and `theme.*` runners: wrap and gutter toggles, splits and
//! split focus, viewport scrolling, the right panel, the read-only
//! overlays (welcome / about / discovery, drawn here beside the commands
//! that open them), and the theme picker with its toggle / reset /
//! follow-the-OS companions. Tab pages are `cmd_tab.zig`; the settings
//! overlay is `settings.zig` + `ui/settings.zig`.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = app_mod.Config;
const Layout = app_mod.Layout;
const layout_mod = @import("layout.zig");
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
    .@"view.close_split" = &closeSplit,
    .@"view.close_others" = &closeOthers,
    .@"view.toggle_auto_equalize_splits" = &toggleAutoEqualize,
    .@"view.only" = &only,
    .@"view.equalize_splits" = &equalizeSplits,
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
};

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

// ─── the right panel ────────────────────────────────────────────────────
// One slot, one panel at a time (`App.right_panel`). `activity_<x>`
// shows and focuses a panel; toggle hides it or brings the last one
// back. Panels without a module in this build name themselves.

pub fn showRightPanel(app: *App, which: app_mod.PanelId) void {
    app.right_panel = which;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = which };
    app.needs_render = true;
}

fn hideRightPanel(app: *App) void {
    app.right_panel = null;
    if (app.focus == .panel) app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

fn toggleRightPanel(app: *App) CommandError!void {
    if (app.right_panel != null) hideRightPanel(app) else showRightPanel(app, .todos);
}

fn focusRightPanel(app: *App) CommandError!void {
    showRightPanel(app, app.right_panel orelse .todos);
}

fn closeRightPanel(app: *App) CommandError!void {
    hideRightPanel(app);
}

fn activityTodos(app: *App) CommandError!void {
    showRightPanel(app, .todos);
}

fn activityNotes(app: *App) CommandError!void {
    showRightPanel(app, .notes);
}

fn activityFindings(app: *App) CommandError!void {
    showRightPanel(app, .findings);
}

fn activitySessions(app: *App) CommandError!void {
    showRightPanel(app, .sessions);
}

fn activityExplorer(app: *App) CommandError!void {
    app.tree.visible = true;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
    app.needs_render = true;
}

/// Panels whose module is a later phase: say so, change nothing.
fn notInBuild(app: *App, what: []const u8) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "{s} panel: not in this build yet", .{what});
}

fn activityHttp(app: *App) CommandError!void {
    showRightPanel(app, .http);
}

fn activityGit(app: *App) CommandError!void {
    showRightPanel(app, .git);
}

// ─── splits ─────────────────────────────────────────────────────────────

/// A new leaf beside the active one. `pane` fills it; null duplicates
/// the active editor so both halves start with the same context (vim
/// `:split`).
pub fn splitWith(app: *App, dir: layout_mod.SplitDir, pane: ?PaneId) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    if (layout.leafOf(cur) == null) return error.NoActivePane;
    const id: PaneId = pane orelse app.duplicatePane(cur) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAnEditor,
    };
    if (pane != null) _ = layout.removePane(id);
    _ = try layout.split(cur, dir, id);
    app.afterSplitChange();
    app.setActive(id);
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
        return;
    };
    app.setActive(target.pane);
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

fn focusPane(app: *App) CommandError!void {
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
    openInfo(app, .discovery);
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
        .discovery => "Click Discovery — F1 / Esc to close",
    };
    const w: u16 = @min(@max(ui.width(title) + 4, 56), screen.w);
    const h: u16 = @min(switch (kind) {
        .welcome => welcome_rows.len + 4,
        .about => 8,
        .discovery => @as(u16, 20),
    }, screen.h);
    const inner = overlay_mod.box(ui, screen, w, h, title, .center);
    if (inner.isEmpty()) return;
    ui.hit(Rect.init(inner.x - 1, inner.y - 1, inner.w + 2, inner.h + 2), .{ .overlay_item = panel_item });
    const fg = Theme.onBg(th.fg, th.overlay_bg.bg);
    const dim = Theme.onBg(th.muted, th.overlay_bg.bg);
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
        .discovery => {
            // What the frame under this box registered, by kind — the
            // map of everything a click can reach right now.
            const Tag = std.meta.Tag(@import("../ui/hit.zig").HitTarget);
            var counts = std.enums.EnumArray(Tag, u32).initFill(0);
            for (app.hits.items.items) |e| counts.getPtr(std.meta.activeTag(e.target)).* += 1;
            _ = ui.putStr(inner.x + 2, inner.y, inner.w -| 2, "clickable regions on this frame:", fg);
            row = 2;
            inline for (@typeInfo(Tag).@"enum".fields) |f| {
                const n = counts.get(@enumFromInt(f.value));
                if (n > 0 and row < inner.h) {
                    const r = inner.row(row);
                    _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.fmt("{s:<16} {d}", .{ f.name, n }), if (row % 2 == 0) fg else dim);
                    row += 1;
                }
            }
        },
    }
}

fn openSettings(app: *App) CommandError!void {
    return settings.open(app);
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
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (&Theme.all) |*th| try labels.append(gpa, try gpa.dupe(u8, th.name));
    const current = Theme.byName(app.theme.name);
    try cmd_picker.open(app, "Themes", .themes, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
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
    // moving previews
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expect(!std.mem.eql(u8, app.theme.name, "onedark"));
    // Esc puts it back and writes nothing
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("onedark", app.theme.name);
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
    ed.setCursor(ed.firstNonWs(row));
    ed.goal_col = null;
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

/// F1: the cheatsheet pane is the help.
fn help(app: *App) CommandError!void {
    return command.run(app, .{ .static = .@"view.cheatsheet" });
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

/// Grow (or shrink) the active leaf's half of its enclosing split by 5 %.
fn resize(app: *App, dir: layout_mod.SplitDir, grow: bool) CommandError!void {
    const s = try enclosingSplit(app, dir);
    const delta: i32 = if (grow == s.first) 5 else -5;
    const next: i32 = std.math.clamp(@as(i32, s.ratio) + delta, 10, 90);
    app.layouts.current().setRatio(s.id, @intCast(next));
    app.needs_render = true;
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
const panel_order = [_]app_mod.PanelId{ .todos, .git, .diagnostics };

fn rightPanelNext(app: *App) CommandError!void {
    return rightPanelStep(app, 1);
}
fn rightPanelPrev(app: *App) CommandError!void {
    return rightPanelStep(app, panel_order.len - 1);
}

fn rightPanelStep(app: *App, by: usize) CommandError!void {
    const cur = app.right_panel orelse {
        showRightPanel(app, panel_order[0]);
        return;
    };
    var idx: usize = 0;
    for (panel_order, 0..) |p, i| if (p == cur) {
        idx = i;
    };
    showRightPanel(app, panel_order[(idx + by) % panel_order.len]);
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
    // Right panel tabs cycle the panels this build has.
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(app_mod.PanelId.todos, app.right_panel.?);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(app_mod.PanelId.git, app.right_panel.?);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(app_mod.PanelId.todos, app.right_panel.?);
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
    try t.expect(app.right_panel == null);
    try command.run(&app, .{ .static = .@"project.todos" });
    try t.expectEqual(app_mod.PanelId.todos, app.right_panel.?);
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
    // The toggle: on, persisted to the workspace config, and even at once.
    try command.run(&app, .{ .static = .@"view.toggle_auto_equalize_splits" });
    try std.testing.expect(app.cfg.ui.auto_equalize_splits);
    try std.testing.expectEqual(@as(u16, 50), layout.node(split_id).split.ratio);
    const text = try tmp.dir.readFileAlloc(std.testing.io, ".mnml/config.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".auto_equalize_splits = true") != null);
    // On: a skew is undone by the next split, and by a close.
    layout.setRatio(split_id, 30);
    try command.run(&app, .{ .static = .@"view.split_down" });
    try std.testing.expectEqual(@as(u16, 50), layout.node(split_id).split.ratio);
    layout.setRatio(split_id, 30);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try std.testing.expectEqual(@as(u16, 50), layout.node(split_id).split.ratio);
}
