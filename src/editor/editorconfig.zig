//! `.editorconfig` — the per-file overrides a project ships beside its
//! sources. `resolveFor` walks up from the file's directory to the
//! workspace root (or a file that says `root = true`), parses each
//! `.editorconfig` on the way, and merges the sections whose glob
//! matches the file, nearer files winning. What is honoured:
//!
//! - `indent_style = space | tab` → what Tab inserts and `>>` pads with
//! - `indent_size = N | tab` → the indent unit; `tab_width = N` → how
//!   wide a `\t` is drawn (each falls back to the other, as the spec
//!   says)
//! - `end_of_line = lf | crlf | cr` → what a save writes
//! - `trim_trailing_whitespace` → strip line ends on save
//! - `insert_final_newline` → the terminating newline on save
//! - `root = true` in the preamble → stop walking up
//!
//! `charset` is read and ignored (the editor is UTF-8). Globs follow the
//! spec: `*` (no `/`), `**`, `?`, `[abc]` / `[!abc]`, `{a,b}` (nested),
//! `{n..m}`; a pattern without a `/` matches the file name, one with a
//! `/` matches the path relative to the `.editorconfig`'s directory.
//!
//! // changed: Rust mnml honoured `tab_width` / `indent_size`,
//! `insert_final_newline` and `trim_trailing_whitespace` only, with a
//! basename-or-anchored glob. `indent_style` and `end_of_line` are new,
//! and a pattern with a `/` in the middle (`src/**/*.zig`) matches the
//! way the spec says rather than never. The apply side lives in
//! `buffer.zig` (`applyEditorconfig`) and the walk is invoked from
//! `App.openEditor`; nothing here touches a buffer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const file_name = ".editorconfig";

pub const IndentStyle = enum { space, tab };
pub const Eol = enum { lf, crlf, cr };

/// What the matching sections say about one file. Null = unspecified.
pub const Resolved = struct {
    indent_style: ?IndentStyle = null,
    /// A number; `indent_size = tab` is recorded as `indent_size_is_tab`.
    indent_size: ?usize = null,
    indent_size_is_tab: bool = false,
    tab_width: ?usize = null,
    end_of_line: ?Eol = null,
    trim_trailing_whitespace: ?bool = null,
    insert_final_newline: ?bool = null,

    /// `over`'s settings replace `self`'s where set.
    pub fn merge(self: *Resolved, over: Resolved) void {
        if (over.indent_style) |v| self.indent_style = v;
        if (over.indent_size) |v| {
            self.indent_size = v;
            self.indent_size_is_tab = false;
        }
        if (over.indent_size_is_tab) {
            self.indent_size = null;
            self.indent_size_is_tab = true;
        }
        if (over.tab_width) |v| self.tab_width = v;
        if (over.end_of_line) |v| self.end_of_line = v;
        if (over.trim_trailing_whitespace) |v| self.trim_trailing_whitespace = v;
        if (over.insert_final_newline) |v| self.insert_final_newline = v;
    }

    pub fn isEmpty(self: Resolved) bool {
        return std.meta.eql(self, .{});
    }

    /// The indent unit: `indent_size`, else `tab_width` (the spec's
    /// fallback, and what `indent_size = tab` means).
    pub fn indentUnit(self: Resolved) ?usize {
        return self.indent_size orelse self.tab_width;
    }

    /// How wide a `\t` is: `tab_width`, else `indent_size`.
    pub fn tabDisplayWidth(self: Resolved) ?usize {
        return self.tab_width orelse self.indent_size;
    }
};

// ─── the walk ─────────────────────────────────────────────────────────────

/// The merged settings for `file_path` (absolute), reading every
/// `.editorconfig` from its directory up to and including `workspace`
/// (or the first one with `root = true`). Missing files are skipped; an
/// unreadable one counts as missing. `arena` holds the file texts.
pub fn resolveFor(io: Io, arena: Allocator, file_path: []const u8, workspace: []const u8) Allocator.Error!Resolved {
    var chain: std.ArrayListUnmanaged(struct { dir: []const u8, text: []const u8 }) = .empty;
    var dir: ?[]const u8 = std.fs.path.dirname(file_path);
    while (dir) |d| {
        const cfg_path = try std.fs.path.join(arena, &.{ d, file_name });
        if (Io.Dir.cwd().readFileAlloc(io, cfg_path, arena, .limited(1024 * 1024))) |text| {
            try chain.append(arena, .{ .dir = d, .text = text });
            if (rootFlag(text)) break;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        if (std.mem.eql(u8, d, workspace)) break;
        const parent = std.fs.path.dirname(d);
        if (parent == null or std.mem.eql(u8, parent.?, d)) break;
        dir = parent;
    }
    // Farthest first so the nearest file's sections win.
    var out: Resolved = .{};
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        const c = chain.items[i];
        out.merge(try parseForPath(arena, c.text, file_path, c.dir));
    }
    return out;
}

