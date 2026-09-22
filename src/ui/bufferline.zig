//! Bufferline — a leaf's tab strip, the row the Rust editor paints above
//! every leaf (`paint_leaf_tab_strip`), cell for cell:
//!
//! ```text
//!  main.rs 󰅖   󰹾 diff: worktree 󰅖   󰐕            󰅁  󰅂
//! ```
//!
//! A chip is ` glyph name badge ` — one cell, the file's devicon in its
//! colour, one cell, the name (cut to `name_cap` cells with `…`), one
//! cell, the badge, one cell. The badge is the close `󰅖` (red on the
//! active chip, grey on the rest, brighter under the pointer), the pin
//! `` on a pinned tab, or `●` on an unsaved one (the pointer turns it
//! back into `×` so one click still closes). A Request pane has no
//! glyph; its method sits in a solid pill before the name. An LSP count
//! (`✗3` / `⚠2`) goes between the name and the badge. The active chip
//! is on the editor's ground in the bold foreground; the others on the
//! strip's ground, dim. Chips sit one cell apart; the ` 󰐕 ` follows the
//! last one on the editor's ground.
//!
//! The right end, from the edge inward: the four split buttons (a
//! shell, split right, split down, maximize — each ` glyph `), before
//! them the AI chips that are enabled (dropped one by one on a strip
//! short of room), before those the markdown mode chip, and before that
//! the ` 󰅁  󰅂 ` pair whenever the leaf holds two or more tabs — lit and
//! registered only when there is something to scroll to, painted dim
//! otherwise so the strip does not reflow at either end.
//!
//! The strip is a window: `Opts.first` is the scroll offset (the caller
//! keeps it on the leaf, the wheel and the chevrons move it). `draw`
//! clamps it to the smallest offset whose tail still fills the strip,
//! so a stale offset never strands tabs off the left edge. Every chip
//! registers `.tab{leaf, idx}` as it paints; its last two cells
//! `.tab_close` on top when the badge was drawn and the tab is not
//! pinned. The hits carry the leaf's tab index, never the painted
//! position.
//!
//! The chrome row's right cluster (`drawCluster`) lives here too — it
//! shares the `+` / `×` glyphs.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const brand = @import("brand.zig");
const ids = @import("../core/ids.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;

pub const PaneId = ids.PaneId;

pub const Severity = enum { none, warning, err };

pub const Tab = struct {
    id: PaneId,
    /// The name shown; for a Request pane the part after the method.
    title: []const u8,
    /// The icon before the name; empty skips the slot (Rust's
    /// `skip_icon`: a Request pane's method pill is its identity).
    glyph: []const u8 = "",
    icon_color: Color = .default,
    /// A Request pane's method — painted as a pill on `icon_color`.
    verb: ?[]const u8 = null,
    active: bool = false,
    dirty: bool = false,
    pinned: bool = false,
    /// Italic name: a preview tab.
    preview: bool = false,
    /// `✗3` / `⚠2` / `●` from the diagnostics, or empty.
    diag: []const u8 = "",
    diag_severity: Severity = .none,
};

/// The markdown mode chip left of the split buttons: `  Preview ` on
/// a markdown editor (purple), ` ✏ Edit ` on a preview (blue).
pub const ModeChip = struct {
    label: []const u8,
    button: u32,
    kind: enum { edit_md, preview_md, view_zon, source_zon },
};

/// One AI mark on the tab bar's right-hand cluster. The colour comes
/// from the caller because it is the product's brand, not the theme's
/// accent — Claude's mark is Anthropic's orange whatever theme mnml is
/// wearing.
///
/// One colour, always. The mark used to pale while no session ran, so
/// the chip carried two jobs: a button, and a running light. Its four
/// neighbours in the cluster are buttons that look the same whatever
/// the state behind them, and this one reading dimmer than the rest
/// said "disabled" rather than "idle". Whether a session is live is
/// the sessions panel's to show, and the statusline's.
pub const AiChip = struct {
    id: u32,
    glyph: []const u8,
    fallback: []const u8,
    fg: Color,
};

/// The split cluster's `.button` ids; `ai` paints before the four.
/// The cluster's ids. `max` is null on the empty layout — Rust paints
/// three buttons there, the maximize one only once a pane is open.
pub const SplitIds = struct {
    term: u32,
    right: u32,
    down: u32,
    max: ?u32,
    ai: []const AiChip = &.{},
    /// The terminal chip's mark, per `ui.terminal_glyph` — the caller
    /// resolves it (`app/terminal_glyph.zig`), because the config does
    /// not reach this layer.
    term_mark: Terminal = terminal_ghost,
};

pub const Opts = struct {
    /// What the `.tab` hits carry as their leaf.
    leaf: u32 = 0,
    /// Paint ` 󰐕 ` after the last tab and register it as this `.button`.
    new_tab: ?u32 = null,
    /// The scroll offset — the first tab painted. Clamped by `draw`.
    first: usize = 0,
    /// The `.button` ids the chevrons register when they can scroll.
    scroll_left: ?u32 = null,
    scroll_right: ?u32 = null,
    split: ?SplitIds = null,
    mode_chip: ?ModeChip = null,
    /// Tabs the caller kept off the strip; they count into ` +N hidden `.
    hidden_extra: usize = 0,
    /// The `.button` the ` +N hidden ` chip registers (a buffer picker).
    hidden_button: ?u32 = null,
    /// The leaf is zoomed: the maximize button shows the restore glyph.
    zoomed: bool = false,
};

/// What `draw` painted: the offset it settled on, how many chips it
/// painted, and how many tabs sit outside the window on each side.
pub const Window = struct { first: usize = 0, painted: usize = 0, hidden_left: usize = 0, hidden_right: usize = 0 };

/// The tab positions a caller needs to route a drop: the `x` each chip
/// starts at and its width, in strip order from the offset.
pub const Slot = struct { idx: usize, x: u16, w: u16 };

/// The most cells a name takes before it is cut.
pub const name_cap: u16 = 18;
/// ` 󰐕 `.
pub const plus_w: u16 = 3;
/// ` 󰅁 ` — one chevron slot.
pub const arrow_w: u16 = 3;
/// One split button.
pub const split_button_w: u16 = 3;
/// The four split buttons.
pub const split_buttons_w: u16 = 4 * split_button_w;

// The glyphs, each with its `--ascii` twin.
/// nf-md-plus — the strip's `+` and the chrome row's; nf-md-close their `×`.
pub const plus_glyph = "\u{F0415}";
pub const plus_ascii = "+";
pub const close_glyph = "\u{F0156}";
pub const close_ascii = "x";
/// nf-fa-thumb_tack.
pub const pin_glyph = "\u{F08D}";
pub const pin_ascii = "P";
/// nf-md-chevron_left / nf-md-chevron_right.
pub const arrow_left_glyph = "\u{F0141}";
pub const arrow_left_ascii = "<";
pub const arrow_right_glyph = "\u{F0142}";
pub const arrow_right_ascii = ">";
/// codicon terminal / split-horizontal / split-vertical.
pub const term_glyph = "\u{EA85}";
pub const term_ascii = "$";
/// Ghostty's ghost, in mnml's own block — the mark a terminal wears by
/// default, whichever emulator mnml is running inside
/// (`app/terminal_glyph.zig`; `src/glyph/builder.zig` bakes it).
pub const ghost_glyph = "\u{F2000}";
pub const ghost_ascii = "$";
pub const split_right_glyph = "\u{EB56}";
pub const split_right_ascii = "|";
pub const split_down_glyph = "\u{EB57}";
pub const split_down_ascii = "-";
/// nf-fa-expand / nf-fa-compress.
pub const maximize_glyph = "\u{F065}";
pub const maximize_ascii = "[";
pub const restore_glyph = "\u{F066}";
pub const restore_ascii = "]";
pub const dirty_dot = "\u{25CF}";

// ─── the marks a pty tab wears ──────────────────────────────────────────

/// The AI products' own marks — mnml's glyphs in its private block, the
/// codepoints the Rust editor pins on the `claude_code` / `codex` rows
/// (`config.rs`, which rewrites any other value on load). A pane
/// running one of them wears its mark in the pane's accent; the ai
/// usage pane wears the same pair.
pub const claude_glyph = "\u{F1E00}";
pub const claude_ascii = "\u{2733}";
pub const codex_glyph = "\u{F1E01}";
pub const codex_ascii = "\u{25C8}";

/// Anthropic's spark — the mark Claude Code wore before the Claude Code
/// figure took `claude_glyph`'s codepoint. mnml bakes it one along, at
/// `U+F1E02`; the glyph track owns the art and the bake.
pub const spark_cp: u21 = 0xF1E02;
pub const spark_glyph = "\u{F1E02}";
/// The figure keeps the `✳` twin it has always shipped with; the
/// spark's is the plain asterisk, so the two are still tellable apart
/// with no Nerd Font at all.
pub const spark_ascii = "*";

/// A mark as the chrome paints it: the glyph and its `--ascii` twin.
/// Everything that draws a branded mark takes one of these from a
/// resolver rather than naming a codepoint, so a change of mark lands
/// on every surface at once.
pub const Mark = struct { glyph: []const u8, fallback: []const u8 };

/// Which mark Claude Code wears — `ui.claude_mark`. Two choices and no
/// picker: the product's own figure, or the Anthropic spark.
pub const ClaudeMark = enum { figure, spark };

/// The ONE answer to "which mark is Claude's right now". The app side
/// reads the config and calls this (`app/claude_mark.zig`); no painter
/// names `claude_glyph` itself.
pub fn claudeMark(which: ClaudeMark) Mark {
    return switch (which) {
        .figure => .{ .glyph = claude_glyph, .fallback = claude_ascii },
        .spark => .{ .glyph = spark_glyph, .fallback = spark_ascii },
    };
}

/// A terminal as the chrome shows it: the name a shell pane's tab goes
/// by, and the mark it wears.
///
/// There used to be a mark per emulator — Nerd Fonts has no brand glyph
/// for any of them, so each took the nearest thing the catalog had: a
/// ghost for Ghostty, a cat for kitty, an apple for Terminal.app. Four
/// icons for one idea, none of them the product's actual logo, and the
/// one a user saw depended on which terminal they happened to launch
/// mnml from. mnml bakes the real Ghostty mark now (`ghost_glyph`), and
/// paints that one whatever it is running inside; `ui.terminal_glyph =
/// .terminal` asks for the plain codicon instead, and that is the whole
/// of the choice (`app/terminal_glyph.zig`). Only the NAME still comes
/// from the environment — a shell tab reads `ghostty (zsh)`.
pub const Terminal = struct {
    label: []const u8,
    glyph: []const u8,
    fallback: []const u8,
};

/// The shipped mark: mnml's own ghost, no emulator named.
pub const terminal_ghost: Terminal = .{ .label = "terminal", .glyph = ghost_glyph, .fallback = ghost_ascii };
/// `ui.terminal_glyph = .terminal`: the codicon, everywhere.
pub const terminal_generic: Terminal = .{ .label = "terminal", .glyph = term_glyph, .fallback = term_ascii };

/// Which mark a terminal wears — `ui.terminal_glyph`, whose type this
/// is (`config/Config.zig` aliases it, so there is one definition).
/// `.custom` is the user's own SVG baked at the ghost's codepoint, so
/// it resolves to the same string: which art is behind it is the
/// font's business, not the chrome's.
pub const TerminalMark = enum { ghostty, terminal, custom };

/// The ONE answer to "which mark is a terminal's right now", the twin
/// of `claudeMark`. The app side adds the emulator's NAME to it
/// (`app/terminal_glyph.zig`).
pub fn terminalMark(which: TerminalMark) Terminal {
    return switch (which) {
        .ghostty, .custom => terminal_ghost,
        .terminal => terminal_generic,
    };
}

/// `$TERM_PROGRAM` as each terminal spells it, and the name mnml shows
/// for it, in the order a lookup walks (the first match wins; the
/// compare ignores case).
const terminal_names = [_]struct { program: []const u8, name: []const u8 }{
    .{ .program = "ghostty", .name = "ghostty" },
    .{ .program = "kitty", .name = "kitty" },
    .{ .program = "WezTerm", .name = "WezTerm" },
    .{ .program = "iTerm.app", .name = "iTerm" },
    .{ .program = "Apple_Terminal", .name = "Terminal" },
    .{ .program = "WindowsTerminal", .name = "Windows Terminal" },
};

/// The name of the terminal `$TERM_PROGRAM` names. `WT_SESSION` stands
/// in only where `TERM_PROGRAM` says nothing — a Windows Terminal old
/// enough to set neither `TERM_PROGRAM` nor a shell that overrides it.
/// A `TERM_PROGRAM` nobody here knows, and no variable at all, both
/// leave the plain `terminal`.
pub fn terminalName(term_program: ?[]const u8, wt_session: ?[]const u8) []const u8 {
    if (term_program) |tp| if (tp.len > 0) {
        for (&terminal_names) |row| if (std.ascii.eqlIgnoreCase(row.program, tp)) return row.name;
        return terminal_generic.label;
    };
    if (wt_session != null) return "Windows Terminal";
    return terminal_generic.label;
}

// ─── one chip ───────────────────────────────────────────────────────────

/// The name as it will paint: cut to `name_cap`.
fn chipName(ui: Ui, tab: Tab) []const u8 {
    return ui.clipStr(tab.title, name_cap);
}

/// The chip's natural width: ` glyph ` (or one cell without one), the
/// method pill and its gap, the name and a cell, the diagnostics and a
/// cell, the badge and a cell.
pub fn chipWidth(ui: Ui, tab: Tab) u16 {
    const icon: u16 = if (tab.glyph.len == 0) 1 else 2 + ui.width(tab.glyph);
    const verb: u16 = if (tab.verb) |v| ui.width(v) + 3 else 0;
    const diag: u16 = if (tab.diag.len == 0) 0 else ui.width(tab.diag) + 1;
    return icon + verb + ui.width(chipName(ui, tab)) + 1 + diag + 2;
}

const Badge = struct { text: []const u8, fg: Color, closes: bool };

fn badgeOf(ui: Ui, tab: Tab, hovered: bool) Badge {
    const p = ui.theme.palette;
    const close: []const u8 = if (ui.ascii) close_ascii else close_glyph;
    if (tab.pinned) return .{ .text = if (ui.ascii) pin_ascii else pin_glyph, .fg = p.yellow, .closes = false };
    if (tab.active) return .{ .text = close, .fg = p.red, .closes = true };
    if (hovered and tab.dirty) return .{ .text = close, .fg = p.orange, .closes = true };
    if (hovered) return .{ .text = close, .fg = p.grey_fg, .closes = true };
    if (tab.dirty) return .{ .text = dirty_dot, .fg = p.orange, .closes = true };
    return .{ .text = close, .fg = p.grey, .closes = true };
}

/// Paints one chip at `x`, clipped to `avail` cells, and registers its
/// hits. Returns the cells it took.
fn paintChip(ui: Ui, x: u16, y: u16, avail: u16, tab: Tab, leaf: u32, idx: u16) u16 {
    if (avail == 0) return 0;
    const p = ui.theme.palette;
    const natural = chipWidth(ui, tab);
    const w = @min(natural, avail);
    const rect = Rect.init(x, y, w, 1);
    const bg = if (tab.active) p.bg else p.bg_darker;
    const badge = badgeOf(ui, tab, ui.hovered(rect));
    ui.fill(rect, .{ .bg = bg });
    const end = x + w;
    var cx = x;
    if (tab.glyph.len == 0) {
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    } else {
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
        cx += ui.putStr(cx, y, end - cx, tab.glyph, .{ .fg = tab.icon_color, .bg = bg });
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    }
    if (tab.verb) |v| {
        const pill: Style = .{ .fg = bg, .bg = tab.icon_color, .bold = true };
        cx += ui.putStr(cx, y, end - cx, " ", pill);
        cx += ui.putStr(cx, y, end - cx, v, pill);
        cx += ui.putStr(cx, y, end - cx, " ", pill);
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    }
    const name_style: Style = .{ .fg = if (tab.active) p.fg else p.grey_fg, .bg = bg, .bold = tab.active, .italic = tab.preview };
    cx += ui.putStr(cx, y, end - cx, chipName(ui, tab), name_style);
    cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    if (tab.diag.len > 0) {
        const fg = if (tab.diag_severity == .err) p.red else p.yellow;
        cx += ui.putStr(cx, y, end - cx, tab.diag, .{ .fg = fg, .bg = bg });
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    }
    cx += ui.putStr(cx, y, end - cx, badge.text, .{ .fg = badge.fg, .bg = bg });
    _ = ui.putStr(cx, y, end -| cx, " ", .{ .bg = bg });
    ui.hit(rect, .{ .tab = .{ .leaf = leaf, .idx = idx } });
    // The close target only where the badge really painted: a cut chip
    // would put it over the name's last letters.
    if (badge.closes and w >= 2 and natural <= w) ui.hit(Rect.init(end - 2, y, 2, 1), .{ .tab_close = .{ .leaf = leaf, .idx = idx } });
    return w;
}

// ─── the strip ──────────────────────────────────────────────────────────

/// Where the right-end furniture sits for `area`, before any tab is laid.
const Geometry = struct {
    /// Tabs stop here.
    tabs_right: u16,
    arrows_x: u16,
    arrows_w: u16,
    mode_x: u16,
    split_x: u16,
    n_ai: usize,
};

fn geometry(ui: Ui, area: Rect, tabs_len: usize, opts: Opts) Geometry {
    var n_ai: usize = if (opts.split) |s| s.ai.len else 0;
    const base: u16 = if (opts.split) |sp| (if (sp.max != null) split_buttons_w else split_buttons_w - split_button_w) else 0;
    while (n_ai > 0 and area.w < base + @as(u16, @intCast(n_ai)) * split_button_w) n_ai -= 1;
    const split_total = base + @as(u16, @intCast(n_ai)) * split_button_w;
    const mode_w: u16 = if (opts.mode_chip) |m| ui.width(m.label) else 0;
    const right = area.right();
    const tabs_right0 = right -| (split_total + mode_w);
    const arrows_w: u16 = if (tabs_len >= 2) 2 * arrow_w else 0;
    const arrows_x = @max(tabs_right0 -| arrows_w, area.x);
    return .{
        .tabs_right = @max(arrows_x -| plus_w, area.x),
        .arrows_x = arrows_x,
        .arrows_w = arrows_w,
        .mode_x = @max(right -| (split_total + mode_w), area.x),
        .split_x = @max(right -| split_total, area.x),
        .n_ai = n_ai,
    };
}

/// The smallest offset at or below `raw` whose tail still fills `room`
/// cells — chips measured whole, a cell of gap between them.
fn clampScroll(ui: Ui, tabs: []const Tab, room: u16, raw: usize) usize {
    if (tabs.len == 0) return 0;
    const want = @min(raw, tabs.len - 1);
    if (want == 0) return 0;
    var used: u16 = 0;
    var max_scroll = want;
    var i = tabs.len;
    while (i > 0) {
        i -= 1;
        const w = chipWidth(ui, tabs[i]);
        const next = used + w + @as(u16, if (used > 0) 1 else 0);
        if (next > room) break;
        used = next;
        max_scroll = i;
    }
    return @min(want, max_scroll);
}

/// How many chips from `first` paint (whole or cut) in `room` cells.
fn countPainted(ui: Ui, tabs: []const Tab, room: u16, first: usize) usize {
    var x: u16 = 0;
    var n: usize = 0;
    var i = first;
    while (i < tabs.len) : (i += 1) {
        if (x >= room) break;
        x += @min(chipWidth(ui, tabs[i]), room - x) + 1;
        n += 1;
    }
    return n;
}

/// The label the ` +N hidden ` chip would carry for `n` tabs off the
/// strip — one spelling, so the room measured for it and the string
/// painted into that room can never disagree.
fn hiddenLabel(ui: Ui, n: usize) []const u8 {
    return ui.fmt(" +{d} hidden ", .{n});
}

/// Where the chips end: `room` cells from `first`, chips measured whole
/// and cut at the edge, a cell of gap between them. The paint loop's
/// arithmetic, without the paint — so the layout can be decided before
/// a cell is touched.
fn paintedEnd(ui: Ui, tabs: []const Tab, room: u16, first: usize) u16 {
    var x: u16 = 0;
    var i = first;
    while (i < tabs.len) : (i += 1) {
        if (x >= room) break;
        x += @min(chipWidth(ui, tabs[i]), room - x) + 1;
    }
    return x;
}

/// The right edge the chips lay out against.
///
/// Normally the strip's own (`g.tabs_right`): ` +N hidden ` takes the
/// cells left over after the last chip and the `󰐕`, which is where it
/// has always gone, so a strip scrolled to a whole tail is laid out
/// cell for cell as before. When there are none — the ordinary overflow
/// case, the last chip cut at the right edge — the chip is GIVEN its
/// cells instead of going unpainted, because a strip that hides tabs
/// and says nothing about them is the bug. It never takes the `󰐕`'s
/// room: that button has nowhere else to be.
fn stripRight(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts, g: Geometry) u16 {
    const room = g.tabs_right -| area.x;
    const first = clampScroll(ui, tabs, room, opts.first);
    const hidden = first + (tabs.len - first - countPainted(ui, tabs, room, first)) + opts.hidden_extra;
    if (hidden == 0) return g.tabs_right;
    const w = ui.width(hiddenLabel(ui, hidden));
    const plus_slot: u16 = if (opts.new_tab != null) plus_w else 0;
    const end = area.x + paintedEnd(ui, tabs, room, first);
    const after_plus = @min(end, g.arrows_x -| plus_slot) + plus_slot;
    if (after_plus + w <= g.arrows_x) return g.tabs_right;
    return @max(g.tabs_right -| w, area.x);
}

/// The offset to paint from when the active tab changed: `current` when
/// the active tab is already in view, else the active tab itself (the
/// clamp pulls it back so the tail fills the strip).
pub fn fitActive(ui: Ui, area: Rect, tabs: []const Tab, current: usize, opts: Opts) usize {
    if (tabs.len == 0) return 0;
    const g = geometry(ui, area, tabs.len, opts);
    const room = stripRight(ui, area, tabs, opts, g) -| area.x;
    const first = clampScroll(ui, tabs, room, current);
    var active: usize = 0;
    for (tabs, 0..) |tab, i| if (tab.active) {
        active = i;
    };
    if (active >= first and active < first + countPainted(ui, tabs, room, first)) return first;
    return clampScroll(ui, tabs, room, active);
}

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) Window {
    const t = ui.theme;
    const p = t.palette;
    ui.fill(area, t.bufferline);
    if (area.isEmpty()) return .{};
    const y = area.y;
    const g = geometry(ui, area, tabs.len, opts);

    // The tabs from the clamped offset, a cell of strip between chips —
    // against the edge ` +N hidden ` leaves them (`stripRight`).
    const tabs_right = stripRight(ui, area, tabs, opts, g);
    const first = clampScroll(ui, tabs, tabs_right -| area.x, opts.first);
    var x = area.x;
    var painted: usize = 0;
    var i = first;
    while (i < tabs.len) : (i += 1) {
        if (x >= tabs_right) break;
        const w = paintChip(ui, x, y, tabs_right - x, tabs[i], opts.leaf, @intCast(i));
        if (w == 0) break;
        x += w + 1;
        painted += 1;
    }
    const hidden_right = tabs.len - first - painted;

    // The chevrons: lit only with somewhere to go.
    if (g.arrows_w > 0) {
        const pair = [_]struct { glyph: []const u8, ascii: []const u8, on: bool, id: ?u32 }{
            .{ .glyph = arrow_left_glyph, .ascii = arrow_left_ascii, .on = first > 0, .id = opts.scroll_left },
            .{ .glyph = arrow_right_glyph, .ascii = arrow_right_ascii, .on = hidden_right > 0, .id = opts.scroll_right },
        };
        for (pair, 0..) |a, slot| {
            const ax = g.arrows_x + @as(u16, @intCast(slot)) * arrow_w;
            if (ax + arrow_w > area.right()) break;
            const r = Rect.init(ax, y, arrow_w, 1);
            const style: Style = if (a.on) .{ .fg = p.fg, .bg = p.bg2 } else .{ .fg = p.comment, .bg = p.bg_darker, .dim = true };
            ui.fill(r, style);
            _ = ui.putStr(ax + 1, y, 1, if (ui.ascii) a.ascii else a.glyph, style);
            if (a.on) if (a.id) |id| ui.hit(r, .{ .button = id });
        }
    }

    // ` 󰐕 ` after the last chip, in its own slot before the chevrons.
    var after_plus = x;
    if (opts.new_tab) |id| {
        const plus_x = @max(@min(x, g.arrows_x -| plus_w), area.x);
        if (plus_x + plus_w <= g.arrows_x) {
            const r = Rect.init(plus_x, y, plus_w, 1);
            ui.fill(r, .{ .bg = p.bg });
            _ = ui.putStr(plus_x + 1, y, 1, if (ui.ascii) plus_ascii else plus_glyph, .{ .fg = p.green, .bg = p.bg, .bold = true });
            ui.hit(r, .{ .button = id });
            after_plus = plus_x + plus_w;
        }
    }
    // ` +N hidden `: the tabs that are still there — off either edge of
    // the window (Rust's `tabs.len() - painted_count`, which counts the
    // scrolled-off left as well as the right) and the ones the caller
    // kept off the strip.
    //
    // It PAINTS whenever any tab is off the strip. It used to sit after
    // the last chip and only if what was left before the chevrons
    // happened to hold it — which is room only when the strip is
    // scrolled to a tail that fits whole. In the ordinary overflow case
    // the last chip is cut at the right edge, nothing is left, and the
    // one piece of chrome that says tabs are missing never painted.
    // `stripRight` gives it the cells in exactly that case, and leaves
    // the strip alone in the other.
    const hidden_total = first + hidden_right + opts.hidden_extra;
    if (hidden_total > 0) {
        const label = hiddenLabel(ui, hidden_total);
        const w = ui.width(label);
        const cx = @max(@min(after_plus, g.arrows_x -| w), area.x);
        if (cx + w <= g.arrows_x) {
            const r = Rect.init(cx, y, w, 1);
            _ = ui.putStr(cx, y, w, label, .{ .fg = p.comment, .bg = p.bg2 });
            if (opts.hidden_button) |id| ui.hit(r, .{ .button = id });
        }
    }

    if (opts.mode_chip) |m| {
        const w = ui.width(m.label);
        if (g.mode_x + w <= area.right()) {
            const r = Rect.init(g.mode_x, y, w, 1);
            const style: Style = .{ .fg = p.bg_darker, .bg = switch (m.kind) {
                .edit_md, .view_zon => p.purple,
                .preview_md, .source_zon => p.blue,
            }, .bold = true };
            _ = ui.putStr(g.mode_x, y, w, m.label, style);
            ui.hit(r, .{ .button = m.button });
        }
    }

    if (opts.split) |s| drawSplit(ui, g.split_x, y, area.right(), s, g.n_ai, opts.zoomed);

    return .{ .first = first, .painted = painted, .hidden_left = first, .hidden_right = hidden_right };
}

