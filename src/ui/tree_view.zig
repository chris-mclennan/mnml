//! The file tree sidebar — the Rust editor's look (`ui/tree_view.rs`)
//! painted on the component system (D6). The app hands the painter a
//! flat list of items, one per row: a workspace section's header, an
//! entry under it, the blank row between sections, and the `Add
//! workspace` row that trails them. Every hit is registered in the same
//! statement as its cells.
//!
//! The primary header is the expander, then ` ~/path/` in bold green with the action
//! chips right-aligned — new folder, new file, pull, collapse / expand,
//! then the refresh chip — dropped from the right of the cluster until
//! the label and the refresh chip fit, one cell of margin kept clear at
//! the edge. An extra workspace (`[[workspaces]]`) is its expander and ` name ` alone.
//!
//! An entry is ` ` + indent + connector + chevron + icon + name, the git
//! badge right-aligned (a cell of air between it, or a long name, and the
//! scrollbar): two cells of indent per level, a `│` down every
//! ancestor level that has siblings to come (levels 2 and up — the top
//! level draws none, as neo-tree), the chevron slot of a file row taking
//! `│` or `└` under the parent's folder icon. The connectors are mnml's
//! own baked glyphs (U+F1F04 / U+F1F05: JetBrainsMono's `│` / `└`
//! shifted right so they meet the chevron above), the chevrons
//! `expander.zig`'s pair in its colour, the file icons `icons.zig`.
//! Every glyph has its `ui.ascii_icons` twin beside it. The cursor row
//! carries the list panels' marker (`▌`, the accent when the tree has
//! the keys, muted otherwise) in its leading cell — the cell that
//! otherwise keeps the rail's ground on every row.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const icons = @import("icons.zig");
const chip_mod = @import("chip.zig");
const scrollbar = @import("scrollbar.zig");
const list_panel = @import("list_panel.zig");
const focus_cue = @import("focus_cue.zig");
const expander = @import("expander.zig");

const Style = vaxis.Style;

// ── glyphs ──

/// mnml's baked `│` and `└`, shifted right to sit under the chevron.
pub const cont_glyph = "\u{F1F04}";
pub const cont_ascii = "|";
pub const corner_glyph = "\u{F1F05}";
pub const corner_ascii = "\\";
/// codicon new-folder / new-file, as the patched font draws them.
pub const new_folder_glyph = "\u{EA80}";
pub const new_folder_ascii = "d+";
pub const new_file_glyph = "\u{EA7F}";
pub const new_file_ascii = "f+";
/// codicon repo-pull — the git graph's Pull button's glyph.
pub const pull_glyph = "\u{EB40}";
pub const pull_ascii = "↓";
/// codicon collapse-all / nf-md-expand_all: the toggle's two faces.
pub const collapse_all_glyph = "\u{EAC5}";
pub const collapse_all_ascii = "↕";
pub const expand_all_glyph = "\u{F0AB4}";
pub const expand_all_ascii = "↧";
/// nf-md-plus_box on the `Add workspace` row.
pub const add_workspace_glyph = "\u{F0419}";
pub const add_workspace_ascii = "+";

/// The primary header's chips and the `Add workspace` row, as click
/// targets (`HitTarget.tree_chip`). The app maps each to its command.
pub const Chip = enum {
    new_folder,
    new_file,
    pull,
    collapse,
    refresh,
    add_workspace,

    /// The header cluster, left to right; the refresh chip stands
    /// apart on the right and survives the cluster's chips.
    pub const cluster = [_]Chip{ .new_folder, .new_file, .pull, .collapse };

    pub fn glyph(c: Chip, fully_collapsed: bool, ascii: bool) []const u8 {
        return switch (c) {
            .new_folder => if (ascii) new_folder_ascii else new_folder_glyph,
            .new_file => if (ascii) new_file_ascii else new_file_glyph,
            .pull => if (ascii) pull_ascii else pull_glyph,
            .collapse => if (fully_collapsed) (if (ascii) expand_all_ascii else expand_all_glyph) else (if (ascii) collapse_all_ascii else collapse_all_glyph),
            .refresh => if (ascii) chip_mod.refresh_icon_ascii else chip_mod.refresh_icon_nerd,
            .add_workspace => if (ascii) add_workspace_ascii else add_workspace_glyph,
        };
    }

    /// The tooltip word (Rust `tooltip.rs`).
    pub fn label(c: Chip, fully_collapsed: bool) []const u8 {
        return switch (c) {
            .new_folder => "new folder",
            .new_file => "new file",
            .pull => "pull",
            .collapse => if (fully_collapsed) "expand all" else "collapse all",
            .refresh => "refresh tree",
            .add_workspace => "add workspace folder",
        };
    }

    fn color(c: Chip, t: *const Theme) vaxis.Color {
        const pal = t.palette;
        return switch (c) {
            .new_folder => pal.blue,
            .new_file => pal.yellow,
            .pull => pal.green,
            .collapse => pal.teal,
            .refresh => pal.cyan,
            .add_workspace => pal.green,
        };
    }
};

