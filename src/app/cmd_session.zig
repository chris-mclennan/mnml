//! `session.*` runners — the table only; the behaviour is `session.zig`.

const session = @import("session.zig");

pub const table = .{
    .@"session.save" = &session.saveCmd,
    .@"session.restore" = &session.restoreCmd,
    .@"session.clear" = &session.clearCmd,
};
