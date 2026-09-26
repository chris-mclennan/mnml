//! Ghostty's `font-codepoint-map`, far enough to answer "which font
//! renders this codepoint?" — the routing the tofu check needs
//! (`glyph_audit.zig`): a routed range gets no fallback in ghostty, so
//! a target font that lacks the codepoint shows `?` for certain.
//!
//! ```text
//! font-codepoint-map = U+EA60-U+EC1E=Symbols Nerd Font Mono
//! font-codepoint-map = U+F0001-U+F1AFF,U+F1B00-U+F20FF=MnmlSymbols
//! ```
//!
//! Later lines override earlier ones for the same codepoint: the LAST
//! matching rule wins. A line lists one range or a comma-separated
//! few, each `U+XXXX` or `U+XXXX-U+YYYY`, then `=` and the family.
//! Codepoints outside every rule fall to the terminal's own font stack,
//! which nothing outside ghostty can see. `config-file` includes are not
//! followed — the Rust reader did not either, and the codepoint map
//! sits in the main file on every setup seen.
//!
//! The file: `$XDG_CONFIG_HOME/ghostty/config`, `~/.config/ghostty/
//! config`, and on macOS `~/Library/Application Support/
//! com.mitchellh.ghostty/config` — the first that exists.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Rule = struct { start: u21, end: u21, font: []const u8 };

/// mnml's own block, and the face that carries it
/// (`src/glyph/builder.zig`). A terminal renders mnml's marks only if
/// this range is routed there; `required_line` is the line that does
/// it, quoted verbatim in the docs and in the icon's own toast.
pub const mnml_block_start: u21 = 0xF1B00;
pub const mnml_block_end: u21 = 0xF20FF;
pub const mnml_font = "MnmlSymbols";
pub const required_line = "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols";

pub const Map = struct {
    rules: []const Rule = &.{},
    /// The file the rules came from; null when none was found.
    path: ?[]const u8 = null,

    /// Is every codepoint mnml owns routed at `MnmlSymbols`? False
    /// when a rule sends part of the block elsewhere, or when nothing
    /// covers it — either way the marks are the terminal's fallback
    /// chain's to decide, which no app can see.
    pub fn coversMnmlBlock(m: Map) bool {
        var cp: u21 = mnml_block_start;
        while (cp <= mnml_block_end) : (cp += 1) {
            const font = m.routedFont(cp) orelse return false;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, font, " \t"), mnml_font)) return false;
        }
        return true;
    }

    /// The family ghostty forces `cp` to, per the last matching rule;
    /// null when no rule covers it.
    pub fn routedFont(m: Map, cp: u21) ?[]const u8 {
        var i = m.rules.len;
        while (i > 0) {
            i -= 1;
            const r = m.rules[i];
            if (cp >= r.start and cp <= r.end) return r.font;
        }
        return null;
    }
};

fn parseCp(s: []const u8) ?u21 {
    var hex = std.mem.trim(u8, s, " \t");
    if (std.mem.startsWith(u8, hex, "U+") or std.mem.startsWith(u8, hex, "u+")) hex = hex[2..];
    const v = std.fmt.parseInt(u32, hex, 16) catch return null;
    return if (v > 0x10FFFF) null else @intCast(v);
}

/// Every `font-codepoint-map` rule of `text`, in file order. Lines
/// mnml does not understand — other keys, comments, a malformed range,
/// a rule without a font — are skipped.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]Rule {
    var out: std.ArrayListUnmanaged(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const key = "font-codepoint-map";
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        // The ranges are left of the first `=`; a family name may hold
        // anything after it.
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const font = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        if (font.len == 0) continue;
        var ranges = std.mem.splitScalar(u8, rest[0..eq], ',');
        while (ranges.next()) |range| {
            const spec = std.mem.trim(u8, range, " \t");
            if (spec.len == 0) continue;
            var lo: ?u21 = null;
            var hi: ?u21 = null;
            if (std.mem.indexOfScalar(u8, spec, '-')) |dash| {
                lo = parseCp(spec[0..dash]);
                hi = parseCp(spec[dash + 1 ..]);
            } else {
                lo = parseCp(spec);
                hi = lo;
            }
            const a = lo orelse continue;
            const b = hi orelse continue;
            if (a > b) continue;
            try out.append(arena, .{ .start = a, .end = b, .font = font });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Where the config may be, in precedence order.
pub fn candidates(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ x, "ghostty", "config" }));
    if (env.get("HOME")) |h| if (h.len > 0) {
        try out.append(arena, try std.fs.path.join(arena, &.{ h, ".config", "ghostty", "config" }));
        if (builtin.os.tag == .macos) try out.append(arena, try std.fs.path.join(arena, &.{ h, "Library", "Application Support", "com.mitchellh.ghostty", "config" }));
    };
    return out.toOwnedSlice(arena);
}

