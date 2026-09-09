//! The HTTP section's painter (D6): the seven sections — COLLECTIONS /
//! ENVS / CHAINS / MOCKS / COOKIES / RECENT / CAPTURED — as rows of one
//! `ListPanel`, each header carrying its own right-aligned chip ladder
//! (`≡` filter, `⟳` refresh, the browser `capture`, `✕` clear, `+`
//! new), the collections as a folder tree with a `+` on every folder
//! row, an empty state's words under an empty section, the green
//! `+ New env` / `+ New chain` / `+ New collection` links, and the
//! three action rows at the bottom (`+ New request`, `↓ Paste curl…`,
//! `↓ Import…`). Every chip, link and folder `+` registers a `.http`
//! hit in the statement that paints it; the rows are the app's
//! (`app/http_panel.zig` builds them from its snapshot).
//!
//! The header ladder is Rust's `draw_section_header` rule: a chip is
//! ` glyph ` (3 cells) with a one-cell gap between neighbours, the
//! cluster needs `1 + chevron + label + " (n)" + gaps + 2 + 3·chips`
//! cells, and while that exceeds the row it drops clear, then refresh,
//! then filter, then new, then capture — so a section's primary
//! action survives at the shipped 26-cell width. CHAINS asks for a
//! filter chip alone, which Rust's painter never draws (its gate wants
//! at least one of the others); the set here is the drawn one: none.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const chip = @import("chip.zig");
const icons = @import("icons.zig");
const request_view = @import("request_view.zig");

const Style = vaxis.Style;

pub const Section = enum {
    collections,
    envs,
    chains,
    mocks,
    cookies,
    recent,
    captured,

    pub const all = [_]Section{ .collections, .envs, .chains, .mocks, .cookies, .recent, .captured };

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .collections => "COLLECTIONS",
            .envs => "ENVS",
            .chains => "CHAINS",
            .mocks => "MOCKS",
            .cookies => "COOKIES",
            .recent => "RECENT",
            .captured => "CAPTURED",
        };
    }

    /// The words under an empty section (Rust's, COOKIES Zig's).
    pub fn emptyText(s: Section, ascii: bool) []const u8 {
        return switch (s) {
            .collections => "No collections yet — click + New collection below.",
            .envs => "No env files yet — click + New env below.",
            .chains => "No chains yet — click + New chain below.",
            .mocks => "No mocks — `:http.save_mock` on a response.",
            .cookies => "No cookies yet — responses with Set-Cookie fill the jar.",
            .recent => "No requests yet — sent requests land here.",
            .captured => if (ascii) "Nothing captured yet — click c capture on this row to dump entries from the browser pane." else "Nothing captured yet — click " ++ capture_glyph ++ " capture on this row to dump entries from the browser pane.",
        };
    }
};

/// A chip on a section header, in the order they paint.
pub const ChipKind = enum {
    filter,
    refresh,
    capture,
    clear,
    new,

    pub const order = [_]ChipKind{ .filter, .refresh, .capture, .clear, .new };
    /// Rust's drop order: the least important first.
    pub const drop_order = [_]ChipKind{ .clear, .refresh, .filter, .new, .capture };
};

/// A link row: the green `+ New …` under a section, the three action
/// rows at the bottom.
pub const Link = enum {
    new_request,
    paste_curl,
    import,
    new_env,
    new_chain,
    new_collection,

    pub fn text(l: Link, ascii: bool) []const u8 {
        return switch (l) {
            .new_request => "+ New request",
            .paste_curl => if (ascii) "v Paste curl…" else "\u{2193} Paste curl…",
            .import => if (ascii) "v Import…" else "\u{2193} Import…",
            .new_env => "+ New env",
            .new_chain => "+ New chain",
            .new_collection => "+ New collection",
        };
    }

    /// The `+ New …` links are green (Rust's `action_button::link`);
    /// the two `↓` rows are the accent.
    pub fn isNew(l: Link) bool {
        return switch (l) {
            .new_request, .new_env, .new_chain, .new_collection => true,
            .paste_curl, .import => false,
        };
    }
};

