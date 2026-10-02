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
//! short of room), before those the markdown mode chip, before that the
//! strip's ` ‹ n/m › ` (`stepper.zig`, one control with two uses): on a
//! session pane, the session's place among the sessions it steps
//! through; on any other strip whose tabs overflow, the page of tabs on
//! show, its arrows paging through the hidden ones. It is not painted
//! when there is nothing to step — one session, tabs that all fit — and
//! on a short strip the number, then the arrows, give way before the
//! active tab would be cut. Beside the pager, right of it, ` ⋯ ` opens
//! the buffer picker: every tab, by name — the one jump to a tab pages
//! away. It is the pager's companion and nothing more: no pager, no
//! ` ⋯ `; and on a strip short of room it gives way first, before the
//! pager's number, and the active tab stays whole. A session strip
//! wears the session control and neither: its arrows bring a hidden tab
//! into view by stepping to it, and the sessions rail lists the rest.
//!
//! The strip is a window: `Opts.first` is the scroll offset (the caller
//! keeps it on the leaf, the wheel and the pager move it). `draw`
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
const focus_cue = @import("focus_cue.zig");
const stepper = @import("stepper.zig");
const list_panel = @import("list_panel.zig");

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
    /// The pane's child is blocked on the user (`sessions.needsYou`):
    /// the needs-you mark after the name, in the attention role.
    needs_you: bool = false,
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

/// A session pane's place among the sessions its strip steps through
/// (`app/session_cycle.zig`, `app/sessions_mode.zig`): ` ‹ 3/7 › ` left
/// of the mode chip, drawn by the stepper.
pub const SessionNav = stepper.Stepper;

/// How much of the ` ‹ 3/7 › ` a strip has room for: the number goes
/// first, then the arrows — the tabs keep `narrow_room` either way.
pub const NavForm = stepper.Form;

/// ` ‹ ` / ` › ` — the stepper's, under the names the strip's callers know.
pub const nav_button_w: u16 = stepper.button_w;
pub const nav_prev_glyph = stepper.prev_glyph;
pub const nav_next_glyph = stepper.next_glyph;
pub const nav_prev_ascii = stepper.prev_ascii;
pub const nav_next_ascii = stepper.next_ascii;

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
    /// The `.button` ids the overflow pager's ` ‹ ` / ` › ` register.
    /// Null paints no pager.
    scroll_left: ?u32 = null,
    scroll_right: ?u32 = null,
    split: ?SplitIds = null,
    mode_chip: ?ModeChip = null,
    /// The `.button` the ` ⋯ ` beside the pager registers (the buffer
    /// picker). Null paints none; it paints only with the pager.
    all_tabs: ?u32 = null,
    /// The leaf is zoomed: the maximize button shows the restore glyph.
    zoomed: bool = false,
    /// The leaf's pane has the keys. False puts the active chip's name
    /// in the dim role under `ui.focus_cue = dim | both` (`focus_cue.words`).
    focused: bool = true,
    /// The active pane is an AI session: its ` ‹ 3/7 › `.
    session_nav: ?SessionNav = null,
};

/// What `draw` painted: the offset it settled on, how many chips it
/// painted, and how many tabs sit outside the window on each side —
/// and, for the pager, the offsets of the previous and next page of
/// tabs (the current offset when there is none that way).
pub const Window = struct {
    first: usize = 0,
    painted: usize = 0,
    hidden_left: usize = 0,
    hidden_right: usize = 0,
    page_prev: usize = 0,
    page_next: usize = 0,
};

/// The tab positions a caller needs to route a drop: the `x` each chip
/// starts at and its width, in strip order from the offset.
pub const Slot = struct { idx: usize, x: u16, w: u16 };

/// The most cells a name takes before it is cut.
pub const name_cap: u16 = 18;
/// ` 󰐕 `.
pub const plus_w: u16 = 3;
/// ` 󰅁 ` — one chevron slot (the git palette's repo pill wears the pair).
pub const arrow_w: u16 = 3;
/// One split button.
pub const split_button_w: u16 = 3;
/// ` ⋯ ` — the all-tabs chip beside the pager, one stepper button wide.
pub const all_tabs_w: u16 = stepper.button_w;
/// The face it wears: the "more" ellipsis every list row's kebab wears
/// (`list_panel.zig`), and its `--ascii` twin.
pub const all_tabs_glyph = list_panel.kebab_glyph;
pub const all_tabs_ascii = list_panel.kebab_ascii;
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
/// The needs-you mark (nf-md-hand_back_right — a raised hand): a tab,
/// a SESSIONS card and nothing else wear it, in `Theme.attention_fg`.
pub const needs_you_glyph = "\u{F0E47}";
pub const needs_you_ascii = "!";

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

/// Which mark Claude Code wears — `ui.claude_mark`, whose type this is
/// (`config/Config.zig` aliases it, so there is one definition). Two
/// drawings mnml ships — the product's own figure and the Anthropic
/// spark — and `.custom`, the user's own SVG baked at the figure's
/// codepoint, so it resolves to the same string: which art is behind it
/// is the font's business, not the chrome's. The twin of `TerminalMark`
/// below, down to that last part.
pub const ClaudeMark = enum { figure, spark, custom };

