//! The pane chrome every mnml integration paints — the caps header with
//! its chip ladder, the tab strip, the filter pill, the app-colour left
//! gutter, the row ground, a `Show more (N)` fold row, a detail panel
//! with its `×` and its scrollbar, and the hint row. One implementation,
//! so two panes cannot drift apart: an integration supplies the words
//! and the targets, the toolkit decides what the chrome looks like.
//!
//! `Painter` is generic over the pane's own hit-target union, so every
//! rectangle is registered in the same statement as the cells it covers
//! and dispatch stays one lookup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const hit = @import("hit.zig");
const text_mod = @import("text.zig");
const build_mod = @import("build.zig");
const action_mod = @import("action.zig");
const wire_mod = @import("../wire.zig");
const warm_mod = @import("../warm.zig");

pub const Frame = frame_mod.Frame;
pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const Rect = hit.Rect;
pub const width = text_mod.width;
pub const fit = text_mod.fit;

/// What the host told us about the terminal.
pub const Ui = struct {
    /// How the tab strip marks the tab that is on — the host's
    /// `ui.tab_indicator`, off `hello`.
    tab_indicator: wire_mod.TabIndicator = .block,
    ascii: bool = false,
    nerd: bool = true,

    pub fn glyph(u: Ui, nerd_g: []const u8, fallback: []const u8) []const u8 {
        return if (u.ascii or !u.nerd) fallback else nerd_g;
    }
};

/// The name of the host's `ui.ascii_icons`, for a run that has no pane
/// and so no `hello` to read it off.
pub const ascii_env = "MNML_ASCII";

/// `$MNML_ASCII`, as the statusline poller's `--values` child sees it.
/// A chip published with no pane open has to pick the same twin the
/// pane would, and the environment is the only place it can learn
/// which. Unset is "the terminal has the font": the answer a child run
/// by hand from a shell gets, and the one that held before the
/// variable existed.
pub fn asciiFromEnv(env: *const std.process.Environ.Map) bool {
    const v = env.get(ascii_env) orelse return false;
    return v.len > 0 and (v[0] == '1' or v[0] == 't' or v[0] == 'T');
}

// ─── the glyphs the chrome owns ──────────────────────────────────────────

pub const gutter_glyph = "\u{258c}"; // ▌ left half block
pub const gutter_ascii = "|";
pub const marker_glyph = "\u{258c}";
pub const marker_ascii = ">";
pub const open_glyph = "\u{F47C}"; // ▾
pub const closed_glyph = "\u{F460}"; // ▸
pub const open_ascii = "v";
pub const closed_ascii = ">";
pub const refresh_nerd = "\u{eb37}";
pub const refresh_ascii = "\u{21ba}";
pub const search_nerd = "\u{F0349}";
pub const search_ascii = "/";
pub const close_glyph = "\u{00d7}"; // ×
pub const close_ascii = "x";
pub const caret_glyph = "\u{258f}"; // ▏
pub const scroll_track = "\u{2502}"; // │
pub const scroll_thumb = "\u{2588}"; // █
pub const more_glyph = "\u{22ef}"; // ⋯
pub const more_ascii = "...";

/// The glyphs the three tab indicators are drawn from. The heavy and
/// light rules are box-drawing and the block is a half-block: all
/// three are in every terminal font, and each has an ascii stand-in.
pub const tab_block = "\u{2580}"; // ▀
pub const tab_rule_active = "\u{2501}"; // ━
pub const tab_rule = "\u{2500}"; // ─
pub const tab_quarter = "\u{1FB82}"; // 🬂 — a quarter-height bar at the head of the row, flush under the label
pub const tab_block_ascii = "=";
pub const tab_rule_active_ascii = "=";
pub const tab_rule_ascii = "-";
pub const tab_quarter_ascii = "_";
/// Below this the pane cannot spare a row for the indicator, and the
/// active label wears the terminal's underline attribute instead.
pub const tab_rule_min_rows: u16 = 12;

/// The `?` chip's caption. Every pane in the family has a key sheet
/// and every pane's hint row ends in `? keys` — but the hint row is
/// what a narrow pane drops first, so the chip on the header ladder is
/// the door that stays. One caption, so it is the same door.
pub const help_chip_text = " ? ";

pub const placeholder_unfocused = "/ filter";
pub const placeholder_focused = "type to filter\u{2026}";
pub const placeholder_focused_ascii = "type to filter...";

/// What a caps header left behind: the cell its left-hand run ended
/// at, and the first cell the right-hand ladder took. Anything else a
/// pane wants on the row goes between them and is clipped at `edge`.
pub const CapsHeader = struct { x: u16, edge: u16 };

/// A chip on the header's right-hand ladder.
pub fn Chip(comptime Target: type) type {
    return struct { text: []const u8, target: Target, active: bool = false };
}

/// One `key label` entry of the hint row. `target` makes it clickable.
pub fn Hint(comptime Target: type) type {
    return struct { key: []const u8, title: []const u8, target: Target };
}

/// A tab on the strip.
pub fn Tab(comptime Target: type) type {
    return struct { label: []const u8, target: Target, active: bool = false };
}

/// One action button of a row's run, as the row hands it over.
pub fn ActionChip(comptime Target: type) type {
    return struct {
        /// The word it says when the row can spare the cells.
        word: []const u8,
        /// What its last press left on it.
        state: action_mod.State = .idle,
        target: Target,
        /// The two styles to paint it in, when the pane has a reason
        /// to override what the word's kind would give: the dim
        /// `[ Merge ]` of a pull request that may not merge yet.
        chip: ?action_mod.Chip = null,
    };
}

