//! The `:` line's completion popup — the app side. The candidates for
//! what is typed, kept in `app.cmd_complete` (the same ring Tab has
//! always cycled) and rebuilt whenever the line changes, so the popup
//! `ui/cmdline_popup.zig` paints is by construction the list Tab, the
//! arrows, Enter and a click act on: one list, every consumer reads it
//! here (Rust's `cmdline_popup_list`, the #1207 lesson).
//!
//! Two hosts hold a `:` line — the app's own (`app/cmdline.zig`, both
//! profiles, `Ctrl+;` or a click on the bottom row) and the vim
//! handler's buffer line — and this module reads and writes whichever
//! is open, so the popup behaves the same over each.
//!
//! What the keys do while the popup is showing (two or more
//! candidates, not dismissed): Tab moves the selection forward and
//! writes it into the line, Shift+Tab moves it back — and once a
//! candidate is in the line Down / Up do the same; over the typed text
//! Up / Down stay the history walk (vim's `c_<Up>`, prefix-filtered),
//! since the popup came up on its own (the app's own line keeps no
//! history, so there the arrows always walk the popup). Enter runs the
//! line (which already holds the selection), and typing narrows the
//! list. Esc takes back the last thing: while the line is still
//! the typed text it puts the popup — which came up on its own — away
//! and leaves the line, and a second Esc closes the line; once a
//! candidate has been written into the line (Tab, an arrow, a click)
//! Esc closes the line as it always has, so one Esc still bails out
//! after a Tab, vim's habit. A single candidate shows no popup, and
//! Tab still completes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const CmdComplete = app_mod.CmdComplete;
const dispatch = @import("dispatch.zig");
const Key = @import("../core/key.zig").Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/cmdline_popup.zig");

/// What the painter gets: the labels (the candidate past the line's
/// head — `apple.md` for `:e ap`, the id itself for the first token)
/// and which one is selected.
pub const List = struct {
    labels: []const []const u8,
    selected: usize,
};

/// The open `:` line's text, whichever host holds it: the app's own
/// line wins, as it does on the row (`render.drawCmdline`).
pub fn currentLine(app: *App) ?[]const u8 {
    if (app.cmdline) |c| return c.text.items;
    const e = app.activeEditor() orelse return null;
    return e.buf.input.cmdlineGet();
}

fn writeLine(app: *App, text: []const u8) Allocator.Error!void {
    if (app.cmdline) |*c| {
        c.text.clearRetainingCapacity();
        try c.text.appendSlice(app.gpa, text);
        c.caret = c.text.items.len;
        app.needs_render = true;
        return;
    }
    const e = app.activeEditor() orelse return;
    try e.buf.input.cmdlineSet(text);
    app.needs_render = true;
}

/// Whether the ring describes `line`: the text it was built for, or
/// the candidate it last wrote.
fn matches(c: *const CmdComplete, line: []const u8) bool {
    if (std.mem.eql(u8, c.prefix, line)) return true;
    return c.candidates.len > 0 and c.idx < c.candidates.len and std.mem.eql(u8, c.candidates[c.idx], line);
}

fn drop(app: *App) void {
    if (app.cmd_complete) |*c| c.deinit(app.gpa);
    app.cmd_complete = null;
}

/// Rebuild the ring for the line as it is now, when the line has
/// changed since it was built. No line → no ring; an empty line → no
/// ring either (every id matches an empty token, and a wall of the
/// whole registry over a bare `:` is not a suggestion).
pub fn refresh(app: *App) Allocator.Error!void {
    const line = currentLine(app) orelse return drop(app);
    if (app.cmd_complete) |*c| {
        if (matches(c, line)) return;
        drop(app);
    }
    if (line.len == 0) return;
    const cands = try dispatch.cmdlineCandidates(app, app.gpa, line);
    if (cands.len == 0) {
        app.gpa.free(cands);
        return;
    }
    errdefer {
        for (cands) |c| app.gpa.free(c);
        app.gpa.free(cands);
    }
    const prefix = try app.gpa.dupe(u8, line);
    app.cmd_complete = .{ .prefix = prefix, .candidates = cands, .idx = 0 };
}

