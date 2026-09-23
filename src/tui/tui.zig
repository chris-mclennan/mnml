//! src/tui — the terminal side (D3): raw mode + our own stdout writer +
//! capability probe in `term.zig`, and the input worker feeding one
//! `std.Io.Queue(vaxis.Event)` in `input.zig`. Each is a comptime
//! selector over a POSIX and a Windows backend (`*_posix.zig`,
//! `*_windows.zig`); what both backends share lives in `caps.zig` and
//! `input_common.zig`.
//!
//! Barrel for `zig build test`; the executables import the modules directly.

pub const Input = @import("input.zig").Input;
pub const Term = @import("term.zig").Term;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("caps.zig");
    _ = @import("input_common.zig");
    _ = @import("legacy_fkeys.zig");
    // The Windows backends' pure halves — the record fold, the console
    // mode words — have tests that analyze on every host; the tests that
    // need a console skip themselves elsewhere. (The POSIX files are not
    // pulled in on Windows: their only tty test needs termios.)
    _ = @import("input_windows.zig");
    _ = @import("term_windows.zig");
}
