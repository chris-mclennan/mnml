//! `find.*` runners and the find bar's reactions: the bar opens over the
//! active pane, matches update as the query is typed, Enter lands on
//! the first match at or after the cursor (before it for vim `?`) and
//! toasts `match N/M`; `find.next` / `find.prev` step and toast the
//! same; `find.replace` prompts `Replace N× "q" with` and splices every
//! match as one undo step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const Prompt = app_mod.Prompt;
const FindBar = app_mod.FindBar;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const find_mod = @import("find.zig");
const EditOp = @import("../editor/edit_op.zig").EditOp;

pub const table = .{
    .@"find.find" = &open,
    .@"find.find_backward" = &openBackward,
    .@"find.next" = &next,
    .@"find.prev" = &prev,
    .@"find.replace" = &replace,
    .@"find.clear" = &clear,
    .@"find.clear_and_deselect" = &clearAndDeselect,
    .@"find.word_forward" = &wordForward,
    .@"find.word_backward" = &wordBackward,
    .@"find.selection_forward" = &selectionForward,
    .@"find.selection_backward" = &selectionBackward,
    .@"find.select_match_forward" = &selectMatchForward,
    .@"find.select_match_backward" = &selectMatchBackward,
    .@"find.toggle_regex" = &toggleRegex,
};

fn open(app: *App) CommandError!void {
    return openBar(app, false);
}

fn openBackward(app: *App) CommandError!void {
    return openBar(app, true);
}

/// Open the bar over the active editor, remembering its find state so
/// Esc can put it back. A bar already open just refocuses.
pub fn openBar(app: *App, reverse: bool) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const e = app.panes.editor(id) orelse return app.diag.fail(app.frame.allocator(), "find only works in editor panes", .{});
    if (app.find_bar) |*fb| {
        if (fb.pane == id) {
            fb.reverse = reverse;
            app.focus = .overlay;
            return;
        }
        app.closeFindBar(false);
    }
    const snap = e.find.clone() catch return error.OutOfMemory;
    const fb: app_mod.FindBarState = .{ .pane = id, .snapshot = snap, .snapshot_cursor = e.buf.editor.cursor, .reverse = reverse };
    // The live preview starts from a blank slate; Esc restores the snapshot.
    e.find.clear();
    app.find_bar = fb;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The query changed: recompute the pane's matches, keep the cursor.
pub fn liveUpdate(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const e = app.panes.editor(fb.pane) orelse return;
    const q = fb.state.query.items;
    if (q.len == 0) {
        e.find.clear();
    } else {
        try e.find.setQuery(q, e.buf.editor.bytes(), if (fb.state.match_case) true else app.search_case);
        e.find.current = if (fb.reverse) e.find.indexBefore(e.buf.editor.cursor) else e.find.indexAtOrAfter(e.buf.editor.cursor);
    }
    app.needs_render = true;
}

/// Enter in the bar: land on the match and close (or chain to replace).
pub fn acceptFromBar(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const pane = fb.pane;
    const reverse = fb.reverse;
    const chain = fb.chain_to_replace;
    const e = app.panes.editor(pane) orelse {
        app.closeFindBar(false);
        return;
    };
    const q = fb.state.query.items;
    if (q.len == 0) {
        app.closeFindBar(true);
        return;
    }
    try e.find.setQuery(q, e.buf.editor.bytes(), if (fb.state.match_case) true else app.search_case);
    if (e.find.matches.items.len == 0) {
        app.toast("no matches for \"{s}\"", .{q});
        app.closeFindBar(false);
        return;
    }
    const idx = (if (reverse) e.find.indexBefore(e.buf.editor.cursor) else e.find.indexAtOrAfter(e.buf.editor.cursor)) orelse 0;
    e.find.current = idx;
    e.buf.editor.setCursor(e.find.matches.items[idx].start);
    e.buf.editor.goal_col = null;
    app.toast("match {d}/{d}", .{ idx + 1, e.find.matches.items.len });
    app.closeFindBar(false);
    if (chain) try openReplacePrompt(app);
}

/// `find.next` / `find.prev` and the bar's ↓ / ↑.
pub fn stepFind(app: *App, delta: i32) Allocator.Error!void {
    const id = app.active orelse return;
    const e = app.panes.editor(id) orelse return;
    if (!e.find.isActive()) {
        app.toast("no active find — use / or Ctrl+F first", .{});
        return;
    }
    if (e.find.matches.items.len == 0) {
        app.toast("no matches for \"{s}\"", .{e.find.query.items});
        return;
    }
    // Without a current match (a cleared cursor jump), step from the cursor.
    if (e.find.current == null) {
        e.find.current = if (delta > 0) e.find.indexAtOrAfter(e.buf.editor.cursor) else e.find.indexBefore(e.buf.editor.cursor);
    } else {
        _ = e.find.step(delta);
    }
    const idx = e.find.current.?;
    e.buf.editor.setCursor(e.find.matches.items[idx].start);
    e.buf.editor.goal_col = null;
    app.toast("match {d}/{d}", .{ idx + 1, e.find.matches.items.len });
    app.needs_render = true;
}

