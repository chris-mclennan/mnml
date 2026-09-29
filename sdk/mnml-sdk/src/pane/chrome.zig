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
const keysheet_mod = @import("keysheet.zig");
const budget_mod = @import("../budget.zig");
const columns_mod = @import("columns.zig");
const meter_mod = @import("meter.zig");

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

/// The six glyphs a frame and a rule are laid from — the host's
/// `single` set, or `+-|` under `--ascii`.
pub const FrameGlyphs = struct { tl: []const u8, tr: []const u8, bl: []const u8, br: []const u8, h: []const u8, v: []const u8 };
pub fn frameGlyphs(ascii: bool) FrameGlyphs {
    return if (ascii)
        .{ .tl = "+", .tr = "+", .bl = "+", .br = "+", .h = "-", .v = "|" }
    else
        .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" };
}

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

/// The in-flight spinner: the frames the host's SESSIONS section turns
/// while it scans (`src/ui/list_panel.zig`, `spinner_frames` /
/// `spinner_step_ms`), so a pane that is fetching turns the SAME glyph
/// at the SAME cadence as the host's own panels — one ring, wherever
/// the reader looks. `--ascii` gets the four-stroke wheel.
pub const spinner_frames = [_][]const u8{ "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280f}" };
pub const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };
/// One turn of the frame ring, in ms.
pub const spinner_step_ms: i64 = 80;

/// The frame the ring is on at `now_ms`.
pub fn spinnerFrame(now_ms: i64, ascii: bool) []const u8 {
    const frames: []const []const u8 = if (ascii) &spinner_ascii else &spinner_frames;
    const idx: usize = @intCast(@mod(@divFloor(now_ms, spinner_step_ms), @as(i64, @intCast(frames.len))));
    return frames[idx];
}

/// What a listing's fetch is doing right now — the one line a caps
/// header owes the reader while the rows are on their way. A pane that
/// waited a minute under `loading…` could not tell whether it was
/// fetching, queued behind the broker, or done with nothing; these are
/// the states it can be in, and `fetchText` is the one wording.
pub const Fetch = union(enum) {
    /// Nothing in flight.
    idle,
    /// A request is out. `done` / `total` when the pane counts repos
    /// on the way; 0 / 0 says only that it is fetching.
    fetching: struct { done: u32 = 0, total: u32 = 0 },
    /// Held in the local broker's queue, this many requests ahead.
    queued: u32,
    /// Held on the shared file bucket (no broker on this machine).
    waiting,
    /// The last fetch failed, and this is why.
    failed: []const u8,

    pub fn busy(f: Fetch) bool {
        return switch (f) {
            .fetching, .queued, .waiting => true,
            .idle, .failed => false,
        };
    }
};

/// The budget chip's ink by tier: the chip at rest while there is
/// room, yellow on the chip ground at the warning, red and bold at the
/// alarm — the host usage meter's two colours on its thresholds.
pub fn budgetStyle(th: Theme, tier: budget_mod.Tier) Style {
    return switch (tier) {
        .ok => th.chip(),
        .warn => .{ .fg = th.yellow, .bg = th.chip_bg },
        .alarm => .{ .fg = th.red, .bg = th.chip_bg, .mods = .{ .bold = true } },
    };
}

/// `fetching…` / `fetching… 2/13 repos` / `queued behind 3 requests` /
/// `waiting for the API budget` / `fetch failed: <why>`; "" when idle.
/// Written into `buf`.
pub fn fetchText(buf: []u8, f: Fetch, ascii: bool) []const u8 {
    const ell: []const u8 = if (ascii) "..." else "\u{2026}";
    return switch (f) {
        .idle => "",
        .fetching => |x| if (x.total > 0)
            std.fmt.bufPrint(buf, "fetching{s} {d}/{d} repos", .{ ell, x.done, x.total }) catch "fetching"
        else
            std.fmt.bufPrint(buf, "fetching{s}", .{ell}) catch "fetching",
        .queued => |n| if (n == 0)
            std.fmt.bufPrint(buf, "fetching{s}", .{ell}) catch "fetching"
        else
            std.fmt.bufPrint(buf, "queued behind {d} request{s}", .{ n, if (n == 1) "" else "s" }) catch "queued",
        .waiting => "waiting for the API budget",
        .failed => |why| std.fmt.bufPrint(buf, "fetch failed: {s}", .{why}) catch "fetch failed",
    };
}

/// What a caps header left behind: the cell its left-hand run ended
/// at, and the first cell the right-hand ladder took. Anything else a
/// pane wants on the row goes between them and is clipped at `edge`.
pub const CapsHeader = struct { x: u16, edge: u16 };

/// A chip on the header's right-hand ladder. `icon` is its narrow
/// rung — a glyph in its own air (a codicon, or its `--ascii` twin)
/// that `capsHeader` paints instead of `text` when the full ladder
/// would push the title's count off the row. A chip without one keeps
/// its words on every rung.
///
/// `style` overrides the chip's ink where the chip's colour IS what it
/// says — the budget chip's tier. Every other chip leaves it null and
/// wears the rest / active pair.
pub fn Chip(comptime Target: type) type {
    return struct { text: []const u8, target: Target, active: bool = false, icon: ?[]const u8 = null, style: ?Style = null };
}

/// The API budget chip's glyph (cod-dashboard) and its `--ascii` twin.
pub const budget_nerd = "\u{eacd}";
pub const budget_ascii = "~";

/// One `key label` entry of the hint row. `target` makes it clickable.
pub fn Hint(comptime Target: type) type {
    return struct { key: []const u8, title: []const u8, target: Target };
}

/// A tab on the strip.
pub fn Tab(comptime Target: type) type {
    return struct { label: []const u8, target: Target, active: bool = false };
}

