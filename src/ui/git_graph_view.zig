//! The commit graph pane, cell for cell the Rust editor's
//! `ui/git_graph_view.rs`: the git toolbar on top, the commit list on
//! the left under its column header, the detail column on the right.
//!
//! ```text
//!    󰕌 Undo   󰑎 Redo    Pull    Push  …
//!      G… │ COMMIT MESSAGE          │ DATE / TIME   │     SHA    │─ WIP @ main · 1 change(s) · 1
//! ▌▶       │ 1 change(s) · 1 new    │               │            │
//! ▌    ●─╮ │ HEAD main merge featu… │   09/06 20:00 │ 7ce273514  │  ▾ Unstaged Files (1)  Stage A
//! ▌    ● │ │ main work              │   09/06 20:00 │ 34b03ced4  │    ? .gitignore           [+]
//! ```
//!
//! A row is `▌` in its lane's colour, `▶ ` on the cursor row, the
//! branch chips, the graph cells with `lane_spacing` pad cells between
//! lanes, then ` │ ` separators around the subject, author, date and
//! sha columns, two cells of pad after the sha. The header's `G…` is
//! `GRAPH` cut to the graph's width. The detail column is the working
//! tree on the WIP row — its file lists with `[+]` / `[−]` and the
//! commit box at the bottom — and a commit's message and files
//! otherwise. Lanes come from `layout`, Rust's walk with the
//! five-row lane cooldown and the rounded corners.
//!
//! Every click target registers in the statement that paints it; the
//! ids are below `special_base` for the rows (their virtual index)
//! and above it for everything else.

const std = @import("std");
const vaxis = @import("vaxis");
const link_span = @import("link_span.zig");
const Rect = @import("rect.zig");
const columns = @import("mnml_sdk").pane.columns;
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const border = @import("border.zig");
const clip = @import("clip.zig");
const git_toolbar = @import("git_toolbar.zig");
const overlay = @import("overlay.zig");
const text_field = @import("text_field.zig");
const parse = @import("../git/parse.zig");
const ids = @import("../core/ids.zig");
const localtime = @import("../core/localtime.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const Color = vaxis.Color;
const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;

// ─── lanes ──────────────────────────────────────────────────────────────

pub const Glyph = enum {
    blank,
    node,
    pass,
    horiz,
    cross,
    /// `╭` — a branch opening to the left of the node.
    tl,
    /// `╮` — a branch opening to the right.
    tr,
    /// `╰` — a lane closing in from the left.
    bl,
    /// `╯` — a lane closing in from the right.
    br,

    pub fn text(g: Glyph, ascii: bool) []const u8 {
        if (ascii) return switch (g) {
            .blank => " ",
            .node => "*",
            .pass => "|",
            .horiz => "-",
            .cross => "+",
            .tl, .br => "/",
            .tr, .bl => "\\",
        };
        return switch (g) {
            .blank => " ",
            .node => "\u{25CF}",
            .pass => "\u{2502}",
            .horiz => "\u{2500}",
            .cross => "\u{253C}",
            .tl => "\u{256D}",
            .tr => "\u{256E}",
            .bl => "\u{2570}",
            .br => "\u{256F}",
        };
    }

    /// Rust's `opens_right` / `opens_left`: whether the cell's stroke
    /// continues into the pad after / before it.
    fn opensRight(g: Glyph) bool {
        return g == .tl or g == .bl or g == .horiz or g == .cross;
    }
    fn opensLeft(g: Glyph) bool {
        return g == .tr or g == .br or g == .horiz or g == .cross;
    }
};

pub const LaneCell = struct { g: Glyph = .blank, color: u8 = 0 };

/// One commit's row of the graph.
pub const Lane = struct {
    /// The column the commit sits in.
    lane: u16,
    /// One per column that exists at this row.
    cells: []LaneCell,
};

pub const lane_colors: u8 = 6;
const cooldown: u16 = 5;

/// Lanes for `commits` (children before parents) — Rust `log::layout`:
/// a commit takes the lane waiting for it (or a fresh one), other lanes
/// waiting for it close in with a corner, extra parents open lanes of
/// their own, a freed lane is not reused for five rows, and a `─` run
/// joins the node to its furthest corner, crossing passing lanes with
/// `┼`. Every slice borrows `arena`.
pub fn layout(arena: Allocator, commits: []const parse.Commit) Allocator.Error![]Lane {
    const out = try arena.alloc(Lane, commits.len);
    var lanes: std.ArrayListUnmanaged(?[]const u8) = .empty;
    var cool: std.ArrayListUnmanaged(u16) = .empty;
    for (commits, 0..) |c, ci| {
        for (cool.items) |*cd| cd.* -|= 1;
        var mine: ?usize = null;
        for (lanes.items, 0..) |l, i| if (l != null and std.mem.eql(u8, l.?, c.hash)) {
            mine = i;
            break;
        };
        const my_lane = mine orelse blk: {
            try lanes.append(arena, null);
            try cool.append(arena, 0);
            break :blk lanes.items.len - 1;
        };
        var merging: std.ArrayListUnmanaged(usize) = .empty;
        for (lanes.items, 0..) |l, i| if (i != my_lane and l != null and std.mem.eql(u8, l.?, c.hash)) try merging.append(arena, i);
        var branch_to: std.ArrayListUnmanaged(usize) = .empty;
        if (c.parents.len > 1) for (c.parents[1..]) |p| {
            var heads = false;
            for (lanes.items) |l| if (l != null and std.mem.eql(u8, l.?, p)) {
                heads = true;
            };
            if (heads) continue;
            var free: ?usize = null;
            for (lanes.items, 0..) |l, i| if (i != my_lane and l == null and cool.items[i] == 0) {
                free = i;
                break;
            };
            const slot = free orelse blk: {
                try lanes.append(arena, null);
                try cool.append(arena, 0);
                break :blk lanes.items.len - 1;
            };
            lanes.items[slot] = p;
            try branch_to.append(arena, slot);
        };
        const cells = try arena.alloc(LaneCell, lanes.items.len);
        for (lanes.items, 0..) |l, i| {
            const color: u8 = @intCast(i % lane_colors);
            cells[i] = .{ .g = .blank, .color = color };
            if (i == my_lane) {
                cells[i] = .{ .g = .node, .color = color };
            } else if (std.mem.indexOfScalar(usize, merging.items, i) != null) {
                cells[i] = .{ .g = if (i < my_lane) .bl else .br, .color = color };
            } else if (std.mem.indexOfScalar(usize, branch_to.items, i) != null) {
                cells[i] = .{ .g = if (i < my_lane) .tl else .tr, .color = color };
            } else if (l != null) {
                cells[i] = .{ .g = .pass, .color = color };
            }
        }
        var lo = my_lane;
        var hi = my_lane;
        for (merging.items) |e| {
            lo = @min(lo, e);
            hi = @max(hi, e);
        }
        for (branch_to.items) |e| {
            lo = @min(lo, e);
            hi = @max(hi, e);
        }
        var x = lo + 1;
        while (x < hi) : (x += 1) {
            if (cells[x].g == .blank) {
                cells[x] = .{ .g = .horiz, .color = @intCast(my_lane % lane_colors) };
            } else if (cells[x].g == .pass) {
                cells[x].g = .cross;
            }
        }
        out[ci] = .{ .lane = @intCast(my_lane), .cells = cells };
        for (merging.items) |i| {
            lanes.items[i] = null;
            cool.items[i] = cooldown;
        }
        lanes.items[my_lane] = if (c.parents.len > 0) c.parents[0] else null;
        if (lanes.items[my_lane] == null) cool.items[my_lane] = cooldown;
        while (lanes.items.len > 0 and lanes.items[lanes.items.len - 1] == null) {
            _ = lanes.pop();
            _ = cool.pop();
        }
    }
    return out;
}

pub const State = struct {
    scroll: usize = 0,
    detail_scroll: usize = 0,
    /// A jump landed off screen: centre it on the next paint.
    center_next: bool = false,
};

// ─── sort ───────────────────────────────────────────────────────────────

pub const SortCol = enum {
    none,
    author,
    date,
    sha,

    pub fn next(c: SortCol) SortCol {
        return switch (c) {
            .none => .date,
            .date => .author,
            .author => .sha,
            .sha => .none,
        };
    }
};

/// `none` is git's own topological order (the lanes only make sense
/// there); a column sorts the list.
pub const Sort = struct {
    col: SortCol = .none,
    asc: bool = false,
};

/// The display order under `sort`: indices into `commits`. `none`
/// keeps git's order; date sorts newest first unless `asc`; author and
/// sha sort A–Z when `asc` — every column reads `asc` the same way,
/// and ties keep git's order.
pub fn sortOrder(arena: Allocator, commits: []const parse.Commit, sort: Sort) Allocator.Error![]u32 {
    const out = try arena.alloc(u32, commits.len);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    if (sort.col == .none) return out;
    const Ctx = struct {
        commits: []const parse.Commit,
        sort: Sort,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ca = ctx.commits[a];
            const cb = ctx.commits[b];
            const ord: std.math.Order = switch (ctx.sort.col) {
                .none => .eq,
                .date => std.math.order(ca.time, cb.time),
                .author => orderIgnoreCase(ca.author, cb.author),
                .sha => orderIgnoreCase(ca.hash, cb.hash),
            };
            if (ord == .eq) return a < b;
            return if (ctx.sort.asc) ord == .lt else ord == .gt;
        }
    };
    std.mem.sort(u32, out, Ctx{ .commits = commits, .sort = sort }, Ctx.lessThan);
    return out;
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

/// The first commit whose hash starts with `prefix` (ASCII
/// case-insensitive); an empty prefix matches nothing.
pub fn findByHashPrefix(commits: []const parse.Commit, prefix: []const u8) ?usize {
    const p = std.mem.trim(u8, prefix, " \t");
    if (p.len == 0) return null;
    for (commits, 0..) |c, i| {
        if (c.hash.len >= p.len and std.ascii.eqlIgnoreCase(c.hash[0..p.len], p)) return i;
    }
    return null;
}

// ─── hit ids ────────────────────────────────────────────────────────────

/// Rows are their virtual index (the WIP row is 0 when shown); the
/// controls live above `special_base`.
pub const special_base: u32 = 0xF000_0000;
pub const divider_id: u32 = 0xF000_0001;
const sort_base: u32 = 0xF100_0000;
const wip_btn_base: u32 = 0xF200_0000;
// 0xF300_0000 is the git toolbar's.
const wip_unstaged_base: u32 = 0xF400_0000;
const wip_staged_base: u32 = 0xF500_0000;
const wip_stage_base: u32 = 0xF600_0000;
const wip_unstage_base: u32 = 0xF700_0000;
const detail_row_base: u32 = 0xF800_0000;
const span: u32 = 0x0100_0000;

pub fn sortId(c: SortCol) u32 {
    return sort_base + @intFromEnum(c);
}

pub fn sortOf(id: u32) ?SortCol {
    if (id < sort_base or id >= sort_base + 4) return null;
    return @enumFromInt(id - sort_base);
}

/// The detail column's controls: the two section buttons, the commit
/// box's three, and the textarea itself.
pub const WipButton = enum { stage_all, unstage_all, commit, ai_message, clear, textarea };

pub fn wipButtonId(b: WipButton) u32 {
    return wip_btn_base + @intFromEnum(b);
}

pub fn wipButtonOf(id: u32) ?WipButton {
    const n: u32 = @typeInfo(WipButton).@"enum".fields.len;
    if (id < wip_btn_base or id >= wip_btn_base + n) return null;
    return @enumFromInt(id - wip_btn_base);
}

/// A file row of the working tree, or its `[+]` / `[−]`.
pub const WipFileHit = struct { idx: u32, staged: bool, button: bool };

pub fn wipFileId(h: WipFileHit) u32 {
    const base: u32 = if (h.button) (if (h.staged) wip_unstage_base else wip_stage_base) else (if (h.staged) wip_staged_base else wip_unstaged_base);
    return base + h.idx;
}

pub fn wipFileOf(id: u32) ?WipFileHit {
    if (id >= wip_unstaged_base and id < wip_unstaged_base + span) return .{ .idx = id - wip_unstaged_base, .staged = false, .button = false };
    if (id >= wip_staged_base and id < wip_staged_base + span) return .{ .idx = id - wip_staged_base, .staged = true, .button = false };
    if (id >= wip_stage_base and id < wip_stage_base + span) return .{ .idx = id - wip_stage_base, .staged = false, .button = true };
    if (id >= wip_unstage_base and id < wip_unstage_base + span) return .{ .idx = id - wip_unstage_base, .staged = true, .button = true };
    return null;
}

pub fn detailRowId(i: u32) u32 {
    return detail_row_base + i;
}

pub fn detailRowOf(id: u32) ?u32 {
    if (id < detail_row_base or id >= detail_row_base + span) return null;
    return id - detail_row_base;
}

// ─── the document ───────────────────────────────────────────────────────

/// One working-tree file for the detail column.
pub const WipFile = struct { path: []const u8, letter: u8 };

/// The commit box's text and state.
pub const CommitDoc = struct {
    text: []const u8 = "",
    cursor: usize = 0,
    focused: bool = false,
    ai_streaming: bool = false,
};

/// The working tree, for the WIP row's detail column.
pub const WipDoc = struct {
    branch: ?[]const u8,
    /// Rust's `format_wip_summary`: `2 change(s) · 1 staged · 1 new`.
    summary: []const u8,
    unstaged: []const WipFile = &.{},
    staged: []const WipFile = &.{},
    commit: CommitDoc = .{},
};

/// A commit's detail column.
pub const DetailDoc = struct {
    short: []const u8,
    author: []const u8,
    age: []const u8,
    message: []const u8 = "",
    parents: []const []const u8 = &.{},
    files: []const parse.DetailFile = &.{},
    pending: bool = false,
};

pub const Doc = struct {
    commits: []const parse.Commit,
    lanes: []const Lane,
    /// Display order: indices into `commits`; `commits.len` long.
    order: []const u32,
    /// Over the virtual rows: the WIP row first when `has_wip`.
    cursor: usize,
    focused: bool,
    lane_spacing: u16 = 1,
    /// Unix seconds, for the ages.
    now: i64,
    /// The DATE / TIME column reads UTC when the statusline clock does
    /// (`clock.utc`), else the machine's zone — the same reader, so the
    /// two clocks on one screen agree.
    utc: bool = false,
    sort: Sort = .{},
    /// The active filters, chipped over the subject header; null = none.
    filter_label: ?[]const u8 = null,
    /// `/` is typing a hash prefix: painted `/<prefix>_` over the subject
    /// header, before the filter chip (Rust `hash_filter`); null = not
    /// typing. // changed: Rust paints it only once a digit is typed;
    /// the empty `/_` shows the mode is on.
    hash_filter: ?[]const u8 = null,
    has_wip: bool = false,
    /// The working tree, painted in the detail column on the WIP row.
    wip: ?WipDoc = null,
    /// The selected commit's detail, painted otherwise.
    detail: ?DetailDoc = null,
    /// The detail column's width: a drag or config override, else a third.
    detail_w: ?u16 = null,
    branch_col: ?u16 = null,
    author_col: ?u16 = null,
    has_stash: bool = false,
    /// The operation the repo is in the middle of; the toolbar swaps.
    in_progress: parse.InProgress = .none,
    /// Multi-select, per commit index: a marked row shows `✓` beside
    /// the cursor cell (the lane's `●` node sits further right).
    marks: ?[]const bool = null,
    /// A `v` range in progress: the virtual rows from the anchor to the
    /// cursor, both ends in, painted as marked.
    range: ?[2]usize = null,
    /// While the plan is open, per commit index: 0 = not in the plan,
    /// else `@intFromEnum(TodoAction) + 1` — the row shows the action's
    /// letter and its colour.
    plan_actions: ?[]const u8 = null,
    /// The compare base (`W`), a commit index: its mark cell shows `⚑`.
    compare_base: ?usize = null,
    /// Per commit index: the row is in `base..HEAD` while a base is set
    /// — painted on the raised ground so the range reads at a glance.
    tinted: ?[]const bool = null,
};

/// The colour of a planned action: what the plan modal's action column
/// and the tinted graph rows share.
pub fn actionColor(pal: Theme.Palette, a: parse.TodoAction) Color {
    return switch (a) {
        .pick => pal.fg,
        .reword => pal.blue,
        .edit => pal.cyan,
        .squash => pal.purple,
        .fixup => pal.purple,
        .drop => pal.red,
    };
}

fn actionLetter(a: parse.TodoAction) []const u8 {
    return switch (a) {
        .pick => "p",
        .reword => "r",
        .edit => "e",
        .squash => "s",
        .fixup => "f",
        .drop => "d",
    };
}

/// What `draw` measured.
pub const Painted = struct {
    /// The rows under the column header.
    body: Rect = Rect.empty,
    list: Rect = Rect.empty,
    detail: Rect = Rect.empty,
    /// The commit box, when painted.
    textarea: Rect = Rect.empty,
    /// The terminal cursor, when the commit box has the focus.
    caret: ?Caret = null,
};

pub const sha_right_pad: u16 = 2;

pub fn totalRows(doc: Doc) usize {
    return doc.commits.len + @as(usize, if (doc.has_wip) 1 else 0);
}

fn laneColor(pal: Theme.Palette, idx: u8) Color {
    return switch (idx % lane_colors) {
        0 => pal.blue,
        1 => pal.green,
        2 => pal.yellow,
        3 => pal.purple,
        4 => pal.cyan,
        else => pal.orange,
    };
}

/// Code points, as Rust's `chars().count()` measures.
fn chars(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn takeChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len and count < n) : (count += 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return s[0..i];
}

fn skipChars(s: []const u8, n: usize) []const u8 {
    return s[takeChars(s, n).len..];
}

/// Rust `pad_or_truncate`: exactly `width` code points, `…` closing a cut.
pub fn padOrTruncate(arena: Allocator, s: []const u8, width: usize, ascii: bool) Allocator.Error![]const u8 {
    if (width == 0) return "";
    const n = chars(s);
    if (n == width) return s;
    if (n < width) {
        const out = try arena.alloc(u8, s.len + (width - n));
        @memcpy(out[0..s.len], s);
        @memset(out[s.len..], ' ');
        return out;
    }
    const ell: []const u8 = if (ascii) "~" else "\u{2026}";
    if (width == 1) return ell;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ takeChars(s, width - 1), ell });
}

