//! Search in a terminal pane: the find bar over the pane's last row,
//! matching its scrollback and screen, every match on the match colour
//! role and the one being stepped on `current_match`, the view scrolled
//! to keep that one in sight, and `k/N` in the bar.
//!
//! The pane's text is never copied out whole. The scan walks the rows
//! of the active screen's page list top to bottom, one logical line at
//! a time (soft-wrapped rows joined), into a line buffer the search
//! owns, and runs the query — literal with smart case, or a regex
//! through the same engine the editor's find uses — over that line.
//! A tick scans at most `rows_per_tick` rows; a scrollback longer than
//! that finishes over the next ticks, the count growing as it goes.
//!
//! Matches are kept in screen coordinates (row 0 is the oldest line
//! the terminal still holds). New output changes only the active area
//! and appends below it, so a search survives it by rescanning from the
//! logical line holding the active area's top — nothing above that can
//! change. The oldest rows being dropped to make room shifts every row
//! up: one tracked pin (`anchor`) on the screen's last row tells by how
//! much, and the matches follow. The current match is kept when it
//! still exists after the rescan; one rewritten in place gives way to
//! the match before it, one dropped off the top to the match nearest
//! the bottom of the view, as a fresh query picks. A resize reflows the
//! lines, a switch of screens shows other ones: both start the scan
//! over.
//!
//! Keys: `/` in vim's terminal-normal mode and the find chord of the
//! standard profile (`Ctrl+F`, whatever `find.find` is bound to) open
//! the bar (`term.search`); `n` / `N` in terminal-normal step
//! (`term.search_next` / `_prev`), Enter / Shift+Enter in the standard
//! bar. Closing the bar leaves the terminal's selection on the current
//! match, so the terminal's copy takes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Ui = @import("../ui/context.zig");
const Rect = @import("../ui/rect.zig");
const find_bar = @import("../ui/find_bar.zig");
const pty_view = @import("../ui/pty_view.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const regex = @import("../regex/regex.zig");
const find_mod = @import("find.zig");
const find_history = @import("find_history.zig");
const cmd_find = @import("cmd_find.zig");
const pty_pane = @import("pty_pane.zig");
const PtyPane = pty_pane.PtyPane;
const pty = @import("pty");
const vt = pty.vt;

pub const table = .{
    .@"term.search" = &open,
    .@"term.search_next" = &next,
    .@"term.search_prev" = &prev,
};

/// How many rows one tick scans. A 10000-line scrollback is three
/// ticks; the typical one finishes inside the keystroke that asked.
pub const rows_per_tick: u32 = 4000;

/// A match's first and last cells, in screen coordinates; `x1` is
/// inclusive and covers a wide char's second cell.
pub const Match = struct {
    y0: u32,
    x0: u16,
    y1: u32,
    x1: u16,

    pub fn eql(a: Match, b: Match) bool {
        return a.y0 == b.y0 and a.x0 == b.x0 and a.y1 == b.y1 and a.x1 == b.x1;
    }
};

/// Where one byte of the line buffer came from.
const CellRef = struct { dy: u32, x: u16, wide: bool };

/// One pane's search. Everything here is gpa-owned by the pane.
pub const Search = struct {
    query: std.ArrayListUnmanaged(u8) = .empty,
    regex: bool = false,
    case_sensitive: bool = false,
    re: ?regex.Regex = null,
    /// The regex did not compile; nothing is scanned.
    bad_pattern: ?regex.Error = null,
    matches: std.ArrayListUnmanaged(Match) = .empty,
    current: ?usize = null,
    /// The current match's cells, so a rescan can find it again.
    keep: ?Match = null,
    /// No match has been picked for this query yet: the scan's end
    /// picks the one nearest the bottom of the view.
    pick_initial: bool = false,
    /// Paint the matches while the bar is closed (vim's terminal-normal
    /// after `/`…Enter or `n`); Esc on the bar turns it off.
    shown: bool = false,
    /// The next row to scan, or null when the scan is done.
    scan: ?u32 = null,
    /// Tracked at the screen's last row (`anchor_y`) as it was at the
    /// last scan: how far it has moved up is how many rows were dropped.
    anchor: ?*vt.Pin = null,
    anchor_y: u32 = 0,
    /// The first row the child could still change when it was last
    /// scanned — the active area's top then; rows above it are history.
    stable_y: u32 = 0,
    /// What the anchor is tracked in: a restarted child is a new
    /// terminal, a pager a new screen.
    session: ?*pty_pane.Session = null,
    screen: vt.ScreenSet.Key = .primary,
    generation: usize = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    fed_gen: u64 = 0,
    // The line being matched, reused from line to line.
    text: std.ArrayListUnmanaged(u8) = .empty,
    refs: std.ArrayListUnmanaged(CellRef) = .empty,
    found: std.ArrayListUnmanaged(regex.Range) = .empty,

    /// The terminal is going (or gone) with the pane: nothing is
    /// untracked, its pages go with it.
    pub fn deinit(s: *Search, gpa: Allocator) void {
        if (s.re) |*r| r.deinit();
        s.query.deinit(gpa);
        s.matches.deinit(gpa);
        s.text.deinit(gpa);
        s.refs.deinit(gpa);
        s.found.deinit(gpa);
        s.* = .{};
    }

    pub fn active(s: *const Search) bool {
        return s.query.items.len > 0;
    }

    pub fn scanning(s: *const Search) bool {
        return s.scan != null;
    }

    /// The bar's count: which match is current, of how many.
    pub fn info(s: *const Search) find_bar.Info {
        return .{ .current = s.current, .total = s.matches.items.len };
    }
};

// ─── the terminal side ──────────────────────────────────────────────────

fn termOf(p: *PtyPane) ?*vt.Terminal {
    const session = p.session orelse return null;
    return session.terminal();
}

/// Let go of the anchor, untracking it only from the screen it was
/// tracked in while that screen still lives.
fn dropAnchor(s: *Search, p: *PtyPane) void {
    const a = s.anchor orelse return;
    s.anchor = null;
    const session = s.session orelse return;
    if (p.session != session) return;
    const term = session.terminal();
    if (term.screens.generation(s.screen) != s.generation) return;
    const screen = term.screens.get(s.screen) orelse return;
    screen.pages.untrackPin(a);
}

/// Put the anchor on the active screen's last row: the newest row is
/// the last to be dropped, so it is the one that can still say how far
/// the rest moved.
fn setAnchor(s: *Search, p: *PtyPane, term: *vt.Terminal) Allocator.Error!void {
    const pages = &term.screens.active.pages;
    var pin = pages.getBottomRight(.screen) orelse pages.getTopLeft(.screen);
    pin.x = 0;
    const y: u32 = @intCast(pages.total_rows -| 1);
    if (s.anchor) |a| if (s.session == p.session and s.screen == term.screens.active_key and s.generation == term.screens.generation(s.screen)) {
        a.* = pin;
        s.anchor_y = y;
        return;
    };
    dropAnchor(s, p);
    s.anchor = try pages.trackPin(pin);
    s.anchor_y = y;
    s.session = p.session;
    s.screen = term.screens.active_key;
    s.generation = term.screens.generation(s.screen);
}

/// The screen row of the logical line holding the active area's top —
/// the first row output can still change.
fn activeLineY(term: *vt.Terminal) u32 {
    const pages = &term.screens.active.pages;
    var y: u32 = @intCast(pages.total_rows -| pages.rows);
    var pin = pages.pin(.{ .screen = .{ .x = 0, .y = y } }) orelse return y;
    while (y > 0 and pin.rowAndCell().row.wrap_continuation) {
        pin = pin.up(1) orelse break;
        y -= 1;
    }
    return y;
}

/// Everything from row `y` on is to be scanned again.
fn rescanFrom(s: *Search, y: u32) void {
    var n = s.matches.items.len;
    while (n > 0 and s.matches.items[n - 1].y0 >= y) n -= 1;
    s.matches.shrinkRetainingCapacity(n);
    if (s.current) |c| if (c >= n) {
        s.current = null;
    };
    s.scan = y;
}

/// Start over from the top: a new query, a resize, another screen.
fn restartScan(s: *Search, p: *PtyPane, term: *vt.Terminal) Allocator.Error!void {
    s.matches.clearRetainingCapacity();
    s.current = null;
    s.cols = term.cols;
    s.rows = term.rows;
    s.fed_gen = p.fed_gen;
    if (!s.active() or s.bad_pattern != null) {
        s.scan = null;
        dropAnchor(s, p);
        return;
    }
    // The anchor may belong to another terminal or screen by now.
    if (s.session != p.session or s.screen != term.screens.active_key or s.generation != term.screens.generation(s.screen)) dropAnchor(s, p);
    s.scan = 0;
    s.stable_y = activeLineY(term);
    try setAnchor(s, p, term);
}

/// Output landed, the pane was resized, or the screen switched: bring
/// the matches up to date with the rows as they are now.
fn refresh(s: *Search, p: *PtyPane, term: *vt.Terminal) Allocator.Error!void {
    const same_screen = s.session == p.session and s.screen == term.screens.active_key and s.generation == term.screens.generation(s.screen);
    if (!same_screen or term.cols != s.cols or term.rows != s.rows or s.anchor == null) {
        // The lines reflowed or are other lines: the current match's
        // cells mean nothing now, so one is picked again.
        s.keep = null;
        s.pick_initial = true;
        return restartScan(s, p, term);
    }
    if (p.fed_gen == s.fed_gen) return;
    s.fed_gen = p.fed_gen;
    const a = s.anchor.?;
    const pages = &term.screens.active.pages;
    const now_y: ?u32 = if (a.garbage) null else if (pages.pointFromPin(.screen, a.*)) |pt| pt.screen.y else null;
    if (now_y == null or now_y.? > s.anchor_y) {
        // More went than the whole scrollback holds: nothing is where
        // it was, so the scan starts over and picks a current again.
        s.keep = null;
        s.pick_initial = true;
        return restartScan(s, p, term);
    }
    const shift = s.anchor_y - now_y.?;
    if (shift > 0) {
        // The oldest rows went: every row moved up by `shift`.
        var w: usize = 0;
        for (s.matches.items) |m| {
            if (m.y0 < shift) continue;
            s.matches.items[w] = .{ .y0 = m.y0 - shift, .x0 = m.x0, .y1 = m.y1 - shift, .x1 = m.x1 };
            w += 1;
        }
        s.matches.shrinkRetainingCapacity(w);
        if (s.scan) |y| s.scan = y -| shift;
        s.stable_y -|= shift;
        if (s.keep) |k| if (k.y0 < shift) {
            // It went off the top: one is picked again, as for a
            // fresh query.
            s.keep = null;
            s.pick_initial = true;
        } else {
            s.keep = .{ .y0 = k.y0 - shift, .x0 = k.x0, .y1 = k.y1 - shift, .x1 = k.x1 };
        };
        s.current = null;
    }
    // Rows from the active area's top as it was at the last scan can
    // have changed since, and so can everything the active area covers
    // now; above both, a row is history and stays as it was read.
    var from = @min(s.stable_y, activeLineY(term));
    if (s.scan) |y| from = @min(from, y);
    rescanFrom(s, from);
    s.stable_y = activeLineY(term);
    try setAnchor(s, p, term);
    s.current = indexOf(s, s.keep);
}

fn indexOf(s: *const Search, want: ?Match) ?usize {
    const k = want orelse return null;
    for (s.matches.items, 0..) |m, i| if (m.eql(k)) return i;
    return null;
}

const Line = struct { last: vt.Pin, rows: u32 };

/// Read the logical line starting at `start` into the line buffer:
/// its last row, and how many rows it took.
fn readLine(s: *Search, gpa: Allocator, start: vt.Pin) Allocator.Error!Line {
    s.text.clearRetainingCapacity();
    s.refs.clearRetainingCapacity();
    var pin = start;
    pin.x = 0;
    var dy: u32 = 0;
    while (true) {
        const row = pin.rowAndCell().row;
        const cells = pin.cells(.all);
        // An unwrapped row's trailing blanks are not text.
        var end: usize = cells.len;
        if (!row.wrap) while (end > 0) {
            const c = cells[end - 1];
            if (c.hasText() or c.wide == .spacer_tail) break;
            end -= 1;
        };
        for (cells[0..end], 0..) |*c, x| {
            switch (c.wide) {
                .spacer_tail, .spacer_head => continue,
                .narrow, .wide => {},
            }
            const ref: CellRef = .{ .dy = dy, .x = @intCast(x), .wide = c.wide == .wide };
            const cp = c.codepoint();
            try appendCp(s, gpa, if (cp == 0) ' ' else cp, ref);
            if (c.hasGrapheme()) if (pin.grapheme(c)) |extra| for (extra) |g| try appendCp(s, gpa, g, ref);
        }
        if (!row.wrap) break;
        pin = pin.down(1) orelse break;
        dy += 1;
    }
    return .{ .last = pin, .rows = dy + 1 };
}

fn appendCp(s: *Search, gpa: Allocator, cp: u21, ref: CellRef) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try s.text.appendSlice(gpa, buf[0..n]);
    for (0..n) |_| try s.refs.append(gpa, ref);
}

