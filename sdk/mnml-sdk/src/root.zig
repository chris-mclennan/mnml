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
//!   broker    the local broker: one queue per service in four
//!             priority classes over a Unix socket, in front of that
//!             same bucket — absent is the normal case, and every
//!             client falls back to the file
//!   warm      the warmer: paced sending with interactive priority,
//!             one warmer per service across processes, delta windows,
//!             per-kind intervals and the budget floor
//!   store     what an integration already knows, kept between runs:
//!             `<data root>/cache/<service>/` keyed by the SERVER's
//!             own `updated` stamp, so a pane paints on open and only
//!             asks about what moved
//!   request_log
//!             one JSON line per request under
//!             `<data root>/requests/<service>.jsonl` — what a slow
//!             pane spent, and what it spent it waiting on
//!   budget    the API budget a pane shows and obeys: the latest
//!             rate-limit headers, a 429's pause (Retry-After, else a
//!             jittered exponential backoff), cache hits and misses, a
//!             daily tally shared across processes, and dry run
//!   base_url  the `$<SERVICE>_BASE_URL` override a test points an
//!             integration at its fake with — a URL or `@<file>`; a
//!             file that never arrives is an error, never a fallback
//!   zon_edit  saving a hand-written ZON file without losing its
//!             comments — the splice the host's settings and an
//!             integration's own config both write through
//!   platform  the platform's URL opener (`xdg-open`, `open`, and on
//!             Windows `rundll32 url.dll,FileProtocolHandler` — never
//!             `cmd`, which splits a URL at its `&`)
//!   testing   test allocators an integration's suite borrows —
//!             `Scribble`, which poisons what it frees so a slice into
//!             a let-go arena reads as `0xAA` rather than as luck
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
pub const broker = @import("broker.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const request_log = @import("request_log.zig");
pub const budget = @import("budget.zig");
pub const store = @import("store.zig");
pub const warm = @import("warm.zig");
pub const pane = @import("pane.zig");
pub const zon_edit = @import("zon_edit.zig");
pub const platform = @import("platform.zig");
pub const base_url = @import("base_url.zig");
pub const testing = @import("testing.zig");

pub const Mount = client.Mount;
pub const Frame = frame.Frame;
pub const Style = frame.Style;
/// One painted cell — what a test reads when it needs the colour a
/// row came out in, which the text dump does not carry.
pub const Slot = frame.Slot;
pub const Ipc = ipc.Ipc;
pub const Manifest = manifest.Manifest;
pub const Limiter = ratelimit.Limiter;
pub const BrokerClass = broker.Class;
pub const RequestLog = request_log.Log;
pub const Budget = budget.Budget;
pub const Store = store.Store;
pub const Gate = warm.Gate;
pub const WarmLock = warm.Lock;
pub const HostMessage = wire.HostMessage;
pub const SiblingMessage = wire.SiblingMessage;
pub const Color = wire.Color;
pub const Mods = wire.Mods;
pub const protocol = wire.protocol;
pub const Theme = pane.Theme;
pub const Painter = pane.Painter;
pub const HitMap = pane.HitMap;
pub const Rect = pane.Rect;
/// An allocator that poisons what it frees — see `testing.Scribble`.
pub const Scribble = testing.Scribble;

test {
    _ = wire;
    _ = client;
    _ = frame;
    _ = ipc;
    _ = manifest;
    _ = broker;
    _ = ratelimit;
    _ = request_log;
    _ = budget;
    _ = store;
    _ = warm;
    _ = pane;
    _ = zon_edit;
    _ = platform;
    _ = base_url;
    _ = testing;
}