/// What a `.http` hit names.
pub const Part = union(enum) {
    chip: struct { section: Section, kind: ChipKind },
    link: Link,
    /// The ` + ` at the edge of the `idx`-th folder row: a new request
    /// in that collection.
    folder_new: u32,
};

pub const Kind = enum { header, folder, item, block, empty, link, gap };

/// One displayed row. Strings borrow the app's snapshot arena.
pub const Row = struct {
    section: Section,
    kind: Kind = .item,
    /// Header / folder: how many items the filter left.
    count: u32 = 0,
    /// The primary text and the dim detail after it.
    label: []const u8 = "",
    detail: []const u8 = "",
    /// Item: its index in the section's data. Folder: its index in
    /// the folder list. Block: its index in the block list.
    idx: u32 = 0,
    /// Header / folder: folded.
    collapsed: bool = false,
    /// Item: a file under a folder row (deeper, the file glyph).
    in_folder: bool = false,
    /// Folder: a `.mnml/collections/<name>` one (the hollow glyph).
    hidden: bool = false,
    /// Env: the active one.
    active: bool = false,
    /// Recent: the status code, 0 for a failed send.
    status: u16 = 0,
    /// Recent / captured: the method.
    method: []const u8 = "",
    link: Link = .new_request,

    /// A row the cursor can rest on.
    pub fn isStop(r: Row) bool {
        return switch (r.kind) {
            .empty, .gap => false,
            else => true,
        };
    }
};

pub const Panel = list_panel.ListPanel(Row);

pub const Props = struct {
    subtitle: ?[]const u8 = null,
    rows: []const Row,
    empty: list_panel.EmptyState,
};

// Codicons, as Rust paints them: filter EB83, browser EB01, close
// EA76, add EA60; the refresh is the family's (`chip.zig`).
pub const filter_glyph = "\u{EB83}";
pub const filter_ascii = "/";
pub const capture_glyph = "\u{EB01}";
pub const capture_ascii = "c";
pub const clear_glyph = "\u{EA76}";
pub const clear_ascii = "x";
pub const new_glyph = "\u{EA60}";
pub const new_ascii = "+";
/// A file inside a collection folder: nf-fa-file_text.
pub const member_glyph = "\u{F15C}";
pub const member_ascii = "-";
/// A loose request file: nf-fa-paper_plane (Rust's FILES rows).
pub const file_glyph = "\u{F1D8}";
pub const file_ascii = "\u{2192}";
/// A hidden (`.mnml/collections`) folder: nf-fa-folder_o.
pub const hidden_folder_glyph = "\u{F114}";
pub const hidden_folder_ascii = "-";
/// A chain: nf-fa-cogs. A mock: nf-fa-group (Rust's glyphs).
pub const chain_glyph = "\u{F085}";
pub const chain_ascii = "*";
pub const mock_glyph = "\u{F0C0}";
pub const mock_ascii = "m";

pub const chip_w: u16 = 3;
/// The ` + ` at a folder row's edge.
pub const folder_new_text = " + ";

/// Which chips a section's header paints, once the width has spoken.
pub const Ladder = struct {
    filter: bool = false,
    refresh: bool = false,
    capture: bool = false,
    clear: bool = false,
    new: bool = false,

    pub fn get(l: Ladder, k: ChipKind) bool {
        return switch (k) {
            .filter => l.filter,
            .refresh => l.refresh,
            .capture => l.capture,
            .clear => l.clear,
            .new => l.new,
        };
    }

    fn set(l: *Ladder, k: ChipKind, v: bool) void {
        switch (k) {
            .filter => l.filter = v,
            .refresh => l.refresh = v,
            .capture => l.capture = v,
            .clear => l.clear = v,
            .new => l.new = v,
        }
    }

    pub fn count(l: Ladder) u16 {
        var n: u16 = 0;
        for (ChipKind.order) |k| if (l.get(k)) {
            n += 1;
        };
        return n;
    }

    /// The cells the cluster takes: 3 per chip, a gap between.
    pub fn width(l: Ladder) u16 {
        const n = l.count();
        return if (n == 0) 0 else chip_w * n + (n - 1);
    }
};

