//! One function: turn the `App` into a frame, registering every click
//! target in the same statement as the cells it covers. The pane is
//! mnml's own panel shape, so it looks native inside mnml-zig rather
//! than like a transplanted table:
//!
//!   row 0   the caps header — `BITBUCKET PRS  (4 repos · 64 PRs)` and,
//!           right-anchored, the chips: `author: all` (the PR family),
//!           the pipelines pages (the pipelines family), the refresh glyph
//!   row 1   the tab strip, when the launch kept more than one tab —
//!           `1 Open + Draft (47)  2 Merged (32)  3 Pipelines (18)`
//!   row 2   the filter pill — `󰍉 / filter`
//!   row 3   the column header
//!   rows    the list: the `▌` marker on the cursor's row, the reference's
//!           columns, a merged PR's pipeline sub-line, the show-more footer,
//!           a scrollbar when the list is longer than the pane; with `d`, the
//!           detail beside it (or over it below 100 columns)
//!   last    the hint row — the status on the left, and on the right the
//!           keys that apply to the focused row, generated from the one
//!           keymap table so nothing here can drift from what a key does
//!
//! Overlays paint last, so they win the click: a row's right-click
//! menu, and the `?` key sheet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const app_mod = @import("app.zig");
const tabs = @import("tabs.zig");
const view = @import("view.zig");
const keymap = @import("keymap.zig");
const hit = @import("hit.zig");
const cfg = @import("config.zig");
const theme_mod = @import("theme.zig");

const App = app_mod.App;
const Style = sdk.Style;
const Theme = theme_mod.Theme;

/// The narrowest pane that gets the list and the detail side by side.
pub const split_min_cols: u16 = 100;
/// The list's share when they are side by side (the reference's 55/45).
pub const list_share_pct: u16 = 55;

pub const marker = "▌";
pub const filter_glyph_nerd = "\u{F0349}";
pub const refresh_glyph_nerd = "\u{eb37}";
pub const refresh_glyph_ascii = "\u{21ba}";

pub const Box = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Chrome = sdk.pane.Painter(hit.Target);

/// A rectangle on the frame with the hit map alongside.
const Painter = struct {
    f: *sdk.Frame,
    app: *App,
    th: Theme,
    nerd: bool,
    /// The shared pane chrome — the gutter, the detail panel's `\u{d7}`
    /// and scrollbar, the clickable hint row. Both official integrations
    /// paint these from the same code.
    c: Chrome,

    fn text(p: *Painter, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
        return p.f.text(x, y, max_w, s, style);
    }

    fn fill(p: *Painter, b: Box, style: Style) void {
        p.f.fill(b.x, b.y, b.w, b.h, style);
    }

    fn target(p: *Painter, x: u16, y: u16, w: u16, tg: hit.Target) void {
        p.app.hits.add(.{ .x = x, .y = y, .w = w, .h = 1 }, tg);
    }

    fn width(s: []const u8) u16 {
        var n: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| n += if (sdk.frame.isWide(cp)) 2 else 1;
        return n;
    }
};

pub fn paint(arena: Allocator, f: *sdk.Frame, app: *App, nerd_font: bool) Allocator.Error!void {
    f.clear(.{ .fg = app.theme.fg, .bg = app.theme.bg });
    app.cols = f.cols;
    app.rows = f.rows;
    app.hits.reset();
    if (f.rows == 0 or f.cols == 0) return;
    var p: Painter = .{
        .f = f,
        .app = app,
        .th = app.theme,
        .nerd = nerd_font,
        .c = .{ .f = f, .gpa = app.hits.gpa, .arena = arena, .hits = &app.hits.inner, .th = app.theme, .ui = .{ .nerd = nerd_font, .ascii = !nerd_font, .tab_indicator = app.tab_indicator } },
    };
    // The app-colour stripe down column 0 — the pane's identity, from
    // the toolkit. Painted under everything: a row that puts its own
    // marker there still wins the cell.
    p.c.gutter(.{ .x = 0, .y = 0, .w = 1, .h = f.rows -| 1 }, null);
    // The header's `N of M` is derived from the rows, and the header
    // paints first: resolve them once here so it reads this frame's
    // numbers rather than the last one's.
    _ = try app.visible(arena);
    var y: u16 = 0;
    try paintHeader(arena, &p, y);
    y += 1;
    if (app.showTabStrip() and y < f.rows) {
        y += try paintTabStrip(arena, &p, y);
    }
    if (y < f.rows) {
        try paintFilter(&p, y);
        y += 1;
    }
    const hint_y = f.rows - 1;
    if (y < hint_y) {
        const body: Box = .{ .x = 0, .y = y, .w = f.cols, .h = hint_y - y };
        try paintBody(arena, &p, body);
    }
    try paintHintRow(arena, &p, hint_y);
    if (app.mode == .menu) try paintMenu(arena, &p);
    if (app.mode == .help) try paintSheet(arena, &p);
    if (app.mode == .confirm) try paintMergeConfirm(&p);
}

// ─── the header ──────────────────────────────────────────────────────────

fn familyLabel(app: *App) []const u8 {
    return switch (app.family()) {
        .prs => "BITBUCKET PRS",
        .pipelines => "BITBUCKET PIPELINES",
        .branches => "BITBUCKET BRANCHES",
    };
}

