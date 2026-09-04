//! TODOS — the reference module (D8). The smallest subsystem that walks
//! every convention, so every later one (notes, findings, sessions, git,
//! lsp…) is written against this file. Each convention is marked where
//! it lands; `docs/CONVENTIONS.md` points back at these lines.
//!
//!   D1  payload ownership — `ScanResult` is built by the worker, owned
//!       by the `.todos` event, and adopted-or-freed in `handle`;
//!   D1  snapshot arena — `State.snapshot` holds the item strings until
//!       the next scan lands;
//!   D3  cancellation — one `Io.Group`; `refresh` cancels the scan in
//!       flight, bumps `generation`, starts another; a stale result is
//!       dropped on receipt;
//!   D5  the command table — `pub const table`, merged at comptime;
//!   D10 a Zig hook subscriber — `onSavePost` rescans after a save;
//!   D6  component draw + hit registration through `ListPanel(Item)`;
//!   D6  mouse routing — `dispatch.zig` switches on the hit and calls
//!       the `*Mouse` functions here.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const App = app_mod.App;
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

pub const Tag = enum {
    todo,
    fixme,
    xxx,
    hack,
    review,

    pub const all = [_]Tag{ .todo, .fixme, .xxx, .hack, .review };

    /// The marker as written in a comment. Case-sensitive on purpose.
    pub fn label(t: Tag) []const u8 {
        return switch (t) {
            .todo => "TODO",
            .fixme => "FIXME",
            .xxx => "XXX",
            .hack => "HACK",
            .review => "REVIEW",
        };
    }
};

/// One marker hit. Slices borrow from `ScanResult.arena` while the
/// result is in flight, and from `State.snapshot` once adopted.
pub const Item = struct {
    tag: Tag,
    /// Workspace-relative path.
    path: []const u8,
    /// 1-based.
    line: u32,
    title: []const u8,
    /// File mtime in seconds; 0 when unknown. Drives Newest/Oldest.
    mtime: i64,
};

/// A finished scan, built by the worker on its own arena and posted as
/// `.todos`. D1: the payload is owned by the event — `handle` copies
/// what it keeps into the snapshot arena and destroys the box before
/// returning. There is no third option.
pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    truncated: bool = false,
    /// Which `refresh` request produced this; stale results are dropped.
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

/// Runners, merged into `command.runners` at comptime (D5). A menu row
/// names one of these as `MenuAction{ .command = .@"todos.open" }`, so a
/// row cannot point at an id that does not exist.
pub const table = .{
    .@"todos.refresh" = &refreshCmd,
    .@"todos.new" = &newCmd,
    .@"todos.sort" = &sortCmd,
    .@"todos.open" = &openCmd,
    .@"todos.copy_path" = &copyPathCmd,
    .@"todos.ignore_file" = &ignoreFileCmd,
};

/// The walk stops here; the header says `+` when it did.
pub const scan_cap: usize = 1000;
/// Files past this are skipped unread.
pub const max_file_bytes: usize = 1024 * 1024;
/// Never entered. Dot-directories are skipped besides (`.git`,
/// `.zig-cache`, `.mnml`…), which is also why `.gitignore` is not
/// consulted: the fixed list covers what a matcher would, at no cost.
const skip_dirs = [_][]const u8{ "node_modules", "target", "zig-out", "zig-cache", "dist", "build", "vendor" };
/// Text files worth reading. A binary check runs on the bytes too.
const scan_exts = [_][]const u8{ "zig", "zon", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "java", "kt", "swift", "cs", "cpp", "cc", "c", "h", "hpp", "rb", "sh", "lua", "yml", "yaml", "toml", "md", "markdown", "txt", "html", "css", "scss", "sql", "vue", "svelte", "test" };
/// A second click on the selected row within this window opens it.
const double_click_ms: i64 = 500;

