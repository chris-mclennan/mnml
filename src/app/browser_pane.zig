//! `Pane.browser` — a Chrome the IDE drives over CDP. The pane keeps
//! the live log (console, navigations, eval results), the filtered
//! network list (Document / XHR / Fetch), the cookies / storage / perf /
//! DOM panels, snapshots, and the URL history. A worker thread owns
//! the process and the WebSocket: launch → `/json` → connect → enable
//! the domains, then every message it reads is posted as `.cdp` and
//! routed here on the UI thread. Requests the pane makes go straight
//! to the socket; the reply is matched by id to what it was for.

const std = @import("std");
const builtin = @import("builtin");
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
const event = @import("../core/event.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/browser_view.zig");
const text_field = @import("../ui/text_field.zig");
const cdp = @import("../cdp/client.zig");
const profile = @import("../cdp/profile.zig");
const console = @import("../cdp/console.zig");
const child_os = @import("../core/child.zig");
const parse = @import("../http/parse.zig");
const captured = @import("../http/captured.zig");
const history = @import("../http/history.zig");
const http = @import("http.zig");

pub const LogKind = view.LogKind;
pub const Panel = view.Panel;

pub const LogLine = struct { kind: LogKind, text: []u8 };

pub const NetEntry = struct {
    request_id: []u8,
    method: []u8,
    url: []u8,
    headers: std.ArrayListUnmanaged(parse.Header) = .empty,
    post_data: ?[]u8 = null,
    status: ?i64 = null,
    mime: ?[]u8 = null,
    failed: ?[]u8 = null,

    fn deinit(self: *NetEntry, gpa: Allocator) void {
        gpa.free(self.request_id);
        gpa.free(self.method);
        gpa.free(self.url);
        for (self.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        self.headers.deinit(gpa);
        if (self.post_data) |p| gpa.free(p);
        if (self.mime) |m| gpa.free(m);
        if (self.failed) |f| gpa.free(f);
    }

    pub fn toRequest(self: *const NetEntry, gpa: Allocator) Allocator.Error!parse.Request {
        var req = try parse.Request.init(gpa);
        errdefer req.deinit(gpa);
        try req.setMethod(gpa, self.method);
        try req.setUrl(gpa, self.url);
        for (self.headers.items) |h| {
            if (h.name.len > 0 and h.name[0] == ':') continue;
            try req.addHeader(gpa, h.name, h.value);
        }
        if (self.post_data) |b| try req.setBody(gpa, b);
        return req;
    }
};

/// What a request the pane sent was for; the reply is routed by it.
/// `eval_json` is the by-value copy of an object an eval returned;
/// `silent` drops even an error (enables on a child target that lacks
/// the domain).
pub const Pending = enum { eval, eval_json, screenshot, screenshot_clip, pdf, cookies, storage, perf, dom, box_model, navigate, quiet, silent };

pub const Snapshot = struct {
    url: []u8,
    net_urls: [][]u8,
    at_ms: i64,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.url);
        for (self.net_urls) |u| gpa.free(u);
        gpa.free(self.net_urls);
    }
};

pub const Row = struct { text: []u8, key: []u8 };

pub const DevicePreset = struct { name: []const u8, width: u32, height: u32, scale: f64, mobile: bool, ua: []const u8 };

pub const device_presets = [_]DevicePreset{
    .{ .name = "Desktop (clear emulation)", .width = 0, .height = 0, .scale = 1, .mobile = false, .ua = "" },
    .{ .name = "iPhone 14 Pro", .width = 393, .height = 852, .scale = 3, .mobile = true, .ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "iPhone SE", .width = 375, .height = 667, .scale = 2, .mobile = true, .ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "Pixel 7", .width = 412, .height = 915, .scale = 2.625, .mobile = true, .ua = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36" },
    .{ .name = "iPad Air", .width = 820, .height = 1180, .scale = 2, .mobile = true, .ua = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "Laptop 1366×768", .width = 1366, .height = 768, .scale = 1, .mobile = false, .ua = "" },
};

pub const Throttle = struct { name: []const u8, offline: bool, latency_ms: u32, down: i64, up: i64 };

pub const throttles = [_]Throttle{
    .{ .name = "Online (no throttle)", .offline = false, .latency_ms = 0, .down = -1, .up = -1 },
    .{ .name = "Offline", .offline = true, .latency_ms = 0, .down = 0, .up = 0 },
    .{ .name = "Slow 3G", .offline = false, .latency_ms = 2000, .down = 400 * 1024 / 8, .up = 400 * 1024 / 8 },
    .{ .name = "Fast 3G", .offline = false, .latency_ms = 563, .down = 1_600_000 / 8, .up = 750_000 / 8 },
    .{ .name = "WiFi", .offline = false, .latency_ms = 2, .down = 30_000_000 / 8, .up = 15_000_000 / 8 },
};

/// What the worker posts.
pub const CdpEvent = struct {
    pane: PaneId,
    kind: union(enum) {
        connected: []u8,
        message: []u8,
        closed: []u8,
        /// A message too large to take, skipped (`ws.Conn.max_message`).
        too_long: struct { id: ?i64, method: ?[]u8, len: u64 },
    },

    pub fn destroy(self: *CdpEvent, gpa: Allocator) void {
        switch (self.kind) {
            .connected, .message, .closed => |s| gpa.free(s),
            .too_long => |t| if (t.method) |m| gpa.free(m),
        }
        gpa.destroy(self);
    }
};

/// Heap-owned, so the worker's pointer survives the pane store moving
/// the pane. `launch` is published the moment Chrome is spawned — not
/// once it reports a port — so `shutdown` can always reach the child.
const Shared = struct {
    io: Io,
    lock: Io.Mutex = .init,
    session: ?cdp.Session = null,
    launch: ?*cdp.Launch = null,
    closing: bool = false,
    /// `closing`, readable without the lock: ends the `/json` retries.
    stop: std.atomic.Value(bool) = .init(false),
};

pub const BrowserPane = struct {
    gpa: Allocator,
    url: []u8,
    state: enum { launching, connected, closed } = .launching,
    log: std.ArrayListUnmanaged(LogLine) = .empty,
    net: std.ArrayListUnmanaged(NetEntry) = .empty,
    net_sel: usize = 0,
    panel: Panel = .log,
    /// Rows from the bottom of the log; 0 follows the tail.
    scroll: usize = 0,
    shared: *Shared,
    thread: ?std.Thread = null,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    /// `{method, params}` sent before the socket opened.
    queued: std.ArrayListUnmanaged(struct { method: []u8, params: []u8, purpose: Pending }) = .empty,
    cookies: std.ArrayListUnmanaged(Row) = .empty,
    cookies_sel: usize = 0,
    storage: std.ArrayListUnmanaged(Row) = .empty,
    storage_sel: usize = 0,
    perf: std.ArrayListUnmanaged([]u8) = .empty,
    dom: std.ArrayListUnmanaged(Row) = .empty,
    dom_sel: usize = 0,
    /// The `depth` the last `DOM.getDocument` asked for: -1 (all), fewer
    /// once the whole tree came back too large to take.
    dom_depth: i32 = -1,
    snapshots: std.ArrayListUnmanaged(Snapshot) = .empty,
    /// URLs visited, oldest first. Owned.
    visited: std.ArrayListUnmanaged([]u8) = .empty,
    device: ?usize = null,
    /// The type-to-narrow filter over the current panel's rows. One per
    /// pane; switching panels keeps it.
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    filter_focused: bool = false,
    /// The DOM row (unfiltered index) whose node Chrome is highlighting.
    hover_dom: ?usize = null,
    title_buf: []u8,
    port: ?u16 = null,
    profile_dir: []u8,
    headless: bool,
    /// `profile_mode = .ephemeral`: the profile is this pane's alone and
    /// goes with it.
    ephemeral: bool = false,
    /// What an eval returned, as its preview, for when the by-value copy
    /// (`eval_json`) fails: keyed by that request's id.
    eval_fallback: std.AutoHashMapUnmanaged(i64, []u8) = .empty,

    pub fn deinit(self: *BrowserPane, gpa: Allocator) void {
        self.shutdown();
        if (self.thread) |t| t.join();
        if (self.shared.session) |*s| s.deinit();
        if (self.shared.launch) |l| l.destroy(self.shared.io);
        // After the kill: Chrome no longer writes into it.
        if (self.ephemeral) Io.Dir.cwd().deleteTree(self.shared.io, self.profile_dir) catch {};
        gpa.destroy(self.shared);
        for (self.log.items) |l| gpa.free(l.text);
        self.log.deinit(gpa);
        for (self.net.items) |*n| n.deinit(gpa);
        self.net.deinit(gpa);
        self.pending.deinit(gpa);
        for (self.queued.items) |q| {
            gpa.free(q.method);
            gpa.free(q.params);
        }
        self.queued.deinit(gpa);
        freeRows(gpa, &self.cookies);
        freeRows(gpa, &self.storage);
        for (self.perf.items) |p| gpa.free(p);
        self.perf.deinit(gpa);
        freeRows(gpa, &self.dom);
        for (self.snapshots.items) |*s| s.deinit(gpa);
        self.snapshots.deinit(gpa);
        for (self.visited.items) |v| gpa.free(v);
        self.visited.deinit(gpa);
        self.filter.deinit(gpa);
        self.clearFallbacks();
        self.eval_fallback.deinit(gpa);
        gpa.free(self.url);
        gpa.free(self.title_buf);
        gpa.free(self.profile_dir);
    }

    fn clearFallbacks(self: *BrowserPane) void {
        var it = self.eval_fallback.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.eval_fallback.clearRetainingCapacity();
    }

    fn freeRows(gpa: Allocator, rows: *std.ArrayListUnmanaged(Row)) void {
        for (rows.items) |r| {
            gpa.free(r.text);
            gpa.free(r.key);
        }
        rows.deinit(gpa);
    }

    pub fn title(self: *const BrowserPane) []const u8 {
        return self.title_buf;
    }

    fn refreshTitle(self: *BrowserPane) Allocator.Error!void {
        const badge: []const u8 = switch (self.state) {
            .launching => "…",
            .connected => "●",
            .closed => "·",
        };
        const fresh = try std.fmt.allocPrint(self.gpa, "browser {s} {s}", .{ badge, history.shortUrl(self.url) });
        self.gpa.free(self.title_buf);
        self.title_buf = fresh;
    }

    /// Ask the worker to stop: close the socket, kill Chrome.
    pub fn shutdown(self: *BrowserPane) void {
        const io = self.shared.io;
        self.shared.lock.lockUncancelable(io);
        defer self.shared.lock.unlock(io);
        self.shared.closing = true;
        self.shared.stop.store(true, .release);
        if (self.shared.session) |*s| {
            s.conn.close(1000, "") catch {};
            s.conn.stream.shutdown(io, .both) catch {};
        }
        // `Launch.kill` — not `l.child.kill` — so the stderr reader is
        // cancelled here too, and a worker still waiting for the port
        // wakes; it is idempotent, so `deinit`'s `destroy` after this
        // one only frees.
        if (self.shared.launch) |l| l.kill(io);
    }

    pub fn push(self: *BrowserPane, kind: LogKind, text: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        if (self.log.items.len >= 5000) self.gpa.free(self.log.orderedRemove(0).text);
        try self.log.append(self.gpa, .{ .kind = kind, .text = copy });
        // Scrolled back, the view holds still: `scroll` counts rows from
        // the bottom, so the rows this line adds under the view are
        // added to it. (The perf panel reuses the field from the top.)
        if (self.scroll > 0 and self.panel != .perf and matches(std.mem.trim(u8, self.filter.items, " \t"), copy)) self.scroll += entryRows(copy);
    }

    pub fn setUrl(self: *BrowserPane, url: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, url);
        self.gpa.free(self.url);
        self.url = copy;
        try self.refreshTitle();
        if (self.visited.items.len == 0 or !std.mem.eql(u8, self.visited.items[self.visited.items.len - 1], url)) {
            try self.visited.append(self.gpa, try self.gpa.dupe(u8, url));
        }
    }

    pub fn selectedNet(self: *BrowserPane) ?*NetEntry {
        if (self.net_sel >= self.net.items.len) return null;
        return &self.net.items[self.net_sel];
    }

    /// The newest entry for `request_id`: a redirect chain shares one id,
    /// and the response that arrives belongs to its last hop.
    fn findNet(self: *BrowserPane, request_id: []const u8) ?*NetEntry {
        var i = self.net.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.net.items[i].request_id, request_id)) return &self.net.items[i];
        }
        return null;
    }
};

// ─── open / worker ──────────────────────────────────────────────────────