pub fn Painter(comptime Target: type) type {
    return struct {
        const Self = @This();
        pub const ChipSpec = Chip(Target);
        pub const HintSpec = Hint(Target);
        pub const TabSpec = Tab(Target);
        pub const ActionChipSpec = ActionChip(Target);

        f: *Frame,
        /// The hit map's allocator — it outlives the frame.
        gpa: Allocator,
        /// One frame's scratch: formatted strings die with the paint.
        arena: Allocator,
        hits: *hit.Map(Target),
        th: Theme,
        ui: Ui,

        pub fn cols(p: *const Self) u16 {
            return p.f.cols;
        }

        pub fn rows(p: *const Self) u16 {
            return p.f.rows;
        }

        // ─── primitives ──────────────────────────────────────────────

        /// Text at `(x, y)`, clipped at `max_w`; the cells used.
        pub fn put(p: *Self, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
            if (x >= p.cols() or y >= p.rows()) return 0;
            return p.f.text(x, y, max_w, s, style);
        }

        /// `s` fitted with an ellipsis into `max_w`.
        pub fn putFit(p: *Self, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
            var buf: [512]u8 = undefined;
            return p.put(x, y, max_w, fit(&buf, s, max_w), style);
        }

        pub fn fill(p: *Self, r: Rect, style: Style) void {
            p.f.fill(r.x, r.y, r.w, r.h, style);
        }

        pub fn mark(p: *Self, r: Rect, target: Target) Allocator.Error!void {
            try p.hits.add(p.gpa, r, target);
        }

        pub fn fmt(p: *Self, comptime f: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(p.arena, f, args) catch "";
        }

        pub fn chevron(p: *const Self, open: bool) []const u8 {
            if (p.ui.ascii or !p.ui.nerd) return if (open) open_ascii else closed_ascii;
            return if (open) open_glyph else closed_glyph;
        }

        pub fn marker(p: *const Self) []const u8 {
            return if (p.ui.ascii) marker_ascii else marker_glyph;
        }

        // ─── the app-colour left gutter ──────────────────────────────

        /// The full-height stripe in the integration's own colour down
        /// column `rect.x`: bright on the cursor's row, dim on the rest.
        /// It is the row marker and the app's identity in one column, so
        /// no pane spends a second column saying the same thing.
        pub fn gutter(p: *Self, rect: Rect, cursor_row: ?u16) void {
            if (rect.isEmpty()) return;
            const g = if (p.ui.ascii) gutter_ascii else gutter_glyph;
            var y = rect.y;
            while (y < rect.bottom() and y < p.rows()) : (y += 1) {
                const on = if (cursor_row) |c| c == y else false;
                _ = p.put(rect.x, y, 1, g, if (on) p.th.gutterOn() else p.th.gutterOff());
            }
        }

        // ─── the caps header ─────────────────────────────────────────

        /// `JIRA WORK  (3 of 8)` at the left; the x the subtitle ended at.
        pub fn capsTitle(p: *Self, x0: u16, y: u16, title: []const u8, sub: []const u8) u16 {
            var x = x0;
            x += p.put(x, y, p.cols() -| x, title, p.th.label());
            if (sub.len > 0) x += p.put(x, y, p.cols() -| x, sub, p.th.dimText());
            return x;
        }

        /// The right-hand chip ladder, laid right to left, each chip
        /// dropped whole when it would cross `left_edge`. Returns the
        /// leftmost cell a chip took.
        pub fn rightChips(p: *Self, y: u16, left_edge: u16, chips: []const ChipSpec) Allocator.Error!u16 {
            var right = p.cols();
            for (chips) |c| {
                const w = width(c.text);
                if (right < left_edge + w + 2) break;
                right -= w + 1;
                _ = p.put(right, y, w, c.text, if (c.active) p.th.chipActive() else p.th.chip());
                try p.mark(.{ .x = right, .y = y, .w = w, .h = 1 }, c.target);
            }
            return right;
        }

        /// `as of 4m ago`, immediately after the subtitle and in the
        /// same muted ink, on every listing in the family.
        ///
        /// A screenful of rows with nothing above it reads as now, and
        /// on a cached pane it usually is not. This is that one line,
        /// in one place, so the two families say it the same way and a
        /// third does not have to decide. `fetched_at` of 0 — nothing
        /// has ever landed — paints nothing: an empty pane says
        /// `loading…`, not `as of 0s ago`.
        ///
        /// Returns the x it ended at, so the caller keeps laying out.
        pub fn asOf(p: *Self, x0: u16, y: u16, fetched_at: i64, now_secs: i64) u16 {
            var buf: [32]u8 = undefined;
            const t2 = warm_mod.asOfText(&buf, fetched_at, now_secs);
            if (t2.len == 0) return x0;
            var x = x0;
            x += p.put(x, y, p.cols() -| x, "  ", p.th.dimText());
            x += p.put(x, y, p.cols() -| x, t2, p.th.dimText());
            return x;
        }

        /// The whole caps header row, in one call: the title and its
        /// count at the left, `as of 4m ago` after them, and the
        /// right-hand chip ladder — laid so the two runs cannot
        /// collide. Hands back where the left run ended and where the
        /// ladder began, so a pane with something else to say on the
        /// row (`3 selected`) can put it between them.
        ///
        /// The collision is the reason this exists. A pane that paints
        /// the left run and then the ladder gets the ladder over the
        /// top of its own words; one that paints the ladder first and
        /// then the left run gets `as of 9s agohor: all`, which is
        /// what the forge pane did at 80 columns the moment its ladder
        /// grew a chip. The ladder is laid FIRST, against the title's
        /// width, and everything after it is clipped at whatever cell
        /// the ladder reached.
        ///
        /// `as of …` is dropped whole rather than clipped: half of an
        /// age is worse than no age, and the count beside the title is
        /// the line that must survive.
        pub fn capsHeader(
            p: *Self,
            x0: u16,
            y: u16,
            title: []const u8,
            sub: []const u8,
            fetched_at: i64,
            now_secs: i64,
            chips: []const ChipSpec,
        ) Allocator.Error!CapsHeader {
            // The ladder may take everything past the title; the count
            // gives way to it before the title does.
            const right = try p.rightChips(y, x0 + width(title) + 1, chips);
            const edge = right -| 1;
            var x = x0;
            x += p.put(x, y, edge -| x, title, p.th.label());
            if (sub.len > 0) x += p.put(x, y, edge -| x, sub, p.th.dimText());
            var buf: [32]u8 = undefined;
            const age = warm_mod.asOfText(&buf, fetched_at, now_secs);
            if (age.len > 0 and x + 2 + width(age) <= edge) {
                x += p.put(x, y, edge -| x, "  ", p.th.dimText());
                x += p.put(x, y, edge -| x, age, p.th.dimText());
            }
            return .{ .x = x, .edge = edge };
        }

        /// The refresh glyph as a chip's text, for the ladder.
        pub fn refreshChipText(p: *const Self) []const u8 {
            return if (p.ui.ascii or !p.ui.nerd) " " ++ refresh_ascii ++ " " else " " ++ refresh_nerd ++ " ";
        }

        // ─── the tab strip ───────────────────────────────────────────

        /// The tab strip, and the row under it that marks the tab that
        /// is on.
        ///
        /// The active tab used to be marked with a `▌` to its left —
        /// mnml's own cursor glyph, doing a second job in a place that
        /// is not a list. It reads as a browser's tabs now: the label
        /// in the pane's brand colour, and an indicator on the row
        /// beneath spanning exactly its cells. Which of the three
        /// shapes is the host's `ui.tab_indicator`, carried on `hello`.
        ///
        /// Returns the rows it used — 2 normally, 1 in a pane too short
        /// to spend one on the indicator, where the active label
        /// carries the terminal's own underline attribute instead.
        pub fn tabStrip(p: *Self, x0: u16, y: u16, list: []const TabSpec) Allocator.Error!u16 {
            const ruled = p.rows() >= tab_rule_min_rows and y + 1 < p.rows();
            var x = x0;
            var active_x: u16 = 0;
            var active_w: u16 = 0;
            for (list) |t| {
                const w = width(t.label);
                if (x + w > p.cols()) break;
                var style: Style = if (t.active) .{ .fg = p.th.brand, .mods = .{ .bold = true } } else p.th.tabInactive();
                // No room for the indicator: the attribute says it.
                if (t.active and !ruled) style.mods.underline = true;
                _ = p.put(x, y, w, t.label, style);
                try p.mark(.{ .x = x, .y = y, .w = w, .h = 1 }, t.target);
                if (t.active) {
                    active_x = x;
                    active_w = w;
                }
                x += w + 1;
            }
            if (!ruled) return 1;
            // Only `rule` lays a track across the strip; the other two
            // leave the row empty either side of the active label.
            if (p.ui.tab_indicator == .rule or p.ui.tab_indicator == .quarter_track) {
                const right = @min(x, p.cols());
                var i = x0;
                const track = if (p.ui.tab_indicator == .quarter_track) (if (p.ui.ascii) tab_quarter_ascii else tab_quarter) else (if (p.ui.ascii) tab_rule_ascii else tab_rule);
                while (i < right) : (i += 1) _ = p.put(i, y + 1, 1, track, p.th.mutedText());
            }
            const glyph = switch (p.ui.tab_indicator) {
                .block => if (p.ui.ascii) tab_block_ascii else tab_block,
                .rule => if (p.ui.ascii) tab_rule_active_ascii else tab_rule_active,
                .line => if (p.ui.ascii) tab_rule_ascii else tab_rule,
                .quarter, .quarter_track => if (p.ui.ascii) tab_quarter_ascii else tab_quarter,
            };
            var i = active_x;
            while (i < active_x + active_w and i < p.cols()) : (i += 1) {
                _ = p.put(i, y + 1, 1, glyph, .{ .fg = p.th.brand });
            }
            return 2;
        }

        // ─── the filter pill ─────────────────────────────────────────

        /// `󰍉 / filter` at rest, the query with a caret while it has the
        /// keys. `caret` is a byte offset into `query`.
        pub fn filterPill(p: *Self, rect: Rect, query: []const u8, caret: usize, editing: bool, target: Target) Allocator.Error!void {
            if (rect.w < 6) return;
            const th = p.th;
            const style = if (editing) th.chipActiveSoft() else th.chip();
            p.fill(rect, style);
            var x = rect.x + 1;
            x += p.put(x, rect.y, 2, p.ui.glyph(search_nerd, search_ascii), .{ .fg = th.accent, .bg = style.bg });
            x += 1;
            if (query.len == 0) {
                const ph: []const u8 = if (!editing) placeholder_unfocused else if (p.ui.ascii) placeholder_focused_ascii else placeholder_focused;
                // The caret goes BEFORE the placeholder, not on top of
                // its first cell: `▏ype to filter…` reads as a
                // typo rather than as an empty field with the keyboard.
                if (editing) x += p.put(x, rect.y, 1, caret_glyph, .{ .fg = th.accent, .bg = style.bg });
                _ = p.put(x, rect.y, rect.w -| 4 -| (x -| (rect.x + 4)), ph, .{ .fg = th.muted, .bg = style.bg });
            } else {
                const used = p.put(x, rect.y, rect.w -| 4, query, .{ .fg = th.fg, .bg = style.bg });
                if (editing) {
                    const caret_x = x + width(query[0..@min(caret, query.len)]);
                    if (caret_x <= x + used) _ = p.put(caret_x, rect.y, 1, caret_glyph, .{ .fg = th.accent, .bg = style.bg });
                }
            }
            try p.mark(rect, target);
        }

        // ─── the list body ───────────────────────────────────────────

        /// One row's ground — `h` is 1, or 2 for a row with a sub-line —
        /// with the gutter stripe down its left column. The row's own
        /// hit is registered over the whole block.
        pub fn rowGround(p: *Self, rect: Rect, selected: bool, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            p.fill(rect, if (selected) p.th.cursorRow() else p.th.text());
            const g = if (p.ui.ascii) gutter_ascii else gutter_glyph;
            var y = rect.y;
            while (y < rect.bottom()) : (y += 1) {
                var s = if (selected) p.th.gutterOn() else p.th.gutterOff();
                if (selected) s.bg = p.th.cursor_line;
                _ = p.put(rect.x, y, 1, g, s);
            }
            try p.mark(rect, target);
        }

        /// The fold row under a capped list: `⋯  Show more (N)` from
        /// `label_x`, the ellipsis dim punctuation and only the words
        /// bright.
        ///
        /// One phrase, in one place. The ellipsis used to be pinned to
        /// the row's left edge while its words sat out in the summary
        /// column, which at any real width read as an empty column
        /// with a stray `⋯` in it rather than as a row you can press.
        pub fn showMoreRow(p: *Self, rect: Rect, label_x: u16, hidden: usize, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            var x = label_x;
            x += p.put(x, rect.y, 3, if (p.ui.ascii) more_ascii else more_glyph, p.th.dimText());
            x += p.put(x, rect.y, 2, "  ", p.th.dimText());
            const label = p.fmt("Show more ({d})", .{hidden});
            _ = p.putFit(x, rect.y, rect.right() -| x, label, p.th.bright());
            try p.mark(rect, target);
        }

        /// One build line under a pull-request row, indented to
        /// `label_x`: `✓ SUCCESSFUL · main · 4h · #412`, the state's
        /// colour, the whole line a hit so a click opens that run's
        /// page. `note` covers the three lines that are not a run —
        /// fetching, none, the reason there are none.
        pub fn buildRow(p: *Self, rect: Rect, label_x: u16, run: build_mod.Run, now_secs: i64, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            var buf: [192]u8 = undefined;
            const line = build_mod.caption(&buf, run, now_secs, p.ui.ascii);
            _ = p.putFit(label_x, rect.y, rect.right() -| label_x, line, build_mod.styleOf(p.th, run.state));
            // `hit.buildHit`, not the rect as given: the door is the
            // whole line, and a pane that paints its build line as a
            // table cell registers the SAME rect by calling
            // `buildHit` itself. One door, two lay-outs.
            try p.mark(hit.buildHit(rect, rect.right()), target);
        }

        // ─── an action button ──────────────────────────────

        /// One `[ Word ]` button, its brackets and its word painted
        /// separately: the punctuation stays muted and the word carries
        /// the colour of what pressing it does
        /// (`sdk.pane.action.Kind`). A caption the toolkit does not
        /// recognise as bracketed is painted whole in the word's style.
        ///
        /// Neither style names a ground, so a button on the cursor's
        /// row keeps that row's fill instead of punching a hole in it.
        /// Returns the cells used.
        pub fn actionChip(p: *Self, x: u16, y: u16, max_w: u16, cap: []const u8, c: action_mod.Chip) u16 {
            // `[ Merge ]` — what a state past `idle` still says — and
            // `[󰊢 Merge]`, which is the idle form now that a button
            // carries its glyph. The brackets are punctuation either
            // way; everything between them is the word's.
            const lead = if (std.mem.startsWith(u8, cap, "[ ")) "[ " else "[";
            const tail = if (std.mem.endsWith(u8, cap, " ]")) " ]" else "]";
            if (!std.mem.startsWith(u8, cap, lead) or !std.mem.endsWith(u8, cap, tail) or cap.len < lead.len + tail.len) {
                return p.put(x, y, max_w, cap, c.word);
            }
            const word = cap[lead.len .. cap.len - tail.len];
            var used = p.put(x, y, max_w, lead, c.bracket);
            used += p.put(x + used, y, max_w -| used, word, c.word);
            used += p.put(x + used, y, max_w -| used, tail, c.bracket);
            return used;
        }

        /// A row's whole run of action buttons, laid left to right from
        /// `x`, each hit registered with the cells it painted. The
        /// cells used.
        ///
        /// `form` comes from `action.formFor`, which the row asks
        /// BEFORE it paints its words — the buttons take their cells
        /// off the text column, so the words are shortened rather than
        /// painted over.
        ///
        /// Every button in the list is painted. A row whose buttons do
        /// not fit gets `action.Form.icon` and three glyphs; it never
        /// gets an empty right margin where an action used to be.
        pub fn actionChips(p: *Self, x: u16, y: u16, form: action_mod.Form, tick: usize, list: []const ActionChipSpec) Allocator.Error!u16 {
            var used: u16 = 0;
            for (list, 0..) |b, i| {
                if (i > 0) used += p.put(x + used, y, action_mod.gap, " ", p.th.dimText());
                var buf: [64]u8 = undefined;
                const cap = action_mod.captionIn(&buf, form, b.state, b.word, tick, p.ui.ascii);
                const c = b.chip orelse action_mod.chipOf(p.th, b.state, action_mod.kindOf(b.word));
                const w = if (form == .icon)
                    p.put(x + used, y, 2, cap, c.word)
                else
                    p.actionChip(x + used, y, p.cols() -| (x + used), cap, c);
                if (w == 0) break;
                try p.mark(.{ .x = x + used, .y = y, .w = w, .h = 1 }, b.target);
                used += w;
            }
            return used;
        }

        /// The stand-in where a build line would be: `→ fetching…`,
        /// `→ no pipeline ran on abc1234`, `→ <why>`. `bad` paints it
        /// in the error colour; everything else is a dim aside.
        pub fn buildNote(p: *Self, rect: Rect, label_x: u16, text: []const u8, bad: bool) void {
            if (rect.isEmpty()) return;
            const arrow = if (p.ui.ascii) "-> " else "\u{2192} ";
            const x = label_x + p.put(label_x, rect.y, 3, arrow, p.th.dimText());
            _ = p.putFit(x, rect.y, rect.right() -| x, text, if (bad) p.th.bad() else p.th.dimText());
        }

        /// A named confirm: a framed box with a heading, its lines, and
        /// two chips. The heading and the lines are the caller's — a
        /// confirm that says "are you sure?" and nothing else is a
        /// confirm nobody reads, so the toolkit takes the words rather
        /// than inventing them.
        ///
        /// The whole box is a hit under `body_target`, so a click
        /// outside the chips does not fall through to the row beneath.
        pub fn confirmBox(
            p: *Self,
            box: Rect,
            heading: []const u8,
            lines: []const []const u8,
            ok_label: []const u8,
            ok_target: Target,
            cancel_label: []const u8,
            cancel_target: Target,
            body_target: Target,
        ) Allocator.Error!void {
            if (box.w < 8 or box.h < 4) return;
            p.fill(box, p.th.overlayBg());
            p.frameBox(box, p.th.overlayBorder());
            _ = p.putFit(box.x + 2, box.y, box.w -| 4, heading, p.th.bright());
            var y = box.y + 2;
            for (lines) |line| {
                if (y >= box.bottom() - 2) break;
                _ = p.putFit(box.x + 2, y, box.w -| 4, line, p.th.text());
                y += 1;
            }
            // The two chips, right-anchored on the last inner row, the
            // affirmative one last so it sits where the eye ends up.
            const row = box.bottom() - 2;
            const okw = width(ok_label);
            const cw = width(cancel_label);
            if (box.w < okw + cw + 6) return;
            const ok_x = box.right() - 2 - okw;
            const cancel_x = ok_x - 1 - cw;
            _ = p.put(cancel_x, row, cw, cancel_label, p.th.chip());
            try p.mark(.{ .x = cancel_x, .y = row, .w = cw, .h = 1 }, cancel_target);
            _ = p.put(ok_x, row, okw, ok_label, p.th.chipActive());
            try p.mark(.{ .x = ok_x, .y = row, .w = okw, .h = 1 }, ok_target);
            try p.mark(box, body_target);
        }

        // ─── the scrollbar ───────────────────────────────────────────

        /// A thumb sized to the window over a dim track. The whole bar
        /// is one hit, so a press or a drag on it can be turned back
        /// into a position with `scrollAt`.
        pub fn scrollbar(p: *Self, bar: Rect, total: usize, first: usize, visible: usize, target: ?Target) Allocator.Error!void {
            if (bar.h == 0 or total == 0) return;
            var y = bar.y;
            while (y < bar.bottom()) : (y += 1) _ = p.put(bar.x, y, 1, scroll_track, .{ .fg = p.th.border });
            const thumb_h: usize = @max(1, (visible * bar.h) / total);
            const max_first = total -| visible;
            const thumb_y: usize = if (max_first == 0) 0 else (first * (bar.h - @min(thumb_h, bar.h))) / max_first;
            var i: usize = 0;
            while (i < thumb_h and thumb_y + i < bar.h) : (i += 1) {
                _ = p.put(bar.x, bar.y + @as(u16, @intCast(thumb_y + i)), 1, scroll_thumb, .{ .fg = p.th.muted });
            }
            if (target) |t| try p.mark(bar, t);
        }

        // ─── an overlay's frame ──────────────────────────────────────

        pub fn frameBox(p: *Self, b: Rect, style: Style) void {
            if (b.w < 2 or b.h < 2) return;
            const right = b.x + b.w - 1;
            const bottom = b.y + b.h - 1;
            _ = p.put(b.x, b.y, 1, "┌", style);
            _ = p.put(right, b.y, 1, "┐", style);
            _ = p.put(b.x, bottom, 1, "└", style);
            _ = p.put(right, bottom, 1, "┘", style);
            var x = b.x + 1;
            while (x < right) : (x += 1) {
                _ = p.put(x, b.y, 1, "─", style);
                _ = p.put(x, bottom, 1, "─", style);
            }
            var y = b.y + 1;
            while (y < bottom) : (y += 1) {
                _ = p.put(b.x, y, 1, "│", style);
                _ = p.put(right, y, 1, "│", style);
            }
        }

        /// The `×` in a panel's top-right corner. Esc still closes the
        /// panel; this is the same door for the pointer.
        pub fn closeChip(p: *Self, box: Rect, target: Target) Allocator.Error!void {
            if (box.w < 3 or box.h == 0) return;
            const x = box.right() - 1;
            _ = p.put(x, box.y, 1, if (p.ui.ascii) close_ascii else close_glyph, p.th.mutedText());
            try p.mark(.{ .x = x, .y = box.y, .w = 1, .h = 1 }, target);
        }

        /// A detail panel's frame: its body is one hit (the wheel
        /// scrolls it), its corner carries the `×`.
        pub fn detailPanel(p: *Self, box: Rect, body_target: Target, close_target: Target) Allocator.Error!void {
            if (box.isEmpty()) return;
            try p.mark(box, body_target);
            try p.closeChip(box, close_target);
        }

        // ─── the hint row ────────────────────────────────────────────

        /// The status on the left, the keys that apply on the right,
        /// each `key label` a hit that runs it, and a trailing `? keys`
        /// that opens the sheet. Entries are dropped from the front
        /// until the row fits, so the last ones — the ones that always
        /// apply — survive a narrow pane.
        pub fn hintRow(p: *Self, y: u16, status: []const u8, list: []const HintSpec) Allocator.Error!void {
            const th = p.th;
            const sep = " \u{b7} ";
            const sep_w: u16 = 3;
            if (list.len == 0) {
                if (status.len > 0) _ = p.putFit(1, y, p.cols() -| 1, status, th.mutedText());
                return;
            }
            // One entry per chord, whatever the caller passed. A pane
            // whose bindings already carry `? keys` and which appends
            // its own paints it twice — the Jira pane did, for as long
            // as its hint row was hand-rolled — so the row that has to
            // read cleanly is the one that decides, not the caller.
            const hints = dedupe(p.arena, list) orelse list;
            const widths = p.arena.alloc(u16, hints.len) catch return;
            var total: u16 = 0;
            for (hints, 0..) |h, i| {
                widths[i] = width(h.key) + 1 + width(h.title);
                total += widths[i] + if (i + 1 < hints.len) sep_w else 0;
            }
            const status_w: u16 = @min(width(status) + 2, p.cols() / 2);
            var first: usize = 0;
            while (first < hints.len and total + status_w > p.cols()) {
                total -= widths[first] + if (first + 1 < hints.len) sep_w else 0;
                first += 1;
            }
            if (status.len > 0) _ = p.putFit(1, y, p.cols() -| 1 -| total, status, th.mutedText());
            var x: u16 = p.cols() -| total;
            var i = first;
            while (i < hints.len) : (i += 1) {
                const h = hints[i];
                const start = x;
                x += p.put(x, y, p.cols() -| x, h.key, th.bright());
                x += p.put(x, y, p.cols() -| x, " ", th.dimText());
                x += p.put(x, y, p.cols() -| x, h.title, th.dimText());
                try p.mark(.{ .x = start, .y = y, .w = x -| start, .h = 1 }, h.target);
                if (i + 1 < hints.len) x += p.put(x, y, p.cols() -| x, sep, th.dimText());
            }
        }

        /// `list` with any repeat of a `key title` pair it already
        /// carries dropped, keeping the first of each and their order.
        /// Null when nothing repeats (the common case) or the arena
        /// cannot answer, so the caller paints its own slice.
        fn dedupe(arena: Allocator, list: []const HintSpec) ?[]const HintSpec {
            var repeats = false;
            for (list, 0..) |h, i| {
                for (list[0..i]) |prev| {
                    if (std.mem.eql(u8, prev.key, h.key) and std.mem.eql(u8, prev.title, h.title)) repeats = true;
                }
            }
            if (!repeats) return null;
            var out = arena.alloc(HintSpec, list.len) catch return null;
            var n: usize = 0;
            for (list) |h| {
                var seen = false;
                for (out[0..n]) |kept| {
                    if (std.mem.eql(u8, kept.key, h.key) and std.mem.eql(u8, kept.title, h.title)) seen = true;
                }
                if (seen) continue;
                out[n] = h;
                n += 1;
            }
            return out[0..n];
        }
    };
}