/// The split cluster from `x`: the AI chips, then ` term `, ` right `,
/// ` down `, ` maximize `.
fn drawSplit(ui: Ui, x0: u16, y: u16, right: u16, s: SplitIds, n_ai: usize, zoomed: bool) void {
    const t = ui.theme;
    const p = t.palette;
    const bg = p.bg_darker;
    var x = x0;
    const Btn = struct { glyph: []const u8, ascii: []const u8, fg: Color, id: u32 };
    var buttons: [8]Btn = undefined;
    var n: usize = 0;
    for (s.ai[0..n_ai]) |chip| {
        buttons[n] = .{ .glyph = chip.glyph, .ascii = chip.fallback, .fg = chip.fg, .id = chip.id };
        n += 1;
    }
    buttons[n] = .{ .glyph = s.term_mark.glyph, .ascii = s.term_mark.fallback, .fg = .{ .index = 15 }, .id = s.term };
    buttons[n + 1] = .{ .glyph = split_right_glyph, .ascii = split_right_ascii, .fg = p.comment, .id = s.right };
    buttons[n + 2] = .{ .glyph = split_down_glyph, .ascii = split_down_ascii, .fg = p.comment, .id = s.down };
    n += 3;
    if (s.max) |max_id| {
        buttons[n] = if (zoomed) .{ .glyph = restore_glyph, .ascii = restore_ascii, .fg = p.cyan, .id = max_id } else .{ .glyph = maximize_glyph, .ascii = maximize_ascii, .fg = p.comment, .id = max_id };
        n += 1;
    }
    for (buttons[0..n]) |b| {
        if (x + split_button_w > right) break;
        const r = Rect.init(x, y, split_button_w, 1);
        ui.fill(r, .{ .bg = bg });
        _ = ui.putStr(x + 1, y, 1, if (ui.ascii) b.ascii else b.glyph, .{ .fg = b.fg, .bg = bg });
        ui.hit(r, .{ .button = b.id });
        x += split_button_w;
    }
}

