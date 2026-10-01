//! The bottom row's own `:` line — the one the whole app shares, as
//! against the per-editor `:` the vim handler owns.
//!
//! The vim handler's `:` belongs to a buffer: it needs an editor pane,
//! and it needs the vim profile. Neither holds when the tree has the
//! keys, when a terminal pane is focused, or when the user is in the
//! standard profile at all — and in every one of those a `:` line is
//! still the shortest way to a command. So this state lives on the app,
//! opens from any focus in either profile, and paints on the same row
//! (`render.drawCmdline` prefers it), which is how the reference editor
//! splits the two as well.
//!
//! Two ways in, both of them deliberately hard to miss:
//!
//!   * `Ctrl+;` — a global chord, dispatched above the chord chain so a
//!     half-typed leader sequence cannot swallow it;
//!   * a click anywhere on the bottom row, which is otherwise dead
//!     space and gives the mouse a route to the `:` line without
//!     knowing the chord at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = @import("../core/key.zig").Key;

/// The typed line and the caret inside it, both owned by the app.
pub const State = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// Byte offset of the caret within `text`.
    caret: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.text.deinit(gpa);
    }
};

/// Open the line, empty. Already open is a no-op — a second `Ctrl+;`
/// (or a second click on the row) must not wipe what is half typed.
pub fn open(app: *App) void {
    if (app.cmdline != null) return;
    app.cmdline = .{};
    app.needs_render = true;
}

pub fn close(app: *App) void {
    if (app.cmdline) |*c| c.deinit(app.gpa);
    app.cmdline = null;
    app.needs_render = true;
}

/// // changed (edge-grip): whether ANY `:` line owns the bottom row —
/// the app's own or the active buffer's, the two `render.drawCmdline`
/// paints in that order. The launcher dock asks before it reveals over
/// that row: a strip that covered a half-typed command would be the
/// one reveal the user could not have wanted.
pub fn anyOpen(app: *App) bool {
    if (app.cmdline != null) return true;
    const e = app.activeEditor() orelse return false;
    return e.buf.input.cmdlineGet() != null;
}

/// A press that landed anywhere but the bar itself, while the line is
/// open — the way a text field loses focus when you click off it.
///
/// An EMPTY line closes. Opened by a stray click on the bottom row and
/// then left alone, a bare `:` with a caret is indistinguishable from a
/// blank row that grew an extra line, while every key quietly goes to
/// it; nothing but Esc got it back, and Esc is not a thing you try
/// against a row you did not know was listening.
///
/// A line with TYPED TEXT stays. The user is mid-command, and losing a
/// half-typed `:w some/long/path` to a click meant for the tree is the
/// worse of the two mistakes. The caret does not move either — the
/// press was not on the line, so it says nothing about where in the
/// line the user wants to be.
///
/// Returns true when it closed one, so a caller can tell the click
/// consumed something. Either way the press then goes on to whatever
/// it landed on: this only takes the focus away, never the click.
pub fn clickAway(app: *App) bool {
    const c = app.cmdline orelse return false;
    if (c.text.items.len > 0) return false;
    close(app);
    return true;
}

/// Insert `text` at the caret — a typed char, or a paste. Control
/// characters and newlines are dropped so a multi-line paste stays one
/// line (the `:` line has nowhere to put the rest).
pub fn insert(app: *App, text: []const u8) Allocator.Error!void {
    const c = &(app.cmdline orelse return);
    var at = c.caret;
    for (text) |ch| {
        if (ch == '\n' or ch == '\r' or ch < 0x20) continue;
        try c.text.insert(app.gpa, at, ch);
        at += 1;
    }
    c.caret = at;
    app.needs_render = true;
}

/// Run the line and close. An empty line just closes, as vim's Enter
/// on an empty `:` does.
fn commit(app: *App) Allocator.Error!void {
    const c = &(app.cmdline orelse return);
    const line = try app.frame.allocator().dupe(u8, std.mem.trim(u8, c.text.items, " \t"));
    close(app);
    if (line.len == 0) return;
    const dispatch = @import("dispatch.zig");
    try dispatch.runExLine(app, line);
}

