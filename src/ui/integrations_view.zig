//! The INTEGRATIONS section — the sidebar column the Rust editor
//! paints (`rust-integrations-120x40.txt`): the caps header, the
//! three tabs (`Inst (3) Mkt (9)  (34)` — Installed, Marketplace, the
//! Dev tab's nf-fa-dev glyph), the filter pill — the sort chip sits in
//! the header's chip ladder, where every other section keeps it — then
//! three rows per entry — ` <glyph> Label`, the
//! dim command id / description / folder, a blank — with a scrollbar
//! when the list is longer than the column. Also the detail pane
//! (`Pane.integrations`, Rust's `IntegrationDetail`): the title line,
//! the description, a row of action buttons, then the manifest's
//! sections. And the palette-bar chip strip, which `render.zig` paints
//! between the search chip and the right cluster.
//!
//! Hits, each registered in the statement that paints it: the tabs are
//! `.button = tab_base + i`; the header's sort chip `.chip{ .integrations, .sort }`;
//! the filter `.filter_input = .integrations`; an entry's two text rows
//! `.row{ .integrations, idx }`; the scrollbar `.scrollbar{ .panel }`;
//! a detail button `.script_hit{ pane, id = i }`; a strip chip
//! `.button = chip_base + i`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const header = @import("header.zig");
const filter_input = @import("filter_input.zig");
const chip = @import("chip.zig");
const scrollbar = @import("scrollbar.zig");
const empty_state = @import("empty_state.zig");
const text_field = @import("text_field.zig");
const ids = @import("../core/ids.zig");
const manifest = @import("../bridge/manifest.zig");
const fonts_section = @import("fonts_section.zig");

pub const PaneId = ids.PaneId;
pub const Caret = text_field.Caret;
pub const EmptyState = empty_state.EmptyState;
const Style = vaxis.Style;
const Color = vaxis.Color;

/// `.button` ids of the palette-bar chips: `chip_base + index`. Kept
/// clear of `render.Button`'s small values and its `0x40`.. bases —
/// dispatch tests this range before the `Button` switch, so a base of
/// `0x10` swallowed `split_max` / `all_tabs` / `right_close`.
pub const chip_base: u32 = 0x0300;
pub const max_chips: u32 = 0x30;
/// `.button` ids of the section's three tabs: `tab_base + @intFromEnum(tab)`.
pub const tab_base: u32 = 0x0340;
/// // changed (lua-install): the SCRIPTS section's own three tabs, which
/// reuse `drawSection` — its own base so a click lands in its own
/// dispatch branch.
pub const script_tab_base: u32 = 0x0350;

pub const Tab = enum(u8) {
    installed,
    marketplace,
    dev,

    pub const all = [_]Tab{ .installed, .marketplace, .dev };

    pub fn next(t: Tab, show_dev: bool) Tab {
        return switch (t) {
            .installed => .marketplace,
            .marketplace => if (show_dev) .dev else .installed,
            .dev => .installed,
        };
    }

    pub fn prev(t: Tab, show_dev: bool) Tab {
        return switch (t) {
            .installed => if (show_dev) .dev else .marketplace,
            .marketplace => .installed,
            .dev => .marketplace,
        };
    }
};

/// nf-fa-dev — the Dev tab's whole label, as the Rust editor spells it.
pub const dev_glyph = "\u{eef4}";
pub const dev_ascii = "Dev";

/// What an entry's `[tag]` says.
pub const Kind = enum { installed, launcher, app, dev };

/// The chip after the label: provenance on the marketplace, the
/// install state on the Dev tab.
pub const Badge = enum {
    official,
    community,
    private,
    installed_here,
    not_installed,
    /// // changed (lua-install): a SCRIPTS row's own two states.
    dev,
    disabled,
    /// One of the four surfaces mnml ships itself
    /// (`app/integrations.zig`'s `first_party`) — nothing vouched for
    /// it from a marketplace source, so not `official`.
    first_party,

    pub fn text(b: Badge, ascii: bool) []const u8 {
        return switch (b) {
            .official => if (ascii) "+ Official" else "\u{2713} Official",
            .community => "~ Community",
            .private => "Private",
            .installed_here => "installed from here",
            .not_installed => "not installed",
            .dev => "Dev",
            .disabled => "disabled",
            .first_party => "first-party",
        };
    }
};

/// One three-row entry, as the app hands it over.
pub const Entry = struct {
    glyph: []const u8 = "",
    fallback: []const u8 = "",
    color: []const u8 = "",
    kind: Kind,
    label: []const u8,
    /// `(hidden)` — an installed integration whose chip is disabled.
    hidden: bool = false,
    /// `(<bin> not installed)`.
    missing: ?[]const u8 = null,
    version: []const u8 = "",
    badge: ?Badge = null,
    /// // changed (int-distribution): a Marketplace row's install
    /// state — `installed` / `update available` / `not installed`,
    /// after the badge. Null on a tab that has no such state to show.
    state: ?@import("../app/marketplace_catalogue.zig").State = null,
    /// `(source)` after the badge, dim.
    source: []const u8 = "",
    /// The second row: the first command's id, the description, the folder.
    line2: []const u8 = "",
    /// The whole entry dims (a marketplace row that is already installed).
    dim: bool = false,
    installing: bool = false,
    /// // changed (lua-polish): `⏱ N` after the badge — how many times
    /// this script tripped the 20 ms budget this session. 0 paints
    /// nothing, so a well-behaved script's row is unchanged and a slow
    /// one is visible before it is annoying (the platform design, §5).
    budget_hits: u32 = 0,
    /// An installed integration built on an SDK behind this mnml's (or
    /// never stamped): the `rebuild` chip at the row's right edge, in
    /// the same place and the same ink as the budget chip.
    rebuild: bool = false,
    /// With `rebuild`: there is no folder here to build it from (it was
    /// downloaded, or its folder is gone), so the chip says what it is —
    /// `old SDK` — rather than promise a rebuild that cannot run.
    rebuild_blocked: bool = false,
};

