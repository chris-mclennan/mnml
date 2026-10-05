//! The kitty graphics protocol, the way mnml uses it. Spec:
//! <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
//!
//! An image is transmitted once, by id, as base64 PNG (`a=t,f=100`) in
//! chunks of at most 4096 payload bytes (`m=1` continues, `m=0` ends),
//! then placed (`a=p`) into a cell box wherever the cursor is. `q=2`
//! on every command keeps the terminal from answering — a reply would
//! land in the key stream. `C=1` leaves the cursor where it was. A
//! frame starts by deleting every placement (`a=d`) and places again,
//! so a pane that closed or scrolled takes its image with it; the
//! transmitted data stays and the next placement is a few bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Base64 payload bytes per chunk; the spec's limit is 4096.
pub const chunk_size: usize = 4096;

/// Every visible placement goes; transmitted images stay.
pub const delete_placements = "\x1b_Ga=d,d=a,q=2\x1b\\";

/// Transmit `png` under `id` (no placement).
pub fn encodeTransmit(arena: Allocator, id: u32, png: []const u8) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(png.len));
    _ = enc.encode(b64, png);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest: []const u8 = b64;
    var first = true;
    while (true) {
        const take = @min(rest.len, chunk_size);
        const chunk = rest[0..take];
        rest = rest[take..];
        const more: u8 = if (rest.len > 0) 1 else 0;
        if (first) {
            try out.print(arena, "\x1b_Ga=t,f=100,i={d},q=2,m={d};", .{ id, more });
            first = false;
        } else {
            try out.print(arena, "\x1b_Gm={d};", .{more});
        }
        try out.appendSlice(arena, chunk);
        try out.appendSlice(arena, "\x1b\\");
        if (rest.len == 0) break;
    }
    return out.items;
}

/// Place the transmitted `id` at the cursor, scaled into `cols`×`rows`.
pub fn encodePlace(arena: Allocator, id: u32, cols: u16, rows: u16) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "\x1b_Ga=p,i={d},c={d},r={d},C=1,q=2\x1b\\", .{ id, cols, rows });
}

/// A `u64` key folded to the u32 id the protocol wants (never 0).
pub fn idOf(key: u64) u32 {
    const folded: u32 = @truncate(key ^ (key >> 32));
    return if (folded == 0) 1 else folded;
}

// ── tests ──

const testing = std.testing;

test "transmit: one chunk carries the header and m=0; a big payload is chunked at 4096 with m=1 continuations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const small = try encodeTransmit(arena, 7, "hi");
    try testing.expectEqualStrings("\x1b_Ga=t,f=100,i=7,q=2,m=0;aGk=\x1b\\", small);
    const big = try encodeTransmit(arena, 9, &@as([5000]u8, @splat('x')));
    // 5000 bytes → 6668 base64 chars → 4096 + 2572.
    try testing.expect(std.mem.startsWith(u8, big, "\x1b_Ga=t,f=100,i=9,q=2,m=1;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, big, "\x1b_Gm=0;"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, big, "\x1b\\"));
    const first_end = std.mem.indexOf(u8, big, "\x1b\\").?;
    const header_len = "\x1b_Ga=t,f=100,i=9,q=2,m=1;".len;
    try testing.expectEqual(chunk_size, first_end - header_len);
    const place = try encodePlace(arena, 9, 40, 12);
    try testing.expectEqualStrings("\x1b_Ga=p,i=9,c=40,r=12,C=1,q=2\x1b\\", place);
    try testing.expect(idOf(0) == 1);
    try testing.expect(idOf(0x1_0000_0000) == 1);
    try testing.expect(idOf(0xabcd) == 0xabcd);
}
