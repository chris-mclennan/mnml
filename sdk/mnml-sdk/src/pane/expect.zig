//! The assertions an integration's OWN tests make about the shared
//! chrome.
//!
//! `consistency_test.zig` proves the toolkit paints the same thing from
//! two different target vocabularies. It cannot prove a pane CALLS the
//! toolkit — and that is the drift that actually happens: a pane grows
//! its own caps title, its own chip ladder, its own fold row, and
//! nothing notices because the toolkit is still perfectly consistent
//! with itself.
//!
//! So the check lives here, where both integrations import it from, and
//! each pane's own test suite points it at its own painted frame. Two
//! families checking one expectation, rather than two families each
//! checking whatever their own test happened to be written against.

const std = @import("std");
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const chrome = @import("chrome.zig");
const action = @import("action.zig");
const hit = @import("hit.zig");
const figure = @import("figure.zig");
const text_mod = @import("text.zig");

pub const Frame = frame_mod.Frame;
pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;

pub const Error = figure.Error || error{
    TitleInk,
    LadderMissing,
    LadderOrder,
    LadderInk,
    BarMissing,
    BarThumbMissing,
    BarTrackMissing,
    FoldRowMissing,
    FoldRowSplit,
    FoldRowInk,
    BuildHitMissing,
    BuildHitPartial,
    GutterBroken,
    GutterInk,
    ActionRunMissing,
    ActionRunOrder,
    ActionRunWidth,
    ActionRunShape,
    ActionRunBlank,
    HeaderNameMissing,
    HeaderNamesRunTogether,
    HeaderInk,
};

fn eqlStyle(a: Style, b: Style) bool {
    return std.meta.eql(a.fg, b.fg) and std.meta.eql(a.bg, b.bg) and std.meta.eql(a.mods, b.mods);
}

/// Foreground and attributes only. The GROUND under a word belongs to
/// whatever is behind it — the pane's own background, a filled cursor
/// row — and a style with a null `bg` takes the one already on the
/// cell, so comparing grounds here would only ever be comparing what
/// the row was sitting on.
fn eqlInk(a: Style, b: Style) bool {
    return std.meta.eql(a.fg, b.fg) and std.meta.eql(a.mods, b.mods);
}

/// The caps title on row `y` starts at `x0` and is painted in
/// `Theme.label()` — muted and bold, the same in every family.
///
/// A pane that paints its title in its accent reads as a different
/// application from the pane beside it, which is the one thing the
/// toolkit exists to prevent.
pub fn capsTitleInk(f: *const Frame, th: Theme, x0: u16, y: u16, title: []const u8) Error!void {
    const want = th.label();
    var i: u16 = 0;
    while (i < text_mod.width(title)) : (i += 1) {
        const got = f.slots[@as(usize, y) * f.cols + x0 + i].style;
        if (!eqlInk(got, want)) return Error.TitleInk;
    }
}

/// The row at `y` carries EVERY one of `targets` as a button, left to
/// right, each a hit exactly as wide as the cells it painted, in the
/// form `form` says.
///
/// Three things at once, because they came apart together:
///
///  * the buttons are THERE. One pane dropped them whole below a
///    width, so at 80 columns the only row that could act could not;
///  * the form is the one the row can afford — one cell each when
///    tight, `[󰏌 Open]` when there is room — rather than a clipped
///    word or an empty margin;
///  * the hit is the painted cells. A button whose rect is wider than
///    its glyph eats the cell beside it; one that is narrower has a
///    dead edge the pointer falls through.
pub fn actionRun(
    comptime Target: type,
    f: *const Frame,
    m: *const hit.Map(Target),
    y: u16,
    targets: []const Target,
    form: action.Form,
) Error!void {
    var prev_right: u16 = 0;
    for (targets) |tg| {
        const r = m.rectOf(tg) orelse return Error.ActionRunMissing;
        if (r.y != y or r.isEmpty()) return Error.ActionRunMissing;
        if (r.x < prev_right) return Error.ActionRunOrder;
        prev_right = r.right();
        switch (form) {
            // One cell, and a glyph in it.
            .icon => {
                if (r.w != 1) return Error.ActionRunWidth;
                if (blank(f, r.x, y)) return Error.ActionRunBlank;
            },
            // `[…]`, and the cell the rect names really carries the
            // opening bracket.
            .icon_label => {
                if (r.w < 4) return Error.ActionRunWidth;
                if (!rowHas(f, y, r.x, "[")) return Error.ActionRunShape;
                if (!rowHas(f, y, r.right() - 1, "]")) return Error.ActionRunShape;
                // The cell after the bracket is the kind's glyph, not
                // air: `[ Open ]` without one would pass the shape
                // check and say nothing about the icon.
                if (blank(f, r.x + 1, y)) return Error.ActionRunBlank;
            },
        }
        // The hit stops where the paint does: the cell past the
        // button is air or the next button's, never this one's.
        if (m.at(r.x, y) == null) return Error.ActionRunMissing;
    }
}

