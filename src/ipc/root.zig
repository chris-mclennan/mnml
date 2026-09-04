//! File-IPC: the channel a host drives mnml-zig through, and the text
//! dumps it reads back. Byte-compatible with mnml 0.2's `.mnml/ipc/`.

pub const command = @import("command.zig");
pub const channel = @import("channel.zig");
pub const screen = @import("screen.zig");

pub const Command = command.Command;
pub const Channel = channel.Channel;
pub const Status = screen.Status;

test {
    _ = command;
    _ = channel;
    _ = screen;
}