/// Each chip is ` <glyph> `.
pub const chip_w: u16 = 3;
/// The cell kept clear at the header's right edge (the scrollbar's column).
const right_margin: u16 = 1;
/// What the primary header keeps for its cluster when clipping the
/// label: five chips and a cell of separation.
const chip_reserve: u16 = 5 * chip_w + 1;
/// The `Add workspace` row's label.
const add_label = " Add workspace";

/// A file's git state (Rust `FileState`), for the badge and the name's colour.
/// A row's git badge. The staged states keep the index's letter — a
/// staged modification is `M`, a staged new file `A`, a staged rename
/// `R`, as the status pane on the same screen says (every staged file
/// read `A`, a modified one included).
pub const GitState = enum { modified, staged, added, renamed, untracked, conflicted };

/// A repo row's marker: lit when the repo is the active one; `accent` —
/// the repo's colour (`app/git_palette.zig`) — paints the dot when set.
pub const RepoMark = struct { active: bool, accent: ?vaxis.Color = null };

/// A workspace section's header row.
pub const Section = struct {
    /// 0 = the primary workspace, i + 1 = the i-th extra root.
    root: u8,
    /// The primary's `~/path/`; an extra's name.
    label: []const u8,
    expanded: bool,
    /// The primary shows hidden files: its label is italic.
    italic: bool = false,
    /// Every directory closed: the toggle chip shows expand-all.
    fully_collapsed: bool = false,
};

/// A file or directory row.
pub const Entry = struct {
    /// The row's index in the app's tree — the hit payload.
    idx: u32,
    name: []const u8,
    /// 0 = a root's direct child.
    depth: u8,
    is_dir: bool,
    expanded: bool = false,
    git: ?GitState = null,
    /// Open in an editor with unsaved changes: `●` beats the git badge.
    dirty: bool = false,
    /// A depth-0 directory that is its own repo in a multi-repo
    /// workspace: the repo glyph, tinted; `active` marks the active one.
    repo: ?RepoMark = null,
    /// A git-ignored entry shown by `tree.toggle_ignored`: dim.
    ignored: bool = false,
};

pub const Item = union(enum) {
    section: Section,
    entry: Entry,
    /// The separator row between sections.
    blank,
    /// The `+ Add workspace` row under the last section.
    add_workspace,
};

pub const Props = struct {
    items: []const Item,
    /// Index into `items` of the cursor row.
    cursor: ?usize = null,
    focused: bool = false,
    /// The first item painted.
    scroll: usize = 0,
    /// `ui.show_workspace_dots`: `● ` / `○ ` after a section's chevron.
    show_dots: bool = false,
};

pub const Layout = struct {
    /// The items that got a row.
    painted: usize = 0,
    /// A scrollbar took the last column.
    overflow: bool = false,
};

/// The items a scrollbar counts: the primary section — its header and
/// its entries. Rust scrolls the primary's file list alone; the extra
/// sections below it and the `Add workspace` row paint when they fit.
pub fn contentLen(items: []const Item) usize {
    var n: usize = 0;
    for (items) |it| switch (it) {
        .section => |s| if (s.root != 0) break,
        .entry => {},
        else => break,
    } else return items.len;
    for (items) |it| {
        if (it == .blank or it == .add_workspace) break;
        if (it == .section and it.section.root != 0) break;
        n += 1;
    }
    return n;
}

pub fn draw(ui: Ui, area: Rect, p: Props) Layout {
    var out: Layout = .{};
    if (area.isEmpty()) return out;
    const t = ui.theme;
    const rail_bg = t.palette.bg_darker;
    ui.fill(area, Theme.onBg(t.fg, rail_bg));
    out.overflow = contentLen(p.items) > area.h;
    const sb_w: u16 = if (out.overflow) 1 else 0;
    var y: u16 = 0;
    var i = p.scroll;
    while (i < p.items.len and y < area.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = area.row(y);
        const is_cursor = if (p.cursor) |c| c == i else false;
        switch (p.items[i]) {
            .section => |s| drawSection(ui, r, sb_w, s, p, is_cursor),
            .entry => |e| drawEntry(ui, r, sb_w, p.items, i, e, is_cursor, p),
            .blank => {},
            .add_workspace => drawAddRow(ui, r),
        }
        if (is_cursor) drawMarker(ui, r, p.focused);
    }
    out.painted = i - p.scroll;
    // right-click: the rows below the last item belong to the last
    // section painted — a right press there opens its workspace menu,
    // as VS Code's empty Explorer space does.
    if (y < area.h) ui.hit(Rect.init(area.x, area.y + y, area.w -| sb_w, area.h - y), .{ .tree_empty = lastRoot(p.items, i) });
    if (out.overflow) scrollbar.drawVertical(ui, Rect.init(area.right() - 1, area.y, 1, area.h), .tree, contentLen(p.items), area.h, p.scroll);
    return out;
}

