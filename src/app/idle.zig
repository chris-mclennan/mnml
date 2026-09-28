//! The tick's idle hooks (D10.2). Two moments a script wants that no
//! key produces: the cursor has stopped somewhere, and the buffer has
//! stopped changing. Both are debounced here rather than at every
//! mutation site — the tick already runs between events, and a hook is
//! UI-thread only.
//!
//! `cursor_idle` is what a blame line, a context lookup or a hover-like
//! decoration hangs off: it fires once, `cursor_idle_ms` after the
//! cursor last moved, and not again until it moves. `buffer_change`
//! fires `buffer_change_ms` after the last edit — the hook
//! `docs/LUA.md` has always documented — for the pane whose document
//! was edited, whichever pane has focus by then. Its debounce is kept
//! per pane (`EditorPane.change_*`): one head compared against the
//! ACTIVE pane's used to fire on every focus switch with no edit at
//! all, and to report an edit against the pane focus moved to.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const hooks = @import("../core/hooks.zig");
const line_blame = @import("line_blame.zig");

/// How long the cursor must sit still before `cursor_idle`.
pub const cursor_idle_ms: i64 = 300;
/// How long the buffer must be quiet before `buffer_change`.
pub const buffer_change_ms: i64 = 150;

pub const State = struct {
    /// Where the cursor was last seen, and when it got there.
    pane: ?PaneId = null,
    byte: usize = 0,
    moved_at_ms: i64 = 0,
    /// `cursor_idle` has fired for this resting place.
    cursor_fired: bool = true,
};

/// Both debounces, from `App.tick`.
pub fn tick(app: *App, now: i64) void {
    const st = &app.idle;
    changes(app, now);
    // Read after: a `buffer_change` hook may have moved the focus.
    const pane = app.active;
    const e = if (pane) |p| app.panes.editor(p) else null;
    if (e == null or pane == null) {
        st.pane = null;
        st.cursor_fired = true;
        return;
    }
    const ed = e.?.buf.editor;
    const cursor = ed.cursor;
    if (st.pane != pane.? or st.byte != cursor) {
        st.pane = pane.?;
        st.byte = cursor;
        st.moved_at_ms = now;
        st.cursor_fired = false;
    } else if (!st.cursor_fired and now - st.moved_at_ms >= cursor_idle_ms) {
        st.cursor_fired = true;
        app.hooks.emit(app, .{ .cursor_idle = .{ .pane = pane.?, .line = @intCast(ed.currentLine() + 1) } });
        line_blame.onCursorIdle(app, pane.?);
    }
}

/// `buffer_change`, pane by pane: a pane whose document's edit-log head
/// moved is pending; `buffer_change_ms` after the last move it fires,
/// naming that pane. Two panes on one document are one edit: it fires
/// once, naming the focused one of them when one has focus, and the
/// others are settled with it. By index, re-fetched: a hook may open or
/// close panes.
fn changes(app: *App, now: i64) void {
    var i: usize = 0;
    while (i < app.panes.slots.items.len) : (i += 1) {
        const id: PaneId = @intCast(i);
        const e = app.panes.editor(id) orelse continue;
        const head = e.buf.doc.edits.head();
        const seen = e.change_seen orelse {
            e.change_seen = head;
            continue;
        };
        if (seen != head) {
            e.change_seen = head;
            e.change_at_ms = now;
            e.change_pending = true;
            // What the current-line blame cached for this file answers
            // for text that is gone.
            line_blame.dropStale(app, id);
            continue;
        }
        if (!e.change_pending or now - e.change_at_ms < buffer_change_ms) continue;
        const doc = e.buf.doc;
        var named = id;
        if (app.active) |a| if (app.panes.editor(a)) |ae| if (ae.buf.doc == doc) {
            named = a;
        };
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*other| if (other.buf.doc == doc) {
                other.change_pending = false;
                other.change_seen = head;
            },
            else => {},
        };
        const lines: u32 = @intCast(app.panes.editor(named).?.buf.editor.lineCount());
        app.hooks.emit(app, .{ .buffer_change = .{ .pane = named, .line_count = lines } });
    }
}

