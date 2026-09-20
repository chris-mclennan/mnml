//! The right-click menus: what a tab, a tree row, the editor body, the
//! statusline mode chip offer — and the `+`'s `Create…` menu. Every row is a
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
const activity_bar = @import("activity_bar.zig");
const side = @import("side.zig");
const sessions = @import("../sessions.zig");
const terminal_glyph = @import("terminal_glyph.zig");
const claude_mark = @import("claude_mark.zig");
const pty_pane = @import("pty_pane.zig");
const Config = @import("../config/Config.zig");

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

pub fn items(app: *App, rows: []const MenuItem) Allocator.Error![]MenuItem {
    return app.gpa.dupe(MenuItem, rows);
}

/// Full screen hides every other way back, so a pane's menu ends
/// with one while inside (the tab menu and the editor menu).
const exit_fullscreen_row: MenuItem = .{ .label = "Exit full screen", .action = .{ .command = .@"view.fullscreen" }, .separator_before = true };

fn itemsWithExit(app: *App, rows: []const MenuItem) Allocator.Error![]MenuItem {
    if (!app.zen) return items(app, rows);
    return std.mem.concat(app.gpa, MenuItem, &.{ rows, &.{exit_fullscreen_row} });
}

/// The editor body: clipboard, undo, selection, the LSP verbs and the
/// fold, then Save.
pub fn openEditorMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try itemsWithExit(app, &.{
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
        .{ .label = "Expand selection", .action = .{ .command = .@"lsp.selection_expand" } },
        .{ .label = "Toggle fold", .action = .{ .command = .@"editor.toggle_fold" } },
        // right-click: Rust's two AI rows.
        .{ .label = "Explain with Claude", .action = .{ .command = .@"ai.explain" }, .separator_before = true },
        .{ .label = "Ask Claude…", .action = .{ .command = .@"ai.ask" } },
        .{ .label = "Save", .action = .{ .command = .@"file.save" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Editor", rows, x, y);
}

/// The gutter's right-click: the breakpoint on the cursor line (the
/// press placed the cursor there) — add / remove, its condition, hit
/// count, log message, enabled flag; then the session verbs.
pub fn openGutterMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const dap = @import("dap.zig");
    const has, const enabled = dap.breakpointAtCursor(app);
    const rows = try items(app, &.{
        .{ .label = if (has) "Remove breakpoint" else "Add breakpoint", .action = .{ .command = .@"dap.toggle_breakpoint" } },
        .{ .label = if (enabled) "Disable breakpoint" else "Enable breakpoint", .action = .{ .command = .@"dap.toggle_breakpoint_enabled" } },
        .{ .label = "Edit condition\u{2026}", .action = .{ .command = .@"dap.toggle_breakpoint_conditional" }, .separator_before = true },
        .{ .label = "Edit hit count\u{2026}", .action = .{ .command = .@"dap.set_breakpoint_hit_count" } },
        .{ .label = "Add log message\u{2026}", .action = .{ .command = .@"dap.set_breakpoint_log_message" } },
        .{ .label = "Start debugging", .action = .{ .command = .@"dap.run" }, .separator_before = true },
        .{ .label = "Continue", .action = .{ .command = .@"dap.continue" } },
        .{ .label = "Evaluate word under cursor", .action = .{ .command = .@"dap.evaluate_hover" } },
        // right-click: Rust's git rows for the line.
        .{ .label = "Peek change", .action = .{ .command = .@"git.peek_change" }, .separator_before = true },
        .{ .label = "Toggle blame", .action = .{ .command = .@"git.blame_toggle" } },
        .{ .label = "Open on remote", .action = .{ .command = .@"git.browse" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Breakpoint", rows, x, y);
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

/// A strip tab: Save (when dirty) first, then the close family, the
/// splits, the file rows (a markdown preview, the two reveals, the
/// path) and — for a pty — the session verbs (Rust
/// `open_tab_context_menu`). The tab is made active before the menu
/// opens, so the rows act on it.
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
    });
    // right-click: the file rows, for a tab that names a file on disk.
    const file_path: ?[]const u8 = if (app.panes.editor(pane)) |e| e.buf.doc.path else null;
    if (file_path) |path| {
        if (@import("md_preview.zig").isMarkdownPath(path)) try rows.append(app.gpa, .{ .label = "Preview markdown", .action = .{ .command = .@"markdown.preview" }, .separator_before = true });
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Reveal in tree", .action = .{ .command = .@"view.reveal_in_tree" }, .separator_before = true },
            .{ .label = "Reveal in Finder", .action = .{ .command = .@"view.reveal_active" } },
        });
    }
    try rows.append(app.gpa, .{ .label = "Copy path", .action = .{ .command = .@"file.copy_path" }, .separator_before = file_path == null });
    // right-click: a pty tab's session verbs (Rust's Rename / Restart /
    // Clear rows on a Pty tab).
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    if (app.panes.pty(pane)) |pt| {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Rename…", .action = .{ .command = .@"term.rename" }, .separator_before = true },
            .{ .label = "Restart", .action = .{ .command = .@"term.restart" } },
            .{ .label = "Clear (Ctrl+L)", .action = .{ .command = .@"term.clear" } },
        });
        // colors: the accent, on the tab as on the SESSIONS row.
        try rows.append(app.gpa, .{ .label = "Color", .action = .none, .submenu = try sessions.colorMenuRows(mem.allocator(), .{ .target = .{ .pane = pane }, .name = "" }, pt.accent_color) });
        // The mark this tab is wearing, changed from the tab itself —
        // a Claude session's is the Claude one, not the terminal's.
        const claude_tab = if (pty_pane.productOf(app, pt)) |prod| prod == .claude else false;
        try rows.append(app.gpa, if (claude_tab)
            .{ .label = "Mark", .action = .none, .submenu = try claudeMarkRows(app, mem.allocator()) }
        else
            .{ .label = "Mark", .action = .none, .submenu = try terminalIconRows(app, mem.allocator()) });
    }
    if (app.zen) try rows.append(app.gpa, exit_fullscreen_row);
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(p.title(), owned, x, y);
    app.overlay.menu.mem = mem;
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
    // The clipboard rows the Files pane's menu has: the chords work on
    // the tree already (`docs/KEYMAP_PROFILES.md`), the menu is where a
    // mouse user finds them.
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Cut", .action = .{ .command = .@"file.cut" }, .separator_before = true },
        .{ .label = "Copy", .action = .{ .command = .@"file.copy" } },
        .{ .label = "Paste here", .action = .{ .command = .@"file.paste" } },
        .{ .label = "Duplicate", .action = .{ .command = .@"file.duplicate" } },
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

/// The branch chip (Rust `open_statusline_branch_context_menu`): the
/// status pane, the graph, the branch verbs, the remote verbs, the
/// stash pair, the commit pair.
pub fn openBranchMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Status / staging", .action = .{ .command = .@"git.status_pane" } },
        .{ .label = "Commit graph", .action = .{ .command = .@"git.graph" } },
        .{ .label = "Checkout branch…", .action = .{ .command = .@"git.checkout" }, .separator_before = true },
        .{ .label = "New branch…", .action = .{ .command = .@"git.new_branch" } },
        .{ .label = "Fetch", .action = .{ .command = .@"git.fetch" }, .separator_before = true },
        .{ .label = "Pull", .action = .{ .command = .@"git.pull" } },
        .{ .label = "Push", .action = .{ .command = .@"git.push" } },
        .{ .label = "Stash…", .action = .{ .command = .@"git.stash" }, .separator_before = true },
        .{ .label = "Stash pop", .action = .{ .command = .@"git.stash_pop" } },
        .{ .label = "Commit…", .action = .{ .command = .@"git.commit" }, .separator_before = true },
        .{ .label = "AI commit message", .action = .{ .command = .@"git.ai_commit" } },
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

/// The statusline's file chip: Rust's "Buffer" menu — the two reveals,
/// the three copies, Close.
pub fn openFileChipMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const e = app.activeEditor() orelse return;
    const path = e.buf.doc.path orelse {
        app.toast("no saved file", .{});
        return;
    };
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const abs = try arena.dupe(u8, path);
    const rows = try items(app, &.{
        .{ .label = "Reveal in tree", .action = .{ .command = .@"view.reveal_in_tree" } },
        .{ .label = "Reveal in Finder", .action = .{ .command = .@"view.reveal_active" } },
        .{ .label = "Copy path", .action = .{ .command = .@"file.copy_path" }, .separator_before = true },
        .{ .label = "Copy absolute path", .action = .{ .copy_text = abs } },
        .{ .label = "Copy file name", .action = .{ .copy_text = std.fs.path.basename(abs) } },
        .{ .label = "Close buffer", .action = .{ .command = .@"buffer.close" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Buffer", rows, x, y, mem);
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
    // // changed (git-more2): a failed git op's toast leads with the command log.
    const is_git_log = if (app.toasts.items[at].id) |tid| std.mem.eql(u8, tid, @import("git.zig").log_toast_id) else false;
    // The 0.2-manifests notice: *Don't show again* persists the flag.
    const is_toml_notice = if (app.toasts.items[at].id) |tid| std.mem.eql(u8, tid, @import("integrations.zig").toml_toast_id) else false;
    const rows = if (is_toml_notice) try items(app, &.{
        .{ .label = "Don't show again", .action = .{ .command = .@"integrations.dismiss_toml_notice" } },
        .{ .label = "Dismiss", .action = .{ .command = .@"toast.dismiss_clicked" }, .separator_before = true },
        .{ .label = "Copy text", .action = .{ .command = .@"toast.copy_clicked" } },
        .{ .label = "Dismiss all", .action = .{ .command = .@"toast.dismiss_all" }, .separator_before = true },
    }) else if (is_git_log) try items(app, &.{
        .{ .label = "Show in the command log", .action = .{ .command = .@"git.command_log" } },
        .{ .label = "Dismiss", .action = .{ .command = .@"toast.dismiss_clicked" }, .separator_before = true },
        .{ .label = "Copy text", .action = .{ .command = .@"toast.copy_clicked" } },
        .{ .label = "Dismiss all", .action = .{ .command = .@"toast.dismiss_all" }, .separator_before = true },
    }) else try items(app, &.{
        .{ .label = "Dismiss", .action = .{ .command = .@"toast.dismiss_clicked" } },
        .{ .label = "Copy text", .action = .{ .command = .@"toast.copy_clicked" } },
        .{ .label = "Dismiss all", .action = .{ .command = .@"toast.dismiss_all" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Toast", rows, x, y);
}

/// A right-click on an activity-bar section (Rust `mouse/right_click.rs`):
/// "Show X" first — the id a left click runs — then the section's quick
/// verbs. Findings has only the first row, as in Rust.
pub fn openRailMenu(app: *App, s: activity_bar.Section, x: u16, y: u16) Allocator.Error!void {
    const Section = activity_bar.Section;
    const show: MenuItem = .{ .label = switch (s) {
        inline else => |tag| comptime ("Show " ++ Section.meta(tag).label),
    }, .action = if (activity_bar.commandOf(s)) |id| .{ .command = id } else .{ .script_section_show = app.script_sections.active } };
    const verbs: []const MenuItem = switch (s) {
        .explorer => &.{
            .{ .label = "Reveal active file", .action = .{ .command = .@"view.reveal_in_tree" } },
            .{ .label = "Refresh tree", .action = .{ .command = .@"tree.refresh" } },
        },
        // // changed (search-section): the section's own verbs; the grep
        // pane stays reachable as *Open as pane*.
        .search => &.{
            .{ .label = "Refresh", .action = .{ .command = .@"search.refresh" } },
            .{ .label = "Open as pane", .action = .{ .command = .@"search.open_pane" } },
            .{ .label = "Find in files\u{2026}", .action = .{ .command = .@"find.grep" } },
        },
        .git => &.{
            .{ .label = "Open git graph", .action = .{ .command = .@"git.graph" } },
            .{ .label = "Fetch", .action = .{ .command = .@"git.fetch" } },
            .{ .label = "Commit…", .action = .{ .command = .@"git.commit" } },
        },
        .debug => &.{
            .{ .label = "Start debugging", .action = .{ .command = .@"dap.run" } },
            .{ .label = "Toggle breakpoint at cursor", .action = .{ .command = .@"dap.toggle_breakpoint" } },
            .{ .label = "Debug console", .action = .{ .command = .@"dap.repl" } },
        },
        .integrations => &.{
            .{ .label = "Refresh integrations", .action = .{ .command = .@"integrations.refresh" } },
            .{ .label = "Refresh binary cache", .action = .{ .command = .@"integrations.refresh_binary_cache" } },
        },
        .sessions => &.{
            .{ .label = "+ New Claude Code session", .action = .{ .command = .@"ai.claude_code_new" } },
            .{ .label = "+ New session in a worktree…", .action = .{ .command = .@"ai.new_session_worktree" } },
            .{ .label = "+ New Codex session", .action = .{ .command = .@"ai.codex_new" } },
            .{ .label = "+ New cloud run…", .action = .{ .command = .@"cloud_agents.new_run" } },
            .{ .label = "Open as a table", .action = .{ .command = .@"sessions.table" } },
        },
        .http => &.{
            .{ .label = "+ New request", .action = .{ .command = .@"http.new" } },
            .{ .label = "Paste curl from clipboard", .action = .{ .command = .@"http.paste_curl" } },
        },
        .notes => &.{.{ .label = "+ New note", .action = .{ .command = .@"notes.new" } }},
        .todos => &.{.{ .label = "Rescan", .action = .{ .command = .@"todos.refresh" } }},
        .findings => &.{},
        // // changed (lua-track): the SCRIPTS section's verbs.
        .scripts => &.{
            .{ .label = "Reload init.lua", .action = .{ .command = .@"script.reload" } },
            .{ .label = "New workspace init.lua", .action = .{ .command = .@"script.new_init" } },
        },
        // // changed (lua-plumbing): a script's section — the list's
        // own Refresh, the same row its kebab carries.
        .script => if (@import("script_section.zig").active(app)) |sec|
            try items(app, &.{.{ .label = "Refresh", .action = .{ .script_list_refresh = sec.list } }})
        else
            &.{},
        .diagnostics, .outline => &.{},
    };
    // A section with a column surface can change sides (VS Code's
    // "Move to right side"); a pane section has no side.
    // // changed (bottom-dock): three hosts, so two move rows — the
    // other column, and the dock (or, from the dock, back up).
    var moves: [2]MenuItem = undefined;
    var n_moves: usize = 0;
    if (side.surface(s) != null) {
        const here = side.sideOf(app, s);
        for ([_]side.Side{ .left, .right, .bottom }) |dest| {
            if (dest == here or n_moves == moves.len) continue;
            moves[n_moves] = .{
                .label = switch (dest) {
                    .left => "Move to left side",
                    .right => "Move to right side",
                    .bottom => "Move to bottom dock",
                },
                .action = .{ .move_section = .{ .section = s, .side = dest } },
            };
            n_moves += 1;
        }
    }
    // // changed (sidebar-autohide): every rail row also carries the
    // column's own three words — the rail IS the column's edge, so it
    // is where a user goes looking for "stop doing that".
    var mode_row = sidebarModeRow(app);
    mode_row.separator_before = true;
    const rows = try app.gpa.alloc(MenuItem, 1 + n_moves + verbs.len + 1);
    errdefer app.gpa.free(rows);
    rows[0] = show;
    @memcpy(rows[1 .. 1 + n_moves], moves[0..n_moves]);
    @memcpy(rows[1 + n_moves .. 1 + n_moves + verbs.len], verbs);
    rows[rows.len - 1] = mode_row;
    try app.openMenu(s.meta().label, rows, x, y);
}

/// `Sidebar \u{25b8}` — the three words `ui.sidebar` takes, with the one
/// in force ticked, plus the session pin when there is something to pin.
/// // changed (sidebar-autohide).
/// A parent row's `submenu` is a slice the open menu keeps a pointer
/// to, not a copy, so it cannot be a temporary of the function that
/// built the row. These three are the same three rows every time —
/// only the tick moves — so they live here, rewritten on each open. One
/// menu is open at a time, and `openMenu` frees the previous one before
/// this is written again.
var sidebar_mode_kids: [3]MenuItem = undefined;

pub fn sidebarModeRow(app: *const App) MenuItem {
    const cur = app.cfg.ui.sidebar;
    sidebar_mode_kids = .{
        .{ .label = "Always (docked)", .action = .{ .command = .@"view.sidebar_mode_always" }, .checked = cur == .always },
        .{ .label = "Auto-hide (reveal on the edge)", .action = .{ .command = .@"view.sidebar_mode_auto" }, .checked = cur == .auto },
        .{ .label = "Hidden (keyboard only)", .action = .{ .command = .@"view.sidebar_mode_hidden" }, .checked = cur == .hidden },
    };
    return .{ .label = "Sidebar", .action = .none, .submenu = &sidebar_mode_kids };
}

/// A right-click on the revealed column's own ground: the three modes
/// and the pin. // changed (sidebar-autohide).
pub fn openSidebarModeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = if (app.sidebar_auto.pinned) "Unpin (back to auto-hide)" else "Pin (dock for this session)", .action = .{ .command = .@"view.sidebar_pin" }, .checked = app.sidebar_auto.pinned },
        sidebarModeRow(app),
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Sidebar", rows, x, y);
}

/// The activity bar's gear (Rust `open_gear_context_menu`): Settings,
/// the palette, the cheatsheet, the theme picker, About.
pub fn openGearMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Settings…", .action = .{ .command = .@"view.settings" } },
        .{ .label = "Command Palette…", .action = .{ .command = .palette } },
        .{ .label = "Cheatsheet…", .action = .{ .command = .@"view.help" } },
        .{ .label = "Themes…", .action = .{ .command = .@"theme.pick" } },
        .{ .label = "About mnml", .action = .{ .command = .@"view.about" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("mnml", rows, x, y);
}

// ─── the curated `+` menu ───────────────────────────────────────────────

/// The section icons and the twins `ui.ascii_icons` paints instead —
/// Rust's `plus_menu_items` (`tui/mouse/down_left.rs`), which names
/// them because a parent's action is nothing the glyph table can key on.
const icon_new_nerd = "\u{f15b}"; //  fa-file
const icon_new_ascii = "f";
const icon_open_nerd = "\u{f07c}"; //  fa-folder_open
const icon_open_ascii = "o";
const icon_ai_nerd = "\u{F06A9}"; // 󰚩 md-robot — the Agents section's
const icon_ai_ascii = "*";
const icon_dock_nerd = "\u{f0db}"; //  fa-columns
const icon_dock_ascii = "#";
const icon_integrations_nerd = "\u{f12e}"; //  fa-puzzle_piece
const icon_integrations_ascii = "&";

/// Rust's `Create…` tree, less the Integrations group (built per open
/// from the enabled integrations) and the "Reopen last closed (N)" row
/// (prepended while there is something to reopen). Each parent is a
/// `▸` row opening its list; a leaf's command id is what
/// `ui.plus_menu_pinned` / `plus_menu_hidden` name.
pub const plus_tree = [_]MenuItem{
    .{ .label = "New", .action = .none, .icon = icon_new_nerd, .icon_ascii = icon_new_ascii, .submenu = &.{
        .{ .label = "Scratch buffer", .action = .{ .command = .@"scratch.new" } },
        .{ .label = "From clipboard", .action = .{ .command = .@"scratch.from_clipboard" } },
        .{ .label = "HTTP request", .action = .{ .command = .@"http.new" } },
        .{ .label = "Shell", .action = .{ .command = .@"term.shell" } },
        .{ .label = "Browser tab", .action = .{ .command = .@"browser.open" } },
        .{ .label = "Tab page", .action = .{ .command = .@"tab.new" } },
    } },
    .{ .label = "Open", .action = .none, .icon = icon_open_nerd, .icon_ascii = icon_open_ascii, .submenu = &.{
        .{ .label = "File…", .action = .{ .command = .@"picker.files" } },
        .{ .label = "Recent files", .action = .{ .command = .@"picker.recent" } },
        .{ .label = "File browser", .action = .{ .command = .@"files.open" } },
        .{ .label = "Dual file panes (commander)", .action = .{ .command = .@"files.open_split" } },
        .{ .label = "Trash", .action = .{ .command = .@"files.trash" } },
    } },
    .{ .label = "AI", .action = .none, .icon = icon_ai_nerd, .icon_ascii = icon_ai_ascii, .submenu = &.{
        .{ .label = "Claude Code session", .action = .{ .command = .@"ai.claude_code_new" } },
        .{ .label = "New session in a worktree…", .action = .{ .command = .@"ai.new_session_worktree" } },
        .{ .label = "Codex session", .action = .{ .command = .@"ai.codex_new" } },
    } },
    .{ .label = "Dock", .action = .none, .icon = icon_dock_nerd, .icon_ascii = icon_dock_ascii, .submenu = &.{
        .{ .label = "Note", .action = .{ .command = .@"dock.new_text" } },
        .{ .label = "Log tail", .action = .{ .command = .@"dock.new_log_tail" } },
    } },
};

/// The Integrations group: one row per enabled, runnable integration
/// chip, each with the integration's own glyph, as its chip paints
/// (Rust: "we have dedicated ones we already use elsewhere"); null
/// when there is none. Labels and glyphs are copied onto `arena`.
fn integrationRows(app: *App, arena: Allocator) Allocator.Error!?MenuItem {
    const integrations = @import("integrations.zig");
    const chips = try integrations.chips(app, arena);
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    for (chips) |chip| {
        if (!chip.enabled) continue;
        const action: command.MenuAction = switch (chip.action) {
            .dyn => |slot| .{ .dyn = slot },
            .named => |id| if (command.by_name.get(id)) |cmd| .{ .command = cmd } else if (app.dyn_commands.get(id)) |slot| .{ .dyn = slot } else continue,
            .none => continue,
        };
        try rows.append(arena, .{
            .label = try arena.dupe(u8, chip.tooltip),
            .action = action,
            .icon = if (chip.glyph.len > 0) try arena.dupe(u8, chip.glyph) else null,
            .icon_ascii = if (chip.fallback.len > 0) try arena.dupe(u8, chip.fallback) else null,
        });
    }
    if (rows.items.len == 0) return null;
    return .{ .label = "Integrations", .action = .none, .icon = icon_integrations_nerd, .icon_ascii = icon_integrations_ascii, .submenu = try rows.toOwnedSlice(arena) };
}

fn isPinned(app: *App, id: []const u8) bool {
    for (app.plus_pinned.items) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

fn isHidden(app: *App, id: []const u8) bool {
    for (app.plus_hidden.items) |h| if (std.mem.eql(u8, h, id)) return true;
    return false;
}

/// The id curation names for a row: a static command's; null for a
/// parent, a dynamic command, or a row with nothing behind it.
fn rowId(item: MenuItem) ?[]const u8 {
    return switch (item.action) {
        .command => |id| command.name(id),
        else => null,
    };
}

fn pinRank(app: *App, item: MenuItem) ?usize {
    const id = rowId(item) orelse return null;
    for (app.plus_pinned.items, 0..) |p, i| if (std.mem.eql(u8, p, id)) return i;
    return null;
}

fn rowHidden(app: *App, item: MenuItem) bool {
    const id = rowId(item) orelse return false;
    return isHidden(app, id);
}

/// Rust's `apply_plus_menu_curation`: hidden rows dropped, pinned rows
/// floated to the top in the order they were pinned — wherever they
/// live, so a pinned row escapes its group; a group emptied by hiding
/// and pinning is dropped, since a parent that opens nothing is a dead
/// click. The result is the menu's (gpa); a trimmed group's rows are
/// `arena`'s.
fn curate(app: *App, arena: Allocator, tree: []const MenuItem) Allocator.Error![]MenuItem {
    const Found = struct { rank: usize, item: MenuItem };
    var found: std.ArrayListUnmanaged(Found) = .empty;
    var keep: std.ArrayListUnmanaged(MenuItem) = .empty;
    for (tree) |item| {
        if (rowHidden(app, item)) continue;
        if (item.submenu.len > 0) {
            var kids: std.ArrayListUnmanaged(MenuItem) = .empty;
            for (item.submenu) |k| {
                if (rowHidden(app, k)) continue;
                if (pinRank(app, k)) |r| try found.append(arena, .{ .rank = r, .item = k }) else try kids.append(arena, k);
            }
            if (kids.items.len == 0) continue;
            var parent = item;
            parent.submenu = try kids.toOwnedSlice(arena);
            try keep.append(arena, parent);
            continue;
        }
        if (pinRank(app, item)) |r| try found.append(arena, .{ .rank = r, .item = item }) else try keep.append(arena, item);
    }
    std.mem.sort(Found, found.items, {}, struct {
        fn less(_: void, a: Found, b: Found) bool {
            return a.rank < b.rank;
        }
    }.less);
    const out = try app.gpa.alloc(MenuItem, found.items.len + keep.items.len);
    for (found.items, 0..) |f, i| out[i] = f.item;
    @memcpy(out[found.items.len..], keep.items);
    return out;
}

/// The right column's ` 󰐕 `: Rust's "Add panel" menu, the five kinds
/// the right panel hosts.
pub fn openAddPanelMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try app.gpa.dupe(MenuItem, &.{
        .{ .label = "Outline", .action = .{ .command = .@"outline.show" } },
        .{ .label = "Problems", .action = .{ .command = .@"lsp.diagnostics" } },
        .{ .label = "AI chat", .action = .{ .command = .@"ai.chat" } },
        .{ .label = "Grep", .action = .{ .command = .@"find.grep" } },
        .{ .label = "Tests", .action = .{ .command = .@"test.run_all" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Add panel", rows, x, y);
}

/// The `+` (the strip's, the top-right cluster's): Rust's `Create…`
/// menu — "Reopen last closed (N)" first while there is something to
/// reopen, then the groups, the enabled integrations as the last
/// group, curated by `ui.plus_menu_pinned` / `plus_menu_hidden`. It
/// opens with its first row highlighted (Rust sets `interacted`), and
/// it is the one menu whose rows can be pinned and hidden.
pub fn openNewTabMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var tree: std.ArrayListUnmanaged(MenuItem) = .empty;
    if (app.closed.items.len > 0) try tree.append(arena, .{
        .label = try std.fmt.allocPrint(arena, "Reopen last closed ({d})", .{app.closed.items.len}),
        .action = .{ .command = .@"buffer.reopen" },
    });
    try tree.appendSlice(arena, &plus_tree);
    if (try integrationRows(app, arena)) |group| try tree.append(arena, group);
    const rows = try curate(app, arena, tree.items);
    errdefer app.gpa.free(rows);
    try app.openMenu("Create…", rows, x, y);
    app.overlay.menu.curatable = true;
    app.overlay.menu.highlight = true;
    app.overlay.menu.mem = mem;
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
        const is_file = if (p.asEditor()) |e| e.buf.doc.path != null else p.* == .md_preview;
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
                .git => app.git_palette.cursor,
                .http => app.http_panel.list.cursor,
                .diagnostics => app.lsp.panel.cursor,
                .debug => app.debug_panel.list.cursor,
                .integrations => app.integrations.panel.cursor,
                .search => app.search_section.list.cursor,
                .script => if (@import("script_section.zig").activeList(app)) |l| l.panel.cursor else return app.diag.fail(arena, "no script section", .{}),
                .notes, .findings, .sessions, .outline, .scripts => return app.diag.fail(arena, "{s}: no menu in this build", .{@tagName(which)}),
            };
            const r = rectOf(app, .{ .row = .{ .panel = which, .idx = @intCast(cursor) } });
            const m: Mouse = .{ .x = r.x, .y = r.y, .kind = .press, .button = .left };
            switch (which) {
                .todos => try @import("../todos.zig").kebabMouse(app, @intCast(cursor), m),
                .search => try @import("search_section.zig").kebabMouse(app, @intCast(cursor), m),
                .git => try @import("git_palette.zig").openRowMenu(app, cursor, r.x, r.y),
                .http => try @import("http_panel.zig").kebabMouse(app, @intCast(cursor), m),
                .diagnostics => try @import("lsp.zig").rowMouse(app, @intCast(cursor), .{ .x = r.x, .y = r.y, .kind = .press, .button = .right }),
                .debug => try @import("debug_panel.zig").kebabMouse(app, @intCast(cursor), m),
                .integrations => try @import("integrations.zig").kebabMouse(app, @intCast(cursor), m),
                .script => try @import("script_section.zig").kebabMouse(app, @intCast(cursor), m),
                .notes, .findings, .sessions, .outline, .scripts => {},
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
        break :blk app.relPath(e.buf.doc.path orelse return app.diag.fail(arena, "no file name", .{}));
    };
    try app.clipboard.set(rel, false);
    app.toast("copied {s}", .{rel});
}

// ─── right-click: the statusline chips ──────────────────────────────────
// Rust `right_click.rs` + `context_menus.rs`, one opener per chip. A
// chip whose rows carry their own string (a URL, a position) builds
// them on an arena the menu then owns.

/// Opens `rows` (gpa) whose labels and strings live on `mem`; the menu
/// owns both and frees them with the overlay.
pub fn openOwned(app: *App, title: []const u8, rows: []MenuItem, x: u16, y: u16, mem: std.heap.ArenaAllocator) Allocator.Error!void {
    try app.openMenu(title, rows, x, y);
    app.overlay.menu.mem = mem;
}

/// The workspace chip (Rust `open_statusline_workspace_context_menu`):
/// the repo verbs when the workspace holds more than one repo, the
/// worktree picker, the workspace verbs, a repo rescan.
pub fn openWorkspaceChipMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    const multi = app.git.repos.items.len > 1;
    if (multi) try rows.appendSlice(app.gpa, &.{
        .{ .label = "Switch repo…", .action = .{ .command = .@"git.switch_repo" } },
        .{ .label = "Next repo", .action = .{ .command = .@"git.next_repo" } },
        .{ .label = "Previous repo", .action = .{ .command = .@"git.prev_repo" } },
    });
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Worktrees…", .action = .{ .command = .@"git.worktrees" }, .separator_before = multi },
        .{ .label = "Switch workspace…", .action = .{ .command = .@"view.switch_workspace" }, .separator_before = true },
        .{ .label = "Add workspace…", .action = .{ .command = .@"view.add_workspace" } },
        .{ .label = "Manage workspaces…", .action = .{ .command = .@"view.manage_workspaces" } },
        .{ .label = "Rescan repos", .action = .{ .command = .@"git.refresh_repos" }, .separator_before = true },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(std.fs.path.basename(app.workspace), owned, x, y);
}

/// The PR chip (Rust `open_statusline_pr_context_menu`): open, the
/// two copies, a refresh.
pub fn openPrMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const statusline_app = @import("statusline.zig");
    const pr = statusline_app.currentPr(app) orelse return;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const url = try arena.dupe(u8, pr.url);
    const number = try std.fmt.allocPrint(arena, "{d}", .{pr.number});
    const rows = try items(app, &.{
        .{ .label = "Open in browser", .action = .{ .open_url = url } },
        .{ .label = "Copy URL", .action = .{ .copy_text = url }, .separator_before = true },
        .{ .label = try std.fmt.allocPrint(arena, "Copy number (#{s})", .{number}), .action = .{ .copy_text = number } },
        .{ .label = "Refresh", .action = .{ .command = .@"pr.refresh" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, try std.fmt.allocPrint(arena, "PR #{s}", .{number}), rows, x, y, mem);
}

/// The language chip (Rust `open_statusline_language_context_menu`):
/// the name to the clipboard, then the LSP's file-level verbs.
pub fn openLanguageMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const lang: []const u8 = if (app.activeEditor()) |e| (e.buf.doc.language orelse "—") else "—";
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const copy = try arena.dupe(u8, lang);
    const rows = try items(app, &.{
        .{ .label = try std.fmt.allocPrint(arena, "Copy language name ({s})", .{copy}), .action = .{ .copy_text = copy } },
        .{ .label = "Symbols in file", .action = .{ .command = .@"lsp.symbols" }, .separator_before = true },
        .{ .label = "Format file", .action = .{ .command = .@"lsp.format" } },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Language", rows, x, y, mem);
}

/// The Ln/Col chip (Rust `open_statusline_lncol_context_menu`): go to
/// line, the position to the clipboard.
pub fn openPositionMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const pos: []const u8 = if (app.activeEditor()) |e| blk: {
        const rc = e.buf.editor.rowCol();
        break :blk try std.fmt.allocPrint(arena, "{d}:{d}", .{ rc.row + 1, rc.col + 1 });
    } else "";
    const rows = try items(app, &.{
        .{ .label = "Go to line…", .action = .{ .command = .@"editor.goto_line" } },
        .{ .label = try std.fmt.allocPrint(arena, "Copy position ({s})", .{pos}), .action = .{ .copy_text = pos } },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Cursor", rows, x, y, mem);
}

/// The find chip (Rust `open_statusline_find_context_menu`).
pub fn openFindMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Next match", .action = .{ .command = .@"find.next" } },
        .{ .label = "Previous match", .action = .{ .command = .@"find.prev" } },
        .{ .label = "Clear highlight", .action = .{ .command = .@"find.clear" }, .separator_before = true },
        .{ .label = "Find…", .action = .{ .command = .@"find.find" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Find", rows, x, y);
}

/// The Sel chip (Rust `open_statusline_sel_context_menu`).
pub fn openSelMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Copy selection", .action = .{ .command = .@"editor.copy" } },
        .{ .label = "Cut selection", .action = .{ .command = .@"editor.cut" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Selection", rows, x, y);
}

/// The size chip (Rust `open_statusline_filesize_context_menu`): the
/// byte count to the clipboard. Rust's "Open externally" row has no
/// runner here.
pub fn openSizeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const e = app.activeEditor() orelse return;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const n = e.buf.editor.bytes().len;
    const size = try std.fmt.allocPrint(arena, "{d}", .{n});
    const rows = try items(app, &.{
        .{ .label = try std.fmt.allocPrint(arena, "Copy size ({s} bytes, {d} lines)", .{ size, e.buf.editor.lineCount() }), .action = .{ .copy_text = size } },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Size", rows, x, y, mem);
}

/// The WRAP chip (Rust `open_statusline_wrap_context_menu`): the title
/// says the state, the row flips it, Settings holds the rest.
pub fn openWrapMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const on = if (app.activeEditor()) |e| (e.wrap orelse app.cfg.ui.wrap) else app.cfg.ui.wrap;
    const rows = try items(app, &.{
        .{ .label = if (on) "Disable wrap" else "Enable wrap", .action = .{ .command = .@"view.toggle_wrap" } },
        .{ .label = "Editor settings…", .action = .{ .command = .@"view.settings" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(if (on) "Wrap · on" else "Wrap · off", rows, x, y);
}

/// A manifest's own statusline chip (Zig-only — the Rust host's
/// dynamic segments took a left click and nothing else). The rows are
/// what you can do to a chip that is showing a number: ask for a fresh
/// one, run whatever the chip's click runs, or go to the integration
/// that owns it.
pub fn openIntegrationSegmentMenu(app: *App, slot: u32, x: u16, y: u16) Allocator.Error!void {
    const segs = app.ipc_fx.segments.items;
    if (slot >= segs.len) return;
    const seg = segs[slot];
    const polled = app.integration_poll.jobForSegment(seg.id) != null;
    const a = app.frame.allocator();
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    if (polled) try rows.append(a, .{ .label = "Refresh now", .action = .{ .command = .@"integrations.poll_now" } });
    if (seg.click_command != null) try rows.append(a, .{ .label = "Open", .action = .{ .dyn = slot }, .separator_before = polled });
    // What this chip's number cost: the REQUESTS view, filtered to the
    // service behind it. A chip that is stale or slow is the place the
    // question gets asked, so it is the place the answer is offered.
    try rows.append(a, .{ .label = "Requests…", .action = .{ .requests_for = serviceOfSegment(seg.id) }, .separator_before = rows.items.len > 0 });
    try rows.append(a, .{ .label = "Integrations…", .action = .{ .command = .@"integrations.show_installed" }, .separator_before = true });
    const built = try items(app, rows.items);
    errdefer app.gpa.free(built);
    try app.openMenu(seg.id, built, x, y);
}

/// The service behind a segment id (`jira_work.assigned` → `jira`,
/// `bitbucket_prs.reviews_mine` → `bitbucket`). The prefix before the
/// first `_` or `.` is the integration's family, which is what the
/// request log files are named for. An id that names neither filters
/// to nothing in particular, which is the whole view.
pub fn serviceOfSegment(id: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, id, "_.") orelse id.len;
    return id[0..cut];
}

/// The test chip (Rust `statusline_test_chip`).
pub fn openTestMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Run all", .action = .{ .command = .@"test.run_all" } },
        .{ .label = "Run file", .action = .{ .command = .@"test.run_file" } },
        .{ .label = "Run at cursor", .action = .{ .command = .@"test.run_at_cursor" } },
        .{ .label = "Re-run failed", .action = .{ .command = .@"test.rerun_failed" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Tests", rows, x, y);
}

/// The AI usage chips (Rust `open_statusline_ai_context_menu`): the
/// usage pane, a refresh, the last response; what the chip shows; the
/// reset countdown; how every AI chip paints.
pub fn openAiChipMenu(app: *App, codex: bool, x: u16, y: u16) Allocator.Error!void {
    const detail = app.ai.chip_detail;
    const meter = app.cfg.ai.claude_meter_mode;
    const rows = try items(app, &.{
        .{ .label = "Open usage pane", .action = .{ .command = if (codex) .@"ai.codex_usage" else .@"ai.claude_usage" } },
        .{ .label = "Refresh usage now", .action = .{ .command = .@"ai.refresh_usage" } },
        .{ .label = "Show last response", .action = .{ .command = .@"ai.show_last_response" } },
        .{ .label = "Session only", .action = .{ .command = .@"ai.chip_show_session" }, .checked = detail == .session, .separator_before = true },
        .{ .label = "Weekly only", .action = .{ .command = .@"ai.chip_show_weekly" }, .checked = detail == .weekly },
        .{ .label = "Both", .action = .{ .command = .@"ai.chip_show_both" }, .checked = detail == .both },
        .{ .label = "Reset countdown", .action = .{ .command = .@"ai.chip_toggle_reset" }, .checked = app.ai.chip_reset_suffix, .separator_before = true },
        .{ .label = "All AI chips: off", .action = .{ .command = .@"ai.chip_show_all_off" }, .checked = meter == .off, .separator_before = true },
        .{ .label = "All AI chips: compact", .action = .{ .command = .@"ai.chip_show_all_compact" }, .checked = meter == .compact },
        .{ .label = "All AI chips: ticker", .action = .{ .command = .@"ai.chip_show_all_ticker" }, .checked = meter == .ticker },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(if (codex) "Codex" else "Claude", rows, x, y);
}

/// The enclosing-symbol chip (Zig-only): the outline and the two
/// symbol pickers.
pub fn openSymbolMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Outline", .action = .{ .command = .@"outline.show" } },
        .{ .label = "Symbols in file…", .action = .{ .command = .@"lsp.symbols" }, .separator_before = true },
        .{ .label = "Symbols in workspace…", .action = .{ .command = .@"lsp.workspace_symbols" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Symbol", rows, x, y);
}

/// The transfer chip (Zig-only): the one verb, named before it runs.
pub fn openTransferMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Cancel all transfers", .action = .{ .command = .@"transfer.cancel_all" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Transfers", rows, x, y);
}

// ─── right-click: the workspace headers ─────────────────────────────────

/// A `> WORKSPACE` header, or the empty rows under a section (Rust
/// `open_workspace_header_context_menu` for root 0,
/// `open_extra_workspace_header_context_menu` for the rest): fold, the
/// whole-tree folds, the workspace verbs, a rescan, the dots.
pub fn openWorkspaceHeaderMenu(app: *App, root: u8, x: u16, y: u16) Allocator.Error!void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const path: []const u8 = if (root == 0) app.workspace else if (root - 1 < app.tree.roots.items.len) app.tree.roots.items[root - 1].path else app.workspace;
    const title = try arena.dupe(u8, std.fs.path.basename(path));
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    if (root == 0) {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Collapse / expand section", .action = .{ .command = .@"view.toggle_tree_section" } },
            .{ .label = "Expand all", .action = .{ .command = .@"tree.expand_all" }, .separator_before = true },
            .{ .label = "Collapse all", .action = .{ .command = .@"tree.collapse_all" } },
            .{ .label = "New file…", .action = .{ .command = .@"file.new" }, .separator_before = true },
            .{ .label = "New folder…", .action = .{ .command = .@"file.new_folder" } },
            .{ .label = "Paste here", .action = .{ .command = .@"file.paste" } },
        });
    } else {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Switch to this workspace", .action = .{ .command = .@"view.switch_workspace" } },
            .{ .label = "Open in file browser", .action = .{ .open_path = try arena.dupe(u8, path) } },
            .{ .label = "Remove workspace…", .action = .{ .command = .@"view.remove_workspace" }, .separator_before = true },
        });
    }
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Switch workspace…", .action = .{ .command = .@"view.switch_workspace" }, .separator_before = true },
        .{ .label = "Add workspace…", .action = .{ .command = .@"view.add_workspace" } },
        .{ .label = "Manage workspaces…", .action = .{ .command = .@"view.manage_workspaces" } },
        .{ .label = "Copy path", .action = .{ .copy_text = try arena.dupe(u8, path) }, .separator_before = true },
        .{ .label = "Refresh tree", .action = .{ .command = .@"tree.refresh" } },
        .{ .label = "Show workspace dots", .action = .{ .command = .@"view.toggle_workspace_dots" }, .checked = app.cfg.ui.show_workspace_dots, .separator_before = true },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try openOwned(app, title, owned, x, y, mem);
}

// ─── right-click: the panes ─────────────────────────────────────────────

/// A pty pane's body (Rust `open_pty_dock_context_menu`): the session
/// verbs, where the pane docks, how big it gets, its name, close. The
/// pane is made active first.
pub fn openPtyPaneMenu(app: *App, pane: PaneId, x: u16, y: u16) Allocator.Error!void {
    const p = app.panes.get(pane) orelse return;
    app.showPane(pane);
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const current: ?[]const u8 = if (app.panes.pty(pane)) |pt| pt.accent_color else null;
    const rows = try items(app, &.{
        .{ .label = "Paste", .action = .{ .command = .@"term.paste" } },
        .{ .label = "Clear (Ctrl+L)", .action = .{ .command = .@"term.clear" } },
        .{ .label = "Restart", .action = .{ .command = .@"term.restart" } },
        .{ .label = "Dock left", .action = .{ .command = .@"view.move_split_left" }, .separator_before = true },
        .{ .label = "Dock right", .action = .{ .command = .@"view.move_split_right" } },
        .{ .label = "Dock top", .action = .{ .command = .@"view.move_split_up" } },
        .{ .label = "Dock bottom", .action = .{ .command = .@"view.move_split_down" } },
        .{ .label = "Maximize width", .action = .{ .command = .@"view.maximize_width" }, .separator_before = true },
        .{ .label = "Maximize height", .action = .{ .command = .@"view.maximize_height" } },
        .{ .label = "Full screen", .action = .{ .command = .@"view.fullscreen" } },
        .{ .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" } },
        .{ .label = "Rename…", .action = .{ .command = .@"term.rename" }, .separator_before = true },
        // colors: the accent, on the pane body as on the tab.
        .{ .label = "Color", .action = .none, .submenu = try sessions.colorMenuRows(mem.allocator(), .{ .target = .{ .pane = pane }, .name = "" }, current) },
        .{ .label = "Close pane", .action = .{ .command = .@"buffer.close" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(p.title(), rows, x, y);
    app.overlay.menu.mem = mem;
}

/// An AI pane's body (Rust `open_ai_pane_context_menu`): re-ask,
/// cancel, promote, apply. Rust's transcript row has no runner here.
pub fn openAiPaneMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Re-ask (fresh session)", .action = .{ .command = .@"ai.reask" } },
        .{ .label = "Cancel running job", .action = .{ .command = .@"ai.cancel" } },
        .{ .label = "Promote to interactive (claude --resume)", .action = .{ .command = .@"ai.promote" }, .separator_before = true },
        .{ .label = "Apply suggested change", .action = .{ .command = .@"ai.apply" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("AI", rows, x, y);
}

/// A breadcrumb segment (Zig-only): the directory it names, to a Files
/// pane or the clipboard.
pub fn openBreadcrumbMenu(app: *App, dir: []const u8, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const copy = try arena.dupe(u8, dir);
    const rows = try items(app, &.{
        .{ .label = "Open in file browser", .action = .{ .open_path = copy } },
        .{ .label = "Copy path", .action = .{ .copy_text = copy } },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, std.fs.path.basename(copy), rows, x, y, mem);
}

/// A welcome-screen recent row (Zig-only): open, copy, the picker.
pub fn openWelcomeRecentMenu(app: *App, path: []const u8, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const copy = try arena.dupe(u8, path);
    const rows = try items(app, &.{
        .{ .label = "Open", .action = .{ .open_path = copy } },
        .{ .label = "Copy path", .action = .{ .copy_text = try arena.dupe(u8, app.relPath(copy)) } },
        .{ .label = "Recent files…", .action = .{ .command = .@"picker.recent" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, std.fs.path.basename(copy), rows, x, y, mem);
}

/// A link (a preview's, a detail pane's — Rust `integration_detail_links`
/// copies the URL): open it, copy it.
pub fn openLinkMenu(app: *App, url: []const u8, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const copy = try arena.dupe(u8, url);
    const rows = try items(app, &.{
        .{ .label = "Open in browser", .action = .{ .open_url = copy } },
        .{ .label = "Copy URL", .action = .{ .copy_text = copy } },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Link", rows, x, y, mem);
}

// ─── right-click: the chrome chips ──────────────────────────────────────
// The palette bar, the bufferline's right cluster, the split strip and
// the right column's strip (Rust `right_click.rs`): one menu per chip,
// keyed by `render.Button`. `openButtonMenu` answers false for a chip
// with no menu so the press falls through to its left action.

pub fn openButtonMenu(app: *App, id: u32, x: u16, y: u16) Allocator.Error!bool {
    const render = @import("render.zig");
    const menu_bar = @import("menu_bar.zig");
    const integrations_view = @import("../ui/integrations_view.zig");
    if (render.Button.tabPageOf(id)) |page| return openTabPageMenu(app, page, x, y);
    if (render.Button.tabPageCloseOf(id)) |page| return openTabPageMenu(app, page, x, y);
    if (id >= integrations_view.tab_base and id < integrations_view.tab_base + integrations_view.Tab.all.len) {
        try openIntegrationsTabsMenu(app, x, y);
        return true;
    }
    if (menu_bar.buttonOf(id)) |which| {
        try openMenuBarMenu(app, which, x, y);
        return true;
    }
    switch (@as(render.Button, @enumFromInt(id))) {
        // The search chip mirrors the chevron: recents, as Rust.
        .palette => {
            command.run(app, .{ .static = .@"picker.recent" }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            return true;
        },
        .menu_bar_pin => try openMenuBarPinMenu(app, x, y),
        // // changed (edge-grip): a grip answers everything the chip at
        // the other end of its surface does, so a right press on one
        // opens that surface's own menu rather than doing nothing.
        .edge_grip_menu_bar => try openMenuBarPinMenu(app, x, y),
        .edge_grip_sidebar_left, .edge_grip_sidebar_right => try openSidebarModeMenu(app, x, y),
        .edge_grip_dock => try @import("launcher_dock.zig").openDockMenu(app, x, y),
        .toggle_tree => try openSidebarMenu(app, x, y),
        .toggle_right_panel => try openRightPanelMenu(app, x, y),
        .right_tab, .right_close => try openRightColumnMenu(app, x, y),
        .right_new => try openAddPanelMenu(app, x, y),
        .back => try openNavMenu(app, false, x, y),
        .forward => try openNavMenu(app, true, x, y),
        .dropdown => try openOpenMenu(app, x, y),
        .tabs_label => try openClusterMenu(app, x, y),
        .theme_toggle => try openThemeMenu(app, x, y),
        .window_close => try openWindowMenu(app, x, y),
        .split_term => try openTerminalChipMenu(app, x, y),
        .split_right => try openSplitChipMenu(app, .horizontal, x, y),
        .split_down => try openSplitChipMenu(app, .vertical, x, y),
        .split_max => try openMaximizeMenu(app, x, y),
        .ai_claude => try openAiLauncherMenu(app, false, x, y),
        .ai_codex => try openAiLauncherMenu(app, true, x, y),
        else => return false,
    }
    return true;
}

/// The sidebar toggle (Rust `palette_sidebar_button`).
fn openSidebarMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const visible = side.shown(app, .left) != null;
    const rows = try items(app, &.{
        .{ .label = if (visible) "Hide sidebar" else "Show sidebar", .action = .{ .command = .@"view.toggle_tree" } },
        .{ .label = "Reset sidebar width", .action = .{ .command = .@"view.reset_tree_width" } },
        .{ .label = "Focus sidebar", .action = .{ .command = .@"view.focus_tree" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Sidebar", rows, x, y);
}

/// The right-column toggle (Rust `palette_right_panel_button`).
fn openRightPanelMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const visible = side.shown(app, .right) != null;
    const rows = try items(app, &.{
        .{ .label = if (visible) "Hide right column" else "Show right column", .action = .{ .command = .@"view.toggle_right_panel" } },
        .{ .label = "Focus right column", .action = .{ .command = .@"view.focus_right_panel" } },
        .{ .label = "Add Outline", .action = .{ .command = .@"outline.show" }, .separator_before = true },
        .{ .label = "Add Problems", .action = .{ .command = .@"lsp.diagnostics" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Right panel", rows, x, y);
}

/// The right column's strip — its chip and its `×` (Rust
/// `open_right_panel_tab_context_menu`): focus, the neighbours, close,
/// hide the column.
fn openRightColumnMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Focus", .action = .{ .command = .@"view.focus_right_panel" } },
        .{ .label = "Next section", .action = .{ .command = .@"view.right_panel_next_tab" }, .separator_before = true },
        .{ .label = "Previous section", .action = .{ .command = .@"view.right_panel_prev_tab" } },
        .{ .label = "Close section", .action = .{ .command = .@"view.right_panel_close_tab" }, .separator_before = true },
        .{ .label = "Hide right column", .action = .{ .command = .@"view.toggle_right_panel" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(if (side.shown(app, .right)) |s| side.label(s) else "Right panel", rows, x, y);
}

/// The palette bar's ` ← ` / ` → ` (Rust `open_palette_nav_context_menu`):
/// the two steps, the picker, the history's clear.
fn openNavMenu(app: *App, forward: bool, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Previous buffer", .action = .{ .command = .@"buffer.prev" } },
        .{ .label = "Next buffer", .action = .{ .command = .@"buffer.next" } },
        .{ .label = "Buffers…", .action = .{ .command = .@"picker.buffers" }, .separator_before = true },
        .{ .label = "Clear history", .action = .{ .command = .@"buffer.clear_mru" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(if (forward) "Forward" else "Back", rows, x, y);
}

/// The palette bar's ` ▾ ` (Rust `palette_dropdown_button`).
fn openOpenMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Recent files", .action = .{ .command = .@"picker.recent" } },
        .{ .label = "Recent commands", .action = .{ .command = .@"picker.recent_commands" } },
        .{ .label = "All files", .action = .{ .command = .@"picker.files" } },
        .{ .label = "Command palette", .action = .{ .command = .palette }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Open…", rows, x, y);
}

/// The ` TABS ` label (Rust `open_top_bar_cluster_context_menu`): the
/// cluster mode, ticked; then the page picker.
fn openClusterMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const cur = app.cfg.ui.top_bar_cluster_mode;
    const rows = try items(app, &.{
        .{ .label = "Expanded", .action = .{ .command = .@"view.cluster_mode_expanded" }, .checked = cur == .expanded },
        .{ .label = "Compact", .action = .{ .command = .@"view.cluster_mode_compact" }, .checked = cur == .compact },
        .{ .label = "Auto", .action = .{ .command = .@"view.cluster_mode_auto" }, .checked = cur == .auto },
        .{ .label = "Tab pages…", .action = .{ .command = .@"tab.picker" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Tab cluster", rows, x, y);
}

/// The theme pill (Rust `bufferline_theme_toggle`): the toggle, the
/// system follow, the reset, the picker, then every theme with the
/// painted one ticked.
pub fn openThemeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const Theme = @import("../ui/theme.zig");
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    const cur = app.theme.name;
    const toggle_label: []const u8 = if (app.cfg.ui.theme_toggle) |alt|
        (if (!std.ascii.eqlIgnoreCase(alt, cur)) try std.fmt.allocPrint(arena, "Toggle → {s}", .{alt}) else "Toggle (primary ⇄ alt)")
    else
        "Toggle (set ui.theme_toggle first)";
    try rows.appendSlice(app.gpa, &.{
        .{ .label = toggle_label, .action = .{ .command = .@"theme.toggle" } },
        .{ .label = "Auto: match system (light / dark)", .action = .{ .command = if (app.cfg.ui.theme_auto_system) .@"theme.auto_system_off" else .@"theme.auto_system" }, .checked = app.cfg.ui.theme_auto_system },
        .{ .label = "Reset to config default", .action = .{ .command = .@"theme.reset" } },
        .{ .label = "Pick theme…  (fuzzy)", .action = .{ .command = .@"theme.pick" } },
    });
    for (&Theme.all, 0..) |*th, i| try rows.append(app.gpa, .{
        .label = th.name,
        .action = .{ .set_theme = th.name },
        .checked = std.ascii.eqlIgnoreCase(th.name, cur),
        .separator_before = i == 0,
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try openOwned(app, "Theme", owned, x, y, mem);
}

/// The window `×` (Rust `bufferline_window_close`).
fn openWindowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Quit (with confirm)", .action = .{ .command = .@"app.quit" } },
        .{ .label = "Save all", .action = .{ .command = .@"file.save_all" }, .separator_before = true },
        .{ .label = "Restart", .action = .{ .command = .@"app.restart" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("mnml", rows, x, y);
}

/// The terminal chip's `Mark ▸` submenu: the mark's two choices with the
/// current one ticked, and the bake below them. On the strip's terminal
/// chip and on a pty tab — the two places the mark itself is on screen,
/// so the menu is where the eye already is. Rows live on `arena`, which
/// the open menu owns.
fn terminalIconRows(app: *App, arena: Allocator) Allocator.Error![]const MenuItem {
    const cur = app.cfg.ui.terminal_glyph;
    const rows = try arena.alloc(MenuItem, 3);
    // The default first, as it reads: the ghost, then the plain one.
    rows[0] = .{ .label = terminal_glyph.label(.ghostty), .action = .{ .set_terminal_mark = .ghostty }, .checked = cur == .ghostty };
    rows[1] = .{ .label = terminal_glyph.label(.terminal), .action = .{ .set_terminal_mark = .terminal }, .checked = cur == .terminal };
    // Not a third mark — the bake that puts your own art behind the
    // ghost's codepoint, so it keeps its own row and its prompt.
    rows[2] = .{ .label = "Custom SVG…", .action = .{ .command = .@"view.terminal_glyph_custom" }, .checked = cur == .custom, .separator_before = true };
    return rows;
}

/// The Claude chip's `Mark ▸` submenu: the two values of
/// `ui.claude_mark`, the current one ticked. Its twin above.
fn claudeMarkRows(app: *App, arena: Allocator) Allocator.Error![]const MenuItem {
    const cur = app.cfg.ui.claude_mark;
    const rows = try arena.alloc(MenuItem, 2);
    rows[0] = .{ .label = claude_mark.label(.figure), .action = .{ .set_claude_mark = .figure }, .checked = cur == .figure };
    rows[1] = .{ .label = claude_mark.label(.spark), .action = .{ .set_claude_mark = .spark }, .checked = cur == .spark };
    return rows;
}

/// The strip's terminal chip (Rust `split_strip_term_buttons`): where
/// the shell goes, and which mark this chip and every pty tab wear.
fn openTerminalChipMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const rows = try items(app, &.{
        .{ .label = "Open shell (beside)", .action = .{ .command = .@"term.shell" } },
        .{ .label = "Open shell in left half", .action = .{ .command = .@"term.shell_left" }, .separator_before = true },
        .{ .label = "Open shell in right half", .action = .{ .command = .@"term.shell_right" } },
        .{ .label = "Open shell in top half", .action = .{ .command = .@"term.shell_top" } },
        .{ .label = "Open shell in bottom half", .action = .{ .command = .@"term.shell_bottom" } },
        .{ .label = "Scratch terminal", .action = .{ .command = .@"term.scratch_toggle" }, .separator_before = true },
        .{ .label = "Mark", .action = .none, .separator_before = true, .submenu = try terminalIconRows(app, mem.allocator()) },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, "Terminal", rows, x, y, mem);
}

/// The strip's split chips (Rust `split_strip_buttons`): the split, the
/// equalize, the grow / shrink pair, close.
fn openSplitChipMenu(app: *App, dir: enum { horizontal, vertical }, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, switch (dir) {
        .horizontal => &.{
            .{ .label = "Split right", .action = .{ .command = .@"view.split_right" } },
            .{ .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" }, .separator_before = true },
            .{ .label = "Grow width", .action = .{ .command = .@"view.split_grow_width" } },
            .{ .label = "Shrink width", .action = .{ .command = .@"view.split_shrink_width" } },
            .{ .label = "Close active pane", .action = .{ .command = .@"buffer.close" }, .separator_before = true },
        },
        .vertical => &.{
            .{ .label = "Split down", .action = .{ .command = .@"view.split_down" } },
            .{ .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" }, .separator_before = true },
            .{ .label = "Grow height", .action = .{ .command = .@"view.split_grow_height" } },
            .{ .label = "Shrink height", .action = .{ .command = .@"view.split_shrink_height" } },
            .{ .label = "Close active pane", .action = .{ .command = .@"buffer.close" }, .separator_before = true },
        },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu(if (dir == .horizontal) "Split horizontal" else "Split vertical", rows, x, y);
}

/// The strip's maximize chip (Rust `split_strip_maximize_buttons`).
/// The two modes the button can be, ticked on the one a left click
/// runs — `ui.maximize_click`, which Settings → UI is the way to change
/// (picking a row here runs it once, it does not re-point the button).
fn openMaximizeMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const mode = app.cfg.ui.maximize_click;
    const rows = try items(app, &.{
        .{ .label = "Zoom this pane / restore", .action = .{ .command = .@"view.toggle_zoom" }, .checked = mode == .zoom_pane },
        .{ .label = "Full screen / restore", .action = .{ .command = .@"view.fullscreen" }, .checked = mode == .fullscreen },
        .{ .label = "Equalize splits", .action = .{ .command = .@"view.equalize_splits" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Maximize", rows, x, y);
}

/// The strip's AI chips (Rust `split_strip_ai_buttons`): toggle the
/// existing pane, a new session in each half, the layout mode, the
/// glyph pair.
fn openAiLauncherMenu(app: *App, codex: bool, x: u16, y: u16) Allocator.Error!void {
    const grid = app.cfg.ui.ai_layout_mode == .grid;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const rows = try items(app, if (codex) &.{
        .{ .label = "Toggle existing Codex pane", .action = .{ .command = .@"ai.codex" } },
        .{ .label = "New Codex session in left half", .action = .{ .command = .@"ai.codex_new_left" }, .separator_before = true },
        .{ .label = "New Codex session in right half", .action = .{ .command = .@"ai.codex_new_right" } },
        .{ .label = "New Codex session in top half", .action = .{ .command = .@"ai.codex_new_top" } },
        .{ .label = "New Codex session in bottom half", .action = .{ .command = .@"ai.codex_new_bottom" } },
        .{ .label = "Layout: Grid (splits)", .action = .{ .command = .@"view.ai_layout_grid" }, .checked = grid, .separator_before = true },
        .{ .label = "Layout: Tabs (stack in leaf)", .action = .{ .command = .@"view.ai_layout_tabs" }, .checked = !grid },
        .{ .label = "Bake AI glyphs into MnmlSymbols", .action = .{ .command = .@"integrations.bake_ai_glyphs" }, .separator_before = true },
        .{ .label = "Edit Codex glyph…", .action = .{ .command = .@"integrations.edit_codex_glyph" } },
    } else &.{
        .{ .label = "Toggle existing Claude Code pane", .action = .{ .command = .@"ai.claude_code" } },
        .{ .label = "New Claude Code session in left half", .action = .{ .command = .@"ai.claude_code_new_left" }, .separator_before = true },
        .{ .label = "New Claude Code session in right half", .action = .{ .command = .@"ai.claude_code_new_right" } },
        .{ .label = "New Claude Code session in top half", .action = .{ .command = .@"ai.claude_code_new_top" } },
        .{ .label = "New Claude Code session in bottom half", .action = .{ .command = .@"ai.claude_code_new_bottom" } },
        .{ .label = "Layout: Grid (splits)", .action = .{ .command = .@"view.ai_layout_grid" }, .checked = grid, .separator_before = true },
        .{ .label = "Layout: Tabs (stack in leaf)", .action = .{ .command = .@"view.ai_layout_tabs" }, .checked = !grid },
        .{ .label = "Bake AI glyphs into MnmlSymbols", .action = .{ .command = .@"integrations.bake_ai_glyphs" }, .separator_before = true },
        .{ .label = "Edit Claude Code glyph…", .action = .{ .command = .@"integrations.edit_claude_glyph" } },
        // Which of the two branded marks Claude wears, everywhere the
        // chrome draws one (`app/claude_mark.zig`).
        .{ .label = "Mark", .action = .none, .separator_before = true, .submenu = try claudeMarkRows(app, mem.allocator()) },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, if (codex) "Codex launcher" else "Claude Code launcher", rows, x, y, mem);
}

/// A tab-page chip or its `×` (Zig-only — Rust's cluster had no menu):
/// the page is shown first, as a tab is made active, so the rows act
/// on it.
fn openTabPageMenu(app: *App, page: usize, x: u16, y: u16) Allocator.Error!bool {
    const cmd_tab = @import("cmd_tab.zig");
    if (page >= app.layouts.layouts.items.len) return false;
    cmd_tab.switchTab(app, page);
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const rows = try items(app, &.{
        .{ .label = "Close page", .action = .{ .command = .@"tab.close" } },
        .{ .label = "Close other pages", .action = .{ .command = .@"tab.only" } },
        .{ .label = "New tab page", .action = .{ .command = .@"tab.new" }, .separator_before = true },
        .{ .label = "Move left", .action = .{ .command = .@"tab.move_left" }, .separator_before = true },
        .{ .label = "Move right", .action = .{ .command = .@"tab.move_right" } },
        .{ .label = "Tab pages…", .action = .{ .command = .@"tab.picker" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try openOwned(app, try std.fmt.allocPrint(arena, "Tab page {d}", .{page + 1}), rows, x, y, mem);
    return true;
}

/// The INTEGRATIONS section's tab strip (Zig-only): the tabs, ticked,
/// and a refresh.
fn openIntegrationsTabsMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const cur = app.integrations.tab;
    const rows = try items(app, &.{
        .{ .label = "Installed", .action = .{ .command = .@"integrations.show_installed" }, .checked = cur == .installed },
        .{ .label = "Marketplace", .action = .{ .command = .@"integrations.show_marketplace" }, .checked = cur == .marketplace },
        .{ .label = "Dev", .action = .{ .command = .@"integrations.show_in_dev" }, .checked = cur == .dev },
        .{ .label = "Refresh", .action = .{ .command = .@"integrations.refresh" }, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Integrations", rows, x, y);
}

/// A menu-bar word (Rust `menu_bar_words`): open it, then the bar's
/// own pin and mode.
fn openMenuBarMenu(app: *App, which: @import("menu_bar.zig").Menu, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{
        .{ .label = "Open", .action = .{ .menu_bar = @intFromEnum(which) } },
        menuBarPinRow(app),
        menuBarCycleRow(app),
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Menu bar", rows, x, y);
}

/// // changed (menu-bar-pin): the pin chip's own right press — the
/// pin and the mode, with no word to open. The dock's pin chip answers
/// the right button the same way.
pub fn openMenuBarPinMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try items(app, &.{ menuBarPinRow(app), menuBarCycleRow(app) });
    errdefer app.gpa.free(rows);
    try app.openMenu("Menu bar", rows, x, y);
}

/// Pin / unpin the bar for the session. The row is there whatever the
/// mode: under `.always` the command answers with why there is nothing
/// to pin, which beats a row that quietly is not there.
fn menuBarPinRow(app: *const App) MenuItem {
    return .{
        .label = if (app.menu_bar.pinned) "Unpin menu bar" else "Pin menu bar",
        .action = .{ .command = .@"view.menu_bar_pin" },
        .checked = app.menu_bar.pinned,
        .separator_before = true,
    };
}

fn menuBarCycleRow(app: *const App) MenuItem {
    return .{ .label = switch (app.cfg.ui.menu_bar) {
        .always => "Menu bar: always → auto",
        .auto => "Menu bar: auto → hidden",
        .hidden => "Menu bar: hidden → always",
    }, .action = .{ .command = .@"view.menu_bar_cycle" } };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn closeMenu(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
}

test "right-click: the workspace chip, the Ln/Col chip, the PR chip, the AI chips and the workspace headers open Rust's rows" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    // One repo: the repo rows stay out and the worktree picker leads.
    try openWorkspaceChipMenu(&app, 3, 3);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("tmp", app.overlay.menu.title);
    try t.expectEqualStrings("Worktrees…", app.overlay.menu.items[0].label);
    try t.expect(!app.overlay.menu.items[0].separator_before);
    closeMenu(&app);
    // The position chip carries the cursor's own text.
    _ = try app.openScratch();
    try openPositionMenu(&app, 3, 3);
    try t.expectEqualStrings("Cursor", app.overlay.menu.title);
    try t.expectEqualStrings("Copy position (1:1)", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("1:1", app.overlay.menu.items[1].action.copy_text);
    closeMenu(&app);
    // No PR: no menu, nothing to act on.
    try openPrMenu(&app, 3, 3);
    try t.expect(app.overlay == .none);
    // The Codex chip opens Codex's usage; the mode rows tick the state.
    try openAiChipMenu(&app, true, 3, 3);
    try t.expectEqualStrings("Codex", app.overlay.menu.title);
    try t.expectEqual(command.CommandId.@"ai.codex_usage", app.overlay.menu.items[0].action.command);
    try t.expect(app.overlay.menu.items[5].checked); // Both, the default
    closeMenu(&app);
    // The primary header leads with the fold; an extra root with switch-to.
    try openWorkspaceHeaderMenu(&app, 0, 3, 3);
    try t.expectEqualStrings("Collapse / expand section", app.overlay.menu.items[0].label);
    try t.expectEqual(app_mod.FocusId.tree, app.overlay.menu.return_focus);
    closeMenu(&app);
    try openWorkspaceHeaderMenu(&app, 1, 3, 3);
    try t.expectEqualStrings("Switch to this workspace", app.overlay.menu.items[0].label);
    closeMenu(&app);
}

test "right-click: the chrome chips — a chip with a menu answers true, one without false; the theme pill ticks the painted theme" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const render = @import("render.zig");
    try t.expect(!try openButtonMenu(&app, @intFromEnum(render.Button.hidden_tabs), 3, 3));
    try t.expect(app.overlay == .none);
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.toggle_tree), 3, 3));
    try t.expectEqualStrings("Sidebar", app.overlay.menu.title);
    closeMenu(&app);
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.theme_toggle), 3, 3));
    var ticked: usize = 0;
    for (app.overlay.menu.items) |it| if (it.action == .set_theme) {
        if (it.checked) {
            ticked += 1;
            try t.expectEqualStrings(app.theme.name, it.action.set_theme);
        }
    };
    try t.expectEqual(@as(usize, 1), ticked);
    closeMenu(&app);
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.split_term), 3, 3));
    try t.expectEqualStrings("Terminal", app.overlay.menu.title);
    try t.expectEqual(command.CommandId.@"term.shell_left", app.overlay.menu.items[1].action.command);
    closeMenu(&app);
    // A page chip: the page is shown, its rows act on it.
    try t.expect(try openButtonMenu(&app, render.Button.tabPage(0), 3, 3));
    try t.expectEqualStrings("Tab page 1", app.overlay.menu.title);
    closeMenu(&app);
    try t.expect(!try openButtonMenu(&app, render.Button.tabPage(7), 3, 3));
}

test "right-click: the maximize chip lists its two modes and ticks the one a left click runs" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const render = @import("render.zig");
    const zen = @import("zen.zig");
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.split_max), 3, 3));
    try t.expectEqualStrings("Maximize", app.overlay.menu.title);
    // Two modes and the equalize; there is no third zoom scope — a
    // leaf is the tab group (`app/zen.zig`).
    try t.expectEqual(@as(usize, 3), app.overlay.menu.items.len);
    try t.expectEqualStrings("Zoom this pane / restore", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Full screen / restore", app.overlay.menu.items[1].label);
    try t.expectEqual(zen.commandFor(.zoom_pane), app.overlay.menu.items[0].action.command);
    try t.expectEqual(zen.commandFor(.fullscreen), app.overlay.menu.items[1].action.command);
    // The tick follows `ui.maximize_click`, on exactly one row.
    try t.expect(app.overlay.menu.items[0].checked);
    try t.expect(!app.overlay.menu.items[1].checked);
    try t.expect(!app.overlay.menu.items[2].checked);
    closeMenu(&app);
    app.cfg.ui.maximize_click = .fullscreen;
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.split_max), 3, 3));
    try t.expect(!app.overlay.menu.items[0].checked);
    try t.expect(app.overlay.menu.items[1].checked);
    // Picking a row runs it; it does not re-point the button, which is
    // Settings -> UI's to change.
    app.overlay.menu.cursor = 0;
    app.overlay.menu.highlight = true;
    _ = try app.openScratch();
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.zoomed_leaf != null);
    try t.expectEqual(app_mod.Config.MaximizeClick.fullscreen, app.cfg.ui.maximize_click);
}

test "right-click: the terminal chip's `Mark` submenu — the ghost first and ticked, the codicon under it, the bake below, and every id registered" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const render = @import("render.zig");
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.split_term), 3, 3));
    const icon_row = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expectEqualStrings("Mark", icon_row.label);
    try t.expectEqual(@as(usize, 3), icon_row.submenu.len);
    // The default reads first.
    try t.expectEqualStrings("Ghostty ghost", icon_row.submenu[0].label);
    try t.expectEqualStrings("Terminal", icon_row.submenu[1].label);
    try t.expectEqualStrings("Custom SVG…", icon_row.submenu[2].label);
    // The two marks are set-rows, not commands: no command id exists
    // for either, and the row carries the value it writes.
    try t.expectEqual(Config.TerminalGlyph.ghostty, icon_row.submenu[0].action.set_terminal_mark);
    try t.expectEqual(Config.TerminalGlyph.terminal, icon_row.submenu[1].action.set_terminal_mark);
    // The shipped default is the ghost, and exactly one row is ticked.
    try t.expect(icon_row.submenu[0].checked);
    try t.expect(!icon_row.submenu[1].checked);
    try t.expect(!icon_row.submenu[2].checked);
    // The bake is still a command — a row that names one the registry
    // does not have compiles and renders, and only a click would find
    // it.
    try t.expect(command.by_name.get(command.name(icon_row.submenu[2].action.command)) != null);
    closeMenu(&app);
    // The tick follows the key.
    app.cfg.ui.terminal_glyph = .custom;
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.split_term), 3, 3));
    const after = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expect(!after.submenu[0].checked);
    try t.expect(after.submenu[2].checked);
    closeMenu(&app);
}

test "right-click: the Claude chip's `Mark` submenu — the figure and the spark, the current one ticked, and the rows write the key" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const render = @import("render.zig");
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.ai_claude), 3, 3));
    const row = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expectEqualStrings("Mark", row.label);
    try t.expectEqual(@as(usize, 2), row.submenu.len);
    try t.expectEqualStrings("Claude Code figure", row.submenu[0].label);
    try t.expectEqualStrings("Anthropic spark", row.submenu[1].label);
    try t.expectEqual(Config.ClaudeMark.figure, row.submenu[0].action.set_claude_mark);
    try t.expectEqual(Config.ClaudeMark.spark, row.submenu[1].action.set_claude_mark);
    // The shipped default is the figure; exactly one tick.
    try t.expect(row.submenu[0].checked);
    try t.expect(!row.submenu[1].checked);
    closeMenu(&app);
    // The tick follows the key.
    app.cfg.ui.claude_mark = .spark;
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.ai_claude), 3, 3));
    const after = app.overlay.menu.items[app.overlay.menu.items.len - 1];
    try t.expect(!after.submenu[0].checked);
    try t.expect(after.submenu[1].checked);
    closeMenu(&app);
    // The Codex chip has no `Mark` row: Codex has one mark.
    try t.expect(try openButtonMenu(&app, @intFromEnum(render.Button.ai_codex), 3, 3));
    for (app.overlay.menu.items) |it| try t.expect(!std.mem.eql(u8, it.label, "Mark"));
    closeMenu(&app);
}

test "right-click: a copy_text row lands on the clipboard after the menu's own arena is gone" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    try openPositionMenu(&app, 3, 3);
    const action = app.overlay.menu.items[1].action;
    try @import("dispatch.zig").runMenuActionForTest(&app, action);
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("1:1", app.clipboard.text());
}

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
    app.activeEditor().?.buf.doc.dirty = true;
    try openTabMenu(&app, b, 3, 1);
    try t.expectEqualStrings("Save", app.overlay.menu.items[0].label);
    app.overlay.deinit(app.gpa);
    app.panes.editor(d).?.buf.doc.dirty = true;
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

test "a context menu: the pointer over a row moves the highlight there, the keyboard carries on from it, a hover past the last row changes nothing" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try openEditorMenu(&app, 10, 5);
    const m = &app.overlay.menu;
    try t.expect(m.highlight);
    try app.render();
    // The frame: `┌ Editor ┐` at (10, 5); the rows start at y = 6.
    const before = try screenOf(&app);
    defer t.allocator.free(before);
    try t.expect(std.mem.indexOf(u8, before, "┌ Editor ") != null);
    var paste_y: ?u16 = null;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.idx == 2) {
        paste_y = h.rect.y;
    };
    try t.expectEqual(@as(?u16, 8), paste_y);
    try app.handle(.{ .mouse = .{ .x = 14, .y = 8, .kind = .motion } });
    try t.expectEqual(@as(usize, 2), m.cursor);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expectEqual(@as(usize, 3), m.cursor);
    // The frame's border and the world outside are not rows.
    try app.handle(.{ .mouse = .{ .x = 10, .y = 8, .kind = .motion } });
    try t.expectEqual(@as(usize, 3), m.cursor);
    try app.handle(.{ .mouse = .{ .x = 80, .y = 25, .kind = .motion } });
    try t.expectEqual(@as(usize, 3), m.cursor);
    try t.expect(app.overlay == .menu);
    // A click still runs the hovered row: Select all selects the buffer.
    try app.handle(.{ .mouse = .{ .x = 14, .y = 11, .kind = .motion } });
    try t.expectEqual(@as(usize, 5), m.cursor);
    try app.handle(.{ .mouse = .{ .x = 14, .y = 11, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
}

fn screenOf(app: *App) ![]u8 {
    try app.render();
    return @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
}

test "the + menu is Rust's Create… tree: New / Open / AI / Dock ▸ rows with Rust's icons, Reopen first when there is a closed tab; → opens a child hung from its row, ← steps back, Enter runs a child's row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    // Rust's bare tree: no integration chip enabled.
    app.cfg.ui.integration_icons = &.{};
    _ = try app.openScratch();
    try openNewTabMenu(&app, 31, 2);
    const m = &app.overlay.menu;
    try t.expect(m.curatable);
    try t.expect(m.highlight);
    try t.expect(!m.dropdown);
    try t.expectEqualStrings("Create…", m.title);
    // Rust's `plus_menu_items`: four groups (the test config enables no
    // integration chip with a runnable command), each with its icon.
    const want = [_]struct { label: []const u8, icon: []const u8, n: usize }{
        .{ .label = "New", .icon = icon_new_nerd, .n = 6 },
        .{ .label = "Open", .icon = icon_open_nerd, .n = 5 },
        // sessions-worktree: the AI child gained New session in a worktree….
        .{ .label = "AI", .icon = icon_ai_nerd, .n = 3 },
        .{ .label = "Dock", .icon = icon_dock_nerd, .n = 2 },
    };
    try t.expectEqual(want.len, m.items.len);
    for (want, m.items) |w, it| {
        try t.expectEqualStrings(w.label, it.label);
        try t.expectEqualStrings(w.icon, it.icon.?);
        try t.expectEqual(w.n, it.submenu.len);
        try t.expect(it.action == .none);
    }
    const leaves = [_]struct { []const u8, command.CommandId }{
        .{ "Scratch buffer", .@"scratch.new" }, .{ "From clipboard", .@"scratch.from_clipboard" },  .{ "HTTP request", .@"http.new" },
        .{ "Shell", .@"term.shell" },           .{ "Browser tab", .@"browser.open" },               .{ "Tab page", .@"tab.new" },
        .{ "File…", .@"picker.files" },
        .{ "Recent files", .@"picker.recent" }, .{ "File browser", .@"files.open" },                .{ "Dual file panes (commander)", .@"files.open_split" },
        .{ "Trash", .@"files.trash" },          .{ "Claude Code session", .@"ai.claude_code_new" },
        .{ "New session in a worktree…", .@"ai.new_session_worktree" },
        .{ "Codex session", .@"ai.codex_new" }, .{ "Note", .@"dock.new_text" },                     .{ "Log tail", .@"dock.new_log_tail" },
    };
    var k: usize = 0;
    for (m.items) |it| for (it.submenu) |leaf| {
        try t.expectEqualStrings(leaves[k][0], leaf.label);
        try t.expectEqual(leaves[k][1], leaf.action.command);
        try t.expect(leaf.icon == null);
        k += 1;
    };
    try t.expectEqual(leaves.len, k);
    // The rows as Rust paints them (`rust-menu-plus-120x40.txt`): the
    // title in the border, ` <icon>  label` with `▸ ` at the end, and
    // the bottom edge straight under the last row — the title is IN the
    // border, so `rows + 2` is the whole frame (2026-09-20: it used to
    // reserve a row for the title as well, which painted as a blank
    // line, and this test pinned it); no child yet.
    const closed = try screenOf(&app);
    defer t.allocator.free(closed);
    // Four short group names: the inner width is Rust's floor of 12.
    try t.expect(std.mem.indexOf(u8, closed, "┌ Create… ───┐") != null);
    try t.expect(std.mem.indexOf(u8, closed, "│ \u{f15b}  New   ▸ │") != null);
    try t.expect(std.mem.indexOf(u8, closed, "│ \u{F06A9}  AI    ▸ │") != null);
    try t.expect(std.mem.indexOf(u8, closed, "│            │") == null);
    try t.expect(std.mem.indexOf(u8, closed, "Scratch buffer") == null);
    // → opens New's child hung from its row: the frame's top on the
    // row, the rows below, Rust's glyph rule on each leaf, no
    // highlight until an arrow; the frame registers its rows.
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expect(m.sub != null);
    try t.expectEqual(@as(usize, 0), m.sub.?.parent);
    try t.expectEqual(@as(usize, 6), m.sub.?.items.len);
    try t.expect(!m.sub.?.highlight);
    const open = try screenOf(&app);
    defer t.allocator.free(open);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{f15b}  New   ▸ │┌───────────────────┐") != null);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{f07c}  Open  ▸ ││ \u{f067}  Scratch buffer │") != null);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{f04b}  From clipboard │") != null);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{f120}  Shell          │") != null);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{f07c}  Browser tab    │") != null);
    try t.expect(std.mem.indexOf(u8, open, "⋮") == null);
    var child_hits: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 1) {
        child_hits += 1;
    };
    try t.expectEqual(@as(usize, 6), child_hits);
    try t.expectEqual(@as(u16, 45), m.sub.?.rect.x);
    try t.expectEqual(@as(u16, 3), m.sub.?.rect.y);
    // j lights the child's cursor row AND moves it (Rust's child
    // `move_down` steps on the first arrow; walkthrough 2.2). The kebab
    // shows only where the label leaves room for it: not on the
    // longest rows (Rust's screen keeps the label there), on HTTP request.
    try app.handle(.{ .key = app_mod.Key.char('j') });
    try t.expect(m.sub.?.highlight);
    try t.expectEqual(@as(usize, 1), m.sub.?.cursor);
    const lit = try screenOf(&app);
    defer t.allocator.free(lit);
    try t.expect(std.mem.indexOf(u8, lit, "│ \u{f067}  Scratch buffer │") != null);
    try t.expect(std.mem.indexOf(u8, lit, "⋮") == null);
    try app.handle(.{ .key = app_mod.Key.char('j') });
    try t.expectEqual(@as(usize, 2), m.sub.?.cursor);
    const lit2 = try screenOf(&app);
    defer t.allocator.free(lit2);
    try t.expect(std.mem.indexOf(u8, lit2, "│ \u{f067}  HTTP request ⋮ │") != null);
    // ← closes it, the parent cursor stays.
    try app.handle(.{ .key = app_mod.Key.named(.left) });
    try t.expect(m.sub == null);
    try t.expectEqual(@as(usize, 0), m.cursor);
    // Enter on a parent opens it; Enter on the last child row runs tab.new.
    const tabs_before = app.layouts.layouts.items.len;
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(m.sub != null);
    try app.handle(.{ .key = app_mod.Key.named(.end) });
    try app.handle(.{ .key = app_mod.Key.named(.end) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(tabs_before + 1, app.layouts.layouts.items.len);
    // A closed buffer puts "Reopen last closed (N)" first, a leaf.
    try app.closed.append(app.gpa, .{ .path = try app.gpa.dupe(u8, "/tmp/gone.txt"), .cursor = 0 });
    try openNewTabMenu(&app, 31, 2);
    try t.expectEqual(@as(usize, 5), m.items.len);
    try t.expectEqualStrings("Reopen last closed (1)", m.items[0].label);
    try t.expectEqual(command.CommandId.@"buffer.reopen", m.items[0].action.command);
    const reopen = try screenOf(&app);
    defer t.allocator.free(reopen);
    try t.expect(std.mem.indexOf(u8, reopen, "│ \u{f07c}  Reopen last closed (1) │") != null);
    // Under ascii icons the column paints the twins and ▸ is `>`.
    app.cfg.ui.ascii_icons = true;
    try openNewTabMenu(&app, 31, 2);
    const ascii = try screenOf(&app);
    defer t.allocator.free(ascii);
    try t.expect(std.mem.indexOf(u8, ascii, "\u{f15b}") == null);
    // (The Reopen row is still there, so the frame is wider than above.)
    try t.expect(std.mem.indexOf(u8, ascii, "| o  Reopen last closed (1) |") != null);
    try t.expect(std.mem.indexOf(u8, ascii, "| f  New                  > |") != null);
    try t.expect(std.mem.indexOf(u8, ascii, "| #  Dock                 > |") != null);
}

test "the + menu: the Integrations group lists the enabled integration chips with their own glyphs; a chip without a command is left out" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const icons = [_]Config.IntegrationIcon{
        .{ .id = "jira", .glyph = "\u{e75c}", .fallback = "j", .command = "view.settings", .label = "Jira" },
        .{ .id = "off", .glyph = "\u{e75c}", .fallback = "o", .command = "view.settings", .enabled = false },
        .{ .id = "mute", .glyph = "\u{e75c}", .fallback = "m" },
        .{ .id = "under_score", .glyph = "\u{e75c}", .fallback = "u", .command = "view.about" },
    };
    app.cfg.ui.integration_icons = &icons;
    try openNewTabMenu(&app, 31, 2);
    const m = &app.overlay.menu;
    try t.expectEqual(@as(usize, 5), m.items.len);
    const group = m.items[4];
    try t.expectEqualStrings("Integrations", group.label);
    try t.expectEqualStrings("\u{f12e}", group.icon.?);
    try t.expectEqual(@as(usize, 2), group.submenu.len);
    try t.expectEqualStrings("Jira", group.submenu[0].label);
    try t.expectEqualStrings("\u{e75c}", group.submenu[0].icon.?);
    try t.expectEqual(command.CommandId.@"view.settings", group.submenu[0].action.command);
    try t.expectEqualStrings("under_score", group.submenu[1].label);
    // The rows paint the chip's glyph, not the play triangle.
    m.cursor = 4;
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    const open = try screenOf(&app);
    defer t.allocator.free(open);
    try t.expect(std.mem.indexOf(u8, open, "│ \u{e75c}  Jira ") != null);
    // Hiding the only two rows drops the group.
    try app.plus_hidden.append(app.gpa, try app.gpa.dupe(u8, "view.settings"));
    try app.plus_hidden.append(app.gpa, try app.gpa.dupe(u8, "view.about"));
    try openNewTabMenu(&app, 31, 2);
    try t.expectEqual(@as(usize, 4), m.items.len);
}

test "a click on the child row's kebab glyph opens the curation, not the row; a right press on a row does too" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    try openNewTabMenu(&app, 45, 1);
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // New ▸
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // the first arrow moves as well as lights
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // HTTP request: room for the kebab
    try app.render();
    // The glyph: the cell on the child's row 2 painting `⋮`.
    var kebab_row: ?u16 = null;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 3 and h.target.menu_item.idx == 2) {
        kebab_row = h.rect.y;
    };
    try t.expect(kebab_row != null);
    const y = kebab_row.?;
    var glyph_x: ?u16 = null;
    var x: u16 = 0;
    while (x < app.screen.width) : (x += 1) {
        const cell = app.screen.readCell(x, y) orelse continue;
        if (std.mem.eql(u8, cell.char.grapheme, "⋮")) glyph_x = x;
    }
    try t.expect(glyph_x != null);
    // The glyph's cell resolves to the kebab, not the row under it.
    const hit = app.hits.at(glyph_x.?, y).?;
    try t.expect(hit == .menu_item);
    try t.expectEqual(@as(u32, 3), hit.menu_item.menu);
    try t.expectEqual(@as(u32, 2), hit.menu_item.idx);
    // And the click opens Pin / Hide / Copy for that row rather than running it.
    try app.handle(.{ .mouse = .{ .x = glyph_x.?, .y = y, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Pin to top", app.overlay.menu.sub.?.items[0].label);
    try t.expectEqual(command.CommandId.@"http.new", app.menu_ctx.?);
    // A right press on the second child row opens its curation.
    try app.handle(.{ .key = app_mod.Key.named(.left) });
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // New ▸ again
    try app.render();
    var row1: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 1 and h.target.menu_item.idx == 1) {
        row1 = h.rect;
    };
    try app.handle(.{ .mouse = .{ .x = row1.?.x + 3, .y = row1.?.y, .kind = .press, .button = .right } });
    try t.expectEqualStrings("Pin to top", app.overlay.menu.sub.?.items[0].label);
    try t.expectEqual(command.CommandId.@"scratch.from_clipboard", app.menu_ctx.?);
    // A right press on a parent row opens nothing new.
    try app.handle(.{ .mouse = .{ .x = 50, .y = 2, .kind = .press, .button = .right } });
    try t.expectEqual(command.CommandId.@"scratch.from_clipboard", app.menu_ctx.?);
    // A right press on a row of a menu that is not curatable does nothing.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try openEditorMenu(&app, 10, 5);
    try app.render();
    try app.handle(.{ .mouse = .{ .x = 14, .y = 7, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expect(app.overlay.menu.sub == null);
}

test "curation: → on a child row offers Pin / Hide / Copy; a pin lands on top and in the home config; a hide drops the row; both survive a fresh App" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.integration_icons = &.{};
    try openNewTabMenu(&app, 4, 1);
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // New ▸
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // From clipboard (the first arrow moves)
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // HTTP request
    try app.handle(.{ .key = app_mod.Key.named(.right) }); // curation
    const m = &app.overlay.menu;
    try t.expect(m.sub != null);
    try t.expectEqualStrings("Pin to top", m.sub.?.items[0].label);
    try t.expectEqual(command.CommandId.@"http.new", app.menu_ctx.?);
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // pin (row 0)
    try t.expect(app.overlay == .none);
    try t.expectEqual(@as(usize, 1), app.plus_pinned.items.len);
    try t.expectEqualStrings("http.new", app.plus_pinned.items[0]);
    const cfg_text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(cfg_text);
    try t.expect(std.mem.indexOf(u8, cfg_text, ".plus_menu_pinned = .{\"http.new\"}") != null);
    // Re-opened: the pinned row leads, its own label, out of its group;
    // no rule between it and the groups (Rust paints none).
    try openNewTabMenu(&app, 4, 1);
    try t.expectEqual(@as(usize, 5), m.items.len);
    try t.expectEqualStrings("HTTP request", m.items[0].label);
    try t.expect(!m.items[1].separator_before);
    try t.expectEqual(@as(usize, 5), m.items[1].submenu.len);
    // → on the pinned row: Unpin leads; Hide drops it from the New child too.
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqualStrings("Unpin", m.sub.?.items[0].label);
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // Hide this row
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // hide
    try t.expectEqual(@as(usize, 0), app.plus_pinned.items.len);
    try t.expectEqualStrings("http.new", app.plus_hidden.items[0]);
    try openNewTabMenu(&app, 4, 1);
    try t.expectEqual(@as(usize, 4), m.items.len);
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqual(@as(usize, 5), m.sub.?.items.len);
    for (m.sub.?.items) |it| try t.expect(!std.mem.eql(u8, it.label, "HTTP request"));
    // Copy id lands on the clipboard (→ on the child's row 0, Scratch buffer).
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try app.handle(.{ .key = app_mod.Key.named(.end) });
    try app.handle(.{ .key = app_mod.Key.named(.end) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqualStrings("scratch.new", app.clipboard.text());
    // Pin one more, then a fresh App on the same data root reads both back.
    try openNewTabMenu(&app, 4, 1);
    try app.handle(.{ .key = app_mod.Key.named(.down) }); // Open
    try t.expectEqual(@as(usize, 1), m.cursor);
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqual(@as(usize, 5), m.sub.?.items.len);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.end) }); // Trash
    try t.expectEqual(@as(usize, 4), m.sub.?.cursor);
    try app.handle(.{ .key = app_mod.Key.named(.right) });
    try t.expectEqual(command.CommandId.@"files.trash", app.menu_ctx.?);
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // pin files.trash (row 0)
    try t.expectEqual(@as(usize, 1), app.plus_pinned.items.len);
    // The next launch reads the home config (`config.load`) — pinned
    // rows and hidden rows come back from it.
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", root);
    var loaded = try @import("../config/load.zig").load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars } });
    var again = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = root, .data_root = root, .cols = 100, .rows = 30 });
    loaded = undefined; // the app owns it now
    defer again.deinit();
    try t.expectEqual(@as(usize, 1), again.plus_pinned.items.len);
    try t.expectEqualStrings("files.trash", again.plus_pinned.items[0]);
    try t.expectEqualStrings("http.new", again.plus_hidden.items[0]);
    again.tree.visible = false;
    again.cfg.ui.integration_icons = &.{};
    try openNewTabMenu(&again, 4, 1);
    try t.expectEqualStrings("Trash", again.overlay.menu.items[0].label);
    try t.expectEqual(@as(usize, 4), again.overlay.menu.items[2].submenu.len);
}

test "an integration chip's menu offers the requests behind its number, filtered to that chip's service" {
    // `jira_work.assigned` is paid for out of the `jira` bucket and
    // logged to `jira.jsonl`; the prefix is what names both.
    try t.expectEqualStrings("jira", serviceOfSegment("jira_work.assigned"));
    try t.expectEqualStrings("bitbucket", serviceOfSegment("bitbucket_prs.reviews_mine"));
    try t.expectEqualStrings("jira", serviceOfSegment("jira.x"));
    try t.expectEqualStrings("plain", serviceOfSegment("plain"));
    try t.expectEqualStrings("", serviceOfSegment(""));

    var app = try App.initWith(t.allocator, t.io, .{ .cols = 100, .rows = 30 });
    defer app.deinit();
    try app.ipc_fx.segments.append(app.gpa, .{
        .id = try app.gpa.dupe(u8, "jira_work.assigned"),
        .side = .right,
        .text = try app.gpa.dupe(u8, "jira 25"),
        .color = null,
        .click_command = null,
        .priority = 60,
        .min_width = 0,
        .max_width = 0,
        .tooltip = null,
        .items = &.{},
    });
    try openIntegrationSegmentMenu(&app, 0, 4, 1);
    var found: ?[]const u8 = null;
    for (app.overlay.menu.items) |item| {
        if (std.mem.eql(u8, item.label, "Requests…")) found = switch (item.action) {
            .requests_for => |svc| svc,
            else => null,
        };
    }
    // The row is there, and it names the service rather than opening
    // the whole machine's log.
    try t.expectEqualStrings("jira", found orelse return error.TestExpectedEqual);
}
