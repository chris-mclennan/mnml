//! The workspace trash: a delete moves the entry to
//! `<data root>/trash/<workspace hash>/` instead of unlinking it, so a
//! delete can be taken back. Each entry is renamed `<stamp>-<name>`
//! (a counter when the name is taken within one second — `rename`
//! replaces, and two deletes of one name would have destroyed the
//! first) and its origin is recorded in an index beside the trash,
//! so `files.restore_from_trash` knows where it goes back.
//!
//! Bounded, or the delete is only deferred: entries older than a week
//! go, the whole trash is capped at 512 MB (oldest evicted first), and
//! anything at least 256 MB skips the trash outright — moving it there
//! would not free the space the user wants back, and the size cap would
//! evict it moments later. The bounds are enforced on a tick and after
//! every delete.
//!
//! The confirm offers `Delete` (to the trash) and `Delete permanently`;
//! inside the trash there is nowhere further to defer to, so only the
//! permanent form is offered and the row menu says so.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const files_pane = @import("files_pane.zig");
const lsp = @import("lsp.zig");
const file_clipboard = @import("file_clipboard.zig");

pub const table = .{
    .@"files.trash" = &openTrashCmd,
    .@"files.restore_from_trash" = &restoreCmd,
    .@"files.empty_trash" = &emptyTrashCmd,
};

pub const Bounds = struct {
    max_age_s: i64 = 7 * 24 * 60 * 60,
    max_total_bytes: u64 = 512 * 1024 * 1024,
    /// Anything at least this big is deleted outright.
    skip_above_bytes: u64 = 256 * 1024 * 1024,
};

pub const default_bounds: Bounds = .{};

/// How often the tick prunes.
pub const prune_every_ms: i64 = 10 * 60 * 1000;

pub const State = struct {
    /// When the tick last pruned; 0 = not yet (the first tick does).
    last_prune_ms: i64 = 0,
    bounds: Bounds = default_bounds,
};

pub const Rec = struct { entry: []const u8, origin: []const u8, at: i64 };
const Index = struct { entries: []const Rec = &.{} };

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'p', .label = "Delete permanently" }, .{ .key = 'c', .label = "Cancel" } };
pub const permanent_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'p', .label = "Delete permanently" }, .{ .key = 'c', .label = "Cancel" } };
pub const empty_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'e', .label = "Empty trash" }, .{ .key = 'c', .label = "Cancel" } };

fn nowUnix(app: *App) i64 {
    return Io.Timestamp.now(app.io, .real).toSeconds();
}

/// `<data root>/trash/<hash of the workspace>`; `<workspace>/.mnml/trash`
/// when the app has no data root (the unit tests).
pub fn dir(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    if (app.data_root.len == 0) return std.fs.path.join(arena, &.{ app.workspace, ".mnml", "trash" });
    const h = std.hash.Wyhash.hash(0, app.workspace);
    const name = try std.fmt.allocPrint(arena, "{x:0>16}", .{h});
    return std.fs.path.join(arena, &.{ app.data_root, "trash", name });
}

/// The index lives BESIDE the trash, not in it — inside, it painted as
/// a row next to the user's deleted files.
pub fn indexPath(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const d = try dir(app, arena);
    return std.fmt.allocPrint(arena, "{s}.index.zon", .{d});
}

pub fn isTrashDir(app: *App, path: []const u8) bool {
    const d = dir(app, app.frame.allocator()) catch return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), d);
}

/// Whether `path` is an entry directly inside the trash.
pub fn isTrashEntry(app: *App, path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    return isTrashDir(app, parent);
}

fn readIndex(app: *App, arena: Allocator) Allocator.Error![]const Rec {
    const path = try indexPath(app, arena);
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 24)) catch return &.{};
    const z = try arena.dupeZ(u8, text);
    const idx = std.zon.parse.fromSliceAlloc(Index, arena, z, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch return &.{};
    return idx.entries;
}

fn writeIndex(app: *App, recs: []const Rec) Allocator.Error!void {
    const arena = app.frame.allocator();
    const path = try indexPath(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(Index{ .entries = recs }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() }) catch {};
}

fn recordOrigin(app: *App, entry: []const u8, origin: []const u8, at: i64) Allocator.Error!void {
    const arena = app.frame.allocator();
    const old = try readIndex(app, arena);
    const recs = try arena.alloc(Rec, old.len + 1);
    @memcpy(recs[0..old.len], old);
    recs[old.len] = .{ .entry = entry, .origin = origin, .at = at };
    try writeIndex(app, recs);
}

/// Where the entry named `entry` came from, if recorded. Last match
/// wins: a basename can be trashed repeatedly.
pub fn originOf(app: *App, arena: Allocator, entry: []const u8) Allocator.Error!?[]const u8 {
    var found: ?[]const u8 = null;
    for (try readIndex(app, arena)) |r| if (std.mem.eql(u8, r.entry, entry)) {
        found = r.origin;
    };
    return found;
}

