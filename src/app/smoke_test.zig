//! The headless smoke test: an `App` on the testing allocator driven
//! the way the terminal loop drives it — keys in, frames out — through
//! the standard keymap, the vim keymap, `:A`, and the close prompt.

const std = @import("std");
const t = std.testing;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const command = @import("../core/command.zig");
const screen_mod = @import("../ipc/screen.zig");
const keymap = @import("../core/keymap.zig");

const Smoke = struct {
    app: App,
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Smoke {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try realRoot(&tmp, t.allocator);
        errdefer t.allocator.free(root);
        const app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 16 });
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(s: *Smoke) void {
        s.app.deinit();
        t.allocator.free(s.root);
        s.tmp.cleanup();
    }

    fn open(s: *Smoke, rel: []const u8) !void {
        const path = try std.fs.path.join(t.allocator, &.{ s.root, rel });
        defer t.allocator.free(path);
        _ = try s.app.openPath(path);
    }

    /// Space-separated tokens: a key spec (`ctrl+s`, `enter`, `space`,
    /// a single char) is one key; any other word is typed char by char.
    fn keys(s: *Smoke, spec: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, spec, ' ');
        while (it.next()) |tok| {
            if (keymap.parseKeySpec(tok)) |k| {
                const is_spec = tok.len == 1 or std.mem.indexOfScalar(u8, tok, '+') != null or k.code != .char or k.code.char == ' ';
                if (is_spec) {
                    try s.app.handle(.{ .key = k });
                    continue;
                }
            }
            for (tok) |c| try s.app.handle(.{ .key = Key.char(c) });
        }
        try s.app.tick(App.nowMs(t.io));
        try s.app.render();
    }

    fn screen(s: *Smoke) ![]u8 {
        try s.app.render();
        return screen_mod.toTestText(t.allocator, &s.app.screen);
    }

    fn file(s: *Smoke, rel: []const u8) ![]u8 {
        return s.tmp.dir.readFileAlloc(t.io, rel, t.allocator, .limited(4096));
    }
};

test "smoke: open, type under the standard keymap, ctrl+s writes the file" {
    var s = try Smoke.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "first line" });
    try s.open("notes.txt");
    try s.keys("TYPED space");
    try t.expect(s.app.activeEditor().?.buf.doc.dirty);
    const txt = try s.screen();
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "TYPED first line") != null);
    try s.keys("ctrl+s");
    try t.expect(!s.app.activeEditor().?.buf.doc.dirty);
    const back = try s.file("notes.txt");
    defer t.allocator.free(back);
    try t.expectEqualStrings("TYPED first line\n", back); // save adds the terminating newline
}

test "smoke: editor.use_vim makes dd delete a line and u undo it" {
    var s = try Smoke.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree" });
    try s.open("a.txt");
    try command.run(&s.app, .{ .static = .@"editor.use_vim" });
    try s.keys("d d");
    try t.expectEqualStrings("two\nthree", s.app.activeEditor().?.buf.editor.bytes());
    const txt = try s.screen();
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "NORMAL") != null);
    try s.keys("u");
    try t.expectEqualStrings("one\ntwo\nthree", s.app.activeEditor().?.buf.editor.bytes());
    try t.expect(!s.app.activeEditor().?.buf.doc.dirty);
}

test "smoke: a second file, :A flips to its test twin and back" {
    var s = try Smoke.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(t.io, "src");
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "src/foo.rs", .data = "fn foo() {}" });
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "src/foo_test.rs", .data = "// test for foo" });
    try s.open("src/foo.rs");
    const first = s.app.active.?;
    try command.run(&s.app, .{ .static = .@"editor.use_vim" });
    try s.keys(": A enter");
    try t.expect(s.app.active.? != first);
    try t.expectEqualStrings("foo_test.rs", s.app.panes.get(s.app.active.?).?.title());
    try s.keys(": A enter");
    try t.expectEqual(first, s.app.active.?);
    try t.expectEqual(@as(usize, 2), s.app.panes.count());
}

test "smoke: app.quit with a dirty buffer raises the confirm overlay; Cancel keeps everything" {
    var s = try Smoke.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "x" });
    try s.open("notes.txt");
    try s.keys("more");
    try command.run(&s.app, .{ .static = .@"app.quit" });
    try t.expect(!s.app.quit);
    try t.expect(s.app.overlay == .confirm);
    const txt = try s.screen();
    defer t.allocator.free(txt);
    // // changed (bottom-row): the quit box names the buffers.
    try t.expect(std.mem.indexOf(u8, txt, "Quit mnml?") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Unsaved: notes.txt") != null);
    // // changed (one-confirm): one bracketed button row in every box.
    try t.expect(std.mem.indexOf(u8, txt, "[Q]uit anyway") != null);
    try s.keys("c");
    try t.expect(s.app.overlay == .none);
    try t.expect(!s.app.quit);
    try t.expect(s.app.activeEditor().?.buf.doc.dirty);
    try t.expect(s.app.focus == .pane);
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
