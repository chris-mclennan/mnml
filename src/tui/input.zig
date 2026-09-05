//! The input worker for this target. `input_posix.zig` reads the tty in
//! an `Io.Group` task and turns SIGWINCH into `.winsize`;
//! `input_windows.zig` reads console records on a thread and turns the
//! window-buffer-size record into the same event. Both feed one
//! `std.Io.Queue(vaxis.Event)` through the shared fold in
//! `input_common.zig`, and both spell keys the same way (`keyName`).

const builtin = @import("builtin");

pub const Input = if (builtin.os.tag == .windows) @import("input_windows.zig") else @import("input_posix.zig");

pub const common = @import("input_common.zig");
pub const Event = common.Event;
pub const Key = common.Key;
pub const keyName = common.keyName;
pub const writeKeyName = common.writeKeyName;
