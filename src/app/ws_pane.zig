//! `Pane.websocket` — one persistent connection: a log of what went
//! each way, a single-line input (Enter sends), Esc disconnects. The
//! reader runs on its own thread and posts `.ws` events; sends go
//! straight to the socket from the UI thread (`http.ws.Conn` serialises
//! writers). A keepalive ping every `[ws] ping_interval_secs`, and up
//! to `[ws] reconnect_max_attempts` reconnects on a drop — or on a
//! server Close of 1001 / 1011–1014 (`reconnectsAfter`) — with
//! 1/2/4/8/16 s backoff. Every message is appended to
//! `<data_root>/ws-history/<host>/history.jsonl`.

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
const event = @import("../core/event.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const text_field = @import("../ui/text_field.zig");
const view = @import("../ui/ws_view.zig");
const ws = @import("../http/ws.zig");

pub const State = enum { connecting, open, closing, closed };

pub const Entry = struct {
    at_ms: i64,
    outgoing: bool,
    /// Owned.
    text: []u8,
    kind: enum { message, system, err } = .message,
};

/// What the reader thread posts.
pub const WsEvent = struct {
    pane: PaneId,
    /// Which connection attempt; a stale attempt's events are dropped.
    attempt: u32,
    kind: union(enum) {
        open: ?[]u8,
        recv: []u8,
        err: []u8,
        closed: []u8,
        /// The server sent a Close frame: its code and reason (owned).
        server_close: struct { code: u16, reason: []u8 },
    },

    pub fn destroy(self: *WsEvent, gpa: Allocator) void {
        switch (self.kind) {
            .open => |p| if (p) |x| gpa.free(x),
            .recv, .err, .closed => |s| gpa.free(s),
            .server_close => |c| gpa.free(c.reason),
        }
        gpa.destroy(self);
    }
};

/// Shared between the pane and its reader thread.
const Shared = struct {
    io: Io,
    lock: Io.Mutex = .init,
    conn: ?*ws.Conn = null,
    closing: bool = false,
};

pub const WebsocketPane = struct {
    gpa: Allocator,
    url: []u8,
    state: State = .connecting,
    log: std.ArrayListUnmanaged(Entry) = .empty,
    input: std.ArrayListUnmanaged(u8) = .empty,
    input_caret: usize = 0,
    /// Rows from the bottom; 0 follows the tail.
    scroll: usize = 0,
    shared: *Shared,
    thread: ?std.Thread = null,
    attempt: u32 = 0,
    reconnects: u32 = 0,
    reconnect_at_ms: ?i64 = null,
    last_ping_ms: i64 = 0,
    /// The user asked for the close; no reconnect.
    user_closed: bool = false,
    title_buf: []u8,
    protocol: ?[]u8 = null,

    pub fn deinit(self: *WebsocketPane, gpa: Allocator) void {
        self.disconnect();
        if (self.thread) |t| t.join();
        if (self.shared.conn) |c| c.deinit();
        gpa.destroy(self.shared);
        for (self.log.items) |e| gpa.free(e.text);
        self.log.deinit(gpa);
        self.input.deinit(gpa);
        gpa.free(self.url);
        gpa.free(self.title_buf);
        if (self.protocol) |p| gpa.free(p);
    }

    pub fn title(self: *const WebsocketPane) []const u8 {
        return self.title_buf;
    }

    fn refreshTitle(self: *WebsocketPane) Allocator.Error!void {
        const badge: []const u8 = switch (self.state) {
            .connecting => "…",
            .open => "●",
            .closing => "▼",
            .closed => "·",
        };
        const fresh = try std.fmt.allocPrint(self.gpa, "ws {s} {s}", .{ badge, hostOf(self.url) });
        self.gpa.free(self.title_buf);
        self.title_buf = fresh;
    }

    /// Tell the reader to stop and close the socket.
    pub fn disconnect(self: *WebsocketPane) void {
        self.shared.lock.lockUncancelable(self.shared.io);
        defer self.shared.lock.unlock(self.shared.io);
        self.shared.closing = true;
        if (self.shared.conn) |c| {
            c.close(1000, "") catch {};
            c.stream.shutdown(c.io, .both) catch {};
        }
    }

    pub fn push(self: *WebsocketPane, now_ms: i64, outgoing: bool, kind: @FieldType(Entry, "kind"), text: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        if (self.log.items.len >= 5000) self.gpa.free(self.log.orderedRemove(0).text);
        try self.log.append(self.gpa, .{ .at_ms = now_ms, .outgoing = outgoing, .text = copy, .kind = kind });
    }
};

pub fn hostOf(url: []const u8) []const u8 {
    const u = ws.Url.parse(url) catch return url;
    return u.host;
}

// ─── open / worker ──────────────────────────────────────────────────────

/// Open a pane on `url` and start connecting.
pub fn open(app: *App, url: []const u8) CommandError!PaneId {
    const gpa = app.gpa;
    _ = ws.Url.parse(url) catch return app.diag.fail(app.frame.allocator(), "ws: not a ws:// or wss:// URL: {s}", .{url});
    const shared = try gpa.create(Shared);
    errdefer gpa.destroy(shared);
    shared.* = .{ .io = app.io };
    var pane: WebsocketPane = .{ .gpa = gpa, .url = try gpa.dupe(u8, url), .shared = shared, .title_buf = try gpa.dupe(u8, "ws") };
    errdefer pane.deinit(gpa);
    try pane.refreshTitle();
    const id = try app.panes.add(.{ .websocket = pane });
    app.showPane(id);
    const p = app.panes.get(id).?.asWebsocket().?;
    try p.push(app.now_ms, false, .system, "connecting…");
    try startWorker(app, id, p);
    return id;
}

fn startWorker(app: *App, id: PaneId, p: *WebsocketPane) CommandError!void {
    const gpa = app.gpa;
    if (p.thread) |t| {
        t.join();
        p.thread = null;
    }
    if (p.shared.conn) |c| {
        c.deinit();
        p.shared.conn = null;
    }
    p.shared.closing = false;
    p.attempt += 1;
    p.state = .connecting;
    try p.refreshTitle();
    const url = try gpa.dupe(u8, p.url);
    errdefer gpa.free(url);
    var subs: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (subs.items) |s| gpa.free(s);
        subs.deinit(gpa);
    }
    for (app.cfg.ws.subprotocols) |s| try subs.append(gpa, try gpa.dupe(u8, s));
    const subs_owned = try subs.toOwnedSlice(gpa);
    p.thread = std.Thread.spawn(.{}, worker, .{ &app.events, app.io, gpa, p.shared, id, p.attempt, url, subs_owned }) catch |err| {
        gpa.free(url);
        for (subs_owned) |s| gpa.free(s);
        gpa.free(subs_owned);
        return app.diag.fail(app.frame.allocator(), "ws: could not start the reader: {s}", .{@errorName(err)});
    };
}

