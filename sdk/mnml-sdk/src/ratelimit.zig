//! One token bucket per service, shared by every process on the
//! machine.
//!
//! An integration is never the only thing spending a host's API budget:
//! three Jira panes, the statusline poller, a shell script and the Rust
//! app can all be drawing on the same allowance at once, and the first
//! any of them hears about it is a 429 that hits all of them. So the
//! bucket does not live in a process — it lives in a file, and every
//! process refills, spends and penalises it under an exclusive advisory
//! lock.
//!
//! **Whose allowance.** Bitbucket Cloud counts per TOKEN, not per IP
//! (measured 2026-10-07: a second token from the same machine got 200s
//! while the first sat in a 429). So a service that opts in
//! (`per_token_services`) can keep one bucket per credential —
//! `<service>-ratelimit-<id>.json` beside the shared file, `<id>` the
//! first 12 hex of a sha256 of the credential (`tokenId`). Everything
//! with no credential to name, and every older client, stays on the
//! shared `<service>-ratelimit.json`. Jira is not opted in: its limits
//! were never measured.
//!
//! The file's six keys are a public format contract (`docs/SDK.md`):
//!
//!     {"ts","tokens","rate","cooldown_until","throttles","last_429"}
//!
//! so mnml coordinates rather than races with any other tool on the
//! machine that agrees to the file format — the Rust crate
//! `mnml-ratelimit` is one. `Config.jira` carries that crate's
//! constants exactly; `Config.bitbucket` is the measured preset, past
//! the crate's; a service with no preset gets `Config{}`, the crate's
//! old Bitbucket constants.
//!
//!   * `acquire` refills from the wall clock, waits out a cooldown,
//!     takes a token when there is one, and otherwise waits for one
//!     (jittered, so processes released together do not re-cluster).
//!     Past `max_block_secs` it gives up and returns false — the caller
//!     should send anyway and let its own 429 handling decide. A wedged
//!     state file must never take an integration offline.
//!   * `penalize` records a 429: the shared rate is cut, the tokens
//!     emptied, and every process parked until `Retry-After` is up.
//!
//! **Who is spending it.** The bucket says how much is left, never
//! who took it — and on this machine a dozen things draw on the same
//! allowance, mnml's panes among them. So every `acquire` also appends
//! one line to `<service>-draws.jsonl` BESIDE the state file, in the
//! same directory every process sharing the bucket resolves:
//!
//! ```
//! {"ts":1789526218.411,"pid":48123,"program":"mnml-jira","service":"jira","reason":"pane_open","wait_ms":3030,"tokens_after":0.24}
//! ```
//!
//! Seven keys, documented in `docs/SDK.md` as a contract, so anything
//! else on the machine can append the same line and be counted — and
//! an optional eighth, `"token_id"`, when the draw came out of a
//! credential's own bucket. The
//! state file itself is NEVER given a field for this: other writers of
//! the format rewrite those six keys wholesale and a seventh would be
//! dropped or choke them.
//!
//! Where the file is, in order:
//!
//!   1. `<SERVICE>_RATELIMIT_STATE` names the file outright
//!   2. `$MNML_SHARED_STATE_DIR/<service>-ratelimit.json` — the
//!      directory holding state every process on the machine shares;
//!      point any other tool that agrees to the file format at it
//!   3. `<MNML_DATA_ROOT>/ratelimit/<service>.json`
//!   4. `~/.config/mnml/ratelimit/<service>.json`
//!
//! Nothing under the home directory is probed for: with neither
//! variable set, the bucket is mnml's own. A per-token bucket
//! (`statePathFor`) sits in the directory 2–4 resolve, as
//! `<service>-ratelimit-<id>.json`; an override (1) names the file
//! outright and so stays the file, credential or not. The draws file
//! stays one per service whichever bucket a draw came out of; its line
//! carries the `token_id`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const broker = @import("broker.zig");

pub const Config = struct {
    /// Tokens per second the bucket refills at. Set BELOW the service's
    /// sustained budget: the bucket is a budget, not a smoother.
    rate: f64 = 0.22,
    /// The burst: a fresh bucket holds this many.
    capacity: f64 = 40.0,
    /// The multiplicative cut on a 429, and the floor it stops at.
    penalty_factor: f64 = 0.5,
    min_rate: f64 = 0.05,
    /// The park when a 429 carries no `Retry-After`.
    default_cooldown_secs: f64 = 60.0,
    /// Eases the cut rate back toward `rate`, once per success.
    recover_factor: f64 = 1.02,
    /// The longest one `acquire` may block before failing open.
    max_block_secs: f64 = 120.0,

    /// Bitbucket Cloud counts per token, and is generous sustained and
    /// strict in a burst. Measured 2026-10-07: 1,500 plain GETs in 19
    /// minutes (1.3/s, at least 4,700 an hour) never met a 429; a burst
    /// at ~9.6/s met one after 694 calls in 72 s, and it cleared inside
    /// 30 s. Success responses carry no rate-limit headers for a
    /// workspace token, so a 429 is the only signal. 1.2/s sits under
    /// the sustained figure; 40 tokens of burst stays far under the
    /// burst cap; a 429 with no useful `Retry-After` parks 30 s.
    pub const bitbucket: Config = .{
        .rate = 1.2,
        .capacity = 40.0,
        .penalty_factor = 0.5,
        .min_rate = 0.05,
        .default_cooldown_secs = 30.0,
        .recover_factor = 1.02,
        .max_block_secs = 120.0,
    };

    /// Jira Cloud's limits have not been measured; these are the Rust
    /// crate's constants: a wider burst than its old Bitbucket preset,
    /// a comparable rate.
    pub const jira: Config = .{
        .rate = 0.33,
        .capacity = 60.0,
        .penalty_factor = 0.5,
        .min_rate = 0.08,
        .default_cooldown_secs = 45.0,
        .recover_factor = 1.02,
        .max_block_secs = 120.0,
    };
};

/// The preset for a service name. Anything without one gets `Config{}`
/// — the Rust crate's old Bitbucket constants, the tightest there is —
/// rather than the measured Bitbucket preset, which an unmeasured API
/// has not earned.
pub fn configFor(service: []const u8) Config {
    if (std.ascii.eqlIgnoreCase(service, "bitbucket")) return .bitbucket;
    if (std.ascii.eqlIgnoreCase(service, "jira")) return .jira;
    return .{};
}

// ─── a bucket per credential ─────────────────────────────────────────────

/// The services whose limits are counted per token, so a credential
/// may keep a bucket of its own (`statePathFor`). Opt-in: a service
/// not listed always resolves the shared file. Jira can join once its
/// limits are measured.
pub const per_token_services = [_][]const u8{"bitbucket"};

pub fn perToken(service: []const u8) bool {
    for (per_token_services) |s| if (std.ascii.eqlIgnoreCase(s, service)) return true;
    return false;
}

/// How many hex characters of the hash name a credential's bucket.
pub const token_id_len = 12;
/// The first `token_id_len` lowercase hex characters of a sha256.
pub const TokenId = [token_id_len]u8;

/// The id of these exact bytes — the hash rule's last step.
pub fn tokenIdOfBytes(bytes: []const u8) TokenId {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..token_id_len].*;
}

/// The id of a Basic credential held as its two halves: the hash of
/// `user:secret` — one colon, no newline.
pub fn tokenIdPair(user: []const u8, secret: []const u8) TokenId {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(user);
    h.update(":");
    h.update(secret);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..token_id_len].*;
}

/// The id of a credential as a caller holds it: a bare token, or the
/// `Authorization` value it goes out as. A leading `Bearer ` is
/// stripped; a leading `Basic ` is stripped and its base64 decoded, so
/// the header and the pair it was built from (`tokenIdPair`) name the
/// same bucket. A Basic value that does not decode is hashed as it
/// stands. Null when nothing is left to hash.
pub fn tokenId(credential: []const u8) ?TokenId {
    if (std.mem.startsWith(u8, credential, "Bearer ")) {
        const rest = credential["Bearer ".len..];
        return if (rest.len == 0) null else tokenIdOfBytes(rest);
    }
    if (std.mem.startsWith(u8, credential, "Basic ")) {
        const rest = credential["Basic ".len..];
        if (rest.len == 0) return null;
        const dec = std.base64.standard.Decoder;
        var buf: [2048]u8 = undefined;
        const n = dec.calcSizeForSlice(rest) catch return tokenIdOfBytes(rest);
        if (n > buf.len) return tokenIdOfBytes(rest);
        dec.decode(buf[0..n], rest) catch return tokenIdOfBytes(rest);
        return tokenIdOfBytes(buf[0..n]);
    }
    return if (credential.len == 0) null else tokenIdOfBytes(credential);
}

/// Where the bucket for this credential lives. A service in
/// `per_token_services` with a credential gets
/// `<service>-ratelimit-<id>.json` in the directory the shared file
/// resolves to; anything else — no credential, a service not opted in,
/// or `<SERVICE>_RATELIMIT_STATE` naming the file outright — gets the
/// shared file (`statePath`), unchanged. Owned.
pub fn statePathFor(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8, credential: ?[]const u8) Allocator.Error![]u8 {
    const id: ?TokenId = if (credential) |c| tokenId(c) else null;
    return statePathForId(gpa, io, env, service, id);
}

/// `statePathFor`, with the id already worked out. Owned.
pub fn statePathForId(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8, id: ?TokenId) Allocator.Error![]u8 {
    const shared = try statePath(gpa, io, env, service);
    const tid = id orelse return shared;
    if (!perToken(service)) return shared;
    var name_buf: [max_service_len + "_RATELIMIT_STATE".len]u8 = undefined;
    if (stateEnvName(&name_buf, service)) |name| {
        if (nonEmpty(env.get(name)) != null) return shared;
    }
    defer gpa.free(shared);
    var svc_buf: [max_service_len]u8 = undefined;
    const own = try std.fmt.allocPrint(gpa, "{s}-ratelimit-{s}.json", .{ sanitize(&svc_buf, service), &tid });
    const dir = std.fs.path.dirname(shared) orelse return own;
    defer gpa.free(own);
    return std.fs.path.join(gpa, &.{ dir, own });
}

