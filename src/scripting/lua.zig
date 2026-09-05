//! The Lua state (D10). One `Lua` per App, on the UI thread only: every
//! entry asserts the thread, arms the budget, and goes through `pcall`,
//! so a script that loops forever or errors out costs one toast, never
//! the process.
//!
//! What a script can hold across calls is a registry reference
//! (`LuaRef`, the seams in `command.zig` / `hooks.zig`); what crosses the
//! boundary at call time is a frame-arena copy. `*App` is private to
//! this file and `api.zig` and is never exposed to Lua — the `mnml`
//! table is the whole surface.
//!
//! Budget: a count hook every 100 000 instructions checks a 20 ms
//! deadline armed at the outermost entry; a trip raises `mnml: script
//! budget exceeded`, which `pcall` catches like any other error.

const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const hooks = @import("../core/hooks.zig");
const script_view = @import("../ui/script_view.zig");
const api = @import("api.zig");

pub const State = zlua.Lua;
pub const LuaRef = command.LuaRef;
pub const Segment = script_view.Segment;

/// The count hook fires every this many VM instructions.
pub const hook_count: i32 = 100_000;
/// How long one outermost call may run.
pub const budget_ms: i64 = 20;
/// How often a statusline segment's function is asked again.
pub const segment_poll_ms: i64 = 250;
pub const max_init_bytes = 4 * 1024 * 1024;
/// The script the app runs at startup: `<data root>/init.lua`, then
/// `<workspace>/.mnml/init.lua` when the workspace is trusted.
pub const init_file = "init.lua";

pub const Side = enum { left, right };

/// `mnml.statusline.segment{ id, side, fn }` as the state keeps it.
pub const StatusSegment = struct {
    id: []u8,
    side: Side,
    func: LuaRef,
    /// The last string the function returned; null hides the segment.
    text: ?[]u8 = null,
    next_poll_ms: i64 = 0,
};

/// `mnml.picker.source{ id, title, items }` as the state keeps it.
pub const PickerSource = struct {
    id: []u8,
    title: []u8,
    items: LuaRef,
};

/// One item of an open `.lua` picker: what Enter calls.
pub const PickerItem = struct {
    on_accept: ?LuaRef,
};

/// `mnml.task.run{ cmd, on_done }`: the pane to watch and what to call.
pub const Task = struct {
    pane: PaneId,
    on_done: LuaRef,
};

