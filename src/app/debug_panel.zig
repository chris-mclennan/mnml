//! DEBUG — the sidebar section (`PanelId.debug`, `Section.debug`): a
//! status row, then VARIABLES / WATCH / CALL STACK / BREAKPOINTS as
//! collapsible sections in one `ListPanel(Row)` list. The data is the
//! session's (`app/dap.zig`); this module owns only the cursor, the
//! filter, which sections are folded, and the values of the last stop
//! (so a variable whose value changed paints in the warning colour
//! until the next resume).
//!
//! Every row is a hit (`.row{ .debug, idx }`), every row has a
//! right-click menu of real command ids, and every key the section
//! takes is also a command — the `dap.*_selected` family acts on the
//! row under the cursor so the menu, the key and the palette cannot
//! drift apart.
//!
//! The section renders into whichever column its side says
//! (`app/side.zig`); nothing here knows left from right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const fuzzy = @import("../ui/fuzzy.zig");
const list_panel = @import("../ui/list_panel.zig");
const view = @import("../ui/debug_panel.zig");
const types = @import("../dap/types.zig");
const dap = @import("dap.zig");
const side = @import("side.zig");
const activity_bar = @import("activity_bar.zig");

pub const Row = view.Row;
pub const Sub = view.Sub;
pub const Panel = view.Panel;

const double_click_ms: i64 = 400;

pub const State = struct {
    list: Panel.State = .{},
    collapsed: std.EnumSet(Sub) = std.EnumSet(Sub).initEmpty(),
    /// `Locals/p.a` → its value at the last stop (owned). A row whose
    /// value differs from this is "changed" until the next resume.
    prev: std.StringHashMapUnmanaged([]u8) = .empty,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.list.deinit(gpa);
        clearPrev(self, gpa);
        self.prev.deinit(gpa);
    }

    fn clearPrev(self: *State, gpa: Allocator) void {
        var it = self.prev.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.prev.clearRetainingCapacity();
    }
};

pub const table = .{
    .@"dap.toggle_panel" = &togglePanel,
    .@"dap.toggle_section" = &toggleSection,
    .@"dap.toggle_selected" = &toggleSelected,
    .@"dap.edit_selected" = &editSelected,
    .@"dap.remove_selected" = &removeSelected,
    .@"dap.open_selected" = &openSelected,
    .@"dap.watch_selected" = &watchSelected,
    .@"dap.copy_value" = &copyValue,
    .@"dap.enable_all_breakpoints" = &enableAll,
    .@"dap.disable_all_breakpoints" = &disableAll,
};

// ─── the rows ───────────────────────────────────────────────────────────

/// The status row's text (the dot is the painter's).
pub fn status(app: *App, arena: Allocator) Allocator.Error!view.Status {
    const s = app.dap.session orelse return .{ .kind = .none, .text = "no session" };
    if (s.stopped) |st| {
        if (s.frames.len > 0) {
            const f = s.frames[0];
            const src = if (f.source) |sp| std.fs.path.basename(sp) else "?";
            const thread = threadName(s, st.thread_id);
            return .{
                .kind = .stopped,
                .text = try std.fmt.allocPrint(arena, "stopped at {s}:{d} \u{B7} thread {s}", .{ src, f.line, thread }),
                .short = try std.fmt.allocPrint(arena, "{s}:{d} \u{B7} {s}", .{ src, f.line, thread }),
            };
        }
        return .{ .kind = .stopped, .text = try std.fmt.allocPrint(arena, "stopped ({s})", .{st.label()}) };
    }
    if (s.exited) return .{ .kind = .exited, .text = "exited" };
    if (s.running) return .{ .kind = .running, .text = "running" };
    return .{ .kind = .starting, .text = "starting" };
}

fn threadName(s: *const dap.Session, id: i64) []const u8 {
    for (s.threads) |t| if (t.id == id) return t.name;
    return "?";
}