/// The cursor row's marker in the leading cell: the list panels' `▌`,
/// the accent when the tree is focused, muted otherwise. The cell
/// keeps the rail's ground under it (a row's highlight still starts at
/// the second cell); only the cursor row gets the glyph.
fn drawMarker(ui: Ui, r: Rect, focused: bool) void {
    const t = ui.theme;
    const marker = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    _ = ui.putStr(r.x, r.y, 1, marker, Theme.onBg(Theme.withFg(t.fg, if (focused) t.accent.fg else t.muted.fg), t.palette.bg_darker));
}

/// The root of the last section at or before item `end`.
fn lastRoot(items: []const Item, end: usize) u8 {
    var i = @min(end, items.len);
    while (i > 0) {
        i -= 1;
        if (items[i] == .section) return items[i].section.root;
    }
    return 0;
}

/// The expander + [`● `] + label; the primary adds the chip cluster.
fn drawSection(ui: Ui, r: Rect, sb_w: u16, s: Section, p: Props, is_cursor: bool) void {
    const t = ui.theme;
    const pal = t.palette;
    const rail_bg = pal.bg_darker;
    const bg = if (is_cursor and p.focused) pal.bg2 else rail_bg;
    // The whole row folds the section; the chips register after it and win.
    ui.hit(r, .{ .tree_root = s.root });
    if (is_cursor and p.focused) ui.fill(Rect.init(r.x + 1, r.y, r.w -| 1, 1), Theme.onBg(t.fg, bg));
    const primary = s.root == 0;
    // The leading cell keeps the rail's ground, as an entry's does.
    var x = r.x + 1;
    x += ui.putStr(x, r.y, r.right() -| x, expander.slot(ui, s.expanded), expander.style(ui, Theme.onBg(t.fg, bg)));
    if (p.show_dots) {
        const dot: []const u8 = if (primary) (if (ui.ascii) "* " else "● ") else (if (ui.ascii) "o " else "○ ");
        x += ui.putStr(x, r.y, r.right() -| x, dot, Theme.onBg(Theme.withFg(t.fg, if (primary) pal.green else pal.comment), bg));
    }
    // The label's room: the primary keeps the cluster's, an extra four
    // cells — and a cell of air before the bar.
    const max_label: u16 = @max(4, if (primary) r.w -| (3 + 2 + chip_reserve) else r.w -| 4 -| sb_w);
    const label = ui.clipStr(s.label, max_label);
    var style = Theme.onBg(Theme.withFg(t.fg, if (primary) pal.green else pal.fg), bg);
    style.bold = true;
    // The focus cue: a workspace header is the tree's title, dim while
    // the keys are somewhere else (`focus_cue.words`).
    style = focus_cue.words(t, ui.focus_cue, p.focused, style);
    style.italic = s.italic;
    const label_w = ui.putStr(x, r.y, r.right() -| x, label, style);
    if (primary) drawChips(ui, r, 3 + 2 + label_w, s.fully_collapsed, rail_bg);
}

/// The primary header's right-aligned cluster. `label_used` is what
/// the chevron, the dot slot and the label took: chips leave from the
/// right of the cluster until the label, a cell of separation, the
/// cluster, the refresh chip and the margin fit.
fn drawChips(ui: Ui, r: Rect, label_used: u16, fully_collapsed: bool, rail_bg: vaxis.Color) void {
    const t = ui.theme;
    const w = r.w;
    var n: u16 = Chip.cluster.len;
    while (n > 0 and label_used + 1 + n * chip_w + chip_w + right_margin > w) n -= 1;
    const show_refresh = w >= label_used + 1 + chip_w + right_margin;
    const cluster_w = n * chip_w + @as(u16, if (show_refresh) chip_w else 0);
    if (cluster_w == 0) return;
    var x = r.x + (w - (cluster_w + right_margin));
    for (Chip.cluster[0..n]) |c| {
        const cell = Rect.init(x, r.y, chip_w, 1);
        _ = ui.putStr(x, r.y, chip_w, ui.fmt(" {s} ", .{c.glyph(fully_collapsed, ui.ascii)}), Theme.onBg(Theme.withFg(t.fg, c.color(t)), rail_bg));
        ui.hit(cell, .{ .tree_chip = c });
        x += chip_w;
    }
    if (show_refresh) {
        const cell = Rect.init(x, r.y, chip_w, 1);
        _ = ui.putStr(x, r.y, chip_w, ui.fmt(" {s} ", .{Chip.refresh.glyph(false, ui.ascii)}), Theme.onBg(Theme.withFg(t.fg, Chip.refresh.color(t)), rail_bg));
        ui.hit(cell, .{ .tree_chip = .refresh });
    }
}

/// The trailing ` <plus> Add workspace` row, right-aligned with a cell
/// of margin. The glyph is counted as two cells (Rust's assumption), so
/// the label ends a cell short of the margin.
fn drawAddRow(ui: Ui, r: Rect) void {
    const t = ui.theme;
    const pal = t.palette;
    const glyph_w: u16 = if (ui.ascii) 1 else 2;
    const total = glyph_w + @as(u16, add_label.len) + right_margin;
    if (r.w < total + 1) return;
    const pad = r.w - total;
    var x = r.x + pad;
    const target = Rect.init(x, r.y, glyph_w + @as(u16, add_label.len), 1);
    x += ui.putStr(x, r.y, r.right() -| x, Chip.add_workspace.glyph(false, ui.ascii), Theme.onBg(Theme.withFg(t.fg, pal.green), pal.bg_darker));
    _ = ui.putStr(x, r.y, r.right() -| x, add_label, Theme.onBg(Theme.withFg(t.fg, pal.comment), pal.bg_darker));
    ui.hit(target, .{ .tree_chip = .add_workspace });
}

