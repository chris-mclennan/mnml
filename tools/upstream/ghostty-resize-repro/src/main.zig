//! libghostty-vt: a resize that wraps an OSC 133 prompt (redraw=1)
//! leaves the prompt's first row behind, and moves the cursor a row
//! further below the prompt's start than the shell expects.
//!
//!   zig build run -Dghostty=pinned   # ghostty c81f0b26 (1.3.2-dev)
//!   zig build run -Dghostty=main     # ghostty 5dc28bb8 (main, 2026-10-04)
//!
//! `ghostty_main` in build.zig.zon is a pin like any other; the weekly
//! upstream watch moves it to the day's main in its own checkout only
//! (`zig fetch --save=ghostty_main <archive url>`).
//!
//! No pty and no shell: the program writes, after each Terminal.resize,
//! the bytes zsh 5.9 writes on SIGWINCH at an idle prompt (captured from
//! a real zsh; see `zshRedraw`). zsh moves up the number of rows its prompt
//! took at the OLD width minus one, clears to the end of the screen, and
//! prints the prompt again. That only lands on the prompt's first row if
//! the terminal kept the cursor that many rows below it.
//!
//! For each resize it prints:
//!   - the cursor before/after Terminal.resize, and how many rows the
//!     cursor ends up below the row zsh will climb back to;
//!   - the screen right after Terminal.resize (before the shell redraws);
//!   - the screen after zsh's redraw, compared row by row with a terminal
//!     that had the new width all along and was sent the same bytes.
//!
//! Each scenario runs in three modes:
//!   lib              Terminal.resize only.
//!   preclear-1.3.1   Before Terminal.resize, do by hand what v1.3.1's
//!                    Screen.resize did before its reflow: clear the
//!                    redrawable prompt; and keep a cursor that sits in the
//!                    blanks past its row's text on that row (v1.3.1's reflow
//!                    moved such a pin to the last column instead of wrapping
//!                    the blanks with it).
//!   preclear-unwrap  As preclear-1.3.1, and also drop the soft-wrap flags of
//!                    the cleared rows, so blank rows do not re-join when the
//!                    terminal is widened.
//!
//! After the summary, one verdict line on the `lib` mode alone — the
//! library with nothing done by hand:
//!   RESIZE-REDRAW: still broken      some resize left the screen wrong
//!   RESIZE-REDRAW: FIXED upstream    every resize matched a fresh render
//! With `--expect=broken` or `--expect=fixed` (`-Dexpect=` through the
//! build) the exit code says whether the verdict is the expected one:
//! 0 when it is, 1 when it is not. Without it the run always exits 0.

const std = @import("std");
const vt = @import("ghostty-vt");

const rows: u16 = 12;

const Scenario = struct {
    name: []const u8,
    /// The prompt's lines; the cursor ends after the last one.
    lines: []const []const u8,
    /// Column counts to resize through, starting at the first.
    widths: []const u16,
};

// 28 columns. With " $ " the one-line prompt is 31 cells and the cursor
// sits on the 32nd: one row at 40 columns, two at 20.
const long = "PROMPT-user@host:~/some/path";

const scenarios = [_]Scenario{
    .{ .name = "A: one-line prompt, narrow/widen x3", .lines = &.{long ++ " $ "}, .widths = &.{ 40, 20, 40, 20, 40, 20, 40 } },
    .{ .name = "B: two-line prompt (long first line), narrow/widen x3", .lines = &.{ long, "> " }, .widths = &.{ 40, 20, 40, 20, 40, 20, 40 } },
    .{ .name = "C: one-line prompt, narrowed step by step", .lines = &.{long ++ " $ "}, .widths = &.{ 40, 34, 28, 22, 16 } },
};

const Mode = enum { lib, @"preclear-1.3.1", @"preclear-unwrap" };

const Verdict = enum { broken, fixed };

