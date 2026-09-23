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
const varsedit = @import("varsedit.zig");
const text = @import("text.zig");
const filters = @import("filters.zig");

const App = app_mod.App;
const Frame = sdk.Frame;
const Style = sdk.Style;
const Theme = sdk.pane.Theme;
const Rect = hit.Rect;

/// What the host told us about the terminal — and the theme it sends
/// with its hello, so the pane paints in the theme it is mounted in.
pub const Ui = struct {
    ascii: bool = false,
    nerd: bool = true,
    th: Theme = .{},
    /// How the tab strip marks the tab that is on — the host's
    /// `ui.tab_indicator`, off `hello`.
    tab_indicator: sdk.wire.TabIndicator = .block,

    pub fn glyph(u: Ui, nerd_g: []const u8, fallback: []const u8) []const u8 {
        return if (u.ascii or !u.nerd) fallback else nerd_g;
    }

    pub fn chrome(u: Ui) sdk.pane.Ui {
        return .{ .ascii = u.ascii, .nerd = u.nerd, .tab_indicator = u.tab_indicator };
    }
};

// ─── the palette: the host theme's roles, never a terminal index ─────────
//
// An index here paints whatever the terminal happens to call that
// number — which is how the toolbar came to be teal in a theme that has
// no teal in it. Every style below resolves through `hello.palette`.

pub const Styles = struct {
    accent: Style,
    accent_plain: Style,
    muted: Style,
    bold: Style,
    plain: Style,
    chip_style: Style,
    chip_active: Style,
    bulk: Style,
    ok_style: Style,
    warn_style: Style,
    err_style: Style,
    blue: Style,
    star: Style,
    border: Style,

    pub fn of(th: Theme) Styles {
        return .{
            .accent = th.accentText(),
            .accent_plain = th.accentPlain(),
            .muted = th.dimText(),
            .bold = th.bright(),
            .plain = th.text(),
            .chip_style = th.chip(),
            .chip_active = th.chipActive(),
            .bulk = .{ .fg = th.purple, .mods = .{ .bold = true } },
            .ok_style = th.good(),
            .warn_style = th.warn(),
            .err_style = th.bad(),
            .blue = .{ .fg = th.blue },
            .star = .{ .fg = th.yellow, .mods = .{ .bold = true } },
            .border = .{ .fg = th.border },
        };
    }
};

// The chrome's own glyphs and words. This file kept a second copy of
// every one of them — two places for `/ filter` to be spelled, two
// places for a Nerd Font codepoint to be pinned.
const Ch = sdk.pane.chrome;
pub const open_glyph = Ch.open_glyph;
pub const closed_glyph = Ch.closed_glyph;
pub const open_ascii = Ch.open_ascii;
pub const closed_ascii = Ch.closed_ascii;
pub const refresh_nerd = Ch.refresh_nerd;
pub const refresh_ascii = Ch.refresh_ascii;
pub const search_nerd = Ch.search_nerd;
pub const search_ascii = Ch.search_ascii;
pub const help_chip_text = Ch.help_chip_text;
pub const placeholder_unfocused = Ch.placeholder_unfocused;
pub const placeholder_focused = Ch.placeholder_focused;
pub const placeholder_focused_ascii = Ch.placeholder_focused_ascii;

/// The rows the chrome takes above the body, computed once per paint.
pub const Layout = struct {
    header_y: u16 = 0,
    tabs_y: u16 = 1,
    toolbar_y: u16 = 2,
    toolbar_rows: u16 = 1,
    columns_y: ?u16 = null,
    body_y: u16 = 3,
    body_h: u16 = 0,
    /// The list's width (the detail pane starts here when open). It
    /// is one cell narrower when the list carries a scrollbar, so the
    /// bar has a column of its own rather than sitting on the words.
    list_w: u16 = 0,
    /// The list has more rows than the body: the toolkit's scrollbar
    /// goes down column `list_w`. Decided before the column header is
    /// painted, so the header and its rows are laid out to the same
    /// width.
    list_bar: bool = false,
    detail_x: ?u16 = null,
    status_y: u16 = 0,
};

