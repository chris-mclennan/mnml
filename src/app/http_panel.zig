//! The HTTP activity panel (`view.activity_http`): the seven sections of
//! the Rust sidebar — COLLECTIONS / ENVS / CHAINS / MOCKS / COOKIES /
//! RECENT / CAPTURED — as collapsible groups of one `ListPanel`, the way
//! the GIT rail groups its status rows. The `/` filter narrows across
//! every section at once and the header counts say what survived it;
//! Enter opens a file, applies an env, runs a chain, copies a cookie or
//! re-opens a recent / captured request as a scratch pane.
//!
//! This file is the state and the actions; the painter is
//! `ui/http_panel.zig` (the rows, the header chip ladders, the folder
//! tree, the empty words, the links). COLLECTIONS is a tree: every
//! folder holding request files is a collection row (`▾ 󰉋 requests
//! (3)`, a ` + ` at its edge for a new request inside it), the files
//! under it; `.mnml/collections/<name>/` folders are the hidden kind;
//! files at the workspace root stand alone. Under an empty section its
//! words and, where a thing can be made, the green `+ New …` link;
//! after the last section `+ New request` / `↓ Paste curl…` /
//! `↓ Import…`. Entering the section opens a blank request pane in the
//! centre when no request pane is active (Rust's `entering_http`);
//! leaving does not close it.
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
const hit = @import("../ui/hit.zig");
const list_panel = @import("../ui/list_panel.zig");
const view = @import("../ui/http_panel.zig");
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

pub const Section = view.Section;
pub const Row = view.Row;
pub const Kind = view.Kind;
pub const Link = view.Link;
pub const ChipKind = view.ChipKind;
pub const Part = view.Part;
pub const Panel = view.Panel;

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
/// Where `http.new_collection` puts a collection.
pub const hidden_root = ".mnml/collections";

/// A collection: a folder with request files in it.
pub const Folder = struct {
    /// Workspace-relative directory.
    rel: []const u8,
    /// What the row says: the relative directory, or the collection's
    /// name for a hidden one.
    name: []const u8,
    hidden: bool,
    /// Indices into `State.files`.
    members: []const u32,
};

pub const State = struct {
    /// D1: the snapshot tier — every list below lives here until the
    /// next `refresh` drops them all at once.
    snapshot: alloc.SnapshotArena,
    /// Request files, workspace-relative, sorted; the hidden
    /// collections' files among them.
    files: []const []const u8 = &.{},
    folders: []const Folder = &.{},
    /// Indices into `files` of the files at the workspace root.
    loose: []const u32 = &.{},
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
    /// Every block of every file, in file order.
    blocks: []const BlockInfo = &.{},
    truncated: bool = false,
    /// Rows as displayed: the filter and the collapse state applied.
    rows: std.ArrayListUnmanaged(Row) = .empty,
    list: Panel.State = .{},
    collapsed: std.enums.EnumSet(Section) = .initEmpty(),
    /// Folded collection folders, by relative directory (keys on the gpa).
    collapsed_dirs: std.StringArrayHashMapUnmanaged(void) = .empty,
    scanned_once: bool = false,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.rows.deinit(gpa);
        self.list.deinit(gpa);
        for (self.collapsed_dirs.keys()) |k| gpa.free(k);
        self.collapsed_dirs.deinit(gpa);
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

    /// The count a section's header shows this frame.
    pub fn shown(self: *const State, s: Section) ?u32 {
        for (self.rows.items) |r| if (r.kind == .header and r.section == s) return r.count;
        return null;
    }
};

pub const CookieRow = struct { host: []const u8, name: []const u8, value: []const u8 };

/// One request block of a listed file (items 8 / 9 / 15): the tree's
/// block rows under a multi-block file, the picker's rows, the tag
/// filter's facts. Strings on the snapshot arena.
pub const BlockInfo = struct {
    /// Index into `State.files`.
    file: u32,
    /// Index into `parse.blocks` of that file's text.
    idx: u32,
    /// The `### name`; null for a leading nameless block.
    name: ?[]const u8,
    method: []const u8,
    url: []const u8,
    /// The name, else the first comment, else the URL's short form.
    label: []const u8,
    tags: []const []const u8,
    description: ?[]const u8,
    /// The file holds more than one block.
    multi: bool,
};

/// The filter, read: `tag:x` narrows to the blocks (and their files)
/// tagged `x`; anything else is the substring the rows match.
pub const Query = struct {
    text: []const u8 = "",
    tag: ?[]const u8 = null,

    pub fn parse(q: []const u8) Query {
        if (std.ascii.startsWithIgnoreCase(q, "tag:")) return .{ .tag = std.mem.trim(u8, q["tag:".len..], " \t") };
        return .{ .text = q };
    }

    pub fn isEmpty(self: Query) bool {
        return self.text.len == 0 and self.tag == null;
    }
};

/// A screen position a menu drops at.
pub const Pos = struct { x: u16, y: u16 };

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
    try walkHidden(app.io, app.gpa, a, app.workspace, &files);
    sortStrings(files.items);
    sortStrings(mocks.items);
    const grouped = try groupFolders(a, files.items);
    const blocks = try scanBlocks(app.io, a, app.workspace, files.items);
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
    st.folders = grouped.folders;
    st.loose = grouped.loose;
    st.mocks = mocks.items;
    st.envs = envs;
    st.active_env = active_env;
    st.chains = chains;
    st.cookies = cookie_rows.items;
    st.recent = recent;
    st.captured = cap_rows;
    st.blocks = blocks;
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
                    try mocks.append(arena, try slashRel(arena, entry.path));
                } else if (parse.isRequestPath(entry.basename)) {
                    try files.append(arena, try slashRel(arena, entry.path));
                }
            },
            else => {},
        }
    }
}

/// A walked path with `/` between its parts on every platform: the
/// folder grouping and the rows read a collection's path that way, and
/// Windows' walker writes `\`.
fn slashRel(arena: Allocator, path: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// `.mnml/collections/<name>/**`: the hidden collections, which the
/// workspace walk skips with every dot-directory.
fn walkHidden(io: Io, gpa: Allocator, arena: Allocator, workspace: []const u8, files: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const path = try std.fs.path.join(arena, &.{ workspace, hidden_root });
    var root = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = root.walkSelectively(gpa) catch return;
    defer walker.deinit();
    while (true) {
        const entry = walker.next(io) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        } orelse break;
        if (files.items.len >= scan_cap) break;
        switch (entry.kind) {
            .directory => walker.enter(io, entry) catch {},
            .file => if (parse.isRequestPath(entry.basename)) {
                try files.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ hidden_root, try slashRel(arena, entry.path) }));
            },
            else => {},
        }
    }
}