fn next(app: *App) CommandError!void {
    _ = try app.requireEditor();
    try stepFind(app, 1);
}

fn prev(app: *App) CommandError!void {
    _ = try app.requireEditor();
    try stepFind(app, -1);
}

fn replace(app: *App) CommandError!void {
    _ = try app.requireEditor();
    try openReplacePrompt(app);
}

/// `Replace N× "q" with` — or, with no find yet, a find bar that chains
/// into it (vim users get pointed at `:%s`).
pub fn openReplacePrompt(app: *App) Allocator.Error!void {
    const id = app.active orelse return;
    const e = app.panes.editor(id) orelse return;
    if (!e.find.isActive()) {
        if (app.cfg.input_style == .vim) {
            app.toast(":%s/old/new/g — substitute across buffer", .{});
            return;
        }
        openBar(app, false) catch return;
        if (app.find_bar) |*fb| fb.chain_to_replace = true;
        return;
    }
    const n = e.find.matches.items.len;
    if (n == 0) {
        app.toast("no matches to replace — refine the find query", .{});
        return;
    }
    // The prompt borrows its title for its whole life: gpa, freed by
    // `Overlay.deinit`.
    const title = try std.fmt.allocPrint(app.gpa, "Replace {d}× \"{s}\" with", .{ n, e.find.query.items });
    errdefer app.gpa.free(title);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, title), .purpose = .replace, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Splice `replacement` over every match, last to first, as one undo step.
pub fn replaceAll(app: *App, replacement: []const u8) Allocator.Error!void {
    const id = app.active orelse return;
    const e = app.panes.editor(id) orelse return;
    const n = e.find.matches.items.len;
    if (n == 0) {
        app.toast("no matches to replace", .{});
        return;
    }
    const arena = app.frame.allocator();
    var ops: std.ArrayListUnmanaged(EditOp) = .empty;
    var i = n;
    while (i > 0) {
        i -= 1;
        const m = e.find.matches.items[i];
        try ops.append(arena, .{ .replace_range = .{ .start = m.start, .end = m.end, .text = replacement } });
    }
    const atomic: EditOp = .{ .atomic = ops.items };
    _ = try app.applyOps(e, &.{atomic});
    try e.find.recompute(e.buf.editor.bytes());
    app.toast("replaced {d}", .{n});
}

/// Replace the current match only and step to the next (the bar's
/// Enter on the replace field).
pub fn replaceCurrent(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const e = app.panes.editor(fb.pane) orelse return;
    const idx = e.find.current orelse e.find.indexAtOrAfter(e.buf.editor.cursor) orelse {
        app.toast("no matches to replace", .{});
        return;
    };
    const m = e.find.matches.items[idx];
    const text = try app.frame.allocator().dupe(u8, fb.state.replace.items);
    try app.splice(e, m.start, m.end, text);
    try e.find.recompute(e.buf.editor.bytes());
    if (e.find.matches.items.len > 0) {
        e.find.current = e.find.indexAtOrAfter(e.buf.editor.cursor);
        e.buf.editor.setCursor(e.find.matches.items[e.find.current.?].start);
    }
    app.toast("replaced 1 · {d} left", .{e.find.matches.items.len});
}

fn clear(app: *App) CommandError!void {
    const e = try app.requireEditor();
    e.find.clear();
    app.needs_render = true;
}

fn clearAndDeselect(app: *App) CommandError!void {
    const e = try app.requireEditor();
    e.find.clear();
    e.buf.editor.anchor = null;
    // Esc in Normal lands here on every press; only ask the editor when
    // there is something to drop.
    if (e.buf.editor.extra_cursors.items.len > 0) _ = try app.applyOps(e, &.{.clear_extra_cursors});
    app.needs_render = true;
}

fn toggleRegex(app: *App) CommandError!void {
    const e = try app.requireEditor();
    e.find.regex = !e.find.regex;
    app.toast("find: regex {s} (literal matching only in this build)", .{if (e.find.regex) "on" else "off"});
}

/// `*` / `#`: the identifier under the cursor becomes the query.
fn wordSearch(app: *App, forward: bool) CommandError!void {
    const e = try app.requireEditor();
    const text = e.buf.editor.bytes();
    const r = find_mod.wordAt(text, e.buf.editor.cursor) orelse {
        app.toast("no word under cursor", .{});
        return;
    };
    const word = try app.frame.allocator().dupe(u8, text[r.start..r.end]);
    try e.find.setQuery(word, text, app.search_case);
    // Step off the word under the cursor so the jump is a real move.
    e.find.current = if (forward) e.find.indexAtOrAfter(r.end) else e.find.indexBefore(r.start);
    try stepFromCurrent(app, e);
}

fn wordForward(app: *App) CommandError!void {
    return wordSearch(app, true);
}

fn wordBackward(app: *App) CommandError!void {
    return wordSearch(app, false);
}

