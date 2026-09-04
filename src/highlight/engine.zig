//! The highlighter: one root grammar kept as an incrementally-edited
//! tree, its highlights query run over the text, and every injection
//! (a fenced code block, `<script>`, a Rust macro body) parsed with the
//! child grammar and painted on top. The output is a flat list of
//! non-overlapping `Span`s carrying a theme `Role`. Precedence follows
//! tree-sitter-highlight, which the grammars' own queries are written
//! for: an inner node beats the node enclosing it, the FIRST pattern to
//! capture a node keeps it (so `@constructor (#match? "^[A-Z]")` above
//! a bare `(identifier) @variable` wins), and an injected layer beats
//! its host inside the injected range.
//!
//! Language handles (parser + compiled queries + predicate tables) are
//! loaded lazily per grammar and live as long as the highlighter; a
//! markdown file with a Rust fence pays for the Rust query once.
//!
//! Editing contract: `edit` applies a byte/point delta to the kept tree
//! (`ts_tree_edit`); `invalidate` drops it when the caller lost track of
//! what changed. `refresh` then parses — incrementally when a tree is
//! kept — and rebuilds the spans.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree_sitter");
const table = @import("table.zig");
const predicate = @import("predicate.zig");
const role_mod = @import("role.zig");

pub const Role = role_mod.Role;

pub const Span = struct { start: u32, end: u32, role: Role };

/// Injection nesting cap: markdown → inline → html → css is three deep.
const max_depth = 4;

const Lang = struct {
    parser: *ts.Parser,
    highlights: *ts.Query,
    hl_preds: predicate.Table,
    /// Per capture index.
    roles: []Role,
    injections: ?*ts.Query = null,
    inj_preds: ?predicate.Table = null,
    inj_language: ?u32 = null,
    inj_content: ?u32 = null,

    fn load(gpa: Allocator, entry: usize) !*Lang {
        const e = table.entries[entry];
        const language = e.language();
        const parser = try ts.Parser.init();
        errdefer parser.deinit();
        try parser.setLanguage(language);
        const hl = try ts.Query.init(language, table.highlightSource(entry), null);
        errdefer hl.deinit();
        var hl_preds = try predicate.Table.build(gpa, hl);
        errdefer hl_preds.deinit();
        const roles = try gpa.alloc(Role, hl.captureCount());
        errdefer gpa.free(roles);
        for (roles, 0..) |*r, i| r.* = role_mod.roleFor(hl.captureName(@intCast(i)));
        const self = try gpa.create(Lang);
        errdefer gpa.destroy(self);
        self.* = .{ .parser = parser, .highlights = hl, .hl_preds = hl_preds, .roles = roles };
        if (e.injections.len > 0) {
            if (ts.Query.init(language, e.injections, null)) |inj| {
                self.injections = inj;
                self.inj_preds = try predicate.Table.build(gpa, inj);
                var i: u32 = 0;
                while (i < inj.captureCount()) : (i += 1) {
                    const name = inj.captureName(i);
                    if (std.mem.eql(u8, name, "injection.language")) self.inj_language = i;
                    if (std.mem.eql(u8, name, "injection.content")) self.inj_content = i;
                }
            } else |_| {}
        }
        return self;
    }

    fn unload(self: *Lang, gpa: Allocator) void {
        if (self.inj_preds) |*p| p.deinit();
        if (self.injections) |q| q.deinit();
        self.hl_preds.deinit();
        gpa.free(self.roles);
        self.highlights.deinit();
        self.parser.deinit();
        gpa.destroy(self);
    }
};