fn paintHeader(arena: Allocator, p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const ts = app.activeTab();
    var x: u16 = 1;
    const label = familyLabel(app);
    x += p.text(x, y, p.f.cols -| x, label, th.label());
    // The subtitle: the reference's status count, dim.
    var sub: []const u8 = "";
    if (ts.loading and !ts.fetched) {
        const done = app.progressDone();
        const total = app.progressTotal();
        sub = if (total > 0) try std.fmt.allocPrint(arena, "  loading… {d}/{d} repos", .{ done, total }) else "  loading…";
    } else if (app.awaiting_only) {
        // The chip is narrowing the tab: say so, or the header goes on
        // claiming a count the rows plainly do not add up to.
        sub = try std.fmt.allocPrint(arena, "  ({d} of {d} awaiting my review)", .{ app.awaitingCount(), ts.items });
    } else if (app.narrowed()) {
        // Narrowed: the count says how much of the tab is hidden, the
        // way the sibling integrations' caps headers do.
        sub = try std.fmt.allocPrint(arena, "  ({d} of {d})", .{ app.filter_shown, app.filter_total });
    } else if (ts.fetched) {
        sub = switch (ts.data) {
            .repo_pr_tree => try std.fmt.allocPrint(arena, "  ({d} repos · {d} PRs{s})", .{ ts.repos, ts.items, if (ts.errored > 0) " · some errored" else "" }),
            .repo_tree => try std.fmt.allocPrint(arena, "  ({d} repos)", .{ts.repos}),
            .pull_requests => try std.fmt.allocPrint(arena, "  ({d} PRs)", .{ts.items}),
            .pipelines => try std.fmt.allocPrint(arena, "  ({d} pipelines)", .{ts.items}),
            .branches => try std.fmt.allocPrint(arena, "  ({d} branches)", .{ts.items}),
        };
    }
    // A refetch over rows that are already there keeps the count and
    // says it is refreshing beside it, rather than replacing what is on
    // screen with `loading…`: the rows below are last time's, and they
    // stay readable while the new ones are fetched.
    if (ts.loading and ts.fetched) {
        sub = try std.fmt.allocPrint(arena, "{s}{s}", .{ sub, if (p.nerd) "  refreshing…" else "  refreshing..." });
    }
    // The chips, laid right to left, each dropped whole when it would
    // cross the title.
    const refresh_text = if (p.nerd) " " ++ refresh_glyph_nerd ++ " " else " " ++ refresh_glyph_ascii ++ " ";
    var right = p.f.cols;
    const rw = Painter.width(refresh_text);
    if (right >= x + rw + 2) {
        right -= rw;
        _ = p.text(right, y, rw, refresh_text, th.refresh());
        p.target(right, y, rw, .{ .chip = .refresh });
    }
    const Chip = struct { text: []const u8, target: hit.Chip, active: bool };
    var chips: [6]Chip = undefined;
    var n: usize = 0;
    switch (app.family()) {
        .prs => {
            const kind_ok = ts.spec.kind == .workspace_open_prs or ts.spec.kind == .workspace_merged_prs;
            // What is waiting on YOU, beside what you authored. The
            // count is off the participants already on screen, so the
            // chip costs nothing and can say its number at rest.
            const waiting = app.awaitingCount();
            if (waiting > 0 or app.awaiting_only) {
                chips[n] = .{ .text = try std.fmt.allocPrint(arena, " awaiting: {d} ", .{waiting}), .target = .awaiting, .active = app.awaiting_only };
                n += 1;
            }
            if (kind_ok) {
                const who = if (ts.spec.mine_only) (if (app.me_display_name.len > 0) app.me_display_name else "me") else "all";
                chips[n] = .{ .text = try std.fmt.allocPrint(arena, " author: {s} ", .{who}), .target = .author, .active = ts.spec.mine_only };
                n += 1;
            }
        },
        .pipelines => {
            chips[n] = .{ .text = " usage ", .target = .usage, .active = false };
            n += 1;
            chips[n] = .{ .text = " caches ", .target = .caches, .active = false };
            n += 1;
            chips[n] = .{ .text = " schedules ", .target = .schedules, .active = false };
            n += 1;
            chips[n] = .{ .text = " run pipeline ", .target = .run_pipeline, .active = false };
            n += 1;
        },
        .branches => {},
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = chips[i];
        const w = Painter.width(c.text);
        if (right < x + w + 2) break;
        right -= w + 1;
        _ = p.text(right, y, w, c.text, if (c.active) th.chipActive() else th.chip());
        p.target(right, y, w, .{ .chip = c.target });
    }
    if (sub.len > 0) _ = p.text(x, y, right -| x -| 1, sub, th.dimText());
}

// ─── the tab strip ───────────────────────────────────────────────────────

/// The strip, from the toolkit — the same two rows the tracker pane
/// paints, so the active tab is underlined the same way in both.
/// Returns the rows it used.
fn paintTabStrip(arena: Allocator, p: *Painter, y: u16) Allocator.Error!u16 {
    const app = p.app;
    var list: std.ArrayList(Chrome.TabSpec) = .empty;
    for (app.tabs, 0..) |*ts, i| {
        const count = if (ts.fetched) try std.fmt.allocPrint(arena, " {d} {s} ({d}) ", .{ i + 1, ts.spec.name, tabCount(ts) }) else try std.fmt.allocPrint(arena, " {d} {s} ", .{ i + 1, ts.spec.name });
        try list.append(arena, .{ .label = count, .target = .{ .tab = i }, .active = i == app.active });
    }
    return p.c.tabStrip(1, y, list.items);
}

/// The reference's tab count: the rows a tree shows, the items of a list.
fn tabCount(ts: *const app_mod.TabState) usize {
    return switch (ts.data) {
        .repo_pr_tree => ts.items,
        .repo_tree => ts.repos,
        else => ts.items,
    };
}

// ─── the filter pill ─────────────────────────────────────────────────────

fn paintFilter(p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    if (p.f.cols < 6) return;
    // The pill is the toolkit's, so the glyph, the placeholder, the
    // caret and the hit are the same ones the Jira pane paints.
    try p.c.filterPill(
        .{ .x = 1, .y = y, .w = p.f.cols - 2, .h = 1 },
        app.filter.items,
        app.filter_caret,
        app.mode == .filter,
        .{ .chip = .filter },
    );
}

// ─── the body ────────────────────────────────────────────────────────────

fn paintBody(arena: Allocator, p: *Painter, body: Box) Allocator.Error!void {
    const app = p.app;
    const split = app.detail_visible and body.w >= split_min_cols;
    const list_w: u16 = if (split) @max(30, (body.w * list_share_pct) / 100) else body.w;
    if (!app.detail_visible or split) {
        try paintList(arena, p, .{ .x = body.x, .y = body.y, .w = list_w, .h = body.h });
    }
    if (app.detail_visible) {
        const x: u16 = if (split) body.x + list_w + 1 else body.x;
        const w: u16 = if (split) body.w -| (list_w + 1) else body.w;
        if (split) {
            var yy = body.y;
            while (yy < body.y + body.h) : (yy += 1) p.f.put(body.x + list_w, yy, "│", .{ .fg = p.th.border });
        }
        try paintDetail(arena, p, .{ .x = x, .y = body.y, .w = w, .h = body.h });
    }
}

