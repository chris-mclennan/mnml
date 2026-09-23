//! The statusline poller: an integration's counts stay live without its
//! pane ever being opened.
//!
//! A manifest's `values_sources` entry says how to ask an integration
//! for its numbers (`mnml-bitbucket --values`) and how often
//! (`poll_interval_secs`, 300 by default). Until now nothing ran it —
//! the `󰌃 N` and PR-count chips moved only while a pane was open, or
//! when the user ran the manifest's refresh command by hand, so the
//! statusline told you what was true whenever you last looked.
//!
//! The mechanism is the one the SDK already talks. The host runs
//! `<binary> --values --workspace <ws>` as a child; the child computes
//! its numbers and publishes its own `statusline-set-segment` over the
//! Tier-2 file channel, which the host reads like any other. The host
//! parses nothing and knows nothing about a chip's shape — the manifest
//! opting in is the whole contract, exactly as the Rust host's
//! `[[values_sources]]` workers were.
//!
//! What the poller is careful about, because the thing on the other end
//! is a rate-limited API and the user's own budget:
//!
//!   * **One worker per source, serial.** A run never overlaps the
//!     previous run of the same source: the worker is a loop, so there
//!     is nothing to overlap with.
//!   * **Staggered.** Two seconds per source at startup, capped at
//!     thirty, and the offset survives for every later cycle — four
//!     integrations never fire on the same second.
//!   * **Backed off.** A non-zero exit doubles the wait, up to eight
//!     intervals. A wrong token should cost one request every forty
//!     minutes, not one every five.
//!   * **Quiet while a pane is open.** That pane is already publishing
//!     the same segment on its own refresh, so a poll would be a second
//!     request for the same answer.
//!   * **Through the shared bucket.** Not the host's doing — each
//!     integration's `--values` takes a token from
//!     `mnml_sdk.ratelimit`'s file, which is the same bucket its panes
//!     and every other process on the machine draw on.
//!
//! A run in flight paints a muted `⟳` on the integration's segment
//! (`statusline.zig`), so a chip that has gone quiet is visibly being
//! asked rather than simply stale. `integrations.poll_now` and the
//! segment's right-click "Refresh now" both wake every worker at once.
//!
//! Cancellation: `App.deinit` and every rescan cancel the group, which
//! interrupts the sleep the worker spends nearly all its life in, and
//! `cancel` does not return until every worker has — which is why the
//! jobs are only freed after it. A child that is mid-run is killed by
//! its pid, taken before the wait: a cancelled `Child.wait` clears
//! `child.id` WITHOUT killing anything, so the `child.kill` that looks
//! like it covers that path sees a null id and does nothing. Nothing
//! this starts outlives the app; the test at the bottom holds that.
//!
//! A test App starts no workers — `native_notify` is off — so nothing
//! spawns children on a timer by accident. The corpus opts in with
//! `MNML_INTEGRATION_POLL=1`, because the one thing worth proving about
//! a poller is that the chip moves with no pane open, and only a real
//! run proves it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const child_os = @import("../core/child.zig");
const integrations = @import("integrations.zig");
const mount_pane = @import("mount_pane.zig");
const broker_app = @import("broker.zig");
const jobs = @import("jobs.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const sdk_chrome = @import("mnml_sdk").pane.chrome;

/// The floor a manifest's interval is clamped to, whatever the config
/// says: polling an API faster than this buys a statusline nothing.
pub const min_interval_floor_secs: u32 = 30;
/// The ceiling. An hour-stale chip is worse than no chip.
pub const max_interval_secs: u32 = 3600;
/// A manifest that names no interval.
pub const default_interval_secs: u32 = 300;
/// Seconds of stagger per source, and the cap on it.
pub const stagger_step_secs: u32 = 2;
pub const stagger_max_secs: u32 = 30;
/// The most workers across every installed integration. Per-source
/// pacing bounds frequency, not fleet size.
pub const max_jobs: usize = 32;
/// The wait after a failure is the interval times two per consecutive
/// failure, up to this multiple.
pub const max_backoff_multiple: u32 = 8;
/// The worker wakes this often to notice a `poll_now` or a pane
/// opening; the sleep is cancelable, so this is not what shutdown
/// waits on.
pub const slice_ms: u32 = 500;
/// The glyph a run in flight puts on its segment.
pub const busy_glyph = "⟳";
pub const busy_glyph_ascii = "*";

/// What one worker and the UI thread pass between them. Every field is
/// an atomic: the worker never allocates and never takes a lock, which
/// is what lets it run on whatever task the group put it on.
pub const Shared = struct {
    /// A pane of this integration is open — skip the cycle.
    paused: std.atomic.Value(bool) = .init(false),
    /// Set by `poll_now`; the worker takes it and runs at once.
    run_now: std.atomic.Value(bool) = .init(false),
    /// A child is running: the `⟳`.
    in_flight: std.atomic.Value(bool) = .init(false),
    /// Unix seconds of the last completed run; 0 = never.
    last_run_secs: std.atomic.Value(i64) = .init(0),
    /// The last run's exit code, or -1 when it could not be spawned.
    last_exit: std.atomic.Value(i32) = .init(0),
    /// Consecutive failures — the backoff multiplier.
    failures: std.atomic.Value(u32) = .init(0),
    /// Completed runs, for the diagnostics and the tests.
    runs: std.atomic.Value(u32) = .init(0),
    /// Cycles skipped because a pane was open.
    skipped: std.atomic.Value(u32) = .init(0),
};

/// One `values_sources` entry, resolved. Owned by the state's gpa and
/// never moved: the worker holds a pointer.
pub const Job = struct {
    /// The manifest's id — what a segment id is prefixed with, and what
    /// an open pane is matched against.
    integration_id: []u8,
    /// The source's id, for the diagnostics.
    source_id: []u8,
    /// The child's argv, fully resolved. Owned, and so is each entry.
    argv: [][]u8,
    /// `--prefetch` after the values run, when the source asks for it.
    prefetch_argv: ?[][]u8 = null,
    cwd: []u8,
    /// The child's whole environment, built once: `MNML_IPC_DIR` (the
    /// channel it publishes its segment on), `MNML_DATA_ROOT`, the
    /// manifest's `MNML_SETTING_<KEY>` rows. Owned.
    env: std.process.Environ.Map,
    interval_secs: u32,
    stagger_secs: u32,
    /// The JOBS list's key for this source's runs (its build index).
    job_key: u64 = 0,
    shared: Shared = .{},

    fn deinit(self: *Job, gpa: Allocator) void {
        gpa.free(self.integration_id);
        gpa.free(self.source_id);
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        if (self.prefetch_argv) |pa| {
            for (pa) |a| gpa.free(a);
            gpa.free(pa);
        }
        gpa.free(self.cwd);
        self.env.deinit();
    }
};

pub const State = struct {
    group: Io.Group = .init,
    /// Stable addresses: a worker holds `*Job`.
    jobs: std.ArrayListUnmanaged(*Job) = .empty,
    /// The workers are running. False after `stop`.
    running: bool = false,

    /// Cancel every worker, then free what they pointed at. In that
    /// order: a job freed under a live worker is a use-after-free, and
    /// `cancel` does not return until every task has.
    pub fn stop(self: *State, gpa: Allocator, io: Io) void {
        if (self.running) self.group.cancel(io);
        self.running = false;
        for (self.jobs.items) |j| {
            j.deinit(gpa);
            gpa.destroy(j);
        }
        self.jobs.clearRetainingCapacity();
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.stop(gpa, io);
        self.jobs.deinit(gpa);
    }

    /// The job whose integration owns `segment_id` (`<id>.<segment>`),
    /// or null.
    pub fn jobForSegment(self: *const State, segment_id: []const u8) ?*Job {
        for (self.jobs.items) |j| {
            if (segment_id.len > j.integration_id.len and
                std.mem.startsWith(u8, segment_id, j.integration_id) and
                segment_id[j.integration_id.len] == '.') return j;
        }
        return null;
    }

    /// Whether a run is in flight for whatever integration owns
    /// `segment_id` — what puts the `⟳` on the chip.
    pub fn segmentBusy(self: *const State, segment_id: []const u8) bool {
        const j = self.jobForSegment(segment_id) orelse return false;
        return j.shared.in_flight.load(.acquire);
    }
};

/// A manifest's interval, clamped by the config's floor and the
/// module's own bounds. `min_interval_secs` is the user's say in how
/// hard their own API budget may be spent; neither side may go below
/// `min_interval_floor_secs`.
pub fn clampInterval(declared: u32, config_min: u32) u32 {
    const want = if (declared == 0) default_interval_secs else declared;
    const floor = @max(config_min, min_interval_floor_secs);
    return std.math.clamp(want, floor, max_interval_secs);
}

/// The stagger for the nth source.
pub fn staggerFor(index: usize) u32 {
    const raw = @as(u32, @intCast(@min(index, 1000))) * stagger_step_secs;
    return @min(raw, stagger_max_secs);
}

/// The wait after `failures` consecutive failures, in seconds.
pub fn backoffSecs(interval_secs: u32, failures: u32) u32 {
    if (failures == 0) return interval_secs;
    const shift: u5 = @intCast(@min(failures, 3));
    const mult = @min(@as(u32, 1) << shift, max_backoff_multiple);
    return @min(interval_secs *| mult, max_interval_secs);
}

// ─── the schedule ────────────────────────────────────────────────────────

/// Rebuild the job list from the scanned manifests and start a worker
/// per job. Called after every `integrations.refresh`, so an install,
/// an uninstall or a disable takes effect without a restart.
pub fn restart(app: *App) Allocator.Error!void {
    const st = &app.integration_poll;
    st.stop(app.gpa, app.io);
    if (!app.cfg.integrations.poll.enabled) return;
    try build(app);
    // A test App does not spawn children on a timer by accident. The
    // corpus opts in with `MNML_INTEGRATION_POLL=1`, because the one
    // thing worth proving about a poller is that the chip moves with no
    // pane open, and only a real run proves that.
    if (app.native_notify or optedIn(app)) start(app);
}

fn optedIn(app: *const App) bool {
    const v = app.env.get("MNML_INTEGRATION_POLL") orelse return false;
    return v.len > 0 and v[0] != '0';
}

/// The jobs the current manifests ask for. Public so a test can build
/// the schedule without starting a worker.
pub fn build(app: *App) Allocator.Error!void {
    const st = &app.integration_poll;
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (app.integrations.list) |*inst| {
        if (!inst.enabled() or !inst.binary_found) continue;
        for (inst.manifest.values_sources) |src| {
            if (st.jobs.items.len >= max_jobs) return;
            const job = buildJob(app, a, inst, src, st.jobs.items.len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoBinary => continue,
            };
            try st.jobs.append(gpa, job);
        }
    }
}

const BuildError = Allocator.Error || error{NoBinary};

/// One source's job: the binary the command names (falling back to the
/// manifest's own, so a dev manifest pointing at `$VAR` works), the
/// command's remaining words, `--workspace <ws>` when it does not
/// already carry one, and a child environment carrying the same
/// `MNML_SETTING_<KEY>` / `MNML_IPC_DIR` a pane would get — the child
/// publishes its segment on that channel.
fn buildJob(
    app: *App,
    arena: Allocator,
    inst: *const integrations.Installed,
    src: manifest_mod.manifest.ValuesSource,
    index: usize,
) BuildError!*Job {
    const gpa = app.gpa;
    var words: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, src.command, " \t");
    while (it.next()) |w| try words.append(arena, w);
    if (words.items.len == 0) return error.NoBinary;
    const named = integrations.resolveBinary(app, arena, words.items[0]) orelse
        integrations.resolveBinary(app, arena, inst.manifest.binary) orelse
        return error.NoBinary;

    var argv: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer for (argv.items) |a| gpa.free(a);
    try argv.append(gpa, try gpa.dupe(u8, named));
    var has_workspace = false;
    for (words.items[1..]) |w| {
        if (std.mem.eql(u8, w, "--workspace")) has_workspace = true;
        try argv.append(gpa, try gpa.dupe(u8, w));
    }
    if (!has_workspace and app.workspace.len > 0) {
        try argv.append(gpa, try gpa.dupe(u8, "--workspace"));
        try argv.append(gpa, try gpa.dupe(u8, app.workspace));
    }

    // `--prefetch` is the whole-pane warm, many requests where `--values`
    // is one. Only a manifest that asks for it by name gets it, and only
    // after a values run that succeeded.
    var prefetch: ?[][]u8 = null;
    errdefer if (prefetch) |pa| {
        for (pa) |a| gpa.free(a);
        gpa.free(pa);
    };
    if (src.prefetch) {
        var pa: std.ArrayListUnmanaged([]u8) = .empty;
        for (argv.items) |a| {
            if (std.mem.eql(u8, a, "--values")) {
                try pa.append(gpa, try gpa.dupe(u8, "--prefetch"));
            } else try pa.append(gpa, try gpa.dupe(u8, a));
        }
        prefetch = try pa.toOwnedSlice(gpa);
    }

    var env = try app.env.clone(gpa);
    errdefer env.deinit();
    try env.put("MNML_WORKSPACE", app.workspace);
    try env.put("MNML_IPC_DIR", try mount_pane.ipcDir(app));
    try env.put("MNML_THEME", app.theme.name);
    // The chip this child publishes is painted on the same statusline
    // the pane's is, so it has to choose the same glyph twin. A pane
    // reads `ui.ascii_icons` off its `hello`; a `--values` child has no
    // mount, so the environment carries it (`sdk.pane.asciiFromEnv`).
    try env.put(sdk_chrome.ascii_env, if (app.cfg.ui.ascii_icons) "1" else "0");
    if (app.data_root.len > 0) try env.put("MNML_DATA_ROOT", app.data_root);
    // The poller's child writes to the same request log a pane does:
    // a `poll` line beside a `pane_open` one is half the point of the
    // log, since they draw on one bucket.
    const rl = app.cfg.integrations.request_log;
    try env.put("MNML_REQUEST_LOG", if (rl.enabled) "1" else "0");
    var mbuf: [12]u8 = undefined;
    try env.put("MNML_REQUEST_LOG_MAX_MB", std.fmt.bufPrint(&mbuf, "{d}", .{rl.max_mb}) catch "4");
    // The poller's child queues on the same brokers a pane does — in
    // the `refresh` class, since nobody is watching a `--values` run
    // but its answer is wanted soon (`warm.classOf`).
    try broker_app.putEnv(app, &env);
    for (inst.manifest.settings) |setting| {
        const name = try std.fmt.allocPrint(arena, "MNML_SETTING_{s}", .{setting.key});
        for (name["MNML_SETTING_".len..]) |*c| c.* = std.ascii.toUpper(c.*);
        try env.put(name, integrations.settingValue(app, inst.id(), setting));
    }

    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{
        .integration_id = try gpa.dupe(u8, inst.id()),
        .source_id = try gpa.dupe(u8, src.id),
        .argv = try argv.toOwnedSlice(gpa),
        .prefetch_argv = prefetch,
        // An empty workspace would be an empty `cwd` and a spawn that
        // fails for a reason no backoff can fix.
        .cwd = try gpa.dupe(u8, if (app.workspace.len > 0) app.workspace else "."),
        .env = env,
        .interval_secs = clampInterval(src.poll_interval_secs, app.cfg.integrations.poll.min_interval_secs),
        .stagger_secs = staggerFor(index),
        .job_key = index,
    };
    return job;
}

