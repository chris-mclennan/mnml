//! The right-click menus: what a tab, a tree row, the editor body, the
//! statusline mode chip and the strip's `+` offer. Every row is a
//! `MenuAction{ .command }`, so a row cannot name an id that does not
//! exist; the opener makes the clicked thing current first (the tab
//! active, the tree cursor on the row) and the commands act on that.
//!
//! The Zig-only commands the rows need — `buffer.close_others`,
//! `buffer.close_right`, `file.copy_path`, the toast and stress-meter
//! verbs, `editor.set_tab_width` — have their runners here, and so does
//! `view.context_menu_at_focus` (Shift+F10), which opens the menu the
//! focused thing would get from a right-click.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const Mouse = @import("../core/key.zig").Mouse;

pub const table = .{
    .@"buffer.close_others" = &closeOthers,
    .@"buffer.close_right" = &closeRight,
    .@"file.copy_path" = &copyPath,
    .@"perf.copy_stress" = &copyStress,
    .@"toast.dismiss_clicked" = &toastDismissClicked,
    .@"toast.copy_clicked" = &toastCopyClicked,
    .@"editor.set_tab_width" = &setTabWidth,
    .@"view.context_menu_at_focus" = &contextMenuAtFocus,
};

fn items(app: *App, rows: []const MenuItem) Allocator.Error![]MenuItem {
    return app.gpa.dupe(MenuItem, rows);
}

