//! The pane's hit map — what the frame's cells mean to a click, written
//! by the painter in the same statement as the cells. A target covers
//! exactly what it paints: a row is its row, a chip its cells, a chevron
//! its one cell, a hint entry its `key label`. Dispatch is one lookup;
//! the last thing painted wins, so an overlay drawn after the body takes
//! the click.
//!
//! `Map` is generic over the pane's own target union, so an integration
//! keeps its vocabulary and shares the bookkeeping.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(r: Rect, x: u16, y: u16) bool {
        return x >= r.x and x < r.x +| r.w and y >= r.y and y < r.y +| r.h;
    }

    pub fn right(r: Rect) u16 {
        return r.x +| r.w;
    }

    pub fn bottom(r: Rect) u16 {
        return r.y +| r.h;
    }

    pub fn isEmpty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }
};

/// The cells one build line's click covers.
///
/// Both official panes paint the toolkit's build line, both know the
/// page it stands for, and on neither of them did a click go there:
/// the tracker pane painted it as a free row and the forge pane as a
/// cell of its table, and both fell through to the generic row hit,
/// which selects. The line read as a link in two panes and behaved as
/// one in neither.
///
/// The door is the WHOLE line — from the row's own left edge to
/// `right_edge` — so the indent left of the caption and the air right
/// of it are part of it rather than dead cells the pointer has to
/// find its way between. A pane whose build line is a table cell
/// registers this rect AFTER its table has painted; the map's
/// last-painted-wins rule then puts the door over the row.
///
/// `right_edge` is the first column the pane does NOT own — a list's
/// scrollbar column, or the detail panel's left edge — so the door
/// never reaches under furniture painted beside it.
pub fn buildHit(row: Rect, right_edge: u16) Rect {
    if (right_edge <= row.x) return .{ .x = row.x, .y = row.y, .w = 0, .h = 0 };
    return .{ .x = row.x, .y = row.y, .w = @min(row.w, right_edge - row.x), .h = 1 };
}

