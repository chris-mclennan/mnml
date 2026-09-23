//! SEARCH — Rust's activity-bar section (`draw_search_section` /
//! `search_section_*` in `app/grep.rs`), on `ListPanel`: a query
//! field, the `16 hits (git grep)` status row naming the backend, the
//! hits by file — the file a fold header, every hit `line:col  text`
//! — Enter or a click opening the file at the line, the row menu, the
//! `Aa` / `\b` / `.*` flags, the refresh chip, Esc clearing the query.
//!
//! The run is `grep.zig`'s worker with `git grep` first: the tracked
//! files only, so `.gitignore` and untracked scratch never answer
//! (Rust's 16 hits where the pane's walk found 437); a workspace that
//! is no repo falls through to `rg`, then the `.gitignore`-honouring
//! walk — the status row says which. The grep pane (`Pane.grep`) is
//! Zig's own door, reached by *Open as pane*, where the replace and the
//! per-hit toggles live.
//!
//! D1: a batch (`grep.Result`) is owned by the event; `handle` copies
//! its hits onto the snapshot arena. D3: one `Io.Group`, cancel-on-
//! rerun, stale batches dropped by generation. D5: `table`. D6:
//! `ListPanel(Row)` with `prelude_rows` for the query and status rows;
//! every target registered where it paints.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("../core/alloc.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const chip = @import("../ui/chip.zig");
const text_field = @import("../ui/text_field.zig");
const filter_input = @import("../ui/filter_input.zig");
const view = @import("../ui/search_section_view.zig");
const grep = @import("grep.zig");
const find_mod = @import("find.zig");
const jobs = @import("jobs.zig");
const side = @import("side.zig");
const activity_bar = @import("activity_bar.zig");
const cmd_view = @import("cmd_view.zig");

pub const Flag = view.Flag;
pub const Row = view.Row;
pub const Panel = list_panel.ListPanel(Row);

pub const table = .{
    .@"view.activity_search" = &activitySearch,
    .@"search.toggle_case_sensitive" = &toggleCaseCmd,
    .@"search.toggle_whole_word" = &toggleWholeWordCmd,
    .@"search.toggle_regex" = &toggleRegexCmd,
    .@"search.refresh" = &refreshCmd,
    .@"search.open" = &openCmd,
    .@"search.open_split" = &openSplitCmd,
    .@"search.copy_path" = &copyPathCmd,
    .@"search.copy_line" = &copyLineCmd,
    .@"search.open_pane" = &openPaneCmd,
};

/// Rows the panel leaves under its header for the query pill, the
/// status and their air: the pill, a blank row, `N hits (…)`, a blank
/// row.
/// // changed (panel-consistency): the pill was the THIRD row with a
/// blank above it; every other section puts its input on row 1 with
/// the air below. The count is unchanged, so the list starts where it
/// did.
pub const prelude_rows: u16 = 4;

/// Rows inside the prelude, from the header down.
const query_row: u16 = 1;
const status_row: u16 = 3;

pub const Group = struct {
    rel: []const u8,
    /// Index of the first hit of this file in `hits`.
    first: u32,
    count: u32,
    collapsed: bool,
};

const RowRef = union(enum) { file: u32, hit: u32 };

