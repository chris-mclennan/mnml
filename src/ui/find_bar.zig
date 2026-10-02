//! Find bar — docked at the bottom of a pane: the `Find` label, the
//! query, the `.*`, `Aa` and `\b` (whole word) toggles, and the match
//! count — `match 2/3` or `no matches`, the exact words the gate
//! asserts. A second row with `Replace` appears when the app asks for
//! it (VS Code's Ctrl+H).
//!
//! Both fields are `text_field`s. The bar does not search: it edits the
//! query and reports what the user meant (`changed`, `next`, `prev`,
//! `submit`, `replace_one`, …) and the app does the work and hands back
//! an `Info` to paint. The toggles flip their own flags here so a
//! repaint is right before the app has even looked.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const key_mod = @import("../core/key.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;
pub const Caret = text_field.Caret;

pub const Focus = enum { query, replace };

pub const State = struct {
    query: text_field.Buf = .empty,
    caret: usize = 0,
    /// Each field's selection (`text_field.clickSelect`), to its caret.
    anchor: ?usize = null,
    replace: text_field.Buf = .empty,
    replace_caret: usize = 0,
    replace_anchor: ?usize = null,
    focus: Focus = .query,
    regex: bool = false,
    match_case: bool = false,
    /// VS Code's Alt+W: only matches that are whole words count.
    whole_word: bool = false,
    in_selection: bool = false,
    show_replace: bool = false,
    /// The whole query is selected (a second Ctrl+F on an open bar, as
    /// VS Code does): the next typed char replaces it, Backspace /
    /// Delete clear it, any other field key just drops the selection.
    select_all: bool = false,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.replace.deinit(gpa);
        s.* = .{};
    }

    pub fn queryText(s: *const State) []const u8 {
        return s.query.items;
    }

    pub fn replaceText(s: *const State) []const u8 {
        return s.replace.items;
    }

    pub fn setQuery(s: *State, gpa: Allocator, value: []const u8) Allocator.Error!void {
        s.query.clearRetainingCapacity();
        try s.query.appendSlice(gpa, value);
        s.caret = s.query.items.len;
        s.anchor = null;
    }
};

/// `ignored`: not a bar key and not a field key — a modified chord the
/// app may still resolve (Ctrl+S saves from the bar, as in VS Code).
pub const Outcome = enum { consumed, ignored, cancel, next, prev, submit, toggle_regex, toggle_case, toggle_word, focus_toggle, replace_one, replace_all, changed, history_prev, history_next };

/// Match info from the app: `current` is 0-based.
pub const Info = struct { current: ?usize, total: usize };

/// Hit ids: `.overlay_item(n)`.
pub const hit_query: u32 = 0;
pub const hit_replace: u32 = 1;
pub const hit_regex: u32 = 2;
pub const hit_case: u32 = 3;
pub const hit_word: u32 = 4;

pub const label_find = "Find";
pub const label_find_selection = "Find (in selection)";
pub const label_replace = "Replace";
pub const chip_regex = ".*";
pub const chip_case = "Aa";
pub const chip_word = "\\b";
pub const no_matches = "no matches";

/// enter → submit (replace field: replace_one), ctrl+enter / ctrl+alt+enter
/// → replace_all, shift+enter / ctrl+p / shift+F3 → prev, ctrl+n / F3 →
/// next, ↑ / ↓ → the find history, esc → cancel, ctrl+r / alt+r regex,
/// ctrl+c / alt+c case, alt+w whole word, tab / shift+tab → focus_toggle;
/// typing → changed.
pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
    const m = key.mods;
    switch (key.code) {
        .esc => return .cancel,
        .enter => {
            if (m.ctrl or m.alt) return if (s.show_replace) .replace_all else .submit;
            if (m.shift) return .prev;
            return if (s.focus == .replace) .replace_one else .submit;
        },
        .up => return .history_prev,
        .down => return .history_next,
        .tab, .backtab => {
            if (s.show_replace) s.focus = if (s.focus == .query) .replace else .query;
            return .focus_toggle;
        },
        .f => |n| {
            if (n == 3) return if (m.shift) .prev else .next;
        },
        .char => |c| if (m.ctrl and !m.alt) switch (c) {
            'r' => {
                s.regex = !s.regex;
                return .toggle_regex;
            },
            'c' => {
                s.match_case = !s.match_case;
                return .toggle_case;
            },
            'n' => return .next,
            'p' => return .prev,
            else => {},
        } else if (m.alt and !m.ctrl and !m.super) switch (c) {
            // VS Code's find widget: Alt+C case, Alt+W whole word, Alt+R regex.
            'c' => {
                s.match_case = !s.match_case;
                return .toggle_case;
            },
            'w' => {
                s.whole_word = !s.whole_word;
                return .toggle_word;
            },
            'r' => {
                s.regex = !s.regex;
                return .toggle_regex;
            },
            else => {},
        },
        else => {},
    }
    if (s.select_all) {
        s.select_all = false;
        const replaces = switch (key.code) {
            .backspace, .delete => true,
            .char => key.typed() != null,
            else => false,
        };
        if (replaces and s.focus == .query) {
            s.query.clearRetainingCapacity();
            s.caret = 0;
            if (key.code != .char) return .changed;
        }
    }
    const edit = if (s.focus == .query)
        try text_field.editKey(&s.query, &s.caret, &s.anchor, gpa, key)
    else
        try text_field.editKey(&s.replace, &s.replace_caret, &s.replace_anchor, gpa, key);
    return switch (edit) {
        .changed => .changed,
        .moved => .consumed,
        .ignored => .ignored,
    };
}

