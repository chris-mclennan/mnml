//! The host's view of the Bridge v2 wire. The definitions live in the
//! SDK (`sdk/mnml-sdk/src/wire.zig`) so an integration and mnml compile
//! the same types; this file names them for the host and runs the
//! SDK's tests under `zig build test`. `docs/BRIDGE.md` is the prose.

const sdk = @import("mnml_sdk");

pub const wire = sdk.wire;

pub const protocol = wire.protocol;
pub const max_message = wire.max_message;
pub const Geometry = wire.Geometry;
pub const Capabilities = wire.Capabilities;
pub const Hello = wire.Hello;
pub const Palette = wire.Palette;
pub const Button = wire.Button;
pub const RowRef = wire.RowRef;
pub const InputEvent = wire.InputEvent;
pub const HostMessage = wire.HostMessage;
pub const Color = wire.Color;
pub const Mods = wire.Mods;
pub const Cell = wire.Cell;
pub const Row = wire.Row;
pub const Cursor = wire.Cursor;
pub const ToastLevel = wire.ToastLevel;
pub const SiblingMessage = wire.SiblingMessage;
pub const SessionState = wire.SessionState;
pub const SessionSelector = wire.SessionSelector;

pub const readMessage = wire.readMessage;
pub const writeMessage = wire.writeMessage;
pub const encode = wire.encode;
pub const decode = wire.decode;
pub const send = wire.send;
pub const receive = wire.receive;

test {
    _ = sdk.wire;
    _ = sdk.frame;
    _ = sdk.client;
    _ = sdk.ipc;
    _ = sdk.manifest;
}