/// The ONE answer to "which mark is Claude's right now". The app side
/// reads the config and calls this (`app/claude_mark.zig`); no painter
/// names `claude_glyph` itself.
pub fn claudeMark(which: ClaudeMark) Mark {
    return switch (which) {
        .figure, .custom => .{ .glyph = claude_glyph, .fallback = claude_ascii },
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

/// // changed (dock-polish): the colour a terminal's mark wears in the
/// chrome — the split cluster's ` term ` chip and a plain shell's tab.
/// It is the terminal's own bright white (palette index 15), not a
/// theme role: a terminal is not one of the integrations, whose
/// category colours are their identity, and it does not take one.
/// The launcher dock's terminal items read THIS constant, so the ghost
/// is one colour on every surface — it used to be green on the dock
/// alone, and the user saw the two ghosts disagree.
pub const terminal_chip_fg: Color = .{ .index = 15 };

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
/// method pill and its gap, the name and a cell, the needs-you mark and
/// a cell, the diagnostics and a cell, the badge and a cell.
pub fn chipWidth(ui: Ui, tab: Tab) u16 {
    const icon: u16 = if (tab.glyph.len == 0) 1 else 2 + ui.width(tab.glyph);
    const verb: u16 = if (tab.verb) |v| ui.width(v) + 3 else 0;
    const mark: u16 = if (tab.needs_you) ui.width(needsYouMark(ui)) + 1 else 0;
    const diag: u16 = if (tab.diag.len == 0) 0 else ui.width(tab.diag) + 1;
    return icon + verb + ui.width(chipName(ui, tab)) + 1 + mark + diag + 2;
}

/// The needs-you mark as this frame paints it (the `--ascii` twin when
/// asked for) — the tab's and the SESSIONS card's alike.
pub fn needsYouMark(ui: Ui) []const u8 {
    return if (ui.ascii) needs_you_ascii else needs_you_glyph;
}

const Badge = struct { text: []const u8, fg: Color, closes: bool };

fn badgeOf(ui: Ui, tab: Tab, hovered: bool) Badge {
    const p = ui.theme.palette;
    const close: []const u8 = if (ui.ascii) close_ascii else close_glyph;
    if (tab.pinned) return .{ .text = if (ui.ascii) pin_ascii else pin_glyph, .fg = p.yellow, .closes = false };
    // The dirty dot wins over the active tab's ×, as over every other
    // tab's: the tab under your hands is the one whose unsaved state
    // matters most. The pointer on the chip turns the dot into the ×
    // (orange, so it still reads unsaved) — the Rust bufferline's rule
    // for a background tab, applied to the active one too.
    if (hovered and tab.dirty) return .{ .text = close, .fg = p.orange, .closes = true };
    if (tab.active and !tab.dirty) return .{ .text = close, .fg = p.red, .closes = true };
    if (hovered) return .{ .text = close, .fg = p.grey_fg, .closes = true };
    if (tab.dirty) return .{ .text = dirty_dot, .fg = p.orange, .closes = true };
    return .{ .text = close, .fg = p.grey, .closes = true };
}

/// Paints one chip at `x`, clipped to `avail` cells, and registers its
/// hits. Returns the cells it took.
fn paintChip(ui: Ui, x: u16, y: u16, avail: u16, tab: Tab, leaf: u32, idx: u16, focused: bool) u16 {
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
    // The active chip's name is the pane's title: the focus cue dims
    // it on a leaf whose pane does not have the keys. The other chips
    // are in the dim role already.
    const plain: Style = .{ .fg = if (tab.active) p.fg else p.grey_fg, .bg = bg, .bold = tab.active, .italic = tab.preview };
    const name_style = if (tab.active) focus_cue.words(ui.theme, ui.focus_cue, focused, plain) else plain;
    cx += ui.putStr(cx, y, end - cx, chipName(ui, tab), name_style);
    cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    if (tab.needs_you) {
        cx += ui.putStr(cx, y, end - cx, needsYouMark(ui), Theme.onBg(ui.theme.attention_fg, bg));
        cx += ui.putStr(cx, y, end - cx, " ", .{ .bg = bg });
    }
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
    /// The overflow pager (`stepper.zig`): where its cells start, how
    /// many it was given, and its form — `.none` with nothing to page.
    pager_x: u16,
    pager_w: u16 = 0,
    pager_form: NavForm = .none,
    /// The ` ⋯ ` after the pager: shown only with it, and only with room.
    all_tabs: bool = false,
    mode_x: u16,
    split_x: u16,
    n_ai: usize,
    nav_x: u16 = 0,
    nav_form: NavForm = .none,
};

/// The widest session-control form that still leaves the active tab
/// whole (and never less than `narrow_room`) next to the rest of the
/// furniture (`fixed`: the split cluster and the mode chip; the 󰐕 is
/// added here). The number gives way first, then the arrows — the
/// session's own name on its tab outranks both. Nothing to step (one
/// session) is no control at all.
fn navFormFor(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts, fixed: u16) NavForm {
    const nav = opts.session_nav orelse return .none;
    const reserved = fixed + plus_w + @max(narrow_room, activeWidth(ui, tabs));
    return stepper.fit(ui, nav, area.w -| reserved);
}

fn activeWidth(ui: Ui, tabs: []const Tab) u16 {
    for (tabs) |tab| if (tab.active) return chipWidth(ui, tab);
    return 0;
}

/// The furniture with `pager_w` cells given to the pager, and the ` ⋯ `
/// after it when `all_tabs`.
fn layoutWith(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts, pager_w: u16, pager_form: NavForm, all_tabs: bool) Geometry {
    var n_ai: usize = if (opts.split) |s| s.ai.len else 0;
    const base: u16 = if (opts.split) |sp| (if (sp.max != null) split_buttons_w else split_buttons_w - split_button_w) else 0;
    while (n_ai > 0 and area.w < base + @as(u16, @intCast(n_ai)) * split_button_w) n_ai -= 1;
    const split_total = base + @as(u16, @intCast(n_ai)) * split_button_w;
    const mode_w: u16 = if (opts.mode_chip) |m| ui.width(m.label) else 0;
    const nav_form = navFormFor(ui, area, tabs, opts, split_total + mode_w);
    const nav_w: u16 = if (opts.session_nav) |nav| stepper.width(ui, nav, nav_form) else 0;
    const right = area.right();
    const tabs_right0 = right -| (split_total + mode_w + nav_w);
    const more_w: u16 = if (all_tabs) all_tabs_w else 0;
    const pager_x = @max(tabs_right0 -| (pager_w + more_w), area.x);
    return .{
        .tabs_right = @max(pager_x -| plus_w, area.x),
        .pager_x = pager_x,
        .pager_w = pager_w,
        .pager_form = pager_form,
        .all_tabs = all_tabs,
        .mode_x = @max(right -| (split_total + mode_w), area.x),
        .split_x = @max(right -| split_total, area.x),
        .n_ai = n_ai,
        .nav_x = @max(right -| (split_total + mode_w + nav_w), area.x),
        .nav_form = nav_form,
    };
}

/// The furniture, the pager included when the tabs overflow: its cells
/// are taken from the tabs only then, so a strip whose tabs all fit is
/// laid out as if there were no pager. A session strip has its own
/// control and no pager. The ` ⋯ ` rides with the pager when the strip
/// holds the whole ` ‹ n/m › `, the ` ⋯ ` and still the active tab
/// (`keep`): short of room it is the first to go — before the number,
/// then the arrows — so the strip only ever loses it as it narrows.
fn geometry(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) Geometry {
    const g0 = layoutWith(ui, area, tabs, opts, 0, .none, false);
    if (opts.scroll_left == null or opts.scroll_right == null) return g0;
    if (g0.nav_form != .none) return g0;
    const room0 = g0.tabs_right -| area.x;
    if (allWidth(ui, tabs) <= room0) return g0;
    const keep = @max(narrow_room, activeWidth(ui, tabs));
    const alone = pagerFit(ui, tabs, room0, keep);
    if (alone.form == .none) return g0;
    if (opts.all_tabs != null and alone.form == .full) {
        const with = pagerFit(ui, tabs, room0 -| all_tabs_w, keep);
        if (with.form == .full) return layoutWith(ui, area, tabs, opts, with.w, with.form, true);
    }
    return layoutWith(ui, area, tabs, opts, alone.w, alone.form, false);
}

const PagerFit = struct { form: NavForm, w: u16 };

/// The pager's form and cells in `room`, leaving the tabs `keep`. The
/// label's width rides on the page count, which rides on the room the
/// pager leaves: two rounds settle it. The widest label (`m/m`) is
/// what is reserved, so paging never reflows the strip.
fn pagerFit(ui: Ui, tabs: []const Tab, room: u16, keep: u16) PagerFit {
    var m = @max(pageCount(ui, tabs, room), 2);
    var form: NavForm = .none;
    var w: u16 = 0;
    for (0..2) |_| {
        const widest: stepper.Stepper = .{ .index = m - 1, .count = m, .prev = 0, .next = 0 };
        form = stepper.fit(ui, widest, room -| keep);
        w = stepper.width(ui, widest, form);
        m = @max(pageCount(ui, tabs, room -| w), 2);
    }
    return .{ .form = form, .w = w };
}

/// Every chip at its natural width, a cell between them.
fn allWidth(ui: Ui, tabs: []const Tab) u32 {
    var w: u32 = 0;
    for (tabs, 0..) |tab, i| w += chipWidth(ui, tab) + @as(u32, if (i > 0) 1 else 0);
    return w;
}

/// The first tab of the page after the one starting at `start`: as
/// many whole chips as `room` holds, a cell between them — never fewer
/// than one, so a chip wider than the strip is a page of its own.
fn pageEnd(ui: Ui, tabs: []const Tab, room: u16, start: usize) usize {
    var x: u32 = 0;
    var i = start;
    while (i < tabs.len) : (i += 1) {
        const next = x + chipWidth(ui, tabs[i]) + @as(u32, if (i > start) 1 else 0);
        if (next > room and i > start) break;
        x = next;
    }
    return i;
}

fn pageCount(ui: Ui, tabs: []const Tab, room: u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < tabs.len) : (n += 1) i = pageEnd(ui, tabs, room, i);
    return n;
}

/// The pager's reading of a window: the pages are cut from the first
/// tab, as many whole chips each as the strip holds; `index` is the
/// page the window starts in (the last one when nothing is hidden to
/// the right — the clamp can start the tail's window mid-page), and
/// `prev` / `next` the offsets one page either way. Like the session
/// ring, the pages wrap: before the first is the last, after the last
/// the first.
const Pages = struct { index: usize, count: usize, prev: usize, next: usize };

fn pagesAt(ui: Ui, tabs: []const Tab, room: u16, first: usize, hidden_right: usize) Pages {
    var out: Pages = .{ .index = 0, .count = 0, .prev = 0, .next = first };
    var last: usize = 0;
    var i: usize = 0;
    while (i < tabs.len) : (out.count += 1) {
        if (i <= first) out.index = out.count;
        if (i < first) out.prev = i;
        if (i > first and out.next == first) out.next = i;
        last = i;
        i = pageEnd(ui, tabs, room, i);
    }
    if (hidden_right == 0) {
        out.index = out.count -| 1;
        out.next = 0;
    }
    if (first == 0) out.prev = last;
    return out;
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

/// How many chips from `first` paint WHOLE in `room` cells — a chip
/// cut at the edge is not in view: its badge, and often its name, are
/// not on the strip. The first chip always counts, as a page of one
/// does when it is wider than the strip.
fn countWhole(ui: Ui, tabs: []const Tab, room: u16, first: usize) usize {
    return pageEnd(ui, tabs, room, first) - first;
}

/// The fewest cells the tabs may be left before the furniture gives way.
const narrow_room: u16 = 12;

/// A leaf too narrow for its furniture and the active tab together —
/// the pager, the 󰐕, the split cluster leave the tabs less than the
/// active chip (or `narrow_room`) — paints the active tab alone across
/// the strip, cut if it must be: the name on the strip is always the
/// pane's, and the other tabs are elided. Null when the strip is wide
/// enough, when dropping the furniture would gain nothing, or when
/// nothing is active.
fn narrowActive(ui: Ui, area: Rect, tabs: []const Tab, g: Geometry) ?usize {
    const active = for (tabs, 0..) |tab, i| {
        if (tab.active) break i;
    } else return null;
    const room = g.tabs_right -| area.x;
    if (room >= @min(chipWidth(ui, tabs[active]), narrow_room)) return null;
    // Nothing to give way: the strip is already all the tabs have (the
    // 󰐕's slot stays carved, as it always is).
    if (narrowWidth(area) <= room) return null;
    return active;
}

/// The cells the active chip takes on a narrow strip: all of it but
/// the 󰐕's slot, which Rust carves before the tabs whether or not a 󰐕
/// paints there.
fn narrowWidth(area: Rect) u16 {
    return area.w -| plus_w;
}

/// The offset to paint from when the active tab changed: `current` when
/// the active tab is already in view, whole, else the active tab itself
/// (the clamp pulls it back so the tail fills the strip). A tab cut at
/// the right edge is not in view: opening the tab after the last whole
/// one used to leave it cut there, its name lost, with the window never
/// moving to it.
pub fn fitActive(ui: Ui, area: Rect, tabs: []const Tab, current: usize, opts: Opts) usize {
    if (tabs.len == 0) return 0;
    const g = geometry(ui, area, tabs, opts);
    if (narrowActive(ui, area, tabs, g)) |a| return a;
    const room = g.tabs_right -| area.x;
    const first = clampScroll(ui, tabs, room, current);
    var active: usize = 0;
    for (tabs, 0..) |tab, i| if (tab.active) {
        active = i;
    };
    if (active >= first and active < first + countWhole(ui, tabs, room, first)) return first;
    return clampScroll(ui, tabs, room, active);
}

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) Window {
    const t = ui.theme;
    const p = t.palette;
    ui.fill(area, t.bufferline);
    if (area.isEmpty()) return .{};
    const y = area.y;
    const g = geometry(ui, area, tabs, opts);
    if (narrowActive(ui, area, tabs, g)) |a| {
        _ = paintChip(ui, area.x, y, narrowWidth(area), tabs[a], opts.leaf, @intCast(a), opts.focused);
        return .{ .first = a, .painted = 1, .hidden_left = a, .hidden_right = tabs.len - a - 1 };
    }

    // The tabs from the clamped offset, a cell of strip between chips.
    const tabs_right = g.tabs_right;
    const first = clampScroll(ui, tabs, tabs_right -| area.x, opts.first);
    // With a pager a page holds whole chips only: one that would be cut
    // at the edge is not painted here — it starts the next page, which
    // is what the pager's count already says. (The first chip always
    // paints, cut if it is wider than the strip.)
    const stop = if (g.pager_form != .none) pageEnd(ui, tabs, tabs_right -| area.x, first) else tabs.len;
    var x = area.x;
    var painted: usize = 0;
    var i = first;
    while (i < stop) : (i += 1) {
        if (x >= tabs_right) break;
        const w = paintChip(ui, x, y, tabs_right - x, tabs[i], opts.leaf, @intCast(i), opts.focused);
        if (w == 0) break;
        x += w + 1;
        painted += 1;
    }
    const hidden_right = tabs.len - first - painted;

    // The pager: ` ‹ n/m › ` over the pages of tabs, right-aligned in
    // the cells reserved for its widest label.
    var pages: Pages = .{ .index = 0, .count = 0, .prev = first, .next = first };
    if (g.pager_form != .none) {
        pages = pagesAt(ui, tabs, tabs_right -| area.x, first, hidden_right);
        const pager: stepper.Stepper = .{ .index = pages.index, .count = pages.count, .prev = opts.scroll_left.?, .next = opts.scroll_right.? };
        const w = stepper.width(ui, pager, g.pager_form);
        _ = stepper.draw(ui, g.pager_x + (g.pager_w -| w), y, area.right(), pager, g.pager_form);
        // ` ⋯ ` after it: the buffer picker, every tab by name.
        if (g.all_tabs) stepper.button(ui, g.pager_x + g.pager_w, y, if (ui.ascii) all_tabs_ascii else all_tabs_glyph, opts.all_tabs.?);
    }

    // ` 󰐕 ` after the last chip, in its own slot before the pager.
    if (opts.new_tab) |id| {
        const plus_x = @max(@min(x, g.pager_x -| plus_w), area.x);
        if (plus_x + plus_w <= g.pager_x) {
            const r = Rect.init(plus_x, y, plus_w, 1);
            ui.fill(r, .{ .bg = p.bg });
            _ = ui.putStr(plus_x + 1, y, 1, if (ui.ascii) plus_ascii else plus_glyph, .{ .fg = p.green, .bg = p.bg, .bold = true });
            ui.hit(r, .{ .button = id });
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

    if (opts.session_nav) |nav| _ = stepper.draw(ui, g.nav_x, y, area.right(), nav, g.nav_form);

    if (opts.split) |s| drawSplit(ui, g.split_x, y, area.right(), s, g.n_ai, opts.zoomed);

    return .{ .first = first, .painted = painted, .hidden_left = first, .hidden_right = hidden_right, .page_prev = pages.prev, .page_next = pages.next };
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
    buttons[n] = .{ .glyph = s.term_mark.glyph, .ascii = s.term_mark.fallback, .fg = terminal_chip_fg, .id = s.term };
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
/// `rust-diff-120x40.txt` row 1: two tabs and the `+` — the Rust strip's
/// dim chevrons are gone: two tabs that fit have nothing to page, and
/// the pager is not painted (`stepper.zig`).
const spec_diff_strip = " " ++ rust_glyph ++ " main.rs " ++ close_glyph ++ "   " ++ diff_glyph ++ " diff: worktree " ++ close_glyph ++ "   " ++ plus_glyph ++ " " ** 40 ++ split_cluster;
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

test "two tabs that fit: the diff spec's strip with no pager — nothing to page is nothing painted" {
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
    try f.expectLacks(nav_prev_glyph);
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

    // Two tabs that fit: nothing at the right end.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .glyph = "x", .dirty = true },
        .{ .id = 2, .title = "b.txt", .glyph = "x", .pinned = true, .active = true },
    };
    const chevrons = "";
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
    try h.expectRow(0, " x a.txt " ++ dirty_dot ++ "   x b.txt " ++ pin_ascii ++ "   " ++ plus_ascii ++ " " ** 21 ++ "  " ++ term_ascii ++ "  " ++ split_right_ascii ++ "  " ++ split_down_ascii ++ "  " ++ maximize_ascii);
    try testing.expectEqual(@as(u32, 9), h.hits.at(25, 0).?.button);
}

test "a tab whose child needs you wears the mark after its name, in the attention role; the chip grows by the mark and a cell; --ascii has its twin" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "claude", .glyph = "x", .active = true, .needs_you = true },
        .{ .id = 2, .title = "sh", .glyph = "x" },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{});
    var buf: [256]u8 = undefined;
    const row = f.row(0, &buf);
    try testing.expect(std.mem.startsWith(u8, row, " x claude " ++ needs_you_glyph ++ " " ++ close_glyph ++ "   x sh " ++ close_glyph));
    try testing.expect(f.fgEql(10, 0, .{ .fg = f.theme.attention_fg.fg }));
    try testing.expect(f.theme.attention_fg.bold);
    var plain = tabs[0];
    plain.needs_you = false;
    try testing.expectEqual(chipWidth(f.ui(), plain) + 2, chipWidth(f.ui(), tabs[0]));
    // The whole chip is still the tab's hit, the close its last two cells.
    try testing.expect(f.hits.at(10, 0).? == .tab);
    try testing.expect(f.hits.at(12, 0).? == .tab_close);
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    g.ascii = true;
    _ = draw(g.ui(), g.full(), &tabs, .{});
    try testing.expect(std.mem.startsWith(u8, g.row(0, &buf), " x claude " ++ needs_you_ascii ++ " " ++ close_ascii));
}

