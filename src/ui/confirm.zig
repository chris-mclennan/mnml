//! Confirm — the small yes/no box: a title, a message, and a row of
//! choices each with a key letter. The close prompt is `Unsaved changes`
//! with Save / Discard / Cancel; a delete asks Delete / Delete
//! permanently / Cancel. One primitive so every confirmation in the app
//! reads and answers alike.
//!
//! Two button rows, as the Rust editor has them. `.bracket` (the close
//! prompt): each choice paints as `  [S]ave  ` from the left edge with a
//! two-cell gap, the box six rows tall. `.plain` (a delete, any other
//! destructive confirm): the choices are `  Delete  `, then
//! ` Delete permanently ` and ` Cancel ` one cell apart, right-aligned,
//! the box five rows tall. In both the key letter is underlined and the
//! focused choice is the accent chip; ←/→, tab and h/l move it, enter
//! fires it, the letter fires its choice directly, esc cancels. Every
//! choice registers `.overlay_item(i)`. The frame is Rust's square
//! `popup_menu`, centred on the whole screen a third of the way down.

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

/// How the choices paint — see the module doc.
pub const Buttons = enum { bracket, plain };

pub const State = struct {
    title: []const u8,
    message: []const u8,
    choices: []const Choice,
    selected: usize = 0,
    buttons: Buttons = .bracket,
};

pub const Outcome = union(enum) { consumed, cancel, choose: usize };

/// The box for a one-line message; each further `\n` in the message
/// adds a row.
pub const height: u16 = 6;
pub const height_plain: u16 = 5;
pub const min_inner_width: u16 = 28;
pub const min_inner_width_plain: u16 = 40;

fn lineCount(s: []const u8) u16 {
    return @intCast(std.mem.count(u8, s, "\n") + 1);
}

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

/// `  Delete  ` for the first choice, ` Cancel ` for the rest — Rust's
/// button labels carry their own padding, wider on the primary.
pub fn plainText(ui: Ui, c: Choice, first: bool) []const u8 {
    return if (first) ui.fmt("  {s}  ", .{c.label}) else ui.fmt(" {s} ", .{c.label});
}

/// The byte of the key letter inside a painted button, for the
/// underline: the bracketed letter, or the key's first occurrence.
fn keyByte(text: []const u8, key: u8) ?usize {
    if (std.mem.indexOfScalar(u8, text, '[')) |open| return open + 1;
    const lk = std.ascii.toLower(key);
    for (text, 0..) |b, i| if (std.ascii.toLower(b) == lk) return i;
    return null;
}