/// The `rebuild` chip's words. Plain ASCII, so it needs no twin.
pub const rebuild_text = "rebuild";
/// The chip on a stale row that cannot be rebuilt here: the same width
/// as `rebuild_text`, so a row's layout is one layout either way.
pub const old_sdk_text = "old SDK";

/// The budget chip's glyph and its `--ascii` twin. U+23F1 is a plain
/// Unicode symbol, not a Nerd Font one, so it needs no codepoint pin.
pub const budget_glyph = "\u{23F1}";
pub const budget_ascii = "!";

pub const SectionProps = struct {
    /// // changed (lua-install): which section is painting. The
    /// SCRIPTS section reuses this whole surface — the tabs, the sort
    /// chip, the filter pill, the three-row entries and the scrollbar
    /// — so the two never drift apart.
    panel: @import("hit.zig").PanelId = .integrations,
    label: []const u8 = "INTEGRATIONS",
    /// The `.button` base the tabs register under.
    tabs_at: u32 = tab_base,
    tab: Tab,
    /// Installed, marketplace, dev — the tab labels' counts.
    counts: [3]usize,
    show_dev: bool,
    filter: []const u8,
    filter_caret: usize,
    filter_anchor: ?usize = null,
    filter_focused: bool,
    /// The active tab's sort, short (`A-Z`).
    sort_label: []const u8,
    /// The widest label that sort can ever show — the header chip pads
    /// to it so it never resizes under a repeat-clicking pointer.
    sort_widest: usize = 0,
    rows: []const Entry,
    scroll: *usize,
    cursor: usize,
    focused: bool,
    empty: EmptyState,
    /// A fetch or an install runs: the refresh chip spins.
    busy: bool = false,
    now_ms: i64 = 0,
    /// The FONTS rows above the Marketplace entries (`fonts_section.zig`);
    /// null hides the section.
    fonts: ?fonts_section.Props = null,
    /// The ` + source ` chip on the header (` + ` where the column is
    /// narrow) — the Marketplace tab's add-a-source; `.chip{ panel,
    /// .new }`.
    add_source: bool = false,
};

/// The Marketplace tab's header chip: its full and narrow rungs.
pub const add_source_text = " + source ";
pub const add_source_short = " + ";

/// Rows an entry takes: the label row, the detail row, a blank. The
/// last entry of a window may drop its blank, so `h` rows hold
/// `(h + 1) / 3` entries.
pub const rows_per_entry: u16 = 3;
/// The body starts under the header, the tabs, the filter and one blank row.
pub const body_top: u16 = 4;

/// A manifest colour name (`cyan`, `#d16d51`) as a theme colour; the
/// accent when it names nothing.
pub fn paletteColor(th: *const Theme, name: []const u8) Color {
    const p = &th.palette;
    if (name.len == 7 and name[0] == '#') {
        if (std.fmt.parseInt(u24, name[1..], 16)) |hex| return Theme.rgb(hex) else |_| {}
    }
    const Named = struct { n: []const u8, c: Color };
    const table = [_]Named{
        .{ .n = "red", .c = p.red },      .{ .n = "orange", .c = p.orange },   .{ .n = "yellow", .c = p.yellow },
        .{ .n = "green", .c = p.green },  .{ .n = "blue", .c = p.blue },       .{ .n = "cyan", .c = p.cyan },
        .{ .n = "teal", .c = p.teal },    .{ .n = "purple", .c = p.purple },   .{ .n = "pink", .c = p.pink },
        .{ .n = "magenta", .c = p.pink }, .{ .n = "comment", .c = p.comment }, .{ .n = "grey", .c = p.grey },
        .{ .n = "fg", .c = p.fg },        .{ .n = "white", .c = p.fg },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(t.n, name)) return t.c;
    return th.accent.fg;
}

// ─── the palette-bar strip ───────────────────────────────────────────────

/// One chip of the strip, as the app hands it over.
pub const ChipProps = struct {
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8,
    enabled: bool,
};

