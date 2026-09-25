//! NOTES — the workspace's scratch notes, `<ws>/.mnml/notes/*.md`, on
//! the `todos.zig` shape (D8): a scan worker posting `.notes =
//! *ScanResult`, a snapshot arena for the rows, `handle` adopting the
//! payload, the command table, the `ListPanel` draw with the shared
//! `sort:` chip, a row menu of real ids, and the mouse prongs
//! `dispatch.zig` routes here.
//!
//! A note is a markdown file; the row shows its name, its first heading
//! (or first line) and how old it is. `notes.new` seeds a prompt with
//! the next free `note-N.md`; the file lands through the tree's new-file
//! path and opens in an editor. The `open` and `save_post` hooks rescan a
//! panel that has been used, so a note written from the tree or a
//! retitled one is listed without a click.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const App = app_mod.App;
const auto_refresh = @import("app/auto_refresh.zig");
const Key = app_mod.Key;
const key_mod = @import("core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("core/alloc.zig");
const command = @import("core/command.zig");
const CommandError = command.CommandError;
const event = @import("core/event.zig");
const hooks = @import("core/hooks.zig");
const panel = @import("core/panel.zig");
const ListSort = panel.ListSort;
const Rect = @import("ui/rect.zig");
const Ui = @import("ui/context.zig");
const Theme = @import("ui/theme.zig");
const hit = @import("ui/hit.zig");
const list_panel = @import("ui/list_panel.zig");
const chip = @import("ui/chip.zig");
const todos = @import("todos.zig");
const tree_mod = @import("app/tree.zig");
const settings = @import("app/settings.zig");

/// Workspace-relative.
pub const dir_rel = ".mnml/notes";

/// One note. Slices borrow from `ScanResult.arena` in flight and from
/// `State.snapshot` once adopted.
pub const Item = struct {
    /// The file name without `.md`.
    name: []const u8,
    /// Workspace-relative path.
    path: []const u8,
    /// The first `# heading`, else the first non-empty line; empty for
    /// an empty file.
    title: []const u8,
    /// File mtime in seconds.
    mtime: i64,
    bytes: u64,
};

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    generation: u32,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*ScanResult {
        const r = try gpa.create(ScanResult);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *ScanResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Panel = list_panel.ListPanel(Item);

pub const table = .{
    .@"notes.refresh" = &refreshCmd,
    .@"notes.new" = &newCmd,
    .@"notes.sort" = &sortCmd,
    .@"notes.open" = &openCmd,
    .@"notes.copy_path" = &copyPathCmd,
    .@"notes.delete" = &deleteCmd,
};

/// Bytes of a note read for its title.
const head_bytes: usize = 64 * 1024;
const double_click_ms: i64 = 500;

pub const State = struct {
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    items: []Item = &.{},
    filtered: std.ArrayListUnmanaged(u32) = .empty,
    list: Panel.State = .{},
    sort: ListSort = .newest,
    generation: u32 = 0,
    scanning: bool = false,
    scanned_once: bool = false,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,

    pub fn init(gpa: Allocator, sort: ListSort) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .sort = sort };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        self.filtered.deinit(gpa);
        self.list.deinit(gpa);
        self.snapshot.deinit();
    }

    pub fn selected(self: *const State) ?Item {
        if (self.list.cursor >= self.filtered.items.len) return null;
        return self.items[self.filtered.items[self.list.cursor]];
    }
};

/// `open` / `save_post` subscriber: a file under the notes directory
/// changed shape; a used panel rescans.
pub fn onPathTouched(app: *App, args: hooks.HookArgs) void {
    const path = switch (args) {
        .open => |o| o.path,
        .save_post => |s| s.path,
        else => return,
    };
    if (!app.notes.scanned_once or !auto_refresh.on(app, .notes)) return;
    if (!isUnderDir(path)) return;
    refresh(app) catch {};
}

/// `tree.acceptDelete` removed `rel` (the tree's confirm and ours share
/// it); a used panel rescans when it was a note.
pub fn onPathRemoved(app: *App, rel: []const u8) void {
    if (!app.notes.scanned_once or !isUnderDir(rel) or !auto_refresh.on(app, .notes)) return;
    refresh(app) catch {};
}

fn isUnderDir(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, dir_rel ++ "/") and std.ascii.endsWithIgnoreCase(rel, ".md");
}

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

