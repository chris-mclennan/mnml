//! The jumplist: where the cursor was before a big jump, so `nav.back`
//! (vim `Ctrl+O`, standard `Ctrl+-`) returns there and `nav.forward`
//! (`Ctrl+I` / `Ctrl+Shift+-`) undoes that. Two stacks of `Point`s
//! (a file + row/col — a byte offset would go stale as the text
//! moves), each capped at 100.
//!
//! Push points: every key that moved the cursor three or more rows
//! within a file or into another file — `G`, `gg`, `{N}G`, `/` + `n`,
//! `%`, `:N`, `gd`, a mark, a `{` — recorded by `dispatch.key`'s
//! before/after snapshot (`snapshot` / `afterKey`), and a file opened
//! by `App.openEditor` while another was active. A jump made by
//! `nav.back` / `nav.forward` / `nav.jump_toggle_prev` is not a push:
//! `in_jump` is set for the key that made it. A vim jump motion
//! (`:help jump-motions`: `{N}G`, `gg`, `/` `?` `n` `N` `*` `#`, `%`,
//! `(` `)` `{` `}`, `H` `M` `L`, a mark) is a push at ANY distance that
//! changes the line — `jump_motion`, raised by whoever made it — so
//! `3G5G<C-o>` comes back to 3. `prev` is vim's `''` /
//! `` `` `` — the position before the last big jump, toggled by
//! `nav.jump_toggle_prev`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

pub const table = .{
    .@"nav.back" = &backCmd,
    .@"nav.forward" = &forwardCmd,
    .@"nav.jump_toggle_prev" = &togglePrevCmd,
};

/// Each stack keeps this many; the oldest goes first.
pub const cap: usize = 100;
/// A within-file move shorter than this is not a jump.
pub const row_threshold: usize = 3;

pub const Point = struct {
    /// Absolute. Owned.
    path: []u8,
    row: usize,
    col: usize,

    pub fn deinit(p: Point, gpa: Allocator) void {
        gpa.free(p.path);
    }

    pub fn samePlace(a: Point, b: Snapshot) bool {
        return a.row == b.row and a.col == b.col and std.mem.eql(u8, a.path, b.path);
    }
};

/// A borrowed point — the path lives on the frame arena.
pub const Snapshot = struct { path: []const u8, row: usize, col: usize };

pub const State = struct {
    back: std.ArrayListUnmanaged(Point) = .empty,
    forward: std.ArrayListUnmanaged(Point) = .empty,
    prev: ?Point = null,
    /// The key being handled is a back / forward / toggle jump itself.
    in_jump: bool = false,
    /// The key being handled made a jump motion: a push however near.
    jump_motion: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (self.back.items) |p| p.deinit(gpa);
        self.back.deinit(gpa);
        for (self.forward.items) |p| p.deinit(gpa);
        self.forward.deinit(gpa);
        if (self.prev) |p| p.deinit(gpa);
    }

    fn push(list: *std.ArrayListUnmanaged(Point), gpa: Allocator, s: Snapshot) Allocator.Error!void {
        if (list.items.len > 0 and list.items[list.items.len - 1].samePlace(s)) return;
        const owned = try gpa.dupe(u8, s.path);
        errdefer gpa.free(owned);
        try list.append(gpa, .{ .path = owned, .row = s.row, .col = s.col });
        while (list.items.len > cap) {
            const old = list.orderedRemove(0);
            old.deinit(gpa);
        }
    }

    fn clear(list: *std.ArrayListUnmanaged(Point), gpa: Allocator) void {
        for (list.items) |p| p.deinit(gpa);
        list.clearRetainingCapacity();
    }
};

/// The active editor's file + cursor, or null (no editor, no path).
/// Clears `in_jump`: a new key is starting.
pub fn snapshot(app: *App) Allocator.Error!?Snapshot {
    app.jumplist.in_jump = false;
    app.jumplist.jump_motion = false;
    return current(app);
}

