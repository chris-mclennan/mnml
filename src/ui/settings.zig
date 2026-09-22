//! Settings overlay — the family idiom for a settings screen: a centered,
//! scrollable list in sections (`── UI ──`, `── Editor ──`, …), one row
//! per setting as `▸ Label:  [active] / other / other  *`, where `▸`
//! marks focus, `[brackets]` the current choice and a trailing `*` a
//! value that differs from the shipped default. Labels pad so the
//! colons line up within the box.
//!
//! The component owns the cursor and the scroll; what a key *means* is
//! handed back as an `Outcome` (adjust this row by ±1, reset it, reset
//! everything, save, cancel) so the app decides what a change does and
//! where it is written. Every row registers `.overlay_item(id)`, and
//! every option chip its own id, so a click can focus a row or jump
//! straight to a value.
//!
//! The list is longer than any box that caps at 70 % of the screen, so
//! the sections below the fold need to be *visible*, not merely
//! reachable: the box carries a section strip under its title (a click
//! jumps, `]` / `[` step, `g` / `G` are the ends), a proportional
//! scrollbar down its right edge from `src/ui/scrollbar.zig` (drag and
//! click-on-track like every other list), and a `12–40 of 97` position
//! in the footer for the boxes too narrow for a bar.
//!
//! // changed (settings-search): ninety rows is more than a strip and a
//! scrollbar can answer for, so `/` opens the family filter pill under
//! the title and the list narrows live — over the label, the current
//! value's word and the section name. The strip stays put beneath it
//! (dimmed where a section has no match), because which sections still
//! hold something *is* the search result; a pill that replaced it would
//! throw away the one affordance the search needs most.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const scrollbar = @import("scrollbar.zig");
const text_field = @import("text_field.zig");
const filter_input = @import("filter_input.zig");
const confirm_ui = @import("confirm.zig");
const ids = @import("../core/ids.zig");
const key_mod = @import("../core/key.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;
pub const Caret = text_field.Caret;

/// One line of the list.
pub const Item = union(enum) {
    /// `── name ──`
    section: []const u8,
    row: Row,
    /// The `Reset all to defaults` action row.
    action: Action,

    pub fn focusable(it: Item) bool {
        return it != .section;
    }
};

pub const Row = struct {
    label: []const u8,
    /// Every choice, in order; `current` indexes it. Empty for a
    /// number row, where `current` is the value itself.
    options: []const []const u8,
    current: usize,
    /// Differs from the shipped default — paints the trailing `*`.
    modified: bool = false,
    /// What `.overlay_item` carries for the row itself; option chips
    /// register `optionHit(id, i)`.
    id: u32,
    /// // changed: a number row — `‹ [value] ›` stepped by ←→; the two
    /// arrows register `optionHit(id, 0)` (down) and `optionHit(id, 1)`
    /// (up). The family convention calls number rows v2; this is the
    /// minimal step form.
    number: ?Number = null,

    pub const Number = struct { min: usize, max: usize, step: usize };
};

pub const Action = struct {
    label: []const u8,
    id: u32,
};

/// Hit ids: a row is `id`; its option `i` is `option_base + id * option_stride + i`;
/// a name in the section strip is `section_base + n`; the box itself is
/// `surface_id`, so a click on its frame is not a click outside.
pub const option_base: u32 = 1 << 20;
pub const option_stride: u32 = 256;
pub const section_base: u32 = 1 << 19;
pub const surface_id: u32 = option_base - 1;
/// // changed (settings-search): the filter pill's own hit, just below
/// the section range so a row id can never reach it.
pub const filter_id: u32 = section_base - 1;

/// The `.scrollbar` owner the settings box's bar registers under.
pub const scrollbar_owner: ids.PaneId = std.math.maxInt(ids.PaneId) - 2;

pub fn optionHit(id: u32, i: usize) u32 {
    return option_base + id * option_stride + @as(u32, @intCast(i));
}

pub fn sectionHit(n: usize) u32 {
    return section_base + @as(u32, @intCast(n));
}

pub const Hit = union(enum) { surface, filter, row: u32, option: struct { id: u32, index: usize }, section: usize };

pub fn decodeHit(h: u32) Hit {
    if (h == surface_id) return .surface;
    if (h == filter_id) return .filter;
    if (h >= section_base and h < option_base) return .{ .section = h - section_base };
    if (h < option_base) return .{ .row = h };
    const rel = h - option_base;
    return .{ .option = .{ .id = rel / option_stride, .index = rel % option_stride } };
}

/// // changed (settings-search): the filter pill's state — open (the
/// row is painted), focused (it has the keys) and the field itself. The
/// text is a `text_field`, so the caret, the arrows, Home/End, the word
/// deletes and a paste come with it rather than being bolted on later.
pub const Filter = struct {
    open: bool = false,
    focused: bool = false,
    buf: text_field.Buf = .empty,
    caret: usize = 0,

    pub fn deinit(f: *Filter, gpa: Allocator) void {
        f.buf.deinit(gpa);
        f.* = .{};
    }

    pub fn text(f: *const Filter) []const u8 {
        return f.buf.items;
    }

    /// Something to clear: the pill is up, or a query is narrowing the
    /// list even though the keys have gone back to it.
    pub fn active(f: *const Filter) bool {
        return f.open or f.buf.items.len != 0;
    }

    /// A paste into the query, at the caret.
    pub fn insert(f: *Filter, gpa: Allocator, str: []const u8) Allocator.Error!void {
        try text_field.insert(&f.buf, &f.caret, gpa, str);
    }

    /// Esc's first press: the query goes, the pill goes, the keys are
    /// the list's again.
    pub fn clear(f: *Filter) void {
        f.buf.clearRetainingCapacity();
        f.caret = 0;
        f.open = false;
        f.focused = false;
    }
};

pub const State = struct {
    /// Index into the items slice; always on a focusable item once
    /// `settle` has run.
    cursor: usize = 0,
    scroll: usize = 0,
    /// Rows the list showed last frame — paging reads it.
    rows: usize = 0,
    /// // changed (settings-search): `/` (and Ctrl+F in the standard
    /// profile) opens this.
    filter: Filter = .{},
    /// // changed (settings-reset-confirm): the "reset everything?" box,
    /// painted over the list while it is up and holding every key. Its
    /// strings are static, so there is nothing to free.
    confirm: ?confirm_ui.State = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.filter.deinit(gpa);
    }

    /// `/` (and Ctrl+F in the standard profile), and a click on the
    /// pill: the row appears and takes the keys, the query it already
    /// holds left alone.
    pub fn openFilter(s: *State) void {
        s.filter.open = true;
        s.filter.focused = true;
    }

    /// // changed (settings-reset-confirm): `R`, and the Reset section's
    /// action row, ask before they throw away every setting. Cancel is
    /// focused, so Enter on reflex is the harmless answer.
    pub fn askResetAll(s: *State) void {
        s.confirm = .{
            .title = reset_confirm_title,
            .message = reset_confirm_message,
            .choices = &reset_confirm_choices,
            .selected = 1,
        };
    }

    /// Move the cursor onto a focusable item (the first at or after it).
    pub fn settle(s: *State, items: []const Item) void {
        if (items.len == 0) return;
        if (s.cursor >= items.len) s.cursor = items.len - 1;
        var i = s.cursor;
        while (i < items.len) : (i += 1) if (items[i].focusable()) {
            s.cursor = i;
            return;
        };
        i = s.cursor;
        while (true) : (i -= 1) {
            if (items[i].focusable()) {
                s.cursor = i;
                return;
            }
            if (i == 0) return;
        }
    }

    fn move(s: *State, items: []const Item, delta: isize) void {
        var i: isize = @intCast(s.cursor);
        while (true) {
            i += delta;
            if (i < 0 or i >= @as(isize, @intCast(items.len))) return;
            if (items[@intCast(i)].focusable()) {
                s.cursor = @intCast(i);
                return;
            }
        }
    }

    fn moveBy(s: *State, items: []const Item, delta: isize) void {
        var n: usize = @abs(delta);
        while (n > 0) : (n -= 1) s.move(items, if (delta < 0) -1 else 1);
    }

    /// The wheel: the window slides `delta` lines and the cursor is
    /// pulled along so it stays inside — `draw` scrolls to the cursor,
    /// so a cursor left behind would drag the window straight back.
    /// A no-op before the first draw (`rows` is unknown).
    pub fn wheel(s: *State, items: []const Item, delta: isize) void {
        if (s.rows == 0 or items.len == 0) return;
        const max_scroll: isize = @intCast(items.len -| s.rows);
        s.scrollTo(items, @intCast(std.math.clamp(@as(isize, @intCast(s.scroll)) + delta, 0, max_scroll)));
    }

    /// Put the window at `first` and pull the cursor in after it. Every
    /// way of moving the *view* rather than the cursor — the wheel, a
    /// scrollbar drag, a section jump — lands here, because `draw`
    /// scrolls back to the cursor and a cursor left behind would undo
    /// the move on the next frame.
    pub fn scrollTo(s: *State, items: []const Item, first: usize) void {
        if (items.len == 0) return;
        s.scroll = @min(first, items.len -| @max(s.rows, 1));
        if (s.rows == 0) return;
        if (s.cursor < s.scroll) {
            s.cursor = s.scroll;
            s.settle(items);
        } else if (s.cursor >= s.scroll + s.rows) {
            s.cursor = s.scroll + s.rows - 1;
            s.settleBack(items);
        }
    }

    /// A press or drag at `off` rows down a `track_h`-tall scrollbar:
    /// the pointer's fraction of the track becomes the window's
    /// fraction of the list, the way every other bar in the app reads.
    pub fn barJump(s: *State, items: []const Item, off: usize, track_h: usize) void {
        if (track_h == 0 or items.len == 0) return;
        s.scrollTo(items, (off * items.len) / track_h);
    }

    /// Top / bottom — `g` and `G`, and Home / End.
    pub fn toTop(s: *State, items: []const Item) void {
        s.cursor = 0;
        s.settle(items);
        s.scroll = 0;
    }

    pub fn toBottom(s: *State, items: []const Item) void {
        s.cursor = items.len -| 1;
        s.settleBack(items);
        s.scroll = items.len -| @max(s.rows, 1);
    }

    /// `]` / `[`: the cursor lands on the first row of the next /
    /// previous section and that section's header goes to the top of
    /// the window, so the name the user jumped to is on screen rather
    /// than one row above it. `[` from anywhere but a section's first
    /// row goes back to that section's own header first, as vim's `[[`
    /// does.
    pub fn jumpSection(s: *State, items: []const Item, delta: i8) void {
        const count = sectionCount(items);
        if (count == 0) return;
        const here = sectionOf(items, s.cursor) orelse 0;
        var target: usize = here;
        if (delta > 0) {
            if (here + 1 >= count) return s.toBottom(items);
            target = here + 1;
        } else {
            const head = sectionHeader(items, here) orelse return;
            // Already at the top of this section: step to the one before.
            if (s.cursor <= head + 1) {
                if (here == 0) return s.toTop(items);
                target = here - 1;
            }
        }
        s.jumpTo(items, target);
    }

    /// The cursor onto section `n`'s first row, its header at the top.
    pub fn jumpTo(s: *State, items: []const Item, n: usize) void {
        const head = sectionHeader(items, n) orelse return;
        s.cursor = head + 1;
        s.settle(items);
        s.scroll = @min(head, items.len -| @max(s.rows, 1));
    }

    /// `settle`, but looking up first: the last focusable at or before
    /// the cursor, else the first after it.
    fn settleBack(s: *State, items: []const Item) void {
        if (items.len == 0) return;
        if (s.cursor >= items.len) s.cursor = items.len - 1;
        var i = s.cursor + 1;
        while (i > 0) {
            i -= 1;
            if (items[i].focusable()) {
                s.cursor = i;
                return;
            }
        }
        s.settle(items);
    }
};