/// The editor body: clipboard, undo, selection, the LSP verbs and the
/// fold, then Save.
pub fn openEditorMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Cut", .action = .{ .command = .@"editor.cut" } },
        .{ .label = "Copy", .action = .{ .command = .@"editor.copy" } },
        .{ .label = "Paste", .action = .{ .command = .@"editor.paste" } },
        .{ .label = "Undo", .action = .{ .command = .@"editor.undo" } },
        .{ .label = "Redo", .action = .{ .command = .@"editor.redo" } },
        .{ .label = "Select all", .action = .{ .command = .@"editor.select_all" } },
        .{ .label = "Go to definition", .action = .{ .command = .@"lsp.goto_definition" }, .separator_before = true },
        .{ .label = "Find references", .action = .{ .command = .@"lsp.references" } },
        .{ .label = "Hover info", .action = .{ .command = .@"lsp.hover" } },
        .{ .label = "Rename symbol", .action = .{ .command = .@"lsp.rename" } },
        .{ .label = "Select all occurrences", .action = .{ .command = .@"editor.select_all_occurrences" }, .separator_before = true },
        .{ .label = "Toggle fold", .action = .{ .command = .@"editor.toggle_fold" } },
        .{ .label = "Save", .action = .{ .command = .@"file.save" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Editor", rows, x, y);
}

/// A request pane's URL / body / response: send, paste, copy, flip.
pub fn openRequestFieldMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Send", .action = .{ .command = .@"http.send" } },
        .{ .label = "Paste curl from clipboard", .action = .{ .command = .@"http.paste_curl" } },
        .{ .label = "Copy as curl", .action = .{ .command = .@"http.copy_curl" } },
        .{ .label = "Cycle method", .action = .{ .command = .@"http.cycle_method" } },
        .{ .label = "Format body as JSON", .action = .{ .command = .@"http.format_body" }, .separator_before = true },
        .{ .label = "Insert header…", .action = .{ .command = .@"http.insert_header" } },
        .{ .label = "Switch Request ⇄ Response", .action = .{ .command = .@"http.toggle_view" }, .separator_before = true },
        .{ .label = "Copy response body", .action = .{ .command = .@"http.copy_response_body" } },
        .{ .label = "Save request", .action = .{ .command = .@"http.save" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Request", rows, x, y);
}

/// A strip tab: Save (when dirty) first, then the close family and the
/// path. The tab is made active before the menu opens.
pub fn openTabMenu(app: *App, pane: PaneId, x: u16, y: u16) Allocator.Error!void {
    const p = app.panes.get(pane) orelse return;
    app.showPane(pane);
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    if (p.dirty()) try rows.append(app.gpa, .{ .label = "Save", .action = .{ .command = .@"file.save" } });
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Close", .action = .{ .command = .@"buffer.close" }, .separator_before = p.dirty() },
        .{ .label = "Close others", .action = .{ .command = .@"buffer.close_others" } },
        .{ .label = "Close to the right", .action = .{ .command = .@"buffer.close_right" } },
        .{ .label = "Close all", .action = .{ .command = .@"view.close_others" } },
        .{ .label = "Split right", .action = .{ .command = .@"view.split_right" }, .separator_before = true },
        .{ .label = "Split down", .action = .{ .command = .@"view.split_down" } },
        .{ .label = "Copy path", .action = .{ .command = .@"file.copy_path" }, .separator_before = true },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(p.title(), owned, x, y);
}

/// A tree row: the file verbs act on the tree cursor, which the opener
/// has put on the row.
pub fn openTreeMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    if (idx >= app.tree.rows.items.len) return;
    app.tree.cursor = idx;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
    const row = app.tree.rows.items[idx];
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    if (row.is_dir) {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "New file…", .action = .{ .command = .@"file.new" } },
            .{ .label = "New folder…", .action = .{ .command = .@"file.new_folder" } },
            .{ .label = "Collapse all", .action = .{ .command = .@"tree.collapse_all" }, .separator_before = true },
            .{ .label = "Expand all", .action = .{ .command = .@"tree.expand_all" } },
        });
    } else {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Open", .action = .{ .command = .@"tree.open_selected" } },
            .{ .label = "Open in split", .action = .{ .command = .@"tree.open_in_split" } },
            .{ .label = "New file…", .action = .{ .command = .@"file.new" }, .separator_before = true },
            .{ .label = "New folder…", .action = .{ .command = .@"file.new_folder" } },
        });
    }
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Move to…", .action = .{ .command = .@"file.move_to" }, .separator_before = true },
        .{ .label = "Rename…", .action = .{ .command = .@"file.rename" } },
        .{ .label = "Delete…", .action = .{ .command = .@"file.delete" } },
        .{ .label = "Reveal in Finder", .action = .{ .command = .@"view.reveal_active" }, .separator_before = true },
        .{ .label = "Copy path", .action = .{ .command = .@"file.copy_path" } },
        .{ .label = "Refresh tree", .action = .{ .command = .@"tree.refresh" }, .separator_before = true },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(row.name(), owned, x, y);
}