/// The rules of the first config that exists; an empty map when none does.
pub fn load(arena: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!Map {
    for (try candidates(arena, env)) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch continue;
        return .{ .rules = try parse(arena, text), .path = path };
    }
    return .{};
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "font-codepoint-map lines: ranges, singles, a comma list; other keys and comments skipped; the last rule wins" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# the author's config
        \\font-family = JetBrainsMono Nerd Font
        \\font-codepoint-map = U+EA60-U+EC1E=Symbols Nerd Font Mono
        \\font-codepoint-map=U+F0001-U+F1AFF,u+F1B00-U+F20FF = MnmlSymbols
        \\font-codepoint-map = U+EB40=Another Face
        \\font-codepoint-map = U+EB4Z-U+EB50=Broken
        \\font-codepoint-map = U+E000-U+E00F
        \\theme = nord
    ;
    const rules = try parse(arena, text);
    try t.expectEqual(@as(usize, 4), rules.len);
    try t.expectEqual(@as(u21, 0xEA60), rules[0].start);
    try t.expectEqual(@as(u21, 0xEC1E), rules[0].end);
    try t.expectEqualStrings("Symbols Nerd Font Mono", rules[0].font);
    try t.expectEqual(@as(u21, 0xF0001), rules[1].start);
    try t.expectEqual(@as(u21, 0xF1B00), rules[2].start);
    try t.expectEqualStrings("MnmlSymbols", rules[2].font);
    try t.expectEqual(rules[3].start, rules[3].end);
    const map: Map = .{ .rules = rules };
    try t.expectEqualStrings("MnmlSymbols", map.routedFont(0xF1E00).?);
    try t.expectEqualStrings("Symbols Nerd Font Mono", map.routedFont(0xEB41).?);
    // U+EB40 is in the first rule too; the later single-codepoint rule wins.
    try t.expectEqualStrings("Another Face", map.routedFont(0xEB40).?);
    try t.expect(map.routedFont(0x41) == null);
    try t.expect(map.routedFont(0xE000) == null);
    try t.expectEqual(@as(usize, 0), (try parse(arena, "")).len);
    // The block mnml's own marks live in: routed whole, or not covered.
    try t.expect(map.coversMnmlBlock());
    const partial: Map = .{ .rules = try parse(arena, "font-codepoint-map = U+F1B00-U+F1FFF=MnmlSymbols\n") };
    try t.expect(!partial.coversMnmlBlock());
    const elsewhere: Map = .{ .rules = try parse(arena, "font-codepoint-map = U+F1B00-U+F20FF=Symbols Nerd Font Mono\n") };
    try t.expect(!elsewhere.coversMnmlBlock());
    try t.expect(!(Map{}).coversMnmlBlock());
}

test "the config is found under XDG_CONFIG_HOME, then ~/.config, then the macOS app-support folder" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const cands = try candidates(arena, &env);
    try t.expectEqual(if (builtin.os.tag == .macos) @as(usize, 2) else 1, cands.len);
    try t.expect(sdk_testing.pathEndsWith(cands[0], ".config/ghostty/config"));
    // Nothing on disk: an empty map, no path.
    const none = try load(arena, io, &env);
    try t.expect(none.path == null);
    try t.expectEqual(@as(usize, 0), none.rules.len);
    try tmp.dir.createDirPath(io, ".config/ghostty");
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/ghostty/config", .data = "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n" });
    const home_map = try load(arena, io, &env);
    try t.expectEqualStrings(cands[0], home_map.path.?);
    try t.expectEqualStrings("MnmlSymbols", home_map.routedFont(0xF1B0A).?);
    // XDG_CONFIG_HOME first.
    try tmp.dir.createDirPath(io, "xdg/ghostty");
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/ghostty/config", .data = "font-codepoint-map = U+EB40=Other\n" });
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(arena, &.{ root, "xdg" }));
    const xdg_map = try load(arena, io, &env);
    try t.expect(sdk_testing.pathEndsWith(xdg_map.path.?, "xdg/ghostty/config"));
    try t.expect(xdg_map.routedFont(0xF1B0A) == null);
    try t.expectEqualStrings("Other", xdg_map.routedFont(0xEB40).?);
}
