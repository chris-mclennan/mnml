//! A document's merge-conflict regions, worked out once per text
//! generation instead of once (twice) per frame and once per key.
//!
//! The common case is a file with no marker at all, and it must stay
//! free however large the file: a marker can only appear where an edit
//! was made, so after the first full look only the stretch the edit log
//! says changed (and a marker's length either side) is looked at again.
//! A file that HAS markers is parsed again on every generation — that is
//! the file the feature is for, and it is a conflicted source file, not
//! a log.
//!
//! The cache is an edit-log consumer: `sync` must run before the frame
//! trims the log (`render.drawEditor` does), or the records it needs are
//! gone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("../git/parse.zig");
const Document = @import("../editor/editor.zig").Document;

pub const Region = parse.ConflictRegion;

/// Bytes of text looked at for a marker since the process started — what
/// a test reads to show a frame over a large document looked at none.
pub var bytes_scanned: usize = 0;

/// What `parse.hasConflictMarker` looks for at the start of a line.
const marker = "<<<<<<< ";

/// Whether a line of `text` starting in `[lo, hi)` opens a conflict.
fn markerIn(text: []const u8, lo: usize, hi_in: usize) bool {
    const hi = @min(hi_in, text.len);
    if (lo >= hi) return false;
    bytes_scanned += hi - lo;
    var at = lo;
    // `lo` itself starts a line only at the top of the text or after a `\n`.
    if (at != 0 and text[at - 1] != '\n') {
        at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return false) + 1;
    }
    while (at < hi) {
        if (std.mem.startsWith(u8, text[at..], marker)) return true;
        at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return false) + 1;
    }
    return false;
}

pub const Cache = struct {
    /// The edit-log seq `has_marker` and `regions` describe.
    seq: ?u64 = null,
    has_marker: bool = false,
    /// gpa-owned.
    regions: []Region = &.{},

    pub fn deinit(self: *Cache, gpa: Allocator) void {
        gpa.free(self.regions);
        self.* = .{};
    }

    pub fn sync(self: *Cache, gpa: Allocator, doc: *const Document) Allocator.Error!void {
        const head = doc.edits.head();
        if (self.seq) |seen| {
            if (seen == head) return;
            if (!self.has_marker and !doc.edits.lostSince(seen)) {
                // No marker before: one can only be where the text changed.
                // Each changed stretch is carried through the edits after it
                // into the text as it is now, and looked at with a marker's
                // length before it (its tail was typed) and the line after
                // (a `\n` was typed in front of it).
                const recs = doc.edits.since(seen);
                const text = doc.bytes();
                self.seq = head;
                var found = false;
                for (recs, 0..) |sp, k| {
                    var lo = sp.start;
                    var hi = sp.new_end;
                    for (recs[k + 1 ..]) |later| {
                        lo = later.shift(lo);
                        hi = @max(later.shift(hi), lo);
                    }
                    const from = lineStartAtOrBefore(text, lo -| marker.len);
                    if (markerIn(text, from, @min(text.len, hi + 1))) {
                        found = true;
                        break;
                    }
                }
                if (!found) return;
                // Found one: fall through to the full parse.
            }
        }
        const text = doc.bytes();
        self.has_marker = markerIn(text, 0, text.len);
        gpa.free(self.regions);
        self.regions = &.{};
        self.seq = head;
        if (!self.has_marker) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        self.regions = try gpa.dupe(Region, try parse.parseConflicts(arena.allocator(), text));
    }
};

fn lineStartAtOrBefore(text: []const u8, at: usize) usize {
    const a = @min(at, text.len);
    return if (std.mem.lastIndexOfScalar(u8, text[0..a], '\n')) |i| i + 1 else 0;
}

// ── tests ──

const testing = std.testing;

test "markerIn agrees with the whole-text check" {
    const cases = [_][]const u8{ "", "abc", "<<<<<<< ours\nx\n=======\ny\n>>>>>>> t\n", "a\n<<<<<<< o\n", "a <<<<<<< o\n", "a\n<<<<<<<\n", "x << y <<<<<<<< z\n", "a\n<<<<<<<x\n" };
    for (cases) |t| {
        try testing.expectEqual(parse.hasConflictMarker(t), markerIn(t, 0, t.len));
    }
}

test "a document with no marker is looked at once; after that only where it was edited — and a marker typed there is found" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else if (i % 7 == 0) '<' else 'a';
    const doc = try Document.create(gpa, big);
    doc.retain();
    defer doc.release();
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    try cache.sync(gpa, doc);
    try testing.expect(!cache.has_marker);
    // The same generation: nothing looked at.
    var before = bytes_scanned;
    try cache.sync(gpa, doc);
    try testing.expectEqual(before, bytes_scanned);
    // An edit at the top and one at the very end: a few bytes each, not
    // the file between them.
    try doc.spliceBy(0, 0, "ZQJ", null);
    try doc.spliceBy(doc.len(), doc.len(), "QJZ\n", null);
    before = bytes_scanned;
    try cache.sync(gpa, doc);
    try testing.expect(!cache.has_marker);
    try testing.expect(bytes_scanned - before < 512);
    try doc.spliceBy(500_000, 500_000, "x", null);
    before = bytes_scanned;
    try cache.sync(gpa, doc);
    try testing.expect(bytes_scanned - before < 256);
    // Type a conflict in the middle, a piece at a time.
    const at = doc.lineStart(doc.lineOfByte(700_000));
    try doc.spliceBy(at, at, "<<<<<<", null);
    try cache.sync(gpa, doc);
    try testing.expect(!cache.has_marker);
    try doc.spliceBy(at + 6, at + 6, "< ours\n", null);
    try cache.sync(gpa, doc);
    try testing.expect(cache.has_marker);
    try doc.spliceBy(at + 13, at + 13, "=======\nb\n>>>>>>> theirs\n", null);
    try cache.sync(gpa, doc);
    try testing.expectEqual(@as(usize, 1), cache.regions.len);
    // Take the opener out again: no marker, no regions.
    try doc.spliceBy(at, at + 13, "", null);
    try cache.sync(gpa, doc);
    try testing.expect(!cache.has_marker);
    try testing.expectEqual(@as(usize, 0), cache.regions.len);
    // A marker made by typing a newline in FRONT of `<<<<<<< x`.
    try doc.spliceBy(at, at, "q<<<<<<< z\n", null);
    try cache.sync(gpa, doc);
    try testing.expect(!cache.has_marker);
    try doc.spliceBy(at + 1, at + 1, "\n", null);
    try cache.sync(gpa, doc);
    try testing.expect(cache.has_marker);
}
