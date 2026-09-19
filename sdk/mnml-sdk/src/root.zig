//! mnml-sdk — write an mnml integration in Zig.
//!
//!   wire      the Bridge v2 protocol (`docs/BRIDGE.md`)
//!   Mount     the sibling's end of a mount socket: hello, next, send
//!   Frame     the cell grid you paint; full or dirty-row sends
//!   Ipc       tier 2: toasts, progress, statusline segments, badges,
//!             `register-command` over `$MNML_IPC_DIR/command`
//!   manifest  `Manifest` + `write` for `--install`
//!   ratelimit one cross-process token bucket per service, shared with
//!             every other process on the machine
//!   store     what an integration already knows, kept between runs:
//!             `<data root>/cache/<service>/` keyed by the SERVER's
//!             own `updated` stamp, so a pane paints on open and only
//!             asks about what moved
//!   request_log
//!             one JSON line per request under
//!             `<data root>/requests/<service>.jsonl` — what a slow
//!             pane spent, and what it spent it waiting on
//!   zon_edit  saving a hand-written ZON file without losing its
//!             comments — the splice the host's settings and an
//!             integration's own config both write through
//!   pane      the pane toolkit: mnml's chrome (caps header + chip
//!             ladder, tab strip, filter pill, app-colour left gutter,
//!             row ground, `Show more (N)`, a detail panel with `×` and
//!             a scrollbar, a clickable hint row), the host theme's
//!             roles, and the hit map
//!
//! A minimal integration is `sdk/examples/hello`.

pub const wire = @import("wire.zig");
pub const client = @import("client.zig");
pub const frame = @import("frame.zig");
pub const ipc = @import("ipc.zig");
pub const manifest = @import("manifest.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const request_log = @import("request_log.zig");
pub const store = @import("store.zig");
pub const pane = @import("pane.zig");
pub const zon_edit = @import("zon_edit.zig");

pub const Mount = client.Mount;
pub const Frame = frame.Frame;
pub const Style = frame.Style;
/// One painted cell — what a test reads when it needs the colour a
/// row came out in, which the text dump does not carry.
pub const Slot = frame.Slot;
pub const Ipc = ipc.Ipc;
pub const Manifest = manifest.Manifest;
pub const Limiter = ratelimit.Limiter;
pub const RequestLog = request_log.Log;
pub const Store = store.Store;
pub const HostMessage = wire.HostMessage;
pub const SiblingMessage = wire.SiblingMessage;
pub const Color = wire.Color;
pub const Mods = wire.Mods;
pub const protocol = wire.protocol;
pub const Theme = pane.Theme;
pub const Painter = pane.Painter;
pub const HitMap = pane.HitMap;
pub const Rect = pane.Rect;

test {
    _ = wire;
    _ = client;
    _ = frame;
    _ = ipc;
    _ = manifest;
    _ = ratelimit;
    _ = request_log;
    _ = store;
    _ = pane;
    _ = zon_edit;
}
