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
//!   running  `[ ⠙ ]` — the session is running (a turning spinner)
//!   waiting  `[ ⏸ ]` — it stopped to ask the user something
//!   view     `[ view ]` — it finished; pressing it brings it up
//!   failed   `[ ✗ ]` in the bad colour, with the last line it
//!            printed on the hint row
//!
//! The four after `idle` are the host's word, not a guess. A press
//! writes the dispatch and the pane sends `watch_session` over the
//! mount naming the row's button; the host matches the session the
//! same way `focus-session` does (its own id, else the working
//! directory and the prompt's first line) and sends a `session_state`
//! line on every edge. So the spinner turns for as long as the session
//! actually runs, `[ view ]` means finished rather than started, and a
//! session that stops to ask something says so instead of looking
//! busy. Until the first line lands a fresh dispatch reads `running`,
//! which is what it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("../frame.zig");
const wire = @import("../wire.zig");
const theme_mod = @import("theme.zig");
const text_mod = @import("text.zig");

pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const width = text_mod.width;

pub const State = enum { idle, running, waiting, view, failed };

/// The host's word for a session, as the button wears it. `done` is
/// `view` on purpose: a finished session is one you go and read.
pub fn fromSessionState(s: wire.SessionState) State {
    return switch (s) {
        .running => .running,
        .waiting => .waiting,
        .done => .view,
        .failed => .failed,
    };
}

/// The braille spinner, one cell per frame. The ascii fallback is the
/// four-stroke one every terminal can draw.
pub const spinner_frames = [_][]const u8{ "\u{2807}", "\u{280B}", "\u{2819}", "\u{2838}", "\u{28B0}", "\u{28E0}", "\u{28C4}", "\u{2846}" };
pub const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };
pub const failed_glyph = "\u{2717}"; // ✗
pub const failed_ascii = "x";
pub const waiting_glyph = "\u{23F8}"; // ⏸
/// mnml's own `⚠ wait` badge falls back to `!`; a button says the same
/// thing in one cell.
pub const waiting_ascii = "!";
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
        .waiting => std.fmt.bufPrint(buf, "[ {s} ]", .{if (ascii) waiting_ascii else waiting_glyph}) catch "[ ! ]",
        .view => std.fmt.bufPrint(buf, "[ {s} ]", .{view_label}) catch "[ view ]",
        .failed => std.fmt.bufPrint(buf, "[ {s} ]", .{if (ascii) failed_ascii else failed_glyph}) catch "[ x ]",
    };
}

// ─── what a button does, and the colour that says so ─────────────────────

/// What pressing a button COSTS, which is what decides its colour.
/// Every button used to paint in one grey chip, so `[ Open ]` — which
/// goes somewhere and changes nothing — looked exactly like
/// `[ Merge ]`, which is the one press in either pane you cannot take
/// back. The word is all a reader has; the colour now says which
/// family the word is in.
pub const Kind = enum {
    /// Goes somewhere and changes nothing: `Open`, and the `[ view ]`
    /// a finished session leaves behind.
    navigation,
    /// Starts a session that READS and reports: `Review`, `Test`.
    review,
    /// Starts a session that WRITES: `Implement`, `Fix`, `Triage`.
    dispatch,
    /// The last one, and the irreversible one: `Merge`, `Decline`.
    final,
};

/// The kind a button's word belongs to. The word is matched without
/// its brackets or its spaces, so a caller may pass either `Merge` or
/// `[ Merge ]`.
///
/// A word nobody has classified is `dispatch`: that is the family
/// that grows (a pane adds an action long before it adds a way to
/// navigate), and a new action painted in the pane's own colour reads
/// as this app's doing rather than as a link or as something final.
pub fn kindOf(word: []const u8) Kind {
    const w = std.mem.trim(u8, word, "[] ");
    if (std.ascii.eqlIgnoreCase(w, "open") or std.ascii.eqlIgnoreCase(w, view_label)) return .navigation;
    if (std.ascii.eqlIgnoreCase(w, "review") or std.ascii.eqlIgnoreCase(w, "test")) return .review;
    if (std.ascii.eqlIgnoreCase(w, "merge") or std.ascii.eqlIgnoreCase(w, "decline")) return .final;
    return .dispatch;
}

