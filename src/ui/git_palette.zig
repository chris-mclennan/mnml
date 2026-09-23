//! The git palette — the branches panel the sidebar shows while Git is
//! the active section. One column per repo (the tab strip holds one
//! graph tab per repo; the repo pill on top picks which):
//!
//! ```text
//!  GIT                    ⟳
//!   󰍉 / filter
//!
//!   ws 󰅀   󰅁  󰅂
//!  Viewing 9
//!
//!   󰌢 LOCAL             2
//!     󱓏 main         1↑ 3↓     ← the checked-out branch: its own glyph,
//!     󰘬 feature                  the name bold, ahead / behind
//!
//!   󰅟 REMOTE            3
//!     󰊤 origin
//!       󰘬 main
//!       󰘬 feature
//!
//!   󰐅 WORKTREES         2
//!     󰋜 ws                         ← the house is the main tree; the
//!  󰌾 󰐅 wt-fix (fix)         ●        one on show is bold · locked
//!                                        (gutter) · dirty (the dot)
//!
//!   󰏗 STASHES           1
//!     ab12cd3 On main: half done
//!
//!   󰓻 TAGS              2
//!     󰓹 v2.0
//! ```
//!
//! Top to bottom, TODOS' shape: the caps header every panel in the
//! column starts with (`header.zig` — `GIT` at the left, the refresh
//! chip at the right edge), the filter row every list panel has
//! (`filter_input.zig` — same glyph, same placeholder, same caret), a
//! blank, the repo pill (a `.git_palette = .repo` hit) with the tab
//! strip's two chevrons after it (`.repo_prev` / `.repo_next`: the
//! previous / next repo in discovery order, wrapping; dim and inert
//! with one repo), `Viewing N` (N = the item rows listed after folding
//! and filtering, in the accent colour), a blank, then ONE scrolling
//! list of five sections in a fixed order. With every repo listed
//! (`Props.grouped`, the pill reading `All repos`) each section holds
//! a muted sub-header per repo — its name, indented like a remote's
//! under REMOTE — and the repo's rows one level further in. A section header is a chevron, a
//! glyph, the caps label and its count at the right edge; a click on
//! any of it folds the section. Column 0 of every row is the gutter:
//! the lock on a `git worktree lock`ed tree, a repo's or a session's
//! accent, the cursor marker when the row has nothing else to say
//! there. The cursor row is the list panels' selection — the grey
//! ground and the accent `▌` — and nothing else paints a ground: the
//! checked-out branch is told by its own glyph (the branch with a
//! check on it) and a bold name, the worktree on show by a bold name
//! (the reference client marks the main tree with a house, not the
//! checked-out row with a check column). The right edge carries the
//! branch's ahead / behind (`10↑`, `2↓`, `1↑ 3↓`; nothing when even or
//! untracked) and the blue dot of a worktree with uncommitted changes.
//! Names clip with `…` before those cells; nothing paints past the
//! column. The rows come in flat (`Row`), built by
//! `app/git_palette.zig`; the scroll follows the cursor as every list
//! panel's does (`list_panel.scrollWindow`), the scrollbar taking the
//! last column only when the list overflows.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const chip = @import("chip.zig");
const header = @import("header.zig");
const bufferline = @import("bufferline.zig");
const expander = @import("expander.zig");
const filter_input = @import("filter_input.zig");
const list_panel = @import("list_panel.zig");
const scrollbar = @import("scrollbar.zig");
const text_field = @import("text_field.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;

pub const Caret = text_field.Caret;

/// The palette's own click targets beside its rows: the repo pill and
/// the two chevrons after it.
pub const Part = enum { repo, repo_prev, repo_next };

/// The sections, in the order they are listed.
pub const Section = enum {
    local,
    remote,
    worktrees,
    stashes,
    tags,

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .local => "LOCAL",
            .remote => "REMOTE",
            .worktrees => "WORKTREES",
            .stashes => "STASHES",
            .tags => "TAGS",
        };
    }

    pub const all = [_]Section{ .local, .remote, .worktrees, .stashes, .tags };
};

/// One painted row. `idx` on an item is its index into the app's list
/// for that kind (a branch's into the rail's branches, a worktree's
/// into the rail's worktrees, and so on).
pub const Row = union(enum) {
    section: struct { s: Section, count: u32, collapsed: bool },
    /// A local branch.
    branch: struct { idx: u32, name: []const u8, current: bool, ahead: u32 = 0, behind: u32 = 0 },
    /// A remote's own row (its branches are the rows under it).
    remote: struct { idx: u32, name: []const u8, github: bool },
    /// A remote branch, shown without the `remote/` prefix.
    remote_branch: struct { idx: u32, name: []const u8, shown: []const u8 },
    /// `accent` is a session's colour when mnml made the tree for one
    /// (sessions-worktree): its `▌` in the gutter; `session` says so.
    worktree: struct { idx: u32, shown: []const u8, main: bool, current: bool, locked: bool, dirty: bool, ahead: u32 = 0, behind: u32 = 0, accent: ?Color = null, session: bool = false },
    stash: struct { idx: u32, sha: []const u8, message: []const u8 },
    tag: struct { idx: u32, name: []const u8 },
    /// All repos: the sub-header a section holds per repo (`idx` is the
    /// repo's index in discovery order); the rows under it are its.
    /// `accent` is the repo's colour, its `▌` in the gutter.
    repo: struct { idx: u32, name: []const u8, accent: ?Color = null },
    gap,

    /// An item row — what `Viewing N` counts and Enter acts on.
    pub fn isItem(r: Row) bool {
        return switch (r) {
            .branch, .remote_branch, .worktree, .stash, .tag => true,
            .section, .remote, .repo, .gap => false,
        };
    }

    /// A row a cursor can rest on.
    pub fn isStop(r: Row) bool {
        return r != .gap;
    }
};