test "the ACTIVE dirty tab shows the dot too, the pointer turns it into an orange ×, and a clean active tab keeps its red ×" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const dirty = [_]Tab{.{ .id = 1, .title = "a.txt", .glyph = "x", .dirty = true, .active = true }};
    _ = draw(f.ui(), f.full(), &dirty, .{});
    try f.expectRow(0, " x a.txt " ++ dirty_dot);
    try testing.expect(f.fgEql(9, 0, .{ .fg = f.theme.palette.orange }));
    // The badge still closes (through the unsaved-changes box).
    try testing.expect(f.hits.at(10, 0).? == .tab_close);
    var ui = f.ui();
    ui.hover = .{ .x = 4, .y = 0 };
    _ = draw(ui, f.full(), &dirty, .{});
    try f.expectRow(0, " x a.txt " ++ close_glyph);
    try testing.expect(f.fgEql(9, 0, .{ .fg = f.theme.palette.orange }));
    // Saved: the red × of the active tab.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const clean = [_]Tab{.{ .id = 1, .title = "a.txt", .glyph = "x", .active = true }};
    _ = draw(g.ui(), g.full(), &clean, .{});
    try g.expectRow(0, " x a.txt " ++ close_glyph);
    try testing.expect(g.fgEql(9, 0, .{ .fg = g.theme.palette.red }));
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