/// Where a press at `row` on a scrollbar puts the window's first item.
pub fn scrollAt(bar: Rect, total: usize, visible: usize, row: u16) usize {
    if (bar.h == 0 or total <= visible) return 0;
    const rel: usize = @min(row -| bar.y, bar.h - 1);
    const max_first = total - visible;
    return @min(max_first, (rel * total) / bar.h);
}

/// The three indicators, painted through the real `tabStrip`.
fn stripRows(gpa: Allocator, ind: wire_mod.TabIndicator, ascii: bool, rows: u16) ![2][]const u8 {
    const Target = union(enum) { tab: u8 };
    var f = try frame_mod.Frame.init(gpa, 40, rows);
    defer f.deinit();
    var hits: hit.Map(Target) = .{};
    defer hits.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var p: Painter(Target) = .{
        .f = &f,
        .gpa = gpa,
        .arena = arena.allocator(),
        .hits = &hits,
        .th = .{ .brand = .{ .index = 5 } },
        .ui = .{ .tab_indicator = ind, .ascii = ascii },
    };
    const used = try p.tabStrip(1, 0, &.{
        .{ .label = " 1 One ", .target = .{ .tab = 0 }, .active = true },
        .{ .label = " 2 Two ", .target = .{ .tab = 1 } },
    });
    var out: [2][]const u8 = .{ "", "" };
    out[0] = try rowOf(gpa, &f, 0);
    out[1] = if (used == 2) try rowOf(gpa, &f, 1) else "";
    return out;
}