pub fn refresh(app: *App) CommandError!void {
    const st = &app.notes;
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.scanning = true;
    st.scanned_once = true;
    app.needs_render = true;
    st.group.concurrent(app.io, scanWorker, .{ app.events, app.io, app.gpa, app.workspace, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "notes: could not start the scan: {s}", .{@errorName(err)});
    };
}

fn scanWorker(events: *event.EventQueue, io: Io, gpa: Allocator, workspace: []const u8, generation: u32) Io.Cancelable!void {
    const result = ScanResult.create(gpa, generation) catch {
        postErr(events, io, gpa, "out of memory starting the scan");
        return;
    };
    errdefer result.destroy(gpa);
    scanInto(io, gpa, workspace, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => {
            postErr(events, io, gpa, "out of memory during the scan");
            return;
        },
    };
    events.post(io, .{ .notes = result });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .notes, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

/// List `<workspace>/.mnml/notes/*.md` (flat) into `r.items`. A missing
/// directory is an empty list, not an error.
pub fn scanInto(io: Io, gpa: Allocator, workspace: []const u8, r: *ScanResult) ScanError!void {
    const arena = r.arena.allocator();
    var items: std.ArrayListUnmanaged(Item) = .empty;
    const dir_path = try std.fs.path.join(arena, &.{ workspace, dir_rel });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        r.items = &.{};
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| blk: {
        if (err == error.Canceled) return error.Canceled;
        break :blk null;
    }) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".md")) continue;
        try io.checkCancel();
        const st = dir.statFile(io, entry.name, .{}) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        const head = dir.readFileAlloc(io, entry.name, gpa, .limited(head_bytes)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(head);
        try items.append(arena, .{
            .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - 3]),
            .path = try std.fs.path.join(arena, &.{ dir_rel, entry.name }),
            .title = try arena.dupe(u8, titleOf(head)),
            .mtime = st.mtime.toSeconds(),
            .bytes = st.size,
        });
    }
    r.items = items.items;
}

/// The first `# heading` (any level) without its hashes; else the
/// first non-empty line; clipped to 120 bytes on a char boundary.
pub fn titleOf(text: []const u8) []const u8 {
    var first: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const body = std.mem.trimStart(u8, std.mem.trimStart(u8, line, "#"), " \t");
            if (body.len > 0) return clip(body);
            continue;
        }
        if (first == null) first = line;
    }
    return clip(first orelse "");
}

fn clip(s: []const u8) []const u8 {
    if (s.len <= 120) return s;
    var cut: usize = 120;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return s[0..cut];
}

// ─── the event handler (D1) ─────────────────────────────────────────────

pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.notes;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    st.scanning = false;
    st.snapshot.reset();
    st.items = &.{};
    const arena = st.snapshot.allocator();
    const items = try arena.alloc(Item, result.items.len);
    for (result.items, 0..) |it, i| items[i] = .{
        .name = try arena.dupe(u8, it.name),
        .path = try arena.dupe(u8, it.path),
        .title = try arena.dupe(u8, it.title),
        .mtime = it.mtime,
        .bytes = it.bytes,
    };
    st.items = items;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

fn sortItems(st: *State) void {
    const Ctx = struct {
        sort: ListSort,
        fn lt(ctx: @This(), a: Item, b: Item) bool {
            switch (ctx.sort) {
                .newest => if (a.mtime != b.mtime) return a.mtime > b.mtime,
                .oldest => if (a.mtime != b.mtime) return a.mtime < b.mtime,
                .name, .name_desc => {},
            }
            const by_name = std.mem.order(u8, a.name, b.name);
            if (by_name != .eq) return if (ctx.sort == .name_desc) by_name == .gt else by_name == .lt;
            return false;
        }
    };
    std.mem.sort(Item, st.items, Ctx{ .sort = st.sort }, Ctx.lt);
}

/// Case-insensitive substring over the name and the title.
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.notes;
    st.filtered.clearRetainingCapacity();
    const q = st.list.filterText();
    for (st.items, 0..) |it, i| {
        if (q.len > 0 and !(todos.containsIgnoreCase(it.name, q) or todos.containsIgnoreCase(it.title, q))) continue;
        try st.filtered.append(app.gpa, @intCast(i));
    }
    if (st.list.cursor >= st.filtered.items.len) st.list.cursor = st.filtered.items.len -| 1;
}

