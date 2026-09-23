//! Named layouts — a tab page written down under a name and put back on
//! demand: `:layout save|load|delete|list <name>`, the `layout.save` /
//! `layout.load` / `layout.delete` prompts, the `layout.pick` picker,
//! View → Layouts and which-key `space W`.
//!
//! A layout is ONE tab page: its split tree (ratios included), which
//! pane is focused, its zoom, and for every pane its KIND and what would
//! reopen it — a file's path, a terminal's cwd and command line, an AI
//! session's CLI and id, an `.http` file's block, a browser's URL, a
//! git view's repo, a search's query. It is the session's own shape
//! (`session.Pane` / `session.Tab`, `session.capturePane` /
//! `openSavedWith` / `buildLayout`), so every kind the session can bring
//! back, a layout can too — plus the request and browser panes the
//! session leaves out (`CaptureOpts.extra_kinds`).
//!
//! The files live per workspace at `.mnml/layouts/<name>.zon`, with the
//! paths under the workspace written relative to it: a layout can be
//! committed and used from another clone. That is also why loading one
//! is a trust question. A terminal with a command line, and an AI
//! session, run a program — so on load they are refused with a toast
//! unless the workspace is trusted (`App.workspace_trusted`, the same
//! decision that gates `.startup.layout`'s pty entries, docs/CONFIG.md
//! "Workspace trust") or the file is one this mnml wrote: `save`
//! records a fingerprint of the file's command lines in
//! `<data root>/written_layouts.zon`, and a file whose commands still
//! match it is the user's own. A plain shell runs nothing the file
//! chose and is never refused.
//!
//! Loading replaces the current tab page. Its panes that no other page
//! shows close — the clean ones; a pane with unsaved changes asks first
//! (the confirm box), and on Load stays open as a background tab of the
//! new page, never lost. `tab.reopen` brings the replaced page's files
//! back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Layout = app_mod.Layout;
const Confirm = app_mod.Confirm;
const Prompt = app_mod.Prompt;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const session = @import("session.zig");
const config = @import("../config/root.zig");
const cmd_picker = @import("cmd_picker.zig");
const cmd_tab = @import("cmd_tab.zig");
const workspace_trust = @import("workspace_trust.zig");

pub const table = .{
    .@"layout.save" = &saveCmd,
    .@"layout.load" = &loadCmd,
    .@"layout.delete" = &deleteCmd,
    .@"layout.pick" = &pickCmd,
};

pub const rel_dir = ".mnml/layouts";
pub const format_version: u32 = 1;
/// `<data root>/written_layouts.zon`: `.@"<layout file>" = "<fingerprint>"`,
/// one line per layout this mnml saved (`config/trusted.zig`'s store).
pub const written_store = "written_layouts.zon";
/// The longest name `validName` takes.
pub const max_name = 64;

/// The file: one tab page in the session's shape. `panes` is what the
/// tree's leaves index; `active` is the focused pane, an index too.
pub const File = struct {
    version: u32 = format_version,
    panes: []const session.Pane = &.{},
    tab: session.Tab = .{},
    active: ?u32 = null,
};

// ─── names and paths ─────────────────────────────────────────────────────

/// A name is a file name and nothing else: letters, digits, `-`, `_`
/// and `.`, not starting with a dot, at most `max_name` bytes.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name or name[0] == '.') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

fn needName(app: *App, raw: []const u8) CommandError![]const u8 {
    const name = std.mem.trim(u8, raw, " \t");
    if (name.len == 0) return app.diag.fail(app.frame.allocator(), "layout: name it — `:layout save <name>`", .{});
    if (std.mem.endsWith(u8, name, ".zon") and validName(name[0 .. name.len - 4])) return name[0 .. name.len - 4];
    if (!validName(name)) return app.diag.fail(app.frame.allocator(), "layout: \"{s}\" is not a name — letters, digits, - _ and . (not first), {d} at most", .{ name, max_name });
    return name;
}

/// `<workspace>/.mnml/layouts/<name>.zon` on `arena`.
pub fn filePath(app: *const App, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.zon", .{name});
    return std.fs.path.join(arena, &.{ app.workspace, rel_dir, file });
}

/// The saved names, sorted, on `arena`. A missing directory is none.
pub fn list(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    const dir_path = try std.fs.path.join(arena, &.{ app.workspace, rel_dir });
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(app.io);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        if (!validName(stem)) continue;
        try out.append(arena, try arena.dupe(u8, stem));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ─── portable paths ──────────────────────────────────────────────────────

/// `path` relative to the workspace when it is under it (`.` for the
/// workspace itself), else as it is.
fn portable(app: *const App, path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, app.workspace)) return ".";
    return app.relPath(path);
}

/// The inverse of `portable`, on `arena`.
fn resolved(app: *const App, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return path;
    if (std.mem.eql(u8, path, ".")) return app.workspace;
    return std.fs.path.join(arena, &.{ app.workspace, path });
}

/// Which fields of a saved pane are workspace paths. A diff's `path` is
/// its repo's, and a grep has none.
fn hasWorkspacePath(kind: session.PaneKind) bool {
    return switch (kind) {
        .editor, .md_preview, .image, .request => true,
        .pty, .git_status, .grep, .git_graph, .diff, .browser, .mount => false,
    };
}

