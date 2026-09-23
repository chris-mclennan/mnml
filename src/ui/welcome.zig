//! The welcome pane — the editor area when no pane is open. Two forms,
//! chosen by `ui.welcome` (`app/welcome.zig` reads it):
//!
//! **The start surface** (`full`, the default, `drawStart`): a compact
//! word mark, the workspace line, then four lists drawn through
//! `ListPanel` — RECENT WORKSPACES, RECENT FILES, SESSIONS (with its
//! `+ New Claude Code session here` row) and SHORTCUTS — and the
//! version line at the foot. The lists sit in two columns when the
//! pane is wide enough and one when it is not; `layout` decides, and
//! what does not fit is dropped whole in a fixed order (the mark under
//! thirty rows, then SHORTCUTS, then the workspaces, then SESSIONS),
//! never overlapped. A list the room cuts short scrolls in its rect
//! with the panel's own bar. The rows are the app's: the pickers'
//! sources, handed in each frame.
//!
//! **The minimal form** (`minimal`, `draw`) — the shape the pane had
//! before the start surface, and Rust's: the `mnml` logo, the
//! workspace and its branch, the shortcut list and the version line,
//! every row centred on the pane.
//!
//! The minimal rows are a ladder the pane's height climbs. Under six
//! rows nothing is painted but the ground. From six the word `mnml`
//! stands in for the logo, which needs nineteen rows (its five plus the
//! fourteen the rest of the ladder takes). Recent files join when
//! twelve rows remain past the head, up to eight of them, each one
//! a row the pane can spare. The whole stack sits at `(h - rows) / 2`
//! from the top; a stack taller than the pane is clipped at the
//! bottom, never scrolled.
//!
//! Every minimal row is centred on its own painted width, so the
//! shortcut chords do not line up in a column: `  ^P     find file` is
//! one string, centred. A recent row and a shortcut row each register
//! a `.welcome` hit hugging the painted text — the empty gutter either
//! side reads as untargetable, and is.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const hit_mod = @import("hit.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");

const Style = vaxis.Style;

pub const Shortcut = struct {
    /// Already in its display spelling: `^P`, `SPC`, `F1`.
    chord: []const u8,
    label: []const u8,
};

pub const Props = struct {
    /// The workspace directory's name.
    workspace: []const u8,
    /// The checked-out branch; null outside a repository.
    branch: ?[]const u8 = null,
    /// Files changed on the branch — `· 3 changed files` after it.
    changed: u32 = 0,
    /// Workspace-relative, newest first.
    recent: []const []const u8 = &.{},
    shortcuts: []const Shortcut = &.{},
    /// Goes after `mnml ` on the last row.
    version: []const u8,
};

/// figlet "Standard" with full kerning: each letter at its native
/// width, a two-cell gutter between them so m / n / m / l read apart.
/// The `l` is one row taller than m / n — row 0 carries only its top
/// serif; the m / n / m underscores live on row 1.
pub const logo = [_][]const u8{
    "                                 _ ",
    " _ __ ___    _ __    _ __ ___   | |",
    "| '_ ` _ \\  | '_ \\  | '_ ` _ \\  | |",
    "| | | | | | | | | | | | | | | | | |",
    "|_| |_| |_| |_| |_| |_| |_| |_| |_|",
};

pub const underline = "──────────────";
const underline_ascii = "--------------";

/// Rows the ladder takes past the logo: blank, workspace, blank,
/// Shortcuts header, underline, six chords, blank, version — the
/// branch row and the recent block come on top.
const rows_after_logo: u16 = 14;
const min_rows: u16 = 6;
/// A recent block needs its header, underline and blank plus the ten
/// rows of shortcuts below it before the first path fits.
const recent_room: u16 = 12;
const max_recent: u16 = 8;

/// A row of the stack before it is centred.
const Row = struct {
    segs: []const Seg = &.{},
    hit: ?hit_mod.WelcomeRow = null,
    /// A path too wide for the pane ends in an ellipsis; every other
    /// row (the logo) clips at the edge.
    ellipsis: bool = false,
};
const Seg = struct { text: []const u8, style: Style };