/// Whether the entry at `from` has a later sibling at `level` before
/// its section ends — the `│` continues past this row.
fn hasLaterSibling(items: []const Item, from: usize, level: u8) bool {
    var j = from + 1;
    while (j < items.len) : (j += 1) {
        const e = switch (items[j]) {
            .entry => |e| e,
            else => return false,
        };
        if (e.depth < level) return false;
        if (e.depth == level) return true;
    }
    return false;
}

pub fn isLastChild(items: []const Item, i: usize) bool {
    return !hasLaterSibling(items, i, items[i].entry.depth);
}

fn drawEntry(ui: Ui, r: Rect, sb_w: u16, items: []const Item, i: usize, e: Entry, is_cursor: bool, p: Props) void {
    const t = ui.theme;
    const pal = t.palette;
    const rail_bg = pal.bg_darker;
    const lit = is_cursor and p.focused;
    const bg = if (is_cursor) (if (p.focused) pal.bg2 else pal.bg) else rail_bg;
    const trace = if (lit) pal.bg3 else pal.bg2;
    const w = r.w -| sb_w;
    ui.hit(Rect.init(r.x, r.y, w, 1), .{ .tree_node = e.idx });
    // The leading cell keeps the rail's ground so the highlight never
    // touches the activity bar; the row bg runs from the second cell.
    ui.fill(Rect.init(r.x + 1, r.y, w -| 1, 1), Theme.onBg(t.fg, bg));
    var x = r.x + 1;
    const right = r.x + w;
    const trace_style = Theme.onBg(Theme.withFg(t.fg, trace), bg);
    const cont: []const u8 = if (ui.ascii) cont_ascii ++ " " else cont_glyph ++ " ";
    // Indent: two cells under the root, then the ancestor levels. A row
    // too deep for the column drops its outermost levels (nvim-tree's
    // left truncation) behind a `…`, so the chevron, the icon and ~10
    // cells of name always fit: past depth ~11 at the stock width the
    // rows painted as blanks.
    const keep_levels: u8 = @intCast(@min(255, ((right -| x) -| (2 + 4 + 10)) / 2));
    const skip: u8 = e.depth -| keep_levels;
    x += ui.putStr(x, r.y, right -| x, if (skip > 0) (if (ui.ascii) "< " else "\u{2026} ") else "  ", trace_style);
    var level: u16 = @as(u16, skip) + 1;
    while (level < e.depth) : (level += 1) {
        x += ui.putStr(x, r.y, right -| x, if (level >= 2 and hasLaterSibling(items, i, @intCast(level))) cont else "  ", trace_style);
    }
    // The row's own level: bars from level two, spaces at level one.
    if (e.depth >= 1) x += ui.putStr(x, r.y, right -| x, if (e.depth >= 2) cont else "  ", trace_style);
    // The chevron slot: a folder's expander in its own colour, a file's
    // connector in the trace's.
    if (!ui.ascii) {
        if (e.is_dir) {
            x += ui.putStr(x, r.y, right -| x, expander.slot(ui, e.expanded), expander.style(ui, Theme.onBg(t.fg, bg)));
        } else {
            const slot: []const u8 = if (e.depth >= 1) (if (isLastChild(items, i)) corner_glyph ++ " " else cont_glyph ++ " ") else "  ";
            x += ui.putStr(x, r.y, right -| x, slot, trace_style);
        }
    }
    // The icon.
    const icon = if (e.repo != null) icons.repo(e.expanded, ui.ascii) else icons.forName(e.name, e.is_dir, e.expanded, ui.ascii);
    const icon_fg = if (e.repo != null or e.is_dir) pal.yellow else icon.color;
    x += ui.putStr(x, r.y, right -| x, ui.fmt("{s} ", .{icon.glyph}), Theme.onBg(Theme.withFg(t.fg, icon_fg), bg));
    if (e.repo) |rp| if (p.show_dots) {
        const marker: []const u8 = if (rp.active) (if (ui.ascii) "* " else "● ") else (if (ui.ascii) "o " else "○ ");
        x += ui.putStr(x, r.y, right -| x, marker, Theme.onBg(Theme.withFg(t.fg, rp.accent orelse (if (rp.active) pal.green else pal.comment)), bg));
    };
    // The name.
    const name_fg = if (e.repo != null) pal.yellow else if (e.is_dir) pal.blue else if (e.git) |g| switch (g) {
        .modified => pal.yellow,
        .staged, .added, .renamed, .untracked => pal.green,
        .conflicted => pal.red,
    } else pal.fg;
    var name_style = Theme.onBg(Theme.withFg(t.fg, name_fg), bg);
    name_style.bold = e.is_dir or lit;
    name_style.dim = (e.repo != null and !e.repo.?.active) or (e.name.len > 0 and e.name[0] == '.') or e.ignored;
    const badge_w: u16 = if (e.dirty or e.git != null) 2 else 0;
    // The name stops at the badge, or a cell short of the bar.
    const name_end = if (badge_w > 0) right -| badge_w else right -| sb_w;
    _ = ui.putStr(x, r.y, name_end -| x, e.name, name_style);
    if (badge_w > 0 and right >= r.x + 1 + badge_w) {
        const badge: []const u8 = if (e.dirty) (if (ui.ascii) "*" else "●") else switch (e.git.?) {
            .modified, .staged => "M",
            .added => "A",
            .renamed => "R",
            .untracked => "?",
            .conflicted => "!",
        };
        const badge_fg = if (e.dirty) pal.orange else switch (e.git.?) {
            .modified => pal.yellow,
            .staged, .added, .renamed, .untracked => pal.green,
            .conflicted => pal.red,
        };
        _ = ui.putStr(right - badge_w, r.y, badge_w, badge, Theme.onBg(Theme.withFg(t.fg, badge_fg), bg));
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");
fn section(root: u8, label: []const u8, expanded: bool) Item {
    return .{ .section = .{ .root = root, .label = label, .expanded = expanded } };
}

fn entry(idx: u32, name: []const u8, depth: u8, is_dir: bool, expanded: bool) Item {
    return .{ .entry = .{ .idx = idx, .name = name, .depth = depth, .is_dir = is_dir, .expanded = expanded } };
}

const fixture_items = [_]Item{
    section(0, "/private/tmp/ws/", true),
    entry(0, "src", 0, true, true),
    entry(1, "main.rs", 1, false, false),
    .{ .entry = .{ .idx = 2, .name = ".gitignore", .depth = 0, .is_dir = false, .git = .untracked } },
    entry(3, "package.json", 0, false, false),
    entry(4, "README.md", 0, false, false),
    .blank,
    section(1, "mixr", false),
    .blank,
    section(2, "acmeco-claude-workspace", false),
};

test "the spec's rows at 26 columns: header, chips at 17/20/23/26, icons, connectors, the badge in column 24, the extras clipped" {
    var f = try Fixture.init(26, 12);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &fixture_items, .cursor = 1, .focused = true });
    try f.expectRow(0, " \u{F47C} /pri…      \u{EA80}  \u{EA7F}  \u{EB40}  \u{EB37}");
    try f.expectRow(1, "\u{258c}  \u{F47C} \u{F07C} src");
    try f.expectRow(2, "     \u{F1F05} \u{E68B} main.rs");
    try f.expectRow(3, "     \u{E702} .gitignore       ?");
    try f.expectRow(4, "     \u{E71E} package.json");
    try f.expectRow(5, "     \u{F00BA} README.md");
    try f.expectRow(6, "");
    try f.expectRow(7, " \u{F460} mixr");
    try f.expectRow(9, " \u{F460} acmeco-claude-workspa…");
    // Hits: the header row folds, its chips act, entries carry their row index.
    try testing.expectEqual(@as(u8, 0), f.hits.at(5, 0).?.tree_root);
    try testing.expectEqual(Chip.new_folder, f.hits.at(13, 0).?.tree_chip);
    try testing.expectEqual(Chip.new_folder, f.hits.at(15, 0).?.tree_chip);
    try testing.expectEqual(Chip.new_file, f.hits.at(16, 0).?.tree_chip);
    try testing.expectEqual(Chip.pull, f.hits.at(19, 0).?.tree_chip);
    try testing.expectEqual(Chip.refresh, f.hits.at(22, 0).?.tree_chip);
    try testing.expectEqual(Chip.refresh, f.hits.at(24, 0).?.tree_chip);
    try testing.expectEqual(@as(u8, 0), f.hits.at(12, 0).?.tree_root);
    try testing.expectEqual(@as(u8, 0), f.hits.at(25, 0).?.tree_root);
    try testing.expectEqual(@as(u32, 1), f.hits.at(12, 2).?.tree_node);
    try testing.expectEqual(@as(u32, 4), f.hits.at(0, 5).?.tree_node);
    try testing.expectEqual(@as(u8, 2), f.hits.at(10, 9).?.tree_root);
    try testing.expect(f.hits.at(3, 6) == null);
    // Colours: the folder icon in the theme's yellow, the folder name
    // bold blue, the untracked file green, the cursor row on bg2 from
    // its second cell and the rail ground on its first.
    try testing.expect(vaxis.Color.eql(f.style(5, 1).fg, f.theme.palette.yellow));
    try testing.expect(vaxis.Color.eql(f.style(7, 1).fg, f.theme.palette.blue));
    try testing.expect(f.style(7, 1).bold);
    try testing.expect(vaxis.Color.eql(f.style(7, 3).fg, f.theme.palette.green));
    try testing.expect(vaxis.Color.eql(f.style(24, 3).fg, f.theme.palette.green));
    try testing.expect(f.style(7, 3).dim);
    try testing.expect(vaxis.Color.eql(f.style(1, 1).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(0, 1).bg, f.theme.palette.bg_darker));
    try testing.expect(vaxis.Color.eql(f.style(7, 2).fg, Theme.rgb(0xDEA584)));
    try testing.expect(vaxis.Color.eql(f.style(3, 0).fg, f.theme.palette.green));
    try testing.expect(f.style(3, 0).bold);
}

