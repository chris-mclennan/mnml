//! src/ui — the render primitives (D6): Rect geometry and, on top of a
//! tty-free `vaxis.Screen`, the Canvas that paints into it.
//!
//! This barrel exists so `zig build test` reaches every ui module's tests
//! without the main executable having to import them.

pub const Rect = @import("rect.zig");
pub const color = @import("color.zig");
pub const Canvas = @import("canvas.zig");
pub const clip = @import("clip.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
