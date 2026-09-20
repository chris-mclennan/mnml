//! mnml's key-spec grammar, turned into macOS virtual keycodes.
//!
//! `ctrl+p`, `space f f`, `enter`, `<C-w>h` — the spellings a `.test`
//! script and a `[keys]` table use — become the (keycode, modifier-flags)
//! pairs `CGEventCreateKeyboardEvent` wants.
//!
//! **Why the grammar is re-stated here rather than imported.** It lives in
//! `src/core/keymap.zig`, which is also where the chord RESOLVER lives, so
//! that file reaches `commands/specs.zig` and through it `src/app.zig`:
//! importing the parser would link the whole editor — tree-sitter, Lua,
//! oniguruma, vaxis — into a dev-only tool that posts mouse events. The
//! types are shared (`src/core/key.zig` imports nothing but std, and this
//! file speaks in its `Key` / `KeyCode` / `Mods`); only the ~40 lines of
//! prefix-stripping are restated, and `parseSpec`'s tests pin every form
//! the real grammar accepts. Splitting the parser out of keymap.zig is the
//! fix, and it is a change to a file half the tree depends on — not one to
//! make from inside a tool.
//!
//! The keycodes are the ANSI positions, which is what a virtual keycode
//! means: 12 is "the key where Q is on a US layout", whatever the user's
//! layout prints on it. Terminals read the position, so `ctrl+p` works on
//! a Dvorak machine the way the user's own `ctrl+p` does.

const std = @import("std");
const key_mod = @import("key");
const mac = @import("mac.zig");

pub const Key = key_mod.Key;
pub const KeyCode = key_mod.KeyCode;
pub const Mods = key_mod.Mods;

pub const Error = error{ BadSpec, TooManyChords, Unmappable };

/// Longest chord chain accepted, matching `keymap.max_seq`.
pub const max_seq = 8;

// ─── the grammar ────────────────────────────────────────────────────────

fn stripAny(s: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |p| {
        if (s.len > p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p)) return s[p.len..];
    }
    return null;
}

/// One chord token: modifiers in any order and any case, then one named
/// key or one character.
pub fn parseChord(spec_in: []const u8) ?Key {
    const spec = std.mem.trim(u8, spec_in, " \t\r\n");
    if (spec.len == 0) return null;
    var mods: Mods = .{};
    var rest = spec;
    while (true) {
        if (stripAny(rest, &.{ "ctrl+", "c-" })) |r| {
            mods.ctrl = true;
            rest = r;
        } else if (stripAny(rest, &.{ "shift+", "s-" })) |r| {
            mods.shift = true;
            rest = r;
        } else if (stripAny(rest, &.{ "alt+", "a-", "meta+", "opt+" })) |r| {
            mods.alt = true;
            rest = r;
        } else if (stripAny(rest, &.{ "super+", "cmd+", "win+", "d-" })) |r| {
            mods.super = true;
            rest = r;
        } else break;
    }
    if (rest.len == 0) return null;
    const code: KeyCode = named(rest) orelse blk: {
        var it = std.unicode.Utf8View.init(rest) catch return null;
        var cps = it.iterator();
        const first = cps.nextCodepoint() orelse return null;
        if (cps.nextCodepoint() != null) return null;
        break :blk .{ .char = first };
    };
    return .{ .code = code, .mods = mods };
}

