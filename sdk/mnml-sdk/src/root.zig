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
//!   feed      what changed, and when to ask: the adaptive poll
//!             interval (backs off while nothing moves, snaps back on
//!             a change or a key), and a JSONL event file anything can
//!             append to — one seam, two sources (`docs/SDK.md`)
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

/// The SDK's own version — `build.zig.zon`'s `.version`, as a value an
/// integration and the host can both read. An integration built on this
/// SDK is offered by an mnml whose SDK is compatible with it
/// (`compatible`): the same major, and for a 0.x SDK the same minor —
/// what a patch release may change without breaking a binary built on
/// the one before. The release index (`integrations.json`) records it
/// per integration; mnml's host test holds this string to the file.
pub const version = "0.1.0";

/// Whether an integration built on SDK `built_on` runs under a host
/// whose SDK is `host`: the same major, and for a 0.x SDK the same
/// minor. A version that does not parse is never compatible.
pub fn compatible(host: []const u8, built_on: []const u8) bool {
    const h = majorMinor(host) orelse return false;
    const b = majorMinor(built_on) orelse return false;
    if (h[0] != b[0]) return false;
    return h[0] != 0 or h[1] == b[1];
}

/// Whether an integration stamped with SDK `stamp` (the manifest's
/// `.sdk`, written by `--install`) was built behind `current` — the SDK
/// this host carries. An empty stamp is a manifest written before the
/// field existed, so it counts as behind; one that does not parse
/// counts as behind too, since nothing says it is current. A stamp
/// AHEAD of `current` is not behind: it was built on a newer SDK, and
/// rebuilding it here would move it backwards.
pub fn behind(stamp: []const u8, current: []const u8) bool {
    const s = triple(stamp) orelse return true;
    const c = triple(current) orelse return false;
    for (s, c) |a, b| if (a != b) return a < b;
    return false;
}

fn triple(v: []const u8) ?[3]u32 {
    const core = v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
    var it = std.mem.splitScalar(u8, core, '.');
    var out: [3]u32 = undefined;
    for (&out) |*n| n.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return out;
}

fn majorMinor(v: []const u8) ?[2]u32 {
    const core = v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
    var it = std.mem.splitScalar(u8, core, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const patch = it.next() orelse return null;
    _ = std.fmt.parseInt(u32, patch, 10) catch return null;
    if (it.next() != null) return null;
    return .{ major, minor };
}

test "compatible: same major, and the same minor below 1.0" {
    const t = std.testing;
    try t.expect(compatible("0.1.0", "0.1.0"));
    try t.expect(compatible("0.1.3", "0.1.0"));
    try t.expect(!compatible("0.2.0", "0.1.0"));
    try t.expect(!compatible("0.1.0", "0.2.0"));
    try t.expect(compatible("1.4.0", "1.0.2"));
    try t.expect(!compatible("2.0.0", "1.9.9"));
    try t.expect(compatible("0.1.0-rc1", "0.1.0"));
    try t.expect(!compatible("0.1", "0.1.0"));
    try t.expect(!compatible("", "0.1.0"));
    try t.expect(!compatible("0.1.0", "x.y.z"));
    try t.expect(compatible(version, version));
}

test "behind: an older stamp, a missing one and a broken one are behind; equal and newer are not" {
    const t = std.testing;
    try t.expect(behind("0.1.0", "0.2.0"));
    try t.expect(behind("0.1.9", "0.1.10"));
    try t.expect(behind("", "0.1.0"));
    try t.expect(behind("zero", "0.1.0"));
    try t.expect(!behind("0.1.0", "0.1.0"));
    try t.expect(!behind("0.2.0", "0.1.0"));
    try t.expect(!behind("1.0.0-rc1", "1.0.0"));
    try t.expect(!behind(version, version));
}

const std = @import("std");
pub const wire = @import("wire.zig");
pub const client = @import("client.zig");
pub const frame = @import("frame.zig");
pub const ipc = @import("ipc.zig");
pub const manifest = @import("manifest.zig");
pub const broker = @import("broker.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const request_log = @import("request_log.zig");
pub const budget = @import("budget.zig");
pub const feed = @import("feed.zig");
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
    _ = feed;
    _ = store;
    _ = warm;
    _ = pane;
    _ = zon_edit;
    _ = platform;
    _ = base_url;
    _ = testing;
}