pub const State = struct {
    /// D3: every scan worker runs in this group; `refresh` cancels it.
    group: Io.Group = .init,
    /// D1: the snapshot tier — item strings live here until the next
    /// scan lands, when `reset` drops them all at once.
    snapshot: alloc.SnapshotArena,
    /// Borrowed from `snapshot`. Sorted by `sort`.
    items: []Item = &.{},
    /// Indices into `items` that pass the filter, in display order.
    filtered: std.ArrayListUnmanaged(u32) = .empty,
    list: Panel.State = .{},
    sort: ListSort = .newest,
    /// Bumped by every `refresh`; a result carrying an older number
    /// belongs to a scan that was cancelled or superseded.
    generation: u32 = 0,
    scanning: bool = false,
    truncated: bool = false,
    /// The panel has been shown (or refreshed) at least once; the
    /// save hook only rescans a panel someone has looked at.
    scanned_once: bool = false,
    /// Files hidden by `todos.ignore_file` this session. Owned keys.
    ignored: std.StringHashMapUnmanaged(void) = .empty,
    /// The last left press on a row, for double-click detection.
    last_click: ?struct { idx: u32, at_ms: i64 } = null,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    /// Cancels the scan in flight and waits for it — the worker borrows
    /// `app.workspace` and posts into `app.events`, so neither may go
    /// before it has returned.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        var it = self.ignored.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.ignored.deinit(gpa);
        self.filtered.deinit(gpa);
        self.list.deinit(gpa);
        self.snapshot.deinit();
    }

    /// The item under the cursor, in display order.
    pub fn selected(self: *const State) ?Item {
        if (self.list.cursor >= self.filtered.items.len) return null;
        return self.items[self.filtered.items[self.list.cursor]];
    }
};

/// D10.2: subscribed in `App.initWith`. A save may have added or
/// removed a marker; rescan, but only once the panel has been used.
pub fn onSavePost(app: *App, _: hooks.HookArgs) void {
    if (!app.todos.scanned_once) return;
    refresh(app) catch {};
}

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

/// Cancel any scan in flight, bump the generation, start a new one.
/// `group.cancel` waits for the old worker, which answers within one
/// file (`checkCancel` per file, and every read is a cancel point).
pub fn refresh(app: *App) CommandError!void {
    const st = &app.todos;
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.scanning = true;
    st.scanned_once = true;
    app.needs_render = true;
    st.group.concurrent(app.io, scanWorker, .{ &app.events, app.io, app.gpa, app.workspace, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "todos: could not start the scan: {s}", .{@errorName(err)});
    };
}

/// The worker. D1: it owns `result` until the post succeeds — an
/// `errdefer` frees it on cancel or OOM, `post` hands it to the event
/// (and frees it itself if the queue is already closed). D3: returning
/// `error.Canceled` is how a cancelled task ends; the group swallows it.
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
    events.post(io, .{ .todos = result });
}

/// Workers never toast (D2); the handler turns this into one.
fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .todos, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

fn isCanceled(err: anyerror) bool {
    return err == error.Canceled;
}

/// Walk `workspace` and fill `r.items` on `r.arena`. Directory order is
/// whatever the file system gives; `handle` sorts.
pub fn scanInto(io: Io, gpa: Allocator, workspace: []const u8, r: *ScanResult) ScanError!void {
    const arena = r.arena.allocator();
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var root = Io.Dir.cwd().openDir(io, workspace, .{ .iterate = true }) catch |err| {
        if (isCanceled(err)) return error.Canceled;
        return;
    };
    defer root.close(io);
    var walker = try root.walkSelectively(gpa);
    defer walker.deinit();
    while (true) {
        const entry = walker.next(io) catch |err| {
            if (isCanceled(err)) return error.Canceled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue; // an unreadable directory was popped; keep walking
        } orelse break;
        if (items.items.len >= scan_cap) {
            r.truncated = true;
            break;
        }
        switch (entry.kind) {
            .directory => if (!skipDir(entry.basename)) {
                walker.enter(io, entry) catch |err| {
                    if (isCanceled(err)) return error.Canceled;
                };
            },
            .file => if (wantsFile(entry.basename)) {
                try io.checkCancel();
                try scanFile(io, gpa, arena, entry.dir, entry.basename, entry.path, &items);
            },
            else => {},
        }
    }
    r.items = items.items;
}

fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