/// Rust `right_align`: `s` at the right of `width` code points, its
/// head cut behind `…` when too long.
pub fn rightAlign(arena: Allocator, s: []const u8, width: usize, ascii: bool) Allocator.Error![]const u8 {
    if (width == 0) return "";
    const n = chars(s);
    if (n == width) return s;
    if (n < width) {
        const out = try arena.alloc(u8, s.len + (width - n));
        @memset(out[0 .. width - n], ' ');
        @memcpy(out[width - n ..], s);
        return out;
    }
    const ell: []const u8 = if (ascii) "~" else "\u{2026}";
    if (width == 1) return ell;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ ell, skipChars(s, n - (width - 1)) });
}

/// Rust `format_commit_datetime`: `MM/DD HH:MM` for `secs` shifted by
/// `offset_secs` (the zone's seconds east of UTC). // changed: Rust
/// read the shift from an undocumented `TZ_OFFSET_HOURS` (default 0 —
/// UTC, unmarked, while its clock read the same knob); here the caller
/// hands in the zone the statusline clock uses, so a commit made at
/// 19:01 -0400 reads `19:01` on that machine, as `git log` prints it.
pub fn commitDateTime(buf: []u8, secs: i64, offset_secs: i64) []const u8 {
    const local = secs +| offset_secs;
    const days = @divFloor(local, 86_400);
    const day_secs = @mod(local, 86_400);
    const hh: u32 = @intCast(@divFloor(day_secs, 3600));
    const mm: u32 = @intCast(@mod(@divFloor(day_secs, 60), 60));
    const ymd = daysToYmd(days);
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}", .{ ymd.m, ymd.d, hh, mm }) catch "";
}

