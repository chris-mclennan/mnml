//! The HTTP activity panel (`view.activity_http`): the seven sections of
//! the Rust sidebar — COLLECTIONS / ENVS / CHAINS / MOCKS / COOKIES /
//! RECENT / CAPTURED — as collapsible groups of one `ListPanel`, the way
//! the GIT rail groups its status rows. The `/` filter narrows across
//! every section at once and the header counts say what survived it;
//! Enter opens a file, applies an env, runs a chain, copies a cookie or
//! re-opens a recent / captured request as a scratch pane.
//!
//! The data is a snapshot: `refresh` rescans everything synchronously
//! (a workspace walk capped at `scan_cap` request files, plus the small
//! `.mnml` / `.rqst` lists) onto one arena that the next refresh drops.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const key_mod = @import("../core/key.zig");
const alloc = @import("../core/alloc.zig");
const command = @import("../core/command.zig");
const panel = @import("../core/panel.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const chip = @import("../ui/chip.zig");
const env_mod = @import("../http/env.zig");
const history = @import("../http/history.zig");
const captured = @import("../http/captured.zig");
const parse = @import("../http/parse.zig");
const http = @import("http.zig");
const cmd_http = @import("cmd_http.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = app_mod.App;
const CommandError = command.CommandError;
const Key = key_mod.Key;
const Mouse = key_mod.Mouse;

pub const Section = enum {
    collections,
    envs,
    chains,
    mocks,
    cookies,
    recent,
    captured,

    pub const all = [_]Section{ .collections, .envs, .chains, .mocks, .cookies, .recent, .captured };

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .collections => "COLLECTIONS",
            .envs => "ENVS",
            .chains => "CHAINS",
            .mocks => "MOCKS",
            .cookies => "COOKIES",
            .recent => "RECENT",
            .captured => "CAPTURED",
        };
    }
};

/// One displayed row: a section header or an item of it. Strings
/// borrow the snapshot arena.
pub const Row = struct {
    section: Section,
    header: bool = false,
    /// Header: how many items the filter left.
    count: u32 = 0,
    /// Item: the primary text and the dim detail after it.
    label: []const u8 = "",
    detail: []const u8 = "",
    /// Item: its index in the section's data.
    idx: u32 = 0,
    /// Header: the section is folded (the chevron says so).
    collapsed: bool = false,
};

pub const Panel = list_panel.ListPanel(Row);

/// Runners, merged into `command.runners` at comptime (D5).
pub const table = .{
    .@"http.panel_open" = &openCmd,
    .@"http.panel_toggle_section" = &toggleSectionCmd,
    .@"http.panel_copy_path" = &copyPathCmd,
    .@"http.toggle_collapse_all" = &toggleCollapseAllCmd,
};

/// The workspace walk stops here.
pub const scan_cap: usize = 500;
/// How many history / captured rows the panel lists, newest first.
pub const recent_cap: usize = 50;
const skip_dirs = [_][]const u8{ "node_modules", "target", "zig-out", "zig-cache", "dist", "build", "vendor" };
/// A second click on the selected row within this window opens it.
const double_click_ms: i64 = 500;

pub const State = struct {
    /// D1: the snapshot tier — every list below lives here until the
    /// next `refresh` drops them all at once.
    snapshot: alloc.SnapshotArena,
    /// Request files, workspace-relative, sorted.
    files: []const []const u8 = &.{},
    envs: []const []const u8 = &.{},
    /// The active env at the last refresh, if any.
    active_env: ?[]const u8 = null,
    /// Chain names (`<name>.chain.json` under `.mnml/chains`).
    chains: []const []const u8 = &.{},
    /// `*.mock.json` sidecars, workspace-relative.
    mocks: []const []const u8 = &.{},
    cookies: []const CookieRow = &.{},
    /// Newest first.
    recent: []const history.Row = &.{},
    captured: []const captured.Row = &.{},
    truncated: bool = false,
    /// Rows as displayed: the filter and the collapse state applied.
    rows: std.ArrayListUnmanaged(Row) = .empty,
    list: Panel.State = .{},
    collapsed: std.enums.EnumSet(Section) = .initEmpty(),
    scanned_once: bool = false,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.rows.deinit(gpa);
        self.list.deinit(gpa);
        self.snapshot.deinit();
    }

    pub fn selected(self: *const State) ?Row {
        if (self.list.cursor >= self.rows.items.len) return null;
        return self.rows.items[self.list.cursor];
    }

    /// Items of `s` before the filter.
    pub fn total(self: *const State, s: Section) usize {
        return switch (s) {
            .collections => self.files.len,
            .envs => self.envs.len,
            .chains => self.chains.len,
            .mocks => self.mocks.len,
            .cookies => self.cookies.len,
            .recent => self.recent.len,
            .captured => self.captured.len,
        };
    }

    pub fn totalItems(self: *const State) usize {
        var n: usize = 0;
        for (Section.all) |s| n += self.total(s);
        return n;
    }
};

