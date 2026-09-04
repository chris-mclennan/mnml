//! `view.*` runners: wrap and gutter toggles, splits and split focus,
//! viewport scrolling, the right panel, and the read-only overlays
//! (welcome / about / discovery) plus the settings overlay, whose draw
//! and key handling live here beside the commands that open them.
//! Tab pages are `cmd_tab.zig`.

const std = @import("std");
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
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
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
    .@"view.focus_right_panel" = &focusRightPanel,
    .@"view.right_panel_close_tab" = &closeRightPanel,
    .@"view.activity_todos" = &activityTodos,
    .@"view.activity_notes" = &activityNotes,
    .@"view.activity_findings" = &activityFindings,
    .@"view.activity_sessions" = &activitySessions,
    .@"view.activity_http" = &activityHttp,
    .@"view.activity_git" = &activityGit,
    .@"view.activity_explorer" = &activityExplorer,
    .@"view.welcome" = &welcome,
    .@"view.about" = &about,
    .@"view.discovery" = &discovery,
    .@"view.settings" = &settings,
    .@"view.cmdline_history" = &cmdlineHistory,
    // changed: `editor.toggle_keymap` is the statusline mode chip's
    // click; it lives with the view code because that is who calls it.
    .@"editor.toggle_keymap" = &toggleKeymap,
};

fn toggleWrap(app: *App) CommandError!void {
    if (app.activeEditor()) |e| {
        const on = !(e.wrap orelse app.cfg.wrap);
        e.wrap = on;
        app.toast("wrap {s}", .{if (on) "on" else "off"});
    } else {
        app.cfg.wrap = !app.cfg.wrap;
        app.toast("wrap {s}", .{if (app.cfg.wrap) "on" else "off"});
    }
    app.needs_render = true;
}

fn toggleLineNumbers(app: *App) CommandError!void {
    app.cfg.line_numbers = !app.cfg.line_numbers;
    app.toast("line numbers {s}", .{if (app.cfg.line_numbers) "on" else "off"});
    app.needs_render = true;
}

fn toggleScrollbar(app: *App) CommandError!void {
    app.cfg.scrollbar = !app.cfg.scrollbar;
    app.toast("scrollbar {s}", .{if (app.cfg.scrollbar) "on" else "off"});
    app.needs_render = true;
}

fn redraw(app: *App) CommandError!void {
    app.needs_render = true;
}

fn resetTreeWidth(app: *App) CommandError!void {
    app.tree.width = @import("tree.zig").default_width;
    app.needs_render = true;
}

fn toggleKeymap(app: *App) CommandError!void {
    const next: input.Style = if (app.cfg.input_style == .vim) .standard else .vim;
    try app.setInputStyle(next);
    app.toast("keymap: {s}", .{@tagName(next)});
}

// ─── the right panel ────────────────────────────────────────────────────
// One slot, one panel at a time (`App.right_panel`). `activity_<x>`
// shows and focuses a panel; toggle hides it or brings the last one
// back. Panels without a module in this build name themselves.

fn showRightPanel(app: *App, which: app_mod.PanelId) void {
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
    return notInBuild(app, "HTTP");
}

fn activityGit(app: *App) CommandError!void {
    return notInBuild(app, "Git");
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
    app.setActive(id);
}

fn splitRight(app: *App) CommandError!void {
    return splitWith(app, .horizontal, null);
}

fn splitDown(app: *App) CommandError!void {
    return splitWith(app, .vertical, null);
}

const Dir = enum { left, right, up, down };

/// The leaf whose rect is the nearest neighbour of the active one in
/// `dir`, by the rects the last frame gave the split tree.
fn focusDir(app: *App, dir: Dir) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
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
    const target = best orelse return;
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

fn focusNextSplit(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len < 2) return;
    const mine = layout.leafOf(cur) orelse return;
    const idx = std.mem.indexOfScalar(layout_mod.NodeId, leaves, mine) orelse return;
    const next = leaves[(idx + 1) % leaves.len];
    app.setActive(layout.leaf(next).?.active);
}