/// Into the focused field.
pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    if (s.focus == .query) {
        try text_field.insertSel(&s.query, &s.caret, &s.anchor, gpa, text);
    } else {
        try text_field.insertSel(&s.replace, &s.replace_caret, &s.replace_anchor, gpa, text);
    }
}

/// The count text: `match 2/3`, `no matches`, or `3 matches` when
/// nothing is current.
pub fn statusText(ui: Ui, info: Info) []const u8 {
    if (info.total == 0) return no_matches;
    if (info.current) |c| return ui.fmt("match {d}/{d}", .{ c + 1, info.total });
    return ui.fmt("{d} matches", .{info.total});
}

/// Two rows at most, from the top of `area`. Returns the focused
/// field's caret.
pub fn draw(ui: Ui, area: Rect, s: *const State, info: Info) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.statusline);
    if (area.isEmpty()) return null;
    const bg = t.statusline.bg;
    const field_style = Theme.onBg(t.fg, t.chip.bg);
    var caret: ?Caret = null;

    // ── row 0: Find ──
    const r0 = area.row(0);
    var x = r0.x;
    const find_label = ui.fmt(" {s} ", .{if (s.in_selection) label_find_selection else label_find});
    const find_style = if (s.focus == .query) t.chip_active else t.chip;
    x += ui.putStr(x, r0.y, r0.w, find_label, find_style);
    x += ui.putStr(x, r0.y, r0.right() -| x, " ", t.statusline);

    // Right side, from the edge: status, then the two toggles.
    const status = statusText(ui, info);
    const status_style = Theme.onBg(if (info.total == 0) t.warn_fg else t.muted, bg);
    var right = r0.right();
    const regex_chip = ui.fmt(" {s} ", .{chip_regex});
    const case_chip = ui.fmt(" {s} ", .{chip_case});
    const word_chip = ui.fmt(" {s} ", .{chip_word});
    const status_w = ui.width(status) + 1;
    const chips_w = ui.width(regex_chip) + 1 + ui.width(case_chip) + 1 + ui.width(word_chip) + 1;
    const field_min: u16 = 6;
    if (right -| x >= status_w + chips_w + field_min) {
        right -= 1;
        right = ui.putStrRight(right, r0.y, status_w, status, status_style);
        right -= 1;
        const wx = ui.putStrRight(right, r0.y, ui.width(word_chip), word_chip, if (s.whole_word) t.chip_active else t.chip);
        ui.hit(Rect.init(wx, r0.y, right - wx, 1), .{ .overlay_item = hit_word });
        right = wx - 1;
        const cx = ui.putStrRight(right, r0.y, ui.width(case_chip), case_chip, if (s.match_case) t.chip_active else t.chip);
        ui.hit(Rect.init(cx, r0.y, right - cx, 1), .{ .overlay_item = hit_case });
        right = cx - 1;
        const rx = ui.putStrRight(right, r0.y, ui.width(regex_chip), regex_chip, if (s.regex) t.chip_active else t.chip);
        ui.hit(Rect.init(rx, r0.y, right - rx, 1), .{ .overlay_item = hit_regex });
        right = rx - 1;
    } else if (right -| x >= status_w + field_min) {
        right -= 1;
        right = ui.putStrRight(right, r0.y, status_w, status, status_style);
        right -= 1;
    }
    const qf = Rect.init(x, r0.y, right -| x, 1);
    ui.hit(qf, .{ .overlay_item = hit_query });
    const query_style = if (s.select_all and s.query.items.len > 0) t.selection else field_style;
    const qc = text_field.draw(ui, qf, s.query.items, s.caret, .{ .style = query_style, .focused = s.focus == .query, .anchor = s.anchor, .field = .find_query });
    if (s.focus == .query) caret = qc;

    // ── row 1: Replace ──
    if (s.show_replace and area.h >= 2) {
        const r1 = area.row(1);
        var rx1 = r1.x;
        const rep_label = ui.fmt(" {s} ", .{label_replace});
        rx1 += ui.putStr(rx1, r1.y, r1.w, rep_label, if (s.focus == .replace) t.chip_active else t.chip);
        rx1 += ui.putStr(rx1, r1.y, r1.right() -| rx1, " ", t.statusline);
        const rf = Rect.init(rx1, r1.y, (r1.right() -| 1) -| rx1, 1);
        ui.hit(rf, .{ .overlay_item = hit_replace });
        const rc = text_field.draw(ui, rf, s.replace.items, s.replace_caret, .{ .style = field_style, .focused = s.focus == .replace, .anchor = s.replace_anchor, .field = .find_replace });
        if (s.focus == .replace) caret = rc;
    }
    return caret;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the gate's literals: Find, match N/M, no matches" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    try s.setQuery(testing.allocator, "alpha");
    var caret = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 3 });
    try f.expectContains("Find");
    try f.expectContains("match 1/3");
    try f.expectRow(0, " Find  alpha" ++ " " ** 23 ++ " .*   Aa   \\b  match 1/3");
    try testing.expectEqual(Caret{ .x = 12, .y = 0 }, caret.?);
    try testing.expect(f.bgEql(1, 0, f.theme.chip_active));
    try testing.expect(f.bgEql(7, 0, f.theme.chip));
    _ = draw(f.ui(), f.full(), &s, .{ .current = 2, .total = 3 });
    try f.expectContains("match 3/3");
    _ = draw(f.ui(), f.full(), &s, .{ .current = null, .total = 0 });
    try f.expectContains("no matches");
    try f.expectLacks("match ");
    _ = draw(f.ui(), f.full(), &s, .{ .current = null, .total = 4 });
    try f.expectContains("4 matches");
    // Hits: the query field, the toggles.
    try testing.expectEqual(hit_query, f.hits.at(20, 0).?.overlay_item);
    try testing.expectEqual(hit_regex, f.hits.at(35, 0).?.overlay_item);
    try testing.expectEqual(hit_case, f.hits.at(40, 0).?.overlay_item);
    try testing.expectEqual(hit_word, f.hits.at(45, 0).?.overlay_item);
    s.in_selection = true;
    s.regex = true;
    s.whole_word = true;
    caret = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 1 });
    try f.expectContains(" Find (in selection) ");
    try testing.expect(f.bgEql(35, 0, f.theme.chip_active));
    try testing.expect(f.bgEql(45, 0, f.theme.chip_active));
}

