//! The pane's state and every action that changes it. `ui.zig` paints
//! this and nothing else; `main.zig` is the mount loop that feeds it
//! keys and clicks.
//!
//! **A refresh is synchronous, and says so.** The mount loop blocks on
//! `mount.next`, so a worker thread finishing a fetch would have nothing
//! to wake the paint with. Instead `refresh` fetches on the loop and
//! calls `progress` between requests — the sink `main` installs paints
//! the frame and sends it, so the progress line moves while the pane is
//! busy. The pane does not answer keys during a refresh; the line says
//! what it is doing and how far along it is. A worker thread plus a
//! wake-up message is the shape to grow into, and the seam is here.
//!
//! **PRs are fetched when a ticket is opened, not for every ticket on
//! every refresh.** The Rust tracker auto-expands every unresolved
//! ticket and fetches its dev-status serially, which is the N+1 that
//! makes its rate limiter necessary; this one asks once, on expand, and
//! caches until the next refresh.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

const auth = @import("auth.zig");
const config = @import("config.zig");
const jira = @import("jira.zig");
const json = @import("json.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const os = @import("os.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");
const tree = @import("tree.zig");

pub const Action = keys.Action;
pub const Mode = keys.Mode;

/// A one-line text field with a cursor, in bytes. Used by the filter,
/// the comment box and every field of the create form — so every text
/// input in this pane gets arrows, home / end and word-delete from the
/// first day, rather than being append-only.
pub const Editor = struct {
    gpa: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Editor) void {
        e.buf.deinit(e.gpa);
        e.* = undefined;
    }

    pub fn text(e: *const Editor) []const u8 {
        return e.buf.items;
    }

    pub fn clear(e: *Editor) void {
        e.buf.clearRetainingCapacity();
        e.cursor = 0;
    }

    pub fn set(e: *Editor, s: []const u8) Allocator.Error!void {
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(e.gpa, s);
        e.cursor = e.buf.items.len;
    }

    pub fn insert(e: *Editor, cp: u21) Allocator.Error!void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        try e.buf.insertSlice(e.gpa, e.cursor, tmp[0..n]);
        e.cursor += n;
    }

    pub fn backspace(e: *Editor) void {
        if (e.cursor == 0) return;
        const start = prevBoundary(e.buf.items, e.cursor);
        e.buf.replaceRange(e.gpa, start, e.cursor - start, &.{}) catch return;
        e.cursor = start;
    }

    pub fn killToStart(e: *Editor) void {
        e.buf.replaceRange(e.gpa, 0, e.cursor, &.{}) catch return;
        e.cursor = 0;
    }

    pub fn killToEnd(e: *Editor) void {
        e.buf.shrinkRetainingCapacity(e.cursor);
    }

    pub fn deleteWordBack(e: *Editor) void {
        var i = e.cursor;
        while (i > 0 and isSpace(e.buf.items[i - 1])) i -= 1;
        while (i > 0 and !isSpace(e.buf.items[i - 1])) i -= 1;
        e.buf.replaceRange(e.gpa, i, e.cursor - i, &.{}) catch return;
        e.cursor = i;
    }

    pub fn left(e: *Editor) void {
        if (e.cursor == 0) return;
        e.cursor = prevBoundary(e.buf.items, e.cursor);
    }

    pub fn right(e: *Editor) void {
        if (e.cursor >= e.buf.items.len) return;
        e.cursor = nextBoundary(e.buf.items, e.cursor);
    }

    pub fn home(e: *Editor) void {
        e.cursor = 0;
    }

    pub fn end(e: *Editor) void {
        e.cursor = e.buf.items.len;
    }

    /// Apply one editing action. True when it was one.
    pub fn apply(e: *Editor, a: Action) Allocator.Error!bool {
        switch (a) {
            .insert => |cp| try e.insert(cp),
            .backspace => e.backspace(),
            .kill_to_start => e.killToStart(),
            .kill_to_end => e.killToEnd(),
            .delete_word_back => e.deleteWordBack(),
            .cursor_left => e.left(),
            .cursor_right => e.right(),
            .cursor_home => e.home(),
            .cursor_end => e.end(),
            .newline => try e.insert('\n'),
            else => return false,
        }
        return true;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    fn prevBoundary(s: []const u8, at: usize) usize {
        var i = at - 1;
        while (i > 0 and (s[i] & 0xc0) == 0x80) i -= 1;
        return i;
    }

    fn nextBoundary(s: []const u8, at: usize) usize {
        var i = at + 1;
        while (i < s.len and (s[i] & 0xc0) == 0x80) i += 1;
        return i;
    }
};

/// What a picker's Enter does.
pub const PickKind = enum { transition, assignee, fix_version, issue_type };

pub const PickItem = struct {
    /// What the action needs — a transition id, an accountId, a version
    /// name. May be empty, which is the `— none —` row.
    id: []const u8,
    label: []const u8,
};

pub const Picker = struct {
    kind: PickKind,
    /// The ticket this was opened on, pinned so a refresh cannot move it.
    key: []const u8,
    items: []const PickItem,
    cursor: usize = 0,
    filter: Editor,
    /// Set when the call that filled it failed.
    err: ?[]const u8 = null,

    /// The rows that survive the filter, as indices into `items`.
    pub fn visible(p: *const Picker, arena: Allocator) Allocator.Error![]const usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (p.items, 0..) |it, i| {
            if (text.containsIgnoreCase(it.label, p.filter.text())) try out.append(arena, i);
        }
        return out.toOwnedSlice(arena);
    }
};

/// What Enter on a confirm does.
pub const Pending = union(enum) {
    transition: struct { key: []const u8, id: []const u8, to: []const u8 },
};

pub const Confirm = struct {
    message: []const u8,
    what: Pending,
};

/// The create form's fields, in tab order.
pub const FormField = enum { project, issue_type, summary, description };

pub const Form = struct {
    fields: [4]Editor,
    focus: FormField = .summary,
    err: ?[]const u8 = null,

    pub fn get(f: *Form, which: FormField) *Editor {
        return &f.fields[@intFromEnum(which)];
    }

    pub fn next(f: *Form) void {
        const at: usize = @intFromEnum(f.focus);
        f.focus = @enumFromInt((at + 1) % f.fields.len);
    }

    pub fn prev(f: *Form) void {
        const at: usize = @intFromEnum(f.focus);
        f.focus = @enumFromInt((at + f.fields.len - 1) % f.fields.len);
    }
};

pub const Overlay = union(enum) {
    none,
    help: struct { scroll: u16 = 0 },
    filter: Editor,
    picker: Picker,
    comment: struct { key: []const u8, editor: Editor, err: ?[]const u8 = null, posting: bool = false },
    form: Form,
    confirm: Confirm,

    pub fn mode(o: Overlay) Mode {
        return switch (o) {
            .none => .list,
            .help => .help,
            .filter => .filter,
            .picker => .picker,
            .comment, .form => .prompt,
            .confirm => .confirm,
        };
    }
};

pub const Tab = struct {
    cfg: config.Tab,
    /// The JQL after `kind` and the fixVersion resolve. Owned by `arena`.
    jql: []const u8 = "",
    /// The version a release tab resolved to, for the header.
    version: []const u8 = "",
    issues: []model.Issue = &.{},
    rows: []const tree.Row = &.{},
    state: tree.State,
    cursor: usize = 0,
    scroll: usize = 0,
    filter: []const u8 = "",
    err: ?[]const u8 = null,
    fetched: bool = false,
    /// Everything this tab's last fetch allocated.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(t: *Tab) void {
        t.state.deinit();
        t.arena.deinit();
    }

    pub fn selected(t: *const Tab) ?*const model.Issue {
        if (t.rows.len == 0) return null;
        const at = @min(t.cursor, t.rows.len - 1);
        const i = t.rows[at].issueIndex() orelse return null;
        if (i >= t.issues.len) return null;
        return &t.issues[i];
    }

    pub fn selectedRow(t: *const Tab) ?tree.Row {
        if (t.rows.len == 0) return null;
        return t.rows[@min(t.cursor, t.rows.len - 1)];
    }
};