fn makePortable(app: *const App, sp: *session.Pane) void {
    if (hasWorkspacePath(sp.kind)) sp.path = portable(app, sp.path);
    if (sp.cwd) |c| sp.cwd = portable(app, c);
    if (sp.repo) |r| sp.repo = portable(app, r);
}

fn makeResolved(app: *const App, arena: Allocator, sp: *session.Pane) Allocator.Error!void {
    if (hasWorkspacePath(sp.kind)) sp.path = try resolved(app, arena, sp.path);
    if (sp.cwd) |c| sp.cwd = try resolved(app, arena, c);
    if (sp.repo) |r| sp.repo = try resolved(app, arena, r);
}

// ─── trust ───────────────────────────────────────────────────────────────

/// A pane that runs a program the file names: a terminal with a command
/// line, which is every AI session too. A plain shell (no argv) runs
/// the user's own `$SHELL` and is not. An integration pane (`mount`)
/// is too: its binary comes from today's manifest, but the arguments it
/// is started with are the file's.
pub fn execBearing(sp: session.Pane) bool {
    return (sp.kind == .pty or sp.kind == .mount) and sp.argv.len > 0;
}

/// FNV-1a over the file's command lines and their cwds, in pane order —
/// what `save` records and `load` compares. A file with no command line
/// fingerprints to the empty hash and needs no record.
pub fn fingerprint(file: File) u64 {
    var h = std.hash.Fnv1a_64.init();
    for (file.panes) |sp| {
        if (!execBearing(sp)) continue;
        for (sp.argv) |a| {
            h.update(a);
            h.update("\x1f");
        }
        h.update("\x1e");
        h.update(sp.cwd orelse "");
        h.update("\n");
    }
    return h.final();
}

fn storePath(app: *const App, arena: Allocator) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ app.data_root, written_store });
}

/// Whether `file` (read from `abs`) may start its command lines: the
/// workspace is trusted, or this mnml wrote the file and its commands
/// are still the ones it wrote.
fn mayRun(app: *App, abs: []const u8, file: File) Allocator.Error!bool {
    if (app.workspace_trusted) return true;
    const store = try storePath(app, app.frame.allocator());
    const recorded = (try config.trusted.lookup(app.gpa, app.io, store, abs)) orelse return false;
    return recorded == fingerprint(file);
}

// ─── save ────────────────────────────────────────────────────────────────

/// The current tab page as a `File` on `arena`, or null when the page
/// holds nothing that can come back.
pub fn capture(app: *App, arena: Allocator) Allocator.Error!?File {
    const layout = app.layouts.current();
    if (layout.isEmpty()) return null;
    const slot_count = app.panes.slots.items.len;
    const index_of = try arena.alloc(?u32, slot_count);
    @memset(index_of, null);
    var panes: std.ArrayListUnmanaged(session.Pane) = .empty;
    for (try layout.allPanes(arena)) |id| {
        if (id >= slot_count or index_of[id] != null) continue;
        const p = app.panes.get(id) orelse continue;
        var sp = (try session.capturePane(app, arena, id, p, .{ .extra_kinds = true })) orelse continue;
        makePortable(app, &sp);
        index_of[id] = @intCast(panes.items.len);
        try panes.append(arena, sp);
    }
    if (panes.items.len == 0) return null;
    const active: ?u32 = if (app.active) |a| (if (a < slot_count) index_of[a] else null) else null;
    return .{ .panes = panes.items, .tab = try session.captureLayout(arena, layout, index_of), .active = active };
}

