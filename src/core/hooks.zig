//! Hooks (D10.2): a curated set of moments in the app's life that Zig
//! code — and, later, Lua — can subscribe to. Payloads are flat
//! strings / ints / enums so a Lua bridge needs no custom marshalling.
//!
//! Emit points are explicit lines in the trunk (file open/save,
//! `focus.set`, the tick debounce, subsystem `handle`s). Emission is
//! UI-thread only; workers post events and let the handler emit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const command = @import("command.zig");

pub const Hook = enum {
    startup,
    exit,
    open,
    save_pre,
    save_post,
    /// Debounced 150 ms after the last edit.
    buffer_change,
    /// // changed (lua-decor): 300 ms after the cursor last moved, once
    /// per resting place (`app/idle.zig`) — what a blame line or any
    /// cursor-following decoration hangs off.
    cursor_idle,
    diagnostics,
    pane_focus,
    lsp_attach,
    git_status,
    /// A request pane's send, after its `@set-*` directives and the
    /// `{{VAR}}` expansion, before the wire. A subscriber may rewrite
    /// it through `rewrite`.
    http_request,
    /// A response landed on a request pane, after its `@assert` /
    /// `@capture` directives ran. Read-only.
    http_response,
};

pub const HookArgs = union(Hook) {
    startup: void,
    exit: void,
    /// Workspace-relative path; borrowed for the duration of the emit.
    open: struct { path: []const u8, pane: u32 },
    /// `auto`: an autosave wrote it, not a save the user asked for.
    /// `may_hold`: the saver can wait for the language server's edits
    /// (`lsp_format.Hold`) — `file.save` and `:w` can
    /// (`cmd_file.SaveOpts.may_hold`); a save-all, a close confirm's
    /// Save, autosave and the replace-in-files batch write cannot.
    save_pre: struct { path: []const u8, pane: u32, auto: bool = false, may_hold: bool = false },
    save_post: struct { path: []const u8, pane: u32, bytes: u64 },
    buffer_change: struct { pane: u32, line_count: u32 },
    cursor_idle: struct { pane: u32, line: u32 },
    diagnostics: struct { path: []const u8, errors: u32, warnings: u32 },
    pane_focus: struct { pane: ?u32 },
    lsp_attach: struct { server: []const u8, pane: u32 },
    git_status: struct { branch: []const u8, dirty: u32 },
    http_request: HttpRequestArgs,
    http_response: HttpResponseArgs,
};

// ─── the HTTP hooks ─────────────────────────────────────────────────────
// Their payloads are not flat: `headers` is a list the Lua bridge turns
// into a name → value table, and `http_request` carries a rewrite the
// subscribers fill. `scripting/api.zig` marshals these two by hand.

pub const HttpHeader = struct { name: []const u8, value: []const u8 };

/// Borrowed for the duration of the emit. `body` is null for a
/// bodiless request; `env` is the active env's name.
pub const HttpRequestArgs = struct {
    pane: u32,
    method: []const u8,
    url: []const u8,
    headers: []const HttpHeader,
    body: ?[]const u8,
    env: ?[]const u8,
    rewrite: *HttpRewrite,
};

/// Bodies past `http_body_cap` reach a subscriber cut there, with
/// `body_truncated` set — the Lua budget stays at 20 ms.
pub const http_body_cap: usize = 1 << 20;

pub const HttpResponseArgs = struct {
    pane: u32,
    status: u16,
    headers: []const HttpHeader,
    body: []const u8,
    body_truncated: bool,
    timing_ms: u64,
};

/// What `http_request` subscribers want changed before the send. A set
/// field replaces the request's; a later subscriber's set field wins.
/// `headers` replaces the whole set. Strings are owned by `gpa`; the
/// emitter applies the rewrite and frees it.
pub const HttpRewrite = struct {
    gpa: Allocator,
    method: ?[]u8 = null,
    url: ?[]u8 = null,
    headers: ?std.ArrayListUnmanaged(Header) = null,
    body: ?[]u8 = null,
    /// The body goes (`body = false` from Lua).
    clear_body: bool = false,

    pub const Header = struct { name: []u8, value: []u8 };

    pub fn init(gpa: Allocator) HttpRewrite {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HttpRewrite) void {
        const gpa = self.gpa;
        if (self.method) |m| gpa.free(m);
        if (self.url) |u| gpa.free(u);
        if (self.body) |b| gpa.free(b);
        self.dropHeaders();
        self.* = undefined;
    }

    fn dropHeaders(self: *HttpRewrite) void {
        if (self.headers) |*hs| {
            for (hs.items) |h| {
                self.gpa.free(h.name);
                self.gpa.free(h.value);
            }
            hs.deinit(self.gpa);
        }
        self.headers = null;
    }

    pub fn setMethod(self: *HttpRewrite, m: []const u8) Allocator.Error!void {
        const d = try self.gpa.dupe(u8, m);
        if (self.method) |old| self.gpa.free(old);
        self.method = d;
    }

    pub fn setUrl(self: *HttpRewrite, u: []const u8) Allocator.Error!void {
        const d = try self.gpa.dupe(u8, u);
        if (self.url) |old| self.gpa.free(old);
        self.url = d;
    }

    pub fn setBody(self: *HttpRewrite, b: []const u8) Allocator.Error!void {
        const d = try self.gpa.dupe(u8, b);
        if (self.body) |old| self.gpa.free(old);
        self.body = d;
        self.clear_body = false;
    }

    pub fn clearBody(self: *HttpRewrite) void {
        if (self.body) |old| self.gpa.free(old);
        self.body = null;
        self.clear_body = true;
    }

    /// Start a replacement header set (an earlier subscriber's goes).
    pub fn beginHeaders(self: *HttpRewrite) void {
        self.dropHeaders();
        self.headers = .empty;
    }

    pub fn addHeader(self: *HttpRewrite, name: []const u8, value: []const u8) Allocator.Error!void {
        if (self.headers == null) self.headers = .empty;
        const n = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(n);
        const v = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(v);
        try self.headers.?.append(self.gpa, .{ .name = n, .value = v });
    }

    pub fn any(self: *const HttpRewrite) bool {
        return self.method != null or self.url != null or self.headers != null or self.body != null or self.clear_body;
    }
};

