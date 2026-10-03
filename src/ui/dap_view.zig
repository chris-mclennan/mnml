//! The debug pane: the step toolbar on its first row, then the Debug
//! Console — VS Code's shape: one scrollback holding the program's
//! output, the `> expr` echoes of what was evaluated, their results
//! (a composite expands under its line), errors, and session notes
//! (`── started prog.dbg ──`), with the input row at the bottom.
//!
//! The app hands in the entries already flattened to lines on the
//! frame arena; the view keeps nothing. An evaluation's lines register
//! `.script_hit{ pane, entry }` so a click folds / unfolds it; the input
//! row registers `input_hit`; the toolbar registers its own ids
//! (`debug_toolbar.zig`).
//!
//! Zig-authored: this is the spec (`docs/ui-spec/zig-debug-console-*`).

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const expander = @import("expander.zig");
const toolbar = @import("debug_toolbar.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;
pub const Style = vaxis.Style;
pub const Caret = text_field.Caret;

pub const prompt = "> ";
/// The `.script_hit` id of the input row.
pub const input_hit: u32 = std.math.maxInt(u32);
/// Entry ids sit below this; the toolbar's above it.
pub const max_entry: u32 = toolbar.hit_base - 1;

/// One painted line of the scrollback.
pub const Line = struct {
    pub const Kind = enum { stdout, stderr, console, note, echo, result, err, pending, child };
    kind: Kind,
    text: []const u8,
    /// The evaluation this line belongs to (a click toggles it).
    entry: ?u32 = null,
    /// A result that folds (a struct, an array): the expander sits
    /// before the text, open or closed, in the expander's colour.
    fold: ?bool = null,
};

pub const Props = struct {
    lines: []const Line,
    /// Lines hidden past the bottom (0 follows the tail).
    scroll: usize,
    input: []const u8,
    caret: usize,
    anchor: ?usize = null,
    state: toolbar.SessionState,
    focused: bool,
    show_toolbar: bool = true,
};

fn lineStyle(t: *const Theme, kind: Line.Kind, bg: vaxis.Color) Style {
    return switch (kind) {
        .stdout => Theme.onBg(t.fg, bg),
        .stderr => Theme.onBg(t.error_fg, bg),
        .console => Theme.onBg(t.muted, bg),
        .note => blk: {
            var s = Theme.onBg(t.muted, bg);
            s.italic = true;
            break :blk s;
        },
        .echo => Theme.onBg(t.accent, bg),
        .result => Theme.onBg(t.info_fg, bg),
        .err => Theme.onBg(t.error_fg, bg),
        .pending, .child => Theme.onBg(t.muted, bg),
    };
}

/// Returns the input caret when focused.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: Props) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return null;
    const bg = t.panel_bg.bg;
    var rest = area;
    if (p.show_toolbar) {
        const s = rest.splitTop(1);
        _ = toolbar.draw(ui, s.top, .{ .pane = pane, .state = p.state });
        rest = s.rest;
    }
    if (rest.h < 1) return null;
    // Input row.
    const input_row = rest.row(rest.h - 1);
    const pw = ui.putStr(input_row.x + 1, input_row.y, input_row.w -| 1, prompt, Theme.onBg(t.accent, bg));
    const field = Rect.init(input_row.x + 1 + pw, input_row.y, input_row.w -| (1 + pw), 1);
    ui.hit(input_row, .{ .script_hit = .{ .pane = pane, .id = input_hit } });
    const caret = text_field.draw(ui, field, p.input, p.caret, .{
        .style = Theme.onBg(t.fg, bg),
        .placeholder = if (p.state == .stopped) "expression \u{2014} Tab completes, \u{2191}\u{2193} history" else "expression (evaluates once stopped)",
        .focused = p.focused,
        .anchor = p.anchor,
        .field = .{ .pane_field = .{ .pane = pane, .sub = .dap_input } },
    });
    if (rest.h < 2) return caret;
    // The scrollback: the last `body.h` lines before the scroll offset.
    const body = Rect.init(rest.x, rest.y, rest.w, rest.h - 1);
    if (p.lines.len == 0) {
        _ = ui.putStr(body.x + 1, body.y, body.w -| 1, ui.clipStr("Debug console \u{2014} program output and evaluations land here", body.w -| 1), Theme.onBg(t.muted, bg));
        return caret;
    }
    const end = p.lines.len -| p.scroll;
    const first = end -| body.h;
    var y: u16 = body.y;
    for (p.lines[first..end]) |l| {
        const r = Rect.init(body.x, y, body.w, 1);
        const style = lineStyle(t, l.kind, bg);
        if (l.kind == .echo) {
            var cx = r.x + 1;
            cx += ui.putStr(cx, y, r.w -| 1, prompt, style);
            _ = ui.putStr(cx, y, r.right() -| cx, ui.clipStr(l.text, r.right() -| cx), Theme.onBg(t.fg, bg));
        } else if (l.fold) |open| {
            var cx = r.x + 1;
            cx += ui.putStr(cx, y, r.right() -| cx, "  ", style);
            cx += ui.putStr(cx, y, r.right() -| cx, expander.slot(ui, open), expander.style(ui, .{ .bg = bg }));
            _ = ui.putStr(cx, y, r.right() -| cx, ui.clipStr(l.text, r.right() -| cx), style);
        } else {
            _ = ui.putStr(r.x + 1, y, r.w -| 1, ui.clipStr(l.text, r.w -| 1), style);
        }
        if (l.entry) |e| ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = e } });
        y += 1;
    }
    return caret;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "toolbar, the scrollback's tail, the echo rows as hits, the input row with its caret" {
    var f = try Fixture.init(90, 8);
    defer f.deinit();
    const lines = [_]Line{
        .{ .kind = .note, .text = "\u{2500}\u{2500} started prog.dbg \u{2500}\u{2500}" },
        .{ .kind = .stdout, .text = "hello" },
        .{ .kind = .stderr, .text = "throw: boom" },
        .{ .kind = .echo, .text = "x * 2", .entry = 0 },
        .{ .kind = .result, .text = "  10 : int", .entry = 0 },
        .{ .kind = .echo, .text = "p", .entry = 1 },
        .{ .kind = .result, .text = "{a=1, b=2} : struct", .entry = 1, .fold = true },
        .{ .kind = .child, .text = "      a : int = 1", .entry = 1 },
    };
    const caret = draw(f.ui(), 4, f.full(), .{ .lines = &lines, .scroll = 0, .input = "y", .caret = 1, .state = .stopped, .focused = true });
    try f.expectContains(" Continue ");
    try f.expectContains(" throw: boom");
    try f.expectContains(" > x * 2");
    try f.expectContains("   10 : int");
    // A foldable result: the expander before its text, in the
    // expander's grey; the text keeps the result colour.
    try f.expectContains("   \u{F47C} {a=1, b=2} : struct");
    try testing.expect(f.fgEql(3, 5, .{ .fg = f.theme.palette.grey }));
    try testing.expect(f.fgEql(5, 5, f.theme.info_fg));
    try f.expectContains("       a : int = 1");
    try f.expectRow(7, " > y");
    try testing.expectEqual(@as(u16, 4), caret.?.x);
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 5).?.script_hit.id);
    try testing.expectEqual(input_hit, f.hits.at(3, 7).?.script_hit.id);
    try testing.expectEqual(toolbar.hitId(.@"continue"), f.hits.at(3, 0).?.script_hit.id);
    // The first line scrolled off: six body rows hold the last six.
    try f.expectLacks("started prog.dbg");
    // Scrolled back by two, the tail's last two lines go.
    var g = try Fixture.init(90, 8);
    defer g.deinit();
    _ = draw(g.ui(), 4, g.full(), .{ .lines = &lines, .scroll = 2, .input = "", .caret = 0, .state = .stopped, .focused = false });
    try g.expectContains("started prog.dbg");
    try g.expectLacks("a : int = 1");
}

test "an empty console says so; the strip can be left out" {
    var f = try Fixture.init(60, 3);
    defer f.deinit();
    _ = draw(f.ui(), 0, f.full(), .{ .lines = &.{}, .scroll = 0, .input = "", .caret = 0, .state = .none, .focused = true, .show_toolbar = false });
    try f.expectContains("Debug console");
    try testing.expect(f.hits.at(3, 0) == null);
}
