//! The update check. Once per launch (behind `ui.check_updates`, and
//! only from the terminal loop, right after its `startup` hook — never
//! headless, never in a test) a worker asks GitHub for the newest release and, when its
//! tag is newer than this build, the next tick toasts it. `app.check_updates`
//! runs the same check by hand and also reports "up to date".
//!
//! D3 as usual: the worker owns nothing of the app but its own `State`
//! and the event queue; it parks its answer under a mutex and posts a
//! `.timer` so the loop wakes; `tick` takes the answer on the UI thread.
//! `MNML_NO_UPDATE_CHECK=1` skips the automatic check.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const http_parse = @import("../http/parse.zig");
const http_client = @import("../http/client.zig");

pub const repo = "chris-mclennan/mnml";
pub const endpoint = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
pub const releases_url = "https://github.com/" ++ repo ++ "/releases";
const root = @import("root");
/// The running build's version, from `main.zig`.
pub const current: []const u8 = if (@hasDecl(root, "version")) root.version else "0.0.0";

pub const Result = union(enum) {
    /// A newer tag, without its `v`. Owned.
    newer: []u8,
    up_to_date,
    /// The one-line reason. Owned.
    failed: []u8,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            .newer, .failed => |s| gpa.free(s),
            .up_to_date => {},
        }
    }
};

pub const State = struct {
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    /// The worker's answer until `tick` takes it.
    result: ?Result = null,
    /// A check has run (or is running) this launch.
    started: bool = false,
    /// The user asked: report "up to date" and failures too.
    manual: bool = false,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.result) |r| r.deinit(gpa);
        self.result = null;
    }

    fn put(self: *State, io: Io, gpa: Allocator, r: Result) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.result) |old| old.deinit(gpa);
        self.result = r;
    }

    fn take(self: *State, io: Io) ?Result {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const r = self.result;
        self.result = null;
        return r;
    }
};

/// The automatic check. The terminal loop calls it after the `startup`
/// hook; it is not a hook subscriber, because `--headless`, the `.test`
/// runner and the unit tests all emit `startup` and none of them may
/// touch the network.
pub fn startupCheck(app: *App) void {
    if (!app.cfg.ui.check_updates) return;
    if (app.env.get("MNML_NO_UPDATE_CHECK")) |v| if (std.mem.eql(u8, v, "1")) return;
    start(app, false) catch {};
}

pub const table = .{
    .@"app.check_updates" = &checkCmd,
};

fn checkCmd(app: *App) CommandError!void {
    try start(app, true);
    app.toast("checking {s} for a newer release…", .{repo});
}

pub fn start(app: *App, manual: bool) CommandError!void {
    const st = &app.update;
    st.group.cancel(app.io);
    st.started = true;
    st.manual = manual;
    st.group.concurrent(app.io, worker, .{ st, app.events, app.io, app.gpa }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "update check: could not start: {s}", .{@errorName(err)});
    };
}

fn worker(st: *State, events: *event.EventQueue, io: Io, gpa: Allocator) Io.Cancelable!void {
    const r = fetch(gpa, io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return,
    };
    st.put(io, gpa, r);
    events.post(io, .timer);
}

/// GET the latest release; compare its tag to `current`.
fn fetch(gpa: Allocator, io: Io) (Allocator.Error || Io.Cancelable)!Result {
    var req = try http_parse.Request.init(gpa);
    defer req.deinit(gpa);
    try req.setUrl(gpa, endpoint);
    try req.addHeader(gpa, "User-Agent", "mnml-zig/" ++ current);
    try req.addHeader(gpa, "Accept", "application/vnd.github+json");
    var outcome = try http_client.send(gpa, io, &req, .{});
    defer outcome.deinit(gpa);
    switch (outcome) {
        .err => |e| return .{ .failed = try gpa.dupe(u8, e) },
        .moved => return .{ .failed = try gpa.dupe(u8, "no response") },
        .ok => |*resp| {
            if (resp.status != 200) return .{ .failed = try std.fmt.allocPrint(gpa, "HTTP {d} from api.github.com", .{resp.status}) };
            const tag = (try tagFromJson(gpa, resp.body)) orelse return .{ .failed = try gpa.dupe(u8, "no tag_name in the release JSON") };
            errdefer gpa.free(tag);
            if (isNewer(tag, current)) return .{ .newer = tag };
            gpa.free(tag);
            return .up_to_date;
        },
    }
}

/// `tag_name` from a GitHub release object, `v` stripped. Owned.
pub fn tagFromJson(gpa: Allocator, body: []const u8) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch return null;
    if (v != .object) return null;
    const tag = v.object.get("tag_name") orelse return null;
    if (tag != .string) return null;
    return try gpa.dupe(u8, std.mem.trimStart(u8, tag.string, "v"));
}

