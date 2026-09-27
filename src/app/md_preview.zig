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
const image = @import("../image/root.zig");
const docs = @import("docs.zig");

pub const table = .{
    .@"markdown.preview" = &previewCmd,
    .@"markdown.edit_raw" = &editRawCmd,
    .@"markdown.cycle_engine" = &cycleEngine,
};

/// `markdown.cycle_engine`: `builtin → glow → pandoc → builtin`; a
/// `.custom` command goes back to `builtin` (the easy reset). Written
/// to the home config as `ui.md_preview_engine`.
fn cycleEngine(app: *App) CommandError!void {
    const Config = app_mod.Config;
    const next: Config.MdEngine = switch (app.cfg.ui.md_preview_engine) {
        .builtin => .glow,
        .glow => .pandoc,
        .pandoc, .custom => .builtin,
    };
    app.cfg.ui.md_preview_engine = next;
    _ = try @import("settings.zig").persist(app, .home, &.{ "ui", "md_preview_engine" }, next);
    app.toast("markdown engine: {s}", .{@tagName(next)});
    app.needs_render = true;
}

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
    /// A glance (a single click, a jump): the next glance at another
    /// markdown file replaces this tab in place. `markdown.preview` on
    /// an editor opens a permanent one. Typing swaps the editor in, and
    /// an editor is never a preview.
    is_preview: bool = false,
    /// The images the preview embeds, by resolved path — loaded on
    /// first sight, kept while the pane lives (`ui/md_view.zig`
    /// places them, `Term.paintImages` draws them).
    images: std.ArrayListUnmanaged(CachedImage) = .empty,

    pub const CachedImage = struct {
        /// Owned, absolute.
        path: []u8,
        /// Null when the file could not be read.
        data: ?image.Loaded,
    };

    pub fn deinit(self: *MdPreviewPane) void {
        for (self.images.items) |*c| {
            if (c.data) |*d| d.deinit(self.gpa);
            self.gpa.free(c.path);
        }
        self.images.deinit(self.gpa);
        self.gpa.free(self.path);
        self.gpa.free(self.text);
    }

    /// The cache entry for `abs`, loading it the first time.
    pub fn imageFor(self: *MdPreviewPane, io: Io, abs: []const u8) Allocator.Error!*CachedImage {
        for (self.images.items) |*c| if (std.mem.eql(u8, c.path, abs)) return c;
        const owned = try self.gpa.dupe(u8, abs);
        errdefer self.gpa.free(owned);
        const data: ?image.Loaded = image.load(self.gpa, io, abs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try self.images.append(self.gpa, .{ .path = owned, .data = data });
        return &self.images.items[self.images.items.len - 1];
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

/// Open (or reveal) the preview of `path`. A `.here` open is a glance:
/// it takes over the tab of the last glanced-at markdown file (like the
/// image viewer) rather than piling up tabs; `.beside` is permanent.
pub fn open(app: *App, path: []const u8, placement: Placement, near: ?PaneId) Allocator.Error!PaneId {
    if (app.panes.findPreview(path)) |id| {
        if (placement == .here) app.showPane(id);
        return id;
    }
    const gpa = app.gpa;
    // A manual section (`app/docs.zig`) is embedded text on a virtual
    // path — the session restores it by that path, so it reads here.
    const text: []u8 = if (docs.textFor(path)) |embedded|
        try gpa.dupe(u8, embedded)
    else if (app.panes.findPath(path)) |eid|
        try gpa.dupe(u8, app.panes.editor(eid).?.buf.editor.bytes())
    else
        Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(1 << 30)) catch try gpa.dupe(u8, "");
    errdefer gpa.free(text);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const fresh: MdPreviewPane = .{ .gpa = gpa, .path = owned_path, .text = text, .is_preview = placement == .here };
    if (placement == .here) if (app.panes.findMdGlance()) |id| {
        const slot = app.panes.get(id).?;
        slot.deinit(gpa, app.io);
        slot.* = .{ .md_preview = fresh };
        app.showPane(id);
        app.needs_render = true;
        return id;
    };
    const id = try app.panes.add(.{ .md_preview = fresh });
    switch (placement) {
        .here => app.showPane(id),
        .beside => {
            const layout = app.layouts.current();
            const anchor = near orelse app.active;
            const split_ok = if (anchor) |a| (try layout.split(a, .horizontal, id)) != null else false;
            if (!split_ok) app.showPane(id);
            app.afterSplitChange();
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
    // The manual has no file behind it: nothing to swap in.
    if (docs.isVirtual(m.path)) {
        app.toast("the manual is read-only \u{2014} its source is docs/CONFIG.md in the repo", .{});
        return preview;
    }
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
            const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "not a markdown file", .{});
            if (!isMarkdownPath(path)) return app.diag.fail(app.frame.allocator(), "not a markdown file", .{});
            // Asked for by name: a permanent tab, in this leaf.
            const id = try open(app, path, .beside, active);
            app.showPane(id);
        },
        .outline, .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .sessions_table, .spend_report, .ai_usage, .grep, .debug, .request, .websocket, .browser, .script, .mount, .integrations, .ai_apply, .tests, .flaky, .requests, .files, .zon, .session_changes => return app.diag.fail(app.frame.allocator(), "not a markdown file", .{}),
    }
}

