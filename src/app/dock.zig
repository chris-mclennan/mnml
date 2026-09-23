//! Dock widgets — the middle tier between panes and chrome: small
//! panels pinned to a corner of the editor body, visible NEXT to the
//! buffer rather than instead of it. A widget is a title bar with a
//! kebab and a close glyph over a body: static text, the live tail of a
//! file, a clock, or the git branch. Widgets sharing a corner stack
//! inward (bottom corners upward, top corners downward) and a corner's
//! stack never takes more than half the body. `Overlay` floats over the
//! editor; `Inline` claims a strip at the top or bottom edge that the
//! panes reflow around. `Translucent` blends the ground with what is
//! underneath so the editor shows through.
//!
//! The title bar drags: a ghost chip follows the pointer, the landing
//! rect is previewed, and a drop within `snap_cells` of another
//! widget's centre inherits that widget's corner and sits beside it.
//! Everything persists in the session file (`session.zig` calls
//! `capture` / `apply`).
//!
//! On the todos shape where it applies: the file tail runs on a worker
//! in `State.group` and lands as `.dock = *TailResult`, owned by the
//! event and adopted-or-freed in `handle`; a stale generation (the
//! widget was edited or closed meanwhile) is dropped. The view is
//! `ui/dock_view.zig`; the mouse prongs are routed here by `dispatch`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const types = @import("../core/dock.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const dock_view = @import("../ui/dock_view.zig");
const transcript = @import("../ai/transcript.zig");
const cmd_picker = @import("cmd_picker.zig");
const PaneId = app_mod.PaneId;

pub const Corner = types.Corner;
pub const Placement = types.Placement;
pub const Opacity = types.Opacity;
pub const Size = types.Size;
pub const Setting = types.Setting;

/// The parts of a widget a click can land on (`hit.DockPart`).
pub const Part = hit.DockPart;

pub const Content = union(enum) {
    /// Owned.
    text: []u8,
    /// `path` owned; the last `max_lines` lines are re-read on the worker.
    log_tail: struct { path: []u8, max_lines: u16 },
    clock,
    git_branch,

    pub fn kind(c: Content) SavedKind {
        return switch (c) {
            .text => .text,
            .log_tail => .log_tail,
            .clock => .clock,
            .git_branch => .git_branch,
        };
    }
};

pub const Widget = struct {
    /// Stable within the session; the hit map and the menus name it.
    id: u32,
    corner: Corner,
    /// Percent of the editor body, clamped to `types.min_pct..max_pct`.
    w_pct: u8,
    h_pct: u8,
    /// Owned.
    title: []u8,
    content: Content,
    placement: Placement = .overlay,
    opacity: Opacity = .solid,
    /// Rows scrolled off the top of the body (the wheel).
    scroll: u16 = 0,
    // ── the tail, runtime only ──
    /// The last read's lines. Owned.
    tail_lines: [][]u8 = &.{},
    /// Lines the file has in all, so the title can say `▼N`.
    tail_total: u32 = 0,
    tail_busy: bool = false,
    tail_at_ms: i64 = 0,
    /// Bumped when the path changes or the widget goes; a result
    /// carrying an older number is dropped.
    tail_generation: u32 = 0,

    pub fn deinit(w: *Widget, gpa: Allocator) void {
        gpa.free(w.title);
        switch (w.content) {
            .text => |t| gpa.free(t),
            .log_tail => |lt| gpa.free(lt.path),
            .clock, .git_branch => {},
        }
        freeLines(gpa, w.tail_lines);
        w.tail_lines = &.{};
    }

    pub fn setSize(w: *Widget, s: Size) void {
        const p = s.pct();
        w.w_pct = p.w;
        w.h_pct = p.h;
    }
};

