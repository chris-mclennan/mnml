//! Painting. Everything here reads `App` and writes an `sdk.Frame`;
//! nothing here changes state, so a screen is a pure function of the
//! app and a test can assert on the cells.
//!
//! The pane, at 120×30 with the detail open:
//!
//!     JIRA  1 Mine 5  2 Release 12                        r ⟳  ? help
//!      KEY            STATUS      ASSIGNEE      UPD   SUMMARY        │ ENG-2  Card form validates on blur
//!     ▼ ENG-1         In Progress Ada Lovelace  1d    Checkout rewri │
//!       ▼ ENG-2       In Review   Ada Lovelace  2h    Card form vali │      type  Story
//!           ENG-4     Done        Sam Beckett   1d    Wire the blur  │    status  In Review
//!         ▸ ENG-3     To Do       —             3d    Apple Pay butt │  assignee  Ada Lovelace
//!       ENG-5         To Do       Ada Lovelace  5h    Basket total w │  reporter  Sam Beckett
//!                                                                    │   version  13.16.0
//!                                                                    │
//!                                                                    │ ── description ──
//!                                                                    │ Validate the card number when the
//!     Mine · 5 tickets                                    ? for keys

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");
const tree = @import("tree.zig");

pub const App = app_mod.App;
pub const Frame = sdk.Frame;
pub const Style = sdk.Style;

/// The chevrons, and their `--ascii` twins. mnml sends `capabilities`
/// in its hello; `Chrome.ascii` carries the answer down here so one
/// switch decides every glyph.
pub const Chrome = struct {
    ascii: bool = false,
    /// `mnml.expand_indicator = .triangle` — the small pair mnml's own
    /// `$MNML_EXPAND_INDICATOR` selects.
    triangle: bool = false,

    pub fn open(c: Chrome) []const u8 {
        if (c.ascii) return "v";
        return if (c.triangle) "\u{25be}" else "\u{25bc}";
    }
    pub fn closed(c: Chrome) []const u8 {
        if (c.ascii) return ">";
        return if (c.triangle) "\u{25b8}" else "\u{25b6}";
    }
    pub fn leaf(c: Chrome) []const u8 {
        _ = c;
        return " ";
    }
    pub fn divider(c: Chrome) []const u8 {
        return if (c.ascii) "|" else "\u{2502}";
    }
    pub fn dash(c: Chrome) []const u8 {
        return if (c.ascii) "-" else "\u{2014}";
    }
    pub fn refresh(c: Chrome) []const u8 {
        return if (c.ascii) "R" else "\u{27f3}";
    }
    pub fn arrow(c: Chrome) []const u8 {
        return if (c.ascii) "->" else "\u{2192}";
    }
    pub fn tick(c: Chrome) []const u8 {
        return if (c.ascii) "v" else "\u{2713}";
    }
};

/// The whole screen.
pub fn draw(f: *Frame, a: *App, chrome: Chrome) Allocator.Error!void {
    f.clear(.none);
    if (f.cols < 8 or f.rows < 3) return;
    const p = a.palette;

    drawTabStrip(f, a, chrome);
    drawStatusLine(f, a);

    // The body: everything between the strip and the status line.
    const body_top: u16 = 1;
    const body_bottom: u16 = f.rows - 1; // exclusive
    if (body_bottom <= body_top) return;

    if (a.blocked) |lines| {
        var ly = body_top + 1;
        for (lines) |line| {
            if (ly >= body_bottom) break;
            _ = f.text(2, ly, f.cols -| 4, line, if (ly == body_top + 1) theme.fgBold(p.warn) else .none);
            ly += 1;
        }
        drawOverlay(f, a, chrome);
        return;
    }

    const detail_w: u16 = if (a.detail_open and f.cols >= 60)
        @max(28, f.cols / 100 * a.cfg.mnml.detail_width_pct)
    else
        0;
    const list_w: u16 = f.cols -| (if (detail_w > 0) detail_w + 1 else 0);

    var y = body_top;
    const t = a.tab() orelse {
        _ = f.text(1, y, list_w -| 1, "No tabs. Add one to .tabs in config.zon.", theme.dim(p));
        drawOverlay(f, a, chrome);
        return;
    };
    if (t.filter.len > 0) {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "filter: {s}   Esc clears", .{t.filter}) catch "filter";
        _ = f.text(1, y, list_w -| 1, line, theme.fg(p.accent));
        y += 1;
    }
    drawHeader(f, t, y, list_w, p);
    y += 1;
    drawRows(f, a, t, y, body_bottom, list_w, chrome);

    if (detail_w > 0) {
        var dy = body_top;
        while (dy < body_bottom) : (dy += 1) f.put(list_w, dy, chrome.divider(), theme.dim(p));
        try drawDetail(f, a, t, list_w + 1, body_top, detail_w, body_bottom, chrome);
    }
    drawOverlay(f, a, chrome);
}

