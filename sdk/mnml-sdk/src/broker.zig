//! The local broker: one queue per service, in priority classes, over
//! a Unix socket.
//!
//! `ratelimit` already makes every process on the machine draw from one
//! token bucket, so the budget is shared. What it cannot do is decide
//! **who gets the next token**: the file bucket is first-come, so the
//! pane the user is looking at takes its turn behind whatever batch
//! script happened to ask a millisecond earlier. On a machine running a
//! dozen Claude sessions, mnml and a handful of loops, that is the
//! difference between a pane that paints and a pane that says
//! `loading…` for half a minute.
//!
//! So: a broker. One process per service holds the bucket and hands
//! tokens out in four classes —
//!
//!   1. `interactive`  the pane you are looking at
//!   2. `refresh`      a pane refresh, the `--values` poller
//!   3. `warm`         the warmer, delta sweeps, prefetch
//!   4. `batch`        shell scripts, capture tools, anything queued
//!
//! **The rule, written down.** Waiters are served by *effective class*,
//! and ties by arrival order. A waiter's effective class is its
//! declared class promoted one step for every full `age_step_ms` it has
//! been queued, capped at `interactive`. So a `batch` waiter reaches
//! `interactive` after three steps (30 s by default) however busy the
//! front of the queue is, and strict priority never becomes starvation.
//! `Queue` is the whole of it and is testable without a socket.
//!
//! **One bucket, still.** The broker does not keep a bucket of its own:
//! it holds a `ratelimit.Limiter` on the SAME state file every file
//! client uses, under the same exclusive lock the Python
//! `bb_ratelimit.py` takes. So a Python process that predates the
//! broker keeps working, the draw lines keep being written, a 429 seen
//! anywhere still parks everyone, and "tokens left" is one number
//! wherever you read it. The broker is a queue in front of the bucket,
//! never a second bucket.
//!
//! **Absent is the normal case.** mnml hosts the broker while it runs;
//! the rest of the time there is none. Every client tries the socket
//! and falls back to the file bucket — see `ratelimit.acquireVia` —
//! so nothing on the machine depends on mnml being open.
//!
//! **The wire** is one line of JSON per message, because the other end
//! is as likely to be twenty lines of Python as it is to be this file:
//!
//! ```
//! → {"v":1,"op":"acquire","service":"bitbucket","class":"interactive","client":"mnml-jira:1234","reason":"pane_open","timeout_ms":5000}
//! ← {"ok":true,"wait_ms":0,"remaining":12.4}
//! ← {"ok":false,"why":"timeout"}
//! ```
//!
//! One request, one reply, then the connection closes. `status` answers
//! with the service's budget, the queue depth by class and the recent
//! draws instead.
//!
//! Where the socket is, in the same order the state file resolves:
//!
//!   1. `<SERVICE>_BROKER_SOCKET` names it outright
//!   2. beside the ratelimit state file, `<service>-broker.sock`
//!   3. and if that DERIVED path will not fit a `sockaddr_un`, a short
//!      `/tmp` name derived from the service alone, so two processes
//!      deriving it still agree.
//!
//! An explicit override is never moved to `/tmp` — a socket somewhere
//! other than the place the user named is worse than none — so one
//! past the limit is refused, by name and by length, at the `serve`,
//! at mnml's election and at `broker status`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ratelimit = @import("ratelimit.zig");

/// Unix sockets are the whole transport. Windows gets the file bucket
/// and no broker — `ratelimit.acquireVia` is written so that is a
/// path, not a hole.
pub const supported = Io.net.has_unix_sockets;

/// The protocol version every message carries. A peer that sends
/// another one is answered `bad_request` rather than guessed at.
pub const version: u8 = 1;

/// How long a DERIVED socket path may be before the short `/tmp` name
/// is used instead. Deliberately under `os_max_path_len`, and the same
/// number on every platform: the two ends of this socket derive their
/// path independently, so the rule that picks between "beside the
/// bucket" and `/tmp` has to give both of them the same answer.
pub const max_path_len: usize = 100;

/// What this platform's `sockaddr_un.sun_path` holds, NUL included:
/// 104 bytes on macOS, 108 on Linux. `Io.net.UnixAddress.max_len`
/// believes 108 everywhere that is not Windows — four bytes past the
/// end of the struct on macOS — and `listen` asserts rather than
/// erroring, so this, not the runtime, is what says a path fits.
pub const os_path_len: usize = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => 104,
    else => 108,
};

/// The longest socket path this machine can bind OR connect to: the
/// `sun_path` above, less the NUL. Past it there is no broker for
/// anybody — which is why an explicit `<SERVICE>_BROKER_SOCKET` past
/// it is refused with a sentence up front rather than left to fail at
/// the bind, where all anybody saw was `BindFailed`.
pub const os_max_path_len: usize = os_path_len - 1;

/// Whether `path` is past what a `sockaddr_un` on this machine holds.
///
/// A derived path never is — `socketPath` falls back to `/tmp` well
/// before this — so a true here always means an explicit
/// `<SERVICE>_BROKER_SOCKET` named it, which is what
/// `explainPathTooLong` tells the reader to go and fix.
pub fn pathTooLong(path: []const u8) bool {
    return path.len > os_max_path_len;
}

/// Room for the longest sentence `explainPathTooLong` or
/// `explainStart` writes.
pub const explain_max: usize = 256;

/// Why a path that is too long is too long, as a sentence:
///
///     socket path is 131 bytes; the OS allows 103 — set
///     BITBUCKET_BROKER_SOCKET shorter or unset it for the default
///
/// Both numbers are there on purpose. The length is the one the reader
/// can measure against their own setting; the limit is the one nobody
/// carries around, and `BindFailed` never hinted a length was the
/// problem at all. Written into `buf` — pass `explain_max` bytes.
pub fn explainPathTooLong(buf: []u8, service: []const u8, path: []const u8) []const u8 {
    var name_buf: [max_service_len + "_BROKER_SOCKET".len]u8 = undefined;
    const name = socketEnvName(&name_buf, service) orelse "the broker socket override";
    return std.fmt.bufPrint(
        buf,
        "socket path is {d} bytes; the OS allows {d} — set {s} shorter or unset it for the default",
        .{ path.len, os_max_path_len, name },
    ) catch "socket path is too long for a sockaddr_un";
}

// ─── classes ─────────────────────────────────────────────────────────────

