//! The API TRAFFIC pane (`Pane.api_traffic`, `view.api_traffic`): who
//! is spending an API's budget right now — mnml's panes, the statusline
//! poller, the fleet's loops, a script — read out of the shared files
//! every process on the machine writes (`api_traffic_reader.zig`).
//!
//! One pane, a tab per service that has files. Three sections, all off
//! one prepared `Snapshot`:
//!
//!   * **Now** — the bucket's tokens, rate and cooldown, the last 429,
//!     this hour against the hourly limit, mnml's day tally, the broker,
//!     the integration's event feed, the shared HTTP cache.
//!   * **Timeline** — requests a minute over 1h / 24h / 7d, stacked by
//!     program, the hourly limit drawn across it.
//!   * **Who** — one row per program: requests, share, top reason,
//!     worst wait, last seen, and its pids.
//!
//! The integration's own chip hover stays the short summary; this is
//! the long one, and it is the host's, because the question it answers
//! is about every process, not one pane.
//!
//!   D1  the worker reads; the paint loop never does. A look runs on the
//!       dashboard cadence (`refresh_cadence`, `ui.dashboard_refresh`):
//!       fast while the pane is on screen and something drew in the last
//!       minute, slow while it is on screen and quiet, never while it is
//!       not. The worker owns the `Job` (the reader, its offsets and
//!       its window) while it runs; the main thread touches it only when
//!       no worker is out.
//!   D2  the worker's `*Result` rides `AppEvent.api_traffic`; the pane
//!       keeps the newest and destroys the one it replaces. Every string
//!       the view, a hover or a menu shows lives on that result's arena;
//!       a menu dupes what it needs into its own `mem`, because the next
//!       result can land while the menu is open.
//!   D3  the `Io.Group` and the `Job` are heap-allocated: a pane lives
//!       in `PaneStore.slots`, which moves when any pane opens, and a
//!       group with a task in it must not move (`spend.zig`'s note).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const event = @import("../core/event.zig");
const reader = @import("api_traffic_reader.zig");
const refresh_cadence = @import("refresh_cadence.zig");
const broker_app = @import("broker.zig");
const context_menus = @import("context_menus.zig");
const config = @import("../config/Config.zig");
const sdk = @import("mnml_sdk");

pub const Window = reader.Window;
pub const ServiceSnap = reader.ServiceSnap;

pub const table = .{
    .@"view.api_traffic" = &showCmd,
    .@"view.api_traffic_throttled" = &throttledCmd,
    .@"view.api_traffic_window_hour" = &windowCmd(.hour),
    .@"view.api_traffic_window_day" = &windowCmd(.day),
    .@"view.api_traffic_window_week" = &windowCmd(.week),
};

/// The pane's own cadence: two seconds while on screen with a draw in
/// the last minute, five while on screen and quiet, nothing while it is
/// not on screen — reopening it reads at once. `ui.dashboard_refresh`
/// pins or stops it the way it does every dashboard.
pub const cadence: refresh_cadence.Cadence = .{ .fast_ms = 2000, .slow_ms = 5000, .idle_ms = 0 };

/// The services mnml fronts come first, in this order.
pub const known = broker_app.services;

// ─── the hit ids (`.script_hit{ pane, id }`) ────────────────────────────

pub const hit_title: u32 = 0x01;
pub const hit_tab_base: u32 = 0x10;
pub const max_tabs: u32 = 0x20;
pub const hit_now_base: u32 = 0x40;
pub const hit_legend_base: u32 = 0x60;
pub const hit_limit: u32 = 0x70;
pub const hit_who_head_base: u32 = 0x80;
pub const hit_section_base: u32 = 0x90;
/// One per bucket row of NOW (`reader.max_buckets`), the shared one
/// first.
pub const hit_bucket_base: u32 = 0xA0;
/// The window chip and the refresh chip are the header's own
/// (`ListHit.chip(.sort)` / `.refresh`, 0x100…).
pub const hit_row_base: u32 = 0x1000;
pub const hit_col_base: u32 = 0x4000;

/// The Now rows, in paint order.
pub const NowRow = enum(u8) { bucket, hour, broker, feed, cache, throttles };

/// The Who columns, in paint order.
pub const WhoCol = enum(u8) { program, requests, share, reason, wait, seen, pids };

pub const Section = enum(u8) { now, timeline, who };

pub fn nowRowOf(id: u32) ?NowRow {
    if (id < hit_now_base or id >= hit_now_base + @typeInfo(NowRow).@"enum".fields.len) return null;
    return @enumFromInt(id - hit_now_base);
}

pub fn whoColOf(id: u32) ?WhoCol {
    if (id < hit_who_head_base or id >= hit_who_head_base + @typeInfo(WhoCol).@"enum".fields.len) return null;
    return @enumFromInt(id - hit_who_head_base);
}

pub fn bucketRowOf(id: u32) ?usize {
    if (id < hit_bucket_base or id >= hit_bucket_base + reader.max_buckets) return null;
    return id - hit_bucket_base;
}

pub fn sectionOf(id: u32) ?Section {
    if (id < hit_section_base or id >= hit_section_base + @typeInfo(Section).@"enum".fields.len) return null;
    return @enumFromInt(id - hit_section_base);
}

// ─── what the worker hands back ─────────────────────────────────────────

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    services: []ServiceSnap = &.{},
    /// When it was read, epoch seconds.
    now: f64 = 0,
    /// Seconds east of UTC at `now`, for the minute labels.
    tz_offset: i64 = 0,
    generation: u32,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn find(self: *const Result, service: []const u8) ?*const ServiceSnap {
        for (self.services) |*s| if (std.mem.eql(u8, s.service, service)) return s;
        return null;
    }
};

/// What a worker reads with. The reader's offsets and window live here
/// between looks; the worker owns all of it while it runs.
pub const Job = struct {
    rd: reader.Reader = .{},
    /// A copy of the App's environment, so the worker never reads a map
    /// the main thread may be writing. Renewed on `r`.
    env: std.process.Environ.Map,
    /// Owned.
    data_root: []u8,
    workspace: []u8,

    fn deinit(j: *Job, gpa: Allocator) void {
        j.rd.deinit(gpa);
        j.env.deinit();
        gpa.free(j.data_root);
        gpa.free(j.workspace);
    }
};