/// The chips a section asks for (Rust's per-section layout, COOKIES
/// given RECENT's set).
pub fn wants(s: Section) Ladder {
    return switch (s) {
        .collections => .{ .filter = true, .refresh = true, .clear = true, .new = true },
        .envs => .{ .filter = true, .new = true },
        .chains => .{},
        .mocks, .cookies, .recent => .{ .filter = true, .refresh = true, .clear = true },
        .captured => .{ .filter = true, .refresh = true, .capture = true, .clear = true },
    };
}

/// The chips that fit in `avail` cells (the row's content width — the
/// panel less its marker column; Rust's `need < area.width` is `need
/// <= avail` here): `wants` with the least important dropped until the
/// header's text, two cells of air and the cluster fit.
pub fn ladder(ui: Ui, s: Section, count: u32, avail: u16) Ladder {
    var l = wants(s);
    const used: u16 = 1 + 2 + ui.width(s.label()) + ui.width(ui.fmt(" ({d})", .{count}));
    for (ChipKind.drop_order) |k| {
        if (need(l, used) <= avail) break;
        l.set(k, false);
    }
    return l;
}

fn need(l: Ladder, used: u16) u16 {
    const n = l.count();
    if (n == 0) return used;
    return used + (n - 1) + 2 + chip_w * n;
}

pub fn chipGlyph(k: ChipKind, ascii: bool) []const u8 {
    return switch (k) {
        .filter => if (ascii) filter_ascii else filter_glyph,
        .refresh => if (ascii) chip.refresh_icon_ascii else chip.refresh_icon_nerd,
        .capture => if (ascii) capture_ascii else capture_glyph,
        .clear => if (ascii) clear_ascii else clear_glyph,
        .new => if (ascii) new_ascii else new_glyph,
    };
}

/// The clear chip is red where it truncates a log (Rust: RECENT and
/// CAPTURED; the cookie jar here); elsewhere it only clears the
/// filter and wears the accent.
pub fn clearIsDestructive(s: Section) bool {
    return switch (s) {
        .recent, .captured, .cookies => true,
        else => false,
    };
}

fn chipStyle(t: *const Theme, s: Section, k: ChipKind, bg: vaxis.Color) Style {
    return switch (k) {
        .new => chip.newStyle(t, bg),
        .clear => if (clearIsDestructive(s)) .{ .fg = t.palette.red, .bg = bg } else chip.refreshStyle(t, bg),
        .filter, .refresh, .capture => chip.refreshStyle(t, bg),
    };
}

pub fn draw(st: *Panel.State, ui: Ui, area: Rect, p: Props) ?list_panel.Caret {
    return Panel.draw(st, ui, area, .{
        .panel = .http,
        .label = "HTTP",
        .subtitle = p.subtitle,
        .rows = p.rows,
        .paintRow = paintRow,
        .empty = p.empty,
        // The green ` + `: a blank request (`http.new`).
        .new_chip = true,
        // The user's pattern: air between the filter and the list.
        .filter_gap = true,
    });
}

/// One row's content, after the marker column.
pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    switch (row.kind) {
        .header => paintHeader(ui, r, row, base),
        .folder => paintFolder(ui, r, row, base),
        .item => paintItem(ui, r, row, base),
        .block => paintBlock(ui, r, row, base),
        .empty => _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(row.label, r.w -| 2), Theme.onBg(t.muted, base.bg)),
        .link => paintLink(ui, r, row, base),
        .gap => {},
    }
}

