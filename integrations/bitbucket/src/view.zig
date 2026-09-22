//! What a row reads like, as data: the columns of each of the five
//! tables, the spans of a row in them, the lines of the detail. The
//! painter (`screen.zig`) lays these into cells; a test asserts on the
//! text a user would read.
//!
//! The columns are the reference's, name for name and width for width
//! (`ui.rs`): the PR tree's `REPO / #PR · STATE · AUTHOR · BRANCH ·
//! UPDATED · TITLE`, the pipelines tree's `REPO / BRANCH · STATE ·
//! BUILD · RESULT · DATE`, and the three flat lists'. One rule is not
//! the reference's: **a column that does not fit is dropped, not
//! squeezed** — at 80 columns the reference paints `R STAT AUT BRAN`,
//! which nobody can read; here the branch goes first, then the author,
//! then the date, and the title keeps its room.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const model = @import("model.zig");
const tabs = @import("tabs.zig");
const app_mod = @import("app.zig");
const theme_mod = @import("theme.zig");
const keymap = @import("keymap.zig");

pub const Style = sdk.Style;
pub const Theme = theme_mod.Theme;
pub const App = app_mod.App;

pub const Table = enum { pr_tree, pipelines_tree, pr_flat, pipelines_flat, branches_flat };

pub fn tableOf(data: tabs.TabData) Table {
    return switch (data) {
        .repo_pr_tree => .pr_tree,
        .repo_tree => .pipelines_tree,
        .pull_requests => .pr_flat,
        .pipelines => .pipelines_flat,
        .branches => .branches_flat,
    };
}

pub const Col = struct {
    name: []const u8,
    w: u16,
    /// The last column takes what is left (at least `w`).
    rest: bool = false,
    /// Dropped in this order when the width runs out (0 = never).
    drop: u8 = 0,
};

/// The reference's column tables. `drop` ranks: 1 goes first.
pub const pr_tree_cols = [_]Col{
    .{ .name = "REPO / #PR", .w = 28 },
    .{ .name = "STATE", .w = 10, .drop = 4 },
    .{ .name = "AUTHOR", .w = 18, .drop = 2 },
    .{ .name = "BRANCH", .w = 22, .drop = 1 },
    .{ .name = "UPDATED", .w = 12, .drop = 3 },
    .{ .name = "TITLE", .w = 20, .rest = true },
};
pub const pipelines_tree_cols = [_]Col{
    .{ .name = "REPO / BRANCH", .w = 38 },
    .{ .name = "STATE", .w = 14, .drop = 3 },
    .{ .name = "BUILD", .w = 8, .drop = 2 },
    .{ .name = "RESULT", .w = 13 },
    .{ .name = "DATE", .w = 12, .drop = 1 },
};
pub const pr_flat_cols = [_]Col{
    .{ .name = "REPO", .w = 24, .drop = 4 },
    .{ .name = "PR", .w = 8 },
    .{ .name = "STATE", .w = 10, .drop = 5 },
    .{ .name = "AUTHOR", .w = 16, .drop = 2 },
    .{ .name = "BRANCH → DEST", .w = 28, .drop = 1 },
    .{ .name = "UPDATED", .w = 12, .drop = 3 },
    .{ .name = "TITLE", .w = 20, .rest = true },
};
pub const pipelines_flat_cols = [_]Col{
    .{ .name = "#", .w = 8 },
    .{ .name = "STATE", .w = 12 },
    .{ .name = "BRANCH", .w = 24, .rest = true },
    .{ .name = "COMMIT", .w = 10, .drop = 4 },
    .{ .name = "TRIGGER", .w = 12, .drop = 3 },
    .{ .name = "DURATION", .w = 10, .drop = 2 },
    .{ .name = "CREATED", .w = 12, .drop = 1 },
};
pub const branches_flat_cols = [_]Col{
    .{ .name = "BRANCH", .w = 32 },
    .{ .name = "COMMIT", .w = 10, .drop = 3 },
    .{ .name = "LATEST", .w = 12, .drop = 2 },
    .{ .name = "AUTHOR", .w = 20, .drop = 1 },
    .{ .name = "MESSAGE", .w = 20, .rest = true },
};

