//! The sessions table (`Pane.sessions_table`): a `ListPanel` hosted by
//! the pane — the caps header with the `ended:` / `where:` / pause /
//! `? help` chips beside the sort and refresh chips, the filter pill,
//! the `+ New session` row, then the rows grouped under a workspace
//! header each — and the summary block under the list: the counts, and
//! the selected session's line with its last exchange (the ONLY place
//! the messages show; a row is the name and the numbers). `?` swaps
//! the body for the help rows. Every target is the pane's
//! `.script_hit` (`hit.ListHit` ids, `sessions_table.hit_*`).
//!
//! A group row carries the column captions, right-aligned over the
//! numbers, so the table needs no caption row of its own.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const list_panel = @import("list_panel.zig");
const expander = @import("expander.zig");
const header = @import("header.zig");
const ids = @import("../core/ids.zig");
const table = @import("../app/sessions_table.zig");
const transcript = @import("../ai/transcript.zig");
const accent_color = @import("accent_color.zig");
const bufferline = @import("bufferline.zig");
const link_span = @import("link_span.zig");

pub const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;
pub const Row = table.Row;
pub const Source = @import("../app/agents.zig").Source;
pub const Panel = table.Panel;

pub const Props = struct {
    /// The rows in display order (groups and sessions).
    rows: []const Row,
    focused: bool,
    now_s: i64,
    now_ms: i64,
    agg: table.Aggregate,
    /// The session under the cursor, for the summary block.
    selected: ?table.ItemView,
    /// Every row the section holds.
    total: usize,
    scanning: bool,
    /// The `where:` chip paints only when a cloud is configured or listed.
    cloud_configured: bool,
    home_missing: bool,
    /// The Claude mark as `ui.claude_mark` has it — the caller resolves
    /// it (`app/claude_mark.zig`), because the config does not reach
    /// this layer. A Claude card wears the same mark the tab bar's
    /// cluster and a Claude pty tab do.
    claude_mark: bufferline.Mark = bufferline.claudeMark(.figure),
};

/// A session's mark: the product's own, the same one its pty tab, the
/// launcher dock and the tab bar's cluster wear — Claude's is whichever
/// `ui.claude_mark` names, Codex has the one. The rows used to carry a
/// neutral `✦` / `◈` pair of their own, which meant a Claude session
/// read as one mark here and another two cells away on its own tab.
/// `paintRow` sees no props, so `draw` parks the resolved mark here
/// beside the clock it already parks.
var ui_claude_mark: bufferline.Mark = bufferline.claudeMark(.figure);

fn sourceGlyph(ascii: bool, source: Source) []const u8 {
    return switch (source) {
        .claude => if (ascii) ui_claude_mark.fallback else ui_claude_mark.glyph,
        .codex => if (ascii) bufferline.codex_ascii else bufferline.codex_glyph,
    };
}

