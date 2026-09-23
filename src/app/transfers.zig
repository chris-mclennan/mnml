//! Background file transfers — copy and move with progress, on a
//! worker in one `Io.Group`, reporting through the event queue as
//! `.transfer` payloads. Nothing bulk ever runs on the UI thread: a
//! 4 KB paste and a 4 GB one take the same path, so the editor cannot
//! freeze and the big one is cancellable.
//!
//! Cancellation is a flag the worker checks between files, so a single
//! enormous file still finishes — stopping mid-file would leave a
//! truncated destination that looks complete. A cancel or a failure
//! removes what THIS transfer created (recorded per entry as it is
//! made, only when it was not already there, so cancelling a paste
//! over an existing name never deletes the user's original). A move
//! removes its source only on a genuine full completion.
//!
//! The statusline chip is aggregate and hidden at rest: `⇄ 42% 3.1M/s`.
//! `transfer.cancel_all` stops every one; `quitGuard` refuses a quit
//! while one runs — `app.quit` (Ctrl+Q, the palette) and `:qa` both ask
//! it — and `:qa!` overrides.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const files_pane = @import("files_pane.zig");
const files_view = @import("../ui/files_view.zig");
const tree_mod = @import("tree.zig");

pub const table = .{
    .@"transfer.cancel_all" = &cancelAllCmd,
};

pub const Kind = enum {
    copy,
    move,

    pub fn verb(k: Kind) []const u8 {
        return switch (k) {
            .copy => "copy",
            .move => "move",
        };
    }
};

/// One (source, destination) pair, both absolute. Borrowed by `start`,
/// which makes the worker its own copies.
pub const Item = struct { src: []const u8, dst: []const u8 };

pub const Msg = union(enum) {
    /// Sizing is over; progress means something from here.
    total: struct { bytes: u64, files: u64 },
    progress: struct { bytes: u64, files: u64 },
    done: struct { skipped: u64 },
    /// gpa-owned by the event.
    failed: []u8,
    cancelled,
};

/// What the worker posts. Owned by the event; `handle` destroys it.
pub const Event = struct {
    id: u64,
    msg: Msg,

    pub fn create(gpa: Allocator, id: u64, msg: Msg) Allocator.Error!*Event {
        const e = try gpa.create(Event);
        e.* = .{ .id = id, .msg = msg };
        return e;
    }

    pub fn destroy(self: *Event, gpa: Allocator) void {
        switch (self.msg) {
            .failed => |m| gpa.free(m),
            else => {},
        }
        gpa.destroy(self);
    }
};

pub const Flag = std.atomic.Value(bool);

/// A transfer the UI knows about, from `start` until its terminal
/// message is reported.
pub const Job = struct {
    id: u64,
    kind: Kind,
    /// The common parent of every destination — what a later paste is
    /// checked against. Owned.
    dest: []u8,
    bytes_total: u64 = 0,
    bytes_done: u64 = 0,
    files_total: u64 = 0,
    files_done: u64 = 0,
    sizing: bool = true,
    started_ms: i64,
    /// Heap so the worker can read it after `jobs` reallocates; freed
    /// when the job is retired, after the worker's last message.
    cancel: *Flag,
    /// A move's sources and destinations (owned): when it lands, the
    /// buffers open on a source follow it. Empty for a copy.
    moves: []Item = &.{},

    fn freeMoves(j: *const Job, gpa: Allocator) void {
        for (j.moves) |it| {
            gpa.free(it.src);
            gpa.free(it.dst);
        }
        gpa.free(j.moves);
    }

    pub fn percent(j: *const Job) u8 {
        if (j.bytes_total == 0) return 0;
        return @intCast(@min(100, j.bytes_done * 100 / j.bytes_total));
    }

    /// Bytes per second, or null before there is enough signal — a
    /// speed read over the first milliseconds is noise.
    pub fn speed(j: *const Job, now_ms: i64) ?u64 {
        const elapsed = now_ms - j.started_ms;
        if (elapsed < 250 or j.bytes_done == 0) return null;
        return j.bytes_done * 1000 / @as(u64, @intCast(elapsed));
    }
};

