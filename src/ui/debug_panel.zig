//! The DEBUG section's rows — what `app/debug_panel.zig` lays out and
//! `ListPanel(Row)` scrolls. One flat list: a status row on top, then
//! four collapsible sections in VS Code's order — VARIABLES (scopes as
//! trees), WATCH, CALL STACK (threads, then the current thread's
//! frames), BREAKPOINTS (every file's breakpoints, then the adapter's
//! exception filters) — each behind a `NAME (n)` header row with its
//! expander (`expander.zig`'s chevron, in its grey, as every panel's),
//! a blank row between one section and the next.
//!
//! Zig-authored: the Rust debug pane was never the spec here. Every
//! row is one cell tall and paints itself from its own fields (the
//! paint callback has no `*App`), so the app builds the rows on the
//! frame arena and this file only decides how they look.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const expander = @import("expander.zig");
const types = @import("../dap/types.zig");

pub const Style = vaxis.Style;
pub const VarRow = types.VarRow;

/// The four sections, in the order they stack.
pub const Sub = enum {
    variables,
    watch,
    call_stack,
    breakpoints,

    pub const all = std.enums.values(Sub);

    pub fn label(s: Sub) []const u8 {
        return switch (s) {
            .variables => "VARIABLES",
            .watch => "WATCH",
            .call_stack => "CALL STACK",
            .breakpoints => "BREAKPOINTS",
        };
    }
};

/// `● stopped at prog.dbg:3 · thread main`, `▶ running`, `○ no session`.
/// `short` is the narrow form (`prog.dbg:3 · main`), painted when the
/// full text does not fit the row.
pub const Status = struct {
    kind: enum { none, starting, running, stopped, exited },
    text: []const u8,
    short: ?[]const u8 = null,
};

pub const Header = struct { sub: Sub, count: usize, collapsed: bool };
pub const Variable = struct { row: VarRow, changed: bool };
pub const Watch = struct { idx: usize, expression: []const u8, value: []const u8, is_err: bool, pending: bool };
pub const Thread = struct { id: i64, name: []const u8, current: bool };
pub const Frame = struct { idx: usize, label: []const u8, current: bool };
pub const BreakpointRow = struct {
    path: []const u8,
    /// `prog.dbg:4`.
    label: []const u8,
    line: u32,
    enabled: bool,
    verified: ?bool,
    condition: ?[]const u8,
    hit_condition: ?[]const u8,
    log_message: ?[]const u8,
};
pub const Filter = struct { id: []const u8, label: []const u8, on: bool };

pub const Row = union(enum) {
    status: Status,
    header: Header,
    variable: Variable,
    watch: Watch,
    thread: Thread,
    frame: Frame,
    breakpoint: BreakpointRow,
    filter: Filter,
    /// A dim one-liner under an empty section (`no watches — w adds one`).
    hint: []const u8,
    /// The blank row between two sections: the cursor skips it, a
    /// click on it does nothing.
    gap,

    /// A row the cursor can rest on.
    pub fn isStop(r: Row) bool {
        return r != .gap;
    }

    /// The text a filter matches against; headers, the status row and
    /// the gaps are never filtered out.
    pub fn filterText(r: Row) ?[]const u8 {
        return switch (r) {
            .status, .header, .hint, .gap => null,
            .variable => |v| v.row.label,
            .watch => |w| w.expression,
            .thread => |t| t.name,
            .frame => |f| f.label,
            .breakpoint => |b| b.label,
            .filter => |f| f.label,
        };
    }
};

pub const Panel = list_panel.ListPanel(Row);

pub const check_on = "[x] ";
pub const check_off = "[ ] ";
pub const watch_glyph = "\u{2316} "; // ⌖
pub const watch_ascii = "@ ";
pub const frame_glyph = "\u{25B6} "; // ▶
pub const frame_ascii = "> ";
pub const dot_on = "\u{25CF}"; // ●
pub const dot_off = "\u{25CB}"; // ○
pub const dot_on_ascii = "*";
pub const dot_off_ascii = "o";

