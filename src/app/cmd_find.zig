//! `find.*` runners and the find bar's reactions: the bar opens over the
//! active pane, matches update as the query is typed, Enter lands on
//! the first match at or after the cursor (before it for vim `?`) and
//! toasts `match N/M`; `find.next` / `find.prev` step and toast the
//! same. `find.replace` in the standard profile is VS Code's Ctrl+H —
//! the bar's Replace row: Enter there replaces the current match and
//! moves on, Ctrl+Alt+Enter splices every match as one undo step; in the
//! vim profile it prompts `Replace N× "q" with` for the same splice.

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
const jumplist = @import("jumplist.zig");

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
    .@"find.word_forward_partial" = &wordForwardPartial,
    .@"find.word_backward_partial" = &wordBackwardPartial,
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

/// Make `tg`'s matches the text's matches before anything reads their
/// offsets: an edit made while they stood (an indent with the bar open,
/// a paste, an undo) moved the bytes, and a stale range selects the
/// wrong characters — or splits one. An editor asks its edit log first,
/// so a key with nothing changed costs nothing.
pub fn ensureFresh(tg: Target) Allocator.Error!void {
    const f = tg.find();
    if (!f.isActive()) return;
    switch (tg) {
        .editor => |e| {
            const head = e.buf.editor.doc.edits.head();
            if (f.seen_edit) |seen| if (seen == head) return;
            _ = try f.refresh(e.buf.editor.bytes());
            f.seen_edit = head;
        },
        .request => |rp| _ = try f.refresh(rp.respFindText()),
    }
}

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
            // starts over, a move keeps it — from the Replace field too.
            fb.state.focus = .query;
            fb.state.select_all = fb.state.query.items.len > 0;
            app.focus = .overlay;
            return;
        }
        app.closeFindBar(false);
    }
    const snap = tg.find().clone() catch return error.OutOfMemory;
    var fb: app_mod.FindBarState = .{ .pane = id, .snapshot = snap, .snapshot_cursor = tg.cursor(), .reverse = reverse, .hist_cursor = app.find_history.items.len };
    // The regex chip is sticky per pane (`find.toggle_regex`); vim's `/`
    // and `?` are always a pattern (`:help pattern`).
    fb.state.regex = vimPattern(app) or tg.find().regex;
    // The live preview starts from a blank slate; Esc restores the snapshot.
    tg.find().clear();
    app.find_bar = fb;
    app.focus = .overlay;
    app.needs_render = true;
}

/// vim's `/` and `?` read the query as a vim pattern, always — the same
/// text `:s` and `:g` take; only the standard profile's Ctrl+F bar has a
/// literal mode behind its `.*` chip (VS Code). `\V` is vim's literal.
pub fn vimPattern(app: *const App) bool {
    return app.input_style == .vim;
}

/// The syntax the find bar's regex takes: vim's under the vim profile,
/// the Perl-style one a VS Code user types under the standard profile.
pub fn dialectFor(app: *const App) regex.Dialect {
    return if (app.input_style == .standard) .perl else .vim;
}

/// The query changed: recompute the pane's matches, keep the cursor.
pub fn liveUpdate(app: *App) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    // A terminal's bar searches its scrollback (`pty_search.zig`).
    if (@import("pty_search.zig").barPane(app)) |p| return @import("pty_search.zig").liveUpdate(app, p);
    const tg = Target.of(app, fb.pane) orelse return;
    const f = tg.find();
    const q = fb.state.query.items;
    if (vimPattern(app)) fb.state.regex = true;
    f.regex = fb.state.regex;
    f.dialect = dialectFor(app);
    fb.landed = false;
    if (q.len == 0) {
        f.clear();
    } else {
        try setBarQuery(app, fb, f, q, tg.text());
        f.current = if (fb.reverse) f.indexBefore(tg.cursor()) else f.indexAtOrAfter(forwardFrom(app, tg.cursor()));
        // A response follows the live match as it is typed.
        if (tg == .request) if (f.current) |c| tg.request.revealFind(f.matches.items[c].start);
    }
    app.needs_render = true;
}

