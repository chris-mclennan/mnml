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
//! Budget: a count hook every 100 000 instructions checks the
//! `budget_ms` deadline armed at the outermost entry. A trip is not an
//! ordinary error a script can swallow: the state is marked `tripped`,
//! the hook then fires on EVERY instruction and raises again, and the
//! `pcall` / `xpcall` a script sees rethrow instead of returning false
//! — so the raise climbs all the way out to the host's own `pcall`,
//! however many protected calls the script stacked in its way.
//!
//! A hook only runs between VM instructions, and one call into a C
//! function is one instruction however long it takes. The C function
//! that can take long on a short input is the pattern matcher —
//! `('a'):rep(1e5):find('.-b')` is quadratic, seconds of UI thread — so
//! Lua's `lstrlib.c` is built from a patched copy
//! (`vendor/lua54/lstrlib.c`) whose matcher asks `spent()` every few
//! thousand steps. What a single C call can still cost past the budget
//! is bounded by its input rather than cut: a `table.sort`, `concat`,
//! `rep` or `utf8` walk is linear (or n log n) in data a budgeted loop
//! had to build first, or in a size the script names (`string.rep('x',
//! 1e9)` allocates and fills a gigabyte before the next instruction
//! checks the clock). Host `mnml.*` functions are ours and do bounded
//! work per call.

const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const hooks = @import("../core/hooks.zig");
const script_view = @import("../ui/script_view.zig");
const api = @import("api.zig");
const diag = @import("diag.zig");
const script_list = @import("../app/script_list.zig");
const build_options = @import("build_options");

pub const State = zlua.Lua;

/// The patched `lstrlib.c`'s question to the host: is the budget of the
/// call running on this state spent? Nonzero raises the budget error
/// from inside the match. Set once per process; a state not inside a
/// budgeted call answers no.
extern var mnml_lstr_budget: ?*const fn (?*zlua.LuaState) callconv(.c) c_int;
pub const LuaRef = command.LuaRef;
pub const Segment = script_view.Segment;

/// The count hook fires every this many VM instructions.
pub const hook_count: i32 = 100_000;
/// What a budget trip raises, and what the host reports it as.
pub const budget_msg = "mnml: script budget exceeded";
/// A frame's worth of work: what the budget protects in a SHIPPED
/// build, where a script must not hold the UI thread longer than one.
pub const frame_budget_ms: i64 = 20;
/// The headroom a Debug build's runaway budget keeps over the work an
/// honest script does there, on top of the slowdown itself.
const runaway_headroom = 5;
/// A Debug build does not get a frame budget, because a frame budget
/// there would not be measuring a frame. The budget is wall clock, but
/// most of what it bounds is HOST code — `mnml.commands()` walks eleven
/// hundred command specs and builds a table per row; `callItems` then
/// copies every row back out — and unoptimized host code, through an
/// unoptimized allocator, is not a little slower but much slower, and
/// not by a constant: a pure Lua loop costs the same in both builds
/// (the VM is a C dependency, not rebuilt), while one
/// `mnml.commands("")` costs ≤ 0.6 ms against ReleaseSafe and 5–10 ms
/// against Debug. The repo's own `lua/recent-commands` example — one of
/// those calls, a row per command, a sort — needs under 20 ms in a
/// shipped build and over 400 ms in a Debug one.
///
/// So Debug gets a RUNAWAY budget instead: long enough that no finite
/// script trips it, short enough that `while true do end` still costs
/// one toast rather than the editor. It is derived from the same
/// measured slowdown the `.test` runner scales its deadlines by
/// (`src/e2e/runner.zig`'s `debug_slowdown`), so the two cannot drift
/// apart, plus headroom.
pub const runaway_budget_ms: i64 = frame_budget_ms * build_options.debug_slowdown * runaway_headroom;
/// How long one outermost call may run. The frame guarantee is a
/// shipped-build guarantee; `zig build check`'s Debug leg is not where
/// it is measured.
pub const budget_ms: i64 = if (compat.is_debug) runaway_budget_ms else frame_budget_ms;
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
    /// The function errored: the one toast has been shown, the segment
    /// is hidden, and it is not asked again until the script reloads —
    /// an erroring render paints in its pane once in the same spirit.
    failed: bool = false,
};

/// `mnml.picker.source{ id, title, items, live?, preview?, multi?,
/// on_accept? }` as the state keeps it.
pub const PickerSource = struct {
    id: []u8,
    title: []u8,
    items: LuaRef,
    /// `items(query)` runs again as the query changes (debounced).
    live: bool = false,
    /// Tab marks a row; Enter hands `on_accept` the list of marked rows.
    multi: bool = false,
    /// `preview(row)` → rows for the picker's preview column.
    preview: ?LuaRef = null,
    /// The source-wide accept: the row table (or the list of them).
    on_accept: ?LuaRef = null,
};

/// One item of an open `.lua` picker: the row table as the script built
/// it (so `data` comes back untouched) and the row's own `on_accept`.
pub const PickerItem = struct {
    on_accept: ?LuaRef,
    /// The whole row table, or null for a plain-string row.
    row: ?LuaRef = null,
};

/// How long the picker waits after a keystroke before asking a live
/// source again. Long enough that a typed word is one call, short
/// enough that the list never feels stale.
pub const live_debounce_ms: i64 = 80;

/// `mnml.operator{ id, keys, run }` as the state keeps it. The vim
/// chord lives in `input/script_ops.zig` (the handler's own table); the
/// standard chord is an ordinary `user.<id>` command, so the palette,
/// the which-key list and `mnml.run` all find it.
pub const Operator = struct {
    id: []u8,
    run: LuaRef,
};

/// `mnml.task.run{ cmd, on_done }`: the pane to watch and what to call.
pub const Task = struct {
    pane: PaneId,
    on_done: LuaRef,
};

/// `mnml.task.run{ hidden = true, on_line = fn, on_done = fn }`: a run
/// with no pane (`app/script_task.zig`), found by the run's id when its
/// lines and its exit arrive.
pub const HiddenTask = struct {
    id: u32,
    on_line: ?LuaRef = null,
    on_done: ?LuaRef = null,
};

pub const OriginKind = enum {
    command,
    hook,
    segment,
    source,
    operator,
    list,

    pub fn label(k: OriginKind) []const u8 {
        return switch (k) {
            .command => "command",
            .hook => "hook",
            .segment => "segment",
            .source => "picker",
            .operator => "operator",
            .list => "list",
        };
    }
};

/// What a script registered and where: the `file:line` of the
/// `mnml.command` / `mnml.on` / `mnml.statusline.segment` /
/// `mnml.picker.source` call, read off the Lua stack at registration
/// (the SCRIPTS section's rows). Gpa-owned strings; a registration
/// under the same kind and name replaces its row.
pub const Origin = struct {
    kind: OriginKind,
    /// The command id (`user.hello`), the hook name, the segment or
    /// source id.
    name: []u8,
    /// Absolute; empty for a chunk that is not a file (`:lua`).
    file: []u8,
    /// 1-based; 0 when unknown.
    line: u32,
};

/// How many of each kind a reload registered — the toast's numbers.
pub const Summary = struct {
    commands: u32 = 0,
    hooks: u32 = 0,
    segments: u32 = 0,
    sources: u32 = 0,
    operators: u32 = 0,
    lists: u32 = 0,
};

