//! A script's HIDDEN task: `mnml.task.run{ hidden = true, on_line = fn }`
//! (D10, the platform design's §1 "tool wrapper" shape). A visible task
//! is a pty pane the user watches; a hidden one has no pane at all —
//! its output only ever goes to the script, a line at a time, which is
//! what a linter wrapper wants.
//!
//!   D3  one worker per run in the state's `Io.Group`, posting
//!       `.script_task` events; the worker never toasts and never
//!       touches the app.
//!   D1  a batch of lines is gpa-owned by its event and freed by the
//!       handler; nothing here outlives the run.
//!
//! The child is `/bin/sh -c "( <cmd> ) 2>&1"` in the workspace (or the
//! task's `cwd`), so a hidden task's stderr reaches `on_line` too —
//! there is no pane to read it in. Output is capped (`max_lines`,
//! `max_line`): a tool that never stops printing costs a bounded
//! number of hook calls, not the session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const event = @import("../core/event.zig");
const pty = @import("pty");

/// At most this many lines reach a script; the rest are dropped and the
/// run still finishes.
pub const max_lines: usize = 5000;
/// A longer line is cut here (the tail is dropped, not wrapped).
pub const max_line: usize = 4096;
/// How many lines one event carries at most.
const batch_max: usize = 64;

pub const Event = struct {
    /// The run this is about (`State.next_id`).
    id: u32,
    payload: union(enum) {
        /// Owned by the event: the handler frees the lines and the slice.
        lines: [][]u8,
        done: struct { ok: bool, code: i32 = 0, signal: u8 = 0 },
        /// The child never started; the reason is owned.
        failed: []u8,
    },

    fn create(gpa: Allocator, id: u32) Allocator.Error!*Event {
        const e = try gpa.create(Event);
        e.* = .{ .id = id, .payload = .{ .done = .{ .ok = false } } };
        return e;
    }

    pub fn destroy(self: *Event, gpa: Allocator) void {
        switch (self.payload) {
            .lines => |ls| {
                for (ls) |l| gpa.free(l);
                gpa.free(ls);
            },
            .failed => |m| gpa.free(m),
            .done => {},
        }
        gpa.destroy(self);
    }
};

pub const State = struct {
    group: Io.Group = .init,
    next_id: u32 = 0,

    pub fn deinit(self: *State, io: Io) void {
        self.group.cancel(io);
    }
};

/// Start `cmd` hidden. Answers the run's id; the script's `on_line` and
/// `on_done` are found by it when the events land.
pub fn spawn(app: *App, cmd: []const u8, cwd: []const u8) !u32 {
    const gpa = app.gpa;
    const st = &app.script_tasks;
    st.next_id += 1;
    const id = st.next_id;
    // `( … ) 2>&1` so a hidden task's stderr reaches the script: there
    // is no pane for it to land in.
    const line = try std.fmt.allocPrint(gpa, "( {s} ) 2>&1", .{cmd});
    errdefer gpa.free(line);
    const dir = try gpa.dupe(u8, cwd);
    errdefer gpa.free(dir);
    const env = try gpa.create(std.process.Environ.Map);
    errdefer gpa.destroy(env);
    env.* = try app.env.clone(gpa);
    errdefer env.deinit();
    try st.group.concurrent(app.io, worker, .{ &app.events, app.io, gpa, line, dir, env, id });
    return id;
}