pub const Painter = struct {
    f: *Frame,
    a: *App,
    arena: Allocator,
    ui: Ui,
    /// The host theme's roles, resolved once for the frame.
    s: Styles,
    /// The shared pane chrome — the gutter, the fold row, the detail
    /// panel's `\u{d7}` and scrollbar, the hint row. Both official
    /// integrations paint these from the same code.
    c: Chrome,
    lay: Layout = .{},

    /// One action button as the toolkit's `actionChips` takes it.
    pub const ActionSpec = sdk.pane.chrome.ActionChip(hit.Target);

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

    /// The toolkit's, so a fold mark is the same glyph in every pane
    /// and a host with no Nerd Font gets the same stand-in. This used
    /// to be a byte-for-byte copy of `Painter.chevron` living here,
    /// which is the shape every one of this pane's drifts started as.
    fn chevron(p: *const Painter, open: bool) []const u8 {
        return p.c.chevron(open);
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
        p.c.gutter(.{ .x = 0, .y = 0, .w = 1, .h = p.lay.status_y }, null);
        if (!p.a.hasTabs()) {
            try p.paintEmptyScope();
            try p.paintStatus();
            return;
        }
        try p.paintHeader();
        p.lay.toolbar_y = p.lay.tabs_y + try p.paintTabs();
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
            // A list longer than its body says so, the way the forge
            // pane's does: a thumb over a dim track down the last
            // column. Forty-three rows in a thirty-row body used to
            // say nothing at all about where in them you were.
            if (try p.listOverflows(p.lay.status_y -| (y + 1))) {
                p.lay.list_bar = true;
                p.lay.list_w -|= 1;
            }
            p.lay.columns_y = y;
            try p.paintColumns(y);
            y += 1;
        }
        p.lay.body_y = y;
        p.lay.body_h = p.lay.status_y -| y;
        if (t.cfg.isKanban()) try p.paintKanban() else try p.paintTree();
        if (p.lay.detail_x) |dx| try p.paintDetail(dx);
        // The app-colour stripe down column 0 — the pane's identity, from
        // the toolkit, so every mnml integration wears it the same way.
        // It is painted UNDER the body: a row that puts its own marker
        // there (the cursor's) still wins the cell.
        try p.paintStatus();
        // The overlays, back to front: the last painted is on top.
        if (p.a.comment != null) try p.paintComment();
        if (p.a.jql != null) try p.paintJql();
        if (p.a.transition != null) try p.paintTransition();
        if (p.a.picker != null) try p.paintPicker();
        if (p.a.modal != null) try p.paintModal();
        if (p.a.vars != null) try p.paintVars();
        if (p.a.help) try p.paintHelp();
        // Last of all: the one overlay with something irreversible
        // behind it wins every click while it is up.
        if (p.a.merge != null) try p.paintMergeConfirm();
    }

    /// The merge confirm: what it is about, in its own words.
    fn paintMergeConfirm(p: *Painter) Allocator.Error!void {
        const m = p.a.merge orelse return;
        const w: u16 = @min(p.cols() -| 6, 72);
        const h: u16 = 8;
        if (p.cols() < 24 or p.rows() < h + 2) return;
        const rect: sdk.pane.Rect = .{ .x = (p.cols() -| w) / 2, .y = (p.rows() -| h) / 2, .w = w, .h = h };
        var hbuf: [160]u8 = undefined;
        var bbuf: [160]u8 = undefined;
        var sbuf: [160]u8 = undefined;
        try p.c.confirmBox(
            rect,
            m.confirm.heading(&hbuf),
            &.{
                m.confirm.title,
                m.confirm.branchLine(&bbuf),
                m.confirm.strategyLine(&sbuf),
                "merged by a Claude Code session, not by this pane",
            },
            " Merge ",
            .confirm_ok,
            " Cancel ",
            .confirm_cancel,
            .confirm_body,
        );
    }

    fn paintEmptyScope(p: *Painter) Allocator.Error!void {
        const fam = if (p.a.family) |f| f.label() else "Jira";
        _ = p.put(1, 0, p.cols(), upperOf(p.arena, fam), p.s.accent);
        _ = p.put(1, 2, p.cols() -| 1, "No tabs for this scope.", p.s.bold);
        const cli = if (p.a.family) |f| f.cli() else "work";
        _ = p.putFit(1, 3, p.cols() -| 1, p.fmt("Add a `.tabs` entry whose kind belongs to `--only {s}` in the config, then press r.", .{cli}), p.s.muted);
        _ = p.putFit(1, 4, p.cols() -| 1, "Kinds: work_open · work_reported · work_assigned · work_recently_done · work_recent · work_unified · jql_editable · filter · fix_version_tree · board_active_sprint · board_backlog.", p.s.muted);
        try p.hitAdd(.{ .x = 0, .y = 0, .w = p.cols(), .h = p.rows() -| 1 }, .help_body);
    }

    // ─── the header and the tabs ─────────────────────────────────────

    fn paintHeader(p: *Painter) Allocator.Error!void {
        const y = p.lay.header_y;
        const t = p.a.tab();
        const title = upperOf(p.arena, if (p.a.family) |f| f.label() else "Jira");
        var arena_mask = std.heap.ArenaAllocator.init(p.a.gpa);
        defer arena_mask.deinit();
        const shown = filters.countTrue(try p.a.mask(arena_mask.allocator(), t));
        // What the fetch is doing — the live phase the worker left in
        // `wait_notice` (queued behind N on the broker, waiting on the
        // file bucket, on the wire), or the reason the last one failed.
        // One wording, the toolkit's, on both panes of the family.
        const now_ms = p.a.nowMs();
        const busy = p.a.refresh.busy();
        const fetch: Ch.Fetch = if (busy) blk: {
            const live = p.a.wait_notice.live();
            break :blk switch (live.phase) {
                .queued => .{ .queued = live.behind },
                .waiting => .waiting,
                .idle, .sending => .{ .fetching = .{} },
            };
        } else if (t.last_error.len > 0) .{ .failed = t.last_error } else .idle;
        const sub = if (t.fetched)
            (if (shown == t.issues.len) p.fmt(" ({d})", .{t.issues.len}) else p.fmt(" ({d} of {d})", .{ shown, t.issues.len }))
        else if (busy or t.last_error.len > 0)
            ""
        else
            " (loading…)";
        // A refetch runs on a worker: the rows on screen are the ones
        // from last time, and the count says what the fetch is doing
        // beside it rather than letting them read as current. Same ink
        // as the count, so it is one phrase and the toolkit can clip
        // the pair as one. A failure sits in the same place.
        const sub_all = if (busy or fetch == .failed)
            p.fmt("{s}{s}", .{ sub, p.c.fetchSub(fetch, now_ms) })
        else
            sub;
        // The whole row from the toolkit: the title muted and bold, the
        // count dim beside it, `as of …` after that, and the ladder at
        // the right with `?` at the very end — the refresh chip turning
        // the spinner while a fetch is out, where the host's own panels
        // turn theirs. This pane used to paint its title in the
        // ACCENT, which made the same header two colours depending on
        // which integration you were looking at, and laid its own
        // ladder beside the forge pane's copy of the same geometry.
        const head = try p.c.capsHeader(1, y, title, sub_all, t.fetched_at, p.a.nowSecs(), &.{
            .{ .text = help_chip_text, .target = .{ .chip = .help } },
            .{ .text = p.c.refreshOrBusyChipText(busy, now_ms), .target = .{ .chip = .refresh } },
        });
        if (p.a.selection.count() > 0) {
            _ = p.put(head.x + 1, y, head.edge -| (head.x + 1), p.fmt("{d} selected", .{p.a.selection.count()}), p.s.bulk);
        }
    }

    /// The strip, from the toolkit — the same two rows the forge pane
    /// paints. It used to mark the active tab with mnml's own cursor
    /// `▌`, a glyph doing a second job in a place that is not a list;
    /// the underline says it instead. Returns the rows it used.
    fn paintTabs(p: *Painter) Allocator.Error!u16 {
        const y = p.lay.tabs_y;
        var list: std.ArrayList(Chrome.TabSpec) = .empty;
        for (p.a.tabs, 0..) |*t, i| {
            try list.append(p.arena, .{
                .label = p.fmt(" {d} {s} ", .{ i + 1, t.cfg.name }),
                .target = .{ .tab = @intCast(i) },
                .active = i == p.a.active,
            });
        }
        return p.c.tabStrip(1, y, list.items);
    }

    // ─── the toolbar chips ───────────────────────────────────────────

    /// `pill` marks the search chip: it is the toolkit's filter pill
    /// laid in the toolbar's chip geometry rather than across the pane,
    /// so the glyph, the placeholder and the caret are the ones the
    /// forge pane paints. `text_` is then only how WIDE it is.
    const ChipSpec = struct { text_: []const u8, target: hit.Chip, style: Style, pill: bool = false };

    /// What the search chip shows: the filter's text, or nothing —
    /// the pill supplies its own placeholder either side of the
    /// keyboard, so this must not.
    fn filterText(p: *const Painter) []const u8 {
        const f = p.a.filter orelse return "";
        return f.edit.text();
    }

    /// The widest thing the pill will paint inside itself: the query,
    /// or the placeholder it stands in for while the query is empty.
    /// The chip has to be wide enough for whichever it is, or the pill
    /// refuses the rectangle and the toolbar paints a gap.
    fn filterShown(p: *const Painter) []const u8 {
        const q = p.filterText();
        if (q.len > 0) return q;
        const editing = if (p.a.filter) |f| f.editing else false;
        if (!editing) return placeholder_unfocused;
        return if (p.ui.ascii) placeholder_focused_ascii else placeholder_focused;
    }

    /// The caret's BYTE offset into that text, which is what the pill
    /// wants. The chip used to paste a `▏` on the end of the
    /// string, so the caret was always at the end however far back the
    /// arrow keys had walked it.
    fn filterCaret(p: *const Painter) usize {
        const f = p.a.filter orelse return 0;
        return f.edit.cursor;
    }

    fn chipList(p: *Painter) Allocator.Error![]const ChipSpec {
        const a = p.a;
        const t = a.tab();
        var out: std.ArrayList(ChipSpec) = .empty;
        const arena = p.arena;
        // The search chip IS the toolkit's filter pill, laid in the
        // toolbar's chip geometry rather than across the pane. All this
        // has to decide is how wide it is: the pill puts its glyph one
        // cell in and its text three, and the caret lands on the cell
        // after the text, which the chip's own trailing cell covers.
        const search_w: u16 = 4 + text.width(p.filterShown());
        const search_text = try arena.alloc(u8, search_w);
        @memset(search_text, ' ');
        const search_style: Style = if (a.filter != null) p.s.chip_active else p.s.chip_style;
        if (t.cfg.isKanban()) {
            const board_name = if (t.board_id != 0) try a.boardName(t.board_id) else "default";
            try out.append(arena, .{ .text_ = try chipText(arena, "board", board_name), .target = .board, .style = p.s.chip_style });
            const sprint_name = blk: {
                if (t.selected_sprint) |id| if (t.sprints) |list| for (list) |s| if (s.id == id) break :blk s.name;
                if (t.cfg.kind == .board_backlog) break :blk "backlog";
                if (t.sprints) |list| for (list) |s| if (std.ascii.eqlIgnoreCase(s.state, "active")) break :blk s.name;
                break :blk "active";
            };
            try out.append(arena, .{ .text_ = try chipText(arena, "sprint", sprint_name), .target = .sprint, .style = p.s.chip_style });
            try out.append(arena, .{ .text_ = search_text, .target = .search, .style = search_style, .pill = true });
            // The avatar cluster is painted by paintToolbar itself.
            try out.append(arena, .{ .text_ = " version ", .target = .version, .style = p.s.chip_style });
            try out.append(arena, .{ .text_ = if (t.active_epics.count() > 0) try std.fmt.allocPrint(arena, " epic: {d} ", .{t.active_epics.count()}) else " epic ", .target = .epic, .style = if (t.active_epics.count() > 0) p.s.chip_active else p.s.chip_style });
            try out.append(arena, .{ .text_ = if (t.issue_type.len > 0) try chipText(arena, "type", t.issue_type) else " type ", .target = .type, .style = if (t.issue_type.len > 0) p.s.chip_active else p.s.chip_style });
            try out.append(arena, .{ .text_ = if (t.label.len > 0) try chipText(arena, "label", t.label) else " label ", .target = .label, .style = if (t.label.len > 0) p.s.chip_active else p.s.chip_style });
            if (t.team.len > 0) try out.append(arena, .{ .text_ = try chipText(arena, "team", t.team), .target = .overflow, .style = p.s.chip_active });
            const qf_n = t.active_quick_filters.items.len;
            try out.append(arena, .{ .text_ = if (qf_n > 0) try std.fmt.allocPrint(arena, " quick filters: {d} ", .{qf_n}) else " quick filters ", .target = .quick_filters, .style = if (qf_n > 0) p.s.chip_active else p.s.chip_style });
            const unassigned_on = t.active_assignees.contains(model.unassigned_sentinel);
            try out.append(arena, .{ .text_ = " unassigned ", .target = .unassigned, .style = if (unassigned_on) p.s.chip_active else p.s.chip_style });
            try out.append(arena, .{ .text_ = " settings ", .target = .settings, .style = p.s.chip_style });
            return out.toOwnedSlice(arena);
        }
        try out.append(arena, .{ .text_ = " basic ", .target = .basic, .style = if (!t.show_jql) p.s.chip_active else p.s.chip_style });
        try out.append(arena, .{ .text_ = " jql ", .target = .jql, .style = if (t.show_jql) p.s.chip_active else p.s.chip_style });
        // An editable tab wears its vars: the values the JQL
        // interpolates are what changes, so they are on the header
        // rather than a level down, and `E` (or any of them) opens the
        // editor.
        if (t.cfg.isEditableJql()) {
            for (t.vars) |v| try out.append(arena, .{ .text_ = try chipText(arena, v.name, try varSummary(arena, v)), .target = .vars, .style = p.s.chip_style });
            try out.append(arena, .{ .text_ = " E edit ", .target = .vars, .style = p.s.chip_style });
        }
        try out.append(arena, .{ .text_ = search_text, .target = .search, .style = search_style, .pill = true });
        try out.append(arena, .{ .text_ = try chipText(arena, "assignee", try p.assigneeLabel(t)), .target = .assignee, .style = if (t.active_assignees.count() > 0) p.s.chip_active else p.s.chip_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "type", if (t.issue_type.len > 0) t.issue_type else "—"), .target = .type, .style = if (t.issue_type.len > 0) p.s.chip_active else p.s.chip_style });
        try out.append(arena, .{ .text_ = try chipText(arena, "status", t.scope.label()), .target = .status, .style = if (t.scope != .all) p.s.chip_active else p.s.chip_style });
        if (t.cfg.isFixVersions()) {
            if (fixVersionOf(t.jql)) |v| {
                try out.append(arena, .{ .text_ = try chipText(arena, "fixVersion", v), .target = .fixv_pill, .style = p.s.chip_active });
                try out.append(arena, .{ .text_ = if (p.ui.ascii) " x " else " ⓧ ", .target = .fixv_remove, .style = p.s.chip_style });
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
            if (c.pill) {
                const editing_pill = if (p.a.filter) |f| f.editing else false;
                try p.c.filterPill(
                    .{ .x = x, .y = y, .w = @min(w, max_x -| x), .h = 1 },
                    p.filterText(),
                    p.filterCaret(),
                    editing_pill,
                    .{ .chip = c.target },
                );
            } else {
                _ = p.put(x, y, max_x -| x, c.text_, c.style);
                try p.hitAdd(.{ .x = x, .y = y, .w = @min(w, max_x -| x), .h = 1 }, .{ .chip = c.target });
            }
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
            _ = p.put(x, y, w, p.fmt(" {s} ", .{ini}), if (on) p.s.chip_active else p.s.chip_style);
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
        _ = p.put(x, y, mw, more, p.s.chip_style);
        try p.hitAdd(.{ .x = x, .y = y, .w = mw, .h = 1 }, .{ .chip = .overflow });
        x += mw + 1;
        return .{ .x = x, .y = y, .rows = used };
    }

    // ─── the columns and the tree ────────────────────────────────────

    const ColX = struct { col: config.Column, x: u16, w: u16 };

    /// Whether the active tab's rows outrun a body `h` rows tall.
    fn listOverflows(p: *Painter, h: u16) Allocator.Error!bool {
        if (h == 0) return false;
        const r = (try p.a.treeRows(p.arena)) orelse return false;
        return r.rows.len > h;
    }

    /// Where each column starts at this width — the toolkit's rule for
    /// a narrow table (`sdk.pane.columns`), the one the forge pane's
    /// table follows: the columns give up cells together down to what
    /// still reads, then go whole (ACTIONS first, STATUS last). KEY is
    /// never dropped and never narrower than the longest key on the
    /// tab, so every row keeps the thing it is known by; the summary is
    /// what gets elided.
    fn columnLayout(p: *Painter) Allocator.Error![]const ColX {
        const t = p.a.tab();
        const set = t.cfg.columnSet();
        var specs: [16]sdk.pane.columns.Spec = undefined;
        var widths: [16]u16 = undefined;
        const n = @min(set.len, specs.len);
        // The key cell: chevron and indent (4), the key, a space and
        // the bump star (2) — `paintTree`'s own arithmetic.
        var longest: usize = 0;
        for (t.issues) |iss| longest = @max(longest, sdk.pane.width(iss.key));
        const key_floor: u16 = @intCast(@min(@as(usize, 40), @max(@as(usize, config.Column.key.minWidth()), longest + 7)));
        for (set[0..n], specs[0..n]) |c, *sp| sp.* = switch (c) {
            .summary => .{ .w = c.minWidth(), .rest = true },
            .key => .{ .w = @max(c.width().?, key_floor), .min = key_floor },
            else => .{ .w = c.width().?, .min = c.minWidth(), .drop = c.dropRank() },
        };
        const avail: u16 = p.lay.list_w -| 2;
        sdk.pane.columns.fit(widths[0..n], specs[0..n], avail, 0);
        var out: std.ArrayList(ColX) = .empty;
        var x: u16 = 2;
        for (set[0..n], widths[0..n]) |c, w| {
            if (w == 0 and c != .summary) continue;
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
        var y0 = p.lay.body_y;
        var h = p.lay.body_h;
        const w = p.lay.list_w;
        if (h == 0) return;
        if (t.last_error.len > 0 and t.issues.len == 0) {
            _ = p.putFit(2, y0, w -| 2, p.fmt("error: {s}", .{t.last_error}), p.s.err_style);
            _ = p.putFit(2, y0 + 1, w -| 2, "press r to try again", p.s.muted);
            return;
        }
        if (!t.fetched) {
            _ = p.put(2, y0, w -| 2, "loading…", p.s.muted);
            return;
        }
        const r = (try a.treeRows(p.arena)) orelse return;
        if (r.ticket_count == 0) {
            _ = p.put(2, y0, w -| 2, if (t.issues.len == 0) "no tickets" else "no tickets match the filter", p.s.muted);
            // A windowed tab still has its widen row here, and an empty
            // window is exactly when it is worth pressing — so the
            // message takes the first line and the rows follow.
            if (r.rows.len == 0) return;
            y0 += 1;
            h -|= 1;
            if (h == 0) return;
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
            const base: Style = if (is_cur) p.s.bold else p.s.plain;
            // The toolkit's row ground: the cursor row's fill across the
            // whole row, the app-colour stripe in column 0 (bright on
            // the cursor's) and the row's own hit, in one statement —
            // the same one the forge pane's list paints. The stripe IS
            // the marker, so no row spends a column saying it twice.
            try p.c.rowGround(.{ .x = 0, .y = y, .w = w, .h = 1 }, is_cur, .{ .row = idx });
            switch (row) {
                .group => |g| {
                    const chev = p.chevron(g.expanded);
                    _ = p.put(1, y, 2, chev, p.s.accent_plain);
                    try p.hitAdd(.{ .x = 1, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    const name = if (std.mem.eql(u8, g.status, tree.top_sentinel)) "Release cut" else g.status;
                    _ = p.putFit(3, y, w -| 3, p.fmt("{s} ({d})", .{ name, g.count }), if (is_cur) p.s.accent else p.s.bold);
                },
                .ticket => |tk| {
                    const iss = t.issues[tk.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key);
                    const expanded = st.isExpanded(iss.key);
                    // No chevron once the PRs are known to be none.
                    const show_chev = !(expanded and prs != null and prs.?.len == 0 and false) and (prs == null or prs.?.len > 0 or !expanded);
                    if (show_chev and !(prs != null and prs.?.len == 0)) {
                        _ = p.put(key_c.x + 2, y, 2, p.chevron(expanded), p.s.accent_plain);
                        try p.hitAdd(.{ .x = key_c.x + 2, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    }
                    const selected_bulk = a.isSelected(iss.key);
                    var kx = key_c.x + 4;
                    const key_style: Style = if (selected_bulk) p.s.bulk else if (is_cur) p.s.accent else p.s.accent_plain;
                    kx += p.putFit(kx, y, key_c.w -| 6, iss.key, key_style);
                    if (tk.bumped) kx += p.put(kx + 1, y, 2, if (p.ui.ascii) "*" else "★", p.s.star) + 1;
                    if (selected_bulk) _ = p.put(kx + 1, y, 2, if (p.ui.ascii) "+" else "✓", p.s.bulk);
                    for (layout) |c| switch (c.col) {
                        .key, .summary => {},
                        .status => _ = p.putFit(c.x, y, c.w -| 1, tk.effective_status, statusStyle(p.ui.th, iss, base)),
                        .assignee => _ = p.putFit(c.x, y, c.w -| 1, iss.assigneeName(), base),
                        .reporter => _ = p.putFit(c.x, y, c.w -| 1, iss.reporterName(), base),
                        .priority => _ = p.putFit(c.x, y, c.w -| 1, iss.priority, base),
                        .type => _ = p.putFit(c.x, y, c.w -| 1, iss.issuetype, base),
                        .updated => _ = p.putFit(c.x, y, c.w -| 1, iss.updatedDay(), base),
                        .fix_version => _ = p.putFit(c.x, y, c.w -| 1, if (iss.fix_versions.len > 0) iss.fix_versions[0] else "—", base),
                        .actions => try p.paintActions(c.x, y, p.actionPlan(iss, c.w -| 1).form, tk.issue_idx, iss),
                    };
                    // The summary, with the action buttons after it when
                    // there is no actions column and they fit.
                    const has_actions_col = colOf(layout, .actions) != null;
                    var sw = @min(sum_c.w, w -| sum_c.x);
                    if (!has_actions_col) {
                        // The ladder: the buttons are always there, and
                        // `avail` decides only how much of themselves
                        // they show. This used to drop them whole below
                        // `bw + 12` and clip the summary above it.
                        const plan = p.actionPlan(iss, sw);
                        if (plan.w > 0 and sw > plan.w) {
                            sw -= plan.w + 1;
                            try p.paintActions(sum_c.x + sw + 1, y, plan.form, tk.issue_idx, iss);
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
                    // Every PR folds out to its builds — an open one to
                    // the runs on its branch head, a merged one to the
                    // runs on what landed. Only a PR with no URL has
                    // nothing to look them up on.
                    if (pr.url.len > 0) {
                        _ = p.put(cx, y, 2, p.chevron(st.isPrExpanded(iss.key, pr.id)), p.s.accent_plain);
                        try p.hitAdd(.{ .x = cx, .y = y, .w = 2, .h = 1 }, .{ .chevron = idx });
                    }
                    _ = p.putFit(cx + 2, y, key_c.w -| 8, pr.status, prStyle(p.ui.th, pr.status));
                    // The chips at the right end of the summary:
                    // `[ Open ] [ Review ] [ Merge ]` on an open PR, `[ Open ]`
                    // on a merged or declined one — here every one a hit.
                    const Btn = struct { label: []const u8, which: hit.PrButton };
                    // Chronological: you open a PR, then it is reviewed,
                    // then it merges.
                    const open_set = [_]Btn{ .{ .label = "Open", .which = .open }, .{ .label = "Review", .which = .review }, .{ .label = "Merge", .which = .merge } };
                    const closed_set = [_]Btn{.{ .label = "Open", .which = .open }};
                    const set: []const Btn = if (pr.isOpen()) &open_set else &closed_set;
                    const ready = a.readinessOf(iss.key, pr);
                    var kb: [256]u8 = undefined;
                    const rk = std.fmt.bufPrint(&kb, "{s}\u{0}{s}", .{ iss.key, pr.id }) catch "";
                    // The ladder. The buttons are ALWAYS on the row;
                    // what the width decides is whether they wear their
                    // words. This block used to drop all three below
                    // `bw + 12`, which at 80 columns is every row.
                    var specs: [3]sdk.pane.action.Spec = undefined;
                    for (set, specs[0..set.len]) |b, *sp| sp.* = .{
                        .word = b.label,
                        .state = if (b.which == .open) .idle else a.actions.state(rk, if (b.which == .merge) "merge" else "review"),
                    };
                    var sw = @min(sum_c.w, w -| sum_c.x);
                    const form = sdk.pane.action.formFor(specs[0..set.len], sw, sdk.pane.action.text_floor, a.spin, p.ui.ascii);
                    const bw = sdk.pane.action.runWidth(specs[0..set.len], form, a.spin, p.ui.ascii);
                    if (sw > bw) {
                        var list: std.ArrayList(Painter.ActionSpec) = .empty;
                        for (set, specs[0..set.len]) |b, sp| {
                            // `[ Merge ]` is dim, and not a target at
                            // all, until the pull request may actually
                            // merge — a hover (or a click) then says
                            // which condition does not hold.
                            const blocked = b.which == .merge and sp.state == .idle and !sdk.pane.merge.isPressable(ready);
                            try list.append(p.arena, .{
                                .word = sp.word,
                                .state = sp.state,
                                .target = if (blocked) .{ .merge_blocked = idx } else .{ .pr_button = .{ .row = idx, .which = b.which } },
                                .chip = if (b.which == .merge and sp.state == .idle) sdk.pane.merge.chipOf(p.ui.th, ready) else null,
                            });
                        }
                        sw -= bw + 1;
                        _ = try p.c.actionChips(sum_c.x + sw + 1, y, form, a.spin, list.items);
                    }
                    const title = if (pr.name.len > 0) pr.name else pr.url;
                    _ = p.putFit(sum_c.x, y, sw -| 1, title, base);
                },
                .pr_loading => _ = p.put(key_c.x + 6, y, w -| (key_c.x + 6), "… fetching linked PRs", p.s.muted),
                .pipeline_loading => p.c.buildNote(.{ .x = 0, .y = y, .w = w, .h = 1 }, key_c.x + 10, "fetching builds\u{2026}", false),
                .pipeline_empty => |pe| {
                    const iss = t.issues[pe.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    const meta = if (pe.pr_idx < prs.len) st.pipelineMeta(iss.key, prs[pe.pr_idx].id) else null;
                    const on: []const u8 = if (meta) |m| m.commit[0..@min(m.commit.len, 7)] else "";
                    const note = if (on.len > 0) p.fmt("no build ran on {s}", .{on}) else "no build ran on this commit";
                    p.c.buildNote(.{ .x = 0, .y = y, .w = w, .h = 1 }, key_c.x + 10, note, false);
                },
                .pipeline_error => |pe| {
                    const iss = t.issues[pe.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    const why = if (pe.pr_idx < prs.len) st.pipelineError(iss.key, prs[pe.pr_idx].id) orelse "?" else "?";
                    p.c.buildNote(.{ .x = 0, .y = y, .w = w, .h = 1 }, key_c.x + 10, why, true);
                },
                .pipeline => |pl| {
                    const iss = t.issues[pl.issue_idx];
                    const st = &(t.tree.?);
                    const prs = st.prs(iss.key) orelse continue;
                    if (pl.pr_idx >= prs.len) continue;
                    const list = st.pipelines(iss.key, prs[pl.pr_idx].id) orelse continue;
                    if (pl.pipeline_idx >= list.len) continue;
                    const pipe = list[pl.pipeline_idx];
                    // The toolkit's build line, so this pane and the
                    // Bitbucket one read the same: state, branch, age,
                    // number — and the whole line opens that run.
                    try p.c.buildRow(.{ .x = 0, .y = y, .w = w, .h = 1 }, key_c.x + 10, .{
                        .state = pipe.stateLabel(),
                        .branch = pipe.branch,
                        .created_on = pipe.created_on,
                        .number = pipe.build_number,
                    }, a.nowSecs(), .{ .build_line = idx });
                },
                // The fold row, from the toolkit: `⋯  Show more (N)`
                // with the label in the bright foreground a key wears.
                .show_more => |sm| try p.c.showMoreRow(.{ .x = 0, .y = y, .w = w, .h = 1 }, sum_c.x, sm.hidden, .{ .show_more = idx }),
                // The same fold row, for the tab's date window rather
                // than a count: `⋯  Show older (2 weeks → 30 days)`.
                .show_older => |so| {
                    var from_buf: [16]u8 = undefined;
                    var to_buf: [16]u8 = undefined;
                    const label = p.fmt("Show older ({s} {s} {s})", .{
                        config.windowLabel(&from_buf, so.window),
                        if (p.ui.ascii) "->" else "→",
                        config.windowLabel(&to_buf, so.next),
                    });
                    try p.c.foldRow(.{ .x = 0, .y = y, .w = w, .h = 1 }, sum_c.x, label, .{ .show_older = idx });
                },
            }
        }
        // The bar owns the column the layout reserved for it. The whole
        // track is one hit, so a press or a drag on it turns back into
        // a position through `sdk.pane.scrollAt` — the same bar, and
        // the same arithmetic, as the detail panel's.
        if (p.lay.list_bar) try p.c.scrollbar(.{ .x = w, .y = y0, .w = 1, .h = h }, r.rows.len, t.scroll, h, .list_bar);
    }

    /// The row's action buttons, each wearing what its last press left:
    /// its word, a spinner, the `[ view ]` that focuses the session it
    /// started, or a red cross. The state is keyed by the ticket, so a
    /// refetch that moves the row brings it along.
    fn paintActions(p: *Painter, x0: u16, y: u16, form: sdk.pane.action.Form, issue_idx: usize, iss: model.Issue) Allocator.Error!void {
        const set = dispatch.buttonsForTicket(iss);
        if (set.len == 0) return;
        var list: std.ArrayList(Painter.ActionSpec) = .empty;
        for (set, 0..) |b, bi| {
            try list.append(p.arena, .{
                .word = std.mem.trim(u8, b.label(), "[] "),
                .state = p.a.actions.state(iss.key, b.kind()),
                .target = .{ .action = .{ .issue = @intCast(issue_idx), .button = @intCast(bi) } },
            });
        }
        _ = try p.c.actionChips(x0, y, form, p.a.spin, list.items);
    }

    /// What a row's buttons will take, and which form they will wear —
    /// asked BEFORE the words are painted, so the summary is shortened
    /// rather than painted over.
    ///
    /// The buttons are ALWAYS there: `avail` decides how much of
    /// themselves they show, never whether they exist. This pane used
    /// to clip forty summaries to show forty copies of a word.
    fn actionPlan(p: *Painter, iss: model.Issue, avail: u16) struct { form: sdk.pane.action.Form, w: u16 } {
        const set = dispatch.buttonsForTicket(iss);
        if (set.len == 0) return .{ .form = .icon, .w = 0 };
        var specs: [4]sdk.pane.action.Spec = undefined;
        const n = @min(set.len, specs.len);
        for (set[0..n], specs[0..n]) |b, *sp| sp.* = .{
            .word = std.mem.trim(u8, b.label(), "[] "),
            .state = p.a.actions.state(iss.key, b.kind()),
        };
        const form = sdk.pane.action.formFor(specs[0..n], avail, sdk.pane.action.text_floor, p.a.spin, p.ui.ascii);
        return .{ .form = form, .w = sdk.pane.action.runWidth(specs[0..n], form, p.a.spin, p.ui.ascii) };
    }

    // ─── the kanban ──────────────────────────────────────────────────

    /// The cell the board leaves to the pane's own stripe. One column,
    /// the toolkit's `Painter.gutter` width, so a board-shaped body
    /// wears the same identity as a list-shaped one.
    const kanban_gutter: u16 = 1;

    fn paintKanban(p: *Painter) Allocator.Error!void {
        const a = p.a;
        const t = a.tab();
        const y0 = p.lay.body_y;
        const h = p.lay.body_h;
        const w = p.lay.list_w;
        if (h < 3 or w < 12) return;
        if (t.last_error.len > 0 and t.issues.len == 0) {
            _ = p.putFit(2, y0, w -| 2, p.fmt("error: {s}", .{t.last_error}), p.s.err_style);
            _ = p.putFit(2, y0 + 1, w -| 2, "press r to try again", p.s.muted);
            return;
        }
        if (!t.fetched) {
            _ = p.put(2, y0, w -| 2, "loading…", p.s.muted);
            return;
        }
        const m = try a.mask(p.arena, t);
        const buckets = try kanban.bucket(p.arena, t.issues, m);
        // The board starts one cell in, so the app-colour gutter runs
        // the WHOLE height of the pane rather than stopping where the
        // header does. A stripe that ends a third of the way down
        // reads as two panes stacked; the columns' own boxes used to
        // paint straight over it, and every card then carried its own
        // little `▌` as if the pane's identity had moved onto them.
        const board_x = kanban_gutter;
        const avail = w -| board_x;
        const col_w: u16 = avail / kanban.count;
        var c: usize = 0;
        while (c < kanban.count) : (c += 1) {
            const cx: u16 = board_x + @as(u16, @intCast(c * col_w));
            const inner_w = col_w -| 2;
            const col: kanban.Col = @enumFromInt(c);
            try p.box(.{ .x = cx, .y = y0, .w = col_w, .h = h }, p.fmt(" {s} ({d}) ", .{ col.title(), buckets[c].len }), p.s.border);
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
                const base: Style = if (is_cur) p.s.bold else p.s.plain;
                const ix = cx + 1;
                // The toolkit's row ground under every line a card owns:
                // the cursor card's fill across the card's width, the
                // app-colour stripe down its left edge, and the card's
                // own hit. `.blank` is the gap BETWEEN cards and belongs
                // to no card, so it stays empty.
                if (ln.line != .blank) {
                    try p.c.rowGround(.{ .x = ix, .y = y, .w = inner_w, .h = 1 }, is_cur, .{ .card = @intCast(ln.issue) });
                }
                switch (ln.line) {
                    .head => {
                        _ = p.put(ix + 1, y, 2, p.chevron(a.isCardExpanded(iss.key)), p.s.accent_plain);
                        try p.hitAdd(.{ .x = ix, .y = y, .w = 3, .h = 1 }, .{ .card_chevron = @intCast(ln.issue) });
                        var kx = ix + 3;
                        kx += p.put(kx, y, 2, kanban.typeGlyph(iss.issuetype, p.ui.ascii or !p.ui.nerd), p.s.muted) + 1;
                        const key_style: Style = if (a.isSelected(iss.key)) p.s.bulk else if (is_cur) p.s.accent else p.s.accent_plain;
                        kx += p.putFit(kx, y, inner_w -| (kx - ix), iss.key, key_style);
                        if (a.isSelected(iss.key)) _ = p.put(kx + 1, y, 2, if (p.ui.ascii) "+" else "✓", p.s.bulk);
                    },
                    .summary => |s| {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, s, base);
                    },
                    .assignee => |s| {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, p.fmt("· {s}", .{s}), p.s.muted);
                    },
                    .labels => {
                        // `#label` chips, four at most, the reference's way.
                        var lx = ix + 3;
                        for (iss.labels, 0..) |l, lidx| {
                            if (lidx == 4) {
                                _ = p.put(lx, y, inner_w -| (lx - ix), p.fmt("+{d}", .{iss.labels.len - 4}), p.s.muted);
                                break;
                            }
                            const chip = p.fmt("#{s}", .{l});
                            if (lx + text.width(chip) > ix + inner_w) break;
                            lx += p.put(lx, y, inner_w -| (lx - ix), chip, p.s.accent_plain) + 1;
                        }
                    },
                    .hint => |hint_line| {
                        _ = p.putFit(ix + 3, y, inner_w -| 3, hint_line, p.s.muted);
                    },
                    .actions => try p.paintActions(ix + 3, y, p.actionPlan(iss, inner_w -| 3).form, ln.issue, iss),
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
        p.c.vrule(dx, y0, h, p.s.border);
        var y = y0;
        const panel: hit.Rect = .{ .x = dx, .y = y0, .w = w, .h = h };
        const x = dx + 1;
        const iw = w -| 3;
        _ = p.put(x, y0, iw, "DETAIL", p.s.accent);
        // The panel's own door for the pointer: the body takes the
        // wheel, the `×` in the corner closes it (Esc still does too).
        try p.c.detailPanel(panel, .detail, .detail_close);
        const idx = (try a.focusedIssueIdx(p.arena)) orelse {
            _ = p.put(x, y0 + 1, iw, "no ticket under the cursor", p.s.muted);
            return;
        };
        const iss = a.tab().issues[idx];
        const lines = try p.detailLines(iss, iw);
        const avail: usize = h -| 1;
        a.details_lines = lines.len;
        a.details_rows = @intCast(avail);
        var start: usize = a.details_scroll;
        if (start > lines.len -| avail) start = lines.len -| avail;
        a.details_scroll = @intCast(start);
        var i = start;
        y = y0 + 1;
        while (i < lines.len and y < y0 + h) : ({
            i += 1;
            y += 1;
        }) _ = p.put(x, y, iw, lines[i].s, lines[i].style);
        // A scrollbar that means something: the thumb says where you
        // are, and a press or a drag on the track goes there.
        if (lines.len > avail) {
            const bar: hit.Rect = .{ .x = panel.right() -| 1, .y = y0 + 1, .w = 1, .h = h -| 1 };
            try p.c.scrollbar(bar, lines.len, start, avail, .detail_bar);
        }
    }

    const Line = struct { s: []const u8, style: Style = .{} };

    fn detailLines(p: *Painter, iss: model.Issue, w: u16) Allocator.Error![]const Line {
        const a = p.a;
        var out: std.ArrayList(Line) = .empty;
        const arena = p.arena;
        var fb: [512]u8 = undefined;
        try out.append(arena, .{ .s = try arena.dupe(u8, text.fit(&fb, p.fmt("{s}  {s}", .{ iss.key, iss.summary }), w)), .style = p.s.bold });
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
        for (fields) |f| try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "{s:>10}: {s}", .{ f.label, f.value }), .style = p.s.plain });
        try out.append(arena, .{ .s = "" });
        const d = a.detailOf(iss.key);
        if (d == null and a.detailFetching(iss.key)) {
            // On the wire: the toolkit's spinner and words, so a slow
            // site reads as busy, not as a key that was not heard.
            try out.append(arena, .{ .s = std.mem.trimStart(u8, p.c.fetchSub(.{ .fetching = .{} }, a.nowMs()), " "), .style = p.s.muted });
        }
        if (d) |det| {
            if (det.error_text.len > 0) {
                try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "detail fetch failed: {s}", .{det.error_text}), .style = p.s.err_style });
            } else {
                const w_line = if (det.watching)
                    try std.fmt.allocPrint(arena, "{s:>10}: {s} watching ({d} total)", .{ "watcher", if (p.ui.ascii) "*" else "★", det.watch_count })
                else
                    try std.fmt.allocPrint(arena, "{s:>10}: {s} not watching ({d} total)", .{ "watcher", if (p.ui.ascii) "o" else "☆", det.watch_count });
                try out.append(arena, .{ .s = w_line, .style = if (det.watching) p.s.star else p.s.muted });
                try out.append(arena, .{ .s = "" });
                try out.append(arena, .{ .s = "── description", .style = p.s.muted });
                const desc = if (std.mem.trim(u8, det.description, " \n").len > 0) det.description else "(no description)";
                for (try text.wrap(arena, desc, w)) |l| try out.append(arena, .{ .s = l });
                try out.append(arena, .{ .s = "" });
                try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "── comments ({d})", .{det.comments.len}), .style = p.s.muted });
                if (det.comments.len == 0) try out.append(arena, .{ .s = "(no comments)", .style = p.s.muted });
                for (det.comments) |c| {
                    try out.append(arena, .{ .s = try std.fmt.allocPrint(arena, "{s} · {s}", .{ c.author, text.dayOf(c.created) }), .style = p.s.accent_plain });
                    for (try text.wrap(arena, c.body, w)) |l| try out.append(arena, .{ .s = l });
                    try out.append(arena, .{ .s = "" });
                }
            }
        } else {
            try out.append(arena, .{ .s = "loading the detail…", .style = p.s.muted });
        }
        return out.toOwnedSlice(arena);
    }

    // ─── the last row ────────────────────────────────────────────────

    fn paintStatus(p: *Painter) Allocator.Error!void {
        const a = p.a;
        const y = p.lay.status_y;
        const w = p.cols();
        var x: u16 = 1;
        var status: []const u8 = a.status.items;
        const hint: []const u8 = blk: {
            if (a.help) break :blk "j/k scroll · Esc close";
            if (a.modal != null) break :blk "j/k · PgUp/PgDn scroll · Esc close";
            if (a.comment != null) break :blk "typing comment · Enter newline · Enter on an empty line or Ctrl+S sends · Esc cancel";
            if (a.picker) |pk| break :blk if (pk.kind.multi()) "type to filter · ↑↓ move · Space toggle · Enter commit · Esc cancel" else "type to filter · ↑↓ move · Enter commit · Esc cancel";
            if (a.transition != null) break :blk "1-9 jump · ↑↓/jk move · Enter commit · Esc cancel";
            if (a.jql != null) break :blk "type to edit · Enter run · Esc cancel · Ctrl+A/E ends · Alt+←/→ words";
            if (a.filter) |f| if (f.editing) break :blk "type to filter · Enter commit · Esc cancel";
            if (!a.hasTabs()) break :blk "r refresh · q quit";
            break :blk "";
        };
        // A dim `[ Merge ]` owes the reader a reason, and the hint row
        // is where it goes: the pointer is already there.
        if (a.hoverNote().len > 0) {
            if (status.len > 0) x += p.putFit(x, y, w -| x, status, p.s.plain) + 2;
            _ = p.putFit(x, y, w -| x, a.hoverNote(), p.s.warn_style);
            return;
        }
        // A button that failed keeps its reason where it can be read:
        // the status moves on, the row's cross does not.
        if (a.hasTabs() and status.len == 0) {
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            if (a.focusedKey(scratch.allocator()) catch null) |k| {
                const iss = for (a.tabConst().issues) |i| {
                    if (std.mem.eql(u8, i.key, k)) break i;
                } else null;
                if (iss) |i| for (dispatch.buttonsForTicket(i)) |b| {
                    const e = a.actions.get(i.key, b.kind());
                    if (e.state != .failed or e.detail.len == 0) continue;
                    status = p.fmt("{s}: {s}", .{ i.key, e.detail });
                    break;
                };
            }
        }
        if (hint.len > 0) {
            if (status.len > 0) x += p.putFit(x, y, w -| x, status, p.s.plain) + 2;
            _ = p.putFit(x, y, w -| x, hint, p.s.muted);
            return;
        }
        // The section help row, from the toolkit: the bindings that
        // apply, each entry a click target that runs what its key runs,
        // and the `? keys` that opens the sheet last — where the
        // drop-from-the-front rule leaves it standing however narrow the
        // pane gets.
        //
        // It was hand-rolled here, with its own room-for-`? keys`
        // arithmetic and its own skip so the row did not end
        // `? keys · ? keys`. The toolkit does both, and the forge
        // pane now gets the same row out of the same code.
        const list = try keymap.hints(p.arena, a.context());
        var entries: std.ArrayList(Chrome.HintSpec) = .empty;
        for (list) |b| {
            var kb: [16]u8 = undefined;
            try entries.append(p.arena, .{
                .key = try p.arena.dupe(u8, keymap.displayKey(&kb, b.keys[0])),
                .title = if (b.short.len > 0) b.short else b.label,
                .target = .{ .hint = b.action },
            });
        }
        try p.c.hintRow(y, status, entries.items);
    }

    // ─── the overlays ────────────────────────────────────────────────

    /// A bordered box with its title in the top edge; the inside is
    /// blanked so what was under it does not show through. The
    /// toolkit's frame, so it is the same box the bitbucket pane opens.
    fn box(p: *Painter, r: Rect, title: []const u8, style: Style) Allocator.Error!void {
        p.c.frameTitled(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, style, title, p.s.accent);
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
        try p.box(r, title, p.s.border);
        try p.hitAdd(r, .picker_body);
        const ix = r.x + 2;
        const iw = r.w -| 4;
        // The filter line.
        const glyph = if (p.ui.ascii or !p.ui.nerd) search_ascii else search_nerd;
        var fx = ix;
        fx += p.put(fx, r.y + 1, iw, glyph, p.s.accent_plain) + 1;
        if (pk.filter.items.len > 0) {
            fx += p.put(fx, r.y + 1, iw -| (fx - ix), pk.filter.items, p.s.plain);
        } else fx += p.put(fx, r.y + 1, iw -| (fx - ix), if (p.ui.ascii) placeholder_focused_ascii else placeholder_focused, p.s.muted);
        _ = p.put(fx, r.y + 1, 1, "▏", p.s.accent_plain);
        if (!pk.loaded) {
            _ = p.put(ix, r.y + 3, iw, "loading…", p.s.muted);
            return;
        }
        if (pk.error_text.len > 0) {
            for (try text.wrap(p.arena, pk.error_text, iw), 0..) |l, i| {
                if (r.y + 3 + i >= r.bottom() - 2) break;
                _ = p.put(ix, @intCast(r.y + 3 + i), iw, l, p.s.err_style);
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
            // The toolkit's row ground, the same one the list rows
            // wear: the cursor's row is a filled band, not a glyph in
            // the margin.
            try p.c.rowGround(.{ .x = r.x + 1, .y = y, .w = r.w -| 2, .h = 1 }, is_cur, .{ .picker_row = @intCast(vis[k]) });
            var x = ix + 2;
            if (pk.kind.multi()) {
                const on = pk.isChecked(it.id);
                x += p.put(x, y, 4, if (on) "[x] " else "[ ] ", if (on) p.s.accent_plain else p.s.muted);
            }
            _ = p.putFit(x, y, iw -| (x - ix), it.label, if (is_cur) p.s.bold else p.s.plain);
        }
        if (vis.len == 0 and pk.error_text.len == 0) _ = p.put(ix, list_y, iw, "nothing matches", p.s.muted);
        const hint = if (pk.kind.multi()) "type to filter · ↑↓ move · Space toggle · Enter commit · Esc cancel" else "type to filter · ↑↓ move · Enter commit · Esc cancel";
        _ = p.putFit(ix, r.bottom() - 2, iw, hint, p.s.muted);
    }

    fn paintTransition(p: *Painter) Allocator.Error!void {
        const tp = &(p.a.transition.?);
        const r = p.centred(60, 14);
        const title = if (tp.targets > 1) p.fmt(" transition {s} (+{d} more) ", .{ tp.key, tp.targets - 1 }) else p.fmt(" transition {s} ", .{tp.key});
        try p.box(r, title, p.s.border);
        try p.hitAdd(r, .picker_body);
        const ix = r.x + 1;
        const iw = r.w -| 2;
        const list = tp.transitions orelse {
            _ = p.put(ix + 1, r.y + 1, iw, "loading…", p.s.muted);
            return;
        };
        var y = r.y + 1;
        for (list, 0..) |t, i| {
            if (y >= r.bottom() - 3) break;
            const is_cur = i == tp.selected;
            try p.c.rowGround(.{ .x = ix, .y = y, .w = iw, .h = 1 }, is_cur, .{ .picker_row = @intCast(i) });
            const line = p.fmt("{d}. {s}  → {s}", .{ i + 1, t.name, t.to_name });
            _ = p.putFit(ix + 2, y, iw -| 2, line, if (is_cur) p.s.bold else p.s.plain);
            y += 1;
        }
        if (list.len == 0 and tp.error_text.len == 0) _ = p.put(ix + 2, r.y + 1, iw, "no transitions from here", p.s.muted);
        if (tp.error_text.len > 0) _ = p.putFit(ix + 2, r.bottom() - 3, iw -| 2, tp.error_text, p.s.err_style);
        _ = p.putFit(ix + 2, r.bottom() - 2, iw -| 2, "1-9 jump · ↑↓/jk move · Enter commit · Esc cancel", p.s.muted);
    }

    /// The vars editor. One line per value under its var's name, an
    /// `+ add` line under a list, and the line under the cursor turns
    /// into a text field when it is being typed into.
    fn paintVars(p: *Painter) Allocator.Error!void {
        const e = &(p.a.vars.?);
        const rows_needed: u16 = @intCast(@min(@as(usize, 40), e.rows.items.len + 6));
        const r = p.centred(62, @max(rows_needed, 8));
        try p.box(r, p.fmt(" vars — {s} ", .{e.tab_name}), p.s.border);
        try p.hitAdd(r, .vars_body);
        const ix = r.x + 2;
        const iw = r.w -| 4;
        const list_y = r.y + 1;
        const list_h: usize = r.h -| 4;
        const start = if (e.cursor >= list_h) e.cursor + 1 - list_h else 0;
        var y = list_y;
        var i = start;
        while (i < e.rows.items.len and y < list_y + list_h) : ({
            i += 1;
            y += 1;
        }) {
            const row = e.rows.items[i];
            const is_cur = i == e.cursor;
            const typing = is_cur and e.edit != null;
            switch (row) {
                .name => |vi| {
                    _ = p.putFit(ix, y, iw, e.boxes.items[vi].name, p.s.bold);
                    continue;
                },
                .value => |v| {
                    // The toolkit's row ground: the cursor's row is a
                    // filled band with the stripe down its left edge.
                    try p.c.rowGround(.{ .x = r.x + 1, .y = y, .w = r.w -| 2, .h = 1 }, is_cur, .{ .vars_row = @intCast(i) });
                    if (typing) {
                        try p.paintVarField(ix + 2, y, iw -| 2, e);
                    } else {
                        const txt = e.valueText(v.v, v.i);
                        _ = p.putFit(ix + 2, y, iw -| 2, if (txt.len > 0) txt else "(empty)", if (txt.len > 0) p.s.plain else p.s.muted);
                    }
                },
                .add => {
                    try p.c.rowGround(.{ .x = r.x + 1, .y = y, .w = r.w -| 2, .h = 1 }, is_cur, .{ .vars_row = @intCast(i) });
                    if (typing) {
                        try p.paintVarField(ix + 2, y, iw -| 2, e);
                    } else _ = p.putFit(ix + 2, y, iw -| 2, "+ add", p.s.muted);
                },
            }
        }
        if (e.error_text.len > 0) _ = p.putFit(ix, r.bottom() - 3, iw, e.error_text, p.s.err_style);
        const save = " s save ";
        const sw = text.width(save);
        _ = p.put(r.right() -| (sw + 2), r.bottom() - 2, sw, save, p.s.chip_style);
        try p.hitAdd(.{ .x = r.right() -| (sw + 2), .y = r.bottom() - 2, .w = sw, .h = 1 }, .vars_save);
        // The save is the chip beside this row, so the words here are the
        // ones that have nowhere else to be said.
        _ = p.putFit(ix, r.bottom() - 2, iw -| (sw + 2), "↑↓ move · ⏎ edit · a add · d remove · Esc cancel", p.s.muted);
    }

    /// The line being typed into, with the caret where the cursor is.
    fn paintVarField(p: *Painter, x: u16, y: u16, w: u16, e: *const varsedit.Editor) Allocator.Error!void {
        const t = &(e.edit.?);
        const txt = t.text();
        _ = p.put(x, y, w, txt, p.s.plain);
        const caret_x = x + text.width(txt[0..@min(t.cursor, txt.len)]);
        if (caret_x < x + w) _ = p.put(caret_x, y, 1, "▏", p.s.accent_plain);
    }

    fn paintModal(p: *Painter) Allocator.Error!void {
        const m = &(p.a.modal.?);
        const r = p.centred(@max(p.cols() * 4 / 5, 40), @max(p.rows() * 4 / 5, 8));
        try p.box(r, p.fmt(" {s} ", .{m.key}), p.s.border);
        try p.hitAdd(r, .modal_body);
        const close_t = " × ";
        const cx = r.right() -| (text.width(close_t) + 1);
        _ = p.put(cx, r.y + 1, text.width(close_t), if (p.ui.ascii) " x " else close_t, p.s.chip_style);
        try p.hitAdd(.{ .x = cx, .y = r.y + 1, .w = text.width(close_t), .h = 1 }, .modal_close);
        const ix = r.x + 1;
        const iw = r.w -| 2;
        if (m.error_text.len > 0) {
            _ = p.putFit(ix + 1, r.y + 1, iw -| 2, p.fmt("could not load {s}: {s}", .{ m.key, m.error_text }), p.s.err_style);
            return;
        }
        const v = m.data orelse {
            _ = p.put(ix + 1, r.y + 1, iw, "loading…", p.s.muted);
            return;
        };
        const summary = try model.fieldDisplay(p.arena, v, "summary");
        const status = try model.fieldDisplay(p.arena, v, "status");
        _ = p.putFit(ix + 1, r.y + 1, cx -| (ix + 2), p.fmt("{s} · {s}  [{s}]", .{ m.key, summary, status }), p.s.bold);
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
                try right.append(p.arena, .{ .s = label, .style = p.s.accent_plain });
                for (try text.wrap(p.arena, value, right_w)) |l| try right.append(p.arena, .{ .s = l });
                try right.append(p.arena, .{ .s = "" });
                continue;
            }
            const head = try std.fmt.allocPrint(p.arena, "{s} : ", .{padRight(p.arena, label, label_w)});
            const wrapped = try text.wrap(p.arena, value, @max(left_w -| @as(u16, @intCast(head.len)), 8));
            if (wrapped.len == 0) {
                try left.append(p.arena, .{ .s = head, .style = p.s.muted });
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
        _ = p.putFit(ix + 1, r.bottom() - 1, iw -| 2, " j/k scroll · Esc close ", p.s.muted);
    }

    fn paintJql(p: *Painter) Allocator.Error!void {
        const e = &(p.a.jql.?);
        const wrap_w: u16 = @intCast(p.a.jqlWrapWidth());
        const bw = wrap_w + 2;
        const lines = try wrapHard(p.arena, e.text(), wrap_w);
        const bh: u16 = @intCast(@min(@max(lines.len, 1) + 2, @as(usize, p.rows() -| 4)));
        const r: Rect = .{ .x = (p.cols() -| bw) / 2, .y = p.lay.status_y -| (bh + 1), .w = bw, .h = bh };
        try p.box(r, " JQL — type to edit · Enter run · Esc cancel ", p.s.border);
        try p.hitAdd(r, .jql_body);
        const caret = e.cursorCodepoints();
        var cp: usize = 0;
        for (lines, 0..) |l, li| {
            if (li + 1 >= bh - 1) break;
            const y: u16 = @intCast(r.y + 1 + li);
            _ = p.put(r.x + 1, y, wrap_w, l, p.s.plain);
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
        try p.box(r, p.fmt(" comment on {s} ", .{c.key}), p.s.border);
        try p.hitAdd(r, .comment);
        const iw = r.w -| 2;
        const lines = try wrapHard(p.arena, c.edit.text(), iw);
        const caret = c.edit.cursorCodepoints();
        var cp: usize = 0;
        var y = r.y + 1;
        for (lines, 0..) |l, li| {
            if (y >= r.bottom() - 1) break;
            _ = p.put(r.x + 1, y, iw, l, p.s.plain);
            const n = std.unicode.utf8CountCodepoints(l) catch l.len;
            if (caret >= cp and caret <= cp + n and (caret < cp + n or li + 1 == lines.len)) {
                const cx: u16 = @intCast(r.x + 1 + @min(caret - cp, iw -| 1));
                _ = p.put(cx, y, 1, if (caret < cp + n) codepointAt(l, caret - cp) else " ", .{ .mods = .{ .reverse = true } });
            }
            cp += n + 1;
            y += 1;
        }
        if (lines.len == 0) _ = p.put(r.x + 1, r.y + 1, 1, " ", .{ .mods = .{ .reverse = true } });
        if (c.error_text.len > 0) _ = p.putFit(r.x + 1, r.bottom() - 2, iw, c.error_text, p.s.err_style);
        _ = p.putFit(r.x + 1, r.bottom() - 1, iw, if (c.posting) " sending… " else " Enter newline · Enter on an empty line or Ctrl+S sends · Esc cancel ", p.s.muted);
    }

    /// The key sheet: the family's one component
    /// (`sdk.pane.chrome.Painter.keySheet`), fed the bindings that
    /// apply here by section, then the overlays' own keys to read.
    fn paintHelp(p: *Painter) Allocator.Error!void {
        const Row = sdk.pane.chrome.SheetRow(hit.Target);
        var sheet: std.ArrayList(Row) = .empty;
        const active = try keymap.active(p.arena, p.a.context());
        inline for (@typeInfo(keymap.Section).@"enum".fields) |sf| {
            const section: keymap.Section = @enumFromInt(sf.value);
            var any = false;
            for (active) |b| if (b.section == section) {
                if (!any) try sheet.append(p.arena, .{ .section = section.title() });
                any = true;
                // A row of the sheet runs what its chord runs: reading
                // the keys and using them are the same gesture.
                try sheet.append(p.arena, .{ .chord = try sdk.pane.keysheet.chords(p.arena, b.keys), .label = b.label, .target = .{ .help_row = b.action } });
            };
        }
        try sheet.append(p.arena, .{ .section = "overlays" });
        for (keymap.modal_rows) |m| try sheet.append(p.arena, .{ .chord = m.keys, .label = m.label });
        try p.c.keySheet(sheet.items, &p.a.help_scroll, .help_body);
    }
};

// ─── styles by state ─────────────────────────────────────────────────────

fn statusStyle(th: Theme, iss: model.Issue, base: Style) Style {
    var s = base;
    const role = th.ticketStatus(iss.status_category);
    s.fg = role.fg;
    s.mods.dim = role.mods.dim;
    return s;
}

/// A pull request's state, in the one mapping every mnml pane that
/// shows a PR uses (`sdk.pane.Theme.prState`): green open, purple
/// merged, red declined.
fn prStyle(th: Theme, status: []const u8) Style {
    return th.prState(status);
}

// ─── small text helpers ──────────────────────────────────────────────────

/// ` key: value ` — mnml's mode chip.
pub fn chipText(arena: Allocator, key: []const u8, value: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, " {s}: {s} ", .{ key, value });
}

/// What a var chip says: the one value, or how many are in the list and
/// the first of them — the header has room for the shape, not the set.
fn varSummary(arena: Allocator, v: config.Var) Allocator.Error![]const u8 {
    if (v.values.len == 0) return if (v.value.len > 0) v.value else "—";
    if (v.values.len == 1) return v.values[0];
    return std.fmt.allocPrint(arena, "{s} +{d}", .{ v.values[0], v.values.len - 1 });
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

/// `MG` from `Mary Goode`; one letter for a single name.
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
pub fn paintNotice(f: *Frame, th: Theme, title: []const u8, lines: []const []const u8, hint: []const u8) void {
    const s = Styles.of(th);
    f.clear(.{ .fg = th.fg, .bg = th.bg });
    _ = f.text(1, 0, f.cols -| 1, title, s.accent);
    var y: u16 = 2;
    for (lines) |l| {
        if (y + 1 >= f.rows) break;
        _ = f.text(1, y, f.cols -| 1, l, if (l.len > 0 and l[0] == ' ') s.muted else s.plain);
        y += 1;
    }
    if (f.rows > 0) _ = f.text(1, f.rows - 1, f.cols -| 1, hint, s.muted);
}

/// Paint `a` onto `f` and fill its hit map.
pub const Chrome = sdk.pane.Painter(hit.Target);

pub fn paint(arena: Allocator, f: *Frame, a: *App, ui: Ui) Allocator.Error!void {
    var p: Painter = .{
        .f = f,
        .a = a,
        .arena = arena,
        .ui = ui,
        .s = Styles.of(ui.th),
        .c = .{ .f = f, .gpa = a.gpa, .arena = arena, .hits = &a.hits, .th = ui.th, .ui = ui.chrome() },
    };
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

/// One cell of the painted frame — the only way a test sees a colour,
/// since the row dump carries none.
fn cellAt(f: *const Frame, x: u16, y: u16) sdk.Slot {
    return f.slots[@as(usize, y) * f.cols + x];
}

fn bgAt(f: *const Frame, x: u16, y: u16) ?sdk.Color {
    return cellAt(f, x, y).style.bg;
}

fn colOfText(arena: Allocator, f: *const Frame, y: u16, needle: []const u8) Allocator.Error!?u16 {
    const row = try rowText(arena, f, y);
    const byte = std.mem.indexOf(u8, row, needle) orelse return null;
    return @intCast(std.unicode.utf8CountCodepoints(row[0..byte]) catch byte);
}

test "initials, the fixVersion pill's value and the hard wrap" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("MG", initials(&buf, "Mary Goode"));
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
    // While a refetch is out the header says what it is doing — the
    // forge pane's words, from the SDK — and the refresh chip turns
    // the host's ring; queued behind the broker says how many ahead.
    {
        a.refresh.running = true;
        a.wait_notice.setPhase(.queued, 2);
        _ = arena.reset(.retain_capacity);
        try paint(ar, &f, a, .{});
        const busy_row = try rowText(ar, &f, 0);
        try testing.expect(std.mem.indexOf(u8, busy_row, "queued behind 2 requests") != null);
        try testing.expect(std.mem.indexOf(u8, busy_row, Ch.refresh_nerd) == null);
        a.wait_notice.setPhase(.sending, 0);
        _ = arena.reset(.retain_capacity);
        try paint(ar, &f, a, .{});
        const sending_row = try rowText(ar, &f, 0);
        try testing.expect(std.mem.indexOf(u8, sending_row, "fetching\u{2026}") != null);
        try testing.expect(std.mem.indexOf(u8, sending_row, "refreshing") == null);
        a.refresh.running = false;
        a.wait_notice.setPhase(.idle, 0);
        _ = arena.reset(.retain_capacity);
        try paint(ar, &f, a, .{});
        const back = try rowText(ar, &f, 0);
        try testing.expect(std.mem.indexOf(u8, back, "fetching") == null);
        try testing.expect(std.mem.indexOf(u8, back, Ch.refresh_nerd) != null);
    }
    try testing.expect(std.mem.startsWith(u8, r0, "▌JIRA WORK (3)"));
    try testing.expect(std.mem.endsWith(u8, r0, " ?"));
    try testing.expectEqualStrings("\u{258c} 1 Assigned   2 Recently Done", try rowText(ar, &f, 1));
    // The strip's indicator: the default `block` under the tab that
    // is on, and no `▌` mark beside the label any more. The bar owns
    // the word — from under the `1`, not under the label's leading
    // pad — plus half of the three-cell gap to `2`, so twelve cells
    // from column 2; nothing before it and nothing after it, since
    // `block` lays no track.
    const rule = std.mem.trimEnd(u8, try rowText(ar, &f, 2), " ");
    try testing.expectEqualStrings("\u{258c} " ++ ("\u{2580}" ** 12), rule);
    try testing.expect(std.mem.indexOf(u8, rule, "\u{2501}") == null);
    const r2 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.indexOf(u8, r2, " basic ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " assignee: All ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " status: All") != null);
    try testing.expect(std.mem.indexOf(u8, r0, "\u{eb37}") != null);
    // The caps header is the TOOLKIT's, not a copy of it: the title in
    // `label()` and the ladder ending in the refresh chip then `?`,
    // both on the chip ground. Asserted through `sdk.pane.expect`, the
    // same function the forge pane's own suite calls, so the two
    // families cannot drift into checking two different things.
    const ui: Ui = .{};
    try sdk.pane.expect.capsTitleInk(&f, ui.th, 1, 0, "JIRA WORK");
    try sdk.pane.expect.headerLadderTail(&f, ui.th, 0, ui.nerd, ui.ascii);
    try testing.expect(std.mem.indexOf(u8, r2, "/ filter") != null);
    const r3 = try rowText(ar, &f, 4);
    try testing.expect(std.mem.startsWith(u8, r3, "▌ KEY"));
    try testing.expect(std.mem.indexOf(u8, r3, "SUMMARY") != null);
    // The first group is the cursor: marker, chevron, name and count.
    const r4 = try rowText(ar, &f, 5);
    try testing.expect(std.mem.startsWith(u8, r4, "\u{258c}\u{F47C} In PR Review (1)"));
    // ENG-2 under it with its two PRs, then the buttons.
    const r5 = try rowText(ar, &f, 6);
    try testing.expect(std.mem.indexOf(u8, r5, "ENG-2") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "In PR Review") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "Ada Lovelace") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "Card form validates on blur") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "[\u{f06e} Review]") != null);
    const r6 = try rowText(ar, &f, 7);
    try testing.expect(std.mem.indexOf(u8, r6, "MERGED") != null);
    try testing.expect(std.mem.indexOf(u8, r6, "[\u{f03cc} Open]") != null);
    try testing.expect(std.mem.indexOf(u8, r6, "[\u{f062d} Merge]") == null);
    const r7 = try rowText(ar, &f, 8);
    try testing.expect(std.mem.indexOf(u8, r7, "OPEN") != null);
    try testing.expect(std.mem.indexOf(u8, r7, "[\u{f03cc} Open] [\u{f06e} Review] [\u{f062d} Merge]") != null);
    const merge_x = (try colOfText(ar, &f, 8, "[\u{f062d} Merge]")).?;
    // Nothing has judged this pull request, so `[ Merge ]` is dim and
    // is NOT a `pr_button`: a stray click there cannot merge anything.
    // It still answers, with the reason it is dim.
    try testing.expectEqual(hit.Target{ .merge_blocked = 3 }, a.hits.at(merge_x + 2, 8).?);
    try testing.expectEqual(hit.Target{ .pr_button = .{ .row = 3, .which = .open } }, a.hits.at((try colOfText(ar, &f, 8, "[\u{f03cc} Open]")).? + 2, 8).?);
    // The hint row comes from the bindings, not a string, and it is the
    // toolkit's: entries shed from the FRONT, so the ones that always
    // apply survive a narrow pane and `? keys` — the door to the rest
    // — is the last thing standing.
    const last = std.mem.trimEnd(u8, try rowText(ar, &f, 39), " ");
    try testing.expect(std.mem.indexOf(u8, last, "a assignee · S select · f fix version") != null);
    try testing.expect(std.mem.endsWith(u8, last, "? keys"));
    // Every painted row is a hit, and a click on the ticket's row
    // selects that row.
    try testing.expectEqual(hit.Target{ .row = 1 }, a.hits.at(30, 6).?);
    try testing.expectEqual(hit.Target{ .tab = 1 }, a.hits.at(14, 1).?);
    try testing.expectEqual(hit.Target{ .chip = .help }, a.hits.at(118, 0).?);
    const review_x = (try colOfText(ar, &f, 6, "[\u{f06e} Review]")).?;
    try testing.expectEqual(hit.Target{ .action = .{ .issue = 1, .button = 0 } }, a.hits.at(review_x + 2, 6).?);
    try a.click(30, 7, false);
    try testing.expectEqual(@as(usize, 2), a.tab().selected);
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 7), "\u{258c}"));
    // The chevron on the group folds it.
    try a.click(1, 5, false);
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 5), "\u{258c}\u{F460} In PR Review (1)"));
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 6), "ENG-2") == null);
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
    try testing.expectEqual(hit.Target.detail, a.hits.at(100, 11).?);
    _ = try a.onKey("d");
    // The filter pill while typing, then committed.
    _ = try a.onKey("/");
    _ = try a.onKey("v");
    _ = try a.onKey("o");
    _ = try a.onKey("u");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 3), "\u{F0349} vou▏") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 39), "type to filter · Enter commit · Esc cancel") != null);
    // The chip is the toolkit's pill now, so the caret sits WHERE the
    // caret is. It used to be a `▏` pasted on the end of the string,
    // which meant the arrow keys moved a caret the chip never showed.
    _ = try a.onKey("left");
    _ = try a.onKey("left");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 3), "\u{F0349} v▏u") != null);
    _ = try a.onKey("right");
    _ = try a.onKey("right");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 3), "\u{F0349} vou▏") != null);
    _ = try a.onKey("enter");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), "▌JIRA WORK (1 of 3)"));
    try testing.expect((try findRow(ar, &f, "ENG-5")) != null);
    try testing.expect((try findRow(ar, &f, "ENG-2")) == null);
    _ = try a.onKey("esc");
    // Bulk marks: S on a ticket lights it and the header counts.
    _ = try a.onKey("j");
    _ = try a.onKey("shift+s");
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 0), "1 selected") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 6), "ENG-2 ✓") != null);
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
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), "▌JIRA FIX VERSIONS (8)"));
    const r2 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.indexOf(u8, r2, " fixVersion: 13.16.0 ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " ⓧ") != null);
    // The `space:` placeholder is gone: it named the tab's project and did nothing.
    try testing.expect(std.mem.indexOf(u8, r2, " space: ") == null);
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
    try testing.expect((try findRow(ar, &f, " Keys ")) != null);
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

test "the bad-scope screen wears the pane's stripe too" {
    // A pane that cannot show anything is still this pane. The error
    // screen a `--only <scope>` with no matching tab lands on had no
    // stripe at all for a while, which made mnml's most confusing
    // screen also its most anonymous one.
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .boards);
    defer h.stop();
    var f = try Frame.init(testing.allocator, 100, 10);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, &h.app, .{});
    try testing.expect((try findRow(ar, &f, "No tabs for this scope.")) != null);
    const ui: Ui = .{};
    try sdk.pane.expect.gutterFullHeight(&f, ui.th, 0, 0, f.rows - 1, ui.ascii);
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
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), "▌JIRA BOARDS (3 of 9)"));
    // The app-colour stripe runs the WHOLE height of the pane, board
    // and all: the columns start one cell in rather than painting
    // their boxes over column 0. Asserted through `sdk.pane.expect`,
    // the same function the forge pane's own suite calls. The stripe
    // used to stop where the header did, which read as two panes
    // stacked — and it is the only column that says which application
    // this is.
    const ui: Ui = .{};
    try sdk.pane.expect.gutterFullHeight(&f, ui.th, 0, 0, f.rows - 1, ui.ascii);
    try testing.expectEqualStrings("\u{2502}", cellAt(&f, 1, (try findRow(ar, &f, " To Do (")).? + 1).symbol());
    const r2 = try rowText(ar, &f, 3);
    try testing.expect(std.mem.indexOf(u8, r2, " board: Checkout board ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " sprint: Sprint 4 ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " [?] ") != null);
    try testing.expect(std.mem.indexOf(u8, r2, " SB ") != null);
    const r3 = try rowText(ar, &f, 4);
    try testing.expect(std.mem.indexOf(u8, r3, " quick filters ") != null or std.mem.indexOf(u8, r2, " quick filters ") != null);
    const top = (try findRow(ar, &f, " To Do (")).?;
    const top_row = try rowText(ar, &f, top);
    try testing.expect(std.mem.indexOf(u8, top_row, " In Progress (") != null);
    try testing.expect(std.mem.indexOf(u8, top_row, " Testing (") != null);
    try testing.expect(std.mem.indexOf(u8, top_row, " Done (") != null);
    // The cursor's card carries the toolkit's row ground — the stripe
    // down its left column and the cursor-line fill across it, on every
    // line the card owns. Its head is the chevron hit, its summary the
    // card hit. (Every card wears the stripe, dim; looking for the
    // first one on the row would find whichever column starts leftmost,
    // so the chevron's own rect is what locates the card.)
    const chev = a.hits.rectOf(hit.Target{ .card_chevron = 0 }).?;
    const head_y = chev.y;
    const head_x = chev.x;
    try testing.expectEqualStrings("\u{258c}", cellAt(&f, head_x, head_y).symbol());
    try testing.expectEqual((Ui{}).th.cursor_line, bgAt(&f, head_x + 8, head_y).?);
    try testing.expectEqual(hit.Target{ .card_chevron = 0 }, a.hits.at(head_x + 1, head_y).?);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, head_y + 1), "Checkout rewrite") != null);
    try testing.expectEqual(hit.Target{ .card = 0 }, a.hits.at(head_x + 6, head_y + 1).?);
    // An avatar click toggles that assignee into the filter.
    const sb_x = (try colOfText(ar, &f, 3, " SB ")).?;
    try a.click(sb_x + 1, 3, false);
    try testing.expectEqual(@as(usize, 2), a.tab().active_assignees.count());
    try paint(ar, &f, a, .{});
    try testing.expect(std.mem.startsWith(u8, try rowText(ar, &f, 0), "▌JIRA BOARDS (4 of 9)"));
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