pub fn main(init: std.process.Init) !u8 {
    var expect: ?Verdict = null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| {
        if (!std.mem.startsWith(u8, a, "--expect=")) continue;
        const want = a["--expect=".len..];
        expect = std.meta.stringToEnum(Verdict, want) orelse {
            std.debug.print("--expect must be broken or fixed, not {s}\n", .{want});
            return 2;
        };
    }

    var totals: [scenarios.len][3]usize = undefined;
    for (scenarios, 0..) |sc, i| {
        for (std.enums.values(Mode), 0..) |mode, j| totals[i][j] = try run(init.io, init.gpa, sc, mode);
    }
    std.debug.print("\n===== SUMMARY (resizes after which the screen differs from a fresh render)\n", .{});
    for (scenarios, 0..) |sc, i| {
        std.debug.print("  {s}\n", .{sc.name});
        for (std.enums.values(Mode), 0..) |mode, j|
            std.debug.print("      {t:<16} {d}/{d}\n", .{ mode, totals[i][j], sc.widths.len - 1 });
    }

    // The verdict is the library's own: `lib` mode, nothing done by hand.
    var lib_wrong: usize = 0;
    for (totals) |t| lib_wrong += t[@intFromEnum(Mode.lib)];
    const seen: Verdict = if (lib_wrong == 0) .fixed else .broken;
    std.debug.print("\nRESIZE-REDRAW: {s}\n", .{switch (seen) {
        .broken => "still broken",
        .fixed => "FIXED upstream",
    }});
    if (expect) |e| if (e != seen) return 1;
    return 0;
}

/// Rows a line of `len` cells takes at `cols`, counting the cursor's cell
/// when it is the line the cursor ends on.
fn rowsFor(len: usize, cols: u16, has_cursor: bool) usize {
    const n = len + @intFromBool(has_cursor);
    return @max(1, (n + cols - 1) / cols);
}

/// Rows from the prompt's first row down to the cursor's, as zsh counts
/// them at `cols`.
fn shellClimb(sc: Scenario, cols: u16) usize {
    var h: usize = 0;
    for (sc.lines, 0..) |l, i| h += rowsFor(l.len, cols, i == sc.lines.len - 1);
    return h - 1;
}

/// The prompt as a shell with OSC 133 integration prints it.
fn printPrompt(s: anytype, sc: Scenario) void {
    s.nextSlice("\x1b]133;A;redraw=1\x07");
    for (sc.lines, 0..) |l, i| {
        if (i > 0) s.nextSlice("\r\n");
        s.nextSlice(l);
    }
    s.nextSlice("\x1b]133;B\x07");
}

/// What zsh 5.9 writes on SIGWINCH at an idle prompt (recorded from a real
/// zsh -f): CR CR, one CUU per row the prompt took at the old width beyond
/// the first, SGR resets, ED, the prompt.
fn zshRedraw(s: anytype, sc: Scenario, old_cols: u16) void {
    s.nextSlice("\r\r");
    for (0..shellClimb(sc, old_cols)) |_| s.nextSlice("\x1b[A");
    s.nextSlice("\x1b[0m\x1b[27m\x1b[24m\x1b[J");
    printPrompt(s, sc);
}

const history = "\x1b]133;A\x07$ true\x1b]133;B\x07\r\n\x1b]133;C\x07OUTPUT-1\r\nOUTPUT-END\r\n\x1b]133;D;0\x07";