/// The whole list for this frame, unfiltered. Frame arena.
pub fn allRows(app: *App, arena: Allocator) Allocator.Error![]Row {
    const st = &app.debug_panel;
    const s = app.dap.session;
    var out: std.ArrayListUnmanaged(Row) = .empty;
    try out.append(arena, .{ .status = try status(app, arena) });

    // VARIABLES: the scopes as trees while stopped.
    const vars: []const types.VarRow = if (s) |ss| (if (ss.stopped != null) try ss.variableRows(arena) else &.{}) else &.{};
    var n_vars: usize = 0;
    for (vars) |v| if (!v.is_scope) {
        n_vars += 1;
    };
    try out.append(arena, .{ .header = .{ .sub = .variables, .count = n_vars, .collapsed = st.collapsed.contains(.variables) } });
    if (!st.collapsed.contains(.variables)) {
        if (vars.len == 0) {
            try out.append(arena, .{ .hint = if (s == null) "no session \u{2014} F5 starts one" else if (s.?.stopped == null) "running\u{2026}" else "waiting for scopes\u{2026}" });
        } else {
            var stack: [16][]const u8 = undefined;
            for (vars) |v| {
                const depth: usize = @min(v.depth, stack.len - 1);
                stack[depth] = v.name;
                const path = try std.mem.join(arena, "/", stack[0 .. depth + 1]);
                const changed = if (st.prev.get(path)) |old| !std.mem.eql(u8, old, v.value) else false;
                try out.append(arena, .{ .variable = .{ .row = v, .changed = changed and !v.is_scope } });
            }
        }
    }

    // WATCH.
    try out.append(arena, .gap);
    try out.append(arena, .{ .header = .{ .sub = .watch, .count = app.dap.watches.items.len, .collapsed = st.collapsed.contains(.watch) } });
    if (!st.collapsed.contains(.watch)) {
        if (app.dap.watches.items.len == 0) {
            try out.append(arena, .{ .hint = "no watches \u{2014} w adds one" });
        } else for (app.dap.watches.items, 0..) |w, i| {
            const r: ?types.WatchResult = if (s) |ss| ss.watch_results.get(w) else null;
            const value: []const u8, const is_err: bool, const pending: bool = if (r) |res|
                (if (res.err) |e| .{ try std.fmt.allocPrint(arena, "err: {s}", .{e}), true, false } else if (res.ty) |t| .{ try std.fmt.allocPrint(arena, "{s} : {s}", .{ res.value, t }), false, false } else .{ res.value, false, false })
            else if (s != null and s.?.stopped != null)
                .{ "\u{2026}", false, true }
            else
                .{ "(no value)", false, false };
            try out.append(arena, .{ .watch = .{ .idx = i, .expression = w, .value = value, .is_err = is_err, .pending = pending } });
        }
    }

    // CALL STACK: the threads, then the current thread's frames.
    const n_frames: usize = if (s) |ss| ss.frames.len else 0;
    try out.append(arena, .gap);
    try out.append(arena, .{ .header = .{ .sub = .call_stack, .count = n_frames, .collapsed = st.collapsed.contains(.call_stack) } });
    if (!st.collapsed.contains(.call_stack)) {
        if (s == null or (s.?.threads.len == 0 and n_frames == 0)) {
            try out.append(arena, .{ .hint = if (s == null) "no session" else "no threads yet" });
        } else {
            const ss = s.?;
            for (ss.threads) |t| try out.append(arena, .{ .thread = .{ .id = t.id, .name = t.name, .current = ss.thread == t.id } });
            const cur = ss.currentFrame();
            for (ss.frames, 0..) |f, i| {
                const src = if (f.source) |sp| app.relPath(sp) else "?";
                try out.append(arena, .{ .frame = .{ .idx = i, .label = try std.fmt.allocPrint(arena, "{s}:{d}  {s}", .{ src, f.line, f.name }), .current = cur != null and cur.? == f.id } });
            }
            if (n_frames == 0 and ss.stopped == null) try out.append(arena, .{ .hint = "running \u{2014} pause to see the stack" });
        }
    }

    // BREAKPOINTS: every file's, by path then line; then the filters.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.dap.breakpoints.iterator();
    while (it.next()) |e| if (e.value_ptr.items.len > 0) try paths.append(arena, e.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var n_bps: usize = 0;
    for (paths.items) |p| n_bps += app.dap.bpsFor(p).len;
    try out.append(arena, .gap);
    try out.append(arena, .{ .header = .{ .sub = .breakpoints, .count = n_bps, .collapsed = st.collapsed.contains(.breakpoints) } });
    if (!st.collapsed.contains(.breakpoints)) {
        for (paths.items) |p| for (app.dap.bpsFor(p)) |b| {
            try out.append(arena, .{ .breakpoint = .{
                .path = p,
                .label = try std.fmt.allocPrint(arena, "{s}:{d}", .{ std.fs.path.basename(p), b.line + 1 }),
                .line = b.line,
                .enabled = b.enabled,
                .verified = b.verified,
                .condition = b.condition,
                .hit_condition = b.hit_condition,
                .log_message = b.log_message,
            } });
        };
        if (s) |ss| for (ss.filters.items) |f| {
            try out.append(arena, .{ .filter = .{ .id = f.filter, .label = f.label, .on = ss.enabled_filters.contains(f.filter) } });
        };
        if (n_bps == 0 and (s == null or s.?.filters.items.len == 0)) try out.append(arena, .{ .hint = "none \u{2014} F9 sets one" });
    }
    return out.items;
}

/// The rows after the filter: leaf rows whose text fuzzy-matches;
/// the status row and the headers always. Frame arena.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]Row {
    const all = try allRows(app, arena);
    const filter = app.debug_panel.list.filterText();
    if (filter.len == 0) return all;
    var out: std.ArrayListUnmanaged(Row) = .empty;
    for (all) |r| {
        const text = r.filterText() orelse {
            if (r != .hint) try out.append(arena, r);
            continue;
        };
        if (fuzzy.score(filter, text) != null) try out.append(arena, r);
    }
    return out.items;
}