/// Howard Hinnant's civil-from-days.
fn daysToYmd(days: i64) struct { y: i64, m: u32, d: u32 } {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: u64 = @intCast(z - era * 146_097);
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Rust `humanize_age`: `now`, `3m`, `5h`, `2d`, `7w`, `4mo`, `2y`.
pub fn humanizeAge(buf: []u8, secs: i64) []const u8 {
    const s = @max(secs, 0);
    if (s < 60) return "now";
    const m = @divFloor(s, 60);
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "";
    const h = @divFloor(m, 60);
    if (h < 24) return std.fmt.bufPrint(buf, "{d}h", .{h}) catch "";
    const d = @divFloor(h, 24);
    if (d < 14) return std.fmt.bufPrint(buf, "{d}d", .{d}) catch "";
    const w = @divFloor(d, 7);
    if (w < 9) return std.fmt.bufPrint(buf, "{d}w", .{w}) catch "";
    const mo = @divFloor(d, 30);
    if (mo < 24) return std.fmt.bufPrint(buf, "{d}mo", .{mo}) catch "";
    return std.fmt.bufPrint(buf, "{d}y", .{@divFloor(d, 365)}) catch "";
}

// ─── refs → chips ───────────────────────────────────────────────────────

pub const RefKind = enum { head, local, remote, tag };
pub const RefLabel = struct { kind: RefKind, name: []const u8 };

/// `HEAD -> main, origin/main, tag: v1` → the chips in Rust's order:
/// HEAD, local branches, remotes, tags, each group A–Z.
pub fn refLabels(arena: Allocator, refs: []const u8) Allocator.Error![]RefLabel {
    var out: std.ArrayListUnmanaged(RefLabel) = .empty;
    var it = std.mem.splitSequence(u8, refs, ", ");
    while (it.next()) |raw| {
        const r = std.mem.trim(u8, raw, " ");
        if (r.len == 0) continue;
        if (std.mem.startsWith(u8, r, "HEAD -> ")) {
            try out.append(arena, .{ .kind = .head, .name = "HEAD" });
            try out.append(arena, .{ .kind = .local, .name = r["HEAD -> ".len..] });
        } else if (std.mem.eql(u8, r, "HEAD")) {
            try out.append(arena, .{ .kind = .head, .name = "HEAD" });
        } else if (std.mem.startsWith(u8, r, "tag: ")) {
            try out.append(arena, .{ .kind = .tag, .name = r["tag: ".len..] });
        } else if (std.mem.indexOfScalar(u8, r, '/') != null) {
            if (!std.mem.endsWith(u8, r, "/HEAD")) try out.append(arena, .{ .kind = .remote, .name = r });
        } else {
            try out.append(arena, .{ .kind = .local, .name = r });
        }
    }
    const Ctx = struct {
        fn lt(_: void, a: RefLabel, b: RefLabel) bool {
            if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };
    std.mem.sort(RefLabel, out.items, {}, Ctx.lt);
    return out.items;
}

/// Rust `chip_width_for_refs`: the chips joined by one space.
fn chipWidth(labels: []const RefLabel) usize {
    var sum: usize = 0;
    for (labels, 0..) |r, i| {
        sum += chars(r.name) + @as(usize, if (r.kind == .tag) 1 else 0);
        if (i + 1 < labels.len) sum += 1;
    }
    return sum;
}

// ─── columns ────────────────────────────────────────────────────────────

pub const Cols = struct { branch: usize = 0, author: usize = 0, age: usize = 0, sha: usize = 0 };
pub const AutoSize = struct { branch_chars: usize, author_chars: usize, branch_override: ?u16, author_override: ?u16, subject_chars: usize = 0 };

/// Rust `compute_column_widths`: the sha, the date, the author and the
/// branch chips take their room in that order, each with its ` │ `,
/// after the fixed cells and twenty for the subject.
pub fn computeColumnWidths(total: usize, graph_w: usize, auto: AutoSize) Cols {
    const min_fixed = 1 + 2 + graph_w + 3 + 20;
    var remaining = total -| min_fixed;
    var w: Cols = .{};
    if (remaining >= 9 + 3) {
        w.sha = 9;
        remaining -= 9 + 3;
    }
    if (remaining >= 13 + 3) {
        w.age = 13;
        remaining -= 13 + 3;
    } else if (remaining >= 11 + 3) {
        w.age = 11;
        remaining -= 11 + 3;
    } else if (remaining >= 6 + 3) {
        w.age = 6;
        remaining -= 6 + 3;
    }
    const author_target: usize = if (auto.author_override) |n| n else std.math.clamp(auto.author_chars, 8, 22);
    if (author_target > 0 and remaining >= author_target + 3) {
        w.author = author_target;
        remaining -= author_target + 3;
    }
    const branch_target: usize = if (auto.branch_override) |n| n else (if (auto.branch_chars == 0) 0 else std.math.clamp(auto.branch_chars, 8, 24));
    if (branch_target > 0 and remaining >= branch_target + 3) {
        w.branch = @min(branch_target, remaining -| 3);
        remaining -= w.branch + 3;
    }
    // What is still spare beyond the subject's twenty goes first to an
    // author or a branch cut at its cap, shared with a subject that is
    // itself cut (`sdk.pane.columns`, the family's one table rule); a
    // width the person set by hand stays as set.
    if (remaining > 0 and (w.author > 0 or w.branch > 0)) {
        const cap = std.math.maxInt(u16);
        const specs = [_]columns.Spec{
            .{ .w = @intCast(@min(w.author, cap)), .need = @intCast(@min(auto.author_chars, 200)), .fixed = auto.author_override != null },
            .{ .w = @intCast(@min(w.branch, cap)), .need = @intCast(@min(auto.branch_chars, 200)), .fixed = auto.branch_override != null },
            .{ .w = 20, .rest = true, .need = @intCast(@min(auto.subject_chars, 2000)) },
        };
        var out: [3]u16 = undefined;
        columns.fit(&out, &specs, @intCast(@min(w.author + w.branch + 20 + remaining, cap)), 0);
        w.author = out[0];
        w.branch = out[1];
    }
    return w;
}

/// Rust `reveal_scroll`: stepping scrolls the minimum; a jump to a row
/// off screen lands it a third of the way down.
pub fn revealScroll(selected: usize, scroll: usize, h: usize, want_center: bool) usize {
    if (h == 0) return scroll;
    const visible = selected >= scroll and selected < scroll + h;
    if (want_center and !visible) return selected -| (h / 3);
    if (selected < scroll) return selected;
    if (selected >= scroll + h) return selected + 1 - h;
    return scroll;
}

// ─── paint ──────────────────────────────────────────────────────────────

/// A pen along one row.
const Pen = struct {
    ui: Ui,
    x: u16,
    y: u16,
    end: u16,

    fn put(p: *Pen, s: []const u8, style: Style) void {
        p.x += p.ui.putStr(p.x, p.y, p.end -| p.x, s, style);
    }

    fn spaces(p: *Pen, n: usize, style: Style) void {
        var i: usize = 0;
        while (i < n) : (i += 1) p.put(" ", style);
    }
};

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) Painted {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    const ground: Style = .{ .bg = pal.bg_dark };
    var painted: Painted = .{};
    ui.fill(area, ground);
    if (area.isEmpty()) return painted;
    const total = totalRows(doc);
    if (total == 0) {
        _ = ui.putStr(area.x, area.y, area.w, "  (no commits — not a git repo, or empty history)", Theme.withFg(ground, pal.comment));
        return painted;
    }
    const cursor = @min(doc.cursor, total - 1);

    // ── the toolbar ──
    var body_full = area;
    if (area.w >= 40 and area.h >= 6) {
        git_toolbar.draw(ui, area.row(0), .{ .pane = pane, .has_stash = doc.has_stash, .in_progress = doc.in_progress });
        body_full = area.splitTop(1).rest;
    }

    // ── list | detail ──
    const detail_w: u16 = if (body_full.w >= 80)
        (if (doc.detail_w) |w| std.math.clamp(w, 20, body_full.w -| 40) else std.math.clamp(body_full.w / 3, 28, 60))
    else
        0;
    var list_area = body_full;
    var detail_area: ?Rect = null;
    if (detail_w > 0) {
        list_area = Rect.init(body_full.x, body_full.y, body_full.w - detail_w - 1, body_full.h);
        detail_area = Rect.init(body_full.right() - detail_w, body_full.y, detail_w, body_full.h);
        const div = Rect.init(list_area.right(), body_full.y, 1, body_full.h);
        ui.vrule(div.x, div.y, div.h, Theme.withFg(ground, pal.grey));
        ui.hit(div, .{ .script_hit = .{ .pane = pane, .id = divider_id } });
    }
    painted.list = list_area;
    if (list_area.h == 0) return painted;
    const header_area = list_area.row(0);
    const body = list_area.splitTop(1).rest;
    painted.body = body;
    const lane_pad: usize = doc.lane_spacing;

    // ── the window ──
    const h: usize = body.h;
    const want_center = view.center_next;
    view.center_next = false;
    view.scroll = revealScroll(cursor, view.scroll, h, want_center);
    view.scroll = @min(view.scroll, total -| @min(h, total));
    const wip_off: usize = if (doc.has_wip) 1 else 0;
    const first = view.scroll;
    const last = @min(total, first + h);

    var graph_w: usize = 0;
    var auto_branch: usize = 0;
    var auto_author: usize = 0;
    var auto_subject: usize = 0;
    var v = first;
    while (v < last) : (v += 1) {
        if (doc.has_wip and v == 0) continue;
        const ci = doc.order[v - wip_off];
        if (ci < doc.lanes.len) graph_w = @max(graph_w, doc.lanes[ci].cells.len);
        const labels = refLabels(arena, doc.commits[ci].refs) catch &.{};
        auto_branch = @max(auto_branch, chipWidth(labels));
        auto_author = @max(auto_author, chars(doc.commits[ci].author));
        auto_subject = @max(auto_subject, chars(doc.commits[ci].subject));
    }
    graph_w = @min(graph_w, 24);
    const cols = computeColumnWidths(@as(usize, body.w) -| sha_right_pad, graph_w, .{
        .branch_chars = auto_branch,
        .author_chars = auto_author,
        .branch_override = doc.branch_col,
        .author_override = doc.author_col,
        .subject_chars = auto_subject,
    });
    drawHeader(ui, pane, header_area, doc, cols, graph_w);

    // ── the rows ──
    const graph_col_w = graph_w + lane_pad * (graph_w -| 1);
    const branch_section: usize = if (cols.branch > 0) cols.branch + 3 else 2;
    const suffix_used = (if (cols.author > 0) cols.author + 3 else 0) + (if (cols.age > 0) cols.age + 3 else 0) + (if (cols.sha > 0) cols.sha + 3 else 0) + sha_right_pad;
    const prefix_used = 1 + 2 + branch_section + graph_col_w + 3;
    const subject_w = @as(usize, body.w) -| (prefix_used + suffix_used);
    v = first;
    var y: u16 = 0;
    while (v < last) : ({
        v += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const selected = v == cursor;
        const row_bg: Color = if (selected) pal.bg2 else pal.bg_dark;
        var base: Style = .{ .bg = row_bg };
        ui.fill(r, base);
        var pen: Pen = .{ .ui = ui, .x = r.x, .y = r.y, .end = r.right() };
        const sep = Theme.withFg(base, pal.line);
        if (doc.has_wip and v == 0) {
            // The WIP row: the yellow lane bar, the summary in the subject.
            pen.put("\u{258C}", Theme.withFg(base, pal.yellow));
            pen.put(if (selected) "\u{25B6} " else "  ", Theme.withFg(base, pal.yellow));
            if (cols.branch > 0) {
                var s = Theme.withFg(base, pal.yellow);
                s.bold = true;
                pen.put(padOrTruncate(arena, ui.fmt("WIP @ {s}", .{if (doc.wip) |w| (w.branch orelse "\u{2026}") else "\u{2026}"}), cols.branch, ui.ascii) catch "", s);
                pen.put(" \u{2502} ", sep);
            } else pen.put("  ", base);
            pen.spaces(graph_col_w, base);
            pen.put(" \u{2502} ", sep);
            var s = Theme.withFg(base, pal.yellow);
            s.italic = true;
            pen.put(padOrTruncate(arena, if (doc.wip) |w| w.summary else "", subject_w, ui.ascii) catch "", s);
            if (cols.author > 0) {
                pen.put(" \u{2502} ", sep);
                pen.spaces(cols.author, base);
            }
            if (cols.age > 0) {
                pen.put(" \u{2502} ", sep);
                pen.spaces(cols.age, base);
            }
            if (cols.sha > 0) {
                pen.put(" \u{2502} ", sep);
                pen.spaces(cols.sha, base);
            }
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = 0 } });
            continue;
        }
        const ci = doc.order[v - wip_off];
        const c = doc.commits[ci];
        const lane: Lane = if (ci < doc.lanes.len) doc.lanes[ci] else .{ .lane = 0, .cells = &.{} };
        const in_tint = if (doc.tinted) |tn| (ci < tn.len and tn[ci]) else false;
        if (in_tint and !selected) {
            base = .{ .bg = pal.bg3 };
            ui.fill(r, base);
            pen = .{ .ui = ui, .x = r.x, .y = r.y, .end = r.right() };
        }
        pen.put("\u{258C}", Theme.withFg(base, laneColor(pal, @intCast(lane.lane))));
        pen.put(if (selected) "\u{25B6}" else " ", Theme.withFg(base, pal.yellow));
        // The mark cell: the planned action's letter while the plan is
        // open, `●` for a selected row, else the space Rust paints.
        var planned: ?parse.TodoAction = null;
        if (doc.plan_actions) |pa| if (ci < pa.len and pa[ci] > 0) {
            planned = @enumFromInt(pa[ci] - 1);
        };
        const in_range = if (doc.range) |rg| (v >= @min(rg[0], rg[1]) and v <= @max(rg[0], rg[1])) else false;
        const marked = in_range or (if (doc.marks) |m| (ci < m.len and m[ci]) else false);
        if (planned) |a| {
            var ps = Theme.withFg(base, actionColor(pal, a));
            ps.bold = true;
            pen.put(actionLetter(a), ps);
        } else if (doc.compare_base != null and doc.compare_base.? == ci) {
            pen.put(if (ui.ascii) "B" else "\u{2691}", Theme.withFg(base, pal.cyan));
        } else if (marked) {
            pen.put(if (ui.ascii) "*" else "\u{2713}", Theme.withFg(base, pal.yellow));
        } else pen.put(" ", base);
        const subject_fg: Color = if (planned) |a| actionColor(pal, a) else pal.fg;
        if (cols.branch > 0) {
            drawBranchChips(ui, &pen, refLabels(arena, c.refs) catch &.{}, cols.branch, base);
            pen.put(" \u{2502} ", sep);
        } else pen.put("  ", base);
        var k: usize = 0;
        while (k < graph_w) : (k += 1) {
            const cell: LaneCell = if (k < lane.cells.len) lane.cells[k] else .{};
            pen.put(cell.g.text(ui.ascii), Theme.withFg(base, laneColor(pal, cell.color)));
            if (lane_pad > 0 and k + 1 < graph_w) {
                const next: LaneCell = if (k + 1 < lane.cells.len) lane.cells[k + 1] else .{};
                const joins = cell.g.opensRight() or next.g.opensLeft();
                const color = if (cell.g.opensRight()) cell.color else next.color;
                var p: usize = 0;
                while (p < lane_pad) : (p += 1) pen.put(if (joins) Glyph.horiz.text(ui.ascii) else " ", if (joins) Theme.withFg(base, laneColor(pal, color)) else base);
            }
        }
        pen.put(" \u{2502} ", sep);
        var subj = Theme.withFg(base, subject_fg);
        if (planned) |a| subj.strikethrough = a == .drop;
        // No BRANCH / TAG column at this width (the sha, the date and the
        // author took the room first): the refs lead the subject, as
        // `git log --decorate` prints them — a graph that names no
        // branch, tag or HEAD cannot say where anything is.
        var subject_room = subject_w;
        if (cols.branch == 0 and subject_w >= 12) {
            const labels = refLabels(arena, c.refs) catch &.{};
            if (labels.len > 0) {
                const chip_w = @min(chipWidth(labels), subject_w / 2);
                drawBranchChips(ui, &pen, labels, chip_w, base);
                pen.put(" ", base);
                subject_room = subject_w - chip_w - 1;
            }
        }
        pen.put(padOrTruncate(arena, c.subject, subject_room, ui.ascii) catch "", subj);
        if (cols.author > 0) {
            pen.put(" \u{2502} ", sep);
            pen.put(rightAlign(arena, c.author, cols.author, ui.ascii) catch "", Theme.withFg(base, pal.comment));
        }
        if (cols.age > 0) {
            // The screen keeps the grapheme slices it is handed until
            // the frame is flushed, so the date must live on the frame
            // arena: `rightAlign` hands an 11-cell column the formatted
            // text itself, and a stack buffer would be gone by then.
            var buf: [16]u8 = undefined;
            const date = arena.dupe(u8, commitDateTime(&buf, c.time, if (doc.utc) 0 else localtime.offset(c.time))) catch "";
            pen.put(" \u{2502} ", sep);
            pen.put(rightAlign(arena, date, cols.age, ui.ascii) catch "", Theme.withFg(base, pal.comment));
        }
        if (cols.sha > 0) {
            pen.put(" \u{2502} ", sep);
            pen.put(rightAlign(arena, c.hash[0..@min(9, c.hash.len)], cols.sha, ui.ascii) catch "", Theme.withFg(base, pal.orange));
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(v) } });
    }

    // ── the list's scrollbar: a plain track, the thumb when it scrolls ──
    if (body.w >= 8 and body.h > 0) {
        const bar = Rect.init(body.right() - 1, body.y, 1, body.h);
        ui.fill(bar, .{ .bg = pal.bg2 });
        const cells: usize = bar.h;
        if (total > cells) {
            const thumb_h = @max((cells * cells) / total, 1);
            const max_scroll = total - cells;
            const max_top = cells -| thumb_h;
            const top = if (max_scroll > 0) (view.scroll * max_top) / max_scroll else 0;
            var cy = top;
            while (cy < @min(top + thumb_h, cells)) : (cy += 1) ui.fill(Rect.init(bar.x, bar.y + @as(u16, @intCast(cy)), 1, 1), .{ .bg = pal.comment });
        }
        ui.hit(bar, .{ .scrollbar = .{ .owner = .{ .pane = pane }, .axis = .v } });
    }

    // ── the detail column ──
    if (detail_area) |da| {
        painted.detail = da;
        if (doc.has_wip and cursor == 0) {
            if (doc.wip) |w| {
                const wp = drawWipDetail(ui, pane, da, w);
                painted.textarea = wp.textarea;
                painted.caret = wp.caret;
            }
        } else if (doc.detail) |d| {
            drawDetail(ui, pane, da, view, d);
        }
    }
    return painted;
}

