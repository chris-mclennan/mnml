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
const RequestPane = @import("request_pane.zig").RequestPane;
const PaneId = app_mod.PaneId;
const Prompt = app_mod.Prompt;
const FindBar = app_mod.FindBar;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const find_mod = @import("find.zig");
const regex = @import("../regex/regex.zig");
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

/// What a find bar searches: an editor's buffer, or a request pane's
/// response — its body, or its headers when that tab is up. The bar,
/// the steps and the count read the same `FindState` either way.
pub const Target = union(enum) {
    editor: *EditorPane,
    request: *RequestPane,

    pub fn of(app: *App, id: PaneId) ?Target {
        if (app.panes.editor(id)) |e| return .{ .editor = e };
        if (app.panes.get(id)) |p| if (p.asRequest()) |rp| return .{ .request = rp };
        return null;
    }

    pub fn find(tg: Target) *find_mod.FindState {
        return switch (tg) {
            .editor => |e| &e.find,
            .request => |rp| &rp.resp_find,
        };
    }

    pub fn text(tg: Target) []const u8 {
        return switch (tg) {
            .editor => |e| e.buf.editor.bytes(),
            .request => |rp| rp.respFindText(),
        };
    }

    pub fn cursor(tg: Target) usize {
        return switch (tg) {
            .editor => |e| e.buf.editor.cursor,
            .request => |rp| rp.resp_cursor,
        };
    }

    pub fn setCursor(tg: Target, byte: usize) void {
        switch (tg) {
            .editor => |e| {
                e.buf.editor.setCursor(byte);
                e.buf.editor.goal_col = null;
            },
            .request => |rp| rp.revealFind(byte),
        }
    }

    /// Where match `idx` puts the cursor: the query's offset applied in
    /// an editor; the match's start in a response.
    pub fn landing(tg: Target, idx: usize) usize {
        const m = tg.find().matches.items[idx];
        return switch (tg) {
            .editor => |e| e.find.offset.landing(e.buf.editor, m.start, m.end),
            .request => m.start,
        };
    }
};

/// The active pane's target, else the diagnostic the editor commands give.
fn requireTarget(app: *App) CommandError!Target {
    const id = app.active orelse return error.NoActivePane;
    if (Target.of(app, id)) |tg| {
        if (tg == .request and tg.request.response() == null) return app.diag.fail(app.frame.allocator(), "find: no response yet", .{});
        return tg;
    }
    return app.diag.fail(app.frame.allocator(), "find only works in editor and request panes", .{});
}

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
    const tg = try requireTarget(app);
    // A response search lands in the Response block, whatever was focused.
    if (tg == .request) tg.request.block = .response;
    if (app.find_bar) |*fb| {
        if (fb.pane == id) {
            fb.reverse = reverse;
            // Ctrl+F on an open bar selects the query (VS Code): typing
            // starts over, a move keeps it.
            fb.state.select_all = fb.state.query.items.len > 0;
            app.focus = .overlay;
            return;
        }
        app.closeFindBar(false);
    }
    const snap = tg.find().clone() catch return error.OutOfMemory;
    var fb: app_mod.FindBarState = .{ .pane = id, .snapshot = snap, .snapshot_cursor = tg.cursor(), .reverse = reverse, .hist_cursor = app.find_history.items.len };
    // The regex chip is sticky per pane (`find.toggle_regex`).
    fb.state.regex = tg.find().regex;
    // The live preview starts from a blank slate; Esc restores the snapshot.
    tg.find().clear();
    app.find_bar = fb;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The query changed: recompute the pane's matches, keep the cursor.
pub fn liveUpdate(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const tg = Target.of(app, fb.pane) orelse return;
    const f = tg.find();
    const q = fb.state.query.items;
    f.regex = fb.state.regex;
    fb.landed = false;
    if (q.len == 0) {
        f.clear();
    } else {
        try f.setQuery(q, tg.text(), if (fb.state.match_case) true else app.search_case);
        f.current = if (fb.reverse) f.indexBefore(tg.cursor()) else f.indexAtOrAfter(tg.cursor());
        // A response follows the live match as it is typed.
        if (tg == .request) if (f.current) |c| tg.request.revealFind(f.matches.items[c].start);
    }
    app.needs_render = true;
}