/// Who is waiting, in the order they are served. Declared highest
/// first, so the enum's own order IS the priority and `@intFromEnum`
/// compares the right way round.
pub const Class = enum(u2) {
    /// The pane on screen, a click, a detail the reader opened.
    interactive,
    /// A pane refresh and the statusline poller's `--values` run —
    /// wanted soon, but nobody is watching the spinner.
    refresh,
    /// The warmer, a delta sweep, a prefetch. Speculative.
    warm,
    /// A shell script, a capture tool, anything that should queue
    /// behind every pane on the machine.
    batch,

    pub fn tag(c: Class) []const u8 {
        return @tagName(c);
    }

    /// The class a name spells, or null. Case-sensitive: these are
    /// wire tokens, not user input.
    pub fn parse(name: []const u8) ?Class {
        inline for (@typeInfo(Class).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    /// One step nearer the front. `interactive` is already there.
    pub fn promoted(c: Class) Class {
        const n = @intFromEnum(c);
        return if (n == 0) c else @enumFromInt(n - 1);
    }
};

/// How long a waiter must be queued to be promoted one class. Three of
/// these is the longest a `batch` waiter can sit behind a busy front:
/// 30 s, which is well inside the `timeout_ms` a batch caller sets and
/// far outside anything a person would notice.
pub const age_step_ms: i64 = 10_000;

// ─── the queue ───────────────────────────────────────────────────────────

/// One waiter, as the queue holds it. `seq` is the arrival order and
/// is what breaks a tie between two waiters of one effective class —
/// so the queue is FIFO within a class and strict between them.
pub const Waiter = struct {
    class: Class,
    enqueued_ms: i64,
    seq: u64,

    /// The class this waiter is served AS, at `now_ms`: its declared
    /// class, promoted one step per full `age_step_ms` waited, capped
    /// at `interactive`. A clock that went backwards promotes nothing.
    pub fn effective(w: Waiter, now_ms: i64) Class {
        const waited = now_ms - w.enqueued_ms;
        if (waited < age_step_ms) return w.class;
        const steps: u64 = @intCast(@divTrunc(waited, age_step_ms));
        const n = @intFromEnum(w.class);
        if (steps >= n) return .interactive;
        return @enumFromInt(n - @as(u2, @intCast(steps)));
    }
};

/// The most waiters one service queues before the broker starts
/// refusing. A machine that has this many things queued on one API has
/// a bigger problem than the queue, and an unbounded queue is a way to
/// run out of memory quietly.
pub const max_waiters: usize = 256;

/// Waiters for one service, served by the rule above. Pure: it holds
/// no socket, no allocator and no clock, so the ordering can be tested
/// without either.
pub const Queue = struct {
    buf: [max_waiters]Waiter = undefined,
    n: usize = 0,
    next_seq: u64 = 0,

    pub const Error = error{Full};

    pub fn items(q: *const Queue) []const Waiter {
        return q.buf[0..q.n];
    }

    /// Join the queue. The handle is the waiter's `seq`, which is how
    /// it is taken out again.
    pub fn push(q: *Queue, class: Class, now_ms: i64) Error!u64 {
        if (q.n >= max_waiters) return error.Full;
        const seq = q.next_seq;
        q.next_seq += 1;
        q.buf[q.n] = .{ .class = class, .enqueued_ms = now_ms, .seq = seq };
        q.n += 1;
        return seq;
    }

    /// Who is served next at `now_ms`, or null when nobody is waiting.
    /// Does not remove: `take` does that, so a caller can look at the
    /// head before it has a token to give it.
    pub fn head(q: *const Queue, now_ms: i64) ?Waiter {
        var best: ?Waiter = null;
        for (q.items()) |w| {
            const b = best orelse {
                best = w;
                continue;
            };
            const we = @intFromEnum(w.effective(now_ms));
            const be = @intFromEnum(b.effective(now_ms));
            if (we < be or (we == be and w.seq < b.seq)) best = w;
        }
        return best;
    }

    /// Serve the head: it leaves the queue and is returned.
    pub fn take(q: *Queue, now_ms: i64) ?Waiter {
        const w = q.head(now_ms) orelse return null;
        _ = q.remove(w.seq);
        return w;
    }

    /// Take one waiter out by its handle — a caller that timed out or
    /// hung up. True when it was still there. Arrival order is kept,
    /// because it is what breaks a tie.
    pub fn remove(q: *Queue, seq: u64) bool {
        for (q.items(), 0..) |w, i| {
            if (w.seq == seq) {
                var j = i;
                while (j + 1 < q.n) : (j += 1) q.buf[j] = q.buf[j + 1];
                q.n -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn len(q: *const Queue) usize {
        return q.n;
    }

    /// How many are waiting in each declared class — what the REQUESTS
    /// pane's header and a `status` reply both say. Indexed by
    /// `@intFromEnum(Class)`.
    pub fn depths(q: *const Queue) [4]u32 {
        var out: [4]u32 = @splat(0);
        for (q.items()) |w| out[@intFromEnum(w.class)] += 1;
        return out;
    }
};

// ─── the wire ────────────────────────────────────────────────────────────

/// The longest line either side will read. A request is a hundred-odd
/// bytes and a `status` reply a few hundred; past this something is
/// wrong and the connection is dropped rather than grown.
pub const max_line = 8192;

pub const Op = enum {
    acquire,
    status,

    pub fn parse(name: []const u8) ?Op {
        if (std.mem.eql(u8, name, "acquire")) return .acquire;
        if (std.mem.eql(u8, name, "status")) return .status;
        return null;
    }
};

/// A request, as it arrives. Every slice points into the caller's own
/// line buffer, so nothing here is owned.
pub const Request = struct {
    v: u8 = version,
    op: Op = .acquire,
    service: []const u8 = "",
    class: Class = .batch,
    /// `<program>:<pid>` — who is asking, for the log and the status
    /// reply. Never trusted for anything but naming.
    client: []const u8 = "",
    reason: []const u8 = "",
    /// How long the caller will wait before it gives up and sends
    /// anyway. 0 means "do not queue at all: a token or nothing".
    timeout_ms: u32 = 0,

    /// One line, newline included, into `buf`.
    pub fn render(r: Request, buf: []u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "{{\"v\":{d},\"op\":\"{s}\",\"service\":\"{f}\",\"class\":\"{s}\",\"client\":\"{f}\",\"reason\":\"{f}\",\"timeout_ms\":{d}}}\n",
            .{
                r.v,
                @tagName(r.op),
                std.zig.fmtString(r.service),
                r.class.tag(),
                std.zig.fmtString(r.client),
                std.zig.fmtString(r.reason),
                r.timeout_ms,
            },
        ) catch "{\"v\":1,\"op\":\"status\"}\n";
    }

    /// Read one back. Null when the line is not a request at all; a
    /// field that is missing takes its default, and an unknown `op` or
    /// `class` is the caller's error to answer, not this function's to
    /// guess at.
    pub fn parse(line: []const u8) ?Request {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{') return null;
        var r: Request = .{};
        r.v = @intFromFloat(@max(@min(jsonNumber(trimmed, "v") orelse @as(f64, version), 255), 0));
        if (jsonString(trimmed, "op")) |s| r.op = Op.parse(s) orelse return null;
        r.service = jsonString(trimmed, "service") orelse "";
        if (jsonString(trimmed, "class")) |s| r.class = Class.parse(s) orelse return null;
        r.client = jsonString(trimmed, "client") orelse "";
        r.reason = jsonString(trimmed, "reason") orelse "";
        r.timeout_ms = @intFromFloat(@max(@min(jsonNumber(trimmed, "timeout_ms") orelse 0, 3_600_000), 0));
        return r;
    }
};

/// Why an `acquire` came back `false`. Four words, so the caller can
/// tell "wait longer" from "there is no broker here".
pub const Why = enum {
    /// The caller's own `timeout_ms` ran out with no token.
    timeout,
    /// The broker is shutting down, or the bucket failed open under
    /// it — either way the caller should send anyway.
    closed,
    /// The line was not a request this version understands.
    bad_request,
    /// This broker holds a different service's bucket.
    wrong_service,

    pub fn tag(w: Why) []const u8 {
        return @tagName(w);
    }

    pub fn parse(name: []const u8) ?Why {
        inline for (@typeInfo(Why).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// What an `acquire` came back with.
pub const Reply = struct {
    ok: bool = false,
    /// How long the broker held the request, in milliseconds.
    wait_ms: u64 = 0,
    /// Tokens left in the shared bucket afterwards — the same number
    /// the file clients read, because it is the same bucket.
    remaining: f64 = 0,
    why: ?Why = null,

    pub fn render(rp: Reply, buf: []u8) []const u8 {
        if (rp.ok) {
            return std.fmt.bufPrint(buf, "{{\"ok\":true,\"wait_ms\":{d},\"remaining\":{d:.3}}}\n", .{ rp.wait_ms, @max(rp.remaining, 0) }) catch "{\"ok\":false,\"why\":\"closed\"}\n";
        }
        return std.fmt.bufPrint(buf, "{{\"ok\":false,\"wait_ms\":{d},\"why\":\"{s}\"}}\n", .{ rp.wait_ms, (rp.why orelse Why.closed).tag() }) catch "{\"ok\":false,\"why\":\"closed\"}\n";
    }

    pub fn parse(line: []const u8) ?Reply {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{') return null;
        return .{
            .ok = jsonTrue(trimmed, "ok"),
            .wait_ms = @intFromFloat(@max(jsonNumber(trimmed, "wait_ms") orelse 0, 0)),
            .remaining = jsonNumber(trimmed, "remaining") orelse 0,
            .why = if (jsonString(trimmed, "why")) |s| Why.parse(s) else null,
        };
    }
};

/// What a `status` says: the budget, the queue by class, and how much
/// the broker has handed out since it started. The REQUESTS pane's
/// header is this, in one line.
pub const StatusReply = struct {
    service: []const u8 = "",
    tokens: f64 = 0,
    capacity: f64 = 0,
    rate: f64 = 0,
    cooldown_secs: f64 = 0,
    /// Waiting now, indexed by `@intFromEnum(Class)`.
    queue: [4]u32 = @splat(0),
    /// Tokens the broker has handed out since it started.
    served: u64 = 0,
    /// Requests it refused for want of a token inside their timeout.
    timed_out: u64 = 0,
    /// Seconds the broker has been up.
    uptime_secs: u64 = 0,

    pub fn total(s: StatusReply) u32 {
        return s.queue[0] + s.queue[1] + s.queue[2] + s.queue[3];
    }

    /// The share of the bucket left, 0…100 — what the pane's header
    /// says as `42% budget`. A capacity of zero is 0%, never a divide.
    pub fn budgetPct(s: StatusReply) u8 {
        if (!(s.capacity > 0)) return 0;
        const pct = (@max(s.tokens, 0) / s.capacity) * 100.0;
        return @intFromFloat(@min(@max(pct, 0), 100));
    }

    pub fn render(s: StatusReply, buf: []u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "{{\"ok\":true,\"service\":\"{f}\",\"tokens\":{d:.3},\"capacity\":{d:.1},\"rate\":{d:.4},\"cooldown_secs\":{d:.1}," ++
                "\"queue\":{{\"interactive\":{d},\"refresh\":{d},\"warm\":{d},\"batch\":{d}}},\"served\":{d},\"timed_out\":{d},\"uptime_secs\":{d}}}\n",
            .{
                std.zig.fmtString(s.service), s.tokens,      s.capacity, s.rate,     s.cooldown_secs,
                s.queue[0],                   s.queue[1],    s.queue[2], s.queue[3], s.served,
                s.timed_out,                  s.uptime_secs,
            },
        ) catch "{\"ok\":false,\"why\":\"closed\"}\n";
    }

    /// Read one back. `service` points into `line`.
    pub fn parse(line: []const u8) ?StatusReply {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{') return null;
        if (!jsonTrue(trimmed, "ok")) return null;
        return .{
            .service = jsonString(trimmed, "service") orelse "",
            .tokens = jsonNumber(trimmed, "tokens") orelse 0,
            .capacity = jsonNumber(trimmed, "capacity") orelse 0,
            .rate = jsonNumber(trimmed, "rate") orelse 0,
            .cooldown_secs = jsonNumber(trimmed, "cooldown_secs") orelse 0,
            .queue = .{
                @intFromFloat(@max(jsonNumber(trimmed, "interactive") orelse 0, 0)),
                @intFromFloat(@max(jsonNumber(trimmed, "refresh") orelse 0, 0)),
                @intFromFloat(@max(jsonNumber(trimmed, "warm") orelse 0, 0)),
                @intFromFloat(@max(jsonNumber(trimmed, "batch") orelse 0, 0)),
            },
            .served = @intFromFloat(@max(jsonNumber(trimmed, "served") orelse 0, 0)),
            .timed_out = @intFromFloat(@max(jsonNumber(trimmed, "timed_out") orelse 0, 0)),
            .uptime_secs = @intFromFloat(@max(jsonNumber(trimmed, "uptime_secs") orelse 0, 0)),
        };
    }
};

// ─── where the socket is ─────────────────────────────────────────────────

/// Longest service name the per-service environment override can be
/// spelled for — the ratelimit module's own ceiling, so the two
/// resolutions agree about what a service may be called.
const max_service_len = 48;

/// `BITBUCKET_BROKER_SOCKET`, `JIRA_BROKER_SOCKET`, … Written into
/// `buf`; null when the service name will not fit.
pub fn socketEnvName(buf: []u8, service: []const u8) ?[]const u8 {
    const suffix = "_BROKER_SOCKET";
    if (service.len == 0 or service.len + suffix.len > buf.len) return null;
    for (service, 0..) |c, i| buf[i] = std.ascii.toUpper(sanitizeByte(c));
    @memcpy(buf[service.len..][0..suffix.len], suffix);
    return buf[0 .. service.len + suffix.len];
}

fn sanitizeByte(c: u8) u8 {
    return if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
}

/// Where the broker for `service` listens. Owned by the caller.
///
/// Derived the same way the ratelimit state file is, so the socket
/// sits beside the bucket it fronts and every process resolves the
/// same one. A path that will not fit a `sockaddr_un` (`sun_path` is
/// 104 bytes on macOS, so 103 of them may be path) falls back to a
/// short `/tmp` name — `fallbackPath` — derived from the service AND
/// the path it stands in for: deterministic, so two processes that
/// both fall back from the same bucket still meet, and distinct per
/// bucket, so two buckets never share one broker. The service alone
/// was the whole name once, and every deep bucket on the machine —
/// every test's private one included — met on the same socket and the
/// same election lock.
///
/// **The fallback is the DERIVED path's only.** An explicit
/// `<SERVICE>_BROKER_SOCKET` is returned exactly as it was set, long
/// or not: silently serving somewhere else than the place the user
/// named would be worse than refusing, and `pathTooLong` +
/// `explainPathTooLong` are how the refusal is said.
pub fn socketPath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error![]u8 {
    var name_buf: [max_service_len + "_BROKER_SOCKET".len]u8 = undefined;
    if (socketEnvName(&name_buf, service)) |name| {
        if (env.get(name)) |p| {
            if (p.len > 0) return gpa.dupe(u8, p);
        }
    }
    var svc_buf: [max_service_len]u8 = undefined;
    const n = @min(service.len, svc_buf.len);
    for (service[0..n], 0..) |c, i| svc_buf[i] = sanitizeByte(c);
    const svc = svc_buf[0..n];

    const state = try ratelimit.statePath(gpa, io, env, service);
    defer gpa.free(state);
    const dir = std.fs.path.dirname(state) orelse ".";
    const beside = try std.fmt.allocPrint(gpa, "{s}/{s}-broker.sock", .{ dir, svc });
    // Leave the same headroom the mount sockets do: a path at the
    // limit is a bind that fails for a reason nobody can read.
    if (beside.len <= max_path_len) return beside;
    defer gpa.free(beside);
    // Windows has no `/tmp` (it would be `\tmp` on the current drive,
    // which usually does not exist): `%TEMP%` is per user and the same
    // for every process of that user, so both sides still meet.
    if (@import("builtin").os.tag == .windows) {
        if (env.get("TEMP") orelse env.get("TMP")) |tmp_dir| if (tmp_dir.len > 0) return fallbackIn(gpa, tmp_dir, '\\', svc, beside);
    }
    return fallbackPath(gpa, svc, beside);
}

/// `/tmp/mnml-broker-<service>-<12 hex>.sock`: the short name a derived
/// path too long for a `sockaddr_un` is served at instead. The hex is
/// the first six bytes of the SHA-256 of the long path, so it is a pure
/// function of where the bucket is — the Python client
/// (`sdk/clients/ratelimit_broker.py`) computes the same one with
/// `hashlib` — and two buckets in two directories get two sockets and
/// two election locks. (`%TEMP%` in place of `/tmp` on Windows.) Owned
/// by the caller.
pub fn fallbackPath(gpa: Allocator, service: []const u8, derived: []const u8) Allocator.Error![]u8 {
    return fallbackIn(gpa, "/tmp", '/', service, derived);
}

fn fallbackIn(gpa: Allocator, dir: []const u8, sep: u8, service: []const u8, derived: []const u8) Allocator.Error![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(derived, &digest, .{});
    return std.fmt.allocPrint(gpa, "{s}{c}mnml-broker-{s}-{s}.sock", .{ dir, sep, service, &std.fmt.bytesToHex(digest[0..6].*, .lower) });
}

/// The election lock beside the socket: `<service>-broker.lock`, the
/// same shape `warm.Lock` writes, so one process per service holds the
/// broker and a second becomes a client. Owned by the caller.
pub fn lockPath(gpa: Allocator, socket: []const u8) Allocator.Error![]u8 {
    if (std.mem.endsWith(u8, socket, ".sock")) {
        return std.fmt.allocPrint(gpa, "{s}.lock", .{socket[0 .. socket.len - ".sock".len]});
    }
    return std.fmt.allocPrint(gpa, "{s}.lock", .{socket});
}

// ─── the one-line JSON readers ───────────────────────────────────────────

/// What follows `"key":` in one line, whitespace skipped — or null
/// when the key is not there.
///
/// **The space matters.** Python's `json.dumps` writes `"op": "acquire"`
/// by default, and this protocol exists to be readable from twenty
/// lines of Python stdlib. A reader that insists on `"op":"acquire"`
/// parses every field of such a line as missing and takes its default,
/// which for `acquire` is a timeout of zero — so the caller is refused
/// instantly and told nothing useful. Skip the whitespace.
fn jsonAfter(line: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var rest = line[at + needle.len ..];
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    return rest;
}

/// Whether `"key"` is `true`, whitespace and all.
fn jsonTrue(line: []const u8, key: []const u8) bool {
    const rest = jsonAfter(line, key) orelse return false;
    return std.mem.startsWith(u8, rest, "true");
}

/// `"key":<number>` out of one line, without parsing the whole thing —
/// these are single-shape messages on a hot path, and the other end of
/// the wire is as likely to be Python as it is to be this file.
fn jsonNumber(line: []const u8, key: []const u8) ?f64 {
    const rest = jsonAfter(line, key) orelse return null;
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.' or rest[end] == '-')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// `"key":"…"` out of one line. No escapes are decoded: a service or a
/// program name that needed them would not be one.
fn jsonString(line: []const u8, key: []const u8) ?[]const u8 {
    const rest0 = jsonAfter(line, key) orelse return null;
    if (rest0.len == 0 or rest0[0] != '"') return null;
    const rest = rest0[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// ─── the server ──────────────────────────────────────────────────────────

/// How often a waiting connection looks at its ticket. A local socket
/// and a bucket that refills at 0.22/s do not need a condition
/// variable; 20 ms is invisible against a 4.5 s gap and keeps the
/// waiting path a loop anyone can read.
pub const poll_ms: u64 = 20;

/// One queued caller's answer, written by the dispatcher and read by
/// the connection that is holding the caller. Intrusive, so the
/// registry costs no allocation on the serving path.
pub const Ticket = struct {
    seq: u64 = 0,
    next: ?*Ticket = null,
    /// Set last, with release ordering: everything above it is
    /// published by the time a reader sees this true.
    done: std.atomic.Value(bool) = .init(false),
    /// False means the bucket failed open under the broker — the
    /// caller should send anyway, exactly as a file client would.
    ok: bool = false,
    remaining: f64 = 0,
};

/// Everything the accept loop, the dispatcher and the connections
/// share. The queue itself is pure; this is the lock around it plus
/// the counters a `status` reply reads.
pub const Shared = struct {
    io: Io,
    mu: Io.Mutex = .init,
    queue: Queue = .{},
    tickets: ?*Ticket = null,
    stopping: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(u64) = .init(0),
    timed_out: std.atomic.Value(u64) = .init(0),
    started_secs: i64 = 0,

    /// Join the queue with a ticket to be answered on.
    pub fn enqueue(s: *Shared, tk: *Ticket, class: Class, now_ms: i64) Queue.Error!void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        tk.seq = try s.queue.push(class, now_ms);
        tk.next = s.tickets;
        s.tickets = tk;
    }

    /// Leave it unanswered — a caller that timed out or hung up.
    /// True when the ticket was still queued.
    pub fn withdraw(s: *Shared, tk: *Ticket) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.unlink(tk);
        return s.queue.remove(tk.seq);
    }

    /// Hand one token to whoever is at the front at `now_ms`. False
    /// when nobody was waiting — the caller then holds the token as a
    /// spare rather than dropping it on the floor.
    pub fn fulfil(s: *Shared, now_ms: i64, ok: bool, remaining: f64) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const w = s.queue.take(now_ms) orelse return false;
        var it = s.tickets;
        while (it) |tk| : (it = tk.next) {
            if (tk.seq != w.seq) continue;
            s.unlink(tk);
            tk.ok = ok;
            tk.remaining = remaining;
            tk.done.store(true, .release);
            return true;
        }
        // A ticket that went without withdrawing itself. The token is
        // the caller's to keep as a spare, so say nobody took it.
        return false;
    }

    /// Answer everyone still queued `closed`, so a broker going down
    /// releases its callers to the file bucket rather than to their
    /// timeouts.
    pub fn releaseAll(s: *Shared) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var it = s.tickets;
        while (it) |tk| {
            const next = tk.next;
            tk.next = null;
            tk.ok = false;
            tk.done.store(true, .release);
            it = next;
        }
        s.tickets = null;
        s.queue = .{ .next_seq = s.queue.next_seq };
    }

    pub fn depths(s: *Shared) [4]u32 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.queue.depths();
    }

    pub fn waiting(s: *Shared) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.queue.len();
    }

    /// Caller holds the lock.
    fn unlink(s: *Shared, tk: *Ticket) void {
        var prev: ?*Ticket = null;
        var it = s.tickets;
        while (it) |cur| : ({
            prev = cur;
            it = cur.next;
        }) {
            if (cur != tk) continue;
            if (prev) |p| p.next = cur.next else s.tickets = cur.next;
            cur.next = null;
            return;
        }
    }
};

/// The broker for one service: a Unix socket, a queue, and the shared
/// token bucket behind both.
///
/// The host starts one per service and stops it on quit. It is NOT the
/// thing that decides whether it may run — that is the election lock
/// (`lockPath`), which the host holds, so a second mnml becomes a
/// client of the first rather than a second broker.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    /// Owned.
    service: []u8,
    /// Owned.
    socket_path: []u8,
    limiter: ratelimit.Limiter,
    shared: Shared,
    listener: ?Io.net.Server = null,
    group: Io.Group = .init,
    /// The token drawn for a waiter that left before it landed. Held
    /// rather than dropped: it came out of the shared bucket and the
    /// bucket has no way to take one back. At most one is ever held.
    spare: ?f64 = null,

    /// Why a broker did not come up. Every one of these is a sentence
    /// in `explainStart`: `BindFailed` on its own sent the reader to
    /// read this file, which is the bug this set exists to fix.
    pub const StartError = error{
        Unsupported,
        /// An explicit `<SERVICE>_BROKER_SOCKET` past `os_max_path_len`.
        PathTooLong,
        /// Something is already bound there — or a socket file is in
        /// the way that we were not allowed to take away.
        AddressInUse,
        PermissionDenied,
        /// The directory the socket would sit in is not there.
        DirMissing,
        /// Anything else the bind said.
        BindFailed,
        ListenFailed,
    } || Allocator.Error;

    pub const Options = struct {
        /// Which bucket this broker fronts — and, through
        /// `socketPath`, where it listens.
        service: []const u8,
        /// This process, as the bucket's draw lines name it: argv[0]'s
        /// basename and the pid. A broker that cannot say who drew
        /// writes no draw lines, exactly as a file client would not.
        program: []const u8 = "",
        pid: i32 = 0,
        /// Override the service preset. Only a test sets this — to
        /// make a bucket refill in milliseconds so an ordering can be
        /// proved inside a test run rather than a coffee break.
        config: ?ratelimit.Config = null,
    };

    /// Bind `<service>-broker.sock`, take the bucket, and start the
    /// accept loop and the dispatcher.
    pub fn start(
        gpa: Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        opts: Options,
    ) StartError!*Server {
        if (!supported) return error.Unsupported;
        const service = opts.service;
        const sock = try socketPath(gpa, io, env, service);
        errdefer gpa.free(sock);
        const svc = try gpa.dupe(u8, service);
        errdefer gpa.free(svc);

        if (pathTooLong(sock)) return error.PathTooLong;
        if (std.fs.path.dirname(sock)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        // A socket file left by a broker that crashed would block the
        // bind. The election lock, not the file, is what says whether
        // somebody else is really serving.
        Io.Dir.cwd().deleteFile(io, sock) catch {};
        const addr = Io.net.UnixAddress.init(sock) catch return error.PathTooLong;
        var listener = addr.listen(io, .{}) catch |err| return bindError(err);
        errdefer listener.deinit(io);

        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .service = svc,
            .socket_path = sock,
            .limiter = try ratelimit.Limiter.forService(gpa, io, env, service),
            .shared = .{ .io = io, .started_secs = Io.Timestamp.now(io, .real).toSeconds() },
            .listener = listener,
        };
        errdefer s.limiter.deinit();
        if (opts.config) |c| s.limiter.cfg = c;
        // The broker never writes a draw line of its own. A token it
        // draws is spent by whoever asked for it, and it is the CLIENT
        // that writes `<service>-draws.jsonl` once the reply lands —
        // so the machine-wide file keeps saying `mnml-jira` and
        // `bb.py` rather than turning every brokered draw into one
        // line that says `mnml-zig`. One line per token either way.
        s.limiter.draws = false;
        if (opts.program.len > 0) try s.limiter.identify(service, opts.program, opts.pid);
        s.group.concurrent(io, dispatch, .{s}) catch return error.ListenFailed;
        s.group.concurrent(io, accept, .{s}) catch return error.ListenFailed;
        return s;
    }

    /// Where it is listening — what an integration is told in
    /// `<SERVICE>_BROKER_SOCKET`.
    pub fn path(s: *const Server) []const u8 {
        return s.socket_path;
    }

    /// The header's numbers, without a round trip: the host paints
    /// its own broker rather than talking to itself.
    pub fn snapshot(s: *Server) StatusReply {
        const st = s.limiter.status();
        return .{
            .service = s.service,
            .tokens = if (st) |v| v.tokens else 0,
            .capacity = if (st) |v| v.capacity else s.limiter.cfg.capacity,
            .rate = if (st) |v| v.rate else s.limiter.cfg.rate,
            .cooldown_secs = if (st) |v| v.cooldown_remaining_secs else 0,
            .queue = s.shared.depths(),
            .served = s.shared.served.load(.monotonic),
            .timed_out = s.shared.timed_out.load(.monotonic),
            .uptime_secs = @intCast(@max(Io.Timestamp.now(s.io, .real).toSeconds() - s.shared.started_secs, 0)),
        };
    }

    /// Stop serving: release everyone queued to the file bucket, wake
    /// the accept loop with a connection of our own, cancel the tasks
    /// and take the socket file away.
    pub fn stop(s: *Server) void {
        const io = s.io;
        s.shared.stopping.store(true, .release);
        s.shared.releaseAll();
        // The accept loop is parked in `accept`; a connection wakes it
        // and it sees `stopping`. (The same trick `bridge/host.zig`
        // uses to end a mount's reader.)
        if (Io.net.UnixAddress.init(s.socket_path)) |addr| {
            if (addr.connect(io)) |c| c.close(io) else |_| {}
        } else |_| {}
        s.group.cancel(io);
        if (s.listener) |*l| l.deinit(io);
        s.listener = null;
        Io.Dir.cwd().deleteFile(io, s.socket_path) catch {};
    }

    /// `stop` first.
    pub fn destroy(s: *Server) void {
        const gpa = s.gpa;
        s.limiter.deinit();
        gpa.free(s.service);
        gpa.free(s.socket_path);
        gpa.destroy(s);
    }
};

/// The bind's own errno, kept rather than flattened. `AddressInUse`
/// and `PermissionDenied` are the two a reader can act on — one is a
/// socket file in the way, the other is a directory they cannot write
/// — and telling them apart is the whole point of this mapping.
fn bindError(err: Io.net.UnixAddress.ListenError) Server.StartError {
    return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.PermissionDenied,
        error.FileNotFound, error.NotDir => error.DirMissing,
        else => error.BindFailed,
    };
}

/// The whole sentence for a broker that did not come up, `service: `
/// prefix excluded so a caller can print it after its own label.
///
/// `stale_pid` is who the election lock named BEFORE this process took
/// it. A socket file outlives the process that bound it, so an
/// `AddressInUse` is nearly always somebody's leftovers — and the pid
/// is the one thing that turns "address in use" into something the
/// reader can go and check.
pub fn explainStart(
    buf: []u8,
    path: []const u8,
    err: Server.StartError,
    service: []const u8,
    stale_pid: ?i32,
) []const u8 {
    if (err == error.PathTooLong) return explainPathTooLong(buf, service, path);
    const reason: []const u8 = switch (err) {
        error.Unsupported => "this platform has no Unix sockets",
        error.AddressInUse => "address in use",
        error.PermissionDenied => "permission denied",
        error.DirMissing => "no such directory",
        error.ListenFailed => "the accept loop would not start",
        error.OutOfMemory => "out of memory",
        else => "the bind failed",
    };
    if (err == error.AddressInUse) {
        if (stale_pid) |pid| {
            return std.fmt.bufPrint(
                buf,
                "could not serve on {s} ({s} — a stale socket from pid {d}?)",
                .{ path, reason, pid },
            ) catch reason;
        }
    }
    return std.fmt.bufPrint(buf, "could not serve on {s} ({s})", .{ path, reason }) catch reason;
}

/// The accept loop. One task per connection where the runtime will
/// give us one; inline when it will not, which serves the queue one
/// caller at a time rather than dropping anybody.
fn accept(s: *Server) Io.Cancelable!void {
    while (!s.shared.stopping.load(.acquire)) {
        const listener = if (s.listener) |*l| l else return;
        const stream = listener.accept(s.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        if (s.shared.stopping.load(.acquire)) {
            stream.close(s.io);
            return;
        }
        s.group.concurrent(s.io, serve, .{ s, stream }) catch {
            try serve(s, stream);
        };
    }
}

/// One connection: read a line, answer it, close. A caller that is
/// queued holds the connection open until it is served, its timeout
/// runs out, or the broker goes down.
fn serve(s: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(s.io);
    var rbuf: [max_line]u8 = undefined;
    var wbuf: [max_line]u8 = undefined;
    var r = stream.reader(s.io, &rbuf);
    var w = stream.writer(s.io, &wbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return;

    var out: [max_line]u8 = undefined;
    const req = Request.parse(line) orelse return reply(&w, (Reply{ .why = .bad_request }).render(&out));
    if (req.v != version) return reply(&w, (Reply{ .why = .bad_request }).render(&out));
    if (req.service.len > 0 and !std.mem.eql(u8, req.service, s.service)) {
        return reply(&w, (Reply{ .why = .wrong_service }).render(&out));
    }
    switch (req.op) {
        .status => return reply(&w, s.snapshot().render(&out)),
        .acquire => {},
    }

    const started = Io.Timestamp.now(s.io, .real).toMilliseconds();
    var tk: Ticket = .{};
    s.shared.enqueue(&tk, req.class, started) catch {
        // The queue is full. Better to say so at once than to hold a
        // caller that could have gone to the file bucket instead.
        return reply(&w, (Reply{ .why = .closed }).render(&out));
    };
    // The ticket lives on this frame, and the queue holds a pointer to
    // it. Every way out of here — served, timed out, the broker going
    // down, a cancel landing in the sleep below — has to take it back
    // out first, so a `defer` rather than a line at the end.
    defer _ = s.shared.withdraw(&tk);
    const deadline = started + @as(i64, req.timeout_ms);
    while (!tk.done.load(.acquire)) {
        if (s.shared.stopping.load(.acquire)) break;
        const now = Io.Timestamp.now(s.io, .real).toMilliseconds();
        if (now >= deadline) {
            if (s.shared.withdraw(&tk)) {
                _ = s.shared.timed_out.fetchAdd(1, .monotonic);
                const waited: u64 = @intCast(@max(now - started, 0));
                return reply(&w, (Reply{ .ok = false, .wait_ms = waited, .why = .timeout }).render(&out));
            }
            // It was being served as we looked; take the answer.
            break;
        }
        try s.io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
    const waited: u64 = @intCast(@max(Io.Timestamp.now(s.io, .real).toMilliseconds() - started, 0));
    if (!tk.done.load(.acquire) or !tk.ok) {
        return reply(&w, (Reply{ .ok = false, .wait_ms = waited, .why = .closed }).render(&out));
    }
    reply(&w, (Reply{ .ok = true, .wait_ms = waited, .remaining = tk.remaining }).render(&out));
}

fn reply(w: *Io.net.Stream.Writer, line: []const u8) void {
    w.interface.writeAll(line) catch return;
    w.interface.flush() catch return;
}

/// The dispatcher: while anybody is waiting, draw a token from the
/// shared bucket and give it to whoever is at the front WHEN IT LANDS
/// — not whoever was at the front when the draw began, so a pane that
/// opens during a four-second wait still overtakes the batch job the
/// wait was started for.
fn dispatch(s: *Server) Io.Cancelable!void {
    while (!s.shared.stopping.load(.acquire)) {
        if (s.shared.waiting() == 0) {
            try s.io.sleep(.fromMilliseconds(poll_ms), .awake);
            continue;
        }
        var ok = true;
        var remaining: f64 = 0;
        if (s.spare) |left| {
            remaining = left;
            s.spare = null;
        } else {
            // The bucket is the shared file one, so this waits on
            // every other process on the machine too — and fails open
            // rather than leaving a pane hung.
            s.limiter.reason = "broker";
            const got = s.limiter.acquireDetailed();
            ok = got.ok;
            remaining = got.tokens_after;
        }
        const now = Io.Timestamp.now(s.io, .real).toMilliseconds();
        if (s.shared.fulfil(now, ok, remaining)) {
            _ = s.shared.served.fetchAdd(1, .monotonic);
        } else if (ok) {
            // Drawn for somebody who left. The bucket cannot take one
            // back, so hold it for the next caller rather than
            // spending it twice.
            s.spare = remaining;
        }
    }
}

// ─── the client ──────────────────────────────────────────────────────────

/// Ask the broker at `path` for a token. Null means **there is no
/// broker here** — the socket is missing, refused, or the peer hung up
/// — and the caller should fall back to the file bucket. A non-null
/// reply is an answer, including `ok:false`.
///
/// The connect is bounded by the transport rather than by a timer: a
/// Unix socket with nobody listening fails at once, which is the only
/// failure this has to be quick about. A broker that has accepted the
/// connection is trusted to answer inside the `timeout_ms` the request
/// carries, because it is a local process that owes exactly one line.
pub fn ask(io: Io, path: []const u8, req: Request) ?Reply {
    if (!supported) return null;
    const line = talk(io, path, req) orelse return null;
    return Reply.parse(line.slice());
}

/// The same round trip for `status`. Null when there is no broker.
pub fn askStatus(io: Io, path: []const u8, service: []const u8) ?StatusReply {
    if (!supported) return null;
    const line = talk(io, path, .{ .op = .status, .service = service }) orelse return null;
    var st = StatusReply.parse(line.slice()) orelse return null;
    // `parse` points `service` into the line, which is this frame's.
    // The caller already knows which service it asked; hand back its
    // own slice rather than a dangling one.
    st.service = service;
    return st;
}

/// One line out, one line back, on the caller's own stack — the reply
/// owns no memory, so a client on a hot path allocates nothing.
pub const Line = struct {
    buf: [max_line]u8 = undefined,
    len: usize = 0,

    pub fn slice(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }
};

fn talk(io: Io, path: []const u8, req: Request) ?Line {
    if (path.len == 0 or pathTooLong(path)) return null;
    // A path that exists but is not a socket — a stale file where the
    // broker used to listen — is "no broker", the same as a missing one.
    // Asked to connect to it the kernel answers ENOTSOCK, which a Debug
    // build's `Io.Threaded` treats as a programmer bug and aborts on.
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .unix_domain_socket) return null;
    const addr = Io.net.UnixAddress.init(path) catch return null;
    const stream = addr.connect(io) catch return null;
    defer stream.close(io);
    var wbuf: [max_line]u8 = undefined;
    var rbuf: [max_line]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var out: [max_line]u8 = undefined;
    w.interface.writeAll(req.render(&out)) catch return null;
    w.interface.flush() catch return null;
    var r = stream.reader(io, &rbuf);
    const got = r.interface.takeDelimiterExclusive('\n') catch return null;
    var line: Line = .{};
    line.len = @min(got.len, line.buf.len);
    @memcpy(line.buf[0..line.len], got[0..line.len]);
    return line;
}

/// `<program>:<pid>` — how a client names itself on the wire. Written
/// into `buf`.
pub fn clientName(buf: []u8, program: []const u8, pid: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ program, pid }) catch program;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the classes are declared front to back, so the enum's own order is the priority" {
    try t.expectEqual(@as(u2, 0), @intFromEnum(Class.interactive));
    try t.expectEqual(@as(u2, 1), @intFromEnum(Class.refresh));
    try t.expectEqual(@as(u2, 2), @intFromEnum(Class.warm));
    try t.expectEqual(@as(u2, 3), @intFromEnum(Class.batch));
    try t.expectEqual(Class.interactive, Class.parse("interactive").?);
    try t.expectEqual(Class.batch, Class.parse("batch").?);
    try t.expect(Class.parse("Interactive") == null);
    try t.expect(Class.parse("") == null);
    try t.expectEqual(Class.warm, Class.batch.promoted());
    try t.expectEqual(Class.interactive, Class.refresh.promoted());
    // The front of the queue cannot be promoted past itself.
    try t.expectEqual(Class.interactive, Class.interactive.promoted());
}

test "a waiter's effective class is its own, promoted one step per age step, capped at the front" {
    const w: Waiter = .{ .class = .batch, .enqueued_ms = 1_000_000, .seq = 0 };
    try t.expectEqual(Class.batch, w.effective(1_000_000));
    try t.expectEqual(Class.batch, w.effective(1_000_000 + age_step_ms - 1));
    try t.expectEqual(Class.warm, w.effective(1_000_000 + age_step_ms));
    try t.expectEqual(Class.refresh, w.effective(1_000_000 + 2 * age_step_ms));
    try t.expectEqual(Class.interactive, w.effective(1_000_000 + 3 * age_step_ms));
    // And it stops there rather than wrapping.
    try t.expectEqual(Class.interactive, w.effective(1_000_000 + 99 * age_step_ms));
    // A clock that went backwards promotes nothing.
    try t.expectEqual(Class.batch, w.effective(999_000));
    // An interactive waiter is already at the front and stays there.
    const i: Waiter = .{ .class = .interactive, .enqueued_ms = 0, .seq = 0 };
    try t.expectEqual(Class.interactive, i.effective(99 * age_step_ms));
}

test "strict priority: the pane goes before the batch script that asked first" {
    var q: Queue = .{};
    const now: i64 = 5_000_000;
    _ = try q.push(.batch, now);
    _ = try q.push(.warm, now);
    _ = try q.push(.refresh, now);
    _ = try q.push(.interactive, now);
    try t.expectEqual(@as(usize, 4), q.len());
    try t.expectEqual(Class.interactive, q.take(now).?.class);
    try t.expectEqual(Class.refresh, q.take(now).?.class);
    try t.expectEqual(Class.warm, q.take(now).?.class);
    try t.expectEqual(Class.batch, q.take(now).?.class);
    try t.expect(q.take(now) == null);
}

test "within one class it is first come, first served" {
    var q: Queue = .{};
    const now: i64 = 0;
    const first = try q.push(.refresh, now);
    const second = try q.push(.refresh, now);
    const third = try q.push(.refresh, now);
    try t.expectEqual(first, q.take(now).?.seq);
    try t.expectEqual(second, q.take(now).?.seq);
    try t.expectEqual(third, q.take(now).?.seq);
}

test "aging: a batch waiter reaches the front rather than starving behind a stream of panes" {
    var q: Queue = .{};
    const t0: i64 = 1_000_000;
    const batch = try q.push(.batch, t0);
    // A pane opens every second for the whole time the batch waits.
    // Without aging the batch waiter never moves.
    var second: i64 = 0;
    while (second < 30) : (second += 1) {
        const now = t0 + second * 1000;
        _ = try q.push(.interactive, now);
        try t.expectEqual(Class.interactive, q.take(now).?.class);
    }
    // Three age steps on, its effective class IS interactive, so the
    // next pane to arrive queues behind it instead of in front.
    const later = t0 + 3 * age_step_ms;
    _ = try q.push(.interactive, later);
    const served = q.take(later).?;
    try t.expectEqual(batch, served.seq);
    try t.expectEqual(Class.batch, served.class);
    try t.expectEqual(Class.interactive, served.effective(later));
}

test "aging promotes one step at a time: at ten seconds a batch waiter is only ahead of batch" {
    var q: Queue = .{};
    const t0: i64 = 0;
    const batch = try q.push(.batch, t0);
    const at = t0 + age_step_ms; // → warm
    _ = try q.push(.refresh, at);
    // A refresh still goes first: the batch waiter is only `warm` yet.
    try t.expectEqual(Class.refresh, q.take(at).?.class);
    const warm_seq = try q.push(.warm, at);
    // Against a warm waiter that just arrived, the aged batch wins on
    // arrival order at the same effective class.
    try t.expectEqual(batch, q.take(at).?.seq);
    try t.expectEqual(warm_seq, q.take(at).?.seq);
}

test "a waiter that hung up leaves the queue, and the queue is bounded" {
    var q: Queue = .{};
    const a = try q.push(.warm, 0);
    _ = try q.push(.batch, 0);
    try t.expect(q.remove(a));
    try t.expect(!q.remove(a));
    try t.expectEqual(Class.batch, q.head(0).?.class);

    var full: Queue = .{};
    var i: usize = 0;
    while (i < max_waiters) : (i += 1) _ = try full.push(.batch, 0);
    try t.expectError(error.Full, full.push(.interactive, 0));
    // Depths say what is waiting, by the class it declared — not the
    // one it has aged into. The header counts arrivals, not standings.
    var mixed: Queue = .{};
    _ = try mixed.push(.interactive, 0);
    _ = try mixed.push(.batch, 0);
    _ = try mixed.push(.batch, 0);
    try t.expectEqual([4]u32{ 1, 0, 0, 2 }, mixed.depths());
}

test "a request goes out as one line and comes back the same request" {
    const req: Request = .{
        .op = .acquire,
        .service = "bitbucket",
        .class = .interactive,
        .client = "mnml-jira:1234",
        .reason = "pane_open",
        .timeout_ms = 5000,
    };
    var buf: [max_line]u8 = undefined;
    const line = req.render(&buf);
    try t.expect(std.mem.endsWith(u8, line, "\n"));
    // The shape the docs promise, key for key — this is the half of
    // the contract a twenty-line Python client reads.
    try t.expectEqualStrings(
        "{\"v\":1,\"op\":\"acquire\",\"service\":\"bitbucket\",\"class\":\"interactive\",\"client\":\"mnml-jira:1234\",\"reason\":\"pane_open\",\"timeout_ms\":5000}\n",
        line,
    );
    const back = Request.parse(line).?;
    try t.expectEqual(@as(u8, 1), back.v);
    try t.expectEqual(Op.acquire, back.op);
    try t.expectEqualStrings("bitbucket", back.service);
    try t.expectEqual(Class.interactive, back.class);
    try t.expectEqualStrings("mnml-jira:1234", back.client);
    try t.expectEqualStrings("pane_open", back.reason);
    try t.expectEqual(@as(u32, 5000), back.timeout_ms);
}

test "a line Python wrote parses: json.dumps puts a space after every colon" {
    // `json.dumps` writes `", "` and `": "` by default, and the whole
    // reason this protocol is one line of JSON is that the other end
    // may be twenty lines of Python stdlib. A reader that needs
    // `"op":"acquire"` sees every field of this line as missing and
    // hands the caller a `timeout_ms` of zero — refused instantly,
    // with nothing in the reply to say why.
    const pythonic = "{\"v\": 1, \"op\": \"acquire\", \"service\": \"bitbucket\", \"class\": \"interactive\", " ++
        "\"client\": \"bb.py:1234\", \"reason\": \"sweep\", \"timeout_ms\": 120000}";
    const r = Request.parse(pythonic).?;
    try t.expectEqual(@as(u8, 1), r.v);
    try t.expectEqual(Op.acquire, r.op);
    try t.expectEqualStrings("bitbucket", r.service);
    try t.expectEqual(Class.interactive, r.class);
    try t.expectEqualStrings("bb.py:1234", r.client);
    try t.expectEqualStrings("sweep", r.reason);
    try t.expectEqual(@as(u32, 120_000), r.timeout_ms);
    // And the other direction, so a Python reader of our replies is
    // symmetric with a Python writer of our requests.
    const st = StatusReply.parse("{\"ok\": true, \"service\": \"jira\", \"tokens\": 3.5, \"capacity\": 60, " ++
        "\"queue\": {\"interactive\": 1, \"refresh\": 0, \"warm\": 0, \"batch\": 2}, \"served\": 9}").?;
    try t.expectEqualStrings("jira", st.service);
    try t.expectApproxEqAbs(@as(f64, 3.5), st.tokens, 1e-6);
    try t.expectEqual([4]u32{ 1, 0, 0, 2 }, st.queue);
    try t.expectEqual(@as(u64, 9), st.served);
}

test "a request that is not one is null, and an unknown op or class is refused rather than guessed" {
    try t.expect(Request.parse("") == null);
    try t.expect(Request.parse("not json") == null);
    try t.expect(Request.parse("{\"v\":1,\"op\":\"drain\"}") == null);
    try t.expect(Request.parse("{\"v\":1,\"op\":\"acquire\",\"class\":\"urgent\"}") == null);
    // Missing fields take their defaults; a bare status is legal.
    const bare = Request.parse("{\"v\":1,\"op\":\"status\",\"service\":\"jira\"}").?;
    try t.expectEqual(Op.status, bare.op);
    try t.expectEqualStrings("jira", bare.service);
    try t.expectEqual(@as(u32, 0), bare.timeout_ms);
    // A version we do not speak parses — the broker answers it
    // `bad_request` rather than the codec refusing to look.
    try t.expectEqual(@as(u8, 9), Request.parse("{\"v\":9,\"op\":\"status\"}").?.v);
    // A timeout past an hour is clamped rather than believed.
    try t.expectEqual(@as(u32, 3_600_000), Request.parse("{\"op\":\"acquire\",\"timeout_ms\":99999999}").?.timeout_ms);
}

test "a reply says the token and what it cost, or which of four things went wrong" {
    var buf: [max_line]u8 = undefined;
    const ok: Reply = .{ .ok = true, .wait_ms = 3030, .remaining = 0.244 };
    try t.expectEqualStrings("{\"ok\":true,\"wait_ms\":3030,\"remaining\":0.244}\n", ok.render(&buf));
    const back = Reply.parse(ok.render(&buf)).?;
    try t.expect(back.ok);
    try t.expectEqual(@as(u64, 3030), back.wait_ms);
    try t.expectApproxEqAbs(@as(f64, 0.244), back.remaining, 1e-6);
    try t.expect(back.why == null);

    const no: Reply = .{ .ok = false, .wait_ms = 5000, .why = .timeout };
    try t.expectEqualStrings("{\"ok\":false,\"wait_ms\":5000,\"why\":\"timeout\"}\n", no.render(&buf));
    const no_back = Reply.parse(no.render(&buf)).?;
    try t.expect(!no_back.ok);
    try t.expectEqual(Why.timeout, no_back.why.?);
    for ([_]Why{ .timeout, .closed, .bad_request, .wrong_service }) |w| {
        const line = (Reply{ .ok = false, .why = w }).render(&buf);
        try t.expectEqual(w, Reply.parse(line).?.why.?);
    }
    try t.expect(Reply.parse("nonsense") == null);
}

test "a status reply carries the budget, the queue by class and what the broker has served" {
    const st: StatusReply = .{
        .service = "bitbucket",
        .tokens = 16.8,
        .capacity = 40,
        .rate = 0.22,
        .cooldown_secs = 0,
        .queue = .{ 0, 1, 0, 2 },
        .served = 128,
        .timed_out = 3,
        .uptime_secs = 903,
    };
    try t.expectEqual(@as(u32, 3), st.total());
    try t.expectEqual(@as(u8, 42), st.budgetPct());
    var buf: [max_line]u8 = undefined;
    const back = StatusReply.parse(st.render(&buf)).?;
    try t.expectEqualStrings("bitbucket", back.service);
    try t.expectApproxEqAbs(@as(f64, 16.8), back.tokens, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 40), back.capacity, 1e-3);
    try t.expectEqual([4]u32{ 0, 1, 0, 2 }, back.queue);
    try t.expectEqual(@as(u64, 128), back.served);
    try t.expectEqual(@as(u64, 3), back.timed_out);
    try t.expectEqual(@as(u64, 903), back.uptime_secs);
    try t.expectEqual(@as(u8, 42), back.budgetPct());
    // An empty bucket is 0%, and a capacity of zero is not a divide.
    try t.expectEqual(@as(u8, 0), (StatusReply{ .capacity = 40 }).budgetPct());
    try t.expectEqual(@as(u8, 0), (StatusReply{ .tokens = 5 }).budgetPct());
    try t.expectEqual(@as(u8, 100), (StatusReply{ .tokens = 40, .capacity = 40 }).budgetPct());
    // A failure line is not a status.
    try t.expect(StatusReply.parse("{\"ok\":false,\"why\":\"closed\"}") == null);
}

test "the socket sits beside the bucket it fronts, and the environment can name it outright" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try socketPath(t.allocator, t.io, &env, "bitbucket");
        defer t.allocator.free(p);
        try t.expectEqualStrings("/data/ratelimit/bitbucket-broker.sock", p);
        const lock = try lockPath(t.allocator, p);
        defer t.allocator.free(lock);
        try t.expectEqualStrings("/data/ratelimit/bitbucket-broker.lock", lock);
    }
    // The shared interop directory: beside the file the Rust crate and
    // the Python script already agree about.
    try env.put("TATTLE_ARTIFACTS_ROOT", "/shared");
    {
        const p = try socketPath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try t.expectEqualStrings("/shared/jira-broker.sock", p);
    }
    try env.put("JIRA_BROKER_SOCKET", "/tmp/x.sock");
    {
        const p = try socketPath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try t.expectEqualStrings("/tmp/x.sock", p);
    }
    // A service name cannot escape its directory.
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("A_B_BROKER_SOCKET", socketEnvName(&buf, "a/b").?);
}

test "a path too long for a sockaddr_un falls back to a short name both sides derive the same" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(t.allocator);
    try deep.appendSlice(t.allocator, "/very");
    while (deep.items.len < 120) try deep.appendSlice(t.allocator, "/deep");
    try env.put("TATTLE_ARTIFACTS_ROOT", deep.items);
    const p = try socketPath(t.allocator, t.io, &env, "bitbucket");
    defer t.allocator.free(p);
    // The short name, derived from the service and the long path: the
    // same long path always lands on the same socket…
    const long = try std.fmt.allocPrint(t.allocator, "{s}/bitbucket-broker.sock", .{deep.items});
    defer t.allocator.free(long);
    const want = try fallbackPath(t.allocator, "bitbucket", long);
    defer t.allocator.free(want);
    try t.expectEqualStrings(want, p);
    try t.expect(std.mem.startsWith(u8, p, "/tmp/mnml-broker-bitbucket-"));
    try t.expect(p.len < Io.net.UnixAddress.max_len);
    try t.expect(!pathTooLong(p));
    const again = try socketPath(t.allocator, t.io, &env, "bitbucket");
    defer t.allocator.free(again);
    try t.expectEqualStrings(p, again);
    // The Python client hashes the same bytes: SHA-256 of the long path,
    // the first six bytes in lower-case hex. Pinned, so the two ends
    // cannot drift apart without this failing.
    const pinned = try fallbackPath(t.allocator, "bitbucket", "/x/bitbucket-broker.sock");
    defer t.allocator.free(pinned);
    try t.expectEqualStrings("/tmp/mnml-broker-bitbucket-" ++ python_pin ++ ".sock", pinned);
}