/// Is there a pointer anywhere inside `T`?
fn hasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |o| hasPointer(o.child),
        .array => |a| hasPointer(a.child),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (hasPointer(f.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            inline for (u.fields) |f| {
                if (hasPointer(f.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn Map(comptime Target: type) type {
    // A target is indices and enums, never a string.
    //
    // The map's entries live on the GPA and are only `reset` at the top
    // of the NEXT frame, while a click is dispatched from `at()`
    // BETWEEN frames — after the pane's frame arena has been reset. A
    // `Target` carrying a `[]const u8` from that arena would therefore
    // dangle at exactly the moment it is read, which is the family of
    // bug `docs/SDK.md` → "Results outlive the job" is about. It would
    // also break `rectOf` silently: `std.meta.eql` compares slices by
    // pointer, so a test that clicks by meaning would stop finding its
    // target for a reason nothing names.
    //
    // Neither shipped pane does this today. This is the tripwire, not a
    // report of a bug: say what you mean with an index into the frame's
    // own rows.
    comptime std.debug.assert(!hasPointer(Target));
    return struct {
        const Self = @This();

        pub const Entry = struct { rect: Rect, target: Target };

        items: std.ArrayList(Entry) = .empty,

        pub fn deinit(m: *Self, gpa: Allocator) void {
            m.items.deinit(gpa);
        }

        /// The top of a frame: nothing is registered yet.
        pub fn reset(m: *Self) void {
            m.items.clearRetainingCapacity();
        }

        pub fn add(m: *Self, gpa: Allocator, rect: Rect, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            try m.items.append(gpa, .{ .rect = rect, .target = target });
        }

        /// Back to front: the last painted wins.
        pub fn at(m: *const Self, x: u16, y: u16) ?Target {
            var i = m.items.items.len;
            while (i > 0) {
                i -= 1;
                const e = m.items.items[i];
                if (e.rect.contains(x, y)) return e.target;
            }
            return null;
        }

        /// Where a target painted, for a test that clicks by meaning.
        pub fn rectOf(m: *const Self, target: Target) ?Rect {
            var i = m.items.items.len;
            while (i > 0) {
                i -= 1;
                const e = m.items.items[i];
                if (std.meta.eql(e.target, target)) return e.rect;
            }
            return null;
        }

        pub fn count(m: *const Self) usize {
            return m.items.items.len;
        }
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const Demo = union(enum) { row: u32, chevron: u32 };

test "a build line's door is the whole line, clipped at what the pane owns" {
    // The indent left of the caption and the air right of it are part
    // of the door: a pointer aimed at a build line must not have to
    // find the words.
    const r = buildHit(.{ .x = 0, .y = 7, .w = 80, .h = 1 }, 79);
    try testing.expectEqual(@as(u16, 0), r.x);
    try testing.expectEqual(@as(u16, 79), r.w);
    try testing.expectEqual(@as(u16, 1), r.h);
    // Never under the furniture painted beside it — a list scrollbar,
    // or the detail panel's left edge.
    try testing.expectEqual(@as(u16, 40), buildHit(.{ .x = 0, .y = 7, .w = 80, .h = 1 }, 40).w);
    // A row taller than one line still registers one line: a build
    // line is one line, whatever the row around it is.
    try testing.expectEqual(@as(u16, 1), buildHit(.{ .x = 2, .y = 7, .w = 20, .h = 3 }, 60).h);
    // Nothing to click when the pane owns nothing there.
    try testing.expect(buildHit(.{ .x = 10, .y = 7, .w = 20, .h = 1 }, 10).isEmpty());
    try testing.expect(buildHit(.{ .x = 10, .y = 7, .w = 20, .h = 1 }, 4).isEmpty());
}

test "the last thing painted wins, an empty rect is never a target, rectOf finds a target by meaning" {
    var m: Map(Demo) = .{};
    defer m.deinit(testing.allocator);
    try m.add(testing.allocator, .{ .x = 0, .y = 2, .w = 40, .h = 1 }, .{ .row = 1 });
    try m.add(testing.allocator, .{ .x = 4, .y = 2, .w = 1, .h = 1 }, .{ .chevron = 1 });
    try m.add(testing.allocator, .{ .x = 0, .y = 3, .w = 0, .h = 1 }, .{ .row = 2 });
    try testing.expectEqual(Demo{ .chevron = 1 }, m.at(4, 2).?);
    try testing.expectEqual(Demo{ .row = 1 }, m.at(5, 2).?);
    try testing.expect(m.at(5, 3) == null);
    try testing.expect(m.at(39, 2) != null and m.at(40, 2) == null);
    try testing.expectEqual(@as(u16, 4), m.rectOf(.{ .chevron = 1 }).?.x);
    try testing.expect(m.rectOf(.{ .row = 9 }) == null);
    try testing.expectEqual(@as(usize, 2), m.count());
    m.reset();
    try testing.expect(m.at(5, 2) == null);
}

test "a target that carries a string does not compile" {
    // The guard above is a `comptime assert`, so the proof that it can
    // fire is a compile error, not a runtime one — this test pins the
    // shapes it accepts and names the one it does not, so a change that
    // quietly relaxed it would have nothing left saying what it was for.
    const Ok = union(enum) { row: usize, chip: enum { sort, filter }, none };
    const Bad = union(enum) { row: usize, label: []const u8 };
    try std.testing.expect(!hasPointer(Ok));
    try std.testing.expect(hasPointer(Bad));
    try std.testing.expect(hasPointer(struct { inner: struct { s: []const u8 } }));
    try std.testing.expect(hasPointer(?[]const u8));
    try std.testing.expect(!hasPointer(struct { a: u16, b: [4]u8 }));
    // And the accepted one really does build a map.
    var m: Map(Ok) = .{};
    defer m.deinit(std.testing.allocator);
    try m.add(std.testing.allocator, .{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{ .row = 2 });
    try std.testing.expectEqual(@as(?Ok, .{ .row = 2 }), m.at(1, 0));
}
