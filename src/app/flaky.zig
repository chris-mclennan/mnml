//! The flaky-test dashboard (`Pane.flaky`) and the history behind it:
//! for every `(file, suite, title)` the last ten outcomes across
//! Playwright runs in this workspace, persisted as ZON at
//! `<ws>/.mnml/flaky.zon`. A test that went both ways in that window
//! is *wobbly* — the tests pane marks it `≋`, and the dashboard lists
//! every wobbly test with its outcome bar (`✓✓✗✓~`), sorted by how
//! often it flipped (most first), then file and title. Enter jumps to
//! the test's line; `r` rebuilds from the history; `esc` closes.
//!
//! Best-effort storage: a missing or unreadable file is an empty
//! history; a failed write is a toast, never a failed run.
//!
//!   D1  the history's keys are gpa-owned and freed in `State.deinit`;
//!       the pane's items live on its snapshot arena, replaced on refresh.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const tests_pane = @import("tests_pane.zig");

pub const table = .{
    .@"flaky.show" = &showCmd,
};

pub const file_name = "flaky.zon";
/// Outcomes kept per test: recent enough to matter, short enough that
/// a fix shows up quickly.
pub const keep: usize = 10;

pub const Outcome = enum(u8) {
    pass = 'P',
    fail = 'F',
    /// Playwright's own per-run marker: passed on a retry.
    flaky = '~',

    pub fn glyph(o: Outcome, ascii: bool) []const u8 {
        return switch (o) {
            .pass => if (ascii) "+" else "✓",
            .fail => if (ascii) "x" else "✗",
            .flaky => "~",
        };
    }
};

pub const Entry = struct {
    /// Most recent last.
    outcomes: [keep]Outcome = undefined,
    len: u8 = 0,
    /// 1-based line last seen for the test, 0 when never.
    line: u32 = 0,

    pub fn slice(e: *const Entry) []const Outcome {
        return e.outcomes[0..e.len];
    }

    pub fn push(e: *Entry, o: Outcome) void {
        if (e.len == keep) {
            std.mem.copyForwards(Outcome, e.outcomes[0 .. keep - 1], e.outcomes[1..keep]);
            e.len -= 1;
        }
        e.outcomes[e.len] = o;
        e.len += 1;
    }

    /// At least one pass and one non-pass in the window. One outcome
    /// is never wobbly — let a new test run a few times first.
    pub fn wobbly(e: *const Entry) bool {
        var pass = false;
        var other = false;
        for (e.slice()) |o| {
            if (o == .pass) pass = true else other = true;
        }
        return pass and other;
    }

    /// Adjacent outcome changes — the dashboard's sort key.
    pub fn flips(e: *const Entry) u32 {
        var n: u32 = 0;
        const s = e.slice();
        var i: usize = 1;
        while (i < s.len) : (i += 1) n += @intFromBool((s[i] == .pass) != (s[i - 1] == .pass));
        return n;
    }
};

/// `file\tsuite\ttitle` — the suite matters because sibling
/// `describe`s may share a title; a tab is never in a file name.
pub fn keyOf(arena: Allocator, file: []const u8, suite: []const u8, title: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}\t{s}\t{s}", .{ file, suite, title });
}

pub const History = struct {
    /// Owned keys.
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    pub fn deinit(self: *History, gpa: Allocator) void {
        for (self.entries.keys()) |k| gpa.free(k);
        self.entries.deinit(gpa);
    }

    pub fn record(self: *History, gpa: Allocator, key: []const u8, outcome: Outcome, line: u32) Allocator.Error!void {
        if (self.entries.getPtr(key)) |e| {
            e.push(outcome);
            e.line = line;
            return;
        }
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        var e: Entry = .{ .line = line };
        e.push(outcome);
        try self.entries.put(gpa, owned, e);
    }

    pub fn get(self: *const History, key: []const u8) ?*const Entry {
        return self.entries.getPtr(key);
    }
};

// ─── the file ───────────────────────────────────────────────────────────

pub const format_version: u32 = 1;

const SavedTest = struct { key: []const u8, outcomes: []const u8, line: u32 = 0 };
const Saved = struct { version: u32 = format_version, tests: []const SavedTest = &.{} };

