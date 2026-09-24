//! The JOBS overlay: every background job mnml started, in one list.
//!
//! A modal box (`overlay.frameLook`, titled ` Jobs `) with a `ListPanel`
//! inside it — the same caps header, row ground, selection marker,
//! scrollbar and empty state the activity panels wear, so the list reads
//! as one of them. Two sections: RUNNING, each job with how long it has
//! been going and, where the job can be stopped, a Cancel row under it;
//! then FINISHED, the last fifty with their outcome and how long they
//! took. The hint row names the keys.
//!
//! The rows are the app's (`app/jobs.zig` builds them each frame from
//! the registry, spinner frame and elapsed already spelled); this file
//! only paints them. Every row registers `.row{ .jobs, idx }` through
//! the panel, so the app routes a click the way it routes a panel's.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const list_panel = @import("list_panel.zig");

pub const Tone = enum { accent, ok, failed, muted };

/// One painted row. Every slice is the caller's (the frame arena).
pub const Row = struct {
    kind: Kind,
    /// The registry's job id; 0 on a section row.
    id: u32 = 0,
    /// The status mark: the spinner's frame, `✓`, `✗`, `⊘`.
    mark: []const u8 = "",
    tone: Tone = .muted,
    /// The job's kind word (`git`, `lsp`, `tests`).
    what: []const u8 = "",
    label: []const u8 = "",
    /// Progress while running, the outcome's words once finished.
    detail: []const u8 = "",
    /// `3.2s` — elapsed while running, the duration once finished.
    right: []const u8 = "",

    pub const Kind = enum { section, running, cancel, finished };
};

pub const Panel = list_panel.ListPanel(Row);

/// The status marks, each with its `--ascii` twin.
pub const ok_glyph = "\u{2713}";
pub const ok_ascii = "+";
pub const failed_glyph = "\u{2717}";
pub const failed_ascii = "x";
pub const cancelled_glyph = "\u{2298}";
pub const cancelled_ascii = "-";
pub const cancel_glyph = "\u{2715}";
pub const cancel_ascii = "x";

pub const hint = "↑↓ move · ⏎ open · c cancel · Esc close";

/// The kind column: the widest kind word plus a cell.
const what_w: u16 = 9;

fn toneStyle(t: *const Theme, ground: Theme.Style, tone: Tone) Theme.Style {
    return Theme.withFg(ground, switch (tone) {
        .accent => t.accent.fg,
        .ok => t.palette.green,
        .failed => t.palette.red,
        .muted => t.muted.fg,
    });
}

fn rowGround(t: *const Theme, selected: bool) Theme.Style {
    return list_panel.rowStyle(t, selected);
}

fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const g = rowGround(t, selected);
    switch (row.kind) {
        .section => {
            var s = Theme.withFg(g, t.accent.fg);
            s.bold = true;
            _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(row.label, r.w -| 1), s);
        },
        .cancel => {
            const text = ui.fmt("{s} Cancel", .{if (ui.ascii) cancel_ascii else cancel_glyph});
            _ = ui.putStr(r.x + 4, r.y, r.w -| 4, ui.clipStr(text, r.w -| 4), Theme.withFg(g, t.palette.red));
        },
        .running, .finished => {
            var x = r.x + 1;
            const end = r.x + r.w;
            // The right column first, so the label knows where to stop.
            const right_w: u16 = if (row.right.len == 0) 0 else ui.width(row.right) + 1;
            const stop = end -| right_w;
            if (right_w > 0 and right_w < r.w) _ = ui.putStrRight(end -| 1, r.y, right_w, row.right, Theme.withFg(g, t.muted.fg));
            if (x < stop) x += ui.putStr(x, r.y, stop - x, row.mark, toneStyle(t, g, row.tone));
            x += 1;
            if (x < stop) {
                const w = @min(what_w, stop - x);
                _ = ui.putStr(x, r.y, w, ui.clipStr(row.what, w), Theme.withFg(g, t.muted.fg));
                x += w;
            }
            if (x < stop) x += ui.putStr(x, r.y, stop - x, ui.clipStr(row.label, stop - x), Theme.withFg(g, t.fg.fg));
            if (row.detail.len > 0 and x + 3 < stop) {
                const text = ui.fmt(" · {s}", .{row.detail});
                const detail_tone: Tone = if (row.tone == .failed) .failed else .muted;
                _ = ui.putStr(x, r.y, stop - x, ui.clipStr(text, stop - x), toneStyle(t, g, detail_tone));
            }
        },
    }
}

