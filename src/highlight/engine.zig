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
//! what changed. `parse` then parses — incrementally when a tree is
//! kept.
//!
//! Spans are built on demand, a window of the text at a time
//! (`spansIn`): the query cursor is restricted to the window's byte
//! range, so the work and the memory follow what is on screen, not the
//! size of the file. A window paints its bytes exactly as a query over
//! the whole tree would — a node's full length decides precedence
//! whether or not all of it is inside.

const std = @import("std");
const builtin = @import("builtin");
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
    /// Per pattern: a bare catch-all (`isCatchAll`), which never takes a
    /// node from a pattern that said more about it.
    catch_all: []bool,
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
        const source = table.highlightSource(entry);
        const catch_all = try gpa.alloc(bool, hl.patternCount());
        errdefer gpa.free(catch_all);
        for (catch_all, 0..) |*c, i| {
            const lo, const hi = hl.patternSourceRange(@intCast(i));
            c.* = hi <= source.len and lo < hi and isCatchAll(source[lo..hi]);
        }
        const self = try gpa.create(Lang);
        errdefer gpa.destroy(self);
        self.* = .{ .parser = parser, .highlights = hl, .hl_preds = hl_preds, .roles = roles, .catch_all = catch_all };
        const inj_source = table.injectionSource(entry);
        if (inj_source.len > 0) {
            if (ts.Query.init(language, inj_source, null)) |inj| {
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
        gpa.free(self.catch_all);
        self.highlights.deinit();
        self.parser.deinit();
        gpa.destroy(self);
    }
};

/// Span windows kept at once: one per viewport onto the document (two
/// splits on one file alternate between two) and a couple to spare.
const max_windows = 4;

/// A window is computed at least this much wider than the request on
/// each side, so scrolling a line at a time lands inside it.
const window_margin = 8 * 1024;

/// Scratch the painter keeps between windows; a larger one (a caller
/// that asked for a whole file) is released once its window is built.
const scratch_keep_bytes = 1 << 20;

/// An injected range at least this long keeps its tree until the next
/// parse — a `<script>` of several megabytes is parsed once, not once
/// per window. Shorter ones (a macro body, a markdown paragraph) cost
/// less to parse again than to look up.
const injected_keep_min = 16 * 1024;
const max_injected_trees = 16;