/// `hashlib.sha256(b"/x/bitbucket-broker.sock").hexdigest()[:12]`.
const python_pin = "667462315536";

test "two deep buckets fall back to two sockets, so their brokers never meet" {
    // Every test's private bucket is under a deep tmp dir, and the
    // fallback used to be `/tmp/mnml-broker-<service>.sock` for all of
    // them: two corpus runs — or a test and the developer's own deep
    // bucket — met on one socket and one election lock, and whichever
    // came second saw the other's broker.
    var env_a = std.process.Environ.Map.init(t.allocator);
    defer env_a.deinit();
    var env_b = std.process.Environ.Map.init(t.allocator);
    defer env_b.deinit();
    const deep = "/very" ++ "/deep" ** 24;
    try env_a.put("TATTLE_ARTIFACTS_ROOT", deep ++ "/a");
    try env_b.put("TATTLE_ARTIFACTS_ROOT", deep ++ "/b");
    const a = try socketPath(t.allocator, t.io, &env_a, "bitbucket");
    defer t.allocator.free(a);
    const b = try socketPath(t.allocator, t.io, &env_b, "bitbucket");
    defer t.allocator.free(b);
    try t.expect(std.mem.startsWith(u8, a, "/tmp/"));
    try t.expect(std.mem.startsWith(u8, b, "/tmp/"));
    try t.expect(!std.mem.eql(u8, a, b));
    const la = try lockPath(t.allocator, a);
    defer t.allocator.free(la);
    const lb = try lockPath(t.allocator, b);
    defer t.allocator.free(lb);
    try t.expect(!std.mem.eql(u8, la, lb));
}

