//! `markdown.link_check`: every `[label](target)` in the workspace's
//! markdown whose target is a path that names no file, in the quickfix
//! pane. URLs (anything with a scheme) and pure anchors are not paths;
//! a `path#anchor` / `path?query` checks the path. A target is looked
//! for beside its file first, then — when it starts with `/` — at the
//! workspace root, the way a repo's docs usually mean it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const ListPane = @import("pane.zig").ListPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");
const cmd_view = @import("cmd_view.zig");

pub const table = .{
    .@"markdown.link_check" = &linkCheck,
};

const md_exts = [_][]const u8{ ".md", ".mdx", ".markdown", ".mkd" };
const max_file_bytes = 4 * 1024 * 1024;

fn isMarkdown(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (md_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// One `[label](target)` in a line: `col` is the 0-based index of the
/// target's first byte.
const Link = struct { col: usize, target: []const u8 };

/// The links of one line, left to right. Not a markdown parser — just
/// enough to find a path: a label may nest brackets one level deep,
/// the target is the first word inside the parens (a `"title"` after
/// it is dropped), and `<>` around it is stripped.
const Links = struct {
    line: []const u8,
    i: usize = 0,

    fn next(self: *Links) ?Link {
        const s = self.line;
        while (self.i < s.len) {
            if (s[self.i] != '[') {
                self.i += 1;
                continue;
            }
            var j = self.i + 1;
            var depth: usize = 1;
            while (j < s.len) : (j += 1) {
                switch (s[j]) {
                    '[' => depth += 1,
                    ']' => depth -= 1,
                    else => {},
                }
                if (depth == 0) break;
            }
            if (j >= s.len) {
                self.i += 1;
                continue;
            }
            const open = j + 1;
            if (open >= s.len or s[open] != '(') {
                self.i = j + 1;
                continue;
            }
            var k = open + 1;
            var parens: usize = 1;
            while (k < s.len) : (k += 1) {
                switch (s[k]) {
                    '(' => parens += 1,
                    ')' => parens -= 1,
                    else => {},
                }
                if (parens == 0) break;
            }
            if (k >= s.len) {
                self.i = s.len;
                return null;
            }
            self.i = k + 1;
            var words = std.mem.tokenizeAny(u8, s[open + 1 .. k], " \t");
            const target = std.mem.trim(u8, words.next() orelse "", "<>");
            if (target.len > 0) return .{ .col = open + 1, .target = target };
        }
        return null;
    }
};

/// `scheme:` in front — `https://`, `mailto:`, `file://`, … — but not
/// a Windows drive letter.
fn isUrlLike(target: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    if (colon < 2) return false;
    for (target[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    return true;
}

/// The path part: everything before the first `#` or `?`.
fn pathPart(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "#?") orelse target.len;
    return target[0..end];
}

fn exists(app: *App, path: []const u8) bool {
    Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    return true;
}

/// Whether `target` (a path, fragment stripped) names a file: beside
/// `parent`, or — when absolute — as written, then under the workspace.
fn resolves(app: *App, arena: Allocator, parent: []const u8, target: []const u8) Allocator.Error!bool {
    if (std.fs.path.isAbsolute(target) or target[0] == '/') {
        if (exists(app, target)) return true;
        return exists(app, try std.fs.path.join(arena, &.{ app.workspace, std.mem.trimStart(u8, target, "/") }));
    }
    return exists(app, try std.fs.path.join(arena, &.{ parent, target }));
}

/// `markdown.link_check`: the walk, the scan, the quickfix.
fn linkCheck(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    var files: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    _ = try cmd_picker.walk(app, &files);
    var entries: std.ArrayListUnmanaged(ListPane.Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.text);
            if (e.path) |p| gpa.free(p);
        }
        entries.deinit(gpa);
    }
    var n_md: usize = 0;
    for (files.items) |rel| {
        if (!isMarkdown(rel)) continue;
        n_md += 1;
        const abs = try app.absPath(rel);
        const text = Io.Dir.cwd().readFileAlloc(app.io, abs, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(text);
        const parent = std.fs.path.dirname(abs) orelse app.workspace;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_idx: usize = 0;
        while (lines.next()) |line| : (line_idx += 1) {
            var links: Links = .{ .line = line };
            while (links.next()) |lk| {
                if (isUrlLike(lk.target)) continue;
                const path = pathPart(lk.target);
                if (path.len == 0) continue;
                if (try resolves(app, arena, parent, path)) continue;
                const entry_text = try std.fmt.allocPrint(gpa, "broken link → {s}", .{lk.target});
                errdefer gpa.free(entry_text);
                try entries.append(gpa, .{
                    .text = entry_text,
                    .path = try gpa.dupe(u8, rel),
                    .line = @intCast(line_idx + 1),
                    .col = @intCast(lk.col + 1),
                });
            }
        }
    }
    if (n_md == 0) {
        app.toast("link check: no markdown files in workspace", .{});
        return;
    }
    if (entries.items.len == 0) {
        app.toast("link check: all good ({d} file(s) scanned)", .{n_md});
        return;
    }
    const n = entries.items.len;
    try @import("quickfix.zig").setAndOpen(app, try entries.toOwnedSlice(gpa), .{});
    app.toast("broken markdown links ({d} across {d} file(s))", .{ n, n_md });
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn collect(line: []const u8, out: []Link) []Link {
    var links: Links = .{ .line = line };
    var n: usize = 0;
    while (links.next()) |lk| : (n += 1) out[n] = lk;
    return out[0..n];
}

test "Links: targets with their columns; titles, <>, nested labels; URLs and drive letters tell apart from paths" {
    var buf: [8]Link = undefined;
    const got = collect("see [a](x.md) and [b [c]](<y z.md> \"t\") or [d](  ) [e](https://h/p) [f", &buf);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("x.md", got[0].target);
    try t.expectEqual(@as(usize, 8), got[0].col);
    try t.expectEqualStrings("y", got[1].target);
    try t.expectEqualStrings("https://h/p", got[2].target);
    try t.expect(isUrlLike("https://h/p"));
    try t.expect(isUrlLike("mailto:x@y"));
    try t.expect(!isUrlLike("C:/x.md"));
    try t.expect(!isUrlLike("docs/a.md"));
    try t.expectEqualStrings("docs/a.md", pathPart("docs/a.md#top"));
    try t.expectEqualStrings("", pathPart("#top"));
    try t.expectEqualStrings("a.md", pathPart("a.md?x=1#y"));
}

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try t.allocator.dupe(u8, pbuf[0..try tmp.dir.realPath(t.io, &pbuf)]);
        errdefer t.allocator.free(root);
        try tmp.dir.createDirPath(t.io, "ws/docs");
        const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
        defer t.allocator.free(ws);
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 30 });
        errdefer app.deinit();
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }
};

