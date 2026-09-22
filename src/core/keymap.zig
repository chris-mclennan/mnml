//! Key-spec grammar + the per-profile chord resolver.
//!
//! `parseKeySpec` turns `"ctrl+shift+p"`, `"enter"`, `"down"`, `"a"` into a
//! `Key`. It is comptime-callable so every default chord in
//! `commands/specs.zig` is validated when the binary is built. The
//! grammar is the one mnml has always had (E3): modifiers `ctrl+|c-`,
//! `shift+|s-`, `alt+|a-|meta+`, `super+|cmd+|win+` in any order and any
//! case, then one named key or one character. `<C-p>` / `<leader>ia`
//! spellings are accepted through a normalizing pre-pass and stored in
//! the canonical form.
//!
//! `Keymap` is the one table app-level chords resolve through: built from
//! the active profile's default chords, then `[keys.global]`, then
//! `[keys.<profile>]`. `resolveSeq` is chord-chain aware.

const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("key.zig");
const Key = key_mod.Key;
const KeyCode = key_mod.KeyCode;
const Mods = key_mod.Mods;
const Chord = key_mod.Chord;
const command = @import("command.zig");
const specs = @import("../commands/specs.zig");

pub const Profile = enum { vim, standard };

/// Longest chord chain a binding may have.
pub const max_seq = 8;

// ─── parsing ────────────────────────────────────────────────────────────

/// Parse one chord token. Returns null for anything unrecognized.
pub fn parseKeySpec(spec_in: []const u8) ?Key {
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
        } else if (stripAny(rest, &.{ "alt+", "a-", "meta+" })) |r| {
            mods.alt = true;
            rest = r;
        } else if (stripAny(rest, &.{ "super+", "cmd+", "win+" })) |r| {
            mods.super = true;
            rest = r;
        } else break;
    }
    const code = keyCode(rest) orelse return null;
    // `Key.canonical` is the one place a chord's spelling is settled, so
    // a spec, a `.test` `key` directive and an IPC `key` verb all name
    // exactly what a terminal sends (`shift+tab` → `backtab`).
    return (Key{ .code = code, .mods = mods }).canonical();
}

