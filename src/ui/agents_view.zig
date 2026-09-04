//! The Claude Agents dashboard (`Pane.claude_agents`): a title row with
//! the filter chips, an aggregate row, the session rows, and a
//! drill-down panel for the selected one. `?` swaps the body for the
//! help overlay. Every row and chip registers `.script_hit{pane, id}`;
//! the ids are `agents.zig`'s.
//!
//! In filter mode the title becomes
//! ` Claude Agents · /<query> · paused (filter) · enter applies · esc clears `
//! — the live-tail-suspended signal shows exactly when it matters.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const ids = @import("../core/ids.zig");
const agents = @import("../app/agents.zig");
const transcript = @import("../ai/transcript.zig");

pub const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;

pub const Props = struct {
    /// The rows in display order.
    rows: []const agents.Row,
    cursor: usize,
    focused: bool,
    workspace: []const u8,
    now_s: i64,
    ascii_ok: bool = true,
};

/// The help rows; the source-filter cycle is documented here.
pub const help_title = "Claude Agents — help (? to close)";
pub const Help = union(enum) { section: []const u8, row: struct { key: []const u8, what: []const u8 } };
pub const help_lines = [_]Help{
    .{ .section = "Navigation" },
    .{ .row = .{ .key = "j / k or ↑/↓", .what = "select row · mouse click also selects" } },
    .{ .row = .{ .key = "PgUp / PgDn", .what = "page through rows (10 at a time)" } },
    .{ .row = .{ .key = "Shift+PgUp / Shift+PgDn", .what = "scroll the drill-down panel" } },
    .{ .row = .{ .key = "Home / End", .what = "first / last row" } },
    .{ .section = "Filters" },
    .{ .row = .{ .key = "/", .what = "filter by text (workspace · id · model · last msg)" } },
    .{ .row = .{ .key = "0 / 1 / 2 / 3 / 4", .what = "filter by state (all / live / tool / idle / ended)" } },
    .{ .row = .{ .key = "> / <", .what = "cycle source filter (all → claude → codex → all)" } },
    .{ .row = .{ .key = "W", .what = "toggle workspace-only filter" } },
    .{ .row = .{ .key = "Ctrl+L", .what = "clear all filters at once" } },
    .{ .section = "Layout" },
    .{ .row = .{ .key = "g / G", .what = "jump to top / bottom of list" } },
    .{ .row = .{ .key = "s", .what = "cycle sort key (state → tokens↓ → cost↓ → recent → workspace)" } },
    .{ .row = .{ .key = "v", .what = "cycle drill-down view (Summary → Todos → Files → Bash → Agents)" } },
    .{ .row = .{ .key = "r", .what = "refresh now · p pause/resume the 3s auto-refresh" } },
    .{ .section = "Selection" },
    .{ .row = .{ .key = "space", .what = "toggle multi-select on the focused row" } },
    .{ .row = .{ .key = "R", .what = "clear multi-select" } },
    .{ .section = "Clipboard / Open" },
    .{ .row = .{ .key = "y / c", .what = "yank session id / cwd to clipboard" } },
    .{ .row = .{ .key = "t / Enter / dbl-click", .what = "open the transcript .jsonl in a split (live)" } },
    .{ .section = "Actions" },
    .{ .row = .{ .key = "o", .what = "resume the session in a new mnml pty pane" } },
    .{ .row = .{ .key = "K", .what = "SIGTERM the selected (or every ticked) session, after a confirm" } },
    .{ .row = .{ .key = "e", .what = "export the selected transcript as markdown" } },
    .{ .section = "Palette commands" },
    .{ .row = .{ .key = ":ai.session_search", .what = "grep all transcripts" } },
    .{ .row = .{ .key = ":ai.spend_today", .what = "today's tokens + cost by workspace" } },
    .{ .section = "Meta" },
    .{ .row = .{ .key = "? / F1", .what = "toggle this help (F1 works mid-filter)" } },
    .{ .row = .{ .key = "Esc / q", .what = "close the pane" } },
};

