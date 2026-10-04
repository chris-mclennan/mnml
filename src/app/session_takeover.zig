//! SESSIONS' verbs on a session another terminal runs, through Claude
//! Code's live-session registry (`app/session_registry.zig`):
//!
//!  - `sessions.ask_external` writes one cross-session message to the
//!    session's inbox socket asking what it is doing. How a reply is
//!    routed back to a sender that is not itself a Claude Code session is
//!    not documented, so mnml binds no socket of its own: it notes where
//!    the session's transcript ends, polls the transcript for the next
//!    assistant reply for 60 s, and toasts it.
//!  - `sessions.take_over` ends an idle or waiting session in its own
//!    terminal (SIGTERM, after checking the pid is still a `claude`
//!    process) and, once its registry file is gone, resumes it in a pane
//!    here. Never SIGKILL: a session that does not exit in 10 s is left
//!    running.
//!
//! The registry is read on the sessions stat tick (`tick`).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const sessions = @import("../sessions.zig");
const registry = @import("session_registry.zig");
const refresh_cadence = @import("refresh_cadence.zig");

pub const ask_window_ms: i64 = 60_000;
pub const take_over_window_ms: i64 = 10_000;
/// How often a pending ask / take-over looks again.
pub const poll_ms: i64 = 500;
/// The most of a transcript's new bytes one poll reads.
const reply_scan_cap: u64 = 256 * 1024;

/// An ask in flight. All owned.
pub const PendingAsk = struct {
    session_id: []u8,
    name: []u8,
    transcript: []u8,
    /// The transcript's length when the message went: a reply is after it.
    offset: u64,
    deadline_ms: i64,
    next_ms: i64 = 0,

    pub fn deinit(p: *PendingAsk, gpa: Allocator) void {
        gpa.free(p.session_id);
        gpa.free(p.name);
        gpa.free(p.transcript);
    }
};

/// A take-over waiting for the session to exit. All owned.
pub const PendingTakeOver = struct {
    pid: u32,
    session_id: []u8,
    cwd: ?[]u8,
    deadline_ms: i64,
    next_ms: i64 = 0,

    pub fn deinit(p: *PendingTakeOver, gpa: Allocator) void {
        gpa.free(p.session_id);
        if (p.cwd) |c| gpa.free(c);
    }
};

/// The confirm's payload (`Confirm.Purpose.take_over`). Owned.
pub const TakeOver = struct {
    pid: u32,
    session_id: []u8,
    cwd: ?[]u8,

    pub fn deinit(t: TakeOver, gpa: Allocator) void {
        gpa.free(t.session_id);
        if (t.cwd) |c| gpa.free(c);
    }
};

// ─── the registry on the stat tick ─────────────────────────────────────

pub fn enabled(app: *const App) bool {
    return app.cfg.sessions.registry;
}

/// The live CLI's record for `session_id`, when the registry is on.
pub fn recordOf(app: *const App, session_id: []const u8) ?registry.Record {
    if (!enabled(app)) return null;
    return app.sessions.registry.find(session_id);
}

/// Read the registry directory again now.
pub fn readRegistry(app: *App) void {
    const st = &app.sessions;
    st.registry_ms = app.now_ms;
    if (!enabled(app)) {
        if (st.registry.map.count() > 0) {
            st.registry.clear(app.gpa);
            app.needs_render = true;
        }
        return;
    }
    const home = (sessions.homeFor(app) catch return) orelse return;
    const dir = registry.dirPath(app.frame.allocator(), home) catch return;
    if (st.registry.refresh(app.io, app.gpa, dir) catch false) app.needs_render = true;
}

fn interval(app: *const App) ?i64 {
    if (app.sessions.ask != null or app.sessions.take_over != null) return poll_ms;
    return refresh_cadence.statInterval(app.cfg.ui.dashboard_refresh, sessions.wantsScan(app)) orelse null;
}

/// The sessions tick's share: the registry when due, a pending ask's
/// poll, a pending take-over's wait.
pub fn tick(app: *App, now: i64) void {
    const st = &app.sessions;
    if (interval(app)) |iv| if (now - st.registry_ms >= iv) readRegistry(app);
    pollAsk(app, now);
    pollTakeOver(app, now);
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.sessions;
    const iv = interval(app) orelse return null;
    return st.registry_ms + iv;
}

// ─── ask ───────────────────────────────────────────────────────────────

pub fn askCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = sessions.current(app) orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    if (it.where == .cloud or it.source != .claude) return app.diag.fail(arena, "sessions: only a local Claude Code session has an inbox", .{});
    const rec = recordOf(app, it.session_id) orelse return app.diag.fail(arena, "sessions: not in Claude Code's session registry (not running, or the registry is off)", .{});
    if (builtin.os.tag == .windows) return app.diag.fail(arena, "sessions: asking a session is not on Windows yet", .{});
    const sock = rec.socket orelse return app.diag.fail(arena, "sessions: that session has no inbox (cross-session messaging off there)", .{});
    return askVia(app, it, rec.title(), sock, registry.ask_text);
}