pub fn draw(ui: Ui, area: Rect, p: Props) void {
    const t = ui.theme;
    const pal = t.palette;
    ui.fill(area, t.bg);
    if (area.h < min_rows or area.w == 0) return;

    const dim = Style{ .fg = pal.comment, .bg = pal.bg_dark };
    const key = Style{ .fg = pal.yellow, .bg = pal.bg_dark, .bold = true };
    const logo_style = Style{ .fg = pal.blue, .bg = pal.bg_dark, .bold = true };
    const header = Style{ .fg = pal.purple, .bg = pal.bg_dark, .bold = true };
    const path = Style{ .fg = pal.fg, .bg = pal.bg_dark };
    const branch_style = Style{ .fg = pal.green, .bg = pal.bg_dark, .bold = true };
    const rule: []const u8 = if (ui.ascii) underline_ascii else underline;

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    const a = ui.arena;
    const show_logo = area.h >= logo.len + rows_after_logo;
    if (show_logo) {
        for (logo) |line| push(&rows, a, .{ .segs = seg1(a, line, logo_style) });
        push(&rows, a, .{});
    } else {
        push(&rows, a, .{ .segs = seg1(a, "mnml", logo_style) });
    }
    push(&rows, a, .{ .segs = seg1(a, ui.fmt("workspace · {s}", .{p.workspace}), path) });
    if (p.branch) |b| {
        const segs: []Seg = a.alloc(Seg, if (p.changed > 0) 3 else 2) catch &.{};
        if (segs.len > 0) {
            segs[0] = .{ .text = "on ", .style = dim };
            segs[1] = .{ .text = b, .style = branch_style };
            if (segs.len == 3) segs[2] = .{ .text = ui.fmt(" · {d} changed file{s}", .{ p.changed, if (p.changed == 1) "" else "s" }), .style = dim };
        }
        push(&rows, a, .{ .segs = segs });
    }
    push(&rows, a, .{});

    if (p.recent.len > 0 and area.h >= rows.items.len + recent_room) {
        push(&rows, a, .{ .segs = seg1(a, "Recent Files", header) });
        push(&rows, a, .{ .segs = seg1(a, rule, dim) });
        const room: usize = area.h - rows.items.len - 10;
        const n = @min(p.recent.len, @min(room, max_recent));
        for (p.recent[0..n], 0..) |rel, i| {
            push(&rows, a, .{ .segs = seg1(a, ui.fmt("  {s}", .{rel}), path), .hit = .{ .kind = .recent, .idx = @intCast(i) }, .ellipsis = true });
        }
        push(&rows, a, .{});
    }

    push(&rows, a, .{ .segs = seg1(a, "Shortcuts", header) });
    push(&rows, a, .{ .segs = seg1(a, rule, dim) });
    for (p.shortcuts, 0..) |s, i| {
        const segs: []Seg = a.alloc(Seg, 2) catch &.{};
        if (segs.len == 2) {
            segs[0] = .{ .text = ui.fmt("  {s}     ", .{s.chord}), .style = key };
            segs[1] = .{ .text = s.label, .style = dim };
        }
        push(&rows, a, .{ .segs = segs, .hit = .{ .kind = .shortcut, .idx = @intCast(i) } });
    }
    push(&rows, a, .{});
    push(&rows, a, .{ .segs = seg1(a, ui.fmt("mnml {s}", .{p.version}), dim) });

    const n: u16 = @intCast(@min(rows.items.len, std.math.maxInt(u16)));
    const top = area.y + (area.h -| n) / 2;
    for (rows.items, 0..) |row, i| {
        const y = top + @as(u16, @intCast(i));
        if (y >= area.bottom()) break;
        var line_w: u16 = 0;
        for (row.segs) |s| line_w +|= ui.width(s.text);
        // A row wider than the pane starts at its left edge and clips.
        const inset = (area.w -| line_w) / 2;
        var x = area.x + inset;
        const right = area.right();
        for (row.segs) |s| {
            if (x >= right) break;
            const room = right - x;
            const text = if (!row.ellipsis or ui.fitsIn(s.text, room)) s.text else ui.clipStr(s.text, room);
            x += ui.putStr(x, y, room, text, s.style);
        }
        if (row.hit) |h| ui.hit(Rect.init(area.x + inset, y, @min(line_w, area.w), 1), .{ .welcome = h });
    }
}

fn push(rows: *std.ArrayListUnmanaged(Row), a: std.mem.Allocator, row: Row) void {
    // OOM drops the row: the frame is painted from whatever fit.
    rows.append(a, row) catch {};
}

fn seg1(a: std.mem.Allocator, text: []const u8, style: Style) []const Seg {
    const s = a.alloc(Seg, 1) catch return &.{};
    s[0] = .{ .text = text, .style = style };
    return s;
}

// ── the start surface ──

pub const List = hit_mod.WelcomeList;
pub const lists = std.enums.values(List);

/// One row of a start-surface list.
pub const Entry = struct {
    /// A shortcut's chord, painted first in the chord colour and padded
    /// to `lead_w` cells so the labels after it line up.
    lead: []const u8 = "",
    lead_w: u16 = 0,
    text: []const u8,
    /// Dim, on the row's right; dropped when it does not fit beside a
    /// readable piece of `text`.
    detail: []const u8 = "",
};

pub const Panel = list_panel.ListPanel(Entry);

/// The start surface's transient state, owned by the app (`app.welcome`):
/// which list the keys walk and each list's cursor and scroll.
pub const State = struct {
    active: List = .recent,
    panels: [lists.len]Panel.State = @splat(.{}),
    /// Set by `drawStart`: the lists this frame painted — the ones Tab
    /// steps through.
    shown: [lists.len]bool = @splat(false),

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        for (&s.panels) |*p| p.deinit(gpa);
        s.* = .{};
    }

    pub fn panel(s: *State, l: List) *Panel.State {
        return &s.panels[@intFromEnum(l)];
    }

    pub fn isShown(s: *const State, l: List) bool {
        return s.shown[@intFromEnum(l)];
    }
};

pub const StartProps = struct {
    workspace: []const u8,
    branch: ?[]const u8 = null,
    changed: u32 = 0,
    workspaces: []const Entry = &.{},
    recent: []const Entry = &.{},
    sessions: []const Entry = &.{},
    shortcuts: []const Entry = &.{},
    version: []const u8,
    /// The start surface has the keys: the active list shows its cursor.
    focused: bool = false,
};

