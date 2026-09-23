//! The live-grep picker: the workspace grep behind the picker overlay
//! instead of behind a pane. What you type IS the pattern — the rows
//! are not fuzzy-filtered, they are re-run — and the preview column
//! shows the file around the hit under the cursor with the match
//! painted.
//!
//! It borrows the grep pane's worker whole (`app/grep.zig`): the same
//! `rg`-then-walk backends, the same batched `Result` events, the same
//! generation guard. Only the target differs — a batch addressed to
//! `target` lands here rather than in a pane, as the SEARCH section's
//! already does.
//!
//! Typing arms a debounce (`debounce_ms`) rather than starting a run
//! per keystroke; the rows on screen stay put until the new ones
//! arrive, so the list never blinks empty while you type.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const grep = @import("grep.zig");
const find_mod = @import("find.zig");
const cmd_picker = @import("cmd_picker.zig");
const dispatch = @import("dispatch.zig");

pub const table = .{
    .@"find.live_grep" = &open,
};

/// The `Result.pane` a live-grep batch carries: no pane owns it.
pub const target: PaneId = std.math.maxInt(PaneId) - 1;

/// Rows past this are dropped — a picker is a short list, not a report.
pub const max_rows: usize = 500;
/// How long the typed pattern rests before it becomes a run.
pub const debounce_ms: i64 = 160;
/// Shorter than this and nothing runs: `a` would match the workspace.
pub const min_query: usize = 2;

pub const State = struct {
    group: Io.Group = .init,
    abort: *grep.Abort,
    generation: u32 = 0,
    /// The pattern the run in flight was started for (gpa).
    ran: []u8 = &.{},
    /// When the typed pattern is next turned into a run.
    requery_at_ms: ?i64 = null,
    /// A run is in flight.
    loading: bool = false,

    pub fn init(gpa: Allocator) Allocator.Error!State {
        const abort = try gpa.create(grep.Abort);
        abort.* = .{};
        return .{ .abort = abort };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.abort.generation.store(std.math.maxInt(u32), .release);
        self.group.cancel(io);
        gpa.destroy(self.abort);
        gpa.free(self.ran);
    }
};

/// `find.live_grep`: the empty picker, waiting for a pattern.
pub fn open(app: *App) CommandError!void {
    const gpa = app.gpa;
    stop(app);
    try cmd_picker.openPicker(app, "Live grep", .grep, try gpa.alloc([]u8, 0), try gpa.alloc(PaneId, 0));
    app.overlay.picker.state.has_preview = true;
    app.overlay.picker.state.total = 0;
}

/// Cancel whatever is in flight; the next run gets a fresh generation.
pub fn stop(app: *App) void {
    const st = &app.grep_picker;
    st.abort.generation.store(std.math.maxInt(u32), .release);
    st.group.cancel(app.io);
    st.loading = false;
    st.requery_at_ms = null;
}

/// The pattern changed: arm the debounce. The rows on screen stay.
pub fn noteQueryChanged(app: *App, now: i64) void {
    if (app.overlay != .picker or app.overlay.picker.kind != .grep) return;
    app.grep_picker.requery_at_ms = now + debounce_ms;
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    if (app.overlay != .picker or app.overlay.picker.kind != .grep) return null;
    return app.grep_picker.requery_at_ms;
}

/// The debounce came due: start the run.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    if (app.overlay != .picker or app.overlay.picker.kind != .grep) return;
    const due = app.grep_picker.requery_at_ms orelse return;
    if (now < due) return;
    app.grep_picker.requery_at_ms = null;
    try run(app);
}

/// Start the worker for the pattern in the picker's field.
fn run(app: *App) Allocator.Error!void {
    const st = &app.grep_picker;
    const query = app.overlay.picker.state.queryText();
    st.abort.generation.store(std.math.maxInt(u32), .release);
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.abort.generation.store(st.generation, .release);
    try clearRows(app);
    if (query.len < min_query) {
        st.loading = false;
        app.needs_render = true;
        return;
    }
    const q = try app.gpa.dupe(u8, query);
    app.gpa.free(st.ran);
    st.ran = q;
    var flags: grep.Flags = .{};
    if (find_mod.hasUpper(q)) flags.case_sensitive = true;
    if (app.search_case) |c| flags.case_sensitive = c;
    st.loading = true;
    app.needs_render = true;
    st.group.concurrent(app.io, grep.worker, .{ &app.events, app.io, app.gpa, @as([]const u8, app.workspace), @as([]const u8, st.ran), flags, st.generation, target, st.abort, false }) catch {
        st.loading = false;
    };
}