/// `▼ NAME (n)` (`▶` folded), the chip cluster at the right edge.
fn paintHeader(ui: Ui, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const l = ladder(ui, row.section, row.count, r.w);
    const cluster_w = l.width();
    const text_end = r.right() -| (cluster_w + @as(u16, if (cluster_w > 0) 1 else 0));
    var x = r.x;
    const open = !row.collapsed;
    const chevron: []const u8 = if (ui.ascii) (if (open) "v " else "> ") else (if (open) "\u{25BC} " else "\u{25B6} ");
    x += ui.putStr(x, r.y, text_end -| x, chevron, Theme.onBg(t.muted, base.bg));
    var label_style = Theme.onBg(t.fg, base.bg);
    label_style.bold = true;
    x += ui.putStr(x, r.y, text_end -| x, ui.clipStr(row.section.label(), text_end -| x), label_style);
    _ = ui.putStr(x, r.y, text_end -| x, ui.fmt(" ({d})", .{row.count}), Theme.onBg(t.muted, base.bg));
    if (cluster_w == 0) return;
    var cx = r.right() - cluster_w;
    for (ChipKind.order) |k| {
        if (!l.get(k)) continue;
        const text = ui.fmt(" {s} ", .{chipGlyph(k, ui.ascii)});
        const w = ui.putStr(cx, r.y, chip_w, text, chipStyle(t, row.section, k, base.bg));
        ui.hit(Rect.init(cx, r.y, w, 1), .{ .http = .{ .chip = .{ .section = row.section, .kind = k } } });
        cx += chip_w + 1;
    }
}

/// `▾ 󰉋 name (n)` with ` + ` at the edge; `▸` folded, the hollow
/// folder for a hidden collection.
fn paintFolder(ui: Ui, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const has_new = r.w > 12;
    const text_end = if (has_new) r.right() -| (chip_w + 1) else r.right();
    var x = r.x + 2;
    const chevron: []const u8 = if (ui.ascii) (if (row.collapsed) "> " else "v ") else (if (row.collapsed) "\u{25B8} " else "\u{25BE} ");
    x += ui.putStr(x, r.y, text_end -| x, chevron, Theme.onBg(t.muted, base.bg));
    const glyph: []const u8 = if (row.hidden) (if (ui.ascii) hidden_folder_ascii else hidden_folder_glyph) else (if (ui.ascii) icons.folder_closed_ascii else icons.folder_closed_glyph);
    const glyph_style: Style = if (row.hidden) Theme.onBg(t.muted, base.bg) else .{ .fg = t.palette.yellow, .bg = base.bg };
    x += ui.putStr(x, r.y, text_end -| x, ui.fmt("{s} ", .{glyph}), glyph_style);
    var name_style = Theme.onBg(t.fg, base.bg);
    name_style.bold = true;
    x += ui.putStr(x, r.y, text_end -| x, ui.clipStr(row.label, text_end -| x), name_style);
    _ = ui.putStr(x, r.y, text_end -| x, ui.fmt(" ({d})", .{row.count}), Theme.onBg(t.muted, base.bg));
    if (!has_new) return;
    const nx = r.right() - chip_w;
    const w = ui.putStr(nx, r.y, chip_w, folder_new_text, chip.newStyle(t, base.bg));
    ui.hit(Rect.init(nx, r.y, w, 1), .{ .http = .{ .folder_new = row.idx } });
}