fn wantsFile(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (scan_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Read one file and append its markers. `rel` is the workspace-relative
/// path the walker hands out (invalid after the next step — duped once
/// onto the arena when the file has a hit).
fn scanFile(io: Io, gpa: Allocator, arena: Allocator, dir: Io.Dir, basename: []const u8, rel: []const u8, items: *std.ArrayListUnmanaged(Item)) ScanError!void {
    const st = dir.statFile(io, basename, .{}) catch |err| {
        if (isCanceled(err)) return error.Canceled;
        return;
    };
    if (st.size > max_file_bytes) return;
    const content = dir.readFileAlloc(io, basename, gpa, .limited(max_file_bytes)) catch |err| {
        if (isCanceled(err)) return error.Canceled;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    defer gpa.free(content);
    if (looksBinary(content)) return;
    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const found = matchLine(line, isMarkdown(basename)) orelse continue;
        if (path == null) path = try arena.dupe(u8, rel);
        try items.append(arena, .{
            .tag = found.tag,
            .path = path.?,
            .line = line_no,
            .title = try arena.dupe(u8, found.title),
            .mtime = st.mtime.toSeconds(),
        });
        if (items.items.len >= scan_cap) return;
    }
}

fn looksBinary(content: []const u8) bool {
    const head = content[0..@min(content.len, 8192)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return true;
    return !std.unicode.utf8ValidateSlice(content);
}

fn isMarkdown(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".md") or std.ascii.endsWithIgnoreCase(name, ".markdown");
}

pub const LineHit = struct { tag: Tag, title: []const u8 };

/// The Rust scanner's rule, kept: the marker must follow a comment
/// opener (`//`, `#`, `/*`, `--`, `<!--`) on its line — or, in
/// markdown, only list / heading / quote punctuation — and must end at
/// a word boundary so `TODOLIST` is not a TODO. One marker per line.
pub fn matchLine(line: []const u8, markdown: bool) ?LineHit {
    for (Tag.all) |tag| {
        const word = tag.label();
        const pos = std.mem.indexOf(u8, line, word) orelse continue;
        const prefix = line[0..pos];
        const commented = std.mem.indexOf(u8, prefix, "//") != null or
            std.mem.indexOfScalar(u8, prefix, '#') != null or
            std.mem.indexOf(u8, prefix, "/*") != null or
            std.mem.indexOf(u8, prefix, "--") != null or
            std.mem.indexOf(u8, prefix, "<!--") != null;
        const md_item = markdown and std.mem.trimStart(u8, prefix, " \t0123456789-*+#>.)[]").len == 0;
        if (!commented and !md_item) continue;
        const after = line[pos + word.len ..];
        if (after.len > 0 and (std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) continue;
        var title = std.mem.trim(u8, std.mem.trimStart(u8, after, ":() "), " \t");
        if (title.len > 120) {
            var cut: usize = 120;
            while (cut > 0 and (title[cut] & 0xC0) == 0x80) cut -= 1;
            title = title[0..cut];
        }
        return .{ .tag = tag, .title = title };
    }
    return null;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

/// D1: `result` is ours to adopt or free — it is destroyed on every
/// path out of here. A stale generation is dropped whole (D3: the scan
/// that produced it was cancelled or superseded, and its items describe
/// a workspace older than the one the newer scan will report).
pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.todos;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    st.scanning = false;
    st.truncated = result.truncated;
    // The snapshot is replaced wholesale: reset, then copy every string
    // in. Paths repeat per file and the walker groups a file's hits, so
    // a path equal to the previous item's is shared, not copied again.
    st.snapshot.reset();
    st.items = &.{};
    const arena = st.snapshot.allocator();
    const items = try arena.alloc(Item, result.items.len);
    var prev_src: []const u8 = "";
    var prev_dst: []const u8 = "";
    for (result.items, 0..) |it, i| {
        const path = if (it.path.ptr == prev_src.ptr and it.path.len == prev_src.len) prev_dst else try arena.dupe(u8, it.path);
        prev_src = it.path;
        prev_dst = path;
        items[i] = .{ .tag = it.tag, .path = path, .line = it.line, .title = try arena.dupe(u8, it.title), .mtime = it.mtime };
    }
    st.items = items;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

/// Line order within a file is ascending in every mode; the modes order
/// the files (by mtime or by path), as the Rust panel does.
fn sortItems(st: *State) void {
    const Ctx = struct {
        sort: ListSort,
        fn lt(ctx: @This(), a: Item, b: Item) bool {
            switch (ctx.sort) {
                .newest => if (a.mtime != b.mtime) return a.mtime > b.mtime,
                .oldest => if (a.mtime != b.mtime) return a.mtime < b.mtime,
                .name, .name_desc => {},
            }
            const by_path = std.mem.order(u8, a.path, b.path);
            if (by_path != .eq) return if (ctx.sort == .name_desc) by_path == .gt else by_path == .lt;
            return a.line < b.line;
        }
    };
    std.mem.sort(Item, st.items, Ctx{ .sort = st.sort }, Ctx.lt);
}

/// The filter is a case-insensitive substring over the marker, the
/// title and the relative path. Ignored files never show.
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.todos;
    st.filtered.clearRetainingCapacity();
    const q = st.list.filterText();
    for (st.items, 0..) |it, i| {
        if (st.ignored.contains(it.path)) continue;
        if (q.len > 0 and !matches(it, q)) continue;
        try st.filtered.append(app.gpa, @intCast(i));
    }
    if (st.list.cursor >= st.filtered.items.len) st.list.cursor = st.filtered.items.len -| 1;
}

fn matches(it: Item, q: []const u8) bool {
    return containsIgnoreCase(it.tag.label(), q) or containsIgnoreCase(it.title, q) or containsIgnoreCase(it.path, q);
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

pub fn setSort(app: *App, sort: ListSort) Allocator.Error!void {
    const st = &app.todos;
    st.sort = sort;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return refresh(app);
}

fn sortCmd(app: *App) CommandError!void {
    try setSort(app, app.todos.sort.next());
    app.toast("sort: {s}", .{app.todos.sort.label()});
}

/// `+ New todo`: a prompt whose text lands under `## Inbox` in the
/// workspace `TODO.md` (see `appendTodo`).
fn newCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New TODO (appended to TODO.md)"), .purpose = .new_todo } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Insert `- TODO: <text>` directly under `## Inbox` (created when
/// missing) so entries collect in one place, newest first. The file is
/// the workspace's own backlog, not a `.mnml/` sink the scanner skips.
pub fn appendTodo(app: *App, text_in: []const u8) CommandError!void {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return;
    const arena = app.frame.allocator();
    const path = try std.fs.path.join(arena, &.{ app.workspace, "TODO.md" });
    const inbox = "## Inbox";
    const existing = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(max_file_bytes)) catch "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const trimmed = std.mem.trim(u8, existing, " \t\r\n");
    if (trimmed.len == 0) {
        try out.print(arena, "# TODO\n\n{s}\n", .{inbox});
    } else if (std.mem.indexOf(u8, existing, inbox) != null) {
        try out.appendSlice(arena, existing);
    } else {
        try out.print(arena, "{s}\n\n{s}\n", .{ std.mem.trimEnd(u8, existing, " \t\r\n"), inbox });
    }
    const at = std.mem.indexOf(u8, out.items, inbox).? + inbox.len;
    const line_end = if (std.mem.indexOfScalarPos(u8, out.items, at, '\n')) |n| n + 1 else out.items.len;
    const entry = try std.fmt.allocPrint(arena, "- TODO: {s}\n", .{text});
    try out.insertSlice(arena, line_end, entry);
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch |err| {
        return app.diag.fail(arena, "todo: write failed: {s}", .{@errorName(err)});
    };
    // A clean buffer showing TODO.md is stale now: give it the new text.
    if (app.panes.findPath(path)) |id| if (app.panes.editor(id)) |e| if (!e.buf.dirty) {
        e.buf.editor.setText(out.items) catch return error.OutOfMemory;
        e.buf.markSaved() catch return error.OutOfMemory;
        e.hl_dirty = true;
    };
    app.toast("todo added to TODO.md", .{});
    try refresh(app);
}

/// `enter` / double-click / the kebab's first row: the marker's file
/// opens in an editor pane with the cursor on its line.
fn openCmd(app: *App) CommandError!void {
    return openSelected(app);
}

pub fn openSelected(app: *App) CommandError!void {
    const it = app.todos.selected() orelse return app.diag.fail(app.frame.allocator(), "todos: nothing selected", .{});
    return openItem(app, it);
}

pub fn openItem(app: *App, it: Item) CommandError!void {
    const arena = app.frame.allocator();
    // The item borrows the snapshot; `openPath` emits hooks that may
    // rescan, so hold a frame copy of what is still needed after it.
    const rel = try arena.dupe(u8, it.path);
    const line = it.line;
    const abs = try app.absPath(rel);
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (app.panes.editor(id)) |e| {
        const ed = &e.buf.editor;
        ed.anchor = null;
        ed.placeCursor(@min(@as(usize, line) -| 1, ed.lineCount() -| 1), 0);
        // Centre the line; `render` clamps the scroll.
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    }
}

fn copyPathCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.todos.selected() orelse return app.diag.fail(arena, "todos: nothing selected", .{});
    const text = try std.fmt.allocPrint(arena, "{s}:{d}", .{ it.path, it.line });
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// Hide every marker in the selected item's file for this session.
/// (Persisting the list is Phase 1 — the ZON config.)
fn ignoreFileCmd(app: *App) CommandError!void {
    const st = &app.todos;
    const it = st.selected() orelse return app.diag.fail(app.frame.allocator(), "todos: nothing selected", .{});
    if (!st.ignored.contains(it.path)) {
        const key = try app.gpa.dupe(u8, it.path);
        errdefer app.gpa.free(key);
        try st.ignored.put(app.gpa, key, {});
    }
    app.toast("ignoring {s} for this session", .{it.path});
    try refilter(app);
}

// ─── keys ───────────────────────────────────────────────────────────────

/// Keys while the panel has focus. The list's own keys first (motion,
/// the filter, enter); then the panel's letters. Returns false for a
/// key the chord chain should see.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.todos;
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
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// A command reached outside `command.run`: toast the reason the same way.
fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("todos: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

/// A row: left press selects (a second one within `double_click_ms`
/// opens); right press selects and opens the row menu; the wheel moves
/// the cursor three rows.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.todos;
    switch (m.kind) {
        .press => {
            if (idx >= st.filtered.items.len) return;
            focusPanel(app);
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, openSelected(app));
            }
        },
        .scroll_up => st.list.cursor -|= 3,
        .scroll_down => st.list.cursor = @min(st.list.cursor + 3, st.filtered.items.len -| 1),
        else => {},
    }
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.todos.filtered.items.len) return;
    focusPanel(app);
    app.todos.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

/// The `sort:` chip cycles on a left press and lists every mode with a
/// tick on a right press; the refresh chip rescans.
pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => runToast(app, refresh(app)),
        .new => runToast(app, newCmd(app)),
        .view => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.todos.list.filter_focused = true;
}

