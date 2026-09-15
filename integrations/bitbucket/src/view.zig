//! What the pane looks like, as data. Every surface — the tab strip,
//! the list, the detail, the confirm, the prompt, the footer — is built
//! as a `[]Line` first and painted second, so a test asserts on the
//! text a user would read instead of on cell coordinates, and the
//! scroll is one integer rather than a second layout.
//!
//! Two layout rules earn their keep:
//!
//! * **Columns are dropped, not squeezed.** A pane 40 columns wide gets
//!   `PR · STATE · TITLE` and nothing else; the REPO, AUTHOR, BRANCH
//!   and UPDATED columns leave one at a time as the width allows.
//!   There is a test at 40, 80, 120 and 200 — the three the corpus runs
//!   plus the narrow one — because a layout that is only ever checked
//!   at the wide end ships broken at the narrow one.
//! * **The detail is one scrollable column.** Splitting it further at
//!   45% of an 80-column pane leaves 36 columns for a diff, which is
//!   not a diff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const model = @import("model.zig");
const j = @import("json.zig");
const links = @import("links.zig");

pub const Tone = enum {
    normal,
    dim,
    bold,
    accent,
    good,
    bad,
    warn,
    /// A section heading inside the detail.
    section,
    /// The column header of the list.
    header,

    pub fn style(tone: Tone) sdk.Style {
        return switch (tone) {
            .normal => .{},
            .dim => .{ .mods = .{ .dim = true } },
            .bold => .{ .mods = .{ .bold = true } },
            .accent => .{ .fg = .{ .index = 6 }, .mods = .{ .bold = true } },
            .good => .{ .fg = .{ .index = 2 } },
            .bad => .{ .fg = .{ .index = 1 } },
            .warn => .{ .fg = .{ .index = 3 } },
            .section => .{ .fg = .{ .index = 5 }, .mods = .{ .bold = true } },
            .header => .{ .fg = .{ .index = 8 }, .mods = .{ .bold = true } },
        };
    }
};

pub const Line = struct {
    text: []const u8,
    tone: Tone = .normal,
};

// ─── the list ────────────────────────────────────────────────────────────

/// Which optional columns fit. The required three — PR, STATE, TITLE —
/// are never dropped.
pub const Columns = struct {
    repo: bool,
    author: bool,
    branches: bool,
    updated: bool,
    votes: bool,
    build: bool,

    pub const repo_w: u16 = 18;
    pub const id_w: u16 = 7;
    pub const state_w: u16 = 9;
    pub const author_w: u16 = 14;
    pub const branch_w: u16 = 26;
    pub const updated_w: u16 = 11;
    pub const votes_w: u16 = 7;
    pub const build_w: u16 = 2;
    /// Below this a title is not worth the columns it costs.
    pub const min_title_w: u16 = 12;

    /// Drop the widest optional column until what is left fits, in the
    /// order a reviewer misses them least.
    pub fn fit(cols: u16, want_repo: bool) Columns {
        var c: Columns = .{ .repo = want_repo, .author = true, .branches = true, .updated = true, .votes = true, .build = true };
        // Dropped in this order; the last two are one character each
        // and carry the review state, so they go last of all.
        const order = [_]*bool{ &c.branches, &c.repo, &c.author, &c.updated, &c.build, &c.votes };
        for (order) |flag| {
            if (c.width() + min_title_w <= cols) break;
            flag.* = false;
        }
        return c;
    }

    /// Everything but the title.
    pub fn width(c: Columns) u16 {
        var w: u16 = id_w + state_w;
        if (c.repo) w += repo_w;
        if (c.author) w += author_w;
        if (c.branches) w += branch_w;
        if (c.updated) w += updated_w;
        if (c.votes) w += votes_w;
        if (c.build) w += build_w;
        return w;
    }
};

pub const Row = struct {
    pr: model.Pr,
    /// The best build status on the PR's source commit, if one is known.
    build: ?model.BuildStatus = null,
};

pub const ListCtx = struct {
    rows: []const Row,
    selected: usize = 0,
    cols: u16 = 80,
    /// A per-repo tab already says which repo it is.
    show_repo: bool = true,
    /// "" when `/2.0/user` has not been resolved.
    me_account_id: []const u8 = "",
    /// Painted instead of the rows when there are none.
    empty_message: []const u8 = "No pull requests.",
};