/// The bar's query with its case and whole-word toggles.
fn setBarQuery(app: *App, fb: *const app_mod.FindBarState, f: *find_mod.FindState, q: []const u8, text: []const u8) Allocator.Error!void {
    const case: ?bool = if (fb.state.match_case) true else app.search_case;
    if (fb.state.whole_word) try f.setWordQuery(q, text, case) else try f.setQuery(q, text, case);
}

/// A click on the bar's `.*` / `Aa` / `\b` chip (`find_bar.hit_regex` /
/// `hit_case` / `hit_word`): the same toggle as Alt+R / Alt+C / Alt+W.
pub fn chipClick(app: *App, id: u32) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    switch (id) {
        FindBar.hit_regex => fb.state.regex = !fb.state.regex,
        FindBar.hit_case => fb.state.match_case = !fb.state.match_case,
        FindBar.hit_word => fb.state.whole_word = !fb.state.whole_word,
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
    if (@import("pty_search.zig").barPane(app)) |p| return @import("pty_search.zig").accept(app, p);
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
    f.dialect = dialectFor(app);
    try setBarQuery(app, fb, f, q, tg.text());
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
    switch (tg) {
        .editor => |e| landOnMatch(app, e, idx),
        .request => tg.setCursor(f.matches.items[idx].start),
    }
    app.toast("match {d}/{d}", .{ idx + 1, f.matches.items.len });
    const snap = f.clone() catch return error.OutOfMemory;
    if (fb.snapshot) |*old| old.deinit();
    fb.snapshot = snap;
    fb.snapshot_cursor = tg.cursor();
    fb.landed = true;
    app.needs_render = true;
}

/// The cursor goes to match `idx`; the standard profile also selects it,
/// as VS Code's find does, so Esc leaves the match selected and typing
/// replaces it. The cursor stays on the match's first character.
fn landOnMatch(app: *App, e: *EditorPane, idx: usize) void {
    const m = e.find.matches.items[idx];
    e.buf.editor.setCursor(m.start);
    e.buf.editor.goal_col = null;
    if (app.input_style == .standard) e.buf.editor.anchor = if (m.end > m.start) m.end else null;
    app.needs_render = true;
}

/// The bar's ↓ / ↑ / Shift+Enter / F3: a step that also commits, so
/// Esc keeps the match it landed on.
pub fn stepFromBar(app: *App, delta: i32) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    if (@import("pty_search.zig").barPane(app)) |p| return @import("pty_search.zig").step(app, p, delta);
    const tg = Target.of(app, fb.pane) orelse return;
    try stepFind(app, delta);
    if (app.input_style == .vim or tg.find().current == null) return;
    if (tg == .editor) landOnMatch(app, tg.editor, tg.find().current.?);
    const snap = tg.find().clone() catch return error.OutOfMemory;
    if (fb.snapshot) |*old| old.deinit();
    fb.snapshot = snap;
    fb.snapshot_cursor = tg.cursor();
    fb.landed = true;
}

