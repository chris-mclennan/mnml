//! Bench: N sends of one request, the latencies sorted, percentiles
//! and a status-class breakdown, a histogram, the first few errors —
//! rendered as the trace `http.bench` puts on the clipboard.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Sample = struct {
    ms: u64,
    /// 0 for a transport failure.
    status: u16,
};

pub const Stats = struct {
    min: u64 = 0,
    p50: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    max: u64 = 0,
    mean: u64 = 0,
    ok: usize = 0,
    failed: usize = 0,
};

/// Nearest-rank on the sorted latencies (rounded), as the Rust bench did.
pub fn stats(samples: []const Sample) Stats {
    if (samples.len == 0) return .{};
    var sorted: [4096]u64 = undefined;
    const n = @min(samples.len, sorted.len);
    for (samples[0..n], 0..) |s, i| sorted[i] = s.ms;
    std.mem.sort(u64, sorted[0..n], {}, std.sort.asc(u64));
    var sum: u64 = 0;
    var ok: usize = 0;
    var failed: usize = 0;
    for (samples) |s| {
        sum += s.ms;
        if (s.status == 0) failed += 1 else if (s.status < 400) ok += 1;
    }
    const pick = struct {
        fn f(list: []const u64, q: f64) u64 {
            const idx: usize = @intFromFloat(@round(@as(f64, @floatFromInt(list.len - 1)) * q));
            return list[@min(idx, list.len - 1)];
        }
    }.f;
    return .{
        .min = sorted[0],
        .p50 = pick(sorted[0..n], 0.50),
        .p95 = pick(sorted[0..n], 0.95),
        .p99 = pick(sorted[0..n], 0.99),
        .max = sorted[n - 1],
        .mean = sum / samples.len,
        .ok = ok,
        .failed = failed,
    };
}

/// The full trace: headline, latency line, status classes, a histogram,
/// the errors.
pub fn report(arena: Allocator, url: []const u8, samples: []const Sample, errors: []const []const u8, wall_ms: u64) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const st = stats(samples);
    try appendFmt(arena, &out, "bench {s}\n  {d} request(s) in {d} ms wall\n", .{ url, samples.len, wall_ms });
    try appendFmt(arena, &out, "  latency ms — min {d} · p50 {d} · p95 {d} · p99 {d} · max {d} · mean {d}\n", .{ st.min, st.p50, st.p95, st.p99, st.max, st.mean });
    try out.appendSlice(arena, "  status:");
    var classes = @as([6]usize, @splat(0));
    for (samples) |s| classes[@min(s.status / 100, 5)] += 1;
    for (classes, 0..) |count, class| {
        if (count == 0) continue;
        if (class == 0) try appendFmt(arena, &out, " ERR={d}", .{count}) else try appendFmt(arena, &out, " {d}xx={d}", .{ class, count });
    }
    try out.append(arena, '\n');
    if (samples.len > 0 and st.max > 0) {
        const buckets: usize = 6;
        var counts = @as([6]usize, @splat(0));
        const span = st.max - st.min + 1;
        for (samples) |s| counts[@min((s.ms - st.min) * buckets / span, buckets - 1)] += 1;
        var b: usize = 0;
        while (b < buckets) : (b += 1) {
            const lo = st.min + span * b / buckets;
            const hi = st.min + span * (b + 1) / buckets;
            const bar_w: usize = @min(counts[b] * 20 / @max(samples.len, 1), 20);
            try appendFmt(arena, &out, "    {d:>5}–{d:<5} ms │", .{ lo, hi });
            var i: usize = 0;
            while (i < 20) : (i += 1) try out.appendSlice(arena, if (i < bar_w) "█" else " ");
            try appendFmt(arena, &out, "│ {d}\n", .{counts[b]});
        }
    }
    if (errors.len > 0) {
        try appendFmt(arena, &out, "  errors: {d} (showing up to 3)\n", .{st.failed});
        for (errors[0..@min(errors.len, 3)]) |e| try appendFmt(arena, &out, "    {s}\n", .{e});
    }
    return out.toOwnedSlice(arena);
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "percentiles are nearest-rank on the sorted latencies; the report names them" {
    const samples = [_]Sample{ .{ .ms = 50, .status = 200 }, .{ .ms = 10, .status = 200 }, .{ .ms = 30, .status = 500 }, .{ .ms = 20, .status = 0 }, .{ .ms = 40, .status = 200 } };
    const st = stats(&samples);
    try testing.expectEqual(@as(u64, 30), st.p50);
    try testing.expectEqual(@as(u64, 50), st.p95);
    try testing.expectEqual(@as(u64, 50), st.p99);
    try testing.expectEqual(@as(u64, 10), st.min);
    try testing.expectEqual(@as(u64, 30), st.mean);
    try testing.expectEqual(@as(usize, 3), st.ok);
    try testing.expectEqual(@as(usize, 1), st.failed);
    const text = try report(testing.allocator, "http://x", &samples, &.{"connection failed"}, 77);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "p50 30") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ERR=1 2xx=3 5xx=1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "errors: 1") != null);
    try testing.expectEqual(@as(u64, 0), stats(&.{}).p50);
}
