//! The Claude / Codex usage reader — the numbers behind the statusline
//! quota chip, the usage panes and the chip's menu. One source: nothing
//! else in the app reads a percentage.
//!
//! Where the numbers come from (the Rust reference, `src/ai_usage.rs`):
//!
//!   * Claude: `GET https://api.anthropic.com/api/oauth/usage` with the
//!     Claude Code OAuth access token as the bearer
//!     (`fetch_claude_with_token_for`, ai_usage.rs:1068). The token is
//!     read from `<data root>/ai_token` — per account,
//!     `[[ai.claude.accounts]].token_path` (config.rs:2372) — a file the
//!     user seeded from the CLI's macOS keychain item `Claude Code-
//!     credentials` (`{claudeAiOauth: {accessToken, refreshToken,
//!     expiresAt, …}}`). The response's `five_hour.utilization` /
//!     `resets_at` and `seven_day.*` are the session and weekly windows,
//!     `limits[]` (`kind` session / weekly_all / weekly_scoped) the
//!     fallback and the per-model rows (`parse_claude_response`,
//!     ai_usage.rs:1336). A 401 / 403 refreshes the token once through
//!     `POST https://console.anthropic.com/v1/oauth/token` (ai_usage.rs:
//!     319), then tries the keychain's current login; a 429's
//!     `Retry-After` is honoured. `GET /api/oauth/profile` names the
//!     account (email, organization) best-effort (ai_usage.rs:1281).
//!     Nothing under `~/.claude` carries these numbers.
//!   * Codex: today's `~/.codex/sessions/**/*.jsonl`, summing each
//!     line's `last_token_usage` delta (`fetch_codex_blocking`,
//!     ai_usage.rs:1588 — Rust lists the directory flat; the CLI nests
//!     `YYYY/MM/DD/`, so this walks).
//!
//! Cadence (`maybe_refresh_ai_usage`, app/ai_usage_methods.rs:233): the
//! active account every 5 minutes — every minute from 90 % up — the
//! others every 20, one spawn per tick and never two within 20 s; a
//! failure backs off 10 min doubling to an hour, or the server's hint.
//!
//! `MNML_CLAUDE_USAGE_FIXTURE=<dir>` replaces the wire with files:
//! `<name>.json` is an account's usage body, `<name>.profile.json` its
//! profile, `<name>.error` a failure (`HTTP 429 retry-after=120`, or
//! `needs-reauth: …`, or any message), `codex.json` the Codex numbers
//! (`{"tokens_today":…,"sessions_today":…}`), `accounts` the account list
//! (one name per line, `*` marks the active one — the config's list
//! otherwise), `now` a fixed clock (unix seconds) and `tz_offset` a fixed
//! zone (seconds east) so a dump is the same on every machine. An
//! account with neither a `.json` nor an `.error` is the not-linked
//! state.
//!
//! D1: a worker's result rides `AppEvent.usage` as an owned `*Result`
//! the handler adopts or destroys; the fetchers here are blocking and
//! allocate only on the arena they are handed. D2: nothing here toasts.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const fixture_env = "MNML_CLAUDE_USAGE_FIXTURE";
pub const usage_url = "https://api.anthropic.com/api/oauth/usage";
pub const profile_url = "https://api.anthropic.com/api/oauth/profile";
pub const token_url = "https://console.anthropic.com/v1/oauth/token";
/// Claude Code's public OAuth client id — the one the keychain blob
/// was minted against, so a refresh must present it.
pub const oauth_client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const keychain_service = "Claude Code-credentials";
pub const token_file = "ai_token";
pub const identity_file = "ai_account_identity.json";
pub const last_response_file = "ai_last_response.json";

pub const refresh_interval_s: u64 = 5 * 60;
pub const idle_interval_s: u64 = 20 * 60;
pub const hot_interval_s: u64 = 60;
pub const spawn_gap_s: u64 = 20;
pub const keychain_interval_s: u64 = 5 * 60;
pub const backoff_base_s: u64 = 10 * 60;
pub const backoff_cap_s: u64 = 60 * 60;
/// The ticker chip shows each account this long.
pub const ticker_slot_s: u64 = 4;
pub const max_body: usize = 1024 * 1024;
pub const max_jsonl: usize = 10 * 1024 * 1024;
pub const max_lines_per_file: usize = 100_000;

// ─── the numbers ────────────────────────────────────────────────────────

/// A `limits[].severity`: how the endpoint itself grades the window.
pub const Severity = enum {
    normal,
    warning,
    critical,

    pub fn parse(s: []const u8) ?Severity {
        return std.meta.stringToEnum(Severity, s);
    }
};

/// One `weekly_scoped` limit: a per-model weekly cap.
pub const Scoped = struct {
    model: []const u8,
    percent: u16,
    resets_at: u64,
    severity: ?Severity = null,
    is_active: bool = false,
};

/// A top-level window the parser does not name (`seven_day_cowork`, a
/// codename): its key, a title made from the key, its numbers.
pub const ExtraWindow = struct {
    key: []const u8,
    title: []const u8,
    percent: u16,
    resets_at: u64,
    locked_reason: ?[]const u8 = null,
};

/// `extra_usage`: whether paid overage is on, why not, how much of it is used.
pub const ExtraUsage = struct {
    enabled: bool,
    reason: ?[]const u8 = null,
    percent: ?u16 = null,
};

/// One `seven_day_breakdown.rows[]` entry: a surface's share of the
/// weekly window — `percent` of the week itself, not of the rows' sum.
/// `key` is `claude_code` / `chat` / `cowork` / `other` on the wire today.
pub const SurfaceShare = struct { key: []const u8, name: []const u8, percent: u16 };

/// `seven_day_breakdown`: where the week went, one row per surface, as
/// of `as_of` (unix seconds; zero when the body gave no time). Null on
/// the accounts whose endpoint sends `null` or no rows.
pub const Breakdown = struct {
    as_of: u64 = 0,
    window_started_at: u64 = 0,
    rows: []const SurfaceShare = &.{},
};

// The limit-reset offer is NOT on this endpoint, and nothing here reads
// one. claude.ai's usage page gets its reset button from a separate call
// that only a web session (the browser's cookie) can make; the OAuth
// usage endpoint answers without it and ignores the query parameters
// that select it, so no codenamed top-level slot of this body carries it
// (an earlier build guessed `omelette_promotional` and was wrong). It is
// deliberately not fetched: this reader holds an OAuth token, not a web
// session. Its shape, read off the live service on 2026-09-24:
//
//   { eligible, ineligible_reason, at_limit, exhausted,
//     grants: [{ id, label, resets_total, resets_left, starts_at, ends_at,
//                clears: ["five_hour", "seven_day",
//                         "seven_day_overage_included"],
//                paused, usable_now, use_requires_limit,
//                percent_used: {…}, blocking: [] }],
//     next_grant_id, weekly_resets_at, cooldown_until }
//
// The day it appears in the OAuth body, it arrives under its own key:
// add that key to `named_keys` and read `grants[]` (a grant with
// `usable_now` and `resets_left > 0` is an offer open, `ends_at` when it
// lapses). Until then any codename is an unknown slot like the others —
// logged, and drawn as a window only when it carries a percent or a clock.

/// The top-level keys the parser reads or deliberately ignores; any other
/// non-null key is reported in `Usage.unknown_keys`.
const named_keys = [_][]const u8{ "five_hour", "seven_day", "limits", "extra_usage", "spend", "member_dashboard_available", "seven_day_breakdown" };

/// One account's last reading. `resets_at` / `weekly_resets_at` are
/// unix seconds; zero means the endpoint gave none.
pub const Usage = struct {
    percent: u16 = 0,
    weekly_percent: u16 = 0,
    resets_at: u64 = 0,
    weekly_resets_at: u64 = 0,
    scoped: []const Scoped = &.{},
    /// Zero until the first successful read.
    fetched_at: u64 = 0,
    /// The last failure; a reading on top of it is stale, not gone.
    last_error: ?[]const u8 = null,
    consecutive_failures: u32 = 0,
    /// Unix seconds before which no fetch is spawned (a 429's hint, or
    /// the backoff). Zero when no cooldown is on.
    retry_after_at: u64 = 0,
    /// The keychain's login is another account's, so the token could
    /// not be repaired: the pane shows the guided re-auth.
    needs_reauth: bool = false,
    /// The endpoint's own grade of the session and the weekly window
    /// (`limits[].severity`), when it gave one.
    severity: ?Severity = null,
    weekly_severity: ?Severity = null,
    /// `limits[].is_active`: the window is the one in force.
    session_active: bool = false,
    weekly_active: bool = false,
    /// `five_hour.locked_reason` / `seven_day.locked_reason`.
    locked_reason: ?[]const u8 = null,
    weekly_locked_reason: ?[]const u8 = null,
    /// Top-level windows the parser does not name, in the body's order.
    windows: []const ExtraWindow = &.{},
    extra_usage: ?ExtraUsage = null,
    /// `seven_day_breakdown`, when the endpoint sent rows.
    breakdown: ?Breakdown = null,
    /// Every non-null top-level key the parser neither reads nor names —
    /// logged once per account so a new field's name can be learned.
    unknown_keys: []const []const u8 = &.{},

    /// Nothing has ever been read and no error is on record.
    pub fn isEmpty(u: *const Usage) bool {
        return u.percent == 0 and u.weekly_percent == 0 and u.scoped.len == 0;
    }
};

pub const Codex = struct {
    tokens_today: u64 = 0,
    sessions_today: u64 = 0,
    fetched_at: u64 = 0,
    last_error: ?[]const u8 = null,
};

/// A fetch that did not produce numbers.
pub const FetchErr = struct {
    message: []const u8,
    /// A 429's numeric `Retry-After`, in seconds.
    retry_after: ?u64 = null,
    needs_reauth: bool = false,
};

/// What a successful Claude fetch carries: the usage and the identity
/// the profile endpoint named, plus a warning the handler toasts (two
/// accounts sharing one login).
pub const Fetched = struct {
    usage: Usage,
    email: ?[]const u8 = null,
    org: ?[]const u8 = null,
    warning: ?[]const u8 = null,
};

pub const ClaudeOutcome = union(enum) { ok: Fetched, err: FetchErr };
pub const CodexOutcome = union(enum) { ok: Codex, err: []const u8 };

/// The keychain worker's answer: the CLI's current login. `refresh_token`
/// tells the active account apart (the access token rotates hourly);
/// `blob` and `email` come along for a capture (`R`).
pub const Keychain = struct {
    refresh_token: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    email: ?[]const u8 = null,
    err: ?[]const u8 = null,
    /// The user asked for a capture: the handler files the blob.
    capture: bool = false,
};

/// A worker's finished job. Every slice lives on `arena`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    payload: Payload = .none,

    pub const Payload = union(enum) {
        none,
        claude: struct { name: []const u8, outcome: ClaudeOutcome },
        codex: CodexOutcome,
        keychain: Keychain,
    };

    pub fn create(gpa: Allocator) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa) };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

