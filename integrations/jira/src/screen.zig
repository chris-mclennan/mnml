//! The pane's paint — an `App` onto an `sdk.Frame`, mnml's way: the caps
//! header with its chips, the tab strip with the `▌` marker, the toolbar
//! as ` key: value ` mode chips that wrap instead of clipping, the
//! filter pill, the column header, the status→ticket→PR→pipeline tree
//! or the kanban, the detail pane on the right, the overlays (pickers,
//! the transition picker, the detail modal, the JQL editor, the comment
//! box, the key sheet), and a last row that is the status plus a hint
//! row generated from the bindings — nothing hand-written that can
//! drift. Every row, chip, tab, picker entry and button registers the
//! rect it painted in the hit map in the same statement, so a click
//! lands on what the eye sees.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const app_mod = @import("app.zig");
const config = @import("config.zig");
const model = @import("model.zig");
const tree = @import("tree.zig");
const kanban = @import("kanban.zig");
const dispatch = @import("dispatch.zig");
const hit = @import("hit.zig");
const keymap = @import("keymap.zig");
const pickers = @import("pickers.zig");
const text = @import("text.zig");
const filters = @import("filters.zig");

const App = app_mod.App;
const Frame = sdk.Frame;
const Style = sdk.Style;
const Rect = hit.Rect;

/// What the host told us about the terminal.
pub const Ui = struct {
    ascii: bool = false,
    nerd: bool = true,

    pub fn glyph(u: Ui, nerd_g: []const u8, fallback: []const u8) []const u8 {
        return if (u.ascii or !u.nerd) fallback else nerd_g;
    }
};

// ─── the palette: index colours, straight to the terminal ────────────────

pub const accent: Style = .{ .fg = .{ .index = 6 }, .mods = .{ .bold = true } };
pub const accent_plain: Style = .{ .fg = .{ .index = 6 } };
pub const muted: Style = .{ .mods = .{ .dim = true } };
pub const bold: Style = .{ .mods = .{ .bold = true } };
pub const plain: Style = .{};
pub const chip_style: Style = .{ .mods = .{ .reverse = true } };
pub const chip_active: Style = .{ .fg = .{ .index = 6 }, .mods = .{ .reverse = true, .bold = true } };
pub const bulk: Style = .{ .fg = .{ .index = 5 }, .mods = .{ .bold = true } };
pub const ok_style: Style = .{ .fg = .{ .index = 2 } };
pub const warn_style: Style = .{ .fg = .{ .index = 3 } };
pub const err_style: Style = .{ .fg = .{ .index = 1 } };
pub const blue: Style = .{ .fg = .{ .index = 4 } };
pub const star: Style = .{ .fg = .{ .index = 3 }, .mods = .{ .bold = true } };
pub const border: Style = .{ .mods = .{ .dim = true } };

pub const marker_glyph = "\u{258c}";
pub const marker_ascii = ">";
pub const open_glyph = "\u{F47C}";
pub const closed_glyph = "\u{F460}";
pub const open_ascii = "v";
pub const closed_ascii = ">";
pub const refresh_nerd = "\u{eb37}";
pub const refresh_ascii = "\u{21ba}";
pub const search_nerd = "\u{F0349}";
pub const search_ascii = "/";
pub const placeholder_unfocused = "/ filter";
pub const placeholder_focused = "type to filter…";
pub const placeholder_focused_ascii = "type to filter...";

/// The rows the chrome takes above the body, computed once per paint.
pub const Layout = struct {
    header_y: u16 = 0,
    tabs_y: u16 = 1,
    toolbar_y: u16 = 2,
    toolbar_rows: u16 = 1,
    columns_y: ?u16 = null,
    body_y: u16 = 3,
    body_h: u16 = 0,
    /// The list's width (the detail pane starts here when open).
    list_w: u16 = 0,
    detail_x: ?u16 = null,
    status_y: u16 = 0,
};

