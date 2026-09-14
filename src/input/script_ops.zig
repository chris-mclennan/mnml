//! The one seam a script operator needs inside the input layer: the
//! `g`-namespace letters `mnml.operator{}` has claimed. The vim handler
//! is a pure key → `EditOp` translator with no `*App`, so it cannot ask
//! the Lua state what is registered; this table is what it reads, and
//! all it reads — the handler branches on "is this letter claimed", not
//! on "is this a script".
//!
//! Registration is `scripting/api.zig`'s (`mnml.operator`), and a
//! `script.reload` clears the table with the Lua state, so an operator
//! never outlives the script that asked for it. One process runs one
//! App, and the table is cleared by `App.init` too, so a test that
//! builds several Apps in a row starts each one empty.
//!
//! Only `g<letter>` is claimable. Vim's other namespaces (`z`, `[`,
//! `]`, `,`) are either taken or reserved, `g` is where the convention
//! puts a user operator (`gs`, `gz`), and one shape means the handler
//! has one place to look.

const std = @import("std");

/// The letters after `g`, each with the operator's index in
/// `Lua.operators`. Small and linear: a script registers a handful.
pub const Claim = struct { letter: u8, index: u32 };

var claims: std.ArrayListUnmanaged(Claim) = .empty;

/// The `g<letter>` chords vim itself uses (`vim.zig`'s `handleGPrefix`).
/// A claim on one of these would never be reached — the handler only
/// asks this table once its own switch has fallen through — so
/// `mnml.operator` refuses them by name instead of registering
/// something that silently does nothing. `vim.zig`'s own test walks
/// every letter and fails if the two ever drift.
pub const reserved = "aAcdDeEfgiIjJkNnpPqrtTuUvx";

pub fn isReserved(letter: u8) bool {
    return std.mem.indexOfScalar(u8, reserved, letter) != null;
}

/// Whether `spec` is a shape `register` accepts: `g` and one letter
/// vim has not already taken.
pub fn validVimSpec(spec: []const u8) bool {
    return spec.len == 2 and spec[0] == 'g' and std.ascii.isAlphabetic(spec[1]) and !isReserved(spec[1]);
}

/// Claim `g<letter>` for the operator at `index`. A letter claimed
/// twice keeps the newer claim — the same rule `mnml.command` follows
/// when an id is registered again.
pub fn register(gpa: std.mem.Allocator, spec: []const u8, index: u32) std.mem.Allocator.Error!void {
    std.debug.assert(spec.len == 2 and spec[0] == 'g' and std.ascii.isAlphabetic(spec[1]));
    const letter = spec[1];
    for (claims.items) |*c| if (c.letter == letter) {
        c.index = index;
        return;
    };
    try claims.append(gpa, .{ .letter = letter, .index = index });
}

/// The operator `g<letter>` names, or null when the letter is free —
/// the whole of what the vim handler asks.
pub fn lookup(letter: u21) ?u32 {
    if (letter > std.math.maxInt(u8)) return null;
    for (claims.items) |c| if (c.letter == @as(u8, @intCast(letter))) return c.index;
    return null;
}

pub fn clear(gpa: std.mem.Allocator) void {
    claims.deinit(gpa);
    claims = .empty;
}

pub fn count() usize {
    return claims.items.len;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "only g<letter> is claimable; a second claim on a letter replaces the first; clear empties the table" {
    defer clear(testing.allocator);
    try testing.expect(validVimSpec("gs"));
    try testing.expect(validVimSpec("gZ"));
    try testing.expect(!validVimSpec("g"));
    try testing.expect(!validVimSpec("gss"));
    try testing.expect(!validVimSpec("zs"));
    try testing.expect(!validVimSpec("g1"));
    // Vim's own `g` chords are refused rather than silently dead.
    try testing.expect(!validVimSpec("gd"));
    try testing.expect(!validVimSpec("gc"));
    try testing.expect(!validVimSpec("gU"));
    try register(testing.allocator, "gs", 3);
    try register(testing.allocator, "gZ", 4);
    try testing.expectEqual(@as(?u32, 3), lookup('s'));
    try testing.expectEqual(@as(?u32, 4), lookup('Z'));
    try testing.expect(lookup('q') == null);
    try testing.expect(lookup('é') == null);
    try register(testing.allocator, "gs", 9);
    try testing.expectEqual(@as(usize, 2), count());
    try testing.expectEqual(@as(?u32, 9), lookup('s'));
    clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expect(lookup('s') == null);
}