/// A click on the bar's `.*` / `Aa` chip (`find_bar.hit_regex` /
/// `hit_case`): the same toggle as ctrl+r / ctrl+c.
pub fn chipClick(app: *App, id: u32) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    switch (id) {
        FindBar.hit_regex => fb.state.regex = !fb.state.regex,
        FindBar.hit_case => fb.state.match_case = !fb.state.match_case,
        else => return,
    }
    try liveUpdate(app);
}

/// The reason a regex query matched nothing, for a toast.
fn patternProblem(err: regex.Error) []const u8 {
    return switch (err) {
        error.InvalidPattern => "invalid pattern",
        error.Unsupported => "pattern uses an item this build does not support (\\&, \\%V…)",
        error.TooLong => "pattern too long",
        error.OutOfMemory => "out of memory",
    };
}

/// Enter in the bar. vim's `/` lands on the match and closes; the
/// standard profile keeps the bar (VS Code: Enter = next, Shift+Enter =
/// previous, Esc closes) — the first Enter lands on the current match,
/// the next ones step. A bar that chains into the replace prompt
/// closes either way.
pub fn acceptFromBar(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    if (app.input_style == .vim or fb.chain_to_replace) return acceptAndClose(app);
    const tg = Target.of(app, fb.pane) orelse {
        app.closeFindBar(false);
        return;
    };
    const f = tg.find();
    const q = fb.state.query.items;
    if (q.len == 0) return;
    // Enter remembers the query — a miss too — before the step decides.
    try @import("find_history.zig").push(app, q);
    // Already on the current match (a previous Enter put us there)?
    // Then this one steps; `setQuery` forgets `current`, so ask first.
    const cursor = tg.cursor();
    const was_on: ?usize = if (fb.landed) (if (f.current) |c| (if (c < f.matches.items.len and cursor == f.matches.items[c].start) c else null) else null) else null;
    f.regex = fb.state.regex;
    try f.setQuery(q, tg.text(), if (fb.state.match_case) true else app.search_case);
    const n = f.matches.items.len;
    if (n == 0) {
        if (f.bad_pattern) |err| app.toast("{s}: \"{s}\"", .{ patternProblem(err), q }) else app.toast("no matches for \"{s}\"", .{q});
        return;
    }
    if (was_on) |c| {
        f.current = @min(c, n - 1);
        _ = f.step(if (fb.reverse) -1 else 1);
    } else {
        f.current = (if (fb.reverse) f.indexBefore(cursor) else f.indexAtOrAfter(cursor)) orelse 0;
    }
    try landFromBar(app, fb, tg);
}

/// The cursor goes to the current match and the bar's snapshot moves
/// up to here: Esc from now on keeps the query and the jump.
fn landFromBar(app: *App, fb: *app_mod.FindBarState, tg: Target) Allocator.Error!void {
    const f = tg.find();
    const idx = f.current orelse return;
    tg.setCursor(f.matches.items[idx].start);
    app.toast("match {d}/{d}", .{ idx + 1, f.matches.items.len });
    const snap = f.clone() catch return error.OutOfMemory;
    if (fb.snapshot) |*old| old.deinit();
    fb.snapshot = snap;
    fb.snapshot_cursor = tg.cursor();
    fb.landed = true;
    app.needs_render = true;
}

/// The bar's ↓ / ↑ / Shift+Enter / F3: a step that also commits, so
/// Esc keeps the match it landed on.
pub fn stepFromBar(app: *App, delta: i32) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const tg = Target.of(app, fb.pane) orelse return;
    try stepFind(app, delta);
    if (app.input_style == .vim or tg.find().current == null) return;
    const snap = tg.find().clone() catch return error.OutOfMemory;
    if (fb.snapshot) |*old| old.deinit();
    fb.snapshot = snap;
    fb.snapshot_cursor = tg.cursor();
    fb.landed = true;
}