test "the replace row, its focus and caret" {
    var f = try Fixture.init(60, 2);
    defer f.deinit();
    var s: State = .{ .show_replace = true };
    defer s.deinit(testing.allocator);
    try s.setQuery(testing.allocator, "beta");
    _ = try handleKey(&s, testing.allocator, Key.named(.tab));
    try testing.expectEqual(Focus.replace, s.focus);
    _ = try handleKey(&s, testing.allocator, Key.char('D'));
    const caret = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 3 });
    try f.expectContains(" Replace  D");
    try testing.expectEqual(Caret{ .x = 11, .y = 1 }, caret.?);
    try testing.expect(f.bgEql(1, 1, f.theme.chip_active));
    try testing.expect(f.bgEql(1, 0, f.theme.chip));
    try testing.expectEqual(hit_replace, f.hits.at(20, 1).?.overlay_item);
    // Only one row given: the replace row is not painted.
    var g = try Fixture.init(60, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &s, .{ .current = 0, .total = 3 });
    try g.expectLacks("Replace");
}

test "keys map to outcomes and flip the toggles; typing is changed" {
    const gpa = testing.allocator;
    var s: State = .{};
    defer s.deinit(gpa);
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('a')));
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.left)));
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.named(.delete)));
    try testing.expectEqualStrings("", s.queryText());
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    try testing.expectEqual(Outcome.prev, try handleKey(&s, gpa, .{ .code = .enter, .mods = .{ .shift = true } }));
    try testing.expectEqual(Outcome.next, try handleKey(&s, gpa, Key.ctrl('n')));
    try testing.expectEqual(Outcome.history_prev, try handleKey(&s, gpa, Key.named(.up)));
    try testing.expectEqual(Outcome.history_next, try handleKey(&s, gpa, Key.named(.down)));
    try testing.expectEqual(Outcome.prev, try handleKey(&s, gpa, .{ .code = .{ .f = 3 }, .mods = .{ .shift = true } }));
    try testing.expectEqual(Outcome.next, try handleKey(&s, gpa, Key.named(.{ .f = 3 })));
    try testing.expectEqual(Outcome.toggle_regex, try handleKey(&s, gpa, Key.ctrl('r')));
    try testing.expect(s.regex);
    try testing.expectEqual(Outcome.toggle_case, try handleKey(&s, gpa, Key.ctrl('c')));
    try testing.expect(s.match_case);
    // VS Code's Alt+C / Alt+W / Alt+R.
    try testing.expectEqual(Outcome.toggle_case, try handleKey(&s, gpa, .{ .code = .{ .char = 'c' }, .mods = .{ .alt = true } }));
    try testing.expect(!s.match_case);
    try testing.expectEqual(Outcome.toggle_word, try handleKey(&s, gpa, .{ .code = .{ .char = 'w' }, .mods = .{ .alt = true } }));
    try testing.expect(s.whole_word);
    try testing.expectEqual(Outcome.toggle_regex, try handleKey(&s, gpa, .{ .code = .{ .char = 'r' }, .mods = .{ .alt = true } }));
    try testing.expect(!s.regex);
    try testing.expectEqualStrings("", s.queryText());
    try testing.expectEqual(Outcome.cancel, try handleKey(&s, gpa, Key.named(.esc)));
    // A chord neither the bar nor the field wants is the app's to resolve.
    try testing.expectEqual(Outcome.ignored, try handleKey(&s, gpa, Key.ctrl('s')));
    try testing.expectEqual(Outcome.ignored, try handleKey(&s, gpa, .{ .code = .{ .char = 'P' }, .mods = .{ .ctrl = true, .shift = true } }));
    // Without a replace row, tab reports but the focus stays on the query.
    try testing.expectEqual(Outcome.focus_toggle, try handleKey(&s, gpa, Key.named(.tab)));
    try testing.expectEqual(Focus.query, s.focus);
    s.show_replace = true;
    _ = try handleKey(&s, gpa, Key.named(.tab));
    try testing.expectEqual(Outcome.replace_one, try handleKey(&s, gpa, Key.named(.enter)));
    try testing.expectEqual(Outcome.replace_all, try handleKey(&s, gpa, .{ .code = .enter, .mods = .{ .ctrl = true } }));
    try testing.expectEqual(Outcome.replace_all, try handleKey(&s, gpa, .{ .code = .enter, .mods = .{ .ctrl = true, .alt = true } }));
    // Shift+Tab goes back to the query.
    try testing.expectEqual(Outcome.focus_toggle, try handleKey(&s, gpa, Key.named(.backtab)));
    try testing.expectEqual(Focus.query, s.focus);
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    _ = try handleKey(&s, gpa, Key.named(.tab));
    try paste(&s, gpa, "new\nvalue");
    try testing.expectEqualStrings("new value", s.replaceText());
    try testing.expectEqualStrings("", s.queryText());
}