fn named(word: []const u8) ?KeyCode {
    const Pair = struct { []const u8, KeyCode };
    const table = [_]Pair{
        .{ "enter", .enter },        .{ "return", .enter },          .{ "cr", .enter },
        .{ "tab", .tab },            .{ "backtab", .backtab },       .{ "esc", .esc },
        .{ "escape", .esc },         .{ "space", .{ .char = ' ' } }, .{ "backspace", .backspace },
        .{ "bs", .backspace },       .{ "delete", .delete },         .{ "del", .delete },
        .{ "insert", .insert },      .{ "up", .up },                 .{ "down", .down },
        .{ "left", .left },          .{ "right", .right },           .{ "home", .home },
        .{ "end", .end },            .{ "pageup", .page_up },        .{ "pgup", .page_up },
        .{ "pagedown", .page_down }, .{ "pgdn", .page_down },
    };
    for (table) |p| {
        if (std.ascii.eqlIgnoreCase(word, p[0])) return p[1];
    }
    if ((word[0] == 'f' or word[0] == 'F') and word.len >= 2) {
        const n = std.fmt.parseInt(u8, word[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return .{ .f = n };
    }
    return null;
}

/// `<C-w>h` / `<leader>ff` spellings, flattened to space-separated
/// tokens. A line-for-line twin of `keymap.normalizeSpec`, including its
/// one load-bearing shortcut: a spec with no `<` is returned untouched,
/// which is why `ctrl+p` does not come back as `c t r l + p` while
/// `<leader>ff` does become three tokens.
fn normalize(spec: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, spec, '<') == null) return spec;
    var w: std.Io.Writer = .fixed(out);
    var i: usize = 0;
    var need_sep = false;
    while (i < spec.len) {
        const c = spec[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (need_sep) w.writeByte(' ') catch return null;
        need_sep = true;
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, spec, i, '>') orelse return null;
            var body = spec[i + 1 .. close];
            i = close + 1;
            while (body.len >= 2 and body[1] == '-') {
                const m: []const u8 = switch (body[0]) {
                    'C', 'c' => "ctrl+",
                    'S', 's' => "shift+",
                    'M', 'm', 'A', 'a' => "alt+",
                    'D', 'd' => "super+",
                    else => return null,
                };
                w.writeAll(m) catch return null;
                body = body[2..];
            }
            const name: []const u8 = if (std.ascii.eqlIgnoreCase(body, "leader") or std.ascii.eqlIgnoreCase(body, "space"))
                "space"
            else if (std.ascii.eqlIgnoreCase(body, "cr") or std.ascii.eqlIgnoreCase(body, "enter") or std.ascii.eqlIgnoreCase(body, "return"))
                "enter"
            else if (std.ascii.eqlIgnoreCase(body, "esc") or std.ascii.eqlIgnoreCase(body, "escape"))
                "esc"
            else if (std.ascii.eqlIgnoreCase(body, "bs"))
                "backspace"
            else if (std.ascii.eqlIgnoreCase(body, "del"))
                "delete"
            else if (std.ascii.eqlIgnoreCase(body, "lt"))
                "<"
            else if (std.ascii.eqlIgnoreCase(body, "gt"))
                ">"
            else
                body;
            // A named key is lower-cased so `<Tab>` is `tab`; a single
            // character keeps its case, so `<C-P>` stays shift-bearing.
            if (name.len > 1) {
                for (name) |ch| w.writeByte(std.ascii.toLower(ch)) catch return null;
            } else {
                w.writeAll(name) catch return null;
            }
        } else {
            const n = std.unicode.utf8ByteSequenceLength(c) catch return null;
            if (i + n > spec.len) return null;
            w.writeAll(spec[i .. i + n]) catch return null;
            i += n;
        }
    }
    return w.buffered();
}

/// A whole spec: one chord or a chain of them.
pub fn parseSpec(spec: []const u8, out: []Key) Error![]Key {
    var norm_buf: [512]u8 = undefined;
    const norm = normalize(spec, &norm_buf) orelse return error.BadSpec;
    var it = std.mem.tokenizeAny(u8, norm, " \t\r\n");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= out.len) return error.TooManyChords;
        out[n] = parseChord(tok) orelse return error.BadSpec;
        n += 1;
    }
    if (n == 0) return error.BadSpec;
    return out[0..n];
}

// ─── the keycodes ───────────────────────────────────────────────────────

pub const Stroke = struct { keycode: u16, flags: u64 };

