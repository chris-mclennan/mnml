//! iTerm2's inline images: one OSC 1337 with the whole file in base64,
//! sized in cells, aspect kept. Spec:
//! <https://iterm2.com/documentation-images.html>
//!
//! The image lands at the cursor; there is no id and no delete — the
//! cells the terminal draws over it are what clear it, so a frame that
//! still shows the image sends it again.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn encodePlacement(arena: Allocator, png: []const u8, cols: u16, rows: u16) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(png.len));
    _ = enc.encode(b64, png);
    return std.fmt.allocPrint(arena, "\x1b]1337;File=inline=1;width={d};height={d};preserveAspectRatio=1:{s}\x07", .{ cols, rows, b64 });
}

// ── tests ──

const testing = std.testing;

test "one OSC 1337 with the base64 payload, sized in cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try encodePlacement(arena_state.allocator(), "hi", 5, 3);
    try testing.expectEqualStrings("\x1b]1337;File=inline=1;width=5;height=3;preserveAspectRatio=1:aGk=\x07", s);
    const empty = try encodePlacement(arena_state.allocator(), "", 1, 1);
    try testing.expect(std.mem.startsWith(u8, empty, "\x1b]1337;File=inline=1;"));
    try testing.expect(std.mem.endsWith(u8, empty, ":\x07"));
}