/// The spans of one byte range of the text, from one parse.
const Window = struct {
    lo: usize = 0,
    hi: usize = 0,
    spans: std.ArrayListUnmanaged(Span) = .empty,
    valid: bool = false,
    used: u64 = 0,

    /// Spans overlapping `[lo, hi)` — a binary search for the first,
    /// then a slice.
    fn slice(w: *const Window, lo: usize, hi: usize) []const Span {
        const items = w.spans.items;
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

    /// Slide the window past an edit so a frame painted before the
    /// next parse still lines up with the text. Spans straddling the
    /// edit are clipped to its start; the new text has none.
    fn shift(w: *Window, start: usize, old_end: usize, new_end: usize) void {
        // An edit that starts at the window's far edge grows it too: text
        // typed at the end of the file is the window's, not past it.
        if (!w.valid or start > w.hi) return;
        const delta: i64 = @as(i64, @intCast(new_end)) - @as(i64, @intCast(old_end));
        w.hi = if (w.hi >= old_end) @intCast(@as(i64, @intCast(w.hi)) + delta) else new_end;
        // Bytes before `start` stay put, so a window that begins at or
        // before the edit keeps its first byte — typing at the very top
        // of the file lands INSIDE the window, it does not push it down
        // (and out from under the viewport, a parse per keystroke).
        if (w.lo > start) {
            w.lo = if (w.lo >= old_end) @intCast(@as(i64, @intCast(w.lo)) + delta) else start;
        }
        var i: usize = 0;
        var out: usize = 0;
        const items = w.spans.items;
        while (i < items.len) : (i += 1) {
            var s = items[i];
            if (s.end <= start) {
                // before the edit: as it was
            } else if (s.start >= old_end) {
                s.start = @intCast(@as(i64, s.start) + delta);
                s.end = @intCast(@as(i64, s.end) + delta);
            } else if (s.start < start) {
                s.end = @intCast(start);
            } else continue;
            items[out] = s;
            out += 1;
        }
        w.spans.items.len = out;
    }
};

/// A child grammar's tree over one injected range, kept until the
/// host tree changes.
const InjectedTree = struct { entry: usize, start: u32, end: u32, tree: *ts.Tree, used: u64 };

pub const Highlighter = struct {
    gpa: Allocator,
    langs: [table.entries.len]?*Lang = [_]?*Lang{null} ** table.entries.len,
    /// The root grammar (a `table.entries` index), or null for plain text.
    root: ?usize = null,
    tree: ?*ts.Tree = null,
    /// The kept tree was told about an edit and not parsed since: its
    /// nodes sit where the text now is, but the edited stretch is the
    /// old structure.
    stale: bool = false,
    /// Counts the trees this highlighter has rendered from — a window
    /// belongs to one of them.
    generation: u64 = 0,
    windows: [max_windows]Window = [_]Window{.{}} ** max_windows,
    injected: std.ArrayListUnmanaged(InjectedTree) = .empty,
    clock: u64 = 0,
    /// Per-byte role of the window being built; reused across windows.
    paint: std.ArrayListUnmanaged(Role) = .empty,
    /// Per byte, who painted it: `ownerKey` of the capture — an inner
    /// (shorter) node overrides an outer one; for one node a later
    /// pattern overrides an earlier one, as under tree-sitter-highlight
    /// and Neovim, except that a bare catch-all never takes a node from a
    /// pattern that said more about it (see `isCatchAll`).
    owner: std.ArrayListUnmanaged(u32) = .empty,
    cursor: ?*ts.QueryCursor = null,
    /// A highlights query behind the last window built ran into the
    /// cursor's match cap and let go of matches (`ts.QueryCursor.
    /// max_match_limit`), so what it painted is not certain to be what
    /// more room would have painted. A narrow window is no protection: the
    /// byte range limits which matches come back, not how much of a node
    /// that straddles the window is walked, and one enclosing node with
    /// thousands of children fills the pool on its own.
    dropped_matches: bool = false,
    /// How many windows ever ran into the cap.
    drops: u64 = 0,
    /// What this highlighter has been made to do, for the tests that hold
    /// a motion to "no parse, and no query wider than a viewport": parses
    /// run by `parse`, windows built, and the widest of them in bytes.
    parses: u64 = 0,
    windows_built: u64 = 0,
    widest_window: usize = 0,

    pub fn init(gpa: Allocator) Highlighter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Highlighter) void {
        self.dropInjected();
        self.injected.deinit(self.gpa);
        if (self.tree) |t| t.deinit();
        if (self.cursor) |c| c.deinit();
        for (&self.langs) |*slot| if (slot.*) |l| l.unload(self.gpa);
        self.paint.deinit(self.gpa);
        self.owner.deinit(self.gpa);
        for (&self.windows) |*w| w.spans.deinit(self.gpa);
    }

    /// Switch the root grammar. Anything but the same entry drops the tree
    /// and the spans.
    pub fn setLanguage(self: *Highlighter, entry: ?usize) void {
        if (entry == self.root) return;
        self.root = entry;
        self.invalidate();
    }

    pub fn hasLanguage(self: *const Highlighter) bool {
        return self.root != null;
    }

    /// Forget the kept tree and what was rendered from it: the next
    /// `parse` starts from scratch.
    pub fn invalidate(self: *Highlighter) void {
        if (self.tree) |t| t.deinit();
        self.tree = null;
        self.stale = false;
        self.newGeneration();
    }

    /// Every window and injected tree belongs to the tree that was
    /// current when it was built.
    fn newGeneration(self: *Highlighter) void {
        self.generation += 1;
        for (&self.windows) |*w| w.valid = false;
        self.dropInjected();
    }

    fn dropInjected(self: *Highlighter) void {
        for (self.injected.items) |it| it.tree.deinit();
        self.injected.clearRetainingCapacity();
    }

    /// Tell the kept tree about one text edit (pre-edit coordinates) and
    /// slide the windows along, so what is painted before the next parse
    /// still lines up with the text.
    pub fn edit(self: *Highlighter, e: ts.InputEdit) void {
        for (&self.windows) |*w| w.shift(e.start_byte, e.old_end_byte, e.new_end_byte);
        const t = self.tree orelse return;
        t.edit(&e);
        self.stale = true;
        // An injected tree sits at pre-edit offsets.
        self.dropInjected();
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

    /// Parse `text` — incrementally when a tree is kept and was told
    /// about every edit. Spans are built on demand, a window at a time
    /// (`spansIn`); nothing here walks the tree.
    pub fn parse(self: *Highlighter, text: []const u8) void {
        const entry = self.root orelse return;
        const l = self.lang(entry) orelse return;
        self.parses += 1;
        l.parser.setIncludedRanges(&.{}) catch {};
        const fresh = l.parser.parseString(self.tree, text) orelse {
            self.invalidate();
            return;
        };
        self.adopt(fresh);
    }

    /// Take `fresh` as the kept tree (the parse may have run elsewhere).
    /// The caller tells it about any edit made since the text it was
    /// parsed from (`edit`).
    pub fn adopt(self: *Highlighter, fresh: *ts.Tree) void {
        if (self.swap(fresh)) |old| old.deinit();
    }

    /// `adopt`, handing the tree it replaces to the caller instead of
    /// freeing it: letting go of a large tree's unshared nodes is work (tens
    /// of milliseconds at 100 MB) that need not happen on the thread that
    /// paints.
    pub fn swap(self: *Highlighter, fresh: *ts.Tree) ?*ts.Tree {
        const old = self.tree;
        self.tree = fresh;
        self.stale = false;
        self.newGeneration();
        return old;
    }

    /// Spans held right now, across every kept window — what the
    /// highlighter's memory follows. Reads, never builds.
    pub fn keptSpanCount(self: *const Highlighter) usize {
        var n: usize = 0;
        for (&self.windows) |*w| {
            if (w.valid) n += w.spans.items.len;
        }
        return n;
    }

    /// Whether a window built from the kept tree covers `[lo, hi)`.
    pub fn covers(self: *const Highlighter, lo: usize, hi: usize) bool {
        for (&self.windows) |*w| if (w.valid and w.lo <= lo and hi <= w.hi) return true;
        return false;
    }

    /// The spans overlapping `[lo, hi)` of `text`, sorted and
    /// non-overlapping. Served from a kept window when one covers the
    /// range; otherwise the highlights query (and every injection) runs
    /// over that range of the tree alone — the cost follows the range,
    /// not the file. The slice is good until the next call.
    pub fn spansIn(self: *Highlighter, text: []const u8, lo_in: usize, hi_in: usize) Allocator.Error![]const Span {
        const hi = @min(hi_in, text.len);
        const lo = @min(lo_in, hi);
        self.clock += 1;
        for (&self.windows) |*w| if (w.valid and w.lo <= lo and hi <= w.hi) {
            w.used = self.clock;
            return w.slice(lo, hi);
        };
        const entry = self.root orelse return &.{};
        const tree = self.tree orelse return &.{};
        const l = self.lang(entry) orelse return &.{};
        var slot: *Window = &self.windows[0];
        for (&self.windows) |*w| {
            if (!w.valid) {
                slot = w;
                break;
            }
            if (w.used < slot.used) slot = w;
        }
        const margin = @max(window_margin, hi - lo);
        const wlo = lo -| margin;
        const whi = @min(text.len, hi +| margin);
        slot.valid = false;
        slot.spans.clearRetainingCapacity();
        try self.build(slot, l, tree, text, wlo, whi);
        slot.lo = wlo;
        slot.hi = whi;
        slot.valid = true;
        slot.used = self.clock;
        return slot.slice(lo, hi);
    }

    /// Parse, then every span of `text` — the small documents (a picker
    /// preview, a response body) and the tests.
    pub fn highlightAll(self: *Highlighter, text: []const u8) Allocator.Error![]const Span {
        self.parse(text);
        return self.spansIn(text, 0, text.len);
    }

    fn build(self: *Highlighter, w: *Window, l: *Lang, tree: *ts.Tree, text: []const u8, lo: usize, hi: usize) Allocator.Error!void {
        const n = hi - lo;
        self.windows_built += 1;
        self.widest_window = @max(self.widest_window, n);
        self.dropped_matches = false;
        try self.paint.resize(self.gpa, n);
        @memset(self.paint.items, .none);
        try self.owner.resize(self.gpa, n);
        @memset(self.owner.items, std.math.maxInt(u32));
        if (self.cursor == null) self.cursor = ts.QueryCursor.init() catch return error.OutOfMemory;
        try self.layer(l, tree.rootNode(), text, 0, lo, lo, hi);
        try flatten(self.gpa, self.paint.items, lo, &w.spans);
        if (n > scratch_keep_bytes) {
            self.paint.clearAndFree(self.gpa);
            self.owner.clearAndFree(self.gpa);
        }
    }

    /// Run one grammar's highlights over the part of `root` inside
    /// `[lo, hi)`, then its injections there. `base` is the window's first
    /// byte — what `paint` and `owner` are indexed from. It stays put as
    /// layers nest, while `[lo, hi)` narrows to the injected range.
    fn layer(self: *Highlighter, l: *Lang, root: ts.Node, text: []const u8, depth: usize, base: usize, lo: usize, hi: usize) Allocator.Error!void {
        const cursor = self.cursor.?;
        _ = cursor.setByteRange(@intCast(lo), @intCast(hi));
        cursor.exec(l.highlights, root);
        // Captures in document order; for one node, in pattern order.
        var ci: u32 = 0;
        while (cursor.nextCapture(&ci)) |m| {
            const cap = m.captures[ci];
            const role = l.roles[cap.index];
            if (role == .none) continue;
            const s = cap.node.startByte();
            const e = @min(cap.node.endByte(), text.len);
            if (e <= s) continue;
            const from = @max(s, lo);
            const to = @min(e, hi);
            if (to <= from) continue;
            if (!l.hl_preds.pass(&m, text)) continue;
            // The node's whole length decides who wins, in or out of
            // the window; for one node, the later capture — captures of
            // a node come in pattern order.
            const key = ownerKey(e - s, l.catch_all[m.pattern_index]);
            for (from - base..to - base) |b| {
                if (key <= self.owner.items[b]) {
                    self.paint.items[b] = role;
                    self.owner.items[b] = key;
                }
            }
        }
        if (cursor.didExceedMatchLimit()) {
            self.dropped_matches = true;
            self.drops += 1;
            // Never silent: a debug build says which grammar, and where.
            if (builtin.mode == .Debug) std.log.warn("highlight: {s} ran into the query cursor's match cap over bytes [{d}, {d}); some matches were dropped", .{ table.entries[self.root.?].key, lo, hi });
        }
        if (depth + 1 >= max_depth) return;
        const inj = l.injections orelse return;
        const content_idx = l.inj_content orelse return;
        const preds = &l.inj_preds.?;
        // Collect first: parsing a child grammar re-enters the cursor.
        const Job = struct { entry: usize, node: ts.Node };
        var jobs: std.ArrayListUnmanaged(Job) = .empty;
        defer jobs.deinit(self.gpa);
        _ = cursor.setByteRange(@intCast(lo), @intCast(hi));
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
                if (cap.node.endByte() <= lo or cap.node.startByte() >= hi) continue;
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
            const held = self.injectedTree(child, job.entry, range, text) orelse continue;
            defer if (!held.kept) held.tree.deinit();
            // The child layer sits on top: its captures win over the host's
            // inside the injected range; what it leaves alone keeps the
            // host's paint.
            const from = @max(range.start_byte, lo);
            const to = @min(@min(range.end_byte, text.len), hi);
            if (to <= from) continue;
            @memset(self.owner.items[from - base .. to - base], std.math.maxInt(u32));
            try self.layer(child, held.tree.rootNode(), text, depth + 1, base, from, to);
        }
    }

    const Held = struct { tree: *ts.Tree, kept: bool };

    /// The child grammar's tree over `range`: a kept one, or a fresh
    /// parse — kept in turn when the range is long enough to be worth it
    /// and a slot no window under construction is using is free.
    fn injectedTree(self: *Highlighter, child: *Lang, entry: usize, range: ts.Range, text: []const u8) ?Held {
        const long = range.end_byte - range.start_byte >= injected_keep_min;
        if (long) for (self.injected.items) |*it| {
            if (it.entry == entry and it.start == range.start_byte and it.end == range.end_byte) {
                it.used = self.clock;
                return .{ .tree = it.tree, .kept = true };
            }
        };
        child.parser.setIncludedRanges(&.{range}) catch return null;
        const tree = child.parser.parseString(null, text);
        child.parser.setIncludedRanges(&.{}) catch {};
        const t = tree orelse return null;
        if (!long) return .{ .tree = t, .kept = false };
        const rec: InjectedTree = .{ .entry = entry, .start = range.start_byte, .end = range.end_byte, .tree = t, .used = self.clock };
        if (self.injected.items.len < max_injected_trees) {
            self.injected.append(self.gpa, rec) catch return .{ .tree = t, .kept = false };
            return .{ .tree = t, .kept = true };
        }
        // Replace the least recently used — never one this window is
        // walking (its `used` is the current clock).
        var victim: ?*InjectedTree = null;
        for (self.injected.items) |*it| {
            if (it.used == self.clock) continue;
            if (victim == null or it.used < victim.?.used) victim = it;
        }
        const v = victim orelse return .{ .tree = t, .kept = false };
        v.tree.deinit();
        v.* = rec;
        return .{ .tree = t, .kept = true };
    }

    /// Run-length encode `paint` (the bytes from `base` on) into sorted,
    /// non-overlapping spans.
    fn flatten(gpa: Allocator, p: []const Role, base: usize, out: *std.ArrayListUnmanaged(Span)) Allocator.Error!void {
        var i: usize = 0;
        while (i < p.len) {
            const r = p[i];
            var j = i + 1;
            while (j < p.len and p[j] == r) j += 1;
            if (r != .none) try out.append(gpa, .{ .start = @intCast(base + i), .end = @intCast(base + j), .role = r });
            i = j;
        }
    }
};

