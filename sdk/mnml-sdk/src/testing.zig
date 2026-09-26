//! Test allocators an integration's suite borrows.
//!
//! Nothing here ships: it is the machinery a pane's tests need to see a
//! lifetime bug, which the normal allocators go out of their way to
//! hide.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An allocator that writes `0xAA` over everything it frees, in every
/// build mode, and hands the call on to a child.
///
/// Nothing else does. `Allocator.free`'s own poison is `undefined`,
/// which a release build is free to skip, and an arena gives its pages
/// back through `rawFree`, which never poisons at all — so a slice of
/// freed memory goes on reading correctly until something else claims
/// the page.
///
/// That is precisely how this family of bugs hides. A job's result
/// carries its own arena; the pane reads a string out of it and keeps
/// the SLICE rather than the arena, and `commit` lets the arena go on
/// the way out. The rows read right for minutes before they don't.
/// Without a scribbling allocator underneath, a test written for that
/// passes whatever the code does — which is the whole reason this file
/// exists rather than a comment saying "be careful".
///
/// Put it under the FETCH side of a test rig — the HTTP client, the
/// worker, and every arena a job or a result makes — and the first read
/// of a let-go result is `0xAA`, not the right answer by luck:
///
/// ```zig
/// var scribble: sdk.testing.Scribble = .{ .child = std.testing.allocator };
/// const r = try Rig.initOn(cfg, .{}, scribble.allocator());
/// ```
///
/// The child is still whatever was passed in, so `std.testing.allocator`
/// underneath keeps reporting leaks and double frees as it always did.
pub const Scribble = struct {
    child: Allocator,

    pub fn allocator(s: *Scribble) Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *Scribble = @ptrCast(@alignCast(ctx));
        return s.child.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const s: *Scribble = @ptrCast(@alignCast(ctx));
        if (!s.child.rawResize(mem, a, new_len, ra)) return false;
        // The tail a shrink gives back is freed memory too.
        if (new_len < mem.len) @memset(mem[new_len..], 0xAA);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const s: *Scribble = @ptrCast(@alignCast(ctx));
        return s.child.rawRemap(mem, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const s: *Scribble = @ptrCast(@alignCast(ctx));
        @memset(mem, 0xAA);
        s.child.rawFree(mem, a, ra);
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "what an arena gives back is poisoned, in every build mode" {
    // The child is an arena so the pages stay mapped after the free:
    // reading freed memory is the thing being demonstrated, and a
    // page-returning allocator underneath would fault instead of
    // showing what is in it.
    var backing = std.heap.ArenaAllocator.init(t.allocator);
    defer backing.deinit();
    var scribble: Scribble = .{ .child = backing.allocator() };
    var arena = std.heap.ArenaAllocator.init(scribble.allocator());
    const said = try arena.allocator().dupe(u8, "Fix the login redirect");
    try t.expectEqualStrings("Fix the login redirect", said);
    // The shape of the bug: the slice is kept, the arena is let go.
    arena.deinit();
    // An arena hands its pages back through `rawFree`, which poisons
    // nothing — this is the read that used to come back correct.
    for (said) |b| try t.expectEqual(@as(u8, 0xAA), b);
}

test "a plain free is poisoned too, and the child still sees every call" {
    var backing = std.heap.ArenaAllocator.init(t.allocator);
    defer backing.deinit();
    var scribble: Scribble = .{ .child = backing.allocator() };
    const gpa = scribble.allocator();
    const buf = try gpa.alloc(u8, 32);
    @memset(buf, 'x');
    gpa.free(buf);
    for (buf) |b| try t.expectEqual(@as(u8, 0xAA), b);
}

test "the child is still underneath: a leak through Scribble is a leak" {
    // What a suite relies on — `std.testing.allocator` keeps its own
    // accounting when it is the child, so a fix that forgets a `deinit`
    // still fails rather than being swallowed by the wrapper.
    var scribble: Scribble = .{ .child = t.allocator };
    const gpa = scribble.allocator();
    const buf = try gpa.alloc(u8, 32);
    gpa.free(buf);
}

/// `got`, a path the code built, is `want`, spelled with `/`. Windows
/// takes either separator and `std.fs.path.join` writes `\`, so there
/// both sides are read with every `\` as `/` — a path test states where
/// a file goes, and the separator is the platform's business.
pub fn expectPath(want: []const u8, got: []const u8) !void {
    if (@import("builtin").os.tag != .windows) return std.testing.expectEqualStrings(want, got);
    const w = try slashed(want);
    defer std.testing.allocator.free(w);
    const g = try slashed(got);
    defer std.testing.allocator.free(g);
    return std.testing.expectEqualStrings(w, g);
}

/// `got` ends with `suffix`, spelled with `/`, read as `expectPath` reads.
pub fn pathEndsWith(got: []const u8, suffix: []const u8) bool {
    if (@import("builtin").os.tag != .windows) return std.mem.endsWith(u8, got, suffix);
    const g = slashed(got) catch return false;
    defer std.testing.allocator.free(g);
    return std.mem.endsWith(u8, g, suffix);
}

/// `got` holds `needle`, spelled with `/`, read as `expectPath` reads.
pub fn pathContains(got: []const u8, needle: []const u8) bool {
    if (@import("builtin").os.tag != .windows) return std.mem.indexOf(u8, got, needle) != null;
    const g = slashed(got) catch return false;
    defer std.testing.allocator.free(g);
    return std.mem.indexOf(u8, g, needle) != null;
}

fn slashed(p: []const u8) Allocator.Error![]u8 {
    const out = try std.testing.allocator.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

test "a path compares with its separators read as the platform writes them" {
    const joined = try std.fs.path.join(std.testing.allocator, &.{ "/data", "ratelimit", "x.json" });
    defer std.testing.allocator.free(joined);
    try expectPath("/data/ratelimit/x.json", joined);
    try std.testing.expect(pathEndsWith(joined, "/ratelimit/x.json"));
    try std.testing.expect(pathContains(joined, "/ratelimit/"));
    try std.testing.expect(!pathEndsWith(joined, "/other.json"));
}
