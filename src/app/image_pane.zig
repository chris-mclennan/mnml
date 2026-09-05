//! `Pane.image` — a one-image viewer. The tree opens an image file here
//! (`App.openPath` routes by extension); it is a preview tab, so the
//! next image glanced at replaces it in place rather than piling up.
//!
//! The paint is two-phase (`src/image/root.zig`): the pane draws a
//! header (name · size · pixels · format · transport) and a dim body,
//! and leaves a `PaintRequest` for the terminal to draw the image over
//! the body once the cells are out. Without a transport the body says
//! what it would take. `i` hides the header, `r` re-reads the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Key = @import("../core/key.zig").Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const image = @import("../image/root.zig");

pub const table = .{
    .@"view.image_open" = &imageOpenCmd,
};

pub const ImagePane = struct {
    gpa: Allocator,
    /// Owned, absolute.
    path: []u8,
    /// Owned: `shot.png [PNG]`.
    tab_title: []u8,
    data: ?image.Loaded,
    /// Why `data` is null, owned.
    err: ?[]u8 = null,
    show_header: bool = true,
    /// Replaceable by the next glance (`open`).
    is_preview: bool = true,

    pub fn deinit(self: *ImagePane) void {
        if (self.data) |*d| d.deinit(self.gpa);
        if (self.err) |e| self.gpa.free(e);
        self.gpa.free(self.tab_title);
        self.gpa.free(self.path);
    }

    fn load(self: *ImagePane, io: std.Io) Allocator.Error!void {
        if (self.data) |*d| d.deinit(self.gpa);
        self.data = null;
        if (self.err) |e| self.gpa.free(e);
        self.err = null;
        self.data = image.load(self.gpa, io, self.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.err = try std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)});
                return;
            },
        };
    }
};

/// Open `path` (absolute) as the image preview: an existing preview
/// image pane is replaced in place (same tab), otherwise a new tab.
pub fn open(app: *App, path: []const u8) Allocator.Error!PaneId {
    const gpa = app.gpa;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const tab_title = try std.fmt.allocPrint(gpa, "{s} [{s}]", .{ std.fs.path.basename(path), image.Format.fromPath(path).label() });
    errdefer gpa.free(tab_title);
    var pane: ImagePane = .{ .gpa = gpa, .path = owned_path, .tab_title = tab_title, .data = null };
    try pane.load(app.io);
    if (app.panes.findImagePreview()) |id| {
        const slot = app.panes.get(id).?;
        slot.deinit(gpa, app.io);
        slot.* = .{ .image = pane };
        app.showPane(id);
        app.needs_render = true;
        return id;
    }
    const id = try app.panes.add(.{ .image = pane });
    app.showPane(id);
    app.needs_render = true;
    return id;
}

/// `view.image_open`: a path prompt.
fn imageOpenCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Open image (workspace-relative or absolute path)"), .purpose = .image_open } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptOpen(app: *App, text: []const u8) Allocator.Error!void {
    const rel = std.mem.trim(u8, text, " \t");
    if (rel.len == 0) return;
    const abs = try app.absPath(rel);
    if (!image.isImagePath(abs)) {
        app.toast("{s}: not an image extension (png / jpg / gif / webp / bmp)", .{rel});
        return;
    }
    _ = try open(app, abs);
}