/// A repaint the app asks for mid-refresh.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    paint: ?*const fn (ctx: ?*anyopaque) void = null,

    pub fn call(s: Sink) void {
        if (s.paint) |f| f(s.ctx);
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    cfg: config.Config,
    cfg_path: []const u8,
    /// Why there is nothing to show: no config, a broken one, no token.
    blocked: ?[]const []const u8 = null,
    client: ?jira.Client = null,
    /// `accountId`, once `/myself` answered. A scoped token often cannot
    /// answer it while being able to search, so a failure costs only the
    /// "me" features.
    me: []const u8 = "",
    me_asked: bool = false,
    tabs: []Tab = &.{},
    active: usize = 0,
    detail_open: bool = true,
    detail_scroll: u16 = 0,
    /// `key` → the fetched detail. Cleared for one key when it changes.
    details: std.StringHashMapUnmanaged(model.Detail) = .empty,
    overlay: Overlay = .none,
    palette: theme.Palette = theme.Palette.dark_palette,
    cols: u16 = 80,
    rows: u16 = 24,
    focused: bool = true,
    /// The status line. Owned by `scratch`.
    status: []const u8 = "",
    /// The Jira timestamp the last refresh started at. Every `Updated`
    /// cell is measured against this one value, so no two rows on screen
    /// disagree about what "now" is.
    now_stamp: []const u8 = "",
    /// The monotonic clock at the end of the last refresh, for
    /// `mnml.refresh_interval_secs`.
    last_refresh_ms: i64 = 0,
    /// True while `refresh` is on the wire.
    busy: bool = false,
    sink: Sink = .{},
    /// Set when `q` was pressed.
    done: bool = false,
    /// Short-lived strings: the status line, a picker's items, a detail.
    scratch: std.heap.ArenaAllocator,
    /// The config, the token and the resolved JQLs — the life of the run.
    perm: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: Io) App {
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = .{},
            .cfg_path = "",
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .perm = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(a: *App) void {
        for (a.tabs) |*t| t.deinit();
        if (a.tabs.len > 0) a.gpa.free(a.tabs);
        a.details.deinit(a.gpa);
        a.closeOverlay();
        a.scratch.deinit();
        a.perm.deinit();
        a.* = undefined;
    }

    pub fn tab(a: *App) ?*Tab {
        if (a.tabs.len == 0) return null;
        return &a.tabs[@min(a.active, a.tabs.len - 1)];
    }

    /// Build the tabs from the config. Nothing is fetched here.
    pub fn openTabs(a: *App) Allocator.Error!void {
        const arena = a.perm.allocator();
        var list: std.ArrayListUnmanaged(Tab) = .empty;
        for (a.cfg.tabs) |tc| {
            const jql = (try tc.staticJql(arena)) orelse "";
            try list.append(a.gpa, .{
                .cfg = tc,
                .jql = jql,
                .state = tree.State.init(a.gpa),
                .arena = std.heap.ArenaAllocator.init(a.gpa),
            });
        }
        a.tabs = try list.toOwnedSlice(a.gpa);
    }

    pub fn setStatus(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.status = std.fmt.allocPrint(a.scratch.allocator(), fmt, args) catch "";
    }

    /// A status line plus a repaint, for the middle of a refresh.
    fn progress(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.setStatus(fmt, args);
        a.sink.call();
    }

    // ── keys ────────────────────────────────────────────────────────────

    pub fn key(a: *App, spec: []const u8) !void {
        const action = keys.map(a.overlay.mode(), spec);
        try a.act(action);
    }

    pub fn act(a: *App, action: Action) !void {
        switch (a.overlay) {
            .none => try a.listAction(action),
            .help => try a.helpAction(action),
            .filter => try a.filterAction(action),
            .picker => try a.pickerAction(action),
            .comment => try a.commentAction(action),
            .form => try a.formAction(action),
            .confirm => try a.confirmAction(action),
        }
    }

    fn helpAction(a: *App, action: Action) !void {
        switch (action) {
            .cancel => a.closeOverlay(),
            .move => |d| {
                const h = &a.overlay.help;
                if (d > 0) h.scroll +|= 1 else h.scroll -|= 1;
            },
            else => {},
        }
    }

    fn listAction(a: *App, action: Action) !void {
        const t = a.tab() orelse {
            // With no tabs at all only quitting and the help sheet work.
            switch (action) {
                .quit, .cancel => a.done = true,
                .help => a.overlay = .{ .help = .{} },
                .refresh => try a.reload(),
                else => {},
            }
            return;
        };
        switch (action) {
            .quit => a.done = true,
            .cancel => {
                // Esc is a cascade: clear the filter, else close the
                // detail pane, else leave.
                if (t.filter.len > 0) {
                    t.filter = "";
                    try a.rebuild(t);
                    a.setStatus("filter cleared", .{});
                } else if (a.detail_open) {
                    a.detail_open = false;
                } else a.done = true;
            },
            .refresh => try a.refresh(),
            .move => |d| a.moveCursor(t, d),
            .page => |d| a.moveCursor(t, @intCast(@as(i32, d) * @as(i32, @intCast(@max(1, a.listHeight() - 1))))),
            .top => {
                t.cursor = 0;
                a.onCursorMoved();
            },
            .bottom => {
                t.cursor = if (t.rows.len == 0) 0 else t.rows.len - 1;
                a.onCursorMoved();
            },
            .expand, .collapse, .toggle_row => {
                const move: tree.Move = switch (action) {
                    .expand => .expand,
                    .collapse => .collapse,
                    else => .toggle,
                };
                // Opening a ticket is when its PRs are worth fetching.
                if (move != .collapse) try a.ensurePrs(t);
                t.cursor = try tree.navigate(&t.state, t.rows, t.issues, t.cursor, move);
                try a.rebuild(t);
                a.onCursorMoved();
            },
            .expand_all => {
                t.state.expandAll();
                try a.rebuild(t);
            },
            .collapse_all => {
                try t.state.collapseAll();
                try a.rebuild(t);
            },
            .hide_row => {
                const it = t.selected() orelse return;
                try t.state.hide(it.key);
                a.setStatus("hid {s} ({d} hidden · H brings them back)", .{ it.key, t.state.hiddenCount() });
                try a.rebuild(t);
            },
            .unhide_all => {
                const n = t.state.hiddenCount();
                t.state.unhideAll();
                a.setStatus("{d} row(s) back", .{n});
                try a.rebuild(t);
            },
            .show_all_prs => {
                const it = t.selected() orelse return;
                try t.state.showAllPrs(it.key);
                try a.rebuild(t);
            },
            .next_tab => a.gotoTab(a.active + 1),
            .prev_tab => a.gotoTab(if (a.active == 0) a.tabs.len - 1 else a.active - 1),
            .go_tab => |n| a.gotoTab(@as(usize, n) - 1),
            .open_filter => {
                var e = Editor.init(a.gpa);
                try e.set(t.filter);
                a.overlay = .{ .filter = e };
            },
            .toggle_detail => a.detail_open = !a.detail_open,
            .detail_scroll => |d| {
                if (d > 0) a.detail_scroll +|= @intCast(d) else a.detail_scroll -|= @intCast(-d);
            },
            .help => a.overlay = .{ .help = .{} },
            .open_browser => try a.openInBrowser(),
            .copy_key => try a.copy(.key),
            .copy_url => try a.copy(.url),
            .transition => try a.openTransitions(),
            .assign => try a.openAssignees(),
            .assign_to_me => try a.assignToMe(),
            .set_fix_version => try a.openVersions(),
            .comment => try a.openComment(),
            .create => try a.openForm(),
            else => {},
        }
    }

    fn filterAction(a: *App, action: Action) !void {
        const t = a.tab() orelse return;
        const e = &a.overlay.filter;
        switch (action) {
            .cancel => {
                a.closeOverlay();
                t.filter = "";
                try a.rebuild(t);
            },
            .accept => {
                t.filter = try a.perm.allocator().dupe(u8, e.text());
                a.closeOverlay();
                try a.rebuild(t);
            },
            .move => |d| a.moveCursor(t, d),
            else => {
                if (try e.apply(action)) {
                    // Live: the list narrows as the user types.
                    t.filter = try a.perm.allocator().dupe(u8, e.text());
                    try a.rebuild(t);
                }
            },
        }
    }

    fn pickerAction(a: *App, action: Action) !void {
        const p = &a.overlay.picker;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const vis = try p.visible(scratch.allocator());
        switch (action) {
            .cancel => a.closeOverlay(),
            .move => |d| {
                if (vis.len == 0) return;
                p.cursor = clampMove(p.cursor, d, vis.len);
            },
            .page => |d| {
                if (vis.len == 0) return;
                p.cursor = clampMove(p.cursor, @as(i8, @intCast(@min(9, @as(i16, d) * 5))), vis.len);
            },
            .go_tab => |n| {
                if (n <= vis.len) p.cursor = n - 1;
            },
            .accept => {
                if (vis.len == 0) return;
                const item = p.items[vis[@min(p.cursor, vis.len - 1)]];
                try a.commitPick(p.kind, p.key, item);
            },
            else => {
                if (try p.filter.apply(action)) p.cursor = 0;
            },
        }
    }

    fn commentAction(a: *App, action: Action) !void {
        const c = &a.overlay.comment;
        switch (action) {
            .cancel => a.closeOverlay(),
            .accept => {
                const body = std.mem.trim(u8, c.editor.text(), " \t\r\n");
                if (body.len == 0) {
                    c.err = "nothing to post";
                    return;
                }
                const key_copy = try a.scratch.allocator().dupe(u8, c.key);
                const body_copy = try a.scratch.allocator().dupe(u8, body);
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                const client = a.client orelse return;
                _ = client;
                switch (try jira.addComment(&a.client.?, scratch.allocator(), key_copy, body_copy)) {
                    .ok => {
                        a.closeOverlay();
                        a.forgetDetail(key_copy);
                        try a.loadDetail(key_copy);
                        a.setStatus("commented on {s}", .{key_copy});
                    },
                    // The buffer is kept: the user can fix it or copy it out.
                    .failed => |f| c.err = try a.scratch.allocator().dupe(u8, f.message),
                }
            },
            else => _ = try c.editor.apply(action),
        }
    }

    fn formAction(a: *App, action: Action) !void {
        const f = &a.overlay.form;
        switch (action) {
            .cancel => a.closeOverlay(),
            .next_field => f.next(),
            .prev_field => f.prev(),
            .accept => try a.submitForm(),
            .newline => {
                // Only the description is multi-line; elsewhere Enter
                // moves on, which is what a form should do.
                if (f.focus == .description) {
                    _ = try f.get(.description).apply(.newline);
                } else f.next();
            },
            else => _ = try f.get(f.focus).apply(action),
        }
    }

    fn confirmAction(a: *App, action: Action) !void {
        switch (action) {
            .cancel => {
                a.closeOverlay();
                a.setStatus("cancelled", .{});
            },
            .accept => {
                const what = a.overlay.confirm.what;
                a.closeOverlay();
                switch (what) {
                    .transition => |tr| try a.runTransition(tr.key, tr.id, tr.to),
                }
            },
            else => {},
        }
    }

    pub fn closeOverlay(a: *App) void {
        switch (a.overlay) {
            .filter => |*e| e.deinit(),
            .picker => |*p| p.filter.deinit(),
            .comment => |*c| c.editor.deinit(),
            .form => |*f| for (&f.fields) |*e| e.deinit(),
            else => {},
        }
        a.overlay = .none;
    }

    // ── cursor ──────────────────────────────────────────────────────────

    pub fn listHeight(a: *App) u16 {
        // Row 0 the tab strip, row 1 the column header, the last row the
        // status line, and a filter line when one is on.
        const chrome: u16 = 3 + @as(u16, if (a.tab()) |t| @intFromBool(t.filter.len > 0) else 0);
        return if (a.rows > chrome) a.rows - chrome else 1;
    }

    fn moveCursor(a: *App, t: *Tab, delta: i8) void {
        if (t.rows.len == 0) return;
        t.cursor = clampMove(t.cursor, delta, t.rows.len);
        a.onCursorMoved();
    }

    fn clampMove(cursor: usize, delta: i8, len: usize) usize {
        if (len == 0) return 0;
        const at: i64 = @intCast(cursor);
        const to = std.math.clamp(at + delta, 0, @as(i64, @intCast(len - 1)));
        return @intCast(to);
    }

    fn onCursorMoved(a: *App) void {
        a.detail_scroll = 0;
        const t = a.tab() orelse return;
        // Keep the cursor on screen.
        const h = a.listHeight();
        if (t.cursor < t.scroll) t.scroll = t.cursor;
        if (t.cursor >= t.scroll + h) t.scroll = t.cursor + 1 - h;
    }

    /// The first screen row the ticket list occupies: under the tab
    /// strip, under the filter line when one is showing, under the
    /// column header.
    pub fn listTop(a: *App) u16 {
        const filtering: u16 = if (a.tab()) |t| @intFromBool(t.filter.len > 0) else 0;
        return 2 + filtering;
    }

    /// The column the detail pane starts at, or null when it is closed.
    pub fn detailX(a: *App) ?u16 {
        if (!a.detail_open or a.cols < 60) return null;
        const w = @max(28, a.cols / 100 * a.cfg.mnml.detail_width_pct);
        return a.cols -| (w + 1);
    }

    /// A click at a screen cell. The tab strip switches tabs; a row in
    /// the list selects it, and a click on its chevron folds it — the
    /// same two things the keyboard does, in the same places the eye
    /// sees them.
    pub fn click(a: *App, col: u16, row: u16, right: bool) !void {
        if (a.overlay != .none) {
            // A click outside an overlay dismisses it, which is what
            // every other mnml overlay does.
            a.closeOverlay();
            return;
        }
        if (row == 0) {
            var x: u16 = 6; // past the `JIRA` chip
            for (a.tabs, 0..) |*t, i| {
                const w: u16 = @intCast(text.width(t.cfg.name) + 5);
                if (col >= x and col < x + w) {
                    a.gotoTab(i);
                    return;
                }
                x += w;
            }
            return;
        }
        const t = a.tab() orelse return;
        if (a.detailX()) |dx| if (col >= dx) return;
        const top = a.listTop();
        if (row < top) return;
        const at = t.scroll + (row - top);
        if (at >= t.rows.len) return;
        t.cursor = at;
        a.onCursorMoved();
        // The chevron sits at the row's indent; a click there folds.
        const mark_x: u16 = 1 + @as(u16, t.rows[at].depth()) * 2;
        if (right or col <= mark_x + 1) {
            try a.ensurePrs(t);
            t.cursor = try tree.navigate(&t.state, t.rows, t.issues, t.cursor, .toggle);
            try a.rebuild(t);
        }
    }

    /// A wheel notch: positive is up. Over the detail pane it scrolls
    /// the detail; over the list it moves the cursor.
    pub fn wheel(a: *App, dy: i16) !void {
        const step: i8 = 3;
        if (dy > 0) {
            if (a.detail_scroll > 0 and a.overlay == .none) a.detail_scroll -|= @intCast(step);
            const t = a.tab() orelse return;
            a.moveCursor(t, -step);
        } else if (dy < 0) {
            const t = a.tab() orelse return;
            a.moveCursor(t, step);
        }
    }

    fn gotoTab(a: *App, want: usize) void {
        if (a.tabs.len == 0) return;
        a.active = want % a.tabs.len;
        a.detail_scroll = 0;
    }

    // ── fetching ────────────────────────────────────────────────────────

    /// Rebuild the visible rows from the issues already in hand.
    pub fn rebuild(a: *App, t: *Tab) Allocator.Error!void {
        t.rows = try tree.build(t.arena.allocator(), &t.state, t.issues, .{
            .group_by = t.cfg.group_by,
            .status_order = t.cfg.status_order,
            .max_prs = a.cfg.mnml.max_prs,
            .filter = t.filter,
        });
        if (t.rows.len == 0) {
            t.cursor = 0;
            t.scroll = 0;
        } else if (t.cursor >= t.rows.len) t.cursor = t.rows.len - 1;
        a.onCursorMoved();
    }

    /// The whole active tab, from the wire.
    pub fn refresh(a: *App) !void {
        const t = a.tab() orelse return;
        if (a.client == null) return;
        a.busy = true;
        defer a.busy = false;
        t.err = null;
        a.now_stamp = nowStamp(a.perm.allocator(), a.io) catch a.now_stamp;
        a.progress("refreshing {s}…", .{t.cfg.name});

        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();

        // Who "me" is, once. A refusal is remembered, not retried.
        if (!a.me_asked) {
            a.me_asked = true;
            switch (try jira.myself(&a.client.?, scratch.allocator())) {
                .ok => |u| a.me = try a.perm.allocator().dupe(u8, u.account_id),
                .failed => {},
            }
        }

        // A release tab has to ask which version it means.
        if (t.jql.len == 0 and t.cfg.kind == .fix_version and t.cfg.project.len > 0) {
            a.progress("{s}: finding the release…", .{t.cfg.name});
            switch (try jira.projectVersions(&a.client.?, scratch.allocator(), t.cfg.project)) {
                .failed => |f| {
                    t.err = try a.perm.allocator().dupe(u8, f.message);
                    a.setStatus("{s}: {s}", .{ t.cfg.name, f.message });
                    return;
                },
                .ok => |all| {
                    const open = try jira.unreleasedVersions(scratch.allocator(), all, t.cfg.version_name_contains);
                    const pick = jira.pickVersion(open, t.cfg.mode) orelse {
                        // The Rust tracker's sentinel: the tab exists and
                        // is empty rather than the pane failing.
                        t.jql = "issuekey = ''";
                        t.err = try a.perm.allocator().dupe(u8, "no unreleased version matches (check version_name_contains)");
                        return;
                    };
                    t.version = try a.perm.allocator().dupe(u8, pick.name);
                    t.jql = try jira.fixVersionJql(a.perm.allocator(), t.cfg.project, pick.name, t.cfg.component);
                },
            }
        }
        if (t.jql.len == 0) {
            t.err = "this tab has no JQL — give it .jql, or a .kind that builds one";
            return;
        }

        const jql = try jira.withTeam(scratch.allocator(), t.jql, t.cfg.team, a.cfg.jira.team_field_name, a.cfg.jira.team_field_id);
        a.progress("{s}: searching…", .{t.cfg.name});

        // The issues AND the cached PR lists live on the tab's own
        // arena, which this resets — so the PR cache has to be dropped
        // in the same breath, before anything can fail and leave the
        // map pointing into freed memory.
        _ = t.arena.reset(.retain_capacity);
        t.state.forgetPrs();
        t.issues = &.{};
        t.rows = &.{};
        const arena = t.arena.allocator();
        const extra: []const []const u8 = if (a.cfg.jira.team_field_id.len > 0) &.{a.cfg.jira.team_field_id} else &.{};
        switch (try jira.search(&a.client.?, arena, jql, extra)) {
            .failed => |f| {
                t.err = try a.perm.allocator().dupe(u8, f.message);
                a.setStatus("{s}: {s}", .{ t.cfg.name, f.message });
                return;
            },
            .ok => |items| {
                t.issues = try model.listFromJson(arena, items, a.cfg.jira.team_field_id);
                t.fetched = true;
            },
        }
        try a.rebuild(t);
        a.setStatus("{s} · {d} ticket{s}", .{ t.cfg.name, t.issues.len, if (t.issues.len == 1) "" else "s" });
        a.last_refresh_ms = Io.Timestamp.now(a.io, .awake).toMilliseconds();
        if (a.detail_open) if (t.selected()) |it| try a.loadDetail(it.key);
    }

    /// Re-read the config and start again — what `r` does when the pane
    /// is blocked on a missing config or token.
    pub fn reload(a: *App) !void {
        a.setStatus("nothing to refresh", .{});
    }

    /// The pane just got the keyboard back. Bridge v2 has no timer
    /// message — the host speaks `hello`, `resize`, `input`, `focus` and
    /// `goodbye` — so regaining focus is the tick an idle auto-refresh
    /// gets: come back to the pane after `refresh_interval_secs` and it
    /// reloads before you read it.
    pub fn focusGained(a: *App) !void {
        a.focused = true;
        const every = a.cfg.mnml.refresh_interval_secs;
        if (every == 0 or a.client == null or a.busy) return;
        if (a.overlay != .none) return;
        const t = a.tab() orelse return;
        if (!t.fetched) return;
        const now = Io.Timestamp.now(a.io, .awake).toMilliseconds();
        if (now - a.last_refresh_ms < @as(i64, every) * 1000) return;
        try a.refresh();
    }

    /// Fetch the selected ticket's PRs, once.
    fn ensurePrs(a: *App, t: *Tab) !void {
        const it = t.selected() orelse return;
        if (t.state.prsOf(it.key) != null) return;
        if (a.client == null) return;
        a.progress("{s}: linked pull requests…", .{it.key});
        switch (try jira.pullRequests(&a.client.?, t.arena.allocator(), it.key, it.id)) {
            .ok => |list| {
                try t.state.setPrs(it.key, list);
                if (list.len > 0) a.setStatus("{s} · {d} linked PR{s}", .{ it.key, list.len, if (list.len == 1) "" else "s" });
            },
            .failed => |f| {
                // Remember the refusal as "none", so one 403 is not a
                // fetch on every keypress.
                try t.state.setPrs(it.key, &.{});
                a.setStatus("{s}: pull requests: {s}", .{ it.key, f.message });
            },
        }
    }

    pub fn detailOf(a: *App, issue_key: []const u8) ?model.Detail {
        return a.details.get(issue_key);
    }

    fn forgetDetail(a: *App, issue_key: []const u8) void {
        _ = a.details.remove(issue_key);
    }

    pub fn loadDetail(a: *App, issue_key: []const u8) !void {
        if (a.client == null) return;
        if (a.details.contains(issue_key)) return;
        switch (try jira.issue(&a.client.?, a.scratch.allocator(), issue_key)) {
            .ok => |v| {
                const d = try model.detailFromJson(a.scratch.allocator(), v);
                try a.details.put(a.gpa, try a.scratch.allocator().dupe(u8, issue_key), d);
            },
            .failed => |f| a.setStatus("{s}: {s}", .{ issue_key, f.message }),
        }
    }

    // ── actions ─────────────────────────────────────────────────────────

    fn browseUrl(a: *App, issue_key: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(a.scratch.allocator(), "{s}/browse/{s}", .{ a.cfg.jira.url, issue_key });
    }

    fn openInBrowser(a: *App) !void {
        const t = a.tab() orelse return;
        // On a PR row, `o` opens the PR — that is the link the row is.
        if (t.selectedRow()) |r| if (r == .pr) {
            const it = t.issues[r.pr.issue];
            const list = t.state.prsOf(it.key) orelse &.{};
            if (r.pr.pr < list.len) {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                return a.reportOpen(os.open(a.io, scratch.allocator(), a.cfg.mnml.open_command, list[r.pr.pr].url), list[r.pr.pr].url);
            }
        };
        const it = t.selected() orelse return;
        const url = try a.browseUrl(it.key);
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.reportOpen(os.open(a.io, scratch.allocator(), a.cfg.mnml.open_command, url), url);
    }

    fn reportOpen(a: *App, out: os.Outcome, url: []const u8) void {
        switch (out) {
            .ok => a.setStatus("opened {s}", .{url}),
            .failed => |why| a.setStatus("could not open {s}: {s}", .{ url, why }),
        }
    }

    const CopyWhat = enum { key, url };

    fn copy(a: *App, what: CopyWhat) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        const s = switch (what) {
            .key => it.key,
            .url => try a.browseUrl(it.key),
        };
        switch (os.copy(a.io, s)) {
            .ok => a.setStatus("copied {s}", .{s}),
            // Put it on the status line so it can at least be read off.
            .failed => |why| a.setStatus("{s} — {s}", .{ s, why }),
        }
    }

    fn openTransitions(a: *App) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        if (a.client == null) return;
        const arena = a.scratch.allocator();
        const key_copy = try arena.dupe(u8, it.key);
        a.progress("{s}: transitions…", .{key_copy});
        var items: std.ArrayListUnmanaged(PickItem) = .empty;
        var err: ?[]const u8 = null;
        switch (try jira.transitions(&a.client.?, arena, key_copy)) {
            .ok => |list| for (list) |tr| try items.append(arena, .{
                .id = tr.id,
                .label = if (tr.to_name.len > 0)
                    try std.fmt.allocPrint(arena, "{s}  → {s}", .{ tr.name, tr.to_name })
                else
                    tr.name,
            }),
            .failed => |f| err = f.message,
        }
        a.overlay = .{ .picker = .{
            .kind = .transition,
            .key = key_copy,
            .items = try items.toOwnedSlice(arena),
            .filter = Editor.init(a.gpa),
            .err = err,
        } };
    }

    fn openAssignees(a: *App) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        if (a.client == null) return;
        const arena = a.scratch.allocator();
        const key_copy = try arena.dupe(u8, it.key);
        const project = projectOf(key_copy);
        a.progress("{s}: who can take it…", .{key_copy});
        var items: std.ArrayListUnmanaged(PickItem) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Unassign —" });
        var err: ?[]const u8 = null;
        switch (try jira.assignableUsers(&a.client.?, arena, project)) {
            .ok => |users| for (users) |u| try items.append(arena, .{ .id = u.account_id, .label = u.display_name }),
            .failed => |f| err = f.message,
        }
        a.overlay = .{ .picker = .{
            .kind = .assignee,
            .key = key_copy,
            .items = try items.toOwnedSlice(arena),
            .filter = Editor.init(a.gpa),
            .err = err,
        } };
    }

    fn openVersions(a: *App) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        if (a.client == null) return;
        const arena = a.scratch.allocator();
        const key_copy = try arena.dupe(u8, it.key);
        const project = projectOf(key_copy);
        a.progress("{s}: versions…", .{key_copy});
        var items: std.ArrayListUnmanaged(PickItem) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Clear the fix version —" });
        var err: ?[]const u8 = null;
        switch (try jira.projectVersions(&a.client.?, arena, project)) {
            .ok => |all| {
                const open = try jira.unreleasedVersions(arena, all, "");
                for (open) |v| try items.append(arena, .{ .id = v.name, .label = v.name });
                for (all) |v| if (v.released) try items.append(arena, .{
                    .id = v.name,
                    .label = try std.fmt.allocPrint(arena, "{s}  (released)", .{v.name}),
                });
            },
            .failed => |f| err = f.message,
        }
        a.overlay = .{ .picker = .{
            .kind = .fix_version,
            .key = key_copy,
            .items = try items.toOwnedSlice(arena),
            .filter = Editor.init(a.gpa),
            .err = err,
        } };
    }

    fn commitPick(a: *App, kind: PickKind, issue_key: []const u8, item: PickItem) !void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (kind) {
            // A transition is the one action that changes what everyone
            // else sees, so it asks first.
            .transition => {
                const arena = a.scratch.allocator();
                a.closeOverlay();
                a.overlay = .{ .confirm = .{
                    .message = try std.fmt.allocPrint(arena, "Move {s} — {s}?", .{ issue_key, item.label }),
                    .what = .{ .transition = .{
                        .key = try arena.dupe(u8, issue_key),
                        .id = try arena.dupe(u8, item.id),
                        .to = try arena.dupe(u8, item.label),
                    } },
                } };
            },
            .assignee => {
                switch (try jira.setAssignee(&a.client.?, scratch.allocator(), issue_key, item.id)) {
                    .ok => {
                        a.closeOverlay();
                        a.forgetDetail(issue_key);
                        // After the refresh, not before: a refresh sets
                        // its own line, and the outcome is what the user
                        // is looking for.
                        try a.refresh();
                        a.setStatus("{s} · assignee = {s}", .{ issue_key, item.label });
                    },
                    .failed => |f| a.overlay.picker.err = try a.scratch.allocator().dupe(u8, f.message),
                }
            },
            .fix_version => {
                switch (try jira.setFixVersion(&a.client.?, scratch.allocator(), issue_key, item.id)) {
                    .ok => {
                        a.closeOverlay();
                        a.forgetDetail(issue_key);
                        try a.refresh();
                        a.setStatus("{s} · fix version = {s}", .{ issue_key, if (item.id.len == 0) "none" else item.id });
                    },
                    .failed => |f| a.overlay.picker.err = try a.scratch.allocator().dupe(u8, f.message),
                }
            },
            .issue_type => a.closeOverlay(),
        }
    }

    fn runTransition(a: *App, issue_key: []const u8, id: []const u8, to: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.progress("{s}: {s}…", .{ issue_key, to });
        switch (try jira.doTransition(&a.client.?, scratch.allocator(), issue_key, id)) {
            .ok => {
                a.forgetDetail(issue_key);
                try a.refresh();
                a.setStatus("{s} · {s}", .{ issue_key, to });
            },
            .failed => |f| a.setStatus("{s}: {s}", .{ issue_key, f.message }),
        }
    }

    fn assignToMe(a: *App) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        if (a.me.len == 0) {
            a.setStatus("who \"me\" is is unknown — the token cannot read /myself, so use a to pick", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key_copy = try a.scratch.allocator().dupe(u8, it.key);
        switch (try jira.setAssignee(&a.client.?, scratch.allocator(), key_copy, a.me)) {
            .ok => {
                a.forgetDetail(key_copy);
                try a.refresh();
                a.setStatus("{s} · assigned to you", .{key_copy});
            },
            .failed => |f| a.setStatus("{s}: {s}", .{ key_copy, f.message }),
        }
    }

    fn openComment(a: *App) !void {
        const t = a.tab() orelse return;
        const it = t.selected() orelse return;
        a.overlay = .{ .comment = .{
            .key = try a.scratch.allocator().dupe(u8, it.key),
            .editor = Editor.init(a.gpa),
        } };
    }

    fn openForm(a: *App) !void {
        const t = a.tab() orelse return;
        var f: Form = .{ .fields = .{ Editor.init(a.gpa), Editor.init(a.gpa), Editor.init(a.gpa), Editor.init(a.gpa) } };
        // Seed the project from the tab, or from the row under the cursor.
        const project = if (t.cfg.project.len > 0)
            t.cfg.project
        else if (t.selected()) |it| projectOf(it.key) else "";
        try f.get(.project).set(project);
        try f.get(.issue_type).set("Task");
        a.overlay = .{ .form = f };
    }

    fn submitForm(a: *App) !void {
        const f = &a.overlay.form;
        const project = std.mem.trim(u8, f.get(.project).text(), " \t");
        const kind = std.mem.trim(u8, f.get(.issue_type).text(), " \t");
        const summary = std.mem.trim(u8, f.get(.summary).text(), " \t\r\n");
        if (project.len == 0) {
            f.err = "a project key is required";
            f.focus = .project;
            return;
        }
        if (summary.len == 0) {
            f.err = "a summary is required";
            f.focus = .summary;
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.progress("creating in {s}…", .{project});
        switch (try jira.createIssue(&a.client.?, scratch.allocator(), .{
            .project = project,
            .issue_type = if (kind.len > 0) kind else "Task",
            .summary = summary,
            .description = f.get(.description).text(),
        })) {
            .ok => |new_key| {
                const copy_key = try a.scratch.allocator().dupe(u8, new_key);
                a.closeOverlay();
                try a.refresh();
                a.setStatus("created {s}", .{copy_key});
            },
            .failed => |fail| f.err = try a.scratch.allocator().dupe(u8, fail.message),
        }
    }
};

/// The wall clock as a Jira timestamp, for the `Updated` column's ages.
pub fn nowStamp(arena: Allocator, io: Io) Allocator.Error![]const u8 {
    const secs = @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000+0000", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// `ENG-1234` → `ENG`.
pub fn projectOf(key: []const u8) []const u8 {
    const dash = std.mem.indexOfScalar(u8, key, '-') orelse return key;
    return key[0..dash];
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the editor: insert, the cursor, word-delete, kill, and a multi-byte character" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    for ("hello world") |c| try e.insert(c);
    try testing.expectEqualStrings("hello world", e.text());
    e.deleteWordBack();
    try testing.expectEqualStrings("hello ", e.text());
    e.home();
    try testing.expectEqual(@as(usize, 0), e.cursor);
    try e.insert('>');
    try testing.expectEqualStrings(">hello ", e.text());
    e.end();
    e.killToStart();
    try testing.expectEqualStrings("", e.text());
    // A multi-byte code point goes in and comes out whole.
    try e.insert('é');
    try e.insert('x');
    try testing.expectEqualStrings("éx", e.text());
    e.left();
    e.backspace();
    try testing.expectEqualStrings("x", e.text());
    // Backspace at the start is a no-op, not an underflow.
    e.home();
    e.backspace();
    try testing.expectEqualStrings("x", e.text());
    // killToEnd cuts from the cursor.
    try e.set("abcdef");
    e.home();
    e.right();
    e.right();
    e.killToEnd();
    try testing.expectEqualStrings("ab", e.text());
}

test "the editor answers exactly the actions the prompt mode produces" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    try testing.expect(try e.apply(.{ .insert = 'a' }));
    try testing.expect(try e.apply(.newline));
    try testing.expect(try e.apply(.cursor_home));
    try testing.expect(!try e.apply(.accept));
    try testing.expect(!try e.apply(.quit));
    try testing.expectEqualStrings("a\n", e.text());
}

test "projectOf takes the prefix of a key, and copes with one that has none" {
    try testing.expectEqualStrings("ENG", projectOf("ENG-1234"));
    try testing.expectEqualStrings("A", projectOf("A-1"));
    try testing.expectEqualStrings("nodash", projectOf("nodash"));
    try testing.expectEqualStrings("", projectOf(""));
}

test "the overlay decides the key mode, and closing one frees its editors" {
    var a = App.init(testing.allocator, testing.io);
    defer a.deinit();
    try testing.expectEqual(Mode.list, a.overlay.mode());
    a.overlay = .{ .filter = Editor.init(testing.allocator) };
    try testing.expectEqual(Mode.filter, a.overlay.mode());
    a.closeOverlay();
    try testing.expectEqual(Mode.list, a.overlay.mode());
    a.overlay = .{ .comment = .{ .key = "ENG-1", .editor = Editor.init(testing.allocator) } };
    try testing.expectEqual(Mode.prompt, a.overlay.mode());
    a.closeOverlay();
    a.overlay = .{ .confirm = .{ .message = "?", .what = .{ .transition = .{ .key = "ENG-1", .id = "1", .to = "Done" } } } };
    try testing.expectEqual(Mode.confirm, a.overlay.mode());
    a.closeOverlay();
    a.overlay = .{ .help = .{} };
    try testing.expectEqual(Mode.help, a.overlay.mode());
}

/// An app with tabs and issues but no client — every key that does not
/// touch the wire can be driven against it.
fn offlineApp(gpa: Allocator) !App {
    var a = App.init(gpa, testing.io);
    a.cfg = .{
        .jira = .{ .url = "https://acme.atlassian.net", .email = "me@acme.com" },
        .tabs = &.{
            .{ .name = "Mine", .kind = .work_assigned },
            .{ .name = "Release", .jql = "project = ENG", .kind = .custom },
        },
    };
    try a.openTabs();
    const t = &a.tabs[0];
    const arena = t.arena.allocator();
    const issues = try arena.alloc(model.Issue, 5);
    issues[0] = .{ .key = "ENG-1", .summary = "Checkout rewrite", .level = .epic, .status = "In Progress", .category = .indeterminate, .assignee = "Ada" };
    issues[1] = .{ .key = "ENG-2", .summary = "Card form", .level = .story, .status = "In Review", .category = .indeterminate, .parent_key = "ENG-1" };
    issues[2] = .{ .key = "ENG-3", .summary = "Apple Pay", .level = .story, .status = "To Do", .category = .new, .parent_key = "ENG-1" };
    issues[3] = .{ .key = "ENG-4", .summary = "Blur handler", .level = .subtask, .status = "Done", .category = .done, .parent_key = "ENG-2" };
    issues[4] = .{ .key = "ENG-5", .summary = "Voucher total", .level = .story, .status = "To Do", .category = .new };
    t.issues = issues;
    t.fetched = true;
    a.rows = 24;
    a.cols = 100;
    try a.rebuild(t);
    return a;
}

test "the list keys move, fold, hide and switch tabs against a tree that is already loaded" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    try testing.expectEqualStrings("ENG-1", t.selected().?.key);

    try a.key("j");
    try testing.expectEqualStrings("ENG-2", t.selected().?.key);
    try a.key("G");
    try testing.expectEqualStrings("ENG-5", t.selected().?.key);
    try a.key("g");
    try testing.expectEqualStrings("ENG-1", t.selected().?.key);

    // Collapse the epic: the three rows under it go.
    try a.key("h");
    try testing.expectEqual(@as(usize, 2), t.rows.len);
    try a.key("l");
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    // C folds everything, E opens it.
    try a.key("C");
    try testing.expectEqual(@as(usize, 2), t.rows.len);
    try a.key("E");
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    // Enter toggles the row under the cursor.
    try a.key("enter");
    try testing.expectEqual(@as(usize, 2), t.rows.len);
    try a.key("space");
    try testing.expectEqual(@as(usize, 5), t.rows.len);

    // `x` hides the branch, `H` brings it back and says how many.
    try a.key("j");
    try a.key("x");
    try testing.expectEqual(@as(usize, 3), t.rows.len);
    try testing.expect(std.mem.indexOf(u8, a.status, "hid ENG-2") != null);
    try a.key("H");
    try testing.expectEqual(@as(usize, 5), t.rows.len);

    // Tabs wrap in both directions, and the digits jump.
    try testing.expectEqual(@as(usize, 0), a.active);
    try a.key("tab");
    try testing.expectEqual(@as(usize, 1), a.active);
    try a.key("tab");
    try testing.expectEqual(@as(usize, 0), a.active);
    try a.key("shift+tab");
    try testing.expectEqual(@as(usize, 1), a.active);
    try a.key("2");
    try testing.expectEqual(@as(usize, 1), a.active);
    try a.key("1");
    try testing.expectEqual(@as(usize, 0), a.active);

    // `q` ends the pane.
    try testing.expect(!a.done);
    try a.key("q");
    try testing.expect(a.done);
}

