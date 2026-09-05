//! A `.gitignore` matcher for the in-process grep walk: one `Rules`
//! per directory that has a `.gitignore`, stacked as the walk
//! descends. Patterns follow gitignore's rules as far as a walker
//! needs them — blank lines and `#` comments, `!` negation, a leading
//! `/` anchoring to the file's directory, a trailing `/` matching
//! directories only, `*`, `?`, `[...]` and `**`; a pattern with no
//! slash (other than a trailing one) matches the basename at any
//! depth. The last matching pattern wins.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pattern = struct {
    /// The glob with any leading `/` and trailing `/` stripped. Owned.
    glob: []u8,
    negate: bool,
    /// A leading `/` (or an inner one): matched against the path
    /// relative to the `.gitignore`'s directory, not the basename.
    anchored: bool,
    dir_only: bool,
};

pub const Rules = struct {
    /// The directory this file lives in, relative to the walk root
    /// (`""` for the root itself). Owned.
    dir: []u8,
    patterns: std.ArrayListUnmanaged(Pattern) = .empty,

    pub fn parse(gpa: Allocator, dir: []const u8, text: []const u8) Allocator.Error!Rules {
        var r: Rules = .{ .dir = try gpa.dupe(u8, dir) };
        errdefer r.deinit(gpa);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, "\r");
            // Trailing spaces are ignored unless escaped.
            while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
            if (line.len == 0 or line[0] == '#') continue;
            var negate = false;
            if (line[0] == '!') {
                negate = true;
                line = line[1..];
            } else if (line.len > 1 and line[0] == '\\' and (line[1] == '#' or line[1] == '!')) {
                line = line[1..];
            }
            if (line.len == 0) continue;
            var dir_only = false;
            if (line[line.len - 1] == '/') {
                dir_only = true;
                line = line[0 .. line.len - 1];
            }
            if (line.len == 0) continue;
            var anchored = false;
            if (line[0] == '/') {
                anchored = true;
                line = line[1..];
            } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
                anchored = true;
            }
            if (line.len == 0) continue;
            try r.patterns.append(gpa, .{ .glob = try gpa.dupe(u8, line), .negate = negate, .anchored = anchored, .dir_only = dir_only });
        }
        return r;
    }

    pub fn deinit(self: *Rules, gpa: Allocator) void {
        for (self.patterns.items) |p| gpa.free(p.glob);
        self.patterns.deinit(gpa);
        gpa.free(self.dir);
    }

    /// Whether these rules say anything about `rel` (relative to the
    /// walk root): null = no pattern matched, true = ignored, false =
    /// un-ignored by a `!` pattern.
    pub fn verdict(self: *const Rules, rel: []const u8, is_dir: bool) ?bool {
        // The path relative to this file's directory.
        const local = if (self.dir.len == 0) rel else blk: {
            if (!std.mem.startsWith(u8, rel, self.dir) or rel.len <= self.dir.len or rel[self.dir.len] != '/') return null;
            break :blk rel[self.dir.len + 1 ..];
        };
        var out: ?bool = null;
        for (self.patterns.items) |p| {
            if (p.dir_only and !is_dir) continue;
            const hit = if (p.anchored) globMatch(p.glob, local) else globMatch(p.glob, std.fs.path.basename(local));
            if (hit) out = !p.negate;
        }
        return out;
    }
};

/// A stack of rule sets, innermost last. The walk pushes one per
/// `.gitignore` it meets and pops on the way out.
pub const Stack = struct {
    gpa: Allocator,
    layers: std.ArrayListUnmanaged(Rules) = .empty,

    pub fn init(gpa: Allocator) Stack {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Stack) void {
        for (self.layers.items) |*l| l.deinit(self.gpa);
        self.layers.deinit(self.gpa);
    }

    pub fn push(self: *Stack, rules: Rules) Allocator.Error!void {
        try self.layers.append(self.gpa, rules);
    }

    /// Drop every layer below `dir` (a directory the walk has left).
    pub fn popBelow(self: *Stack, dir: []const u8) void {
        while (self.layers.items.len > 0) {
            const top = self.layers.items[self.layers.items.len - 1];
            const inside = top.dir.len == 0 or std.mem.eql(u8, top.dir, dir) or (std.mem.startsWith(u8, dir, top.dir) and dir.len > top.dir.len and dir[top.dir.len] == '/');
            if (inside) break;
            var l = self.layers.pop().?;
            l.deinit(self.gpa);
        }
    }

    /// Ignored when the innermost rule set with an opinion says so.
    pub fn ignored(self: *const Stack, rel: []const u8, is_dir: bool) bool {
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.items[i].verdict(rel, is_dir)) |v| return v;
        }
        return false;
    }
};

/// gitignore glob: `*` stops at `/`, `**` crosses it, `?` is one char,
/// `[...]` a class. Whole-string match.
pub fn globMatch(glob: []const u8, s: []const u8) bool {
    return matchAt(glob, 0, s, 0);
}