/// Where each chip sits from offset `first` — the drop router asks this
/// to place a dragged tab between two others without repainting. Chips
/// are laid at their natural width; one past the strip's edge is not
/// listed.
pub fn slotsFrom(ui: Ui, area: Rect, tabs: []const Tab, first: usize, out: []Slot) []Slot {
    var n: usize = 0;
    var x = area.x;
    var i = first;
    while (i < tabs.len and n < out.len) : (i += 1) {
        if (x >= area.right()) break;
        const w = chipWidth(ui, tabs[i]);
        out[n] = .{ .idx = i, .x = x, .w = w };
        n += 1;
        x += w + 1;
    }
    return out[0..n];
}

// ─── the chrome row's right cluster ─────────────────────────────────────
//
// Rust's `paint_right_cluster`: ` + ` (a new tab page), then in the
// full mode ` TABS ` and a chip per tab page (`●` when it holds a dirty
// buffer, ` × ` after the active one), a one-cell spacer, the theme
// pill `●━ ` (`━●` on the alternate theme) and the ` × ` that quits.
// The compact mode drops the label and shows the page chips only from
// the second page on. `pickCluster` is Rust's fit rule: the full
// cluster when it clears the workspace chip by `cluster_gap`, else the
// compact one, else nothing.

pub const Cluster = struct {
    /// Tab pages, and which one is showing.
    pages: u16 = 1,
    active: u16 = 0,
    /// Per page, whether a buffer in it is unsaved; a short slice reads false.
    dirty: []const bool = &.{},
    /// The theme pill's state: on the configured alternate theme.
    on_alt: bool = false,
    compact: bool = false,
};

