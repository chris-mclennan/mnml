//! What both pty backends hand the pane: the reader's wakeup and how the
//! child ended. `session_posix.zig` and `session_windows.zig` re-export
//! these so `pty.session.Exit` names one type whichever backend is in.
//! Both also take their thread-shared locks from here.

const std = @import("std");
const vt = @import("ghostty-vt");

/// The most bytes one `Session.pump` feeds the terminal. A pump takes
/// what was in the ring when it started, up to this, and returns: a
/// child flooding short lines (`yes`) refills the ring as fast as the
/// terminal parses it, and a pump that chased it until empty never gave
/// the loop back to the keyboard (Ctrl+C took 4-18 s to arrive). What
/// is left is taken on the next pass; `Session.backlog` says there is
/// some, and the loop does not sleep while it is true.
pub const pump_budget: usize = 64 * 1024;

/// `terminal.scrollback_lines`' default: what a build log needs to keep
/// its first error. The library's own default is 10 KB — about 500 lines.
pub const default_scrollback_lines: usize = 10_000;

/// The `Terminal` every session runs, whichever backend. Scrollback is
/// bounded by lines, not bytes (ghostty's `scrollback-limit-lines`), so
/// the number the user sets is the number they get.
pub fn terminalOptions(cols: u16, rows: u16, scrollback_lines: usize) vt.Terminal.Options {
    return .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = scrollback_lines,
        // Mode 2027 on, as ghostty's `grapheme-width-method = unicode`
        // sets it and as mnml's own canvas asks its host for: 👍🏽 and 🇺🇸
        // are one two-cell cluster, a ZWJ family keeps its joiners, ❤️
        // takes VS16's width — so the child, the pane's grid and the
        // host agree on where every later cell of the row is.
        .default_modes = .{ .grapheme_cluster = true },
    };
}

/// Called from the reader thread: once when the ring goes from empty to
/// readable (see `Ring.commit`), and once when the child's output ends.
/// The UI side answers by calling `Session.pump`. The call is made under
/// the session's notify lock, and `Session.deinit` disarms it under that
/// same lock before letting go — so `ctx` only has to outlive the
/// *session*, not the detached reader. The callback must therefore never
/// block on something the UI thread provides (a full event queue drained
/// only by the UI thread would deadlock a `deinit` waiting for the lock).
pub const Notify = struct {
    ctx: ?*anyopaque = null,
    fn_ptr: ?*const fn (?*anyopaque) void = null,

    pub const none: Notify = .{};

    pub fn call(self: Notify) void {
        if (self.fn_ptr) |f| f(self.ctx);
    }
};

pub const Exit = union(enum) {
    /// Normal exit with this status code.
    code: u8,
    /// Killed by this signal. On Windows: an exit code above 255 — the
    /// NTSTATUS-shaped ones (`0xC0000005` access violation, `0xC000013A`
    /// ctrl-C) — which is the closest thing the platform has to a death
    /// by signal.
    signal: u32,

    pub fn ok(self: Exit) bool {
        return self == .code and self.code == 0;
    }
};

/// The terminal half of `Session.resize`, shared by both backends. The
/// pty is sized first and the grid second, as ghostty orders it; what
/// this adds is the part of ghostty's resize the library mnml pins no
/// longer does, and a shell at its prompt depends on.
///
/// On SIGWINCH zsh (and readline) redraws its prompt by moving the
/// cursor UP the number of rows the prompt took *before* the resize,
/// clearing to the end of the screen, and printing it again. That only
/// works if the cursor is still that many rows below the prompt's first
/// row. Reflow breaks it: narrowed, a prompt row that wraps pushes the
/// cursor a row down, the climb stops a row short, and the row it
/// should have cleared stays behind as a blank one — one more with
/// every resize. The ghostty people run (1.3.1) does not do that: it
/// keeps the cursor on its row. The library here (1.3.2-dev) moved the
/// prompt clear after the reflow and lets a cursor sitting past the
/// row's text drag the blanks along with it, and both walk the cursor
/// down. `keepCursorRow` puts the older order back before the reflow.
pub fn resizeGrid(handler: *vt.TerminalStream.Handler, cols: u16, rows: u16) !void {
    keepCursorRow(handler.terminal, cols);
    try handler.resize(.{ .cols = cols, .rows = rows });
}

