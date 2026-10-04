//! Ghost text you can watch. The suggestion machinery is
//! `app/ai.zig` + `ai/suggest.zig`; this file is the part that says
//! what it is doing, because until now it said nothing at all: with the
//! `claude-code` backend one suggestion is a whole `claude -p` run, so
//! the typist paused, waited seconds, saw no ghost, and had no way to
//! tell a backend that is working from one that is broken.
//!
//! Three surfaces, one state:
//!
//!   - the statusline chip (`Phase` → `chipText`), in the AI segment
//!     area beside the Claude and Codex meters. Idle paints nothing and
//!     so does a suggestion that is showing — the ghost text is its own
//!     state; the chip is only for the moments with nothing to look at.
//!   - one line per request in `:messages` (`logLine`), which is where
//!     the latency and the reason an answer never came are readable
//!     after the fact.
//!   - `status.json`'s `"ghost"` (`Phase.wire`), so a `.test` can watch
//!     a request go out and land without a screen assertion.
//!
//! `State` here holds only what observation needs. The counters a
//! suggestion is judged by (`shown` / `accepted`) stay in `ai.State`,
//! and `statsLine` reads both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const suggest = @import("../ai/suggest.zig");
const list_panel = @import("../ui/list_panel.zig");
const clip = @import("../ui/clip.zig");
const sl = @import("../ui/statusline.zig");
const tooltip = @import("../ui/tooltip.zig");

/// `∅` and `!` outlive the request that produced them, so a result
/// that lands between two keystrokes is still something the eye — and
/// a `.test` polling `status.json` — can catch.
pub const empty_hold_ms: i64 = 2000;
pub const error_hold_ms: i64 = 5000;

/// How many outcomes `ai.suggestion_stats` reads back.
pub const recent_cap: usize = 5;

/// What the chip is showing. The wire words are `status.json`'s.
pub const Phase = enum {
    /// Nothing is pending and nothing is showing: no chip.
    idle,
    /// The debounce is armed — an edit landed, the request has not.
    armed,
    /// A request is out.
    inflight,
    /// A suggestion is on screen. No chip: the ghost text is the state.
    shown,
    /// The last request came back with nothing to suggest.
    empty,
    /// The last request failed, timed out, or could not be run.
    err,

    pub fn wire(p: Phase) []const u8 {
        return switch (p) {
            .idle => "idle",
            .armed => "armed",
            .inflight => "inflight",
            .shown => "shown",
            .empty => "empty",
            .err => "error",
        };
    }
};

/// How one request ended. `cancelled` is the user typing through it.
pub const Outcome = enum {
    shown,
    empty,
    failed,
    timeout,
    cancelled,
    /// The answer came back for a cursor that has since moved (no edit,
    /// so nothing cancelled the flight): dropped, never painted there.
    stale,

    pub fn word(o: Outcome) []const u8 {
        return switch (o) {
            .shown => "ok",
            .empty => "empty",
            .failed => "error",
            .timeout => "timeout",
            .cancelled => "cancelled",
            .stale => "stale",
        };
    }
};

pub const State = struct {
    /// Every settled request's latency, for the mean.
    latency_total_ms: u64 = 0,
    latency_n: u32 = 0,
    last_latency_ms: ?i64 = null,
    /// The last `recent_cap` outcomes, oldest first.
    recent: [recent_cap]Outcome = undefined,
    recent_len: usize = 0,
    /// `App.now_ms` the `∅` / `!` chip stays up until.
    empty_until_ms: i64 = 0,
    error_until_ms: i64 = 0,
    /// The last failure's words, for the hover copy. Owned.
    last_error: ?[]u8 = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.last_error) |e| gpa.free(e);
        self.last_error = null;
    }

    /// Record a settled request. `now_ms` sets how long the chip holds.
    pub fn note(self: *State, outcome: Outcome, latency_ms: i64, now_ms: i64) void {
        const ms = @max(latency_ms, 0);
        self.last_latency_ms = ms;
        self.latency_total_ms += @intCast(ms);
        self.latency_n +|= 1;
        if (self.recent_len < recent_cap) {
            self.recent[self.recent_len] = outcome;
            self.recent_len += 1;
        } else {
            std.mem.copyForwards(Outcome, self.recent[0 .. recent_cap - 1], self.recent[1..recent_cap]);
            self.recent[recent_cap - 1] = outcome;
        }
        switch (outcome) {
            .empty => self.empty_until_ms = now_ms + empty_hold_ms,
            .failed, .timeout => self.error_until_ms = now_ms + error_hold_ms,
            // A suggestion or a cancel replaces whatever was held: the
            // chip must never show `!` over a ghost that just landed.
            .shown, .cancelled, .stale => {
                self.empty_until_ms = 0;
                self.error_until_ms = 0;
            },
        }
    }

    /// A request is going out — whatever the last one left up, goes.
    pub fn clearHolds(self: *State) void {
        self.empty_until_ms = 0;
        self.error_until_ms = 0;
    }

    pub fn meanMs(self: *const State) ?i64 {
        if (self.latency_n == 0) return null;
        return @intCast(self.latency_total_ms / self.latency_n);
    }

    pub fn setError(self: *State, gpa: Allocator, msg: []const u8) void {
        const copy = gpa.dupe(u8, msg[0..@min(msg.len, 200)]) catch return;
        if (self.last_error) |e| gpa.free(e);
        self.last_error = copy;
    }
};