/// Paints the chips right-to-left ending at `right_x` on row `y`, each
/// ` <glyph> ` with its colour (dim when disabled), and returns the x
/// the strip starts at. A chip that would not fit is dropped whole.
pub fn drawChips(ui: Ui, right_x: u16, y: u16, min_x: u16, bg: Style, chips: []const ChipProps) u16 {
    const th = ui.theme;
    var x = right_x;
    var i = chips.len;
    while (i > 0) {
        i -= 1;
        const c = chips[i];
        const glyph = if (ui.nerd_font and !ui.ascii and c.glyph.len > 0) c.glyph else if (c.fallback.len > 0) c.fallback else c.glyph;
        if (glyph.len == 0) continue;
        const w = ui.width(glyph) + 2;
        if (x < min_x + w) break;
        x -= w;
        var style = Theme.onBg(th.fg, bg.bg);
        style.fg = paletteColor(th, c.color);
        if (!c.enabled) style.dim = true;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, bg);
        _ = ui.putStr(x + 1, y, w - 2, glyph, style);
        ui.hit(r, .{ .button = chip_base + @as(u32, @intCast(i)) });
    }
    return x;
}

// ─── the section ─────────────────────────────────────────────────────────

const Tier = enum { full, compact, tiny };

fn tabLabel(ui: Ui, tab: Tab, tier: Tier, count: usize) []const u8 {
    return switch (tab) {
        .installed => switch (tier) {
            .full => ui.fmt("Installed ({d})", .{count}),
            .compact => ui.fmt("Inst ({d})", .{count}),
            .tiny => "Inst",
        },
        .marketplace => switch (tier) {
            .full => ui.fmt("Marketplace ({d})", .{count}),
            .compact => ui.fmt("Mkt ({d})", .{count}),
            .tiny => "Mkt",
        },
        .dev => ui.fmt("{s} ({d})", .{ if (ui.ascii or !ui.nerd_font) dev_ascii else dev_glyph, count }),
    };
}

/// The tab row: the largest label tier that fits, one cell of gutter
/// on the left, one cell between tabs; the active tab is the accent
/// pill. Registers `.button = tab_base + i` per tab.
fn drawTabs(ui: Ui, row: Rect, p: SectionProps) void {
    const t = ui.theme;
    ui.fill(row, t.panel_bg);
    const n: u16 = if (p.show_dev) 3 else 2;
    const avail = row.w -| 1;
    var tier: Tier = .full;
    var labels: [3][]const u8 = undefined;
    tiers: for ([_]Tier{ .full, .compact, .tiny }) |tr| {
        tier = tr;
        var total: u16 = n - 1;
        for (Tab.all[0..n]) |tab| {
            labels[@intFromEnum(tab)] = tabLabel(ui, tab, tr, p.counts[@intFromEnum(tab)]);
            total += ui.width(labels[@intFromEnum(tab)]);
        }
        if (total <= avail) break :tiers;
    }
    var x = row.x + 1;
    for (Tab.all[0..n]) |tab| {
        const label = labels[@intFromEnum(tab)];
        const w = @min(ui.width(label), row.right() -| x);
        if (w == 0) break;
        const active = tab == p.tab;
        const style = if (active) t.chip_active else Theme.onBg(t.muted, t.panel_bg.bg);
        const r = Rect.init(x, row.y, w, 1);
        _ = ui.putStr(x, row.y, w, ui.clipStr(label, w), style);
        ui.hit(r, .{ .button = p.tabs_at + @as(u32, @intFromEnum(tab)) });
        x += w + 1;
    }
}

pub fn drawSection(ui: Ui, area: Rect, p: SectionProps) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.isEmpty()) return null;
    const top = area.splitTop(1);
    // // changed (panel-consistency): the sort chip was painted at the
    // right end of the FILTER row, where no other section keeps it. It
    // is the header's mode chip now — the same ladder as TODOS /
    // NOTES / FINDINGS / SESSIONS, so at the shipped 26-cell width it
    // is the icon rung rather than a pill stealing the filter's cells.
    const mode_text: ?[]const u8 = chip.modeText(ui.arena, "sort", p.sort_label, p.sort_widest) catch null;
    const extra = [_]header.ExtraChip{.{ .text = add_source_text, .short = add_source_short, .id = 0, .style = chip.newStyle(t, t.panel_bg.bg), .kind = .new }};
    _ = header.draw(ui, top.top, .{
        .panel = p.panel,
        .label = p.label,
        .mode_chip = mode_text,
        .mode_kind = .sort,
        .bg = t.panel_bg,
        .extra = if (p.add_source) &extra else &.{},
    });
    if (p.busy) list_panel.paintSpinner(ui, top.top, p.label, p.now_ms);
    if (area.h < 2) return null;
    drawTabs(ui, area.row(1), p);
    if (area.h < 3) return null;

    // The filter pill, the shared widget across the whole row.
    const caret = filter_input.draw(ui, area.row(2), .{
        .panel = p.panel,
        .text = p.filter,
        .caret = p.filter_caret,
        .anchor = p.filter_anchor,
        .focused = p.filter_focused,
        .bg = t.panel_bg,
    });
    if (area.h <= body_top) return caret;
    var body = area;
    body.y += body_top;
    body.h -= body_top;
    if (p.fonts) |fp| {
        const used = fonts_section.draw(ui, body, fp);
        body.y += used;
        body.h -= used;
        if (body.h == 0) return caret;
    }

    if (p.rows.len == 0) {
        p.scroll.* = 0;
        _ = empty_state.draw(ui, body, p.empty, t.panel_bg);
        return caret;
    }
    const visible_entries: usize = @max((body.h + 1) / rows_per_entry, 1);
    const win = list_panel.scrollWindow(p.scroll, p.cursor, p.rows.len, visible_entries);
    var list = body;
    if (win.needs_bar and body.w > 4) {
        const split = body.splitRight(1);
        // One cell of air before the track, as the Rust panel reserves.
        list = Rect.init(split.left.x, split.left.y, split.left.w -| 1, split.left.h);
        scrollbar.drawVertical(ui, split.rest, .{ .panel = p.panel }, p.rows.len, visible_entries, p.scroll.*);
    }
    var y: u16 = 0;
    var i: usize = win.first;
    while (i < p.rows.len and y + 1 < list.h) : (i += 1) {
        const e = p.rows[i];
        const selected = i == p.cursor;
        const r1 = list.row(y);
        const r2 = list.row(y + 1);
        const style = list_panel.rowStyle(t, selected);
        ui.fill(r1, style);
        ui.fill(r2, style);
        // // changed (panel-consistency): the gutter ran on `r1` alone,
        // so a selected entry was half-marked; `paintMarker` takes the
        // entry's whole height.
        if (selected) list_panel.paintMarker(ui, Rect.init(r1.x, r1.y, r1.w, 2), style, p.focused);
        paintEntry(ui, r1, r2, e, style);
        ui.hit(r1, .{ .row = .{ .panel = p.panel, .idx = @intCast(i) } });
        ui.hit(r2, .{ .row = .{ .panel = p.panel, .idx = @intCast(i) } });
        y += rows_per_entry;
    }
    return caret;
}