pub const help_title = "Sessions table — help (? to close)";
pub const Help = union(enum) { section: []const u8, row: struct { key: []const u8, what: []const u8 } };
pub const help_lines = [_]Help{
    .{ .section = "Navigation" },
    .{ .row = .{ .key = "j / k or ↑/↓", .what = "select row · a click selects too" } },
    .{ .row = .{ .key = "g / G · Home / End", .what = "first / last row" } },
    .{ .row = .{ .key = "PgUp / PgDn", .what = "page" } },
    .{ .row = .{ .key = "z · ⏎ on a group", .what = "collapse / expand the workspace group" } },
    .{ .section = "Filters" },
    .{ .row = .{ .key = "/", .what = "filter by text (name · id · model · cwd · state)" } },
    .{ .row = .{ .key = "f", .what = "state filter: waiting → live → tool → idle → failed → done → every" } },
    .{ .row = .{ .key = "w", .what = "cycle where (all → local → cloud)" } },
    .{ .row = .{ .key = "E", .what = "show / hide ended sessions older than a day" } },
    .{ .row = .{ .key = "Ctrl+L", .what = "clear every filter" } },
    .{ .section = "Layout" },
    .{ .row = .{ .key = "s", .what = "cycle the sort within a group (state → tokens → cost → recent)" } },
    .{ .row = .{ .key = "r · p", .what = "refresh now · pause / resume the 3 s auto-refresh" } },
    .{ .section = "Selection" },
    .{ .row = .{ .key = "space · U", .what = "tick the row for a batch action · clear the ticks" } },
    .{ .section = "Actions" },
    .{ .row = .{ .key = "⏎ / o / dbl-click", .what = "resume the session in a terminal (a cloud run: open it)" } },
    .{ .row = .{ .key = "t", .what = "open the transcript (a cloud run: tail its log)" } },
    .{ .row = .{ .key = "K / S", .what = "kill (SIGTERM) the session — or every ticked one — after a confirm" } },
    .{ .row = .{ .key = "y / c", .what = "copy the session id / the working directory" } },
    .{ .row = .{ .key = "e", .what = "export the transcript as markdown" } },
    .{ .row = .{ .key = "R · P · x", .what = "rename · pin · delete the transcript (confirm)" } },
    .{ .row = .{ .key = "right-click", .what = "the session's menu (a cloud run: open / tail / cancel)" } },
    .{ .section = "Meta" },
    .{ .row = .{ .key = "? / F1", .what = "toggle this help" } },
    .{ .row = .{ .key = "Esc / q", .what = "close the table" } },
};

/// Rows the summary block takes under the list.
fn summaryRows(area_h: u16) u16 {
    if (area_h >= 18) return 5;
    if (area_h >= 12) return 3;
    return 0;
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, tp: *table.TablePane, props: Props) ?Caret {
    const th = ui.theme;
    ui.fill(area, th.panel_bg);
    if (area.isEmpty()) return null;
    if (tp.help) {
        drawHelp(ui, area);
        return null;
    }
    setClock(props.now_ms);
    ui_now_s = props.now_s;
    ui_claude_mark = props.claude_mark;
    const sh = summaryRows(area.h);
    var list_area = area;
    var summary_area = Rect.empty;
    if (sh > 0) {
        const s = area.splitBottom(sh);
        list_area = s.top;
        summary_area = s.rest;
    }
    // The header chips: left of the sort chip, right to left.
    var extra_buf: [4]header.ExtraChip = undefined;
    var n: usize = 0;
    extra_buf[n] = .{ .text = " ? help ", .id = table.hit_help };
    n += 1;
    extra_buf[n] = .{ .text = if (tp.paused) (if (ui.ascii) " > resume " else " ▶ resume ") else (if (ui.ascii) " || pause " else " ⏸ pause "), .id = table.hit_pause };
    n += 1;
    if (props.cloud_configured) {
        extra_buf[n] = .{ .text = ui.fmt(" where: {s} ", .{if (tp.where_filter) |w| w.label() else "all"}), .id = table.hit_where };
        n += 1;
    }
    extra_buf[n] = .{ .text = if (tp.show_ended) " ended: shown " else " ended: hidden ", .id = table.hit_ended };
    n += 1;
    const shown = countItems(props.rows);
    const subtitle = if (tp.multi.count() > 0)
        ui.fmt(" ({d} of {d} · ☑ {d})", .{ shown, props.total, tp.multi.count() })
    else if (shown != props.total or tp.anyFilter())
        ui.fmt(" ({d} of {d})", .{ shown, props.total })
    else
        ui.fmt(" ({d})", .{props.total});
    const empty: list_panel.EmptyState = if (props.scanning and props.total == 0)
        .{ .message = "Scanning sessions…" }
    else if (props.home_missing)
        .{ .message = "No home directory — nowhere to look for sessions." }
    else if (props.total == 0)
        .{ .message = "No sessions in the last 7 days — + New session starts one." }
    else if (props.agg.hidden > 0 and !tp.show_ended and !tp.anyFilter())
        .{ .message = "Every session ended over a day ago — E shows them." }
    else
        .{ .message = "No sessions match — Ctrl+L clears the filters" };
    const caret = Panel.draw(&tp.list, ui, list_area, .{
        .panel = .sessions,
        .label = "SESSIONS",
        .subtitle = subtitle,
        .sort_chip = tp.sort.label(),
        .sort_widest = table.Sort.widest,
        .rows = props.rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
        .new_label = "+ New session",
        .pane = pane,
        .extra_chips = extra_buf[0..n],
        .focused = props.focused,
    });
    if (props.scanning) list_panel.paintSpinner(ui, list_area, "SESSIONS", props.now_ms);
    if (!summary_area.isEmpty()) drawSummary(ui, pane, summary_area, props);
    return caret;
}