/// The toast's five-minute window per service: one toast, then quiet
/// until five minutes have passed since it. Pure arithmetic, so the
/// rule is tested without a clock.
pub const Coalescer = struct {
    pub const window_secs: f64 = 300;
    pub const max_services = 8;
    slots: [max_services]Slot = @splat(.{}),

    pub const Slot = struct {
        name: [32]u8 = undefined,
        len: u8 = 0,
        last_toast: f64 = -std.math.inf(f64),

        fn service(s: *const Slot) []const u8 {
            return s.name[0..s.len];
        }
    };

    fn slot(c: *Coalescer, service: []const u8) ?*Slot {
        for (&c.slots) |*sl| if (sl.len > 0 and std.mem.eql(u8, sl.service(), service)) return sl;
        if (service.len > 32) return null;
        for (&c.slots) |*sl| if (sl.len == 0) {
            @memcpy(sl.name[0..service.len], service);
            sl.len = @intCast(service.len);
            return sl;
        };
        return null;
    }

    /// `fresh` new 429s for `service` at `now`: toast, or hold them
    /// into the toast already up. Never one toast per line.
    pub fn note(c: *Coalescer, service: []const u8, fresh: u32, now: f64) bool {
        if (fresh == 0) return false;
        const sl = c.slot(service) orelse return false;
        if (now - sl.last_toast < window_secs) return false;
        sl.last_toast = now;
        return true;
    }
};

/// The reader, its worker and the newest snapshot: the App's, not the
/// pane's, because the 429 toasts watch the files with no pane open.
pub const State = struct {
    group: ?*Io.Group = null,
    job: ?*Job = null,
    result: ?*Result = null,
    loading: bool = false,
    generation: u32 = 0,
    /// When the last look started (`app.now_ms`); 0 before the first.
    last_ms: i64 = 0,
    coalescer: Coalescer = .{},
    /// The service the newest throttle toast named, for
    /// `view.api_traffic_throttled` alone. A toast's own button carries
    /// its service (`ToastAction.api_traffic`), and a plain open never
    /// reads this.
    last_toasted: [32]u8 = undefined,
    last_toasted_len: u8 = 0,

    /// Cancel the worker before anything it holds goes.
    pub fn deinit(st: *State, gpa: Allocator, io: Io) void {
        if (st.group) |g| {
            g.cancel(io);
            gpa.destroy(g);
        }
        if (st.job) |j| {
            j.deinit(gpa);
            gpa.destroy(j);
        }
        if (st.result) |r| r.destroy(gpa);
        st.* = .{};
    }
};

pub const ApiTrafficPane = struct {
    gpa: Allocator,
    /// The App's newest snapshot (`State.result`), borrowed: the App
    /// owns it and moves this pointer with every result it adopts.
    result: ?*Result = null,
    /// A look is out and the pane has nothing yet to show.
    loading: bool = false,
    /// The tab: a service's name, owned — it survives a result that
    /// lists the services in another order.
    service: []u8 = &.{},
    window: Window = .hour,
    /// The Who row under the cursor.
    cursor: usize = 0,
    scroll: usize = 0,
    /// The timeline column the keys have picked (`[` / `]`); null shows
    /// the hovered one, or none.
    column: ?usize = null,
    /// Buckets per timeline column at the last paint — what a column's
    /// hit id (its first bucket) spans, for its hover.
    col_span: usize = 1,
    was_shown: bool = false,

    pub fn init(gpa: Allocator, window: Window) ApiTrafficPane {
        return .{ .gpa = gpa, .window = window };
    }

    pub fn deinit(self: *ApiTrafficPane, io: Io) void {
        _ = io;
        self.gpa.free(self.service);
    }

    pub fn title(self: *const ApiTrafficPane) []const u8 {
        _ = self;
        return "API traffic";
    }

    /// The tab's snapshot: the named service, else the first.
    pub fn current(self: *const ApiTrafficPane) ?*const ServiceSnap {
        const r = self.result orelse return null;
        if (r.find(self.service)) |s| return s;
        if (r.services.len > 0) return &r.services[0];
        return null;
    }

    pub fn currentWin(self: *const ApiTrafficPane) ?*const reader.WinSnap {
        const s = self.current() orelse return null;
        return s.win(self.window);
    }

    pub fn selectedWho(self: *const ApiTrafficPane) ?*const reader.WhoRow {
        const w = self.currentWin() orelse return null;
        if (self.cursor >= w.who.len) return null;
        return &w.who[self.cursor];
    }
};

// ─── open / refresh ─────────────────────────────────────────────────────

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.api_traffic);
}

pub fn windowOf(w: config.ApiTrafficWindow) Window {
    return switch (w) {
        .hour => .hour,
        .day => .day,
        .week => .week,
    };
}

/// `view.api_traffic`: the one pane, below the active pane; a refresh
/// when it is already open, on the tab it was on.
fn showCmd(app: *App) CommandError!void {
    _ = try openPane(app);
    try refresh(app);
}

/// The pane on `service`'s tab, then a read: a throttle toast's offer.
/// The same tab keeps its cursor; another starts at the top.
pub fn openOn(app: *App, service: []const u8) CommandError!void {
    const p = try openPane(app);
    if (!std.mem.eql(u8, p.service, service)) {
        try setService(p, service);
        p.cursor = 0;
        p.scroll = 0;
        p.column = null;
    }
    try refresh(app);
}

/// The one pane, made below the active pane when there is none, shown.
fn openPane(app: *App) CommandError!*ApiTrafficPane {
    const st = &app.api_traffic;
    const id = find(app) orelse blk: {
        var pane = ApiTrafficPane.init(app.gpa, windowOf(app.cfg.integrations.api_traffic_window));
        pane.result = st.result;
        pane.loading = st.result == null;
        const id = app.panes.add(.{ .api_traffic = pane }) catch |err| {
            pane.deinit(app.io);
            return err;
        };
        const layout = app.layouts.current();
        if (app.active) |cur| if (layout.leafOf(cur) != null) {
            _ = layout.split(cur, .horizontal, id) catch {};
        };
        break :blk id;
    };
    app.showPane(id);
    const p = get(app, id).?;
    if (p.service.len == 0) {
        if (st.result) |r| try pickBusiest(p, r);
    }
    return p;
}

pub fn get(app: *App, id: PaneId) ?*ApiTrafficPane {
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .api_traffic => |*p| p,
        else => null,
    };
}

fn ensureJob(app: *App) Allocator.Error!void {
    const st = &app.api_traffic;
    if (st.group == null) {
        const g = try app.gpa.create(Io.Group);
        g.* = .init;
        st.group = g;
    }
    if (st.job == null) {
        const job = try app.gpa.create(Job);
        errdefer app.gpa.destroy(job);
        var env_copy = try app.env.clone(app.gpa);
        errdefer env_copy.deinit();
        const root = try app.gpa.dupe(u8, app.data_root);
        errdefer app.gpa.free(root);
        job.* = .{ .env = env_copy, .data_root = root, .workspace = try app.gpa.dupe(u8, app.workspace) };
        st.job = job;
    }
}