/// The header line plus one line per row. Allocated on `arena`.
pub fn listLines(arena: Allocator, ctx: ListCtx) Allocator.Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    const c = Columns.fit(ctx.cols, ctx.show_repo);
    const title_w = ctx.cols -| c.width() -| 1;

    var head: std.Io.Writer.Allocating = .init(arena);
    const hw = &head.writer;
    if (c.repo) try pad(hw, "REPO", Columns.repo_w);
    try pad(hw, "PR", Columns.id_w);
    try pad(hw, "STATE", Columns.state_w);
    if (c.author) try pad(hw, "AUTHOR", Columns.author_w);
    if (c.branches) try pad(hw, "BRANCH → DEST", Columns.branch_w);
    if (c.updated) try pad(hw, "UPDATED", Columns.updated_w);
    if (c.votes) try pad(hw, "VOTES", Columns.votes_w);
    if (c.build) try pad(hw, "B", Columns.build_w);
    try pad(hw, "TITLE", title_w);
    try out.append(arena, .{ .text = trimEndSpaces(head.written()), .tone = .header });

    if (ctx.rows.len == 0) {
        try out.append(arena, .{ .text = "", .tone = .dim });
        try out.append(arena, .{ .text = ctx.empty_message, .tone = .dim });
        return out.toOwnedSlice(arena);
    }

    for (ctx.rows) |row| {
        const pr = row.pr;
        var line: std.Io.Writer.Allocating = .init(arena);
        const w = &line.writer;
        if (c.repo) try pad(w, pr.repo(), Columns.repo_w);
        var idbuf: [16]u8 = undefined;
        try pad(w, std.fmt.bufPrint(&idbuf, "#{d}", .{pr.id}) catch "#?", Columns.id_w);
        try pad(w, stateLabel(pr), Columns.state_w);
        if (c.author) try pad(w, dashIfEmpty(pr.author), Columns.author_w);
        if (c.branches) {
            var bbuf: [128]u8 = undefined;
            const both = std.fmt.bufPrint(&bbuf, "{s} → {s}", .{ dashIfEmpty(pr.source_branch), dashIfEmpty(pr.dest_branch) }) catch "?";
            try pad(w, both, Columns.branch_w);
        }
        if (c.updated) try pad(w, pr.updatedDate(), Columns.updated_w);
        if (c.votes) {
            var vbuf: [16]u8 = undefined;
            const votes = std.fmt.bufPrint(&vbuf, "✓{d} ✗{d}", .{ pr.approvals(), pr.changesRequested() }) catch "";
            try pad(w, votes, Columns.votes_w);
        }
        if (c.build) try pad(w, if (row.build) |b| b.glyph() else " ", Columns.build_w);
        try pad(w, pr.title, title_w);
        try out.append(arena, .{ .text = trimEndSpaces(line.written()), .tone = rowTone(pr, ctx.me_account_id) });
    }
    return out.toOwnedSlice(arena);
}

fn stateLabel(pr: model.Pr) []const u8 {
    if (pr.draft) return "DRAFT";
    return if (pr.state.len > 0) pr.state else "?";
}

fn rowTone(pr: model.Pr, me: []const u8) Tone {
    if (pr.draft) return .dim;
    if (std.mem.eql(u8, pr.state, "MERGED")) return .dim;
    if (std.mem.eql(u8, pr.state, "DECLINED")) return .dim;
    return switch (pr.voteOf(me)) {
        .approved => .good,
        .changes_requested => .warn,
        .none => .normal,
    };
}

// ─── the detail ──────────────────────────────────────────────────────────

pub const DetailCtx = struct {
    pr: model.Pr,
    workspace: []const u8 = "",
    repo: []const u8 = "",
    reviewers: []const model.Participant = &.{},
    builds: []const model.BuildStatus = &.{},
    files: []const model.DiffstatEntry = &.{},
    /// The raw unified diff; empty until it is fetched.
    diff: []const u8 = "",
    activity: []const model.Activity = &.{},
    jira_keys: []const links.Key = &.{},
    me_account_id: []const u8 = "",
    cols: u16 = 80,
    /// `D` folds the diff away — it is the longest section by far.
    show_diff: bool = true,
    /// What is still being fetched, painted in place of the section.
    loading: bool = false,
};

