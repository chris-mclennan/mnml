//! Confirm — the small yes/no box: a title, a message, and a row of
//! choices each with a key letter. The close prompt is `Unsaved changes`
//! with Save / Discard / Cancel; a delete asks Delete / Cancel. One
//! primitive so every confirmation in the app reads and answers alike.
//!
//! Each choice paints as `  [S]ave  ` — the letter is bracketed in the
//! label itself so a keyboard user sees the hotkey without relying on
//! an underline the terminal may not draw (the underline is applied
//! too). The focused choice is the accent chip; ←/→, tab and h/l move
//! it, enter fires it, the letter fires its choice directly, esc
//! cancels. Every choice registers `.overlay_item(i)`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const key_mod = @import("../core/key.zig");

const Style = vaxis.Style;

pub const Key = key_mod.Key;

pub const Choice = struct { key: u8, label: []const u8 };

pub const State = struct {
    title: []const u8,
    message: []const u8,
    choices: []const Choice,
    selected: usize = 0,
};

pub const Outcome = union(enum) { consumed, cancel, choose: usize };

pub const height: u16 = 6;
pub const min_inner_width: u16 = 28;

/// The choice's letter (either case), ←/→ + enter, esc → cancel.
pub fn handleKey(s: *State, key: Key) Outcome {
    const n = s.choices.len;
    if (n == 0) return if (key.code == .esc) .cancel else .consumed;
    if (s.selected >= n) s.selected = n - 1;
    switch (key.code) {
        .esc => return .cancel,
        .enter => return .{ .choose = s.selected },
        .left, .backtab => s.selected = (s.selected + n - 1) % n,
        .right, .tab => s.selected = (s.selected + 1) % n,
        .char => |c| {
            if (key.mods.ctrl or key.mods.alt) return .consumed;
            if (c == ' ') return .{ .choose = s.selected };
            if (c < 0x80) {
                const lc = std.ascii.toLower(@intCast(c));
                for (s.choices, 0..) |ch, i| if (std.ascii.toLower(ch.key) == lc) return .{ .choose = i };
                if (lc == 'h') s.selected = (s.selected + n - 1) % n;
                if (lc == 'l') s.selected = (s.selected + 1) % n;
            }
        },
        else => {},
    }
    return .consumed;
}

/// `  [S]ave  ` — the key bracketed where it occurs in the label, or
/// prefixed when it does not.
pub fn buttonText(ui: Ui, c: Choice) []const u8 {
    const lk = std.ascii.toLower(c.key);
    for (c.label, 0..) |b, i| {
        if (std.ascii.toLower(b) == lk) {
            return ui.fmt("  {s}[{c}]{s}  ", .{ c.label[0..i], std.ascii.toUpper(c.key), c.label[i + 1 ..] });
        }
    }
    return ui.fmt("  [{c}] {s}  ", .{ std.ascii.toUpper(c.key), c.label });
}