fn countItems(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |r| if (r == .item) {
        n += 1;
    };
    return n;
}

/// The columns after the name, right to left: the dirty count, the
/// age, the cost, the tokens, the id with the `#` before it — each
/// dropped when the name would fall under `name_min`. The `#` is the
/// session's number in SESSIONS (`sessions.focus_N`), blank for one
/// the panel does not number; it goes with the id, last.
const name_min: u16 = 12;
const col_num: u16 = 3;
const col_id: u16 = 9;
const col_tokens: u16 = 8;
const col_cost: u16 = 9;
const col_age: u16 = 6;
const col_dirty: u16 = 6;

const Columns = struct { num: bool, id: bool, tokens: bool, cost: bool, age: bool, dirty: bool, right_w: u16 };

fn columns(w: u16) Columns {
    var c: Columns = .{ .num = true, .id = true, .tokens = true, .cost = true, .age = true, .dirty = true, .right_w = col_num + col_id + col_tokens + col_cost + col_age + col_dirty };
    const left: u16 = 11;
    if (w >= left + name_min + c.right_w) return c;
    c.dirty = false;
    c.right_w -= col_dirty;
    if (w >= left + name_min + c.right_w) return c;
    c.cost = false;
    c.right_w -= col_cost;
    if (w >= left + name_min + c.right_w) return c;
    c.tokens = false;
    c.right_w -= col_tokens;
    if (w >= left + name_min + c.right_w) return c;
    c.age = false;
    c.right_w -= col_age;
    if (w >= left + name_min + c.right_w) return c;
    c.num = false;
    c.id = false;
    c.right_w = 0;
    return c;
}

fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const th = ui.theme;
    const style = list_panel.rowStyle(th, selected);
    if (r.w < 4 or r.h == 0) return;
    const cols = columns(r.w);
    switch (row) {
        .group => |g| {
            var x = r.x + 1;
            var gstyle = Theme.withFg(style, th.accent.fg);
            gstyle.bold = true;
            x += ui.putStr(x, r.y, r.right() -| x, expander.slot(ui, !g.collapsed), expander.style(ui, style));
            const where_mark: []const u8 = if (g.where == .cloud) (if (ui.ascii) "cloud: " else "☁ ") else "";
            x += ui.putStr(x, r.y, r.right() -| x, where_mark, gstyle);
            const cap_x = r.right() -| cols.right_w;
            x += ui.putStr(x, r.y, cap_x -| x, ui.clipStr(g.label, cap_x -| x), gstyle);
            const tail = if (g.hidden > 0) ui.fmt(" ({d} · {d} hidden)", .{ g.count, g.hidden }) else ui.fmt(" ({d})", .{g.count});
            _ = ui.putStr(x, r.y, cap_x -| x, ui.clipStr(tail, cap_x -| x), Theme.withFg(style, th.muted.fg));
            // The captions over the numbers.
            var cx = cap_x;
            const cap_style = Theme.withFg(style, th.muted.fg);
            if (cols.num) cx += ui.putStr(cx, r.y, col_num, ui.fmt("{s:>3}", .{"#"}), cap_style);
            if (cols.id) cx += ui.putStr(cx, r.y, col_id, ui.fmt("{s:>9}", .{"id"}), cap_style);
            if (cols.tokens) cx += ui.putStr(cx, r.y, col_tokens, ui.fmt("{s:>8}", .{"tokens"}), cap_style);
            if (cols.cost) cx += ui.putStr(cx, r.y, col_cost, ui.fmt("{s:>9}", .{"cost"}), cap_style);
            if (cols.age) cx += ui.putStr(cx, r.y, col_age, ui.fmt("{s:>6}", .{"age"}), cap_style);
            if (cols.dirty) _ = ui.putStr(cx, r.y, col_dirty, ui.fmt("{s:>6}", .{"dirty"}), cap_style);
        },
        .item => |v| {
            const it = v.it;
            var x = r.x;
            // colors: the session's accent in the row's first cell, as
            // the card's `▌`; a tick takes both cells over it.
            if (v.ticked) {
                x += ui.putStr(x, r.y, r.right() -| x, if (ui.ascii) "[x]" else "☑ ", Theme.withFg(style, th.accent.fg));
            } else {
                const chosen: ?vaxis.Color = if (v.color) |c| accent_color.resolve(c, th) else null;
                if (chosen) |c| {
                    x += ui.putStr(x, r.y, r.right() -| x, if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph, Theme.withFg(style, c));
                    x += ui.putStr(x, r.y, r.right() -| x, " ", style);
                } else {
                    x += ui.putStr(x, r.y, r.right() -| x, "  ", style);
                }
            }
            x += ui.putStr(x, r.y, r.right() -| x, sourceGlyph(ui.ascii, it.source), Theme.withFg(style, th.accent.fg));
            x += ui.putStr(x, r.y, r.right() -| x, " ", style);
            const badge_style = switch (it.state) {
                .waiting => Theme.withFg(style, th.attention_fg.fg),
                .streaming => Theme.withFg(style, th.info_fg.fg),
                .tool_call => Theme.withFg(style, th.palette.yellow),
                .idle => Theme.withFg(style, th.muted.fg),
                .failed => Theme.withFg(style, th.palette.red),
                .done => Theme.withFg(style, th.muted.fg),
            };
            x = padTo(ui, x, r.y, x + ui.putStr(x, r.y, @min(7, r.right() -| x), it.state.badge(ui.ascii), badge_style), x + 7, style);
            const num_x = r.right() -| cols.right_w;
            if (v.pinned) x += ui.putStr(x, r.y, num_x -| x, if (ui.ascii) "* " else "\u{F0403} ", Theme.withFg(style, th.palette.orange));
            var name_style = Theme.withFg(style, th.fg.fg);
            name_style.bold = v.active;
            const name_w = num_x -| x -| 1;
            x += ui.putStr(x, r.y, name_w, ui.clipStr(v.name, name_w), name_style);
            // sessions-worktree: the tree's name, muted, in what is left.
            if (v.worktree) |wt| {
                const tag = sessions.worktreeTag(ui.arena, wt, ui.ascii) catch "";
                const left = num_x -| x -| 1;
                if (left > 2) {
                    x += ui.putStr(x, r.y, left, " ", style);
                    _ = ui.putStr(x, r.y, left -| 1, ui.clipStr(tag, left -| 1), Theme.withFg(style, th.muted.fg));
                }
            }
            var cx = num_x;
            const num_style = Theme.withFg(style, th.muted.fg);
            if (cols.num) cx += ui.putStr(cx, r.y, col_num, if (v.number) |n| ui.fmt("{d:>3}", .{n}) else "   ", num_style);
            if (cols.id) cx += ui.putStr(cx, r.y, col_id, ui.fmt("{s:>9}", .{it.session_id[0..@min(8, it.session_id.len)]}), num_style);
            if (cols.tokens) {
                var tb: [16]u8 = undefined;
                // `+`: the transcript is longer than the totals read.
                const plus = if (it.totals_capped) "+" else "";
                cx += ui.putStr(cx, r.y, col_tokens, ui.fmt("{s:>8}", .{ui.fmt("{s}{s}", .{ transcript.fmtTokens(&tb, it.tokens), plus })}), num_style);
            }
            if (cols.cost) {
                // A model with no price: `n/a`, never a $0.00 that reads as free.
                const cost = if (!it.cost_known) "n/a" else ui.fmt("${d:.2}{s}", .{ it.cost_usd, if (it.totals_capped) "+" else "" });
                cx += ui.putStr(cx, r.y, col_cost, ui.fmt("{s:>9}", .{cost}), num_style);
            }
            if (cols.age) cx += ui.putStr(cx, r.y, col_age, ui.fmt("{s:>6}", .{list_panel.ageText(ui, ui_now_s, it.last_activity_s)}), num_style);
            if (cols.dirty) {
                const d = if (it.dirty) |n| (if (n > 0) ui.fmt("{s}{d}", .{ if (ui.ascii) "*" else "●", n }) else "") else "";
                rightAligned(ui, cx, r.y, col_dirty, d, Theme.withFg(style, if (it.dirtyEnded()) th.palette.orange else th.muted.fg));
            }
        },
    }
}