pub const Highlighter = struct {
    gpa: Allocator,
    langs: [table.entries.len]?*Lang = [_]?*Lang{null} ** table.entries.len,
    /// The root grammar (a `table.entries` index), or null for plain text.
    root: ?usize = null,
    tree: ?*ts.Tree = null,
    /// Per-byte role of the last text highlighted; reused across refreshes.
    paint: std.ArrayListUnmanaged(Role) = .empty,
    /// Per-byte length of the node that painted it — an inner (shorter)
    /// node overrides an outer one; the first pattern to capture a node
    /// keeps it, as under tree-sitter-highlight.
    owner: std.ArrayListUnmanaged(u32) = .empty,
    spans: std.ArrayListUnmanaged(Span) = .empty,
    cursor: ?*ts.QueryCursor = null,

    pub fn init(gpa: Allocator) Highlighter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |t| t.deinit();
        if (self.cursor) |c| c.deinit();
        for (&self.langs) |*slot| if (slot.*) |l| l.unload(self.gpa);
        self.paint.deinit(self.gpa);
        self.owner.deinit(self.gpa);
        self.spans.deinit(self.gpa);
    }

    /// Switch the root grammar. Anything but the same entry drops the tree
    /// and the spans.
    pub fn setLanguage(self: *Highlighter, entry: ?usize) void {
        if (entry == self.root) return;
        self.root = entry;
        self.invalidate();
        self.spans.clearRetainingCapacity();
    }

    pub fn hasLanguage(self: *const Highlighter) bool {
        return self.root != null;
    }

    /// Forget the kept tree: the next `refresh` parses from scratch.
    pub fn invalidate(self: *Highlighter) void {
        if (self.tree) |t| t.deinit();
        self.tree = null;
    }

    /// Tell the kept tree about one text edit (pre-edit coordinates).
    pub fn edit(self: *Highlighter, e: ts.InputEdit) void {
        const t = self.tree orelse return;
        t.edit(&e);
    }

    /// The root node of the last parse, for callers that walk the tree
    /// (text objects, the outline, sticky context).
    pub fn rootNode(self: *const Highlighter) ?ts.Node {
        const t = self.tree orelse return null;
        return t.rootNode();
    }

    fn lang(self: *Highlighter, entry: usize) ?*Lang {
        if (self.langs[entry]) |l| return l;
        const l = Lang.load(self.gpa, entry) catch return null;
        self.langs[entry] = l;
        return l;
    }

    /// Parse `text` (incrementally when a tree is kept and was told about
    /// every edit) and rebuild the spans.
    pub fn refresh(self: *Highlighter, text: []const u8) Allocator.Error!void {
        self.spans.clearRetainingCapacity();
        const entry = self.root orelse return;
        const l = self.lang(entry) orelse return;
        l.parser.setIncludedRanges(&.{}) catch {};
        const fresh = l.parser.parseString(self.tree, text) orelse {
            self.invalidate();
            return;
        };
        if (self.tree) |old| old.deinit();
        self.tree = fresh;

        try self.paint.resize(self.gpa, text.len);
        @memset(self.paint.items, .none);
        try self.owner.resize(self.gpa, text.len);
        @memset(self.owner.items, std.math.maxInt(u32));
        if (self.cursor == null) self.cursor = ts.QueryCursor.init() catch return;
        try self.layer(l, fresh.rootNode(), text, 0);
        try self.flatten();
    }

    /// Run one grammar's highlights over `root`, then its injections.
    fn layer(self: *Highlighter, l: *Lang, root: ts.Node, text: []const u8, depth: usize) Allocator.Error!void {
        const cursor = self.cursor.?;
        cursor.exec(l.highlights, root);
        // Captures in document order; for one node, in pattern order.
        var ci: u32 = 0;
        while (cursor.nextCapture(&ci)) |m| {
            const cap = m.captures[ci];
            const role = l.roles[cap.index];
            if (role == .none) continue;
            if (!l.hl_preds.pass(&m, text)) continue;
            const s = cap.node.startByte();
            const e = @min(cap.node.endByte(), text.len);
            if (e <= s) continue;
            const size: u32 = @intCast(e - s);
            for (s..e) |b| {
                if (size < self.owner.items[b]) {
                    self.paint.items[b] = role;
                    self.owner.items[b] = size;
                }
            }
        }
        if (depth + 1 >= max_depth) return;
        const inj = l.injections orelse return;
        const content_idx = l.inj_content orelse return;
        const preds = &l.inj_preds.?;
        // Collect first: parsing a child grammar re-enters the cursor.
        const Job = struct { entry: usize, node: ts.Node };
        var jobs: std.ArrayListUnmanaged(Job) = .empty;
        defer jobs.deinit(self.gpa);
        cursor.exec(inj, root);
        while (cursor.nextMatch()) |m| {
            if (!preds.pass(&m, text)) continue;
            const settings = preds.settings(m.pattern_index);
            const name: ?[]const u8 = settings.injection_language orelse
                (if (l.inj_language) |li| predicate.captureText(&m, li, text) else null);
            const key = table.keyForLanguageName(name orelse continue) orelse continue;
            const child_entry = table.find(key) orelse continue;
            for (m.slice()) |cap| {
                if (cap.index != content_idx) continue;
                if (cap.node.endByte() <= cap.node.startByte()) continue;
                try jobs.append(self.gpa, .{ .entry = child_entry, .node = cap.node });
            }
        }
        for (jobs.items) |job| {
            const child = self.lang(job.entry) orelse continue;
            if (child == l and depth > 0) continue; // a grammar injecting itself recurses forever
            const range: ts.Range = .{
                .start_byte = job.node.startByte(),
                .end_byte = job.node.endByte(),
                .start_point = job.node.startPoint(),
                .end_point = job.node.endPoint(),
            };
            child.parser.setIncludedRanges(&.{range}) catch continue;
            const tree = child.parser.parseString(null, text) orelse continue;
            defer tree.deinit();
            child.parser.setIncludedRanges(&.{}) catch {};
            // The child layer sits on top: its captures win over the host's
            // inside the injected range; what it leaves alone keeps the
            // host's paint.
            @memset(self.owner.items[range.start_byte..@min(range.end_byte, text.len)], std.math.maxInt(u32));
            try self.layer(child, tree.rootNode(), text, depth + 1);
        }
    }

    /// Run-length encode the paint into sorted, non-overlapping spans.
    fn flatten(self: *Highlighter) Allocator.Error!void {
        const p = self.paint.items;
        var i: usize = 0;
        while (i < p.len) {
            const r = p[i];
            var j = i + 1;
            while (j < p.len and p[j] == r) j += 1;
            if (r != .none) try self.spans.append(self.gpa, .{ .start = @intCast(i), .end = @intCast(j), .role = r });
            i = j;
        }
    }

    /// Spans overlapping `[lo, hi)` — a binary search for the first, then
    /// a slice.
    pub fn spansIn(self: *const Highlighter, lo: usize, hi: usize) []const Span {
        const items = self.spans.items;
        var a: usize = 0;
        var b: usize = items.len;
        while (a < b) {
            const mid = a + (b - a) / 2;
            if (items[mid].end <= lo) a = mid + 1 else b = mid;
        }
        var e = a;
        while (e < items.len and items[e].start < hi) e += 1;
        return items[a..e];
    }

    /// Shift the cached spans past an edit so a frame painted before the
    /// next parse still lines up with the text. Spans straddling the edit
    /// are clipped to its start.
    pub fn shiftSpans(self: *Highlighter, start: usize, old_end: usize, new_end: usize) void {
        const delta: i64 = @as(i64, @intCast(new_end)) - @as(i64, @intCast(old_end));
        var i: usize = 0;
        while (i < self.spans.items.len) {
            const s = &self.spans.items[i];
            if (s.end <= start) {
                i += 1;
                continue;
            }
            if (s.start >= old_end) {
                s.start = @intCast(@as(i64, s.start) + delta);
                s.end = @intCast(@as(i64, s.end) + delta);
                i += 1;
                continue;
            }
            // Overlaps the edited range: keep the part before it.
            if (s.start < start) {
                s.end = @intCast(start);
                i += 1;
            } else {
                _ = self.spans.orderedRemove(i);
            }
        }
    }
};