// ─── the rebase plan ────────────────────────────────────────────────────

pub const plan_row_base: u32 = 0xF000_2000;
const plan_row_cap: u32 = 0x1000;

pub fn planRowId(i: u32) u32 {
    return plan_row_base + @min(i, plan_row_cap - 1);
}

pub fn planRowOf(id: u32) ?u32 {
    if (id < plan_row_base or id >= plan_row_base + plan_row_cap) return null;
    return id - plan_row_base;
}

pub const PlanRowDoc = struct {
    action: parse.TodoAction,
    sha: []const u8,
    subject: []const u8,
    /// One the user selected (the rest are the commits between).
    marked: bool,
    /// A reword whose message is typed.
    has_message: bool = false,
};

pub const PlanDoc = struct {
    rows: []const PlanRowDoc,
    cursor: usize,
    /// The parent the rebase starts from; null = `--root`.
    base: ?[]const u8,
    scroll: usize,
};

pub const plan_hint = "\u{2190}\u{2192} p r e s f d action \u{B7} J K move \u{B7} \u{23CE} run \u{B7} esc cancel";

/// The plan modal over the graph: a boxed list of the todo, oldest
/// first, the action column in its colour, a hint row under it. The
/// caller keeps `scroll` level with the cursor through the returned
/// value. Every row is a hit (`planRowId`).
pub fn drawPlan(ui: Ui, pane: PaneId, area: Rect, doc: PlanDoc) usize {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    if (area.w < 30 or area.h < 6) return doc.scroll;
    const w: u16 = @min(area.w -| 4, 96);
    const want_h: u16 = @intCast(@min(doc.rows.len + 3, @as(usize, area.h -| 2)));
    const h: u16 = @max(want_h, 5);
    const title = if (doc.base) |b|
        ui.fmt("Rebase plan \u{B7} {d} commit{s} onto {s}", .{ doc.rows.len, if (doc.rows.len == 1) "" else "s", b[0..@min(7, b.len)] })
    else
        ui.fmt("Rebase plan \u{B7} {d} commit{s} from the root", .{ doc.rows.len, if (doc.rows.len == 1) "" else "s" });
    const inner = overlay.boxLook(ui, area, w, h, title, .center, .modal);
    if (inner.isEmpty()) return doc.scroll;
    const list_h: usize = inner.h -| 1;
    const scroll = revealScroll(doc.cursor, doc.scroll, @max(list_h, 1), false);
    const bg = t.overlay_bg.bg;
    var i: usize = scroll;
    var y: u16 = 0;
    while (i < doc.rows.len and y < list_h) : ({
        i += 1;
        y += 1;
    }) {
        const row = doc.rows[i];
        const r = inner.row(y);
        const selected = i == doc.cursor;
        const base: Style = .{ .bg = if (selected) pal.bg2 else bg };
        ui.fill(r, base);
        var pen: Pen = .{ .ui = ui, .x = r.x, .y = r.y, .end = r.right() };
        pen.put(if (selected) " \u{25B6} " else "   ", Theme.withFg(base, pal.yellow));
        var act = Theme.withFg(base, actionColor(pal, row.action));
        act.bold = true;
        pen.put(padOrTruncate(arena, row.action.word(), 7, ui.ascii) catch "", act);
        pen.put(row.sha[0..@min(7, row.sha.len)], Theme.withFg(base, pal.orange));
        pen.put("  ", base);
        var subj = Theme.withFg(base, if (row.marked) pal.fg else pal.comment);
        subj.bold = row.marked;
        subj.strikethrough = row.action == .drop;
        const tail: []const u8 = if (row.has_message) (if (ui.ascii) "  [msg]" else "  \u{270E}") else "";
        const avail: usize = @as(usize, r.right() -| pen.x) -| ui.width(tail);
        pen.put(padOrTruncate(arena, row.subject, avail, ui.ascii) catch "", subj);
        if (tail.len > 0) pen.put(tail, Theme.withFg(base, pal.blue));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = planRowId(@intCast(i)) } });
    }
    if (inner.h > 0) overlay.hint(ui, inner.row(inner.h - 1), plan_hint);
    return scroll;
}

/// The column header row: `BRANCH / TAG │ GRAPH │ COMMIT MESSAGE │ AUTHOR │ DATE / TIME │ SHA`.
fn drawHeader(ui: Ui, pane: PaneId, area: Rect, doc: Doc, cols: Cols, graph_w: usize) void {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    const bg: Style = .{ .bg = pal.bg_darker };
    ui.fill(area, bg);
    if (area.isEmpty()) return;
    var pen: Pen = .{ .ui = ui, .x = area.x, .y = area.y, .end = area.right() };
    const sep = Theme.withFg(bg, pal.grey);
    var label = Theme.withFg(bg, pal.comment);
    label.bold = true;
    pen.put("   ", bg);
    if (cols.branch > 0) {
        pen.put(padOrTruncate(arena, "BRANCH / TAG", cols.branch, ui.ascii) catch "", label);
        pen.put(" \u{2502} ", sep);
    } else pen.put("  ", bg);
    pen.put(padOrTruncate(arena, "GRAPH", graph_w, ui.ascii) catch "", label);
    pen.put(" \u{2502} ", sep);
    const branch_section: usize = if (cols.branch > 0) cols.branch + 3 else 2;
    const fixed_used = 1 + 2 + branch_section + graph_w + 3 + (if (cols.author > 0) cols.author + 3 else 0) + (if (cols.age > 0) cols.age + 3 else 0) + (if (cols.sha > 0) cols.sha + 3 else 0) + sha_right_pad;
    const subject_w = @as(usize, area.w) -| fixed_used;
    if (doc.hash_filter) |typed| {
        // The hash-typing chip wins (the active keyboard interaction).
        var s = Theme.withFg(bg, pal.yellow);
        s.bold = true;
        pen.put(padOrTruncate(arena, std.fmt.allocPrint(arena, "/{s}_", .{typed}) catch "", subject_w, ui.ascii) catch "", s);
    } else if (doc.filter_label) |chip| {
        var s = Theme.onBg(Theme.withFg(bg, pal.bg_darker), pal.yellow);
        s.bold = true;
        pen.put(padOrTruncate(arena, chip, subject_w, ui.ascii) catch "", s);
    } else {
        pen.put(padOrTruncate(arena, "COMMIT MESSAGE", subject_w, ui.ascii) catch "", label);
    }
    const sortable = [_]struct { col: SortCol, w: usize, name: []const u8 }{
        .{ .col = .author, .w = cols.author, .name = "AUTHOR" },
        .{ .col = .date, .w = cols.age, .name = "DATE / TIME" },
        .{ .col = .sha, .w = cols.sha, .name = "SHA" },
    };
    for (sortable) |s| {
        if (s.w == 0) continue;
        pen.put(" \u{2502} ", sep);
        const active = doc.sort.col == s.col;
        const glyph: []const u8 = if (!active) "  " else if (doc.sort.asc) (if (ui.ascii) " ^" else " \u{25B2}") else (if (ui.ascii) " v" else " \u{25BC}");
        var style = Theme.withFg(bg, if (active) pal.yellow else pal.comment);
        style.bold = true;
        const x = pen.x;
        pen.put(rightAlign(arena, ui.fmt("{s}{s}", .{ s.name, glyph }), s.w, ui.ascii) catch "", style);
        ui.hit(Rect.init(x, area.y, @intCast(@min(s.w, @as(usize, area.right() -| x))), 1), .{ .script_hit = .{ .pane = pane, .id = sortId(s.col) } });
    }
}