test "the fold row is one phrase: the ellipsis is punctuation and only its words are bright" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    // Four linked pull requests on one ticket: three rows and a fold
    // row for the fourth.
    const t0 = a.tab();
    try t0.tree.?.setExpanded("ENG-2", true);
    try t0.tree.?.putPrs("ENG-2", &.{
        .{ .id = "#1", .status = "MERGED" },
        .{ .id = "#2", .status = "OPEN" },
        .{ .id = "#3", .status = "MERGED" },
        .{ .id = "#4", .status = "OPEN" },
    });
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const y = (try findRow(ar, &f, "Show more (1)")) orelse return error.NoFoldRow;
    // `⋯  Show more (N)` — the ellipsis dim, two cells of air, the
    // words in the bright foreground a key wears, and the three of
    // them next to one another. Asserted through `sdk.pane.expect`,
    // the same function the forge pane's own suite calls: this pane
    // used to pin the `⋯` to the row's left edge and put its words out
    // in the summary column, forty cells away from it.
    const ui: Ui = .{};
    try sdk.pane.expect.foldRow(&f, ui.th, y, ui.ascii);
}

test "a ticket row's buttons are always there: words at 140, glyphs at 80, hit = paint" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const ui: Ui = .{};

    // Wide: the glyph AND the word, and every button a hit the width
    // of the cells it painted.
    {
        a.resize(140, 24);
        var f = try Frame.init(testing.allocator, 140, 24);
        defer f.deinit();
        try paint(ar, &f, a, .{});
        const y = (try findRow(ar, &f, "ENG-2")) orelse return error.NoTicketRow;
        try sdk.pane.expect.actionRun(hit.Target, &f, &a.hits, y, &.{.{ .action = .{ .issue = 1, .button = 0 } }}, .icon_label);
    }
    // Narrow: the SAME buttons, one cell each. They are not dropped —
    // this pane used to clip forty summaries to show them and the
    // forge pane used to drop them whole, and neither rule is this one.
    {
        a.resize(80, 24);
        var f = try Frame.init(testing.allocator, 80, 24);
        defer f.deinit();
        try paint(ar, &f, a, .{});
        const y = (try findRow(ar, &f, "ENG-2")) orelse return error.NoTicketRow;
        try sdk.pane.expect.actionRun(hit.Target, &f, &a.hits, y, &.{.{ .action = .{ .issue = 1, .button = 0 } }}, .icon);
        // And the pointer names what the glyph cannot: at icon+label
        // the word is on screen and the hover says nothing.
        const r = a.hits.rectOf(.{ .action = .{ .issue = 1, .button = 0 } }).?;
        try a.hover(r.x, y);
        try testing.expect(a.hoverNote().len > 0);
    }
    _ = ui;
}