/// The profile directory for `[browser] profile_mode`, before any
/// suffix: `<data root>/chrome-profile` when shared (and there is a data
/// root), else `<workspace>/.mnml/chrome-profile`.
pub fn profileBase(app: *App, arena: Allocator) Allocator.Error![]u8 {
    if (app.cfg.browser.profile_mode == .shared and app.data_root.len > 0) return std.fmt.allocPrint(arena, "{s}/chrome-profile", .{app.data_root});
    return std.fmt.allocPrint(arena, "{s}/.mnml/chrome-profile", .{app.workspace});
}

/// Where ephemeral profiles go: `<workspace>/.mnml/`, one directory per
/// open (`chrome-profile-ephemeral-<random>`), removed when its pane
/// closes; `browser.wipe_profile` removes any a crash left behind.
pub const ephemeral_prefix = "chrome-profile-ephemeral-";

pub const Picked = struct { dir: []u8, note: ?[]u8 = null };

fn inUse(app: *App, dir: []const u8) bool {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asBrowser()) |b| {
        if (std.mem.eql(u8, b.profile_dir, dir)) return true;
    };
    return false;
}

/// A profile directory for a new pane that no open pane uses and no
/// live Chrome holds. The base first, then `-1`, `-2`…: a suffix is
/// taken from what is free, not from how many panes are open, so a
/// closed pane's suffix is reused and a live one's never is. A lock
/// held by a Chrome that an earlier mnml started and left behind
/// (`cdp/profile.zig`'s `orphan`) is cleared by stopping that Chrome;
/// any other live holder is left alone and the next suffix is tried.
pub fn pickProfile(app: *App, arena: Allocator) Allocator.Error!Picked {
    if (app.cfg.browser.profile_mode == .ephemeral) {
        while (true) {
            var raw: [6]u8 = undefined;
            app.io.random(&raw);
            const dir = try std.fmt.allocPrint(arena, "{s}/.mnml/{s}{x}", .{ app.workspace, ephemeral_prefix, &raw });
            Io.Dir.cwd().access(app.io, dir, .{}) catch return .{ .dir = dir };
        }
    }
    const base = try profileBase(app, arena);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const dir = if (i == 0) base else try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, i });
        if (inUse(app, dir)) continue;
        switch (profile.probe(app.gpa, app.io, dir)) {
            .free, .stale => return .{ .dir = dir },
            .orphan => |pid| {
                if (!profile.stopOrphan(app.io, pid, .fromSeconds(3))) continue;
                return .{ .dir = dir, .note = try std.fmt.allocPrint(arena, "stopped a Chrome an earlier session left running on {s} (pid {d})", .{ app.relPath(dir), pid }) };
            },
            .held => continue,
        }
    }
    return .{ .dir = base };
}

/// Launch Chrome at `url` in a new pane beside the active one.
/// Tests: pretend no Chrome is installed, so `open` fails with its diag
/// instead of launching the one on this machine.
pub var test_no_chrome: bool = false;
/// Tests: launch this stand-in instead of looking for Chrome.
pub var test_binary: ?[]const u8 = null;

pub fn open(app: *App, url_in: []const u8) CommandError!PaneId {
    const gpa = app.gpa;
    const binary: ?[]const u8 = if (builtin.is_test) test_binary else null;
    const no_chrome = (builtin.is_test and test_no_chrome) or (binary == null and !cdp.available(gpa, app.io, &app.env));
    if (no_chrome) return app.diag.fail(app.frame.allocator(), "no Chrome found — run `:browser.install_cft` to install Chrome for Testing", .{});
    const url = try cdp.normalizeUrl(app.frame.allocator(), url_in);
    const shared = try gpa.create(Shared);
    errdefer gpa.destroy(shared);
    shared.* = .{ .io = app.io };
    const picked = try pickProfile(app, app.frame.allocator());
    const pdir = picked.dir;
    Io.Dir.cwd().createDirPath(app.io, pdir) catch {};
    var pane: BrowserPane = .{
        .gpa = gpa,
        .url = try gpa.dupe(u8, url),
        .shared = shared,
        .title_buf = try gpa.dupe(u8, "browser"),
        .profile_dir = try gpa.dupe(u8, pdir),
        .headless = app.cfg.browser.headless,
        .ephemeral = app.cfg.browser.profile_mode == .ephemeral,
    };
    errdefer pane.deinit(gpa);
    try pane.refreshTitle();
    if (picked.note) |note| try pane.push(.system, note);
    try pane.push(.system, "launching Chrome…");
    const id = try app.panes.add(.{ .browser = pane });
    // Beside the active pane (the "watch the network while editing the request" layout).
    if (app.active) |cur| {
        if (app.layouts.current().split(cur, .horizontal, id) catch null) |_| {
            app.setActive(id);
        } else app.showPane(id);
    } else app.showPane(id);
    const p = app.panes.get(id).?.asBrowser().?;
    const url_owned = try gpa.dupe(u8, p.url);
    errdefer gpa.free(url_owned);
    const dir_owned = try gpa.dupe(u8, p.profile_dir);
    errdefer gpa.free(dir_owned);
    p.thread = std.Thread.spawn(.{}, worker, .{ &app.events, app.io, gpa, &app.env, shared, id, url_owned, dir_owned, p.headless, binary }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "browser: could not start the worker: {s}", .{@errorName(err)});
    };
    if (p.device) |d| _ = d;
    return id;
}

fn post(events: *event.EventQueue, io: Io, gpa: Allocator, ev: CdpEvent) void {
    const box = gpa.create(CdpEvent) catch return;
    box.* = ev;
    events.post(io, .{ .cdp = box });
}

fn postClosed(events: *event.EventQueue, io: Io, gpa: Allocator, pane: PaneId, reason: []const u8) void {
    const copy = gpa.dupe(u8, reason) catch return;
    post(events, io, gpa, .{ .pane = pane, .kind = .{ .closed = copy } });
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, env: *const std.process.Environ.Map, shared: *Shared, pane: PaneId, url: []u8, profile_dir: []u8, headless: bool, binary: ?[]const u8) void {
    defer gpa.free(url);
    defer gpa.free(profile_dir);
    const launch = cdp.spawn(gpa, io, env, .{ .url = url, .profile_dir = profile_dir, .headless = headless, .binary = binary }) catch |err| {
        const msg: []const u8 = switch (err) {
            error.ChromeNotFound => "Chrome not found. Install Chrome for Testing:\n    npx @puppeteer/browsers install chrome@stable\nor run `:browser.install_cft`.",
            error.NoDevToolsPort => "couldn't find Chrome's DevTools port — did it start?",
            error.OutOfMemory => "out of memory launching Chrome",
            error.ConcurrencyUnavailable => "could not start Chrome's stderr reader",
        };
        postClosed(events, io, gpa, pane, msg);
        return;
    };
    // Published before anything waits on it: from here on the pane's
    // `shutdown` can kill Chrome, which wakes the wait below.
    {
        shared.lock.lockUncancelable(io);
        defer shared.lock.unlock(io);
        if (shared.closing) {
            launch.destroy(io);
            return;
        }
        shared.launch = launch;
    }
    const port = launch.waitPort(io, cdp.port_timeout) orelse {
        shared.lock.lockUncancelable(io);
        const closing = shared.closing;
        shared.lock.unlock(io);
        if (closing) return;
        postClosed(events, io, gpa, pane, if (launch.port_ready.isSet())
            "Chrome exited before reporting its DevTools port — is another Chrome using this profile?"
        else
            "Chrome did not report a DevTools port within 20 s");
        return;
    };
    const ws_url = cdp.pageWsUrl(gpa, io, port, &shared.stop) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "couldn't reach Chrome's /json endpoint: {s}", .{@errorName(err)}) catch return;
        defer gpa.free(msg);
        postClosed(events, io, gpa, pane, msg);
        return;
    };
    defer gpa.free(ws_url);
    var session = cdp.Session.connect(gpa, io, ws_url) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "connecting to {s}: {s}", .{ ws_url, @errorName(err) }) catch return;
        defer gpa.free(msg);
        postClosed(events, io, gpa, pane, msg);
        return;
    };
    session.enableAll() catch {};
    {
        shared.lock.lockUncancelable(io);
        defer shared.lock.unlock(io);
        if (shared.closing) {
            session.deinit();
            return;
        }
        shared.session = session;
    }
    const connected = std.fmt.allocPrint(gpa, "{s}\n{d}", .{ ws_url, port }) catch return;
    post(events, io, gpa, .{ .pane = pane, .kind = .{ .connected = connected } });
    while (true) {
        const next = shared.session.?.next() catch |err| {
            const msg = std.fmt.allocPrint(gpa, "WebSocket error: {s}", .{@errorName(err)}) catch break;
            defer gpa.free(msg);
            postClosed(events, io, gpa, pane, msg);
            return;
        } orelse break;
        switch (next) {
            .text => |text| {
                const copy = gpa.dupe(u8, text) catch break;
                post(events, io, gpa, .{ .pane = pane, .kind = .{ .message = copy } });
            },
            .too_long => |t| {
                const method = if (t.method) |m| gpa.dupe(u8, m) catch null else null;
                post(events, io, gpa, .{ .pane = pane, .kind = .{ .too_long = .{ .id = t.id, .method = method, .len = t.len } } });
            },
        }
    }
    postClosed(events, io, gpa, pane, if (shared.closing) "closed" else "page closed");
}

// ─── requests ───────────────────────────────────────────────────────────

/// Send a CDP request from the pane (queued until connected).
pub fn send(app: *App, p: *BrowserPane, method: []const u8, params_json: []const u8, purpose: Pending) Allocator.Error!void {
    _ = try sendTo(app, p, method, params_json, purpose, null);
}

/// `send`, to a given session (null: the pane's own page). The request
/// id once sent; null when queued or not sent.
pub fn sendTo(app: *App, p: *BrowserPane, method: []const u8, params_json: []const u8, purpose: Pending, session: ?[]const u8) Allocator.Error!?i64 {
    const io = app.io;
    p.shared.lock.lockUncancelable(io);
    defer p.shared.lock.unlock(io);
    if (p.shared.session) |*s| {
        const id = s.send(method, params_json, session) catch |err| {
            try p.push(.system, try std.fmt.allocPrint(app.frame.allocator(), "send {s} failed: {s}", .{ method, @errorName(err) }));
            return null;
        };
        try p.pending.put(app.gpa, id, purpose);
        return id;
    }
    try p.queued.append(app.gpa, .{ .method = try app.gpa.dupe(u8, method), .params = try app.gpa.dupe(u8, params_json), .purpose = purpose });
    return null;
}

fn flushQueued(app: *App, p: *BrowserPane) Allocator.Error!void {
    const items = try app.frame.allocator().dupe(@TypeOf(p.queued.items[0]), p.queued.items);
    p.queued.clearRetainingCapacity();
    for (items) |q| {
        defer {
            app.gpa.free(q.method);
            app.gpa.free(q.params);
        }
        try send(app, p, q.method, q.params, q.purpose);
    }
}

/// Load `url_in` (typed the way an address bar takes it: see
/// `cdp.normalizeUrl`) in what the pane shows.
pub fn navigate(app: *App, p: *BrowserPane, url_in: []const u8) Allocator.Error!void {
    const url = try cdp.normalizeUrl(app.frame.allocator(), url_in);
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"url\":{f}}}", .{std.json.fmt(url, .{})});
    try send(app, p, "Page.navigate", params, .navigate);
    try p.push(.nav, try std.fmt.allocPrint(app.frame.allocator(), "→ {s}", .{url}));
}

/// Evaluate `expr` in the page. The user's eval (`.eval`) gets the
/// result as a remote object with its preview, so a function, a
/// Symbol or a circular object reads as DevTools shows it; the
/// panels' dumps (`.storage` / `.perf` / `.quiet`) take it by value.
pub fn eval(app: *App, p: *BrowserPane, expr: []const u8, purpose: Pending) Allocator.Error!void {
    const by_value = purpose != .eval;
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"expression\":{f},\"returnByValue\":{},\"generatePreview\":{},\"userGesture\":true,\"awaitPromise\":true}}", .{ std.json.fmt(expr, .{}), by_value, !by_value });
    try send(app, p, "Runtime.evaluate", params, purpose);
    if (purpose == .eval) try p.push(.eval, try std.fmt.allocPrint(app.frame.allocator(), "» {s}", .{expr}));
}

// ─── the event handler ──────────────────────────────────────────────────