fn paintList(arena: Allocator, p: *Painter, box: Box) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const ts = app.activeTab();
    if (box.h == 0 or box.w < 4) return;
    // A tab that failed paints the reason instead of an empty list.
    if (ts.error_text.len > 0) {
        _ = p.text(box.x + 2, box.y, box.w -| 2, ts.spec.name, th.label());
        if (box.h > 2) _ = p.text(box.x + 2, box.y + 2, box.w -| 2, ts.error_text, th.bad());
        if (box.h > 4) _ = p.text(box.x + 2, box.y + 4, box.w -| 2, "r retries · see the README's Auth section", th.mutedText());
        return;
    }
    const inner_w = box.w -| 2; // the marker column and a cell of air
    const cols = try view.fit(arena, view.tableOf(ts.data), inner_w -| 1);
    const header = try view.headerSpans(arena, cols, th);
    paintSpans(p, box.x + 2, box.y, inner_w -| 1, header);
    if (box.h < 2) return;
    const list: Box = .{ .x = box.x, .y = box.y + 1, .w = box.w, .h = box.h - 1 };
    const v = try app.visible(arena);
    if (v.rows.len == 0) {
        const msg: []const u8 = if (ts.loading) "loading…" else if (!ts.fetched) "not fetched yet — r" else if (app.filter.items.len > 0) "No matches — esc clears" else emptyMessage(ts.spec.kind);
        _ = p.text(list.x + 2, list.y, list.w -| 2, msg, th.mutedText());
        return;
    }
    // The scroll window follows the cursor over cells, not rows — a
    // merged PR opened to its pipeline is two cells tall.
    if (ts.selected >= v.rows.len) ts.selected = v.rows.len - 1;
    const needs_bar = v.cells > list.h;
    const text_w = if (needs_bar) list.w -| 2 else list.w;
    var first = ts.scroll;
    if (first > ts.selected) first = ts.selected;
    // Push the window down until the cursor's cells fit.
    while (true) {
        var used: usize = 0;
        var i = first;
        while (i <= ts.selected) : (i += 1) used += v.rows[i].height();
        if (used <= list.h or first >= ts.selected) break;
        first += 1;
    }
    // Never leave blank rows under a full list.
    while (first > 0) {
        var used: usize = 0;
        var i = first - 1;
        while (i < v.rows.len) : (i += 1) {
            used += v.rows[i].height();
            if (used > list.h) break;
        }
        if (used > list.h) break;
        first -= 1;
    }
    ts.scroll = first;
    var y = list.y;
    var idx = first;
    while (idx < v.rows.len and y < list.y + list.h) : (idx += 1) {
        const row = v.rows[idx];
        const selected = idx == ts.selected;
        const h = row.height();
        // The toolkit's row ground: the fill, the app-colour stripe in
        // column 0 (bright on the cursor's row) and the row's own hit,
        // in one statement — the same one the Jira tree paints.
        try p.c.rowGround(.{ .x = list.x, .y = y, .w = text_w, .h = @min(h, list.y + list.h - y) }, selected, .{ .row = idx });
        const spans = try view.rowSpans(arena, .{ .app = app, .ts = ts, .cols = cols, .th = th, .row = row, .selected = selected, .ascii = !p.nerd });
        // The buttons take their cells off the row's right end BEFORE
        // the words are painted, so a title is shortened rather than
        // painted over.
        // The buttons come out of the LAST column's width, so a row
        // never trades its title for them.
        const bw = rowButtonsWidth(p, if (cols.len > 0) cols[cols.len - 1].w else 0, row, selected);
        paintSpans(p, list.x + 2, y, text_w -| 2 -| bw, spans);
        if (bw > 0) try paintRowButtons(p, list.x, y, text_w, bw, idx, row);
        y += h;
    }
    if (needs_bar) try p.c.scrollbar(.{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h }, v.cells, cellsBefore(v.rows, first), list.h, null);
}

/// `[ Open ] [ Merge ]` at the right end of a pull-request row.
///
/// `[ Merge ]` is dim and registers NO `pr_button` target until the
/// pull request may actually merge — only `merge_blocked`, which a
/// hover reads for its reason and a click answers with the same
/// sentence. A button that is always pressable teaches nothing.
const open_caption = "[ Open ]";
/// Cells the title keeps when a row carries its buttons.
const title_floor: u16 = 16;

/// What one row's buttons will take, or 0 when the row has none.
///
/// Only the row under the CURSOR carries them, and only when the title
/// column can give up their cells and still say something — this table
/// is dense, and a title clipped to `Rede` is worse than no button.
/// `M` merges the focused pull request whether or not the button fits,
/// so a narrow pane loses the convenience and not the action.
fn rowButtonsWidth(p: *Painter, title_w: u16, row: tabs.VisibleRow, selected: bool) u16 {
    const app = p.app;
    if (!selected or row != .pr) return 0;
    const repos = switch (app.activeTab().data) {
        .repo_pr_tree => |r| r,
        else => return 0,
    };
    if (row.pr.repo >= repos.len or row.pr.idx >= repos[row.pr.repo].prs.len) return 0;
    const pr = repos[row.pr.repo].prs[row.pr.idx];
    var total = Painter.width(open_caption);
    if (pr.isOpen()) {
        var kbuf: [256]u8 = undefined;
        const row_key = app_mod.App.prRowKey(&kbuf, repos[row.pr.repo].slug, pr.id);
        var abuf: [32]u8 = undefined;
        var mbuf: [16]u8 = undefined;
        const state = app.actions.state(row_key, "merge");
        const shown = if (state == .idle) sdk.pane.merge.caption(&mbuf) else sdk.pane.action.caption(&abuf, state, sdk.pane.merge.label, app.spin, !p.nerd);
        total += 1 + Painter.width(shown);
    }
    // Below this the row keeps its words instead.
    if (title_w < total + title_floor) return 0;
    return total + 1;
}

fn paintRowButtons(p: *Painter, x0: u16, y: u16, w: u16, bw: u16, idx: usize, row: tabs.VisibleRow) Allocator.Error!void {
    const app = p.app;
    const repos = switch (app.activeTab().data) {
        .repo_pr_tree => |r| r,
        else => return,
    };
    const slug = repos[row.pr.repo].slug;
    const pr = repos[row.pr.repo].prs[row.pr.idx];
    var kbuf: [256]u8 = undefined;
    const row_key = app_mod.App.prRowKey(&kbuf, slug, pr.id);

    var x = x0 + w -| bw + 1;
    const ow = Painter.width(open_caption);
    _ = p.text(x, y, ow, open_caption, p.th.chip());
    p.target(x, y, ow, .{ .pr_button = .{ .row = idx, .which = .open } });
    x += ow + 1;
    // A merged or declined pull request has nothing to merge.
    if (!pr.isOpen()) return;
    const state = app.actions.state(row_key, "merge");
    var abuf: [32]u8 = undefined;
    var mbuf: [16]u8 = undefined;
    const shown = if (state == .idle) sdk.pane.merge.caption(&mbuf) else sdk.pane.action.caption(&abuf, state, sdk.pane.merge.label, app.spin, !p.nerd);
    const mw = Painter.width(shown);
    if (state != .idle) {
        // Once a merge session exists the button follows IT: the
        // spinner, the `⏸`, the `[ view ]`, the `✗` — readiness has
        // had its say.
        _ = p.text(x, y, mw, shown, sdk.pane.action.styleOf(p.th, state));
        p.target(x, y, mw, .{ .pr_button = .{ .row = idx, .which = .merge } });
        return;
    }
    const r = app.readinessOf(slug, pr);
    _ = p.text(x, y, mw, shown, sdk.pane.merge.styleOf(p.th, r));
    if (sdk.pane.merge.isPressable(r)) {
        p.target(x, y, mw, .{ .pr_button = .{ .row = idx, .which = .merge } });
    } else {
        p.target(x, y, mw, .{ .merge_blocked = idx });
    }
}

fn cellsBefore(rows: []const tabs.VisibleRow, first: usize) usize {
    var n: usize = 0;
    for (rows[0..@min(first, rows.len)]) |r| n += r.height();
    return n;
}

