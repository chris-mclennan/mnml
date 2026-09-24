//! The staging view (`Pane.git_status`) — the Rust editor's
//! `git_status_view.rs` cell for cell (`docs/ui-spec/rust-git-status-*.txt`):
//!
//! ```text
//!   on main   2 unstaged · 0 staged                                          █
//!   s/u stage·unstage  space toggle  a/A all  ⏎ diff  c commit  C ai-commit  r refresh
//!   Unstaged changes (2)                                                     █
//!   ▶ ? .gitignore                                                           █
//!     ? requests/                                                            █
//!                                                                            █
//!   Staged changes (0)                                                       █
//!     (none)                                                                 █
//! ```
//!
//! Two sections — a third, `⚠ Conflicts (N)`, leads while the status
//! lists `U` entries — the cursor row's text on the `bg2` band with a `▶`,
//! and a one-cell scrollbar on the right whenever the pane is at
//! least eight cells wide and lists something. The hint row is clipped
//! at the pane's edge, never dropped word by word (`rust-git-status-80x24`).
//! Every entry row is a `.script_hit{ pane, id = flat index }`; every
//! hint word is a `.script_hit{ pane, id = hintId(action) }`, so a click
//! on `s` stages the cursor's file the way the key does.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const scrollbar = @import("scrollbar.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const Color = vaxis.Color;
const PaneId = ids.PaneId;

/// A file the pane lists: its porcelain letter (`M A D R C U ?`) and
/// which section it sits in. A file changed on both sides is one
/// entry per section.
pub const Entry = struct { path: []const u8, letter: u8, staged: bool };

pub const Doc = struct {
    /// The checked-out branch; null when HEAD is on none.
    branch: ?[]const u8,
    /// A detached HEAD in git's words (`HEAD detached at v0.1`), painted
    /// in place of `on <branch>`.
    detached_label: ?[]const u8 = null,
    unstaged: []const Entry,
    staged: []const Entry,
    /// Flat index: the unstaged entries, then the staged.
    cursor: usize,
    /// An AI commit message is on its way: the hint row says so.
    ai_pending: bool = false,
    /// The vim profile: Space is the leader there, so the toggle is
    /// fugitive's `-` and the hint row says so.
    vim: bool = false,
};

/// What a hint word does; the keys share the table.
pub const Action = enum(u8) { stage, unstage, toggle, stage_all, unstage_all, diff, commit, ai_commit, refresh };

/// Hint ids sit above any flat row index.
pub const hint_base: u32 = 0xF000_0100;
const action_count: u32 = @typeInfo(Action).@"enum".fields.len;

pub fn hintId(a: Action) u32 {
    return hint_base + @intFromEnum(a);
}

pub fn hintOf(id: u32) ?Action {
    if (id < hint_base or id >= hint_base + action_count) return null;
    return @enumFromInt(id - hint_base);
}

/// One painted row of the pane, top to bottom.
pub const Line = union(enum) {
    header,
    hint,
    blank,
    clean,
    section: struct { staged: bool, count: usize, conflicts: bool = false },
    none,
    entry: struct { flat: usize, e: Entry },
};

/// Rust's `lines`: header, hint, then either the clean note or the
/// two sections, each `(none)` when empty, a blank row between them.
pub fn lines(arena: Allocator, doc: Doc) Allocator.Error![]const Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    try out.append(arena, .header);
    try out.append(arena, .hint);
    if (doc.unstaged.len + doc.staged.len == 0) {
        try out.append(arena, .blank);
        try out.append(arena, .clean);
        return out.items;
    }
    // Conflicted entries (`U`) lead in a section of their own — enter
    // opens the editor on them, not a diff — keeping their flat index.
    var conflicts: usize = 0;
    for (doc.unstaged) |e| if (e.letter == 'U') {
        conflicts += 1;
    };
    if (conflicts > 0) {
        try out.append(arena, .{ .section = .{ .staged = false, .count = conflicts, .conflicts = true } });
        for (doc.unstaged, 0..) |e, i| if (e.letter == 'U') try out.append(arena, .{ .entry = .{ .flat = i, .e = e } });
        try out.append(arena, .blank);
    }
    try out.append(arena, .{ .section = .{ .staged = false, .count = doc.unstaged.len - conflicts } });
    if (doc.unstaged.len == conflicts) try out.append(arena, .none);
    for (doc.unstaged, 0..) |e, i| if (e.letter != 'U') try out.append(arena, .{ .entry = .{ .flat = i, .e = e } });
    try out.append(arena, .blank);
    try out.append(arena, .{ .section = .{ .staged = true, .count = doc.staged.len } });
    if (doc.staged.len == 0) try out.append(arena, .none);
    for (doc.staged, 0..) |e, i| try out.append(arena, .{ .entry = .{ .flat = doc.unstaged.len + i, .e = e } });
    return out.items;
}