/// Rust `render_branch_chips`: HEAD cyan bold, branches green, remotes
/// purple, tags yellow with `⊙`, one space apart, `+N` when they do
/// not fit, padded to the column.
fn drawBranchChips(ui: Ui, pen: *Pen, labels: []const RefLabel, width: usize, base: Style) void {
    const pal = ui.theme.palette;
    var used: usize = 0;
    for (labels, 0..) |r, i| {
        const text = if (r.kind == .tag) ui.fmt("{s}{s}", .{ if (ui.ascii) "o" else "\u{2299}", r.name }) else r.name;
        const needed = chars(text) + @as(usize, if (i + 1 < labels.len) 1 else 0);
        if (used + needed > width) {
            const tail = ui.fmt("+{d}", .{labels.len - i});
            if (used + chars(tail) <= width) {
                pen.put(tail, Theme.withFg(base, pal.comment));
                used += chars(tail);
            }
            break;
        }
        var s = Theme.withFg(base, switch (r.kind) {
            .head => pal.cyan,
            .local => pal.green,
            .remote => pal.purple,
            .tag => pal.yellow,
        });
        s.bold = r.kind == .head;
        pen.put(text, s);
        used += chars(text);
        if (i + 1 < labels.len) {
            pen.put(" ", base);
            used += 1;
        }
    }
    if (used < width) pen.spaces(width - used, base);
}

// ─── the detail column: a commit ────────────────────────────────────────

const Seg = struct { text: []const u8, style: Style };
const Line = struct {
    segs: []const Seg,
    /// A file row: its index, for the hit.
    file: ?u32 = null,
};

fn lineOf(arena: Allocator, segs: []const Seg) Allocator.Error!Line {
    return .{ .segs = try arena.dupe(Seg, segs) };
}

pub const Para = struct { text: []const u8, pre: bool };

/// Rust `reflow_commit_message`: the subject alone, blank lines and
/// indented lines verbatim, list items their own paragraph, the rest
/// joined into one logical line per paragraph.
pub fn reflowMessage(arena: Allocator, message: []const u8) Allocator.Error![]const Para {
    var out: std.ArrayListUnmanaged(Para) = .empty;
    var para: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, message, '\n');
    var i: usize = 0;
    while (it.next()) |raw_line| : (i += 1) {
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        if (i == 0) {
            try out.append(arena, .{ .text = raw, .pre = false });
            continue;
        }
        const trimmed = std.mem.trim(u8, raw, " \t");
        const list_item = std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "\u{2022} ");
        if (trimmed.len == 0) {
            if (para.items.len > 0) try out.append(arena, .{ .text = try para.toOwnedSlice(arena), .pre = false });
            try out.append(arena, .{ .text = "", .pre = true });
        } else if (raw[0] == ' ' or raw[0] == '\t') {
            if (para.items.len > 0) try out.append(arena, .{ .text = try para.toOwnedSlice(arena), .pre = false });
            try out.append(arena, .{ .text = raw, .pre = true });
        } else if (list_item) {
            if (para.items.len > 0) try out.append(arena, .{ .text = try para.toOwnedSlice(arena), .pre = false });
            try para.appendSlice(arena, std.mem.trimEnd(u8, raw, " \t"));
        } else if (para.items.len == 0) {
            try para.appendSlice(arena, std.mem.trimEnd(u8, raw, " \t"));
        } else {
            try para.append(arena, ' ');
            try para.appendSlice(arena, trimmed);
        }
    }
    if (para.items.len > 0) try out.append(arena, .{ .text = try para.toOwnedSlice(arena), .pre = false });
    return out.items;
}

/// Bytes of `rest` that go on one row of width `w`: the longest prefix
/// that fits, cut back to the last space when the line continues. Never
/// past `rest.len` — the caller slices `rest` by it.
pub fn wrapTake(rest: []const u8, w: u16, method: vaxis.gwidth.Method) usize {
    var take = clip.fitCells(rest, w, method);
    if (take < rest.len) {
        if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| if (sp > 0) {
            take = sp + 1;
        };
    }
    return take;
}

/// A commit's detail: `─ sha · author · age ────`, the message reflowed
/// and wrapped, its parents, `changed files (n):` and one row per file.
fn drawDetail(ui: Ui, pane: PaneId, area: Rect, view: *State, d: DetailDoc) void {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    const bg: Style = .{ .bg = pal.bg };
    ui.fill(area, bg);
    if (area.w < 4 or area.h == 0) return;
    const w: usize = area.w;
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    const head = ui.fmt(" {s} \u{B7} {s} \u{B7} {s} ", .{ d.short, d.author, d.age });
    const dashes = w -| (chars(head) + 1);
    const dash = border.ruleGlyph(.h, ui.ascii);
    var dash_run: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < dashes) : (i += 1) dash_run.appendSlice(arena, dash) catch return;
    lines.append(arena, lineOf(arena, &.{
        .{ .text = dash, .style = Theme.withFg(bg, pal.line) },
        .{ .text = head, .style = Theme.withFg(bg, pal.orange) },
        .{ .text = dash_run.items, .style = Theme.withFg(bg, pal.line) },
    }) catch return) catch return;
    if (d.pending) {
        lines.append(arena, lineOf(arena, &.{.{ .text = "  loading\u{2026}", .style = Theme.withFg(bg, pal.comment) }}) catch return) catch return;
    } else {
        const paras = reflowMessage(arena, d.message) catch return;
        for (paras) |p| {
            const fg = Theme.withFg(bg, pal.fg);
            if (p.pre) {
                lines.append(arena, lineOf(arena, &.{.{ .text = ui.fmt("  {s}", .{p.text}), .style = fg }}) catch return) catch return;
                continue;
            }
            var rest: []const u8 = ui.fmt("  {s}", .{p.text});
            while (rest.len > 0) {
                const take = wrapTake(rest, @intCast(w), ui.canvas.widthMethod());
                if (take == 0) break;
                lines.append(arena, lineOf(arena, &.{.{ .text = std.mem.trimEnd(u8, rest[0..take], " "), .style = fg }}) catch return) catch return;
                rest = rest[take..];
            }
        }
        if (d.parents.len > 0) {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            text.appendSlice(arena, "  parents: ") catch return;
            for (d.parents, 0..) |p, k| {
                if (k > 0) text.appendSlice(arena, "  ") catch return;
                text.appendSlice(arena, p[0..@min(9, p.len)]) catch return;
            }
            lines.append(arena, lineOf(arena, &.{.{ .text = text.items, .style = Theme.withFg(bg, pal.comment) }}) catch return) catch return;
        }
        lines.append(arena, lineOf(arena, &.{}) catch return) catch return;
        var hs = Theme.withFg(bg, pal.comment);
        hs.bold = true;
        lines.append(arena, lineOf(arena, &.{.{ .text = ui.fmt("  changed files ({d}):", .{d.files.len}), .style = hs }}) catch return) catch return;
        const total = d.files.len;
        const avail = @as(usize, area.h) -| (lines.items.len + 1);
        const shown = @min(total, avail -| 1);
        for (d.files[0..shown], 0..) |f, idx| {
            const color = switch (f.status) {
                'A' => pal.green,
                'M' => pal.yellow,
                'D' => pal.red,
                'R' => pal.blue,
                'C' => pal.cyan,
                else => pal.comment,
            };
            const prefix = ui.fmt("  {c} ", .{f.status});
            const pad = w -| (chars(prefix) + chars(f.path));
            var l = lineOf(arena, &.{
                .{ .text = prefix, .style = Theme.withFg(bg, color) },
                .{ .text = f.path, .style = Theme.withFg(bg, pal.fg) },
                .{ .text = padOrTruncate(arena, "", pad, ui.ascii) catch "", .style = bg },
            }) catch return;
            l.file = @intCast(idx);
            lines.append(arena, l) catch return;
        }
        if (shown < total) lines.append(arena, lineOf(arena, &.{.{ .text = ui.fmt("  \u{2026} and {d} more", .{total - shown}), .style = Theme.withFg(bg, pal.comment) }}) catch return) catch return;
    }
    view.detail_scroll = 0;
    var y: u16 = 0;
    for (lines.items) |l| {
        if (y >= area.h) break;
        const r = area.row(y);
        var pen: Pen = .{ .ui = ui, .x = r.x, .y = r.y, .end = r.right() };
        for (l.segs) |s| pen.put(s.text, s.style);
        if (l.file) |fi| ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = detailRowId(fi) } }) else {
            // The message's URLs and declared keys link (a file row is
            // a file).
            var text: std.ArrayListUnmanaged(u8) = .empty;
            for (l.segs) |s| text.appendSlice(arena, s.text) catch break;
            link_span.mark(ui, r.x, r.y, pen.x - r.x, text.items);
        }
        y += 1;
    }
}

// ─── the detail column: the working tree ────────────────────────────────

const WipPainted = struct { textarea: Rect = Rect.empty, caret: ?Caret = null };

/// Rust's ladder for the commit box: ten rows, eight, four, none.
fn commitHeight(h: u16) u16 {
    if (h >= 14) return 10;
    if (h >= 10) return 8;
    if (h >= 6) return 4;
    return 0;
}