/// The stamp encoded in an entry's name — NOT the mtime, which a rename
/// does not touch (a file untouched for a week would be pruned on the
/// tick it was trashed).
fn trashedAt(name: []const u8) ?i64 {
    var end: usize = 0;
    while (end < name.len and std.ascii.isDigit(name[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, name[0..end], 10) catch null;
}

/// An unused name in the trash for `name`.
fn freeEntryName(app: *App, arena: Allocator, trash_dir: []const u8, name: []const u8, stamp: i64) Allocator.Error![]const u8 {
    const first = try std.fmt.allocPrint(arena, "{d}-{s}", .{ stamp, name });
    if (!exists(app, try std.fs.path.join(arena, &.{ trash_dir, first }))) return first;
    var n: u32 = 2;
    while (n < 10_000) : (n += 1) {
        const cand = try std.fmt.allocPrint(arena, "{d}-{d}-{s}", .{ stamp, n, name });
        if (!exists(app, try std.fs.path.join(arena, &.{ trash_dir, cand }))) return cand;
    }
    return std.fmt.allocPrint(arena, "{d}-{d}-{s}", .{ stamp, app.now_ms, name });
}

fn exists(app: *App, path: []const u8) bool {
    Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    return true;
}

/// Total bytes under `path` — a file's size, or the sum over a tree.
/// Symlinks count as themselves and are never followed.
pub fn measure(io: Io, gpa: Allocator, path: []const u8) u64 {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
    if (st.kind != .directory) return st.size;
    var root = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer root.close(io);
    var walker = root.walk(gpa) catch return 0;
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        const s = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        total += s.size;
    }
    return total;
}

/// Whether `path` holds at least `limit` bytes — `measure`, stopping
/// as soon as the answer is yes.
pub fn atLeast(io: Io, gpa: Allocator, path: []const u8, limit: u64) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    if (st.kind != .directory) return st.size >= limit;
    var root = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer root.close(io);
    var walker = root.walk(gpa) catch return false;
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        const s = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        total += s.size;
        if (total >= limit) return true;
    }
    return false;
}

/// The editor panes with unsaved edits on `path` — or under it, a
/// folder — and the first such file's path.
fn dirtyUnder(app: *App, path: []const u8) struct { n: usize, first: ?[]const u8 } {
    var n: usize = 0;
    var first: ?[]const u8 = null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |e| if (e.buf.doc.path) |bp| {
        const under = std.mem.eql(u8, bp, path) or (std.mem.startsWith(u8, bp, path) and bp.len > path.len and bp[path.len] == '/');
        if (under and p.dirty()) {
            n += 1;
            if (first == null) first = bp;
        }
    };
    return .{ .n = n, .first = first };
}

/// A trashed entry keeps what the user SAW: every dirty buffer on
/// `path` (or under it) writes its text over its file's copy inside
/// the trash entry `dest`, so a restore brings the unsaved edits back.
fn keepUnsaved(app: *App, path: []const u8, dest: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const Buffer = @import("../editor/buffer.zig").Buffer;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |e| if (e.buf.doc.path) |bp| {
        if (!p.dirty()) continue;
        const target = if (std.mem.eql(u8, bp, path))
            dest
        else if (std.mem.startsWith(u8, bp, path) and bp.len > path.len and bp[path.len] == '/')
            try std.fs.path.join(arena, &.{ dest, bp[path.len + 1 ..] })
        else
            continue;
        const data = try Buffer.withEol(arena, e.buf.editor.bytes(), e.buf.doc.eol);
        if (std.fs.path.dirname(target)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = target, .data = data }) catch |err| {
            app.toast("could not keep the unsaved edits of {s} in the trash: {s}", .{ app.relPath(bp), @errorName(err) });
        };
    };
}

fn removeOutright(app: *App, path: []const u8) !void {
    const st = try Io.Dir.cwd().statFile(app.io, path, .{ .follow_symlinks = false });
    if (st.kind == .directory) return Io.Dir.cwd().deleteTree(app.io, path);
    return Io.Dir.cwd().deleteFile(app.io, path);
}

// ─── the confirm ────────────────────────────────────────────────────────

/// Ask before deleting `paths` (absolute). Cancel is the default; the
/// permanent button is there for whoever wants to skip the trash.
/// Entries under `dir`, recursively, stopping at `cap`.
fn entryCount(app: *App, path: []const u8, cap: usize) usize {
    var d = Io.Dir.cwd().openDir(app.io, path, .{ .iterate = true }) catch return 0;
    defer d.close(app.io);
    var walker = d.walk(app.gpa) catch return 0;
    defer walker.deinit();
    var n: usize = 0;
    while (n < cap) {
        const e = walker.next(app.io) catch break;
        if (e == null) break;
        n += 1;
    }
    return n;
}

