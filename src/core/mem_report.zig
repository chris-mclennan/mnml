//! `-Dmem-report`: where the process's memory is, measured rather than
//! guessed. Two counters — every byte live through the app's allocator,
//! and every byte live inside the tree-sitter runtime (its own malloc,
//! routed here through `ts_set_allocator`) — each with its peak, plus a
//! tally of the parse jobs, so a tree-sitter figure can be read as "one
//! tree is this big" rather than "trees are piling up". The
//! per-document breakdown (text, saved copy, line index, undo, redo) is
//! structural and lives with the app (`app/driver.zig` prints the table
//! to stderr as a headless session ends).
//!
//! Off by default: the wrapper and the hooks are not installed, and
//! nothing here costs anything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const enabled: bool = build_options.mem_report;

pub const Counter = struct {
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn add(c: *Counter, n: usize) void {
        const now = c.live.fetchAdd(n, .monotonic) + n;
        var p = c.peak.load(.monotonic);
        while (now > p) p = c.peak.cmpxchgWeak(p, now, .monotonic, .monotonic) orelse break;
    }

    fn sub(c: *Counter, n: usize) void {
        _ = c.live.fetchSub(n, .monotonic);
    }
};

pub var app: Counter = .{};
pub var tree_sitter: Counter = .{};

/// Parse-job bookkeeping. `started` minus `posted` is what is still
/// parsing; `adopted` minus `disposed` is how many trees are held; a
/// gap between `asked` and `done` is a replaced tree still queued for
/// the thread that frees it. Only touched when `enabled`.
pub const Tally = struct {
    jobs_started: std.atomic.Value(u64) = .init(0),
    jobs_posted: std.atomic.Value(u64) = .init(0),
    results_adopted: std.atomic.Value(u64) = .init(0),
    results_dropped: std.atomic.Value(u64) = .init(0),
    disposals_asked: std.atomic.Value(u64) = .init(0),
    disposals_done: std.atomic.Value(u64) = .init(0),

    pub fn bump(v: *std.atomic.Value(u64)) void {
        if (!enabled) return;
        _ = v.fetchAdd(1, .monotonic);
    }
};

pub var tally: Tally = .{};

/// Wraps the process allocator; every byte through it is counted.
pub const Counting = struct {
    child: Allocator,

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        app.add(len);
        noteLarge("alloc", len, ra);
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(buf, alignment, new_len, ra)) return false;
        if (new_len >= buf.len) app.add(new_len - buf.len) else app.sub(buf.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(buf, alignment, new_len, ra) orelse return null;
        if (new_len > buf.len) noteLarge("grow", new_len, ra);
        if (new_len >= buf.len) app.add(new_len - buf.len) else app.sub(buf.len - new_len);
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
        app.sub(buf.len);
    }
};

/// A single block this large is worth a name: who asked for it.
const large_bytes = 48 << 20;

fn noteLarge(what: []const u8, len: usize, ra: usize) void {
    if (len < large_bytes) return;
    std.debug.print("mem-report: {s} {d} MB (app live {d} MB) from:\n", .{ what, mb(len), mb(app.live.load(.monotonic)) });
    std.debug.dumpCurrentStackTrace(.{ .first_address = ra });
}

// ── the tree-sitter runtime's malloc ──
// A 16-byte header in front of each block remembers its size, so `free`
// and `realloc` can account for what they let go.

const header = 16;

fn tsMalloc(n: usize) callconv(.c) ?*anyopaque {
    const raw: [*]u8 = @ptrCast(std.c.malloc(n + header) orelse return null);
    @as(*usize, @ptrCast(@alignCast(raw))).* = n;
    tree_sitter.add(n);
    return raw + header;
}

fn tsCalloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const n = count * size;
    const p = tsMalloc(n) orelse return null;
    @memset(@as([*]u8, @ptrCast(p))[0..n], 0);
    return p;
}

fn tsRealloc(p: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque {
    const old = p orelse return tsMalloc(n);
    const raw_old = @as([*]u8, @ptrCast(old)) - header;
    const old_n = @as(*usize, @ptrCast(@alignCast(raw_old))).*;
    const raw: [*]u8 = @ptrCast(std.c.realloc(raw_old, n + header) orelse return null);
    @as(*usize, @ptrCast(@alignCast(raw))).* = n;
    if (n >= old_n) tree_sitter.add(n - old_n) else tree_sitter.sub(old_n - n);
    return raw + header;
}

fn tsFree(p: ?*anyopaque) callconv(.c) void {
    const old = p orelse return;
    const raw = @as([*]u8, @ptrCast(old)) - header;
    tree_sitter.sub(@as(*usize, @ptrCast(@alignCast(raw))).*);
    std.c.free(raw);
}

extern fn ts_set_allocator(
    new_malloc: ?*const fn (usize) callconv(.c) ?*anyopaque,
    new_calloc: ?*const fn (usize, usize) callconv(.c) ?*anyopaque,
    new_realloc: ?*const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    new_free: ?*const fn (?*anyopaque) callconv(.c) void,
) void;

/// Route the tree-sitter runtime's allocations through the counter.
/// Before the first parser exists, or blocks cross allocators.
pub fn installTreeSitter() void {
    ts_set_allocator(tsMalloc, tsCalloc, tsRealloc, tsFree);
}

pub fn mb(n: usize) usize {
    return (n + (1 << 19)) >> 20;
}