test "the filter is live, Esc drops it, and Esc cascades after that" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    try a.key("/");
    try testing.expectEqual(Mode.filter, a.overlay.mode());
    // Typing narrows as it goes — and keeps the matched row's ancestors.
    for ("blur") |c| try a.key(&[_]u8{c});
    try testing.expectEqual(@as(usize, 3), t.rows.len);
    try a.key("enter");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expectEqualStrings("blur", t.filter);
    // Esc clears the filter first…
    try a.key("esc");
    try testing.expectEqualStrings("", t.filter);
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    // …then closes the detail pane…
    try testing.expect(a.detail_open);
    try a.key("esc");
    try testing.expect(!a.detail_open);
    // …then leaves.
    try a.key("esc");
    try testing.expect(a.done);
    // Esc inside the filter cancels it outright.
    a.done = false;
    try a.key("/");
    for ("zzz") |c| try a.key(&[_]u8{c});
    try a.key("esc");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expectEqualStrings("", t.filter);
}

test "`?` opens the help sheet and every key but its own is ignored while it is up" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    try a.key("?");
    try testing.expectEqual(Mode.help, a.overlay.mode());
    // `q` would quit from the list; here it closes the sheet.
    try a.key("q");
    try testing.expect(!a.done);
    try testing.expectEqual(Mode.list, a.overlay.mode());
    // `j` under the sheet does not move the list.
    try a.key("?");
    const before = t.cursor;
    try a.key("j");
    try testing.expectEqual(before, t.cursor);
}