fn rowOf(gpa: Allocator, f: *frame_mod.Frame, y: u16) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) try out.appendSlice(gpa, f.slots[@as(usize, y) * f.cols + x].symbol());
    return out.toOwnedSlice(gpa);
}

test "the tab indicator draws each shape under the active label, and only `rule` lays a track" {
    const gpa = std.testing.allocator;
    // `block`: the half-block under `  1 One `, nothing either side.
    {
        const r = try stripRows(gpa, .block, false, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expect(std.mem.indexOf(u8, r[0], "1 One") != null);
        try std.testing.expectEqualStrings(" " ++ (tab_block ** 7) ++ " " ** 32, r[1]);
    }
    // `rule`: heavy under the active label, a light track over the rest
    // of the strip and nothing past its right edge.
    {
        const r = try stripRows(gpa, .rule, false, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ (tab_rule_active ** 7) ++ tab_rule ** 9 ++ " " ** 23, r[1]);
    }
    // `line`: the light rule under the active label only.
    {
        const r = try stripRows(gpa, .line, false, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ (tab_rule ** 7) ++ " " ** 32, r[1]);
    }
    // `quarter`: a quarter-height bar at the head of the row, flush under the active label only.
    {
        const r = try stripRows(gpa, .quarter, false, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ (tab_quarter ** 7) ++ " " ** 32, r[1]);
    }
    // `quarter_track`: the same bar across the strip, the active tab's stretch in colour.
    {
        const r = try stripRows(gpa, .quarter_track, false, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ (tab_quarter ** 16) ++ " " ** 23, r[1]);
    }
    // ascii: a stand-in for each, so a terminal without the font still
    // says which tab is on.
    {
        const r = try stripRows(gpa, .block, true, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ ("=" ** 7) ++ " " ** 32, r[1]);
    }
    {
        const r = try stripRows(gpa, .line, true, 20);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings(" " ++ ("-" ** 7) ++ " " ** 32, r[1]);
    }
    // A pane too short for the extra row spends none: the label wears
    // the terminal's underline attribute instead.
    {
        const r = try stripRows(gpa, .block, false, 6);
        defer gpa.free(r[0]);
        defer gpa.free(r[1]);
        try std.testing.expectEqualStrings("", r[1]);
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const Demo = union(enum) { row: u32, chip: u8, tab: u8, filter, hint: u8, detail, close, bar, show_more };
const P = Painter(Demo);

const Rig = struct {
    f: Frame,
    hits: hit.Map(Demo) = .{},
    arena: std.heap.ArenaAllocator,

    fn init(cols: u16, rows: u16) !Rig {
        return .{ .f = try Frame.init(testing.allocator, cols, rows), .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(r: *Rig) void {
        r.f.deinit();
        r.hits.deinit(testing.allocator);
        r.arena.deinit();
    }

    fn painter(r: *Rig, th: Theme, ui: Ui) P {
        return .{ .f = &r.f, .gpa = testing.allocator, .arena = r.arena.allocator(), .hits = &r.hits, .th = th, .ui = ui };
    }

    fn rowText(r: *Rig, y: u16) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var x: u16 = 0;
        while (x < r.f.cols) : (x += 1) {
            const s = r.f.slots[@as(usize, y) * r.f.cols + x].symbol();
            if (s.len == 0) continue;
            try out.appendSlice(r.arena.allocator(), s);
        }
        return std.mem.trimEnd(u8, try out.toOwnedSlice(r.arena.allocator()), " ");
    }
};

test "the gutter stripe runs the pane's whole height in the app colour, bright on the cursor's row" {
    var r = try Rig.init(20, 5);
    defer r.deinit();
    const th = Theme.fromHelloBranded(.{ .blue = .{ .rgb = .{ 1, 2, 3 } } }, "blue");
    var p = r.painter(th, .{});
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = 5 }, 2);
    var y: u16 = 0;
    while (y < 5) : (y += 1) {
        try testing.expectEqualStrings(gutter_glyph, r.f.slots[@as(usize, y) * 20].symbol());
        try testing.expectEqual(theme_mod.Color{ .rgb = .{ 1, 2, 3 } }, r.f.slots[@as(usize, y) * 20].style.fg.?);
    }
    try testing.expect(r.f.slots[2 * 20].style.mods.bold);
    try testing.expect(r.f.slots[0].style.mods.dim);
}

test "the header's chip ladder lays right to left and drops a chip whole rather than clipping it" {
    var r = try Rig.init(30, 2);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    const x = p.capsTitle(1, 0, "DEMO", "  (2 of 9)");
    const chips = [_]P.ChipSpec{
        .{ .text = " ? ", .target = .{ .chip = 0 } },
        .{ .text = " refresh ", .target = .{ .chip = 1 }, .active = true },
        .{ .text = " a very wide chip indeed ", .target = .{ .chip = 2 } },
    };
    const left = try p.rightChips(0, x, &chips);
    try testing.expect(left > x);
    try testing.expect(r.hits.rectOf(.{ .chip = 0 }) != null);
    try testing.expect(r.hits.rectOf(.{ .chip = 1 }) != null);
    // The third does not fit: it is not painted and not a target.
    try testing.expect(r.hits.rectOf(.{ .chip = 2 }) == null);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(0), "a very wide chip") == null);
}