pub fn render(arena: Allocator, file: File) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml layout — one tab page; `:layout load <name>` puts it back.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(file, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

pub fn parse(arena: Allocator, src: [:0]const u8) error{ OutOfMemory, ParseZon }!File {
    @setEvalBranchQuota(8000);
    return std.zon.parse.fromSliceAlloc(File, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
}

pub fn save(app: *App, raw_name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const name = try needName(app, raw_name);
    const file = (try capture(app, arena)) orelse return app.diag.fail(arena, "layout: nothing on this tab page can be saved — scratch buffers and lists do not come back", .{});
    const text = try render(arena, file);
    const abs = try filePath(app, arena, name);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, std.fs.path.dirname(abs).?) catch |err| return app.diag.fail(arena, "layout: cannot create {s}: {s}", .{ rel_dir, @errorName(err) });
    cwd.writeFile(app.io, .{ .sub_path = abs, .data = text }) catch |err| return app.diag.fail(arena, "layout: cannot write {s}: {s}", .{ app.relPath(abs), @errorName(err) });
    // The file's command lines are this mnml's own from here on.
    var runs: usize = 0;
    for (file.panes) |sp| if (execBearing(sp)) {
        runs += 1;
    };
    if (runs > 0) config.trusted.remember(app.gpa, app.io, try storePath(app, arena), abs, fingerprint(file)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try app.toastLevel(.warn, "layout {s}: saved, but {s} could not record it — its terminals will ask for trust on load: {s}", .{ name, written_store, @errorName(err) }),
    };
    const leaves = (try app.layouts.current().leaves(arena)).len;
    app.toast("layout {s} saved · {d} pane{s}, {d} split{s}", .{ name, file.panes.len, plural(file.panes.len), leaves, plural(leaves) });
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// ─── load ────────────────────────────────────────────────────────────────

pub const load_choices = [_]Confirm.Choice{ .{ .key = 'l', .label = "Load" }, .{ .key = 'c', .label = "Cancel" } };

/// Read and parse `name`'s file onto `arena`; the reason goes in
/// `app.diag` when it cannot be used.
fn read(app: *App, arena: Allocator, name: []const u8) CommandError!File {
    const abs = try filePath(app, arena, name);
    const src = Io.Dir.cwd().readFileAllocOptions(app.io, abs, arena, .limited(8 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return app.diag.fail(arena, "layout: no layout named {s} — `:layout list` has the saved ones", .{name}),
        else => return app.diag.fail(arena, "layout: cannot read {s}: {s}", .{ app.relPath(abs), @errorName(err) }),
    };
    const file = parse(arena, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return app.diag.fail(arena, "layout: {s} does not parse — not loaded", .{app.relPath(abs)}),
    };
    if (file.version != format_version) return app.diag.fail(arena, "layout: {s} is format v{d}, this build reads v{d} — not loaded", .{ app.relPath(abs), file.version, format_version });
    return file;
}

/// The panes on the page a load replaces that would lose their unsaved
/// changes from view: dirty, shown on no other page, and not a file the
/// layout itself reopens.
fn dirtyOnPage(app: *App, arena: Allocator, file: File) Allocator.Error![]const u8 {
    const page = app.layouts.current();
    var names: std.ArrayListUnmanaged(u8) = .empty;
    for (try page.allPanes(arena)) |id| {
        const p = app.panes.get(id) orelse continue;
        if (!p.dirty() or shownElsewhere(app, page, id)) continue;
        if (p.asEditor()) |e| if (e.buf.doc.path) |path| {
            const rel = portable(app, path);
            const reopened = for (file.panes) |sp| {
                if (sp.kind == .editor and std.mem.eql(u8, sp.path, rel)) break true;
            } else false;
            if (reopened) continue;
        };
        if (names.items.len > 0) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, p.title());
    }
    return names.items;
}

fn shownElsewhere(app: *App, page: *const Layout, id: PaneId) bool {
    for (app.layouts.layouts.items) |*l| {
        if (l == page) continue;
        if (l.leafOf(id) != null) return true;
    }
    return false;
}

/// Load `name` over the current tab page. `force` skips the unsaved-
/// changes question (the confirm box's Load, or `:layout load!`).
pub fn load(app: *App, raw_name: []const u8, force: bool) CommandError!void {
    const arena = app.frame.allocator();
    const name = try needName(app, raw_name);
    const file = try read(app, arena, name);
    if (!force) {
        const dirty = try dirtyOnPage(app, arena, file);
        if (dirty.len > 0) return askLoad(app, name, dirty);
    }
    const abs = try filePath(app, arena, name);
    const may_run = try mayRun(app, abs, file);

    // Every pane, back into the store — refused ones are null and are
    // swept out of the tree like a file that went away.
    const ids = try arena.alloc(?PaneId, file.panes.len);
    var refused: usize = 0;
    var missing: usize = 0;
    for (file.panes, 0..) |sp_in, i| {
        var sp = sp_in;
        if (execBearing(sp) and !may_run) {
            ids[i] = null;
            refused += 1;
            continue;
        }
        try makeResolved(app, arena, &sp);
        ids[i] = session.openSavedWith(app, sp, ids[0..i], .{ .run_commands = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (ids[i] == null) missing += 1;
    }
    var fresh = try session.buildLayout(app.gpa, file.tab, ids);
    if (fresh.isEmpty()) {
        fresh.deinit();
        // Whatever did open lands where the openers put it: nothing is
        // closed, and the page stays.
        if (refused > 0) try toastRefused(app, name, refused);
        return app.diag.fail(arena, "layout: nothing in {s} could be reopened — the page is left as it was", .{name});
    }

    // The swap: the page's slot takes the new tree, and the old one is
    // retired like a closed tab page (its clean panes close, its dirty
    // ones become background tabs here, `tab.reopen` has its files).
    const ls = &app.layouts;
    app.setActive(null);
    var gone = ls.layouts.items[ls.active];
    ls.layouts.items[ls.active] = fresh;
    defer gone.deinit();
    try cmd_tab.retirePage(app, &gone, ls.current());
    const page = ls.current();
    const want: ?PaneId = if (file.active) |a| (if (a < ids.len) ids[a] else null) else null;
    app.setActive(if (want) |w| (if (page.leafOf(w) != null) w else page.landing()) else page.landing());
    app.needs_render = true;

    const opened = file.panes.len - refused - missing;
    if (refused > 0) try toastRefused(app, name, refused);
    if (missing > 0) {
        app.toast("layout {s} loaded · {d} pane{s} ({d} could not be reopened)", .{ name, opened, plural(opened), missing });
    } else app.toast("layout {s} loaded · {d} pane{s}", .{ name, opened, plural(opened) });
}

fn toastRefused(app: *App, name: []const u8, n: usize) Allocator.Error!void {
    try app.toastLevel(.warn, "layout {s}: {d} terminal{s} not started — this workspace is not trusted and the file's commands are not ones this mnml saved (workspace.review_trust)", .{ name, n, plural(n) });
}

fn askLoad(app: *App, name: []const u8, dirty: []const u8) CommandError!void {
    const gpa = app.gpa;
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const msg = try std.fmt.allocPrint(gpa, "Layout {s} replaces this tab page. Unsaved: {s}\nThey stay open as background tabs of the new page.", .{ name, dirty });
    errdefer gpa.free(msg);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Load layout?", .message = msg, .choices = &load_choices, .selected = load_choices.len - 1 },
        .purpose = .{ .layout_load = owned_name },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The confirm box's answer: index 0 is Load.
pub fn answerLoad(app: *App, name: []const u8, choice: usize) Allocator.Error!void {
    if (choice != 0) {
        app.toast("layout {s}: not loaded — the page is kept", .{name});
        return;
    }
    const owned = try app.frame.allocator().dupe(u8, name);
    toastOnFail(app, load(app, owned, true)) catch |err| return err;
}

fn toastOnFail(app: *App, result: CommandError!void) Allocator.Error!void {
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{command.reason(err)}),
    };
}

// ─── delete ──────────────────────────────────────────────────────────────

pub fn delete(app: *App, raw_name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const name = try needName(app, raw_name);
    const abs = try filePath(app, arena, name);
    Io.Dir.cwd().deleteFile(app.io, abs) catch |err| switch (err) {
        error.FileNotFound => return app.diag.fail(arena, "layout: no layout named {s}", .{name}),
        else => return app.diag.fail(arena, "layout: cannot delete {s}: {s}", .{ app.relPath(abs), @errorName(err) }),
    };
    // A later file under the same name is not the one this mnml wrote.
    _ = workspace_trust.removeEntry(app.gpa, app.io, try storePath(app, arena), abs) catch {};
    app.toast("layout {s} deleted", .{name});
}

// ─── the `:` line ────────────────────────────────────────────────────────

/// `:layout save|load|delete|list [name]`; `:layout load! <name>` skips
/// the unsaved-changes question; a bare `:layout` lists.
pub fn ex(app: *App, args: []const u8) CommandError!void {
    const verb, const rest = splitWord(args);
    if (verb.len == 0 or std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "ls")) return listCmd(app);
    if (std.mem.eql(u8, verb, "save")) return save(app, rest);
    if (std.mem.eql(u8, verb, "load")) return load(app, rest, false);
    if (std.mem.eql(u8, verb, "load!")) return load(app, rest, true);
    if (std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "del") or std.mem.eql(u8, verb, "rm")) return delete(app, rest);
    return app.diag.fail(app.frame.allocator(), ":layout {s}? — save | load | delete | list <name>", .{verb});
}

fn splitWord(s_in: []const u8) struct { []const u8, []const u8 } {
    const s = std.mem.trim(u8, s_in, " \t");
    const i = std.mem.indexOfAny(u8, s, " \t") orelse return .{ s, "" };
    return .{ s[0..i], std.mem.trim(u8, s[i..], " \t") };
}

fn listCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const names = try list(app, arena);
    if (names.len == 0) {
        app.toast("no saved layouts — `:layout save <name>` saves this tab page", .{});
        return;
    }
    const joined = try std.mem.join(arena, ", ", names);
    app.toast("layouts ({d}): {s}", .{ names.len, joined });
}