fn blank(f: *const Frame, x: u16, y: u16) bool {
    const sym = f.slots[@as(usize, y) * f.cols + x].symbol();
    return sym.len == 0 or std.mem.eql(u8, sym, " ") or std.mem.eql(u8, sym, "\x00");
}

/// The app-colour stripe down column `x`, unbroken from `y0` for `h`
/// rows, in one of the gutter's two inks.
///
/// It is the pane's identity and the only column that says which
/// application you are looking at, so a pane that loses it halfway
/// down reads as two panes stacked. The tracker pane's board did
/// exactly that: the header rows wore the stripe, the kanban columns
/// then painted their own boxes straight over column 0, and every
/// card grew a little `▌` of its own as if the identity had moved
/// onto them. The board now starts one cell in.
pub fn gutterFullHeight(f: *const Frame, th: Theme, x: u16, y0: u16, h: u16, ascii: bool) Error!void {
    const g: []const u8 = if (ascii) chrome.gutter_ascii else chrome.gutter_glyph;
    const on = th.gutterOn();
    const off = th.gutterOff();
    var y = y0;
    while (y < y0 + h and y < f.rows) : (y += 1) {
        const slot = f.slots[@as(usize, y) * f.cols + x];
        if (!std.mem.eql(u8, slot.symbol(), g)) return Error.GutterBroken;
        if (!eqlInk(slot.style, on) and !eqlInk(slot.style, off)) return Error.GutterInk;
    }
}

/// The header ladder ends, right to left, in the refresh chip and then
/// `?` — both in `Theme.chip()`, both on row `y`, the `?` flush against
/// the pane's last usable column.
///
/// Right to left because that is how `Painter.rightChips` lays it: the
/// first chip in the slice is the one nearest the edge, and the two
/// every family carries go last so they are the two that survive a
/// narrow pane.
pub fn headerLadderTail(f: *const Frame, th: Theme, y: u16, nerd: bool, ascii: bool) Error!void {
    const help = chrome.help_chip_text;
    const refresh: []const u8 = if (ascii or !nerd) " " ++ chrome.refresh_ascii ++ " " else " " ++ chrome.refresh_nerd ++ " ";
    const hw = text_mod.width(help);
    const rw = text_mod.width(refresh);
    if (f.cols < hw + rw + 4) return;
    // `rightChips` leaves one cell of air past the last chip.
    const help_x = f.cols - hw - 1;
    const refresh_x = help_x - rw - 1;
    if (!rowHas(f, y, help_x, help)) return Error.LadderMissing;
    if (!rowHas(f, y, refresh_x, refresh)) return Error.LadderOrder;
    const want = th.chip();
    for ([_]u16{ help_x, refresh_x }) |x0| {
        var i: u16 = 0;
        while (i < 3) : (i += 1) {
            if (!eqlStyle(f.slots[@as(usize, y) * f.cols + x0 + i].style, want)) return Error.LadderInk;
        }
    }
}