test "a picker filters, moves, jumps by digit and cancels without doing anything" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    a.overlay = .{ .picker = .{
        .kind = .assignee,
        .key = "ENG-1",
        .items = &.{
            .{ .id = "", .label = "— Unassign —" },
            .{ .id = "a1", .label = "Ada Lovelace" },
            .{ .id = "a2", .label = "Sam Beckett" },
        },
        .filter = Editor.init(testing.allocator),
    } };
    try testing.expectEqual(@as(usize, 3), (try a.overlay.picker.visible(scratch.allocator())).len);
    try a.key("down");
    try testing.expectEqual(@as(usize, 1), a.overlay.picker.cursor);
    try a.key("3");
    try testing.expectEqual(@as(usize, 2), a.overlay.picker.cursor);
    // Typing filters; `j` and `k` type rather than moving.
    for ("sam") |c| try a.key(&[_]u8{c});
    const vis = try a.overlay.picker.visible(scratch.allocator());
    try testing.expectEqual(@as(usize, 1), vis.len);
    try testing.expectEqualStrings("Sam Beckett", a.overlay.picker.items[vis[0]].label);
    try testing.expectEqual(@as(usize, 0), a.overlay.picker.cursor);
    // Backspacing the filter away brings every row back.
    try a.key("backspace");
    try a.key("backspace");
    try a.key("backspace");
    try testing.expectEqual(@as(usize, 3), (try a.overlay.picker.visible(scratch.allocator())).len);
    try a.key("esc");
    try testing.expectEqual(Mode.list, a.overlay.mode());
}