test "a build line is a door: the whole line is one hit, and it opens that run" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const t0 = a.tab();
    try t0.tree.?.setExpanded("ENG-2", true);
    try t0.tree.?.putPrs("ENG-2", &.{.{ .id = "#1", .status = "OPEN", .url = "https://bitbucket.org/acme/api/pull-requests/1" }});
    try t0.tree.?.setPrExpanded("ENG-2", "#1", true);
    try t0.tree.?.putPipelines("ENG-2", "#1", &.{.{ .build_number = 413, .branch = "chris/fix", .created_on = "2026-09-15T15:20:00+00:00" }});
    var f = try Frame.init(testing.allocator, 120, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const y = (try findRow(ar, &f, "#413")) orelse return error.NoBuildLine;

    // The whole line is one door, from the pane's left edge to the
    // cell the list ends at — `sdk.pane.expect.buildLineHit`, the same
    // function the forge pane's own suite calls, whose build line is a
    // table CELL rather than a free row. Both fell through to the
    // generic row hit before this, which selects; the line read as a
    // link in two panes and behaved as one in neither.
    const idx = blk: {
        var x: u16 = 0;
        while (x < f.cols) : (x += 1) if (a.hits.at(x, y)) |tg| if (tg == .build_line) break :blk tg.build_line;
        return error.NoBuildHit;
    };
    const right = a.hits.rectOf(.{ .build_line = idx }).?.right();
    try sdk.pane.expect.buildLineHit(hit.Target, &a.hits, y, 0, right, .{ .build_line = idx });

    // And pressing it goes to that run's page rather than selecting
    // the line. `open_command` is `true`, so nothing on the machine is
    // launched and the status line still says which URL was handed
    // over — and `sdk.pane.build.pageUrl` is what spelled it, on both
    // panes.
    a.cfg.open_command = "true";
    try a.click(1, y, false);
    try testing.expectEqualStrings("opened https://bitbucket.org/acme/api/pipelines/results/413", a.status.items);
}

