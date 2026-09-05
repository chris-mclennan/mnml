//! What a terminal session knows about its terminal, and the verdicts
//! that come from the environment rather than from the probe. Shared by
//! `term_posix.zig` and `term_windows.zig`: neither backend decides
//! truecolor or Terminal.app's quirks differently, only how it reaches
//! the tty.

const std = @import("std");
const vaxis = @import("vaxis");

const Io = std.Io;

/// What the terminal told us, plus what the environment implies.
pub const Capabilities = struct {
    /// CSI u — chords like `ctrl+shift+p` are distinguishable.
    kitty_keyboard: bool = false,
    /// Kitty graphics protocol answered the `a=q` probe.
    kitty_graphics: bool = false,
    /// 24-bit SGR. Decided by `detectRgb`, not by the terminal.
    rgb: bool = false,
    /// How the terminal measures graphemes: mode 2027 / explicit width ⇒
    /// `.unicode`, otherwise wcwidth.
    unicode: vaxis.gwidth.Method = .wcwidth,
    /// Mode 1016 — mouse reports carry pixel offsets.
    sgr_pixels: bool = false,
    /// Mode 2048 — the terminal reports its size in-band; SIGWINCH (or
    /// the console's resize record) is redundant.
    in_band_resize: bool = false,
    /// OSC 66 explicit width (ghostty, kitty ≥ 0.40).
    explicit_width: bool = false,

    /// One line for a status bar: `kbd=kitty gfx=kitty rgb=24bit …`.
    pub fn write(caps: Capabilities, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("kbd={s} gfx={s} rgb={s} width={s} mouse={s} resize={s}", .{
            if (caps.kitty_keyboard) "kitty" else "legacy",
            if (caps.kitty_graphics) "kitty" else "none",
            if (caps.rgb) "24bit" else "256",
            switch (caps.unicode) {
                .unicode => if (caps.explicit_width) "explicit" else "2027",
                .wcwidth => "wcwidth",
                .no_zwj => "no-zwj",
            },
            if (caps.sgr_pixels) "pixels" else "cells",
            if (caps.in_band_resize) "in-band" else "sigwinch",
        });
    }

    pub fn format(caps: Capabilities, w: *Io.Writer) Io.Writer.Error!void {
        return caps.write(w);
    }
};

pub const Options = struct {
    alt_screen: bool = true,
    mouse: bool = true,
    bracketed_paste: bool = true,
    /// Push the kitty keyboard flags when the terminal answered `CSI ? u`.
    kitty_keyboard: bool = true,
    kitty_flags: vaxis.Key.KittyFlags = .{},
    /// How long to wait for the DA1 reply that ends the probe. A terminal
    /// that never answers costs exactly this much at startup.
    query_timeout_ms: i64 = 1000,
    /// Override the environment's truecolor verdict (`null` = detect).
    rgb: ?bool = null,
};

// ── what the probe gets wrong ──

/// Corrections to what the probe concluded, for terminals known to answer
/// it misleadingly.
///
/// Apple Terminal does not know OSC 66. It prints the payload of the
/// explicit-width probe (`OSC 66 ; w=1 ; SPACE ST`) as text, the space
/// moves the cursor to column 2, and the cursor-position reply reads as
/// "explicit width works". vaxis then wraps every wide glyph in OSC 66 —
/// which Terminal.app swallows whole, so CJK and emoji vanish and the row
/// drifts. It has neither mode 2027 nor OSC 66: wcwidth, always.
pub fn applyTerminalQuirks(caps: *vaxis.Vaxis.Capabilities, env: *const std.process.Environ.Map) void {
    const prog = env.get("TERM_PROGRAM") orelse return;
    if (std.mem.eql(u8, prog, "Apple_Terminal")) {
        caps.explicit_width = false;
        caps.scaled_text = false;
        caps.unicode = .wcwidth;
    }
}