/// One row of the key sheet: a section header (`section` set), or a
/// binding — its chord spelled with `keysheet.chords`, what it does,
/// and what a click on it runs (null: a row to read, not press).
pub fn SheetRow(comptime Target: type) type {
    return struct { section: []const u8 = "", chord: []const u8 = "", label: []const u8 = "", target: ?Target = null };
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
        pub const SheetRowSpec = SheetRow(Target);

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

        /// A table's column header row (`columns.headerFor`): names in
        /// `label()`, fitted to their widths with an ellipsis (`...`
        /// under `--ascii`, by the pane's `Ui`), `gap` cells between.
        pub fn columnHeader(p: *Self, x0: u16, y: u16, max_w: u16, list: anytype, gap: u16) u16 {
            if (y >= p.rows() or x0 >= p.cols()) return 0;
            return columns_mod.headerFor(p.f, x0, y, max_w, list, gap, p.th, p.ui.ascii or !p.ui.nerd);
        }

        /// A fill meter (`meter.paint`), `--ascii` twin by the pane's `Ui`.
        pub fn meter(p: *Self, x: u16, y: u16, cells: u16, frac: f64, tier: budget_mod.Tier) u16 {
            if (y >= p.rows() or x >= p.cols()) return 0;
            return meter_mod.paint(p.f, x, y, cells, frac, tier, p.th, p.ui.ascii or !p.ui.nerd);
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
            return p.rightChipsIn(y, left_edge, chips, .full);
        }

        /// Which rung of the ladder: every chip's words, or its icon
        /// where it has one.
        pub const Rung = enum { full, icon };

        fn chipText(c: ChipSpec, rung: Rung) []const u8 {
            return if (rung == .icon) c.icon orelse c.text else c.text;
        }

        /// Would every chip land, on `rung`, with nothing left of
        /// `left_edge`? The same arithmetic `rightChipsIn` paints with.
        fn ladderFits(p: *const Self, left_edge: u16, chips: []const ChipSpec, rung: Rung) bool {
            var right = p.cols();
            for (chips) |c| {
                const w = width(chipText(c, rung));
                if (right < left_edge + w + 2) return false;
                right -= w + 1;
            }
            return true;
        }

        pub fn rightChipsIn(p: *Self, y: u16, left_edge: u16, chips: []const ChipSpec, rung: Rung) Allocator.Error!u16 {
            var right = p.cols();
            for (chips) |c| {
                const text = chipText(c, rung);
                const w = width(text);
                if (right < left_edge + w + 2) break;
                right -= w + 1;
                _ = p.put(right, y, w, text, c.style orelse if (c.active) p.th.chipActive() else p.th.chip());
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
        ///
        /// Narrower, the ladder degrades before the count does, the way
        /// the host's panel headers do: first every chip that has an
        /// `icon` drops to it; only when even that ladder would cross
        /// the count is the count given up — WHOLE, never `(2 re` — and
        /// the icon ladder may then take everything past the title.
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
            // The rungs, widest first: the words beside the title and
            // its count; the icons beside them; the icons with the count
            // dropped, where the ladder may take everything past the
            // title. The title is never given up to the ladder.
            const title_end = x0 + width(title);
            const count_end = title_end + width(sub);
            const rung: Rung = if (p.ladderFits(count_end + 1, chips, .full)) .full else .icon;
            const keep_count = rung == .full or p.ladderFits(count_end + 1, chips, .icon);
            const right = try p.rightChipsIn(y, if (keep_count) count_end + 1 else title_end + 1, chips, rung);
            const edge = right -| 1;
            var x = x0;
            x += p.put(x, y, edge -| x, title, p.th.label());
            if (sub.len > 0 and keep_count) x += p.put(x, y, edge -| x, sub, p.th.dimText());
            var buf: [32]u8 = undefined;
            const age = warm_mod.asOfText(&buf, fetched_at, now_secs);
            if (age.len > 0 and x + 2 + width(age) <= edge) {
                x += p.put(x, y, edge -| x, "  ", p.th.dimText());
                x += p.put(x, y, edge -| x, age, p.th.dimText());
            }
            return .{ .x = x, .edge = edge };
        }

        /// The API budget chip, for the header ladder — the same chip
        /// in the same place on every pane in the family:
        /// ` <g> 812/1000 ` off the API's own headers, ` <g> 37/h ` when
        /// it sends none, ` <g> DRY ` in a dry run and ` <g> paused
        /// until 14:03:22 ` after a 429, in the host usage meter's
        /// tiers (`budget.Tier`). Its narrow rung is the glyph alone,
        /// still in the tier's ink. The hover is `help.budget`.
        pub fn budgetChip(p: *Self, snap: budget_mod.Snapshot, target: Target) ChipSpec {
            const g = if (p.ui.ascii or !p.ui.nerd) budget_ascii else budget_nerd;
            var buf: [48]u8 = undefined;
            const words = snap.chipWords(&buf);
            return .{
                .text = p.fmt(" {s} {s} ", .{ g, words }),
                .target = target,
                .icon = p.fmt(" {s} ", .{g}),
                .style = budgetStyle(p.th, snap.tier()),
            };
        }

        /// The refresh glyph as a chip's text, for the ladder.
        pub fn refreshChipText(p: *const Self) []const u8 {
            return if (p.ui.ascii or !p.ui.nerd) " " ++ refresh_ascii ++ " " else " " ++ refresh_nerd ++ " ";
        }

        /// The refresh chip's text while a fetch is in flight: the
        /// spinner, in the refresh chip's cells — where the host's own
        /// panels turn theirs (`list_panel.paintSpinner` overpaints the
        /// refresh chip). A pane passes `now_ms` off its clock; the
        /// ring is the same one at the same step on every pane.
        pub fn busyChipText(p: *Self, now_ms: i64) []const u8 {
            const g = spinnerFrame(now_ms, p.ui.ascii or !p.ui.nerd);
            return p.fmt(" {s} ", .{g});
        }

        /// The refresh chip's text: the spinner while `busy`, the glyph
        /// at rest — so a pane never has to choose.
        pub fn refreshOrBusyChipText(p: *Self, busy: bool, now_ms: i64) []const u8 {
            return if (busy) p.busyChipText(now_ms) else p.refreshChipText();
        }

        /// The header's fetch line as a subtitle fragment: two cells of
        /// air, the spinner, the words — `  ⠋ fetching…`; "" when idle,
        /// and a failure in the same place without a spinner.
        pub fn fetchSub(p: *Self, f: Fetch, now_ms: i64) []const u8 {
            const ascii = p.ui.ascii or !p.ui.nerd;
            var buf: [256]u8 = undefined;
            const words = fetchText(&buf, f, ascii);
            if (words.len == 0) return "";
            if (f.busy()) return p.fmt("  {s} {s}", .{ spinnerFrame(now_ms, ascii), words });
            return p.fmt("  {s}", .{words});
        }

        // ─── the toolbar row ─────────────────────────────────────────

        /// ` key: value ` — the mode chip's text, the same shape on
        /// every pane (`sort: Newest first` on the host's panels,
        /// `status: Open + Draft` on a forge pane).
        pub fn modeChipText(p: *Self, key: []const u8, value: []const u8) []const u8 {
            return p.fmt(" {s}: {s} ", .{ key, value });
        }

        /// A row of filter chips under the header: left to right from
        /// `x0` with a one-cell gap, wrapping to the next row when the
        /// next chip would clip at `max_x`, at most `max_rows` rows —
        /// the tracker pane's toolbar geometry, so the forge pane's
        /// filters sit where the tracker pane's do. Every chip is a
        /// hit over exactly its cells. Returns the rows used.
        pub fn toolbarRow(p: *Self, x0: u16, y0: u16, max_x: u16, max_rows: u16, chips: []const ChipSpec) Allocator.Error!u16 {
            if (max_rows == 0 or y0 >= p.rows()) return 0;
            var x = x0;
            var y = y0;
            var used: u16 = 1;
            for (chips) |c| {
                const w = width(c.text);
                if (x + w > max_x and x > x0) {
                    if (used >= max_rows or y + 1 >= p.rows()) break;
                    y += 1;
                    used += 1;
                    x = x0;
                }
                const cw = @min(w, max_x -| x);
                if (cw == 0) break;
                _ = p.put(x, y, cw, c.text, c.style orelse if (c.active) p.th.chipActive() else p.th.chip());
                try p.mark(.{ .x = x, .y = y, .w = cw, .h = 1 }, c.target);
                x += w + 1;
            }
            return used;
        }

        // ─── the tab strip ───────────────────────────────────────────

        /// The tab strip, and the row under it that marks the tab that
        /// is on.
        ///
        /// The active tab used to be marked with a `▌` to its left —
        /// mnml's own cursor glyph, doing a second job in a place that
        /// is not a list. It reads as a browser's tabs now: the label
        /// in the pane's brand colour, and an indicator on the row
        /// beneath. Which of the shapes is the host's
        /// `ui.tab_indicator`, carried on `hello`.
        ///
        /// One rule decides what the indicator row covers, for every
        /// shape: a tab OWNS its ink — the label with its padding
        /// trimmed — plus half of each gap beside it, so two neighbours
        /// meet at the gap's midpoint (an odd gap gives its extra cell
        /// to the tab on the left). Padding inside a label is gap, not
        /// ink; the label's hit rect still covers all of it. The active
        /// bar spans exactly what its tab owns, and a track (`rule`,
        /// `quarter_track`) runs from the first tab's ink to the last
        /// tab's ink and never past it — one tab wears one bar the width
        /// of its word, with no stub after it as if a second tab
        /// followed.
        ///
        /// Returns the rows it used — 2 normally, 1 in a pane too short
        /// to spend one on the indicator, where the active label
        /// carries the terminal's own underline attribute instead.
        pub fn tabStrip(p: *Self, x0: u16, y: u16, list: []const TabSpec) Allocator.Error!u16 {
            const ruled = p.rows() >= tab_rule_min_rows and y + 1 < p.rows();
            const Span = struct { start: u16, end: u16 };
            var x = x0;
            var track: Span = .{ .start = x0, .end = x0 };
            var active: ?Span = null;
            var prev_end: u16 = x0;
            for (list, 0..) |t, i| {
                const w = width(t.label);
                if (x + w > p.cols()) break;
                var style: Style = if (t.active) .{ .fg = p.th.brand, .mods = .{ .bold = true } } else p.th.tabInactive();
                // No room for the indicator: the attribute says it.
                if (t.active and !ruled) style.mods.underline = true;
                _ = p.put(x, y, w, t.label, style);
                try p.mark(.{ .x = x, .y = y, .w = w, .h = 1 }, t.target);
                const ink = inkSpan(t.label);
                const ink_start = x + ink.lead;
                const ink_end = ink_start + ink.vis;
                // The first tab starts at its ink; every other one where
                // its left neighbour stopped.
                const own_start = if (i == 0) ink_start else prev_end;
                // Half of the gap to the next tab that fits on the strip.
                // The last tab ends at its own ink.
                var own_end = ink_end;
                if (i + 1 < list.len) {
                    const next = list[i + 1];
                    const next_x = x + w + 1;
                    if (next_x + width(next.label) <= p.cols()) {
                        const gap = next_x + inkSpan(next.label).lead - ink_end;
                        own_end = ink_end + (gap + 1) / 2;
                    }
                }
                if (i == 0) track.start = own_start;
                track.end = own_end;
                prev_end = own_end;
                if (t.active) active = .{ .start = own_start, .end = own_end };
                x += w + 1;
            }
            if (!ruled) return 1;
            // Only `rule` and `quarter_track` lay a track along the
            // strip; the other shapes leave the row empty either side
            // of the active tab.
            if (p.ui.tab_indicator == .rule or p.ui.tab_indicator == .quarter_track) {
                const right = @min(track.end, p.cols());
                var i = track.start;
                const glyph = if (p.ui.tab_indicator == .quarter_track) (if (p.ui.ascii) tab_quarter_ascii else tab_quarter) else (if (p.ui.ascii) tab_rule_ascii else tab_rule);
                while (i < right) : (i += 1) _ = p.put(i, y + 1, 1, glyph, p.th.mutedText());
            }
            const glyph = switch (p.ui.tab_indicator) {
                .block => if (p.ui.ascii) tab_block_ascii else tab_block,
                .rule => if (p.ui.ascii) tab_rule_active_ascii else tab_rule_active,
                .line => if (p.ui.ascii) tab_rule_ascii else tab_rule,
                .quarter, .quarter_track => if (p.ui.ascii) tab_quarter_ascii else tab_quarter,
            };
            if (active) |a| {
                var i = a.start;
                while (i < a.end and i < p.cols()) : (i += 1) {
                    _ = p.put(i, y + 1, 1, glyph, .{ .fg = p.th.brand });
                }
            }
            return 2;
        }

        /// Where a tab label's ink is: the cells of padding before it,
        /// and the width of the text with its padding trimmed. A label
        /// that is all padding is taken whole, so it still gets a bar.
        fn inkSpan(label: []const u8) struct { lead: u16, vis: u16 } {
            const first = std.mem.indexOfNone(u8, label, " ") orelse return .{ .lead = 0, .vis = width(label) };
            const last = std.mem.lastIndexOfNone(u8, label, " ").? + 1;
            return .{ .lead = @intCast(first), .vis = width(label[first..last]) };
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
            try p.foldRow(rect, label_x, p.fmt("Show more ({d})", .{hidden}), target);
        }

        /// The fold row with its words given rather than counted — the
        /// same ellipsis, the same dim punctuation, the same bright
        /// label, for a row that folds something a count cannot say
        /// (a date window, say). `showMoreRow` is this with `Show more
        /// (N)` filled in.
        pub fn foldRow(p: *Self, rect: Rect, label_x: u16, label: []const u8, target: Target) Allocator.Error!void {
            if (rect.isEmpty()) return;
            var x = label_x;
            x += p.put(x, rect.y, 3, if (p.ui.ascii) more_ascii else more_glyph, p.th.dimText());
            x += p.put(x, rect.y, 2, "  ", p.th.dimText());
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

        /// The square frame every integration overlay wears — a
        /// picker, a key sheet, a row's menu, a kanban column. `+-+`
        /// under `--ascii`, the same as the host's popups. Two panes
        /// drew this by hand for a while and only one of them had the
        /// ascii half; this is the one copy now.
        pub fn frameBox(p: *Self, b: Rect, style: Style) void {
            if (b.w < 2 or b.h < 2) return;
            const g = frameGlyphs(p.ui.ascii);
            const right = b.x + b.w - 1;
            const bottom = b.y + b.h - 1;
            _ = p.put(b.x, b.y, 1, g.tl, style);
            _ = p.put(right, b.y, 1, g.tr, style);
            _ = p.put(b.x, bottom, 1, g.bl, style);
            _ = p.put(right, bottom, 1, g.br, style);
            var x = b.x + 1;
            while (x < right) : (x += 1) {
                _ = p.put(x, b.y, 1, g.h, style);
                _ = p.put(x, bottom, 1, g.h, style);
            }
            var y = b.y + 1;
            while (y < bottom) : (y += 1) {
                _ = p.put(b.x, y, 1, g.v, style);
                _ = p.put(right, y, 1, g.v, style);
            }
        }

        /// `frameBox` with the interior blanked first and `title` laid
        /// into the top edge after the corner, in `title_style`. The
        /// blank is what keeps the rows under an overlay from showing
        /// through it.
        pub fn frameTitled(p: *Self, b: Rect, style: Style, title: []const u8, title_style: Style) void {
            if (b.w < 2 or b.h < 2) return;
            p.fill(b, .none);
            p.frameBox(b, style);
            if (title.len > 0) _ = p.putFit(b.x + 1, b.y, b.w -| 2, title, title_style);
        }

        /// A vertical rule of `h` cells from (`x`, `y`) — the divider
        /// between a list and the detail beside it. `|` under `--ascii`.
        pub fn vrule(p: *Self, x: u16, y: u16, h: u16, style: Style) void {
            const g = frameGlyphs(p.ui.ascii).v;
            var i: u16 = 0;
            while (i < h) : (i += 1) _ = p.put(x, y + i, 1, g, style);
        }

        /// A horizontal rule of `w` cells from (`x`, `y`). `-` under
        /// `--ascii`.
        pub fn hrule(p: *Self, x: u16, y: u16, w: u16, style: Style) void {
            const g = frameGlyphs(p.ui.ascii).h;
            var i: u16 = 0;
            while (i < w) : (i += 1) _ = p.put(x + i, y, 1, g, style);
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

        // ─── the key sheet ───────────────────────────────────────────

        /// The `?` key sheet, in the host's help shape (`keysheet.zig`):
        /// a centred box titled ` Keys ` on the overlay ground, a
        /// `▾ ── name ── (n)` header per section, the chords in the
        /// accent padded to the widest, the label two cells on and
        /// wrapped under itself, a blank line between sections, the
        /// footer on the last inner row. `scroll` is clamped to the
        /// rows here. The box is one hit (`body_target`: the wheel, a
        /// press that closes); a binding with a target is a hit on each
        /// of its lines.
        pub fn keySheet(p: *Self, list: []const SheetRowSpec, scroll: *usize, body_target: Target) Allocator.Error!void {
            const th = p.th;
            const bw = @min(p.cols() -| 4, keysheet_mod.max_w);
            const bh = @min(p.rows() -| 2, keysheet_mod.max_h);
            if (bw < 24 or bh < 6) return;
            const box: Rect = .{ .x = (p.cols() - bw) / 2, .y = (p.rows() - bh) / 2, .w = bw, .h = bh };
            const ground = th.overlayBg();
            const on = struct {
                fn bg(g: Style, s: Style) Style {
                    var out = s;
                    out.bg = g.bg;
                    return out;
                }
            }.bg;
            p.fill(box, ground);
            p.frameBox(box, on(ground, th.overlayBorder()));
            _ = p.putFit(box.x + 1, box.y, box.w -| 2, keysheet_mod.title, on(ground, th.accentText()));
            try p.mark(box, body_target);

            const ix = box.x + 2;
            const iw = box.w -| 4;
            var chord_w: u16 = keysheet_mod.chord_min;
            for (list) |r| if (r.section.len == 0) {
                chord_w = @max(chord_w, @min(width(r.chord), keysheet_mod.chord_max));
            };
            const label_x = ix + 2 + chord_w + 2;
            const label_w = (box.x + box.w -| 2) -| label_x;

            // The lines: a header, then each binding over as many lines
            // as its label wraps to, a blank after each section.
            const Line = struct { header: []const u8 = "", chord: []const u8 = "", label: []const u8 = "", target: ?Target = null };
            var lines: std.ArrayList(Line) = .empty;
            const fold = if (p.ui.ascii) "v" else "\u{25be}";
            for (list, 0..) |r, ri| {
                if (r.section.len > 0) {
                    if (lines.items.len > 0) try lines.append(p.arena, .{});
                    var n: usize = 0;
                    for (list[ri + 1 ..]) |b| {
                        if (b.section.len > 0) break;
                        n += 1;
                    }
                    try lines.append(p.arena, .{ .header = p.fmt("{s} \u{2500}\u{2500} {s} \u{2500}\u{2500} ({d})", .{ fold, r.section, n }) });
                    continue;
                }
                var first = true;
                var rest = r.label;
                while (true) {
                    var cut = wrapAt(rest, label_w);
                    // A lone glyph wider than the column still moves on.
                    if (cut == 0) cut = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
                    try lines.append(p.arena, .{ .chord = if (first) r.chord else "", .label = std.mem.trimEnd(u8, rest[0..cut], " "), .target = r.target });
                    first = false;
                    rest = std.mem.trimStart(u8, rest[cut..], " ");
                    if (rest.len == 0) break;
                }
            }

            const body_h: usize = bh -| 3;
            const max_scroll = lines.items.len -| body_h;
            if (scroll.* > max_scroll) scroll.* = max_scroll;
            var y = box.y + 1;
            for (lines.items[scroll.*..]) |l| {
                if (y >= box.y + 1 + body_h) break;
                if (l.header.len > 0) {
                    _ = p.putFit(ix, y, iw, l.header, on(ground, th.bright()));
                } else if (l.chord.len > 0 or l.label.len > 0) {
                    if (l.chord.len > 0) _ = p.putFit(ix + 2, y, chord_w, l.chord, on(ground, th.accentPlain()));
                    _ = p.putFit(label_x, y, label_w, l.label, on(ground, th.text()));
                    if (l.target) |tg| try p.mark(.{ .x = box.x + 1, .y = y, .w = box.w -| 2, .h = 1 }, tg);
                }
                y += 1;
            }
            _ = p.putFit(ix, box.y + bh - 2, iw, if (p.ui.ascii) keysheet_mod.footer_ascii else keysheet_mod.footer, on(ground, th.dimText()));
        }

        /// Where to cut `s` so the piece fits `w` cells: after the last
        /// space that keeps it in, else hard at `w` (one long word).
        fn wrapAt(s: []const u8, w: u16) usize {
            if (width(s) <= w or w == 0) return s.len;
            var used: u16 = 0;
            var last_space: ?usize = null;
            var it = std.unicode.Utf8View.initUnchecked(s).iterator();
            var i: usize = 0;
            while (it.nextCodepointSlice()) |bytes| {
                if (bytes.len == 1 and bytes[0] == ' ') last_space = i;
                used += width(bytes);
                if (used > w) return if (last_space) |sp| (if (sp == 0) i else sp) else i;
                i += bytes.len;
            }
            return s.len;
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

/// One strip painted through the real `tabStrip` onto a `cols`-wide
/// frame `rows` high, at `x0 = 1`: `labels` in order, the one at
/// `active` on. Two readings of the indicator row come back: the
/// glyphs as a string, and the SHAPE — `A` where the cell is in the
/// brand colour (the active bar), `t` where it is a muted track cell,
/// space where it is empty — since a `quarter_track` row is one glyph
/// end to end and only the colour says where the bar stops. Both are
/// `""` when the pane was too short to spend the row. The hit map is
/// probed too: `hit_first` / `hit_last` are what a press on the FIRST
/// tab's first and last cell resolves to.
const Strip = struct {
    row: []const u8,
    shape: []const u8,
    hit_first: ?u8,
    hit_last: ?u8,

    fn deinit(s: Strip, gpa: Allocator) void {
        gpa.free(s.row);
        gpa.free(s.shape);
    }
};

fn strip(gpa: Allocator, ind: wire_mod.TabIndicator, ascii: bool, cols: u16, rows: u16, labels: []const []const u8, active: usize) !Strip {
    const Target = union(enum) { tab: u8 };
    const brand: theme_mod.Color = .{ .index = 5 };
    var f = try frame_mod.Frame.init(gpa, cols, rows);
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
        .th = .{ .brand = brand },
        .ui = .{ .tab_indicator = ind, .ascii = ascii },
    };
    var list: std.ArrayListUnmanaged(Painter(Target).TabSpec) = .empty;
    defer list.deinit(gpa);
    for (labels, 0..) |l, i| try list.append(gpa, .{ .label = l, .target = .{ .tab = @intCast(i) }, .active = i == active });
    const used = try p.tabStrip(1, 0, list.items);
    const first_w = width(labels[0]);
    const hit_first: ?u8 = if (hits.at(1, 0)) |t| t.tab else null;
    const hit_last: ?u8 = if (hits.at(first_w, 0)) |t| t.tab else null;
    if (used != 2) return .{ .row = try gpa.dupe(u8, ""), .shape = try gpa.dupe(u8, ""), .hit_first = hit_first, .hit_last = hit_last };
    var shape: std.ArrayListUnmanaged(u8) = .empty;
    defer shape.deinit(gpa);
    var x: u16 = 0;
    while (x < cols) : (x += 1) {
        const slot = f.slots[@as(usize, 1) * cols + x];
        const blank = std.mem.eql(u8, std.mem.trim(u8, slot.symbol(), " "), "");
        const fg = slot.style.fg;
        try shape.append(gpa, if (blank) ' ' else if (fg != null and std.meta.eql(fg.?, brand)) 'A' else 't');
    }
    return .{ .row = try rowOf(gpa, &f, 1), .shape = try shape.toOwnedSlice(gpa), .hit_first = hit_first, .hit_last = hit_last };
}

fn rowOf(gpa: Allocator, f: *frame_mod.Frame, y: u16) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) try out.appendSlice(gpa, f.slots[@as(usize, y) * f.cols + x].symbol());
    return out.toOwnedSlice(gpa);
}

const two_padded = [_][]const u8{ " 1 One ", " 2 Two " };

test "one tab wears one bar the width of its word — no track stub after it as if a second tab followed" {
    const gpa = std.testing.allocator;
    // ` 1 One ` at x 1: the ink is `1 One`, cells 2..7. The track ends
    // with the ink; nothing at cell 7 where the padding and the gap were.
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &.{" 1 One "}, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_quarter ** 5) ++ " " ** 33, s.row);
        try std.testing.expectEqualStrings("  AAAAA" ++ " " ** 33, s.shape);
    }
    // `rule`: the heavy bar and not one cell of the light track.
    {
        const s = try strip(gpa, .rule, false, 40, 20, &.{" 1 One "}, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_rule_active ** 5) ++ " " ** 33, s.row);
        try std.testing.expect(std.mem.indexOf(u8, s.row, tab_rule) == null);
    }
}