fn freeLines(gpa: Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

/// A finished tail read. Owned by the event; `handle` copies the lines
/// it keeps onto the gpa and destroys the box.
pub const TailResult = struct {
    arena: std.heap.ArenaAllocator,
    id: u32,
    generation: u32,
    lines: []const []const u8 = &.{},
    total: u32 = 0,
    /// The file could not be read; the widget shows why.
    err: ?[]const u8 = null,

    pub fn create(gpa: Allocator, id: u32, generation: u32) Allocator.Error!*TailResult {
        const r = try gpa.create(TailResult);
        r.* = .{ .arena = .init(gpa), .id = id, .generation = generation };
        return r;
    }

    pub fn destroy(self: *TailResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const table = .{
    .@"dock.new_text" = &newTextBl,
    .@"dock.new_text_br" = &newTextBr,
    .@"dock.new_text_tl" = &newTextTl,
    .@"dock.new_text_tr" = &newTextTr,
    .@"dock.new_log_tail" = &newLogTail,
    .@"dock.close_all" = &closeAll,
    .@"dock.move_corner_next" = &moveCornerNext,
    .@"dock.toggle" = &toggle,
    .@"dock.add_preset" = &addPreset,
    .@"dock.remove" = &removeFocused,
    .@"dock.edit" = &editFocused,
    .@"dock.rename" = &renameFocused,
};

/// A drop this close to another widget's centre joins its corner.
pub const snap_cells: u16 = 8;
/// A tail re-reads this often.
pub const tail_ms: i64 = 1000;
/// Bytes of a tailed file's end that are read.
pub const tail_cap: usize = 64 * 1024;
pub const default_max_lines: u16 = 50;
pub const default_log_rel = ".mnml/run.log";
/// Narrower or shorter than this and the widget is not painted.
pub const min_w: u16 = 8;
pub const min_h: u16 = 3;

pub const State = struct {
    widgets: std.ArrayListUnmanaged(Widget) = .empty,
    next_id: u32 = 1,
    /// `dock.toggle`: every widget hidden, strips released.
    hidden: bool = false,
    /// The widget the kebab commands act on: the last one clicked,
    /// created, or menu-opened.
    focused: ?u32 = null,
    /// Where the pointer is during a title drag (the ghost + preview).
    drag_to: ?struct { x: u16, y: u16 } = null,
    /// D3: the tail workers.
    group: Io.Group = .init,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        for (self.widgets.items) |*w| w.deinit(gpa);
        self.widgets.deinit(gpa);
    }

    pub fn find(self: *State, id: u32) ?*Widget {
        for (self.widgets.items) |*w| if (w.id == id) return w;
        return null;
    }

    pub fn indexOf(self: *const State, id: u32) ?usize {
        for (self.widgets.items, 0..) |w, i| if (w.id == id) return i;
        return null;
    }

    /// The focused widget, else the newest.
    pub fn target(self: *State) ?*Widget {
        if (self.focused) |id| if (self.find(id)) |w| return w;
        if (self.widgets.items.len == 0) return null;
        return &self.widgets.items[self.widgets.items.len - 1];
    }
};

// ─── adding and removing ────────────────────────────────────────────────

pub const NewWidget = struct {
    corner: Corner = .bottom_left,
    title: []const u8,
    content: union(enum) { text: []const u8, log_tail: []const u8, clock, git_branch },
    size: Size = .medium,
    placement: Placement = .overlay,
    opacity: Opacity = .solid,
};

/// Append a widget; it becomes the focused one.
pub fn add(app: *App, spec: NewWidget) Allocator.Error!u32 {
    const gpa = app.gpa;
    const st = &app.dock;
    const title = try gpa.dupe(u8, spec.title);
    errdefer gpa.free(title);
    const content: Content = switch (spec.content) {
        .text => |t| .{ .text = try gpa.dupe(u8, t) },
        .log_tail => |p| .{ .log_tail = .{ .path = try gpa.dupe(u8, p), .max_lines = default_max_lines } },
        .clock => .clock,
        .git_branch => .git_branch,
    };
    errdefer switch (content) {
        .text => |t| gpa.free(t),
        .log_tail => |lt| gpa.free(lt.path),
        else => {},
    };
    const id = st.next_id;
    st.next_id += 1;
    const p = spec.size.pct();
    try st.widgets.append(gpa, .{ .id = id, .corner = spec.corner, .w_pct = p.w, .h_pct = p.h, .title = title, .content = content, .placement = spec.placement, .opacity = spec.opacity });
    st.focused = id;
    st.hidden = false;
    app.needs_render = true;
    return id;
}

/// Remove a widget. The tail group is cancelled first — a worker may
/// be reading the path this frees.
pub fn remove(app: *App, id: u32) void {
    const st = &app.dock;
    const i = st.indexOf(id) orelse return;
    st.group.cancel(app.io);
    var w = st.widgets.orderedRemove(i);
    w.deinit(app.gpa);
    if (st.focused == id) st.focused = null;
    app.needs_render = true;
}

// ─── layout ─────────────────────────────────────────────────────────────

pub const Placed = struct {
    id: u32,
    rect: Rect,
    /// Sits in a strip rather than over the editor.
    inline_strip: bool,
};

pub const Strips = struct { top: u16 = 0, bottom: u16 = 0 };

const Wh = struct { w: u16, h: u16 };

fn widgetSize(area: Rect, w: Widget) Wh {
    const wp = std.math.clamp(w.w_pct, types.min_pct, types.max_pct);
    const hp = std.math.clamp(w.h_pct, types.min_pct, types.max_pct);
    return .{
        .w = @intCast(@as(u32, area.w) * wp / 100),
        .h = @intCast(@as(u32, area.h) * hp / 100),
    };
}

/// The rows the inline widgets claim at each edge: the tallest widget
/// at that edge, each edge capped at a quarter of the body so both
/// together never pass half.
pub fn strips(area: Rect, widgets: []const Widget, hidden: bool) Strips {
    var out: Strips = .{};
    if (hidden) return out;
    const cap = area.h / 4;
    for (widgets) |w| {
        if (w.placement != .@"inline") continue;
        const h = @min(widgetSize(area, w).h, cap);
        if (h < min_h) continue;
        if (w.corner.isBottom()) out.bottom = @max(out.bottom, h) else out.top = @max(out.top, h);
    }
    return out;
}

/// The editor body with the strips taken off.
pub fn bodyAfterStrips(area: Rect, s: Strips) Rect {
    var r = area;
    r = r.splitTop(s.top).rest;
    r = r.splitBottom(s.bottom).top;
    return r;
}

/// Where every widget paints. Inline widgets tile their strip left to
/// right in insertion order; overlay widgets stack in their corner.
/// `area` is the whole editor body (strips included).
pub fn layout(arena: Allocator, area: Rect, widgets: []const Widget, hidden: bool) Allocator.Error![]Placed {
    var out: std.ArrayListUnmanaged(Placed) = .empty;
    if (hidden or area.w < 12 or area.h < 4) return out.toOwnedSlice(arena);
    const s = strips(area, widgets, hidden);
    const body = bodyAfterStrips(area, s);

    // Inline strips.
    inline for (.{ true, false }) |top| {
        const strip_h = if (top) s.top else s.bottom;
        if (strip_h >= min_h) {
            var n: u16 = 0;
            for (widgets) |w| if (w.placement == .@"inline" and w.corner.isBottom() != top) {
                n += 1;
            };
            const strip = if (top) area.splitTop(strip_h).top else area.splitBottom(strip_h).rest;
            var x: u16 = strip.x;
            const each: u16 = if (n == 0) 0 else strip.w / n;
            var i: u16 = 0;
            for (widgets) |w| if (w.placement == .@"inline" and w.corner.isBottom() != top) {
                i += 1;
                const wid: u16 = if (i == n) strip.right() - x else each;
                if (wid >= min_w) try out.append(arena, .{ .id = w.id, .rect = Rect.init(x, strip.y, wid, strip.h), .inline_strip = true });
                x += wid;
            };
        }
    }

    // Overlay corners. Bottom corners stack upward: the first widget
    // sits at the very bottom, so the list is walked in order and each
    // next one lands above it. Top corners stack downward. A widget its
    // corner has no room for (the stack is capped at half the body)
    // overflows to the next corner with room, clockwise — a drop on a
    // full corner used to leave it unpainted, with no rect and no hit.
    const max_stack = body.h / 2;
    var used = std.EnumArray(Corner, u16).initFill(0);
    var overflow: std.ArrayListUnmanaged(usize) = .empty;
    for (widgets, 0..) |w, i| {
        if (w.placement != .overlay) continue;
        const sz = widgetSize(body, w);
        if (sz.w < min_w or sz.h < min_h) continue;
        if (!try placeInCorner(&out, arena, body, &used, max_stack, w.id, sz, w.corner)) try overflow.append(arena, i);
    }
    for (overflow.items) |i| {
        const w = widgets[i];
        const sz = widgetSize(body, w);
        var corner = w.corner.next();
        var tries: u8 = 0;
        while (tries < 3) : ({
            corner = corner.next();
            tries += 1;
        }) {
            if (try placeInCorner(&out, arena, body, &used, max_stack, w.id, sz, corner)) break;
        }
    }
    return out.toOwnedSlice(arena);
}

const CornerUsed = std.EnumArray(Corner, u16);

/// One widget into `corner`'s stack when the cap leaves room for it.
fn placeInCorner(out: *std.ArrayListUnmanaged(Placed), arena: Allocator, body: Rect, used: *CornerUsed, max_stack: u16, id: u32, sz: Wh, corner: Corner) Allocator.Error!bool {
    const u = used.get(corner);
    if (u + sz.h > max_stack) return false;
    const x = if (corner.isRight()) body.right() - sz.w else body.x;
    const y = if (corner.isBottom()) body.bottom() - u - sz.h else body.y + u;
    try out.append(arena, .{ .id = id, .rect = Rect.init(x, y, sz.w, sz.h), .inline_strip = false });
    used.set(corner, u + sz.h);
    return true;
}

/// The corner with room for widget `id` (its stack cap counted without
/// it): `want` itself, else the next corners clockwise. Null when no
/// corner can hold it.
pub fn cornerWithRoom(body: Rect, widgets: []const Widget, id: u32, want: Corner) ?Corner {
    const moving = for (widgets) |w| {
        if (w.id == id) break w;
    } else return null;
    const sz = widgetSize(body, moving);
    const max_stack = body.h / 2;
    var used = CornerUsed.initFill(0);
    for (widgets) |w| {
        if (w.id == id or w.placement != .overlay) continue;
        const s = widgetSize(body, w);
        if (s.w < min_w or s.h < min_h) continue;
        used.set(w.corner, used.get(w.corner) + s.h);
    }
    var corner = want;
    var tries: u8 = 0;
    while (tries < 4) : ({
        corner = corner.next();
        tries += 1;
    }) {
        if (used.get(corner) + sz.h <= max_stack) return corner;
    }
    return null;
}

pub fn placedOf(placed: []const Placed, id: u32) ?Placed {
    for (placed) |p| if (p.id == id) return p;
    return null;
}

/// Where a drop at `(x, y)` would put widget `id`: the corner of the
/// widget whose centre is within `snap_cells` (and the slot beside it),
/// else the quadrant of the body the pointer is in.
pub const Drop = struct { corner: Corner, before: ?u32 = null, after: ?u32 = null };

pub fn dropTarget(st: *const State, placed: []const Placed, body: Rect, id: u32, x: u16, y: u16) Drop {
    for (placed) |p| {
        if (p.id == id or p.inline_strip) continue;
        const cx = p.rect.x + p.rect.w / 2;
        const cy = p.rect.y + p.rect.h / 2;
        const dx = if (x > cx) x - cx else cx - x;
        const dy = if (y > cy) y - cy else cy - y;
        if (dx <= snap_cells and dy <= snap_cells) {
            const other = st.widgets.items[st.indexOf(p.id).?];
            // Above the centre → the slot that paints above it. For a
            // bottom corner the list stacks upward, so "above" is AFTER
            // in the list; for a top corner it is BEFORE.
            const above = y < cy;
            const before = if (other.corner.isBottom()) !above else above;
            return .{ .corner = other.corner, .before = if (before) p.id else null, .after = if (before) null else p.id };
        }
    }
    const right = x >= body.x + body.w / 2;
    const bottom = y >= body.y + body.h / 2;
    return .{ .corner = if (bottom) (if (right) .bottom_right else .bottom_left) else (if (right) .top_right else .top_left) };
}

/// Apply a drop: the corner, and the slot beside the snapped widget. A
/// corner whose stack is full takes nothing: the widget parks in the
/// nearest corner with room and the toast says which; with no room
/// anywhere it stays where it was.
pub fn applyDrop(app: *App, id: u32, drop: Drop) Allocator.Error!void {
    const st = &app.dock;
    const from = st.indexOf(id) orelse return;
    var corner = drop.corner;
    const area = app.dock_area;
    if (area.w >= 12 and area.h >= 4) {
        const body = bodyAfterStrips(area, strips(area, st.widgets.items, st.hidden));
        if (cornerWithRoom(body, st.widgets.items, id, drop.corner)) |c| {
            if (c != drop.corner) app.toast("dock: {s} is full — parked {s}", .{ drop.corner.label(), c.label() });
            corner = c;
        } else {
            app.toast("dock: no corner has room for {s} — it stays {s}", .{ st.widgets.items[from].title, st.widgets.items[from].corner.label() });
            return;
        }
    }
    var w = st.widgets.orderedRemove(from);
    w.corner = corner;
    if (corner != drop.corner) {
        try st.widgets.append(app.gpa, w);
        app.needs_render = true;
        return;
    }
    if (drop.before orelse drop.after) |anchor| {
        const at = st.indexOf(anchor) orelse st.widgets.items.len;
        const slot = if (drop.before != null) at else at + 1;
        try st.widgets.insert(app.gpa, slot, w);
    } else {
        try st.widgets.append(app.gpa, w);
    }
    app.needs_render = true;
}

// ─── the tail worker (D1 + D3) ──────────────────────────────────────────

/// Every tick: a due tail starts its read; one read per widget at a time.
pub fn tick(app: *App, now: i64) void {
    const st = &app.dock;
    if (st.hidden) return;
    for (st.widgets.items) |*w| {
        const lt = switch (w.content) {
            .log_tail => |lt| lt,
            else => continue,
        };
        if (w.tail_busy or now - w.tail_at_ms < tail_ms) continue;
        w.tail_busy = true;
        w.tail_at_ms = now;
        st.group.concurrent(app.io, tailWorker, .{ app.events, app.io, app.gpa, lt.path, lt.max_lines, w.id, w.tail_generation }) catch {
            w.tail_busy = false;
        };
    }
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.dock;
    if (st.hidden) return null;
    var next: ?i64 = null;
    for (st.widgets.items) |w| switch (w.content) {
        .log_tail => next = @min(next orelse std.math.maxInt(i64), w.tail_at_ms + tail_ms),
        .clock => next = @min(next orelse std.math.maxInt(i64), app.now_ms + 1000),
        else => {},
    };
    return next;
}

fn tailWorker(events: *event.EventQueue, io: Io, gpa: Allocator, path: []const u8, max_lines: u16, id: u32, generation: u32) Io.Cancelable!void {
    const result = TailResult.create(gpa, id, generation) catch return;
    errdefer result.destroy(gpa);
    readTailInto(io, gpa, path, max_lines, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return,
    };
    events.post(io, .{ .dock = result });
}

const TailError = Io.Cancelable || Allocator.Error;

/// The last `max_lines` lines of the file's last `tail_cap` bytes.
pub fn readTailInto(io: Io, gpa: Allocator, path: []const u8, max_lines: u16, r: *TailResult) TailError!void {
    const arena = r.arena.allocator();
    const bytes = transcript.readTail(gpa, io, Io.Dir.cwd(), path, tail_cap) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            r.err = try std.fmt.allocPrint(arena, "{s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return;
        },
    };
    defer gpa.free(bytes);
    try io.checkCancel();
    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 and it.peek() == null) break;
        try all.append(arena, try arena.dupe(u8, line));
    }
    r.total = @intCast(all.items.len);
    const keep = @min(all.items.len, @as(usize, max_lines));
    r.lines = all.items[all.items.len - keep ..];
}