/// Send `text` to `sock` for row `it` and start waiting on its transcript.
pub fn askVia(app: *App, it: sessions.Item, name: []const u8, sock: []const u8, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const offset = transcriptLen(app.io, it.transcript_path);
    registry.send(app.io, arena, sock, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => app.diag.fail(arena, "sessions: asking a session is not on Windows yet", .{}),
        error.Unreachable => app.diag.fail(arena, "sessions: could not reach {s}'s inbox", .{name}),
    };
    clearAsk(app);
    const gpa = app.gpa;
    const sid = try gpa.dupe(u8, it.session_id);
    errdefer gpa.free(sid);
    const nm = try gpa.dupe(u8, name);
    errdefer gpa.free(nm);
    const tp = try gpa.dupe(u8, it.transcript_path);
    app.sessions.ask = .{ .session_id = sid, .name = nm, .transcript = tp, .offset = offset, .deadline_ms = app.now_ms + ask_window_ms };
    app.toast("asked {s} what it is doing — its reply shows here", .{name});
}

fn clearAsk(app: *App) void {
    if (app.sessions.ask) |*p| p.deinit(app.gpa);
    app.sessions.ask = null;
}

fn transcriptLen(io: Io, path: []const u8) u64 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    return f.length(io) catch 0;
}

fn pollAsk(app: *App, now: i64) void {
    const p = &(app.sessions.ask orelse return);
    if (now < p.next_ms) return;
    p.next_ms = now + poll_ms;
    const arena = app.frame.allocator();
    if (newReply(app.io, arena, p.transcript, p.offset) catch null) |reply| {
        app.toast("{s}: {s}", .{ p.name, reply });
        clearAsk(app);
        return;
    }
    if (now >= p.deadline_ms) {
        app.toast("{s} did not reply within 60 s", .{p.name});
        clearAsk(app);
    }
}

/// The first assistant reply written to `path` after byte `offset`.
pub fn newReply(io: Io, arena: Allocator, path: []const u8, offset: u64) !?[]const u8 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = try f.length(io);
    if (len <= offset) return null;
    const want: usize = @intCast(@min(len - offset, reply_scan_cap));
    const buf = try arena.alloc(u8, want);
    const n = try f.readPositionalAll(io, buf, offset);
    return replyIn(arena, buf[0..n]);
}

/// In transcript lines: the first assistant entry's message to the
/// asker — a `SendMessage` tool call's text, else its plain text. One
/// line, clipped.
pub fn replyIn(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (v != .object) continue;
        const ty = v.object.get("type") orelse continue;
        if (ty != .string or !std.mem.eql(u8, ty.string, "assistant")) continue;
        const msg = v.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        var plain: ?[]const u8 = null;
        switch (content) {
            .string => |s| plain = s,
            .array => |arr| for (arr.items) |b| {
                if (b != .object) continue;
                const bt = b.object.get("type") orelse continue;
                if (bt != .string) continue;
                if (std.mem.eql(u8, bt.string, "tool_use")) {
                    const nm = b.object.get("name") orelse continue;
                    if (nm != .string or !std.mem.eql(u8, nm.string, "SendMessage")) continue;
                    const input = b.object.get("input") orelse continue;
                    if (input != .object) continue;
                    for ([_][]const u8{ "message", "content", "text" }) |k| if (input.object.get(k)) |m| if (m == .string and m.string.len > 0) return oneLine(m.string);
                } else if (std.mem.eql(u8, bt.string, "text") and plain == null) {
                    if (b.object.get("text")) |t| if (t == .string) {
                        plain = t.string;
                    };
                }
            },
            else => {},
        }
        if (plain) |s| if (std.mem.trim(u8, s, " \t\r\n").len > 0) return oneLine(s);
    }
    return null;
}

fn oneLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const first = t[0 .. std.mem.indexOfAny(u8, t, "\r\n") orelse t.len];
    return sessions.clipChars(first, 160);
}

// ─── take over ─────────────────────────────────────────────────────────

pub const choices = [_]app_mod.Confirm.Choice{ .{ .key = 't', .label = "Take over" }, .{ .key = 'c', .label = "Cancel" } };

