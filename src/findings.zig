//! FINDINGS — the workspace's tester / review reports,
//! `<ws>/.mnml/findings/*.md`, on the `todos.zig` shape (D8) like
//! `notes.zig`: a scan worker posting `.findings = *ScanResult`, a
//! snapshot arena for the rows, `handle` adopting the payload, the
//! command table, the `ListPanel` draw with the shared `sort:` chip, a
//! row menu of real ids, and the mouse prongs `dispatch.zig` routes here.
//!
//! A finding is a markdown file with an optional frontmatter block:
//!
//!     ---
//!     severity: high
//!     status: open
//!     ---
//!     # The picker panics below 30 columns
//!
//! The row shows the severity tag, the file name, the title (the first
//! heading, else the first line) and the age; a resolved finding paints
//! dim. `findings.resolve` rewrites `status:` to `resolved` in place —
//! the report keeps its history and the row stays, greyed. `findings.new`
//! seeds a prompt with the next free `finding-N.md`; the file is created
//! with the frontmatter template and opened.

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
const todos = @import("todos.zig");
const notes = @import("notes.zig");
const tree_mod = @import("app/tree.zig");
const settings = @import("app/settings.zig");

/// Workspace-relative.
pub const dir_rel = ".mnml/findings";

/// `severity:` in the frontmatter. Aliases the tester agents use
/// (`SEV-1`, `S2`, `blocker`) map onto the five levels; anything else
/// is `unknown` and sorts last.
pub const Severity = enum {
    critical,
    high,
    medium,
    low,
    info,
    unknown,

    pub fn parse(s_in: []const u8) Severity {
        const s = std.mem.trim(u8, s_in, " \t\r\"'");
        const aliases = [_]struct { []const u8, Severity }{
            .{ "critical", .critical }, .{ "blocker", .critical }, .{ "sev-1", .critical }, .{ "sev1", .critical }, .{ "s1", .critical }, .{ "p0", .critical },
            .{ "high", .high },         .{ "major", .high },       .{ "sev-2", .high },     .{ "sev2", .high },     .{ "s2", .high },     .{ "p1", .high },
            .{ "medium", .medium },     .{ "moderate", .medium },  .{ "sev-3", .medium },   .{ "sev3", .medium },   .{ "s3", .medium },   .{ "p2", .medium },
            .{ "low", .low },           .{ "minor", .low },        .{ "sev-4", .low },      .{ "sev4", .low },      .{ "s4", .low },      .{ "p3", .low },
            .{ "info", .info },         .{ "note", .info },        .{ "nit", .info },       .{ "trivial", .info },
        };
        for (aliases) |row| if (std.ascii.eqlIgnoreCase(s, row[0])) return row[1];
        return .unknown;
    }

    /// The tag the row paints; four cells, so the columns line up.
    pub fn tag(s: Severity) []const u8 {
        return switch (s) {
            .critical => "CRIT",
            .high => "HIGH",
            .medium => "MED ",
            .low => "LOW ",
            .info => "INFO",
            .unknown => "    ",
        };
    }

    pub fn label(s: Severity) []const u8 {
        return @tagName(s);
    }
};

/// `status:` in the frontmatter.
pub const Status = enum {
    open,
    resolved,
    dismissed,
    unknown,

    pub fn parse(s_in: []const u8) Status {
        const s = std.mem.trim(u8, s_in, " \t\r\"'");
        const aliases = [_]struct { []const u8, Status }{
            .{ "open", .open },           .{ "new", .open },          .{ "todo", .open },           .{ "confirmed", .open },
            .{ "resolved", .resolved },   .{ "fixed", .resolved },    .{ "closed", .resolved },     .{ "done", .resolved },
            .{ "dismissed", .dismissed }, .{ "wontfix", .dismissed }, .{ "won't fix", .dismissed }, .{ "duplicate", .dismissed },
            .{ "invalid", .dismissed },
        };
        for (aliases) |row| if (std.ascii.eqlIgnoreCase(s, row[0])) return row[1];
        return .unknown;
    }

    pub fn label(s: Status) []const u8 {
        return @tagName(s);
    }
};