fn post(events: *event.EventQueue, io: Io, gpa: Allocator, ev: WsEvent) void {
    const box = gpa.create(WsEvent) catch return;
    box.* = ev;
    events.post(io, .{ .ws = box });
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, shared: *Shared, pane: PaneId, attempt: u32, url: []u8, subs: [][]u8) void {
    defer gpa.free(url);
    defer {
        for (subs) |s| gpa.free(s);
        gpa.free(subs);
    }
    const conn = ws.Conn.connect(gpa, io, url, .{ .subprotocols = subs }) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "connect failed: {s}", .{@errorName(err)}) catch return;
        post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .err = msg } });
        const reason = gpa.dupe(u8, "dropped") catch return;
        post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .closed = reason } });
        return;
    };
    {
        shared.lock.lockUncancelable(io);
        defer shared.lock.unlock(io);
        if (shared.closing) {
            conn.deinit();
            return;
        }
        shared.conn = conn;
    }
    const proto: ?[]u8 = if (conn.protocol) |p| gpa.dupe(u8, p) catch null else null;
    post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .open = proto } });
    while (true) {
        const msg = conn.readMessage() catch |err| {
            const text = std.fmt.allocPrint(gpa, "read error: {s}", .{@errorName(err)}) catch break;
            post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .err = text } });
            break;
        } orelse break;
        switch (msg) {
            .text => |t| {
                const copy = gpa.dupe(u8, t) catch break;
                post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .recv = copy } });
            },
            .binary => |b| {
                const text = std.fmt.allocPrint(gpa, "(binary {d} bytes)", .{b.len}) catch break;
                post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .recv = text } });
            },
            .too_long => |t| {
                const text = std.fmt.allocPrint(gpa, "(message of {d} bytes skipped: over the {d} MiB cap)", .{ t.len, conn.max_message >> 20 }) catch break;
                post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .recv = text } });
            },
            .close => |c| {
                // Our own Esc's close comes back as the server's echo.
                if (shared.closing) break;
                const reason = gpa.dupe(u8, c.reason) catch break;
                post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .server_close = .{ .code = c.code, .reason = reason } } });
                return;
            },
            .ping, .pong => {},
        }
    }
    const reason = gpa.dupe(u8, if (shared.closing) "closed" else "dropped") catch return;
    post(events, io, gpa, .{ .pane = pane, .attempt = attempt, .kind = .{ .closed = reason } });
}