/// The line's keys while it is open. Returns false for a key it does
/// not want, so the caller can carry on with it.
pub fn key(app: *App, k: Key) Allocator.Error!bool {
    const c = &(app.cmdline orelse return false);
    switch (k.code) {
        .esc => {
            close(app);
            return true;
        },
        .enter => {
            try commit(app);
            return true;
        },
        .backspace => {
            if (c.caret > 0) {
                const start = prevBoundary(c.text.items, c.caret);
                c.text.replaceRange(app.gpa, start, c.caret - start, &.{}) catch return error.OutOfMemory;
                c.caret = start;
            } else close(app);
            app.needs_render = true;
            return true;
        },
        .delete => {
            if (c.caret < c.text.items.len) {
                const end = nextBoundary(c.text.items, c.caret);
                c.text.replaceRange(app.gpa, c.caret, end - c.caret, &.{}) catch return error.OutOfMemory;
            }
            app.needs_render = true;
            return true;
        },
        .left => {
            c.caret = prevBoundary(c.text.items, c.caret);
            app.needs_render = true;
            return true;
        },
        .right => {
            c.caret = nextBoundary(c.text.items, c.caret);
            app.needs_render = true;
            return true;
        },
        .home => {
            c.caret = 0;
            app.needs_render = true;
            return true;
        },
        .end => {
            c.caret = c.text.items.len;
            app.needs_render = true;
            return true;
        },
        .char => |cp| {
            // `Ctrl+;` again while it is open: leave it alone rather
            // than typing a `;`, so the chord is idempotent.
            if (k.mods.ctrl and cp == ';') return true;
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return true;
            try insert(app, buf[0..n]);
            return true;
        },
        else => return false,
    }
}

/// The line as the row paints it: `:` then the text with the caret
/// mark set into it, the shape the vim `:` line uses too.
pub fn display(app: *const App, arena: Allocator, ascii: bool) Allocator.Error!?[]const u8 {
    const c = app.cmdline orelse return null;
    const caret = @min(c.caret, c.text.items.len);
    return try std.fmt.allocPrint(arena, ":{s}{s}{s}", .{
        c.text.items[0..caret],
        if (ascii) "|" else "▏",
        c.text.items[caret..],
    });
}

fn prevBoundary(s: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = @min(at, s.len);
    i -= 1;
    while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn nextBoundary(s: []const u8, at: usize) usize {
    if (at >= s.len) return s.len;
    var i = at + 1;
    while (i < s.len and s[i] & 0xC0 == 0x80) i += 1;
    return i;
}

// ── tests ──

const t = std.testing;

test "the line types, edits at the caret, and runs on Enter" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    try t.expect(app.cmdline == null);
    open(&app);
    try t.expect(app.cmdline != null);
    // A second open keeps what is typed.
    try insert(&app, "noh");
    open(&app);
    try t.expectEqualStrings("noh", app.cmdline.?.text.items);

    // The caret walks and edits mid-line.
    try t.expect(try key(&app, Key.named(.left)));
    try t.expect(try key(&app, Key.char('X')));
    try t.expectEqualStrings("noXh", app.cmdline.?.text.items);
    try t.expect(try key(&app, Key.named(.backspace)));
    try t.expectEqualStrings("noh", app.cmdline.?.text.items);
    try t.expect(try key(&app, Key.named(.home)));
    try t.expectEqual(@as(usize, 0), app.cmdline.?.caret);
    try t.expect(try key(&app, Key.named(.end)));
    try t.expectEqual(@as(usize, 3), app.cmdline.?.caret);

    // The paint shape carries the caret mark.
    const shown = (try display(&app, app.frame.allocator(), false)).?;
    try t.expectEqualStrings(":noh▏", shown);

    // Enter runs it and closes.
    try t.expect(try key(&app, Key.named(.enter)));
    try t.expect(app.cmdline == null);
    try t.expectEqualStrings("noh", app.cmd_history.getLast());
}