pub const State = struct {
    group: Io.Group = .init,
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    next_id: u64 = 1,

    /// Cancels every worker and waits: they post into `app.events`,
    /// which must outlive them.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        for (self.jobs.items) |j| j.cancel.store(true, .release);
        self.group.cancel(io);
        for (self.jobs.items) |j| {
            gpa.free(j.dest);
            gpa.destroy(j.cancel);
            j.freeMoves(gpa);
        }
        self.jobs.deinit(gpa);
    }
};

// ─── starting one ───────────────────────────────────────────────────────

/// What the worker owns: its items and where to report.
const Work = struct {
    gpa: Allocator,
    id: u64,
    kind: Kind,
    items: []Item,
    cancel: *Flag,

    fn destroy(w: *Work) void {
        const gpa = w.gpa;
        for (w.items) |it| {
            gpa.free(it.src);
            gpa.free(it.dst);
        }
        gpa.free(w.items);
        gpa.destroy(w);
    }
};

/// Start a transfer of `items`; returns its id. The worker runs from
/// here; the listing refreshes when it reports done.
pub fn start(app: *App, kind: Kind, items: []const Item) CommandError!u64 {
    const gpa = app.gpa;
    const st = &app.transfers;
    const work = try gpa.create(Work);
    errdefer gpa.destroy(work);
    work.* = .{ .gpa = gpa, .id = st.next_id, .kind = kind, .items = &.{}, .cancel = undefined };
    const owned = try gpa.alloc(Item, items.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |it| {
            gpa.free(it.src);
            gpa.free(it.dst);
        }
        gpa.free(owned);
    }
    for (items) |it| {
        const src = try gpa.dupe(u8, it.src);
        errdefer gpa.free(src);
        const dst = try gpa.dupe(u8, it.dst);
        owned[n] = .{ .src = src, .dst = dst };
        n += 1;
    }
    work.items = owned;
    const flag = try gpa.create(Flag);
    errdefer gpa.destroy(flag);
    flag.* = Flag.init(false);
    work.cancel = flag;
    const dest = try gpa.dupe(u8, commonAncestor(items));
    errdefer gpa.free(dest);
    var moves: []Item = &.{};
    if (kind == .move) {
        moves = try gpa.alloc(Item, items.len);
        @memset(moves, .{ .src = &.{}, .dst = &.{} });
    }
    errdefer (Job{ .id = 0, .kind = kind, .dest = &.{}, .started_ms = 0, .cancel = flag, .moves = moves }).freeMoves(gpa);
    if (kind == .move) for (moves, items) |*m, it| {
        m.* = .{ .src = try gpa.dupe(u8, it.src), .dst = try gpa.dupe(u8, it.dst) };
    };
    try st.jobs.append(gpa, .{ .id = st.next_id, .kind = kind, .dest = dest, .started_ms = app.now_ms, .cancel = flag, .moves = moves });
    errdefer _ = st.jobs.pop();
    st.group.concurrent(app.io, worker, .{ &app.events, app.io, work }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "transfer: could not start the worker: {s}", .{@errorName(err)});
    };
    const id = st.next_id;
    st.next_id += 1;
    app.needs_render = true;
    return id;
}

/// The longest shared prefix of every destination, by path segment.
fn commonAncestor(items: []const Item) []const u8 {
    if (items.len == 0) return "";
    var acc: []const u8 = items[0].dst;
    for (items[1..]) |it| {
        var n: usize = 0;
        const lim = @min(acc.len, it.dst.len);
        while (n < lim and acc[n] == it.dst[n]) n += 1;
        // Back up to a segment boundary.
        while (n > 0 and (n == acc.len or acc[n] != '/') and (n == it.dst.len or it.dst[n] != '/')) n -= 1;
        acc = acc[0..n];
    }
    return if (acc.len == 0) "/" else acc;
}

/// The first destination a running transfer is already writing (the
/// same tree, or one inside the other), if any. A second paste passed
/// the `exists` check before the first worker had created anything.
pub fn clash(app: *App, items: []const Item) ?[]const u8 {
    for (items) |it| for (app.transfers.jobs.items) |j| {
        if (std.mem.eql(u8, it.dst, j.dest) or under(it.dst, j.dest) or under(j.dest, it.dst)) return it.dst;
    };
    return null;
}

