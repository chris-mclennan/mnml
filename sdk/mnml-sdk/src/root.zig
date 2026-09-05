//! mnml-sdk — write an mnml integration in Zig.
//!
//!   wire      the Bridge v2 protocol (`docs/BRIDGE.md`)
//!   Mount     the sibling's end of a mount socket: hello, next, send
//!   Frame     the cell grid you paint; full or dirty-row sends
//!   Ipc       tier 2: toasts, progress, statusline segments, badges,
//!             `register-command` over `$MNML_IPC_DIR/command`
//!   manifest  `Manifest` + `write` for `--install`
//!
//! A minimal integration is `sdk/examples/hello`.

pub const wire = @import("wire.zig");
pub const client = @import("client.zig");
pub const frame = @import("frame.zig");
pub const ipc = @import("ipc.zig");
pub const manifest = @import("manifest.zig");

pub const Mount = client.Mount;
pub const Frame = frame.Frame;
pub const Style = frame.Style;
pub const Ipc = ipc.Ipc;
pub const Manifest = manifest.Manifest;
pub const HostMessage = wire.HostMessage;
pub const SiblingMessage = wire.SiblingMessage;
pub const Color = wire.Color;
pub const Mods = wire.Mods;
pub const protocol = wire.protocol;

test {
    _ = wire;
    _ = client;
    _ = frame;
    _ = ipc;
    _ = manifest;
}