pub const Props = struct {
    rows: []const Row,
    repo: []const u8,
    /// The item rows listed (after folding and the filter).
    viewing: usize,
    filter: []const u8 = "",
    filter_caret: usize = 0,
    filter_focused: bool = false,
    /// The keyboard cursor over `rows`.
    cursor: usize = 0,
    /// The first row painted; clamped so the cursor is in view.
    scroll: usize = 0,
    /// The repos the chevrons step through; one leaves them dim.
    repo_count: usize = 1,
    /// All repos: the item rows sit under `.repo` sub-headers, one
    /// level further in.
    grouped: bool = false,
    /// // changed (colors): the pill's repo accent — its `▌` in column
    /// 0 of the pill row; null under All repos and with one repo.
    accent: ?Color = null,
};

pub const Painted = struct {
    /// The scroll after the clamp — the app stores it back.
    scroll: usize = 0,
    /// Rows the list has room for.
    visible: usize = 0,
    /// The filter's caret when it has focus.
    caret: ?Caret = null,
};

// ── glyphs ──

/// The pill's dropdown mark — not an expander (those are `expander.zig`'s).
pub const repo_chevron_nerd = "\u{F0140}"; // md-chevron_down
pub const repo_chevron_ascii = "v";
pub const local_nerd = "\u{F0322}"; // md-laptop
pub const local_ascii = "%";
pub const remote_nerd = "\u{F015F}"; // md-cloud
pub const remote_ascii = "~";
pub const worktrees_nerd = "\u{F0405}"; // md-pine_tree
pub const worktrees_ascii = "^";
pub const stashes_nerd = "\u{F03D7}"; // md-package_variant_closed
pub const stashes_ascii = "$";
pub const tags_nerd = "\u{F04FB}"; // md-tag_multiple
pub const tags_ascii = "#";
pub const branch_nerd = "\u{F062C}"; // md-source_branch
pub const branch_ascii = "Y";
pub const github_nerd = "\u{F02A4}"; // md-github
pub const github_ascii = "G";
pub const forge_nerd = "\u{F059F}"; // md-web
pub const forge_ascii = "W";
pub const home_nerd = "\u{F02DC}"; // md-home
pub const home_ascii = "@";
pub const tree_nerd = "\u{F0405}"; // md-pine_tree
pub const tree_ascii = "^";
pub const lock_nerd = "\u{F033E}"; // md-lock
pub const lock_ascii = "!";
/// The checked-out branch's glyph — the branch with a check on it.
pub const current_branch_nerd = "\u{F14CF}"; // md-source_branch_check
pub const current_branch_ascii = "*";
pub const tag_nerd = "\u{F04F9}"; // md-tag
pub const tag_ascii = "#";
pub const dirty_dot = "\u{25CF}";
pub const dirty_dot_ascii = "o";
pub const ahead_arrow = "\u{2191}";
pub const behind_arrow = "\u{2193}";

fn g(ui: Ui, nerd: []const u8, ascii: []const u8) []const u8 {
    return if (ui.ascii or !ui.nerd_font) ascii else nerd;
}

fn sectionGlyph(ui: Ui, s: Section) []const u8 {
    return switch (s) {
        .local => g(ui, local_nerd, local_ascii),
        .remote => g(ui, remote_nerd, remote_ascii),
        .worktrees => g(ui, worktrees_nerd, worktrees_ascii),
        .stashes => g(ui, stashes_nerd, stashes_ascii),
        .tags => g(ui, tags_nerd, tags_ascii),
    };
}

/// `1↑ 3↓` — the branch's standing against its upstream; empty when
/// even or untracked.
pub fn trackText(ui: Ui, ahead: u32, behind: u32) []const u8 {
    const up = if (ui.ascii) "^" else ahead_arrow;
    const down = if (ui.ascii) "v" else behind_arrow;
    if (ahead > 0 and behind > 0) return ui.fmt("{d}{s} {d}{s}", .{ ahead, up, behind, down });
    if (ahead > 0) return ui.fmt("{d}{s}", .{ ahead, up });
    if (behind > 0) return ui.fmt("{d}{s}", .{ behind, down });
    return "";
}

/// The rows above the list: the caps header, the filter, a blank, the
/// pill with the chevrons, `Viewing N`, a blank.
pub const head_rows: u16 = 6;

/// ` 󰅁 ` — one chevron slot, the tab strip's (`bufferline.arrow_w`).
pub const arrow_w: u16 = bufferline.arrow_w;