test "an explicit override past the sockaddr_un is kept, refused, and explained by length" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(t.allocator);
    try deep.appendSlice(t.allocator, "/very");
    while (deep.items.len < 126) try deep.appendSlice(t.allocator, "/deep");
    try deep.appendSlice(t.allocator, "/b.sock");
    try env.put("BITBUCKET_BROKER_SOCKET", deep.items);

    // Kept as set, NOT quietly moved to /tmp: a broker somewhere other
    // than the place the user named is worse than no broker.
    const p = try socketPath(t.allocator, t.io, &env, "bitbucket");
    defer t.allocator.free(p);
    try t.expectEqualStrings(deep.items, p);
    try t.expect(pathTooLong(p));

    // …and said so: the length they can measure, the limit they cannot
    // guess, and the variable to go and change.
    var buf: [explain_max]u8 = undefined;
    const why = explainPathTooLong(&buf, "bitbucket", p);
    var expect_buf: [explain_max]u8 = undefined;
    try t.expectEqualStrings(
        try std.fmt.bufPrint(
            &expect_buf,
            "socket path is {d} bytes; the OS allows {d} — set BITBUCKET_BROKER_SOCKET shorter or unset it for the default",
            .{ p.len, os_max_path_len },
        ),
        why,
    );

    // The boundary is the NUL's: `sun_path` holds 104 bytes on macOS,
    // so 103 of them may be path.
    try t.expectEqual(os_path_len - 1, os_max_path_len);
    try t.expect(!pathTooLong("x" ** os_max_path_len));
    try t.expect(pathTooLong("x" ** (os_max_path_len + 1)));
    // And a derived path never trips it — that is what the headroom is.
    try t.expect(max_path_len < os_max_path_len);

    // Nothing connects to it either, so a client is on the file bucket
    // rather than parked on an errno nobody declared.
    try t.expect(askStatus(t.io, p, "bitbucket") == null);
}