test "a list longer than its body carries the toolkit's scrollbar, and the bar is a control" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    // A body short enough that the rows outrun it. The forge pane's
    // list has always said where in it you are; this one did not.
    a.resize(80, 12);
    var f = try Frame.init(testing.allocator, 80, 12);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const bar_x = f.cols - 1;
    // The track runs the height of the body with a sized thumb on it,
    // in the toolkit's two glyphs. Asserted through `sdk.pane.expect`,
    // the same function the forge pane's own suite calls.
    try sdk.pane.expect.listScrollbar(&f, bar_x, 0, f.rows);
    // Every cell of the track is the same hit, so a press anywhere on
    // it is a position rather than a miss.
    const first_bar_y = blk: {
        var yy: u16 = 0;
        while (yy < f.rows) : (yy += 1) if (a.hits.at(bar_x, yy)) |t| if (t == .list_bar) break :blk yy;
        return error.NoScrollbarHit;
    };
    // The words stop one cell short of it: the bar has a column of its
    // own rather than sitting on a clipped summary.
    try testing.expect(a.hits.at(bar_x, first_bar_y).? == hit.Target.list_bar);
    // A press near the bottom of the track scrolls there, and brings
    // the cursor with it so the keys carry on from where the eye is.
    const before = a.tab().scroll;
    try a.click(bar_x, f.rows - 2, false);
    try testing.expect(a.tab().scroll > before);
    try testing.expect(a.tab().selected >= a.tab().scroll);
    // And a drag keeps steering it back.
    try a.drag(bar_x, first_bar_y);
    try testing.expectEqual(@as(usize, 0), a.tab().scroll);
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
    const r2 = try rowText(ar, &f, 3);
    const r3 = try rowText(ar, &f, 4);
    try testing.expect(std.mem.indexOf(u8, r2, " basic ") != null);
    // Whatever did not fit on the toolbar's first row is whole on its
    // second, never clipped.
    try testing.expect(std.mem.indexOf(u8, r3, " status: All") != null or std.mem.indexOf(u8, r2, " status: All") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(ar, &f, 5), "KEY") != null or std.mem.indexOf(u8, r3, "KEY") != null);
    try testing.expect((try findRow(ar, &f, "ENG-2")) != null);
    // 80 columns sheds most of the row; what is left still reads, and
    // still ends at the door.
    const last = std.mem.trimEnd(u8, try rowText(ar, &f, 23), " ");
    try testing.expect(std.mem.indexOf(u8, last, "d detail") != null);
    try testing.expect(std.mem.endsWith(u8, last, "? keys"));
    // Wheel on the list moves the cursor.
    try a.wheel(20, 10, -1);
    try testing.expect(a.tab().selected > 0);
}