/// A press on the scrollbar jumps the cursor to the proportional row.
pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.todos;
    const total = st.filtered.items.len;
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
    app.focus = .{ .panel = .todos };
    app.needs_render = true;
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open", .action = .{ .command = .@"todos.open" } },
        .{ .label = "Copy path", .action = .{ .command = .@"todos.copy_path" } },
        .{ .label = "Ignore file", .action = .{ .command = .@"todos.ignore_file" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("TODO", items, x, y);
}

fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.alloc(command.MenuItem, ListSort.all.len);
    errdefer app.gpa.free(items);
    for (ListSort.all, 0..) |s, i| items[i] = .{
        .label = s.label(),
        .action = .{ .set_panel_sort = .{ .panel = .todos, .sort = s } },
        .checked = s == app.todos.sort,
    };
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.todos;
    // The first time the panel is shown it scans (Rust parity).
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    const rows = try ui.arena.alloc(Item, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = st.items[idx];
    const cap: []const u8 = if (st.truncated) "+" else "";
    const subtitle = if (st.list.filterText().len == 0)
        ui.fmt(" ({d}{s})", .{ st.items.len, cap })
    else
        ui.fmt(" ({d} of {d}{s})", .{ rows.len, st.items.len, cap });
    const refresh_glyph = chip.refreshIcon(ui.ascii);
    const empty: list_panel.EmptyState = if (st.scanning and st.items.len == 0)
        .{ .message = "Scanning the workspace…", .hint = "Markers appear as they are found." }
    else if (st.items.len == 0)
        .{ .message = ui.fmt("No markers found — click{s}in the header to rescan.", .{refresh_glyph}), .hint = "Scans for TODO / FIXME / XXX / HACK / REVIEW." }
    else
        .{ .message = "No matches — Esc clears" };
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .todos,
        .label = "TODOS",
        .subtitle = subtitle,
        .sort_chip = st.sort.label(),
        .sort_widest = ListSort.widest_label,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.scanning) paintSpinner(app, ui, area);
}

