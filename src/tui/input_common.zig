//! The half of the input worker that does not care where the bytes come
//! from: `vaxis.Parser` over a byte stream, the fold that turns parsed
//! events into queue posts and capability updates, and the key naming
//! the status line, the tests and the `.test` runner share.
//!
//! `input_posix.zig` (a tty read in an `Io.Group` task) and
//! `input_windows.zig` (console records on a thread) both own the fields
//! these functions reach — `io`, `gpa`, `vx`, `queue`, `cache` — and pass
//! themselves in; the functions are generic over the backend so neither
//! file has to re-spell the other's logic.
//!
//! `fold` mirrors upstream's `Loop.handleEventGeneric` prong for prong —
//! that function cannot be analyzed under `zig test` on macOS (vaxis
//! 0.6.0's non-Linux `TestTty` has no `resetSignalHandler`), and owning
//! the fold makes it testable.

const std = @import("std");
const vaxis = @import("vaxis");
pub const legacy_fkeys = @import("legacy_fkeys.zig");

const Io = std.Io;

pub const Event = vaxis.Event;
pub const Key = vaxis.Key;

/// Events the queue holds before a producer blocks.
pub const queue_len = 256;

/// Parse `buf[0..total]`, posting every complete event through `in`.
/// Returns how many trailing bytes belong to an incomplete sequence; they
/// have been moved to the front of `buf` for the next read to extend.
pub fn parse(in: anytype, parser: *vaxis.Parser, buf: []u8, total: usize) !usize {
    var pos: usize = 0;
    while (pos < total) {
        // A shifted F-key in a convention vaxis does not read — it drops
        // those sequences — is the chord the key was (`legacy_fkeys.zig`).
        if (legacy_fkeys.match(buf[pos..total], in.fkeys)) |m| {
            pos += m.n;
            try fold(in, .{ .key_press = m.key });
            continue;
        }
        const result = parser.parse(buf[pos..total], in.gpa) catch {
            // Unparseable garbage: drop one byte and carry on.
            pos += 1;
            continue;
        };
        if (result.n == 0) {
            // Incomplete sequence: keep the tail for the next read.
            std.mem.copyForwards(u8, buf[0 .. total - pos], buf[pos..total]);
            return total - pos;
        }
        pos += result.n;
        const event = result.event orelse continue;
        try fold(in, event);
    }
    return 0;
}

/// One parsed event: capability replies update `in.vx`, everything else
/// is posted. `key.text` points into the parser's read buffer, so it is
/// copied into the grapheme ring before the event leaves this thread.
pub fn fold(in: anytype, event: Event) !void {
    const vx = in.vx;
    switch (event) {
        .key_press => |key| {
            // The explicit-width / scaled-text probes end in a cursor
            // position report, `CSI row ; col R`, which the parser reads
            // as F3 with `col` as its modifier: column 2 ⇒ shift (OSC 66
            // moved the cursor, explicit width works), 3 ⇒ alt (scaled
            // text). A terminal without OSC 66 answers column 1 — a plain
            // F3 — and upstream vaxis delivers that as a key press. While
            // the queries are outstanding every F3 is a reply, never a key.
            if (key.codepoint == Key.f3 and !vx.queries_done.load(.unordered)) {
                if (key.mods.shift) {
                    vx.caps.explicit_width = true;
                    vx.caps.unicode = .unicode;
                    vx.screen.width_method = .unicode;
                } else if (key.mods.alt) {
                    vx.caps.scaled_text = true;
                }
                return;
            }
            try in.postEvent(.{ .key_press = cacheText(in, key) });
        },
        .key_release => |key| try in.postEvent(.{ .key_release = cacheText(in, key) }),
        .mouse => |mouse| try in.postEvent(.{ .mouse = vx.translateMouse(mouse) }),
        .mouse_leave, .focus_in, .focus_out, .paste_start, .paste_end => try in.postEvent(event),
        // Owned by the event; the consumer frees it.
        .paste => try in.postEvent(event),
        .color_report, .color_scheme => try in.postEvent(event),
        .cap_kitty_keyboard => vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => vx.caps.kitty_graphics = true,
        .cap_rgb => vx.caps.rgb = true,
        .cap_unicode => {
            vx.caps.unicode = .unicode;
            vx.screen.width_method = .unicode;
        },
        .cap_sgr_pixels => vx.caps.sgr_pixels = true,
        .cap_color_scheme_updates => vx.caps.color_scheme_updates = true,
        .cap_multi_cursor => vx.caps.multi_cursor = true,
        .cap_da1 => {
            // The probe's last reply: wake `queryTerminal`.
            vx.queries_done.store(true, .unordered);
            Io.futexWake(in.io, std.atomic.Value(u32), &vx.query_futex, 10);
        },
        .winsize => |ws| {
            // Mode 2048 report. From here on the out-of-band resize path
            // (SIGWINCH, the console's size record) is skipped.
            vx.state.in_band_resize = true;
            try in.postEvent(.{ .winsize = ws });
        },
    }
}