/// Everything `phaseOf` needs, so the state machine is testable
/// without an `App`.
pub const Sample = struct {
    /// `[ai] inline_suggestions` is on and a backend is picked.
    enabled: bool = true,
    in_flight: bool = false,
    armed: bool = false,
    ghost_showing: bool = false,
    now_ms: i64 = 0,
};

/// The one place the chip, the hover copy and `status.json` agree.
///
/// Order is the point: a request that is out outranks the `∅` its
/// predecessor left up, a held `!` outranks a held `∅` (the worse news
/// wins), and a ghost on screen outranks the clock still being armed —
/// an accept re-arms it, and the chip must not blink `…` over a
/// suggestion the user is reading.
pub fn phaseOf(st: *const State, s: Sample) Phase {
    if (!s.enabled) return .idle;
    if (s.in_flight) return .inflight;
    if (s.now_ms < st.error_until_ms) return .err;
    if (s.now_ms < st.empty_until_ms) return .empty;
    if (s.ghost_showing) return .shown;
    if (s.armed) return .armed;
    return .idle;
}

/// The chip's text, already padded the way a `Seg` wants it, or null
/// when this phase paints nothing.
pub fn chipText(arena: Allocator, ph: Phase, elapsed_ms: i64, now_ms: i64, ascii: bool) Allocator.Error!?[]const u8 {
    const mark = if (ascii) sl.ghost_ascii else sl.ghost_glyph;
    return switch (ph) {
        .idle, .shown => null,
        .armed => try std.fmt.allocPrint(arena, " {s} {s} ", .{ mark, clip.ellipsisText(ascii) }),
        .inflight => try std.fmt.allocPrint(arena, " {s} {s} {s} ", .{
            mark,
            list_panel.spinnerFrame(now_ms, ascii),
            try secsAlloc(arena, elapsed_ms),
        }),
        .empty => try std.fmt.allocPrint(arena, " {s} {s} ", .{ mark, if (ascii) "0" else "∅" }),
        .err => try std.fmt.allocPrint(arena, " {s} ! ", .{mark}),
    };
}

/// `2.3s` — one decimal, which is the resolution a person reads a wait at.
pub fn secsAlloc(arena: Allocator, ms: i64) Allocator.Error![]u8 {
    const v = @max(ms, 0);
    return std.fmt.allocPrint(arena, "{d}.{d}s", .{ @divFloor(v, 1000), @divFloor(@mod(v, 1000), 100) });
}

/// The `:messages` line for one settled request:
///
///   ghost-text: claude-code · 2.3s · 41 chars
///   ghost-text: claude-code · 0.9s · empty
///   ghost-text: claude-code · 1.2s · error: claude -p: not signed in
///   ghost-text: claude-code · 4.0s · timeout
///   ghost-text: claude-code · 0.4s · cancelled (typed)
pub fn logLine(
    arena: Allocator,
    backend: suggest.Backend,
    outcome: Outcome,
    latency_ms: i64,
    chars: usize,
    detail: ?[]const u8,
) Allocator.Error![]u8 {
    const head = try std.fmt.allocPrint(arena, "ghost-text: {s} · {s} · ", .{ backend.token(), try secsAlloc(arena, latency_ms) });
    return switch (outcome) {
        .shown => std.fmt.allocPrint(arena, "{s}{d} chars", .{ head, chars }),
        .empty => std.fmt.allocPrint(arena, "{s}empty", .{head}),
        .timeout => std.fmt.allocPrint(arena, "{s}timeout", .{head}),
        .cancelled => std.fmt.allocPrint(arena, "{s}cancelled (typed)", .{head}),
        .stale => std.fmt.allocPrint(arena, "{s}dropped (cursor moved)", .{head}),
        .failed => std.fmt.allocPrint(arena, "{s}error: {s}", .{ head, trimPrefix(detail orelse "the request failed") }),
    };
}