pub fn confirmDelete(app: *App, paths: []const []const u8) Allocator.Error!void {
    if (paths.len == 0) return;
    const gpa = app.gpa;
    const owned = try gpa.alloc([]u8, paths.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |p| gpa.free(p);
        gpa.free(owned);
    }
    for (paths) |p| {
        owned[n] = try gpa.dupe(u8, p);
        n += 1;
    }
    const in_trash = isTrashEntry(app, paths[0]);
    // Too large for the trash: the delete can only be permanent, and
    // the box says so BEFORE the choice — never an undoable-looking
    // Delete that turns out permanent afterwards.
    var too_big = false;
    if (!in_trash) for (paths) |p| {
        if (atLeast(app.io, app.gpa, p, app.trash.bounds.skip_above_bytes)) too_big = true;
    };
    const permanent_only = in_trash or too_big;
    var dirty_n: usize = 0;
    var dirty_first: ?[]const u8 = null;
    for (paths) |p| {
        const d = dirtyUnder(app, p);
        dirty_n += d.n;
        if (dirty_first == null) dirty_first = d.first;
    }
    const arena = app.frame.allocator();
    const dirty_note = if (dirty_n == 0)
        ""
    else if (permanent_only)
        try std.fmt.allocPrint(arena, "  — unsaved changes in {s} are lost", .{if (dirty_n == 1) app.relPath(dirty_first.?) else try std.fmt.allocPrint(arena, "{d} open files", .{dirty_n})})
    else
        try std.fmt.allocPrint(arena, "  — unsaved changes in {s}: the trash keeps them", .{if (dirty_n == 1) app.relPath(dirty_first.?) else try std.fmt.allocPrint(arena, "{d} open files", .{dirty_n})});
    const trash_note = if (in_trash) "  (permanent — already in the trash)" else "";
    const big_note = if (too_big) try std.fmt.allocPrint(arena, "  — too large for the trash ({d} MB+): permanent", .{app.trash.bounds.skip_above_bytes / (1024 * 1024)}) else "";
    const first_dir = if (Io.Dir.cwd().statFile(app.io, paths[0], .{})) |st| st.kind == .directory else |_| false;
    // Rust's question: `Delete <rel>?`, a directory's with its entry
    // count, an entry already in the trash flagged permanent. The
    // buttons say where it goes.
    const msg = if (paths.len > 1)
        try std.fmt.allocPrint(gpa, "Delete {d} items?{s}{s}{s}", .{ paths.len, trash_note, big_note, dirty_note })
    else if (first_dir) blk: {
        const n_entries = entryCount(app, paths[0], 500);
        var nb: [24]u8 = undefined;
        const hint = if (n_entries >= 500) "500+ entries" else std.fmt.bufPrint(&nb, "{d} entr{s}", .{ n_entries, if (n_entries == 1) "y" else "ies" }) catch "entries";
        break :blk try std.fmt.allocPrint(gpa, "Delete {s} recursively? ({s}){s}{s}{s}", .{ app.relPath(paths[0]), hint, trash_note, big_note, dirty_note });
    } else try std.fmt.allocPrint(gpa, "Delete {s}?{s}{s}{s}", .{ app.relPath(paths[0]), trash_note, big_note, dirty_note });
    errdefer gpa.free(msg);
    const choices: []const app_mod.Confirm.Choice = if (permanent_only) &permanent_choices else &delete_choices;
    app.overlay.deinit(gpa);
    app.overlay = .{
        .confirm = .{
            .state = .{
                .title = "Delete",
                .message = msg,
                .choices = choices,
                // Cancel is the focus, as in Rust: a destructive box's
                // Enter must not be the destructive act.
                .selected = choices.len - 1,
            },
            .purpose = .{ .delete_paths = .{ .paths = owned, .permanent_only = permanent_only } },
            .message = msg,
            .return_focus = if (app.focus == .tree) .tree else null,
        },
    };
    app.focus = .overlay;
    app.needs_render = true;
}