fn paintEntry(ui: Ui, r1: Rect, r2: Rect, e: Entry, style: Style) void {
    const t = ui.theme;
    const dimmed = e.dim or e.hidden;
    var x = r1.x + 2;
    var right = r1.right();
    // The budget chip is painted at the row's RIGHT edge, and its cells
    // come out of the run before anything else takes them: at the
    // shipped `ui.tree_width = 30` the column is 26 cells wide and the
    // label, version and badge already fill them, so a chip appended
    // after all of those would never be on screen at all.
    const chip_text: []const u8 = if (e.rebuild)
        (if (e.rebuild_blocked) old_sdk_text else rebuild_text)
    else if (e.budget_hits == 0)
        ""
    else if (ui.ascii)
        ui.fmt("{s}{d}", .{ budget_ascii, e.budget_hits })
    else
        ui.fmt("{s} {d}", .{ budget_glyph, e.budget_hits });
    const chip_w = ui.width(chip_text);
    // Below this the row is a label and nothing else; a chip would be
    // the whole row.
    const chip_fits = chip_w > 0 and r1.w > chip_w + 9;
    if (chip_fits) {
        // +2: one cell of air before the chip, one after it (the last
        // column of the row is the column's border).
        right -|= @intCast(chip_w + 2);
        // Painted BEFORE the left-to-right run, so the run clips
        // against the narrowed `right` instead of overwriting it.
        _ = ui.putStrRight(r1.right() - 1, r1.y, chip_w, chip_text, Theme.withFg(style, t.palette.yellow));
    }
    // The glyph, coloured; the `[tag]` when there is one.
    const glyph = if (ui.nerd_font and !ui.ascii and e.glyph.len > 0) e.glyph else e.fallback;
    if (glyph.len > 0) {
        var gs = Theme.withFg(style, paletteColor(t, e.color));
        if (dimmed) gs.dim = true;
        x += ui.putStr(x, r1.y, right -| x, glyph, gs);
        x += if (e.kind == .installed) 1 else 2;
    }
    if (e.kind != .installed) {
        const tag: []const u8 = if (e.dim) "[installed]" else switch (e.kind) {
            .launcher => "[launcher]",
            .app => "[app]",
            .dev => "[dev]",
            .installed => unreachable,
        };
        const tag_fg: Color = if (e.dim) t.muted.fg else switch (e.kind) {
            .launcher => t.palette.cyan,
            .app, .dev => t.palette.orange,
            .installed => unreachable,
        };
        x += ui.putStr(x, r1.y, right -| x, tag, Theme.withFg(style, tag_fg));
        x += ui.putStr(x, r1.y, right -| x, " ", style);
    }
    var ls = Theme.withFg(style, if (e.missing != null or dimmed) t.muted.fg else t.fg.fg);
    if (dimmed) ls.dim = true;
    x += ui.putStr(x, r1.y, right -| x, ui.clipStr(e.label, right -| x), ls);
    if (e.hidden) {
        var hs = Theme.withFg(style, t.muted.fg);
        hs.dim = true;
        hs.italic = true;
        x += ui.putStr(x, r1.y, right -| x, " (hidden)", hs);
    }
    if (e.missing) |bin| {
        var ms = Theme.withFg(style, t.palette.red);
        ms.dim = true;
        x += ui.putStr(x, r1.y, right -| x, ui.clipStr(ui.fmt(" ({s} not installed)", .{bin}), right -| x), ms);
    }
    if (e.version.len > 0) x += ui.putStr(x, r1.y, right -| x, ui.fmt("  {s}", .{e.version}), Theme.withFg(style, t.muted.fg));
    if (e.badge) |b| {
        const fg: Color = switch (b) {
            .official, .installed_here => t.palette.green,
            .community, .not_installed, .disabled => t.muted.fg,
            .private => t.palette.yellow,
            .dev => t.palette.orange,
            .first_party => t.palette.teal,
        };
        x += ui.putStr(x, r1.y, right -| x, ui.fmt("  {s}", .{b.text(ui.ascii)}), Theme.withFg(style, fg));
    }
    if (e.state) |st| {
        const fg: Color = switch (st) {
            .installed => t.palette.green,
            .update => t.palette.yellow,
            .not_installed => t.muted.fg,
        };
        x += ui.putStr(x, r1.y, right -| x, ui.clipStr(ui.fmt("  {s}", .{st.text()}), right -| x), Theme.withFg(style, fg));
    }
    if (e.source.len > 0) {
        var ss = Theme.withFg(style, t.muted.fg);
        ss.dim = true;
        x += ui.putStr(x, r1.y, right -| x, ui.clipStr(ui.fmt("  ({s})", .{e.source}), right -| x), ss);
    }
    if (e.installing) {
        const note: []const u8 = if (ui.ascii) "installing..." else "installing…";
        const nw = ui.width(note);
        if (right > x + nw + 1) _ = ui.putStrRight(right - 1, r1.y, nw, note, Theme.withFg(style, t.info_fg.fg));
    }
    // Row 2: the id / description / folder, dim.
    var ds = Theme.withFg(style, t.muted.fg);
    ds.dim = true;
    _ = ui.putStr(r2.x + 4, r2.y, r2.right() -| (r2.x + 4), ui.clipStr(e.line2, r2.right() -| (r2.x + 4)), ds);
}