/// D1: the event is ours; the text is parsed on the frame arena and
/// what the pane keeps is copied.
pub fn handle(app: *App, ev: *CdpEvent) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const pane = app.panes.get(ev.pane) orelse return;
    const p = pane.asBrowser() orelse return;
    app.needs_render = true;
    switch (ev.kind) {
        .connected => |info| {
            p.state = .connected;
            var lines = std.mem.splitScalar(u8, info, '\n');
            const ws_url = lines.next() orelse "";
            if (lines.next()) |port| p.port = std.fmt.parseInt(u16, port, 10) catch null;
            try p.push(.system, try std.fmt.allocPrint(app.frame.allocator(), "connected — {s}", .{ws_url}));
            try p.refreshTitle();
            try flushQueued(app, p);
            if (p.device) |d| try applyDevice(app, p, d);
        },
        .closed => |reason| {
            p.state = .closed;
            try p.push(.system, try std.fmt.allocPrint(app.frame.allocator(), "session ended: {s}", .{reason}));
            try p.refreshTitle();
        },
        .message => |text| try onMessage(app, p, text),
        .too_long => |t| try onTooLong(app, p, t.id, t.method, t.len),
    }
}

/// The fewest levels the DOM panel asks for before it gives up.
const dom_min_depth = 2;

/// What a request was for, as the log says it.
fn purposeLabel(purpose: Pending) []const u8 {
    return switch (purpose) {
        .eval => "eval",
        .screenshot, .screenshot_clip => "screenshot",
        .pdf => "pdf",
        .cookies => "cookies",
        .storage => "storage",
        .perf => "perf",
        .dom => "DOM",
        .box_model => "node box",
        .navigate => "navigate",
        .eval_json => "eval",
        .quiet, .silent => "request",
    };
}

/// The preview an eval's object read as, when its by-value copy failed.
fn evalFallback(app: *App, p: *BrowserPane, rid: i64) Allocator.Error!void {
    const kv = p.eval_fallback.fetchRemove(rid) orelse return;
    defer app.gpa.free(kv.value);
    try p.push(.eval, try std.fmt.allocPrint(app.frame.allocator(), "= {s}", .{kv.value}));
}

/// `⚠ Uncaught Error: boom` off a reply's or an event's
/// `exceptionDetails`: the exception's first line, prefixed the way
/// DevTools prefixes it.
fn exceptionLine(arena: Allocator, details: std.json.Value) Allocator.Error![]const u8 {
    const text = cdp.str(details, &.{"text"}) orelse "Uncaught";
    const exc = cdp.get(details, &.{"exception"});
    const desc: []const u8 = if (cdp.str(exc, &.{"description"})) |d| std.mem.sliceTo(d, '\n') else if (exc) |e| try console.objectText(arena, e, false) else "";
    if (desc.len == 0) return std.fmt.allocPrint(arena, "⚠ {s}", .{text});
    const prefix: []const u8 = if (std.mem.startsWith(u8, text, "Uncaught (in promise)")) "Uncaught (in promise)" else "Uncaught";
    return std.fmt.allocPrint(arena, "⚠ {s} {s}", .{ prefix, desc });
}

/// A reply or event over the WebSocket cap was skipped; the session
/// lives on. A reply fails the request it answers, with a note that
/// says how large it was; the DOM panel asks again for fewer levels.
fn onTooLong(app: *App, p: *BrowserPane, id: ?i64, method: ?[]const u8, len: u64) Allocator.Error!void {
    const arena = app.frame.allocator();
    const mb = @divFloor(len + (1 << 19), 1 << 20);
    const rid = id orelse {
        try p.push(.console_err, try std.fmt.allocPrint(arena, "skipped a {s} event of {d} MB (too large to show)", .{ method orelse "CDP", mb }));
        return;
    };
    const purpose = p.pending.get(rid) orelse return;
    _ = p.pending.remove(rid);
    if (purpose == .eval_json) return evalFallback(app, p, rid);
    const fewer: i32 = if (p.dom_depth < 0) 8 else @divFloor(p.dom_depth, 2);
    if (purpose == .dom and fewer >= dom_min_depth) {
        p.dom_depth = fewer;
        try p.push(.system, try std.fmt.allocPrint(arena, "DOM: the whole tree is {d} MB — asking for {d} levels", .{ mb, p.dom_depth }));
        try send(app, p, "DOM.getDocument", try std.fmt.allocPrint(arena, "{{\"depth\":{d}}}", .{p.dom_depth}), .dom);
        return;
    }
    try p.push(.console_err, try std.fmt.allocPrint(arena, "{s}: reply too large ({d} MB) — not shown", .{ purposeLabel(purpose), mb }));
}

fn onMessage(app: *App, p: *BrowserPane, text: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const m = cdp.parseMessage(arena, text) catch return;
    if (m.method) |method| return onEvent(app, p, method, m);
    const rid = m.id orelse return;
    const purpose = p.pending.get(rid) orelse return;
    _ = p.pending.remove(rid);
    if (m.error_message) |e| {
        switch (purpose) {
            .silent => {},
            .eval_json => try evalFallback(app, p, rid),
            else => try p.push(.console_err, try std.fmt.allocPrint(arena, "{s} failed: {s}", .{ purposeLabel(purpose), e })),
        }
        return;
    }
    // A throw or a rejection: the panels' dumps say which one failed.
    if (cdp.get(m.result, &.{"exceptionDetails"})) |details| switch (purpose) {
        .eval => return p.push(.console_err, try exceptionLine(arena, details)),
        .storage, .perf => return p.push(.console_err, try std.fmt.allocPrint(arena, "{s}: {s}", .{ purposeLabel(purpose), (try exceptionLine(arena, details))["⚠ ".len..] })),
        .eval_json => return evalFallback(app, p, rid),
        else => {},
    };
    switch (purpose) {
        .quiet, .silent => {},
        .navigate => {
            // A navigation Chrome refused at the network layer.
            if (cdp.str(m.result, &.{"errorText"})) |e| try p.push(.console_err, try std.fmt.allocPrint(arena, "navigate failed: {s}", .{e}));
        },
        .eval => {
            const value = cdp.get(m.result, &.{"result"}) orelse return;
            const ty = cdp.str(value, &.{"type"}) orelse "";
            const subtype = cdp.str(value, &.{"subtype"}) orelse "";
            const shown = try console.objectText(arena, value, false);
            // A plain object or an array reads as its JSON, copied by
            // value from the object the eval returned; the preview is
            // what shows if that copy fails (a circular object).
            if (std.mem.eql(u8, ty, "object") and (subtype.len == 0 or std.mem.eql(u8, subtype, "array"))) if (cdp.str(value, &.{"objectId"})) |oid| {
                const params = try std.fmt.allocPrint(arena, "{{\"objectId\":{f},\"functionDeclaration\":\"function(){{return this}}\",\"returnByValue\":true}}", .{std.json.fmt(oid, .{})});
                // To the session the eval ran in: the reply carries it.
                if (try sendTo(app, p, "Runtime.callFunctionOn", params, .eval_json, m.session_id)) |jid| {
                    try p.eval_fallback.put(app.gpa, jid, try app.gpa.dupe(u8, shown));
                    _ = try sendTo(app, p, "Runtime.releaseObject", try std.fmt.allocPrint(arena, "{{\"objectId\":{f}}}", .{std.json.fmt(oid, .{})}), .silent, m.session_id);
                    return;
                }
            };
            try p.push(.eval, try std.fmt.allocPrint(arena, "= {s}", .{shown}));
        },
        .eval_json => {
            const kv = p.eval_fallback.fetchRemove(rid);
            defer if (kv) |x| app.gpa.free(x.value);
            const value = cdp.get(m.result, &.{ "result", "value" }) orelse {
                if (kv) |x| try p.push(.eval, try std.fmt.allocPrint(arena, "= {s}", .{x.value}));
                return;
            };
            try p.push(.eval, try std.fmt.allocPrint(arena, "= {s}", .{try std.json.Stringify.valueAlloc(arena, value, .{})}));
        },
        .screenshot, .screenshot_clip, .pdf => {
            const data = cdp.str(m.result, &.{"data"}) orelse return;
            const ext: []const u8 = if (purpose == .pdf) "pdf" else "png";
            const path = try saveBase64(app, data, ext);
            if (path) |pth| {
                app.toast("{s} saved: {s}", .{ if (purpose == .pdf) "pdf" else "screenshot", app.relPath(pth) });
                try p.push(.system, try std.fmt.allocPrint(arena, "saved {s}", .{app.relPath(pth)}));
            }
        },
        .cookies => {
            BrowserPane.freeRows(app.gpa, &p.cookies);
            p.cookies = .empty;
            const list = cdp.get(m.result, &.{"cookies"}) orelse return;
            if (list != .array) return;
            for (list.array.items) |c| {
                const name = cdp.str(c, &.{"name"}) orelse continue;
                const value = cdp.str(c, &.{"value"}) orelse "";
                const domain = cdp.str(c, &.{"domain"}) orelse "";
                const path = cdp.str(c, &.{"path"}) orelse "/";
                const line = try std.fmt.allocPrint(app.gpa, "{s}={s}   {s}{s}", .{ name, if (value.len > 40) value[0..38] else value, domain, path });
                errdefer app.gpa.free(line);
                const key = try std.fmt.allocPrint(app.gpa, "{s}\t{s}\t{s}", .{ name, domain, path });
                errdefer app.gpa.free(key);
                try p.cookies.append(app.gpa, .{ .text = line, .key = key });
            }
            p.panel = .cookies;
            p.cookies_sel = 0;
        },
        .storage => {
            BrowserPane.freeRows(app.gpa, &p.storage);
            p.storage = .empty;
            const value = cdp.str(m.result, &.{ "result", "value" }) orelse return p.push(.console_err, "storage: the page gave no storage to read");
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, value, .{}) catch return;
            if (parsed != .array) return;
            for (parsed.array.items) |e| {
                const scope = cdp.str(e, &.{"scope"}) orelse "local";
                const k = cdp.str(e, &.{"key"}) orelse continue;
                const v = cdp.str(e, &.{"value"}) orelse "";
                const line = try std.fmt.allocPrint(app.gpa, "[{s}] {s} = {s}", .{ scope, k, if (v.len > 60) v[0..58] else v });
                errdefer app.gpa.free(line);
                const key = try std.fmt.allocPrint(app.gpa, "{s}\t{s}", .{ scope, k });
                errdefer app.gpa.free(key);
                try p.storage.append(app.gpa, .{ .text = line, .key = key });
            }
            p.panel = .storage;
            p.storage_sel = 0;
        },
        .perf => {
            for (p.perf.items) |l| app.gpa.free(l);
            p.perf.clearRetainingCapacity();
            const value = cdp.str(m.result, &.{ "result", "value" }) orelse return p.push(.console_err, "perf: the page gave no timings to read");
            var lines = std.mem.splitScalar(u8, value, '\n');
            while (lines.next()) |l| if (l.len > 0) try p.perf.append(app.gpa, try app.gpa.dupe(u8, l));
            p.panel = .perf;
        },
        .dom => {
            BrowserPane.freeRows(app.gpa, &p.dom);
            p.dom = .empty;
            const root = cdp.get(m.result, &.{"root"}) orelse return;
            try flattenDom(app, p, root, 0);
            p.panel = .dom;
            p.dom_sel = 0;
        },
        .box_model => {
            const content = cdp.get(m.result, &.{ "model", "content" }) orelse return;
            if (content != .array or content.array.items.len < 8) return;
            const q = content.array.items;
            const xs = [_]f64{ num(q[0]), num(q[2]), num(q[4]), num(q[6]) };
            const ys = [_]f64{ num(q[1]), num(q[3]), num(q[5]), num(q[7]) };
            const x = @min(@min(xs[0], xs[1]), @min(xs[2], xs[3]));
            const y = @min(@min(ys[0], ys[1]), @min(ys[2], ys[3]));
            const w = @max(@max(xs[0], xs[1]), @max(xs[2], xs[3])) - x;
            const h = @max(@max(ys[0], ys[1]), @max(ys[2], ys[3])) - y;
            const params = try std.fmt.allocPrint(arena, "{{\"format\":\"png\",\"clip\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"scale\":1}}}}", .{ x, y, w, h });
            try send(app, p, "Page.captureScreenshot", params, .screenshot_clip);
        },
    }
}