/// Spaces from `from` up to `to` (cells, not bytes — a glyph's width).
fn padTo(ui: Ui, x_unused: u16, y: u16, from: u16, to: u16, style: vaxis.Style) u16 {
    _ = x_unused;
    var x = from;
    while (x < to) : (x += 1) _ = ui.putStr(x, y, 1, " ", style);
    return to;
}

/// `text` against the right edge of `w` cells at `x`, by width.
fn rightAligned(ui: Ui, x: u16, y: u16, w: u16, text: []const u8, style: vaxis.Style) void {
    const tw = ui.width(text);
    const pad = w -| tw;
    _ = padTo(ui, x, y, x, x + pad, style);
    _ = ui.putStr(x + pad, y, w -| pad, text, style);
}

/// `paintRow` has no props: the frame's clock is parked here by `draw`.
/// One painter runs at a time, on the UI thread.
var ui_now_ms: i64 = 0;
/// The wall clock the ages are on (`sessions.wallNowS`).
var ui_now_s: i64 = 0;

fn drawSummary(ui: Ui, pane: PaneId, area: Rect, props: Props) void {
    const th = ui.theme;
    const bg = th.panel_bg;
    ui.fill(area, bg);
    const head = area.row(0);
    ui.hrule(head.x, head.y, head.w, Theme.withFg(bg, th.border.fg));
    _ = ui.putStr(head.x + 2, head.y, head.w -| 2, " summary ", Theme.withFg(bg, th.accent.fg));
    ui.hit(area, .{ .script_hit = .{ .pane = pane, .id = table.hit_summary } });
    if (area.h < 2) return;
    const a = props.agg;
    var tb: [16]u8 = undefined;
    const g = struct {
        fn pick(ascii: bool, glyph: []const u8, twin: []const u8) []const u8 {
            return if (ascii) twin else glyph;
        }
    };
    const dirty_part = if (a.dirty_ended > 0) ui.fmt(" · {s} {d} dirty, ended", .{ g.pick(ui.ascii, "●", "*"), a.dirty_ended }) else "";
    const hidden_part = if (a.hidden > 0) ui.fmt(" · {d} hidden", .{a.hidden}) else "";
    const cloud_part = if (a.cloud > 0) ui.fmt(" · {s} {d} cloud", .{ g.pick(ui.ascii, "☁", "c"), a.cloud }) else "";
    const line1 = ui.fmt("  {s} {d} waiting · {s} {d} live · {s} {d} tool · {s} {d} idle · {s} {d} failed · {s} {d} done{s}{s}{s} · {s} tokens · ${d:.2}", .{
        g.pick(ui.ascii, "⚠", "!"),
        a.waiting,
        g.pick(ui.ascii, "●", "*"),
        a.live,
        g.pick(ui.ascii, "▸", ">"),
        a.tool,
        g.pick(ui.ascii, "○", "o"),
        a.idle,
        g.pick(ui.ascii, "✗", "x"),
        a.failed,
        g.pick(ui.ascii, "·", "."),
        a.done,
        dirty_part,
        hidden_part,
        cloud_part,
        transcript.fmtTokens(&tb, a.tokens),
        a.cost,
    });
    const r1 = area.row(1);
    _ = ui.putStr(r1.x, r1.y, r1.w, ui.clipStr(line1, r1.w), Theme.withFg(bg, th.muted.fg));
    if (area.h < 3) return;
    const r2 = area.row(2);
    const v = props.selected orelse {
        _ = ui.putStr(r2.x + 2, r2.y, r2.w -| 2, "no session under the cursor", Theme.withFg(bg, th.muted.fg));
        return;
    };
    const it = v.it;
    const pid_part = if (it.pid) |p| ui.fmt(" · pid {d}", .{p}) else "";
    const branch_part = if (it.git_branch) |b| ui.fmt(" · {s} {s}", .{ g.pick(ui.ascii, "\u{F062C}", "@"), b }) else "";
    const where_part = if (it.where == .cloud) (if (it.cloud) |c| ui.fmt(" · cloud {s}{s}", .{ c.raw_state, if (c.pr_url) |u| ui.fmt(" · {s}", .{u}) else "" }) else " · cloud") else "";
    const line2 = ui.fmt("  {s} · {s} {s} · {s}{s}{s}{s} · {s}", .{ v.name, sourceGlyph(ui.ascii, it.source), it.source.label(), it.model orelse "?", pid_part, branch_part, where_part, it.cwd orelse it.workspace });
    // A cloud run's PR, a URL or a ticket key in the exchange: links
    // (`link_span`), like the same words on a card.
    link_span.mark(ui, r2.x, r2.y, ui.putStr(r2.x, r2.y, r2.w, ui.clipStr(line2, r2.w), Theme.withFg(bg, th.fg.fg)), line2);
    if (area.h < 5) return;
    const r3 = area.row(3);
    const r4 = area.row(4);
    const who: []const u8 = switch (it.source) {
        .claude => "claude",
        .codex => "codex",
    };
    const you = ui.fmt("  you: {s}", .{collapsed(ui, it.last_user_msg orelse "—")});
    const them = ui.fmt("  {s}: {s}", .{ who, collapsed(ui, it.last_assistant_msg orelse "—") });
    link_span.mark(ui, r3.x, r3.y, ui.putStr(r3.x, r3.y, r3.w, ui.clipStr(you, r3.w), Theme.withFg(bg, th.muted.fg)), you);
    link_span.mark(ui, r4.x, r4.y, ui.putStr(r4.x, r4.y, r4.w, ui.clipStr(them, r4.w), Theme.withFg(bg, th.muted.fg)), them);
}