/// As `snapshot`, without touching `in_jump`.
pub fn current(app: *App) Allocator.Error!?Snapshot {
    const e = app.activeEditor() orelse return null;
    const path = e.buf.doc.path orelse return null;
    const pos = e.buf.editor.rowCol();
    return .{ .path = try app.frame.allocator().dupe(u8, path), .row = pos.row, .col = pos.col };
}

/// After a key: a file switch or a move of `row_threshold`+ rows
/// records where the cursor was.
pub fn afterKey(app: *App, before: ?Snapshot) Allocator.Error!void {
    defer app.jumplist.in_jump = false;
    defer app.jumplist.jump_motion = false;
    const b = before orelse return;
    const a = (try current(app)) orelse return;
    const switched = !std.mem.eql(u8, a.path, b.path);
    const rows = if (a.row > b.row) a.row - b.row else b.row - a.row;
    const far = !switched and (rows >= row_threshold or (app.jumplist.jump_motion and rows > 0));
    if (switched or far) try record(app, b);
}

/// The key being handled made a vim jump motion (`afterKey` records it
/// whatever the distance).
pub fn noteJumpMotion(app: *App) void {
    app.jumplist.jump_motion = true;
}

/// `before` becomes the newest back entry (and `prev`); the forward
/// stack is wiped — any new jump ends the redo lane. Nothing while a
/// nav jump is in flight: those keep their own books.
pub fn record(app: *App, before: Snapshot) Allocator.Error!void {
    const st = &app.jumplist;
    if (st.in_jump) return;
    const gpa = app.gpa;
    if (st.prev) |p| p.deinit(gpa);
    st.prev = .{ .path = try gpa.dupe(u8, before.path), .row = before.row, .col = before.col };
    try State.push(&st.back, gpa, before);
    State.clear(&st.forward, gpa);
}

/// Open (or reveal) the point's file and put the cursor there. The
/// open bypasses the push `openEditor` would make.
fn jumpTo(app: *App, p: Point) CommandError!void {
    app.jumplist.in_jump = true;
    const id = app.openEditor(p.path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "nav: cannot open {s}: {s}", .{ app.relPath(p.path), @errorName(err) }),
    };
    const e = app.panes.editor(id) orelse return;
    e.buf.editor.placeCursor(@min(p.row, e.buf.editor.lineCount() - 1), p.col);
    app.focus = .{ .pane = id };
    app.needs_render = true;
}

fn backCmd(app: *App) CommandError!void {
    const st = &app.jumplist;
    const target = st.back.pop() orelse return app.diag.fail(app.frame.allocator(), "nothing to go back to", .{});
    defer target.deinit(app.gpa);
    if (try current(app)) |here| try State.push(&st.forward, app.gpa, here);
    try jumpTo(app, target);
}

fn forwardCmd(app: *App) CommandError!void {
    const st = &app.jumplist;
    const target = st.forward.pop() orelse return app.diag.fail(app.frame.allocator(), "nothing to go forward to", .{});
    defer target.deinit(app.gpa);
    if (try current(app)) |here| try State.push(&st.back, app.gpa, here);
    try jumpTo(app, target);
}

