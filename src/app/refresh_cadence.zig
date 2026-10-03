//! How often a dashboard's source is read again — one model for the
//! three behind the SESSIONS section and the sessions table: the
//! liveness pass (`sessions.refresh`: the process table, each row's
//! state, `git status`), the transcript walk (`agents.refresh`: a stat
//! per file, a read only for what moved) and the cloud runs
//! (`cloud_agents.refresh`: the `aws` call).
//!
//! A source has three intervals. It runs on `fast_ms` while a view of
//! it is on screen AND something is live (a session thinking or in a
//! tool, a cloud run in progress), on `slow_ms` while a view is on
//! screen with nothing live, and on `idle_ms` while no view is — so the
//! next open shows a recent listing without the machine re-reading it
//! every few seconds. 0 is "never" for any of the three.
//! `ui.dashboard_refresh` (Settings → Integrations → Dashboard refresh)
//! overrides the choice: `fast` / `slow` pin the on-screen interval,
//! `manual` runs nothing until the ⟳ chip or `sessions.refresh` asks.
//!
//! The decision is arithmetic on values the last adoption left behind
//! (`sessions.State`): no timer per source, no allocation.

const std = @import("std");
const Config = @import("../config/Config.zig");

/// `sessions.refresh`, `agents.refresh`, `cloud_agents.refresh` in the
/// config: milliseconds, 0 = never.
pub const Cadence = Config.RefreshCadence;

/// `ui.dashboard_refresh`.
pub const Mode = Config.DashboardRefresh;

/// Which of a source's intervals applies now.
pub const Phase = enum { fast, slow, idle, manual };

pub fn phase(mode: Mode, on_screen: bool, live: bool) Phase {
    return switch (mode) {
        .manual => .manual,
        .fast => if (on_screen) .fast else .idle,
        .slow => if (on_screen) .slow else .idle,
        .auto => if (!on_screen) .idle else if (live) .fast else .slow,
    };
}

/// The interval for `p`, null when the source does not run on its own.
pub fn interval(c: Cadence, p: Phase) ?i64 {
    const ms: u32 = switch (p) {
        .fast => c.fast_ms,
        .slow => c.slow_ms,
        .idle => c.idle_ms,
        .manual => return null,
    };
    return if (ms == 0) null else ms;
}

/// When a source last read at `last_ms` is due again, null for never.
pub fn dueAt(c: Cadence, p: Phase, last_ms: i64) ?i64 {
    return last_ms + (interval(c, p) orelse return null);
}

pub fn isDue(c: Cadence, p: Phase, last_ms: i64, now: i64) bool {
    const at = dueAt(c, p, last_ms) orelse return false;
    return now >= at;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "refresh cadence: auto is fast on screen with something live, slow on screen without, idle off screen; manual never runs" {
    try t.expectEqual(Phase.fast, phase(.auto, true, true));
    try t.expectEqual(Phase.slow, phase(.auto, true, false));
    try t.expectEqual(Phase.idle, phase(.auto, false, true));
    try t.expectEqual(Phase.idle, phase(.auto, false, false));
    // The pinned modes hold their interval on screen whatever is live,
    // and still drop to idle off it.
    try t.expectEqual(Phase.fast, phase(.fast, true, false));
    try t.expectEqual(Phase.slow, phase(.slow, true, true));
    try t.expectEqual(Phase.idle, phase(.fast, false, true));
    try t.expectEqual(Phase.manual, phase(.manual, true, true));
    try t.expectEqual(Phase.manual, phase(.manual, false, false));

    const c: Cadence = .{ .fast_ms = 1000, .slow_ms = 4000, .idle_ms = 0 };
    try t.expectEqual(@as(?i64, 1000), interval(c, .fast));
    try t.expectEqual(@as(?i64, 4000), interval(c, .slow));
    // 0 is never, as manual is.
    try t.expectEqual(@as(?i64, null), interval(c, .idle));
    try t.expectEqual(@as(?i64, null), interval(c, .manual));
    try t.expect(!isDue(c, .fast, 500, 1499));
    try t.expect(isDue(c, .fast, 500, 1500));
    try t.expect(!isDue(c, .slow, 500, 1500));
    try t.expect(!isDue(c, .idle, 0, std.math.maxInt(i32)));
    try t.expect(!isDue(c, .manual, 0, std.math.maxInt(i32)));
    try t.expectEqual(@as(?i64, 4500), dueAt(c, .slow, 500));
}