// ── layering (lsp-more) ──
// changed: semantic tokens from a language server paint OVER the
// tree-sitter spans, never instead of them. `layerSpans` is the one
// merge: `over` wins where the two overlap and `base` keeps every byte
// `over` leaves alone, so a server that only names identifiers still
// leaves keywords and strings to the grammar.

/// Lay `over` on top of `base`. Both are sorted by `start` and
/// non-overlapping; `T` needs `start` / `end` fields. The result is
/// sorted and non-overlapping, on `arena`.
pub fn layerSpans(comptime T: type, arena: Allocator, base: []const T, over: []const T) Allocator.Error![]T {
    if (over.len == 0) return arena.dupe(T, base);
    var out: std.ArrayListUnmanaged(T) = .empty;
    var oi: usize = 0;
    for (base) |b| {
        while (oi < over.len and over[oi].end <= b.start) oi += 1;
        var cur = b.start;
        var j = oi;
        while (j < over.len and over[j].start < b.end) : (j += 1) {
            const o = over[j];
            if (o.start > cur) {
                var piece = b;
                piece.start = cur;
                piece.end = o.start;
                try out.append(arena, piece);
            }
            cur = @max(cur, o.end);
        }
        if (cur < b.end) {
            var piece = b;
            piece.start = cur;
            try out.append(arena, piece);
        }
    }
    try out.appendSlice(arena, over);
    std.mem.sort(T, out.items, {}, struct {
        fn lt(_: void, a: T, c: T) bool {
            return a.start < c.start;
        }
    }.lt);
    return out.items;
}

// ── tests ──

const testing = std.testing;

/// A capture's claim on a byte: twice its node's length, plus one for a
/// bare catch-all. A claim at or below the byte's current one repaints
/// it, so a shorter node always wins, a later pattern on the same node
/// wins, and a catch-all loses a node a more specific pattern has.
fn ownerKey(len: usize, catch_all: bool) u32 {
    const capped: u32 = @intCast(@min(len, std.math.maxInt(u32) / 2 - 1));
    return capped * 2 + @intFromBool(catch_all);
}