fn under(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return true;
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
}

// ─── the worker ─────────────────────────────────────────────────────────

const WorkError = Io.Cancelable || Allocator.Error || error{Stopped};

const Reporter = struct {
    events: *event.EventQueue,
    io: Io,
    gpa: Allocator,
    id: u64,
    bytes: u64 = 0,
    files: u64 = 0,
    since_post: u64 = 0,

    /// Progress, at most every 32 files — the UI needs a signal, not a
    /// message per byte.
    fn credit(r: *Reporter, bytes: u64, files: u64, force: bool) void {
        r.bytes += bytes;
        r.files += files;
        r.since_post += files;
        if (force or r.since_post >= 32) {
            r.since_post = 0;
            r.post(.{ .progress = .{ .bytes = r.bytes, .files = r.files } });
        }
    }

    fn post(r: *Reporter, msg: Msg) void {
        const ev = Event.create(r.gpa, r.id, msg) catch return;
        r.events.post(r.io, .{ .transfer = ev });
    }
};

fn worker(events: *event.EventQueue, io: Io, work: *Work) Io.Cancelable!void {
    defer work.destroy();
    const gpa = work.gpa;
    var rep: Reporter = .{ .events = events, .io = io, .gpa = gpa, .id = work.id };
    // Sizing: per source, so a rename can credit exactly its own size.
    const per_source = gpa.alloc(u64, work.items.len) catch return;
    defer gpa.free(per_source);
    var bytes_total: u64 = 0;
    var files_total: u64 = 0;
    for (work.items, 0..) |it, i| {
        const m = try measure(io, gpa, it.src, work.cancel);
        per_source[i] = m.bytes;
        bytes_total += m.bytes;
        files_total += m.files;
    }
    rep.post(.{ .total = .{ .bytes = bytes_total, .files = files_total } });

    var created: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (created.items) |c| gpa.free(c);
        created.deinit(gpa);
    }
    var skipped: u64 = 0;
    for (work.items, 0..) |it, i| {
        if (work.cancel.load(.acquire)) return finishCancelled(io, &rep, created.items);
        const existed = exists(io, it.dst);
        // A move within one filesystem is a rename: nothing crosses the disk.
        if (work.kind == .move) {
            if (Io.Dir.renameAbsolute(it.src, it.dst, io)) {
                if (!existed) created.append(gpa, gpa.dupe(u8, it.dst) catch continue) catch {};
                rep.credit(per_source[i], countFilesQuick(io, gpa, it.dst), true);
                continue;
            } else |err| if (err == error.Canceled) return error.Canceled;
        }
        copyTree(io, gpa, it.src, it.dst, &rep, work.cancel, &created, &skipped) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return failWith(io, gpa, &rep, created.items, "out of memory"),
            error.Stopped => return finishCancelled(io, &rep, created.items),
            else => return failWith(io, gpa, &rep, created.items, @errorName(err)),
        };
        if (work.kind == .move) {
            removePath(io, it.src) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return failWith(io, gpa, &rep, created.items, @errorName(err));
            };
        }
    }
    if (work.cancel.load(.acquire)) return finishCancelled(io, &rep, created.items);
    rep.credit(0, 0, true);
    rep.post(.{ .done = .{ .skipped = skipped } });
}

fn finishCancelled(io: Io, rep: *Reporter, created: []const []u8) void {
    cleanup(io, created);
    rep.post(.cancelled);
}

fn failWith(io: Io, gpa: Allocator, rep: *Reporter, created: []const []u8, why: []const u8) void {
    cleanup(io, created);
    const msg = gpa.dupe(u8, why) catch return;
    rep.post(.{ .failed = msg });
}