/// The host theme role each kind paints in. Never a literal: a pane
/// that hard-codes blue picks the terminal's blue and ignores the
/// theme it is mounted in.
pub fn roleColor(th: Theme, kind: Kind) theme_mod.Color {
    return switch (kind) {
        .navigation => th.muted,
        .review => th.blue,
        .dispatch => dispatchColor(th),
        .final => th.green,
    };
}

/// A dispatch button wears the pane's OWN colour: that is the app
/// saying it is about to go and do something.
///
/// Two of the five official manifests name a chip colour that is
/// already spoken for, though — Jira Work's is blue, which is
/// `review`; Jira Fix Versions' is green, which is `final` — and a
/// `[ Triage ]` painted exactly like the `[ Review ]` two rows above
/// it, or exactly like a ready `[ Merge ]`, is the one thing this
/// whole map exists to prevent. So the brand is used when it is free
/// and the next colour on a fixed ladder when it is not.
fn dispatchColor(th: Theme) theme_mod.Color {
    const taken = [_]theme_mod.Color{ th.blue, th.green };
    const ladder = [_]theme_mod.Color{ th.brand, th.purple, th.orange, th.cyan };
    for (ladder) |c| {
        var free = true;
        for (taken) |t| {
            if (sameColor(c, t)) free = false;
        }
        if (free) return c;
    }
    return th.brand;
}

fn sameColor(a: theme_mod.Color, b: theme_mod.Color) bool {
    return switch (a) {
        .index => |i| b == .index and b.index == i,
        .rgb => |v| b == .rgb and std.mem.eql(u8, &v, &b.rgb),
    };
}

/// The two styles one button is painted in. The brackets are
/// punctuation and stay muted; the word carries the colour. Splitting
/// them is what keeps a row of three buttons from reading as three
/// coloured blocks — the eye lands on the words, which is where the
/// meaning is.
pub const Chip = struct {
    bracket: Style,
    word: Style,

    /// The one style a caller with nowhere to put two of them uses.
    pub fn flat(c: Chip) Style {
        return c.word;
    }
};

/// What one button is painted in, given what it says and what it does.
/// A state past `idle` is the host's word about a session and outranks
/// the kind — a spinner is a spinner whichever button started it.
pub fn chipOf(th: Theme, state: State, kind: Kind) Chip {
    const punctuation: Style = .{ .fg = th.muted };
    return switch (state) {
        .idle => .{ .bracket = punctuation, .word = .{ .fg = roleColor(th, kind), .mods = .{ .bold = true } } },
        // A session that is running, or one you can go and read, wears
        // the plain foreground: it is no longer offering to do the
        // thing its word named.
        .running, .view => .{ .bracket = punctuation, .word = .{ .fg = th.fg } },
        // Waiting on the user is not an error and not progress: the
        // warning colour, the same one the SESSIONS panel's `wait`
        // badge wears.
        .waiting => .{ .bracket = punctuation, .word = .{ .fg = th.yellow } },
        .failed => .{ .bracket = punctuation, .word = .{ .fg = th.red } },
    };
}

/// The colour each state wears, for a caller that paints the caption in
/// one style. `kind` decides an `idle` button; the rest are the
/// session's.
pub fn styleOf(th: Theme, state: State, kind: Kind) Style {
    return chipOf(th, state, kind).flat();
}

/// What a press means, given what the button says now.
pub const Press = enum { dispatch, focus_session, retry };

pub fn pressOf(state: State) Press {
    return switch (state) {
        .idle => .dispatch,
        // A session that is running, or stopped to ask something, is
        // brought up rather than started again — pressing it a second
        // time must never fork a duplicate.
        .running, .waiting, .view => .focus_session,
        .failed => .retry,
    };
}

// ─── the per-row store ───────────────────────────────────────────────────

/// What one press left behind on one row.
pub const Entry = struct {
    state: State = .idle,
    /// The session the dispatch started, as the host names it — what a
    /// `focus-session` line carries. Empty until the host has matched
    /// one and said so.
    session: []const u8 = "",
    /// The first line of the prompt the dispatch was started with. The
    /// only name a dispatched `term` line can carry, so it is how both
    /// `watch-session` and `focus-session` find the session again when
    /// there is no id yet.
    prompt_line: []const u8 = "",
    /// The last line the session printed, or why the dispatch failed —
    /// what the hint row shows under a `✗`.
    detail: []const u8 = "",
};