/// Newlines and runs of whitespace as one space.
fn collapsed(ui: Ui, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) out.append(ui.arena, ' ') catch return s;
        out.appendSlice(ui.arena, w) catch return s;
    }
    return out.items;
}

fn drawHelp(ui: Ui, body: Rect) void {
    const th = ui.theme;
    ui.fill(body, th.overlay_bg);
    var title_style = Theme.onBg(th.warn_fg, th.overlay_bg.bg);
    title_style.bold = true;
    _ = ui.putStr(body.x, body.y, body.w, ui.clipStr(ui.fmt(" {s}", .{help_title}), body.w), title_style);
    var y: u16 = 1;
    for (help_lines) |h| {
        if (y >= body.h) break;
        const r = body.row(y);
        switch (h) {
            .section => |name| _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt(" ── {s} ", .{name}), r.w), Theme.onBg(th.accent, th.overlay_bg.bg)),
            .row => |kv| {
                _ = ui.putStr(r.x + 3, r.y, r.w -| 3, ui.clipStr(kv.key, 22), Theme.onBg(th.fg, th.overlay_bg.bg));
                _ = ui.putStr(r.x + 26, r.y, r.w -| 26, ui.clipStr(kv.what, r.w -| 26), Theme.onBg(th.muted, th.overlay_bg.bg));
            },
        }
        y += 1;
    }
}