// ── tests ──

const testing = std.testing;

fn countRole(h: *const Highlighter, role: Role) usize {
    var n: usize = 0;
    for (h.spans.items) |s| if (s.role == role) {
        n += 1;
    };
    return n;
}

fn roleAt(h: *const Highlighter, off: usize) Role {
    for (h.spans.items) |s| if (off >= s.start and off < s.end) return s.role;
    return .none;
}

test "rust: keywords, functions, types, strings and numbers each get their role" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const text = "fn hello() -> u32 {\n    let x: u32 = 42;\n    x\n}\n";
    try h.refresh(text);
    try testing.expectEqual(Role.keyword, roleAt(&h, 0)); // fn
    try testing.expectEqual(Role.function, roleAt(&h, 3)); // hello
    try testing.expectEqual(Role.type, roleAt(&h, 14)); // u32
    try testing.expectEqual(Role.constant, roleAt(&h, std.mem.indexOf(u8, text, "42").?));
    try testing.expect(h.spans.items.len >= 5);
    // Non-overlapping and sorted.
    var prev: u32 = 0;
    for (h.spans.items) |s| {
        try testing.expect(s.start >= prev and s.end > s.start);
        prev = s.end;
    }
}

test "predicates hold: a capitalised identifier is a constructor, a plain one is not; the first pattern keeps a node" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const text = "let Zed = limit;\n";
    try h.refresh(text);
    // `((identifier) @constructor (#match? "^[A-Z]"))` precedes the plain
    // `(identifier) @variable` in the shipped query; the earlier pattern
    // keeps the node (tree-sitter-highlight's rule), the predicate gates it.
    try testing.expectEqual(Role.special, roleAt(&h, std.mem.indexOf(u8, text, "Zed").?));
    try testing.expect(roleAt(&h, std.mem.indexOf(u8, text, "limit").?) != .special);
}