/// One row's cells, after the marker. The ground is already filled.
pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    const end = r.right();
    var x = r.x;
    switch (row) {
        .status => |s| {
            const dot: []const u8, const color = switch (s.kind) {
                .none => .{ if (ui.ascii) dot_off_ascii else dot_off, t.muted.fg },
                .starting => .{ "\u{2026}", t.muted.fg },
                .running => .{ if (ui.ascii) frame_ascii[0..1] else frame_glyph[0..3], t.info_fg.fg },
                .stopped => .{ if (ui.ascii) dot_on_ascii else dot_on, t.error_fg.fg },
                .exited => .{ if (ui.ascii) dot_off_ascii else dot_off, t.muted.fg },
            };
            x += ui.putStr(x, r.y, end -| x, dot, Theme.withFg(base, color));
            x += ui.putStr(x, r.y, end -| x, " ", base);
            var st = Theme.withFg(base, if (s.kind == .stopped) t.fg.fg else t.muted.fg);
            st.bold = s.kind == .stopped;
            const text: []const u8 = if (s.short) |sh| (if (ui.fitsIn(s.text, end -| x)) s.text else sh) else s.text;
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(text, end -| x), st);
        },
        .header => |h| {
            // The git panel's header grey, bold; the expander in its colour.
            var st = Theme.withFg(base, t.muted.fg);
            st.bold = true;
            x += ui.putStr(x, r.y, end -| x, expander.slot(ui, !h.collapsed), expander.style(ui, base));
            x += ui.putStr(x, r.y, end -| x, h.sub.label(), st);
            const count = ui.fmt(" ({d})", .{h.count});
            if (end -| x > ui.width(count)) _ = ui.putStr(x, r.y, end -| x, count, Theme.withFg(base, t.muted.fg));
        },
        .variable => |v| {
            const vr = v.row;
            x += @as(u16, vr.depth) * 2;
            if (x >= end) return;
            if (vr.expandable) {
                x += ui.putStr(x, r.y, end -| x, expander.slot(ui, vr.expanded), expander.style(ui, base));
            } else {
                x += ui.putStr(x, r.y, end -| x, "  ", base);
            }
            var label_style = Theme.withFg(base, if (vr.is_scope) t.accent.fg else t.fg.fg);
            label_style.bold = vr.is_scope;
            x += ui.putStr(x, r.y, end -| x, ui.clipStr(vr.label, end -| x), label_style);
            if (vr.value.len > 0 and end -| x > 3) {
                x += ui.putStr(x, r.y, end -| x, " = ", Theme.withFg(base, t.muted.fg));
                var vs = Theme.withFg(base, if (v.changed) t.warn_fg.fg else t.info_fg.fg);
                vs.bold = v.changed;
                _ = ui.putStr(x, r.y, end -| x, ui.clipStr(vr.value, end -| x), vs);
            }
        },
        .watch => |w| {
            x += 2;
            x += ui.putStr(x, r.y, end -| x, if (ui.ascii) watch_ascii else watch_glyph, Theme.withFg(base, t.warn_fg.fg));
            x += ui.putStr(x, r.y, end -| x, ui.clipStr(w.expression, end -| x), Theme.withFg(base, t.fg.fg));
            if (end -| x > 3) {
                x += ui.putStr(x, r.y, end -| x, " = ", Theme.withFg(base, t.muted.fg));
                const vs = Theme.withFg(base, if (w.is_err) t.error_fg.fg else if (w.pending) t.muted.fg else t.info_fg.fg);
                _ = ui.putStr(x, r.y, end -| x, ui.clipStr(w.value, end -| x), vs);
            }
        },
        .thread => |th| {
            x += 2;
            const dot: []const u8 = if (th.current) (if (ui.ascii) dot_on_ascii else dot_on) else (if (ui.ascii) dot_off_ascii else dot_off);
            x += ui.putStr(x, r.y, end -| x, dot, Theme.withFg(base, if (th.current) t.accent.fg else t.muted.fg));
            x += ui.putStr(x, r.y, end -| x, " ", base);
            var st = Theme.withFg(base, t.fg.fg);
            st.bold = th.current;
            x += ui.putStr(x, r.y, end -| x, ui.clipStr(ui.fmt("thread {s}", .{th.name}), end -| x), st);
        },
        .frame => |f| {
            x += 2;
            x += ui.putStr(x, r.y, end -| x, if (f.current) (if (ui.ascii) frame_ascii else frame_glyph) else "  ", Theme.withFg(base, t.warn_fg.fg));
            var st = Theme.withFg(base, t.fg.fg);
            st.bold = f.current;
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(f.label, end -| x), st);
        },
        .breakpoint => |b| {
            x += 2;
            x += ui.putStr(x, r.y, end -| x, if (b.enabled) check_on else check_off, Theme.withFg(base, if (b.enabled) t.error_fg.fg else t.muted.fg));
            const dim = !b.enabled or (b.verified != null and !b.verified.?);
            x += ui.putStr(x, r.y, end -| x, ui.clipStr(b.label, end -| x), Theme.withFg(base, if (dim) t.muted.fg else t.fg.fg));
            const detail = breakpointDetail(ui, b);
            if (detail.len > 0 and end -| x > 3) {
                x += ui.putStr(x, r.y, end -| x, "  ", base);
                _ = ui.putStr(x, r.y, end -| x, ui.clipStr(detail, end -| x), Theme.withFg(base, if (dim) t.muted.fg else t.warn_fg.fg));
            }
        },
        .filter => |f| {
            x += 2;
            x += ui.putStr(x, r.y, end -| x, if (f.on) check_on else check_off, Theme.withFg(base, if (f.on) t.error_fg.fg else t.muted.fg));
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(f.label, end -| x), Theme.withFg(base, if (f.on) t.fg.fg else t.muted.fg));
        },
        .hint => |h| {
            x += 4;
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(h, end -| x), Theme.withFg(base, t.muted.fg));
        },
        .gap => {},
    }
}

