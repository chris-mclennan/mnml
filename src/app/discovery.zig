//! Discoverability: what every click target is, in words.
//!
//! `describe` turns a `HitTarget` — the frame's own record of what it
//! painted — into a one-line title and a detail line. Three things read
//! it: the hover tooltip near the pointer (`ui.hover_tooltip`), the
//! info box at the bottom of the left rail (`ui.hover_help`), and the
//! F1 click-discovery overlay, which tints every registered rect,
//! labels it with the hit's own label (`row:todos:3`), and explains the
//! next thing clicked instead of acting on it.
//!
//! The hover surfaces only wake on real pointer motion (`App.hover_live`,
//! set by a `.motion` / `.drag` report and cleared by a press), so a
//! scripted click never grows a box under itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const hit_mod = @import("../ui/hit.zig");
const HitTarget = hit_mod.HitTarget;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const tooltip = @import("../ui/tooltip.zig");
const statusline = @import("../ui/statusline.zig");
const toast_mod = @import("../ui/toast.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const render = @import("render.zig");
const md_preview = @import("md_preview.zig");
const integrations = @import("integrations.zig");
const command = @import("../core/command.zig");
const activity_bar = @import("activity_bar.zig");

pub const Tip = tooltip.Tip;

/// The words for `target`, or null for a target with nothing to say.
pub fn describe(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?Tip {
    const f = struct {
        fn fmt(a: Allocator, comptime s: []const u8, args: anytype) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(a, s, args);
        }
    };
    return switch (target) {
        .pane => |id| .{
            .title = try f.fmt(arena, "Pane: {s}", .{if (app.panes.get(id)) |p| p.title() else "?"}),
            .detail = "click focuses · right-click: the pane's menu",
        },
        .divider => .{ .title = "Divider", .detail = "drag to resize" },
        .tab_close => .{ .title = "Close tab", .detail = "click closes this pane" },
        .dock => |d| .{
            .title = try f.fmt(arena, "Dock widget {d}", .{d.id}),
            .detail = "click focuses · drag the header moves it · right-click: widget menu",
        },
        .tab => |tb| blk: {
            const layout = app.layouts.current();
            const lid = (try layout.leafAt(arena, tb.leaf)) orelse break :blk null;
            const leaf = layout.leaf(lid) orelse break :blk null;
            if (tb.idx >= leaf.tabs.items.len) break :blk null;
            const p = app.panes.get(leaf.tabs.items[tb.idx]) orelse break :blk null;
            break :blk .{
                .title = try f.fmt(arena, "Tab: {s}{s}", .{ p.title(), if (p.dirty()) " (unsaved)" else "" }),
                .detail = "click shows · middle-click closes · right-click: tab menu · drag to move",
            };
        },
        .row => |pr| .{
            .title = try f.fmt(arena, "{s} row {d}", .{ upper(arena, @tagName(pr.panel)), pr.idx + 1 }),
            .detail = "click selects · double-click / Enter opens · right-click: row menu",
        },
        .kebab => |pr| .{
            .title = try f.fmt(arena, "{s} row menu", .{upper(arena, @tagName(pr.panel))}),
            .detail = "click opens the row's actions",
        },
        .chip => |c| switch (c.kind) {
            .sort => .{ .title = "sort: chip", .detail = "click cycles the order · right-click lists every mode" },
            .refresh => .{ .title = "Refresh", .detail = "click rescans the panel" },
            .new => .{ .title = "New", .detail = "click creates an item in this panel" },
            .view => .{ .title = "view: chip", .detail = "click cycles the row style" },
        },
        .filter_input => |p| .{
            .title = try f.fmt(arena, "{s} filter", .{upper(arena, @tagName(p))}),
            .detail = "type to narrow the rows · Esc clears",
        },
        .scrollbar => .{ .title = "Scrollbar", .detail = "drag the thumb · wheel scrolls" },
        .button => |id| try describeButton(app, arena, id),
        .link => |l| .{ .title = try f.fmt(arena, "Link: {s}", .{l.url}), .detail = "click opens it" },
        .menu_item => |mi| blk: {
            if (app.overlay != .menu) break :blk .{ .title = "Menu row", .detail = null };
            const m = &app.overlay.menu;
            const items = if (mi.menu == 1 or mi.menu == 3) (if (m.sub) |s| s.items else break :blk null) else m.items;
            if (mi.idx >= items.len) break :blk null;
            const it = items[mi.idx];
            break :blk .{
                .title = try f.fmt(arena, "Menu: {s}", .{it.label}),
                .detail = switch (it.action) {
                    .command => |cmd| command.name(cmd),
                    else => if (it.submenu.len > 0) "opens more rows" else null,
                },
            };
        },
        .statusline_seg => |seg| try describeSegment(app, arena, seg),
        .tree_node => |idx| blk: {
            if (idx >= app.tree.rows.items.len) break :blk null;
            const row = app.tree.rows.items[idx];
            break :blk .{
                .title = try f.fmt(arena, "{s}{s}", .{ row.rel, if (row.is_dir) "/" else "" }),
                .detail = if (row.is_dir) "click expands · right-click: folder menu" else "click opens · right-click: file menu · drag to move",
            };
        },
        .script_hit => |sh| .{
            .title = try f.fmt(arena, "{s} item", .{if (app.panes.get(sh.pane)) |p| @tagName(std.meta.activeTag(p.*)) else "pane"}),
            .detail = "click selects · click again acts",
        },
        .editor_cell => |cell| .{
            .title = try f.fmt(arena, "Line {d}", .{cell.line + 1}),
            .detail = "click places the cursor · drag selects · right-click: editor menu",
        },
        .overlay_item => .{ .title = "Overlay item", .detail = "click chooses it" },
        .rail => |part| activity_bar.describe(part),
        .welcome => |row| switch (row.kind) {
            .recent => .{ .title = "Recent file", .detail = "click opens it" },
            .shortcut => .{ .title = "Shortcut", .detail = "click runs it" },
        },
    };
}

fn upper(arena: Allocator, s: []const u8) []const u8 {
    const out = arena.dupe(u8, s) catch return s;
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn describeButton(app: *App, arena: Allocator, id: u32) Allocator.Error!?Tip {
    if (id == md_preview.button_edit) return .{ .title = "Edit the markdown", .detail = "swaps the raw editor in (markdown.edit_raw)" };
    if (id == md_preview.button_preview) return .{ .title = "Preview the markdown", .detail = "opens the rendered preview (markdown.preview)" };
    if (id == toast_mod.undo_button) return .{
        .title = if (app.undo_chip) |u| try std.fmt.allocPrint(arena, "Undo: {s}", .{u.label}) else "Undo",
        .detail = "click puts it back · right-click drops the offer",
    };
    if (id >= toast_mod.button_base) return .{ .title = "Toast", .detail = "click dismisses · right-click: dismiss / copy / dismiss all" };
    if (id >= integrations_view.chip_base and id < integrations_view.chip_base + integrations_view.max_chips) {
        const list = try integrations.chips(app, arena);
        const i = id - integrations_view.chip_base;
        if (i < list.len) return .{
            .title = try std.fmt.allocPrint(arena, "{s}{s}", .{ list[i].tooltip, if (list[i].enabled) "" else " (disabled)" }),
            .detail = "click runs it · right-click: its menu",
        };
        return null;
    }
    if (render.Button.newTabLeaf(id) != null) return .{ .title = "+ New tab", .detail = "click opens a scratch buffer · right-click: the + menu (New / Open / Panels / Tools / Integrations)" };
    if (@import("menu_bar.zig").buttonOf(id)) |m| return .{ .title = try std.fmt.allocPrint(arena, "{s} menu", .{m.label()}), .detail = "click drops the menu" };
    return switch (@as(render.Button, @enumFromInt(id))) {
        .palette => .{ .title = "Command palette", .detail = "search files · run commands (ctrl+shift+p)" },
        .toggle_tree => .{ .title = "Left panel", .detail = "click toggles the file tree (ctrl+n)" },
        .toggle_right_panel => .{ .title = "Right panel", .detail = "click toggles it (ctrl+shift+b)" },
        .ai_claude => .{ .title = "Claude Code", .detail = "click opens the session (ai.claude_code)" },
        .ai_codex => .{ .title = "Codex", .detail = "click opens the session (ai.codex)" },
        .add_integration => .{ .title = "+ Add an integration", .detail = "click opens the Marketplace (integrations.show_marketplace)" },
        .stress => .{ .title = "Stress meter", .detail = "the statusline meter's copy · click toasts the numbers · right-click: its menu" },
        else => null,
    };
}

fn describeSegment(app: *App, arena: Allocator, seg: u32) Allocator.Error!?Tip {
    switch (seg) {
        statusline.seg_mode => return .{
            .title = try std.fmt.allocPrint(arena, "Mode — {s} keymap", .{@tagName(app.input_style)}),
            .detail = "click: toggle vim ⇄ standard · right-click: keymap menu",
        },
        statusline.seg_file => return .{ .title = "File", .detail = "right-click: copy the path" },
        statusline.seg_position => return .{ .title = "Position", .detail = "click: go to line" },
        statusline.seg_input_style => return .{ .title = "Input style", .detail = "click: toggle vim ⇄ standard · right-click: keymap menu" },
        statusline.seg_restricted => return .{
            .title = "RESTRICTED — this workspace's exec-bearing settings are off",
            .detail = "click reviews what it wants to run (workspace.review_trust)",
        },
        else => {},
    }
    const id = render.SegId.of(seg) orelse return null;
    return switch (id) {
        .branch => blk: {
            var detail: std.ArrayListUnmanaged(u8) = .empty;
            try detail.appendSlice(arena, "click: status pane · right-click: git menu");
            if (app.git.status) |s| {
                if (s.ahead > 0) try detail.print(arena, " · ↑{d} ahead", .{s.ahead});
                if (s.behind > 0) try detail.print(arena, " · ↓{d} behind", .{s.behind});
                const n = s.changeCount();
                if (n > 0) try detail.print(arena, " · ●{d} changed", .{n});
            }
            break :blk .{ .title = try std.fmt.allocPrint(arena, "Branch {s}", .{app.git.branchLabel() orelse "?"}), .detail = detail.items };
        },
        .diagnostics => .{ .title = "Diagnostics in this file", .detail = "click: the panel · right-click: next / previous / filter" },
        .ai_meter => .{ .title = "AI spend", .detail = "click: today's report" },
        .bell => blk: {
            const u = app.messages.unread();
            break :blk .{
                .title = if (u.err + u.warn == 0) "Messages — nothing unread" else try std.fmt.allocPrint(arena, "Messages — {d} unread ({d} errors)", .{ u.err + u.warn, u.err }),
                .detail = "click: the history · right-click: clear",
            };
        },
        .stress => blk: {
            const s = app.stress.stats() orelse break :blk .{ .title = "Frame time", .detail = "no frames sampled yet" };
            break :blk .{
                .title = try std.fmt.allocPrint(arena, "Frame time — p50 {d}.{d}ms · p95 {d}.{d}ms · max {d}.{d}ms · n={d}", .{
                    s.p50_us / 1000, (s.p50_us % 1000) / 100,
                    s.p95_us / 1000, (s.p95_us % 1000) / 100,
                    s.max_us / 1000, (s.max_us % 1000) / 100,
                    s.count,
                }),
                .detail = "click toasts the numbers · right-click: copy / reset / hide",
            };
        },
        .indent => .{ .title = try std.fmt.allocPrint(arena, "Indent — {d} columns per tab", .{app.cfg.editor.tab_width}), .detail = "click: set the tab width" },
        .encoding => .{ .title = "Encoding — utf-8", .detail = "the only encoding in this build" },
        .transfer => .{ .title = "File transfers", .detail = "progress of the running copies · right-click: cancel all" },
        .clock => .{ .title = "Clock", .detail = "local time (a Z is UTC) · click: local / UTC / hide" },
        .coverage => .{ .title = "Coverage", .detail = "feature (F) and code (C) coverage from the trends files · click toasts both · right-click picks the mode" },
        _ => null,
    };
}

// ─── the hover surfaces ─────────────────────────────────────────────────

/// The tip under the pointer, from the frame that is being painted (its
/// hits are complete by the time this runs). Null unless the pointer
/// really moved there.
pub fn hoverTip(app: *App, arena: Allocator) Allocator.Error!?Tip {
    if (!app.hover_live) return null;
    const h = app.hover orelse return null;
    const target = app.hits.at(h.x, h.y) orelse return null;
    return describe(app, arena, target);
}

/// The popup (`ui.hover_tooltip`), after everything else.
pub fn drawTooltip(app: *App, ui: Ui, screen: Rect) Allocator.Error!void {
    if (!app.cfg.ui.hover_tooltip or app.overlay == .info) return;
    const h = app.hover orelse return;
    const tip = (try hoverTip(app, ui.arena)) orelse return;
    tooltip.draw(ui, screen, h.x, h.y, tip);
}

/// The rail's info box (`ui.hover_help`): the tip from the previous
/// frame's hits, so the rail can reserve the rows before it paints.
pub fn drawHelpBox(ui: Ui, area: Rect, tip: Tip) void {
    tooltip.drawHelpBox(ui, area, tip);
}

// ─── the F1 overlay ─────────────────────────────────────────────────────

/// Every hit the frame registered, tinted and labelled; a title row on
/// top says what a click will do now.
pub fn drawOverlay(app: *App, ui: Ui, screen: Rect) void {
    const th = ui.theme;
    const tint = Theme.onBg(th.fg, th.match.bg);
    // Snapshot: painting labels registers nothing, but be explicit.
    const entries = app.hits.items.items;
    var labelled_editor: ?app_mod.PaneId = null;
    for (entries) |e| {
        const r = e.rect.intersect(screen);
        if (r.isEmpty()) continue;
        var yy = r.y;
        while (yy < r.bottom()) : (yy += 1) {
            var xx = r.x;
            while (xx < r.right()) : (xx += 1) {
                if (ui.canvas.screen.readCell(xx, yy)) |cell| {
                    var c = cell;
                    c.style.bg = th.match.bg;
                    ui.canvas.put(xx, yy, c);
                }
            }
        }
        // One label per editor, not one per visible line.
        if (e.target == .editor_cell) {
            if (labelled_editor) |seen| if (seen == e.target.editor_cell.pane) continue;
            labelled_editor = e.target.editor_cell.pane;
        }
        // The cell grid borrows the label's bytes: they must outlive
        // this loop, so they go on the frame arena, not the stack.
        var aw: std.Io.Writer.Allocating = .init(ui.arena);
        e.target.writeLabel(&aw.writer) catch continue;
        const label = aw.written();
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), tint);
    }
    const title = if (ui.ascii) " Click Discovery - every highlighted cell is a click target; click one to learn what it does - Esc closes " else " Click Discovery — every highlighted cell is a click target; click one to learn what it does · Esc closes ";
    const bar = Rect.init(screen.x, screen.y, screen.w, 1);
    ui.fill(bar, th.chip_active);
    _ = ui.putStr(bar.x, bar.y, bar.w, ui.clipStr(title, bar.w), Theme.onBg(th.chip_active, th.chip_active.bg));
}

