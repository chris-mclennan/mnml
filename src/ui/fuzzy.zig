//! Fuzzy scoring for the pickers and the palette: case-insensitive
//! subsequence match with bonuses for what a person typing a name
//! means — consecutive runs, word starts, camel humps, the exact phrase
//! at a word boundary, the exact token — and penalties for gaps, a late
//! first hit and a long haystack. `score` is the contract (`null` = not
//! a match; higher is better); `match` also returns the matched byte
//! positions so a picker can highlight them.
//!
//! Two habits from the Rust picker are kept: `_`, `-` and `.` in the
//! query are dropped before the subsequence walk, so a dotted command
//! id matches its title (`http.send_streaming` finds "HTTP: send …
//! stream"); and the ORIGINAL query is tried as a boundary substring
//! first, so typing the tail of an id (`.deselect`) lands on the
//! contiguous run instead of a greedy scatter that loses to shorter
//! names.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Match = struct {
    score: u32,
    /// Byte offsets into the haystack, ascending.
    positions: []const usize,
};

/// The score alone. An empty query matches everything at the base score.
pub fn score(query: []const u8, text: []const u8) ?u32 {
    var buf: [256]usize = undefined;
    return scoreInto(query, text, &buf);
}

/// The score and the matched positions, on `arena`.
pub fn match(arena: Allocator, query: []const u8, text: []const u8) Allocator.Error!?Match {
    var buf: [256]usize = undefined;
    var n: usize = 0;
    const s = scoreImpl(query, text, &buf, &n) orelse return null;
    return .{ .score = s, .positions = try arena.dupe(usize, buf[0..n]) };
}

fn scoreInto(query: []const u8, text: []const u8, buf: []usize) ?u32 {
    var n: usize = 0;
    return scoreImpl(query, text, buf, &n);
}

/// Scores are offset so a poor match is still non-negative: `base` is
/// what an empty query yields.
pub const base: u32 = 1000;

fn isBoundary(c: u8) bool {
    return switch (c) {
        '/', '_', '-', '.', ' ', ':' => true,
        else => false,
    };
}

fn isSeparator(c: u8) bool {
    return c == '_' or c == '-' or c == '.';
}

fn scoreImpl(query_in: []const u8, text: []const u8, buf: []usize, n_out: *usize) ?u32 {
    const query = std.mem.trim(u8, query_in, " \t");
    n_out.* = 0;
    if (query.len == 0) return base;
    var n: usize = 0;

    // Pass 1: the query as a case-insensitive substring at a boundary.
    var used_substring = false;
    if (query.len <= text.len) {
        var start: usize = 0;
        while (start + query.len <= text.len) : (start += 1) {
            if (!std.ascii.startsWithIgnoreCase(text[start..], query)) continue;
            const at_boundary = start == 0 or isBoundary(text[start - 1]);
            if (!at_boundary) continue;
            var i: usize = 0;
            while (i < query.len and n < buf.len) : (i += 1) {
                buf[n] = start + i;
                n += 1;
            }
            used_substring = true;
            break;
        }
    }

    // Pass 2: greedy subsequence on the query with separators dropped.
    if (!used_substring) {
        var hi: usize = 0;
        for (query) |qc| {
            if (isSeparator(qc)) continue;
            const lq = std.ascii.toLower(qc);
            var found: ?usize = null;
            while (hi < text.len) {
                const i = hi;
                hi += 1;
                if (std.ascii.toLower(text[i]) == lq) {
                    found = i;
                    break;
                }
            }
            const i = found orelse return null;
            if (n < buf.len) {
                buf[n] = i;
                n += 1;
            }
        }
        if (n == 0) return base; // the query was separators only
    }

    var s: i64 = 0;
    var prev: ?usize = null;
    for (buf[0..n]) |i| {
        if (prev) |p| {
            if (i == p + 1) s += 15 else s -= @intCast(i - p - 1);
        } else {
            s += 5;
        }
        if (i == 0 or isBoundary(text[i - 1])) s += 12;
        if (i > 0 and std.ascii.isUpper(text[i]) and std.ascii.isLower(text[i - 1])) s += 8;
        prev = i;
    }
    s -= @intCast(text.len / 8);
    s -= @intCast(buf[0] / 2);

    // Exact phrase at a boundary: +50; a whole token besides: +150.
    if (query.len <= text.len) {
        var pos: usize = 0;
        while (pos + query.len <= text.len) : (pos += 1) {
            if (!std.ascii.startsWithIgnoreCase(text[pos..], query)) continue;
            const at_boundary = pos == 0 or isBoundary(text[pos - 1]);
            if (!at_boundary) continue;
            s += 50;
            const end = pos + query.len;
            if (end == text.len or isBoundary(text[end])) s += 150;
            break;
        }
    }

    n_out.* = n;
    const clamped: i64 = @max(0, @as(i64, base) + s);
    return @intCast(clamped);
}

// ── tests ──

const testing = std.testing;

test "subsequence, case-insensitive; a miss is null; empty matches at base" {
    try testing.expect(score("abc", "xaxbxc") != null);
    try testing.expect(score("abc", "xaxbx") == null);
    try testing.expect(score("ABC", "a b c") != null);
    try testing.expectEqual(base, score("", "anything").?);
    try testing.expectEqual(base, score("  ", "anything").?);
    try testing.expect(score("z", "") == null);
}

test "consecutive and boundary hits outrank a scatter" {
    const tight = score("open", "open file").?;
    const scattered = score("open", "o p e n x").?;
    try testing.expect(tight > scattered);
    const at_word = score("file", "picker.files").?;
    const mid_word = score("file", "profile").?;
    try testing.expect(at_word > mid_word);
}

test "a dotted command id finds its title; the id's tail finds the contiguous run" {
    try testing.expect(score("http.send_streaming", "HTTP: send as a Server-Sent Events stream · http.send_streaming") != null);
    try testing.expect(score("httpsend", "HTTP: send active request") != null);
    const m = (try match(testing.allocator, "deselect", "find  ·  Find: clear highlights  ·  find.clear_and_deselect")).?;
    defer testing.allocator.free(m.positions);
    try testing.expectEqual(@as(usize, 8), m.positions.len);
    try testing.expectEqual(m.positions[0] + 7, m.positions[7]);
    // The exact token beats a shorter fuzzy neighbour.
    try testing.expect(score("hover-help", "view.toggle_hover-help").? > score("hover-help", "view.hover_help_x").?);
}

test "positions are ascending and inside the text" {
    const m = (try match(testing.allocator, "mz", "mnml-zig")).?;
    defer testing.allocator.free(m.positions);
    try testing.expectEqualSlices(usize, &.{ 0, 5 }, m.positions);
    try testing.expect(try match(testing.allocator, "q", "mnml-zig") == null);
}
