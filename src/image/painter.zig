//! The terminal side of the two-phase paint: after the cells of a
//! frame are out, draw the frame's `PaintRequest`s over them.
//!
//! Kitty: an image is transmitted once by id, every placement is
//! deleted, and each request is placed again — a pane that closed or
//! scrolled takes its image with it, and a request that did not change
//! costs a few bytes. iTerm2 and sixel have no ids and no delete: the
//! payload goes out again on every frame that shows it, at the cursor.
//! The cursor is put back where vaxis left it, so the next diff starts
//! from the truth.
//!
//! `Painter` is owned by the terminal loop (the caches live as long as
//! the session) and takes the writer, never the terminal, so the
//! `tui` module stays free of the image layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const root = @import("root.zig");
const Transport = root.Transport;
const PaintRequest = root.PaintRequest;

const Painter = @This();

/// Which kitty ids this session has transmitted.
kitty_sent: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// Whether the last frame placed anything — one frame with none still
/// has to clear.
shown: bool = false,
/// Sixel streams already built for an (image, box) pair.
sixel_cache: std.AutoHashMapUnmanaged(u64, []u8) = .empty,

pub const max_sixel_cache: usize = 16;

/// Where the terminal's cursor is and whether it shows, plus the cell
/// size in pixels (zeros mean unknown).
pub const Screen = struct {
    cursor_row: u16,
    cursor_col: u16,
    cursor_vis: bool,
    cell_w_px: u32 = 0,
    cell_h_px: u32 = 0,
};

pub fn deinit(self: *Painter, gpa: Allocator) void {
    self.kitty_sent.deinit(gpa);
    var it = self.sixel_cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    self.sixel_cache.deinit(gpa);
}

/// Emit the escapes for `paints` on `w` (flushed).
pub fn paint(self: *Painter, gpa: Allocator, w: *Io.Writer, transport: Transport, paints: []const PaintRequest, screen: Screen) !void {
    if (transport == .none) return;
    if (paints.len == 0 and !self.shown) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try w.writeAll("\x1b[?25l");
    if (transport == .kitty) try w.writeAll(root.kitty.delete_placements);
    for (paints) |p| {
        if (p.rect.isEmpty()) continue;
        try w.print("\x1b[{d};{d}H", .{ p.rect.y + 1, p.rect.x + 1 });
        switch (transport) {
            .kitty => {
                const id = root.kitty.idOf(p.key);
                if (!self.kitty_sent.contains(id)) {
                    try w.writeAll(try root.kitty.encodeTransmit(arena, id, p.png));
                    try self.kitty_sent.put(gpa, id, {});
                }
                try w.writeAll(try root.kitty.encodePlace(arena, id, p.rect.w, p.rect.h));
            },
            .iterm2 => try w.writeAll(try root.iterm2.encodePlacement(arena, p.png, p.rect.w, p.rect.h)),
            .sixel => try w.writeAll(try self.sixelFor(gpa, p, screen)),
            .none => {},
        }
    }
    try w.print("\x1b[{d};{d}H", .{ screen.cursor_row + 1, screen.cursor_col + 1 });
    if (screen.cursor_vis) try w.writeAll("\x1b[?25h");
    try w.flush();
    self.shown = paints.len > 0;
}

/// The sixel stream for `p`'s image in `p`'s box, built once per
/// (image, box); the cache is emptied past `max_sixel_cache` entries.
fn sixelFor(self: *Painter, gpa: Allocator, p: PaintRequest, screen: Screen) ![]const u8 {
    var h = std.hash.Wyhash.init(p.key);
    h.update(std.mem.asBytes(&p.rect.w));
    h.update(std.mem.asBytes(&p.rect.h));
    const k = h.final();
    if (self.sixel_cache.get(k)) |s| return s;
    const cell_w: u32 = if (screen.cell_w_px > 0) screen.cell_w_px else 10;
    const cell_h: u32 = if (screen.cell_h_px > 0) screen.cell_h_px else 20;
    var px = try root.sixel.decode(gpa, p.png);
    defer px.deinit(gpa);
    var fitted = try root.sixel.fit(gpa, &px, @as(u32, p.rect.w) * cell_w, @as(u32, p.rect.h) * cell_h);
    defer fitted.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const stream = try gpa.dupe(u8, try root.sixel.encode(arena_state.allocator(), &fitted));
    errdefer gpa.free(stream);
    if (self.sixel_cache.count() >= max_sixel_cache) {
        var it = self.sixel_cache.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        self.sixel_cache.clearRetainingCapacity();
    }
    try self.sixel_cache.put(gpa, k, stream);
    return stream;
}