/// A search run as if typed after `/` (`?` when `reverse`) — `q/`'s
/// Enter: the bar opens over the active editor with `q` and lands.
pub fn searchFor(app: *App, q: []const u8, reverse: bool) Allocator.Error!void {
    openBar(app, reverse) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const fb = &(app.find_bar orelse return);
    try fb.state.setQuery(app.gpa, q);
    try liveUpdate(app);
    try acceptFromBar(app);
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
    f.regex = vimPattern(app) or fb.state.regex;
    f.dialect = dialectFor(app);
    try setBarQuery(app, fb, f, pattern, tg.text());
    f.offset = offset;
    // `/` and `?` write vim's last search pattern, which `:s//new/` reads.
    try app.noteSearchPattern(pattern);
    if (f.matches.items.len == 0) {
        if (f.bad_pattern) |err| app.toast("{s}: \"{s}\"", .{ patternProblem(err), pattern }) else app.toast("no matches for \"{s}\"", .{pattern});
        app.closeFindBar(false);
        // E486: a replaying macro stops here.
        app.key_failed = true;
        return;
    }
    const idx = (if (reverse) f.indexBefore(tg.cursor()) else f.indexAtOrAfter(forwardFrom(app, tg.cursor()))) orelse 0;
    f.current = idx;
    jumplist.noteJumpMotion(app);
    try noteWrap(app, f.matches.items[idx].start, tg.cursor(), !reverse, false);
    tg.setCursor(tg.landing(idx));
    app.toast("match {d}/{d}", .{ idx + 1, f.matches.items.len });
    app.closeFindBar(false);
    if (chain and tg == .editor) try openReplacePrompt(app);
}

/// Where a forward search starts: vim's `/` one past the cursor, so a
/// match under the cursor is the next one only after wrapping round
/// (`:help search-commands`); the standard profile's find takes the
/// match at the cursor.
fn forwardFrom(app: *const App, cursor: usize) usize {
    return if (app.input_style == .vim) cursor + 1 else cursor;
}

/// vim's `W` notice: a search that went past the end of the buffer and
/// came round says so (`:help 'shortmess'`), before its `match N/M`.
/// `at_ok`: landing on `from` itself is not a wrap (a step with no
/// current match takes the one under the cursor). `/` starts one past
/// the cursor, so for it landing back on the cursor is a wrap.
fn noteWrap(app: *App, landed: usize, from: usize, forward: bool, at_ok: bool) Allocator.Error!void {
    if (app.input_style != .vim) return;
    if (at_ok and landed == from) return;
    const wrapped = if (forward) landed <= from else landed >= from;
    if (!wrapped) return;
    try app.toastLevel(.warn, "{s}", .{if (forward) "search hit BOTTOM, continuing at TOP" else "search hit TOP, continuing at BOTTOM"});
}

/// `find.next` / `find.prev` and the bar's ↓ / ↑.
pub fn stepFind(app: *App, delta: i32) Allocator.Error!void {
    const id = app.active orelse return;
    const tg = Target.of(app, id) orelse return;
    const f = tg.find();
    try ensureFresh(tg);
    if (!f.isActive()) {
        app.toast("no active find — use / or Ctrl+F first", .{});
        app.key_failed = true;
        return;
    }
    if (f.matches.items.len == 0) {
        app.toast("no matches for \"{s}\"", .{f.query.items});
        app.key_failed = true;
        return;
    }
    // Without a current match (a cleared cursor jump), step from the cursor.
    const from = tg.cursor();
    const fresh = f.current == null;
    if (f.current == null) {
        f.current = if (delta > 0) f.indexAtOrAfter(from) else f.indexBefore(from);
    } else {
        _ = f.step(delta);
    }
    const idx = f.current.?;
    try noteWrap(app, f.matches.items[idx].start, from, delta > 0, fresh);
    tg.setCursor(tg.landing(idx));
    jumplist.noteJumpMotion(app);
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
    if (app.input_style == .standard) return openReplaceBar(app);
    try openReplacePrompt(app);
}