// ─── the detail pane ─────────────────────────────────────────────────────

pub const DetailProps = struct {
    glyph: []const u8 = "",
    fallback: []const u8 = "",
    color: []const u8 = "",
    label: []const u8,
    id: []const u8,
    version: []const u8 = "",
    category: []const u8 = "",
    description: []const u8 = "",
    /// `installed · ~/.config/mnml/integrations/sample.zon`, `marketplace · acme (launcher)`, `dev · integrations/sample`.
    origin: []const u8 = "",
    binary: []const u8 = "",
    mode: []const u8 = "",
    /// `binary missing`, `disabled`, `installing…`.
    status: ?[]const u8 = null,
    commands: []const manifest.Command = &.{},
    settings: []const manifest.Setting = &.{},
    requires: []const []const u8 = &.{},
    statusline: []const manifest.manifest.StatuslineSegment = &.{},
    context_menu: []const manifest.manifest.ContextMenuEntry = &.{},
    menu_bar: []const manifest.manifest.MenuBarEntry = &.{},
    /// The action buttons, in order; `cursor` is the focused one.
    buttons: []const []const u8 = &.{},
    cursor: usize = 0,
    focused: bool = false,
};

/// The detail pane. Returns nothing; the buttons' hits carry the actions.
pub fn drawDetail(ui: Ui, pane: PaneId, area: Rect, p: DetailProps) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    var y: u16 = 0;
    // The title line.
    {
        const r = area.row(y);
        var x = r.x + 1;
        const glyph = if (ui.nerd_font and !ui.ascii and p.glyph.len > 0) p.glyph else p.fallback;
        if (glyph.len > 0) {
            var gs = t.fg;
            gs.fg = paletteColor(t, p.color);
            x += ui.putStr(x, r.y, r.right() -| x, glyph, gs);
            x += 1;
        }
        var ls = t.fg;
        ls.bold = true;
        x += ui.putStr(x, r.y, r.right() -| x, p.label, ls);
        const meta = ui.fmt("  {s}{s}{s}{s}{s}", .{ p.id, if (p.version.len > 0) "  v" else "", p.version, if (p.category.len > 0) " · " else "", p.category });
        x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(meta, r.right() -| x), t.muted);
        if (p.status) |s| {
            const sw = ui.width(s);
            if (r.right() > x + sw + 2) _ = ui.putStrRight(r.right() - 1, r.y, sw, s, t.warn_fg);
        }
        y += 1;
    }
    if (y < area.h and p.description.len > 0) {
        const r = area.row(y);
        _ = ui.putStr(r.x + 1, r.y, r.w -| 2, ui.clipStr(p.description, r.w -| 2), t.muted);
        y += 1;
    }
    if (y < area.h and p.origin.len > 0) {
        const r = area.row(y);
        var os = t.muted;
        os.dim = true;
        _ = ui.putStr(r.x + 1, r.y, r.w -| 2, ui.clipStr(p.origin, r.w -| 2), os);
        y += 1;
    }
    y += 1;
    // The buttons: `[ Open ]  [ Disable ]  …`, the focused one on the accent.
    if (y < area.h and p.buttons.len > 0) {
        const r = area.row(y);
        var x = r.x + 1;
        for (p.buttons, 0..) |label, i| {
            const text = ui.fmt("[ {s} ]", .{label});
            const w = ui.width(text);
            if (x + w > r.right()) break;
            const sel = i == p.cursor;
            var bs: Style = if (sel) t.chip_active else Theme.onBg(t.accent, t.bg.bg);
            if (sel and !p.focused) bs = Theme.onBg(t.muted, t.chip.bg);
            const br = Rect.init(x, r.y, w, 1);
            _ = ui.putStr(x, r.y, w, text, bs);
            ui.hit(br, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
            x += w + 2;
        }
        y += 2;
    }
    const Line = struct { k: []const u8, v: []const u8 };
    const Sect = struct {
        fn head(u: Ui, a: Rect, yy: *u16, title: []const u8) bool {
            if (yy.* >= a.h) return false;
            const r = a.row(yy.*);
            var hs = u.theme.muted;
            hs.bold = true;
            var x = r.x + 1;
            x += u.putStr(x, r.y, r.w -| 2, u.fmt("{s} ", .{title}), hs);
            u.hrule(x, r.y, (r.right() - 1) -| x, u.theme.muted);
            yy.* += 1;
            return true;
        }
        fn line(u: Ui, a: Rect, yy: *u16, l: Line) void {
            if (yy.* >= a.h) return;
            const r = a.row(yy.*);
            var x = r.x + 3;
            if (l.k.len > 0) {
                x += u.putStr(x, r.y, r.right() -| x, l.k, u.theme.accent);
                x += u.putStr(x, r.y, r.right() -| x, "  ", u.theme.fg);
            }
            _ = u.putStr(x, r.y, r.right() -| x, u.clipStr(l.v, r.right() -| x), u.theme.fg);
            yy.* += 1;
        }
    };
    if (p.commands.len > 0 and Sect.head(ui, area, &y, "Commands")) {
        for (p.commands) |c| {
            var v: []const u8 = c.title;
            for (c.keys) |k| v = ui.fmt("{s}  {s}", .{ v, k });
            if (c.ex) |ex| v = ui.fmt("{s}  :{s}", .{ v, ex });
            Sect.line(ui, area, &y, .{ .k = c.id, .v = v });
        }
        y += 1;
    }
    if (p.settings.len > 0 and Sect.head(ui, area, &y, "Settings")) {
        for (p.settings) |s| {
            var v: []const u8 = "";
            for (s.options, 0..) |o, i| v = ui.fmt("{s}{s}{s}{s}{s}", .{ v, if (i > 0) " / " else "", if (std.mem.eql(u8, o, s.default)) "[" else "", o, if (std.mem.eql(u8, o, s.default)) "]" else "" });
            Sect.line(ui, area, &y, .{ .k = s.key, .v = ui.fmt("{s}: {s}", .{ s.label, v }) });
        }
        y += 1;
    }
    if (p.statusline.len > 0 and Sect.head(ui, area, &y, "Statusline")) {
        for (p.statusline) |s| Sect.line(ui, area, &y, .{ .k = s.id, .v = ui.fmt("{s}  {s}{s}{s}", .{ s.text, @tagName(s.side), if (s.click_command) |_| "  click: " else "", s.click_command orelse "" }) });
        y += 1;
    }
    if ((p.context_menu.len > 0 or p.menu_bar.len > 0) and Sect.head(ui, area, &y, "Menus")) {
        for (p.context_menu) |c| Sect.line(ui, area, &y, .{ .k = c.target.kind, .v = ui.fmt("{s}  {s}", .{ c.text(), c.command }) });
        for (p.menu_bar) |m| Sect.line(ui, area, &y, .{ .k = m.path, .v = m.command });
        y += 1;
    }
    if (p.requires.len > 0 and Sect.head(ui, area, &y, "Requires")) {
        var v: []const u8 = "";
        for (p.requires, 0..) |r, i| v = ui.fmt("{s}{s}{s}", .{ v, if (i > 0) ", " else "", r });
        Sect.line(ui, area, &y, .{ .k = "", .v = v });
        y += 1;
    }
    if (Sect.head(ui, area, &y, "Binary")) {
        Sect.line(ui, area, &y, .{ .k = "binary", .v = p.binary });
        if (p.mode.len > 0) Sect.line(ui, area, &y, .{ .k = "mode", .v = p.mode });
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn sectionProps(rows: []const Entry, scroll: *usize, tab: Tab) SectionProps {
    return .{
        .tab = tab,
        .counts = .{ 3, 9, 34 },
        .show_dev = true,
        .filter = "",
        .filter_caret = 0,
        .filter_focused = false,
        .sort_label = "A-Z",
        .sort_widest = 8, // "Category"
        .rows = rows,
        .scroll = scroll,
        .cursor = 0,
        .focused = true,
        .empty = .{ .message = "Nothing installed yet — try the Marketplace tab" },
    };
}

test "the Marketplace tab's + source chip: the narrow rung at the shipped 26 and around it, the full one where it fits, a .new chip either way; no chip without the flag" {
    var scroll: usize = 0;
    inline for (.{ 26, 30, 34, 50 }) |w| {
        var f = try Fixture.init(w, 6);
        defer f.deinit();
        var p = sectionProps(&.{}, &scroll, .marketplace);
        p.add_source = true;
        _ = drawSection(f.ui(), f.full(), p);
        // ` + source ` needs 10 cells + one of air beside the 14-cell title.
        const full = w >= 34;
        const text = if (full) add_source_text else add_source_short;
        var buf: [1024]u8 = undefined;
        const row0 = f.row(0, &buf);
        const at = std.mem.indexOf(u8, row0, text) orelse return error.TestExpectedChip;
        try testing.expect(std.mem.indexOf(u8, row0, "INTEGRATIONS") != null);
        // Every cell of the chip is the chip, and it sits left of the sort chip.
        const x0: u16 = @intCast(try std.unicode.utf8CountCodepoints(row0[0..at]));
        var x = x0;
        while (x < x0 + text.len) : (x += 1) try testing.expectEqual(chip.ChipKind.new, f.hits.at(x, 0).?.chip.kind);
        try testing.expectEqual(chip.ChipKind.sort, f.hits.at(x + 1, 0).?.chip.kind);
        try testing.expect(vaxis.Color.eql(f.style(x0 + 1, 0).fg, f.theme.palette.green));
    }
    var g = try Fixture.init(26, 6);
    defer g.deinit();
    _ = drawSection(g.ui(), g.full(), sectionProps(&.{}, &scroll, .marketplace));
    var gbuf: [1024]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, g.row(0, &gbuf), " + ") == null);
}