pub const Subscriber = union(enum) {
    zig: *const fn (*App, HookArgs) void,
    lua: command.LuaRef,
};

pub const Hooks = struct {
    gpa: Allocator,
    subs: std.enums.EnumArray(Hook, std.ArrayList(Subscriber)) = .initFill(.empty),
    /// The thread that may emit. Set by `App.init`; asserted in `emit`.
    ui_thread: std.Thread.Id,

    pub fn init(gpa: Allocator) Hooks {
        return .{ .gpa = gpa, .ui_thread = std.Thread.getCurrentId() };
    }

    pub fn deinit(self: *Hooks) void {
        for (&self.subs.values) |*list| list.deinit(self.gpa);
    }

    pub fn subscribe(self: *Hooks, hook: Hook, sub: Subscriber) Allocator.Error!void {
        try self.subs.getPtr(hook).append(self.gpa, sub);
    }

    /// Remove every Lua subscriber (script reload). Returns how many went.
    pub fn unsubscribeLua(self: *Hooks) usize {
        var n: usize = 0;
        for (&self.subs.values) |*list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == .lua) {
                    _ = list.swapRemove(i);
                    n += 1;
                } else i += 1;
            }
        }
        return n;
    }

    /// Drop the subscribers ONE Lua state made — a single installed
    /// script reloading leaves every other script's hooks alone.
    pub fn unsubscribeState(self: *Hooks, state: u16) usize {
        var n: usize = 0;
        for (&self.subs.values) |*list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == .lua and list.items[i].lua.state == state) {
                    _ = list.swapRemove(i);
                    n += 1;
                } else i += 1;
            }
        }
        return n;
    }

    /// Deliver `args` to every subscriber of its hook, in subscription
    /// order. Never called under a lock or inside render.
    pub fn emit(self: *Hooks, app: *App, args: HookArgs) void {
        std.debug.assert(std.Thread.getCurrentId() == self.ui_thread);
        const hook = std.meta.activeTag(args);
        // Iterate by index: a subscriber may subscribe another.
        var i: usize = 0;
        while (i < self.subs.get(hook).items.len) : (i += 1) {
            switch (self.subs.get(hook).items[i]) {
                .zig => |f| f(app, args),
                .lua => |r| if (app.luaState(r.state)) |l| l.callHook(r, args),
            }
        }
    }

    pub fn count(self: *const Hooks, hook: Hook) usize {
        return self.subs.get(hook).items.len;
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const TestSink = struct {
    var saves: u32 = 0;
    var last_path: [64]u8 = undefined;
    var last_len: usize = 0;
    var opens: u32 = 0;

    fn onSave(_: *App, args: HookArgs) void {
        saves += 1;
        const p = args.save_post.path;
        @memcpy(last_path[0..p.len], p);
        last_len = p.len;
    }
    fn onOpen(_: *App, _: HookArgs) void {
        opens += 1;
    }
};

test "emit delivers to the hook's subscribers only, in order, with the payload" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    var hooks = Hooks.init(std.testing.allocator);
    defer hooks.deinit();
    TestSink.saves = 0;
    TestSink.opens = 0;
    try hooks.subscribe(.save_post, .{ .zig = &TestSink.onSave });
    try hooks.subscribe(.open, .{ .zig = &TestSink.onOpen });
    try hooks.subscribe(.save_post, .{ .lua = .{ .ref = 7 } });
    hooks.emit(&app, .{ .save_post = .{ .path = "src/main.zig", .pane = 0, .bytes = 42 } });
    try std.testing.expectEqual(@as(u32, 1), TestSink.saves);
    try std.testing.expectEqual(@as(u32, 0), TestSink.opens);
    try std.testing.expectEqualStrings("src/main.zig", TestSink.last_path[0..TestSink.last_len]);
    hooks.emit(&app, .{ .open = .{ .path = "a", .pane = 1 } });
    try std.testing.expectEqual(@as(u32, 1), TestSink.opens);
    try std.testing.expectEqual(@as(usize, 2), hooks.count(.save_post));
    try std.testing.expectEqual(@as(usize, 1), hooks.unsubscribeLua());
    try std.testing.expectEqual(@as(usize, 1), hooks.count(.save_post));
}

test "HttpRewrite: a set field replaces an earlier one, headers begin fresh, and it frees what it owns" {
    var rw = HttpRewrite.init(std.testing.allocator);
    defer rw.deinit();
    try std.testing.expect(!rw.any());
    try rw.setMethod("POST");
    try rw.setMethod("PUT");
    try rw.setUrl("http://a/");
    try rw.addHeader("A", "1");
    rw.beginHeaders();
    try rw.addHeader("B", "2");
    try rw.setBody("x");
    rw.clearBody();
    try std.testing.expectEqualStrings("PUT", rw.method.?);
    try std.testing.expectEqual(@as(usize, 1), rw.headers.?.items.len);
    try std.testing.expectEqualStrings("B", rw.headers.?.items[0].name);
    try std.testing.expect(rw.body == null and rw.clear_body and rw.any());
    try rw.setBody("y");
    try std.testing.expect(!rw.clear_body);
}