fn emptyMessage(kind: cfg.Kind) []const u8 {
    return switch (kind) {
        .pull_requests, .workspace_open_prs, .workspace_merged_prs => "(no PRs match this tab)",
        .pipelines => "(no pipelines have run on this repo)",
        .branches => "(no branches in this repo)",
        .workspace_pipelines => "(no repos in scope)",
    };
}

/// Spans left to right; a span with `w` pads or clips to it.
fn paintSpans(p: *Painter, x0: u16, y: u16, max_w: u16, spans: []const view.Span) void {
    var x = x0;
    const end = x0 + max_w;
    for (spans) |s| {
        if (x >= end) break;
        const room = end - x;
        if (s.w == 0) {
            x += p.text(x, y, room, s.text, s.style);
        } else {
            const w = @min(s.w, room);
            p.fill(.{ .x = x, .y = y, .w = w, .h = 1 }, s.style);
            _ = p.text(x, y, w, s.text, s.style);
            x += w;
        }
    }
}

/// The merge confirm: what it is about, in its own words.
fn paintMergeConfirm(p: *Painter) Allocator.Error!void {
    const c = p.app.merge_confirm orelse return;
    const w: u16 = @min(p.f.cols -| 6, 72);
    const h: u16 = 8;
    if (p.f.cols < 24 or p.f.rows < h + 2) return;
    const box: sdk.pane.Rect = .{
        .x = (p.f.cols -| w) / 2,
        .y = (p.f.rows -| h) / 2,
        .w = w,
        .h = h,
    };
    var hbuf: [160]u8 = undefined;
    var bbuf: [160]u8 = undefined;
    var sbuf: [160]u8 = undefined;
    try p.c.confirmBox(
        box,
        c.confirm.heading(&hbuf),
        &.{
            c.confirm.title,
            c.confirm.branchLine(&bbuf),
            c.confirm.strategyLine(&sbuf),
            "merged by a Claude Code session, not by this pane",
        },
        " Merge ",
        .confirm_ok,
        " Cancel ",
        .confirm_cancel,
        .confirm_body,
    );
}

// ─── the detail ──────────────────────────────────────────────────────────

fn paintDetail(arena: Allocator, p: *Painter, box: Box) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    if (box.w < 6 or box.h == 0) return;
    // The panel's own door for the pointer: the body takes the wheel,
    // the `\u{d7}` in the corner closes it (Esc still does too).
    try p.c.detailPanel(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, .detail, .detail_close);
    const inner_x = box.x + 1;
    const inner_w = box.w -| 2;
    const rows = (try app.visible(arena)).rows;
    const key = app.focusedKey(rows) orelse {
        _ = p.text(inner_x, box.y, inner_w, "(no PR focused)", th.mutedText());
        return;
    };
    var kbuf: [256]u8 = undefined;
    const title = App.keyText(&kbuf, key);
    const entry = app.focusedDetail(rows) orelse {
        _ = p.text(inner_x, box.y, inner_w, title, th.accentText());
        const msg: []const u8 = if (app.detailInFlight(rows)) "loading detail…" else "(no detail cached — press d to refresh)";
        if (box.h > 1) _ = p.text(inner_x, box.y + 1, inner_w, msg, th.mutedText());
        return;
    };
    const me = if (app.config.account_id.len > 0) app.config.account_id else app.me_account_id;
    const lines = try view.detailLines(arena, entry, title, me, inner_w, th);
    const max_scroll = lines.len -| box.h;
    if (app.detail_scroll > max_scroll) app.detail_scroll = max_scroll;
    var y = box.y;
    var i = app.detail_scroll;
    while (i < lines.len and y < box.y + box.h) : (i += 1) {
        paintSpans(p, inner_x, y, inner_w, lines[i].spans);
        y += 1;
    }
    app.detail_lines = lines.len;
    app.detail_rows = box.h;
    // A scrollbar that means something: the thumb says where you are,
    // and a press or a drag on the track goes there.
    if (lines.len > box.h) try p.c.scrollbar(.{ .x = box.x + box.w - 1, .y = box.y + 1, .w = 1, .h = box.h -| 1 }, lines.len, app.detail_scroll, box.h, .detail_bar);
}

// ─── the hint row ─────────────────────────────────────────────────────────

/// What the hint row says when a mode owns the keyboard: the keys that
/// mode answers to, not the list's. The list's own row comes from the
/// keymap table below.
fn modeHint(app: *App) ?[]const u8 {
    return switch (app.mode) {
        .list => null,
        .filter => "type to filter · ⏎ commit · esc clear · ^u wipe · ↑↓ leave",
        .menu => "↑↓ / jk move · ⏎ run · esc close",
        .help => "j k scroll · any other key closes",
        .confirm => "⏎ merge through Claude Code · ←→ strategy · esc cancel",
    };
}

fn paintHintRow(arena: Allocator, p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    if (modeHint(app)) |line| {
        const status = app.status.items;
        var x: u16 = 1;
        if (status.len > 0) x += p.text(x, y, p.f.cols / 2, status, th.mutedText()) + 2;
        const w = Painter.width(line);
        const at: u16 = if (p.f.cols -| w > x) p.f.cols -| w else x;
        _ = p.text(at, y, p.f.cols -| at, line, th.dimText());
        return;
    }
    const rows = (try app.visible(arena)).rows;
    // A dim `[ Merge ]` owes the reader a reason, and the hint row is
    // where it goes: the pointer is already there.
    if (app.hoverNote().len > 0) {
        _ = p.text(1, y, p.f.cols -| 2, app.hoverNote(), th.warn());
        return;
    }
    const ctx = app.keyContext(rows);
    const hs = try view.hints(arena, ctx);
    // The status on the left takes what the hints leave.
    const sep = " · ";
    const sep_w: u16 = 3;
    var widths = try arena.alloc(u16, hs.len);
    var total: u16 = 0;
    for (hs, 0..) |h, i| {
        widths[i] = Painter.width(h.key) + 1 + Painter.width(h.title);
        total += widths[i] + if (i + 1 < hs.len) sep_w else 0;
    }
    const status = app.status.items;
    const status_w: u16 = @min(Painter.width(status) + 2, p.f.cols / 2);
    var first: usize = 0;
    // Drop hints from the front until the row fits, keeping `q`.
    while (first < hs.len and total + status_w > p.f.cols) {
        total -= widths[first] + if (first + 1 < hs.len) sep_w else 0;
        first += 1;
    }
    if (status.len > 0) _ = p.text(1, y, p.f.cols -| 1 -| total, status, th.mutedText());
    var x: u16 = p.f.cols -| total;
    var i = first;
    while (i < hs.len) : (i += 1) {
        const h = hs[i];
        const start = x;
        x += p.text(x, y, p.f.cols -| x, h.key, .{ .fg = th.fg, .mods = .{ .bold = true } });
        x += p.text(x, y, p.f.cols -| x, " ", th.dimText());
        x += p.text(x, y, p.f.cols -| x, h.title, th.dimText());
        p.target(start, y, x - start, .{ .hint = h.action });
        if (i + 1 < hs.len) x += p.text(x, y, p.f.cols -| x, sep, th.dimText());
    }
}

