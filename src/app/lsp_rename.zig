//! The rename preview: a `textDocument/rename` reply that touches more
//! than one file opens a confirmation box before anything changes —
//! every file with its hunks (`L12  old → new`), a toggle per file,
//! Enter applies what is ticked, Esc walks away. A single-file rename
//! still applies at once (`lsp.zig`).
//!
//! Applying is one way for every file: a file open in an editor takes
//! its edits through `EditOp` (one undo step, the buffer marked dirty,
//! the server synced on the next frame), and a file that is not open is
//! opened first — in the background, the active pane kept — and takes
//! them the same way. Nothing touches the disk until the user saves, so
//! the rename is never half on disk and half in buffers (a closed file
//! written at once beside an open one left dirty meant `./deploy.sh`
//! failed with `join_by: command not found` until the dot was noticed,
//! and `:q!` on the open buffer left the others renamed for good); one
//! `file.save_all` lands the whole edit, one undo per buffer takes it
//! back. VS Code and Neovim do the same. The box says how many files it
//! will open.
//!
//! The box is `app.lsp` state like the peek overlay, not an `Overlay`
//! variant: its rows register `.overlay_item(row)` while no overlay is
//! up, and `lsp.interceptKey` owns the keys while it shows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const alloc = @import("../core/alloc.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const overlay = @import("../ui/overlay.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../lsp/client.zig");
const types = @import("../lsp/types.zig");
const lsp = @import("lsp.zig");

const Server = client.Server;
const Value = jsonrpc.Value;

pub const File = struct {
    /// Absolute. Arena.
    path: []const u8,
    /// Sorted by position; `new_text` on the arena.
    edits: []types.TextEdit,
    enabled: bool = true,
};

pub const Row = struct {
    file: usize,
    /// null for the file's header row; else the index into its edits.
    edit: ?usize,
    /// The hunk's line as it reads now (arena), for a hunk row.
    before: []const u8 = "",
};

pub const Preview = struct {
    arena: alloc.SnapshotArena,
    server: *Server,
    files: []File,
    rows: []Row,
    cursor: usize = 0,
    scroll: usize = 0,

    fn deinit(self: *Preview) void {
        self.arena.deinit();
    }
};

pub const State = struct {
    preview: ?Preview = null,

    pub fn deinit(self: *State) void {
        if (self.preview) |*p| p.deinit();
        self.preview = null;
    }
};

/// How many files a `WorkspaceEdit` touches.
pub fn fileCount(edit: Value) usize {
    if (jsonrpc.getArr(edit, "documentChanges")) |changes| {
        var n: usize = 0;
        for (changes) |ch| if (jsonrpc.getObj(ch, "textDocument") != null) {
            n += 1;
        };
        return n;
    }
    if (jsonrpc.getObj(edit, "changes")) |changes| return switch (changes) {
        .object => |o| o.count(),
        else => 0,
    };
    return 0;
}

pub fn close(app: *App) void {
    app.lsp.rename.deinit();
    app.needs_render = true;
}

/// Build the preview from the reply and show it.
pub fn open(app: *App, s: *Server, edit: Value) Allocator.Error!void {
    close(app);
    var p: Preview = .{ .arena = alloc.SnapshotArena.init(app.gpa), .server = s, .files = &.{}, .rows = &.{} };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    var files: std.ArrayListUnmanaged(File) = .empty;
    if (jsonrpc.getArr(edit, "documentChanges")) |changes| {
        for (changes) |ch| {
            const td = jsonrpc.getObj(ch, "textDocument") orelse continue;
            const uri = jsonrpc.getStr(td, "uri") orelse continue;
            try addFile(a, &files, uri, jsonrpc.getField(ch, "edits"));
        }
    } else if (jsonrpc.getObj(edit, "changes")) |changes| switch (changes) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| try addFile(a, &files, kv.key_ptr.*, kv.value_ptr.*);
        },
        else => {},
    };
    std.mem.sort(File, files.items, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    p.files = files.items;
    if (p.files.len == 0) {
        p.arena.deinit();
        app.toast("rename: no edits", .{});
        return;
    }
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (p.files, 0..) |f, fi| {
        try rows.append(a, .{ .file = fi, .edit = null });
        const text = try fileText(app, a, f.path);
        for (f.edits, 0..) |te, ei| {
            const before = if (text) |t| lineText(t, te.range.start.line) else "";
            try rows.append(a, .{ .file = fi, .edit = ei, .before = before });
        }
    }
    p.rows = rows.items;
    app.lsp.rename.preview = p;
    app.needs_render = true;
}