// ─── the accounts ───────────────────────────────────────────────────────

/// One configured account, its token path resolved.
pub const AccountCfg = struct { name: []const u8, token_path: []const u8, active: bool };

/// The config's `.ai.claude_accounts`, normalised as Rust's
/// `claude_accounts()` (config.rs:2404): no entries is the single
/// `default` account on `ai_token`; exactly one entry is active — the
/// first flagged, else the first. Paths are resolved: `~/` from `home`,
/// a relative one under `data_root`.
pub fn accountsFromConfig(arena: Allocator, entries: anytype, data_root: []const u8, home: ?[]const u8) Allocator.Error![]AccountCfg {
    var out: std.ArrayListUnmanaged(AccountCfg) = .empty;
    for (entries) |e| {
        const name = std.mem.trim(u8, e.name, " \t");
        const raw = std.mem.trim(u8, e.token_path, " \t");
        try out.append(arena, .{
            .name = if (name.len == 0) "default" else name,
            .token_path = try resolveTokenPath(arena, if (raw.len == 0) token_file else raw, data_root, home),
            .active = e.active,
        });
    }
    if (out.items.len == 0) {
        try out.append(arena, .{ .name = "default", .token_path = try resolveTokenPath(arena, token_file, data_root, home), .active = true });
        return out.items;
    }
    var seen = false;
    for (out.items) |*a| {
        if (a.active and !seen) seen = true else a.active = false;
    }
    if (!seen) out.items[0].active = true;
    return out.items;
}

pub fn resolveTokenPath(arena: Allocator, raw: []const u8, data_root: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        if (home) |h| return std.fs.path.join(arena, &.{ h, raw[2..] });
    }
    if (std.mem.eql(u8, raw, "~")) {
        if (home) |h| return arena.dupe(u8, h);
    }
    if (std.fs.path.isAbsolute(raw)) return arena.dupe(u8, raw);
    return std.fs.path.join(arena, &.{ data_root, raw });
}

/// A fixture directory's `accounts` file: one name per line, `*name`
/// the active one. Null when the file is not there.
pub fn fixtureAccounts(arena: Allocator, io: Io, dir: []const u8) Allocator.Error!?[]AccountCfg {
    const path = try std.fs.path.join(arena, &.{ dir, "accounts" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var out: std.ArrayListUnmanaged(AccountCfg) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        var line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const active = line[0] == '*';
        if (active) line = std.mem.trim(u8, line[1..], " \t");
        if (line.len == 0) continue;
        try out.append(arena, .{ .name = line, .token_path = "", .active = active });
    }
    if (out.items.len == 0) return null;
    var seen = false;
    for (out.items) |*a| {
        if (a.active and !seen) seen = true else a.active = false;
    }
    if (!seen) out.items[0].active = true;
    return out.items;
}

/// The fixture's fixed clock (`now`, unix seconds), when it has one.
pub fn fixtureNow(io: Io, dir: []const u8) ?u64 {
    return fixtureInt(u64, io, dir, "now");
}

/// The fixture's fixed zone (`tz_offset`, seconds east of UTC).
pub fn fixtureTz(io: Io, dir: []const u8) ?i64 {
    return fixtureInt(i64, io, dir, "tz_offset");
}

fn fixtureInt(comptime T: type, io: Io, dir: []const u8, name: []const u8) ?T {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return null;
    var buf: [64]u8 = undefined;
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    return std.fmt.parseInt(T, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch null;
}

// ─── parsing ────────────────────────────────────────────────────────────

pub const ParseError = error{ OutOfMemory, BadJson };

/// The `/api/oauth/usage` body → the two windows and the scoped rows.
/// `now` stamps `fetched_at`.
pub fn parseUsage(arena: Allocator, json: []const u8, now: u64) ParseError!Usage {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadJson,
    };
    if (v != .object) return error.BadJson;
    const session = extractWindow(v, "five_hour", "session");
    const weekly = extractWindow(v, "seven_day", "weekly_all");
    var out: Usage = .{
        .percent = session.pct,
        .weekly_percent = weekly.pct,
        .resets_at = session.resets,
        .weekly_resets_at = weekly.resets,
        .fetched_at = now,
    };
    var scoped: std.ArrayListUnmanaged(Scoped) = .empty;
    if (field(v, "limits")) |limits| if (limits == .array) {
        for (limits.array.items) |entry| {
            const kind = strOf(entry, "kind") orelse "";
            const sev: ?Severity = if (strOf(entry, "severity")) |x| Severity.parse(x) else null;
            const active = if (field(entry, "is_active")) |x| x == .bool and x.bool else false;
            if (std.mem.eql(u8, kind, "session")) {
                out.severity = sev;
                out.session_active = active;
            } else if (std.mem.eql(u8, kind, "weekly_all")) {
                out.weekly_severity = sev;
                out.weekly_active = active;
            }
            if (!std.mem.eql(u8, kind, "weekly_scoped")) continue;
            const model: []const u8 = blk: {
                const scope = field(entry, "scope") orelse break :blk "?";
                const m = field(scope, "model") orelse break :blk "?";
                break :blk strOf(m, "display_name") orelse "?";
            };
            try scoped.append(arena, .{
                .model = try arena.dupe(u8, model),
                .percent = pctOf(entry, "percent"),
                .resets_at = if (strOf(entry, "resets_at")) |x| (parseIso8601(x) orelse 0) else 0,
                .severity = sev,
                .is_active = active,
            });
        }
    };
    out.scoped = scoped.items;
    if (field(v, "five_hour")) |w| out.locked_reason = try dupeOpt(arena, strOf(w, "locked_reason"));
    if (field(v, "seven_day")) |w| out.weekly_locked_reason = try dupeOpt(arena, strOf(w, "locked_reason"));
    if (field(v, "extra_usage")) |e| if (e == .object) {
        out.extra_usage = .{
            .enabled = if (field(e, "is_enabled")) |x| x == .bool and x.bool else false,
            .reason = try dupeOpt(arena, strOf(e, "disabled_reason")),
            .percent = if (field(e, "utilization") != null) pctOf(e, "utilization") else null,
        };
    };
    out.breakdown = try parseBreakdown(arena, field(v, "seven_day_breakdown"));
    var windows: std.ArrayListUnmanaged(ExtraWindow) = .empty;
    var unknown: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = v.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const val = e.value_ptr.*;
        if (val == .null or inList(&named_keys, key)) continue;
        try unknown.append(arena, try arena.dupe(u8, key));
        if (val != .object or (val.object.get("utilization") == null and val.object.get("resets_at") == null)) continue;
        const pct = pctOf(val, "utilization");
        const resets: u64 = if (strOf(val, "resets_at")) |x| (parseIso8601(x) orelse 0) else 0;
        const locked = strOf(val, "locked_reason");
        // A slot the endpoint keeps at zero with no clock says nothing.
        if (pct == 0 and resets == 0 and locked == null) continue;
        const title = try humanKey(arena, key);
        // `seven_day_sonnet` beside a scoped Sonnet row is that row.
        const dup = for (out.scoped) |sc| {
            const t_ = try std.fmt.allocPrint(arena, "Current week ({s})", .{sc.model});
            if (std.ascii.eqlIgnoreCase(t_, title)) break true;
        } else false;
        if (dup) continue;
        try windows.append(arena, .{ .key = try arena.dupe(u8, key), .title = title, .percent = pct, .resets_at = resets, .locked_reason = try dupeOpt(arena, locked) });
    }
    out.windows = windows.items;
    out.unknown_keys = unknown.items;
    return out;
}

/// `seven_day_breakdown` → its rows; null when it is null, not an object,
/// or has no row to show. A row without a `display_name` is titled from
/// its key.
fn parseBreakdown(arena: Allocator, v: ?std.json.Value) Allocator.Error!?Breakdown {
    const b = v orelse return null;
    if (b != .object) return null;
    const rows = field(b, "rows") orelse return null;
    if (rows != .array) return null;
    var shares: std.ArrayListUnmanaged(SurfaceShare) = .empty;
    for (rows.array.items) |r| {
        if (r != .object) continue;
        const key = strOf(r, "key") orelse "other";
        const name = if (strOf(r, "display_name")) |n| try arena.dupe(u8, n) else try humanWords(arena, key);
        try shares.append(arena, .{ .key = try arena.dupe(u8, key), .name = name, .percent = pctOf(r, "percent") });
    }
    if (shares.items.len == 0) return null;
    return .{
        .as_of = if (strOf(b, "as_of")) |x| (parseIso8601(x) orelse 0) else 0,
        .window_started_at = if (strOf(b, "window_started_at")) |x| (parseIso8601(x) orelse 0) else 0,
        .rows = shares.items,
    };
}

fn inList(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn dupeOpt(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |x| try arena.dupe(u8, x) else null;
}

/// A window's title from its key: `seven_day_<x>` is `Current week (X)`,
/// `five_hour_<x>` is `Current session (X)`, anything else the key with
/// spaces for underscores and a capital first letter.
pub fn humanKey(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const Pre = struct { pre: []const u8, title: []const u8 };
    for ([_]Pre{ .{ .pre = "seven_day_", .title = "Current week" }, .{ .pre = "five_hour_", .title = "Current session" } }) |p| {
        if (std.mem.startsWith(u8, key, p.pre) and key.len > p.pre.len) return std.fmt.allocPrint(arena, "{s} ({s})", .{ p.title, try humanWords(arena, key[p.pre.len..]) });
    }
    return humanWords(arena, key);
}

/// `org_level_disabled_until` → `Org level disabled until`.
pub fn humanWords(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, key);
    for (out) |*c| if (c.* == '_') {
        c.* = ' ';
    };
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

const Window = struct { pct: u16, resets: u64 };

/// `<top>.utilization` / `.resets_at` when either is set, else the
/// `limits[]` entry of `kind`.
fn extractWindow(v: std.json.Value, top: []const u8, kind: []const u8) Window {
    if (field(v, top)) |w| if (w == .object) {
        const pct = pctOf(w, "utilization");
        const resets: u64 = if (strOf(w, "resets_at")) |s| (parseIso8601(s) orelse 0) else 0;
        if (pct > 0 or resets > 0) return .{ .pct = pct, .resets = resets };
    };
    if (field(v, "limits")) |limits| if (limits == .array) {
        for (limits.array.items) |entry| {
            if (!std.mem.eql(u8, strOf(entry, "kind") orelse "", kind)) continue;
            return .{ .pct = pctOf(entry, "percent"), .resets = if (strOf(entry, "resets_at")) |s| (parseIso8601(s) orelse 0) else 0 };
        }
    };
    return .{ .pct = 0, .resets = 0 };
}

pub const Profile = struct { email: ?[]const u8 = null, org: ?[]const u8 = null };

/// `/api/oauth/profile` → `account.email` and `organization.name`;
/// null when neither is there.
pub fn parseProfile(arena: Allocator, json: []const u8) Allocator.Error!?Profile {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var p: Profile = .{};
    if (field(v, "account")) |a| if (strOf(a, "email")) |e| {
        const tr = std.mem.trim(u8, e, " \t");
        if (tr.len > 0) p.email = tr;
    };
    if (field(v, "organization")) |o| if (strOf(o, "name")) |n| {
        const tr = std.mem.trim(u8, n, " \t");
        if (tr.len > 0) p.org = tr;
    };
    return if (p.email == null and p.org == null) null else p;
}

/// A token file's access token: a plain `sk-ant-…` line, or the
/// keychain JSON (`{claudeAiOauth: {accessToken}}`, or the bare inner
/// object). Null for junk.
pub fn accessTokenOf(arena: Allocator, raw: []const u8) ?[]const u8 {
    return tokenField(arena, raw, "accessToken", true);
}

/// The refresh token of a JSON token file; null for a plain token.
pub fn refreshTokenOf(arena: Allocator, raw: []const u8) ?[]const u8 {
    return tokenField(arena, raw, "refreshToken", false);
}

fn tokenField(arena: Allocator, raw: []const u8, key: []const u8, plain_ok: bool) ?[]const u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] != '{') return if (plain_ok) s else null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{}) catch return null;
    const inner = field(v, "claudeAiOauth") orelse v;
    const tr = std.mem.trim(u8, strOf(inner, key) orelse return null, " \t");
    return if (tr.len == 0) null else tr;
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .null) null else f;
}