pub fn detailLines(arena: Allocator, ctx: DetailCtx) Allocator.Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    const pr = ctx.pr;

    try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s}/{s}#{d}", .{ ctx.workspace, ctx.repo, pr.id }), .tone = .accent });
    try out.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "{s} · {s} → {s}", .{ stateLabel(pr), dashIfEmpty(pr.source_branch), dashIfEmpty(pr.dest_branch) }),
        .tone = if (std.mem.eql(u8, pr.state, "OPEN")) .good else .dim,
    });
    try out.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "author: {s} · updated: {s}", .{ dashIfEmpty(pr.author), pr.updatedDate() }),
        .tone = .dim,
    });
    const mine = pr.voteOf(ctx.me_account_id);
    try out.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "{s} you: {s} · ✓{d} approved · ✗{d} changes requested", .{
            mine.glyph(), mine.label(), pr.approvals(), pr.changesRequested(),
        }),
        .tone = switch (mine) {
            .approved => .good,
            .changes_requested => .warn,
            .none => .dim,
        },
    });
    try out.append(arena, .{ .text = "" });
    try out.append(arena, .{ .text = pr.title, .tone = .bold });
    try out.append(arena, .{ .text = "" });

    if (ctx.jira_keys.len > 0) {
        var keys: std.Io.Writer.Allocating = .init(arena);
        keys.writer.writeAll("issues: ") catch return error.OutOfMemory;
        for (ctx.jira_keys, 0..) |k, i| {
            if (i > 0) keys.writer.writeAll("  ") catch return error.OutOfMemory;
            keys.writer.print("[{d}] {s}", .{ i + 1, k.text }) catch return error.OutOfMemory;
        }
        try out.append(arena, .{ .text = keys.written(), .tone = .accent });
        try out.append(arena, .{ .text = "" });
    }

    if (std.mem.trim(u8, pr.description, " \t\r\n").len > 0) {
        try wrapInto(arena, &out, pr.description, ctx.cols, 0, .normal);
    } else {
        try out.append(arena, .{ .text = "(no description)", .tone = .dim });
    }
    try out.append(arena, .{ .text = "" });

    try out.append(arena, .{ .text = "reviewers", .tone = .section });
    if (ctx.reviewers.len == 0) {
        try out.append(arena, .{ .text = "  (none)", .tone = .dim });
    } else for (ctx.reviewers) |r| {
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "  {s} {s}  {s}", .{ r.approval.glyph(), dashIfEmpty(r.display_name), r.approval.label() }),
            .tone = switch (r.approval) {
                .approved => .good,
                .changes_requested => .warn,
                .none => .dim,
            },
        });
    }
    try out.append(arena, .{ .text = "" });

    try out.append(arena, .{ .text = "builds", .tone = .section });
    if (ctx.builds.len == 0) {
        try out.append(arena, .{ .text = if (ctx.loading) "  loading…" else "  (none reported)", .tone = .dim });
    } else for (ctx.builds) |b| {
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "  {s} {s}  {s}", .{ b.glyph(), dashIfEmpty(b.name), b.state }),
            .tone = if (std.ascii.eqlIgnoreCase(b.state, "FAILED")) .bad else if (std.ascii.eqlIgnoreCase(b.state, "SUCCESSFUL")) .good else .warn,
        });
    }
    try out.append(arena, .{ .text = "" });

    var added: i64 = 0;
    var removed: i64 = 0;
    for (ctx.files) |f| {
        added += f.added;
        removed += f.removed;
    }
    try out.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "files ({d})  +{d}  -{d}", .{ ctx.files.len, added, removed }),
        .tone = .section,
    });
    if (ctx.files.len == 0) {
        try out.append(arena, .{ .text = if (ctx.loading) "  loading…" else "  (no diffstat)", .tone = .dim });
    } else for (ctx.files) |f| {
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "  {s} {s}  +{d} -{d}", .{ f.glyph(), f.path, f.added, f.removed }),
            .tone = .normal,
        });
    }
    try out.append(arena, .{ .text = "" });

    if (ctx.show_diff) {
        try out.append(arena, .{ .text = "diff", .tone = .section });
        if (ctx.diff.len == 0) {
            try out.append(arena, .{ .text = if (ctx.loading) "  loading…" else "  (no diff)", .tone = .dim });
        } else try diffInto(arena, &out, ctx.diff, ctx.cols);
        try out.append(arena, .{ .text = "" });
    } else {
        try out.append(arena, .{ .text = "diff  (hidden — D shows it)", .tone = .section });
        try out.append(arena, .{ .text = "" });
    }

    try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "activity ({d})", .{ctx.activity.len}), .tone = .section });
    if (ctx.activity.len == 0) {
        try out.append(arena, .{ .text = if (ctx.loading) "  loading…" else "  (nothing yet)", .tone = .dim });
    } else try activityInto(arena, &out, ctx.activity, ctx.cols);

    // Nothing leaves this function wider than the pane. The header
    // lines are printed, not wrapped, and "✗0 changes requested" is
    // longer than a 40-column pane — so the cut is applied once, here,
    // rather than remembered at eleven call sites.
    for (out.items) |*line| {
        if (countCells(line.text) > ctx.cols) line.text = try cut(arena, line.text, ctx.cols, "");
    }
    return out.toOwnedSlice(arena);
}

/// The activity stream: a top-level comment at one indent, a reply to
/// it at two, an inline comment carrying the file and line it hangs
/// off. Replies follow their parent rather than their timestamp —
/// a thread read out of order is not a thread.
fn activityInto(arena: Allocator, out: *std.ArrayList(Line), items: []const model.Activity, cols: u16) Allocator.Error!void {
    for (items) |a| {
        if (a.parent_id != 0) continue;
        try oneActivity(arena, out, a, cols, 2);
        for (items) |reply| {
            if (reply.parent_id != a.id or a.id == 0) continue;
            try oneActivity(arena, out, reply, cols, 5);
        }
    }
    // A reply whose parent is not in this page still has to appear.
    for (items) |a| {
        if (a.parent_id == 0) continue;
        var has_parent = false;
        for (items) |p| if (p.id == a.parent_id and p.parent_id == 0) {
            has_parent = true;
        };
        if (!has_parent) try oneActivity(arena, out, a, cols, 5);
    }
}

