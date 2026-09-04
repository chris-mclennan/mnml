//! canvas-demo: the terminal layer end to end — `Term` (raw mode, probe,
//! modes), the input worker, and the `Canvas` primitives painting into
//! vaxis's screen. Full-screen; `q` or `ctrl+c` quits.
//!
//! What to look at, per terminal:
//!   - the left box word-wraps a paragraph that mixes ASCII, CJK and
//!     emoji — every CJK glyph must take exactly two cells and never
//!     smear into the border;
//!   - the right box grapheme-wraps tokens with no break opportunity;
//!   - the status rows show what the probe found and the last key with
//!     its modifiers, so `ctrl+shift+p` vs `ctrl+p` (kitty keyboard) and
//!     the legacy fallback are both visible;
//!   - resizing re-lays out; the count in the status row ticks up.

const std = @import("std");
const vaxis = @import("vaxis");
const Term = @import("tui/term.zig");
const Input = @import("tui/input.zig");
const Canvas = @import("ui/canvas.zig");
const Rect = @import("ui/rect.zig");
const text = @import("ui/text.zig");

const Io = std.Io;
const Key = vaxis.Key;
const Segment = vaxis.Segment;
const Style = vaxis.Style;

/// A crash inside the alt screen would print its trace where nobody can
/// read it. Term's hook resets the terminal first.
pub const panic = Term.Panic;

const State = struct {
    last_key: ?Key = null,
    keys: u32 = 0,
    last_mouse: ?vaxis.Mouse = null,
    resizes: u32 = 0,
    paste_bytes: usize = 0,
    focused: bool = true,
};

// ── palette (rgb on purpose: Terminal.app must fold these to the cube) ──

const bg: Style = .{ .bg = .{ .rgb = .{ 0x1e, 0x1e, 0x2e } }, .fg = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } } };
const frame_a: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0x89, 0xb4, 0xfa } } };
const frame_b: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } } };
const title_style: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } }, .bold = true };
const accent: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } } };
const dim: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0x6c, 0x70, 0x86 } } };
const status_style: Style = .{ .bg = .{ .rgb = .{ 0x31, 0x32, 0x44 } }, .fg = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } } };
const status_key: Style = .{ .bg = status_style.bg, .fg = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } }, .bold = true };

const paragraph = [_]Segment{
    .{ .text = "mnml-zig", .style = .{ .bg = bg.bg, .fg = bg.fg, .bold = true } },
    .{ .text = " paints through a clipped Canvas into vaxis's cell store. Word wrap keeps whole words together: ", .style = bg },
    .{ .text = "日本語のテキストは各文字が二セル幅", .style = accent },
    .{ .text = " and 中文也一样, mixed with emoji ", .style = bg },
    .{ .text = "🦊 🐍 🚀", .style = bg },
    .{ .text = ", a ZWJ family 👨‍👩‍👧, flags 🇯🇵 🇳🇿, and a combining mark: e\u{0301}. ", .style = bg },
    .{ .text = "Every wide glyph owns a real space tail, so nothing smears into the border on the right.", .style = bg },
    .{ .text = "\n\nA second paragraph after two newlines — the layout honours them.", .style = dim },
};

const long_tokens = [_]Segment{
    .{ .text = "Grapheme wrap breaks anywhere a word would not: ", .style = bg },
    .{ .text = "Supercalifragilisticexpialidocious_Donaudampfschifffahrtsgesellschaftskapitän_", .style = accent },
    .{ .text = "https://example.com/a/very/long/path/with/no/spaces?that=forces&a=grapheme&wrap=true ", .style = bg },
    .{ .text = "漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字", .style = frame_b },
    .{ .text = " 🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀", .style = bg },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const term = try gpa.create(Term);
    defer gpa.destroy(term);
    term.init(io, gpa, init.environ_map, .{}) catch |err| switch (err) {
        error.NotATty => {
            std.debug.print("canvas-demo needs a terminal on stdout\n", .{});
            return err;
        },
        else => return err,
    };
    defer term.deinit();
    try term.setTitle("mnml-zig canvas demo");

    // Cells hold grapheme slices, not copies: every string painted this
    // frame must outlive `render`. The frame arena is that lifetime.
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();

    var state: State = .{};
    try draw(term, &state, frame.allocator());
    try term.render();

    var pending: [64]Term.Event = undefined;
    while (true) {
        const first = term.next() catch break;
        var quit = handle(term, &state, first) catch break;
        // A burst (paste, mouse motion, key repeat) is one frame.
        const n = term.drain(&pending) catch break;
        for (pending[0..n]) |ev| {
            if (handle(term, &state, ev) catch true) quit = true;
        }
        if (quit) break;
        _ = frame.reset(.retain_capacity);
        try draw(term, &state, frame.allocator());
        try term.render();
    }
}