/// A trash delete that could not go to the trash: ask again, naming
/// why, with only the permanent form (and Cancel, the default) on offer.
fn confirmPermanent(app: *App, paths: []const []const u8, why: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const owned = try gpa.alloc([]u8, paths.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |p| gpa.free(p);
        gpa.free(owned);
    }
    for (paths) |p| {
        owned[n] = try gpa.dupe(u8, p);
        n += 1;
    }
    const what = if (paths.len == 1) app.relPath(paths[0]) else try std.fmt.allocPrint(app.frame.allocator(), "{d} items", .{paths.len});
    const msg = try std.fmt.allocPrint(gpa, "{s} was not deleted — {s}. Delete it permanently?", .{ what, why });
    errdefer gpa.free(msg);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Delete permanently", .message = msg, .choices = &permanent_choices, .selected = permanent_choices.len - 1 },
        .purpose = .{ .delete_paths = .{ .paths = owned, .permanent_only = true } },
        .message = msg,
        .return_focus = if (app.focus == .tree) .tree else null,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The confirm's answer: choice 0 trashes (or deletes, inside the
/// trash), the permanent button deletes outright, and the Cancel button
/// says so.
pub fn acceptDelete(app: *App, paths: []const []const u8, permanent_only: bool, choice: usize) Allocator.Error!void {
    if (permanent_only) {
        if (choice != 0) return cancelled(app, paths, true);
        return deletePaths(app, paths, true);
    }
    switch (choice) {
        0 => try deletePaths(app, paths, false),
        1 => try deletePaths(app, paths, true),
        else => cancelled(app, paths, false),
    }
}

/// Cancel was the answer. Cancel is the FOCUSED button, so Enter — the
/// most likely key on any dialog — lands here, and it used to tear the
/// box down with nothing said: on screen that is indistinguishable from
/// a delete that worked. The toast names the key that does delete, so
/// the keeping of the file reads as the deliberate default it is.
/// (Esc stays silent: asking to leave and being told you left is noise.)
fn cancelled(app: *App, paths: []const []const u8, permanent_only: bool) void {
    if (paths.len == 0) return;
    const keys = if (permanent_only) "`p` deletes permanently" else "`d` deletes, `p` permanently";
    if (paths.len == 1) {
        app.toast("cancelled — {s} kept; {s}", .{ app.relPath(paths[0]), keys });
    } else {
        app.toast("cancelled — {d} items kept; {s}", .{ paths.len, keys });
    }
}

// ─── the delete ─────────────────────────────────────────────────────────

/// Delete every path: into the trash unless `permanent`, the entry is
/// already in the trash, it is too large to keep, or the move fails —
/// the toast says which. Buffers on a deleted path close.
pub fn deletePaths(app: *App, paths: []const []const u8, permanent: bool) Allocator.Error!void {
    const arena = app.frame.allocator();
    const bounds = app.trash.bounds;
    var trashed: usize = 0;
    var removed: usize = 0;
    var failed: usize = 0;
    var last_note: []const u8 = "";
    const trash_dir = try dir(app, arena);
    const stamp = nowUnix(app);
    // What the trash could not take — too large, or the move into it
    // failed (another volume, a read-only data root). The user picked
    // the undoable delete, so these are NOT removed: the box asks again.
    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var kept_why: []const u8 = "";
    for (paths) |path| {
        const is_dir = if (Io.Dir.cwd().statFile(app.io, path, .{ .follow_symlinks = false })) |st| st.kind == .directory else |_| false;
        const name = std.fs.path.basename(path);
        const already = isTrashEntry(app, path);
        const too_big = !permanent and !already and atLeast(app.io, app.gpa, path, bounds.skip_above_bytes);
        var moved = false;
        if (!permanent and !already) {
            if (too_big) {
                try kept.append(arena, path);
                kept_why = try std.fmt.allocPrint(arena, "too large for the trash ({d} MB+)", .{bounds.skip_above_bytes / (1024 * 1024)});
                continue;
            }
            Io.Dir.cwd().createDirPath(app.io, trash_dir) catch {};
            const entry = try freeEntryName(app, arena, trash_dir, name, stamp);
            const dest = try std.fs.path.join(arena, &.{ trash_dir, entry });
            if (Io.Dir.renameAbsolute(path, dest, app.io)) {
                moved = true;
                try recordOrigin(app, entry, path, stamp);
                try keepUnsaved(app, path, dest);
            } else |err| {
                try kept.append(arena, path);
                kept_why = try std.fmt.allocPrint(arena, "the trash could not take it: {s}", .{@errorName(err)});
                continue;
            }
        }
        if (!moved) {
            removeOutright(app, path) catch |err| {
                failed += 1;
                last_note = try std.fmt.allocPrint(arena, "{s}: {s}", .{ app.relPath(path), @errorName(err) });
                continue;
            };
            removed += 1;
            last_note = "permanently";
        } else trashed += 1;
        try closeBuffersUnder(app, path, is_dir);
        dropRecent(app, path, is_dir);
        lsp.notifyWatched(app, path, .deleted);
    }
    if (trashed > 0) prune(app, nowUnix(app), bounds);
    try pruneIndex(app);
    try files_pane.refreshAfterFsChange(app);
    if (failed > 0) {
        app.toast("delete failed: {s}", .{last_note});
        return;
    }
    if (kept.items.len > 0) {
        if (trashed > 0) app.toast("deleted {d} item{s} — files.trash restores {s}", .{ trashed, if (trashed == 1) "" else "s", if (trashed == 1) "it" else "them" });
        return confirmPermanent(app, kept.items, kept_why);
    }
    if (paths.len == 1) {
        const rel = app.relPath(paths[0]);
        if (trashed == 1) app.toast("deleted {s} — files.trash restores it", .{rel}) else app.toast("deleted {s} ({s})", .{ rel, last_note });
    } else if (removed == 0) {
        app.toast("deleted {d} items — files.trash restores them", .{trashed});
    } else {
        app.toast("deleted {d} items ({d} {s})", .{ paths.len, removed, last_note });
    }
}

fn closeBuffersUnder(app: *App, path: []const u8, is_dir: bool) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.panes.slots.items.len) : (i += 1) {
        const p = &(app.panes.slots.items[i] orelse continue);
        const e = p.asEditor() orelse continue;
        const bp = e.buf.doc.path orelse continue;
        if (std.mem.eql(u8, bp, path) or (is_dir and std.mem.startsWith(u8, bp, path) and bp.len > path.len and bp[path.len] == '/')) {
            try app.forceClosePane(@intCast(i));
        }
    }
}

fn dropRecent(app: *App, path: []const u8, is_dir: bool) void {
    var i: usize = 0;
    while (i < app.recent.items.len) {
        const r = app.recent.items[i];
        if (std.mem.eql(u8, r, path) or (is_dir and std.mem.startsWith(u8, r, path) and r.len > path.len and r[path.len] == '/')) {
            app.gpa.free(app.recent.orderedRemove(i));
        } else i += 1;
    }
}