fn strOf(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn pctOf(v: std.json.Value, key: []const u8) u16 {
    const f = field(v, key) orelse return 0;
    const n: f64 = switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => return 0,
    };
    return @intFromFloat(std.math.clamp(@round(n), 0.0, 999.0));
}

fn intOf(v: std.json.Value, key: []const u8) ?u64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .float => |x| if (x < 0) null else @intFromFloat(x),
        else => null,
    };
}

/// `2026-08-05T22:50:00.123240+00:00` / `…Z` → unix seconds.
pub fn parseIso8601(s: []const u8) ?u64 {
    if (s.len < 19) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        while (rest.len > 0 and std.ascii.isDigit(rest[0])) rest = rest[1..];
    }
    var tz: i64 = 0;
    if (rest.len > 0 and rest[0] != 'Z' and rest[0] != 'z') {
        const sign: i64 = switch (rest[0]) {
            '+' => 1,
            '-' => -1,
            else => return null,
        };
        const body = rest[1..];
        var hh: i64 = 0;
        var mm: i64 = 0;
        if (std.mem.indexOfScalar(u8, body, ':')) |c| {
            hh = std.fmt.parseInt(i64, body[0..c], 10) catch return null;
            mm = std.fmt.parseInt(i64, body[c + 1 ..], 10) catch return null;
        } else if (body.len >= 4) {
            hh = std.fmt.parseInt(i64, body[0..2], 10) catch return null;
            mm = std.fmt.parseInt(i64, body[2..4], 10) catch return null;
        } else return null;
        tz = sign * (hh * 3600 + mm * 60);
    }
    const days = daysFromCivil(y, mo, d);
    const local = days * 86400 + h * 3600 + mi * 60 + sec;
    const utc = local - tz;
    return if (utc < 0) null else @intCast(utc);
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
pub fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y: i64 = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: u32, d: u32 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

// ─── the failure rule ───────────────────────────────────────────────────

/// A failed fetch on top of whatever was read before: the numbers
/// survive (a five-minute-old reading beats a fresh-looking zero), the
/// error is the staleness mark, and the account backs off — the
/// server's hint when it gave one above zero, else 10 min doubling per
/// failure to an hour.
pub fn applyFetchError(u: *Usage, e: FetchErr, now: u64) void {
    u.consecutive_failures +|= 1;
    const backoff: u64 = if (e.retry_after) |secs| (if (secs > 0) secs else backoffFor(u.consecutive_failures)) else backoffFor(u.consecutive_failures);
    u.retry_after_at = now +| backoff;
    u.last_error = e.message;
    u.needs_reauth = e.needs_reauth;
}

fn backoffFor(failures: u32) u64 {
    const shift: u6 = @intCast(@min(failures -| 1, 3));
    return @min(backoff_base_s << shift, backoff_cap_s);
}

/// The poll interval for an account: hot when it is the active one
/// between 90 and 99 %, short when active or never read, long otherwise.
pub fn intervalFor(is_active: bool, percent: u16, last_at: u64) u64 {
    if (last_at == 0) return refresh_interval_s;
    if (!is_active) return idle_interval_s;
    return if (percent >= 90 and percent < 100) hot_interval_s else refresh_interval_s;
}

// ─── the fixture reader ─────────────────────────────────────────────────

/// One account from the fixture directory.
pub fn fetchFixture(arena: Allocator, io: Io, dir: []const u8, name: []const u8, now: u64) Allocator.Error!ClaudeOutcome {
    const body_path = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.json", .{name}) });
    const err_path = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.error", .{name}) });
    if (readSmall(arena, io, err_path)) |text| return .{ .err = parseFixtureError(text) };
    const body = readSmall(arena, io, body_path) orelse return .{ .err = .{ .message = "not linked" } };
    const usage = parseUsage(arena, body, now) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadJson => return .{ .err = .{ .message = "parse json: not the usage shape" } },
    };
    var out: Fetched = .{ .usage = usage };
    const prof_path = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.profile.json", .{name}) });
    if (readSmall(arena, io, prof_path)) |text| if (try parseProfile(arena, text)) |p| {
        out.email = p.email;
        out.org = p.org;
    };
    return .{ .ok = out };
}

/// `HTTP 429 retry-after=120`, `needs-reauth: <why>`, or a message.
fn parseFixtureError(text: []const u8) FetchErr {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, line, "needs-reauth:")) return .{ .message = std.mem.trim(u8, line["needs-reauth:".len..], " \t"), .needs_reauth = true };
    var retry: ?u64 = null;
    if (std.mem.indexOf(u8, line, "retry-after=")) |i| {
        const tail = line[i + "retry-after=".len ..];
        const end = std.mem.indexOfAny(u8, tail, " \t") orelse tail.len;
        retry = std.fmt.parseInt(u64, tail[0..end], 10) catch null;
    }
    return .{ .message = line, .retry_after = retry };
}

pub fn fetchCodexFixture(arena: Allocator, io: Io, dir: []const u8, now: u64) Allocator.Error!CodexOutcome {
    const path = try std.fs.path.join(arena, &.{ dir, "codex.json" });
    const text = readSmall(arena, io, path) orelse return .{ .err = "~/.codex/sessions not found" };
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = "codex.json: not JSON" },
    };
    return .{ .ok = .{ .tokens_today = intOf(v, "tokens_today") orelse 0, .sessions_today = intOf(v, "sessions_today") orelse 0, .fetched_at = now } };
}

fn readSmall(arena: Allocator, io: Io, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_body)) catch null;
}

// ─── the wire ───────────────────────────────────────────────────────────

pub const HttpReply = struct { status: u16, retry_after: ?u64 = null, body: []const u8 };
pub const HttpError = error{ OutOfMemory, Canceled, Failed };

/// GET `url` as `bearer`; the body on `arena`. Blocking: a worker's.
pub fn httpGet(gpa: Allocator, io: Io, arena: Allocator, url: []const u8, bearer: []const u8) HttpError!HttpReply {
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{bearer});
    return httpDo(gpa, io, arena, .GET, url, &.{ .{ .name = "Authorization", .value = auth }, .{ .name = "Accept", .value = "application/json" } }, null);
}

/// POST a JSON `payload` to `url`.
pub fn httpPostJson(gpa: Allocator, io: Io, arena: Allocator, url: []const u8, payload: []const u8) HttpError!HttpReply {
    return httpDo(gpa, io, arena, .POST, url, &.{.{ .name = "Accept", .value = "application/json" }}, payload);
}

fn httpDo(gpa: Allocator, io: Io, arena: Allocator, method: std.http.Method, url: []const u8, extra: []const std.http.Header, payload: ?[]const u8) HttpError!HttpReply {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return error.Failed;
    var req = client.request(method, uri, .{
        .extra_headers = extra,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "mnml-zig" },
            .accept_encoding = .{ .override = "identity" },
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Failed,
    };
    defer req.deinit();
    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = req.sendBodyUnflushed(&.{}) catch return error.Failed;
        body.writer.writeAll(p) catch return error.Failed;
        body.end() catch return error.Failed;
        req.connection.?.flush() catch return error.Failed;
    } else req.sendBodiless() catch return error.Failed;
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Failed,
    };
    var retry_after: ?u64 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
        retry_after = std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
    };
    const status: u16 = @intFromEnum(response.head.status);
    var out: Io.Writer.Allocating = .init(arena);
    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);
    _ = reader.streamRemaining(&out.writer) catch return error.Failed;
    return .{ .status = status, .retry_after = retry_after, .body = out.written() };
}

/// Everything a live fetch needs to know about where it runs.
pub const Live = struct {
    data_root: []const u8,
    /// How many accounts are configured: with siblings, a keychain
    /// resync must prove the login is this account's before writing.
    account_count: usize,
    /// The endpoints; tests point them at a loopback server.
    usage_url: []const u8 = usage_url,
    profile_url: []const u8 = profile_url,
    token_url: []const u8 = token_url,
    /// Whether to consult the keychain on a rejected token (macOS).
    keychain: bool = builtin.os.tag == .macos,
};

/// One account over the wire: the token file, the usage endpoint, a
/// refresh on a rejected token, the profile, the identity pin.
pub fn fetchLive(gpa: Allocator, io: Io, arena: Allocator, live: Live, name: []const u8, token_path: []const u8, now: u64) HttpError!ClaudeOutcome {
    const raw = Io.Dir.cwd().readFileAlloc(io, token_path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .{ .err = .{ .message = try std.fmt.allocPrint(arena, "read token {s}: {s}", .{ token_path, @errorName(err) }) } },
    };
    var token = accessTokenOf(arena, raw) orelse return .{ .err = .{ .message = "not linked" } };
    var reply = try httpGet(gpa, io, arena, live.usage_url, token);
    if (reply.status == 401 or reply.status == 403) {
        if (refreshTokenOf(arena, raw)) |rt| if (try refreshToken(gpa, io, arena, live.token_url, rt, token_path)) |fresh| {
            token = fresh;
            reply = try httpGet(gpa, io, arena, live.usage_url, token);
        };
    }
    if ((reply.status == 401 or reply.status == 403) and live.keychain) {
        if (readKeychain(gpa, io, arena)) |blob| if (!std.mem.eql(u8, std.mem.trim(u8, blob, " \t\r\n"), std.mem.trim(u8, raw, " \t\r\n"))) {
            const candidate = accessTokenOf(arena, blob) orelse blob;
            const again = try httpGet(gpa, io, arena, live.usage_url, candidate);
            if (again.status >= 200 and again.status < 300) {
                // The blob works — but is it THIS account's? With one
                // account there is no sibling to clobber; with several
                // the profile's email must match the account's pin.
                var belongs = live.account_count <= 1;
                if (!belongs) {
                    const prof = try profileOf(gpa, io, arena, live.profile_url, candidate);
                    const email = if (prof) |p| p.email else null;
                    const pinned = try pinnedEmail(arena, io, live.data_root, name);
                    if (email != null and pinned != null and std.mem.eql(u8, email.?, pinned.?)) belongs = true;
                    if (!belongs) {
                        return .{ .err = .{
                            .message = try std.fmt.allocPrint(arena, "the keychain login is {s}, not {s}'s", .{ email orelse "unknown", name }),
                            .needs_reauth = true,
                        } };
                    }
                }
                writeSecret(io, token_path, blob) catch {};
                token = candidate;
                reply = again;
            }
        };
    }
    try writeLastResponse(arena, io, live.data_root, reply, now);
    if (reply.status < 200 or reply.status >= 300) {
        const msg = if (reply.status == 401 or reply.status == 403)
            "token rejected — re-link via :ai.link_claude_token"
        else
            truncate(redactBearer(arena, reply.body) catch reply.body, 80);
        return .{ .err = .{
            .message = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ reply.status, msg }),
            .retry_after = if (reply.status == 429) reply.retry_after else null,
        } };
    }
    const usage = parseUsage(arena, reply.body, now) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadJson => return .{ .err = .{ .message = "parse json: not the usage shape" } },
    };
    var out: Fetched = .{ .usage = usage };
    if (try profileOf(gpa, io, arena, live.profile_url, token)) |p| {
        out.email = p.email;
        out.org = p.org;
        if (p.email) |e| out.warning = try pinIdentity(arena, io, live.data_root, name, e);
    }
    return .{ .ok = out };
}