/// vim's Enter: land on the match and close (or chain to replace).
fn acceptAndClose(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const pane = fb.pane;
    const reverse = fb.reverse;
    const chain = fb.chain_to_replace;
    const tg = Target.of(app, pane) orelse {
        app.closeFindBar(false);
        return;
    };
    const f = tg.find();
    const q = fb.state.query.items;
    if (q.len == 0) {
        app.closeFindBar(true);
        return;
    }
    // Remembered first, so a query that misses is still recallable.
    try @import("find_history.zig").push(app, q);
    // `/pat/e`: what follows an unescaped `/` (`?` for `?`) is a search
    // offset, not pattern (`:help search-offset`).
    var pattern: []const u8 = q;
    var offset: find_mod.Offset = .{};
    if (app.input_style == .vim) if (splitOffset(q, if (reverse) '?' else '/')) |sp| {
        pattern = sp.pattern;
        offset = sp.offset;
    };
    f.regex = fb.state.regex;
    try f.setQuery(pattern, tg.text(), if (fb.state.match_case) true else app.search_case);
    f.offset = offset;
    // `/` and `?` write vim's last search pattern, which `:s//new/` reads.
    try app.noteSearchPattern(pattern);
    if (f.matches.items.len == 0) {
        if (f.bad_pattern) |err| app.toast("{s}: \"{s}\"", .{ patternProblem(err), pattern }) else app.toast("no matches for \"{s}\"", .{pattern});
        app.closeFindBar(false);
        return;
    }
    const idx = (if (reverse) f.indexBefore(tg.cursor()) else f.indexAtOrAfter(tg.cursor())) orelse 0;
    f.current = idx;
    tg.setCursor(tg.landing(idx));
    app.toast("match {d}/{d}", .{ idx + 1, f.matches.items.len });
    app.closeFindBar(false);
    if (chain and tg == .editor) try openReplacePrompt(app);
}

/// `find.next` / `find.prev` and the bar's ↓ / ↑.
pub fn stepFind(app: *App, delta: i32) Allocator.Error!void {
    const id = app.active orelse return;
    const tg = Target.of(app, id) orelse return;
    const f = tg.find();
    if (!f.isActive()) {
        app.toast("no active find — use / or Ctrl+F first", .{});
        return;
    }
    if (f.matches.items.len == 0) {
        app.toast("no matches for \"{s}\"", .{f.query.items});
        return;
    }
    // Without a current match (a cleared cursor jump), step from the cursor.
    if (f.current == null) {
        f.current = if (delta > 0) f.indexAtOrAfter(tg.cursor()) else f.indexBefore(tg.cursor());
    } else {
        _ = f.step(delta);
    }
    const idx = f.current.?;
    tg.setCursor(tg.landing(idx));
    app.toast("match {d}/{d}", .{ idx + 1, f.matches.items.len });
    app.needs_render = true;
}

const SplitQuery = struct { pattern: []const u8, offset: find_mod.Offset };

/// `pat/e+1` → the pattern and its offset; null when there is no
/// unescaped `sep` or what follows it is not an offset (then the whole
/// text is the pattern, as before).
fn splitOffset(q: []const u8, sep: u8) ?SplitQuery {
    var i: usize = 0;
    while (i < q.len) : (i += 1) {
        if (q[i] == '\\') {
            i += 1;
            continue;
        }
        if (q[i] == sep) {
            const off = find_mod.Offset.parse(q[i + 1 ..]) orelse return null;
            return .{ .pattern = q[0..i], .offset = off };
        }
    }
    return null;
}

fn next(app: *App) CommandError!void {
    _ = try requireTarget(app);
    try stepFind(app, 1);
}