test "a selected query is replaced by typing, cleared by Backspace, kept by a move" {
    const gpa = testing.allocator;
    var s: State = .{};
    defer s.deinit(gpa);
    try s.setQuery(gpa, "alpha");
    s.select_all = true;
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.left)));
    try testing.expectEqualStrings("alpha", s.queryText());
    try testing.expect(!s.select_all);
    s.select_all = true;
    // ↓ (history) acts without touching the selection: typing afterwards still replaces.
    try testing.expectEqual(Outcome.history_next, try handleKey(&s, gpa, Key.named(.down)));
    try testing.expect(s.select_all);
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('z')));
    try testing.expectEqualStrings("z", s.queryText());
    try testing.expectEqual(@as(usize, 1), s.caret);
    s.select_all = true;
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.named(.backspace)));
    try testing.expectEqualStrings("", s.queryText());
    // Painted as a selection while it stands.
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    try s.setQuery(gpa, "beta");
    s.select_all = true;
    _ = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 1 });
    try testing.expect(f.bgEql(7, 0, f.theme.selection));
    s.select_all = false;
    _ = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 1 });
    try testing.expect(f.bgEql(7, 0, f.theme.chip));
}

test "narrow bars drop the toggles, then the count, and never panic" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    try s.setQuery(testing.allocator, "x");
    _ = draw(f.ui(), f.full(), &s, .{ .current = 0, .total = 1 });
    try f.expectContains("match 1/1");
    try f.expectLacks("Aa");
    var g = try Fixture.init(14, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), &s, .{ .current = 0, .total = 1 });
    try g.expectContains(" Find  x");
    try g.expectLacks("match");
    var h = try Fixture.init(3, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), &s, .{ .current = null, .total = 0 });
    _ = draw(h.ui(), Rect.empty, &s, .{ .current = null, .total = 0 });
}