fn profileOf(gpa: Allocator, io: Io, arena: Allocator, url: []const u8, token: []const u8) HttpError!?Profile {
    const reply = httpGet(gpa, io, arena, url, token) catch |err| switch (err) {
        error.Failed => return null,
        else => return err,
    };
    if (reply.status < 200 or reply.status >= 300) return null;
    return parseProfile(arena, reply.body);
}

/// `POST` the refresh grant; on success the new blob is written back to
/// `token_path` and the fresh access token returned.
fn refreshToken(gpa: Allocator, io: Io, arena: Allocator, url: []const u8, refresh: []const u8, token_path: []const u8) HttpError!?[]const u8 {
    var payload: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .grant_type = "refresh_token", .refresh_token = refresh, .client_id = oauth_client_id }, .{}, &payload.writer) catch return error.OutOfMemory;
    const reply = httpPostJson(gpa, io, arena, url, payload.written()) catch |err| switch (err) {
        error.Failed => return null,
        else => return err,
    };
    if (reply.status < 200 or reply.status >= 300) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, .{}) catch return null;
    const access = strOf(v, "access_token") orelse return null;
    const new_refresh = strOf(v, "refresh_token") orelse refresh;
    const expires_in = intOf(v, "expires_in") orelse 0;
    const now: u64 = @intCast(@max(Io.Timestamp.now(io, .real).toSeconds(), 0));
    var blob: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .claudeAiOauth = .{ .accessToken = access, .refreshToken = new_refresh, .expiresAt = (now +| expires_in) *| 1000 } }, .{ .whitespace = .indent_2 }, &blob.writer) catch return error.OutOfMemory;
    writeSecret(io, token_path, blob.written()) catch {};
    return access;
}

/// The macOS keychain's Claude Code login, raw. Null off macOS, when
/// `security` fails, or when the item is empty.
pub fn readKeychain(gpa: Allocator, io: Io, arena: Allocator) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const result = std.process.run(gpa, io, .{ .argv = &.{ "security", "find-generic-password", "-s", keychain_service, "-w" }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(4096) }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    const out = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return arena.dupe(u8, out) catch null;
}

/// Create-or-truncate `path` at mode 0600 (the parent made as needed).
pub fn writeSecret(io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch {};
    const perms: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = perms });
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
}

fn writeLastResponse(arena: Allocator, io: Io, data_root: []const u8, reply: HttpReply, now: u64) Allocator.Error!void {
    if (data_root.len == 0) return;
    const path = try std.fs.path.join(arena, &.{ data_root, "cache", last_response_file });
    const text = try std.fmt.allocPrint(arena, "// HTTP {d}\n// fetched_at: {d}\n{s}\n", .{ reply.status, now, try redactBearer(arena, reply.body) });
    writeSecret(io, path, text) catch {};
}

/// Anything shaped like a token (`sk-ant-…`, `sk-…`, `Bearer <run>`) →
/// `<redacted>`, so an echoed header never reaches a toast or a file.
pub fn redactBearer(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const rest = s[i..];
        const hit = std.mem.startsWith(u8, rest, "sk-") or std.mem.startsWith(u8, rest, "Bearer ");
        if (hit) {
            var j: usize = if (rest[0] == 'B') "Bearer ".len else 0;
            while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '-' or rest[j] == '_')) j += 1;
            if (j > 8) {
                try out.appendSlice(arena, "<redacted>");
                i += j;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn truncate(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ─── identity pins ──────────────────────────────────────────────────────

/// `<data root>/ai_account_identity.json`: `{name: email}`, learned the
/// first time an account's profile answers. The token blob carries no
/// identity, so this is how accounts are told apart offline.
pub fn pinnedEmail(arena: Allocator, io: Io, data_root: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const pins = try readPins(arena, io, data_root);
    return pins.get(name);
}

fn readPins(arena: Allocator, io: Io, data_root: []const u8) Allocator.Error!std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (data_root.len == 0) return map;
    const path = try std.fs.path.join(arena, &.{ data_root, identity_file });
    const text = readSmall(arena, io, path) orelse return map;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return map;
    if (v != .object) return map;
    var it = v.object.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .string) try map.put(arena, e.key_ptr.*, e.value_ptr.string);
    return map;
}

/// Record `name → email` unless another account already owns that
/// email — then say so (the returned warning) and leave the pin alone.
pub fn pinIdentity(arena: Allocator, io: Io, data_root: []const u8, name: []const u8, email: []const u8) Allocator.Error!?[]const u8 {
    if (data_root.len == 0) return null;
    var pins = try readPins(arena, io, data_root);
    var it = pins.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, name)) continue;
        if (std.mem.eql(u8, e.value_ptr.*, email)) return try std.fmt.allocPrint(arena, "Claude accounts {s} and {s} share one login ({s}) — their token files hold the same credential", .{ e.key_ptr.*, name, email });
    }
    if (pins.get(name)) |old| if (std.mem.eql(u8, old, email)) return null;
    try pins.put(arena, name, email);
    var obj: std.json.ObjectMap = .empty;
    var it2 = pins.iterator();
    while (it2.next()) |e| try obj.put(arena, e.key_ptr.*, .{ .string = e.value_ptr.* });
    var out: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(std.json.Value{ .object = obj }, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    const path = try std.fs.path.join(arena, &.{ data_root, identity_file });
    writeSecret(io, path, out.written()) catch {};
    return null;
}

/// Move `old`'s pin to `new` (an account renamed), or drop it when `new`
/// is null (an account removed). No pin, no write.
pub fn movePin(arena: Allocator, io: Io, data_root: []const u8, old: []const u8, new: ?[]const u8) Allocator.Error!void {
    if (data_root.len == 0) return;
    var pins = try readPins(arena, io, data_root);
    const email = pins.get(old) orelse return;
    _ = pins.orderedRemove(old);
    if (new) |n| try pins.put(arena, n, email);
    var obj: std.json.ObjectMap = .empty;
    var it = pins.iterator();
    while (it.next()) |e| try obj.put(arena, e.key_ptr.*, .{ .string = e.value_ptr.* });
    var out: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(std.json.Value{ .object = obj }, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    const path = try std.fs.path.join(arena, &.{ data_root, identity_file });
    writeSecret(io, path, out.written()) catch {};
}

/// The account whose token file holds `refresh_token` — the one the
/// CLI is logged in as right now.
pub fn accountOfRefreshToken(arena: Allocator, io: Io, accounts: []const AccountCfg, refresh_token: []const u8) Allocator.Error!?[]const u8 {
    for (accounts) |a| {
        if (a.token_path.len == 0) continue;
        const raw = readSmall(arena, io, a.token_path) orelse continue;
        if (refreshTokenOf(arena, raw)) |rt| if (std.mem.eql(u8, rt, refresh_token)) return a.name;
    }
    return null;
}

// ─── Codex ──────────────────────────────────────────────────────────────

/// Today's Codex sessions: every `.jsonl` under `<home>/.codex/sessions`
/// touched today (UTC day), the `last_token_usage` deltas summed.
pub fn fetchCodexLive(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, now: u64) (Allocator.Error || Io.Cancelable)!CodexOutcome {
    const sessions = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    var root = Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true }) catch return .{ .err = "~/.codex/sessions not found" };
    defer root.close(io);
    var out: Codex = .{ .fetched_at = now };
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        const mtime = st.mtime.toSeconds();
        if (mtime < 0 or @divFloor(@as(u64, @intCast(mtime)), 86400) != now / 86400) continue;
        try io.checkCancel();
        const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_jsonl)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(text);
        out.sessions_today += 1;
        out.tokens_today += try sumCodexJsonl(gpa, text);
    }
    return .{ .ok = out };
}

/// The `last_token_usage` (a per-turn delta — never `total_token_usage`,
/// which is cumulative) summed over the lines of one rollout file.
pub fn sumCodexJsonl(gpa: Allocator, text: []const u8) Allocator.Error!u64 {
    var sum: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= max_lines_per_file) break;
        if (std.mem.indexOf(u8, line, "last_token_usage") == null) continue;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        const usage = walkKey(v, "last_token_usage", 0) orelse continue;
        const inp = intOf(usage, "input_tokens") orelse 0;
        const outp = intOf(usage, "output_tokens") orelse 0;
        sum += intOf(usage, "total_tokens") orelse (inp + outp);
    }
    return sum;
}

fn walkKey(v: std.json.Value, key: []const u8, depth: usize) ?std.json.Value {
    if (depth > 8) return null;
    switch (v) {
        .object => |o| {
            if (o.get(key)) |hit| return hit;
            var it = o.iterator();
            while (it.next()) |e| if (walkKey(e.value_ptr.*, key, depth + 1)) |hit| return hit;
        },
        .array => |a| for (a.items) |item| {
            if (walkKey(item, key, depth + 1)) |hit| return hit;
        },
        else => {},
    }
    return null;
}

// ─── formatting ─────────────────────────────────────────────────────────

/// `6:50pm` — a session reset, later today. `offset` is seconds east.
pub fn fmtShortTime(buf: []u8, secs: u64, offset: i64) []const u8 {
    const local: u64 = @intCast(@max(@as(i64, @intCast(secs)) + offset, 0));
    const mins = (local / 60) % (24 * 60);
    return fmtClock(buf, mins / 60, mins % 60);
}

