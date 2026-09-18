//! Getting a pane's slow work off its event loop.
//!
//! A pane's refetch is minutes of a working day: a search, then a call
//! per row. Run inline it freezes the pane — no keys, no repaint, not
//! even the resize the host just sent — and on a loaded machine that is
//! long enough for a test's own budget to lapse. `Slot` is the one-job
//! channel both panes refetch through: the loop claims it, a task on
//! the pane's `Io.Group` does the work, and the loop takes the result
//! on a later tick. Nothing is locked, because nothing is shared: the
//! task is handed its own inputs and gives back a value the loop alone
//! applies.
//!
//! The queue is closed before the group is cancelled. A task parked on
//! a put into a live queue never sees the cancel, and `group.cancel`
//! then never returns — closing first turns that park into an error the
//! task returns through.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A single in-flight job and the value it comes back with.
///
/// `claim` and `take` are the loop's; `finish` is the worker's. `busy`
/// is what a header reads to say it is refreshing — it is only ever
/// written by the loop, so a paint never touches a lock.
pub fn Slot(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        q: Io.Queue(T),
        buffer: []T,
        /// True between `claim` and the `take` that collects the result.
        running: bool = false,
        /// Set when the queue has closed under a pending job — the
        /// result will never arrive and the pane must stop waiting.
        lost: bool = false,

        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const buffer = try gpa.alloc(T, 1);
            return .{ .gpa = gpa, .q = .init(buffer), .buffer = buffer };
        }

        /// Close the queue, then drain whatever a finished-but-uncollected
        /// job left, so the caller can free it. Call before cancelling
        /// the group the workers run on.
        pub fn deinit(self: *Self, io: Io, comptime drop: ?fn (T) void) void {
            self.q.close(io);
            if (drop) |f| while (self.take(io)) |v| f(v);
            self.gpa.free(self.buffer);
            self.* = undefined;
        }

        pub fn busy(self: *const Self) bool {
            return self.running;
        }

        /// Take the slot for one job; false when one is already in it.
        pub fn claim(self: *Self) bool {
            if (self.running) return false;
            self.running = true;
            self.lost = false;
            return true;
        }

        /// The worker's hand-back. A closed queue means the pane is
        /// going away: the value is dropped by the caller's `catch`.
        pub fn finish(self: *Self, io: Io, value: T) error{Closed}!void {
            self.q.putOne(io, value) catch return error.Closed;
        }

        /// The result, if it has landed. Frees the slot for the next job.
        pub fn take(self: *Self, io: Io) ?T {
            var out: [1]T = undefined;
            const n = self.q.getUncancelable(io, &out, 0) catch {
                // Nothing will arrive now; let the pane stop waiting.
                if (self.running) self.lost = true;
                self.running = false;
                return null;
            };
            if (n == 0) return null;
            self.running = false;
            return out[0];
        }

        /// Give up on a job whose worker will never answer (the pane is
        /// closing, or the group was cancelled under it).
        pub fn abandon(self: *Self) void {
            self.running = false;
        }
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const Payload = struct { n: usize };

test "the slot holds one job: a second claim is refused until the result is taken" {
    var s = try Slot(Payload).init(testing.allocator);
    defer s.deinit(testing.io, null);
    try testing.expect(!s.busy());
    try testing.expect(s.claim());
    try testing.expect(s.busy());
    // While one is in flight the pane does not start another.
    try testing.expect(!s.claim());
    try testing.expect(s.take(testing.io) == null);
    try s.finish(testing.io, .{ .n = 7 });
    const got = s.take(testing.io).?;
    try testing.expectEqual(@as(usize, 7), got.n);
    try testing.expect(!s.busy());
    // …and the slot is free again.
    try testing.expect(s.claim());
    s.abandon();
    try testing.expect(!s.busy());
}

test "a closed queue ends a pending job rather than leaving the pane waiting forever" {
    var s = try Slot(Payload).init(testing.allocator);
    defer testing.allocator.free(s.buffer);
    try testing.expect(s.claim());
    s.q.close(testing.io);
    // The worker's hand-back fails rather than parking.
    try testing.expectError(error.Closed, s.finish(testing.io, .{ .n = 1 }));
    // And the loop stops expecting one.
    try testing.expect(s.take(testing.io) == null);
    try testing.expect(!s.busy());
    try testing.expect(s.lost);
}

test "deinit drains a result nobody collected, so its arena can be freed" {
    var seen: usize = 0;
    const Sink = struct {
        var count: *usize = undefined;
        fn drop(v: Payload) void {
            count.* += v.n;
        }
    };
    Sink.count = &seen;
    var s = try Slot(Payload).init(testing.allocator);
    try testing.expect(s.claim());
    try s.finish(testing.io, .{ .n = 3 });
    s.deinit(testing.io, Sink.drop);
    try testing.expectEqual(@as(usize, 3), seen);
}