/// Paints the palette into `area` and registers its hits.
pub fn draw(ui: Ui, area: Rect, p: Props) Painted {
    const t = ui.theme;
    const pal = t.palette;
    const bg = t.panel_bg;
    var out: Painted = .{ .scroll = p.scroll };
    ui.fill(area, bg);
    if (area.h < 1 or area.w < 6) return out;
    const x0 = area.x;
    const w = area.w;

    // ── the caps header every panel in the column starts with ──
    // `GIT` at the left, the refresh chip at the right edge; the
    // header owns the chip and its `.git` / `.refresh` hit.
    _ = header.draw(ui, area.row(0), .{
        .panel = .git,
        .label = "GIT",
        .show_refresh = true,
        .bg = bg,
        .focused = ui.isFocused(.{ .panel = .git }),
    });

    // ── the filter row every list panel has ──
    if (area.h > 1) {
        out.caret = filter_input.draw(ui, area.row(1), .{
            .panel = .git,
            .text = p.filter,
            .caret = p.filter_caret,
            .focused = p.filter_focused,
            .bg = bg,
        });
    }

    // ── the repo pill, the chevrons after it ──
    if (area.h > 3) {
        const y = area.y + 3;
        const text = ui.fmt(" {s} {s} ", .{ p.repo, g(ui, repo_chevron_nerd, repo_chevron_ascii) });
        const text_w = ui.width(text);
        // The chevrons sit at the column's right edge — the scrollbar's
        // side — so they stay under the pointer while it steps through
        // repos whose names differ in length (they used to follow the
        // pill and slide with it). The pill takes what is left on the
        // left, one cell of air before the chevrons; a column too
        // narrow for both paints the pill alone, clipped. At the width
        // git mode snaps to (20 cells, `All repos 󰅀`) the air goes and
        // the pill's own trailing space is clipped instead: the slot's
        // leading cell keeps the glyphs apart.
        const arrows_fit = text_w + 2 * arrow_w <= w -| 1;
        const room: u16 = if (arrows_fit) w -| (2 + 2 * arrow_w) else w -| 2;
        // Tight by exactly the trailing space: drop the space rather
        // than clip the name (which would eat the dropdown glyph).
        const pill_text = if (text_w == room + 1) ui.fmt(" {s} {s}", .{ p.repo, g(ui, repo_chevron_nerd, repo_chevron_ascii) }) else text;
        var style = Theme.onBg(t.fg, pal.bg2);
        style.bold = true;
        const pill_w = ui.putStr(x0 + 1, y, room, ui.clipStr(pill_text, room), style);
        ui.hit(Rect.init(x0 + 1, y, pill_w, 1), .{ .git_palette = .repo });
        if (p.accent) |accent| _ = ui.putStr(x0, y, 1, if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph, Theme.withFg(bg, accent));
        if (arrows_fit) {
            const on = p.repo_count > 1;
            const pair = [_]struct { glyph: []const u8, ascii: []const u8, part: Part }{
                .{ .glyph = bufferline.arrow_left_glyph, .ascii = bufferline.arrow_left_ascii, .part = .repo_prev },
                .{ .glyph = bufferline.arrow_right_glyph, .ascii = bufferline.arrow_right_ascii, .part = .repo_next },
            };
            const arrows_x = x0 + w -| (1 + 2 * arrow_w);
            for (pair, 0..) |a, slot| {
                const ax = arrows_x + @as(u16, @intCast(slot)) * arrow_w;
                const r = Rect.init(ax, y, arrow_w, 1);
                const astyle: Style = if (on) .{ .fg = pal.fg, .bg = pal.bg2 } else .{ .fg = pal.comment, .bg = pal.bg_darker, .dim = true };
                ui.fill(r, astyle);
                _ = ui.putStr(ax + 1, y, 1, if (ui.ascii) a.ascii else a.glyph, astyle);
                if (on) ui.hit(r, .{ .git_palette = a.part });
            }
        }
    }

    // ── Viewing N ──
    if (area.h > 4) {
        const y = area.y + 4;
        var x = x0 + 1;
        x += ui.putStr(x, y, w -| 1, "Viewing ", bg);
        _ = ui.putStr(x, y, area.right() -| x, ui.fmt("{d}", .{p.viewing}), Theme.withFg(bg, t.accent.fg));
    }

    // ── the list ──
    if (area.h <= head_rows) return out;
    var list = Rect.init(x0, area.y + head_rows, w, area.h - head_rows);
    const win = list_panel.scrollWindow(&out.scroll, p.cursor, p.rows.len, list.h);
    out.visible = list.h;
    if (win.needs_bar and list.w > 3) {
        const split = list.splitRight(1);
        list = split.left;
        scrollbar.drawVertical(ui, split.rest, .{ .panel = .git }, p.rows.len, list.h, out.scroll);
    }
    const focused = ui.isFocused(.{ .panel = .git });
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const row = p.rows[idx];
        const rr = list.row(@intCast(i));
        const y = rr.y;
        const end = rr.right();
        const at_cursor = idx == p.cursor and row.isStop();
        const ground: Style = if (at_cursor) list_panel.rowStyle(t, true) else bg;
        if (at_cursor) ui.fill(rr, ground);
        const muted = Theme.withFg(ground, t.muted.fg);
        const accent = Theme.withFg(ground, t.accent.fg);

        // The gutter: a lock, a repo's or a session's accent, or the
        // cursor's marker.
        var gutter: ?[]const u8 = null;
        var gutter_style = ground;
        switch (row) {
            .repo => |rp| if (rp.accent) |repo_accent| {
                gutter = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
                gutter_style = Theme.withFg(ground, repo_accent);
            },
            .worktree => |wt| if (wt.locked) {
                gutter = g(ui, lock_nerd, lock_ascii);
                gutter_style = Theme.withFg(ground, pal.yellow);
            } else if (wt.accent) |session_accent| {
                gutter = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
                gutter_style = Theme.withFg(ground, session_accent);
            },
            else => {},
        }
        if (gutter == null and at_cursor) {
            gutter = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
            gutter_style = Theme.withFg(ground, if (focused) t.accent.fg else t.muted.fg);
        }
        if (gutter) |gl| _ = ui.putStr(rr.x, y, 1, gl, gutter_style);

        // The right-edge cells, one cell in from the edge.
        var right_text: []const u8 = "";
        var right_style = ground;
        var dot = false;
        switch (row) {
            .section => |s| {
                right_text = ui.fmt("{d}", .{s.count});
                right_style = accent;
            },
            .branch => |b| if (b.current) {
                right_text = trackText(ui, b.ahead, b.behind);
            },
            .worktree => |wt| {
                dot = wt.dirty;
                if (wt.current) right_text = trackText(ui, wt.ahead, wt.behind);
            },
            else => {},
        }
        const dot_w: u16 = if (dot) (if (right_text.len > 0) 2 else 1) else 0;
        const right_w: u16 = ui.width(right_text) + dot_w;
        const right_x: u16 = if (right_w > 0) end -| (right_w + 1) else end;

        // The row's text from its indent; under a repo sub-header the
        // item rows sit one level further in.
        var x: u16 = rr.x;
        const nest: u16 = if (p.grouped) 2 else 0;
        switch (row) {
            .gap => {},
            .repo => |rp| {
                x += 2;
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(rp.name, (right_x -| 1) -| x), muted);
            },
            .section => |s| {
                x += 1;
                x += ui.putStr(x, y, right_x -| x, expander.slot(ui, !s.collapsed), expander.style(ui, ground));
                x += ui.putStr(x, y, right_x -| x, sectionGlyph(ui, s.s), muted);
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                var ls = muted;
                ls.bold = true;
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(s.s.label(), (right_x -| 1) -| x), ls);
            },
            .branch => |b| {
                x += 2 + nest;
                x += ui.putStr(x, y, right_x -| x, if (b.current) g(ui, current_branch_nerd, current_branch_ascii) else g(ui, branch_nerd, branch_ascii), Theme.withFg(ground, if (b.current) pal.green else pal.purple));
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                var ns = Theme.withFg(ground, t.fg.fg);
                ns.bold = b.current;
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(b.name, (right_x -| 1) -| x), ns);
            },
            .remote => |m| {
                x += 2 + nest;
                x += ui.putStr(x, y, right_x -| x, if (m.github) g(ui, github_nerd, github_ascii) else g(ui, forge_nerd, forge_ascii), accent);
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(m.name, (right_x -| 1) -| x), Theme.withFg(ground, t.fg.fg));
            },
            .remote_branch => |rb| {
                x += 4 + nest;
                x += ui.putStr(x, y, right_x -| x, g(ui, branch_nerd, branch_ascii), Theme.withFg(ground, pal.purple));
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(rb.shown, (right_x -| 1) -| x), Theme.withFg(ground, t.fg.fg));
            },
            .worktree => |wt| {
                x += 2 + nest;
                x += ui.putStr(x, y, right_x -| x, if (wt.main) g(ui, home_nerd, home_ascii) else g(ui, tree_nerd, tree_ascii), Theme.withFg(ground, if (wt.main) pal.yellow else pal.green));
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                var ns = Theme.withFg(ground, t.fg.fg);
                ns.bold = wt.current;
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(wt.shown, (right_x -| 1) -| x), ns);
            },
            .stash => |s| {
                x += 2 + nest;
                x += ui.putStr(x, y, right_x -| x, s.sha, muted);
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(s.message, (right_x -| 1) -| x), Theme.withFg(ground, t.fg.fg));
            },
            .tag => |tg| {
                x += 2 + nest;
                x += ui.putStr(x, y, right_x -| x, g(ui, tag_nerd, tag_ascii), Theme.withFg(ground, pal.orange));
                x += ui.putStr(x, y, right_x -| x, " ", ground);
                _ = ui.putStr(x, y, (right_x -| 1) -| x, ui.clipStr(tg.name, (right_x -| 1) -| x), Theme.withFg(ground, t.fg.fg));
            },
        }

        // The right-edge cells.
        if (right_w > 0 and right_x > rr.x) {
            var rx = right_x;
            if (right_text.len > 0) {
                switch (row) {
                    .section => rx += ui.putStr(rx, y, end -| rx, right_text, right_style),
                    else => {
                        // `1↑` in green, `3↓` in orange.
                        var it = std.mem.splitScalar(u8, right_text, ' ');
                        while (it.next()) |part| {
                            const behind = std.mem.endsWith(u8, part, behind_arrow) or (ui.ascii and std.mem.endsWith(u8, part, "v"));
                            rx += ui.putStr(rx, y, end -| rx, part, Theme.withFg(ground, if (behind) pal.orange else pal.green));
                            if (it.peek() != null) rx += ui.putStr(rx, y, end -| rx, " ", ground);
                        }
                    },
                }
            }
            if (dot) {
                if (right_text.len > 0) rx += ui.putStr(rx, y, end -| rx, " ", ground);
                _ = ui.putStr(rx, y, end -| rx, if (ui.ascii) dirty_dot_ascii else dirty_dot, accent);
            }
        }
        if (row.isStop()) ui.hit(rr, .{ .row = .{ .panel = .git, .idx = @intCast(idx) } });
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");
/// The pill row of the spec: the name, the dropdown mark, the tab
/// strip's two arrows after a cell of air (none at 20 cells).
// The pill on the left, the chevrons anchored at the column's right
// edge (26 cells: glyphs at x = 20 and 23, one blank cell after).
const pill_ws = "  ws " ++ repo_chevron_nerd ++ "              " ++ bufferline.arrow_left_glyph ++ "  " ++ bufferline.arrow_right_glyph;
const pill_all = "  All repos " ++ repo_chevron_nerd ++ "       " ++ bufferline.arrow_left_glyph ++ "  " ++ bufferline.arrow_right_glyph;
// 20 cells: no air — the pill's trailing space is clipped, the chevrons
// at the edge (glyphs at x = 14 and 17).
const pill_all_narrow = "  All repos " ++ repo_chevron_nerd ++ " " ++ bufferline.arrow_left_glyph ++ "  " ++ bufferline.arrow_right_glyph;
// 16 cells: the pill, then the chevrons at the edge (glyphs at x = 10 and 13).
const pill_ws_16 = "  ws " ++ repo_chevron_nerd ++ "    " ++ bufferline.arrow_left_glyph ++ "  " ++ bufferline.arrow_right_glyph;

