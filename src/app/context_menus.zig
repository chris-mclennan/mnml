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
    .@"menu.pin_row" = &pinRow,
    .@"menu.unpin_row" = &unpinRow,
    .@"menu.hide_row" = &hideRow,
    .@"menu.copy_id" = &copyRowId,
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

/// The field a request-pane right-click landed on: the menu's title.
pub const RequestField = enum {
    url,
    body,
    headers,
    response,

    pub fn title(f: RequestField) []const u8 {
        return switch (f) {
            .url => "URL",
            .body => "Body",
            .headers => "Headers",
            .response => "Response",
        };
    }
};

/// A request pane's URL / body / response: send, paste, copy, flip —
/// titled by the field under the pointer.
pub fn openRequestFieldMenu(app: *App, field: RequestField, x: u16, y: u16) Allocator.Error!void {
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
    try app.openMenu(field.title(), rows, x, y);
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
        .{ .label = if (p.pinned()) "Unpin tab" else "Pin tab", .action = .{ .command = .@"buffer.pin_toggle" }, .separator_before = true },
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

// ─── the curated `+` menu ───────────────────────────────────────────────

/// The section icons and the twins `ui.ascii_icons` paints instead.
const icon_new_nerd = "\u{f067}"; //  fa-plus
const icon_new_ascii = "+";
const icon_open_nerd = "\u{f07c}"; //  fa-folder_open
const icon_open_ascii = "o";
const icon_panels_nerd = "\u{f0db}"; //  fa-table_columns
const icon_panels_ascii = "#";
const icon_tools_nerd = "\u{f0ad}"; //  fa-wrench
const icon_tools_ascii = "%";
const icon_integrations_nerd = "\u{f1e6}"; //  fa-plug
const icon_integrations_ascii = "&";
const icon_pin_nerd = "\u{f08d}"; //  fa-thumbtack
const icon_pin_ascii = "*";

/// The five sections, each a `▸` row opening its own list. A row's
/// command id is what `ui.plus_menu_pinned` / `plus_menu_hidden` name.
pub const plus_sections = [_]MenuItem{
    .{ .label = "New", .action = .none, .icon = icon_new_nerd, .icon_ascii = icon_new_ascii, .submenu = &.{
        .{ .label = "New file…", .action = .{ .command = .@"file.new" } },
        .{ .label = "New tab page", .action = .{ .command = .@"tab.new" } },
        .{ .label = "New request", .action = .{ .command = .@"http.new" } },
        .{ .label = "New note", .action = .{ .command = .@"notes.new" } },
        .{ .label = "New TODO", .action = .{ .command = .@"todos.new" } },
        .{ .label = "New shell", .action = .{ .command = .@"term.shell" } },
        .{ .label = "New dock note", .action = .{ .command = .@"dock.new_text" } },
    } },
    .{ .label = "Open", .action = .none, .icon = icon_open_nerd, .icon_ascii = icon_open_ascii, .submenu = &.{
        .{ .label = "Open file…", .action = .{ .command = .@"picker.files" } },
        .{ .label = "Recent files…", .action = .{ .command = .@"picker.recent" } },
        .{ .label = "Switch buffer…", .action = .{ .command = .@"picker.buffers" } },
        .{ .label = "Pinned files…", .action = .{ .command = .@"harpoon.menu" } },
        .{ .label = "Open image…", .action = .{ .command = .@"view.image_open" } },
    } },
    .{ .label = "Panels", .action = .none, .icon = icon_panels_nerd, .icon_ascii = icon_panels_ascii, .submenu = &.{
        .{ .label = "TODOs", .action = .{ .command = .@"view.activity_todos" } },
        .{ .label = "Git", .action = .{ .command = .@"view.activity_git" } },
        .{ .label = "Diagnostics", .action = .{ .command = .@"lsp.diagnostics" } },
        .{ .label = "HTTP", .action = .{ .command = .@"view.activity_http" } },
        .{ .label = "Notes", .action = .{ .command = .@"view.activity_notes" } },
        .{ .label = "Findings", .action = .{ .command = .@"view.activity_findings" } },
        .{ .label = "Sessions", .action = .{ .command = .@"view.activity_sessions" } },
        .{ .label = "Agents", .action = .{ .command = .@"view.activity_agents" } },
    } },
    .{ .label = "Tools", .action = .none, .icon = icon_tools_nerd, .icon_ascii = icon_tools_ascii, .submenu = &.{
        .{ .label = "Terminal", .action = .{ .command = .@"term.shell" } },
        .{ .label = "Claude Code", .action = .{ .command = .@"ai.claude_code" } },
        .{ .label = "Codex", .action = .{ .command = .@"ai.codex" } },
        .{ .label = "Browser (CDP)", .action = .{ .command = .@"browser.open" } },
        .{ .label = "WebSocket…", .action = .{ .command = .@"ws.connect" } },
        .{ .label = "Cheatsheet", .action = .{ .command = .@"view.cheatsheet" } },
        .{ .label = "Settings", .action = .{ .command = .@"view.settings" } },
        .{ .label = "Messages", .action = .{ .command = .@"messages.show" } },
    } },
    .{ .label = "Integrations", .action = .none, .icon = icon_integrations_nerd, .icon_ascii = icon_integrations_ascii, .submenu = &.{
        .{ .label = "Installed", .action = .{ .command = .@"integrations.show_installed" } },
        .{ .label = "Marketplace", .action = .{ .command = .@"integrations.show_marketplace" } },
        .{ .label = "In development", .action = .{ .command = .@"integrations.show_in_dev" } },
        .{ .label = "Refresh", .action = .{ .command = .@"integrations.refresh" } },
    } },
};

fn isPinned(app: *App, id: []const u8) bool {
    for (app.plus_pinned.items) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

fn isHidden(app: *App, id: []const u8) bool {
    for (app.plus_hidden.items) |h| if (std.mem.eql(u8, h, id)) return true;
    return false;
}

/// The label a section gives a command, so a pinned row reads the same
/// at the top as it does inside its section.
fn sectionLabel(id: command.CommandId) []const u8 {
    for (plus_sections) |sec| for (sec.submenu) |row| if (row.action == .command and row.action.command == id) return row.label;
    return command.title(id);
}

/// The strip's `+`: the pinned rows first, then the five sections.
pub fn openNewTabMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    for (app.plus_pinned.items) |id| {
        const cmd = command.by_name.get(id) orelse continue;
        try rows.append(app.gpa, .{ .label = sectionLabel(cmd), .action = .{ .command = cmd }, .icon = icon_pin_nerd, .icon_ascii = icon_pin_ascii });
    }
    const had_pins = rows.items.len > 0;
    for (plus_sections, 0..) |sec, i| {
        var row = sec;
        row.separator_before = had_pins and i == 0;
        try rows.append(app.gpa, row);
    }
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu("New", owned, x, y);
    app.overlay.menu.curatable = true;
}

/// Open row `idx`'s child beside it (the hidden rows of a curatable
/// menu left out).
pub fn openSubmenu(app: *App, idx: usize) Allocator.Error!void {
    const m = &app.overlay.menu;
    if (idx >= m.items.len) return;
    const src = m.items[idx].submenu;
    var list: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer list.deinit(app.gpa);
    for (src) |row| {
        if (m.curatable and row.action == .command and isHidden(app, command.name(row.action.command))) continue;
        try list.append(app.gpa, row);
    }
    if (list.items.len == 0) try list.append(app.gpa, .{ .label = "(every row hidden — Settings restores them)", .action = .none });
    const owned = try list.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    m.closeSub(app.gpa);
    m.cursor = idx;
    m.sub = .{ .parent = idx, .items = owned };
    app.needs_render = true;
}

/// The pin / hide / copy-id list for `item`, beside row `parent`; the
/// item's command rides in `app.menu_ctx` to the row's runner.
pub fn openCuration(app: *App, parent: usize, item: MenuItem) Allocator.Error!void {
    const m = &app.overlay.menu;
    if (item.action != .command) return;
    const cmd = item.action.command;
    app.menu_ctx = cmd;
    const pinned = isPinned(app, command.name(cmd));
    const owned = try items(app, &.{
        if (pinned) .{ .label = "Unpin", .action = .{ .command = .@"menu.unpin_row" } } else .{ .label = "Pin to top", .action = .{ .command = .@"menu.pin_row" } },
        .{ .label = "Hide this row", .action = .{ .command = .@"menu.hide_row" } },
        .{ .label = "Copy command id", .action = .{ .command = .@"menu.copy_id" } },
    });
    errdefer app.gpa.free(owned);
    m.closeSub(app.gpa);
    m.sub = .{ .parent = parent, .items = owned };
    app.needs_render = true;
}

fn persistPlus(app: *App) Allocator.Error!void {
    const settings = @import("settings.zig");
    _ = try settings.persist(app, .home, &.{ "ui", "plus_menu_pinned" }, @as([]const []const u8, app.plus_pinned.items));
    _ = try settings.persist(app, .home, &.{ "ui", "plus_menu_hidden" }, @as([]const []const u8, app.plus_hidden.items));
}

fn removeFrom(app: *App, list: *std.ArrayListUnmanaged([]u8), id: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], id)) {
            app.gpa.free(list.orderedRemove(i));
        } else i += 1;
    }
}