/// D1: `result` is adopted or freed here. A widget that changed its
/// path or went away meanwhile carries a newer generation.
pub fn handle(app: *App, result: *TailResult) Allocator.Error!void {
    defer result.destroy(app.gpa);
    const w = app.dock.find(result.id) orelse return;
    w.tail_busy = false;
    if (result.generation != w.tail_generation) return;
    const gpa = app.gpa;
    var fresh = try gpa.alloc([]u8, if (result.err) |_| 1 else result.lines.len);
    var filled: usize = 0;
    errdefer freeLines(gpa, fresh[0..filled]);
    if (result.err) |e| {
        fresh[0] = try gpa.dupe(u8, e);
        filled = 1;
    } else for (result.lines) |l| {
        fresh[filled] = try gpa.dupe(u8, l);
        filled += 1;
    }
    freeLines(gpa, w.tail_lines);
    w.tail_lines = fresh;
    w.tail_total = result.total;
    app.needs_render = true;
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

/// Paints every widget over `area` (the editor body, strips included)
/// and the drag ghost + landing preview while a title is being dragged.
/// Called after the panes, so the widgets overlay them.
pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.dock;
    app.dock_area = area;
    if (st.hidden or st.widgets.items.len == 0) return;
    const placed = try layout(ui.arena, area, st.widgets.items, st.hidden);
    for (placed) |p| {
        const w = st.find(p.id) orelse continue;
        const lines = try contentLines(app, ui.arena, w);
        _ = dock_view.draw(ui, .{
            .id = w.id,
            .rect = p.rect,
            .title = w.title,
            .lines = lines,
            .scroll = w.scroll,
            .anchor_end = w.content == .log_tail,
            .focused = st.focused == w.id,
            .opacity = w.opacity,
        });
    }
    if (app.drag) |d| if (d == .dock) if (st.drag_to) |to| {
        const w = st.find(d.dock.id) orelse return;
        const body = bodyAfterStrips(area, strips(area, st.widgets.items, st.hidden));
        const drop = dropTarget(st, placed, body, w.id, to.x, to.y);
        const sz = widgetSize(body, w.*);
        const landing = Rect.init(
            if (drop.corner.isRight()) body.right() -| sz.w else body.x,
            if (drop.corner.isBottom()) body.bottom() -| sz.h else body.y,
            sz.w,
            sz.h,
        );
        dock_view.drawDrag(ui, to.x, to.y, w.title, landing, drop.corner.label());
    };
}

// ─── content for the view ───────────────────────────────────────────────