/// `Aug 10 at 2am` — a weekly reset, another day.
pub fn fmtLongTime(buf: []u8, secs: u64, offset: i64) []const u8 {
    const local: u64 = @intCast(@max(@as(i64, @intCast(secs)) + offset, 0));
    const mins = (local / 60) % (24 * 60);
    const c = civilFromDays(@intCast(local / 86400));
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var tb: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {d} at {s}", .{ months[(c.m - 1) % 12], c.d, fmtClock(&tb, mins / 60, mins % 60) }) catch "?";
}

fn fmtClock(buf: []u8, h: u64, m: u64) []const u8 {
    const h12: u64 = if (h == 0 or h == 12) 12 else h % 12;
    const ampm: []const u8 = if (h < 12) "am" else "pm";
    if (m == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ h12, ampm }) catch "?";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}{s}", .{ h12, m, ampm }) catch "?";
}

/// ` 3h` / ` 45m` / ` 2d` / ` <1m` until `resets_at`; the window's
/// nominal length (`5h` / `7d`) when the endpoint gave no reset — an
/// untouched window still rolls over within it.
pub fn fmtResetSuffix(buf: []u8, resets_at: u64, now: u64, fallback: []const u8) []const u8 {
    if (resets_at == 0 or resets_at <= now) return std.fmt.bufPrint(buf, " {s}", .{fallback}) catch "?";
    const rem = resets_at - now;
    if (rem < 60) return " <1m";
    if (rem < 3600) return std.fmt.bufPrint(buf, " {d}m", .{rem / 60}) catch "?";
    if (rem < 86_400) return std.fmt.bufPrint(buf, " {d}h", .{rem / 3600}) catch "?";
    return std.fmt.bufPrint(buf, " {d}d", .{rem / 86_400}) catch "?";
}

/// `1234567` → `1,234,567`.
pub fn fmtThousands(buf: []u8, n: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&digits, "{d}", .{n}) catch return "?";
    var out: usize = 0;
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) {
            if (out >= buf.len) return "?";
            buf[out] = ',';
            out += 1;
        }
        if (out >= buf.len) return "?";
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

// ─── the chip ───────────────────────────────────────────────────────────

pub const Tier = enum { ok, warn, hot };

pub fn tierOf(percent: u16) Tier {
    return if (percent >= 85) .hot else if (percent >= 60) .warn else .ok;
}

/// The endpoint's `severity` when it gave one, else the thresholds.
pub fn tierOfWire(percent: u16, severity: ?Severity) Tier {
    const sev = severity orelse return tierOf(percent);
    return switch (sev) {
        .critical => .hot,
        .warning => .warn,
        .normal => .ok,
    };
}

/// Eight blocks over 0–100 for the compact chip.
pub fn sparklineChar(percent: u16) []const u8 {
    const blocks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const idx = (@as(usize, @min(percent, 100)) * (blocks.len - 1)) / 100;
    return blocks[@min(idx, blocks.len - 1)];
}

/// The chip's view of one account: what the compact and ticker
/// renderers need, decoupled from the app's owned rows.
pub const ChipAccount = struct { name: []const u8, usage: Usage, is_active: bool };

pub const Detail = enum { session, weekly, both };

pub const ChipOpts = struct {
    glyph: []const u8,
    detail: Detail = .both,
    show_reset: bool = false,
    now: u64,
};

/// One account's chip: ` 󱸀 24% 3h 62% 4d ` (a letter prefix in ticker
/// mode, a trailing `!` when the reading is stale, `—` before the first
/// reading, `—!` when nothing was ever read).
pub fn singleChip(arena: Allocator, u: *const Usage, letter: ?u8, o: ChipOpts) Allocator.Error![]const u8 {
    var prefix: [2]u8 = .{ ' ', ' ' };
    const pre: []const u8 = if (letter) |l| blk: {
        prefix[0] = l;
        break :blk prefix[0..2];
    } else "";
    if (u.fetched_at == 0) return std.fmt.allocPrint(arena, " {s} {s}{s} ", .{ o.glyph, pre, if (u.last_error != null) "—!" else "—" });
    const stale: []const u8 = if (u.last_error != null) "!" else "";
    var sb: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    const sr: []const u8 = if (o.show_reset) fmtResetSuffix(&sb, u.resets_at, o.now, "5h") else "";
    const wr: []const u8 = if (o.show_reset) fmtResetSuffix(&wb, u.weekly_resets_at, o.now, "7d") else "";
    return switch (o.detail) {
        .weekly => std.fmt.allocPrint(arena, " {s} {s}{d}%{s}{s} ", .{ o.glyph, pre, u.weekly_percent, wr, stale }),
        .both => std.fmt.allocPrint(arena, " {s} {s}{d}%{s} {d}%{s}{s} ", .{ o.glyph, pre, u.percent, sr, u.weekly_percent, wr, stale }),
        .session => std.fmt.allocPrint(arena, " {s} {s}{d}%{s}{s} ", .{ o.glyph, pre, u.percent, sr, stale }),
    };
}

pub const Compact = struct {
    text: []const u8,
    /// `text` in its parts: the blocks, and what follows
    /// them (the stale `!`, the arrow or the countdown, the last space).
    spark: []const u8 = "",
    rest: []const u8 = "",
    /// The worst state across the accounts read (the endpoint's own
    /// severity where it gave one).
    tier: Tier = .ok,
    /// The worst session % across the accounts read.
    worst: u16 = 0,
    any_error: bool = false,
    any_fetched: bool = false,
};

/// Every account at once: a sparkline (one block per account, `!` for
/// one never read, `…` for one not read yet), a `!` when any reading is
/// stale, then `→P` — the account to spend on next (remaining % per
/// hour of runway, a clear winner) — else `⟳3h` to the first reset.
pub fn compactChip(arena: Allocator, accounts: []const ChipAccount, o: ChipOpts) Allocator.Error!Compact {
    if (accounts.len == 0) return .{ .text = try std.fmt.allocPrint(arena, " {s} … ", .{o.glyph}) };
    var spark: std.ArrayListUnmanaged(u8) = .empty;
    var out: Compact = .{ .text = "" };
    var any_stale = false;
    var all_near_empty = true;
    for (accounts) |a| {
        const u = &a.usage;
        if (u.fetched_at > 0) {
            try spark.appendSlice(arena, sparklineChar(u.percent));
            out.tier = worseTier(out.tier, accountTier(u));
            out.worst = @max(out.worst, u.percent);
            out.any_fetched = true;
            if (u.percent < 90) all_near_empty = false;
            if (u.last_error != null) any_stale = true;
        } else if (u.last_error != null) {
            try spark.append(arena, '!');
            out.any_error = true;
            all_near_empty = false;
        } else {
            try spark.appendSlice(arena, "…");
            all_near_empty = false;
        }
    }
    var suffix: []const u8 = "";
    if (out.any_fetched) {
        var top: ?struct { urg: f32, letter: u8 } = null;
        var second: f32 = 0;
        for (accounts) |a| {
            const urg = urgency(&a.usage, o.now);
            if (urg <= 0) continue;
            if (top == null or urg > top.?.urg) {
                if (top) |prev| second = @max(second, prev.urg);
                top = .{ .urg = urg, .letter = abbrev(a.name) };
            } else second = @max(second, urg);
        }
        if (!all_near_empty and top != null and second * 1.5 < top.?.urg) {
            suffix = try std.fmt.allocPrint(arena, " →{c}", .{top.?.letter});
        } else if (hoursUntilFirstReset(accounts, o.now)) |h| {
            suffix = if (h == 0) " ⟳<1h" else if (h < 100) try std.fmt.allocPrint(arena, " ⟳{d}h", .{h}) else " ⟳soon";
        }
    }
    out.spark = spark.items;
    out.rest = try std.fmt.allocPrint(arena, "{s}{s} ", .{ if (any_stale) "!" else "", suffix });
    out.text = try std.fmt.allocPrint(arena, " {s} {s}{s}", .{ o.glyph, out.spark, out.rest });
    return out;
}

/// An account's worst window: the session or the week, by the endpoint's
/// grade where it gave one.
pub fn accountTier(u: *const Usage) Tier {
    return worseTier(tierOfWire(u.percent, u.severity), tierOfWire(u.weekly_percent, u.weekly_severity));
}

pub fn worseTier(a: Tier, b: Tier) Tier {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
}

/// `remaining % / hours to reset`: how much of an account the next reset
/// would throw away per hour — the reason to be on it now.
pub fn urgency(u: *const Usage, now: u64) f32 {
    if (u.fetched_at == 0 or u.last_error != null or u.percent >= 100) return 0;
    const remaining: f32 = @floatFromInt(100 - u.percent);
    const reset_at = if (u.resets_at > now) u.resets_at else if (u.weekly_resets_at > now) u.weekly_resets_at else return 0;
    const hours = @as(f32, @floatFromInt(reset_at - now)) / 3600.0;
    if (hours <= 0.05) return remaining * 1000.0;
    return remaining / hours;
}

/// Whole hours to the earliest reset still ahead, across the accounts.
pub fn hoursUntilFirstReset(accounts: []const ChipAccount, now: u64) ?u64 {
    var best: ?u64 = null;
    for (accounts) |a| {
        for ([_]u64{ a.usage.resets_at, a.usage.weekly_resets_at }) |at| if (at > now) {
            best = if (best) |b| @min(b, at) else at;
        };
    }
    return if (best) |b| (b - now) / 3600 else null;
}

/// The first letter of the name, upper-cased; `?` for an empty name.
pub fn abbrev(name: []const u8) u8 {
    return if (name.len == 0) '?' else std.ascii.toUpper(name[0]);
}