/// The history as ZON text on `arena`, keys sorted so the file diffs.
pub fn render(arena: Allocator, h: *const History) Allocator.Error![]u8 {
    const keys = try arena.dupe([]const u8, h.entries.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const tests = try arena.alloc(SavedTest, keys.len);
    for (keys, 0..) |k, i| {
        const e = h.entries.get(k).?;
        const bar = try arena.alloc(u8, e.len);
        for (e.slice(), 0..) |o, j| bar[j] = @intFromEnum(o);
        tests[i] = .{ .key = k, .outcomes = bar, .line = e.line };
    }
    var out: Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml flaky-test history — the last ten Playwright outcomes per test; delete it to start clean.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(Saved{ .tests = tests }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

/// Parse ZON text into `h` (gpa-owned keys). Unknown outcome letters
/// are dropped; a newer format is ignored.
pub fn parseInto(gpa: Allocator, arena: Allocator, h: *History, src: [:0]const u8) Allocator.Error!void {
    const saved = compat.zonParse(Saved, arena, src, null, .{ .ignore_unknown_fields = true }) catch return;
    if (saved.version > format_version) return;
    for (saved.tests) |st| {
        for (st.outcomes) |c| {
            const o: Outcome = switch (c) {
                'P' => .pass,
                'F' => .fail,
                '~' => .flaky,
                else => continue,
            };
            try h.record(gpa, st.key, o, st.line);
        }
    }
}

pub fn path(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ app.workspace, ".mnml", file_name });
}

// ─── app state ──────────────────────────────────────────────────────────

pub const State = struct {
    history: History = .{},
    loaded: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.history.deinit(gpa);
    }
};

/// Read the file once per process (a later `recordRun` writes it back).
pub fn ensureLoaded(app: *App) Allocator.Error!void {
    if (app.flaky.loaded) return;
    app.flaky.loaded = true;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try path(app, arena);
    const src = Io.Dir.cwd().readFileAllocOptions(app.io, p, arena, .limited(16 * 1024 * 1024), .of(u8), 0) catch return;
    try parseInto(app.gpa, arena, &app.flaky.history, src);
}

pub fn save(app: *App) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try render(arena, &app.flaky.history);
    const p = try path(app, arena);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, std.fs.path.dirname(p) orelse ".") catch {
        app.toast("flaky: could not write {s}", .{p});
        return;
    };
    cwd.writeFile(app.io, .{ .sub_path = p, .data = text }) catch app.toast("flaky: could not write {s}", .{p});
}

/// Every outcome of `run` into the history (skipped tests say
/// nothing), then to disk, then every open dashboard refreshed.
pub fn recordRun(app: *App, run: tests_pane.TestRun) Allocator.Error!void {
    try ensureLoaded(app);
    const arena = app.frame.allocator();
    for (run.tests) |tc| {
        const o: Outcome = switch (tc.status) {
            .passed => .pass,
            .failed => .fail,
            .flaky => .flaky,
            .skipped => continue,
        };
        try app.flaky.history.record(app.gpa, try keyOf(arena, tc.file, tc.suite_path, tc.title), o, tc.line);
    }
    try save(app);
    try refreshAll(app);
}

pub fn isWobbly(app: *App, file: []const u8, suite: []const u8, title: []const u8) bool {
    const key = keyOf(app.frame.allocator(), file, suite, title) catch return false;
    const e = app.flaky.history.get(key) orelse return false;
    return e.wobbly();
}

// ─── the pane ───────────────────────────────────────────────────────────

pub const Item = struct {
    /// Workspace-relative spec file.
    rel: []const u8,
    suite: []const u8,
    title: []const u8,
    line: u32,
    outcomes: []const Outcome,
    flips: u32,
};