pub const Painter = struct {
    f: *Frame,
    a: *App,
    arena: Allocator,
    ui: Ui,
    lay: Layout = .{},

    fn cols(p: *const Painter) u16 {
        return p.f.cols;
    }

    fn rows(p: *const Painter) u16 {
        return p.f.rows;
    }

    /// Text at `(x, y)`, clipped at `max_w`; the cells used.
    fn put(p: *Painter, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
        if (x >= p.cols() or y >= p.rows()) return 0;
        return p.f.text(x, y, max_w, s, style);
    }

    /// `s` fitted with an ellipsis into `max_w`.
    fn putFit(p: *Painter, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
        var buf: [512]u8 = undefined;
        return p.put(x, y, max_w, text.fit(&buf, s, max_w), style);
    }

    fn hitAdd(p: *Painter, r: Rect, target: hit.Target) Allocator.Error!void {
        if (r.w == 0 or r.h == 0) return;
        try p.a.hits.add(p.a.gpa, r, target);
    }

    fn marker(p: *const Painter) []const u8 {
        return if (p.ui.ascii) marker_ascii else marker_glyph;
    }

    fn chevron(p: *const Painter, open: bool) []const u8 {
        if (p.ui.ascii or !p.ui.nerd) return if (open) open_ascii else closed_ascii;
        return if (open) open_glyph else closed_glyph;
    }

    fn fmt(p: *Painter, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(p.arena, f, args) catch "";
    }

    // ─── the frame ───────────────────────────────────────────────────

    pub fn paint(p: *Painter) Allocator.Error!void {
        p.f.clear(.none);
        p.a.hits.reset();
        if (p.rows() == 0 or p.cols() == 0) return;
        p.lay.status_y = p.rows() - 1;
        if (!p.a.hasTabs()) {
            try p.paintEmptyScope();
            try p.paintStatus();
            return;
        }
        try p.paintHeader();
        try p.paintTabs();
        const t = p.a.tab();
        p.lay.list_w = p.cols();
        if (p.a.details_visible and p.cols() >= 60 and !t.cfg.isKanban()) {
            const dw = @max(@as(u16, 30), p.cols() * 2 / 5);
            p.lay.list_w = p.cols() - dw;
            p.lay.detail_x = p.lay.list_w;
        }
        p.lay.toolbar_rows = try p.paintToolbar();
        var y = p.lay.toolbar_y + p.lay.toolbar_rows;
        if (!t.cfg.isKanban()) {
            p.lay.columns_y = y;
            try p.paintColumns(y);
            y += 1;
        }
        p.lay.body_y = y;
        p.lay.body_h = p.lay.status_y -| y;
        if (t.cfg.isKanban()) try p.paintKanban() else try p.paintTree();
        if (p.lay.detail_x) |dx| try p.paintDetail(dx);
        try p.paintStatus();
        // The overlays, back to front: the last painted is on top.
        if (p.a.comment != null) try p.paintComment();
        if (p.a.jql != null) try p.paintJql();
        if (p.a.transition != null) try p.paintTransition();
        if (p.a.picker != null) try p.paintPicker();
        if (p.a.modal != null) try p.paintModal();
        if (p.a.help) try p.paintHelp();
    }

    fn paintEmptyScope(p: *Painter) Allocator.Error!void {
        const fam = if (p.a.family) |f| f.label() else "Jira";
        _ = p.put(1, 0, p.cols(), upperOf(p.arena, fam), accent);
        _ = p.put(1, 2, p.cols() -| 1, "No tabs for this scope.", bold);
        const cli = if (p.a.family) |f| f.cli() else "work";
        _ = p.putFit(1, 3, p.cols() -| 1, p.fmt("Add a `.tabs` entry whose kind belongs to `--only {s}` in the config, then press r.", .{cli}), muted);
        _ = p.putFit(1, 4, p.cols() -| 1, "Kinds: work_assigned · work_recently_done · work_recent · work_unified · filter · fix_version_tree · board_active_sprint · board_backlog.", muted);
        try p.hitAdd(.{ .x = 0, .y = 0, .w = p.cols(), .h = p.rows() -| 1 }, .help_body);
    }

    // ─── the header and the tabs ─────────────────────────────────────

    fn paintHeader(p: *Painter) Allocator.Error!void {
        const y = p.lay.header_y;
        const t = p.a.tab();
        const title = upperOf(p.arena, if (p.a.family) |f| f.label() else "Jira");
        var x: u16 = 1;
        x += p.put(x, y, p.cols() -| x, title, accent);
        var arena_mask = std.heap.ArenaAllocator.init(p.a.gpa);
        defer arena_mask.deinit();
        const shown = filters.countTrue(try p.a.mask(arena_mask.allocator(), t));
        const sub = if (t.fetched)
            (if (shown == t.issues.len) p.fmt(" ({d})", .{t.issues.len}) else p.fmt(" ({d} of {d})", .{ shown, t.issues.len }))
        else if (t.last_error.len > 0)
            " (error)"
        else
            " (loading…)";
        x += p.put(x, y, p.cols() -| x, sub, muted);
        if (p.a.selection.count() > 0) {
            x += p.put(x + 1, y, p.cols() -| (x + 1), p.fmt("{d} selected", .{p.a.selection.count()}), bulk) + 1;
        }
        // The right-end chips, dropped whole when they do not fit.
        const help_t = " ? ";
        const refresh_t = if (p.ui.ascii or !p.ui.nerd) " " ++ refresh_ascii ++ " " else " " ++ refresh_nerd ++ " ";
        const hw = text.width(help_t);
        const rw = text.width(refresh_t);
        var rx = p.cols();
        if (rx >= x + hw + rw + 3) {
            rx -= hw + 1;
            _ = p.put(rx, y, hw, help_t, chip_style);
            try p.hitAdd(.{ .x = rx, .y = y, .w = hw, .h = 1 }, .{ .chip = .help });
            rx -= rw + 1;
            _ = p.put(rx, y, rw, refresh_t, chip_style);
            try p.hitAdd(.{ .x = rx, .y = y, .w = rw, .h = 1 }, .{ .chip = .refresh });
        }
    }

    fn paintTabs(p: *Painter) Allocator.Error!void {
        const y = p.lay.tabs_y;
        var x: u16 = 0;
        for (p.a.tabs, 0..) |*t, i| {
            const is_active = i == p.a.active;
            const label = p.fmt("{d} {s}", .{ i + 1, t.cfg.name });
            const w = text.width(label) + 2;
            if (x + w > p.cols()) break;
            if (is_active) _ = p.put(x, y, 1, p.marker(), accent);
            _ = p.put(x + 1, y, w - 1, label, if (is_active) bold else muted);
            try p.hitAdd(.{ .x = x, .y = y, .w = w, .h = 1 }, .{ .tab = @intCast(i) });
            x += w + 1;
        }
    }

    // ─── the toolbar chips ───────────────────────────────────────────

    const ChipSpec = struct { text_: []const u8, target: hit.Chip, style: Style };

    fn chipList(p: *Painter) Allocator.Error![]const ChipSpec {
        const a = p.a;
        const t = a.tab();
        var out: std.ArrayList(ChipSpec) = .empty;
        const arena = p.arena;
        // The search pill: the filter's text, or the placeholder.
        const glyph = if (p.ui.ascii or !p.ui.nerd) search_ascii else search_nerd;
        const search_text = blk: {
            if (a.filter) |f| {
                if (f.editing) break :blk try std.fmt.allocPrint(arena, " {s} {s}▏", .{ glyph, if (f.edit.text().len > 0) f.edit.text() else (if (p.ui.ascii) placeholder_focused_ascii else placeholder_focused) });
                break :blk try std.fmt.allocPrint(arena, " {s} {s} ", .{ glyph, f.edit.text() });
            }
            break :blk try std.fmt.allocPrint(arena, " {s} {s} ", .{ glyph, placeholder_unfocused });
        };
        const search_style: Style = if (a.filter != null) chip_active else chip_style;
        if (t.cfg.isKanban()) {
            const board_name = if (t.board_id != 0) try a.boardName(t.board_id) else "default";
            try out.append(arena, .{ .text_ = try chipText(arena, "board", board_name), .target = .board, .style = chip_style });
            const sprint_name = blk: {
                if (t.selected_sprint) |id| if (t.sprints) |list| for (list) |s| if (s.id == id) break :blk s.name;
                if (t.cfg.kind == .board_backlog) break :blk "backlog";
                if (t.sprints) |list| for (list) |s| if (std.ascii.eqlIgnoreCase(s.state, "active")) break :blk s.name;
                break :blk "active";
            };
            try out.append(arena, .{ .text_ = try chipText(arena, "sprint", sprint_name), .target = .sprint, .style = chip_style });
            try out.append(arena, .{ .text_ = search_text, .target = .search, .style = search_style });
            // The avatar cluster is painted by paintToolbar itself.
            try out.append(arena, .{ .text_ = " version ", .target = .version, .style = chip_style });
            try out.append(arena, .{ .text_ = if (t.active_epics.count() > 0) try std.fmt.allocPrint(arena, " epic: {d} ", .{t.active_epics.count()}) else " epic ", .target = .epic, .style = if (t.active_epics.count() > 0) chip_active else chip_style });
            try out.append(arena, .{ .text_ = if (t.issue_type.len > 0) try chipText(arena, "type", t.issue_type) else " type ", .target = .type, .style = if (t.issue_type.len > 0) chip_active else chip_style });
            try out.append(arena, .{ .text_ = if (t.label.len > 0) try chipText(arena, "label", t.label) else " label ", .target = .label, .style = if (t.label.len > 0) chip_active else chip_style });
            if (t.team.len > 0) try out.append(arena, .{ .text_ = try chipText(arena, "team", t.team), .target = .overflow, .style = chip_active });
            const qf_n = t.active_quick_filters.items.len;
            try out.append(arena, .{ .text_ = if (qf_n > 0) try std.fmt.allocPrint(arena, " quick filters: {d} ", .{qf_n}) else " quick filters ", .target = .quick_filters, .style = if (qf_n > 0) chip_active else chip_style });
            const unassigned_on = t.active_assignees.contains(model.unassigned_sentinel);
            try out.append(arena, .{ .text_ = " unassigned ", .target = .unassigned, .style = if (unassigned_on) chip_active else chip_style });
            try out.append(arena, .{ .text_ = " settings ", .target = .settings, .style = chip_style });
            return out.toOwnedSlice(arena);
        }
        try out.append(arena, .{ .text_ = " basic ", .target = .basic, .style = if (!t.show_jql) chip_active else chip_style });
        try out.append(arena, .{ .text_ = " jql ", .target = .jql, .style = if (t.show_jql) chip_active else chip_style });
        try out.append(arena, .{ .text_ = search_text, .target = .search, .style = search_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "space", if (t.cfg.project.len > 0) t.cfg.project else "—"), .target = .space, .style = chip_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "assignee", try p.assigneeLabel(t)), .target = .assignee, .style = if (t.active_assignees.count() > 0) chip_active else chip_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "type", if (t.issue_type.len > 0) t.issue_type else "—"), .target = .type, .style = if (t.issue_type.len > 0) chip_active else chip_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "status", t.scope.label()), .target = .status, .style = if (t.scope != .all) chip_active else chip_style });
        if (t.cfg.isFixVersions()) {
            if (fixVersionOf(t.jql)) |v| {
                try out.append(arena, .{ .text_ = try chipText(arena, "fixVersion", v), .target = .fixv_pill, .style = chip_active });
                try out.append(arena, .{ .text_ = if (p.ui.ascii) " x " else " ⓧ ", .target = .fixv_remove, .style = chip_style });
            }
        }
        return out.toOwnedSlice(arena);
    }

    fn assigneeLabel(p: *Painter, t: *const app_mod.TabState) Allocator.Error![]const u8 {
        const n = t.active_assignees.count();
        if (n == 0) return "All";
        if (n == 1) {
            var it = t.active_assignees.keyIterator();
            const id = it.next().?.*;
            if (p.a.me) |me| if (std.mem.eql(u8, me.account_id, id)) return "Me";
            if (std.mem.eql(u8, id, model.unassigned_sentinel)) return "Unassigned";
            for (t.assignees) |s| if (std.mem.eql(u8, s.account_id, id)) return s.display_name;
            return "1";
        }
        return std.fmt.allocPrint(p.arena, "{d}", .{n});
    }

    /// The chips left to right with a one-cell gap, wrapping to the next
    /// row when the next one would clip; returns the rows used. On a
    /// kanban tab the avatar cluster sits after the search pill.
    fn paintToolbar(p: *Painter) Allocator.Error!u16 {
        const list = try p.chipList();
        const max_x = p.lay.list_w;
        var x: u16 = 1;
        var y = p.lay.toolbar_y;
        var used: u16 = 1;
        for (list) |c| {
            const w = text.width(c.text_);
            if (x + w > max_x and x > 1) {
                y += 1;
                used += 1;
                x = 1;
                if (y >= p.lay.status_y -| 2) break;
            }
            _ = p.put(x, y, max_x -| x, c.text_, c.style);
            try p.hitAdd(.{ .x = x, .y = y, .w = @min(w, max_x -| x), .h = 1 }, .{ .chip = c.target });
            x += w + 1;
            if (c.target == .search and p.a.tab().cfg.isKanban()) {
                const r = try p.paintAvatars(x, y, max_x);
                x = r.x;
                y = r.y;
                used = r.rows;
            }
        }
        return used;
    }

    const Cursor = struct { x: u16, y: u16, rows: u16 };

    /// `MG  LB  BS  [?]` — initials of the tab's assignees (me excluded),
    /// active ones lit; `[?]` opens the full list.
    fn paintAvatars(p: *Painter, x0: u16, y0: u16, max_x: u16) Allocator.Error!Cursor {
        const t = p.a.tab();
        var x = x0;
        var y = y0;
        var used: u16 = y0 - p.lay.toolbar_y + 1;
        const shown = @min(t.assignees.len, 6);
        for (t.assignees[0..shown], 0..) |s, i| {
            var buf: [8]u8 = undefined;
            const ini = initials(&buf, s.display_name);
            const w: u16 = @intCast(ini.len + 2);
            if (x + w > max_x) {
                y += 1;
                used += 1;
                x = 1;
            }
            const on = t.active_assignees.contains(s.account_id);
            _ = p.put(x, y, w, p.fmt(" {s} ", .{ini}), if (on) chip_active else chip_style);
            try p.hitAdd(.{ .x = x, .y = y, .w = w, .h = 1 }, .{ .avatar = @intCast(i) });
            x += w + 1;
        }
        const more = " [?] ";
        const mw = text.width(more);
        if (x + mw > max_x) {
            y += 1;
            used += 1;
            x = 1;
        }
        _ = p.put(x, y, mw, more, chip_style);
        try p.hitAdd(.{ .x = x, .y = y, .w = mw, .h = 1 }, .{ .chip = .overflow });
        x += mw + 1;
        return .{ .x = x, .y = y, .rows = used };
    }

    // ─── the columns and the tree ────────────────────────────────────

    const ColX = struct { col: config.Column, x: u16, w: u16 };

    /// Where each column starts at this width: the fixed ones from the
    /// config, shrunk together when they would eat the summary.
    fn columnLayout(p: *Painter) Allocator.Error![]const ColX {
        const set = p.a.tab().cfg.columnSet();
        var fixed: u32 = 0;
        for (set) |c| fixed += c.width() orelse 0;
        const avail: u32 = p.lay.list_w -| 2;
        // The summary keeps at least 20 cells; the fixed columns shrink
        // together for it, the date column no further than a date.
        const budget: u32 = avail -| 20;
        const scale_num: u32 = if (fixed > budget and fixed > 0) budget else fixed;
        var out: std.ArrayList(ColX) = .empty;
        var x: u16 = 2;
        for (set) |c| {
            const w: u16 = if (c.width()) |cw| blk: {
                const scaled: u32 = if (fixed > 0) cw * scale_num / fixed else cw;
                break :blk @intCast(@max(if (c == .updated) @as(u32, 11) else 6, scaled));
            } else @intCast(@max(1, avail -| (x - 2)));
            try out.append(p.arena, .{ .col = c, .x = x, .w = w });
            x += w;
        }
        return out.toOwnedSlice(p.arena);
    }

    fn paintColumns(p: *Painter, y: u16) Allocator.Error!void {
        for (try p.columnLayout()) |c| {
            const label: []const u8 = switch (c.col) {
                .key => "KEY",
                .status => "STATUS",
                .assignee => "ASSIGNEE",
                .reporter => "REPORTER",
                .priority => "PRIORITY",
                .type => "TYPE",
                .updated => "UPDATED",
                .fix_version => "FIX VERSION",
                .actions => "ACTIONS",
                .summary => "SUMMARY",
            };
            _ = p.put(c.x, y, @min(c.w, p.lay.list_w -| c.x), label, .{ .mods = .{ .dim = true, .bold = true } });
        }
    }

    fn colOf(layout: []const ColX, which: config.Column) ?ColX {
        for (layout) |c| if (c.col == which) return c;
        return null;
    }

    fn paintTree(p: *Painter) Allocator.Error!void {
        const a = p.a;
        const t = a.tab();
        const y0 = p.lay.body_y;
        const h = p.lay.body_h;
        const w = p.lay.list_w;
        if (h == 0) return;
        if (t.last_error.len > 0 and t.issues.len == 0) {
            _ = p.putFit(2, y0, w -| 2, p.fmt("error: {s}", .{t.last_error}), err_style);
            _ = p.putFit(2, y0 + 1, w -| 2, "press r to try again", muted);
            return;
        }
        if (!t.fetched) {
            _ = p.put(2, y0, w -| 2, "loading…", muted);
            return;
        }
        const r = (try a.treeRows(p.arena)) orelse return;
        if (r.rows.len == 0) {
            _ = p.put(2, y0, w -| 2, if (t.issues.len == 0) "no tickets" else "no tickets match the filter", muted);
            return;
        }
        // Keep the cursor on screen.
        if (t.selected < t.scroll) t.scroll = t.selected;
        if (t.selected >= t.scroll + h) t.scroll = t.selected + 1 - h;
        if (t.scroll + h > r.rows.len) t.scroll = r.rows.len -| h;
        const layout = try p.columnLayout();
        const key_c = colOf(layout, .key) orelse ColX{ .col = .key, .x = 2, .w = 18 };
        const sum_c = colOf(layout, .summary) orelse ColX{ .col = .summary, .x = 2 + 18, .w = w -| 20 };
        var i = t.scroll;
        var y = y0;
        while (i < r.rows.len and y < y0 + h) : ({
            i += 1;
            y += 1;
        }) {
            const row = r.rows[i];
            const is_cur = i == t.selected;
            const idx: u32 = @intCast(i);
            const base: Style = if (is_cur) bold else plain;
            if (is_cur) _ = p.put(0, y, 1, p.marker(), accent);
            try p.hitAdd(.{ .x = 0, .y = y, .w = w, .h = 1 }, .{ .row = idx });
            switch (row) {
                .group => |g| {
                    const chev = p.chevron(g.expanded);
                    _ = p.put(1, y, 2, chev, accent_plain);
                    try p.hitAdd(.{ .x = 1, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    const name = if (std.mem.eql(u8, g.status, tree.top_sentinel)) "Release cut" else g.status;
                    _ = p.putFit(3, y, w -| 3, p.fmt("{s} ({d})", .{ name, g.count }), if (is_cur) accent else bold);
                },
                .ticket => |tk| {
                    const iss = t.issues[tk.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key);
                    const expanded = st.isExpanded(iss.key);
                    // No chevron once the PRs are known to be none.
                    const show_chev = !(expanded and prs != null and prs.?.len == 0 and false) and (prs == null or prs.?.len > 0 or !expanded);
                    if (show_chev and !(prs != null and prs.?.len == 0)) {
                        _ = p.put(key_c.x + 2, y, 2, p.chevron(expanded), accent_plain);
                        try p.hitAdd(.{ .x = key_c.x + 2, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    }
                    const selected_bulk = a.isSelected(iss.key);
                    var kx = key_c.x + 4;
                    const key_style: Style = if (selected_bulk) bulk else if (is_cur) accent else accent_plain;
                    kx += p.putFit(kx, y, key_c.w -| 6, iss.key, key_style);
                    if (tk.bumped) kx += p.put(kx + 1, y, 2, if (p.ui.ascii) "*" else "★", star) + 1;
                    if (selected_bulk) _ = p.put(kx + 1, y, 2, if (p.ui.ascii) "+" else "✓", bulk);
                    for (layout) |c| switch (c.col) {
                        .key, .summary => {},
                        .status => _ = p.putFit(c.x, y, c.w -| 1, tk.effective_status, statusStyle(iss, base)),
                        .assignee => _ = p.putFit(c.x, y, c.w -| 1, iss.assigneeName(), base),
                        .reporter => _ = p.putFit(c.x, y, c.w -| 1, iss.reporterName(), base),
                        .priority => _ = p.putFit(c.x, y, c.w -| 1, iss.priority, base),
                        .type => _ = p.putFit(c.x, y, c.w -| 1, iss.issuetype, base),
                        .updated => _ = p.putFit(c.x, y, c.w -| 1, iss.updatedDay(), base),
                        .fix_version => _ = p.putFit(c.x, y, c.w -| 1, if (iss.fix_versions.len > 0) iss.fix_versions[0] else "—", base),
                        .actions => try p.paintActions(c.x, y, c.w -| 1, tk.issue_idx, iss),
                    };
                    // The summary, with the action buttons after it when
                    // there is no actions column and they fit.
                    const has_actions_col = colOf(layout, .actions) != null;
                    var sw = @min(sum_c.w, w -| sum_c.x);
                    if (!has_actions_col) {
                        const buttons = dispatch.buttonsForTicket(iss);
                        var bw: u16 = 0;
                        for (buttons) |b| bw += text.width(b.label()) + 1;
                        if (buttons.len > 0 and sw > bw + 12) {
                            sw -= bw;
                            try p.paintActions(sum_c.x + sw, y, bw, tk.issue_idx, iss);
                        }
                    }
                    _ = p.putFit(sum_c.x, y, sw -| 1, iss.summary, base);
                },
                .pr => |pr_ref| {
                    const iss = t.issues[pr_ref.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    if (pr_ref.pr_idx >= prs.len) continue;
                    const pr = prs[pr_ref.pr_idx];
                    const cx = key_c.x + 6;
                    if (pr.isMerged()) {
                        _ = p.put(cx, y, 2, p.chevron(st.isPrExpanded(iss.key, pr.id)), accent_plain);
                        try p.hitAdd(.{ .x = cx, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    }
                    _ = p.putFit(cx + 2, y, key_c.w -| 8, pr.status, prStyle(pr.status));
                    // The reference's chips at the right end of the summary:
                    // `[ Review ] [ Merge ] [ Open ]` on an open PR, `[ Open ]`
                    // on a merged or declined one — here every one a hit.
                    const Btn = struct { label: []const u8, which: hit.PrButton };
                    const open_set = [_]Btn{ .{ .label = "[ Review ]", .which = .review }, .{ .label = "[ Merge ]", .which = .merge }, .{ .label = "[ Open ]", .which = .open } };
                    const closed_set = [_]Btn{.{ .label = "[ Open ]", .which = .open }};
                    const set: []const Btn = if (pr.isOpen()) &open_set else &closed_set;
                    var bw: u16 = 0;
                    for (set) |b| bw += text.width(b.label) + 1;
                    var sw = @min(sum_c.w, w -| sum_c.x);
                    if (sw > bw + 12) {
                        sw -= bw;
                        var bx = sum_c.x + sw;
                        for (set) |b| {
                            const lw = text.width(b.label);
                            _ = p.put(bx, y, lw, b.label, chip_style);
                            try p.hitAdd(.{ .x = bx, .y = y, .w = lw, .h = 1 }, .{ .pr_button = .{ .row = idx, .which = b.which } });
                            bx += lw + 1;
                        }
                    }
                    const title = if (pr.name.len > 0) pr.name else pr.url;
                    _ = p.putFit(sum_c.x, y, sw -| 1, title, base);
                },
                .pr_loading => _ = p.put(key_c.x + 6, y, w -| (key_c.x + 6), "… fetching linked PRs", muted),
                .pipeline_loading => _ = p.put(key_c.x + 10, y, w -| (key_c.x + 10), "→ fetching pipelines…", muted),
                .pipeline_empty => _ = p.put(key_c.x + 10, y, w -| (key_c.x + 10), "→ no pipelines on the merge commit", muted),
                .pipeline_error => |pe| {
                    const iss = t.issues[pe.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    const why = if (pe.pr_idx < prs.len) st.pipelineError(iss.key, prs[pe.pr_idx].id) orelse "?" else "?";
                    _ = p.putFit(key_c.x + 10, y, w -| (key_c.x + 10), p.fmt("→ {s}", .{why}), warn_style);
                },
                .pipeline => |pl| {
                    const iss = t.issues[pl.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    if (pl.pr_idx >= prs.len) continue;
                    const list = st.pipelines(iss.key, prs[pl.pr_idx].id) orelse continue;
                    if (pl.pipeline_idx >= list.len) continue;
                    const pipe = list[pl.pipeline_idx];
                    var dbuf: [32]u8 = undefined;
                    const line = p.fmt("→ #{d} {s}  {s}  {s}  {s}", .{ pipe.build_number, pipe.stateLabel(), pipe.branchLabel(), pipe.createdDate(), pipe.durationLabel(&dbuf) });
                    _ = p.putFit(key_c.x + 10, y, w -| (key_c.x + 10), line, pipelineStyle(pipe));
                },
                .show_more => |sm| {
                    _ = p.put(key_c.x + 6, y, 2, if (p.ui.ascii) "..." else "⋯", muted);
                    const label = p.fmt("Show all {d} PRs ↴", .{sm.hidden});
                    _ = p.putFit(sum_c.x, y, sum_c.w -| 1, label, if (is_cur) accent else accent_plain);
                    try p.hitAdd(.{ .x = 0, .y = y, .w = w, .h = 1 }, .{ .show_more = idx });
                },
            }
        }
    }

    fn paintActions(p: *Painter, x0: u16, y: u16, max_w: u16, issue_idx: usize, iss: model.Issue) Allocator.Error!void {
        var x = x0;
        for (dispatch.buttonsForTicket(iss), 0..) |b, bi| {
            const lw = text.width(b.label());
            if (x + lw > x0 + max_w) break;
            _ = p.put(x, y, lw, b.label(), chip_style);
            try p.hitAdd(.{ .x = x, .y = y, .w = lw, .h = 1 }, .{ .action = .{ .issue = @intCast(issue_idx), .button = @intCast(bi) } });
            x += lw + 1;
        }
    }

    // ─── the kanban ──────────────────────────────────────────────────

    fn paintKanban(p: *Painter) Allocator.Error!void {
        const a = p.a;
        const t = a.tab();
        const y0 = p.lay.body_y;
        const h = p.lay.body_h;
        const w = p.lay.list_w;
        if (h < 3 or w < 12) return;
        if (t.last_error.len > 0 and t.issues.len == 0) {
            _ = p.putFit(2, y0, w -| 2, p.fmt("error: {s}", .{t.last_error}), err_style);
            _ = p.putFit(2, y0 + 1, w -| 2, "press r to try again", muted);
            return;
        }
        if (!t.fetched) {
            _ = p.put(2, y0, w -| 2, "loading…", muted);
            return;
        }
        const m = try a.mask(p.arena, t);
        const buckets = try kanban.bucket(p.arena, t.issues, m);
        const col_w: u16 = w / kanban.count;
        var c: usize = 0;
        while (c < kanban.count) : (c += 1) {
            const cx: u16 = @intCast(c * col_w);
            const inner_w = col_w -| 2;
            const col: kanban.Col = @enumFromInt(c);
            try p.box(.{ .x = cx, .y = y0, .w = col_w, .h = h }, p.fmt(" {s} ({d}) ", .{ col.title(), buckets[c].len }), border);
            try p.hitAdd(.{ .x = cx, .y = y0, .w = col_w, .h = h }, .{ .column = @intCast(c) });
            // The lines of every card, then the window the scroll shows.
            var lines: std.ArrayList(struct { issue: usize, line: kanban.CardLine, first: bool }) = .empty;
            for (buckets[c]) |idx| {
                const iss = t.issues[idx];
                const card = try kanban.layoutCard(p.arena, idx, iss, a.isCardExpanded(iss.key), inner_w);
                for (card.lines, 0..) |ln, li| try lines.append(p.arena, .{ .issue = idx, .line = ln, .first = li == 0 });
            }
            // Keep the cursor's card on screen in its column.
            const inner_h = h -| 2;
            if (t.selected < t.issues.len and kanban.colOf(t.issues, t.selected) == col) {
                var head_line: usize = 0;
                for (lines.items, 0..) |ln, li| if (ln.issue == t.selected and ln.first) {
                    head_line = li;
                };
                if (head_line < a.kanban_scroll[c]) a.kanban_scroll[c] = @intCast(head_line);
                if (head_line >= a.kanban_scroll[c] + inner_h) a.kanban_scroll[c] = @intCast(head_line + 1 -| inner_h);
            }
            if (a.kanban_scroll[c] > lines.items.len -| inner_h) a.kanban_scroll[c] = @intCast(lines.items.len -| inner_h);
            var li: usize = a.kanban_scroll[c];
            var y = y0 + 1;
            while (li < lines.items.len and y < y0 + h - 1) : ({
                li += 1;
                y += 1;
            }) {
                const ln = lines.items[li];
                const iss = t.issues[ln.issue];
                const is_cur = ln.issue == t.selected;
                const base: Style = if (is_cur) bold else plain;
                const ix = cx + 1;
                switch (ln.line) {
                    .head => {
                        if (is_cur) _ = p.put(ix, y, 1, p.marker(), accent);
                        _ = p.put(ix + 1, y, 2, p.chevron(a.isCardExpanded(iss.key)), accent_plain);
                        try p.hitAdd(.{ .x = ix, .y = y, .w = 3, .h = 1 }, .{ .card_chevron = @intCast(ln.issue) });
                        var kx = ix + 3;
                        kx += p.put(kx, y, 2, kanban.typeGlyph(iss.issuetype, p.ui.ascii or !p.ui.nerd), muted) + 1;
                        const key_style: Style = if (a.isSelected(iss.key)) bulk else if (is_cur) accent else accent_plain;
                        kx += p.putFit(kx, y, inner_w -| (kx - ix), iss.key, key_style);
                        if (a.isSelected(iss.key)) _ = p.put(kx + 1, y, 2, if (p.ui.ascii) "+" else "✓", bulk);
                        try p.hitAdd(.{ .x = ix + 3, .y = y, .w = inner_w -| 3, .h = 1 }, .{ .card = @intCast(ln.issue) });
                    },
                    .summary => |s| {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, s, base);
                        try p.hitAdd(.{ .x = ix, .y = y, .w = inner_w, .h = 1 }, .{ .card = @intCast(ln.issue) });
                    },
                    .assignee => |s| {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, p.fmt("· {s}", .{s}), muted);
                        try p.hitAdd(.{ .x = ix, .y = y, .w = inner_w, .h = 1 }, .{ .card = @intCast(ln.issue) });
                    },
                    .labels => {
                        // `#label` chips, four at most, the reference's way.
                        var lx = ix + 3;
                        for (iss.labels, 0..) |l, lidx| {
                            if (lidx == 4) {
                                _ = p.put(lx, y, inner_w -| (lx - ix), p.fmt("+{d}", .{iss.labels.len - 4}), muted);
                                break;
                            }
                            const chip = p.fmt("#{s}", .{l});
                            if (lx + text.width(chip) > ix + inner_w) break;
                            lx += p.put(lx, y, inner_w -| (lx - ix), chip, accent_plain) + 1;
                        }
                        try p.hitAdd(.{ .x = ix, .y = y, .w = inner_w, .h = 1 }, .{ .card = @intCast(ln.issue) });
                    },
                    .hint => {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, "(click card for full details)", muted);
                        try p.hitAdd(.{ .x = ix, .y = y, .w = inner_w, .h = 1 }, .{ .card = @intCast(ln.issue) });
                    },
                    .actions => try p.paintActions(ix + 3, y, inner_w -| 3, ln.issue, iss),
                    .blank => {},
                }
            }
        }
    }

    // ─── the detail pane ─────────────────────────────────────────────

    fn paintDetail(p: *Painter, dx: u16) Allocator.Error!void {
        const a = p.a;
        const y0 = p.lay.tabs_y;
        const h = p.lay.status_y -| y0;
        const w = p.cols() -| dx;
        if (w < 8 or h < 2) return;
        var y = y0;
        while (y < y0 + h) : (y += 1) _ = p.put(dx, y, 1, "│", border);
        try p.hitAdd(.{ .x = dx, .y = y0, .w = w, .h = h }, .detail);
        const x = dx + 1;
        const iw = w -| 2;
        _ = p.put(x, y0, iw, "DETAIL", accent);
        const idx = (try a.focusedIssueIdx(p.arena)) orelse {
            _ = p.put(x, y0 + 1, iw, "no ticket under the cursor", muted);
            return;
        };
        const iss = a.tab().issues[idx];
        const lines = try p.detailLines(iss, iw);
        const avail: usize = h -| 1;
        var start: usize = a.details_scroll;
        if (start > lines.len -| avail) start = lines.len -| avail;
        a.details_scroll = @intCast(start);
        var i = start;
        y = y0 + 1;
        while (i < lines.len and y < y0 + h) : ({
            i += 1;
            y += 1;
        }) _ = p.put(x, y, iw, lines[i].s, lines[i].style);
    }

    const Line = struct { s: []const u8, style: Style = plain };

    fn detailLines(p: *Painter, iss: model.Issue, w: u16) Allocator.Error![]const Line {
        const a = p.a;
        var out: std.ArrayList(Line) = .empty;
        const arena = p.arena;
        var fb: [512]u8 = undefined;
        try out.append(arena, .{ .s = try arena.dupe(u8, text.fit(&fb, p.fmt("{s}  {s}", .{ iss.key, iss.summary }), w)), .style = bold });
        try out.append(arena, .{ .s = "" });
        const Field = struct { label: []const u8, value: []const u8 };
        const fields = [_]Field{
            .{ .label = "type", .value = iss.issuetype },
            .{ .label = "status", .value = iss.status },
            .{ .label = "priority", .value = iss.priority },
            .{ .label = "assignee", .value = iss.assigneeName() },
            .{ .label = "reporter", .value = iss.reporterName() },
            .{ .label = "fixVersion", .value = if (iss.fix_versions.len > 0) try std.mem.join(arena, ", ", iss.fix_versions) else "—" },
            .{ .label = "sprint", .value = if (iss.sprint.len > 0) iss.sprint else "—" },
            .{ .label = "labels", .value = if (iss.labels.len > 0) try std.mem.join(arena, ", ", iss.labels) else "—" },
        };
        for (fields) |f| try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "{s:>10}: {s}", .{ f.label, f.value }), .style = plain });
        try out.append(arena, .{ .s = "" });
        const d = a.detailOf(iss.key);
        if (d) |det| {
            if (det.error_text.len > 0) {
                try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "detail fetch failed: {s}", .{det.error_text}), .style = err_style });
            } else {
                const w_line = if (det.watching)
                    try std.fmt.allocPrint(arena, "{s:>10}: {s} watching ({d} total)", .{ "watcher", if (p.ui.ascii) "*" else "★", det.watch_count })
                else
                    try std.fmt.allocPrint(arena, "{s:>10}: {s} not watching ({d} total)", .{ "watcher", if (p.ui.ascii) "o" else "☆", det.watch_count });
                try out.append(arena, .{ .s = w_line, .style = if (det.watching) star else muted });
                try out.append(arena, .{ .s = "" });
                try out.append(arena, .{ .s = "── description", .style = muted });
                const desc = if (std.mem.trim(u8, det.description, " \n").len > 0) det.description else "(no description)";
                for (try text.wrap(arena, desc, w)) |l| try out.append(arena, .{ .s = l });
                try out.append(arena, .{ .s = "" });
                try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "── comments ({d})", .{det.comments.len}), .style = muted });
                if (det.comments.len == 0) try out.append(arena, .{ .s = "(no comments)", .style = muted });
                for (det.comments) |c| {
                    try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "{s} · {s}", .{ c.author, text.dayOf(c.created) }), .style = accent_plain });
                    for (try text.wrap(arena, c.body, w)) |l| try out.append(arena, .{ .s = l });
                    try out.append(arena, .{ .s = "" });
                }
            }
        } else {
            try out.append(arena, .{ .s = "loading the detail…", .style = muted });
        }
        return out.toOwnedSlice(arena);
    }

    // ─── the last row ────────────────────────────────────────────────

    fn paintStatus(p: *Painter) Allocator.Error!void {
        const a = p.a;
        const y = p.lay.status_y;
        const w = p.cols();
        var x: u16 = 1;
        const status = a.status.items;
        const hint: []const u8 = blk: {
            if (a.help) break :blk "j/k scroll · Esc close";
            if (a.modal != null) break :blk "j/k · PgUp/PgDn scroll · Esc close";
            if (a.comment != null) break :blk "typing comment · Ctrl+S send · Esc cancel · Enter newline";
            if (a.picker) |pk| break :blk if (pk.kind.multi()) "type to filter · ↑↓ move · Space toggle · Enter commit · Esc cancel" else "type to filter · ↑↓ move · Enter commit · Esc cancel";
            if (a.transition != null) break :blk "1-9 jump · ↑↓/jk move · Enter commit · Esc cancel";
            if (a.jql != null) break :blk "type to edit · Enter run · Esc cancel · Ctrl+A/E ends · Alt+←/→ words";
            if (a.filter) |f| if (f.editing) break :blk "type to filter · Enter commit · Esc cancel";
            if (!a.hasTabs()) break :blk "r refresh · q quit";
            break :blk "";
        };
        if (status.len > 0) {
            x += p.putFit(x, y, w -| x, status, plain);
            x += 2;
        }
        if (hint.len > 0) {
            _ = p.putFit(x, y, w -| x, hint, muted);
            return;
        }
        // The section help row: `t transition · a assignee · …` from the
        // bindings that apply, whole entries only, as many as fit.
        for (try keymap.hints(p.arena, a.context()), 0..) |b, i| {
            var kb: [16]u8 = undefined;
            const entry = if (i == 0) p.fmt("{s} {s}", .{ keymap.displayKey(&kb, b.keys[0]), b.label }) else p.fmt("· {s} {s}", .{ keymap.displayKey(&kb, b.keys[0]), b.label });
            const ew = text.width(entry);
            if (x + ew > w) break;
            x += p.put(x, y, ew, entry, muted) + 1;
        }
    }

    // ─── the overlays ────────────────────────────────────────────────

    /// A bordered box with its title in the top edge; the inside is
    /// blanked so what was under it does not show through.
    fn box(p: *Painter, r: Rect, title: []const u8, style: Style) Allocator.Error!void {
        if (r.w < 2 or r.h < 2) return;
        p.f.fill(r.x, r.y, r.w, r.h, .none);
        const ascii = p.ui.ascii;
        const tl = if (ascii) "+" else "┌";
        const tr = if (ascii) "+" else "┐";
        const bl = if (ascii) "+" else "└";
        const br = if (ascii) "+" else "┘";
        const hz = if (ascii) "-" else "─";
        const vt = if (ascii) "|" else "│";
        var x = r.x;
        while (x < r.right()) : (x += 1) {
            _ = p.put(x, r.y, 1, hz, style);
            _ = p.put(x, r.bottom() - 1, 1, hz, style);
        }
        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            _ = p.put(r.x, y, 1, vt, style);
            _ = p.put(r.right() - 1, y, 1, vt, style);
        }
        _ = p.put(r.x, r.y, 1, tl, style);
        _ = p.put(r.right() - 1, r.y, 1, tr, style);
        _ = p.put(r.x, r.bottom() - 1, 1, bl, style);
        _ = p.put(r.right() - 1, r.bottom() - 1, 1, br, style);
        if (title.len > 0) _ = p.putFit(r.x + 1, r.y, r.w -| 2, title, accent);
    }

    fn centred(p: *const Painter, w: u16, h: u16) Rect {
        const bw = @min(w, p.cols());
        const bh = @min(h, p.rows());
        return .{ .x = (p.cols() - bw) / 2, .y = (p.rows() - bh) / 2, .w = bw, .h = bh };
    }

    fn paintPicker(p: *Painter) Allocator.Error!void {
        const pk = &(p.a.picker.?);
        const r = p.centred(60, 18);
        const title = if (pk.targets > 1) p.fmt(" {s} ({d} tickets) ", .{ pk.kind.title(), pk.targets }) else p.fmt(" {s} ", .{pk.kind.title()});
        try p.box(r, title, border);
        try p.hitAdd(r, .picker_body);
        const ix = r.x + 2;
        const iw = r.w -| 4;
        // The filter line.
        const glyph = if (p.ui.ascii or !p.ui.nerd) search_ascii else search_nerd;
        var fx = ix;
        fx += p.put(fx, r.y + 1, iw, glyph, accent_plain) + 1;
        if (pk.filter.items.len > 0) {
            fx += p.put(fx, r.y + 1, iw -| (fx - ix), pk.filter.items, plain);
        } else fx += p.put(fx, r.y + 1, iw -| (fx - ix), if (p.ui.ascii) placeholder_focused_ascii else placeholder_focused, muted);
        _ = p.put(fx, r.y + 1, 1, "▏", accent_plain);
        if (!pk.loaded) {
            _ = p.put(ix, r.y + 3, iw, "loading…", muted);
            return;
        }
        if (pk.error_text.len > 0) {
            for (try text.wrap(p.arena, pk.error_text, iw), 0..) |l, i| {
                if (r.y + 3 + i >= r.bottom() - 2) break;
                _ = p.put(ix, @intCast(r.y + 3 + i), iw, l, err_style);
            }
        }
        const vis = try pk.visible(p.arena);
        const list_y = r.y + 3;
        const list_h: usize = r.h -| 6;
        var pos: usize = 0;
        for (vis, 0..) |i, k| if (i == pk.selected) {
            pos = k;
        };
        const start = if (pos >= list_h) pos + 1 - list_h else 0;
        var k = start;
        var y = list_y;
        while (k < vis.len and y < list_y + list_h) : ({
            k += 1;
            y += 1;
        }) {
            const it = pk.items[vis[k]];
            const is_cur = vis[k] == pk.selected;
            var x = ix;
            if (is_cur) _ = p.put(x, y, 1, p.marker(), accent);
            x += 2;
            if (pk.kind.multi()) {
                const on = pk.isChecked(it.id);
                x += p.put(x, y, 4, if (on) "[x] " else "[ ] ", if (on) accent_plain else muted);
            }
            _ = p.putFit(x, y, iw -| (x - ix), it.label, if (is_cur) bold else plain);
            try p.hitAdd(.{ .x = r.x + 1, .y = y, .w = r.w -| 2, .h = 1 }, .{ .picker_row = @intCast(vis[k]) });
        }
        if (vis.len == 0 and pk.error_text.len == 0) _ = p.put(ix, list_y, iw, "nothing matches", muted);
        const hint = if (pk.kind.multi()) "type to filter · ↑↓ move · Space toggle · Enter commit · Esc cancel" else "type to filter · ↑↓ move · Enter commit · Esc cancel";
        _ = p.putFit(ix, r.bottom() - 2, iw, hint, muted);
    }

    fn paintTransition(p: *Painter) Allocator.Error!void {
        const tp = &(p.a.transition.?);
        const r = p.centred(60, 14);
        const title = if (tp.targets > 1) p.fmt(" transition {s} (+{d} more) ", .{ tp.key, tp.targets - 1 }) else p.fmt(" transition {s} ", .{tp.key});
        try p.box(r, title, border);
        try p.hitAdd(r, .picker_body);
        const ix = r.x + 1;
        const iw = r.w -| 2;
        const list = tp.transitions orelse {
            _ = p.put(ix + 1, r.y + 1, iw, "loading…", muted);
            return;
        };
        var y = r.y + 1;
        for (list, 0..) |t, i| {
            if (y >= r.bottom() - 3) break;
            const is_cur = i == tp.selected;
            if (is_cur) _ = p.put(ix, y, 1, p.marker(), accent);
            const line = p.fmt("{d}. {s}  → {s}", .{ i + 1, t.name, t.to_name });
            _ = p.putFit(ix + 2, y, iw -| 2, line, if (is_cur) bold else plain);
            try p.hitAdd(.{ .x = ix, .y = y, .w = iw, .h = 1 }, .{ .picker_row = @intCast(i) });
            y += 1;
        }
        if (list.len == 0 and tp.error_text.len == 0) _ = p.put(ix + 2, r.y + 1, iw, "no transitions from here", muted);
        if (tp.error_text.len > 0) _ = p.putFit(ix + 2, r.bottom() - 3, iw -| 2, tp.error_text, err_style);
        _ = p.putFit(ix + 2, r.bottom() - 2, iw -| 2, "1-9 jump · ↑↓/jk move · Enter commit · Esc cancel", muted);
    }

    fn paintModal(p: *Painter) Allocator.Error!void {
        const m = &(p.a.modal.?);
        const r = p.centred(@max(p.cols() * 4 / 5, 40), @max(p.rows() * 4 / 5, 8));
        try p.box(r, p.fmt(" {s} ", .{m.key}), border);
        try p.hitAdd(r, .modal_body);
        const close_t = " × ";
        const cx = r.right() -| (text.width(close_t) + 1);
        _ = p.put(cx, r.y + 1, text.width(close_t), if (p.ui.ascii) " x " else close_t, chip_style);
        try p.hitAdd(.{ .x = cx, .y = r.y + 1, .w = text.width(close_t), .h = 1 }, .modal_close);
        const ix = r.x + 1;
        const iw = r.w -| 2;
        if (m.error_text.len > 0) {
            _ = p.putFit(ix + 1, r.y + 1, iw -| 2, p.fmt("could not load {s}: {s}", .{ m.key, m.error_text }), err_style);
            return;
        }
        const v = m.data orelse {
            _ = p.put(ix + 1, r.y + 1, iw, "loading…", muted);
            return;
        };
        const summary = try model.fieldDisplay(p.arena, v, "summary");
        const status = try model.fieldDisplay(p.arena, v, "status");
        _ = p.putFit(ix + 1, r.y + 1, cx -| (ix + 2), p.fmt("{s} · {s}  [{s}]", .{ m.key, summary, status }), bold);
        // 40 / 60: the field table on the left, the description right.
        const left_w: u16 = @max(iw * 2 / 5, 16);
        const right_x = ix + left_w + 1;
        const right_w = iw -| (left_w + 2);
        var left: std.ArrayList(Line) = .empty;
        var right: std.ArrayList(Line) = .empty;
        var label_w: usize = 4;
        for (p.a.cfg.detail_modal.fields) |spec| label_w = @max(label_w, p.a.cfg.detail_modal.resolveLabel(spec).len);
        for (p.a.cfg.detail_modal.fields) |spec| {
            const id = p.a.cfg.detail_modal.resolveId(spec);
            const label = p.a.cfg.detail_modal.resolveLabel(spec);
            const value = try model.fieldDisplay(p.arena, v, id);
            if (std.mem.eql(u8, id, "description") or std.mem.eql(u8, id, "environment")) {
                try right.append(p.arena, .{ .s = label, .style = accent_plain });
                for (try text.wrap(p.arena, value, right_w)) |l| try right.append(p.arena, .{ .s = l });
                try right.append(p.arena, .{ .s = "" });
                continue;
            }
            const head = try std.fmt.allocPrint(p.arena, "{s} : ", .{padRight(p.arena, label, label_w)});
            const wrapped = try text.wrap(p.arena, value, @max(left_w -| @as(u16, @intCast(head.len)), 8));
            if (wrapped.len == 0) {
                try left.append(p.arena, .{ .s = head, .style = muted });
                continue;
            }
            try left.append(p.arena, .{ .s = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ head, wrapped[0] }) });
            for (wrapped[1..]) |l| try left.append(p.arena, .{ .s = l });
        }
        const body_y = r.y + 2;
        const body_h: usize = r.h -| 3;
        const scroll: usize = m.scroll;
        var i: usize = scroll;
        var y = body_y;
        while (y < body_y + body_h) : ({
            i += 1;
            y += 1;
        }) {
            if (i < left.items.len) _ = p.putFit(ix + 1, y, left_w -| 1, left.items[i].s, left.items[i].style);
            if (i < right.items.len) _ = p.putFit(right_x, y, right_w, right.items[i].s, right.items[i].style);
        }
        _ = p.putFit(ix + 1, r.bottom() - 1, iw -| 2, " j/k scroll · Esc close ", muted);
    }

    fn paintJql(p: *Painter) Allocator.Error!void {
        const e = &(p.a.jql.?);
        const wrap_w: u16 = @intCast(p.a.jqlWrapWidth());
        const bw = wrap_w + 2;
        const lines = try wrapHard(p.arena, e.text(), wrap_w);
        const bh: u16 = @intCast(@min(@max(lines.len, 1) + 2, @as(usize, p.rows() -| 4)));
        const r: Rect = .{ .x = (p.cols() -| bw) / 2, .y = p.lay.status_y -| (bh + 1), .w = bw, .h = bh };
        try p.box(r, " JQL — type to edit · Enter run · Esc cancel ", border);
        try p.hitAdd(r, .jql_body);
        const caret = e.cursorCodepoints();
        var cp: usize = 0;
        for (lines, 0..) |l, li| {
            if (li + 1 >= bh - 1) break;
            const y: u16 = @intCast(r.y + 1 + li);
            _ = p.put(r.x + 1, y, wrap_w, l, plain);
            try p.hitAdd(.{ .x = r.x + 1, .y = y, .w = wrap_w, .h = 1 }, .{ .jql_text = .{ .col = 0, .row = @intCast(li) } });
            const n = std.unicode.utf8CountCodepoints(l) catch l.len;
            if (caret >= cp and caret <= cp + n and (caret < cp + n or li + 1 == lines.len or n < wrap_w)) {
                const cx: u16 = @intCast(r.x + 1 + (caret - cp));
                const under = if (caret < cp + n) codepointAt(l, caret - cp) else " ";
                _ = p.put(cx, y, 1, under, .{ .mods = .{ .reverse = true } });
            }
            cp += n;
        }
        if (lines.len == 0) _ = p.put(r.x + 1, r.y + 1, 1, " ", .{ .mods = .{ .reverse = true } });
    }

    fn paintComment(p: *Painter) Allocator.Error!void {
        const c = &(p.a.comment.?);
        const bw: u16 = if (p.lay.detail_x) |dx| p.cols() -| dx else @min(p.cols(), 60);
        const bx: u16 = if (p.lay.detail_x) |dx| dx else (p.cols() -| bw) / 2;
        const bh: u16 = @min(8, p.rows() -| 2);
        const r: Rect = .{ .x = bx, .y = p.lay.status_y -| bh, .w = bw, .h = bh };
        try p.box(r, p.fmt(" comment on {s} ", .{c.key}), border);
        try p.hitAdd(r, .comment);
        const iw = r.w -| 2;
        const lines = try wrapHard(p.arena, c.edit.text(), iw);
        const caret = c.edit.cursorCodepoints();
        var cp: usize = 0;
        var y = r.y + 1;
        for (lines, 0..) |l, li| {
            if (y >= r.bottom() - 1) break;
            _ = p.put(r.x + 1, y, iw, l, plain);
            const n = std.unicode.utf8CountCodepoints(l) catch l.len;
            if (caret >= cp and caret <= cp + n and (caret < cp + n or li + 1 == lines.len)) {
                const cx: u16 = @intCast(r.x + 1 + @min(caret - cp, iw -| 1));
                _ = p.put(cx, y, 1, if (caret < cp + n) codepointAt(l, caret - cp) else " ", .{ .mods = .{ .reverse = true } });
            }
            cp += n + 1;
            y += 1;
        }
        if (lines.len == 0) _ = p.put(r.x + 1, r.y + 1, 1, " ", .{ .mods = .{ .reverse = true } });
        if (c.error_text.len > 0) _ = p.putFit(r.x + 1, r.bottom() - 2, iw, c.error_text, err_style);
        _ = p.putFit(r.x + 1, r.bottom() - 1, iw, if (c.posting) " sending… " else " Ctrl+S send · Esc cancel · Enter newline ", muted);
    }

    /// The key sheet, the built-in sections' way: `▾ ── name ── (n)`
    /// headers and `  chord  title` rows, from the bindings that apply.
    fn paintHelp(p: *Painter) Allocator.Error!void {
        const r = p.centred(84, 32);
        try p.box(r, " KEYS ", border);
        try p.hitAdd(r, .help_body);
        const ix = r.x + 1;
        const iw = r.w -| 2;
        const HelpRow = struct { header: []const u8 = "", chord: []const u8 = "", label: []const u8 = "" };
        var lines: std.ArrayList(HelpRow) = .empty;
        const ctx = p.a.context();
        const active = try keymap.active(p.arena, ctx);
        var chord_w: u16 = 8;
        for (active) |b| {
            var buf: [64]u8 = undefined;
            chord_w = @max(chord_w, @min(text.width(chordText(&buf, b)), 20));
        }
        for (keymap.modal_rows) |m| chord_w = @max(chord_w, @min(text.width(m.keys), 20));
        const fold = if (p.ui.ascii) "v" else "▾";
        inline for (@typeInfo(keymap.Section).@"enum".fields) |sf| {
            const section: keymap.Section = @enumFromInt(sf.value);
            var n: usize = 0;
            for (active) |b| if (b.section == section) {
                n += 1;
            };
            if (n > 0) {
                try lines.append(p.arena, .{ .header = try std.fmt.allocPrint(p.arena, "{s} ── {s} ── ({d})", .{ fold, section.title(), n }) });
                for (active) |b| if (b.section == section) {
                    var buf: [64]u8 = undefined;
                    try lines.append(p.arena, .{ .chord = try p.arena.dupe(u8, chordText(&buf, b)), .label = b.label });
                };
                try lines.append(p.arena, .{});
            }
        }
        try lines.append(p.arena, .{ .header = try std.fmt.allocPrint(p.arena, "{s} ── overlays ── ({d})", .{ fold, keymap.modal_rows.len }) });
        for (keymap.modal_rows) |m| try lines.append(p.arena, .{ .chord = m.keys, .label = m.label });
        const body_h: usize = r.h -| 3;
        var start = p.a.help_scroll;
        if (start > lines.items.len -| body_h) start = lines.items.len -| body_h;
        p.a.help_scroll = start;
        var i = start;
        var y = r.y + 1;
        while (i < lines.items.len and y < r.bottom() - 2) : ({
            i += 1;
            y += 1;
        }) {
            const l = lines.items[i];
            if (l.header.len > 0) {
                _ = p.putFit(ix + 1, y, iw -| 1, l.header, bold);
            } else if (l.chord.len > 0) {
                // The chord in the accent, padded to the column; the title plain.
                _ = p.putFit(ix + 3, y, chord_w, l.chord, accent_plain);
                _ = p.putFit(ix + 3 + chord_w + 2, y, iw -| (chord_w + 6), l.label, plain);
            }
        }
        _ = p.putFit(ix + 1, r.bottom() - 2, iw -| 1, "j/k scroll · Esc close", muted);
    }
};