fn num(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn flattenDom(app: *App, p: *BrowserPane, node: std.json.Value, depth: usize) Allocator.Error!void {
    if (node != .object) return;
    const name = cdp.str(node, &.{"nodeName"}) orelse "?";
    const node_id = cdp.int(node, &.{"nodeId"}) orelse 0;
    var attrs: std.ArrayListUnmanaged(u8) = .empty;
    if (cdp.get(node, &.{"attributes"})) |a| if (a == .array) {
        var i: usize = 0;
        while (i + 1 < a.array.items.len) : (i += 2) {
            const k = a.array.items[i];
            const v = a.array.items[i + 1];
            if (k != .string or v != .string) continue;
            if (std.mem.eql(u8, k.string, "id")) try appendFmt(app.frame.allocator(), &attrs, "#{s}", .{v.string});
            if (std.mem.eql(u8, k.string, "class")) try appendFmt(app.frame.allocator(), &attrs, ".{s}", .{std.mem.sliceTo(v.string, ' ')});
        }
    };
    const skipped = std.mem.eql(u8, name, "#text") or std.mem.eql(u8, name, "#comment") or std.mem.eql(u8, name, "#document");
    if (!skipped) {
        const line = try std.fmt.allocPrint(app.gpa, "{s}{s}{s}", .{ try indent(app.frame.allocator(), depth), std.ascii.lowerString(try app.frame.allocator().alloc(u8, name.len), name), attrs.items });
        errdefer app.gpa.free(line);
        const key = try std.fmt.allocPrint(app.gpa, "{d}", .{node_id});
        errdefer app.gpa.free(key);
        try p.dom.append(app.gpa, .{ .text = line, .key = key });
    }
    if (cdp.get(node, &.{"children"})) |c| if (c == .array) {
        for (c.array.items) |child| try flattenDom(app, p, child, if (skipped) depth else depth + 1);
    };
}

fn indent(arena: Allocator, depth: usize) Allocator.Error![]u8 {
    const out = try arena.alloc(u8, @min(depth, 40) * 2);
    @memset(out, ' ');
    return out;
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try list.appendSlice(a, s);
}

fn saveBase64(app: *App, data: []const u8, ext: []const u8) Allocator.Error!?[]const u8 {
    const arena = app.frame.allocator();
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(data) catch return null;
    const bytes = try arena.alloc(u8, size);
    dec.decode(bytes, data) catch return null;
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "screenshots" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch return null;
    const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(app.io, .real).toNanoseconds(), std.time.ns_per_ms));
    const path = try std.fmt.allocPrint(arena, "{s}/shot-{d}.{s}", .{ dir, ts, ext });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = bytes }) catch return null;
    return path;
}

fn onEvent(app: *App, p: *BrowserPane, method: []const u8, m: cdp.Message) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
        const kind = cdp.str(m.params, &.{"type"}) orelse "log";
        const args: []const std.json.Value = if (cdp.get(m.params, &.{"args"})) |a| (if (a == .array) a.array.items else &.{}) else &.{};
        const text = try console.formatArgs(arena, args);
        const is_err = std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "warning") or std.mem.eql(u8, kind, "assert");
        try p.push(if (is_err) .console_err else .console, try std.fmt.allocPrint(arena, "console.{s}: {s}", .{ console.callName(kind), text }));
    } else if (std.mem.eql(u8, method, "Log.entryAdded")) {
        const level = cdp.str(m.params, &.{ "entry", "level" }) orelse "info";
        const text = cdp.str(m.params, &.{ "entry", "text" }) orelse "";
        try p.push(if (std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "warning")) .console_err else .console, try std.fmt.allocPrint(arena, "[{s}] {s}", .{ level, text }));
    } else if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
        const text = cdp.str(m.params, &.{ "exceptionDetails", "text" }) orelse "exception";
        const desc = cdp.str(m.params, &.{ "exceptionDetails", "exception", "description" }) orelse "";
        try p.push(.console_err, try std.fmt.allocPrint(arena, "{s} {s}", .{ text, std.mem.sliceTo(desc, '\n') }));
    } else if (std.mem.eql(u8, method, "Page.frameNavigated")) {
        if (cdp.str(m.params, &.{ "frame", "parentId" }) != null) return;
        const url = cdp.str(m.params, &.{ "frame", "url" }) orelse return;
        try p.setUrl(url);
        try p.push(.nav, try std.fmt.allocPrint(arena, "navigated: {s}", .{url}));
    } else if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
        const ty = cdp.str(m.params, &.{"type"}) orelse "";
        if (!(std.mem.eql(u8, ty, "Document") or std.mem.eql(u8, ty, "XHR") or std.mem.eql(u8, ty, "Fetch"))) return;
        const request_id = cdp.str(m.params, &.{"requestId"}) orelse return;
        const url = cdp.str(m.params, &.{ "request", "url" }) orelse return;
        const meth = cdp.str(m.params, &.{ "request", "method" }) orelse "GET";
        // A redirect hop: Chrome reuses the request id and hands the
        // previous hop's response over here, never as a responseReceived.
        if (cdp.get(m.params, &.{"redirectResponse"})) |rr| if (p.findNet(request_id)) |prev| {
            prev.status = cdp.int(rr, &.{"status"});
            if (cdp.str(rr, &.{"mimeType"})) |mt| {
                if (prev.mime) |old| app.gpa.free(old);
                prev.mime = try app.gpa.dupe(u8, mt);
            }
        };
        var entry: NetEntry = .{ .request_id = try app.gpa.dupe(u8, request_id), .method = undefined, .url = undefined };
        errdefer app.gpa.free(entry.request_id);
        entry.method = try app.gpa.dupe(u8, meth);
        errdefer app.gpa.free(entry.method);
        entry.url = try app.gpa.dupe(u8, url);
        errdefer app.gpa.free(entry.url);
        if (cdp.get(m.params, &.{ "request", "headers" })) |hs| if (hs == .object) {
            var it = hs.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .string) {
                const n = try app.gpa.dupe(u8, e.key_ptr.*);
                errdefer app.gpa.free(n);
                const v = try app.gpa.dupe(u8, e.value_ptr.string);
                errdefer app.gpa.free(v);
                try entry.headers.append(app.gpa, .{ .name = n, .value = v });
            };
        };
        if (cdp.str(m.params, &.{ "request", "postData" })) |pd| entry.post_data = try app.gpa.dupe(u8, pd);
        if (p.net.items.len >= 500) {
            var oldest = p.net.orderedRemove(0);
            oldest.deinit(app.gpa);
        }
        try p.net.append(app.gpa, entry);
        try p.push(.net, try std.fmt.allocPrint(arena, "{s} {s}", .{ meth, history.shortUrl(url) }));
        if (app.cfg.browser.autocapture_to_log) try appendCaptured(app, &p.net.items[p.net.items.len - 1]);
    } else if (std.mem.eql(u8, method, "Network.responseReceived")) {
        const request_id = cdp.str(m.params, &.{"requestId"}) orelse return;
        const n = p.findNet(request_id) orelse return;
        n.status = cdp.int(m.params, &.{ "response", "status" });
        if (cdp.str(m.params, &.{ "response", "mimeType" })) |mt| {
            if (n.mime) |old| app.gpa.free(old);
            n.mime = try app.gpa.dupe(u8, mt);
        }
    } else if (std.mem.eql(u8, method, "Network.loadingFailed")) {
        const request_id = cdp.str(m.params, &.{"requestId"}) orelse return;
        const n = p.findNet(request_id) orelse return;
        const why = cdp.str(m.params, &.{"errorText"}) orelse "failed";
        if (n.failed) |old| app.gpa.free(old);
        n.failed = try app.gpa.dupe(u8, why);
    } else if (std.mem.eql(u8, method, "Target.attachedToTarget")) {
        const url = cdp.str(m.params, &.{ "targetInfo", "url" }) orelse "";
        const ty = cdp.str(m.params, &.{ "targetInfo", "type" }) orelse "";
        try p.push(.nav, try std.fmt.allocPrint(arena, "attached {s}: {s}", .{ ty, url }));
    }
}

/// One captured-log line per Document / XHR / Fetch request.
pub fn appendCaptured(app: *App, n: *const NetEntry) Allocator.Error!void {
    const path = try captured.logPath(app.frame.allocator(), app.workspace);
    const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(app.io, .real).toNanoseconds(), std.time.ns_per_ms));
    const line = try captured.renderLine(app.gpa, ts, n.request_id, n.method, n.url, n.headers.items, n.post_data);
    defer app.gpa.free(line);
    history.appendLine(app.gpa, app.io, path, line) catch {};
}

pub fn applyDevice(app: *App, p: *BrowserPane, idx: usize) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (idx >= device_presets.len) return;
    const d = device_presets[idx];
    if (d.width == 0) {
        try send(app, p, "Emulation.clearDeviceMetricsOverride", "{}", .quiet);
        try send(app, p, "Emulation.setUserAgentOverride", "{\"userAgent\":\"\"}", .quiet);
        p.device = null;
        try p.push(.system, "device emulation cleared");
        return;
    }
    const metrics = try std.fmt.allocPrint(arena, "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":{d},\"mobile\":{}}}", .{ d.width, d.height, d.scale, d.mobile });
    try send(app, p, "Emulation.setDeviceMetricsOverride", metrics, .quiet);
    if (d.ua.len > 0) {
        const ua = try std.fmt.allocPrint(arena, "{{\"userAgent\":{f}}}", .{std.json.fmt(d.ua, .{})});
        try send(app, p, "Emulation.setUserAgentOverride", ua, .quiet);
    }
    p.device = idx;
    try p.push(.system, try std.fmt.allocPrint(arena, "emulating: {s} ({d}×{d})", .{ d.name, d.width, d.height }));
}

pub fn applyThrottle(app: *App, p: *BrowserPane, idx: usize) Allocator.Error!void {
    if (idx >= throttles.len) return;
    const t = throttles[idx];
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"offline\":{},\"latency\":{d},\"downloadThroughput\":{d},\"uploadThroughput\":{d}}}", .{ t.offline, t.latency_ms, t.down, t.up });
    try send(app, p, "Network.emulateNetworkConditions", params, .quiet);
    try p.push(.system, try std.fmt.allocPrint(app.frame.allocator(), "network: {s}", .{t.name}));
}

// ─── snapshots ──────────────────────────────────────────────────────────

pub fn captureSnapshot(app: *App, p: *BrowserPane) Allocator.Error!usize {
    const gpa = app.gpa;
    const urls = try gpa.alloc([]u8, p.net.items.len);
    var filled: usize = 0;
    errdefer {
        for (urls[0..filled]) |u| gpa.free(u);
        gpa.free(urls);
    }
    for (p.net.items) |n| {
        urls[filled] = try gpa.dupe(u8, n.url);
        filled += 1;
    }
    const url = try gpa.dupe(u8, p.url);
    errdefer gpa.free(url);
    try p.snapshots.append(gpa, .{ .url = url, .net_urls = urls, .at_ms = app.now_ms });
    return p.snapshots.items.len;
}

/// Lines `-` / `+` / ` ` comparing the latest snapshot to now.
pub fn diffSnapshot(app: *App, p: *BrowserPane) Allocator.Error!?[]const u8 {
    if (p.snapshots.items.len == 0) return null;
    const arena = app.frame.allocator();
    const snap = p.snapshots.items[p.snapshots.items.len - 1];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendFmt(arena, &out, "# browser snapshot diff — #{d} vs now\n\nurl: {s} → {s}\n\n## network\n\n", .{ p.snapshots.items.len, snap.url, p.url });
    for (snap.net_urls) |u| {
        var still = false;
        for (p.net.items) |n| if (std.mem.eql(u8, n.url, u)) {
            still = true;
        };
        try appendFmt(arena, &out, "{s} {s}\n", .{ if (still) " " else "-", u });
    }
    for (p.net.items) |n| {
        var was = false;
        for (snap.net_urls) |u| if (std.mem.eql(u8, n.url, u)) {
            was = true;
        };
        if (!was) try appendFmt(arena, &out, "+ {s}\n", .{n.url});
    }
    return out.items;
}

// ─── keys / mouse / draw ────────────────────────────────────────────────