/// The ring, if it is the popup's: built for the open line, two or
/// more candidates, not dismissed.
fn live(app: *App) ?*CmdComplete {
    const line = currentLine(app) orelse return null;
    const c = &(app.cmd_complete orelse return null);
    if (c.dismissed or !matches(c, line) or !view.shows(c.candidates.len)) return null;
    return c;
}

pub fn showing(app: *App) bool {
    return live(app) != null;
}

/// The painter's data, on `arena`; null when nothing shows.
pub fn list(app: *App, arena: Allocator) Allocator.Error!?List {
    const c = live(app) orelse return null;
    const head_len = if (std.mem.lastIndexOfScalar(u8, c.prefix, ' ')) |i| i + 1 else 0;
    const labels = try arena.alloc([]const u8, c.candidates.len);
    for (c.candidates, 0..) |cand, i| labels[i] = if (cand.len >= head_len) cand[head_len..] else cand;
    return .{ .labels = labels, .selected = @min(c.idx, c.candidates.len - 1) };
}

/// Move the selection by `delta` and write it into the line. The line
/// already on a candidate moves off it; the typed text lands on the
/// selection itself going forward (the first Tab writes row 0) and on
/// the last candidate going back (vim's Shift+Tab).
pub fn cycle(app: *App, delta: i8) Allocator.Error!void {
    try refresh(app);
    const line = currentLine(app) orelse return;
    const c = &(app.cmd_complete orelse return);
    if (c.candidates.len == 0) return;
    const n: i64 = @intCast(c.candidates.len);
    const on_candidate = c.idx < c.candidates.len and std.mem.eql(u8, c.candidates[c.idx], line);
    if (on_candidate or delta < 0) c.idx = @intCast(@mod(@as(i64, @intCast(c.idx)) + delta, n));
    c.idx = @min(c.idx, c.candidates.len - 1);
    c.dismissed = false;
    try writeLine(app, c.candidates[c.idx]);
}

/// Whether the line holds a candidate the ring wrote (Tab, an arrow,
/// a click), as against the text the user typed.
fn onCandidate(app: *App) bool {
    const c = live(app) orelse return false;
    const line = currentLine(app) orelse return false;
    return c.idx < c.candidates.len and std.mem.eql(u8, c.candidates[c.idx], line);
}

/// Esc while showing over the typed text: the popup goes, the line
/// stays. Typing again rebuilds the ring, so the popup comes back for
/// the next token.
pub fn dismiss(app: *App) void {
    const c = live(app) orelse return;
    c.dismissed = true;
    app.needs_render = true;
}

/// A click on row `idx` of the list the popup drew.
pub fn click(app: *App, idx: usize) Allocator.Error!void {
    const c = live(app) orelse return;
    if (idx >= c.candidates.len) return;
    c.idx = idx;
    try writeLine(app, c.candidates[idx]);
}

/// The keys the popup owns while it is showing, for either host: the
/// arrows walk the list, Esc puts it away — over the typed text only;
/// on a written candidate Esc is the line's own, and closes it. Tab is
/// the hosts' own (the vim handler emits its seams; `appLineKey` below
/// reads it for the app's line). False for any key the popup does not
/// take.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    if (!showing(app)) return false;
    switch (k.code) {
        // Over the typed text the arrows are the line's history walk.
        .down => if (onCandidate(app)) try cycle(app, 1) else return false,
        .up => if (onCandidate(app)) try cycle(app, -1) else return false,
        .esc => {
            if (onCandidate(app)) return false;
            dismiss(app);
        },
        else => return false,
    }
    return true;
}

/// The app's own `:` line, ahead of `cmdline.key`: the popup's keys
/// while it shows, and Tab / Shift+Tab completion at any time (the
/// vim line's handler does this itself).
pub fn appLineKey(app: *App, k: Key) Allocator.Error!bool {
    // The app's line keeps no history: the arrows are the popup's.
    if (showing(app)) switch (k.code) {
        .down => {
            try cycle(app, 1);
            return true;
        },
        .up => {
            try cycle(app, -1);
            return true;
        },
        else => {},
    };
    if (try interceptKey(app, k)) return true;
    switch (k.code) {
        .tab => try cycle(app, 1),
        .backtab => try cycle(app, -1),
        else => return false,
    }
    return true;
}