fn drawTabStrip(f: *Frame, a: *App, chrome: Chrome) void {
    const p = a.palette;
    f.fill(0, 0, f.cols, 1, .{ .mods = .{ .reverse = true } });
    var x = f.text(1, 0, f.cols, "JIRA", .{ .fg = p.accent, .mods = .{ .bold = true, .reverse = true } }) + 1;
    for (a.tabs, 0..) |*t, i| {
        if (x + 6 >= f.cols) break;
        var buf: [96]u8 = undefined;
        const label = if (t.fetched)
            std.fmt.bufPrint(&buf, " {d} {s} {d} ", .{ i + 1, t.cfg.name, t.issues.len }) catch " ? "
        else
            std.fmt.bufPrint(&buf, " {d} {s} ", .{ i + 1, t.cfg.name }) catch " ? ";
        const style: Style = if (i == a.active)
            .{ .fg = p.accent, .mods = .{ .bold = true } }
        else
            .{ .mods = .{ .reverse = true, .dim = true } };
        x += f.text(x, 0, f.cols -| x, label, style);
    }
    // The right-hand hints, when there is room for them.
    var tail: [40]u8 = undefined;
    const hint = std.fmt.bufPrint(&tail, "r {s}  ? help ", .{chrome.refresh()}) catch " ? help ";
    const w = text.width(hint);
    if (f.cols > x + w + 2) _ = f.text(f.cols - w, 0, w, hint, .{ .mods = .{ .reverse = true, .dim = true } });
}

fn drawStatusLine(f: *Frame, a: *App) void {
    const p = a.palette;
    const y = f.rows - 1;
    f.fill(0, y, f.cols, 1, .none);
    const style: Style = if (a.busy) theme.fg(p.warn) else theme.dim(p);
    _ = f.text(1, y, f.cols -| 2, a.status, style);
    const t = a.tab();
    if (t) |tt| if (tt.err) |e| {
        _ = f.text(1, y, f.cols -| 2, e, theme.fg(p.err));
    };
    // The hidden-rows reminder sits at the right, where it cannot be
    // mistaken for the status.
    if (t) |tt| if (tt.state.hiddenCount() > 0) {
        var buf: [40]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, " {d} hidden · H ", .{tt.state.hiddenCount()}) catch "";
        const w = text.width(note);
        if (f.cols > w + 4) _ = f.text(f.cols - w, y, w, note, theme.fg(p.warn));
    };
}

/// The column header, and the layout every row then follows.
pub const Layout = struct {
    pub const Item = struct { col: config.Column, x: u16, w: u16 };
    items: [10]Item = @splat(.{ .col = .summary, .x = 0, .w = 0 }),
    n: usize = 0,

    pub fn slice(l: *const Layout) []const Item {
        return l.items[0..l.n];
    }
};

/// Fit the configured columns into `total` cells.
///
/// The flexible column (`summary`) takes what the fixed ones leave. When
/// that is less than a summary can usefully hold, fixed columns are
/// **dropped from the right** — never `key`, and never the flexible one —
/// until it fits. A pane beside an open sidebar is narrow, and a row of
/// metadata with the summary cut off entirely is the wrong trade: the
/// summary is what the user is reading.
pub fn layout(columns: []const config.Column, total: u16) Layout {
    const min_summary: u16 = 16;
    var keep: [10]bool = @splat(true);
    const n = @min(columns.len, keep.len);

    var flexible_at: ?usize = null;
    for (columns[0..n], 0..) |c, i| {
        if (c.width() == null and flexible_at == null) flexible_at = i;
    }

    while (true) {
        var fixed: u16 = 1;
        for (columns[0..n], 0..) |c, i| {
            if (!keep[i]) continue;
            if (c.width()) |w| fixed +|= w + 1;
        }
        if (flexible_at == null) break;
        if (total > fixed + min_summary) break;
        // Drop the rightmost fixed column that is not the key.
        var dropped = false;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (!keep[i]) continue;
            if (columns[i] == .key) continue;
            if (columns[i].width() == null) continue;
            keep[i] = false;
            dropped = true;
            break;
        }
        if (!dropped) break;
    }

    var fixed_total: u16 = 1;
    for (columns[0..n], 0..) |c, i| {
        if (!keep[i]) continue;
        if (c.width()) |w| fixed_total +|= w + 1;
    }
    const flexible: u16 = if (total > fixed_total) total - fixed_total else 0;

    var l: Layout = .{};
    var x: u16 = 1;
    for (columns[0..n], 0..) |c, i| {
        if (!keep[i]) continue;
        const w: u16 = c.width() orelse flexible;
        if (w == 0 or x + w > total) continue;
        l.items[l.n] = .{ .col = c, .x = x, .w = w };
        l.n += 1;
        x += w + 1;
    }
    return l;
}

fn drawHeader(f: *Frame, t: *const app_mod.Tab, y: u16, w: u16, p: theme.Palette) void {
    const l = layout(t.cfg.columns, w);
    for (l.slice()) |it| {
        var buf: [64]u8 = undefined;
        const head = text.fit(&buf, it.col.header(), it.w);
        _ = f.text(it.x, y, it.w, head, .{ .fg = p.muted, .mods = .{ .bold = true } });
    }
}