pub fn handleKey(app: *App, id: PaneId, p: *BrowserPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    if (k.mods.ctrl and k.code == .char and k.code.char == 'r') {
        try runCmd(app, .@"browser.url_history");
        return true;
    }
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    if (p.filter_focused) return filterKey(app, p, k);
    const page: i64 = @intCast(@max(app.pane_rows, 1));
    switch (k.code) {
        .esc => {
            if (p.filter.items.len > 0) {
                p.filter.clearRetainingCapacity();
                p.filter_caret = 0;
                try moveSel(p, 0);
                return true;
            }
            if (p.panel != .log) {
                p.panel = .log;
                return true;
            }
            return false;
        },
        .up => try moveSel(p, -1),
        .down => try moveSel(p, 1),
        .page_up => try moveSel(p, -page),
        .page_down => try moveSel(p, page),
        .enter => if (p.panel == .net) try resendSelected(app, p),
        .char => |c| switch (c) {
            '/' => p.filter_focused = true,
            'j' => try moveSel(p, 1),
            'k' => try moveSel(p, -1),
            'g' => try runCmd(app, .@"browser.navigate"),
            'e' => try evalPrompt(app),
            'r' => try runCmd(app, .@"browser.reload"),
            'n' => p.panel = if (p.panel == .net) .log else .net,
            'K' => try runCmd(app, .@"browser.cookies"),
            'L' => try runCmd(app, .@"browser.storage"),
            'P' => try runCmd(app, .@"browser.perf"),
            'D' => try runCmd(app, .@"browser.dom"),
            'm' => try runCmd(app, .@"browser.device_picker"),
            's' => try runCmd(app, .@"browser.screenshot"),
            'y' => try copySelectedCurl(app, p),
            'd' => if (p.panel == .cookies) try runCmd(app, .@"browser.delete_cookie") else if (p.panel == .storage) try runCmd(app, .@"browser.delete_storage"),
            'a' => if (p.panel == .cookies) try runCmd(app, .@"browser.add_cookie") else if (p.panel == .storage) try runCmd(app, .@"browser.add_storage"),
            'q' => try app.closePane(id, true),
            else => return false,
        },
        else => return false,
    }
    return true;
}

/// Keys while the filter has focus: esc clears then blurs, enter blurs,
/// the arrows still move the selection, everything else edits the text.
/// A changed filter keeps the selection on a visible row.
fn filterKey(app: *App, p: *BrowserPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => {
            if (p.filter.items.len > 0) {
                p.filter.clearRetainingCapacity();
                p.filter_caret = 0;
                try moveSel(p, 0);
            } else p.filter_focused = false;
            return true;
        },
        .enter => {
            p.filter_focused = false;
            return true;
        },
        .up => {
            try moveSel(p, -1);
            return true;
        },
        .down => {
            try moveSel(p, 1);
            return true;
        },
        else => {},
    }
    switch (try text_field.handleKey(&p.filter, &p.filter_caret, app.gpa, k)) {
        .ignored => return false,
        .moved => return true,
        .changed => {
            try moveSel(p, 0);
            return true;
        },
    }
}

fn runCmd(app: *App, cmd: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = cmd }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Case-insensitive substring; an empty needle matches everything.
fn matches(needle: []const u8, hay: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// The unfiltered indices of the current panel's rows that pass the
/// filter, in order. Network rows match on method, url, status and
/// mime; the row panels and the log on their text.
pub fn visibleIndices(arena: Allocator, p: *const BrowserPane) Allocator.Error![]usize {
    const needle = std.mem.trim(u8, p.filter.items, " \t");
    var out: std.ArrayListUnmanaged(usize) = .empty;
    switch (p.panel) {
        .log => for (p.log.items, 0..) |l, i| {
            if (matches(needle, l.text)) try out.append(arena, i);
        },
        .net => for (p.net.items, 0..) |n, i| {
            var status_buf: [24]u8 = undefined;
            const status: []const u8 = if (n.failed) |f| f else if (n.status) |st| (std.fmt.bufPrint(&status_buf, "{d}", .{st}) catch "") else "";
            if (matches(needle, n.method) or matches(needle, n.url) or matches(needle, status) or matches(needle, n.mime orelse "")) try out.append(arena, i);
        },
        .cookies => for (p.cookies.items, 0..) |r, i| {
            if (matches(needle, r.text)) try out.append(arena, i);
        },
        .storage => for (p.storage.items, 0..) |r, i| {
            if (matches(needle, r.text)) try out.append(arena, i);
        },
        .dom => for (p.dom.items, 0..) |r, i| {
            if (matches(needle, r.text)) try out.append(arena, i);
        },
        .perf => for (p.perf.items, 0..) |l, i| {
            if (matches(needle, l)) try out.append(arena, i);
        },
    }
    return out.items;
}

/// The selection field the current panel moves.
fn selOf(p: *BrowserPane) ?*usize {
    return switch (p.panel) {
        .net => &p.net_sel,
        .cookies => &p.cookies_sel,
        .storage => &p.storage_sel,
        .dom => &p.dom_sel,
        .log, .perf => null,
    };
}

/// Step the selection `delta` rows through the narrowed order; the log
/// and perf panels scroll instead. A selection the filter hid snaps to
/// the first visible row.
fn moveSel(p: *BrowserPane, delta: i64) Allocator.Error!void {
    const sel = selOf(p) orelse {
        if (delta < 0) p.scroll += @intCast(-delta) else p.scroll -|= @intCast(delta);
        return;
    };
    var scratch = std.heap.ArenaAllocator.init(p.gpa);
    defer scratch.deinit();
    const visible = try visibleIndices(scratch.allocator(), p);
    if (visible.len == 0) return;
    var pos: ?usize = null;
    for (visible, 0..) |idx, i| if (idx == sel.*) {
        pos = i;
        break;
    };
    const cur: i64 = if (pos) |x| @intCast(x) else -1;
    const last: i64 = @intCast(visible.len - 1);
    const next: i64 = if (pos == null) 0 else std.math.clamp(cur + delta, 0, last);
    sel.* = visible[@intCast(next)];
}

pub fn evalPrompt(app: *App) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Evaluate in page"), .purpose = .browser_eval } };
    app.focus = .overlay;
}

fn copySelectedCurl(app: *App, p: *BrowserPane) Allocator.Error!void {
    if (p.panel != .net) {
        app.toast("browser: open the network panel (n) and pick a request", .{});
        return;
    }
    const n = p.selectedNet() orelse return;
    var req = try n.toRequest(app.frame.allocator());
    const curl = try parse.toCurl(app.frame.allocator(), &req);
    try app.clipboard.set(curl, false);
    app.toast("copied as curl: {s} {s}", .{ n.method, history.shortUrl(n.url) });
}

fn resendSelected(app: *App, p: *BrowserPane) Allocator.Error!void {
    const n = p.selectedNet() orelse return;
    const req = try n.toRequest(app.gpa);
    _ = http.openFromRequest(app, req, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

pub fn scrollBy(p: *BrowserPane, delta: i32) void {
    moveSel(p, delta) catch {};
}

pub fn click(app: *App, p: *BrowserPane, hit_id: u32) Allocator.Error!void {
    app.needs_render = true;
    if (hit_id == view.hit_filter) {
        p.filter_focused = true;
        return;
    }
    if (hit_id >= view.hit_row_base) {
        const idx = hit_id - view.hit_row_base;
        switch (p.panel) {
            .net => {
                if (idx == p.net_sel) try resendSelected(app, p) else p.net_sel = idx;
            },
            .cookies => p.cookies_sel = idx,
            .storage => p.storage_sel = idx,
            .dom => p.dom_sel = idx,
            .log, .perf => {},
        }
        return;
    }
    if (hit_id >= view.hit_panel_base and hit_id < view.hit_panel_base + view.Panel.all.len) {
        const which = view.Panel.all[hit_id - view.hit_panel_base];
        switch (which) {
            .cookies => try runCmd(app, .@"browser.cookies"),
            .storage => try runCmd(app, .@"browser.storage"),
            .perf => try runCmd(app, .@"browser.perf"),
            .dom => try runCmd(app, .@"browser.dom"),
            .log, .net => p.panel = which,
        }
    }
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *BrowserPane, area: Rect) Allocator.Error!void {
    const arena = ui.arena;
    const focused = app.active == id and app.focus == .pane;
    const visible = try visibleIndices(arena, p);
    var log: []view.LogLine = &.{};
    var net: []view.NetRow = &.{};
    var rows: [][]const u8 = &.{};
    switch (p.panel) {
        .log => log = try logRows(arena, p, visible),
        .net => {
            net = try arena.alloc(view.NetRow, visible.len);
            for (visible, 0..) |idx, i| {
                const n = p.net.items[idx];
                net[i] = .{
                    .index = idx,
                    .method = n.method,
                    .url = history.shortUrl(n.url),
                    .status = if (n.failed != null) "✗" else if (n.status) |st| try std.fmt.allocPrint(arena, "{d}", .{st}) else "…",
                    .mime = n.mime orelse "",
                };
            }
        },
        .cookies => rows = try rowTexts(arena, p.cookies.items, visible),
        .storage => rows = try rowTexts(arena, p.storage.items, visible),
        .dom => rows = try rowTexts(arena, p.dom.items, visible),
        .perf => {
            rows = try arena.alloc([]const u8, visible.len);
            for (visible, 0..) |idx, i| rows[i] = p.perf.items[idx];
        },
    }
    const total: usize = switch (p.panel) {
        .log => p.log.items.len,
        .net => p.net.items.len,
        .cookies => p.cookies.items.len,
        .storage => p.storage.items.len,
        .dom => p.dom.items.len,
        .perf => p.perf.items.len,
    };
    const sel: usize = switch (p.panel) {
        .net => p.net_sel,
        .cookies => p.cookies_sel,
        .storage => p.storage_sel,
        .dom => p.dom_sel,
        .log, .perf => 0,
    };
    const out = view.draw(ui, id, area, .{
        .url = p.url,
        .state = @tagName(p.state),
        .port = p.port,
        .panel = p.panel,
        .log = log,
        .net = net,
        .rows = rows,
        .row_index = visible,
        .total = total,
        .sel = sel,
        .scroll = &p.scroll,
        .focused = focused,
        .device = if (p.device) |d| device_presets[d].name else null,
        .filter = p.filter.items,
        .filter_caret = p.filter_caret,
        .filter_focused = p.filter_focused,
    });
    if (app.active == id) {
        app.pane_rows = @max(area.h, 1);
        app.pane_cols = @max(area.w, 1);
        if (focused) if (out.caret) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        };
    }
    try syncHighlight(app, p, if (p.panel == .dom) out.hovered_row else null);
}

/// A log entry of several lines paints as that many rows, up to
/// `max_entry_rows`; the rest is one `⏎ +N more lines` row, so nothing
/// is cut without a mark.
pub const max_entry_rows = 50;

/// The rows one log entry paints as.
pub fn entryRows(text: []const u8) usize {
    const lines = std.mem.count(u8, text, "\n") + 1;
    return if (lines > max_entry_rows) max_entry_rows + 1 else lines;
}

fn logRows(arena: Allocator, p: *const BrowserPane, visible: []const usize) Allocator.Error![]view.LogLine {
    var out: std.ArrayListUnmanaged(view.LogLine) = .empty;
    for (visible) |idx| {
        const l = p.log.items[idx];
        var it = std.mem.splitScalar(u8, l.text, '\n');
        var shown: usize = 0;
        while (it.next()) |line| {
            if (shown == max_entry_rows) {
                const rest = std.mem.count(u8, it.rest(), "\n") + 2;
                try out.append(arena, .{ .kind = .system, .text = try std.fmt.allocPrint(arena, "  ⏎ +{d} more lines", .{rest}) });
                break;
            }
            // Continuation lines are indented under the entry's first.
            try out.append(arena, .{ .kind = l.kind, .text = if (shown == 0) line else try std.fmt.allocPrint(arena, "  {s}", .{line}) });
            shown += 1;
        }
    }
    return out.items;
}

/// Chrome's overlay follows the pointer over the DOM rows: one
/// `Overlay.highlightNode` when a new row comes under it, one
/// `Overlay.hideHighlight` when it leaves them all (or the panel is no
/// longer the DOM).
fn syncHighlight(app: *App, p: *BrowserPane, hovered: ?usize) Allocator.Error!void {
    if (hovered) |idx| {
        if (idx >= p.dom.items.len) return syncHighlight(app, p, null);
        if (p.hover_dom == idx) return;
        const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"nodeId\":{s},\"highlightConfig\":{s}}}", .{ p.dom.items[idx].key, highlight_config });
        try send(app, p, "Overlay.highlightNode", params, .quiet);
        p.hover_dom = idx;
    } else if (p.hover_dom != null) {
        try send(app, p, "Overlay.hideHighlight", "{}", .quiet);
        p.hover_dom = null;
    }
}

/// DevTools' inspect colours: content blue, padding green, border
/// yellow, margin orange, with the size tooltip.
const highlight_config = "{\"showInfo\":true,\"contentColor\":{\"r\":111,\"g\":168,\"b\":220,\"a\":0.66},\"paddingColor\":{\"r\":147,\"g\":196,\"b\":125,\"a\":0.55},\"borderColor\":{\"r\":255,\"g\":229,\"b\":153,\"a\":0.66},\"marginColor\":{\"r\":246,\"g\":178,\"b\":107,\"a\":0.66}}";