/// VS Code's Ctrl+H: the find bar with its Replace row. The query is
/// the active find's, selected so typing starts over; Tab moves to the
/// Replace field, Enter there replaces the current match and moves on,
/// Ctrl+Alt+Enter replaces them all, Esc closes.
pub fn openReplaceBar(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const prior = try app.frame.allocator().dupe(u8, e.find.query.items);
    const was_regex = e.find.regex;
    try openBar(app, false);
    const fb = &(app.find_bar orelse return);
    fb.state.show_replace = true;
    fb.state.focus = .query;
    if (fb.state.query.items.len == 0 and prior.len > 0) {
        try fb.state.setQuery(app.gpa, prior);
        fb.state.regex = fb.state.regex or was_regex;
        fb.state.select_all = true;
        try liveUpdate(app);
    }
    app.needs_render = true;
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
    try ensureFresh(.{ .editor = e });
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
    try ensureFresh(.{ .editor = e });
    const n = e.find.matches.items.len;
    if (n == 0) {
        app.toast("no matches to replace", .{});
        return;
    }
    const arena = app.frame.allocator();
    // In regex mode the replacement may name groups (`\1`, `&`), so
    // each match is found again for its groups and expanded.
    var re: ?regex.Regex = if (e.find.regex) regex.Regex.compile(e.find.query.items, .{ .ignore_case = !e.find.case_sensitive, .dialect = e.find.dialect }) catch null else null;
    defer if (re) |*r| r.deinit();
    const text = e.buf.editor.bytes();
    const matches = e.find.matches.items;
    // One pass builds the text from the first match to the last and one
    // splice lands it — one undo entry, one change for the server, as
    // `:%s` does. An op per match spliced the whole buffer per match.
    const lo = matches[0].start;
    const hi = matches[n - 1].end;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, hi - lo);
    var copied = lo;
    var first_end: usize = lo;
    for (matches, 0..) |m, mi| {
        try out.appendSlice(arena, text[copied..m.start]);
        if (re) |*r| if (r.find(text, m.start)) |full| {
            try regex.expandReplacementFor(e.find.dialect, arena, &out, replacement, text, full);
        } else try out.appendSlice(arena, replacement) else try out.appendSlice(arena, replacement);
        copied = m.end;
        if (mi == 0) first_end = lo + out.items.len;
    }
    _ = try app.applyOps(e, &.{.{ .replace_range = .{ .start = lo, .end = hi, .text = out.items } }});
    // A landed match's selection went with the text it covered.
    e.buf.editor.anchor = null;
    // The cursor ends after the first replacement, where it always has.
    e.buf.editor.setCursor(@min(first_end, e.buf.editor.len()));
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
    try ensureFresh(.{ .editor = e });
    const idx = e.find.current orelse e.find.indexAtOrAfter(e.buf.editor.cursor) orelse {
        app.toast("no matches to replace", .{});
        return;
    };
    const m = e.find.matches.items[idx];
    const arena = app.frame.allocator();
    const all = e.buf.editor.bytes();
    // A regex replacement may name the match's groups (`$1`, `\1`).
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var re: ?regex.Regex = if (e.find.regex) regex.Regex.compile(e.find.query.items, .{ .ignore_case = !e.find.case_sensitive, .dialect = e.find.dialect }) catch null else null;
    defer if (re) |*r| r.deinit();
    if (re) |*r| if (r.find(all, m.start)) |full| {
        try regex.expandReplacementFor(e.find.dialect, arena, &out, fb.state.replace.items, all, full);
    } else try out.appendSlice(arena, fb.state.replace.items) else try out.appendSlice(arena, fb.state.replace.items);
    try app.splice(e, m.start, m.end, out.items);
    // The next match is searched for from after the replacement, so a
    // replacement that contains the query is not replaced again.
    const after = m.start + out.items.len;
    try e.find.recompute(e.buf.editor.bytes());
    if (e.find.matches.items.len > 0) {
        // Lands (and commits) the way Enter in Find does, so Esc keeps it.
        e.find.current = e.find.indexAtOrAfter(after);
        try landFromBar(app, fb, .{ .editor = e });
    } else {
        e.buf.editor.anchor = null;
        e.buf.editor.setCursor(after);
        const snap = try e.find.clone();
        if (fb.snapshot) |*old| old.deinit();
        fb.snapshot = snap;
        fb.snapshot_cursor = after;
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
    if (vimPattern(app)) {
        // Nothing to toggle: `/` is a pattern; `\V` reads the rest literally.
        app.toast("find: / is always a vim pattern — start it with \\V for literal text", .{});
        return;
    }
    f.regex = !f.regex;
    f.dialect = dialectFor(app);
    if (app.find_bar) |*fb| if (fb.pane == app.active.?) {
        fb.state.regex = f.regex;
        try liveUpdate(app);
    };
    if (f.isActive()) try f.recompute(tg.text());
    app.toast("find: regex {s}", .{if (!f.regex) "off" else if (f.dialect == .vim) "on (vim patterns)" else "on (a|b, \\d+, x{3}, (…))"});
    app.needs_render = true;
}

