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

// ─── a failed refetch keeps what it had ─────────────────────────────────

/// Copy `v` and everything it points at onto `a`: slices, single
/// pointers, optionals, tagged unions and structs are followed; plain
/// values are copied. What a pane uses to carry last time's rows into
/// a refetch whose answer for them failed — the rows live on the old
/// result's arena, which is about to be freed.
///
/// A failed refetch keeps the rows it had and says so in the header
/// (`chrome.fetchText`'s `fetch failed: <why>`), and the `as of` stamp
/// stays on the last success: a Wi-Fi blip must never read as "nothing
/// here, and it is fresh". Both first-party panes follow that; a pane
/// whose fetch answers per group (Bitbucket's per-repo tree) carries
/// each failed group's last-good entry with this.
pub fn dupeDeep(comptime T: type, a: Allocator, v: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    if (p.sentinel() != null) return a.dupeZ(u8, v);
                    return a.dupe(u8, v);
                }
                if (p.sentinel() != null) @compileError("dupeDeep: a sentinel slice of " ++ @typeName(p.child));
                const out = try a.alloc(p.child, v.len);
                for (v, out) |x, *o| o.* = try dupeDeep(p.child, a, x);
                return out;
            },
            .one => {
                const o = try a.create(p.child);
                o.* = try dupeDeep(p.child, a, v.*);
                return o;
            },
            else => @compileError("dupeDeep: a many- or C-pointer in " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            var out: T = v;
            inline for (s.fields) |f| {
                if (!f.is_comptime) @field(out, f.name) = try dupeDeep(f.type, a, @field(v, f.name));
            }
            return out;
        },
        .optional => |o| return if (v) |x| try dupeDeep(o.child, a, x) else null,
        .array => |arr| {
            var out: T = undefined;
            for (v, &out) |x, *o| o.* = try dupeDeep(arr.child, a, x);
            return out;
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("dupeDeep: an untagged union " ++ @typeName(T));
            switch (v) {
                inline else => |payload, tag| return @unionInit(T, @tagName(tag), try dupeDeep(@TypeOf(payload), a, payload)),
            }
        },
        else => return v,
    }
}

/// The header's reason for a refetch that failed for `failed` of
/// `total` groups (repos, projects) — `network error` when every one
/// did, `web: HTTP 500` when one of several did, `2 of 5 repos: HTTP
/// 500` otherwise. `first` names the first failed group, `why` its
/// reason. Goes after `fetch failed: ` (`chrome.fetchText`).
pub fn partialFailureText(buf: []u8, failed: usize, total: usize, noun: []const u8, first: []const u8, why: []const u8) []const u8 {
    if (failed == 0) return "";
    if (failed >= total) return std.fmt.bufPrint(buf, "{s}", .{why}) catch why;
    if (failed == 1) return std.fmt.bufPrint(buf, "{s}: {s}", .{ first, why }) catch why;
    return std.fmt.bufPrint(buf, "{d} of {d} {s}: {s}", .{ failed, total, noun, why }) catch why;
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

test "dupeDeep carries a value off an arena that is about to go" {
    const Inner = struct { name: []const u8, tags: []const []const u8 };
    const Row = struct { id: i64, inner: []const Inner, maybe: ?Inner = null, kind: union(enum) { none, one: []const u8 } = .none };
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    const sa = src_arena.allocator();
    const tags = try sa.alloc([]const u8, 1);
    tags[0] = try sa.dupe(u8, "draft");
    const inner = try sa.alloc(Inner, 1);
    inner[0] = .{ .name = try sa.dupe(u8, "api"), .tags = tags };
    const row: Row = .{ .id = 7, .inner = inner, .maybe = inner[0], .kind = .{ .one = try sa.dupe(u8, "x") } };

    var dst_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer dst_arena.deinit();
    const copy = try dupeDeep(Row, dst_arena.allocator(), row);
    // Poison the source the way a freed arena reads, then free it.
    @memset(@constCast(inner[0].name), 0xAA);
    src_arena.deinit();
    try testing.expectEqual(@as(i64, 7), copy.id);
    try testing.expectEqualStrings("api", copy.inner[0].name);
    try testing.expectEqualStrings("draft", copy.inner[0].tags[0]);
    try testing.expectEqualStrings("api", copy.maybe.?.name);
    try testing.expectEqualStrings("x", copy.kind.one);
}

test "partialFailureText: every group, one of several, some of several" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", partialFailureText(&buf, 0, 2, "repos", "api", "HTTP 500"));
    try testing.expectEqualStrings("network error", partialFailureText(&buf, 2, 2, "repos", "api", "network error"));
    try testing.expectEqualStrings("web: HTTP 500", partialFailureText(&buf, 1, 3, "repos", "web", "HTTP 500"));
    try testing.expectEqualStrings("2 of 5 repos: HTTP 500", partialFailureText(&buf, 2, 5, "repos", "web", "HTTP 500"));
}