/// While a scan runs the refresh chip shows a spinner. The chip's cells
/// are the header's last three when it fits (`header.zig`'s ladder);
/// they are overpainted here and the hit registered under them stays.
/// // changed: `ListPanel.Props` has no `busy` flag yet — a `ui`-side
/// addition would let the header paint this itself.
fn paintSpinner(app: *App, ui: Ui, area: Rect) void {
    const label_w: u16 = 5; // "TODOS"
    if (area.w < label_w + 3 + 3 or area.h == 0) return;
    const frames: []const []const u8 = if (ui.ascii) &spinner_ascii else &spinner_frames;
    const idx: usize = @intCast(@mod(@divFloor(app.now_ms, 80), @as(i64, @intCast(frames.len))));
    const style = chip.refreshStyle(ui.theme, ui.theme.panel_bg.bg);
    const x = area.right() - 3;
    _ = ui.putStr(x, area.y, 1, " ", style);
    _ = ui.putStr(x + 1, area.y, 1, frames[idx], style);
    _ = ui.putStr(x + 2, area.y, 1, " ", style);
}

fn tagStyle(t: *const Theme, tag: Tag, base: vaxis.Style) vaxis.Style {
    var s = Theme.withFg(base, switch (tag) {
        .todo => t.info_fg.fg,
        .fixme => t.warn_fg.fg,
        .xxx, .hack => t.error_fg.fg,
        .review => t.accent.fg,
    });
    s.bold = true;
    return s;
}