// ── tests ──

const testing = std.testing;
const Rect = @import("../ui/rect.zig");

test "kitty: transmit once, place every frame, clear once more after the last placement; iTerm2 resends" {
    var painter: Painter = .{};
    defer painter.deinit(testing.allocator);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const screen: Screen = .{ .cursor_row = 3, .cursor_col = 4, .cursor_vis = true };
    const req: PaintRequest = .{ .rect = Rect.init(2, 1, 10, 5), .png = "png-bytes", .key = 0xabcd };
    try painter.paint(testing.allocator, &aw.writer, .kitty, &.{req}, screen);
    const first = try testing.allocator.dupe(u8, aw.written());
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, root.kitty.delete_placements) != null);
    try testing.expect(std.mem.indexOf(u8, first, "\x1b[2;3H") != null); // the box, 1-based
    try testing.expect(std.mem.indexOf(u8, first, "a=t,f=100,i=43981") != null);
    try testing.expect(std.mem.indexOf(u8, first, "a=p,i=43981,c=10,r=5") != null);
    try testing.expect(std.mem.endsWith(u8, first, "\x1b[4;5H\x1b[?25h"));
    // The same frame again: placed, not transmitted.
    aw.clearRetainingCapacity();
    try painter.paint(testing.allocator, &aw.writer, .kitty, &.{req}, screen);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "a=t,") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "a=p,i=43981") != null);
    // Nothing to show: one clear, then silence.
    aw.clearRetainingCapacity();
    try painter.paint(testing.allocator, &aw.writer, .kitty, &.{}, screen);
    try testing.expect(std.mem.indexOf(u8, aw.written(), root.kitty.delete_placements) != null);
    aw.clearRetainingCapacity();
    try painter.paint(testing.allocator, &aw.writer, .kitty, &.{}, screen);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
    // iTerm2 carries the payload every time; a hidden cursor stays hidden.
    const hidden: Screen = .{ .cursor_row = 0, .cursor_col = 0, .cursor_vis = false };
    try painter.paint(testing.allocator, &aw.writer, .iterm2, &.{req}, hidden);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b]1337;File=inline=1;width=10;height=5") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?25h") == null);
    // `.none` writes nothing at all.
    aw.clearRetainingCapacity();
    try painter.paint(testing.allocator, &aw.writer, .none, &.{req}, screen);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "sixel: a decodable image is fitted to the box and cached by (image, box)" {
    var painter: Painter = .{};
    defer painter.deinit(testing.allocator);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const png = try root.sixel.testFixturePng(testing.allocator);
    defer testing.allocator.free(png);
    const req: PaintRequest = .{ .rect = Rect.init(0, 0, 4, 2), .png = png, .key = 7 };
    const screen: Screen = .{ .cursor_row = 0, .cursor_col = 0, .cursor_vis = false, .cell_w_px = 8, .cell_h_px = 16 };
    try painter.paint(testing.allocator, &aw.writer, .sixel, &.{req}, screen);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1bPq\"1;1;2;1") != null);
    try testing.expectEqual(@as(usize, 1), painter.sixel_cache.count());
    try painter.paint(testing.allocator, &aw.writer, .sixel, &.{req}, screen);
    try testing.expectEqual(@as(usize, 1), painter.sixel_cache.count());
    const bad: PaintRequest = .{ .rect = Rect.init(0, 0, 4, 2), .png = "nope", .key = 8 };
    try testing.expectError(error.Undecodable, painter.paint(testing.allocator, &aw.writer, .sixel, &.{bad}, screen));
}