/// The compact word mark — the minimal form's logo in figlet "small",
/// three rows where that one takes five.
pub const mark = [_][]const u8{
    " _ __    _ _    _ __    _ ",
    "| '  \\  | ' \\  | '  \\  | |",
    "|_|_|_| |_||_| |_|_|_| |_|",
};
/// Under this many rows the mark is dropped.
pub const mark_min_rows: u16 = 30;
/// The widest a column grows, and the narrowest two can be before the
/// lists fall back to one column.
pub const col_max: u16 = 48;
pub const col_min: u16 = 32;
pub const gutter: u16 = 4;

pub const new_session_label = "+ New Claude Code session here";

/// The rows each list asks for past its header — capped, so a long
/// history does not push the rest off the pane — and the fewest it
/// can live with before it is dropped.
fn wantRows(l: List, n: usize) u16 {
    const cap: usize = switch (l) {
        .workspaces => 4,
        .recent => 8,
        .sessions => 5,
        .shortcuts => 12,
    };
    return @intCast(@max(1, @min(n, cap)));
}

/// The fewest rows a list lives with before it is dropped: one (a row
/// or its empty state) — but SHORTCUTS is a reference, and a reference
/// that scrolls four rows at a time is not one, so it wants four.
fn minRows(l: List, n: usize) u16 {
    return if (l == .shortcuts) @intCast(@max(1, @min(n, 4))) else 1;
}

/// The rows a list takes beyond its rows: the header, and for SESSIONS
/// the New row with its air above and below.
fn chromeRows(l: List) u16 {
    return if (l == .sessions) 4 else 1;
}

pub const Counts = [lists.len]usize;

pub const Layout = struct {
    mark: ?Rect = null,
    title: ?Rect = null,
    lists: [lists.len]?Rect = @splat(null),
    version: ?Rect = null,
    columns: u16 = 0,
};

/// Where everything goes in `area` for lists of `n` rows. Pure: the
/// same inputs give the same rects, and no two rects overlap.
pub fn layout(area: Rect, n: Counts) Layout {
    var out: Layout = .{};
    if (area.w < 20 or area.h < 6) return out;
    const two = area.w >= 2 * col_min + gutter + 4;
    const col_w: u16 = if (two) @min((area.w - 4 - gutter) / 2, col_max) else @min(area.w -| 4, col_max + 8);
    out.columns = if (two) 2 else 1;
    const with_mark = area.h >= mark_min_rows;
    const top_h: u16 = (if (with_mark) @as(u16, mark.len) + 1 else 0) + 2;
    const bottom_h: u16 = 2;
    const room: u16 = area.h -| (top_h + bottom_h);

    const Col = struct { items: [lists.len]List = undefined, len: usize = 0 };
    var cols: [2]Col = .{ .{}, .{} };
    if (two) {
        cols[0].items[0] = .workspaces;
        cols[0].items[1] = .recent;
        cols[0].len = 2;
        cols[1].items[0] = .sessions;
        cols[1].items[1] = .shortcuts;
        cols[1].len = 2;
    } else {
        for (lists, 0..) |l, i| cols[0].items[i] = l;
        cols[0].len = lists.len;
    }
    var dropped: [lists.len]bool = @splat(false);
    const drop_order = [_]List{ .shortcuts, .workspaces, .sessions, .recent };
    var heights: [lists.len]u16 = @splat(0);
    var col_h: [2]u16 = .{ 0, 0 };
    var d: usize = 0;
    while (true) {
        // The fewest rows each column needs with what is still in.
        var fits = true;
        for (cols[0..out.columns], 0..) |c, ci| {
            var need: u16 = 0;
            var k: u16 = 0;
            for (c.items[0..c.len]) |l| {
                if (dropped[@intFromEnum(l)]) continue;
                need += chromeRows(l) + minRows(l, n[@intFromEnum(l)]) + (if (k > 0) @as(u16, 1) else 0);
                k += 1;
            }
            col_h[ci] = need;
            if (need > room) fits = false;
        }
        if (fits or d == drop_order.len) break;
        dropped[@intFromEnum(drop_order[d])] = true;
        d += 1;
    }
    // Grow each list towards what it asks for, in column order.
    for (cols[0..out.columns], 0..) |c, ci| {
        var spare: u16 = room -| col_h[ci];
        for (c.items[0..c.len]) |l| {
            const i = @intFromEnum(l);
            if (dropped[i]) continue;
            const want = wantRows(l, n[i]);
            const least = minRows(l, n[i]);
            const extra = @min(want -| least, spare);
            spare -= extra;
            heights[i] = chromeRows(l) + least + extra;
            col_h[ci] += extra;
        }
    }
    var body_h: u16 = 0;
    for (col_h[0..out.columns]) |h| body_h = @max(body_h, h);
    const total_h = @min(area.h, top_h + body_h + bottom_h);
    var y = area.y + (area.h - total_h) / 2;
    const block_w: u16 = if (two) 2 * col_w + gutter else col_w;
    const x0 = area.x + (area.w -| block_w) / 2;
    if (with_mark) {
        const mw: u16 = @intCast(mark[0].len);
        out.mark = Rect.init(area.x + (area.w -| mw) / 2, y, @min(mw, area.w), @intCast(mark.len));
        y += @as(u16, mark.len) + 1;
    }
    out.title = Rect.init(x0, y, block_w, 1);
    y += 2;
    for (cols[0..out.columns], 0..) |c, ci| {
        var cy = y;
        const cx = x0 + @as(u16, @intCast(ci)) * (col_w + gutter);
        for (c.items[0..c.len]) |l| {
            const i = @intFromEnum(l);
            if (dropped[i] or heights[i] == 0) continue;
            if (cy + heights[i] > area.bottom()) break;
            out.lists[i] = Rect.init(cx, cy, col_w, heights[i]);
            cy += heights[i] + 1;
        }
    }
    const vy = y + body_h + 1;
    if (vy < area.bottom()) out.version = Rect.init(x0, vy, block_w, 1);
    return out;
}

