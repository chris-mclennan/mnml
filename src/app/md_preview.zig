//! The rendered markdown preview (`Pane.md_preview`). A `.md` file opens
//! rendered by default (`markdown_opens_rendered`); `markdown.preview`
//! opens the preview beside an editor's tab in the same leaf;
//! `markdown.edit_raw` — or typing on the preview — swaps the editor in.
//! With `auto_md_preview` on, opening a `.md` file splits the preview
//! to the right and keeps the focus on the editor.
//!
//! The preview reads the editor's text whenever the file is open in
//! one, so an edit shows on the next frame; the render is a pure
//! function of that text (`ui/md_view.zig`) done per frame on the frame
//! arena — the loop coalesces frames, which is the debounce.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const md_view = @import("../ui/md_view.zig");
const dispatch = @import("dispatch.zig");

pub const table = .{
    .@"markdown.preview" = &previewCmd,
    .@"markdown.edit_raw" = &editRawCmd,
};

/// The bufferline chips: `✏ Edit` on a preview, ` Preview` on a
/// markdown editor.
pub const button_edit: u32 = 0x6d64_0001;
pub const button_preview: u32 = 0x6d64_0002;

pub const MdPreviewPane = struct {
    gpa: Allocator,
    /// Owned, absolute.
    path: []u8,
    /// Owned: the file as read when no editor held it.
    text: []u8,
    /// Display rows.
    scroll: usize = 0,
    /// Rows the content took at the last frame (for paging).
    total_rows: usize = 0,

    pub fn deinit(self: *MdPreviewPane) void {
        self.gpa.free(self.path);
        self.gpa.free(self.text);
    }
};

pub fn isMarkdownPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown") or std.ascii.eqlIgnoreCase(ext, ".mdx");
}

pub const Placement = enum {
    /// A tab in the focused leaf, made active.
    here,
    /// A split to the right of `near`; the focus stays where it is.
    beside,
};

/// Open (or reveal) the preview of `path`.
pub fn open(app: *App, path: []const u8, placement: Placement, near: ?PaneId) Allocator.Error!PaneId {
    if (app.panes.findPreview(path)) |id| {
        if (placement == .here) app.showPane(id);
        return id;
    }
    const gpa = app.gpa;
    const text: []u8 = if (app.panes.findPath(path)) |eid|
        try gpa.dupe(u8, app.panes.editor(eid).?.buf.editor.bytes())
    else
        Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(1 << 30)) catch try gpa.dupe(u8, "");
    errdefer gpa.free(text);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const id = try app.panes.add(.{ .md_preview = .{ .gpa = gpa, .path = owned_path, .text = text } });
    switch (placement) {
        .here => app.showPane(id),
        .beside => {
            const layout = app.layouts.current();
            const anchor = near orelse app.active;
            const split_ok = if (anchor) |a| (try layout.split(a, .horizontal, id)) != null else false;
            if (!split_ok) app.showPane(id);
        },
    }
    app.needs_render = true;
    return id;
}

/// The text the preview renders: the editor's when the file is open.
pub fn sourceText(app: *App, m: *const MdPreviewPane) []const u8 {
    if (app.panes.findPath(m.path)) |eid| if (app.panes.editor(eid)) |e| return e.buf.editor.bytes();
    return m.text;
}

/// Replace the preview with the file's editor in the same leaf. Returns
/// the editor's pane.
pub fn swapToEditor(app: *App, preview: PaneId) Allocator.Error!PaneId {
    const pane = app.panes.get(preview) orelse return error.OutOfMemory;
    const m = pane.asMdPreview() orelse return error.OutOfMemory;
    const path = try app.frame.allocator().dupe(u8, m.path);
    app.showPane(preview);
    const eid = app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("open {s}: {s}", .{ app.relPath(path), @errorName(err) });
            return preview;
        },
    };
    try app.forceClosePane(preview);
    app.setActive(eid);
    return eid;
}

fn previewCmd(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(active) orelse return error.NoActivePane;
    switch (pane.*) {
        .md_preview => {},
        .editor => |*e| {
            const path = e.buf.path orelse return app.diag.fail(app.frame.allocator(), "not a markdown file", .{});
            if (!isMarkdownPath(path)) return app.diag.fail(app.frame.allocator(), "not a markdown file", .{});
            _ = try open(app, path, .here, active);
        },
        .outline, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .debug, .dap_repl, .request, .websocket, .browser, .script => return app.diag.fail(app.frame.allocator(), "not a markdown file", .{}),
    }
}