/// Start a look now, unless one is already out — its result is about
/// to land, and two workers on one `Job` would be one too many.
pub fn refresh(app: *App) CommandError!void {
    const st = &app.api_traffic;
    if (st.loading) return;
    try ensureJob(app);
    st.generation +%= 1;
    st.loading = true;
    st.last_ms = app.now_ms;
    app.needs_render = true;
    st.group.?.concurrent(app.io, worker, .{ app.events, app.io, app.gpa, st.job.?, st.generation }) catch |err| {
        st.loading = false;
        return app.diag.fail(app.frame.allocator(), "api traffic: could not start the reader: {s}", .{@errorName(err)});
    };
}

/// `r`: the environment again (a variable set since the pane opened
/// names another interop directory), then a look.
pub fn reload(app: *App) CommandError!void {
    const st = &app.api_traffic;
    if (!st.loading) if (st.job) |j| {
        const fresh = try app.env.clone(app.gpa);
        j.env.deinit();
        j.env = fresh;
    };
    try refresh(app);
}

fn onScreen(app: *App, id: PaneId) bool {
    return app.layouts.current().leafOf(id) != null;
}

/// Something drew in the last minute: the fast interval.
fn live(r: ?*const Result) bool {
    const res = r orelse return false;
    for (res.services) |*s| {
        const w = s.win(.hour);
        const nb = Window.hour.buckets();
        if (nb > 0 and w.total(nb - 1) > 0) return true;
    }
    return false;
}

fn mode(app: *const App) refresh_cadence.Mode {
    return app.cfg.ui.dashboard_refresh;
}

/// How often the files are read with no pane on screen, for the 429
/// toasts alone: a throttle is news for a few minutes, not seconds.
pub const watch_ms: i64 = 30_000;

/// `MNML_API_TRAFFIC_WATCH`: a test App watches nothing unless it asks,
/// as a test App hosts no broker (`broker.hosting`).
pub const watch_env = "MNML_API_TRAFFIC_WATCH";

/// Whether the 429 toasts watch the files with no pane on screen: the
/// setting, and a real terminal (or the opt-in).
pub fn watching(app: *const App) bool {
    if (!app.cfg.integrations.throttle_toasts) return false;
    if (app.native_notify) return true;
    const v = app.env.get(watch_env) orelse return false;
    return v.len > 0 and !broker_app.off(v);
}

/// The interval the next look waits, from the state now; null for none.
fn interval(app: *App) ?i64 {
    const shown = if (find(app)) |id| onScreen(app, id) else false;
    const ph = refresh_cadence.phase(mode(app), shown, live(app.api_traffic.result));
    if (ph == .manual) return null;
    if (shown) return refresh_cadence.interval(cadence, ph);
    return if (watching(app)) watch_ms else null;
}

/// Every tick: a look when the cadence says one is due, or the moment
/// the pane comes back on screen.
pub fn tick(app: *App, now: i64) void {
    const st = &app.api_traffic;
    var opened = false;
    if (find(app)) |id| {
        const p = get(app, id).?;
        const shown = onScreen(app, id);
        opened = shown and !p.was_shown;
        p.was_shown = shown;
    }
    if (st.loading) return;
    if (opened and mode(app) != .manual) {
        refresh(app) catch {};
        return;
    }
    const iv = interval(app) orelse return;
    if (st.last_ms == 0 or now - st.last_ms >= iv) refresh(app) catch {};
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    // `find` and the layout walk take the App mutably; nothing here
    // writes through it.
    const m = @constCast(app);
    if (app.api_traffic.loading) return null;
    const iv = interval(m) orelse return null;
    return app.api_traffic.last_ms + iv;
}

// ─── the worker ─────────────────────────────────────────────────────────

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *Job, generation: u32) Io.Cancelable!void {
    const result = Result.create(gpa, generation) catch return;
    compute(io, gpa, job, result) catch |err| switch (err) {
        error.Canceled => {
            result.destroy(gpa);
            return error.Canceled;
        },
        error.OutOfMemory => {
            result.destroy(gpa);
            const owned = gpa.dupe(u8, "api traffic: out of memory reading the logs") catch return;
            events.post(io, .{ .err = .{ .source = .ai, .msg = owned } });
            return;
        },
    };
    events.post(io, .{ .api_traffic = result });
}

pub const ComputeError = Io.Cancelable || Allocator.Error;

/// One look: every log's new lines, then every service's snapshot.
pub fn compute(io: Io, gpa: Allocator, job: *Job, r: *Result) ComputeError!void {
    return computeAt(io, gpa, job, r, nowSecs(io));
}

pub fn computeAt(io: Io, gpa: Allocator, job: *Job, r: *Result, now: f64) ComputeError!void {
    r.now = now;
    r.tz_offset = sdk.budget.localOffset(reader.floorI64(now));
    const paths: reader.Paths = .{ .data_root = job.data_root, .workspace = job.workspace, .env = &job.env };
    try job.rd.look(io, gpa, paths, &known, now);
    try io.checkCancel();
    const arena = r.arena.allocator();
    var out: std.ArrayListUnmanaged(ServiceSnap) = .empty;
    for (job.rd.services.items) |*s| {
        try io.checkCancel();
        var snap: ServiceSnap = .{ .service = try arena.dupe(u8, s.service), .source = s.source() };
        for (Window.all) |w| snap.windows[@intFromEnum(w)] = try reader.buildWindow(arena, gpa, s, w, now);
        const buckets = try reader.readBuckets(io, arena, gpa, &job.env, s.service, now);
        // A service with no line in any log, no 429 and no bucket file
        // is a name mnml knows, not one anybody spends on: no tab.
        if (snap.source == .none and buckets.len == 0 and !s.requests.seen and s.throttles.items.len == 0) continue;
        snap.now = .{
            .buckets = buckets,
            .hour_requests = snap.windows[@intFromEnum(Window.hour)].requests,
            .hour_by = try reader.hourByBucket(arena, gpa, s, buckets, now),
            .hourly_limit = reader.hourlyLimit(s.service),
            .tally_today = reader.readTally(io, gpa, job.data_root, s.service, now),
            .broker = brokerOf(io, gpa, &job.env, s.service, now),
            .feed = reader.readFeed(io, arena, paths, s.service, now),
            .cache_entries = reader.countCache(io, gpa, &job.env, s.service),
            .throttles = try reader.throttlesIn(arena, gpa, s, s.throttles.items, 3600, now),
        };
        snap.fresh = @intCast(s.fresh.items.len);
        snap.last5 = try reader.throttlesIn(arena, gpa, s, s.throttles.items, Coalescer.window_secs, now);
        try out.append(arena, snap);
    }
    r.services = out.items;
}

