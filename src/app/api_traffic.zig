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
/// The window chip and the refresh chip are the header's own
/// (`ListHit.chip(.sort)` / `.refresh`, 0x100…).
pub const hit_row_base: u32 = 0x1000;
pub const hit_col_base: u32 = 0x4000;

/// The Now rows, in paint order.
pub const NowRow = enum(u8) { bucket, hour, broker, feed, cache };

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
    pane: PaneId,

    pub fn create(gpa: Allocator, generation: u32, pane: PaneId) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation, .pane = pane };
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

pub const ApiTrafficPane = struct {
    gpa: Allocator,
    group: *Io.Group,
    job: *Job,
    result: ?*Result = null,
    loading: bool = false,
    generation: u32 = 0,
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
    /// When the last look started (`app.now_ms`); 0 before the first.
    last_ms: i64 = 0,
    was_shown: bool = false,

    pub fn init(gpa: Allocator, env: *const std.process.Environ.Map, data_root: []const u8, workspace: []const u8, window: Window) Allocator.Error!ApiTrafficPane {
        const grp = try gpa.create(Io.Group);
        errdefer gpa.destroy(grp);
        grp.* = .init;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        var env_copy = try env.clone(gpa);
        errdefer env_copy.deinit();
        const root = try gpa.dupe(u8, data_root);
        errdefer gpa.free(root);
        job.* = .{ .env = env_copy, .data_root = root, .workspace = try gpa.dupe(u8, workspace) };
        return .{ .gpa = gpa, .group = grp, .job = job, .window = window };
    }

    /// Cancel the worker before anything it holds goes.
    pub fn deinit(self: *ApiTrafficPane, io: Io) void {
        self.group.cancel(io);
        self.gpa.destroy(self.group);
        self.job.deinit(self.gpa);
        self.gpa.destroy(self.job);
        if (self.result) |r| r.destroy(self.gpa);
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
/// when it is already open.
fn showCmd(app: *App) CommandError!void {
    if (find(app)) |id| {
        app.showPane(id);
        try refresh(app, id);
        return;
    }
    var pane = try ApiTrafficPane.init(app.gpa, &app.env, app.data_root, app.workspace, windowOf(app.cfg.integrations.api_traffic_window));
    errdefer pane.deinit(app.io);
    const id = try app.panes.add(.{ .api_traffic = pane });
    pane = undefined;
    const layout = app.layouts.current();
    if (app.active) |cur| if (layout.leafOf(cur) != null) {
        _ = layout.split(cur, .horizontal, id) catch {};
    };
    app.showPane(id);
    try refresh(app, id);
}

pub fn get(app: *App, id: PaneId) ?*ApiTrafficPane {
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .api_traffic => |*p| p,
        else => null,
    };
}

/// Start a look now, unless one is already out — its result is about
/// to land, and two workers on one `Job` would be one too many.
pub fn refresh(app: *App, id: PaneId) CommandError!void {
    const p = get(app, id) orelse return;
    if (p.loading) return;
    p.generation +%= 1;
    p.loading = true;
    p.last_ms = app.now_ms;
    app.needs_render = true;
    p.group.concurrent(app.io, worker, .{ app.events, app.io, app.gpa, p.job, p.generation, id }) catch |err| {
        p.loading = false;
        return app.diag.fail(app.frame.allocator(), "api traffic: could not start the reader: {s}", .{@errorName(err)});
    };
}

/// `r`: the environment again (a variable set since the pane opened
/// names another interop directory), then a look.
pub fn reload(app: *App, id: PaneId) CommandError!void {
    const p = get(app, id) orelse return;
    if (!p.loading) {
        const fresh = try app.env.clone(app.gpa);
        p.job.env.deinit();
        p.job.env = fresh;
    }
    try refresh(app, id);
}

fn onScreen(app: *App, id: PaneId) bool {
    return app.layouts.current().leafOf(id) != null;
}

/// Something drew in the last minute: the fast interval.
fn live(p: *const ApiTrafficPane) bool {
    const r = p.result orelse return false;
    for (r.services) |*s| {
        const w = s.win(.hour);
        const nb = Window.hour.buckets();
        if (nb > 0 and w.total(nb - 1) > 0) return true;
    }
    return false;
}

fn mode(app: *const App) refresh_cadence.Mode {
    return app.cfg.ui.dashboard_refresh;
}

/// Every tick: a look when the cadence says one is due, or the moment
/// the pane comes back on screen.
pub fn tick(app: *App, now: i64) void {
    const id = find(app) orelse return;
    const p = get(app, id) orelse return;
    const shown = onScreen(app, id);
    const opened = shown and !p.was_shown;
    p.was_shown = shown;
    if (p.loading) return;
    const ph = refresh_cadence.phase(mode(app), shown, live(p));
    if ((opened and ph != .manual) or refresh_cadence.isDue(cadence, ph, p.last_ms, now)) refresh(app, id) catch {};
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    // `find` and the layout walk take the App mutably; nothing here
    // writes through it.
    const m = @constCast(app);
    const id = find(m) orelse return null;
    const p = get(m, id) orelse return null;
    if (p.loading) return null;
    return refresh_cadence.dueAt(cadence, refresh_cadence.phase(mode(app), onScreen(m, id), live(p)), p.last_ms);
}

// ─── the worker ─────────────────────────────────────────────────────────

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *Job, generation: u32, pane: PaneId) Io.Cancelable!void {
    const result = Result.create(gpa, generation, pane) catch return;
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
    const now = nowSecs(io);
    r.now = now;
    r.tz_offset = sdk.budget.localOffset(@intFromFloat(now));
    const paths: reader.Paths = .{ .data_root = job.data_root, .workspace = job.workspace, .env = &job.env };
    try job.rd.look(io, gpa, paths, &known, now);
    try io.checkCancel();
    const arena = r.arena.allocator();
    var out: std.ArrayListUnmanaged(ServiceSnap) = .empty;
    for (job.rd.services.items) |*s| {
        try io.checkCancel();
        var snap: ServiceSnap = .{ .service = try arena.dupe(u8, s.service), .source = s.source() };
        for (Window.all) |w| snap.windows[@intFromEnum(w)] = try reader.buildWindow(arena, gpa, s, w, now);
        const bucket = reader.readBucket(io, gpa, &job.env, s.service, now);
        // A service with no line in any log and no bucket file is a
        // name mnml knows, not one anybody spends on: no tab.
        if (snap.source == .none and bucket == null and !s.requests.seen) continue;
        snap.now = .{
            .bucket = bucket,
            .hour_requests = snap.windows[@intFromEnum(Window.hour)].requests,
            .hourly_limit = reader.hourlyLimit(s.service),
            .tally_today = reader.readTally(io, gpa, job.data_root, s.service, now),
            .broker = brokerOf(io, gpa, &job.env, s.service, now),
            .feed = reader.readFeed(io, arena, paths, s.service, now),
            .cache_entries = reader.countCache(io, gpa, &job.env, s.service),
        };
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
    const p = get(app, result.pane) orelse {
        result.destroy(app.gpa);
        return;
    };
    if (result.generation != p.generation) {
        result.destroy(app.gpa);
        return;
    }
    p.loading = false;
    // A broker this mnml hosts answers from memory: the worker asked
    // its socket, which is the same answer a moment older.
    for (result.services) |*s| {
        const slot = app.broker.slotFor(s.service) orelse continue;
        if (slot.server) |srv| s.now.broker = .{ .where = .hosted, .queue = srv.snapshot().queue };
    }
    if (p.result) |old| old.destroy(app.gpa);
    p.result = result;
    // The tab: keep the one picked; on the first result, the busiest
    // service this hour.
    if (p.service.len == 0 or result.find(p.service) == null) {
        var best: ?*const ServiceSnap = null;
        for (result.services) |*s| {
            if (best == null or s.win(.hour).requests > best.?.win(.hour).requests) best = s;
        }
        if (best) |b| try setService(p, b.service);
    }
    clampCursor(p);
    app.needs_render = true;
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
                'r' => reload(app, id) catch {},
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
        if (m.button == .left) reload(app, id) catch {};
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
    const id = try app.panes.add(.{ .api_traffic = try ApiTrafficPane.init(app.gpa, &app.env, app.data_root, app.workspace, .hour) });
    const p = get(app, id).?;
    const r = try Result.create(app.gpa, p.generation, id);
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
    snap.now = .{ .bucket = .{ .tokens = 3, .capacity = 40, .rate = 0.22 }, .hour_requests = 3, .hourly_limit = 792, .broker = .{ .where = .off }, .cache_entries = 2 };
    r.services = try a.dupe(ServiceSnap, &.{snap});
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
    try t.expect(p.loading);
    // The worker's result lands on a later tick.
    var tries: usize = 0;
    while (p.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (p.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
    }
    try t.expect(!p.loading);
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
    const stale = try Result.create(t.allocator, p.generation -% 1, id);
    try app.handle(.{ .api_traffic = stale });
    try t.expectEqual(r, p.result.?);

    // The same command again refocuses the one pane.
    try command.run(&app, .{ .static = .@"view.api_traffic" });
    try t.expectEqual(id, find(&app).?);
    tries = 0;
    while (p.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (p.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
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
    while (p.loading and tries < 200) : (tries += 1) {
        try app.tick(app.now_ms);
        if (p.loading) try t.io.sleep(.fromMilliseconds(10), .awake);
    }
    // A hand-made result: one service, one program with two pids.
    const r = try Result.create(t.allocator, p.generation, id);
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
    const r2 = try Result.create(t.allocator, p.generation, id);
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
