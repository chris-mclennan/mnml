//! One-shot: mnml's `themes/*.toml` (the NvChad base46 palettes) →
//! `themes/*.zon` plus `themes/root.zig`, the comptime table
//! `src/ui/theme.zig` imports. Run once, commit the output, forget it —
//! mnml-zig has no TOML reader and does not want one; this file reads
//! exactly the subset those 94 files use (`key = "value"` lines, two
//! `[section]` headers, `#` comments) and nothing else.
//!
//!     zig run tools/theme_toml2zon.zig -- ../mnml/themes themes
//!
//! Every palette value is kept as written (`#rrggbb` → `0xrrggbb`); a
//! key the schema does not name lands under `.extra` so nothing is
//! lost. The one known typo (`vibrant_gree` in catppuccin-latte) is
//! folded onto `vibrant_green` and reported.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const base_30_keys = [_][]const u8{
    "white",         "darker_black", "black",         "black2",  "one_bg",    "one_bg2",   "one_bg3",     "grey",
    "grey_fg",       "grey_fg2",     "light_grey",    "red",     "baby_pink", "pink",      "line",        "green",
    "vibrant_green", "nord_blue",    "blue",          "yellow",  "sun",       "purple",    "dark_purple", "teal",
    "orange",        "cyan",         "statusline_bg", "lightbg", "pmenu_bg",  "folder_bg",
};

const base_16_keys = [_][]const u8{
    "base00", "base01", "base02", "base03", "base04", "base05", "base06", "base07",
    "base08", "base09", "base0A", "base0B", "base0C", "base0D", "base0E", "base0F",
};

const Entry = struct { key: []const u8, hex: u24 };

const Parsed = struct {
    name: []const u8 = "",
    kind: []const u8 = "",
    base_30: std.ArrayList(Entry) = .empty,
    base_16: std.ArrayList(Entry) = .empty,
    extra: std.ArrayList(Entry) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: theme_toml2zon <toml dir> <zon dir>\n", .{});
        return error.Usage;
    }
    const src_dir = args[1];
    const dst_dir = args[2];
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dst_dir);

    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try cwd.openDir(io, src_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".toml")) continue;
            try names.append(arena, try arena.dupe(u8, e.name[0 .. e.name.len - ".toml".len]));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var converted: usize = 0;
    var partial: usize = 0;
    for (names.items) |stem| {
        const path = try std.fs.path.join(arena, &.{ src_dir, try std.fmt.allocPrint(arena, "{s}.toml", .{stem}) });
        const text = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
        var p = try parse(arena, stem, text);
        if (p.notes.items.len != 0) partial += 1;
        for (p.notes.items) |n| std.debug.print("{s}: {s}\n", .{ stem, n });
        const out = try render(arena, stem, &p);
        const out_path = try std.fs.path.join(arena, &.{ dst_dir, try std.fmt.allocPrint(arena, "{s}.zon", .{stem}) });
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = out });
        converted += 1;
    }
    const root = try renderRoot(arena, names.items);
    const root_path = try std.fs.path.join(arena, &.{ dst_dir, "root.zig" });
    try cwd.writeFile(io, .{ .sub_path = root_path, .data = root });
    std.debug.print("{d} themes converted ({d} with notes) → {s}\n", .{ converted, partial, dst_dir });
}

fn parse(arena: Allocator, stem: []const u8, text: []const u8) !Parsed {
    var p: Parsed = .{};
    var section: enum { top, base_30, base_16 } = .top;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[base_30]")) {
                section = .base_30;
            } else if (std.mem.eql(u8, line, "[base_16]")) {
                section = .base_16;
            } else {
                std.debug.print("{s}:{d}: unknown section {s}\n", .{ stem, line_no, line });
                return error.UnknownSection;
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("{s}:{d}: not a key = value line: {s}\n", .{ stem, line_no, line });
            return error.BadLine;
        };
        var key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        switch (section) {
            .top => {
                if (std.mem.eql(u8, key, "name")) {
                    p.name = value;
                } else if (std.mem.eql(u8, key, "type")) {
                    p.kind = value;
                } else {
                    std.debug.print("{s}:{d}: unknown top-level key {s}\n", .{ stem, line_no, key });
                    return error.UnknownKey;
                }
            },
            .base_30, .base_16 => {
                if (std.mem.eql(u8, key, "vibrant_gree")) {
                    try p.notes.append(arena, "`vibrant_gree` read as `vibrant_green` (upstream typo)");
                    key = "vibrant_green";
                }
                const hex = parseHex(value) orelse {
                    std.debug.print("{s}:{d}: not a #rrggbb colour: {s}\n", .{ stem, line_no, value });
                    return error.BadColour;
                };
                const entry: Entry = .{ .key = key, .hex = hex };
                if (section == .base_30) {
                    if (contains(&base_30_keys, key)) try p.base_30.append(arena, entry) else try p.extra.append(arena, entry);
                } else {
                    if (contains(&base_16_keys, key)) try p.base_16.append(arena, entry) else try p.extra.append(arena, entry);
                }
            },
        }
    }
    if (p.name.len == 0) return error.NoName;
    if (!std.mem.eql(u8, p.kind, "dark") and !std.mem.eql(u8, p.kind, "light")) return error.BadKind;
    for (base_30_keys) |k| if (!hasKey(p.base_30.items, k)) try p.notes.append(arena, try std.fmt.allocPrint(arena, "base_30 lacks {s}", .{k}));
    var missing16: usize = 0;
    for (base_16_keys) |k| if (!hasKey(p.base_16.items, k)) {
        missing16 += 1;
    };
    if (missing16 != 0) try p.notes.append(arena, try std.fmt.allocPrint(arena, "base_16 lacks {d} slot(s) — onedark fills them at load", .{missing16}));
    if (p.extra.items.len != 0) try p.notes.append(arena, try std.fmt.allocPrint(arena, "{d} extra key(s) kept under .extra", .{p.extra.items.len}));
    return p;
}