/// `major.minor.patch` compare. A `-pre` suffix ranks below the bare
/// version it names (0.3.0-dev < 0.3.0), `+meta` is ignored, and
/// anything unparseable is "not newer".
pub fn isNewer(remote: []const u8, local: []const u8) bool {
    const r = parts(remote) orelse return false;
    const l = parts(local) orelse return false;
    return switch (std.mem.order(u64, &r.nums, &l.nums)) {
        .gt => true,
        .lt => false,
        .eq => l.pre and !r.pre,
    };
}

const Version = struct { nums: [3]u64, pre: bool };

fn parts(v_in: []const u8) ?Version {
    var v = std.mem.trimStart(u8, v_in, "v");
    if (std.mem.indexOfScalar(u8, v, '+')) |i| v = v[0..i];
    var pre = false;
    if (std.mem.indexOfScalar(u8, v, '-')) |i| {
        pre = i + 1 < v.len;
        v = v[0..i];
    }
    var out: [3]u64 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    out[0] = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next()) |m| out[1] = std.fmt.parseInt(u64, m, 10) catch return null;
    if (it.next()) |p| out[2] = std.fmt.parseInt(u64, p, 10) catch return null;
    return .{ .nums = out, .pre = pre };
}

/// The UI thread's half: toast the answer the worker left.
pub fn tick(app: *App) Allocator.Error!void {
    const st = &app.update;
    const r = st.take(app.io) orelse return;
    defer r.deinit(app.gpa);
    switch (r) {
        .newer => |tag| try app.toastLevel(.warn, "mnml v{s} is out (this is v{s}) — {s}", .{ tag, current, releases_url }),
        .up_to_date => if (st.manual) app.toast("mnml v{s} is the latest release", .{current}),
        .failed => |why| if (st.manual) try app.toastLevel(.warn, "update check failed: {s}", .{why}),
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "isNewer: semver order, v prefix and suffixes, garbage is never newer" {
    try t.expect(isNewer("0.1.4", "0.1.3"));
    try t.expect(isNewer("v0.2.0", "0.1.99"));
    try t.expect(isNewer("1.0.0", "0.99.99"));
    try t.expect(isNewer("0.3.0", "0.3.0-dev"));
    try t.expect(!isNewer("0.3.0-rc1", "0.3.0"));
    try t.expect(isNewer("0.3.1-rc1", "0.3.0"));
    try t.expect(!isNewer("0.3.0+build7", "0.3.0"));
    try t.expect(!isNewer("0.1.3", "0.1.4"));
    try t.expect(!isNewer("0.1.3", "0.1.3"));
    try t.expect(!isNewer("garbage", "0.1.3"));
    try t.expect(!isNewer("0.1.3", "garbage"));
    // What a checkout builds (`<zon version>+g<sha>[-dirty]`) against the
    // endpoint's repo as it is before the cutover: its latest is a 0.2.x
    // Rust release, which is never newer than a 0.3.0-dev build.
    try t.expect(!isNewer("0.2.22", "0.3.0-dev+g1a2b3c4-dirty"));
    try t.expect(!isNewer("v0.2.23", "0.3.0-dev+g1a2b3c4"));
    try t.expect(!isNewer("0.2.22", "0.3.0-dev"));
}

test "tagFromJson reads tag_name and strips the v; the tick toasts what the worker left" {
    const tag = (try tagFromJson(t.allocator, "{\"tag_name\":\"v9.9.9\",\"name\":\"x\"}")).?;
    defer t.allocator.free(tag);
    try t.expectEqualStrings("9.9.9", tag);
    try t.expect((try tagFromJson(t.allocator, "[1,2]")) == null);
    try t.expect((try tagFromJson(t.allocator, "not json")) == null);

    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 20 });
    defer app.deinit();
    app.update.put(app.io, app.gpa, .{ .newer = try t.allocator.dupe(u8, "9.9.9") });
    try tick(&app);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "mnml v9.9.9 is out"));
    try t.expect(app.toasts.items[app.toasts.items.len - 1].level == .warn);
    // Quiet when up to date unless asked.
    app.update.put(app.io, app.gpa, .up_to_date);
    try tick(&app);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "mnml v9.9.9 is out"));
    app.update.manual = true;
    app.update.put(app.io, app.gpa, .up_to_date);
    try tick(&app);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "is the latest release") != null);
    try t.expect(app.update.take(app.io) == null);
}

test "the startup hook never starts the update check: headless, the .test runner and the unit tests all emit it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws_dir, .data_root = ws_dir, .cols = 80, .rows = 20 });
    defer app.deinit();
    try t.expect(app.cfg.ui.check_updates);
    try t.expect(app.env.get("MNML_NO_UPDATE_CHECK") == null);
    app.hooks.emit(&app, .startup);
    try t.expect(!app.update.started);
}