/// Which account the ticker shows at `now`.
pub fn tickerIndex(now: u64, n: usize) usize {
    return if (n == 0) 0 else @intCast((now / ticker_slot_s) % n);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// The shape of a real `/api/oauth/usage` body (values invented).
pub const usage_fixture =
    \\{"five_hour":{"utilization":95.0,"resets_at":"2026-09-12T20:20:00.280504+00:00","limit_dollars":null},
    \\ "seven_day":{"utilization":52.0,"resets_at":"2026-09-19T05:00:00.280523+00:00"},
    \\ "seven_day_opus":null,"extra_usage":{"is_enabled":false},
    \\ "limits":[{"kind":"session","group":"session","percent":95,"severity":"critical","resets_at":"2026-09-12T20:20:00.280504+00:00","scope":null,"is_active":true},
    \\   {"kind":"weekly_all","group":"weekly","percent":52,"severity":"normal","resets_at":"2026-09-19T05:00:00.280523+00:00","scope":null,"is_active":false},
    \\   {"kind":"weekly_scoped","group":"weekly","percent":55,"severity":"normal","resets_at":"2026-09-19T05:00:00.280703+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],
    \\ "spend":{"used":{"amount_minor":0,"currency":"USD"},"percent":0}}
;

/// An older tier: no top-level windows, `limits[]` only.
pub const usage_limits_only_fixture =
    \\{"limits":[{"kind":"session","percent":12,"resets_at":"2026-09-12T18:00:00Z"},{"kind":"weekly_all","percent":3,"resets_at":"2026-09-15T05:00:00Z"}]}
;

/// The 2026-09 shape, every field the parser reads plus the ones it only
/// names (values invented): a weekly window per model at the top level,
/// a live window under a codename at 0 %, a locked window, the extra
/// usage block, the severities, and `omelette_promotional` carrying two
/// clocks — a codename, read like any other: it is no limit-reset offer
/// (see `Usage`'s note on the grants).
pub const usage_wide_fixture =
    \\{"five_hour":{"utilization":88.0,"resets_at":"2026-09-12T22:00:00+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},
    \\ "seven_day":{"utilization":61.0,"resets_at":"2026-09-19T05:00:00+00:00","locked_reason":"weekly_limit_reached"},
    \\ "seven_day_oauth_apps":null,"seven_day_opus":null,
    \\ "seven_day_sonnet":{"utilization":30.0,"resets_at":"2026-09-19T05:00:00+00:00","locked_reason":null},
    \\ "seven_day_cowork":{"utilization":12.0,"resets_at":null},
    \\ "tangelo":null,"iguana_necktie":null,
    \\ "omelette_promotional":{"resets_at":"2026-09-12T21:00:00+00:00","expires_at":"2026-09-13T04:00:00+00:00"},
    \\ "nimbus_quill":{"utilization":0.0,"resets_at":null,"limit_dollars":null,"locked_reason":null},
    \\ "copper_kite":{"state":"new"},
    \\ "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":"USD","decimal_places":2,"disabled_reason":"org_level_disabled_until","user_disabled":false},
    \\ "limits":[{"kind":"session","group":"session","percent":88,"severity":"warning","resets_at":"2026-09-12T22:00:00+00:00","scope":null,"is_active":true},
    \\   {"kind":"weekly_all","group":"weekly","percent":61,"severity":"critical","resets_at":"2026-09-19T05:00:00+00:00","scope":null,"is_active":false},
    \\   {"kind":"weekly_scoped","group":"weekly","percent":30,"severity":"normal","resets_at":"2026-09-19T05:00:00+00:00","scope":{"model":{"id":null,"display_name":"Sonnet"},"surface":null},"is_active":false}],
    \\ "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"percent":0,"severity":"normal","enabled":false},
    \\ "member_dashboard_available":false,"seven_day_breakdown":null}
;

/// `seven_day_breakdown` as the endpoint sends it (values invented): the
/// week split by surface, a row with no `display_name`, and an
/// `extra_usage` whose currency, places and reason are all null.
pub const usage_breakdown_fixture =
    \\{"five_hour":{"utilization":20.0,"resets_at":"2026-09-12T22:00:00+00:00"},
    \\ "seven_day":{"utilization":47.0,"resets_at":"2026-09-19T05:00:00+00:00"},
    \\ "extra_usage":{"is_enabled":null,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null,"decimal_places":null,"disabled_reason":null},
    \\ "seven_day_breakdown":{"as_of":"2026-09-12T19:55:00+00:00","window_started_at":"2026-09-12T05:00:00+00:00",
    \\   "rows":[{"key":"claude_code","display_name":"Claude Code","percent":31.4},{"key":"chat","display_name":"Chat","percent":9},
    \\          {"key":"cowork","display_name":"Cowork","percent":5.0},{"key":"other","percent":2}]}}
;

pub const profile_fixture =
    \\{"account":{"uuid":"00000000-0000-4000-8000-000000000000","full_name":"Test User","display_name":"Test","email":"me@example.com","has_claude_max":true},
    \\ "organization":{"uuid":"00000000-0000-4000-8000-000000000001","name":"me@example.com's Organization","organization_type":"claude_max"}}
;

pub const token_blob_fixture =
    \\{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FIXTURE-ACCESS","refreshToken":"sk-ant-ort01-FIXTURE-REFRESH","expiresAt":1789200000000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
;

test "parseIso8601: the endpoint's shapes, offsets and junk" {
    try t.expectEqual(@as(?u64, 1789244400), parseIso8601("2026-09-12T20:20:00.280504+00:00"));
    try t.expectEqual(@as(?u64, 1789244400), parseIso8601("2026-09-12T20:20:00Z"));
    try t.expectEqual(@as(?u64, 1789244400 - 3600), parseIso8601("2026-09-12T20:20:00+01:00"));
    try t.expectEqual(@as(?u64, 1789244400 + 1800), parseIso8601("2026-09-12T20:20:00-0030"));
    try t.expectEqual(@as(?u64, 0), parseIso8601("1970-01-01T00:00:00Z"));
    try t.expect(parseIso8601("2026-09-12") == null);
    try t.expect(parseIso8601("2026-13-12T20:20:00Z") == null);
    try t.expect(parseIso8601("2026-09-12T20:20:00+x") == null);
}

test "civil dates round-trip" {
    try t.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try t.expectEqual(@as(i64, 20708), daysFromCivil(2026, 9, 12));
    const c = civilFromDays(20708);
    try t.expectEqual(@as(i64, 2026), c.y);
    try t.expectEqual(@as(u32, 9), c.m);
    try t.expectEqual(@as(u32, 12), c.d);
    const leap = civilFromDays(daysFromCivil(2024, 2, 29));
    try t.expectEqual(@as(u32, 2), leap.m);
    try t.expectEqual(@as(u32, 29), leap.d);
}

test "parseUsage: the windows, the scoped row, the limits-only fallback, junk" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try parseUsage(a, usage_fixture, 1789243232);
    try t.expectEqual(@as(u16, 95), u.percent);
    try t.expectEqual(@as(u16, 52), u.weekly_percent);
    try t.expectEqual(@as(u64, 1789244400), u.resets_at);
    try t.expectEqual(@as(u64, 1789794000), u.weekly_resets_at);
    try t.expectEqual(@as(usize, 1), u.scoped.len);
    try t.expectEqualStrings("Fable", u.scoped[0].model);
    try t.expectEqual(@as(u16, 55), u.scoped[0].percent);
    try t.expectEqual(@as(u64, 1789243232), u.fetched_at);
    try t.expect(u.last_error == null);
    const l = try parseUsage(a, usage_limits_only_fixture, 1);
    try t.expectEqual(@as(u16, 12), l.percent);
    try t.expectEqual(@as(u16, 3), l.weekly_percent);
    try t.expectEqual(@as(u64, 1789236000), l.resets_at);
    try t.expectEqual(@as(usize, 0), l.scoped.len);
    const z = try parseUsage(a, "{}", 1);
    try t.expect(z.isEmpty());
    try t.expectError(error.BadJson, parseUsage(a, "nope", 1));
    try t.expectError(error.BadJson, parseUsage(a, "[1]", 1));
}

test "parseUsage: the wire's newer fields — severity, is_active, locked_reason, extra usage, windows it does not name, the keys to learn; a codename is never a reset offer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try parseUsage(a, usage_wide_fixture, 1789243232);
    try t.expectEqual(@as(u16, 88), u.percent);
    try t.expectEqual(Severity.warning, u.severity.?);
    try t.expectEqual(Severity.critical, u.weekly_severity.?);
    try t.expect(u.session_active and !u.weekly_active);
    try t.expect(u.locked_reason == null);
    try t.expectEqualStrings("weekly_limit_reached", u.weekly_locked_reason.?);
    try t.expectEqual(Severity.normal, u.scoped[0].severity.?);
    // `seven_day_sonnet` is the scoped Sonnet row already; `seven_day_cowork`
    // is new — a window titled from its key; `nimbus_quill` at 0 % with no
    // reset stays quiet; `copper_kite` is no window at all. The codename
    // `omelette_promotional` carries a clock, so it is a window like any
    // other unknown slot — titled from its key, never "Limit reset".
    try t.expectEqual(@as(usize, 2), u.windows.len);
    try t.expectEqualStrings("seven_day_cowork", u.windows[0].key);
    try t.expectEqualStrings("Current week (Cowork)", u.windows[0].title);
    try t.expectEqual(@as(u16, 12), u.windows[0].percent);
    try t.expectEqualStrings("omelette_promotional", u.windows[1].key);
    try t.expectEqualStrings("Omelette promotional", u.windows[1].title);
    try t.expectEqual(@as(u16, 0), u.windows[1].percent);
    // Extra usage: off, and why.
    try t.expect(!u.extra_usage.?.enabled);
    try t.expectEqualStrings("org_level_disabled_until", u.extra_usage.?.reason.?);
    try t.expect(u.extra_usage.?.percent == null);
    // Every non-null top-level key the parser does not name, to be logged —
    // the codename included: nothing here maps one to a reset offer.
    for ([_][]const u8{ "seven_day_sonnet", "seven_day_cowork", "omelette_promotional", "nimbus_quill", "copper_kite" }) |k| {
        const found = for (u.unknown_keys) |x| {
            if (std.mem.eql(u8, x, k)) break true;
        } else false;
        try t.expect(found);
    }
    for (u.unknown_keys) |x| {
        try t.expect(!std.mem.eql(u8, x, "tangelo")); // null
        try t.expect(!std.mem.eql(u8, x, "five_hour")); // named
    }
    // The old shape has none of it.
    const old = try parseUsage(a, usage_limits_only_fixture, 1);
    try t.expect(old.extra_usage == null and old.windows.len == 0 and old.severity == null);
    try t.expectEqualStrings("Nimbus quill", try humanKey(a, "nimbus_quill"));
    try t.expectEqualStrings("Current session (Burst)", try humanKey(a, "five_hour_burst"));
    try t.expectEqualStrings("Current week (Oauth apps)", try humanKey(a, "seven_day_oauth_apps"));
}

test "parseUsage: seven_day_breakdown — a row per surface of the week, the time it was taken; null, rowless or absent is none; extra_usage's null fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try parseUsage(a, usage_breakdown_fixture, 1789243232);
    const b = u.breakdown.?;
    try t.expectEqual(parseIso8601("2026-09-12T19:55:00+00:00").?, b.as_of);
    try t.expectEqual(parseIso8601("2026-09-12T05:00:00+00:00").?, b.window_started_at);
    try t.expectEqual(@as(usize, 4), b.rows.len);
    try t.expectEqualStrings("claude_code", b.rows[0].key);
    try t.expectEqualStrings("Claude Code", b.rows[0].name);
    try t.expectEqual(@as(u16, 31), b.rows[0].percent);
    try t.expectEqual(@as(u16, 9), b.rows[1].percent);
    // No display name: titled from the key.
    try t.expectEqualStrings("Other", b.rows[3].name);
    // The key is named: never an unknown slot, never a window.
    try t.expectEqual(@as(usize, 0), u.unknown_keys.len);
    try t.expectEqual(@as(usize, 0), u.windows.len);
    // Every sub-field of extra_usage null: off, no reason, no percent.
    try t.expect(!u.extra_usage.?.enabled);
    try t.expect(u.extra_usage.?.reason == null and u.extra_usage.?.percent == null);
    // The accounts that send none.
    try t.expect((try parseUsage(a, usage_fixture, 1)).breakdown == null);
    try t.expect((try parseUsage(a, usage_wide_fixture, 1)).breakdown == null);
    try t.expect((try parseUsage(a, "{\"seven_day_breakdown\":{\"as_of\":null,\"rows\":[]}}", 1)).breakdown == null);
    try t.expect((try parseUsage(a, "{\"seven_day_breakdown\":{\"rows\":null}}", 1)).breakdown == null);
    // No time: the rows still land, the stamp is zero.
    const nt = try parseUsage(a, "{\"seven_day_breakdown\":{\"as_of\":null,\"rows\":[{\"key\":\"chat\",\"display_name\":\"Chat\",\"percent\":3}]}}", 1);
    try t.expectEqual(@as(u64, 0), nt.breakdown.?.as_of);
    try t.expectEqual(@as(usize, 1), nt.breakdown.?.rows.len);
}

test "parseProfile and the token blob fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = (try parseProfile(a, profile_fixture)).?;
    try t.expectEqualStrings("me@example.com", p.email.?);
    try t.expectEqualStrings("me@example.com's Organization", p.org.?);
    try t.expect((try parseProfile(a, "{\"account\":{}}")) == null);
    try t.expect((try parseProfile(a, "junk")) == null);
    try t.expectEqualStrings("sk-ant-oat01-FIXTURE-ACCESS", accessTokenOf(a, token_blob_fixture).?);
    try t.expectEqualStrings("sk-ant-ort01-FIXTURE-REFRESH", refreshTokenOf(a, token_blob_fixture).?);
    try t.expectEqualStrings("sk-ant-plain", accessTokenOf(a, "  sk-ant-plain\n").?);
    try t.expect(refreshTokenOf(a, "sk-ant-plain") == null);
    try t.expectEqualStrings("x", accessTokenOf(a, "{\"accessToken\":\"x\"}").?);
    try t.expect(accessTokenOf(a, "{\"nope\":1}") == null);
    try t.expect(accessTokenOf(a, "") == null);
}