/// The worker's messages already say `ghost-text:`; the log line adds
/// its own, so the prefix comes off rather than reading twice.
fn trimPrefix(msg: []const u8) []const u8 {
    const p = "ghost-text: ";
    return if (std.mem.startsWith(u8, msg, p)) msg[p.len..] else msg;
}

/// `ai.suggestion_stats`'s toast: the accept rate it always had, plus
/// the mean latency and the last five outcomes — the two numbers that
/// answer "is this thing working".
pub fn statsLine(arena: Allocator, st: *const State, shown: u32, accepted: u32) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const pct: u32 = if (shown == 0) 0 else @intCast(@min(accepted * 100 / shown, 100));
    try out.print(arena, "AI ghost-text: {d} of {d} accepted ({d}%)", .{ accepted, shown, pct });
    if (st.meanMs()) |m| try out.print(arena, " · mean {s}", .{try secsAlloc(arena, m)});
    if (st.recent_len > 0) {
        try out.appendSlice(arena, " · last:");
        for (st.recent[0..st.recent_len], 0..) |o, i| {
            try out.print(arena, "{s} {s}", .{ if (i == 0) "" else ",", o.word() });
        }
    }
    return out.toOwnedSlice(arena);
}

/// The chip's hover title — what it is doing, in words.
pub fn hoverTitle(ph: Phase) []const u8 {
    return switch (ph) {
        .idle => "AI ghost-text",
        .armed => "AI ghost-text — about to ask",
        .inflight => "AI ghost-text — asking",
        .shown => "AI ghost-text — a suggestion is showing",
        .empty => "AI ghost-text — nothing to suggest",
        .err => "AI ghost-text — the last request failed",
    };
}

/// The chip's hover detail: which backend answers, how long the last
/// one took, and what a click does — the three things the chip itself
/// has no room for.
pub fn hoverDetail(arena: Allocator, st: *const State, backend: suggest.Backend, ph: Phase) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, backend.label());
    if (ph == .err) {
        if (st.last_error) |e| try out.print(arena, " · {s}", .{trimPrefix(e)});
    }
    if (st.last_latency_ms) |ms| try out.print(arena, " · last {s}", .{try secsAlloc(arena, ms)});
    if (st.meanMs()) |ms| try out.print(arena, " · mean {s}", .{try secsAlloc(arena, ms)});
    try out.appendSlice(arena, " · click: pick the backend · right-click: the ghost-text menu");
    return out.toOwnedSlice(arena);
}

/// The chip's `Tip`, for `app/discovery.zig`.
pub fn tip(app: *App, arena: Allocator) Allocator.Error!tooltip.Tip {
    const ph = phase(app);
    return .{
        .title = hoverTitle(ph),
        .detail = try hoverDetail(arena, &app.ai.ghost, @import("ai.zig").suggestBackend(app), ph),
    };
}