// ─── styles by state ─────────────────────────────────────────────────────

fn statusStyle(iss: model.Issue, base: Style) Style {
    var s = base;
    if (std.mem.eql(u8, iss.status_category, "done")) {
        s.fg = .{ .index = 2 };
    } else if (std.mem.eql(u8, iss.status_category, "indeterminate")) {
        s.fg = .{ .index = 4 };
    } else s.mods.dim = true;
    return s;
}

fn prStyle(status: []const u8) Style {
    if (std.ascii.eqlIgnoreCase(status, "merged")) return ok_style;
    if (std.ascii.eqlIgnoreCase(status, "open")) return warn_style;
    if (std.ascii.eqlIgnoreCase(status, "declined")) return err_style;
    return muted;
}

fn pipelineStyle(pipe: model.Pipeline) Style {
    if (std.ascii.eqlIgnoreCase(pipe.result, "successful")) return ok_style;
    if (std.ascii.eqlIgnoreCase(pipe.result, "failed") or std.ascii.eqlIgnoreCase(pipe.result, "error")) return err_style;
    return muted;
}

// ─── small text helpers ──────────────────────────────────────────────────

/// ` key: value ` — mnml's mode chip.
pub fn chipText(arena: Allocator, key: []const u8, value: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, " {s}: {s} ", .{ key, value });
}