fn paintItem(ui: Ui, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const end = r.right();
    var x = r.x + @as(u16, if (row.in_folder) 4 else 2);
    switch (row.section) {
        .collections => {
            const glyph: []const u8 = if (row.in_folder) (if (ui.ascii) member_ascii else member_glyph) else (if (ui.ascii) file_ascii else file_glyph);
            x += ui.putStr(x, r.y, end -| x, ui.fmt("{s} ", .{glyph}), .{ .fg = t.palette.blue, .bg = base.bg });
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.label, end -| x), Theme.onBg(t.fg, base.bg));
        },
        .envs => {
            const marker: []const u8 = if (row.active) "\u{25CF} " else "\u{25CB} ";
            x += ui.putStr(x, r.y, end -| x, marker, if (row.active) .{ .fg = t.palette.green, .bg = base.bg } else Theme.onBg(t.muted, base.bg));
            var s = Theme.onBg(t.fg, base.bg);
            s.bold = row.active;
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.label, end -| x), s);
        },
        .chains => {
            x += ui.putStr(x, r.y, end -| x, if (ui.ascii) chain_ascii ++ "  " else chain_glyph ++ "  ", .{ .fg = t.palette.cyan, .bg = base.bg });
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.label, end -| x), Theme.onBg(t.fg, base.bg));
        },
        .mocks => {
            x += ui.putStr(x, r.y, end -| x, if (ui.ascii) mock_ascii ++ " " else mock_glyph ++ " ", .{ .fg = t.palette.orange, .bg = base.bg });
            _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.label, end -| x), Theme.onBg(t.fg, base.bg));
        },
        .cookies => paintLabelDetail(ui, x, r, row, base),
        .recent => {
            const status_text = if (row.status == 0) ui.fmt("{s:<4}", .{"err"}) else ui.fmt("{d:<4}", .{row.status});
            x += ui.putStr(x, r.y, end -| x, status_text, .{ .fg = statusColor(t, row.status), .bg = base.bg });
            paintMethodUrl(ui, x, r, row, base);
        },
        .captured => paintMethodUrl(ui, x, r, row, base),
    }
}

/// A `###` block under its file: `GET  name  #tag #tag`, the method
/// in its verb's colour, two cells deeper than the file's row.
fn paintBlock(ui: Ui, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const end = r.right();
    var x = r.x + @as(u16, if (row.in_folder) 6 else 4);
    x += ui.putStr(x, r.y, end -| x, ui.fmt("{s:<4} ", .{row.method}), .{ .fg = request_view.methodColor(t.palette, row.method), .bg = base.bg, .bold = true });
    paintLabelDetail(ui, x, r, row, base);
}

/// `GET  host/path`: the method bold in the accent, padded to four.
fn paintMethodUrl(ui: Ui, x0: u16, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const end = r.right();
    var x = x0;
    var ms: Style = .{ .fg = t.palette.cyan, .bg = base.bg, .bold = true };
    ms.bold = true;
    x += ui.putStr(x, r.y, end -| x, ui.fmt("{s:<4} ", .{row.method}), ms);
    _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.label, end -| x), Theme.onBg(t.fg, base.bg));
}

/// 2xx green, 3xx the accent, 4xx yellow, the rest (and a failed
/// send) red.
pub fn statusColor(t: *const Theme, status: u16) vaxis.Color {
    if (status >= 200 and status < 300) return t.palette.green;
    if (status >= 300 and status < 400) return t.palette.cyan;
    if (status >= 400 and status < 500) return t.palette.yellow;
    return t.palette.red;
}

/// `label  detail`: the detail yields before the label does — a long
/// detail is clipped at the paint, never squeezing the label away.
fn paintLabelDetail(ui: Ui, x0: u16, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const end = r.right();
    var x = x0;
    const avail: u16 = end -| x;
    // Capped at the row: a 100k-char label must not sum past u16.
    const label_w = ui.widthUpTo(row.label, avail);
    const detail_w: u16 = if (row.detail.len > 0) ui.widthUpTo(row.detail, avail) + 2 else 0;
    var label = row.label;
    const label_max = @max(avail -| detail_w, @min(label_w, avail / 2));
    if (label_w > label_max) label = ui.clipStr(row.label, label_max);
    x += ui.putStr(x, r.y, end -| x, label, Theme.onBg(t.fg, base.bg));
    if (row.detail.len > 0 and end > x + 2) {
        x += ui.putStr(x, r.y, end -| x, "  ", base);
        _ = ui.putStr(x, r.y, end -| x, ui.clipStr(row.detail, end -| x), Theme.onBg(t.muted, base.bg));
    }
}

/// A link row: the text alone is the target.
fn paintLink(ui: Ui, r: Rect, row: Row, base: Style) void {
    const t = ui.theme;
    const x = r.x + 2;
    const style: Style = if (row.link.isNew()) chip.newStyle(t, base.bg) else .{ .fg = t.palette.cyan, .bg = base.bg };
    const text = row.link.text(ui.ascii);
    const w = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(text, r.right() -| x), style);
    ui.hit(Rect.init(x, r.y, w, 1), .{ .http = .{ .link = row.link } });
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");
const hit = @import("hit.zig");

