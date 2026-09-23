//! Autosave: `editor.autosave_secs` writes a dirty buffer to disk that
//! many seconds after its last change, and `editor.autosave_on_focus_loss`
//! writes every dirty buffer when the terminal loses focus. The write is
//! the ordinary save — its hooks, the trailing-newline and trim rules,
//! persistent undo — minus format-on-save: a formatter moving the text
//! under someone mid-sentence is not a save they asked for.
//!
//! A buffer's "last change" is its edit log's head: the tick notes when
//! it last moved and saves once it has stood still for the interval. A
//! scratch buffer (no path) and a read-only one are never written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const cmd_file = @import("cmd_file.zig");

const Seen = struct { version: u64, at_ms: i64 };

pub const State = struct {
    seen: std.AutoHashMapUnmanaged(PaneId, Seen) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.seen.deinit(gpa);
    }
};

/// A number that moves whenever the text does.
fn version(e: *const EditorPane) u64 {
    const log = &e.buf.doc.edits;
    return log.head() +% log.replaced_at +% log.lost_at;
}

fn wants(e: *const EditorPane) bool {
    return e.buf.doc.dirty and e.buf.doc.path != null and !e.buf.doc.read_only;
}

pub fn tick(app: *App, now: i64) void {
    const secs = app.cfg.editor.autosave_secs;
    if (secs == 0) {
        if (app.autosave.seen.count() > 0) app.autosave.seen.clearRetainingCapacity();
        return;
    }
    const interval: i64 = @as(i64, secs) * 1000;
    for (app.panes.slots.items, 0..) |*slot, i| {
        const p = &(slot.* orelse continue);
        if (p.* != .editor) continue;
        const e = &p.editor;
        const id: PaneId = @intCast(i);
        if (!wants(e)) {
            _ = app.autosave.seen.remove(id);
            continue;
        }
        const v = version(e);
        const gop = app.autosave.seen.getOrPut(app.gpa, id) catch return;
        if (!gop.found_existing or gop.value_ptr.version != v) {
            gop.value_ptr.* = .{ .version = v, .at_ms = now };
            continue;
        }
        if (now - gop.value_ptr.at_ms < interval) continue;
        _ = app.autosave.seen.remove(id);
        save(app, id, e);
    }
}

/// When `tick` has a buffer to write, for the loop to wake then.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const secs = app.cfg.editor.autosave_secs;
    if (secs == 0) return null;
    var next: ?i64 = null;
    var it = app.autosave.seen.valueIterator();
    while (it.next()) |s| {
        const due = s.at_ms + @as(i64, secs) * 1000;
        next = @min(next orelse due, due);
    }
    // A buffer that just went dirty is seen on the next tick; look again
    // within the interval so its clock starts.
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| if (p.* == .editor and wants(&p.editor) and !app.autosave.seen.contains(@intCast(i))) {
        const soon = app.now_ms + 250;
        next = @min(next orelse soon, soon);
    };
    return next;
}

/// The terminal lost focus: every dirty buffer with a file goes to disk.
pub fn onFocusLost(app: *App) void {
    if (!app.cfg.editor.autosave_on_focus_loss) return;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| if (p.* == .editor and wants(&p.editor)) {
        save(app, @intCast(i), &p.editor);
    };
}

fn save(app: *App, id: PaneId, e: *EditorPane) void {
    cmd_file.savePane(app, id, e, .{ .auto = true }) catch |err| switch (err) {
        // Said by the save itself (the toast names the file and why).
        else => {},
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "autosave: a dirty buffer is written once it has stood still for autosave_secs; off writes nothing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    const file = try std.fs.path.join(app.frame.allocator(), &.{ root, "a.txt" });
    const id = try app.openEditor(file);
    const e = app.panes.editor(id).?;
    try app.splice(e, 3, 3, " mine");
    e.buf.doc.recomputeDirty();
    try t.expect(e.buf.doc.dirty);
    // Off (the default): nothing, however long it waits.
    tick(&app, 0);
    tick(&app, 60_000);
    try t.expect(e.buf.doc.dirty);
    app.cfg.editor.autosave_secs = 2;
    tick(&app, 100_000); // noticed
    try t.expect(nextDeadlineMs(&app).? == 102_000);
    tick(&app, 101_000); // not yet
    try t.expect(e.buf.doc.dirty);
    // Another keystroke restarts the clock.
    try app.splice(e, 8, 8, "!");
    tick(&app, 101_500);
    tick(&app, 103_000);
    try t.expect(e.buf.doc.dirty);
    tick(&app, 103_500);
    try t.expect(!e.buf.doc.dirty);
    const on_disk = try tmp.dir.readFileAlloc(t.io, "a.txt", t.allocator, .limited(1024));
    defer t.allocator.free(on_disk);
    try t.expectEqualStrings("one mine!\n", on_disk);
}

test "autosave: focus loss writes every dirty buffer when autosave_on_focus_loss is on" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    const file = try std.fs.path.join(app.frame.allocator(), &.{ root, "b.txt" });
    const id = try app.openEditor(file);
    const e = app.panes.editor(id).?;
    try app.splice(e, 1, 1, "X");
    e.buf.doc.recomputeDirty();
    try app.handle(.{ .focus = false });
    try t.expect(e.buf.doc.dirty); // off by default
    app.cfg.editor.autosave_on_focus_loss = true;
    try app.handle(.{ .focus = false });
    try t.expect(!e.buf.doc.dirty);
}