// ─── the commands: the prompt and the picker ─────────────────────────────

fn openPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, title), .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn saveCmd(app: *App) CommandError!void {
    openPrompt(app, "Save this tab page as layout", .layout_save);
}

fn loadCmd(app: *App) CommandError!void {
    openPrompt(app, "Load layout (replaces this tab page)", .layout_load);
}

fn deleteCmd(app: *App) CommandError!void {
    openPrompt(app, "Delete layout", .layout_delete);
}

/// `layout.pick`: a picker over the saved names, each with what it
/// holds; the pick loads.
fn pickCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    const names = try list(app, arena);
    if (names.len == 0) return app.diag.fail(arena, "no saved layouts — `:layout save <name>` (or layout.save) saves this tab page", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (names) |n| {
        const label = try gpa.dupe(u8, n);
        errdefer gpa.free(label);
        const detail = try describe(app, arena, n);
        const owned_detail = try gpa.dupe(u8, detail);
        errdefer gpa.free(owned_detail);
        try labels.append(gpa, label);
        try details.append(gpa, owned_detail);
    }
    const labels_owned = try labels.toOwnedSlice(gpa);
    const details_owned = try details.toOwnedSlice(gpa);
    try cmd_picker.openPickerWith(app, "Load layout", .custom, labels_owned, try gpa.alloc(PaneId, 0), details_owned, &.{});
    app.overlay.picker.on_accept = &acceptPick;
}

/// The picker row's detail: `3 panes · 2 splits · a.txt, b.txt` — or why
/// the file cannot be used.
fn describe(app: *App, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const file = read(app, arena, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.msg orelse "cannot be read",
    };
    var leaves: usize = 0;
    for (file.tab.nodes) |n| if (n == .leaf) {
        leaves += 1;
    };
    var what: std.ArrayListUnmanaged(u8) = .empty;
    try what.print(arena, "{d} pane{s} · {d} split{s}", .{ file.panes.len, plural(file.panes.len), leaves, plural(leaves) });
    if (file.tab.zoomed != null) try what.appendSlice(arena, " · zoomed");
    var shown: usize = 0;
    for (file.panes) |sp| {
        const label: []const u8 = switch (sp.kind) {
            .editor, .md_preview, .image, .request => std.fs.path.basename(sp.path),
            .pty => if (sp.argv.len > 0) std.fs.path.basename(sp.argv[0]) else "shell",
            .browser => sp.url orelse "browser",
            .grep => sp.query orelse "search",
            .git_status => "git status",
            .git_graph => "git graph",
            .diff => "diff",
            .mount => sp.label orelse sp.integration orelse "integration",
        };
        try what.appendSlice(arena, if (shown == 0) " · " else ", ");
        try what.appendSlice(arena, label);
        shown += 1;
        if (shown == 4 and file.panes.len > 4) {
            try what.print(arena, " +{d}", .{file.panes.len - 4});
            break;
        }
    }
    return what.items;
}