/// D1: the event is ours; adopted into the log or freed here.
pub fn handle(app: *App, ev: *WsEvent) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const pane = app.panes.get(ev.pane) orelse return;
    const p = pane.asWebsocket() orelse return;
    if (ev.attempt != p.attempt) return;
    app.needs_render = true;
    switch (ev.kind) {
        .open => |proto| {
            p.state = .open;
            p.reconnects = 0;
            p.last_ping_ms = app.now_ms;
            if (p.protocol) |old| app.gpa.free(old);
            p.protocol = if (proto) |x| try app.gpa.dupe(u8, x) else null;
            try p.push(app.now_ms, false, .system, if (proto) |x| try std.fmt.allocPrint(app.frame.allocator(), "connected (subprotocol {s})", .{x}) else "connected");
            try p.refreshTitle();
            try flushQueued(app, ev.pane, p);
        },
        .recv => |text| {
            try p.push(app.now_ms, false, .message, text);
            persistHistory(app, p.url, false, text);
        },
        .err => |text| try p.push(app.now_ms, false, .err, text),
        .server_close => |c| {
            // A deliberate close from the server says why; it is not a
            // network drop, and reconnecting into the same answer
            // (1008 policy, 4001 auth) only repeats it.
            p.state = .closed;
            const line = if (c.reason.len > 0) try std.fmt.allocPrint(app.frame.allocator(), "closed {d} {s}", .{ c.code, c.reason }) else try std.fmt.allocPrint(app.frame.allocator(), "closed {d}", .{c.code});
            try p.push(app.now_ms, false, if (c.code == 1000) .system else .err, line);
            if (!p.user_closed and reconnectsAfter(c.code, app.cfg.ws.reconnect_on_close) and p.reconnects < app.cfg.ws.reconnect_max_attempts) {
                p.reconnects += 1;
                const backoff: i64 = @as(i64, 1) << @intCast(@min(p.reconnects - 1, 4));
                p.reconnect_at_ms = app.now_ms + backoff * 1000;
                p.state = .connecting;
                try p.push(app.now_ms, false, .err, try std.fmt.allocPrint(app.frame.allocator(), "reconnecting in {d}s (attempt {d}/{d})", .{ backoff, p.reconnects, app.cfg.ws.reconnect_max_attempts }));
            }
            try p.refreshTitle();
        },
        .closed => |reason| {
            const was_user = p.user_closed or std.mem.eql(u8, reason, "closed");
            p.state = .closed;
            try p.push(app.now_ms, false, .system, if (was_user) "closed" else "dropped");
            if (!was_user and p.reconnects < app.cfg.ws.reconnect_max_attempts) {
                p.reconnects += 1;
                const backoff: i64 = @as(i64, 1) << @intCast(@min(p.reconnects - 1, 4));
                p.reconnect_at_ms = app.now_ms + backoff * 1000;
                p.state = .connecting;
                try p.push(app.now_ms, false, .err, try std.fmt.allocPrint(app.frame.allocator(), "dropped — reconnecting in {d}s (attempt {d}/{d})", .{ backoff, p.reconnects, app.cfg.ws.reconnect_max_attempts }));
            }
            try p.refreshTitle();
        },
    }
}

