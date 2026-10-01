//! The one inbound queue (D3). Every worker — terminal input included —
//! posts an `AppEvent`; the UI thread has exactly one wait (`wake`) and
//! drains the queue non-blocking after it.
//!
//! Payload ownership: a payload is owned by the event. The handler adopts
//! it or frees it before returning. `freeEvent` is what a failed `post`
//! calls so a closed queue cannot leak.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const key = @import("key.zig");
const todos = @import("../todos.zig");
const notes = @import("../notes.zig");
const findings = @import("../findings.zig");
const sessions = @import("../sessions.zig");
const dock = @import("../app/dock.zig");
const git_client = @import("../git/client.zig");
const spend = @import("../app/spend.zig");
const usage = @import("../ai/usage.zig");
const tests_pane = @import("../app/tests_pane.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const http_client = @import("../http/client.zig");
const ws_pane = @import("../app/ws_pane.zig");
const browser_pane = @import("../app/browser_pane.zig");
const bridge_host = @import("../bridge/host.zig");
const marketplace = @import("../app/marketplace.zig");
const font_scan = @import("../app/font_scan.zig");
const ipc_command = @import("../ipc/command.zig");
const transfers = @import("../app/transfers.zig");
const grep = @import("../app/grep.zig");
const session_search = @import("../app/session_search.zig");
const script_task = @import("../app/script_task.zig");
const syntax_jobs = @import("../app/syntax_jobs.zig");
const jobs = @import("../app/jobs.zig");

pub const PtyId = u32;

/// Who produced an `.err`. Workers never toast; they post this and the
/// UI thread decides how to surface it.
pub const Source = enum { todos, notes, findings, sessions, dock, git, lsp, dap, cdp, http, ai, copilot, pty, ipc, sonos, now_playing, marketplace, input, mount, transfer, grep };

// Payloads for subsystems that do not exist yet. Each is an opaque
// placeholder so the union has its final shape today; the subsystem
// replaces the placeholder with its real type when it lands.
/// What a language server's reader task posts. `message` is a parsed
/// frame the handler adopts or destroys; `closed` says the stream ended
/// (the server exited or broke) — `app/lsp.zig` retires the server.
pub const LspEvent = union(enum) {
    message: *jsonrpc.Incoming,
    closed,
    /// A reply or notification over `jsonrpc.max_body`, read off the
    /// pipe and thrown away rather than parsed. Everything that is left
    /// of it: how big it was, and whichever of the method and the
    /// request id its first bytes carried.
    oversize: Oversize,

    pub const Oversize = struct {
        len: usize,
        id: ?i64 = null,
        method_buf: [96]u8 = undefined,
        method_len: u8 = 0,

        pub fn method(self: *const Oversize) ?[]const u8 {
            return if (self.method_len == 0) null else self.method_buf[0..self.method_len];
        }
    };

    pub fn destroy(self: *LspEvent, gpa: Allocator) void {
        switch (self.*) {
            .message => |m| m.destroy(gpa),
            .closed, .oversize => {},
        }
        gpa.destroy(self);
    }
};

/// The same shape for a debug adapter's session.
pub const DapEvent = union(enum) {
    message: *jsonrpc.Incoming,
    closed,

    pub fn destroy(self: *DapEvent, gpa: Allocator) void {
        switch (self.*) {
            .message => |m| m.destroy(gpa),
            .closed => {},
        }
        gpa.destroy(self);
    }
};
/// What an AI worker posts (`src/app/ai.zig`). `job` on the event is
/// the `Job` id; 0 for the ghost text, which has no job. Every slice is
/// gpa-owned by the event.
/// How a ghost-text request ended, as the worker saw it. It rides on
/// the result rather than arriving as a separate `.err` so the app has
/// one place to log the line, hold the chip and settle the clock —
/// before this, a failure reached the user as a toast and left the
/// suggestion machinery looking exactly like one that had simply not
/// answered yet.
pub const SuggestOutcome = enum { shown, empty, failed, timed_out };

pub const AiMsg = union(enum) {
    /// An inline suggestion for `pane`; dropped unless `generation` is
    /// still the one the debounce wants. `text` is the completion on
    /// `.shown` and the reason on `.failed`; empty otherwise.
    suggestion: struct { pane: u32, generation: u32, text: []u8, outcome: SuggestOutcome = .shown },
    /// Answer text for the job's pane (a whole turn, or a chunk).
    text: []u8,
    /// The job finished; nothing more will arrive.
    done,
    /// The job failed; the reason.
    failed: []u8,
    /// The job's child ran past `[ai] cli_timeout_ms` and was killed;
    /// the reason. A failure the user did not ask for, so it toasts.
    timed_out: []u8,
    /// The worker wants a yes / no before a write (`detail`); it is
    /// parked on the job's `confirm` queue until the UI answers.
    confirm: []u8,
};

pub fn freeAiMsg(gpa: Allocator, msg: AiMsg) void {
    switch (msg) {
        .suggestion => |s| gpa.free(s.text),
        .text, .failed, .timed_out, .confirm => |s| gpa.free(s),
        .done => {},
    }
}
pub const SonosUpdate = struct { _todo: u8 = 0 }; // TODO(sonos)
pub const NowPlaying = struct { _todo: u8 = 0 }; // TODO(now_playing)
pub const StatuslineSegment = struct { _todo: u8 = 0 }; // TODO(statusline)
/// What the terminal loop's IPC tail posts (`tui/loop.zig`): the two
/// lifecycle lines a wrapper drops in `<ws>/.mnml/<ipc>/command` —
/// `{"cmd":"quit"}` and `{"cmd":"restart"}` (`run.sh stop` / `restart`).
/// One command off the file channel, owned. The tail parses onto the
/// event's own arena because a posted event outlives the poll that read
/// it; `App.handle` destroys it.
///
/// It used to be an `enum { quit, restart }` and the terminal loop
/// refused everything else — so an integration's `statusline-set-segment`
/// worked under the headless driver and was answered `unsupported` in
/// the app the user was actually looking at. The whole command set
/// travels now; what the loop refuses is decided by `ipc.allow_input`,
/// not by the shape of this type.
pub const IpcCommand = struct {
    arena: std.heap.ArenaAllocator,
    cmd: ipc_command.Command,

    pub fn create(gpa: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!*IpcCommand {
        const self = try gpa.create(IpcCommand);
        errdefer gpa.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .cmd = undefined };
        errdefer self.arena.deinit();
        self.cmd = try ipc_command.parse(self.arena.allocator(), line);
        return self;
    }

    pub fn destroy(self: *IpcCommand) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const AppEvent = union(enum) {
    key: key.Key,
    mouse: key.Mouse,
    winsize: key.Winsize,
    /// Bracketed paste. Owned; the handler frees or adopts.
    paste: []u8,
    focus: bool,

    lsp: struct { server: u32, msg: *LspEvent },
    /// The Copilot language server's reader task (`copilot/client.zig`).
    /// Its own variant rather than a row in `lsp`: Copilot is not
    /// registered as a language server, and `app/lsp.zig` must never
    /// see its frames.
    copilot: struct { msg: *LspEvent },
    dap: struct { session: u32, msg: *DapEvent },
    /// The CDP worker: connected / a raw message / closed. Owned.
    cdp: *browser_pane.CdpEvent,
    /// A finished git job. Owned; `git.handle` adopts or destroys it.
    git: *git_client.Result,
    /// A finished send. Owned; `http.handle` adopts the response.
    http: *http_client.JobResult,
    /// A progressive send: the head, a run of body bytes, the end.
    /// Owned; `http.handleStream` adopts or destroys it.
    sse: *http_client.StreamChunk,
    /// The WebSocket pane's reader: open / a message / closed. Owned.
    ws: *ws_pane.WsEvent,
    ai: struct { job: u64, msg: AiMsg },
    pty_readable: PtyId,
    sonos: SonosUpdate,
    now_playing: *NowPlaying,
    statusline: StatuslineSegment,
    /// A finished marketplace fetch or install. Owned; `marketplace.handle` adopts it.
    marketplace: *marketplace.Result,
    /// The latest Nerd Fonts release (or why the lookup failed). Owned;
    /// `font_scan.handle` adopts or frees it.
    fonts: *font_scan.Result,
    ipc: *IpcCommand,
    /// A mounted integration spoke (or its stream ended). Owned;
    /// `mount_pane.handle` reads it and `destroy`s it on every path.
    mount: *bridge_host.Event,

    /// A finished TODO scan. Owned; `todos.handle` copies it into its
    /// snapshot and `destroy`s it on every path.
    todos: *todos.ScanResult,
    /// A finished notes listing. Owned; `notes.handle` copies it into its
    /// snapshot and `destroy`s it on every path.
    notes: *notes.ScanResult,
    /// A finished findings listing. Owned; `findings.handle` copies it into its
    /// snapshot and `destroy`s it on every path.
    findings: *findings.ScanResult,
    /// A finished session listing. Owned; `sessions.handle` copies it into its
    /// snapshot and `destroy`s it on every path.
    sessions: *sessions.ScanResult,
    /// A finished dock tail read. Owned; `dock.handle` adopts the lines.
    dock: *dock.TailResult,
    /// A finished spend computation. Owned; the spend pane (or the meter) adopts it.
    spend: *spend.Result,
    /// A finished usage fetch (Claude / Codex / the keychain). Owned; `usage_pane.handle` adopts it.
    usage: *usage.Result,
    /// A finished Playwright run. Owned; `tests_pane.handle` adopts or destroys it.
    tests: *tests_pane.Result,
    /// A file transfer's totals / progress / end. Owned; `transfers.handle` destroys it.
    transfer: *transfers.Event,
    /// A batch of grep hits (the last one says `done`). Owned; `grep.handle` copies and destroys it.
    grep: *grep.Result,
    /// `ai.search_sessions`: the transcript search's hits (`app/session_search.zig`).
    session_search: *session_search.Result,
    /// A hidden script task's output lines or its exit. Owned;
    /// `script_task.handle` destroys it.
    script_task: *script_task.Event,
    /// A document's parse, finished on a worker. Owned;
    /// `syntax_jobs.handle` adopts the tree and destroys the rest.
    syntax: *syntax_jobs.Result,
    /// A worker's own word on a background job — progress, or how it
    /// ended (`app/jobs.zig`). Owned; `jobs.handleEvent` destroys it.
    job: *jobs.Event,

    /// A worker failed. `msg` is gpa-owned and freed by the handler.
    err: struct { source: Source, msg: []u8 },
    /// A deadline elapsed; `App.tick` decides what it meant.
    timer: void,

    comptime {
        std.debug.assert(@sizeOf(AppEvent) <= 64);
    }
};

/// Free whatever an `AppEvent` owns. Used when a post fails and by any
/// handler that decides to drop rather than adopt a payload.
pub fn freeEvent(gpa: Allocator, ev: AppEvent) void {
    switch (ev) {
        .paste => |p| gpa.free(p),
        .err => |e| gpa.free(e.msg),
        .todos => |r| r.destroy(gpa),
        .notes => |r| r.destroy(gpa),
        .findings => |r| r.destroy(gpa),
        .sessions => |r| r.destroy(gpa),
        .dock => |r| r.destroy(gpa),
        .spend => |r| r.destroy(gpa),
        .usage => |r| r.destroy(gpa),
        .tests => |r| r.destroy(gpa),
        .grep => |r| r.destroy(gpa),
        .session_search => |r| r.destroy(gpa),
        .script_task => |r| r.destroy(gpa),
        .syntax => |r| r.destroy(gpa),
        .job => |j| j.destroy(gpa),
        .ai => |a| freeAiMsg(gpa, a.msg),
        .lsp => |l| l.msg.destroy(gpa),
        .copilot => |c| c.msg.destroy(gpa),
        .dap => |d| d.msg.destroy(gpa),
        .git => |r| r.destroy(gpa),
        .http => |p| p.destroy(gpa),
        .sse => |p| p.destroy(gpa),
        .cdp => |p| p.destroy(gpa),
        .ws => |p| p.destroy(gpa),
        .now_playing => |p| gpa.destroy(p),
        .marketplace => |p| p.destroy(gpa),
        .fonts => |p| p.destroy(gpa),
        .mount => |p| p.destroy(gpa),
        .transfer => |p| p.destroy(gpa),
        .key, .mouse, .winsize, .focus, .pty_readable, .sonos, .statusline, .ipc, .timer => {},
    }
}

pub const EventQueue = struct {
    q: Io.Queue(AppEvent),
    wake: Io.Event = .unset,
    gpa: Allocator,
    buffer: []AppEvent,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!EventQueue {
        const buffer = try gpa.alloc(AppEvent, capacity);
        return .{ .q = .init(buffer), .gpa = gpa, .buffer = buffer };
    }

    /// Refuse every post from now on: a post already waiting for room
    /// in a full ring returns at once, and every later one frees its
    /// payload instead of queueing it. What is queued stays until
    /// `deinit`. The first step of a shutdown — before any worker is
    /// cancelled or awaited, since nothing drains the queue any more.
    pub fn close(self: *EventQueue, io: Io) void {
        self.q.close(io);
    }

    /// Closes the queue, frees anything still queued, and releases the ring.
    pub fn deinit(self: *EventQueue, io: Io) void {
        self.q.close(io);
        var buf: [32]AppEvent = undefined;
        while (true) {
            const n = self.q.getUncancelable(io, &buf, 0) catch 0;
            if (n == 0) break;
            for (buf[0..n]) |ev| freeEvent(self.gpa, ev);
        }
        self.gpa.free(self.buffer);
    }

    /// Post from any thread. Blocks only if the ring is full (backpressure
    /// on a runaway worker); never returns an error — a closed queue frees
    /// the payload instead.
    pub fn post(self: *EventQueue, io: Io, ev: AppEvent) void {
        self.q.putOneUncancelable(io, ev) catch freeEvent(self.gpa, ev);
        self.wake.set(io);
    }

    /// Non-blocking drain into `buf`. Returns how many events were taken;
    /// 0 when the queue is empty or closed.
    pub fn drain(self: *EventQueue, io: Io, buf: []AppEvent) usize {
        return self.q.getUncancelable(io, buf, 0) catch 0;
    }
};

test "post then drain returns events in order and wakes" {
    const io = std.testing.io;
    var q = try EventQueue.init(std.testing.allocator, 8);
    defer q.deinit(io);
    try std.testing.expect(!q.wake.isSet());
    q.post(io, .{ .focus = true });
    q.post(io, .{ .pty_readable = 7 });
    try std.testing.expect(q.wake.isSet());
    var buf: [4]AppEvent = undefined;
    const n = q.drain(io, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(buf[0] == .focus);
    try std.testing.expectEqual(@as(PtyId, 7), buf[1].pty_readable);
    try std.testing.expectEqual(@as(usize, 0), q.drain(io, &buf));
}

test "close releases a worker parked on a full ring, and its payload is freed" {
    const io = std.testing.io;
    var q = try EventQueue.init(std.testing.allocator, 1);
    defer q.deinit(io);
    q.post(io, .{ .focus = true }); // the ring is now full
    const Worker = struct {
        fn run(queue: *EventQueue, wio: Io) Io.Cancelable!void {
            const msg = std.testing.allocator.dupe(u8, "parked") catch return;
            queue.post(wio, .{ .err = .{ .source = .todos, .msg = msg } });
        }
    };
    var group: Io.Group = .init;
    try group.concurrent(io, Worker.run, .{ &q, io });
    // Nothing drains: this is a shutdown. Without the close the worker
    // waits for room forever and so does the group.
    q.close(io);
    try group.await(io);
}

test "deinit frees payloads still queued; post after close frees too" {
    const io = std.testing.io;
    var q = try EventQueue.init(std.testing.allocator, 8);
    const msg = try std.testing.allocator.dupe(u8, "boom");
    q.post(io, .{ .err = .{ .source = .todos, .msg = msg } });
    q.deinit(io);
    // A second queue, closed before the post: the payload must not leak.
    var q2 = try EventQueue.init(std.testing.allocator, 2);
    q2.q.close(io);
    const paste = try std.testing.allocator.dupe(u8, "text");
    q2.post(io, .{ .paste = paste });
    std.testing.allocator.free(q2.buffer);
}