test "applyFetchError: the numbers survive, the backoff doubles to an hour, a zero hint is no hint" {
    var u: Usage = .{ .percent = 40, .weekly_percent = 10, .fetched_at = 100 };
    applyFetchError(&u, .{ .message = "HTTP 429: slow down", .retry_after = 0 }, 1000);
    try t.expectEqual(@as(u16, 40), u.percent);
    try t.expectEqual(@as(u64, 1000 + 600), u.retry_after_at);
    try t.expectEqualStrings("HTTP 429: slow down", u.last_error.?);
    applyFetchError(&u, .{ .message = "again" }, 2000);
    try t.expectEqual(@as(u64, 2000 + 1200), u.retry_after_at);
    applyFetchError(&u, .{ .message = "again" }, 3000);
    applyFetchError(&u, .{ .message = "again" }, 4000);
    applyFetchError(&u, .{ .message = "again" }, 5000);
    try t.expectEqual(@as(u64, 5000 + 3600), u.retry_after_at);
    applyFetchError(&u, .{ .message = "hint", .retry_after = 300 }, 6000);
    try t.expectEqual(@as(u64, 6300), u.retry_after_at);
    try t.expect(!u.needs_reauth);
    applyFetchError(&u, .{ .message = "other login", .needs_reauth = true }, 7000);
    try t.expect(u.needs_reauth);
    applyFetchError(&u, .{ .message = "plain" }, 8000);
    try t.expect(!u.needs_reauth);
}

test "intervalFor: hot only for the active account at 90–99, short before the first read" {
    try t.expectEqual(refresh_interval_s, intervalFor(false, 95, 0));
    try t.expectEqual(idle_interval_s, intervalFor(false, 95, 5));
    try t.expectEqual(hot_interval_s, intervalFor(true, 95, 5));
    try t.expectEqual(refresh_interval_s, intervalFor(true, 100, 5));
    try t.expectEqual(refresh_interval_s, intervalFor(true, 40, 5));
}

test "accountsFromConfig: the default account, one active, ~ and relative paths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const E = struct { name: []const u8, token_path: []const u8, active: bool };
    const none = try accountsFromConfig(a, &[_]E{}, "/data", "/home/me");
    try t.expectEqual(@as(usize, 1), none.len);
    try t.expectEqualStrings("default", none[0].name);
    try t.expectEqualStrings("/data/ai_token", none[0].token_path);
    try t.expect(none[0].active);
    const three = try accountsFromConfig(a, &[_]E{
        .{ .name = "personal", .token_path = "ai_token.personal", .active = false },
        .{ .name = "work", .token_path = "~/.claude/work.json", .active = true },
        .{ .name = "consulting", .token_path = "/abs/tok", .active = true },
    }, "/data", "/home/me");
    try t.expectEqualStrings("/data/ai_token.personal", three[0].token_path);
    try t.expectEqualStrings("/home/me/.claude/work.json", three[1].token_path);
    try t.expectEqualStrings("/abs/tok", three[2].token_path);
    try t.expect(!three[0].active and three[1].active and !three[2].active);
    const none_active = try accountsFromConfig(a, &[_]E{ .{ .name = "", .token_path = "", .active = false }, .{ .name = "b", .token_path = "", .active = false } }, "/data", null);
    try t.expectEqualStrings("default", none_active[0].name);
    try t.expect(none_active[0].active and !none_active[1].active);
}

test "the fixture directory: ok, error, needs-reauth, not linked, codex, accounts, now" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "personal.json", .data = usage_fixture });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "personal.profile.json", .data = profile_fixture });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "work.error", .data = "HTTP 429 retry-after=120\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "consulting.error", .data = "needs-reauth: the keychain login is other@example.com, not consulting's\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "codex.json", .data = "{\"tokens_today\":1234567,\"sessions_today\":3}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "# two\npersonal\n*work\nconsulting\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "now", .data = "1789243232\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tz_offset", .data = "-25200" });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try fetchFixture(a, t.io, dir, "personal", 7);
    try t.expectEqual(@as(u16, 95), ok.ok.usage.percent);
    try t.expectEqual(@as(u64, 7), ok.ok.usage.fetched_at);
    try t.expectEqualStrings("me@example.com", ok.ok.email.?);
    const e = try fetchFixture(a, t.io, dir, "work", 7);
    try t.expectEqualStrings("HTTP 429 retry-after=120", e.err.message);
    try t.expectEqual(@as(?u64, 120), e.err.retry_after);
    const r = try fetchFixture(a, t.io, dir, "consulting", 7);
    try t.expect(r.err.needs_reauth);
    try t.expect(std.mem.startsWith(u8, r.err.message, "the keychain login is other@example.com"));
    const nl = try fetchFixture(a, t.io, dir, "ghost", 7);
    try t.expectEqualStrings("not linked", nl.err.message);
    const c = try fetchCodexFixture(a, t.io, dir, 9);
    try t.expectEqual(@as(u64, 1234567), c.ok.tokens_today);
    try t.expectEqual(@as(u64, 3), c.ok.sessions_today);
    const accts = (try fixtureAccounts(a, t.io, dir)).?;
    try t.expectEqual(@as(usize, 3), accts.len);
    try t.expectEqualStrings("personal", accts[0].name);
    try t.expect(!accts[0].active and accts[1].active and !accts[2].active);
    try t.expectEqual(@as(?u64, 1789243232), fixtureNow(t.io, dir));
    try t.expectEqual(@as(?i64, -25200), fixtureTz(t.io, dir));
    try t.expect((try fixtureAccounts(a, t.io, "/nope/none")) == null);
    try t.expect(fixtureNow(t.io, "/nope/none") == null);
    const nc = try fetchCodexFixture(a, t.io, "/nope/none", 9);
    try t.expectEqualStrings("~/.codex/sessions not found", nc.err);
}

test "sumCodexJsonl sums the deltas only; fetchCodexLive walks today's files" {
    const two_turns =
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"total_token_usage":{"total_tokens":120}}}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"output_tokens":50},"total_token_usage":{"total_tokens":470}}}}
        \\{"type":"session_meta","payload":{"cwd":"/w"}}
        \\not json
    ;
    try t.expectEqual(@as(u64, 470), try sumCodexJsonl(t.allocator, two_turns));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const home = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, ".codex/sessions/2026/09/12");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/12/rollout-a.jsonl", .data = two_turns });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/12/rollout-b.jsonl", .data = two_turns });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/12/notes.txt", .data = "x" });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const now: u64 = @intCast(@max(Io.Timestamp.now(t.io, .real).toSeconds(), 0));
    const today = try fetchCodexLive(t.allocator, t.io, arena.allocator(), home, now);
    try t.expectEqual(@as(u64, 940), today.ok.tokens_today);
    try t.expectEqual(@as(u64, 2), today.ok.sessions_today);
    // Files not touched today are not this day's.
    const other = try fetchCodexLive(t.allocator, t.io, arena.allocator(), home, now + 3 * 86400);
    try t.expectEqual(@as(u64, 0), other.ok.sessions_today);
    const missing = try fetchCodexLive(t.allocator, t.io, arena.allocator(), "/nope/none", now);
    try t.expectEqualStrings("~/.codex/sessions not found", missing.err);
}

test "formatting: the reset clocks, the suffix, thousands" {
    var buf: [32]u8 = undefined;
    // 2026-09-12T20:20:00Z at -07:00 is 1:20pm; at +00:00 8:20pm.
    try t.expectEqualStrings("1:20pm", fmtShortTime(&buf, 1789244400, -7 * 3600));
    try t.expectEqualStrings("8:20pm", fmtShortTime(&buf, 1789244400, 0));
    try t.expectEqualStrings("12am", fmtShortTime(&buf, 0, 0));
    try t.expectEqualStrings("12pm", fmtShortTime(&buf, 12 * 3600, 0));
    try t.expectEqualStrings("Sep 19 at 5am", fmtLongTime(&buf, 1789794000, 0));
    try t.expectEqualStrings("Sep 18 at 10pm", fmtLongTime(&buf, 1789794000, -7 * 3600));
    try t.expectEqualStrings(" 5h", fmtResetSuffix(&buf, 0, 100, "5h"));
    try t.expectEqualStrings(" 7d", fmtResetSuffix(&buf, 50, 100, "7d"));
    try t.expectEqualStrings(" <1m", fmtResetSuffix(&buf, 130, 100, "5h"));
    try t.expectEqualStrings(" 45m", fmtResetSuffix(&buf, 100 + 45 * 60 + 5, 100, "5h"));
    try t.expectEqualStrings(" 3h", fmtResetSuffix(&buf, 100 + 3 * 3600 + 5, 100, "5h"));
    try t.expectEqualStrings(" 4d", fmtResetSuffix(&buf, 100 + 4 * 86400 + 5, 100, "7d"));
    try t.expectEqualStrings("0", fmtThousands(&buf, 0));
    try t.expectEqualStrings("999", fmtThousands(&buf, 999));
    try t.expectEqualStrings("1,000", fmtThousands(&buf, 1000));
    try t.expectEqualStrings("1,234,567", fmtThousands(&buf, 1_234_567));
    try t.expectEqualStrings("1,000,000,000", fmtThousands(&buf, 1_000_000_000));
}