fn acceptPick(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    try toastOnFail(app, load(app, label, false));
}

/// The prompts' answers (`dispatch.acceptPrompt`).
pub fn acceptSave(app: *App, text: []const u8) Allocator.Error!void {
    try toastOnFail(app, save(app, text));
}

pub fn acceptLoad(app: *App, text: []const u8) Allocator.Error!void {
    try toastOnFail(app, load(app, text, false));
}

pub fn acceptDelete(app: *App, text: []const u8) Allocator.Error!void {
    try toastOnFail(app, delete(app, text));
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const builtin = @import("builtin");
const pty_pane = @import("pty_pane.zig");
const git_app = @import("git.zig");
const grep = @import("grep.zig");
const image_pane = @import("image_pane.zig");
const md_preview = @import("md_preview.zig");
const http_app = @import("http.zig");
const browser_pane = @import("browser_pane.zig");

/// A real workspace in a temp dir, with its own data root under it so
/// nothing reaches the user's config or the written-layouts store.
const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    data: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &pbuf);
        const root = try t.allocator.dupe(u8, pbuf[0..n]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "data");
        return .{ .tmp = tmp, .root = root, .data = try std.fs.path.join(t.allocator, &.{ root, "data" }) };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.data);
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn app(f: *Fixture, trusted: bool) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = f.root, .data_root = f.data, .cols = 160, .rows = 48, .workspace_trusted = trusted });
    }

    fn abs(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }

    fn sh(f: *Fixture, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(t.allocator, args);
        const res = try std.process.run(t.allocator, t.io, .{ .argv = argv.items, .cwd = .{ .path = f.root } });
        defer t.allocator.free(res.stdout);
        defer t.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.GitFailed;
    }

    fn read(f: *Fixture, rel: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(t.io, rel, t.allocator, .limited(1 << 20));
    }
};

/// The first pane of `kind` whose `ok` accepts it.
fn find(app: *App, comptime kind: std.meta.Tag(app_mod.Pane)) ?PaneId {
    return app.panes.findKind(kind);
}

fn ptyWith(app: *App, first_arg: ?[]const u8) ?*pty_pane.PtyPane {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| {
            if (first_arg) |want| {
                if (pt.argv.len > 0 and std.mem.eql(u8, pt.argv[0], want)) return pt;
            } else if (pt.argv.len == 0) return pt;
        },
        else => {},
    };
    return null;
}

fn toasted(app: *App, text: []const u8) bool {
    for (app.toasts.items) |tt| if (std.mem.indexOf(u8, tt.text, text) != null) return true;
    return false;
}

test "named layouts: names are file names; save / list / delete through the `:` line; an unknown verb and a missing name say so" {
    var f = try Fixture.init();
    defer f.deinit();
    try t.expect(validName("dev"));
    try t.expect(validName("review-2.split_3"));
    try t.expect(!validName(""));
    try t.expect(!validName(".hidden"));
    try t.expect(!validName("a/b"));
    try t.expect(!validName("../up"));
    try t.expect(!validName("with space"));
    try t.expect(!validName("x" ** (max_name + 1)));
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    var app = try f.app(false);
    defer app.deinit();
    // Nothing that can come back: a scratch page is refused out loud.
    _ = try app.openScratch();
    try t.expectError(error.Failed, ex(&app, "save scratch"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "nothing on this tab page") != null);
    _ = try app.openPath(a);
    try ex(&app, "save dev");
    try ex(&app, "save dev.zon"); // the extension is the name's
    try ex(&app, "save b");
    const names = try list(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 2), names.len);
    try t.expectEqualStrings("b", names[0]);
    try t.expectEqualStrings("dev", names[1]);
    try ex(&app, "list");
    try t.expect(toasted(&app, "layouts (2): b, dev"));
    try t.expectError(error.Failed, ex(&app, "save ../evil"));
    try t.expectError(error.Failed, ex(&app, "save"));
    try t.expectError(error.Failed, ex(&app, "frobnicate x"));
    try ex(&app, "delete b");
    try t.expectEqual(@as(usize, 1), (try list(&app, app.frame.allocator())).len);
    try t.expectError(error.Failed, ex(&app, "delete b"));
    try t.expectError(error.Failed, ex(&app, "load nope"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "no layout named nope") != null);
    // A file with no command line records nothing in the store.
    try t.expectError(error.FileNotFound, f.tmp.dir.access(t.io, "data/" ++ written_store, .{}));
}