fn pathEql(got: []const u8, want: []const u8) bool {
    return got.len == want.len and @import("mnml_sdk").testing.pathStartsWith(got, want);
}

fn hasEntry(entries: []const ListPane.Entry, text: []const u8, path: []const u8, line: u32, col: u32) bool {
    // The entry's path reads with the platform's separator.
    for (entries) |e| if (std.mem.eql(u8, e.text, text) and e.path != null and pathEql(e.path.?, path) and e.line == line and e.col == col) return true;
    return false;
}

test "link_check: the missing targets land in the quickfix with 1-based positions; URLs, anchors and root-anchored paths pass; a clean tree and an empty one each toast" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/README.md", .data = "# Hi\n\nSee [g](docs/guide.md), [gone](docs/missing.md#top), [web](https://example.com), [here](#top) and [root](/docs/guide.md).\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/docs/guide.md", .data = "[back](../README.md) [nowhere](nope.md \"t\")\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/notes.txt", .data = "[not markdown](zzz.md)\n" });
    try command.run(&f.app, .{ .static = .@"markdown.link_check" });
    try t.expectEqualStrings("broken markdown links (2 across 2 file(s))", f.app.lastToast().?);
    const id = f.app.panes.findKind(.list).?;
    const lp = &f.app.panes.get(id).?.list;
    try t.expect(lp.kind == .quickfix);
    try t.expectEqual(@as(usize, 2), lp.entries.items.len);
    try t.expect(hasEntry(lp.entries.items, "broken link → docs/missing.md#top", "README.md", 3, 32));
    try t.expect(hasEntry(lp.entries.items, "broken link → nope.md", "docs/guide.md", 1, 32));
    // The missing files written: all good.
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/docs/missing.md", .data = "" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/docs/nope.md", .data = "" });
    try command.run(&f.app, .{ .static = .@"markdown.link_check" });
    try t.expectEqualStrings("link check: all good (4 file(s) scanned)", f.app.lastToast().?);
    // No markdown at all.
    var g = try Fixture.init();
    defer g.deinit();
    try g.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/a.txt", .data = "[x](y.md)" });
    try command.run(&g.app, .{ .static = .@"markdown.link_check" });
    try t.expectEqualStrings("link check: no markdown files in workspace", g.app.lastToast().?);
    try t.expect(g.app.panes.findKind(.list) == null);
}