test "injections: markdown fences carry the fenced grammar, inline emphasis and headings paint" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("md").?);
    const text = "# Title\n\nThis is **bold** and *em* text.\n\n```rust\nfn main() { let x = 1; }\n```\n";
    try h.refresh(text);
    try testing.expectEqual(Role.title, roleAt(&h, 2));
    try testing.expectEqual(Role.strong, roleAt(&h, std.mem.indexOf(u8, text, "bold").?));
    try testing.expectEqual(Role.emphasis, roleAt(&h, std.mem.indexOf(u8, text, "em*").?));
    // The rust fence: `fn` is a keyword only if the injection ran.
    try testing.expectEqual(Role.keyword, roleAt(&h, std.mem.indexOf(u8, text, "fn main").?));
    try testing.expect(h.spans.items.len >= 6);
}

test "injections: html routes <style> to css and <script> to javascript" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("html").?);
    const text = "<html><head><style>body { color: red; }</style><script>const x = 42;</script></head><body><div class=\"x\">hi</div></body></html>\n";
    try h.refresh(text);
    try testing.expectEqual(Role.keyword, roleAt(&h, std.mem.indexOf(u8, text, "const").?));
    try testing.expectEqual(Role.constant, roleAt(&h, std.mem.indexOf(u8, text, "42").?));
    try testing.expect(roleAt(&h, std.mem.indexOf(u8, text, "color").?) != .none);
    try testing.expect(h.spans.items.len >= 6);
}

test "incremental: an edit told to the tree reparses to the same spans as a fresh parse" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const before = "fn a() {}\nfn b() {}\n";
    try h.refresh(before);
    // Insert `fn c() {}\n` at the end of line 1 (byte 10).
    const after = "fn a() {}\nfn c() {}\nfn b() {}\n";
    h.edit(.{ .start_byte = 10, .old_end_byte = 10, .new_end_byte = 20, .start_point = .{ .row = 1, .column = 0 }, .old_end_point = .{ .row = 1, .column = 0 }, .new_end_point = .{ .row = 2, .column = 0 } });
    try h.refresh(after);
    var fresh = Highlighter.init(testing.allocator);
    defer fresh.deinit();
    fresh.setLanguage(table.find("rs").?);
    try fresh.refresh(after);
    try testing.expectEqualSlices(Span, fresh.spans.items, h.spans.items);
    try testing.expectEqual(Role.function, roleAt(&h, 13)); // c
}

test "shiftSpans keeps stale spans aligned across an insert and a delete" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    try h.spans.appendSlice(testing.allocator, &.{ .{ .start = 0, .end = 2, .role = .keyword }, .{ .start = 3, .end = 8, .role = .function }, .{ .start = 10, .end = 12, .role = .type } });
    h.shiftSpans(3, 3, 5); // insert 2 bytes at 3
    try testing.expectEqual(@as(u32, 5), h.spans.items[1].start);
    try testing.expectEqual(@as(u32, 12), h.spans.items[2].start);
    h.shiftSpans(6, 13, 6); // delete [6,13): clips the function span, drops the type span
    try testing.expectEqual(@as(usize, 2), h.spans.items.len);
    try testing.expectEqual(@as(u32, 6), h.spans.items[1].end);
}

test "spansIn slices by byte range" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    try h.spans.appendSlice(testing.allocator, &.{ .{ .start = 0, .end = 2, .role = .keyword }, .{ .start = 5, .end = 8, .role = .function }, .{ .start = 10, .end = 12, .role = .type } });
    try testing.expectEqual(@as(usize, 1), h.spansIn(6, 9).len);
    try testing.expectEqual(@as(usize, 2), h.spansIn(1, 6).len);
    try testing.expectEqual(@as(usize, 0), h.spansIn(12, 20).len);
    try testing.expectEqual(@as(usize, 3), h.spansIn(0, 100).len);
}

test "every grammar highlights its fixture through the engine" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    for (table.entries, 0..) |e, i| {
        h.setLanguage(i);
        try h.refresh(e.fixture);
        if (h.spans.items.len == 0) {
            std.debug.print("{s}: no spans on its fixture\n", .{e.key});
            return error.NoSpans;
        }
    }
}
