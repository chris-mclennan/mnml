//! The host's messages, read on a task of their own and handed to the
//! main loop through a queue with a wake event — so the loop can wait
//! *with a timeout* and run the auto-refresh on the reference's cadence
//! while nothing is typed. `Mount.next` blocks on the socket; a pane
//! that reads it inline can never tick.
//!
//! Each message arrives on its own arena, freed by whoever takes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

pub const Item = struct {
    arena: *std.heap.ArenaAllocator,
    /// Null once the host said goodbye or the socket ended.
    msg: ?sdk.HostMessage,

    pub fn destroy(it: Item, gpa: Allocator) void {
        it.arena.deinit();
        gpa.destroy(it.arena);
    }
};

pub const Inbox = struct {
    gpa: Allocator,
    q: Io.Queue(Item),
    wake: Io.Event = .unset,
    buffer: []Item,
    /// Set by the reader when the stream ended.
    ended: bool = false,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Inbox {
        const buffer = try gpa.alloc(Item, capacity);
        return .{ .gpa = gpa, .q = .init(buffer), .buffer = buffer };
    }

    pub fn deinit(self: *Inbox, io: Io) void {
        self.q.close(io);
        var buf: [16]Item = undefined;
        while (true) {
            const n = self.q.getUncancelable(io, &buf, 0) catch 0;
            if (n == 0) break;
            for (buf[0..n]) |it| it.destroy(self.gpa);
        }
        self.gpa.free(self.buffer);
    }

    /// The reader task: `mount.next` until it says null.
    pub fn reader(io: Io, self: *Inbox, mount: *sdk.Mount) Io.Cancelable!void {
        while (true) {
            const arena = self.gpa.create(std.heap.ArenaAllocator) catch return;
            arena.* = std.heap.ArenaAllocator.init(self.gpa);
            const msg = mount.next(arena.allocator()) catch null;
            const done = msg == null;
            self.q.putOneUncancelable(io, .{ .arena = arena, .msg = msg }) catch {
                arena.deinit();
                self.gpa.destroy(arena);
                return;
            };
            self.wake.set(io);
            if (done) {
                self.ended = true;
                return;
            }
        }
    }

    /// Wait up to `ms` for a message; false on the timeout.
    pub fn wait(self: *Inbox, io: Io, ms: u32) bool {
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } };
        self.wake.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => return false,
            error.Canceled => return false,
        };
        self.wake.reset();
        return true;
    }

    /// The next message without waiting, or null.
    pub fn take(self: *Inbox, io: Io) ?Item {
        var buf: [1]Item = undefined;
        const n = self.q.getUncancelable(io, &buf, 0) catch 0;
        if (n == 0) return null;
        return buf[0];
    }
};