/// The query over the line buffer, the line starting at row `y`.
fn matchLine(s: *Search, gpa: Allocator, y: u32) Allocator.Error!void {
    const text = s.text.items;
    if (text.len == 0) return;
    s.found.clearRetainingCapacity();
    if (s.re) |*re| {
        try re.findAll(gpa, &s.found, text);
    } else {
        var needle_buf: [256]u8 = undefined;
        const needle = find_mod.unescape(s.query.items, &needle_buf);
        try find_mod.findAll(gpa, &s.found, text, needle, s.case_sensitive);
    }
    for (s.found.items) |r| {
        // An empty match (`^`, `\zs`) has no cell to call out.
        if (r.end <= r.start or r.end > text.len) continue;
        const a = s.refs.items[r.start];
        const b = s.refs.items[r.end - 1];
        try s.matches.append(gpa, .{ .y0 = y + a.dy, .x0 = a.x, .y1 = y + b.dy, .x1 = b.x + @intFromBool(b.wide) });
    }
}

/// Scan up to `budget` rows from `s.scan`.
fn advance(s: *Search, gpa: Allocator, p: *PtyPane, term: *vt.Terminal, budget: u32) Allocator.Error!void {
    var y = s.scan orelse return;
    const pages = &term.screens.active.pages;
    const total: u32 = @intCast(pages.total_rows);
    var done: u32 = 0;
    var pin_opt = pages.pin(.{ .screen = .{ .x = 0, .y = y } });
    while (pin_opt) |pin| {
        if (done >= budget) break;
        const line = try readLine(s, gpa, pin);
        try matchLine(s, gpa, y);
        y += line.rows;
        done += line.rows;
        pin_opt = line.last.down(1);
    }
    if (pin_opt == null or y >= total) {
        s.scan = null;
        s.stable_y = activeLineY(term);
        try setAnchor(s, p, term);
        settle(s, term);
    } else {
        s.scan = y;
    }
}