fn rowTexts(arena: Allocator, rows: []const Row, visible: []const usize) Allocator.Error![][]const u8 {
    const out = try arena.alloc([]const u8, visible.len);
    for (visible, 0..) |idx, i| out[i] = rows[idx].text;
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "events route into the log, the net list, the url and the captured log; replies by purpose" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const gpa = testing.allocator;
    const shared = try gpa.create(Shared);
    shared.* = .{ .io = testing.io };
    var pane: BrowserPane = .{ .gpa = gpa, .url = try gpa.dupe(u8, "about:blank"), .shared = shared, .title_buf = try gpa.dupe(u8, "browser"), .profile_dir = try gpa.dupe(u8, "/tmp/x"), .headless = true };
    const id = try app.panes.add(.{ .browser = pane });
    pane = undefined;
    app.showPane(id);
    const p = app.panes.get(id).?.asBrowser().?;
    const mk = struct {
        fn ev(g: Allocator, pid: PaneId, text: []const u8) !*CdpEvent {
            const box = try g.create(CdpEvent);
            box.* = .{ .pane = pid, .kind = .{ .message = try g.dupe(u8, text) } };
            return box;
        }
    };
    try handle(&app, try mk.ev(gpa, id, "{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":\"error\",\"args\":[{\"type\":\"string\",\"value\":\"boom\"},{\"type\":\"number\",\"value\":3}]}}"));
    try testing.expectEqualStrings("console.error: boom 3", p.log.items[p.log.items.len - 1].text);
    try testing.expect(p.log.items[p.log.items.len - 1].kind == .console_err);
    try handle(&app, try mk.ev(gpa, id, "{\"method\":\"Page.frameNavigated\",\"params\":{\"frame\":{\"id\":\"F\",\"url\":\"https://example.com/home\"}}}"));
    try testing.expectEqualStrings("https://example.com/home", p.url);
    try testing.expectEqualStrings("browser … example.com/home", p.title());
    try handle(&app, try mk.ev(gpa, id, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"r1\",\"type\":\"XHR\",\"request\":{\"url\":\"https://api.example.com/items?x=1\",\"method\":\"POST\",\"headers\":{\"accept\":\"*/*\",\":authority\":\"x\"},\"postData\":\"{}\"}}}"));
    try handle(&app, try mk.ev(gpa, id, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"r2\",\"type\":\"Image\",\"request\":{\"url\":\"https://x/a.png\",\"method\":\"GET\"}}}"));
    try handle(&app, try mk.ev(gpa, id, "{\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"r1\",\"response\":{\"status\":201,\"mimeType\":\"application/json\"}}}"));
    try testing.expectEqual(@as(usize, 1), p.net.items.len);
    try testing.expectEqual(@as(?i64, 201), p.net.items[0].status);
    var req = try p.net.items[0].toRequest(gpa);
    defer req.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), req.headers.items.len);
    try testing.expectEqualStrings("{}", req.body.?);
    const log = try tmp.dir.readFileAlloc(testing.io, ".rqst/captured/log.jsonl", gpa, .limited(1 << 16));
    defer gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "\"request_id\":\"r1\"") != null);
    // A queued eval flushes on connect and its reply lands as `= value`.
    try eval(&app, p, "1+1", .eval);
    try testing.expectEqual(@as(usize, 1), p.queued.items.len);
    try p.pending.put(gpa, 7, .eval);
    try handle(&app, try mk.ev(gpa, id, "{\"id\":7,\"result\":{\"result\":{\"type\":\"number\",\"value\":2}}}"));
    try testing.expectEqualStrings("= 2", p.log.items[p.log.items.len - 1].text);
    try p.pending.put(gpa, 8, .cookies);
    try handle(&app, try mk.ev(gpa, id, "{\"id\":8,\"result\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\"example.com\",\"path\":\"/\"}]}}"));
    try testing.expect(p.panel == .cookies);
    try testing.expectEqualStrings("sid\texample.com\t/", p.cookies.items[0].key);
    try p.pending.put(gpa, 9, .dom);
    try handle(&app, try mk.ev(gpa, id, "{\"id\":9,\"result\":{\"root\":{\"nodeId\":1,\"nodeName\":\"#document\",\"children\":[{\"nodeId\":2,\"nodeName\":\"HTML\",\"children\":[{\"nodeId\":3,\"nodeName\":\"DIV\",\"attributes\":[\"id\",\"app\",\"class\",\"main x\"]}]}]}}}"));
    try testing.expectEqual(@as(usize, 2), p.dom.items.len);
    try testing.expectEqualStrings("  div#app.main", p.dom.items[1].text);
    const count = try captureSnapshot(&app, p);
    try testing.expectEqual(@as(usize, 1), count);
    const diff = (try diffSnapshot(&app, p)).?;
    try testing.expect(std.mem.indexOf(u8, diff, "  https://api.example.com/items?x=1") != null);
    try handle(&app, try mk.ev(gpa, id, "{\"id\":99,\"result\":{}}"));
    const closed = try gpa.create(CdpEvent);
    closed.* = .{ .pane = id, .kind = .{ .closed = try gpa.dupe(u8, "page closed") } };
    try handle(&app, closed);
    try testing.expect(p.state == .closed);
}

/// A pane with no Chrome behind it: `send` queues, nothing connects.
fn testPane(app: *App) !PaneId {
    const gpa = testing.allocator;
    const shared = try gpa.create(Shared);
    shared.* = .{ .io = testing.io };
    var pane: BrowserPane = .{ .gpa = gpa, .url = try gpa.dupe(u8, "about:blank"), .shared = shared, .title_buf = try gpa.dupe(u8, "browser"), .profile_dir = try gpa.dupe(u8, "/tmp/x"), .headless = true };
    const id = try app.panes.add(.{ .browser = pane });
    pane = undefined;
    app.showPane(id);
    return id;
}

fn netEvent(gpa: Allocator, pid: PaneId, request_id: []const u8, method: []const u8, url: []const u8) !*CdpEvent {
    const box = try gpa.create(CdpEvent);
    box.* = .{ .pane = pid, .kind = .{ .message = try std.fmt.allocPrint(gpa, "{{\"method\":\"Network.requestWillBeSent\",\"params\":{{\"requestId\":\"{s}\",\"type\":\"XHR\",\"request\":{{\"url\":\"{s}\",\"method\":\"{s}\"}}}}}}", .{ request_id, url, method }) } };
    return box;
}

test "the filter narrows the network rows and the selection steps through the narrowed order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    try handle(&app, try netEvent(gpa, id, "r1", "GET", "https://a.example.com/items"));
    try handle(&app, try netEvent(gpa, id, "r2", "POST", "https://b.example.com/users"));
    try handle(&app, try netEvent(gpa, id, "r3", "GET", "https://c.example.com/items/7"));
    p.panel = .net;
    try p.filter.appendSlice(gpa, "ITEMS");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, try visibleIndices(arena.allocator(), p));
    // j skips the hidden row; k comes back; the ends clamp.
    try testing.expect(try handleKey(&app, id, p, Key.char('j')));
    try testing.expectEqual(@as(usize, 2), p.net_sel);
    _ = try handleKey(&app, id, p, Key.char('j'));
    try testing.expectEqual(@as(usize, 2), p.net_sel);
    _ = try handleKey(&app, id, p, Key.char('k'));
    try testing.expectEqual(@as(usize, 0), p.net_sel);
    // A selection the filter hides snaps to the first visible row.
    p.net_sel = 1;
    p.filter.clearRetainingCapacity();
    try p.filter.appendSlice(gpa, "post");
    try moveSel(p, 0);
    try testing.expectEqual(@as(usize, 1), p.net_sel);
    try p.filter.appendSlice(gpa, "x");
    try testing.expectEqual(@as(usize, 0), (try visibleIndices(arena.allocator(), p)).len);
    // The method matches too; other panels narrow on their text.
    p.filter.clearRetainingCapacity();
    try p.filter.appendSlice(gpa, "get");
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, try visibleIndices(arena.allocator(), p));
    try p.dom.append(gpa, .{ .text = try gpa.dupe(u8, "html"), .key = try gpa.dupe(u8, "2") });
    try p.dom.append(gpa, .{ .text = try gpa.dupe(u8, "  div#app"), .key = try gpa.dupe(u8, "3") });
    p.panel = .dom;
    p.filter.clearRetainingCapacity();
    try p.filter.appendSlice(gpa, "#app");
    try testing.expectEqualSlices(usize, &.{1}, try visibleIndices(arena.allocator(), p));
}

test "/ focuses the filter, typing narrows, esc clears then blurs, enter blurs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    try handle(&app, try netEvent(gpa, id, "r1", "GET", "https://a.example.com/items"));
    try handle(&app, try netEvent(gpa, id, "r2", "POST", "https://b.example.com/users"));
    p.panel = .net;
    try testing.expect(try handleKey(&app, id, p, Key.char('/')));
    try testing.expect(p.filter_focused);
    // Letters the pane would otherwise act on go to the text now.
    try testing.expect(try handleKey(&app, id, p, Key.char('u')));
    try testing.expect(try handleKey(&app, id, p, Key.char('s')));
    try testing.expectEqualStrings("us", p.filter.items);
    try testing.expectEqual(@as(usize, 1), p.net_sel);
    try testing.expect(p.panel == .net);
    // The arrows still move the selection while typing.
    try testing.expect(try handleKey(&app, id, p, Key.named(.up)));
    try testing.expectEqual(@as(usize, 1), p.net_sel);
    // A ctrl chord is not the filter's.
    try testing.expect(!try handleKey(&app, id, p, Key.ctrl('x')));
    try testing.expect(try handleKey(&app, id, p, Key.named(.esc)));
    try testing.expectEqualStrings("", p.filter.items);
    try testing.expect(p.filter_focused);
    try testing.expect(try handleKey(&app, id, p, Key.named(.esc)));
    try testing.expect(!p.filter_focused);
    _ = try handleKey(&app, id, p, Key.char('/'));
    _ = try handleKey(&app, id, p, Key.char('a'));
    try testing.expect(try handleKey(&app, id, p, Key.named(.enter)));
    try testing.expect(!p.filter_focused);
    try testing.expectEqualStrings("a", p.filter.items);
    // Switching panels keeps the text; esc from the list clears a stale filter first.
    _ = try handleKey(&app, id, p, Key.char('n'));
    try testing.expect(p.panel == .log);
    try testing.expectEqualStrings("a", p.filter.items);
    try testing.expect(try handleKey(&app, id, p, Key.named(.esc)));
    try testing.expectEqualStrings("", p.filter.items);
    // The pill click focuses it.
    try click(&app, p, view.hit_filter);
    try testing.expect(p.filter_focused);
}

test "hovering a DOM row highlights its node once; leaving the rows hides the highlight once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    try p.dom.append(gpa, .{ .text = try gpa.dupe(u8, "html"), .key = try gpa.dupe(u8, "2") });
    try p.dom.append(gpa, .{ .text = try gpa.dupe(u8, "  div#app"), .key = try gpa.dupe(u8, "31") });
    p.panel = .dom;
    var f = try @import("../ui/test_fixture.zig").init(80, 20);
    defer f.deinit();
    // Rows start at y = 3 (header, strip, pill).
    f.hover = .{ .x = 5, .y = 4 };
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 1), p.queued.items.len);
    try testing.expectEqualStrings("Overlay.highlightNode", p.queued.items[0].method);
    try testing.expect(std.mem.startsWith(u8, p.queued.items[0].params, "{\"nodeId\":31,"));
    try testing.expectEqual(@as(?usize, 1), p.hover_dom);
    // Still on the same row: nothing more is sent.
    f.hits.reset();
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 1), p.queued.items.len);
    // Off the rows: one hide.
    f.hover = .{ .x = 5, .y = 15 };
    f.hits.reset();
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 2), p.queued.items.len);
    try testing.expectEqualStrings("Overlay.hideHighlight", p.queued.items[1].method);
    try testing.expect(p.hover_dom == null);
    f.hits.reset();
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 2), p.queued.items.len);
    // A panel that is not the DOM hides a highlight it left behind.
    f.hover = .{ .x = 5, .y = 3 };
    f.hits.reset();
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 3), p.queued.items.len);
    p.panel = .log;
    f.hits.reset();
    try draw(&app, f.ui(), id, p, f.full());
    try testing.expectEqual(@as(usize, 4), p.queued.items.len);
    try testing.expectEqualStrings("Overlay.hideHighlight", p.queued.items[3].method);
}

/// A stand-in Chrome script in `root` that runs `body`, for `test_binary`
/// or `cdp.spawn`. Its path is on `arena`.
fn standInScript(arena: Allocator, root: []const u8, name: []const u8, body: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ root, name });
    const text = try std.fmt.allocPrint(arena, "#!/bin/sh\n{s}\n", .{body});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text });
    const f = try Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .read_write });
    defer f.close(testing.io);
    try f.setPermissions(testing.io, .fromMode(0o755));
    return path;
}