/// The chip's right-click: the two commands that answer "why is this
/// not working" — the backend picker and the session's own numbers —
/// plus the switch itself.
pub fn openMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try @import("context_menus.zig").items(app, &.{
        .{ .label = "Pick the backend…", .action = .{ .command = .@"ai.setup_suggestions" } },
        .{ .label = "Suggestion stats", .action = .{ .command = .@"ai.suggestion_stats" } },
        .{ .label = "Show messages", .action = .{ .command = .@"messages.show" } },
        .{ .label = "Turn ghost text off", .action = .{ .command = .@"ai.toggle_inline_suggestions" }, .checked = app.cfg.ai.inline_suggestions, .separator_before = true },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("AI ghost-text", rows, x, y);
}

// ─── the App's view ─────────────────────────────────────────────────────

/// The live `Sample` — the one place the app's scattered flags become
/// the chip's state.
pub fn sample(app: *App) Sample {
    const ai = @import("ai.zig");
    const enabled = app.cfg.ai.inline_suggestions and ai.suggestBackend(app) != .unset;
    const ghost_showing = if (app.activeEditor()) |e| e.buf.editor.ghost_suggestion != null else false;
    return .{
        .enabled = enabled,
        .in_flight = app.ai.debounce.in_flight != null,
        .armed = app.ai.debounce.dirty_ms != null,
        .ghost_showing = ghost_showing,
        .now_ms = app.now_ms,
    };
}

pub fn phase(app: *App) Phase {
    return phaseOf(&app.ai.ghost, sample(app));
}

/// How long the in-flight request has been out, for the chip.
pub fn elapsedMs(app: *const App) i64 {
    if (app.ai.debounce.in_flight == null) return 0;
    return @max(app.now_ms - app.ai.debounce.fired_ms, 0);
}

/// One settled request, everywhere at once: the counters, the chip's
/// hold, and the `:messages` line. `detail` is the failure's words.
pub fn settle(app: *App, outcome: Outcome, chars: usize, detail: ?[]const u8) Allocator.Error!void {
    const st = &app.ai.ghost;
    const latency = @max(app.now_ms - app.ai.debounce.fired_ms, 0);
    st.note(outcome, latency, app.now_ms);
    if (detail) |d| st.setError(app.gpa, d);
    const line = try logLine(app.frame.allocator(), @import("ai.zig").suggestBackend(app), outcome, latency, chars, detail);
    // Recorded, not toasted: one toast per keystroke-pause would be
    // the opposite of the quiet the feature is supposed to have.
    try app.messages.record(app.gpa, line, if (outcome == .failed or outcome == .timeout) .warn else .info, app.now_ms);
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "phase: the order that decides what the chip says" {
    var st: State = .{};
    // Nothing set up: never a chip, whatever else is true.
    try t.expectEqual(Phase.idle, phaseOf(&st, .{ .enabled = false, .in_flight = true, .armed = true }));
    try t.expectEqual(Phase.idle, phaseOf(&st, .{}));
    try t.expectEqual(Phase.armed, phaseOf(&st, .{ .armed = true }));
    try t.expectEqual(Phase.inflight, phaseOf(&st, .{ .in_flight = true, .armed = true }));
    try t.expectEqual(Phase.shown, phaseOf(&st, .{ .ghost_showing = true, .armed = true }));
    // An empty answer holds for two seconds, then the chip goes.
    st.note(.empty, 900, 1000);
    try t.expectEqual(Phase.empty, phaseOf(&st, .{ .now_ms = 2999 }));
    try t.expectEqual(Phase.idle, phaseOf(&st, .{ .now_ms = 3000 }));
    // A failure holds longer, and outranks a held `∅`.
    st.note(.empty, 100, 5000);
    st.note(.failed, 100, 5000);
    try t.expectEqual(Phase.err, phaseOf(&st, .{ .now_ms = 6000 }));
    try t.expectEqual(Phase.idle, phaseOf(&st, .{ .now_ms = 10_000 }));
    // A request going out clears whatever was held.
    st.note(.failed, 100, 20_000);
    try t.expectEqual(Phase.err, phaseOf(&st, .{ .now_ms = 20_100 }));
    try t.expectEqual(Phase.inflight, phaseOf(&st, .{ .now_ms = 20_100, .in_flight = true }));
    st.clearHolds();
    try t.expectEqual(Phase.idle, phaseOf(&st, .{ .now_ms = 20_100 }));
    // A suggestion that lands after a failure never paints `!` over it.
    st.note(.failed, 100, 30_000);
    st.note(.shown, 100, 30_000);
    try t.expectEqual(Phase.shown, phaseOf(&st, .{ .now_ms = 30_100, .ghost_showing = true }));
    // The wire words are `status.json`'s.
    try t.expectEqualStrings("error", Phase.err.wire());
    try t.expectEqualStrings("inflight", Phase.inflight.wire());
}

test "chipText: a chip in the phases that have one, nothing in the two that do not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try chipText(a, .idle, 0, 0, false) == null);
    try t.expect(try chipText(a, .shown, 0, 0, false) == null);
    try t.expectEqualStrings(" \u{f0626} … ", (try chipText(a, .armed, 0, 0, false)).?);
    try t.expectEqualStrings(" \u{f0626} ∅ ", (try chipText(a, .empty, 0, 0, false)).?);
    try t.expectEqualStrings(" \u{f0626} ! ", (try chipText(a, .err, 0, 0, false)).?);
    // In flight: the app's own spinner frame, then the elapsed.
    const flight = (try chipText(a, .inflight, 1832, 0, false)).?;
    try t.expectEqualStrings(" \u{f0626} ⣾ 1.8s ", flight);
    // The frame turns with the clock — the chip is alive, not a still.
    try t.expect(!std.mem.eql(u8, flight, (try chipText(a, .inflight, 1832, 240, false)).?));
    // `--ascii` has no Nerd Font to fall back on.
    try t.expectEqualStrings(" AI ... ", (try chipText(a, .armed, 0, 0, true)).?);
    try t.expectEqualStrings(" AI | 0.4s ", (try chipText(a, .inflight, 400, 0, true)).?);
    try t.expectEqualStrings(" AI 0 ", (try chipText(a, .empty, 0, 0, true)).?);
}

test "logLine: one line per request, the outcome last" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("ghost-text: claude-code · 2.3s · 41 chars", try logLine(a, .claude_code, .shown, 2310, 41, null));
    try t.expectEqualStrings("ghost-text: claude-code · 0.9s · empty", try logLine(a, .claude_code, .empty, 900, 0, null));
    try t.expectEqualStrings("ghost-text: claude-api · 4.0s · timeout", try logLine(a, .claude_api, .timeout, 4000, 0, null));
    try t.expectEqualStrings("ghost-text: claude-code · 0.4s · cancelled (typed)", try logLine(a, .claude_code, .cancelled, 400, 0, null));
    // The worker's own `ghost-text: ` prefix does not read twice.
    try t.expectEqualStrings(
        "ghost-text: claude-code · 1.2s · error: claude -p: not signed in",
        try logLine(a, .claude_code, .failed, 1200, 0, "ghost-text: claude -p: not signed in"),
    );
    try t.expectEqualStrings("ghost-text: claude-api · 0.0s · error: the request failed", try logLine(a, .claude_api, .failed, 0, 0, null));
}