test "two tabs meet at the midpoint of the gap between their words — an odd gap gives its extra cell to the left tab" {
    const gpa = std.testing.allocator;
    // ` 1 One ` ` 2 Two ` at x 1: ink 2..7 and 10..15, a gap of three
    // (padding, separator, padding). Two go left, one right: the tabs
    // own 2..9 and 9..15, and the track is the union, 2..15.
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_quarter ** 13) ++ " " ** 25, s.row);
        try std.testing.expectEqualStrings("  AAAAAAAtttttt" ++ " " ** 25, s.shape);
    }
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &two_padded, 1);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  tttttttAAAAAA" ++ " " ** 25, s.shape);
    }
    // `One ` `Two` at x 1: ink 1..4 and 6..9, a gap of two (the first
    // label's padding and the separator) — one cell each: 1..5 and 5..9.
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &.{ "One ", "Two" }, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings(" AAAAtttt" ++ " " ** 31, s.shape);
    }
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &.{ "One ", "Two" }, 1);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings(" ttttAAAA" ++ " " ** 31, s.shape);
    }
}

test "padding inside a label is gap, not ink — the bar measures the trimmed word while the hit rect keeps the whole label" {
    const gpa = std.testing.allocator;
    // `   1 One   ` (three each side) and `  2 Two  ` (two each side)
    // at x 1: ink 4..9 and 15..20, a gap of six — three each: the tabs
    // own 4..12 and 12..20, and the track starts at 4, not at 1.
    const s = try strip(gpa, .quarter_track, false, 40, 20, &.{ "   1 One   ", "  2 Two  " }, 0);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("    AAAAAAAAtttttttt" ++ " " ** 20, s.shape);
    // A press on the first label's first cell (x 1) and its last cell
    // (x 11) — both padding — still lands on tab 0.
    try std.testing.expectEqual(@as(?u8, 0), s.hit_first);
    try std.testing.expectEqual(@as(?u8, 0), s.hit_last);
}