/// A pattern that names one node kind and nothing else — `(identifier)
/// @variable`, `(_) @x`, `[(a) (b)] @y` — no parent, field, child,
/// anchor, quantifier or predicate. Queries put these at either end:
/// Neovim-style ones (c_sharp, python, c, java, javascript, ruby, zig)
/// open with the catch-all and let every later, specific pattern
/// override it; older ones (go, json) close with it after the specific
/// ones, meaning "whatever is left". A catch-all that loses a node to a
/// more specific pattern whichever side it sits on reads both as meant.
pub fn isCatchAll(pattern: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    var saw_node = false;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        switch (c) {
            ';' => while (i < pattern.len and pattern[i] != '\n') : (i += 1) {},
            '@' => while (i + 1 < pattern.len and isNameByte(pattern[i + 1])) : (i += 1) {},
            '(' => {
                depth += 1;
                if (depth > 1) return false;
                saw_node = true;
            },
            ')' => depth -|= 1,
            '[', ']', ' ', '\t', '\n', '\r' => {},
            ':', '#', '"', '.', '*', '+', '?', '!' => return false,
            else => if (!isNameByte(c)) return false,
        }
    }
    return saw_node;
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

fn roleAt(spans: []const Span, off: usize) Role {
    for (spans) |s| if (off >= s.start and off < s.end) return s.role;
    return .none;
}

/// The role painted on each byte of `[lo, hi)`.
fn paintOf(gpa: Allocator, spans: []const Span, lo: usize, hi: usize) ![]Role {
    const out = try gpa.alloc(Role, hi - lo);
    @memset(out, .none);
    for (spans) |s| {
        const from = @max(@as(usize, s.start), lo);
        const to = @min(@as(usize, s.end), hi);
        if (to > from) @memset(out[from - lo .. to - lo], s.role);
    }
    return out;
}

/// `got` paints `[lo, hi)` exactly as `all` (every span of the text) does.
fn expectSamePaint(all: []const Span, got: []const Span, lo: usize, hi: usize) !void {
    const gpa = testing.allocator;
    const want = try paintOf(gpa, all, lo, hi);
    defer gpa.free(want);
    const have = try paintOf(gpa, got, lo, hi);
    defer gpa.free(have);
    try testing.expectEqualSlices(Role, want, have);
    // Sorted, non-overlapping, nothing empty.
    var prev: u32 = 0;
    for (got) |s| {
        try testing.expect(s.start >= prev and s.end > s.start);
        prev = s.end;
    }
}

/// Every span of `text` from a highlighter that has seen nothing else.
fn scratchSpans(gpa: Allocator, entry: usize, text: []const u8) ![]Span {
    var fresh = Highlighter.init(gpa);
    defer fresh.deinit();
    fresh.setLanguage(entry);
    return gpa.dupe(Span, try fresh.highlightAll(text));
}

test "rust: keywords, functions, types, strings and numbers each get their role" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const text = "fn hello() -> u32 {\n    let x: u32 = 42;\n    x\n}\n";
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.keyword, roleAt(spans, 0)); // fn
    try testing.expectEqual(Role.function, roleAt(spans, 3)); // hello
    try testing.expectEqual(Role.type, roleAt(spans, 14)); // u32
    try testing.expectEqual(Role.constant, roleAt(spans, std.mem.indexOf(u8, text, "42").?));
    try testing.expect(spans.len >= 5);
    // Non-overlapping and sorted.
    var prev: u32 = 0;
    for (spans) |s| {
        try testing.expect(s.start >= prev and s.end > s.start);
        prev = s.end;
    }
}

test "predicates hold: a capitalised identifier is a constructor, a plain one is not; a later catch-all does not take the node" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const text = "let Zed = limit;\n";
    const spans = try h.highlightAll(text);
    // `((identifier) @constructor (#match? "^[A-Z]"))` precedes the plain
    // `(identifier) @variable` in the shipped query; the catch-all comes
    // later but says less about the node, so the constructor keeps it,
    // and the predicate gates it.
    try testing.expectEqual(Role.special, roleAt(spans, std.mem.indexOf(u8, text, "Zed").?));
    try testing.expect(roleAt(spans, std.mem.indexOf(u8, text, "limit").?) != .special);
}

/// The role painted on the first byte of the `nth` (0-based) occurrence
/// of `needle` in `text`.
fn roleOf(spans: []const Span, text: []const u8, needle: []const u8, nth: usize) Role {
    var at: usize = 0;
    var k: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, needle)) |i| : (k += 1) {
        if (k == nth) return roleAt(spans, i);
        at = i + 1;
    }
    unreachable;
}

test "c_sharp: the query opens with `(identifier) @variable`; the specific captures after it paint class, record, method, attribute, base, new and call names" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("cs").?);
    const text =
        \\using System;
        \\
        \\namespace Acme.Core;
        \\
        \\public record Point(int X, int Y);
        \\
        \\[AttributeUsage(AttributeTargets.Method)]
        \\public sealed class AuditedAttribute : Attribute
        \\{
        \\    public string? Tag { get; init; }
        \\}
        \\
        \\public static class Calc
        \\{
        \\    public static int Add(int a, int b) => a + b;
        \\
        \\    [Audited(Tag = "div")]
        \\    public static int Divide(int a, int b)
        \\    {
        \\        if (b == 0) throw new DivideByZeroException("b is zero");
        \\        return a / b;
        \\    }
        \\
        \\    public static string Describe(object? o) => Calc.Add(1, 2).ToString();
        \\}
        \\
    ;
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.type, roleOf(spans, text, "Calc", 0)); // class_declaration name
    try testing.expectEqual(Role.type, roleOf(spans, text, "Point", 0)); // record_declaration
    try testing.expectEqual(Role.type, roleOf(spans, text, "AuditedAttribute", 0)); // class name
    try testing.expectEqual(Role.type, roleOf(spans, text, "Attribute\n", 0)); // base_list
    try testing.expectEqual(Role.function, roleOf(spans, text, "Add(int", 0)); // method_declaration name
    try testing.expectEqual(Role.function, roleOf(spans, text, "Divide", 0));
    try testing.expectEqual(Role.type, roleOf(spans, text, "AttributeUsage", 0)); // attribute name (@attribute)
    try testing.expectEqual(Role.type, roleOf(spans, text, "Audited(", 0));
    try testing.expectEqual(Role.type, roleOf(spans, text, "DivideByZeroException", 0)); // object_creation type
    try testing.expectEqual(Role.function, roleOf(spans, text, "Add(1", 0)); // invocation member name
    try testing.expectEqual(Role.function, roleOf(spans, text, "ToString", 0));
    // What the catch-all is for: a plain identifier stays plain.
    try testing.expectEqual(Role.default, roleOf(spans, text, "a / b", 0));
    // And what already coloured still does.
    try testing.expectEqual(Role.keyword, roleOf(spans, text, "public", 0));
    try testing.expectEqual(Role.type, roleOf(spans, text, "int X", 0)); // predefined_type
    try testing.expectEqual(Role.string, roleOf(spans, text, "\"div\"", 0));
}