/// Keys on the pane: `i` toggles the header, `r` re-reads the file.
pub fn handleKey(app: *App, id: PaneId, p: *ImagePane, k: Key) Allocator.Error!bool {
    _ = id;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .char => |c| switch (c) {
            'i' => p.show_header = !p.show_header,
            'r' => {
                try p.load(app.io);
                app.toast("reloaded {s}", .{app.relPath(p.path)});
            },
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// `12.3 KB` / `1.2 MB`.
fn sizeLabel(arena: Allocator, n: usize) []const u8 {
    const kb = @as(f64, @floatFromInt(n)) / 1024.0;
    if (kb >= 1024.0) return std.fmt.allocPrint(arena, "{d:.1} MB", .{kb / 1024.0}) catch "";
    return std.fmt.allocPrint(arena, "{d:.1} KB", .{kb}) catch "";
}

/// The cell box an image of `size` takes inside `body`, aspect kept
/// under the usual 1:2 cell.
pub fn cellBox(size: image.Size, body: Rect) Rect {
    if (body.isEmpty() or size.w == 0 or size.h == 0) return Rect.empty;
    // Pixels per cell: 10 wide, 20 tall — the ratio is what matters.
    var cols: u32 = @max(1, (size.w + 9) / 10);
    var rows: u32 = @max(1, (size.h + 19) / 20);
    if (cols > body.w) {
        rows = @max(1, (rows * body.w + cols / 2) / cols);
        cols = body.w;
    }
    if (rows > body.h) {
        cols = @max(1, (cols * body.h + rows / 2) / rows);
        rows = body.h;
    }
    const w: u16 = @intCast(@min(cols, body.w));
    const h: u16 = @intCast(@min(rows, body.h));
    return Rect.init(body.x + (body.w - w) / 2, body.y, w, h);
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *ImagePane, area: Rect) Allocator.Error!void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    ui.hit(area, .{ .pane = id });
    var body = area;
    if (p.show_header and area.h >= 2) {
        const parts = area.splitTop(1);
        body = parts.rest;
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.print(ui.arena, " {s}", .{std.fs.path.basename(p.path)});
        if (p.data) |*d| {
            try line.print(ui.arena, " · {s}", .{sizeLabel(ui.arena, d.bytes.len)});
            if (d.size) |s| try line.print(ui.arena, " · {d}×{d}", .{ s.w, s.h });
            try line.print(ui.arena, " · {s}", .{d.format.label()});
        }
        try line.print(ui.arena, " · {s}", .{app.image_transport.label()});
        _ = ui.putStr(parts.top.x, parts.top.y, parts.top.w, ui.clipStr(line.items, parts.top.w), Theme.onBg(th.muted, th.bg.bg));
    }
    if (body.isEmpty()) return;
    const dim = Theme.onBg(th.muted, th.bg.bg);
    if (p.err) |e| {
        _ = ui.putStr(body.x + 1, body.y, body.w -| 1, ui.clipStr(ui.fmt("cannot load: {s}", .{e}), body.w -| 1), Theme.onBg(th.error_fg, th.bg.bg));
        return;
    }
    const d = &(p.data orelse return);
    if (app.image_transport == .none) {
        const lines = [_][]const u8{
            "no image protocol in this terminal",
            "kitty graphics (ghostty, kitty, WezTerm), iTerm2, or sixel (foot, mlterm) render inline;",
            "MNML_IMAGE_PROTOCOL=kitty|iterm2|sixel forces one",
        };
        for (lines, 0..) |l, i| {
            if (i >= body.h) break;
            _ = ui.putStr(body.x + 1, body.y + @as(u16, @intCast(i)), body.w -| 1, ui.clipStr(l, body.w -| 1), dim);
        }
        return;
    }
    const png = d.ensurePng(app.gpa) orelse {
        _ = ui.putStr(body.x + 1, body.y, body.w -| 1, ui.clipStr(ui.fmt("cannot decode {s}: {s}", .{ d.format.label(), d.png_error orelse "?" }), body.w -| 1), Theme.onBg(th.error_fg, th.bg.bg));
        return;
    };
    const size = d.size orelse image.Size{ .w = 800, .h = 600 };
    const box = cellBox(size, body);
    if (box.isEmpty()) return;
    // The placeholder: the box in the panel ground so the paint has a
    // clean canvas, and the terminal draws the image over it.
    ui.fill(box, th.panel_bg);
    try app.image_paints.append(app.frame.allocator(), .{ .rect = box, .png = png, .key = d.key(p.path) });
}

// ── tests ──

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

const tiny_png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x28" ++ "\x00\x00\x00\x14" ++ "\x08\x06\x00\x00\x00" ++ "\x00\x00\x00\x00";

test "an image opens from openPath as a preview tab, shows its header, and the next image replaces it in place" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shot.png", .data = tiny_png });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.gif", .data = "GIF89a" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(t.allocator, &.{ root, "shot.png" });
    defer t.allocator.free(a);
    const id = try app.openPath(a);
    try t.expect(app.panes.get(id).?.* == .image);
    try t.expectEqualStrings("shot.png [PNG]", app.panes.get(id).?.title());
    const text = try screenText(&app);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "shot.png · 0.0 KB · 40×20 · PNG · none") != null);
    try t.expect(std.mem.indexOf(u8, text, "no image protocol in this terminal") != null);
    try t.expectEqual(@as(usize, 0), app.image_paints.items.len);
    // With a transport the body leaves a paint request sized to the pixels.
    app.image_transport = .kitty;
    const painted = try screenText(&app);
    defer t.allocator.free(painted);
    try t.expect(std.mem.indexOf(u8, painted, "kitty graphics") != null);
    try t.expectEqual(@as(usize, 1), app.image_paints.items.len);
    const box = app.image_paints.items[0].rect;
    try t.expectEqual(@as(u16, 4), box.w);
    try t.expectEqual(@as(u16, 1), box.h);
    try t.expect(app.image_paints.items[0].png.ptr == app.panes.get(id).?.image.data.?.bytes.ptr);
    // The second image takes the same tab.
    const b = try std.fs.path.join(t.allocator, &.{ root, "other.gif" });
    defer t.allocator.free(b);
    const id2 = try app.openPath(b);
    try t.expectEqual(id, id2);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    try t.expectEqualStrings("other.gif [GIF]", app.panes.get(id).?.title());
    // `i` hides the header; the discovery / hover surfaces see a pane hit.
    try app.handle(.{ .key = Key.char('i') });
    try t.expect(!app.panes.get(id).?.image.show_header);
    try app.render();
    try t.expect(app.hits.at(10, 5).? == .pane);
    // A GIF on kitty needs a decode; a bogus one says so instead of painting.
    const again = try screenText(&app);
    defer t.allocator.free(again);
    try t.expect(std.mem.indexOf(u8, again, "cannot decode GIF") != null);
    try t.expectEqual(@as(usize, 0), app.image_paints.items.len);
}

test "cellBox keeps the 1:2 cell aspect, clamps to the body, and centres" {
    const body = Rect.init(0, 0, 40, 10);
    const wide = cellBox(.{ .w = 800, .h = 200 }, body); // 80×10 cells → 40×5
    try t.expectEqual(@as(u16, 40), wide.w);
    try t.expectEqual(@as(u16, 5), wide.h);
    const tall = cellBox(.{ .w = 100, .h = 400 }, body); // 10×20 → 5×10
    try t.expectEqual(@as(u16, 5), tall.w);
    try t.expectEqual(@as(u16, 10), tall.h);
    try t.expectEqual(@as(u16, 17), tall.x);
    const small = cellBox(.{ .w = 30, .h = 20 }, body);
    try t.expectEqual(@as(u16, 3), small.w);
    try t.expectEqual(@as(u16, 1), small.h);
    try t.expect(cellBox(.{ .w = 0, .h = 0 }, body).isEmpty());
}