/// A stand-in for Chrome: a child that stays up until it is killed,
/// owned by the pane the way a real launch is.
fn standInChrome(p: *BrowserPane, root: []const u8) !std.process.Child.Id {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bin = try standInScript(arena.allocator(), root, "stand-in-chrome", "exec /bin/sleep 30");
    const l = try cdp.spawn(testing.allocator, testing.io, &std.process.Environ.Map.init(testing.allocator), .{ .profile_dir = root, .binary = bin });
    p.shared.launch = l;
    return l.child.id.?;
}

test "closing a browser pane while its Chrome runs takes the child with it — forceClosePane and the tab's ✕ both, and neither panics" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();

    // The crash the user hit: `dispatch.mouse` → `closePane` →
    // `forceClosePane` → `Pane.deinit` → `BrowserPane.deinit` →
    // `Launch.kill`, with Chrome still running.
    const id = try testPane(&app);
    const pid = try standInChrome(app.panes.get(id).?.asBrowser().?, pbuf[0..n]);
    try app.forceClosePane(id);
    try testing.expect(app.panes.get(id) == null);
    try testing.expect(child_os.goneWithin(testing.io, pid, .fromSeconds(10)));

    // The same close through the tab strip's ✕, which is how it was hit.
    const id2 = try testPane(&app);
    const pid2 = try standInChrome(app.panes.get(id2).?.asBrowser().?, pbuf[0..n]);
    try app.render();
    const spot = blk: {
        var y: u16 = 0;
        while (y < app.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < app.screen.width) : (x += 1) {
                const hit = app.hits.at(x, y) orelse continue;
                if (hit != .tab_close) continue;
                const layout = app.layouts.current();
                const lid = (try layout.leafAt(app.frame.allocator(), hit.tab_close.leaf)) orelse continue;
                const leaf = layout.leaf(lid) orelse continue;
                if (hit.tab_close.idx >= leaf.tabs.items.len) continue;
                if (leaf.tabs.items[hit.tab_close.idx] != id2) continue;
                break :blk .{ .x = x, .y = y };
            }
        }
        break :blk null;
    };
    try testing.expect(spot != null);
    try app.handle(.{ .mouse = .{ .x = spot.?.x, .y = spot.?.y, .kind = .press, .button = .left } });
    try testing.expect(app.panes.get(id2) == null);
    try testing.expect(child_os.goneWithin(testing.io, pid2, .fromSeconds(10)));
}

/// Runs the half of a pane's close that can block — `shutdown`, then
/// the join of the worker — on its own thread and says when it came
/// back: a close that hangs then fails the test at the watchdog instead
/// of hanging the suite. The rest of the close (`forceClosePane`, which
/// must run on the UI thread) follows on the test's thread.
const Closer = struct {
    p: *BrowserPane,
    done: Io.Event = .unset,

    fn run(self: *Closer) void {
        self.p.shutdown();
        if (self.p.thread) |t| t.join();
        self.p.thread = null;
        self.done.set(testing.io);
    }
};

test "closing a browser pane whose Chrome has not reported its DevTools port comes back at once and takes that Chrome with it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    // No `defer app.deinit()`: past the watchdog the close is wedged in
    // the closer thread and must not be raced by a second teardown.
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A wedged start: running, no DevTools line, and a grandchild that
    // keeps stderr open — so neither a port nor an EOF ever arrives.
    const body = try std.fmt.allocPrint(arena.allocator(), "/bin/sleep 30 & echo $! > '{s}/grandchild.pid'; exec /bin/sleep 30", .{root});
    test_binary = try standInScript(arena.allocator(), root, "wedged-chrome", body);
    defer test_binary = null;
    defer {
        var gbuf: [32]u8 = undefined;
        if (tmp.dir.readFile(testing.io, "grandchild.pid", &gbuf)) |txt| {
            if (std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, txt, " \n"), 10)) |g| std.posix.kill(g, .KILL) catch {} else |_| {}
        } else |_| {}
    }
    const id = try open(&app, "http://127.0.0.1:9/");
    const p = app.panes.get(id).?.asBrowser().?;
    // The launch is the pane's as soon as Chrome is spawned.
    var pid: ?std.process.Child.Id = null;
    var tries: usize = 0;
    while (pid == null and tries < 500) : (tries += 1) {
        p.shared.lock.lockUncancelable(testing.io);
        if (p.shared.launch) |l| pid = l.child.id;
        p.shared.lock.unlock(testing.io);
        if (pid == null) testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(pid != null);
    testing.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try testing.expect(p.state == .launching);
    var closer: Closer = .{ .p = p };
    const t = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    // A regression leaves the close parked on the worker; leave it there.
    if (!waitSet(&closer.done, .fromSeconds(10))) return error.CloseWaitedOnAWedgedChrome;
    t.join();
    try app.forceClosePane(id);
    try testing.expect(app.panes.get(id) == null);
    try testing.expect(child_os.goneWithin(testing.io, pid.?, .fromSeconds(10)));
    app.deinit();
}

/// `ev` set within `limit` (spurious wakeups ride out the deadline).
fn waitSet(ev: *Io.Event, limit: Io.Duration) bool {
    const start = Io.Timestamp.now(testing.io, .awake);
    while (!ev.isSet()) {
        const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake));
        if (elapsed.nanoseconds >= limit.nanoseconds) return false;
        ev.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
    }
    return true;
}

/// `testPane`, on a given profile directory.
fn testPaneAt(app: *App, dir: []const u8, ephemeral: bool) !PaneId {
    const id = try testPane(app);
    const p = app.panes.get(id).?.asBrowser().?;
    testing.allocator.free(p.profile_dir);
    p.profile_dir = try testing.allocator.dupe(u8, dir);
    p.ephemeral = ephemeral;
    return id;
}

test "a new pane's profile suffix is one no open pane uses: A, B, close A, then C does not land on B's profile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const arena = app.frame.allocator();
    const first = try pickProfile(&app, arena);
    try testing.expect(std.mem.endsWith(u8, first.dir, "/.mnml/chrome-profile"));
    const a = try testPaneAt(&app, first.dir, false);
    const second = try pickProfile(&app, arena);
    try testing.expect(std.mem.endsWith(u8, second.dir, "/.mnml/chrome-profile-1"));
    _ = try testPaneAt(&app, second.dir, false);
    try app.forceClosePane(a);
    // One pane open, on `-1`: the count says 1, the free suffix is the base.
    const third = try pickProfile(&app, arena);
    try testing.expectEqualStrings(first.dir, third.dir);
    try testing.expect(third.note == null);
}

test "a profile a live Chrome holds is skipped for the next free suffix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const arena = app.frame.allocator();
    const base = try profileBase(&app, arena);
    try Io.Dir.cwd().createDirPath(testing.io, base);
    // Another mnml's pane, say: alive, and our child, so not an orphan.
    var holder = try std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer holder.kill(testing.io);
    var d = try Io.Dir.cwd().openDir(testing.io, base, .{});
    defer d.close(testing.io);
    const target = try std.fmt.allocPrint(arena, "host-{d}", .{holder.id.?});
    try d.symLink(testing.io, target, "SingletonLock", .{});
    const picked = try pickProfile(&app, arena);
    try testing.expect(std.mem.endsWith(u8, picked.dir, "/.mnml/chrome-profile-1"));
    try testing.expect(!child_os.gone(holder.id.?));
}

test "a Chrome an earlier mnml left running on the profile (after a kill -9) is stopped, and the pane gets that profile with a note saying so" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const arena = app.frame.allocator();
    const base = try profileBase(&app, arena);
    try Io.Dir.cwd().createDirPath(testing.io, base);
    // The orphan: a launch line on `base`, adopted by launchd.
    const script = try std.fs.path.join(arena, &.{ root, "orphan-chrome" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = script, .data = "#!/bin/sh\nwhile :; do /bin/sleep 1; done\n" });
    const pidfile = try std.fs.path.join(arena, &.{ root, "orphan.pid" });
    const line = try std.fmt.allocPrint(arena, "/bin/sh '{s}' --remote-debugging-port=0 '--user-data-dir={s}' </dev/null >/dev/null 2>&1 & echo $! > '{s}'", .{ script, base, pidfile });
    var launcher = try std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sh", "-c", line }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = try launcher.wait(testing.io);
    var nbuf: [32]u8 = undefined;
    const orphan = try std.fmt.parseInt(profile.Pid, std.mem.trim(u8, try Io.Dir.cwd().readFile(testing.io, pidfile, &nbuf), " \n"), 10);
    defer std.posix.kill(orphan, .KILL) catch {};
    var d = try Io.Dir.cwd().openDir(testing.io, base, .{});
    defer d.close(testing.io);
    try d.symLink(testing.io, try std.fmt.allocPrint(arena, "host-{d}", .{orphan}), "SingletonLock", .{});
    // launchd adopts it asynchronously.
    var tries: usize = 0;
    while (profile.probe(testing.allocator, testing.io, base) != .orphan and tries < 100) : (tries += 1) testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    const picked = try pickProfile(&app, arena);
    try testing.expectEqualStrings(base, picked.dir);
    try testing.expect(std.mem.indexOf(u8, picked.note.?, "stopped a Chrome an earlier session left running") != null);
    try testing.expect(child_os.goneWithin(testing.io, orphan, .fromSeconds(10)));
}

test "ephemeral profiles: each open gets its own, a closed pane takes its profile with it, and wipe_profile clears what a crash left" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    app.cfg.browser.profile_mode = .ephemeral;
    const arena = app.frame.allocator();
    const one = try pickProfile(&app, arena);
    const two = try pickProfile(&app, arena);
    try testing.expect(!std.mem.eql(u8, one.dir, two.dir));
    try testing.expect(std.mem.indexOf(u8, one.dir, "/.mnml/" ++ ephemeral_prefix) != null);
    try Io.Dir.cwd().createDirPath(testing.io, one.dir);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ one.dir, "Cookies" }), .data = "sid=secret" });
    const id = try testPaneAt(&app, one.dir, true);
    try app.forceClosePane(id);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, one.dir, .{}));
    // Left by a crash: no pane will close it. wipe_profile does, and
    // leaves the workspace-mode profile alone.
    try Io.Dir.cwd().createDirPath(testing.io, two.dir);
    const kept = try std.fs.path.join(arena, &.{ root, ".mnml", "chrome-profile" });
    try Io.Dir.cwd().createDirPath(testing.io, kept);
    try command.run(&app, .{ .static = .@"browser.wipe_profile" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, two.dir, .{}));
    try Io.Dir.cwd().access(testing.io, kept, .{});
}

test "wipe_profile in workspace mode clears the profile and its -N siblings, not the ephemeral or proxy ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const arena = app.frame.allocator();
    const mn = try std.fs.path.join(arena, &.{ root, ".mnml" });
    for ([_][]const u8{ "chrome-profile", "chrome-profile-1", "chrome-profile-12", "chrome-profile-ephemeral-ab12", "chrome-profile-proxy-99" }) |name| try Io.Dir.cwd().createDirPath(testing.io, try std.fs.path.join(arena, &.{ mn, name }));
    try command.run(&app, .{ .static = .@"browser.wipe_profile" });
    for ([_][]const u8{ "chrome-profile", "chrome-profile-1", "chrome-profile-12" }) |name| try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ mn, name }), .{}));
    for ([_][]const u8{ "chrome-profile-ephemeral-ab12", "chrome-profile-proxy-99" }) |name| try Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ mn, name }), .{});
}

test "a reply too large to take fails its own request with a note, the session stays up, and the DOM panel asks for fewer levels" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    p.state = .connected;
    const tooLong = struct {
        fn ev(g: Allocator, pid: PaneId, rid: ?i64, len: u64) !*CdpEvent {
            const box = try g.create(CdpEvent);
            box.* = .{ .pane = pid, .kind = .{ .too_long = .{ .id = rid, .method = null, .len = len } } };
            return box;
        }
    };
    try p.pending.put(gpa, 120, .eval);
    try handle(&app, try tooLong.ev(gpa, id, 120, 73_523_893));
    try testing.expectEqualStrings("eval: reply too large (70 MB) — not shown", p.log.items[p.log.items.len - 1].text);
    try testing.expect(p.state == .connected);
    try testing.expect(p.pending.get(120) == null);
    // The DOM: the whole tree was too large, so it asks again with a depth.
    try p.pending.put(gpa, 121, .dom);
    try handle(&app, try tooLong.ev(gpa, id, 121, 73_523_893));
    try testing.expectEqual(@as(i32, 8), p.dom_depth);
    try testing.expectEqualStrings("DOM.getDocument", p.queued.items[p.queued.items.len - 1].method);
    try testing.expectEqualStrings("{\"depth\":8}", p.queued.items[p.queued.items.len - 1].params);
    // A skipped event says so.
    try handle(&app, try tooLong.ev(gpa, id, null, 80 << 20));
    try testing.expect(std.mem.startsWith(u8, p.log.items[p.log.items.len - 1].text, "skipped a CDP event of 80 MB"));
}