test "every other bind failure names its errno, and a leftover lock names the stale pid" {
    // The bind's own errno reaches the sentence rather than being
    // flattened on the way: `BindFailed` for all of these was the bug.
    try t.expectEqual(Server.StartError.AddressInUse, bindError(error.AddressInUse));
    try t.expectEqual(Server.StartError.PermissionDenied, bindError(error.AccessDenied));
    try t.expectEqual(Server.StartError.PermissionDenied, bindError(error.PermissionDenied));
    try t.expectEqual(Server.StartError.PermissionDenied, bindError(error.ReadOnlyFileSystem));
    try t.expectEqual(Server.StartError.DirMissing, bindError(error.FileNotFound));
    try t.expectEqual(Server.StartError.DirMissing, bindError(error.NotDir));
    // Only what nobody can act on stays generic.
    try t.expectEqual(Server.StartError.BindFailed, bindError(error.NetworkDown));

    var buf: [explain_max]u8 = undefined;
    try t.expectEqualStrings(
        "could not serve on /tmp/x.sock (address in use — a stale socket from pid 4242?)",
        explainStart(&buf, "/tmp/x.sock", error.AddressInUse, "bitbucket", 4242),
    );
    // No lock to name: still the errno, never `BindFailed`.
    try t.expectEqualStrings(
        "could not serve on /tmp/x.sock (address in use)",
        explainStart(&buf, "/tmp/x.sock", error.AddressInUse, "bitbucket", null),
    );
    try t.expectEqualStrings(
        "could not serve on /tmp/x.sock (permission denied)",
        explainStart(&buf, "/tmp/x.sock", error.PermissionDenied, "bitbucket", null),
    );
    try t.expectEqualStrings(
        "could not serve on /tmp/x.sock (no such directory)",
        explainStart(&buf, "/tmp/x.sock", error.DirMissing, "bitbucket", null),
    );
    // A pid on anything but an in-use address would be a guess.
    try t.expectEqualStrings(
        "could not serve on /tmp/x.sock (permission denied)",
        explainStart(&buf, "/tmp/x.sock", error.PermissionDenied, "bitbucket", 4242),
    );
    // The length case is its own sentence, not an errno.
    const long = "x" ** (os_max_path_len + 7);
    try t.expect(std.mem.startsWith(
        u8,
        explainStart(&buf, long, error.PathTooLong, "jira", null),
        "socket path is ",
    ));
    try t.expect(std.mem.indexOf(
        u8,
        explainStart(&buf, long, error.PathTooLong, "jira", null),
        "JIRA_BROKER_SOCKET",
    ) != null);
}

