//! The git palette — the sidebar while Git is the active section, cell
//! for cell the Rust editor's `ui/git_palette.rs`:
//!
//! ```text
//!  GIT              ↻
//!   ws 󰅀
//!  ⎇ main  ↑1
//!
//!  󰍉 / filter
//!
//!  ▾ WORKTREES     1
//!    ⌂ main (ws)
//!
//!  ▾ LOCAL         2
//!    ○ feature
//!    ● main
//! ```
//!
//! The caps header (`header.zig`), the repo pill, the branch row, the
//! filter pill, then the sections — WORKTREES, LOCAL (folder-grouped by
//! the first `/`), REMOTE, PULL REQUESTS — each a header row with its
//! count at the right edge, its rows, and a blank row after. The rows
//! come in flat (`Row`), built by `app/git_palette.zig` from the rail
//! data and the filter; the scroll skips item rows in draw order and
//! keeps every header, as Rust does. Every row registers
//! `.row{ .git, idx }` in the statement that paints it; the pill and
//! the branch row are `.git_palette` parts.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const header = @import("header.zig");
const filter_input = @import("filter_input.zig");
const scrollbar = @import("scrollbar.zig");
const clip = @import("clip.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;

/// The palette's own click targets beside its rows.
pub const Part = enum { repo, branch };

pub const Section = enum {
    worktrees,
    local,
    remote,
    prs,

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .worktrees => "WORKTREES",
            .local => "LOCAL",
            .remote => "REMOTE",
            .prs => "PULL REQUESTS",
        };
    }
};

/// One painted row of the sections. `idx` on an item is its index into
/// the app's list for that kind (a branch's into the rail's branches).
pub const Row = union(enum) {
    section: struct { s: Section, count: u32, collapsed: bool },
    /// `▾ bugfix  (2)` — a `/` prefix group inside LOCAL or REMOTE.
    folder: struct { s: Section, name: []const u8, count: u32, collapsed: bool },
    worktree: struct { idx: u32, shown: []const u8, current: bool },
    branch: struct { idx: u32, shown: []const u8, name: []const u8, current: bool, in_folder: bool },
    remote: struct { idx: u32, shown: []const u8, name: []const u8, in_folder: bool },
    pr: struct { idx: u32, number: u32, title: []const u8, current: bool },
    gap,

    /// An item row — what the scroll skips and the filter counts.
    pub fn isItem(r: Row) bool {
        return switch (r) {
            .worktree, .branch, .remote, .pr => true,
            else => false,
        };
    }

    /// The name a click selects (Rust's `git_palette_selected`).
    pub fn selectName(r: Row) ?[]const u8 {
        return switch (r) {
            .worktree => |w| w.shown,
            .branch => |b| b.name,
            .remote => |m| m.name,
            else => null,
        };
    }
};

pub const Props = struct {
    rows: []const Row,
    repo: []const u8,
    branch: ?[]const u8,
    ahead: u32 = 0,
    behind: u32 = 0,
    filter: []const u8 = "",
    filter_focused: bool = false,
    /// The last clicked ref: its row carries the highlight.
    selected: ?[]const u8 = null,
    /// The keyboard cursor, highlighted while the palette has focus.
    cursor: ?usize = null,
    /// Item rows skipped before the first painted one.
    scroll: usize,
};

pub const Painted = struct {
    /// Rows the body has for items (the panel less the header and the
    /// filter) — the scrollbar's viewport and the scroll clamp.
    body_rows: usize = 0,
    /// Item rows in `rows`.
    total_items: usize = 0,
};

pub const glyph_repo_chevron_nerd = "\u{F0140}";
pub const glyph_repo_chevron_ascii = "v";
pub const glyph_branch = "\u{2387}";
pub const glyph_here = "\u{2302}";
pub const glyph_dot = "\u{B7}";
pub const glyph_current = "\u{25CF}";
pub const glyph_other = "\u{25CB}";
pub const glyph_remote = "\u{2601}";
pub const glyph_open = "\u{25BE}";
pub const glyph_closed = "\u{25B8}";

fn chev(ui: Ui, collapsed: bool) []const u8 {
    if (ui.ascii) return if (collapsed) "> " else "v ";
    return if (collapsed) glyph_closed ++ " " else glyph_open ++ " ";
}