/// `draw` parks the clock for `paintRow` (which sees no props).
pub fn setClock(now_ms: i64) void {
    ui_now_ms = now_ms;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");
const sessions = @import("../sessions.zig");

test "columns: every number at a wide row; the dirty, cost, tokens, age and id (with the #) columns go one by one as the row narrows, the name keeping 12 cells" {
    const wide = columns(100);
    try testing.expect(wide.num and wide.id and wide.tokens and wide.cost and wide.age and wide.dirty);
    const mid = columns(11 + 12 + col_num + col_id + col_tokens + col_age);
    try testing.expect(mid.id and mid.tokens and mid.age and !mid.cost and !mid.dirty);
    const narrow = columns(11 + 12 + col_num + col_id + col_age);
    try testing.expect(narrow.num and narrow.id and narrow.age and !narrow.tokens and !narrow.cost and !narrow.dirty);
    const bare = columns(30);
    try testing.expect(!bare.num and !bare.id and bare.right_w == 0);
}

test "a group row carries the captions over the numbers; a session row is the badge, the name and the numbers — never the message" {
    var f = try Fixture.init(90, 4);
    defer f.deinit();
    setClock(1_000_000 * 1000);
    ui_now_s = 1_000_000;
    var it = sessions.testItem("aaaaaaaa-1111", .streaming, 1_000_000 - 120, "mnml", "fix the tests");
    it.last_assistant_msg = "Running them now.";
    it.tokens = 12_500;
    it.cost_usd = 0.42;
    it.dirty = 3;
    it.cwd = "/w/mnml";
    const rows = [_]Row{
        .{ .group = .{ .key = "/w/mnml", .label = "mnml", .where = .local, .count = 1, .hidden = 2, .collapsed = false } },
        .{ .item = .{ .it = it, .name = "fix the tests", .ticked = true, .active = false, .pinned = false } },
    };
    paintRow(f.ui(), Rect.init(0, 0, 90, 1), rows[0], false);
    paintRow(f.ui(), Rect.init(0, 1, 90, 1), rows[1], false);
    var buf: [256]u8 = undefined;
    const g = f.row(0, &buf);
    try testing.expect(std.mem.indexOf(u8, g, "\u{F47C} mnml (1 · 2 hidden)") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, g, " "), "id  tokens     cost   age dirty"));
    var buf2: [256]u8 = undefined;
    const s = f.row(1, &buf2);
    // The row wears the product's own mark — `ui.claude_mark`'s, the
    // same one the session's pty tab and the cluster chip wear, not a
    // neutral star of the table's own.
    try testing.expect(std.mem.startsWith(u8, s, "☑ " ++ bufferline.claude_glyph ++ " ● live fix the tests"));
    try testing.expect(std.mem.indexOf(u8, s, "aaaaaaaa") != null);
    try testing.expect(std.mem.indexOf(u8, s, "12.5k") != null);
    try testing.expect(std.mem.indexOf(u8, s, "$0.42") != null);
    try testing.expect(std.mem.indexOf(u8, s, "2m") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, s, " "), "●3"));
    try testing.expect(std.mem.indexOf(u8, s, "Running") == null);
}

test "a session row wears the Claude mark the caller resolved — the spark once `ui.claude_mark` says so, the figure by default" {
    var f = try Fixture.init(90, 2);
    defer f.deinit();
    setClock(1_000_000 * 1000);
    ui_now_s = 1_000_000;
    defer ui_claude_mark = bufferline.claudeMark(.figure);
    const it = sessions.testItem("aaaaaaaa-1111", .idle, 1_000_000 - 120, "mnml", "fix the tests");
    const row: Row = .{ .item = .{ .it = it, .name = "fix the tests", .ticked = false, .active = false, .pinned = false } };
    ui_claude_mark = bufferline.claudeMark(.figure);
    paintRow(f.ui(), Rect.init(0, 0, 90, 1), row, false);
    ui_claude_mark = bufferline.claudeMark(.spark);
    paintRow(f.ui(), Rect.init(0, 1, 90, 1), row, false);
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(0, &a), bufferline.claude_glyph) != null);
    try testing.expect(std.mem.indexOf(u8, f.row(1, &b), bufferline.spark_glyph) != null);
    // Not both at once — the row took the mark it was given.
    try testing.expect(std.mem.indexOf(u8, f.row(0, &a), bufferline.spark_glyph) == null);
    try testing.expect(std.mem.indexOf(u8, f.row(1, &b), bufferline.claude_glyph) == null);
}