/// The file's shape — the Python and Rust sides read and write the
/// same six keys.
pub const State = struct {
    ts: f64 = 0,
    tokens: f64 = 0,
    rate: f64 = 0,
    cooldown_until: f64 = 0,
    throttles: u32 = 0,
    last_429: f64 = 0,
};

/// What `acquire` was waiting on. An empty bucket and a 429 cooldown
/// are the same `loading…` on screen and very different problems, so
/// the limiter says which — and the request log writes it down.
pub const Wait = enum {
    /// It did not wait: there was a token.
    nothing,
    /// The bucket was empty; it refills at `rate`.
    tokens,
    /// A 429 had parked every process on this bucket until the
    /// cooldown was up.
    cooldown,
    /// `max_block_secs` passed and the limiter failed open. The caller
    /// sent anyway.
    gave_up,

    pub fn tag(w: Wait) []const u8 {
        return @tagName(w);
    }
};

/// Which side of the machine handed the token over. Both spend from
/// the same bucket; the difference is whether anything was ahead of
/// this request in a queue, and the request log writes it down so a
/// slow morning can be read back to whether the broker was up.
pub const Via = enum {
    /// Through the local broker's queue (`broker.zig`).
    broker,
    /// Straight off the shared state file — no broker, or its socket
    /// was not there.
    file,

    pub fn tag(v: Via) []const u8 {
        return @tagName(v);
    }
};

/// One `acquire`, with what it cost. `ok` is the old boolean: false
/// means the limiter gave up and the caller should send anyway.
pub const Acquired = struct {
    ok: bool,
    /// Wall time the request was held before it went out.
    wait_ms: u64 = 0,
    waited_for: Wait = .nothing,
    /// Tokens left in the shared bucket after this one took its token;
    /// what the hover and the log both read.
    tokens_after: f64 = 0,
    via: Via = .file,
};

/// The last wait worth telling the reader about.
///
/// `loading…` for three seconds with nothing else on screen is the
/// complaint this exists to answer. Whatever thread made the request
/// records its wait here; the loop that paints takes it and says so.
/// Atomics rather than a lock, because the writer is usually a worker
/// and the reader is always the paint loop, and paint takes no locks.
pub const Notice = struct {
    /// The longest wait since the last `take`, in milliseconds.
    wait_ms: std.atomic.Value(u64) = .init(0),
    /// Tokens left afterwards, times a thousand, so it crosses as an
    /// integer.
    tokens_milli: std.atomic.Value(u64) = .init(0),
    /// A 429's cooldown rather than an empty bucket.
    cooldown: std.atomic.Value(bool) = .init(false),
    /// The live `Phase`, and how many requests were ahead when it
    /// joined the broker's queue — what the request is doing NOW, as
    /// distinct from the wait already paid above.
    phase: std.atomic.Value(u8) = .init(0),
    behind: std.atomic.Value(u32) = .init(0),

    /// Under this, a wait is not worth a line: it is the difference
    /// between a pane that is working and a pane that is parked.
    pub const threshold_ms: u64 = 2000;

    pub const Taken = struct {
        wait_ms: u64,
        tokens: f64,
        cooldown: bool,

        /// `waiting for the API budget · 3.1 s · 0.2 tokens`, or the
        /// cooldown's own wording. Written into `buf`.
        pub fn text(t2: Taken, buf: []u8) []const u8 {
            const secs = @as(f64, @floatFromInt(t2.wait_ms)) / 1000.0;
            const what = if (t2.cooldown) "backing off after a 429" else "waiting for the API budget";
            return std.fmt.bufPrint(buf, "{s} · {d:.1} s · {d:.1} tokens", .{ what, secs, t2.tokens }) catch what;
        }
    };

    /// Record one `acquire`. Anything under the threshold is dropped:
    /// the point is the wait a person notices.
    pub fn record(n: *Notice, a: Acquired) void {
        if (a.wait_ms < threshold_ms) return;
        if (a.wait_ms <= n.wait_ms.load(.acquire)) return;
        n.wait_ms.store(a.wait_ms, .release);
        n.tokens_milli.store(@intFromFloat(@max(a.tokens_after, 0) * 1000.0), .release);
        n.cooldown.store(a.waited_for == .cooldown, .release);
    }

    /// The wait to say something about, once. Null when nothing has
    /// been slow since the last look.
    pub fn take(n: *Notice) ?Taken {
        const ms = n.wait_ms.swap(0, .acq_rel);
        if (ms == 0) return null;
        return .{
            .wait_ms = ms,
            .tokens = @as(f64, @floatFromInt(n.tokens_milli.load(.acquire))) / 1000.0,
            .cooldown = n.cooldown.load(.acquire),
        };
    }

    // ─── what the request is doing RIGHT NOW ─────────────────────────

    /// The live phase, as distinct from the wait already paid: `take`
    /// answers "what was slow", this answers "what is it doing at this
    /// moment", which is what a header has to say while the reader
    /// waits. Written by the limiter and the client on the worker
    /// thread; read by the paint loop.
    pub const Phase = enum(u8) {
        /// No request is between acquire and reply.
        idle,
        /// In the local broker's queue, `behind` requests ahead of it.
        queued,
        /// Held on the shared file bucket (no broker on this machine).
        waiting,
        /// The token is in hand and the request is on the wire.
        sending,
    };

    pub fn setPhase(n: *Notice, phase: Phase, behind: u32) void {
        n.behind.store(behind, .release);
        n.phase.store(@intFromEnum(phase), .release);
    }

    pub const Live = struct { phase: Phase, behind: u32 };

    pub fn live(n: *const Notice) Live {
        const p: Phase = @enumFromInt(n.phase.load(.acquire));
        return .{ .phase = p, .behind = n.behind.load(.acquire) };
    }
};

pub const Status = struct {
    tokens: f64,
    capacity: f64,
    rate: f64,
    baseline_rate: f64,
    throttles: u32,
    cooldown_remaining_secs: f64,
    /// How long ago the last 429 was, in seconds; null when the bucket
    /// has never seen one.
    last_429_age_secs: ?f64 = null,

    /// The hover line on an integration's statusline chip:
    ///
    ///     budget: 0.2 of 60 tokens · 0.33/s · 127 throttles · last 429 4h ago
    ///
    /// The wording is here rather than in each integration so two
    /// chips drawing on two buckets read the same way. Written into
    /// `buf`.
    /// The bucket has met a 429: a throttle is counted, or one is dated.
    pub fn penalized(st: Status) bool {
        return st.throttles > 0 or st.last_429_age_secs != null;
    }

    pub fn describe(st: Status, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("budget: {d:.1} of {d:.0} tokens · {d:.2}/s", .{ st.tokens, st.capacity, st.rate }) catch return buf[0..w.end];
        // "cut from" means a 429 cut it: a rate merely below this
        // process's baseline — another writer's lower preset, a config
        // that asks for less — is not a throttle and says nothing.
        if (st.penalized() and st.rate < st.baseline_rate - 0.001) w.print(" (cut from {d:.2})", .{st.baseline_rate}) catch {};
        if (st.throttles > 0) w.print(" · {d} throttle{s}", .{ st.throttles, if (st.throttles == 1) "" else "s" }) catch {};
        if (st.last_429_age_secs) |age| {
            var abuf: [24]u8 = undefined;
            w.print(" · last 429 {s} ago", .{ageText(&abuf, age)}) catch {};
        }
        if (st.cooldown_remaining_secs > 0.5) w.print(" · parked {d:.0}s", .{st.cooldown_remaining_secs}) catch {};
        return buf[0..w.end];
    }
};