fn oneActivity(arena: Allocator, out: *std.ArrayList(Line), a: model.Activity, cols: u16, indent: u16) Allocator.Error!void {
    var when: [16]u8 = undefined;
    var head: std.Io.Writer.Allocating = .init(arena);
    head.writer.splatByteAll(' ', indent) catch return error.OutOfMemory;
    head.writer.print("{s}{s} · {s}", .{
        if (indent > 2) "↳ " else "",
        dashIfEmpty(a.author),
        j.stampInto(a.created_on, &when),
    }) catch return error.OutOfMemory;
    if (a.isInline()) {
        if (a.inlineLine()) |n| {
            head.writer.print("  {s}:{d}", .{ a.inline_path, n }) catch return error.OutOfMemory;
        } else head.writer.print("  {s}", .{a.inline_path}) catch return error.OutOfMemory;
    }
    try out.append(arena, .{ .text = head.written(), .tone = switch (a.kind) {
        .approval => .good,
        .changes_requested => .warn,
        .update => .dim,
        else => .accent,
    } });
    const body = if (a.deleted) "(deleted)" else a.text;
    try wrapInto(arena, out, body, cols, indent + 2, if (a.deleted) .dim else .normal);
}

/// A unified diff, one line per line, toned by its marker.
fn diffInto(arena: Allocator, out: *std.ArrayList(Line), diff: []const u8, cols: u16) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tone: Tone = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---"))
            .dim
        else if (std.mem.startsWith(u8, line, "@@"))
            .accent
        else if (std.mem.startsWith(u8, line, "diff --git"))
            .section
        else if (std.mem.startsWith(u8, line, "+"))
            .good
        else if (std.mem.startsWith(u8, line, "-"))
            .bad
        else
            .dim;
        // A diff is cut, never wrapped: a wrapped hunk stops lining up.
        try out.append(arena, .{ .text = try cut(arena, line, cols -| 2, "  "), .tone = tone });
    }
}

// ─── the chrome ──────────────────────────────────────────────────────────

pub const TabInfo = struct {
    name: []const u8,
    count: ?usize = null,
    /// A tab that fell back says which mode it is really showing.
    fallback_note: []const u8 = "",
};

pub fn tabStrip(arena: Allocator, tabs: []const TabInfo, active: usize) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (tabs, 0..) |tab, i| {
        if (i > 0) w.writeAll("  ") catch return error.OutOfMemory;
        w.print("{s}{d} {s}", .{ if (i == active) "▸" else " ", i + 1, tab.name }) catch return error.OutOfMemory;
        if (tab.count) |n| w.print(" ({d})", .{n}) catch return error.OutOfMemory;
        if (tab.fallback_note.len > 0) w.print(" [{s}]", .{tab.fallback_note}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

pub const FilterCtx = struct {
    query: []const u8 = "",
    editing: bool = false,
    matched: usize = 0,
    total: usize = 0,
};

pub fn filterLine(arena: Allocator, f: FilterCtx) Allocator.Error![]const u8 {
    if (f.editing) return std.fmt.allocPrint(arena, "filter: {s}▏  ({d}/{d})  enter keep · esc clear", .{ f.query, f.matched, f.total });
    if (f.query.len > 0) return std.fmt.allocPrint(arena, "filter: {s}  ({d}/{d})  / edit · esc clear", .{ f.query, f.matched, f.total });
    return std.fmt.allocPrint(arena, "/ filter · r refresh · d detail · ? keys", .{});
}

/// A confirm before anything that writes. It always names the thing it
/// is about to do, including the merge strategy — a confirm that only
/// says "Merge?" is not a confirm.
pub const Confirm = struct {
    title: []const u8,
    detail: []const u8 = "",
    /// The key that goes through with it.
    accept_key: []const u8 = "y",
};

pub fn confirmLines(arena: Allocator, c: Confirm) Allocator.Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    try out.append(arena, .{ .text = c.title, .tone = .bold });
    if (c.detail.len > 0) try out.append(arena, .{ .text = c.detail, .tone = .dim });
    try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} confirm · esc cancel", .{c.accept_key}), .tone = .accent });
    return out.toOwnedSlice(arena);
}

// ─── little text helpers ─────────────────────────────────────────────────

/// Write `s` cut to `w` cells and padded out to exactly `w`. Cells, not
/// bytes: a multi-byte code point counts once (twice in the wide
/// ranges, which the SDK's frame also does).
pub fn pad(w: *std.Io.Writer, s: []const u8, width: u16) Allocator.Error!void {
    if (width == 0) return;
    var used: u16 = 0;
    var i: usize = 0;
    while (i < s.len and used < width) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const take = @min(n, s.len - i);
        const cw = cellWidth(s[i..][0..take]);
        if (used + cw > width) break;
        w.writeAll(s[i..][0..take]) catch return error.OutOfMemory;
        used += cw;
        i += take;
    }
    w.splatByteAll(' ', width - used) catch return error.OutOfMemory;
}

/// `s` cut to `w` cells with `prefix` in front, owned by `arena`.
pub fn cut(arena: Allocator, s: []const u8, width: u16, prefix: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll(prefix) catch return error.OutOfMemory;
    var used: u16 = 0;
    var i: usize = 0;
    while (i < s.len and used < width) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const take = @min(n, s.len - i);
        const cw = cellWidth(s[i..][0..take]);
        if (used + cw > width) break;
        out.writer.writeAll(s[i..][0..take]) catch return error.OutOfMemory;
        used += cw;
        i += take;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn cellWidth(bytes: []const u8) u16 {
    const cp = std.unicode.utf8Decode(bytes) catch return 1;
    // The wide blocks the SDK's frame also counts as two.
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0x1F300 and cp <= 0x1FAFF)) return 2;
    return 1;
}