test "every indicator shape spans the same ownership: the word plus half the gap, and only `rule` / `quarter_track` lay a track" {
    const gpa = std.testing.allocator;
    // `block`: the half-block over the first tab's 2..9, nothing either side.
    {
        const s = try strip(gpa, .block, false, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_block ** 7) ++ " " ** 31, s.row);
        try std.testing.expectEqualStrings("  AAAAAAA" ++ " " ** 31, s.shape);
    }
    // `rule`: heavy over 2..9, the light track on to the last word's end
    // at 15, and nothing past it.
    {
        const s = try strip(gpa, .rule, false, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_rule_active ** 7) ++ (tab_rule ** 6) ++ " " ** 25, s.row);
        try std.testing.expectEqualStrings("  AAAAAAAtttttt" ++ " " ** 25, s.shape);
    }
    // `line`: the light rule over the active tab only.
    {
        const s = try strip(gpa, .line, false, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_rule ** 7) ++ " " ** 31, s.row);
    }
    // `quarter`: the quarter bar over the active tab only.
    {
        const s = try strip(gpa, .quarter, false, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_quarter ** 7) ++ " " ** 31, s.row);
    }
    // `quarter_track`: the same bar along the track, the active stretch in colour.
    {
        const s = try strip(gpa, .quarter_track, false, 40, 20, &two_padded, 1);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ (tab_quarter ** 13) ++ " " ** 25, s.row);
        try std.testing.expectEqualStrings("  tttttttAAAAAA" ++ " " ** 25, s.shape);
    }
}