/// The scan is done: find the current match again, or pick one.
fn settle(s: *Search, term: *vt.Terminal) void {
    if (s.matches.items.len == 0) {
        s.current = null;
        return;
    }
    if (s.current == null) s.current = indexOf(s, s.keep);
    if (s.current == null and s.keep != null) {
        // It went: the one before where it was takes over.
        const k = s.keep.?;
        var i: usize = s.matches.items.len;
        while (i > 0) : (i -= 1) if (s.matches.items[i - 1].y0 <= k.y0) break;
        s.current = if (i > 0) i - 1 else 0;
    }
    if (s.current == null and s.pick_initial) {
        s.current = nearestToView(s, term);
        s.pick_initial = false;
        if (s.current) |c| reveal(s, term, c);
    }
    if (s.current) |c| s.keep = s.matches.items[c];
}

/// The last match starting at or above the view's bottom row — the
/// newest one the user could be looking at — else the first.
fn nearestToView(s: *const Search, term: *vt.Terminal) ?usize {
    if (s.matches.items.len == 0) return null;
    const bottom = viewTop(term) + term.rows -| 1;
    var i: usize = s.matches.items.len;
    while (i > 0) : (i -= 1) if (s.matches.items[i - 1].y0 <= bottom) return i - 1;
    return 0;
}