/// Before a reflow to `new_cols`: a prompt the shell will redraw
/// (OSC 133 marked it, and did not say `redraw=0`) is cleared now, so
/// it reflows as the blank rows it is about to become and keeps its row
/// count; and a cursor in the blanks past the end of its row's text is
/// pulled back onto the row it is on. Only the primary screen reflows.
fn keepCursorRow(term: *vt.Terminal, new_cols: u16) void {
    if (term.screens.active_key != .primary) return;
    const screen = term.screens.active;
    const redraw = term.flags.shell_redraws_prompt;
    if (redraw != .false and screen.cursor.semantic_content != .output) clearPrompt(screen, redraw == .last);
    clampCursor(screen, term.cols, new_cols);
}

/// Blank the prompt the cursor is on — every row from where it started
/// down, or with `last_only` the cursor's row — as the library does
/// after its reflow. The rows lose their wrap flags too: a blank row
/// has nothing to carry onto the next, and a chain of them would
/// otherwise reflow into a different number of rows than the shell
/// counted.
fn clearPrompt(screen: *vt.Screen, last_only: bool) void {
    const cursor = &screen.cursor;
    if (last_only) {
        const page = cursor.page_pin.node.page();
        screen.clearCells(page, cursor.page_row, page.getCells(cursor.page_row));
        cursor.page_pin.markDirty();
        return;
    }
    var prompts = cursor.page_pin.promptIterator(.left_up, null);
    const start = prompts.next() orelse return;
    var rows = start.rowIterator(.right_down, null);
    var first = true;
    while (rows.next()) |pin| {
        const page = pin.node.page();
        const row = pin.rowAndCell().row;
        screen.clearCells(page, row, page.getCells(row));
        row.wrap = false;
        // The prompt's first row may still continue whatever was above
        // it; that row keeps its wrap, so this one keeps the link.
        if (!first) row.wrap_continuation = false;
        first = false;
        pin.markDirty();
    }
}

/// A cursor past the end of its row's text — where a shell leaves it
/// after the prompt — stays on the row that text starts on, at most at
/// its last column, rather than following the blanks onto a wrapped
/// row. What ghostty 1.3.1's reflow does with it, and so where the shell
/// expects it when it redraws.
fn clampCursor(screen: *vt.Screen, old_cols: u16, new_cols: u16) void {
    const cursor = &screen.cursor;
    if (cursor.page_row.wrap) return; // its text goes on to the next row
    const cells = cursor.page_pin.cells(.all);
    var len: usize = cells.len;
    while (len > 0 and cells[len - 1].isEmpty()) len -= 1;
    if (cursor.x < len) return;
    // Where this row starts once reflowed: its place in the logical
    // line, the rows before it in the chain being full.
    var before: usize = 0;
    var pin = cursor.page_pin.*;
    while (pin.rowAndCell().row.wrap_continuation) : (before += 1) pin = pin.up(1) orelse break;
    const start_x = (before * old_cols) % new_cols;
    const last = new_cols - 1 - start_x;
    if (cursor.x > last) screen.cursorHorizontalAbsolute(@intCast(last));
}

/// The text a child's clipboard write carries (OSC 52, or the first
/// text representation of an OSC 5522 one); null for a clear or a write
/// with no text in it.
pub fn clipboardText(w: vt.clipboard.Write) ?[]const u8 {
    for (w.contents) |c| if (vt.clipboard.isTextMime(c.mime)) return c.data;
    return null;
}

/// A test-and-set lock for the short critical sections the backends
/// share with their threads (the notify callback, the outbox). A
/// spinlock because the other side is a raw thread with no `Io` to
/// park on, and every section is a handful of instructions or a
/// bounded memcpy.
pub const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A terminal fed what a shell writes, resized as a session resizes it.
/// What zsh writes on SIGWINCH is replayed by hand (captured from zsh
/// 5.9): `\r`, up the rows its prompt took before the resize, clear to
/// the end of the screen, the prompt again.
const Shell = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,

    fn init(self: *Shell, cols: u16, rows: u16) !void {
        self.term = try .init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows });
        self.stream = self.term.vtStream();
    }

    fn deinit(self: *Shell) void {
        self.stream.deinit();
        self.term.deinit(testing.allocator);
    }

    fn feed(self: *Shell, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    fn resize(self: *Shell, cols: u16) !void {
        try resizeGrid(&self.stream.handler, cols, self.term.rows);
    }

    /// Row `y` of the screen, trailing blanks dropped, into `buf`.
    fn row(self: *Shell, y: u16, buf: []u8) []const u8 {
        var n: usize = 0;
        var x: u16 = 0;
        while (x < self.term.cols) : (x += 1) {
            const cell = self.term.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = y } }) orelse break;
            const cp = cell.cell.codepoint();
            buf[n] = if (cp == 0) ' ' else @intCast(cp);
            n += 1;
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
    }

    fn expectRows(self: *Shell, want: []const []const u8) !void {
        var buf: [256]u8 = undefined;
        for (want, 0..) |w, y| try testing.expectEqualStrings(std.mem.trimEnd(u8, w, " "), self.row(@intCast(y), &buf));
        try testing.expectEqualStrings("", self.row(@intCast(want.len), &buf));
    }
};

