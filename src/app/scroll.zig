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

// ── acceleration ──
//
// The Rust app's `budgeted_scroll_at` (`src/app/dispatch.rs`, #1236),
// arithmetic kept as is so the same run of events moves the same
// number of lines: the multiplier ramps on the wheel's RATE (events
// per second, batch / gap) from 1.0 below 45/s to the setting's
// ceiling at 120/s; a gap over 250 ms starts a new gesture with no
// inherited speed, so a single notch after a pause is always 1:1; a
// rate that falls under half the gesture's peak is a free-spinning
// wheel decaying, which is never amplified (it travels one line per
// event and dies with the wheel); the sub-line remainder carries
// across the gesture so `gentle` (×1.5) is not floored back to `off`;
// a leaky bucket of 40 × ceiling lines refilled at 60/s bounds a
// flick, and a real event always moves at least one line so a hand on
// the wheel never sees the view stand still. `off` is a true bypass:
// no rate, no carry, the plain bucket — and that path can spend 0 when
// the bucket is dry, as the Rust one does.

const Config = @import("../config/Config.zig");
pub const Setting = Config.ScrollAccel;

const bucket_max: f32 = 40.0;
const bucket_refill_per_s: f32 = 60.0;
const accel_full_rate: f32 = 120.0;
const accel_floor_rate: f32 = 45.0;
const gesture_gap_ms: i64 = 250;
/// A list surface moves at most this many rows per batch at `off`;
/// the cap scales with the setting so acceleration is not clamped
/// away (`listStep`).
const list_cap: u16 = 8;
/// The tree steps one row per notch: events inside this window belong
/// to the notch already handled (ghostty reports a detent as three).
pub const tree_notch_window_ms: i64 = 60;

/// How much further a hard spin travels than a slow one.
pub fn ceiling(s: Setting) f32 {
    return switch (s) {
        .off => 1.0,
        .gentle => 1.5,
        .normal => 2.5,
        .fast => 4.0,
    };
}

/// Rust `list_scroll_clamp_scaled`: a batch's (budgeted) count clamped
/// to a per-batch cap for a list surface, so one batch cannot teleport
/// the cursor across hundreds of rows.
pub fn listStep(batch: u16, s: Setting) u16 {
    const scaled: u16 = @intFromFloat(@round(@as(f32, list_cap) * ceiling(s)));
    return @min(batch, @max(scaled, list_cap));
}

pub const Accel = struct {
    last_event_ms: ?i64 = null,
    peak_rate: f32 = 0,
    decaying: bool = false,
    carry: f32 = 0,
    row_accum: f32 = 0,
    bucket: f32 = 0,
    bucket_last_ms: ?i64 = null,
    /// The multiplier the last batch got; the tree derives its rows
    /// from it.
    last_factor: f32 = 1.0,
    tree_last_step_ms: ?i64 = null,

    /// The lines `batch` events landing at `now_ms` may move.
    pub fn apply(a: *Accel, s: Setting, batch: u16, now_ms: i64) u16 {
        if (batch == 0) return 0;
        const ceil = ceiling(s);
        const want_raw: f32 = @floatFromInt(batch);
        const gap_ms: ?i64 = if (a.last_event_ms) |t| now_ms - t else null;
        a.last_event_ms = now_ms;
        const new_gesture = gap_ms == null or gap_ms.? > gesture_gap_ms;
        const rate: f32 = if (new_gesture) 0.0 else blk: {
            const secs = @max(@as(f32, @floatFromInt(@max(gap_ms.?, 0))) / 1000.0, 0.001);
            break :blk want_raw / secs;
        };
        if (new_gesture) {
            a.peak_rate = 0;
            a.decaying = false;
            a.carry = 0;
            a.row_accum = 0;
        }
        const full = bucket_max * @max(ceil, 1.0);
        if (a.bucket_last_ms) |prev| {
            const elapsed = @as(f32, @floatFromInt(@max(now_ms - prev, 0))) / 1000.0;
            a.bucket = @min(a.bucket + elapsed * bucket_refill_per_s, full);
        } else {
            a.bucket = full;
        }
        a.bucket_last_ms = now_ms;
        if (ceil <= 1.0) {
            const spend = @floor(@min(want_raw, a.bucket));
            a.bucket -= spend;
            a.last_factor = 1.0;
            return @intFromFloat(spend);
        }
        if (rate > a.peak_rate) {
            a.peak_rate = rate;
        } else if (a.peak_rate > 0 and rate < a.peak_rate * 0.5) {
            a.decaying = true;
        }
        const ramp = std.math.clamp((rate - accel_floor_rate) / (accel_full_rate - accel_floor_rate), 0.0, 1.0);
        const factor: f32 = if (a.decaying) 1.0 else 1.0 + (ceil - 1.0) * ramp;
        a.last_factor = factor;
        const want = want_raw * factor;
        const wanted = want + a.carry;
        var spend = @floor(@min(wanted, a.bucket));
        if (spend < 1.0) spend = 1.0;
        a.carry = std.math.clamp(wanted - spend, 0.0, 1.0);
        a.bucket = @max(a.bucket - spend, 0.0);
        return @intFromFloat(spend);
    }

    /// The next batch starts a gesture of its own, whatever the clock
    /// says: the `.test` / IPC drivers post one notch per step and a
    /// script's notches are deliberate, not a spin.
    pub fn endGesture(a: *Accel) void {
        a.last_event_ms = null;
    }

    /// The rows the tree steps for one batch (Rust: one row per NOTCH).
    /// With acceleration off a batch inside the notch window of the
    /// last step is the same notch and moves nothing; on, the rows come
    /// from the factor the batch got — accumulated, so a factor of 2.5
    /// alternates 2 and 3 rather than jumping 2 every time.
    pub fn treeRows(a: *Accel, s: Setting, now_ms: i64) u16 {
        const on = ceiling(s) > 1.0;
        if (!on) {
            if (a.tree_last_step_ms) |t| if (now_ms - t < tree_notch_window_ms) return 0;
            a.tree_last_step_ms = now_ms;
            return 1;
        }
        a.tree_last_step_ms = now_ms;
        a.row_accum += @max(a.last_factor, 1.0);
        const rows = @max(@floor(a.row_accum), 1.0);
        a.row_accum -= rows;
        return @intFromFloat(rows);
    }
};