/// The row under the cursor, when the section is on screen.
pub fn selected(app: *App) Allocator.Error!?Row {
    if (!side.isShown(app, .debug)) return null;
    const list = try rows(app, app.frame.allocator());
    const i = app.debug_panel.list.cursor;
    if (i >= list.len) return null;
    return list[i];
}

/// The breakpoint row under the cursor: what the `dap.*breakpoint*`
/// commands act on when the section has the keys.
pub fn selectedBreakpoint(app: *App) Allocator.Error!?view.BreakpointRow {
    if (app.focus != .panel or app.focus.panel != .debug) return null;
    const r = (try selected(app)) orelse return null;
    return if (r == .breakpoint) r.breakpoint else null;
}

/// The variable row under the cursor (`dap.set_variable`).
pub fn selectedVariable(app: *App) Allocator.Error!?types.VarRow {
    const r = (try selected(app)) orelse return null;
    return if (r == .variable) r.variable.row else null;
}

/// Remember every variable's value for the changed-flash: called when
/// the program resumes, before the session forgets the stop.
pub fn snapshotValues(app: *App) Allocator.Error!void {
    const st = &app.debug_panel;
    const gpa = app.gpa;
    st.clearPrev(gpa);
    const s = app.dap.session orelse return;
    const arena = app.frame.allocator();
    const vars = try s.variableRows(arena);
    var stack: [16][]const u8 = undefined;
    for (vars) |v| {
        if (v.is_scope) {
            stack[0] = v.name;
            continue;
        }
        const depth: usize = @min(v.depth, stack.len - 1);
        stack[depth] = v.name;
        const path = try std.mem.join(gpa, "/", stack[0 .. depth + 1]);
        errdefer gpa.free(path);
        const value = try gpa.dupe(u8, v.value);
        errdefer gpa.free(value);
        const gop = try st.prev.getOrPut(gpa, path);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.*);
            gpa.free(path);
        }
        gop.value_ptr.* = value;
    }
}