/// Every block of every listed file: read (up to 1 MB each), split on
/// `###`, each block parsed for its method, URL, tags and description.
/// A file that will not read or parse contributes nothing.
fn scanBlocks(io: Io, arena: Allocator, workspace: []const u8, files: []const []const u8) Allocator.Error![]const BlockInfo {
    var out: std.ArrayListUnmanaged(BlockInfo) = .empty;
    for (files, 0..) |rel, fi| {
        const path = try std.fs.path.join(arena, &.{ workspace, rel });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
        const list = try parse.blocks(arena, text);
        for (list, 0..) |b, bi| {
            var method: []const u8 = "?";
            var url: []const u8 = "";
            var tags: []const []const u8 = &.{};
            var desc: ?[]const u8 = null;
            if (parse.parse(arena, b.text)) |req| {
                method = req.method;
                url = req.url;
                tags = try parse.tags(arena, &req);
                desc = parse.description(&req);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
            const label: []const u8 = if (b.name != null and b.name.?.len > 0) b.name.? else if (b.summary) |s| s else if (url.len > 0) history.shortUrl(url) else std.fs.path.basename(rel);
            try out.append(arena, .{ .file = @intCast(fi), .idx = @intCast(bi), .name = b.name, .method = method, .url = url, .label = label, .tags = tags, .description = desc, .multi = list.len > 1 });
        }
    }
    return out.items;
}

fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

const Grouped = struct { folders: []const Folder, loose: []const u32 };

/// Every distinct directory among `files` (sorted) is a folder with
/// the files directly in it; `.mnml/collections/<name>` is hidden and
/// named by `<name>`; root files are loose.
fn groupFolders(a: Allocator, files: []const []const u8) Allocator.Error!Grouped {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var loose: std.ArrayListUnmanaged(u32) = .empty;
    for (files, 0..) |f, i| {
        const d = std.fs.path.dirname(f) orelse "";
        if (d.len == 0) {
            try loose.append(a, @intCast(i));
            continue;
        }
        var seen = false;
        for (dirs.items) |x| if (std.mem.eql(u8, x, d)) {
            seen = true;
            break;
        };
        if (!seen) try dirs.append(a, d);
    }
    sortStrings(dirs.items);
    var out: std.ArrayListUnmanaged(Folder) = .empty;
    for (dirs.items) |d| {
        var members: std.ArrayListUnmanaged(u32) = .empty;
        for (files, 0..) |f, i| {
            const fd = std.fs.path.dirname(f) orelse "";
            if (std.mem.eql(u8, fd, d)) try members.append(a, @intCast(i));
        }
        const hidden = std.mem.startsWith(u8, d, hidden_root ++ "/");
        const name = if (hidden) d[hidden_root.len + 1 ..] else d;
        try out.append(a, .{ .rel = d, .name = name, .hidden = hidden, .members = members.items });
    }
    return .{ .folders = out.items, .loose = loose.items };
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
/// filter left) and, unless collapsed, its rows — the collection tree,
/// the items, an empty section's words and its `+ New …` link — a gap
/// after each, and the three action links last. Under a filter a
/// section with no match is dropped, and so are the words and links.
pub fn rebuild(app: *App) Allocator.Error!void {
    const st = &app.http_panel;
    const gpa = app.gpa;
    st.rows.clearRetainingCapacity();
    const q = st.list.filterText();
    const query = Query.parse(q);
    const a = st.snapshot.allocator();
    var any = false;
    for (Section.all) |s| {
        var items: std.ArrayListUnmanaged(Row) = .empty;
        defer items.deinit(gpa);
        var count: u32 = 0;
        if (s == .collections) {
            count = try collectionRows(st, gpa, &items, query);
        } else {
            const n = st.total(s);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const row = try itemRow(st, a, s, i);
                if (matches(row, q)) try items.append(gpa, row);
            }
            count = @intCast(items.items.len);
        }
        if (q.len > 0 and count == 0) continue;
        any = true;
        const folded = st.collapsed.contains(s);
        try st.rows.append(gpa, .{ .section = s, .kind = .header, .count = count, .collapsed = folded });
        if (!folded) {
            try st.rows.appendSlice(gpa, items.items);
            if (q.len == 0) {
                if (count == 0) try st.rows.append(gpa, .{ .section = s, .kind = .empty, .label = s.emptyText(app.cfg.ui.ascii_icons) });
                const link: ?Link = switch (s) {
                    .collections => if (count == 0) .new_collection else null,
                    .envs => .new_env,
                    .chains => .new_chain,
                    else => null,
                };
                if (link) |l| try st.rows.append(gpa, .{ .section = s, .kind = .link, .link = l });
            }
        }
        try st.rows.append(gpa, .{ .section = s, .kind = .gap });
    }
    if (q.len == 0 or any) {
        for ([_]Link{ .new_request, .paste_curl, .import }) |l| try st.rows.append(gpa, .{ .section = .captured, .kind = .link, .link = l });
    }
    if (st.list.cursor >= st.rows.items.len) st.list.cursor = st.rows.items.len -| 1;
    settle(st, true);
}

/// The COLLECTIONS tree under `q`: a folder whose name matches shows
/// every member, otherwise the members that match; a folder with
/// nothing to show goes; the filter unfolds every folder (Rust). A
/// multi-block file lists its blocks under it (`GET  name`), the ones
/// that match under a filter; a file matches by its name or by any
/// block's name / method / URL / tags / description; `tag:x` keeps
/// only the blocks tagged `x` and their files. Returns the files shown.
fn collectionRows(st: *State, gpa: Allocator, items: *std.ArrayListUnmanaged(Row), q: Query) Allocator.Error!u32 {
    var count: u32 = 0;
    const filtering = !q.isEmpty();
    for (st.folders, 0..) |f, fi| {
        const name_hits = q.tag == null and (q.text.len == 0 or containsIgnoreCase(f.name, q.text));
        var shown: std.ArrayListUnmanaged(Row) = .empty;
        defer shown.deinit(gpa);
        var files_shown: u32 = 0;
        for (f.members) |mi| {
            if (try appendFileRows(st, gpa, &shown, mi, std.fs.path.basename(st.files[mi]), true, q, name_hits)) files_shown += 1;
        }
        if (filtering and !name_hits and files_shown == 0) continue;
        const folded = !filtering and st.collapsed_dirs.contains(f.rel);
        try items.append(gpa, .{ .section = .collections, .kind = .folder, .idx = @intCast(fi), .label = f.name, .count = files_shown, .collapsed = folded, .hidden = f.hidden });
        count += files_shown;
        if (!folded) try items.appendSlice(gpa, shown.items);
    }
    for (st.loose) |i| {
        if (try appendFileRows(st, gpa, items, i, st.files[i], false, q, false)) count += 1;
    }
    return count;
}

/// The file's row and, for a multi-block file, its block rows — under
/// `q` the ones that match (all of them when the file's own name did,
/// or the folder's). True when the file was shown.
fn appendFileRows(st: *State, gpa: Allocator, items: *std.ArrayListUnmanaged(Row), fi: u32, label: []const u8, in_folder: bool, q: Query, folder_hit: bool) Allocator.Error!bool {
    const filtering = !q.isEmpty();
    const file_hit = folder_hit or (q.tag == null and (q.text.len == 0 or containsIgnoreCase(label, q.text)));
    var multi = false;
    var any_block_hit = false;
    var block_rows: std.ArrayListUnmanaged(Row) = .empty;
    defer block_rows.deinit(gpa);
    for (st.blocks, 0..) |b, bi| {
        if (b.file != fi) continue;
        const matched = blockMatches(b, q);
        any_block_hit = any_block_hit or matched;
        if (!b.multi) continue;
        multi = true;
        if (filtering and !file_hit and !matched) continue;
        try block_rows.append(gpa, .{ .section = .collections, .kind = .block, .idx = @intCast(bi), .label = b.label, .method = b.method, .detail = try tagsDetail(st.snapshot.allocator(), b.tags), .in_folder = in_folder });
    }
    if (filtering and !file_hit and !any_block_hit) return false;
    try items.append(gpa, .{ .section = .collections, .idx = fi, .label = label, .in_folder = in_folder });
    if (multi) try items.appendSlice(gpa, block_rows.items);
    return true;
}

/// A block against the query: the tag (a prefix, case-insensitive)
/// when one is asked for, else the substring over its name, method,
/// URL, description and tags.
fn blockMatches(b: BlockInfo, q: Query) bool {
    if (q.tag) |want| {
        for (b.tags) |t| if (std.ascii.startsWithIgnoreCase(t, want)) return true;
        return false;
    }
    if (q.text.len == 0) return true;
    if (containsIgnoreCase(b.label, q.text) or containsIgnoreCase(b.method, q.text) or containsIgnoreCase(b.url, q.text)) return true;
    if (b.description) |d| if (containsIgnoreCase(d, q.text)) return true;
    for (b.tags) |t| if (containsIgnoreCase(t, q.text)) return true;
    return false;
}

/// `#a #b` for a row's detail; empty for none.
fn tagsDetail(a: Allocator, tags: []const []const u8) Allocator.Error![]const u8 {
    if (tags.len == 0) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (tags, 0..) |t, i| {
        if (i > 0) try out.append(a, ' ');
        try out.append(a, '#');
        try out.appendSlice(a, t);
    }
    return out.items;
}

/// Item `i` of section `s` as a row. The formatted texts land on the
/// snapshot arena so the row can be kept until the next refresh.
fn itemRow(st: *const State, a: Allocator, s: Section, i: usize) Allocator.Error!Row {
    const idx: u32 = @intCast(i);
    return switch (s) {
        .collections => .{ .section = s, .idx = idx, .label = st.files[i] },
        .envs => .{ .section = s, .idx = idx, .label = st.envs[i], .active = if (st.active_env) |ae| std.mem.eql(u8, ae, st.envs[i]) else false },
        .chains => .{ .section = s, .idx = idx, .label = st.chains[i] },
        .mocks => .{ .section = s, .idx = idx, .label = mockLabel(st.mocks[i]) },
        .cookies => .{ .section = s, .idx = idx, .label = st.cookies[i].name, .detail = st.cookies[i].host },
        .recent => blk: {
            const r = st.recent[i];
            const status: u16 = r.status orelse 0;
            break :blk .{ .section = s, .idx = idx, .label = history.shortUrl(r.url), .method = r.method, .status = status, .detail = try std.fmt.allocPrint(a, "{s} {d}", .{ r.url, status }) };
        },
        .captured => blk: {
            const r = st.captured[i];
            break :blk .{ .section = s, .idx = idx, .label = history.shortUrl(r.url), .method = r.method, .detail = r.url };
        },
    };
}

/// `api/orders.curl.mock.json` → `api/orders.curl` (Rust).
fn mockLabel(rel: []const u8) []const u8 {
    const suffix = ".mock.json";
    if (std.mem.endsWith(u8, rel, suffix)) return rel[0 .. rel.len - suffix.len];
    return rel;
}

/// The filter is a case-insensitive substring over the label, the
/// method and the detail (a recent row's full URL, a cookie's host…).
fn matches(row: Row, q: []const u8) bool {
    if (q.len == 0) return true;
    return containsIgnoreCase(row.label, q) or containsIgnoreCase(row.detail, q) or containsIgnoreCase(row.method, q);
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

/// The cursor never rests on a gap or an empty section's words: from
/// wherever it landed it walks on in `down`'s direction to the next
/// stop, or back when there is none.
fn settle(st: *State, down: bool) void {
    const rows = st.rows.items;
    if (rows.len == 0) return;
    var i = st.list.cursor;
    if (i >= rows.len) i = rows.len - 1;
    if (rows[i].isStop()) {
        st.list.cursor = i;
        return;
    }
    var j = i;
    if (down) {
        while (j + 1 < rows.len) : (j += 1) if (rows[j + 1].isStop()) {
            st.list.cursor = j + 1;
            return;
        };
        j = i;
        while (j > 0) : (j -= 1) if (rows[j - 1].isStop()) {
            st.list.cursor = j - 1;
            return;
        };
    } else {
        while (j > 0) : (j -= 1) if (rows[j - 1].isStop()) {
            st.list.cursor = j - 1;
            return;
        };
        j = i;
        while (j + 1 < rows.len) : (j += 1) if (rows[j + 1].isStop()) {
            st.list.cursor = j + 1;
            return;
        };
    }
    st.list.cursor = i;
}

// ─── actions ────────────────────────────────────────────────────────────

fn requireRow(app: *App) CommandError!Row {
    return app.http_panel.selected() orelse app.diag.fail(app.frame.allocator(), "http panel: nothing selected", .{});
}

/// Enter on a row: a header or a folder toggles, a link acts, an item
/// opens, applies or runs what it names.
pub fn activate(app: *App, row: Row) CommandError!void {
    const st = &app.http_panel;
    const arena = app.frame.allocator();
    switch (row.kind) {
        .header => {
            st.collapsed.toggle(row.section);
            try rebuild(app);
            return;
        },
        .folder => return toggleFolder(app, row.idx),
        .link => return linkAction(app, row.link, null),
        .empty, .gap => return,
        .block => {
            const b = st.blocks[row.idx];
            const abs = try std.fs.path.join(arena, &.{ app.workspace, st.files[b.file] });
            _ = http.openFileBlock(app, abs, b.idx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(arena, "open {s}: {s}", .{ st.files[b.file], @errorName(err) }),
            };
            return;
        },
        .item => {},
    }
    switch (row.section) {
        .collections => try openRel(app, st.files[row.idx]),
        .mocks => try openRel(app, st.mocks[row.idx]),
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

fn openRel(app: *App, rel: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const abs = try std.fs.path.join(arena, &.{ app.workspace, rel });
    _ = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
}

/// Fold or unfold the `idx`-th collection folder.
pub fn toggleFolder(app: *App, idx: u32) CommandError!void {
    const st = &app.http_panel;
    if (idx >= st.folders.len) return;
    const rel = st.folders[idx].rel;
    if (st.collapsed_dirs.fetchSwapRemove(rel)) |kv| {
        app.gpa.free(kv.key);
    } else {
        const key = try app.gpa.dupe(u8, rel);
        errdefer app.gpa.free(key);
        try st.collapsed_dirs.put(app.gpa, key, {});
    }
    try rebuild(app);
}

/// What a link opens — the same thing the palette command does.
/// `at` is where the Import menu drops; null puts it by the row.
pub fn linkAction(app: *App, link: Link, at: ?Pos) CommandError!void {
    switch (link) {
        .new_request => try command.run(app, .{ .static = .@"http.new" }),
        .paste_curl => try command.run(app, .{ .static = .@"http.paste_curl" }),
        .import => try openImportMenu(app, at),
        .new_env => try command.run(app, .{ .static = .@"http.new_env" }),
        .new_chain => try command.run(app, .{ .static = .@"http.new_chain" }),
        .new_collection => try command.run(app, .{ .static = .@"http.new_collection" }),
    }
}

/// Rust's `Import from:` picker as a menu: a Postman collection or a
/// HAR file, both read from the clipboard.
fn openImportMenu(app: *App, at: ?Pos) CommandError!void {
    const M = command.MenuItem;
    const items: []const M = &.{
        .{ .label = "Postman collection — from clipboard (JSON)", .action = .{ .command = .@"http.import_postman" } },
        .{ .label = "HAR file — from clipboard (Chrome / Firefox export)", .action = .{ .command = .@"http.import_har" } },
    };
    const owned = try app.gpa.dupe(M, items);
    errdefer app.gpa.free(owned);
    const pos = at orelse rowPos(app);
    try app.openMenu("Import from:", owned, pos.x, pos.y);
}

/// Where a keyboard-opened menu lands: the panel's column, the row.
fn rowPos(app: *App) Pos {
    _ = app;
    return .{ .x = 4, .y = 4 };
}

/// A blank request pane whose source is `req-N.http` inside the
/// `idx`-th collection folder — saved there on Ctrl+S (Rust's
/// `http_new_request_in_collection`).
pub fn newRequestInFolder(app: *App, idx: u32) CommandError!void {
    const st = &app.http_panel;
    const arena = app.frame.allocator();
    if (idx >= st.folders.len) return app.diag.fail(arena, "http panel: no such collection", .{});
    const f = st.folders[idx];
    const dir = try std.fs.path.join(arena, &.{ app.workspace, f.rel });
    var n: usize = 1;
    const path = while (n < 1000) : (n += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}/req-{d}.http", .{ dir, n });
        Io.Dir.cwd().access(app.io, candidate, .{}) catch break candidate;
    } else return app.diag.fail(arena, "collection: too many req-N.http files (999+)", .{});
    const id = try http.openBlank(app);
    const rp = app.panes.get(id).?.asRequest().?;
    rp.source_path = try app.gpa.dupe(u8, path);
    try rp.refreshTitle();
    app.toast("new request in {s}: {s} (Ctrl+S saves it)", .{ f.name, std.fs.path.basename(path) });
}

/// A section header's chip (Rust's `HttpChipKind` routing): the filter
/// takes the keys, refresh rescans, capture starts the browser capture,
/// clear truncates the log (RECENT / CAPTURED), empties the jar
/// (COOKIES) or just clears the filter, new makes an env or a collection.
pub fn chipAction(app: *App, section: Section, kind: ChipKind) CommandError!void {
    const st = &app.http_panel;
    switch (kind) {
        .filter => {
            focusPanel(app);
            st.list.filter_focused = true;
        },
        .refresh => try command.run(app, .{ .static = .@"http.refresh" }),
        .capture => try command.run(app, .{ .static = .@"http.capture_start" }),
        .clear => switch (section) {
            .recent => {
                try command.run(app, .{ .static = .@"http.clear_recent" });
                try refresh(app);
            },
            .captured => {
                try command.run(app, .{ .static = .@"http.clear_captured" });
                try refresh(app);
            },
            .cookies => {
                try command.run(app, .{ .static = .@"cookies.clear" });
                try refresh(app);
            },
            else => {
                st.list.filter.clearRetainingCapacity();
                st.list.filter_caret = 0;
                st.list.filter_focused = false;
                try rebuild(app);
            },
        },
        .new => switch (section) {
            .envs => try command.run(app, .{ .static = .@"http.new_env" }),
            .collections => try command.run(app, .{ .static = .@"http.new_collection" }),
            else => app.toast("no `new` action for this section", .{}),
        },
    }
}

/// Entering the section (Rust's `entering_http`): a blank request pane
/// in the centre when no request pane is active. Leaving does not
/// close it.
pub fn enter(app: *App) CommandError!void {
    if (http.activeRequest(app) != null) return;
    // The auto-opened pane is a preview: untouched, it goes on the way
    // out; the flag clears at the first edit (Rust's `is_preview`).
    const id = try http.openBlank(app);
    if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        rp.is_preview = true;
    };
}

/// Leaving the section (Rust's `leaving_http`, the user's 2026-08-24
/// ask): a request pane that is still the auto-opened preview, or
/// that reads blank (typed into and emptied — the preview flag does
/// not come back), closes on its own. Anything with content stays.
pub fn leave(app: *App) Allocator.Error!void {
    var i: usize = app.panes.slots.items.len;
    while (i > 0) {
        i -= 1;
        const slot = &app.panes.slots.items[i];
        const p = if (slot.*) |*p| p else continue;
        const rp = switch (p.*) {
            .request => |*rp| rp,
            else => continue,
        };
        if ((rp.is_preview and !rp.edited) or rp.isEffectivelyBlank())
            try app.forceClosePane(@intCast(i));
    }
}

fn openCmd(app: *App) CommandError!void {
    try activate(app, try requireRow(app));
}

fn toggleSectionCmd(app: *App) CommandError!void {
    const row = try requireRow(app);
    if (row.kind == .folder) return toggleFolder(app, row.idx);
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

/// Copy what identifies the row: a file's workspace path, a folder's,
/// an env / chain name, a cookie's `name=value`, a recent / captured
/// request's URL.
fn copyPathCmd(app: *App) CommandError!void {
    const st = &app.http_panel;
    const row = try requireRow(app);
    const arena = app.frame.allocator();
    const text: []const u8 = switch (row.kind) {
        .header => row.section.label(),
        .folder => st.folders[row.idx].rel,
        .link => row.link.text(app.cfg.ui.ascii_icons),
        .empty, .gap => return,
        .block => st.files[st.blocks[row.idx].file],
        .item => switch (row.section) {
            .collections => st.files[row.idx],
            .mocks => st.mocks[row.idx],
            .envs => st.envs[row.idx],
            .chains => st.chains[row.idx],
            .cookies => try std.fmt.allocPrint(arena, "{s}={s}", .{ st.cookies[row.idx].name, st.cookies[row.idx].value }),
            .recent => st.recent[row.idx].url,
            .captured => st.captured[row.idx].url,
        },
    };
    try app.clipboard.set(text, false);
    app.toast("copied {s}", .{text});
}

// ─── keys ───────────────────────────────────────────────────────────────

/// `r` rescans, `c` collapses / expands everything, `n` starts a new
/// request; left / right (h / l) close and open the selected section.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.http_panel;
    const before = st.list.cursor;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => {
            settle(st, st.list.cursor >= before);
            return true;
        },
        .filter_changed => {
            try rebuild(app);
            return true;
        },
        .activate => |i| {
            st.list.cursor = i;
            if (st.selected()) |row| runToast(app, activate(app, row));
            return true;
        },
        .new_activate => {},
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
                'n' => runToast(app, command.run(app, .{ .static = .@"http.new" })),
                'h' => return try foldSelected(app, true),
                'l' => return try foldSelected(app, false),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// Close (`fold`) or open the selected row's section — or its folder,
/// on a folder row; the cursor lands on the header when it closes.
fn foldSelected(app: *App, fold: bool) Allocator.Error!bool {
    const st = &app.http_panel;
    const row = st.selected() orelse return false;
    if (row.kind == .folder) {
        if (fold == row.collapsed) return true;
        runToast(app, toggleFolder(app, row.idx));
        return true;
    }
    if (fold == st.collapsed.contains(row.section)) return true;
    st.collapsed.toggle(row.section);
    try rebuild(app);
    if (fold) for (st.rows.items, 0..) |r, i| if (r.kind == .header and r.section == row.section) {
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

/// A row: a left press selects and acts — a header or a folder toggles,
/// a link acts, a request or a block opens (one press, as a file in the
/// tree does; Rust opens on the first click too — the second press this
/// once waited for left the two trees disagreeing); a right press
/// selects and opens the row menu; the wheel moves the cursor three rows.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.http_panel;
    switch (m.kind) {
        .press => {
            if (idx >= st.rows.items.len) return;
            focusPanel(app);
            const row = st.rows.items[idx];
            if (!row.isStop()) return;
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            switch (row.kind) {
                .link => runToast(app, linkAction(app, row.link, .{ .x = m.x, .y = m.y })),
                else => runToast(app, activate(app, row)),
            }
        },
        else => {},
    }
}

/// The wheel over the list moves the cursor `rows` rows and settles it
/// on a stop.
pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.http_panel;
    st.list.cursor = if (down) @min(st.list.cursor + rows, st.rows.items.len -| 1) else st.list.cursor -| rows;
    settle(st, down);
    app.needs_render = true;
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
        // right-click: the ⟳ menu every list panel has; the ` + `'s
        // ladder of everything the section can create.
        .refresh => if (m.button == .right) try @import("auto_refresh.zig").openRefreshMenu(app, .http, m.x, m.y) else runToast(app, refresh(app)),
        .new => if (m.button == .right) try openNewLadderMenu(app, m.x, m.y) else runToast(app, command.run(app, .{ .static = .@"http.new" })),
        .sort, .history => {},
    }
}

/// right-click: the header ` + `'s ladder (Zig-only) — one row per
/// thing the section creates, then the two imports.
fn openNewLadderMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "New request…", .action = .{ .command = .@"http.new_request" } },
        .{ .label = "New collection…", .action = .{ .command = .@"http.new_collection" } },
        .{ .label = "New env…", .action = .{ .command = .@"http.new_env" } },
        .{ .label = "New chain…", .action = .{ .command = .@"http.new_chain" } },
        .{ .label = "Paste curl from clipboard", .action = .{ .command = .@"http.paste_curl" }, .separator_before = true },
        .{ .label = "Import Postman collection…", .action = .{ .command = .@"http.import_postman" } },
        .{ .label = "Import HAR…", .action = .{ .command = .@"http.import_har" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("New", items, x, y);
}

/// The section's own targets: a header chip, a link, a folder's ` + `.
/// right-click: each opens the menu of the row it sits on — the
/// section header's, the link row's, the folder row's.
pub fn partMouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    if (m.button == .right) {
        const st = &app.http_panel;
        const idx: ?usize = switch (part) {
            .chip => |c| rowIndex(st, c.section, .header, null, null),
            .link => |l| rowIndex(st, null, .link, l, null),
            .folder_new => |i| rowIndex(st, .collections, .folder, null, i),
        };
        if (idx) |i| {
            focusPanel(app);
            st.list.cursor = i;
            try openRowMenu(app, m.x, m.y);
        }
        return;
    }
    if (m.button != .left) return;
    switch (part) {
        .chip => |c| runToast(app, chipAction(app, c.section, c.kind)),
        .link => |l| runToast(app, linkAction(app, l, .{ .x = m.x, .y = m.y })),
        .folder_new => |i| runToast(app, newRequestInFolder(app, i)),
    }
}

/// The first displayed row matching what is given of section / kind /
/// link / folder index.
fn rowIndex(st: *const State, section: ?Section, kind: Kind, link: ?Link, folder: ?u32) ?usize {
    for (st.rows.items, 0..) |row, i| {
        if (row.kind != kind) continue;
        if (section) |s| if (row.section != s) continue;
        if (link) |l| if (row.link != l) continue;
        if (folder) |f| if (row.idx != f) continue;
        return i;
    }
    return null;
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
            settle(st, true);
        },
        .scroll_up => {
            st.list.cursor -|= 3;
            settle(st, false);
        },
        .scroll_down => {
            st.list.cursor = @min(st.list.cursor + 3, total - 1);
            settle(st, true);
        },
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
    const items: []const M = switch (row.kind) {
        .header => switch (row.section) {
            .collections => &.{
                .{ .label = if (st.collapsed.contains(.collections)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "Find request…", .action = .{ .command = .@"http.find_request" }, .separator_before = true },
                .{ .label = "New collection…", .action = .{ .command = .@"http.new_collection" }, .separator_before = true },
                .{ .label = "New request…", .action = .{ .command = .@"http.new_request" } },
                .{ .label = "Sync sources", .action = .{ .command = .@"http.sync" } },
            },
            .envs => &.{
                .{ .label = if (st.collapsed.contains(.envs)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "New env…", .action = .{ .command = .@"http.new_env" }, .separator_before = true },
                .{ .label = "Pick env…", .action = .{ .command = .@"http.pick_env" } },
                .{ .label = "Clear override", .action = .{ .command = .@"http.reset_env" } },
            },
            .chains => &.{
                .{ .label = if (st.collapsed.contains(.chains)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "New chain…", .action = .{ .command = .@"http.new_chain" }, .separator_before = true },
                .{ .label = "Run chain…", .action = .{ .command = .@"http.run_chain" } },
            },
            .mocks => &.{
                .{ .label = if (st.collapsed.contains(.mocks)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "Save response as mock", .action = .{ .command = .@"http.save_mock" }, .separator_before = true },
            },
            .cookies => &.{
                .{ .label = if (st.collapsed.contains(.cookies)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "Show jar", .action = .{ .command = .@"cookies.show" }, .separator_before = true },
                .{ .label = "Clear jar", .action = .{ .command = .@"cookies.clear" } },
            },
            .recent => &.{
                .{ .label = if (st.collapsed.contains(.recent)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "History picker…", .action = .{ .command = .@"http.history" }, .separator_before = true },
                .{ .label = "Clear recent", .action = .{ .command = .@"http.clear_recent" } },
            },
            .captured => &.{
                .{ .label = if (st.collapsed.contains(.captured)) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
                .{ .label = "Collapse / expand all", .action = .{ .command = .@"http.toggle_collapse_all" } },
                .{ .label = "Refresh", .action = .{ .command = .@"http.refresh" }, .separator_before = true },
                .{ .label = "Start capture", .action = .{ .command = .@"http.capture_start" }, .separator_before = true },
                .{ .label = "Captured picker…", .action = .{ .command = .@"http.view_captured" } },
                .{ .label = "Clear captured", .action = .{ .command = .@"http.clear_captured" } },
            },
        },
        .folder => &.{
            .{ .label = if (row.collapsed) "Expand" else "Collapse", .action = .{ .command = .@"http.panel_toggle_section" } },
            .{ .label = "Copy path", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "New request…", .action = .{ .command = .@"http.new_request" }, .separator_before = true },
            .{ .label = "New collection…", .action = .{ .command = .@"http.new_collection" } },
        },
        .link => &.{
            .{ .label = row.link.text(app.cfg.ui.ascii_icons), .action = .{ .command = .@"http.panel_open" } },
        },
        .empty, .gap => return,
        .block => &.{
            .{ .label = "Open", .action = .{ .command = .@"http.panel_open" } },
            .{ .label = "Copy file path", .action = .{ .command = .@"http.panel_copy_path" } },
            .{ .label = "Rename block…", .action = .{ .command = .@"http.rename_request" }, .separator_before = true },
            .{ .label = "Duplicate block", .action = .{ .command = .@"http.duplicate_request" } },
            .{ .label = "Move block to…", .action = .{ .command = .@"http.move_request" } },
            .{ .label = "Delete block…", .action = .{ .command = .@"http.delete_request" } },
            .{ .label = "Find request…", .action = .{ .command = .@"http.find_request" }, .separator_before = true },
        },
        .item => switch (row.section) {
            .collections => &.{
                .{ .label = "Open", .action = .{ .command = .@"http.panel_open" } },
                .{ .label = "Copy path", .action = .{ .command = .@"http.panel_copy_path" } },
                .{ .label = "Rename…", .action = .{ .command = .@"http.rename_request" }, .separator_before = true },
                .{ .label = "Duplicate", .action = .{ .command = .@"http.duplicate_request" } },
                .{ .label = "Move to…", .action = .{ .command = .@"http.move_request" } },
                .{ .label = "Delete…", .action = .{ .command = .@"http.delete_request" } },
                .{ .label = "Find request…", .action = .{ .command = .@"http.find_request" }, .separator_before = true },
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
        },
    };
    const owned = try app.gpa.dupe(M, items);
    errdefer app.gpa.free(owned);
    const title = switch (row.kind) {
        .header => row.section.label(),
        .link => row.link.text(app.cfg.ui.ascii_icons),
        else => row.label,
    };
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
    for (st.rows.items) |r| if (r.kind == .header) {
        shown += r.count;
    };
    const subtitle = if (st.list.filterText().len == 0)
        ui.fmt(" ({d}{s})", .{ total, cap })
    else
        ui.fmt(" ({d} of {d}{s})", .{ shown, total, cap });
    const caret = view.draw(&st.list, ui, area, .{
        .subtitle = subtitle,
        .rows = st.rows.items,
        .empty = .{ .message = "No matches — Esc clears" },
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;
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
        try f.write("loose.http", "GET https://x/loose\n");
        try f.write(".mnml/collections/smoke/ping.http", "GET https://x/ping\n");
        try f.write(".mnml/env/dev.env", "HOST=https://dev\n");
        try f.write(".mnml/env/prod.env", "HOST=https://prod\n");
        try f.write(".mnml/chains/login.chain.json", "[{\"request\":\"api/users.http\"}]\n");
        try f.write(".mnml/cookies.json", "{\"x.test\":{\"session\":\"abc\"}}\n");
        try f.write(".rqst/history.jsonl", "{\"ts\":1,\"method\":\"POST\",\"url\":\"https://x/login\",\"status\":201}\n{\"ts\":2,\"method\":\"GET\",\"url\":\"https://x/users\",\"status\":200}\n");
        try f.write(".rqst/captured/log.jsonl", "{\"at\":1,\"request_id\":\"r1\",\"method\":\"GET\",\"url\":\"https://cdn.test/app.js\"}\n");
    }

    /// The index of the first row of `kind` in `section` (label
    /// filtered when given).
    fn rowOf(f: *Fixture, section: Section, kind: Kind, label: ?[]const u8) ?usize {
        for (f.app.http_panel.rows.items, 0..) |r, i| {
            if (r.section != section or r.kind != kind) continue;
            if (label) |l| if (!std.mem.eql(u8, r.label, l)) continue;
            return i;
        }
        return null;
    }

    /// Where the first `.http` hit matching `pred` painted last frame.
    fn findHit(f: *Fixture, comptime pred: fn (Part) bool) ?struct { x: u16, y: u16 } {
        for (f.app.hits.items.items) |e| switch (e.target) {
            .http => |p| if (pred(p)) return .{ .x = e.rect.x, .y = e.rect.y },
            else => {},
        };
        return null;
    }
};

/// The kinds of `section`'s rows, the three action links at the end
/// of the list left out.
fn kinds(st: *const State, section: Section, out: *[64]Kind) []const Kind {
    var n: usize = 0;
    for (st.rows.items) |r| {
        if (r.section != section or n >= out.len) continue;
        if (r.kind == .link and (r.link == .new_request or r.link == .paste_curl or r.link == .import)) continue;
        out[n] = r.kind;
        n += 1;
    }
    return out[0..n];
}

test "refresh lists every section; collections group by folder with the hidden one named; the filter narrows across all seven, unfolds the tree and drops the sections it empties" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    var kb: [64]Kind = undefined;
    try testing.expectEqual(@as(usize, 4), st.files.len);
    try sdk_testing.expectPath(".mnml/collections/smoke/ping.http", st.files[0]);
    try testing.expectEqual(@as(usize, 2), st.folders.len);
    try testing.expectEqualStrings("smoke", st.folders[0].name);
    try testing.expect(st.folders[0].hidden);
    try testing.expectEqualStrings("api", st.folders[1].name);
    try testing.expectEqual(@as(usize, 2), st.folders[1].members.len);
    try testing.expectEqual(@as(usize, 1), st.loose.len);
    try testing.expectEqualStrings("loose.http", st.files[st.loose[0]]);
    try testing.expectEqual(@as(usize, 2), st.envs.len);
    try testing.expectEqual(@as(usize, 1), st.chains.len);
    try testing.expectEqual(@as(usize, 1), st.mocks.len);
    try testing.expectEqual(@as(usize, 1), st.cookies.len);
    try testing.expectEqual(@as(usize, 2), st.recent.len);
    try testing.expectEqualStrings("GET", st.recent[0].method);
    try testing.expectEqual(@as(usize, 1), st.captured.len);
    // COLLECTIONS: header, smoke + ping, api + two, loose, gap.
    try testing.expectEqualSlices(Kind, &.{ .header, .folder, .item, .folder, .item, .item, .item, .gap }, kinds(st, .collections, &kb));
    try testing.expectEqual(@as(u32, 4), st.shown(.collections).?);
    // ENVS has its link after the items; CHAINS too; MOCKS none.
    try testing.expectEqualSlices(Kind, &.{ .header, .item, .item, .link, .gap }, kinds(st, .envs, &kb));
    try testing.expectEqualSlices(Kind, &.{ .header, .item, .link, .gap }, kinds(st, .chains, &kb));
    try testing.expectEqualSlices(Kind, &.{ .header, .item, .gap }, kinds(st, .mocks, &kb));
    try sdk_testing.expectPath("api/orders.curl", st.rows.items[f.rowOf(.mocks, .item, null).?].label);
    // The three action links close the list.
    const n = st.rows.items.len;
    try testing.expectEqual(Link.new_request, st.rows.items[n - 3].link);
    try testing.expectEqual(Link.import, st.rows.items[n - 1].link);
    // `users` matches a file and a recent row: the other five sections go,
    // and so do the words, the links and the gaps' neighbours.
    try st.list.filter.appendSlice(testing.allocator, "USERS");
    try rebuild(&f.app);
    try testing.expectEqual(@as(u32, 1), st.shown(.collections).?);
    try testing.expectEqualSlices(Kind, &.{ .header, .folder, .item, .gap }, kinds(st, .collections, &kb));
    try testing.expectEqual(@as(u32, 1), st.shown(.recent).?);
    try testing.expect(st.shown(.envs) == null);
    try testing.expect(st.shown(.cookies) == null);
    // A folder's name matches: every member shows.
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "api");
    try rebuild(&f.app);
    try testing.expectEqual(@as(u32, 2), st.shown(.collections).?);
    // A cookie's host is searchable too.
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "x.test");
    try rebuild(&f.app);
    try testing.expectEqual(@as(u32, 1), st.shown(.cookies).?);
    // Nothing matches: no rows, so the panel says so.
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, "zzz");
    try rebuild(&f.app);
    try testing.expectEqual(@as(usize, 0), st.rows.items.len);
}

test "an empty workspace: every section's words, the links under COLLECTIONS / ENVS / CHAINS, the cursor skips the words and gaps" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    var kb: [64]Kind = undefined;
    try testing.expectEqualSlices(Kind, &.{ .header, .empty, .link, .gap }, kinds(st, .collections, &kb));
    try testing.expectEqual(Link.new_collection, st.rows.items[2].link);
    try testing.expectEqualSlices(Kind, &.{ .header, .empty, .link, .gap }, kinds(st, .envs, &kb));
    try testing.expectEqualSlices(Kind, &.{ .header, .empty, .gap }, kinds(st, .mocks, &kb));
    try testing.expectEqualStrings("No mocks — `:http.save_mock` on a response.", st.rows.items[f.rowOf(.mocks, .empty, null).?].label);
    try testing.expect(std.mem.startsWith(u8, st.rows.items[f.rowOf(.captured, .empty, null).?].label, "Nothing captured yet"));
    // j from the header lands on the link, not the words; k back. The
    // keys need a first draw (it sets the list's total): show the panel.
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    focusPanel(&f.app);
    try f.app.render();
    try f.app.handle(.{ .key = Key.char('j') });
    try testing.expectEqual(@as(usize, 2), st.list.cursor);
    try f.app.handle(.{ .key = Key.char('j') });
    try testing.expectEqual(@as(usize, 4), st.list.cursor);
    try f.app.handle(.{ .key = Key.char('k') });
    try testing.expectEqual(@as(usize, 2), st.list.cursor);
    // G reaches the last link.
    try f.app.handle(.{ .key = Key.char('G') });
    try testing.expectEqual(Link.import, st.selected().?.link);
}

test "a collapsed section keeps its header; a folder folds; collapse-all folds every one and unfolds once all are closed" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    var kb: [64]Kind = undefined;
    st.collapsed.insert(.recent);
    try rebuild(&f.app);
    try testing.expectEqualSlices(Kind, &.{ .header, .gap }, kinds(st, .recent, &kb));
    try testing.expectEqual(@as(u32, 2), st.shown(.recent).?);
    try toggleFolder(&f.app, 1);
    try testing.expectEqualSlices(Kind, &.{ .header, .folder, .item, .folder, .item, .gap }, kinds(st, .collections, &kb));
    try testing.expect(st.rows.items[3].collapsed);
    try testing.expectEqual(@as(u32, 4), st.shown(.collections).?);
    try toggleFolder(&f.app, 1);
    try testing.expect(!st.rows.items[3].collapsed);
    try command.run(&f.app, .{ .static = .@"http.toggle_collapse_all" });
    for (Section.all) |s| try testing.expectEqualSlices(Kind, &.{ .header, .gap }, kinds(st, s, &kb));
    try command.run(&f.app, .{ .static = .@"http.toggle_collapse_all" });
    try testing.expectEqualSlices(Kind, &.{ .header, .item, .item, .link, .gap }, kinds(st, .envs, &kb));
}

test "activate: an env row becomes the session override; a file row opens a request pane; a cookie row copies name=value; a link opens its prompt" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    // Entering opened a blank request pane and gave it the keys.
    try testing.expect(f.app.focus == .pane);
    try testing.expectEqualStrings("GET  new request", f.app.panes.get(f.app.active.?).?.title());
    try refresh(&f.app);
    const st = &f.app.http_panel;
    st.list.cursor = f.rowOf(.envs, .item, "prod").?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expectEqualStrings("prod", f.app.http.env_override.?);
    try testing.expect(st.rows.items[f.rowOf(.envs, .item, "prod").?].active);
    st.list.cursor = f.rowOf(.cookies, .item, null).?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expectEqualStrings("session=abc", f.app.clipboard.text());
    st.list.cursor = f.rowOf(.collections, .item, "users.http").?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    const rp = http.activeRequest(&f.app).?;
    try testing.expectEqualStrings("https://x/users", rp.url.items);
    st.list.cursor = f.rowOf(.envs, .link, null).?;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.prompt.state.title, "New env name") != null);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // The Import link opens the two-row menu; both rows name registered ids.
    st.list.cursor = st.rows.items.len - 1;
    try command.run(&f.app, .{ .static = .@"http.panel_open" });
    try testing.expect(f.app.overlay == .menu);
    try testing.expectEqualStrings("Import from:", f.app.overlay.menu.title);
    try testing.expectEqual(command.CommandId.@"http.import_postman", f.app.overlay.menu.items[0].action.command);
    try testing.expectEqual(command.CommandId.@"http.import_har", f.app.overlay.menu.items[1].action.command);
    try f.app.handle(.{ .key = Key.named(.esc) });
}