fn cacheText(in: anytype, key: Key) Key {
    var out = key;
    if (key.text) |text| out.text = in.cache.put(text);
    return out;
}

/// A queue error inside a worker: cancelation propagates, a closed queue
/// ends the worker quietly.
pub fn mapQueueErr(err: anyerror) Io.Cancelable!void {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => {},
    };
}

// ── key naming (for status lines, tests, and the .test runner's key specs) ──

const named = [_]struct { cp: u21, name: []const u8 }{
    .{ .cp = Key.escape, .name = "esc" },
    .{ .cp = Key.enter, .name = "enter" },
    .{ .cp = Key.tab, .name = "tab" },
    .{ .cp = Key.backspace, .name = "backspace" },
    .{ .cp = Key.space, .name = "space" },
    .{ .cp = Key.insert, .name = "insert" },
    .{ .cp = Key.delete, .name = "delete" },
    .{ .cp = Key.left, .name = "left" },
    .{ .cp = Key.right, .name = "right" },
    .{ .cp = Key.up, .name = "up" },
    .{ .cp = Key.down, .name = "down" },
    .{ .cp = Key.page_up, .name = "pageup" },
    .{ .cp = Key.page_down, .name = "pagedown" },
    .{ .cp = Key.home, .name = "home" },
    .{ .cp = Key.end, .name = "end" },
    .{ .cp = Key.f1, .name = "f1" },
    .{ .cp = Key.f2, .name = "f2" },
    .{ .cp = Key.f3, .name = "f3" },
    .{ .cp = Key.f4, .name = "f4" },
    .{ .cp = Key.f5, .name = "f5" },
    .{ .cp = Key.f6, .name = "f6" },
    .{ .cp = Key.f7, .name = "f7" },
    .{ .cp = Key.f8, .name = "f8" },
    .{ .cp = Key.f9, .name = "f9" },
    .{ .cp = Key.f10, .name = "f10" },
    .{ .cp = Key.f11, .name = "f11" },
    .{ .cp = Key.f12, .name = "f12" },
    .{ .cp = Key.kp_enter, .name = "kpenter" },
};

/// `ctrl+shift+a`, `alt+enter`, `f5`, `漢` — mnml's key-spec grammar.
/// Modifier-only presses (kitty reports them) come out as `ctrl` etc.
pub fn keyName(key: Key, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    writeKeyName(&w, key) catch {};
    return w.buffered();
}

pub fn writeKeyName(w: *Io.Writer, key: Key) Io.Writer.Error!void {
    var wrote_mod = false;
    const mods = [_]struct { on: bool, name: []const u8 }{
        .{ .on = key.mods.ctrl, .name = "ctrl" },
        .{ .on = key.mods.alt, .name = "alt" },
        .{ .on = key.mods.shift, .name = "shift" },
        .{ .on = key.mods.super, .name = "super" },
        .{ .on = key.mods.hyper, .name = "hyper" },
        .{ .on = key.mods.meta, .name = "meta" },
    };
    for (mods) |m| {
        if (!m.on) continue;
        if (wrote_mod) try w.writeByte('+');
        try w.writeAll(m.name);
        wrote_mod = true;
    }
    if (key.isModifier()) return;
    if (wrote_mod) try w.writeByte('+');
    for (named) |n| {
        if (n.cp == key.codepoint) return w.writeAll(n.name);
    }
    if (key.codepoint < 0x20) {
        // Legacy control byte: ctrl+<letter>, unless kitty already told us.
        if (!key.mods.ctrl) try w.writeAll("ctrl+");
        return w.writeByte(@intCast(key.codepoint + 0x60));
    }
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(key.codepoint, &utf8) catch return w.writeByte('?');
    try w.writeAll(utf8[0..n]);
}