/// ANSI virtual keycodes, by the character the US layout prints.
const ansi = [_]struct { u8, u16 }{
    .{ 'a', 0 },   .{ 's', 1 },  .{ 'd', 2 },   .{ 'f', 3 },  .{ 'h', 4 },
    .{ 'g', 5 },   .{ 'z', 6 },  .{ 'x', 7 },   .{ 'c', 8 },  .{ 'v', 9 },
    .{ 'b', 11 },  .{ 'q', 12 }, .{ 'w', 13 },  .{ 'e', 14 }, .{ 'r', 15 },
    .{ 'y', 16 },  .{ 't', 17 }, .{ '1', 18 },  .{ '2', 19 }, .{ '3', 20 },
    .{ '4', 21 },  .{ '6', 22 }, .{ '5', 23 },  .{ '=', 24 }, .{ '9', 25 },
    .{ '7', 26 },  .{ '-', 27 }, .{ '8', 28 },  .{ '0', 29 }, .{ ']', 30 },
    .{ 'o', 31 },  .{ 'u', 32 }, .{ '[', 33 },  .{ 'i', 34 }, .{ 'p', 35 },
    .{ 'l', 37 },  .{ 'j', 38 }, .{ '\'', 39 }, .{ 'k', 40 }, .{ ';', 41 },
    .{ '\\', 42 }, .{ ',', 43 }, .{ '/', 44 },  .{ 'n', 45 }, .{ 'm', 46 },
    .{ '.', 47 },  .{ '`', 50 }, .{ ' ', 49 },
};

/// The shifted face of each of those keys, so `?` is shift+`/` rather than
/// an unmappable character.
const shifted = [_]struct { u8, u8 }{
    .{ '!', '1' }, .{ '@', '2' },  .{ '#', '3' }, .{ '$', '4' }, .{ '%', '5' },
    .{ '^', '6' }, .{ '&', '7' },  .{ '*', '8' }, .{ '(', '9' }, .{ ')', '0' },
    .{ '_', '-' }, .{ '+', '=' },  .{ '{', '[' }, .{ '}', ']' }, .{ '|', '\\' },
    .{ ':', ';' }, .{ '"', '\'' }, .{ '<', ',' }, .{ '>', '.' }, .{ '?', '/' },
    .{ '~', '`' },
};

fn ansiCode(c: u8) ?u16 {
    for (ansi) |p| {
        if (p[0] == c) return p[1];
    }
    return null;
}