fn drawRows(f: *Frame, a: *App, t: *app_mod.Tab, top: u16, bottom: u16, w: u16, chrome: Chrome) void {
    const p = a.palette;
    if (t.rows.len == 0) {
        const msg: []const u8 = if (t.err != null)
            "nothing to show — the line below says why"
        else if (t.filter.len > 0)
            "nothing matches that filter"
        else if (t.fetched)
            "no tickets match this query"
        else
            "press r to load";
        _ = f.text(2, top, w -| 3, msg, theme.dim(p));
        return;
    }
    const l = layout(t.cfg.columns, w);
    var y = top;
    var i = t.scroll;
    while (y < bottom and i < t.rows.len) : ({
        y += 1;
        i += 1;
    }) {
        const on = i == t.cursor;
        const row_style: Style = if (on)
            (if (a.focused) theme.selected else theme.selectedUnfocused(p))
        else
            .none;
        if (on) f.fill(0, y, w, 1, row_style);
        switch (t.rows[i]) {
            .group => |g| {
                var buf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} {s} ({d})", .{
                    if (g.expanded) chrome.open() else chrome.closed(),
                    g.label,
                    g.count,
                }) catch g.label;
                _ = f.text(1, y, w -| 2, line, mergeBold(row_style, p.accent, on));
            },
            .issue => |ir| drawIssueRow(f, a, t, l, ir, y, w, row_style, on, chrome),
            .pr => |pr| drawPrRow(f, a, t, pr, y, w, row_style, on, chrome),
            .pr_loading => {
                _ = f.text(6, y, w -| 7, "fetching linked pull requests…", merge(row_style, p.muted, on));
            },
            .pr_more => |m| {
                var buf: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "… show all {d} more (P)", .{m.hidden}) catch "… show all";
                _ = f.text(indentOf(m.depth), y, w -| indentOf(m.depth), line, merge(row_style, p.accent, on));
            },
        }
    }
    drawScrollbar(f, t, top, bottom, w, p);
}

fn indentOf(depth: u8) u16 {
    return 1 + @as(u16, depth) * 2;
}

fn drawIssueRow(f: *Frame, a: *App, t: *app_mod.Tab, l: Layout, ir: tree.Row.IssueRow, y: u16, w: u16, row_style: Style, on: bool, chrome: Chrome) void {
    const p = a.palette;
    const it = t.issues[ir.index];
    for (l.slice()) |cell| {
        var buf: [256]u8 = undefined;
        var value: []const u8 = "";
        var colour: ?sdk.Color = p.muted;
        switch (cell.col) {
            .key => {
                const mark = if (!ir.has_children) chrome.leaf() else if (ir.expanded) chrome.open() else chrome.closed();
                const pad = indentOf(ir.depth);
                var kbuf: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&kbuf, "{s} {s}", .{ mark, it.key }) catch it.key;
                const at = cell.x + pad -| 1;
                _ = f.text(at, y, cell.w, text.fit(&buf, line, cell.w), mergeBold(row_style, p.accent, on));
                continue;
            },
            .status => {
                value = it.status;
                colour = theme.statusColor(p, it.category);
            },
            .assignee => {
                value = if (it.assignee.len > 0) it.assignee else chrome.dash();
                colour = p.muted;
            },
            .reporter => value = if (it.reporter.len > 0) it.reporter else chrome.dash(),
            .priority => {
                value = it.priority;
                colour = theme.priorityColor(p, it.priority);
            },
            .type => value = it.kind,
            .updated => value = text.ageOf(&buf, it.updated, a.now_stamp),
            .fix_version => value = if (it.fix_version.len > 0) it.fix_version else chrome.dash(),
            .summary => {
                value = it.summary;
                // The summary is the sentence: the theme's own fg, not a role.
                colour = null;
            },
            .actions => value = "t a f c o",
        }
        var fit_buf: [512]u8 = undefined;
        _ = f.text(cell.x, y, cell.w, text.fit(&fit_buf, value, cell.w), merge(row_style, colour, on));
    }
    _ = w;
}

fn drawPrRow(f: *Frame, a: *App, t: *app_mod.Tab, pr: tree.Row.PrRow, y: u16, w: u16, row_style: Style, on: bool, chrome: Chrome) void {
    const p = a.palette;
    const it = t.issues[pr.issue];
    const list = t.state.prsOf(it.key) orelse return;
    if (pr.pr >= list.len) return;
    const q = list[pr.pr];
    var buf: [320]u8 = undefined;
    const colour = if (std.ascii.eqlIgnoreCase(q.status, "MERGED"))
        p.label
    else if (q.isOpen())
        p.done
    else
        p.muted;
    const line = if (q.source_branch.len > 0)
        std.fmt.bufPrint(&buf, "{s}  {s} {s}  {s} {s} {s}{s}", .{
            q.status,
            q.repo,
            q.id,
            q.source_branch,
            chrome.arrow(),
            q.dest_branch,
            if (q.approvals > 0) " " else "",
        }) catch q.title
    else
        std.fmt.bufPrint(&buf, "{s}  {s} {s}  {s}", .{ q.status, q.repo, q.id, q.title }) catch q.title;
    const x = indentOf(pr.depth);
    var fit_buf: [512]u8 = undefined;
    const used = f.text(x, y, w -| x, text.fit(&fit_buf, line, w -| x), merge(row_style, colour, on));
    if (q.approvals > 0 and x + used + 4 < w) {
        var abuf: [16]u8 = undefined;
        const ap = std.fmt.bufPrint(&abuf, "({d}{s})", .{ q.approvals, chrome.tick() }) catch "";
        _ = f.text(x + used, y, w -| (x + used), ap, merge(row_style, p.done, on));
    }
}