test "the ascii twins draw the same ownership, so a terminal without the font still says where a tab ends" {
    const gpa = std.testing.allocator;
    {
        const s = try strip(gpa, .block, true, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("=" ** 7) ++ " " ** 31, s.row);
    }
    {
        const s = try strip(gpa, .rule, true, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("=" ** 7) ++ ("-" ** 6) ++ " " ** 25, s.row);
    }
    {
        const s = try strip(gpa, .line, true, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("-" ** 7) ++ " " ** 31, s.row);
    }
    {
        const s = try strip(gpa, .quarter, true, 40, 20, &two_padded, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("_" ** 7) ++ " " ** 31, s.row);
    }
    {
        const s = try strip(gpa, .quarter_track, true, 40, 20, &two_padded, 1);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("_" ** 13) ++ " " ** 25, s.row);
        try std.testing.expectEqualStrings("  tttttttAAAAAA" ++ " " ** 25, s.shape);
    }
    // One tab in ascii: the same no-stub rule.
    {
        const s = try strip(gpa, .quarter_track, true, 40, 20, &.{" 1 One "}, 0);
        defer s.deinit(gpa);
        try std.testing.expectEqualStrings("  " ++ ("_" ** 5) ++ " " ** 33, s.row);
    }
}

test "a tab that does not fit the strip is not laid out, and the track stops at the last word that did" {
    const gpa = std.testing.allocator;
    // Twelve columns: ` 2 Two ` would start at 9 and end at 16, so it
    // is dropped, and the track is the first word alone — no half-gap
    // reaching toward a tab that is not there.
    const s = try strip(gpa, .quarter_track, false, 12, 20, &two_padded, 0);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("  AAAAA" ++ " " ** 5, s.shape);
}