test "the caps header's two runs never land on each other: the ladder is laid first and the age gives way" {
    const now: i64 = 1_789_526_218;
    const chips = [_]P.ChipSpec{
        .{ .text = help_chip_text, .target = .{ .chip = 0 } },
        .{ .text = " \u{21ba} ", .target = .{ .chip = 1 } },
        .{ .text = " author: all ", .target = .{ .chip = 2 } },
    };
    // Wide: the count, the age and every chip.
    {
        var r = try Rig.init(80, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        const head = try p.capsHeader(1, 0, "FORGE PRS", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.indexOf(u8, row, "FORGE PRS  (2 repos)  as of 9s ago") != null);
        try testing.expect(std.mem.indexOf(u8, row, " author: all ") != null);
        try testing.expect(head.x < head.edge);
    }
    // Narrow: the chips still fit, the age no longer does — so it is
    // dropped WHOLE. The forge pane used to paint it over the first
    // chip's words instead: `as of 9s agohor: all`.
    {
        var r = try Rig.init(46, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        _ = try p.capsHeader(1, 0, "FORGE PRS", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.indexOf(u8, row, "FORGE PRS  (2 repos)") != null);
        try testing.expect(std.mem.indexOf(u8, row, " author: all ") != null);
        try testing.expect(std.mem.indexOf(u8, row, "as of") == null);
        try testing.expect(std.mem.indexOf(u8, row, "agohor") == null);
    }
    // Narrower still: the count gives way to the ladder before the
    // title does, and the title is never clipped by it.
    {
        var r = try Rig.init(22, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        _ = try p.capsHeader(1, 0, "FORGE PRS", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.startsWith(u8, row, " FORGE PRS"));
        try testing.expect(r.hits.rectOf(.{ .chip = 0 }) != null);
        try testing.expect(r.hits.rectOf(.{ .chip = 2 }) == null);
    }
}

test "the filter pill: the placeholder at rest, the query with a caret while editing, one hit either way" {
    var r = try Rig.init(30, 2);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{ .ascii = true });
    try p.filterPill(.{ .x = 1, .y = 0, .w = 28, .h = 1 }, "", 0, false, .filter);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(0), "/ filter") != null);
    try p.filterPill(.{ .x = 1, .y = 1, .w = 28, .h = 1 }, "vouch", 5, true, .filter);
    const row = try r.rowText(1);
    try testing.expect(std.mem.indexOf(u8, row, "vouch") != null);
    try testing.expect(std.mem.indexOf(u8, row, caret_glyph) != null);
    try testing.expectEqual(Demo.filter, r.hits.at(4, 1).?);
}