/// One finding. Slices borrow from `ScanResult.arena` in flight and
/// from `State.snapshot` once adopted.
pub const Item = struct {
    /// The file name without `.md`.
    name: []const u8,
    /// Workspace-relative path.
    path: []const u8,
    title: []const u8,
    severity: Severity,
    status: Status,
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
    .@"findings.refresh" = &refreshCmd,
    .@"findings.new" = &newCmd,
    .@"findings.sort" = &sortCmd,
    .@"findings.open" = &openCmd,
    .@"findings.copy_path" = &copyPathCmd,
    .@"findings.resolve" = &resolveCmd,
    .@"findings.delete" = &deleteCmd,
};

/// Bytes of a finding read for its frontmatter and title.
const head_bytes: usize = 64 * 1024;
const double_click_ms: i64 = 500;
/// The template `findings.new` writes.
pub const template_head = "---\nseverity: medium\nstatus: open\n---\n# ";

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

/// `open` / `save_post` subscriber: a file under the findings directory
/// changed shape; a used panel rescans.
pub fn onPathTouched(app: *App, args: hooks.HookArgs) void {
    const path = switch (args) {
        .open => |o| o.path,
        .save_post => |s| s.path,
        else => return,
    };
    if (!app.findings.scanned_once or !auto_refresh.on(app, .findings)) return;
    if (!isUnderDir(path)) return;
    refresh(app) catch {};
}

/// `tree.acceptDelete` removed `rel`; a used panel rescans when it was
/// a finding.
pub fn onPathRemoved(app: *App, rel: []const u8) void {
    if (!app.findings.scanned_once or !isUnderDir(rel) or !auto_refresh.on(app, .findings)) return;
    refresh(app) catch {};
}

fn isUnderDir(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, dir_rel ++ "/") and std.ascii.endsWithIgnoreCase(rel, ".md");
}

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

pub fn refresh(app: *App) CommandError!void {
    const st = &app.findings;
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.scanning = true;
    st.scanned_once = true;
    app.needs_render = true;
    st.group.concurrent(app.io, scanWorker, .{ app.events, app.io, app.gpa, app.workspace, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "findings: could not start the scan: {s}", .{@errorName(err)});
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
    events.post(io, .{ .findings = result });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .findings, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

/// List `<workspace>/.mnml/findings/*.md` (flat) into `r.items`. A
/// missing directory is an empty list, not an error.
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
        const meta = parseHead(head);
        try items.append(arena, .{
            .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - 3]),
            .path = try std.fs.path.join(arena, &.{ dir_rel, entry.name }),
            .title = try arena.dupe(u8, meta.title),
            .severity = meta.severity,
            .status = meta.status,
            .mtime = st.mtime.toSeconds(),
            .bytes = st.size,
        });
    }
    r.items = items.items;
}

pub const Head = struct { title: []const u8, severity: Severity, status: Status };

/// The frontmatter's `severity:` / `status:` (and `title:` when the
/// body has no heading), then the body's title as `notes.titleOf`
/// reads it. Without a frontmatter block, a `Severity:` / `Status:`
/// line (optionally `**bold**`) in the first forty lines still counts —
/// the tester agents write both shapes.
pub fn parseHead(text: []const u8) Head {
    var out: Head = .{ .title = "", .severity = .unknown, .status = .unknown };
    var fm_title: []const u8 = "";
    var body = text;
    if (frontmatter(text)) |fm| {
        body = fm.rest;
        var lines = std.mem.splitScalar(u8, fm.block, '\n');
        while (lines.next()) |raw| {
            const kv = keyValue(raw) orelse continue;
            if (std.ascii.eqlIgnoreCase(kv.key, "severity")) out.severity = Severity.parse(kv.value);
            if (std.ascii.eqlIgnoreCase(kv.key, "status")) out.status = Status.parse(kv.value);
            if (std.ascii.eqlIgnoreCase(kv.key, "title")) fm_title = std.mem.trim(u8, kv.value, " \t\r\"'");
        }
    } else {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |raw| : (n += 1) {
            if (n >= 40) break;
            const kv = keyValue(std.mem.trim(u8, raw, " \t\r*_-")) orelse continue;
            const value = std.mem.trim(u8, kv.value, " \t\r*_");
            if (out.severity == .unknown and std.ascii.eqlIgnoreCase(kv.key, "severity")) out.severity = Severity.parse(value);
            if (out.status == .unknown and std.ascii.eqlIgnoreCase(kv.key, "status")) out.status = Status.parse(value);
        }
    }
    out.title = notes.titleOf(body);
    if (out.title.len == 0) out.title = fm_title;
    return out;
}