/// `*` / `#`: the identifier under the cursor, as a whole keyword
/// (`\<word\>`, `:help star`), becomes the query; `g*` / `g#` take it
/// as a substring too.
fn wordSearch(app: *App, forward: bool, whole: bool) CommandError!void {
    const e = try app.requireEditor();
    const text = e.buf.editor.bytes();
    const r = find_mod.wordAt(text, e.buf.editor.cursor) orelse {
        app.toast("no word under cursor", .{});
        return;
    };
    const word = try app.frame.allocator().dupe(u8, text[r.start..r.end]);
    if (whole) try e.find.setWordQuery(word, text, app.search_case) else try e.find.setQuery(word, text, app.search_case);
    // `*` / `#` write the last search pattern too (`:help star`), so
    // `:s//new/` renames that identifier and not its longer cousins.
    try app.noteSearchPattern(if (whole) try std.fmt.allocPrint(app.frame.allocator(), "\\<{s}\\>", .{word}) else word);
    // Step off the word under the cursor so the jump is a real move.
    e.find.current = if (forward) e.find.indexAtOrAfter(r.end) else e.find.indexBefore(r.start);
    try stepFromCurrent(app, e);
}

fn wordForward(app: *App) CommandError!void {
    return wordSearch(app, true, true);
}

fn wordBackward(app: *App) CommandError!void {
    return wordSearch(app, false, true);
}

fn wordForwardPartial(app: *App) CommandError!void {
    return wordSearch(app, true, false);
}

fn wordBackwardPartial(app: *App) CommandError!void {
    return wordSearch(app, false, false);
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
    try ensureFresh(.{ .editor = e });
    const idx = e.find.current orelse {
        app.toast("no matches for \"{s}\"", .{e.find.query.items});
        app.key_failed = true;
        return;
    };
    e.buf.editor.setCursor(e.find.matches.items[idx].start);
    e.buf.editor.goal_col = null;
    jumplist.noteJumpMotion(app);
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
    try ensureFresh(.{ .editor = e });
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
/// Matches found before an edit are found again first: the text moved
/// under them (`cgnQ<Esc>` then `.`).
pub fn seedCtxMatches(e: *EditorPane) Allocator.Error!void {
    try ensureFresh(.{ .editor = e });
    const cur = e.buf.editor.cursor;
    e.buf.editor.find_next = null;
    e.buf.editor.find_prev = null;
    const ms = e.find.matches.items;
    if (ms.len == 0) return;
    for (ms) |m| if (m.start <= cur and cur < m.end) {
        e.buf.editor.find_next = .{ m.start, m.end };
        e.buf.editor.find_prev = .{ m.start, m.end };
        return;
    };
    const nxt = e.find.indexAtOrAfter(cur) orelse 0;
    e.buf.editor.find_next = .{ ms[nxt].start, ms[nxt].end };
    var last: usize = ms.len - 1;
    var i = ms.len;
    while (i > 0) {
        i -= 1;
        if (ms[i].end <= cur) {
            last = i;
            break;
        }
    }
    e.buf.editor.find_prev = .{ ms[last].start, ms[last].end };
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

test "find: ctrl+r turns the query into a pattern — Perl-style in the standard profile; replace expands $1 groups; a bad pattern says so" {
    var app = try appWith("foo1 bar22 baz333\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    for ("\\d+") |c| try app.handle(.{ .key = Key.char(c) });
    const e = app.activeEditor().?;
    try t.expectEqual(@as(usize, 0), e.find.matches.items.len);
    try app.handle(.{ .key = Key.ctrl('r') });
    try t.expect(e.find.regex);
    try t.expectEqual(regex.Dialect.perl, e.find.dialect);
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("match 1/3", app.lastToast().?);
    // The chip is sticky: reopening the bar keeps regex on.
    try command.run(&app, .{ .static = .@"find.find" });
    try t.expect(app.find_bar.?.state.regex);
    for ("([a-z]+)(\\d+)") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try command.run(&app, .{ .static = .@"find.replace" });
    try app.handle(.{ .key = Key.named(.tab) });
    for ("$2-$1") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = .{ .code = .enter, .mods = .{ .ctrl = true, .alt = true } } });
    try t.expectEqualStrings("1-foo 22-bar 333-baz\n", e.buf.editor.bytes());
    try command.run(&app, .{ .static = .@"find.find" });
    for ("(x") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("invalid pattern: \"(x\"", app.lastToast().?);
    try command.run(&app, .{ .static = .@"find.toggle_regex" });
    try t.expect(!e.find.regex);
    // The vim profile's `/` takes vim's syntax, `\d\+`, `\|`, chip or not.
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"find.find" });
    for ("\\d\\+\\|foo") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(regex.Dialect.vim, e.find.dialect);
    try t.expectEqual(@as(usize, 4), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
}