/// The separator inside the `key` a `watch_session` carries: one
/// string on the wire, a row key and an action this side. A unit
/// separator rather than a punctuation mark because a row key is a
/// ticket key or a `ws/repo#id` and must never be able to collide
/// with it.
pub const key_sep = "\x1f";

/// `<row key><US><action>` — the name a pane gives one button on the
/// wire. Written into `buf`; a pair too long for it is truncated
/// rather than wrong, and simply never matches.
pub fn watchKey(buf: []u8, row_key: []const u8, action: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}" ++ key_sep ++ "{s}", .{ row_key, action }) catch buf[0..0];
}

/// The pair back out of a `watch_session` key; null when it is not one.
pub fn splitWatchKey(key: []const u8) ?struct { row: []const u8, action: []const u8 } {
    const at = std.mem.indexOfScalar(u8, key, key_sep[0]) orelse return null;
    return .{ .row = key[0..at], .action = key[at + 1 ..] };
}

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
            .prompt_line = if (entry.prompt_line.len > 0) try s.arena.allocator().dupe(u8, entry.prompt_line) else "",
            .detail = if (entry.detail.len > 0) try s.arena.allocator().dupe(u8, entry.detail) else "",
        };
        const gop = try s.map.getOrPut(s.gpa, try s.keyOf(row_key, action));
        gop.value_ptr.* = owned;
    }

    /// A `session_state` line from the host: the button the `key`
    /// names takes the host's word for what its session is doing, and
    /// keeps everything the press itself left (the prompt line it is
    /// matched by). A key for a button this pane does not know is
    /// ignored — a stale line from a session started before a refetch
    /// must not conjure a row.
    ///
    /// Returns false when the key was not one of this pane's.
    pub fn applyState(s: *Store, key: []const u8, to: State, session: []const u8, detail: []const u8) Allocator.Error!bool {
        const pair = splitWatchKey(key) orelse return false;
        const had = s.get(pair.row, pair.action);
        if (had.state == .idle and had.prompt_line.len == 0 and had.session.len == 0) return false;
        try s.set(pair.row, pair.action, .{
            .state = to,
            .session = if (session.len > 0) session else had.session,
            .prompt_line = had.prompt_line,
            // A state that carries no line keeps the one it had, so a
            // failure's reason does not vanish on the next edge.
            .detail = if (detail.len > 0) detail else had.detail,
        });
        return true;
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
    try testing.expectEqualStrings("[ ⏸ ]", caption(&buf, .waiting, "Triage", 0, false));
    try testing.expectEqualStrings("[ view ]", caption(&buf, .view, "Triage", 0, false));
    try testing.expectEqualStrings("[ \u{2717} ]", caption(&buf, .failed, "Triage", 0, false));
    // ascii: the four-stroke spinner and an x.
    try testing.expectEqualStrings("[ / ]", caption(&buf, .running, "Triage", 1, true));
    try testing.expectEqualStrings("[ x ]", caption(&buf, .failed, "Triage", 0, true));
    try testing.expectEqualStrings("[ ! ]", caption(&buf, .waiting, "Triage", 0, true));
    // Every state's caption is one cell wider than its inside, and a
    // spinner never changes the button's width as it turns.
    const w0 = width(caption(&buf, .running, "Triage", 0, false));
    var i: usize = 1;
    while (i < spinner_frames.len) : (i += 1) {
        try testing.expectEqual(w0, width(caption(&buf, .running, "Triage", i, false)));
    }
}