/// Remove what this transfer created, youngest first — a directory is
/// recorded before what was written into it.
fn cleanup(io: Io, created: []const []u8) void {
    var i = created.len;
    while (i > 0) {
        i -= 1;
        removePath(io, created[i]) catch {};
    }
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn removePath(io: Io, path: []const u8) !void {
    const st = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (st.kind == .directory) return Io.Dir.cwd().deleteTree(io, path);
    return Io.Dir.cwd().deleteFile(io, path);
}

const Measure = struct { bytes: u64, files: u64 };

/// Bytes and files under `path`; symlinks count as one file of their
/// own and are never followed.
pub fn measure(io: Io, gpa: Allocator, path: []const u8, cancel: *Flag) Io.Cancelable!Measure {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return .{ .bytes = 0, .files = 0 };
    };
    if (st.kind != .directory) return .{ .bytes = st.size, .files = 1 };
    var root = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return .{ .bytes = 0, .files = 0 };
    };
    defer root.close(io);
    var walker = root.walk(gpa) catch return .{ .bytes = 0, .files = 0 };
    defer walker.deinit();
    var out: Measure = .{ .bytes = 0, .files = 0 };
    while (true) {
        if (cancel.load(.acquire)) break;
        const entry = walker.next(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        } orelse break;
        if (entry.kind == .directory) continue;
        const s = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        out.bytes += s.size;
        out.files += 1;
    }
    return out;
}

fn countFilesQuick(io: Io, gpa: Allocator, path: []const u8) u64 {
    var flag = Flag.init(false);
    const m = measure(io, gpa, path, &flag) catch return 0;
    return m.files;
}

/// Copy `src` to `dst` (a file, or a tree entry by entry), crediting
/// bytes as each file lands. `error.Stopped` is a cancel between files.
fn copyTree(io: Io, gpa: Allocator, src: []const u8, dst: []const u8, rep: *Reporter, cancel: *Flag, created: *std.ArrayListUnmanaged([]u8), skipped: *u64) !void {
    if (cancel.load(.acquire)) return error.Stopped;
    const st = Io.Dir.cwd().statFile(io, src, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        skipped.* += 1;
        return;
    };
    switch (st.kind) {
        .directory => {
            const existed = exists(io, dst);
            try Io.Dir.cwd().createDirPath(io, dst);
            if (!existed) try created.append(gpa, try gpa.dupe(u8, dst));
            var d = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
            defer d.close(io);
            var names: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (names.items) |nm| gpa.free(nm);
                names.deinit(gpa);
            }
            var it = d.iterate();
            while (true) {
                const ent = it.next(io) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    break;
                } orelse break;
                try names.append(gpa, try gpa.dupe(u8, ent.name));
            }
            for (names.items) |nm| {
                const child_src = try std.fs.path.join(gpa, &.{ src, nm });
                defer gpa.free(child_src);
                const child_dst = try std.fs.path.join(gpa, &.{ dst, nm });
                defer gpa.free(child_dst);
                try copyTree(io, gpa, child_src, child_dst, rep, cancel, created, skipped);
            }
        },
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().readLink(io, src, &buf) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                skipped.* += 1;
                return;
            };
            const existed = exists(io, dst);
            Io.Dir.cwd().symLink(io, buf[0..n], dst, .{}) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                skipped.* += 1;
                return;
            };
            if (!existed) try created.append(gpa, try gpa.dupe(u8, dst));
            rep.credit(st.size, 1, false);
        },
        else => {
            const existed = exists(io, dst);
            Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dst, io, .{}) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return err;
            };
            if (!existed) try created.append(gpa, try gpa.dupe(u8, dst));
            rep.credit(st.size, 1, false);
        },
    }
}

// ─── the handler (UI thread) ────────────────────────────────────────────

/// D1: the event is ours to destroy on every path. A finished transfer
/// toasts, refreshes the tree and every Files pane, and is retired —
/// the chip shows what runs, not a history.
pub fn handle(app: *App, ev: *Event) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const st = &app.transfers;
    app.needs_render = true;
    const idx = for (st.jobs.items, 0..) |j, i| {
        if (j.id == ev.id) break i;
    } else return;
    const j = &st.jobs.items[idx];
    switch (ev.msg) {
        .total => |tot| {
            j.bytes_total = tot.bytes;
            j.files_total = tot.files;
            j.sizing = false;
        },
        .progress => |p| {
            j.bytes_done = p.bytes;
            j.files_done = p.files;
        },
        .done => |d| {
            const files = j.files_done;
            // The moved files' buffers follow them — or the next save
            // re-creates the old path beside the moved file.
            for (j.moves) |m| try tree_mod.retargetBuffers(app, m.src, m.dst);
            if (d.skipped > 0) {
                app.toast("{s} finished — {d} item{s}, {d} skipped", .{ j.kind.verb(), files, if (files == 1) "" else "s", d.skipped });
            } else {
                app.toast("{s} finished — {d} item{s}", .{ j.kind.verb(), files, if (files == 1) "" else "s" });
            }
            retire(app, idx);
            try files_pane.refreshAfterFsChange(app);
        },
        .failed => |why| {
            app.toast("{s} failed: {s}", .{ j.kind.verb(), why });
            retire(app, idx);
            try files_pane.refreshAfterFsChange(app);
        },
        .cancelled => {
            app.toast("{s} cancelled", .{j.kind.verb()});
            retire(app, idx);
            try files_pane.refreshAfterFsChange(app);
        },
    }
}