fn rowText(t: *vt.Terminal, y: u16, buf: []u8) []const u8 {
    const p = t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = y } }) orelse return "";
    var n: usize = 0;
    for (p.cells(.all)) |c| {
        const cp = c.codepoint();
        buf[n] = if (cp == 0) ' ' else if (cp < 128) @intCast(cp) else '?';
        n += 1;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

fn dump(t: *vt.Terminal) void {
    var buf: [256]u8 = undefined;
    const c = t.screens.active.cursor;
    var y: u16 = 0;
    while (y < t.rows) : (y += 1) {
        const text = rowText(t, y, &buf);
        if (text.len == 0 and y > c.y + 1) continue;
        std.debug.print("      {d:>2} |{s}|{s}\n", .{ y, text, if (y == c.y) " <- cursor" else "" });
    }
}

/// v1.3.1's pre-reflow prompt handling, done by hand before
/// Terminal.resize (see the file comment).
fn preclear(t: *vt.Terminal, new_cols: u16, unwrap: bool) void {
    const screen = t.screens.active;
    if (t.flags.shell_redraws_prompt != .false and screen.cursor.semantic_content != .output) {
        var prompts = screen.cursor.page_pin.promptIterator(.left_up, null);
        if (prompts.next()) |start| {
            var it = start.rowIterator(.right_down, null);
            var first = true;
            while (it.next()) |p| {
                const page = p.node.page();
                const row = p.rowAndCell().row;
                screen.clearCells(page, row, page.getCells(row));
                if (unwrap) {
                    row.wrap = false;
                    if (!first) row.wrap_continuation = false;
                }
                first = false;
            }
        }
    }
    if (!screen.cursor.page_row.wrap) {
        const cells = screen.cursor.page_pin.cells(.all);
        var len: usize = cells.len;
        while (len > 0 and cells[len - 1].isEmpty()) len -= 1;
        if (screen.cursor.x >= len and screen.cursor.x > new_cols - 1)
            screen.cursorHorizontalAbsolute(new_cols - 1);
    }
}

/// Compare with a terminal that had `t.cols` columns all along and was
/// sent the same history and prompt. Prints each differing row.
fn compareFresh(io: std.Io, gpa: std.mem.Allocator, t: *vt.Terminal, sc: Scenario) !bool {
    var f = try vt.Terminal.init(io, gpa, .{ .cols = t.cols, .rows = rows });
    defer f.deinit(gpa);
    var fs = f.vtStream();
    defer fs.deinit();
    fs.nextSlice(history);
    printPrompt(&fs, sc);

    var same = true;
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        const got = rowText(t, y, &a);
        const want = rowText(&f, y, &b);
        if (!std.mem.eql(u8, got, want)) {
            same = false;
            std.debug.print("      row {d:>2}: got |{s}|  want |{s}|\n", .{ y, got, want });
        }
    }
    const gc = t.screens.active.cursor;
    const fc = f.screens.active.cursor;
    if (gc.x != fc.x or gc.y != fc.y) {
        same = false;
        std.debug.print("      cursor: got row {d} col {d}  want row {d} col {d}\n", .{ gc.y, gc.x, fc.y, fc.x });
    }
    return same;
}

fn run(io: std.Io, gpa: std.mem.Allocator, sc: Scenario, mode: Mode) !usize {
    var t = try vt.Terminal.init(io, gpa, .{ .cols = sc.widths[0], .rows = rows });
    defer t.deinit(gpa);
    var s = t.vtStream();
    defer s.deinit();

    std.debug.print("\n===== {s} [{t}]\n", .{ sc.name, mode });
    s.nextSlice(history);
    printPrompt(&s, sc);
    std.debug.print("  start at {d} columns:\n", .{t.cols});
    dump(&t);

    var bad: usize = 0;
    for (sc.widths[0 .. sc.widths.len - 1], sc.widths[1..]) |cols, new_cols| {
        const pages = &t.screens.active.pages;
        const before = t.screens.active.cursor;

        // The row zsh will climb back to, tracked through the resize.
        const climb = shellClimb(sc, cols);
        const target = try pages.trackPin(pages.pin(.{ .active = .{
            .x = 0,
            .y = before.y - @as(u16, @intCast(climb)),
        } }).?);
        defer pages.untrackPin(target);

        switch (mode) {
            .lib => {},
            .@"preclear-1.3.1" => preclear(&t, new_cols, false),
            .@"preclear-unwrap" => preclear(&t, new_cols, true),
        }
        try t.resize(gpa, .{ .cols = new_cols, .rows = rows });

        const c = t.screens.active.cursor;
        const target_y: i32 = @intCast(pages.pointFromPin(.active, target.*).?.active.y);
        const below = @as(i32, c.y) - target_y;
        std.debug.print("\n  resize {d} -> {d}: cursor row {d} -> {d}, col {d} -> {d}; {d} row(s) below the row zsh climbs back to, zsh climbs {d}{s}\n", .{
            cols,                                                                                                                      new_cols, before.y, c.y, before.x, c.x, below, climb,
            if (below > climb) "  => climb stops SHORT" else if (below < climb) "  => climb OVERSHOOTS into the output above" else "",
        });
        std.debug.print("    right after Terminal.resize:\n", .{});
        dump(&t);

        zshRedraw(&s, sc, cols);
        std.debug.print("    after zsh's redraw:\n", .{});
        dump(&t);
        if (try compareFresh(io, gpa, &t, sc)) {
            std.debug.print("    OK: same as a terminal {d} columns wide all along\n", .{new_cols});
        } else {
            bad += 1;
            std.debug.print("    WRONG: differs from a terminal {d} columns wide all along (rows above)\n", .{new_cols});
        }
    }
    return bad;
}