// ─── keys ───────────────────────────────────────────────────────────────

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.debug_panel;
    const before = st.list.cursor;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => {
            try settle(app, st.list.cursor >= before);
            return true;
        },
        .filter_changed => return true,
        .activate => |i| {
            st.list.cursor = i;
            try activateRow(app);
            return true;
        },
        .new_activate => {},
        .ignored => {},
    }
    if (st.list.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            app.needs_render = true;
            return true;
        },
        .left => {
            runToast(app, foldSelected(app, false));
            return true;
        },
        .right => {
            runToast(app, foldSelected(app, true));
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                ' ' => runToast(app, toggleSelected(app)),
                'e', 's' => runToast(app, editSelected(app)),
                'd', 'x' => runToast(app, removeSelected(app)),
                'w' => runToast(app, watchSelected(app)),
                'y' => runToast(app, copyValue(app)),
                'c' => runToast(app, command.run(app, .{ .static = .@"dap.toggle_breakpoint_conditional" })),
                'h' => runToast(app, command.run(app, .{ .static = .@"dap.set_breakpoint_hit_count" })),
                'l' => runToast(app, command.run(app, .{ .static = .@"dap.set_breakpoint_log_message" })),
                'o' => runToast(app, openSelected(app)),
                'z' => runToast(app, toggleSection(app)),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// The cursor never rests on the blank row between two sections: from
/// wherever a move landed it walks on in the move's direction to the
/// next stop, or back when there is none (`http_panel`'s rule).
fn settle(app: *App, down: bool) Allocator.Error!void {
    const st = &app.debug_panel;
    const list = try rows(app, app.frame.allocator());
    if (list.len == 0) return;
    var i = st.list.cursor;
    if (i >= list.len) i = list.len - 1;
    if (list[i].isStop()) {
        st.list.cursor = i;
        return;
    }
    var j = i;
    if (down) {
        while (j + 1 < list.len) : (j += 1) if (list[j + 1].isStop()) {
            st.list.cursor = j + 1;
            return;
        };
        j = i;
        while (j > 0) : (j -= 1) if (list[j - 1].isStop()) {
            st.list.cursor = j - 1;
            return;
        };
    } else {
        while (j > 0) : (j -= 1) if (list[j - 1].isStop()) {
            st.list.cursor = j - 1;
            return;
        };
        j = i;
        while (j + 1 < list.len) : (j += 1) if (list[j + 1].isStop()) {
            st.list.cursor = j + 1;
            return;
        };
    }
    st.list.cursor = i;
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("debug: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// Enter: what the row is for.
fn activateRow(app: *App) Allocator.Error!void {
    const r = (try selected(app)) orelse return;
    switch (r) {
        .status => |s| runToast(app, switch (s.kind) {
            .none, .exited => command.run(app, .{ .static = .@"dap.run" }),
            .stopped => command.run(app, .{ .static = .@"dap.continue" }),
            .running, .starting => command.run(app, .{ .static = .@"dap.pause" }),
        }),
        .header => runToast(app, toggleSection(app)),
        .variable => |v| if (v.row.expandable) runToast(app, toggleSection(app)) else runToast(app, editSelected(app)),
        .watch => runToast(app, editSelected(app)),
        .thread, .frame, .breakpoint => runToast(app, openSelected(app)),
        .filter => runToast(app, toggleSelected(app)),
        .hint, .gap => {},
    }
    app.needs_render = true;
}

// ─── commands ───────────────────────────────────────────────────────────

/// `dap.toggle_panel`: the DEBUG section shown, or hidden when it is.
fn togglePanel(app: *App) CommandError!void {
    if (side.isShown(app, .debug)) {
        side.hide(app, .debug);
        return;
    }
    activity_bar.enter(app, .debug);
    side.place(app, .debug, true);
}

/// `dap.toggle_section`: fold the section (or the expandable variable)
/// under the cursor; on a leaf row, the section it belongs to.
fn toggleSection(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.debug_panel;
    const list = try rows(app, arena);
    if (st.list.cursor >= list.len) return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    switch (list[st.list.cursor]) {
        .variable => |v| if (v.row.expandable) return dap.toggleExpand(app, v.row),
        else => {},
    }
    // Walk up to the header this row sits under.
    var i = st.list.cursor;
    while (true) : (i -= 1) {
        if (list[i] == .header) {
            const sub = list[i].header.sub;
            if (st.collapsed.contains(sub)) st.collapsed.remove(sub) else st.collapsed.insert(sub);
            st.list.cursor = i;
            app.needs_render = true;
            return;
        }
        if (i == 0) return app.diag.fail(arena, "debug: not in a section", .{});
    }
}

/// ← folds, → unfolds — the section, or an expandable variable.
fn foldSelected(app: *App, open: bool) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.debug_panel;
    const list = try rows(app, arena);
    if (st.list.cursor >= list.len) return;
    switch (list[st.list.cursor]) {
        .variable => |v| if (v.row.expandable and v.row.expanded != open) return dap.toggleExpand(app, v.row),
        .header => |h| {
            if (open) st.collapsed.remove(h.sub) else st.collapsed.insert(h.sub);
            app.needs_render = true;
            return;
        },
        else => {},
    }
    if (!open) return toggleSection(app);
}

/// `dap.toggle_selected` (Space): a checkbox flips, a fold toggles.
fn toggleSelected(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    switch (r) {
        .breakpoint => return command.run(app, .{ .static = .@"dap.toggle_breakpoint_enabled" }),
        .filter => |f| return dap.toggleFilter(app, f.id),
        .header, .variable => return toggleSection(app),
        .status => return activateRow(app),
        else => return app.diag.fail(arena, "debug: nothing to toggle here", .{}),
    }
}

/// `dap.edit_selected` (e): a variable's value, a watch's expression,
/// a breakpoint's condition.
fn editSelected(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    switch (r) {
        .variable => |v| return dap.setVariableFor(app, v.row),
        .watch => return editWatch(app),
        .breakpoint => return command.run(app, .{ .static = .@"dap.toggle_breakpoint_conditional" }),
        else => return app.diag.fail(arena, "debug: nothing to edit here", .{}),
    }
}

/// `dap.remove_selected` (d / x): a watch, a breakpoint.
fn removeSelected(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    switch (r) {
        .watch => |w| {
            const expr = try arena.dupe(u8, w.expression);
            dap.removeWatch(app, expr);
        },
        .breakpoint => return command.run(app, .{ .static = .@"dap.remove_breakpoint" }),
        else => return app.diag.fail(arena, "debug: nothing to remove here", .{}),
    }
}

/// `dap.open_selected` (o / Enter): a frame selects itself and the
/// editor jumps; a breakpoint opens its line; a thread becomes current.
fn openSelected(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    switch (r) {
        .frame => |f| return dap.selectFrame(app, f.idx),
        .thread => |t| return dap.selectThread(app, t.id),
        .breakpoint => |b| {
            const id = app.openPath(b.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(arena, "debug: cannot open {s}", .{b.path}),
            };
            if (app.panes.editor(id)) |e| {
                const ed = e.buf.editor;
                ed.anchor = null;
                ed.placeCursor(@min(b.line, @as(u32, @intCast(ed.lineCount() -| 1))), 0);
            }
            app.needs_render = true;
        },
        else => return app.diag.fail(arena, "debug: nothing to open here", .{}),
    }
}

/// `dap.watch_selected` (w): the variable under the cursor becomes a
/// watch; elsewhere the add-watch prompt.
fn watchSelected(app: *App) CommandError!void {
    const r = try selected(app);
    if (r != null and r.? == .variable and !r.?.variable.row.is_scope) {
        const name = try app.frame.allocator().dupe(u8, r.?.variable.row.name);
        if (app.dap.hasWatch(name)) return app.diag.fail(app.frame.allocator(), "watch: already tracking {s}", .{name});
        return dap.addWatch(app, name);
    }
    return dap.addWatchPrompt(app);
}

/// `dap.copy_value` (y): the value under the cursor to the clipboard.
fn copyValue(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: nothing under the cursor", .{});
    const value: []const u8 = switch (r) {
        .variable => |v| v.row.value,
        .watch => |w| w.value,
        .frame => |f| f.label,
        .breakpoint => |b| b.label,
        else => return app.diag.fail(arena, "debug: nothing to copy here", .{}),
    };
    try app.clipboard.setYank(value, false);
    app.toast("yanked: {s}{s}", .{ value[0..@min(value.len, 40)], if (value.len > 40) "\u{2026}" else "" });
}

/// The watch half of `dap.edit_selected`: a prompt seeded with the
/// selected watch's expression; accept replaces it in place.
fn editWatch(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return app.diag.fail(arena, "debug: no watch under the cursor", .{});
    if (r != .watch) return app.diag.fail(arena, "debug: no watch under the cursor", .{});
    return dap.editWatchPrompt(app, r.watch.expression);
}

fn enableAll(app: *App) CommandError!void {
    return dap.setAllEnabled(app, true);
}

fn disableAll(app: *App) CommandError!void {
    return dap.setAllEnabled(app, false);
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .debug };
    app.needs_render = true;
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.debug_panel;
    switch (m.kind) {
        .press => {
            const list = try rows(app, app.frame.allocator());
            if (idx >= list.len) return;
            // The blank row between two sections takes no click.
            if (!list[idx].isStop()) return;
            focusPanel(app);
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            switch (list[idx]) {
                // One click folds a header, flips a checkbox, opens a
                // composite; a double click activates the rest.
                .header, .filter => runToast(app, toggleSelected(app)),
                .variable => |v| if (v.row.expandable) runToast(app, toggleSection(app)) else if (again) try activateRow(app),
                .breakpoint => {
                    // The checkbox is the row's first four cells after the
                    // marker + indent; the label opens the line.
                    const r = hitRectOf(app, idx) orelse return;
                    if (m.x < r.x + list_panel.marker_w + 2 + 4) runToast(app, toggleSelected(app)) else if (again) try activateRow(app);
                },
                else => if (again) {
                    st.last_click = null;
                    try activateRow(app);
                },
            }
        },
        else => {},
    }
    app.needs_render = true;
}

fn hitRectOf(app: *App, idx: u32) ?Rect {
    var i = app.hits.items.items.len;
    while (i > 0) {
        i -= 1;
        const e = app.hits.items.items[i];
        if (e.target == .row and e.target.row.panel == .debug and e.target.row.idx == idx) return e.rect;
    }
    return null;
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len or !list[idx].isStop()) return;
    focusPanel(app);
    app.debug_panel.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .new => runToast(app, dap.addWatchPrompt(app)),
        .sort, .refresh, .history => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.debug_panel.list.filter_focused = true;
}