test "the section: header with the sort chip in its ladder, the three tabs at the Rust widths, the filter across the whole row, three rows per entry, the gutter down BOTH rows of the selected one" {
    var f = try Fixture.init(26, 14);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Entry{
        .{ .glyph = "B", .fallback = "B", .color = "blue", .kind = .installed, .label = "Browser", .line2 = "browser.open" },
        .{ .glyph = "C", .fallback = "C", .color = "orange", .kind = .installed, .label = "Claude Code", .hidden = true, .line2 = "ai.claude_code" },
    };
    _ = drawSection(f.ui(), f.full(), sectionProps(&rows, &scroll, .installed));
    try f.expectContains("INTEGRATIONS");
    // 26 wide: the compact tier, as the Rust dump at the shipped width.
    try f.expectRow(1, " Inst (3) Mkt (9) " ++ dev_glyph ++ " (34)");
    // The sort chip is the header's, at the icon rung the 26-cell
    // shipped width leaves — never on the filter row, where no other
    // section keeps it.
    try f.expectRow(0, " INTEGRATIONS" ++ " " ** 7 ++ "\u{f0dc}   \u{eb37}");
    try f.expectLacks("A-Z");
    try f.expectRow(2, "  \u{F0349} / filter");
    // The selected entry's gutter runs BOTH its rows.
    try f.expectRow(4, "\u{258c} B Browser");
    try f.expectRow(5, "\u{258c}   browser.open");
    try f.expectRow(6, "");
    try f.expectRow(7, "  C Claude Code (hidden)");
    try testing.expect(f.bgEql(10, 4, f.theme.cursor_line));
    try testing.expect(f.bgEql(10, 5, f.theme.cursor_line));
    try testing.expect(f.fgEql(0, 5, f.theme.accent));
    try testing.expectEqual(tab_base + 0, f.hits.at(2, 1).?.button);
    try testing.expectEqual(tab_base + 2, f.hits.at(20, 1).?.button);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 5).?.row.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 8).?.row.idx);
    try testing.expectEqual(chip.ChipKind.sort, f.hits.at(20, 0).?.chip.kind);
    try testing.expectEqual(chip.ChipKind.refresh, f.hits.at(24, 0).?.chip.kind);
    try testing.expectEqual(list_panel.PanelId.integrations, f.hits.at(5, 2).?.filter_input);
    // Where the sort pill used to sit the filter now reaches: the pill
    // is the whole row, and nothing on it is a chip.
    try testing.expectEqual(list_panel.PanelId.integrations, f.hits.at(22, 2).?.filter_input);
    // The active pill is the accent; the hidden row dims.
    try testing.expect(f.bgEql(1, 1, f.theme.chip_active));
    try testing.expect(f.style(6, 7).dim);
    // Wide enough for the full labels.
    var g = try Fixture.init(50, 6);
    defer g.deinit();
    _ = drawSection(g.ui(), g.full(), sectionProps(&rows, &scroll, .marketplace));
    try g.expectRow(1, " Installed (3) Marketplace (9) " ++ dev_glyph ++ " (34)");
    try testing.expect(g.bgEql(16, 1, g.theme.chip_active));
    // Too narrow for the counts: the tiny tier.
    var h = try Fixture.init(16, 6);
    defer h.deinit();
    _ = drawSection(h.ui(), h.full(), sectionProps(&rows, &scroll, .installed));
    try h.expectRow(1, " Inst Mkt " ++ dev_glyph ++ " (34)");
}