// ─── overlays ────────────────────────────────────────────────────────────

fn paintMenu(arena: Allocator, p: *Painter) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const m = app.menu orelse return;
    var w: u16 = 0;
    for (m.items) |a| {
        const b = keymap.bindingOf(a) orelse continue;
        w = @max(w, Painter.width(b.title) + Painter.width(keymap.keyLabel(b.keys[0])) + 5);
    }
    const h: u16 = @intCast(m.items.len + 2);
    const x: u16 = if (m.col + w + 2 <= p.f.cols) m.col else p.f.cols -| (w + 2);
    const y: u16 = if (m.y + 1 + h <= p.f.rows) m.y + 1 else m.y -| h;
    const box: Box = .{ .x = x, .y = y, .w = w + 2, .h = h };
    p.fill(box, .{ .fg = th.fg, .bg = th.cursor_line });
    paintFrame(p, box, th.overlayBorder());
    for (m.items, 0..) |a, i| {
        const b = keymap.bindingOf(a) orelse continue;
        const row_y = y + 1 + @as(u16, @intCast(i));
        const selected = i == m.selected;
        const style: Style = if (selected) th.chipActive() else .{ .fg = th.fg, .bg = th.cursor_line };
        p.fill(.{ .x = x + 1, .y = row_y, .w = w, .h = 1 }, style);
        const line = try std.fmt.allocPrint(arena, " {s}", .{b.title});
        _ = p.text(x + 1, row_y, w, line, style);
        const key = keymap.keyLabel(b.keys[0]);
        _ = p.text(x + 1 + w -| (Painter.width(key) + 1), row_y, Painter.width(key), key, .{ .fg = if (selected) style.fg else th.muted, .bg = style.bg });
        p.app.hits.add(.{ .x = x, .y = row_y, .w = w + 2, .h = 1 }, .{ .menu_item = i });
    }
}

fn paintFrame(p: *Painter, b: Box, style: Style) void {
    if (b.w < 2 or b.h < 2) return;
    const right = b.x + b.w - 1;
    const bottom = b.y + b.h - 1;
    p.f.put(b.x, b.y, "┌", style);
    p.f.put(right, b.y, "┐", style);
    p.f.put(b.x, bottom, "└", style);
    p.f.put(right, bottom, "┘", style);
    var x = b.x + 1;
    while (x < right) : (x += 1) {
        p.f.put(x, b.y, "─", style);
        p.f.put(x, bottom, "─", style);
    }
    var y = b.y + 1;
    while (y < bottom) : (y += 1) {
        p.f.put(b.x, y, "│", style);
        p.f.put(right, y, "│", style);
    }
}

/// The key sheet: mnml's help shape — a centred box, a section
/// header per group, `key  title` rows, the hint at the bottom.
fn paintSheet(arena: Allocator, p: *Painter) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const w: u16 = @min(p.f.cols -| 4, 70);
    const h: u16 = @min(p.f.rows -| 2, 40);
    if (w < 20 or h < 6) return;
    const x = (p.f.cols - w) / 2;
    const y = (p.f.rows - h) / 2;
    const box: Box = .{ .x = x, .y = y, .w = w, .h = h };
    p.fill(box, .{ .fg = th.fg, .bg = th.cursor_line });
    paintFrame(p, box, th.overlayBorder());
    _ = p.text(x + 2, y, 10, " Keys ", .{ .fg = th.accent, .bg = th.cursor_line, .mods = .{ .bold = true } });
    p.app.hits.add(.{ .x = x, .y = y, .w = w, .h = h }, .sheet);
    // The rows: a header per section, then its bindings.
    const Row = union(enum) { section: []const u8, binding: keymap.Binding };
    var rows: std.ArrayList(Row) = .empty;
    for (keymap.sections) |sec| {
        try rows.append(arena, .{ .section = sec });
        for (&keymap.table) |b| if (std.mem.eql(u8, b.section, sec)) try rows.append(arena, .{ .binding = b });
    }
    const body_h = h -| 3;
    const max_scroll = rows.items.len -| body_h;
    if (app.help_scroll > max_scroll) app.help_scroll = max_scroll;
    var ry = y + 1;
    var i = app.help_scroll;
    while (i < rows.items.len and ry < y + 1 + body_h) : (i += 1) {
        switch (rows.items[i]) {
            .section => |name| {
                const line = try std.fmt.allocPrint(arena, "── {s} ──", .{name});
                _ = p.text(x + 2, ry, w -| 4, line, .{ .fg = th.accent, .bg = th.cursor_line, .mods = .{ .bold = true } });
            },
            .binding => |b| {
                var keys: std.ArrayList(u8) = .empty;
                for (b.keys, 0..) |k, ki| {
                    if (ki > 0) try keys.appendSlice(arena, " ");
                    try keys.appendSlice(arena, keymap.keyLabel(k));
                }
                _ = p.text(x + 4, ry, 14, keys.items, .{ .fg = th.accent, .bg = th.cursor_line });
                const scope: []const u8 = switch (b.scope) {
                    .any => "",
                    .tree => "  (tree)",
                    .row => "  (row)",
                    .detail => "  (detail open)",
                };
                const line = try std.fmt.allocPrint(arena, "{s}{s}", .{ b.title, scope });
                _ = p.text(x + 19, ry, w -| 21, line, .{ .fg = th.fg, .bg = th.cursor_line });
                // A row of the sheet runs what its chord runs: reading
                // the keys and using them are the same gesture.
                p.app.hits.add(.{ .x = x + 1, .y = ry, .w = w -| 2, .h = 1 }, .{ .sheet_row = b.action });
            },
        }
        ry += 1;
    }
    _ = p.text(x + 2, y + h - 2, w -| 4, "j/k scroll · any other key closes", .{ .fg = th.muted, .bg = th.cursor_line });
}

// ─── the text of a frame, for the tests ──────────────────────────────────

/// Row `y` as text, a wide glyph's tail skipped.
pub fn rowText(arena: Allocator, f: *sdk.Frame, y: u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) {
        const s = f.slots[@as(usize, y) * f.cols + x].symbol();
        if (s.len == 0) continue;
        try out.appendSlice(arena, s);
    }
    return std.mem.trimEnd(u8, try out.toOwnedSlice(arena), " ");
}

pub fn screenText(arena: Allocator, f: *sdk.Frame) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        if (y > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, try rowText(arena, f, y));
    }
    return out.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const Rig = app_mod.Rig;

const acme: cfg.Config = .{ .email = "me@x.com", .workspace = "acme", .repos = &.{ "api", "web" }, .refresh_interval_secs = 0, .tabs = &cfg.default_tabs };