/// Whether a server Close frame with `code` is worth a reconnect: the
/// server going away (1001) or in trouble / restarting / asking to try
/// later (1011–1014). A normal close (1000), a protocol or policy
/// answer (1002–1010) and an application code (3000–4999) are final —
/// unless `[ws] reconnect_on_close` says every close is.
pub fn reconnectsAfter(code: u16, reconnect_on_close: bool) bool {
    if (reconnect_on_close) return true;
    return switch (code) {
        1001, 1011, 1012, 1013, 1014 => true,
        else => false,
    };
}

/// Keepalive pings and due reconnects.
pub fn tickAll(app: *App) void {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .websocket => |*p| {
            if (p.reconnect_at_ms) |at| if (app.now_ms >= at) {
                p.reconnect_at_ms = null;
                startWorker(app, @intCast(i), p) catch {};
            };
            const every: i64 = @as(i64, app.cfg.ws.ping_interval_secs) * 1000;
            if (p.state == .open and every > 0 and app.now_ms - p.last_ping_ms >= every) {
                p.last_ping_ms = app.now_ms;
                if (p.shared.conn) |c| c.ping("") catch {};
            }
        },
        else => {},
    };
}

pub fn nextDeadline(app: *App) ?i64 {
    var next: ?i64 = null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .websocket => |*p| {
            if (p.reconnect_at_ms) |at| next = @min(next orelse std.math.maxInt(i64), at);
            const every: i64 = @as(i64, app.cfg.ws.ping_interval_secs) * 1000;
            if (p.state == .open and every > 0) next = @min(next orelse std.math.maxInt(i64), p.last_ping_ms + every);
        },
        else => {},
    };
    return next;
}

/// Send `text` on the pane's connection and log it.
pub fn send(app: *App, p: *WebsocketPane, text: []const u8) CommandError!void {
    if (p.state != .open) return app.diag.fail(app.frame.allocator(), "ws: not connected ({s})", .{@tagName(p.state)});
    const conn = p.shared.conn orelse return app.diag.fail(app.frame.allocator(), "ws: not connected", .{});
    conn.sendText(text) catch |err| return app.diag.fail(app.frame.allocator(), "ws: send failed: {s}", .{@errorName(err)});
    try p.push(app.now_ms, true, .message, text);
    persistHistory(app, p.url, true, text);
    p.scroll = 0;
    app.needs_render = true;
}

// ─── history ────────────────────────────────────────────────────────────

fn historyRoot(app: *App, arena: Allocator) Allocator.Error!?[]u8 {
    if (app.data_root.len == 0) return null;
    return try std.fs.path.join(arena, &.{ app.data_root, "ws-history" });
}

fn slugOf(arena: Allocator, host: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, host);
    for (out) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '_' or c.* == '.' or c.* == '-')) {
        c.* = '_';
    };
    return out;
}