// ─── restore ────────────────────────────────────────────────────────────

/// Put a trash entry back where it came from. Refuses rather than
/// clobbers when something has taken the path since.
pub fn restore(app: *App, entry_abs: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (!isTrashEntry(app, entry_abs)) return app.diag.fail(arena, "not a trash entry", .{});
    const entry = std.fs.path.basename(entry_abs);
    const to = (try originOf(app, arena, entry)) orelse return app.diag.fail(arena, "no record of where {s} came from — move it by hand", .{entry});
    if (exists(app, to)) return app.diag.fail(arena, "{s} already exists", .{app.relPath(to)});
    if (std.fs.path.dirname(to)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    Io.Dir.renameAbsolute(entry_abs, to, app.io) catch |err| return app.diag.fail(arena, "restore failed: {s}", .{@errorName(err)});
    try pruneIndex(app);
    try files_pane.refreshAfterFsChange(app);
    app.toast("restored {s}", .{app.relPath(to)});
}

// ─── the bounds ─────────────────────────────────────────────────────────

const Aged = struct { at: i64, path: []const u8, bytes: u64 };

/// Drop entries older than the age bound, then the oldest until the
/// total fits, then index lines whose entry is gone.
pub fn prune(app: *App, now_s: i64, bounds: Bounds) void {
    const arena = app.frame.allocator();
    const trash_dir = dir(app, arena) catch return;
    var d = Io.Dir.cwd().openDir(app.io, trash_dir, .{ .iterate = true }) catch return;
    defer d.close(app.io);
    var aged: std.ArrayListUnmanaged(Aged) = .empty;
    var it = d.iterate();
    while (it.next(app.io) catch null) |ent| {
        const at = trashedAt(ent.name) orelse continue; // not ours: leave it
        const path = std.fs.path.join(arena, &.{ trash_dir, ent.name }) catch return;
        if (now_s - at >= bounds.max_age_s) {
            removeOutright(app, path) catch {};
            continue;
        }
        aged.append(arena, .{ .at = at, .path = path, .bytes = measure(app.io, app.gpa, path) }) catch return;
    }
    var total: u64 = 0;
    for (aged.items) |a| total += a.bytes;
    if (total > bounds.max_total_bytes) {
        std.mem.sort(Aged, aged.items, {}, struct {
            fn lt(_: void, a: Aged, b: Aged) bool {
                return a.at < b.at;
            }
        }.lt);
        for (aged.items) |a| {
            if (total <= bounds.max_total_bytes) break;
            removeOutright(app, a.path) catch continue;
            total -= a.bytes;
        }
    }
    pruneIndex(app) catch {};
}

/// Drop index records whose entry no longer exists.
fn pruneIndex(app: *App) Allocator.Error!void {
    const arena = app.frame.allocator();
    const recs = try readIndex(app, arena);
    if (recs.len == 0) return;
    const trash_dir = try dir(app, arena);
    var kept: std.ArrayListUnmanaged(Rec) = .empty;
    for (recs) |r| {
        if (exists(app, try std.fs.path.join(arena, &.{ trash_dir, r.entry }))) try kept.append(arena, r);
    }
    if (kept.items.len != recs.len) try writeIndex(app, kept.items);
}

/// The tick: the first one prunes, then every ten minutes.
pub fn tick(app: *App, now_ms: i64) void {
    const st = &app.trash;
    if (st.last_prune_ms != 0 and now_ms - st.last_prune_ms < prune_every_ms) return;
    st.last_prune_ms = now_ms;
    prune(app, nowUnix(app), st.bounds);
}

pub fn count(app: *App) usize {
    const arena = app.frame.allocator();
    const trash_dir = dir(app, arena) catch return 0;
    var d = Io.Dir.cwd().openDir(app.io, trash_dir, .{ .iterate = true }) catch return 0;
    defer d.close(app.io);
    var n: usize = 0;
    var it = d.iterate();
    while (it.next(app.io) catch null) |_| n += 1;
    return n;
}

// ─── commands ───────────────────────────────────────────────────────────

/// Open the trash as a Files pane — the seven days are real only if
/// there is somewhere to see them.
/// The trash view is a singleton: a second `files.trash` focuses and
/// re-reads the one that is open rather than stacking a twin.
fn openTrashCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const trash_dir = try dir(app, arena);
    Io.Dir.cwd().createDirPath(app.io, trash_dir) catch return app.diag.fail(arena, "could not open the trash", .{});
    if (count(app) == 0) app.toast("trash is empty", .{});
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .files => |*f| if (f.in_trash) {
            try f.reload(app.io);
            app.showPane(@intCast(i));
            return;
        },
        else => {},
    };
    _ = try files_pane.open(app, trash_dir);
}

fn restoreCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const paths = try file_clipboard.targetPaths(app, arena);
    if (paths.len == 0) return app.diag.fail(arena, "nothing selected", .{});
    for (paths) |p| try restore(app, p);
}