pub fn upperOf(arena: Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s;
    for (s, out) |c, *o| o.* = std.ascii.toUpper(c);
    return out;
}

fn padRight(arena: Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    const out = arena.alloc(u8, w) catch return s;
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

/// `MG` from `Marco Gomez`; one letter for a single name.
pub fn initials(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, name, ' ');
    while (it.next()) |word| {
        if (n >= 2 or n >= buf.len) break;
        if (word.len == 0) continue;
        const cp_len = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
        if (cp_len == 1) {
            buf[n] = std.ascii.toUpper(word[0]);
            n += 1;
        } else if (n + cp_len <= buf.len) {
            @memcpy(buf[n .. n + cp_len], word[0..cp_len]);
            n += cp_len;
        }
    }
    if (n == 0) {
        buf[0] = '?';
        return buf[0..1];
    }
    return buf[0..n];
}

/// The chords of a binding as the sheet prints them: `↑ / k`.
fn chordText(buf: []u8, b: keymap.Binding) []const u8 {
    var n: usize = 0;
    for (b.keys, 0..) |k, i| {
        var kb: [16]u8 = undefined;
        const d = keymap.displayKey(&kb, k);
        if (i > 0) {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n .. n + 3], " / ");
            n += 3;
        }
        if (n + d.len > buf.len) break;
        @memcpy(buf[n .. n + d.len], d);
        n += d.len;
    }
    return buf[0..n];
}