fn retire(app: *App, idx: usize) void {
    const j = app.transfers.jobs.orderedRemove(idx);
    app.gpa.free(j.dest);
    app.gpa.destroy(j.cancel);
    j.freeMoves(app.gpa);
}

pub fn running(app: *App) usize {
    return app.transfers.jobs.items.len;
}

/// The quit guard: a quit kills the workers mid-copy and leaves a
/// half-written destination behind; an explicit cancel promises a
/// cleanup, a quit cannot. Every quit path asks here (`force` is
/// `:qa!`), so the standard profile's Ctrl+Q refuses like `:qa` does.
pub fn quitGuard(app: *App, force: bool) CommandError!void {
    const n = running(app);
    if (force or n == 0) return;
    return app.diag.fail(app.frame.allocator(), "{d} transfer(s) still running — transfer.cancel_all, or :qa! to quit anyway", .{n});
}

/// Raise every worker's flag. Returns how many were told.
pub fn cancelAll(app: *App) usize {
    var n: usize = 0;
    for (app.transfers.jobs.items) |j| {
        j.cancel.store(true, .release);
        n += 1;
    }
    return n;
}

fn cancelAllCmd(app: *App) CommandError!void {
    const n = cancelAll(app);
    if (n == 0) return app.diag.fail(app.frame.allocator(), "no transfer is running", .{});
    app.toast("cancelling {d} transfer{s}", .{ n, if (n == 1) "" else "s" });
}

/// The statusline chip, or null at rest. Aggregate over every running
/// transfer; a constant-ish width so the right lane does not slide.
pub fn chip(app: *App, arena: Allocator, ascii: bool) Allocator.Error!?[]const u8 {
    const jobs = app.transfers.jobs.items;
    if (jobs.len == 0) return null;
    var done: u64 = 0;
    var total: u64 = 0;
    var speed: u64 = 0;
    var sizing = true;
    for (jobs) |j| {
        done += j.bytes_done;
        total += j.bytes_total;
        if (j.speed(app.now_ms)) |s| speed += s;
        if (!j.sizing) sizing = false;
    }
    const glyph: []const u8 = if (ascii) "<>" else "⇄";
    const prefix = if (jobs.len > 1) try std.fmt.allocPrint(arena, "{s}{d} ", .{ glyph, jobs.len }) else try std.fmt.allocPrint(arena, "{s} ", .{glyph});
    if (sizing) return try std.fmt.allocPrint(arena, "{s}sizing…", .{prefix});
    const pct: u64 = if (total == 0) 0 else @min(100, done * 100 / total);
    if (speed > 0) return try std.fmt.allocPrint(arena, "{s}{d}% {s}/s", .{ prefix, pct, files_view.humanBytes(arena, speed) });
    return try std.fmt.allocPrint(arena, "{s}{d}%", .{ prefix, pct });
}

/// While anything runs the chip animates: a frame every 80 ms.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    if (app.transfers.jobs.items.len == 0) return null;
    return app.now_ms + 80;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

fn settle(app: *App, max_ticks: usize) !void {
    var i: usize = 0;
    while (running(app) > 0 and i < max_ticks) : (i += 1) {
        try app.tick(app.now_ms + 5);
        app.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
}

fn seedTree(tmp: *std.testing.TmpDir, files: usize) !void {
    try tmp.dir.createDirPath(t.io, "big/nested/deeper");
    var i: usize = 0;
    var name_buf: [64]u8 = undefined;
    while (i < files) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "big/nested/f{d}.bin", .{i});
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "x" ** 512 });
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big/nested/deeper/leaf.txt", .data = "leaf" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big/top.txt", .data = "top" });
}