/// The wheel over the list moves the cursor `rows` rows.
pub fn wheel(app: *App, down: bool, step: usize) void {
    const st = &app.debug_panel;
    st.list.cursor = if (down) @min(st.list.cursor + step, st.list.total -| 1) else st.list.cursor -| step;
    app.needs_render = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.debug_panel;
    const total = st.list.total;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.list.cursor = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => st.list.cursor -|= 3,
        .scroll_down => st.list.cursor = @min(st.list.cursor + 3, total - 1),
        else => {},
    }
}

/// The right-click / kebab menu for the row under the cursor. Every
/// row names commands only, so a wrong id is a compile error.
pub fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const arena = app.frame.allocator();
    const r = (try selected(app)) orelse return;
    const title: []const u8, const items: []const MenuItem = switch (r) {
        .status => |s| .{ "Session", switch (s.kind) {
            .none, .exited => &.{
                .{ .label = "Start debugging", .action = .{ .command = .@"dap.run" } },
                .{ .label = "Hide DEBUG section", .action = .{ .command = .@"dap.toggle_panel" }, .separator_before = true },
            },
            .stopped => &.{
                .{ .label = "Continue", .action = .{ .command = .@"dap.continue" } },
                .{ .label = "Step over", .action = .{ .command = .@"dap.next" } },
                .{ .label = "Step into", .action = .{ .command = .@"dap.step_in" } },
                .{ .label = "Step out", .action = .{ .command = .@"dap.step_out" } },
                .{ .label = "Restart", .action = .{ .command = .@"dap.restart" }, .separator_before = true },
                .{ .label = "Stop", .action = .{ .command = .@"dap.terminate" } },
                .{ .label = "Debug console", .action = .{ .command = .@"dap.repl" }, .separator_before = true },
            },
            .running, .starting => &.{
                .{ .label = "Pause", .action = .{ .command = .@"dap.pause" } },
                .{ .label = "Restart", .action = .{ .command = .@"dap.restart" } },
                .{ .label = "Stop", .action = .{ .command = .@"dap.terminate" } },
                .{ .label = "Debug console", .action = .{ .command = .@"dap.repl" }, .separator_before = true },
            },
        } },
        .header => |h| .{ h.sub.label(), switch (h.sub) {
            .variables => &.{
                .{ .label = if (h.collapsed) "Expand" else "Collapse", .action = .{ .command = .@"dap.toggle_section" } },
            },
            .watch => &.{
                .{ .label = if (h.collapsed) "Expand" else "Collapse", .action = .{ .command = .@"dap.toggle_section" } },
                .{ .label = "+ Add watch\u{2026}", .action = .{ .command = .@"dap.add_watch" }, .separator_before = true },
                .{ .label = "Clear watches", .action = .{ .command = .@"dap.clear_watches" } },
            },
            .call_stack => &.{
                .{ .label = if (h.collapsed) "Expand" else "Collapse", .action = .{ .command = .@"dap.toggle_section" } },
                .{ .label = "Switch thread\u{2026}", .action = .{ .command = .@"dap.pick_thread" }, .separator_before = true },
                .{ .label = "Pause", .action = .{ .command = .@"dap.pause" } },
            },
            .breakpoints => &.{
                .{ .label = if (h.collapsed) "Expand" else "Collapse", .action = .{ .command = .@"dap.toggle_section" } },
                .{ .label = "Enable all", .action = .{ .command = .@"dap.enable_all_breakpoints" }, .separator_before = true },
                .{ .label = "Disable all", .action = .{ .command = .@"dap.disable_all_breakpoints" } },
                .{ .label = "Clear all in this file", .action = .{ .command = .@"dap.clear_all_breakpoints" } },
                .{ .label = "Exception breakpoints\u{2026}", .action = .{ .command = .@"dap.exceptions" }, .separator_before = true },
            },
        } },
        .variable => |v| .{ if (v.row.is_scope) "Scope" else "Variable", if (v.row.is_scope) &.{
            .{ .label = if (v.row.expanded) "Collapse" else "Expand", .action = .{ .command = .@"dap.toggle_section" } },
        } else &.{
            .{ .label = "Set value\u{2026}", .action = .{ .command = .@"dap.set_variable" } },
            .{ .label = "Add to watch", .action = .{ .command = .@"dap.watch_selected" } },
            .{ .label = "Copy value", .action = .{ .command = .@"dap.copy_value" } },
            .{ .label = if (v.row.expanded) "Collapse" else "Expand", .action = .{ .command = .@"dap.toggle_section" }, .separator_before = true },
        } },
        .watch => .{ "Watch", &.{
            .{ .label = "Edit expression\u{2026}", .action = .{ .command = .@"dap.edit_selected" } },
            .{ .label = "Remove", .action = .{ .command = .@"dap.remove_selected" } },
            .{ .label = "Copy value", .action = .{ .command = .@"dap.copy_value" } },
            .{ .label = "+ Add watch\u{2026}", .action = .{ .command = .@"dap.add_watch" }, .separator_before = true },
        } },
        .thread => .{ "Thread", &.{
            .{ .label = "Switch to this thread", .action = .{ .command = .@"dap.open_selected" } },
            .{ .label = "Pause", .action = .{ .command = .@"dap.pause" } },
        } },
        .frame => .{ "Frame", &.{
            .{ .label = "Jump to frame", .action = .{ .command = .@"dap.open_selected" } },
            .{ .label = "Copy location", .action = .{ .command = .@"dap.copy_value" } },
        } },
        .breakpoint => |b| .{ "Breakpoint", &.{
            .{ .label = "Go to line", .action = .{ .command = .@"dap.open_selected" } },
            .{ .label = if (b.enabled) "Disable" else "Enable", .action = .{ .command = .@"dap.toggle_breakpoint_enabled" } },
            .{ .label = "Edit condition\u{2026}", .action = .{ .command = .@"dap.toggle_breakpoint_conditional" }, .separator_before = true },
            .{ .label = "Edit hit count\u{2026}", .action = .{ .command = .@"dap.set_breakpoint_hit_count" } },
            .{ .label = "Edit log message\u{2026}", .action = .{ .command = .@"dap.set_breakpoint_log_message" } },
            .{ .label = "Remove", .action = .{ .command = .@"dap.remove_breakpoint" }, .separator_before = true },
        } },
        .filter => |f| .{ "Exception breakpoint", &.{
            .{ .label = if (f.on) "Disable" else "Enable", .action = .{ .command = .@"dap.toggle_selected" } },
        } },
        .hint, .gap => return,
    };
    _ = arena;
    const copy = try app.gpa.dupe(MenuItem, items);
    errdefer app.gpa.free(copy);
    try app.openMenu(title, copy, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.debug_panel;
    const list = try rows(app, ui.arena);
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .debug,
        .label = "DEBUG",
        .rows = list,
        .paintRow = view.paintRow,
        .has_kebab = true,
        .show_refresh = false,
        .new_chip = true,
        .filter_gap = true,
        .empty = .{ .message = "No session", .hint = "F5 starts one" },
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "no session: the status row, four headers with their hints, a watch row; the filter narrows; Esc leaves" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.activity_debug" });
    try testing.expect(side.isShown(&app, .debug));
    try testing.expectEqual(app_mod.FocusId{ .panel = .debug }, app.focus);
    try dap.addWatch(&app, "x + 1");
    const t1 = try screenText(&app);
    defer testing.allocator.free(t1);
    try testing.expect(std.mem.indexOf(u8, t1, "DEBUG") != null);
    try testing.expect(std.mem.indexOf(u8, t1, "○ no session") != null);
    // A blank line sits between the filter and the first row, as in
    // every other list panel: the row under "/ filter" holds nothing
    // across the panel's columns.
    {
        var lines = std.mem.splitScalar(u8, t1, '\n');
        var filter_row: ?[]const u8 = null;
        var next_row: ?[]const u8 = null;
        while (lines.next()) |line| {
            if (filter_row != null) {
                next_row = line;
                break;
            }
            if (std.mem.indexOf(u8, line, "/ filter") != null) filter_row = line;
        }
        const fr = filter_row orelse return error.NoFilterRow;
        const nr = next_row orelse return error.NoRowUnderFilter;
        const col = std.mem.indexOf(u8, fr, "/ filter").?;
        const from = @min(col, nr.len);
        const end = if (std.mem.indexOf(u8, nr[from..], "\u{2502}")) |b| from + b else nr.len;
        try testing.expectEqualStrings("", std.mem.trim(u8, nr[from..end], " "));
        try testing.expect(std.mem.indexOf(u8, nr, "no session") == null);
    }
    try testing.expect(std.mem.indexOf(u8, t1, "\u{F47C} VARIABLES (0)") != null);
    try testing.expect(std.mem.indexOf(u8, t1, "⌖ x + 1 = (no value)") != null);
    try testing.expect(std.mem.indexOf(u8, t1, "\u{F47C} BREAKPOINTS (0)") != null);
    try testing.expect(std.mem.indexOf(u8, t1, "none — F9 sets one") != null);
    // Folding WATCH hides its rows; the count stays.
    const all = try rows(&app, app.frame.allocator());
    var watch_hdr: usize = 0;
    for (all, 0..) |r, i| if (r == .header and r.header.sub == .watch) {
        watch_hdr = i;
    };
    app.debug_panel.list.cursor = watch_hdr;
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(app.debug_panel.collapsed.contains(.watch));
    const t2 = try screenText(&app);
    defer testing.allocator.free(t2);
    try testing.expect(std.mem.indexOf(u8, t2, "\u{F460} WATCH (1)") != null);
    try testing.expect(std.mem.indexOf(u8, t2, "x + 1 =") == null);
    try app.handle(.{ .key = Key.named(.right) });
    try testing.expect(!app.debug_panel.collapsed.contains(.watch));
    // `/` filters the leaf rows; headers stay.
    try app.handle(.{ .key = Key.char('/') });
    for ("zzz") |c| try app.handle(.{ .key = Key.char(c) });
    const t3 = try screenText(&app);
    defer testing.allocator.free(t3);
    try testing.expect(std.mem.indexOf(u8, t3, "WATCH (1)") != null);
    try testing.expect(std.mem.indexOf(u8, t3, "x + 1 =") == null);
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.focus == .pane);
}

