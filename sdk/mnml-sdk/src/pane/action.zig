//! The action button a row carries — `[ Triage ]`, `[ Review ]`,
//! `[ Merge ]` — and what happens to it after it is pressed.
//!
//! A press used to leave no mark: the line was written, the status said
//! so for a moment, and the button went back to looking un-pressed, so
//! there was no way to tell a row you had dispatched from one you had
//! not. A button now carries state, kept per row KEY (a ticket key, a
//! PR's `ws/repo#id`) rather than per row index, so it survives the
//! refetch that moves the row.
//!
//!   idle     `[ Triage ]`
//!   running  `[ ⠙ ]` — the dispatch is being written
//!   view     `[ view ]` — a session was started; pressing it asks the
//!            host to focus that session
//!   failed   `[ ✗ ]` in the bad colour, with the reason on the hint row
//!
//! What mnml does NOT tell a pane is when a session ENDS: the Bridge
//! carries input, resize and focus to a pane and nothing back about the
//! host's own state. So `running` is the window in which the pane is
//! writing the dispatch, and `view` means "a session was started for
//! this row and the host can be asked to bring it up" — not "it
//! finished". A live spinner for the length of a session needs a
//! host→pane session-state message, which does not exist yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const text_mod = @import("text.zig");

pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const width = text_mod.width;

pub const State = enum { idle, running, view, failed };

/// The braille spinner, one cell per frame. The ascii fallback is the
/// four-stroke one every terminal can draw.
pub const spinner_frames = [_][]const u8{ "\u{2807}", "\u{280B}", "\u{2819}", "\u{2838}", "\u{28B0}", "\u{28E0}", "\u{28C4}", "\u{2846}" };
pub const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };
pub const failed_glyph = "\u{2717}"; // ✗
pub const failed_ascii = "x";
pub const view_label = "view";

/// One frame of the spinner for `tick` — the pane's own counter, so
/// every button on screen turns together.
pub fn spinnerFrame(tick: usize, ascii: bool) []const u8 {
    if (ascii) return spinner_ascii[tick % spinner_ascii.len];
    return spinner_frames[tick % spinner_frames.len];
}

/// What one button says now. `label` is the row's own word when idle.
pub fn caption(buf: []u8, state: State, label: []const u8, tick: usize, ascii: bool) []const u8 {
    return switch (state) {
        .idle => std.fmt.bufPrint(buf, "[ {s} ]", .{label}) catch label,
        .running => std.fmt.bufPrint(buf, "[ {s} ]", .{spinnerFrame(tick, ascii)}) catch "[ ]",
        .view => std.fmt.bufPrint(buf, "[ {s} ]", .{view_label}) catch "[ view ]",
        .failed => std.fmt.bufPrint(buf, "[ {s} ]", .{if (ascii) failed_ascii else failed_glyph}) catch "[ x ]",
    };
}

/// The colour each state wears: a pressed button is the accent, a
/// failed one the bad colour, an untouched one an ordinary chip.
pub fn styleOf(th: Theme, state: State) Style {
    return switch (state) {
        .idle => th.chip(),
        .running, .view => th.chipActiveSoft(),
        .failed => .{ .fg = th.red, .bg = th.chip_bg },
    };
}

/// What a press means, given what the button says now.
pub const Press = enum { dispatch, focus_session, retry };

pub fn pressOf(state: State) Press {
    return switch (state) {
        .idle, .running => .dispatch,
        .view => .focus_session,
        .failed => .retry,
    };
}

// ─── the per-row store ───────────────────────────────────────────────────

/// What one press left behind on one row.
pub const Entry = struct {
    state: State = .idle,
    /// The session the dispatch started, as the host names it — what a
    /// `focus-session` line carries. Empty until one is known.
    session: []const u8 = "",
    /// The last line the dispatch printed when it failed, for the hint row.
    detail: []const u8 = "",
};