fn drawScrollbar(f: *Frame, t: *const app_mod.Tab, top: u16, bottom: u16, w: u16, p: theme.Palette) void {
    const height = bottom - top;
    if (t.rows.len <= height or w < 4) return;
    const x = w - 1;
    // The thumb covers the visible share, at least one cell.
    const span = @max(1, height * height / @as(u16, @intCast(@min(t.rows.len, 65535))));
    const at = if (t.rows.len == 0) 0 else @as(u16, @intCast(t.scroll * height / t.rows.len));
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        const on = y >= at and y < at + span;
        f.put(x, top + y, if (on) "\u{2588}" else "\u{2502}", .{ .fg = if (on) p.accent else p.muted });
    }
}

fn drawDetail(f: *Frame, a: *App, t: *app_mod.Tab, x: u16, top: u16, w: u16, bottom: u16, chrome: Chrome) Allocator.Error!void {
    const p = a.palette;
    const it = t.selected() orelse {
        _ = f.text(x + 1, top, w -| 2, "no ticket selected", theme.dim(p));
        return;
    };
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();

    var lines: std.ArrayListUnmanaged(struct { s: []const u8, st: Style }) = .empty;
    const add = struct {
        fn f2(l: *@TypeOf(lines), al: Allocator, s: []const u8, st: Style) Allocator.Error!void {
            try l.append(al, .{ .s = s, .st = st });
        }
    }.f2;

    try add(&lines, ar, try std.fmt.allocPrint(ar, "{s}  {s}", .{ it.key, it.summary }), .{ .fg = p.accent, .mods = .{ .bold = true } });
    try add(&lines, ar, "", .none);
    const fields = [_][2][]const u8{
        .{ "type", it.kind },
        .{ "status", it.status },
        .{ "priority", it.priority },
        .{ "assignee", if (it.assignee.len > 0) it.assignee else chrome.dash() },
        .{ "reporter", if (it.reporter.len > 0) it.reporter else chrome.dash() },
        .{ "version", if (it.fix_version.len > 0) it.fix_version else chrome.dash() },
        // Only when there is one: `epic —` on an epic reads as a bug.
        .{ "epic", it.parent_key },
    };
    for (fields) |fd| {
        if (fd[1].len == 0) continue;
        try add(&lines, ar, try std.fmt.allocPrint(ar, "{s: >10}  {s}", .{ fd[0], fd[1] }), .none);
    }

    const detail = a.detailOf(it.key);
    if (detail == null) {
        try add(&lines, ar, "", .none);
        try add(&lines, ar, "loading the description…", theme.dim(p));
    } else {
        const d = detail.?;
        try add(&lines, ar, "", .none);
        try add(&lines, ar, try heading(ar, "description", w, chrome), .{ .fg = p.muted, .mods = .{ .bold = true } });
        if (d.description.len == 0) {
            try add(&lines, ar, "(none)", theme.dim(p));
        } else {
            for (try text.wrap(ar, d.description, w -| 2)) |ln| try add(&lines, ar, ln, .none);
        }
        // The PRs this ticket carries, read-only.
        if (t.state.prsOf(it.key)) |prs| if (prs.len > 0) {
            try add(&lines, ar, "", .none);
            try add(&lines, ar, try heading(ar, "pull requests", w, chrome), .{ .fg = p.muted, .mods = .{ .bold = true } });
            for (prs) |q| try add(&lines, ar, try std.fmt.allocPrint(ar, "{s}  {s} {s}", .{ q.status, q.repo, q.id }), .none);
        };
        if (d.comments.len > 0) {
            try add(&lines, ar, "", .none);
            try add(&lines, ar, try heading(ar, "comments", w, chrome), .{ .fg = p.muted, .mods = .{ .bold = true } });
            // Newest first, capped — an old ticket has hundreds.
            const cap = @min(d.comments.len, a.cfg.mnml.max_comments);
            var n: usize = 0;
            while (n < cap) : (n += 1) {
                const c = d.comments[d.comments.len - 1 - n];
                try add(&lines, ar, try std.fmt.allocPrint(ar, "{s}  {s}", .{ c.author, text.dayOf(c.created) }), .{ .fg = p.label });
                for (try text.wrap(ar, c.body, w -| 4)) |ln| {
                    try add(&lines, ar, try std.fmt.allocPrint(ar, "  {s}", .{ln}), .none);
                }
                try add(&lines, ar, "", .none);
            }
        }
    }

    var y = top;
    var i: usize = a.detail_scroll;
    while (y < bottom and i < lines.items.len) : ({
        y += 1;
        i += 1;
    }) {
        var buf: [1024]u8 = undefined;
        _ = f.text(x + 1, y, w -| 2, text.fit(&buf, lines.items[i].s, w -| 2), lines.items[i].st);
    }
}

fn heading(ar: Allocator, label: []const u8, w: u16, chrome: Chrome) Allocator.Error![]const u8 {
    _ = w;
    return std.fmt.allocPrint(ar, "{s}{s} {s} ", .{ chrome.dash(), chrome.dash(), label });
}

