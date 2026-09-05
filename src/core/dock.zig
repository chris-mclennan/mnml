//! The dock's value vocabulary — where a widget sits, how big it is,
//! whether it floats over the editor or claims a strip, and how much of
//! the editor shows through. Lives in core because the command layer's
//! `MenuAction` names these (the kebab menu's rows set one of them) and
//! the session file persists them.

const std = @import("std");

pub const Corner = enum {
    bottom_left,
    bottom_right,
    top_left,
    top_right,

    pub const all = [_]Corner{ .bottom_left, .bottom_right, .top_left, .top_right };

    pub fn isBottom(c: Corner) bool {
        return c == .bottom_left or c == .bottom_right;
    }
    pub fn isRight(c: Corner) bool {
        return c == .bottom_right or c == .top_right;
    }
    /// `dock.move_corner_next`: clockwise from the bottom-left.
    pub fn next(c: Corner) Corner {
        return switch (c) {
            .bottom_left => .top_left,
            .top_left => .top_right,
            .top_right => .bottom_right,
            .bottom_right => .bottom_left,
        };
    }
    pub fn label(c: Corner) []const u8 {
        return switch (c) {
            .bottom_left => "Bottom-left",
            .bottom_right => "Bottom-right",
            .top_left => "Top-left",
            .top_right => "Top-right",
        };
    }
};

/// Overlay floats over the editor body; inline claims a strip at the
/// top or bottom edge and the editor reflows around it.
pub const Placement = enum {
    overlay,
    @"inline",

    pub fn label(p: Placement) []const u8 {
        return switch (p) {
            .overlay => "Overlay",
            .@"inline" => "Inline",
        };
    }
};

/// Solid paints a full ground; translucent blends the ground with what
/// the editor painted underneath (or skips it when the colours cannot
/// be blended), so the text shows through.
pub const Opacity = enum {
    solid,
    translucent,

    pub fn label(o: Opacity) []const u8 {
        return switch (o) {
            .solid => "Solid",
            .translucent => "Translucent",
        };
    }
};

/// The presets, as percentages of the editor body. Fractions are
/// clamped to 15–90 % at layout time whatever the file says.
pub const Size = enum {
    small,
    medium,
    large,
    wide,
    tall,

    pub const all = [_]Size{ .small, .medium, .large, .wide, .tall };

    pub fn pct(s: Size) struct { w: u8, h: u8 } {
        return switch (s) {
            .small => .{ .w = 25, .h = 15 },
            .medium => .{ .w = 50, .h = 25 },
            .large => .{ .w = 50, .h = 40 },
            .wide => .{ .w = 90, .h = 25 },
            .tall => .{ .w = 50, .h = 50 },
        };
    }
    pub fn label(s: Size) []const u8 {
        return switch (s) {
            .small => "Small",
            .medium => "Medium",
            .large => "Large",
            .wide => "Wide",
            .tall => "Tall",
        };
    }
    /// The preset a widget's fractions match, if any (the menu ticks it).
    pub fn matching(w: u8, h: u8) ?Size {
        for (all) |s| {
            const p = s.pct();
            if (p.w == w and p.h == h) return s;
        }
        return null;
    }
};

pub const min_pct: u8 = 15;
pub const max_pct: u8 = 90;

/// What a kebab-menu row sets on a widget.
pub const Setting = union(enum) {
    size: Size,
    corner: Corner,
    placement: Placement,
    opacity: Opacity,
};

test "corners cycle clockwise from the bottom-left and back" {
    var c: Corner = .bottom_left;
    for (0..4) |_| c = c.next();
    try std.testing.expectEqual(Corner.bottom_left, c);
    try std.testing.expect(Corner.bottom_right.isBottom() and Corner.bottom_right.isRight());
    try std.testing.expect(!Corner.top_left.isBottom() and !Corner.top_left.isRight());
}

test "size presets round-trip through matching" {
    for (Size.all) |s| try std.testing.expectEqual(s, Size.matching(s.pct().w, s.pct().h).?);
    try std.testing.expect(Size.matching(33, 33) == null);
}