/// The screen row at the top of the viewport.
fn viewTop(term: *vt.Terminal) u32 {
    const pages = &term.screens.active.pages;
    const pt = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return 0;
    return pt.screen.y;
}

/// Scroll so match `idx` is in view, clear of the bar's row.
fn reveal(s: *const Search, term: *vt.Terminal, idx: usize) void {
    const m = s.matches.items[idx];
    const top = viewTop(term);
    const h: u32 = @max(@as(u32, term.rows) -| 1, 1);
    if (m.y0 >= top and m.y1 < top + h) return;
    term.scrollViewport(.{ .row = m.y0 -| h / 2 });
}

// ─── the query ──────────────────────────────────────────────────────────

/// The options the editor's find bar compiles its regex with, the
/// dialect included: whichever syntax `cmd_find` gives the profile —
/// vim's under vim, the Perl-style one under standard — a terminal's
/// bar takes too.
fn regexOptions(app: *const App, ignore_case: bool) regex.Options {
    return .{ .ignore_case = ignore_case, .dialect = cmd_find.dialectFor(app) };
}

/// A new query (or toggles): recompile and scan from the top, as much
/// as one tick allows right now.
pub fn setQuery(app: *App, p: *PtyPane, q: []const u8, use_regex: bool, force_case: ?bool) Allocator.Error!void {
    const s = &p.search;
    const gpa = app.gpa;
    s.query.clearRetainingCapacity();
    try s.query.appendSlice(gpa, q);
    s.regex = use_regex;
    s.case_sensitive = force_case orelse find_mod.hasUpper(q);
    if (s.re) |*r| r.deinit();
    s.re = null;
    s.bad_pattern = null;
    s.keep = null;
    s.pick_initial = q.len > 0;
    if (use_regex and q.len > 0) {
        s.re = regex.Regex.compile(q, regexOptions(app, !s.case_sensitive)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                s.bad_pattern = err;
                break :blk null;
            },
        };
    }
    const term = termOf(p) orelse {
        s.matches.clearRetainingCapacity();
        s.current = null;
        return;
    };
    try restartScan(s, p, term);
    try advance(s, gpa, p, term, rows_per_tick);
    app.needs_render = true;
}

// ─── the bar ────────────────────────────────────────────────────────────

/// `term.search`: open the find bar over the active terminal pane. The
/// standard profile brings the last query back selected, as VS Code's
/// terminal find does; vim's `/` starts empty.
fn open(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "term.search: not a terminal pane", .{});
    if (p.session == null) return app.diag.fail(app.frame.allocator(), "term.search: the terminal is not running — a key starts it", .{});
    return openOn(app, id, p);
}

pub fn openOn(app: *App, id: PaneId, p: *PtyPane) Allocator.Error!void {
    if (app.find_bar) |*fb| {
        if (fb.pane == id) {
            fb.state.select_all = fb.state.query.items.len > 0;
            app.focus = .overlay;
            return;
        }
        app.closeFindBar(false);
    }
    var fb: app_mod.FindBarState = .{ .pane = id, .snapshot = null, .snapshot_cursor = 0, .hist_cursor = app.find_history.items.len };
    fb.state.regex = p.search.regex;
    if (app.input_style == .standard and p.search.active()) {
        try fb.state.setQuery(app.gpa, p.search.query.items);
        fb.state.select_all = true;
    }
    app.find_bar = fb;
    app.focus = .overlay;
    p.search.shown = true;
    app.needs_render = true;
}

/// The bar's pane, when it is a terminal.
pub fn barPane(app: *App) ?*PtyPane {
    const fb = app.find_bar orelse return null;
    return app.panes.pty(fb.pane);
}

/// The query or a toggle changed on the bar.
pub fn liveUpdate(app: *App, p: *PtyPane) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const force: ?bool = if (fb.state.match_case) true else app.search_case;
    try setQuery(app, p, fb.state.query.items, fb.state.regex, force);
    fb.landed = false;
}