fn persistHistory(app: *App, url: []const u8, outgoing: bool, text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = (historyRoot(app, a) catch return) orelse return;
    const dir = std.fs.path.join(a, &.{ root, slugOf(a, hostOf(url)) catch return }) catch return;
    Io.Dir.cwd().createDirPath(app.io, dir) catch return;
    const path = std.fs.path.join(a, &.{ dir, "history.jsonl" }) catch return;
    const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(app.io, .real).toNanoseconds(), std.time.ns_per_ms));
    var aw: Io.Writer.Allocating = .init(a);
    aw.writer.print("{{\"ts\":{d},\"url\":", .{ts}) catch return;
    std.json.Stringify.value(url, .{}, &aw.writer) catch return;
    aw.writer.print(",\"outgoing\":{},\"text\":", .{outgoing}) catch return;
    std.json.Stringify.value(text, .{}, &aw.writer) catch return;
    aw.writer.writeAll("}") catch return;
    const line = aw.written();
    @import("../http/history.zig").appendLine(app.gpa, app.io, path, line) catch {};
}

pub const HistoryRow = struct { url: []const u8, last_ts: i64, count: usize };

/// Every host directory's URL, newest first.
pub fn readHistory(app: *App, arena: Allocator) Allocator.Error![]HistoryRow {
    var out: std.ArrayListUnmanaged(HistoryRow) = .empty;
    const root = (try historyRoot(app, arena)) orelse return out.items;
    var dir = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch return out.items;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |e| {
        if (e.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ root, e.name, "history.jsonl" });
        const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(8 << 20)) catch continue;
        var url: ?[]const u8 = null;
        var last: i64 = 0;
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            count += 1;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
            if (v != .object) continue;
            if (v.object.get("ts")) |t| if (t == .integer) {
                last = @max(last, t.integer);
            };
            if (url == null) if (v.object.get("url")) |u| if (u == .string) {
                url = u.string;
            };
        }
        if (url) |u| try out.append(arena, .{ .url = u, .last_ts = last, .count = count });
    }
    std.mem.sort(HistoryRow, out.items, {}, struct {
        fn lt(_: void, x: HistoryRow, y: HistoryRow) bool {
            return x.last_ts > y.last_ts;
        }
    }.lt);
    return out.items;
}

// ─── keys / mouse / draw ────────────────────────────────────────────────

pub fn handleKey(app: *App, id: PaneId, p: *WebsocketPane, k: Key) Allocator.Error!bool {
    _ = id;
    app.needs_render = true;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const rows = @max(app.pane_rows, 1);
    switch (k.code) {
        .enter => {
            const text = try app.frame.allocator().dupe(u8, p.input.items);
            if (std.mem.trim(u8, text, " \t").len == 0) return true;
            send(app, p, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
            p.input.clearRetainingCapacity();
            p.input_caret = 0;
            return true;
        },
        .esc => {
            if (p.state == .open or p.state == .connecting) {
                p.user_closed = true;
                p.state = .closing;
                p.disconnect();
                try p.refreshTitle();
                return true;
            }
            return false;
        },
        .page_up => {
            p.scroll += rows;
            return true;
        },
        .page_down => {
            p.scroll -|= rows;
            return true;
        },
        .up => {
            p.scroll += 1;
            return true;
        },
        .down => {
            p.scroll -|= 1;
            return true;
        },
        else => {},
    }
    const edit = try text_field.handleKey(&p.input, &p.input_caret, app.gpa, k);
    return edit != .ignored;
}

pub fn paste(app: *App, p: *WebsocketPane, text: []const u8) Allocator.Error!void {
    try text_field.insert(&p.input, &p.input_caret, app.gpa, std.mem.trimEnd(u8, std.mem.sliceTo(text, '\n'), "\r"));
    app.needs_render = true;
}

pub fn scrollBy(p: *WebsocketPane, delta: i32) void {
    if (delta < 0) p.scroll += @intCast(-delta) else p.scroll -|= @intCast(delta);
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *WebsocketPane, area: Rect) Allocator.Error!void {
    const focused = app.active == id and app.focus == .pane;
    const entries = try ui.arena.alloc(view.Entry, p.log.items.len);
    for (p.log.items, 0..) |e, i| entries[i] = .{ .outgoing = e.outgoing, .text = e.text, .kind = switch (e.kind) {
        .message => .message,
        .system => .system,
        .err => .err,
    } };
    const caret = view.draw(ui, id, area, .{
        .url = p.url,
        .state = @tagName(p.state),
        .protocol = p.protocol,
        .entries = entries,
        .input = p.input.items,
        .input_caret = p.input_caret,
        .scroll = &p.scroll,
        .focused = focused,
    });
    if (app.active == id) {
        app.pane_rows = @max(area.h, 1);
        app.pane_cols = @max(area.w, 1);
        if (focused) if (caret) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        };
    }
}