test "entering twice opens one pane; with a request pane active none; leaving closes the preview and the blank, keeps the dirty" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    try testing.expectEqual(@as(usize, 1), f.app.panes.count());
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    try testing.expectEqual(@as(usize, 1), f.app.panes.count());
    // Untouched preview: leaving closes it (Rust's rule).
    try command.run(&f.app, .{ .static = .@"view.activity_todos" });
    try testing.expectEqual(@as(usize, 0), f.app.panes.count());
    // Typed into: it survives.
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    const rp = http.activeRequest(&f.app).?;
    try rp.url.appendSlice(f.app.gpa, "http://x/y");
    rp.edited = true;
    try command.run(&f.app, .{ .static = .@"view.activity_todos" });
    try testing.expectEqual(@as(usize, 1), f.app.panes.count());
    try testing.expect(f.app.panes.get(f.app.active.?).?.* == .request);
    // Emptied again: it reads blank and goes on the next leave.
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    rp.url.clearRetainingCapacity();
    try testing.expect(rp.isEffectivelyBlank());
    try command.run(&f.app, .{ .static = .@"view.activity_todos" });
    try testing.expectEqual(@as(usize, 0), f.app.panes.count());
}

test "headless: the panel paints the blank row under the filter, seven headers with their ladders, the tree, the words and the links; the filter row narrows; enter on a header folds it" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    focusPanel(&f.app);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    // The list is longer than the panel: the first screen holds the
    // top sections, `G` scrolls the tail into view below.
    for ([_]Section{ .collections, .envs, .chains, .mocks }) |s| try testing.expect(std.mem.indexOf(u8, txt, s.label()) != null);
    // Under the menu bar: row 1 the header, row 2 the filter, row 3
    // blank (the user's pattern), row 4 the COLLECTIONS header.
    var lines = std.mem.splitScalar(u8, txt, '\n');
    _ = lines.next();
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "HTTP (12)") != null);
    try testing.expect(sdk_testing.pathContains(lines.next().?, "/ filter"));
    _ = lines.next();
    var x: u16 = 4;
    while (x < 30) : (x += 1) try testing.expectEqualStrings(" ", f.app.screen.readCell(x, 3).?.char.grapheme);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "COLLECTIONS (4)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F47C} \u{F07B} api (2)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F15C} users.http") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F1D8} loose.http") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F114} smoke (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "+ New env") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "+ New chain") != null);
    // The ladders: ENVS' `+`, the folder `+`.
    try testing.expect(f.findHit(struct {
        fn p(part: Part) bool {
            return part == .chip and part.chip.section == .envs and part.chip.kind == .new;
        }
    }.p) != null);
    try testing.expect(f.findHit(struct {
        fn p(part: Part) bool {
            return part == .folder_new;
        }
    }.p) != null);
    // The tail: COOKIES, RECENT, CAPTURED's words and chip, the three links.
    try f.app.handle(.{ .key = Key.char('G') });
    const tail = try f.screen();
    defer testing.allocator.free(tail);
    for ([_]Section{ .cookies, .recent, .captured }) |s| try testing.expect(std.mem.indexOf(u8, tail, s.label()) != null);
    try testing.expect(sdk_testing.pathContains(tail, "201 POST x/login"));
    try testing.expect(std.mem.indexOf(u8, tail, "session  x.test") != null);
    try testing.expect(sdk_testing.pathContains(tail, "GET  cdn.test/app.js"));
    try testing.expect(std.mem.indexOf(u8, tail, "+ New request") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\u{2193} Paste curl…") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\u{2193} Import…") != null);
    try testing.expect(f.findHit(struct {
        fn p(part: Part) bool {
            return part == .chip and part.chip.section == .captured and part.chip.kind == .capture;
        }
    }.p) != null);
    // Back to row 0, the COLLECTIONS header; enter folds it.
    try f.app.handle(.{ .key = Key.char('g') });
    try f.app.handle(.{ .key = Key.named(.enter) });
    const st = &f.app.http_panel;
    try testing.expect(st.collapsed.contains(.collections));
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "users.http") == null);
    try testing.expect(std.mem.indexOf(u8, txt2, "COLLECTIONS (4)") != null);
    // `/` then typing narrows; the subtitle counts what survived.
    try f.app.handle(.{ .key = Key.char('/') });
    try f.app.handle(.{ .key = Key.char('l') });
    try f.app.handle(.{ .key = Key.char('o') });
    try f.app.handle(.{ .key = Key.char('g') });
    const txt3 = try f.screen();
    defer testing.allocator.free(txt3);
    try testing.expect(std.mem.indexOf(u8, txt3, "(2 of 12)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "CHAINS (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "RECENT (1)") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "ENVS") == null);
    try testing.expect(std.mem.indexOf(u8, txt3, "+ New chain") == null);
}