pub const Lua = struct {
    L: *State,
    app: *App,
    gpa: Allocator,
    io: Io,
    ui_thread: std.Thread.Id,
    /// Which state this is: 0 is the App's `init.lua` state, 1.. an
    /// installed script's own (`app/scripts.zig`). Every `LuaRef` this
    /// state hands out carries it, so a ref never reaches another
    /// state's registry.
    id: u16 = 0,
    /// The installed script's name, "" for the `init.lua` state. It
    /// prefixes the decoration namespaces and labels the origins.
    script_name: []const u8 = "",
    /// The script's directory — the only place a scoped `require`
    /// looks. Null for the `init.lua` state, which has no `require`.
    root: ?[]const u8 = null,
    /// How many times the 20 ms budget tripped in this session — the
    /// SCRIPTS row's chip and `script.doctor`'s column.
    budget_hits: u32 = 0,
    /// The scoped `require`'s cache table, when this state has one.
    modules: ?LuaRef = null,
    /// Set by the outermost `enter`; the count hook compares against it.
    deadline_ms: ?i64 = null,
    /// The budget ran out during the current outermost call. From then
    /// until that call returns, every instruction raises and the
    /// script's `pcall` / `xpcall` rethrow: the trip cannot be caught.
    tripped: bool = false,
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
    /// `mnml.operator{}`, in registration order — the index is what
    /// `input/script_ops.zig` and `AppCommand.script_operator` carry.
    operators: std.ArrayList(Operator) = .empty,
    /// The `run` refs of the list row menu that is open, by row.
    menu_items: std.ArrayList(LuaRef) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    hidden_tasks: std.ArrayList(HiddenTask) = .empty,
    /// Everything registered since the last reset, in order.
    origins: std.ArrayList(Origin) = .empty,
    /// The script error that is a diagnostic right now (`diag.zig`).
    report: ?diag.Report = null,
    /// Whether the last `loadInitFiles` ran every file clean.
    last_load_ok: bool = true,

    /// A fresh state with `base string table math utf8` open, `dofile`
    /// / `loadfile` removed, `print` routed to a toast, and the `mnml`
    /// table installed. Heap-allocated: the C hook finds it through the
    /// state's extra space, so its address must not move.
    pub fn create(gpa: Allocator, io: Io, app: *App) Allocator.Error!*Lua {
        return createFor(gpa, io, app, 0, "", null);
    }

    /// A state for an installed script: its own id, its own name and
    /// the directory a scoped `require` may read under.
    pub fn createFor(gpa: Allocator, io: Io, app: *App, id: u16, script_name: []const u8, root: ?[]const u8) Allocator.Error!*Lua {
        const self = try gpa.create(Lua);
        errdefer gpa.destroy(self);
        self.* = .{
            .L = undefined,
            .app = app,
            .gpa = gpa,
            .io = io,
            .ui_thread = std.Thread.getCurrentId(),
            .id = id,
            .script_name = script_name,
            .root = root,
        };
        try self.openState();
        return self;
    }

    pub fn destroy(self: *Lua) void {
        self.closeState();
        self.segments.deinit(self.gpa);
        self.sources.deinit(self.gpa);
        self.picker_items.deinit(self.gpa);
        self.operators.deinit(self.gpa);
        self.menu_items.deinit(self.gpa);
        self.tasks.deinit(self.gpa);
        self.hidden_tasks.deinit(self.gpa);
        self.origins.deinit(self.gpa);
        if (self.report) |r| self.gpa.free(r.path);
        self.gpa.destroy(self);
    }

    fn openState(self: *Lua) Allocator.Error!void {
        // The operator table is process-global (the vim handler has no
        // App): a fresh state starts with its own claims cleared,
        // whatever the last App in this process left behind.
        @import("../input/script_ops.zig").clearState(self.gpa, self.id);
        const L = try State.init(self.gpa);
        self.L = L;
        attach(L, self);
        mnml_lstr_budget = &strBudget;
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
        // A budget trip must reach the host: the script's own protected
        // calls rethrow it (see `guardedPcall`).
        _ = L.getGlobal("pcall");
        L.pushClosure(zlua.wrap(guardedPcall), 1);
        L.setGlobal("pcall");
        _ = L.getGlobal("xpcall");
        L.pushClosure(zlua.wrap(guardedXpcall), 1);
        L.setGlobal("xpcall");
        // Source text only: see `textLoad`.
        _ = L.getGlobal("load");
        L.pushClosure(zlua.wrap(textLoad), 1);
        L.setGlobal("load");
        // No finalizers: see `guardedSetmetatable`.
        _ = L.getGlobal("setmetatable");
        L.pushClosure(zlua.wrap(guardedSetmetatable), 1);
        L.setGlobal("setmetatable");
        // An installed script — and only an installed script — may
        // `require` its own files. There is no `package`, so this is
        // the whole module system: a name resolves under the script's
        // own directory or it does not resolve.
        if (self.root != null) {
            L.newTable();
            self.modules = self.ref();
            L.pushFunction(zlua.wrap(requireFn));
            L.setGlobal("require");
        }
        api.install(self);
    }

    /// `require("lib.thing")` → `<root>/lib/thing.lua`, run once and
    /// cached. The name is dots and plain segments only: a `..`, a
    /// separator, a leading `/` or a drive letter is refused, so the
    /// reach never leaves the script's directory. Nothing else is
    /// loadable — there is no `package.path` to widen.
    fn requireFn(L: *State) !i32 {
        const self = of(L);
        const name = L.checkString(1);
        const root = self.root orelse L.raiseErrorStr("require: only an installed script may require its own files", .{});
        if (!validModuleName(name)) {
            const shown: [:0]const u8 = self.app.frame.allocator().dupeSentinel(u8, name, 0) catch "?";
            L.raiseErrorStr("require: `%s` is not a module under this script (letters, digits, `_`, `-`, and `.` between parts)", .{shown.ptr});
        }
        const arena = self.app.frame.allocator();
        const cache = self.modules orelse L.raiseErrorStr("require: no module cache", .{});
        // Already loaded? `cache[name]`.
        self.pushRef(cache);
        L.pushValue(1);
        if (L.getTableRaw(-2) != .nil) {
            L.remove(-2);
            return 1;
        }
        L.pop(1);
        // `lib.thing` → `<root>/lib/thing.lua`, and nowhere else.
        const rel = arena.dupe(u8, name) catch L.raiseErrorStr("require: out of memory", .{});
        for (rel) |*ch| if (ch.* == '.') {
            ch.* = std.fs.path.sep;
        };
        const path = std.fmt.allocPrint(arena, "{s}{c}{s}.lua", .{ root, std.fs.path.sep, rel }) catch L.raiseErrorStr("require: out of memory", .{});
        const src = Io.Dir.cwd().readFileAllocOptions(self.io, path, arena, .limited(max_init_bytes), .of(u8), 0) catch {
            const shown: [:0]const u8 = arena.dupeSentinel(u8, name, 0) catch "?";
            L.raiseErrorStr("require: no `%s` under this script", .{shown.ptr});
        };
        const chunk = std.fmt.allocPrintSentinel(arena, "@{s}", .{path}, 0) catch L.raiseErrorStr("require: out of memory", .{});
        L.loadBuffer(src, chunk, .text) catch {
            const msg: [:0]const u8 = arena.dupeSentinel(u8, L.toStringEx(-1), 0) catch "load error";
            L.raiseErrorStr("require: %s", .{msg.ptr});
        };
        L.protectedCall(.{ .args = 0, .results = 1 }) catch {
            const msg: [:0]const u8 = arena.dupeSentinel(u8, L.toStringEx(-1), 0) catch "run error";
            L.raiseErrorStr("require: %s", .{msg.ptr});
        };
        // A module that returns nothing caches `true`, as Lua's does.
        if (L.isNoneOrNil(-1)) {
            L.pop(1);
            L.pushBoolean(true);
        }
        // cache[name] = value, and leave the value.
        L.pushValue(1);
        L.pushValue(-2);
        L.setTableRaw(-4);
        L.remove(-2);
        return 1;
    }

    /// `lib.thing` — dot-separated plain segments. No `..`, no empty
    /// part, no path separator, nothing absolute.
    pub fn validModuleName(name: []const u8) bool {
        if (name.len == 0 or name.len > 200) return false;
        var it = std.mem.splitScalar(u8, name, '.');
        var parts: usize = 0;
        while (it.next()) |part| {
            parts += 1;
            if (part.len == 0) return false;
            for (part) |c| switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
                else => return false,
            };
        }
        return parts > 0;
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
        for (self.operators.items) |o| self.gpa.free(o.id);
        self.operators.clearRetainingCapacity();
        self.menu_items.clearRetainingCapacity();
        @import("../input/script_ops.zig").clearState(self.gpa, self.id);
        self.modules = null;
        self.tasks.clearRetainingCapacity();
        // A hidden run keeps going; its events find no row and are
        // dropped (`app/script_task.zig`).
        self.hidden_tasks.clearRetainingCapacity();
        self.clearOrigins();
        self.loaded_files = 0;
        self.map_seq = 0;
        self.L.deinit();
    }

    // ── origins (the SCRIPTS section) ──

    fn clearOrigins(self: *Lua) void {
        for (self.origins.items) |o| {
            self.gpa.free(o.name);
            self.gpa.free(o.file);
        }
        self.origins.clearRetainingCapacity();
    }

    /// Record `kind` / `name` as registered by the Lua caller of the
    /// `mnml.*` function running now (stack level 1: the C function is
    /// level 0). A registration under the same kind and name replaces
    /// its row, so the list is what is live, in first-registration order.
    pub fn noteOrigin(self: *Lua, kind: OriginKind, name: []const u8) Allocator.Error!void {
        var file: []const u8 = "";
        var line: u32 = 0;
        if (self.L.getStack(1)) |got| {
            var info = got;
            self.L.getInfo(.{ .S = true, .l = true }, &info);
            if (info.what != .c) {
                const src = info.source;
                file = if (src.len > 0 and src[0] == '@') src[1..] else "";
                line = @intCast(@max(info.current_line orelse 0, 0));
            }
        } else |_| {}
        const owned_file = try self.gpa.dupe(u8, file);
        errdefer self.gpa.free(owned_file);
        for (self.origins.items) |*o| if (o.kind == kind and std.mem.eql(u8, o.name, name)) {
            self.gpa.free(o.file);
            o.file = owned_file;
            o.line = line;
            return;
        };
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        try self.origins.append(self.gpa, .{ .kind = kind, .name = owned_name, .file = owned_file, .line = line });
    }

    pub fn summary(self: *const Lua) Summary {
        var s: Summary = .{};
        for (self.origins.items) |o| switch (o.kind) {
            .command => s.commands += 1,
            .hook => s.hooks += 1,
            .segment => s.segments += 1,
            .source => s.sources += 1,
            .operator => s.operators += 1,
            .list => s.lists += 1,
        };
        return s;
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
        return .{ .state = self.id, .ref = @intCast(r) };
    }

    pub fn unref(self: *Lua, r: LuaRef) void {
        std.debug.assert(r.state == self.id);
        self.L.unref(zlua.registry_index, @intCast(r.ref));
    }

    /// Push the registry value `r`. The ref must be this state's — the
    /// dispatchers route by `r.state` before they get here.
    pub fn pushRef(self: *Lua, r: LuaRef) void {
        std.debug.assert(r.state == self.id);
        _ = self.L.getIndexRaw(zlua.registry_index, @intCast(r.ref));
    }

    // ── budget ──

    const DebugPtr = compat.fnParamTypes(@typeInfo(zlua.CHookFn).pointer.child)[1].?;

    fn countHook(state: ?*zlua.LuaState, _: DebugPtr) callconv(.c) void {
        const L: *State = @ptrCast(state.?);
        const self = of(L);
        if (self.tripped) L.raiseErrorStr(budget_msg, .{});
        if (self.spent()) L.raiseErrorStr(budget_msg, .{});
    }

    fn strBudget(state: ?*zlua.LuaState) callconv(.c) c_int {
        const L: *State = @ptrCast(state.?);
        return @intFromBool(of(L).spent());
    }

    /// Whether the budget of the call running now is gone — and if it
    /// just went, the trip: counted once, and the hook re-armed to fire
    /// on every instruction so the script cannot run another one.
    fn spent(self: *Lua) bool {
        if (self.tripped) return true;
        const deadline = self.deadline_ms orelse return false;
        if (App.nowMs(self.io) < deadline) return false;
        self.tripped = true;
        self.budget_hits += 1;
        self.L.setHook(&countHook, .{ .count = true }, 1);
        return true;
    }

    /// The `pcall` and `xpcall` scripts see: the base library's own
    /// (upvalue 1), called with the same arguments, except that a budget
    /// trip is rethrown rather than returned as `false, msg`. Without
    /// this, `while true do pcall(function() while true do end end) end`
    /// swallowed each raise and ran forever.
    fn guardedPcall(L: *State) i32 {
        const n = L.getTop();
        L.pushValue(State.upvalueIndex(1));
        L.insert(1);
        L.call(.{ .args = n, .results = zlua.mult_return });
        if (of(L).tripped) L.raiseErrorStr(budget_msg, .{});
        return L.getTop();
    }

    /// `xpcall(f, msgh, …)`: `guardedPcall`, with the message handler
    /// wrapped too. A raise from the count hook reaches the handler
    /// while Lua still has hooks switched off (it is running inside the
    /// hook), so a handler that looped there would run with no budget
    /// at all. After a trip the wrapper hands the message on without
    /// calling the script's handler.
    fn guardedXpcall(L: *State) i32 {
        if (L.isFunction(2)) {
            L.pushValue(2);
            L.pushClosure(zlua.wrap(guardedHandler), 1);
            L.replace(2);
        }
        return guardedPcall(L);
    }

    /// `load(chunk, chunkname?, mode?, env?)` with the mode forced to
    /// `"t"`: source text, never a precompiled chunk. Lua 5.4 does not
    /// verify bytecode — a crafted binary chunk is a way out of the VM's
    /// guarantees — so a script may compile text and nothing else. The
    /// arguments are passed on as given otherwise (an absent `env` stays
    /// absent: an explicit nil would be an `_ENV` of nil).
    fn textLoad(L: *State) i32 {
        const n = L.getTop();
        if (n >= 3) {
            _ = L.pushString("t");
            L.replace(3);
        } else {
            while (L.getTop() < 2) L.pushNil();
            _ = L.pushString("t");
        }
        L.pushValue(State.upvalueIndex(1));
        L.insert(1);
        L.call(.{ .args = L.getTop() - 1, .results = zlua.mult_return });
        return L.getTop();
    }

    /// `setmetatable(t, mt)`, refusing a metatable with a `__gc` field.
    /// A finalizer runs when the collector gets to it — on a reload or a
    /// quit (closing the state runs every pending one), or at any
    /// allocation — and Lua switches hooks off while it runs, so the
    /// count hook cannot cut it: `__gc = function() while true do end
    /// end` hung the UI thread on the next `script.reload`. Lua marks an
    /// object for finalization only if its metatable has the field at
    /// the moment it is set (any non-nil value, even one replaced by a
    /// function later), so a raw look at `mt.__gc` here is the whole
    /// gate. There is no `debug.setmetatable` to go around it.
    fn guardedSetmetatable(L: *State) i32 {
        if (L.typeOf(2) == .table) {
            _ = L.pushString("__gc");
            const has_gc = L.getTableRaw(2) != .nil;
            L.pop(1);
            if (has_gc) L.raiseErrorStr("setmetatable: `__gc` is not available to scripts — a finalizer runs where the script budget cannot reach it (a reload, a quit, any collection)", .{});
        }
        L.pushValue(State.upvalueIndex(1));
        L.insert(1);
        L.call(.{ .args = L.getTop() - 1, .results = 1 });
        return 1;
    }

    fn guardedHandler(L: *State) i32 {
        if (of(L).tripped) return 1;
        L.pushValue(State.upvalueIndex(1));
        L.insert(1);
        L.call(.{ .args = L.getTop() - 1, .results = 1 });
        return 1;
    }

    /// UI-thread assertion plus the budget for the outermost call. Pair
    /// with `leave`.
    fn enter(self: *Lua) void {
        std.debug.assert(std.Thread.getCurrentId() == self.ui_thread);
        if (self.depth == 0) {
            self.deadline_ms = App.nowMs(self.io) + budget_ms;
            self.tripped = false;
            self.L.setHook(&countHook, .{ .count = true }, hook_count);
        }
        self.depth += 1;
    }

    fn leave(self: *Lua) void {
        self.depth -= 1;
        if (self.depth == 0) {
            self.L.setHook(&countHook, .{}, 0);
            self.deadline_ms = null;
            self.tripped = false;
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
        // Read before `leave` clears it: a trip is reported as a trip
        // whatever the script's handlers made of the message on the way.
        const tripped = self.tripped;
        self.leave();
        L.remove(base);
        result catch {
            // `toStringEx` pushes the string form; pop it and the error object.
            const msg = L.toStringEx(-1);
            const arena = self.app.frame.allocator();
            self.last_error = if (tripped and std.mem.indexOf(u8, msg, budget_msg) == null)
                std.fmt.allocPrint(arena, "{s}\n{s}", .{ budget_msg, msg }) catch budget_msg
            else
                arena.dupe(u8, msg) catch "script error";
            L.pop(2);
            return error.Failed;
        };
    }

    /// `pcall`, and then read what the function returned INSIDE the same
    /// protected call and the same budget.
    ///
    /// Reading a returned value is not passive: `lua_getfield` honours
    /// `__index`, `luaL_tolstring` honours `__tostring`, and either runs
    /// the script's own code. Run after `pcall` returned, that code is
    /// outside every boundary — an `error()` in it has no `pcall` to land
    /// in, and an unprotected Lua error aborts the process. So the call
    /// and the decode are one protected call: a trampoline closure calls
    /// the function, then hands its results to `ctx.decode(lua)` with the
    /// results as the whole of its stack (index 1 up to the top).
    ///
    /// The decode can be cut short by a Lua error at any read. Whatever
    /// it builds must therefore be owned by `ctx` (the caller frees it on
    /// either outcome), never by a local an `errdefer` would free — a Lua
    /// error unwinds by longjmp and runs no Zig `defer`.
    pub fn pcallThen(self: *Lua, nargs: i32, comptime nresults: i32, ctx: anytype) error{Failed}!void {
        const Ctx = @TypeOf(ctx.*);
        const T = struct {
            fn run(L: *State) i32 {
                const c = L.toUserdata(Ctx, State.upvalueIndex(1)) catch unreachable;
                L.call(.{ .args = L.getTop() - 1, .results = nresults });
                c.decode(of(L));
                return 0;
            }
        };
        const L = self.L;
        L.pushLightUserdata(ctx);
        L.pushClosure(zlua.wrap(T.run), 1);
        L.insert(-(nargs + 2));
        return self.pcall(nargs + 1, 0);
    }

    /// The error `pcall` (or the loader) just caught: a diagnostic on
    /// the `init.lua` it names, when it names one, and its toast —
    /// persistent and clickable then, plain otherwise (`diag.zig`).
    fn toastError(self: *Lua, comptime what: []const u8) void {
        const msg = self.last_error orelse "script error";
        const landed = diag.report(self, msg) catch false;
        diag.toast(self, what, msg, landed);
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
                self.last_error = self.app.frame.allocator().dupe(u8, msg) catch "syntax error";
                self.L.pop(2);
                self.toastError("init.lua");
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
        var ok = true;
        if (app.data_root.len != 0) {
            const path = try std.fs.path.join(arena, &.{ app.data_root, init_file });
            _ = self.loadInit(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => ok = false,
            };
        }
        if (app.workspace_trusted) {
            const path = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", init_file });
            _ = self.loadInit(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => ok = false,
            };
        }
        self.last_load_ok = ok;
        // Every file ran clean: whatever error was standing is fixed.
        if (ok) try diag.clear(self);
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

    /// Run `src` (a selection, the cursor line) as a chunk named
    /// `=selection`, an expression first (`return <src>`) so `1 + 1`
    /// answers `2`, a statement chunk when that does not parse. The
    /// values it returns, `tostring`ed and tab-joined, on the frame
    /// arena; null when it returned nothing. An error is `error.Failed`
    /// with the message in `last_error` — the caller reports it (there
    /// is no line of a file to land on).
    pub fn eval(self: *Lua, src: []const u8) error{ Failed, OutOfMemory }!?[]const u8 {
        const L = self.L;
        const arena = self.app.frame.allocator();
        const as_expr = try std.fmt.allocPrint(arena, "return {s}", .{src});
        L.loadBuffer(as_expr, "=selection", .text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LuaSyntax => {
                L.pop(1);
                L.loadBuffer(src, "=selection", .text) catch |err2| switch (err2) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LuaSyntax => {
                        const msg = L.toStringEx(-1);
                        self.last_error = arena.dupe(u8, msg) catch "syntax error";
                        L.pop(2);
                        return error.Failed;
                    },
                };
            },
        };
        // The values' string forms are taken inside the protected call —
        // a returned table's `__tostring` is the script's code.
        const Ctx = struct {
            arena: Allocator,
            out: ?[]const u8 = null,
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                c.out = joinResults(lua.L, c.arena) catch |e| {
                    c.err = e;
                    return;
                };
            }
        };
        var ctx: Ctx = .{ .arena = arena };
        try self.pcallThen(0, zlua.mult_return, &ctx);
        if (ctx.err) |e| return e;
        return ctx.out;
    }

    /// Every value on the stack, `tostring`ed and tab-joined; null when
    /// there are none.
    fn joinResults(L: *State, arena: Allocator) Allocator.Error!?[]const u8 {
        const n = L.getTop();
        if (n == 0) return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: i32 = 1;
        while (i <= n) : (i += 1) {
            if (i > 1) try out.append(arena, '\t');
            try out.appendSlice(arena, L.toStringEx(i));
            L.pop(1);
        }
        return out.items;
    }

    // ── the seams ──

    /// A `DynRunner.lua` command. The reason lands in `app.diag`, so
    /// `command.run` toasts it once.
    pub fn callCommand(self: *Lua, r: LuaRef) command.CommandError!void {
        self.pushRef(r);
        self.pcall(0, 0) catch {
            const msg = self.last_error orelse "script error";
            _ = diag.report(self, msg) catch {};
            return self.app.diag.fail(self.app.frame.allocator(), "{s}", .{msg});
        };
    }

    /// A `Subscriber.lua` hook: the payload table (its fields per
    /// `HookArgs`, plus `hook = "<name>"`) is the one argument.
    pub fn callHook(self: *Lua, r: LuaRef, args: hooks.HookArgs) void {
        const L = self.L;
        // The two HTTP hooks carry a header table and a rewrite: hand-marshalled.
        switch (args) {
            .http_request, .http_response => return api.callHttpHook(self, r, args),
            else => {},
        }
        self.pushRef(r);
        switch (args) {
            .http_request, .http_response => unreachable,
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
    /// frame. The rows are decoded inside the protected call
    /// (`pcallThen`): a row's `__index` is the script's code too.
    pub fn callRender(self: *Lua, r: LuaRef, w: u16, h: u16) Allocator.Error![]const []const Segment {
        const arena = self.app.frame.allocator();
        const L = self.L;
        const Ctx = struct {
            arena: Allocator,
            rows: []const []const Segment = &.{},
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                c.rows = lua.decodeRows(c.arena, -1) catch |e| {
                    c.err = e;
                    return;
                };
            }
        };
        var ctx: Ctx = .{ .arena = arena };
        self.pushRef(r);
        L.pushInteger(w);
        L.pushInteger(h);
        self.pcallThen(2, 1, &ctx) catch {
            _ = diag.report(self, self.last_error orelse "") catch {};
            const row = try arena.alloc(Segment, 1);
            row[0] = .{ .text = self.last_error orelse "script error", .style = self.app.theme.error_fg };
            const rows = try arena.alloc([]const Segment, 1);
            rows[0] = row;
            return rows;
        };
        if (ctx.err) |e| return e;
        return ctx.rows;
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

    /// `t[name]` when it is a string, copied onto the frame arena. The
    /// read may run an `__index` (the callers are all inside a protected
    /// call), and a string that metamethod made is anchored by nothing
    /// once it is popped — so the slice handed back is never Lua's.
    fn stringField(L: *State, t: i32, name: [:0]const u8) ?[]const u8 {
        _ = L.getField(t, name);
        defer L.pop(1);
        if (L.typeOf(-1) != .string) return null;
        const s = L.toString(-1) catch return null;
        return of(L).app.frame.allocator().dupe(u8, s) catch L.raiseErrorStr("out of memory", .{});
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
    /// null to hide it; `error.Failed` (toasted) when it errored. The
    /// value's string form is taken inside the protected call: a
    /// returned table's `__tostring` is script code.
    fn callSegment(self: *Lua, r: LuaRef) error{Failed}!?[]const u8 {
        const Ctx = struct {
            text: ?[]const u8 = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                const L = lua.L;
                if (L.isNoneOrNil(-1)) return;
                const s = L.toStringEx(-1);
                c.text = lua.app.frame.allocator().dupe(u8, s) catch null;
                L.pop(1);
            }
        };
        var ctx: Ctx = .{};
        self.pushRef(r);
        self.pcallThen(0, 1, &ctx) catch {
            self.toastError("statusline segment");
            return error.Failed;
        };
        return ctx.text;
    }

    /// A picker source's `items(query)` → labels and details (gpa, the
    /// picker takes them) with the `on_accept` refs kept in
    /// `picker_items`. Each item is a string or `{ label, detail?,
    /// on_accept? }`.
    pub fn callItems(self: *Lua, r: LuaRef, query: []const u8, labels: *std.ArrayList([]u8), details: *std.ArrayList([]u8), icons: *std.ArrayList([]u8)) Allocator.Error!void {
        const L = self.L;
        const Ctx = struct {
            labels: *std.ArrayList([]u8),
            details: *std.ArrayList([]u8),
            icons: *std.ArrayList([]u8),
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                lua.decodeItems(c.labels, c.details, c.icons) catch |e| {
                    c.err = e;
                };
            }
        };
        var ctx: Ctx = .{ .labels = labels, .details = details, .icons = icons };
        self.pushRef(r);
        _ = L.pushString(query);
        self.pcallThen(1, 1, &ctx) catch {
            self.toastError("picker items");
            return;
        };
        if (ctx.err) |e| return e;
    }

    /// The items table at the top of the stack → the three lists and
    /// `picker_items`. Runs inside `callItems`' protected call: every
    /// read that can reach a metamethod happens before the row's strings
    /// are duplicated, and each duplicate is owned by its list the moment
    /// it exists, so an error mid-row leaks nothing.
    fn decodeItems(self: *Lua, labels: *std.ArrayList([]u8), details: *std.ArrayList([]u8), icons: *std.ArrayList([]u8)) Allocator.Error!void {
        const L = self.L;
        const gpa = self.gpa;
        self.pickerClosed();
        if (!L.isTable(-1)) return;
        const n = L.lenRaw(-1);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i));
            defer L.pop(1);
            var on_accept: ?LuaRef = null;
            var row_ref: ?LuaRef = null;
            var label: []const u8 = "";
            var detail: []const u8 = "";
            var icon: []const u8 = "";
            if (L.isTable(-1)) {
                label = stringField(L, -1, "label") orelse "";
                detail = stringField(L, -1, "detail") orelse "";
                icon = stringField(L, -1, "icon") orelse "";
                _ = L.getField(-1, "on_accept");
                if (L.isFunction(-1)) {
                    on_accept = self.ref();
                } else L.pop(1);
            } else {
                label = L.toString(-1) catch "";
            }
            // The row table itself is kept, so `data` reaches `on_accept`
            // and `preview` exactly as the script wrote it.
            if (L.isTable(-1)) {
                L.pushValue(-1);
                row_ref = self.ref();
            }
            try self.picker_items.ensureUnusedCapacity(gpa, 1);
            try labels.ensureUnusedCapacity(gpa, 1);
            try details.ensureUnusedCapacity(gpa, 1);
            try icons.ensureUnusedCapacity(gpa, 1);
            const l = try gpa.dupe(u8, label);
            errdefer gpa.free(l);
            const d = try gpa.dupe(u8, detail);
            errdefer gpa.free(d);
            const g = try gpa.dupe(u8, icon);
            labels.appendAssumeCapacity(l);
            details.appendAssumeCapacity(d);
            icons.appendAssumeCapacity(g);
            self.picker_items.appendAssumeCapacity(.{ .on_accept = on_accept, .row = row_ref });
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

    /// A script operator's `run(range)`: the range table is its one
    /// argument, in the shape `mnml.buf.selection()` answers.
    pub fn callOperator(self: *Lua, index: u32, start: usize, end: usize, mode: []const u8) void {
        if (index >= self.operators.items.len) return;
        const L = self.L;
        self.pushRef(self.operators.items[index].run);
        L.createTable(0, 3);
        L.pushInteger(@intCast(start));
        L.setField(-2, "start");
        L.pushInteger(@intCast(end));
        L.setField(-2, "end");
        _ = L.pushString(mode);
        L.setField(-2, "mode");
        self.pcall(1, 0) catch self.toastError("operator");
    }

    // ── mnml.list ──

    /// A list's `rows(sort)` → the decoded rows on the gpa (the app
    /// caches them across frames), or null when the call failed — the
    /// panel then keeps the rows it had rather than blanking.
    pub fn callListRows(self: *Lua, r: LuaRef, sort: ?[]const u8) Allocator.Error!?[]script_list.Row {
        const L = self.L;
        const gpa = self.gpa;
        // The rows are built inside the protected call and owned by the
        // context, so a row whose read errors part-way leaves nothing
        // behind: whatever was built is freed unless it is handed out.
        const Ctx = struct {
            gpa: Allocator,
            out: std.ArrayListUnmanaged(script_list.Row) = .empty,
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                lua.decodeListRows(c.gpa, &c.out) catch |e| {
                    c.err = e;
                };
            }
        };
        var ctx: Ctx = .{ .gpa = gpa };
        defer {
            for (ctx.out.items) |row| freeListRow(gpa, row);
            ctx.out.deinit(gpa);
        }
        self.pushRef(r);
        if (sort) |s| _ = L.pushString(s) else L.pushNil();
        self.pcallThen(1, 1, &ctx) catch {
            self.toastError("list rows");
            return null;
        };
        if (ctx.err) |e| return e;
        return try ctx.out.toOwnedSlice(gpa);
    }

    fn freeListRow(gpa: Allocator, row: script_list.Row) void {
        gpa.free(row.label);
        gpa.free(row.detail);
        gpa.free(row.icon);
        gpa.free(row.state);
    }

    /// The rows table at the top of the stack → `out`. Every read that
    /// can reach a metamethod is done (onto the frame arena) before the
    /// row's strings are duplicated onto the gpa and appended.
    fn decodeListRows(self: *Lua, gpa: Allocator, out: *std.ArrayListUnmanaged(script_list.Row)) Allocator.Error!void {
        const L = self.L;
        if (!L.isTable(-1)) return;
        const n = L.lenRaw(-1);
        try out.ensureTotalCapacity(gpa, n);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i));
            defer L.pop(1);
            var header = false;
            var label: []const u8 = "";
            var detail: []const u8 = "";
            var icon: []const u8 = "";
            var state: []const u8 = "";
            var count: u32 = 0;
            if (L.isTable(-1)) {
                if (stringField(L, -1, "header")) |h| {
                    header = true;
                    label = h;
                } else label = stringField(L, -1, "label") orelse "";
                detail = stringField(L, -1, "detail") orelse "";
                icon = stringField(L, -1, "icon") orelse "";
                state = stringField(L, -1, "state") orelse "";
                _ = L.getField(-1, "count");
                count = if (L.toInteger(-1)) |c| @intCast(std.math.clamp(c, 0, std.math.maxInt(u32))) else |_| 0;
                L.pop(1);
            } else {
                label = L.toString(-1) catch "";
            }
            var row: script_list.Row = .{ .index = @intCast(i - 1), .header = header, .count = count };
            row.label = try gpa.dupe(u8, label);
            errdefer gpa.free(row.label);
            row.detail = try gpa.dupe(u8, detail);
            errdefer gpa.free(row.detail);
            row.icon = try gpa.dupe(u8, icon);
            errdefer gpa.free(row.icon);
            row.state = try gpa.dupe(u8, state);
            out.appendAssumeCapacity(row);
        }
    }

    /// Push row `index` of `l`'s last `rows()` answer as a table — what
    /// `on_enter` and `on_menu` are handed.
    fn pushListRow(self: *Lua, l: *const script_list.List, index: u32) void {
        const L = self.L;
        const row: ?script_list.Row = for (l.cache) |r| {
            if (r.index == index) break r;
        } else null;
        L.createTable(0, 6);
        if (row) |rr| {
            _ = L.pushString(rr.label);
            L.setField(-2, if (rr.header) "header" else "label");
            _ = L.pushString(rr.detail);
            L.setField(-2, "detail");
            _ = L.pushString(rr.icon);
            L.setField(-2, "icon");
            _ = L.pushString(rr.state);
            L.setField(-2, "state");
            L.pushInteger(@intCast(rr.count));
            L.setField(-2, "count");
        }
        L.pushInteger(@as(i64, index) + 1);
        L.setField(-2, "index");
    }

    /// `on_enter(row)`.
    pub fn callRow(self: *Lua, r: LuaRef, l: *const script_list.List, index: u32) void {
        self.pushRef(r);
        self.pushListRow(l, index);
        self.pcall(1, 0) catch self.toastError("list on_enter");
    }

    /// `on_menu(row)` → `{ { label, run }, … }`. The labels come back on
    /// `arena` (the menu's own); the `run` refs are kept until the next
    /// menu opens, so a click can reach them.
    pub fn callMenu(self: *Lua, r: LuaRef, l: *const script_list.List, index: u32, arena: Allocator) Allocator.Error![]const []const u8 {
        const Ctx = struct {
            arena: Allocator,
            labels: std.ArrayListUnmanaged([]const u8) = .empty,
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                lua.decodeMenu(c.arena, &c.labels) catch |e| {
                    c.err = e;
                };
            }
        };
        var ctx: Ctx = .{ .arena = arena };
        self.dropMenuItems();
        self.pushRef(r);
        self.pushListRow(l, index);
        self.pcallThen(1, 1, &ctx) catch {
            self.toastError("list on_menu");
            return &.{};
        };
        if (ctx.err) |e| return e;
        return ctx.labels.items;
    }

    /// `{ { label, run }, … }` at the top of the stack → labels on
    /// `arena`, the `run` refs into `menu_items` (one per label, in step).
    fn decodeMenu(self: *Lua, arena: Allocator, labels: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
        const L = self.L;
        if (!L.isTable(-1)) return;
        const n = L.lenRaw(-1);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            _ = L.getIndex(-1, @intCast(i));
            defer L.pop(1);
            if (!L.isTable(-1)) continue;
            const label = stringField(L, -1, "label") orelse continue;
            _ = L.getField(-1, "run");
            if (!L.isFunction(-1)) {
                L.pop(1);
                continue;
            }
            try self.menu_items.ensureUnusedCapacity(self.gpa, 1);
            try labels.append(arena, label);
            self.menu_items.appendAssumeCapacity(self.ref());
        }
    }

    /// A row menu's entry was clicked: its `run()`.
    pub fn runMenuItem(self: *Lua, item: u32) void {
        if (item >= self.menu_items.items.len) return;
        self.pushRef(self.menu_items.items[item]);
        self.pcall(0, 0) catch self.toastError("list menu");
    }

    pub fn dropMenuItems(self: *Lua) void {
        for (self.menu_items.items) |r| self.unref(r);
        self.menu_items.clearRetainingCapacity();
    }

    /// The picker closed (or a new item list replaces the old): drop the
    /// item refs.
    pub fn pickerClosed(self: *Lua) void {
        for (self.picker_items.items) |it| {
            if (it.on_accept) |a| self.unref(a);
            if (it.row) |rr| self.unref(rr);
        }
        self.picker_items.clearRetainingCapacity();
    }

    /// Push row `i` of the open picker, or its label when the row was a
    /// plain string. Leaves exactly one value on the stack.
    fn pushRow(self: *Lua, i: usize, label: []const u8) void {
        if (i < self.picker_items.items.len) if (self.picker_items.items[i].row) |r| return self.pushRef(r);
        _ = self.L.pushString(label);
    }

    /// The source's `on_accept(row)` — or `on_accept({ row, … })` when
    /// the picker is multi-select and rows are marked.
    pub fn acceptSource(self: *Lua, r: LuaRef, rows: []const usize, labels: []const []const u8, multi: bool) void {
        const L = self.L;
        self.pushRef(r);
        if (multi) {
            L.createTable(@intCast(rows.len), 0);
            for (rows, 0..) |row, n| {
                self.pushRow(row, if (n < labels.len) labels[n] else "");
                L.setIndex(-2, @intCast(n + 1));
            }
        } else {
            self.pushRow(if (rows.len > 0) rows[0] else 0, if (labels.len > 0) labels[0] else "");
        }
        self.pcall(1, 0) catch self.toastError("on_accept");
    }

    /// A source's `preview(row)` → rows of segments for the picker's
    /// preview column, gpa-owned (the overlay holds them across frames,
    /// and the frame arena does not survive one).
    pub fn callPreview(self: *Lua, r: LuaRef, i: usize, label: []const u8) Allocator.Error![][]Segment {
        // The decode's scratch arena is the context's, so it is released
        // whether the decode finished or a read inside it errored.
        const Ctx = struct {
            arena_state: std.heap.ArenaAllocator,
            rows: []const []const Segment = &.{},
            err: ?Allocator.Error = null,
            pub fn decode(c: *@This(), lua: *Lua) void {
                c.rows = lua.decodeRows(c.arena_state.allocator(), -1) catch |e| {
                    c.err = e;
                    return;
                };
            }
        };
        var ctx: Ctx = .{ .arena_state = std.heap.ArenaAllocator.init(self.gpa) };
        defer ctx.arena_state.deinit();
        self.pushRef(r);
        self.pushRow(i, label);
        self.pcallThen(1, 1, &ctx) catch {
            self.toastError("picker preview");
            return &.{};
        };
        if (ctx.err) |e| return e;
        const rows = ctx.rows;
        // Onto the gpa: the preview outlives this frame.
        const out = try self.gpa.alloc([]Segment, rows.len);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |row| {
                for (row) |seg| self.gpa.free(seg.text);
                self.gpa.free(row);
            }
            self.gpa.free(out);
        }
        for (rows, 0..) |row, n| {
            const copy = try self.gpa.alloc(Segment, row.len);
            var texts: usize = 0;
            errdefer {
                for (copy[0..texts]) |seg| self.gpa.free(seg.text);
                self.gpa.free(copy);
            }
            for (row, 0..) |seg, k| {
                copy[k] = .{ .text = try self.gpa.dupe(u8, seg.text), .style = seg.style, .hit = null };
                texts = k + 1;
            }
            out[n] = copy;
            made = n + 1;
        }
        return out;
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
            if (s.failed or now < s.next_poll_ms) continue;
            s.next_poll_ms = now + segment_poll_ms;
            // An error is one toast, not one every 250 ms for the rest of
            // the session: the segment latches off until a reload.
            const fresh = self.callSegment(s.func) catch blk: {
                s.failed = true;
                break :blk null;
            };
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

    fn hiddenTask(self: *Lua, id: u32) ?*HiddenTask {
        for (self.hidden_tasks.items) |*t| if (t.id == id) return t;
        return null;
    }

    /// One line of a hidden task's output → `on_line(text)`.
    pub fn hiddenTaskLine(self: *Lua, id: u32, text: []const u8) void {
        const t = self.hiddenTask(id) orelse return;
        const r = t.on_line orelse return;
        self.pushRef(r);
        _ = self.L.pushString(text);
        self.pcall(1, 0) catch self.toastError("on_line");
    }

    /// A hidden task exited → `on_done{ ok, code | signal }`, and the
    /// row goes.
    pub fn hiddenTaskDone(self: *Lua, id: u32, ok: bool, code: i32, signal: u8) void {
        var idx: usize = 0;
        const t = while (idx < self.hidden_tasks.items.len) : (idx += 1) {
            if (self.hidden_tasks.items[idx].id == id) break self.hidden_tasks.items[idx];
        } else return;
        _ = self.hidden_tasks.orderedRemove(idx);
        if (t.on_line) |r| self.unref(r);
        const done = t.on_done orelse return;
        defer self.unref(done);
        const L = self.L;
        self.pushRef(done);
        L.createTable(0, 2);
        L.pushBoolean(ok);
        L.setField(-2, "ok");
        if (signal != 0) {
            L.pushInteger(signal);
            L.setField(-2, "signal");
        } else {
            L.pushInteger(code);
            L.setField(-2, "code");
        }
        self.pcall(1, 0) catch self.toastError("on_done");
    }

    pub fn nextDeadlineMs(self: *const Lua) ?i64 {
        var next: ?i64 = null;
        for (self.segments.items) |s| if (!s.failed) {
            next = @min(next orelse std.math.maxInt(i64), s.next_poll_ms);
        };
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
            if (slot == .script and slot.script.lua == self) try app.forceClosePane(@intCast(i));
        }
        for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
            if (!alive or c.owner != .script or c.owner.script != self.id) continue;
            for (c.keys) |k| app.keymap.unbind(k);
        }
        _ = app.dyn_commands.unregisterScript(self.id);
        _ = app.hooks.unsubscribeState(self.id);
        // Every namespace goes with the state: the decorations it holds
        // and the diagnostics it published (`app/script_decor.zig`).
        try @import("../app/script_decor.zig").resetState(app, self.id);
        // The lists and the rail sections they fed go with it too.
        try @import("../app/script_section.zig").resetState(app, self.id);
        app.script_lists.clearState(app.gpa, self.id);
        if (app.overlay == .picker and app.overlay.picker.kind == .lua and app.overlay.picker.lua_state == self.id) {
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

test "budget: a trip cannot be caught — pcall and xpcall rethrow it, loops around them end" {
    // The trip used to be a plain `error()`. A script's own `pcall`
    // caught it, the deadline stayed past, the hook raised again a
    // hundred thousand instructions later, the `pcall` caught that too —
    // forever, at 100% CPU, with the UI thread never coming back.
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    const top = lua.L.getTop();
    const cases = [_][]const u8{
        "while true do pcall(function() while true do end end) end",
        "while true do xpcall(function() while true do end end, function(m) return m end) end",
        // A handler that itself loops, and one that rewrites the message.
        "xpcall(function() while true do end end, function() while true do end end)",
        "while true do xpcall(function() while true do end end, function() return 'swallowed' end) end",
        // Protected calls stacked deep, each one retrying.
        "local function f(n) if n == 0 then while true do end end; while true do pcall(f, n - 1) end end; f(5)",
    };
    for (cases, 1..) |src, n| {
        try testing.expectError(error.Failed, lua.runString(src));
        try testing.expect(std.mem.indexOf(u8, lua.last_error.?, budget_msg) != null);
        try testing.expectEqual(@as(u32, @intCast(n)), lua.budget_hits);
        try testing.expect(!lua.tripped);
        try testing.expectEqual(@as(u32, 0), lua.depth);
    }
    // An ordinary error is still an ordinary error to `pcall`, and the
    // state works afterwards.
    try lua.runString("local ok, err = pcall(error, 'plain'); assert(not ok and err == 'plain')");
    try lua.runString("local ok = xpcall(function() return 1 end, print); assert(ok)");
    try testing.expectEqual(top, lua.L.getTop());
}

test "budget: a long pattern match is cut inside the C call, not after it" {
    // The budget is a count hook, and a hook runs between VM
    // instructions — one `string.find` is one instruction. A quadratic
    // pattern over a long subject held the UI thread for seconds with
    // the deadline long past and nothing looking at it.
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    const cases = [_][]const u8{
        "local s = string.rep('a', 100000); return s:find('.-b')",
        "local s = string.rep('a', 100000); return (s:gsub('a-b', ''))",
        "local s = string.rep('a', 100000); for _ in s:gmatch('a*b') do end",
        "local s = string.rep('(', 100000); return s:find('%b()')",
    };
    for (cases, 1..) |src, n| {
        try testing.expectError(error.Failed, lua.runString(src));
        try testing.expect(std.mem.indexOf(u8, lua.last_error.?, budget_msg) != null);
        try testing.expectEqual(@as(u32, @intCast(n)), lua.budget_hits);
    }
    // An honest match is untouched, and a match is not the budget's
    // outside a budgeted call.
    try lua.runString("assert(('hello world'):find('o w') == 5 and ('a,b'):gsub(',', ';') == 'a;b')");
}

test "a statusline segment that errors toasts once and is not polled again until a reload" {
    // A segment was polled every 250 ms forever and each error was a
    // fresh toast: 118 in the message log after half a minute.
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    try lua.runString("N = 0; mnml.statusline.segment{ id = 'bad', fn = function() N = N + 1; error('SEGBOOM') end }");
    const toasts_before = app.toasts.items.len;
    var now: i64 = 1_000;
    for (0..8) |_| {
        try lua.tick(now);
        now += segment_poll_ms;
    }
    try lua.runString("assert(N == 1, 'polled ' .. N .. ' times')");
    try testing.expectEqual(toasts_before + 1, app.toasts.items.len);
    try testing.expect(lua.nextDeadlineMs() == null);
    // A reload is a fresh start: the new segment is asked again.
    try lua.reset();
    try lua.runString("N = 0; mnml.statusline.segment{ id = 'bad', fn = function() N = N + 1; return 'ok' end }");
    try lua.tick(now);
    try lua.tick(now + segment_poll_ms);
    try lua.runString("assert(N == 2, 'polled ' .. N .. ' times')");
}

test "load compiles source text only: a precompiled chunk is refused, text and env work as before" {
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\local f, err = load(string.dump(function() return 42 end))
        \\assert(f == nil and err:find('binary'), tostring(err))
        \\f, err = load(string.dump(function() return 42 end), 'x', 'b')
        \\assert(f == nil and err:find('binary'), tostring(err))
        \\assert(load('return 1 + 1')() == 2)
        \\assert(load('return x', 'chunk', 'bt', { x = 7 })() == 7)
        \\assert(load('return y', 'chunk')() == nil)
    );
}