// ─── commands ───────────────────────────────────────────────────────────

pub const table = .{
    .@"ws.connect" = &connectCmd,
    .@"ws.send_message" = &sendMessageCmd,
    .@"ws.disconnect" = &disconnectCmd,
    .@"ws.history" = &historyCmd,
    .@"ws.send" = &sendFileCmd,
};

pub fn activeWs(app: *App) ?*WebsocketPane {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return p.asWebsocket();
}

fn connectCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "WebSocket URL (ws:// or wss://)"), .purpose = .ws_url } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn sendMessageCmd(app: *App) CommandError!void {
    const p = activeWs(app) orelse return app.diag.fail(app.frame.allocator(), "ws: no active WebSocket pane (:ws.connect opens one)", .{});
    if (p.input.items.len > 0) {
        const text = try app.frame.allocator().dupe(u8, p.input.items);
        try send(app, p, text);
        p.input.clearRetainingCapacity();
        p.input_caret = 0;
        return;
    }
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Message to send"), .purpose = .ws_message } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn disconnectCmd(app: *App) CommandError!void {
    const p = activeWs(app) orelse return app.diag.fail(app.frame.allocator(), "ws: no active WebSocket pane", .{});
    p.user_closed = true;
    p.state = .closing;
    p.disconnect();
    try p.refreshTitle();
    app.toast("ws: closing {s}", .{hostOf(p.url)});
}

fn historyCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try readHistory(app, arena.allocator());
    if (rows.len == 0) return app.diag.fail(app.frame.allocator(), "ws.history: no past connections (history lives under <data>/ws-history)", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (rows) |r| {
        try labels.append(gpa, try gpa.dupe(u8, r.url));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{d} message(s)", .{r.count}));
    }
    try @import("cmd_picker.zig").openPickerWith(app, "WebSocket history", .ws_history, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// A `.ws` file: the URL on the first line, one message per line after.
fn sendFileCmd(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const text = e.buf.editor.bytes();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var url: ?[]const u8 = null;
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        url = t;
        break;
    }
    const u = url orelse return app.diag.fail(app.frame.allocator(), "ws.send: the buffer has no ws:// URL on its first line", .{});
    const id = try open(app, u);
    const p = app.panes.get(id).?.asWebsocket().?;
    // Messages queue in the log as pending until the socket opens.
    var n: usize = 0;
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        try p.push(app.now_ms, true, .system, try std.fmt.allocPrint(app.frame.allocator(), "queued: {s}", .{t}));
        try app.http.ws_queue.append(app.gpa, .{ .pane = id, .text = try app.gpa.dupe(u8, t) });
        n += 1;
    }
    app.toast("ws: connecting to {s}, {d} message(s) queued", .{ hostOf(u), n });
}