test "a pane too short for the indicator row spends none: the label wears the terminal's underline instead" {
    const gpa = std.testing.allocator;
    const s = try strip(gpa, .block, false, 40, 6, &two_padded, 0);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("", s.row);
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

test "the caps header's narrow rung: chips drop to their icons before the count goes, and the count goes whole" {
    const now: i64 = 1_789_526_218;
    const chips = [_]P.ChipSpec{
        .{ .text = help_chip_text, .target = .{ .chip = 0 } },
        .{ .text = " \u{21ba} ", .target = .{ .chip = 1 } },
        .{ .text = " usage ", .target = .{ .chip = 2 }, .icon = " % " },
        .{ .text = " run pipeline ", .target = .{ .chip = 3 }, .icon = " > " },
    };
    // Wide: every word, the count, the age.
    {
        var r = try Rig.init(80, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        _ = try p.capsHeader(1, 0, "PIPES", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.indexOf(u8, row, "PIPES  (2 repos)  as of 9s ago") != null);
        try testing.expect(std.mem.indexOf(u8, row, " run pipeline ") != null);
        try testing.expect(std.mem.indexOf(u8, row, " usage ") != null);
    }
    // The words would cross the count: the icons, and the count whole.
    {
        var r = try Rig.init(36, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        const head = try p.capsHeader(1, 0, "PIPES", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.indexOf(u8, row, "PIPES  (2 repos)") != null);
        try testing.expect(std.mem.indexOf(u8, row, "run pipeline") == null);
        try testing.expect(std.mem.indexOf(u8, row, " > ") != null);
        try testing.expect(std.mem.indexOf(u8, row, " % ") != null);
        try testing.expectEqual(@as(u16, 3), r.hits.rectOf(.{ .chip = 3 }).?.w);
        try testing.expect(head.x <= head.edge);
    }
    // Even the icons would cross it: the count is dropped WHOLE — never
    // `(2 re` — and the ladder keeps every chip.
    {
        var r = try Rig.init(28, 1);
        defer r.deinit();
        var p = r.painter(Theme.fromHello(null), .{});
        _ = try p.capsHeader(1, 0, "PIPES", "  (2 repos)", now - 9, now, &chips);
        const row = try r.rowText(0);
        try testing.expect(std.mem.startsWith(u8, row, " PIPES"));
        try testing.expect(std.mem.indexOf(u8, row, "(2") == null);
        for (0..4) |i| try testing.expect(r.hits.rectOf(.{ .chip = @intCast(i) }) != null);
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

test "the frame and the rules come from one glyph set, with an ascii twin" {
    var r = try Rig.init(8, 4);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    p.frameTitled(.{ .x = 0, .y = 0, .w = 6, .h = 3 }, .none, "T", .none);
    p.vrule(7, 0, 3, .none);
    p.hrule(0, 3, 8, .none);
    try testing.expectEqualStrings("┌T───┐ │", try r.rowText(0));
    try testing.expectEqualStrings("│    │ │", try r.rowText(1));
    try testing.expectEqualStrings("└────┘ │", try r.rowText(2));
    try testing.expectEqualStrings("────────", try r.rowText(3));

    var a = try Rig.init(8, 4);
    defer a.deinit();
    var q = a.painter(Theme.fromHello(null), .{ .ascii = true });
    q.frameTitled(.{ .x = 0, .y = 0, .w = 6, .h = 3 }, .none, "T", .none);
    q.vrule(7, 0, 3, .none);
    q.hrule(0, 3, 8, .none);
    try testing.expectEqualStrings("+T---+ |", try a.rowText(0));
    try testing.expectEqualStrings("|    | |", try a.rowText(1));
    try testing.expectEqualStrings("+----+ |", try a.rowText(2));
    try testing.expectEqualStrings("--------", try a.rowText(3));
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

test "the fetch line names every state a listing can be in, and the spinner is the host's ring at the host's step" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", fetchText(&buf, .idle, false));
    try testing.expectEqualStrings("fetching\u{2026}", fetchText(&buf, .{ .fetching = .{} }, false));
    try testing.expectEqualStrings("fetching...", fetchText(&buf, .{ .fetching = .{} }, true));
    try testing.expectEqualStrings("fetching\u{2026} 2/13 repos", fetchText(&buf, .{ .fetching = .{ .done = 2, .total = 13 } }, false));
    try testing.expectEqualStrings("queued behind 3 requests", fetchText(&buf, .{ .queued = 3 }, false));
    try testing.expectEqualStrings("queued behind 1 request", fetchText(&buf, .{ .queued = 1 }, false));
    // Queued behind nobody is not a queue worth a word.
    try testing.expectEqualStrings("fetching\u{2026}", fetchText(&buf, .{ .queued = 0 }, false));
    try testing.expectEqualStrings("waiting for the API budget", fetchText(&buf, .waiting, false));
    try testing.expectEqualStrings("fetch failed: 401 auth failed", fetchText(&buf, .{ .failed = "401 auth failed" }, false));
    try testing.expect(Fetch.busy(.{ .queued = 2 }));
    try testing.expect(!Fetch.busy(.{ .failed = "x" }));
    try testing.expect(!Fetch.busy(.idle));
    // The ring: ten braille frames, 80 ms a step, wrapping.
    try testing.expectEqual(@as(usize, 10), spinner_frames.len);
    try testing.expectEqual(@as(i64, 80), spinner_step_ms);
    try testing.expectEqualStrings(spinner_frames[0], spinnerFrame(0, false));
    try testing.expectEqualStrings(spinner_frames[1], spinnerFrame(80, false));
    try testing.expectEqualStrings(spinner_frames[0], spinnerFrame(800, false));
    try testing.expectEqualStrings("/", spinnerFrame(80, true));

    // Through the painter: the refresh chip becomes the spinner while
    // busy and the subtitle fragment carries the words behind it.
    var r = try Rig.init(60, 2);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{ .nerd = true });
    try testing.expectEqualStrings(" " ++ refresh_nerd ++ " ", p.refreshOrBusyChipText(false, 160));
    try testing.expectEqualStrings(" \u{2839} ", p.refreshOrBusyChipText(true, 160));
    try testing.expectEqualStrings("  \u{2839} fetching\u{2026}", p.fetchSub(.{ .fetching = .{} }, 160));
    try testing.expectEqualStrings("  fetch failed: no", p.fetchSub(.{ .failed = "no" }, 160));
    try testing.expectEqualStrings("", p.fetchSub(.idle, 160));
}

test "the toolbar row lays chips left to right, wraps whole chips, and every chip is a hit over its cells" {
    var r = try Rig.init(30, 3);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    const chips = [_]P.ChipSpec{
        .{ .text = p.modeChipText("status", "Open + Draft"), .target = .{ .chip = 0 }, .active = true },
        .{ .text = p.modeChipText("author", "all"), .target = .{ .chip = 1 } },
        .{ .text = p.modeChipText("target", "any"), .target = .{ .chip = 2 } },
    };
    // 1 + 21 + 1 + 13 = 36 > 30: the second chip wraps whole.
    const used = try p.toolbarRow(1, 0, 30, 2, &chips);
    try testing.expectEqual(@as(u16, 2), used);
    try testing.expectEqualStrings("  status: Open + Draft", try r.rowText(0));
    try testing.expectEqualStrings("  author: all   target: any", try r.rowText(1));
    try testing.expectEqual(@as(u16, 1), r.hits.rectOf(.{ .chip = 1 }).?.x);
    try testing.expectEqual(@as(u16, 1), r.hits.rectOf(.{ .chip = 1 }).?.y);
    try testing.expectEqual(@as(u16, 13), r.hits.rectOf(.{ .chip = 1 }).?.w);
    try testing.expectEqual(@as(u16, 15), r.hits.rectOf(.{ .chip = 2 }).?.x);
    // One row allowed: what does not fit is dropped whole, not clipped.
    r.hits.reset();
    var r2 = try Rig.init(30, 3);
    defer r2.deinit();
    var p2 = r2.painter(Theme.fromHello(null), .{});
    try testing.expectEqual(@as(u16, 1), try p2.toolbarRow(1, 0, 30, 1, &chips));
    try testing.expect(r2.hits.rectOf(.{ .chip = 1 }) == null);
    try testing.expect(std.mem.indexOf(u8, try r2.rowText(0), "author") == null);
}

test "the key sheet: one box for every pane — counted headers, padded chords, a long label wrapped under itself, Esc in the footer, every line of a row a hit" {
    // hunt/findings-2026-09-23/integ-keysheet-two-components.md
    var r = try Rig.init(60, 20);
    defer r.deinit();
    var p = r.painter(Theme.fromHello(null), .{});
    const rows = [_]P.SheetRowSpec{
        .{ .section = "navigation" },
        .{ .chord = "\u{2191} / k", .label = "up", .target = .{ .hint = 1 } },
        .{ .chord = "PgDn", .label = "page down", .target = .{ .hint = 2 } },
        .{ .section = "tree" },
        .{ .chord = "\u{2192} / l", .label = "expand, or step into the first child of the row under the cursor", .target = .{ .hint = 3 } },
    };
    var scroll: usize = 99;
    try p.keySheet(&rows, &scroll, .detail);
    // The scroll is clamped to the rows.
    try testing.expectEqual(@as(usize, 0), scroll);
    const box = r.hits.rectOf(.detail).?;
    try testing.expectEqual(@as(u16, 56), box.w);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(box.y), " Keys ") != null);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(box.y + 1), "\u{25be} \u{2500}\u{2500} navigation \u{2500}\u{2500} (2)") != null);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(box.y + 2), "\u{2191} / k     up") != null);
    // A blank line, then the next section.
    try testing.expect(std.mem.indexOf(u8, try r.rowText(box.y + 5), "\u{2500}\u{2500} tree \u{2500}\u{2500} (1)") != null);
    // The long label is whole, over two lines, not clipped.
    const l1 = try r.rowText(box.y + 6);
    const l2 = try r.rowText(box.y + 7);
    try testing.expect(std.mem.indexOf(u8, l1, "expand, or step into") != null);
    try testing.expect(std.mem.indexOf(u8, l2, "cursor") != null);
    try testing.expect(std.mem.indexOf(u8, l1, "\u{2026}") == null);
    try testing.expectEqual(Demo{ .hint = 3 }, r.hits.at(box.x + 30, box.y + 7).?);
    try testing.expect(std.mem.indexOf(u8, try r.rowText(box.y + box.h - 2), "j/k scroll \u{b7} Esc close") != null);
}
