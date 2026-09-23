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
//! `docs/LUA.md` has always documented.

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
    /// The edit-log head last seen, and when it changed.
    seq: u64 = 0,
    edited_at_ms: i64 = 0,
    /// `buffer_change` has fired for this text.
    change_fired: bool = true,
};

/// Both debounces, from `App.tick`.
pub fn tick(app: *App, now: i64) void {
    const st = &app.idle;
    const pane = app.active;
    const e = if (pane) |p| app.panes.editor(p) else null;
    if (e == null or pane == null) {
        st.pane = null;
        st.cursor_fired = true;
        st.change_fired = true;
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
    const head = e.?.buf.doc.edits.head();
    if (st.seq != head) {
        st.seq = head;
        st.edited_at_ms = now;
        st.change_fired = false;
        line_blame.dropStale(app, pane.?);
    } else if (!st.change_fired and now - st.edited_at_ms >= buffer_change_ms) {
        st.change_fired = true;
        app.hooks.emit(app, .{ .buffer_change = .{ .pane = pane.?, .line_count = @intCast(ed.lineCount()) } });
    }
}

/// When the loop must come back for one of the two.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.idle;
    var next: ?i64 = null;
    if (!st.cursor_fired) next = st.moved_at_ms + cursor_idle_ms;
    if (!st.change_fired) next = @min(next orelse std.math.maxInt(i64), st.edited_at_ms + buffer_change_ms);
    return next;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "cursor_idle fires once the cursor rests, again only after it moves; buffer_change follows an edit" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
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