test "singleChip per detail, with the reset suffix, stale and unread" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: u64 = 1789243232;
    const u: Usage = .{ .percent = 24, .weekly_percent = 62, .resets_at = now + 3 * 3600 + 10, .weekly_resets_at = now + 4 * 86400 + 10, .fetched_at = now };
    try t.expectEqualStrings(" G 24% 62% ", try singleChip(a, &u, null, .{ .glyph = "G", .now = now }));
    try t.expectEqualStrings(" G 24% ", try singleChip(a, &u, null, .{ .glyph = "G", .detail = .session, .now = now }));
    try t.expectEqualStrings(" G 62% ", try singleChip(a, &u, null, .{ .glyph = "G", .detail = .weekly, .now = now }));
    try t.expectEqualStrings(" G P 24% 3h 62% 4d ", try singleChip(a, &u, 'P', .{ .glyph = "G", .show_reset = true, .now = now }));
    var stale = u;
    stale.last_error = "HTTP 429";
    try t.expectEqualStrings(" G 24% 62%! ", try singleChip(a, &stale, null, .{ .glyph = "G", .now = now }));
    try t.expectEqualStrings(" G — ", try singleChip(a, &Usage{}, null, .{ .glyph = "G", .now = now }));
    try t.expectEqualStrings(" G C —! ", try singleChip(a, &Usage{ .last_error = "x" }, 'C', .{ .glyph = "G", .now = now }));
    // A window the endpoint gave no reset for shows its nominal length.
    const fresh: Usage = .{ .fetched_at = now };
    try t.expectEqualStrings(" G 0% 5h 0% 7d ", try singleChip(a, &fresh, null, .{ .glyph = "G", .show_reset = true, .now = now }));
}

test "compactChip: the sparkline, the arrow to the urgent account, the reset fallback, errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: u64 = 1789243232;
    const none = try compactChip(a, &.{}, .{ .glyph = "G", .now = now });
    try t.expectEqualStrings(" G … ", none.text);
    // personal has 60 % left over 2 h (30/h); work 90 % left over 20 h (4.5/h): → P.
    const pw = [_]ChipAccount{
        .{ .name = "personal", .usage = .{ .percent = 40, .resets_at = now + 2 * 3600, .fetched_at = now }, .is_active = true },
        .{ .name = "work", .usage = .{ .percent = 10, .resets_at = now + 20 * 3600, .fetched_at = now }, .is_active = false },
    };
    const c = try compactChip(a, &pw, .{ .glyph = "G", .now = now });
    try t.expectEqualStrings(" G ▃▁ →P ", c.text);
    try t.expectEqual(@as(u16, 40), c.worst);
    try t.expect(c.any_fetched and !c.any_error);
    // No clear winner: the first reset instead.
    const even = [_]ChipAccount{
        .{ .name = "personal", .usage = .{ .percent = 40, .resets_at = now + 5 * 3600, .fetched_at = now }, .is_active = true },
        .{ .name = "work", .usage = .{ .percent = 40, .resets_at = now + 5 * 3600 + 60, .fetched_at = now }, .is_active = false },
    };
    try t.expectEqualStrings(" G ▃▃ ⟳5h ", (try compactChip(a, &even, .{ .glyph = "G", .now = now })).text);
    // Both near-empty: relief in Xh; a stale reading keeps its bar and adds `!`; one never read is `!`.
    const mixed = [_]ChipAccount{
        .{ .name = "personal", .usage = .{ .percent = 95, .resets_at = now + 3600 + 5, .fetched_at = now, .last_error = "HTTP 429" }, .is_active = true },
        .{ .name = "work", .usage = .{ .percent = 100, .resets_at = now + 7200, .fetched_at = now }, .is_active = false },
    };
    const m = try compactChip(a, &mixed, .{ .glyph = "G", .now = now });
    try t.expectEqualStrings(" G ▇█! ⟳1h ", m.text);
    const never = [_]ChipAccount{
        .{ .name = "personal", .usage = .{ .last_error = "no token" }, .is_active = true },
        .{ .name = "work", .usage = .{}, .is_active = false },
    };
    const n = try compactChip(a, &never, .{ .glyph = "G", .now = now });
    try t.expectEqualStrings(" G !… ", n.text);
    try t.expect(n.any_error and !n.any_fetched);
    try t.expectEqual(@as(usize, 0), tickerIndex(now, 2));
    try t.expectEqual(@as(usize, 1), tickerIndex(now + 4, 2));
    try t.expectEqual(@as(usize, 0), tickerIndex(now, 0));
    try t.expectEqual(@as(u8, 'P'), abbrev("personal"));
    try t.expectEqual(@as(u8, '?'), abbrev(""));
}

test "identity pins: learned once, a shared login is a warning; the active account by refresh token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try pinnedEmail(a, t.io, root, "personal")) == null);
    try t.expect((try pinIdentity(a, t.io, root, "personal", "me@example.com")) == null);
    try t.expectEqualStrings("me@example.com", (try pinnedEmail(a, t.io, root, "personal")).?);
    try t.expect((try pinIdentity(a, t.io, root, "personal", "me@example.com")) == null);
    const warn = (try pinIdentity(a, t.io, root, "work", "me@example.com")).?;
    try t.expect(std.mem.indexOf(u8, warn, "personal and work share one login") != null);
    try t.expect((try pinnedEmail(a, t.io, root, "work")) == null);
    try t.expect((try pinIdentity(a, t.io, root, "work", "w@example.com")) == null);
    try t.expectEqualStrings("me@example.com", (try pinnedEmail(a, t.io, root, "personal")).?);
    // The refresh token names the CLI's account.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ai_token.personal", .data = token_blob_fixture });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ai_token.work", .data = "sk-ant-plain" });
    const accts = [_]AccountCfg{
        .{ .name = "work", .token_path = try std.fs.path.join(a, &.{ root, "ai_token.work" }), .active = true },
        .{ .name = "personal", .token_path = try std.fs.path.join(a, &.{ root, "ai_token.personal" }), .active = false },
    };
    try t.expectEqualStrings("personal", (try accountOfRefreshToken(a, t.io, &accts, "sk-ant-ort01-FIXTURE-REFRESH")).?);
    try t.expect((try accountOfRefreshToken(a, t.io, &accts, "other")) == null);
}

test "redactBearer scrubs token runs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("bad header: <redacted> and <redacted>.", try redactBearer(arena.allocator(), "bad header: Bearer sk-ant-oat01-abcdefgh and sk-ant-oat01-zzzzzzzz."));
    try t.expectEqualStrings("sk-1 ok", try redactBearer(arena.allocator(), "sk-1 ok"));
}

/// A loopback usage server: answers the usage and profile paths from
/// fixtures, a 429 with a hint on demand, 401 for a wrong bearer.
const FakeServer = struct {
    var saw_auth: [128]u8 = undefined;
    var saw_auth_len: usize = 0;
    var mode: enum { ok, throttle } = .ok;

    fn serve(io: Io, server: *Io.net.Server) Io.Cancelable!void {
        while (true) {
            const stream = server.accept(io) catch return;
            defer stream.close(io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var reader = stream.reader(io, &rbuf);
            var writer = stream.writer(io, &wbuf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            var auth: []const u8 = "";
            var it = request.iterateHeaders();
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                auth = h.value;
            };
            @memcpy(saw_auth[0..auth.len], auth);
            saw_auth_len = auth.len;
            const target = request.head.target;
            if (mode == .throttle) {
                request.respond("{\"error\":\"rate_limit_error\"}", .{ .status = .too_many_requests, .extra_headers = &.{.{ .name = "retry-after", .value = "3150" }} }) catch return;
            } else if (!std.mem.eql(u8, auth, "Bearer sk-ant-oat01-FIXTURE-ACCESS")) {
                request.respond("{\"error\":\"unauthorized\"}", .{ .status = .unauthorized }) catch return;
            } else if (std.mem.endsWith(u8, target, "/profile")) {
                request.respond(profile_fixture, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch return;
            } else {
                request.respond(usage_fixture, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch return;
            }
        }
    }
};

test "fetchLive against a loopback server: the bearer, the numbers, the profile, the pin, a 429's hint, a rejected token" {
    const io = t.io;
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var group: Io.Group = .init;
    try group.concurrent(io, FakeServer.serve, .{ io, &server });
    defer group.cancel(io);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ai_token", .data = token_blob_fixture });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ai_token.bad", .data = "sk-ant-oat01-WRONG-TOKEN" });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const live: Live = .{
        .data_root = root,
        .account_count = 1,
        .usage_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api/oauth/usage", .{port}),
        .profile_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api/oauth/profile", .{port}),
        .token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/oauth/token", .{port}),
        .keychain = false,
    };
    const tok = try std.fs.path.join(a, &.{ root, "ai_token" });
    const ok = try fetchLive(t.allocator, io, a, live, "default", tok, 77);
    try t.expectEqualStrings("Bearer sk-ant-oat01-FIXTURE-ACCESS", FakeServer.saw_auth[0..FakeServer.saw_auth_len]);
    try t.expectEqual(@as(u16, 95), ok.ok.usage.percent);
    try t.expectEqual(@as(u16, 52), ok.ok.usage.weekly_percent);
    try t.expectEqual(@as(u64, 77), ok.ok.usage.fetched_at);
    try t.expectEqualStrings("me@example.com", ok.ok.email.?);
    try t.expect(ok.ok.warning == null);
    try t.expectEqualStrings("me@example.com", (try pinnedEmail(a, t.io, root, "default")).?);
    // The last response is on disk, under cache/, for ai.show_last_response.
    const last = try tmp.dir.readFileAlloc(t.io, "cache/" ++ last_response_file, a, .limited(1 << 20));
    try t.expect(std.mem.startsWith(u8, last, "// HTTP 200\n// fetched_at: 77\n"));
    // A wrong token, no refresh token, no keychain: rejected.
    const bad = try fetchLive(t.allocator, io, a, live, "default", try std.fs.path.join(a, &.{ root, "ai_token.bad" }), 78);
    try t.expectEqualStrings("HTTP 401: token rejected — re-link via :ai.link_claude_token", bad.err.message);
    try t.expect(bad.err.retry_after == null);
    // A 429 carries the server's hint.
    FakeServer.mode = .throttle;
    defer FakeServer.mode = .ok;
    const throttled = try fetchLive(t.allocator, io, a, live, "default", tok, 79);
    try t.expect(std.mem.startsWith(u8, throttled.err.message, "HTTP 429: "));
    try t.expectEqual(@as(?u64, 3150), throttled.err.retry_after);
    // No token file at all.
    const none = try fetchLive(t.allocator, io, a, live, "default", try std.fs.path.join(a, &.{ root, "ai_token.none" }), 80);
    try t.expect(std.mem.startsWith(u8, none.err.message, "read token "));
}