/// A batch for the picker: append its hits as rows.
pub fn handle(app: *App, result: *grep.Result) Allocator.Error!void {
    defer result.destroy(app.gpa);
    const st = &app.grep_picker;
    if (result.generation != st.generation) return;
    if (app.overlay != .picker or app.overlay.picker.kind != .grep) return;
    const gpa = app.gpa;
    const p = &app.overlay.picker;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var rows: std.ArrayListUnmanaged(app_mod.GrepRow) = .empty;
    try labels.appendSlice(gpa, p.labels);
    try rows.appendSlice(gpa, p.grep_hits);
    errdefer {
        labels.deinit(gpa);
        rows.deinit(gpa);
    }
    for (result.hits.items) |h| {
        if (labels.items.len >= max_rows) break;
        const label = try std.fmt.allocPrint(gpa, "{s}:{d}  {s}", .{ h.rel, h.line, std.mem.trim(u8, h.text, " \t") });
        errdefer gpa.free(label);
        const path = try gpa.dupe(u8, h.path);
        errdefer gpa.free(path);
        try labels.append(gpa, label);
        try rows.append(gpa, .{ .path = path, .line = h.line, .col = h.col, .len = h.len });
    }
    gpa.free(p.labels);
    gpa.free(p.grep_hits);
    p.labels = try labels.toOwnedSlice(gpa);
    p.grep_hits = try rows.toOwnedSlice(gpa);
    p.state.total = p.labels.len;
    try dispatch.refilterPicker(app);
    cmd_picker.preview(app);
    if (result.done) st.loading = false;
    app.needs_render = true;
}

/// Drop the rows the last run left.
fn clearRows(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    const p = &app.overlay.picker;
    for (p.labels) |l| gpa.free(l);
    gpa.free(p.labels);
    for (p.grep_hits) |h| gpa.free(h.path);
    gpa.free(p.grep_hits);
    p.labels = try gpa.alloc([]u8, 0);
    p.grep_hits = try gpa.alloc(app_mod.GrepRow, 0);
    p.state.total = 0;
    p.state.cursor = 0;
    p.filtered.clearRetainingCapacity();
    app_mod.Overlay.freePreview(gpa, p.preview);
    p.preview = &.{};
    p.state.preview_focus = null;
    p.state.preview_scroll = 0;
}

/// Enter on a row: open the file at the hit's line and column.
pub fn accept(app: *App, row: app_mod.GrepRow) Allocator.Error!void {
    const id = app.openPath(row.path) catch return;
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .editor => |*e| e.buf.editor.placeCursorByte(row.line -| 1, row.col),
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

test "live grep: typing runs the workspace grep, the rows carry their file, the preview centres on the hit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "src");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..80) |i| try text.appendSlice(t.allocator, if (i == 59) "    const needle = 1;\n" else "    // hay\n");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/a.zig", .data = text.items });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();

    try command.run(&app, .{ .static = .@"find.live_grep" });
    try t.expect(app.overlay == .picker);
    try t.expect(app.overlay.picker.kind == .grep);
    try t.expect(app.overlay.picker.state.has_preview);
    for ("needle") |c| try app.handle(.{ .key = Key.char(c) });
    // The debounce holds the run back until the pattern rests.
    try t.expect(app.grep_picker.requery_at_ms != null);
    try tick(&app, app.now_ms + debounce_ms + 1);
    // Drain the worker's batches.
    var spins: usize = 0;
    while (spins < 400) : (spins += 1) {
        try app.tick(App.nowMs(t.io));
        if (!app.grep_picker.loading) break;
        t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try t.expect(!app.grep_picker.loading);
    try t.expect(app.overlay.picker.labels.len > 0);
    const row = app.overlay.picker.grep_hits[0];
    try t.expectEqual(@as(u32, 60), row.line);
    try t.expect(std.mem.endsWith(u8, row.path, "src/a.zig"));
    try t.expect(std.mem.startsWith(u8, app.overlay.picker.labels[0], "src/a.zig:60"));
    // The preview is centred on the hit and the needle keeps its own ground.
    const p = &app.overlay.picker;
    try t.expect(p.preview.len > 0);
    const focus = p.state.preview_focus orelse return error.NoFocus;
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(t.allocator);
    for (p.preview[focus]) |seg| try joined.appendSlice(t.allocator, seg.text);
    try t.expect(std.mem.indexOf(u8, joined.items, "const needle = 1;") != null);
    try t.expect(std.mem.startsWith(u8, joined.items, "  60 "));
}