test "python: the query opens with `(identifier) @variable`; def and class names, calls, decorators, builtins and type hints take the later captures" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("py").?);
    const text =
        \\import os
        \\
        \\@decorator
        \\class Foo(Base):
        \\    def bar(self, x: int) -> str:
        \\        return str(len(x))
        \\
        \\total = helper(1)
        \\MAX = None
        \\print(os.path)
        \\
    ;
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.function, roleOf(spans, text, "decorator", 0));
    try testing.expectEqual(Role.function, roleOf(spans, text, "bar", 0)); // function_definition name
    try testing.expectEqual(Role.function, roleOf(spans, text, "len", 0)); // a builtin call
    try testing.expectEqual(Role.function, roleOf(spans, text, "helper", 0)); // a call
    try testing.expectEqual(Role.function, roleOf(spans, text, "print", 0));
    try testing.expectEqual(Role.type, roleOf(spans, text, "int", 0)); // type hint
    try testing.expectEqual(Role.type, roleOf(spans, text, "str:", 0));
    try testing.expectEqual(Role.constant, roleOf(spans, text, "MAX", 0));
    try testing.expect(roleOf(spans, text, "Foo", 0) != .default); // class name: constructor / type
    try testing.expectEqual(Role.default, roleOf(spans, text, "total", 0)); // a plain name stays plain
    try testing.expectEqual(Role.keyword, roleOf(spans, text, "class", 0));
}

test "go: the query closes with `(identifier) @variable`; a catch-all after the specific patterns leaves function and call names alone" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("go").?);
    const text = "package main\n\nfunc (p *Point) Move(dx int) int {\n\treturn p.X + dx\n}\n\nfunc main() {\n\tfmt.Println(helper(2))\n}\n";
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.function, roleOf(spans, text, "Move", 0)); // method_declaration name
    try testing.expectEqual(Role.function, roleOf(spans, text, "main", 1)); // function_declaration name
    try testing.expectEqual(Role.function, roleOf(spans, text, "Println", 0)); // selector call
    try testing.expectEqual(Role.function, roleOf(spans, text, "helper", 0)); // plain call
    try testing.expectEqual(Role.type, roleOf(spans, text, "Point", 0));
}

test "isCatchAll: one node kind and captures, nothing else" {
    try testing.expect(isCatchAll("(identifier) @variable"));
    try testing.expect(isCatchAll("(_) @x"));
    try testing.expect(isCatchAll("[\n  (string_expression)\n  (indented_string_expression)\n] @string"));
    try testing.expect(isCatchAll("; a comment: with (parens)\n(identifier) @variable.member"));
    try testing.expect(!isCatchAll("(method_declaration name: (identifier) @function)"));
    try testing.expect(!isCatchAll("((identifier) @constant (#match? @constant \"^[A-Z]\"))"));
    try testing.expect(!isCatchAll("(base_list (identifier) @type)"));
    try testing.expect(!isCatchAll("[\"fn\" \"let\"] @keyword"));
    try testing.expect(!isCatchAll("(identifier)? @x"));
}

test "injections: markdown fences carry the fenced grammar, inline emphasis and headings paint" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("md").?);
    const text = "# Title\n\nThis is **bold** and *em* text.\n\n```rust\nfn main() { let x = 1; }\n```\n";
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.title, roleAt(spans, 2));
    try testing.expectEqual(Role.strong, roleAt(spans, std.mem.indexOf(u8, text, "bold").?));
    try testing.expectEqual(Role.emphasis, roleAt(spans, std.mem.indexOf(u8, text, "em*").?));
    // The rust fence: `fn` is a keyword only if the injection ran.
    try testing.expectEqual(Role.keyword, roleAt(spans, std.mem.indexOf(u8, text, "fn main").?));
    try testing.expect(spans.len >= 6);
}

test "injections: html routes <style> to css and <script> to javascript" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("html").?);
    const text = "<html><head><style>body { color: red; }</style><script>const x = 42;</script></head><body><div class=\"x\">hi</div></body></html>\n";
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.keyword, roleAt(spans, std.mem.indexOf(u8, text, "const").?));
    try testing.expectEqual(Role.constant, roleAt(spans, std.mem.indexOf(u8, text, "42").?));
    try testing.expect(roleAt(spans, std.mem.indexOf(u8, text, "color").?) != .none);
    try testing.expect(spans.len >= 6);
}

test "inherits: Vue and Svelte take HTML's tags, attributes and <style> as css under their own patterns; Svelte's <script lang=\"ts\"> is TypeScript" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("vue").?);
    const vue = "<template>\n  <div class=\"app\">{{ count + 1 }}</div>\n</template>\n<script setup lang=\"ts\">\nconst n: number = 1;\n</script>\n<style scoped>\n.app { color: red; }\n</style>\n";
    const vs = try h.highlightAll(vue);
    try testing.expectEqual(Role.type, roleAt(vs, std.mem.indexOf(u8, vue, "div").?));
    try testing.expectEqual(Role.string, roleAt(vs, std.mem.indexOf(u8, vue, "app\"").?));
    try testing.expectEqual(Role.variable, roleAt(vs, std.mem.indexOf(u8, vue, "color").?));
    try testing.expectEqual(Role.type, roleAt(vs, std.mem.indexOf(u8, vue, "number").?));
    try testing.expectEqual(Role.constant, roleAt(vs, std.mem.indexOf(u8, vue, "1 }}").?));
    h.setLanguage(table.find("svelte").?);
    const sv = "<script lang=\"ts\">\n  export let start: number = 0;\n</script>\n<button class:active={start > 3}>go</button>\n<style>\n  button { color: blue; }\n</style>\n";
    const ss = try h.highlightAll(sv);
    try testing.expectEqual(Role.type, roleAt(ss, std.mem.indexOf(u8, sv, "button").?));
    try testing.expectEqual(Role.type, roleAt(ss, std.mem.indexOf(u8, sv, "number").?));
    try testing.expectEqual(Role.constant, roleAt(ss, std.mem.indexOf(u8, sv, "3}").?));
    const style = std.mem.indexOf(u8, sv, "<style>").?;
    try testing.expectEqual(Role.type, roleAt(ss, std.mem.indexOfPos(u8, sv, style, "button").?));
    try testing.expectEqual(Role.variable, roleAt(ss, std.mem.indexOfPos(u8, sv, style, "color").?));
}

test "inherits: the base query comes first, the file's own patterns after it, and every name resolves" {
    const src = "; inherits: html_tags\n\n(foo) @bar\n";
    const got = comptime table.withInherited(.highlights, src);
    try testing.expect(std.mem.startsWith(u8, got, @import("ts_queries").html_highlights));
    try testing.expect(std.mem.endsWith(u8, got, src));
    // No modeline, nothing added; a later comment line saying `inherits:` is not one.
    try testing.expectEqualStrings("(a) @b\n; inherits: html\n", comptime table.withInherited(.highlights, "(a) @b\n; inherits: html\n"));
}