test "marketplace and dev rows carry their tag, badge and source; the empty state paints; a long list gets a bar" {
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Entry{
        .{ .glyph = "b", .fallback = "b", .kind = .launcher, .label = "btop", .badge = .official, .source = "acme", .line2 = "Resource monitor" },
        .{ .kind = .app, .label = "mnml-db", .badge = .community, .source = "me", .line2 = "Databases", .dim = true, .installing = true },
        .{ .kind = .dev, .label = "Sample", .badge = .installed_here, .source = "integrations", .line2 = "integrations/sample" },
    };
    _ = drawSection(f.ui(), f.full(), sectionProps(&rows, &scroll, .marketplace));
    try f.expectContains("\u{258c} b  [launcher] btop  \u{2713} Official  (acme)");
    try f.expectContains("\u{258c}   Resource monitor");
    try f.expectContains("[installed] mnml-db  ~ Community  (me)");
    try f.expectContains("installing…");
    // Ten rows hold two entries; three need the bar.
    try testing.expect(f.hits.at(59, 5).? == .scrollbar);
    var g = try Fixture.init(40, 10);
    defer g.deinit();
    var p = sectionProps(&rows, &scroll, .dev);
    p.rows = &.{};
    p.empty = .{ .message = "No dev roots yet", .hint = "integrations.dev_roots" };
    _ = drawSection(g.ui(), g.full(), p);
    try g.expectRow(4, "  No dev roots yet");
    try g.expectRow(5, "  integrations.dev_roots");
    var h = try Fixture.init(60, 10);
    defer h.deinit();
    _ = drawSection(h.ui(), h.full(), sectionProps(rows[2..], &scroll, .dev));
    try h.expectRow(4, "\u{258c} [dev] Sample  installed from here  (integrations)");
}