pub const ClusterIds = struct {
    new_tab: u32,
    tabs_label: u32,
    /// Page `i` registers `page_base + i`; its `×` `page_close_base + i`.
    page_base: u32,
    page_close_base: u32,
    theme: u32,
    close: u32,
};

pub const ClusterPref = enum { auto, expanded, compact };
pub const ClusterFit = struct { w: u16, compact: bool };

/// The cells between the workspace chip's right edge and the cluster.
pub const cluster_gap: u16 = 4;

fn digits(n: usize) u16 {
    var d: u16 = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// The cluster's width in cells for `c` (its `compact` decides which).
pub fn clusterWidth(c: Cluster) u16 {
    var w: u16 = 3; // ` + `
    const chips = !c.compact or c.pages >= 2;
    if (!c.compact) w += 6; // ` TABS `
    if (chips) {
        var i: usize = 0;
        while (i < c.pages) : (i += 1) {
            w += 2 + digits(i + 1); // `{marker}{n} `
            if (i == c.active) w += 2; // `× `
        }
    }
    return w + 1 + 3 + 3; // spacer, `●━ `, ` × `
}

/// Which cluster fits at the right of `area` past `palette_right_edge`:
/// the full one, the compact one, or none. `expanded` still falls back
/// to compact when the full one will not fit; `compact` never tries the
/// full one.
pub fn pickCluster(area: Rect, palette_right_edge: u16, c: Cluster, pref: ClusterPref) ?ClusterFit {
    var full = c;
    full.compact = false;
    var compact = c;
    compact.compact = true;
    const full_w = clusterWidth(full);
    const compact_w = clusterWidth(compact);
    const full_fits = area.x + (area.w -| full_w) >= palette_right_edge + cluster_gap;
    const compact_fits = area.x + (area.w -| compact_w) >= palette_right_edge + cluster_gap;
    if (pref != .compact and full_fits) return .{ .w = full_w, .compact = false };
    if (compact_fits) return .{ .w = compact_w, .compact = true };
    return null;
}

/// Paints the cluster from `area.x` on `area.y`, registering each part.
pub fn drawCluster(ui: Ui, area: Rect, c: Cluster, id: ClusterIds) void {
    const t = ui.theme;
    const pal = t.palette;
    const y = area.y;
    var x = area.x;
    const chip_bg = pal.bg2;
    const plus = Rect.init(x, y, 3, 1);
    ui.fill(plus, .{ .fg = pal.fg, .bg = chip_bg });
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) plus_ascii else plus_glyph, .{ .fg = pal.fg, .bg = chip_bg });
    ui.hit(plus, .{ .button = id.new_tab });
    x += 3;
    const chips = !c.compact or c.pages >= 2;
    if (!c.compact) {
        const r = Rect.init(x, y, 6, 1);
        _ = ui.putStr(x, y, 6, " TABS ", .{ .fg = pal.bg_darker, .bg = pal.fg, .bold = true });
        ui.hit(r, .{ .button = id.tabs_label });
        x += 6;
    }
    if (chips) {
        var i: usize = 0;
        while (i < c.pages) : (i += 1) {
            const active = i == c.active;
            const dirty = i < c.dirty.len and c.dirty[i];
            const style: Style = if (active) .{ .fg = pal.bg_darker, .bg = pal.blue, .bold = true } else .{ .fg = pal.fg, .bg = chip_bg };
            const label = ui.fmt("{s}{d} ", .{ @as([]const u8, if (dirty) dirty_dot else " "), i + 1 });
            const w = ui.width(label);
            const r = Rect.init(x, y, w, 1);
            ui.fill(r, style);
            _ = ui.putStr(x, y, w, label, style);
            ui.hit(r, .{ .button = id.page_base + @as(u32, @intCast(i)) });
            x += w;
            if (active) {
                const cr = Rect.init(x, y, 2, 1);
                ui.fill(cr, style);
                _ = ui.putStr(x, y, 1, if (ui.ascii) close_ascii else close_glyph, style);
                ui.hit(cr, .{ .button = id.page_close_base + @as(u32, @intCast(i)) });
                x += 2;
            }
        }
    }
    // The spacer paints in the chips' colour so it does not read as a
    // hole punched between two strips.
    ui.fill(Rect.init(x, y, 1, 1), .{ .bg = chip_bg });
    x += 1;
    const pill = Rect.init(x, y, 3, 1);
    ui.fill(pill, .{ .bg = chip_bg });
    const dot: Style = .{ .fg = pal.fg, .bg = chip_bg };
    const bar: Style = .{ .fg = pal.comment, .bg = chip_bg };
    if (c.on_alt) {
        _ = ui.putStr(x, y, 1, "\u{2501}", bar); // chrome-audit: allow — the theme pill's bar is a glyph, not a rule
        _ = ui.putStr(x + 1, y, 1, dirty_dot, dot);
    } else {
        _ = ui.putStr(x, y, 1, dirty_dot, dot);
        _ = ui.putStr(x + 1, y, 1, "\u{2501}", bar); // chrome-audit: allow — as above
    }
    ui.hit(pill, .{ .button = id.theme });
    x += 3;
    const close = Rect.init(x, y, 3, 1);
    const close_style: Style = .{ .fg = pal.bg_darker, .bg = pal.red, .bold = true };
    ui.fill(close, close_style);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) close_ascii else close_glyph, close_style);
    ui.hit(close, .{ .button = id.close });
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const split_ids: SplitIds = .{ .term = 1, .right = 2, .down = 3, .max = 4 };

