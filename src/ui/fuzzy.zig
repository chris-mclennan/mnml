//! Fuzzy scoring for the pickers and the palette — the Rust editor's
//! `fuzzy_match`, bonus for bonus, so the palette ranks as it does
//! there: a case-insensitive subsequence match with rewards for what a
//! person typing a name means — consecutive runs (+15), word starts
//! (+12), camel humps (+8), the exact phrase at a word boundary (+50),
//! the whole token besides (+150) — and penalties for gaps, a late
//! first hit and a long haystack. `score` is the contract (`null` = not
//! a match; higher is better); `match` also returns the matched byte
//! positions so a picker can highlight them.
//!
//! Two habits are Rust's: `_`, `-` and `.` in the query are dropped
//! before the subsequence walk, so a dotted command id matches its
//! title (`http.send_streaming` finds "HTTP: send … stream"); and the
//! ORIGINAL query is tried as a boundary substring first, so typing the
//! tail of an id (`.deselect`) lands on the contiguous run instead of a
//! greedy scatter that loses to shorter names. Lengths and positions
//! are counted in code points, as Rust counts chars — a `·` in a
//! palette row costs one, not two.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Match = struct {
    score: u32,
    /// Byte offsets into the haystack, ascending.
    positions: []const usize,
};

/// The score alone. An empty query matches everything at the base score.
pub fn score(query: []const u8, text: []const u8) ?u32 {
    var n: usize = 0;
    return scoreImpl(query, text, &scratch.out, &n);
}

/// The score and the matched positions, on `arena`.
pub fn match(arena: Allocator, query: []const u8, text: []const u8) Allocator.Error!?Match {
    var n: usize = 0;
    const s = scoreImpl(query, text, &scratch.out, &n) orelse return null;
    return .{ .score = s, .positions = try arena.dupe(usize, scratch.out[0..n]) };
}

/// Scores are offset so a poor match is still non-negative: `base` is
/// what an empty query yields. Rust's raw score is `s - base`.
pub const base: u32 = 1000;

/// The longest haystack scored in code points; a longer one is scored
/// on its first `max_chars` (a palette row is well under it).
pub const max_chars: usize = 512;
const max_hits: usize = 256;

fn isBoundary(c: u21) bool {
    return switch (c) {
        '/', '_', '-', '.', ' ', ':' => true,
        else => false,
    };
}

fn isSeparator(c: u21) bool {
    return c == '_' or c == '-' or c == '.';
}

/// Latin letters with a diacritic → the base letter (U+00C0–U+017F);
/// `_` = no fold. With the combining marks dropped in `decode`, an NFC
/// `é` typed on the keyboard and an NFD `e` + U+0301 in a name Finder
/// wrote both reach `e` — fzf's default folding, VS Code's NFC match.
const fold_latin1 = "AAAAAA_CEEEEIIIIDNOOOOO_OUUUUY__aaaaaa_ceeeeiiiidnooooo_ouuuuy_y";
const fold_ext_a = "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiIiJjKkkLlLlLlLlLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs";

fn lower(c: u21) u21 {
    if (c < 0x80) return std.ascii.toLower(@intCast(c));
    const base_letter: u8 = if (c >= 0xC0 and c < 0x100) fold_latin1[c - 0xC0] else if (c >= 0x100 and c < 0x180) fold_ext_a[c - 0x100] else return c;
    return if (base_letter == '_') c else std.ascii.toLower(base_letter);
}

/// A combining diacritical mark (U+0300–U+036F): part of the letter
/// before it for matching.
fn isCombining(c: u21) bool {
    return c >= 0x300 and c <= 0x36F;
}

fn isUpper(c: u21) bool {
    return c < 0x80 and std.ascii.isUpper(@intCast(c));
}

fn isLower(c: u21) bool {
    return c < 0x80 and std.ascii.isLower(@intCast(c));
}

/// `text` as code points with each one's byte offset; invalid bytes
/// count as one code point each, and a combining mark joins the code
/// point before it (it is skipped).
fn decode(text: []const u8, chars: []u21, offs: []usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < chars.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp: u21 = if (i + len <= text.len) std.unicode.utf8Decode(text[i .. i + len]) catch text[i] else text[i];
        if (n > 0 and isCombining(cp)) {
            i += @max(len, 1);
            continue;
        }
        chars[n] = cp;
        offs[n] = i;
        n += 1;
        i += @max(len, 1);
    }
    return n;
}

