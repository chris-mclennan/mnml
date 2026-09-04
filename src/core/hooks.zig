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
    diagnostics,
    pane_focus,
    lsp_attach,
    git_status,
};

pub const HookArgs = union(Hook) {
    startup: void,
    exit: void,
    /// Workspace-relative path; borrowed for the duration of the emit.
    open: struct { path: []const u8, pane: u32 },
    save_pre: struct { path: []const u8, pane: u32 },
    save_post: struct { path: []const u8, pane: u32, bytes: u64 },
    buffer_change: struct { pane: u32, line_count: u32 },
    diagnostics: struct { path: []const u8, errors: u32, warnings: u32 },
    pane_focus: struct { pane: ?u32 },
    lsp_attach: struct { server: []const u8, pane: u32 },
    git_status: struct { branch: []const u8, dirty: u32 },
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
                .lua => {}, // TODO(lua): registry lookup + budgeted protectedCall (D10.2)
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
    try hooks.subscribe(.save_post, .{ .lua = 7 });
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