test "a half-width pane keeps every key whole: the columns go before the key loses a cell" {
    // hunt/findings-2026-09-23/integ-jira-narrow-key-truncated.md: at 60
    // columns every key read `ENG…`; at ~43 the key cell was empty and
    // the header ran together (`STATUSASSIGNUPDATED`).
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    for ([_]u16{ 60, 43, 34 }) |cols| {
        a.resize(cols, 24);
        var f = try Frame.init(testing.allocator, cols, 24);
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const ar = arena.allocator();
        try paint(ar, &f, a, .{});
        // Every ticket on the tab has its whole key on screen, with no
        // ellipsis eating it.
        for (a.tab().issues) |iss| {
            const y = (try findRow(ar, &f, iss.key)) orelse {
                // A folded group hides its tickets; only the unfolded
                // ones are the point here.
                continue;
            };
            const row = try rowText(ar, &f, y);
            const at = std.mem.indexOf(u8, row, iss.key).?;
            const after = row[at + iss.key.len ..];
            try testing.expect(!std.mem.startsWith(u8, after, "\u{2026}"));
        }
        // The header's labels are words with air between them, never
        // two run together.
        const hy = (try findRow(ar, &f, "KEY")).?;
        const head = try rowText(ar, &f, hy);
        try testing.expect(std.mem.indexOf(u8, head, "STATUSASSIGN") == null);
        try testing.expect(std.mem.indexOf(u8, head, "ASSIGNEEUPDATED") == null);
        try testing.expect(std.mem.indexOf(u8, head, "SUMMARY") != null);
    }
    // At 60 the assignee went whole; the key and the summary are there.
    a.resize(60, 24);
    var f = try Frame.init(testing.allocator, 60, 24);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try paint(arena.allocator(), &f, a, .{});
    const head = try rowText(arena.allocator(), &f, (try findRow(arena.allocator(), &f, "KEY")).?);
    try testing.expect(std.mem.indexOf(u8, head, "ASSIGNEE") == null);
    try testing.expect((try findRow(arena.allocator(), &f, "ENG-2")) != null);
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
    _ = try a.onKey("shift+j");
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

/// Every cell that carries a fold chevron in this frame.
const ChevronAt = struct { x: u16, y: u16, open: bool };

fn chevronsOf(arena: Allocator, f: *const Frame) Allocator.Error![]const ChevronAt {
    var out: std.ArrayList(ChevronAt) = .empty;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < f.cols) : (x += 1) {
            const sym = f.slots[@as(usize, y) * f.cols + x].symbol();
            if (std.mem.eql(u8, sym, open_glyph)) try out.append(arena, .{ .x = x, .y = y, .open = true });
            if (std.mem.eql(u8, sym, closed_glyph)) try out.append(arena, .{ .x = x, .y = y, .open = false });
        }
    }
    return out.toOwnedSlice(arena);
}