/// The row holding the cursor's entry; 0 when there is none.
pub fn cursorLine(ls: []const Line, cursor: usize) usize {
    for (ls, 0..) |l, i| switch (l) {
        .entry => |e| if (e.flat == cursor) return i,
        else => {},
    };
    return 0;
}

/// Rust's scroll rule: the cursor's row is pulled into the `h`-row
/// window, then the window is clamped to the end.
pub fn scrollTo(scroll: *usize, cursor_row: usize, total: usize, h: usize) void {
    if (cursor_row < scroll.*) {
        scroll.* = cursor_row;
    } else if (cursor_row >= scroll.* + h) {
        scroll.* = cursor_row + 1 - h;
    }
    const max_scroll = total - @min(h, total);
    if (scroll.* > max_scroll) scroll.* = max_scroll;
}

/// Rust paints a scrollbar column from eight cells up.
pub const min_scrollbar_width: u16 = 8;

const Seg = struct { text: []const u8, action: ?Action };

// The hint row, word by word, so each word can be a hit.
const hint_segs = [_]Seg{
    .{ .text = "  ", .action = null },
    .{ .text = "s", .action = .stage },
    .{ .text = "/", .action = null },
    .{ .text = "u", .action = .unstage },
    .{ .text = " ", .action = null },
    .{ .text = "stage", .action = .stage },
    .{ .text = "\u{B7}", .action = null },
    .{ .text = "unstage", .action = .unstage },
    .{ .text = "  ", .action = null },
    .{ .text = "space toggle", .action = .toggle },
    .{ .text = "  ", .action = null },
    .{ .text = "a", .action = .stage_all },
    .{ .text = "/", .action = null },
    .{ .text = "A", .action = .unstage_all },
    .{ .text = " all", .action = null },
    .{ .text = "  ", .action = null },
    .{ .text = "\u{23CE} diff", .action = .diff },
    .{ .text = "  ", .action = null },
    .{ .text = "c commit", .action = .commit },
    .{ .text = "  ", .action = null },
    .{ .text = "C ai-commit", .action = .ai_commit },
    .{ .text = "  ", .action = null },
    .{ .text = "r refresh", .action = .refresh },
};
const ascii_enter = "enter diff";
const vim_toggle = "- toggle";
const ai_hint = "  \u{2726} asking Claude for a commit message\u{2026}";
const ai_hint_ascii = "  * asking Claude for a commit message...";
const clean_note = "  \u{2713} working tree clean";
const clean_note_ascii = "  v working tree clean";

/// The letter's colour: added green, modified yellow, deleted red,
/// renamed blue, copied cyan, a conflict red, untracked muted.
pub fn letterColor(p: Theme.Palette, letter: u8) Color {
    return switch (letter) {
        'A' => p.green,
        'M' => p.yellow,
        'D' => p.red,
        'R' => p.blue,
        'C' => p.cyan,
        'U' => p.red,
        else => p.comment,
    };
}

/// Paints the pane and registers its hits; `scroll` is the pane's own
/// and follows the cursor.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, doc: Doc, scroll: *usize) void {
    const p = ui.theme.palette;
    const ground: Style = .{ .bg = p.bg_dark };
    ui.fill(area, ground);
    if (area.isEmpty()) return;
    const n = doc.unstaged.len + doc.staged.len;
    const sb_w: u16 = if (area.w >= min_scrollbar_width) 1 else 0;
    const body = Rect.init(area.x, area.y, area.w - sb_w, area.h);
    // The text stops a cell short of the bar; a row's hit reaches it.
    const text = Rect.init(body.x, body.y, body.w -| sb_w, body.h);
    const ls = lines(ui.arena, doc) catch return;
    const h: usize = area.h;
    if (n == 0) {
        // Rust paints the four rows from the top and no scrollbar.
        for (ls, 0..) |l, i| {
            if (i >= h) break;
            paintLine(ui, pane, text.row(@intCast(i)), doc, l);
        }
        return;
    }
    scrollTo(scroll, cursorLine(ls, doc.cursor), ls.len, h);
    var y: u16 = 0;
    var i = scroll.*;
    while (i < ls.len and y < h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        paintLine(ui, pane, text.row(y), doc, ls[i]);
        switch (ls[i]) {
            .entry => |e| ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(e.flat) } }),
            else => {},
        }
    }
    if (sb_w > 0) scrollbar.drawVertical(ui, Rect.init(area.right() - 1, area.y, 1, area.h), .{ .pane = pane }, ls.len, h, scroll.*);
}