/// The panel of the doc comment: two locals, one remote with three
/// branches, two worktrees (one locked, one dirty), a stash, two tags.
pub const spec_rows = [_]Row{
    .{ .section = .{ .s = .local, .count = 2, .collapsed = false } },
    .{ .branch = .{ .idx = 0, .name = "main", .current = true, .ahead = 1, .behind = 3 } },
    .{ .branch = .{ .idx = 1, .name = "feature", .current = false } },
    .gap,
    .{ .section = .{ .s = .remote, .count = 3, .collapsed = false } },
    .{ .remote = .{ .idx = 0, .name = "origin", .github = true } },
    .{ .remote_branch = .{ .idx = 2, .name = "origin/main", .shown = "main" } },
    .{ .remote_branch = .{ .idx = 3, .name = "origin/feature", .shown = "feature" } },
    .{ .remote_branch = .{ .idx = 4, .name = "origin/hotfix", .shown = "hotfix" } },
    .gap,
    .{ .section = .{ .s = .worktrees, .count = 2, .collapsed = false } },
    .{ .worktree = .{ .idx = 0, .shown = "ws", .main = true, .current = true, .locked = false, .dirty = false, .ahead = 1, .behind = 3 } },
    .{ .worktree = .{ .idx = 1, .shown = "fix (wt-fix)", .main = false, .current = false, .locked = true, .dirty = true } },
    .gap,
    .{ .section = .{ .s = .stashes, .count = 1, .collapsed = false } },
    .{ .stash = .{ .idx = 0, .sha = "ab12cd3", .message = "On main: half done" } },
    .gap,
    .{ .section = .{ .s = .tags, .count = 2, .collapsed = true } },
    .gap,
};