pub const CookieRow = struct { host: []const u8, name: []const u8, value: []const u8 };

// ─── the scan ───────────────────────────────────────────────────────────

/// Rescan every section onto a fresh snapshot and rebuild the rows.
pub fn refresh(app: *App) Allocator.Error!void {
    const st = &app.http_panel;
    var incoming = alloc.SnapshotArena.init(app.gpa);
    errdefer incoming.deinit();
    const a = incoming.allocator();
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var mocks: std.ArrayListUnmanaged([]const u8) = .empty;
    var truncated = false;
    walkWorkspace(app.io, app.gpa, a, app.workspace, &files, &mocks, &truncated) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    sortStrings(files.items);
    sortStrings(mocks.items);
    const envs = try env_mod.listNames(a, app.io, app.workspace);
    const active_env: ?[]const u8 = if (try http.envName(app, a)) |n| try a.dupe(u8, n) else null;
    const chains = try listChains(app, a);
    var cookie_rows: std.ArrayListUnmanaged(CookieRow) = .empty;
    {
        const j = try cmd_http.jar(app);
        const entries = try j.entries(a);
        for (entries) |e| try cookie_rows.append(a, .{ .host = try a.dupe(u8, e.host), .name = try a.dupe(u8, e.name), .value = try a.dupe(u8, e.value) });
    }
    const hist_path = try history.historyPath(a, app.workspace);
    const oldest_first = try history.tail(a, app.io, hist_path, recent_cap);
    const recent = try a.alloc(history.Row, oldest_first.len);
    for (oldest_first, 0..) |r, i| recent[oldest_first.len - 1 - i] = r;
    const cap_all = try captured.load(a, app.io, app.workspace);
    const cap_n = @min(cap_all.len, recent_cap);
    const cap_rows = try a.alloc(captured.Row, cap_n);
    for (0..cap_n) |i| cap_rows[i] = cap_all[cap_all.len - 1 - i];

    st.snapshot.replace(&incoming);
    st.files = files.items;
    st.mocks = mocks.items;
    st.envs = envs;
    st.active_env = active_env;
    st.chains = chains;
    st.cookies = cookie_rows.items;
    st.recent = recent;
    st.captured = cap_rows;
    st.truncated = truncated;
    st.scanned_once = true;
    try rebuild(app);
    app.needs_render = true;
}

fn walkWorkspace(io: Io, gpa: Allocator, arena: Allocator, workspace: []const u8, files: *std.ArrayListUnmanaged([]const u8), mocks: *std.ArrayListUnmanaged([]const u8), truncated: *bool) !void {
    var root = try Io.Dir.cwd().openDir(io, workspace, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(gpa);
    defer walker.deinit();
    while (true) {
        const entry = walker.next(io) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        } orelse break;
        if (files.items.len >= scan_cap) {
            truncated.* = true;
            break;
        }
        switch (entry.kind) {
            .directory => if (!skipDir(entry.basename)) {
                walker.enter(io, entry) catch {};
            },
            .file => {
                if (std.mem.endsWith(u8, entry.basename, ".mock.json")) {
                    try mocks.append(arena, try arena.dupe(u8, entry.path));
                } else if (parse.isRequestPath(entry.basename)) {
                    try files.append(arena, try arena.dupe(u8, entry.path));
                }
            },
            else => {},
        }
    }
}

fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

fn listChains(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const dir_path = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "chains" });
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".chain.json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".chain.json".len];
        if (stem.len == 0) continue;
        try out.append(arena, try arena.dupe(u8, stem));
    }
    sortStrings(out.items);
    return out.items;
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

// ─── rows ───────────────────────────────────────────────────────────────