fn paintLine(ui: Ui, pane: PaneId, r: Rect, doc: Doc, l: Line) void {
    const p = ui.theme.palette;
    const comment: Style = .{ .fg = p.comment, .bg = p.bg_dark };
    const end = r.right();
    var x = r.x;
    switch (l) {
        .header => {
            if (doc.branch) |b| {
                x += ui.putStr(x, r.y, end -| x, "  on ", comment);
                x += ui.putStr(x, r.y, end -| x, b, .{ .fg = p.blue, .bg = p.bg_dark, .bold = true });
            } else {
                x += ui.putStr(x, r.y, end -| x, "  ", comment);
                x += ui.putStr(x, r.y, end -| x, doc.detached_label orelse "no branch", .{ .fg = p.blue, .bg = p.bg_dark, .bold = true });
            }
            _ = ui.putStr(x, r.y, end -| x, ui.fmt("   {d} unstaged \u{B7} {d} staged", .{ doc.unstaged.len, doc.staged.len }), comment);
        },
        .hint => {
            if (doc.ai_pending) {
                _ = ui.putStr(x, r.y, end -| x, if (ui.ascii) ai_hint_ascii else ai_hint, comment);
                return;
            }
            for (hint_segs) |seg| {
                if (x >= end) break;
                const text = if (ui.ascii and seg.action == .diff) ascii_enter else if (doc.vim and seg.action == .toggle) vim_toggle else seg.text;
                const w = ui.putStr(x, r.y, end -| x, text, comment);
                if (seg.action) |a| ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hintId(a) } });
                x += w;
            }
        },
        .blank => {},
        .clean => _ = ui.putStr(x, r.y, end -| x, if (ui.ascii) clean_note_ascii else clean_note, .{ .fg = p.green, .bg = p.bg_dark }),
        .section => |s| {
            if (s.conflicts) {
                const label = ui.fmt("  {s} Conflicts ({d})  \u{23CE} resolve in the editor", .{ if (ui.ascii) "!" else "\u{26A0}", s.count });
                _ = ui.putStr(x, r.y, end -| x, label, .{ .fg = p.red, .bg = p.bg_dark, .bold = true });
                return;
            }
            const label = ui.fmt("  {s} changes ({d})", .{ if (s.staged) "Staged" else "Unstaged", s.count });
            _ = ui.putStr(x, r.y, end -| x, label, .{ .fg = if (s.staged) p.green else p.yellow, .bg = p.bg_dark, .bold = true });
        },
        .none => _ = ui.putStr(x, r.y, end -| x, "    (none)", comment),
        .entry => |e| {
            const sel = e.flat == doc.cursor;
            const bg = if (sel) p.bg2 else p.bg_dark;
            const marker: []const u8 = if (!sel) "    " else if (ui.ascii) "  > " else "  \u{25B6} ";
            x += ui.putStr(x, r.y, end -| x, marker, .{ .fg = p.yellow, .bg = bg });
            x += ui.putStr(x, r.y, end -| x, ui.fmt("{c} ", .{e.e.letter}), .{ .fg = letterColor(p, e.e.letter), .bg = bg, .bold = true });
            _ = ui.putStr(x, r.y, end -| x, e.e.path, .{ .fg = p.fg, .bg = bg });
        },
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const fixture_unstaged = [_]Entry{
    .{ .path = ".gitignore", .letter = '?', .staged = false },
    .{ .path = "requests/", .letter = '?', .staged = false },
};

fn fixtureDoc() Doc {
    return .{ .branch = "main", .unstaged = &fixture_unstaged, .staged = &.{}, .cursor = 0 };
}