test "a copy of a tree lands whole, reports its totals, toasts once, and is retired; the chip reads at rest" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try seedTree(&tmp, 40);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try t.expect((try chip(&app, app.frame.allocator(), false)) == null);
    const src = try std.fs.path.join(t.allocator, &.{ root, "big" });
    defer t.allocator.free(src);
    const dst = try std.fs.path.join(t.allocator, &.{ root, "copy" });
    defer t.allocator.free(dst);
    const started = app.now_ms;
    const id = try start(&app, .copy, &.{.{ .src = src, .dst = dst }});
    // Starting returned at once: the copy is not on this thread.
    try t.expect(app.now_ms - started < 200);
    try t.expectEqual(@as(usize, 1), running(&app));
    // The same destination is a clash while it runs; a sibling is not.
    try t.expect(clash(&app, &.{.{ .src = src, .dst = dst }}) != null);
    const inside = try std.fs.path.join(t.allocator, &.{ dst, "nested", "x" });
    defer t.allocator.free(inside);
    try t.expect(clash(&app, &.{.{ .src = src, .dst = inside }}) != null);
    const other = try std.fs.path.join(t.allocator, &.{ root, "elsewhere" });
    defer t.allocator.free(other);
    try t.expect(clash(&app, &.{.{ .src = src, .dst = other }}) == null);
    try settle(&app, 4000);
    try t.expectEqual(@as(usize, 0), running(&app));
    const leaf = try tmp.dir.readFileAlloc(t.io, "copy/nested/deeper/leaf.txt", t.allocator, .limited(8));
    defer t.allocator.free(leaf);
    try t.expectEqualStrings("leaf", leaf);
    const f39 = try tmp.dir.readFileAlloc(t.io, "copy/nested/f39.bin", t.allocator, .limited(1024));
    defer t.allocator.free(f39);
    try t.expectEqual(@as(usize, 512), f39.len);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "copy finished — 42 items") != null);
    try t.expect(id >= 1);
    // The source is untouched by a copy.
    try tmp.dir.access(t.io, "big/top.txt", .{});
}

test "a move within one filesystem renames; cancel_all stops a copy between files and removes what it made" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try seedTree(&tmp, 300);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const src = try std.fs.path.join(t.allocator, &.{ root, "big" });
    defer t.allocator.free(src);
    const moved = try std.fs.path.join(t.allocator, &.{ root, "moved" });
    defer t.allocator.free(moved);
    _ = try start(&app, .move, &.{.{ .src = src, .dst = moved }});
    try settle(&app, 4000);
    try t.expectEqual(@as(usize, 0), running(&app));
    try tmp.dir.access(t.io, "moved/top.txt", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "big", .{}));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "move finished") != null);
    // Copy it back, cancel straight away: the worker stops between files
    // and the partial destination is cleaned up.
    const back = try std.fs.path.join(t.allocator, &.{ root, "back" });
    defer t.allocator.free(back);
    _ = try start(&app, .copy, &.{.{ .src = moved, .dst = back }});
    try t.expectEqual(@as(usize, 1), cancelAll(&app));
    try settle(&app, 4000);
    try t.expectEqual(@as(usize, 0), running(&app));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "cancelled") != null);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "back", .{}));
    try tmp.dir.access(t.io, "moved/top.txt", .{});
    // Nothing running: the command says so.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"transfer.cancel_all" }));
}