test "a button's colour says what pressing it costs, and no two families collide" {
    // A theme where every role is its own colour, so a role swapped
    // for another shows up rather than hiding behind a shared default.
    const th = Theme.fromHelloBranded(.{
        .fg = .{ .rgb = .{ 200, 200, 200 } },
        .muted = .{ .rgb = .{ 90, 90, 90 } },
        .blue = .{ .rgb = .{ 97, 175, 239 } },
        .green = .{ .rgb = .{ 152, 195, 121 } },
        .purple = .{ .rgb = .{ 198, 120, 221 } },
        .orange = .{ .rgb = .{ 209, 154, 102 } },
        .cyan = .{ .rgb = .{ 86, 182, 194 } },
        .accent = .{ .rgb = .{ 97, 175, 239 } },
    }, "magenta");

    // The word decides the family, with or without its brackets.
    try testing.expectEqual(Kind.navigation, kindOf("Open"));
    try testing.expectEqual(Kind.navigation, kindOf("[ Open ]"));
    try testing.expectEqual(Kind.navigation, kindOf("view"));
    try testing.expectEqual(Kind.review, kindOf("Review"));
    try testing.expectEqual(Kind.review, kindOf("[ Test ]"));
    try testing.expectEqual(Kind.dispatch, kindOf("Triage"));
    try testing.expectEqual(Kind.dispatch, kindOf("Implement"));
    try testing.expectEqual(Kind.dispatch, kindOf("Fix"));
    try testing.expectEqual(Kind.final, kindOf("Merge"));
    try testing.expectEqual(Kind.final, kindOf("Decline"));
    // A word nobody has classified is a dispatch: that is the family
    // that grows, and the pane's own colour is the safe thing to say.
    try testing.expectEqual(Kind.dispatch, kindOf("Backport"));

    // Four families, four colours, all four different.
    const roles = [_]theme_mod.Color{
        roleColor(th, .navigation),
        roleColor(th, .review),
        roleColor(th, .dispatch),
        roleColor(th, .final),
    };
    for (roles, 0..) |a, i| for (roles[0..i]) |b| try testing.expect(!sameColor(a, b));
    try testing.expectEqual(th.muted, roles[0]);
    try testing.expectEqual(th.blue, roles[1]);
    // The brand is free here, so a dispatch wears it.
    try testing.expectEqual(th.purple, roles[2]);
    try testing.expectEqual(th.green, roles[3]);

    // The brackets are punctuation and stay muted; the word carries
    // the colour, and neither names a ground — a button on the
    // cursor's row must keep that row's fill, not punch a hole in it.
    const c = chipOf(th, .idle, .review);
    try testing.expectEqual(th.muted, c.bracket.fg.?);
    try testing.expectEqual(th.blue, c.word.fg.?);
    try testing.expect(c.bracket.bg == null and c.word.bg == null);
}

test "a brand already spoken for steps down the ladder rather than repeating a role" {
    // Jira Work's manifest chip is blue, which is `review`.
    const work = Theme.fromHelloBranded(.{
        .blue = .{ .rgb = .{ 97, 175, 239 } },
        .green = .{ .rgb = .{ 152, 195, 121 } },
        .purple = .{ .rgb = .{ 198, 120, 221 } },
        .orange = .{ .rgb = .{ 209, 154, 102 } },
        .cyan = .{ .rgb = .{ 86, 182, 194 } },
    }, "blue");
    try testing.expect(sameColor(work.brand, work.blue));
    try testing.expectEqual(work.purple, roleColor(work, .dispatch));

    // Jira Fix Versions' is green, which is `final` — a `[ Triage ]`
    // that paints like a ready `[ Merge ]` is worse than a grey one.
    const fixv = Theme.fromHelloBranded(.{
        .blue = .{ .rgb = .{ 97, 175, 239 } },
        .green = .{ .rgb = .{ 152, 195, 121 } },
        .purple = .{ .rgb = .{ 198, 120, 221 } },
        .orange = .{ .rgb = .{ 209, 154, 102 } },
        .cyan = .{ .rgb = .{ 86, 182, 194 } },
    }, "green");
    try testing.expect(sameColor(fixv.brand, fixv.green));
    try testing.expectEqual(fixv.purple, roleColor(fixv, .dispatch));

    // A theme whose purple is its blue again keeps stepping.
    const odd = Theme.fromHelloBranded(.{
        .blue = .{ .rgb = .{ 1, 1, 1 } },
        .green = .{ .rgb = .{ 2, 2, 2 } },
        .purple = .{ .rgb = .{ 1, 1, 1 } },
        .orange = .{ .rgb = .{ 3, 3, 3 } },
        .cyan = .{ .rgb = .{ 4, 4, 4 } },
    }, "green");
    try testing.expectEqual(odd.orange, roleColor(odd, .dispatch));
}