pub const FlakyPane = struct {
    snapshot: alloc.SnapshotArena,
    items: []const Item = &.{},
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn init(gpa: Allocator) FlakyPane {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    pub fn deinit(self: *FlakyPane) void {
        self.snapshot.deinit();
    }

    pub fn title(self: *const FlakyPane) []const u8 {
        return if (self.items.len == 0) "flaky ✓" else "flaky ≋";
    }

    pub fn selected(self: *const FlakyPane) ?*const Item {
        return if (self.cursor < self.items.len) &self.items[self.cursor] else null;
    }
};

/// The wobbly tests of `h` as items on `arena`: most flips first, then
/// file, then title.
pub fn wobblyItems(arena: Allocator, h: *const History) Allocator.Error![]Item {
    var out: std.ArrayListUnmanaged(Item) = .empty;
    var it = h.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        if (!e.wobbly()) continue;
        var parts = std.mem.splitScalar(u8, kv.key_ptr.*, '\t');
        const file = parts.next() orelse continue;
        const suite = parts.next() orelse continue;
        const title = parts.rest();
        try out.append(arena, .{
            .rel = try arena.dupe(u8, file),
            .suite = try arena.dupe(u8, suite),
            .title = try arena.dupe(u8, title),
            .line = e.line,
            .outcomes = try arena.dupe(Outcome, e.slice()),
            .flips = e.flips(),
        });
    }
    std.mem.sort(Item, out.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            if (a.flips != b.flips) return a.flips > b.flips;
            const f = std.mem.order(u8, a.rel, b.rel);
            if (f != .eq) return f == .lt;
            return std.mem.order(u8, a.title, b.title) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.flaky);
}

fn rebuild(app: *App, p: *FlakyPane) Allocator.Error!void {
    try ensureLoaded(app);
    p.snapshot.reset();
    p.items = try wobblyItems(p.snapshot.allocator(), &app.flaky.history);
    if (p.cursor >= p.items.len) p.cursor = p.items.len -| 1;
    app.needs_render = true;
}

/// Every open dashboard, from the current history.
pub fn refreshAll(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .flaky => |*p| try rebuild(app, p),
        else => {},
    };
}

/// `flaky.show`: the one dashboard, below the active pane; a refresh
/// when it is already open.
fn showCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        try rebuild(app, &app.panes.get(id).?.flaky);
        return;
    }
    const id = try app.panes.add(.{ .flaky = FlakyPane.init(app.gpa) });
    const layout = app.layouts.current();
    if (app.active) |cur| if (layout.leafOf(cur) != null) {
        _ = layout.split(cur, .horizontal, id) catch {};
    };
    app.showPane(id);
    try rebuild(app, &app.panes.get(id).?.flaky);
}