// ── sections ─────────────────────────────────────────────────────────────
// The strip's arithmetic, kept as free functions over the item list so a
// test can ask where a section starts without painting a frame.

/// How many `.section` headers the list carries.
pub fn sectionCount(items: []const Item) usize {
    var n: usize = 0;
    for (items) |it| if (it == .section) {
        n += 1;
    };
    return n;
}

/// The item index of section `n`'s header.
pub fn sectionHeader(items: []const Item, n: usize) ?usize {
    var seen: usize = 0;
    for (items, 0..) |it, i| if (it == .section) {
        if (seen == n) return i;
        seen += 1;
    };
    return null;
}

/// Section `n`'s name.
pub fn sectionName(items: []const Item, n: usize) ?[]const u8 {
    const h = sectionHeader(items, n) orelse return null;
    return items[h].section;
}

/// Which section item `idx` belongs to — the last header at or before
/// it. Null only for items above the first header.
pub fn sectionOf(items: []const Item, idx: usize) ?usize {
    var seen: ?usize = null;
    var n: usize = 0;
    for (items, 0..) |it, i| {
        if (i > idx) break;
        if (it == .section) {
            seen = n;
            n += 1;
        }
    }
    return seen;
}

/// Section `n`'s index in a *different* item list, found by name — the
/// strip is painted from the unfiltered list, so a click on a name has
/// to land in the filtered one. Null when that section has no match.
pub fn sectionIndexOfName(items: []const Item, name: []const u8) ?usize {
    var n: usize = 0;
    for (items) |it| if (it == .section) {
        if (std.mem.eql(u8, it.section, name)) return n;
        n += 1;
    };
    return null;
}

// ── the filter ───────────────────────────────────────────────────────────
// The match rule and the visible-list derivation, as free functions over
// the item list, so a test can ask what a query matches without painting
// a frame.

