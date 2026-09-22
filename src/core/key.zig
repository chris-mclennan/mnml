//! Terminal input events as the trunk sees them. The tui layer converts
//! whatever the terminal library reports into these; nothing above the
//! tui imports a terminal library.
//!
//! `Key` is the raw event. `Chord` is the normalized lookup key the
//! keymap uses: an uppercase char is lowered and `shift` made explicit,
//! so `P` and `shift+p` — and however a given terminal reports them —
//! collapse to one chord. Everything else is kept (`ctrl+shift+p` needs
//! its shift).

const std = @import("std");

pub const Mods = packed struct(u4) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub const none: Mods = .{};

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }
};

pub const KeyCode = union(enum) {
    char: u21,
    enter,
    tab,
    backtab,
    esc,
    backspace,
    delete,
    insert,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f: u8,

    pub fn eql(a: KeyCode, b: KeyCode) bool {
        return std.meta.eql(a, b);
    }
};

pub const Key = struct {
    code: KeyCode,
    mods: Mods = .{},

    pub fn char(c: u21) Key {
        return .{ .code = .{ .char = c } };
    }
    pub fn ctrl(c: u21) Key {
        return .{ .code = .{ .char = c }, .mods = .{ .ctrl = true } };
    }
    pub fn named(code: KeyCode) Key {
        return .{ .code = code };
    }

    /// The one spelling of a shifted Tab. A terminal never sends
    /// `.tab` with shift: it reports its own back-tab code and drops the
    /// modifier, and `tui/loop.zig`'s `translateKey` folds vaxis's form
    /// the same way. So every other spelling — `shift+tab`, `<S-Tab>`,
    /// `ctrl+shift+tab`, `shift+backtab` — folds onto `.backtab` here,
    /// and a key spec can no longer name a key no terminal will send.
    pub fn canonical(k: Key) Key {
        var mods = k.mods;
        const code: KeyCode = switch (k.code) {
            .tab => if (mods.shift) blk: {
                mods.shift = false;
                break :blk .backtab;
            } else .tab,
            .backtab => blk: {
                mods.shift = false;
                break :blk .backtab;
            },
            else => k.code,
        };
        return .{ .code = code, .mods = mods };
    }

    /// The character this key would type, if any: a plain or shift-only
    /// char. `ctrl+a` types nothing.
    pub fn typed(k: Key) ?u21 {
        if (k.mods.ctrl or k.mods.alt or k.mods.super) return null;
        return switch (k.code) {
            .char => |c| c,
            else => null,
        };
    }
};

pub const Chord = struct {
    code: KeyCode,
    mods: Mods,

    pub fn of(k_in: Key) Chord {
        const k = k_in.canonical();
        var mods = k.mods;
        const code: KeyCode = switch (k.code) {
            .char => |c| if (c >= 'A' and c <= 'Z') blk: {
                mods.shift = true;
                break :blk .{ .char = c + ('a' - 'A') };
            } else .{ .char = c },
            else => |other| other,
        };
        return .{ .code = code, .mods = mods };
    }

    pub fn eql(a: Chord, b: Chord) bool {
        return a.mods.eql(b.mods) and a.code.eql(b.code);
    }

    /// Dense encoding used as a hash-map key: `mods:4 | tag:8 | payload:21`.
    pub fn pack(c: Chord) u64 {
        const tag: u64 = @intFromEnum(std.meta.activeTag(c.code));
        const payload: u64 = switch (c.code) {
            .char => |ch| ch,
            .f => |n| n,
            else => 0,
        };
        return (@as(u64, @as(u4, @bitCast(c.mods))) << 40) | (tag << 32) | payload;
    }

    pub fn unpack(v: u64) Chord {
        const mods: Mods = @bitCast(@as(u4, @truncate(v >> 40)));
        const tag: std.meta.Tag(KeyCode) = @enumFromInt(@as(u8, @truncate(v >> 32)));
        const payload: u32 = @truncate(v);
        const code: KeyCode = switch (tag) {
            .char => .{ .char = @intCast(payload) },
            .f => .{ .f = @intCast(payload) },
            inline else => |t| @unionInit(KeyCode, @tagName(t), {}),
        };
        return .{ .code = code, .mods = mods };
    }

    /// Canonical spec (`ctrl+shift+p`, `enter`, `f5`, `space`). Round-trips
    /// through `keymap.parseKeySpec` for every chord mnml binds.
    pub fn format(c: Chord, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (c.mods.ctrl) try w.writeAll("ctrl+");
        if (c.mods.alt) try w.writeAll("alt+");
        if (c.mods.shift) try w.writeAll("shift+");
        if (c.mods.super) try w.writeAll("super+");
        switch (c.code) {
            .char => |ch| if (ch == ' ') try w.writeAll("space") else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &buf) catch 1;
                try w.writeAll(buf[0..n]);
            },
            .f => |n| try w.print("f{d}", .{n}),
            inline else => |_, t| try w.writeAll(switch (t) {
                .enter => "enter",
                .tab => "tab",
                .backtab => "backtab",
                .esc => "esc",
                .backspace => "backspace",
                .delete => "delete",
                .insert => "insert",
                .up => "up",
                .down => "down",
                .left => "left",
                .right => "right",
                .home => "home",
                .end => "end",
                .page_up => "pageup",
                .page_down => "pagedown",
                .char, .f => unreachable,
            }),
        }
    }
};

pub const MouseButton = enum { left, right, middle, none };
pub const MouseKind = enum { press, release, drag, motion, scroll_up, scroll_down };

pub const Mouse = struct {
    x: u16,
    y: u16,
    kind: MouseKind,
    button: MouseButton = .none,
    mods: Mods = .{},
};

pub const Winsize = struct {
    cols: u16,
    rows: u16,
};

test "chord folds an uppercase char into shift + lowercase" {
    const a = Chord.of(.{ .code = .{ .char = 'P' } });
    const b = Chord.of(.{ .code = .{ .char = 'p' }, .mods = .{ .shift = true } });
    try std.testing.expect(a.eql(b));
    try std.testing.expect(a.mods.shift);
    try std.testing.expectEqual(@as(u21, 'p'), a.code.char);
}

test "chord pack/unpack round-trips every code" {
    const samples = [_]Chord{
        .{ .code = .{ .char = 'x' }, .mods = .{ .ctrl = true, .shift = true } },
        .{ .code = .{ .char = 0x1F600 }, .mods = .{} },
        .{ .code = .{ .f = 12 }, .mods = .{ .alt = true } },
        .{ .code = .page_down, .mods = .{ .super = true } },
        .{ .code = .enter, .mods = .{} },
    };
    for (samples) |c| try std.testing.expect(c.eql(Chord.unpack(c.pack())));
}

test "chord formats to its canonical spec" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Chord{ .code = .{ .char = 'p' }, .mods = .{ .ctrl = true, .shift = true } }).format(&w);
    try std.testing.expectEqualStrings("ctrl+shift+p", w.buffered());
    w = .fixed(&buf);
    try (Chord{ .code = .{ .char = ' ' }, .mods = .{} }).format(&w);
    try std.testing.expectEqualStrings("space", w.buffered());
    w = .fixed(&buf);
    try (Chord{ .code = .{ .f = 5 }, .mods = .{} }).format(&w);
    try std.testing.expectEqualStrings("f5", w.buffered());
}