/// The user chose `sort` — the chip's click or a row of its
/// right-click menu, the one path for both: the list re-sorts and
/// `ui.notes_sort` is persisted, so the panel opens in that order next time.
pub fn pickSort(app: *App, sort: ListSort) Allocator.Error!void {
    try setSort(app, sort);
    app.cfg.ui.notes_sort = app.notes.sort.toConfig();
    _ = try settings.persist(app, .workspace, &.{ "ui", "notes_sort" }, app.cfg.ui.notes_sort);
}

pub fn setSort(app: *App, sort: ListSort) Allocator.Error!void {
    const st = &app.notes;
    st.sort = sort;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return refresh(app);
}

/// The chip's click: the next mode, persisted as `ui.notes_sort`.
fn sortCmd(app: *App) CommandError!void {
    try pickSort(app, app.notes.sort.next());
    app.toast("notes: {s}", .{app.notes.sort.label()});
}

/// `+ New note`: a prompt seeded with the next free `note-N.md`, so
/// enter is the fast path and a real name can be typed over it. The
/// file is created and opened by the tree's new-file path.
fn newCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const abs_dir = try app.absPath(dir_rel);
    Io.Dir.cwd().createDirPath(app.io, abs_dir) catch |err| return app.diag.fail(arena, "notes: create {s}/: {s}", .{ dir_rel, @errorName(err) });
    const seed = try nextFreeName(app, arena, abs_dir, "note");
    const dir = try app.gpa.dupe(u8, dir_rel);
    errdefer app.gpa.free(dir);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New note in " ++ dir_rel ++ "/"), .purpose = .{ .new_note = dir } } };
    app.overlay.prompt.state.seed(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// `<stem>-N.md`, the smallest N whose file does not exist.
pub fn nextFreeName(app: *App, arena: Allocator, abs_dir: []const u8, stem: []const u8) Allocator.Error![]const u8 {
    var n: usize = 1;
    while (n < 100_000) : (n += 1) {
        const name = try std.fmt.allocPrint(arena, "{s}-{d}.md", .{ stem, n });
        const full = try std.fs.path.join(arena, &.{ abs_dir, name });
        Io.Dir.cwd().access(app.io, full, .{}) catch return name;
    }
    return try std.fmt.allocPrint(arena, "{s}.md", .{stem});
}

/// A typed name without an extension gets `.md` — the panel lists only
/// markdown, so a bare `mynote` must not vanish into a file it cannot
/// see. A name with any extension is kept as typed.
pub fn withMdExt(arena: Allocator, text_in: []const u8) Allocator.Error![]const u8 {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0 or text[text.len - 1] == '/') return text;
    if (std.fs.path.extension(text).len > 0) return text;
    return std.fmt.allocPrint(arena, "{s}.md", .{text});
}

/// The prompt's accept: create + open through the tree, then rescan
/// (the `open` hook does too; this covers a name the hook cannot see,
/// such as one typed with a directory).
pub fn acceptNew(app: *App, dir: []const u8, text: []const u8) Allocator.Error!void {
    try tree_mod.acceptNewFile(app, dir, try withMdExt(app.frame.allocator(), text));
    if (app.notes.scanned_once) refresh(app) catch {};
}

fn openCmd(app: *App) CommandError!void {
    return openSelected(app);
}

pub fn openSelected(app: *App) CommandError!void {
    const it = app.notes.selected() orelse return app.diag.fail(app.frame.allocator(), "notes: nothing selected", .{});
    return openItem(app, it);
}

pub fn openItem(app: *App, it: Item) CommandError!void {
    const arena = app.frame.allocator();
    const rel = try arena.dupe(u8, it.path);
    const abs = try app.absPath(rel);
    _ = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
}

fn copyPathCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.notes.selected() orelse return app.diag.fail(arena, "notes: nothing selected", .{});
    const text = try arena.dupe(u8, it.path);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// Delete after a confirm — the tree's own delete box, so the buffers
/// on the file close the same way (`tree.acceptDelete`), and
/// `onPathRemoved` rescans.
fn deleteCmd(app: *App) CommandError!void {
    const it = app.notes.selected() orelse return app.diag.fail(app.frame.allocator(), "notes: nothing selected", .{});
    return confirmDelete(app, it.path, "Delete note");
}