test "a server refuses an override it cannot bind, by length rather than at the bind" {
    if (!supported) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(t.allocator);
    try deep.appendSlice(t.allocator, "/tmp");
    while (deep.items.len < 126) try deep.appendSlice(t.allocator, "/deep");
    try deep.appendSlice(t.allocator, "/b.sock");
    try env.put("BITBUCKET_BROKER_SOCKET", deep.items);
    // `BindFailed` was the whole bug: the caller could not tell a long
    // path from a busy address, so it could not say which to fix.
    try t.expectError(error.PathTooLong, Server.start(t.allocator, t.io, &env, .{ .service = "bitbucket" }));
}

// ─── tests: a real broker on a private socket ────────────────────────────

/// A broker on its own socket, its own bucket and its own directory,
/// so a test never touches the machine's real ones.
const Harness = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    server: *Server,
    dir: []u8,

    /// `tokens` seeds the bucket before the broker starts, so a test
    /// can queue every client while the first token is still on its
    /// way — which is the only way to prove an ORDER rather than an
    /// arrival sequence. Null leaves a fresh bucket (full).
    fn init(service: []const u8, cfg: ratelimit.Config, tokens: ?f64) !Harness {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const real = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
        const dir = try t.allocator.dupe(u8, real);
        errdefer t.allocator.free(dir);

        var env = std.process.Environ.Map.init(t.allocator);
        errdefer env.deinit();
        // The bucket AND the socket under the test's own directory:
        // `<SERVICE>_RATELIMIT_STATE` is the documented override, and
        // the socket derives from beside it.
        var name_buf: [64]u8 = undefined;
        const state = try std.fmt.allocPrint(t.allocator, "{s}/{s}-ratelimit.json", .{ dir, service });
        defer t.allocator.free(state);
        try env.put(ratelimit.stateEnvName(&name_buf, service).?, state);
        if (tokens) |have| {
            var sbuf: [512]u8 = undefined;
            const now: f64 = @as(f64, @floatFromInt(Io.Timestamp.now(t.io, .real).toNanoseconds())) / 1e9;
            const text = ratelimit.renderState(&sbuf, .{ .ts = now, .tokens = have, .rate = cfg.rate });
            try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = state, .data = text });
        }

        const server = try Server.start(t.allocator, t.io, &env, .{
            .service = service,
            .program = "mnml-test",
            .pid = 4242,
            .config = cfg,
        });
        return .{ .tmp = tmp, .env = env, .server = server, .dir = dir };
    }

    fn deinit(h: *Harness) void {
        h.server.stop();
        h.server.destroy();
        h.env.deinit();
        t.allocator.free(h.dir);
        h.tmp.cleanup();
    }
};