fn viewing(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |r| if (r.isItem()) {
        n += 1;
    };
    return n;
}

test "the spec's column at 26 cells: the caps header with its refresh chip, the filter, the pill with the chevrons, Viewing N, then every section with its glyph, its count at the edge, the checked-out branch's glyph, the lock, the dot and the ahead / behind; every stop a hit" {
    var f = try Fixture.init(26, 26);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = viewing(&spec_rows) });
    try f.expectRow(0, " GIT                    \u{eb37}");
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "");
    try f.expectRow(3, pill_ws);
    try f.expectRow(4, " Viewing 8");
    try f.expectRow(5, "");
    // The cursor rests on the first row: its muted marker in the gutter.
    try f.expectRow(6, "\u{258c}\u{F47C} \u{F0322} LOCAL              2");
    try f.expectRow(7, "  \u{F14CF} main            1\u{2191} 3\u{2193}");
    try f.expectRow(8, "  \u{F062C} feature");
    try f.expectRow(9, "");
    try f.expectRow(10, " \u{F47C} \u{F015F} REMOTE             3");
    try f.expectRow(11, "  \u{F02A4} origin");
    try f.expectRow(12, "    \u{F062C} main");
    try f.expectRow(13, "    \u{F062C} feature");
    try f.expectRow(14, "    \u{F062C} hotfix");
    try f.expectRow(15, "");
    try f.expectRow(16, " \u{F47C} \u{F0405} WORKTREES          2");
    try f.expectRow(17, "  \u{F02DC} ws              1\u{2191} 3\u{2193}");
    try f.expectRow(18, "\u{F033E} \u{F0405} fix (wt-fix)        \u{25CF}");
    try f.expectRow(19, "");
    try f.expectRow(20, " \u{F47C} \u{F03D7} STASHES            1");
    try f.expectRow(21, "  ab12cd3 On main: half \u{2026}");
    try f.expectRow(22, "");
    try f.expectRow(23, " \u{F460} \u{F04FB} TAGS               2");
    try f.expectRow(24, "");
    // Hits: the header's chip is the `.git` refresh, the filter, the
    // pill over its cells with the chevrons dim and inert at one repo
    // (nothing else on that row), the rows; the gaps none.
    const ChipKind = @import("hit.zig").ChipKind;
    const PanelId = @import("hit.zig").PanelId;
    try testing.expectEqual(ChipKind.refresh, f.hits.at(24, 0).?.chip.kind);
    try testing.expectEqual(PanelId.git, f.hits.at(24, 0).?.chip.panel);
    try testing.expect(f.hits.at(10, 0) == null);
    try testing.expectEqual(PanelId.git, f.hits.at(10, 1).?.filter_input);
    try testing.expectEqual(Part.repo, f.hits.at(2, 3).?.git_palette);
    try testing.expect(f.hits.at(0, 3) == null);
    try testing.expect(f.hits.at(20, 3) == null);
    try testing.expect(f.hits.at(23, 3) == null);
    try testing.expect(f.hits.at(25, 3) == null);
    try testing.expect(f.style(20, 3).dim);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 6).?.row.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(25, 7).?.row.idx);
    try testing.expect(f.hits.at(5, 9) == null);
    try testing.expectEqual(@as(u32, 5), f.hits.at(3, 11).?.row.idx);
    try testing.expectEqual(@as(u32, 17), f.hits.at(3, 23).?.row.idx);
    // Colours: N and the counts in the accent; the checked-out branch's
    // glyph and the ahead in green, the behind in orange, the lock in
    // yellow, the dot in the accent. No row paints a ground of its own
    // — the checked-out branch and the worktree on show sit on the
    // panel's, told by the glyph and a bold name; the gutter is empty
    // on both (no check column).
    try testing.expect(f.fgEql(9, 4, f.theme.accent));
    try testing.expect(f.fgEql(24, 6, f.theme.accent));
    try testing.expect(f.fgEql(2, 7, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(20, 7, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(23, 7, .{ .fg = f.theme.palette.orange }));
    try testing.expect(f.fgEql(0, 18, .{ .fg = f.theme.palette.yellow }));
    try testing.expect(f.fgEql(24, 18, f.theme.accent));
    try testing.expect(f.bgEql(0, 7, f.theme.panel_bg));
    try testing.expect(f.bgEql(25, 7, f.theme.panel_bg));
    try testing.expect(f.bgEql(0, 8, f.theme.panel_bg));
    try testing.expect(f.bgEql(0, 17, f.theme.panel_bg));
    try testing.expect(f.bgEql(25, 17, f.theme.panel_bg));
    try testing.expectEqualStrings(" ", f.cell(0, 7).char.grapheme);
    try testing.expectEqualStrings(" ", f.cell(0, 17).char.grapheme);
    try testing.expect(f.style(4, 7).bold);
    try testing.expect(!f.style(4, 8).bold);
    try testing.expect(f.style(4, 17).bold);
    try testing.expect(!f.style(4, 18).bold);
}

test "the chevrons: lit and clickable with two repos (prev, next), dim and inert with one; a pill too wide for them paints alone" {
    var f = try Fixture.init(26, 8);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .repo_count = 2 });
    try f.expectRow(3, pill_ws);
    // Anchored right: the slots are 19..21 and 22..24; the pill stops
    // short of them, and the cell between is nobody's.
    try testing.expectEqual(Part.repo_prev, f.hits.at(19, 3).?.git_palette);
    try testing.expectEqual(Part.repo_prev, f.hits.at(21, 3).?.git_palette);
    try testing.expectEqual(Part.repo_next, f.hits.at(22, 3).?.git_palette);
    try testing.expectEqual(Part.repo_next, f.hits.at(24, 3).?.git_palette);
    try testing.expect(f.hits.at(18, 3) == null);
    try testing.expect(f.hits.at(25, 3) == null);
    try testing.expect(!f.style(20, 3).dim);
    try testing.expect(f.bgEql(20, 3, .{ .bg = f.theme.palette.bg2 }));
    // One repo: the glyphs stay, dim, and take no click.
    var one = try Fixture.init(26, 8);
    defer one.deinit();
    _ = draw(one.ui(), one.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .repo_count = 1 });
    try one.expectRow(3, pill_ws);
    try testing.expect(one.hits.at(20, 3) == null);
    try testing.expect(one.hits.at(23, 3) == null);
    try testing.expect(one.style(20, 3).dim);
    // A name that leaves no room: the pill alone, clipped one cell in.
    var long = try Fixture.init(26, 8);
    defer long.deinit();
    _ = draw(long.ui(), long.full(), .{ .rows = &spec_rows, .repo = "a-rather-long-repo", .viewing = 8, .repo_count = 2 });
    var buf: [128]u8 = undefined;
    const row = long.row(3, &buf);
    try testing.expect(std.mem.indexOf(u8, row, "\u{F0141}") == null);
    try testing.expect(std.unicode.utf8CountCodepoints(row) catch 0 <= 25);
    try testing.expect(long.hits.at(2, 3).?.git_palette == .repo);
    var x: u16 = 0;
    while (x < 26) : (x += 1) if (long.hits.at(x, 3)) |h| try testing.expect(h.git_palette == .repo);
}