// ── accel tests ──
//
// The runs and their totals are the Rust function's, computed by
// running its arithmetic over the same event timings
// (`docs/research/scroll-tuning.md` has the table); a change here that
// moves a number is a change in feel.

const Run = struct { gaps: []const i64, batch: u16 = 1 };

fn total(s: Setting, run: Run) u32 {
    var a: Accel = .{};
    var t: i64 = 1000;
    var sum: u32 = 0;
    for (run.gaps) |g| {
        t += g;
        sum += a.apply(s, run.batch, t);
    }
    return sum;
}

fn perEvent(s: Setting, run: Run, out: []u16) void {
    var a: Accel = .{};
    var t: i64 = 1000;
    for (run.gaps, 0..) |g, i| {
        t += g;
        out[i] = a.apply(s, run.batch, t);
    }
}

test "accel table: the Rust function's line counts, per setting, for the same event runs" {
    const all = [_]Setting{ .off, .gentle, .normal, .fast };
    // A single slow notch is 1:1 at every setting; a slow scroll stays 1:1.
    for (all) |s| {
        try testing.expectEqual(@as(u32, 4), total(s, .{ .gaps = &.{ 400, 400, 400, 400 } }));
        try testing.expectEqual(@as(u32, 10), total(s, .{ .gaps = &(@as([10]i64, @splat(120))) }));
    }
    // A hard spin (8 ms gaps ≈ 125/s) travels further as the setting rises.
    const spin: Run = .{ .gaps = &(@as([10]i64, @splat(8))) };
    try testing.expectEqual(@as(u32, 10), total(.off, spin));
    try testing.expectEqual(@as(u32, 14), total(.gentle, spin));
    try testing.expectEqual(@as(u32, 23), total(.normal, spin));
    try testing.expectEqual(@as(u32, 37), total(.fast, spin));
    var per: [10]u16 = undefined;
    perEvent(.normal, spin, &per);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 2, 3, 2, 3, 2, 3, 2 }, &per);
    perEvent(.fast, spin, &per);
    try testing.expectEqualSlices(u16, &.{ 1, 4, 4, 4, 4, 4, 4, 4, 4, 4 }, &per);
    // Mid-ramp (10 ms ≈ 100/s).
    const mid: Run = .{ .gaps = &(@as([10]i64, @splat(10))) };
    try testing.expectEqual(@as(u32, 10), total(.off, mid));
    try testing.expectEqual(@as(u32, 13), total(.gentle, mid));
    try testing.expectEqual(@as(u32, 19), total(.normal, mid));
    try testing.expectEqual(@as(u32, 29), total(.fast, mid));
    // ghostty's detents: three events 8 ms apart, 150 ms between detents.
    // Only the first detent's burst is amplified; the 150 ms gap reads
    // as the rate collapsing, so the rest travel 1:1 until a pause.
    const detents: Run = .{ .gaps = &.{ 150, 8, 8, 150, 8, 8, 150, 8, 8, 150, 8, 8 } };
    try testing.expectEqual(@as(u32, 12), total(.off, detents));
    try testing.expectEqual(@as(u32, 13), total(.gentle, detents));
    try testing.expectEqual(@as(u32, 15), total(.normal, detents));
    try testing.expectEqual(@as(u32, 18), total(.fast, detents));
    // The same detents already folded: a batch of 3 at 150 ms is slow.
    for (all) |s| try testing.expectEqual(@as(u32, 12), total(s, .{ .gaps = &.{ 150, 150, 150, 150 }, .batch = 3 }));
    // A tick's worth of burst (30 events in one batch) then five more.
    const burst: Run = .{ .gaps = &.{ 0, 16, 16, 16, 16, 16 }, .batch = 30 };
    try testing.expectEqual(@as(u32, 44), total(.off, burst));
    try testing.expectEqual(@as(u32, 64), total(.gentle, burst));
    try testing.expectEqual(@as(u32, 104), total(.normal, burst));
    try testing.expectEqual(@as(u32, 164), total(.fast, burst));
    var per6: [6]u16 = undefined;
    perEvent(.normal, burst, &per6);
    try testing.expectEqualSlices(u16, &.{ 30, 70, 1, 1, 1, 1 }, &per6);
}