/// What one client got, so the tasks can be read back in the order
/// they were served.
const Got = struct {
    class: Class,
    reply: ?Reply = null,
    served_ms: i64 = 0,
};

fn oneClient(io: Io, path: []const u8, g: *Got, timeout_ms: u32) void {
    g.reply = ask(io, path, .{
        .op = .acquire,
        .service = "",
        .class = g.class,
        .client = "test:1",
        .reason = "test",
        .timeout_ms = timeout_ms,
    });
    g.served_ms = Io.Timestamp.now(io, .real).toMilliseconds();
}

test "a real broker on a private socket serves the pane before the batch script that queued first" {
    if (!supported) return error.SkipZigTest;
    // A bucket with nothing in it that refills ten times a second, so
    // the order is decided by the queue and the test takes under a
    // second rather than three minutes.
    var h = try Harness.init("bitbucket", .{ .rate = 4.0, .capacity = 6.0, .max_block_secs = 20.0 }, 0);
    defer h.deinit();
    const io = t.io;
    const path = h.server.path();

    // Four clients, queued worst-first. They all connect before any
    // token lands, so the broker decides the order, not the socket.
    var gots = [_]Got{
        .{ .class = .batch },
        .{ .class = .warm },
        .{ .class = .refresh },
        .{ .class = .interactive },
    };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&gots) |*g| {
        try group.concurrent(io, oneClient, .{ io, path, g, @as(u32, 8000) });
        // Enough to be sure each has joined the queue before the next
        // does: the tie-break inside a class is arrival order, and
        // this test is about the order BETWEEN classes.
        try io.sleep(.fromMilliseconds(30), .awake);
    }
    try group.await(io);

    for (&gots) |*g| {
        try t.expect(g.reply != null);
        try t.expect(g.reply.?.ok);
    }
    // Served in class order, not arrival order.
    try t.expect(gots[3].served_ms <= gots[2].served_ms);
    try t.expect(gots[2].served_ms <= gots[1].served_ms);
    try t.expect(gots[1].served_ms <= gots[0].served_ms);
    // The pane waited for one token; the batch script waited for four.
    try t.expect(gots[3].reply.?.wait_ms < gots[0].reply.?.wait_ms);
    try t.expectEqual(@as(u64, 4), h.server.shared.served.load(.monotonic));
}