test "find: vim's / and ? are vim patterns, never literal — ^, \\<\\>, \\d, ., \\c, \\|; smart case skips escapes" {
    var app = try appWith("x ab\nab foo.bar fooxbar\nxx foobar foo\na1 b22 c333\nxx Foo\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    const Case = struct { q: []const u8, line: usize, col: usize, n: usize };
    const cases = [_]Case{
        .{ .q = "^ab", .line = 1, .col = 0, .n = 1 },
        .{ .q = "\\<foo\\>", .line = 1, .col = 3, .n = 3 },
        .{ .q = "\\d\\d\\d", .line = 3, .col = 8, .n = 1 },
        .{ .q = "o.b", .line = 1, .col = 5, .n = 3 },
        .{ .q = "\\cFOO", .line = 1, .col = 3, .n = 5 },
        .{ .q = "c333\\|Foo", .line = 3, .col = 7, .n = 2 },
        // `\S` is no uppercase letter, so `\Soo` is case-insensitive;
        // `OO` is, so `\SOO` is not.
        .{ .q = "\\SOO", .line = 0, .col = 0, .n = 0 },
        .{ .q = "\\Soo", .line = 1, .col = 3, .n = 5 },
        // `\V` is vim's literal: the dot is a dot.
        .{ .q = "\\Vo.b", .line = 1, .col = 5, .n = 1 },
    };
    for (cases) |c| {
        e.buf.editor.setCursor(0);
        try command.run(&app, .{ .static = .@"find.find" });
        try t.expect(app.find_bar.?.state.regex);
        for (c.q) |ch| try app.handle(.{ .key = Key.char(ch) });
        try app.handle(.{ .key = Key.named(.enter) });
        t.expectEqual(c.n, e.find.matches.items.len) catch |err| {
            std.debug.print("query {s}\n", .{c.q});
            return err;
        };
        if (c.n == 0) continue;
        try t.expectEqual(c.line, e.buf.editor.currentLine());
        try t.expectEqual(c.col, e.buf.editor.cursor - e.buf.editor.lineStart(c.line));
    }
    // `?` too.
    e.buf.editor.setCursor(e.buf.editor.len());
    try command.run(&app, .{ .static = .@"find.find_backward" });
    for ("^\\a\\d") |ch| try app.handle(.{ .key = Key.char(ch) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(@as(usize, 3), e.buf.editor.currentLine());
    // Alt+R has nothing to turn off in the vim profile.
    try command.run(&app, .{ .static = .@"find.toggle_regex" });
    try t.expect(e.find.regex);
}

test "find: Esc restores the previous find state; Ctrl+H's replace-all splices every match" {
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
    // Ctrl+H: the bar's Replace row, the find's query in the Find field.
    try command.run(&app, .{ .static = .@"find.replace" });
    try t.expect(app.find_bar.?.state.show_replace);
    try t.expectEqualStrings("alpha", app.find_bar.?.state.queryText());
    try app.handle(.{ .key = Key.named(.tab) });
    for ("DELTA") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = .{ .code = .enter, .mods = .{ .ctrl = true, .alt = true } } });
    try t.expectEqualStrings("DELTA beta DELTA gamma DELTA", e.buf.editor.bytes());
    try t.expectEqualStrings("replaced 3", app.lastToast().?);
    try t.expect(e.buf.doc.dirty);
    // One undo step for the whole run.
    _ = try app.applyOps(e, &.{.undo});
    try t.expectEqualStrings("alpha beta alpha gamma alpha", e.buf.editor.bytes());
}

test "find: replace-all lands every match in one splice, cursor after the first replacement" {
    var app = try appWith("x worker-1 y worker-2 z worker-3\n");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"find.find" });
    for ("worker-") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const e = app.activeEditor().?;
    try t.expectEqual(@as(usize, 3), e.find.matches.items.len);
    const seq0 = e.buf.doc.edits.next_seq;
    try command.run(&app, .{ .static = .@"find.replace" });
    try app.handle(.{ .key = Key.named(.tab) });
    for ("w-") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = .{ .code = .enter, .mods = .{ .ctrl = true, .alt = true } } });
    try t.expectEqualStrings("x w-1 y w-2 z w-3\n", e.buf.editor.bytes());
    // One splice (so one change for the server and O(file) work), where
    // an op per match spliced the whole buffer once per match.
    try t.expectEqual(seq0 + 1, e.buf.doc.edits.next_seq);
    try t.expectEqual(@as(usize, 4), e.buf.editor.cursor);
}