/// Break `text` on its own newlines, then on spaces, at `cols - indent`.
fn wrapInto(arena: Allocator, out: *std.ArrayList(Line), text: []const u8, cols: u16, indent: u16, tone: Tone) Allocator.Error!void {
    const width = cols -| indent -| 1;
    if (width < 8) {
        try out.append(arena, .{ .text = try cut(arena, text, cols, ""), .tone = tone });
        return;
    }
    var pad_buf: std.ArrayList(u8) = .empty;
    try pad_buf.appendNTimes(arena, ' ', indent);
    const lead = pad_buf.items;

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para_raw| {
        const para = std.mem.trimEnd(u8, para_raw, "\r");
        if (para.len == 0) {
            try out.append(arena, .{ .text = "" });
            continue;
        }
        var rest = para;
        while (rest.len > 0) {
            if (countCells(rest) <= width) {
                try out.append(arena, .{ .text = try std.mem.concat(arena, u8, &.{ lead, rest }), .tone = tone });
                break;
            }
            var brk = takeCells(rest, width);
            if (std.mem.lastIndexOfScalar(u8, rest[0..brk], ' ')) |sp| {
                if (sp > 0) brk = sp;
            }
            try out.append(arena, .{ .text = try std.mem.concat(arena, u8, &.{ lead, rest[0..brk] }), .tone = tone });
            rest = std.mem.trimStart(u8, rest[brk..], " ");
        }
    }
}

fn countCells(s: []const u8) u16 {
    var n: u16 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const take = @min(len, s.len - i);
        n += cellWidth(s[i..][0..take]);
        i += take;
    }
    return n;
}

/// The byte index at which `s` has used `width` cells.
fn takeCells(s: []const u8, width: u16) usize {
    var used: u16 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const take = @min(len, s.len - i);
        const cw = cellWidth(s[i..][0..take]);
        if (used + cw > width) break;
        used += cw;
        i += take;
    }
    return @max(i, 1);
}

fn trimEndSpaces(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " ");
}

fn dashIfEmpty(s: []const u8) []const u8 {
    return if (s.len == 0) "—" else s;
}

// ─── painting ────────────────────────────────────────────────────────────

/// Paint `lines` into the box `x, top` sized `width × height`,
/// scrolled by `scroll`, with `selected` reversed. `selected` is an
/// index into `lines`, or null for a surface with no cursor.
pub fn paintLines(f: *sdk.Frame, lines: []const Line, box: Box, scroll: usize, selected: ?usize) void {
    var y: u16 = 0;
    while (y < box.height) : (y += 1) {
        const row = box.y + y;
        if (row >= f.rows) break;
        f.fill(box.x, row, box.width, 1, .{});
        const idx = scroll + y;
        if (idx >= lines.len) continue;
        const line = lines[idx];
        var st = line.tone.style();
        if (selected != null and selected.? == idx) {
            st.mods.reverse = true;
            f.fill(box.x, row, box.width, 1, st);
        }
        _ = f.text(box.x, row, box.width, line.text, st);
    }
}

pub const Box = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16,
    height: u16,
};

/// The scroll offset that keeps `selected` on screen, given the one in
/// force now. Clamped to the last page.
pub fn scrollFor(selected: usize, height: u16, total: usize, current: usize) usize {
    if (height == 0) return 0;
    const h: usize = height;
    var s = current;
    if (selected < s) s = selected;
    if (selected >= s + h) s = selected + 1 - h;
    const max_scroll = if (total > h) total - h else 0;
    return @min(s, max_scroll);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn samplePr(id: i64) model.Pr {
    return .{
        .id = id,
        .title = "Fix the login redirect",
        .state = "OPEN",
        .updated_on = "2026-09-01T12:34:56.000+00:00",
        .author = "Chris M",
        .source_branch = "chris/fix-login",
        .dest_branch = "main",
        .repo_full_name = "acme/api",
        .description = "Fixes ENG-4210.",
    };
}

fn lineTexts(arena: Allocator, lines: []const Line) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, lines.len);
    for (lines, out) |l, *slot| slot.* = l.text;
    return out;
}

fn joined(arena: Allocator, lines: []const Line) Allocator.Error![]u8 {
    return std.mem.join(arena, "\n", try lineTexts(arena, lines));
}

test "columns are dropped one at a time as the pane narrows — 200, 120, 80 and 40" {
    // 200 and 120 keep everything.
    const wide = Columns.fit(200, true);
    try t.expect(wide.repo and wide.author and wide.branches and wide.updated and wide.votes and wide.build);
    const mid = Columns.fit(120, true);
    try t.expect(mid.repo and mid.author and mid.branches and mid.updated);
    // 80 — the corpus's narrow size, and mnml's default pane width —
    // must still be a usable list: the branch column is the first to go.
    const eighty = Columns.fit(80, true);
    try t.expect(!eighty.branches);
    try t.expect(eighty.votes);
    try t.expect(eighty.width() + Columns.min_title_w <= 80);
    // 40: down to the three that cannot be dropped, and it still fits.
    const narrow = Columns.fit(40, true);
    try t.expect(!narrow.repo and !narrow.author and !narrow.branches and !narrow.updated);
    try t.expect(narrow.width() + Columns.min_title_w <= 40);
    // A per-repo tab spends the repo column's width on the title.
    try t.expect(!Columns.fit(80, false).repo);
    try t.expect(Columns.fit(80, false).width() < eighty.width());
}