test "the header's chips leave from the right of the cluster: 20 keeps two, 26 three, 40 all four; the refresh chip outlives them" {
    inline for (.{ .{ 20, 2 }, .{ 26, 3 }, .{ 40, 4 } }) |c| {
        var f = try Fixture.init(c[0], 1);
        defer f.deinit();
        _ = draw(f.ui(), f.full(), .{ .items = &.{section(0, "/private/tmp/ws/", true)} });
        var chips: usize = 0;
        var refresh: usize = 0;
        for (f.hits.items.items) |h| switch (h.target) {
            .tree_chip => |ch| if (ch == .refresh) {
                refresh += 1;
            } else {
                chips += 1;
            },
            else => {},
        };
        try testing.expectEqual(@as(usize, c[1]), chips);
        try testing.expectEqual(@as(usize, 1), refresh);
        // The refresh chip ends one cell short of the edge.
        try testing.expectEqual(Chip.refresh, f.hits.at(c[0] - 2, 0).?.tree_chip);
        try testing.expect(f.hits.at(c[0] - 1, 0).?.tree_root == 0);
    }
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .items = &.{.{ .section = .{ .root = 0, .label = "~/Projects/mnml/", .expanded = true, .fully_collapsed = true } }} });
    try g.expectRow(0, " \u{F47C} ~/Projects/mnml/      \u{EA80}  \u{EA7F}  \u{EB40}  \u{F0AB4}  \u{EB37}");
    try testing.expectEqual(Chip.collapse, g.hits.at(33, 0).?.tree_chip);
    // Too narrow for any chip: the label alone, clipped to four cells.
    var h = try Fixture.init(8, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .items = &.{section(0, "/private/tmp/ws/", true)} });
    try h.expectRow(0, " \u{F47C} /pr…");
    try testing.expectEqual(@as(usize, 1), h.hits.items.items.len);
}