/// A press while the overlay is up: explain the target under it.
pub fn explain(app: *App, target: ?HitTarget) Allocator.Error!void {
    const arena = app.frame.allocator();
    const tgt = target orelse {
        app.toast("nothing clickable there", .{});
        return;
    };
    const tip = (try describe(app, arena, tgt)) orelse {
        var buf: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        tgt.writeLabel(&w) catch {};
        app.toast("{s}", .{w.buffered()});
        return;
    };
    if (tip.detail) |d| app.toast("{s} — {s}", .{ tip.title, d }) else app.toast("{s}", .{tip.title});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "describe: every hit kind has words; the statusline ids each say what a click does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    try app.render();
    const arena = app.frame.allocator();
    const Tag = std.meta.Tag(HitTarget);
    var seen = std.enums.EnumSet(Tag).initEmpty();
    for (app.hits.items.items) |e| {
        const tip = try describe(&app, arena, e.target);
        try t.expect(tip != null);
        seen.insert(std.meta.activeTag(e.target));
    }
    try t.expect(seen.contains(.tab) and seen.contains(.statusline_seg) and seen.contains(.button) and seen.contains(.editor_cell) and seen.contains(.pane));
    const mode = (try describe(&app, arena, .{ .statusline_seg = statusline.seg_mode })).?;
    try t.expect(std.mem.indexOf(u8, mode.title, "standard") != null);
    try t.expect(std.mem.indexOf(u8, mode.detail.?, "toggle vim") != null);
    const restricted = (try describe(&app, arena, .{ .statusline_seg = statusline.seg_restricted })).?;
    try t.expect(std.mem.indexOf(u8, restricted.detail.?, "review_trust") != null);
    const indent = (try describe(&app, arena, .{ .statusline_seg = @intFromEnum(render.SegId.indent) })).?;
    try t.expect(std.mem.indexOf(u8, indent.title, "4 columns") != null);
    const stress = (try describe(&app, arena, .{ .statusline_seg = @intFromEnum(render.SegId.stress) })).?;
    try t.expect(std.mem.indexOf(u8, stress.title, "p95") != null);
    const tab = (try describe(&app, arena, .{ .tab = .{ .leaf = 0, .idx = 0 } })).?;
    try t.expect(std.mem.indexOf(u8, tab.title, "[scratch]") != null);
    try t.expect((try describe(&app, arena, .{ .tab = .{ .leaf = 0, .idx = 9 } })) == null);
    _ = id;
    const plus = (try describe(&app, arena, .{ .button = render.Button.newTab(0) })).?;
    try t.expect(std.mem.indexOf(u8, plus.detail.?, "Panels") != null);
}