/// The value of `fixVersion = "…"` in a JQL, if any.
pub fn fixVersionOf(jql: []const u8) ?[]const u8 {
    var lower: [4096]u8 = undefined;
    const n = @min(jql.len, lower.len);
    for (jql[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const start = std.mem.indexOf(u8, lower[0..n], "fixversion") orelse return null;
    const after = jql[start + "fixversion".len ..];
    const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const rest = after[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

/// Lines of exactly `w` code points (the last shorter), newlines
/// honoured — the JQL editor's and the comment box's wrap.
pub fn wrapHard(arena: Allocator, s: []const u8, w: u16) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (w == 0) return out.toOwnedSlice(arena);
    var para = std.mem.splitScalar(u8, s, '\n');
    while (para.next()) |line| {
        var start: usize = 0;
        var n: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const cl = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (n == w) {
                try out.append(arena, line[start..i]);
                start = i;
                n = 0;
            }
            i += cl;
            n += 1;
        }
        try out.append(arena, line[start..]);
    }
    if (out.items.len > 0 and s.len == 0) out.items.len = 0;
    return out.toOwnedSlice(arena);
}

fn codepointAt(s: []const u8, idx: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const cl = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (n == idx) return s[i..@min(i + cl, s.len)];
        i += cl;
        n += 1;
    }
    return " ";
}

/// A setup screen — no config, no token, a bad file: the title, the
/// lines, and the keys that apply.
pub fn paintNotice(f: *Frame, title: []const u8, lines: []const []const u8, hint: []const u8) void {
    f.clear(.none);
    _ = f.text(1, 0, f.cols -| 1, title, accent);
    var y: u16 = 2;
    for (lines) |l| {
        if (y + 1 >= f.rows) break;
        _ = f.text(1, y, f.cols -| 1, l, if (l.len > 0 and l[0] == ' ') muted else plain);
        y += 1;
    }
    if (f.rows > 0) _ = f.text(1, f.rows - 1, f.cols -| 1, hint, muted);
}

/// Paint `a` onto `f` and fill its hit map.
pub fn paint(arena: Allocator, f: *Frame, a: *App, ui: Ui) Allocator.Error!void {
    var p: Painter = .{ .f = f, .a = a, .arena = arena, .ui = ui };
    try p.paint();
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// The frame as text rows, for the assertions.
pub fn rowText(arena: Allocator, f: *const Frame, y: u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) {
        const sym = f.slots[@as(usize, y) * f.cols + x].symbol();
        try out.appendSlice(arena, if (sym.len == 0) "" else sym);
    }
    return std.mem.trimEnd(u8, try out.toOwnedSlice(arena), " ");
}

pub fn screenText(arena: Allocator, f: *const Frame) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        try out.appendSlice(arena, try rowText(arena, f, y));
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn findRow(arena: Allocator, f: *const Frame, needle: []const u8) Allocator.Error!?u16 {
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        if (std.mem.indexOf(u8, try rowText(arena, f, y), needle) != null) return y;
    }
    return null;
}