fn addFile(a: Allocator, files: *std.ArrayListUnmanaged(File), uri: []const u8, edits_v: ?Value) Allocator.Error!void {
    const path = (try types.pathFromUri(a, uri)) orelse return;
    const edits = try types.readTextEdits(a, edits_v);
    if (edits.len == 0) return;
    for (edits) |*te| te.new_text = try a.dupe(u8, te.new_text);
    std.mem.sort(types.TextEdit, edits, {}, struct {
        fn lt(_: void, x: types.TextEdit, y: types.TextEdit) bool {
            if (x.range.start.line != y.range.start.line) return x.range.start.line < y.range.start.line;
            return x.range.start.character < y.range.start.character;
        }
    }.lt);
    for (files.items) |*f| if (std.mem.eql(u8, f.path, path)) {
        f.edits = try std.mem.concat(a, types.TextEdit, &.{ f.edits, edits });
        return;
    };
    try files.append(a, .{ .path = path, .edits = edits });
}

/// The file's text: the open buffer's, else the disk's. Null when
/// neither can be had.
fn fileText(app: *App, arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    if (app.panes.findPath(path)) |id| if (app.panes.editor(id)) |e| return try arena.dupe(u8, e.buf.editor.bytes());
    return Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(16 * 1024 * 1024)) catch null;
}

/// Line `line` of `text`, without its newline ("" past the end).
fn lineSlice(text: []const u8, line: u32) []const u8 {
    var start: usize = 0;
    var n: u32 = 0;
    while (n < line) : (n += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "") + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

fn lineText(text: []const u8, line: u32) []const u8 {
    return std.mem.trim(u8, lineSlice(text, line), " \t\r");
}

// ─── keys + mouse ───────────────────────────────────────────────────────

/// True while the box shows and took the key.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    const p = &(app.lsp.rename.preview orelse return false);
    switch (k.code) {
        .esc => close(app),
        .enter => try apply(app),
        .down => p.cursor = @min(p.cursor + 1, p.rows.len -| 1),
        .up => p.cursor -|= 1,
        .char => |c| if (k.mods.ctrl or k.mods.alt) {
            return true;
        } else switch (c) {
            'j' => p.cursor = @min(p.cursor + 1, p.rows.len -| 1),
            'k' => p.cursor -|= 1,
            'q' => close(app),
            ' ', 'x' => toggle(app, p.rows[@min(p.cursor, p.rows.len -| 1)].file),
            'a' => {
                var all = true;
                for (p.files) |f| all = all and f.enabled;
                for (p.files) |*f| f.enabled = !all;
            },
            else => {},
        },
        else => {},
    }
    app.needs_render = true;
    return true;
}

fn toggle(app: *App, file: usize) void {
    const p = &(app.lsp.rename.preview orelse return);
    if (file < p.files.len) p.files[file].enabled = !p.files[file].enabled;
}

/// A click on row `i`: move there and toggle its file.
pub fn click(app: *App, i: usize) void {
    const p = &(app.lsp.rename.preview orelse return);
    if (i >= p.rows.len) return;
    p.cursor = i;
    toggle(app, p.rows[i].file);
    app.needs_render = true;
}

// ─── apply ──────────────────────────────────────────────────────────────