/// The working tree: `─ WIP @ branch · summary`, `▾ Unstaged Files (n)`
/// with ` Stage All ` at the edge and a `[+]` per row, `▾ Staged Files
/// (n)` with ` Unstage All ` and `[−]`, then the commit box pinned to the
/// bottom.
fn drawWipDetail(ui: Ui, pane: PaneId, area: Rect, wd: WipDoc) WipPainted {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    const bg: Style = .{ .bg = pal.bg };
    const out: WipPainted = .{};
    ui.fill(area, bg);
    const commit_h = commitHeight(area.h);
    const files_area = Rect.init(area.x, area.y, area.w, area.h -| commit_h);
    const commit_area = Rect.init(area.x, area.y + (area.h -| commit_h), area.w, commit_h);
    const w: usize = files_area.w;

    const Hit = struct { line: usize, x0: usize, x1: usize, id: u32 };
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    // Header.
    const head_full = ui.fmt(" WIP @ {s} \u{B7} {s}", .{ wd.branch orelse "(detached)", wd.summary });
    const head = takeChars(head_full, w -| 1);
    var hs = Theme.withFg(bg, pal.yellow);
    hs.bold = true;
    lines.append(arena, lineOf(arena, &.{ .{ .text = border.ruleGlyph(.h, ui.ascii), .style = Theme.withFg(bg, pal.line) }, .{ .text = head, .style = hs } }) catch return out) catch return out;
    lines.append(arena, lineOf(arena, &.{}) catch return out) catch return out;

    const sections = [_]struct { label: []const u8, files: []const WipFile, button: []const u8, staged: bool, accent: Color }{
        .{ .label = "Unstaged Files", .files = wd.unstaged, .button = " Stage All ", .staged = false, .accent = pal.green },
        .{ .label = "Staged Files", .files = wd.staged, .button = " Unstage All ", .staged = true, .accent = pal.orange },
    };
    for (sections) |sec| {
        const label_text = ui.fmt("  {s} {s} ({d})", .{ if (ui.ascii) "v" else "\u{25BE}", sec.label, sec.files.len });
        const label_chars = chars(label_text);
        const btn_chars = chars(sec.button);
        const padding = @max(w -| (label_chars + btn_chars), 1);
        var ls = Theme.withFg(bg, pal.fg);
        ls.bold = true;
        const active = sec.files.len > 0;
        var bs = if (active) Theme.onBg(Theme.withFg(bg, pal.bg_dark), sec.accent) else Theme.withFg(bg, pal.comment);
        bs.bold = active;
        if (active) hits.append(arena, .{ .line = lines.items.len, .x0 = label_chars + padding, .x1 = label_chars + padding + btn_chars, .id = wipButtonId(if (sec.staged) .unstage_all else .stage_all) }) catch return out;
        lines.append(arena, lineOf(arena, &.{
            .{ .text = label_text, .style = ls },
            .{ .text = padOrTruncate(arena, "", padding, ui.ascii) catch "", .style = bg },
            .{ .text = sec.button, .style = bs },
        }) catch return out) catch return out;
        const btn: []const u8 = if (sec.staged) " [\u{2212}] " else " [+] ";
        const btn_w = chars(btn);
        for (sec.files, 0..) |f, i| {
            const prefix = ui.fmt("    {c} ", .{f.letter});
            const prefix_chars = chars(prefix);
            const path_avail = @max(w -| (prefix_chars + btn_w + 1), 8);
            const color = switch (f.letter) {
                'M' => pal.yellow,
                '?' => pal.comment,
                '!' => pal.red,
                'A' => pal.green,
                'D' => pal.red,
                else => pal.fg,
            };
            var fbs = Theme.onBg(Theme.withFg(bg, pal.bg_dark), sec.accent);
            fbs.bold = true;
            hits.append(arena, .{ .line = lines.items.len, .x0 = 0, .x1 = prefix_chars + path_avail, .id = wipFileId(.{ .idx = @intCast(i), .staged = sec.staged, .button = false }) }) catch return out;
            hits.append(arena, .{ .line = lines.items.len, .x0 = prefix_chars + path_avail + 1, .x1 = prefix_chars + path_avail + 1 + btn_w, .id = wipFileId(.{ .idx = @intCast(i), .staged = sec.staged, .button = true }) }) catch return out;
            lines.append(arena, lineOf(arena, &.{
                .{ .text = prefix, .style = Theme.withFg(bg, color) },
                .{ .text = padOrTruncate(arena, f.path, path_avail, ui.ascii) catch "", .style = Theme.withFg(bg, pal.fg) },
                .{ .text = " ", .style = bg },
                .{ .text = btn, .style = fbs },
            }) catch return out) catch return out;
        }
        lines.append(arena, lineOf(arena, &.{}) catch return out) catch return out;
    }

    // The overflow: the last visible row says how many more.
    const files_max: usize = files_area.h;
    if (lines.items.len > files_max and files_max > 0) {
        const dropped = lines.items.len - files_max + 1;
        lines.shrinkRetainingCapacity(files_max - 1);
        lines.append(arena, lineOf(arena, &.{.{ .text = ui.fmt("  \u{2026} and {d} more", .{dropped}), .style = Theme.withFg(bg, pal.comment) }}) catch return out) catch return out;
    }
    for (lines.items, 0..) |l, i| {
        if (i >= files_area.h) break;
        const r = files_area.row(@intCast(i));
        var pen: Pen = .{ .ui = ui, .x = r.x, .y = r.y, .end = r.right() };
        for (l.segs) |s| pen.put(s.text, s.style);
    }
    // The hits, in paint order: a row's `[+]` sits over the row. A
    // button cut by the column's edge keeps its visible cells (Rust
    // drops the rect whole — a narrow column's Stage All is dead there).
    for (hits.items) |hh| {
        if (hh.line >= files_area.h or hh.line >= lines.items.len) continue;
        if (hh.x0 >= w) continue;
        const x1 = @min(hh.x1, w);
        const r = Rect.init(files_area.x + @as(u16, @intCast(hh.x0)), files_area.y + @as(u16, @intCast(hh.line)), @intCast(x1 - hh.x0), 1);
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hh.id } });
    }

    if (commit_h == 0) return out;
    return drawCommitSection(ui, pane, commit_area, wd);
}

/// The commit box: `▾ Commit · N file(s) staged`, the textarea, the
/// Commit / AI Message / Clear buttons, the hint.
fn drawCommitSection(ui: Ui, pane: PaneId, area: Rect, wd: WipDoc) WipPainted {
    const t = ui.theme;
    const pal = t.palette;
    const arena = ui.arena;
    const bg: Style = .{ .bg = pal.bg };
    var out: WipPainted = .{};
    ui.fill(area, bg);
    const staged_count = wd.staged.len;
    const h = area.h;
    const textarea_rows: u16 = @max(h -| @as(u16, if (h >= 5) 3 else 2), 1);
    const textarea_y = area.y + 1;
    const buttons_y = textarea_y + textarea_rows;
    const hint_y = buttons_y + 1;
    const header = if (staged_count == 0) ui.fmt("  {s} Commit  \u{B7} (nothing staged)", .{if (ui.ascii) "v" else "\u{25BE}"}) else ui.fmt("  {s} Commit  \u{B7} {d} file(s) staged", .{ if (ui.ascii) "v" else "\u{25BE}", staged_count });
    var hs = Theme.withFg(bg, pal.fg);
    hs.bold = true;
    _ = ui.putStr(area.x, area.y, area.w, padOrTruncate(arena, header, area.w, ui.ascii) catch "", hs);
    const pad_x: u16 = 2;
    const content_w = area.w -| pad_x * 2;
    if (content_w >= 4 and textarea_rows >= 1) {
        const ta = Rect.init(area.x + pad_x, textarea_y, content_w, textarea_rows);
        out.textarea = ta;
        out.caret = drawTextarea(ui, pane, ta, wd.commit);
        drawCommitButtons(ui, pane, Rect.init(area.x, buttons_y, area.w, 1), staged_count, wd.commit);
        if (h >= 5) {
            const hint: []const u8 = if (wd.commit.focused) "  Enter newline \u{B7} Esc unfocus \u{B7} Ctrl+Enter commit" else "  Click textarea to type \u{B7} c commit \u{B7} C AI message";
            _ = ui.putStr(area.x, hint_y, area.w, padOrTruncate(arena, hint, area.w, ui.ascii) catch "", Theme.withFg(bg, pal.comment));
        }
        return out;
    }
    drawCommitButtons(ui, pane, Rect.init(area.x, area.y + 1, area.w, 1), staged_count, wd.commit);
    return out;
}

/// Rust `layout_textarea_rows`: `(start, end)` byte ranges of the rows,
/// char-wrapped at `width`, split on `\n`; at least one row.
pub fn textareaRows(arena: Allocator, text: []const u8, width: usize) Allocator.Error![]const [2]usize {
    var rows: std.ArrayListUnmanaged([2]usize) = .empty;
    if (width == 0) {
        try rows.append(arena, .{ 0, text.len });
        return rows.items;
    }
    var row_start: usize = 0;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (text[i] == '\n') {
            try rows.append(arena, .{ row_start, i });
            row_start = i + 1;
            cols = 0;
            i += 1;
            continue;
        }
        if (cols >= width) {
            try rows.append(arena, .{ row_start, i });
            row_start = i;
            cols = 0;
        }
        cols += 1;
        i += n;
    }
    try rows.append(arena, .{ row_start, text.len });
    return rows.items;
}

/// The row and column (code points) of byte `cursor` in `rows`.
pub fn locateCursor(rows: []const [2]usize, text: []const u8, cursor: usize) struct { row: usize, col: usize } {
    var idx: usize = 0;
    for (rows, 0..) |r, i| {
        idx = i;
        if (cursor >= r[0] and cursor <= r[1]) break;
    }
    const start = rows[idx][0];
    return .{ .row = idx, .col = chars(text[start..@min(cursor, text.len)]) };
}

fn drawTextarea(ui: Ui, pane: PaneId, area: Rect, c: CommitDoc) ?Caret {
    const pal = ui.theme.palette;
    const arena = ui.arena;
    const bg: Style = .{ .bg = if (c.focused) pal.bg_dark else pal.bg2 };
    ui.fill(area, bg);
    ui.hit(area, .{ .script_hit = .{ .pane = pane, .id = wipButtonId(.textarea) } });
    const content_w: usize = area.w;
    if (content_w == 0 or area.h == 0) return null;
    const rows = textareaRows(arena, c.text, content_w) catch return null;
    const cur = locateCursor(rows, c.text, c.cursor);
    const visible_h: usize = area.h;
    const scroll = if (cur.row >= visible_h) cur.row + 1 - visible_h else 0;
    var vrow: usize = 0;
    while (vrow < visible_h) : (vrow += 1) {
        const actual = scroll + vrow;
        const line: []const u8 = if (actual < rows.len) c.text[rows[actual][0]..rows[actual][1]] else "";
        _ = ui.putStr(area.x, area.y + @as(u16, @intCast(vrow)), area.w, padOrTruncate(arena, line, content_w, ui.ascii) catch "", Theme.withFg(bg, pal.fg));
    }
    if (c.text.len == 0 and !c.focused) {
        const placeholder: []const u8 = if (c.ai_streaming) " (asking Claude for a commit message\u{2026}) " else " click here \u{B7} then type a commit message ";
        var ps = Theme.withFg(bg, pal.comment);
        ps.italic = true;
        _ = ui.putStr(area.x, area.y, area.w, padOrTruncate(arena, placeholder, content_w, ui.ascii) catch "", ps);
    }
    if (c.focused) {
        const visual_row = cur.row -| scroll;
        if (visual_row < visible_h and cur.col <= content_w) return .{ .x = area.x + @as(u16, @intCast(cur.col)), .y = area.y + @as(u16, @intCast(visual_row)) };
    }
    return null;
}

fn buttonStyle(base: Style, fg: Color, on_bg: Color, active: bool, off: Style) Style {
    if (!active) return off;
    var s = Theme.onBg(Theme.withFg(base, fg), on_bg);
    s.bold = true;
    return s;
}

fn drawCommitButtons(ui: Ui, pane: PaneId, area: Rect, staged_count: usize, c: CommitDoc) void {
    const pal = ui.theme.palette;
    const bg: Style = .{ .bg = pal.bg };
    ui.fill(area, bg);
    const blank = std.mem.trim(u8, c.text, " \t\r\n").len == 0;
    const commit_active = staged_count > 0 and !blank and !c.ai_streaming;
    const ai_active = staged_count > 0 and !c.ai_streaming;
    const clear_active = c.text.len > 0 and !c.ai_streaming;
    const off = Theme.onBg(Theme.withFg(bg, pal.comment), pal.bg2);
    const buttons = [_]struct { label: []const u8, style: Style, id: u32 }{
        .{ .label = " Commit ", .style = buttonStyle(bg, pal.bg_dark, pal.green, commit_active, off), .id = wipButtonId(.commit) },
        .{ .label = if (c.ai_streaming) " AI writing\u{2026} " else " AI Message ", .style = if (c.ai_streaming) buttonStyle(bg, pal.bg_dark, pal.yellow, true, off) else buttonStyle(bg, pal.bg_dark, pal.blue, ai_active, off), .id = wipButtonId(.ai_message) },
        .{ .label = " Clear ", .style = buttonStyle(bg, pal.bg_dark, pal.red, clear_active, off), .id = wipButtonId(.clear) },
    };
    var pen: Pen = .{ .ui = ui, .x = area.x, .y = area.y, .end = area.right() };
    pen.put("  ", bg);
    for (buttons, 0..) |b, i| {
        if (i > 0) pen.put("  ", bg);
        const x = pen.x;
        pen.put(b.label, b.style);
        ui.hit(Rect.init(x, area.y, @intCast(@min(chars(b.label), @as(usize, area.right() -| x))), 1), .{ .script_hit = .{ .pane = pane, .id = b.id } });
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn commit(hash: []const u8, parents: []const []const u8) parse.Commit {
    return .{ .hash = hash, .parents = parents, .author = "a", .time = 0, .refs = "", .subject = hash };
}

fn identity(arena: Allocator, n: usize) ![]u32 {
    const out = try arena.alloc(u32, n);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    return out;
}

test "layout: a linear chain stays in lane 0" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = [_]parse.Commit{ commit("c", &.{"b"}), commit("b", &.{"a"}), commit("a", &.{}) };
    const l = try layout(a.allocator(), &cs);
    for (l) |row| {
        try testing.expectEqual(@as(u16, 0), row.lane);
        try testing.expectEqual(@as(usize, 1), row.cells.len);
        try testing.expectEqual(Glyph.node, row.cells[0].g);
    }
}

test "layout: the fixture's merge — ●─╮ / ● │ / │ ● / ●─╯ — with the lane colours; a freed lane cools down before reuse" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // merge → (main work, feature work); both → init.
    const cs = [_]parse.Commit{ commit("m", &.{ "x", "f" }), commit("x", &.{"base"}), commit("f", &.{"base"}), commit("base", &.{}) };
    const l = try layout(a.allocator(), &cs);
    try testing.expectEqual(@as(usize, 2), l[0].cells.len);
    try testing.expectEqual(Glyph.node, l[0].cells[0].g);
    try testing.expectEqual(Glyph.tr, l[0].cells[1].g);
    try testing.expectEqual(@as(u8, 1), l[0].cells[1].color);
    try testing.expectEqual(Glyph.node, l[1].cells[0].g);
    try testing.expectEqual(Glyph.pass, l[1].cells[1].g);
    try testing.expectEqual(Glyph.pass, l[2].cells[0].g);
    try testing.expectEqual(Glyph.node, l[2].cells[1].g);
    try testing.expectEqual(@as(u16, 1), l[2].lane);
    try testing.expectEqual(Glyph.node, l[3].cells[0].g);
    try testing.expectEqual(Glyph.br, l[3].cells[1].g);
    try testing.expectEqualStrings("\u{256E}", Glyph.tr.text(false));
    try testing.expectEqualStrings("\u{256F}", Glyph.br.text(false));
    try testing.expectEqualStrings("\\", Glyph.tr.text(true));
    // A branch opened right after lane 1 was freed takes a new lane 3,
    // not the cooling lane 1 (lane 2 is still live, so nothing trims).
    const cs2 = [_]parse.Commit{ commit("m", &.{ "x", "f", "y" }), commit("f", &.{}), commit("x", &.{ "x2", "h" }), commit("y", &.{}), commit("x2", &.{}), commit("h", &.{}) };
    const l2 = try layout(a.allocator(), &cs2);
    try testing.expectEqual(@as(usize, 4), l2[2].cells.len);
    try testing.expectEqual(Glyph.node, l2[2].cells[0].g);
    try testing.expectEqual(Glyph.horiz, l2[2].cells[1].g);
    try testing.expectEqual(Glyph.cross, l2[2].cells[2].g);
    try testing.expectEqual(Glyph.tr, l2[2].cells[3].g);
}

