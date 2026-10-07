//! Overlay box — the frame every popup shares: cleared ground in
//! `theme.overlay_bg`, a rounded border in `theme.overlay_border` (plain
//! `+-+` under `--ascii`), the title on the top edge in
//! `theme.overlay_title`. The prompt, the confirm, the picker, the
//! which-key popup and the tooltip all open with `box`, so they land
//! with one look and one placement rule: a size is clamped to the
//! screen before anything is painted, and a box that cannot hold a
//! border returns an empty inner rect instead of a torn frame.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");

const Segment = vaxis.Segment;

pub const Anchor = enum {
    /// Vertically centered.
    center,
    /// A third of the way down — where the Rust prompts sit.
    third,
    /// Flush with the top edge.
    top,
    /// Just above the last row of `screen` (the statusline).
    above_bottom,
};

/// The rect a `w`×`h` box takes inside `screen`, clamped and placed.
pub fn place(screen: Rect, w_in: u16, h_in: u16, anchor: Anchor) Rect {
    const w = @min(w_in, screen.w);
    const h = @min(h_in, screen.h);
    const x = screen.x + (screen.w - w) / 2;
    const y = switch (anchor) {
        .center => screen.y + (screen.h - h) / 2,
        .third => screen.y + (screen.h - h) / 3,
        .top => screen.y,
        .above_bottom => screen.y + (screen.h -| (h + 1)),
    };
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// The rect a `w`×`h` box takes when it hangs from a cell — its
/// bottom-left corner at (`x`, `bottom`), growing UP — clamped so its
/// top never rises above `top` and its right edge never leaves
/// `screen`. The `:` line's completion popup is placed this way: it
/// stands directly above the command line, its left edge on the first
/// typed character, where the eyes and the typing are, and never in
/// the middle of the screen. A box that cannot hold three rows or
/// three columns there comes back empty, as `frame` would leave it.
pub fn placeAbove(screen: Rect, x: u16, bottom: u16, top: u16, w_in: u16, h_in: u16) Rect {
    if (bottom < top or bottom >= screen.bottom() or x >= screen.right()) return Rect.empty;
    const room_h = bottom + 1 - top;
    const room_w = screen.right() - x;
    const w = @min(w_in, room_w);
    const h = @min(h_in, room_h);
    if (w < 3 or h < 3) return Rect.empty;
    return .{ .x = x, .y = bottom + 1 - h, .w = w, .h = h };
}

/// The three frames the Rust editor draws. `popup` is the rounded
/// transient one (a tooltip, a context menu, a hover card); `menu` is
/// the square dialog frame with the title as plain bold text (a
/// prompt, a confirm, the which-key popup — Rust's `popup_menu`);
/// `modal` is the square panel frame with the title as an accent chip
/// (the picker, the help overlay, click discovery — Rust's
/// `modal_panel`).
pub const Look = enum { popup, menu, modal };

/// Clears `r`, paints the frame and the title, returns the inner rect.
pub fn frame(ui: Ui, r: Rect, title: ?[]const u8) Rect {
    return frameLook(ui, r, title, .popup);
}

/// `frame` with an explicit `Look`.
pub fn frameLook(ui: Ui, r: Rect, title: ?[]const u8, look: Look) Rect {
    const t = ui.theme;
    ui.fill(r, t.overlay_bg);
    if (r.w < 2 or r.h < 2) return Rect.empty;
    const kind: @import("border.zig").Kind = if (ui.ascii) .ascii else switch (look) {
        .popup => .rounded,
        .menu, .modal => .single,
    };
    if (title) |tt| {
        const text = ui.fmt(" {s} ", .{tt});
        const style = switch (look) {
            .popup, .menu => t.overlay_title,
            .modal => t.chip_active,
        };
        const segs = [_]Segment{.{ .text = text, .style = style }};
        return ui.canvas.border(r, kind, t.overlay_border, &segs);
    }
    return ui.canvas.border(r, kind, t.overlay_border, null);
}

/// `place` then `frame`: the box's inner rect.
pub fn box(ui: Ui, screen: Rect, w: u16, h: u16, title: ?[]const u8, anchor: Anchor) Rect {
    return frame(ui, place(screen, w, h, anchor), title);
}

/// `box` with an explicit `Look`.
pub fn boxLook(ui: Ui, screen: Rect, w: u16, h: u16, title: ?[]const u8, anchor: Anchor, look: Look) Rect {
    return frameLook(ui, place(screen, w, h, anchor), title, look);
}

/// A dim hint row (`  enter to submit · esc to cancel`), in the hint
/// language's `--ascii` spelling when the terminal needs it.
pub fn hint(ui: Ui, r: Rect, text: []const u8) void {
    if (r.isEmpty()) return;
    const t = ui.theme;
    var s = @import("theme.zig").onBg(t.muted, t.overlay_bg.bg);
    s.dim = false;
    _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(hintText(ui, text), r.w), s);
}