const Frontmatter = struct { block: []const u8, rest: []const u8, start: usize, end: usize };

/// A leading `---` block. `block` is what is between the fences,
/// `rest` what follows the closing fence; `start`/`end` bound the
/// whole block in `text` for a rewrite.
fn frontmatter(text: []const u8) ?Frontmatter {
    if (!std.mem.startsWith(u8, text, "---")) return null;
    const first_nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    if (std.mem.trim(u8, text[3..first_nl], " \t\r").len != 0) return null;
    var pos = first_nl + 1;
    while (pos <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[pos..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            const rest_start = if (line_end < text.len) line_end + 1 else text.len;
            return .{ .block = text[first_nl + 1 .. pos], .rest = text[rest_start..], .start = 0, .end = rest_start };
        }
        if (line_end >= text.len) break;
        pos = line_end + 1;
    }
    return null;
}

fn keyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t\r");
    if (key.len == 0 or key.len > 32) return null;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return null;
    return .{ .key = key, .value = line[colon + 1 ..] };
}

/// `text` with `status: <value>` in its frontmatter: the existing line
/// rewritten, a missing line added before the closing fence, a missing
/// block prepended. Always returns a new string.
pub fn setStatusInText(arena: Allocator, text: []const u8, value: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (frontmatter(text)) |fm| {
        const block_start = std.mem.indexOfScalar(u8, text, '\n').? + 1;
        try out.appendSlice(arena, text[0..block_start]);
        var replaced = false;
        var lines = std.mem.splitScalar(u8, fm.block, '\n');
        while (lines.next()) |raw| {
            if (raw.len == 0 and lines.peek() == null) break;
            if (!replaced) if (keyValue(raw)) |kv| if (std.ascii.eqlIgnoreCase(kv.key, "status")) {
                try out.print(arena, "status: {s}\n", .{value});
                replaced = true;
                continue;
            };
            try out.appendSlice(arena, raw);
            try out.append(arena, '\n');
        }
        if (!replaced) try out.print(arena, "status: {s}\n", .{value});
        try out.appendSlice(arena, "---\n");
        try out.appendSlice(arena, fm.rest);
    } else {
        try out.print(arena, "---\nstatus: {s}\n---\n", .{value});
        try out.appendSlice(arena, text);
    }
    return out.toOwnedSlice(arena);
}

// ─── the event handler (D1) ─────────────────────────────────────────────

pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.findings;
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
        .severity = it.severity,
        .status = it.status,
        .mtime = it.mtime,
        .bytes = it.bytes,
    };
    st.items = items;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