/// Messages a `.ws` file queued before the socket opened.
pub fn flushQueued(app: *App, id: PaneId, p: *WebsocketPane) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.http.ws_queue.items.len) {
        const q = app.http.ws_queue.items[i];
        if (q.pane != id) {
            i += 1;
            continue;
        }
        const text = try app.frame.allocator().dupe(u8, q.text);
        app.gpa.free(q.text);
        _ = app.http.ws_queue.orderedRemove(i);
        send(app, p, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
}

/// The prompts this pane opens.
pub fn acceptPrompt(app: *App, purpose: app_mod.PromptPurpose, text: []const u8) Allocator.Error!void {
    switch (purpose) {
        .ws_url => {
            const url = std.mem.trim(u8, text, " \t");
            if (url.len == 0) return;
            _ = open(app, url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
        },
        .ws_message => {
            const p = activeWs(app) orelse return;
            send(app, p, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
        },
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "a pane against the echo server: connect, send, receive, history, disconnect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var server = try ws.EchoServer.start(testing.allocator, testing.io);
    defer server.stop();
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const url = try std.fmt.allocPrint(testing.allocator, "ws://127.0.0.1:{d}/x", .{server.port});
    defer testing.allocator.free(url);
    const id = try open(&app, url);
    const p = app.panes.get(id).?.asWebsocket().?;
    var waited: usize = 0;
    while (p.state != .open and waited < 300) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(p.state == .open);
    try testing.expect(std.mem.startsWith(u8, p.title(), "ws ● 127.0.0.1"));
    for ("ping!") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    waited = 0;
    while (p.log.items.len < 4 and waited < 300) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    // connecting…, connected, → ping!, ← ping!
    try testing.expectEqual(@as(usize, 4), p.log.items.len);
    try testing.expect(p.log.items[2].outgoing);
    try testing.expectEqualStrings("ping!", p.log.items[3].text);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try readHistory(&app, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(usize, 2), rows[0].count);
    try app.handle(.{ .key = Key.named(.esc) });
    waited = 0;
    while (p.state != .closed and waited < 300) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(p.state == .closed);
    try testing.expect(p.reconnect_at_ms == null);
}

test "a server Close frame is logged with its code and reason, and a 4xxx is not reconnected; a 1012 restart is" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    const cases = [_]struct { ask: []const u8, line: []const u8, reconnects: bool }{
        .{ .ask = "close:4001 token expired", .line = "closed 4001 token expired", .reconnects = false },
        .{ .ask = "close:1012 restart", .line = "closed 1012 restart", .reconnects = true },
    };
    for (cases) |case| {
        // The echo server takes one connection; one apiece.
        var server = try ws.EchoServer.start(testing.allocator, testing.io);
        defer server.stop();
        const url = try std.fmt.allocPrint(testing.allocator, "ws://127.0.0.1:{d}/x", .{server.port});
        defer testing.allocator.free(url);
        const id = try open(&app, url);
        const p = app.panes.get(id).?.asWebsocket().?;
        var waited: usize = 0;
        while (p.state != .open and waited < 300) : (waited += 1) {
            try app.tick(App.nowMs(app.io));
            try Io.sleep(app.io, .fromMilliseconds(10), .awake);
        }
        try testing.expect(p.state == .open);
        for (case.ask) |c| try app.handle(.{ .key = Key.char(c) });
        try app.handle(.{ .key = Key.named(.enter) });
        waited = 0;
        while (p.state == .open and waited < 300) : (waited += 1) {
            try app.tick(App.nowMs(app.io));
            try Io.sleep(app.io, .fromMilliseconds(10), .awake);
        }
        var saw = false;
        var saw_dropped = false;
        for (p.log.items) |e| {
            if (std.mem.eql(u8, e.text, case.line)) saw = true;
            if (std.mem.eql(u8, e.text, "dropped")) saw_dropped = true;
        }
        try testing.expect(saw);
        try testing.expect(!saw_dropped);
        try testing.expectEqual(case.reconnects, p.reconnect_at_ms != null);
        p.reconnect_at_ms = null;
        p.disconnect();
    }
    try testing.expect(reconnectsAfter(4001, true));
    try testing.expect(!reconnectsAfter(1000, false));
}