/// A list's scrollbar runs down column `x` from `y0` for `h` rows: a
/// sized thumb over a dim track, both the toolkit's glyphs.
///
/// A pane whose list outruns its body and says nothing about where in
/// it you are is a pane you scroll blind. One family had this from the
/// start and the other did not, which is the only reason it is worth
/// asserting from both.
pub fn listScrollbar(f: *const Frame, x: u16, y0: u16, h: u16) Error!void {
    var track: u16 = 0;
    var thumb: u16 = 0;
    var y = y0;
    while (y < y0 + h and y < f.rows) : (y += 1) {
        const sym = f.slots[@as(usize, y) * f.cols + x].symbol();
        if (std.mem.eql(u8, sym, chrome.scroll_track)) track += 1;
        if (std.mem.eql(u8, sym, chrome.scroll_thumb)) thumb += 1;
    }
    if (track + thumb == 0) return Error.BarMissing;
    if (thumb == 0) return Error.BarThumbMissing;
    // A thumb that fills the whole track says nothing; the list that
    // needs a bar is by definition longer than the window.
    if (track == 0) return Error.BarTrackMissing;
}

/// The fold row on line `y` reads `<ellipsis>  Show more (` as one
/// phrase: the ellipsis dim punctuation, two cells of air, then the
/// words in the bright foreground a key wears.
///
/// One phrase because the two panes used to disagree about where the
/// ellipsis went — one pinned it to the row's left edge and put its
/// words forty columns away, which reads as an empty column with a
/// stray mark in it rather than as a row you can press.
pub fn foldRow(f: *const Frame, th: Theme, y: u16, ascii: bool) Error!void {
    const ell: []const u8 = if (ascii) chrome.more_ascii else chrome.more_glyph;
    var x: u16 = 0;
    const at = while (x < f.cols) : (x += 1) {
        if (rowHas(f, y, x, ell)) break x;
    } else return Error.FoldRowMissing;
    const words_x = at + @as(u16, @intCast(text_mod.width(ell))) + 2;
    if (!rowHas(f, y, words_x, "Show more (")) return Error.FoldRowSplit;
    if (!eqlInk(f.slots[@as(usize, y) * f.cols + at].style, th.dimText())) return Error.FoldRowInk;
    if (!eqlInk(f.slots[@as(usize, y) * f.cols + words_x].style, th.bright())) return Error.FoldRowInk;
}

/// The text of one statusline segment obeys the family's figure rule:
/// one figure the segment is named for, and a bracketed subset only
/// when the pane genuinely has one (`sdk.pane.figure`).
///
/// Asserted from both suites because the two panes disagreed about it
/// by accident rather than on purpose — the forge pane had a real
/// subset to publish and the tracker pane did not, and nothing said
/// which of those was the standard.
pub fn statuslineFigure(s: []const u8) Error!void {
    return figure.check(s);
}

/// Every cell of the build line on row `y`, from `x0` up to but not
/// including `x1`, resolves to `want` — one door, the width of the
/// line.
///
/// Both panes painted the toolkit's build line and neither opened the
/// run when you clicked it: the caption fell through to the generic
/// row hit, which selects. Asserted from both suites because the two
/// lay-outs differ — one is a free row and the other a cell inside a
/// table — and the door must not.
pub fn buildLineHit(comptime Target: type, m: *const hit.Map(Target), y: u16, x0: u16, x1: u16, want: Target) Error!void {
    if (x1 <= x0) return Error.BuildHitMissing;
    if (m.at(x0, y) == null) return Error.BuildHitMissing;
    var x = x0;
    while (x < x1) : (x += 1) {
        const got = m.at(x, y) orelse return Error.BuildHitPartial;
        if (!std.meta.eql(got, want)) return Error.BuildHitPartial;
    }
}