fn listLabel(l: List) []const u8 {
    return switch (l) {
        .workspaces => "RECENT WORKSPACES",
        .recent => "RECENT FILES",
        .sessions => "SESSIONS",
        .shortcuts => "SHORTCUTS",
    };
}

fn listEmpty(l: List) list_panel.EmptyState {
    return switch (l) {
        .workspaces => .{ .message = "No workspace open" },
        .recent => .{ .message = "No recent files yet" },
        .sessions => .{ .message = "No session to resume" },
        .shortcuts => .{ .message = "No shortcuts bound" },
    };
}

fn idx16(i: u32) u16 {
    return @intCast(@min(i, std.math.maxInt(u16)));
}
fn workspaceHit(i: u32) hit_mod.HitTarget {
    return .{ .welcome = .{ .kind = .workspace, .idx = idx16(i) } };
}
fn recentHit(i: u32) hit_mod.HitTarget {
    return .{ .welcome = .{ .kind = .recent, .idx = idx16(i) } };
}
fn sessionHit(i: u32) hit_mod.HitTarget {
    return .{ .welcome = .{ .kind = .session, .idx = idx16(i) } };
}
fn shortcutHit(i: u32) hit_mod.HitTarget {
    return .{ .welcome = .{ .kind = .shortcut, .idx = idx16(i) } };
}

fn targetsOf(l: List) list_panel.Targets {
    return .{
        .row = switch (l) {
            .workspaces => &workspaceHit,
            .recent => &recentHit,
            .sessions => &sessionHit,
            .shortcuts => &shortcutHit,
        },
        .new = if (l == .sessions) .{ .welcome = .{ .kind = .new_session, .idx = 0 } } else null,
        .bar = .{ .welcome = l },
    };
}

/// A list row: the chord (a shortcut's), the text, the dim detail on
/// the right when there is room for it and a readable piece of text.
fn paintEntry(ui: Ui, r: Rect, row: Entry, selected: bool) void {
    const t = ui.theme;
    const ground = list_panel.rowStyleOn(t, t.bg, selected);
    if (r.w <= 1) return;
    var x = r.x + 1;
    const right = r.right();
    if (row.lead.len > 0) {
        var key = Theme.withFg(ground, t.palette.yellow);
        key.bold = true;
        _ = ui.putStr(x, r.y, right -| x, ui.clipStr(row.lead, right -| x), key);
        x = @min(right, x + @max(row.lead_w, ui.width(row.lead)) + 2);
    }
    var text_end = right;
    const dw = ui.width(row.detail);
    // The detail keeps its place while the whole text fits beside it,
    // or twenty cells of it do; else the text has the row.
    const avail = right -| x;
    if (dw > 0 and avail > dw + 2 and (ui.width(row.text) + dw + 2 <= avail or avail - dw - 2 >= 20)) text_end = right - dw - 2;
    const text_room = text_end -| x;
    const used = ui.putStr(x, r.y, text_room, ui.clipStr(row.text, text_room), Theme.withFg(ground, t.palette.fg));
    if (text_end < right and used > 0) {
        var dim = Theme.withFg(ground, t.muted.fg);
        dim.dim = true;
        _ = ui.putStr(right - dw, r.y, dw, row.detail, dim);
    }
}

/// Paints the start surface into `area` and records which lists showed.
pub fn drawStart(st: *State, ui: Ui, area: Rect, p: StartProps) void {
    const t = ui.theme;
    const pal = t.palette;
    ui.fill(area, t.bg);
    st.shown = @splat(false);
    const rows_of = [_][]const Entry{ p.workspaces, p.recent, p.sessions, p.shortcuts };
    var counts: Counts = undefined;
    for (rows_of, 0..) |r, i| counts[i] = r.len;
    const lay = layout(area, counts);

    const dim = Style{ .fg = pal.comment, .bg = pal.bg_dark };
    if (lay.mark) |m| {
        const logo_style = Style{ .fg = pal.blue, .bg = pal.bg_dark, .bold = true };
        for (mark, 0..) |line, i| _ = ui.putStr(m.x, m.y + @as(u16, @intCast(i)), m.w, line, logo_style);
    }
    if (lay.title) |r| {
        const path = Style{ .fg = pal.fg, .bg = pal.bg_dark };
        const branch_style = Style{ .fg = pal.green, .bg = pal.bg_dark, .bold = true };
        const head = ui.fmt("workspace · {s}", .{p.workspace});
        const on = if (p.branch != null) "  on " else "";
        const b = p.branch orelse "";
        const tail = if (p.branch != null and p.changed > 0) ui.fmt(" · {d} changed file{s}", .{ p.changed, if (p.changed == 1) "" else "s" }) else "";
        const w = ui.width(head) + ui.width(on) + ui.width(b) + ui.width(tail);
        var x = r.x + (r.w -| w) / 2;
        const right = r.right();
        x += ui.putStr(x, r.y, right -| x, ui.clipStr(head, right -| x), path);
        x += ui.putStr(x, r.y, right -| x, on, dim);
        x += ui.putStr(x, r.y, right -| x, b, branch_style);
        _ = ui.putStr(x, r.y, right -| x, tail, dim);
    }
    for (lists) |l| {
        const i = @intFromEnum(l);
        const r = lay.lists[i] orelse continue;
        st.shown[i] = true;
        // Rows under the chord column line up on the widest chord.
        const rows = rows_of[i];
        _ = Panel.draw(st.panel(l), ui, r, .{
            // Unused: every target is `targets`' and the header has no chips.
            .panel = .sessions,
            .label = listLabel(l),
            .rows = rows,
            .paintRow = &paintEntry,
            .empty = listEmpty(l),
            .show_filter = false,
            .show_refresh = false,
            .new_label = if (l == .sessions) new_session_label else null,
            .ground = t.bg,
            .show_cursor = p.focused and st.active == l,
            .focused = p.focused,
            .targets = targetsOf(l),
        });
    }
    // The keys walk a list that is on screen.
    if (!st.isShown(st.active)) {
        for (lists) |l| if (st.isShown(l)) {
            st.active = l;
            break;
        };
    }
    if (lay.version) |r| {
        const text = ui.fmt("mnml {s}", .{p.version});
        const w = ui.width(text);
        _ = ui.putStr(r.x + (r.w -| w) / 2, r.y, r.w, ui.clipStr(text, r.w), dim);
    }
}