/// Enter on the bar: vim's lands and closes, leaving `n` / `N`; the
/// standard profile's steps to the next match and keeps the bar.
pub fn accept(app: *App, p: *PtyPane) Allocator.Error!void {
    const fb = &(app.find_bar orelse return);
    const q = fb.state.query.items;
    if (q.len == 0) {
        if (app.input_style == .vim) app.closeFindBar(true);
        return;
    }
    try find_history.push(app, q);
    if (!p.search.active()) try liveUpdate(app, p);
    const s = &p.search;
    if (s.matches.items.len == 0 and !s.scanning()) {
        if (s.bad_pattern) |err| app.toast("{s}: \"{s}\"", .{ patternProblem(err), q }) else app.toast("no matches for \"{s}\"", .{q});
        if (app.input_style == .vim) app.closeFindBar(false);
        return;
    }
    if (app.input_style == .vim) {
        if (s.current) |c| app.toast("match {d}/{d}", .{ c + 1, s.matches.items.len });
        app.closeFindBar(false);
        return;
    }
    step(app, p, 1);
}

fn patternProblem(err: regex.Error) []const u8 {
    return switch (err) {
        error.InvalidPattern => "invalid pattern",
        error.Unsupported => "pattern uses an item this build does not support (\\&, \\%V…)",
        error.TooLong => "pattern too long",
        error.OutOfMemory => "out of memory",
    };
}

/// The bar is closing. Esc (`cancelled`) stops painting the matches;
/// either way the terminal's selection lands on the current match, so
/// copying takes it.
pub fn barClosed(app: *App, p: *PtyPane, cancelled: bool) void {
    const s = &p.search;
    s.shown = !cancelled and s.active();
    if (s.current) |c| selectMatch(p, s.matches.items[c]) catch {};
    app.needs_render = true;
}

/// Put the terminal's selection on `m`.
fn selectMatch(p: *PtyPane, m: Match) Allocator.Error!void {
    const term = termOf(p) orelse return;
    const screen = term.screens.active;
    const a = screen.pages.pin(.{ .screen = .{ .x = m.x0, .y = m.y0 } }) orelse return;
    const b = screen.pages.pin(.{ .screen = .{ .x = m.x1, .y = m.y1 } }) orelse return;
    try screen.select(vt.Selection.init(a, b, false));
}

/// Step `delta` matches, wrapping; the view follows. With the bar
/// closed the selection moves with it.
pub fn step(app: *App, p: *PtyPane, delta: i32) void {
    const s = &p.search;
    if (!s.active()) {
        app.toast("no search in this terminal — / (vim) or Ctrl+F first", .{});
        return;
    }
    const n = s.matches.items.len;
    if (n == 0) {
        if (s.scanning()) app.toast("still searching…", .{}) else app.toast("no matches for \"{s}\"", .{s.query.items});
        return;
    }
    const term = termOf(p) orelse return;
    const cur: i64 = if (s.current) |c| @intCast(c) else if (delta > 0) -1 else @intCast(n);
    const idx: usize = @intCast(@mod(cur + delta, @as(i64, @intCast(n))));
    s.current = idx;
    s.keep = s.matches.items[idx];
    s.pick_initial = false;
    reveal(s, term, idx);
    const bar_open = if (app.find_bar) |fb| app.panes.pty(fb.pane) == p else false;
    if (!bar_open) {
        s.shown = true;
        selectMatch(p, s.matches.items[idx]) catch {};
    }
    app.toast("match {d}/{d}", .{ idx + 1, n });
    app.needs_render = true;
}

fn next(app: *App) CommandError!void {
    return stepActive(app, 1);
}

fn prev(app: *App) CommandError!void {
    return stepActive(app, -1);
}

fn stepActive(app: *App, delta: i32) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.pty(id) orelse return app.diag.fail(app.frame.allocator(), "not a terminal pane", .{});
    step(app, p, delta);
}

// ─── keys ───────────────────────────────────────────────────────────────

/// Terminal-normal's search keys: `/` opens the bar, `n` / `N` step.
pub fn termNormalKey(app: *App, id: PaneId, p: *PtyPane, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const c = switch (k.code) {
        .char => |c| c,
        else => return false,
    };
    switch (c) {
        '/' => {
            if (p.session == null) return false;
            try openOn(app, id, p);
        },
        'n' => step(app, p, 1),
        'N' => step(app, p, -1),
        else => return false,
    }
    return true;
}

/// The chord the editor's find is bound to, pressed in a terminal pane
/// of the standard profile, searches the terminal (`Ctrl+F`, as VS
/// Code's terminal does). Under vim the child keeps its `Ctrl+F`.
pub fn findChord(app: *App, id: PaneId, p: *PtyPane, k: Key) Allocator.Error!bool {
    if (app.input_style != .standard or p.session == null) return false;
    const target = app.keymap.resolve(k) orelse return false;
    switch (target) {
        .static => |cmd| if (cmd != .@"find.find") return false,
        .named => return false,
    }
    try openOn(app, id, p);
    return true;
}

// ─── the loop ───────────────────────────────────────────────────────────

/// A restart is about to free the terminal the anchor lives in.
pub fn onRestart(p: *PtyPane) void {
    dropAnchor(&p.search, p);
}

/// Every tick: each searching pane follows its output and scans on.
pub fn tickAll(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| {
            if (!p.search.active()) continue;
            const term = termOf(p) orelse continue;
            const before = p.search.matches.items.len;
            const was_scanning = p.search.scanning();
            try refresh(&p.search, p, term);
            if (p.search.scanning()) try advance(&p.search, app.gpa, p, term, rows_per_tick);
            if (was_scanning or p.search.matches.items.len != before or p.search.scanning()) app.needs_render = true;
        },
        else => {},
    };
}