test "F1: the overlay labels every hit and the next click explains instead of acting; Esc closes" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.render();
    var mode_rect: ?Rect = null;
    var n_hits: usize = 0;
    for (app.hits.items.items) |e| {
        n_hits += 1;
        if (e.target == .statusline_seg and e.target.statusline_seg == statusline.seg_mode) mode_rect = e.rect;
    }
    try t.expect(n_hits > 3);
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .info and app.overlay.info == .discovery);
    const text = try screenText(&app);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "Click Discovery") != null);
    // Every hit of the underlying frame is labelled with its own label.
    var labelled: usize = 0;
    for (app.hits.items.items) |e| {
        var buf: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try e.target.writeLabel(&w);
        const label = w.buffered();
        const shown = if (label.len > e.rect.w) label[0..@min(label.len, e.rect.w -| 1)] else label;
        if (e.target != .editor_cell and shown.len > 0 and std.mem.indexOf(u8, text, shown) != null) labelled += 1;
    }
    try t.expect(labelled >= 4);
    // A wide enough rect shows its whole label; a narrow one clips to
    // its width (the editor's per-run cells, the six-cell mode chip).
    try t.expect(std.mem.indexOf(u8, text, "tab:0:0") != null);
    try t.expect(std.mem.indexOf(u8, text, "edit…") != null);
    try t.expect(std.mem.indexOf(u8, text, "statu…") != null);
    // A click on the mode chip explains it and does not toggle the keymap.
    const style_before = app.input_style;
    try app.handle(.{ .mouse = .{ .x = mode_rect.?.x, .y = mode_rect.?.y, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
    try t.expectEqual(style_before, app.input_style);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "toggle vim") != null);
    // Esc closes it without a word.
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .info);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
}