/// The four shared modes. Within equal keys the severity orders
/// (critical first), so a batch of reports written together reads
/// worst-first.
fn sortItems(st: *State) void {
    const Ctx = struct {
        sort: ListSort,
        fn lt(ctx: @This(), a: Item, b: Item) bool {
            switch (ctx.sort) {
                .newest => if (a.mtime != b.mtime) return a.mtime > b.mtime,
                .oldest => if (a.mtime != b.mtime) return a.mtime < b.mtime,
                .name, .name_desc => {
                    const by_name = std.mem.order(u8, a.name, b.name);
                    if (by_name != .eq) return if (ctx.sort == .name_desc) by_name == .gt else by_name == .lt;
                },
            }
            if (a.severity != b.severity) return @intFromEnum(a.severity) < @intFromEnum(b.severity);
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(Item, st.items, Ctx{ .sort = st.sort }, Ctx.lt);
}

/// Case-insensitive substring over the name, the title, the severity
/// and the status — `high`, `resolved` and `open` all narrow.
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.findings;
    st.filtered.clearRetainingCapacity();
    const q = st.list.filterText();
    for (st.items, 0..) |it, i| {
        if (q.len > 0 and !matches(it, q)) continue;
        try st.filtered.append(app.gpa, @intCast(i));
    }
    if (st.list.cursor >= st.filtered.items.len) st.list.cursor = st.filtered.items.len -| 1;
}

fn matches(it: Item, q: []const u8) bool {
    return todos.containsIgnoreCase(it.name, q) or todos.containsIgnoreCase(it.title, q) or
        todos.containsIgnoreCase(it.severity.label(), q) or todos.containsIgnoreCase(it.status.label(), q);
}

pub fn setSort(app: *App, sort: ListSort) Allocator.Error!void {
    const st = &app.findings;
    st.sort = sort;
    sortItems(st);
    try refilter(app);
    app.needs_render = true;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return refresh(app);
}

/// The chip's click: the next mode, persisted as `ui.findings_sort`.
fn sortCmd(app: *App) CommandError!void {
    try setSort(app, app.findings.sort.next());
    app.cfg.ui.findings_sort = app.findings.sort.toConfig();
    _ = try settings.persist(app, .workspace, &.{ "ui", "findings_sort" }, app.cfg.ui.findings_sort);
    app.toast("findings: {s}", .{app.findings.sort.label()});
}

/// `+ New finding`: a prompt seeded with the next free `finding-N.md`.
fn newCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const abs_dir = try app.absPath(dir_rel);
    Io.Dir.cwd().createDirPath(app.io, abs_dir) catch |err| return app.diag.fail(arena, "findings: create {s}/: {s}", .{ dir_rel, @errorName(err) });
    const seed = try notes.nextFreeName(app, arena, abs_dir, "finding");
    const dir = try app.gpa.dupe(u8, dir_rel);
    errdefer app.gpa.free(dir);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New finding in " ++ dir_rel ++ "/"), .purpose = .{ .new_finding = dir } } };
    app.overlay.prompt.state.seed(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's accept: the file is written with the frontmatter
/// template first (a new finding is never an empty page), then created
/// + opened through the tree, then the panel rescans.
pub fn acceptNew(app: *App, dir: []const u8, text_in: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const text = try notes.withMdExt(arena, text_in);
    if (text.len > 0) {
        const rel = if (std.mem.indexOfScalar(u8, text, '/') == null and dir.len > 0) try std.fs.path.join(arena, &.{ dir, text }) else text;
        const abs = try app.absPath(rel);
        if (std.fs.path.dirname(rel)) |parent| Io.Dir.cwd().createDirPath(app.io, try app.absPath(parent)) catch {};
        Io.Dir.cwd().access(app.io, abs, .{}) catch {
            const stem = std.fs.path.stem(std.fs.path.basename(rel));
            const body = try std.fmt.allocPrint(arena, "{s}{s}\n\n", .{ template_head, stem });
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = body }) catch {};
        };
    }
    // The same `.md` name the file was written under: a bare name used
    // to open (and create) an extension-less twin beside it.
    try tree_mod.acceptNewFile(app, dir, text);
    if (app.findings.scanned_once) refresh(app) catch {};
}

fn openCmd(app: *App) CommandError!void {
    return openSelected(app);
}

pub fn openSelected(app: *App) CommandError!void {
    const it = app.findings.selected() orelse return app.diag.fail(app.frame.allocator(), "findings: nothing selected", .{});
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
    const it = app.findings.selected() orelse return app.diag.fail(arena, "findings: nothing selected", .{});
    const text = try arena.dupe(u8, it.path);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// `Mark resolved`: `status: resolved` lands in the file's frontmatter
/// (added when there is none). A clean buffer showing the file takes
/// the new text; the panel rescans.
fn resolveCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = app.findings.selected() orelse return app.diag.fail(arena, "findings: nothing selected", .{});
    if (it.status == .resolved) {
        app.toast("{s} is already resolved", .{it.name});
        return;
    }
    const rel = try arena.dupe(u8, it.path);
    const abs = try app.absPath(rel);
    const content = Io.Dir.cwd().readFileAlloc(app.io, abs, arena, .limited(todos.max_file_bytes)) catch |err| {
        return app.diag.fail(arena, "findings: read {s}: {s}", .{ rel, @errorName(err) });
    };
    const out = try setStatusInText(arena, content, "resolved");
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = out }) catch |err| {
        return app.diag.fail(arena, "findings: write {s}: {s}", .{ rel, @errorName(err) });
    };
    if (app.panes.findPath(abs)) |id| if (app.panes.editor(id)) |e| if (!e.buf.doc.dirty) {
        e.buf.editor.setText(out) catch return error.OutOfMemory;
        e.buf.markSaved() catch return error.OutOfMemory;
        e.syntax.dirty = true;
    };
    app.toast("resolved {s}", .{rel});
    try refresh(app);
}