/// Who serves the queue, from the socket's election lock and — when
/// somebody holds it — one status round trip. The lock first: a socket
/// file outlives the process that bound it (`broker_app.lines`).
fn brokerOf(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, service: []const u8, now: f64) reader.Broker {
    if (!sdk.broker.supported) return .{ .where = .off };
    if (env.get(broker_app.enabled_env)) |v| if (broker_app.off(v)) return .{ .where = .off };
    const path = sdk.broker.socketPath(gpa, io, env, service) catch return .{};
    defer gpa.free(path);
    if (sdk.broker.pathTooLong(path)) return .{ .where = .off };
    const lock = sdk.broker.lockPath(gpa, path) catch return .{};
    defer gpa.free(lock);
    if (!sdk.warm.heldBySomeone(io, lock, now)) return .{ .where = .off };
    const st = sdk.broker.askStatus(io, path, service) orelse return .{ .where = .off };
    return .{ .where = .client, .queue = st.queue };
}

// ─── the event handler ──────────────────────────────────────────────────

/// `result` is adopted or destroyed on every path.
pub fn handle(app: *App, result: *Result) Allocator.Error!void {
    const st = &app.api_traffic;
    if (result.generation != st.generation) {
        result.destroy(app.gpa);
        return;
    }
    st.loading = false;
    // A broker this mnml hosts answers from memory: the worker asked
    // its socket, which is the same answer a moment older.
    for (result.services) |*s| {
        const slot = app.broker.slotFor(s.service) orelse continue;
        if (slot.server) |srv| s.now.broker = .{ .where = .hosted, .queue = srv.snapshot().queue };
    }
    if (st.result) |old| old.destroy(app.gpa);
    st.result = result;
    if (find(app)) |id| {
        const p = get(app, id).?;
        p.result = result;
        p.loading = false;
        // The tab: keep the one picked; on the first result, the
        // busiest service this hour.
        if (p.service.len == 0 or result.find(p.service) == null) try pickBusiest(p, result);
        clampCursor(p);
    }
    try toastThrottles(app, result);
    app.needs_render = true;
}

/// One `.warn` toast per service per five minutes when new 429s landed:
/// `Bitbucket throttled — 3 × 429 in the last 5 min (2 from widget.py,
/// 1 from mnml-bitbucket)`; its button, "API traffic", opens the pane on
/// that service. The first look after start finds no news.
fn toastThrottles(app: *App, result: *const Result) Allocator.Error!void {
    if (!app.cfg.integrations.throttle_toasts) return;
    const st = &app.api_traffic;
    for (result.services) |*s| {
        if (!st.coalescer.note(s.service, s.fresh, result.now)) continue;
        const text = try throttleText(app.frame.allocator(), s);
        const label = try app.gpa.dupe(u8, "API traffic");
        errdefer app.gpa.free(label);
        const service = try app.gpa.dupe(u8, s.service);
        errdefer app.gpa.free(service);
        if (s.service.len <= st.last_toasted.len) {
            @memcpy(st.last_toasted[0..s.service.len], s.service);
            st.last_toasted_len = @intCast(s.service.len);
        }
        try app.toastWithAction(.warn, .{ .api_traffic = .{ .label = label, .service = service } }, "{s}", .{text});
    }
}

/// The toast's words, on `arena`.
pub fn throttleText(arena: Allocator, s: *const ServiceSnap) Allocator.Error![]const u8 {
    var who: std.ArrayListUnmanaged(u8) = .empty;
    for (s.last5.by, 0..) |b, i| {
        if (i == 3) {
            try who.print(arena, ", …", .{});
            break;
        }
        try who.print(arena, "{s}{d} from {s}", .{ if (i > 0) ", " else "", b.n, b.reason });
    }
    var name = try arena.dupe(u8, s.service);
    if (name.len > 0) name[0] = std.ascii.toUpper(name[0]);
    return std.fmt.allocPrint(arena, "{s} throttled — {d} × 429 in the last 5 min ({s})", .{ name, s.last5.n, who.items });
}

/// Whether toast `id` (a `.button` hit) is a throttle toast.
pub fn isThrottleToast(app: *const App, id: u32) bool {
    const toast_ui = @import("../ui/toast.zig");
    if (id < toast_ui.button_base) return false;
    const i = if (id >= toast_ui.close_base) id - toast_ui.close_base else if (id >= toast_ui.action_base) id - toast_ui.action_base else id - toast_ui.button_base;
    if (i >= app.toasts.items.len) return false;
    const a = app.toasts.items[app.toasts.items.len - 1 - i].action orelse return false;
    return a == .api_traffic;
}

/// `view.api_traffic_throttled`: the pane, on the service the newest
/// throttle toast named (the palette's way to it once the toast has
/// gone); a plain open before any toast.
fn throttledCmd(app: *App) CommandError!void {
    const st = &app.api_traffic;
    if (st.last_toasted_len == 0) return showCmd(app);
    var buf: [32]u8 = undefined;
    const n = st.last_toasted_len;
    @memcpy(buf[0..n], st.last_toasted[0..n]);
    return openOn(app, buf[0..n]);
}

fn pickBusiest(p: *ApiTrafficPane, result: *const Result) Allocator.Error!void {
    var best: ?*const ServiceSnap = null;
    for (result.services) |*s| {
        if (best == null or s.win(.hour).requests > best.?.win(.hour).requests) best = s;
    }
    if (best) |b| try setService(p, b.service);
}

fn setService(p: *ApiTrafficPane, name: []const u8) Allocator.Error!void {
    const owned = try p.gpa.dupe(u8, name);
    p.gpa.free(p.service);
    p.service = owned;
}

fn clampCursor(p: *ApiTrafficPane) void {
    const n = if (p.currentWin()) |w| w.who.len else 0;
    if (p.cursor >= n) p.cursor = n -| 1;
    if (p.column) |c| if (c >= p.window.buckets()) {
        p.column = null;
    };
}

// ─── keys / mouse ───────────────────────────────────────────────────────

/// The tab `delta` along from the current one, wrapping.
pub fn stepTab(p: *ApiTrafficPane, delta: i32) Allocator.Error!void {
    const r = p.result orelse return;
    if (r.services.len == 0) return;
    var at: usize = 0;
    for (r.services, 0..) |s, i| if (std.mem.eql(u8, s.service, p.service)) {
        at = i;
    };
    const n: i32 = @intCast(r.services.len);
    const next: usize = @intCast(@mod(@as(i32, @intCast(at)) + delta, n));
    try setService(p, r.services[next].service);
    p.cursor = 0;
    p.scroll = 0;
    p.column = null;
}

pub fn setWindow(p: *ApiTrafficPane, w: Window) void {
    p.window = w;
    p.column = null;
    clampCursor(p);
}