test "injections: TypeScript and TSX carry JavaScript's — css / html / sql tagged templates and regex literals are their languages, as in .js" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    const text = "const b = css`\n  color: red;\n`;\nconst p = html`<div class=\"x\">hi</div>`;\nconst q = sql`SELECT id FROM users`;\nconst re = /ab+[0-9]{2}$/;\n";
    for ([_][]const u8{ "js", "ts", "tsx" }) |key| {
        h.setLanguage(table.find(key).?);
        const spans = try h.highlightAll(text);
        errdefer std.debug.print("in {s}\n", .{key});
        try testing.expectEqual(Role.variable, roleAt(spans, std.mem.indexOf(u8, text, "color").?));
        try testing.expectEqual(Role.type, roleAt(spans, std.mem.indexOf(u8, text, "div").?));
        try testing.expectEqual(Role.keyword, roleAt(spans, std.mem.indexOf(u8, text, "SELECT").?));
        // The regex grammar splits the literal: `+` is not the string's colour.
        try testing.expect(roleAt(spans, std.mem.indexOf(u8, text, "+[").?) != roleAt(spans, std.mem.indexOf(u8, text, "ab+").?));
    }
}

test "sql: integers and floats are constants — the query's `#match?` is in Lua's `%d` — and strings stay strings" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("sql").?);
    const text = "SELECT id FROM users WHERE id = 42 AND ratio > 2.5 AND name = 'x';\n";
    const spans = try h.highlightAll(text);
    try testing.expectEqual(Role.constant, roleAt(spans, std.mem.indexOf(u8, text, "42").?));
    try testing.expectEqual(Role.constant, roleAt(spans, std.mem.indexOf(u8, text, "2.5").?));
    try testing.expectEqual(Role.string, roleAt(spans, std.mem.indexOf(u8, text, "'x'").?));
}

test "incremental: an edit told to the tree reparses to the same spans as a fresh parse" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    h.setLanguage(table.find("rs").?);
    const before = "fn a() {}\nfn b() {}\n";
    _ = try h.highlightAll(before);
    // Insert `fn c() {}\n` at the end of line 1 (byte 10).
    const after = "fn a() {}\nfn c() {}\nfn b() {}\n";
    h.edit(.{ .start_byte = 10, .old_end_byte = 10, .new_end_byte = 20, .start_point = .{ .row = 1, .column = 0 }, .old_end_point = .{ .row = 1, .column = 0 }, .new_end_point = .{ .row = 2, .column = 0 } });
    const spans = try h.highlightAll(after);
    const fresh = try scratchSpans(testing.allocator, table.find("rs").?, after);
    defer testing.allocator.free(fresh);
    try testing.expectEqualSlices(Span, fresh, spans);
    try testing.expectEqual(Role.function, roleAt(spans, 13)); // c
}

test "a window slides with an edit: spans after it move, spans across it are clipped, the new text has none" {
    const gpa = testing.allocator;
    var w: Window = .{ .lo = 0, .hi = 14, .valid = true };
    defer w.spans.deinit(gpa);
    try w.spans.appendSlice(gpa, &.{ .{ .start = 0, .end = 2, .role = .keyword }, .{ .start = 3, .end = 8, .role = .function }, .{ .start = 10, .end = 12, .role = .type } });
    w.shift(3, 3, 5); // insert 2 bytes at 3
    try testing.expectEqual(@as(u32, 5), w.spans.items[1].start);
    try testing.expectEqual(@as(u32, 12), w.spans.items[2].start);
    try testing.expectEqual(@as(usize, 16), w.hi);
    w.shift(6, 13, 6); // delete [6,13): clips the function span, drops the type span
    try testing.expectEqual(@as(usize, 2), w.spans.items.len);
    try testing.expectEqual(@as(u32, 6), w.spans.items[1].end);
    try testing.expectEqual(@as(usize, 9), w.hi);
    // An edit wholly before the window moves both ends; one after it moves nothing.
    var v: Window = .{ .lo = 100, .hi = 200, .valid = true };
    defer v.spans.deinit(gpa);
    try v.spans.append(gpa, .{ .start = 120, .end = 130, .role = .string });
    v.shift(10, 10, 15);
    try testing.expectEqual(@as(usize, 105), v.lo);
    try testing.expectEqual(@as(usize, 205), v.hi);
    try testing.expectEqual(@as(u32, 125), v.spans.items[0].start);
    v.shift(300, 310, 300);
    try testing.expectEqual(@as(usize, 205), v.hi);
    try testing.expectEqual(@as(u32, 135), v.spans.items[0].end);
    // Typing AT either edge is typing inside the window — the two places a
    // file is most often typed into, its first byte and its last. A window
    // that moved off instead would miss on every keystroke.
    var top: Window = .{ .lo = 0, .hi = 50, .valid = true };
    defer top.spans.deinit(gpa);
    try top.spans.append(gpa, .{ .start = 0, .end = 2, .role = .keyword });
    top.shift(0, 0, 3);
    try testing.expectEqual(@as(usize, 0), top.lo);
    try testing.expectEqual(@as(usize, 53), top.hi);
    try testing.expectEqual(@as(u32, 3), top.spans.items[0].start);
    top.shift(53, 53, 57); // at the end of the file
    try testing.expectEqual(@as(usize, 0), top.lo);
    try testing.expectEqual(@as(usize, 57), top.hi);
    // One byte past the window is not the window's.
    var far: Window = .{ .lo = 10, .hi = 20, .valid = true };
    defer far.spans.deinit(gpa);
    far.shift(21, 21, 25);
    try testing.expectEqual(@as(usize, 20), far.hi);
}

test "layerSpans: the overlay wins where it covers, the base keeps the rest, and the result stays sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = [_]Span{ .{ .start = 0, .end = 10, .role = .keyword }, .{ .start = 12, .end = 20, .role = .string }, .{ .start = 30, .end = 34, .role = .type } };
    const over = [_]Span{ .{ .start = 3, .end = 5, .role = .function }, .{ .start = 8, .end = 14, .role = .variable }, .{ .start = 40, .end = 42, .role = .constant } };
    const out = try layerSpans(Span, arena.allocator(), &base, &over);
    const want = [_]Span{
        .{ .start = 0, .end = 3, .role = .keyword },
        .{ .start = 3, .end = 5, .role = .function },
        .{ .start = 5, .end = 8, .role = .keyword },
        .{ .start = 8, .end = 14, .role = .variable },
        .{ .start = 14, .end = 20, .role = .string },
        .{ .start = 30, .end = 34, .role = .type },
        .{ .start = 40, .end = 42, .role = .constant },
    };
    try testing.expectEqualSlices(Span, &want, out);
    // No overlay: the base as it was. No base: the overlay as it was.
    try testing.expectEqualSlices(Span, &base, try layerSpans(Span, arena.allocator(), &base, &.{}));
    try testing.expectEqualSlices(Span, &over, try layerSpans(Span, arena.allocator(), &.{}, &over));
}