/// A scan still going wants the next tick at once.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| if (p.search.scanning()) return app.now_ms,
        else => {},
    };
    return null;
}

// ─── painting ───────────────────────────────────────────────────────────

/// The pane's matches in view, as marks on viewport rows. Empty while
/// the search is not on show or the size moved under it.
pub fn marks(app: *App, id: PaneId, p: *PtyPane) Allocator.Error![]const pty_view.Mark {
    const s = &p.search;
    if (!s.active() or s.matches.items.len == 0) return &.{};
    const bar_open = if (app.find_bar) |fb| fb.pane == id else false;
    if (!bar_open and !(s.shown and p.term_normal)) return &.{};
    const term = termOf(p) orelse return &.{};
    if (term.cols != s.cols or term.rows != s.rows) return &.{};
    const top = viewTop(term);
    const bottom = top + term.rows;
    // The first match ending at or below the top; they are in row order.
    var lo: usize = 0;
    var hi: usize = s.matches.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (s.matches.items[mid].y1 < top) lo = mid + 1 else hi = mid;
    }
    var out: std.ArrayListUnmanaged(pty_view.Mark) = .empty;
    const arena = app.frame.allocator();
    var i = lo;
    while (i < s.matches.items.len) : (i += 1) {
        const m = s.matches.items[i];
        if (m.y0 >= bottom) break;
        var y = @max(m.y0, top);
        while (y <= m.y1 and y < bottom) : (y += 1) {
            try out.append(arena, .{
                .y = @intCast(y - top),
                .x0 = if (y == m.y0) m.x0 else 0,
                .x1 = if (y == m.y1) m.x1 else term.cols -| 1,
                .current = s.current == i,
            });
        }
    }
    return out.items;
}

/// The bar over the pane's last row, drawn through the find bar
/// component; the caret goes to its field.
pub fn drawBar(app: *App, ui: Ui, id: PaneId, p: *PtyPane, body: Rect) void {
    const fb = &(app.find_bar orelse return);
    if (fb.pane != id or body.h < 2) return;
    const bar = body.splitBottom(1).rest;
    if (find_bar.draw(ui, bar, &fb.state, p.search.info())) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

// ─── tests ──────────────────────────────────────────────────────────────

const builtin = @import("builtin");
const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");
const Theme = @import("../ui/theme.zig");

/// The text a match's cells hold, read back off the terminal.
fn textOf(p: *PtyPane, m: Match) ![]u8 {
    const screen = termOf(p).?.screens.active;
    const a = screen.pages.pin(.{ .screen = .{ .x = m.x0, .y = m.y0 } }) orelse return error.TestUnexpectedResult;
    const b = screen.pages.pin(.{ .screen = .{ .x = m.x1, .y = m.y1 } }) orelse return error.TestUnexpectedResult;
    const s = try screen.selectionString(t.allocator, .{ .sel = vt.Selection.init(a, b, false), .trim = false });
    defer t.allocator.free(s);
    return t.allocator.dupe(u8, s);
}

/// The whole of screen row `y`'s logical line, as text.
fn lineOf(p: *PtyPane, y: u32) ![]u8 {
    const screen = termOf(p).?.screens.active;
    const a = screen.pages.pin(.{ .screen = .{ .x = 0, .y = y } }) orelse return error.TestUnexpectedResult;
    const b = screen.pages.pin(.{ .screen = .{ .x = screen.pages.cols - 1, .y = y } }) orelse return error.TestUnexpectedResult;
    const s = try screen.selectionString(t.allocator, .{ .sel = vt.Selection.init(a, b, false), .trim = true });
    defer t.allocator.free(s);
    return t.allocator.dupe(u8, s);
}

/// The screen cell `needle` starts at, if it is on screen.
fn cellOf(app: *App, needle: []const u8) ?struct { x: u16, y: u16 } {
    var y: u16 = 0;
    while (y < app.screen.height) : (y += 1) {
        var x: u16 = 0;
        while (x + needle.len <= app.screen.width) : (x += 1) {
            var i: usize = 0;
            while (i < needle.len) : (i += 1) {
                const c = app.screen.readCell(x + @as(u16, @intCast(i)), y) orelse break;
                if (c.char.grapheme.len != 1 or c.char.grapheme[0] != needle[i]) break;
            } else return .{ .x = x, .y = y };
        }
    }
    return null;
}

fn typeText(app: *App, s: []const u8) !void {
    for (s) |c| try app.handle(.{ .key = Key.char(c) });
}

/// Tick until the pane's scan is done.
fn settleScan(app: *App, p: *PtyPane) !void {
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        try app.tick(App.nowMs(app.io));
        if (!p.search.scanning()) return;
    }
    return error.TestUnexpectedResult;
}