fn chevronAt(arena: Allocator, f: *const Frame, x: u16, y: u16) Allocator.Error!?bool {
    _ = arena;
    if (y >= f.rows or x >= f.cols) return null;
    const sym = f.slots[@as(usize, y) * f.cols + x].symbol();
    if (std.mem.eql(u8, sym, open_glyph)) return true;
    if (std.mem.eql(u8, sym, closed_glyph)) return false;
    return null;
}

test "every chevron column folds under the mouse — the group's, the ticket's and the merged PR's" {
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
    // A merged PR's chevron is the one that used to launch a browser
    // instead of expanding: open ENG-2's so the sweep below covers it.
    const start = try chevronsOf(ar, &f);
    try testing.expect(start.len >= 3);
    // Both cells of every chevron's two-cell target, one at a time: the
    // glyph flips on the click and flips back on the next one, so the
    // pointer can fold anything the keyboard can.
    var col_off: u16 = 0;
    while (col_off < 2) : (col_off += 1) {
        var i: usize = 0;
        while (true) : (i += 1) {
            try paint(ar, &f, a, .{});
            const list = try chevronsOf(ar, &f);
            if (i >= list.len) break;
            const c = list[i];
            try a.click(c.x + col_off, c.y, false);
            try paint(ar, &f, a, .{});
            const after = try chevronAt(ar, &f, c.x, c.y);
            if (after == null) {
                std.debug.print("chevron at {d},{d} (open={}) vanished after a click on column +{d}\n{s}\n", .{ c.x, c.y, c.open, col_off, try screenText(ar, &f) });
                return error.ChevronDidNotFold;
            }
            if (after.? == c.open) {
                std.debug.print("chevron at {d},{d} did not fold on a click on column +{d} (still open={})\n{s}\n", .{ c.x, c.y, col_off, c.open, try screenText(ar, &f) });
                return error.ChevronDidNotFold;
            }
            // Put it back so the next chevron is where it was.
            try a.click(c.x + col_off, c.y, false);
        }
    }
}