/// Paints the dashboard; returns the query caret in filter mode.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *agents.AgentsPane, props: Props) ?Caret {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return null;
    var caret: ?Caret = null;

    // ── title ──
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const title_style = Theme.onBg(if (props.focused) th.accent else th.muted, th.panel_bg.bg);
    const pause_chip: []const u8 = if (p.paused_by_user) " · paused" else if (p.filter_mode) " · paused (filter)" else "";
    if (p.filter_mode) {
        const lead = " Claude Agents · /";
        var x = head.x + ui.putStr(head.x, head.y, head.w, lead, title_style);
        const qw: u16 = @intCast(@min(@as(usize, head.w -| (x - head.x)), @max(p.query.items.len + 1, 8)));
        const qr = Rect.init(x, head.y, qw, 1);
        caret = text_field.draw(ui, qr, p.query.items, p.query_caret, .{ .style = Theme.onBg(th.fg, th.panel_bg.bg) });
        x += qw;
        const tail = ui.fmt("{s} · enter applies · esc clears ", .{pause_chip});
        _ = ui.putStr(x, head.y, head.right() -| x, ui.clipStr(tail, head.right() -| x), title_style);
    } else {
        const state_chip: []const u8 = if (p.state_filter) |s| switch (s) {
            .streaming => " · ●live",
            .tool_call => " · ▸tool",
            .idle => " · ○idle",
            .ended => " · ·ended",
        } else "";
        const source_chip: []const u8 = if (p.source_filter) |s| switch (s) {
            .claude => " · ✦claude",
            .codex => " · ◈codex",
        } else "";
        const ws_chip: []const u8 = if (p.workspace_only) " · this-ws" else "";
        const count_chip = if (p.anyFilter()) ui.fmt(" · {d}/{d}", .{ props.rows.len, p.rows.len }) else "";
        const multi = if (p.multi.count() > 0) ui.fmt(" · ☑ {d}", .{p.multi.count()}) else "";
        const busy: []const u8 = if (p.scanning) " · scanning…" else "";
        const query_part = if (p.query.items.len > 0) ui.fmt(" · filter: {s}", .{p.query.items}) else "";
        const left = ui.fmt(" Claude Agents{s}{s}{s}{s}{s}{s}{s}{s} · ", .{ query_part, source_chip, state_chip, ws_chip, pause_chip, multi, count_chip, busy });
        var x = head.x + ui.putStr(head.x, head.y, head.w, ui.clipStr(left, head.w), title_style);
        ui.hit(Rect.init(head.x, head.y, x - head.x, 1), .{ .script_hit = .{ .pane = pane, .id = agents.hit_title } });
        const chip_style = Theme.onBg(th.fg, th.chip.bg);
        x = chip(ui, x, head, ui.fmt("sort:{s}", .{p.sort.label()}), chip_style, pane, agents.hit_sort);
        x = chip(ui, x, head, ui.fmt("src:{s}", .{if (p.source_filter) |s| s.label() else "all"}), chip_style, pane, agents.hit_source);
        x = chip(ui, x, head, if (p.paused_by_user) "▶ resume" else "⏸ pause", chip_style, pane, agents.hit_pause);
        x = chip(ui, x, head, "↻ refresh", chip_style, pane, agents.hit_refresh);
        x = chip(ui, x, head, "? help", chip_style, pane, agents.hit_help);
        const hint = " · j/k · / filter · W ws · > src · s sort · v view · K kill ";
        _ = ui.putStr(x, head.y, head.right() -| x, ui.clipStr(hint, head.right() -| x), title_style);
    }
    if (area.h < 2) return caret;
    const body = area.splitTop(1).rest;
    if (p.help) {
        drawHelp(ui, body);
        return caret;
    }

    // ── aggregate ──
    const agg = p.aggregate();
    var tok_buf: [16]u8 = undefined;
    const agg_row = body.row(0);
    const agg_text = ui.fmt("  ● {d} live · ▸ {d} tool · ○ {d} idle · · {d} ended · {s} tokens · ${d:.4}", .{ agg.live, agg.tool, agg.idle, agg.ended, transcript.fmtTokens(&tok_buf, agg.tokens), agg.cost });
    _ = ui.putStr(agg_row.x, agg_row.y, agg_row.w, ui.clipStr(agg_text, agg_row.w), Theme.onBg(th.muted, th.bg.bg));
    if (body.h < 2) return caret;
    var rest = body.splitTop(1).rest;

    // ── rows + detail ──
    const detail_h: u16 = if (rest.h >= 10) @min(@max(rest.h / 3, 6), 12) else 0;
    var list = rest;
    var detail_area = Rect.empty;
    if (detail_h > 0 and rest.h > detail_h + 2) {
        const s = rest.splitBottom(detail_h);
        list = s.top;
        detail_area = s.rest;
    }
    rest = list;
    if (props.rows.len == 0) {
        const msg: []const u8 = if (p.scanning) "  Scanning ~/.claude/projects and ~/.codex/sessions…" else if (p.home == null) "  No home directory to scan — Claude / Codex sessions are read from ~/.claude and ~/.codex" else if (p.rows.len > 0) "  No sessions match the filters — Ctrl+L clears them" else "  No Claude / Codex sessions in the last 7 days — start one with ai.claude_code";
        _ = ui.putStr(list.x, list.y, list.w, ui.clipStr(msg, list.w), Theme.onBg(th.muted, th.bg.bg));
    } else {
        // Keep the cursor visible.
        const rows_h: usize = list.h;
        if (rows_h > 0) {
            if (p.cursor < p.scroll) p.scroll = p.cursor;
            if (p.cursor >= p.scroll + rows_h) p.scroll = p.cursor + 1 - rows_h;
        }
        var y: u16 = 0;
        var i = p.scroll;
        while (i < props.rows.len and y < list.h) : ({
            i += 1;
            y += 1;
        }) {
            const r = list.row(y);
            const row = props.rows[i];
            const sel = i == p.cursor;
            const bg = if (sel) th.cursor_line.bg else th.bg.bg;
            if (sel) ui.fill(r, th.cursor_line);
            const ticked = p.multi.contains(row.session_id);
            var x = r.x;
            x += ui.putStr(x, r.y, r.right() -| x, if (ticked) "☑ " else "  ", Theme.onBg(th.accent, bg));
            x += ui.putStr(x, r.y, r.right() -| x, row.source.glyph(ui.ascii), Theme.onBg(th.accent, bg));
            x += ui.putStr(x, r.y, r.right() -| x, " ", Theme.onBg(th.fg, bg));
            const badge = if (row.state == .tool_call and row.current_tool != null) ui.fmt("▸ {s}", .{row.current_tool.?[0..@min(row.current_tool.?.len, 8)]}) else row.state.badge(ui.ascii);
            const badge_style = switch (row.state) {
                .streaming => Theme.onBg(th.info_fg, bg),
                .tool_call => Theme.onBg(th.warn_fg, bg),
                .idle, .ended => Theme.onBg(th.muted, bg),
            };
            x += ui.putStr(x, r.y, @min(10, r.right() -| x), ui.fmt("{s:<10}", .{badge}), badge_style);
            x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s:<16} ", .{ui.clipStr(row.workspace, 16)}), Theme.onBg(th.fg, bg));
            x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s:<8} ", .{row.session_id[0..@min(8, row.session_id.len)]}), Theme.onBg(th.muted, bg));
            var tb: [16]u8 = undefined;
            x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s:>7} ${d:>7.4} ", .{ transcript.fmtTokens(&tb, row.tokens), row.cost_usd }), Theme.onBg(th.muted, bg));
            x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s:<10} ", .{ago(ui, props.now_s - row.last_activity_s)}), Theme.onBg(th.muted, bg));
            if (row.last_user_msg) |m| _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(m, r.right() -| x), Theme.onBg(th.fg, bg));
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = agents.row_base + @as(u32, @intCast(i)) } });
        }
    }
    if (!detail_area.isEmpty()) drawDetail(ui, pane, detail_area, p, props);
    return caret;
}