/// Delete after a confirm — the tree's own delete box (`notes.confirmDelete`).
fn deleteCmd(app: *App) CommandError!void {
    const it = app.findings.selected() orelse return app.diag.fail(app.frame.allocator(), "findings: nothing selected", .{});
    return notes.confirmDelete(app, it.path, "Delete finding");
}

// ─── keys ───────────────────────────────────────────────────────────────

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.findings;
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
                'd' => runToast(app, resolveCmd(app)),
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
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("findings: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.findings;
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
    const st = &app.findings;
    const total = st.filtered.items.len;
    st.list.cursor = if (down) @min(st.list.cursor + rows, total -| 1) else st.list.cursor -| rows;
    app.needs_render = true;
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.findings.filtered.items.len) return;
    focusPanel(app);
    app.findings.list.cursor = idx;
    app.findings.list.on_new = false;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .findings, m.x, m.y) else runToast(app, refresh(app)),
        .new => runToast(app, newCmd(app)),
        .view, .history => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.findings.list.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.findings;
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
    app.focus = .{ .panel = .findings };
    app.needs_render = true;
}

fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Open", .action = .{ .command = .@"findings.open" } },
        .{ .label = "Copy path", .action = .{ .command = .@"findings.copy_path" } },
        .{ .label = "Mark resolved", .action = .{ .command = .@"findings.resolve" }, .separator_before = true },
        .{ .label = "Delete…", .action = .{ .command = .@"findings.delete" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Finding", items, x, y);
}

fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.alloc(command.MenuItem, ListSort.all.len);
    errdefer app.gpa.free(items);
    for (ListSort.all, 0..) |s, i| items[i] = .{
        .label = s.label(),
        .action = .{ .set_panel_sort = .{ .panel = .findings, .sort = s } },
        .checked = s == app.findings.sort,
    };
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.findings;
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    const rows = try ui.arena.alloc(Item, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = st.items[idx];
    var open_n: usize = 0;
    for (st.items) |it| if (it.status != .resolved and it.status != .dismissed) {
        open_n += 1;
    };
    const subtitle = if (st.list.filterText().len == 0)
        ui.fmt(" ({d} open of {d})", .{ open_n, st.items.len })
    else
        ui.fmt(" ({d} of {d})", .{ rows.len, st.items.len });
    const empty: list_panel.EmptyState = if (st.scanning and st.items.len == 0)
        .{ .message = "Reading findings…" }
    else if (st.items.len == 0)
        .{ .message = "No findings yet.", .hint = "Stored under " ++ dir_rel ++ "/*.md" }
    else
        .{ .message = ui.fmt("No findings match /{s} — {d} in workspace", .{ st.list.filterText(), st.items.len }), .hint = "Stored under " ++ dir_rel ++ "/*.md" };
    now_s = Io.Timestamp.now(app.io, .real).toSeconds();
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .findings,
        .label = "FINDINGS",
        .subtitle = subtitle,
        .sort_chip = st.sort.label(),
        .sort_widest = ListSort.widest_label,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
        .new_label = "+ New finding",
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    if (st.scanning) list_panel.paintSpinner(ui, area, "FINDINGS", app.now_ms);
}

/// Set by `draw` (the paint callback has no `*App`).
var now_s: i64 = 0;

pub fn severityStyle(t: *const Theme, s: Severity, base: vaxis.Style) vaxis.Style {
    var st = Theme.withFg(base, switch (s) {
        .critical, .high => t.error_fg.fg,
        .medium => t.warn_fg.fg,
        .low, .info => t.info_fg.fg,
        .unknown => t.muted.fg,
    });
    st.bold = s == .critical or s == .high;
    return st;
}

/// `SEV name  title  age`: the severity tag coloured by level, the name
/// in the accent, the title in the text colour, the age dim on the
/// right. A resolved or dismissed finding paints entirely muted so the
/// open ones stand out.
fn paintRow(ui: Ui, r: Rect, row: Item, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    const closed = row.status == .resolved or row.status == .dismissed;
    var x = r.x;
    const end = r.right();
    const age = list_panel.ageText(ui, now_s, row.mtime);
    const age_w = ui.width(age);
    var body_end = end;
    if (age_w + 2 < end -| x) {
        _ = ui.putStr(end - age_w, r.y, age_w, age, Theme.onBg(t.muted, base.bg));
        body_end = end - age_w - 1;
    }
    const tag_style = if (closed) Theme.onBg(t.muted, base.bg) else severityStyle(t, row.severity, base);
    x += ui.putStr(x, r.y, body_end -| x, row.severity.tag(), tag_style);
    x += ui.putStr(x, r.y, body_end -| x, " ", base);
    const name_style = if (closed) Theme.onBg(t.muted, base.bg) else Theme.withFg(base, t.accent.fg);
    x += ui.putStr(x, r.y, body_end -| x, ui.clipStr(row.name, body_end -| x), name_style);
    if (row.title.len > 0 and body_end -| x > 3) {
        x += ui.putStr(x, r.y, body_end -| x, "  ", base);
        const title_style = if (closed) Theme.onBg(t.muted, base.bg) else Theme.onBg(t.fg, base.bg);
        _ = ui.putStr(x, r.y, body_end -| x, ui.clipStr(row.title, body_end -| x), title_style);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "parseHead: frontmatter severity + status + title, aliases, a bare Severity: line, and no metadata at all" {
    const a = parseHead("---\nseverity: SEV-2\nstatus: Fixed\n---\n# Picker panics\n\nbody\n");
    try testing.expectEqual(Severity.high, a.severity);
    try testing.expectEqual(Status.resolved, a.status);
    try testing.expectEqualStrings("Picker panics", a.title);
    const b = parseHead("---\ntitle: \"From the block\"\nseverity: blocker\n---\n\nno heading here\n");
    try testing.expectEqual(Severity.critical, b.severity);
    try testing.expectEqual(Status.unknown, b.status);
    try testing.expectEqualStrings("no heading here", b.title);
    const c = parseHead("# Report\n\n**Severity:** low\n- Status: open\n");
    try testing.expectEqual(Severity.low, c.severity);
    try testing.expectEqual(Status.open, c.status);
    try testing.expectEqualStrings("Report", c.title);
    const d = parseHead("just a line\n");
    try testing.expectEqual(Severity.unknown, d.severity);
    try testing.expectEqual(Status.unknown, d.status);
    try testing.expectEqualStrings("just a line", d.title);
    // An unterminated block is body text: the bare `severity:` line
    // still counts, and the heading after it is the title.
    const e = parseHead("---\nseverity: high\n# never closed\n");
    try testing.expectEqual(Severity.high, e.severity);
    try testing.expectEqualStrings("never closed", e.title);
    // A title in the block is used only when the body has none.
    const f = parseHead("---\ntitle: block\n---\n# body wins\n");
    try testing.expectEqualStrings("body wins", f.title);
}

test "setStatusInText rewrites the status line, adds one to a block without it, and prepends a block when there is none" {
    const a = testing.allocator;
    const one = try setStatusInText(a, "---\nseverity: high\nstatus: open\n---\n# T\n", "resolved");
    defer a.free(one);
    try testing.expectEqualStrings("---\nseverity: high\nstatus: resolved\n---\n# T\n", one);
    const two = try setStatusInText(a, "---\nseverity: high\n---\n# T\n", "resolved");
    defer a.free(two);
    try testing.expectEqualStrings("---\nseverity: high\nstatus: resolved\n---\n# T\n", two);
    const three = try setStatusInText(a, "# T\nbody\n", "resolved");
    defer a.free(three);
    try testing.expectEqualStrings("---\nstatus: resolved\n---\n# T\nbody\n", three);
    try testing.expectEqual(Status.resolved, parseHead(three).status);
    try testing.expectEqualStrings("T", parseHead(three).title);
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
        while (f.app.findings.scanning and i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (f.app.findings.scanning) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }
};

test "scanInto lists .mnml/findings/*.md with severity + status; a missing directory is empty" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const empty = try ScanResult.create(testing.allocator, 1);
    defer empty.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.root, empty);
    try testing.expectEqual(@as(usize, 0), empty.items.len);
    try f.write(".mnml/findings/finding-1.md", "---\nseverity: high\nstatus: open\n---\n# Crash below 30 cols\n");
    try f.write(".mnml/findings/r2.md", "# Plain report\n");
    try f.write(".mnml/findings/notes.txt", "not markdown\n");
    const r = try ScanResult.create(testing.allocator, 1);
    defer r.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.root, r);
    try testing.expectEqual(@as(usize, 2), r.items.len);
    for (r.items) |it| {
        if (std.mem.eql(u8, it.name, "finding-1")) {
            try testing.expectEqual(Severity.high, it.severity);
            try testing.expectEqual(Status.open, it.status);
            try testing.expectEqualStrings("Crash below 30 cols", it.title);
            try sdk_testing.expectPath(".mnml/findings/finding-1.md", it.path);
        } else {
            try testing.expectEqualStrings("r2", it.name);
            try testing.expectEqual(Severity.unknown, it.severity);
            try testing.expectEqualStrings("Plain report", it.title);
        }
    }
}