/// The popup over the `:` line's row, its top capped at `top` (the
/// first row under the tab bar). Nothing under an overlay: the line
/// paints under it too, and the overlay's rows must not compete with
/// the popup's for a click.
pub fn draw(app: *App, ui: Ui, cmdline: Rect, top: u16) Allocator.Error!void {
    if (app.overlay != .none) return;
    if (currentLine(app) == null) return;
    // A line changed by something other than a key (a paste command,
    // a chord) is caught here, so the popup never lags the line.
    try refresh(app);
    const l = (try list(app, ui.arena)) orelse return;
    _ = view.draw(ui, cmdline, top, .{ .labels = l.labels, .selected = l.selected, .border_color = app.cfg.ui.cmdline_popup_border_color });
}

// ── tests ──

const t = std.testing;
const cmdline_mod = @import("cmdline.zig");

fn typeInto(app: *App, text: []const u8) !void {
    for (text) |ch| try dispatch.key(app, Key.char(ch));
}

test "typing on the app's : line builds the list; two or more show, one hides; Esc dismisses, then closes" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try dispatch.key(&app, Key.ctrl(';'));
    try t.expect(app.cmdline != null);
    try t.expect(!showing(&app));
    // `do` matches `dock` (an ex verb) and every id containing `do`.
    try typeInto(&app, "do");
    try t.expect(showing(&app));
    const l = (try list(&app, app.frame.allocator())).?;
    try t.expect(l.labels.len >= 2);
    try t.expectEqual(@as(usize, 0), l.selected);
    var has_dock = false;
    for (l.labels) |lab| if (std.mem.eql(u8, lab, "dock")) {
        has_dock = true;
    };
    try t.expect(has_dock);
    // Down writes the selection into the line; the popup stays on the
    // same list.
    try dispatch.key(&app, Key.named(.down));
    try t.expect(showing(&app));
    try t.expectEqualStrings(l.labels[0], app.cmdline.?.text.items);
    try dispatch.key(&app, Key.named(.down));
    try t.expectEqualStrings(l.labels[1], app.cmdline.?.text.items);
    try dispatch.key(&app, Key.named(.up));
    try t.expectEqualStrings(l.labels[0], app.cmdline.?.text.items);
    // On a written candidate Esc is the line's own: one press closes it.
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(app.cmdline == null);
    try t.expect(app.cmd_complete == null);
    // Over the typed text Esc puts the popup away and keeps the line;
    // the second Esc closes the line.
    try dispatch.key(&app, Key.ctrl(';'));
    try typeInto(&app, "do");
    try t.expect(showing(&app));
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(!showing(&app));
    try t.expectEqualStrings("do", app.cmdline.?.text.items);
    // Typing again brings it back for the new token.
    try dispatch.key(&app, Key.char('c'));
    try t.expect(showing(&app));
    try dispatch.key(&app, Key.named(.backspace));
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(!showing(&app));
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(app.cmdline == null);
    try t.expect(app.cmd_complete == null);

    // A token with exactly one candidate is no popup — but Tab still
    // completes it.
    try dispatch.key(&app, Key.ctrl(';'));
    try typeInto(&app, "tabclos");
    try t.expect(!showing(&app));
    try t.expect(app.cmd_complete != null and app.cmd_complete.?.candidates.len == 1);
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqualStrings("tabclose", app.cmdline.?.text.items);
    try dispatch.key(&app, Key.named(.esc));
}

test "Tab on the app's : line cycles the same list the popup shows, and a click writes a row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try dispatch.key(&app, Key.ctrl(';'));
    try typeInto(&app, "ta");
    try t.expect(showing(&app));
    const l = (try list(&app, app.frame.allocator())).?;
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqualStrings("tab.close", app.cmdline.?.text.items);
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqualStrings("tab.first", app.cmdline.?.text.items);
    // Shift+Tab goes back; from the typed text it lands on the last.
    try dispatch.key(&app, Key.named(.backtab));
    try t.expectEqualStrings("tab.close", app.cmdline.?.text.items);
    try click(&app, l.labels.len - 1);
    try t.expectEqualStrings(l.labels[l.labels.len - 1], app.cmdline.?.text.items);
    try t.expect(showing(&app));
    // Typing again re-filters: the ring is rebuilt for the new text.
    try dispatch.key(&app, Key.char('z'));
    try t.expect(app.cmd_complete == null or !std.mem.eql(u8, app.cmd_complete.?.prefix, "ta"));
}