/// The widest chord in `rows` — what `Entry.lead_w` pads to.
pub fn leadWidth(ui: Ui, rows: []const Entry) u16 {
    var w: u16 = 0;
    for (rows) |r| w = @max(w, ui.width(r.lead));
    return w;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const standard = [_]Shortcut{
    .{ .chord = "^P", .label = "find file" },
    .{ .chord = "^R", .label = "recent files" },
    .{ .chord = "^K", .label = "which-key menu" },
    .{ .chord = "^N", .label = "new file" },
    .{ .chord = "^B", .label = "toggle tree" },
    .{ .chord = "^Q", .label = "quit" },
};

/// Rows 2–37 of `docs/ui-spec/rust-120x40.txt` from column 31: the
/// Rust editor's welcome pane on the `ws` fixture at 120×40, with
/// its version row rewritten to the form this build paints.
const spec_89x36 = [_][]const u8{
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "                                                            _",
    "                            _ __ ___    _ __    _ __ ___   | |",
    "                           | '_ ` _ \\  | '_ \\  | '_ ` _ \\  | |",
    "                           | | | | | | | | | | | | | | | | | |",
    "                           |_| |_| |_| |_| |_| |_| |_| |_| |_|",
    "",
    "                                     workspace · ws",
    "                                         on main",
    "",
    "                                        Shortcuts",
    "                                     ──────────────",
    "                                     ^P     find file",
    "                                    ^R     recent files",
    "                                   ^K     which-key menu",
    "                                      ^N     new file",
    "                                    ^B     toggle tree",
    "                                        ^Q     quit",
    "",
    "                                 mnml 0.2.21 · 9d5049b52",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
};

test "welcome: 89×36: the pane matches the Rust dump row for row" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .shortcuts = &standard, .version = "0.2.21 · 9d5049b52" });
    try f.expectRows(&spec_89x36);
    // The logo is the accent blue in bold, the headers purple, the branch
    // green, the chords yellow, the version row muted.
    const pal = f.theme.palette;
    try testing.expect(f.fgEql(60, 8, .{ .fg = pal.blue }) and f.style(60, 8).bold);
    try testing.expect(f.fgEql(40, 17, .{ .fg = pal.purple }));
    try testing.expect(f.fgEql(44, 15, .{ .fg = pal.green }) and f.fgEql(41, 15, .{ .fg = pal.comment }));
    try testing.expect(f.fgEql(37, 19, .{ .fg = pal.yellow }) and f.fgEql(44, 19, .{ .fg = pal.comment }));
    try testing.expect(f.fgEql(33, 26, .{ .fg = pal.comment }));
    try testing.expect(f.bgEql(0, 0, .{ .bg = pal.bg_dark }) and f.bgEql(88, 35, .{ .bg = pal.bg_dark }));
    // Each shortcut row's hit hugs its painted text.
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 0 }, f.hits.at(37, 19).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 5 }, f.hits.at(40, 24).?.welcome);
    // The hit takes in the two-cell lead, as the painted text does.
    try testing.expect(f.hits.at(34, 19) == null);
    try testing.expect(f.hits.at(10, 24) == null);
}

test "welcome: outside a repo the branch row is gone and the stack re-centres" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    // 18 rows on 36: top is 9.
    try expectCentred(&f, 9, logo[0]);
    try expectCentred(&f, 15, "workspace · ws");
    try f.expectRow(16, "");
    try expectCentred(&f, 17, "Shortcuts");
    try expectCentred(&f, 26, "mnml 0.3.0");
    try f.expectRow(27, "");
}