test "a blank row sits between one section and the next — none before the first, none after the last; j / k step over it and a click on it does nothing" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.activity_debug" });
    const all = try rows(&app, app.frame.allocator());
    // The status row, then each header with its hint; a gap before every
    // header but the first and none at the end.
    var headers: usize = 0;
    for (all, 0..) |r, i| {
        if (r == .header) {
            headers += 1;
            if (i > 1) try testing.expect(all[i - 1] == .gap) else try testing.expect(all[i - 1] == .status);
        }
        if (r == .gap) {
            try testing.expect(i + 1 < all.len);
            try testing.expect(all[i + 1] == .header);
            try testing.expect(all[i - 1] != .gap);
        }
    }
    try testing.expectEqual(@as(usize, 4), headers);
    try testing.expect(all[all.len - 1] != .gap);
    // On the screen: the row above WATCH is blank across the panel.
    const t = try screenText(&app);
    defer testing.allocator.free(t);
    {
        var lines = std.mem.splitScalar(u8, t, '\n');
        var prev: []const u8 = "";
        var seen = false;
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "WATCH (0)")) |col| {
                const end = if (std.mem.indexOf(u8, prev[@min(col, prev.len)..], "\u{2502}")) |b| @min(col, prev.len) + b else prev.len;
                try testing.expectEqualStrings("", std.mem.trim(u8, prev[@min(col, prev.len)..end], " "));
                seen = true;
            }
            prev = line;
        }
        try testing.expect(seen);
    }
    // The hint under VARIABLES is row 2; j lands on WATCH's header (4),
    // never on the gap (3); k walks back over it. `screenText` rendered a
    // frame, and a frame resets the frame arena `all` was built on, so the
    // rows are taken again rather than read through a dangling slice —
    // which macOS's allocator happened to keep readable and Linux's did
    // not (a segfault, not a failed assert).
    const after = try rows(&app, app.frame.allocator());
    try testing.expect(after[2] == .hint);
    try testing.expect(after[3] == .gap);
    try testing.expect(after[4] == .header);
    app.debug_panel.list.cursor = 2;
    try app.handle(.{ .key = Key.char('j') });
    try testing.expectEqual(@as(usize, 4), app.debug_panel.list.cursor);
    try app.handle(.{ .key = Key.char('k') });
    try testing.expectEqual(@as(usize, 2), app.debug_panel.list.cursor);
    try app.handle(.{ .key = Key.named(.down) });
    try testing.expectEqual(@as(usize, 4), app.debug_panel.list.cursor);
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqual(@as(usize, 2), app.debug_panel.list.cursor);
    // A press on the gap moves nothing and opens nothing.
    try rowMouse(&app, 3, .{ .x = 5, .y = 5, .kind = .press, .button = .left });
    try testing.expectEqual(@as(usize, 2), app.debug_panel.list.cursor);
    try rowMouse(&app, 3, .{ .x = 5, .y = 5, .kind = .press, .button = .right });
    try testing.expectEqual(@as(usize, 2), app.debug_panel.list.cursor);
    try testing.expect(app.overlay != .menu);
}