/// The one place a `Key` becomes something `CGEvent` understands.
pub fn stroke(k: Key) Error!Stroke {
    var flags: u64 = 0;
    if (k.mods.ctrl) flags |= mac.flag_control;
    if (k.mods.shift) flags |= mac.flag_shift;
    if (k.mods.alt) flags |= mac.flag_alternate;
    if (k.mods.super) flags |= mac.flag_command;
    const code: u16 = switch (k.code) {
        .enter => 36,
        .tab => 48,
        .backtab => blk: {
            flags |= mac.flag_shift;
            break :blk 48;
        },
        .esc => 53,
        .backspace => 51,
        .delete => 117,
        .insert => 114,
        .up => 126,
        .down => 125,
        .left => 123,
        .right => 124,
        .home => 115,
        .end => 119,
        .page_up => 116,
        .page_down => 121,
        .f => |n| switch (n) {
            1 => 122,
            2 => 120,
            3 => 99,
            4 => 118,
            5 => 96,
            6 => 97,
            7 => 98,
            8 => 100,
            9 => 101,
            10 => 109,
            11 => 103,
            12 => 111,
            else => return error.Unmappable,
        },
        .char => |cp| blk: {
            if (cp > 127) return error.Unmappable;
            const c: u8 = @intCast(cp);
            // An uppercase letter IS shift plus the lowercase key; a
            // `.test` writes `key G` and means what the user's finger
            // does, so the modifier is added rather than demanded.
            if (c >= 'A' and c <= 'Z') {
                flags |= mac.flag_shift;
                break :blk ansiCode(c + ('a' - 'A')).?;
            }
            for (shifted) |p| {
                if (p[0] == c) {
                    flags |= mac.flag_shift;
                    break :blk ansiCode(p[1]).?;
                }
            }
            break :blk ansiCode(c) orelse return error.Unmappable;
        },
    };
    return .{ .keycode = code, .flags = flags };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "parseSpec: the grammar's forms, chords and chains" {
    var buf: [max_seq]Key = undefined;

    const one = try parseSpec("ctrl+p", &buf);
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expect(one[0].mods.ctrl);
    try t.expectEqual(@as(u21, 'p'), one[0].code.char);

    // Every modifier spelling the real grammar takes, in any case.
    for ([_][]const u8{ "C-p", "CTRL+p", "c-P" }) |spec| {
        const k = (try parseSpec(spec, &buf))[0];
        try t.expect(k.mods.ctrl);
    }
    const sup = (try parseSpec("cmd+shift+k", &buf))[0];
    try t.expect(sup.mods.super and sup.mods.shift);

    // A chain, and `<leader>` as Space.
    const chain = try parseSpec("space f f", &buf);
    try t.expectEqual(@as(usize, 3), chain.len);
    try t.expectEqual(@as(u21, ' '), chain[0].code.char);
    const leader = try parseSpec("<leader>ff", &buf);
    try t.expectEqual(@as(usize, 3), leader.len);
    try t.expectEqual(@as(u21, ' '), leader[0].code.char);
    const angle = try parseSpec("<C-w>h", &buf);
    try t.expectEqual(@as(usize, 2), angle.len);
    try t.expect(angle[0].mods.ctrl);
    try t.expectEqual(@as(u21, 'h'), angle[1].code.char);

    // Named keys.
    try t.expect((try parseSpec("enter", &buf))[0].code == .enter);
    try t.expect((try parseSpec("ESC", &buf))[0].code == .esc);
    try t.expect((try parseSpec("pgdn", &buf))[0].code == .page_down);
    try t.expectEqual(@as(u8, 5), (try parseSpec("f5", &buf))[0].code.f);

    try t.expectError(error.BadSpec, parseSpec("", &buf));
    try t.expectError(error.BadSpec, parseSpec("ctrl+", &buf));
    try t.expectError(error.BadSpec, parseSpec("nosuchkey", &buf));
}

test "stroke: keycodes are ANSI positions and a shifted face carries its shift" {
    var buf: [max_seq]Key = undefined;

    // ctrl+p is the P POSITION (35) with the control flag — what makes
    // the terminal send 0x10 whatever the user's layout prints there.
    const cp = try stroke((try parseSpec("ctrl+p", &buf))[0]);
    try t.expectEqual(@as(u16, 35), cp.keycode);
    try t.expectEqual(mac.flag_control, cp.flags);

    // An uppercase letter is shift plus the lowercase key, not a key of
    // its own: `key G` in a .test means the finger, not the glyph.
    const g = try stroke((try parseSpec("G", &buf))[0]);
    try t.expectEqual(@as(u16, 5), g.keycode);
    try t.expectEqual(mac.flag_shift, g.flags);

    // And a shifted punctuation face resolves to its unshifted key.
    const q = try stroke((try parseSpec("?", &buf))[0]);
    try t.expectEqual(@as(u16, 44), q.keycode); // the `/` key
    try t.expectEqual(mac.flag_shift, q.flags);

    try t.expectEqual(@as(u16, 36), (try stroke((try parseSpec("enter", &buf))[0])).keycode);
    try t.expectEqual(@as(u16, 53), (try stroke((try parseSpec("esc", &buf))[0])).keycode);
    try t.expectEqual(@as(u16, 49), (try stroke((try parseSpec("space", &buf))[0])).keycode);
    try t.expectEqual(@as(u16, 126), (try stroke((try parseSpec("up", &buf))[0])).keycode);
    try t.expectEqual(@as(u16, 96), (try stroke((try parseSpec("f5", &buf))[0])).keycode);

    // backtab IS shift+tab on this platform; nothing else is.
    const bt = try stroke((try parseSpec("backtab", &buf))[0]);
    try t.expectEqual(@as(u16, 48), bt.keycode);
    try t.expectEqual(mac.flag_shift, bt.flags);

    // Anything off the ANSI layout is refused rather than posted as some
    // other key: `type` is the verb for text.
    try t.expectError(error.Unmappable, stroke(.{ .code = .{ .char = 'é' } }));
}

test "all four modifier flags reach the event" {
    var buf: [max_seq]Key = undefined;
    const s = try stroke((try parseSpec("ctrl+shift+alt+cmd+a", &buf))[0]);
    try t.expectEqual(@as(u16, 0), s.keycode);
    try t.expectEqual(mac.flag_control | mac.flag_shift | mac.flag_alternate | mac.flag_command, s.flags);
}