test "a show-more row is one phrase: the ellipsis leads its own words, and the row is one hit" {
    var r = try Rig.init(40, 2);
    defer r.deinit();
    const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 9, 9, 9 } }, .muted = .{ .rgb = .{ 5, 5, 5 } } });
    var p = r.painter(th, .{});
    try p.showMoreRow(.{ .x = 0, .y = 0, .w = 40, .h = 1 }, 10, 7, .show_more);
    // `\u{22ef}  Show more (7)` from `label_x`, contiguous. The ellipsis
    // used to be pinned to the row's left edge while its words sat at
    // `label_x`, which at any real width read as two things.
    try testing.expect(std.mem.indexOf(u8, try r.rowText(0), "\u{22ef}  Show more (7)") != null);
    try testing.expectEqualStrings(more_glyph, r.f.slots[10].symbol());
    // Punctuation stays dim; only the words are bright.
    try testing.expectEqual(theme_mod.Color{ .rgb = .{ 5, 5, 5 } }, r.f.slots[10].style.fg.?);
    try testing.expect(!r.f.slots[10].style.mods.bold);
    try testing.expectEqualStrings("S", r.f.slots[13].symbol());
    try testing.expectEqual(theme_mod.Color{ .rgb = .{ 9, 9, 9 } }, r.f.slots[13].style.fg.?);
    try testing.expect(r.f.slots[13].style.mods.bold);
    // The whole row is the press, not just the words.
    try testing.expectEqual(Demo.show_more, r.hits.at(3, 0).?);
}