// ── tests ──

const testing = std.testing;
/// The platform's worker: the fold is exercised through whichever
/// backend this host builds, so both are covered where they compile.
const Input = @import("input.zig").Input;

fn expectName(expected: []const u8, key: Key) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, keyName(key, &buf));
}

test "keyName: plain, modified, named and legacy control keys" {
    try expectName("a", .{ .codepoint = 'a' });
    try expectName("漢", .{ .codepoint = 0x6f22 });
    try expectName("ctrl+a", .{ .codepoint = 'a', .mods = .{ .ctrl = true } });
    try expectName("ctrl+shift+a", .{ .codepoint = 'a', .mods = .{ .ctrl = true, .shift = true } });
    try expectName("alt+enter", .{ .codepoint = Key.enter, .mods = .{ .alt = true } });
    try expectName("esc", .{ .codepoint = Key.escape });
    try expectName("f5", .{ .codepoint = Key.f5 });
    try expectName("shift+tab", .{ .codepoint = Key.tab, .mods = .{ .shift = true } });
    // Legacy \x01 with no kitty modifiers still reads as ctrl+a.
    try expectName("ctrl+a", .{ .codepoint = 0x01 });
    // ...and a kitty-reported ctrl+a does not double the prefix.
    try expectName("ctrl+a", .{ .codepoint = 0x01, .mods = .{ .ctrl = true } });
    try expectName("ctrl+space", .{ .codepoint = Key.space, .mods = .{ .ctrl = true } });
}

test "keyName: caps/num lock are not spelled; lone modifiers are" {
    try expectName("a", .{ .codepoint = 'a', .mods = .{ .caps_lock = true, .num_lock = true } });
    try expectName("ctrl", .{ .codepoint = Key.left_control, .mods = .{ .ctrl = true } });
}

fn testInput(vx: *vaxis.Vaxis) !*Input {
    const in = try testing.allocator.create(Input);
    in.init(testing.io, testing.allocator, vx, .stdin());
    return in;
}

test "fold: capability replies land in vaxis, DA1 ends the probe, keys are posted" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    const in = try testInput(&vx);
    defer testing.allocator.destroy(in);

    vx.queries_done.store(false, .unordered);
    try fold(in, .cap_kitty_keyboard);
    try fold(in, .cap_kitty_graphics);
    try fold(in, .cap_sgr_pixels);
    try fold(in, .cap_unicode);
    // shift+F3 while probing is the explicit-width reply, not a key; a
    // plain F3 is the same report from a terminal without OSC 66.
    try fold(in, .{ .key_press = .{ .codepoint = Key.f3, .mods = .{ .shift = true } } });
    try fold(in, .{ .key_press = .{ .codepoint = Key.f3 } });
    try fold(in, .{ .winsize = .{ .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0 } });
    try fold(in, .cap_da1);

    try testing.expect(vx.caps.kitty_keyboard);
    try testing.expect(vx.caps.kitty_graphics);
    try testing.expect(vx.caps.sgr_pixels);
    try testing.expect(vx.caps.explicit_width);
    try testing.expectEqual(vaxis.gwidth.Method.unicode, vx.caps.unicode);
    try testing.expect(vx.state.in_band_resize);
    try testing.expect(vx.queries_done.load(.unordered));

    // After the probe, shift+F3 is an ordinary key.
    try fold(in, .{ .key_press = .{ .codepoint = Key.f3, .mods = .{ .shift = true } } });
    try fold(in, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });

    var buf: [8]Event = undefined;
    const n = try in.drain(&buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 20), buf[0].winsize.cols);
    try testing.expectEqual(@as(u21, Key.f3), buf[1].key_press.codepoint);
    try testing.expectEqualStrings("a", buf[2].key_press.text.?);
}