/// `42s` / `7m` / `4h` / `3d` — the coarsest unit that still says
/// something, which is all an age on a hover needs to.
pub fn ageText(buf: []u8, secs: f64) []const u8 {
    const s2 = @max(secs, 0);
    if (s2 < 90) return std.fmt.bufPrint(buf, "{d:.0}s", .{s2}) catch "?";
    if (s2 < 5400) return std.fmt.bufPrint(buf, "{d:.0}m", .{s2 / 60.0}) catch "?";
    if (s2 < 172800) return std.fmt.bufPrint(buf, "{d:.0}h", .{s2 / 3600.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}d", .{s2 / 86400.0}) catch "?";
}

/// The ceiling on `<service>-draws.jsonl` before it rotates, and the
/// one older generation kept beside it.
pub const draws_max_bytes: u64 = 4 * 1024 * 1024;

pub const Limiter = struct {
    gpa: Allocator,
    io: Io,
    /// Owned.
    path: []u8,
    cfg: Config,
    /// Requests the bucket let through, for the diagnostics.
    acquired: u32 = 0,
    /// The service this bucket is, so a draw line can name it. Owned.
    service: []u8 = &.{},
    /// This process, as a draw line names it: the basename of argv[0],
    /// and the pid. Borrowed from the caller, which owns argv.
    program: []const u8 = "",
    pid: i32 = 0,
    /// Why this process is spending, right now. Whoever is about to
    /// make a request sets it; the draw line carries it so a drained
    /// bucket is attributable to a cause and not only to a program.
    ///
    /// **Borrowed, and read on a LATER call than the one that set it.**
    /// A literal or a `@tagName` — never a frame-arena or job-result
    /// string, which would be gone by the time a draw is recorded.
    reason: []const u8 = "user",
    /// Off only in a test that must leave no file behind.
    draws: bool = true,
    /// The credential this bucket is keyed on (`tokenId`), when it is
    /// one of its own; every draw line carries it as `token_id`. Null
    /// on the shared bucket, and the line then has no such key.
    token_id: ?TokenId = null,
    /// Where the local broker for this service listens, when one was
    /// resolved (`forService` does it; `useBroker` is the test's way
    /// in). Owned. Empty means the socket is never tried and
    /// `acquireVia` is exactly `acquireDetailed`.
    broker_socket: []u8 = &.{},
    /// Until when a failed connect stops us trying the socket again,
    /// on the wall clock in seconds. A machine with no broker — which
    /// is most of the time, since mnml hosts it — must not pay a
    /// failed connect per request.
    broker_quiet_until: f64 = 0,
    /// Where the request's live phase is written as it moves — queued
    /// behind N on the broker, waiting on the file bucket, then
    /// sending — so a pane's header can say which of those it is
    /// looking at. Null writes nothing. The client that owns the
    /// `Notice` points this at it; the limiter never sets `.idle`,
    /// which is the client's to say once the reply is in.
    live: ?*Notice = null,

    /// How long one failed connect keeps `acquireVia` off the socket.
    /// Short enough that a pane opened moments after mnml starts finds
    /// the broker; long enough that a machine without one pays the
    /// failed connect twice a second rather than every request.
    pub const broker_retry_secs: f64 = 2.0;

    pub fn init(gpa: Allocator, io: Io, path: []const u8, cfg: Config) Allocator.Error!Limiter {
        return .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path), .cfg = cfg };
    }

    /// Point this limiter at a broker socket. `forService` does it
    /// from the environment; a test names the path itself.
    pub fn useBroker(self: *Limiter, path: []const u8) Allocator.Error!void {
        self.gpa.free(self.broker_socket);
        self.broker_socket = try self.gpa.dupe(u8, path);
        self.broker_quiet_until = 0;
    }

    /// Name this process in the draw lines: `program` is argv[0]'s
    /// basename, `service` the bucket's own name. Without this a
    /// limiter still works — it simply writes no draw lines, since a
    /// line that cannot say who drew is worth nothing.
    pub fn identify(self: *Limiter, service: []const u8, program: []const u8, pid: i32) Allocator.Error!void {
        self.gpa.free(self.service);
        self.service = try self.gpa.dupe(u8, service);
        self.program = program;
        self.pid = pid;
    }

    /// The limiter for a service, at the shared path the environment
    /// resolves to and with that service's preset.
    pub fn forService(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error!Limiter {
        const p = try statePath(gpa, io, env, service);
        defer gpa.free(p);
        var l = try init(gpa, io, p, configFor(service));
        errdefer l.deinit();
        try l.attachBroker(env, service);
        return l;
    }

    /// The limiter for a service spent with this credential — a bare
    /// token or the `Authorization` value it goes out as. A service in
    /// `per_token_services` gets the credential's own bucket
    /// (`statePathFor`) and draw lines naming its `token_id`; anything
    /// else is exactly `forService`.
    ///
    /// The broker is attached only when the path is still the shared
    /// file: the broker hands out tokens from the shared bucket, so a
    /// limiter keyed on its own credential asking it would spend the
    /// wrong budget.
    pub fn forToken(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8, credential: ?[]const u8) Allocator.Error!Limiter {
        const id: ?TokenId = if (!perToken(service)) null else if (credential) |c| tokenId(c) else null;
        const p = try statePathForId(gpa, io, env, service, id);
        defer gpa.free(p);
        var l = try init(gpa, io, p, configFor(service));
        errdefer l.deinit();
        const shared = try statePath(gpa, io, env, service);
        defer gpa.free(shared);
        // `token_id` only when the draws really come out of the
        // token's own bucket: an override (`<SERVICE>_RATELIMIT_STATE`)
        // names the shared file, and a draw line there naming a token
        // would pair one bucket's `tokens_after` with another's id.
        if (std.mem.eql(u8, shared, p)) try l.attachBroker(env, service) else l.token_id = id;
        return l;
    }

    /// Point this limiter at the broker socket the environment resolves
    /// for `service` — `forService`'s second half, for a pane that built
    /// its limiter on a path of its own (a configured `state_path`, a
    /// preset of its own) and would otherwise never ask the broker at
    /// all: both panes did exactly that, so the broker served Jira's
    /// Bitbucket calls and nothing else. Resolved once, whether or not
    /// anything is listening — the broker comes and goes with mnml, so
    /// "is there one" belongs to `acquireVia`, not to startup. Told
    /// `MNML_BROKER=0`, there is no socket to try at all.
    pub fn attachBroker(self: *Limiter, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error!void {
        if (!broker.enabledIn(env)) return;
        const p = broker.socketPath(self.gpa, self.io, env, service) catch return;
        defer self.gpa.free(p);
        try self.useBroker(p);
    }

    pub fn deinit(self: *Limiter) void {
        self.gpa.free(self.path);
        self.gpa.free(self.service);
        self.gpa.free(self.broker_socket);
        self.* = undefined;
    }

    /// `<dir of the state file>/<service>-draws.jsonl`. Owned by the
    /// caller; null when the limiter was never identified.
    pub fn drawsPath(self: *const Limiter, gpa: Allocator) Allocator.Error!?[]u8 {
        if (self.service.len == 0) return null;
        const dir = std.fs.path.dirname(self.path) orelse ".";
        return try std.fmt.allocPrint(gpa, "{s}/{s}-draws.jsonl", .{ dir, self.service });
    }

    /// One draw, written where everything else on this machine that
    /// shares the bucket can read it. Best effort throughout — a log
    /// is never a reason a request fails.
    fn noteDraw(self: *Limiter, a: Acquired) void {
        if (!self.draws or self.service.len == 0) return;
        const path = (self.drawsPath(self.gpa) catch return) orelse return;
        defer self.gpa.free(path);
        var buf: [512]u8 = undefined;
        // The optional eighth key: which credential's bucket this draw
        // came out of. The file stays one per service either way.
        var id_buf: [32]u8 = undefined;
        const id_field: []const u8 = if (self.token_id) |id|
            std.fmt.bufPrint(&id_buf, ",\"token_id\":\"{s}\"", .{&id}) catch ""
        else
            "";
        const line = std.fmt.bufPrint(
            &buf,
            "{{\"ts\":{d:.3},\"pid\":{d},\"program\":\"{f}\",\"service\":\"{f}\",\"reason\":\"{f}\",\"wait_ms\":{d},\"tokens_after\":{d:.3}{s}}}\n",
            .{
                nowSecs(self.io),
                self.pid,
                std.zig.fmtString(self.program),
                std.zig.fmtString(self.service),
                std.zig.fmtString(self.reason),
                a.wait_ms,
                @max(a.tokens_after, 0),
                id_field,
            },
        ) catch return;
        if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(self.io, d) catch {};
        const file = Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = false, .lock = .exclusive }) catch return;
        var end = file.length(self.io) catch 0;
        if (end + line.len > draws_max_bytes) {
            file.close(self.io);
            const older = std.fmt.allocPrint(self.gpa, "{s}.1", .{path}) catch return;
            defer self.gpa.free(older);
            Io.Dir.cwd().deleteFile(self.io, older) catch {};
            Io.Dir.cwd().rename(path, Io.Dir.cwd(), older, self.io) catch {
                Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "" }) catch {};
            };
            const fresh = Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = false, .lock = .exclusive }) catch return;
            defer fresh.close(self.io);
            end = fresh.length(self.io) catch 0;
            fresh.writePositionalAll(self.io, line, end) catch {};
            return;
        }
        defer file.close(self.io);
        file.writePositionalAll(self.io, line, end) catch {};
    }

    /// Block until a token is available. False when the limiter gave
    /// up (a wedged file, or `max_block_secs` passed); the caller
    /// should send anyway and let its own 429 handling decide.
    pub fn acquire(self: *Limiter) bool {
        return self.acquireDetailed().ok;
    }

    /// A token, through the local broker if there is one and off the
    /// shared file if there is not.
    ///
    /// The broker (`broker.zig`) is what puts the pane you are looking
    /// at in front of a batch script that asked first; the file bucket
    /// is first-come and cannot. So every request tries the socket —
    /// and every request works without it, because mnml hosts the
    /// broker and mnml is not always running.
    ///
    /// Falling back is never an error the caller sees. A socket that
    /// is missing, refused, or answering for another service is a
    /// `.file` acquire and a two-second quiet period, so a machine
    /// with no broker pays one failed connect every two seconds rather
    /// than one per request.
    ///
    /// A brokered reply of `ok:false` is the SAME fail-open the file
    /// bucket gives: the caller should send anyway and let its own 429
    /// handling decide. It is not a reason to ask the file bucket for
    /// a second token — that would spend two.
    pub fn acquireVia(self: *Limiter, class: broker.Class) Acquired {
        const got = self.brokered(class) orelse self.acquireDetailed();
        // Token in hand (or failed open, which sends anyway): the
        // request is on the wire from here.
        if (self.live) |n| n.setPhase(.sending, 0);
        return got;
    }

    /// The broker half of `acquireVia`. Null means "there is no broker
    /// here": the caller falls through to the file bucket.
    fn brokered(self: *Limiter, class: broker.Class) ?Acquired {
        if (!broker.supported or self.broker_socket.len == 0) return null;
        const now = nowSecs(self.io);
        if (now < self.broker_quiet_until) return null;
        var name_buf: [96]u8 = undefined;
        // The broker's own wait is bounded by what this limiter would
        // have waited on the file: one policy, two paths.
        const timeout_ms: u32 = @intFromFloat(@min(@max(self.cfg.max_block_secs, 0) * 1000.0, 3_600_000));
        // Who is ahead of us, before we join them: one more local
        // round trip, only when someone is going to paint the answer.
        // The queue may move while we ask; the number is the header's
        // `queued behind N`, not a contract.
        if (self.live) |n| {
            const ahead: u32 = if (self.service.len > 0)
                (if (broker.askStatus(self.io, self.broker_socket, self.service)) |st| st.total() else 0)
            else
                0;
            n.setPhase(.queued, ahead);
        }
        const rp = broker.ask(self.io, self.broker_socket, .{
            .op = .acquire,
            .service = self.service,
            .class = class,
            .client = broker.clientName(&name_buf, self.program, self.pid),
            .reason = self.reason,
            .timeout_ms = timeout_ms,
        }) orelse {
            self.broker_quiet_until = now + broker_retry_secs;
            return null;
        };
        if (rp.why) |why| switch (why) {
            // Not our broker, or not a version we speak. The file
            // bucket is the right answer and the socket is not worth
            // asking again for a while.
            .bad_request, .wrong_service => {
                self.broker_quiet_until = now + broker_retry_secs;
                return null;
            },
            // It queued us and could not serve us. That is the file
            // bucket's `gave_up`, not a reason to spend twice.
            .timeout, .closed => {
                return .{ .ok = false, .wait_ms = rp.wait_ms, .waited_for = .gave_up, .tokens_after = rp.remaining, .via = .broker };
            },
        };
        if (!rp.ok) return .{ .ok = false, .wait_ms = rp.wait_ms, .waited_for = .gave_up, .tokens_after = rp.remaining, .via = .broker };
        self.acquired += 1;
        const got: Acquired = .{
            .ok = true,
            .wait_ms = rp.wait_ms,
            // The reply says how long, never whether a 429 was the
            // reason — the broker's queue and the bucket's cooldown
            // both read as a wait from out here.
            .waited_for = if (rp.wait_ms > 0) .tokens else .nothing,
            .tokens_after = rp.remaining,
            .via = .broker,
        };
        // The broker writes no draw line, so this does: one line per
        // token, named for whoever spent it, whichever path it came
        // down. `<service>-draws.jsonl` reads the same either way.
        self.noteDraw(got);
        return got;
    }

    /// The same wait, with an account of it: how long, on what, and
    /// what was left afterwards. A pane that says `loading…` for three
    /// seconds can say WHY with this, and the request log writes it
    /// down for the run after.
    pub fn acquireDetailed(self: *Limiter) Acquired {
        const started = nowSecs(self.io);
        const deadline = started + self.cfg.max_block_secs;
        var jitter_seed: u32 = 0;
        // What the FIRST look found: a request held three seconds by an
        // empty bucket and one held three seconds by a cooldown are
        // different problems, and it is the first answer that names it.
        var cause: Wait = .nothing;
        var left: f64 = 0;
        while (true) {
            const now = nowSecs(self.io);
            var probe: Probe = .{ .cfg = self.cfg, .tokens_after = &left, .cooldown = undefined };
            var was_cooldown = false;
            probe.cooldown = &was_cooldown;
            const wait = self.withLockedState(now, probe) catch return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up };
            if (wait <= 0.0) {
                self.acquired += 1;
                const got: Acquired = .{ .ok = true, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = cause, .tokens_after = left };
                self.noteDraw(got);
                return got;
            }
            if (cause == .nothing) cause = if (was_cooldown) .cooldown else .tokens;
            // The first look that found nothing is the moment the
            // header's line changes from `fetching` to `waiting`.
            if (self.live) |n| n.setPhase(.waiting, 0);
            jitter_seed +%= 1;
            const jittered = jitter(@min(wait, 5.0), jitter_seed);
            if (nowSecs(self.io) + jittered > deadline) return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up, .tokens_after = left };
            self.io.sleep(.fromMilliseconds(@intFromFloat(@max(jittered, 0.05) * 1000.0)), .awake) catch
                return .{ .ok = false, .wait_ms = millisSince(started, nowSecs(self.io)), .waited_for = .gave_up, .tokens_after = left };
        }
    }

    /// One look at the bucket: take a token when there is one, else
    /// say how long until there is, and whether a cooldown is the
    /// reason there is not.
    const Probe = struct {
        cfg: Config,
        tokens_after: *f64,
        cooldown: *bool,

        fn apply(ctx: @This(), st: *State, at: f64) f64 {
            ctx.cooldown.* = st.cooldown_until > at;
            ctx.tokens_after.* = st.tokens;
            if (ctx.cooldown.*) return st.cooldown_until - at;
            if (st.tokens >= 1.0) {
                st.tokens -= 1.0;
                ctx.tokens_after.* = st.tokens;
                // Ease the shared rate back toward the baseline.
                st.rate = @min(ctx.cfg.rate, @max(st.rate * ctx.cfg.recover_factor, @max(st.rate, 0.0)));
                return 0.0;
            }
            const need = 1.0 - st.tokens;
            const cur = @max(st.rate, ctx.cfg.min_rate);
            return need / cur;
        }
    };

    /// Record a 429: park every process until `retry_after_secs` is
    /// up (the default cooldown when null) and cut the shared rate.
    pub fn penalize(self: *Limiter, retry_after_secs: ?f64) void {
        const now = nowSecs(self.io);
        _ = self.withLockedState(now, struct {
            cfg: Config,
            cd: f64,
            fn apply(ctx: @This(), st: *State, at: f64) f64 {
                st.rate = @max(ctx.cfg.min_rate, st.rate * ctx.cfg.penalty_factor);
                st.tokens = 0.0;
                st.cooldown_until = at + ctx.cd;
                st.throttles +|= 1;
                st.last_429 = at;
                return 0.0;
            }
        }{ .cfg = self.cfg, .cd = if (retry_after_secs) |s| (if (s > 0) s else self.cfg.default_cooldown_secs) else self.cfg.default_cooldown_secs }) catch {};
    }

    /// The bucket as the FILE stands for it, which every process
    /// sharing it reads alike: the file carries tokens and a rate but no
    /// burst, and the burst it stands for is the service's preset
    /// (`configFor` — what `budget.Bucket` reads a legacy file with).
    /// This process's config can only ask for less: a `.rate` block of
    /// `1000 / 1000` (the demo's, the corpus's) does not make a bucket
    /// that another writer keeps at the preset's 40 a bucket of 1000 —
    /// read that way, 40 tokens were 4 % of it and every poll gave way.
    /// Without a service name (never `identify`d) the config is all
    /// there is.
    pub fn sharedView(self: *const Limiter) struct { capacity: f64, rate: f64 } {
        if (self.service.len == 0) return .{ .capacity = self.cfg.capacity, .rate = self.cfg.rate };
        const preset = configFor(self.service);
        return .{ .capacity = @min(self.cfg.capacity, preset.capacity), .rate = @min(self.cfg.rate, preset.rate) };
    }

    /// A snapshot for `--diag`, a chip's hover and the warmers' budget
    /// test; null when the file cannot be read. Capacity and baseline are
    /// the file's (`sharedView`), tokens and rate the file's own, so the
    /// four agree whoever else is drawing.
    pub fn status(self: *Limiter) ?Status {
        const now = nowSecs(self.io);
        var snap: State = .{};
        _ = self.withLockedState(now, struct {
            out: *State,
            fn apply(ctx: @This(), st: *State, _: f64) f64 {
                ctx.out.* = st.*;
                return 0.0;
            }
        }{ .out = &snap }) catch return null;
        const view = self.sharedView();
        return .{
            .tokens = @min(snap.tokens, view.capacity),
            .capacity = view.capacity,
            .rate = snap.rate,
            .baseline_rate = view.rate,
            .throttles = snap.throttles,
            .cooldown_remaining_secs = @max(snap.cooldown_until - now, 0.0),
            .last_429_age_secs = if (snap.last_429 > 0) @max(now - snap.last_429, 0.0) else null,
        };
    }

    /// Open (creating), lock, read, refill, apply, write back.
    fn withLockedState(self: *Limiter, now: f64, ctx: anytype) !f64 {
        if (std.fs.path.dirname(self.path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        const file = try Io.Dir.cwd().createFile(self.io, self.path, .{ .read = true, .truncate = false, .lock = .exclusive });
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch 0;
        var st = parseState(buf[0..n]) orelse State{ .tokens = self.cfg.capacity, .rate = self.cfg.rate, .ts = now };
        const elapsed = @max(now - st.ts, 0.0);
        st.tokens = @min(self.cfg.capacity, st.tokens + elapsed * st.rate);
        if (st.rate <= 0.0) st.rate = self.cfg.rate;
        st.ts = now;
        const result = ctx.apply(&st, now);
        var out: [512]u8 = undefined;
        const text = renderState(&out, st);
        try file.setLength(self.io, 0);
        try file.writePositionalAll(self.io, text, 0);
        return result;
    }
};

/// The state file's JSON; null when it is empty or not the shape.
pub fn parseState(text: []const u8) ?State {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(State, arena_state.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed;
}

/// The state as the Python and Rust sides write it: six keys, floats as
/// decimals, ints as ints.
pub fn renderState(buf: []u8, st: State) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"ts\":{d},\"tokens\":{d},\"rate\":{d},\"cooldown_until\":{d},\"throttles\":{d},\"last_429\":{d}}}", .{
        st.ts, st.tokens, st.rate, st.cooldown_until, st.throttles, st.last_429,
    }) catch buf[0..0];
}