test "welcome: the ladder: twelve rows keep the word, eight rows clip the tail, five rows paint nothing" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .shortcuts = &standard, .version = "0.3.0" });
    // 13 rows of stack on 12: top is 0, the version row falls off.
    try expectCentred(&f, 0, "mnml");
    try expectCentred(&f, 1, "workspace · ws");
    try expectCentred(&f, 2, "on main");
    try f.expectRow(3, "");
    try expectCentred(&f, 4, "Shortcuts");
    try expectCentred(&f, 5, underline);
    try expectCentred(&f, 6, "  ^P     find file");
    try expectCentred(&f, 7, "  ^R     recent files");
    try expectCentred(&f, 8, "  ^K     which-key menu");
    try expectCentred(&f, 9, "  ^N     new file");
    try expectCentred(&f, 10, "  ^B     toggle tree");
    try expectCentred(&f, 11, "  ^Q     quit");
    try f.expectLacks("mnml 0.3.0");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 5 }, f.hits.at(26, 11).?.welcome);

    var g = try Fixture.init(60, 8);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    try expectCentred(&g, 0, "mnml");
    try expectCentred(&g, 1, "workspace · ws");
    try g.expectRow(2, "");
    try expectCentred(&g, 3, "Shortcuts");
    try expectCentred(&g, 4, underline);
    try expectCentred(&g, 5, "  ^P     find file");
    try expectCentred(&g, 6, "  ^R     recent files");
    try expectCentred(&g, 7, "  ^K     which-key menu");
    try g.expectLacks("new file");

    var h = try Fixture.init(60, 5);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    try h.expectRows(&.{ "", "", "", "", "" });
    try testing.expect(h.bgEql(0, 0, .{ .bg = h.theme.palette.bg_dark }));
}

test "welcome: the chord column is whatever the profile says: vim's leader rows" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const vim = [_]Shortcut{
        .{ .chord = "^P", .label = "find file" },
        .{ .chord = "SPC", .label = "which-key menu" },
        .{ .chord = "^N", .label = "toggle tree" },
        .{ .chord = "^Q", .label = "quit" },
    };
    draw(f.ui(), f.full(), .{ .workspace = "ws", .shortcuts = &vim, .version = "0.3.0" });
    // 10 rows on 12: top is 1.
    try expectCentred(&f, 4, underline);
    try expectCentred(&f, 5, "  ^P     find file");
    try expectCentred(&f, 6, "  SPC     which-key menu");
    try expectCentred(&f, 7, "  ^N     toggle tree");
    try expectCentred(&f, 8, "  ^Q     quit");
    try expectCentred(&f, 10, "mnml 0.3.0");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 2 }, f.hits.at(24, 7).?.welcome);
}

test "welcome: recent files sit between the branch and the shortcuts, each row a hit, capped by the room" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    const recent = [_][]const u8{ "src/main.rs", "README.md", "package.json" };
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    // 19 + 3 + 3 = 25 rows: top is 5.
    try expectCentred(&f, 5, logo[0]);
    try expectCentred(&f, 12, "on main");
    try f.expectRow(13, "");
    try expectCentred(&f, 14, "Recent Files");
    try expectCentred(&f, 15, underline);
    try expectCentred(&f, 16, "  src/main.rs");
    try expectCentred(&f, 17, "  README.md");
    try expectCentred(&f, 18, "  package.json");
    try f.expectRow(19, "");
    try expectCentred(&f, 20, "Shortcuts");
    try expectCentred(&f, 29, "mnml 0.3.0");
    // "  src/main.rs" is 13 wide: inset 38, the hit spans 38..50.
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(38, 16).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(50, 16).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 2 }, f.hits.at(44, 18).?.welcome);
    try testing.expect(f.hits.at(37, 16) == null);
    try testing.expect(f.hits.at(51, 16) == null);
    try testing.expect(f.hits.at(44, 15) == null);

    // Twelve recent files on 36 rows: 36 - 12 head rows - 10 below = 8, the cap.
    var many: [12][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = if (i % 2 == 0) "a.txt" else "b.txt";
    var g = try Fixture.init(89, 36);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .workspace = "ws", .branch = "main", .recent = &many, .shortcuts = &standard, .version = "0.3.0" });
    // 19 + 3 + 8 = 30 rows: top is 3.
    try expectCentred(&g, 3, logo[0]);
    try expectCentred(&g, 12, "Recent Files");
    try expectCentred(&g, 14, "  a.txt");
    try expectCentred(&g, 21, "  b.txt");
    try g.expectRow(22, "");
    try expectCentred(&g, 23, "Shortcuts");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 7 }, g.hits.at(42, 21).?.welcome);
    try testing.expect(g.hits.at(42, 22) == null);
    // Below 21 rows (nine of head plus twelve) there is no recent block;
    // at 22 the first path fits (22 - 11 - 10 = 1).
    var h = try Fixture.init(89, 20);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    try h.expectLacks("Recent Files");
    try h.expectContains("Shortcuts");
    var k = try Fixture.init(89, 22);
    defer k.deinit();
    draw(k.ui(), k.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    try k.expectContains("Recent Files");
    try k.expectContains("  src/main.rs");
    try k.expectLacks("README.md");
}