test "sort modes break ties by severity; the filter matches severity and status words; a stale generation is dropped" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    const st = &f.app.findings;
    const r = try ScanResult.create(testing.allocator, 1);
    const items = try r.arena.allocator().alloc(Item, 3);
    items[0] = .{ .name = "b", .path = ".mnml/findings/b.md", .title = "Beta", .severity = .low, .status = .open, .mtime = 5, .bytes = 1 };
    items[1] = .{ .name = "a", .path = ".mnml/findings/a.md", .title = "Alpha", .severity = .critical, .status = .resolved, .mtime = 5, .bytes = 1 };
    items[2] = .{ .name = "c", .path = ".mnml/findings/c.md", .title = "Gamma", .severity = .medium, .status = .open, .mtime = 9, .bytes = 1 };
    r.items = items;
    st.generation = 1;
    try handle(&f.app, r);
    // newest: c (9), then a + b tie on mtime → critical before low
    try testing.expectEqualStrings("c", st.items[0].name);
    try testing.expectEqualStrings("a", st.items[1].name);
    try testing.expectEqualStrings("b", st.items[2].name);
    try setSort(&f.app, .oldest);
    try testing.expectEqualStrings("a", st.items[0].name);
    try testing.expectEqualStrings("c", st.items[2].name);
    try setSort(&f.app, .name_desc);
    try testing.expectEqualStrings("c", st.items[0].name);
    try setSort(&f.app, .name);
    try testing.expectEqualStrings("a", st.items[0].name);
    try st.list.filter.appendSlice(testing.allocator, "resolved");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqualStrings("a", st.selected().?.name);
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "MED");
    try refilter(&f.app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqualStrings("c", st.selected().?.name);
    st.list.filter.clearRetainingCapacity();
    const stale = try ScanResult.create(testing.allocator, 0);
    try handle(&f.app, stale);
    try testing.expectEqual(@as(usize, 3), st.items.len);
}