/// Rows the list can put a cursor on — what the filtered footer counts.
pub fn focusableCount(items: []const Item) usize {
    var n: usize = 0;
    for (items) |it| if (it.focusable()) {
        n += 1;
    };
    return n;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// The word a row's current value reads as — the bracketed option, or
/// the number itself on a step row.
pub fn valueWord(r: Row, buf: []u8) []const u8 {
    if (r.number != null) return std.fmt.bufPrint(buf, "{d}", .{r.current}) catch "";
    if (r.options.len == 0) return "";
    return r.options[@min(r.current, r.options.len - 1)];
}

/// Case-insensitive substring over the row's label, the word its
/// current value reads as, and the name of the section it sits in — so
/// `dock` finds every dock row and `always` every row set to `always`.
pub fn rowMatches(r: Row, section: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (has(r.label, needle)) return true;
    var buf: [24]u8 = undefined;
    if (has(valueWord(r, &buf), needle)) return true;
    return has(section, needle);
}

/// One item against a query; a header never matches on its own (it is
/// kept only for the rows beneath it).
fn itemMatches(it: Item, section: []const u8, needle: []const u8) bool {
    return switch (it) {
        .section => false,
        .row => |r| rowMatches(r, section, needle),
        .action => |a| needle.len == 0 or has(a.label, needle) or has(section, needle),
    };
}

/// The list `draw` paints for a query: every matching row, and a
/// section header only where something under it matched. An empty
/// query is the whole list (a copy, so the caller frees one thing).
pub fn filtered(gpa: Allocator, items: []const Item, needle: []const u8) Allocator.Error![]Item {
    var out: std.ArrayListUnmanaged(Item) = .empty;
    errdefer out.deinit(gpa);
    if (needle.len == 0) {
        try out.appendSlice(gpa, items);
        return out.toOwnedSlice(gpa);
    }
    var section: []const u8 = "";
    for (items, 0..) |it, i| switch (it) {
        .section => |name| {
            section = name;
            var j = i + 1;
            while (j < items.len and items[j] != .section) : (j += 1) {
                if (itemMatches(items[j], name, needle)) {
                    try out.append(gpa, it);
                    break;
                }
            }
        },
        else => if (itemMatches(it, section, needle)) try out.append(gpa, it),
    };
    return out.toOwnedSlice(gpa);
}

pub const Outcome = union(enum) {
    consumed,
    cancel,
    save,
    /// // changed (settings-search): the query changed — the caller
    /// rebuilds the visible list and puts the cursor back on a match.
    refilter,
    /// The focused row moves `delta` choices (wrapping).
    adjust: struct { item: usize, delta: i8 },
    reset_row: usize,
    reset_all,
    /// Enter / space on an action row.
    activate: usize,
};

pub const KeyOpts = struct {
    gpa: Allocator,
    /// The standard profile binds Ctrl+F to the filter too (VS Code's
    /// habit); vim gets `/` alone.
    ctrl_f: bool = false,
    /// // changed (settings-typeahead): the standard profile's box is
    /// type-to-filter, the way VS Code's settings screen is — a
    /// printable key that is not one of the documented controls opens
    /// the pill and goes into the query. The vim profile keeps its
    /// `h j k l r R q g G [ ]` set, which is what a vim user expects
    /// and what the family convention documents.
    typeahead: bool = false,
};

/// // changed (settings-reset-confirm): the reset-everything box. Static
/// strings — the state that holds them lives in `State.confirm`, which
/// therefore needs no deinit.
pub const reset_confirm_title = "Reset settings";
pub const reset_confirm_message = "Reset every setting to its default?";
const reset_confirm_choices = [_]confirm_ui.Choice{
    .{ .key = 'r', .label = "Reset" },
    .{ .key = 'c', .label = "Cancel" },
};

/// The filter pill's keys, while it has them. Esc clears and hands the
/// list back, Enter hands the list back keeping the query, `↑↓` walk
/// the matches without leaving the field, and everything else is the
/// text field's — so `←→`, Home/End and the word deletes edit the query
/// rather than the focused row. A key the field does not want (Tab,
/// PgUp…) falls through to the list's own set.
fn filterKey(s: *State, key: Key, items: []const Item, opts: KeyOpts) Allocator.Error!?Outcome {
    switch (key.code) {
        .esc => {
            s.filter.clear();
            return .refilter;
        },
        .enter => {
            s.filter.focused = false;
            return .consumed;
        },
        .up => {
            s.move(items, -1);
            return .consumed;
        },
        .down => {
            s.move(items, 1);
            return .consumed;
        },
        else => {},
    }
    return switch (try text_field.handleKey(&s.filter.buf, &s.filter.caret, opts.gpa, key)) {
        .changed => .refilter,
        .moved => .consumed,
        .ignored => null,
    };
}

/// ←→ adjust · ↑↓ move · Tab / Shift-Tab next and previous section ·
/// `/` filter · Ctrl+R reset the focused row · Enter save · Esc cancel
/// (a live filter first) · Home/End/PgUp/PgDn move further.
///
/// The vim profile adds its own letters on top: `h l` adjust, `j k`
/// move, `[` `]` section, `g G` the ends, `r` reset the row, `R` reset
/// all, `q` save. // changed (settings-typeahead): the standard
/// profile has none of them — there every other printable key opens
/// the filter pill and goes into the query, because that is what a VS
/// Code user's hands do on a settings screen, and because a `q` that
/// silently saved and closed dropped the rest of the word into the
/// buffer underneath.
pub fn handleKey(s: *State, key: Key, items: []const Item, opts: KeyOpts) Allocator.Error!Outcome {
    s.settle(items);
    // // changed (settings-reset-confirm): the box on top owns the keys.
    if (s.confirm) |*c| switch (confirm_ui.handleKey(c, key)) {
        .consumed => return .consumed,
        .cancel => {
            s.confirm = null;
            return .consumed;
        },
        .choose => |i| {
            s.confirm = null;
            return if (i == 0) .reset_all else .consumed;
        },
    };
    if (s.filter.focused) if (try filterKey(s, key, items, opts)) |o| return o;
    const page: isize = @intCast(@max(1, s.rows));
    switch (key.code) {
        // A query narrowing the list is what Esc takes back first; the
        // second press is the overlay's own way out.
        .esc => {
            if (s.filter.active()) {
                s.filter.clear();
                return .refilter;
            }
            return .cancel;
        },
        .enter => return if (s.cursor < items.len and items[s.cursor] == .action) .{ .activate = s.cursor } else .save,
        .up => s.move(items, -1),
        .down => s.move(items, 1),
        .left => return adjustFocused(s, items, -1),
        .right => return adjustFocused(s, items, 1),
        // Nothing in the overlay takes Tab, so it is the section strip's
        // — the shape a settings screen with tabbed sections would have.
        .tab => s.jumpSection(items, 1),
        .backtab => s.jumpSection(items, -1),
        .home => s.toTop(items),
        .end => s.toBottom(items),
        .page_up => s.moveBy(items, -page),
        .page_down => s.moveBy(items, page),
        .char => |c| {
            if (key.mods.ctrl or key.mods.alt or key.mods.super) {
                if (key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                    if (opts.ctrl_f and (c == 'f' or c == 'F')) s.openFilter();
                    // The reset that is reachable without a letter, so
                    // the type-to-filter box still has one.
                    if (c == 'r' or c == 'R') return resetFocused(s, items);
                }
                return .consumed;
            }
            // `/` is the family's filter chord in both profiles, and it
            // is the one printable the standard box does not type: a
            // query cannot begin with a slash, which no setting's label
            // does either.
            if (c == '/') {
                s.openFilter();
                return .consumed;
            }
            // Space stays the row's toggle in both profiles — a leading
            // space matches nothing, so it is no loss as a query.
            if (c == ' ') return if (s.cursor < items.len and items[s.cursor] == .action) .{ .activate = s.cursor } else adjustFocused(s, items, 1);
            if (opts.typeahead) return try typeInto(s, c, opts);
            switch (c) {
                'k' => s.move(items, -1),
                'j' => s.move(items, 1),
                'h' => return adjustFocused(s, items, -1),
                'l' => return adjustFocused(s, items, 1),
                ']' => s.jumpSection(items, 1),
                '[' => s.jumpSection(items, -1),
                'g' => s.toTop(items),
                'G' => s.toBottom(items),
                'r' => return resetFocused(s, items),
                'R' => {
                    s.askResetAll();
                    return .consumed;
                },
                'q' => return .save,
                else => {},
            }
        },
        else => {},
    }
    return .consumed;
}

/// // changed (settings-typeahead): a printable key in the standard
/// profile opens the pill and extends the query, so the box behaves the
/// way a search field does from the first keystroke.
fn typeInto(s: *State, c: u21, opts: KeyOpts) Allocator.Error!Outcome {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return .consumed;
    s.openFilter();
    try s.filter.insert(opts.gpa, buf[0..n]);
    return .refilter;
}

fn resetFocused(s: *State, items: []const Item) Outcome {
    return if (s.cursor < items.len and items[s.cursor] == .row) .{ .reset_row = s.cursor } else .consumed;
}

fn adjustFocused(s: *State, items: []const Item, delta: i8) Outcome {
    if (s.cursor >= items.len) return .consumed;
    return switch (items[s.cursor]) {
        .row => .{ .adjust = .{ .item = s.cursor, .delta = delta } },
        .action => .{ .activate = s.cursor },
        .section => .consumed,
    };
}

pub const title = "Settings";
pub const hint_text = "←→ adjust · ↑↓ move · r/R reset · Enter save · Esc cancel";
/// The footer in five widths. `hint_text` is the family's line and the
/// box's width budget — it never changes, so the box does not resize
/// when a wider form is picked; `hint_text_search` and
/// `hint_text_sections` add `/ search` and the section keys when the
/// footer is wide enough to carry them, and `hint_text_tight` drops
/// `↑↓ move` when the position (`12–40 of 97`) has taken the room — the
/// footer never loses its tail, because `Esc cancel` is the way out.
pub const hint_text_sections = "←→ adjust · ↑↓ move · [ ] section · / search · r/R reset · Enter save · Esc cancel";
pub const hint_text_search = "←→ adjust · ↑↓ move · / search · r/R reset · Enter save · Esc cancel";
/// `↑↓ move` goes before `/ search` does: arrows in a list are the one
/// key nobody has to be told, and `/` is the one nobody guesses.
pub const hint_text_search_tight = "←→ adjust · / search · r/R reset · Enter save · Esc cancel";
pub const hint_text_tight = "←→ adjust · r/R reset · Enter save · Esc cancel";

/// // changed (settings-typeahead): the standard profile's five, in the
/// same descending order. They advertise what actually works there —
/// no letter commands, the sections on Tab rather than `[ ]`, typing
/// as the search, and `ctrl+r` as the reset that needs no letter.
pub const std_hint_sections = "←→ adjust · ↑↓ move · Tab section · type to search · ctrl+r reset · Enter save · Esc cancel";
pub const std_hint_search = "←→ adjust · ↑↓ move · type to search · ctrl+r reset · Enter save · Esc cancel";
pub const std_hint_search_tight = "←→ adjust · type to search · ctrl+r reset · Enter save · Esc cancel";
pub const std_hint = "←→ adjust · ↑↓ move · ctrl+r reset · Enter save · Esc cancel";
pub const std_hint_tight = "←→ adjust · ctrl+r reset · Enter save · Esc cancel";

/// // changed (settings-filter-hint): the box has TWO key states and
/// used to paint one footer for both. While the filter field has the
/// keys, `←→` move the text caret and Enter only hands the list back —
/// so a reader who took the list's `←→ adjust · … · Enter save` at its
/// word changed nothing, silently. These four are what the FIELD does,
/// and they are the same in both profiles because the field is.
pub const filter_hint = "type to filter · ←→ caret · ↑↓ move · Enter to the list · Esc clears";
pub const filter_hint_move = "←→ caret · ↑↓ move · Enter to the list · Esc clears";
pub const filter_hint_tight = "←→ caret · Enter to the list · Esc clears";
pub const filter_hint_tightest = "Enter to the list · Esc clears";
pub const max_width: u16 = 84;
pub const min_width: u16 = 40;
/// A row with more choices than this paints `[current] ‹ i/n ›` instead
/// of the whole list (the theme row has 94).
pub const max_listed_options: usize = 6;

/// // changed (settings-search): what `draw` needs besides the list it
/// paints. `all` is the *unfiltered* list — the strip is painted from
/// it (so a section with no match is dimmed rather than gone, and its
/// click still jumps), the footer counts against it, and so does the
/// box's own geometry, so the box does not breathe as a query narrows
/// the rows under it. Empty means "the same list".
pub const DrawOpts = struct {
    all: []const Item = &.{},
    /// // changed (settings-typeahead): the standard profile's footer,
    /// which advertises a different set because a different set works.
    typeahead: bool = false,
};

/// Paint the box. `subtitle` (the focused row's target file, say) joins
/// the title: `Settings · → .mnml/config.zon`. Rows scroll to keep the
/// cursor visible; the list is as tall as the screen allows. Returns
/// the filter field's caret cell while it has the keys.
pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item, subtitle: ?[]const u8, opts: DrawOpts) ?Caret {
    const t = ui.theme;
    s.settle(items);
    const all = if (opts.all.len == 0) items else opts.all;
    // Label column: the widest label, so every colon lines up.
    var label_w: u16 = 0;
    var widest: u16 = 0;
    for (all) |it| switch (it) {
        .row => |r| {
            label_w = @max(label_w, ui.width(r.label));
            // A choice list wider than the box windows around the active
            // value (`choiceWindow`), so a row asks only for what that
            // form needs: the bracketed active value and its two arrows.
            // The box stays the family's 60 %; it does not grow to fit
            // the longest list.
            var ow: u16 = 0;
            if (r.number != null) {
                ow = 12;
            } else if (r.options.len > max_listed_options) {
                ow = ui.width(r.options[r.current]) + 12;
            } else {
                ow = ui.width(r.options[r.current]) + 8;
            }
            widest = @max(widest, ui.width(r.label) + ow);
        },
        .action => |a| widest = @max(widest, ui.width(a.label)),
        .section => |name| widest = @max(widest, ui.width(name) + 6),
    };
    const hint = overlay.hintText(ui, hint_text);
    // ~60 % of the screen wide and ~70 % tall (the family idiom): wider
    // when the rows need it, up to `max_width`; shorter when the rows
    // fit — a long list scrolls inside the box instead of filling the
    // screen.
    const want_w: u16 = @min(max_width, @max(@max(min_width, ui.width(hint) + 4), @max(widest + 12, area.w * 6 / 10)));
    const w = @min(want_w, area.w -| 2);
    const cap_h: u16 = @max(area.h * 7 / 10, @min(area.h, 8));
    // Border 2 + the section strip + the footer: what a list has to
    // clear before the box stops growing.
    //
    // // changed (settings-search): the height is asked of `all`, the
    // unfiltered list, for the same reason the width is — a box that
    // shrank to fit each query's result would jump under the hand with
    // every character typed, and the rows left on screen would slide
    // out from under the pointer between one keystroke and the next.
    // The box is the size the whole list asks for; a query empties rows
    // inside it rather than resizing it.
    const pill_rows: usize = if (s.filter.open) 1 else 0;
    const want_h: u16 = @intCast(@min(@as(usize, cap_h), all.len + 5 + pill_rows));
    // // changed (settings-title-path): the subtitle is the focused
    // row's destination file and the name is what it is for, so it is
    // cut from the LEFT when the box is too narrow — the border clips
    // from the right, which threw the name away.
    const full_title = if (subtitle) |sub| blk: {
        // The `→` stays put: it is what says the rest is a destination.
        const arrow: []const u8 = if (std.mem.startsWith(u8, sub, "→ ")) "→ " else "";
        const room = (w -| 4) -| ui.width(title) -| ui.width(" · ") -| ui.width(arrow);
        break :blk ui.fmt("{s} · {s}{s}", .{ title, arrow, elideLeft(ui, sub[arrow.len..], room) });
    } else title;
    const box_rect = overlay.place(area, w, want_h, .center);
    const inner = overlay.frame(ui, box_rect, full_title);
    if (inner.isEmpty() or inner.h < 2) return null;
    // First, so every row and chip registered after it wins the scan.
    ui.hit(box_rect, .{ .overlay_item = surface_id });

    const bg = t.overlay_bg.bg;
    // The filter pill under the title, then the section strip, then the
    // footer, then whatever is left is the list. A box with no room for
    // three rows keeps the rows and drops the strip — the list is the
    // point; the pill outranks the strip while it is open, because the
    // query it holds is what the rows on screen are.
    var body = inner;
    var caret: ?Caret = null;
    if (s.filter.open and inner.h >= 3) {
        const sp = body.splitTop(1);
        caret = drawFilter(ui, sp.top, s, bg);
        body = sp.rest;
    }
    const form = stripForm(ui, all, inner.w);
    if (form != .none and body.h >= 3) {
        const sp = body.splitTop(1);
        drawStrip(ui, sp.top, s, items, all, form, bg);
        body = sp.rest;
    }
    const split_foot = body.splitBottom(1);
    const foot = split_foot.rest;
    var rows_rect = split_foot.top;

    const list_h: usize = rows_rect.h;
    s.rows = list_h;
    const overflows = items.len > list_h;
    if (s.scroll > items.len -| list_h) s.scroll = items.len -| list_h;
    if (s.cursor < s.scroll) s.scroll = s.cursor;
    if (s.cursor >= s.scroll + list_h) s.scroll = s.cursor + 1 - list_h;
    // The bar takes its column off the rows before they are laid out, so
    // a chip never paints under it.
    if (overflows and rows_rect.w > 4) {
        const sp = rows_rect.splitRight(1);
        rows_rect = sp.left;
        scrollbar.drawVertical(ui, sp.rest, .{ .pane = scrollbar_owner }, items.len, list_h, s.scroll);
    }

    // A query nothing answers to: say so where the rows would be,
    // rather than leaving a box of empty ground and no explanation.
    if (items.len == 0 and rows_rect.h > 0) {
        const msg = ui.fmt("no setting matches \"{s}\"", .{s.filter.text()});
        _ = ui.putStr(rows_rect.x + 2, rows_rect.y, rows_rect.w -| 2, ui.clipStr(msg, rows_rect.w -| 2), Theme.onBg(t.muted, bg));
    }

    var y: u16 = rows_rect.y;
    var idx = s.scroll;
    while (idx < items.len and y < rows_rect.y + @as(u16, @intCast(list_h))) : ({
        idx += 1;
        y += 1;
    }) {
        const r = Rect.init(rows_rect.x, y, rows_rect.w, 1);
        const focused = idx == s.cursor;
        const row_style: Style = if (focused) Theme.onBg(t.overlay_bg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(r, row_style);
        switch (items[idx]) {
            .section => |name| {
                const rule = if (ui.ascii) "--" else "──";
                const text = ui.fmt("{s} {s} {s}", .{ rule, name, rule });
                _ = ui.putStr(r.x + 1, y, r.w -| 1, ui.clipStr(text, r.w -| 1), Theme.onBg(t.muted, bg));
            },
            .row => |row| {
                // The row first, its chips after: the hit map scans back
                // to front, so a chip registered later wins the click
                // over the row it sits on (D6 — last painted wins).
                ui.hit(r, .{ .overlay_item = row.id });
                var x = r.x + 1;
                x += ui.putStr(x, y, 2, if (focused) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(t.accent, row_style.bg));
                const label = ui.fmt("{s}:", .{row.label});
                x += ui.putStr(x, y, r.right() -| x, label, Theme.onBg(if (focused) t.fg else t.fg, row_style.bg));
                x += label_w + 3 - @min(label_w + 3, ui.width(label));
                if (row.number) |num| {
                    // `‹ [32] ›` — the arrows step; the value is the row.
                    const prev_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "<" else "‹", Theme.onBg(if (row.current > num.min) t.accent else t.muted, row_style.bg));
                    ui.hit(Rect.init(prev_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, 0) });
                    x += 1;
                    const cur = ui.fmt("[{d}]", .{row.current});
                    const cw = ui.width(cur);
                    _ = ui.putStr(x, y, r.right() -| x, cur, t.chip_active);
                    ui.hit(Rect.init(x, y, cw, 1), .{ .overlay_item = row.id });
                    x += cw + 1;
                    const next_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) ">" else "›", Theme.onBg(if (row.current < num.max) t.accent else t.muted, row_style.bg));
                    ui.hit(Rect.init(next_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, 1) });
                } else if (row.options.len > max_listed_options) {
                    // `[current] ‹ i/n ›` — the arrows are the neighbours' hits.
                    const n = row.options.len;
                    const cur = ui.fmt("[{s}]", .{row.options[row.current]});
                    const cw = ui.width(cur);
                    _ = ui.putStr(x, y, r.right() -| x, cur, t.chip_active);
                    ui.hit(Rect.init(x, y, cw, 1), .{ .overlay_item = row.id });
                    x += cw + 1;
                    const prev_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "<" else "‹", Theme.onBg(t.accent, row_style.bg));
                    ui.hit(Rect.init(prev_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, (row.current + n - 1) % n) });
                    x += ui.putStr(x, y, r.right() -| x, ui.fmt(" {d}/{d} ", .{ row.current + 1, n }), Theme.onBg(t.muted, row_style.bg));
                    const next_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) ">" else "›", Theme.onBg(t.accent, row_style.bg));
                    ui.hit(Rect.init(next_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, (row.current + 1) % n) });
                } else {
                    // Every choice when the row has room; otherwise a
                    // window around the active one, the hidden side
                    // marked `‹` / `›` (each a hit on the nearest hidden
                    // choice), so the bracketed value is always on screen
                    // and `→` never steps onto one that is not.
                    const star: u16 = if (row.modified) 2 else 0;
                    const win = choiceWindow(ui, row.options, row.current, (r.right() -| x) -| star);
                    const mark_style = Theme.onBg(t.accent, row_style.bg);
                    if (win.lo > 0) {
                        ui.hit(Rect.init(x, y, 1, 1), .{ .overlay_item = optionHit(row.id, win.lo - 1) });
                        x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "< " else "‹ ", mark_style);
                    }
                    var i = win.lo;
                    while (i < win.hi) : (i += 1) {
                        if (i > win.lo) x += ui.putStr(x, y, r.right() -| x, " / ", Theme.onBg(t.muted, row_style.bg));
                        const active = i == row.current;
                        const text = if (active) ui.fmt("[{s}]", .{row.options[i]}) else row.options[i];
                        const ow = ui.width(text);
                        const style: Style = if (active) t.chip_active else Theme.onBg(t.muted, row_style.bg);
                        _ = ui.putStr(x, y, r.right() -| x, text, style);
                        ui.hit(Rect.init(x, y, @min(ow, r.right() -| x), 1), .{ .overlay_item = optionHit(row.id, i) });
                        x += ow;
                    }
                    if (win.hi < row.options.len) {
                        x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) " >" else " ›", mark_style);
                        ui.hit(Rect.init(x -| 1, y, 1, 1), .{ .overlay_item = optionHit(row.id, win.hi) });
                    }
                }
                if (row.modified and x + 2 < r.right()) _ = ui.putStr(x + 2, y, 1, "*", Theme.withFg(row_style, t.warn_fg.fg));
            },
            .action => |a| {
                var x = r.x + 1;
                x += ui.putStr(x, y, 2, if (focused) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(t.accent, row_style.bg));
                _ = ui.putStr(x, y, r.right() -| x, ui.clipStr(a.label, r.right() -| x), Theme.withFg(row_style, t.error_fg.fg));
                ui.hit(r, .{ .overlay_item = a.id });
            },
        }
    }
    // Footer: the position left, the key hint right. The position is
    // what makes the overflow visible where the box is too narrow for a
    // bar, so it is painted first and the hint takes what is left.
    ui.fill(foot, t.overlay_bg);
    var hint_style = Theme.onBg(t.muted, bg);
    hint_style.dim = false;
    const room = foot.w -| 2;
    // While a query is on, the position says how much of the list it
    // left — `3 of 91` — whether or not what is left overflows the box.
    // An open-but-empty pill has filtered nothing, so the scroll
    // position stays until the first character is typed.
    const pos = if (s.filter.text().len != 0)
        ui.fmt("{d} of {d}", .{ focusableCount(items), focusableCount(all) })
    else if (overflows)
        positionText(ui, s.scroll, list_h, items.len, room)
    else
        null;
    var hint_room = room;
    if (pos) |p| {
        _ = ui.putStr(foot.x + 1, foot.y, room, p, Theme.onBg(t.accent, bg));
        hint_room = room -| (ui.width(p) + 2);
    }
    if (hint_room >= 10) _ = ui.putStrRight(foot.right() -| 1, foot.y, hint_room, ui.clipStr(hintFor(ui, hint_room, opts.typeahead, s.filter.focused), hint_room), hint_style);
    // // changed (settings-reset-confirm): the ask goes on top of the
    // box, last, so its choices are the hits a click lands on and the
    // caret is not left blinking in a pill that no longer has the keys.
    if (s.confirm) |*c| {
        confirm_ui.draw(ui, area, c);
        return null;
    }
    return caret;
}