test "the comment box refuses an empty body and keeps what was typed when the post fails" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    try a.key("c");
    try testing.expectEqual(Mode.prompt, a.overlay.mode());
    try testing.expectEqualStrings("ENG-1", a.overlay.comment.key);
    // Whitespace is not a comment.
    try a.key("space");
    try a.key("ctrl+s");
    try testing.expectEqualStrings("nothing to post", a.overlay.comment.err.?);
    try testing.expectEqual(Mode.prompt, a.overlay.mode());
    // Enter makes a newline here; ctrl+s is the send.
    try a.key("enter");
    try testing.expect(std.mem.indexOfScalar(u8, a.overlay.comment.editor.text(), '\n') != null);
    try a.key("esc");
    try testing.expectEqual(Mode.list, a.overlay.mode());
}

test "the create form seeds its project, walks its fields and names the field that is empty" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    try a.key("n");
    try testing.expectEqual(Mode.prompt, a.overlay.mode());
    const f = &a.overlay.form;
    // The project came off the row under the cursor.
    try testing.expectEqualStrings("ENG", f.get(.project).text());
    try testing.expectEqualStrings("Task", f.get(.issue_type).text());
    try testing.expectEqual(FormField.summary, f.focus);
    // Tab and shift+tab walk, wrapping.
    try a.key("tab");
    try testing.expectEqual(FormField.description, f.focus);
    try a.key("tab");
    try testing.expectEqual(FormField.project, f.focus);
    try a.key("shift+tab");
    try testing.expectEqual(FormField.description, f.focus);
    // Enter in a one-line field moves on instead of typing a newline.
    f.focus = .summary;
    try a.key("enter");
    try testing.expectEqual(FormField.description, f.focus);
    try testing.expectEqualStrings("", f.get(.summary).text());
    // Submitting with no summary says so and puts the cursor there.
    try a.key("ctrl+s");
    try testing.expectEqualStrings("a summary is required", f.err.?);
    try testing.expectEqual(FormField.summary, f.focus);
    // …and with no project key either.
    f.get(.project).clear();
    try a.key("ctrl+s");
    try testing.expectEqualStrings("a project key is required", f.err.?);
    try testing.expectEqual(FormField.project, f.focus);
}