test "a window slices by byte range" {
    const gpa = testing.allocator;
    var w: Window = .{ .lo = 0, .hi = 100, .valid = true };
    defer w.spans.deinit(gpa);
    try w.spans.appendSlice(gpa, &.{ .{ .start = 0, .end = 2, .role = .keyword }, .{ .start = 5, .end = 8, .role = .function }, .{ .start = 10, .end = 12, .role = .type } });
    try testing.expectEqual(@as(usize, 1), w.slice(6, 9).len);
    try testing.expectEqual(@as(usize, 2), w.slice(1, 6).len);
    try testing.expectEqual(@as(usize, 0), w.slice(12, 20).len);
    try testing.expectEqual(@as(usize, 3), w.slice(0, 100).len);
}

test "every grammar highlights its fixture through the engine" {
    var h = Highlighter.init(testing.allocator);
    defer h.deinit();
    for (table.entries, 0..) |e, i| {
        h.setLanguage(i);
        if ((try h.highlightAll(e.fixture)).len == 0) {
            std.debug.print("{s}: no spans on its fixture\n", .{e.key});
            return error.NoSpans;
        }
    }
}

/// A text long enough that a window is a small part of it: `unit`
/// repeated past `min_len`.
fn repeated(gpa: Allocator, unit: []const u8, min_len: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    while (out.items.len < min_len) try out.appendSlice(gpa, unit);
    return out.toOwnedSlice(gpa);
}

test "a window paints its bytes exactly as the whole file does: every grammar, injections included, none of them near the match cap" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x77696e64);
    const rand = prng.random();
    var excused: std.ArrayListUnmanaged([]const u8) = .empty;
    defer excused.deinit(gpa);
    for (table.entries, 0..) |e, i| {
        // Long enough that the margin does not swallow the file.
        const text = try repeated(gpa, e.fixture, 16 * window_margin);
        defer gpa.free(text);
        // The reference: every span of the file, from a highlighter that
        // has seen nothing else. It is a reference only while every query
        // behind it kept every match: one that ran into the cursor's cap
        // let some go, and what a capped query paints moves with the cap
        // and the range. Such a text has no exact answer to hold a window
        // to, so it is reported and fails the test, never skipped.
        var ref = Highlighter.init(gpa);
        defer ref.deinit();
        ref.setLanguage(i);
        const all = try gpa.dupe(Span, try ref.highlightAll(text));
        defer gpa.free(all);
        var capped = ref.dropped_matches;
        var h = Highlighter.init(gpa);
        defer h.deinit();
        h.setLanguage(i);
        h.parse(text);
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            const lo = rand.uintLessThan(usize, text.len);
            const hi = @min(text.len, lo + 1 + rand.uintLessThan(usize, 3000));
            const got = try gpa.dupe(Span, try h.spansIn(text, lo, hi));
            defer gpa.free(got);
            if (h.dropped_matches) capped = true;
            // Whatever the cap did, the spans are well formed and inside
            // what was asked for.
            var prev: u32 = 0;
            for (got) |s| {
                try testing.expect(s.start >= prev and s.end > s.start);
                try testing.expect(s.end > lo and s.start < hi);
                prev = s.end;
            }
            if (!capped) expectSamePaint(all, got, lo, hi) catch |err| {
                std.debug.print("{s}: window [{d}, {d}) differs from the whole file\n", .{ e.key, lo, hi });
                return err;
            };
            // What is kept covers more than was asked, and never the file.
            try testing.expect(h.covers(lo, hi));
        }
        for (&h.windows) |*w| try testing.expect(w.hi - w.lo <= 3001 + 2 * window_margin);
        if (capped) try excused.append(gpa, e.key);
    }
    // No grammar's query nears the cap on its fixture repeated to 128 KB
    // (Haskell's did, until its misplaced paren was corrected): every one
    // was compared exactly. A name here is a grammar that lost that.
    if (excused.items.len != 0) {
        for (excused.items) |k| std.debug.print("{s} ran into the match cap; its windows were not compared with the whole file\n", .{k});
        return error.GrammarReachedMatchCap;
    }
}

/// `(row, column)` of byte `at`, the way `InputEdit` wants it.
fn pointOf(text: []const u8, at: usize) ts.Point {
    var row: u32 = 0;
    var bol: usize = 0;
    for (text[0..at], 0..) |c, i| if (c == '\n') {
        row += 1;
        bol = i + 1;
    };
    return .{ .row = row, .column = @intCast(at - bol) };
}