/// // changed (settings-title-path): `s` cut to `max` cells from the
/// LEFT — `…/mnml/config.zon`. The box's title carries the focused
/// row's destination file, and the FILE NAME is the fact it exists to
/// carry ("did I just change this project, or every project?"). The
/// border clips from the right, so a long absolute path lost exactly
/// that half; this keeps the tail and drops the head.
pub fn elideLeft(ui: Ui, s: []const u8, max: u16) []const u8 {
    if (max == 0) return "";
    if (ui.fitsIn(s, max)) return s;
    const mark = ui.ellipsisText();
    const budget = max -| @as(u16, if (ui.ascii) 3 else 1);
    if (budget == 0) return mark;
    var i: usize = s.len;
    while (i > 0) {
        var j = i - 1;
        while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
        if (!ui.fitsIn(s[j..], budget)) break;
        i = j;
    }
    return ui.fmt("{s}{s}", .{ mark, s[i..] });
}

/// The family filter pill, in the box instead of on a panel: a cell of
/// ground each side, the search glyph in the accent, then the query or
/// its placeholder. Its whole width is one `.overlay_item(filter_id)`
/// hit, so a click puts the keys back in it.
fn drawFilter(ui: Ui, r: Rect, s: *State, bg: vaxis.Color) ?Caret {
    _ = bg;
    const t = ui.theme;
    ui.fill(r, t.overlay_bg);
    if (r.w < 6) return null;
    const pill = Rect.init(r.x + 1, r.y, r.w - 2, 1);
    const style = if (s.filter.focused) Theme.withFg(t.chip, t.fg.fg) else t.chip;
    ui.fill(pill, style);
    var x = pill.x;
    x += ui.putStr(x, pill.y, pill.w, " ", style);
    x += ui.putStr(x, pill.y, pill.right() - x, filter_input.glyph(ui), Theme.withFg(style, t.accent.fg));
    x += ui.putStr(x, pill.y, pill.right() - x, " ", style);
    ui.hit(pill, .{ .overlay_item = filter_id });
    const field = Rect.init(x, pill.y, (pill.right() - 1) -| x, 1);
    return text_field.draw(ui, field, s.filter.text(), s.filter.caret, .{
        .style = style,
        .placeholder = filter_input.placeholder(ui, s.filter.focused, filter_input.default_noun),
        .focused = s.filter.focused,
    });
}

/// The widest of the five hints that fits `room`, in descending width.
/// Below the tightest the caller clips — and the tight form ends in
/// `Esc cancel`, so what survives a clip is still the way out. The
/// `--ascii` spelling is the hint language's (`overlay.hintText`), so
/// the family keeps one string per form, not two.
pub fn hintFor(ui: Ui, room: u16, typeahead: bool, filtering: bool) []const u8 {
    const forms: []const []const u8 = if (filtering)
        &.{ filter_hint, filter_hint_move, filter_hint_tight, filter_hint_tightest }
    else if (typeahead)
        &.{ std_hint_sections, std_hint_search, std_hint_search_tight, std_hint, std_hint_tight }
    else
        &.{ hint_text_sections, hint_text_search, hint_text_search_tight, hint_text, hint_text_tight };
    for (forms) |f| {
        const shown = overlay.hintText(ui, f);
        if (ui.width(shown) <= room) return shown;
    }
    return overlay.hintText(ui, forms[forms.len - 1]);
}

/// `12–40 of 97` while it and the hint both fit, `40/97` when they do
/// not. The choice is made against the *widest* the long form can ever
/// get (every number as wide as the total), so the footer does not flip
/// between the two forms as the list scrolls past a digit.
pub fn positionText(ui: Ui, scroll: usize, list_h: usize, total: usize, room: u16) []const u8 {
    const first = scroll + 1;
    const last = @min(scroll + list_h, total);
    const dash = if (ui.ascii) "-" else "–";
    const widest = ui.width(ui.fmt("{d}{s}{d} of {d}", .{ total, dash, total, total }));
    const hint_w = ui.width(overlay.hintText(ui, hint_text));
    if (widest + 2 + hint_w <= room) return ui.fmt("{d}{s}{d} of {d}", .{ first, dash, last, total });
    return ui.fmt("{d}/{d}", .{ last, total });
}

/// The section strip's three forms: every name, the initials, or
/// nothing at all when even the initials will not fit.
pub const StripForm = enum { none, initials, names };

/// Cells a joined strip needs: `UI · Editor · …`, a cell of padding
/// each side.
fn stripWidth(ui: Ui, items: []const Item, form: StripForm) u16 {
    const n = sectionCount(items);
    if (n == 0) return 0;
    var total: u16 = 2 + @as(u16, @intCast(n - 1)) * 3;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = sectionName(items, i) orelse continue;
        total += if (form == .initials) 1 else ui.width(name);
    }
    return total;
}