fn handle(term: *Term, state: *State, ev: Term.Event) !bool {
    switch (ev) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return true;
            state.last_key = key;
            state.keys += 1;
        },
        .winsize => |ws| {
            try term.resize(ws);
            state.resizes += 1;
        },
        .mouse => |m| state.last_mouse = m,
        .paste => |bytes| {
            state.paste_bytes = bytes.len;
            term.freeEvent(ev);
        },
        .focus_in => state.focused = true,
        .focus_out => state.focused = false,
        else => {},
    }
    return false;
}

fn draw(term: *Term, state: *const State, arena: std.mem.Allocator) !void {
    const c = Canvas.init(term.screen(), .{ .quantize = term.quantize() });
    const full = c.full();
    c.fill(full, bg);

    // Header, two status rows at the bottom, boxes in between.
    const header = full.splitTop(1);
    const bottom = header.rest.splitBottom(2);
    const body = bottom.top;

    _ = c.text(header.top, &.{
        .{ .text = " mnml-zig canvas demo ", .style = title_style },
        .{ .text = "· q quits · resize me · type chords · move the mouse", .style = dim },
    }, .{});

    // Side by side when there is room, stacked when there is not.
    var left: Rect = undefined;
    var right: Rect = undefined;
    if (body.w >= 80) {
        const v = body.splitLeft(body.w * 3 / 5);
        left = v.left;
        right = v.rest;
    } else {
        const h = body.splitTop(body.h / 2);
        left = h.top;
        right = h.rest;
    }

    try drawBox(c, left, frame_a, " Word wrap · ASCII / CJK / emoji ", &paragraph, .word, arena);
    try drawBox(c, right, frame_b, " Grapheme wrap · long tokens ", &long_tokens, .grapheme, arena);

    try drawStatus(c, bottom.rest, term, state, arena);
}

fn drawBox(c: Canvas, r: Rect, frame: Style, title: []const u8, segs: []const Segment, wrap: text.Wrap, arena: std.mem.Allocator) !void {
    const t = [_]Segment{.{ .text = title, .style = title_style }};
    const inner = c.border(r, .rounded, frame, &t);
    if (inner.isEmpty()) return;
    const pad = inner.inset(1);
    if (pad.isEmpty()) return;
    const text_area = pad.splitBottom(1);
    const rows = c.text(text_area.top, segs, .{ .wrap = wrap, .trim = true });
    const need = c.measure(segs, text_area.top.w, .{ .wrap = wrap, .trim = true });

    const footer = try std.fmt.allocPrint(arena, "rows {d}/{d} at {d} cols", .{ rows, need, text_area.top.w });
    _ = c.text(text_area.rest, &.{.{ .text = footer, .style = dim }}, .{ .alignment = .right });
}

fn drawStatus(c: Canvas, r: Rect, term: *Term, state: *const State, arena: std.mem.Allocator) !void {
    c.fill(r, status_style);
    const rows = r.splitTop(1);

    var cw: Io.Writer.Allocating = .init(arena);
    try cw.writer.writeAll(" ");
    try term.caps.write(&cw.writer);
    try cw.writer.print("  {d}x{d} resizes={d}{s}", .{
        term.screen().width,
        term.screen().height,
        state.resizes,
        if (state.focused) "" else "  (unfocused)",
    });
    _ = c.text(rows.top, &.{.{ .text = cw.written(), .style = status_style }}, .{});

    var kw_alloc: Io.Writer.Allocating = .init(arena);
    const kw = &kw_alloc.writer;
    if (state.last_key) |key| {
        try kw.print(" key #{d}: ", .{state.keys});
        const name_start = kw_alloc.written().len;
        try Input.writeKeyName(kw, key);
        const name_end = kw_alloc.written().len;
        try kw.print("  cp=U+{X:0>4}", .{key.codepoint});
        if (key.shifted_codepoint) |s| try kw.print(" shifted=U+{X:0>4}", .{s});
        if (key.base_layout_codepoint) |b| try kw.print(" base=U+{X:0>4}", .{b});
        if (key.text) |t| try kw.print(" text=\"{s}\"", .{t});
        if (state.paste_bytes > 0) try kw.print("  paste={d}B", .{state.paste_bytes});
        if (state.last_mouse) |m| try kw.print("  mouse=({d},{d}) {t} {t}", .{ m.col, m.row, m.button, m.type });
        const line = kw_alloc.written();
        _ = c.text(rows.rest, &.{
            .{ .text = line[0..name_start], .style = status_style },
            .{ .text = line[name_start..name_end], .style = status_key },
            .{ .text = line[name_end..], .style = status_style },
        }, .{});
    } else {
        try kw.writeAll(" key: (none yet) — try ctrl+p, then ctrl+shift+p, alt+enter, shift+tab");
        if (state.last_mouse) |m| try kw.print("  mouse=({d},{d}) {t} {t}", .{ m.col, m.row, m.button, m.type });
        _ = c.text(rows.rest, &.{.{ .text = kw_alloc.written(), .style = status_style }}, .{});
    }
}