fn curationTarget(app: *App) CommandError!command.CommandId {
    return app.menu_ctx orelse app.diag.fail(app.frame.allocator(), "no menu row to curate", .{});
}

fn pinRow(app: *App) CommandError!void {
    const cmd = try curationTarget(app);
    const id = command.name(cmd);
    removeFrom(app, &app.plus_hidden, id);
    if (!isPinned(app, id)) try app.plus_pinned.append(app.gpa, try app.gpa.dupe(u8, id));
    try persistPlus(app);
    app.toast("pinned {s} to the top of +", .{id});
}

fn unpinRow(app: *App) CommandError!void {
    const cmd = try curationTarget(app);
    removeFrom(app, &app.plus_pinned, command.name(cmd));
    try persistPlus(app);
    app.toast("unpinned {s}", .{command.name(cmd)});
}

fn hideRow(app: *App) CommandError!void {
    const cmd = try curationTarget(app);
    const id = command.name(cmd);
    removeFrom(app, &app.plus_pinned, id);
    if (!isHidden(app, id)) try app.plus_hidden.append(app.gpa, try app.gpa.dupe(u8, id));
    try persistPlus(app);
    app.toast("hid {s} from + (ui.plus_menu_hidden)", .{id});
}

fn copyRowId(app: *App) CommandError!void {
    const cmd = try curationTarget(app);
    try app.clipboard.set(command.name(cmd), false);
    app.toast("copied {s}", .{command.name(cmd)});
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
    var left_of_keep: usize = 0;
    const keep_idx = std.mem.indexOfScalar(PaneId, tabs, keep) orelse tabs.len;
    // Right to left: `buffer.reopen` pops the closed list, so the Undo
    // chip's reopens then land in the order the tabs had.
    var i = tabs.len;
    while (i > 0) {
        i -= 1;
        const id = tabs[i];
        if (id == keep) continue;
        if (after) |a| if (i <= a) continue;
        const p = app.panes.get(id) orelse continue;
        if (p.dirty()) {
            skipped += 1;
            continue;
        }
        // A pinned tab is immune to the bulk closes.
        if (p.pinned()) continue;
        const is_file = if (p.asEditor()) |e| e.buf.path != null else p.* == .md_preview;
        if (is_file) {
            reopenable += 1;
            if (i < keep_idx) left_of_keep += 1;
        }
        try app.forceClosePane(id);
    }
    app.setActive(keep);
    if (skipped > 0) app.toast("kept {d} tab(s) with unsaved changes", .{skipped});
    // The Undo chip: the closed files come back in one click, where they
    // were — the kept tab slides back past the ones that sat left of it.
    if (reopenable > 0) {
        const keep_at = (std.mem.indexOfScalar(PaneId, (try siblingTabs(app)), keep) orelse 0) + left_of_keep;
        try app.armUndo(.{ .reopen = .{ .n = reopenable, .keep = keep, .keep_at = keep_at } }, "closed {d} tab(s)", .{reopenable});
    }
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

test "the request field menu is titled by the field under the pointer" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    inline for (.{ .{ RequestField.url, "URL" }, .{ RequestField.body, "Body" }, .{ RequestField.response, "Response" } }) |case| {
        try openRequestFieldMenu(&app, case[0], 3, 3);
        try t.expect(app.overlay == .menu);
        try t.expectEqualStrings(case[1], app.overlay.menu.title);
        try t.expectEqualStrings("Send", app.overlay.menu.items[0].label);
        app.overlay.deinit(app.gpa);
        app.overlay = .none;
    }
}

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