const Screen = struct {
    rig: *Rig,
    frame: sdk.Frame,
    arena: std.heap.ArenaAllocator,

    fn init(cols: u16, rows: u16, config: cfg.Config, opts: app_mod.Options) !*Screen {
        const s = try t.allocator.create(Screen);
        s.rig = try Rig.init(config, opts);
        s.frame = try sdk.Frame.init(t.allocator, cols, rows);
        s.arena = std.heap.ArenaAllocator.init(t.allocator);
        return s;
    }

    fn deinit(s: *Screen) void {
        s.frame.deinit();
        s.rig.deinit();
        s.arena.deinit();
        t.allocator.destroy(s);
    }

    fn draw(s: *Screen) ![]const u8 {
        _ = s.arena.reset(.retain_capacity);
        try paint(s.arena.allocator(), &s.frame, &s.rig.app, true);
        return screenText(s.arena.allocator(), &s.frame);
    }

    fn key(s: *Screen, spec: []const u8) !void {
        _ = try s.rig.key(spec);
    }

    fn click(s: *Screen, col: u16, row: u16, button: App.Button) !void {
        _ = try s.rig.app.click(col, row, button);
        try s.rig.drain();
    }

    fn rowOf(s: *Screen, text: []const u8) !u16 {
        const scr = try s.draw();
        var it = std.mem.splitScalar(u8, scr, '\n');
        var y: u16 = 0;
        while (it.next()) |line| : (y += 1) if (std.mem.indexOf(u8, line, text) != null) return y;
        std.debug.print("no row contains `{s}`:\n{s}\n", .{ text, scr });
        return error.NoSuchRow;
    }
};

fn has(scr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, scr, needle) != null;
}

test "the pane paints the header, the strip, the pill, the reference's columns, the rows and the hint row" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    const scr = try s.draw();
    try t.expect(has(scr, "BITBUCKET PRS"));
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(has(scr, " 1 Open + Draft (3) "));
    try t.expect(has(scr, " 2 Merged (2) "));
    try t.expect(has(scr, " 3 Pipelines (2)"));
    try t.expect(has(scr, "/ filter"));
    try t.expect(has(scr, "REPO / #PR"));
    try t.expect(has(scr, "STATE"));
    try t.expect(has(scr, "AUTHOR"));
    try t.expect(has(scr, "BRANCH"));
    try t.expect(has(scr, "UPDATED"));
    try t.expect(has(scr, "TITLE"));
    try t.expect(has(scr, "▌ ▾ api"));
    try t.expect(has(scr, "2 PRs"));
    try t.expect(has(scr, "#1234"));
    try t.expect(has(scr, "Fix the login redirect"));
    try t.expect(has(scr, "chris/fix-login"));
    try t.expect(has(scr, "Show more (1)"));
    try t.expect(has(scr, "author: all"));
    try t.expect(has(scr, "Open + Draft · 2 repos, 3 PRs"));
    try t.expect(has(scr, "⏎ expand"));
    try t.expect(has(scr, "q quit"));
    // The reference paints four chips that do nothing when clicked
    // (`filter not wired yet (round-1 visual)`). None of them is here,
    // on either family — the `/` pill is what replaced the fifth, its
    // Search chip.
    // `draw` resets the screen arena, so the first screen has to be
    // taken out of it before the second one is drawn.
    const first = try t.allocator.dupe(u8, scr);
    defer t.allocator.free(first);
    try s.key("3");
    const pipelines = try s.draw();
    for ([_][]const u8{ "Target branch", "Pipeline type", "Trigger type" }) |dead_chip| {
        try t.expect(!has(first, dead_chip));
        try t.expect(!has(pipelines, dead_chip));
    }
    // `Branch ▾` was the fourth; the pipelines tree's column header is
    // the only `BRANCH` on the screen.
    try t.expect(!has(pipelines, "Branch ▾"));
    try t.expect(!has(pipelines, "[ Branch"));
    try t.expect(has(pipelines, "REPO / BRANCH"));
}

test "a click on a row selects that row and toggles a header; the strip switches tabs; the hints fire" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    const y_1234 = try s.rowOf("OPEN       Chris M");
    try s.click(10, y_1234, .left);
    try t.expectEqual(@as(usize, 1), s.rig.app.tabs[0].selected);
    var scr = try s.draw();
    // The cursor's marker, the row's own chevron (every PR has builds
    // to fold out now), then its number.
    try t.expect(has(scr, "▌   \u{25b8} #1234"));
    const y_api = try s.rowOf("▾ api");
    try s.click(3, y_api, .left);
    scr = try s.draw();
    try t.expect(has(scr, "▸ api"));
    // The header keeps its preview of #1234; the PR row itself is gone.
    try t.expect(has(scr, "#1234 · Fix the login"));
    try t.expect(!has(scr, "Fix the login redirect"));
    // The strip.
    const hit_tab = s.rig.app.hits.rectOf(.{ .tab = 1 }).?;
    try s.click(hit_tab.x + 2, hit_tab.y, .left);
    try t.expectEqual(@as(usize, 1), s.rig.app.active);
    scr = try s.draw();
    try t.expect(has(scr, "MERGED"));
    try t.expect(has(scr, "#1100"));
    // A hint word is a key: `q` quits.
    _ = try s.draw();
    const hint_q = s.rig.app.hits.rectOf(.{ .hint = .quit }).?;
    try t.expect(!(try s.rig.app.click(hint_q.x, hint_q.y, .left)));
}

test "a PR folds out to its builds under enter, one row per run, and the detail paints beside the list" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    try s.key("2");
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, "▸ #1100"));
    try s.key("enter");
    scr = try s.draw();
    try t.expect(has(scr, "\u{25be} #1100"));
    // The toolkit's build line, the same one the Jira pane paints:
    // state, branch, age, number.
    try t.expect(has(scr, "\u{2713} SUCCESSFUL \u{b7} main \u{b7} "));
    try t.expect(has(scr, "\u{b7} #412"));
    try s.key("d");
    scr = try s.draw();
    try t.expect(has(scr, "acme/api#1100"));
    try t.expect(has(scr, "MERGED · sam/drop-exporter → main"));
    try t.expect(has(scr, "author: Sam K"));
    try t.expect(has(scr, "✓ you approved · 1 total"));
    try t.expect(has(scr, "(no description)"));
    try t.expect(has(scr, "comments (0, most-recent first):"));
    try t.expect(has(scr, "│"));
    // Below 100 columns the detail takes the body.
    const narrow = try Screen.init(80, 24, acme, .{});
    defer narrow.deinit();
    try narrow.key("j");
    try narrow.key("d");
    const nscr = try narrow.draw();
    try t.expect(has(nscr, "acme/api#1234"));
    try t.expect(has(nscr, "○ not approved · 1 total"));
    // A comment's body, wrapped into the narrow panel. (Dana's "Nice
    // catch" is the oldest of the three and now sits one row below the
    // fold — the tab strip's rule costs the body a row.)
    try t.expect(has(nscr, "withQuery needs to escape"));
    try t.expect(!has(nscr, "REPO / #PR"));
}