/// Code points, as Rust's `chars().count()` measures.
fn chars(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Paints the palette into `area` and registers its hits.
pub fn draw(ui: Ui, area: Rect, p: Props) Painted {
    const t = ui.theme;
    const pal = t.palette;
    const bg = t.panel_bg;
    var out: Painted = .{};
    ui.fill(area, bg);
    if (area.h < 2 or area.w < 8) return out;
    const x0 = area.x;
    const w = area.w;
    const bottom = area.bottom();

    // ── GIT ──
    _ = header.draw(ui, area.row(0), .{ .panel = .git, .label = "GIT", .show_refresh = true, .bg = bg });
    var y: u16 = area.y + 1;

    // ── the repo pill ──
    {
        const text = ui.fmt(" {s} {s} ", .{ p.repo, if (ui.ascii) glyph_repo_chevron_ascii else glyph_repo_chevron_nerd });
        const pill_w: u16 = @intCast(@min(chars(text), @as(usize, w -| 1)));
        var style = Theme.onBg(t.fg, pal.bg2);
        style.bold = true;
        const r = Rect.init(x0 + 1, y, pill_w, 1);
        _ = ui.putStr(r.x, y, r.w, text, style);
        ui.hit(r, .{ .git_palette = .repo });
        y += 1;
    }

    // ── ⎇ branch  ↑a  ↓b ──
    if (y < bottom) {
        var x = x0 + 1;
        const end = area.right();
        x += ui.putStr(x, y, end -| x, if (ui.ascii) "Y " else glyph_branch ++ " ", Theme.onBg(Theme.withFg(bg, pal.purple), bg.bg));
        var bs = bg;
        bs.bold = true;
        x += ui.putStr(x, y, end -| x, p.branch orelse "(no branch)", bs);
        if (p.ahead > 0) x += ui.putStr(x, y, end -| x, ui.fmt("  \u{2191}{d}", .{p.ahead}), Theme.withFg(bg, pal.green));
        if (p.behind > 0) x += ui.putStr(x, y, end -| x, ui.fmt("  \u{2193}{d}", .{p.behind}), Theme.withFg(bg, pal.orange));
        ui.hit(area.row(y - area.y), .{ .git_palette = .branch });
        y += 2;
    }

    // ── the filter pill ──
    if (y < bottom) {
        const r = Rect.init(x0, y, w, 1);
        const chip_bg = pal.bg2;
        const chip = Theme.onBg(bg, chip_bg);
        ui.fill(Rect.init(x0 + 1, y, w -| 2, 1), chip);
        var x = x0 + 1;
        const end = area.right() - 1;
        x += ui.putStr(x, y, end -| x, ui.fmt("{s} ", .{filter_input.glyph(ui)}), Theme.withFg(chip, pal.comment));
        const empty = p.filter.len == 0;
        const text: []const u8 = if (empty) filter_input.placeholder(ui, p.filter_focused) else p.filter;
        const max_text: usize = @as(usize, w) -| 5;
        // A long filter keeps its tail, with `…` in front.
        var shown = text;
        if (chars(text) > max_text) {
            var start: usize = 0;
            while (start < text.len and chars(text[start..]) > max_text -| 1) start += std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
            shown = ui.fmt("{s}{s}", .{ if (ui.ascii) "..." else "\u{2026}", text[start..] });
        }
        const text_style = Theme.withFg(chip, if (empty and !p.filter_focused) pal.comment else pal.fg);
        x += ui.putStr(x, y, end -| x, shown, text_style);
        _ = ui.putStr(x, y, end -| x, if (p.filter_focused) (if (ui.ascii) "|" else "\u{258F}") else " ", Theme.withFg(chip, pal.cyan));
        ui.hit(r, .{ .filter_input = .git });
        y += 2;
    }

    // ── the sections ──
    out.body_rows = @as(usize, area.h) -| 2;
    for (p.rows) |r| if (r.isItem()) {
        out.total_items += 1;
    };
    const focused = ui.isFocused(.{ .panel = .git });
    var skip = p.scroll;
    for (p.rows, 0..) |row, idx| {
        if (y >= bottom) break;
        if (row.isItem() and skip > 0) {
            skip -= 1;
            continue;
        }
        const rr = Rect.init(x0, y, w, 1);
        const hl_name = if (p.selected) |s| (if (row.selectName()) |n| std.mem.eql(u8, s, n) else false) else false;
        const hl = hl_name or (focused and p.cursor != null and p.cursor.? == idx and row != .gap);
        const row_bg: Color = if (hl) pal.bg2 else bg.bg;
        const ground = Theme.onBg(bg, row_bg);
        // The highlight never touches the activity bar: the first cell
        // keeps the panel's own ground.
        if (hl) ui.fill(Rect.init(x0 + 1, y, w -| 1, 1), ground);
        const end = area.right();
        switch (row) {
            .gap => {},
            .section => |s| {
                var x = x0 + 1;
                x += ui.putStr(x, y, end -| x, chev(ui, s.collapsed), Theme.withFg(ground, pal.comment));
                var ls = Theme.withFg(ground, pal.comment);
                ls.bold = true;
                const label = s.s.label();
                x += ui.putStr(x, y, end -| x, label, ls);
                const count = ui.fmt("{d}", .{s.count});
                // Rust's row is one cell short of the width: the count sits
                // two cells in from the right edge.
                const cx: u16 = @intCast(@max(@as(usize, x), @as(usize, area.right()) -| (chars(count) + 2)));
                _ = ui.putStr(cx, y, end -| cx, count, Theme.withFg(ground, pal.cyan));
            },
            .folder => |f| {
                var x = x0 + 2;
                x += ui.putStr(x, y, end -| x, chev(ui, f.collapsed), Theme.withFg(ground, pal.comment));
                x += ui.putStr(x, y, end -| x, f.name, Theme.withFg(ground, pal.fg));
                _ = ui.putStr(x, y, end -| x, ui.fmt("  ({d})", .{f.count}), Theme.withFg(ground, pal.comment));
            },
            .worktree => |wt| {
                var x = x0 + 3;
                const marker: []const u8 = if (wt.current) (if (ui.ascii) "@" else glyph_here) else (if (ui.ascii) "." else glyph_dot);
                x += ui.putStr(x, y, end -| x, marker, Theme.withFg(ground, if (wt.current) pal.yellow else pal.fg));
                x += ui.putStr(x, y, end -| x, " ", ground);
                var ns = Theme.withFg(ground, pal.fg);
                ns.bold = wt.current;
                _ = ui.putStr(x, y, end -| x, wt.shown, ns);
            },
            .branch => |b| {
                var x: u16 = x0 + @as(u16, if (b.in_folder) 5 else 3);
                const marker: []const u8 = if (b.current) (if (ui.ascii) "*" else glyph_current) else (if (ui.ascii) "o" else glyph_other);
                x += ui.putStr(x, y, end -| x, marker, Theme.withFg(ground, if (b.current) pal.green else pal.fg));
                x += ui.putStr(x, y, end -| x, " ", ground);
                var ns = Theme.withFg(ground, pal.fg);
                ns.bold = b.current;
                _ = ui.putStr(x, y, end -| x, b.shown, ns);
            },
            .remote => |m| {
                var x: u16 = x0 + @as(u16, if (m.in_folder) 5 else 3);
                x += ui.putStr(x, y, end -| x, if (ui.ascii) "~ " else glyph_remote ++ " ", Theme.withFg(ground, pal.blue));
                _ = ui.putStr(x, y, end -| x, m.shown, Theme.withFg(ground, pal.fg));
            },
            .pr => |pr| {
                var x = x0 + 3;
                const marker: []const u8 = if (pr.current) (if (ui.ascii) "*" else glyph_current) else (if (ui.ascii) "o" else glyph_other);
                x += ui.putStr(x, y, end -| x, marker, Theme.withFg(ground, pal.fg));
                x += ui.putStr(x, y, end -| x, " ", ground);
                const num = ui.fmt("#{d}", .{pr.number});
                x += ui.putStr(x, y, end -| x, num, Theme.withFg(ground, pal.fg));
                x += ui.putStr(x, y, end -| x, " ", ground);
                var ts = Theme.withFg(ground, pal.fg);
                ts.bold = pr.current;
                _ = ui.putStr(x, y, end -| x, ui.clipStr(pr.title, end -| x), ts);
            },
        }
        if (row != .gap) ui.hit(rr, .{ .row = .{ .panel = .git, .idx = @intCast(idx) } });
        y += 1;
    }

    // The scrollbar over the rows' right edge, only when they overflow.
    if (out.total_items > out.body_rows and w >= 4 and area.h > 2) {
        const sb = Rect.init(area.right() - 1, area.y + 2, 1, area.h - 2);
        scrollbar.drawVertical(ui, sb, .{ .panel = .git }, out.total_items, out.body_rows, p.scroll);
    }
    return out;
}

/// Rust's `group_by_folder`: names with a `/` grouped under their first
/// segment (folders A–Z), the rest as one root group last. Each group
/// lists indices into `names`.
pub const Group = struct { folder: []const u8, idxs: []const u32 };

pub fn groupByFolder(arena: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error![]Group {
    const Folder = struct { name: []const u8, idxs: std.ArrayListUnmanaged(u32) };
    var folders: std.ArrayListUnmanaged(Folder) = .empty;
    var roots: std.ArrayListUnmanaged(u32) = .empty;
    for (names, 0..) |n, i| {
        if (std.mem.indexOfScalar(u8, n, '/')) |slash| {
            const folder = n[0..slash];
            var found = false;
            for (folders.items) |*f| if (std.mem.eql(u8, f.name, folder)) {
                try f.idxs.append(arena, @intCast(i));
                found = true;
            };
            if (!found) {
                var list: std.ArrayListUnmanaged(u32) = .empty;
                try list.append(arena, @intCast(i));
                try folders.append(arena, .{ .name = folder, .idxs = list });
            }
        } else try roots.append(arena, @intCast(i));
    }
    const Ctx = struct {
        fn lt(_: void, a: Folder, b: Folder) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };
    std.mem.sort(Folder, folders.items, {}, Ctx.lt);
    var out: std.ArrayListUnmanaged(Group) = .empty;
    for (folders.items) |f| try out.append(arena, .{ .folder = f.name, .idxs = f.idxs.items });
    if (roots.items.len > 0) try out.append(arena, .{ .folder = "", .idxs = roots.items });
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

/// The row's text up to the scrollbar's column (its thumb sits at the
/// right edge of every overflowing row).
fn expectRowStart(f: *Fixture, y: u16, prefix: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const row = f.row(y, &buf);
    if (!std.mem.startsWith(u8, row, prefix)) {
        std.debug.print("row {d}: {s}\n", .{ y, row });
        return error.TestExpectedEqual;
    }
}

const spec_rows = [_]Row{
    .{ .section = .{ .s = .worktrees, .count = 1, .collapsed = false } },
    .{ .worktree = .{ .idx = 0, .shown = "main (ws)", .current = true } },
    .gap,
    .{ .section = .{ .s = .local, .count = 2, .collapsed = false } },
    .{ .branch = .{ .idx = 0, .shown = "feature", .name = "feature", .current = false, .in_folder = false } },
    .{ .branch = .{ .idx = 1, .shown = "main", .name = "main", .current = true, .in_folder = false } },
    .gap,
};

test "the spec's sidebar, rows 2–13 at 20 wide: the header, the pill, the branch, the filter, WORKTREES then LOCAL with their counts at the edge; every row a hit" {
    var f = try Fixture.init(20, 14);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .rows = &spec_rows, .repo = "ws", .branch = "main", .scroll = 0 });
    try f.expectRow(0, " GIT              \u{eb37}");
    try f.expectRow(1, "  ws \u{F0140}");
    try f.expectRow(2, " \u{2387} main");
    try f.expectRow(3, "");
    try f.expectRow(4, " \u{F0349} / filter");
    try f.expectRow(5, "");
    try f.expectRow(6, " \u{25BE} WORKTREES     1");
    try f.expectRow(7, "   \u{2302} main (ws)");
    try f.expectRow(8, "");
    try f.expectRow(9, " \u{25BE} LOCAL         2");
    try f.expectRow(10, "   \u{25CB} feature");
    try f.expectRow(11, "   \u{25CF} main");
    try f.expectRow(12, "");
    try f.expectRow(13, "");
    // The pill is a hit over its cells only; the branch row is one across.
    try testing.expectEqual(Part.repo, f.hits.at(3, 1).?.git_palette);
    try testing.expect(f.hits.at(8, 1) == null);
    try testing.expectEqual(Part.branch, f.hits.at(15, 2).?.git_palette);
    try testing.expectEqual(@import("hit.zig").PanelId.git, f.hits.at(10, 4).?.filter_input);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 6).?.row.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 7).?.row.idx);
    try testing.expect(f.hits.at(5, 8) == null);
    try testing.expectEqual(@as(u32, 4), f.hits.at(5, 10).?.row.idx);
    try testing.expectEqual(@as(u32, 5), f.hits.at(19, 11).?.row.idx);
    // The refresh chip on the header, the count in cyan, the pill on bg2.
    try testing.expectEqual(@import("hit.zig").ChipKind.refresh, f.hits.at(18, 0).?.chip.kind);
    try testing.expect(f.fgEql(17, 6, .{ .fg = f.theme.palette.cyan }));
    try testing.expect(f.bgEql(2, 1, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(1, 4, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(19, 4, f.theme.panel_bg));
    try testing.expect(f.fgEql(3, 11, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.style(5, 11).bold);
    try testing.expect(!f.style(5, 10).bold);
}

test "a selected branch and the focused cursor row carry bg2 from the second cell; the ahead / behind counts follow the branch; a filter shows its text and a focused caret" {
    var f = try Fixture.init(20, 14);
    defer f.deinit();
    var ui = f.ui();
    ui.focus = .{ .panel = .git };
    _ = draw(ui, f.full(), .{ .rows = &spec_rows, .repo = "ws", .branch = "main", .ahead = 2, .behind = 1, .selected = "feature", .cursor = 5, .filter = "ma", .filter_focused = true, .scroll = 0 });
    try f.expectRow(2, " \u{2387} main  \u{2191}2  \u{2193}1");
    try f.expectRow(4, " \u{F0349} ma\u{258F}");
    try testing.expect(f.bgEql(0, 10, f.theme.panel_bg));
    try testing.expect(f.bgEql(1, 10, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(19, 10, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(1, 11, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(1, 7, f.theme.panel_bg));
}

test "the scroll skips item rows and keeps the headers; the scrollbar appears only on overflow; a folder groups its branches" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    try rows.append(arena, .{ .section = .{ .s = .local, .count = 12, .collapsed = false } });
    try rows.append(arena, .{ .folder = .{ .s = .local, .name = "bugfix", .count = 2, .collapsed = false } });
    try rows.append(arena, .{ .branch = .{ .idx = 0, .shown = "one", .name = "bugfix/one", .current = false, .in_folder = true } });
    try rows.append(arena, .{ .branch = .{ .idx = 1, .shown = "two", .name = "bugfix/two", .current = false, .in_folder = true } });
    var i: u32 = 2;
    while (i < 12) : (i += 1) try rows.append(arena, .{ .branch = .{ .idx = i, .shown = try std.fmt.allocPrint(arena, "b{d:0>2}", .{i}), .name = "x", .current = false, .in_folder = false } });
    var f = try Fixture.init(20, 12);
    defer f.deinit();
    var p = draw(f.ui(), f.full(), .{ .rows = rows.items, .repo = "r", .branch = null, .scroll = 0 });
    try testing.expectEqual(@as(usize, 12), p.total_items);
    try testing.expectEqual(@as(usize, 10), p.body_rows);
    try f.expectRow(1, "  r \u{F0140}");
    // The scrollbar runs from the branch row down (Rust's `area.y + 2`).
    try expectRowStart(&f, 2, " \u{2387} (no branch)");
    try expectRowStart(&f, 7, "  \u{25BE} bugfix  (2)");
    try expectRowStart(&f, 8, "     \u{25CB} one");
    try testing.expect(f.hits.at(19, 8).?.scrollbar.owner.panel == .git);
    p = draw(f.ui(), f.full(), .{ .rows = rows.items, .repo = "r", .branch = null, .scroll = 3 });
    try expectRowStart(&f, 6, " \u{25BE} LOCAL        12");
    try expectRowStart(&f, 7, "  \u{25BE} bugfix  (2)");
    try expectRowStart(&f, 8, "   \u{25CB} b03");
    try testing.expectEqual(@as(u32, 5), f.hits.at(5, 8).?.row.idx);
    const groups = try groupByFolder(arena, &.{ "main", "bugfix/foo", "bugfix/bar", "chore/x", "develop" });
    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("bugfix", groups[0].folder);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, groups[0].idxs);
    try testing.expectEqualStrings("chore", groups[1].folder);
    try testing.expectEqualStrings("", groups[2].folder);
    try testing.expectEqualSlices(u32, &.{ 0, 4 }, groups[2].idxs);
}