fn editRawCmd(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(active) orelse return error.NoActivePane;
    switch (pane.*) {
        .md_preview => _ = try swapToEditor(app, active),
        .editor => {},
        .outline, .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .sessions_table, .spend_report, .ai_usage, .grep, .debug, .request, .websocket, .browser, .script, .mount, .integrations, .ai_apply, .tests, .flaky, .requests, .files, .zon, .session_changes => return error.NotAnEditor,
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
                // No editor came (the manual, a file that would not
                // open): the key stops here rather than looping back.
                if (try swapToEditor(app, id) == id) return true;
                try dispatch.key(app, k);
            },
        },
        .enter, .backspace, .delete, .tab => {
            if (try swapToEditor(app, id) == id) return true;
            try dispatch.key(app, k);
        },
        else => return false,
    }
    return true;
}

pub fn draw(app: *App, ui: Ui, id: PaneId, m: *MdPreviewPane, area: Rect) Allocator.Error!void {
    // Inline images take `ui.md_image_rows` rows each when the terminal
    // can draw them; otherwise the caption stands alone.
    const image_rows: u16 = if (app.image_transport != .none) app.cfg.ui.md_image_rows else 0;
    const lines = try md_view.renderWith(ui.arena, ui.theme, sourceText(app, m), ui.ascii, image_rows);
    const total = md_view.totalRows(ui.canvas, lines, area.w -| 2);
    if (m.scroll > total -| area.h) m.scroll = total -| area.h;
    var placements: std.ArrayListUnmanaged(md_view.Placement) = .empty;
    m.total_rows = md_view.drawWith(ui, id, area, lines, m.scroll, &placements);
    if (app.active == id) app.pane_rows = @max(area.h, 1);
    // Resolve each `src` against the file's directory, load once, and
    // leave the paint for the terminal.
    const dir = std.fs.path.dirname(m.path) orelse "/";
    for (placements.items) |p| {
        const abs = if (std.fs.path.isAbsolute(p.src)) p.src else try std.fs.path.resolve(ui.arena, &.{ dir, p.src });
        const cached = try m.imageFor(app.io, abs);
        const d = &(cached.data orelse continue);
        const png = d.ensurePng(app.gpa) orelse continue;
        try app.image_paints.append(app.frame.allocator(), .{ .rect = p.rect, .png = png, .key = d.key(abs) });
    }
}

// ── tests ──

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;
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
    try testing.expect(e.buf.doc.dirty);
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

test "inline images: the preview reserves md_image_rows per image on a transport, loads it once, and leaves a paint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "img");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "img/cat.png", .data = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x28\x00\x00\x00\x14\x08\x06\x00\x00\x00\x00\x00\x00\x00" });
    // Enough text after the image that the preview can scroll.
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    defer doc.deinit(testing.allocator);
    try doc.appendSlice(testing.allocator, "# Cats\n\n![a cat](img/cat.png)\n\nafter\n");
    for (0..40) |i| try doc.print(testing.allocator, "line {d}\n", .{i});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = doc.items });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 60, .rows = 20, .cfg = .{ .ui = .{ .md_image_rows = 5 } } });
    defer app.deinit();
    app.tree.visible = false;
    const path = try std.fs.path.join(testing.allocator, &.{ root, "notes.md" });
    defer testing.allocator.free(path);
    const pid = try app.openPath(path);
    // Headless: the caption alone, no paint.
    const plain = try screenText(&app);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "[image: a cat]") != null);
    try testing.expectEqual(@as(usize, 0), app.image_paints.items.len);
    try testing.expectEqual(@as(usize, 0), app.panes.get(pid).?.md_preview.images.items.len);
    // kitty: four filler rows under the caption become the paint box.
    app.image_transport = .kitty;
    const painted = try screenText(&app);
    defer testing.allocator.free(painted);
    try testing.expect(std.mem.indexOf(u8, painted, "[image: a cat]") != null);
    try testing.expectEqual(@as(usize, 1), app.image_paints.items.len);
    const req = app.image_paints.items[0];
    try testing.expectEqual(@as(u16, 4), req.rect.h);
    try testing.expect(std.mem.startsWith(u8, req.png, "\x89PNG"));
    const cache = &app.panes.get(pid).?.md_preview.images;
    try testing.expectEqual(@as(usize, 1), cache.items.len);
    try testing.expect(sdk_testing.pathEndsWith(cache.items[0].path, "img/cat.png"));
    // A second frame reuses the cache and the same key.
    const key = req.key;
    try app.render();
    try testing.expectEqual(@as(usize, 1), cache.items.len);
    try testing.expectEqual(key, app.image_paints.items[0].key);
    // Scrolling the caption and the first filler off keeps the three
    // visible fillers, now at the top of the pane.
    const first_y = req.rect.y;
    scrollBy(&app, &app.panes.get(pid).?.md_preview, 4);
    try app.render();
    try testing.expectEqual(@as(usize, 1), app.image_paints.items.len);
    try testing.expectEqual(@as(u16, 3), app.image_paints.items[0].rect.h);
    try testing.expectEqual(first_y - 3, app.image_paints.items[0].rect.y);
    // A missing file is a cache entry with no data and no paint.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "![gone](img/none.png)\n" });
    _ = try swapToEditor(&app, pid);
    try command.run(&app, .{ .static = .@"markdown.preview" });
    try app.render();
    try testing.expectEqual(@as(usize, 0), app.image_paints.items.len);
}