pub fn stripForm(ui: Ui, items: []const Item, avail: u16) StripForm {
    if (sectionCount(items) < 2) return .none;
    if (stripWidth(ui, items, .names) <= avail) return .names;
    if (stripWidth(ui, items, .initials) <= avail) return .initials;
    return .none;
}

/// `UI · Editor · AI · Integrations · Reset`, the cursor's section in
/// the active-chip colour, each name its own click target.
///
/// // changed (settings-search): the strip is painted from `all`, the
/// unfiltered list, so every section is still there to click while a
/// query is on; one with nothing left in `items` is dimmed. The hit
/// carries the index in `all` — the app looks the name up in whatever
/// list is on screen.
fn drawStrip(ui: Ui, r: Rect, s: *const State, items: []const Item, all: []const Item, form: StripForm, bg: vaxis.Color) void {
    const t = ui.theme;
    ui.fill(r, t.overlay_bg);
    const here = sectionOf(items, s.cursor);
    const here_name = if (here) |h| sectionName(items, h) else null;
    const sep = overlay.hintText(ui, " · ");
    const n = sectionCount(all);
    var x = r.x + 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) x += ui.putStr(x, r.y, r.right() -| x, sep, Theme.onBg(t.muted, bg));
        const name = sectionName(all, i) orelse continue;
        const text = if (form == .initials) name[0..@min(name.len, 1)] else name;
        const matched = sectionIndexOfName(items, name) != null;
        const active = matched and here_name != null and std.mem.eql(u8, here_name.?, name);
        var style: Style = if (active) t.chip_active else Theme.onBg(t.muted, bg);
        if (!matched) style.dim = true;
        const used = ui.putStr(x, r.y, r.right() -| x, text, style);
        ui.hit(Rect.init(x, r.y, used, 1), .{ .overlay_item = sectionHit(i) });
        x += used;
    }
}

/// `[lo, hi)` of `options` a row of `avail` cells shows: the active
/// choice always, then its neighbours added right, left, right… while
/// `a / [b] / c` plus a `‹ ` / ` ›` for each hidden side still fits. The
/// whole list when it fits; the active choice alone when nothing else
/// does.
pub const Window = struct { lo: usize, hi: usize };

pub fn choiceWindow(ui: Ui, options: []const []const u8, current: usize, avail: u16) Window {
    const n = options.len;
    if (n == 0) return .{ .lo = 0, .hi = 0 };
    const cur = @min(current, n - 1);
    var lo = cur;
    var hi = cur + 1;
    var width: u16 = ui.width(options[cur]) + 2;
    while (true) {
        var grew = false;
        if (hi < n) {
            const w = width + 3 + ui.width(options[hi]);
            if (w + marks(lo, hi + 1, n) <= avail) {
                width = w;
                hi += 1;
                grew = true;
            }
        }
        if (lo > 0) {
            const w = width + 3 + ui.width(options[lo - 1]);
            if (w + marks(lo - 1, hi, n) <= avail) {
                width = w;
                lo -= 1;
                grew = true;
            }
        }
        if (!grew) return .{ .lo = lo, .hi = hi };
    }
}

/// Cells the `‹ ` / ` ›` marks take for a window `[lo, hi)` of `n`.
fn marks(lo: usize, hi: usize, n: usize) u16 {
    return @as(u16, if (lo > 0) 2 else 0) + @as(u16, if (hi < n) 2 else 0);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const bool_opts = [_][]const u8{ "off", "on" };
const style_opts = [_][]const u8{ "vim", "standard" };
const many_opts = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };

/// `handleKey` in a test: the filter's buffer lives on the testing
/// allocator, and `/` is the only key that opens it (vim's profile).
fn tkey(s: *State, key: Key, items: []const Item) Allocator.Error!Outcome {
    return handleKey(s, key, items, .{ .gpa = testing.allocator });
}

fn sample() [6]Item {
    return .{
        .{ .section = "UI" },
        .{ .row = .{ .label = "Line numbers", .options = &bool_opts, .current = 1, .id = 0 } },
        .{ .section = "Editor" },
        .{ .row = .{ .label = "Input style", .options = &style_opts, .current = 1, .modified = true, .id = 1 } },
        .{ .row = .{ .label = "Theme", .options = &many_opts, .current = 2, .id = 2 } },
        .{ .action = .{ .label = "Reset all to defaults", .id = 3 } },
    };
}

test "rows paint as `▸ Label:  [active] / other  *`, colons aligned, hits per row and option; long lists paint one" {
    // 16 rows: the box caps at ~70 % of the screen, and six items plus
    // the chrome need eleven.
    var f = try Fixture.init(90, 16);
    defer f.deinit();
    var s: State = .{};
    const items = sample();
    _ = draw(f.ui(), f.full(), &s, &items, "→ .mnml/config.zon", .{});
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, " Settings · → .mnml/config.zon ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "── UI ──") != null);
    try testing.expect(std.mem.indexOf(u8, text, "▸ Line numbers:  off / [on]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  Input style:   vim / [standard]  *") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  Theme:         [c] ‹ 3/8 ›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Reset all to defaults") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Esc cancel") != null);
    // the first focusable is the cursor; a row hit and an option hit exist
    try testing.expectEqual(@as(usize, 1), s.cursor);
    var saw_row = false;
    var saw_opt = false;
    var saw_next = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .surface, .filter => {},
        .row => |id| saw_row = saw_row or id == 0,
        .section => {},
        .option => |o| {
            saw_opt = saw_opt or (o.id == 1 and o.index == 0);
            saw_next = saw_next or (o.id == 2 and o.index == 3);
        },
    };
    try testing.expect(saw_row and saw_opt and saw_next);
    // Every chip painted is a chip the pointer reaches: the scan from the
    // back must resolve a chip's own cells to the chip, not to the row
    // that carries it — the `off` / `[on]` pair and the long list's `‹`.
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| try testing.expectEqual(Hit{ .option = o }, decodeHit(f.hits.at(h.rect.x, h.rect.y).?.overlay_item)),
        else => {},
    };
    // …and the row's label cell is still the row.
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .row => |id| if (id == 0) try testing.expectEqual(Hit{ .row = 0 }, decodeHit(f.hits.at(h.rect.x + 3, h.rect.y).?.overlay_item)),
        else => {},
    };
}

test "choices that overflow the row paint a window around the active one, marked on the hidden side" {
    var f = try Fixture.init(46, 5);
    defer f.deinit();
    const sorts = [_][]const u8{ "newest", "oldest", "name", "name_desc" };
    var s: State = .{};
    var items = [_]Item{
        .{ .row = .{ .label = "Sort", .options = &sorts, .current = 0, .id = 7 } },
    };
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    var text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  [newest] / oldest / name ›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "name_desc") == null);
    // `›` is the nearest hidden choice's hit.
    var saw_next = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| if (o.index == 3) {
            saw_next = true;
            try testing.expectEqual(@as(u16, 1), h.rect.w);
        },
        else => {},
    };
    try testing.expect(saw_next);
    // The active value stays visible wherever it is; the far side drops.
    items[0].row.current = 3;
    f.hits.reset();
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  ‹ oldest / name / [name_desc]") != null);
    // Room for everything paints everything, no marks.
    var wide = try Fixture.init(60, 5);
    defer wide.deinit();
    _ = draw(wide.ui(), wide.full(), &s, &items, null, .{});
    text = try wide.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  newest / oldest / name / [name_desc]") != null);
    // The pure window arithmetic: a row too narrow for anything but the
    // active choice shows it alone.
    const w = choiceWindow(f.ui(), &sorts, 2, 6);
    try testing.expectEqual(@as(usize, 2), w.lo);
    try testing.expectEqual(@as(usize, 3), w.hi);
}

test "the box is ~60 % of the screen wide and caps at ~70 % tall; a long list scrolls inside it" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    var items: [60]Item = undefined;
    items[0] = .{ .section = "UI" };
    for (1..60) |i| items[i] = .{ .row = .{ .label = "Row", .options = &bool_opts, .current = 0, .id = @intCast(i) } };
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    const text = try f.text();
    // 70 % of 40 rows = 28: the frame's corners sit 28 rows apart, centered.
    var top: ?usize = null;
    var bottom: ?usize = null;
    var dashes: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var y: usize = 0;
    while (it.next()) |line| : (y += 1) {
        if (std.mem.indexOf(u8, line, "╭") != null and top == null) top = y;
        if (std.mem.indexOf(u8, line, "╰") != null) {
            bottom = y;
            dashes = std.mem.count(u8, line, "─");
        }
    }
    try testing.expectEqual(@as(usize, 6), top.?);
    try testing.expectEqual(@as(usize, 33), bottom.?);
    // 60 % of 120 columns = 72 wide: the bottom border is 70 dashes between its corners.
    try testing.expectEqual(@as(usize, 70), dashes);
    // The list scrolls: the last row is not painted, the first is.
    // 28 rows less the two border rows and the footer. This list has
    // one section header, so there is nowhere to jump and no strip.
    try testing.expectEqual(@as(usize, 28 - 3), s.rows);
}

test "a number row paints ‹ [value] › with a hit on each arrow" {
    var f = try Fixture.init(60, 6);
    defer f.deinit();
    var s: State = .{};
    const items = [_]Item{
        .{ .section = "UI" },
        .{ .row = .{ .label = "Right panel width", .options = &.{}, .current = 32, .id = 4, .number = .{ .min = 8, .max = 120, .step = 2 } } },
    };
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Right panel width:  ‹ [32] ›") != null);
    var down = false;
    var up = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| {
            down = down or (o.id == 4 and o.index == 0);
            up = up or (o.id == 4 and o.index == 1);
        },
        else => {},
    };
    try testing.expect(down and up);
    try testing.expectEqual(@as(i8, 1), (try tkey(&s, Key.named(.right), &items)).adjust.delta);
}

test "the wheel slides the window and carries the cursor with it" {
    var f = try Fixture.init(60, 7);
    defer f.deinit();
    var s: State = .{};
    const items = sample();
    // Nothing before a draw: the window height is unknown.
    s.wheel(&items, 2);
    try testing.expectEqual(@as(usize, 0), s.scroll);
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    try testing.expect(s.rows > 0 and s.rows < items.len);
    s.wheel(&items, 2);
    try testing.expectEqual(@as(usize, 2), s.scroll);
    try testing.expect(s.cursor >= s.scroll);
    try testing.expect(items[s.cursor].focusable());
    // The draw keeps the window where the wheel put it.
    _ = draw(f.ui(), f.full(), &s, &items, null, .{});
    try testing.expectEqual(@as(usize, 2), s.scroll);
    // Back up past the top clamps; the cursor comes along (a header at 0
    // is skipped for the first row).
    s.cursor = items.len - 1;
    s.wheel(&items, -10);
    try testing.expectEqual(@as(usize, 0), s.scroll);
    try testing.expect(s.cursor < s.rows);
    try testing.expect(items[s.cursor].focusable());
}