/// Who has been drawing on a bucket lately, from `<service>-draws.jsonl`.
pub const Draws = struct {
    /// The program with the most draws in the window.
    top: []const u8 = "",
    /// Its draws, and everyone's.
    top_n: u32 = 0,
    total: u32 = 0,

    /// `mnml-jira 41 of 83 draws in 10m` — what a chip's hover says so
    /// a drained bucket is attributable rather than mysterious.
    /// Written into `buf`; empty when nothing drew in the window.
    pub fn describe(d: Draws, buf: []u8, window_secs: u32) []const u8 {
        if (d.total == 0) return "";
        var abuf: [24]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s} {d} of {d} draws in {s}", .{
            d.top, d.top_n, d.total, ageText(&abuf, @floatFromInt(window_secs)),
        }) catch "";
    }
};

/// The top consumer of the last `window_secs`, read out of a draws
/// file. Cheap and bounded: only the tail of the file is read, since
/// a window is always the newest lines. Null when there is no file or
/// nothing in the window — never an error, because this only ever
/// decorates a hover.
pub fn recentDraws(gpa: Allocator, io: Io, path: []const u8, window_secs: u32, now: f64, name_out: []u8) ?Draws {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 * 1024 * 1024)) catch return null;
    defer gpa.free(text);
    const cutoff = now - @as(f64, @floatFromInt(window_secs));
    // Programs seen, with their counts. A machine does not run
    // hundreds of different programs against one API; past this the
    // tail simply lands in the total, which is still right.
    var names: [16][]const u8 = undefined;
    var counts: [16]u32 = @splat(0);
    var n_names: usize = 0;
    var total: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ts = jsonNumber(line, "ts") orelse continue;
        if (ts < cutoff) continue;
        total += 1;
        const prog = jsonString(line, "program") orelse "other";
        var found = false;
        for (names[0..n_names], 0..) |nm, i| {
            if (std.mem.eql(u8, nm, prog)) {
                counts[i] += 1;
                found = true;
            }
        }
        if (!found and n_names < names.len) {
            names[n_names] = prog;
            counts[n_names] = 1;
            n_names += 1;
        }
    }
    if (total == 0) return null;
    var best: usize = 0;
    for (counts[0..n_names], 0..) |c, i| if (c > counts[best]) {
        best = i;
    };
    if (n_names == 0) return .{ .total = total };
    // Every name points into `text`, which is freed on the way out,
    // so the winner is copied into the caller's own buffer.
    const name = names[best];
    const keep = @min(name.len, name_out.len);
    @memcpy(name_out[0..keep], name[0..keep]);
    return .{ .top = name_out[0..keep], .top_n = counts[best], .total = total };
}