test "colors: a session row's first cell is the `▌` in its accent; a tick takes the cells over it; no colour is air" {
    var f = try Fixture.init(90, 3);
    defer f.deinit();
    setClock(1_000_000 * 1000);
    ui_now_s = 1_000_000;
    const it = sessions.testItem("aaaaaaaa-1111", .idle, 1_000_000 - 120, "mnml", "fix the tests");
    const rows = [_]Row{
        .{ .item = .{ .it = it, .name = "fix the tests", .ticked = false, .active = false, .pinned = false, .color = "red" } },
        .{ .item = .{ .it = it, .name = "fix the tests", .ticked = true, .active = false, .pinned = false, .color = "red" } },
        .{ .item = .{ .it = it, .name = "fix the tests", .ticked = false, .active = false, .pinned = false } },
    };
    for (rows, 0..) |r, i| paintRow(f.ui(), Rect.init(0, @intCast(i), 90, 1), r, false);
    const bar = f.screen.readCell(0, 0).?;
    try testing.expectEqualStrings("\u{258c}", bar.char.grapheme);
    try testing.expect(vaxis.Color.eql(bar.style.fg, f.theme.palette.red));
    try testing.expectEqualStrings("☑", f.screen.readCell(0, 1).?.char.grapheme);
    try testing.expectEqualStrings(" ", f.screen.readCell(0, 2).?.char.grapheme);
    // The name sits at the same cell on every row (the row text is
    // bytes, so the column is the width of what precedes the name).
    var buf: [128]u8 = undefined;
    var col: ?u16 = null;
    for (0..3) |y| {
        const line = f.row(@intCast(y), &buf);
        const at = std.mem.indexOf(u8, line, "fix the tests") orelse return error.TestUnexpectedResult;
        const c = f.ui().width(line[0..at]);
        if (col) |want| try testing.expectEqual(want, c) else col = c;
    }
}

test "the summary block links what the selected session's exchange holds: the URL takes a `.link` hit over its cells" {
    var f = try Fixture.init(80, 6);
    defer f.deinit();
    // A finder that knows URLs alone — no integration installed.
    const Urls = struct {
        var buf: [4]link_span.Span = undefined;
        fn find(_: *anyopaque, text: []const u8) []const link_span.Span {
            var n: usize = 0;
            var from: usize = 0;
            while (link_span.nextUrl(text, from)) |r| : (from = r.end) {
                if (n == buf.len) break;
                buf[n] = .{ .start = r.start, .end = r.end, .url = text[r.start..r.end] };
                n += 1;
            }
            return buf[0..n];
        }
    };
    var dummy: u8 = 0;
    var ui = f.ui();
    ui.links = .{ .ctx = &dummy, .find = Urls.find };
    var it = sessions.testItem("aaaaaaaa-1111", .idle, 1_000_000, "mnml", "see https://example.com/x please");
    it.last_assistant_msg = "Done.";
    const props: Props = .{ .rows = &.{}, .focused = true, .now_s = 1_000_000, .now_ms = 0, .agg = .{}, .selected = .{ .it = it, .name = "fix it", .ticked = false, .active = false, .pinned = false }, .total = 1, .scanning = false, .cloud_configured = false, .home_missing = false };
    drawSummary(ui, 1, Rect.init(0, 0, 80, 5), props);
    var buf: [256]u8 = undefined;
    const you = f.row(3, &buf);
    const at = std.mem.indexOf(u8, you, "https://").?;
    try testing.expectEqualStrings("https://example.com/x", f.hits.at(@intCast(at), 3).?.link.url);
    try testing.expectEqualStrings("https://example.com/x", f.hits.at(@intCast(at + 20), 3).?.link.url);
    try testing.expect(f.hits.at(@intCast(at + 21), 3).? != .link);
}