test "a broker client and a file client see one budget, and the broker writes through the same lock" {
    if (!supported) return error.SkipZigTest;
    // Three tokens, no refill worth speaking of: whoever takes one
    // takes it from the other.
    var h = try Harness.init("jira", .{ .rate = 0.0001, .capacity = 3.0, .max_block_secs = 30.0 }, null);
    defer h.deinit();
    const io = t.io;

    // A file client on the same state file — a Python script, the
    // Rust crate, or an mnml process whose connect failed.
    const state = try std.fmt.allocPrint(t.allocator, "{s}/jira-ratelimit.json", .{h.dir});
    defer t.allocator.free(state);
    var file_client = try ratelimit.Limiter.init(t.allocator, io, state, .{ .rate = 0.0001, .capacity = 3.0, .max_block_secs = 0.3 });
    defer file_client.deinit();
    file_client.draws = false;

    // One through the socket…
    const first = ask(io, h.server.path(), .{ .class = .interactive, .service = "jira", .timeout_ms = 3000 }).?;
    try t.expect(first.ok);
    // …and the file client sees a bucket with one fewer in it.
    try t.expectApproxEqAbs(first.remaining, file_client.status().?.tokens, 0.01);

    // Two more from the file side empties it…
    try t.expect(file_client.acquire());
    try t.expect(file_client.acquire());
    try t.expect(!file_client.acquire());
    // …and the broker has nothing to hand out either. One budget.
    const dry = ask(io, h.server.path(), .{ .class = .interactive, .service = "jira", .timeout_ms = 200 }).?;
    try t.expect(!dry.ok);
    try t.expectEqual(Why.timeout, dry.why.?);
}

test "no broker at the path is null, not an error — the caller falls back to the file bucket" {
    if (!supported) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const missing = try std.fmt.allocPrint(t.allocator, "{s}/nobody-broker.sock", .{dir});
    defer t.allocator.free(missing);
    try t.expect(ask(t.io, missing, .{ .class = .interactive, .timeout_ms = 10 }) == null);
    try t.expect(askStatus(t.io, missing, "bitbucket") == null);
    // A path that is a file rather than a socket is the same answer.
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = missing, .data = "not a socket" });
    try t.expect(ask(t.io, missing, .{ .class = .interactive, .timeout_ms = 10 }) == null);
}

test "status answers the budget, the queue by class and what has been served; a stopped broker answers nothing" {
    if (!supported) return error.SkipZigTest;
    var h = try Harness.init("bitbucket", .{ .rate = 10.0, .capacity = 5.0, .max_block_secs = 2.0 }, null);
    const io = t.io;
    const path = try t.allocator.dupe(u8, h.server.path());
    defer t.allocator.free(path);

    const before = askStatus(io, path, "bitbucket").?;
    try t.expectEqualStrings("bitbucket", before.service);
    try t.expectApproxEqAbs(@as(f64, 5.0), before.capacity, 0.001);
    try t.expectEqual(@as(u32, 0), before.total());
    try t.expectEqual(@as(u64, 0), before.served);

    const got = ask(io, path, .{ .class = .refresh, .service = "bitbucket", .timeout_ms = 2000 }).?;
    try t.expect(got.ok);
    const after = askStatus(io, path, "bitbucket").?;
    try t.expectEqual(@as(u64, 1), after.served);
    try t.expect(after.tokens < before.tokens);
    try t.expect(after.budgetPct() < 100);

    // A request for another service's bucket is refused rather than
    // silently served off the wrong one.
    const wrong = ask(io, path, .{ .class = .interactive, .service = "jira", .timeout_ms = 200 }).?;
    try t.expect(!wrong.ok);
    try t.expectEqual(Why.wrong_service, wrong.why.?);

    h.deinit();
    // The socket file goes with the broker, so a client that tries it
    // after a quit falls back rather than hanging on a dead path.
    try t.expect(askStatus(io, path, "bitbucket") == null);
}

test "a timeout of zero is a token or nothing: the caller never queues" {
    if (!supported) return error.SkipZigTest;
    var h = try Harness.init("bitbucket", .{ .rate = 0.0001, .capacity = 1.0, .max_block_secs = 0.3 }, null);
    defer h.deinit();
    const io = t.io;
    // One token in the bucket. Even at `timeout_ms = 0` the first
    // caller is served, because the dispatcher has one ready.
    var first = ask(io, h.server.path(), .{ .class = .batch, .timeout_ms = 400 }).?;
    try t.expect(first.ok);
    // The second asks for no wait at all and is told no at once.
    const started = Io.Timestamp.now(io, .real).toMilliseconds();
    first = ask(io, h.server.path(), .{ .class = .interactive, .timeout_ms = 0 }).?;
    const took = Io.Timestamp.now(io, .real).toMilliseconds() - started;
    try t.expect(!first.ok);
    try t.expectEqual(Why.timeout, first.why.?);
    try t.expect(took < 400);
}

/// A bucket under `tmp` whose derived socket path is too long for a
/// `sockaddr_un`, so its broker serves at the `/tmp` fallback — the
/// shape every test's private bucket has on a machine whose checkout
/// is a few directories deep. Returns the env to start a server with.
fn deepBucketEnv(tmp: *std.testing.TmpDir, service: []const u8) !std.process.Environ.Map {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var dir: std.ArrayListUnmanaged(u8) = .empty;
    defer dir.deinit(t.allocator);
    try dir.appendSlice(t.allocator, real);
    while (dir.items.len <= max_path_len) try dir.appendSlice(t.allocator, "/deep");
    try Io.Dir.cwd().createDirPath(t.io, dir.items);
    var env = std.process.Environ.Map.init(t.allocator);
    errdefer env.deinit();
    var name_buf: [64]u8 = undefined;
    const state = try std.fmt.allocPrint(t.allocator, "{s}/{s}-ratelimit.json", .{ dir.items, service });
    defer t.allocator.free(state);
    try env.put(ratelimit.stateEnvName(&name_buf, service).?, state);
    return env;
}

test "two brokers on two deep private buckets both serve, and stopping one leaves the other up" {
    if (!supported) return error.SkipZigTest;
    var tmp_a = t.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = t.tmpDir(.{});
    defer tmp_b.cleanup();
    var env_a = try deepBucketEnv(&tmp_a, "bitbucket");
    defer env_a.deinit();
    var env_b = try deepBucketEnv(&tmp_b, "bitbucket");
    defer env_b.deinit();

    const a = try Server.start(t.allocator, t.io, &env_a, .{ .service = "bitbucket" });
    defer a.destroy();
    var a_stopped = false;
    defer if (!a_stopped) a.stop();
    const b = try Server.start(t.allocator, t.io, &env_b, .{ .service = "bitbucket" });
    defer b.destroy();
    var b_stopped = false;
    defer if (!b_stopped) b.stop();

    // Both are on the short fallback, and not the same one.
    try t.expect(std.mem.startsWith(u8, a.path(), "/tmp/mnml-broker-bitbucket-"));
    try t.expect(!std.mem.eql(u8, a.path(), b.path()));
    try t.expect(askStatus(t.io, a.path(), "bitbucket") != null);
    try t.expect(askStatus(t.io, b.path(), "bitbucket") != null);

    // One of them goes away. On a shared fallback the second start had
    // unlinked the first's socket and bound over it, so stopping the
    // second took the first off the machine with it.
    b.stop();
    b_stopped = true;
    try t.expect(askStatus(t.io, b.path(), "bitbucket") == null);
    try t.expect(askStatus(t.io, a.path(), "bitbucket") != null);
    a.stop();
    a_stopped = true;
}