pub fn handleKey(app: *App, id: PaneId, p: *ApiTrafficPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const n = if (p.currentWin()) |w| w.who.len else 0;
    const last = n -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .tab => try stepTab(p, if (k.mods.shift) -1 else 1),
        .backtab => try stepTab(p, -1),
        .left => stepColumn(p, -1),
        .right => stepColumn(p, 1),
        .esc => {
            if (p.column != null) p.column = null else try app.forceClosePane(id);
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'h', '[' => stepColumn(p, -1),
                'l', ']' => stepColumn(p, 1),
                'w' => setWindow(p, p.window.next()),
                '1' => setWindow(p, .hour),
                '2' => setWindow(p, .day),
                '3' => setWindow(p, .week),
                'r' => reload(app) catch {},
                'y' => copyPid(app, p),
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

/// Walk the timeline's picked column; the first step lands on the
/// newest bucket.
fn stepColumn(p: *ApiTrafficPane, delta: i32) void {
    const nb = p.window.buckets();
    if (nb == 0) return;
    const cur: i64 = if (p.column) |c| @intCast(c) else @intCast(nb);
    const next = std.math.clamp(cur + delta, 0, @as(i64, @intCast(nb - 1)));
    p.column = @intCast(next);
}

/// `y`: the pid of the program under the cursor — the newest, when it
/// ran as several.
pub fn copyPid(app: *App, p: *const ApiTrafficPane) void {
    const row = p.selectedWho() orelse return;
    if (row.pids.len == 0) {
        app.toast("{s} drew without a pid", .{row.program});
        return;
    }
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{row.pids[0]}) catch return;
    app.clipboard.copy(text) catch {};
    app.toast("copied pid {s} ({s})", .{ text, row.program });
}

pub fn click(app: *App, id: PaneId, p: *ApiTrafficPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    _ = id;
    if (m.kind != .press) return;
    app.needs_render = true;
    const chip_sort = @import("../ui/hit.zig").ListHit.chip(.sort);
    const chip_refresh = @import("../ui/hit.zig").ListHit.chip(.refresh);
    if (hit_id == chip_sort) {
        if (m.button == .right) return openWindowMenu(app, m.x, m.y);
        if (m.button == .left) setWindow(p, p.window.next());
        return;
    }
    if (hit_id == chip_refresh) {
        if (m.button == .left) reload(app) catch {};
        return;
    }
    if (hit_id >= hit_col_base) {
        if (m.button == .left) {
            const c: usize = hit_id - hit_col_base;
            p.column = if (p.column != null and p.column.? == c) null else c;
        }
        return;
    }
    if (hit_id >= hit_row_base) {
        const row: usize = hit_id - hit_row_base;
        const w = p.currentWin() orelse return;
        if (row >= w.who.len) return;
        p.cursor = row;
        if (m.button == .right) return openRowMenu(app, p, m.x, m.y);
        return;
    }
    if (hit_id >= hit_tab_base and hit_id < hit_tab_base + max_tabs) {
        if (m.button != .left) return;
        const r = p.result orelse return;
        const i: usize = hit_id - hit_tab_base;
        if (i < r.services.len) {
            try setService(p, r.services[i].service);
            p.cursor = 0;
            p.scroll = 0;
            p.column = null;
        }
        return;
    }
}

pub fn scrollBy(p: *ApiTrafficPane, delta: i64) void {
    const n = if (p.currentWin()) |w| w.who.len else 0;
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(n -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

/// A Who row's right-click: the REQUESTS view filtered to it, and its
/// pid. The menu's `mem` owns every string — the next result can land
/// while it is open, and that frees the one these came from.
pub fn openRowMenu(app: *App, p: *const ApiTrafficPane, x: u16, y: u16) Allocator.Error!void {
    const row = p.selectedWho() orelse return;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const a = mem.allocator();
    const name = try a.dupe(u8, row.program);
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    defer rows.deinit(app.gpa);
    try rows.append(app.gpa, .{ .label = "Open in REQUESTS", .action = .{ .requests_for = name } });
    if (row.pids.len > 0) {
        const pid = try std.fmt.allocPrint(a, "{d}", .{row.pids[0]});
        try rows.append(app.gpa, .{ .label = try std.fmt.allocPrint(a, "Copy pid {s}", .{pid}), .action = .{ .copy_text = pid }, .separator_before = true });
    }
    const owned = try context_menus.items(app, rows.items);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, name, owned, x, y, mem);
}

/// The window chip's right-click: every window, the current one ticked.
pub fn openWindowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try context_menus.items(app, &.{
        .{ .label = "Last hour", .action = .{ .command = .@"view.api_traffic_window_hour" } },
        .{ .label = "Last 24 hours", .action = .{ .command = .@"view.api_traffic_window_day" } },
        .{ .label = "Last 7 days", .action = .{ .command = .@"view.api_traffic_window_week" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Window", rows, x, y);
}

fn windowCmd(comptime w: Window) fn (*App) CommandError!void {
    return struct {
        fn run(app: *App) CommandError!void {
            const id = find(app) orelse return;
            const p = get(app, id) orelse return;
            setWindow(p, w);
            app.needs_render = true;
        }
    }.run;
}

// ─── a seeded pane, for the hover audit ─────────────────────────────────

/// The pane with a small hand-made result and no worker: one service,
/// two programs, one bucket of traffic — every part the view paints, so
/// `zig build hover-audit` can probe each one. Invented names only.
pub fn seedForAudit(app: *App) Allocator.Error!PaneId {
    const id = try app.panes.add(.{ .api_traffic = ApiTrafficPane.init(app.gpa, .hour) });
    const p = get(app, id).?;
    const st = &app.api_traffic;
    const r = try Result.create(app.gpa, st.generation);
    const a = r.arena.allocator();
    r.now = 1_790_000_000;
    const nb = Window.hour.buckets();
    const series = try a.dupe(reader.Series, &.{ .{ .label = "widget.py" }, .{ .label = "mnml-acme", .mnml = true } });
    const counts = try a.alloc(u32, nb * series.len);
    @memset(counts, 0);
    counts[(nb - 1) * 2] = 2;
    counts[(nb - 1) * 2 + 1] = 1;
    var snap: ServiceSnap = .{ .service = "acme", .source = .draws };
    snap.windows[0] = .{
        .window = .hour,
        .requests = 3,
        .series = series,
        .counts = counts,
        .start = r.now - 3600,
        .who = try a.dupe(reader.WhoRow, &.{
            .{ .program = "widget.py", .requests = 2, .share_pct = 66.7, .reasons = try a.dupe(reader.Reason, &.{.{ .reason = "poll", .n = 2 }}), .pids = try a.dupe(i32, &.{4100}), .last_seen = r.now - 5 },
            .{ .program = "mnml-acme", .mnml = true, .requests = 1, .share_pct = 33.3, .reasons = try a.dupe(reader.Reason, &.{.{ .reason = "pane_open", .n = 1 }}), .series = 1, .last_seen = r.now - 9 },
        }),
    };
    snap.now = .{
        .buckets = try a.dupe(reader.BucketRow, &.{
            .{ .file = "acme-ratelimit.json", .bucket = .{ .tokens = 3, .capacity = 40, .rate = 0.22 } },
            .{ .token = "0123456789ab", .file = "acme-ratelimit-0123456789ab.json", .bucket = .{ .tokens = 1, .capacity = 40, .rate = 0.22, .throttles = 2, .last_429_age = 30 } },
        }),
        .hour_by = try a.dupe(reader.HourRow, &.{ .{ .requests = 1 }, .{ .token = "0123456789ab", .requests = 2 } }),
        .hour_requests = 3,
        .hourly_limit = 792,
        .broker = .{ .where = .off },
        .cache_entries = 2,
        .throttles = .{ .n = 1, .last_age = 240, .by = try a.dupe(reader.Reason, &.{.{ .reason = "widget.py", .n = 1 }}) },
    };
    r.services = try a.dupe(ServiceSnap, &.{snap});
    if (st.result) |old| old.destroy(app.gpa);
    st.result = r;
    p.result = r;
    try setService(p, "acme");
    return id;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// A fixture interop directory and data root under a tmp dir — invented
/// programs, an invented host, nothing from a real machine.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    shared: []u8,
    data: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try t.allocator.dupe(u8, buf[0..try tmp.dir.realPath(t.io, &buf)]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "shared");
        try tmp.dir.createDirPath(t.io, "data/requests");
        return .{
            .tmp = tmp,
            .root = root,
            .shared = try std.fs.path.join(t.allocator, &.{ root, "shared" }),
            .data = try std.fs.path.join(t.allocator, &.{ root, "data" }),
        };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.root);
        t.allocator.free(f.shared);
        t.allocator.free(f.data);
        f.tmp.cleanup();
    }
};

test "view.api_traffic opens one pane, reads the fixture logs on its worker, and the result lands with the busiest service as the tab" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const now = nowSecs(t.io);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..5) |i| try text.print(t.allocator, "{{\"ts\":{d:.3},\"pid\":4100,\"program\":\"widget.py\",\"service\":\"bitbucket\",\"reason\":\"poll\",\"wait_ms\":20,\"tokens_after\":3}}\n", .{now - 30 - @as(f64, @floatFromInt(i))});
    try text.print(t.allocator, "{{\"ts\":{d:.3},\"pid\":77,\"program\":\"mnml-bitbucket\",\"service\":\"bitbucket\",\"reason\":\"pane_open\",\"wait_ms\":0,\"tokens_after\":2}}\n", .{now - 10});
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/bitbucket-draws.jsonl", .data = text.items });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/jira-draws.jsonl", .data = "" });

    var app = try App.initWith(t.allocator, t.io, .{ .workspace = fx.root, .cols = 140, .rows = 40, .data_root = fx.data });
    defer app.deinit();
    app.tree.visible = false;
    try app.env.put("MNML_SHARED_STATE_DIR", fx.shared);

    try command.run(&app, .{ .static = .@"view.api_traffic" });
    const id = find(&app).?;
    const p = get(&app, id).?;
    try t.expect(app.api_traffic.loading);
    // The worker's result lands on a later tick.
    var tries: usize = 0;
    while (app.api_traffic.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (app.api_traffic.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
    }
    try t.expect(!app.api_traffic.loading);
    const r = p.result.?;
    try t.expectEqual(@as(usize, 2), r.services.len);
    try t.expectEqualStrings("bitbucket", p.service);
    const w = p.currentWin().?;
    try t.expectEqual(@as(u32, 6), w.requests);
    try t.expectEqualStrings("widget.py", w.who[0].program);
    try t.expectEqual(reader.Source.draws, p.current().?.source);
    // The hourly limit is the bucket's refill an hour.
    try t.expectEqual(reader.hourlyLimit("bitbucket"), p.current().?.now.hourly_limit);

    // Tab moves to jira and back; `w` walks the window.
    _ = try handleKey(&app, id, p, .{ .code = .tab });
    try t.expectEqualStrings("jira", p.service);
    _ = try handleKey(&app, id, p, .{ .code = .tab });
    try t.expectEqualStrings("bitbucket", p.service);
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = 'w' } });
    try t.expectEqual(Window.day, p.window);
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = '1' } });
    try t.expectEqual(Window.hour, p.window);

    // A stale result is dropped; the pane keeps what it had.
    const stale = try Result.create(t.allocator, app.api_traffic.generation -% 1);
    try app.handle(.{ .api_traffic = stale });
    try t.expectEqual(r, p.result.?);

    // The same command again refocuses the one pane.
    try command.run(&app, .{ .static = .@"view.api_traffic" });
    try t.expectEqual(id, find(&app).?);
    tries = 0;
    while (app.api_traffic.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (app.api_traffic.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
    }
}