// `docs/ui-spec/rust-git-status-120x40.txt`, rows 3..10, columns 31..120
// (the pane is 89 cells): the text, then the scrollbar's `█` on the last.
const spec_rows = [_][]const u8{
    "  on main   2 unstaged \u{B7} 0 staged",
    "  s/u stage\u{B7}unstage  space toggle  a/A all  \u{23CE} diff  c commit  C ai-commit  r refresh",
    "  Unstaged changes (2)",
    "  \u{25B6} ? .gitignore",
    "    ? requests/",
    "",
    "  Staged changes (0)",
    "    (none)",
};

/// `text` padded to `w - 1` cells with the scrollbar glyph on the last.
fn withBar(arena: Allocator, text: []const u8, w: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, text);
    var cells = std.unicode.utf8CountCodepoints(text) catch text.len;
    while (cells < w - 1) : (cells += 1) try out.append(arena, ' ');
    try out.appendSlice(arena, "\u{2588}");
    return out.items;
}

test "lines: the two sections with (none) for an empty one; the clean note when nothing changed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ls = try lines(arena, fixtureDoc());
    try testing.expectEqual(@as(usize, 8), ls.len);
    try testing.expect(ls[0] == .header and ls[1] == .hint);
    try testing.expectEqual(@as(usize, 2), ls[2].section.count);
    try testing.expect(!ls[2].section.staged);
    try testing.expectEqual(@as(usize, 1), ls[4].entry.flat);
    try testing.expect(ls[5] == .blank and ls[6].section.staged and ls[7] == .none);
    try testing.expectEqual(@as(usize, 4), cursorLine(ls, 1));
    try testing.expectEqual(@as(usize, 0), cursorLine(ls, 9));

    const staged = [_]Entry{.{ .path = "a.zig", .letter = 'A', .staged = true }};
    const both = try lines(arena, .{ .branch = "main", .unstaged = &fixture_unstaged, .staged = &staged, .cursor = 2 });
    try testing.expectEqual(@as(usize, 8), both.len);
    try testing.expectEqual(@as(usize, 2), both[7].entry.flat);
    try testing.expectEqual(@as(usize, 7), cursorLine(both, 2));

    const clean = try lines(arena, .{ .branch = "main", .unstaged = &.{}, .staged = &.{}, .cursor = 0 });
    try testing.expectEqual(@as(usize, 4), clean.len);
    try testing.expect(clean[2] == .blank and clean[3] == .clean);
}