test "the detail panel's × closes it and its scrollbar answers a press and a drag" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    // Short on purpose: the detail has more lines than rows, which is
    // when a scrollbar has anything to say.
    var f = try Frame.init(testing.allocator, 120, 12);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // The cursor starts on a group row, which has no detail: step onto
    // the ticket under it first.
    _ = try a.onKey("j");
    try a.toggleDetails();
    try paint(ar, &f, a, .{});
    try testing.expect(a.details_visible);
    // The bar is there, and it is a target rather than a decoration.
    const bar = a.hits.rectOf(hit.Target.detail_bar) orelse {
        std.debug.print("no scrollbar; lines={d} rows={d} visible={}\n{s}\n", .{ a.details_lines, a.details_rows, a.details_visible, try screenText(ar, &f) });
        return error.NoScrollbar;
    };
    try testing.expect(a.details_lines > a.details_rows);
    try testing.expectEqual(@as(u16, 0), a.details_scroll);
    // A press near the bottom of the track goes there; a drag back up
    // comes back. `scrollAt` clamps to the last window.
    try a.click(bar.x, bar.bottom() - 1, false);
    const deep = a.details_scroll;
    try testing.expect(deep > 0);
    try a.drag(bar.x, bar.y);
    try testing.expectEqual(@as(u16, 0), a.details_scroll);
    // A drag that is not over the bar moves nothing.
    a.details_scroll = deep;
    try a.drag(1, bar.y);
    try testing.expectEqual(deep, a.details_scroll);
    // The × closes the panel; Esc still does too.
    const close = a.hits.rectOf(hit.Target.detail_close) orelse return error.NoCloseChip;
    try a.click(close.x, close.y, false);
    try testing.expect(!a.details_visible);
}

test "every hint entry and every key-sheet row runs what its chord runs" {
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
    // `d detail` on the hint row opens the detail pane, as `d` does.
    const d = a.hits.rectOf(hit.Target{ .hint = .toggle_details }) orelse return error.NoHint;
    try testing.expect(!a.details_visible);
    try a.click(d.x, d.y, false);
    try testing.expect(a.details_visible);
    try a.click(d.x, d.y, false);
    try testing.expect(!a.details_visible);
    // `? keys` at the end opens the sheet.
    const keys = a.hits.rectOf(hit.Target{ .hint = .help }) orelse return error.NoKeysHint;
    try a.click(keys.x, keys.y, false);
    try testing.expect(a.help);
    // And a row of the sheet runs its own chord — `Tab` switches tab.
    try paint(ar, &f, a, .{});
    const row = a.hits.rectOf(hit.Target{ .help_row = .next_tab }) orelse {
        std.debug.print("no sheet row for next_tab\n{s}\n", .{try screenText(ar, &f)});
        return error.NoSheetRow;
    };
    const was = a.active;
    try a.click(row.x, row.y, false);
    try testing.expect(a.active != was);
}

/// The theme a colour test paints in: a `cursor_line` that is nothing
/// else on the screen, so "this cell is on the cursor row" is a fact
/// and not a coincidence.
fn bandedUi() Ui {
    return .{ .th = Theme.fromHelloBranded(.{
        .fg = .{ .rgb = .{ 200, 200, 200 } },
        .bg = .{ .rgb = .{ 10, 10, 10 } },
        .muted = .{ .rgb = .{ 90, 90, 90 } },
        .accent = .{ .rgb = .{ 97, 175, 239 } },
        .cursor_line = .{ .rgb = .{ 44, 50, 60 } },
        .chip_bg = .{ .rgb = .{ 45, 45, 45 } },
        .chip_active_bg = .{ .rgb = .{ 152, 195, 121 } },
    }, "blue") };
}

/// Every cell of `y` between `x0` and `x1` carries `want` as its
/// ground, bar the ones in `allow` — a chip on a row brings its own,
/// and that is the one thing that may sit on top of the band.
fn expectBand(f: *const Frame, y: u16, x0: u16, x1: u16, want: sdk.Color, allow: []const sdk.Color) !void {
    var x = x0;
    while (x < x1) : (x += 1) {
        const got = bgAt(f, x, y);
        if (got != null and std.meta.eql(got.?, want)) continue;
        if (got != null) {
            var ok = false;
            for (allow) |c| ok = ok or std.meta.eql(got.?, c);
            if (ok) continue;
        }
        std.debug.print("row {d} breaks at column {d}: `{s}` on {any}, wanted {any}\n", .{ y, x, cellAt(f, x, y).symbol(), got, want });
        return error.RowNotBanded;
    }
}

/// …and no cell of it does.
fn expectNoBand(f: *const Frame, y: u16, x0: u16, x1: u16, want: sdk.Color) !void {
    var x = x0;
    while (x < x1) : (x += 1) {
        const got = bgAt(f, x, y);
        if (got != null and std.meta.eql(got.?, want)) {
            std.debug.print("row {d} is banded at column {d}, and should not be\n", .{ y, x });
            return error.RowBanded;
        }
    }
}

test "the cursor row is a filled band across the whole row, on the tree, the kanban and a picker" {
    const ui = bandedUi();
    const band = ui.th.cursor_line;
    // A row's `[ Open ]` / `[ Merge ]` chips paint on their own ground;
    // everything else on the row belongs to the band.
    const chip_grounds = [_]sdk.Color{ ui.th.chip_bg, ui.th.chip_active_bg };
    {
        const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
        defer h.stop();
        const a = &h.app;
        try a.ensureLoaded();
        var f = try Frame.init(testing.allocator, 120, 40);
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const ar = arena.allocator();
        try paint(ar, &f, a, ui);
        // The tree: the cursor is on the first group header.
        const cur = (try findRow(ar, &f, "In PR Review (1)")).?;
        try expectBand(&f, cur, 0, 120, band, &.{});
        try expectNoBand(&f, cur + 1, 0, 120, band);
        // Move it onto a ticket row and the band moves with it.
        _ = try a.onKey("j");
        try paint(ar, &f, a, ui);
        try expectNoBand(&f, cur, 0, 120, band);
        try expectBand(&f, cur + 1, 0, 120, band, &chip_grounds);
        // The picker over the list: its rows band the same way.
        _ = try a.onKey("a");
        try paint(ar, &f, a, ui);
        try testing.expect(a.picker != null);
        const pr = a.hits.rectOf(hit.Target{ .picker_row = 0 }).?;
        try expectBand(&f, pr.y, pr.x, pr.x + pr.w, band, &.{});
        const next = a.hits.rectOf(hit.Target{ .picker_row = 1 }).?;
        try expectNoBand(&f, next.y, next.x, next.x + next.w, band);
    }
    {
        const h = try app_mod.Harness.start(.{ .tabs = &app_mod.board_tabs, .team_field_id = "customfield_10056" }, .boards);
        defer h.stop();
        const a = &h.app;
        try a.ensureLoaded();
        var f = try Frame.init(testing.allocator, 120, 40);
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const ar = arena.allocator();
        try paint(ar, &f, a, ui);
        // The kanban: the cursor's card bands across the card's width,
        // and the card beside it in the next column does not.
        const card = a.hits.rectOf(hit.Target{ .card = 0 }).?;
        try expectBand(&f, card.y, card.x, card.x + card.w, band, &.{});
        var other: ?Rect = null;
        var i: u32 = 1;
        while (i < 9) : (i += 1) {
            if (a.hits.rectOf(hit.Target{ .card = i })) |rr| {
                if (rr.y != card.y or rr.x != card.x) {
                    other = rr;
                    break;
                }
            }
        }
        try expectNoBand(&f, other.?.y, other.?.x, other.?.x + other.?.w, band);
    }
}

test "the hint row says `? keys` once: the entry it reserves room for, not that one and its binding too" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    // Wide enough that every binding fits: below this the row drops the
    // last of them for room, and a row that never paints the help
    // binding cannot show it twice — which is why the duplicate
    // survived so long in a suite that only ever painted 120 columns.
    var f = try Frame.init(testing.allocator, 200, 40);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try paint(ar, &f, a, .{});
    const row = std.mem.trimEnd(u8, try rowText(ar, &f, 39), " ");
    try testing.expect(std.mem.indexOf(u8, row, "r refresh") != null);
    try testing.expect(std.mem.endsWith(u8, row, "? keys"));
    try testing.expect(std.mem.indexOf(u8, row, "? keys \u{b7} ? keys") == null);
    // …and the one that is painted is the door to the sheet.
    const keys = a.hits.rectOf(hit.Target{ .hint = .help }) orelse return error.NoKeysHint;
    try a.click(keys.x, keys.y, false);
    try testing.expect(a.help);
}