pub const State = struct {
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    /// Heap-allocated: the worker holds it past the state's moves.
    abort: *grep.Abort,
    generation: u32 = 0,
    query: text_field.Buf = .empty,
    caret: usize = 0,
    /// The keys go into the query; else to the rows.
    query_focused: bool = false,
    /// The query the hits answer — owned; the worker reads it, so a
    /// rerun cancels the worker before the swap. Null: nothing ran.
    ran: ?[]u8 = null,
    flags: grep.Flags = .{},
    backend: ?grep.Backend = null,
    hits: std.ArrayListUnmanaged(grep.Hit) = .empty,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    rows: std.ArrayListUnmanaged(RowRef) = .empty,
    /// Files folded shut, by rel path (owned keys).
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    list: Panel.State = .{},
    loading: bool = false,
    truncated: bool = false,
    /// Files the last run left unread for their size.
    skipped_big: u32 = 0,
    /// The last run's reason for nothing.
    err: ?[]u8 = null,

    pub fn init(gpa: Allocator) Allocator.Error!State {
        const abort = try gpa.create(grep.Abort);
        abort.* = .{};
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .abort = abort };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.abort.generation.store(std.math.maxInt(u32), .release);
        self.group.cancel(io);
        gpa.destroy(self.abort);
        self.query.deinit(gpa);
        if (self.ran) |q| gpa.free(q);
        self.hits.deinit(gpa);
        self.groups.deinit(gpa);
        self.rows.deinit(gpa);
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.collapsed.deinit(gpa);
        self.list.deinit(gpa);
        if (self.err) |e| gpa.free(e);
        self.snapshot.deinit();
    }

    pub fn queryText(self: *const State) []const u8 {
        return self.query.items;
    }

    /// The hit under the cursor, if the cursor row is one.
    pub fn selectedHit(self: *const State) ?grep.Hit {
        if (self.list.cursor >= self.rows.items.len) return null;
        return switch (self.rows.items[self.list.cursor]) {
            .hit => |i| self.hits.items[i],
            .file => null,
        };
    }

    /// The group the cursor row belongs to (a hit's file, or the file row).
    fn selectedGroup(self: *const State) ?u32 {
        if (self.list.cursor >= self.rows.items.len) return null;
        return switch (self.rows.items[self.list.cursor]) {
            .file => |g| g,
            .hit => |h| blk: {
                for (self.groups.items, 0..) |grp, i| if (h >= grp.first and h < grp.first + grp.count) break :blk @intCast(i);
                break :blk null;
            },
        };
    }

    /// Groups and rows from `hits` and the folds.
    fn rebuild(self: *State, gpa: Allocator) Allocator.Error!void {
        self.groups.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.hits.items.len) {
            const rel = self.hits.items[i].rel;
            var j = i;
            while (j < self.hits.items.len and std.mem.eql(u8, self.hits.items[j].rel, rel)) : (j += 1) {}
            const g: u32 = @intCast(self.groups.items.len);
            const collapsed = self.collapsed.contains(rel);
            try self.groups.append(gpa, .{ .rel = rel, .first = @intCast(i), .count = @intCast(j - i), .collapsed = collapsed });
            try self.rows.append(gpa, .{ .file = g });
            if (!collapsed) {
                var k = i;
                while (k < j) : (k += 1) try self.rows.append(gpa, .{ .hit = @intCast(k) });
            }
            i = j;
        }
        if (self.list.cursor >= self.rows.items.len) self.list.cursor = self.rows.items.len -| 1;
    }

    fn setCollapsed(self: *State, gpa: Allocator, rel: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (self.collapsed.contains(rel)) return;
            const key = try gpa.dupe(u8, rel);
            errdefer gpa.free(key);
            try self.collapsed.put(gpa, key, {});
        } else if (self.collapsed.fetchRemove(rel)) |kv| gpa.free(kv.key);
    }

    /// A new run: everything from the last one goes, the folds too.
    fn clearResults(self: *State, gpa: Allocator) void {
        self.hits.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.collapsed.clearRetainingCapacity();
        self.snapshot.reset();
        self.list.cursor = 0;
        self.list.scroll = 0;
        self.truncated = false;
        self.skipped_big = 0;
        self.backend = null;
        if (self.err) |e| gpa.free(e);
        self.err = null;
    }
};

// ─── show / run ─────────────────────────────────────────────────────────

pub fn isShown(app: *const App) bool {
    return side.isShown(app, .search);
}

/// `view.activity_search`: the section in its column, the keys in the
/// query (Rust: the click focuses the input).
fn activitySearch(app: *App) CommandError!void {
    activity_bar.enter(app, .search);
    side.place(app, .search, true);
    app.search_section.query_focused = true;
    app.needs_render = true;
}

/// Cancel the run in flight, bump the generation, start the query on
/// the worker — `git grep` first. An empty query clears the hits.
pub fn run(app: *App) CommandError!void {
    const st = &app.search_section;
    const q = std.mem.trim(u8, st.query.items, " \t");
    st.abort.generation.store(std.math.maxInt(u32), .release);
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.abort.generation.store(st.generation, .release);
    st.clearResults(app.gpa);
    if (st.ran) |old| app.gpa.free(old);
    st.ran = null;
    st.loading = false;
    app.needs_render = true;
    if (q.len == 0) return jobs.dropKeyed(app, .search, grep.section_target);
    st.ran = try app.gpa.dupe(u8, q);
    st.loading = true;
    var flags = st.flags;
    if (!flags.case_sensitive and find_mod.hasUpper(q)) flags.case_sensitive = true;
    st.group.concurrent(app.io, grep.worker, .{ app.events, app.io, app.gpa, @as([]const u8, app.workspace), @as([]const u8, st.ran.?), flags, st.generation, grep.section_target, st.abort, true }) catch |err| {
        st.loading = false;
        return app.diag.fail(app.frame.allocator(), "search: could not start the worker: {s}", .{@errorName(err)});
    };
    _ = try jobs.begin(app, .{ .kind = .search, .key = grep.section_target, .label = try std.fmt.allocPrint(app.frame.allocator(), "search \"{s}\"", .{q}), .cancel = &cancelRun, .drop_superseded = true });
}

/// The JOBS list's Cancel: stop the walk where it is; the hits so far stay.
fn cancelRun(app: *App, key: u64) void {
    const st = &app.search_section;
    st.abort.generation.store(std.math.maxInt(u32), .release);
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.abort.generation.store(st.generation, .release);
    st.loading = false;
    jobs.endKeyed(app, .search, key, jobs.Outcome.cancel(null));
    app.needs_render = true;
}