test "an overflowing strip: the offset clamps to what fills it, the pager ` ‹ n/m › ` takes the chevrons' place, the + stays" {
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
    // From the start: three tabs are off the strip. The pager says so
    // — page 1 of 4, two whole chips to a page here — and the + keeps
    // its reserved slot.
    const w0 = draw(f.ui(), f.full(), &tabs, opts);
    try f.expectRow(0, " x one.txt " ++ close_glyph ++ "   x two.txt " ++ close_glyph ++ "   " ++ plus_glyph ++ "  " ++ nav_prev_glyph ++ " 1/4 " ++ nav_next_glyph);
    try testing.expectEqual(@as(usize, 0), w0.first);
    try testing.expectEqual(@as(usize, 2), w0.painted);
    try testing.expectEqual(@as(usize, 3), w0.hidden_right);
    // Both arrows are buttons; before the first page is the last.
    try testing.expectEqual(@as(u32, 70), f.hits.at(32, 0).?.button);
    try testing.expectEqual(@as(u32, 71), f.hits.at(38, 0).?.button);
    try testing.expectEqual(@as(usize, 2), w0.page_next);
    try testing.expectEqual(@as(usize, 4), w0.page_prev);
    try testing.expectEqual(@as(u32, 77), f.hits.at(29, 0).?.button);
    // The active tab is last: fitActive jumps to it and the clamp pulls
    // back to the offset whose tail fills the strip — which is the last
    // tab alone, once the chip has taken its cells.
    const first = fitActive(f.ui(), f.full(), &tabs, 0, opts);
    try testing.expectEqual(@as(usize, 4), first);
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    var at_tail = opts;
    at_tail.first = first;
    const w1 = draw(g.ui(), g.full(), &tabs, at_tail);
    try testing.expectEqual(@as(usize, 4), w1.hidden_left);
    try testing.expectEqual(@as(usize, 0), w1.hidden_right);
    try g.expectContains(" x five.txt " ++ close_glyph ++ "   " ++ plus_glyph);
    // The tail is the last page, and after it comes the first.
    try g.expectContains(nav_prev_glyph ++ " 4/4 " ++ nav_next_glyph);
    try testing.expectEqual(@as(usize, 0), w1.page_next);
    try testing.expect(hasTab(&g, 4));
    // A stale offset past that is pulled back; the active tab already in
    // view keeps the offset.
    var stale = opts;
    stale.first = 9;
    try testing.expectEqual(@as(usize, 4), draw(g.ui(), g.full(), &tabs, stale).first);
    try testing.expectEqual(@as(usize, 4), fitActive(g.ui(), g.full(), &tabs, 4, opts));
    // Everything fits: no pager at all — no cells, no buttons.
    var k = try Fixture.init(90, 1);
    defer k.deinit();
    const w3 = draw(k.ui(), k.full(), &tabs, opts);
    try testing.expectEqual(@as(usize, 0), w3.hidden_right);
    try testing.expect(!hasButton(&k, 70) and !hasButton(&k, 71));
    try k.expectLacks(nav_prev_glyph);
    try k.expectLacks(arrow_left_glyph);
    // No tabs: the + alone at the left.
    var e = try Fixture.init(20, 1);
    defer e.deinit();
    _ = draw(e.ui(), e.full(), &.{}, .{ .new_tab = 1 });
    try e.expectRow(0, " " ++ plus_glyph);
    _ = draw(e.ui(), Rect.empty, &.{}, .{ .new_tab = 1 });
}