fn stripComment(line: []const u8) []const u8 {
    // A `#` outside quotes starts a comment; `"#abc123"` is a value.
    var in_quote = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quote = !in_quote;
        if (c == '#' and !in_quote) return line[0..i];
    }
    return line;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn parseHex(s: []const u8) ?u24 {
    if (s.len != 7 or s[0] != '#') return null;
    return std.fmt.parseInt(u24, s[1..], 16) catch null;
}

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn hasKey(entries: []const Entry, key: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return true;
    return false;
}

fn render(arena: Allocator, stem: []const u8, p: *Parsed) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("// {s} — converted from mnml's themes/{s}.toml by tools/theme_toml2zon.zig.\n", .{ p.name, stem });
    try w.writeAll("// The palette as NvChad ships it; src/ui/theme.zig derives every UI role from it.\n");
    for (p.notes.items) |n| try w.print("// note: {s}\n", .{n});
    try w.writeAll(".{\n");
    try w.print("    .name = \"{s}\",\n", .{p.name});
    try w.print("    .kind = .{s},\n", .{p.kind});
    try w.writeAll("    .base_30 = .{\n");
    for (base_30_keys) |k| {
        for (p.base_30.items) |e| if (std.mem.eql(u8, e.key, k)) try w.print("        .{s} = 0x{x:0>6},\n", .{ k, e.hex });
    }
    try w.writeAll("    },\n");
    try w.writeAll("    .base_16 = .{\n");
    for (base_16_keys) |k| {
        for (p.base_16.items) |e| if (std.mem.eql(u8, e.key, k)) try w.print("        .{s} = 0x{x:0>6},\n", .{ k, e.hex });
    }
    try w.writeAll("    },\n");
    if (p.extra.items.len != 0) {
        try w.writeAll("    .extra = .{\n");
        for (p.extra.items) |e| try w.print("        .{{ .name = \"{s}\", .hex = 0x{x:0>6} }},\n", .{ e.key, e.hex });
        try w.writeAll("    },\n");
    }
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

fn renderRoot(arena: Allocator, names: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\//! The bundled themes: every `themes/*.zon`, imported at comptime, so a
        \\//! malformed palette is a compile error, not a runtime surprise. The
        \\//! list is generated by `tools/theme_toml2zon.zig`; a new theme is a
        \\//! new `.zon` beside these plus one line in `all`.
        \\//!
        \\//! This module is the `themes` import of the main module. It defines
        \\//! the source shape itself because `src/` is not reachable from here
        \\//! and a palette has no business knowing what mnml paints with it.
        \\
        \\pub const Kind = enum { dark, light };
        \\
        \\/// NvChad's `base_30`: the UI chrome colours, `0xrrggbb`. Every key is
        \\/// optional because a few upstream palettes leave one out; the
        \\/// derivation in `src/ui/theme.zig` has a fallback chain per role.
        \\pub const Base30 = struct {
        \\
    );
    for (base_30_keys) |k| try w.print("    {s}: ?u24 = null,\n", .{k});
    try w.writeAll(
        \\};
        \\
        \\/// The syntax palette, `base00`..`base0F`. A missing slot falls back
        \\/// to onedark's at load.
        \\pub const Base16 = struct {
        \\
    );
    for (base_16_keys) |k| try w.print("    {s}: ?u24 = null,\n", .{k});
    try w.writeAll(
        \\};
        \\
        \\/// A key outside the schema, kept so the conversion loses nothing.
        \\pub const Extra = struct { name: []const u8, hex: u24 };
        \\
        \\pub const Source = struct {
        \\    name: []const u8,
        \\    kind: Kind,
        \\    base_30: Base30 = .{},
        \\    base_16: Base16 = .{},
        \\    extra: []const Extra = &.{},
        \\};
        \\
        \\pub const all = [_]Source{
        \\
    );
    for (names) |n| try w.print("    @import(\"{s}.zon\"),\n", .{n});
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}