fn header(s: Section, n: u32) Row {
    return .{ .section = s, .kind = .header, .count = n };
}

test "the ladder at 26 / 30 / 34: Rust's per-section sets and drop order" {
    // avail is the content width: the panel less the marker column.
    // COLLECTIONS: used 18; four chips need 35, three 31, two 27, one 23.
    var f = try Fixture.init(26, 1);
    defer f.deinit();
    const ui = f.ui();
    try testing.expectEqual(Ladder{ .new = true }, ladder(ui, .collections, 0, 25));
    try testing.expectEqual(Ladder{ .filter = true, .new = true }, ladder(ui, .collections, 0, 29));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .new = true }, ladder(ui, .collections, 0, 33));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .clear = true, .new = true }, ladder(ui, .collections, 0, 40));
    // ENVS: used 11; both chips need 20.
    try testing.expectEqual(Ladder{ .filter = true, .new = true }, ladder(ui, .envs, 0, 25));
    // CHAINS asks for nothing.
    try testing.expectEqual(Ladder{}, ladder(ui, .chains, 0, 60));
    // MOCKS: used 12; three chips need 25 — exactly the shipped width.
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .clear = true }, ladder(ui, .mocks, 0, 25));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true }, ladder(ui, .mocks, 0, 24));
    // RECENT: used 13; three need 26 > 25, so clear goes first.
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true }, ladder(ui, .recent, 2, 25));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .clear = true }, ladder(ui, .recent, 2, 29));
    // CAPTURED: used 15; four need 32, three 28, two 24: filter + capture.
    try testing.expectEqual(Ladder{ .filter = true, .capture = true }, ladder(ui, .captured, 0, 25));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .capture = true }, ladder(ui, .captured, 0, 29));
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true, .capture = true, .clear = true }, ladder(ui, .captured, 0, 33));
    // COOKIES takes RECENT's set; a wide count costs cells.
    try testing.expectEqual(Ladder{ .filter = true, .refresh = true }, ladder(ui, .cookies, 100, 25));
    // Nothing fits: the title alone.
    try testing.expectEqual(Ladder{}, ladder(ui, .collections, 0, 10));
}

test "a header paints the chevron, the bold label, the dim count and the cluster at the edge, each chip with its hit" {
    var f = try Fixture.init(30, 3);
    defer f.deinit();
    const ui = f.ui();
    paintRow(ui, Rect.init(0, 0, 25, 1), header(.captured, 0), false);
    try f.expectRow(0, "\u{25BC} CAPTURED (0)     \u{EB83}   \u{EB01}");
    try testing.expect(f.style(2, 0).bold);
    try testing.expectEqual(ChipKind.filter, f.hits.at(18, 0).?.http.chip.kind);
    try testing.expectEqual(Section.captured, f.hits.at(18, 0).?.http.chip.section);
    try testing.expectEqual(ChipKind.capture, f.hits.at(23, 0).?.http.chip.kind);
    try testing.expect(f.hits.at(21, 0) == null);
    // Folded: the other chevron; the clear chip is red on RECENT.
    var folded = header(.recent, 12);
    folded.collapsed = true;
    paintRow(ui, Rect.init(0, 1, 29, 1), folded, true);
    try f.expectRow(1, "\u{25B6} RECENT (12)      \u{EB83}   \u{EB37}   \u{EA76}");
    try testing.expect(vaxis.Color.eql(f.style(27, 1).fg, f.theme.palette.red));
    try testing.expectEqual(ChipKind.clear, f.hits.at(26, 1).?.http.chip.kind);
    // The ENVS `+` is green; a long label clips before the cluster.
    paintRow(ui, Rect.init(0, 2, 25, 1), header(.envs, 3), false);
    try f.expectRow(2, "\u{25BC} ENVS (3)         \u{EB83}   \u{EA60}");
    try testing.expect(vaxis.Color.eql(f.style(23, 2).fg, f.theme.palette.green));
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    paintRow(g.ui(), g.full().row(0), header(.collections, 0), false);
    try g.expectRow(0, "\u{25BC} COLLECTIO…");
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);
}