test "with a pager a page paints whole chips only: a chip that would be cut at the edge is not painted and starts the next page, at every width" {
    var names: [12][8]u8 = undefined;
    var tabs: [12]Tab = undefined;
    for (&tabs, 0..) |*tab, i| tab.* = .{ .id = @intCast(i + 1), .title = try std.fmt.bufPrint(&names[i], "t{d}.txt", .{i + 1}), .glyph = "x" };
    tabs[0].active = true;
    const opts: Opts = .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .all_tabs = 72 };
    var cut_seen = false;
    var w: u16 = 30;
    while (w <= 110) : (w += 1) {
        var f = try Fixture.init(w, 1);
        defer f.deinit();
        const win = draw(f.ui(), f.full(), &tabs, opts);
        if (!hasButton(&f, 70)) continue;
        // Every chip painted is whole: its close glyph is on the strip.
        var buf: [1024]u8 = undefined;
        const row = f.row(0, &buf);
        try testing.expectEqual(win.painted, std.mem.count(u8, row, close_glyph));
        for (win.painted..tabs.len) |i| try testing.expect(!hasTab(&f, @intCast(i)));
        // The page is what the pager counts: the next page starts at the
        // first chip not painted.
        try testing.expectEqual(win.first + win.painted, win.page_next);
        // Room was left after the last whole chip: the old loop painted
        // the next one there, cut.
        const g = geometry(f.ui(), f.full(), &tabs, opts);
        const room = g.tabs_right -| f.full().x;
        if (win.first + win.painted < tabs.len and allWidth(f.ui(), tabs[win.first .. win.first + win.painted]) + 1 < room) cut_seen = true;
    }
    try testing.expect(cut_seen);
}