test "scrollback search (vim): `/` in terminal-normal finds one line of 3000, highlights it, Enter selects it; a regex with two matches steps with n / N and wraps" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 3000; sleep 30" }, .label = "seq" });
    try t.expect(try pty_pane.tickUntilScreen(&app, "3000", 5000));
    const p = app.panes.pty(id).?;
    // Terminal-normal, then `/`: the bar opens over the pane's last row.
    try app.handle(.{ .key = Key.ctrl('x') });
    try t.expect(p.term_normal);
    try app.handle(.{ .key = Key.char('/') });
    try t.expect(app.find_bar != null and app.find_bar.?.pane == id);
    try typeText(&app, "2999");
    try settleScan(&app, p);
    try t.expectEqual(@as(usize, 1), p.search.matches.items.len);
    try t.expectEqual(@as(?usize, 0), p.search.current);
    // The keymap's toast sits over the bar's right end.
    app.dismissToasts();
    const got = try textOf(p, p.search.matches.items[0]);
    defer t.allocator.free(got);
    try t.expectEqualStrings("2999", got);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "match 1/1") != null);
    // The line on screen wears the current-match role.
    const at = cellOf(&app, "2999") orelse return error.TestUnexpectedResult;
    try t.expect(Theme.Color.eql(app.screen.readCell(at.x, at.y).?.style.bg, app.theme.current_match.bg));
    // Enter lands and closes; the terminal's selection is the match.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar == null);
    const sel = termOf(p).?.screens.active.selection orelse return error.TestUnexpectedResult;
    const sel_text = try termOf(p).?.screens.active.selectionString(t.allocator, .{ .sel = sel });
    defer t.allocator.free(sel_text);
    try t.expectEqualStrings("2999", sel_text);
    // `y` in terminal-normal yanks it, as it yanks a mouse selection.
    try app.handle(.{ .key = Key.char('y') });
    try t.expectEqualStrings("2999", app.clipboard.text());

    // A regex: two lines. The one nearer the bottom is current; `n`
    // wraps to the first, `N` back.
    try app.handle(.{ .key = Key.char('/') });
    try app.handle(.{ .key = Key.ctrl('r') });
    try typeText(&app, "^299[89]$");
    try settleScan(&app, p);
    try t.expectEqual(@as(usize, 2), p.search.matches.items.len);
    try t.expectEqual(@as(?usize, 1), p.search.current);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar == null);
    try app.handle(.{ .key = Key.char('n') });
    try t.expectEqual(@as(?usize, 0), p.search.current);
    const first = try textOf(p, p.search.matches.items[0]);
    defer t.allocator.free(first);
    try t.expectEqualStrings("2998", first);
    try app.handle(.{ .key = Key.char('N') });
    try t.expectEqual(@as(?usize, 1), p.search.current);
    // Still painted in terminal-normal after the bar closed; `i` back
    // to the child hides them.
    try app.render();
    const at2 = cellOf(&app, "2999") orelse return error.TestUnexpectedResult;
    try t.expect(Theme.Color.eql(app.screen.readCell(at2.x, at2.y).?.style.bg, app.theme.current_match.bg));
    const at3 = cellOf(&app, "2998") orelse return error.TestUnexpectedResult;
    try t.expect(Theme.Color.eql(app.screen.readCell(at3.x, at3.y).?.style.bg, app.theme.match.bg));
    try app.handle(.{ .key = Key.char('i') });
    try app.render();
    try t.expect(!Theme.Color.eql(app.screen.readCell(at3.x, at3.y).?.style.bg, app.theme.match.bg));
}

test "scrollback search (standard): Ctrl+F opens it, Enter / Shift+Enter step with wrap and scroll the match into view, Esc closes with the match selected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 400; sleep 30" }, .label = "seq" });
    try t.expect(try pty_pane.tickUntilScreen(&app, "400", 5000));
    const p = app.panes.pty(id).?;
    try app.handle(.{ .key = Key.ctrl('f') });
    try t.expect(app.find_bar != null and app.find_bar.?.pane == id);
    // `^11` — lines 11 and 110–119: eleven, the newest current.
    try app.handle(.{ .key = Key.ctrl('r') });
    try typeText(&app, "^11");
    try settleScan(&app, p);
    try t.expectEqual(@as(usize, 11), p.search.matches.items.len);
    try t.expectEqual(@as(?usize, 10), p.search.current);
    // Enter: the next, wrapping to line 11, scrolled into view.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar != null);
    try t.expectEqual(@as(?usize, 0), p.search.current);
    try app.render();
    const top = viewTop(termOf(p).?);
    const m = p.search.matches.items[0];
    try t.expect(m.y0 >= top and m.y0 < top + termOf(p).?.rows - 1);
    // Shift+Enter: back to 119.
    try app.handle(.{ .key = .{ .code = .enter, .mods = .{ .shift = true } } });
    try t.expectEqual(@as(?usize, 10), p.search.current);
    // Esc: the bar goes, the matches stop painting, the selection is 11 of `119`.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.find_bar == null);
    try t.expect(!p.search.shown);
    const sel = termOf(p).?.screens.active.selection orelse return error.TestUnexpectedResult;
    const s = try termOf(p).?.screens.active.selectionString(t.allocator, .{ .sel = sel });
    defer t.allocator.free(s);
    try t.expectEqualStrings("11", s);
    // The terminal's copy takes it.
    try command.run(&app, .{ .static = .@"term.copy" });
    try t.expectEqualStrings("11", app.clipboard.text());
    const line = try lineOf(p, p.search.matches.items[10].y0);
    defer t.allocator.free(line);
    try t.expectEqualStrings("119", line);
    // Ctrl+F again brings the query back, selected.
    try app.handle(.{ .key = Key.ctrl('f') });
    try t.expectEqualStrings("^11", app.find_bar.?.state.queryText());
    try t.expect(app.find_bar.?.state.select_all);
    // The standard profile's regex is the one a VS Code user types:
    // `(` `|` `)` group and alternate — the query replaces the selection.
    try typeText(&app, "^(11|119)$");
    try settleScan(&app, p);
    try t.expectEqual(@as(usize, 2), p.search.matches.items.len);
}