test "the vim : line: Up over the typed text is the history walk, prefix-filtered; after Tab it walks the popup; one Esc abandons it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try app.setInputStyle(.vim);
    const e = app.activeEditor().?;
    // Run one command so the history has an entry.
    try dispatch.key(&app, Key.char(':'));
    try typeInto(&app, "noh");
    try dispatch.key(&app, Key.named(.enter));
    // Up on `do` is the history walk: no entry starts with `do`, so the
    // line stays (vim's `c_<Up>`) — the auto popup does not take it.
    try dispatch.key(&app, Key.char(':'));
    try typeInto(&app, "do");
    try t.expect(showing(&app));
    try dispatch.key(&app, Key.named(.up));
    try t.expectEqualStrings("do", e.buf.input.cmdlineGet().?);
    // Tab engages the popup; then Up walks it.
    try dispatch.key(&app, Key.named(.tab));
    const first = try t.allocator.dupe(u8, e.buf.input.cmdlineGet().?);
    defer t.allocator.free(first);
    try dispatch.key(&app, Key.named(.down));
    try dispatch.key(&app, Key.named(.up));
    const last = try t.allocator.dupe(u8, e.buf.input.cmdlineGet().?);
    defer t.allocator.free(last);
    try t.expectEqualStrings(first, last);
    try t.expect(!std.mem.eql(u8, last, "noh"));
    try t.expect(showing(&app));
    // On the written candidate Esc closes the line, as vim's does.
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(e.buf.input.cmdlineGet() == null);
    try t.expect(app.cmd_complete == null);
    // Over the typed text too: one Esc abandons the line with the popup
    // on it (Neovim: `:tabn<Tab><Esc>iX<Esc>` inserts the X).
    try dispatch.key(&app, Key.char(':'));
    try typeInto(&app, "do");
    try t.expect(showing(&app));
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(e.buf.input.cmdlineGet() == null);
    try t.expect(app.cmd_complete == null);
    // A popup put away by a click-away keeps the line; Up is then the
    // history walk again.
    try dispatch.key(&app, Key.char(':'));
    try typeInto(&app, "do");
    dismiss(&app);
    try t.expect(!showing(&app));
    try dispatch.key(&app, Key.named(.up));
    try t.expectEqualStrings("do", e.buf.input.cmdlineGet().?);
    // An empty line matches every entry: Up is the newest.
    try dispatch.key(&app, Key.ctrl('u'));
    try dispatch.key(&app, Key.named(.up));
    try t.expectEqualStrings("noh", e.buf.input.cmdlineGet().?);
    // A prefix that one entry has: `n` finds `noh`.
    try dispatch.key(&app, Key.ctrl('u'));
    try dispatch.key(&app, Key.char('n'));
    try dispatch.key(&app, Key.named(.up));
    try t.expectEqualStrings("noh", e.buf.input.cmdlineGet().?);
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(e.buf.input.cmdlineGet() == null);
    try t.expect(app.cmd_complete == null);
}

test "the painter is fed the list at the : line's row and paints above it" {
    const render = @import("render.zig");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try dispatch.key(&app, Key.ctrl(';'));
    try typeInto(&app, "do");
    try app.render();
    // The frame's bottom border is on row 22 (the `:` line is 23), its
    // left edge on column 1 — the cell after the `:`.
    var found: ?u32 = null;
    for (app.hits.items.items) |h| if (h.target == .overlay_item and h.target.overlay_item == 0) {
        found = h.rect.y;
        try t.expectEqual(@as(u16, 2), h.rect.x);
    };
    try t.expect(found != null);
    try t.expectEqual(@intFromEnum(render.Button.cmdline_bar), app.hits.at(60, 23).?.button);
}