/// The hint language's `--ascii` spelling, one pair per glyph. Every
/// hint row in the app is written once, in the unicode form, and
/// comes through here; before this table nine painters each kept a
/// second string by hand, and they had drifted — `<- ->` beside
/// `<-/->`, `enter` beside `Enter`, ` - ` beside `  -  ` — which is the
/// thing a component exists to stop. Order matters: the two-arrow
/// pairs go before the single arrows they contain.
pub const ascii_pairs = [_]struct { u: []const u8, a: []const u8 }{
    .{ .u = "\u{2190}\u{2192}", .a = "<- ->" }, // ←→
    .{ .u = "\u{2191}\u{2193}", .a = "up/down" }, // ↑↓
    .{ .u = "\u{2191}", .a = "^" }, // ↑ (a count of updates waiting)
    .{ .u = "\u{2190}", .a = "<-" }, // ←
    .{ .u = "\u{2192}", .a = "->" }, // →
    .{ .u = "\u{23ce}", .a = "enter" }, // ⏎
    .{ .u = "\u{21b5}", .a = "enter" }, // ↵
    .{ .u = "\u{2014}", .a = "-" }, // —
    .{ .u = "\u{b7}", .a = "-" }, // ·
};

/// `text` as the terminal will read it: unchanged, or its `--ascii`
/// spelling on the frame arena. A painter that lays a hint itself (a
/// pane's legend row, a footer) asks here rather than keeping a twin.
pub fn hintText(ui: Ui, text: []const u8) []const u8 {
    if (!ui.ascii) return text;
    return asciiHint(ui.arena, text) catch text;
}