pub fn handleKey(app: *App, id: PaneId, p: *FlakyPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const last = p.items.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .enter => jump(app, p),
        .esc => try app.forceClosePane(id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'r' => try rebuild(app, p),
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn jump(app: *App, p: *FlakyPane) void {
    const it = p.selected() orelse return;
    tests_pane.jumpTo(app, it.rel, it.line) catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("flaky: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// A click focuses the row; a second click on it jumps.
pub fn click(app: *App, p: *FlakyPane, row: u32, m: Mouse) void {
    if (row >= p.items.len) return;
    if (m.kind != .press or m.button != .left) return;
    if (p.cursor == row) jump(app, p) else p.cursor = row;
    app.needs_render = true;
}

pub fn scrollBy(p: *FlakyPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.items.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "history: records, caps at ten, classifies wobbly, counts flips" {
    var h: History = .{};
    defer h.deinit(t.allocator);
    try h.record(t.allocator, "x\tS\tflips", .pass, 3);
    try h.record(t.allocator, "x\tS\tsolid", .pass, 9);
    try h.record(t.allocator, "x\tS\tdead", .fail, 1);
    try t.expect(!h.get("x\tS\tflips").?.wobbly());
    try t.expect(!h.get("x\tS\tdead").?.wobbly());
    try h.record(t.allocator, "x\tS\tflips", .fail, 4);
    try t.expect(h.get("x\tS\tflips").?.wobbly());
    try t.expectEqual(@as(u32, 1), h.get("x\tS\tflips").?.flips());
    try t.expectEqual(@as(u32, 4), h.get("x\tS\tflips").?.line);
    try h.record(t.allocator, "x\tS\tflips", .pass, 4);
    try h.record(t.allocator, "x\tS\tflips", .flaky, 4);
    try t.expectEqual(@as(u32, 3), h.get("x\tS\tflips").?.flips());
    // Twelve more passes: the window is ten, the fail ages out.
    var i: usize = 0;
    while (i < 12) : (i += 1) try h.record(t.allocator, "x\tS\tflips", .pass, 4);
    try t.expectEqual(@as(u8, 10), h.get("x\tS\tflips").?.len);
    try t.expect(!h.get("x\tS\tflips").?.wobbly());
}

test "the ZON file round-trips and unknown letters are dropped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h: History = .{};
    defer h.deinit(t.allocator);
    try h.record(t.allocator, "b.spec.ts\t\tbeta", .fail, 5);
    try h.record(t.allocator, "b.spec.ts\t\tbeta", .pass, 5);
    try h.record(t.allocator, "a.spec.ts\tS\talpha", .pass, 10);
    try h.record(t.allocator, "a.spec.ts\tS\talpha", .flaky, 11);
    const text = try render(a, &h);
    try t.expect(std.mem.indexOf(u8, text, ".key = \"a.spec.ts\\tS\\talpha\"") != null);
    try t.expect(std.mem.indexOf(u8, text, ".outcomes = \"P~\"") != null);
    try t.expect(std.mem.indexOf(u8, text, ".outcomes = \"FP\"") != null);
    try t.expect(std.mem.indexOf(u8, text, ".version = 1") != null);
    var h2: History = .{};
    defer h2.deinit(t.allocator);
    try parseInto(t.allocator, a, &h2, try a.dupeSentinel(u8, text, 0));
    try t.expectEqual(@as(usize, 2), h2.entries.count());
    try t.expect(h2.get("b.spec.ts\t\tbeta").?.wobbly());
    try t.expectEqual(@as(u32, 11), h2.get("a.spec.ts\tS\talpha").?.line);
    var h3: History = .{};
    defer h3.deinit(t.allocator);
    try parseInto(t.allocator, a, &h3, ".{ .version = 1, .tests = .{ .{ .key = \"k\", .outcomes = \"PzF\" } } }");
    try t.expectEqual(@as(u8, 2), h3.get("k").?.len);
    try parseInto(t.allocator, a, &h3, "garbage");
    try t.expectEqual(@as(usize, 1), h3.entries.count());
    // Items: most flips first, then file, then title.
    const items = try wobblyItems(a, &h2);
    try t.expectEqual(@as(usize, 2), items.len);
    try t.expectEqualStrings("alpha", items[0].title);
    try t.expectEqual(@as(u32, 1), items[0].flips);
    try t.expectEqualStrings("beta", items[1].title);
}

test "flaky.show lists the workspace's wobbly tests from .mnml/flaky.zon; enter jumps; a run refreshes it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/flaky.zon", .data = ".{ .version = 1, .tests = .{ .{ .key = \"a.spec.ts\\tS\\tone\", .outcomes = \"PFPF\", .line = 3 }, .{ .key = \"a.spec.ts\\tS\\ttwo\", .outcomes = \"PPPF\", .line = 2 }, .{ .key = \"b.spec.ts\\t\\tsolid\", .outcomes = \"PPP\" } } }\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.spec.ts", .data = "1\n2\n3\n4\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try showCmd(&app);
    const id = find(&app).?;
    const p = &app.panes.get(id).?.flaky;
    try t.expectEqual(@as(usize, 2), p.items.len);
    try t.expectEqualStrings("one", p.items[0].title);
    try t.expectEqual(@as(u32, 3), p.items[0].flips);
    try t.expectEqualStrings("flaky ≋", p.title());
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    const e = app.activeEditor().?;
    try t.expectEqualStrings("a.spec.ts", app.relPath(e.buf.doc.path.?));
    try t.expectEqual(@as(usize, 2), e.buf.editor.rowCol().row);
    // A run that passes `one` twice more still leaves it wobbly; the
    // dashboard refreshes and the file is rewritten.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const run: tests_pane.TestRun = .{ .tests = &.{.{ .title = "one", .suite_path = "S", .file = "a.spec.ts", .line = 3, .status = .passed, .duration_ms = 1, .err = null, .trace_path = null }} };
    try recordRun(&app, run);
    try t.expectEqual(@as(usize, 2), p.items.len);
    try t.expectEqual(@as(usize, 5), app.flaky.history.get("a.spec.ts\tS\tone").?.len);
    const text = try tmp.dir.readFileAlloc(t.io, ".mnml/flaky.zon", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"PFPFP\"") != null);
    // A second `flaky.show` refocuses the same pane.
    try showCmd(&app);
    try t.expectEqual(id, find(&app).?);
    try t.expectEqual(id, app.active.?);
}