/// `root = true` in the preamble (before the first section).
pub fn rootFlag(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') return false;
        const kv = splitKv(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(kv.key, "root")) return std.ascii.eqlIgnoreCase(kv.value, "true");
    }
    return false;
}

const Kv = struct { key: []const u8, value: []const u8 };

/// `key = value` (or `key: value`), both trimmed, the key lower-cased in
/// place of comparison by the caller.
fn splitKv(line: []const u8) ?Kv {
    const at = std.mem.indexOfAny(u8, line, "=:") orelse return null;
    var value = std.mem.trim(u8, line[at + 1 ..], " \t");
    // A trailing comment.
    if (std.mem.indexOfAny(u8, value, "#;")) |c| value = std.mem.trimEnd(u8, value[0..c], " \t");
    return .{ .key = std.mem.trim(u8, line[0..at], " \t"), .value = value };
}

/// What one file's sections say about `file_path`. `config_dir` anchors
/// the globs. Later matching sections override earlier ones.
pub fn parseForPath(arena: Allocator, text: []const u8, file_path: []const u8, config_dir: []const u8) Allocator.Error!Resolved {
    var out: Resolved = .{};
    var in_section = false;
    var section_matches = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse continue;
            in_section = true;
            section_matches = try matches(arena, line[1..close], file_path, config_dir);
            continue;
        }
        if (!in_section or !section_matches) continue;
        const kv = splitKv(line) orelse continue;
        var key_buf: [64]u8 = undefined;
        if (kv.key.len > key_buf.len) continue;
        const key = std.ascii.lowerString(&key_buf, kv.key);
        var val_buf: [64]u8 = undefined;
        if (kv.value.len > val_buf.len) continue;
        const value = std.ascii.lowerString(&val_buf, kv.value);
        if (std.mem.eql(u8, key, "indent_style")) {
            if (std.mem.eql(u8, value, "tab")) out.indent_style = .tab else if (std.mem.eql(u8, value, "space")) out.indent_style = .space;
        } else if (std.mem.eql(u8, key, "indent_size")) {
            if (std.mem.eql(u8, value, "tab")) {
                out.indent_size = null;
                out.indent_size_is_tab = true;
            } else if (std.fmt.parseInt(usize, value, 10) catch null) |n| {
                if (n >= 1) {
                    out.indent_size = n;
                    out.indent_size_is_tab = false;
                }
            }
        } else if (std.mem.eql(u8, key, "tab_width")) {
            if (std.fmt.parseInt(usize, value, 10) catch null) |n| if (n >= 1) {
                out.tab_width = n;
            };
        } else if (std.mem.eql(u8, key, "end_of_line")) {
            if (std.mem.eql(u8, value, "lf")) out.end_of_line = .lf else if (std.mem.eql(u8, value, "crlf")) out.end_of_line = .crlf else if (std.mem.eql(u8, value, "cr")) out.end_of_line = .cr;
        } else if (std.mem.eql(u8, key, "trim_trailing_whitespace")) {
            if (boolOf(value)) |b| out.trim_trailing_whitespace = b;
        } else if (std.mem.eql(u8, key, "insert_final_newline")) {
            if (boolOf(value)) |b| out.insert_final_newline = b;
        }
    }
    return out;
}

