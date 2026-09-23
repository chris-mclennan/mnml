//! The usage panes (`Pane.ai_usage`), Rust's `claude_usage_view.rs` /
//! `codex_usage_view.rs`: a header row with the key hints, then — for
//! Claude — one block per account behind a gutter bar (green for the
//! active one): the session window, the weekly window, each per-model
//! window, as a filled bar with its reset time; the retry-after line, the
//! guided re-auth, the empty / stale state. Codex is the spare pane:
//! tokens today, sessions today, the scan time. Props only — the app side
//! (`app/usage_pane.zig`) builds them off its state.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const ids = @import("../core/ids.zig");
const usage = @import("../ai/usage.zig");
const usage_pane = @import("../app/usage_pane.zig");
const list_panel = @import("list_panel.zig");
const localtime = @import("../core/localtime.zig");

pub const PaneId = ids.PaneId;

/// One account as the pane paints it.
pub const AccountView = struct {
    name: []const u8,
    usage: usage.Usage,
    email: ?[]const u8 = null,
    org: ?[]const u8 = null,
    is_active: bool = false,
};

pub const Props = struct {
    accounts: []const AccountView,
    codex: ?usage.Codex,
    /// Unix seconds, for the countdowns.
    now: u64,
    /// The zone the reset clocks read in.
    tz: Tz,
    loading: bool = false,
};

/// The zone the clocks read in: a fixed offset (the fixture's), or the
/// machine's, looked up at each instant — a weekly reset on the far side
/// of a daylight-saving change is in that side's offset, not today's.
pub const Tz = union(enum) {
    fixed: i64,
    local,

    /// Seconds east of UTC at `secs`.
    pub fn at(tz: Tz, secs: u64) i64 {
        return switch (tz) {
            .fixed => |o| o,
            .local => localtime.offset(@intCast(@min(secs, std.math.maxInt(i64)))),
        };
    }
};

/// The bar's width: the body minus the ` 100% used` suffix, at most 60.
pub const max_bar_w: u16 = 60;
pub const suffix_cells: u16 = 10;
pub const gutter_glyph = "▌";
pub const gutter_ascii = "|";

/// The pencil after an account's name: click renames it (Rust's
/// `claude_usage_pencils`, nf-fa-pencil).
pub const pencil_glyph = "\u{F040}";
pub const pencil_ascii = "e";
/// The mark before a limit-reset offer (and on the chip's block).
pub const offer_glyph = "↺";
pub const offer_ascii = "@";

/// A run of text; `hit` registers its cells as that `script_hit` id.
const Span = struct { text: []const u8, style: Theme.Style, hit: ?u32 = null };

const Row = struct {
    /// Painted first, in this style, when set.
    gutter: ?Theme.Style = null,
    /// The whole row's `script_hit` id (a span's own wins over it).
    hit: ?u32 = null,
    /// The pane menu's kebab, right-aligned (the header row).
    kebab: bool = false,
    body: union(enum) {
        spans: []const Span,
        bar: struct { percent: u16, severity: ?usage.Severity = null },
    },
};

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *usage_pane.UsagePane, props: Props, focused: bool) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    const bar_w: u16 = @min(area.w -| (suffix_cells + 2), max_bar_w);
    switch (p.product) {
        .claude => claudeRows(ui, &rows, props, focused) catch return,
        .codex => codexRows(ui, &rows, props, focused) catch return,
    }
    const visible: usize = area.h;
    const max_scroll = rows.items.len -| @max(visible, 1);
    if (p.scroll > max_scroll) p.scroll = max_scroll;
    var y: u16 = 0;
    var i = p.scroll;
    const pal = &th.palette;
    while (i < rows.items.len and y < area.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = area.row(y);
        const row = rows.items[i];
        if (row.hit) |h| ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = h } });
        var right = r.right();
        if (row.kebab) {
            const k = if (ui.ascii) list_panel.kebab_ascii else list_panel.kebab_glyph;
            const kw = ui.width(k);
            if (kw + 4 < r.w) {
                right -= kw;
                const kr = Rect.init(right, r.y, kw, 1);
                _ = ui.putStr(kr.x, kr.y, kw, k, Theme.onBg(th.muted, th.bg.bg));
                ui.hit(kr, .{ .script_hit = .{ .pane = pane, .id = usage_pane.hit_kebab } });
            }
        }
        var x = r.x;
        if (row.gutter) |g| x += ui.putStr(x, r.y, right -| x, if (ui.ascii) gutter_ascii else gutter_glyph, g);
        switch (row.body) {
            .spans => |spans| for (spans) |s| {
                if (x >= right) break;
                const w = ui.putStr(x, r.y, right - x, s.text, s.style);
                if (s.hit) |h| if (w > 0) ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = h } });
                x += w;
            },
            .bar => |b| {
                const clamped: u32 = @min(b.percent, 100);
                const filled: u16 = @intCast((@as(u32, bar_w) * clamped) / 100);
                const empty: u16 = bar_w -| filled;
                // The endpoint's own grade when it gave one, else Rust's
                // thresholds (85 / 60); below both, Claude Code's purple.
                const color = switch (usage.tierOfWire(b.percent, b.severity)) {
                    .hot => pal.red,
                    .warn => pal.yellow,
                    .ok => pal.purple,
                };
                if (filled > 0) ui.fill(Rect.init(x, r.y, @min(filled, r.right() -| x), 1), Theme.onBg(th.fg, color));
                x += filled;
                if (empty > 0 and x < r.right()) ui.fill(Rect.init(x, r.y, @min(empty, r.right() -| x), 1), Theme.onBg(th.fg, pal.bg2));
                x += empty;
                var label = Theme.onBg(th.fg, th.bg.bg);
                label.bold = true;
                if (x < r.right()) _ = ui.putStr(x, r.y, r.right() - x, ui.fmt(" {d}% used", .{b.percent}), label);
            },
        }
    }
}