/// When the loop must come back for one of the two.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.idle;
    var next: ?i64 = null;
    if (!st.cursor_fired) next = st.moved_at_ms + cursor_idle_ms;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*e| if (e.change_pending) {
            next = @min(next orelse std.math.maxInt(i64), e.change_at_ms + buffer_change_ms);
        },
        else => {},
    };
    return next;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "cursor_idle fires once the cursor rests, again only after it moves; buffer_change follows an edit" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    _ = try app.openScratchWith("one\ntwo\nthree\n");
    try lua.runString(
        \\idles = 0
        \\changes = 0
        \\mnml.on("cursor_idle", function(a) idles = idles + 1; at = a.line; pane = a.pane end)
        \\mnml.on("buffer_change", function(a) changes = changes + 1; lines = a.line_count end)
    );
    const e = app.activeEditor().?;
    e.buf.editor.setCursor(4); // line 2
    var now = app.now_ms;
    tick(&app, now);
    try lua.runString("assert(idles == 0, 'fired too early')");
    // Not yet: the debounce has not elapsed.
    now += cursor_idle_ms - 1;
    tick(&app, now);
    try lua.runString("assert(idles == 0, 'fired before the debounce')");
    now += 2;
    tick(&app, now);
    try lua.runString("assert(idles == 1 and at == 2, 'line ' .. tostring(at))");
    // Resting longer does not fire it again.
    now += 10 * cursor_idle_ms;
    tick(&app, now);
    try lua.runString("assert(idles == 1, 'fired twice for one rest')");
    // Moving arms it again.
    e.buf.editor.setCursor(0);
    tick(&app, now);
    now += cursor_idle_ms;
    tick(&app, now);
    try lua.runString("assert(idles == 2 and at == 1, tostring(at))");
    // An edit fires buffer_change once, after its own debounce.
    _ = try app.applyOps(e, &.{.{ .insert_str = "x\n" }});
    tick(&app, now);
    try lua.runString("assert(changes == 0)");
    now += buffer_change_ms;
    tick(&app, now);
    try lua.runString("assert(changes == 1 and lines == 4, tostring(lines))");
    now += 10 * buffer_change_ms;
    tick(&app, now);
    try lua.runString("assert(changes == 1)");
}

test "buffer_change is per pane: a focus switch is not an edit, and an edit is reported for the pane that was edited" {
    // One edit-log head was compared against whichever pane was active:
    // switching between two unedited panes fired the hook each time, and
    // an edit followed by a switch inside the debounce was reported once,
    // naming the pane focus moved to.
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const lua = app.script();
    const a = try app.openScratchWith("one\n");
    const b = try app.openScratchWith("two\nlines\n");
    try lua.runString(
        \\LOG = {}
        \\mnml.on("buffer_change", function(ev) LOG[#LOG + 1] = ev.pane .. ':' .. ev.line_count end)
    );
    var now = app.now_ms;
    tick(&app, now);
    // Focus back and forth, no edits: nothing.
    for (0..4) |k| {
        app.active = if (k % 2 == 0) a else b;
        now += 2 * buffer_change_ms;
        tick(&app, now);
    }
    try lua.runString("assert(#LOG == 0, table.concat(LOG, ','))");
    // Edit a, move to b inside the debounce: reported once, for a.
    app.active = a;
    tick(&app, now);
    _ = try app.applyOps(app.panes.editor(a).?, &.{.{ .insert_str = "x\n" }});
    tick(&app, now);
    app.active = b;
    tick(&app, now + 10);
    now += 2 * buffer_change_ms;
    tick(&app, now);
    const want = try std.fmt.allocPrint(testing.allocator, "assert(#LOG == 1 and LOG[1] == '{d}:2', table.concat(LOG, ','))", .{a});
    defer testing.allocator.free(want);
    try lua.runString(want);
    now += 10 * buffer_change_ms;
    tick(&app, now);
    try lua.runString("assert(#LOG == 1, table.concat(LOG, ','))");
}