test "preview tabs: a glance at another .md replaces the glanced tab in place; typing makes it an editor (never a preview); markdown.preview is permanent; a request preview is promoted by editing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "# A\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.md", .data = "# B\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.md", .data = "# C\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "r.http", .data = "GET https://example.test/\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 80, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try std.fs.path.join(testing.allocator, &.{ root, "a.md" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b.md" });
    defer testing.allocator.free(b);
    const c = try std.fs.path.join(testing.allocator, &.{ root, "c.md" });
    defer testing.allocator.free(c);
    const r = try std.fs.path.join(testing.allocator, &.{ root, "r.http" });
    defer testing.allocator.free(r);
    // A glance, then another: the same tab, now b.md. (`openPath` is
    // the explicit gesture — a tab of its own; `openPreview` is what a
    // tree click reaches.)
    const first = try app.openPreview(a);
    try testing.expect(app.panes.get(first).?.md_preview.is_preview);
    const second = try app.openPreview(b);
    try testing.expectEqual(first, second);
    try testing.expectEqualStrings(b, app.panes.get(second).?.md_preview.path);
    try testing.expectEqual(@as(usize, 1), app.panes.count());
    // Glancing back at a.md replaces it again (no tab for a.md survived).
    _ = try app.openPreview(a);
    try testing.expectEqualStrings(a, app.panes.get(first).?.md_preview.path);
    // Typing swaps the editor in: an editor, never a preview — the next
    // glance opens a new preview tab beside it instead of replacing it.
    try app.handle(.{ .key = Key.char('Z') });
    const eid = app.active.?;
    try testing.expect(app.panes.get(eid).?.* == .editor);
    try testing.expect(app.panes.get(first) == null);
    const third = try app.openPreview(c);
    try testing.expect(third != eid);
    try testing.expect(app.panes.get(eid).?.* == .editor);
    try testing.expectEqual(@as(usize, 2), app.panes.count());
    // markdown.preview on the editor: a permanent preview a glance does not take.
    app.showPane(eid);
    try command.run(&app, .{ .static = .@"markdown.preview" });
    const explicit = app.active.?;
    try testing.expect(!app.panes.get(explicit).?.md_preview.is_preview);
    _ = try app.openPreview(b);
    try testing.expect(app.panes.get(explicit).?.* == .md_preview);
    try testing.expectEqualStrings(a, app.panes.get(explicit).?.md_preview.path);
    try testing.expectEqualStrings(b, app.panes.get(third).?.md_preview.path);
    // A request opened from a glance is a preview until it is edited.
    const http_app = @import("http.zig");
    const rid = try http_app.openFile(&app, r, true);
    try testing.expect(app.panes.get(rid).?.request.is_preview);
    try testing.expect(!app.panes.get(rid).?.request.edited);
    // A glanced pane is browsed: a bare key never edits it (`x` goes to
    // the chord chain); Enter enters the URL field, then the key lands.
    try app.handle(.{ .key = Key.char('x') });
    try testing.expect(!app.panes.get(rid).?.request.edited);
    try app.handle(.{ .key = Key.named(.enter) });
    try app.handle(.{ .key = Key.char('x') });
    try testing.expect(app.panes.get(rid).?.request.edited);
}

test "markdown.cycle_engine walks builtin → glow → pandoc → builtin, a custom command back to builtin, writing the home config each time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    const Config = app_mod.Config;
    try command.run(&app, .{ .static = .@"markdown.cycle_engine" });
    try std.testing.expectEqual(Config.MdEngine.glow, app.cfg.ui.md_preview_engine);
    try std.testing.expectEqualStrings("markdown engine: glow", app.lastToast().?);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(app.frame.allocator(), &.{ root, "config.zon" }), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".md_preview_engine = .glow") != null);
    try command.run(&app, .{ .static = .@"markdown.cycle_engine" });
    try std.testing.expectEqual(Config.MdEngine.pandoc, app.cfg.ui.md_preview_engine);
    try command.run(&app, .{ .static = .@"markdown.cycle_engine" });
    try std.testing.expectEqual(Config.MdEngine.builtin, app.cfg.ui.md_preview_engine);
    app.cfg.ui.md_preview_engine = .{ .custom = "glow -s dark" };
    try command.run(&app, .{ .static = .@"markdown.cycle_engine" });
    try std.testing.expectEqual(Config.MdEngine.builtin, app.cfg.ui.md_preview_engine);
    try std.testing.expectEqualStrings("markdown engine: builtin", app.lastToast().?);
}