/// vaxis spells indexed and rgb colors with colon sub-parameters
/// (`38:5:n`, `38:2:r:g:b`) — the kitty-era form. Terminal.app and the
/// other terminals that never learned CSI u ignore the whole sequence,
/// so every color vanishes (the gallery painted white-on-dark in
/// Terminal.app). The semicolon form is understood everywhere, so it
/// is the spelling for any terminal that did not answer the kitty
/// keyboard query, and for Terminal.app regardless.
pub fn legacySgr(env: *const std.process.Environ.Map, kitty_keyboard: bool) bool {
    if (env.get("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "Apple_Terminal")) return true;
    }
    return !kitty_keyboard;
}

// ── truecolor ──

/// vaxis never sets `caps.rgb`, and no probe answers "24-bit". The
/// environment is the best signal we have:
///  - Terminal.app advertises `COLORTERM=truecolor` but renders 24-bit
///    SGR badly, so it is folded to 256 regardless.
///  - `COLORTERM=truecolor|24bit` is the convention everyone else honours.
///  - ghostty, kitty, WezTerm, iTerm2 are rgb whether or not COLORTERM
///    survived a `tmux`/`ssh` hop.
///  - Windows Terminal sets no COLORTERM at all; `WT_SESSION` is how it
///    announces itself, and it has been 24-bit since 1.0. ConEmu says
///    `ConEmuANSI=ON`.
pub fn detectRgb(env: *const std.process.Environ.Map) bool {
    if (env.get("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "Apple_Terminal")) return false;
        for ([_][]const u8{ "ghostty", "kitty", "WezTerm", "iTerm.app" }) |rgb_prog| {
            if (std.mem.eql(u8, prog, rgb_prog)) return true;
        }
    }
    if (env.get("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return true;
    }
    if (env.get("TERM")) |term| {
        for ([_][]const u8{ "xterm-ghostty", "xterm-kitty" }) |rgb_term| {
            if (std.mem.eql(u8, term, rgb_term)) return true;
        }
        if (std.mem.endsWith(u8, term, "-direct")) return true;
    }
    if (env.get("WT_SESSION")) |wt| if (wt.len > 0) return true;
    if (env.get("ConEmuANSI")) |on| if (std.mem.eql(u8, on, "ON")) return true;
    return false;
}

// ── tests ──

const testing = std.testing;

fn envWith(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "detectRgb: COLORTERM says truecolor, except in Terminal.app" {
    var a = try envWith(&.{.{ "COLORTERM", "truecolor" }});
    defer a.deinit();
    try testing.expect(detectRgb(&a));

    var b = try envWith(&.{ .{ "COLORTERM", "truecolor" }, .{ "TERM_PROGRAM", "Apple_Terminal" } });
    defer b.deinit();
    try testing.expect(!detectRgb(&b));

    var c = try envWith(&.{.{ "COLORTERM", "24bit" }});
    defer c.deinit();
    try testing.expect(detectRgb(&c));
}

test "detectRgb: the rgb terminals count without COLORTERM; xterm alone does not" {
    var ghostty = try envWith(&.{ .{ "TERM_PROGRAM", "ghostty" }, .{ "TERM", "xterm-ghostty" } });
    defer ghostty.deinit();
    try testing.expect(detectRgb(&ghostty));

    var kitty = try envWith(&.{.{ "TERM", "xterm-kitty" }});
    defer kitty.deinit();
    try testing.expect(detectRgb(&kitty));

    var direct = try envWith(&.{.{ "TERM", "tmux-direct" }});
    defer direct.deinit();
    try testing.expect(detectRgb(&direct));

    var plain = try envWith(&.{.{ "TERM", "xterm-256color" }});
    defer plain.deinit();
    try testing.expect(!detectRgb(&plain));

    var empty = try envWith(&.{});
    defer empty.deinit();
    try testing.expect(!detectRgb(&empty));
}

test "detectRgb: Windows Terminal announces itself with WT_SESSION, ConEmu with ConEmuANSI" {
    var wt = try envWith(&.{.{ "WT_SESSION", "8f2d1c9e-0000-4000-8000-000000000000" }});
    defer wt.deinit();
    try testing.expect(detectRgb(&wt));

    var wt_empty = try envWith(&.{.{ "WT_SESSION", "" }});
    defer wt_empty.deinit();
    try testing.expect(!detectRgb(&wt_empty));

    var conemu = try envWith(&.{.{ "ConEmuANSI", "ON" }});
    defer conemu.deinit();
    try testing.expect(detectRgb(&conemu));

    var conemu_off = try envWith(&.{.{ "ConEmuANSI", "OFF" }});
    defer conemu_off.deinit();
    try testing.expect(!detectRgb(&conemu_off));
}

test "applyTerminalQuirks: Apple Terminal's false explicit-width claim is dropped" {
    var apple = try envWith(&.{.{ "TERM_PROGRAM", "Apple_Terminal" }});
    defer apple.deinit();
    var caps: vaxis.Vaxis.Capabilities = .{ .explicit_width = true, .scaled_text = true, .unicode = .unicode };
    applyTerminalQuirks(&caps, &apple);
    try testing.expect(!caps.explicit_width);
    try testing.expect(!caps.scaled_text);
    try testing.expectEqual(vaxis.gwidth.Method.wcwidth, caps.unicode);

    // ghostty's claim stands.
    var ghostty = try envWith(&.{.{ "TERM_PROGRAM", "ghostty" }});
    defer ghostty.deinit();
    caps = .{ .explicit_width = true, .unicode = .unicode };
    applyTerminalQuirks(&caps, &ghostty);
    try testing.expect(caps.explicit_width);
    try testing.expectEqual(vaxis.gwidth.Method.unicode, caps.unicode);
}

test "legacySgr: Terminal.app always, otherwise whoever lacks the kitty keyboard" {
    var apple = try envWith(&.{.{ "TERM_PROGRAM", "Apple_Terminal" }});
    defer apple.deinit();
    try testing.expect(legacySgr(&apple, true));
    var ghostty = try envWith(&.{.{ "TERM_PROGRAM", "ghostty" }});
    defer ghostty.deinit();
    try testing.expect(!legacySgr(&ghostty, true));
    try testing.expect(legacySgr(&ghostty, false));
}

test "Capabilities.write: one status-line summary" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try (Capabilities{}).write(&w);
    try testing.expectEqualStrings("kbd=legacy gfx=none rgb=256 width=wcwidth mouse=cells resize=sigwinch", w.buffered());

    w = .fixed(&buf);
    const ghostty: Capabilities = .{
        .kitty_keyboard = true,
        .kitty_graphics = true,
        .rgb = true,
        .unicode = .unicode,
        .explicit_width = true,
        .sgr_pixels = true,
        .in_band_resize = true,
    };
    try ghostty.write(&w);
    try testing.expectEqualStrings("kbd=kitty gfx=kitty rgb=24bit width=explicit mouse=pixels resize=in-band", w.buffered());
}