test "welcome: a narrow pane: a wide path ends in an ellipsis and stays one hit, the logo clips bare" {
    var f = try Fixture.init(30, 36);
    defer f.deinit();
    const recent = [_][]const u8{"a/very/long/path/that/does/not/fit/in/thirty/cells.zig"};
    draw(f.ui(), f.full(), .{ .workspace = "ws", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    var buf: [256]u8 = undefined;
    // 22 rows on 36: top is 7; the path row is the tenth.
    const r = f.row(17, &buf);
    try testing.expect(std.mem.startsWith(u8, r, "  a/very/long/path"));
    try testing.expect(std.mem.endsWith(u8, r, "…"));
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(0, 17).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(29, 17).?.welcome);
    try f.expectRow(11, "|_| |_| |_| |_| |_| |_| |_| |_");
}

/// `text` centred on the fixture's width the way the pane centres a
/// row: `(w - width) / 2` cells of inset.
fn expectCentred(f: *Fixture, y: u16, text: []const u8) !void {
    var buf: [512]u8 = undefined;
    const tw: usize = std.unicode.utf8CountCodepoints(text) catch text.len;
    const inset = (@as(usize, f.screen.width) - tw) / 2;
    @memset(buf[0..inset], ' ');
    @memcpy(buf[inset .. inset + text.len], text);
    // The row reader trims the trailing blank (the logo's top row has one).
    try f.expectRow(y, std.mem.trimEnd(u8, buf[0 .. inset + text.len], " "));
}

// ── tests: the start surface ──

/// The editor area each gate size leaves the welcome pane with the tree
/// up at its shipped width: the columns right of the 31-cell sidebar,
/// the rows under the menu bar and the tab strip and above the
/// statusline and the `:` line.
const gate_areas = [_]Rect{
    Rect.init(31, 2, 49, 20), // 80x24
    Rect.init(31, 2, 89, 36), // 120x40
    Rect.init(31, 2, 169, 56), // 200x60
};

fn expectInside(outer: Rect, r: Rect) !void {
    if (r.x < outer.x or r.y < outer.y or r.right() > outer.right() or r.bottom() > outer.bottom()) {
        std.debug.print("{any} outside {any}\n", .{ r, outer });
        return error.TestUnexpectedResult;
    }
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
}

/// Every rect of `lay` inside `area`, no two overlapping.
fn expectSound(area: Rect, lay: Layout) !void {
    var rects: [lists.len + 3]Rect = undefined;
    var n: usize = 0;
    for ([_]?Rect{ lay.mark, lay.title, lay.version }) |r| if (r) |x| {
        rects[n] = x;
        n += 1;
    };
    for (lay.lists) |r| if (r) |x| {
        rects[n] = x;
        n += 1;
    };
    for (rects[0..n], 0..) |a, i| {
        try expectInside(area, a);
        for (rects[i + 1 .. n]) |b| if (overlaps(a, b)) {
            std.debug.print("{any} overlaps {any}\n", .{ a, b });
            return error.TestUnexpectedResult;
        };
    }
}

const typical: Counts = .{ 1, 2, 1, 9 };

test "start layout: 80x24 drops the mark and SHORTCUTS, one column, nothing overlaps" {
    const area = gate_areas[0];
    const lay = layout(area, typical);
    try expectSound(area, lay);
    try testing.expect(lay.mark == null);
    try testing.expectEqual(@as(u16, 1), lay.columns);
    try testing.expect(lay.lists[@intFromEnum(List.shortcuts)] == null);
    try testing.expect(lay.lists[@intFromEnum(List.workspaces)] != null);
    try testing.expect(lay.lists[@intFromEnum(List.recent)] != null);
    try testing.expect(lay.lists[@intFromEnum(List.sessions)] != null);
    try testing.expect(lay.title != null and lay.version != null);
    // The lists stack in Tab order, a blank row between them.
    const ws = lay.lists[@intFromEnum(List.workspaces)].?;
    const rc = lay.lists[@intFromEnum(List.recent)].?;
    try testing.expectEqual(ws.bottom() + 1, rc.y);
}

test "start layout: 120x40 keeps the mark and every list in two columns" {
    const area = gate_areas[1];
    const lay = layout(area, typical);
    try expectSound(area, lay);
    try testing.expect(lay.mark != null);
    try testing.expectEqual(@as(u16, 2), lay.columns);
    for (lay.lists) |r| try testing.expect(r != null);
    const ws = lay.lists[@intFromEnum(List.workspaces)].?;
    const ss = lay.lists[@intFromEnum(List.sessions)].?;
    const sc = lay.lists[@intFromEnum(List.shortcuts)].?;
    // Workspaces and files on the left, sessions and shortcuts on the right.
    try testing.expectEqual(ws.y, ss.y);
    try testing.expect(ss.x >= ws.right() + gutter);
    try testing.expectEqual(ss.x, sc.x);
    // SHORTCUTS gets every row it asked for: its header and nine.
    try testing.expectEqual(@as(u16, 10), sc.h);
}

test "start layout: 200x60 caps the columns and centres the block" {
    const area = gate_areas[2];
    const lay = layout(area, typical);
    try expectSound(area, lay);
    try testing.expect(lay.mark != null);
    const ws = lay.lists[@intFromEnum(List.workspaces)].?;
    const ss = lay.lists[@intFromEnum(List.sessions)].?;
    try testing.expectEqual(col_max, ws.w);
    const block = ss.right() - ws.x;
    try testing.expectEqual(area.x + (area.w - block) / 2, ws.x);
}

test "start layout: long lists grow to their caps and no further; every height from 6 to 60 stays sound" {
    const many: Counts = .{ 30, 30, 30, 30 };
    const lay = layout(gate_areas[2], many);
    try expectSound(gate_areas[2], lay);
    try testing.expectEqual(@as(u16, 1 + 4), lay.lists[@intFromEnum(List.workspaces)].?.h);
    try testing.expectEqual(@as(u16, 1 + 8), lay.lists[@intFromEnum(List.recent)].?.h);
    try testing.expectEqual(@as(u16, 4 + 5), lay.lists[@intFromEnum(List.sessions)].?.h);
    var h: u16 = 6;
    while (h <= 60) : (h += 1) {
        var w: u16 = 20;
        while (w <= 200) : (w += 9) {
            const area = Rect.init(3, 1, w, h);
            try expectSound(area, layout(area, many));
            try expectSound(area, layout(area, .{ 0, 0, 0, 0 }));
        }
    }
    // Under 20 x 6 nothing but the ground.
    const none = layout(Rect.init(0, 0, 19, 40), typical);
    try testing.expect(none.title == null and none.version == null);
}

const sample_rows = struct {
    const workspaces = [_]Entry{.{ .text = "ws", .detail = "open" }};
    const recent = [_]Entry{ .{ .text = "src/main.zig" }, .{ .text = "README.md" } };
    const sessions = [_]Entry{.{ .text = "fix the tests", .detail = "claude · 2d" }};
    const shortcuts = [_]Entry{
        .{ .lead = "Ctrl+P", .lead_w = 12, .text = "find a file" },
        .{ .lead = "Ctrl+R", .lead_w = 12, .text = "recent files" },
        .{ .lead = "Ctrl+Shift+P", .lead_w = 12, .text = "command palette" },
        .{ .lead = "Ctrl+Q", .lead_w = 12, .text = "quit" },
    };
};

fn drawSample(f: *Fixture, st: *State, focused: bool) void {
    drawStart(st, f.ui(), f.full(), .{
        .workspace = "ws",
        .branch = "main",
        .workspaces = &sample_rows.workspaces,
        .recent = &sample_rows.recent,
        .sessions = &sample_rows.sessions,
        .shortcuts = &sample_rows.shortcuts,
        .version = "0.3.0",
        .focused = focused,
    });
}

test "start surface: 89x36 paints the mark, the four lists and the version; every row is a hit inside its list" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    var st: State = .{};
    defer st.deinit(testing.allocator);
    drawSample(&f, &st, false);
    try f.expectContains(mark[1]);
    try f.expectContains("workspace · ws  on main");
    try f.expectContains("RECENT WORKSPACES");
    try f.expectContains("RECENT FILES");
    try f.expectContains("SESSIONS");
    try f.expectContains("SHORTCUTS");
    try f.expectContains(new_session_label);
    try f.expectContains("src/main.zig");
    try f.expectContains("Ctrl+Shift+P  command palette");
    try f.expectContains("Ctrl+P        find a file");
    try f.expectContains("mnml 0.3.0");
    for (lists) |l| try testing.expect(st.isShown(l));
    // The hit rect gate: every welcome hit sits inside the pane, and no
    // two of them share a cell.
    const lay = layout(f.full(), .{ 1, 2, 1, 4 });
    var n: [5]usize = @splat(0);
    for (f.hits.items.items, 0..) |e, i| {
        try expectInside(f.full(), e.rect);
        if (e.target != .welcome) continue;
        const r = e.target.welcome;
        n[@intFromEnum(r.kind)] += 1;
        try expectInside(lay.lists[@intFromEnum(r.list())].?, e.rect);
        for (f.hits.items.items[i + 1 ..]) |o| if (o.target == .welcome) try testing.expect(!overlaps(e.rect, o.rect));
    }
    try testing.expectEqual([5]usize{ 1, 2, 1, 1, 4 }, n);
    // Not focused: no row wears the cursor.
    var buf: [256]u8 = undefined;
    var y: u16 = 0;
    while (y < 36) : (y += 1) try testing.expect(std.mem.indexOf(u8, f.row(y, &buf), list_panel.marker_glyph) == null);
}