test "stats: the mean and the last five outcomes, oldest dropped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    defer st.deinit(t.allocator);
    try t.expectEqualStrings("AI ghost-text: 0 of 0 accepted (0%)", try statsLine(a, &st, 0, 0));
    st.note(.shown, 1000, 0);
    st.note(.empty, 3000, 0);
    try t.expectEqual(@as(?i64, 2000), st.meanMs());
    try t.expectEqualStrings("AI ghost-text: 1 of 2 accepted (50%) · mean 2.0s · last: ok, empty", try statsLine(a, &st, 2, 1));
    // Six outcomes, five remembered: the oldest goes.
    for ([_]Outcome{ .failed, .timeout, .cancelled, .shown }) |o| st.note(o, 1000, 0);
    try t.expectEqual(@as(usize, recent_cap), st.recent_len);
    try t.expectEqualStrings("empty", st.recent[0].word());
    try t.expectEqualStrings("ok", st.recent[recent_cap - 1].word());
    st.note(.shown, 1000, 0);
    try t.expectEqualStrings("error", st.recent[0].word());
}

test "hover copy names the backend and the last latency" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{};
    defer st.deinit(t.allocator);
    try t.expectEqualStrings("AI ghost-text — asking", hoverTitle(.inflight));
    try t.expectEqualStrings(
        "Claude Code sub · click: pick the backend · right-click: the ghost-text menu",
        try hoverDetail(a, &st, .claude_code, .idle),
    );
    st.note(.shown, 2300, 0);
    try t.expectEqualStrings(
        "Claude API · last 2.3s · mean 2.3s · click: pick the backend · right-click: the ghost-text menu",
        try hoverDetail(a, &st, .claude_api, .idle),
    );
    // A failure names itself, once, without the worker's own prefix.
    st.setError(t.allocator, "ghost-text: claude -p: not signed in");
    st.note(.failed, 1300, 0);
    try t.expectEqualStrings("AI ghost-text — the last request failed", hoverTitle(.err));
    try t.expectEqualStrings(
        "Claude Code sub · claude -p: not signed in · last 1.3s · mean 1.8s · click: pick the backend · right-click: the ghost-text menu",
        try hoverDetail(a, &st, .claude_code, .err),
    );
}