test "the Who row's menu opens REQUESTS filtered to the program and copies its newest pid; the strings outlive the result" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = fx.root, .cols = 140, .rows = 40, .data_root = fx.data });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.api_traffic" });
    const id = find(&app).?;
    const p = get(&app, id).?;
    var tries: usize = 0;
    while (app.api_traffic.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (app.api_traffic.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
    }
    // A hand-made result: one service, one program with two pids.
    const r = try Result.create(t.allocator, app.api_traffic.generation);
    const a = r.arena.allocator();
    const who = try a.dupe(reader.WhoRow, &.{.{ .program = try a.dupe(u8, "mnml-bitbucket"), .mnml = true, .requests = 4, .share_pct = 100, .pids = try a.dupe(i32, &.{ 4242, 17 }) }});
    var snap: ServiceSnap = .{ .service = try a.dupe(u8, "bitbucket"), .source = .draws };
    snap.windows[0].who = who;
    r.services = try a.dupe(ServiceSnap, &.{snap});
    try app.handle(.{ .api_traffic = r });
    try t.expectEqualStrings("bitbucket", p.service);

    try openRowMenu(&app, p, 5, 5);
    const menu = &app.overlay.menu;
    try t.expectEqualStrings("mnml-bitbucket", menu.title);
    try t.expectEqualStrings("Open in REQUESTS", menu.items[0].label);
    try t.expectEqualStrings("mnml-bitbucket", menu.items[0].action.requests_for);
    try t.expectEqualStrings("Copy pid 4242", menu.items[1].label);
    try t.expectEqualStrings("4242", menu.items[1].action.copy_text);

    // The next result replaces (and frees) the one the menu was built
    // from; the menu's strings are its own.
    const r2 = try Result.create(t.allocator, app.api_traffic.generation);
    try app.handle(.{ .api_traffic = r2 });
    try t.expectEqualStrings("mnml-bitbucket", app.overlay.menu.items[0].action.requests_for);
    try t.expectEqualStrings("4242", app.overlay.menu.items[1].action.copy_text);
}