test "all repos: a muted sub-header per repo under each section, the rows one level further in, the current marks per repo" {
    var f = try Fixture.init(26, 14);
    defer f.deinit();
    const grouped = [_]Row{
        .{ .section = .{ .s = .local, .count = 3, .collapsed = false } },
        .{ .repo = .{ .idx = 0, .name = "alpha" } },
        .{ .branch = .{ .idx = 0, .name = "main", .current = true, .ahead = 1 } },
        .{ .branch = .{ .idx = 1, .name = "feature", .current = false } },
        .{ .repo = .{ .idx = 1, .name = "beta" } },
        .{ .branch = .{ .idx = 0, .name = "dev", .current = true } },
        .gap,
    };
    _ = draw(f.ui(), f.full(), .{ .rows = &grouped, .repo = "All repos", .viewing = 3, .repo_count = 2, .grouped = true, .cursor = 2 });
    try f.expectRow(3, pill_all);
    try f.expectRow(6, " \u{F47C} \u{F0322} LOCAL              3");
    try f.expectRow(7, "  alpha");
    try f.expectRow(8, "\u{258c}   \u{F14CF} main             1\u{2191}");
    try f.expectRow(9, "    \u{F062C} feature");
    try f.expectRow(10, "  beta");
    try f.expectRow(11, "    \u{F14CF} dev");
    try testing.expect(f.fgEql(2, 7, f.theme.muted));
    try testing.expect(f.bgEql(0, 8, f.theme.cursor_line));
    try testing.expect(f.bgEql(0, 11, f.theme.panel_bg));
    // The sub-header is a stop with a row hit; the section count is the sum.
    try testing.expectEqual(@as(u32, 1), f.hits.at(4, 7).?.row.idx);
    try testing.expectEqual(@as(u32, 4), f.hits.at(4, 10).?.row.idx);
    // The 20-cell column git mode snaps to at 120x40: the chevrons
    // close up against the pill rather than drop.
    var narrow = try Fixture.init(20, 8);
    defer narrow.deinit();
    _ = draw(narrow.ui(), narrow.full(), .{ .rows = &grouped, .repo = "All repos", .viewing = 3, .repo_count = 2, .grouped = true });
    try narrow.expectRow(3, pill_all_narrow);
    try testing.expectEqual(Part.repo_prev, narrow.hits.at(14, 3).?.git_palette);
    try testing.expectEqual(Part.repo_next, narrow.hits.at(17, 3).?.git_palette);
    try testing.expectEqual(Part.repo, narrow.hits.at(12, 3).?.git_palette);
    try testing.expect(narrow.hits.at(19, 3) == null);
}