// ── overlays ────────────────────────────────────────────────────────────

fn drawOverlay(f: *Frame, a: *App, chrome: Chrome) void {
    switch (a.overlay) {
        .none => {},
        .help => drawHelp(f, a),
        .filter => |*e| drawInputBar(f, a, "filter", e),
        .picker => |*p| drawPicker(f, a, p, chrome),
        .comment => |*c| drawComment(f, a, c),
        .form => |*fm| drawForm(f, a, fm),
        .confirm => |*c| drawConfirm(f, a, c),
    }
}

/// A centred box, cleared and framed. Returns the inner rectangle.
fn box(f: *Frame, a: *App, want_w: u16, want_h: u16, title: []const u8) struct { x: u16, y: u16, w: u16, h: u16 } {
    const p = a.palette;
    const w = @min(want_w, f.cols -| 2);
    const h = @min(want_h, f.rows -| 2);
    const x = (f.cols -| w) / 2;
    const y = (f.rows -| h) / 2;
    f.fill(x, y, w, h, .{ .mods = .{ .reverse = true } });
    var buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, " {s} ", .{title}) catch title;
    _ = f.text(x + 1, y, w -| 2, head, .{ .fg = p.accent, .mods = .{ .bold = true, .reverse = true } });
    return .{ .x = x + 1, .y = y + 1, .w = w -| 2, .h = h -| 2 };
}

fn drawHelp(f: *Frame, a: *App) void {
    const p = a.palette;
    const r = box(f, a, 60, @intCast(keys.help_rows.len + 3), "keys");
    var y = r.y;
    var i: usize = a.overlay.help.scroll;
    while (y < r.y + r.h and i < keys.help_rows.len) : ({
        y += 1;
        i += 1;
    }) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s: <18}{s}", .{ keys.help_rows[i][0], keys.help_rows[i][1] }) catch "";
        _ = f.text(r.x, y, r.w, line, .{ .fg = p.accent, .mods = .{ .reverse = true } });
    }
}

fn drawInputBar(f: *Frame, a: *App, label: []const u8, e: *const app_mod.Editor) void {
    const p = a.palette;
    const y = f.rows - 1;
    f.fill(0, y, f.cols, 1, .none);
    var x = f.text(1, y, f.cols, label, theme.fg(p.accent));
    x += f.text(1 + x, y, 2, ": ", theme.dim(p)) + 1;
    const head = e.text()[0..e.cursor];
    const tail = e.text()[e.cursor..];
    x += f.text(x, y, f.cols -| x, head, .none);
    x += f.text(x, y, f.cols -| x, "\u{2502}", theme.fg(p.accent));
    _ = f.text(x, y, f.cols -| x, tail, theme.dim(p));
}

fn drawPicker(f: *Frame, a: *App, p: *const app_mod.Picker, chrome: Chrome) void {
    const pal = a.palette;
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    defer arena.deinit();
    const vis = p.visible(arena.allocator()) catch &.{};
    var tbuf: [96]u8 = undefined;
    const title = switch (p.kind) {
        .transition => std.fmt.bufPrint(&tbuf, "move {s}", .{p.key}) catch "move",
        .assignee => std.fmt.bufPrint(&tbuf, "assign {s}", .{p.key}) catch "assign",
        .fix_version => std.fmt.bufPrint(&tbuf, "fix version on {s}", .{p.key}) catch "fix version",
        .issue_type => "issue type",
    };
    const r = box(f, a, 64, @intCast(@min(20, vis.len + 6)), title);
    // Row 0 is the filter line, so typing is visibly a filter.
    var buf: [128]u8 = undefined;
    const filter_line = std.fmt.bufPrint(&buf, "/{s}\u{2502}", .{p.filter.text()}) catch "/";
    _ = f.text(r.x, r.y, r.w, filter_line, .{ .fg = pal.muted, .mods = .{ .reverse = true } });

    var y = r.y + 2;
    if (p.err) |e| {
        _ = f.text(r.x, y, r.w, e, .{ .fg = pal.err, .mods = .{ .reverse = true } });
        y += 1;
    }
    if (vis.len == 0) {
        _ = f.text(r.x, y, r.w, "(nothing here — Esc)", .{ .fg = pal.muted, .mods = .{ .reverse = true } });
        return;
    }
    var i: usize = 0;
    // Window the list around the cursor.
    const h = r.y + r.h - y;
    const first = if (p.cursor >= h) p.cursor + 1 - h else 0;
    while (y < r.y + r.h and first + i < vis.len) : ({
        y += 1;
        i += 1;
    }) {
        const at = first + i;
        const item = p.items[vis[at]];
        const on = at == p.cursor;
        var rbuf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&rbuf, "{s} {d}. {s}", .{ if (on) chrome.closed() else " ", at + 1, item.label }) catch item.label;
        const style: Style = if (on)
            .{ .fg = pal.accent, .mods = .{ .bold = true, .reverse = true } }
        else
            .{ .mods = .{ .reverse = true } };
        _ = f.text(r.x, y, r.w, line, style);
    }
}