/// A palette colour as text on the pane's ground.
fn colored(th: *const Theme, color: Theme.Color) Theme.Style {
    return Theme.onBg(Theme.withFg(th.fg, color), th.bg.bg);
}

fn claudeRows(ui: Ui, rows: *std.ArrayListUnmanaged(Row), props: Props, focused: bool) std.mem.Allocator.Error!void {
    const th = ui.theme;
    const a = ui.arena;
    const pal = &th.palette;
    const plain = Theme.onBg(th.fg, th.bg.bg);
    var bold = plain;
    bold.bold = true;
    const muted = Theme.onBg(th.muted, th.bg.bg);
    var hint = muted;
    hint.italic = true;
    var head_style = if (focused) bold else Theme.onBg(th.muted, th.bg.bg);
    head_style.bold = true;
    const yellow = Theme.onBg(th.warn_fg, th.bg.bg);
    const red = Theme.onBg(th.error_fg, th.bg.bg);
    const body_hit: ?u32 = usage_pane.hit_body;
    try rows.append(a, .{ .hit = body_hit, .kebab = true, .body = .{ .spans = try a.dupe(Span, &.{
        .{ .text = " Claude usage ", .style = head_style },
        .{ .text = overlay.hintText(ui, "· r refresh · a add · L claude login · R capture · esc close"), .style = hint },
    }) } });
    try rows.append(a, .{ .hit = body_hit, .body = .{ .spans = &.{} } });
    if (props.accounts.len == 0) {
        try rows.append(a, .{ .hit = body_hit, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "fetching… (link a token via `:ai.link_claude_token`)", .style = muted }}) } });
    }
    for (props.accounts, 0..) |acc, i| {
        const first = rows.items.len;
        const u = &acc.usage;
        var gutter = colored(th, if (acc.is_active) pal.green else pal.bg_darker);
        gutter.bold = acc.is_active;
        const g: ?Theme.Style = gutter;
        // `▌(active) name ✎ · email · org` (Rust's header shape).
        var head: std.ArrayListUnmanaged(Span) = .empty;
        if (acc.is_active) {
            var pill = colored(th, pal.green);
            pill.bold = true;
            try head.append(a, .{ .text = "(active) ", .style = pill });
        }
        try head.append(a, .{ .text = try std.fmt.allocPrint(a, "{s} ", .{acc.name}), .style = bold });
        try head.append(a, .{ .text = if (ui.ascii) pencil_ascii else pencil_glyph, .style = muted, .hit = usage_pane.hit_pencil_base + @as(u32, @intCast(i)) });
        var identity: std.ArrayListUnmanaged(u8) = .empty;
        if (acc.email) |e| try identity.print(a, " · {s}", .{e});
        if (acc.org) |o| try identity.print(a, " · {s}", .{o});
        if (identity.items.len > 0) try head.append(a, .{ .text = identity.items, .style = muted });
        try rows.append(a, .{ .gutter = g, .body = .{ .spans = head.items } });
        // A limit-reset offer, under the name (the key is a GUESS —
        // `usage.reset_offer_keys`).
        if (u.offer) |o| {
            var green = colored(th, pal.green);
            green.bold = true;
            const text = if (o.expires_at == 0) "Limit reset available" else blk: {
                var buf: [32]u8 = undefined;
                const soon = o.expires_at > props.now and o.expires_at - props.now < 86_400;
                const when = if (soon) usage.fmtShortTime(&buf, o.expires_at, props.tz.at(o.expires_at)) else usage.fmtLongTime(&buf, o.expires_at, props.tz.at(o.expires_at));
                break :blk try std.fmt.allocPrint(a, "Limit reset available · expires {s}", .{when});
            };
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{ .{ .text = if (ui.ascii) offer_ascii ++ " " else offer_glyph ++ " ", .style = green }, .{ .text = text, .style = green } }) } });
        }
        try rows.append(a, .{ .gutter = g, .body = .{ .spans = &.{} } });
        const ctx: WindowCtx = .{ .ui = ui, .rows = rows, .g = g, .bold = bold, .muted = muted, .tz = props.tz };
        try window(ctx, "Current session", u.percent, u.severity, u.resets_at, false, u.session_active, u.locked_reason, true);
        try window(ctx, "Current week (all models)", u.weekly_percent, u.weekly_severity, u.weekly_resets_at, true, u.weekly_active, u.weekly_locked_reason, true);
        // Per-model windows.
        for (u.scoped) |sc| try window(ctx, try std.fmt.allocPrint(a, "Current week ({s})", .{sc.model}), sc.percent, sc.severity, sc.resets_at, true, sc.is_active, null, false);
        // Windows the endpoint reports that this build does not name.
        for (u.windows) |w| try window(ctx, w.title, w.percent, null, w.resets_at, true, false, w.locked_reason, false);
        if (u.extra_usage) |e| {
            const state = if (e.enabled) "on" else "off";
            var line: std.ArrayListUnmanaged(u8) = .empty;
            try line.print(a, "  Extra usage: {s}", .{state});
            if (e.percent) |pct| try line.print(a, " · {d}% used", .{pct});
            if (!e.enabled) if (e.reason) |r| try line.print(a, " · {s}", .{try usage.humanWords(a, r)});
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = line.items, .style = muted }}) } });
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = &.{} } });
        }
        // A 429 is the server's own cooldown; any other failure backs
        // off on our side, and the row says which.
        if (u.retry_after_at > props.now) {
            const remaining = u.retry_after_at - props.now;
            const throttled = if (u.last_error) |e| std.mem.startsWith(u8, e, "HTTP 429") else false;
            const text = if (throttled) try std.fmt.allocPrint(a, "  Anthropic asked us to retry in {d}s (429)", .{remaining}) else try std.fmt.allocPrint(a, "  next fetch in {d}s", .{remaining});
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = text, .style = if (throttled) yellow else muted }}) } });
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = &.{} } });
        }
        if (u.needs_reauth) {
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "  ⚠ token expired — needs re-auth", .style = yellow }}) } });
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "    1. press L to run `claude login` (as {s})", .{acc.name}), .style = muted }}) } });
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "    2. press R to capture it from the keychain", .style = muted }}) } });
            if (u.last_error) |why| try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "    {s}", .{why}), .style = muted }}) } });
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = &.{} } });
        } else if (u.isEmpty()) {
            const text = if (u.last_error) |e| try std.fmt.allocPrint(a, "no data yet · last error: {s}", .{e}) else "fetching…";
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = text, .style = muted }}) } });
        } else if (u.last_error) |e| {
            try rows.append(a, .{ .gutter = g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  last fetch error: {s}", .{e}), .style = red }}) } });
        }
        // Every row of the block answers a right-click with the
        // account's menu.
        for (rows.items[first..]) |*r| r.hit = usage_pane.hit_account_base + @as(u32, @intCast(i));
        if (i + 1 < props.accounts.len) try rows.append(a, .{ .hit = body_hit, .body = .{ .spans = &.{} } });
    }
    try rows.append(a, .{ .hit = body_hit, .body = .{ .spans = &.{} } });
    try rows.append(a, .{ .hit = body_hit, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = " `:ai.refresh_usage` to force fetch · `:ai.show_last_response` for raw JSON ", .style = hint }}) } });
}