test "start surface: focused, the active list's row wears the marker and the others none" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    var st: State = .{ .active = .recent };
    defer st.deinit(testing.allocator);
    st.panel(.recent).cursor = 1;
    drawSample(&f, &st, true);
    var hits: usize = 0;
    var buf: [256]u8 = undefined;
    var y: u16 = 0;
    while (y < 36) : (y += 1) {
        const r = f.row(y, &buf);
        if (std.mem.indexOf(u8, r, list_panel.marker_glyph)) |_| {
            hits += 1;
            try testing.expect(std.mem.indexOf(u8, r, "README.md") != null);
        }
    }
    try testing.expectEqual(@as(usize, 1), hits);
}

test "start surface: 49x20 has no mark and no SHORTCUTS; the keys move off a list that did not paint" {
    var f = try Fixture.init(49, 20);
    defer f.deinit();
    var st: State = .{ .active = .shortcuts };
    defer st.deinit(testing.allocator);
    drawSample(&f, &st, true);
    try f.expectLacks(mark[1]);
    try f.expectLacks("SHORTCUTS");
    try f.expectContains("RECENT FILES");
    try testing.expect(!st.isShown(.shortcuts));
    try testing.expect(st.active != .shortcuts);
    for (f.hits.items.items) |e| try expectInside(f.full(), e.rect);
}

test "start surface: a list's detail goes before its text is cut to nothing" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    paintEntry(f.ui(), f.full(), .{ .text = "a long session name", .detail = "claude · 2d" }, false);
    try f.expectRow(0, " a long session name");
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    paintEntry(g.ui(), g.full(), .{ .text = "fix", .detail = "claude · 2d" }, false);
    // The detail ends on the row's last cell.
    try g.expectRow(0, " fix" ++ " " ** 25 ++ "claude · 2d");
}