// The pane glyphs the spec rows carry — the painter takes them from the
// caller (`render.paneIcon`); each with the `--ascii` twin that side paints.
const rust_glyph = "\u{E68B}";
const rust_ascii = "R";
const diff_glyph = "\u{F0E7E}";
const diff_ascii = "\u{B1}";
const preview_glyph = "\u{F06E}";
const preview_ascii = "p";

fn hasButton(f: *Fixture, id: u32) bool {
    for (f.hits.items.items) |h| if (h.target == .button and h.target.button == id) return true;
    return false;
}

fn hasTab(f: *Fixture, idx: u16) bool {
    for (f.hits.items.items) |h| if (h.target == .tab and h.target.tab.idx == idx) return true;
    return false;
}

/// The four split buttons, ` glyph ` each. The terminal chip wears the
/// shipped mark — mnml's ghost, where the Rust screen had the codicon.
const split_cluster = " " ++ ghost_glyph ++ "  " ++ split_right_glyph ++ "  " ++ split_down_glyph ++ "  " ++ maximize_glyph ++ " ";
/// The strip columns of `docs/ui-spec/rust-editor-120x40.txt` row 1
/// (31..120): one rust file, the `+`, the split cluster.
const spec_editor_strip = " " ++ rust_glyph ++ " main.rs " ++ close_glyph ++ "   " ++ plus_glyph ++ " " ** 61 ++ split_cluster;
/// `rust-diff-120x40.txt` row 1: two tabs, the `+`, the chevrons.
const spec_diff_strip = " " ++ rust_glyph ++ " main.rs " ++ close_glyph ++ "   " ++ diff_glyph ++ " diff: worktree " ++ close_glyph ++ "   " ++ plus_glyph ++ " " ** 34 ++ " " ++ arrow_left_glyph ++ "  " ++ arrow_right_glyph ++ " " ++ split_cluster;
/// `rust-request-120x40.txt` row 1: the method pill, no glyph.
const spec_request_strip = "  GET  httpbin.org/get " ++ close_glyph ++ "   " ++ plus_glyph;