/// The `--ascii` spelling of `text`, allocated on `arena`.
pub fn asciiHint(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, text.len);
    var i: usize = 0;
    scan: while (i < text.len) {
        for (ascii_pairs) |pr| {
            if (std.mem.startsWith(u8, text[i..], pr.u)) {
                try out.appendSlice(arena, pr.a);
                i += pr.u.len;
                continue :scan;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "place clamps to the screen and honours the anchor" {
    const screen = Rect.init(0, 0, 40, 10);
    try testing.expect(place(screen, 20, 4, .center).eql(Rect.init(10, 3, 20, 4)));
    try testing.expect(place(screen, 20, 4, .third).eql(Rect.init(10, 2, 20, 4)));
    try testing.expect(place(screen, 20, 4, .top).eql(Rect.init(10, 0, 20, 4)));
    try testing.expect(place(screen, 20, 4, .above_bottom).eql(Rect.init(10, 5, 20, 4)));
    try testing.expect(place(screen, 90, 40, .center).eql(screen));
    try testing.expect(place(Rect.init(5, 5, 3, 3), 90, 40, .above_bottom).eql(Rect.init(5, 5, 3, 3)));
}

test "placeAbove hangs the box from its bottom-left cell and clamps at the top edge" {
    const screen = Rect.init(0, 0, 40, 10);
    // Bottom row 8, four rows tall: rows 5..8, left edge on x = 1.
    try testing.expect(placeAbove(screen, 1, 8, 2, 20, 4).eql(Rect.init(1, 5, 20, 4)));
    // Taller than the room between `top` and `bottom`: the top is clamped.
    try testing.expect(placeAbove(screen, 1, 8, 2, 20, 30).eql(Rect.init(1, 2, 20, 7)));
    // Wider than what is right of `x`: the width is clamped.
    try testing.expect(placeAbove(screen, 30, 8, 2, 20, 4).eql(Rect.init(30, 5, 10, 4)));
    // The screen's last row is a fine bottom; one past it is not.
    try testing.expect(placeAbove(screen, 1, 9, 2, 20, 4).eql(Rect.init(1, 6, 20, 4)));
    try testing.expect(placeAbove(screen, 1, 10, 2, 20, 4).isEmpty());
    // No room for a frame at all — a bottom above the top, or two rows
    // of room — is an empty rect.
    try testing.expect(placeAbove(screen, 1, 1, 2, 20, 4).isEmpty());
    try testing.expect(placeAbove(screen, 1, 3, 2, 20, 4).isEmpty());
    try testing.expect(placeAbove(screen, 39, 8, 2, 20, 4).isEmpty());
}

test "box paints the frame with its title and returns the inner rect" {
    var f = try Fixture.init(20, 5);
    defer f.deinit();
    const inner = box(f.ui(), f.full(), 14, 4, "Go to line", .top);
    try testing.expect(inner.eql(Rect.init(4, 1, 12, 2)));
    try f.expectRow(0, "   ╭ Go to line ╮");
    try f.expectRow(3, "   ╰────────────╯");
    try testing.expect(f.bgEql(6, 1, f.theme.overlay_bg));
    try testing.expect(f.style(5, 0).bold);
    var ui = f.ui();
    ui.ascii = true;
    _ = box(ui, f.full(), 14, 4, "Go to line", .top);
    try f.expectRow(0, "   + Go to line +");
    try testing.expect(box(ui, f.full(), 1, 1, null, .top).isEmpty());
    hint(ui, Rect.init(0, 4, 20, 1), "  enter · esc");
    try f.expectRow(4, "  enter - esc");
}

test "the menu and modal looks are square; the modal title is the accent chip" {
    var f = try Fixture.init(20, 5);
    defer f.deinit();
    _ = boxLook(f.ui(), f.full(), 14, 4, "Delete", .top, .menu);
    try f.expectRow(0, "   ┌ Delete ────┐");
    try f.expectRow(3, "   └────────────┘");
    try testing.expect(f.bgEql(5, 0, f.theme.overlay_bg));
    _ = boxLook(f.ui(), f.full(), 14, 4, "Help", .top, .modal);
    try f.expectRow(0, "   ┌ Help ──────┐");
    try testing.expect(f.bgEql(5, 0, f.theme.chip_active));
    var ui = f.ui();
    ui.ascii = true;
    _ = boxLook(ui, f.full(), 14, 4, "Help", .top, .modal);
    try f.expectRow(0, "   + Help ------+");
}

test "the hint language has one ascii spelling, and a hint row paints it" {
    var f = try Fixture.init(60, 3);
    defer f.deinit();
    var ui = f.ui();
    try testing.expectEqualStrings("a · b", hintText(ui, "a · b"));
    ui.ascii = true;
    // The pairs the families used to keep by hand, and the two they
    // never had (`↵`, `—`).
    try testing.expectEqualStrings(
        "<- -> adjust - up/down move - <- a - -> b - enter c - enter d - e - f",
        hintText(ui, "←→ adjust · ↑↓ move · ← a · → b · ⏎ c · ↵ d · e — f"),
    );
    // The two-arrow pairs win over the single arrows they contain.
    try testing.expectEqualStrings("[<- ->]", hintText(ui, "[←→]"));
    hint(ui, Rect.init(0, 1, 60, 1), "  enter to submit · esc to cancel");
    try f.expectRow(1, "  enter to submit - esc to cancel");
    const owned = try asciiHint(testing.allocator, "x · y");
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("x - y", owned);
}