const WindowCtx = struct {
    ui: Ui,
    rows: *std.ArrayListUnmanaged(Row),
    g: ?Theme.Style,
    bold: Theme.Style,
    muted: Theme.Style,
    tz: Tz,
};

/// One window as Claude Code's usage screen draws it: the title (with
/// `· in force` when the endpoint says it is the binding limit), the
/// bar, the reset clock, a `Locked:` line when the window is locked.
/// `always_reset` paints "(reset time not available)" for a zero clock.
fn window(c: WindowCtx, title: []const u8, percent: u16, severity: ?usage.Severity, resets_at: u64, long: bool, active: bool, locked: ?[]const u8, always_reset: bool) std.mem.Allocator.Error!void {
    const a = c.ui.arena;
    const head: []const Span = if (active)
        try a.dupe(Span, &.{ .{ .text = title, .style = c.bold }, .{ .text = " · in force", .style = c.muted } })
    else
        try a.dupe(Span, &.{.{ .text = title, .style = c.bold }});
    try c.rows.append(a, .{ .gutter = c.g, .body = .{ .spans = head } });
    try c.rows.append(a, .{ .gutter = c.g, .body = .{ .bar = .{ .percent = percent, .severity = severity } } });
    if (resets_at > 0 or always_reset) try c.rows.append(a, .{ .gutter = c.g, .body = .{ .spans = try resetRow(a, resets_at, c.tz, long, c.muted) } });
    if (locked) |why| try c.rows.append(a, .{ .gutter = c.g, .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  Locked: {s}", .{try usage.humanWords(a, why)}), .style = c.muted }}) } });
    try c.rows.append(a, .{ .gutter = c.g, .body = .{ .spans = &.{} } });
}

fn resetRow(a: std.mem.Allocator, resets_at: u64, tz: Tz, long: bool, style: Theme.Style) std.mem.Allocator.Error![]const Span {
    if (resets_at == 0) return a.dupe(Span, &.{.{ .text = "  (reset time not available)", .style = style }});
    var buf: [32]u8 = undefined;
    const when = if (long) usage.fmtLongTime(&buf, resets_at, tz.at(resets_at)) else usage.fmtShortTime(&buf, resets_at, tz.at(resets_at));
    return a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  Resets {s}", .{when}), .style = style }});
}

fn codexRows(ui: Ui, rows: *std.ArrayListUnmanaged(Row), props: Props, focused: bool) std.mem.Allocator.Error!void {
    const th = ui.theme;
    const a = ui.arena;
    const pal = &th.palette;
    const plain = Theme.onBg(th.fg, th.bg.bg);
    var bold = plain;
    bold.bold = true;
    const muted = Theme.onBg(th.muted, th.bg.bg);
    var hint = muted;
    hint.italic = true;
    var head_style = if (focused) bold else Theme.onBg(th.muted, th.bg.bg);
    head_style.bold = true;
    try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{
        .{ .text = " Codex usage ", .style = head_style },
        .{ .text = overlay.hintText(ui, "· r refresh · esc close"), .style = hint },
    }) } });
    try rows.append(a, .{ .body = .{ .spans = &.{} } });
    if (props.codex) |c| {
        var nb: [32]u8 = undefined;
        try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "Tokens today", .style = bold }}) } });
        try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  {s}", .{usage.fmtThousands(&nb, c.tokens_today)}), .style = colored(th, pal.green) }}) } });
        try rows.append(a, .{ .body = .{ .spans = &.{} } });
        try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "Sessions today", .style = bold }}) } });
        try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  {d} session{s}", .{ c.sessions_today, if (c.sessions_today == 1) "" else "s" }), .style = muted }}) } });
        try rows.append(a, .{ .body = .{ .spans = &.{} } });
        if (c.fetched_at > 0) {
            var tb: [32]u8 = undefined;
            try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  Last scan: {s}", .{usage.fmtShortTime(&tb, c.fetched_at, props.tz.at(c.fetched_at))}), .style = muted }}) } });
            try rows.append(a, .{ .body = .{ .spans = &.{} } });
        }
        if (c.last_error) |e| {
            try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = try std.fmt.allocPrint(a, "  last scan error: {s}", .{e}), .style = Theme.onBg(th.error_fg, th.bg.bg) }}) } });
            try rows.append(a, .{ .body = .{ .spans = &.{} } });
        }
        if (c.tokens_today == 0 and c.sessions_today == 0 and c.last_error == null) {
            try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "  (no Codex sessions today yet — run `codex` to record one)", .style = muted }}) } });
        }
    } else {
        try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = "fetching… (scans ~/.codex/sessions/*.jsonl once mnml boots)", .style = muted }}) } });
    }
    try rows.append(a, .{ .body = .{ .spans = &.{} } });
    try rows.append(a, .{ .body = .{ .spans = try a.dupe(Span, &.{.{ .text = " `:ai.refresh_usage` to force scan ", .style = hint }}) } });
}