test "one file tab is the Rust editor spec's strip, cell for cell, with its hits" {
    var f = try Fixture.init(89, 1);
    defer f.deinit();
    const tabs = [_]Tab{.{ .id = 7, .title = "main.rs", .glyph = rust_glyph, .active = true }};
    const w = draw(f.ui(), f.full(), &tabs, .{ .leaf = 2, .new_tab = 77, .split = split_ids });
    try f.expectRow(0, std.mem.trimEnd(u8, spec_editor_strip, " "));
    try testing.expectEqual(@as(usize, 1), w.painted);
    // The chip, its close, the +, the four buttons.
    try testing.expectEqual(@as(u32, 2), f.hits.at(4, 0).?.tab.leaf);
    try testing.expectEqual(@as(u16, 0), f.hits.at(1, 0).?.tab.idx);
    try testing.expect(f.hits.at(11, 0).? == .tab_close);
    try testing.expect(f.hits.at(12, 0).? == .tab_close);
    try testing.expect(f.hits.at(13, 0) == null);
    try testing.expectEqual(@as(u32, 77), f.hits.at(15, 0).?.button);
    try testing.expectEqual(@as(u32, 1), f.hits.at(78, 0).?.button);
    try testing.expectEqual(@as(u32, 2), f.hits.at(81, 0).?.button);
    try testing.expectEqual(@as(u32, 3), f.hits.at(84, 0).?.button);
    try testing.expectEqual(@as(u32, 4), f.hits.at(87, 0).?.button);
    // The active chip is on the editor's ground, bold; the + is green.
    try testing.expect(f.bgEql(4, 0, .{ .bg = f.theme.palette.bg }));
    try testing.expect(f.style(4, 0).bold);
    try testing.expect(f.fgEql(15, 0, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(11, 0, .{ .fg = f.theme.palette.red }));
    // The gap is strip.
    try testing.expect(f.bgEql(13, 0, f.theme.bufferline));
}

test "two tabs bring the chevrons: the diff spec's strip; dim and inert with nothing to scroll" {
    var f = try Fixture.init(89, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 7, .title = "main.rs", .glyph = rust_glyph },
        .{ .id = 8, .title = "diff: worktree", .glyph = diff_glyph, .active = true },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .split = split_ids });
    try f.expectRow(0, std.mem.trimEnd(u8, spec_diff_strip, " "));
    try testing.expect(!hasButton(&f, 70));
    try testing.expect(!hasButton(&f, 71));
    try testing.expect(f.style(72, 0).dim);
    // The inactive chip's badge is the grey close glyph, and it closes.
    try testing.expect(f.fgEql(11, 0, .{ .fg = f.theme.palette.grey }));
    try testing.expectEqual(@as(u16, 0), f.hits.at(12, 0).?.tab_close.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(33, 0).?.tab_close.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(20, 0).?.tab.idx);
}

test "a request tab has no glyph and a method pill; a dirty tab a dot the pointer turns into ×; a pinned tab never closes" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const req = [_]Tab{.{ .id = 1, .title = "httpbin.org/get", .verb = "GET", .icon_color = f.theme.palette.green, .active = true }};
    _ = draw(f.ui(), f.full(), &req, .{ .new_tab = 9 });
    try f.expectRow(0, spec_request_strip);
    try testing.expect(f.bgEql(3, 0, .{ .bg = f.theme.palette.green }));
    try testing.expectEqual(@as(u32, 9), f.hits.at(27, 0).?.button);

    // Two tabs: the chevron pair sits at the right end, dim.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .glyph = "x", .dirty = true },
        .{ .id = 2, .title = "b.txt", .glyph = "x", .pinned = true, .active = true },
    };
    const chevrons = " " ** 13 ++ arrow_left_glyph ++ "  " ++ arrow_right_glyph;
    _ = draw(g.ui(), g.full(), &tabs, .{});
    try g.expectRow(0, " x a.txt " ++ dirty_dot ++ "   x b.txt " ++ pin_glyph ++ chevrons);
    try testing.expect(g.fgEql(9, 0, .{ .fg = g.theme.palette.orange }));
    try testing.expect(g.hits.at(10, 0).? == .tab_close);
    try testing.expect(g.hits.at(22, 0).? == .tab);
    // The pointer over the dirty chip: the × in orange.
    var ui = g.ui();
    ui.hover = .{ .x = 4, .y = 0 };
    _ = draw(ui, g.full(), &tabs, .{});
    try g.expectRow(0, " x a.txt " ++ close_glyph ++ "   x b.txt " ++ pin_glyph ++ chevrons);
    try testing.expect(g.fgEql(9, 0, .{ .fg = g.theme.palette.orange }));
    // ASCII twins, with the + and the split cluster.
    var h = try Fixture.init(60, 1);
    defer h.deinit();
    h.ascii = true;
    _ = draw(h.ui(), h.full(), &tabs, .{ .new_tab = 9, .split = split_ids });
    try h.expectRow(0, " x a.txt " ++ dirty_dot ++ "   x b.txt " ++ pin_ascii ++ "   " ++ plus_ascii ++ " " ** 17 ++ arrow_left_ascii ++ "  " ++ arrow_right_ascii ++ "  " ++ term_ascii ++ "  " ++ split_right_ascii ++ "  " ++ split_down_ascii ++ "  " ++ maximize_ascii);
    try testing.expectEqual(@as(u32, 9), h.hits.at(25, 0).?.button);
}

test "a long name is cut to name_cap; a chip cut by the edge keeps its tab hit and loses its close" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{.{ .id = 1, .title = "a_very_long_file_name_indeed.txt", .glyph = "x", .active = true }};
    _ = draw(f.ui(), f.full(), &tabs, .{});
    // Seventeen characters and the ellipsis: eighteen cells, as Rust's `clip_to_cells`.
    try f.expectRow(0, " x a_very_long_file_… " ++ close_glyph);
    // Eight cells: the `+` slot is reserved even with no `+` to paint
    // (Rust carves it before the tabs), so five are left for the chip.
    var g = try Fixture.init(8, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &tabs, .{});
    try g.expectRow(0, " x a_");
    try testing.expect(g.hits.at(4, 0).? == .tab);
    try testing.expect(g.hits.at(5, 0) == null);
    for (g.hits.items.items) |h| try testing.expect(h.target != .tab_close);
}