test "the label truncates to what the cluster leaves: five cells at 26, and never under four" {
    var f = try Fixture.init(26, 1);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &.{section(0, "~/Projects/mnml-zig-worktrees/chrome-fixture/ws/", true)} });
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.row(0, &buf), " \u{F47C} ~/Pr… "));
    var g = try Fixture.init(30, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .items = &.{section(0, "~/short/", true)} });
    try testing.expect(std.mem.startsWith(u8, g.row(0, &buf), " \u{F47C} ~/short/ "));
    var h = try Fixture.init(26, 2);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .items = &.{ section(0, "/a/", true), section(1, "a-very-long-workspace-name-indeed", false) } });
    try h.expectRow(1, " \u{F460} a-very-long-workspace…");
}

test "connectors: ancestors with siblings to come draw a bar from level two, the top level none, a file's slot is the corner on the last child" {
    const items = [_]Item{
        section(0, "/w/", true),
        entry(0, "a", 0, true, true),
        entry(1, "b", 1, true, true),
        entry(2, "c1", 2, false, false),
        entry(3, "c2", 2, true, true),
        entry(4, "d", 3, false, false),
        entry(5, "c3", 2, false, false),
        entry(6, "e", 1, false, false),
        entry(7, "f", 0, false, false),
    };
    var f = try Fixture.init(30, 10);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &items });
    try f.expectRow(1, "   \u{F47C} \u{F07C} a");
    try f.expectRow(2, "     \u{F47C} \u{F07C} b");
    try f.expectRow(3, "     \u{F1F04} \u{F1F04} \u{F15B} c1");
    try f.expectRow(4, "     \u{F1F04} \u{F47C} \u{F07C} c2");
    try f.expectRow(5, "     \u{F1F04} \u{F1F04} \u{F1F05} \u{F15B} d");
    try f.expectRow(6, "     \u{F1F04} \u{F1F05} \u{F15B} c3");
    try f.expectRow(7, "     \u{F1F05} \u{F15B} e");
    try f.expectRow(8, "     \u{F15B} f");
    // ASCII: no chevron slot, the folder triangles, the dot, `| ` bars.
    var g = try Fixture.init(30, 10);
    defer g.deinit();
    var ui = g.ui();
    ui.ascii = true;
    _ = draw(ui, g.full(), .{ .items = &items });
    try g.expectRow(0, " v /w/         d+ f+ ↓  ↕  \u{21BA}");
    try g.expectRow(1, "   ▼ a");
    try g.expectRow(3, "     | · c1");
    try g.expectRow(5, "     | | · d");
    try g.expectRow(8, "   · f");
}