// ─── the worker ──────────────────────────────────────────────────────────

fn start(app: *App) void {
    const st = &app.integration_poll;
    if (st.jobs.items.len == 0) return;
    for (st.jobs.items) |j| {
        st.group.concurrent(app.io, worker, .{ j, &app.events, app.io }) catch continue;
    }
    st.running = true;
}

/// One source, forever: wait out its stagger, then run, wait, run.
/// `error.Canceled` is propagated rather than swallowed — a task that
/// eats it never leaves the group and `cancel` never returns.
fn worker(job: *Job, events: *event.EventQueue, io: Io) Io.Cancelable!void {
    try waitSecs(job, io, job.stagger_secs);
    var next_wait = job.interval_secs;
    while (true) {
        if (job.shared.paused.load(.acquire) and !job.shared.run_now.load(.acquire)) {
            // A pane of this integration is open and already publishing
            // the same segment. Skip the cycle, do not count it as a
            // failure, and look again after one interval.
            _ = job.shared.skipped.fetchAdd(1, .monotonic);
        } else {
            _ = job.shared.run_now.swap(false, .acq_rel);
            job.shared.in_flight.store(true, .release);
            events.post(io, .timer);
            // A run is a background job: the worker says so itself, the
            // UI thread keeps the list (`jobs.post`).
            var label_buf: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s} --values ({s})", .{ job.integration_id, job.source_id }) catch job.integration_id;
            jobs.post(events, io, events.gpa, .integration, job.job_key, .running, label);
            const code = runOnce(job, io) catch |err| switch (err) {
                error.Canceled => {
                    job.shared.in_flight.store(false, .release);
                    jobs.post(events, io, events.gpa, .integration, job.job_key, .cancelled, null);
                    return error.Canceled;
                },
            };
            var words_buf: [48]u8 = undefined;
            const words: []const u8 = if (code == 0) "published" else if (code < 0) "could not start it" else std.fmt.bufPrint(&words_buf, "exit {d} — backing off", .{code}) catch "failed";
            jobs.post(events, io, events.gpa, .integration, job.job_key, if (code == 0) .ok else .failed, words);
            job.shared.in_flight.store(false, .release);
            job.shared.last_exit.store(code, .monotonic);
            job.shared.last_run_secs.store(Io.Timestamp.now(io, .real).toSeconds(), .monotonic);
            _ = job.shared.runs.fetchAdd(1, .monotonic);
            const failures = if (code == 0) blk: {
                job.shared.failures.store(0, .monotonic);
                break :blk 0;
            } else job.shared.failures.fetchAdd(1, .monotonic) + 1;
            next_wait = backoffSecs(job.interval_secs, failures);
            events.post(io, .timer);
        }
        try waitSecs(job, io, next_wait);
        next_wait = job.interval_secs;
    }
}