/// `<marker> <title>  <rel/path>:<line>` — the marker coloured by kind,
/// the location dim. When both do not fit the title keeps what it can
/// and the location is clipped from the LEFT, so `…main.zig:3` still
/// says which file and line; the location never drops below
/// `min_loc` cells, so a long title cannot squeeze it out entirely.
fn paintRow(ui: Ui, r: Rect, row: Item, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    var x = r.x;
    const end = r.right();
    x += ui.putStr(x, r.y, end -| x, row.tag.label(), tagStyle(t, row.tag, base));
    x += ui.putStr(x, r.y, end -| x, " ", base);
    const loc = ui.fmt("{s}:{d}", .{ row.path, row.line });
    const min_loc: u16 = 10;
    const avail: u16 = end -| x;
    const title_w = ui.width(row.title);
    const loc_w = ui.width(loc);
    var title = row.title;
    var loc_shown = loc;
    if (title_w + 2 + loc_w > avail) {
        const loc_keep = @min(loc_w, min_loc);
        const title_max = avail -| (2 + loc_keep);
        title = ui.clipStr(row.title, title_max);
        const loc_max = avail -| (ui.width(title) + 2);
        loc_shown = clipLeft(ui, loc, loc_max);
    }
    x += ui.putStr(x, r.y, end -| x, title, Theme.onBg(t.fg, base.bg));
    x += ui.putStr(x, r.y, end -| x, "  ", base);
    _ = ui.putStr(x, r.y, end -| x, loc_shown, Theme.onBg(t.muted, base.bg));
}

/// `s` cut to `max` cells keeping its END, with the ellipsis in front.
fn clipLeft(ui: Ui, s: []const u8, max: u16) []const u8 {
    if (ui.width(s) <= max) return s;
    const ell: []const u8 = if (ui.ascii) "..." else "…";
    const ell_w = ui.width(ell);
    if (max <= ell_w) return "";
    var start: usize = 0;
    while (start < s.len and ui.width(s[start..]) > max - ell_w) {
        start += std.unicode.utf8ByteSequenceLength(s[start]) catch 1;
    }
    return ui.fmt("{s}{s}", .{ ell, s[start..] });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "matchLine: comment openers, markdown items, word boundaries, one marker per line" {
    try testing.expectEqualStrings("wire it up", matchLine("    // TODO: wire it up", false).?.title);
    try testing.expectEqual(Tag.fixme, matchLine("x = 1  # FIXME(leaks) on error", false).?.tag);
    try testing.expectEqualStrings("leaks) on error", matchLine("x = 1  # FIXME(leaks) on error", false).?.title);
    try testing.expect(matchLine("let todolist = TODOLIST;", false) == null);
    try testing.expect(matchLine("const x = \"TODO\";", false) == null);
    try testing.expect(matchLine("- TODO: buy milk", true) != null);
    try testing.expect(matchLine("Later we TODO this", true) == null);
    try testing.expect(matchLine("- TODO: buy milk", false) == null);
    try testing.expectEqual(Tag.xxx, matchLine("/* XXX HACK */", false).?.tag);
    try testing.expectEqual(Tag.review, matchLine("<!-- REVIEW before merge -->", false).?.tag);
    try testing.expectEqualStrings("", matchLine("// TODO", false).?.title);
}

test "wantsFile and skipDir follow the fixed lists" {
    try testing.expect(wantsFile("main.zig"));
    try testing.expect(wantsFile("README.MD"));
    try testing.expect(!wantsFile("photo.png"));
    try testing.expect(!wantsFile("Makefile"));
    try testing.expect(skipDir(".git"));
    try testing.expect(skipDir("node_modules"));
    try testing.expect(!skipDir("src"));
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

    /// Tick until the scan lands (or `max` ticks pass).
    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (f.app.todos.scanning and i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (f.app.todos.scanning) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

test "scanInto finds markers across files, skips noisy dirs and binaries, records mtime" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.write("src/a.zig", "const a = 1;\n// TODO: first\n// FIXME leaks\n");
    try f.write("docs/notes.md", "# Notes\n- TODO: buy milk\nLater we TODO this, mid-sentence\n");
    try f.write("node_modules/x.js", "// TODO: never seen\n");
    try f.write(".git/config", "# TODO: never seen\n");
    try f.write("blob.zig", "// TODO: binary\x00\n");
    try f.write("image.png", "// TODO: wrong extension\n");
    const r = try ScanResult.create(testing.allocator, 1);
    defer r.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.root, r);
    try testing.expectEqual(@as(usize, 3), r.items.len);
    var seen_a: usize = 0;
    for (r.items) |it| {
        try testing.expect(it.mtime > 0);
        if (std.mem.eql(u8, it.path, "src/a.zig")) {
            seen_a += 1;
            try testing.expect(it.line == 2 or it.line == 3);
        } else {
            try testing.expectEqualStrings("docs/notes.md", it.path);
            try testing.expectEqualStrings("buy milk", it.title);
        }
    }
    try testing.expectEqual(@as(usize, 2), seen_a);
}

test "handle adopts a matching generation, drops a stale one, and frees both" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.todos;
    st.generation = 3;
    const fresh = try ScanResult.create(testing.allocator, 3);
    const items = try fresh.arena.allocator().alloc(Item, 2);
    items[0] = .{ .tag = .todo, .path = "b.zig", .line = 4, .title = "second", .mtime = 10 };
    items[1] = .{ .tag = .fixme, .path = "a.zig", .line = 9, .title = "first", .mtime = 20 };
    fresh.items = items;
    try handle(&f.app, fresh);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    // Newest first: a.zig (mtime 20) before b.zig.
    try testing.expectEqualStrings("a.zig", st.items[0].path);
    try testing.expectEqual(@as(usize, 2), st.filtered.items.len);
    // A stale result (an older generation) is dropped whole.
    const stale = try ScanResult.create(testing.allocator, 2);
    const stale_items = try stale.arena.allocator().alloc(Item, 1);
    stale_items[0] = .{ .tag = .hack, .path = "z.zig", .line = 1, .title = "stale", .mtime = 99 };
    stale.items = stale_items;
    try handle(&f.app, stale);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    try testing.expectEqualStrings("a.zig", st.items[0].path);
}