pub fn confirmDelete(app: *App, rel_in: []const u8, title: []const u8) CommandError!void {
    const rel = try app.gpa.dupe(u8, rel_in);
    errdefer app.gpa.free(rel);
    const msg = try std.fmt.allocPrint(app.gpa, "  Delete {s}?", .{rel});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = title, .message = msg, .choices = &delete_choices },
        .purpose = .{ .delete_path = rel },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'c', .label = "Cancel" } };

// ─── keys ───────────────────────────────────────────────────────────────

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.notes;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try refilter(app);
            return true;
        },
        .activate => |i| {
            st.list.cursor = i;
            runToast(app, openSelected(app));
            return true;
        },
        .new_activate => {
            runToast(app, newCmd(app));
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
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => runToast(app, refresh(app)),
                's' => runToast(app, sortCmd(app)),
                'n' => runToast(app, newCmd(app)),
                'x' => runToast(app, deleteCmd(app)),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("notes: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.notes;
    switch (m.kind) {
        .press => {
            if (idx >= st.filtered.items.len) return;
            focusPanel(app);
            st.list.cursor = idx;
            st.list.on_new = false;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, openSelected(app));
            }
        },
        else => {},
    }
}

/// The wheel over the list: `rows` rows (the batch, budgeted and
/// clamped by `dispatch.panelWheel`); the window follows the cursor.
pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.notes;
    const total = st.filtered.items.len;
    st.list.cursor = if (down) @min(st.list.cursor + rows, total -| 1) else st.list.cursor -| rows;
    app.needs_render = true;
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.notes.filtered.items.len) return;
    focusPanel(app);
    app.notes.list.cursor = idx;
    app.notes.list.on_new = false;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .notes, m.x, m.y) else runToast(app, refresh(app)),
        .new => runToast(app, newCmd(app)),
        .view, .history => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.notes.list.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.notes;
    const total = st.filtered.items.len;
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

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .notes };
    app.needs_render = true;
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open", .action = .{ .command = .@"notes.open" } },
        .{ .label = "Copy path", .action = .{ .command = .@"notes.copy_path" } },
        .{ .label = "Delete…", .action = .{ .command = .@"notes.delete" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Note", items, x, y);
}

fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.alloc(command.MenuItem, ListSort.all.len);
    errdefer app.gpa.free(items);
    for (ListSort.all, 0..) |s, i| items[i] = .{
        .label = s.label(),
        .action = .{ .set_panel_sort = .{ .panel = .notes, .sort = s } },
        .checked = s == app.notes.sort,
    };
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.notes;
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    const rows = try ui.arena.alloc(Item, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = st.items[idx];
    const subtitle = if (st.list.filterText().len == 0)
        ui.fmt(" ({d})", .{st.items.len})
    else
        ui.fmt(" ({d} of {d})", .{ rows.len, st.items.len });
    const empty: list_panel.EmptyState = if (st.scanning and st.items.len == 0)
        .{ .message = "Reading notes…" }
    else if (st.items.len == 0)
        .{ .message = "No notes yet — click + New note above.", .hint = "Stored under " ++ dir_rel ++ "/*.md" }
    else
        .{ .message = "No matches — Esc clears" };
    now_s = Io.Timestamp.now(app.io, .real).toSeconds();
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .notes,
        .label = "NOTES",
        .subtitle = subtitle,
        .sort_chip = st.sort.label(),
        .sort_widest = ListSort.widest_label,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
        .new_label = "+ New note",
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.scanning) list_panel.paintSpinner(ui, area, "NOTES", app.now_ms);
}

/// The wall clock the rows measure their age against; set by `draw`
/// (the paint callback has no `*App`).
var now_s: i64 = 0;