test "headless: the panel lists findings with severity tags; d resolves the selected one in place; n seeds finding-N.md with the template" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write(".mnml/findings/finding-1.md", "---\nseverity: high\nstatus: open\n---\n# Picker panics\n");
    f.app.tree.visible = false;
    // Room for the count and the full chip side by side: on the right,
    // 56 wide.
    f.app.side.of.set(.findings, .right);
    f.app.side.right_width = 56;
    try command.run(&f.app, .{ .static = .@"view.activity_findings" });
    // Through the registry, not the first draw: a table left out of
    // `command.runner_tables` fails here instead of passing silently.
    try command.run(&f.app, .{ .static = .@"findings.refresh" });
    try f.settle(2000);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "FINDINGS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(1 open of 1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "HIGH finding-1  Picker panics") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "sort: Newest first") != null);
    try f.app.handle(.{ .key = Key.char('d') });
    const back = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/findings/finding-1.md", testing.allocator, .limited(4096));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("---\nseverity: high\nstatus: resolved\n---\n# Picker panics\n", back);
    try f.settle(2000);
    try testing.expectEqual(Status.resolved, f.app.findings.items[0].status);
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "(0 open of 1)") != null);
    // A second d is a no-op with a toast, not a rewrite.
    try command.run(&f.app, .{ .static = .@"findings.resolve" });
    try testing.expectEqualStrings("finding-1 is already resolved", f.app.lastToast().?);
    // n seeds the next name; enter creates the file with the template and opens it.
    try f.app.handle(.{ .key = Key.char('n') });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expectEqualStrings("finding-2.md", f.app.overlay.prompt.state.text());
    try f.app.handle(.{ .key = Key.named(.enter) });
    const fresh = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/findings/finding-2.md", testing.allocator, .limited(4096));
    defer testing.allocator.free(fresh);
    try testing.expectEqualStrings("---\nseverity: medium\nstatus: open\n---\n# finding-2\n\n", fresh);
    try testing.expectEqualStrings("finding-2.md", f.app.panes.get(f.app.active.?).?.title());
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 2), f.app.findings.items.len);
}