test "the pager pages: whole chips per page from the first tab, `›` to the next page's offset, `‹` to the previous, wrapping at both ends; a session strip's own control leaves it out" {
    const names = [_][]const u8{ "t1.txt", "t2.txt", "t3.txt", "t4.txt", "t5.txt", "t6.txt", "t7.txt", "t8.txt", "t9.txt", "t10.tx", "t11.tx", "t12.tx" };
    var tabs: [12]Tab = undefined;
    for (names, 0..) |n, i| tabs[i] = .{ .id = @intCast(i + 1), .title = n, .glyph = "x", .active = i == 0 };
    const opts: Opts = .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71 };
    // 80 cells, no cluster: the reading at each page start.
    const Want = struct { first: usize, label: []const u8, prev: usize, next: usize };
    var f = try Fixture.init(80, 1);
    defer f.deinit();
    const w0 = draw(f.ui(), f.full(), &tabs, opts);
    try testing.expectEqual(@as(usize, 0), w0.first);
    try f.expectContains(nav_prev_glyph ++ " 1/");
    const pages_label = blk: {
        var buf: [1024]u8 = undefined;
        const row = f.row(0, &buf);
        const at = std.mem.indexOf(u8, row, " 1/").?;
        break :blk try f.ui().arena.dupe(u8, row[at + 3 .. std.mem.indexOfScalarPos(u8, row, at + 3, ' ').?]);
    };
    const count = try std.fmt.parseInt(usize, pages_label, 10);
    try testing.expect(count >= 3);
    // Walk forward with `›`: every page, then round to the first.
    var first: usize = 0;
    var seen: usize = 0;
    var steps: usize = 0;
    while (steps < count) : (steps += 1) {
        var g = try Fixture.init(80, 1);
        defer g.deinit();
        var o = opts;
        o.first = first;
        const w = draw(g.ui(), g.full(), &tabs, o);
        seen += 1;
        try g.expectContains(g.ui().fmt("{s} {d}/{d} {s}", .{ nav_prev_glyph, steps + 1, count, nav_next_glyph }));
        // `‹` from here is where the last step came from.
        if (steps > 0) try testing.expect(w.page_prev < w.first);
        first = w.page_next;
    }
    try testing.expectEqual(count, seen);
    try testing.expectEqual(@as(usize, 0), first);
    _ = Want;
    // A session strip that overflows wears its session control, no pager.
    var s = try Fixture.init(80, 1);
    defer s.deinit();
    var so = opts;
    so.session_nav = .{ .index = 1, .count = 3, .prev = 60, .next = 61 };
    _ = draw(s.ui(), s.full(), &tabs, so);
    try s.expectContains(nav_prev_glyph ++ " 2/3 " ++ nav_next_glyph);
    try testing.expect(!hasButton(&s, 70) and !hasButton(&s, 71));
    // One session — nothing to step — is no control, and the pager is back.
    so.session_nav = .{ .index = 0, .count = 1, .prev = 60, .next = 61 };
    var u = try Fixture.init(80, 1);
    defer u.deinit();
    _ = draw(u.ui(), u.full(), &tabs, so);
    try u.expectLacks("1/1");
    try testing.expect(!hasButton(&u, 60) and !hasButton(&u, 61));
    try testing.expect(hasButton(&u, 70) and hasButton(&u, 71));
}

test "the mode chip sits before the cluster; AI chips drop first" {
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
        .mode_chip = .{ .label = " " ++ preview_glyph ++ " Preview ", .button = 5, .kind = .edit_md },
        .split = .{ .term = 1, .right = 2, .down = 3, .max = 4, .ai = &ai },
    });
    try f.expectRow(0, std.mem.trimEnd(u8, " x a.md " ++ close_glyph ++ "   " ++ plus_glyph ++ " " ** 15 ++ preview_glyph ++ " Preview  ✳  ❯ " ++ split_cluster, " "));
    try testing.expect(f.hits.at(15, 0) == null);
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