const text = "0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij > ";

test "a prompt that wraps when its pane narrows is redrawn in place: one blank row above it, twice over" {
    var sh: Shell = undefined;
    try sh.init(118, 12);
    defer sh.deinit();
    // `PROMPT=$'\n…'`: a blank row, then one line of 83 cells.
    sh.feed("TOP\r\n\r\n" ++ text);

    // 118 → 58: the line takes two rows now. zsh climbs the one row
    // above the line it counted and prints the prompt from there.
    try sh.resize(58);
    try testing.expectEqual(@as(u16, 2), sh.term.screens.active.cursor.y);
    sh.feed("\r\r\x1b[A\x1b[J\r\n" ++ text);
    try sh.expectRows(&.{ "TOP", "", text[0..58], text[58..] });

    // 58 → 38, with the cursor on the second of those rows: it climbs 2.
    try sh.resize(38);
    try testing.expectEqual(@as(u16, 3), sh.term.screens.active.cursor.y);
    sh.feed("\r\r\x1b[A\x1b[A\x1b[J\r\n" ++ text);
    try sh.expectRows(&.{ "TOP", "", text[0..38], text[38..76], text[76..] });
}

test "a cursor inside its row's text, or on a row that still fits, is where the reflow puts it" {
    var sh: Shell = undefined;
    try sh.init(118, 8);
    defer sh.deinit();
    sh.feed(text ++ "\x1b[11G");
    try sh.resize(38);
    try testing.expectEqual(@as(u16, 10), sh.term.screens.active.cursor.x);
    try testing.expectEqual(@as(u16, 0), sh.term.screens.active.cursor.y);

    var short: Shell = undefined;
    try short.init(118, 8);
    defer short.deinit();
    short.feed("% ");
    try short.resize(38);
    try testing.expectEqual(@as(u16, 2), short.term.screens.active.cursor.x);
}

test "a marked prompt (OSC 133) of three lines keeps its rows through a narrowing and a widening" {
    // What ghostty's zsh integration makes of `PROMPT=$'\n…\n> '`.
    const prompt = "\x1b]133;A;cl=line\x07\r\n\x1b]133;P;k=s\x07" ++ text[0..80] ++ "\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07";
    var sh: Shell = undefined;
    try sh.init(118, 12);
    defer sh.deinit();
    sh.feed("TOP\r\n" ++ prompt);

    try sh.resize(58);
    try testing.expectEqual(@as(u16, 3), sh.term.screens.active.cursor.y);
    sh.feed("\r\r\x1b[A\x1b[A\x1b[J" ++ prompt);
    try sh.expectRows(&.{ "TOP", "", text[0..58], text[58..80], ">" });

    // Wider again: the climb is the three rows it took at 58, and the
    // row above the prompt is still there when it is done.
    try sh.resize(118);
    try testing.expectEqual(@as(u16, 4), sh.term.screens.active.cursor.y);
    sh.feed("\r\r\x1b[3A\x1b[J" ++ prompt);
    try sh.expectRows(&.{ "TOP", "", text[0..80], ">" });
}

test "the alternate screen is left to the library: it does not reflow" {
    var sh: Shell = undefined;
    try sh.init(118, 8);
    defer sh.deinit();
    sh.feed("\x1b[?1049h" ++ text);
    try sh.resize(38);
    try testing.expectEqual(@as(u16, 37), sh.term.screens.active.cursor.x);
    try testing.expectEqual(@as(u16, 0), sh.term.screens.active.cursor.y);
}