/// `<name>  <title>  <age>`: the name in the accent, the title in the
/// text colour, the age dim and right-aligned. The title gives way
/// first; the name is clipped only when it alone does not fit.
fn paintRow(ui: Ui, r: Rect, row: Item, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    var x = r.x;
    const end = r.right();
    const age = list_panel.ageText(ui, now_s, row.mtime);
    const age_w = ui.width(age);
    var body_end = end;
    if (age_w + 2 < end -| x) {
        _ = ui.putStr(end - age_w, r.y, age_w, age, Theme.onBg(t.muted, base.bg));
        body_end = end - age_w - 1;
    }
    const name = ui.clipStr(row.name, body_end -| x);
    x += ui.putStr(x, r.y, body_end -| x, name, Theme.withFg(base, t.accent.fg));
    if (row.title.len > 0 and body_end -| x > 3) {
        x += ui.putStr(x, r.y, body_end -| x, "  ", base);
        _ = ui.putStr(x, r.y, body_end -| x, ui.clipStr(row.title, body_end -| x), Theme.onBg(t.fg, base.bg));
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "titleOf: the first heading wins over an earlier line; else the first line; empty stays empty" {
    try testing.expectEqualStrings("Plan", titleOf("intro line\n\n## Plan\nmore"));
    try testing.expectEqualStrings("just text", titleOf("\n  just text  \nsecond"));
    try testing.expectEqualStrings("", titleOf("\n\n"));
    try testing.expectEqualStrings("after empty hash", titleOf("#\n# after empty hash"));
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

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (f.app.notes.scanning and i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (f.app.notes.scanning) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

test "scanInto lists the notes directory's markdown files with titles; a missing directory is empty" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const empty = try ScanResult.create(testing.allocator, 1);
    defer empty.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.root, empty);
    try testing.expectEqual(@as(usize, 0), empty.items.len);
    try f.write(".mnml/notes/note-1.md", "# Ship it\n\nbody\n");
    try f.write(".mnml/notes/ideas.md", "loose thought\n");
    try f.write(".mnml/notes/skip.txt", "not markdown\n");
    try f.write(".mnml/notes/sub/deep.md", "# nested is not listed\n");
    const r = try ScanResult.create(testing.allocator, 1);
    defer r.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.root, r);
    try testing.expectEqual(@as(usize, 2), r.items.len);
    for (r.items) |it| {
        try testing.expect(it.mtime > 0);
        if (std.mem.eql(u8, it.name, "note-1")) {
            try testing.expectEqualStrings("Ship it", it.title);
            try testing.expectEqualStrings(".mnml/notes/note-1.md", it.path);
        } else {
            try testing.expectEqualStrings("ideas", it.name);
            try testing.expectEqualStrings("loose thought", it.title);
        }
    }
}

test "sort modes and the filter over name + title; a stale generation is dropped" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.notes;
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 3);
    items[0] = .{ .name = "b-note", .path = ".mnml/notes/b-note.md", .title = "Beta", .mtime = 5, .bytes = 1 };
    items[1] = .{ .name = "a-note", .path = ".mnml/notes/a-note.md", .title = "Alpha plan", .mtime = 9, .bytes = 1 };
    items[2] = .{ .name = "c-note", .path = ".mnml/notes/c-note.md", .title = "", .mtime = 1, .bytes = 0 };
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    try testing.expectEqualStrings("a-note", st.items[0].name);
    try testing.expectEqualStrings("c-note", st.items[2].name);
    try setSort(&f.app, .oldest);
    try testing.expectEqualStrings("c-note", st.items[0].name);
    try setSort(&f.app, .name);
    try testing.expectEqualStrings("a-note", st.items[0].name);
    try testing.expectEqualStrings("c-note", st.items[2].name);
    try setSort(&f.app, .name_desc);
    try testing.expectEqualStrings("c-note", st.items[0].name);
    try st.list.filter.appendSlice(testing.allocator, "PLAN");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqualStrings("a-note", st.selected().?.name);
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "b-");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    const stale = try ScanResult.create(testing.allocator, 0);
    try handle(&f.app, stale);
    try testing.expectEqual(@as(usize, 3), st.items.len);
}