test "folder, member, loose file, env, chain, mock, recent and captured rows; the folder + and the links register their hits" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    const ui = f.ui();
    paintRow(ui, f.full().row(0), .{ .section = .collections, .kind = .folder, .label = "requests", .count = 3, .idx = 1 }, false);
    try f.expectRow(0, "  \u{25BE} \u{F07B} requests (3)          +");
    try testing.expectEqual(@as(u32, 1), f.hits.at(28, 0).?.http.folder_new);
    try testing.expect(f.hits.at(26, 0) == null);
    paintRow(ui, f.full().row(1), .{ .section = .collections, .kind = .folder, .label = "smoke", .count = 1, .hidden = true, .collapsed = true }, false);
    try f.expectRow(1, "  \u{25B8} \u{F114} smoke (1)             +");
    paintRow(ui, f.full().row(2), .{ .section = .collections, .label = "demo.http", .in_folder = true }, false);
    try f.expectRow(2, "    \u{F15C} demo.http");
    paintRow(ui, f.full().row(3), .{ .section = .collections, .label = "loose.http" }, false);
    try f.expectRow(3, "  \u{F1D8} loose.http");
    paintRow(ui, f.full().row(4), .{ .section = .envs, .label = "prod", .active = true }, false);
    try f.expectRow(4, "  \u{25CF} prod");
    try testing.expect(f.style(4, 4).bold);
    paintRow(ui, f.full().row(5), .{ .section = .envs, .label = "dev" }, false);
    try f.expectRow(5, "  \u{25CB} dev");
    paintRow(ui, f.full().row(6), .{ .section = .chains, .label = "login" }, false);
    try f.expectRow(6, "  \u{F085}  login");
    paintRow(ui, f.full().row(7), .{ .section = .mocks, .label = "api/orders.curl" }, false);
    try f.expectRow(7, "  \u{F0C0} api/orders.curl");
    paintRow(ui, f.full().row(8), .{ .section = .recent, .label = "x/login", .method = "POST", .status = 201 }, false);
    try f.expectRow(8, "  201 POST x/login");
    try testing.expect(vaxis.Color.eql(f.style(2, 8).fg, f.theme.palette.green));
    paintRow(ui, f.full().row(9), .{ .section = .recent, .label = "x/down", .method = "GET", .status = 0 }, false);
    try f.expectRow(9, "  err GET  x/down");
    try testing.expect(vaxis.Color.eql(f.style(2, 9).fg, f.theme.palette.red));
    paintRow(ui, f.full().row(10), .{ .section = .captured, .label = "cdn.test/app.js", .method = "GET" }, false);
    try f.expectRow(10, "  GET  cdn.test/app.js");
    paintRow(ui, f.full().row(11), .{ .section = .envs, .kind = .link, .link = .new_env }, false);
    try f.expectRow(11, "  + New env");
    try testing.expectEqual(Link.new_env, f.hits.at(2, 11).?.http.link);
    try testing.expectEqual(Link.new_env, f.hits.at(10, 11).?.http.link);
    try testing.expect(f.hits.at(11, 11) == null);
    try testing.expect(vaxis.Color.eql(f.style(2, 11).fg, f.theme.palette.green));
    // The two `↓` rows are the accent, and clip.
    var g = try Fixture.init(12, 2);
    defer g.deinit();
    paintRow(g.ui(), g.full().row(0), .{ .section = .captured, .kind = .link, .link = .paste_curl }, false);
    try g.expectRow(0, "  \u{2193} Paste c…");
    try testing.expect(vaxis.Color.eql(g.style(2, 0).fg, g.theme.palette.cyan));
    paintRow(g.ui(), g.full().row(1), .{ .section = .captured, .kind = .empty, .label = Section.captured.emptyText(false) }, false);
    try g.expectRow(1, "  Nothing c…");
    try testing.expect(g.hits.at(3, 1) == null);
}