/// Sleep in slices so a `poll_now` is noticed promptly. The slices are
/// not what makes shutdown prompt — `io.sleep` is cancelable — they are
/// what makes "refresh now" feel like now.
fn waitSecs(job: *Job, io: Io, secs: u32) Io.Cancelable!void {
    var left_ms: u64 = @as(u64, secs) * 1000;
    while (left_ms > 0) {
        if (job.shared.run_now.load(.acquire)) return;
        const step: u64 = @min(left_ms, slice_ms);
        try io.sleep(.fromMilliseconds(@intCast(step)), .awake);
        left_ms -= step;
    }
}

/// The child, and its exit code. -1 when it could not be spawned at
/// all, which is a failure like any other for the backoff.
fn runOnce(job: *Job, io: Io) Io.Cancelable!i32 {
    const code = try spawnAndWait(io, job.argv, job.cwd, &job.env);
    if (job.prefetch_argv) |pa| {
        if (code == 0) _ = try spawnAndWait(io, pa, job.cwd, &job.env);
    }
    return code;
}

fn spawnAndWait(io: Io, argv: []const []u8, cwd: []const u8, env: *const std.process.Environ.Map) Io.Cancelable!i32 {
    // The argv is `[][]u8` because the job owns it; the spawn wants
    // `[]const []const u8`.
    var stack: [16][]const u8 = undefined;
    if (argv.len == 0 or argv.len > stack.len) return -1;
    for (argv, 0..) |a, i| stack[i] = a;
    var child = std.process.spawn(io, .{
        .argv = stack[0..argv.len],
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return -1,
    };
    // Whatever happens next — a normal exit, a cancel mid-wait — the
    // child does not outlive this function. That is the whole of "no
    // orphan pollers", and it does not come for free: a cancelled
    // `wait` clears `child.id` WITHOUT killing anything, so the
    // `child.kill` that looks like it covers this path sees a null id
    // and returns having done nothing. The pid is taken first and the
    // signal sent to it directly.
    const pid = child.id;
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => {
            child_os.reapAbandoned(pid);
            return error.Canceled;
        },
        else => {
            child_os.reapAbandoned(pid);
            return -1;
        },
    };
    return switch (term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
}

// ─── the tick ────────────────────────────────────────────────────────────

/// Once per frame: tell each worker whether a pane of its integration
/// is open. The worker never reads `App`, so this is the only way it
/// learns.
pub fn tick(app: *App) void {
    const st = &app.integration_poll;
    for (st.jobs.items) |j| {
        j.shared.paused.store(paneOpenFor(app, j.integration_id), .release);
    }
}

/// The rule one mount pane is judged by: it belongs to this
/// integration, and it is still alive. A pane showing an exit banner
/// publishes nothing, so it is no reason to skip a poll.
pub fn paneCounts(owner: ?[]const u8, alive: bool, integration_id: []const u8) bool {
    if (!alive) return false;
    const o = owner orelse return false;
    return std.mem.eql(u8, o, integration_id);
}

/// Whether any live mount pane belongs to `integration_id`.
pub fn paneOpenFor(app: *const App, integration_id: []const u8) bool {
    for (app.panes.slots.items) |*slot| {
        const p = if (slot.*) |*x| x else continue;
        switch (p.*) {
            .mount => |*m| if (paneCounts(m.integration, m.alive(), integration_id)) return true,
            else => {},
        }
    }
    return false;
}

// ─── the command ─────────────────────────────────────────────────────────

/// `integrations.poll_now`: wake every worker. Also what the segment's
/// right-click "Refresh now" runs.
pub fn pollNow(app: *App) CommandError!void {
    const st = &app.integration_poll;
    if (st.jobs.items.len == 0) {
        app.toast("integrations: nothing declares a values source to poll", .{});
        return;
    }
    for (st.jobs.items) |j| j.shared.run_now.store(true, .release);
    app.toast("integrations: refreshing {d} source{s}", .{ st.jobs.items.len, if (st.jobs.items.len == 1) "" else "s" });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the interval is the manifest's, clamped by the config's floor and the module's bounds" {
    // A manifest that names none takes the default.
    try testing.expectEqual(@as(u32, 300), clampInterval(0, 60));
    // The manifest's own number stands when it is inside both bounds.
    try testing.expectEqual(@as(u32, 120), clampInterval(120, 60));
    // The user's floor lifts a manifest that asks for more than they
    // want to spend…
    try testing.expectEqual(@as(u32, 600), clampInterval(30, 600));
    // …and the module's own floor lifts a config that asks for less
    // than a statusline can use.
    try testing.expectEqual(@as(u32, 30), clampInterval(1, 0));
    try testing.expectEqual(@as(u32, 30), clampInterval(5, 5));
    // The ceiling holds: an hour-stale chip is worse than no chip.
    try testing.expectEqual(@as(u32, 3600), clampInterval(99_999, 60));
}

test "the stagger offsets each source and stops at its cap; the backoff doubles to eight intervals" {
    try testing.expectEqual(@as(u32, 0), staggerFor(0));
    try testing.expectEqual(@as(u32, 2), staggerFor(1));
    try testing.expectEqual(@as(u32, 6), staggerFor(3));
    // Past the cap every later source starts together, which is fine —
    // their intervals still differ and nothing fans out at once.
    try testing.expectEqual(@as(u32, 30), staggerFor(15));
    try testing.expectEqual(@as(u32, 30), staggerFor(400));

    try testing.expectEqual(@as(u32, 300), backoffSecs(300, 0));
    try testing.expectEqual(@as(u32, 600), backoffSecs(300, 1));
    try testing.expectEqual(@as(u32, 1200), backoffSecs(300, 2));
    // Three strikes is already the ceiling multiple; it does not keep
    // doubling past it.
    try testing.expectEqual(@as(u32, 2400), backoffSecs(300, 3));
    try testing.expectEqual(@as(u32, 2400), backoffSecs(300, 9));
    // And never past an hour.
    try testing.expectEqual(@as(u32, 3600), backoffSecs(3000, 4));
}

test "a segment belongs to the integration its id is prefixed with, and only to that one" {
    var st: State = .{};
    defer st.deinit(testing.allocator, testing.io);
    var job: Job = .{
        .integration_id = try testing.allocator.dupe(u8, "bitbucket_prs"),
        .source_id = try testing.allocator.dupe(u8, "bitbucket_values"),
        .argv = &.{},
        .cwd = try testing.allocator.dupe(u8, ""),
        .env = std.process.Environ.Map.init(testing.allocator),
        .interval_secs = 300,
        .stagger_secs = 0,
    };
    const owned = try testing.allocator.create(Job);
    owned.* = job;
    job = undefined;
    try st.jobs.append(testing.allocator, owned);

    try testing.expect(st.jobForSegment("bitbucket_prs.prs_mine") != null);
    // Not a prefix match on the bare name, and not a different chip.
    try testing.expect(st.jobForSegment("bitbucket_prs") == null);
    try testing.expect(st.jobForSegment("bitbucket_prs_other.chip") == null);
    try testing.expect(st.jobForSegment("jira_work.assigned") == null);

    // The `⟳` follows the job's own in-flight flag.
    try testing.expect(!st.segmentBusy("bitbucket_prs.prs_mine"));
    owned.shared.in_flight.store(true, .release);
    try testing.expect(st.segmentBusy("bitbucket_prs.prs_mine"));
    try testing.expect(!st.segmentBusy("jira_work.assigned"));
}

const manifest_with_source =
    \\.{
    \\    .id = "acme_prs",
    \\    .label = "Acme PRs",
    \\    .binary = "$ACME_BIN",
    \\    .statusline = .{ .{ .id = "prs", .text = "A …", .click_command = "acme_prs.open" } },
    \\    .commands = .{.{ .id = "acme_prs.open", .title = "Acme PRs: open" }},
    \\    .values_sources = .{.{ .id = "acme_values", .command = "mnml-acme --values --only prs", .poll_interval_secs = 120 }},
    \\}
;

test "the schedule is one job per values source: the manifest's own binary, its words, and the workspace appended" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/acme.zon", .data = manifest_with_source });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mnml-acme", .data = "#!/bin/sh\n" });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const bin = try std.fs.path.join(testing.allocator, &.{ root, "mnml-acme" });
    defer testing.allocator.free(bin);
    try env.put("ACME_BIN", bin);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24, .env = &env });
    defer app.deinit();
    try integrations.refresh(&app);
    try testing.expect(app.integrations.list[0].binary_found);

    // `integrations.refresh` builds the schedule; what it does not do in
    // a test App is start the workers (`native_notify` is off and the
    // corpus's opt-in is not set), so the jobs can be inspected at rest.
    const st = &app.integration_poll;
    try testing.expect(!st.running);
    try testing.expectEqual(@as(usize, 1), st.jobs.items.len);
    const job = st.jobs.items[0];
    try testing.expectEqualStrings("acme_prs", job.integration_id);
    try testing.expectEqualStrings("acme_values", job.source_id);
    // The command's first word is resolved to a real path; the rest of
    // its words survive in order; the workspace is appended, because a
    // child publishes its segment on that workspace's channel.
    try testing.expectEqual(@as(usize, 6), job.argv.len);
    try testing.expectEqualStrings(bin, job.argv[0]);
    try testing.expectEqualStrings("--values", job.argv[1]);
    try testing.expectEqualStrings("--only", job.argv[2]);
    try testing.expectEqualStrings("prs", job.argv[3]);
    try testing.expectEqualStrings("--workspace", job.argv[4]);
    try testing.expectEqualStrings(root, job.argv[5]);
    // The manifest asked for 120 s and the config's floor is 60.
    try testing.expectEqual(@as(u32, 120), job.interval_secs);
    // No `--prefetch` unless the source asks by name.
    try testing.expect(job.prefetch_argv == null);
    // The child is told where the channel is.
    try testing.expect(job.env.get("MNML_IPC_DIR") != null);
    // The segment the manifest declares is this job's.
    try testing.expect(st.jobForSegment("acme_prs.prs") != null);

    // A disabled chip is not polled: the whole point of disabling one
    // is that it stops costing requests.
    st.stop(app.gpa, app.io);
    app.integrations.list[0].manifest.chip = .{ .enabled = false };
    try build(&app);
    try testing.expectEqual(@as(usize, 0), st.jobs.items.len);
    app.integrations.list[0].manifest.chip = null;

    // Nor is one whose binary cannot be found.
    st.stop(app.gpa, app.io);
    app.integrations.list[0].binary_found = false;
    try build(&app);
    try testing.expectEqual(@as(usize, 0), st.jobs.items.len);
}