test "named layouts: save → load round-trips every pane kind — editor, preview, image, request, git status / graph / diff, search, shell, command, AI session — with the split tree, the ratios, the focus and the zoom" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(t.io, "sub");
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle two\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "# notes\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "shot.png", .data = "\x89PNG\r\n\x1a\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "api.http", .data = "### first\nGET http://127.0.0.1:9/a\n\n###\nGET http://127.0.0.1:9/b\n\n###\nGET http://127.0.0.1:9/c\n" });
    // A fake `claude`: the basename names the product; the real CLI never runs.
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/claude", .data = "#!/bin/sh\nsleep 30\n" });
    try f.tmp.dir.setFilePermissions(t.io, "bin/claude", .fromMode(0o755), .{});
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.sh(&.{ "add", "." });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle two\nneedle again\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    const md = try f.abs("notes.md");
    defer t.allocator.free(md);
    const png = try f.abs("shot.png");
    defer t.allocator.free(png);
    const http_file = try f.abs("api.http");
    defer t.allocator.free(http_file);
    const sub = try f.abs("sub");
    defer t.allocator.free(sub);
    const fake = try f.abs("bin/claude");
    defer t.allocator.free(fake);

    var leaves_before: usize = 0;
    var ratios_before: [16]u16 = undefined;
    var nratios: usize = 0;
    {
        var app = try f.app(false);
        defer app.deinit();
        const ida = try app.openPath(a);
        app.panes.editor(ida).?.buf.editor.setCursor(4);
        _ = try md_preview.open(&app, md, .here, null);
        const repo = (try git_app.repoByPath(&app, f.root)).?;
        _ = try git_app.openStatusPane(&app, repo);
        app.showPane(try git_app.ensureGraphPane(&app, repo));
        _ = try git_app.openDiff(&app, repo, .worktree, null, null, null);
        app.showPane((try grep.restorePane(&app, "needle", .{}, 0)).?);
        const iid = try image_pane.open(&app, png);
        app.panes.get(iid).?.image.is_preview = false;
        // The second of two bare `###` blocks: only its position tells it apart.
        const rid = try http_app.openFileBlock(&app, http_file, 2);
        _ = try pty_pane.open(&app, .{ .argv = &.{}, .cwd = sub, .label = "sh", .kind = .shell, .placement = .right });
        _ = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sleeper", .kind = .command, .placement = .below });
        _ = try pty_pane.open(&app, .{ .argv = &.{ fake, "--session-id", "sid-7" }, .label = "claude", .kind = .command, .placement = .tab });
        // Drag a divider off centre and zoom the request pane's split.
        const layout = app.layouts.current();
        for (layout.nodes.items, 0..) |n, i| if (n == .split) layout.setRatio(@intCast(i), 37);
        app.setActive(rid);
        try command.run(&app, .{ .static = .@"view.toggle_zoom" });
        leaves_before = (try layout.leaves(app.frame.allocator())).len;
        for (layout.nodes.items) |n| if (n == .split) {
            ratios_before[nratios] = n.split.ratio;
            nratios += 1;
        };
        try ex(&app, "save all");
    }
    const text = try f.read(rel_dir ++ "/all.zon");
    defer t.allocator.free(text);
    // Workspace paths are written relative, so the file travels; a
    // command line is the command line, whatever it names.
    const abs_a = try std.fmt.allocPrint(t.allocator, "\"{s}\"", .{a});
    defer t.allocator.free(abs_a);
    try t.expect(std.mem.indexOf(u8, text, abs_a) == null);
    try t.expect(std.mem.indexOf(u8, text, ".path = \"a.txt\"") != null);
    try t.expect(std.mem.indexOf(u8, text, ".cwd = \"sub\"") != null);
    try t.expect(std.mem.indexOf(u8, text, ".repo = \".\"") != null);
    // (`.editor` is the default kind, so the file leaves it out.)
    for ([_][]const u8{ ".md_preview", ".image", ".request", ".git_status", ".git_graph", ".diff", ".grep", ".pty" }) |k| {
        if (std.mem.indexOf(u8, text, k) == null) std.debug.print("missing kind {s}\n", .{k});
        try t.expect(std.mem.indexOf(u8, text, k) != null);
    }
    try t.expect(std.mem.indexOf(u8, text, ".block_index = 2") != null);
    try t.expect(std.mem.indexOf(u8, text, "sid-7") != null);
    try t.expect(std.mem.indexOf(u8, text, ".zoomed") != null);
    // The file holds command lines, so this mnml recorded them.
    const store = try f.read("data/" ++ written_store);
    defer t.allocator.free(store);
    try t.expect(std.mem.indexOf(u8, store, "all.zon") != null);
    {
        // A fresh app, NOT trusted: the file is this mnml's own, so its
        // terminals start anyway.
        var app = try f.app(false);
        defer app.deinit();
        _ = try app.openScratch();
        try ex(&app, "load all");
        try t.expect(toasted(&app, "layout all loaded"));
        const layout = app.layouts.current();
        try t.expectEqual(leaves_before, (try layout.leaves(app.frame.allocator())).len);
        var got: [16]u16 = undefined;
        var ng: usize = 0;
        for (layout.nodes.items) |n| if (n == .split) {
            got[ng] = n.split.ratio;
            ng += 1;
        };
        try t.expectEqualSlices(u16, ratios_before[0..nratios], got[0..ng]);
        // The scratch page it replaced is gone with its scratch.
        try t.expectEqual(@as(usize, 1), app.layouts.layouts.items.len);
        const e = app.panes.editor(app.panes.findPath(a).?).?;
        try t.expectEqual(@as(usize, 4), e.buf.editor.cursor);
        try t.expect(app.panes.findPreview(md) != null);
        try t.expectEqualStrings(png, app.panes.get(find(&app, .image).?).?.image.path);
        const rp = app.panes.get(find(&app, .request).?).?.asRequest().?;
        try t.expectEqualStrings(http_file, rp.source_path.?);
        try t.expectEqualStrings("", rp.block_name.?);
        try t.expectEqual(@as(?u32, 2), rp.block_index);
        try t.expectEqualStrings(f.root, app.git.repoById(app.panes.get(find(&app, .git_status).?).?.git_status.repo).?.path);
        try t.expect(find(&app, .git_graph) != null);
        try t.expect(find(&app, .diff) != null);
        try t.expectEqualStrings("needle", app.panes.get(find(&app, .grep).?).?.grep.query);
        const shell = ptyWith(&app, null).?;
        try t.expectEqualStrings(sub, shell.cwd.?);
        try t.expect(!shell.dormant);
        // A command line comes back RUNNING — a layout is loaded on
        // purpose — and the AI session resumes its id.
        const sleeper = ptyWith(&app, "/bin/sh").?;
        try t.expect(!sleeper.dormant);
        const claude = ptyWith(&app, fake).?;
        try t.expect(!claude.dormant);
        try t.expectEqualStrings("--resume", claude.argv[1]);
        try t.expectEqualStrings("sid-7", claude.argv[2]);
        // Focus and zoom: the request pane, zoomed.
        try t.expectEqual(find(&app, .request).?, app.active.?);
        try t.expectEqual(find(&app, .request).?, app.zoomedPane().?);
        for (try layout.allPanes(app.frame.allocator())) |id| try t.expect(app.panes.get(id) != null);
    }
}