pub fn takeOverCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = sessions.current(app) orelse return app.diag.fail(arena, "sessions: nothing selected", .{});
    if (it.where == .cloud or it.source != .claude) return app.diag.fail(arena, "sessions: only a local Claude Code session can be taken over", .{});
    if (builtin.os.tag == .windows) return app.diag.fail(arena, "sessions: taking over a session is not on Windows yet", .{});
    const rec = recordOf(app, it.session_id) orelse return app.diag.fail(arena, "sessions: not in Claude Code's session registry (not running, or the registry is off)", .{});
    if (!registry.takeOverAllowed(rec.status)) {
        app.toast("{s} is {s} — try when it is idle", .{ rec.title(), if (rec.status == .busy) "working" else "in an unknown state" });
        return;
    }
    if (app.sessions.take_over != null) return app.diag.fail(arena, "sessions: a take-over is already waiting", .{});
    const gpa = app.gpa;
    const sid = try gpa.dupe(u8, it.session_id);
    errdefer gpa.free(sid);
    const cwd: ?[]u8 = if (it.cwd orelse rec.cwd) |c| try gpa.dupe(u8, c) else null;
    errdefer if (cwd) |c| gpa.free(c);
    const msg = try std.fmt.allocPrint(gpa, "  End the session in its own terminal and resume it here?\n  {s} (pid {d}, {s})", .{ rec.title(), rec.pid, rec.status.label() });
    errdefer gpa.free(msg);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Take over", .message = msg, .choices = &choices },
        .purpose = .{ .take_over = .{ .pid = rec.pid, .session_id = sid, .cwd = cwd } },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The confirm's yes. The registry is read again first: the session may
/// have started a turn, or the pid moved on, while the box was up.
pub fn accept(app: *App, t: TakeOver) Allocator.Error!void {
    readRegistry(app);
    const st = &app.sessions;
    const rec = st.registry.findPid(t.pid) orelse {
        app.toast("that session already ended — resuming it here", .{});
        return startResume(app, t.session_id, t.cwd);
    };
    if (!std.mem.eql(u8, rec.session_id, t.session_id)) {
        app.toast("pid {d} is another session now — nothing sent", .{t.pid});
        return;
    }
    if (!registry.takeOverAllowed(rec.status)) {
        app.toast("{s} is working — try when it is idle", .{rec.title()});
        return;
    }
    const sig = st.signaler;
    const cmd = sig.cmdline(sig.ctx, app.io, app.gpa, app.frame.allocator(), t.pid) orelse {
        app.toast("pid {d} is not running — nothing sent", .{t.pid});
        return;
    };
    if (!registry.isClaudeCmdline(cmd)) {
        app.toast("pid {d} is not a claude process — nothing sent", .{t.pid});
        return;
    }
    if (!sig.term(sig.ctx, app.io, app.gpa, t.pid)) {
        app.toast("could not signal pid {d}", .{t.pid});
        return;
    }
    const gpa = app.gpa;
    const sid = try gpa.dupe(u8, t.session_id);
    errdefer gpa.free(sid);
    const cwd: ?[]u8 = if (t.cwd) |c| try gpa.dupe(u8, c) else null;
    if (st.take_over) |*p| p.deinit(gpa);
    st.take_over = .{ .pid = t.pid, .session_id = sid, .cwd = cwd, .deadline_ms = app.now_ms + take_over_window_ms, .next_ms = app.now_ms + poll_ms };
    app.toast("asked {s} to end — it resumes here when it exits", .{rec.title()});
}

fn pollTakeOver(app: *App, now: i64) void {
    const st = &app.sessions;
    const p = &(st.take_over orelse return);
    if (now < p.next_ms) return;
    p.next_ms = now + poll_ms;
    const gone = st.registry.findPid(p.pid) == null and st.registry.find(p.session_id) == null;
    if (gone) {
        const done = p.*;
        st.take_over = null;
        var d = done;
        defer d.deinit(app.gpa);
        startResume(app, d.session_id, d.cwd) catch {};
        return;
    }
    if (now >= p.deadline_ms) {
        app.toast("the session did not exit within 10 s — left running", .{});
        p.deinit(app.gpa);
        st.take_over = null;
    }
}

/// The existing resume path, on the scan's row when there is one.
fn startResume(app: *App, session_id: []const u8, cwd: ?[]const u8) Allocator.Error!void {
    const it: sessions.Item = app.sessions.itemOf(session_id) orelse .{
        .source = .claude,
        .session_id = session_id,
        .workspace = if (cwd) |c| std.fs.path.basename(c) else "",
        .cwd = cwd,
        .transcript_path = "",
        .state = .idle,
        .pid = null,
        .last_activity_s = 0,
        .last_user_msg = null,
        .last_assistant_msg = null,
    };
    const run = app.sessions.resumer orelse &sessions.resumeItem;
    run(app, it) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => app.toast("could not resume the session here", .{}),
    };
}

// ─── tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "session_takeover: replyIn takes the SendMessage text, else the plain text, of the first assistant entry" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try testing.expect((try replyIn(ar, "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\nnot json\n")) == null);
    try testing.expectEqualStrings("refactoring the parser; safe to interrupt", (try replyIn(ar,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Replying."},{"type":"tool_use","name":"SendMessage","input":{"to":"x","message":"refactoring the parser; safe to interrupt\nmore"}}]}}
    )).?);
    try testing.expectEqualStrings("writing tests", (try replyIn(ar,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"writing tests"}]}}
    )).?);
}