test "a block row: the method in its colour two cells deeper than the file, the name, the tags dimmed" {
    var f = try Fixture.init(40, 2);
    defer f.deinit();
    const ui = f.ui();
    paintRow(ui, f.full().row(0), .{ .section = .collections, .kind = .block, .label = "two", .method = "POST", .detail = "#smoke #users", .in_folder = true }, false);
    try f.expectRow(0, "      POST two  #smoke #users");
    try testing.expect(vaxis.Color.eql(f.style(6, 0).fg, f.theme.palette.orange));
    try testing.expect(vaxis.Color.eql(f.style(16, 0).fg, f.theme.muted.fg));
    paintRow(ui, f.full().row(1), .{ .section = .collections, .kind = .block, .label = "one", .method = "GET" }, true);
    try f.expectRow(1, "    GET  one");
    try testing.expect(Row.isStop(.{ .section = .collections, .kind = .block }));
}

test "status colours and the empty words" {
    var f = try Fixture.init(10, 1);
    defer f.deinit();
    const t = &f.theme;
    try testing.expect(vaxis.Color.eql(statusColor(t, 204), t.palette.green));
    try testing.expect(vaxis.Color.eql(statusColor(t, 301), t.palette.cyan));
    try testing.expect(vaxis.Color.eql(statusColor(t, 404), t.palette.yellow));
    try testing.expect(vaxis.Color.eql(statusColor(t, 500), t.palette.red));
    try testing.expect(vaxis.Color.eql(statusColor(t, 0), t.palette.red));
    try testing.expect(std.mem.indexOf(u8, Section.captured.emptyText(false), capture_glyph) != null);
    try testing.expect(std.mem.indexOf(u8, Section.captured.emptyText(true), capture_glyph) == null);
    for (Section.all) |s| try testing.expect(s.emptyText(false).len > 10);
    try testing.expect(!Row.isStop(.{ .section = .envs, .kind = .gap }));
    try testing.expect(Row.isStop(.{ .section = .envs, .kind = .link }));
}

test "a chip hit's label" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (hit.HitTarget{ .http = .{ .chip = .{ .section = .envs, .kind = .new } } }).writeLabel(&w);
    try testing.expectEqualStrings("http:chip:envs:new", w.buffered());
}

test "at the panel's 26 cells with the bar: the header's cluster, a folder's +, every item's clipped label and a link all stop a cell short of the scrollbar" {
    var f = try Fixture.init(26, 9);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    var rows: [9]Row = undefined;
    rows[0] = header(.collections, 7);
    rows[1] = .{ .section = .collections, .kind = .folder, .label = "a-folder-name-that-overflows", .count = 2 };
    for (2..8) |i| rows[i] = .{ .section = .collections, .label = "a-request-file-name-that-is-long.http", .idx = @intCast(i) };
    rows[8] = .{ .section = .collections, .kind = .link, .link = .new_request };
    _ = draw(&st, f.ui(), f.full(), .{ .rows = &rows, .empty = .{ .message = "", .hint = "" } });
    // Header, filter, the gap row, then six list rows and the bar.
    try f.expectRow(3, "\u{258c}\u{25BC} COLLECTIONS (7)    \u{EA60}  █");
    try f.expectRow(4, "   \u{25BE} \u{F07B} a-folder-nam…  +  █");
    try f.expectRow(5, "   \u{F1D8} a-request-file-nam… █");
    try f.expectRow(8, "   \u{F1D8} a-request-file-nam… █");
    try f.expectAirBeforeBar(3, 9, 25);
    // The chips still act, at their new cells.
    try testing.expectEqual(ChipKind.new, f.hits.at(22, 3).?.http.chip.kind);
    try testing.expectEqual(@as(u32, 0), f.hits.at(22, 4).?.http.folder_new);
    try testing.expectEqual(hit.Axis.v, f.hits.at(25, 5).?.scrollbar.axis);
}