/// True when another open pane shows the same file — the pane is a
/// split's duplicate and can go without losing anything.
fn hasTwin(app: *App, id: PaneId) bool {
    const e = app.panes.editor(id) orelse return false;
    const path = e.buf.path orelse return false;
    for (app.panes.slots.items, 0..) |*slot, i| {
        if (i == id or slot.* == null) continue;
        const other = slot.*.?.asEditor() orelse continue;
        if (other.buf.path) |p| if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

/// Drop the active leaf. A clean duplicate of a file open elsewhere
/// closes; every other tab stays open in the background.
fn closeSplit(app: *App) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const leaves = try layout.leaves(app.frame.allocator());
    if (leaves.len < 2) {
        app.toast("only one split", .{});
        return;
    }
    const mine = layout.leafOf(cur) orelse return;
    const tabs = try app.frame.allocator().dupe(PaneId, layout.leaf(mine).?.tabs.items);
    for (tabs) |tab| {
        const p = app.panes.get(tab) orelse continue;
        if (!p.dirty() and hasTwin(app, tab)) {
            try app.forceClosePane(tab);
        } else _ = layout.removePane(tab);
    }
    const first = layout.firstLeaf() orelse return;
    app.setActive(layout.leaf(first).?.active);
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
                ui.fmt("keymap: {s} · {d} bindings", .{ @tagName(app.cfg.input_style), app.keymap.count() }),
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

// ─── the settings overlay ───────────────────────────────────────────────
// A sectioned list of discrete-choice rows (the family idiom):
// `▸ label:  [active] / other  *` — `▸` focused, brackets the current
// choice, `*` changed from the default. ←→ adjust, ↑↓ move, r / R
// reset, Enter saves, Esc puts the opened config back.

const Choice = struct {
    label: []const u8,
    options: []const []const u8,
    get: *const fn (*const Config) usize,
    set: *const fn (*Config, usize) void,
};

const Row = union(enum) { header: []const u8, choice: Choice };

const on_off = [_][]const u8{ "on", "off" };
const styles = [_][]const u8{ "standard", "vim" };
const tab_widths = [_][]const u8{ "2", "4", "8" };
const timeouts = [_][]const u8{ "300", "500", "800", "1000" };

fn boolGet(comptime field: []const u8) *const fn (*const Config) usize {
    return &struct {
        fn f(c: *const Config) usize {
            return if (@field(c, field)) 0 else 1;
        }
    }.f;
}

fn boolSet(comptime field: []const u8) *const fn (*Config, usize) void {
    return &struct {
        fn f(c: *Config, i: usize) void {
            @field(c, field) = i == 0;
        }
    }.f;
}

pub const rows = [_]Row{
    .{ .header = "UI" },
    .{ .choice = .{ .label = "Soft wrap", .options = &on_off, .get = boolGet("wrap"), .set = boolSet("wrap") } },
    .{ .choice = .{ .label = "Line numbers", .options = &on_off, .get = boolGet("line_numbers"), .set = boolSet("line_numbers") } },
    .{ .choice = .{ .label = "Scrollbar", .options = &on_off, .get = boolGet("scrollbar"), .set = boolSet("scrollbar") } },
    .{ .choice = .{ .label = "Breadcrumb", .options = &on_off, .get = boolGet("breadcrumb"), .set = boolSet("breadcrumb") } },
    .{ .choice = .{ .label = "ASCII icons", .options = &on_off, .get = boolGet("ascii"), .set = boolSet("ascii") } },
    .{ .header = "Editor" },
    .{ .choice = .{ .label = "Input style", .options = &styles, .get = &struct {
        fn f(c: *const Config) usize {
            return if (c.input_style == .vim) 1 else 0;
        }
    }.f, .set = &struct {
        fn f(c: *Config, i: usize) void {
            c.input_style = if (i == 1) .vim else .standard;
        }
    }.f } },
    .{ .choice = .{ .label = "Tab width", .options = &tab_widths, .get = &struct {
        fn f(c: *const Config) usize {
            return switch (c.tab_width) {
                2 => 0,
                8 => 2,
                else => 1,
            };
        }
    }.f, .set = &struct {
        fn f(c: *Config, i: usize) void {
            c.tab_width = switch (i) {
                0 => 2,
                2 => 8,
                else => 4,
            };
        }
    }.f } },
    .{ .choice = .{ .label = "Chord timeout (ms)", .options = &timeouts, .get = &struct {
        fn f(c: *const Config) usize {
            return switch (c.chord_timeout_ms) {
                300 => 0,
                800 => 2,
                1000 => 3,
                else => 1,
            };
        }
    }.f, .set = &struct {
        fn f(c: *Config, i: usize) void {
            c.chord_timeout_ms = switch (i) {
                0 => 300,
                2 => 800,
                3 => 1000,
                else => 500,
            };
        }
    }.f } },
};

fn isChoice(i: usize) bool {
    return rows[i] == .choice;
}

fn firstChoice() usize {
    for (rows, 0..) |r, i| if (r == .choice) return i;
    return 0;
}

fn settings(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .settings = .{ .cursor = firstChoice(), .opened = app.cfg } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The settings overlay's keys. Returns true when the overlay closed.
pub fn settingsKey(app: *App, s: *app_mod.SettingsState, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => {
            try settingsCancel(app, s);
            return true;
        },
        .enter => {
            try settingsSave(app);
            return true;
        },
        .up => moveCursor(s, -1),
        .down => moveCursor(s, 1),
        .left => adjust(app, s, -1),
        .right => adjust(app, s, 1),
        .char => |c| switch (c) {
            'k' => moveCursor(s, -1),
            'j' => moveCursor(s, 1),
            'h' => adjust(app, s, -1),
            'l' => adjust(app, s, 1),
            'r' => resetRow(app, s.cursor),
            'R' => {
                const defaults: Config = .{};
                for (rows, 0..) |_, i| if (isChoice(i)) rows[i].choice.set(&app.cfg, rows[i].choice.get(&defaults));
            },
            'q' => {
                try settingsCancel(app, s);
                return true;
            },
            else => {},
        },
        else => {},
    }
    app.needs_render = true;
    return false;
}

fn moveCursor(s: *app_mod.SettingsState, delta: i32) void {
    var i: i64 = @intCast(s.cursor);
    while (true) {
        i += delta;
        if (i < 0 or i >= rows.len) return;
        if (isChoice(@intCast(i))) {
            s.cursor = @intCast(i);
            return;
        }
    }
}

fn adjust(app: *App, s: *app_mod.SettingsState, delta: i32) void {
    if (!isChoice(s.cursor)) return;
    const c = rows[s.cursor].choice;
    const n: i64 = @intCast(c.options.len);
    const cur: i64 = @intCast(c.get(&app.cfg));
    c.set(&app.cfg, @intCast(@mod(cur + delta, n)));
}

fn resetRow(app: *App, idx: usize) void {
    if (!isChoice(idx)) return;
    const defaults: Config = .{};
    rows[idx].choice.set(&app.cfg, rows[idx].choice.get(&defaults));
}

/// Esc: the config the overlay opened with comes back.
fn settingsCancel(app: *App, s: *app_mod.SettingsState) Allocator.Error!void {
    const opened = s.opened;
    app.cfg = opened;
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

/// Enter / a click outside: the edited config stays; a keymap change
/// is applied to every buffer.
pub fn settingsSave(app: *App) Allocator.Error!void {
    const style = app.cfg.input_style;
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    if (app.activeBuffer()) |b| {
        if (b.input.mode() == .none and style == .vim or b.input.mode() != .none and style == .standard) try app.setInputStyle(style);
    } else try app.setInputStyle(style);
    app.toast("settings saved", .{});
    app.needs_render = true;
}

/// A click on row `idx` focuses it; a second click on the focused row
/// advances its value.
pub fn settingsClick(app: *App, s: *app_mod.SettingsState, idx: usize) void {
    if (idx >= rows.len or !isChoice(idx)) return;
    if (s.cursor == idx) adjust(app, s, 1) else s.cursor = idx;
    app.needs_render = true;
}

pub fn drawSettings(app: *App, ui: Ui, screen: Rect, s: *app_mod.SettingsState) void {
    const th = ui.theme;
    const w: u16 = @min(64, screen.w);
    const h: u16 = @min(rows.len + 4, screen.h);
    const inner = overlay_mod.box(ui, screen, w, h, "Settings — ←→ adjust · r reset · Enter save · Esc cancel", .center);
    if (inner.isEmpty()) return;
    ui.hit(Rect.init(inner.x - 1, inner.y - 1, inner.w + 2, inner.h + 2), .{ .overlay_item = panel_item });
    const defaults: Config = .{};
    const fg = Theme.onBg(th.fg, th.overlay_bg.bg);
    const dim = Theme.onBg(th.muted, th.overlay_bg.bg);
    const acc = Theme.onBg(th.accent, th.overlay_bg.bg);
    const visible: usize = inner.h -| 1;
    if (s.cursor < s.scroll) s.scroll = s.cursor;
    if (s.cursor >= s.scroll + visible) s.scroll = s.cursor + 1 - visible;
    var y: u16 = 0;
    var i = s.scroll;
    while (i < rows.len and y < inner.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = inner.row(y);
        switch (rows[i]) {
            .header => |name| {
                const line = if (ui.ascii) ui.fmt("-- {s} --", .{name}) else ui.fmt("── {s} ──", .{name});
                _ = ui.putStr(r.x + 1, r.y, r.w -| 1, line, dim);
            },
            .choice => |c| {
                const focused = i == s.cursor;
                if (focused) ui.fill(r, Theme.onBg(th.overlay_bg, th.cursor_line.bg));
                const bg = if (focused) th.cursor_line.bg else th.overlay_bg.bg;
                var x = r.x + 1;
                x += ui.putStr(x, r.y, 2, if (focused) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(acc, bg));
                x += ui.putStr(x, r.y, r.w -| (x - r.x), ui.fmt("{s}:", .{c.label}), Theme.onBg(fg, bg));
                x = @max(x, r.x + 24);
                const cur = c.get(&app.cfg);
                for (c.options, 0..) |opt, oi| {
                    const text = if (oi == cur) ui.fmt(" [{s}]", .{opt}) else ui.fmt(" {s}", .{opt});
                    x += ui.putStr(x, r.y, r.right() -| x, text, if (oi == cur) Theme.onBg(acc, bg) else Theme.onBg(dim, bg));
                    if (oi + 1 < c.options.len) x += ui.putStr(x, r.y, r.right() -| x, " /", Theme.onBg(dim, bg));
                }
                if (c.get(&app.cfg) != c.get(&defaults)) _ = ui.putStr(x + 1, r.y, r.right() -| (x + 1), "*", Theme.onBg(th.warn_fg, bg));
                ui.hit(r, .{ .overlay_item = @intCast(i) });
            },
        }
    }
    if (inner.h > 0) overlay_mod.hint(ui, inner.row(inner.h - 1), "  click a row to focus it · click outside to save");
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Allocator = std.mem.Allocator;

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
    try command.run(&app, .{ .static = .@"view.focus_next_split" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.split_down" });
    const c = app.active.?;
    try command.run(&app, .{ .static = .@"view.focus_up" });
    try t.expectEqual(a, app.active.?);
    try command.run(&app, .{ .static = .@"view.focus_down" });
    try t.expectEqual(c, app.active.?);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // Scratch duplicates have no path, so they stay open in the background.
    try t.expectEqual(@as(usize, 3), app.panes.count());
}

test "a split duplicates the file; closing the split drops the clean duplicate" {
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
    try t.expect(!app.activeEditor().?.buf.dirty);
    try command.run(&app, .{ .static = .@"view.close_split" });
    try t.expectEqual(a, app.active.?);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    // Splitting with an explicit pane puts that pane in the new leaf.
    const s = try app.openScratch();
    try command.run(&app, .{ .static = .@"buffer.prev" });
    try t.expectEqual(a, app.active.?);
    try splitWith(&app, .vertical, s);
    try t.expectEqual(s, app.active.?);
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
}

test "settings: adjust, reset, cancel restores, save applies the keymap" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.settings" });
    try t.expect(app.overlay == .settings);
    const s = &app.overlay.settings;
    try t.expectEqual(@as(usize, 1), s.cursor);
    _ = try settingsKey(&app, s, Key.named(.right));
    try t.expect(app.cfg.wrap);
    _ = try settingsKey(&app, s, Key.char('r'));
    try t.expect(!app.cfg.wrap);
    // Down to Input style, right → vim, Esc → back to standard.
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = try settingsKey(&app, s, Key.char('j'));
    try t.expectEqual(@as(usize, 7), s.cursor);
    _ = try settingsKey(&app, s, Key.char('l'));
    try t.expectEqual(input.Style.vim, app.cfg.input_style);
    try t.expect(try settingsKey(&app, s, Key.named(.esc)));
    try t.expectEqual(input.Style.standard, app.cfg.input_style);
    try t.expect(app.overlay == .none);
    // Open again, switch to vim, Enter applies it to the buffer.
    try command.run(&app, .{ .static = .@"view.settings" });
    settingsClick(&app, &app.overlay.settings, 7);
    settingsClick(&app, &app.overlay.settings, 7);
    try t.expect(try settingsKey(&app, &app.overlay.settings, Key.named(.enter)));
    try t.expectEqual(input.EditingMode.normal, app.activeBuffer().?.input.mode());
    try app.render();
    try command.run(&app, .{ .static = .@"view.about" });
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "About mnml") != null);
    try t.expect(std.mem.indexOf(u8, txt, "version") != null);
}