test "Esc drops the line, backspace on an empty line closes it, an empty Enter just closes" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    open(&app);
    try insert(&app, "wq");
    try t.expect(try key(&app, Key.named(.esc)));
    try t.expect(app.cmdline == null);
    try t.expectEqual(@as(usize, 0), app.cmd_history.items.len);

    open(&app);
    try t.expect(try key(&app, Key.named(.backspace)));
    try t.expect(app.cmdline == null);

    open(&app);
    try t.expect(try key(&app, Key.named(.enter)));
    try t.expect(app.cmdline == null);
    try t.expectEqual(@as(usize, 0), app.cmd_history.items.len);
}

test "the chord opens the line from any focus and outranks a half-typed chord chain" {
    const dispatch = @import("dispatch.zig");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    // Pane focus.
    try dispatch.key(&app, Key.ctrl(';'));
    try t.expect(app.cmdline != null);
    try t.expect(try key(&app, Key.named(.esc)));

    // Tree focus.
    app.focus = .tree;
    app.tree.visible = true;
    try dispatch.key(&app, Key.ctrl(';'));
    try t.expect(app.cmdline != null);
    try t.expect(try key(&app, Key.named(.esc)));

    // Mid-chord: `ctrl+k` leaves a chain pending. The chord still opens
    // the line, and the dangling chain goes — the reference editor moved
    // this above its own chord dispatch for exactly this report (it
    // worked in tree focus and failed in a pane, where a leader chord
    // was left hanging).
    app.focus = .{ .pane = app.active.? };
    try dispatch.key(&app, Key.ctrl('k'));
    try t.expect(app.chord.len > 0);
    try dispatch.key(&app, Key.ctrl(';'));
    try t.expect(app.cmdline != null);
    try t.expectEqual(@as(usize, 0), app.chord.len);

    // The vim profile binds it too.
    try t.expect(try key(&app, Key.named(.esc)));
    try app.setInputStyle(.vim);
    try dispatch.key(&app, Key.ctrl(';'));
    try t.expect(app.cmdline != null);
    try t.expect(try key(&app, Key.named(.esc)));
}

test "a click off the bar closes an empty line; a half-typed one survives it" {
    const dispatch = @import("dispatch.zig");
    const render = @import("render.zig");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();

    // The bottom row is the last one; a frame registers its hit.
    // // changed (dock-grip-row): under the default `.inner` the
    // launcher dock's grip sits above the statusline, with the strip
    // it summons, so the whole row — its middle too — is the line's.
    const bar_y: u16 = 23;
    try app.render();
    const under = app.hits.at(60, bar_y).?;
    try t.expect(under == .button);
    try t.expectEqual(@intFromEnum(render.Button.cmdline_bar), under.button);
    try t.expectEqual(@intFromEnum(render.Button.cmdline_bar), app.hits.at(39, bar_y).?.button);

    const press = struct {
        fn at(a: *App, x: u16, y: u16) !void {
            try a.render();
            try dispatch.mouse(a, .{ .x = x, .y = y, .kind = .press, .button = .left }, 1);
        }
    };

    // A click on the row opens it; a second click on the row is a
    // no-op — the row is the line's own, so it never closes it.
    try press.at(&app, 60, bar_y);
    try t.expect(app.cmdline != null);
    try press.at(&app, 10, bar_y);
    try t.expect(app.cmdline != null);

    // A click anywhere else, with nothing typed, takes the focus away.
    try press.at(&app, 5, 5);
    try t.expect(app.cmdline == null);

    // A right click off the bar does it too.
    try press.at(&app, 60, bar_y);
    try t.expect(app.cmdline != null);
    try app.render();
    try dispatch.mouse(&app, .{ .x = 5, .y = 5, .kind = .press, .button = .right }, 1);
    try t.expect(app.cmdline == null);

    // Half typed, the line stays and keeps its text and caret: losing
    // it to a stray click is the worse mistake.
    try press.at(&app, 60, bar_y);
    try insert(&app, "wq");
    try t.expect(try key(&app, Key.named(.left)));
    try press.at(&app, 5, 5);
    try t.expect(app.cmdline != null);
    try t.expectEqualStrings("wq", app.cmdline.?.text.items);
    try t.expectEqual(@as(usize, 1), app.cmdline.?.caret);
}

test "a paste stays on one line and control characters are dropped" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    open(&app);
    try insert(&app, "set num\nber\ttail");
    try t.expectEqualStrings("set numbertail", app.cmdline.?.text.items);
}