test "sort modes order files and keep a file's lines ascending; the filter is case-insensitive over marker, title and path" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.todos;
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 4);
    items[0] = .{ .tag = .todo, .path = "src/b.zig", .line = 30, .title = "Beta", .mtime = 5 };
    items[1] = .{ .tag = .todo, .path = "src/b.zig", .line = 2, .title = "alpha", .mtime = 5 };
    items[2] = .{ .tag = .fixme, .path = "src/a.zig", .line = 7, .title = "Gamma", .mtime = 9 };
    items[3] = .{ .tag = .review, .path = "docs/c.md", .line = 1, .title = "delta", .mtime = 1 };
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    // newest: a (9), b (5, lines 2 then 30), c (1)
    try testing.expectEqualStrings("src/a.zig", st.items[0].path);
    try testing.expectEqual(@as(u32, 2), st.items[1].line);
    try testing.expectEqual(@as(u32, 30), st.items[2].line);
    try testing.expectEqualStrings("docs/c.md", st.items[3].path);
    try setSort(&f.app, .oldest);
    try testing.expectEqualStrings("docs/c.md", st.items[0].path);
    try testing.expectEqual(@as(u32, 2), st.items[1].line);
    try setSort(&f.app, .name);
    try testing.expectEqualStrings("docs/c.md", st.items[0].path);
    try testing.expectEqualStrings("src/a.zig", st.items[1].path);
    try testing.expectEqual(@as(u32, 2), st.items[2].line);
    try setSort(&f.app, .name_desc);
    try testing.expectEqualStrings("src/b.zig", st.items[0].path);
    try testing.expectEqual(@as(u32, 2), st.items[0].line);
    try testing.expectEqualStrings("docs/c.md", st.items[3].path);

    try st.list.filter.appendSlice(testing.allocator, "ALPHA");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqualStrings("alpha", st.selected().?.title);
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "fix");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqual(Tag.fixme, st.selected().?.tag);
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "DOCS/");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    st.list.filter.clearRetainingCapacity();
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 4), st.filtered.items.len);
}

test "cancel-on-rescan: a second refresh cancels the first; only the last generation lands; nothing leaks" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    // Enough files that a scan takes a while.
    var i: usize = 0;
    var name_buf: [64]u8 = undefined;
    while (i < 400) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "pkg{d}/f{d}.zig", .{ i % 20, i });
        try f.write(name, "// TODO: item\nconst x = 1;\n");
    }
    const st = &f.app.todos;
    try refresh(&f.app);
    try testing.expectEqual(@as(u32, 1), st.generation);
    try refresh(&f.app);
    try refresh(&f.app);
    try testing.expectEqual(@as(u32, 3), st.generation);
    try testing.expect(st.scanning);
    try f.settle(2000);
    try testing.expect(!st.scanning);
    try testing.expectEqual(@as(usize, 400), st.items.len);
    // Whatever the cancelled workers posted was dropped by generation:
    // the queue is empty and the dataset is the third scan's.
    var buf: [8]event.AppEvent = undefined;
    try testing.expectEqual(@as(usize, 0), f.app.events.drain(f.app.io, &buf));
    // A refresh with the worker still running, then deinit (through the
    // fixture) — the group is cancelled before the queue closes.
    try refresh(&f.app);
    try testing.expect(st.scanning);
}