fn screenOf(app: *App) ![]u8 {
    try app.render();
    return @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
}

test "the + menu: five ▸ sections, → opens a child beside its parent, ← steps back, Enter runs the child's row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try openNewTabMenu(&app, 4, 1);
    const m = &app.overlay.menu;
    try t.expect(m.curatable);
    try t.expectEqual(@as(usize, 5), m.items.len);
    try t.expectEqualStrings("Panels", m.items[2].label);
    try t.expect(m.items[2].submenu.len == 8);
    const closed = try screenOf(&app);
    defer t.allocator.free(closed);
    // The glyph column and the ▸ marker paint; no child yet.
    try t.expect(std.mem.indexOf(u8, closed, "\u{f067} New") != null);
    try t.expect(std.mem.indexOf(u8, closed, "Panels") != null);
    try t.expect(std.mem.indexOf(u8, closed, "▸") != null);
    try t.expect(std.mem.indexOf(u8, closed, "New tab page") == null);
    // → opens New's child, anchored beside the row; the frame registers its rows.
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expect(m.sub != null);
    try t.expectEqual(@as(usize, 0), m.sub.?.parent);
    try t.expectEqual(@as(usize, 7), m.sub.?.items.len);
    const open = try screenOf(&app);
    defer t.allocator.free(open);
    try t.expect(std.mem.indexOf(u8, open, "New tab page") != null);
    var child_hits: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 1) {
        child_hits += 1;
    };
    try t.expectEqual(@as(usize, 7), child_hits);
    try t.expect(m.sub.?.rect.x >= 4);
    // j moves in the child, ← closes it, the parent cursor stays.
    try app.handle(.{ .key = app_mod.Key.char('j') });
    try t.expectEqual(@as(usize, 1), m.sub.?.cursor);
    try app.handle(.{ .key = app_mod.Key.named(.left) });
    try t.expect(m.sub == null);
    try t.expectEqual(@as(usize, 0), m.cursor);
    // Enter on a parent opens it; Enter on the second child row runs tab.new.
    const tabs_before = app.layouts.layouts.items.len;
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(m.sub != null);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(tabs_before + 1, app.layouts.layouts.items.len);
    // Under ascii icons the column paints the twins and ▸ is `>`.
    app.cfg.ui.ascii_icons = true;
    try openNewTabMenu(&app, 4, 1);
    const ascii = try screenOf(&app);
    defer t.allocator.free(ascii);
    try t.expect(std.mem.indexOf(u8, ascii, "\u{f067}") == null);
    try t.expect(std.mem.indexOf(u8, ascii, "+ New") != null);
    try t.expect(std.mem.indexOf(u8, ascii, "# Panels") != null);
    try t.expect(std.mem.indexOf(u8, ascii, ">") != null);
}