/// The displayed rows: every section's header (with the count the
/// filter left) and, unless collapsed, its matching items. Under a
/// filter a section with no match is dropped.
pub fn rebuild(app: *App) Allocator.Error!void {
    const st = &app.http_panel;
    const gpa = app.gpa;
    st.rows.clearRetainingCapacity();
    const q = st.list.filterText();
    const a = st.snapshot.allocator();
    for (Section.all) |s| {
        var items: std.ArrayListUnmanaged(Row) = .empty;
        defer items.deinit(gpa);
        const n = st.total(s);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const row = try itemRow(st, a, s, i);
            if (matches(row, q)) try items.append(gpa, row);
        }
        if (q.len > 0 and items.items.len == 0) continue;
        const folded = st.collapsed.contains(s);
        try st.rows.append(gpa, .{ .section = s, .header = true, .count = @intCast(items.items.len), .collapsed = folded });
        if (folded) continue;
        try st.rows.appendSlice(gpa, items.items);
    }
    if (st.list.cursor >= st.rows.items.len) st.list.cursor = st.rows.items.len -| 1;
}

/// Item `i` of section `s` as a row. The formatted texts land on the
/// snapshot arena so the row can be kept until the next refresh.
fn itemRow(st: *const State, a: Allocator, s: Section, i: usize) Allocator.Error!Row {
    const idx: u32 = @intCast(i);
    return switch (s) {
        .collections => .{ .section = s, .idx = idx, .label = st.files[i] },
        .envs => .{ .section = s, .idx = idx, .label = st.envs[i], .detail = if (st.active_env) |ae| (if (std.mem.eql(u8, ae, st.envs[i])) "active" else "") else "" },
        .chains => .{ .section = s, .idx = idx, .label = st.chains[i] },
        .mocks => .{ .section = s, .idx = idx, .label = st.mocks[i] },
        .cookies => .{ .section = s, .idx = idx, .label = st.cookies[i].name, .detail = st.cookies[i].host },
        .recent => blk: {
            const r = st.recent[i];
            const label = try std.fmt.allocPrint(a, "{s} {s}", .{ r.method, history.shortUrl(r.url) });
            const detail = if (r.status) |code| try std.fmt.allocPrint(a, "{d}", .{code}) else if (r.err != null) "err" else "";
            break :blk .{ .section = s, .idx = idx, .label = label, .detail = detail };
        },
        .captured => blk: {
            const r = st.captured[i];
            const label = try std.fmt.allocPrint(a, "{s} {s}", .{ r.method, history.shortUrl(r.url) });
            break :blk .{ .section = s, .idx = idx, .label = label };
        },
    };
}