test "hover: the popup and the rail's info box wake on motion over a chip, and only on motion" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24, .cfg = .{ .ui = .{ .hover_tooltip = true } } });
    defer app.deinit();
    _ = try app.openScratch();
    try app.render();
    var mode_rect: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .statusline_seg and e.target.statusline_seg == statusline.seg_mode) {
        mode_rect = e.rect;
    };
    // A press there is not a hover.
    try app.handle(.{ .mouse = .{ .x = mode_rect.?.x, .y = mode_rect.?.y, .kind = .press, .button = .middle } });
    const pressed = try screenText(&app);
    defer t.allocator.free(pressed);
    try t.expect(std.mem.indexOf(u8, pressed, "toggle vim") == null);
    // Motion is.
    try app.handle(.{ .mouse = .{ .x = mode_rect.?.x, .y = mode_rect.?.y, .kind = .motion } });
    try t.expect(app.hover_live);
    const hovered = try screenText(&app);
    defer t.allocator.free(hovered);
    try t.expect(std.mem.indexOf(u8, hovered, "toggle vim") != null);
    // The rail's box carries the same words (ui.hover_help is on by default).
    try t.expect(std.mem.indexOf(u8, hovered, "Mode") != null);
    // Off the chip: nothing.
    try app.handle(.{ .mouse = .{ .x = 50, .y = 5, .kind = .motion } });
    const away = try screenText(&app);
    defer t.allocator.free(away);
    try t.expect(std.mem.indexOf(u8, away, "toggle vim") == null);
}