/// The body's lines on the frame arena.
pub fn contentLines(app: *App, arena: Allocator, w: *const Widget) Allocator.Error![]const []const u8 {
    switch (w.content) {
        .text => |t| {
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, t, '\n');
            while (it.next()) |l| try lines.append(arena, l);
            return lines.toOwnedSlice(arena);
        },
        .log_tail => |lt| {
            if (w.tail_lines.len == 0) {
                const one = try arena.alloc([]const u8, 1);
                one[0] = try std.fmt.allocPrint(arena, "tailing {s}…", .{lt.path});
                return one;
            }
            const out = try arena.alloc([]const u8, w.tail_lines.len);
            for (w.tail_lines, 0..) |l, i| out[i] = l;
            return out;
        },
        .clock => {
            const secs = Io.Timestamp.now(app.io, .real).toSeconds();
            const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
            const day = es.getDaySeconds();
            const ymd = es.getEpochDay().calculateYearDay();
            const md = ymd.calculateMonthDay();
            const out = try arena.alloc([]const u8, 2);
            out[0] = try std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2} UTC", .{ day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
            out[1] = try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{ ymd.year, md.month.numeric(), md.day_index + 1 });
            return out;
        },
        .git_branch => {
            const out = try arena.alloc([]const u8, 2);
            out[0] = app.git.branchLabel() orelse "not a git repository";
            const n = app.git.badge();
            out[1] = if (app.git.branchLabel() == null) "" else if (n == 0) "clean" else try std.fmt.allocPrint(arena, "{d} changed", .{n});
            return out;
        },
    }
}

/// `blend(top, under)`: `top_pct` of the widget's ground over what was
/// painted underneath. Null unless both are rgb — an indexed or default
/// colour cannot be mixed, and the view then skips the ground instead.
pub fn blend(top: vaxis.Color, under: vaxis.Color, top_pct: u8) ?vaxis.Color {
    const a = switch (top) {
        .rgb => |c| c,
        else => return null,
    };
    const b = switch (under) {
        .rgb => |c| c,
        else => return null,
    };
    var out: [3]u8 = undefined;
    for (0..3) |i| {
        const mixed: u32 = (@as(u32, a[i]) * top_pct + @as(u32, b[i]) * (100 - @as(u32, top_pct))) / 100;
        out[i] = @intCast(mixed);
    }
    return .{ .rgb = out };
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn newTextBl(app: *App) CommandError!void {
    return promptNewText(app, .bottom_left);
}
fn newTextBr(app: *App) CommandError!void {
    return promptNewText(app, .bottom_right);
}
fn newTextTl(app: *App) CommandError!void {
    return promptNewText(app, .top_left);
}
fn newTextTr(app: *App) CommandError!void {
    return promptNewText(app, .top_right);
}

/// The note's text comes from a prompt; the widget lands on accept.
fn promptNewText(app: *App, corner: Corner) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Dock note"), .purpose = .{ .dock_new_text = corner } } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptNewText(app: *App, corner: Corner, text: []const u8) Allocator.Error!void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return;
    _ = try add(app, .{ .corner = corner, .title = "Note", .content = .{ .text = t } });
}

/// A prompt seeded with `.mnml/run.log`, relative to the workspace.
fn newLogTail(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Tail file (workspace-relative or absolute)"), .purpose = .{ .dock_new_log = .bottom_left } } };
    app.overlay.prompt.state.setText(app.gpa, default_log_rel) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptNewLog(app: *App, corner: Corner, text: []const u8) Allocator.Error!void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return;
    const abs = if (std.fs.path.isAbsolute(t)) t else try app.absPath(t);
    const title = try std.fmt.allocPrint(app.frame.allocator(), "Log: {s}", .{std.fs.path.basename(t)});
    _ = try add(app, .{ .corner = corner, .title = title, .content = .{ .log_tail = abs } });
}

fn closeAll(app: *App) CommandError!void {
    const st = &app.dock;
    if (st.widgets.items.len == 0) return app.diag.fail(app.frame.allocator(), "dock: nothing to close", .{});
    st.group.cancel(app.io);
    const n = st.widgets.items.len;
    for (st.widgets.items) |*w| w.deinit(app.gpa);
    st.widgets.clearRetainingCapacity();
    st.focused = null;
    app.needs_render = true;
    app.toast("closed {d} dock widget{s}", .{ n, if (n == 1) "" else "s" });
}

fn moveCornerNext(app: *App) CommandError!void {
    const w = app.dock.target() orelse return app.diag.fail(app.frame.allocator(), "dock: no widget", .{});
    const area = app.dock_area;
    const want = w.corner.next();
    w.corner = if (area.w >= 12 and area.h >= 4)
        cornerWithRoom(bodyAfterStrips(area, strips(area, app.dock.widgets.items, app.dock.hidden)), app.dock.widgets.items, w.id, want) orelse
            return app.diag.fail(app.frame.allocator(), "dock: no corner has room for {s}", .{w.title})
    else
        want;
    app.needs_render = true;
    app.toast("dock: {s}", .{w.corner.label()});
}

fn toggle(app: *App) CommandError!void {
    const st = &app.dock;
    if (st.widgets.items.len == 0) return app.diag.fail(app.frame.allocator(), "dock: no widgets — dock.new_text starts one", .{});
    st.hidden = !st.hidden;
    app.needs_render = true;
}

fn removeFocused(app: *App) CommandError!void {
    const w = app.dock.target() orelse return app.diag.fail(app.frame.allocator(), "dock: no widget", .{});
    remove(app, w.id);
}

/// `dock.add_preset`: a picker of the ready-made widgets.
const presets = [_]struct { label: []const u8, detail: []const u8 }{
    .{ .label = "Clock", .detail = "the time, ticking" },
    .{ .label = "Git branch", .detail = "the branch and how much is changed" },
    .{ .label = "Log tail", .detail = default_log_rel },
    .{ .label = "Text note…", .detail = "a few lines of your own" },
};

fn addPreset(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (presets) |p| {
        try labels.append(gpa, try gpa.dupe(u8, p.label));
        try details.append(gpa, try gpa.dupe(u8, p.detail));
    }
    try cmd_picker.openPickerWith(app, "Dock widget", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptPreset;
}

fn acceptPreset(app: *App, idx: usize, _: []const u8) Allocator.Error!void {
    switch (idx) {
        0 => _ = try add(app, .{ .corner = .top_right, .title = "Clock", .content = .clock, .size = .small }),
        1 => _ = try add(app, .{ .corner = .top_right, .title = "Branch", .content = .git_branch, .size = .small }),
        2 => try acceptNewLog(app, .bottom_left, default_log_rel),
        else => promptNewText(app, .bottom_left) catch {},
    }
}

/// `dock.edit`: the text of a note, the path of a tail.
fn editFocused(app: *App) CommandError!void {
    const w = app.dock.target() orelse return app.diag.fail(app.frame.allocator(), "dock: no widget", .{});
    const seed: []const u8, const title: []const u8 = switch (w.content) {
        .text => |t| .{ t, "Dock note text" },
        .log_tail => |lt| .{ lt.path, "Tail file" },
        .clock, .git_branch => return app.diag.fail(app.frame.allocator(), "dock: {s} has nothing to edit", .{w.title}),
    };
    const seed_copy = try app.frame.allocator().dupe(u8, seed);
    const id = w.id;
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .{ .dock_edit = id } } };
    app.overlay.prompt.state.setText(app.gpa, seed_copy) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptEdit(app: *App, id: u32, text: []const u8) Allocator.Error!void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const w = app.dock.find(id) orelse return;
    switch (w.content) {
        .text => |*old| {
            const fresh = try app.gpa.dupe(u8, t);
            app.gpa.free(old.*);
            old.* = fresh;
        },
        .log_tail => |*lt| {
            if (t.len == 0) return;
            const abs = if (std.fs.path.isAbsolute(t)) t else try app.absPath(t);
            const fresh = try app.gpa.dupe(u8, abs);
            // The worker may hold the old path: wait for it, then swap.
            app.dock.group.cancel(app.io);
            app.gpa.free(lt.path);
            lt.path = fresh;
            w.tail_generation +%= 1;
            w.tail_busy = false;
            w.tail_at_ms = 0;
            freeLines(app.gpa, w.tail_lines);
            w.tail_lines = &.{};
            w.tail_total = 0;
            const title = try std.fmt.allocPrint(app.gpa, "Log: {s}", .{std.fs.path.basename(t)});
            app.gpa.free(w.title);
            w.title = title;
        },
        .clock, .git_branch => {},
    }
    app.needs_render = true;
}