test "draw: the spec's rows cell for cell at 89 wide, every entry and hint word a hit, the scrollbar on the edge" {
    var f = try Fixture.init(89, 9);
    defer f.deinit();
    var scroll: usize = 0;
    draw(f.ui(), 3, Rect.init(0, 0, 89, 9), fixtureDoc(), &scroll);
    const arena = f.arena_state.allocator();
    for (spec_rows, 0..) |want, y| try f.expectRow(@intCast(y), try withBar(arena, want, 89));
    try f.expectRow(8, try withBar(arena, "", 89));
    // Entry rows carry their flat index across the body.
    try testing.expectEqual(@as(u32, 0), f.hits.at(2, 3).?.script_hit.id);
    try testing.expectEqual(@as(u32, 1), f.hits.at(60, 4).?.script_hit.id);
    try testing.expectEqual(@as(PaneId, 3), f.hits.at(60, 4).?.script_hit.pane);
    try testing.expect(f.hits.at(60, 2) == null);
    try testing.expect(f.hits.at(60, 0) == null);
    // The hint words: `s` `u` `stage` `unstage` `space toggle` `a` `A`
    // `⏎ diff` `c commit` `C ai-commit` `r refresh`; the separators none.
    try testing.expectEqual(hintId(.stage), f.hits.at(2, 1).?.script_hit.id);
    try testing.expect(f.hits.at(3, 1) == null);
    try testing.expectEqual(hintId(.unstage), f.hits.at(4, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.stage), f.hits.at(8, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.unstage), f.hits.at(15, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.toggle), f.hits.at(25, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.stage_all), f.hits.at(35, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.unstage_all), f.hits.at(37, 1).?.script_hit.id);
    try testing.expect(f.hits.at(40, 1) == null);
    try testing.expectEqual(hintId(.diff), f.hits.at(44, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.commit), f.hits.at(53, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.ai_commit), f.hits.at(63, 1).?.script_hit.id);
    try testing.expectEqual(hintId(.refresh), f.hits.at(78, 1).?.script_hit.id);
    try testing.expectEqual(@as(?Action, .refresh), hintOf(hintId(.refresh)));
    try testing.expectEqual(@as(?Action, null), hintOf(1));
    try testing.expectEqual(@as(?Action, null), hintOf(hint_base + action_count));
    const sb = f.hits.at(88, 5).?;
    try testing.expect(sb == .scrollbar);
    try testing.expectEqual(@as(PaneId, 3), sb.scrollbar.owner.pane);
    // Colours: the cursor's text on bg2 and only its text; the branch
    // blue and bold; the section headers yellow / green; `?` muted.
    try testing.expect(f.bgEql(2, 3, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(15, 3, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(16, 3, .{ .bg = f.theme.palette.bg_dark }));
    try testing.expect(f.bgEql(4, 4, .{ .bg = f.theme.palette.bg_dark }));
    try testing.expect(f.fgEql(5, 0, .{ .fg = f.theme.palette.blue }));
    try testing.expect(f.style(5, 0).bold);
    try testing.expect(f.fgEql(2, 2, .{ .fg = f.theme.palette.yellow }));
    try testing.expect(f.fgEql(2, 6, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(4, 3, .{ .fg = f.theme.palette.comment }));
    try testing.expect(f.fgEql(2, 3, .{ .fg = f.theme.palette.yellow }));
}

test "conflicted entries lead in their own section and keep their flat index; the rest of the sections are as before" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mixed = [_]Entry{
        .{ .path = "m.zig", .letter = 'M', .staged = false },
        .{ .path = "c.zig", .letter = 'U', .staged = false },
    };
    const ls = try lines(arena, .{ .branch = "main", .unstaged = &mixed, .staged = &.{}, .cursor = 1 });
    // header, hint, Conflicts, c.zig, blank, Unstaged, m.zig, blank, Staged, (none)
    try testing.expectEqual(@as(usize, 10), ls.len);
    try testing.expect(ls[2].section.conflicts);
    try testing.expectEqual(@as(usize, 1), ls[2].section.count);
    try testing.expectEqual(@as(usize, 1), ls[3].entry.flat);
    try testing.expect(!ls[5].section.conflicts);
    try testing.expectEqual(@as(usize, 1), ls[5].section.count);
    try testing.expectEqual(@as(usize, 0), ls[6].entry.flat);
    try testing.expectEqual(@as(usize, 3), cursorLine(ls, 1));
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    var scroll: usize = 0;
    draw(f.ui(), 1, f.full(), .{ .branch = "main", .unstaged = &mixed, .staged = &.{}, .cursor = 1 }, &scroll);
    try f.expectRow(2, try withBar(arena, "  \u{26A0} Conflicts (1)  \u{23CE} resolve in the editor", 60));
    try f.expectRow(3, try withBar(arena, "  \u{25B6} U c.zig", 60));
    try f.expectRow(5, try withBar(arena, "  Unstaged changes (1)", 60));
    try f.expectRow(6, try withBar(arena, "    M m.zig", 60));
    try testing.expect(f.fgEql(2, 2, .{ .fg = f.theme.palette.red }));
    try testing.expectEqual(@as(u32, 1), f.hits.at(6, 3).?.script_hit.id);
    try testing.expectEqual(@as(u32, 0), f.hits.at(6, 6).?.script_hit.id);
}

test "draw at 49 wide (rust-git-status-80x24) clips the hint row at the edge and keeps the scrollbar" {
    var f = try Fixture.init(49, 8);
    defer f.deinit();
    var scroll: usize = 0;
    draw(f.ui(), 1, Rect.init(0, 0, 49, 8), fixtureDoc(), &scroll);
    const arena = f.arena_state.allocator();
    try f.expectRow(0, try withBar(arena, "  on main   2 unstaged \u{B7} 0 staged", 49));
    try f.expectRow(1, try withBar(arena, "  s/u stage\u{B7}unstage  space toggle  a/A all  \u{23CE} d", 49));
    try f.expectRow(3, try withBar(arena, "  \u{25B6} ? .gitignore", 49));
    // The clipped `⏎ di` is still the diff hit; the words past the
    // edge are not registered.
    try testing.expectEqual(hintId(.diff), f.hits.at(46, 1).?.script_hit.id);
    var found = false;
    for (f.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.id == hintId(.commit)) {
        found = true;
    };
    try testing.expect(!found);
}

test "draw: the letter colours; a narrow pane has no scrollbar; ASCII twins" {
    var f = try Fixture.init(7, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const mixed = [_]Entry{
        .{ .path = "m.zig", .letter = 'M', .staged = false },
        .{ .path = "d.zig", .letter = 'D', .staged = false },
    };
    const staged = [_]Entry{.{ .path = "a.zig", .letter = 'A', .staged = true }};
    draw(f.ui(), 1, f.full(), .{ .branch = null, .detached_label = "HEAD detached at v0.1", .unstaged = &mixed, .staged = &staged, .cursor = 2 }, &scroll);
    try f.expectRow(0, "  HEAD");
    try f.expectRow(3, "    M m");
    try f.expectRow(7, "  \u{25B6} A a");
    try testing.expect(f.fgEql(4, 3, .{ .fg = f.theme.palette.yellow }));
    try testing.expect(f.fgEql(4, 4, .{ .fg = f.theme.palette.red }));
    try testing.expect(f.fgEql(4, 7, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.hits.at(6, 5) == null);
    var g = try Fixture.init(60, 4);
    defer g.deinit();
    g.ascii = true;
    draw(g.ui(), 1, g.full(), .{ .branch = "main", .unstaged = &.{}, .staged = &.{}, .cursor = 0, .ai_pending = true }, &scroll);
    try g.expectRow(1, ai_hint_ascii);
    try g.expectRow(3, clean_note_ascii);
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);
    draw(g.ui(), 1, g.full(), .{ .branch = "main", .unstaged = &mixed, .staged = &.{}, .cursor = 1 }, &scroll);
    try g.expectContains("enter diff");
    try g.expectRow(3, "  > D d.zig                                                |");
}

test "draw: the clean state paints the note and no scrollbar; the cursor row scrolls into view" {
    var f = try Fixture.init(40, 6);
    defer f.deinit();
    var scroll: usize = 0;
    draw(f.ui(), 1, f.full(), .{ .branch = "main", .unstaged = &.{}, .staged = &.{}, .cursor = 0 }, &scroll);
    try f.expectRow(0, "  on main   0 unstaged \u{B7} 0 staged");
    try f.expectRow(2, "");
    try f.expectRow(3, clean_note);
    try testing.expect(f.fgEql(2, 3, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.hits.at(39, 3) == null);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var many: [12]Entry = undefined;
    for (&many, 0..) |*e, i| e.* = .{ .path = try std.fmt.allocPrint(arena, "f{d}.zig", .{i}), .letter = 'M', .staged = false };
    // 12 entries + header, hint, section = 15 rows before the blank;
    // the cursor on the last entry (row 14) puts the window at 9..15.
    draw(f.ui(), 1, f.full(), .{ .branch = "main", .unstaged = &many, .staged = &.{}, .cursor = 11 }, &scroll);
    try testing.expectEqual(@as(usize, 9), scroll);
    try f.expectRow(0, "    M f6.zig                           \u{2588}");
    try f.expectRow(5, "  \u{25B6} M f11.zig                          \u{2588}");
    try testing.expectEqual(@as(u32, 11), f.hits.at(3, 5).?.script_hit.id);
    // Back to the top: the window follows the cursor up, its row first.
    draw(f.ui(), 1, f.full(), .{ .branch = "main", .unstaged = &many, .staged = &.{}, .cursor = 0 }, &scroll);
    try testing.expectEqual(@as(usize, 3), scroll);
    try f.expectRow(0, "  \u{25B6} M f0.zig                           \u{2588}");
}

test "scrollTo: pulls the cursor row in from either side and clamps to the end" {
    var s: usize = 0;
    scrollTo(&s, 7, 20, 5);
    try testing.expectEqual(@as(usize, 3), s);
    scrollTo(&s, 1, 20, 5);
    try testing.expectEqual(@as(usize, 1), s);
    s = 30;
    scrollTo(&s, 19, 20, 5);
    try testing.expectEqual(@as(usize, 15), s);
    s = 4;
    scrollTo(&s, 2, 3, 10);
    try testing.expectEqual(@as(usize, 0), s);
}