test "a metatable with __gc is refused, so no finalizer ever runs unbudgeted" {
    // A finalizer runs with Lua's hooks switched off — on the state's
    // close at a reload or a quit, or mid-collection — so the budget
    // could never cut one that loops; `script.reload` hung for good.
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    try testing.expectError(error.Failed, lua.runString("KEEP = setmetatable({}, { __gc = function() while true do end end })"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "__gc") != null);
    // Any value marks the object, a later function would then run: refused too.
    try testing.expectError(error.Failed, lua.runString("local mt = { __gc = false }; KEEP = setmetatable({}, mt); mt.__gc = function() while true do end end"));
    // Every other metatable is untouched.
    try lua.runString(
        \\local t = setmetatable({}, { __index = function() return 7 end })
        \\assert(t.x == 7 and getmetatable(t) ~= nil)
        \\local mt = {}; local u = setmetatable({}, mt); mt.__gc = function() while true do end end
        \\assert(getmetatable(setmetatable(u, nil)) == nil)
    );
    // The close a reload does runs no finalizer that could hang it.
    try lua.reset();
    try lua.runString("collectgarbage('collect')");
}

test "the frame budget is a shipped-build promise; Debug gets a runaway budget derived from the same slowdown" {
    // The regression this pins. `budget_ms` was a flat 20 ms of wall
    // clock, but most of what it bounds is HOST code — `mnml.commands()`
    // walks eleven hundred specs and builds a table per row, `callItems`
    // copies every row back out — and host code is far slower
    // unoptimized. So the repo's own example sat inside the budget in a
    // shipped build and blew it in a Debug one: `items` raised `mnml:
    // script budget exceeded`, `callItems` turned that into an empty
    // list, and the picker painted `(no matches)`. That is what
    // `lua_example_recent_commands.test` failed on, only ever under
    // `zig build e2e` (Debug by default) — which read as "fails in a
    // worktree" three times over.
    //
    // Asserted as the RULE, not as a clock: a wall-clock assertion here
    // would run on `std.testing.allocator`, which tracks every
    // allocation and is not the allocator the frame budget is measured
    // against — the example needs ~600 ms under it even in ReleaseSafe.
    // The shipped build's headroom is pinned where it is real, by
    // `lua_example_recent_commands.test` against the built binary, and
    // the failure mode by the picker test in `api.zig`.
    try testing.expectEqual(@as(i64, 20), frame_budget_ms);
    if (compat.is_debug) {
        // At least the slowdown the `.test` runner measured, or the
        // budget is again a figure that fits whichever script was
        // measured last.
        try testing.expect(budget_ms >= frame_budget_ms * build_options.debug_slowdown);
        try testing.expectEqual(runaway_budget_ms, budget_ms);
    } else {
        // The shipped build owes a frame, and only a frame.
        try testing.expectEqual(frame_budget_ms, budget_ms);
    }
    // Runaway, not unbounded: `while true do end` still costs one toast
    // rather than the editor, so the figure stays inside a few seconds.
    try testing.expect(budget_ms > 0 and budget_ms <= 10_000);
}