/// How many times `99` is in the lines `from`..`to`, as the literal
/// search counts them (non-overlapping, left to right).
fn count99(from: u32, to: u32) usize {
    var want: usize = 0;
    var n = from;
    while (n <= to) : (n += 1) {
        var buf: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        var i: usize = 0;
        while (i + 2 <= line.len) {
            if (line[i] == '9' and line[i + 1] == '9') {
                want += 1;
                i += 2;
            } else i += 1;
        }
    }
    return want;
}

/// Every match reads `99`, and there is one per `99` in the lines the
/// terminal still holds, which end at `last`. Returns the first line.
fn expectAll99(p: *PtyPane, last: u32) !u32 {
    const first = try lineOf(p, 0);
    defer t.allocator.free(first);
    const n0 = try std.fmt.parseInt(u32, first, 10);
    try t.expectEqual(count99(n0, last), p.search.matches.items.len);
    for (p.search.matches.items) |m| {
        const s = try textOf(p, m);
        defer t.allocator.free(s);
        try t.expectEqualStrings("99", s);
    }
    return n0;
}

test "scrollback search survives output: the oldest rows dropping shifts the matches with them, the current one is kept while it exists, new lines are searched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 40, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 3000; read x; seq 3001 4000; read x; seq 4001 6500; sleep 30" }, .label = "seq" });
    const p = app.panes.pty(id).?;
    // A scrollback short enough that the later batches push the oldest
    // pages out (the terminal drops whole pages, a thousand-odd rows).
    termOf(p).?.screens.active.pages.setMaxLines(3500);
    try t.expect(try pty_pane.tickUntilScreen(&app, "3000", 5000));
    try app.handle(.{ .key = Key.ctrl('f') });
    try typeText(&app, "99");
    try settleScan(&app, p);
    const first1 = try expectAll99(p, 3000);
    // The current match is line 2999's.
    const cur = p.search.matches.items[p.search.current.?];
    const before_line = try lineOf(p, cur.y0);
    defer t.allocator.free(before_line);
    try t.expectEqualStrings("2999", before_line);
    // The second batch drops the oldest page; line 2999 stays.
    p.write("\r");
    try t.expect(try pty_pane.tickUntilScreen(&app, "4000", 5000));
    try settleScan(&app, p);
    const first2 = try expectAll99(p, 4000);
    try t.expect(first2 > first1);
    const kept = p.search.matches.items[p.search.current.?];
    const kept_line = try lineOf(p, kept.y0);
    defer t.allocator.free(kept_line);
    try t.expectEqualStrings("2999", kept_line);
    // The third drops line 2999 too: the match nearest the bottom of
    // the view is current again, as for a fresh query.
    p.write("\r");
    try t.expect(try pty_pane.tickUntilScreen(&app, "6500", 5000));
    try settleScan(&app, p);
    try t.expect(try expectAll99(p, 6500) > 2999);
    try t.expectEqual(@as(?usize, p.search.matches.items.len - 1), p.search.current);
    const newest = try lineOf(p, p.search.matches.items[p.search.current.?].y0);
    defer t.allocator.free(newest);
    try t.expectEqualStrings("6499", newest);
}

test "scrollback search: a pattern that does not compile matches nothing and Enter says so; an empty query clears; lower case matches either case, a capital only itself" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 40, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "echo Alpha beta; sleep 30" }, .label = "ab" });
    try t.expect(try pty_pane.tickUntilScreen(&app, "Alpha beta", 5000));
    const p = app.panes.pty(id).?;
    try app.handle(.{ .key = Key.ctrl('x') });
    try app.handle(.{ .key = Key.char('/') });
    // An unclosed vim group.
    try app.handle(.{ .key = Key.ctrl('r') });
    try typeText(&app, "a\\(");
    try t.expect(p.search.bad_pattern != null);
    try t.expectEqual(@as(usize, 0), p.search.matches.items.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.find_bar == null);
    // The regex chip is sticky; a fresh `/` starts empty.
    try app.handle(.{ .key = Key.char('/') });
    try t.expect(app.find_bar.?.state.regex);
    try typeText(&app, "a");
    try settleScan(&app, p);
    // `Alpha` twice (A, a), `beta` once: a lower-case query is either case.
    try t.expectEqual(@as(usize, 3), p.search.matches.items.len);
    try app.handle(.{ .key = Key.named(.backspace) });
    try t.expect(!p.search.active());
    try t.expectEqual(@as(usize, 0), p.search.matches.items.len);
    try typeText(&app, "A");
    try settleScan(&app, p);
    try t.expectEqual(@as(usize, 1), p.search.matches.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.find_bar == null);
}