test "badges: M / A / ? / ! right-aligned, the unsaved dot beating git, a repo row in orange with its marker" {
    const items = [_]Item{
        section(0, "/w/", true),
        .{ .entry = .{ .idx = 0, .name = "m.rs", .depth = 0, .is_dir = false, .git = .modified } },
        .{ .entry = .{ .idx = 1, .name = "a.rs", .depth = 0, .is_dir = false, .git = .added } },
        .{ .entry = .{ .idx = 2, .name = "c.rs", .depth = 0, .is_dir = false, .git = .conflicted } },
        .{ .entry = .{ .idx = 3, .name = "d.rs", .depth = 0, .is_dir = false, .git = .modified, .dirty = true } },
        .{ .entry = .{ .idx = 4, .name = "repo", .depth = 0, .is_dir = true, .repo = .{ .active = false } } },
    };
    var f = try Fixture.init(20, 6);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &items, .show_dots = true });
    try f.expectRow(1, "     \u{E68B} m.rs       M");
    try f.expectRow(2, "     \u{E68B} a.rs       A");
    try f.expectRow(3, "     \u{E68B} c.rs       !");
    try f.expectRow(4, "     \u{E68B} d.rs       ●");
    try f.expectRow(5, "   \u{F460} \u{E702} ○ repo");
    try testing.expect(vaxis.Color.eql(f.style(7, 1).fg, f.theme.palette.yellow));
    try testing.expect(vaxis.Color.eql(f.style(18, 3).fg, f.theme.palette.red));
    try testing.expect(vaxis.Color.eql(f.style(18, 4).fg, f.theme.palette.orange));
    try testing.expect(vaxis.Color.eql(f.style(9, 5).fg, f.theme.palette.yellow));
    try testing.expect(f.style(9, 5).dim);
}

test "badges: a staged file keeps the index's letter — M for a modification, R for a rename, A only for a new file" {
    const items = [_]Item{
        section(0, "/w/", true),
        .{ .entry = .{ .idx = 0, .name = "m.rs", .depth = 0, .is_dir = false, .git = .staged } },
        .{ .entry = .{ .idx = 1, .name = "r.rs", .depth = 0, .is_dir = false, .git = .renamed } },
        .{ .entry = .{ .idx = 2, .name = "a.rs", .depth = 0, .is_dir = false, .git = .added } },
    };
    var f = try Fixture.init(20, 4);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &items, .show_dots = true });
    try f.expectRow(1, "     \u{E68B} m.rs       M");
    try f.expectRow(2, "     \u{E68B} r.rs       R");
    try f.expectRow(3, "     \u{E68B} a.rs       A");
    try testing.expect(vaxis.Color.eql(f.style(18, 1).fg, f.theme.palette.green));
}

test "scroll and overflow: the rows from `scroll`, a scrollbar in the last column that the badges keep clear of; the add row only when it fits" {
    var items: [12]Item = undefined;
    items[0] = section(0, "/w/", true);
    for (1..10) |i| items[i] = .{ .entry = .{ .idx = @intCast(i - 1), .name = "f.txt", .depth = 0, .is_dir = false, .git = .untracked } };
    items[10] = .blank;
    items[11] = .add_workspace;
    var f = try Fixture.init(26, 6);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .items = &items, .scroll = 2 });
    try testing.expect(l.overflow);
    try testing.expectEqual(@as(usize, 6), l.painted);
    try f.expectRow(0, "     \u{F0219} f.txt           ? █");
    try testing.expect(f.hits.at(25, 0).?.scrollbar.owner == .tree);
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 0).?.tree_node);
    try f.expectLacks("Add workspace");
    // Everything fits: no scrollbar, the add row right-aligned with the
    // glyph counted as two cells (Rust), a cell of margin.
    var g = try Fixture.init(26, 14);
    defer g.deinit();
    const m = draw(g.ui(), g.full(), .{ .items = &items });
    try testing.expect(!m.overflow);
    try g.expectRow(9, "     \u{F0219} f.txt            ?");
    try g.expectRow(10, "");
    try g.expectRow(11, "         \u{F0419} Add workspace");
    try testing.expectEqual(Chip.add_workspace, g.hits.at(9, 11).?.tree_chip);
    try testing.expectEqual(Chip.add_workspace, g.hits.at(24, 11).?.tree_chip);
    try testing.expect(g.hits.at(25, 11) == null);
    try testing.expectEqual(@as(usize, 12), contentLen(&items) + 2);
}

test "sections: the cursor bar on a focused header, the triangle indicator, the dots, and an ascii twin for every glyph" {
    const items = [_]Item{ section(0, "/w/", true), section(1, "mixr", false) };
    var f = try Fixture.init(30, 2);
    defer f.deinit();
    f.triangle = true;
    _ = draw(f.ui(), f.full(), .{ .items = &items, .cursor = 1, .focused = true, .show_dots = true });
    try f.expectRow(0, " " ++ expander.open_triangle ++ " ● /w/       \u{EA80}  \u{EA7F}  \u{EB40}  \u{EAC5}  \u{EB37}");
    try f.expectRow(1, "\u{258c}" ++ expander.closed_triangle ++ " ○ mixr");
    try testing.expect(vaxis.Color.eql(f.style(5, 1).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(0, 1).bg, f.theme.palette.bg_darker));
    inline for (.{ cont_glyph, corner_glyph, new_folder_glyph, new_file_glyph, pull_glyph, collapse_all_glyph, expand_all_glyph, add_workspace_glyph }) |g| {
        try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(g));
    }
    for (std.enums.values(Chip)) |c| {
        try testing.expect(c.glyph(false, true).len > 0);
        try testing.expect(c.label(false).len > 0);
    }
    try testing.expectEqualStrings("expand all", Chip.collapse.label(true));
    try testing.expectEqualStrings(expand_all_glyph, Chip.collapse.glyph(true, false));
    _ = draw(f.ui(), Rect.empty, .{ .items = &items });
}