fn editRawCmd(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(active) orelse return error.NoActivePane;
    switch (pane.*) {
        .md_preview => _ = try swapToEditor(app, active),
        .editor => {},
        .outline, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .debug, .dap_repl, .request, .websocket, .browser, .script => return error.NotAnEditor,
    }
}

pub fn scrollBy(app: *App, m: *MdPreviewPane, delta: i64) void {
    const max: i64 = @intCast(m.total_rows -| @max(app.pane_rows, 1));
    const cur: i64 = @intCast(m.scroll);
    m.scroll = @intCast(std.math.clamp(cur + delta, 0, @max(max, 0)));
    app.needs_render = true;
}

/// Keys on the preview: navigation stays here; anything that would
/// type swaps the editor in and lands the key there.
pub fn handleKey(app: *App, id: PaneId, k: Key) Allocator.Error!bool {
    const pane = app.panes.get(id) orelse return false;
    const m = pane.asMdPreview() orelse return false;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const page: i64 = @intCast(@max(app.pane_rows, 1));
    switch (k.code) {
        .down => scrollBy(app, m, 1),
        .up => scrollBy(app, m, -1),
        .page_down => scrollBy(app, m, page),
        .page_up => scrollBy(app, m, -page),
        .home => scrollBy(app, m, -@as(i64, @intCast(m.scroll))),
        .end => scrollBy(app, m, @intCast(m.total_rows)),
        .esc => {},
        .char => |c| switch (c) {
            'j' => scrollBy(app, m, 1),
            'k' => scrollBy(app, m, -1),
            'g' => scrollBy(app, m, -@as(i64, @intCast(m.scroll))),
            'G' => scrollBy(app, m, @intCast(m.total_rows)),
            ' ' => scrollBy(app, m, page),
            'e' => _ = try swapToEditor(app, id),
            else => {
                _ = try swapToEditor(app, id);
                try dispatch.key(app, k);
            },
        },
        .enter, .backspace, .delete, .tab => {
            _ = try swapToEditor(app, id);
            try dispatch.key(app, k);
        },
        else => return false,
    }
    return true;
}

pub fn draw(app: *App, ui: Ui, id: PaneId, m: *MdPreviewPane, area: Rect) Allocator.Error!void {
    const lines = try md_view.render(ui.arena, ui.theme, sourceText(app, m), ui.ascii);
    const total = md_view.totalRows(ui.canvas, lines, area.w -| 2);
    if (m.scroll > total -| area.h) m.scroll = total -| area.h;
    m.total_rows = md_view.draw(ui, id, area, lines, m.scroll);
    if (app.active == id) app.pane_rows = @max(area.h, 1);
}

// ── tests ──

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "a .md opens rendered; typing swaps the editor in and lands; edit_raw / preview round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "# Title\n\nSome **bold** text.\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const path = try std.fs.path.join(testing.allocator, &.{ root, "notes.md" });
    defer testing.allocator.free(path);
    const pid = try app.openPath(path);
    try testing.expect(app.panes.get(pid).?.* == .md_preview);
    const rendered = try screenText(&app);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "Some bold text.") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Title") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Edit") != null);
    // Typing lands in the editor.
    try app.handle(.{ .key = Key.char('Z') });
    const e = app.activeEditor().?;
    try testing.expect(std.mem.startsWith(u8, e.buf.editor.bytes(), "Z# Title"));
    try testing.expect(e.buf.dirty);
    try testing.expect(app.panes.get(pid) == null);
    // Back to a preview: the editor's unsaved text is what renders.
    try command.run(&app, .{ .static = .@"markdown.preview" });
    try testing.expect(app.panes.get(app.active.?).?.* == .md_preview);
    const again = try screenText(&app);
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "Z# Title") != null);
    try testing.expectEqual(@as(usize, 2), app.panes.count());
    try command.run(&app, .{ .static = .@"markdown.edit_raw" });
    try testing.expect(app.panes.get(app.active.?).?.* == .editor);
    try testing.expectEqual(@as(usize, 1), app.panes.count());
}

test "auto_md_preview splits the preview beside the editor and keeps the focus" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "# Title\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 80, .rows = 12, .cfg = .{ .ui = .{ .auto_md_preview = true } } });
    defer app.deinit();
    app.tree.visible = false;
    const path = try std.fs.path.join(testing.allocator, &.{ root, "notes.md" });
    defer testing.allocator.free(path);
    const eid = try app.openPath(path);
    try testing.expectEqual(eid, app.active.?);
    try testing.expect(app.panes.get(eid).?.* == .editor);
    try testing.expectEqual(@as(usize, 2), app.panes.count());
    try testing.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
}