/// `"key":<number>` out of one JSON line, without parsing the whole
/// thing — these files have millions of lines and one shape.
fn jsonNumber(line: []const u8, key: []const u8) ?f64 {
    var kbuf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    const rest = line[at + needle.len ..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.' or rest[end] == '-')) : (end += 1) {}
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// `"key":"…"` out of one JSON line. No escapes are decoded: a
/// program name that needed them would not be one.
fn jsonString(line: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    const rest = line[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn millisSince(start: f64, end: f64) u64 {
    const d = end - start;
    if (d <= 0) return 0;
    return @intFromFloat(d * 1000.0);
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

/// ±20% of `base`, from a counter rather than a random source — the
/// point is not to re-cluster after a shared cooldown, not secrecy.
fn jitter(base: f64, seed: u32) f64 {
    const noise: f64 = @as(f64, @floatFromInt(seed *% 2654435761 % 1000)) / 1000.0;
    return base * (0.8 + 0.4 * noise);
}

/// Longest service name the per-service environment override can be
/// spelled for; past it the override is simply not offered.
const max_service_len = 48;

/// `BITBUCKET_RATELIMIT_STATE`, `JIRA_RATELIMIT_STATE`, … — the
/// per-service override that names the file outright. Written into
/// `buf`; null when the service name will not fit.
pub fn stateEnvName(buf: []u8, service: []const u8) ?[]const u8 {
    const suffix = "_RATELIMIT_STATE";
    if (service.len == 0 or service.len + suffix.len > buf.len) return null;
    for (service, 0..) |c, i| buf[i] = std.ascii.toUpper(sanitizeByte(c));
    @memcpy(buf[service.len..][0..suffix.len], suffix);
    return buf[0 .. service.len + suffix.len];
}

/// The crate's own sanitiser: alphanumerics, `-` and `_` survive, the
/// rest becomes `_`, so a service name can never escape its directory.
fn sanitizeByte(c: u8) u8 {
    return if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
}

fn sanitize(buf: []u8, service: []const u8) []const u8 {
    const n = @min(service.len, buf.len);
    for (service[0..n], 0..) |c, i| buf[i] = sanitizeByte(c);
    return buf[0..n];
}

/// Where the shared bucket lives, in the order the module comment
/// gives. A pure function of the environment: `io` is unused and kept
/// so every caller's signature stays put. Owned.
pub fn statePath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, service: []const u8) Allocator.Error![]u8 {
    _ = io;
    var name_buf: [max_service_len + "_RATELIMIT_STATE".len]u8 = undefined;
    if (stateEnvName(&name_buf, service)) |name| {
        if (nonEmpty(env.get(name))) |p| return gpa.dupe(u8, p);
    }
    var svc_buf: [max_service_len]u8 = undefined;
    const svc = sanitize(&svc_buf, service);
    // The format contract's file name, in the shared directory.
    const shared_name = try std.fmt.allocPrint(gpa, "{s}-ratelimit.json", .{svc});
    defer gpa.free(shared_name);
    // mnml's own fallback lives under a `ratelimit/` directory instead.
    const own_name = try std.fmt.allocPrint(gpa, "{s}.json", .{svc});
    defer gpa.free(own_name);

    // `HOME`, else `USERPROFILE` (Windows sets no `HOME`).
    const home_dir = nonEmpty(env.get("HOME")) orelse nonEmpty(env.get("USERPROFILE"));
    if (nonEmpty(env.get("MNML_SHARED_STATE_DIR"))) |dir| return std.fs.path.join(gpa, &.{ dir, shared_name });
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return std.fs.path.join(gpa, &.{ root, "ratelimit", own_name });
    if (home_dir) |home| return std.fs.path.join(gpa, &.{ home, ".config", "mnml", "ratelimit", own_name });
    return std.fs.path.join(gpa, &.{ "ratelimit", own_name });
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ─── a 429, answered the same way by every integration ─────────────────

/// `Retry-After` as whole seconds. A date form (RFC 9110 allows one)
/// is not parsed — the caller's default stands.
pub fn parseRetryAfter(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// What a request does with a 429: park the shared bucket for as long
/// as the server asked (`Limiter.penalize`), wait that long, and ask
/// again — up to `max_attempts` in all. A wait longer than
/// `max_backoff_secs` is not slept through in the request: the bucket
/// stays parked for the whole of it and the failure goes back to the
/// caller, whose header says so. Both first-party integrations send
/// through this, so one site's `Retry-After: 2` is two seconds in the
/// Jira pane and the Bitbucket pane alike.
pub const Retry = struct {
    max_attempts: u32 = 3,
    /// A 429 with no `Retry-After`.
    default_backoff_secs: u32 = 15,
    max_backoff_secs: u32 = 30,

    /// The seconds to wait before attempt `attempt + 1` (attempts count
    /// from 1), or null when the request should give up now.
    pub fn next(r: Retry, attempt: u32, retry_after: ?u32) ?u32 {
        if (attempt >= @max(r.max_attempts, 1)) return null;
        const want = retry_after orelse r.default_backoff_secs;
        if (want > r.max_backoff_secs) return null;
        return want;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("testing.zig");

test "Bitbucket's preset is the measured one, Jira's the Rust crate's, and an unknown service takes the tightest" {
    // Measured 2026-10-07 (per token): 1.2/s sustained, a 40-token
    // burst, 30 s parked after a 429; the floor a cut stops at is the
    // crate's.
    try t.expectApproxEqAbs(@as(f64, 1.2), Config.bitbucket.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 40.0), Config.bitbucket.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.05), Config.bitbucket.min_rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 30.0), Config.bitbucket.default_cooldown_secs, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.33), Config.jira.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 60.0), Config.jira.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.08), Config.jira.min_rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 45.0), Config.jira.default_cooldown_secs, 1e-12);
    for ([_]Config{ Config.bitbucket, Config.jira }) |c| {
        try t.expectApproxEqAbs(@as(f64, 0.5), c.penalty_factor, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 1.02), c.recover_factor, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 120.0), c.max_block_secs, 1e-12);
    }
    try t.expectApproxEqAbs(Config.bitbucket.rate, configFor("bitbucket").rate, 1e-12);
    try t.expectApproxEqAbs(Config.jira.rate, configFor("Jira").rate, 1e-12);
    // An API nobody measured does not inherit Bitbucket's measured
    // rate: it gets the crate's old constants.
    const unknown = configFor("something-else");
    try t.expectApproxEqAbs(@as(f64, 0.22), unknown.rate, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 40.0), unknown.capacity, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 60.0), unknown.default_cooldown_secs, 1e-12);
}

test "a 429 with no Retry-After parks a Bitbucket bucket for the preset's 30 s" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit.json" });
    defer t.allocator.free(path);
    var l = try Limiter.init(t.allocator, t.io, path, configFor("bitbucket"));
    defer l.deinit();
    l.penalize(null);
    const st = l.status().?;
    try t.expect(st.cooldown_remaining_secs > 28.0 and st.cooldown_remaining_secs <= 30.0);
}

test "the token id is the first 12 hex of a sha256 — pinned to two vectors" {
    // Computed with Python's hashlib at the time the rule was written:
    //   hashlib.sha256(b"abc").hexdigest()[:12]      == "ba7816bf8f01"
    //   hashlib.sha256(b"me@x:pw").hexdigest()[:12]  == "0032469eec6d"
    // Any other implementation of the contract must agree with these.
    try t.expectEqualStrings("ba7816bf8f01", &tokenIdOfBytes("abc"));
    try t.expectEqualStrings("0032469eec6d", &tokenIdPair("me@x", "pw"));
    // A bare token, and the same token as a Bearer header, are one id.
    try t.expectEqualStrings("ba7816bf8f01", &tokenId("abc").?);
    try t.expectEqualStrings("ba7816bf8f01", &tokenId("Bearer abc").?);
    // A Basic header is decoded first: `me@x:pw` is `bWVAeDpwdw==`.
    try t.expectEqualStrings("0032469eec6d", &tokenId("Basic bWVAeDpwdw==").?);
    // Nothing to hash is no id — the shared bucket, not a bucket for "".
    try t.expect(tokenId("") == null);
    try t.expect(tokenId("Bearer ") == null);
    try t.expect(tokenId("Basic ") == null);
}

test "a per-token bucket sits beside the shared file; no credential, an override or Jira is the shared file" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    {
        const p = try statePathFor(t.allocator, t.io, &env, "bitbucket", "ATCTTfake-token-for-a-test");
        defer t.allocator.free(p);
        const id = tokenIdOfBytes("ATCTTfake-token-for-a-test");
        const want = try std.fmt.allocPrint(t.allocator, "/shared/bitbucket-ratelimit-{s}.json", .{&id});
        defer t.allocator.free(want);
        try sdk_testing.expectPath(want, p);
    }
    // No credential, or an empty one: the shared file, unchanged.
    for ([_]?[]const u8{ null, "" }) |cred| {
        const p = try statePathFor(t.allocator, t.io, &env, "bitbucket", cred);
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/shared/bitbucket-ratelimit.json", p);
    }
    // Jira has not opted in: a credential changes nothing.
    {
        const p = try statePathFor(t.allocator, t.io, &env, "jira", "ATCTTfake-token-for-a-test");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/shared/jira-ratelimit.json", p);
    }
    // Without a shared directory it is still beside the shared file.
    try env.put("MNML_SHARED_STATE_DIR", "");
    try env.put("MNML_DATA_ROOT", "/data");
    {
        const p = try statePathFor(t.allocator, t.io, &env, "bitbucket", "abc");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/data/ratelimit/bitbucket-ratelimit-ba7816bf8f01.json", p);
    }
    // An override names the file outright, credential or not.
    try env.put("BITBUCKET_RATELIMIT_STATE", "/tmp/named.json");
    {
        const p = try statePathFor(t.allocator, t.io, &env, "bitbucket", "abc");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/tmp/named.json", p);
    }
}