test "a mnml-catalogue row paints its version, badge and install state — installed, update available, not installed" {
    var f = try Fixture.init(70, 12);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Entry{
        .{ .kind = .app, .label = "Jira", .version = "0.2.0", .badge = .official, .state = .not_installed, .source = "mnml", .line2 = "Jira: work, boards" },
        .{ .kind = .app, .label = "Bitbucket", .version = "0.2.0", .badge = .official, .state = .installed, .source = "mnml", .line2 = "PRs + pipelines", .dim = true },
        .{ .kind = .app, .label = "Sample", .version = "0.2.0", .badge = .official, .state = .update, .source = "mnml", .line2 = "The counter", .dim = true },
    };
    _ = drawSection(f.ui(), f.full(), sectionProps(&rows, &scroll, .marketplace));
    // Version, then badge, then state, then the source.
    try f.expectContains("[app] Jira  0.2.0  \u{2713} Official  not installed  (mnml)");
    try f.expectContains("Bitbucket  0.2.0  \u{2713} Official  installed  (mnml)");
    try f.expectContains("Sample  0.2.0  \u{2713} Official  update available  (mnml)");
    // A row with no state to show paints none of it.
    const plain = [_]Entry{.{ .kind = .launcher, .label = "btop", .badge = .official, .source = "acme", .line2 = "Resource monitor" }};
    var g = try Fixture.init(60, 8);
    defer g.deinit();
    _ = drawSection(g.ui(), g.full(), sectionProps(&plain, &scroll, .marketplace));
    try g.expectContains("[launcher] btop  \u{2713} Official  (acme)");
}

test "the detail pane: title, buttons with hits, the manifest's sections" {
    var f = try Fixture.init(70, 20);
    defer f.deinit();
    const cmds = [_]manifest.Command{.{ .id = "sample.open", .title = "Sample: open", .keys = &.{"ctrl+k s"} }};
    const segs = [_]manifest.manifest.StatuslineSegment{.{ .id = "chip", .text = "S·1", .click_command = "sample.open" }};
    drawDetail(f.ui(), 7, f.full(), .{
        .glyph = "S",
        .fallback = "S",
        .label = "Sample",
        .id = "sample",
        .version = "0.1.0",
        .category = "sample",
        .description = "The sample",
        .origin = "installed · integrations/sample.zon",
        .binary = "mnml-sample",
        .mode = "mount",
        .status = "binary missing",
        .commands = &cmds,
        .statusline = &segs,
        .requires = &.{"SAMPLE_TOKEN"},
        .buttons = &.{ "Open", "Disable", "Uninstall" },
        .cursor = 1,
        .focused = true,
    });
    try f.expectContains("S Sample  sample  v0.1.0 · sample");
    try f.expectContains("binary missing");
    try f.expectContains("[ Open ]  [ Disable ]  [ Uninstall ]");
    try testing.expectEqual(@as(u32, 1), f.hits.at(12, 4).?.script_hit.id);
    try testing.expectEqual(@as(u32, 7), f.hits.at(12, 4).?.script_hit.pane);
    try f.expectContains("Commands ");
    try f.expectContains("sample.open  Sample: open  ctrl+k s");
    try f.expectContains("chip  S·1  right  click: sample.open");
    try f.expectContains("SAMPLE_TOKEN");
    try f.expectContains("binary  mnml-sample");
}

test "chips paint right-to-left with their hits and drop what does not fit" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    const chips = [_]ChipProps{
        .{ .glyph = "A", .fallback = "A", .color = "red", .enabled = true },
        .{ .glyph = "B", .fallback = "B", .color = "#00ff00", .enabled = false },
        .{ .glyph = "C", .fallback = "C", .color = "nope", .enabled = true },
    };
    const x = drawChips(f.ui(), 20, 0, 0, .{}, &chips);
    try testing.expectEqual(@as(u16, 11), x);
    try f.expectRow(0, "            A  B  C");
    try testing.expectEqual(chip_base + 2, f.hits.at(18, 0).?.button);
    try testing.expectEqual(chip_base + 0, f.hits.at(12, 0).?.button);
    try testing.expect(f.style(15, 0).dim);
    try testing.expectEqual(Color{ .rgb = .{ 0, 255, 0 } }, f.style(15, 0).fg);
    // Only one fits between min_x and the right edge.
    var g = try Fixture.init(20, 1);
    defer g.deinit();
    const x2 = drawChips(g.ui(), 20, 0, 16, .{}, &chips);
    try testing.expectEqual(@as(u16, 17), x2);
    try g.expectRow(0, "                  C");
}