test "clicks: a header chip acts (ENVS + opens the prompt, RECENT ✕ truncates the log), a link acts, the folder + opens req-1.http in the collection, a folder row folds" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    f.app.tree.visible = false;
    // A 34-cell column: RECENT's ladder keeps its ✕ beside the scrollbar.
    f.app.tree.width = 34;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    try f.app.render();
    const st = &f.app.http_panel;
    const env_new = f.findHit(struct {
        fn p(part: Part) bool {
            return part == .chip and part.chip.section == .envs and part.chip.kind == .new;
        }
    }.p).?;
    try f.app.handle(.{ .mouse = .{ .x = env_new.x + 1, .y = env_new.y, .kind = .press, .button = .left } });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.prompt.state.title, "New env name") != null);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try f.app.render();
    const folder_new = f.findHit(struct {
        fn p(part: Part) bool {
            return part == .folder_new and part.folder_new == 1;
        }
    }.p).?;
    try f.app.handle(.{ .mouse = .{ .x = folder_new.x + 1, .y = folder_new.y, .kind = .press, .button = .left } });
    const rp = http.activeRequest(&f.app).?;
    try testing.expect(sdk_testing.pathEndsWith(rp.source_path.?, "/api/req-1.http"));
    try testing.expectEqualStrings("req-1.http", rp.title());
    // RECENT is below the first screenful: G scrolls the tail in.
    focusPanel(&f.app);
    try f.app.handle(.{ .key = Key.char('G') });
    try f.app.render();
    // The RECENT clear chip fits at this width: the log is truncated.
    const recent_clear = f.findHit(struct {
        fn p(part: Part) bool {
            return part == .chip and part.chip.section == .recent and part.chip.kind == .clear;
        }
    }.p).?;
    try f.app.handle(.{ .mouse = .{ .x = recent_clear.x + 1, .y = recent_clear.y, .kind = .press, .button = .left } });
    try testing.expectEqual(@as(usize, 0), st.recent.len);
    try testing.expect(st.shown(.recent).? == 0);
    try f.app.render();
    // The `+ New chain` link.
    const chain_link = f.findHit(struct {
        fn p(part: Part) bool {
            return part == .link and part.link == .new_chain;
        }
    }.p).?;
    try f.app.handle(.{ .mouse = .{ .x = chain_link.x + 3, .y = chain_link.y, .kind = .press, .button = .left } });
    try testing.expect(f.app.overlay == .prompt);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.prompt.state.title, "New chain name") != null);
    try f.app.handle(.{ .key = Key.named(.esc) });
    focusPanel(&f.app);
    try f.app.handle(.{ .key = Key.char('g') });
    try f.app.render();
    // A press on the api folder row (not its +) folds it.
    const folder_idx = f.rowOf(.collections, .folder, "api").?;
    var y: u16 = 0;
    var found = false;
    while (y < 40 and !found) : (y += 1) {
        if (f.app.hits.at(8, y)) |t| if (t == .row and t.row.panel == .http and t.row.idx == folder_idx) {
            found = true;
            try f.app.handle(.{ .mouse = .{ .x = 8, .y = y, .kind = .press, .button = .left } });
        };
    }
    try testing.expect(found);
    try testing.expect(st.rows.items[folder_idx].collapsed);
    try testing.expect(st.collapsed_dirs.contains("api"));
}

