//! The session's outbound bytes — keys, pastes and the terminal's query
//! replies on their way to the child.
//!
//! The UI thread never writes to the pty itself. A child that is not
//! reading its input (a build, `sleep`, `tail -f`, a server) stops
//! draining the tty after about a kilobyte, and a `write(2)` from the UI
//! thread would then block it — every pane, every key, Ctrl+C included —
//! until the child reads or exits. So the UI thread `push`es here and
//! returns at once, and the session's own I/O thread (the POSIX reader,
//! which polls the master for POLLOUT; the Windows writer) drains the
//! box whenever the child makes room. It is the inbound ring's mirror
//! (docs/DESIGN.md D3), with one difference: the producer allocates, so
//! nothing the drainer does ever touches an allocator.
//!
//! Ordering is the box's: one FIFO holds keys, pastes and replies alike,
//! so a query reply can never overtake the keystroke that came before it.
//!
//! The drainer copies a chunk out under the lock (`peek`), writes it with
//! the lock released, then `consume`s what the kernel took. `discard`
//! (the interrupt path) bumps `gen`, and a `consume` stamped with an older
//! generation is ignored — the bytes it would have dropped are new ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SpinLock = @import("common.zig").SpinLock;

const log = std.log.scoped(.pty);

pub const Outbox = struct {
    lock: SpinLock = .{},
    /// `buf.items[head..]` is pending. Grown by the producer only.
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    /// Bumped by `discard`, so a drain that raced it does not drop bytes
    /// pushed after it.
    gen: u32 = 0,
    /// Set once the child can take nothing more (EOF, a failed write):
    /// every later `push` is dropped rather than queued forever.
    closed: bool = false,

    /// A paste larger than this is refused rather than queued: 64 MiB of
    /// input to a child that is not reading is a mistake, not a paste.
    pub const max_pending: usize = 64 * 1024 * 1024;

    pub const Taken = struct { n: usize, gen: u32 };

    pub fn deinit(self: *Outbox, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.* = undefined;
    }

    /// Producer side. Queue `bytes`; true when the box went from empty
    /// to pending — the drainer may be asleep and must be woken.
    pub fn push(self: *Outbox, gpa: Allocator, bytes: []const u8) Allocator.Error!bool {
        if (bytes.len == 0) return false;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.closed) return false;
        const queued = self.buf.items.len - self.head;
        if (queued + bytes.len > max_pending) {
            log.warn("dropping {d} bytes of input: the child has {d} unread", .{ bytes.len, queued });
            return false;
        }
        // Reclaim what the drainer has written before growing.
        if (self.head > 0 and self.buf.items.len + bytes.len > self.buf.capacity) self.compact();
        try self.buf.appendSlice(gpa, bytes);
        return queued == 0;
    }

    /// Drainer side: copy up to `dst.len` pending bytes out.
    pub fn peek(self: *Outbox, dst: []u8) Taken {
        self.lock.lock();
        defer self.lock.unlock();
        const src = self.buf.items[self.head..];
        const n = @min(src.len, dst.len);
        @memcpy(dst[0..n], src[0..n]);
        return .{ .n = n, .gen = self.gen };
    }

    /// Drainer side: `n` bytes of what `peek` stamped `gen` reached the
    /// child.
    pub fn consume(self: *Outbox, n: usize, gen: u32) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (gen != self.gen) return;
        self.head = @min(self.head + n, self.buf.items.len);
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        }
    }

    pub fn pending(self: *Outbox) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.buf.items.len - self.head;
    }

    /// Drop everything not yet written. What a tty does with its own
    /// input queue on an interrupt character (`ISIG` without `NOFLSH`).
    pub fn discard(self: *Outbox) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.buf.clearRetainingCapacity();
        self.head = 0;
        self.gen +%= 1;
    }

    /// Nothing more will ever be written: drop what is queued and refuse
    /// the rest.
    pub fn close(self: *Outbox) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = true;
        self.buf.clearRetainingCapacity();
        self.head = 0;
        self.gen +%= 1;
    }

    fn compact(self: *Outbox) void {
        const live = self.buf.items[self.head..];
        std.mem.copyForwards(u8, self.buf.items[0..live.len], live);
        self.buf.shrinkRetainingCapacity(live.len);
        self.head = 0;
    }
};

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "push reports the empty-to-pending edge only; peek and consume drain in order" {
    var box: Outbox = .{};
    defer box.deinit(testing.allocator);
    try testing.expect(try box.push(testing.allocator, "abc"));
    try testing.expect(!try box.push(testing.allocator, "def"));
    var buf: [4]u8 = undefined;
    const a = box.peek(&buf);
    try testing.expectEqualStrings("abcd", buf[0..a.n]);
    box.consume(2, a.gen);
    const b = box.peek(&buf);
    try testing.expectEqualStrings("cdef", buf[0..b.n]);
    box.consume(b.n, b.gen);
    try testing.expectEqual(@as(usize, 0), box.pending());
    // Empty again: the next push is an edge again.
    try testing.expect(try box.push(testing.allocator, "g"));
}

test "a consume that raced a discard drops nothing that was pushed after it" {
    var box: Outbox = .{};
    defer box.deinit(testing.allocator);
    _ = try box.push(testing.allocator, "old bytes");
    var buf: [16]u8 = undefined;
    const taken = box.peek(&buf);
    box.discard();
    _ = try box.push(testing.allocator, "new");
    box.consume(taken.n, taken.gen);
    const now = box.peek(&buf);
    try testing.expectEqualStrings("new", buf[0..now.n]);
}

test "a closed box refuses input; compaction keeps the pending tail" {
    var box: Outbox = .{};
    defer box.deinit(testing.allocator);
    _ = try box.push(testing.allocator, "0123456789");
    var buf: [8]u8 = undefined;
    const t1 = box.peek(&buf);
    box.consume(8, t1.gen);
    // Growing past capacity compacts first: the two pending bytes lead.
    const big = [_]u8{'x'} ** 64;
    _ = try box.push(testing.allocator, &big);
    const t2 = box.peek(&buf);
    try testing.expectEqualStrings("89xxxxxx", buf[0..t2.n]);
    box.close();
    try testing.expect(!try box.push(testing.allocator, "late"));
    try testing.expectEqual(@as(usize, 0), box.pending());
}