test "the cursor row takes the list panels' ground and marker, or keeps its gutter mark; the focused filter shows its caret; a folded section keeps only its header" {
    var f = try Fixture.init(26, 26);
    defer f.deinit();
    var ui = f.ui();
    ui.focus = .{ .panel = .git };
    var p = draw(ui, f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .cursor = 2, .filter = "ma", .filter_caret = 2, .filter_focused = true });
    try f.expectRow(1, "  \u{F0349} ma");
    try testing.expectEqual(Caret{ .x = 6, .y = 1 }, p.caret.?);
    try f.expectRow(8, "\u{258c} \u{F062C} feature");
    try testing.expect(f.bgEql(0, 8, f.theme.cursor_line));
    try testing.expect(f.bgEql(25, 8, f.theme.cursor_line));
    try testing.expect(f.fgEql(0, 8, f.theme.accent));
    // On the checked-out branch the cursor's marker takes the gutter (no
    // check to keep) and its ground is the selection's.
    p = draw(ui, f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .cursor = 1 });
    try f.expectRow(7, "\u{258c} \u{F14CF} main            1\u{2191} 3\u{2193}");
    try testing.expect(f.bgEql(3, 7, f.theme.cursor_line));
    try testing.expect(f.bgEql(3, 8, f.theme.panel_bg));
    // Unfocused, the marker is muted.
    p = draw(f.ui(), f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .cursor = 2 });
    try testing.expect(f.fgEql(0, 8, f.theme.muted));
}

test "the list scrolls as one: the scroll follows the cursor, the scrollbar takes the last column only on overflow, and the header and pill rows never scroll" {
    var f = try Fixture.init(26, 10);
    defer f.deinit();
    // Four list rows of room (10 - 6); the spec has 19.
    var p = draw(f.ui(), f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8, .cursor = 12 });
    try testing.expectEqual(@as(usize, 4), p.visible);
    try testing.expectEqual(@as(usize, 9), p.scroll);
    try f.expectRow(0, " GIT                    \u{eb37}");
    try f.expectRow(3, pill_ws);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(7, &buf), " \u{F47C} \u{F0405} WORKTREES"));
    try testing.expect(std.mem.startsWith(u8, f.row(9, &buf), "\u{F033E} \u{F0405} fix (wt-fix)"));
    try testing.expect(f.hits.at(25, 7).?.scrollbar.owner.panel == .git);
    try testing.expectEqual(@as(u32, 10), f.hits.at(24, 7).?.row.idx);
    // A short list: no bar, the last column is the row's.
    const few = spec_rows[0..3];
    p = draw(f.ui(), f.full(), .{ .rows = few, .repo = "ws", .viewing = 2 });
    try testing.expectEqual(@as(usize, 0), p.scroll);
    try testing.expectEqual(@as(u32, 1), f.hits.at(25, 7).?.row.idx);
    try f.expectRow(7, "  \u{F14CF} main            1\u{2191} 3\u{2193}");
}

