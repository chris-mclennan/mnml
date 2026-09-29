//! `zig build hover-audit` / `mnml-zig hover-audit` — every hoverable
//! target the app can produce, and whether the info view has curated
//! words for it.
//!
//! The audit builds a headless `App` on a scratch workspace and walks
//! every `HitTarget` family: the statusline's segments, the rail's
//! rows, every `render.Button`, the tab strip, the launcher dock's item
//! kinds, the dock widgets' parts, every Settings row, the confirm
//! boxes' buttons, a picker's row, every context menu's rows (each
//! menu is opened for real and its labels read back, submenus
//! included), the list panels' chips / rows / kebabs / filters, the
//! HTTP panel's parts, the tree's rows and chips, the editor's cells,
//! and the surface line of every pane kind. Each probe is resolved the
//! way the ladder resolves it (`info_view.resolve`): CURATED when
//! `info_view_copy.lookup` has an entry, FALLBACK when only
//! `discovery.describe`'s one-liner answers, NONE when nothing does.
//!
//! **The required set is everything the audit probes, minus
//! `docs/hover-help-todo.txt`.** That file is the allow-list of targets
//! known to be uncovered — the phase-two backlog, one key per line —
//! so the audit fails only on a NEW uncovered target: the build cannot
//! add a control without help, while the backlog stays visible and
//! shrinks. A key in the file that is covered now is STALE and
//! reported (the unit test fails on it, so the file cannot drift; the
//! CLI prints it). `--write-todo PATH` rewrites the file from the
//! current uncovered set.
//!
//! Every curated entry the walk reaches is also linted
//! (`info_view_copy.lint`): a shortcut row naming a command no profile
//! binds, a literal chord outside the allowed set, a body under forty
//! characters. Command and Settings links are checked by the compiler.
//!
//! `--strict` exits 1 on a new uncovered target or a lint problem; the
//! unit test below asserts both are zero and the todo is exact.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const hit = @import("../ui/hit.zig");
const HitTarget = hit.HitTarget;
const info_view = @import("info_view.zig");
const Resolution = info_view.Resolution;
const copy = @import("info_view_copy.zig");
const sl = @import("../ui/statusline.zig");
const statusline_app = @import("statusline.zig");
const rail_ui = @import("../ui/activity_bar.zig");
const render = @import("render.zig");
const Button = render.Button;
const menu_bar = @import("menu_bar.zig");
const context_menus = @import("context_menus.zig");
const usage_pane = @import("usage_pane.zig");
const settings_app = @import("settings.zig");
const ui_settings = @import("../ui/settings.zig");
const launcher_dock = @import("launcher_dock.zig");
const tree_view = @import("../ui/tree_view.zig");
const http_panel = @import("../ui/http_panel.zig");
const search_view = @import("../ui/search_section_view.zig");
const git_palette_ui = @import("../ui/git_palette.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const toast_mod = @import("../ui/toast.zig");
const md_preview = @import("md_preview.zig");
const zon_pane = @import("zon_pane.zig");
const command = @import("../core/command.zig");
const os_path = @import("../core/os_path.zig");
const ghost_chip = @import("ghost_chip.zig");
const clock_mod = @import("clock.zig");
const coverage = @import("coverage.zig");
const now_playing = @import("now_playing.zig");
const git_status_view = @import("../ui/git_status_view.zig");

/// The allow-list, embedded so the unit test and the CLI read the same
/// file the repo carries.
pub const todo_text = @embedFile("hover_help_todo");

pub const Result = struct {
    key: []const u8,
    res: Resolution,
    title: []const u8,
};

pub const Report = struct {
    results: []const Result,
    lint: []const copy.Problem,
    /// Uncovered (fallback or none) and not in the todo.
    new_uncovered: []const []const u8,
    /// In the todo, but curated now — delete the line.
    stale: []const []const u8,
    curated: usize,
    fallback: usize,
    none: usize,

    pub fn ok(r: Report) bool {
        return r.new_uncovered.len == 0 and r.lint.len == 0;
    }
};

// ─── the walk ───────────────────────────────────────────────────────────

const Walk = struct {
    app: *App,
    arena: Allocator,
    results: std.ArrayListUnmanaged(Result) = .empty,
    lint: std.ArrayListUnmanaged(copy.Problem) = .empty,

    fn probe(w: *Walk, key: []const u8, target: HitTarget) Allocator.Error!void {
        const res = try info_view.resolve(w.app, w.arena, target);
        var title: []const u8 = "";
        if (res == .curated) {
            const entry = (try copy.lookup(w.app, w.arena, target)) orelse copy.panels.infoView(.body);
            title = entry.title;
            try copy.lint(w.arena, entry, &w.lint);
        }
        try w.results.append(w.arena, .{ .key = key, .res = res, .title = title });
    }

    /// A probe whose entry the walk reaches directly, not through a
    /// `HitTarget` — a pane kind, a dock item kind, a menu's submenu row.
    fn probeEntry(w: *Walk, key: []const u8, entry: ?copy.Entry) Allocator.Error!void {
        if (entry) |e| {
            try copy.lint(w.arena, e, &w.lint);
            try w.results.append(w.arena, .{ .key = key, .res = .curated, .title = e.title });
        } else try w.results.append(w.arena, .{ .key = key, .res = .fallback, .title = "" });
    }

    fn fmtKey(w: *Walk, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(w.arena, fmt, args);
    }

    fn closeOverlay(w: *Walk) void {
        w.app.overlay.deinit(w.app.gpa);
        w.app.overlay = .none;
        if (w.app.focus == .overlay) w.app.focus = if (w.app.active) |a| .{ .pane = a } else .tree;
    }

    /// Every row of the open menu, then its submenus by label.
    fn menuRows(w: *Walk, family: []const u8) Allocator.Error!void {
        // A menu that needs state the scratch app lacks (a PR on the
        // branch, a file chip with a file) opens nothing; that is not a
        // gap in the dictionary, so it is not a row in the table.
        if (w.app.overlay != .menu) return;
        // The key is the opener's name, not the menu's title: a title
        // can be the workspace's directory or a pane's, which the
        // scratch app does not control.
        const m = &w.app.overlay.menu;
        const title = try w.arena.dupe(u8, m.title);
        const items = try w.arena.dupe(command.MenuItem, m.items);
        for (items, 0..) |it, i| {
            try w.probe(try w.fmtKey("menu:{s}/{s}", .{ family, it.label }), .{ .menu_item = .{ .menu = 0, .idx = @intCast(i) } });
            for (it.submenu) |sub| try w.probeEntry(try w.fmtKey("menu:{s}/{s}/{s}", .{ family, it.label, sub.label }), try copy.menus.resolve(w.app, w.arena, title, it.label, sub));
        }
        w.closeOverlay();
    }
};

/// The walk over a fresh app on `workspace` (which holds `README.md`,
/// `src/main.rs`, `weird.xyz`). `todo` is the allow-list's text.
pub fn run(gpa: Allocator, io: Io, arena: Allocator, workspace: []const u8, data_root: []const u8, todo: []const u8) !Report {
    var app = try App.initWith(gpa, io, .{ .workspace = workspace, .data_root = data_root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    try app.render();
    var w: Walk = .{ .app = &app, .arena = arena };
    try walkStatusline(&w);
    try walkRail(&w);
    try walkButtons(&w);
    try walkPanes(&w);
    try walkDock(&w);
    try walkPanels(&w);
    try walkTree(&w);
    try walkEditor(&w);
    try walkUsagePane(&w);
    try walkOverlays(&w);
    try walkMenus(&w);
    try walkGitGraph(&w);
    try walkFileChipRows(&w);
    return tally(arena, w.results.items, w.lint.items, todo);
}

/// The git graph pane's controls (`info_view_copy/git_graph.zig`) and
/// its detail column's file-row menus. The scratch workspace is not a
/// repository, so the pane cannot be opened here; the ids and the menu
/// rows are the ones `ui/git_graph_view.zig`, `ui/git_toolbar.zig` and
/// `git.openDetailRowMenu` register, resolved the way the ladder does.
fn walkGitGraph(w: *Walk) Allocator.Error!void {
    const gg = copy.git_graph;
    const gv = @import("../ui/git_graph_view.zig");
    const tb = @import("../ui/git_toolbar.zig");
    inline for (comptime std.enums.values(tb.Action)) |a| try w.probeEntry("git_graph:toolbar:" ++ @tagName(a), gg.entry(tb.hitId(a)));
    inline for (comptime std.enums.values(gv.SortCol)) |c| try w.probeEntry("git_graph:column:" ++ @tagName(c), gg.entry(gv.sortId(c)));
    inline for (comptime std.enums.values(gv.WipButton)) |b| try w.probeEntry("git_graph:wip:" ++ @tagName(b), gg.entry(gv.wipButtonId(b)));
    try w.probeEntry("git_graph:file:unstaged", gg.entry(gv.wipFileId(.{ .idx = 0, .staged = false, .button = false })));
    try w.probeEntry("git_graph:file:staged", gg.entry(gv.wipFileId(.{ .idx = 0, .staged = true, .button = false })));
    try w.probeEntry("git_graph:file:stage_button", gg.entry(gv.wipFileId(.{ .idx = 0, .staged = false, .button = true })));
    try w.probeEntry("git_graph:file:unstage_button", gg.entry(gv.wipFileId(.{ .idx = 0, .staged = true, .button = true })));
    try w.probeEntry("git_graph:detail_row", gg.entry(gv.detailRowId(0)));
    try w.probeEntry("git_graph:plan_row", gg.entry(gv.planRowId(0)));
    try w.probeEntry("git_graph:divider", gg.entry(gv.divider_id));
    // The detail rows' menus, titled with the file's name.
    const Row = struct { label: []const u8, action: command.MenuAction };
    const menu_rows = [_]Row{
        .{ .label = "Open diff (Enter)", .action = .{ .command = .@"git.graph_detail_open" } },
        .{ .label = "Open file", .action = .{ .command = .@"git.open_file" } },
        .{ .label = "Stage", .action = .{ .command = .@"git.stage" } },
        .{ .label = "Unstage", .action = .{ .command = .@"git.unstage" } },
        .{ .label = "Discard changes\u{2026}", .action = .{ .command = .@"git.discard" } },
        .{ .label = "Stash this file\u{2026}", .action = .{ .command = .@"git.stash_file" } },
        .{ .label = "Copy path (a.txt)", .action = .{ .copy_text = "a.txt" } },
        .{ .label = "Open the file's diff in this commit (Enter)", .action = .{ .command = .@"git.graph_detail_open" } },
        .{ .label = "Open file at this revision", .action = .{ .command = .@"git.graph_file_at_rev" } },
        .{ .label = "Copy commit hash (abc1234)", .action = .{ .copy_text = "abc1234" } },
        .{ .label = "Browse commit on remote", .action = .{ .command = .@"git.browse_commit" } },
    };
    for (menu_rows) |r| try w.probeEntry(try w.fmtKey("menu:git_detail_row/{s}", .{r.label}), copy.menus.lookupItem("a.txt", null, r.label, r.action));
}

/// The statusline file chip's `Buffer` menu. The walk's menus family
/// opens it on the active editor, which on the scratch app has no
/// file, so it opens nothing there (`menuRows`); its rows are read
/// here the way `context_menus.openFileChipMenu` builds them.
fn walkFileChipRows(w: *Walk) Allocator.Error!void {
    const Row = struct { label: []const u8, action: command.MenuAction };
    const menu_rows = [_]Row{
        .{ .label = "Reveal in tree", .action = .{ .command = .@"view.reveal_in_tree" } },
        .{ .label = "Reveal in Finder", .action = .{ .command = .@"view.reveal_active" } },
        .{ .label = "Copy path", .action = .{ .command = .@"file.copy_path" } },
        .{ .label = "Copy absolute path", .action = .{ .copy_text = "/w/a.txt" } },
        .{ .label = "Copy file name", .action = .{ .copy_text = "a.txt" } },
        .{ .label = "Close buffer", .action = .{ .command = .@"buffer.close" } },
    };
    for (menu_rows) |r| try w.probeEntry(try w.fmtKey("menu:file_chip/{s}", .{r.label}), copy.menus.lookupItem("Buffer", null, r.label, r.action));
}

fn walkStatusline(w: *Walk) Allocator.Error!void {
    try w.probe("statusline:mode", .{ .statusline_seg = sl.seg_mode });
    try w.probe("statusline:file", .{ .statusline_seg = sl.seg_file });
    try w.probe("statusline:position", .{ .statusline_seg = sl.seg_position });
    try w.probe("statusline:language", .{ .statusline_seg = sl.seg_language });
    try w.probe("statusline:restricted", .{ .statusline_seg = sl.seg_restricted });
    inline for (comptime std.enums.values(statusline_app.SegId)) |id| try w.probe("statusline:" ++ @tagName(id), .{ .statusline_seg = id.raw() });
    try w.probe("statusline:tip_row", .{ .tip_row = .{ .seg = sl.seg_mode, .idx = 0, .x = 0, .y = 0 } });
    // A host's segment with and without a tooltip.
    try w.app.ipc_fx.setSegment(w.app.gpa, .{ .id = "audit-plain", .text = " 3 " });
    try w.app.ipc_fx.setSegment(w.app.gpa, .{ .id = "audit-tip", .text = " 3 ", .tooltip = "Three things\nwhat they are", .click_command = "messages.show" });
    const segs = w.app.ipc_fx.segments.items;
    for (segs, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, "audit-plain")) try w.probe("statusline:dyn:plain", .{ .statusline_seg = sl.seg_dyn_base + @as(u32, @intCast(i)) });
        if (std.mem.eql(u8, s.id, "audit-tip")) try w.probe("statusline:dyn:tooltip", .{ .statusline_seg = sl.seg_dyn_base + @as(u32, @intCast(i)) });
    }
}

fn walkRail(w: *Walk) Allocator.Error!void {
    inline for (comptime std.enums.values(rail_ui.Section)) |s| try w.probe("rail:" ++ @tagName(s), .{ .rail = .{ .section = s } });
    try w.probe("rail:gear", .{ .rail = .gear });
    try w.probe("rail:pin", .{ .rail = .{ .pin = 0 } });
    try w.probe("rail:script", .{ .rail = .{ .script = 0 } });
}

fn walkButtons(w: *Walk) Allocator.Error!void {
    inline for (comptime std.enums.values(Button)) |b| {
        if (@intFromEnum(b) < @intFromEnum(Button.tab_page_base)) try w.probe("button:" ++ @tagName(b), .{ .button = @intFromEnum(b) });
    }
    try w.probe("button:tab_page", .{ .button = Button.tabPage(0) });
    try w.probe("button:tab_page_close", .{ .button = Button.tabPageClose(0) });
    try w.probe("button:tab_scroll_left", .{ .button = Button.tabScroll(0, .left) });
    try w.probe("button:tab_scroll_right", .{ .button = Button.tabScroll(0, .right) });
    try w.probe("button:new_tab", .{ .button = Button.newTab(0) });
    inline for (comptime std.enums.values(menu_bar.Menu)) |m| try w.probe("button:menu:" ++ @tagName(m), .{ .button = menu_bar.button_base + @intFromEnum(m) });
    try w.probe("button:menu_overflow", .{ .button = menu_bar.overflow_button });
    try w.probe("button:md_edit", .{ .button = md_preview.button_edit });
    try w.probe("button:md_preview", .{ .button = md_preview.button_preview });
    try w.probe("button:zon_view", .{ .button = zon_pane.button_view });
    try w.probe("button:zon_source", .{ .button = zon_pane.button_source });
    w.app.toast("audit toast", .{});
    try w.probe("button:toast", .{ .button = toast_mod.button_base });
    try w.probe("button:undo", .{ .button = toast_mod.undo_button });
    const chips = try @import("integrations.zig").chips(w.app, w.arena);
    if (chips.len > 0) try w.probe("button:integration_chip", .{ .button = integrations_view.chip_base });
}

fn walkPanes(w: *Walk) Allocator.Error!void {
    inline for (comptime std.enums.values(std.meta.Tag(app_mod.Pane))) |k| try w.probeEntry("pane:" ++ @tagName(k), copy.chrome.paneKind(k));
    try w.probe("divider", .{ .divider = 0 });
    try w.probe("divider:info_view", .{ .divider = render.info_divider_id });
    try w.probe("scrollbar:pane", .{ .scrollbar = .{ .owner = .{ .pane = 0 }, .axis = .v } });
    try w.probe("scrollbar:panel", .{ .scrollbar = .{ .owner = .{ .panel = .todos }, .axis = .v } });
    try w.probe("scrollbar:tree", .{ .scrollbar = .{ .owner = .tree, .axis = .v } });
    try w.probe("scrollbar:welcome", .{ .scrollbar = .{ .owner = .{ .welcome = .recent }, .axis = .v } });
    try w.probe("hover_popup", .hover_popup);
}

fn walkDock(w: *Walk) Allocator.Error!void {
    try w.probe("launcher_dock:pin", .{ .launcher_dock = .pin });
    inline for (comptime std.enums.values(launcher_dock.Kind)) |k| try w.probeEntry("launcher_dock:kind:" ++ @tagName(k), copy.dock.itemKind(k, null, false));
    const items = try launcher_dock.items(w.app, w.arena);
    for (items, 0..) |it, i| try w.probe(try w.fmtKey("launcher_dock:item:{s}", .{@tagName(it.kind)}), .{ .launcher_dock = .{ .item = @intCast(i) } });
    inline for (comptime std.enums.values(hit.DockPart)) |p| try w.probe("dock_widget:" ++ @tagName(p), .{ .dock = .{ .id = 999, .part = p } });
}

fn walkPanels(w: *Walk) Allocator.Error!void {
    inline for (comptime std.enums.values(hit.PanelId)) |p| {
        inline for (comptime std.enums.values(hit.ChipKind)) |k| try w.probe("chip:" ++ @tagName(p) ++ ":" ++ @tagName(k), .{ .chip = .{ .panel = p, .kind = k } });
        try w.probe("row:" ++ @tagName(p), .{ .row = .{ .panel = p, .idx = 0 } });
        try w.probe("kebab:" ++ @tagName(p), .{ .kebab = .{ .panel = p, .idx = 0 } });
        try w.probe("filter_input:" ++ @tagName(p), .{ .filter_input = p });
    }
    inline for (comptime std.enums.values(search_view.Flag)) |f| try w.probe("search_chip:" ++ @tagName(f), .{ .search_chip = f });
    inline for (comptime std.enums.values(http_panel.Section)) |s| inline for (comptime std.enums.values(http_panel.ChipKind)) |k| try w.probe("http:chip:" ++ @tagName(s) ++ ":" ++ @tagName(k), .{ .http = .{ .chip = .{ .section = s, .kind = k } } });
    inline for (comptime std.enums.values(http_panel.Link)) |l| try w.probe("http:link:" ++ @tagName(l), .{ .http = .{ .link = l } });
    try w.probe("http:folder_new", .{ .http = .{ .folder_new = 0 } });
    inline for (comptime std.enums.values(git_palette_ui.Part)) |p| try w.probe("git_palette:" ++ @tagName(p), .{ .git_palette = p });
    try w.probe("font_update", .{ .font_update = 0 });
    try w.probe("ai_placeholder", .{ .ai_placeholder = 0 });
    inline for (comptime std.enums.values(hit.WelcomeRow.Kind)) |k| try w.probe("welcome:" ++ @tagName(k), .{ .welcome = .{ .kind = k, .idx = 0 } });
    try w.probe("session_changes", .{ .session_changes = 0 });
    // sessiondiff: a changes view's hint words and a row. The view has
    // no session behind it here, so the row is the generic one; the
    // unit tests reach the four row kinds.
    const title = try w.app.gpa.dupe(u8, "changes \u{B7} audit");
    const vid = w.app.panes.add(.{ .session_changes = .{ .session = 0, .token = 0, .title = title } }) catch |err| {
        w.app.gpa.free(title);
        return err;
    };
    inline for (comptime std.enums.values(git_status_view.Action)) |a| try w.probe("script_hit:session_changes:hint:" ++ @tagName(a), .{ .script_hit = .{ .pane = vid, .id = git_status_view.hintId(a) } });
    try w.probe("script_hit:session_changes:row", .{ .script_hit = .{ .pane = vid, .id = 0 } });
    try w.probe("link", .{ .link = .{ .url = "https://example.com/" } });
    try w.probe("info_view:body", .{ .info_view = .body });
    try w.probe("info_view:kebab", .{ .info_view = .kebab });
    try w.probe("info_view:pin", .{ .info_view = .pin });
    try w.probe("info_view:try_it", .{ .info_view = .{ .try_it = 0 } });
}

fn walkTree(w: *Walk) Allocator.Error!void {
    try w.probe("tree_root:0", .{ .tree_root = 0 });
    if (w.app.tree.roots.items.len > 0) try w.probe("tree_root:extra", .{ .tree_root = 1 });
    try w.probe("tree_empty", .{ .tree_empty = 0 });
    inline for (comptime std.enums.values(tree_view.Chip)) |c| try w.probe("tree_chip:" ++ @tagName(c), .{ .tree_chip = c });
    for (w.app.tree.rows.items, 0..) |row, i| {
        if (row.header) continue;
        try w.probe(try w.fmtKey("tree_node:{s}", .{if (row.is_dir) "dir" else row.name()}), .{ .tree_node = @intCast(i) });
    }
    // The dictionary's whole-name and extension families, by sample.
    try w.probeEntry("tree_node:family:by_name", try copy.tree.rowEntry(w.arena, "package.json", false));
    try w.probeEntry("tree_node:family:by_ext", try copy.tree.rowEntry(w.arena, "x.py", false));
}

fn walkEditor(w: *Walk) Allocator.Error!void {
    const path = try std.fs.path.join(w.arena, &.{ w.app.workspace, "README.md" });
    const id = w.app.openPath(path) catch {
        try w.results.append(w.arena, .{ .key = "editor:(README.md did not open)", .res = .none, .title = "" });
        return;
    };
    w.app.focus = .{ .pane = id };
    // A markdown file may open rendered; the raw editor is what the
    // cells belong to.
    const eid: PaneId = if (w.app.panes.editor(id) != null) id else blk: {
        const scratch = w.app.openScratch() catch id;
        break :blk scratch;
    };
    try w.probe("pane:active", .{ .pane = eid });
    try w.probe("editor_cell", .{ .editor_cell = .{ .pane = eid, .line = 0, .col = 0 } });
    try w.probe("gutter", .{ .gutter = .{ .pane = eid, .line = 0 } });
    try w.probe("fold_arrow", .{ .fold_arrow = .{ .pane = eid, .line = 0 } });
    if (w.app.panes.editor(eid)) |e| if (e.buf.doc.path != null) try w.probe("breadcrumb", .{ .breadcrumb = .{ .pane = eid, .idx = 0 } });
    try w.app.render();
    // The tab of the active pane, and its badge.
    var tab: ?hit.TabRef = null;
    for (w.app.hits.items.items) |h| if (h.target == .tab) {
        tab = h.target.tab;
    };
    if (tab) |tb| {
        try w.probe("tab", .{ .tab = tb });
        try w.probe("tab_close", .{ .tab_close = tb });
    } else try w.results.append(w.arena, .{ .key = "tab:(no tab painted)", .res = .none, .title = "" });
    try w.probe("script_hit:row", .{ .script_hit = .{ .pane = eid, .id = hit.ListHit.row(0) } });
    try w.probe("script_hit:chip", .{ .script_hit = .{ .pane = eid, .id = hit.ListHit.chip(.sort) } });
    // The current-line blame's text (`app/line_blame.zig`).
    try w.probe("script_hit:line_blame", .{ .script_hit = .{ .pane = eid, .id = @import("line_blame.zig").hit_id } });
}

/// The Claude usage pane's parts: the kebab, a row outside any account,
/// an account's block and its pencil (one account seeded to name).
fn walkUsagePane(w: *Walk) Allocator.Error!void {
    const id = try w.app.panes.add(.{ .ai_usage = .{ .product = .claude } });
    if (w.app.ai.usage.accounts.items.len == 0) try w.app.ai.usage.accounts.append(w.app.gpa, .{ .arena = .init(w.app.gpa), .name = "work" });
    try w.probe("script_hit:usage:kebab", .{ .script_hit = .{ .pane = id, .id = usage_pane.hit_kebab } });
    try w.probe("script_hit:usage:body", .{ .script_hit = .{ .pane = id, .id = usage_pane.hit_body } });
    try w.probe("script_hit:usage:account", .{ .script_hit = .{ .pane = id, .id = usage_pane.hit_account_base } });
    try w.probe("script_hit:usage:pencil", .{ .script_hit = .{ .pane = id, .id = usage_pane.hit_pencil_base } });
    try w.probe("script_hit:usage:breakdown", .{ .script_hit = .{ .pane = id, .id = usage_pane.hit_breakdown_base } });
}

fn walkOverlays(w: *Walk) Allocator.Error!void {
    const app = w.app;
    // Settings: every row, the option chip, the section names, the
    // filter, the box, the Reset row.
    try settings_app.open(app);
    for (settings_app.rows, 0..) |r, i| try w.probe(try w.fmtKey("settings:row:{s}", .{r.path}), .{ .overlay_item = @intCast(i) });
    try w.probe("settings:option", .{ .overlay_item = ui_settings.optionHit(0, 0) });
    for (0..5) |n| try w.probe(try w.fmtKey("settings:section:{d}", .{n}), .{ .overlay_item = ui_settings.sectionHit(n) });
    try w.probe("settings:filter", .{ .overlay_item = ui_settings.filter_id });
    try w.probe("settings:surface", .{ .overlay_item = ui_settings.surface_id });
    try w.probe("settings:reset", .{ .overlay_item = settings_app.reset_id });
    const refs = try @import("integrations.zig").settingRefs(app, w.arena);
    if (refs.len > 0) try w.probe("settings:integration_row", .{ .overlay_item = settings_app.integ_base });
    w.closeOverlay();
    // The confirm boxes.
    const msg = try app.gpa.dupe(u8, "audit");
    app.overlay = .{ .confirm = .{ .state = .{ .title = "Quit", .message = msg, .choices = &App.quit_choices }, .purpose = .quit, .message = msg } };
    for (App.quit_choices, 0..) |c, i| try w.probe(try w.fmtKey("confirm:quit:{s}", .{c.label}), .{ .overlay_item = @intCast(i) });
    app.overlay.confirm.purpose = .quit_clean;
    app.overlay.confirm.state.choices = &App.quit_clean_choices;
    for (App.quit_clean_choices, 0..) |c, i| try w.probe(try w.fmtKey("confirm:quit_clean:{s}", .{c.label}), .{ .overlay_item = @intCast(i) });
    app.overlay.confirm.purpose = .restart;
    app.overlay.confirm.state.choices = &App.restart_choices;
    for (App.restart_choices, 0..) |c, i| try w.probe(try w.fmtKey("confirm:restart:{s}", .{c.label}), .{ .overlay_item = @intCast(i) });
    app.overlay.confirm.purpose = .{ .close_pane = 0 };
    app.overlay.confirm.state.choices = &App.close_choices;
    for (App.close_choices, 0..) |c, i| try w.probe(try w.fmtKey("confirm:close_pane:{s}", .{c.label}), .{ .overlay_item = @intCast(i) });
    app.overlay.confirm.purpose = .trust_workspace;
    try w.probe("confirm:other", .{ .overlay_item = 0 });
    w.closeOverlay();
    // The other overlays' rows.
    app.overlay = .discovery;
    try w.probe("overlay_item:discovery", .{ .overlay_item = 0 });
    app.overlay = .{ .info = .about };
    try w.probe("overlay_item:about", .{ .overlay_item = 0 });
    app.overlay = .{ .help = .{} };
    try w.probe("overlay_item:help", .{ .overlay_item = 0 });
    w.closeOverlay();
    app.overlay = .none;
    // The find bar over a terminal pane (`pty_search.zig`): a dormant
    // terminal — nothing is spawned — with the bar open on it.
    if (@import("pty_pane.zig").open(app, .{ .dormant = true, .label = "audit" })) |tid| {
        const bar = @import("../ui/find_bar.zig");
        app.find_bar = .{ .pane = tid, .snapshot = null, .snapshot_cursor = 0 };
        try w.probe("term_search:query", .{ .overlay_item = bar.hit_query });
        try w.probe("term_search:regex", .{ .overlay_item = bar.hit_regex });
        try w.probe("term_search:case", .{ .overlay_item = bar.hit_case });
        app.closeFindBar(false);
        try app.forceClosePane(tid);
    } else |_| {}
    // A picker's row.
    command.run(app, .{ .static = .@"picker.files" }) catch {};
    if (app.overlay == .picker) {
        try w.probe("overlay_item:picker:files", .{ .overlay_item = 0 });
        w.closeOverlay();
    }
    command.run(app, .{ .static = .palette }) catch {};
    if (app.overlay == .picker) {
        try w.probe("overlay_item:picker:commands", .{ .overlay_item = 0 });
        w.closeOverlay();
    }
}

fn walkMenus(w: *Walk) Allocator.Error!void {
    const app = w.app;
    const cm = context_menus;
    const Opener = struct { name: []const u8, open: *const fn (*App) Allocator.Error!void };
    const Fns = struct {
        fn editor(a: *App) Allocator.Error!void {
            return cm.openEditorMenu(a, 5, 5);
        }
        fn gutter(a: *App) Allocator.Error!void {
            return cm.openGutterMenu(a, 5, 5);
        }
        fn mode(a: *App) Allocator.Error!void {
            return cm.openModeMenu(a, 5, 5);
        }
        fn stress(a: *App) Allocator.Error!void {
            return cm.openStressMenu(a, 5, 5);
        }
        fn branch(a: *App) Allocator.Error!void {
            return cm.openBranchMenu(a, 5, 5);
        }
        fn diagnostics(a: *App) Allocator.Error!void {
            return cm.openDiagnosticsMenu(a, 5, 5);
        }
        fn fileChip(a: *App) Allocator.Error!void {
            return cm.openFileChipMenu(a, 5, 5);
        }
        fn bell(a: *App) Allocator.Error!void {
            return cm.openBellMenu(a, 5, 5);
        }
        fn sidebarMode(a: *App) Allocator.Error!void {
            return cm.openSidebarModeMenu(a, 5, 5);
        }
        fn gear(a: *App) Allocator.Error!void {
            return cm.openGearMenu(a, 5, 5);
        }
        fn addPanel(a: *App) Allocator.Error!void {
            return cm.openAddPanelMenu(a, 5, 5);
        }
        fn newTab(a: *App) Allocator.Error!void {
            return cm.openNewTabMenu(a, 5, 5);
        }
        fn workspaceChip(a: *App) Allocator.Error!void {
            return cm.openWorkspaceChipMenu(a, 5, 5);
        }
        fn pr(a: *App) Allocator.Error!void {
            return cm.openPrMenu(a, 5, 5);
        }
        fn language(a: *App) Allocator.Error!void {
            return cm.openLanguageMenu(a, 5, 5);
        }
        fn position(a: *App) Allocator.Error!void {
            return cm.openPositionMenu(a, 5, 5);
        }
        fn find(a: *App) Allocator.Error!void {
            return cm.openFindMenu(a, 5, 5);
        }
        fn sel(a: *App) Allocator.Error!void {
            return cm.openSelMenu(a, 5, 5);
        }
        fn size(a: *App) Allocator.Error!void {
            return cm.openSizeMenu(a, 5, 5);
        }
        fn wrap(a: *App) Allocator.Error!void {
            return cm.openWrapMenu(a, 5, 5);
        }
        fn tests(a: *App) Allocator.Error!void {
            return cm.openTestMenu(a, 5, 5);
        }
        fn aiClaude(a: *App) Allocator.Error!void {
            return cm.openAiChipMenu(a, false, 5, 5);
        }
        fn aiCodex(a: *App) Allocator.Error!void {
            return cm.openAiChipMenu(a, true, 5, 5);
        }
        fn symbol(a: *App) Allocator.Error!void {
            return cm.openSymbolMenu(a, 5, 5);
        }
        fn transfer(a: *App) Allocator.Error!void {
            return cm.openTransferMenu(a, 5, 5);
        }
        fn workspaceHeader(a: *App) Allocator.Error!void {
            return cm.openWorkspaceHeaderMenu(a, 0, 5, 5);
        }
        fn aiPane(a: *App) Allocator.Error!void {
            return cm.openAiPaneMenu(a, 5, 5);
        }
        fn theme(a: *App) Allocator.Error!void {
            return cm.openThemeMenu(a, 5, 5);
        }
        fn menuBarPin(a: *App) Allocator.Error!void {
            return cm.openMenuBarPinMenu(a, 5, 5);
        }
        fn kebab(a: *App) Allocator.Error!void {
            return info_view.openKebabMenu(a, 5, 5);
        }
        fn dock(a: *App) Allocator.Error!void {
            return launcher_dock.openDockMenu(a, 5, 5);
        }
        fn ghost(a: *App) Allocator.Error!void {
            return ghost_chip.openMenu(a, 5, 5);
        }
        fn clock(a: *App) Allocator.Error!void {
            return clock_mod.openMenu(a, 5, 5);
        }
        fn coverageMode(a: *App) Allocator.Error!void {
            return coverage.openModeMenu(a, 5, 5);
        }
        fn nowPlaying(a: *App) Allocator.Error!void {
            return now_playing.openMenu(a, 5, 5);
        }
        fn lspChip(a: *App) Allocator.Error!void {
            return statusline_app.openLspChipMenu(a, 5, 5);
        }
        fn link(a: *App) Allocator.Error!void {
            return cm.openLinkMenu(a, "https://example.com/", 5, 5);
        }
        fn breadcrumb(a: *App) Allocator.Error!void {
            return cm.openBreadcrumbMenu(a, "src", 5, 5);
        }
        fn welcomeRecent(a: *App) Allocator.Error!void {
            return cm.openWelcomeRecentMenu(a, "README.md", 5, 5);
        }
        fn toast(a: *App) Allocator.Error!void {
            a.toast("audit toast", .{});
            return cm.openToastMenu(a, 0, 5, 5);
        }
        fn tree(a: *App) Allocator.Error!void {
            return cm.openTreeMenu(a, 0, 5, 5);
        }
        fn usagePane(a: *App) Allocator.Error!void {
            return usage_pane.openPaneMenu(a, 5, 5);
        }
        fn usageAccount(a: *App) Allocator.Error!void {
            return usage_pane.openAccountMenu(a, "work", 5, 5);
        }
        fn sessionChanges(a: *App) Allocator.Error!void {
            return @import("session_changes.zig").openRowMenu(a, 5, 5);
        }
    };
    const openers = [_]Opener{
        .{ .name = "editor", .open = &Fns.editor },
        .{ .name = "gutter", .open = &Fns.gutter },
        .{ .name = "mode", .open = &Fns.mode },
        .{ .name = "stress", .open = &Fns.stress },
        .{ .name = "branch", .open = &Fns.branch },
        .{ .name = "diagnostics", .open = &Fns.diagnostics },
        .{ .name = "file_chip", .open = &Fns.fileChip },
        .{ .name = "bell", .open = &Fns.bell },
        .{ .name = "sidebar_mode", .open = &Fns.sidebarMode },
        .{ .name = "gear", .open = &Fns.gear },
        .{ .name = "add_panel", .open = &Fns.addPanel },
        .{ .name = "new_tab", .open = &Fns.newTab },
        .{ .name = "workspace_chip", .open = &Fns.workspaceChip },
        .{ .name = "pr", .open = &Fns.pr },
        .{ .name = "language", .open = &Fns.language },
        .{ .name = "position", .open = &Fns.position },
        .{ .name = "find", .open = &Fns.find },
        .{ .name = "sel", .open = &Fns.sel },
        .{ .name = "size", .open = &Fns.size },
        .{ .name = "wrap", .open = &Fns.wrap },
        .{ .name = "tests", .open = &Fns.tests },
        .{ .name = "ai_claude_chip", .open = &Fns.aiClaude },
        .{ .name = "ai_codex_chip", .open = &Fns.aiCodex },
        .{ .name = "symbol", .open = &Fns.symbol },
        .{ .name = "transfer", .open = &Fns.transfer },
        .{ .name = "workspace_header", .open = &Fns.workspaceHeader },
        .{ .name = "ai_pane", .open = &Fns.aiPane },
        .{ .name = "theme", .open = &Fns.theme },
        .{ .name = "menu_bar_pin", .open = &Fns.menuBarPin },
        .{ .name = "info_view_kebab", .open = &Fns.kebab },
        .{ .name = "launcher_dock", .open = &Fns.dock },
        .{ .name = "ghost", .open = &Fns.ghost },
        .{ .name = "clock", .open = &Fns.clock },
        .{ .name = "coverage", .open = &Fns.coverageMode },
        .{ .name = "now_playing", .open = &Fns.nowPlaying },
        .{ .name = "lsp_chip", .open = &Fns.lspChip },
        .{ .name = "link", .open = &Fns.link },
        .{ .name = "breadcrumb", .open = &Fns.breadcrumb },
        .{ .name = "welcome_recent", .open = &Fns.welcomeRecent },
        .{ .name = "toast", .open = &Fns.toast },
        .{ .name = "tree_row", .open = &Fns.tree },
        .{ .name = "usage_pane", .open = &Fns.usagePane },
        .{ .name = "usage_account", .open = &Fns.usageAccount },
        .{ .name = "session_changes", .open = &Fns.sessionChanges },
    };
    for (openers) |o| {
        w.closeOverlay();
        o.open(app) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        try w.menuRows(o.name);
    }
    // The rail's menu, per section.
    inline for (comptime std.enums.values(rail_ui.Section)) |s| {
        w.closeOverlay();
        try cm.openRailMenu(app, s, 5, 5);
        try w.menuRows("rail:" ++ @tagName(s));
    }
    // The chrome's button menus.
    const buttons = [_]Button{ .toggle_tree, .toggle_right_panel, .right_tab, .right_new, .back, .forward, .dropdown, .tabs_label, .theme_toggle, .window_close, .split_term, .split_right, .split_down, .split_max, .ai_claude, .ai_codex, .menu_bar_pin, .edge_grip_menu_bar, .edge_grip_sidebar_left, .edge_grip_dock };
    for (buttons) |b| {
        w.closeOverlay();
        _ = try cm.openButtonMenu(app, @intFromEnum(b), 5, 5);
        try w.menuRows(try w.fmtKey("button:{s}", .{@tagName(b)}));
    }
    // The menu bar's words: the right-click menu on a word, then the
    // dropdown itself with every row.
    inline for (comptime std.enums.values(menu_bar.Menu)) |m| {
        w.closeOverlay();
        _ = try cm.openButtonMenu(app, menu_bar.button_base + @intFromEnum(m), 5, 5);
        try w.menuRows("menu_bar_word:" ++ @tagName(m));
        w.closeOverlay();
        try menu_bar.open(app, m, 5, 5, false);
        try w.menuRows("menu_bar:" ++ @tagName(m));
    }
    w.closeOverlay();
    _ = try cm.openButtonMenu(app, Button.tabPage(0), 5, 5);
    try w.menuRows("button:tab_page");
    // The tab menu of the active pane.
    if (app.active) |id| {
        w.closeOverlay();
        try cm.openTabMenu(app, id, 5, 5);
        try w.menuRows("tab");
    }
    w.closeOverlay();
}

// ─── the tally ──────────────────────────────────────────────────────────

fn tally(arena: Allocator, results: []const Result, lint: []const copy.Problem, todo: []const u8) Allocator.Error!Report {
    var todo_set: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, todo, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try todo_set.put(arena, line, {});
    }
    var uncovered: std.StringHashMapUnmanaged(void) = .empty;
    var new_uncovered: std.ArrayListUnmanaged([]const u8) = .empty;
    var curated: usize = 0;
    var fallback: usize = 0;
    var none: usize = 0;
    for (results) |r| {
        switch (r.res) {
            .curated => curated += 1,
            .fallback => fallback += 1,
            .none => none += 1,
        }
        if (r.res != .curated) {
            if (uncovered.contains(r.key)) continue;
            try uncovered.put(arena, r.key, {});
            if (!todo_set.contains(r.key)) try new_uncovered.append(arena, r.key);
        }
    }
    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = todo_set.keyIterator();
    while (it.next()) |k| if (!uncovered.contains(k.*)) try stale.append(arena, k.*);
    std.mem.sort([]const u8, new_uncovered.items, {}, lessThan);
    std.mem.sort([]const u8, stale.items, {}, lessThan);
    return .{
        .results = results,
        .lint = lint,
        .new_uncovered = new_uncovered.items,
        .stale = stale.items,
        .curated = curated,
        .fallback = fallback,
        .none = none,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The uncovered keys, sorted and unique — the todo file's content.
pub fn uncoveredKeys(arena: Allocator, r: Report) Allocator.Error![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (r.results) |res| if (res.res != .curated and !seen.contains(res.key)) {
        try seen.put(arena, res.key, {});
        try out.append(arena, res.key);
    };
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

// ─── the CLI ────────────────────────────────────────────────────────────

/// `mnml-zig hover-audit [--strict] [--quiet] [--write-todo PATH]`.
pub fn main(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var strict = false;
    var quiet = false;
    var write_todo: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--write-todo")) {
            i += 1;
            if (i >= argv.len) {
                try w.writeAll("hover-audit: --write-todo needs a path\n");
                return 2;
            }
            write_todo = argv[i];
        } else {
            try w.print("hover-audit: unknown argument {s}\nusage: mnml hover-audit [--strict] [--quiet] [--write-todo PATH]\n", .{a});
            return 2;
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scratch = try scratchWorkspace(arena, io, env);
    defer Io.Dir.cwd().deleteTree(io, scratch.root) catch {};
    const report = try run(gpa, io, arena, scratch.workspace, scratch.data_root, todo_text);
    if (!quiet) {
        try w.writeAll("hover-audit: target → resolution (curated | fallback | none)\n");
        for (report.results) |r| try w.print("  {s: <9} {s}{s}{s}\n", .{ @tagName(r.res), r.key, if (r.title.len > 0) "  —  " else "", r.title });
    }
    const uncovered = try uncoveredKeys(arena, report);
    try w.print("\nhover-audit: {d} targets — {d} curated, {d} fallback, {d} none; {d} distinct uncovered, {d} of them listed in docs/hover-help-todo.txt\n", .{ report.results.len, report.curated, report.fallback, report.none, uncovered.len, uncovered.len - report.new_uncovered.len });
    if (report.lint.len > 0) {
        try w.print("\n{d} lint problem(s) in curated entries:\n", .{report.lint.len});
        for (report.lint) |p| try w.print("  {s}: {s}\n", .{ p.entry, p.what });
    }
    if (report.stale.len > 0) {
        try w.print("\n{d} stale line(s) in docs/hover-help-todo.txt — covered now, delete them:\n", .{report.stale.len});
        for (report.stale) |k| try w.print("  {s}\n", .{k});
    }
    if (report.new_uncovered.len > 0) {
        try w.print("\n{d} NEW uncovered target(s) — write an entry in src/app/info_view_copy/, or add the key to docs/hover-help-todo.txt with a reason:\n", .{report.new_uncovered.len});
        for (report.new_uncovered) |k| try w.print("  {s}\n", .{k});
    }
    if (write_todo) |path| {
        var aw: Io.Writer.Allocating = .init(arena);
        try aw.writer.writeAll("# docs/hover-help-todo.txt — hover-help targets with no curated entry yet.\n# One key per line, as `mnml-zig hover-audit` prints them. The audit fails on an\n# uncovered target that is NOT listed here, and reports a listed one that is\n# covered now (delete the line). Regenerate: mnml-zig hover-audit --write-todo docs/hover-help-todo.txt\n");
        for (try uncoveredKeys(arena, report)) |k| try aw.writer.print("{s}\n", .{k});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
        try w.print("\nwrote {s}\n", .{path});
    }
    return if (strict and !report.ok()) 1 else 0;
}

const Scratch = struct { root: []const u8, workspace: []const u8, data_root: []const u8 };

/// A throwaway workspace under TMPDIR with the files the walk expects,
/// and a data root beside it so nothing reaches the real config.
fn scratchWorkspace(arena: Allocator, io: Io, env: *std.process.Environ.Map) !Scratch {
    // `TMPDIR`, else Windows's `TEMP` / `TMP` — `/tmp` is no directory there.
    const tmp = os_path.tempDir(env, .native);
    const leaf = try std.fmt.allocPrint(arena, "mnml-hover-audit-{d}", .{Io.Timestamp.now(io, .awake).toMilliseconds()});
    const root = try std.fs.path.join(arena, &.{ tmp, leaf });
    const ws = try std.fs.path.join(arena, &.{ root, "ws" });
    const data_root = try std.fs.path.join(arena, &.{ root, "data" });
    try Io.Dir.cwd().createDirPath(io, ws);
    try Io.Dir.cwd().createDirPath(io, data_root);
    try populate(io, ws);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, ws, &buf);
    return .{ .root = root, .workspace = try arena.dupe(u8, buf[0..n]), .data_root = data_root };
}

/// The files the walk expects in a workspace.
pub fn populate(io: Io, ws: []const u8) !void {
    const dir = try Io.Dir.cwd().openDir(io, ws, .{});
    try dir.createDirPath(io, "src");
    try dir.writeFile(io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    try dir.writeFile(io, .{ .sub_path = "README.md", .data = "# demo\n" });
    try dir.writeFile(io, .{ .sub_path = "weird.xyz", .data = "?\n" });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the audit: no NEW uncovered target, no stale todo line, no lint problem — the required set is everything minus docs/hover-help-todo.txt" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const ws = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(ws);
    try populate(t.io, ws);
    const data_root = try std.fs.path.join(t.allocator, &.{ ws, ".data" });
    defer t.allocator.free(data_root);
    try tmp.dir.createDirPath(t.io, ".data");
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try run(t.allocator, t.io, arena, ws, data_root, todo_text);
    for (report.lint) |p| std.debug.print("hover-audit lint: {s}: {s}\n", .{ p.entry, p.what });
    for (report.new_uncovered) |k| std.debug.print("hover-audit: NEW uncovered target (write an entry or list it in docs/hover-help-todo.txt): {s}\n", .{k});
    for (report.stale) |k| std.debug.print("hover-audit: stale todo line (covered now — delete it): {s}\n", .{k});
    try t.expectEqual(@as(usize, 0), report.lint.len);
    try t.expectEqual(@as(usize, 0), report.new_uncovered.len);
    try t.expectEqual(@as(usize, 0), report.stale.len);
    // The walk is wide: hundreds of targets, most of them curated.
    try t.expect(report.results.len > 400);
    try t.expect(report.curated > report.fallback + report.none);
}

test "the tally can fail: an uncovered key outside the todo is NEW, a todo line that is covered is STALE" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = [_]Result{
        .{ .key = "a:curated", .res = .curated, .title = "A" },
        .{ .key = "b:fallback", .res = .fallback, .title = "" },
        .{ .key = "c:none", .res = .none, .title = "" },
    };
    const r = try tally(arena, &results, &.{}, "# comment\nb:fallback\na:curated\n");
    try t.expectEqual(@as(usize, 1), r.new_uncovered.len);
    try t.expectEqualStrings("c:none", r.new_uncovered[0]);
    try t.expectEqual(@as(usize, 1), r.stale.len);
    try t.expectEqualStrings("a:curated", r.stale[0]);
    try t.expect(!r.ok());
    const clean = try tally(arena, &results, &.{}, "b:fallback\nc:none\n");
    try t.expect(clean.ok());
    try t.expectEqual(@as(usize, 1), clean.curated);
}