/// `''` / `` `` ``: swap places with the position before the last jump.
fn togglePrevCmd(app: *App) CommandError!void {
    const st = &app.jumplist;
    const target = st.prev orelse return app.diag.fail(app.frame.allocator(), "nothing to toggle to", .{});
    st.prev = null;
    defer target.deinit(app.gpa);
    if (try current(app)) |here| st.prev = .{ .path = try app.gpa.dupe(u8, here.path), .row = here.row, .col = here.col };
    try jumpTo(app, target);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

const Fixture = struct {
    app: App,
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b1\nb2\nb3\n" });
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        try app.setInputStyle(.vim);
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn open(f: *Fixture, rel: []const u8) !app_mod.PaneId {
        const path = try std.fs.path.join(f.app.frame.allocator(), &.{ f.root, rel });
        return f.app.openPath(path);
    }

    fn keys(f: *Fixture, s: []const u8) !void {
        for (s) |c| try f.app.handle(.{ .key = Key.char(c) });
    }

    fn row(f: *Fixture) usize {
        return f.app.activeEditor().?.buf.editor.currentLine();
    }

    fn file(f: *Fixture) []const u8 {
        return std.fs.path.basename(f.app.activeEditor().?.buf.doc.path.?);
    }
};

test "jumplist: G / gg / {N}G push; Ctrl+O walks back 7, 4, 1; Ctrl+I forward; a new jump wipes the redo lane" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.open("a.txt");
    // Rust mnml's rule, kept: a move of three or more rows is a jump
    // (`1G` → `3G` is two rows and is not one).
    try f.keys("4G");
    try f.keys("7G");
    try f.keys("12G");
    try t.expectEqual(@as(usize, 11), f.row());
    try t.expectEqual(@as(usize, 3), f.app.jumplist.back.items.len);
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqual(@as(usize, 6), f.row());
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqual(@as(usize, 3), f.row());
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqual(@as(usize, 0), f.row());
    // Nothing further back: the reason is toasted, the cursor stays.
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqual(@as(usize, 0), f.row());
    try t.expectEqualStrings("nothing to go back to", f.app.lastToast().?);
    try t.expectEqual(@as(usize, 3), f.app.jumplist.forward.items.len);
    try f.app.handle(.{ .key = Key.ctrl('i') });
    try t.expectEqual(@as(usize, 3), f.row());
    try f.app.handle(.{ .key = Key.ctrl('i') });
    try t.expectEqual(@as(usize, 6), f.row());
    // A fresh jump from here wipes the forward stack.
    try f.keys("gg");
    try t.expectEqual(@as(usize, 0), f.app.jumplist.forward.items.len);
    try t.expectEqual(@as(usize, 0), f.row());
    // `j` twice is not a jump.
    try f.keys("jj");
    const before = f.app.jumplist.back.items.len;
    try t.expectEqual(before, f.app.jumplist.back.items.len);
    try t.expectEqual(@as(usize, 2), f.row());
}

test "jumplist: `` toggles with the position before the last jump; a search hit is a jump" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.open("a.txt");
    try f.keys("9G");
    try f.keys("``");
    try t.expectEqual(@as(usize, 0), f.row());
    try f.keys("``");
    try t.expectEqual(@as(usize, 8), f.row());
    try f.keys("gg");
    // `/l7` + enter lands on line 7: six rows away, a jump.
    try f.keys("/l7");
    try f.app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(@as(usize, 6), f.row());
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqual(@as(usize, 0), f.row());
}

test "jumplist: opening another file pushes; nav.back returns to the file and row; the cap holds" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.open("a.txt");
    try f.keys("5G");
    _ = try f.open("b.txt");
    try t.expectEqualStrings("b.txt", f.file());
    try f.app.handle(.{ .key = Key.ctrl('o') });
    try t.expectEqualStrings("a.txt", f.file());
    try t.expectEqual(@as(usize, 4), f.row());
    try f.app.handle(.{ .key = Key.ctrl('i') });
    try t.expectEqualStrings("b.txt", f.file());
    // 150 jumps in a.txt keep the newest 100 — Neovim's number, spelled
    // out so a changed `cap` fails here rather than moving the bar.
    _ = try f.open("a.txt");
    var i: usize = 0;
    while (i < 150) : (i += 1) try f.keys(if (i % 2 == 0) "G" else "gg");
    try t.expectEqual(@as(usize, 100), f.app.jumplist.back.items.len);
}

test "jumplist: nav.back as a command (no key) does not record its own landing on the next key" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.open("a.txt");
    try f.keys("10G");
    try command.run(&f.app, .{ .static = .@"nav.back" });
    try t.expectEqual(@as(usize, 0), f.row());
    try t.expectEqual(@as(usize, 1), f.app.jumplist.forward.items.len);
    try f.keys("j");
    try t.expectEqual(@as(usize, 1), f.app.jumplist.forward.items.len);
    try command.run(&f.app, .{ .static = .@"nav.forward" });
    try t.expectEqual(@as(usize, 9), f.row());
}