pub fn colsOf(table: Table) []const Col {
    return switch (table) {
        .pr_tree => &pr_tree_cols,
        .pipelines_tree => &pipelines_tree_cols,
        .pr_flat => &pr_flat_cols,
        .pipelines_flat => &pipelines_flat_cols,
        .branches_flat => &branches_flat_cols,
    };
}

/// One cell of air between columns, as the reference's table.
pub const gap: u16 = 1;

/// The columns that fit `width`, with the `rest` column widened to the
/// remainder. Dropped whole, highest `drop` rank last.
pub fn fit(a: Allocator, table: Table, width: u16) Allocator.Error![]Col {
    const all = colsOf(table);
    var keep = try a.alloc(bool, all.len);
    @memset(keep, true);
    while (true) {
        var need: u16 = 0;
        var n: u16 = 0;
        for (all, 0..) |c, i| if (keep[i]) {
            need += c.w;
            n += 1;
        };
        if (n > 0) need += (n - 1) * gap;
        if (need <= width) break;
        // Drop the lowest-ranked droppable column still kept.
        var best: ?usize = null;
        for (all, 0..) |c, i| if (keep[i] and c.drop > 0) {
            if (best == null or c.drop < all[best.?].drop) best = i;
        };
        const victim = best orelse break;
        keep[victim] = false;
    }
    var out: std.ArrayList(Col) = .empty;
    var used: u16 = 0;
    for (all, 0..) |c, i| if (keep[i]) {
        try out.append(a, c);
        used += c.w + gap;
    };
    used -|= gap;
    for (out.items) |*c| if (c.rest and width > used) {
        c.w += width - used;
    };
    return out.toOwnedSlice(a);
}

pub const Span = struct {
    text: []const u8,
    style: Style,
    /// Cells this span pads or clips to; 0 = as long as the text.
    w: u16 = 0,
};

/// The column header row.
pub fn headerSpans(a: Allocator, cols: []const Col, th: Theme) Allocator.Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    const style: Style = .{ .fg = th.muted, .mods = .{ .bold = true } };
    for (cols, 0..) |c, i| {
        if (i > 0) try out.append(a, .{ .text = " ", .style = style, .w = gap });
        try out.append(a, .{ .text = c.name, .style = style, .w = c.w });
    }
    return out.toOwnedSlice(a);
}

pub const RowCtx = struct {
    app: *App,
    ts: *const app_mod.TabState,
    cols: []const Col,
    th: Theme,
    row: tabs.VisibleRow,
    selected: bool,
    /// The host said it has no nerd font: plain glyphs, plain separators.
    ascii: bool = false,
};

fn cellStyle(c: RowCtx, base: Style) Style {
    if (!c.selected) return base;
    return c.th.onCursor(base);
}