test "// changed (settings-typeahead): in the standard profile every printable key is the query, not a command" {
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const items = sample();
    const std_opts: KeyOpts = .{ .gpa = testing.allocator, .ctrl_f = true, .typeahead = true };
    // `quit` — the query a VS Code user types for the Confirm-on-quit
    // row. Before, `q` saved and closed and `uit` fell into the buffer
    // underneath (hunt/findings-2026-09-21/kbd-settings-typeahead.md).
    for ("quit") |c| try testing.expect(try handleKey(&s, Key.char(c), &items, std_opts) == .refilter);
    try testing.expectEqualStrings("quit", s.filter.text());
    try testing.expect(s.filter.focused);
    s.filter.clear();
    // The letters that were commands are now just letters.
    for ("hjklrRgG[]") |c| {
        const out = try handleKey(&s, Key.char(c), &items, std_opts);
        try testing.expect(out == .refilter);
        try testing.expect(s.confirm == null);
    }
    try testing.expectEqualStrings("hjklrRgG[]", s.filter.text());
    s.filter.clear();
    // The controls that stay: the arrows adjust and move, Tab steps a
    // section, Ctrl+R resets the focused row, Enter saves, Esc cancels.
    s.cursor = 3;
    try testing.expectEqual(@as(i8, 1), (try handleKey(&s, Key.named(.right), &items, std_opts)).adjust.delta);
    try testing.expectEqual(@as(i8, -1), (try handleKey(&s, Key.named(.left), &items, std_opts)).adjust.delta);
    try testing.expectEqual(@as(usize, 3), (try handleKey(&s, Key.ctrl('r'), &items, std_opts)).reset_row);
    try testing.expect(try handleKey(&s, Key.named(.backtab), &items, std_opts) == .consumed);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expect(try handleKey(&s, Key.named(.tab), &items, std_opts) == .consumed);
    try testing.expectEqual(@as(usize, 3), s.cursor);
    try testing.expect(try handleKey(&s, Key.named(.enter), &items, std_opts) == .save);
    try testing.expect(try handleKey(&s, Key.named(.esc), &items, std_opts) == .cancel);
    // `/` is still the family's filter chord rather than a query byte.
    try testing.expect(try handleKey(&s, Key.char('/'), &items, std_opts) == .consumed);
    try testing.expectEqualStrings("", s.filter.text());
    try testing.expect(s.filter.focused);
}

test "keys: move skips headers, adjust/reset/save/cancel come back as outcomes" {
    var s: State = .{};
    const items = sample();
    try testing.expect(try tkey(&s, Key.named(.down), &items) == .consumed);
    try testing.expectEqual(@as(usize, 3), s.cursor);
    try testing.expectEqual(@as(i8, 1), (try tkey(&s, Key.named(.right), &items)).adjust.delta);
    try testing.expectEqual(@as(i8, -1), (try tkey(&s, Key.char('h'), &items)).adjust.delta);
    try testing.expectEqual(@as(usize, 3), (try tkey(&s, Key.char('r'), &items)).reset_row);
    // // changed (settings-reset-confirm): `R` raises the ask; Cancel
    // is focused, so Enter on reflex is the harmless answer and only
    // the Reset choice comes back as `.reset_all`.
    try testing.expect(try tkey(&s, Key.char('R'), &items) == .consumed);
    try testing.expect(s.confirm != null);
    try testing.expectEqual(@as(usize, 1), s.confirm.?.selected);
    try testing.expect(try tkey(&s, Key.named(.enter), &items) == .consumed);
    try testing.expect(s.confirm == null);
    try testing.expect(try tkey(&s, Key.char('R'), &items) == .consumed);
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .consumed);
    try testing.expect(s.confirm == null);
    try testing.expect(try tkey(&s, Key.char('R'), &items) == .consumed);
    try testing.expect(try tkey(&s, Key.char('r'), &items) == .reset_all);
    try testing.expect(s.confirm == null);
    // Ctrl+R is the reset that needs no letter — it is what the
    // standard profile's footer advertises, and it works in both.
    try testing.expectEqual(@as(usize, 3), (try tkey(&s, Key.ctrl('r'), &items)).reset_row);
    try testing.expect(try tkey(&s, Key.named(.enter), &items) == .save);
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .cancel);
    _ = try tkey(&s, Key.char('j'), &items);
    try testing.expectEqual(@as(usize, 4), s.cursor);
    _ = try tkey(&s, Key.char('j'), &items);
    try testing.expectEqual(@as(usize, 5), (try tkey(&s, Key.named(.enter), &items)).activate);
    _ = try tkey(&s, Key.char('k'), &items);
    _ = try tkey(&s, Key.char('k'), &items);
    _ = try tkey(&s, Key.char('k'), &items);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    _ = try tkey(&s, Key.char('k'), &items); // nowhere further up
    try testing.expectEqual(@as(usize, 1), s.cursor);
}

// ── the strip, the bar and the position ──

/// Five sections with enough rows between them to overflow any box the
/// tests open — the shape the real list has.
fn sectioned(buf: *[60]Item) []Item {
    const names = [_][]const u8{ "UI", "Editor", "AI", "Integrations", "Reset" };
    var n: usize = 0;
    for (names) |name| {
        buf[n] = .{ .section = name };
        n += 1;
        for (0..10) |_| {
            buf[n] = .{ .row = .{ .label = "Row", .options = &bool_opts, .current = 0, .id = @intCast(n) } };
            n += 1;
        }
    }
    return buf[0..n];
}

test "the section strip names every section, marks the cursor's, and gives each name its own hit" {
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    try testing.expectEqual(@as(usize, 5), sectionCount(items));
    try testing.expectEqual(@as(usize, 0), sectionHeader(items, 0).?);
    try testing.expectEqual(@as(usize, 11), sectionHeader(items, 1).?);
    try testing.expectEqualStrings("AI", sectionName(items, 2).?);
    try testing.expectEqual(@as(usize, 1), sectionOf(items, 12).?);
    try testing.expectEqual(@as(usize, 4), sectionOf(items, items.len - 1).?);

    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "UI · Editor · AI · Integrations · Reset") != null);
    // Each name is its own click target, and the cursor's section reads
    // as the active chip.
    var seen: [5]bool = @splat(false);
    for (f.hits.items.items) |h| switch (decodeHit(if (h.target == .overlay_item) h.target.overlay_item else continue)) {
        .section => |n| {
            seen[n] = true;
            try testing.expectEqual(Hit{ .section = n }, decodeHit(f.hits.at(h.rect.x, h.rect.y).?.overlay_item));
        },
        else => {},
    };
    for (seen) |ok| try testing.expect(ok);
    const strip_y = for (f.hits.items.items) |h| {
        if (h.target == .overlay_item and decodeHit(h.target.overlay_item) == .section) break h.rect.y;
    } else unreachable;
    const ui_x = for (f.hits.items.items) |h| {
        if (h.target != .overlay_item) continue;
        const d = decodeHit(h.target.overlay_item);
        if (d == .section and d.section == 0) break h.rect.x;
    } else unreachable;
    try testing.expect(vaxis.Color.eql(f.style(ui_x, strip_y).bg, f.theme.chip_active.bg));
}

test "a box too narrow for the names paints the initials, and one narrower still paints no strip" {
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    const ui = f.ui();
    // `UI · Editor · AI · Integrations · Reset` plus a cell of padding
    // each side; the initials need `U · E · A · I · R` and the same.
    try testing.expectEqual(StripForm.names, stripForm(ui, items, 41));
    try testing.expectEqual(StripForm.initials, stripForm(ui, items, 40));
    try testing.expectEqual(StripForm.initials, stripForm(ui, items, 19));
    try testing.expectEqual(StripForm.none, stripForm(ui, items, 18));
    // One section is no strip at all: there is nowhere to jump.
    var one = [_]Item{ .{ .section = "UI" }, .{ .row = .{ .label = "A", .options = &bool_opts, .current = 0, .id = 0 } } };
    try testing.expectEqual(StripForm.none, stripForm(ui, &one, 80));

    // 40 columns: the box is 38 wide, 36 inside — short of the 41 the
    // names need, past the 19 the initials do.
    var narrow = try Fixture.init(40, 20);
    defer narrow.deinit();
    var s: State = .{};
    _ = draw(narrow.ui(), narrow.full(), &s, items, null, .{});
    const text = try narrow.text();
    try testing.expect(std.mem.indexOf(u8, text, "U · E · A · I · R") != null);
    try testing.expect(std.mem.indexOf(u8, text, "UI · Editor") == null);
}

test "] and [ step sections and put the header on the top row; g and G are the ends" {
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    try testing.expectEqual(@as(usize, 1), s.cursor);

    // `]`: the first row of Editor, its header at the top of the window.
    _ = try tkey(&s, Key.char(']'), items);
    try testing.expectEqual(@as(usize, 12), s.cursor);
    try testing.expectEqual(@as(usize, 11), s.scroll);
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    try testing.expect(std.mem.indexOf(u8, try f.text(), "── Editor ──") != null);

    // `[` from a section's first row steps back a section…
    _ = try tkey(&s, Key.char('['), items);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    // …and from anywhere else goes to this section's own first row.
    s.cursor = 8;
    _ = try tkey(&s, Key.char('['), items);
    try testing.expectEqual(@as(usize, 1), s.cursor);

    // Tab / Shift-Tab are the same jump.
    _ = try tkey(&s, Key.named(.tab), items);
    try testing.expectEqual(@as(usize, 12), s.cursor);
    _ = try tkey(&s, Key.named(.backtab), items);
    try testing.expectEqual(@as(usize, 1), s.cursor);

    // `G` / `g`, and `]` past the last section lands at the bottom.
    _ = try tkey(&s, Key.char('G'), items);
    try testing.expectEqual(items.len - 1, s.cursor);
    try testing.expectEqual(items.len - s.rows, s.scroll);
    _ = try tkey(&s, Key.char(']'), items);
    try testing.expectEqual(items.len - 1, s.cursor);
    _ = try tkey(&s, Key.char('g'), items);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expectEqual(@as(usize, 0), s.scroll);
    _ = try tkey(&s, Key.char('['), items);
    try testing.expectEqual(@as(usize, 1), s.cursor);
}