test "the cursor's PR row grows its buttons, the Merge is dim, and hovering it says why" {
    // Wide enough for the row to give up the cells: at 120 the title
    // would pay for them, so the buttons are not offered there and the
    // `M` key and the row menu carry the action instead.
    const s = try Screen.init(200, 40, acme, .{});
    defer s.deinit();
    // The cursor onto #1234.
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, "[ Open ] [ Merge ]"));
    // Only the row under the cursor carries them: the table is dense,
    // and the title is the column that would otherwise pay.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, scr, "[ Merge ]"));

    // Nothing has judged it, so the button registers `merge_blocked`
    // rather than a `pr_button`: a stray click cannot merge anything.
    const at = s.rig.app.hits.rectOf(.{ .merge_blocked = 1 }).?;
    try t.expect(s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .merge } }) == null);
    // …and the pointer resting on it puts the reason on the hint row.
    s.rig.app.hover(at.x + 2, at.y);
    scr = try s.draw();
    try t.expect(has(scr, "Merge: not checked yet"));

    // Judged and blocked: the reason names the condition and its count.
    const ts = s.rig.app.activeTab();
    const pr = ts.data.repo_pr_tree[0].prs[0];
    try s.rig.app.putReadiness("api#1234", pr.updated_on, .{ .approvals = 1, .required = 2, .conflicts = false, .build_green = true, .checked = true });
    s.rig.app.hover(at.x + 2, at.y);
    scr = try s.draw();
    try t.expect(has(scr, "Merge: 1 of 2 approvals"));

    // Ready: the button becomes a real target, and the pointer moving
    // off it takes the sentence away with it.
    try s.rig.app.putReadiness("api#1234", pr.updated_on, .{ .approvals = 2, .required = 2, .conflicts = false, .build_green = true, .checked = true });
    scr = try s.draw();
    try t.expect(s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .merge } }) != null);
    s.rig.app.hover(0, 0);
    scr = try s.draw();
    try t.expect(!has(scr, "Merge: "));

    // Confirming it names the pull request rather than asking "are you
    // sure?" about nothing in particular.
    try s.rig.app.pressMerge("api", pr);
    scr = try s.draw();
    try t.expect(has(scr, "Merge acme/api/pull-requests/1234"));
    try t.expect(has(scr, "Fix the login redirect"));
    try t.expect(has(scr, "chris/fix-login \u{2192} main"));
    try t.expect(has(scr, "strategy: merge commit"));
    try t.expect(has(scr, "merged by a Claude Code session, not by this pane"));
    try t.expect(has(scr, " Merge "));
    try t.expect(has(scr, " Cancel "));
    // Esc takes it away without doing anything.
    try s.key("esc");
    scr = try s.draw();
    try t.expect(!has(scr, "Merge acme/api/pull-requests/1234"));
}

test "the awaiting chip says its count, narrows the tab, and the header says what it narrowed" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    var scr = try s.draw();
    // At rest: the chip carries its number beside `author:`.
    try t.expect(has(scr, "awaiting: 1"));
    try t.expect(has(scr, "author: all"));
    try t.expect(has(scr, "(2 repos \u{b7} 3 PRs)"));
    try t.expect(has(scr, "#1234"));

    // `A` is the same door the chip is — a chip nobody can reach from
    // the keyboard is half a feature. (mnml spells it `shift+a`.)
    try s.key("shift+a");
    scr = try s.draw();
    try t.expect(has(scr, "(1 of 3 awaiting my review)"));
    // Only Dana's #1198, which I am a reviewer on and have not voted.
    try t.expect(has(scr, "#1198"));
    try t.expect(!has(scr, "Fix the login redirect"));
    // …and it is 30 hours old, so the 24-hour window the tree usually
    // folds it behind is lifted rather than hiding the very thing the
    // chip is for.
    try t.expect(!has(scr, "Show more"));

    // The chip itself toggles it back.
    const chip = s.rig.app.hits.rectOf(.{ .chip = .awaiting }).?;
    try s.click(chip.x + 1, chip.y, .left);
    scr = try s.draw();
    try t.expect(has(scr, "(2 repos \u{b7} 3 PRs)"));
    try t.expect(has(scr, "Fix the login redirect"));
}

test "an OPEN PR folds out to the builds on its branch head; a second open costs nothing while it has not moved" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    // The cursor onto #1234, the open pull request the account authored.
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, "\u{25b8} #1234"));
    const served = s.rig.srv.state.served;
    try s.key("enter");
    try s.rig.drain();
    scr = try s.draw();
    try t.expect(has(scr, "\u{25be} #1234"));
    // One run on `chris/fix-login`'s head, in the toolkit's words.
    try t.expect(has(scr, "\u{23f5} IN_PROGRESS \u{b7} chris/fix-login \u{b7} "));
    try t.expect(has(scr, "\u{b7} #413"));
    // One request paid for it: the repo's pipelines list.
    try t.expectEqual(@as(u32, 1), s.rig.srv.state.served - served);

    // Fold shut and open again: nothing is asked for, because the pull
    // request has not moved since the runs were read.
    try s.key("enter");
    try s.rig.drain();
    try s.key("enter");
    try s.rig.drain();
    try t.expectEqual(@as(u32, 1), s.rig.srv.state.served - served);
    scr = try s.draw();
    try t.expect(has(scr, "\u{b7} #413"));

    // The build line is a door: Enter on it opens that run's page.
    const rows = try s.rig.rows();
    var build_row: ?usize = null;
    for (rows, 0..) |r, i| if (r == .build) {
        build_row = i;
        break;
    };
    s.rig.app.tabs[0].selected = build_row.?;
    // Straight at the app: the rig's own `key` drains the effects,
    // and the effect IS what this asserts.
    _ = try s.rig.app.keyPress("enter");
    const fx = s.rig.app.takeEffects();
    defer s.rig.app.freeEffects(fx);
    // The page, and the toast that says which page.
    try t.expectEqual(@as(usize, 2), fx.len);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pipelines/results/413", fx[0].open_url);
}

test "the pipelines tree paints the reference's columns and glyphs; the pipelines chips are on the header" {
    const s = try Screen.init(120, 40, acme, .{ .only = .pipelines });
    defer s.deinit();
    const scr = try s.draw();
    try t.expect(has(scr, "BITBUCKET PIPELINES"));
    try t.expect(!has(scr, " 1 Pipelines"));
    try t.expect(has(scr, "REPO / BRANCH"));
    try t.expect(has(scr, "BUILD"));
    try t.expect(has(scr, "RESULT"));
    try t.expect(has(scr, "▾ api"));
    try t.expect(has(scr, "4 branches"));
    try t.expect(has(scr, "main"));
    try t.expect(has(scr, "COMPLETED"));
    try t.expect(has(scr, "#412"));
    try t.expect(has(scr, "✓ SUCCESSFUL"));
    try t.expect(has(scr, "✗ FAILED"));
    try t.expect(has(scr, "IN_PROGRESS"));
    try t.expect(has(scr, "run pipeline"));
    try t.expect(has(scr, "usage"));
    try t.expect(s.rig.app.hits.rectOf(.{ .chip = .usage }) != null);
}