/// The ticked files, every one through `EditOp` in a buffer: an open
/// file's, or one opened here for it (the active pane kept). Nothing
/// is written; the toast says how many buffers were opened unsaved.
/// The box closes either way.
pub fn apply(app: *App) Allocator.Error!void {
    var p = app.lsp.rename.preview orelse return;
    app.lsp.rename.preview = null;
    defer p.deinit();
    var files_done: usize = 0;
    var edits_done: usize = 0;
    var opened: usize = 0;
    var refused: usize = 0;
    const keep_active = app.active;
    for (p.files) |f| {
        if (!f.enabled) continue;
        const was_open = app.panes.findPath(f.path) != null;
        const id = app.panes.findPath(f.path) orelse (app.openEditor(f.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                refused += 1;
                app.toast("rename: {s} skipped — cannot open it", .{app.relPath(f.path)});
                continue;
            },
        });
        const e = app.panes.editor(id) orelse {
            refused += 1;
            continue;
        };
        try lsp.applyEditsToPane(app, e, f.edits, p.server.encoding);
        files_done += 1;
        edits_done += f.edits.len;
        if (!was_open) opened += 1;
    }
    if (keep_active) |k| if (app.panes.get(k) != null) app.setActive(k);
    const arena = app.frame.allocator();
    const opened_note: []const u8 = if (opened > 0) try std.fmt.allocPrint(arena, " · {d} opened unsaved", .{opened}) else "";
    if (refused == 0) app.toast("renamed in {d} file(s) · {d} edit(s){s}", .{ files_done, edits_done, opened_note }) else app.toast("renamed in {d} file(s), {d} skipped{s}", .{ files_done, refused, opened_note });
    app.needs_render = true;
}

// ─── draw ───────────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) void {
    const p = &(app.lsp.rename.preview orelse return);
    const t = ui.theme;
    if (area.w < 30 or area.h < 6) return;
    const w = std.math.clamp(area.w - area.w / 5, 30, @min(110, area.w));
    const max_h = area.h - area.h / 4;
    const want: u16 = @intCast(@min(p.rows.len + 3, 200));
    const h: u16 = @max(@min(want, max_h), @min(8, area.h));
    const x = area.x + (area.w - w) / 2;
    const y = area.y + 1;
    var edits: usize = 0;
    var on: usize = 0;
    for (p.files) |f| {
        edits += f.edits.len;
        if (f.enabled) on += 1;
    }
    // How many ticked files are not open: Enter opens those, unsaved.
    var closed: usize = 0;
    for (p.files) |f| if (f.enabled and app.panes.findPath(f.path) == null) {
        closed += 1;
    };
    const title = if (closed == 0)
        ui.fmt("{s} rename · {d} of {d} files · {d} edits", .{ if (ui.ascii) "*" else "✦", on, p.files.len, edits })
    else
        ui.fmt("{s} rename · {d} of {d} files · {d} edits · {d} closed file{s} opens unsaved", .{ if (ui.ascii) "*" else "✦", on, p.files.len, edits, closed, if (closed == 1) "" else "s" });
    const inner = overlay.frame(ui, Rect.init(x, y, w, h), title);
    if (inner.isEmpty() or inner.h < 2) return;
    const rows: usize = inner.h - 1;
    if (p.cursor >= p.rows.len) p.cursor = p.rows.len -| 1;
    if (p.cursor < p.scroll) p.scroll = p.cursor;
    if (p.cursor >= p.scroll + rows) p.scroll = p.cursor + 1 - rows;
    var i: usize = 0;
    while (i < rows and p.scroll + i < p.rows.len) : (i += 1) {
        const idx = p.scroll + i;
        const row = p.rows[idx];
        const r = inner.row(@intCast(i));
        const is_cursor = idx == p.cursor;
        const base = if (is_cursor) Theme.onBg(t.overlay_bg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(r, base);
        const f = p.files[row.file];
        const muted = Theme.withFg(base, t.muted.fg);
        if (row.edit == null) {
            const mark = if (f.enabled) (if (ui.ascii) "[x]" else "[✓]") else "[ ]";
            const label = ui.fmt("{s} {s}  ({d})", .{ mark, app.relPath(f.path), f.edits.len });
            _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), Theme.withFg(base, if (f.enabled) t.accent.fg else t.muted.fg));
        } else {
            const te = f.edits[row.edit.?];
            const prefix = ui.fmt("    L{d:<5}", .{te.range.start.line + 1});
            var cx = r.x;
            cx += ui.putStr(cx, r.y, r.w, prefix, muted);
            const arrow = if (ui.ascii) " -> " else " → ";
            const shown = ui.fmt("{s}{s}{s}", .{ row.before, arrow, te.new_text });
            const style = if (f.enabled) Theme.withFg(base, t.fg.fg) else muted;
            _ = ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(shown, r.right() -| cx), style);
        }
        ui.hit(r, .{ .overlay_item = @intCast(idx) });
    }
    overlay.hint(ui, inner.row(inner.h - 1), "space toggles a file · a toggles all · enter applies · esc cancels");
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const command = @import("../core/command.zig");