test "a session pane's strip: ` ‹ 3/7 › ` before the cluster, each arrow a button; short of room the number goes first, then the arrows, and the active tab stays whole" {
    const tabs = [_]Tab{.{ .id = 1, .title = "claude", .glyph = "x", .active = true }};
    const opts: Opts = .{
        .new_tab = 9,
        .split = .{ .term = 1, .right = 2, .down = 3, .max = 4 },
        .session_nav = .{ .index = 2, .count = 7, .prev = 60, .next = 61 },
    };
    // Room for all of it: 12 cells of cluster, 9 of nav, the tab's 12
    // and the 󰐕 — 36 and up.
    var f = try Fixture.init(50, 1);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), &tabs, opts);
    try f.expectContains(" " ++ nav_prev_glyph ++ " 3/7 " ++ nav_next_glyph ++ "  " ++ ghost_glyph);
    // The nav ends where the cluster starts: 50 - 12 - 9 = 29.
    for ([_]u16{ 29, 30, 31 }) |x| try testing.expectEqual(@as(u32, 60), f.hits.at(x, 0).?.button);
    for ([_]u16{ 35, 36, 37 }) |x| try testing.expectEqual(@as(u32, 61), f.hits.at(x, 0).?.button);
    // The number between them is no target.
    try testing.expect(f.hits.at(33, 0) == null);
    try testing.expectEqual(@as(u32, 1), f.hits.at(38, 0).?.button);
    // The active chip is untouched.
    try testing.expectEqual(@as(u32, 0), f.hits.at(1, 0).?.tab.idx);

    // Short of room: the number goes, the arrows stay (33..35).
    var g = try Fixture.init(34, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &tabs, opts);
    try g.expectContains(" " ++ nav_prev_glyph ++ "  " ++ nav_next_glyph ++ "  " ++ ghost_glyph);
    try g.expectLacks("3/7");
    try testing.expectEqual(@as(u32, 60), g.hits.at(16, 0).?.button);
    try testing.expectEqual(@as(u32, 61), g.hits.at(19, 0).?.button);

    // Shorter still: the arrows go too, before the tab would.
    var h = try Fixture.init(32, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), &tabs, opts);
    try h.expectLacks(nav_prev_glyph);
    try h.expectLacks(nav_next_glyph);
    try h.expectContains(" x claude ");

    // The session's own name outranks the nav: an 18-cell name keeps
    // its chip whole, and the nav takes only what is left over.
    const long = [_]Tab{.{ .id = 1, .title = "fix the failing te", .glyph = "x", .active = true }};
    var l = try Fixture.init(44, 1);
    defer l.deinit();
    _ = draw(l.ui(), l.full(), &long, opts);
    try l.expectContains(" x fix the failing te " ++ close_glyph);
    try l.expectLacks(nav_prev_glyph);
    var m = try Fixture.init(45, 1);
    defer m.deinit();
    _ = draw(m.ui(), m.full(), &long, opts);
    try m.expectContains(" x fix the failing te " ++ close_glyph);
    try m.expectContains(nav_prev_glyph ++ "  " ++ nav_next_glyph);
    try m.expectLacks("3/7");

    // `--ascii`: `<` and `>`.
    var a = try Fixture.init(50, 1);
    defer a.deinit();
    var aui = a.ui();
    aui.ascii = true;
    _ = draw(aui, a.full(), &tabs, opts);
    try a.expectContains(" " ++ nav_prev_ascii ++ " 3/7 " ++ nav_next_ascii ++ " ");
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

test "focus cue: the active chip's name dims on a leaf whose pane does not have the keys; the cue `rail` leaves it" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 7, .title = "main.rs", .glyph = rust_glyph, .active = true },
        .{ .id = 8, .title = "lib.rs", .glyph = rust_glyph },
    };
    // The name starts after ` glyph `: column 3. The second chip's name
    // after the first chip, the one-cell gap and its own ` glyph `.
    _ = draw(f.ui(), f.full(), &tabs, .{});
    try testing.expect(f.fgEql(3, 0, .{ .fg = f.theme.palette.fg }));
    try testing.expect(f.style(3, 0).bold);
    _ = draw(f.ui(), f.full(), &tabs, .{ .focused = false });
    try testing.expect(f.fgEql(3, 0, .{ .fg = f.theme.palette.comment }));
    try testing.expect(!f.style(3, 0).bold);
    var ui = f.ui();
    ui.focus_cue = .rail;
    _ = draw(ui, f.full(), &tabs, .{ .focused = false });
    try testing.expect(f.fgEql(3, 0, .{ .fg = f.theme.palette.fg }));
}

test "a 20-column leaf always shows its active tab, whole or cut, and elides the rest" {
    const tabs = [_]Tab{
        .{ .id = 1, .title = "alpha.txt", .glyph = "x" },
        .{ .id = 2, .title = "bravo.txt", .glyph = "x", .active = true },
        .{ .id = 3, .title = "charlie.txt", .glyph = "x" },
    };
    // As render hands it over: the + , the chevrons, the split cluster
    // and the ` ⋯ `'s button — more furniture than 20 cells hold.
    const opts: Opts = .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .split = split_ids, .all_tabs = 8 };
    for ([_]usize{ 0, 1, 2 }) |stale| {
        var f = try Fixture.init(20, 1);
        defer f.deinit();
        var o = opts;
        o.first = fitActive(f.ui(), f.full(), &tabs, stale, opts);
        const w = draw(f.ui(), f.full(), &tabs, o);
        try f.expectContains("bravo");
        try f.expectLacks("alpha");
        try f.expectLacks("charlie");
        try testing.expect(hasTab(&f, 1));
        try testing.expect(!hasTab(&f, 0) and !hasTab(&f, 2));
        try testing.expectEqual(@as(usize, 1), w.first);
        try testing.expectEqual(@as(usize, 1), w.painted);
    }
    // A stale offset the caller did not re-fit (the leaf narrowed under
    // it) still paints the active tab, not the one at the offset.
    var g = try Fixture.init(20, 1);
    defer g.deinit();
    var o = opts;
    o.first = 0;
    _ = draw(g.ui(), g.full(), &tabs, o);
    try g.expectContains("bravo");
    try g.expectLacks("alpha");
}

/// Twelve `tN.txt` tabs, `active` the one with the keys: the strip
/// `tab_strip_pager.test` opens.
fn twelveTabs(active: usize) [12]Tab {
    const names = [_][]const u8{ "t1.txt", "t2.txt", "t3.txt", "t4.txt", "t5.txt", "t6.txt", "t7.txt", "t8.txt", "t9.txt", "t10.txt", "t11.txt", "t12.txt" };
    var tabs: [12]Tab = undefined;
    for (names, 0..) |n, i| tabs[i] = .{ .id = @intCast(i + 1), .title = n, .glyph = "x", .active = i == active };
    return tabs;
}

const all_tabs_opts: Opts = .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .all_tabs = 8 };