test "a transition asks before it moves anything, and n leaves the ticket alone" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    a.overlay = .{ .confirm = .{
        .message = "Move ENG-1 — Close  → Done?",
        .what = .{ .transition = .{ .key = "ENG-1", .id = "41", .to = "Close  → Done" } },
    } };
    try a.key("n");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expectEqualStrings("cancelled", a.status);
    // An unrelated key leaves the question up.
    a.overlay = .{ .confirm = .{
        .message = "?",
        .what = .{ .transition = .{ .key = "ENG-1", .id = "41", .to = "Done" } },
    } };
    try a.key("z");
    try testing.expectEqual(Mode.confirm, a.overlay.mode());
}

test "the cursor keeps itself on screen as it moves" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    a.rows = 8; // three rows of chrome, five of list
    const t = a.tab().?;
    try testing.expectEqual(@as(u16, 5), a.listHeight());
    try a.key("G");
    try testing.expectEqual(@as(usize, 4), t.cursor);
    try testing.expectEqual(@as(usize, 0), t.scroll);
    a.rows = 6; // three of list
    try a.key("g");
    try a.key("G");
    try testing.expectEqual(@as(usize, 2), t.scroll);
    try a.key("g");
    try testing.expectEqual(@as(usize, 0), t.scroll);
}