fn renameFocused(app: *App) CommandError!void {
    const w = app.dock.target() orelse return app.diag.fail(app.frame.allocator(), "dock: no widget", .{});
    const seed = try app.frame.allocator().dupe(u8, w.title);
    const id = w.id;
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Dock widget title"), .purpose = .{ .dock_rename = id } } };
    app.overlay.prompt.state.setText(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptRename(app: *App, id: u32, text: []const u8) Allocator.Error!void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return;
    const w = app.dock.find(id) orelse return;
    const fresh = try app.gpa.dupe(u8, t);
    app.gpa.free(w.title);
    w.title = fresh;
    app.needs_render = true;
}

/// A kebab row: size, corner, placement or opacity.
pub fn setSetting(app: *App, id: u32, setting: Setting) void {
    const w = app.dock.find(id) orelse return;
    switch (setting) {
        .size => |s| w.setSize(s),
        .corner => |c| w.corner = c,
        .placement => |p| w.placement = p,
        .opacity => |o| w.opacity = o,
    }
    app.dock.focused = id;
    app.needs_render = true;
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

/// A press on a widget: the title arms a drag, the close glyph closes,
/// the kebab (or a right press anywhere) opens the menu, the body
/// focuses; the wheel scrolls the body.
pub fn mouse(app: *App, id: u32, part: Part, m: Mouse) Allocator.Error!void {
    const st = &app.dock;
    const w = st.find(id) orelse return;
    switch (m.kind) {
        .press => {
            st.focused = id;
            app.needs_render = true;
            if (m.button == .right) return openMenu(app, id, m.x, m.y);
            if (m.button != .left) return;
            switch (part) {
                .close => remove(app, id),
                .kebab => try openMenu(app, id, m.x, m.y),
                .title => app.drag = .{ .dock = .{ .id = id, .x = m.x, .y = m.y } },
                .body => {},
            }
        },
        .scroll_up => w.scroll -|= 1,
        .scroll_down => w.scroll +|= 1,
        else => {},
    }
}

/// The drag in flight: the pointer moves the ghost; the release drops.
pub fn continueDrag(app: *App, d: *app_mod.DockDrag, m: Mouse) Allocator.Error!void {
    const st = &app.dock;
    if (m.kind == .drag) {
        if (d.x != m.x or d.y != m.y) d.moved = true;
        st.drag_to = .{ .x = m.x, .y = m.y };
        app.needs_render = true;
        return;
    }
    const id = d.id;
    const moved = d.moved;
    app.drag = null;
    st.drag_to = null;
    app.needs_render = true;
    if (!moved) return;
    const placed = try layout(app.frame.allocator(), app.dock_area, st.widgets.items, st.hidden);
    const body = bodyAfterStrips(app.dock_area, strips(app.dock_area, st.widgets.items, st.hidden));
    const drop = dropTarget(st, placed, body, id, m.x, m.y);
    try applyDrop(app, id, drop);
}

/// The kebab menu: sizes, corners, placement, opacity, then rename /
/// edit / close. The current values are ticked.
pub fn openMenu(app: *App, id: u32, x: u16, y: u16) Allocator.Error!void {
    const w = app.dock.find(id) orelse return;
    app.dock.focused = id;
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    const cur_size = Size.matching(w.w_pct, w.h_pct);
    for (Size.all, 0..) |s, i| try items.append(app.gpa, .{ .label = s.label(), .action = .{ .dock_set = .{ .id = id, .setting = .{ .size = s } } }, .checked = cur_size == s, .separator_before = i == 0 and false });
    for (Corner.all, 0..) |c, i| try items.append(app.gpa, .{ .label = c.label(), .action = .{ .dock_set = .{ .id = id, .setting = .{ .corner = c } } }, .checked = w.corner == c, .separator_before = i == 0 });
    try items.append(app.gpa, .{ .label = "Overlay", .action = .{ .dock_set = .{ .id = id, .setting = .{ .placement = .overlay } } }, .checked = w.placement == .overlay, .separator_before = true });
    try items.append(app.gpa, .{ .label = "Inline", .action = .{ .dock_set = .{ .id = id, .setting = .{ .placement = .@"inline" } } }, .checked = w.placement == .@"inline" });
    try items.append(app.gpa, .{ .label = "Solid", .action = .{ .dock_set = .{ .id = id, .setting = .{ .opacity = .solid } } }, .checked = w.opacity == .solid, .separator_before = true });
    try items.append(app.gpa, .{ .label = "Translucent", .action = .{ .dock_set = .{ .id = id, .setting = .{ .opacity = .translucent } } }, .checked = w.opacity == .translucent });
    try items.append(app.gpa, .{ .label = "Rename…", .action = .{ .command = .@"dock.rename" }, .separator_before = true });
    try items.append(app.gpa, .{ .label = "Edit…", .action = .{ .command = .@"dock.edit" } });
    try items.append(app.gpa, .{ .label = "Move to next corner", .action = .{ .command = .@"dock.move_corner_next" } });
    try items.append(app.gpa, .{ .label = "Close", .action = .{ .command = .@"dock.remove" }, .separator_before = true });
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu("Dock", owned, x, y);
}

// ─── persistence (session.zon) ──────────────────────────────────────────

pub const SavedKind = enum { text, log_tail, clock, git_branch };

pub const SavedWidget = struct {
    corner: Corner = .bottom_left,
    w_pct: u8 = 50,
    h_pct: u8 = 25,
    title: []const u8 = "",
    kind: SavedKind = .text,
    text: []const u8 = "",
    path: []const u8 = "",
    max_lines: u16 = default_max_lines,
    placement: Placement = .overlay,
    opacity: Opacity = .solid,
};

pub fn capture(app: *App, arena: Allocator) Allocator.Error![]const SavedWidget {
    const out = try arena.alloc(SavedWidget, app.dock.widgets.items.len);
    for (app.dock.widgets.items, 0..) |w, i| out[i] = .{
        .corner = w.corner,
        .w_pct = w.w_pct,
        .h_pct = w.h_pct,
        .title = w.title,
        .kind = w.content.kind(),
        .text = switch (w.content) {
            .text => |t| t,
            else => "",
        },
        .path = switch (w.content) {
            .log_tail => |lt| lt.path,
            else => "",
        },
        .max_lines = switch (w.content) {
            .log_tail => |lt| lt.max_lines,
            else => default_max_lines,
        },
        .placement = w.placement,
        .opacity = w.opacity,
    };
    return out;
}

/// Replace the widgets with the file's. A saved tail keeps its path
/// verbatim (it was absolute when saved).
pub fn apply(app: *App, saved: []const SavedWidget, hidden: bool) Allocator.Error!void {
    const st = &app.dock;
    st.group.cancel(app.io);
    for (st.widgets.items) |*w| w.deinit(app.gpa);
    st.widgets.clearRetainingCapacity();
    st.focused = null;
    for (saved) |s| {
        const id = try add(app, .{
            .corner = s.corner,
            .title = if (s.title.len > 0) s.title else "Note",
            .content = switch (s.kind) {
                .text => .{ .text = s.text },
                .log_tail => .{ .log_tail = s.path },
                .clock => .clock,
                .git_branch => .git_branch,
            },
            .placement = s.placement,
            .opacity = s.opacity,
        });
        const w = st.find(id).?;
        w.w_pct = std.math.clamp(s.w_pct, types.min_pct, types.max_pct);
        w.h_pct = std.math.clamp(s.h_pct, types.min_pct, types.max_pct);
        if (w.content == .log_tail) w.content.log_tail.max_lines = @max(s.max_lines, 1);
    }
    st.focused = null;
    st.hidden = hidden;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mk(id: u32, corner: Corner, size: Size, placement: Placement) Widget {
    const p = size.pct();
    return .{ .id = id, .corner = corner, .w_pct = p.w, .h_pct = p.h, .title = @constCast("t"), .content = .clock, .placement = placement };
}

test "layout: four corners anchor, a corner stacks inward, the stack stops at half the body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const area = Rect.init(10, 5, 100, 40);
    // Medium = 50 × 25 % → 50 × 10.
    const ws = [_]Widget{ mk(1, .bottom_left, .medium, .overlay), mk(2, .bottom_right, .medium, .overlay), mk(3, .top_left, .medium, .overlay), mk(4, .top_right, .medium, .overlay) };
    const placed = try layout(arena, area, &ws, false);
    try testing.expectEqual(@as(usize, 4), placed.len);
    try testing.expect(placedOf(placed, 1).?.rect.eql(Rect.init(10, 35, 50, 10)));
    try testing.expect(placedOf(placed, 2).?.rect.eql(Rect.init(60, 35, 50, 10)));
    try testing.expect(placedOf(placed, 3).?.rect.eql(Rect.init(10, 5, 50, 10)));
    try testing.expect(placedOf(placed, 4).?.rect.eql(Rect.init(60, 5, 50, 10)));
    // Three mediums in one bottom corner: 10 + 10 fit under the 20-row
    // cap; the third overflows clockwise to the next corner with room
    // (top-left) instead of vanishing. The first sits at the very bottom.
    const stack = [_]Widget{ mk(1, .bottom_left, .medium, .overlay), mk(2, .bottom_left, .medium, .overlay), mk(3, .bottom_left, .medium, .overlay) };
    const p2 = try layout(arena, area, &stack, false);
    try testing.expectEqual(@as(usize, 3), p2.len);
    try testing.expectEqual(@as(u16, 35), placedOf(p2, 1).?.rect.y);
    try testing.expectEqual(@as(u16, 25), placedOf(p2, 2).?.rect.y);
    try testing.expect(placedOf(p2, 3).?.rect.eql(Rect.init(10, 5, 50, 10)));
    // Every corner full: the fifth has nowhere to go and is the only one unplaced.
    const full = [_]Widget{ mk(1, .bottom_left, .medium, .overlay), mk(2, .bottom_left, .medium, .overlay), mk(3, .bottom_right, .medium, .overlay), mk(4, .bottom_right, .medium, .overlay), mk(5, .top_left, .medium, .overlay), mk(6, .top_left, .medium, .overlay), mk(7, .top_right, .medium, .overlay), mk(8, .top_right, .medium, .overlay), mk(9, .bottom_left, .medium, .overlay) };
    const p4 = try layout(arena, area, &full, false);
    try testing.expectEqual(@as(usize, 8), p4.len);
    try testing.expect(placedOf(p4, 9) == null);
    try testing.expectEqual(Corner.top_left, cornerWithRoom(area, &stack, 3, .bottom_left).?);
    try testing.expectEqual(Corner.bottom_left, cornerWithRoom(area, stack[0..2], 2, .bottom_left).?);
    try testing.expect(cornerWithRoom(area, &full, 9, .bottom_left) == null);
    // Top corners stack downward.
    const top = [_]Widget{ mk(1, .top_right, .small, .overlay), mk(2, .top_right, .small, .overlay) };
    const p3 = try layout(arena, area, &top, false);
    try testing.expectEqual(@as(u16, 5), placedOf(p3, 1).?.rect.y);
    try testing.expectEqual(@as(u16, 11), placedOf(p3, 2).?.rect.y); // small: 25 × 15 % → 25 × 6
    try testing.expectEqual(@as(u16, 85), placedOf(p3, 2).?.rect.x);
    // Hidden: nothing.
    try testing.expectEqual(@as(usize, 0), (try layout(arena, area, &ws, true)).len);
    // Too small to paint: nothing, no panic.
    try testing.expectEqual(@as(usize, 0), (try layout(arena, Rect.init(0, 0, 11, 3), &ws, false)).len);
}

test "layout: inline widgets claim strips capped at a quarter each, tile the strip, and the body shrinks around them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const area = Rect.init(0, 0, 80, 40);
    // Tall = 50 % → 20 rows, capped to 10; two at the bottom tile 40 + 40.
    const ws = [_]Widget{ mk(1, .bottom_left, .tall, .@"inline"), mk(2, .bottom_right, .medium, .@"inline"), mk(3, .top_left, .small, .@"inline"), mk(4, .top_left, .medium, .overlay) };
    const s = strips(area, &ws, false);
    try testing.expectEqual(@as(u16, 10), s.bottom);
    try testing.expectEqual(@as(u16, 6), s.top);
    const body = bodyAfterStrips(area, s);
    try testing.expect(body.eql(Rect.init(0, 6, 80, 24)));
    const placed = try layout(arena, area, &ws, false);
    try testing.expectEqual(@as(usize, 4), placed.len);
    try testing.expect(placedOf(placed, 1).?.rect.eql(Rect.init(0, 30, 40, 10)));
    try testing.expect(placedOf(placed, 2).?.rect.eql(Rect.init(40, 30, 40, 10)));
    try testing.expect(placedOf(placed, 1).?.inline_strip);
    try testing.expect(placedOf(placed, 3).?.rect.eql(Rect.init(0, 0, 80, 6)));
    // The overlay widget anchors to the shrunken body, not the strip.
    try testing.expectEqual(@as(u16, 6), placedOf(placed, 4).?.rect.y);
    try testing.expect(!placedOf(placed, 4).?.inline_strip);
    // Hidden releases the strips.
    try testing.expectEqual(@as(u16, 0), strips(area, &ws, true).bottom);
}

test "dropTarget: a drop near another widget's centre snaps to its corner beside it; elsewhere the quadrant decides" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st: State = .{};
    defer st.deinit(testing.allocator, testing.io);
    try st.widgets.append(testing.allocator, mk(1, .bottom_left, .medium, .overlay));
    try st.widgets.append(testing.allocator, mk(2, .top_right, .medium, .overlay));
    // The test widgets hold a literal title; keep deinit from freeing it.
    defer for (st.widgets.items) |*x| {
        x.title = &.{};
    };
    const area = Rect.init(0, 0, 100, 40);
    const placed = try layout(arena, area, st.widgets.items, false);
    // Widget 2 paints at (50, 0, 50, 10): centre (75, 5). Drop widget 1
    // at (70, 3): within 8 cells, above the centre → for a top corner
    // "above" is the slot BEFORE it.
    const near = dropTarget(&st, placed, area, 1, 70, 3);
    try testing.expectEqual(Corner.top_right, near.corner);
    try testing.expectEqual(@as(?u32, 2), near.before);
    // Below the centre → after.
    const below = dropTarget(&st, placed, area, 1, 78, 9);
    try testing.expectEqual(@as(?u32, 2), below.after);
    try testing.expect(below.before == null);
    // Far from everything: the quadrant.
    try testing.expectEqual(Corner.bottom_right, dropTarget(&st, placed, area, 1, 90, 35).corner);
    try testing.expectEqual(Corner.top_left, dropTarget(&st, placed, area, 2, 3, 3).corner);
    try testing.expect(dropTarget(&st, placed, area, 2, 3, 3).before == null);
}