test "find: Ctrl+H's Replace row — Tab, Enter replaces one and moves on, $1 groups, Esc keeps the selection" {
    var app = try appWith("foo1 x foo22 foox foo3\n");
    defer app.deinit();
    const e = app.activeEditor().?;
    try command.run(&app, .{ .static = .@"find.replace" });
    try t.expect(app.find_bar.?.state.show_replace);
    for ("foo") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(@as(usize, 4), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqual(FindBar.Focus.replace, app.find_bar.?.state.focus);
    for ("bar") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("bar1 x foo22 foox foo3\n", e.buf.editor.bytes());
    try t.expectEqualStrings("replaced 1 · 3 left", app.lastToast().?);
    // The next match is the current one now, selected.
    try t.expectEqual(@as(usize, 7), e.buf.editor.cursor);
    try t.expectEqual(@as(?usize, 10), e.buf.editor.anchor);
    // Shift+Tab back to Find, then a pattern with groups.
    try app.handle(.{ .key = Key.named(.backtab) });
    try app.handle(.{ .key = .{ .code = .{ .char = 'r' }, .mods = .{ .alt = true } } });
    for ("(\\d+)") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqual(@as(usize, 2), e.find.matches.items.len);
    try app.handle(.{ .key = Key.named(.tab) });
    for ("<$1>") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("bar1 x bar<22> foox foo3\n", e.buf.editor.bytes());
    // Esc closes and keeps the next match selected: `foo3`.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.find_bar == null);
    try t.expectEqual(@as(usize, 20), e.buf.editor.cursor);
    try t.expectEqual(@as(?usize, 24), e.buf.editor.anchor);
    // Each replacement was its own undo step.
    _ = try app.applyOps(e, &.{ .undo, .undo });
    try t.expectEqualStrings("foo1 x foo22 foox foo3\n", e.buf.editor.bytes());
}