test "an overflowing strip: the offset clamps to what fills it, the chevrons light with their buttons, the + stays" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "one.txt", .glyph = "x" },
        .{ .id = 2, .title = "two.txt", .glyph = "x" },
        .{ .id = 3, .title = "three.txt", .glyph = "x" },
        .{ .id = 4, .title = "four.txt", .glyph = "x" },
        .{ .id = 5, .title = "five.txt", .glyph = "x", .active = true },
    };
    const opts: Opts = .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71 };
    // From the start: three tabs are off the strip, so ` +3 hidden ` is
    // GIVEN its cells (`stripRight`) and what is left holds one chip
    // whole and six cells of the next; the + keeps its reserved slot.
    // The chip costs a tab of window — the trade it exists to make.
    const w0 = draw(f.ui(), f.full(), &tabs, opts);
    try f.expectRow(0, " x one.txt " ++ close_glyph ++ "   x two  " ++ plus_glyph ++ " +3 hidden  " ++ arrow_left_glyph ++ "  " ++ arrow_right_glyph);
    try testing.expectEqual(@as(usize, 0), w0.first);
    try testing.expectEqual(@as(usize, 2), w0.painted);
    try testing.expectEqual(@as(usize, 3), w0.hidden_right);
    try testing.expect(!hasButton(&f, 70));
    try testing.expectEqual(@as(u32, 71), f.hits.at(38, 0).?.button);
    try testing.expectEqual(@as(u32, 77), f.hits.at(22, 0).?.button);
    // The cut second chip keeps its tab hit and has no close.
    try testing.expectEqual(@as(u16, 1), f.hits.at(18, 0).?.tab.idx);
    try testing.expect(f.hits.at(19, 0).? == .tab);
    // The active tab is last: fitActive jumps to it and the clamp pulls
    // back to the offset whose tail fills the strip — which is the last
    // tab alone, once the chip has taken its cells.
    const first = fitActive(f.ui(), f.full(), &tabs, 0, opts);
    try testing.expectEqual(@as(usize, 4), first);
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const w1 = draw(g.ui(), g.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .first = first });
    try testing.expectEqual(@as(usize, 4), w1.hidden_left);
    try testing.expectEqual(@as(usize, 0), w1.hidden_right);
    try g.expectContains(" x five.txt " ++ close_glyph ++ "   " ++ plus_glyph ++ "  +4 hidden ");
    try testing.expectEqual(@as(u32, 70), g.hits.at(35, 0).?.button);
    try testing.expect(!hasButton(&g, 71));
    try testing.expect(hasTab(&g, 4));
    // A stale offset past that is pulled back; the active tab already in
    // view keeps the offset.
    try testing.expectEqual(@as(usize, 4), draw(g.ui(), g.full(), &tabs, .{ .new_tab = 77, .first = 4 }).first);
    try testing.expectEqual(@as(usize, 4), fitActive(g.ui(), g.full(), &tabs, 4, opts));
    // Everything fits: the chevrons stay, dim.
    var k = try Fixture.init(90, 1);
    defer k.deinit();
    const w3 = draw(k.ui(), k.full(), &tabs, opts);
    try testing.expectEqual(@as(usize, 0), w3.hidden_right);
    try testing.expect(!hasButton(&k, 70) and !hasButton(&k, 71));
    try k.expectContains(arrow_left_glyph ++ "  " ++ arrow_right_glyph);
    // No tabs: the + alone at the left.
    var e = try Fixture.init(20, 1);
    defer e.deinit();
    _ = draw(e.ui(), e.full(), &.{}, .{ .new_tab = 1 });
    try e.expectRow(0, " " ++ plus_glyph);
    _ = draw(e.ui(), Rect.empty, &.{}, .{ .new_tab = 1 });
}

test "the hidden chip counts the tabs scrolled off the left edge too, and clicks through to its button" {
    // Five tabs, the strip scrolled to its tail: 66 cells hold the last
    // three chips whole (the clamp pulls a stale offset back to them),
    // two sit off the left edge and the chip says so where Rust's does —
    // after the `+`.
    var f = try Fixture.init(66, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "one.txt", .glyph = "x" },
        .{ .id = 2, .title = "two.txt", .glyph = "x" },
        .{ .id = 3, .title = "three.txt", .glyph = "x" },
        .{ .id = 4, .title = "four.txt", .glyph = "x" },
        .{ .id = 5, .title = "five.txt", .glyph = "x", .active = true },
    };
    const w = draw(f.ui(), f.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .hidden_button = 8, .first = 3 });
    try testing.expectEqual(@as(usize, 2), w.first);
    try testing.expectEqual(@as(usize, 2), w.hidden_left);
    try testing.expectEqual(@as(usize, 0), w.hidden_right);
    try f.expectContains(plus_glyph ++ "  +2 hidden ");
    try testing.expectEqual(@as(u32, 8), f.hits.at(50, 0).?.button);
    // The filtered-out tabs add to the same count.
    var g = try Fixture.init(66, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &tabs, .{ .new_tab = 77, .hidden_button = 8, .hidden_extra = 2, .first = 3 });
    try g.expectContains(" +4 hidden ");
    // Nothing hidden: no chip.
    var k = try Fixture.init(90, 1);
    defer k.deinit();
    _ = draw(k.ui(), k.full(), &tabs, .{ .new_tab = 77, .hidden_button = 8 });
    try testing.expect(!hasButton(&k, 8));
}

test "the hidden chip counts the filtered tabs; the mode chip sits before the cluster; AI chips drop first" {
    var f = try Fixture.init(56, 1);
    defer f.deinit();
    const tabs = [_]Tab{.{ .id = 1, .title = "a.md", .glyph = "x", .active = true }};
    const claude_fg = brand.claude;
    const codex_fg = Theme.rgb(0x56b6c2);
    const ai = [_]AiChip{
        .{ .id = 40, .glyph = "\u{2733}", .fallback = "*", .fg = claude_fg },
        .{ .id = 41, .glyph = "\u{276F}", .fallback = ">", .fg = codex_fg },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{
        .new_tab = 9,
        .hidden_extra = 3,
        .hidden_button = 8,
        .mode_chip = .{ .label = " " ++ preview_glyph ++ " Preview ", .button = 5, .kind = .edit_md },
        .split = .{ .term = 1, .right = 2, .down = 3, .max = 4, .ai = &ai },
    });
    try f.expectRow(0, std.mem.trimEnd(u8, " x a.md " ++ close_glyph ++ "   " ++ plus_glyph ++ "  +3 hidden    " ++ preview_glyph ++ " Preview  ✳  ❯ " ++ split_cluster, " "));
    try testing.expectEqual(@as(u32, 8), f.hits.at(15, 0).?.button);
    try testing.expectEqual(@as(u32, 5), f.hits.at(30, 0).?.button);
    try testing.expect(f.bgEql(30, 0, .{ .bg = f.theme.palette.purple }));
    try testing.expectEqual(@as(u32, 40), f.hits.at(39, 0).?.button);
    try testing.expectEqual(@as(u32, 41), f.hits.at(42, 0).?.button);
    // The marks wear their product's brand, never the theme's accent,
    // and they wear it whatever is or is not running behind them — the
    // chip is a button like its four neighbours, not a running light.
    const claude_x = f.hits.entryAt(39, 0).?.rect.x + 1;
    const codex_x = f.hits.entryAt(42, 0).?.rect.x + 1;
    try testing.expectEqual(claude_fg, f.style(claude_x, 0).fg);
    try testing.expectEqual(codex_fg, f.style(codex_x, 0).fg);
    try testing.expect(!std.meta.eql(f.style(claude_x, 0).fg, f.theme.accent.fg));
    try testing.expectEqual(@as(u32, 4), f.hits.at(54, 0).?.button);
    // Short of room, the AI chips go before the four.
    var g = try Fixture.init(15, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &.{}, .{ .split = .{ .term = 1, .right = 2, .down = 3, .max = 4, .ai = &ai } });
    try g.expectRow(0, std.mem.trimEnd(u8, " ✳ " ++ split_cluster, " "));
    var h = try Fixture.init(12, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), &.{}, .{ .split = .{ .term = 1, .right = 2, .down = 3, .max = 4, .ai = &ai }, .zoomed = true });
    try h.expectRow(0, " " ++ ghost_glyph ++ "  " ++ split_right_glyph ++ "  " ++ split_down_glyph ++ "  " ++ restore_glyph);
    try testing.expect(h.fgEql(10, 0, .{ .fg = h.theme.palette.cyan }));
    // The ASCII twins of the test glyphs are spelled beside them.
    try testing.expect(rust_ascii.len + diff_ascii.len + preview_ascii.len > 0);
}