/// A batch from the worker (D1: destroyed on every path). A stale
/// generation is dropped whole.
pub fn handle(app: *App, result: *grep.Result) Allocator.Error!void {
    const st = &app.search_section;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    const arena = st.snapshot.allocator();
    for (result.hits.items) |h| {
        try st.hits.append(app.gpa, .{
            .path = try arena.dupe(u8, h.path),
            .rel = try arena.dupe(u8, h.rel),
            .line = h.line,
            .col = h.col,
            .len = h.len,
            .text = try arena.dupe(u8, h.text),
            .text_off = h.text_off,
            .ccol = h.ccol,
        });
    }
    st.backend = result.backend;
    if (result.truncated) st.truncated = true;
    st.skipped_big += result.skipped_big;
    if (result.err) |e| {
        if (st.err) |old| app.gpa.free(old);
        st.err = try app.gpa.dupe(u8, e);
    }
    const first_batch = st.list.cursor == 0 and st.rows.items.len == 0;
    try st.rebuild(app.gpa);
    // Rust's `search_selected = 0` is the first HIT: the selection
    // starts under the first file header, not on it.
    if (first_batch and st.rows.items.len > 1) st.list.cursor = 1;
    if (result.done) {
        st.loading = false;
        // Every finished search is the quickfix list (`:cnext` walks it).
        if (st.err == null) try @import("quickfix.zig").fromGrepHits(app, st.hits.items, grep.section_target);
        const n = st.hits.items.len;
        const words = try std.fmt.allocPrint(app.frame.allocator(), "{d} match{s}{s}", .{ n, if (n == 1) "" else "es", if (st.truncated) " (capped)" else "" });
        jobs.endKeyed(app, .search, grep.section_target, if (st.err) |e| jobs.Outcome.fail(e) else jobs.Outcome.done(words));
    } else jobs.progress(app, .search, grep.section_target, try std.fmt.allocPrint(app.frame.allocator(), "{d} so far", .{st.hits.items.len}));
    app.needs_render = true;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return run(app);
}

/// A flag flips and the query reruns (Rust's `search_section_toggle_*`).
/// With the section closed the ids keep their pane meaning
/// (`grep.paneToggle*`), so `:set`-style scripts and the find bar's
/// case slot behave as before.
fn toggleFlag(app: *App, f: Flag) CommandError!void {
    const st = &app.search_section;
    switch (f) {
        .case_sensitive => {
            st.flags.case_sensitive = !st.flags.case_sensitive;
            app.search_case = st.flags.case_sensitive;
        },
        .whole_word => st.flags.whole_word = !st.flags.whole_word,
        .regex => st.flags.regex = !st.flags.regex,
    }
    app.toast("search: {s} {s}", .{ switch (f) {
        .case_sensitive => "case-sensitive",
        .whole_word => "whole-word",
        .regex => "regex",
    }, if (f.isOn(st.flags)) "on" else "off" });
    if (st.ran != null) try run(app);
    app.needs_render = true;
}

fn toggleCaseCmd(app: *App) CommandError!void {
    if (!isShown(app)) return grep.paneToggleCase(app);
    return toggleFlag(app, .case_sensitive);
}

fn toggleWholeWordCmd(app: *App) CommandError!void {
    if (!isShown(app)) return grep.paneToggleWholeWord(app);
    return toggleFlag(app, .whole_word);
}

fn toggleRegexCmd(app: *App) CommandError!void {
    if (!isShown(app)) return grep.paneToggleRegex(app);
    return toggleFlag(app, .regex);
}

/// `search.open`: the hit under the cursor opens at its line; a file
/// row folds / unfolds.
fn openCmd(app: *App) CommandError!void {
    return activateRow(app, false);
}

fn openSplitCmd(app: *App) CommandError!void {
    return activateRow(app, true);
}

fn activateRow(app: *App, beside: bool) CommandError!void {
    const st = &app.search_section;
    if (st.list.cursor >= st.rows.items.len) return app.diag.fail(app.frame.allocator(), "search: nothing selected", .{});
    switch (st.rows.items[st.list.cursor]) {
        .file => |g| try toggleGroup(app, g),
        .hit => |h| {
            @import("quickfix.zig").noteGrepHit(app, grep.section_target, h);
            try openHit(app, st.hits.items[h], beside);
        },
    }
}

/// Open the hit's file in an editor at its line and column (an editor
/// even for markdown — a preview has no cursor to place). `beside`:
/// in a new split to the right of the active pane (`:vs path`).
pub fn openHit(app: *App, h: grep.Hit, beside: bool) CommandError!void {
    const arena = app.frame.allocator();
    // The hit borrows the snapshot; hold frame copies past the open.
    const path = try arena.dupe(u8, h.path);
    const rel = try arena.dupe(u8, h.rel);
    const line = h.line;
    const col = h.col;
    try app.noteRecent(path);
    const cur = app.active;
    const eid = app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (beside) if (cur) |c| if (c != eid) {
        app.setActive(c);
        try cmd_view.splitWith(app, .vertical, eid);
    };
    if (app.panes.editor(eid)) |e| {
        const ed = e.buf.editor;
        ed.anchor = null;
        ed.placeCursorByte(@min(@as(usize, line) -| 1, ed.lineCount() -| 1), col);
        ed.goal_col = null;
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    }
    app.showPane(eid);
    app.focus = .{ .pane = eid };
    app.needs_render = true;
}