fn emptyTrashCmd(app: *App) CommandError!void {
    const n = count(app);
    if (n == 0) return app.diag.fail(app.frame.allocator(), "trash is empty", .{});
    const msg = try std.fmt.allocPrint(app.gpa, "  Delete {d} trashed item{s} for good?", .{ n, if (n == 1) "" else "s" });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Empty trash", .message = msg, .choices = &empty_choices, .selected = 1 },
        .purpose = .empty_trash,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptEmpty(app: *App, choice: usize) Allocator.Error!void {
    if (choice != 0) return;
    const arena = app.frame.allocator();
    const trash_dir = try dir(app, arena);
    Io.Dir.cwd().deleteTree(app.io, trash_dir) catch {};
    Io.Dir.cwd().deleteFile(app.io, try indexPath(app, arena)) catch {};
    Io.Dir.cwd().createDirPath(app.io, trash_dir) catch {};
    try files_pane.refreshAfterFsChange(app);
    app.toast("trash emptied", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Env = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    data: []u8,

    fn init() !Env {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try std.fs.path.join(t.allocator, &.{ buf[0..n], "ws" });
        errdefer t.allocator.free(root);
        const data = try std.fs.path.join(t.allocator, &.{ buf[0..n], "data" });
        errdefer t.allocator.free(data);
        try tmp.dir.createDirPath(t.io, "ws");
        try tmp.dir.createDirPath(t.io, "data");
        return .{ .tmp = tmp, .root = root, .data = data };
    }

    fn deinit(self: *Env) void {
        t.allocator.free(self.root);
        t.allocator.free(self.data);
        self.tmp.cleanup();
    }

    fn app(self: *Env) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = self.root, .data_root = self.data, .cols = 80, .rows = 20 });
    }
};

test "delete moves the entry to the trash and restore puts it back; a second delete of the same name keeps both" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "first" });
    try env.tmp.dir.createDirPath(t.io, "ws/sub");
    const a = try std.fs.path.join(t.allocator, &.{ env.root, "a.txt" });
    defer t.allocator.free(a);
    _ = try app.openPath(a);
    try deletePaths(&app, &.{a}, false);
    try t.expect(app.active == null); // the buffer closed
    try t.expect(!exists(&app, a));
    try t.expectEqual(@as(usize, 1), count(&app));
    // The trash lives under the data root, keyed by the workspace.
    const td = try dir(&app, app.frame.allocator());
    try t.expect(std.mem.startsWith(u8, td, env.data));
    // Another a.txt within the same second gets its own name.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "second" });
    try deletePaths(&app, &.{a}, false);
    try t.expectEqual(@as(usize, 2), count(&app));
    // Restore the newest (its bytes say "second"); the other then
    // refuses, because the path exists again.
    var d = try Io.Dir.cwd().openDir(t.io, td, .{ .iterate = true });
    defer d.close(t.io);
    var entries: [2][]u8 = undefined;
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(t.io)) |e| : (n += 1) entries[n] = try std.fs.path.join(t.allocator, &.{ td, e.name });
    defer for (entries[0..n]) |e| t.allocator.free(e);
    try t.expectEqual(@as(usize, 2), n);
    const body0 = try Io.Dir.cwd().readFileAlloc(t.io, entries[0], t.allocator, .limited(64));
    defer t.allocator.free(body0);
    const newest_abs = if (std.mem.eql(u8, body0, "second")) entries[0] else entries[1];
    const other_abs = if (newest_abs.ptr == entries[0].ptr) entries[1] else entries[0];
    try restore(&app, newest_abs);
    const back = try env.tmp.dir.readFileAlloc(t.io, "ws/a.txt", t.allocator, .limited(64));
    defer t.allocator.free(back);
    try t.expectEqualStrings("second", back);
    try t.expectError(error.Failed, restore(&app, other_abs));
    try t.expectEqual(@as(usize, 1), count(&app));
    // Deleting an entry already in the trash removes it for good.
    try deletePaths(&app, &.{other_abs}, false);
    try t.expectEqual(@as(usize, 0), count(&app));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "permanently") != null);
    // A permanent delete never touches the trash.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/b.txt", .data = "b" });
    const b = try std.fs.path.join(t.allocator, &.{ env.root, "b.txt" });
    defer t.allocator.free(b);
    try deletePaths(&app, &.{b}, true);
    try t.expectEqual(@as(usize, 0), count(&app));
    try t.expect(!exists(&app, b));
}