test "the name a terminal goes by, per `$TERM_PROGRAM` and `WT_SESSION`; the mark is mnml's own either way, and both marks have an `--ascii` twin" {
    try testing.expectEqualStrings("ghostty", terminalName("ghostty", null));
    try testing.expectEqualStrings("kitty", terminalName("kitty", null));
    try testing.expectEqualStrings("WezTerm", terminalName("WezTerm", null));
    try testing.expectEqualStrings("iTerm", terminalName("iTerm.app", null));
    try testing.expectEqualStrings("Terminal", terminalName("Apple_Terminal", null));
    try testing.expectEqualStrings("Windows Terminal", terminalName("WindowsTerminal", null));
    // The compare ignores case, as the variable's spelling drifts.
    try testing.expectEqualStrings("ghostty", terminalName("Ghostty", null));
    try testing.expectEqualStrings("WezTerm", terminalName("wezterm", null));
    // Nothing known, and nothing at all: the plain name.
    try testing.expectEqualStrings("terminal", terminalName("Hyper", null));
    try testing.expectEqualStrings("terminal", terminalName(null, null));
    // Windows Terminal is the one that answers on a second variable —
    // but only where `TERM_PROGRAM` says nothing at all.
    try testing.expectEqualStrings("Windows Terminal", terminalName(null, "abc-123"));
    try testing.expectEqualStrings("Windows Terminal", terminalName("", "abc-123"));
    try testing.expectEqualStrings("terminal", terminalName("Hyper", "abc-123"));
    // Two marks, not six: mnml's own and the codicon, each with a twin.
    // The emulator no longer picks one — that is what the per-terminal
    // table did, and what made the mark depend on where mnml was
    // launched from.
    try testing.expectEqualStrings(ghost_glyph, terminal_ghost.glyph);
    try testing.expectEqualStrings(term_glyph, terminal_generic.glyph);
    try testing.expect(!std.mem.eql(u8, terminal_ghost.glyph, terminal_generic.glyph));
    try testing.expectEqualStrings(ghost_ascii, terminal_ghost.fallback);
    try testing.expectEqualStrings(term_ascii, terminal_generic.fallback);
    try testing.expect(claude_ascii.len > 0 and codex_ascii.len > 0);
    try testing.expect(!std.mem.eql(u8, claude_glyph, codex_glyph));
}

test "slots follow the painted order at natural widths" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .glyph = "x" },
        .{ .id = 2, .title = "b.txt", .glyph = "x", .active = true },
        .{ .id = 3, .title = "c.txt", .glyph = "x" },
    };
    var buf: [8]Slot = undefined;
    const sl = slotsFrom(f.ui(), f.full(), &tabs, 0, &buf);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(u16, 0), sl[0].x);
    try testing.expectEqual(@as(u16, 11), sl[0].w);
    try testing.expectEqual(@as(u16, 12), sl[1].x);
    try testing.expectEqual(@as(usize, 2), sl[2].idx);
    const from1 = slotsFrom(f.ui(), f.full(), &tabs, 1, &buf);
    try testing.expectEqual(@as(usize, 2), from1.len);
    try testing.expectEqual(@as(usize, 1), from1[0].idx);
}

const cluster_ids: ClusterIds = .{ .new_tab = 10, .tabs_label = 11, .page_base = 0x40, .page_close_base = 0x60, .theme = 12, .close = 13 };

test "the right cluster: compact is Rust's `+ ●━ ×` on one page, full adds TABS and the page chips; widths match the paint; every part is a hit" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    const one: Cluster = .{ .compact = true };
    try testing.expectEqual(@as(u16, 10), clusterWidth(one));
    drawCluster(f.ui(), Rect.init(10, 0, 10, 1), one, cluster_ids);
    try f.expectRow(0, "           " ++ plus_glyph ++ "  ●━  " ++ close_glyph);
    try testing.expectEqual(@as(u32, 10), f.hits.at(11, 0).?.button);
    try testing.expectEqual(@as(u32, 12), f.hits.at(15, 0).?.button);
    try testing.expectEqual(@as(u32, 13), f.hits.at(18, 0).?.button);
    try testing.expect(f.bgEql(18, 0, .{ .bg = f.theme.palette.red }));
    // Full, two pages, the second active and dirty.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const two: Cluster = .{ .pages = 2, .active = 1, .dirty = &.{ false, true }, .on_alt = true };
    const w = clusterWidth(two);
    try testing.expectEqual(@as(u16, 3 + 6 + 3 + 3 + 2 + 1 + 3 + 3), w);
    drawCluster(g.ui(), Rect.init(0, 0, w, 1), two, cluster_ids);
    try g.expectRow(0, " " ++ plus_glyph ++ "  TABS  1 ●2 " ++ close_glyph ++ "  ━●  " ++ close_glyph);
    try testing.expectEqual(@as(u32, 11), g.hits.at(5, 0).?.button);
    try testing.expectEqual(@as(u32, 0x40), g.hits.at(10, 0).?.button);
    try testing.expectEqual(@as(u32, 0x41), g.hits.at(13, 0).?.button);
    try testing.expectEqual(@as(u32, 0x61), g.hits.at(15, 0).?.button);
    try testing.expect(g.bgEql(13, 0, .{ .bg = g.theme.palette.blue }));
    // Compact with two pages keeps the chips, drops the label.
    var c = two;
    c.compact = true;
    try testing.expectEqual(w - 6, clusterWidth(c));
    // The fit rule: full when it clears the chip by 4, else compact, else none.
    const bar = Rect.init(0, 0, 120, 1);
    try testing.expectEqual(ClusterFit{ .w = 21, .compact = false }, pickCluster(bar, 84, .{}, .auto).?);
    try testing.expectEqual(ClusterFit{ .w = 10, .compact = true }, pickCluster(bar, 84, .{}, .compact).?);
    try testing.expectEqual(ClusterFit{ .w = 10, .compact = true }, pickCluster(Rect.init(0, 0, 80, 1), 64, .{}, .auto).?);
    try testing.expect(pickCluster(Rect.init(0, 0, 76, 1), 64, .{}, .expanded) == null);
}