fn copyPathCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const st = &app.search_section;
    if (st.list.cursor >= st.rows.items.len) return app.diag.fail(arena, "search: nothing selected", .{});
    const text = switch (st.rows.items[st.list.cursor]) {
        .file => |g| st.groups.items[g].rel,
        .hit => |h| try std.fmt.allocPrint(arena, "{s}:{d}", .{ st.hits.items[h].rel, st.hits.items[h].line }),
    };
    try app.clipboard.set(text, false);
    app.toast("copied {s}", .{text});
}

fn copyLineCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const h = app.search_section.selectedHit() orelse return app.diag.fail(arena, "search: the cursor is on a file row", .{});
    const text = std.mem.trim(u8, h.text, " \t");
    try app.clipboard.set(text, false);
    app.toast("copied the line", .{});
}

/// `search.open_pane`: the query as a grep pane (Zig's door — the
/// replace and the per-hit toggles), or the pane's prompt with nothing
/// to run.
fn openPaneCmd(app: *App) CommandError!void {
    const st = &app.search_section;
    const q = std.mem.trim(u8, st.query.items, " \t");
    if (q.len == 0) return grep.openQueryPrompt(app);
    const owned = try app.frame.allocator().dupe(u8, q);
    try grep.runGrep(app, owned);
    if (grep.find(app)) |id| if (app.panes.get(id)) |p| {
        p.grep.flags = st.flags;
    };
}

fn toggleGroup(app: *App, g: u32) Allocator.Error!void {
    const st = &app.search_section;
    const grp = st.groups.items[g];
    try st.setCollapsed(app.gpa, grp.rel, !grp.collapsed);
    try st.rebuild(app.gpa);
    app.needs_render = true;
}

/// `←` / `h` folds the cursor's file (from a hit, its file); `→` / `l`
/// opens it.
fn fold(app: *App, on: bool) Allocator.Error!void {
    const st = &app.search_section;
    const g = st.selectedGroup() orelse return;
    const rel = st.groups.items[g].rel;
    if (st.collapsed.contains(rel) == on) return;
    try st.setCollapsed(app.gpa, rel, on);
    try st.rebuild(app.gpa);
    for (st.rows.items, 0..) |r, i| if (r == .file and r.file == g) {
        st.list.cursor = i;
        break;
    };
    app.needs_render = true;
}

// ─── keys ───────────────────────────────────────────────────────────────

/// Keys while the section has focus. In the query: Esc clears it (then
/// a second Esc goes to the rows), Enter runs it — or, empty with hits
/// listed, opens the selected hit (Rust) — ↑ / ↓ move the selection,
/// the rest edits the text. On the rows: `/` focuses the query, the
/// list's own keys move and Enter activates, `h` / `l` and the arrows
/// fold, `r` reruns, `y` copies `path:line`, `o` opens the pane, Esc
/// goes back to the active pane.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.search_section;
    app.needs_render = true;
    if (st.query_focused) {
        switch (k.code) {
            .esc => {
                if (st.query.items.len > 0) {
                    st.query.clearRetainingCapacity();
                    st.caret = 0;
                } else st.query_focused = false;
                return true;
            },
            .enter => {
                if (std.mem.trim(u8, st.query.items, " \t").len == 0 and st.hits.items.len > 0) {
                    runToast(app, activateRow(app, false));
                } else runToast(app, run(app));
                return true;
            },
            .up => {
                st.list.cursor -|= 1;
                return true;
            },
            .down => {
                st.list.cursor = @min(st.list.cursor + 1, st.rows.items.len -| 1);
                return true;
            },
            else => {},
        }
        return switch (try text_field.handleKey(&st.query, &st.caret, app.gpa, k)) {
            .ignored => false,
            .moved, .changed => true,
        };
    }
    if (k.code == .char and k.code.char == '/' and !k.mods.ctrl and !k.mods.alt and !k.mods.super) {
        st.query_focused = true;
        return true;
    }
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed, .filter_changed => return true,
        .activate => |i| {
            st.list.cursor = i;
            runToast(app, activateRow(app, false));
            return true;
        },
        .new_activate, .ignored => {},
    }
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .left => try fold(app, true),
        .right => try fold(app, false),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'h' => try fold(app, true),
                'l' => try fold(app, false),
                'r' => runToast(app, run(app)),
                'y' => runToast(app, copyPathCmd(app)),
                'o' => runToast(app, openPaneCmd(app)),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

/// A command reached outside `command.run`: toast the reason the same way.
fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("search: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .search };
    app.needs_render = true;
}