test "the list paints a header and one row per PR, with the state, the branches and the votes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr = samplePr(1234);
    pr.participants = &.{
        .{ .display_name = "Dana R", .account_id = "acct-dana", .role = "REVIEWER", .approval = .approved },
        .{ .display_name = "Sam K", .account_id = "acct-sam", .role = "REVIEWER", .approval = .changes_requested },
    };
    const lines = try listLines(a, .{ .rows = &.{.{ .pr = pr, .build = .{ .name = "Pipeline", .state = "FAILED" } }}, .cols = 200 });
    const text = try joined(a, lines);
    try t.expect(std.mem.indexOf(u8, text, "REPO") != null);
    try t.expect(std.mem.indexOf(u8, text, "BRANCH → DEST") != null);
    try t.expect(std.mem.indexOf(u8, text, "acme/api") == null); // the repo column is the slug half
    try t.expect(std.mem.indexOf(u8, text, "api ") != null);
    try t.expect(std.mem.indexOf(u8, text, "#1234") != null);
    try t.expect(std.mem.indexOf(u8, text, "OPEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "chris/fix-login → main") != null);
    try t.expect(std.mem.indexOf(u8, text, "2026-09-01") != null);
    try t.expect(std.mem.indexOf(u8, text, "✓1 ✗1") != null);
    try t.expect(std.mem.indexOf(u8, text, "✖") != null);
    try t.expect(std.mem.indexOf(u8, text, "Fix the login redirect") != null);
}

test "a narrow list still names the PR, its state and its title, and no row runs past the width" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u16{ 40, 80, 120, 200 }) |cols| {
        const lines = try listLines(a, .{ .rows = &.{.{ .pr = samplePr(1234) }}, .cols = cols });
        try t.expectEqual(@as(usize, 2), lines.len);
        for (lines) |l| {
            if (countCells(l.text) > cols) {
                std.debug.print("at {d} cols a line was {d} cells: {s}\n", .{ cols, countCells(l.text), l.text });
                return error.LineTooWide;
            }
        }
        try t.expect(std.mem.indexOf(u8, lines[1].text, "#1234") != null);
        try t.expect(std.mem.indexOf(u8, lines[1].text, "OPEN") != null);
        try t.expect(std.mem.indexOf(u8, lines[1].text, "Fix the") != null);
    }
}

test "a draft is dimmed and labelled DRAFT rather than OPEN" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr = samplePr(9);
    pr.draft = true;
    const lines = try listLines(a, .{ .rows = &.{.{ .pr = pr }}, .cols = 120 });
    try t.expect(std.mem.indexOf(u8, lines[1].text, "DRAFT") != null);
    try t.expectEqual(Tone.dim, lines[1].tone);
}

test "an empty list says so instead of painting a bare header" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try listLines(a, .{ .rows = &.{}, .cols = 120, .empty_message = "No open PRs you authored." });
    const text = try joined(a, lines);
    try t.expect(std.mem.indexOf(u8, text, "No open PRs you authored.") != null);
}