test "blend mixes rgb grounds and refuses anything else" {
    const mixed = blend(.{ .rgb = .{ 100, 100, 100 } }, .{ .rgb = .{ 0, 0, 0 } }, 50).?;
    try testing.expectEqualSlices(u8, &.{ 50, 50, 50 }, &mixed.rgb);
    const forty = blend(.{ .rgb = .{ 100, 0, 200 } }, .{ .rgb = .{ 0, 100, 100 } }, 40).?;
    try testing.expectEqualSlices(u8, &.{ 40, 60, 140 }, &forty.rgb);
    try testing.expect(blend(.default, .{ .rgb = .{ 1, 2, 3 } }, 50) == null);
    try testing.expect(blend(.{ .rgb = .{ 1, 2, 3 } }, .{ .index = 4 }, 50) == null);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    fn init(cols: u16, rows: u16) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = cols, .rows = rows });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }

    /// Tick until no tail is busy (or `max` ticks pass). The clock does
    /// not move: the tests drive `now_ms` themselves, and a wall-clock
    /// tick here would start the next read on a different timeline.
    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            var busy = false;
            for (f.app.dock.widgets.items) |x| if (x.tail_busy) {
                busy = true;
            };
            if (!busy) return;
            try f.app.tick(f.app.now_ms);
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
};