pub const Lua = struct {
    L: *State,
    app: *App,
    gpa: Allocator,
    io: Io,
    ui_thread: std.Thread.Id,
    /// Set by the outermost `enter`; the count hook compares against it.
    deadline_ms: ?i64 = null,
    depth: u32 = 0,
    /// The last error `pcall` caught, on the frame arena.
    last_error: ?[]const u8 = null,
    /// How many scripts `loadInit` has run since the last reset.
    loaded_files: u32 = 0,
    map_seq: u32 = 0,
    segments: std.ArrayList(StatusSegment) = .empty,
    sources: std.ArrayList(PickerSource) = .empty,
    /// The `on_accept` refs of the picker that is open, by row.
    picker_items: std.ArrayList(PickerItem) = .empty,
    tasks: std.ArrayList(Task) = .empty,

    /// A fresh state with `base string table math utf8` open, `dofile`
    /// / `loadfile` removed, `print` routed to a toast, and the `mnml`
    /// table installed. Heap-allocated: the C hook finds it through the
    /// state's extra space, so its address must not move.
    pub fn create(gpa: Allocator, io: Io, app: *App) Allocator.Error!*Lua {
        const self = try gpa.create(Lua);
        errdefer gpa.destroy(self);
        self.* = .{
            .L = undefined,
            .app = app,
            .gpa = gpa,
            .io = io,
            .ui_thread = std.Thread.getCurrentId(),
        };
        try self.openState();
        return self;
    }

    pub fn destroy(self: *Lua) void {
        self.closeState();
        self.segments.deinit(self.gpa);
        self.sources.deinit(self.gpa);
        self.picker_items.deinit(self.gpa);
        self.tasks.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn openState(self: *Lua) Allocator.Error!void {
        const L = try State.init(self.gpa);
        self.L = L;
        attach(L, self);
        L.openBase();
        L.openString();
        L.openTable();
        L.openMath();
        L.openUtf8();
        // The base lib reaches the file system through these two; a
        // script shells out through `mnml.task.run` and nothing else.
        L.pushNil();
        L.setGlobal("dofile");
        L.pushNil();
        L.setGlobal("loadfile");
        L.pushFunction(zlua.wrap(api.print));
        L.setGlobal("print");
        api.install(self);
    }

    fn closeState(self: *Lua) void {
        for (self.segments.items) |s| {
            self.gpa.free(s.id);
            if (s.text) |t| self.gpa.free(t);
        }
        self.segments.clearRetainingCapacity();
        for (self.sources.items) |s| {
            self.gpa.free(s.id);
            self.gpa.free(s.title);
        }
        self.sources.clearRetainingCapacity();
        self.picker_items.clearRetainingCapacity();
        self.tasks.clearRetainingCapacity();
        self.loaded_files = 0;
        self.map_seq = 0;
        self.L.deinit();
    }

    // ── the pointer both ways ──

    fn attach(L: *State, self: *Lua) void {
        const space = L.getExtraSpace();
        std.mem.writeInt(usize, space[0..@sizeOf(usize)], @intFromPtr(self), builtin.cpu.arch.endian());
    }

    /// The wrapper behind a state — what a `zlua.wrap`ped function and
    /// the count hook call to reach the app.
    pub fn of(L: *State) *Lua {
        const space = L.getExtraSpace();
        return @ptrFromInt(std.mem.readInt(usize, space[0..@sizeOf(usize)], builtin.cpu.arch.endian()));
    }

    // ── refs ──

    /// Pop the top of the stack into the registry.
    pub fn ref(self: *Lua) LuaRef {
        const r = self.L.ref(zlua.registry_index);
        std.debug.assert(r > 0);
        return @intCast(r);
    }

    pub fn unref(self: *Lua, r: LuaRef) void {
        self.L.unref(zlua.registry_index, @intCast(r));
    }

    /// Push the registry value `r`.
    pub fn pushRef(self: *Lua, r: LuaRef) void {
        _ = self.L.getIndexRaw(zlua.registry_index, @intCast(r));
    }

    // ── budget ──

    const DebugPtr = @typeInfo(@typeInfo(zlua.CHookFn).pointer.child).@"fn".params[1].type.?;

    fn countHook(state: ?*zlua.LuaState, _: DebugPtr) callconv(.c) void {
        const L: *State = @ptrCast(state.?);
        const self = of(L);
        const deadline = self.deadline_ms orelse return;
        if (App.nowMs(self.io) >= deadline) L.raiseErrorStr("mnml: script budget exceeded", .{});
    }

    /// UI-thread assertion plus the budget for the outermost call. Pair
    /// with `leave`.
    fn enter(self: *Lua) void {
        std.debug.assert(std.Thread.getCurrentId() == self.ui_thread);
        if (self.depth == 0) {
            self.deadline_ms = App.nowMs(self.io) + budget_ms;
            self.L.setHook(&countHook, .{ .count = true }, hook_count);
        }
        self.depth += 1;
    }

    fn leave(self: *Lua) void {
        self.depth -= 1;
        if (self.depth == 0) {
            self.L.setHook(&countHook, .{}, 0);
            self.deadline_ms = null;
        }
    }

    fn tracebackHandler(L: *State) i32 {
        const msg = L.toStringEx(1);
        L.traceback(L, msg, 1);
        return 1;
    }

    /// Call the function at `-(nargs + 1)` with `nargs` arguments under a
    /// traceback handler and the budget. On failure the message is in
    /// `last_error` (frame arena) and the stack is as it was before the
    /// function was pushed.
    pub fn pcall(self: *Lua, nargs: i32, nresults: i32) error{Failed}!void {
        const L = self.L;
        const base = L.getTop() - nargs;
        L.pushFunction(zlua.wrap(tracebackHandler));
        L.insert(base);
        self.enter();
        const result = L.protectedCall(.{ .args = nargs, .results = nresults, .msg_handler = base });
        self.leave();
        L.remove(base);
        result catch {
            // `toStringEx` pushes the string form; pop it and the error object.
            const msg = L.toStringEx(-1);
            self.last_error = self.app.frame.allocator().dupe(u8, msg) catch "script error";
            L.pop(2);
            return error.Failed;
        };
    }

    fn toastError(self: *Lua, comptime what: []const u8) void {
        self.app.toastLevel(.err, what ++ ": {s}", .{self.last_error orelse "script error"}) catch {};
    }

    // ── loading ──

    /// Run `path` as a chunk. A missing file is not an error (false); a
    /// syntax or runtime error toasts and returns `error.Failed`.
    pub fn loadInit(self: *Lua, path: []const u8) error{ Failed, OutOfMemory }!bool {
        const gpa = self.gpa;
        const src = Io.Dir.cwd().readFileAllocOptions(self.io, path, gpa, .limited(max_init_bytes), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.app.toastLevel(.err, "{s}: cannot read: {s}", .{ path, @errorName(err) }) catch {};
                return error.Failed;
            },
        };
        defer gpa.free(src);
        const name = try std.fmt.allocPrintSentinel(gpa, "@{s}", .{path}, 0);
        defer gpa.free(name);
        self.L.loadBuffer(src, name, .text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LuaSyntax => {
                const msg = self.L.toStringEx(-1);
                self.app.toastLevel(.err, "{s}", .{msg}) catch {};
                self.L.pop(2);
                return error.Failed;
            },
        };
        self.pcall(0, 0) catch {
            self.toastError("init.lua");
            return error.Failed;
        };
        self.loaded_files += 1;
        return true;
    }

    /// The two `init.lua` files, in order: the user's from the data
    /// root, then the workspace's — only when the workspace is trusted
    /// (`trust.zig` lists it as an exec-bearing claim). A failing file
    /// toasts and the next one still runs.
    pub fn loadInitFiles(self: *Lua) Allocator.Error!void {
        const app = self.app;
        const arena = app.frame.allocator();
        if (app.data_root.len != 0) {
            const path = try std.fs.path.join(arena, &.{ app.data_root, init_file });
            _ = self.loadInit(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => {},
            };
        }
        if (app.workspace_trusted) {
            const path = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", init_file });
            _ = self.loadInit(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => {},
            };
        }
    }

    /// Run a string as a chunk named `lua` (the `:lua` line, tests).
    /// Errors toast.
    pub fn runString(self: *Lua, src: []const u8) error{ Failed, OutOfMemory }!void {
        self.L.loadBuffer(src, "=lua", .text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LuaSyntax => {
                const msg = self.L.toStringEx(-1);
                self.last_error = self.app.frame.allocator().dupe(u8, msg) catch "syntax error";
                self.L.pop(2);
                self.toastError("lua");
                return error.Failed;
            },
        };
        self.pcall(0, 0) catch {
            self.toastError("lua");
            return error.Failed;
        };
    }

    // ── the seams ──

    /// A `DynRunner.lua` command. The reason lands in `app.diag`, so
    /// `command.run` toasts it once.
    pub fn callCommand(self: *Lua, r: LuaRef) command.CommandError!void {
        self.pushRef(r);
        self.pcall(0, 0) catch return self.app.diag.fail(self.app.frame.allocator(), "{s}", .{self.last_error orelse "script error"});
    }

    /// A `Subscriber.lua` hook: the payload table (its fields per
    /// `HookArgs`, plus `hook = "<name>"`) is the one argument.
    pub fn callHook(self: *Lua, r: LuaRef, args: hooks.HookArgs) void {
        const L = self.L;
        self.pushRef(r);
        switch (args) {
            inline else => |payload| L.pushAny(payload) catch {
                L.pop(1);
                return;
            },
        }
        _ = L.pushString(@tagName(args));
        L.setField(-2, "hook");
        self.pcall(1, 0) catch self.toastError("hook");
    }

    /// `render(w, h)` → rows of segments on the frame arena. A failing
    /// render paints its message in the pane instead of toasting every
    /// frame.
    pub fn callRender(self: *Lua, r: LuaRef, w: u16, h: u16) Allocator.Error![]const []const Segment {
        const arena = self.app.frame.allocator();
        const L = self.L;
        self.pushRef(r);
        L.pushInteger(w);
        L.pushInteger(h);
        self.pcall(2, 1) catch {
            const row = try arena.alloc(Segment, 1);
            row[0] = .{ .text = self.last_error orelse "script error", .style = self.app.theme.error_fg };
            const rows = try arena.alloc([]const Segment, 1);
            rows[0] = row;
            return rows;
        };
        defer L.pop(1);
        return self.decodeRows(arena, -1);
    }

    fn decodeRows(self: *Lua, arena: Allocator, index: i32) Allocator.Error![]const []const Segment {
        const L = self.L;
        const t = L.absIndex(index);
        var rows: std.ArrayList([]const Segment) = .empty;
        switch (L.typeOf(t)) {
            .string => {
                const s = L.toString(t) catch "";
                try rows.append(arena, try self.oneSegment(arena, s));
            },
            .table => {
                const n = L.lenRaw(t);
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    _ = L.getIndex(t, @intCast(i));
                    defer L.pop(1);
                    try rows.append(arena, try self.decodeRow(arena, -1));
                }
            },
            else => {},
        }
        return rows.toOwnedSlice(arena);
    }

    fn oneSegment(self: *Lua, arena: Allocator, s: []const u8) Allocator.Error![]const Segment {
        const row = try arena.alloc(Segment, 1);
        row[0] = .{ .text = try arena.dupe(u8, s), .style = self.app.theme.fg };
        return row;
    }

    fn decodeRow(self: *Lua, arena: Allocator, index: i32) Allocator.Error![]const Segment {
        const L = self.L;
        const t = L.absIndex(index);
        switch (L.typeOf(t)) {
            .string, .number => return self.oneSegment(arena, L.toString(t) catch ""),
            .table => {},
            else => return &.{},
        }
        // A row table with a `text` key is a single segment.
        if (L.getField(t, "text") != .nil) {
            L.pop(1);
            const seg = try arena.alloc(Segment, 1);
            seg[0] = try self.decodeSegment(arena, t);
            return seg;
        }
        L.pop(1);
        const n = L.lenRaw(t);
        const segs = try arena.alloc(Segment, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = L.getIndex(t, @intCast(i + 1));
            defer L.pop(1);
            segs[i] = switch (L.typeOf(-1)) {
                .table => try self.decodeSegment(arena, -1),
                else => .{ .text = try arena.dupe(u8, L.toString(-1) catch ""), .style = self.app.theme.fg },
            };
        }
        return segs;
    }

    fn stringField(L: *State, t: i32, name: [:0]const u8) ?[]const u8 {
        _ = L.getField(t, name);
        defer L.pop(1);
        if (L.typeOf(-1) != .string) return null;
        return L.toString(-1) catch null;
    }

    fn boolField(L: *State, t: i32, name: [:0]const u8) bool {
        _ = L.getField(t, name);
        defer L.pop(1);
        return L.toBoolean(-1);
    }

    fn decodeSegment(self: *Lua, arena: Allocator, index: i32) Allocator.Error!Segment {
        const L = self.L;
        const t = L.absIndex(index);
        var spec: script_view.StyleSpec = .{};
        const text = try arena.dupe(u8, stringField(L, t, "text") orelse "");
        if (stringField(L, t, "fg")) |s| spec.fg = try arena.dupe(u8, s);
        if (stringField(L, t, "bg")) |s| spec.bg = try arena.dupe(u8, s);
        spec.bold = boolField(L, t, "bold");
        spec.italic = boolField(L, t, "italic");
        spec.underline = boolField(L, t, "underline");
        _ = L.getField(t, "hit");
        const hit: ?u32 = if (L.toInteger(-1)) |n| (if (n >= 0) @intCast(n) else null) else |_| null;
        L.pop(1);
        return .{ .text = text, .style = script_view.resolve(&self.app.theme, spec), .hit = hit };
    }

    /// `on_hit(id, button)`.
    pub fn callHit(self: *Lua, r: LuaRef, id: u32, button: []const u8) void {
        const L = self.L;
        self.pushRef(r);
        L.pushInteger(id);
        _ = L.pushString(button);
        self.pcall(2, 0) catch self.toastError("on_hit");
    }

    /// `on_key(name)` → whether the script consumed it.
    pub fn callKey(self: *Lua, r: LuaRef, name: []const u8) bool {
        const L = self.L;
        self.pushRef(r);
        _ = L.pushString(name);
        self.pcall(1, 1) catch {
            self.toastError("on_key");
            return false;
        };
        defer L.pop(1);
        return L.toBoolean(-1);
    }

    /// A statusline segment's function → its text on the frame arena,
    /// null to hide it.
    fn callSegment(self: *Lua, r: LuaRef) ?[]const u8 {
        const L = self.L;
        self.pushRef(r);
        self.pcall(0, 1) catch {
            self.toastError("statusline segment");
            return null;
        };
        defer L.pop(1);
        if (L.isNoneOrNil(-1)) return null;
        const s = L.toStringEx(-1);
        defer L.pop(1);
        return self.app.frame.allocator().dupe(u8, s) catch null;
    }

    /// A picker source's `items(query)` → labels and details (gpa, the
    /// picker takes them) with the `on_accept` refs kept in
    /// `picker_items`. Each item is a string or `{ label, detail?,
    /// on_accept? }`.
    pub fn callItems(self: *Lua, r: LuaRef, query: []const u8, labels: *std.ArrayList([]u8), details: *std.ArrayList([]u8)) Allocator.Error!void {
        const L = self.L;
        const gpa = self.gpa;
        self.pushRef(r);
        _ = L.pushString(query);
        self.pcall(1, 1) catch {
            self.toastError("picker items");
            return;
        };
        defer L.pop(1);
        self.pickerClosed();
        if (!L.isTable(-1)) return;
        const n = L.lenRaw(-1);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i));
            defer L.pop(1);
            var on_accept: ?LuaRef = null;
            var label: []const u8 = "";
            var detail: []const u8 = "";
            if (L.isTable(-1)) {
                label = stringField(L, -1, "label") orelse "";
                detail = stringField(L, -1, "detail") orelse "";
                _ = L.getField(-1, "on_accept");
                if (L.isFunction(-1)) {
                    on_accept = self.ref();
                } else L.pop(1);
            } else {
                label = L.toString(-1) catch "";
            }
            const l = try gpa.dupe(u8, label);
            errdefer gpa.free(l);
            const d = try gpa.dupe(u8, detail);
            errdefer gpa.free(d);
            try labels.append(gpa, l);
            try details.append(gpa, d);
            try self.picker_items.append(gpa, .{ .on_accept = on_accept });
        }
    }

    /// Enter on row `i` of an open `.lua` picker: `on_accept(label)`.
    pub fn acceptItem(self: *Lua, i: usize, label: []const u8) void {
        if (i >= self.picker_items.items.len) return;
        const r = self.picker_items.items[i].on_accept orelse return;
        self.pushRef(r);
        _ = self.L.pushString(label);
        self.pcall(1, 0) catch self.toastError("on_accept");
    }

    /// The picker closed (or a new item list replaces the old): drop the
    /// item refs.
    pub fn pickerClosed(self: *Lua) void {
        for (self.picker_items.items) |it| if (it.on_accept) |a| self.unref(a);
        self.picker_items.clearRetainingCapacity();
    }

    pub fn findSource(self: *Lua, id: []const u8) ?*PickerSource {
        for (self.sources.items) |*s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }

    // ── tick: segments and tasks ──

    /// Poll every statusline segment whose interval elapsed and finish
    /// every task whose pane exited.
    pub fn tick(self: *Lua, now: i64) Allocator.Error!void {
        for (self.segments.items) |*s| {
            if (now < s.next_poll_ms) continue;
            s.next_poll_ms = now + segment_poll_ms;
            const fresh = self.callSegment(s.func);
            const same = if (s.text) |old| (if (fresh) |f| std.mem.eql(u8, old, f) else false) else fresh == null;
            if (same) continue;
            if (s.text) |old| self.gpa.free(old);
            s.text = if (fresh) |f| try self.gpa.dupe(u8, f) else null;
            self.app.needs_render = true;
        }
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const task = self.tasks.items[i];
            const p = self.app.panes.pty(task.pane) orelse {
                self.unref(task.on_done);
                _ = self.tasks.swapRemove(i);
                continue;
            };
            const exit = p.exit orelse {
                i += 1;
                continue;
            };
            _ = self.tasks.swapRemove(i);
            defer self.unref(task.on_done);
            const L = self.L;
            self.pushRef(task.on_done);
            L.createTable(0, 2);
            L.pushBoolean(exit.ok());
            L.setField(-2, "ok");
            switch (exit) {
                .code => |c| {
                    L.pushInteger(c);
                    L.setField(-2, "code");
                },
                .signal => |s| {
                    L.pushInteger(s);
                    L.setField(-2, "signal");
                },
            }
            self.pcall(1, 0) catch self.toastError("on_done");
        }
    }

    pub fn nextDeadlineMs(self: *const Lua) ?i64 {
        var next: ?i64 = null;
        for (self.segments.items) |s| next = @min(next orelse std.math.maxInt(i64), s.next_poll_ms);
        if (self.tasks.items.len > 0) next = @min(next orelse std.math.maxInt(i64), self.app.now_ms + 100);
        return next;
    }

    /// The texts of the segments on `side`, in registration order.
    pub fn segmentTexts(self: *const Lua, arena: Allocator, side: Side) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.segments.items) |s| {
            if (s.side != side) continue;
            const text = s.text orelse continue;
            try out.append(arena, text);
        }
        return out.toOwnedSlice(arena);
    }

    // ── reset ──

    /// Everything a script registered goes — its commands and their
    /// chords, its hooks, panes, segments, sources, tasks — and the state
    /// is closed and reopened, so nothing survives that could reference
    /// the old registry. The configured tasks' commands share the
    /// `.script` owner and are reinstalled.
    pub fn reset(self: *Lua) Allocator.Error!void {
        std.debug.assert(std.Thread.getCurrentId() == self.ui_thread);
        const app = self.app;
        // Script panes first: their deinit unrefs into the state that is
        // about to close.
        var i: usize = 0;
        while (i < app.panes.slots.items.len) : (i += 1) {
            const slot = app.panes.slots.items[i] orelse continue;
            if (slot == .script) try app.forceClosePane(@intCast(i));
        }
        for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
            if (!alive or c.owner != .script) continue;
            for (c.keys) |k| app.keymap.unbind(k);
        }
        _ = app.dyn_commands.unregisterOwner(.script);
        _ = app.hooks.unsubscribeLua();
        if (app.overlay == .picker and app.overlay.picker.kind == .lua) {
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
        }
        self.closeState();
        try self.openState();
        try app.keymap.rebuildPrefixes();
        try @import("../app/tasks.zig").installFromConfig(app, &app.cfg);
        app.needs_render = true;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "libs: base/string/table/math/utf8 only; dofile/loadfile gone; os/io nil" {
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\assert(os == nil and io == nil and package == nil and debug == nil)
        \\assert(dofile == nil and loadfile == nil and require == nil)
        \\assert(string.format('%d', 3) == '3' and table.concat({'a','b'}) == 'ab')
        \\assert(math.max(1, 2) == 2 and utf8.len('héllo') == 5)
        \\assert(type(mnml) == 'table' and type(mnml.command) == 'function')
    );
}