/// The filter is a case-insensitive substring over the label and the
/// detail (a recent row's URL, a cookie's host…).
fn matches(row: Row, q: []const u8) bool {
    if (q.len == 0) return true;
    return containsIgnoreCase(row.label, q) or containsIgnoreCase(row.detail, q);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ─── actions ────────────────────────────────────────────────────────────

fn requireRow(app: *App) CommandError!Row {
    return app.http_panel.selected() orelse app.diag.fail(app.frame.allocator(), "http panel: nothing selected", .{});
}

/// Enter on a row: a header toggles its section; an item opens, applies
/// or runs what it names.
pub fn activate(app: *App, row: Row) CommandError!void {
    const st = &app.http_panel;
    const arena = app.frame.allocator();
    if (row.header) {
        st.collapsed.toggle(row.section);
        try rebuild(app);
        return;
    }
    switch (row.section) {
        .collections, .mocks => {
            const rel = if (row.section == .collections) st.files[row.idx] else st.mocks[row.idx];
            const abs = try std.fs.path.join(arena, &.{ app.workspace, rel });
            _ = app.openPath(abs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
            };
        },
        .envs => {
            const name = st.envs[row.idx];
            if (app.http.env_override) |e| app.gpa.free(e);
            app.http.env_override = try app.gpa.dupe(u8, name);
            st.active_env = name;
            try rebuild(app);
            app.toast("env: {s} (session override — :http.reset_env clears)", .{name});
        },
        .chains => try cmd_http.runChainNamed(app, st.chains[row.idx]),
        .cookies => {
            const c = st.cookies[row.idx];
            const text = try std.fmt.allocPrint(arena, "{s}={s}", .{ c.name, c.value });
            try app.clipboard.set(text, false);
            app.toast("cookies: copied {s}={s}", .{ c.name, c.value });
        },
        .recent => {
            const req = try history.rowToRequest(app.gpa, st.recent[row.idx]);
            _ = try http.openFromRequest(app, req, .{});
        },
        .captured => {
            const req = try captured.toRequest(app.gpa, st.captured[row.idx]);
            _ = try http.openFromRequest(app, req, .{});
        },
    }
}

fn openCmd(app: *App) CommandError!void {
    try activate(app, try requireRow(app));
}

fn toggleSectionCmd(app: *App) CommandError!void {
    const row = try requireRow(app);
    app.http_panel.collapsed.toggle(row.section);
    try rebuild(app);
}

/// `http.toggle_collapse_all`: every section closed, or every one open
/// once all are closed.
fn toggleCollapseAllCmd(app: *App) CommandError!void {
    const st = &app.http_panel;
    var all_closed = true;
    for (Section.all) |s| if (!st.collapsed.contains(s)) {
        all_closed = false;
    };
    st.collapsed = if (all_closed) .initEmpty() else .initFull();
    try rebuild(app);
    app.toast("http panel: {s}", .{if (all_closed) "expanded" else "collapsed"});
}

/// Copy what identifies the row: a file's workspace path, an env / chain
/// name, a cookie's `name=value`, a recent / captured request's URL.
fn copyPathCmd(app: *App) CommandError!void {
    const st = &app.http_panel;
    const row = try requireRow(app);
    const arena = app.frame.allocator();
    const text: []const u8 = if (row.header) row.section.label() else switch (row.section) {
        .collections => st.files[row.idx],
        .mocks => st.mocks[row.idx],
        .envs => st.envs[row.idx],
        .chains => st.chains[row.idx],
        .cookies => try std.fmt.allocPrint(arena, "{s}={s}", .{ st.cookies[row.idx].name, st.cookies[row.idx].value }),
        .recent => st.recent[row.idx].url,
        .captured => st.captured[row.idx].url,
    };
    try app.clipboard.set(text, false);
    app.toast("copied {s}", .{text});
}

// ─── keys ───────────────────────────────────────────────────────────────

/// `r` rescans, `c` collapses / expands everything, `n` starts a new
/// request; left / right (h / l) close and open the selected section.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.http_panel;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try rebuild(app);
            return true;
        },
        .activate => |i| {
            st.list.cursor = i;
            if (st.selected()) |row| runToast(app, activate(app, row));
            return true;
        },
        .ignored => {},
    }
    if (st.list.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .left => return try foldSelected(app, true),
        .right => return try foldSelected(app, false),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => runToast(app, refresh(app)),
                'c' => runToast(app, toggleCollapseAllCmd(app)),
                'n' => runToast(app, command.run(app, .{ .static = .@"http.new_request" })),
                'h' => return try foldSelected(app, true),
                'l' => return try foldSelected(app, false),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// Close (`fold`) or open the selected row's section; the cursor lands
/// on its header when it closes.
fn foldSelected(app: *App, fold: bool) Allocator.Error!bool {
    const st = &app.http_panel;
    const row = st.selected() orelse return false;
    if (fold == st.collapsed.contains(row.section)) return true;
    st.collapsed.toggle(row.section);
    try rebuild(app);
    if (fold) for (st.rows.items, 0..) |r, i| if (r.header and r.section == row.section) {
        st.list.cursor = i;
        break;
    };
    return true;
}

/// A command reached outside `command.run`: toast the reason the same way.
fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("http panel: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

/// A row: a left press selects (a header toggles at once; an item opens
/// on a second press within `double_click_ms`); a right press selects
/// and opens the row menu; the wheel moves the cursor three rows.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.http_panel;
    switch (m.kind) {
        .press => {
            if (idx >= st.rows.items.len) return;
            focusPanel(app);
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const row = st.rows.items[idx];
            if (row.header) {
                st.last_click = null;
                runToast(app, activate(app, row));
                return;
            }
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, activate(app, row));
            }
        },
        .scroll_up => st.list.cursor -|= 3,
        .scroll_down => st.list.cursor = @min(st.list.cursor + 3, st.rows.items.len -| 1),
        else => {},
    }
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.http_panel.rows.items.len) return;
    focusPanel(app);
    app.http_panel.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => runToast(app, refresh(app)),
        .new => runToast(app, command.run(app, .{ .static = .@"http.new" })),
        .sort, .view => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.http_panel.list.filter_focused = true;
}

/// A press on the scrollbar jumps the cursor to the proportional row.
pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.http_panel;
    const total = st.rows.items.len;
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

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .http };
    app.needs_render = true;
}