test "the spec's rows at 95 wide: the toolbar, the column header, the WIP row, the merge row with the date and the nine-char sha, the divider and the detail column" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{
        .{ .hash = "7ce273514abc", .parents = &.{ "34b03ced4abc", "3ec2bf9e8abc" }, .author = "Chris", .time = 1757188800, .refs = "HEAD -> main", .subject = "merge feature" },
        .{ .hash = "34b03ced4abc", .parents = &.{"482589dd2abc"}, .author = "Chris", .time = 1757188800, .refs = "", .subject = "main work" },
        .{ .hash = "3ec2bf9e8abc", .parents = &.{"482589dd2abc"}, .author = "Chris", .time = 1757188800, .refs = "feature", .subject = "feature work" },
        .{ .hash = "482589dd2abc", .parents = &.{}, .author = "Chris", .time = 1757130900, .refs = "", .subject = "init" },
    };
    const l = try layout(arena, &cs);
    var f = try Fixture.init(95, 37);
    defer f.deinit();
    var st: State = .{};
    const files = [_]WipFile{.{ .path = ".gitignore", .letter = '?' }};
    const p = draw(f.ui(), 1, f.full(), &st, .{
        .commits = &cs,
        .lanes = l,
        .order = try identity(arena, 4),
        .cursor = 0,
        .focused = true,
        .now = 1757260800,
        // The pins are +0000 instants: the column follows the clock's
        // zone, so the test asks for UTC as git_graph_dates.test does.
        .utc = true,
        .has_wip = true,
        .wip = .{ .branch = "main", .summary = "1 change(s) \u{B7} 1 new", .unstaged = &files },
    });
    try f.expectRow(0, try std.fmt.allocPrint(arena, "    {s} Undo   {s} Redo   {s} Pull   {s} Push   {s} Fetch   {s} Branch   {s} Commit   {s} Stash   {s} Reflog", .{ git_toolbar.glyphOf(.undo), git_toolbar.glyphOf(.redo), git_toolbar.glyphOf(.pull), git_toolbar.glyphOf(.push), git_toolbar.glyphOf(.fetch), git_toolbar.glyphOf(.branch), git_toolbar.glyphOf(.commit), git_toolbar.glyphOf(.stash), git_toolbar.glyphOf(.reflog) }));
    try f.expectRow(1, "     G\u{2026} \u{2502} COMMIT MESSAGE          \u{2502} DATE / TIME   \u{2502}     SHA    \u{2502}\u{2500} WIP @ main \u{B7} 1 change(s) \u{B7} 1");
    try f.expectRow(2, "\u{258C}\u{25B6}       \u{2502} 1 change(s) \u{B7} 1 new    \u{2502}               \u{2502}            \u{2502}");
    // No BRANCH / TAG column at 95: the refs lead the subject (Rust
    // painted none at this width, and a graph that names no ref cannot
    // say where anything is).
    try f.expectRow(3, "\u{258C}    \u{25CF}\u{2500}\u{256E} \u{2502} HEAD main merge featu\u{2026} \u{2502}   09/06 20:00 \u{2502} 7ce273514  \u{2502}  \u{25BE} Unstaged Files (1)  Stage A");
    try f.expectRow(4, "\u{258C}    \u{25CF} \u{2502} \u{2502} main work              \u{2502}   09/06 20:00 \u{2502} 34b03ced4  \u{2502}    ? .gitignore           [+]");
    try f.expectRow(5, "\u{258C}    \u{2502} \u{25CF} \u{2502} feature feature work   \u{2502}   09/06 20:00 \u{2502} 3ec2bf9e8  \u{2502}");
    try f.expectRow(6, "\u{258C}    \u{25CF}\u{2500}\u{256F} \u{2502} init                   \u{2502}   09/06 03:55 \u{2502} 482589dd2  \u{2502}  \u{25BE} Staged Files (0)  Unstage A");
    try f.expectRow(27, "                                                               \u{2502}  \u{25BE} Commit  \u{B7} (nothing staged)");
    try f.expectRow(28, "                                                               \u{2502}   click here \u{B7} then type a \u{2026}");
    try f.expectRow(35, "                                                               \u{2502}   Commit    AI Message    Clea");
    try f.expectRow(36, "                                                               \u{2502}  Click textarea to type \u{B7} c c\u{2026}");
    try testing.expect(p.detail.eql(Rect.init(64, 1, 31, 36)));
    try testing.expect(p.textarea.eql(Rect.init(66, 28, 27, 7)));
    // The hits: the rows by index, the sort columns, the divider, the
    // file row and its [+], the textarea and the three buttons.
    try testing.expectEqual(@as(u32, 0), f.hits.at(10, 2).?.script_hit.id);
    try testing.expectEqual(@as(u32, 1), f.hits.at(10, 3).?.script_hit.id);
    try testing.expectEqual(sortId(.date), f.hits.at(40, 1).?.script_hit.id);
    try testing.expectEqual(sortId(.sha), f.hits.at(58, 1).?.script_hit.id);
    try testing.expectEqual(divider_id, f.hits.at(63, 10).?.script_hit.id);
    try testing.expectEqual(wipButtonId(.stage_all), f.hits.at(90, 3).?.script_hit.id);
    try testing.expectEqual(WipFileHit{ .idx = 0, .staged = false, .button = false }, wipFileOf(f.hits.at(70, 4).?.script_hit.id).?);
    try testing.expectEqual(WipFileHit{ .idx = 0, .staged = false, .button = true }, wipFileOf(f.hits.at(92, 4).?.script_hit.id).?);
    try testing.expectEqual(wipButtonId(.textarea), f.hits.at(70, 29).?.script_hit.id);
    try testing.expectEqual(wipButtonId(.commit), f.hits.at(68, 35).?.script_hit.id);
    try testing.expectEqual(wipButtonId(.ai_message), f.hits.at(80, 35).?.script_hit.id);
    try testing.expectEqual(wipButtonId(.clear), f.hits.at(92, 35).?.script_hit.id);
    // Unstage All is inert with nothing staged.
    try testing.expect(f.hits.at(90, 6) == null or f.hits.at(90, 6).?.script_hit.id != wipButtonId(.unstage_all));
    // The lane colours: lane 0 blue, lane 1 green; the sha orange.
    try testing.expect(f.fgEql(5, 3, .{ .fg = f.theme.palette.blue }));
    try testing.expect(f.fgEql(7, 3, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(52, 3, .{ .fg = f.theme.palette.orange }));
    try testing.expect(f.bgEql(10, 2, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(10, 3, .{ .bg = f.theme.palette.bg_dark }));
}

/// Reuses the stack the frame just left: a slice a painter kept into
/// its own frame reads as this junk afterwards.
noinline fn clobberStack() void {
    var junk: [64 * 1024]u8 = undefined;
    @memset(&junk, 0xFF);
    std.mem.doNotOptimizeAway(&junk);
}

test "the date column at the walk's pane widths — 96 cells (120 columns) and 56 (80 columns) — is the 11-cell form, and every date paints whole after the frame's stack is reused: no U+FFFD" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{
        .{ .hash = "7ce273514abc", .parents = &.{"34b03ced4abc"}, .author = "Chris", .time = 1757188800, .refs = "", .subject = "merge feature" },
        .{ .hash = "34b03ced4abc", .parents = &.{}, .author = "Chris", .time = 1757130900, .refs = "", .subject = "init" },
    };
    // At 96 the detail column takes a third; eight lane cells leave the
    // list exactly the room the walk's merge-heavy graph did. At 56
    // there is no detail column and a linear history lands there.
    const widths = [_]struct { w: u16, lanes: usize }{ .{ .w = 96, .lanes = 8 }, .{ .w = 56, .lanes = 1 } };
    for (widths) |case| {
        const cells = try arena.alloc(LaneCell, case.lanes);
        @memset(cells, .{ .g = .node });
        const lanes = [_]Lane{ .{ .lane = 0, .cells = cells }, .{ .lane = 0, .cells = cells } };
        var f = try Fixture.init(case.w, 12);
        defer f.deinit();
        var st: State = .{};
        _ = draw(f.ui(), 1, f.full(), &st, .{ .commits = &cs, .lanes = &lanes, .order = try identity(arena, 2), .cursor = 0, .focused = true, .now = 1757260800, .utc = true });
        clobberStack();
        var buf: [1024]u8 = undefined;
        const header = try arena.dupe(u8, f.row(1, &buf));
        // The precondition: the 11-cell column, its header cut from the left.
        try testing.expect(std.mem.indexOf(u8, header, "\u{2026}E / TIME") != null);
        const r2 = try arena.dupe(u8, f.row(2, &buf));
        const r3 = try arena.dupe(u8, f.row(3, &buf));
        try testing.expect(std.unicode.utf8ValidateSlice(r2));
        try testing.expect(std.unicode.utf8ValidateSlice(r3));
        try testing.expect(std.mem.indexOf(u8, r2, "\u{FFFD}") == null);
        try testing.expect(std.mem.indexOf(u8, r2, "09/06 20:00") != null);
        try testing.expect(std.mem.indexOf(u8, r3, "09/06 03:55") != null);
    }
}