test "budget: an infinite loop trips after the deadline and the app survives" {
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    try testing.expectError(error.Failed, lua.runString("while true do end"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "script budget exceeded") != null);
    try testing.expect(lua.deadline_ms == null);
    try testing.expectEqual(@as(u32, 0), lua.depth);
    // Still a working state afterwards.
    try lua.runString("x = 41 + 1");
    _ = lua.L.getGlobal("x");
    try testing.expectEqual(@as(zlua.Integer, 42), try lua.L.toInteger(-1));
    lua.L.pop(1);
    // The toast said so.
    try testing.expect(app.toasts.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, app.toasts.items[0].text, "budget") != null);
}

test "a runtime error carries a traceback and leaves the stack level" {
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    const top = lua.L.getTop();
    try testing.expectError(error.Failed, lua.runString("local function inner() error('boom') end inner()"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "boom") != null);
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "traceback") != null);
    try testing.expectEqual(top, lua.L.getTop());
}

fn zigSaveSubs(app: *App) usize {
    var n: usize = 0;
    for (app.hooks.subs.get(.save_post).items) |s| if (s == .zig) {
        n += 1;
    };
    return n;
}

test "ref/unref round-trips and a reset reopens the state leak-free" {
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    lua.L.pushInteger(7);
    const r = lua.ref();
    lua.pushRef(r);
    try testing.expectEqual(@as(zlua.Integer, 7), try lua.L.toInteger(-1));
    lua.L.pop(1);
    lua.unref(r);
    try lua.runString("mnml.on('save_post', function() end); mnml.command{ id = 'x', run = function() end }");
    try testing.expect(app.dyn_commands.get("user.x") != null);
    try testing.expectEqual(@as(usize, 1), app.hooks.count(.save_post) - zigSaveSubs(&app));
    try lua.reset();
    try testing.expect(app.dyn_commands.get("user.x") == null);
    try testing.expectEqual(@as(usize, 0), app.hooks.count(.save_post) - zigSaveSubs(&app));
    try lua.runString("assert(type(mnml) == 'table')");
}

test "loadInit: a missing file is false; a syntax error toasts; a chunk runs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "nope.lua" });
    defer testing.allocator.free(missing);
    try testing.expect(!try lua.loadInit(missing));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.lua", .data = "this is not lua" });
    const bad = try std.fs.path.join(testing.allocator, &.{ root, "bad.lua" });
    defer testing.allocator.free(bad);
    try testing.expectError(error.Failed, lua.loadInit(bad));
    try testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.lua", .data = "mnml.command{ id = 'from_file', run = function() end }" });
    const ok = try std.fs.path.join(testing.allocator, &.{ root, "ok.lua" });
    defer testing.allocator.free(ok);
    try testing.expect(try lua.loadInit(ok));
    try testing.expect(app.dyn_commands.get("user.from_file") != null);
    try testing.expectEqual(@as(u32, 1), lua.loaded_files);
}