test "accel: a decaying tail is never amplified, a pause resets, jitter does not trip the detector" {
    const tail: Run = .{ .gaps = &.{ 8, 8, 8, 8, 8, 8, 8, 8, 20, 30, 45, 60, 90, 130, 180 } };
    try testing.expectEqual(@as(u32, 25), total(.normal, tail));
    try testing.expectEqual(@as(u32, 36), total(.fast, tail));
    var per: [15]u16 = undefined;
    perEvent(.fast, tail, &per);
    try testing.expectEqualSlices(u16, &.{ 1, 4, 4, 4, 4, 4, 4, 4, 1, 1, 1, 1, 1, 1, 1 }, &per);
    // Hand back on the wheel after 900 ms: the second gesture spins again.
    const again: Run = .{ .gaps = &.{ 8, 8, 8, 8, 8, 8, 30, 60, 120, 900, 8, 8, 8, 8, 8, 8 } };
    try testing.expectEqual(@as(u32, 32), total(.normal, again));
    try testing.expectEqual(@as(u32, 49), total(.fast, again));
    // Steady scrolling with ±25 % jitter is not a stop.
    const jitter: Run = .{ .gaps = &.{ 20, 24, 18, 22, 26, 19, 21, 25, 20, 23 } };
    try testing.expectEqual(@as(u32, 10), total(.normal, jitter));
    try testing.expectEqual(@as(u32, 11), total(.fast, jitter));
    // Time passing moves nothing: no call, no lines.
}

test "accel: sustained scrolling never starves on the accelerated paths; off can run the bucket dry" {
    // 400 batches of 3 at 100/s (the tester's run): every accelerated
    // setting moves at least one line per event; `off` is Rust's bypass
    // and spends 0 once the bucket is dry.
    var zero: [4]u32 = .{ 0, 0, 0, 0 };
    var sum: [4]u32 = .{ 0, 0, 0, 0 };
    for ([_]Setting{ .off, .gentle, .normal, .fast }, 0..) |s, i| {
        var a: Accel = .{};
        var t: i64 = 1000;
        for (0..400) |_| {
            t += 10;
            const got = a.apply(s, 3, t);
            if (got == 0) zero[i] += 1;
            sum[i] += got;
        }
    }
    try testing.expectEqualSlices(u32, &.{ 279, 452, 493, 553 }, &sum);
    try testing.expect(zero[0] > 0);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, zero[1..]);
    // Ten seconds at 40/s: the last 100 of 400 events still move, at every setting.
    for ([_]Setting{ .off, .gentle, .normal, .fast }) |s| {
        var a: Accel = .{};
        var t: i64 = 1000;
        var late: u32 = 0;
        for (0..400) |i| {
            t += 25;
            const got = a.apply(s, 1, t);
            if (i >= 300) late += got;
        }
        try testing.expectEqual(@as(u32, 100), late);
    }
}

test "listStep caps a batch per setting; the default is normal" {
    try testing.expectEqual(@as(u16, 8), listStep(40, .off));
    try testing.expectEqual(@as(u16, 12), listStep(40, .gentle));
    try testing.expectEqual(@as(u16, 20), listStep(40, .normal));
    try testing.expectEqual(@as(u16, 32), listStep(40, .fast));
    for ([_]Setting{ .off, .gentle, .normal, .fast }) |s| try testing.expectEqual(@as(u16, 5), listStep(5, s));
    // The shipped default is a feel decision; a flip is deliberate.
    const c: Config = .{};
    try testing.expectEqual(Setting.normal, c.editor.scroll_accel);
}

test "treeRows: one row per notch with accel off, rows from the factor with it on" {
    var a: Accel = .{};
    // Off: a second batch 20 ms after the first is the same notch.
    try testing.expectEqual(@as(u16, 1), a.treeRows(.off, 1000));
    try testing.expectEqual(@as(u16, 0), a.treeRows(.off, 1020));
    try testing.expectEqual(@as(u16, 0), a.treeRows(.off, 1059));
    try testing.expectEqual(@as(u16, 1), a.treeRows(.off, 1060));
    // On: a slow notch (factor 1) is one row; a fast spin's factor
    // accumulates — 2.5 alternates 2 and 3.
    var b: Accel = .{};
    _ = b.apply(.normal, 1, 1000);
    try testing.expectEqual(@as(u16, 1), b.treeRows(.normal, 1000));
    _ = b.apply(.normal, 1, 1008);
    try testing.expectEqual(@as(u16, 2), b.treeRows(.normal, 1008));
    _ = b.apply(.normal, 1, 1016);
    try testing.expectEqual(@as(u16, 3), b.treeRows(.normal, 1016));
    // endGesture: the next batch is 1:1 whatever the clock says.
    b.endGesture();
    try testing.expectEqual(@as(u16, 1), b.apply(.normal, 1, 1024));
}