test "a redirect: the 302 lands on the hop that answered it, the 200 on the URL that returned it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    const msg = struct {
        fn ev(g: Allocator, pid: PaneId, text: []const u8) !*CdpEvent {
            const box = try g.create(CdpEvent);
            box.* = .{ .pane = pid, .kind = .{ .message = try g.dupe(u8, text) } };
            return box;
        }
    };
    // The wire, as Chrome sends it for GET /start → 302 → /landed → 200.
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"56311.2\",\"type\":\"Document\",\"request\":{\"url\":\"http://127.0.0.1:18801/start\",\"method\":\"GET\"}}}"));
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"56311.2\",\"type\":\"Document\",\"request\":{\"url\":\"http://127.0.0.1:18802/landed\",\"method\":\"GET\"},\"redirectResponse\":{\"status\":302,\"mimeType\":\"text/plain\"}}}"));
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"56311.2\",\"type\":\"Document\",\"response\":{\"status\":200,\"mimeType\":\"text/html\"}}}"));
    try testing.expectEqual(@as(usize, 2), p.net.items.len);
    try testing.expectEqualStrings("http://127.0.0.1:18801/start", p.net.items[0].url);
    try testing.expectEqual(@as(?i64, 302), p.net.items[0].status);
    try testing.expectEqualStrings("http://127.0.0.1:18802/landed", p.net.items[1].url);
    try testing.expectEqual(@as(?i64, 200), p.net.items[1].status);
    try testing.expectEqualStrings("text/html", p.net.items[1].mime.?);
}

test "console: every line of a multi-line message paints, objects read from their preview, format specifiers apply, warn is warn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = pbuf[0..n], .data_root = pbuf[0..n] });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try testPane(&app);
    const p = app.panes.get(id).?.asBrowser().?;
    const msg = struct {
        fn ev(g: Allocator, pid: PaneId, text: []const u8) !*CdpEvent {
            const box = try g.create(CdpEvent);
            box.* = .{ .pane = pid, .kind = .{ .message = try g.dupe(u8, text) } };
            return box;
        }
    };
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":\"log\",\"args\":[{\"type\":\"string\",\"value\":\"multi\\nline\\nmessage\"}]}}"));
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":\"log\",\"args\":[{\"type\":\"object\",\"className\":\"Object\",\"description\":\"Object\",\"preview\":{\"type\":\"object\",\"description\":\"Object\",\"overflow\":false,\"properties\":[{\"name\":\"a\",\"type\":\"number\",\"value\":\"1\"},{\"name\":\"s\",\"type\":\"string\",\"value\":\"str\"}]}}]}}"));
    try handle(&app, try msg.ev(gpa, id, "{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":\"warning\",\"args\":[{\"type\":\"string\",\"value\":\"%s is %d%%\"},{\"type\":\"string\",\"value\":\"rate\"},{\"type\":\"number\",\"value\":5}]}}"));
    try testing.expectEqualStrings("console.log: {a: 1, s: \"str\"}", p.log.items[p.log.items.len - 2].text);
    try testing.expectEqualStrings("console.warn: rate is 5%", p.log.items[p.log.items.len - 1].text);
    var f = try @import("../ui/test_fixture.zig").init(80, 20);
    defer f.deinit();
    try draw(&app, f.ui(), id, p, f.full());
    const screen = try f.text();
    try testing.expect(std.mem.indexOf(u8, screen, "console.log: multi") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "  line") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "  message") != null);
    // A long one is cut with a mark that says how much is left.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    defer long.deinit(gpa);
    for (0..60) |i| try long.print(gpa, "row{d}\n", .{i});
    try p.push(.console, long.items[0 .. long.items.len - 1]);
    const rows = try logRows(app.frame.allocator(), p, &.{p.log.items.len - 1});
    try testing.expectEqual(@as(usize, max_entry_rows + 1), rows.len);
    try testing.expectEqualStrings("  ⏎ +10 more lines", rows[rows.len - 1].text);
}

/// One CDP message as the worker posts it.
fn cdpMsg(pid: PaneId, text: []const u8) !*CdpEvent {
    const g = testing.allocator;
    const box = try g.create(CdpEvent);
    box.* = .{ .pane = pid, .kind = .{ .message = try g.dupe(u8, text) } };
    return box;
}

/// A fresh app on a temporary workspace, and a browser pane in it.
const TestBed = struct {
    tmp: testing.TmpDir = undefined,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    app: App = undefined,
    id: PaneId = undefined,

    fn init(self: *TestBed) !*BrowserPane {
        self.tmp = testing.tmpDir(.{});
        const n = try self.tmp.dir.realPath(testing.io, &self.buf);
        self.root = self.buf[0..n];
        self.app = try App.initWith(testing.allocator, testing.io, .{ .workspace = self.root, .data_root = self.root });
        self.id = try testPane(&self.app);
        return self.app.panes.get(self.id).?.asBrowser().?;
    }

    fn deinit(self: *TestBed) void {
        self.app.deinit();
        self.tmp.cleanup();
    }

    fn msg(self: *TestBed, text: []const u8) !void {
        try handle(&self.app, try cdpMsg(self.id, text));
    }

    fn last(self: *TestBed) []const u8 {
        const p = self.app.panes.get(self.id).?.asBrowser().?;
        return p.log.items[p.log.items.len - 1].text;
    }

    fn lastQueued(self: *TestBed) []const u8 {
        const p = self.app.panes.get(self.id).?.asBrowser().?;
        return p.queued.items[p.queued.items.len - 1].method;
    }
};

test "an eval that throws or rejects reads as an error; a function, a Symbol and an object read the way DevTools shows them" {
    var tb: TestBed = .{};
    const p = try tb.init();
    defer tb.deinit();
    const gpa = testing.allocator;
    // The user's eval asks for a remote object with its preview.
    try eval(&tb.app, p, "1", .eval);
    try testing.expect(std.mem.indexOf(u8, p.queued.items[0].params, "\"returnByValue\":false,\"generatePreview\":true") != null);
    try p.pending.put(gpa, 200, .eval);
    try tb.msg("{\"id\":200,\"result\":{\"result\":{\"type\":\"object\",\"value\":{}},\"exceptionDetails\":{\"text\":\"Uncaught (in promise) Error: rej\",\"exception\":{\"type\":\"object\",\"subtype\":\"error\",\"description\":\"Error: rej\\n    at <anonymous>:1:16\"}}}}");
    try testing.expectEqualStrings("⚠ Uncaught (in promise) Error: rej", tb.last());
    try testing.expect(p.log.items[p.log.items.len - 1].kind == .console_err);
    try p.pending.put(gpa, 201, .eval);
    try tb.msg("{\"id\":201,\"result\":{\"result\":{\"type\":\"object\",\"subtype\":\"error\",\"description\":\"Error: evalboom\\n at x\"},\"exceptionDetails\":{\"text\":\"Uncaught\",\"exception\":{\"type\":\"object\",\"subtype\":\"error\",\"description\":\"Error: evalboom\\n at x\"}}}}");
    try testing.expectEqualStrings("⚠ Uncaught Error: evalboom", tb.last());
    try p.pending.put(gpa, 202, .eval);
    try tb.msg("{\"id\":202,\"result\":{\"result\":{\"type\":\"function\",\"className\":\"Function\",\"description\":\"() => 1\",\"objectId\":\"o1\"}}}");
    try testing.expectEqualStrings("= () => 1", tb.last());
    try p.pending.put(gpa, 203, .eval);
    try tb.msg("{\"id\":203,\"result\":{\"result\":{\"type\":\"symbol\",\"description\":\"Symbol(s)\",\"objectId\":\"o2\"}}}");
    try testing.expectEqualStrings("= Symbol(s)", tb.last());
    // An object: copied by value from its objectId (its preview is kept
    // for when that fails), and released.
    p.state = .connected;
    const queued_before = p.queued.items.len;
    try p.pending.put(gpa, 204, .eval);
    try tb.msg("{\"id\":204,\"result\":{\"result\":{\"type\":\"object\",\"className\":\"Object\",\"description\":\"Object\",\"objectId\":\"o3\",\"preview\":{\"type\":\"object\",\"description\":\"Object\",\"overflow\":false,\"properties\":[{\"name\":\"x\",\"type\":\"number\",\"value\":\"1\"},{\"name\":\"self\",\"type\":\"object\",\"value\":\"Object\"}]}}}}");
    // No session in a test pane: the copy is queued, so the preview shows.
    try testing.expectEqual(queued_before + 1, p.queued.items.len);
    try testing.expectEqualStrings("Runtime.callFunctionOn", tb.lastQueued());
    try testing.expectEqualStrings("= {x: 1, self: Object}", tb.last());
    // The copy's reply is the JSON; a failed copy (a circular object) the preview.
    try p.eval_fallback.put(gpa, 205, try gpa.dupe(u8, "{x: 1}"));
    try p.pending.put(gpa, 205, .eval_json);
    try tb.msg("{\"id\":205,\"result\":{\"result\":{\"type\":\"object\",\"value\":{\"x\":1,\"y\":[1,2]}}}}");
    try testing.expectEqualStrings("= {\"x\":1,\"y\":[1,2]}", tb.last());
    try p.eval_fallback.put(gpa, 206, try gpa.dupe(u8, "{x: 1, self: Object}"));
    try p.pending.put(gpa, 206, .eval_json);
    try tb.msg("{\"id\":206,\"error\":{\"code\":-32000,\"message\":\"Object reference chain is too long\"}}");
    try testing.expectEqualStrings("= {x: 1, self: Object}", tb.last());
    try testing.expectEqual(@as(usize, 0), p.eval_fallback.count());
    // A panel's dump that throws says so (about:blank's localStorage).
    try p.pending.put(gpa, 207, .storage);
    try tb.msg("{\"id\":207,\"result\":{\"result\":{\"type\":\"object\"},\"exceptionDetails\":{\"text\":\"Uncaught\",\"exception\":{\"description\":\"SecurityError: Failed to read the 'localStorage' property\\n at\"}}}}");
    try testing.expectEqualStrings("storage: Uncaught SecurityError: Failed to read the 'localStorage' property", tb.last());
    try testing.expect(p.panel == .log);
    // An error reply names what failed in words, not the tag.
    try p.pending.put(gpa, 208, .navigate);
    try tb.msg("{\"id\":208,\"error\":{\"code\":-32000,\"message\":\"Cannot navigate to invalid URL\"}}");
    try testing.expectEqualStrings("navigate failed: Cannot navigate to invalid URL", tb.last());
    try p.pending.put(gpa, 209, .quiet);
    try tb.msg("{\"id\":209,\"error\":{\"code\":-32000,\"message\":\"Could not find node with given id\"}}");
    try testing.expectEqualStrings("request failed: Could not find node with given id", tb.last());
}

test "a schemeless address typed into navigate is sent with http://" {
    var tb: TestBed = .{};
    const p = try tb.init();
    defer tb.deinit();
    try navigate(&tb.app, p, "localhost:18808/first");
    try testing.expectEqualStrings("Page.navigate", tb.lastQueued());
    try testing.expectEqualStrings("{\"url\":\"http://localhost:18808/first\"}", p.queued.items[p.queued.items.len - 1].params);
    try testing.expectEqualStrings("→ http://localhost:18808/first", tb.last());
}

test "scrolled back, the log holds still while lines arrive; at the tail it follows" {
    var tb: TestBed = .{};
    const p = try tb.init();
    defer tb.deinit();
    for (0..10) |i| try p.push(.console, try std.fmt.allocPrint(tb.app.frame.allocator(), "tick {d}", .{i}));
    p.scroll = 3;
    try p.push(.console, "tick 10");
    try p.push(.console, "two\nrows");
    try testing.expectEqual(@as(usize, 6), p.scroll);
    // A line the filter hides adds no row.
    try p.filter.appendSlice(testing.allocator, "tick");
    try p.push(.console, "noise");
    try testing.expectEqual(@as(usize, 6), p.scroll);
    p.filter.clearRetainingCapacity();
    p.scroll = 0;
    try p.push(.console, "tick 11");
    try testing.expectEqual(@as(usize, 0), p.scroll);
}