test "the key sheet, the row menu and the filter paint as overlays that take the click" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    try s.key("?");
    var scr = try s.draw();
    try t.expect(has(scr, " Keys "));
    try t.expect(has(scr, "── tree ──"));
    try t.expect(has(scr, "hide this repo (persists)"));
    try t.expect(has(scr, "approve / withdraw the approval"));
    try s.click(60, 20, .left);
    try t.expectEqual(app_mod.Mode.list, s.rig.app.mode);
    _ = try s.draw();
    const y_1234 = try s.rowOf("OPEN       Chris M");
    try s.click(10, y_1234, .right);
    scr = try s.draw();
    try t.expect(has(scr, "the pull request's detail"));
    try t.expect(has(scr, "open on the web"));
    const item = s.rig.app.hits.rectOf(.{ .menu_item = 1 }).?;
    try s.click(item.x + 2, item.y, .left);
    try t.expect(std.mem.startsWith(u8, s.rig.app.status.items, "opened https://bitbucket.org/acme/api/pull-requests/1234"));
    try s.key("/");
    for ("login") |c| try s.key(&[_]u8{c});
    scr = try s.draw();
    try t.expect(has(scr, "login▏"));
    try t.expect(has(scr, "Fix the login redirect"));
    try t.expect(!has(scr, "Redesign the empty"));
}

test "the pane paints at every size the gate runs, and at one below them" {
    for ([_][2]u16{ .{ 30, 10 }, .{ 80, 24 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        const s = try Screen.init(size[0], size[1], acme, .{});
        defer s.deinit();
        _ = try s.draw();
        try s.key("d");
        _ = try s.draw();
        try s.key("?");
        _ = try s.draw();
        try s.key("esc");
        try s.key("3");
        _ = try s.draw();
    }
}

test "the `/` filter: the header reads N of M while narrowed and the hint row changes with the mode" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    // Unnarrowed the header carries the tab's own count and the hint
    // row is the keymap's.
    var scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(!has(scr, " of "));
    try t.expect(has(scr, "q quit"));

    // `/` opens the pill and hands the keyboard to the filter: the row
    // says what the filter answers to, not what the list does.
    try s.key("/");
    scr = try s.draw();
    try t.expect(has(scr, "type to filter"));
    try t.expect(has(scr, "⏎ commit"));
    try t.expect(has(scr, "esc clear"));
    try t.expect(!has(scr, "q quit"));

    // Typing narrows live — before Enter commits anything.
    for ("empty") |c| try s.key(&[_]u8{c});
    scr = try s.draw();
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "Redesign the empty"));
    // #1234 is gone as a row — the api header still previews it, which
    // is why the row count, not the title, is what proves the narrowing.
    try t.expectEqual(@as(usize, 1), s.rig.app.filter_shown);
    try t.expectEqual(@as(usize, 2), s.rig.app.filter_total);

    // Enter commits: the query stays, the narrowed count stays, the
    // hint row goes back to the list's keys.
    try s.key("enter");
    scr = try s.draw();
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "empty"));
    try t.expect(has(scr, "q quit"));
    try t.expect(!has(scr, "type to filter"));

    // Esc clears and leaves.
    try s.key("esc");
    scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(!has(scr, " of 2)"));

    // The menu and the sheet own the row the same way.
    try s.key("j");
    try s.click(6, try s.rowOf("#1234"), .right);
    scr = try s.draw();
    try t.expect(has(scr, "⏎ run"));
    try s.key("esc");
    try s.key("?");
    scr = try s.draw();
    try t.expect(has(scr, "scroll"));
}

/// Right-click the row the painter registered at `i` — through the
/// real hit map, so a row whose rectangle is wrong or missing fails
/// here rather than passing on a hand-built map.
fn rightClickRow(s: *Screen, i: usize) !void {
    _ = try s.draw();
    const r = s.rig.app.hits.rectOf(.{ .row = i }) orelse return error.NoHitForRow;
    try s.click(r.x + 2, r.y, .right);
}

fn menuItems(s: *Screen) []const app_mod.Action {
    return if (s.rig.app.menu) |m| m.items else &.{};
}

test "a right-click offers the actions of the row kind under it — every kind, off the painted hit map" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    var rows = try s.rig.rows();

    // The tree is api(#1234), web(#820), `Show more (1)`.
    try t.expect(rows[0] == .repo_header);
    try t.expect(rows[1] == .pr);
    try t.expect(rows[rows.len - 1] == .show_more);

    // A repo row: fold it, open it, copy it, hide it, move it.
    try rightClickRow(s, 0);
    try t.expectEqual(app_mod.Mode.menu, s.rig.app.mode);
    try t.expectEqual(@as(usize, 0), s.rig.app.menu.?.row);
    try t.expectEqualSlices(app_mod.Action, &.{ .activate, .open_web, .yank_url, .hide_repo, .reorder_up, .reorder_down }, menuItems(s));
    try s.key("esc");

    // A PR row: its detail, its page, its URL, and Enter — which folds
    // out its builds, on an open pull request as much as a merged one.
    // No approve: the reference binds `a` only with the detail open, so
    // the menu cannot offer it either.
    try rightClickRow(s, 1);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate, .merge_pr }, menuItems(s));
    try t.expectEqual(@as(usize, 1), s.rig.app.tabs[0].selected);
    try s.key("esc");

    // The same row with the detail open gains the one write.
    try s.key("d");
    try rightClickRow(s, 1);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate, .merge_pr, .toggle_approval }, menuItems(s));
    try s.key("esc");
    try s.key("d");

    // The `Show more (N)` footer lifts the window and nothing else.
    try rightClickRow(s, rows.len - 1);
    try t.expectEqualSlices(app_mod.Action, &.{.activate}, menuItems(s));
    try s.key("esc");

    // A merged PR folds out to the runs on what landed — the same
    // Enter, a different commit.
    try s.key("m");
    rows = try s.rig.rows();
    var merged: ?usize = null;
    for (rows, 0..) |r, i| if (r == .pr) {
        merged = i;
        break;
    };
    try rightClickRow(s, merged.?);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate }, menuItems(s));
    try s.key("esc");

    // A branch row on the pipelines tree: the run's page and its URL.
    try s.key("3");
    rows = try s.rig.rows();
    var branch: ?usize = null;
    for (rows, 0..) |r, i| if (r == .branch) {
        branch = i;
        break;
    };
    try rightClickRow(s, branch.?);
    try t.expectEqualSlices(app_mod.Action, &.{ .open_web, .yank_url }, menuItems(s));
    try t.expectEqual(branch.?, s.rig.app.tabs[2].selected);
    try s.key("esc");
    try t.expectEqual(app_mod.Mode.list, s.rig.app.mode);
}