test "poll_now wakes every worker; with nothing to poll it says so instead of pretending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    try pollNow(&app);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "nothing declares a values source") != null);

    const owned = try testing.allocator.create(Job);
    owned.* = .{
        .integration_id = try testing.allocator.dupe(u8, "acme_prs"),
        .source_id = try testing.allocator.dupe(u8, "acme_values"),
        .argv = &.{},
        .cwd = try testing.allocator.dupe(u8, root),
        .env = std.process.Environ.Map.init(testing.allocator),
        .interval_secs = 300,
        .stagger_secs = 0,
    };
    try app.integration_poll.jobs.append(app.gpa, owned);
    try testing.expect(!owned.shared.run_now.load(.acquire));
    try pollNow(&app);
    try testing.expect(owned.shared.run_now.load(.acquire));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "refreshing 1 source") != null);
}

test "a pane of an integration pauses its poll, and only its own" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    const owned = try testing.allocator.create(Job);
    owned.* = .{
        .integration_id = try testing.allocator.dupe(u8, "acme_prs"),
        .source_id = try testing.allocator.dupe(u8, "acme_values"),
        .argv = &.{},
        .cwd = try testing.allocator.dupe(u8, root),
        .env = std.process.Environ.Map.init(testing.allocator),
        .interval_secs = 300,
        .stagger_secs = 0,
    };
    try app.integration_poll.jobs.append(app.gpa, owned);

    tick(&app);
    try testing.expect(!owned.shared.paused.load(.acquire));

    // A live mount pane of a *different* integration changes nothing.
    _ = try app.panes.add(.{ .mount = .{
        .gpa = app.gpa,
        .mount = null,
        .label = try app.gpa.dupe(u8, "other"),
        .integration = try app.gpa.dupe(u8, "jira_work"),
        .generation = 1,
        .exit = try app.gpa.dupe(u8, "gone"),
    } });
    tick(&app);
    try testing.expect(!owned.shared.paused.load(.acquire));

    // …and neither does a pane of this one that has exited: it is
    // showing a banner, not publishing a segment.
    _ = try app.panes.add(.{ .mount = .{
        .gpa = app.gpa,
        .mount = null,
        .label = try app.gpa.dupe(u8, "acme"),
        .integration = try app.gpa.dupe(u8, "acme_prs"),
        .generation = 2,
        .exit = try app.gpa.dupe(u8, "gone"),
    } });
    tick(&app);
    try testing.expect(!owned.shared.paused.load(.acquire));

    // The rule a live pane is judged by — the half `paneOpenFor` walks
    // to, which a test cannot reach without a real mount socket.
    try testing.expect(paneCounts("acme_prs", true, "acme_prs"));
    try testing.expect(!paneCounts("acme_prs", false, "acme_prs"));
    try testing.expect(!paneCounts("jira_work", true, "acme_prs"));
    try testing.expect(!paneCounts(null, true, "acme_prs"));
}

