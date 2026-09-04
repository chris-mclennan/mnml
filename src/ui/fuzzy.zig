//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! Fuzzy matching: case-insensitive subsequence with bonuses for word
//! starts and consecutive runs. Higher is better; null = no match.

const std = @import("std");

pub fn score(query: []const u8, text: []const u8) ?u32 {
    if (query.len == 0) return 1;
    var s: u32 = 0;
    var ti: usize = 0;
    var prev_hit: ?usize = null;
    for (query) |qc| {
        const q = std.ascii.toLower(qc);
        var found: ?usize = null;
        while (ti < text.len) : (ti += 1) {
            if (std.ascii.toLower(text[ti]) == q) {
                found = ti;
                break;
            }
        }
        const i = found orelse return null;
        s += 1;
        if (i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) s += 3;
        if (prev_hit) |p| if (p + 1 == i) {
            s += 2;
        };
        prev_hit = i;
        ti = i + 1;
    }
    // Shorter texts rank above longer ones for the same hits.
    s += @intCast(@min(20, 200 / @max(text.len, 1)) / 10);
    return s;
}

test "fuzzy: subsequence, case-insensitive, bonuses" {
    try std.testing.expect(score("abc", "xyz") == null);
    try std.testing.expect(score("ac", "abc") != null);
    try std.testing.expect(score("FB", "picker.files_buffers") != null);
    try std.testing.expect(score("ab", "a_b").? >= score("ab", "axxb").?);
    try std.testing.expectEqual(@as(?u32, 1), score("", "anything"));
}