/// The child, its output split into lines, its exit. Everything passed
/// in is freed here.
fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, cmdline: []u8, cwd: []u8, env: *std.process.Environ.Map, id: u32) Io.Cancelable!void {
    defer {
        env.deinit();
        gpa.destroy(env);
        gpa.free(cmdline);
        gpa.free(cwd);
    }
    var shell_buf: [4][]const u8 = undefined;
    const argv = pty.shellArgv(&shell_buf, env, cmdline);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = env,
    }) catch |err| {
        postFailed(events, io, gpa, id, err);
        return;
    };
    const out = child.stdout orelse {
        _ = child.wait(io) catch {};
        postFailed(events, io, gpa, id, error.NoStdout);
        return;
    };
    var rbuf: [8192]u8 = undefined;
    var reader: Io.File.Reader = .init(out, io, &rbuf);
    var chunk: [8192]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(gpa);
    var batch: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (batch.items) |l| gpa.free(l);
        batch.deinit(gpa);
    }
    var sent: usize = 0;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        pending.appendSlice(gpa, chunk[0..n]) catch break;
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const raw = pending.items[0..nl];
            if (sent < max_lines) {
                const text = std.mem.trimEnd(u8, raw[0..@min(raw.len, max_line)], "\r");
                const owned = gpa.dupe(u8, text) catch break;
                batch.append(gpa, owned) catch {
                    gpa.free(owned);
                    break;
                };
                sent += 1;
            }
            std.mem.copyForwards(u8, pending.items, pending.items[nl + 1 ..]);
            pending.items.len -= nl + 1;
            if (batch.items.len >= batch_max) flush(events, io, gpa, id, &batch);
        }
        flush(events, io, gpa, id, &batch);
    }
    // A last line without its newline is a line too.
    if (pending.items.len > 0 and sent < max_lines) {
        const text = std.mem.trimEnd(u8, pending.items[0..@min(pending.items.len, max_line)], "\r");
        if (gpa.dupe(u8, text)) |owned| {
            batch.append(gpa, owned) catch gpa.free(owned);
        } else |_| {}
    }
    flush(events, io, gpa, id, &batch);
    const term = child.wait(io) catch {
        postDone(events, io, gpa, id, .{ .ok = false });
        return;
    };
    const done: Done = switch (term) {
        .exited => |code| .{ .ok = code == 0, .code = @intCast(code) },
        .signal => |sig| .{ .ok = false, .signal = @truncate(@as(u32, @intCast(@intFromEnum(sig)))) },
        else => .{ .ok = false },
    };
    postDone(events, io, gpa, id, done);
}

/// How a run ended, as the event carries it.
pub const Done = struct { ok: bool, code: i32 = 0, signal: u8 = 0 };

fn flush(events: *event.EventQueue, io: Io, gpa: Allocator, id: u32, batch: *std.ArrayListUnmanaged([]u8)) void {
    if (batch.items.len == 0) return;
    const lines = batch.toOwnedSlice(gpa) catch return;
    const ev = Event.create(gpa, id) catch {
        for (lines) |l| gpa.free(l);
        gpa.free(lines);
        return;
    };
    ev.payload = .{ .lines = lines };
    events.post(io, .{ .script_task = ev });
}

fn postDone(events: *event.EventQueue, io: Io, gpa: Allocator, id: u32, done: Done) void {
    const ev = Event.create(gpa, id) catch return;
    ev.payload = .{ .done = .{ .ok = done.ok, .code = done.code, .signal = done.signal } };
    events.post(io, .{ .script_task = ev });
}

fn postFailed(events: *event.EventQueue, io: Io, gpa: Allocator, id: u32, err: anyerror) void {
    const ev = Event.create(gpa, id) catch return;
    const msg = std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) catch {
        ev.payload = .{ .done = .{ .ok = false } };
        events.post(io, .{ .script_task = ev });
        return;
    };
    ev.payload = .{ .failed = msg };
    events.post(io, .{ .script_task = ev });
}

/// The UI thread's end: the lines go to the run's `on_line`, the exit
/// to its `on_done`. The event is destroyed on every path.
pub fn handle(app: *App, ev: *Event) void {
    defer ev.destroy(app.gpa);
    const lua = app.script();
    switch (ev.payload) {
        .lines => |lines| for (lines) |l| lua.hiddenTaskLine(ev.id, l),
        .done => |d| lua.hiddenTaskDone(ev.id, d.ok, d.code, d.signal),
        .failed => |msg| {
            app.toastLevel(.err, "task: {s}", .{msg}) catch {};
            lua.hiddenTaskDone(ev.id, false, 0, 0);
        },
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "a hidden task streams its lines to on_line and its exit to on_done" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratch();
    try lua.runString(
        \\seen = {}
        \\done = nil
        \\mnml.task.run{ cmd = "printf 'one\\ntwo\\n'; echo three 1>&2; exit 3", hidden = true,
        \\               on_line = function(t) seen[#seen + 1] = t end,
        \\               on_done = function(r) done = r end }
    );
    // No pane of its own: a hidden task is invisible (the scratch
    // buffer above is the only pane there is).
    try testing.expectEqual(@as(usize, 1), app.panes.count());
    var spins: usize = 0;
    while (spins < 400) : (spins += 1) {
        try app.tick(app.now_ms + 5);
        var ok = false;
        lua.runString("assert(done ~= nil)") catch {
            ok = true;
        };
        if (!ok) break;
    }
    try lua.runString(
        \\assert(#seen == 3, "lines: " .. #seen)
        \\assert(seen[1] == "one" and seen[2] == "two", seen[1] .. "/" .. seen[2])
        \\assert(seen[3] == "three", seen[3])
        \\assert(done.ok == false and done.code == 3, tostring(done.code))
    );
}