test "row menus name real ids for every row kind; d removes the watch under the cursor; the section moves right and still draws" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/prog.dbg");
    try e.buf.editor.setText("let x = 1\nx = x + 1\n");
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try dap.addWatch(&app, "x");
    try command.run(&app, .{ .static = .@"view.activity_debug" });
    const all = try rows(&app, app.frame.allocator());
    for (all, 0..) |_, i| {
        app.debug_panel.list.cursor = i;
        try openRowMenu(&app, 5, 5);
        if (app.overlay == .menu) {
            for (app.overlay.menu.items) |it| try testing.expect(it.action == .command);
            app.overlay.deinit(app.gpa);
            app.overlay = .none;
        }
    }
    // The watch row: d removes it.
    for (all, 0..) |r, i| if (r == .watch) {
        app.debug_panel.list.cursor = i;
    };
    app.focus = .{ .panel = .debug };
    try app.handle(.{ .key = Key.char('d') });
    try testing.expectEqual(@as(usize, 0), app.dap.watches.items.len);
    // The breakpoint row: Space disables it, x removes it.
    const all2 = try rows(&app, app.frame.allocator());
    for (all2, 0..) |r, i| if (r == .breakpoint) {
        app.debug_panel.list.cursor = i;
    };
    try app.handle(.{ .key = Key.char(' ') });
    try testing.expect(!app.dap.bpsFor("/tmp/prog.dbg")[0].enabled);
    try app.handle(.{ .key = Key.char('x') });
    try testing.expectEqual(@as(usize, 0), app.dap.bpsFor("/tmp/prog.dbg").len);
    // Moved to the right column it is the same list.
    try side.move(&app, .debug, .right);
    try testing.expect(side.isShown(&app, .debug));
    try testing.expectEqual(side.Side.right, side.sideOf(&app, .debug));
    const t = try screenText(&app);
    defer testing.allocator.free(t);
    try testing.expect(std.mem.indexOf(u8, t, "\u{F47C} CALL STACK (0)") != null);
}