test "a limiter for a token spends its own bucket, skips the shared broker, and names the token in its draws" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_SHARED_STATE_DIR", dir);

    var mine = try Limiter.forToken(t.allocator, t.io, &env, "bitbucket", "Bearer abc");
    defer mine.deinit();
    try mine.identify("bitbucket", "mnml-bitbucket", 7);
    // The broker serves the shared bucket; this one is not that.
    try t.expectEqualStrings("", mine.broker_socket);
    try t.expectApproxEqAbs(Config.bitbucket.rate, mine.cfg.rate, 1e-12);
    try t.expect(mine.acquire());

    // An older client, with no credential to name, on the shared file.
    var old = try Limiter.forToken(t.allocator, t.io, &env, "bitbucket", null);
    defer old.deinit();
    try old.identify("bitbucket", "bb.py", 8);
    try t.expect(old.acquire());
    if (broker.supported) try t.expect(old.broker_socket.len > 0);

    // Two buckets, one draws file.
    const own = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit-ba7816bf8f01.json" });
    defer t.allocator.free(own);
    const shared = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit.json" });
    defer t.allocator.free(shared);
    try Io.Dir.cwd().access(t.io, own, .{});
    try Io.Dir.cwd().access(t.io, shared, .{});
    const a = (try mine.drawsPath(t.allocator)).?;
    defer t.allocator.free(a);
    const b = (try old.drawsPath(t.allocator)).?;
    defer t.allocator.free(b);
    try t.expectEqualStrings(a, b);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, a, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    const first = it.next().?;
    const second = it.next().?;
    try t.expect(std.mem.indexOf(u8, first, "\"token_id\":\"ba7816bf8f01\"") != null);
    try t.expect(std.mem.indexOf(u8, second, "token_id") == null);
    for ([_][]const u8{ first, second }) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
        parsed.deinit();
    }
    // The state file is still the six keys.
    const st = try Io.Dir.cwd().readFileAlloc(t.io, own, t.allocator, .limited(4096));
    defer t.allocator.free(st);
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, st, "\":"));

    // Jira, asked the same way, is `forService`.
    var jira = try Limiter.forToken(t.allocator, t.io, &env, "jira", "Bearer abc");
    defer jira.deinit();
    try t.expect(jira.token_id == null);
    try t.expect(std.mem.endsWith(u8, jira.path, "jira-ratelimit.json"));

    // An override names the file outright: no per-token bucket, so no
    // `token_id` on its draws — `tokens_after` is the override's.
    const named = try std.fs.path.join(t.allocator, &.{ dir, "named.json" });
    defer t.allocator.free(named);
    try env.put("BITBUCKET_RATELIMIT_STATE", named);
    var over = try Limiter.forToken(t.allocator, t.io, &env, "bitbucket", "Bearer abc");
    defer over.deinit();
    try t.expect(over.token_id == null);
    try sdk_testing.expectPath(named, over.path);
}

test "a state file written by the Rust crate reads back field for field" {
    // Written by hand from the crate's schema — six keys, serde's
    // spelling, the field order `State` declares them in.
    const fixture = @embedFile("testdata/rust-written-ratelimit.json");
    const st = parseState(fixture).?;
    try t.expectApproxEqAbs(@as(f64, 1789526218.009115), st.ts, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 12.5), st.tokens, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.11), st.rate, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1789526278.009115), st.cooldown_until, 1e-6);
    try t.expectEqual(@as(u32, 7), st.throttles);
    try t.expectApproxEqAbs(@as(f64, 1789526218.009115), st.last_429, 1e-6);
    // And what we write is what it reads: the same six keys, in the
    // same order, no others.
    var buf: [512]u8 = undefined;
    const text = renderState(&buf, st);
    for ([_][]const u8{ "\"ts\":", "\"tokens\":", "\"rate\":", "\"cooldown_until\":", "\"throttles\":", "\"last_429\":" }) |key| {
        try t.expect(std.mem.indexOf(u8, text, key) != null);
        try t.expect(std.mem.indexOf(u8, fixture, key) != null);
    }
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, text, "\":"));
    const back = parseState(text).?;
    try t.expectEqual(st.throttles, back.throttles);
    try t.expectApproxEqAbs(st.tokens, back.tokens, 1e-9);
    try t.expect(parseState("") == null);
    try t.expect(parseState("nonsense") == null);
    // A key the crate might add later is ignored, not fatal.
    try t.expect(parseState("{\"ts\":1,\"tokens\":2,\"rate\":0.2,\"cooldown_until\":0,\"throttles\":0,\"last_429\":0,\"future\":9}") != null);
}

test "two limiters on one file share the tokens, and one 429 parks both" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "bucket", "jira-ratelimit.json" });
    defer t.allocator.free(path);
    // Two independent limiters — stand-ins for two processes: a pane
    // and the statusline poller.
    var pane = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 3.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer pane.deinit();
    var poller = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 3.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer poller.deinit();

    // Three tokens between them, not three each.
    try t.expect(pane.acquire());
    try t.expect(poller.acquire());
    try t.expect(pane.acquire());
    try t.expect(!poller.acquire());
    try t.expectEqual(@as(u32, 2), pane.acquired);
    try t.expectEqual(@as(u32, 1), poller.acquired);

    // One 429 seen by one process parks the other.
    poller.penalize(30);
    try t.expect(!pane.acquire());
    const s = pane.status().?;
    try t.expectEqual(@as(u32, 1), s.throttles);
    try t.expectApproxEqAbs(@as(f64, 0.25), s.rate, 1e-9);
    try t.expect(s.cooldown_remaining_secs > 25.0);
    // The file is what any other process reads.
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"throttles\":1") != null);
}

test "every draw is written beside the state file, where anything else on the machine can read it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "jira-ratelimit.json" });
    defer t.allocator.free(path);

    // A limiter nobody identified writes no draw lines: a line that
    // cannot say who drew is worth nothing.
    var anon = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 8.0, .rate = 5.0 });
    defer anon.deinit();
    try t.expect(anon.acquire());
    try t.expect((try anon.drawsPath(t.allocator)) == null);

    var pane = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 8.0, .rate = 5.0 });
    defer pane.deinit();
    try pane.identify("jira", "mnml-jira", 48123);
    pane.reason = "pane_open";
    try t.expect(pane.acquire());
    try t.expect(pane.acquire());
    pane.reason = "poll";
    try t.expect(pane.acquire());

    // A second process on the SAME bucket — the case the file exists
    // for — appends to the same file under its own name.
    var script = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 8.0, .rate = 5.0 });
    defer script.deinit();
    try script.identify("jira", "bb.py", 91002);
    script.reason = "user";
    try t.expect(script.acquire());

    const draws = (try pane.drawsPath(t.allocator)).?;
    defer t.allocator.free(draws);
    // Beside the state file, in the shared directory, under the name
    // the contract in docs/SDK.md gives.
    const want = try std.fs.path.join(t.allocator, &.{ dir, "jira-draws.jsonl" });
    defer t.allocator.free(want);
    try sdk_testing.expectPath(want, draws);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, draws, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expectEqual(@as(usize, 4), std.mem.count(u8, text, "\n"));
    // The seven keys the contract names, on every line, and nothing
    // that could be a credential.
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        for ([_][]const u8{ "\"ts\":", "\"pid\":", "\"program\":", "\"service\":", "\"reason\":", "\"wait_ms\":", "\"tokens_after\":" }) |k| {
            t.expect(std.mem.indexOf(u8, line, k) != null) catch |err| {
                std.debug.print("missing {s} in {s}\n", .{ k, line });
                return err;
            };
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
        parsed.deinit();
    }
    try t.expect(std.mem.indexOf(u8, text, "\"program\":\"mnml-jira\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"program\":\"bb.py\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"reason\":\"pane_open\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"pid\":48123") != null);

    // And the state file itself gained nothing: the Rust and Python
    // writers rewrite those six keys wholesale, so a seventh there
    // would be dropped or choke them.
    const st = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(st);
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, st, "\":"));
    try t.expect(std.mem.indexOf(u8, st, "program") == null);

    // Read back: who has been spending, over a window.
    var nbuf: [64]u8 = undefined;
    const now = nowSecs(t.io);
    const d = recentDraws(t.allocator, t.io, draws, 600, now, &nbuf).?;
    try t.expectEqual(@as(u32, 4), d.total);
    try t.expectEqualStrings("mnml-jira", d.top);
    try t.expectEqual(@as(u32, 3), d.top_n);
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("mnml-jira 3 of 4 draws in 10m", d.describe(&buf, 600));
    // A window that ended before any of them saw nothing at all.
    try t.expect(recentDraws(t.allocator, t.io, draws, 600, now + 4000, &nbuf) == null);
    // A file that is not there is not an error: this only decorates a
    // hover.
    try t.expect(recentDraws(t.allocator, t.io, "/nonexistent/x-draws.jsonl", 600, now, &nbuf) == null);
}

test "the hover line says what the bucket holds, at what rate, and how long since the last 429" {
    var buf: [160]u8 = undefined;
    // A healthy bucket: no throttles, no 429, nothing alarming to say.
    try t.expectEqualStrings(
        "budget: 12.0 of 60 tokens · 0.33/s",
        (Status{ .tokens = 12.0, .capacity = 60, .rate = 0.33, .baseline_rate = 0.33, .throttles = 0, .cooldown_remaining_secs = 0 }).describe(&buf),
    );
    // A drained, cut, parked one says all four things — which is the
    // whole answer to "why is this pane slow".
    try t.expectEqualStrings(
        "budget: 0.2 of 40 tokens · 0.11/s (cut from 0.22) · 127 throttles · last 429 4h ago",
        (Status{
            .tokens = 0.24,
            .capacity = 40,
            .rate = 0.11,
            .baseline_rate = 0.22,
            .throttles = 127,
            .cooldown_remaining_secs = 0,
            .last_429_age_secs = 4 * 3600,
        }).describe(&buf),
    );
    try t.expect(std.mem.indexOf(u8, (Status{
        .tokens = 0,
        .capacity = 40,
        .rate = 0.22,
        .baseline_rate = 0.22,
        .throttles = 1,
        .cooldown_remaining_secs = 28,
        .last_429_age_secs = 31,
    }).describe(&buf), "parked 28s") != null);
    var abuf: [24]u8 = undefined;
    try t.expectEqualStrings("42s", ageText(&abuf, 42));
    try t.expectEqualStrings("7m", ageText(&abuf, 7 * 60));
    try t.expectEqualStrings("4h", ageText(&abuf, 4 * 3600));
    try t.expectEqualStrings("3d", ageText(&abuf, 3 * 86400));
}