/// `when i == 2 · hits >= 5 · log "x is {x}" · unverified`, whichever apply.
pub fn breakpointDetail(ui: Ui, b: BreakpointRow) []const u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    if (b.condition) |c| {
        parts[n] = ui.fmt("when {s}", .{c});
        n += 1;
    }
    if (b.hit_condition) |h| {
        parts[n] = ui.fmt("hits {s}", .{h});
        n += 1;
    }
    if (b.log_message) |l| {
        parts[n] = ui.fmt("log \"{s}\"", .{l});
        n += 1;
    }
    if (b.enabled and b.verified != null and !b.verified.?) {
        parts[n] = "unverified";
        n += 1;
    }
    if (n == 0) return "";
    const sep: []const u8 = if (ui.ascii) " - " else " \u{B7} ";
    return std.mem.join(ui.arena, sep, parts[0..n]) catch "";
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn props(rows: []const Row) Panel.Props {
    return .{
        .panel = .debug,
        .label = "DEBUG",
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .show_refresh = false,
        .new_chip = true,
        .empty = .{ .message = "No session" },
    };
}

test "every row kind paints its shape at the shipped width (26 cells) and registers a hit" {
    var f = try Fixture.init(26, 14);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    const rows = [_]Row{
        .{ .status = .{ .kind = .stopped, .text = "stopped at prog.dbg:3 · thread main", .short = "prog.dbg:3 · main" } },
        .{ .header = .{ .sub = .variables, .count = 2, .collapsed = false } },
        .{ .variable = .{ .row = .{ .depth = 0, .is_scope = true, .label = "Locals", .name = "Locals", .value = "", .var_ref = 1, .expanded = true, .expandable = true, .parent_ref = 0 }, .changed = false } },
        .{ .variable = .{ .row = .{ .depth = 1, .is_scope = false, .label = "x: int", .name = "x", .value = "7", .var_ref = 0, .expanded = false, .expandable = false, .parent_ref = 1 }, .changed = true } },
        .{ .header = .{ .sub = .watch, .count = 1, .collapsed = false } },
        .{ .watch = .{ .idx = 0, .expression = "x * 100", .value = "700", .is_err = false, .pending = false } },
        .{ .header = .{ .sub = .call_stack, .count = 1, .collapsed = false } },
        .{ .thread = .{ .id = 1, .name = "main", .current = true } },
        .{ .frame = .{ .idx = 0, .label = "prog.dbg:3  main", .current = true } },
        .{ .header = .{ .sub = .breakpoints, .count = 2, .collapsed = true } },
        .{ .breakpoint = .{ .path = "/w/prog.dbg", .label = "prog.dbg:3", .line = 2, .enabled = true, .verified = true, .condition = "i == 2", .hit_condition = null, .log_message = null } },
        .{ .filter = .{ .id = "uncaught", .label = "Uncaught errors", .on = true } },
    };
    _ = Panel.draw(&st, f.ui(), f.full(), props(&rows));
    try f.expectContains("DEBUG");
    try f.expectRow(2, "▌● prog.dbg:3 · main");
    try f.expectRow(3, " \u{F47C} VARIABLES (2)");
    try f.expectRow(4, " \u{F47C} Locals");
    try f.expectRow(5, "     x: int = 7");
    try f.expectRow(7, "   ⌖ x * 100 = 700");
    try f.expectRow(9, "   ● thread main");
    try f.expectRow(10, "   ▶ prog.dbg:3  main");
    try f.expectRow(11, " \u{F460} BREAKPOINTS (2)");
    try f.expectRow(12, "   [x] prog.dbg:3  when i…");
    try f.expectRow(13, "   [x] Uncaught errors");
    // The changed value is the warning colour; the frame's ▶ too. The
    // headers are the git panel's grey; their expanders the menu bar's
    // dimmer `palette.grey` (expander.style).
    try testing.expect(f.fgEql(14, 5, f.theme.warn_fg));
    try testing.expect(f.fgEql(1, 3, .{ .fg = f.theme.palette.grey }));
    try testing.expect(f.fgEql(3, 3, f.theme.muted));
    try testing.expect(f.style(3, 3).bold);
    try testing.expect(f.fgEql(1, 11, .{ .fg = f.theme.palette.grey }));
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 5).?.row.idx);
    try testing.expectEqual(list_panel.PanelId.debug, f.hits.at(5, 5).?.row.panel);
}

test "breakpointDetail joins the parts; a disabled or unverified breakpoint paints muted" {
    var f = try Fixture.init(60, 3);
    defer f.deinit();
    const ui = f.ui();
    try testing.expectEqualStrings("", breakpointDetail(ui, .{ .path = "", .label = "", .line = 0, .enabled = true, .verified = null, .condition = null, .hit_condition = null, .log_message = null }));
    try testing.expectEqualStrings("when a · hits >= 5 · log \"hi\" · unverified", breakpointDetail(ui, .{ .path = "", .label = "", .line = 0, .enabled = true, .verified = false, .condition = "a", .hit_condition = ">= 5", .log_message = "hi" }));
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    const rows = [_]Row{
        .{ .breakpoint = .{ .path = "/w/a.py", .label = "a.py:9", .line = 8, .enabled = false, .verified = null, .condition = null, .hit_condition = null, .log_message = null } },
    };
    _ = Panel.draw(&st, ui, f.full(), props(&rows));
    try f.expectRow(2, "▌  [ ] a.py:9");
    try testing.expect(f.fgEql(8, 2, f.theme.muted));
}
