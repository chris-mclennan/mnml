//! The bottom row — the one under the statusline. Four things live on
//! it, in this order of precedence:
//!
//!   1. an open `:` line (`:noh▏`), the app's own or a buffer's;
//!   2. the newest toast, echoed dim on the left, so a message that has
//!      already faded out of its box still has somewhere to be read;
//!   3. a `⟳  bench (12/100 · 5s) running…` indicator on the right
//!      while async work is in flight — a toast lasts three seconds and
//!      a bench does not, so without this a long op has no signal at
//!      all;
//!   4. nothing, which is still a click target: the whole row opens the
//!      `:` line, the affordance a user who does not know `Ctrl+;` can
//!      actually find.
//!
//! The echoed toast's first `[name]` is painted as a link and gets its
//! own hit — `ai.explain_diff: ready → [diff-explanation]` names a pane
//! the message is about, and clicking it should go there rather than
//! leave the user to find it. The in-flight indicator gets one too:
//! clicking it aborts the work it is reporting.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Style = vaxis.Style;

/// What the row is asked to show this frame. Every field is borrowed
/// for the paint only.
pub const Model = struct {
    /// An open `:` line, already in its `:<text>▏` display form.
    line: ?[]const u8 = null,
    /// The line's selection, a byte range of `line`, painted in the
    /// theme's selection the way a text field paints one.
    sel: ?[2]usize = null,
    /// The newest toast, echoed when no `:` line is open.
    toast: ?[]const u8 = null,
    /// `bench (12/100 · 5s), sync (3s)` — the names only; the row adds
    /// the glyph and the `running…`.
    inflight: ?[]const u8 = null,
};

/// The hit ids the row registers, supplied by the caller so the id
/// space stays in one place (`app/render.zig`).
pub const Hits = struct {
    /// The whole row: opens the `:` line.
    bar: u32,
    /// The in-flight indicator: aborts.
    inflight: u32,
    /// The echoed toast's `[name]`: reveals that pane.
    mention: u32,
};

/// The bracketed name in `s`, if it has one — the byte range of
/// `[name]`, brackets included.
pub fn mention(s: []const u8) ?struct { start: usize, end: usize } {
    const lb = std.mem.indexOfScalar(u8, s, '[') orelse return null;
    const rb = std.mem.indexOfScalarPos(u8, s, lb + 1, ']') orelse return null;
    if (rb <= lb + 1) return null;
    return .{ .start = lb, .end = rb + 1 };
}

/// The name a `[name]` mention carries, without its brackets.
pub fn mentionName(s: []const u8) ?[]const u8 {
    const m = mention(s) orelse return null;
    return s[m.start + 1 .. m.end - 1];
}

/// Paints the row and registers its hits. Returns the screen cell the
/// caret sits on when a `:` line is open, so the caller can park the
/// terminal cursor there.
pub fn draw(ui: Ui, area: Rect, model: Model, hits: Hits) ?struct { x: u16, y: u16 } {
    if (area.isEmpty()) return null;
    const t = ui.theme;
    // The row's ground is the editor's, as the blank row under the
    // statusline always was — the statusline's own colour would make
    // the row read as a second statusline.
    ui.fill(area, t.bg);
    const bg = t.bg.bg;

    // The row is a click target whatever it shows — an unregistered row
    // would let a click fall through to whatever painted under it.
    ui.hit(area, .{ .button = hits.bar });

    // 1. The `:` line owns the row outright while it is open. Its hit
    //    stays registered; the handler makes a click a no-op so the
    //    line is not torn down under the user's own typing.
    if (model.line) |line| {
        var style = Theme.onBg(t.warn_fg, bg);
        style.bold = true;
        _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(line, area.w), style);
        if (model.sel) |s| if (s[0] < s[1] and s[1] <= line.len) {
            const sx = area.x + ui.width(line[0..s[0]]);
            if (sx < area.right()) _ = ui.putStr(sx, area.y, area.right() - sx, line[s[0]..s[1]], Theme.onBg(t.fg, t.selection.bg));
        };
        const caret_mark: []const u8 = if (ui.ascii) "|" else "▏";
        const before = std.mem.indexOf(u8, line, caret_mark) orelse line.len;
        const cx = area.x + @min(ui.width(line[0..before]), area.w -| 1);
        return .{ .x = cx, .y = area.y };
    }

    // 2. The toast echo, dim, on the left.
    var used: u16 = 0;
    if (model.toast) |msg| {
        const dim = Theme.onBg(t.muted, bg);
        if (mention(msg)) |m| {
            used += ui.putStr(area.x, area.y, area.w, msg[0..m.start], dim);
            var link = Theme.onBg(t.warn_fg, bg);
            link.bold = true;
            link.ul_style = .single;
            const name_x = area.x + used;
            const name_w = ui.putStr(name_x, area.y, area.w -| used, msg[m.start..m.end], link);
            if (name_w > 0) ui.hit(Rect.init(name_x, area.y, name_w, 1), .{ .button = hits.mention });
            used += name_w;
            used += ui.putStr(area.x + used, area.y, area.w -| used, msg[m.end..], dim);
        } else {
            used = ui.putStr(area.x, area.y, area.w, ui.clipStr(msg, area.w), dim);
        }
    }

    // 3. The in-flight indicator, right-aligned, one cell off the edge.
    if (model.inflight) |names| {
        const text = if (ui.ascii)
            ui.fmt("(*) {s} running...", .{names})
        else
            ui.fmt("⟳  {s} running…", .{names});
        const w = ui.width(text);
        // It never overwrites the echo: no room, no indicator.
        if (w + used + 1 <= area.w) {
            const x = area.right() - 1 - w;
            var style = Theme.onBg(t.warn_fg, bg);
            style.bold = true;
            _ = ui.putStr(x, area.y, w, text, style);
            ui.hit(Rect.init(x, area.y, w, 1), .{ .button = hits.inflight });
        }
    }
    return null;
}

