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
const agents = @import("../app/agents.zig");
const spend = @import("../app/spend.zig");

pub const PtyId = u32;

/// Who produced an `.err`. Workers never toast; they post this and the
/// UI thread decides how to surface it.
pub const Source = enum { todos, git, lsp, dap, cdp, http, ai, pty, ipc, sonos, now_playing, marketplace, input };

// Payloads for subsystems that do not exist yet. Each is an opaque
// placeholder so the union has its final shape today; the subsystem
// replaces the placeholder with its real type when it lands.
pub const LspEvent = struct { _todo: u8 = 0 }; // TODO(lsp)
pub const DapEvent = struct { _todo: u8 = 0 }; // TODO(dap)
pub const CdpEvent = struct { _todo: u8 = 0 }; // TODO(cdp)
pub const GitResult = struct { _todo: u8 = 0 }; // TODO(git)
pub const HttpJobResult = struct { _todo: u8 = 0 }; // TODO(http)
pub const SseChunk = struct { _todo: u8 = 0 }; // TODO(http)
pub const WsFrame = struct { _todo: u8 = 0 }; // TODO(http)
/// What an AI worker posts (`src/app/ai.zig`). `job` on the event is
/// the `Job` id; 0 for the ghost text, which has no job. Every slice is
/// gpa-owned by the event.
pub const AiMsg = union(enum) {
    /// An inline suggestion for `pane`; dropped unless `generation` is
    /// still the one the debounce wants.
    suggestion: struct { pane: u32, generation: u32, text: []u8 },
    /// Answer text for the job's pane (a whole turn, or a chunk).
    text: []u8,
    /// The job finished; nothing more will arrive.
    done,
    /// The job failed; the reason.
    failed: []u8,
    /// The worker wants a yes / no before a write (`detail`); it is
    /// parked on the job's `confirm` queue until the UI answers.
    confirm: []u8,
};

pub fn freeAiMsg(gpa: Allocator, msg: AiMsg) void {
    switch (msg) {
        .suggestion => |s| gpa.free(s.text),
        .text, .failed, .confirm => |s| gpa.free(s),
        .done => {},
    }
}
pub const SonosUpdate = struct { _todo: u8 = 0 }; // TODO(sonos)
pub const NowPlaying = struct { _todo: u8 = 0 }; // TODO(now_playing)
pub const StatuslineSegment = struct { _todo: u8 = 0 }; // TODO(statusline)
pub const MarketResult = struct { _todo: u8 = 0 }; // TODO(marketplace)
pub const IpcCommand = struct { _todo: u8 = 0 }; // TODO(ipc)

pub const AppEvent = union(enum) {
    key: key.Key,
    mouse: key.Mouse,
    winsize: key.Winsize,
    /// Bracketed paste. Owned; the handler frees or adopts.
    paste: []u8,
    focus: bool,

    lsp: struct { server: u32, msg: *LspEvent },
    dap: struct { session: u32, msg: *DapEvent },
    cdp: CdpEvent,
    git: *GitResult,
    http: *HttpJobResult,
    sse: SseChunk,
    ws: WsFrame,
    ai: struct { job: u64, msg: AiMsg },
    pty_readable: PtyId,
    sonos: SonosUpdate,
    now_playing: *NowPlaying,
    statusline: StatuslineSegment,
    marketplace: *MarketResult,
    ipc: IpcCommand,

    /// A finished TODO scan. Owned; `todos.handle` adopts the arena.
    todos: *todos.ScanResult,
    /// A finished Claude / Codex session scan. Owned; the agents pane adopts it.
    agents: *agents.ScanResult,
    /// A finished spend computation. Owned; the spend pane (or the meter) adopts it.
    spend: *spend.Result,

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
        .agents => |r| r.destroy(gpa),
        .spend => |r| r.destroy(gpa),
        .ai => |a| freeAiMsg(gpa, a.msg),
        .lsp => |l| gpa.destroy(l.msg),
        .dap => |d| gpa.destroy(d.msg),
        .git => |p| gpa.destroy(p),
        .http => |p| gpa.destroy(p),
        .now_playing => |p| gpa.destroy(p),
        .marketplace => |p| gpa.destroy(p),
        .key, .mouse, .winsize, .focus, .cdp, .sse, .ws, .pty_readable, .sonos, .statusline, .ipc, .timer => {},
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