/// Strip the first of `prefixes` that matches case-insensitively.
fn stripAny(s: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |prefix| {
        if (s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return s[prefix.len..];
    }
    return null;
}

const Named = struct { []const u8, KeyCode };
const named_keys = [_]Named{
    .{ "enter", .enter },                  .{ "return", .enter },               .{ "cr", .enter },
    .{ "tab", .tab },                      .{ "backtab", .backtab },            .{ "esc", .esc },
    .{ "escape", .esc },                   .{ "space", .{ .char = ' ' } },      .{ "leader", .{ .char = ' ' } },
    .{ "backspace", .backspace },          .{ "bs", .backspace },               .{ "delete", .delete },
    .{ "del", .delete },                   .{ "insert", .insert },              .{ "ins", .insert },
    .{ "up", .up },                        .{ "down", .down },                  .{ "left", .left },
    .{ "right", .right },                  .{ "home", .home },                  .{ "end", .end },
    .{ "pageup", .page_up },               .{ "pgup", .page_up },               .{ "pagedown", .page_down },
    .{ "pgdn", .page_down },               .{ "pgdown", .page_down },           .{ "f1", .{ .f = 1 } },
    .{ "f2", .{ .f = 2 } },                .{ "f3", .{ .f = 3 } },              .{ "f4", .{ .f = 4 } },
    .{ "f5", .{ .f = 5 } },                .{ "f6", .{ .f = 6 } },              .{ "f7", .{ .f = 7 } },
    .{ "f8", .{ .f = 8 } },                .{ "f9", .{ .f = 9 } },              .{ "f10", .{ .f = 10 } },
    .{ "f11", .{ .f = 11 } },              .{ "f12", .{ .f = 12 } },
    // Named punctuation: `ctrl+minus` is spellable where `ctrl+-` reads
    // badly and `ctrl++` cannot be written at all.
               .{ "minus", .{ .char = '-' } },
    .{ "dash", .{ .char = '-' } },         .{ "underscore", .{ .char = '_' } }, .{ "plus", .{ .char = '+' } },
    .{ "equal", .{ .char = '=' } },        .{ "equals", .{ .char = '=' } },     .{ "comma", .{ .char = ',' } },
    .{ "period", .{ .char = '.' } },       .{ "dot", .{ .char = '.' } },        .{ "slash", .{ .char = '/' } },
    .{ "backslash", .{ .char = '\\' } },   .{ "semicolon", .{ .char = ';' } },  .{ "quote", .{ .char = '\'' } },
    .{ "grave", .{ .char = '`' } },        .{ "backtick", .{ .char = '`' } },   .{ "bracketleft", .{ .char = '[' } },
    .{ "bracketright", .{ .char = ']' } },
};

fn keyCode(token: []const u8) ?KeyCode {
    for (named_keys) |n| {
        if (std.ascii.eqlIgnoreCase(token, n[0])) return n[1];
    }
    // A single character (any script) — case preserved; `Chord.of` folds it.
    if (token.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(token[0]) catch return null;
    if (n != token.len) return null;
    const c = std.unicode.utf8Decode(token[0..n]) catch return null;
    return .{ .char = c };
}

/// Normalize `<C-p>` / `<S-Tab>` / `<leader>ia` spellings into the
/// canonical whitespace-separated grammar. Only invoked when the spec
/// contains `<`; a canonical spec passes through untouched. Chars outside
/// an angle group become one chord each (`<leader>ia` → `space i a`).
/// Returns null when the output does not fit or a group is unterminated.
pub fn normalizeSpec(spec: []const u8, out: []u8) ?[]const u8 {
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
            // Modifier groups: C- S- M- A- D- in any order.
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
            // Lower-case named keys so `<Tab>` → `tab`; a single char keeps
            // its case so `<C-P>` stays shift-significant through `Chord.of`.
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

/// Parse a chord chain into `out`. Returns the filled prefix of `out`, or
/// null if any token fails to parse, the chain is empty, or it overflows.
pub fn parseKeySeqBuf(spec: []const u8, out: []Chord) ?[]Chord {
    var norm_buf: [256]u8 = undefined;
    const norm = normalizeSpec(spec, &norm_buf) orelse return null;
    var it = std.mem.tokenizeAny(u8, norm, " \t\r\n");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= out.len) return null;
        const k = parseKeySpec(tok) orelse return null;
        out[n] = Chord.of(k);
        n += 1;
    }
    if (n == 0) return null;
    return out[0..n];
}

/// Comptime form: the sequence lives in the binary's rodata.
pub fn parseKeySeqComptime(comptime spec: []const u8) ?[]const Chord {
    comptime {
        var buf: [max_seq]Chord = undefined;
        const got = parseKeySeqBuf(spec, &buf) orelse return null;
        const frozen = buf[0..got.len].*;
        return &frozen;
    }
}

// ─── the resolver ───────────────────────────────────────────────────────

/// What a binding fires. `named` is a command the keymap could not
/// resolve statically (a plugin / IPC command bound in config before it
/// registered); it is looked up in the dynamic registry when pressed.
pub const Target = union(enum) {
    static: command.CommandId,
    named: []u8,

    fn deinit(t: Target, gpa: Allocator) void {
        switch (t) {
            .named => |s| gpa.free(s),
            .static => {},
        }
    }
};

pub const SeqResolution = union(enum) {
    /// Exact match and no longer binding extends it: fire now.
    run: Target,
    /// Only a prefix of longer bindings: wait for the next key.
    pending,
    /// Bound on its own AND a prefix: wait `timeoutlen`, then fire this.
    pending_with_fallback: Target,
    /// No match, no prefix.
    none,
};

/// One line of `[keys.*]` config. `command` may be `""`, `"none"` or
/// `"unbound"` to remove a default.
pub const Binding = struct { spec: []const u8, command: []const u8 };

/// The keys section of the config, in the shape the loader will fill.
pub const KeysConfig = struct {
    global: []const Binding = &.{},
    vim: []const Binding = &.{},
    standard: []const Binding = &.{},
};

pub const Keymap = struct {
    gpa: Allocator,
    /// Key = the packed chord sequence as bytes (`[]u64` reinterpreted).
    map: std.StringHashMapUnmanaged(Target) = .empty,
    /// Every PROPER prefix of every bound sequence.
    prefixes: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator) Keymap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Keymap) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.map.deinit(self.gpa);
        self.clearPrefixes();
        self.prefixes.deinit(self.gpa);
    }

    /// Defaults for `profile` from the spec table (`both` + the profile's
    /// own list), then `[keys.global]`, then `[keys.<profile>]`.
    pub fn build(gpa: Allocator, profile: Profile, cfg: KeysConfig) Allocator.Error!Keymap {
        var km = Keymap.init(gpa);
        errdefer km.deinit();
        for (specs.specs, 0..) |s, i| {
            const id: command.CommandId = @enumFromInt(i);
            for (s.keys.both) |spec| try km.bindStatic(spec, id);
            const own = switch (profile) {
                .vim => s.keys.vim,
                .standard => s.keys.standard,
            };
            for (own) |spec| try km.bindStatic(spec, id);
        }
        const layers = [_][]const Binding{ cfg.global, switch (profile) {
            .vim => cfg.vim,
            .standard => cfg.standard,
        } };
        for (layers) |layer| {
            for (layer) |b| {
                const cmd = std.mem.trim(u8, b.command, " \t");
                if (cmd.len == 0 or std.mem.eql(u8, cmd, "none") or std.mem.eql(u8, cmd, "unbound")) {
                    km.unbind(b.spec);
                } else {
                    try km.bind(b.spec, cmd);
                }
            }
        }
        try km.rebuildPrefixes();
        return km;
    }

    fn bindStatic(self: *Keymap, spec: []const u8, id: command.CommandId) Allocator.Error!void {
        var buf: [max_seq]Chord = undefined;
        const seq = parseKeySeqBuf(spec, &buf) orelse return; // defaults are comptime-checked
        try self.put(seq, .{ .static = id });
    }

    /// Bind one spec to a command by name. Unknown names are kept as
    /// `.named` and resolved when pressed. A spec that does not parse is
    /// ignored. Prefixes are NOT rebuilt — call `rebuildPrefixes` after a
    /// batch, or use `bindNow` for a single runtime binding.
    pub fn bind(self: *Keymap, spec: []const u8, cmd: []const u8) Allocator.Error!void {
        var buf: [max_seq]Chord = undefined;
        const seq = parseKeySeqBuf(spec, &buf) orelse return;
        const target: Target = if (command.by_name.get(cmd)) |id| .{ .static = id } else .{ .named = try self.gpa.dupe(u8, cmd) };
        errdefer target.deinit(self.gpa);
        try self.put(seq, target);
    }

    /// `bind` + prefix rebuild — for plugin-registered commands.
    pub fn bindNow(self: *Keymap, spec: []const u8, cmd: []const u8) Allocator.Error!void {
        try self.bind(spec, cmd);
        try self.rebuildPrefixes();
    }

    pub fn unbind(self: *Keymap, spec: []const u8) void {
        var buf: [max_seq]Chord = undefined;
        const seq = parseKeySeqBuf(spec, &buf) orelse return;
        var pk: [max_seq]u64 = undefined;
        const k = packSeq(seq, &pk);
        if (self.map.fetchRemove(k)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
        }
    }

    fn put(self: *Keymap, seq: []const Chord, target: Target) Allocator.Error!void {
        var pk: [max_seq]u64 = undefined;
        const k = packSeq(seq, &pk);
        if (self.map.getPtr(k)) |slot| {
            slot.deinit(self.gpa);
            slot.* = target;
            return;
        }
        const owned = try self.gpa.dupe(u8, k);
        errdefer self.gpa.free(owned);
        try self.map.put(self.gpa, owned, target);
    }

    fn clearPrefixes(self: *Keymap) void {
        var it = self.prefixes.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.prefixes.clearRetainingCapacity();
    }

    pub fn rebuildPrefixes(self: *Keymap) Allocator.Error!void {
        self.clearPrefixes();
        var it = self.map.keyIterator();
        while (it.next()) |k| {
            const n = k.len / @sizeOf(u64);
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const p = k.*[0 .. i * @sizeOf(u64)];
                if (self.prefixes.contains(p)) continue;
                const owned = try self.gpa.dupe(u8, p);
                errdefer self.gpa.free(owned);
                try self.prefixes.put(self.gpa, owned, {});
            }
        }
    }

    /// Single-chord lookup: the target only when the chord is bound on
    /// its own. For chain-aware dispatch use `resolveSeq`.
    pub fn resolve(self: *const Keymap, k: Key) ?Target {
        const one = [_]Chord{Chord.of(k)};
        var pk: [1]u64 = undefined;
        return self.map.get(packSeq(&one, &pk));
    }

    pub fn resolveSeq(self: *const Keymap, seq: []const Chord) SeqResolution {
        if (seq.len == 0 or seq.len > max_seq) return .none;
        var pk: [max_seq]u64 = undefined;
        const k = packSeq(seq, &pk);
        const exact = self.map.get(k);
        const is_prefix = self.prefixes.contains(k);
        if (exact) |t| return if (is_prefix) .{ .pending_with_fallback = t } else .{ .run = t };
        return if (is_prefix) .pending else .none;
    }

    pub fn count(self: *const Keymap) usize {
        return self.map.count();
    }

    fn packSeq(seq: []const Chord, out: []u64) []const u8 {
        for (seq, 0..) |c, i| out[i] = c.pack();
        return std.mem.sliceAsBytes(out[0..seq.len]);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

test "every named key parses to its code" {
    for (named_keys) |n| {
        const k = parseKeySpec(n[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expect(k.code.eql(n[1]));
        try std.testing.expect(k.mods.eql(.{}));
    }
}

test "every modifier spelling, any case, any order" {
    const K = struct {
        fn ex(spec: []const u8, mods: Mods, code: KeyCode) !void {
            const k = parseKeySpec(spec) orelse return error.TestUnexpectedResult;
            try std.testing.expect(k.mods.eql(mods));
            try std.testing.expect(k.code.eql(code));
        }
    };
    try K.ex("ctrl+q", .{ .ctrl = true }, .{ .char = 'q' });
    try K.ex("C-q", .{ .ctrl = true }, .{ .char = 'q' });
    try K.ex("CTRL+Q", .{ .ctrl = true }, .{ .char = 'Q' });
    try K.ex("shift+p", .{ .shift = true }, .{ .char = 'p' });
    try K.ex("s-p", .{ .shift = true }, .{ .char = 'p' });
    try K.ex("alt+x", .{ .alt = true }, .{ .char = 'x' });
    try K.ex("a-x", .{ .alt = true }, .{ .char = 'x' });
    try K.ex("meta+x", .{ .alt = true }, .{ .char = 'x' });
    try K.ex("super+x", .{ .super = true }, .{ .char = 'x' });
    try K.ex("cmd+x", .{ .super = true }, .{ .char = 'x' });
    try K.ex("win+x", .{ .super = true }, .{ .char = 'x' });
    try K.ex("shift+ctrl+alt+enter", .{ .ctrl = true, .shift = true, .alt = true }, .enter);
    try K.ex("ctrl+leader", .{ .ctrl = true }, .{ .char = ' ' });
    try K.ex("ctrl+plus", .{ .ctrl = true }, .{ .char = '+' });
    try K.ex("  down  ", .{}, .down);
    try std.testing.expect(parseKeySpec("nope-not-a-key") == null);
    try std.testing.expect(parseKeySpec("") == null);
    try std.testing.expect(parseKeySpec("ab") == null);
}

test "punctuation names agree with the literal form" {
    const pairs = [_][2][]const u8{
        .{ "minus", "-" }, .{ "dash", "-" },        .{ "underscore", "_" },   .{ "equal", "=" },
        .{ "comma", "," }, .{ "period", "." },      .{ "slash", "/" },        .{ "semicolon", ";" },
        .{ "grave", "`" }, .{ "bracketleft", "[" }, .{ "bracketright", "]" }, .{ "backslash", "\\" },
    };
    for (pairs) |p| {
        const a = parseKeySpec(p[0]).?;
        const b = parseKeySpec(p[1]).?;
        try std.testing.expect(a.code.eql(b.code));
    }
}

test "a shifted Tab has one spelling: shift+tab, <S-Tab>, backtab and ctrl+shift+tab all fold onto backtab" {
    // `tui/loop.zig`'s `translateKey` hands the app `.backtab` with the
    // shift modifier cleared; a spec that kept `.tab` + shift could
    // never match it, which is what killed `buffer.prev` (hunt
    // 2026-09-21, kbd-ctrl-shift-tab-dead).
    const bt = parseKeySpec("backtab").?;
    for ([_][]const u8{ "shift+tab", "s-tab", "SHIFT+TAB", "shift+backtab" }) |spec| {
        const k = parseKeySpec(spec).?;
        try std.testing.expect(k.code.eql(bt.code));
        try std.testing.expect(!k.mods.shift);
    }
    const cst = parseKeySpec("ctrl+shift+tab").?;
    try std.testing.expect(cst.code.eql(.backtab));
    try std.testing.expect(cst.mods.ctrl and !cst.mods.shift);
    try std.testing.expect(Chord.of(cst).eql(Chord.of(parseKeySpec("ctrl+backtab").?)));
    // A plain Tab is untouched, with or without ctrl.
    try std.testing.expect(parseKeySpec("tab").?.code.eql(.tab));
    try std.testing.expect(parseKeySpec("ctrl+tab").?.code.eql(.tab));
}

test "buffer.prev answers the chord a terminal really sends for Ctrl+Shift+Tab and <S-Tab>" {
    const gpa = std.testing.allocator;
    var vim = try Keymap.build(gpa, .vim, .{});
    defer vim.deinit();
    var standard = try Keymap.build(gpa, .standard, .{});
    defer standard.deinit();
    var buf: [max_seq]Chord = undefined;
    // What `translateKey` produces for Ctrl+Shift+Tab: `.backtab` + ctrl.
    const terminal_cst = [_]Chord{Chord.of(.{ .code = .backtab, .mods = .{ .ctrl = true } })};
    try std.testing.expectEqual(command.CommandId.@"buffer.prev", vim.resolveSeq(&terminal_cst).run.static);
    try std.testing.expectEqual(command.CommandId.@"buffer.prev", standard.resolveSeq(&terminal_cst).run.static);
    // NvChad's `<S-Tab>` bufferline-prev: `.backtab`, no modifier.
    const terminal_st = [_]Chord{Chord.of(.{ .code = .backtab })};
    try std.testing.expectEqual(command.CommandId.@"buffer.prev", vim.resolveSeq(&terminal_st).run.static);
    try std.testing.expectEqual(command.CommandId.@"buffer.prev", vim.resolveSeq(parseKeySeqBuf("<S-Tab>", &buf).?).run.static);
    // Standard keeps `<S-Tab>` free — it is a vim-profile mapping.
    try std.testing.expect(standard.resolveSeq(&terminal_st) == .none);
}

test "P is shift+p; <C-p> is ctrl+p; <leader>ia is space i a" {
    var a: [max_seq]Chord = undefined;
    var b: [max_seq]Chord = undefined;
    try std.testing.expect(parseKeySeqBuf("P", &a).?[0].eql(parseKeySeqBuf("shift+p", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<C-p>", &a).?[0].eql(parseKeySeqBuf("ctrl+p", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<C-S-p>", &a).?[0].eql(parseKeySeqBuf("ctrl+shift+p", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<S-Tab>", &a).?[0].eql(parseKeySeqBuf("shift+tab", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<M-x>", &a).?[0].eql(parseKeySeqBuf("alt+x", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<D-s>", &a).?[0].eql(parseKeySeqBuf("super+s", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<CR>", &a).?[0].eql(parseKeySeqBuf("enter", &b).?[0]));
    try std.testing.expect(parseKeySeqBuf("<F5>", &a).?[0].eql(parseKeySeqBuf("f5", &b).?[0]));
    const l = parseKeySeqBuf("<leader>ia", &a).?;
    const s = parseKeySeqBuf("space i a", &b).?;
    try std.testing.expectEqual(@as(usize, 3), l.len);
    for (l, s) |x, y| try std.testing.expect(x.eql(y));
    try std.testing.expect(parseKeySeqBuf("<C-", &a) == null);
}

test "comptime parse matches runtime parse" {
    const ct = comptime parseKeySeqComptime("ctrl+k ctrl+i").?;
    var buf: [max_seq]Chord = undefined;
    const rt = parseKeySeqBuf("ctrl+k ctrl+i", &buf).?;
    try std.testing.expectEqual(ct.len, rt.len);
    for (ct, rt) |x, y| try std.testing.expect(x.eql(y));
}

test "profiles are isolated: a vim chord is unbound in standard and vice versa" {
    const gpa = std.testing.allocator;
    var vim = try Keymap.build(gpa, .vim, .{});
    defer vim.deinit();
    var standard = try Keymap.build(gpa, .standard, .{});
    defer standard.deinit();

    var buf: [max_seq]Chord = undefined;
    // `both`: ctrl+q → app.quit in both profiles.
    const quit = parseKeySeqBuf("ctrl+q", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"app.quit", vim.resolveSeq(quit).run.static);
    try std.testing.expectEqual(command.CommandId.@"app.quit", standard.resolveSeq(quit).run.static);
    // vim-only: ctrl+n toggles the tree in vim, is file.new in standard.
    const cn = parseKeySeqBuf("ctrl+n", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"view.toggle_tree", vim.resolveSeq(cn).run.static);
    try std.testing.expectEqual(command.CommandId.@"file.new", standard.resolveSeq(cn).run.static);
    // standard-only: ctrl+b toggles the sidebar in VS Code; in vim it is
    // the editor's page-back and the keymap must not see it.
    const cb = parseKeySeqBuf("ctrl+b", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"view.toggle_tree", standard.resolveSeq(cb).run.static);
    try std.testing.expect(vim.resolveSeq(cb) == .none);
    // standard-only: ctrl+o opens the file picker in VS Code; in vim it is
    // the jumplist (normal) and one-shot normal (insert).
    const co = parseKeySeqBuf("ctrl+o", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"picker.files", standard.resolveSeq(co).run.static);
    try std.testing.expect(vim.resolveSeq(co) == .none);
    // standard-only: the ctrl+k menus do not exist in vim.
    const ck = parseKeySeqBuf("ctrl+k z", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"view.fullscreen", standard.resolveSeq(ck).run.static);
    try std.testing.expect(vim.resolveSeq(ck) == .none);
    // ctrl+k alone: standard has it as leader AND prefix; vim as focus_up.
    const k1 = parseKeySeqBuf("ctrl+k", &buf).?;
    try std.testing.expectEqual(command.CommandId.@"whichkey.leader", standard.resolveSeq(k1).pending_with_fallback.static);
    try std.testing.expectEqual(command.CommandId.@"view.focus_up", vim.resolveSeq(k1).run.static);
}

test "space is the leader and a prefix; space f is pending" {
    const gpa = std.testing.allocator;
    var km = try Keymap.build(gpa, .vim, .{});
    defer km.deinit();
    var buf: [max_seq]Chord = undefined;
    try std.testing.expect(km.resolveSeq(parseKeySeqBuf("space", &buf).?) == .pending_with_fallback);
    try std.testing.expect(km.resolveSeq(parseKeySeqBuf("space f", &buf).?) == .pending);
    try std.testing.expectEqual(command.CommandId.@"picker.files", km.resolveSeq(parseKeySeqBuf("space f f", &buf).?).run.static);
    try std.testing.expect(km.resolveSeq(parseKeySeqBuf("space q q q", &buf).?) == .none);
}

test "the NvChad leader chords ra / ca / gt / cm / fo / fz resolve in the vim profile and nowhere else" {
    const gpa = std.testing.allocator;
    var vim = try Keymap.build(gpa, .vim, .{});
    defer vim.deinit();
    var standard = try Keymap.build(gpa, .standard, .{});
    defer standard.deinit();
    var buf: [max_seq]Chord = undefined;
    const Case = struct { spec: []const u8, id: command.CommandId };
    // NvChad mappings.lua: `<leader>ra` "LSP renamer", `<leader>ca`
    // "LSP code action", `<leader>gt` "telescope git status",
    // `<leader>cm` "telescope git commits", `<leader>fo` "telescope
    // find oldfiles", `<leader>fz` "telescope find in current buffer".
    for ([_]Case{
        .{ .spec = "space r a", .id = .@"lsp.rename" },
        .{ .spec = "space c a", .id = .@"lsp.code_action" },
        .{ .spec = "space g t", .id = .@"git.status_pane" },
        .{ .spec = "space c m", .id = .@"git.graph" },
        .{ .spec = "space f o", .id = .@"picker.recent" },
        .{ .spec = "space f z", .id = .@"find.find" },
    }) |c| {
        const seq = parseKeySeqBuf(c.spec, &buf).?;
        try std.testing.expectEqual(c.id, vim.resolveSeq(seq).run.static);
        try std.testing.expect(standard.resolveSeq(seq) == .none);
    }
}

test "config overlays: global applies to both, profile overlays its own, none unbinds" {
    const gpa = std.testing.allocator;
    const cfg: KeysConfig = .{
        .global = &.{ .{ .spec = "ctrl+q", .command = "none" }, .{ .spec = "<C-S-x>", .command = "view.about" } },
        .vim = &.{.{ .spec = "ctrl+p", .command = "plugin.not_yet_registered" }},
    };
    var vim = try Keymap.build(gpa, .vim, cfg);
    defer vim.deinit();
    var standard = try Keymap.build(gpa, .standard, cfg);
    defer standard.deinit();
    var buf: [max_seq]Chord = undefined;
    try std.testing.expect(vim.resolveSeq(parseKeySeqBuf("ctrl+q", &buf).?) == .none);
    try std.testing.expect(standard.resolveSeq(parseKeySeqBuf("ctrl+q", &buf).?) == .none);
    try std.testing.expectEqual(command.CommandId.@"view.about", vim.resolveSeq(parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try std.testing.expectEqual(command.CommandId.@"view.about", standard.resolveSeq(parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try std.testing.expectEqualStrings("plugin.not_yet_registered", vim.resolveSeq(parseKeySeqBuf("ctrl+p", &buf).?).run.named);
    try std.testing.expectEqual(command.CommandId.@"picker.files", standard.resolveSeq(parseKeySeqBuf("ctrl+p", &buf).?).run.static);
}