// ── tests ──

const t_ = std.testing;
const Fixture = @import("test_fixture.zig");

const ids: Hits = .{ .bar = 101, .inflight = 102, .mention = 103 };

test "an open : line owns the row and carries the caret" {
    var f = try Fixture.init(40, 3);
    defer f.deinit();
    const c = draw(f.ui(), Rect.init(0, 2, 40, 1), .{ .line = ":noh▏" }, ids).?;
    var buf: [128]u8 = undefined;
    try t_.expectEqualStrings(":noh▏", f.row(2, &buf));
    try t_.expectEqual(@as(u16, 4), c.x);
    try t_.expectEqual(@as(u16, 2), c.y);
    // The row keeps its hit so a click cannot fall through to the pane
    // under it; the handler no-ops while the line is open.
    try t_.expectEqual(ids.bar, f.hits.at(10, 2).?.button);
    // Mid-line the caret sits where the mark is, not at the end.
    f.hits.reset();
    const c2 = draw(f.ui(), Rect.init(0, 2, 40, 1), .{ .line = ":no▏h" }, ids).?;
    try t_.expectEqual(@as(u16, 3), c2.x);
}

test "an empty row is still a click target for the : line" {
    var f = try Fixture.init(40, 3);
    defer f.deinit();
    try t_.expect(draw(f.ui(), Rect.init(0, 2, 40, 1), .{}, ids) == null);
    try t_.expectEqual(ids.bar, f.hits.at(20, 2).?.button);
    try t_.expectEqual(ids.bar, f.hits.at(0, 2).?.button);
}

test "the echoed toast's [name] is a link with its own hit over just the brackets" {
    var f = try Fixture.init(60, 3);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 2, 60, 1), .{ .toast = "ai.pr_desc: ready → [pr-description]" }, ids);
    var buf: [256]u8 = undefined;
    try t_.expectEqualStrings("ai.pr_desc: ready → [pr-description]", f.row(2, &buf));
    // `[` is at char 20; the name runs 16 cells from there.
    try t_.expectEqual(ids.mention, f.hits.at(20, 2).?.button);
    try t_.expectEqual(ids.mention, f.hits.at(35, 2).?.button);
    // Either side of it the row's own hit still answers.
    try t_.expectEqual(ids.bar, f.hits.at(19, 2).?.button);
    try t_.expectEqual(ids.bar, f.hits.at(36, 2).?.button);
    try t_.expect(f.fgEql(21, 2, f.theme.warn_fg));
    try t_.expectEqualStrings("pr-description", mentionName("ai.pr_desc: ready → [pr-description]").?);
    try t_.expect(mentionName("no brackets here") == null);
    try t_.expect(mentionName("empty [] mention") == null);
}

test "the in-flight indicator is right-aligned, aborts on click, and yields to a long echo" {
    var f = try Fixture.init(60, 3);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 2, 60, 1), .{ .inflight = "bench (12/100 · 5s)" }, ids);
    var buf: [256]u8 = undefined;
    try t_.expectEqualStrings("⟳  bench (12/100 · 5s) running…", std.mem.trimStart(u8, f.row(2, &buf), " "));
    try t_.expectEqual(ids.inflight, f.hits.at(58, 2).?.button);
    try t_.expectEqual(ids.bar, f.hits.at(2, 2).?.button);

    // A toast wide enough to collide keeps the row; the indicator drops.
    f.hits.reset();
    const long = "a message long enough that the indicator cannot fit beside it at all";
    _ = draw(f.ui(), Rect.init(0, 2, 60, 1), .{ .toast = long, .inflight = "sync (3s)" }, ids);
    try f.expectLacks("running…");

    // ASCII mode spells it without the glyphs.
    f.hits.reset();
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, Rect.init(0, 2, 60, 1), .{ .inflight = "sync (3s)" }, ids);
    try f.expectContains("(*) sync (3s) running...");
}

test "no room, no paint" {
    var f = try Fixture.init(40, 3);
    defer f.deinit();
    try t_.expect(draw(f.ui(), Rect.empty, .{ .line = ":x▏" }, ids) == null);
    try t_.expectEqual(@as(usize, 0), f.hits.items.items.len);
}