test "a detail panel carries a × in its corner and a scrollbar whose track is one hit" {
    var r = try Rig.init(20, 6);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    const box: Rect = .{ .x = 8, .y = 0, .w = 12, .h = 6 };
    try p.detailPanel(box, .detail, .close);
    try testing.expectEqualStrings(close_glyph, r.f.slots[19].symbol());
    try testing.expectEqual(Demo.close, r.hits.at(19, 0).?);
    try testing.expectEqual(Demo.detail, r.hits.at(10, 2).?);
    try p.scrollbar(.{ .x = 19, .y = 0, .w = 1, .h = 6 }, 30, 0, 6, .bar);
    try testing.expectEqual(Demo.bar, r.hits.at(19, 3).?);
    // The press maps back to a window position.
    try testing.expectEqual(@as(usize, 0), scrollAt(.{ .x = 19, .y = 0, .w = 1, .h = 6 }, 30, 6, 0));
    try testing.expectEqual(@as(usize, 24), scrollAt(.{ .x = 19, .y = 0, .w = 1, .h = 6 }, 30, 6, 5));
}

test "every hint entry is a hit; the front is dropped when the row will not fit" {
    var r = try Rig.init(20, 1);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    const hints = [_]P.HintSpec{
        .{ .key = "t", .title = "transition", .target = .{ .hint = 0 } },
        .{ .key = "a", .title = "assignee", .target = .{ .hint = 1 } },
        .{ .key = "q", .title = "quit", .target = .{ .hint = 2 } },
    };
    try p.hintRow(0, "", &hints);
    const row = try r.rowText(0);
    try testing.expect(std.mem.indexOf(u8, row, "q quit") != null);
    try testing.expect(std.mem.indexOf(u8, row, "t transition") == null);
    const q = r.hits.rectOf(.{ .hint = 2 }).?;
    try testing.expectEqual(Demo{ .hint = 2 }, r.hits.at(q.x, 0).?);
    try testing.expect(r.hits.rectOf(.{ .hint = 0 }) == null);
}

test "every listing in the family says how old it is, in the same words and the same ink" {
    var r = try Rig.init(60, 2);
    defer r.deinit();
    const th = Theme.fromHello(null);
    var p = r.painter(th, .{});
    const now: i64 = 1_789_526_218;

    var x = p.capsTitle(1, 0, "JIRA WORK", " (8)");
    x = p.asOf(x, 0, now - 4 * 60, now);
    try testing.expectEqualStrings(" JIRA WORK (8)  as of 4m ago", try r.rowText(0));
    // The same ink as the subtitle: the age is context, not a heading.
    try testing.expectEqual(th.dimText().fg, r.f.slots[@as(usize, x) - 1].style.fg);

    // A pane that has never fetched anything says nothing rather than
    // claiming to be current.
    const x0 = p.capsTitle(1, 1, "JIRA WORK", " (loading\u{2026})");
    try testing.expectEqual(x0, p.asOf(x0, 1, 0, now));
    try testing.expect(std.mem.indexOf(u8, try r.rowText(1), "as of") == null);
}