fn boolOf(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

// ─── globs ────────────────────────────────────────────────────────────────

/// Does section `pattern` cover `file_path`? A pattern without a `/`
/// matches the file name; one with a `/` matches the path relative to
/// `config_dir` (a leading `/` is the same anchor, spelled out). Braces
/// are expanded first, then the alternatives are glob-matched.
pub fn matches(arena: Allocator, pattern: []const u8, file_path: []const u8, config_dir: []const u8) Allocator.Error!bool {
    const anchored = std.mem.indexOfScalar(u8, pattern, '/') != null;
    var target: []const u8 = undefined;
    var pat = pattern;
    if (anchored) {
        if (pat[0] == '/') pat = pat[1..];
        target = relativeTo(file_path, config_dir) orelse return false;
    } else {
        target = std.fs.path.basename(file_path);
    }
    if (pat.len == 0) return false;
    const alts = try expandBraces(arena, pat);
    for (alts) |alt| if (globMatch(alt, target)) return true;
    return false;
}

/// `path` under `dir`, without the separator; null when it is not.
fn relativeTo(path: []const u8, dir: []const u8) ?[]const u8 {
    if (dir.len == 0) return path;
    if (!std.mem.startsWith(u8, path, dir)) return null;
    if (path.len == dir.len) return "";
    if (dir[dir.len - 1] == '/') return path[dir.len..];
    if (path[dir.len] != '/') return null;
    return path[dir.len + 1 ..];
}

/// `{a,b}` → `a`, `b` (nested groups and several groups multiply out);
/// `{1..3}` → `1`, `2`, `3`. A lone `{` or an empty `{}` is literal.
pub fn expandBraces(arena: Allocator, pattern: []const u8) Allocator.Error![]const []const u8 {
    const open = std.mem.indexOfScalar(u8, pattern, '{') orelse return try single(arena, pattern);
    // The matching close, depth-aware.
    var depth: usize = 0;
    var close: ?usize = null;
    var i = open;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') depth += 1;
        if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const end = close orelse return try single(arena, pattern);
    const before = pattern[0..open];
    const inner = pattern[open + 1 .. end];
    const after = pattern[end + 1 ..];
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    if (rangeOf(inner)) |r| {
        var n = r[0];
        while (true) : (n += 1) {
            try parts.append(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
            if (n == r[1]) break;
        }
    } else {
        // Split on top-level commas only.
        var start: usize = 0;
        var d: usize = 0;
        var j: usize = 0;
        while (j <= inner.len) : (j += 1) {
            if (j == inner.len or (inner[j] == ',' and d == 0)) {
                try parts.append(arena, inner[start..j]);
                start = j + 1;
            } else if (inner[j] == '{') d += 1 else if (inner[j] == '}') d -|= 1;
        }
        // `{}` and `{single}` are literal in the spec.
        if (parts.items.len < 2) {
            const lit = try std.mem.concat(arena, u8, &.{ before, "{", inner, "}" });
            const rest = try expandBraces(arena, after);
            var out: std.ArrayListUnmanaged([]const u8) = .empty;
            for (rest) |r| try out.append(arena, try std.mem.concat(arena, u8, &.{ lit, r }));
            return out.items;
        }
    }
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (parts.items) |p| {
        const joined = try std.mem.concat(arena, u8, &.{ before, p, after });
        for (try expandBraces(arena, joined)) |alt| try out.append(arena, alt);
    }
    return out.items;
}

fn single(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = s;
    return out;
}

/// `n..m` with both ends integers (either order).
fn rangeOf(inner: []const u8) ?[2]i64 {
    const dots = std.mem.indexOf(u8, inner, "..") orelse return null;
    const a = std.fmt.parseInt(i64, inner[0..dots], 10) catch return null;
    const b = std.fmt.parseInt(i64, inner[dots + 2 ..], 10) catch return null;
    return .{ @min(a, b), @max(a, b) };
}

/// `*` (not across `/`), `**`, `?`, `[abc]`, `[!abc]`, `[a-z]`, `\x`.
pub fn globMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    switch (pat[0]) {
        '*' => {
            if (pat.len > 1 and pat[1] == '*') {
                // `**` swallows anything, separators included; `**/` may
                // also match nothing at all.
                const rest = pat[2..];
                if (rest.len > 0 and rest[0] == '/') {
                    if (globMatch(rest[1..], s)) return true;
                }
                var i: usize = 0;
                while (i <= s.len) : (i += 1) if (globMatch(rest, s[i..])) return true;
                return false;
            }
            var i: usize = 0;
            while (i <= s.len) : (i += 1) {
                if (globMatch(pat[1..], s[i..])) return true;
                if (i < s.len and s[i] == '/') return false;
            }
            return false;
        },
        '?' => {
            if (s.len == 0 or s[0] == '/') return false;
            return globMatch(pat[1..], s[1..]);
        },
        '[' => {
            const close = std.mem.indexOfScalarPos(u8, pat, 1, ']') orelse return s.len > 0 and s[0] == '[' and globMatch(pat[1..], s[1..]);
            if (s.len == 0) return false;
            var set = pat[1..close];
            var negate = false;
            if (set.len > 0 and (set[0] == '!' or set[0] == '^')) {
                negate = true;
                set = set[1..];
            }
            var hit = false;
            var i: usize = 0;
            while (i < set.len) : (i += 1) {
                if (i + 2 < set.len and set[i + 1] == '-') {
                    if (s[0] >= set[i] and s[0] <= set[i + 2]) hit = true;
                    i += 2;
                } else if (set[i] == s[0]) hit = true;
            }
            if (hit == negate) return false;
            return globMatch(pat[close + 1 ..], s[1..]);
        },
        '\\' => {
            if (pat.len < 2 or s.len == 0 or s[0] != pat[1]) return false;
            return globMatch(pat[2..], s[1..]);
        },
        else => {
            if (s.len == 0 or s[0] != pat[0]) return false;
            return globMatch(pat[1..], s[1..]);
        },
    }
}

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "editorconfig glob: * ? ** classes braces ranges escapes" {
    try testing.expect(globMatch("*.zig", "main.zig"));
    try testing.expect(!globMatch("*.zig", "src/main.zig"));
    try testing.expect(globMatch("**/*.zig", "src/a/main.zig"));
    try testing.expect(globMatch("**/*.zig", "main.zig"));
    try testing.expect(globMatch("src/**", "src/a/b.c"));
    try testing.expect(globMatch("?.md", "a.md"));
    try testing.expect(!globMatch("?.md", "ab.md"));
    try testing.expect(globMatch("[abc].md", "b.md"));
    try testing.expect(!globMatch("[!abc].md", "b.md"));
    try testing.expect(globMatch("[a-z]x", "qx"));
    try testing.expect(!globMatch("[a-z]x", "Qx"));
    try testing.expect(globMatch("a\\*b", "a*b"));
    try testing.expect(!globMatch("a\\*b", "axb"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(!globMatch("", "x"));
    try testing.expect(globMatch("", ""));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const alts = try expandBraces(arena, "*.{js,ts}");
    try testing.expectEqual(@as(usize, 2), alts.len);
    try testing.expectEqualStrings("*.js", alts[0]);
    try testing.expectEqualStrings("*.ts", alts[1]);
    const multi = try expandBraces(arena, "{a,b}-{c,d}");
    try testing.expectEqual(@as(usize, 4), multi.len);
    try testing.expectEqualStrings("a-c", multi[0]);
    try testing.expectEqualStrings("b-d", multi[3]);
    const nested = try expandBraces(arena, "{a,{b,c}}");
    try testing.expectEqual(@as(usize, 3), nested.len);
    try testing.expectEqualStrings("c", nested[2]);
    const range = try expandBraces(arena, "v{1..3}.txt");
    try testing.expectEqual(@as(usize, 3), range.len);
    try testing.expectEqualStrings("v2.txt", range[1]);
    // Literal braces.
    const lone = try expandBraces(arena, "a{b");
    try testing.expectEqual(@as(usize, 1), lone.len);
    try testing.expectEqualStrings("a{b", lone[0]);
    const one = try expandBraces(arena, "a{b}c");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("a{b}c", one[0]);
}

test "editorconfig matches: a bare pattern is the file name, a slash anchors to the config dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try matches(arena, "*.zig", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(try matches(arena, "*", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(try matches(arena, "src/**/*.zig", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(try matches(arena, "/src/*/main.zig", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(!try matches(arena, "/src/*.zig", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(!try matches(arena, "src/*.zig", "/ws/src/a/main.zig", "/ws"));
    try testing.expect(try matches(arena, "*.{zig,rs}", "/ws/lib.rs", "/ws"));
    // A file outside the config dir never matches an anchored pattern.
    try testing.expect(!try matches(arena, "src/*", "/elsewhere/src/x", "/ws"));
    try testing.expect(try matches(arena, "x", "/elsewhere/src/x", "/ws"));
}

test "editorconfig parse: sections, keys, comments, root, unknown values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# top
        \\root = true
        \\
        \\[*]
        \\indent_style = space
        \\indent_size = 4
        \\end_of_line = lf ; a comment
        \\charset = utf-8
        \\trim_trailing_whitespace = true
        \\insert_final_newline = TRUE
        \\
        \\[*.zig]
        \\indent_size = tab
        \\tab_width = 8
        \\INDENT_STYLE = Tab
        \\
        \\[Makefile]
        \\indent_style = bogus
        \\end_of_line = crlf
        \\insert_final_newline = maybe
        \\
    ;
    try testing.expect(rootFlag(text));
    try testing.expect(!rootFlag("[*]\nroot = true\n"));
    const md = try parseForPath(arena, text, "/ws/readme.md", "/ws");
    try testing.expectEqual(IndentStyle.space, md.indent_style.?);
    try testing.expectEqual(@as(usize, 4), md.indent_size.?);
    try testing.expectEqual(@as(?usize, null), md.tab_width);
    try testing.expectEqual(Eol.lf, md.end_of_line.?);
    try testing.expect(md.trim_trailing_whitespace.?);
    try testing.expect(md.insert_final_newline.?);
    try testing.expectEqual(@as(usize, 4), md.indentUnit().?);
    try testing.expectEqual(@as(usize, 4), md.tabDisplayWidth().?);
    const zig = try parseForPath(arena, text, "/ws/src/x.zig", "/ws");
    try testing.expectEqual(IndentStyle.tab, zig.indent_style.?);
    try testing.expect(zig.indent_size_is_tab);
    try testing.expectEqual(@as(?usize, null), zig.indent_size);
    try testing.expectEqual(@as(usize, 8), zig.tab_width.?);
    try testing.expectEqual(@as(usize, 8), zig.indentUnit().?);
    const mk = try parseForPath(arena, text, "/ws/Makefile", "/ws");
    // An unknown value leaves the earlier section's setting standing.
    try testing.expectEqual(IndentStyle.space, mk.indent_style.?);
    try testing.expectEqual(Eol.crlf, mk.end_of_line.?);
    try testing.expect(mk.insert_final_newline.?);
    // Nothing matches an empty preamble-only file.
    try testing.expect((try parseForPath(arena, "root = true\n", "/ws/a", "/ws")).isEmpty());
}

test "editorconfig resolveFor: nearer files win, root stops the walk, the workspace bounds it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Above the workspace: must not be read.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".editorconfig", .data = "[*]\nindent_size = 9\nend_of_line = cr\n" });
    try tmp.dir.createDirPath(testing.io, "ws/src/deep");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.editorconfig", .data = "[*]\nindent_style = space\nindent_size = 4\ntrim_trailing_whitespace = true\n[*.zig]\nindent_size = 2\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/src/.editorconfig", .data = "[*.zig]\nindent_style = tab\n" });
    const ws = try std.fs.path.join(arena, &.{ root, "ws" });
    const zig = try std.fs.path.join(arena, &.{ root, "ws", "src", "deep", "x.zig" });
    const r = try resolveFor(testing.io, arena, zig, ws);
    try testing.expectEqual(IndentStyle.tab, r.indent_style.?); // src/ over ws/
    try testing.expectEqual(@as(usize, 2), r.indent_size.?); // ws/ [*.zig] over ws/ [*]
    try testing.expect(r.trim_trailing_whitespace.?);
    try testing.expectEqual(@as(?Eol, null), r.end_of_line); // the file above the workspace was not read
    const txt = try std.fs.path.join(arena, &.{ root, "ws", "notes.txt" });
    const t = try resolveFor(testing.io, arena, txt, ws);
    try testing.expectEqual(IndentStyle.space, t.indent_style.?);
    try testing.expectEqual(@as(usize, 4), t.indent_size.?);
    // `root = true` in src/ hides ws/'s file.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/src/.editorconfig", .data = "root = true\n[*.zig]\nindent_style = tab\n" });
    const r2 = try resolveFor(testing.io, arena, zig, ws);
    try testing.expectEqual(IndentStyle.tab, r2.indent_style.?);
    try testing.expectEqual(@as(?usize, null), r2.indent_size);
    try testing.expectEqual(@as(?bool, null), r2.trim_trailing_whitespace);
    // No file anywhere: empty.
    const nowhere = try std.fs.path.join(arena, &.{ root, "ws", "src", "deep", "y.txt" });
    try tmp.dir.deleteFile(testing.io, "ws/src/.editorconfig");
    try tmp.dir.deleteFile(testing.io, "ws/.editorconfig");
    try testing.expect((try resolveFor(testing.io, arena, nowhere, ws)).isEmpty());
}