test "a trashed file with unsaved edits: the confirm says so and the trash keeps the edits, file or folder" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "saved" });
    try env.tmp.dir.createDirPath(t.io, "ws/lib");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/lib/b.txt", .data = "b" });
    const a = try std.fs.path.join(t.allocator, &.{ env.root, "a.txt" });
    defer t.allocator.free(a);
    const lib = try std.fs.path.join(t.allocator, &.{ env.root, "lib" });
    defer t.allocator.free(lib);
    const b = try std.fs.path.join(t.allocator, &.{ lib, "b.txt" });
    defer t.allocator.free(b);
    _ = try app.openPath(a);
    const e = app.activeEditor().?;
    e.buf.editor.setCursor(e.buf.editor.len());
    _ = try app.applyOps(e, &.{.{ .insert_str = "UNSAVED" }});
    try t.expect(app.panes.get(app.active.?).?.dirty());
    try confirmDelete(&app, &.{a});
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.message, "unsaved changes in a.txt: the trash keeps them") != null);
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(!exists(&app, a));
    // The restore brings back what the user saw, not the last save.
    const td = try dir(&app, app.frame.allocator());
    var d = try Io.Dir.cwd().openDir(t.io, td, .{ .iterate = true });
    var it = d.iterate();
    const entry = try std.fs.path.join(t.allocator, &.{ td, (try it.next(t.io)).?.name });
    d.close(t.io);
    defer t.allocator.free(entry);
    try restore(&app, entry);
    const got = try env.tmp.dir.readFileAlloc(t.io, "ws/a.txt", t.allocator, .limited(64));
    defer t.allocator.free(got);
    try t.expectEqualStrings("savedUNSAVED", got);
    // A folder holding a dirty buffer: the file inside the entry holds the edits.
    _ = try app.openPath(b);
    const eb = app.activeEditor().?;
    _ = try app.applyOps(eb, &.{.{ .insert_str = "EDIT" }});
    try confirmDelete(&app, &.{lib});
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.message, "unsaved changes in lib/b.txt") != null);
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(!exists(&app, lib));
    var d2 = try Io.Dir.cwd().openDir(t.io, td, .{ .iterate = true });
    defer d2.close(t.io);
    var it2 = d2.iterate();
    var lib_entry: ?[]u8 = null;
    while (try it2.next(t.io)) |x| if (std.mem.endsWith(u8, x.name, "-lib")) {
        lib_entry = try std.fs.path.join(t.allocator, &.{ td, x.name, "b.txt" });
    };
    defer if (lib_entry) |q| t.allocator.free(q);
    const kept = try Io.Dir.cwd().readFileAlloc(t.io, lib_entry.?, t.allocator, .limited(64));
    defer t.allocator.free(kept);
    try t.expectEqualStrings("EDITb", kept);
}

test "a directory round-trips through the trash into its own parent; restore refuses an unrecorded entry" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    try env.tmp.dir.createDirPath(t.io, "ws/lib/inner");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/lib/inner/x.txt", .data = "x" });
    const lib = try std.fs.path.join(t.allocator, &.{ env.root, "lib" });
    defer t.allocator.free(lib);
    try deletePaths(&app, &.{lib}, false);
    try t.expect(!exists(&app, lib));
    const td = try dir(&app, app.frame.allocator());
    var d = try Io.Dir.cwd().openDir(t.io, td, .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    const e = (try it.next(t.io)).?;
    try t.expect(std.mem.endsWith(u8, e.name, "-lib"));
    const entry_abs = try std.fs.path.join(t.allocator, &.{ td, e.name });
    defer t.allocator.free(entry_abs);
    try restore(&app, entry_abs);
    try t.expect(exists(&app, lib));
    const x = try env.tmp.dir.readFileAlloc(t.io, "ws/lib/inner/x.txt", t.allocator, .limited(8));
    defer t.allocator.free(x);
    try t.expectEqualStrings("x", x);
    // An entry nobody recorded has nowhere to go.
    try env.tmp.dir.createDirPath(t.io, "data/stray");
    Io.Dir.cwd().createDirPath(t.io, td) catch {};
    const stray = try std.fs.path.join(t.allocator, &.{ td, "1700000000-stray.txt" });
    defer t.allocator.free(stray);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = stray, .data = "?" });
    try t.expectError(error.Failed, restore(&app, stray));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "no record") != null);
}