fn chip(ui: Ui, x_in: u16, head: Rect, label: []const u8, style: vaxis.Style, pane: PaneId, id: u32) u16 {
    var x = x_in;
    const text = ui.fmt(" {s} ", .{label});
    const w = ui.width(text);
    if (x + w + 1 > head.right()) return x;
    const r = Rect.init(x, head.y, w, 1);
    ui.fill(r, style);
    _ = ui.putStr(x, head.y, w, text, style);
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = id } });
    x += w;
    x += ui.putStr(x, head.y, head.right() -| x, " ", Theme.onBg(ui.theme.muted, ui.theme.panel_bg.bg));
    return x;
}

fn ago(ui: Ui, s: i64) []const u8 {
    if (s < 0) return "now";
    if (s < 60) return ui.fmt("{d}s ago", .{s});
    if (s < 3600) return ui.fmt("{d}m ago", .{@divFloor(s, 60)});
    if (s < 86400) return ui.fmt("{d}h ago", .{@divFloor(s, 3600)});
    return ui.fmt("{d}d ago", .{@divFloor(s, 86400)});
}

/// The drill-down panel for the selected row.
fn drawDetail(ui: Ui, pane: PaneId, area: Rect, p: *agents.AgentsPane, props: Props) void {
    const th = ui.theme;
    const head = area.row(0);
    var x = head.x;
    while (x < head.right()) : (x += 1) _ = ui.putStr(x, head.y, 1, if (ui.ascii) "-" else "─", Theme.onBg(th.border, th.bg.bg));
    const label = ui.fmt(" {s} (v cycles) ", .{p.detail.label()});
    _ = ui.putStr(head.x + 2, head.y, head.w -| 2, label, Theme.onBg(th.accent, th.bg.bg));
    ui.hit(head, .{ .script_hit = .{ .pane = pane, .id = agents.hit_detail } });
    if (area.h < 2) return;
    const body = area.splitTop(1).rest;
    const row = if (p.cursor < props.rows.len) props.rows[p.cursor] else {
        _ = ui.putStr(body.x + 2, body.y, body.w -| 2, "no session selected", Theme.onBg(th.muted, th.bg.bg));
        return;
    };
    var lines: [12][]const u8 = undefined;
    var n: usize = 0;
    switch (p.detail) {
        .summary => {
            lines[n] = ui.fmt("session {s} · {s} · {s} · pid {s} · pending tools {d}", .{ row.session_id, row.source.label(), row.model orelse "?", if (row.pid) |pid| ui.fmt("{d}", .{pid}) else "—", row.pending_tool_uses });
            n += 1;
            lines[n] = ui.fmt("cwd {s}", .{row.cwd orelse "?"});
            n += 1;
            lines[n] = ui.fmt("transcript {s}", .{row.transcript_path});
            n += 1;
            lines[n] = ui.fmt("user: {s}", .{row.last_user_msg orelse "—"});
            n += 1;
            lines[n] = ui.fmt("assistant: {s}", .{row.last_assistant_msg orelse "—"});
            n += 1;
        },
        .todos, .files, .bash, .agents => {
            lines[n] = ui.fmt("{s}: read from the transcript on open (t) — the tail keeps the last exchange only", .{p.detail.label()});
            n += 1;
        },
    }
    var y: u16 = 0;
    var i = p.detail_scroll;
    while (i < n and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(lines[i], r.w -| 2), Theme.onBg(if (i == 0) th.fg else th.muted, th.bg.bg));
    }
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
            .section => |name| {
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt(" ── {s} ", .{name}), r.w), Theme.onBg(th.accent, th.overlay_bg.bg));
            },
            .row => |kv| {
                const kw = ui.putStr(r.x + 3, r.y, r.w -| 3, ui.clipStr(kv.key, 26), Theme.onBg(th.fg, th.overlay_bg.bg));
                _ = kw;
                _ = ui.putStr(r.x + 30, r.y, r.w -| 30, ui.clipStr(kv.what, r.w -| 30), Theme.onBg(th.muted, th.overlay_bg.bg));
            },
        }
        y += 1;
    }
}

// ── tests ──

const testing = std.testing;

test "the help rows document the three-stop source cycle" {
    var found = false;
    for (help_lines) |h| switch (h) {
        .row => |kv| if (std.mem.eql(u8, kv.key, "> / <")) {
            try testing.expectEqualStrings("cycle source filter (all → claude → codex → all)", kv.what);
            found = true;
        },
        .section => {},
    };
    try testing.expect(found);
}