test "headless smoke: two TODOs in a file, refresh, the panel lists both and row 0 hits as .row{todos,0}" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write("src/main.zig", "// TODO: wire the frobnicator\nconst x = 1;\n// FIXME: leaks on error\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_todos" });
    try testing.expect(f.app.focus == .panel);
    try command.run(&f.app, .{ .static = .@"todos.refresh" });
    try f.settle(2000);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "TODOS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "wire the frobnicator") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "leaks on error") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "main.zig:3") != null);
    var row0: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .row and h.target.row.idx == 0) {
        row0 = h.rect;
    };
    try testing.expect(row0 != null);
    const target = f.app.hits.at(row0.?.x + 2, row0.?.y).?;
    try testing.expect(target == .row);
    try testing.expectEqual(panel.PanelId.todos, target.row.panel);
    try testing.expectEqual(@as(u32, 0), target.row.idx);
    // Enter opens the selected marker at its line.
    try f.app.handle(.{ .key = Key.named(.enter) });
    const e = f.app.activeEditor().?;
    try testing.expectEqualStrings("main.zig", f.app.panes.get(f.app.active.?).?.title());
    try testing.expect(e.buf.editor.currentLine() == 0 or e.buf.editor.currentLine() == 2);
    try testing.expect(f.app.focus == .pane);
}

test "mouse: a click selects, a second opens; the sort chip cycles and its right-click lists every mode; ignore hides a file" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write("a.zig", "// TODO: one\n");
    try f.write("b.zig", "// HACK: two\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_todos" });
    // The first draw starts the scan; the second paints its result.
    try f.app.render();
    try f.settle(2000);
    try f.app.render();
    var row1: ?Rect = null;
    var sort_chip: ?Rect = null;
    for (f.app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.idx == 1) {
            row1 = h.rect;
        },
        .chip => |c| if (c.kind == .sort) {
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
    try click.at(&f.app, row1.?, .left);
    try testing.expectEqual(@as(usize, 1), f.app.todos.list.cursor);
    try testing.expect(f.app.focus == .panel);
    try testing.expect(f.app.active == null);
    try click.at(&f.app, row1.?, .left);
    try testing.expect(f.app.active != null);
    try testing.expect(f.app.focus == .pane);
    // The sort chip.
    try f.app.render();
    const before = f.app.todos.sort;
    try click.at(&f.app, sort_chip.?, .left);
    try testing.expectEqual(before.next(), f.app.todos.sort);
    try click.at(&f.app, sort_chip.?, .right);
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(ListSort.all.len, f.app.overlay.menu.items.len);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "Sort by") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Name (Z–A)") != null);
    // Pick "Oldest first" through the menu's hit.
    var oldest: ?Rect = null;
    for (f.app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.idx == 1) {
        oldest = h.rect;
    };
    try click.at(&f.app, oldest.?, .left);
    try testing.expect(f.app.overlay == .none);
    try testing.expectEqual(ListSort.oldest, f.app.todos.sort);
    // The row menu: ignore the selected file.
    try f.app.render();
    try click.at(&f.app, row1.?, .right);
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(@as(usize, 3), f.app.overlay.menu.items.len);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(f.app.overlay == .none);
    try command.run(&f.app, .{ .static = .@"todos.ignore_file" });
    try testing.expectEqual(@as(usize, 1), f.app.todos.filtered.items.len);
}

test "todos.new appends under ## Inbox and rescans; the save hook rescans a used panel" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.write("TODO.md", "# Backlog\n\n- old item\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"todos.new" });
    try testing.expect(f.app.overlay == .prompt);
    for ("ship it") |c| try f.app.handle(.{ .key = Key.char(c) });
    try f.app.handle(.{ .key = Key.named(.enter) });
    const back = try f.tmp.dir.readFileAlloc(testing.io, "TODO.md", testing.allocator, .limited(4096));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("# Backlog\n\n- old item\n\n## Inbox\n- TODO: ship it\n", back);
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 1), f.app.todos.items.len);
    try testing.expectEqualStrings("ship it", f.app.todos.items[0].title);
    // Save a file with a new marker: the hook rescans.
    const gen = f.app.todos.generation;
    try f.write("x.zig", "");
    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "x.zig" });
    defer testing.allocator.free(abs);
    _ = try f.app.openPath(abs);
    for ("// TODO: from a save\n") |c| try f.app.handle(.{ .key = Key.char(c) });
    try command.run(&f.app, .{ .static = .@"file.save" });
    try testing.expect(f.app.todos.generation > gen);
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 2), f.app.todos.items.len);
}