fn colOfText(arena: Allocator, f: *const Frame, y: u16, needle: []const u8) Allocator.Error!?u16 {
    const row = try rowText(arena, f, y);
    const byte = std.mem.indexOf(u8, row, needle) orelse return null;
    return @intCast(std.unicode.utf8CountCodepoints(row[0..byte]) catch byte);
}

test "initials, the fixVersion pill's value and the hard wrap" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("MG", initials(&buf, "Marco Gomez"));
    try testing.expectEqualStrings("A", initials(&buf, "ada"));
    try testing.expectEqualStrings("?", initials(&buf, ""));
    try testing.expectEqualStrings("13.16.0", fixVersionOf("project = ENG AND fixVersion = \"13.16.0\" ORDER BY rank").?);
    try testing.expect(fixVersionOf("project = ENG") == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try wrapHard(arena.allocator(), "abcdefgh\nij", 3);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("gh", lines[2]);
    try testing.expectEqualStrings("ij", lines[3]);
}

test "Work: the header, the tab strip, the mode chips, the columns, the tree rows, and every row is a hit" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const r0 = try rowText(ar, &f, 0);
    try testing.expect(std.mem.startsWith(u8, r0, " JIRA WORK (3)"));
    try testing.expect(std.mem.endsWith(u8, r0, " ?"));
    try testing.expectEqualStrings("\u{258c}1 Assigned   2 Recently Done", try rowText(ar, &f, 1));
    const r2 = try rowText(ar, &f, 2);
    try testing.expect(std.mem.indexOf(u8, r2, " basic ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " assignee: All ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " status: All") != null);
    try testing.expect(std.mem.indexOf(u8, r0, "\u{eb37}") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "/ filter") != null);
    const r3 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.startsWith(u8, r3, "  KEY"));
    try testing.expect(std.mem.indexOf(u8, r3, "SUMMARY") != null);
    // The first group is the cursor: marker, chevron, name and count.
    const r4 = try rowText(ar, &f, 4);
    try testing.expect(std.mem.startsWith(u8, r4, "\u{258c}\u{F47C} In PR Review (1)"));
    // ENG-2 under it with its two PRs, then the buttons.
    const r5 = try rowText(ar, &f, 5);
    try testing.expect(std.mem.indexOf(u8, r5, "ENG-2") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "In PR Review") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "Ada Lovelace") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "Card form validates on blur") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "[ Review ]") != null);
    const r6 = try rowText(ar, &f, 6);
    try testing.expect(std.mem.indexOf(u8, r6, "MERGED") != null);
    try testing.expect(std.mem.indexOf(u8, r6, "[ Open ]") != null);
    try testing.expect(std.mem.indexOf(u8, r6, "[ Merge ]") == null);
    const r7 = try rowText(ar, &f, 7);
    try testing.expect(std.mem.indexOf(u8, r7, "OPEN") != null);
    try testing.expect(std.mem.indexOf(u8, r7, "[ Review ] [ Merge ] [ Open ]") != null);
    const merge_x = (try colOfText(ar, &f, 7, "[ Merge ]")).?;
    try testing.expectEqual(hit.Target{ .pr_button = .{ .row = 3, .which = .merge } }, a.hits.at(merge_x + 2, 7).?);
    // The hint row comes from the bindings, not a string.
    const last = try rowText(ar, &f, 39);
    try testing.expect(std.mem.indexOf(u8, last, "t transition · a assignee · S select for a bulk action") != null);
    // Every painted row is a hit, and a click on row 6 selects that row.
    try testing.expectEqual(hit.Target{ .row = 2 }, a.hits.at(30, 6).?);
    try testing.expectEqual(hit.Target{ .tab = 1 }, a.hits.at(14, 1).?);
    try testing.expectEqual(hit.Target{ .chip = .help }, a.hits.at(118, 0).?);
    const review_x = (try colOfText(ar, &f, 5, "[ Review ]")).?;
    try testing.expectEqual(hit.Target{ .action = .{ .issue = 1, .button = 0 } }, a.hits.at(review_x + 2, 5).?);
    try a.click(30, 6, false);
    try testing.expectEqual(@as(usize, 2), a.tab().selected);
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 6), "\u{258c}"));
    // The chevron on the group folds it.
    try a.click(1, 4, false);
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 4), "\u{258c}\u{F460} In PR Review (1)"));
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 5), "ENG-2") == null);
}