/// The box: seven tenths of the screen wide (48..100), as tall as the
/// rows need up to eight tenths of it, a third of the way down.
pub fn place(screen: Rect, rows: usize) Rect {
    const w: u16 = std.math.clamp(screen.w * 7 / 10, @min(48, screen.w), @min(100, screen.w));
    // Frame, header, the rows, the hint.
    const want: usize = rows + 4;
    const cap: u16 = @max(8, screen.h * 8 / 10);
    const h: u16 = @intCast(@min(@max(want, 8), @min(cap, screen.h)));
    return overlay.place(screen, w, h, .third);
}

/// Paints the overlay over `screen`. `subtitle` is the header's
/// `(2 running · 12 finished)`.
pub fn draw(ui: Ui, screen: Rect, st: *Panel.State, rows: []const Row, subtitle: []const u8) void {
    if (screen.w < 20 or screen.h < 6) return;
    // The caps header below names the list; a frame title would say it
    // twice.
    const inner = overlay.frameLook(ui, place(screen, rows.len), null, .modal);
    if (inner.isEmpty() or inner.h < 3) return;
    const parts = inner.splitBottom(1);
    _ = Panel.draw(st, ui, parts.top, .{
        .panel = .jobs,
        .label = "JOBS",
        .subtitle = subtitle,
        .rows = rows,
        .paintRow = paintRow,
        .show_filter = false,
        .show_refresh = false,
        .focused = true,
        .empty = .{ .message = "No background jobs yet", .hint = "language servers, git fetches, test runs and sends land here" },
    });
    overlay.hint(ui, parts.rest, hint);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @import("test_fixture.zig");

test "place: seven tenths wide, as tall as the rows, never past the screen" {
    const screen = Rect.init(0, 0, 120, 40);
    const small = place(screen, 2);
    try testing.expectEqual(@as(u16, 84), small.w);
    try testing.expectEqual(@as(u16, 8), small.h);
    const big = place(screen, 200);
    try testing.expectEqual(@as(u16, 32), big.h);
    const tiny = place(Rect.init(0, 0, 30, 10), 50);
    try testing.expect(tiny.w <= 30 and tiny.h <= 10);
}

test "draw: the sections, a running row with its Cancel row, a finished failure, the hint; rows register as the jobs panel's" {
    var f = try fixture.init(100, 30);
    defer f.deinit();
    const ui = f.ui();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    const rows = [_]Row{
        .{ .kind = .section, .label = "RUNNING (1)" },
        .{ .kind = .running, .id = 3, .mark = "⠋", .tone = .accent, .what = "git", .label = "fetch", .right = "2.1s" },
        .{ .kind = .cancel, .id = 3 },
        .{ .kind = .section, .label = "FINISHED (1)" },
        .{ .kind = .finished, .id = 2, .mark = failed_glyph, .tone = .failed, .what = "lint", .label = "shellcheck run.sh", .detail = "exit 2", .right = "0.4s" },
    };
    draw(ui, f.full(), &st, &rows, "(1 running · 1 finished)");
    // One title: the caps header's, with the header's own gap before
    // the count; the frame carries none.
    try f.expectContains("JOBS (1 running · 1 finished)");
    try f.expectLacks(" Jobs ");
    try f.expectContains("RUNNING (1)");
    try f.expectContains("⠋ git      fetch");
    try f.expectContains(cancel_glyph ++ " Cancel");
    try f.expectContains(failed_glyph ++ " lint     shellcheck run.sh · exit 2");
    try f.expectContains("2.1s");
    try f.expectContains("c cancel");
    // The Cancel row is the panel's third row, and says so to the pointer.
    var found = false;
    for (f.hits.items.items) |e| if (e.target == .row and e.target.row.panel == .jobs and e.target.row.idx == 2) {
        found = true;
    };
    try testing.expect(found);
}

test "draw: an empty registry paints the empty state, not a blank box" {
    var f = try fixture.init(100, 30);
    defer f.deinit();
    var st: Panel.State = .{};
    draw(f.ui(), f.full(), &st, &.{}, "");
    try f.expectContains("No background jobs yet");
}