/// The statusline mode chip: pick the keymap.
pub fn openModeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const vim = app.input_style == .vim;
    const rows = try items(app, &.{
        .{ .label = "vim keymap", .action = .{ .command = .@"editor.use_vim" }, .checked = vim },
        .{ .label = "standard keymap", .action = .{ .command = .@"editor.use_standard" }, .checked = !vim },
        .{ .label = "Open the cheatsheet", .action = .{ .command = .@"view.cheatsheet" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Keymap", rows, x, y);
}

/// The statusline's stress bar: read it out, copy it, reset it, hide it.
pub fn openStressMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Toast the numbers", .action = .{ .command = .@"perf.toast_stress" } },
        .{ .label = "Copy summary", .action = .{ .command = .@"perf.copy_stress" } },
        .{ .label = "Reset", .action = .{ .command = .@"perf.reset_stress" }, .separator_before = true },
        .{ .label = "Hide the meter", .action = .{ .command = .@"perf.hide_stress" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Stress meter", rows, x, y);
}

/// The branch chip: the status pane, the graph, the remote verbs.
pub fn openBranchMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Status / staging", .action = .{ .command = .@"git.status_pane" } },
        .{ .label = "Commit graph", .action = .{ .command = .@"git.graph" } },
        .{ .label = "Commit…", .action = .{ .command = .@"git.commit" }, .separator_before = true },
        .{ .label = "Fetch", .action = .{ .command = .@"git.fetch" } },
        .{ .label = "Pull", .action = .{ .command = .@"git.pull" } },
        .{ .label = "Push", .action = .{ .command = .@"git.push" } },
        .{ .label = "Refresh", .action = .{ .command = .@"git.refresh" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Git", rows, x, y);
}

/// The diagnostics chip: the panel and the two jumps.
pub fn openDiagnosticsMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Diagnostics panel", .action = .{ .command = .@"lsp.diagnostics" } },
        .{ .label = "Next diagnostic", .action = .{ .command = .@"lsp.next_diagnostic" }, .separator_before = true },
        .{ .label = "Previous diagnostic", .action = .{ .command = .@"lsp.prev_diagnostic" } },
        .{ .label = "Cycle severity filter", .action = .{ .command = .@"lsp.diagnostics_filter" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Diagnostics", rows, x, y);
}

/// The bell: the history picker and its clear.
pub fn openBellMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Show messages", .action = .{ .command = .@"messages.show" } },
        .{ .label = "Clear history", .action = .{ .command = .@"messages.clear" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Messages", rows, x, y);
}

/// A toast's right-click: `at` indexes `app.toasts` (oldest first) and
/// rides in `app.toast_ctx` to the row's command.
pub fn openToastMenu(app: *App, at: usize, x: u16, y: u16) Allocator.Error!void {
    if (at >= app.toasts.items.len) return;
    app.toast_ctx = at;
    const rows = try items(app, &.{
        .{ .label = "Dismiss", .action = .{ .command = .@"toast.dismiss_clicked" } },
        .{ .label = "Copy text", .action = .{ .command = .@"toast.copy_clicked" } },
        .{ .label = "Dismiss all", .action = .{ .command = .@"toast.dismiss_all" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Toast", rows, x, y);
}

/// The strip's `+`.
pub fn openNewTabMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "New blank tab", .action = .{ .command = .@"file.new" } },
        .{ .label = "Open file…", .action = .{ .command = .@"picker.files" } },
        .{ .label = "Recent files…", .action = .{ .command = .@"picker.recent" } },
        .{ .label = "New tab page", .action = .{ .command = .@"tab.new" }, .separator_before = true },
        .{ .label = "New dock note", .action = .{ .command = .@"dock.new_text" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("New tab", rows, x, y);
}

// ─── the runners the rows need ──────────────────────────────────────────

/// The tabs of the leaf the active pane is in.
fn siblingTabs(app: *App) CommandError![]const PaneId {
    const id = app.active orelse return error.NoActivePane;
    const layout = app.layouts.current();
    const lid = layout.leafOf(id) orelse return error.NoActivePane;
    return app.frame.allocator().dupe(PaneId, layout.leaf(lid).?.tabs.items);
}

/// Close the other tabs of this split (dirty ones stay, with a toast).
fn closeOthers(app: *App) CommandError!void {
    const keep = app.active orelse return error.NoActivePane;
    const tabs = try siblingTabs(app);
    try closeTabs(app, tabs, keep, null);
}

/// Close the tabs after this one in its split.
fn closeRight(app: *App) CommandError!void {
    const keep = app.active orelse return error.NoActivePane;
    const tabs = try siblingTabs(app);
    const at = std.mem.indexOfScalar(PaneId, tabs, keep) orelse return;
    try closeTabs(app, tabs, keep, at);
}

fn closeTabs(app: *App, tabs: []const PaneId, keep: PaneId, after: ?usize) CommandError!void {
    var skipped: usize = 0;
    var reopenable: usize = 0;
    for (tabs, 0..) |id, i| {
        if (id == keep) continue;
        if (after) |a| if (i <= a) continue;
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            skipped += 1;
            continue;
        }
        if (p.asEditor()) |e| if (e.buf.path != null) {
            reopenable += 1;
        };
        try app.forceClosePane(id);
    }
    app.setActive(keep);
    if (skipped > 0) app.toast("kept {d} tab(s) with unsaved changes", .{skipped});
    // The Undo chip: the closed files come back in one click.
    if (reopenable > 0) try app.armUndo(.{ .reopen = reopenable }, "closed {d} tab(s)", .{reopenable});
}

/// `perf.copy_stress`: the summary `perf.toast_stress` shows, to the clipboard.
fn copyStress(app: *App) CommandError!void {
    const s = app.stress.stats() orelse return app.diag.fail(app.frame.allocator(), "stress meter: no frames sampled yet", .{});
    const text = try std.fmt.allocPrint(app.frame.allocator(), "frames: p50 {d}.{d}ms · p95 {d}.{d}ms · max {d}.{d}ms · n={d}", .{
        s.p50_us / 1000, (s.p50_us % 1000) / 100,
        s.p95_us / 1000, (s.p95_us % 1000) / 100,
        s.max_us / 1000, (s.max_us % 1000) / 100,
        s.count,
    });
    try app.clipboard.set(text, false);
    app.toast("copied the stress summary", .{});
}

/// `toast.dismiss_clicked`: the toast the menu was opened on.
fn toastDismissClicked(app: *App) CommandError!void {
    const at = app.toast_ctx orelse return app.diag.fail(app.frame.allocator(), "no toast under the menu", .{});
    app.toast_ctx = null;
    app.dismissToastAt(at);
}

/// `toast.copy_clicked`: its text to the clipboard.
fn toastCopyClicked(app: *App) CommandError!void {
    const at = app.toast_ctx orelse return app.diag.fail(app.frame.allocator(), "no toast under the menu", .{});
    app.toast_ctx = null;
    if (at >= app.toasts.items.len) return;
    const text = try app.frame.allocator().dupe(u8, app.toasts.items[at].text);
    try app.clipboard.set(text, false);
    app.toast("copied", .{});
}

/// `editor.set_tab_width`: the prompt the indent chip opens.
fn setTabWidth(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Tab width");
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    const cur = try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{app.cfg.editor.tab_width});
    try state.buf.appendSlice(app.gpa, cur);
    state.caret = state.buf.items.len;
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .tab_width } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's answer: 1…16 applies to the config and every open buffer.
pub fn acceptTabWidth(app: *App, text: []const u8) Allocator.Error!void {
    const n = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t"), 10) catch 0;
    if (n < 1 or n > 16) {
        app.toast("tab width: 1…16, not \"{s}\"", .{text});
        return;
    }
    app.cfg.editor.tab_width = n;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*e| e.buf.setInputStyle(app.input_style, app.editorConfig()),
        else => {},
    };
    app.toast("tab width: {d}", .{n});
}

/// `view.context_menu_at_focus` (Shift+F10): the tree row under the
/// cursor, the focused panel's row, or the active tab — the same menu a
/// right-click there would open, anchored at the thing's own rect.
fn contextMenuAtFocus(app: *App) CommandError!void {
    if (app.overlay != .none) return;
    const arena = app.frame.allocator();
    switch (app.focus) {
        .tree => {
            const idx = app.tree.cursor;
            if (idx >= app.tree.rows.items.len) return app.diag.fail(arena, "no tree row under the cursor", .{});
            const r = rectOf(app, .{ .tree_node = @intCast(idx) });
            try openTreeMenu(app, idx, r.x, r.y);
        },
        .panel => |which| {
            const cursor: usize = switch (which) {
                .todos => app.todos.list.cursor,
                .git => app.git.rail.cursor,
                .http => app.http_panel.list.cursor,
                .diagnostics => app.lsp.panel.cursor,
                .notes, .findings, .sessions => return app.diag.fail(arena, "{s}: no menu in this build", .{@tagName(which)}),
            };
            const r = rectOf(app, .{ .row = .{ .panel = which, .idx = @intCast(cursor) } });
            const m: Mouse = .{ .x = r.x, .y = r.y, .kind = .press, .button = .left };
            switch (which) {
                .todos => try @import("../todos.zig").kebabMouse(app, @intCast(cursor), m),
                .git => try @import("git.zig").kebabMouse(app, @intCast(cursor), m),
                .http => try @import("http_panel.zig").kebabMouse(app, @intCast(cursor), m),
                .diagnostics => try @import("lsp.zig").rowMouse(app, @intCast(cursor), .{ .x = r.x, .y = r.y, .kind = .press, .button = .right }),
                .notes, .findings, .sessions => {},
            }
        },
        .pane => |id| {
            // The strip tab of the pane, if the frame painted one.
            var i = app.hits.items.items.len;
            while (i > 0) {
                i -= 1;
                const e = app.hits.items.items[i];
                if (e.target != .tab) continue;
                const layout = app.layouts.current();
                const lid = (try layout.leafAt(arena, e.target.tab.leaf)) orelse continue;
                const leaf = layout.leaf(lid) orelse continue;
                if (e.target.tab.idx < leaf.tabs.items.len and leaf.tabs.items[e.target.tab.idx] == id) {
                    return openTabMenu(app, id, e.rect.x, e.rect.y);
                }
            }
            if (app.panes.editor(id) != null) {
                const c: @import("../ui/editor_view.zig").Cursor = app.cursor_pos orelse .{ .x = 0, .y = 1 };
                return openEditorMenu(app, c.x, c.y);
            }
            const r = rectOf(app, .{ .pane = id });
            try openTabMenu(app, id, r.x, r.y);
        },
        .overlay => {},
    }
}

/// Where the last frame painted `target`, or the top-left corner.
fn rectOf(app: *App, target: @import("../ui/hit.zig").HitTarget) @import("../ui/rect.zig") {
    for (app.hits.items.items) |e| if (std.meta.eql(e.target, target)) return e.rect;
    return .{ .x = 0, .y = 1, .w = 1, .h = 1 };
}

/// The tree row's path when the tree has focus, else the active file's.
fn copyPath(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const rel: []const u8 = blk: {
        if (app.focus == .tree and app.tree.cursor < app.tree.rows.items.len) break :blk app.tree.rows.items[app.tree.cursor].rel;
        const e = try app.requireEditor();
        break :blk app.relPath(e.buf.path orelse return app.diag.fail(arena, "no file name", .{}));
    };
    try app.clipboard.set(rel, false);
    app.toast("copied {s}", .{rel});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "tab menu: Save leads when dirty; close_others / close_right keep dirty tabs; copy_path reads the tree row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const a = try app.openScratch();
    const b = try app.openScratch();
    const c = try app.openScratch();
    const d = try app.openScratch();
    try openTabMenu(&app, b, 3, 1);
    try t.expect(app.overlay == .menu);
    try t.expectEqual(b, app.active.?);
    try t.expectEqualStrings("Close", app.overlay.menu.items[0].label);
    app.activeEditor().?.buf.dirty = true;
    try openTabMenu(&app, b, 3, 1);
    try t.expectEqualStrings("Save", app.overlay.menu.items[0].label);
    app.overlay.deinit(app.gpa);
    app.panes.editor(d).?.buf.dirty = true;
    try command.run(&app, .{ .static = .@"buffer.close_right" });
    try t.expect(app.panes.get(c) == null);
    try t.expect(app.panes.get(d) != null);
    try t.expectEqual(b, app.active.?);
    try command.run(&app, .{ .static = .@"buffer.close_others" });
    try t.expect(app.panes.get(a) == null);
    try t.expect(app.panes.get(d) != null);
    try t.expectEqual(@as(usize, 2), app.panes.count());
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"file.copy_path" }));
    try openEditorMenu(&app, 5, 5);
    try t.expectEqualStrings("Go to definition", app.overlay.menu.items[6].label);
    try openModeMenu(&app, 0, 9);
    try t.expect(app.overlay.menu.items[1].checked);
}