test "curation: → on a child row offers Pin / Hide / Copy; a pin lands on top and in the home config; a hide drops the row" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try openNewTabMenu(&app, 4, 1);
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // New ▸
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // New tab page
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // curation
    const m = &app.overlay.menu;
    try t.expect(m.sub != null);
    try t.expectEqualStrings("Pin to top", m.sub.?.items[0].label);
    try t.expectEqual(command.CommandId.@"tab.new", app.menu_ctx.?);
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // pin
    try t.expect(app.overlay == .none);
    try t.expectEqual(@as(usize, 1), app.plus_pinned.items.len);
    try t.expectEqualStrings("tab.new", app.plus_pinned.items[0]);
    const cfg_text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(cfg_text);
    try t.expect(std.mem.indexOf(u8, cfg_text, ".plus_menu_pinned = .{\"tab.new\"}") != null);
    // Re-opened: the pinned row leads, the sections follow after a rule.
    try openNewTabMenu(&app, 4, 1);
    try t.expectEqual(@as(usize, 6), m.items.len);
    try t.expectEqualStrings("New tab page", m.items[0].label);
    try t.expect(m.items[1].separator_before);
    // → on the pinned row: Unpin leads; Hide drops it from the New child too.
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqualStrings("Unpin", m.sub.?.items[0].label);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // hide
    try t.expectEqual(@as(usize, 0), app.plus_pinned.items.len);
    try t.expectEqualStrings("tab.new", app.plus_hidden.items[0]);
    try openNewTabMenu(&app, 4, 1);
    try t.expectEqual(@as(usize, 5), m.items.len);
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqual(@as(usize, 6), m.sub.?.items.len);
    for (m.sub.?.items) |it| try t.expect(!std.mem.eql(u8, it.label, "New tab page"));
    // A click on the child row's kebab opens the curation for that row.
    try app.render();
    var kebab: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 3) {
        kebab = h.rect;
    };
    try t.expect(kebab != null);
    try app.handle(.{ .mouse = .{ .x = kebab.?.x, .y = kebab.?.y, .kind = .press, .button = .left } });
    try t.expectEqualStrings("Pin to top", m.sub.?.items[0].label);
    try t.expectEqual(command.CommandId.@"file.new", app.menu_ctx.?);
    // Copy id lands on the clipboard.
    try app.handle(.{ .key = app_mod.Key.named(.end) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqualStrings("file.new", app.clipboard.text());
}