test "a click on a strip name jumps to that section, as the key does" {
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    // `Integrations` is section 3; the pointer resolves its cells to it.
    var at: ?[2]u16 = null;
    for (f.hits.items.items) |h| {
        if (h.target != .overlay_item) continue;
        const d = decodeHit(h.target.overlay_item);
        if (d == .section and d.section == 3) at = .{ h.rect.x, h.rect.y };
    }
    try testing.expectEqual(Hit{ .section = 3 }, decodeHit(f.hits.at(at.?[0], at.?[1]).?.overlay_item));
    // What `app/settings.zig`'s `click` does with it — the cursor on the
    // section's first row, its header on the window's top row.
    s.jumpTo(items, 2);
    try testing.expectEqual(@as(usize, 23), s.cursor);
    try testing.expectEqual(@as(usize, 22), s.scroll);
    s.jumpTo(items, 3);
    try testing.expectEqual(@as(usize, 34), s.cursor);
    // The last sections cannot reach the top row — the window stops at
    // the end of the list — but the header is still on screen.
    try testing.expectEqual(items.len - s.rows, s.scroll);
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    try testing.expect(std.mem.indexOf(u8, try f.text(), "── Integrations ──") != null);
}

test "the bar paints when the list overflows, takes its column off the rows, and a press on the track moves the window" {
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    try testing.expect(items.len > s.rows);
    // One `.scrollbar` hit, a single column, as tall as the list.
    var bar: ?@TypeOf(f.hits.items.items[0]) = null;
    for (f.hits.items.items) |h| if (h.target == .scrollbar) {
        bar = h;
    };
    try testing.expectEqual(scrollbar_owner, bar.?.target.scrollbar.owner.pane);
    try testing.expectEqual(@as(u16, 1), bar.?.rect.w);
    try testing.expectEqual(@as(u16, @intCast(s.rows)), bar.?.rect.h);
    // The rows stop one cell short of it: nothing paints under the bar.
    try testing.expectEqualStrings("█", f.cell(bar.?.rect.x, bar.?.rect.y).char.grapheme);

    // The thumb is proportional and sits at the top while scroll is 0.
    const th = scrollbar.thumb(bar.?.rect.h, items.len, s.rows, s.scroll).?;
    try testing.expectEqual(@as(u16, 0), th.start);
    try testing.expect(th.len > 0 and th.len < bar.?.rect.h);

    // A press half-way down the track puts the window half-way down the
    // list, and the cursor comes with it.
    s.barJump(items, bar.?.rect.h / 2, bar.?.rect.h);
    try testing.expect(s.scroll > 0 and s.scroll <= items.len - s.rows);
    try testing.expect(s.cursor >= s.scroll and s.cursor < s.scroll + s.rows);
    try testing.expect(items[s.cursor].focusable());
    // The paint keeps it where the bar put it.
    const put = s.scroll;
    _ = draw(f.ui(), f.full(), &s, items, null, .{});
    try testing.expectEqual(put, s.scroll);
    // The end of the track is the end of the list.
    s.barJump(items, bar.?.rect.h, bar.?.rect.h);
    try testing.expectEqual(items.len - s.rows, s.scroll);

    // A list that fits gets no bar at all.
    var fits = try Fixture.init(120, 40);
    defer fits.deinit();
    const short = sample();
    var s2: State = .{};
    _ = draw(fits.ui(), fits.full(), &s2, &short, null, .{});
    for (fits.hits.items.items) |h| try testing.expect(h.target != .scrollbar);
}

test "the footer carries the position, in the long form when the hint leaves room and the compact one when it does not" {
    var f = try Fixture.init(200, 60);
    defer f.deinit();
    const ui = f.ui();
    // Room for both: `12–40 of 97`.
    try testing.expectEqualStrings("12–40 of 97", positionText(ui, 11, 29, 97, 80));
    // The hint needs the room: the compact form. The choice is made
    // against the widest the long form can reach (every number as wide
    // as the total), so it does not flip as the list scrolls.
    try testing.expectEqualStrings("40/97", positionText(ui, 11, 29, 97, 66));
    try testing.expectEqualStrings("29/97", positionText(ui, 0, 29, 97, 66));
    try testing.expectEqualStrings("97/97", positionText(ui, 68, 29, 97, 66));
    // The last window stops at the end of the list.
    try testing.expectEqualStrings("69–97 of 97", positionText(ui, 68, 29, 97, 80));

    // The hint shrinks in four named steps and always ends in the way
    // out. `/ search` rides the two widest forms, so the key is on
    // screen wherever the footer can carry it.
    try testing.expectEqualStrings(hint_text_sections, hintFor(ui, ui.width(hint_text_sections), false, false));
    try testing.expectEqualStrings(hint_text_search, hintFor(ui, ui.width(hint_text_sections) - 1, false, false));
    try testing.expectEqualStrings(hint_text_search_tight, hintFor(ui, ui.width(hint_text_search) - 1, false, false));
    try testing.expectEqualStrings(hint_text, hintFor(ui, ui.width(hint_text), false, false));
    try testing.expectEqualStrings(hint_text_tight, hintFor(ui, ui.width(hint_text) - 1, false, false));
    try testing.expectEqualStrings(hint_text_tight, hintFor(ui, 0, false, false));
    // // changed (settings-typeahead): the standard profile's own five,
    // which never name a letter command the box no longer has.
    try testing.expectEqualStrings(std_hint_sections, hintFor(ui, ui.width(std_hint_sections), true, false));
    try testing.expectEqualStrings(std_hint_search, hintFor(ui, ui.width(std_hint_sections) - 1, true, false));
    try testing.expectEqualStrings(std_hint_search_tight, hintFor(ui, ui.width(std_hint_search) - 1, true, false));
    try testing.expectEqualStrings(std_hint, hintFor(ui, ui.width(std_hint), true, false));
    try testing.expectEqualStrings(std_hint_tight, hintFor(ui, ui.width(std_hint) - 1, true, false));
    try testing.expectEqualStrings(std_hint_tight, hintFor(ui, 0, true, false));
    for ([_][]const u8{ std_hint_sections, std_hint_search, std_hint_search_tight, std_hint, std_hint_tight }) |form| {
        try testing.expect(std.mem.indexOf(u8, form, "r/R") == null);
        try testing.expect(std.mem.indexOf(u8, form, "ctrl+r reset") != null);
    }
    // // changed (settings-filter-hint): while the field has the keys
    // the footer is the FIELD's, in either profile — it never promises
    // `adjust` or `save`, neither of which the arrows or Enter do there.
    try testing.expectEqualStrings(filter_hint, hintFor(ui, ui.width(filter_hint), false, true));
    try testing.expectEqualStrings(filter_hint, hintFor(ui, ui.width(filter_hint), true, true));
    try testing.expectEqualStrings(filter_hint_move, hintFor(ui, ui.width(filter_hint) - 1, true, true));
    try testing.expectEqualStrings(filter_hint_tight, hintFor(ui, ui.width(filter_hint_move) - 1, true, true));
    try testing.expectEqualStrings(filter_hint_tightest, hintFor(ui, ui.width(filter_hint_tight) - 1, true, true));
    try testing.expectEqualStrings(filter_hint_tightest, hintFor(ui, 0, false, true));
    for ([_][]const u8{ filter_hint, filter_hint_move, filter_hint_tight, filter_hint_tightest }) |form| {
        try testing.expect(std.mem.indexOf(u8, form, "adjust") == null);
        try testing.expect(std.mem.indexOf(u8, form, "save") == null);
        try testing.expect(std.mem.indexOf(u8, form, "Esc clears") != null);
    }
    try testing.expect(std.mem.indexOf(u8, hint_text_sections, "/ search") != null);
    try testing.expect(std.mem.indexOf(u8, hint_text_search, "/ search") != null);
    try testing.expect(std.mem.indexOf(u8, hint_text_search_tight, "/ search") != null);
    // The ladder is descending, or "the widest that fits" means nothing.
    try testing.expect(ui.width(hint_text_sections) > ui.width(hint_text_search));
    try testing.expect(ui.width(hint_text_search) > ui.width(hint_text_search_tight));
    try testing.expect(ui.width(hint_text_search_tight) > ui.width(hint_text));
    try testing.expect(ui.width(hint_text) > ui.width(hint_text_tight));

    // On the screen: an overflowing list shows a position, one that fits
    // shows none.
    var buf: [60]Item = undefined;
    const items = sectioned(&buf);
    var s: State = .{};
    var box = try Fixture.init(120, 40);
    defer box.deinit();
    _ = draw(box.ui(), box.full(), &s, items, null, .{});
    var text = try box.text();
    try testing.expect(std.mem.indexOf(u8, text, ui.fmt("{d}/{d}", .{ s.rows, items.len })) != null);
    try testing.expect(std.mem.indexOf(u8, text, "Esc cancel") != null);
    var fits = try Fixture.init(120, 40);
    defer fits.deinit();
    const short = sample();
    var s2: State = .{};
    _ = draw(fits.ui(), fits.full(), &s2, &short, null, .{});
    text = try fits.text();
    try testing.expect(std.mem.indexOf(u8, text, " of ") == null);
    try testing.expect(std.mem.indexOf(u8, text, "/6") == null);
}

// ── the filter ──

const dock_opts = [_][]const u8{ "hidden", "auto_hide", "always" };
const edge_opts = [_][]const u8{ "left", "right", "bottom" };

/// A list with three sections, so a query can empty one of them.
fn filterSample() [9]Item {
    return .{
        .{ .section = "UI" },
        .{ .row = .{ .label = "Launcher dock", .options = &dock_opts, .current = 2, .id = 0 } },
        .{ .row = .{ .label = "Launcher dock edge", .options = &edge_opts, .current = 1, .id = 1 } },
        .{ .row = .{ .label = "Line numbers", .options = &bool_opts, .current = 1, .id = 2 } },
        .{ .section = "Editor" },
        .{ .row = .{ .label = "Tab width", .options = &.{}, .current = 4, .id = 3, .number = .{ .min = 1, .max = 16, .step = 1 } } },
        .{ .row = .{ .label = "Input style", .options = &style_opts, .current = 1, .id = 4 } },
        .{ .section = "Reset" },
        .{ .action = .{ .label = "Reset all to defaults", .id = 9 } },
    };
}

test "the match rule reads the label, the current value's word and the section name, case-insensitively" {
    const items = filterSample();
    const dock = items[1].row;
    const numbers = items[3].row;
    const tab_width = items[5].row;
    // The label, in any case.
    try testing.expect(rowMatches(dock, "UI", "dock"));
    try testing.expect(rowMatches(dock, "UI", "DOCK"));
    try testing.expect(rowMatches(dock, "UI", "Launcher"));
    try testing.expect(!rowMatches(dock, "UI", "theme"));
    // The word the current value reads as — `always`, not the other
    // two choices the row could be set to.
    try testing.expect(rowMatches(dock, "UI", "always"));
    try testing.expect(rowMatches(dock, "UI", "ALWAYS"));
    try testing.expect(!rowMatches(dock, "UI", "auto_hide"));
    try testing.expect(rowMatches(numbers, "UI", "on"));
    try testing.expect(!rowMatches(numbers, "UI", "off"));
    // A number row's value is its digits.
    try testing.expect(rowMatches(tab_width, "Editor", "4"));
    try testing.expect(!rowMatches(tab_width, "Editor", "7"));
    // The section name, so `editor` brings the whole section.
    try testing.expect(rowMatches(tab_width, "Editor", "edit"));
    try testing.expect(rowMatches(items[6].row, "Editor", "EDITOR"));
    // An empty query matches everything.
    try testing.expect(rowMatches(dock, "UI", ""));
}