/// The buttons' state for a whole pane, keyed by `<row key>\\x00<action>`
/// so two actions on one row are two buttons and a refetch that moves
/// the row keeps both. Every string is owned here.
pub const Store = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.map.deinit(s.gpa);
        s.arena.deinit();
        s.* = undefined;
    }

    fn keyOf(s: *Store, row_key: []const u8, action: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(s.arena.allocator(), "{s}\u{0}{s}", .{ row_key, action });
    }

    pub fn get(s: *const Store, row_key: []const u8, action: []const u8) Entry {
        var buf: [320]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\u{0}{s}", .{ row_key, action }) catch return .{};
        return s.map.get(k) orelse .{};
    }

    pub fn state(s: *const Store, row_key: []const u8, action: []const u8) State {
        return s.get(row_key, action).state;
    }

    pub fn set(s: *Store, row_key: []const u8, action: []const u8, entry: Entry) Allocator.Error!void {
        const owned: Entry = .{
            .state = entry.state,
            .session = if (entry.session.len > 0) try s.arena.allocator().dupe(u8, entry.session) else "",
            .detail = if (entry.detail.len > 0) try s.arena.allocator().dupe(u8, entry.detail) else "",
        };
        const gop = try s.map.getOrPut(s.gpa, try s.keyOf(row_key, action));
        gop.value_ptr.* = owned;
    }

    /// Is anything still being dispatched? The pane's spinner only turns
    /// while this is true.
    pub fn anyRunning(s: *const Store) bool {
        var it = s.map.valueIterator();
        while (it.next()) |e| if (e.state == .running) return true;
        return false;
    }

    pub fn count(s: *const Store) usize {
        return s.map.count();
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a button says its word, then a spinner, then view, then a cross" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("[ Triage ]", caption(&buf, .idle, "Triage", 0, false));
    try testing.expectEqualStrings("[ \u{2807} ]", caption(&buf, .running, "Triage", 0, false));
    try testing.expectEqualStrings("[ \u{280B} ]", caption(&buf, .running, "Triage", 1, false));
    try testing.expectEqualStrings("[ view ]", caption(&buf, .view, "Triage", 0, false));
    try testing.expectEqualStrings("[ \u{2717} ]", caption(&buf, .failed, "Triage", 0, false));
    // ascii: the four-stroke spinner and an x.
    try testing.expectEqualStrings("[ / ]", caption(&buf, .running, "Triage", 1, true));
    try testing.expectEqualStrings("[ x ]", caption(&buf, .failed, "Triage", 0, true));
    // Every state's caption is one cell wider than its inside, and a
    // spinner never changes the button's width as it turns.
    const w0 = width(caption(&buf, .running, "Triage", 0, false));
    var i: usize = 1;
    while (i < spinner_frames.len) : (i += 1) {
        try testing.expectEqual(w0, width(caption(&buf, .running, "Triage", i, false)));
    }
}

test "what a press means follows what the button says" {
    try testing.expectEqual(Press.dispatch, pressOf(.idle));
    try testing.expectEqual(Press.dispatch, pressOf(.running));
    try testing.expectEqual(Press.focus_session, pressOf(.view));
    try testing.expectEqual(Press.retry, pressOf(.failed));
}

test "the store is keyed by the row's key, so a refetch that moves the row keeps its buttons" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(State.idle, s.state("ENG-2", "triage"));
    try s.set("ENG-2", "triage", .{ .state = .running });
    try s.set("ENG-2", "fix", .{ .state = .failed, .detail = "no .claude/ under the dispatch workspace" });
    try s.set("ENG-9", "triage", .{ .state = .view, .session = "abc-123" });
    // Two actions on one row are two buttons.
    try testing.expectEqual(State.running, s.state("ENG-2", "triage"));
    try testing.expectEqual(State.failed, s.state("ENG-2", "fix"));
    try testing.expectEqualStrings("no .claude/ under the dispatch workspace", s.get("ENG-2", "fix").detail);
    // A different row's is its own.
    try testing.expectEqualStrings("abc-123", s.get("ENG-9", "triage").session);
    try testing.expectEqual(State.idle, s.state("ENG-9", "fix"));
    try testing.expect(s.anyRunning());
    try s.set("ENG-2", "triage", .{ .state = .view, .session = "def-456" });
    try testing.expect(!s.anyRunning());
    try testing.expectEqual(@as(usize, 3), s.count());
    // Setting the same button again replaces it rather than doubling it.
    try s.set("ENG-2", "triage", .{ .state = .idle });
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expectEqualStrings("", s.get("ENG-2", "triage").session);
}