test "the cadence: a look at open, again when due while on screen, none off screen, none under manual" {
    const c = cadence;
    try t.expect(refresh_cadence.isDue(c, .fast, 0, 2000));
    try t.expect(!refresh_cadence.isDue(c, .slow, 0, 4999));
    try t.expect(refresh_cadence.isDue(c, .slow, 0, 5000));
    // Off screen: never.
    try t.expect(!refresh_cadence.isDue(c, .idle, 0, std.math.maxInt(i32)));
    try t.expect(!refresh_cadence.isDue(c, .manual, 0, std.math.maxInt(i32)));
}

/// A result with one service whose last five minutes hold `by`, `fresh`
/// of them new.
fn throttleResult(app: *App, now: f64, fresh: u32, by: []const reader.Reason) !*Result {
    const r = try Result.create(t.allocator, app.api_traffic.generation);
    const a = r.arena.allocator();
    r.now = now;
    var n: u32 = 0;
    for (by) |b| n += b.n;
    var snap: ServiceSnap = .{ .service = "bitbucket", .source = .draws, .fresh = fresh };
    snap.last5 = .{ .n = n, .last_age = 1, .by = try a.dupe(reader.Reason, by) };
    snap.now.throttles = snap.last5;
    r.services = try a.dupe(ServiceSnap, &.{snap});
    return r;
}

fn throttleToasts(app: *const App) usize {
    var n: usize = 0;
    for (app.toasts.items) |tt| {
        if (std.mem.indexOf(u8, tt.text, "throttled") != null) n += 1;
    }
    return n;
}

test "429 toasts coalesce: five new in two minutes is one toast with the counts, more inside five minutes is quiet, one after them is a second toast" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const t0: f64 = 1_790_000_000;
    // The first look after start: no news, no toast, whatever it read.
    try app.handle(.{ .api_traffic = try throttleResult(&app, t0 - 60, 0, &.{.{ .reason = "widget.py", .n = 9 }}) });
    try t.expectEqual(@as(usize, 0), throttleToasts(&app));
    // Five new 429s over two minutes, read in one look.
    try app.handle(.{ .api_traffic = try throttleResult(&app, t0, 5, &.{ .{ .reason = "widget.py", .n = 3 }, .{ .reason = "mnml-bitbucket", .n = 2 } }) });
    try t.expectEqual(@as(usize, 1), throttleToasts(&app));
    const last = app.toasts.items[app.toasts.items.len - 1];
    try t.expectEqualStrings("Bitbucket throttled — 5 × 429 in the last 5 min (3 from widget.py, 2 from mnml-bitbucket)", last.text);
    try t.expectEqual(app_mod.ToastLevel.warn, last.level);
    try t.expectEqualStrings("bitbucket", last.action.?.api_traffic.service);
    // More inside the window: held, not a toast per line.
    try app.handle(.{ .api_traffic = try throttleResult(&app, t0 + 60, 1, &.{.{ .reason = "widget.py", .n = 6 }}) });
    try app.handle(.{ .api_traffic = try throttleResult(&app, t0 + 200, 2, &.{.{ .reason = "widget.py", .n = 8 }}) });
    try t.expectEqual(@as(usize, 1), throttleToasts(&app));
    // A sixth after five minutes: the second toast.
    try app.handle(.{ .api_traffic = try throttleResult(&app, t0 + 330, 1, &.{.{ .reason = "cron.sh", .n = 1 }}) });
    try t.expectEqual(@as(usize, 2), throttleToasts(&app));
    // Its offer opens the pane on that service.
    try command.run(&app, .{ .static = .@"view.api_traffic_throttled" });
    const p = get(&app, find(&app).?).?;
    try t.expectEqualStrings("bitbucket", p.service);
}

test "with 429 toasts off the NOW line still counts them and nothing toasts" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.integrations.throttle_toasts = false;
    try t.expect(!watching(&app));
    try app.handle(.{ .api_traffic = try throttleResult(&app, 1_790_000_000, 5, &.{.{ .reason = "widget.py", .n = 5 }}) });
    try t.expectEqual(@as(usize, 0), throttleToasts(&app));
    try t.expectEqual(@as(u32, 5), app.api_traffic.result.?.services[0].now.throttles.n);
}

test "the coalescer: one toast per service per five minutes, services apart" {
    var c: Coalescer = .{};
    try t.expect(!c.note("bitbucket", 0, 0));
    try t.expect(c.note("bitbucket", 3, 100));
    try t.expect(!c.note("bitbucket", 1, 399));
    try t.expect(c.note("jira", 1, 120));
    try t.expect(c.note("bitbucket", 1, 400));
}

/// A worker's `Job` over the fixture, the way `ensureJob` makes one.
fn fixtureJob(fx: *const Fixture) !*Job {
    const job = try t.allocator.create(Job);
    errdefer t.allocator.destroy(job);
    var env = std.process.Environ.Map.init(t.allocator);
    errdefer env.deinit();
    try env.put("MNML_SHARED_STATE_DIR", fx.shared);
    job.* = .{ .env = env, .data_root = try t.allocator.dupe(u8, fx.data), .workspace = try t.allocator.dupe(u8, fx.root) };
    return job;
}

fn freeJob(job: *Job) void {
    job.deinit(t.allocator);
    t.allocator.destroy(job);
}

/// Every window of every service of `r`, painted at three sizes.
fn paintAll(r: *Result) !void {
    const Ui = @import("../ui/test_fixture.zig");
    const view = @import("../ui/api_traffic_view.zig");
    for (r.services) |s| for (Window.all) |w| for ([_][2]u16{ .{ 60, 20 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        var p = ApiTrafficPane.init(t.allocator, w);
        defer p.deinit(t.io);
        p.result = r;
        p.service = try t.allocator.dupe(u8, s.service);
        // The newest column picked, so the readout paints too.
        p.column = w.buckets() - 1;
        var f = try Ui.init(size[0], size[1]);
        defer f.deinit();
        view.draw(f.ui(), 9, f.full(), &p, true);
    };
}

test "a draws line stamped 1e30 and a bucket cooling until 1e20 are read and painted without a panic, on every window" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const now = nowSecs(t.io);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.print(t.allocator, "{{\"ts\":{d:.3},\"pid\":4100,\"program\":\"widget.py\",\"service\":\"jira\",\"reason\":\"poll\",\"wait_ms\":20,\"tokens_after\":3}}\n", .{now - 30});
    // The hunt's first vector, byte for byte.
    try text.appendSlice(t.allocator, "{\"ts\":1e30,\"pid\":7,\"program\":\"clock-skew\",\"service\":\"jira\",\"reason\":\"poll\",\"wait_ms\":0,\"tokens_after\":1}\n");
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/jira-draws.jsonl", .data = text.items });
    // The second: a cooldown 10^20 seconds out.
    const bucket = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"tokens\":5,\"rate\":0.33,\"cooldown_until\":1e+20,\"throttles\":1,\"last_429\":{d}}}", .{ now, now - 5 });
    defer t.allocator.free(bucket);
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/jira-ratelimit.json", .data = bucket });
    const job = try fixtureJob(&fx);
    defer freeJob(job);
    // Twice: the first look at start, then the next one, which is the
    // one that crashed every launch.
    for (0..2) |_| {
        const r = try Result.create(t.allocator, 0);
        defer r.destroy(t.allocator);
        try computeAt(t.io, t.allocator, job, r, now);
        const s = r.find("jira").?;
        try t.expectEqual(@as(u32, 1), s.win(.hour).requests);
        try t.expectEqual(@as(f64, 0), s.now.buckets[0].bucket.cooldown_secs);
        try paintAll(r);
    }
}