fn prev(app: *App) CommandError!void {
    _ = try requireTarget(app);
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
        if (app.input_style == .vim) {
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
    // In regex mode the replacement may name groups (`\1`, `&`), so
    // each match is found again for its groups and expanded.
    var re: ?regex.Regex = if (e.find.regex) regex.Regex.compile(e.find.query.items, .{ .ignore_case = !e.find.case_sensitive }) catch null else null;
    defer if (re) |*r| r.deinit();
    const text = e.buf.editor.bytes();
    var i = n;
    while (i > 0) {
        i -= 1;
        const m = e.find.matches.items[i];
        var rep: []const u8 = replacement;
        if (re) |*r| if (r.find(text, m.start)) |full| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try regex.expandReplacement(arena, &out, replacement, text, full);
            rep = out.items;
        };
        try ops.append(arena, .{ .replace_range = .{ .start = m.start, .end = m.end, .text = rep } });
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
    const e = app.panes.editor(fb.pane) orelse {
        app.toast("a response is read-only", .{});
        return;
    };
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
    const tg = try requireTarget(app);
    const f = tg.find();
    f.regex = !f.regex;
    if (app.find_bar) |*fb| if (fb.pane == app.active.?) {
        fb.state.regex = f.regex;
        try liveUpdate(app);
    };
    if (f.isActive()) try f.recompute(tg.text());
    app.toast("find: regex {s}", .{if (f.regex) "on (vim patterns)" else "off"});
    app.needs_render = true;
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
    // `*` / `#` write the last search pattern too (`:help star`).
    try app.noteSearchPattern(word);
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
    try t.expect(app.find_bar != null); // standard: the bar stays
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

test "find: standard Enter steps and keeps the bar, Esc keeps the landing, Ctrl+F selects the query; vim Enter closes" {
    var app = try appWith("alpha\nbeta\nalpha\ngamma\nalpha\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    const e = app.activeEditor().?;
    // Live matches leave the cursor alone, so the first Enter lands on
    // the match at the cursor; the ones after it step.
    try t.expectEqual(@as(usize, 0), e.buf.editor.cursor);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar != null);
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("match 2/3", app.lastToast().?);
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try app.handle(.{ .key = .{ .code = .enter, .mods = .{ .shift = true } } });
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    try app.handle(.{ .key = Key.named(.enter) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("match 3/3", app.lastToast().?);
    try t.expectEqual(@as(usize, 4), e.buf.editor.currentLine());
    try t.expect(!e.buf.doc.dirty);
    // Esc closes and keeps the landing: the query and the cursor stay.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.find_bar == null);
    try t.expectEqual(@as(usize, 4), e.buf.editor.currentLine());
    try t.expectEqualStrings("alpha", e.find.query.items);
    // Ctrl+F on an open bar selects the query: typing starts over, and
    // Esc on that draft goes back to the last landing.
    try command.run(&app, .{ .static = .@"find.find" });
    for ("beta") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("match 1/1", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.find" });
    try t.expect(app.find_bar.?.state.select_all);
    for ("gam") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualStrings("gam", app.find_bar.?.state.queryText());
    try t.expectEqual(@as(usize, 1), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqualStrings("beta", e.find.query.items);
    try t.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    // vim: `/` + Enter lands and closes, as it always did.
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"find.find" });
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar == null);
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
}

test "find: ctrl+r turns the query into a vim pattern; replace expands groups; a bad pattern says so" {
    var app = try appWith("foo1 bar22 baz333\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    for ("\\d\\+") |c| try app.handle(.{ .key = Key.char(c) });
    const e = app.activeEditor().?;
    try t.expectEqual(@as(usize, 0), e.find.matches.items.len);
    try app.handle(.{ .key = Key.ctrl('r') });
    try t.expect(e.find.regex);
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    // The chip is sticky: reopening the bar keeps regex on.
    try command.run(&app, .{ .static = .@"find.find" });
    try t.expect(app.find_bar.?.state.regex);
    for ("\\(\\a\\+\\)\\(\\d\\+\\)") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try command.run(&app, .{ .static = .@"find.replace" });
    for ("\\2-\\1") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("1-foo 22-bar 333-baz\n", e.buf.editor.bytes());
    try command.run(&app, .{ .static = .@"find.find" });
    for ("\\(x") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("invalid pattern: \"\\(x\"", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.toggle_regex" });
    try t.expect(!e.find.regex);
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
    try t.expect(e.buf.doc.dirty);
    // One undo step for the whole run.
    _ = try app.applyOps(e, &.{.undo});
    try t.expectEqualStrings("alpha beta alpha gamma alpha", e.buf.editor.bytes());
}