test "filtering keeps a section header only where something under it matched" {
    const items = filterSample();
    // `dock` — two UI rows, and no Editor or Reset header at all.
    const dock = try filtered(testing.allocator, &items, "dock");
    defer testing.allocator.free(dock);
    try testing.expectEqual(@as(usize, 3), dock.len);
    try testing.expectEqualStrings("UI", dock[0].section);
    try testing.expectEqualStrings("Launcher dock", dock[1].row.label);
    try testing.expectEqualStrings("Launcher dock edge", dock[2].row.label);
    try testing.expectEqual(@as(usize, 2), focusableCount(dock));
    try testing.expect(sectionIndexOfName(dock, "Editor") == null);

    // A section name pulls its whole section, header and all.
    const editor = try filtered(testing.allocator, &items, "editor");
    defer testing.allocator.free(editor);
    try testing.expectEqual(@as(usize, 3), editor.len);
    try testing.expectEqualStrings("Editor", editor[0].section);
    try testing.expectEqual(@as(usize, 0), sectionIndexOfName(editor, "Editor").?);

    // The action row matches on its own label, and brings its header.
    const reset = try filtered(testing.allocator, &items, "defaults");
    defer testing.allocator.free(reset);
    try testing.expectEqual(@as(usize, 2), reset.len);
    try testing.expectEqualStrings("Reset", reset[0].section);
    try testing.expect(reset[1] == .action);

    // Nothing at all: no headers either, and the box says so where the
    // rows would be.
    const none = try filtered(testing.allocator, &items, "zzzz");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    var f = try Fixture.init(70, 20);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    s.openFilter();
    try text_field.insert(&s.filter.buf, &s.filter.caret, testing.allocator, "zzzz");
    _ = draw(f.ui(), f.full(), &s, none, null, .{ .all = &items });
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "no setting matches \"zzzz\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0 of 6") != null);

    // An empty query is the whole list, copied.
    const all = try filtered(testing.allocator, &items, "");
    defer testing.allocator.free(all);
    try testing.expectEqual(items.len, all.len);
    try testing.expectEqual(@as(usize, 6), focusableCount(all));
}

test "`/` opens the pill, Ctrl+F only in the standard profile, and the field takes the keys" {
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const items = filterSample();
    try testing.expect(!s.filter.open);
    // Ctrl+F is not the vim profile's.
    try testing.expect(try tkey(&s, Key.ctrl('f'), &items) == .consumed);
    try testing.expect(!s.filter.open);
    try testing.expect(try handleKey(&s, Key.ctrl('f'), &items, .{ .gpa = testing.allocator, .ctrl_f = true }) == .consumed);
    try testing.expect(s.filter.open and s.filter.focused);
    s.filter.clear();
    // `/` is everyone's.
    try testing.expect(try tkey(&s, Key.char('/'), &items) == .consumed);
    try testing.expect(s.filter.open and s.filter.focused);
    // Typing filters; the list keys type instead of acting.
    for ("dock") |c| try testing.expect(try tkey(&s, Key.char(c), &items) == .refilter);
    try testing.expectEqualStrings("dock", s.filter.text());
    // `j` and `R` are letters in the field, not move and reset-all.
    try testing.expect(try tkey(&s, Key.char('j'), &items) == .refilter);
    try testing.expectEqualStrings("dockj", s.filter.text());
    try testing.expect(try tkey(&s, Key.named(.backspace), &items) == .refilter);
    try testing.expectEqualStrings("dock", s.filter.text());
    // ←→ move the caret while the field has the keys; they adjust the
    // row only once Enter has handed the list back.
    try testing.expect(try tkey(&s, Key.named(.left), &items) == .consumed);
    try testing.expectEqual(@as(usize, 3), s.filter.caret);
    try testing.expect(try tkey(&s, Key.named(.home), &items) == .consumed);
    try testing.expectEqual(@as(usize, 0), s.filter.caret);
    // ↑↓ walk the matches without leaving the field.
    const dock = try filtered(testing.allocator, &items, "dock");
    defer testing.allocator.free(dock);
    s.cursor = 1;
    try testing.expect(try tkey(&s, Key.named(.down), dock) == .consumed);
    try testing.expectEqual(@as(usize, 2), s.cursor);
    try testing.expect(s.filter.focused);
    // Enter hands the list back, query and all; `←` is an adjust again.
    try testing.expect(try tkey(&s, Key.named(.enter), dock) == .consumed);
    try testing.expect(!s.filter.focused and s.filter.open);
    try testing.expectEqualStrings("dock", s.filter.text());
    try testing.expectEqual(@as(i8, -1), (try tkey(&s, Key.named(.left), dock)).adjust.delta);
}

test "Esc clears the query first and cancels the overlay second" {
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const items = filterSample();
    // Nothing to clear: Esc is the way out.
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .cancel);
    // A live query: Esc takes the query, the pill and the focus.
    _ = try tkey(&s, Key.char('/'), &items);
    for ("dock") |c| _ = try tkey(&s, Key.char(c), &items);
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .refilter);
    try testing.expectEqualStrings("", s.filter.text());
    try testing.expect(!s.filter.open and !s.filter.focused);
    // The second press is the overlay's.
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .cancel);
    // Esc still clears once the list has the keys back (Enter left the
    // query on), rather than closing the box under a live filter.
    _ = try tkey(&s, Key.char('/'), &items);
    for ("dock") |c| _ = try tkey(&s, Key.char(c), &items);
    _ = try tkey(&s, Key.named(.enter), &items);
    try testing.expect(!s.filter.focused);
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .refilter);
    try testing.expect(try tkey(&s, Key.named(.esc), &items) == .cancel);
}

test "the pill paints under the title, the strip dims the sections with no match, and the footer counts them" {
    var f = try Fixture.init(70, 20);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const all = filterSample();
    s.openFilter();
    try text_field.insert(&s.filter.buf, &s.filter.caret, testing.allocator, "dock");
    const vis = try filtered(testing.allocator, &all, "dock");
    defer testing.allocator.free(vis);
    const caret = draw(f.ui(), f.full(), &s, vis, null, .{ .all = &all });
    const text = try f.text();
    // The family pill, with the query in it, and the caret at its end.
    try testing.expect(std.mem.indexOf(u8, text, "\u{F0349} dock") != null);
    try testing.expect(caret != null);
    // Only the matching rows, and only the section that holds them.
    try testing.expect(std.mem.indexOf(u8, text, "── UI ──") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Launcher dock:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Line numbers") == null);
    try testing.expect(std.mem.indexOf(u8, text, "── Editor ──") == null);
    // The strip still names every section — a click has to keep working
    // — and the footer says how much of the list is left.
    try testing.expect(std.mem.indexOf(u8, text, "UI · Editor · Reset") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 of 6") != null);
    // Every name is still its own hit, matched or not — and the ones
    // the query emptied are dimmed, so the strip says where the
    // matches are rather than only where the sections are.
    var seen: usize = 0;
    var dim_editor = false;
    var dim_ui = true;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .section => |n| {
            seen += 1;
            const st = f.style(h.rect.x, h.rect.y);
            if (n == 0) dim_ui = st.dim;
            if (n == 1) dim_editor = st.dim;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expect(dim_editor and !dim_ui);
    // The pill is a hit too, so a click can put the keys back in it.
    var saw_filter = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .filter => saw_filter = true,
        else => {},
    };
    try testing.expect(saw_filter);
}

test "an unfocused pill keeps the query on screen and reads `/ filter` when empty" {
    var f = try Fixture.init(70, 20);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const all = filterSample();
    s.openFilter();
    _ = draw(f.ui(), f.full(), &s, &all, null, .{ .all = &all });
    var text = try f.text();
    // Focused and empty: the family's `type to filter…`.
    try testing.expect(std.mem.indexOf(u8, text, "type to filter") != null);
    // No query, so the footer keeps its scroll position rather than a
    // count — nothing has been filtered out.
    try testing.expect(std.mem.indexOf(u8, text, " of 6") == null);
    s.filter.focused = false;
    _ = draw(f.ui(), f.full(), &s, &all, null, .{ .all = &all });
    text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "\u{F0349} / filter") != null);
}

/// The frame's top and bottom rows in a rendered screen, so a test can
/// say where the box came out and how tall it is.
const BoxRows = struct { top: usize, bottom: usize };

fn boxRows(text: []const u8) BoxRows {
    var out: BoxRows = .{ .top = 0, .bottom = 0 };
    var it = std.mem.splitScalar(u8, text, '\n');
    var y: usize = 0;
    var seen_top = false;
    while (it.next()) |line| : (y += 1) {
        if (std.mem.indexOf(u8, line, "\u{256d}") != null and !seen_top) { // chrome-audit: allow — a test helper reading the frame back
            out.top = y;
            seen_top = true;
        }
        if (std.mem.indexOf(u8, line, "\u{2570}") != null) out.bottom = y; // chrome-audit: allow — as above
    }
    return out;
}

/// One draw on a screen of its own — the fixture never clears, so two
/// draws into one would leave the first box's corners on screen and a
/// shrinking box would measure as though it had not moved.
fn drawnBox(s: *State, items: []const Item, all: []const Item) !BoxRows {
    var f = try Fixture.init(70, 30);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), s, items, null, .{ .all = all });
    return boxRows(try f.text());
}

test "the box keeps the height the whole list asks for while a query narrows it" {
    // Thirty rows: the 70 % cap is 21 and the list wants 15, so the
    // list length is what decides the height here. On a screen where
    // the cap won, every list would come out the same size and this
    // would pass without the fix.
    var s: State = .{};
    defer s.deinit(testing.allocator);
    const all = filterSample();
    s.openFilter();
    const open = try drawnBox(&s, &all, &all);
    // Nine items plus the border, the strip, the footer and the pill.
    try testing.expectEqual(@as(usize, 14), open.bottom - open.top);

    // Two rows and one header survive `dock` — a third of the list.
    // The box does not follow them down.
    try text_field.insert(&s.filter.buf, &s.filter.caret, testing.allocator, "dock");
    const vis = try filtered(testing.allocator, &all, "dock");
    defer testing.allocator.free(vis);
    try testing.expectEqual(@as(usize, 3), vis.len);
    const narrowed = try drawnBox(&s, vis, &all);
    try testing.expectEqual(open.top, narrowed.top);
    try testing.expectEqual(open.bottom, narrowed.bottom);

    // And a query nothing answers to leaves the box where it is too, so
    // the `no setting matches` line has the same ground under it.
    const none = try filtered(testing.allocator, &all, "zzz");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    const empty = try drawnBox(&s, none, &all);
    try testing.expectEqual(open.top, empty.top);
    try testing.expectEqual(open.bottom, empty.bottom);
}