fn selectionSearch(app: *App, forward: bool) CommandError!void {
    const e = try app.requireEditor();
    const sel = e.buf.editor.selection() orelse return error.NoSelection;
    if (sel[0] == sel[1]) return error.NoSelection;
    const text = e.buf.editor.bytes();
    const q = try app.frame.allocator().dupe(u8, text[sel[0]..sel[1]]);
    e.buf.editor.anchor = null;
    try e.find.setQuery(q, text, app.search_case);
    e.find.current = if (forward) e.find.indexAtOrAfter(sel[1]) else e.find.indexBefore(sel[0]);
    try stepFromCurrent(app, e);
}

fn selectionForward(app: *App) CommandError!void {
    return selectionSearch(app, true);
}

fn selectionBackward(app: *App) CommandError!void {
    return selectionSearch(app, false);
}

fn stepFromCurrent(app: *App, e: *EditorPane) Allocator.Error!void {
    const idx = e.find.current orelse {
        app.toast("no matches for \"{s}\"", .{e.find.query.items});
        return;
    };
    e.buf.editor.setCursor(e.find.matches.items[idx].start);
    e.buf.editor.goal_col = null;
    app.toast("match {d}/{d}", .{ idx + 1, e.find.matches.items.len });
    app.needs_render = true;
}

/// vim `gn` / `gN`: select the next / previous match.
fn selectMatch(app: *App, forward: bool) CommandError!void {
    const e = try app.requireEditor();
    if (!e.find.isActive()) {
        app.toast("gn — no active find (use / first)", .{});
        return;
    }
    if (e.find.matches.items.len == 0) {
        app.toast("gn — no matches", .{});
        return;
    }
    const cur = e.buf.editor.cursor;
    const idx = (if (forward) e.find.indexAtOrAfter(cur + 1) else e.find.indexBefore(cur)) orelse 0;
    const m = e.find.matches.items[idx];
    e.find.current = idx;
    e.buf.editor.setSelection(m.start, m.end);
    e.buf.input.requestVisualMode();
    app.toast("{s} match", .{if (forward) "→" else "←"});
    app.needs_render = true;
}

fn selectMatchForward(app: *App) CommandError!void {
    return selectMatch(app, true);
}

fn selectMatchBackward(app: *App) CommandError!void {
    return selectMatch(app, false);
}

/// The `gn` / `gN` ranges the vim handler reads through `EditCtx`: the
/// match the cursor is on, else the next (previous) one, wrapping.
pub fn seedCtxMatches(e: *EditorPane) void {
    const cur = e.buf.editor.cursor;
    e.buf.find_next = null;
    e.buf.find_prev = null;
    const ms = e.find.matches.items;
    if (ms.len == 0) return;
    for (ms) |m| if (m.start <= cur and cur < m.end) {
        e.buf.find_next = .{ m.start, m.end };
        e.buf.find_prev = .{ m.start, m.end };
        return;
    };
    const nxt = e.find.indexAtOrAfter(cur) orelse 0;
    e.buf.find_next = .{ ms[nxt].start, ms[nxt].end };
    var last: usize = ms.len - 1;
    var i = ms.len;
    while (i > 0) {
        i -= 1;
        if (ms[i].end <= cur) {
            last = i;
            break;
        }
    }
    e.buf.find_prev = .{ ms[last].start, ms[last].end };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

fn appWith(text: []const u8) !App {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    errdefer app.deinit();
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText(text);
    return app;
}

test "find: type → live matches, Enter lands on match 1/3, next/prev wrap, no-match query says so" {
    var app = try appWith("alpha\nbeta\nalpha\ngamma\nalpha\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    try t.expect(app.find_bar != null);
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    const e = app.activeEditor().?;
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar == null);
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.next" });
    try t.expectEqualStrings("match 2/3", app.lastToast().?);
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"find.next" });
    try command.run(&app, .{ .static = .@"find.next" });
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.prev" });
    try t.expectEqualStrings("match 3/3", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.find" });
    for ("zzz") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("no matches for \"zzz\"", app.lastToast().?);
    try t.expectEqual(@as(usize, 0), e.find.matches.items.len);
}

test "find: Esc restores the previous find state; replace prompts and splices every match" {
    var app = try appWith("alpha beta alpha gamma alpha");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const e = app.activeEditor().?;
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    try command.run(&app, .{ .static = .@"find.find" });
    for ("betafoo") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(@as(usize, 0), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqualStrings("alpha", e.find.query.items);
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    try command.run(&app, .{ .static = .@"find.replace" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Replace 3× \"alpha\" with", app.overlay.prompt.state.title);
    for ("DELTA") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("DELTA beta DELTA gamma DELTA", e.buf.editor.bytes());
    try t.expectEqualStrings("replaced 3", app.lastToast().?);
    try t.expect(e.buf.dirty);
    // One undo step for the whole run.
    _ = try app.applyOps(e, &.{.undo});
    try t.expectEqualStrings("alpha beta alpha gamma alpha", e.buf.editor.bytes());
}