test "every numeric field of every file at its extremes: the worker reads it and the view paints it, whatever the clock" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(t.io, "shared/api-usage");
    const now = nowSecs(t.io);
    const values = [_][]const u8{ "1e30", "-1e30", "1e400", "-1e400", "0", "-1", "4294967296", "1.8446744073709552e19", "5e19", "1e21", "1.7976931348623157e308", "1e", "-", "" };
    var draws: std.ArrayListUnmanaged(u8) = .empty;
    defer draws.deinit(t.allocator);
    var reqs: std.ArrayListUnmanaged(u8) = .empty;
    defer reqs.deinit(t.allocator);
    var throttles: std.ArrayListUnmanaged(u8) = .empty;
    defer throttles.deinit(t.allocator);
    for (values) |v| {
        for ([_][]const u8{ "ts", "pid", "wait_ms", "tokens_after" }) |k| try draws.print(t.allocator, "{{\"{s}\":{s},\"ts\":{d:.3},\"pid\":4,\"program\":\"widget.py\",\"reason\":\"poll\",\"wait_ms\":2}}\n", .{ k, v, now - 20 });
        for ([_][]const u8{ "ts", "status", "wait_ms" }) |k| try reqs.print(t.allocator, "{{\"{s}\":{s},\"ts\":{d:.3},\"integration\":\"mnml-acme\",\"path\":\"/x\",\"status\":429,\"wait_ms\":2}}\n", .{ k, v, now - 20 });
        try throttles.print(t.allocator, "{{\"ts\":{s},\"api\":\"acme\",\"caller\":\"c\"}}\n", .{v});
    }
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/acme-draws.jsonl", .data = draws.items });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data/requests/acme.jsonl", .data = reqs.items });
    var date: [10]u8 = undefined;
    const tpath = try std.fmt.allocPrint(t.allocator, "shared/api-usage/{s}.throttles.jsonl", .{sdk.budget.isoDate(&date, @divFloor(reader.floorI64(now), 86400))});
    defer t.allocator.free(tpath);
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = tpath, .data = throttles.items });
    const job = try fixtureJob(&fx);
    defer freeJob(job);
    for (values) |v| for ([_][]const u8{ "ts", "tokens", "rate", "cooldown_until", "last_429" }) |k| {
        const b = try std.fmt.allocPrint(t.allocator, "{{\"ts\":{d},\"tokens\":5,\"rate\":0.3,\"cooldown_until\":0,\"throttles\":1,\"last_429\":0,\"{s}\":{s}}}", .{ now, k, v });
        defer t.allocator.free(b);
        try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "shared/acme-ratelimit.json", .data = b });
        const r = try Result.create(t.allocator, 0);
        defer r.destroy(t.allocator);
        try computeAt(t.io, t.allocator, job, r, now);
        try paintAll(r);
    };
    // The clock itself far off either way.
    for ([_]f64{ 0, 1, reader.max_ts, 1e18 }) |clock| {
        const r = try Result.create(t.allocator, 0);
        defer r.destroy(t.allocator);
        try computeAt(t.io, t.allocator, job, r, clock);
        try paintAll(r);
    }
}

/// A result whose services each have `fresh` new 429s, one caller each.
fn throttleResultFor(app: *App, now: f64, services: []const []const u8, fresh: u32) !*Result {
    const r = try Result.create(t.allocator, app.api_traffic.generation);
    const a = r.arena.allocator();
    r.now = now;
    const snaps = try a.alloc(ServiceSnap, services.len);
    for (snaps, services) |*snap, name| {
        snap.* = .{ .service = try a.dupe(u8, name), .source = .draws, .fresh = fresh };
        snap.last5 = .{ .n = fresh, .last_age = 1, .by = try a.dupe(reader.Reason, &.{.{ .reason = "widget.py", .n = fresh }}) };
        snap.now.throttles = snap.last5;
    }
    r.services = snaps;
    return r;
}

fn toastFor(app: *const App, service_title: []const u8) ?ToastAction {
    for (app.toasts.items) |tt| if (std.mem.startsWith(u8, tt.text, service_title)) return tt.action;
    return null;
}

const ToastAction = app_mod.ToastAction;

test "each throttle toast's button opens its own service, and a plain open keeps the tab the user is on" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const t0: f64 = 1_790_000_000;
    // Two services throttled in one read: two toasts.
    try app.handle(.{ .api_traffic = try throttleResultFor(&app, t0, &.{ "alphaapi", "betaapi" }, 0) });
    try app.handle(.{ .api_traffic = try throttleResultFor(&app, t0 + 1, &.{ "alphaapi", "betaapi" }, 2) });
    try t.expectEqual(@as(usize, 2), throttleToasts(&app));
    // The FIRST toast's button: its own service, not the last one's.
    try app.runToastAction(toastFor(&app, "Alphaapi").?);
    const p = get(&app, find(&app).?).?;
    try t.expectEqualStrings("alphaapi", p.service);
    try app.runToastAction(toastFor(&app, "Betaapi").?);
    try t.expectEqualStrings("betaapi", p.service);

    // The user walks to another tab and moves the cursor; a toast for a
    // third service comes and goes unclicked (the other two are inside
    // their five quiet minutes).
    try setService(p, "alphaapi");
    try app.handle(.{ .api_traffic = try throttleResultFor(&app, t0 + 2, &.{ "alphaapi", "betaapi", "gammaapi" }, 1) });
    try t.expect(toastFor(&app, "Gammaapi") != null);
    p.cursor = 3;
    // A plain open — the chord, the View menu, the rail row — reads
    // again and stays where the user was.
    try command.run(&app, .{ .static = .@"view.api_traffic" });
    try t.expectEqualStrings("alphaapi", p.service);
    try t.expectEqual(@as(usize, 3), p.cursor);
}