test "a session's state outranks the button's family, and the state colours are unchanged" {
    const th = Theme.fromHelloBranded(.{
        .fg = .{ .rgb = .{ 200, 200, 200 } },
        .muted = .{ .rgb = .{ 90, 90, 90 } },
        .blue = .{ .rgb = .{ 97, 175, 239 } },
        .green = .{ .rgb = .{ 152, 195, 121 } },
        .yellow = .{ .rgb = .{ 229, 192, 123 } },
        .red = .{ .rgb = .{ 224, 108, 117 } },
        .purple = .{ .rgb = .{ 198, 120, 221 } },
    }, "magenta");
    // A spinner is a spinner whichever button started it: the four
    // kinds agree on every state past `idle`.
    for ([_]State{ .running, .waiting, .view, .failed }) |st| {
        const a = chipOf(th, st, .navigation);
        for ([_]Kind{ .review, .dispatch, .final }) |k| {
            const b = chipOf(th, st, k);
            try testing.expectEqual(a.word.fg, b.word.fg);
        }
    }
    try testing.expectEqual(th.yellow, chipOf(th, .waiting, .final).word.fg.?);
    try testing.expectEqual(th.red, chipOf(th, .failed, .final).word.fg.?);
    try testing.expectEqual(th.fg.?, chipOf(th, .view, .final).word.fg.?);
    // …and an idle one does not: that is the whole point.
    try testing.expect(!sameColor(chipOf(th, .idle, .navigation).word.fg.?, chipOf(th, .idle, .final).word.fg.?));
}

test "what a press means follows what the button says" {
    try testing.expectEqual(Press.dispatch, pressOf(.idle));
    // Only an untouched button starts anything: a session that is
    // running or waiting is brought up, never forked.
    try testing.expectEqual(Press.focus_session, pressOf(.running));
    try testing.expectEqual(Press.focus_session, pressOf(.waiting));
    try testing.expectEqual(Press.focus_session, pressOf(.view));
    try testing.expectEqual(Press.retry, pressOf(.failed));
}

test "a watch key carries the row and the action and comes back as the pair" {
    var buf: [64]u8 = undefined;
    const k = watchKey(&buf, "acme/api#1234", "merge");
    try testing.expectEqualStrings("acme/api#1234" ++ key_sep ++ "merge", k);
    const pair = splitWatchKey(k).?;
    try testing.expectEqualStrings("acme/api#1234", pair.row);
    try testing.expectEqualStrings("merge", pair.action);
    // A key that is not a pair is not one — it must not half-match.
    try testing.expect(splitWatchKey("no-separator-here") == null);
    // The separator cannot occur in a row key or an action, so the
    // split is the one the pane meant.
    try testing.expectEqualStrings("", splitWatchKey(key_sep ++ "triage").?.row);
}

test "a session_state line moves the button the key names, and nothing else" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    var buf: [64]u8 = undefined;
    // A key for a button nobody pressed is ignored: a line that
    // arrives after a refetch must not conjure a row.
    try testing.expect(!try s.applyState(watchKey(&buf, "ENG-2", "triage"), fromSessionState(.running), "", ""));
    try testing.expectEqual(State.idle, s.state("ENG-2", "triage"));

    try s.set("ENG-2", "triage", .{ .state = .running, .prompt_line = "/agents:developer ENG-2" });
    try testing.expect(try s.applyState(watchKey(&buf, "ENG-2", "triage"), fromSessionState(.waiting), "abc-123", "Do you want to proceed?"));
    const waiting = s.get("ENG-2", "triage");
    try testing.expectEqual(State.waiting, waiting.state);
    try testing.expectEqualStrings("abc-123", waiting.session);
    // The press's own name for the session survives every edge — it is
    // how the host finds it again when it never gave an id.
    try testing.expectEqualStrings("/agents:developer ENG-2", waiting.prompt_line);
    try testing.expectEqualStrings("Do you want to proceed?", waiting.detail);
    // An edge with no line of its own keeps the last one rather than
    // blanking the hint row.
    try testing.expect(try s.applyState(watchKey(&buf, "ENG-2", "triage"), fromSessionState(.done), "", ""));
    const done = s.get("ENG-2", "triage");
    // A session that ENDED is one to go and read: `done` is `[ view ]`.
    try testing.expectEqual(State.view, done.state);
    try testing.expectEqualStrings("abc-123", done.session);
    try testing.expectEqualStrings("Do you want to proceed?", done.detail);
    // A bad key is refused rather than silently landing somewhere.
    try testing.expect(!try s.applyState("ENG-2", .failed, "", ""));
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