test "the status a live bucket reports carries the age of its last 429" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "b.json" });
    defer t.allocator.free(path);
    var l = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 4.0, .rate = 0.5 });
    defer l.deinit();
    try t.expect(l.acquire());
    // Never throttled: there is no age to report, and the hover says
    // nothing about a 429 rather than saying "0s ago".
    const clean = l.status().?;
    try t.expect(clean.last_429_age_secs == null);
    var buf: [160]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, clean.describe(&buf), "429") == null);
    l.penalize(5);
    const after = l.status().?;
    try t.expect(after.last_429_age_secs != null);
    try t.expect(after.last_429_age_secs.? < 5.0);
    try t.expectEqual(@as(u32, 1), after.throttles);
    try t.expect(std.mem.indexOf(u8, after.describe(&buf), "last 429") != null);
}

test "a config that asks for more than the shared file stands for reads the file's bucket: 40 of 40, not 40 of 1000 — and nothing says `cut from` without a 429" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit.json" });
    defer t.allocator.free(path);
    // Another writer keeps the file at Bitbucket's preset: 40 tokens, 1.2/s.
    {
        var preset = try Limiter.init(t.allocator, t.io, path, .bitbucket);
        defer preset.deinit();
        try preset.identify("bitbucket", "other", 1);
        preset.draws = false;
        try t.expect(preset.acquire());
    }
    // This one's config says 1000 / 1000 (the demo's `.rate` block).
    var cfg = Config.bitbucket;
    cfg.rate = 1000;
    cfg.capacity = 1000;
    var mine = try Limiter.init(t.allocator, t.io, path, cfg);
    defer mine.deinit();
    mine.draws = false;
    // Unnamed, the config is all there is.
    try t.expectApproxEqAbs(@as(f64, 1000), mine.status().?.capacity, 1e-9);
    try mine.identify("bitbucket", "mnml-bitbucket", 2);
    const st = mine.status().?;
    try t.expectApproxEqAbs(@as(f64, 40), st.capacity, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1.2), st.baseline_rate, 1e-9);
    try t.expect(st.tokens <= st.capacity);
    try t.expect(st.tokens / st.capacity > 0.9);
    // So a `--values` poll does not give way to a full bucket.
    try t.expect(!@import("warm.zig").underBudget(st));
    var buf: [160]u8 = undefined;
    const line = st.describe(&buf);
    try t.expect(std.mem.indexOf(u8, line, "of 40 tokens") != null);
    try t.expect(std.mem.indexOf(u8, line, "cut from") == null);
    // A config that asks for LESS is its own: 10 of burst reads 10.
    var low = Config.bitbucket;
    low.capacity = 10;
    low.rate = 0.5;
    mine.cfg = low;
    try t.expectApproxEqAbs(@as(f64, 10), mine.status().?.capacity, 1e-9);
    // A rate below the baseline with no 429 is not a cut.
    try t.expect(std.mem.indexOf(u8, (Status{ .tokens = 59, .capacity = 60, .rate = 0.33, .baseline_rate = 1000, .throttles = 0, .cooldown_remaining_secs = 0 }).describe(&buf), "cut from") == null);
    try t.expect(std.mem.indexOf(u8, (Status{ .tokens = 0, .capacity = 60, .rate = 0.16, .baseline_rate = 0.33, .throttles = 1, .cooldown_remaining_secs = 0, .last_429_age_secs = 30 }).describe(&buf), "(cut from 0.33)") != null);
}

test "a wait a person would notice becomes one line; a wait they would not is dropped" {
    var n: Notice = .{};
    // Under the threshold: nothing to say. A pane that is working
    // should not narrate.
    n.record(.{ .ok = true, .wait_ms = 0, .waited_for = .nothing, .tokens_after = 12.0 });
    n.record(.{ .ok = true, .wait_ms = Notice.threshold_ms - 1, .waited_for = .tokens, .tokens_after = 0.4 });
    try t.expect(n.take() == null);

    // Over it: the longest wait wins, and the line says how long, on
    // what, and what is left.
    n.record(.{ .ok = true, .wait_ms = 3100, .waited_for = .tokens, .tokens_after = 0.24 });
    n.record(.{ .ok = true, .wait_ms = 2200, .waited_for = .tokens, .tokens_after = 0.9 });
    const got = n.take().?;
    try t.expectEqual(@as(u64, 3100), got.wait_ms);
    try t.expect(!got.cooldown);
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("waiting for the API budget · 3.1 s · 0.2 tokens", got.text(&buf));
    // Taken once: the next paint does not repeat it.
    try t.expect(n.take() == null);

    // A 429's cooldown is a different sentence, because it is a
    // different problem.
    n.record(.{ .ok = true, .wait_ms = 30000, .waited_for = .cooldown, .tokens_after = 0.0 });
    const parked = n.take().?;
    try t.expect(parked.cooldown);
    try t.expectEqualStrings("backing off after a 429 · 30.0 s · 0.0 tokens", parked.text(&buf));

    // The live phase is a separate channel from the wait already paid:
    // it says what the request is doing NOW, and `take` leaves it alone.
    try t.expectEqual(Notice.Phase.idle, n.live().phase);
    n.setPhase(.queued, 3);
    try t.expectEqual(Notice.Phase.queued, n.live().phase);
    try t.expectEqual(@as(u32, 3), n.live().behind);
    try t.expect(n.take() == null);
    try t.expectEqual(Notice.Phase.queued, n.live().phase);
    n.setPhase(.sending, 0);
    try t.expectEqual(Notice.Phase.sending, n.live().phase);
    try t.expectEqual(@as(u32, 0), n.live().behind);
    n.setPhase(.idle, 0);
    try t.expectEqual(Notice.Phase.idle, n.live().phase);
}

test "acquire says what it waited on: nothing, an empty bucket, then a 429's cooldown" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "jira-ratelimit.json" });
    defer t.allocator.free(path);
    // Two tokens, and a refill slow enough that the third is a real
    // wait rather than a race with the clock: a second's stall between
    // two draws (a loaded runner) refills 0.01 of a token.
    var l = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 2.0, .rate = 0.01, .min_rate = 0.01, .max_block_secs = 0.3 });
    defer l.deinit();

    // A token in hand: no wait, and the count left is what the next
    // caller will find.
    const first = l.acquireDetailed();
    try t.expect(first.ok);
    try t.expectEqual(Wait.nothing, first.waited_for);
    try t.expectApproxEqAbs(@as(f64, 1.0), first.tokens_after, 0.01);
    const second = l.acquireDetailed();
    try t.expect(second.ok);
    try t.expectEqual(Wait.nothing, second.waited_for);
    try t.expectApproxEqAbs(@as(f64, 0.0), second.tokens_after, 0.01);

    // The bucket is empty and the refill is slower than the budget to
    // wait in: the limiter fails open rather than hanging the pane.
    const third = l.acquireDetailed();
    try t.expect(!third.ok);
    try t.expectEqual(Wait.gave_up, third.waited_for);

    // An empty bucket that WILL refill inside the budget: the request
    // goes out, having really waited, and the wait is blamed on the
    // tokens rather than on anything else.
    // On a bucket of its own: the refill rate lives in the FILE, so a
    // limiter pointed at the one above would inherit its 0.01. One
    // token a second: a runner that stalls between the two draws for
    // less than that still finds the bucket empty.
    const quick_path = try std.fs.path.join(t.allocator, &.{ dir, "quick-ratelimit.json" });
    defer t.allocator.free(quick_path);
    var quick = try Limiter.init(t.allocator, t.io, quick_path, .{ .capacity = 1.0, .rate = 1.0, .max_block_secs = 5.0 });
    defer quick.deinit();
    try t.expect(quick.acquire());
    const waited = quick.acquireDetailed();
    try t.expect(waited.ok);
    try t.expectEqual(Wait.tokens, waited.waited_for);
    try t.expect(waited.wait_ms > 0);

    // A 429 is a different reason for the same silence, and the
    // account of the wait says so rather than blaming the refill.
    const parked_path = try std.fs.path.join(t.allocator, &.{ dir, "parked-ratelimit.json" });
    defer t.allocator.free(parked_path);
    var parked = try Limiter.init(t.allocator, t.io, parked_path, .{ .capacity = 4.0, .rate = 20.0, .max_block_secs = 5.0 });
    defer parked.deinit();
    try t.expect(parked.acquire());
    // A second's cooldown: the first look has to land inside it, and a
    // 50 ms one expired before it on a loaded Debug runner (the look
    // then found the cut bucket refilling, and blamed the tokens).
    parked.penalize(1.0);
    const after_429 = parked.acquireDetailed();
    try t.expect(after_429.ok);
    try t.expectEqual(Wait.cooldown, after_429.waited_for);
    try t.expect(after_429.wait_ms > 0);

    // A cooldown longer than the budget fails open, and still names
    // the cooldown rather than pretending nothing happened.
    var impatient = try Limiter.init(t.allocator, t.io, parked_path, .{ .capacity = 4.0, .rate = 20.0, .max_block_secs = 0.0 });
    defer impatient.deinit();
    impatient.penalize(30);
    const gave_up = impatient.acquireDetailed();
    try t.expect(!gave_up.ok);
    try t.expectEqual(Wait.gave_up, gave_up.waited_for);
    // `acquire` is still the boolean every existing caller reads.
    try t.expect(!impatient.acquire());
}

test "the state path falls back to USERPROFILE where there is no HOME (Windows)" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "/nonexistent-profile");
    const want = try std.fs.path.join(t.allocator, &.{ "/nonexistent-profile", ".config", "mnml", "ratelimit", "jira.json" });
    defer t.allocator.free(want);
    const p = try statePath(t.allocator, t.io, &env, "jira");
    defer t.allocator.free(p);
    try t.expectEqualStrings(want, p);
    // An empty HOME is no home: USERPROFILE still answers.
    try env.put("HOME", "");
    const q = try statePath(t.allocator, t.io, &env, "jira");
    defer t.allocator.free(q);
    try t.expectEqualStrings(want, q);
}