/// The verdict `scoreImpl` would reach for an all-ASCII query whose
/// needle (separators dropped, case folded) is not a subsequence of the
/// text — reached on the bytes, without decoding either side. A picker
/// over a 50k-file tree calls the scorer once per file per keystroke,
/// and most files are rejected here.
fn cannotMatch(query: []const u8, text: []const u8) bool {
    var ti: usize = 0;
    for (query) |qc| {
        if (qc >= 0x80) return false; // decoding decides
        if (qc == '_' or qc == '-' or qc == '.') continue;
        const want = std.ascii.toLower(qc);
        while (ti < text.len and std.ascii.toLower(text[ti]) != want) {
            // A non-ASCII letter may fold to `want` (`é` → `e`).
            if (text[ti] >= 0x80) return false;
            ti += 1;
        }
        if (ti == text.len) return true;
        ti += 1;
    }
    return false;
}

/// The scorer's working arrays, kept per thread: as locals they cost a
/// ~20 KB fill of `undefined` on every call in the safe build modes —
/// more than the scoring itself, times every row of a large picker.
const Scratch = struct {
    qchars: [max_chars]u21,
    qoffs: [max_chars]usize,
    nl: [max_chars]u21,
    hchars: [max_chars]u21,
    hoffs: [max_chars]usize,
    hlower: [max_chars]u21,
    tchars: [max_chars]u21,
    toffs: [max_chars]usize,
    matched: [max_hits]usize,
    /// `score` / `match`'s positions before `match` copies them out.
    out: [max_hits]usize,
};
threadlocal var scratch: Scratch = undefined;

fn scoreImpl(query_in: []const u8, text: []const u8, buf: []usize, n_out: *usize) ?u32 {
    n_out.* = 0;
    if (cannotMatch(query_in, text)) return null;
    const sc = &scratch;
    const qchars = &sc.qchars;
    const qoffs = &sc.qoffs;
    const qn_raw = decode(query_in, qchars, qoffs);
    // Rust normalises the needle by dropping `_` `-` `.` and lower-casing.
    const nl = &sc.nl;
    var nl_n: usize = 0;
    for (qchars[0..qn_raw]) |c| {
        if (isSeparator(c)) continue;
        nl[nl_n] = lower(c);
        nl_n += 1;
    }
    if (nl_n == 0) return base;

    const hchars = &sc.hchars;
    const hoffs = &sc.hoffs;
    const n = decode(text, hchars, hoffs);
    const hlower = &sc.hlower;
    for (hchars[0..n], 0..) |c, i| hlower[i] = lower(c);

    // The trimmed original query, lower-cased, for the substring passes.
    const trimmed = std.mem.trim(u8, query_in, " \t\r\n");
    const tchars = &sc.tchars;
    const toffs = &sc.toffs;
    const tn = decode(trimmed, tchars, toffs);
    for (tchars[0..tn], 0..) |c, i| tchars[i] = lower(c);

    const matched = &sc.matched; // char indices
    var mn: usize = 0;

    // Pass 1: the original query as a case-insensitive substring at a boundary.
    var used_substring = false;
    if (tn > 0 and tn <= n) {
        var start: usize = 0;
        outer: while (start + tn <= n) : (start += 1) {
            for (tchars[0..tn], 0..) |qc, off| if (hlower[start + off] != qc) continue :outer;
            const at_boundary = start == 0 or isBoundary(hchars[start - 1]);
            if (!at_boundary) continue;
            var i: usize = 0;
            while (i < tn and mn < matched.len) : (i += 1) {
                matched[mn] = start + i;
                mn += 1;
            }
            used_substring = true;
            break;
        }
    }

    // Pass 2: greedy forward subsequence on the normalised needle.
    if (!used_substring) {
        var hi: usize = 0;
        for (nl[0..nl_n]) |nc| {
            var found: ?usize = null;
            while (hi < n) {
                if (hlower[hi] == nc) {
                    found = hi;
                    hi += 1;
                    break;
                }
                hi += 1;
            }
            const i = found orelse return null;
            if (mn < matched.len) {
                matched[mn] = i;
                mn += 1;
            }
        }
    }

    var s: i64 = 0;
    var prev: ?usize = null;
    for (matched[0..mn]) |i| {
        if (prev) |p| {
            if (i == p + 1) s += 15 else s -= @intCast(i - p - 1);
        } else {
            s += 5;
        }
        if (i == 0 or isBoundary(hchars[i - 1])) s += 12;
        if (i > 0 and isUpper(hchars[i]) and isLower(hchars[i - 1])) s += 8;
        prev = i;
    }
    s -= @intCast(n / 8);
    s -= @intCast(matched[0] / 2);

    // The exact phrase at a boundary: +50; a whole token besides: +150.
    if (tn > 0 and tn <= n) {
        var pos: usize = 0;
        outer: while (pos + tn <= n) : (pos += 1) {
            for (tchars[0..tn], 0..) |qc, off| if (hlower[pos + off] != qc) continue :outer;
            const at_boundary = pos == 0 or isBoundary(hchars[pos - 1]);
            if (!at_boundary) continue;
            s += 50;
            const end = pos + tn;
            if (end == n or switch (hchars[end]) {
                '.', ' ', ':', '-', '/' => true,
                else => false,
            }) s += 150;
            break;
        }
    }

    var k: usize = 0;
    while (k < mn and k < buf.len) : (k += 1) buf[k] = hoffs[matched[k]];
    n_out.* = k;
    const clamped: i64 = @max(0, @as(i64, base) + s);
    return @intCast(clamped);
}