test "incremental property: after every random edit the kept tree's windows paint what a from-scratch parse paints" {
    const gpa = testing.allocator;
    const Case = struct { key: []const u8, seed: []const u8, bits: []const []const u8 };
    const cases = [_]Case{
        .{
            .key = "rs",
            .seed = "use std::fmt;\n\n/// Doc.\npub fn alpha(x: u32) -> u32 {\n    let s = \"text\";\n    println!(\"{} {}\", x, s);\n    x + 1\n}\n\nstruct Point { x: i64, y: i64 }\n\nimpl Point {\n    fn len(&self) -> i64 { self.x * self.y }\n}\n",
            .bits = &.{ "fn z() {}\n", "let q = 7;", "\"", "{", "}", "(", ")", "// note\n", "/* ", " */", "vec![1, 2]", "\n", " ", "Some(x)", "'a", "#[test]\n", "pub ", "match v { _ => 0 }" },
        },
        .{
            .key = "md",
            .seed = "# Title\n\nSome *emphasis* and **strong** text with `code`.\n\n```rust\nfn main() { let x = 1; }\n```\n\n- item one\n- item two\n\n<div class=\"x\">html</div>\n\n## Second\n\n[link](http://example.test) tail.\n",
            .bits = &.{ "*", "**", "`", "```\n", "```js\nconst a = 1;\n```\n", "# H\n", "\n\n", "- x\n", "[a](b)", " ", "word", "<b>", "</b>", "> quote\n" },
        },
        .{
            .key = "html",
            .seed = "<html><head><style>body { color: red; }</style><script>const x = 42; function f() { return x; }</script></head><body><div class=\"x\">hi</div></body></html>\n",
            .bits = &.{ "<p>", "</p>", "<script>let y = 1;</script>", "<style>a { top: 0 }</style>", "\"", "<", ">", " id=\"k\"", "text", "\n", "<!-- c -->", "{", "}" },
        },
    };
    var prng = std.Random.DefaultPrng.init(0x68696c69);
    const rand = prng.random();
    for (cases) |case| {
        const entry = table.find(case.key).?;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(gpa);
        // Several windows' worth, so the windows that are kept are tested
        // as windows rather than as the whole file.
        while (text.items.len < 3 * window_margin) try text.appendSlice(gpa, case.seed);
        var h = Highlighter.init(gpa);
        defer h.deinit();
        h.setLanguage(entry);
        h.parse(text.items);
        _ = try h.spansIn(text.items, 0, 400);
        // The reference, one per case: `invalidate` before each step drops
        // its tree, windows and injected trees, so every step's answer is
        // a from-scratch parse of the text as it stands; only the
        // compiled queries carry over. A fresh highlighter per step
        // compiled them 180 times, half of this test's 24-31 s in Debug.
        var ref = Highlighter.init(gpa);
        defer ref.deinit();
        ref.setLanguage(entry);
        var step: usize = 0;
        while (step < 60) : (step += 1) {
            // One to three edits between parses, as a burst of typing is.
            var burst: usize = 1 + rand.uintLessThan(usize, 3);
            while (burst > 0) : (burst -= 1) {
                // Edits cluster: near the start, near the end, anywhere.
                const at = switch (rand.uintLessThan(u8, 3)) {
                    0 => rand.uintLessThan(usize, @min(text.items.len, 300) + 1),
                    1 => text.items.len - rand.uintLessThan(usize, @min(text.items.len, 300) + 1),
                    else => rand.uintLessThan(usize, text.items.len + 1),
                };
                const del = if (rand.boolean()) @min(text.items.len - at, rand.uintLessThan(usize, 40)) else 0;
                const ins: []const u8 = if (del == 0 or rand.boolean()) case.bits[rand.uintLessThan(usize, case.bits.len)] else "";
                const start_pt = pointOf(text.items, at);
                const old_end_pt = pointOf(text.items, at + del);
                try text.replaceRange(gpa, at, del, ins);
                h.edit(.{
                    .start_byte = @intCast(at),
                    .old_end_byte = @intCast(at + del),
                    .new_end_byte = @intCast(at + ins.len),
                    .start_point = start_pt,
                    .old_end_point = old_end_pt,
                    .new_end_point = pointOf(text.items, at + ins.len),
                });
            }
            h.parse(text.items);
            ref.invalidate();
            const all = try gpa.dupe(Span, try ref.highlightAll(text.items));
            defer gpa.free(all);
            var probe: usize = 0;
            while (probe < 4) : (probe += 1) {
                const lo = if (text.items.len == 0) 0 else rand.uintLessThan(usize, text.items.len);
                const hi = @min(text.items.len, lo + 1 + rand.uintLessThan(usize, 2000));
                const got = try h.spansIn(text.items, lo, hi);
                expectSamePaint(all, got, lo, hi) catch |err| {
                    std.debug.print("{s}: step {d}, window [{d}, {d}) differs from a from-scratch parse\n", .{ case.key, step, lo, hi });
                    return err;
                };
            }
            // And the whole file, through the same kept tree.
            const whole = try gpa.dupe(Span, try h.spansIn(text.items, 0, text.items.len));
            defer gpa.free(whole);
            try testing.expectEqualSlices(Span, all, whole);
        }
    }
}

test "a long injected range keeps its tree between windows and lets go of it at the next parse" {
    const gpa = testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "<html><body><script>\n");
    while (text.items.len < 3 * injected_keep_min) try text.appendSlice(gpa, "const value = 42; function f(a) { return a + value; }\n");
    try text.appendSlice(gpa, "</script></body></html>\n");
    var h = Highlighter.init(gpa);
    defer h.deinit();
    h.setLanguage(table.find("html").?);
    h.parse(text.items);
    const a = try gpa.dupe(Span, try h.spansIn(text.items, 100, 200));
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 1), h.injected.items.len);
    const kept = h.injected.items[0].tree;
    // A window far from the first misses every kept window and reuses the tree.
    _ = try h.spansIn(text.items, text.items.len - 300, text.items.len - 100);
    try testing.expectEqual(@as(usize, 1), h.injected.items.len);
    try testing.expectEqual(kept, h.injected.items[0].tree);
    try testing.expectEqual(Role.keyword, roleAt(a, std.mem.indexOfPos(u8, text.items, 100, "const").?));
    h.parse(text.items);
    try testing.expectEqual(@as(usize, 0), h.injected.items.len);
}

test "the match cap is a crash guard: a query that fans out past the cursor's 16-bit capture-list ids finishes instead of reading a freed list" {
    const gpa = testing.allocator;
    // The 54-byte Haskell fixture pasted some 2400 times, and the two
    // patterns tree-sitter-haskell 0.23.1 shipped with a misplaced paren
    // (`src/highlight/queries/haskell.scm` corrects them): `match: (_)`
    // as a third, unanchored sibling keeps a match in progress per
    // signature - more than the cursor's 16-bit ids can name. Without a
    // cap that reads a freed capture list; at 65535 it runs for minutes.
    //
    // The work before the cap trips grows with the cube of the input
    // (measured in Debug: 14 s at 32 KB, 111 s at 64 KB, 383 s at the
    // full 128 KB — tree-sitter's C at -O0). The shipped cap trips
    // between 32 and 64 KB, so a Debug build runs the same query on a
    // sixteenth of the text against a sixteenth of the cap: 8 KB and 64,
    // which trips in well under a second (4 KB already does). The
    // cursor still comes from `QueryCursor.init`, and the cap it sets is
    // asserted first, so the shipped figure stays under test in both
    // modes; optimized builds run the full text against it.
    const scale: u32 = if (builtin.mode == .Debug) 16 else 1;
    const e = table.entries[table.find("hs").?];
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    while (text.items.len < 128 * 1024 / scale) try text.appendSlice(gpa, e.fixture);
    const parser = try ts.Parser.init();
    defer parser.deinit();
    try parser.setLanguage(e.language());
    const tree = parser.parseString(null, text.items).?;
    defer tree.deinit();
    const broken =
        \\((decl/signature name: (variable) @_name type: (type))
        \\  . (decl name: (variable) @variable) match: (_)
        \\  (#eq? @_name @variable))
    ;
    const q = try ts.Query.init(e.language(), broken, null);
    defer q.deinit();
    const cursor = try ts.QueryCursor.init();
    defer cursor.deinit();
    try testing.expectEqual(ts.QueryCursor.max_match_limit, cursor.matchLimit());
    cursor.setMatchLimit(ts.QueryCursor.max_match_limit / scale);
    cursor.exec(q, tree.rootNode());
    var ci: u32 = 0;
    var n: usize = 0;
    while (cursor.nextCapture(&ci)) |_| n += 1;
    try testing.expect(cursor.didExceedMatchLimit());
    // And the query as shipped, corrected, over the full 128 KB (cheap
    // in any mode — the corrected query never fans out): every match
    // kept.
    while (text.items.len < 128 * 1024) try text.appendSlice(gpa, e.fixture);
    var h = Highlighter.init(gpa);
    defer h.deinit();
    h.setLanguage(table.find("hs").?);
    try testing.expect((try h.highlightAll(text.items)).len > 1000);
    try testing.expectEqual(@as(u64, 0), h.drops);
}