fn globalRef(lua: *Lua, name: [:0]const u8) LuaRef {
    _ = lua.L.getGlobal(name);
    return lua.ref();
}

test "a returned value's metamethods run inside the protected call: an error there is a message, not an abort" {
    // Reading what a script returned runs the script's code when the
    // value has a metatable — `__index` on a row's field, `__tostring`
    // on a segment's text. Those reads used to happen after `pcall` had
    // returned, where a Lua error has nowhere to land and the process
    // aborts; each call below would take the test runner down with it.
    var app = try App.init(testing.allocator, testing.io);
    defer app.deinit();
    const lua = app.script();
    const top = lua.L.getTop();
    try lua.runString(
        \\local boom = function(what) return setmetatable({}, { __index = function() error(what) end, __tostring = function() error(what) end }) end
        \\function render() return { boom('ROW-BOOM') } end
        \\function segment() return boom('SEG-BOOM') end
        \\function rows() return { boom('LIST-BOOM') } end
        \\function items() return { boom('ITEM-BOOM') } end
        \\function preview() return { boom('PREVIEW-BOOM') } end
    );
    const rows = try lua.callRender(globalRef(lua, "render"), 20, 4);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(std.mem.indexOf(u8, rows[0][0].text, "ROW-BOOM") != null);
    try testing.expectError(error.Failed, lua.callSegment(globalRef(lua, "segment")));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "SEG-BOOM") != null);
    try testing.expect((try lua.callListRows(globalRef(lua, "rows"), null)) == null);
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "LIST-BOOM") != null);
    var labels: std.ArrayList([]u8) = .empty;
    var details: std.ArrayList([]u8) = .empty;
    var icons: std.ArrayList([]u8) = .empty;
    defer {
        for (labels.items) |x| testing.allocator.free(x);
        for (details.items) |x| testing.allocator.free(x);
        for (icons.items) |x| testing.allocator.free(x);
        labels.deinit(testing.allocator);
        details.deinit(testing.allocator);
        icons.deinit(testing.allocator);
    }
    try lua.callItems(globalRef(lua, "items"), "", &labels, &details, &icons);
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "ITEM-BOOM") != null);
    try testing.expectEqual(@as(usize, 0), (try lua.callPreview(globalRef(lua, "preview"), 0, "x")).len);
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "PREVIEW-BOOM") != null);
    try testing.expectError(error.Failed, lua.eval("setmetatable({}, { __tostring = function() error('EVAL-BOOM') end })"));
    try testing.expect(std.mem.indexOf(u8, lua.last_error.?, "EVAL-BOOM") != null);
    // A well-behaved metatable still reads: the decode is protected, not raw.
    try lua.runString("function proxy() return { setmetatable({}, { __index = function(_, k) if k == 'text' then return 'VIA-INDEX' end end }) } end");
    const via = try lua.callRender(globalRef(lua, "proxy"), 20, 4);
    try testing.expectEqualStrings("VIA-INDEX", via[0][0].text);
    try testing.expectEqual(top, lua.L.getTop());
    try lua.runString("assert(1 + 1 == 2)");
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