test "a text widget paints in its corner over the editor with its title, kebab and close; the hits name the parts; close removes it" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    f.app.tree.visible = false;
    _ = try add(&f.app, .{ .corner = .bottom_left, .title = "Note", .content = .{ .text = "remember the milk\nand eggs" } });
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "Note") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "remember the milk") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "and eggs") != null);
    var title: ?Rect = null;
    var close: ?Rect = null;
    var kebab: ?Rect = null;
    var body: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .dock) switch (h.target.dock.part) {
        .title => title = h.rect,
        .close => close = h.rect,
        .kebab => kebab = h.rect,
        .body => body = h.rect,
    };
    try testing.expect(title != null and close != null and kebab != null and body != null);
    // The widget sits at the bottom-left of the body: below the tab strip, on the left edge.
    try testing.expectEqual(f.app.panes_area.x, body.?.x);
    try testing.expectEqual(f.app.panes_area.bottom(), body.?.bottom());
    // The kebab opens the menu with the current values ticked.
    try f.app.handle(.{ .mouse = .{ .x = kebab.?.x, .y = kebab.?.y, .kind = .press, .button = .left } });
    try testing.expect(f.app.overlay == .menu);
    var ticked: usize = 0;
    for (f.app.overlay.menu.items) |it| if (it.checked) {
        ticked += 1;
    };
    try testing.expectEqual(@as(usize, 4), ticked); // Medium, Bottom-left, Overlay, Solid
    try f.app.handle(.{ .key = key_mod.Key.named(.esc) });
    // Close.
    try f.app.handle(.{ .mouse = .{ .x = close.?.x, .y = close.?.y, .kind = .press, .button = .left } });
    try testing.expectEqual(@as(usize, 0), f.app.dock.widgets.items.len);
}

test "the title drags: a release far away lands in that quadrant, a release near another widget snaps beside it" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    f.app.tree.visible = false;
    const a = try add(&f.app, .{ .corner = .bottom_left, .title = "A", .content = .{ .text = "a" } });
    const b = try add(&f.app, .{ .corner = .top_right, .title = "B", .content = .{ .text = "b" } });
    try f.app.render();
    var title_a: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .dock and h.target.dock.id == a and h.target.dock.part == .title) {
        title_a = h.rect;
    };
    try testing.expect(title_a != null);
    const body = f.app.panes_area;
    // Press, drag to the bottom-right quadrant, release.
    try f.app.handle(.{ .mouse = .{ .x = title_a.?.x + 1, .y = title_a.?.y, .kind = .press, .button = .left } });
    try testing.expect(f.app.drag != null and f.app.drag.? == .dock);
    try f.app.handle(.{ .mouse = .{ .x = body.right() - 5, .y = body.bottom() - 2, .kind = .drag, .button = .left } });
    try testing.expect(f.app.dock.drag_to != null);
    try f.app.handle(.{ .mouse = .{ .x = body.right() - 5, .y = body.bottom() - 2, .kind = .release, .button = .left } });
    try testing.expect(f.app.drag == null);
    try testing.expectEqual(Corner.bottom_right, f.app.dock.find(a).?.corner);
    // Drag A onto B's centre: A joins the top-right corner beside B.
    try f.app.render();
    var placed_b: ?Rect = null;
    var title_a2: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .dock) {
        if (h.target.dock.id == b and h.target.dock.part == .body) placed_b = h.rect;
        if (h.target.dock.id == a and h.target.dock.part == .title) title_a2 = h.rect;
    };
    const cx = placed_b.?.x + placed_b.?.w / 2;
    const cy = placed_b.?.y + placed_b.?.h / 2;
    try f.app.handle(.{ .mouse = .{ .x = title_a2.?.x + 1, .y = title_a2.?.y, .kind = .press, .button = .left } });
    try f.app.handle(.{ .mouse = .{ .x = cx, .y = cy + 2, .kind = .drag, .button = .left } });
    try f.app.handle(.{ .mouse = .{ .x = cx, .y = cy + 2, .kind = .release, .button = .left } });
    try testing.expectEqual(Corner.top_right, f.app.dock.find(a).?.corner);
    // Below B's centre in a top corner: A stacks after B.
    try testing.expectEqual(@as(usize, 0), f.app.dock.indexOf(b).?);
    try testing.expectEqual(@as(usize, 1), f.app.dock.indexOf(a).?);
    // A press-and-release without motion is not a drop.
    try f.app.render();
    try f.app.handle(.{ .mouse = .{ .x = title_a2.?.x + 1, .y = title_a2.?.y, .kind = .press, .button = .left } });
    try f.app.handle(.{ .mouse = .{ .x = title_a2.?.x + 1, .y = title_a2.?.y, .kind = .release, .button = .left } });
    try testing.expectEqual(Corner.top_right, f.app.dock.find(a).?.corner);
}

test "a drop on a corner whose stack is full parks the widget in the next corner with room, toasts, and keeps it painted" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    f.app.tree.visible = false;
    const a = try add(&f.app, .{ .corner = .bottom_left, .title = "A", .content = .{ .text = "a" } });
    const b = try add(&f.app, .{ .corner = .bottom_left, .title = "B", .content = .{ .text = "b" } });
    const c = try add(&f.app, .{ .corner = .top_right, .title = "Clock", .content = .clock, .size = .small });
    try f.app.render();
    // Two mediums fill the bottom-left cap; the drop parks the Clock in
    // the next corner clockwise with room, top-left, and says so.
    try applyDrop(&f.app, c, .{ .corner = .bottom_left });
    try testing.expectEqual(Corner.top_left, f.app.dock.find(c).?.corner);
    try testing.expect(std.mem.indexOf(u8, f.app.toasts.items[f.app.toasts.items.len - 1].text, "Bottom-left is full — parked Top-left") != null);
    try f.app.render();
    var painted = false;
    for (f.app.hits.items.items) |h| if (h.target == .dock and h.target.dock.id == c) {
        painted = true;
    };
    try testing.expect(painted);
    _ = a;
    _ = b;
}