test "through the fake server: a rename over two files opens the preview; an unticked file is skipped, a ticked closed file opens as a dirty buffer and the disk waits for the save, Esc walks away" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    const file = lsp.TestRig.file;
    const other = lsp.TestRig.other;
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = other, .data = "foo();\nfoo();\n" });
    defer Io.Dir.cwd().deleteFile(io, other) catch {};
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file);
        }
        fn preview(a: *App) bool {
            return a.lsp.rename.preview != null;
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    const ed = e.buf.editor;
    ed.setCursor(17); // `foo` on line 1
    const source_pane = app.active.?;

    // Two files: the box lists both, sorted by path, hunks under each;
    // the hint says the closed one will be opened.
    try lsp.acceptRename(&app, "multiOne");
    try lsp.TestRig.pump(&app, &app, Cond.preview, 5000);
    {
        const p = &app.lsp.rename.preview.?;
        try testing.expectEqual(@as(usize, 2), p.files.len);
        try testing.expectEqual(@as(usize, 4), p.rows.len);
        try testing.expectEqualStrings(other, p.files[0].path);
        try testing.expectEqualStrings("foo();", p.rows[1].before);
        try testing.expectEqualStrings("const foo = 2;", p.rows[3].before);
    }
    const txt = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "✦ rename · 2 of 2 files · 2 edits · 1 closed file opens unsaved") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "const foo = 2; → multiOne") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[✓] mnml-zig-fake-lsp-other.ts  (1)") != null);
    // Space on the first header unticks the closed file; Enter applies
    // only the open buffer's edit, and opens nothing.
    try app.handle(.{ .key = Key.char(' ') });
    try testing.expect(!app.lsp.rename.preview.?.files[0].enabled);
    const one = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "1 of 2 files · 2 edits") != null);
    try testing.expect(std.mem.indexOf(u8, one, "opens unsaved") == null);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(app.lsp.rename.preview == null);
    try testing.expect(std.mem.indexOf(u8, ed.bytes(), "const multiOne = 2;") != null);
    try testing.expectEqualStrings("renamed in 1 file(s) · 1 edit(s)", app.lastToast().?);
    try testing.expect(app.panes.findPath(other) == null);
    var disk = try Io.Dir.cwd().readFileAlloc(io, other, gpa, .limited(4096));
    try testing.expectEqualStrings("foo();\nfoo();\n", disk);
    gpa.free(disk);

    // Both ticked: the closed file is opened behind the active pane,
    // edited in memory and dirty; the disk still says `foo` until a
    // save-all writes both.
    try lsp.acceptRename(&app, "multiTwo");
    try lsp.TestRig.pump(&app, &app, Cond.preview, 5000);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("renamed in 2 file(s) · 2 edit(s) · 1 opened unsaved", app.lastToast().?);
    try testing.expect(std.mem.indexOf(u8, ed.bytes(), "multiTwo") != null);
    try testing.expectEqual(source_pane, app.active.?);
    const other_id = app.panes.findPath(other).?;
    const oe = app.panes.editor(other_id).?;
    try testing.expectEqualStrings("foo();\nmultiTwo();\n", oe.buf.editor.bytes());
    try testing.expect(oe.buf.doc.dirty);
    disk = try Io.Dir.cwd().readFileAlloc(io, other, gpa, .limited(4096));
    try testing.expectEqualStrings("foo();\nfoo();\n", disk);
    gpa.free(disk);
    try oe.buf.save(io);
    disk = try Io.Dir.cwd().readFileAlloc(io, other, gpa, .limited(4096));
    try testing.expectEqualStrings("foo();\nmultiTwo();\n", disk);
    gpa.free(disk);

    // Now that it is open, the next rename edits the buffer it has.
    try lsp.acceptRename(&app, "multiThree");
    try lsp.TestRig.pump(&app, &app, Cond.preview, 5000);
    const both_open = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(both_open);
    try testing.expect(std.mem.indexOf(u8, both_open, "opens unsaved") == null);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("renamed in 2 file(s) · 2 edit(s)", app.lastToast().?);
    try testing.expect(std.mem.startsWith(u8, oe.buf.editor.bytes(), "foo();\nmultiThree"));

    // Esc: nothing changes. `a` toggles every file; a click toggles a row's.
    const before = try gpa.dupe(u8, ed.bytes());
    defer gpa.free(before);
    try lsp.acceptRename(&app, "multiFour");
    try lsp.TestRig.pump(&app, &app, Cond.preview, 5000);
    try app.handle(.{ .key = Key.char('a') });
    try testing.expect(!app.lsp.rename.preview.?.files[0].enabled and !app.lsp.rename.preview.?.files[1].enabled);
    try app.handle(.{ .key = Key.char('a') });
    try testing.expect(app.lsp.rename.preview.?.files[1].enabled);
    click(&app, 3);
    try testing.expect(!app.lsp.rename.preview.?.files[1].enabled);
    try testing.expectEqual(@as(usize, 3), app.lsp.rename.preview.?.cursor);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.lsp.rename.preview == null);
    try testing.expectEqualStrings(before, ed.bytes());
    try rig.stop(&app);
}

