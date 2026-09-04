//! src/tui — the terminal side (D3): raw mode + our own stdout writer +
//! capability probe in `term.zig`, and the input worker feeding one
//! `std.Io.Queue(vaxis.Event)` in `input.zig`.
//!
//! Barrel for `zig build test`; the executables import the modules directly.

pub const Input = @import("input.zig");
pub const Term = @import("term.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
