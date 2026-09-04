//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The find / replace bar docked at the bottom of a pane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("rect.zig");
const context = @import("context.zig");
const prompt = @import("prompt.zig");
const key_mod = @import("../core/key.zig");
pub const Key = key_mod.Key;
pub const Ui = context.Ui;

pub const FindBar = struct {
    pub const State = struct {
        query: std.ArrayListUnmanaged(u8) = .empty,
        caret: usize = 0,
        replace: std.ArrayListUnmanaged(u8) = .empty,
        replace_caret: usize = 0,
        focus: enum { query, replace } = .query,
        regex: bool = false,
        match_case: bool = false,
        in_selection: bool = false,
        show_replace: bool = false,
    };
    pub const Outcome = enum { consumed, cancel, next, prev, submit, toggle_regex, toggle_case, focus_toggle, replace_one, replace_all, changed };
    pub const Info = struct { current: ?usize, total: usize };

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.replace.deinit(gpa);
    }

    pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
        switch (key.code) {
            .esc => return .cancel,
            .enter => {
                if (key.mods.shift) return .prev;
                if (key.mods.ctrl or key.mods.alt) return .replace_all;
                return if (s.focus == .replace) .replace_one else .submit;
            },
            .tab => {
                if (s.show_replace) s.focus = if (s.focus == .query) .replace else .query;
                return .focus_toggle;
            },
            .backtab => {
                if (s.show_replace) s.focus = if (s.focus == .query) .replace else .query;
                return .focus_toggle;
            },
            .down => return .next,
            .up => return .prev,
            .f => |n| return if (n == 3) (if (key.mods.shift) .prev else .next) else .consumed,
            .char => |c| if (key.mods.ctrl) {
                switch (c) {
                    'r' => {
                        s.regex = !s.regex;
                        return .toggle_regex;
                    },
                    'c' => {
                        s.match_case = !s.match_case;
                        return .toggle_case;
                    },
                    'h' => {
                        s.show_replace = true;
                        s.focus = .replace;
                        return .focus_toggle;
                    },
                    else => {},
                }
            },
            else => {},
        }
        const before = if (s.focus == .query) s.query.items.len else s.replace.items.len;
        const edited = if (s.focus == .query) try prompt.editKey(gpa, &s.query, &s.caret, key) else try prompt.editKey(gpa, &s.replace, &s.replace_caret, key);
        const after = if (s.focus == .query) s.query.items.len else s.replace.items.len;
        if (edited and (before != after or key.code == .char) and s.focus == .query) return .changed;
        return .consumed;
    }

    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
        if (s.focus == .query) try prompt.insertText(gpa, &s.query, &s.caret, text) else try prompt.insertText(gpa, &s.replace, &s.replace_caret, text);
    }

    /// Row 1: `Find` label, the query, then `match N/M` or `no matches`.
    pub fn draw(ui: Ui, area: Rect, s: *const State, info: Info) void {
        if (area.isEmpty()) return;
        ui.canvas.fill(area, ui.theme.panel_bg);
        const label: []const u8 = if (s.in_selection) "Find (in selection)" else "Find";
        const cur = @min(s.caret, s.query.items.len);
        const status = if (info.total == 0)
            "no matches"
        else if (info.current) |c|
            std.fmt.allocPrint(ui.arena, "match {d}/{d}", .{ c + 1, info.total }) catch "match"
        else
            std.fmt.allocPrint(ui.arena, "{d} matches", .{info.total}) catch "matches";
        const line = std.mem.concat(ui.arena, u8, &.{ " ", label, ": ", s.query.items[0..cur], "\u{258f}", s.query.items[cur..], "   ", status, if (s.regex) "  [.*]" else "", if (s.match_case) "  [Aa]" else "" }) catch return;
        _ = ui.canvas.text(area.row(0), &.{.{ .text = line, .style = ui.theme.panel_bg }}, .{});
        ui.hits.add(ui.arena, area.row(0), .{ .overlay_item = 0 }) catch {};
        if (s.show_replace and area.h >= 2) {
            const rc = @min(s.replace_caret, s.replace.items.len);
            const l2 = std.mem.concat(ui.arena, u8, &.{ " Replace: ", s.replace.items[0..rc], "\u{258f}", s.replace.items[rc..] }) catch return;
            _ = ui.canvas.text(area.row(1), &.{.{ .text = l2, .style = ui.theme.panel_bg }}, .{});
            ui.hits.add(ui.arena, area.row(1), .{ .overlay_item = 1 }) catch {};
        }
    }
};

test "find bar: typing reports changed, enter submits, esc cancels" {
    const gpa = std.testing.allocator;
    var s: FindBar.State = .{};
    defer FindBar.deinit(&s, gpa);
    try std.testing.expectEqual(FindBar.Outcome.changed, try FindBar.handleKey(&s, gpa, Key.char('a')));
    try std.testing.expectEqual(FindBar.Outcome.changed, try FindBar.handleKey(&s, gpa, Key.named(.backspace)));
    try std.testing.expectEqual(FindBar.Outcome.submit, try FindBar.handleKey(&s, gpa, Key.named(.enter)));
    try std.testing.expectEqual(FindBar.Outcome.prev, try FindBar.handleKey(&s, gpa, .{ .code = .enter, .mods = .{ .shift = true } }));
    try std.testing.expectEqual(FindBar.Outcome.cancel, try FindBar.handleKey(&s, gpa, Key.named(.esc)));
    try std.testing.expectEqual(FindBar.Outcome.toggle_regex, try FindBar.handleKey(&s, gpa, Key.ctrl('r')));
    try std.testing.expect(s.regex);
}