test "a log tail reads the file's last lines on the worker, the title says how many more there are, and an edit re-points it" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    f.app.tree.visible = false;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..80) |i| try text.print(testing.allocator, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "run.log", .data = text.items });
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "run.log" });
    defer testing.allocator.free(abs);
    const id = try add(&f.app, .{ .corner = .bottom_left, .title = "Log: run.log", .content = .{ .log_tail = abs } });
    f.app.now_ms = 10_000;
    tick(&f.app, 10_000);
    try testing.expect(f.app.dock.find(id).?.tail_busy);
    try f.settle(2000);
    const wd = f.app.dock.find(id).?;
    try testing.expectEqual(@as(usize, 50), wd.tail_lines.len);
    try testing.expectEqual(@as(u32, 80), wd.tail_total);
    try testing.expectEqualStrings("line 79", wd.tail_lines[49]);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "line 79") != null);
    // The body shows the END of the tail, and the chip counts what is above.
    try testing.expect(std.mem.indexOf(u8, txt, "▼") != null);
    // Not due again yet; due after tail_ms.
    f.app.now_ms = 10_500;
    tick(&f.app, 10_500);
    try testing.expect(!wd.tail_busy);
    f.app.now_ms = 11_100;
    tick(&f.app, 11_100);
    try testing.expect(wd.tail_busy);
    try f.settle(2000);
    // A missing file says so instead of going blank.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "other.log", .data = "only one\n" });
    try acceptEdit(&f.app, id, "other.log");
    try testing.expectEqualStrings("Log: other.log", f.app.dock.find(id).?.title);
    try testing.expectEqual(@as(usize, 0), f.app.dock.find(id).?.tail_lines.len);
    f.app.now_ms = 20_000;
    tick(&f.app, 20_000);
    try f.settle(2000);
    try testing.expectEqualStrings("only one", f.app.dock.find(id).?.tail_lines[0]);
    try acceptEdit(&f.app, id, "/nonexistent/nowhere.log");
    f.app.now_ms = 30_000;
    tick(&f.app, 30_000);
    try f.settle(2000);
    try testing.expect(std.mem.indexOf(u8, f.app.dock.find(id).?.tail_lines[0], "nowhere.log") != null);
}

test "a translucent widget keeps the editor's text under its body; a solid one covers it" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    f.app.tree.visible = false;
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "x.txt", .data = "0123456789012345678901234567890123456789\n" ** 20 });
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "x.txt" });
    defer testing.allocator.free(abs);
    _ = try f.app.openPath(abs);
    const id = try add(&f.app, .{ .corner = .top_left, .title = "T", .content = .{ .text = "hi" }, .size = .large, .opacity = .translucent });
    try f.app.render();
    var body: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .dock and h.target.dock.part == .body) {
        body = h.rect;
    };
    // A cell on the body's last row, past the widget's own text.
    const probe_x = body.?.x + body.?.w - 2;
    const probe_y = body.?.bottom() - 1;
    const under = f.app.screen.readCell(probe_x, probe_y).?;
    try testing.expect(under.char.grapheme.len > 0 and std.ascii.isDigit(under.char.grapheme[0]));
    f.app.dock.find(id).?.opacity = .solid;
    try f.app.render();
    const covered = f.app.screen.readCell(probe_x, probe_y).?;
    try testing.expectEqualStrings(" ", covered.char.grapheme);
}

test "session round-trip: widgets, corners, sizes, placement, opacity and the hidden flag come back" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    const session = @import("session.zig");
    _ = try add(&f.app, .{ .corner = .top_right, .title = "Clock", .content = .clock, .size = .small, .placement = .@"inline" });
    const n = try add(&f.app, .{ .corner = .bottom_left, .title = "Note", .content = .{ .text = "two\nlines" }, .opacity = .translucent });
    f.app.dock.find(n).?.setSize(.wide);
    _ = try add(&f.app, .{ .corner = .bottom_right, .title = "Log: a.log", .content = .{ .log_tail = "/tmp/a.log" } });
    f.app.dock.hidden = true;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = try session.capture(&f.app, arena);
    try testing.expectEqual(@as(usize, 3), saved.dock.len);
    const text = try session.render(arena, saved);
    const back = try session.parse(arena, try arena.dupeZ(u8, text));
    var g = try Fixture.init(80, 24);
    defer g.deinit();
    try session.apply(&g.app, arena, back);
    const ws = g.app.dock.widgets.items;
    try testing.expectEqual(@as(usize, 3), ws.len);
    try testing.expectEqualStrings("Clock", ws[0].title);
    try testing.expect(ws[0].content == .clock);
    try testing.expectEqual(Placement.@"inline", ws[0].placement);
    try testing.expectEqual(Corner.top_right, ws[0].corner);
    try testing.expectEqualStrings("two\nlines", ws[1].content.text);
    try testing.expectEqual(Opacity.translucent, ws[1].opacity);
    try testing.expectEqual(Size.wide, Size.matching(ws[1].w_pct, ws[1].h_pct).?);
    try testing.expectEqualStrings("/tmp/a.log", ws[2].content.log_tail.path);
    try testing.expectEqual(default_max_lines, ws[2].content.log_tail.max_lines);
    try testing.expect(g.app.dock.hidden);
    try testing.expectEqual(@as(u32, 4), g.app.dock.next_id);
}

test "commands: new_text lands through the prompt, toggle hides and shows, move_corner_next cycles, close_all empties and then fails honestly" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"dock.new_text_tr" });
    try testing.expect(f.app.overlay == .prompt);
    for ("hello dock") |c| try f.app.handle(.{ .key = key_mod.Key.char(c) });
    try f.app.handle(.{ .key = key_mod.Key.named(.enter) });
    try testing.expectEqual(@as(usize, 1), f.app.dock.widgets.items.len);
    try testing.expectEqual(Corner.top_right, f.app.dock.widgets.items[0].corner);
    try testing.expectEqualStrings("hello dock", f.app.dock.widgets.items[0].content.text);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "hello dock") != null);
    try command.run(&f.app, .{ .static = .@"dock.toggle" });
    try testing.expect(f.app.dock.hidden);
    const hidden = try f.screen();
    defer testing.allocator.free(hidden);
    try testing.expect(std.mem.indexOf(u8, hidden, "hello dock") == null);
    try command.run(&f.app, .{ .static = .@"dock.toggle" });
    try command.run(&f.app, .{ .static = .@"dock.move_corner_next" });
    try testing.expectEqual(Corner.bottom_right, f.app.dock.widgets.items[0].corner);
    try command.run(&f.app, .{ .static = .@"dock.rename" });
    // The prompt is seeded with the current title ("Note").
    for (0..4) |_| try f.app.handle(.{ .key = key_mod.Key.named(.backspace) });
    for ("Shopping") |c| try f.app.handle(.{ .key = key_mod.Key.char(c) });
    try f.app.handle(.{ .key = key_mod.Key.named(.enter) });
    try testing.expectEqualStrings("Shopping", f.app.dock.widgets.items[0].title);
    try command.run(&f.app, .{ .static = .@"dock.close_all" });
    try testing.expectEqual(@as(usize, 0), f.app.dock.widgets.items.len);
    try testing.expectError(error.Failed, command.run(&f.app, .{ .static = .@"dock.close_all" }));
    try testing.expectEqualStrings("dock: nothing to close", f.app.lastToast().?);
    // The preset picker: the clock lands top-right, small.
    try command.run(&f.app, .{ .static = .@"dock.add_preset" });
    try testing.expect(f.app.overlay == .picker);
    try f.app.handle(.{ .key = key_mod.Key.named(.enter) });
    try testing.expectEqual(@as(usize, 1), f.app.dock.widgets.items.len);
    try testing.expect(f.app.dock.widgets.items[0].content == .clock);
    try testing.expectEqual(Size.small, Size.matching(f.app.dock.widgets.items[0].w_pct, f.app.dock.widgets.items[0].h_pct).?);
    const clock = try f.screen();
    defer testing.allocator.free(clock);
    try testing.expect(std.mem.indexOf(u8, clock, "UTC") != null);
}