/// Message on the first inner rows (one per line), the choices on the
/// last; the box a third of the way down. Registers `.overlay_item(i)`
/// per choice.
pub fn draw(ui: Ui, area: Rect, s: *const State) void {
    const t = ui.theme;
    const plain = s.buttons == .plain;
    const gap: u16 = if (plain) 1 else 2;
    const indent: u16 = if (plain) 1 else 2;
    var buttons_w: u16 = 0;
    for (s.choices, 0..) |c, i| buttons_w += ui.width(if (plain) plainText(ui, c, i == 0) else buttonText(ui, c)) + gap;
    var msg_w: u16 = 0;
    var lines = std.mem.splitScalar(u8, s.message, '\n');
    while (lines.next()) |line| msg_w = @max(msg_w, ui.width(line) + indent);
    const floor: u16 = if (plain) min_inner_width_plain else @max(min_inner_width, ui.width(s.title) + 4);
    const inner_w = @max(@max(msg_w, buttons_w + 2), floor);
    const w = @min(inner_w + 2, area.w -| 2);
    const h = (if (plain) height_plain else height) + lineCount(s.message) - 1;
    const inner = overlay.boxLook(ui, area, @max(w, @min(area.w, 8)), h, s.title, .third, .menu);
    if (inner.isEmpty() or inner.h < 2) return;

    lines = std.mem.splitScalar(u8, s.message, '\n');
    var row: u16 = 0;
    while (lines.next()) |line| : (row += 1) {
        if (row + 1 >= inner.h) break;
        const msg_row = inner.row(row);
        const text = if (plain) ui.fmt(" {s}", .{line}) else ui.fmt("  {s}", .{line});
        _ = ui.putStr(msg_row.x, msg_row.y, msg_row.w, ui.clipStr(text, msg_row.w), Theme.onBg(t.fg, t.overlay_bg.bg));
    }

    const by = inner.bottom() - 1;
    var bx = if (plain) inner.x + (inner.w -| buttons_w) else inner.x + 1;
    for (s.choices, 0..) |c, i| {
        const text = if (plain) plainText(ui, c, i == 0) else buttonText(ui, c);
        const bw = ui.width(text);
        if (bx + bw > inner.right()) break;
        const style = if (i == s.selected) t.chip_active else t.chip;
        const r = Rect.init(bx, by, bw, 1);
        ui.fill(r, style);
        // Paint the label, then underline the key letter.
        _ = ui.putStr(bx, by, bw, text, style);
        if (keyByte(text, c.key)) |i_byte| {
            var ul = style;
            ul.ul_style = .single;
            _ = ui.putStr(bx + ui.width(text[0..i_byte]), by, 1, text[i_byte .. i_byte + 1], ul);
        }
        ui.hit(r, .{ .overlay_item = @intCast(i) });
        bx += bw + gap;
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
    // Box: inner 41 (buttons 10+13+12 + 6 = 41), h 6, y = (10-6)/3 = 1; buttons on row 5.
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

test "the plain row: Rust's delete confirm — square frame, right-aligned buttons, the key underlined" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    const choices = [_]Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'p', .label = "Delete permanently" }, .{ .key = 'c', .label = "Cancel" } };
    var s: State = .{ .title = "Delete", .message = "Delete .gitignore?", .choices = &choices, .selected = 2, .buttons = .plain };
    draw(f.ui(), f.full(), &s);
    // Rust: inner 43 (buttons 11 + 21 + 9 = 41, + 2), 45 wide at x 37, y (40-5)/3 = 11.
    try f.expectRow(11, " " ** 37 ++ "┌ Delete ───────────────────────────────────┐");
    try f.expectRow(12, " " ** 37 ++ "│ Delete .gitignore?                        │");
    try f.expectRow(13, " " ** 37 ++ "│                                           │");
    try f.expectRow(14, " " ** 37 ++ "│    Delete    Delete permanently   Cancel  │");
    try f.expectRow(15, " " ** 37 ++ "└───────────────────────────────────────────┘");
    try testing.expectEqual(@as(usize, 3), f.hits.items.items.len);
    try testing.expectEqual(@as(u32, 0), f.hits.at(42, 14).?.overlay_item);
    try testing.expectEqual(@as(u32, 1), f.hits.at(60, 14).?.overlay_item);
    try testing.expectEqual(@as(u32, 2), f.hits.at(75, 14).?.overlay_item);
    // Cancel is the focused chip; the underlines sit on D, p and C.
    try testing.expect(f.bgEql(75, 14, f.theme.chip_active));
    try testing.expect(f.bgEql(42, 14, f.theme.chip));
    try testing.expect(f.style(42, 14).ul_style == .single);
    try testing.expect(f.style(43, 14).ul_style == .off);
    try testing.expect(f.style(59, 14).ul_style == .single);
    try testing.expect(f.style(73, 14).ul_style == .single);
}

test "the bracket row is Rust's close prompt: two-space gaps from the left edge, six rows, centred on the screen" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s = closeState();
    s.message = "main.rs has unsaved changes.";
    draw(f.ui(), f.full(), &s);
    try f.expectRow(11, " " ** 37 ++ "┌ Unsaved changes ──────────────────────────┐");
    try f.expectRow(12, " " ** 37 ++ "│  main.rs has unsaved changes.             │");
    try f.expectRow(15, " " ** 37 ++ "│   [S]ave      [D]iscard      [C]ancel     │");
    try f.expectRow(16, " " ** 37 ++ "└───────────────────────────────────────────┘");
}