test "the state path resolves in four steps: override, shared dir, data root, home config" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    // 4. Nothing set but a home: mnml's own config directory.
    {
        const p = try statePath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/nonexistent-home/.config/mnml/ratelimit/jira.json", p);
    }
    // 3. A data root is ahead of it.
    try env.put("MNML_DATA_ROOT", "/data");
    for ([_][2][]const u8{
        .{ "bitbucket", "/data/ratelimit/bitbucket.json" },
        .{ "jira", "/data/ratelimit/jira.json" },
    }) |case| {
        const p = try statePath(t.allocator, t.io, &env, case[0]);
        defer t.allocator.free(p);
        try sdk_testing.expectPath(case[1], p);
    }
    // 2. The shared-state directory is ahead of that, under the format
    // contract's file name.
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    for ([_][2][]const u8{
        .{ "bitbucket", "/shared/bitbucket-ratelimit.json" },
        .{ "jira", "/shared/jira-ratelimit.json" },
    }) |case| {
        const p = try statePath(t.allocator, t.io, &env, case[0]);
        defer t.allocator.free(p);
        try sdk_testing.expectPath(case[1], p);
    }
    // An empty shared directory is no directory.
    try env.put("MNML_SHARED_STATE_DIR", "");
    {
        const p = try statePath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/data/ratelimit/jira.json", p);
    }
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    // 1. The per-service override wins, and only for its own service.
    try env.put("JIRA_RATELIMIT_STATE", "/tmp/j.json");
    {
        const p = try statePath(t.allocator, t.io, &env, "jira");
        defer t.allocator.free(p);
        try sdk_testing.expectPath("/tmp/j.json", p);
        const other = try statePath(t.allocator, t.io, &env, "bitbucket");
        defer t.allocator.free(other);
        try sdk_testing.expectPath("/shared/bitbucket-ratelimit.json", other);
    }
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("BITBUCKET_RATELIMIT_STATE", stateEnvName(&buf, "bitbucket").?);
    try t.expectEqualStrings("JIRA_RATELIMIT_STATE", stateEnvName(&buf, "jira").?);
    // A service name cannot walk out of the directory it is given.
    var svc_buf: [16]u8 = undefined;
    try t.expectEqualStrings("___x", sanitize(&svc_buf, "../x"));
}

test "no folder under the home directory is probed for the shared bucket" {
    // A home holding a dot-folder of `<service>-ratelimit.json` files —
    // the shape a shared directory has — is not picked up: only
    // `MNML_SHARED_STATE_DIR` names the shared directory.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(t.io, &buf)];
    for ([_][]const u8{ ".shared-state", ".artifacts", ".mnml" }) |stray| {
        try tmp.dir.createDirPath(t.io, stray);
        const file = try std.fmt.allocPrint(t.allocator, "{s}/jira-ratelimit.json", .{stray});
        defer t.allocator.free(file);
        try tmp.dir.writeFile(t.io, .{ .sub_path = file, .data = "{}" });
    }
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    const want = try std.fs.path.join(t.allocator, &.{ home, ".config", "mnml", "ratelimit", "jira.json" });
    defer t.allocator.free(want);
    const p = try statePath(t.allocator, t.io, &env, "jira");
    defer t.allocator.free(p);
    try sdk_testing.expectPath(want, p);
    for ([_][]const u8{ ".shared-state", ".artifacts", ".mnml" }) |stray| {
        try t.expect(std.mem.indexOf(u8, p, stray) == null);
    }
}

test "acquireVia falls back to the file bucket when there is no broker, and says so" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "jira-ratelimit.json" });
    defer t.allocator.free(path);
    var l = try Limiter.init(t.allocator, t.io, path, .{ .capacity = 2.0, .rate = 0.5, .max_block_secs = 0.2 });
    defer l.deinit();
    l.draws = false;

    // No socket named at all: `acquireVia` is exactly `acquireDetailed`.
    const bare = l.acquireVia(.interactive);
    try t.expect(bare.ok);
    try t.expectEqual(Via.file, bare.via);

    // A socket named but nothing listening: the same answer, and the
    // failed connect is remembered so the next request does not pay
    // for it again.
    const nowhere = try std.fs.path.join(t.allocator, &.{ dir, "jira-broker.sock" });
    defer t.allocator.free(nowhere);
    try l.useBroker(nowhere);
    try t.expectEqual(@as(f64, 0), l.broker_quiet_until);
    const fell_back = l.acquireVia(.interactive);
    try t.expect(fell_back.ok);
    try t.expectEqual(Via.file, fell_back.via);
    try t.expect(l.broker_quiet_until > nowSecs(t.io));

    // Two tokens between them, taken through whichever path: the
    // fallback is not a second bucket.
    try t.expect(!l.acquireVia(.interactive).ok);
    try t.expectEqual(@as(u32, 2), l.acquired);
}

test "a limiter for a service resolves its broker socket beside the bucket, listening or not" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    var l = try Limiter.forService(t.allocator, t.io, &env, "bitbucket");
    defer l.deinit();
    try sdk_testing.expectPath("/data/ratelimit/bitbucket.json", l.path);
    // Resolved at startup, tried per request — the broker comes and
    // goes with mnml.
    if (broker.supported) try sdk_testing.expectPath("/data/ratelimit/bitbucket-broker.sock", l.broker_socket);
}

test "a limiter built on a path of its own attaches the environment's broker socket — and none under MNML_BROKER=0" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const own = try std.fmt.allocPrint(t.allocator, "{s}/my-bitbucket-bucket.json", .{dir});
    defer t.allocator.free(own);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_BROKER_SOCKET", "/tmp/bb-test-broker.sock");

    // The pane's way: its own state path, its own preset, then the broker.
    var l = try Limiter.init(t.allocator, t.io, own, .{ .rate = 2.0, .capacity = 4.0 });
    defer l.deinit();
    try t.expectEqualStrings("", l.broker_socket);
    try l.attachBroker(&env, "bitbucket");
    try t.expectEqualStrings("/tmp/bb-test-broker.sock", l.broker_socket);
    // The path and the preset are still the pane's.
    try t.expectEqualStrings(own, l.path);
    try t.expectApproxEqAbs(@as(f64, 4.0), l.cfg.capacity, 0.001);

    try env.put("MNML_BROKER", "0");
    var off = try Limiter.init(t.allocator, t.io, own, .{});
    defer off.deinit();
    try off.attachBroker(&env, "bitbucket");
    try t.expectEqualStrings("", off.broker_socket);
}

test "MNML_BROKER=0 leaves a limiter without a broker socket: every acquire is the file bucket's" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", dir);
    for ([_][]const u8{ "0", "off", "False", "NO" }) |v| {
        try env.put(broker.enabled_env, v);
        var l = try Limiter.forService(t.allocator, t.io, &env, "bitbucket");
        defer l.deinit();
        try t.expectEqualStrings("", l.broker_socket);
        const got = l.acquireVia(.interactive);
        try t.expect(got.ok);
        try t.expectEqual(Via.file, got.via);
    }
    // Anything else leaves it on.
    try env.put(broker.enabled_env, "1");
    var on = try Limiter.forService(t.allocator, t.io, &env, "bitbucket");
    defer on.deinit();
    if (broker.supported) try t.expect(on.broker_socket.len > 0);
}

test "a brokered acquire is one token off the same bucket, marked broker, with its draw line written" {
    if (!broker.supported) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const state = try std.fs.path.join(t.allocator, &.{ dir, "bitbucket-ratelimit.json" });
    defer t.allocator.free(state);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_RATELIMIT_STATE", state);
    const server = broker.Server.start(t.allocator, t.io, &env, .{
        .service = "bitbucket",
        .program = "mnml-zig",
        .pid = 1,
        .config = .{ .capacity = 4.0, .rate = 8.0, .max_block_secs = 5.0 },
    }) catch return error.SkipZigTest;
    defer {
        server.stop();
        server.destroy();
    }

    var l = try Limiter.forService(t.allocator, t.io, &env, "bitbucket");
    defer l.deinit();
    l.cfg = .{ .capacity = 4.0, .rate = 8.0, .max_block_secs = 5.0 };
    try l.identify("bitbucket", "mnml-bitbucket", 99);
    l.reason = "pane_open";
    try t.expectEqualStrings(server.path(), l.broker_socket);

    // The live phase a header reads: joining the queue says how many
    // are ahead (nobody, on a fresh broker), and the token in hand
    // says the request is on the wire. `.idle` is the client's to
    // write once the reply is in, so it is still `.sending` here.
    var notice: Notice = .{};
    l.live = &notice;
    try t.expectEqual(Notice.Phase.idle, notice.live().phase);
    const got = l.acquireVia(.interactive);
    try t.expect(got.ok);
    try t.expectEqual(Via.broker, got.via);
    try t.expectEqual(@as(u32, 1), l.acquired);
    try t.expectEqual(Notice.Phase.sending, notice.live().phase);
    try t.expectEqual(@as(u32, 0), notice.live().behind);

    // One bucket: the file says the token went.
    const text = try Io.Dir.cwd().readFileAlloc(t.io, state, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    const st = parseState(text).?;
    try t.expect(st.tokens < 4.0);

    // And one draw line, written by the CLIENT — so the machine-wide
    // file still says who spent the budget rather than saying the
    // broker did.
    const draws = (try l.drawsPath(t.allocator)).?;
    defer t.allocator.free(draws);
    const lines = try Io.Dir.cwd().readFileAlloc(t.io, draws, t.allocator, .limited(4096));
    defer t.allocator.free(lines);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, lines, "\n"));
    try t.expect(std.mem.indexOf(u8, lines, "\"program\":\"mnml-bitbucket\"") != null);
    try t.expect(std.mem.indexOf(u8, lines, "\"reason\":\"pane_open\"") != null);
}

test "a 429 is retried after what the server asked, a bounded number of times, never through a long park" {
    const r: Retry = .{ .max_attempts = 3, .default_backoff_secs = 15, .max_backoff_secs = 30 };
    try t.expectEqual(@as(?u32, 2), r.next(1, 2));
    try t.expectEqual(@as(?u32, 15), r.next(2, null));
    try t.expectEqual(@as(?u32, null), r.next(3, 2));
    try t.expectEqual(@as(?u32, null), r.next(1, 45));
    try t.expectEqual(@as(?u32, 2), parseRetryAfter(" 2 "));
    try t.expectEqual(@as(?u32, null), parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"));
}
