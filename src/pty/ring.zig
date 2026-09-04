//! Single-producer / single-consumer byte ring between a pty reader thread
//! (producer) and the UI thread (consumer).
//!
//! The reader thread `read(2)`s straight into `writable()` and `commit`s; the
//! UI thread's pump takes `readable()` slices and `consume`s them. Nothing is
//! copied twice and nothing is allocated after `init`.
//!
//! Wakeup protocol — the "readable" flag. The producer raises `readable`
//! after every commit and reports whether it was the one to flip it from
//! false to true; only that transition should post an event to the UI
//! queue, so a burst of reads costs one wakeup, not one per `read(2)`. The
//! consumer lowers the flag *before* draining. Ordered that way there is no
//! lost wakeup: a commit that lands before the consumer's swap is visible to
//! that drain (acq_rel on the flag chains to the release on `tail`), and a
//! commit that lands after it sees `false` and posts again.
//!
//! Indices are monotonically increasing u64 counters; the slot is
//! `index & mask`. They never wrap in practice (2^64 bytes) so `tail - head`
//! is always the live byte count without any full/empty ambiguity.

const std = @import("std");
const assert = std.debug.assert;
const Value = std.atomic.Value;

pub const Ring = struct {
    buf: []u8,
    mask: u64,
    /// Next byte the consumer will read. Written by the consumer only.
    head: Value(u64) = .init(0),
    /// Next byte the producer will write. Written by the producer only.
    tail: Value(u64) = .init(0),
    /// True while the producer believes the consumer has unseen bytes.
    readable: Value(bool) = .init(false),

    /// What the pty hot path uses: 256 KiB, enough for ~30 ms of a shell
    /// spewing at full tilt before the reader has to wait for a frame.
    pub const default_capacity: usize = 256 * 1024;

    /// `cap` must be a power of two. Backed by `page_allocator` by
    /// default because the buffer is large, long-lived, and the reader
    /// thread touches it without any allocator involvement.
    pub fn init(cap: usize) std.mem.Allocator.Error!Ring {
        return initWith(std.heap.page_allocator, cap);
    }

    pub fn initWith(allocator: std.mem.Allocator, cap: usize) std.mem.Allocator.Error!Ring {
        assert(cap > 0 and std.math.isPowerOfTwo(cap));
        return .{
            .buf = try allocator.alloc(u8, cap),
            .mask = cap - 1,
        };
    }

    pub fn deinit(self: *Ring) void {
        self.deinitWith(std.heap.page_allocator);
    }

    pub fn deinitWith(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn capacity(self: *const Ring) usize {
        return self.buf.len;
    }

    /// Bytes waiting to be consumed. Safe from either side (a snapshot).
    pub fn len(self: *const Ring) usize {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        return @intCast(t - h);
    }

    // ── producer side ────────────────────────────────────────────────

    /// The contiguous region the producer may fill right now. Empty when
    /// the ring is full. May be shorter than the true free space when the
    /// free space wraps around the end of the buffer; call again after
    /// `commit` to get the rest.
    pub fn writable(self: *Ring) []u8 {
        const t = self.tail.load(.monotonic); // own writes
        const h = self.head.load(.acquire);
        const free: usize = @intCast(self.buf.len - (t - h));
        if (free == 0) return self.buf[0..0];
        const slot: usize = @intCast(t & self.mask);
        const to_end = self.buf.len - slot;
        return self.buf[slot .. slot + @min(free, to_end)];
    }

    /// Publish `n` bytes previously written into `writable()`. Returns
    /// true when this commit flipped the ring from "nothing new" to
    /// "readable" — the caller posts exactly one wakeup in that case.
    pub fn commit(self: *Ring, n: usize) bool {
        assert(n <= self.buf.len - self.len());
        const t = self.tail.load(.monotonic);
        self.tail.store(t + n, .release);
        return !self.readable.swap(true, .acq_rel);
    }

    /// Convenience for tests and small writers: copy as much of `bytes`
    /// as fits. Returns how many were written and whether a wakeup is due.
    pub fn push(self: *Ring, bytes: []const u8) struct { written: usize, wake: bool } {
        var written: usize = 0;
        var wake = false;
        while (written < bytes.len) {
            const dst = self.writable();
            if (dst.len == 0) break;
            const n = @min(dst.len, bytes.len - written);
            @memcpy(dst[0..n], bytes[written .. written + n]);
            if (self.commit(n)) wake = true;
            written += n;
        }
        return .{ .written = written, .wake = wake };
    }

    // ── consumer side ────────────────────────────────────────────────

    /// Lower the readable flag. Call once at the top of a pump, before the
    /// first `readable()`, so a commit racing the drain re-posts.
    pub fn beginDrain(self: *Ring) void {
        _ = self.readable.swap(false, .acq_rel);
    }

    /// The contiguous run of bytes ready to consume. Empty when drained.
    /// May stop short at the end of the buffer; call again after
    /// `consume` for the wrapped remainder.
    pub fn readableSlice(self: *Ring) []const u8 {
        const h = self.head.load(.monotonic); // own writes
        const t = self.tail.load(.acquire);
        const avail: usize = @intCast(t - h);
        if (avail == 0) return self.buf[0..0];
        const slot: usize = @intCast(h & self.mask);
        const to_end = self.buf.len - slot;
        return self.buf[slot .. slot + @min(avail, to_end)];
    }

    /// Release `n` bytes obtained from `readableSlice()`.
    pub fn consume(self: *Ring, n: usize) void {
        assert(n <= self.len());
        const h = self.head.load(.monotonic);
        self.head.store(h + n, .release);
    }
};

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "empty ring has no readable or full writable" {
    var r = try Ring.initWith(testing.allocator, 16);
    defer r.deinitWith(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.len());
    try testing.expectEqual(@as(usize, 0), r.readableSlice().len);
    try testing.expectEqual(@as(usize, 16), r.writable().len);
}

test "push then drain round-trips bytes in order" {
    var r = try Ring.initWith(testing.allocator, 16);
    defer r.deinitWith(testing.allocator);
    const res = r.push("hello");
    try testing.expectEqual(@as(usize, 5), res.written);
    try testing.expect(res.wake);
    r.beginDrain();
    try testing.expectEqualStrings("hello", r.readableSlice());
    r.consume(5);
    try testing.expectEqual(@as(usize, 0), r.len());
}

test "wrap-around: writable and readable stop at the buffer end and continue" {
    var r = try Ring.initWith(testing.allocator, 8);
    defer r.deinitWith(testing.allocator);

    // Fill 6, drain 6: head = tail = 6, so the next write wraps at 8.
    _ = r.push("abcdef");
    r.beginDrain();
    r.consume(6);

    // Free space is 8 but only 2 are contiguous before the end.
    try testing.expectEqual(@as(usize, 2), r.writable().len);
    const res = r.push("123456");
    try testing.expectEqual(@as(usize, 6), res.written);
    try testing.expectEqual(@as(usize, 6), r.len());

    // Readable comes back in two runs: [6..8) then [0..4).
    try testing.expectEqualStrings("12", r.readableSlice());
    r.consume(2);
    try testing.expectEqualStrings("3456", r.readableSlice());
    r.consume(4);
    try testing.expectEqual(@as(usize, 0), r.readableSlice().len);
}

test "full ring refuses further writes until consumed" {
    var r = try Ring.initWith(testing.allocator, 4);
    defer r.deinitWith(testing.allocator);
    const a = r.push("wxyz!");
    try testing.expectEqual(@as(usize, 4), a.written);
    try testing.expectEqual(@as(usize, 0), r.writable().len);
    r.consume(1);
    try testing.expectEqual(@as(usize, 1), r.writable().len);
    const b = r.push("!");
    try testing.expectEqual(@as(usize, 1), b.written);
    try testing.expectEqualStrings("xyz", r.readableSlice());
    r.consume(3);
    try testing.expectEqualStrings("!", r.readableSlice());
}

test "wake fires only on the empty-to-readable edge" {
    var r = try Ring.initWith(testing.allocator, 64);
    defer r.deinitWith(testing.allocator);
    try testing.expect(r.push("a").wake);
    try testing.expect(!r.push("b").wake); // still readable, no second wake
    try testing.expect(!r.push("c").wake);
    r.beginDrain(); // consumer takes ownership of what's there
    try testing.expect(r.push("d").wake); // anything after that must wake again
    while (r.readableSlice().len > 0) r.consume(r.readableSlice().len);
    try testing.expect(!r.push("e").wake); // flag still up from "d"
}

test "producer and consumer threads agree on every byte" {
    var r = try Ring.initWith(testing.allocator, 1024);
    defer r.deinitWith(testing.allocator);

    const total: usize = 200_000;
    const Producer = struct {
        fn run(ring: *Ring) void {
            var i: usize = 0;
            while (i < total) {
                const dst = ring.writable();
                if (dst.len == 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const n = @min(dst.len, total - i);
                for (dst[0..n], 0..) |*b, k| b.* = @truncate(i + k);
                _ = ring.commit(n);
                i += n;
            }
        }
    };
    const th = try std.Thread.spawn(.{}, Producer.run, .{&r});

    var seen: usize = 0;
    while (seen < total) {
        r.beginDrain();
        const src = r.readableSlice();
        if (src.len == 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        for (src, 0..) |b, k| try testing.expectEqual(@as(u8, @truncate(seen + k)), b);
        r.consume(src.len);
        seen += src.len;
    }
    th.join();
    try testing.expectEqual(@as(usize, 0), r.len());
}