/// A row: a left press selects — a hit opens at its line (Rust: the
/// click opens), a file row folds / unfolds; a right press selects and
/// opens the row menu.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.search_section;
    if (m.kind != .press or idx >= st.rows.items.len) return;
    focusPanel(app);
    st.query_focused = false;
    st.list.cursor = idx;
    st.list.on_new = false;
    if (m.button == .right) return openRowMenu(app, m.x, m.y);
    if (m.button != .left) return;
    runToast(app, activateRow(app, false));
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.search_section;
    if (m.kind != .press or idx >= st.rows.items.len) return;
    focusPanel(app);
    st.query_focused = false;
    st.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

/// The refresh chip reruns; its right press too (there is no scan to
/// keep fresh — the query runs when asked).
pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => runToast(app, run(app)),
        .sort, .new, .view, .history => {},
    }
}

/// A header flag's press.
pub fn flagMouse(app: *App, f: Flag) Allocator.Error!void {
    if (!isShown(app)) return;
    runToast(app, toggleFlag(app, f));
}

/// A press on the query row focuses it.
pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.search_section.query_focused = true;
}

pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.search_section;
    const total = st.rows.items.len;
    st.list.cursor = if (down) @min(st.list.cursor + rows, total -| 1) else st.list.cursor -| rows;
    app.needs_render = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.search_section;
    const total = st.rows.items.len;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.list.cursor = @min(off * total / bar.h, total - 1);
        },
        else => {},
    }
}