test "the detail column's width: the drag override wins, then the config, else a third clamped to 28..60; under 80 there is none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{commit("aaaaaaaaaa", &.{})};
    const l = try layout(arena, &cs);
    var st: State = .{};
    const widths = [_]struct { w: u16, override: ?u16, want: u16 }{
        .{ .w = 95, .override = null, .want = 31 },
        .{ .w = 200, .override = null, .want = 60 },
        .{ .w = 80, .override = null, .want = 28 },
        .{ .w = 95, .override = 40, .want = 40 },
        .{ .w = 95, .override = 10, .want = 20 },
        .{ .w = 95, .override = 90, .want = 55 },
        .{ .w = 79, .override = 40, .want = 0 },
    };
    for (widths) |w| {
        var f = try Fixture.init(w.w, 20);
        defer f.deinit();
        const p = draw(f.ui(), 1, f.full(), &st, .{ .commits = &cs, .lanes = l, .order = try identity(arena, 1), .cursor = 0, .focused = true, .now = 0, .detail_w = w.override, .detail = .{ .short = "aaaaaaaaa", .author = "a", .age = "now", .message = "aaaaaaaaaa" } });
        try testing.expectEqual(w.want, p.detail.w);
    }
}

test "sortOrder: none keeps git's order; date newest first (asc flips); author and sha A–Z ignoring case; the header's arrow follows" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const three = [_]parse.Commit{
        .{ .hash = "c1", .parents = &.{}, .author = "zed", .time = 30, .refs = "", .subject = "beta" },
        .{ .hash = "b2", .parents = &.{}, .author = "Amy", .time = 10, .refs = "", .subject = "alpha" },
        .{ .hash = "a3", .parents = &.{}, .author = "mia", .time = 20, .refs = "", .subject = "Gamma" },
    };
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, try sortOrder(arena, &three, .{}));
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, try sortOrder(arena, &three, .{ .col = .date }));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, try sortOrder(arena, &three, .{ .col = .date, .asc = true }));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, try sortOrder(arena, &three, .{ .col = .author, .asc = true }));
    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, try sortOrder(arena, &three, .{ .col = .sha, .asc = true }));
    try testing.expectEqual(@as(?usize, 2), findByHashPrefix(&three, "A3"));
    try testing.expectEqual(@as(?usize, null), findByHashPrefix(&three, ""));
    const l = try layout(arena, &three);
    var f = try Fixture.init(70, 6);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 1, f.full(), &st, .{ .commits = &three, .lanes = l, .order = try sortOrder(arena, &three, .{ .col = .date }), .cursor = 0, .focused = true, .now = 0, .sort = .{ .col = .date } });
    try f.expectContains("DATE / TIME \u{25BC}");
    try f.expectContains("beta");
    try testing.expect(f.hits.at(3, 2).?.script_hit.id == 0);
}

test "helpers: padOrTruncate and rightAlign by code points, the UTC date, the ages, the chips from a refs line, the columns, the textarea rows" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("ab   ", try padOrTruncate(arena, "ab", 5, false));
    try testing.expectEqualStrings("abcd\u{2026}", try padOrTruncate(arena, "abcdefg", 5, false));
    try testing.expectEqualStrings("\u{2026}", try padOrTruncate(arena, "abc", 1, false));
    try testing.expectEqualStrings("   ab", try rightAlign(arena, "ab", 5, false));
    try testing.expectEqualStrings("\u{2026}defg", try rightAlign(arena, "abcdefg", 5, false));
    try testing.expectEqualStrings("\u{B7}\u{B7}  ", try padOrTruncate(arena, "\u{B7}\u{B7}", 4, false));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("09/06 20:00", commitDateTime(&buf, 1757188800, 0));
    try testing.expectEqualStrings("09/06 22:00", commitDateTime(&buf, 1757188800, 2 * 3600));
    try testing.expectEqualStrings("09/06 16:00", commitDateTime(&buf, 1757188800, -4 * 3600));
    try testing.expectEqualStrings("01/01 00:00", commitDateTime(&buf, 0, 0));
    try testing.expectEqualStrings("now", humanizeAge(&buf, 5));
    try testing.expectEqualStrings("3m", humanizeAge(&buf, 200));
    try testing.expectEqualStrings("5h", humanizeAge(&buf, 5 * 3600));
    try testing.expectEqualStrings("2d", humanizeAge(&buf, 2 * 86400));
    try testing.expectEqualStrings("3w", humanizeAge(&buf, 21 * 86400));
    try testing.expectEqualStrings("4mo", humanizeAge(&buf, 130 * 86400));
    try testing.expectEqualStrings("2y", humanizeAge(&buf, 800 * 86400));
    const labels = try refLabels(arena, "HEAD -> main, origin/main, tag: v1, feature, origin/HEAD");
    try testing.expectEqual(@as(usize, 5), labels.len);
    try testing.expectEqual(RefKind.head, labels[0].kind);
    try testing.expectEqualStrings("feature", labels[1].name);
    try testing.expectEqualStrings("main", labels[2].name);
    try testing.expectEqual(RefKind.remote, labels[3].kind);
    try testing.expectEqual(RefKind.tag, labels[4].kind);
    try testing.expectEqual(@as(usize, 4 + 1 + 7 + 1 + 4 + 1 + 11 + 1 + 3), chipWidth(labels));
    const rows = try textareaRows(arena, "hello world\nab", 5);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual([2]usize{ 0, 5 }, rows[0]);
    try testing.expectEqual([2]usize{ 5, 10 }, rows[1]);
    try testing.expectEqual([2]usize{ 10, 11 }, rows[2]);
    try testing.expectEqual([2]usize{ 12, 14 }, rows[3]);
    const c = locateCursor(rows, "hello world\nab", 13);
    try testing.expectEqual(@as(usize, 3), c.row);
    try testing.expectEqual(@as(usize, 1), c.col);
    const cols = computeColumnWidths(61, 2, .{ .branch_chars = 12, .author_chars = 14, .branch_override = null, .author_override = null });
    try testing.expectEqual(@as(usize, 9), cols.sha);
    try testing.expectEqual(@as(usize, 13), cols.age);
    try testing.expectEqual(@as(usize, 0), cols.author);
    try testing.expectEqual(@as(usize, 0), cols.branch);
    const wide = computeColumnWidths(150, 2, .{ .branch_chars = 12, .author_chars = 14, .branch_override = null, .author_override = null });
    try testing.expectEqual(@as(usize, 14), wide.author);
    try testing.expectEqual(@as(usize, 12), wide.branch);
    // A long author and branch on a wide pane: past their 22 / 24 caps
    // to what they need, while a short subject leaves room; a width
    // set by hand stays; a narrow pane is cut as before.
    const long = computeColumnWidths(220, 2, .{ .branch_chars = 40, .author_chars = 30, .branch_override = null, .author_override = null, .subject_chars = 30 });
    try testing.expectEqual(@as(usize, 30), long.author);
    try testing.expectEqual(@as(usize, 40), long.branch);
    const pinned = computeColumnWidths(220, 2, .{ .branch_chars = 40, .author_chars = 30, .branch_override = null, .author_override = 16, .subject_chars = 30 });
    try testing.expectEqual(@as(usize, 16), pinned.author);
    const tight = computeColumnWidths(108, 2, .{ .branch_chars = 40, .author_chars = 30, .branch_override = null, .author_override = null, .subject_chars = 0 });
    try testing.expectEqual(@as(usize, 22), tight.author);
    try testing.expectEqual(@as(usize, 7), revealScroll(10, 0, 10, true));
    try testing.expectEqual(@as(usize, 1), revealScroll(10, 0, 10, false));
    try testing.expectEqual(@as(usize, 0), revealScroll(3, 0, 10, true));
}

test "a commit's detail: the header rule, the reflowed message wrapped to the width, the parents, the file rows with hits; a focused commit box returns the caret" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{commit("aaaaaaaaaa", &.{})};
    const l = try layout(arena, &cs);
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    var st: State = .{};
    const files = [_]parse.DetailFile{ .{ .status = 'M', .path = "src/a.zig" }, .{ .status = 'A', .path = "new.txt" } };
    const p = draw(f.ui(), 1, f.full(), &st, .{
        .commits = &cs,
        .lanes = l,
        .order = try identity(arena, 1),
        .cursor = 0,
        .focused = true,
        .now = 0,
        .detail = .{ .short = "aaaaaaaaa", .author = "amy", .age = "2d", .message = "Subject line\n\nA body that is long\nenough to wrap inside the panel.\n\n    code kept\n- item", .parents = &.{ "bbbbbbbbbbbb", "cccccccccccc" }, .files = &files },
    });
    try testing.expectEqual(@as(u16, 33), p.detail.w);
    const x = p.detail.x;
    try f.expectContains("\u{2500} aaaaaaaaa \u{B7} amy \u{B7} 2d \u{2500}");
    try f.expectContains("  Subject line");
    try f.expectContains("  A body that is long enough to");
    try f.expectContains("      code kept");
    try f.expectContains("  - item");
    try f.expectContains("  parents: bbbbbbbbb  cccccccc");
    try f.expectContains("  changed files (2):");
    try f.expectContains("  M src/a.zig");
    try f.expectContains("  A new.txt");
    var found: ?u32 = null;
    var y: u16 = 0;
    while (y < 20) : (y += 1) if (f.hits.at(x + 3, y)) |h| if (h == .script_hit) if (detailRowOf(h.script_hit.id)) |i| if (i == 1) {
        found = i;
    };
    try testing.expectEqual(@as(?u32, 1), found);
    // The commit box with the focus: the caret after the text.
    var g = try Fixture.init(100, 20);
    defer g.deinit();
    const q = draw(g.ui(), 1, g.full(), &st, .{
        .commits = &cs,
        .lanes = l,
        .order = try identity(arena, 1),
        .cursor = 0,
        .focused = true,
        .now = 0,
        .has_wip = true,
        .wip = .{ .branch = "main", .summary = "working tree clean", .commit = .{ .text = "fix: it", .cursor = 7, .focused = true } },
    });
    try testing.expectEqual(Caret{ .x = q.textarea.x + 7, .y = q.textarea.y }, q.caret.?);
    try g.expectContains("  Enter newline \u{B7} Esc unfocus \u{B7} \u{2026}");
}

test "a commit's message links its ticket key and PR ref: `.link` hits over their cells, none on the file rows" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{commit("aaaaaaaaaa", &.{})};
    const l = try layout(arena, &cs);
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    var ui = f.ui();
    ui.links = link_span.TestKeys.finder();
    var st: State = .{};
    const files = [_]parse.DetailFile{.{ .status = 'M', .path = "ENG-9.txt" }};
    _ = draw(ui, 1, f.full(), &st, .{
        .commits = &cs,
        .lanes = l,
        .order = try identity(arena, 1),
        .cursor = 0,
        .focused = true,
        .now = 0,
        .detail = .{ .short = "aaaaaaaaa", .author = "amy", .age = "2d", .message = "ENG-123: merge widget#42", .parents = &.{}, .files = &files },
    });
    var buf: [512]u8 = undefined;
    var key: ?[2]u16 = null;
    var pr: ?[2]u16 = null;
    var file: ?[2]u16 = null;
    var y: u16 = 0;
    while (y < 20) : (y += 1) {
        const row = f.row(y, &buf);
        if (std.mem.indexOf(u8, row, "ENG-123:")) |i| key = .{ @intCast(try std.unicode.utf8CountCodepoints(row[0..i])), y };
        if (std.mem.indexOf(u8, row, "widget#42")) |i| pr = .{ @intCast(try std.unicode.utf8CountCodepoints(row[0..i])), y };
        if (std.mem.indexOf(u8, row, "ENG-9.txt")) |i| file = .{ @intCast(try std.unicode.utf8CountCodepoints(row[0..i])), y };
    }
    try testing.expectEqualStrings(link_span.TestKeys.key_url, f.hits.at(key.?[0] + 6, key.?[1]).?.link.url);
    try testing.expectEqualStrings(link_span.TestKeys.pr_url, f.hits.at(pr.?[0], pr.?[1]).?.link.url);
    try testing.expect(f.hits.at(file.?[0], file.?[1]).? != .link);
}