fn drawComment(f: *Frame, a: *App, c: anytype) void {
    const p = a.palette;
    var tbuf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "comment on {s}", .{c.key}) catch "comment";
    const r = box(f, a, 70, 12, title);
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    defer arena.deinit();
    const body = c.editor.text();
    // The cursor is drawn inline, so a long comment shows where typing
    // will land rather than always appending at the end.
    const with_cursor = std.mem.concat(arena.allocator(), u8, &.{ body[0..c.editor.cursor], "\u{2502}", body[c.editor.cursor..] }) catch body;
    const lines = text.wrap(arena.allocator(), with_cursor, r.w) catch &.{};
    var y = r.y;
    for (lines) |ln| {
        if (y >= r.y + r.h - 1) break;
        _ = f.text(r.x, y, r.w, ln, .{ .mods = .{ .reverse = true } });
        y += 1;
    }
    const foot = if (c.err) |e| e else "ctrl+s send · Enter newline · Esc cancel";
    const style: Style = if (c.err != null)
        .{ .fg = p.err, .mods = .{ .reverse = true } }
    else
        .{ .fg = p.muted, .mods = .{ .reverse = true } };
    _ = f.text(r.x, r.y + r.h - 1, r.w, foot, style);
}

fn drawForm(f: *Frame, a: *App, fm: *const app_mod.Form) void {
    const p = a.palette;
    const r = box(f, a, 70, 14, "new ticket");
    const labels = [_][]const u8{ "project", "type", "summary", "description" };
    var y = r.y;
    for (labels, 0..) |label, i| {
        const focused = @intFromEnum(fm.focus) == i;
        var buf: [16]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{s: >11}  ", .{label}) catch label;
        const x = r.x + f.text(r.x, y, r.w, head, .{ .fg = if (focused) p.accent else p.muted, .mods = .{ .reverse = true } });
        const e = &fm.fields[i];
        if (focused) {
            var used = f.text(x, y, r.w -| (x - r.x), e.text()[0..e.cursor], .{ .mods = .{ .reverse = true } });
            used += f.text(x + used, y, r.w -| (x - r.x), "\u{2502}", .{ .fg = p.accent, .mods = .{ .reverse = true } });
            _ = f.text(x + used, y, r.w -| (x - r.x), e.text()[e.cursor..], .{ .mods = .{ .reverse = true } });
        } else {
            _ = f.text(x, y, r.w -| (x - r.x), e.text(), .{ .mods = .{ .reverse = true, .dim = true } });
        }
        y += if (i == 3) 1 else 2;
    }
    const foot = if (fm.err) |e| e else "Tab next field · ctrl+s create · Esc cancel";
    const style: Style = if (fm.err != null)
        .{ .fg = p.err, .mods = .{ .reverse = true } }
    else
        .{ .fg = p.muted, .mods = .{ .reverse = true } };
    _ = f.text(r.x, r.y + r.h - 1, r.w, foot, style);
}

fn drawConfirm(f: *Frame, a: *App, c: *const app_mod.Confirm) void {
    const p = a.palette;
    const r = box(f, a, 60, 5, "are you sure");
    _ = f.text(r.x, r.y, r.w, c.message, .{ .mods = .{ .bold = true, .reverse = true } });
    _ = f.text(r.x, r.y + 2, r.w, "y / Enter  yes      n / Esc  no", .{ .fg = p.muted, .mods = .{ .reverse = true } });
}

// ── style helpers ───────────────────────────────────────────────────────

/// A row's own colour, unless the row is selected — a reverse-video row
/// keeps the theme's own pair, and a coloured foreground on top of it is
/// unreadable half the time.
fn merge(row: Style, colour: ?sdk.Color, selected: bool) Style {
    if (selected) return row;
    return .{ .fg = colour, .bg = row.bg, .mods = row.mods };
}

fn mergeBold(row: Style, colour: ?sdk.Color, selected: bool) Style {
    var s = merge(row, colour, selected);
    s.mods.bold = true;
    return s;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// The frame as text, one line per row — what a corpus `.test` sees.
pub fn dump(gpa: Allocator, f: *const Frame) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < f.cols) : (x += 1) {
            const s = f.slots[@as(usize, y) * f.cols + x].symbol();
            out.writer.writeAll(if (s.len == 0) "" else s) catch return error.OutOfMemory;
        }
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn testApp(gpa: Allocator) !App {
    var a = App.init(gpa, testing.io);
    a.cfg = .{
        .jira = .{ .url = "https://acme.atlassian.net", .email = "me@acme.com" },
        .tabs = &.{
            .{ .name = "Mine", .kind = .work_assigned },
            .{ .name = "Release", .jql = "project = ENG", .kind = .custom },
        },
    };
    try a.openTabs();
    const t = &a.tabs[0];
    const arena = t.arena.allocator();
    const issues = try arena.alloc(model.Issue, 5);
    issues[0] = .{ .key = "ENG-1", .summary = "Checkout rewrite", .level = .epic, .kind = "Epic", .status = "In Progress", .category = .indeterminate, .assignee = "Ada Lovelace", .reporter = "Sam Beckett", .priority = "High", .updated = "2026-09-14T09:00:00.000+0000", .fix_version = "13.16.0" };
    issues[1] = .{ .key = "ENG-2", .summary = "Card form validates on blur", .level = .story, .kind = "Story", .status = "In Review", .category = .indeterminate, .parent_key = "ENG-1", .assignee = "Ada Lovelace", .updated = "2026-09-15T08:30:00.000+0000" };
    issues[2] = .{ .key = "ENG-3", .summary = "Apple Pay button", .level = .story, .kind = "Story", .status = "To Do", .category = .new, .parent_key = "ENG-1", .updated = "2026-09-12T08:00:00.000+0000" };
    issues[3] = .{ .key = "ENG-4", .summary = "Wire the blur handler", .level = .subtask, .kind = "Sub-task", .status = "Done", .category = .done, .parent_key = "ENG-2", .assignee = "Sam Beckett", .updated = "2026-09-14T16:00:00.000+0000" };
    issues[4] = .{ .key = "ENG-5", .summary = "Basket total wrong with a voucher", .level = .story, .kind = "Bug", .status = "To Do", .category = .new, .assignee = "Ada Lovelace", .updated = "2026-09-15T07:15:00.000+0000" };
    t.issues = issues;
    t.fetched = true;
    a.now_stamp = "2026-09-15T12:00:00.000+0000";
    a.setStatus("Mine · 5 tickets", .{});
    try a.rebuild(t);
    return a;
}