fn matchAt(g: []const u8, gi_in: usize, s: []const u8, si_in: usize) bool {
    var gi = gi_in;
    var si = si_in;
    while (gi < g.len) {
        const c = g[gi];
        switch (c) {
            '*' => {
                if (gi + 1 < g.len and g[gi + 1] == '*') {
                    // `**`: any run of segments. `**/x` may also match `x`.
                    var rest = gi + 2;
                    if (rest < g.len and g[rest] == '/') rest += 1;
                    var k = si;
                    while (true) {
                        if (matchAt(g, rest, s, k)) return true;
                        if (k >= s.len) return false;
                        k += 1;
                    }
                }
                var k = si;
                while (true) {
                    if (matchAt(g, gi + 1, s, k)) return true;
                    if (k >= s.len or s[k] == '/') return false;
                    k += 1;
                }
            },
            '?' => {
                if (si >= s.len or s[si] == '/') return false;
                gi += 1;
                si += 1;
            },
            '[' => {
                if (si >= s.len) return false;
                const close = std.mem.indexOfScalarPos(u8, g, gi + 1, ']') orelse {
                    if (s[si] != '[') return false;
                    gi += 1;
                    si += 1;
                    continue;
                };
                var class = g[gi + 1 .. close];
                var negate = false;
                if (class.len > 0 and (class[0] == '!' or class[0] == '^')) {
                    negate = true;
                    class = class[1..];
                }
                var hit = false;
                var i: usize = 0;
                while (i < class.len) : (i += 1) {
                    if (i + 2 < class.len and class[i + 1] == '-') {
                        if (s[si] >= class[i] and s[si] <= class[i + 2]) hit = true;
                        i += 2;
                    } else if (class[i] == s[si]) hit = true;
                }
                if (hit == negate) return false;
                gi = close + 1;
                si += 1;
            },
            '\\' => {
                if (gi + 1 < g.len) gi += 1;
                if (si >= s.len or s[si] != g[gi]) return false;
                gi += 1;
                si += 1;
            },
            else => {
                if (si >= s.len or s[si] != c) return false;
                gi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "glob: star stops at slash, double-star crosses, classes and escapes" {
    try t.expect(globMatch("*.log", "a.log"));
    try t.expect(!globMatch("*.log", "dir/a.log"));
    try t.expect(globMatch("**/a.log", "x/y/a.log"));
    try t.expect(globMatch("**/a.log", "a.log"));
    try t.expect(globMatch("build/**", "build/x/y"));
    try t.expect(globMatch("a?c", "abc"));
    try t.expect(!globMatch("a?c", "a/c"));
    try t.expect(globMatch("[a-c]x", "bx"));
    try t.expect(!globMatch("[!a-c]x", "bx"));
    try t.expect(globMatch("\\#x", "#x"));
}

test "rules: negation, anchoring, dir-only, basename at any depth; the stack's innermost wins" {
    const gpa = t.allocator;
    // Owned by the stack once pushed; freed by `stack.deinit`.
    const root = try Rules.parse(gpa, "", "# build output\n*.o\n/dist\nnode_modules/\n!keep.o\ndocs/*.tmp\n");
    try t.expectEqual(@as(?bool, true), root.verdict("a.o", false));
    try t.expectEqual(@as(?bool, true), root.verdict("src/deep/b.o", false));
    try t.expectEqual(@as(?bool, false), root.verdict("src/keep.o", false));
    try t.expectEqual(@as(?bool, true), root.verdict("dist", true));
    try t.expectEqual(@as(?bool, null), root.verdict("src/dist", true));
    try t.expectEqual(@as(?bool, true), root.verdict("node_modules", true));
    try t.expectEqual(@as(?bool, null), root.verdict("node_modules", false));
    try t.expectEqual(@as(?bool, true), root.verdict("docs/x.tmp", false));
    try t.expectEqual(@as(?bool, null), root.verdict("docs/sub/x.tmp", false));
    try t.expectEqual(@as(?bool, null), root.verdict("main.zig", false));

    var stack = Stack.init(gpa);
    defer stack.deinit();
    try stack.push(root);
    try t.expect(stack.ignored("x/y.o", false));
    // A nested .gitignore un-ignores objects under `src`.
    try stack.push(try Rules.parse(gpa, "src", "!*.o\n*.gen\n"));
    try t.expect(!stack.ignored("src/a.o", false));
    try t.expect(stack.ignored("src/a.gen", false));
    try t.expect(stack.ignored("lib/a.o", false));
    // Leaving `src` drops its layer.
    stack.popBelow("lib");
    try t.expectEqual(@as(usize, 1), stack.layers.items.len);
    try t.expect(stack.ignored("src/a.o", false));
    stack.popBelow("src/inner");
    try t.expectEqual(@as(usize, 1), stack.layers.items.len);
}