test "stopping the poller cancels the worker and reaps its child: nothing outlives the app" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 24 });
    defer app.deinit();

    // A child that would outlive the app by five minutes if nothing
    // killed it, writing its pid where the test can find it.
    const pid_path = try std.fs.path.join(testing.allocator, &.{ root, "child.pid" });
    defer testing.allocator.free(pid_path);
    const script = try std.fmt.allocPrint(testing.allocator, "echo $$ > {s}; exec sleep 300", .{pid_path});
    defer testing.allocator.free(script);
    var argv = try testing.allocator.alloc([]u8, 3);
    argv[0] = try testing.allocator.dupe(u8, "/bin/sh");
    argv[1] = try testing.allocator.dupe(u8, "-c");
    argv[2] = try testing.allocator.dupe(u8, script);
    const job = try testing.allocator.create(Job);
    job.* = .{
        .integration_id = try testing.allocator.dupe(u8, "slow"),
        .source_id = try testing.allocator.dupe(u8, "slow_values"),
        .argv = argv,
        .cwd = try testing.allocator.dupe(u8, root),
        .env = std.process.Environ.Map.init(testing.allocator),
        .interval_secs = 300,
        .stagger_secs = 0,
    };
    try app.integration_poll.jobs.append(app.gpa, job);
    start(&app);
    try testing.expect(app.integration_poll.running);

    // Wait for the child to be up — the run is in flight and the pid
    // file is there.
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (job.shared.in_flight.load(.acquire)) {
            if (tmp.dir.access(testing.io, "child.pid", .{})) |_| break else |_| {}
        }
        testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    try testing.expect(job.shared.in_flight.load(.acquire));
    var pid_buf: [32]u8 = undefined;
    const pid_text = try tmp.dir.readFile(testing.io, "child.pid", &pid_buf);
    const pid = try std.fmt.parseInt(i32, std.mem.trim(u8, pid_text, " \n\r\t"), 10);
    try testing.expect(processAlive(pid));

    // `stop` cancels the group and does not return until the worker
    // has — and the worker kills its child on the way out.
    app.integration_poll.stop(app.gpa, app.io);
    try testing.expect(!app.integration_poll.running);
    try testing.expectEqual(@as(usize, 0), app.integration_poll.jobs.items.len);
    // `stop` returns after the worker has, and the worker after the
    // reap, so `gone` holds at once; the deadline is what a wrong answer
    // costs. The one this test gave under load — "still there" a full
    // ten seconds after the kill — was a zombie: the cancel's SIGIO had
    // landed in the reap's `waitpid` (`core/child.zig`, `reap`).
    try testing.expect(child_os.goneWithin(testing.io, pid, .fromSeconds(10)));
}

/// Whether that process is still there. A child the worker failed to
/// kill would answer yes, which is exactly what this is looking for.
fn processAlive(pid: i32) bool {
    return !child_os.gone(pid);
}