test "named layouts: a terminal command or an AI session from a file this mnml did not write is refused in an untrusted workspace — with a toast; the rest opens; trust or a re-save lets it run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    // A layout shipped in the repo: an editor, a plain shell, a command
    // that would leave a mark, and a split between them.
    try f.tmp.dir.createDirPath(t.io, rel_dir);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_dir ++ "/shipped.zon", .data =
        \\.{
        \\    .panes = .{
        \\        .{ .path = "a.txt" },
        \\        .{ .kind = .pty },
        \\        .{ .kind = .pty, .argv = .{ "/bin/sh", "-c", "echo pwned > pwned.txt; sleep 30" } },
        \\    },
        \\    .tab = .{
        \\        .nodes = .{
        \\            .{ .split = .{ .dir = .horizontal, .ratio = 50, .first = 1, .second = 2 } },
        \\            .{ .leaf = .{ .active = 0, .tabs = .{0} } },
        \\            .{ .split = .{ .dir = .vertical, .ratio = 50, .first = 3, .second = 4 } },
        \\            .{ .leaf = .{ .active = 1, .tabs = .{1} } },
        \\            .{ .leaf = .{ .active = 2, .tabs = .{2} } },
        \\        },
        \\        .root = 0,
        \\    },
        \\    .active = 0,
        \\}
        \\
    });
    {
        var app = try f.app(false);
        defer app.deinit();
        try ex(&app, "load shipped");
        // Refused, out loud; the editor and the shell are there.
        try t.expect(toasted(&app, "1 terminal not started"));
        try t.expect(ptyWith(&app, "/bin/sh") == null);
        try t.expect(ptyWith(&app, null) != null);
        const a = try f.abs("a.txt");
        defer t.allocator.free(a);
        try t.expect(app.panes.findPath(a) != null);
        try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
        t.io.sleep(.fromMilliseconds(200), .awake) catch {};
        try t.expectError(error.FileNotFound, f.tmp.dir.access(t.io, "pwned.txt", .{}));
    }
    {
        // A trusted workspace runs it.
        var app = try f.app(true);
        defer app.deinit();
        try ex(&app, "load shipped");
        try t.expect(!toasted(&app, "not started"));
        try t.expect(ptyWith(&app, "/bin/sh") != null);
    }
    {
        // Saved by this mnml, then its command edited by hand: the
        // fingerprint no longer matches, so it is someone else's again.
        var app = try f.app(true);
        defer app.deinit();
        try ex(&app, "load shipped");
        try ex(&app, "save mine");
    }
    const mine = try f.read(rel_dir ++ "/mine.zon");
    defer t.allocator.free(mine);
    {
        var app = try f.app(false);
        defer app.deinit();
        try ex(&app, "load mine");
        try t.expect(!toasted(&app, "not started"));
        try t.expect(ptyWith(&app, "/bin/sh") != null);
    }
    const edited = try std.mem.replaceOwned(u8, t.allocator, mine, "sleep 30", "sleep 31");
    defer t.allocator.free(edited);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_dir ++ "/mine.zon", .data = edited });
    {
        var app = try f.app(false);
        defer app.deinit();
        try ex(&app, "load mine");
        try t.expect(toasted(&app, "1 terminal not started"));
        try t.expect(ptyWith(&app, "/bin/sh") == null);
    }
}