test "bounds: age prunes by the stamp, the size cap evicts oldest first, an oversize delete is permanent only when asked" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    const arena = app.frame.allocator();
    const td = try dir(&app, arena);
    try Io.Dir.cwd().createDirPath(t.io, td);
    const now = nowUnix(&app);
    // Three stamped entries: old, middle, new — 100 bytes each.
    const old_at = now - 8 * 24 * 3600;
    const mid_at = now - 3600;
    const new_at = now - 60;
    const names = [_][]const u8{
        try std.fmt.allocPrint(arena, "{d}-old.txt", .{old_at}),
        try std.fmt.allocPrint(arena, "{d}-mid.txt", .{mid_at}),
        try std.fmt.allocPrint(arena, "{d}-new.txt", .{new_at}),
    };
    for (names) |nm| try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ td, nm }), .data = "x" ** 100 });
    // Something without a stamp is not ours and is left alone.
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ td, "notes" }), .data = "keep" });
    prune(&app, now, .{});
    try t.expect(!exists(&app, try std.fs.path.join(arena, &.{ td, names[0] })));
    try t.expect(exists(&app, try std.fs.path.join(arena, &.{ td, names[1] })));
    try t.expect(exists(&app, try std.fs.path.join(arena, &.{ td, "notes" })));
    try t.expectEqual(@as(usize, 3), count(&app));
    // A 150-byte budget: mid (older) goes, new stays.
    prune(&app, now, .{ .max_total_bytes = 150 });
    try t.expect(!exists(&app, try std.fs.path.join(arena, &.{ td, names[1] })));
    try t.expect(exists(&app, try std.fs.path.join(arena, &.{ td, names[2] })));
    // Something at or above the per-entry bound cannot go to the trash:
    // the confirm says so up front and offers only the permanent form;
    // a trash delete that meets it anyway (it grew, or the confirm was
    // skipped) removes nothing and asks again.
    app.trash.bounds.skip_above_bytes = 50;
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/huge.bin", .data = "h" ** 64 });
    const huge = try std.fs.path.join(t.allocator, &.{ env.root, "huge.bin" });
    defer t.allocator.free(huge);
    try confirmDelete(&app, &.{huge});
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.message, "too large for the trash") != null);
    try t.expectEqual(@as(usize, 2), app.overlay.confirm.state.choices.len);
    try app.handle(.{ .key = Key.char('d') }); // not a choice here
    try t.expect(exists(&app, huge));
    try app.handle(.{ .key = Key.named(.esc) });
    try deletePaths(&app, &.{huge}, false);
    try t.expect(exists(&app, huge));
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.message, "huge.bin was not deleted — too large for the trash") != null);
    try app.handle(.{ .key = Key.char('p') });
    try t.expect(!exists(&app, huge));
    try t.expectEqual(@as(usize, 2), count(&app)); // new.txt + notes
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "permanently") != null);
    // The first tick prunes; the next one within ten minutes does not run again.
    app.trash.bounds = .{};
    tick(&app, 1000);
    try t.expectEqual(@as(i64, 1000), app.trash.last_prune_ms);
    tick(&app, 2000);
    try t.expectEqual(@as(i64, 1000), app.trash.last_prune_ms);
    tick(&app, 1000 + prune_every_ms);
    try t.expectEqual(@as(i64, 1000 + prune_every_ms), app.trash.last_prune_ms);
}

test "a trash delete the trash cannot take is not removed: the box asks again, naming why" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "a" });
    const a = try std.fs.path.join(t.allocator, &.{ env.root, "a.txt" });
    defer t.allocator.free(a);
    // A file where the trash directory should be: every move into it fails.
    const td = try dir(&app, app.frame.allocator());
    if (std.fs.path.dirname(td)) |parent| try Io.Dir.cwd().createDirPath(t.io, parent);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = td, .data = "not a directory" });
    try confirmDelete(&app, &.{a});
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(exists(&app, a));
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.message, "a.txt was not deleted — the trash could not take it") != null);
    // Cancel is the default; Enter keeps the file.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(exists(&app, a));
    try deletePaths(&app, &.{a}, false);
    try app.handle(.{ .key = Key.char('p') });
    try t.expect(!exists(&app, a));
}

test "the confirm: Cancel is the default (Rust's), d trashes with a toast, p skips the trash; inside the trash only the permanent form is offered" {
    var env = try Env.init();
    defer env.deinit();
    var app = try env.app();
    defer app.deinit();
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "a" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/b.txt", .data = "b" });
    const a = try std.fs.path.join(t.allocator, &.{ env.root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ env.root, "b.txt" });
    defer t.allocator.free(b);
    try confirmDelete(&app, &.{a});
    try t.expect(app.overlay == .confirm);
    try t.expectEqual(@as(usize, 2), app.overlay.confirm.state.selected);
    try t.expectEqual(@as(usize, 3), app.overlay.confirm.state.choices.len);
    try t.expectEqualStrings("Delete a.txt?", app.overlay.confirm.state.message);
    // Esc is the silent way out; `d` trashes and says so.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(exists(&app, a));
    // Enter lands on Cancel — and SAYS so. A box that tore down with
    // nothing said read on screen exactly like a delete that worked,
    // and Enter is the likeliest key on any dialog.
    try confirmDelete(&app, &.{a});
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(exists(&app, a));
    try t.expectEqualStrings("cancelled — a.txt kept; `d` deletes, `p` permanently", app.lastToast().?);
    try confirmDelete(&app, &.{a});
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(!exists(&app, a));
    try t.expectEqual(@as(usize, 1), count(&app));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "deleted a.txt") != null);
    try confirmDelete(&app, &.{b});
    try app.handle(.{ .key = Key.char('p') });
    try t.expect(!exists(&app, b));
    try t.expectEqual(@as(usize, 1), count(&app));
    // Inside the trash: two choices, the question says permanent.
    const td = try dir(&app, app.frame.allocator());
    var d = try Io.Dir.cwd().openDir(t.io, td, .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    const e = (try it.next(t.io)).?;
    const entry_abs = try std.fs.path.join(t.allocator, &.{ td, e.name });
    defer t.allocator.free(entry_abs);
    try confirmDelete(&app, &.{entry_abs});
    try t.expectEqual(@as(usize, 2), app.overlay.confirm.state.choices.len);
    try t.expectEqualStrings("Delete", app.overlay.confirm.state.title);
    try t.expect(std.mem.endsWith(u8, app.overlay.confirm.state.message, "(permanent — already in the trash)"));
    try t.expectEqual(@as(usize, 1), app.overlay.confirm.state.selected);
    try app.handle(.{ .key = Key.named(.left) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(@as(usize, 0), count(&app));
}

const Key = app_mod.Key;