test "Work: the detail pane, the filter pill while typing, the bulk marks, and the pickers over the list" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = try a.onKey("j");
    _ = try a.onKey("d");
    try paint(ar, &f, a, .{});
    try testing.expect((try findRow(ar, &f, "DETAIL")) != null);
    try testing.expect((try findRow(ar, &f, "ENG-2  Card form validates on blur")) != null);
    try testing.expect((try findRow(ar, &f, "★ watching (2 total)")) != null);
    try testing.expect((try findRow(ar, &f, "── comments (2)")) != null);
    try testing.expectEqual(hit.Target.detail, a.hits.at(100, 10).?);
    _ = try a.onKey("d");
    // The filter pill while typing, then committed.
    _ = try a.onKey("/");
    _ = try a.onKey("v");
    _ = try a.onKey("o");
    _ = try a.onKey("u");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 2), "\u{F0349} vou▏") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 39), "type to filter · Enter commit · Esc cancel") != null);
    _ = try a.onKey("enter");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), " JIRA WORK (1 of 3)"));
    try testing.expect((try findRow(ar, &f, "ENG-5")) != null);
    try testing.expect((try findRow(ar, &f, "ENG-2")) == null);
    _ = try a.onKey("esc");
    // Bulk marks: S on a ticket lights it and the header counts.
    _ = try a.onKey("j");
    _ = try a.onKey("shift+s");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 0), "1 selected") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 5), "ENG-2 ✓") != null);
    // The assignee picker over the list: title, filter line, rows, hits.
    _ = try a.onKey("a");
    try paint(ar, &f, a, .{});
    const title_y = (try findRow(ar, &f, " set assignee ")).?;
    try testing.expect((try findRow(ar, &f, "— Unassign —")) != null);
    const lin_y = (try findRow(ar, &f, "Lin Zhao")).?;
    try testing.expectEqual(hit.Target{ .picker_row = 3 }, a.hits.at(60, lin_y).?);
    try testing.expectEqual(hit.Target.picker_body, a.hits.at(60, title_y + 1).?);
    try a.click(60, lin_y, false);
    try testing.expect(a.picker == null);
    try testing.expectEqualStrings(@import("jira.zig").fake.account_lin, h.store.find("ENG-2").?.assignee);
}