/// The row's menu, titled by the row — a hit's `path:line`, a file's
/// path: open, open to the side, copy path / line, then refresh and
/// the pane door.
fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.search_section;
    const arena = app.frame.allocator();
    if (st.list.cursor >= st.rows.items.len) return;
    const is_hit = st.rows.items[st.list.cursor] == .hit;
    const title: []const u8 = switch (st.rows.items[st.list.cursor]) {
        .hit => |h| try std.fmt.allocPrint(arena, "{s}:{d}", .{ st.hits.items[h].rel, st.hits.items[h].line }),
        .file => |g| st.groups.items[g].rel,
    };
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    if (is_hit) {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Open", .action = .{ .command = .@"search.open" } },
            .{ .label = "Open to the side", .action = .{ .command = .@"search.open_split" } },
            .{ .label = "Copy path:line", .action = .{ .command = .@"search.copy_path" }, .separator_before = true },
            .{ .label = "Copy line", .action = .{ .command = .@"search.copy_line" } },
        });
    } else {
        try rows.appendSlice(app.gpa, &.{
            .{ .label = "Fold / unfold", .action = .{ .command = .@"search.open" } },
            .{ .label = "Copy path", .action = .{ .command = .@"search.copy_path" }, .separator_before = true },
        });
    }
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "Search again", .action = .{ .command = .@"search.refresh" }, .separator_before = true },
        .{ .label = "Open as pane", .action = .{ .command = .@"search.open_pane" } },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(title, owned, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

/// The status row's words: Rust's, the backend named once a run has
/// answered.
pub fn statusText(ui: Ui, st: *const State) []const u8 {
    if (st.loading) return if (ui.ascii) " searching..." else " searching\u{2026}";
    if (st.ran == null) return if (st.query_focused) " type \u{b7} Enter to run \u{b7} Esc clears" else " / focuses the query \u{b7} Enter runs it";
    if (st.err) |e| return ui.fmt(" {s}: {s}", .{ if (st.backend) |b| b.label() else "search", e });
    const n = st.hits.items.len;
    const big = grep.bigNote(ui.arena, st.skipped_big);
    if (st.truncated) return ui.fmt(" {d}+ hits, capped ({s}){s}", .{ n, if (st.backend) |b| b.label() else "search", big });
    return ui.fmt(" {d} hit{s} ({s}){s}", .{ n, if (n == 1) "" else "s", if (st.backend) |b| b.label() else "search", big });
}

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.search_section;
    const rows = try ui.arena.alloc(Row, st.rows.items.len);
    for (st.rows.items, 0..) |r, i| rows[i] = switch (r) {
        .file => |g| .{ .file = .{ .rel = st.groups.items[g].rel, .count = st.groups.items[g].count, .collapsed = st.groups.items[g].collapsed } },
        .hit => |h| .{ .hit = st.hits.items[h] },
    };
    const focused = ui.isFocused(.{ .panel = .search });
    // Rust lists nothing under the status row when there are no hits.
    _ = Panel.draw(&st.list, ui, area, .{
        .panel = .search,
        .label = "SEARCH",
        .rows = rows,
        .paintRow = view.paintRow,
        .has_kebab = true,
        .empty = .{ .message = "" },
        .show_filter = false,
        .show_refresh = true,
        .prelude_rows = prelude_rows,
    });
    if (area.h > 0) view.drawFlags(ui, area.row(0), st.flags, ui.width(chip.refreshIcon(ui.ascii)));
    // The query is the shared filter pill — the same widget, glyph and
    // grey band SESSIONS and every other section paint on this row.
    if (area.h > query_row) {
        const caret = filter_input.draw(ui, area.row(query_row), .{
            .panel = .search,
            .text = st.query.items,
            .caret = st.caret,
            .focused = st.query_focused and focused,
            .bg = ui.theme.panel_bg,
            .noun = "search",
        });
        if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    }
    if (area.h > status_row) view.drawStatus(ui, area.row(status_row), statusText(ui, st));
    if (st.loading) list_panel.paintSpinner(ui, area, "SEARCH", app.now_ms);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

/// A seeded repo: three tracked files with `alpha`, an ignored log with
/// it, an untracked scratch file with it — `git grep` answers 5, the
/// walk would answer 6 (the scratch), a walk without the `.gitignore`
/// 9.
const Fixture = struct {
    app: App,
    tmp: std.testing.TmpDir,
    root: []u8,

    fn git(root: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, &.{ "git", "-C", root, "-c", "user.email=test@mnml.dev", "-c", "user.name=test", "-c", "commit.gpgsign=false" });
        try argv.appendSlice(t.allocator, args);
        var child = try std.process.spawn(t.io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        const term = try child.wait(t.io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "src/deep");
        try tmp.dir.createDirPath(t.io, "build");
        try tmp.dir.writeFile(t.io, .{ .sub_path = "src/a.zig", .data = "const alpha = 1;\nconst beta = alpha + alpha;\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "src/deep/b.txt", .data = "Alpha at the top\nnothing here\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "# alpha\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
        try git(root, &.{ "init", "-q", "-b", "main" });
        try git(root, &.{ "add", "." });
        try git(root, &.{ "commit", "-q", "-m", "seed" });
        // After the commit: an ignored log and an untracked scratch file.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "build/out.log", .data = "alpha alpha alpha\n" });
        try tmp.dir.writeFile(t.io, .{ .sub_path = "scratch.txt", .data = "alpha untracked\n" });
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
        errdefer app.deinit();
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// Tick until the run lands (or `max` ticks pass).
    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            try f.app.tick(App.nowMs(t.io));
            if (!f.app.search_section.loading) return;
            t.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
        return error.SearchDidNotSettle;
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return screen_mod.toTestText(t.allocator, &f.app.screen);
    }

    fn typeQuery(f: *Fixture, q: []const u8) !void {
        for (q) |c| try f.app.handle(.{ .key = Key.char(c) });
    }
};

fn hasGit() bool {
    var child = std.process.spawn(t.io, .{ .argv = &.{ "git", "--version" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(t.io) catch return false;
    return term == .exited and term.exited == 0;
}

test "view.activity_search: the section takes the column with the query focused; Enter runs git grep — the tracked files only, the header names it; the pane door keeps the walk" {
    if (!hasGit()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try app.openScratch();
    try command.run(app, .{ .static = .@"view.activity_search" });
    try t.expect(side.isShown(app, .search));
    try t.expect(app.focus == .panel and app.focus.panel == .search);
    try t.expect(app.search_section.query_focused);
    try t.expectEqual(activity_bar.Section.search, activity_bar.active(app));
    var txt = try f.screen();
    try t.expect(std.mem.indexOf(u8, txt, " SEARCH") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Aa \\b .*") != null);
    // The input is the shared filter pill, not a bare ` / ` run: the
    // magnify glyph and the `type to search…` placeholder.
    try t.expect(std.mem.indexOf(u8, txt, "\u{F0349} type to search\u{2026}") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Enter to run") != null);
    t.allocator.free(txt);
    try f.typeQuery("alpha");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    const st = &app.search_section;
    try t.expectEqual(grep.Backend.git_grep, st.backend.?);
    // One hit per MATCH, as the walk and rg count (Rust's git grep
    // counts lines): 3 in src/a.zig, 1 in b.txt, 1 in notes.md; the log
    // and the scratch never.
    try t.expectEqual(@as(usize, 5), st.hits.items.len);
    try t.expectEqual(@as(usize, 3), st.groups.items.len);
    try t.expectEqual(@as(usize, 8), st.rows.items.len);
    for (st.hits.items) |h| {
        try t.expect(std.mem.indexOf(u8, h.rel, ".log") == null);
        try t.expect(std.mem.indexOf(u8, h.rel, "scratch") == null);
    }
    txt = try f.screen();
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, " 5 hits (git grep)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "\u{F0349} alpha") != null);
    try t.expect(std.mem.indexOf(u8, txt, "src/a.zig") != null);
    try t.expect(std.mem.indexOf(u8, txt, "1:7  const alpha = 1;") != null);
    // The shape every section shares: the caps title, the input pill,
    // a BLANK row under it, the status, a blank row, the rows. The
    // pill was the third row with the blank above it — the deviation
    // the panel-consistency pass fixed.
    var lines = std.mem.splitScalar(u8, txt, '\n');
    var y: usize = 0;
    var header_y: ?usize = null;
    while (lines.next()) |l| : (y += 1) if (std.mem.indexOf(u8, l, " SEARCH") != null and header_y == null) {
        header_y = y;
    };
    lines.reset();
    y = 0;
    while (lines.next()) |l| : (y += 1) {
        if (y == header_y.? + 1) {
            try t.expect(std.mem.indexOf(u8, l, "\u{F0349} alpha") != null);
        } else if (y == header_y.? + 2) {
            // The air under the pill: neither the input nor the status.
            try t.expect(std.mem.indexOf(u8, l, "\u{F0349}") == null);
            try t.expect(std.mem.indexOf(u8, l, "hits (") == null);
        } else if (y == header_y.? + 3) {
            try t.expect(std.mem.indexOf(u8, l, "5 hits (git grep)") != null);
        } else if (y == header_y.? + 5) {
            try t.expect(std.mem.indexOf(u8, l, "src/a.zig") != null or std.mem.indexOf(u8, l, "notes.md") != null or std.mem.indexOf(u8, l, "b.txt") != null);
        }
    }
    // The pane door: the same query in a grep pane, which walks (rg / the walk — never git).
    try command.run(app, .{ .static = .@"search.open_pane" });
    const id = grep.find(app).?;
    try t.expectEqualStrings("alpha", app.panes.get(id).?.grep.query);
    // Let the pane's run land before the app goes: a batch posted
    // while the queue closes is a leak the full run reports.
    var i: usize = 0;
    while (i < 400 and app.panes.get(id).?.grep.loading) : (i += 1) {
        try app.tick(App.nowMs(t.io));
        t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try t.expect(!app.panes.get(id).?.grep.loading);
}

test "git grep past the cap: the run finishes (git is stopped, not waited on with the pipe full) and the header says it capped" {
    if (!hasGit()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // 12 000 matching lines, ~1.6 MB of `git grep` output: more than
    // the reader's buffer plus the pipe.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(t.allocator);
    for (0..12_000) |i| try big.print(t.allocator, "alpha {d:0>6} padding padding padding padding padding padding padding padding padding padding padding\n", .{i});
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "big.txt", .data = big.items });
    try Fixture.git(f.root, &.{ "add", "big.txt" });
    try Fixture.git(f.root, &.{ "commit", "-q", "-m", "big" });
    _ = try app.openScratch();
    try command.run(app, .{ .static = .@"view.activity_search" });
    try f.typeQuery("alpha");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(2000);
    const st = &app.search_section;
    try t.expect(st.truncated);
    try t.expectEqual(grep.max_hits, st.hits.items.len);
    const txt = try f.screen();
    defer t.allocator.free(txt);
    // At the stock column width the words that matter come first.
    try t.expect(std.mem.indexOf(u8, txt, " 5000+ hits, capped") != null);
}

test "the walk parity: the same seed without a repository answers through the walk with the .gitignore honoured, and the header says so" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    // No repository: git grep exits 128 and the worker moves on. The
    // test's PATH may hold rg (which also honours the .gitignore);
    // either way the ignored log is out and the header names the tool.
    try f.tmp.dir.deleteTree(t.io, ".git");
    try command.run(app, .{ .static = .@"view.activity_search" });
    try f.typeQuery("alpha");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    const st = &app.search_section;
    try t.expect(st.backend.? != .git_grep);
    // The untracked scratch file counts now: 6 hits (rg reports each match; the walk too — a.zig's second line has two).
    try t.expect(st.hits.items.len >= 6);
    for (st.hits.items) |h| try t.expect(std.mem.indexOf(u8, h.rel, ".log") == null);
    const txt = try f.screen();
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, ui_label(st.backend.?)) != null);
}

fn ui_label(b: grep.Backend) []const u8 {
    return switch (b) {
        .git_grep => "(git grep)",
        .rg => "(rg)",
        .walk => "(walk)",
    };
}

test "keys: Esc clears the query then leaves it; ↓ and Enter open the hit at its line; h folds the file and l opens it; the flags rerun; a click opens too" {
    if (!hasGit()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    _ = try app.openScratch();
    try command.run(app, .{ .static = .@"view.activity_search" });
    try f.typeQuery("alpha");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    const st = &app.search_section;
    try t.expectEqual(@as(usize, 8), st.rows.items.len);
    // The selection starts on the first hit (row 1, under its file
    // header — Rust's `search_selected = 0`); ↓ ↓ from the query moves
    // it past the next file header onto the second hit (row 3). Enter
    // with a query runs again — Esc clears, then Enter opens the
    // selected hit at its line and column.
    try t.expectEqual(@as(usize, 1), st.list.cursor);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try t.expectEqual(@as(usize, 3), st.list.cursor);
    try t.expect(st.rows.items[3] == .hit);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(usize, 0), st.query.items.len);
    try t.expect(st.query_focused);
    try app.handle(.{ .key = Key.named(.enter) });
    const e = app.activeEditor().?;
    try t.expect(std.mem.endsWith(u8, e.buf.doc.path.?, st.hits.items[1].rel));
    try t.expectEqual(@as(usize, st.hits.items[1].line - 1), e.buf.editor.currentLine());
    try t.expectEqual(@as(usize, st.hits.items[1].col), e.buf.editor.rowCol().col);
    try t.expect(app.focus == .pane);
    // Back in the section: a second Esc in the empty query goes to the rows; h folds the file, l opens it.
    side.focusSection(app, .search);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!st.query_focused);
    st.list.cursor = 1;
    try app.handle(.{ .key = Key.char('h') });
    try t.expectEqual(@as(usize, 8 - st.groups.items[0].count), st.rows.items.len);
    try t.expectEqual(@as(usize, 0), st.list.cursor);
    try t.expect(st.rows.items[0] == .file);
    try app.handle(.{ .key = Key.char('l') });
    try t.expectEqual(@as(usize, 8), st.rows.items.len);
    // `/` focuses the query again; typing edits it (the caret moves with ←).
    try app.handle(.{ .key = Key.char('/') });
    try t.expect(st.query_focused);
    try f.typeQuery("Alph");
    try app.handle(.{ .key = Key.named(.left) });
    try f.typeQuery("l");
    try t.expectEqualStrings("Alplh", st.query.items);
    try app.handle(.{ .key = Key.named(.esc) });
    try f.typeQuery("Alpha");
    // Smart case: an upper-case query is case-sensitive on its own — one hit.
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    try t.expectEqual(@as(usize, 1), st.hits.items.len);
    // The whole-word flag reruns: `alph` matches nothing whole.
    try app.handle(.{ .key = Key.named(.esc) });
    try f.typeQuery("alph");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    try t.expectEqual(@as(usize, 5), st.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_whole_word" });
    try t.expect(st.flags.whole_word);
    try f.settle(400);
    try t.expectEqual(@as(usize, 0), st.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_whole_word" });
    try f.settle(400);
    try t.expectEqual(@as(usize, 5), st.hits.items.len);
    // The case flag: `Aa` on with a lower-case query finds nothing upper.
    try command.run(app, .{ .static = .@"search.toggle_case_sensitive" });
    try t.expect(st.flags.case_sensitive);
    try t.expectEqual(true, app.search_case.?);
    try f.settle(400);
    try t.expectEqual(@as(usize, 4), st.hits.items.len);
    try command.run(app, .{ .static = .@"search.toggle_case_sensitive" });
    try f.settle(400);
    // A click on a hit row opens it; a right click opens the row menu titled by the hit.
    try app.render();
    var row_y: ?u16 = null;
    var yy: u16 = 0;
    while (yy < app.screen.height) : (yy += 1) if (app.hits.at(10, yy)) |h| if (h == .row and h.row.panel == .search and h.row.idx == 1) {
        row_y = yy;
    };
    try app.handle(.{ .mouse = .{ .x = 10, .y = row_y.?, .kind = .press, .button = .right } });
    try app.handle(.{ .mouse = .{ .x = 10, .y = row_y.?, .kind = .release, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Open", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Open to the side", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("Copy path:line", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("Copy line", app.overlay.menu.items[3].label);
    try t.expectEqualStrings("Open as pane", app.overlay.menu.items[5].label);
    try t.expect(std.mem.indexOf(u8, app.overlay.menu.title, ":") != null);
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .mouse = .{ .x = 10, .y = row_y.?, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = 10, .y = row_y.?, .kind = .release, .button = .left } });
    try t.expect(app.focus == .pane);
    const e2 = app.activeEditor().?;
    try t.expect(std.mem.endsWith(u8, e2.buf.doc.path.?, st.hits.items[0].rel));
    // The header flag chip: a press toggles the flag.
    try app.render();
    var chip_x: ?u16 = null;
    var chip_y: u16 = 0;
    yy = 0;
    while (yy < app.screen.height and chip_x == null) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < app.screen.width) : (xx += 1) if (app.hits.at(xx, yy)) |h| if (h == .search_chip and h.search_chip == .regex) {
            chip_x = xx;
            chip_y = yy;
            break;
        };
    }
    try app.handle(.{ .mouse = .{ .x = chip_x.?, .y = chip_y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = chip_x.?, .y = chip_y, .kind = .release, .button = .left } });
    try t.expect(st.flags.regex);
}

test "open to the side: the hit's file lands in a split beside the active pane" {
    if (!hasGit()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    const scratch = try app.openScratch();
    try command.run(app, .{ .static = .@"view.activity_search" });
    try f.typeQuery("nothing here");
    try app.handle(.{ .key = Key.named(.enter) });
    try f.settle(400);
    const st = &app.search_section;
    try t.expectEqual(@as(usize, 1), st.hits.items.len);
    st.list.cursor = 1;
    try command.run(app, .{ .static = .@"search.open_split" });
    const eid = app.active.?;
    try t.expect(eid != scratch);
    const layout = app.layouts.current();
    try t.expect(layout.leafOf(eid) != null and layout.leafOf(scratch) != null);
    try t.expect(layout.leafOf(eid).? != layout.leafOf(scratch).?);
    try t.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.currentLine());
}