/// Rust's raw score for `query` against `text`: the bonuses and
/// penalties alone, null when it does not match.
pub fn raw(query: []const u8, text: []const u8) ?i64 {
    const s = score(query, text) orelse return null;
    return @as(i64, s) - base;
}

// ── tests ──

const testing = std.testing;

test "subsequence, case-insensitive; a miss is null; empty matches at base" {
    try testing.expect(score("abc", "xaxbxc") != null);
    try testing.expect(score("abc", "xaxbx") == null);
    try testing.expect(score("ABC", "a b c") != null);
    try testing.expectEqual(base, score("", "anything").?);
    // Rust keeps a needle's spaces: two of them do not match a word.
    try testing.expect(score("  ", "anything") == null);
    try testing.expectEqual(base, score("_", "anything").?);
    try testing.expect(score("z", "") == null);
    try testing.expect(score("xyz", "abc") == null);
}

test "Rust's table: contiguous beats scattered, boundary beats mid-word, the exact phrase and the exact id win" {
    // fuzzy.rs: contiguous_beats_scattered
    try testing.expect(raw("main", "src/main.rs").? > raw("main", "m_a_i_n.txt").?);
    // boundary_bonus / exact_phrase_boost_gated_on_word_boundary
    try testing.expect(raw("fk", "foo_key").? > raw("fk", "xafkx").?);
    // exact_phrase_boost_at_word_boundary
    try testing.expect(raw("abc", "some abc thing").? > raw("abc", "somexabcthing").?);
    // exact_id_beats_prefix_of_longer_id
    const winner = raw("integrations.refresh", "integrations  ·  Integrations: re-scan manifests in .mnml/integrations/  ·  integrations.refresh").?;
    const loser = raw("integrations.refresh", "integrations  ·  Integrations: refresh installed-binary detection  ·  integrations.refresh_binary_cache").?;
    try testing.expect(winner > loser);
    // case_insensitive_subsequence: positions 0 and 2
    const m = (try match(testing.allocator, "ab", "AxBy")).?;
    defer testing.allocator.free(m.positions);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, m.positions);
}

test "the raw numbers are Rust's: the palette's git rows" {
    // `git` against `git  ·  Git: diff the worktree  ·  git.diff` (44 chars):
    // first hit +5, boundary +12, then +15 +15 with boundaries none;
    // -44/8 = -5, -0; +50 phrase, +150 token → 242.
    try testing.expectEqual(@as(i64, 242), raw("git", "git  ·  Git: diff the worktree  ·  git.diff").?);
    // 52 chars: -6 → 241. The `·` counts one, as Rust's char does.
    try testing.expectEqual(@as(i64, 241), raw("git", "git  ·  Git: diff this file (split)  ·  git.diff_file").?);
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

test "positions are byte offsets, ascending and inside the text" {
    const m = (try match(testing.allocator, "mz", "mnml-zig")).?;
    defer testing.allocator.free(m.positions);
    try testing.expectEqualSlices(usize, &.{ 0, 5 }, m.positions);
    try testing.expect(try match(testing.allocator, "q", "mnml-zig") == null);
    // Past a two-byte `·` the byte offset moves by two, the score by one.
    const dot = (try match(testing.allocator, "diff", "g  ·  diff")).?;
    defer testing.allocator.free(dot.positions);
    try testing.expectEqualSlices(usize, &.{ 7, 8, 9, 10 }, dot.positions);
}

test "latin diacritics fold both ways: NFC typed finds an NFD name and the reverse; ecole finds either" {
    const nfd = "e\u{301}cole-notes.txt"; // Finder's spelling: e + COMBINING ACUTE
    const nfc = "\u{e9}cole-notes.txt";
    try testing.expect(score("\u{e9}cole", nfd) != null);
    try testing.expect(score("e\u{301}cole", nfc) != null);
    try testing.expect(score("ecole", nfd) != null);
    try testing.expect(score("ecole", nfc) != null);
    try testing.expect(score("\u{e9}cole", "school.txt") == null);
    // The positions still land on real bytes of the haystack.
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const m = (try match(fba.allocator(), "\u{e9}c", nfd)).?;
    try testing.expectEqual(@as(usize, 0), m.positions[0]);
    try testing.expectEqual(@as(usize, 3), m.positions[1]);
}
