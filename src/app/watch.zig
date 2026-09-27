//! The file watcher: every 2 s each open file is stat'ed and compared
//! with the stamp taken when it was last read or written. A clean buffer
//! reloads in place (cursor row and scroll kept) with a `reloaded`
//! toast; a dirty one is left alone with a warning that names the way
//! out, and restamped so the warning fires once per change.
//!
//! No inotify / kqueue: a stat per open buffer every two seconds is
//! nothing, and it behaves the same on every platform.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const pane_mod = @import("pane.zig");
const hooks = @import("../core/hooks.zig");
const todos = @import("../todos.zig");

pub const interval_ms: i64 = 2000;

/// What is on disk for `path` right now, or null when it cannot be read.
pub const DiskStamp = pane_mod.DiskStamp;

pub fn stamp(io: Io, path: []const u8) ?pane_mod.DiskStamp {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.toNanoseconds(), .size = st.size };
}

/// Record the file as it is now — after a read or a write.
pub fn restamp(app: *App, e: *EditorPane) void {
    const path = e.buf.doc.path orelse {
        e.buf.doc.disk = null;
        return;
    };
    e.buf.doc.disk = stamp(app.io, path);
    if (e.buf.doc.disk != null) e.buf.doc.deleted = false;
}

/// `save_post` subscriber: the buffer just wrote the file.
pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    const e = app.panes.editor(args.save_post.pane) orelse return;
    restamp(app, e);
}

/// Every tick; does its work at most once per `interval_ms`.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    if (now - app.last_watch_ms < interval_ms) return;
    app.last_watch_ms = now;
    try check(app);
}

/// The 2 s pass, on demand.
pub fn check(app: *App) Allocator.Error!void {
    for (app.panes.slots.items, 0..) |*slot, i| {
        const pane = &(slot.* orelse continue);
        const e = pane.asEditor() orelse continue;
        const path = e.buf.doc.path orelse continue;
        const known = e.buf.doc.disk orelse continue;
        const now_on_disk = stamp(app.io, path) orelse {
            // Gone: said once, and the buffer keeps every byte — a save
            // writes the file back (vim's E211, VS Code's "(deleted)").
            if (!e.buf.doc.deleted) {
                e.buf.doc.deleted = true;
                try app.toastLevel(.warn, "{s} was deleted on disk — the buffer keeps it; save to write it back", .{app.relPath(path)});
                app.needs_render = true;
            }
            continue;
        };
        if (e.buf.doc.deleted) {
            // Back (a checkout, an undo in another tool): a change like any.
            e.buf.doc.deleted = false;
            app.needs_render = true;
        }
        if (now_on_disk.mtime_ns == known.mtime_ns and now_on_disk.size == known.size) continue;
        // The change event: the TODOS panel queues a debounced rescan
        // whether the buffer reloads or is left dirty — the disk moved.
        todos.noteFileChanged(app);
        const rel = app.relPath(path);
        if (e.buf.doc.dirty) {
            if (app.input_style == .vim)
                app.toast("{s} changed on disk — :e! to discard / save to overwrite", .{rel})
            else
                app.toast("{s} changed on disk — Save overwrites it; close without saving to take the disk's version", .{rel});
            e.buf.doc.disk = now_on_disk;
            continue;
        }
        reload(app, @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.toast("{s}: reload failed: {s}", .{ rel, @errorName(err) });
                e.buf.doc.disk = now_on_disk;
                continue;
            },
        };
        app.toast("{s} reloaded", .{rel});
    }
    try checkDirs(app);
}

/// The listings: a Files pane whose directory's mtime moved re-reads
/// (an entry added, removed or renamed outside mnml — git checkout, a
/// build, another editor), and the tree refreshes when any directory
/// it lists did. The 2 s pass is the debounce; a burst of writes is
/// one re-read.
fn checkDirs(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .files => |*f| if (f.dir_stamp) |known| {
            const now_st = stamp(app.io, f.cwd) orelse continue;
            if (now_st.mtime_ns == known.mtime_ns) continue;
            try f.reload(app.io);
            app.needs_render = true;
        },
        else => {},
    };
    if (app.tree.loaded and app.tree.dirsChanged(app.io)) {
        try app.tree.refresh(app);
        app.needs_render = true;
    }
}

pub const ReloadError = Allocator.Error || Io.Dir.ReadFileAllocError || error{NoPath};