/// The row menu: what Enter does first, then the section's own
/// commands. Every action is a registered id.
fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.http_panel;
    const row = st.selected() orelse return;
    const M = command.MenuItem;
    const items: []const M = if (row.header) &.{
        .{ .label = if (st.collapsed.contains(row.section)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
        .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
        .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
    } else switch (row.section) {
        .collections => &.{
            .{ .label = "Open", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy path", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "New request…", .action = .{ .command = .@"http.new_request" }, .separator_before = true },
            .{ .label = "New collection…", .action = .{ .command = .@"http.new_collection" } },
            .{ .label = "Sync sources", .action = .{ .command = .@"http.sync" } },
        },
        .envs => &.{
            .{ .label = "Use this env", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy name", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "Edit active env…", .action = .{ .command = .@"http.edit_env" }, .separator_before = true },
            .{ .label = "Clear override", .action = .{ .command = .@"http.reset_env" } },
            .{ .label = "New env…", .action = .{ .command = .@"http.new_env" } },
        },
        .chains => &.{
            .{ .label = "Run chain", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy name", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "New chain…", .action = .{ .command = .@"http.new_chain" }, .separator_before = true },
        },
        .mocks => &.{
            .{ .label = "Open", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy path", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "Replay on active request", .action = .{ .command = .@"http.replay_mock" }, .separator_before = true },
        },
        .cookies => &.{
            .{ .label = "Copy name=value", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Delete cookie…", .action = .{ .command = .@"cookies.delete" }, .separator_before = true },
            .{ .label = "Clear jar", .action = .{ .command = .@"cookies.clear" } },
        },
        .recent => &.{
            .{ .label = "Open as request", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy URL", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "History picker…", .action = .{ .command = .@"http.history" }, .separator_before = true },
            .{ .label = "Clear recent", .action = .{ .command = .@"http.clear_recent" } },
        },
        .captured => &.{
            .{ .label = "Open as request", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy URL", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "Captured picker…", .action = .{ .command = .@"http.view_captured" }, .separator_before = true },
            .{ .label = "Clear captured", .action = .{ .command = .@"http.clear_captured" } },
        },
    };
    const owned = try app.gpa.dupe(M, items);
    errdefer app.gpa.free(owned);
    const title = if (row.header) row.section.label() else row.label;
    try app.openMenu(title, owned, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.http_panel;
    // The first time the panel is shown it scans (Rust parity).
    if (!st.scanned_once) refresh(app) catch {};
    const total = st.totalItems();
    const cap: []const u8 = if (st.truncated) "+" else "";
    var shown: usize = 0;
    for (st.rows.items) |r| if (r.header) {
        shown += r.count;
    };
    const subtitle = if (st.list.filterText().len == 0)
        ui.fmt(" ({d}{s})", .{ total, cap })
    else
        ui.fmt(" ({d} of {d}{s})", .{ shown, total, cap });
    const empty: list_panel.EmptyState = if (total == 0)
        .{ .message = "No .http / .curl files yet — save one to see it here." }
    else
        .{ .message = "No matches — Esc clears" };
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .http,
        .label = "HTTP",
        .subtitle = subtitle,
        .rows = st.rows.items,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
        // The green ` + `: a blank request (`http.new_request`).
        .new_chip = true,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

/// A header is `▼ NAME (n)` (`▸` collapsed); an item is indented under
/// it, its detail dim after two spaces.
fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    var x = r.x;
    const end = r.right();
    if (row.header) {
        const open = !row.collapsed;
        const chevron: []const u8 = if (ui.ascii) (if (open) "v " else "> ") else (if (open) "▼ " else "▸ ");
        x += ui.putStr(x, r.y, end -| x, chevron, Theme.onBg(t.muted, base.bg));
        const label = ui.fmt("{s} ({d})", .{ row.section.label(), row.count });
        _ = ui.putStr(x, r.y, end -| x, ui.clipStr(label, end -| x), Theme.onBg(t.accent, base.bg));
        return;
    }
    x += ui.putStr(x, r.y, end -| x, "  ", base);
    const avail: u16 = end -| x;
    // Capped at the row: a 100k-char label must not sum past u16.
    const label_w = ui.widthUpTo(row.label, avail);
    const detail_w: u16 = if (row.detail.len > 0) ui.widthUpTo(row.detail, avail) + 2 else 0;
    var label = row.label;
    // The detail yields before the label does: a long detail is clipped
    // at the paint, never squeezing the label to nothing.
    const label_max = @max(avail -| detail_w, @min(label_w, avail / 2));
    if (label_w > label_max) label = ui.clipStr(row.label, label_max);
    x += ui.putStr(x, r.y, end -| x, label, Theme.onBg(t.fg, base.bg));
    if (row.detail.len > 0 and end > x + 2) {
        x += ui.putStr(x, r.y, end -| x, "  ", base);
        const dstyle = if (std.mem.eql(u8, row.detail, "active")) Theme.onBg(t.accent, base.bg) else Theme.onBg(t.muted, base.bg);
        _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.detail, end -| x), dstyle);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const panel_ids = panel;

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

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("../ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }

    fn seedAll(f: *Fixture) !void {
        try f.write("api/users.http", "GET https://x/users\n");
        try f.write("api/orders.curl", "curl https://x/orders\n");
        try f.write("api/orders.curl.mock.json", "{\"status\":200,\"body\":\"[]\"}\n");
        try f.write(".mnml/env/dev.env", "HOST=https://dev\n");
        try f.write(".mnml/env/prod.env", "HOST=https://prod\n");
        try f.write(".mnml/chains/login.chain.json", "[{\"request\":\"api/users.http\"}]\n");
        try f.write(".mnml/cookies.json", "{\"x.test\":{\"session\":\"abc\"}}\n");
        try f.write(".rqst/history.jsonl", "{\"ts\":1,\"method\":\"POST\",\"url\":\"https://x/login\",\"status\":201}\n{\"ts\":2,\"method\":\"GET\",\"url\":\"https://x/users\",\"status\":200}\n");
        try f.write(".rqst/captured/log.jsonl", "{\"at\":1,\"request_id\":\"r1\",\"method\":\"GET\",\"url\":\"https://cdn.test/app.js\"}\n");
    }
};

fn rowCount(st: *const State, s: Section) ?u32 {
    for (st.rows.items) |r| if (r.header and r.section == s) return r.count;
    return null;
}

test "refresh lists every section; the filter narrows across all seven and drops the sections it empties" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    try testing.expectEqual(@as(usize, 2), st.files.len);
    try testing.expectEqualStrings("api/orders.curl", st.files[0]);
    try testing.expectEqual(@as(usize, 2), st.envs.len);
    try testing.expectEqual(@as(usize, 1), st.chains.len);
    try testing.expectEqualStrings("login", st.chains[0]);
    try testing.expectEqual(@as(usize, 1), st.mocks.len);
    try testing.expectEqual(@as(usize, 1), st.cookies.len);
    try testing.expectEqual(@as(usize, 2), st.recent.len);
    // Newest first.
    try testing.expectEqualStrings("GET", st.recent[0].method);
    try testing.expectEqual(@as(usize, 1), st.captured.len);
    // Seven headers + 10 items.
    var headers: usize = 0;
    for (st.rows.items) |r| if (r.header) {
        headers += 1;
    };
    try testing.expectEqual(@as(usize, 7), headers);
    try testing.expectEqual(@as(usize, 17), st.rows.items.len);
    // `users` matches a file and a recent row: the other five sections go.
    try st.list.filter.appendSlice(testing.allocator, "USERS");
    try rebuild(&f.app);
    try testing.expectEqual(@as(u32, 1), rowCount(st, .collections).?);
    try testing.expectEqual(@as(u32, 1), rowCount(st, .recent).?);
    try testing.expect(rowCount(st, .envs) == null);
    try testing.expect(rowCount(st, .cookies) == null);
    try testing.expectEqual(@as(usize, 4), st.rows.items.len);
    // A cookie's host is searchable too.
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "x.test");
    try rebuild(&f.app);
    try testing.expectEqual(@as(u32, 1), rowCount(st, .cookies).?);
    try testing.expectEqual(@as(usize, 2), st.rows.items.len);
}

test "a collapsed section keeps its header; collapse-all folds every one and unfolds once all are closed" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    st.collapsed.insert(.recent);
    try rebuild(&f.app);
    try testing.expectEqual(@as(usize, 15), st.rows.items.len);
    try testing.expectEqual(@as(u32, 2), rowCount(st, .recent).?);
    try command.run(&f.app, .{ .static = .@"http.toggle_collapse_all" });
    try testing.expectEqual(@as(usize, 7), st.rows.items.len);
    try command.run(&f.app, .{ .static = .@"http.toggle_collapse_all" });
    try testing.expectEqual(@as(usize, 17), st.rows.items.len);
}

test "activate: an env row becomes the session override; a file row opens a request pane; a cookie row copies name=value" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    try testing.expect(f.app.focus == .panel and f.app.focus.panel == .http);
    try refresh(&f.app);
    const st = &f.app.http_panel;
    var env_row: ?usize = null;
    var file_row: ?usize = null;
    var cookie_row: ?usize = null;
    for (st.rows.items, 0..) |r, i| {
        if (r.header) continue;
        if (r.section == .envs and std.mem.eql(u8, r.label, "prod")) env_row = i;
        if (r.section == .collections and std.mem.endsWith(u8, r.label, "users.http")) file_row = i;
        if (r.section == .cookies) cookie_row = i;
    }
    st.list.cursor = env_row.?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expectEqualStrings("prod", f.app.http.env_override.?);
    try testing.expectEqualStrings("active", st.rows.items[env_row.?].detail);
    st.list.cursor = cookie_row.?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expectEqualStrings("session=abc", f.app.clipboard.text());
    st.list.cursor = file_row.?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    const rp = http.activeRequest(&f.app).?;
    try testing.expectEqualStrings("https://x/users", rp.url.items);
}

test "headless: the panel paints seven headers, the filter row narrows, enter on a header folds it" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    for (Section.all) |s| try testing.expect(std.mem.indexOf(u8, txt, s.label()) != null);
    try testing.expect(std.mem.indexOf(u8, txt, "api/users.http") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "POST x/login  201") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "session  x.test") != null);
    // Row 0 is the COLLECTIONS header; enter folds it.
    try f.app.handle(.{ .key = Key.named(.enter) });
    const st = &f.app.http_panel;
    try testing.expect(st.collapsed.contains(.collections));
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "api/users.http") == null);
    try testing.expect(std.mem.indexOf(u8, txt2, "COLLECTIONS (2)") != null);
    // `/` then typing narrows; the subtitle counts what survived.
    try f.app.handle(.{ .key = Key.char('/') });
    try f.app.handle(.{ .key = Key.char('l') });
    try f.app.handle(.{ .key = Key.char('o') });
    try f.app.handle(.{ .key = Key.char('g') });
    const txt3 = try f.screen();
    defer testing.allocator.free(txt3);
    try testing.expect(std.mem.indexOf(u8, txt3, "(2 of 10)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "CHAINS (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "RECENT (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "ENVS") == null);
}

test "paintRow: a 100k-char label and detail paint clipped without overflowing the cell sum" {
    const UiFixture = @import("../ui/test_fixture.zig");
    var f = try UiFixture.init(60, 2);
    defer f.deinit();
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'h');
    paintRow(f.ui(), f.full().row(0), .{ .section = .recent, .label = long, .detail = "200" }, false);
    paintRow(f.ui(), f.full().row(1), .{ .section = .recent, .label = "GET x", .detail = long }, true);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(0, &buf), "  hhhh"));
    try testing.expect(std.mem.endsWith(u8, f.row(0, &buf), "…  200"));
    // A long detail clips itself; the label keeps its cells.
    try testing.expect(std.mem.startsWith(u8, f.row(1, &buf), "  GET x  hhhh"));
    try testing.expect(std.mem.endsWith(u8, f.row(1, &buf), "…"));
}

test "the green + chip on the header opens a blank request; its hit is the .new chip of the http panel" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, " + ") != null);
    // Find the chip by its hit, wherever the ladder put it.
    var found: ?struct { x: u16, y: u16 } = null;
    var y: u16 = 0;
    while (y < 4 and found == null) : (y += 1) {
        var x: u16 = 0;
        while (x < 100) : (x += 1) {
            const target = f.app.hits.at(x, y) orelse continue;
            if (target == .chip and target.chip.kind == .new and target.chip.panel == .http) {
                found = .{ .x = x, .y = y };
                break;
            }
        }
    }
    try testing.expect(found != null);
    try f.app.handle(.{ .mouse = .{ .x = found.?.x, .y = found.?.y, .kind = .press, .button = .left } });
    const pane = f.app.panes.get(f.app.active.?).?;
    try testing.expect(pane.* == .request);
    try testing.expectEqualStrings("GET  new request", pane.title());
}