test "the ` ⋯ ` rides with the pager: right of ` ‹ n/m › `, a stepper button whose hit is the buffer picker's, lit under the pointer, `...` under --ascii; tabs that all fit have neither" {
    const tabs = twelveTabs(0);
    var f = try Fixture.init(80, 1);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), &tabs, all_tabs_opts);
    try f.expectContains(nav_prev_glyph ++ " 1/");
    try f.expectContains(nav_next_glyph ++ "  " ++ "\u{22ef}");
    // The last three cells, the strip having no cluster: the chip's, a
    // button wide, after the `›`.
    for ([_]u16{ 77, 78, 79 }) |x| try testing.expectEqual(@as(u32, 8), f.hits.at(x, 0).?.button);
    try testing.expectEqual(@as(u32, 71), f.hits.at(76, 0).?.button);
    // The stepper's own look: its ground, its bold glyph; the pointer lights it.
    try testing.expect(f.bgEql(78, 0, .{ .bg = f.theme.palette.bg_darker }));
    try testing.expect(f.style(78, 0).bold);
    var ui = f.ui();
    ui.hover = .{ .x = 78, .y = 0 };
    _ = draw(ui, f.full(), &tabs, all_tabs_opts);
    try testing.expect(f.bgEql(77, 0, .{ .bg = f.theme.palette.bg2 }));
    // `--ascii`: the list rows' twin.
    var a = try Fixture.init(80, 1);
    defer a.deinit();
    var aui = a.ui();
    aui.ascii = true;
    _ = draw(aui, a.full(), &tabs, all_tabs_opts);
    try a.expectContains(nav_next_ascii ++ " " ++ all_tabs_ascii);
    try testing.expectEqual(@as(u32, 8), a.hits.at(77, 0).?.button);
    // Five tabs that fit: no pager, no ` ⋯ `, no cells taken.
    var k = try Fixture.init(90, 1);
    defer k.deinit();
    _ = draw(k.ui(), k.full(), tabs[0..5], all_tabs_opts);
    try testing.expect(!hasButton(&k, 8));
    try k.expectLacks("\u{22ef}");
    // A strip with no pager to wear (no arrows' ids) has no ` ⋯ ` either.
    var n = try Fixture.init(80, 1);
    defer n.deinit();
    _ = draw(n.ui(), n.full(), &tabs, .{ .new_tab = 77, .all_tabs = 8 });
    try testing.expect(!hasButton(&n, 8));
}

test "a session strip wears its session control and no ` ⋯ ` — sessions have the rail; one session, no control, and the pager and its ` ⋯ ` are back" {
    const tabs = twelveTabs(0);
    var o = all_tabs_opts;
    o.session_nav = .{ .index = 1, .count = 3, .prev = 60, .next = 61 };
    var s = try Fixture.init(80, 1);
    defer s.deinit();
    _ = draw(s.ui(), s.full(), &tabs, o);
    try s.expectContains(nav_prev_glyph ++ " 2/3 " ++ nav_next_glyph);
    try testing.expect(!hasButton(&s, 8));
    try s.expectLacks("\u{22ef}");
    o.session_nav = .{ .index = 0, .count = 1, .prev = 60, .next = 61 };
    var u = try Fixture.init(80, 1);
    defer u.deinit();
    _ = draw(u.ui(), u.full(), &tabs, o);
    try testing.expect(hasButton(&u, 70) and hasButton(&u, 8));
}

test "short of room the ` ⋯ ` goes first — before the pager's number, then its arrows — and the active tab stays whole" {
    const tabs = twelveTabs(0);
    // 29 cells: the chip, the pager whole, the active tab whole.
    var f = try Fixture.init(29, 1);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), &tabs, all_tabs_opts);
    try f.expectRow(0, " x t1.txt " ++ close_glyph ++ "  " ++ plus_glyph ++ "   " ++ nav_prev_glyph ++ " 1/12 " ++ nav_next_glyph ++ "  \u{22ef}");
    // One cell short: the ` ⋯ ` yields, the pager keeps its number.
    var g = try Fixture.init(28, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &tabs, all_tabs_opts);
    try g.expectContains(nav_prev_glyph ++ " 1/12 " ++ nav_next_glyph);
    try testing.expect(!hasButton(&g, 8));
    try g.expectContains(" x t1.txt " ++ close_glyph);
    // Narrower: the number goes, the arrows stay, the chip stays gone —
    // it never comes back as the strip shrinks.
    var w: u16 = 25;
    while (w >= 21) : (w -= 1) {
        var h = try Fixture.init(w, 1);
        defer h.deinit();
        _ = draw(h.ui(), h.full(), &tabs, all_tabs_opts);
        try h.expectLacks("1/12");
        try testing.expect(hasButton(&h, 70) and !hasButton(&h, 8));
        try h.expectContains(" x t1.txt " ++ close_glyph);
    }
}

test "at the shipped sizes the ` ⋯ ` stands beside the pager and the active tab is whole: 160 columns with the 32-cell tree, 120x40, 200x60" {
    // The leaf strip at each size (the tree and its rail take 33 cells):
    // 120 → 87, 160 → 127, 200 → 167; the split cluster at its end.
    for ([_]u16{ 87, 127, 167 }) |wd| {
        const tabs = twelveTabs(11);
        var f = try Fixture.init(wd, 1);
        defer f.deinit();
        var o = all_tabs_opts;
        o.split = split_ids;
        o.first = fitActive(f.ui(), f.full(), &tabs, 0, o);
        _ = draw(f.ui(), f.full(), &tabs, o);
        try f.expectContains(" x t12.txt " ++ close_glyph);
        try f.expectContains(nav_next_glyph ++ "  \u{22ef}  " ++ ghost_glyph);
        try testing.expect(hasButton(&f, 8) and hasButton(&f, 70));
    }
}

test "the tab after the last whole one, opened, is brought into view whole — a chip cut at the edge is not in view" {
    // 40 cells: t1 and t2 whole, t3 cut at the edge.
    const tabs = [_]Tab{
        .{ .id = 1, .title = "t1.txt", .glyph = "x" },
        .{ .id = 2, .title = "t2.txt", .glyph = "x" },
        .{ .id = 3, .title = "t3.txt", .glyph = "x", .active = true },
    };
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const o: Opts = .{ .new_tab = 77 };
    const first = fitActive(f.ui(), f.full(), &tabs, 0, o);
    try testing.expectEqual(@as(usize, 1), first);
    var at = o;
    at.first = first;
    _ = draw(f.ui(), f.full(), &tabs, at);
    try f.expectContains(" x t3.txt " ++ close_glyph);
}