/// Message on the first inner row, the choices on the last; the box a
/// third of the way down. Registers `.overlay_item(i)` per choice.
pub fn draw(ui: Ui, area: Rect, s: *const State) void {
    const t = ui.theme;
    const msg = ui.fmt("  {s}", .{s.message});
    var buttons_w: u16 = 0;
    for (s.choices) |c| buttons_w += ui.width(buttonText(ui, c)) + 2;
    const inner_w = @max(@max(ui.width(msg), buttons_w + 2), @max(min_inner_width, ui.width(s.title) + 4));
    const w = @min(inner_w + 2, area.w -| 2);
    const inner = overlay.box(ui, area, @max(w, @min(area.w, 8)), height, s.title, .third);
    if (inner.isEmpty() or inner.h < 2) return;

    const msg_row = inner.row(0);
    _ = ui.putStr(msg_row.x, msg_row.y, msg_row.w, ui.clipStr(msg, msg_row.w), Theme.onBg(t.fg, t.overlay_bg.bg));

    const by = inner.bottom() - 1;
    var bx = inner.x + 1;
    for (s.choices, 0..) |c, i| {
        const text = buttonText(ui, c);
        const bw = ui.width(text);
        if (bx + bw > inner.right()) break;
        const style = if (i == s.selected) t.chip_active else t.chip;
        const r = Rect.init(bx, by, bw, 1);
        ui.fill(r, style);
        // Paint the label, then underline the letter inside the brackets.
        _ = ui.putStr(bx, by, bw, text, style);
        if (std.mem.indexOfScalar(u8, text, '[')) |open| {
            const letter_x = bx + ui.width(text[0 .. open + 1]);
            var ul = style;
            ul.ul_style = .single;
            _ = ui.putStr(letter_x, by, 1, text[open + 1 .. open + 2], ul);
        }
        ui.hit(r, .{ .overlay_item = @intCast(i) });
        bx += bw + 2;
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const close_choices = [_]Choice{ .{ .key = 's', .label = "Save" }, .{ .key = 'd', .label = "Discard" }, .{ .key = 'c', .label = "Cancel" } };

fn closeState() State {
    return .{ .title = "Unsaved changes", .message = "notes.txt has unsaved changes.", .choices = &close_choices };
}

test "the close prompt: title, message, three bracketed choices with hits" {
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    var s = closeState();
    draw(f.ui(), f.full(), &s);
    try f.expectContains("Unsaved changes");
    try f.expectContains("has unsaved changes");
    try f.expectContains("[S]ave");
    try f.expectContains("[D]iscard");
    try f.expectContains("[C]ancel");
    // Box: inner 40 (buttons 10+13+12 + 6 = 41 → inner 41), h 6, y = (10-6)/3 = 1; buttons on row 5.
    const save = f.hits.at(f.hits.items.items[0].rect.x, 5).?;
    try testing.expectEqual(@as(u32, 0), save.overlay_item);
    try testing.expectEqual(@as(usize, 3), f.hits.items.items.len);
    const discard_rect = f.hits.items.items[1].rect;
    try testing.expectEqual(@as(u16, 5), discard_rect.y);
    try testing.expectEqual(@as(u32, 1), f.hits.at(discard_rect.x + 2, 5).?.overlay_item);
    try testing.expectEqual(@as(u32, 2), f.hits.items.items[2].target.overlay_item);
    // The first choice is the accent chip; the letter is underlined.
    const sx = f.hits.items.items[0].rect.x;
    try testing.expect(f.bgEql(sx, 5, f.theme.chip_active));
    try testing.expect(f.bgEql(discard_rect.x, 5, f.theme.chip));
    try testing.expect(f.style(sx + 3, 5).ul_style == .single);
    try testing.expect(f.style(sx + 4, 5).ul_style == .off);
    // Move the focus and repaint: the chip follows.
    _ = handleKey(&s, Key.named(.right));
    f.hits.reset();
    draw(f.ui(), f.full(), &s);
    try testing.expect(f.bgEql(sx, 5, f.theme.chip));
    try testing.expect(f.bgEql(discard_rect.x, 5, f.theme.chip_active));
}

test "keys: letters fire, arrows and tab move with wrap, enter fires the focus, esc cancels" {
    var s = closeState();
    try testing.expectEqual(@as(usize, 1), handleKey(&s, Key.char('d')).choose);
    try testing.expectEqual(@as(usize, 0), handleKey(&s, Key.char('S')).choose);
    try testing.expectEqual(@as(usize, 2), handleKey(&s, Key.char('c')).choose);
    try testing.expectEqual(Outcome.consumed, handleKey(&s, Key.char('x')));
    try testing.expectEqual(Outcome.consumed, handleKey(&s, Key.ctrl('s')));
    try testing.expectEqual(Outcome.cancel, handleKey(&s, Key.named(.esc)));
    try testing.expectEqual(@as(usize, 0), handleKey(&s, Key.named(.enter)).choose);
    _ = handleKey(&s, Key.named(.left));
    try testing.expectEqual(@as(usize, 2), s.selected);
    _ = handleKey(&s, Key.named(.tab));
    try testing.expectEqual(@as(usize, 0), s.selected);
    _ = handleKey(&s, Key.char('l'));
    try testing.expectEqual(@as(usize, 1), s.selected);
    _ = handleKey(&s, Key.char('h'));
    try testing.expectEqual(@as(usize, 0), s.selected);
    _ = handleKey(&s, Key.named(.backtab));
    try testing.expectEqual(@as(usize, 2), handleKey(&s, Key.char(' ')).choose);
    var none: State = .{ .title = "x", .message = "y", .choices = &.{} };
    try testing.expectEqual(Outcome.consumed, handleKey(&none, Key.named(.enter)));
    try testing.expectEqual(Outcome.cancel, handleKey(&none, Key.named(.esc)));
}

test "a key that is not in its label is prefixed; narrow screens drop what does not fit" {
    var f = try Fixture.init(40, 8);
    defer f.deinit();
    const choices = [_]Choice{ .{ .key = 'y', .label = "Delete" }, .{ .key = 'n', .label = "Keep" } };
    var s: State = .{ .title = "Delete file?", .message = "Really delete a.txt?", .choices = &choices };
    draw(f.ui(), f.full(), &s);
    try f.expectContains("[Y] Delete");
    try f.expectContains("[N] Keep");
    // Inner 18: the first button (14) fits, the second would not — it is
    // dropped whole rather than painted half.
    var g = try Fixture.init(22, 8);
    defer g.deinit();
    draw(g.ui(), g.full(), &s);
    try g.expectContains("[Y] Delete");
    try g.expectLacks("Keep");
    try testing.expectEqual(@as(usize, 1), g.hits.items.items.len);
    var h = try Fixture.init(3, 3);
    defer h.deinit();
    draw(h.ui(), h.full(), &s);
    draw(h.ui(), Rect.empty, &s);
}