test "headless: the panel lists notes, enter opens one, n seeds note-N.md and the file lands in .mnml/notes/" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write(".mnml/notes/note-1.md", "# First note\n");
    f.app.tree.visible = false;
    f.app.side.of.set(.notes, .right); // the 40-cell chrome these rows read
    f.app.side.right_width = 40;
    try command.run(&f.app, .{ .static = .@"view.activity_notes" });
    try f.app.render();
    try f.settle(2000);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "NOTES") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "note-1  First note") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "sort: Newest first") != null);
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("note-1.md", f.app.panes.get(f.app.active.?).?.title());
    try command.run(&f.app, .{ .static = .@"view.activity_notes" });
    try f.app.handle(.{ .key = Key.char('n') });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("note-2.md", f.app.overlay.prompt.state.text());
    try f.app.handle(.{ .key = Key.named(.enter) });
    _ = f.tmp.dir.statFile(testing.io, ".mnml/notes/note-2.md", .{}) catch return error.TestNoteNotCreated;
    try testing.expectEqualStrings("note-2.md", f.app.panes.get(f.app.active.?).?.title());
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 2), f.app.notes.items.len);
    // The seed is a selection: a typed name replaces it, and a name
    // without an extension lands as `<name>.md`, where the panel sees it.
    try command.run(&f.app, .{ .static = .@"view.activity_notes" });
    try f.app.handle(.{ .key = Key.char('n') });
    try testing.expectEqualStrings("note-3.md", f.app.overlay.prompt.state.text());
    try testing.expect(f.app.overlay.prompt.state.select_all);
    for ("mynote") |c| try f.app.handle(.{ .key = Key.char(c) });
    try testing.expectEqualStrings("mynote", f.app.overlay.prompt.state.text());
    try f.app.handle(.{ .key = Key.named(.enter) });
    _ = f.tmp.dir.statFile(testing.io, ".mnml/notes/mynote.md", .{}) catch return error.TestNoteNotCreated;
    try testing.expectEqualStrings("mynote.md", f.app.panes.get(f.app.active.?).?.title());
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 3), f.app.notes.items.len);
}

test "withMdExt: a bare name gets .md, an extension or a folder is kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("mynote.md", try withMdExt(arena, "mynote"));
    try testing.expectEqualStrings("mynote.md", try withMdExt(arena, "  mynote \n"));
    try testing.expectEqualStrings("note-1.md", try withMdExt(arena, "note-1.md"));
    try testing.expectEqualStrings("draft.txt", try withMdExt(arena, "draft.txt"));
    try testing.expectEqualStrings("ideas/", try withMdExt(arena, "ideas/"));
    try testing.expectEqualStrings("ideas/one.md", try withMdExt(arena, "ideas/one"));
    try testing.expectEqualStrings("", try withMdExt(arena, ""));
}

test "mouse: a row's right-click menu names real ids; the sort chip cycles and persists ui.notes_sort; delete confirms and rescans" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write(".mnml/notes/a.md", "# A\n");
    try f.write(".mnml/notes/b.md", "# B\n");
    f.app.tree.visible = false;
    f.app.side.of.set(.notes, .right); // the 40-cell chrome these rows read
    f.app.side.right_width = 40;
    try command.run(&f.app, .{ .static = .@"view.activity_notes" });
    try f.app.render();
    try f.settle(2000);
    try f.app.render();
    var row1: ?Rect = null;
    var sort_chip: ?Rect = null;
    for (f.app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.panel == .notes and r.idx == 1) {
            row1 = h.rect;
        },
        .chip => |c| if (c.panel == .notes and c.kind == .sort) {
            sort_chip = h.rect;
        },
        else => {},
    };
    try testing.expect(row1 != null and sort_chip != null);
    const click = struct {
        fn at(app: *App, r: Rect, button: key_mod.MouseButton) !void {
            try app.handle(.{ .mouse = .{ .x = r.x + 1, .y = r.y, .kind = .press, .button = button } });
            try app.handle(.{ .mouse = .{ .x = r.x + 1, .y = r.y, .kind = .release, .button = button } });
        }
    };
    try click.at(&f.app, row1.?, .right);
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 3), f.app.overlay.menu.items.len);
    for (f.app.overlay.menu.items) |it| try testing.expect(it.action == .command);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try click.at(&f.app, sort_chip.?, .left);
    try testing.expectEqual(ListSort.oldest, f.app.notes.sort);
    try testing.expectEqual(ListSort.oldest, ListSort.fromConfig(f.app.cfg.ui.notes_sort));
    const cfg = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/config.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "notes_sort") != null);
    try click.at(&f.app, sort_chip.?, .right);
    try testing.expect(f.app.overlay == .menu);
    try testing.expect(f.app.overlay.menu.items[1].checked);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // Delete the selected note through the confirm.
    try f.app.handle(.{ .key = Key.char('x') });
    try testing.expect(f.app.overlay == .confirm);
    try f.app.handle(.{ .key = Key.char('d') });
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 1), f.app.notes.items.len);
}
