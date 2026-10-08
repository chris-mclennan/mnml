//! The offline switch: one process-wide flag that every outbound HTTP
//! path asks before it opens a socket. `--demo` sets it (the demo is "a
//! populated mnml you can try without the network", `config/demo.zig`),
//! and so does `MNML_OFFLINE=1` — the look harness, a train, a machine
//! that must not phone home.
//!
//! mnml reads no proxy variables (`HTTPS_PROXY` and friends): its own
//! client takes a proxy from a request's `# @proxy` or the config only.
//! A proxy that refuses is therefore no guard for mnml's own requests;
//! this switch is.
//!
//! Two layers ask it:
//!
//!   * `gate` — every sender (`http/client.zig` `send`, the Messages
//!     API client, the usage poller). Under the switch a URL whose host
//!     is not loopback is refused before a socket opens; loopback still
//!     goes out, because the demo's own fakes and the corpus's servers
//!     live there and are not "the network".
//!   * `App.offline` — mnml's own fetches decide earlier, with a message
//!     that names what was skipped: the Marketplace lists only what is
//!     bundled (no release index, no GitHub source, no download), the
//!     update checks say "offline" instead of asking GitHub. The App
//!     reads its own environment too, so a `.test` file's `# env:
//!     MNML_OFFLINE=1` switches one App without touching the process.

const std = @import("std");

pub const Reason = enum(u8) {
    online = 0,
    /// `--demo` (`MNML_DEMO` is set in the re-executed process).
    demo = 1,
    /// `MNML_OFFLINE=1`.
    env = 2,

    /// What a refusal says: `offline (demo)` / `offline (MNML_OFFLINE=1)`.
    pub fn label(r: Reason) []const u8 {
        return switch (r) {
            .online => "online",
            .demo => "offline (demo)",
            .env => "offline (MNML_OFFLINE=1)",
        };
    }
};

pub const env_var = "MNML_OFFLINE";

var state = std.atomic.Value(u8).init(@intFromEnum(Reason.online));
/// Sends `gate` refused since the process started — what the tests read
/// to prove nothing went out.
var refusals = std.atomic.Value(u32).init(0);

/// Turn the switch on (or off, with `.online`). `main` calls it once,
/// from the process environment, before anything can send.
pub fn set(r: Reason) void {
    state.store(@intFromEnum(r), .release);
}

pub fn reason() Reason {
    return @enumFromInt(state.load(.acquire));
}

pub fn refused() u32 {
    return refusals.load(.acquire);
}

/// The reason an environment asks for: `MNML_OFFLINE=1` first, then a
/// demo workspace (`MNML_DEMO`), else online.
pub fn fromEnv(env: *const std.process.Environ.Map) Reason {
    if (env.get(env_var)) |v| if (std.mem.eql(u8, std.mem.trim(u8, v, " "), "1")) return .env;
    if (env.get("MNML_DEMO")) |v| if (v.len > 0) return .demo;
    return .online;
}

/// The host of `url` (`scheme://[user@]host[:port]/…`), lower-case not
/// applied; null when there is none.
fn hostOf(url: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, url, " \t");
    const after = if (std.mem.indexOf(u8, trimmed, "://")) |i| trimmed[i + 3 ..] else trimmed;
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    var auth = after[0..end];
    if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth = auth[at + 1 ..];
    if (auth.len == 0) return null;
    if (auth[0] == '[') {
        const close = std.mem.indexOfScalar(u8, auth, ']') orelse return null;
        return auth[1..close];
    }
    const colon = std.mem.indexOfScalar(u8, auth, ':') orelse return auth;
    return auth[0..colon];
}

/// Whether `url` stays on this machine: `localhost`, `127.0.0.0/8`, `::1`.
pub fn isLoopback(url: []const u8) bool {
    const host = hostOf(url) orelse return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    // A dotted IPv4 address in 127/8 — not a name that merely starts
    // with "127." (`127.example.com` is somebody's server).
    if (!std.mem.startsWith(u8, host, "127.")) return false;
    for (host) |c| if (c != '.' and !std.ascii.isDigit(c)) return false;
    return true;
}

/// The one gate every sender asks: null when `url` may go out, else the
/// switch's reason (and the refusal is counted).
pub fn gate(url: []const u8) ?Reason {
    const r = reason();
    if (r == .online or isLoopback(url)) return null;
    _ = refusals.fetchAdd(1, .acq_rel);
    return r;
}

/// The one-line refusal a sender returns in place of a response. Owned.
pub fn message(gpa: std.mem.Allocator, r: Reason, url: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}: not sent — {s} is off this machine", .{ r.label(), hostOf(url) orelse url });
}

const t = std.testing;

test "the switch reads MNML_OFFLINE=1 before the demo, and nothing else" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try t.expectEqual(Reason.online, fromEnv(&env));
    try env.put("MNML_OFFLINE", "0");
    try t.expectEqual(Reason.online, fromEnv(&env));
    try env.put("MNML_DEMO", "/x/tour");
    try t.expectEqual(Reason.demo, fromEnv(&env));
    try env.put("MNML_OFFLINE", "1");
    try t.expectEqual(Reason.env, fromEnv(&env));
}

test "the gate lets loopback through and refuses everything else, counting each refusal" {
    defer set(.online);
    try t.expectEqual(@as(?Reason, null), gate("https://api.github.com/x"));
    set(.demo);
    const before = refused();
    try t.expectEqual(@as(?Reason, .demo), gate("https://api.github.com/repos/x/releases/latest"));
    try t.expectEqual(@as(?Reason, .demo), gate("http://user:pw@example.org:8080/a"));
    try t.expectEqual(@as(?Reason, null), gate("http://127.0.0.1:4000/integrations.json"));
    try t.expectEqual(@as(?Reason, null), gate("http://localhost/x"));
    try t.expectEqual(@as(?Reason, null), gate("http://[::1]:9/x"));
    try t.expectEqual(@as(?Reason, .demo), gate("http://127.example.com/x"));
    try t.expectEqual(before + 3, refused());
    const msg = try message(t.allocator, .demo, "https://github.com/a/b");
    defer t.allocator.free(msg);
    try t.expectEqualStrings("offline (demo): not sent — github.com is off this machine", msg);
}