/// The spans of one row, column by column.
pub fn rowSpans(a: Allocator, c: RowCtx) Allocator.Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    const ts = c.ts;
    const th = c.th;
    var cells: [8][]const u8 = undefined;
    var styles: [8]Style = undefined;
    var n: usize = 0;
    const base = cellStyle(c, th.text());
    const dim = cellStyle(c, th.mutedText());
    switch (c.row) {
        .repo_header => |h| switch (ts.data) {
            .repo_pr_tree => |repos| {
                const r = repos[h.repo];
                const open = ts.expanded.hasRepo(r.slug);
                cells[0] = try std.fmt.allocPrint(a, "{s} {s}", .{ expander(open, c.ascii), r.slug });
                styles[0] = cellStyle(c, if (r.error_label.len > 0) th.bad() else th.accentText());
                if (r.error_label.len > 0) {
                    cells[1] = r.error_label;
                    styles[1] = cellStyle(c, th.bad());
                    n = 2;
                    while (n < 6) : (n += 1) {
                        cells[n] = "";
                        styles[n] = dim;
                    }
                } else if (r.prs.len == 0 and r.fallback_merged != null) {
                    const fb = r.fallback_merged.?;
                    cells[1] = "last merged";
                    cells[2] = fb.author;
                    cells[3] = fb.source_branch;
                    cells[4] = fb.updatedDate();
                    cells[5] = try std.fmt.allocPrint(a, "#{d} · {s}", .{ fb.id, fb.title });
                    for (1..6) |i| styles[i] = dim;
                    n = 6;
                } else {
                    const p: ?model.PullRequest = if (r.prs.len > 0) r.prs[0] else null;
                    cells[1] = try std.fmt.allocPrint(a, "{d} PRs", .{r.prs.len});
                    cells[2] = if (p) |pr| pr.author else "";
                    cells[3] = if (p) |pr| pr.source_branch else "";
                    cells[4] = if (p) |pr| pr.updatedDate() else "";
                    cells[5] = if (p) |pr| try std.fmt.allocPrint(a, "#{d} · {s}", .{ pr.id, pr.title }) else "";
                    for (1..6) |i| styles[i] = dim;
                    n = 6;
                }
            },
            .repo_tree => |repos| {
                const r = repos[h.repo];
                const open = ts.expanded.hasRepo(r.slug);
                cells[0] = try std.fmt.allocPrint(a, "{s} {s}", .{ expander(open, c.ascii), r.slug });
                styles[0] = cellStyle(c, if (r.error_label.len > 0) th.bad() else th.accentText());
                cells[1] = if (r.error_label.len > 0) r.error_label else try std.fmt.allocPrint(a, "{d} branches", .{r.branches.len});
                styles[1] = cellStyle(c, if (r.error_label.len > 0) th.bad() else th.mutedText());
                cells[2] = "";
                cells[3] = "";
                cells[4] = "";
                for (2..5) |i| styles[i] = dim;
                n = 5;
            },
            else => {},
        },
        .pr => |p| {
            const r = ts.data.repo_pr_tree[p.repo];
            const pr = r.prs[p.idx];
            const expandable = pr.buildCommit().len > 0;
            const caret: []const u8 = if (!expandable) "  " else expander(p.open, c.ascii);
            cells[0] = try std.fmt.allocPrint(a, "  {s} #{d}", .{ caret, pr.id });
            styles[0] = cellStyle(c, th.number());
            cells[1] = pr.state;
            styles[1] = cellStyle(c, th.prState(pr.state));
            cells[2] = pr.author;
            styles[2] = base;
            cells[3] = pr.source_branch;
            styles[3] = base;
            cells[4] = pr.updatedDate();
            styles[4] = base;
            cells[5] = pr.title;
            styles[5] = base;
            n = 6;
        },
        // A build line is not a table row: it is one line under the
        // pull request it belongs to, in the toolkit's own words.
        .build => return buildSpans(a, c),
        .build_note => return buildNoteSpans(a, c),
        .branch => |b| {
            const br = ts.data.repo_tree[b.repo].branches[b.idx];
            cells[0] = try std.fmt.allocPrint(a, "    {s}", .{br.name});
            styles[0] = base;
            if (br.latest) |pl| {
                cells[1] = pl.stateOnlyLabel();
                styles[1] = cellStyle(c, th.pipelineState(pl.stateOnlyLabel()));
                cells[2] = try std.fmt.allocPrint(a, "#{d}", .{pl.build_number});
                styles[2] = cellStyle(c, th.number());
                cells[3] = if (pl.result_name.len > 0) try std.fmt.allocPrint(a, "{s} {s}", .{ model.glyphFor(pl.result_name), pl.result_name }) else "";
                styles[3] = cellStyle(c, th.pipelineState(pl.result_name));
                cells[4] = pl.createdDate();
                styles[4] = base;
            } else {
                cells[1] = "—";
                styles[1] = dim;
                cells[2] = "";
                cells[3] = "";
                cells[4] = "";
                styles[2] = dim;
                styles[3] = dim;
                styles[4] = dim;
            }
            n = 5;
        },
        // The fold row does not go through the table at all: it is
        // `Painter.showMoreRow`, laid at `lastColumnX` by the caller,
        // so the two panes' fold rows are one function and one phrase.
        .show_more => n = 0,
        .flat => |i| switch (ts.data) {
            .pull_requests => |list| {
                const pr = list[i];
                cells[0] = pr.repo_full;
                styles[0] = base;
                cells[1] = try std.fmt.allocPrint(a, "#{d}", .{pr.id});
                styles[1] = cellStyle(c, th.number());
                cells[2] = pr.state;
                styles[2] = cellStyle(c, th.prState(pr.state));
                cells[3] = if (pr.author.len > 0) pr.author else "—";
                styles[3] = base;
                cells[4] = try std.fmt.allocPrint(a, "{s} → {s}", .{ orQ(pr.source_branch), orQ(pr.dest_branch) });
                styles[4] = base;
                cells[5] = pr.updatedDate();
                styles[5] = base;
                cells[6] = pr.title;
                styles[6] = base;
                n = 7;
            },
            .pipelines => |list| {
                const pl = list[i];
                var dbuf: [16]u8 = undefined;
                cells[0] = try std.fmt.allocPrint(a, "#{d}", .{pl.build_number});
                styles[0] = cellStyle(c, th.number());
                cells[1] = pl.stateLabel();
                styles[1] = cellStyle(c, th.pipelineState(pl.stateLabel()));
                cells[2] = pl.branchLabel();
                styles[2] = base;
                cells[3] = pl.shortSha();
                styles[3] = base;
                cells[4] = pl.triggerLabel();
                styles[4] = base;
                cells[5] = try a.dupe(u8, pl.durationLabel(&dbuf));
                styles[5] = base;
                cells[6] = pl.createdDate();
                styles[6] = base;
                n = 7;
            },
            .branches => |list| {
                const br = list[i];
                cells[0] = br.name;
                styles[0] = base;
                cells[1] = br.shortSha();
                styles[1] = cellStyle(c, th.number());
                cells[2] = br.latestDate();
                styles[2] = base;
                cells[3] = br.authorLabel();
                styles[3] = base;
                cells[4] = br.summaryLine();
                styles[4] = base;
                n = 5;
            },
            else => {},
        },
    }
    // Lay the cells into the columns that fit: the table's own order
    // is the cells' order, so a dropped column skips its cell.
    const all = colsOf(tableOf(ts.data));
    var ci: usize = 0;
    var first = true;
    for (all, 0..) |col, i| {
        if (i >= n) break;
        if (ci < c.cols.len and std.mem.eql(u8, c.cols[ci].name, col.name)) {
            if (!first) try out.append(a, .{ .text = " ", .style = base, .w = gap });
            first = false;
            try out.append(a, .{ .text = cells[i], .style = styles[i], .w = c.cols[ci].w });
            ci += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// Where the last kept column starts, given the x the spans start at.
/// The fold row is laid there by the toolkit rather than squeezed
/// through the table.
pub fn lastColumnX(cols: []const Col, x0: u16) u16 {
    if (cols.len == 0) return x0;
    var x = x0;
    for (cols[0 .. cols.len - 1]) |c| x += c.w + gap;
    return x;
}

fn orQ(s: []const u8) []const u8 {
    return if (s.len > 0) s else "?";
}

/// The tree's chevron — the toolkit's `open_glyph` / `closed_glyph`,
/// the same codepoints the host's file tree and the tracker pane's
/// tree fold with (`src/ui/expander.zig`), and their `--ascii` twins.
/// This pane used to paint `▾` / `▸`, the reference's triangles, so
/// its rows folded with a different mark from every other tree on the
/// screen.
pub fn expander(open: bool, ascii: bool) []const u8 {
    if (ascii) return if (open) sdk.pane.chrome.open_ascii else sdk.pane.chrome.closed_ascii;
    return if (open) sdk.pane.chrome.open_glyph else sdk.pane.chrome.closed_glyph;
}

/// One build line under a pull-request row — the toolkit's, so this
/// pane and the Jira one read the same. The whole line is the row, so
/// the spans are one span.
pub fn buildSpans(a: Allocator, c: RowCtx) Allocator.Error![]Span {
    const b = c.row.build;
    const r = c.ts.data.repo_pr_tree[b.repo];
    const pr = r.prs[b.idx];
    const cached = c.app.prPipelinesOf(r.slug, pr.id);
    var out: std.ArrayList(Span) = .empty;
    const runs = if (cached) |e| e.pipelines else &.{};
    if (b.run >= runs.len) return out.toOwnedSlice(a);
    const run = runs[b.run];
    const label = run.stateLabel();
    var buf: [192]u8 = undefined;
    const line = sdk.pane.build.caption(&buf, .{
        .state = label,
        .branch = run.branchLabel(),
        .created_on = run.created_on,
        .number = run.build_number,
    }, c.app.now_secs, c.ascii);
    try out.append(a, .{ .text = build_indent, .style = cellStyle(c, c.th.mutedText()) });
    try out.append(a, .{ .text = try a.dupe(u8, line), .style = cellStyle(c, sdk.pane.build.styleOf(c.th, label)) });
    return out.toOwnedSlice(a);
}

/// The indent a build line hangs at, under its pull request's `#id`.
pub const build_indent = "      ";

/// The line where a build line would be when there is not one.
pub fn buildNoteSpans(a: Allocator, c: RowCtx) Allocator.Error![]Span {
    const b = c.row.build_note;
    const r = c.ts.data.repo_pr_tree[b.repo];
    const pr = r.prs[b.idx];
    const sha = pr.buildCommit()[0..@min(pr.buildCommit().len, 7)];
    const cached = c.app.prPipelinesOf(r.slug, pr.id);
    var out: std.ArrayList(Span) = .empty;
    const arrow = if (c.ascii) "-> " else "\u{2192} ";
    const text: []const u8 = switch (b.kind) {
        .loading => try std.fmt.allocPrint(a, "fetching builds on {s}\u{2026}", .{sha}),
        .none => try std.fmt.allocPrint(a, "no build ran on {s}", .{sha}),
        .failed => if (cached) |e| e.error_text else "the build lookup failed",
    };
    try out.append(a, .{ .text = build_indent, .style = cellStyle(c, c.th.mutedText()) });
    try out.append(a, .{ .text = arrow, .style = cellStyle(c, c.th.mutedText()) });
    try out.append(a, .{ .text = text, .style = cellStyle(c, if (b.kind == .failed) c.th.bad() else c.th.mutedText()) });
    return out.toOwnedSlice(a);
}

// ─── the detail ──────────────────────────────────────────────────────────

pub const Line = struct { spans: []const Span };

/// The detail panel's lines, wrapped to `width`: the reference's
/// header (state · branches, author · updated, the approval line),
/// the title, the description, the comments most-recent first.
pub fn detailLines(a: Allocator, entry: *const app_mod.DetailEntry, title: []const u8, me: []const u8, width: u16, th: Theme) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    const pr = entry.pr;
    try out.append(a, .{ .spans = try one(a, title, th.accentText()) });
    try out.append(a, .{ .spans = try a.dupe(Span, &.{
        .{ .text = pr.state, .style = th.prState(pr.state) },
        .{ .text = try std.fmt.allocPrint(a, " · {s} → {s}", .{ orQ(pr.source_branch), orQ(pr.dest_branch) }), .style = th.text() },
    }) });
    try wrapInto(a, &out, try std.fmt.allocPrint(a, "author: {s} · updated: {s}", .{ if (pr.author.len > 0) pr.author else "—", pr.updatedDate() }), th.text(), width);
    if (pr.approvedBy(me)) {
        try out.append(a, .{ .spans = try one(a, try std.fmt.allocPrint(a, "✓ you approved · {d} total", .{pr.approvalCount()}), .{ .fg = th.green, .mods = .{ .bold = true } }) });
    } else {
        try out.append(a, .{ .spans = try one(a, try std.fmt.allocPrint(a, "○ not approved · {d} total", .{pr.approvalCount()}), th.warn()) });
    }
    try out.append(a, .{ .spans = &.{} });
    try wrapInto(a, &out, pr.title, .{ .fg = th.fg, .mods = .{ .bold = true } }, width);
    try out.append(a, .{ .spans = &.{} });
    const desc = std.mem.trim(u8, pr.description, " \r\n\t");
    if (desc.len == 0) {
        try out.append(a, .{ .spans = try one(a, "(no description)", .{ .fg = th.muted, .mods = .{ .italic = true } }) });
    } else {
        var it = std.mem.splitScalar(u8, desc, '\n');
        while (it.next()) |line| try wrapInto(a, &out, std.mem.trimEnd(u8, line, "\r"), th.text(), width);
    }
    try out.append(a, .{ .spans = &.{} });
    try out.append(a, .{ .spans = try one(a, try std.fmt.allocPrint(a, "comments ({d}, most-recent first):", .{entry.comments.len}), .{ .fg = th.muted, .mods = .{ .bold = true } }) });
    try out.append(a, .{ .spans = &.{} });
    var i = entry.comments.len;
    var shown: usize = 0;
    while (i > 0 and shown < 20) : (shown += 1) {
        i -= 1;
        const cm = entry.comments[i];
        try out.append(a, .{ .spans = try a.dupe(Span, &.{
            .{ .text = try std.fmt.allocPrint(a, "  {s} · ", .{if (cm.author.len > 0) cm.author else "—"}), .style = .{ .fg = th.cyan } },
            .{ .text = cm.createdDate(), .style = th.mutedText() },
        }) });
        var lines = std.mem.splitScalar(u8, cm.body, '\n');
        while (lines.next()) |line| try wrapInto(a, &out, try std.fmt.allocPrint(a, "    {s}", .{std.mem.trimEnd(u8, line, "\r")}), th.text(), width);
        try out.append(a, .{ .spans = &.{} });
    }
    return out.toOwnedSlice(a);
}

fn one(a: Allocator, text: []const u8, style: Style) Allocator.Error![]Span {
    return a.dupe(Span, &.{.{ .text = text, .style = style }});
}

/// Word-wrap `text` into lines no wider than `width` code points.
pub fn wrapInto(a: Allocator, out: *std.ArrayList(Line), text: []const u8, style: Style, width: u16) Allocator.Error!void {
    const w: usize = @max(width, 8);
    var rest = text;
    if (rest.len == 0) {
        try out.append(a, .{ .spans = &.{} });
        return;
    }
    while (rest.len > 0) {
        const n = std.unicode.utf8CountCodepoints(rest) catch rest.len;
        if (n <= w) {
            try out.append(a, .{ .spans = try one(a, rest, style) });
            return;
        }
        // The byte offset of the w-th code point.
        var bytes: usize = 0;
        var cps: usize = 0;
        while (bytes < rest.len and cps < w) : (cps += 1) bytes += std.unicode.utf8ByteSequenceLength(rest[bytes]) catch 1;
        var cut = bytes;
        if (std.mem.lastIndexOfScalar(u8, rest[0..bytes], ' ')) |sp| if (sp > 0) {
            cut = sp;
        };
        try out.append(a, .{ .spans = try one(a, std.mem.trimEnd(u8, rest[0..cut], " "), style) });
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
}

// ─── the hint row ─────────────────────────────────────────────────────────

pub const Hint = struct { key: []const u8, title: []const u8, action: keymap.Action };

/// The hints for a context, in the table's order.
pub fn hints(a: Allocator, ctx: keymap.Context) Allocator.Error![]Hint {
    var buf: [keymap.table.len]keymap.Binding = undefined;
    const bs = keymap.hints(ctx, &buf);
    const out = try a.alloc(Hint, bs.len);
    for (bs, out) |b, *h| h.* = .{ .key = keymap.keyLabel(b.keys[0]), .title = shortTitle(b.action, b.title), .action = b.action };
    return out;
}

/// The hint row has room for a word or two per key.
fn shortTitle(action: keymap.Action, title: []const u8) []const u8 {
    return switch (action) {
        .down => "move",
        .activate => "expand",
        .open_web => "open on web",
        .toggle_detail => "detail",
        .toggle_approval => "approve",
        .toggle_merged => "open↔merged",
        .refresh => "refresh",
        .help => "keys",
        .quit => "quit",
        else => title,
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the reference's columns fit at 120 and drop the branch, then the author, at 80" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wide = try fit(a, .pr_tree, 120);
    try t.expectEqual(@as(usize, 6), wide.len);
    try t.expectEqualStrings("TITLE", wide[5].name);
    try t.expect(wide[5].w > 20);
    const narrow = try fit(a, .pr_tree, 80);
    // 28+10+18+22+12+20 + 5 gaps = 115 > 80 → drop BRANCH (92), then
    // AUTHOR (73 ≤ 80): the title keeps its room, unlike the reference's
    // four-character columns at this width.
    try t.expectEqual(@as(usize, 4), narrow.len);
    for (narrow) |c| try t.expect(!std.mem.eql(u8, c.name, "BRANCH") and !std.mem.eql(u8, c.name, "AUTHOR"));
    const tiny = try fit(a, .pr_tree, 50);
    try t.expectEqual(@as(usize, 2), tiny.len);
    try t.expectEqualStrings("REPO / #PR", tiny[0].name);
    try t.expectEqualStrings("TITLE", tiny[1].name);
    const pipes = try fit(a, .pipelines_tree, 80);
    // 38+14+8+13+12 + 4 = 89 > 80 → drop DATE.
    try t.expectEqual(@as(usize, 4), pipes.len);
    try t.expectEqualStrings("RESULT", pipes[3].name);
}

test "wrapping breaks on a space when it can and never loses a character" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Line) = .empty;
    try wrapInto(a, &out, "The quick brown fox jumps over the lazy dog", .{}, 16);
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expectEqualStrings("The quick brown", out.items[0].spans[0].text);
    try t.expectEqualStrings("fox jumps over", out.items[1].spans[0].text);
    try t.expectEqualStrings("the lazy dog", out.items[2].spans[0].text);
    var hard: std.ArrayList(Line) = .empty;
    try wrapInto(a, &hard, "abcdefghijklmnopqrstuvwxyz", .{}, 10);
    try t.expectEqual(@as(usize, 3), hard.items.len);
    try t.expectEqualStrings("abcdefghij", hard.items[0].spans[0].text);
    try t.expectEqualStrings("uvwxyz", hard.items[2].spans[0].text);
}

test "the hint row reads like the reference's footer, generated from the table" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const hs = try hints(arena.allocator(), .{ .on_tree = true, .on_row = true, .detail_open = true });
    try t.expectEqualStrings("↓", hs[0].key);
    try t.expectEqualStrings("move", hs[0].title);
    var has_approve = false;
    for (hs) |h| if (h.action == .toggle_approval) {
        has_approve = true;
        try t.expectEqualStrings("a", h.key);
        try t.expectEqualStrings("approve", h.title);
    };
    try t.expect(has_approve);
    try t.expectEqualStrings("q", hs[hs.len - 1].key);
}