test "the pane paints: the tab strip, the tree, the columns and the status line" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 120, 20);
    defer f.deinit();
    a.cols = 120;
    a.rows = 20;
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);

    // The strip names the app and both tabs, with the loaded one counted.
    try testing.expect(std.mem.indexOf(u8, screen, "JIRA") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "1 Mine 5") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "2 Release") != null);
    // The columns the default set names.
    try testing.expect(std.mem.indexOf(u8, screen, "KEY") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "STATUS") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "ASSIGNEE") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "SUMMARY") != null);
    // The tree, with its chevrons and its indents.
    try testing.expect(std.mem.indexOf(u8, screen, "\u{25bc} ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "ENG-4") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Checkout rewrite") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Ada Lovelace") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "In Review") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "2026-09-15T") == null);
    // An epic has no epic of its own, so the detail says nothing there.
    try testing.expect(std.mem.indexOf(u8, screen, "epic  \u{2014}") == null);
    // The status line.
    try testing.expect(std.mem.indexOf(u8, screen, "Mine \u{b7} 5 tickets") != null);
    // The detail pane, on the right.
    try testing.expect(std.mem.indexOf(u8, screen, "ENG-1  Checkout rewrite") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "reporter  Sam Beckett") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "version  13.16.0") != null);
}

test "the Updated column is an age, not a timestamp, once there is room for it" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 120, 20);
    defer f.deinit();
    a.cols = 120;
    a.rows = 20;
    // With the detail pane open at 120 the list is 71 cells, and
    // `updated` is one of the columns the layout drops to keep a usable
    // summary. Closed, it fits.
    a.detail_open = false;
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "UPDATED") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "3h") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "1d") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "2026-09-15T") == null);
}

test "expand_indicator picks the small pair, and --ascii still wins over it" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 16);
    defer f.deinit();
    a.cols = 100;
    a.rows = 16;
    try draw(&f, &a, .{ .triangle = true });
    var screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{25be} ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{25bc}") == null);
    testing.allocator.free(screen);
    try draw(&f, &a, .{ .triangle = true, .ascii = true });
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "v ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{25be}") == null);
    testing.allocator.free(screen);
}

test "--ascii swaps every glyph for a plain twin, and the layout does not move" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 16);
    defer f.deinit();
    a.cols = 100;
    a.rows = 16;
    try draw(&f, &a, .{ .ascii = true });
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "v ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{25bc}") == null);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{2502}") == null);
    try testing.expect(std.mem.indexOf(u8, screen, "\u{27f3}") == null);
    try testing.expect(std.mem.indexOf(u8, screen, "|") != null);
}

test "the layout gives the flexible column what is left, and drops fixed columns to keep it usable" {
    const cols = config.default_columns;
    const wide = layout(&cols, 120);
    try testing.expectEqual(@as(usize, 6), wide.n);
    try testing.expectEqual(@as(u16, 1), wide.items[0].x);
    try testing.expectEqual(@as(u16, 14), wide.items[0].w); // key
    try testing.expectEqual(@as(u16, 14), wide.items[1].w); // status
    try testing.expect(wide.items[4].w >= 16); // summary
    try testing.expectEqual(config.Column.actions, wide.items[5].col);
    // 59 cells — a pane beside an open sidebar. `key`, `status` and the
    // summary survive; the rest go, because a row without a summary is
    // not worth painting.
    const narrow = layout(&cols, 59);
    var saw_key = false;
    var saw_summary = false;
    for (narrow.slice()) |it| {
        try testing.expect(it.x + it.w <= 59);
        if (it.col == .key) saw_key = true;
        if (it.col == .summary) {
            saw_summary = true;
            try testing.expect(it.w >= 16);
        }
    }
    try testing.expect(saw_key and saw_summary);
    // Narrower still: the key and the summary are the last two standing.
    const tiny = layout(&cols, 34);
    try testing.expectEqual(@as(usize, 2), tiny.n);
    try testing.expectEqual(config.Column.key, tiny.items[0].col);
    try testing.expectEqual(config.Column.summary, tiny.items[1].col);
    // A single flexible column takes the width.
    const one = layout(&.{.summary}, 50);
    try testing.expectEqual(@as(usize, 1), one.n);
    try testing.expectEqual(@as(u16, 49), one.items[0].w);
}