/// Row `y` is a table's column header: each of `names`, left to right
/// from `x0`, whole or clipped to a prefix of at least one cell, in
/// `Theme.label()`, and never touching the next — `columns.header`.
///
/// A header two panes spell two ways is the first thing a reader sees
/// differ between them; one that runs its words together at a narrow
/// width (`STATUSASSIGNEE`) reads as one column that does not exist.
pub fn columnHeader(f: *const Frame, th: Theme, x0: u16, y: u16, names: []const []const u8) Error!void {
    const want = th.label();
    var x = x0;
    for (names) |name| {
        // The first cell of the name on the row, from where the last ended.
        const first = name[0 .. std.unicode.utf8ByteSequenceLength(name[0]) catch 1];
        const at = while (x < f.cols) : (x += 1) {
            if (rowHas(f, y, x, first)) break x;
        } else return Error.HeaderNameMissing;
        var cells: u16 = 0;
        var off: usize = 0;
        while (off < name.len and at + cells < f.cols) {
            const len = std.unicode.utf8ByteSequenceLength(name[off]) catch 1;
            const slot = f.slots[@as(usize, y) * f.cols + at + cells];
            if (!std.mem.eql(u8, slot.symbol(), name[off .. off + len])) break;
            if (!eqlInk(slot.style, want)) return Error.HeaderInk;
            off += len;
            cells += 1;
        }
        x = at + cells;
        // Clipped or whole, the next cell is air (or the row's end).
        if (x < f.cols and !blank(f, x, y)) return Error.HeaderNamesRunTogether;
    }
}

/// `want`, one codepoint per cell, starting at `(x0, y)`. Every glyph
/// the ladder carries is single-width, so a cell is a codepoint here.
fn rowHas(f: *const Frame, y: u16, x0: u16, want: []const u8) bool {
    var i: u16 = 0;
    var off: usize = 0;
    while (off < want.len) {
        const len = std.unicode.utf8ByteSequenceLength(want[off]) catch return false;
        const g = want[off .. off + len];
        const slot = f.slots[@as(usize, y) * f.cols + x0 + i];
        if (!std.mem.eql(u8, slot.symbol(), g)) return false;
        off += len;
        i += 1;
    }
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a row's buttons are there at both widths, and the hit is the cells" {
    const Target = union(enum) { btn: u8 };
    var f = try Frame.init(testing.allocator, 60, 3);
    defer f.deinit();
    var hits: hit.Map(Target) = .{};
    defer hits.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } });
    var p: chrome.Painter(Target) = .{ .f = &f, .gpa = testing.allocator, .arena = arena.allocator(), .hits = &hits, .th = th, .ui = .{ .nerd = true } };

    const list = [_]chrome.ActionChip(Target){
        .{ .word = "Open", .target = .{ .btn = 0 } },
        .{ .word = "Merge", .target = .{ .btn = 1 } },
    };
    const wide = try p.actionChips(2, 0, .icon_label, 0, &list);
    try testing.expectEqual(action.runWidth(&.{ .{ .word = "Open" }, .{ .word = "Merge" } }, .icon_label, 0, false), wide);
    try actionRun(Target, &f, &hits, 0, &.{ .{ .btn = 0 }, .{ .btn = 1 } }, .icon_label);
    // …and the icon form is one cell each, still both there.
    hits.reset();
    const tight = try p.actionChips(2, 1, .icon, 0, &list);
    try testing.expectEqual(@as(u16, 3), tight);
    try actionRun(Target, &f, &hits, 1, &.{ .{ .btn = 0 }, .{ .btn = 1 } }, .icon);
    // The wrong form is caught either way round.
    try testing.expectError(Error.ActionRunWidth, actionRun(Target, &f, &hits, 1, &.{.{ .btn = 0 }}, .icon_label));

    // A row that dropped one of its buttons — what the forge pane did
    // below 135 columns — fails rather than passing quietly.
    hits.reset();
    _ = try p.actionChips(2, 2, .icon_label, 0, list[0..1]);
    try testing.expectError(Error.ActionRunMissing, actionRun(Target, &f, &hits, 2, &.{ .{ .btn = 0 }, .{ .btn = 1 } }, .icon_label));
}