test "parse: a stream is cut at sequence boundaries and the tail carries over" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    const in = try testInput(&vx);
    defer testing.allocator.destroy(in);
    vx.queries_done.store(true, .unordered);

    var parser: vaxis.Parser = .{};
    var buf: [64]u8 = undefined;
    // "a", then an arrow key cut after its CSI: the parser cannot finish
    // `ESC [` and the two bytes wait at the front of the buffer.
    @memcpy(buf[0..3], "a\x1b[");
    var carry = try parse(in, &parser, &buf, 3);
    try testing.expectEqual(@as(usize, 2), carry);
    try testing.expectEqualStrings("\x1b[", buf[0..2]);
    // The next read completes it.
    buf[2] = 'A';
    carry = try parse(in, &parser, &buf, 3);
    try testing.expectEqual(@as(usize, 0), carry);

    var out: [8]Event = undefined;
    const n = try in.drain(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u21, 'a'), out[0].key_press.codepoint);
    try testing.expectEqual(@as(u21, Key.up), out[1].key_press.codepoint);
}

test "parse: a shifted F-key reaches the keymap as `shift+fN` whichever way the terminal spells it" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    const in = try testInput(&vx);
    defer testing.allocator.destroy(in);
    vx.queries_done.store(true, .unordered);

    const Case = struct { style: legacy_fkeys.Style, bytes: []const u8, names: []const []const u8 };
    const cases = [_]Case{
        // xterm's modifier parameter — Windows Terminal, VTE, Konsole,
        // xterm itself: vaxis reads these already.
        .{ .style = .xterm, .bytes = "\x1b[1;2R\x1b[15;2~\x1b[24;2~\x1b[15;6~", .names = &.{ "shift+f3", "shift+f5", "shift+f12", "ctrl+shift+f5" } },
        // Terminal.app: Shift+F5..F12 are the VT220's F13..F20, which
        // vaxis drops.
        .{ .style = .apple_terminal, .bytes = "\x1b[25~\x1b[28~\x1b[29~\x1b[31~\x1b[33~\x1b[34~", .names = &.{ "shift+f5", "shift+f7", "shift+f8", "shift+f9", "shift+f11", "shift+f12" } },
        // rxvt / the Linux console.
        .{ .style = .rxvt, .bytes = "\x1b[25~\x1b[32~\x1b[23$\x1b[24$", .names = &.{ "shift+f3", "shift+f8", "shift+f11", "shift+f12" } },
        // xterm's own F13 is Shift+F1; SS3 with a modifier digit.
        .{ .style = .xterm, .bytes = "\x1b[25~\x1bO2R", .names = &.{ "shift+f1", "shift+f3" } },
    };
    var parser: vaxis.Parser = .{};
    for (cases) |c| {
        in.fkeys = c.style;
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..c.bytes.len], c.bytes);
        try testing.expectEqual(@as(usize, 0), try parse(in, &parser, &buf, c.bytes.len));
        var out: [8]Event = undefined;
        const n = try in.drain(&out);
        try testing.expectEqual(c.names.len, n);
        for (c.names, out[0..n]) |want, ev| {
            var nb: [32]u8 = undefined;
            try testing.expectEqualStrings(want, keyName(ev.key_press, &nb));
        }
    }
}

test "parser distinguishes chords the legacy encoding folds together" {
    // Kitty encodes ctrl+i and tab differently; legacy sends 0x09 for both.
    var parser: vaxis.Parser = .{};
    const tab = try parser.parse("\t", null);
    try testing.expectEqual(@as(u21, Key.tab), tab.event.?.key_press.codepoint);
    const ctrl_i = try parser.parse("\x1b[105;5u", null);
    try testing.expectEqual(@as(u21, 'i'), ctrl_i.event.?.key_press.codepoint);
    try testing.expect(ctrl_i.event.?.key_press.mods.ctrl);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("tab", keyName(tab.event.?.key_press, &buf));
    try testing.expectEqualStrings("ctrl+i", keyName(ctrl_i.event.?.key_press, &buf));
    // A lone ESC (input.len == 1) is the escape key, not an alt prefix.
    const esc = try parser.parse("\x1b", null);
    try testing.expectEqual(@as(u21, Key.escape), esc.event.?.key_press.codepoint);
}