test "named layouts: loading over unsaved changes asks through the confirm box; Cancel keeps the page, Load keeps the dirty pane as a background tab" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "bravo\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    const b = try f.abs("b.txt");
    defer t.allocator.free(b);
    var app = try f.app(false);
    defer app.deinit();
    _ = try app.openPath(a);
    try ex(&app, "save justa");
    // Replace the page's content with b.txt, dirty.
    const idb = try app.openPath(b);
    try app.forceClosePane(app.panes.findPath(a).?);
    const eb = app.panes.editor(idb).?;
    _ = try app.applyOps(eb, &.{.{ .insert_str = "x" }});
    try t.expect(eb.buf.doc.dirty);
    try ex(&app, "load justa");
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .layout_load);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "b.txt") != null);
    // Cancel is the focused choice.
    try t.expectEqual(load_choices.len - 1, app.overlay.confirm.state.selected);
    // As `dispatch` answers a box: the overlay goes, then the answer runs.
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try answerLoad(&app, "justa", 1);
    try t.expect(toasted(&app, "not loaded"));
    try t.expect(app.layouts.current().leafOf(idb) != null);
    // Load: a.txt is the page, b.txt is still open, unsaved, as a tab.
    try answerLoad(&app, "justa", 0);
    try t.expect(toasted(&app, "layout justa loaded"));
    const ida = app.panes.findPath(a).?;
    try t.expectEqual(ida, app.active.?);
    try t.expect(app.panes.get(idb) != null);
    try t.expect(app.panes.editor(idb).?.buf.doc.dirty);
    try t.expect(app.layouts.current().leafOf(idb) != null);
    // `:layout load!` skips the question.
    try ex(&app, "load! justa");
    try t.expect(app.overlay != .confirm);
}

test "named layouts: a browser pane rides in the file by URL; with no Chrome the load skips it and says so, the rest opens" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    const file: File = .{
        .panes = &.{ .{ .path = "a.txt" }, .{ .kind = .browser, .url = "http://127.0.0.1:9/page" } },
        .tab = .{ .nodes = &.{
            .{ .split = .{ .dir = .horizontal, .ratio = 60, .first = 1, .second = 2 } },
            .{ .leaf = .{ .active = 0, .tabs = &.{0} } },
            .{ .leaf = .{ .active = 1, .tabs = &.{1} } },
        }, .root = 0 },
        .active = 0,
    };
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const text = try render(arena_state.allocator(), file);
    try t.expect(std.mem.indexOf(u8, text, "http://127.0.0.1:9/page") != null);
    const back = try parse(arena_state.allocator(), try arena_state.allocator().dupeZ(u8, text));
    try t.expectEqual(session.PaneKind.browser, back.panes[1].kind);
    try t.expectEqualStrings("http://127.0.0.1:9/page", back.panes[1].url.?);
    try f.tmp.dir.createDirPath(t.io, rel_dir);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_dir ++ "/web.zon", .data = text });
    browser_pane.test_no_chrome = true;
    defer browser_pane.test_no_chrome = false;
    var app = try f.app(false);
    defer app.deinit();
    try ex(&app, "load web");
    try t.expect(toasted(&app, "1 pane (1 could not be reopened)"));
    try t.expectEqual(@as(usize, 1), (try app.layouts.current().leaves(app.frame.allocator())).len);
}

test "named layouts: layout.save / load / delete prompt through the one prompt, layout.pick lists what each holds and loads the pick" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    var app = try f.app(false);
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"layout.pick" }));
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    _ = try app.openPath(a);
    try command.run(&app, .{ .static = .@"view.split_right" });
    try command.run(&app, .{ .static = .@"layout.save" });
    try t.expect(app.overlay == .prompt);
    try t.expect(app.overlay.prompt.purpose == .layout_save);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try acceptSave(&app, "two");
    try t.expect(toasted(&app, "layout two saved · 2 panes, 2 splits"));
    try command.run(&app, .{ .static = .@"layout.pick" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 1), app.overlay.picker.labels.len);
    try t.expectEqualStrings("two", app.overlay.picker.labels[0]);
    try t.expect(std.mem.indexOf(u8, app.overlay.picker.details[0], "2 panes · 2 splits · a.txt, a.txt") != null);
    try cmd_picker.accept(&app, 0);
    try t.expect(toasted(&app, "layout two loaded · 2 panes"));
    try command.run(&app, .{ .static = .@"layout.load" });
    try t.expect(app.overlay.prompt.purpose == .layout_load);
    try command.run(&app, .{ .static = .@"layout.delete" });
    try t.expect(app.overlay.prompt.purpose == .layout_delete);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try acceptDelete(&app, "two");
    try t.expect(toasted(&app, "layout two deleted"));
}

test "named layouts: an integration pane's arguments are the file's, so it is a trust question like a terminal command" {
    const argv: []const []const u8 = &.{ "/bin/mnml-jira", "--only", "work" };
    try t.expect(execBearing(.{ .kind = .mount, .integration = "jira_work", .argv = argv }));
    try t.expect(!execBearing(.{ .kind = .mount, .integration = "jira_work" }));
    try t.expect(!hasWorkspacePath(.mount));
    // The fingerprint covers it, so a file this mnml wrote still opens.
    const with: File = .{ .panes = &.{.{ .kind = .mount, .integration = "jira_work", .argv = argv }} };
    const without: File = .{ .panes = &.{.{ .kind = .mount, .integration = "jira_work" }} };
    try t.expect(fingerprint(with) != fingerprint(without));
}