test "a move that lands takes the open buffers with it — a file, and a file inside a moved folder" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "dest");
    try tmp.dir.createDirPath(t.io, "lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "orig" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lib/b.txt", .data = "b" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "lib", "b.txt" });
    defer t.allocator.free(b);
    _ = try app.openPath(a);
    const ida = app.active.?;
    _ = try app.applyOps(app.activeEditor().?, &.{.{ .insert_str = "EDIT" }});
    _ = try app.openPath(b);
    const idb = app.active.?;
    const a_dst = try std.fs.path.join(t.allocator, &.{ root, "dest", "a.txt" });
    defer t.allocator.free(a_dst);
    const lib = try std.fs.path.join(t.allocator, &.{ root, "lib" });
    defer t.allocator.free(lib);
    const lib_dst = try std.fs.path.join(t.allocator, &.{ root, "dest", "lib" });
    defer t.allocator.free(lib_dst);
    _ = try start(&app, .move, &.{ .{ .src = a, .dst = a_dst }, .{ .src = lib, .dst = lib_dst } });
    try settle(&app, 4000);
    const ea = app.panes.editor(ida).?;
    const eb = app.panes.editor(idb).?;
    try t.expectEqualStrings(a_dst, ea.buf.doc.path.?);
    const b_dst = try std.fs.path.join(t.allocator, &.{ lib_dst, "b.txt" });
    defer t.allocator.free(b_dst);
    try t.expectEqualStrings(b_dst, eb.buf.doc.path.?);
    // The save lands on the moved file; the old path stays gone.
    try ea.buf.save(t.io);
    var got: [16]u8 = undefined;
    try t.expectEqualStrings("EDITorig\n", try tmp.dir.readFile(t.io, "dest/a.txt", &got));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "a.txt", .{}));
}

test ":qa refuses while a transfer runs and :qa! overrides; the chip shows progress" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try seedTree(&tmp, 400);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const src = try std.fs.path.join(t.allocator, &.{ root, "big" });
    defer t.allocator.free(src);
    const dst = try std.fs.path.join(t.allocator, &.{ root, "out" });
    defer t.allocator.free(dst);
    _ = try start(&app, .copy, &.{.{ .src = src, .dst = dst }});
    try t.expectError(error.Failed, app.runEx("qa"));
    try t.expect(!app.quit);
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "transfer") != null);
    try t.expect((try chip(&app, app.frame.allocator(), false)) != null);
    try t.expect((try chip(&app, app.frame.allocator(), true)).?[0] == '<');
    try app.runEx("qa!");
    try t.expect(app.quit);
    app.quit = false;
    _ = cancelAll(&app);
    try settle(&app, 4000);
    try t.expectEqual(@as(usize, 0), running(&app));
}

test "app.quit refuses while a transfer runs, like :qa; the discard box never opens over it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try seedTree(&tmp, 400);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const src = try std.fs.path.join(t.allocator, &.{ root, "big" });
    defer t.allocator.free(src);
    const dst = try std.fs.path.join(t.allocator, &.{ root, "out" });
    defer t.allocator.free(dst);
    _ = try start(&app, .copy, &.{.{ .src = src, .dst = dst }});
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"app.quit" }));
    try t.expect(!app.quit);
    try t.expect(app.overlay != .confirm);
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "1 transfer(s) still running") != null);
    _ = cancelAll(&app);
    try settle(&app, 4000);
    try t.expectEqual(@as(usize, 0), running(&app));
    // // changed (quit-confirm): past the guard the quit raises its box
    // — the guard is the FIRST word, so nothing was copying when it did.
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.char('q') });
    try t.expect(app.quit);
}

test "commonAncestor and percent" {
    try t.expectEqualStrings("/a/b", commonAncestor(&.{ .{ .src = "", .dst = "/a/b/c" }, .{ .src = "", .dst = "/a/b/d/e" } }));
    try t.expectEqualStrings("/a/b/c", commonAncestor(&.{.{ .src = "", .dst = "/a/b/c" }}));
    try t.expectEqualStrings("/", commonAncestor(&.{ .{ .src = "", .dst = "/a" }, .{ .src = "", .dst = "/b" } }));
    try t.expectEqualStrings("/a", commonAncestor(&.{ .{ .src = "", .dst = "/a/bc" }, .{ .src = "", .dst = "/a/bd" } }));
    var flag = Flag.init(false);
    var j: Job = .{ .id = 1, .kind = .copy, .dest = @constCast(""), .started_ms = 0, .cancel = &flag };
    try t.expectEqual(@as(u8, 0), j.percent());
    j.bytes_total = 200;
    j.bytes_done = 50;
    try t.expectEqual(@as(u8, 25), j.percent());
    try t.expect(j.speed(100) == null);
    try t.expectEqual(@as(u64, 100), j.speed(500).?);
}