test "narrow columns: at 16, 20 and 24 cells nothing paints past the edge, the count wins over the label, names clip with an ellipsis" {
    const long_rows = [_]Row{
        .{ .section = .{ .s = .worktrees, .count = 12, .collapsed = false } },
        .{ .worktree = .{ .idx = 0, .shown = "a-rather-long-branch-name (a-rather-long-dir)", .main = false, .current = true, .locked = false, .dirty = true, .ahead = 10, .behind = 2 } },
        .{ .stash = .{ .idx = 0, .sha = "ab12cd3", .message = "On main: a message that runs well past the column" } },
    };
    for ([_]u16{ 16, 20, 24 }) |w| {
        var f = try Fixture.init(w, 9);
        defer f.deinit();
        _ = draw(f.ui(), f.full(), .{ .rows = &long_rows, .repo = "a-long-repo-name", .viewing = 2 });
        var buf: [256]u8 = undefined;
        var y: u16 = 0;
        while (y < 9) : (y += 1) {
            const row = f.row(y, &buf);
            try testing.expect(std.unicode.utf8CountCodepoints(row) catch 0 <= w);
        }
        // The section header: the count sits one cell in from the edge.
        const hdr = f.row(6, &buf);
        try testing.expect(std.mem.endsWith(u8, hdr, "12"));
        try testing.expect(f.fgEql(w - 2, 6, f.theme.accent));
        // The worktree row ends in `10↑ 2↓ ●`; the name before it is clipped.
        const wt = f.row(7, &buf);
        try testing.expect(std.mem.endsWith(u8, wt, "10\u{2191} 2\u{2193} \u{25CF}"));
        try testing.expect(std.mem.indexOf(u8, wt, "\u{2026}") != null);
        try testing.expect(std.mem.startsWith(u8, wt, "  \u{F0405} a"));
        // The stash row clips its message.
        const st = f.row(8, &buf);
        try testing.expect(std.mem.endsWith(u8, st, "\u{2026}"));
        try testing.expect(std.mem.startsWith(u8, st, "  ab12cd3 "));
    }
    // 16 cells: the header keeps its chip, the pill and its chevrons
    // still fit; WORKTREES gives way to the count.
    var f = try Fixture.init(16, 9);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .rows = &long_rows, .repo = "ws", .viewing = 2, .repo_count = 2 });
    try f.expectRow(0, " GIT          \u{eb37}");
    try f.expectRow(3, pill_ws_16);
    try testing.expectEqual(@import("hit.zig").ChipKind.refresh, f.hits.at(14, 0).?.chip.kind);
    // 16 cells: prev over 9..11, next over 12..14, the edge cell free.
    try testing.expectEqual(Part.repo_prev, f.hits.at(9, 3).?.git_palette);
    try testing.expectEqual(Part.repo_next, f.hits.at(12, 3).?.git_palette);
    try testing.expect(f.hits.at(15, 3) == null);
    try f.expectRow(6, "\u{258c}\u{F47C} \u{F0405} WORKTR\u{2026} 12");
}

test "ascii: every glyph has a one-cell twin and the row shapes hold" {
    var f = try Fixture.init(26, 26);
    defer f.deinit();
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, f.full(), .{ .rows = &spec_rows, .repo = "ws", .viewing = 8 });
    try f.expectRow(0, " GIT                    \u{21ba}");
    try f.expectRow(1, "  / / filter");
    try f.expectRow(3, "  ws v              <  >");
    try f.expectRow(6, ">v % LOCAL              2");
    try f.expectRow(7, "  * main            1^ 3v");
    try f.expectRow(11, "  G origin");
    try f.expectRow(17, "  @ ws              1^ 3v");
    try f.expectRow(18, "! ^ fix (wt-fix)        o");
    try f.expectRow(23, " > # TAGS               2");
    try testing.expectEqualStrings("", trackText(ui, 0, 0));
    try testing.expectEqualStrings("2v", trackText(ui, 0, 2));
}

test "a cell of air before the bar at 26 cells: a section's count, a long branch name's ellipsis and the ahead / behind all stop a cell short of it" {
    var f = try Fixture.init(26, 12);
    defer f.deinit();
    var rows: [14]Row = undefined;
    rows[0] = .{ .section = .{ .s = .local, .count = 13, .collapsed = false } };
    for (1..14) |i| rows[i] = .{ .branch = .{ .idx = @intCast(i - 1), .name = "a-long-branch-name-that-overflows", .current = i == 1, .ahead = 12, .behind = 3 } };
    const p = draw(f.ui(), f.full(), .{ .rows = &rows, .repo = "ws", .viewing = 13, .cursor = 2 });
    try testing.expectEqual(@as(usize, 6), p.visible);
    try f.expectAirBeforeBar(head_rows, 12, 25);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(6, &buf), "13 █"));
    try testing.expect(std.mem.endsWith(u8, f.row(7, &buf), "12\u{2191} 3\u{2193} █"));
    try testing.expect(std.mem.endsWith(u8, f.row(8, &buf), "… █"));
    try testing.expect(f.hits.at(25, 8).? == .scrollbar);
}