test "one left press on a request row opens it, as a tree file does; a folder row folds on one press too" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    f.app.tree.visible = false;
    f.app.tree.width = 34;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    try f.app.render();
    const st = &f.app.http_panel;
    const item_idx = f.rowOf(.collections, .item, "loose.http").?;
    var y: u16 = 0;
    var found = false;
    while (y < 40 and !found) : (y += 1) {
        if (f.app.hits.at(8, y)) |t| if (t == .row and t.row.panel == .http and t.row.idx == item_idx) {
            found = true;
            try f.app.handle(.{ .mouse = .{ .x = 8, .y = y, .kind = .press, .button = .left } });
        };
    }
    try testing.expect(found);
    // No second press waited for: the pane is open and it is the row's.
    const rp = http.activeRequest(&f.app).?;
    try testing.expect(sdk_testing.pathEndsWith(rp.source_path.?, "/loose.http"));
    try testing.expectEqual(item_idx, st.list.cursor);
}

test "every row menu names registered ids only; the header menus carry the section's verbs" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    try f.seedAll();
    try refresh(&f.app);
    const st = &f.app.http_panel;
    for (st.rows.items, 0..) |r, i| {
        if (!r.isStop()) continue;
        st.list.cursor = i;
        try openRowMenu(&f.app, 3, 3);
        try testing.expect(f.app.overlay == .menu);
        try testing.expect(f.app.overlay.menu.items.len > 0);
        for (f.app.overlay.menu.items) |it| switch (it.action) {
            .command => |id| try testing.expect(command.by_name.get(command.name(id)) != null),
            else => return error.TestUnexpectedResult,
        };
        try f.app.handle(.{ .key = Key.named(.esc) });
    }
    st.list.cursor = f.rowOf(.captured, .header, null).?;
    try openRowMenu(&f.app, 3, 3);
    try testing.expectEqualStrings("Start capture", f.app.overlay.menu.items[3].label);
    try f.app.handle(.{ .key = Key.named(.esc) });
}

test "the green + chip on the header opens a blank request; its hit is the .new chip of the http panel" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    f.app.tree.visible = false;
    try command.run(&f.app, .{ .static = .@"view.activity_http" });
    const before = f.app.panes.count();
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
    try testing.expectEqual(before + 1, f.app.panes.count());
    const pane = f.app.panes.get(f.app.active.?).?;
    try testing.expect(pane.* == .request);
    try testing.expectEqualStrings("GET  new request", pane.title());
}