test "a click selects the row it landed on, and a click on the chevron folds it" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    a.detail_open = false;
    // Row 2 of the screen is the first ticket (strip, header, then rows).
    try testing.expectEqual(@as(u16, 2), a.listTop());
    try a.click(20, 3, false);
    try testing.expectEqualStrings("ENG-2", t.selected().?.key);
    // Its chevron is at the row's indent: a click there folds the branch.
    try a.click(3, 3, false);
    try testing.expectEqual(@as(usize, 4), t.rows.len);
    try a.click(3, 3, false);
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    // A right-click anywhere on the row folds it too.
    try a.click(40, 3, true);
    try testing.expectEqual(@as(usize, 4), t.rows.len);
    try a.click(40, 3, true);
    // A click past the last row changes nothing.
    const before = t.cursor;
    try a.click(20, 19, false);
    try testing.expectEqual(before, t.cursor);
    // A click on the tab strip switches tabs.
    try a.click(8, 0, false);
    try testing.expectEqual(@as(usize, 0), a.active);
    try a.click(20, 0, false);
    try testing.expectEqual(@as(usize, 1), a.active);
    // A click with an overlay up dismisses it rather than reaching the list.
    a.active = 0;
    try a.key("?");
    try a.click(20, 3, false);
    try testing.expectEqual(Mode.list, a.overlay.mode());
}

test "focus is the tick: an auto-refresh only fires when the interval has passed, and never mid-overlay" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    // No client: `focusGained` can never reach the wire, so this test
    // asserts the guards rather than the fetch.
    a.cfg.mnml.refresh_interval_secs = 60;
    a.last_refresh_ms = 0;
    try a.focusGained();
    try testing.expect(a.focused);
    // Off by config.
    a.cfg.mnml.refresh_interval_secs = 0;
    try a.focusGained();
    // An overlay is up: the user is typing, not reading.
    a.cfg.mnml.refresh_interval_secs = 60;
    try a.key("/");
    try a.focusGained();
    try testing.expectEqual(Mode.filter, a.overlay.mode());
    try a.key("esc");
}

test "the wheel moves the cursor three rows a notch, and stops at the ends" {
    var a = try offlineApp(testing.allocator);
    defer a.deinit();
    const t = a.tab().?;
    try a.wheel(-1);
    try testing.expectEqual(@as(usize, 3), t.cursor);
    try a.wheel(-1);
    try testing.expectEqual(@as(usize, 4), t.cursor);
    try a.wheel(1);
    try testing.expectEqual(@as(usize, 1), t.cursor);
    try a.wheel(1);
    try testing.expectEqual(@as(usize, 0), t.cursor);
    try a.wheel(0);
    try testing.expectEqual(@as(usize, 0), t.cursor);
}