test "a build line's door is the whole line, and a door over only the words fails" {
    const Target = union(enum) { build: u8, row: u8 };
    var m: hit.Map(Target) = .{};
    defer m.deinit(testing.allocator);
    // What `Painter.buildRow` registers: the whole line.
    try m.add(testing.allocator, hit.buildHit(.{ .x = 0, .y = 3, .w = 60, .h = 1 }, 60), .{ .build = 1 });
    try buildLineHit(Target, &m, 3, 0, 60, .{ .build = 1 });

    // What both panes had instead: the row's own hit under the line,
    // so a click selected rather than opening the run.
    var bad: hit.Map(Target) = .{};
    defer bad.deinit(testing.allocator);
    try bad.add(testing.allocator, .{ .x = 0, .y = 3, .w = 60, .h = 1 }, .{ .row = 1 });
    try testing.expectError(Error.BuildHitPartial, buildLineHit(Target, &bad, 3, 0, 60, .{ .build = 1 }));

    // A door over only the caption's cells leaves the indent and the
    // air past the words dead.
    var short: hit.Map(Target) = .{};
    defer short.deinit(testing.allocator);
    try short.add(testing.allocator, .{ .x = 6, .y = 3, .w = 30, .h = 1 }, .{ .build = 1 });
    try testing.expectError(Error.BuildHitMissing, buildLineHit(Target, &short, 3, 0, 60, .{ .build = 1 }));
    try testing.expectError(Error.BuildHitPartial, buildLineHit(Target, &short, 3, 6, 60, .{ .build = 1 }));

    // Nothing at all on the row.
    var empty: hit.Map(Target) = .{};
    defer empty.deinit(testing.allocator);
    try testing.expectError(Error.BuildHitMissing, buildLineHit(Target, &empty, 3, 0, 60, .{ .build = 1 }));
}

test "the header expectations pass on a toolkit-painted header and fail on a hand-rolled one" {
    const Target = union(enum) { chip: u8 };
    var f = try Frame.init(testing.allocator, 60, 4);
    defer f.deinit();
    var hits: hit.Map(Target) = .{};
    defer hits.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } }, .chip_bg = .{ .rgb = .{ 7, 8, 9 } } });

    var p: chrome.Painter(Target) = .{
        .f = &f,
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .hits = &hits,
        .th = th,
        .ui = .{ .nerd = true },
    };
    const x = p.capsTitle(1, 0, "PANE", "  (3)");
    _ = try p.rightChips(0, x, &.{
        .{ .text = chrome.help_chip_text, .target = .{ .chip = 0 } },
        .{ .text = p.refreshChipText(), .target = .{ .chip = 1 } },
    });
    try capsTitleInk(&f, th, 1, 0, "PANE");
    try headerLadderTail(&f, th, 0, true, false);

    // The accent title the tracker pane used to paint.
    _ = f.text(1, 1, 10, "PANE", th.accentText());
    try testing.expectError(Error.TitleInk, capsTitleInk(&f, th, 1, 1, "PANE"));
    // A ladder with the refresh glyph in bare accent ink, the way the
    // forge pane used to paint it.
    _ = f.text(f.cols - 4, 2, 3, chrome.help_chip_text, th.chip());
    _ = f.text(f.cols - 8, 2, 3, " " ++ chrome.refresh_nerd ++ " ", th.refresh());
    try testing.expectError(Error.LadderInk, headerLadderTail(&f, th, 2, true, false));
    // Nothing at all on the row.
    try testing.expectError(Error.LadderMissing, headerLadderTail(&f, th, 3, true, false));
}

test "a column header painted by the toolkit passes; one run together or in the wrong ink fails" {
    const columns = @import("columns.zig");
    const Col = struct { name: []const u8, w: u16 };
    var f = try Frame.init(testing.allocator, 40, 3);
    defer f.deinit();
    const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } });
    _ = columns.header(&f, 2, 0, 38, &[_]Col{ .{ .name = "KEY", .w = 5 }, .{ .name = "STATUS", .w = 4 }, .{ .name = "SUMMARY", .w = 10 } }, 1, th);
    try columnHeader(&f, th, 2, 0, &.{ "KEY", "STATUS", "SUMMARY" });
    // What the tracker pane painted at 43 columns.
    _ = f.text(2, 1, 30, "KEY STATUSASSIGNEE", th.label());
    try testing.expectError(Error.HeaderNamesRunTogether, columnHeader(&f, th, 2, 1, &.{ "KEY", "STATUS", "ASSIGNEE" }));
    _ = f.text(2, 2, 30, "KEY", th.accentText());
    try testing.expectError(Error.HeaderInk, columnHeader(&f, th, 2, 2, &.{"KEY"}));
    try testing.expectError(Error.HeaderNameMissing, columnHeader(&f, th, 2, 0, &.{"NOPE"}));
}
