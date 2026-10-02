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
const text_field = @import("../ui/text_field.zig");

/// The typed line and the caret inside it, both owned by the app.
pub const State = struct {
    text: text_field.Buf = .empty,
    /// Byte offset of the caret within `text`.
    caret: usize = 0,
    /// The selection's other end (`text_field.clickSelect`): a click on
    /// the line, a double-click's word, a triple's whole line.
    anchor: ?usize = null,

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

/// Insert `text` at the caret, over the selection — a typed char, or a
/// paste. Control characters and newlines are dropped so a multi-line
/// paste stays one line (the `:` line has nowhere to put the rest).
pub fn insert(app: *App, text: []const u8) Allocator.Error!void {
    const c = if (app.cmdline) |*l| l else return;
    const clean = try app.frame.allocator().alloc(u8, text.len);
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '\n' or ch == '\r' or ch < 0x20) continue;
        clean[n] = ch;
        n += 1;
    }
    try text_field.insertSel(&c.text, &c.caret, &c.anchor, app.gpa, clean[0..n]);
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
        // Backspace on an empty caret closes the line, as vim's does;
        // over a selection it deletes it.
        .backspace => {
            if (c.caret == 0 and text_field.selRange(c.caret, c.anchor) == null) {
                close(app);
            } else _ = try text_field.editKey(&c.text, &c.caret, &c.anchor, app.gpa, k);
            app.needs_render = true;
            return true;
        },
        .delete, .left, .right, .home, .end => {
            _ = try text_field.editKey(&c.text, &c.caret, &c.anchor, app.gpa, k);
            app.needs_render = true;
            return true;
        },
        .char => |cp| {
            // `Ctrl+;` again while it is open: leave it alone rather
            // than typing a `;`, so the chord is idempotent.
            if (k.mods.ctrl and cp == ';') return true;
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            _ = try text_field.editKey(&c.text, &c.caret, &c.anchor, app.gpa, k);
            app.needs_render = true;
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

/// The selection as a byte range of `display`'s string — the `:` and
/// the caret mark counted — for the row to paint; null when none.
pub fn displaySel(app: *const App, ascii: bool) ?[2]usize {
    const c = app.cmdline orelse return null;
    const r = text_field.selRange(@min(c.caret, c.text.items.len), c.anchor) orelse return null;
    if (r[1] > c.text.items.len) return null;
    const mark: usize = if (ascii) 1 else "▏".len;
    // The mark sits at the caret, which is one end of the range.
    return if (c.caret == r[0]) .{ 1 + r[0] + mark, 1 + r[1] + mark } else .{ 1 + r[0], 1 + r[1] };
}

/// A left press `col` cells into the open line (the `:` is cell 0),
/// `clicks` deep: the caret there, the word, the whole line; Shift
/// grows the selection to the press. The row clips rather than
/// scrolls, so a cell is the display's own.
pub fn click(app: *App, col: u16, clicks: u8, shift: bool, method: @import("vaxis").gwidth.Method) void {
    const c = if (app.cmdline) |*l| l else return;
    const text = c.text.items;
    const caret = @min(c.caret, text.len);
    const mark_w: u16 = 1;
    // The cell walk over `:` + before + mark + after.
    var byte: usize = text.len;
    if (col == 0) byte = 0 else {
        var x: u16 = 1;
        var it = @import("../core/utf8.zig").graphemeIterator(text);
        while (it.next()) |g| {
            if (g.start == caret) x += mark_w;
            const w = @import("../core/utf8.zig").width(g.bytes(text), method);
            if (col < x + w) {
                byte = g.start;
                break;
            }
            x += w;
        }
    }
    if (shift) text_field.extendTo(text, &c.caret, &c.anchor, byte) else text_field.clickSelect(text, &c.caret, &c.anchor, byte, clicks);
    app.needs_render = true;
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

test "a double-click on the line takes the word, the row paints it as a selection, a paste replaces it; Backspace over a selection deletes it rather than closing" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    open(&app);
    try insert(&app, "echo alpha beta");
    // `:echo alpha beta▏`: `beta` is cells 12..15; the caret mark is after it.
    click(&app, 13, 2, false, .unicode);
    try t.expectEqual([2]usize{ 11, 15 }, @import("../ui/text_field.zig").selRange(app.cmdline.?.caret, app.cmdline.?.anchor).?);
    try t.expectEqual([2]usize{ 12, 16 }, displaySel(&app, false).?);
    try app.render();
    try t.expect(@import("vaxis").Color.eql(app.screen.readCell(13, 23).?.style.bg, app.theme.selection.bg));
    try t.expect(!@import("vaxis").Color.eql(app.screen.readCell(8, 23).?.style.bg, app.theme.selection.bg));
    try @import("dispatch.zig").paste(&app, "gamma");
    try t.expectEqualStrings("echo alpha gamma", app.cmdline.?.text.items);
    // With the caret at the start the mark takes cell 1, so cell 3 is
    // the `c` of `echo`, byte 1 — the mark's cell is not a byte.
    click(&app, 1, 1, false, .unicode);
    try t.expectEqual(@as(usize, 0), app.cmdline.?.caret);
    click(&app, 3, 1, false, .unicode);
    try t.expectEqual(@as(usize, 1), app.cmdline.?.caret);
    // The whole line, then Backspace: emptied, still open.
    click(&app, 3, 3, false, .unicode);
    try t.expect((try key(&app, Key.named(.backspace))));
    try t.expect(app.cmdline != null);
    try t.expectEqualStrings("", app.cmdline.?.text.items);
}