/// An app wired to a fake Jira behind a real socket. The caller must
/// `finishServing` before the group is awaited.
const Wired = struct {
    app: App,
    store: fake.Store,
    server: Io.net.Server,
    loopback: jira.Loopback = undefined,
    group: Io.Group = .init,
    arena: std.heap.ArenaAllocator,

    const fake = jira.fake;

    fn start(gpa: Allocator) !*Wired {
        const w = try gpa.create(Wired);
        w.* = .{
            .app = App.init(gpa, testing.io),
            .store = try fake.Store.init(gpa),
            .server = undefined,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        w.server = try addr.listen(testing.io, .{ .reuse_address = true });
        w.loopback = .{ .store = &w.store, .server = &w.server };
        try w.group.concurrent(testing.io, jira.Loopback.serve, .{ testing.io, &w.loopback });
        const ar = w.arena.allocator();
        const base = try std.fmt.allocPrint(ar, "http://127.0.0.1:{d}", .{w.server.socket.address.getPort()});
        w.app.cfg = .{
            .jira = .{ .url = base, .email = "fake@acme.com", .rate = .{ .per_sec = 10_000, .burst = 100 } },
            .tabs = &.{.{ .name = "All", .kind = .custom, .jql = "project = ENG ORDER BY rank" }},
        };
        w.app.client = jira.Client.init(gpa, testing.io, base, try auth.basicHeader(ar, "fake@acme.com", "fake-token"), .v3, w.app.cfg.jira.rate);
        try w.app.openTabs();
        return w;
    }

    fn stop(w: *Wired, gpa: Allocator) void {
        w.loopback.finish(&w.app.client.?, w.arena.allocator()) catch {};
        w.group.await(testing.io) catch {};
        w.group.cancel(testing.io);
        w.server.deinit(testing.io);
        w.app.deinit();
        w.store.deinit();
        w.arena.deinit();
        gpa.destroy(w);
    }
};

test "a refresh against a real server fills the tree, the detail and the PR cache" {
    const gpa = testing.allocator;
    const w = try Wired.start(gpa);
    defer w.stop(gpa);
    const a = &w.app;
    a.cols = 120;
    a.rows = 30;

    try a.refresh();
    const t = a.tab().?;
    try testing.expectEqual(@as(usize, 5), t.issues.len);
    try testing.expectEqualStrings("ENG-1", t.issues[0].key);
    // The hierarchy came out of `parent`: the epic over two stories, one
    // of them over a sub-task, and the bug on its own.
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    try testing.expectEqual(@as(u8, 0), t.rows[0].issue.depth);
    try testing.expectEqual(@as(u8, 1), t.rows[1].issue.depth);
    try testing.expectEqual(@as(u8, 2), t.rows[2].issue.depth);
    // The detail pane's ticket was fetched with it.
    try testing.expect(a.detailOf("ENG-1") != null);
    try testing.expect(std.mem.indexOf(u8, a.detailOf("ENG-1").?.description, "umbrella") != null);
    try testing.expect(std.mem.indexOf(u8, a.status, "5 ticket") != null);

    // Opening ENG-2 fetches its pull requests, once.
    try a.key("j");
    try testing.expectEqualStrings("ENG-2", t.selected().?.key);
    const before = w.store.requests;
    try a.key("l");
    try testing.expectEqual(@as(usize, 2), t.state.prsOf("ENG-2").?.len);
    try testing.expect(w.store.requests > before);
    const after = w.store.requests;
    try a.key("h");
    try a.key("l");
    try testing.expectEqual(after, w.store.requests);
}

test "a failed refresh drops the PR cache with the arena it points into" {
    const gpa = testing.allocator;
    const w = try Wired.start(gpa);
    defer w.stop(gpa);
    const a = &w.app;
    a.cols = 120;
    a.rows = 30;
    try a.refresh();
    const t = a.tab().?;
    try a.key("j");
    try a.key("l");
    try testing.expect(t.state.prsOf("ENG-2") != null);

    // The next refresh fails — after the tab's arena has already been
    // reset. The PR lists live on that arena, so a cache that survives
    // is a map of dangling slices, and the next `rebuild` walks them.
    w.store.fail_with = 503;
    try a.refresh();
    try testing.expect(t.err != null);
    try testing.expect(t.state.prsOf("ENG-2") == null);
    try testing.expectEqual(@as(usize, 0), t.issues.len);
    try testing.expectEqual(@as(usize, 0), t.rows.len);
    // Painting and moving after the failure touch nothing freed.
    try a.rebuild(t);
    try a.key("j");
    try a.key("l");
    try testing.expectEqual(@as(usize, 0), t.rows.len);

    // And it recovers: the folds the user chose are still theirs.
    w.store.fail_with = null;
    try a.refresh();
    try testing.expectEqual(@as(usize, 5), t.issues.len);
    try testing.expect(t.err == null);
}

test "an action against a real server changes the ticket and the next refresh shows it" {
    const gpa = testing.allocator;
    const w = try Wired.start(gpa);
    defer w.stop(gpa);
    const a = &w.app;
    a.cols = 120;
    a.rows = 30;
    try a.refresh();
    const t = a.tab().?;

    // `t` opens the workflow the server offers for ENG-1.
    try a.key("t");
    try testing.expectEqual(Mode.picker, a.overlay.mode());
    try testing.expectEqualStrings("ENG-1", a.overlay.picker.key);
    try testing.expectEqual(@as(usize, 3), a.overlay.picker.items.len);
    // Enter asks first — nothing has moved yet.
    try a.key("enter");
    try testing.expectEqual(Mode.confirm, a.overlay.mode());
    try testing.expect(std.mem.indexOf(u8, a.overlay.confirm.message, "ENG-1") != null);
    try testing.expectEqualStrings("In Progress", w.store.find("ENG-1").?.status);
    // `n` leaves it alone.
    try a.key("n");
    try testing.expectEqualStrings("In Progress", w.store.find("ENG-1").?.status);
    // `y` moves it, and the refresh that follows shows the new status.
    try a.key("t");
    try a.key("enter");
    try a.key("y");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expect(!std.mem.eql(u8, "In Progress", w.store.find("ENG-1").?.status));
    try testing.expectEqualStrings(w.store.find("ENG-1").?.status, t.issues[0].status);
    // The outcome line survives the refresh that follows it.
    try testing.expect(std.mem.indexOf(u8, a.status, "ENG-1") != null);

    // A comment posts and comes back on the detail without a manual refresh.
    try a.key("c");
    for ("picking this up") |c| try a.key(&[_]u8{c});
    try a.key("ctrl+s");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expect(std.mem.indexOf(u8, a.status, "commented on ENG-1") != null);
    const d = a.detailOf("ENG-1").?;
    try testing.expect(std.mem.indexOf(u8, d.comments[d.comments.len - 1].body, "picking this up") != null);

    // Creating a ticket adds it to the next refresh.
    try a.key("n");
    a.overlay.form.focus = .summary;
    for ("From the pane") |c| try a.key(&[_]u8{c});
    try a.key("ctrl+s");
    try testing.expectEqual(Mode.list, a.overlay.mode());
    try testing.expect(std.mem.indexOf(u8, a.status, "created ENG-91") != null);
    try testing.expectEqual(@as(usize, 6), t.issues.len);
}

test "a refusal from the server lands on the status line in Jira's own words" {
    const gpa = testing.allocator;
    const w = try Wired.start(gpa);
    defer w.stop(gpa);
    const a = &w.app;
    a.cols = 120;
    a.rows = 30;
    // A bad credential: the pane says what Jira said, not a number.
    var bad = jira.Client.init(gpa, testing.io, a.cfg.jira.url, "Basic bm9wZQ==", .v3, a.cfg.jira.rate);
    bad.sleep_enabled = false;
    a.client = bad;
    try a.refresh();
    const t = a.tab().?;
    try testing.expect(t.err != null);
    try testing.expect(std.mem.indexOf(u8, t.err.?, "must be authenticated") != null);
    try testing.expect(std.mem.indexOf(u8, a.status, "must be authenticated") != null);
}

test "with no tabs at all the pane still quits, and does not index into nothing" {
    var a = App.init(testing.allocator, testing.io);
    defer a.deinit();
    try a.openTabs();
    try testing.expect(a.tab() == null);
    try a.key("j");
    try a.key("enter");
    try a.key("t");
    try a.key("?");
    try testing.expectEqual(Mode.help, a.overlay.mode());
    try a.key("esc");
    try a.key("q");
    try testing.expect(a.done);
}
