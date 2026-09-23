//! The key sheet every integration pane opens on `?` — ONE component,
//! so two panes of the family cannot drift into two sheets (they had:
//! `KEYS` against `Keys`, `▾ ── navigation ── (6)` against
//! `── navigate ──`, `PgDn` against `⇟`, Esc against "any other key",
//! wrapped against clipped — hunt/findings-2026-09-23/
//! integ-keysheet-two-components.md).
//!
//! The pane hands over its rows — a section header, then its bindings,
//! each a chord already spelled with `chords` and an optional target a
//! click runs — and `chrome.Painter.keySheet` paints them in the host's
//! help shape (`src/ui/help_overlay.zig`): a centred box titled
//! ` Keys `, `▾ ── name ── (n)` headers, the chords in the accent padded
//! to the widest (8..20 cells), the label after two cells and wrapped
//! under itself when it is long, the footer on the last inner row. The
//! keys the sheet answers are `key` below, the same in every pane.

const std = @import("std");

pub const title = " Keys ";
pub const footer = "j/k scroll \u{b7} Esc close";
pub const footer_ascii = "j/k scroll - Esc close";

/// The widest the chord column grows, and the least it takes.
pub const chord_min: u16 = 8;
pub const chord_max: u16 = 20;
/// The box: at most this big, centred, two cells short of the pane.
pub const max_w: u16 = 84;
pub const max_h: u16 = 40;

/// What a key does while the sheet is open. Anything else is ignored —
/// the sheet stays up; a stray key never runs behind it.
pub const Key = enum { close, down, up, page_down, page_up, top, bottom, ignore };

pub fn key(spec: []const u8) Key {
    const eq = std.mem.eql;
    if (eq(u8, spec, "esc") or eq(u8, spec, "?") or eq(u8, spec, "q") or eq(u8, spec, "f1")) return .close;
    if (eq(u8, spec, "down") or eq(u8, spec, "j")) return .down;
    if (eq(u8, spec, "up") or eq(u8, spec, "k")) return .up;
    if (eq(u8, spec, "pagedown") or eq(u8, spec, "ctrl+d")) return .page_down;
    if (eq(u8, spec, "pageup") or eq(u8, spec, "ctrl+u")) return .page_up;
    if (eq(u8, spec, "home") or eq(u8, spec, "g")) return .top;
    if (eq(u8, spec, "end") or eq(u8, spec, "shift+g")) return .bottom;
    return .ignore;
}

/// Apply a `key` to a scroll offset; the painter clamps it to the rows.
/// True when the sheet should close.
pub fn scroll(offset: *usize, k: Key) bool {
    switch (k) {
        .close => return true,
        .down => offset.* +|= 1,
        .up => offset.* -|= 1,
        .page_down => offset.* +|= 10,
        .page_up => offset.* -|= 10,
        .top => offset.* = 0,
        .bottom => offset.* = std.math.maxInt(usize) / 2,
        .ignore => {},
    }
    return false;
}

const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn prefixed(comptime prefix: []const u8) [26][]const u8 {
    var out: [26][]const u8 = undefined;
    for (0..26) |i| out[i] = prefix ++ upper[i .. i + 1];
    return out;
}
const ctrl_names = prefixed("Ctrl+");
const alt_names = prefixed("Alt+");

/// One chord as the family spells it — `Enter`, `Space`, `↑`, `PgDn`,
/// `Home`, `Shift+Tab`, `Ctrl+D`, `Alt+↑`, `D` for `shift+d`, `>` for
/// `shift+.`, and a plain key as itself. The same word on the sheet, the
/// hint row and a picker's help line of every pane.
pub fn chord(spec: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "enter", "Enter" },           .{ "space", "Space" },         .{ "esc", "Esc" },
        .{ "tab", "Tab" },               .{ "backtab", "Shift+Tab" },   .{ "shift+tab", "Shift+Tab" },
        .{ "up", "\u{2191}" },           .{ "down", "\u{2193}" },       .{ "left", "\u{2190}" },
        .{ "right", "\u{2192}" },        .{ "pageup", "PgUp" },         .{ "pagedown", "PgDn" },
        .{ "home", "Home" },             .{ "end", "End" },             .{ "f1", "F1" },
        .{ "delete", "Del" },            .{ "backspace", "Backspace" }, .{ "alt+up", "Alt+\u{2191}" },
        .{ "alt+down", "Alt+\u{2193}" }, .{ "shift+.", ">" },           .{ "shift+/", "?" },
    };
    for (pairs) |p| if (std.mem.eql(u8, p[0], spec)) return p[1];
    if (spec.len == 7 and std.mem.startsWith(u8, spec, "shift+") and std.ascii.isLower(spec[6]))
        return upper[spec[6] - 'a' .. spec[6] - 'a' + 1];
    if (spec.len == 6 and std.mem.startsWith(u8, spec, "ctrl+") and std.ascii.isLower(spec[5]))
        return ctrl_names[spec[5] - 'a'];
    if (spec.len == 5 and std.mem.startsWith(u8, spec, "alt+") and std.ascii.isLower(spec[4]))
        return alt_names[spec[4] - 'a'];
    return spec;
}

/// Every spelling of a binding, `↑ / k`, on `arena`.
pub fn chords(arena: std.mem.Allocator, keys: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (keys, 0..) |k, i| {
        // Two specs that spell alike (`backtab`, `shift+tab`) are one.
        const c = chord(k);
        var seen = false;
        for (keys[0..i]) |prev| seen = seen or std.mem.eql(u8, chord(prev), c);
        if (seen) continue;
        if (out.items.len > 0) try out.appendSlice(arena, " / ");
        try out.appendSlice(arena, c);
    }
    return out.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "chord: one spelling for the family" {
    try testing.expectEqualStrings("Enter", chord("enter"));
    try testing.expectEqualStrings("PgDn", chord("pagedown"));
    try testing.expectEqualStrings("Home", chord("home"));
    try testing.expectEqualStrings("D", chord("shift+d"));
    try testing.expectEqualStrings(">", chord("shift+."));
    try testing.expectEqualStrings("Ctrl+D", chord("ctrl+d"));
    try testing.expectEqualStrings("Alt+\u{2191}", chord("alt+up"));
    try testing.expectEqualStrings("Shift+Tab", chord("backtab"));
    try testing.expectEqualStrings("q", chord("q"));
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("Home / g", try chords(a.allocator(), &.{ "home", "g" }));
    try testing.expectEqualStrings("Shift+Tab", try chords(a.allocator(), &.{ "backtab", "shift+tab" }));
}

test "key: Esc, ? and q close; j/k and the page keys scroll; anything else is ignored, not a close" {
    var off: usize = 0;
    try testing.expect(!scroll(&off, key("j")));
    try testing.expect(!scroll(&off, key("down")));
    try testing.expectEqual(@as(usize, 2), off);
    try testing.expect(!scroll(&off, key("k")));
    try testing.expectEqual(@as(usize, 1), off);
    try testing.expect(!scroll(&off, key("x")));
    try testing.expectEqual(Key.ignore, key("x"));
    try testing.expect(scroll(&off, key("esc")));
    try testing.expect(scroll(&off, key("?")));
    try testing.expectEqual(Key.top, key("g"));
}
