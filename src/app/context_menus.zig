//! The right-click menus: what a tab, a tree row, the editor body, the
//! statusline mode chip and the strip's `+` offer. Every row is a
//! `MenuAction{ .command }`, so a row cannot name an id that does not
//! exist; the opener makes the clicked thing current first (the tab
//! active, the tree cursor on the row) and the commands act on that.
//!
//! The Zig-only commands the rows need — `buffer.close_others`,
//! `buffer.close_right`, `file.copy_path` — have their runners here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;

pub const table = .{
    .@"buffer.close_others" = &closeOthers,
    .@"buffer.close_right" = &closeRight,
    .@"file.copy_path" = &copyPath,
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
    for (tabs, 0..) |id, i| {
        if (id == keep) continue;
        if (after) |a| if (i <= a) continue;
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            skipped += 1;
            continue;
        }
        try app.forceClosePane(id);
    }
    app.setActive(keep);
    if (skipped > 0) app.toast("kept {d} tab(s) with unsaved changes", .{skipped});
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