test "mouse: the row menu names real ids; the sort chip cycles and persists ui.findings_sort; right-click lists the modes with a tick" {
    var f = try Fixture.init(100, 20);
    defer f.deinit();
    try f.write(".mnml/findings/a.md", "# A\n");
    try f.write(".mnml/findings/b.md", "# B\n");
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_findings" });
    try f.app.render();
    try f.settle(2000);
    try f.app.render();
    var row1: ?Rect = null;
    var sort_chip: ?Rect = null;
    for (f.app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.panel == .findings and r.idx == 1) {
            row1 = h.rect;
        },
        .chip => |c| if (c.panel == .findings and c.kind == .sort) {
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
    try testing.expectEqual(@as(usize, 4), f.app.overlay.menu.items.len);
    for (f.app.overlay.menu.items) |it| try testing.expect(it.action == .command);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try click.at(&f.app, sort_chip.?, .left);
    try testing.expectEqual(ListSort.oldest, f.app.findings.sort);
    try testing.expectEqual(ListSort.oldest, ListSort.fromConfig(f.app.cfg.ui.findings_sort));
    const cfg = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/config.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "findings_sort") != null);
    try click.at(&f.app, sort_chip.?, .right);
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqual(ListSort.all.len, f.app.overlay.menu.items.len);
    try testing.expect(f.app.overlay.menu.items[1].checked);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // Delete the selected finding through the confirm; the panel rescans.
    try f.app.handle(.{ .key = Key.char('x') });
    try testing.expect(f.app.overlay == .confirm);
    try f.app.handle(.{ .key = Key.char('d') });
    try f.settle(2000);
    try testing.expectEqual(@as(usize, 1), f.app.findings.items.len);
}

test "the sort chip at 26 / 30 / 34 cells and the shipped 40 is icon-only and live; the full label needs 50" {
    inline for (.{ 26, 30, 34, 40, 50 }) |panel_w| {
        // The right panel takes `panel_w` plus a divider off the screen
        // (and is clamped to the screen less 21, so the screen is wide).
        var f = try Fixture.init(100, 12);
        defer f.deinit();
        try f.write(".mnml/findings/a.md", "# A\n");
        f.app.tree.visible = false;
        f.app.side.of.set(.findings, .right);
        f.app.side.right_width = panel_w;
        try command.run(&f.app, .{ .static = .@"view.activity_findings" });
        try f.app.render();
        try f.settle(2000);
        const txt = try f.screen();
        defer testing.allocator.free(txt);
        var chip_rect: ?Rect = null;
        for (f.app.hits.items.items) |h| if (h.target == .chip and h.target.chip.panel == .findings and h.target.chip.kind == .sort) {
            chip_rect = h.rect;
        };
        try testing.expect(chip_rect != null);
        // FINDINGS is the widest label: with its count the full chip
        // needs 49 cells; the count stays beside the icon down to 32.
        if (panel_w < 50) {
            try testing.expectEqual(@as(u16, 3), chip_rect.?.w);
            try testing.expect(std.mem.indexOf(u8, txt, "sort:") == null);
            if (panel_w >= 32) try testing.expect(std.mem.indexOf(u8, txt, "(1 open of 1)") != null);
        } else {
            try testing.expect(std.mem.indexOf(u8, txt, "sort: Newest first") != null);
            try testing.expect(std.mem.indexOf(u8, txt, "(1 open of 1)") != null);
        }
        // The chip is live at every rung: a right-click lists the modes.
        try f.app.handle(.{ .mouse = .{ .x = chip_rect.?.x + 1, .y = chip_rect.?.y, .kind = .press, .button = .right } });
        try testing.expect(f.app.overlay == .menu);
        try testing.expectEqual(ListSort.all.len, f.app.overlay.menu.items.len);
    }
}