test "Fix Versions: the pill, the bump star, the transition picker's rows, and the key sheet" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.fixv_tabs }, .fix_versions);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), " JIRA FIX VERSIONS (8)"));
    const r2 = try rowText(ar, &f, 2);
    try testing.expect(std.mem.indexOf(u8, r2, " fixVersion: 13.16.0 ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " ⓧ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " space: ENG ") != null);
    const star_y = (try findRow(ar, &f, "ENG-2 ★")).?;
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, star_y), "Testing") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 39), "f switch the release") != null);
    _ = try a.onKey("j");
    _ = try a.onKey("t");
    try paint(ar, &f, a, .{});
    try testing.expect((try findRow(ar, &f, " transition ENG-2 ")) != null);
    const row_y = (try findRow(ar, &f, "3. ")).?;
    try testing.expectEqual(hit.Target{ .picker_row = 2 }, a.hits.at(60, row_y).?);
    try testing.expect((try findRow(ar, &f, "1-9 jump · ↑↓/jk move · Enter commit · Esc cancel")) != null);
    _ = try a.onKey("esc");
    _ = try a.onKey("?");
    try paint(ar, &f, a, .{});
    try testing.expect((try findRow(ar, &f, " KEYS ")) != null);
    try testing.expect((try findRow(ar, &f, "▾ ── rows ──")) != null);
    // The dispatch section is below the fold at 32 rows: scroll to it.
    a.help_scroll = 14;
    try paint(ar, &f, a, .{});
    const impl_y = (try findRow(ar, &f, "dispatch: implement")).?;
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, impl_y), "│   I ") != null);
    // The overlays section is last; a big scroll clamps to the end.
    a.help_scroll = 999;
    try paint(ar, &f, a, .{});
    try testing.expect((try findRow(ar, &f, "▾ ── overlays ──")) != null);
    try testing.expect((try findRow(ar, &f, "JQL editor: line ends")) != null);
    try a.click(60, 20, false);
    try testing.expect(!a.help);
}

test "Boards: the kanban columns, the cards with a chevron and a marker, the avatar cluster, and the modal" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.board_tabs, .team_field_id = "customfield_10056" }, .boards);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), " JIRA BOARDS (3 of 9)"));
    const r2 = try rowText(ar, &f, 2);
    try testing.expect(std.mem.indexOf(u8, r2, " board: Checkout board ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " sprint: Sprint 4 ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " [?] ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " SB ") != null);
    const r3 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.indexOf(u8, r3, " quick filters ") != null or std.mem.indexOf(u8, r2, " quick filters ") != null);
    const top = (try findRow(ar, &f, " To Do (")).?;
    const top_row = try rowText(ar, &f, top);
    try testing.expect(std.mem.indexOf(u8, top_row, " In Progress (") != null);
    try testing.expect(std.mem.indexOf(u8, top_row, " Testing (") != null);
    try testing.expect(std.mem.indexOf(u8, top_row, " Done (") != null);
    // The cursor's card carries the marker; its head is the chevron hit,
    // its summary the card hit.
    const head_y = (try findRow(ar, &f, "ENG-1")).?;
    const head_x = (try colOfText(ar, &f, head_y, "\u{258c}")).?;
    try testing.expectEqual(hit.Target{ .card_chevron = 0 }, a.hits.at(head_x + 1, head_y).?);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, head_y + 1), "Checkout rewrite") != null);
    try testing.expectEqual(hit.Target{ .card = 0 }, a.hits.at(head_x + 6, head_y + 1).?);
    // An avatar click toggles that assignee into the filter.
    const sb_x = (try colOfText(ar, &f, 2, " SB ")).?;
    try a.click(sb_x + 1, 2, false);
    try testing.expectEqual(@as(usize, 2), a.tab().active_assignees.count());
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), " JIRA BOARDS (4 of 9)"));
    // The modal: title, the field table and the description.
    try a.click(head_x + 6, head_y + 1, false);
    try testing.expect(a.modal != null);
    try paint(ar, &f, a, .{});
    try testing.expect((try findRow(ar, &f, "ENG-1 · Checkout rewrite  [In Progress]")) != null);
    try testing.expect((try findRow(ar, &f, "Assignee    : Ada Lovelace")) != null);
    try testing.expect((try findRow(ar, &f, "Description")) != null);
    const x_y = (try findRow(ar, &f, " × ")).?;
    const x_x = (try colOfText(ar, &f, x_y, " × ")).?;
    try testing.expectEqual(hit.Target.modal_close, a.hits.at(x_x + 1, x_y).?);
    try a.click(x_x + 1, x_y, false);
    try testing.expect(a.modal == null);
}

test "the narrow pane: 80x24 keeps the chips whole by wrapping, the columns shrink, the hint row still reads" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    a.resize(80, 24);
    var f = try Frame.init(testing.allocator, 80, 24);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const r2 = try rowText(ar, &f, 2);
    const r3 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.indexOf(u8, r2, " basic ") != null);
    // Whatever did not fit on row 2 is whole on row 3, never clipped.
    try testing.expect(std.mem.indexOf(u8, r3, " status: All") != null or std.mem.indexOf(u8, r2, " status: All") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 4), "KEY") != null or std.mem.indexOf(u8, r3, "KEY") != null);
    try testing.expect((try findRow(ar, &f, "ENG-2")) != null);
    const last = try rowText(ar, &f, 23);
    try testing.expect(std.mem.indexOf(u8, last, "t transition") != null);
    // Wheel on the list moves the cursor.
    try a.wheel(20, 10, -1);
    try testing.expect(a.tab().selected > 0);
}

test "the JQL editor paints its box with the caret and a click places it" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = try a.onKey("shift+e");
    try paint(ar, &f, a, .{});
    const title_y = (try findRow(ar, &f, " JQL — type to edit")).?;
    const line = try rowText(ar, &f, title_y + 1);
    try testing.expect(std.mem.indexOf(u8, line, "assignee = currentUser()") != null);
    try testing.expectEqual(hit.Target{ .jql_text = .{ .col = 0, .row = 0 } }, a.hits.at(20, title_y + 1).?);
    const x0 = (try colOfText(ar, &f, title_y + 1, "assignee")).?;
    try a.click(x0 + 3, title_y + 1, false);
    try testing.expectEqual(@as(usize, 3), a.jql.?.cursor);
    _ = try a.onKey("esc");
    try testing.expect(a.jql == null);
}