test "csharp-ls's rename shape — `documentChanges`, the open file versioned and the closed one not — edits both in buffers and writes neither until the save" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    const file = lsp.TestRig.file;
    // Warn.cs's call of `Calc.Add`, closed, on disk.
    const warn = "/tmp/mnml-zig-fake-lsp-warn.ts";
    const warn_text = "public static class Warn\n{\n    public static int Noisy() => Calc.Add(1, 2);\n}\n";
    const e = try lsp.TestRig.openFile(&app, file, "public static int Add(int a, int b) => a + b;\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = warn, .data = warn_text });
    defer Io.Dir.cwd().deleteFile(io, warn) catch {};
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file);
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The reply csharp-ls 0.28 sent for `Add` → `Plus` (the hunt's wire
    // capture), with this test's URIs.
    const json = try std.fmt.allocPrint(a, "{{\"documentChanges\":[{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":1}},\"edits\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":18}},\"end\":{{\"line\":0,\"character\":21}}}},\"newText\":\"Plus\"}}]}},{{\"textDocument\":{{\"uri\":\"{s}\"}},\"edits\":[{{\"range\":{{\"start\":{{\"line\":2,\"character\":38}},\"end\":{{\"line\":2,\"character\":41}}}},\"newText\":\"Plus\"}}]}}]}}", .{ try types.uriFromPath(a, file), try types.uriFromPath(a, warn) });
    const edit = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    try testing.expectEqual(@as(usize, 2), fileCount(edit));
    try open(&app, rig.server, edit);
    try testing.expectEqual(@as(usize, 2), app.lsp.rename.preview.?.files.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("renamed in 2 file(s) · 2 edit(s) · 1 opened unsaved", app.lastToast().?);
    // Both halves are in buffers, both dirty; the disk has neither.
    try testing.expectEqualStrings("public static int Plus(int a, int b) => a + b;\n", e.buf.editor.bytes());
    const warn_pane = app.panes.editor(app.panes.findPath(warn).?).?;
    try testing.expect(std.mem.indexOf(u8, warn_pane.buf.editor.bytes(), "Calc.Plus(1, 2)") != null);
    try testing.expect(warn_pane.buf.doc.dirty);
    var disk = try Io.Dir.cwd().readFileAlloc(io, warn, gpa, .limited(4096));
    try testing.expectEqualStrings(warn_text, disk);
    gpa.free(disk);
    // One save of the opened file lands its half.
    try warn_pane.buf.save(io);
    disk = try Io.Dir.cwd().readFileAlloc(io, warn, gpa, .limited(4096));
    defer gpa.free(disk);
    try testing.expect(std.mem.indexOf(u8, disk, "Calc.Plus(1, 2)") != null);
    try rig.stop(&app);
}

test "fileCount reads both WorkspaceEdit shapes" {
    var p = try std.json.parseFromSlice(Value, testing.allocator, "{\"changes\":{\"file:///a\":[],\"file:///b\":[]}}", .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), fileCount(p.value));
    var q = try std.json.parseFromSlice(Value, testing.allocator, "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///a\"},\"edits\":[]},{\"kind\":\"create\",\"uri\":\"file:///c\"}]}", .{});
    defer q.deinit();
    try testing.expectEqual(@as(usize, 1), fileCount(q.value));
}