test "the detail names the PR, the reviewers' votes, the builds, the diffstat and the threads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr = samplePr(1234);
    pr.participants = &.{.{ .display_name = "Dana R", .account_id = "acct-dana", .role = "REVIEWER", .approval = .approved }};
    const lines = try detailLines(a, .{
        .pr = pr,
        .workspace = "acme",
        .repo = "api",
        .me_account_id = "acct-chris",
        .reviewers = &.{
            .{ .display_name = "Dana R", .account_id = "acct-dana", .role = "REVIEWER", .approval = .approved },
            .{ .display_name = "Sam K", .account_id = "acct-sam", .role = "REVIEWER", .approval = .changes_requested },
        },
        .builds = &.{
            .{ .key = "b1", .name = "Pipeline #412", .state = "SUCCESSFUL" },
            .{ .key = "b2", .name = "Deploy to dev", .state = "FAILED" },
        },
        .files = &.{
            .{ .status = "modified", .path = "src/auth/session.zig", .added = 18, .removed = 4 },
            .{ .status = "added", .path = "tests/redirect.test", .added = 31, .removed = 0 },
        },
        .diff = "diff --git a/x b/x\n@@ -1,2 +1,3 @@\n-old\n+new\n context\n",
        .activity = &.{
            .{ .kind = .comment, .id = 1, .author = "Dana R", .created_on = "2026-09-01T10:00:00+00:00", .text = "Nice catch." },
            .{ .kind = .comment, .id = 2, .author = "Sam K", .created_on = "2026-09-01T11:00:00+00:00", .text = "escape this", .inline_path = "src/auth/session.zig", .inline_to = 44 },
            .{ .kind = .comment, .id = 3, .author = "Chris M", .created_on = "2026-09-01T11:30:00+00:00", .text = "done", .parent_id = 2 },
            .{ .kind = .approval, .author = "Dana R", .created_on = "2026-09-01T12:00:00+00:00", .text = "approved this pull request" },
        },
        .jira_keys = &.{.{ .text = "ENG-4210", .project = "TE" }},
        .cols = 100,
    });
    const text = try joined(a, lines);
    try t.expect(std.mem.indexOf(u8, text, "acme/api#1234") != null);
    try t.expect(std.mem.indexOf(u8, text, "OPEN · chris/fix-login → main") != null);
    try t.expect(std.mem.indexOf(u8, text, "author: Chris M · updated: 2026-09-01") != null);
    // The account has not voted; the others have.
    try t.expect(std.mem.indexOf(u8, text, "○ you: no vote · ✓1 approved · ✗0 changes requested") != null);
    try t.expect(std.mem.indexOf(u8, text, "issues: [1] ENG-4210") != null);
    try t.expect(std.mem.indexOf(u8, text, "reviewers") != null);
    try t.expect(std.mem.indexOf(u8, text, "✓ Dana R  approved") != null);
    try t.expect(std.mem.indexOf(u8, text, "✗ Sam K  changes requested") != null);
    try t.expect(std.mem.indexOf(u8, text, "● Pipeline #412  SUCCESSFUL") != null);
    try t.expect(std.mem.indexOf(u8, text, "✖ Deploy to dev  FAILED") != null);
    try t.expect(std.mem.indexOf(u8, text, "files (2)  +49  -4") != null);
    try t.expect(std.mem.indexOf(u8, text, "~ src/auth/session.zig  +18 -4") != null);
    try t.expect(std.mem.indexOf(u8, text, "+ tests/redirect.test  +31 -0") != null);
    try t.expect(std.mem.indexOf(u8, text, "@@ -1,2 +1,3 @@") != null);
    try t.expect(std.mem.indexOf(u8, text, "activity (4)") != null);
    // An inline comment names its file and line; its reply is indented
    // under it, not filed by timestamp at the end.
    try t.expect(std.mem.indexOf(u8, text, "Sam K · 2026-09-01 11:00  src/auth/session.zig:44") != null);
    const reply_at = std.mem.indexOf(u8, text, "↳ Chris M").?;
    const approval_at = std.mem.indexOf(u8, text, "Dana R · 2026-09-01 12:00").?;
    try t.expect(reply_at < approval_at);
}

test "a detail with nothing fetched yet says loading, and says so per section" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loading = try joined(a, try detailLines(a, .{ .pr = samplePr(1), .loading = true, .cols = 80 }));
    try t.expectEqual(@as(usize, 4), std.mem.count(u8, loading, "loading…"));
    const done = try joined(a, try detailLines(a, .{ .pr = samplePr(1), .cols = 80 }));
    try t.expect(std.mem.indexOf(u8, done, "(none reported)") != null);
    try t.expect(std.mem.indexOf(u8, done, "(no diffstat)") != null);
    try t.expect(std.mem.indexOf(u8, done, "(no diff)") != null);
    try t.expect(std.mem.indexOf(u8, done, "(nothing yet)") != null);
    try t.expect(std.mem.indexOf(u8, done, "(none)") != null);
}

test "folding the diff away leaves the rest of the detail intact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try joined(a, try detailLines(a, .{
        .pr = samplePr(1),
        .diff = "diff --git a/x b/x\n+added\n",
        .show_diff = false,
        .cols = 80,
    }));
    try t.expect(std.mem.indexOf(u8, text, "diff  (hidden — D shows it)") != null);
    try t.expect(std.mem.indexOf(u8, text, "+added") == null);
    try t.expect(std.mem.indexOf(u8, text, "activity (0)") != null);
}

test "a long description wraps to the pane and never runs off it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr = samplePr(1);
    pr.description = "This is a long paragraph that has to wrap somewhere sensible rather than being cut, " ++
        "and it carries a second sentence so there is something to wrap onto.\n\nA second paragraph.";
    const lines = try detailLines(a, .{ .pr = pr, .cols = 40 });
    for (lines) |l| try t.expect(countCells(l.text) <= 40);
    const text = try joined(a, lines);
    try t.expect(std.mem.indexOf(u8, text, "A second paragraph.") != null);
    // It wrapped on spaces, so no line starts mid-word.
    try t.expect(std.mem.indexOf(u8, text, "somewhere sensible") != null or std.mem.indexOf(u8, text, "somewhere") != null);
}

test "a diff line is cut, not wrapped, so the hunks stay lined up" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "+" ++ ("x" ** 200);
    const lines = try detailLines(a, .{ .pr = samplePr(1), .diff = long, .cols = 60 });
    var diff_lines: usize = 0;
    for (lines) |l| {
        if (std.mem.startsWith(u8, l.text, "  +x")) diff_lines += 1;
        try t.expect(countCells(l.text) <= 60);
    }
    try t.expectEqual(@as(usize, 1), diff_lines);
}

