//! Shifted function keys from terminals that do not speak the kitty
//! keyboard protocol and do not use xterm's modifier parameter.
//!
//! xterm, Windows Terminal, VTE and Konsole send Shift+F1 as `CSI 1;2 P`
//! and Shift+F5 as `CSI 15;2 ~`; `vaxis.Parser` reads the `;2` as shift
//! and those chords arrive as `shift+f1` / `shift+f5` already. The
//! terminals this file is for send a DIFFERENT KEY instead — one of the
//! VT220's extra function keys, `CSI 25 ~` … `CSI 34 ~` (F13–F20) — and
//! vaxis drops those sequences on the floor, so every `shift+fN` chord in
//! the spec table (find.prev, lsp.references, dap.step_out, …) was dead
//! there. Which shifted key each code stands for is the terminal's
//! convention, not the protocol's, so the table is picked by
//! `$TERM_PROGRAM` / `$TERM`:
//!
//!   xterm         F13–F20 are Shift+F1–F8 (xterm's own terminfo names
//!                 kf13–kf24 for Shift+F1–F12) — the default
//!   Terminal.app  Shift+F5–F12 send F13–F20
//!   rxvt, linux   Shift+F3–F10 send F13–F20 (Shift+F1/F2 are F11/F12's
//!                 own codes and cannot be told apart); Shift+F11 / F12
//!                 are `CSI 23 $` / `CSI 24 $`
//!
//! and `ESC O <m> P…S` — SS3 with a modifier digit, which some terminals
//! send for F1–F4 — reads its modifier the way the CSI form does.

const std = @import("std");
const vaxis = @import("vaxis");

const Key = vaxis.Key;

pub const Style = enum { xterm, apple_terminal, rxvt };

/// The convention the terminal in `$TERM_PROGRAM` / `$TERM` follows.
pub fn styleFor(term_program: ?[]const u8, term: ?[]const u8) Style {
    if (term_program) |tp| if (std.mem.eql(u8, tp, "Apple_Terminal")) return .apple_terminal;
    if (term) |t| if (std.mem.startsWith(u8, t, "rxvt") or std.mem.eql(u8, t, "linux")) return .rxvt;
    return .xterm;
}

pub const Match = struct { key: Key, n: usize };

/// The VT220's F13–F20 codes, in order.
const vt220_extra = [_]u16{ 25, 26, 28, 29, 31, 32, 33, 34 };

const fkeys = [_]u21{ Key.f1, Key.f2, Key.f3, Key.f4, Key.f5, Key.f6, Key.f7, Key.f8, Key.f9, Key.f10, Key.f11, Key.f12 };

fn shifted(n: usize) Key {
    return .{ .codepoint = fkeys[n - 1], .mods = .{ .shift = true } };
}

/// A shifted function key at the head of `bytes`, whole, or null — a
/// sequence this file does not know, or one not finished yet, is left
/// for `vaxis.Parser`.
pub fn match(bytes: []const u8, style: Style) ?Match {
    if (bytes.len < 4 or bytes[0] != 0x1b) return null;
    if (bytes[1] == 'O') {
        // SS3 <modifier> P..S
        const m = bytes[2];
        if (m < '2' or m > '9') return null;
        const f: u21 = switch (bytes[3]) {
            'P' => Key.f1,
            'Q' => Key.f2,
            'R' => Key.f3,
            'S' => Key.f4,
            else => return null,
        };
        return .{ .key = .{ .codepoint = f, .mods = @bitCast(@as(u8, m - '1')) }, .n = 4 };
    }
    if (bytes[1] != '[') return null;
    var i: usize = 2;
    var number: u16 = 0;
    while (i < bytes.len and i < 5 and std.ascii.isDigit(bytes[i])) : (i += 1) number = number * 10 + (bytes[i] - '0');
    if (i == 2 or i >= bytes.len) return null;
    const final = bytes[i];
    const n = i + 1;
    if (final == '$') {
        if (style != .rxvt) return null;
        return switch (number) {
            23 => .{ .key = shifted(11), .n = n },
            24 => .{ .key = shifted(12), .n = n },
            else => null,
        };
    }
    if (final != '~') return null;
    const k = std.mem.indexOfScalar(u16, &vt220_extra, number) orelse return null;
    const first: usize = switch (style) {
        .xterm => 1,
        .apple_terminal => 5,
        .rxvt => 3,
    };
    return .{ .key = shifted(first + k), .n = n };
}

// ── tests ──

const testing = std.testing;

fn expectKey(want_f: u21, want_mods: Key.Modifiers, bytes: []const u8, style: Style) !void {
    const m = match(bytes, style) orelse return error.NoMatch;
    try testing.expectEqual(want_f, m.key.codepoint);
    try testing.expectEqual(want_mods, m.key.mods);
    try testing.expectEqual(bytes.len, m.n);
}

test "styleFor: Terminal.app by TERM_PROGRAM, rxvt and the Linux console by TERM, xterm otherwise" {
    try testing.expectEqual(Style.apple_terminal, styleFor("Apple_Terminal", "xterm-256color"));
    try testing.expectEqual(Style.rxvt, styleFor(null, "rxvt-unicode-256color"));
    try testing.expectEqual(Style.rxvt, styleFor(null, "linux"));
    try testing.expectEqual(Style.xterm, styleFor("ghostty", "xterm-ghostty"));
    try testing.expectEqual(Style.xterm, styleFor(null, null));
}

test "the VT220 F13-F20 codes are the shifted keys each convention says they are" {
    const shift: Key.Modifiers = .{ .shift = true };
    // xterm: F13 is Shift+F1.
    try expectKey(Key.f1, shift, "\x1b[25~", .xterm);
    try expectKey(Key.f8, shift, "\x1b[34~", .xterm);
    // Terminal.app: Shift+F5 is F13, Shift+F12 is F20.
    try expectKey(Key.f5, shift, "\x1b[25~", .apple_terminal);
    try expectKey(Key.f7, shift, "\x1b[28~", .apple_terminal);
    try expectKey(Key.f10, shift, "\x1b[32~", .apple_terminal);
    try expectKey(Key.f12, shift, "\x1b[34~", .apple_terminal);
    // rxvt / linux: Shift+F3 is F13; Shift+F11 / F12 are `$`-final.
    try expectKey(Key.f3, shift, "\x1b[25~", .rxvt);
    try expectKey(Key.f10, shift, "\x1b[34~", .rxvt);
    try expectKey(Key.f11, shift, "\x1b[23$", .rxvt);
    try expectKey(Key.f12, shift, "\x1b[24$", .rxvt);
    try testing.expect(match("\x1b[23$", .xterm) == null);
    // SS3 with a modifier digit.
    try expectKey(Key.f1, shift, "\x1bO2P", .xterm);
    try expectKey(Key.f4, .{ .ctrl = true }, "\x1bO5S", .xterm);
}

test "everything else is vaxis's: plain F-keys, the xterm modifier form, CPR, arrows, an unfinished sequence" {
    for ([_][]const u8{ "\x1b[15~", "\x1b[15;2~", "\x1b[1;2P", "\x1b[12;40R", "\x1bOP", "\x1b[A", "\x1b[2", "\x1b[25", "a", "\x1b[27~" }) |s| {
        try testing.expect(match(s, .apple_terminal) == null);
    }
}