/// Replace the buffer's text with the file's, as one undo step, keeping
/// the cursor's row and the scroll where they were. Marks the buffer
/// clean and restamps it. `:e!` and the watcher both come through here.
pub fn reload(app: *App, id: PaneId) ReloadError!void {
    const e = app.panes.editor(id) orelse return error.NoPath;
    const path = e.buf.doc.path orelse return error.NoPath;
    const text = try Io.Dir.cwd().readFileAlloc(app.io, path, app.frame.allocator(), .limited(1 << 30));
    const ed = e.buf.editor;
    const row = ed.currentLine();
    const scroll = e.view.scroll_line;
    // The other windows on the document keep their row too; the splice
    // would land them on byte 0.
    const others = e.buf.doc.views.items;
    const rows = try app.frame.allocator().alloc(usize, others.len);
    for (others, 0..) |v, i| rows[i] = v.currentLine();
    try app.splice(e, 0, ed.len(), text);
    try e.buf.markSaved();
    const last = ed.lineCount() -| 1;
    for (others, 0..) |v, i| if (v != ed) v.placeCursor(@min(rows[i], last), 0);
    ed.placeCursor(@min(row, last), 0);
    e.view.scroll_line = @intCast(@min(@as(usize, scroll), last));
    e.syntax.dirty = true;
    restamp(app, e);
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        const app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 60, .rows = 12 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn open(f: *Fixture, rel: []const u8) !PaneId {
        const abs = try std.fs.path.join(t.allocator, &.{ f.root, rel });
        defer t.allocator.free(abs);
        return f.app.openPath(abs);
    }
};

test "a clean buffer reloads when the file changes on disk; the cursor row survives; a dirty one is warned once" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "one\ntwo\nthree\n" });
    const id = try f.open("notes.txt");
    const e = f.app.panes.editor(id).?;
    try t.expect(e.buf.doc.disk != null);
    e.buf.editor.placeCursor(2, 0);
    // Nothing changed: no toast.
    f.app.last_watch_ms = 0;
    try tick(&f.app, interval_ms);
    try t.expect(f.app.lastToast() == null);
    // The size changes, so the stamp differs whatever the mtime granularity.
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "one\ntwo\nthree\nfour\nfive\n" });
    try tick(&f.app, interval_ms + 100); // within the interval: not yet
    try t.expect(f.app.lastToast() == null);
    try tick(&f.app, 2 * interval_ms);
    try t.expectEqualStrings("notes.txt reloaded", f.app.lastToast().?);
    try t.expectEqualStrings("one\ntwo\nthree\nfour\nfive\n", e.buf.editor.bytes());
    try t.expect(!e.buf.doc.dirty);
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    // Dirty: warned, not reloaded, and only once for this change.
    _ = try f.app.applyOps(e, &.{.{ .insert_str = "EDIT " }});
    try t.expect(e.buf.doc.dirty);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "changed again\n" });
    f.app.dismissToasts();
    try tick(&f.app, 3 * interval_ms);
    try t.expectEqualStrings("notes.txt changed on disk — Save overwrites it; close without saving to take the disk's version", f.app.lastToast().?);
    try t.expect(std.mem.indexOf(u8, e.buf.editor.bytes(), "EDIT") != null);
    f.app.dismissToasts();
    try tick(&f.app, 4 * interval_ms);
    try t.expect(f.app.lastToast() == null);
    // :e! discards and takes the disk's text.
    try f.app.runEx("e!");
    try t.expectEqualStrings("changed again\n", e.buf.editor.bytes());
    try t.expect(!e.buf.doc.dirty);
}

test "a Files pane and the tree re-read when a file appears in their directory outside mnml" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try @import("../core/command.zig").run(&f.app, .{ .static = .@"files.open" });
    try f.app.tree.refresh(&f.app);
    const files = &f.app.panes.get(f.app.active.?).?.files;
    try t.expectEqual(@as(usize, 1), files.count());
    try t.expect(files.dir_stamp != null);
    try t.expect(f.app.tree.dir_stamps.count() >= 1);
    const rows_before = f.app.tree.rows.items.len;
    // Nothing changed: the pass is quiet.
    f.app.last_watch_ms = 0;
    try tick(&f.app, interval_ms);
    try t.expectEqual(@as(usize, 1), files.count());
    // A file lands from outside; the directory's mtime moves. A
    // same-nanosecond stamp is the one thing this cannot see, so the
    // stamp is nudged back to stand for "read earlier".
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "zzz-external.txt", .data = "" });
    files.dir_stamp.?.mtime_ns -= 1;
    var it = f.app.tree.dir_stamps.valueIterator();
    while (it.next()) |v| v.mtime_ns -= 1;
    try tick(&f.app, 2 * interval_ms);
    try t.expectEqual(@as(usize, 2), files.count());
    try t.expect(f.app.tree.rows.items.len > rows_before);
    try t.expect(f.app.tree.rowOf("zzz-external.txt") != null);
}

test "a save restamps the file so the writer's own change is not reported" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "x\n" });
    const id = try f.open("a.txt");
    const e = f.app.panes.editor(id).?;
    _ = try f.app.applyOps(e, &.{.{ .insert_str = "more text " }});
    try f.app.runEx("w");
    try t.expect(!e.buf.doc.dirty);
    f.app.dismissToasts();
    try tick(&f.app, 10 * interval_ms);
    try t.expect(f.app.lastToast() == null);
}

test "a change on disk queues the TODOS rescan (a used panel only)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "x\n" });
    _ = try f.open("a.txt");
    f.app.todos.scanned_once = true;
    f.app.now_ms = 10 * interval_ms;
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "x and more\n" });
    try tick(&f.app, 10 * interval_ms);
    try t.expectEqual(@as(?i64, 10 * interval_ms + todos.rescan_debounce_ms), f.app.todos.rescan_at_ms);
}