test "pad and cut count cells, not bytes, so a multi-byte glyph does not overflow a column" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try pad(&out.writer, "✓✗", 5);
    try t.expectEqualStrings("✓✗   ", out.written());
    try t.expectEqual(@as(u16, 5), countCells(out.written()));
    var narrow: std.Io.Writer.Allocating = .init(a);
    try pad(&narrow.writer, "abcdef", 3);
    try t.expectEqualStrings("abc", narrow.written());
    // A wide code point takes two cells and is dropped rather than half-painted.
    var wide: std.Io.Writer.Allocating = .init(a);
    try pad(&wide.writer, "日本", 3);
    try t.expectEqualStrings("日 ", wide.written());
    try t.expectEqualStrings("  ab", try cut(a, "abcdef", 2, "  "));
}

test "the tab strip marks the active tab, counts what is in each, and notes a fallback" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const strip = try tabStrip(a, &.{
        .{ .name = "Mine", .count = 2 },
        .{ .name = "Review queue", .count = 1 },
        .{ .name = "api", .count = 12, .fallback_note = "workspace" },
    }, 1);
    try t.expectEqualStrings(" 1 Mine (2)  ▸2 Review queue (1)   3 api (12) [workspace]", strip);
}

test "the filter line says what it is doing in each of its three states" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(std.mem.indexOf(u8, try filterLine(a, .{}), "/ filter") != null);
    const editing = try filterLine(a, .{ .query = "login", .editing = true, .matched = 1, .total = 3 });
    try t.expect(std.mem.indexOf(u8, editing, "filter: login▏") != null);
    try t.expect(std.mem.indexOf(u8, editing, "(1/3)") != null);
    const held = try filterLine(a, .{ .query = "login", .matched = 1, .total = 3 });
    try t.expect(std.mem.indexOf(u8, held, "esc clear") != null);
    try t.expect(std.mem.indexOf(u8, held, "▏") == null);
}

test "a confirm names the action it is about to take, the merge strategy included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try confirmLines(a, .{
        .title = "Merge acme/api#1234?",
        .detail = "strategy: squash · close source branch: yes",
    });
    const text = try joined(a, lines);
    try t.expect(std.mem.indexOf(u8, text, "Merge acme/api#1234?") != null);
    try t.expect(std.mem.indexOf(u8, text, "strategy: squash") != null);
    try t.expect(std.mem.indexOf(u8, text, "y confirm · esc cancel") != null);
}

test "the scroll keeps the selection on screen and never runs past the last page" {
    try t.expectEqual(@as(usize, 0), scrollFor(0, 10, 100, 0));
    try t.expectEqual(@as(usize, 0), scrollFor(5, 10, 100, 0));
    // Stepping past the bottom scrolls by exactly one.
    try t.expectEqual(@as(usize, 1), scrollFor(10, 10, 100, 0));
    // Stepping back above the top scrolls up to it.
    try t.expectEqual(@as(usize, 3), scrollFor(3, 10, 100, 7));
    // The last page stops at the end, not past it.
    try t.expectEqual(@as(usize, 90), scrollFor(99, 10, 100, 95));
    // Fewer rows than the height: no scroll at all.
    try t.expectEqual(@as(usize, 0), scrollFor(2, 10, 3, 0));
    try t.expectEqual(@as(usize, 0), scrollFor(0, 0, 100, 0));
}

test "painting puts the lines on the frame, reverses the selected one and clears the rest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var f = try sdk.Frame.init(t.allocator, 40, 6);
    defer f.deinit();
    const lines = [_]Line{
        .{ .text = "first", .tone = .header },
        .{ .text = "second" },
        .{ .text = "third" },
    };
    paintLines(&f, &lines, .{ .y = 1, .width = 40, .height = 4 }, 0, 1);
    try t.expectEqualStrings("first", try rowText(arena.allocator(), &f, 1));
    try t.expectEqualStrings("second", try rowText(arena.allocator(), &f, 2));
    try t.expectEqualStrings("third", try rowText(arena.allocator(), &f, 3));
    try t.expectEqualStrings("", try rowText(arena.allocator(), &f, 4));
    // The selected row is reversed across the whole width.
    try t.expect(f.slots[2 * 40 + 0].style.mods.reverse);
    try t.expect(f.slots[2 * 40 + 39].style.mods.reverse);
    try t.expect(!f.slots[1 * 40 + 0].style.mods.reverse);
    // Scrolled by one, the first line is gone.
    paintLines(&f, &lines, .{ .y = 1, .width = 40, .height = 4 }, 1, null);
    try t.expectEqualStrings("second", try rowText(arena.allocator(), &f, 1));
}

/// Row `y` of the frame as text, trailing blanks trimmed — the test
/// spelling of "what a user would see on that line".
pub fn rowText(arena: Allocator, f: *const sdk.Frame, y: u16) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) {
        out.writer.writeAll(f.slots[@as(usize, y) * f.cols + x].symbol()) catch return error.OutOfMemory;
    }
    return std.mem.trimEnd(u8, out.written(), " ");
}