test "a narrow pane paints without panicking at any size down to 8 columns" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var w: u16 = 8;
    while (w <= 40) : (w += 1) {
        var f = try Frame.init(testing.allocator, w, 6);
        defer f.deinit();
        a.cols = w;
        a.rows = 6;
        try draw(&f, &a, .{});
        const screen = try dump(testing.allocator, &f);
        testing.allocator.free(screen);
    }
    // And a pane too small for anything at all.
    var tiny = try Frame.init(testing.allocator, 4, 2);
    defer tiny.deinit();
    a.cols = 4;
    a.rows = 2;
    try draw(&tiny, &a, .{});
}

test "every overlay paints its own chrome over the list" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 24);
    defer f.deinit();
    a.cols = 100;
    a.rows = 24;

    try a.key("?");
    try draw(&f, &a, .{});
    var screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "keys") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "expand / collapse") != null);
    testing.allocator.free(screen);
    try a.key("esc");

    try a.key("/");
    for ("blur") |c| try a.key(&[_]u8{c});
    try draw(&f, &a, .{});
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "filter: blur") != null);
    testing.allocator.free(screen);
    try a.key("esc");

    try a.key("c");
    for ("on it") |c| try a.key(&[_]u8{c});
    try draw(&f, &a, .{});
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "comment on ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "on it") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "ctrl+s send") != null);
    testing.allocator.free(screen);
    try a.key("esc");

    try a.key("n");
    try draw(&f, &a, .{});
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "new ticket") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "project") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "description") != null);
    testing.allocator.free(screen);
    try a.key("esc");

    a.overlay = .{ .confirm = .{
        .message = "Move ENG-1 — Close?",
        .what = .{ .transition = .{ .key = "ENG-1", .id = "41", .to = "Done" } },
    } };
    try draw(&f, &a, .{});
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "are you sure") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Move ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "y / Enter") != null);
    testing.allocator.free(screen);
}

test "a picker paints its filter line, its rows and its refusal" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 24);
    defer f.deinit();
    a.cols = 100;
    a.rows = 24;
    a.overlay = .{ .picker = .{
        .kind = .transition,
        .key = "ENG-1",
        .items = &.{
            .{ .id = "21", .label = "Start work  → In Progress" },
            .{ .id = "41", .label = "Close  → Done" },
        },
        .filter = app_mod.Editor.init(testing.allocator),
    } };
    try draw(&f, &a, .{});
    var screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "move ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "1. Start work") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "2. Close") != null);
    testing.allocator.free(screen);
    // A workflow with nothing to offer says so rather than being blank.
    a.overlay.picker.items = &.{};
    a.overlay.picker.err = "403 — the token is valid but not allowed to do that";
    try draw(&f, &a, .{});
    screen = try dump(testing.allocator, &f);
    try testing.expect(std.mem.indexOf(u8, screen, "not allowed") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "nothing here") != null);
    testing.allocator.free(screen);
}

test "a blocked pane paints why, and no ticket chrome at all" {
    var a = App.init(testing.allocator, testing.io);
    defer a.deinit();
    a.blocked = &.{ "No Jira API token.", "", "Make one at https://id.atlassian.com/…", "Then press r to try again." };
    var f = try Frame.init(testing.allocator, 80, 12);
    defer f.deinit();
    a.cols = 80;
    a.rows = 12;
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "No Jira API token.") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "press r to try again") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "KEY") == null);
}

test "the hidden-rows count is on screen, so H is discoverable" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 16);
    defer f.deinit();
    a.cols = 100;
    a.rows = 16;
    try a.key("x");
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "1 hidden") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "H") != null);
}

test "a PR row paints its state, its repo and its approvals under the ticket" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    const prs = [_]@import("jira.zig").PullRequest{
        .{ .id = "#2023", .title = "Validate on blur", .status = "MERGED", .url = "https://bitbucket.org/acme/checkout/pull-requests/2023", .repo = "checkout", .source_branch = "feat/blur", .dest_branch = "main", .approvals = 2 },
    };
    try t.state.setPrs("ENG-2", &prs);
    try a.rebuild(t);
    var f = try Frame.init(testing.allocator, 120, 16);
    defer f.deinit();
    a.cols = 120;
    a.rows = 16;
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "MERGED") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "checkout #2023") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "feat/blur \u{2192} main") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "(2\u{2713})") != null);
}

test "the filter line and an empty result both say what happened" {
    var a = try testApp(testing.allocator);
    defer a.deinit();
    var f = try Frame.init(testing.allocator, 100, 16);
    defer f.deinit();
    a.cols = 100;
    a.rows = 16;
    try a.key("/");
    for ("zzzz") |c| try a.key(&[_]u8{c});
    try a.key("enter");
    try draw(&f, &a, .{});
    const screen = try dump(testing.allocator, &f);
    defer testing.allocator.free(screen);
    try testing.expect(std.mem.indexOf(u8, screen, "filter: zzzz") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "nothing matches that filter") != null);
}