test "the cursor row's marker: the list panels' bar in the leading cell, the accent when focused and muted when not, on an entry and on a section header alike, nowhere else" {
    var f = try Fixture.init(26, 10);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &fixture_items, .cursor = 2, .focused = true });
    try f.expectRow(2, "\u{258c}    \u{F1F05} \u{E68B} main.rs");
    try f.expectRow(1, "   \u{F47C} \u{F07C} src");
    try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, 2).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.style(0, 2).fg, f.theme.accent.fg));
    // The leading cell keeps the rail's ground under the marker.
    try testing.expect(vaxis.Color.eql(f.style(0, 2).bg, f.theme.palette.bg_darker));
    try testing.expect(vaxis.Color.eql(f.style(1, 2).bg, f.theme.palette.bg2));
    // Unfocused: the same glyph, muted.
    _ = draw(f.ui(), f.full(), .{ .items = &fixture_items, .cursor = 2, .focused = false });
    try testing.expectEqualStrings(list_panel.marker_glyph, f.cell(0, 2).char.grapheme);
    try testing.expect(vaxis.Color.eql(f.style(0, 2).fg, f.theme.muted.fg));
    try testing.expect(!vaxis.Color.eql(f.style(0, 2).fg, f.theme.accent.fg));
    // On a section header, and only there.
    _ = draw(f.ui(), f.full(), .{ .items = &fixture_items, .cursor = 7, .focused = true });
    try f.expectRow(7, "\u{258c}\u{F460} mixr");
    try f.expectRow(2, "     \u{F1F05} \u{E68B} main.rs");
    // No cursor: no marker anywhere; ascii has its twin.
    _ = draw(f.ui(), f.full(), .{ .items = &fixture_items });
    var y: u16 = 0;
    while (y < 10) : (y += 1) try testing.expectEqualStrings(" ", f.cell(0, y).char.grapheme);
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, f.full(), .{ .items = &fixture_items, .cursor = 1, .focused = true });
    try testing.expectEqualStrings(list_panel.marker_ascii, f.cell(0, 1).char.grapheme);
}

test "a cell of air before the bar: a long name is cut a cell short of it, an extra section's label clips a cell short of it, the blank row keeps it" {
    var items: [9]Item = undefined;
    items[0] = section(0, "/w/", true);
    for (1..7) |i| items[i] = entry(@intCast(i - 1), "a-long-file-name-that-overflows.txt", 0, false, false);
    items[7] = .blank;
    items[8] = section(1, "a-very-long-workspace-name-indeed", false);
    var f = try Fixture.init(26, 6);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .items = &items, .scroll = 3, .cursor = 3, .focused = true });
    try testing.expect(l.overflow);
    try f.expectRow(0, "\u{258c}    \u{F0219} a-long-file-name- █");
    try f.expectRow(3, "     \u{F0219} a-long-file-name- █");
    try f.expectRow(4, "                         █");
    try f.expectRow(5, " \u{F460} a-very-long-workspac… █");
    try f.expectAirBeforeBar(0, 6, 25);
    // Without the bar the name runs to the edge and the label keeps
    // Rust's one cell of margin.
    var g = try Fixture.init(26, 12);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .items = &items });
    try g.expectRow(1, "     \u{F0219} a-long-file-name-th");
    try g.expectRow(8, " \u{F460} a-very-long-workspace…");
}

test "colors: a repo row's marker dot takes the repo's accent when it has one, active or not; without one the stock green / grey" {
    const items = [_]Item{
        section(0, "/w/", true),
        .{ .entry = .{ .idx = 0, .name = "alpha", .depth = 0, .is_dir = true, .repo = .{ .active = true, .accent = Theme.default.palette.red } } },
        .{ .entry = .{ .idx = 1, .name = "beta", .depth = 0, .is_dir = true, .repo = .{ .active = false, .accent = Theme.default.palette.blue } } },
        .{ .entry = .{ .idx = 2, .name = "gamma", .depth = 0, .is_dir = true, .repo = .{ .active = false } } },
    };
    var f = try Fixture.init(20, 4);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .items = &items, .show_dots = true });
    try f.expectRow(1, "   \u{F460} \u{E702} ● alpha");
    try f.expectRow(2, "   \u{F460} \u{E702} ○ beta");
    try testing.expect(vaxis.Color.eql(f.style(7, 1).fg, f.theme.palette.red));
    try testing.expect(vaxis.Color.eql(f.style(7, 2).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(7, 3).fg, f.theme.palette.comment));
}
