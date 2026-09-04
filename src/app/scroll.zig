//! Wheel coalescing. A trackpad or a free-spinning wheel on macOS posts
//! thirty-odd scroll events per flick, and ghostty triples a notched
//! wheel's reports; dispatching each one — a frame per event — is what
//! made the Rust app keep scrolling for a second after the finger
//! lifted. The `Coalescer` folds a run of same-direction wheel events
//! into one motion with a count, capped so a stuck wheel cannot scroll
//! a thousand lines in one go.
//!
//! The policy is the whole of it: `App.handle` offers every mouse event
//! here first; a wheel event in the same direction at the same cell is
//! absorbed, a bare motion report is dropped (they interleave with
//! every burst), and anything else makes the app flush the batch before
//! it handles the new event — so a click after a flick still lands
//! after the scroll. `App.tick` flushes what is left.

const std = @import("std");
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;

/// The most a batch grows to before it is dispatched as is.
pub const cap: u16 = 40;

pub const Batch = struct { mouse: Mouse, count: u16 };

pub const Coalescer = struct {
    pending: ?Batch = null,

    /// True when `m` was absorbed (a wheel event folded into the batch,
    /// or a motion report dropped); false when the caller must flush
    /// the batch and handle `m` itself.
    pub fn offer(c: *Coalescer, m: Mouse) bool {
        const is_wheel = m.kind == .scroll_up or m.kind == .scroll_down;
        if (!is_wheel) {
            // Motion reports interleave with every burst; a batch that
            // stopped at each would barely coalesce.
            return m.kind == .motion and c.pending != null;
        }
        if (c.pending) |*p| {
            const same = p.mouse.kind == m.kind and p.mouse.mods.eql(m.mods) and p.mouse.x == m.x and p.mouse.y == m.y;
            if (same and p.count < cap) {
                p.count += 1;
                return true;
            }
            return false;
        }
        c.pending = .{ .mouse = m, .count = 1 };
        return true;
    }

    /// The batch, if one is pending; the coalescer is empty after.
    pub fn take(c: *Coalescer) ?Batch {
        defer c.pending = null;
        return c.pending;
    }
};

// ── tests ──

const testing = std.testing;

fn wheel(kind: key_mod.MouseKind, x: u16) Mouse {
    return .{ .x = x, .y = 5, .kind = kind };
}

test "a same-direction burst folds into one batch with its count; the cap stops it" {
    var c: Coalescer = .{};
    try testing.expect(c.take() == null);
    var i: usize = 0;
    while (i < 30) : (i += 1) try testing.expect(c.offer(wheel(.scroll_down, 4)));
    const b = c.take().?;
    try testing.expectEqual(@as(u16, 30), b.count);
    try testing.expect(b.mouse.kind == .scroll_down);
    try testing.expect(c.take() == null);
    i = 0;
    while (i < cap) : (i += 1) try testing.expect(c.offer(wheel(.scroll_up, 4)));
    // The forty-first must be flushed first.
    try testing.expect(!c.offer(wheel(.scroll_up, 4)));
    try testing.expectEqual(cap, c.take().?.count);
}

test "a direction change, another cell or a click ends the batch; motions are dropped" {
    var c: Coalescer = .{};
    try testing.expect(c.offer(wheel(.scroll_down, 4)));
    try testing.expect(c.offer(.{ .x = 9, .y = 9, .kind = .motion }));
    try testing.expect(!c.offer(wheel(.scroll_up, 4)));
    try testing.expectEqual(@as(u16, 1), c.take().?.count);
    try testing.expect(c.offer(wheel(.scroll_up, 4)));
    try testing.expect(!c.offer(wheel(.scroll_up, 5)));
    _ = c.take();
    try testing.expect(c.offer(wheel(.scroll_down, 4)));
    try testing.expect(!c.offer(.{ .x = 4, .y = 5, .kind = .press, .button = .left }));
    _ = c.take();
    // With nothing pending a motion is the caller's to handle (hover).
    try testing.expect(!c.offer(.{ .x = 1, .y = 1, .kind = .motion }));
    // Shift+wheel is a different batch from a plain one.
    try testing.expect(c.offer(wheel(.scroll_down, 4)));
    try testing.expect(!c.offer(.{ .x = 4, .y = 5, .kind = .scroll_down, .mods = .{ .shift = true } }));
}
