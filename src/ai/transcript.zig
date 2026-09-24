//! Session transcripts on disk — what the agents dashboard and the
//! spend report both read. Claude Code writes
//! `~/.claude/projects/<encoded-workspace>/<session>.jsonl`, one event
//! per line; Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`.
//! Both are parsed here into one `Stats`, line by line on a scratch arena
//! so a 200 MB transcript costs one line of memory at a time.
//!
//! Pricing is a table by model, dollars per million tokens; tokens spent
//! on an unknown model make the cost unknown (`Stats.priced`) rather than
//! a wrong number — never a $0.00 that reads as free.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Stats = struct {
    cwd: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// input + output, every assistant event seen.
    tokens: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_create_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    event_count: usize = 0,
    /// The session's first prompt — what it was started to do, and what
    /// names it when nothing else does (`sessions.nameOf`).
    first_user_msg: ?[]const u8 = null,
    last_user_msg: ?[]const u8 = null,
    last_assistant_msg: ?[]const u8 = null,
    /// The last assistant turn was a tool call still waiting on its result.
    last_was_tool_call: bool = false,
    last_tool_name: ?[]const u8 = null,
    pending_tool_uses: usize = 0,
    /// The transcript ends on an error: Claude Code's `isApiErrorMessage`
    /// assistant turn, or a `result` event with `is_error` — what makes
    /// a session without a process `failed` rather than `done`.
    last_error: bool = false,

    /// Claude: the usage summed message by message, each at its own
    /// model's price, every message counted once (`Usage`). Null for a
    /// Codex rollout, whose running totals are priced by `model`.
    usage: ?Usage = null,

    pub fn costUsd(s: Stats) f64 {
        if (s.usage) |u| return u.cost_usd;
        return estimateCost(s.model orelse "", s.input_tokens, s.output_tokens, s.cache_create_tokens, s.cache_read_tokens);
    }

    /// Whether every token has a price: false when some were spent on a
    /// model the price table does not know, so the cost is not a number
    /// to show (`n/a`, never a $0.00 that reads as free).
    pub fn priced(s: Stats) bool {
        if (s.usage) |u| return !u.unpriced;
        return s.tokens == 0 or knownPrice(s.model orelse "") != null;
    }
};

/// Claude Code's usage, summed over a transcript. Claude Code writes one
/// assistant message as several JSONL lines — one per content block —
/// and every line repeats the message's id and its whole usage, so a
/// message is counted the first time its id is seen and never again.
/// The repeats follow each other closely, so the ids of the last
/// `recent_ids` messages are what is remembered; `add` can be fed a
/// transcript in pieces (the scan's per-file cache does).
pub const Usage = struct {
    tokens: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_create_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    /// Each message at its own model's price.
    cost_usd: f64 = 0,
    /// Some tokens were spent on a model with no price.
    unpriced: bool = false,
    ids: [recent_ids][id_cap]u8 = undefined,
    id_lens: [recent_ids]u8 = @splat(0),
    next_id: u8 = 0,

    pub const recent_ids = 16;
    const id_cap = 64;

    fn seen(u: *const Usage, id: []const u8) bool {
        if (id.len == 0 or id.len > id_cap) return false;
        for (u.id_lens, 0..) |n, i| if (n == id.len and std.mem.eql(u8, u.ids[i][0..n], id)) return true;
        return false;
    }

    fn remember(u: *Usage, id: []const u8) void {
        if (id.len == 0 or id.len > id_cap) return;
        const at = u.next_id;
        @memcpy(u.ids[at][0..id.len], id);
        u.id_lens[at] = @intCast(id.len);
        u.next_id = (at + 1) % recent_ids;
    }

    /// One assistant message's `message` object: its usage, unless its
    /// id was already counted.
    pub fn addMessage(u: *Usage, m: std.json.Value) void {
        if (m != .object) return;
        const usage = m.object.get("usage") orelse return;
        if (str(m, "id")) |id| {
            if (u.seen(id)) return;
            u.remember(id);
        }
        const i = int(usage, "input_tokens");
        const o = int(usage, "output_tokens");
        const cw = int(usage, "cache_creation_input_tokens");
        const cr = int(usage, "cache_read_input_tokens");
        u.tokens +|= i + o;
        u.input_tokens +|= i;
        u.output_tokens +|= o;
        u.cache_create_tokens +|= cw;
        u.cache_read_tokens +|= cr;
        const model = str(m, "model") orelse "";
        if (knownPrice(model)) |p| {
            u.cost_usd += costAt(p, i, o, cw, cr);
        } else if (i + o + cw + cr > 0) u.unpriced = true;
    }

    /// Every assistant line of `text` (whole lines), on a scratch arena
    /// reset per line. Lines without `"usage"` are not parsed at all.
    pub fn addText(u: *Usage, gpa: Allocator, text: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (std.mem.indexOf(u8, raw, "\"usage\"") == null) continue;
            const line = std.mem.trim(u8, raw, " \r\t");
            _ = scratch.reset(.retain_capacity);
            const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
            if (!std.mem.eql(u8, str(v, "type") orelse "", "assistant")) continue;
            u.addMessage(v.object.get("message") orelse continue);
        }
    }
};

/// How much of a message the dashboard keeps.
pub const msg_cap: usize = 200;

/// Claude Code's JSONL. Every kept string is duped onto `arena`; the
/// line itself is parsed on a scratch arena reset per line.
pub fn parseClaude(arena: Allocator, text: []const u8) Allocator.Error!Stats {
    var st: Stats = .{};
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    defer pending.deinit(arena);
    var usage: Usage = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        st.event_count += 1;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        if (v != .object) continue;
        if (str(v, "cwd")) |c| st.cwd = try arena.dupe(u8, c);
        if (str(v, "gitBranch")) |b| st.git_branch = try arena.dupe(u8, b);
        const ty = str(v, "type") orelse "";
        const msg = v.object.get("message");
        if (std.mem.eql(u8, ty, "result")) {
            st.last_error = boolean(v, "is_error");
            continue;
        }
        if (std.mem.eql(u8, ty, "assistant")) {
            st.last_was_tool_call = false;
            st.last_error = boolean(v, "isApiErrorMessage");
            const m = msg orelse continue;
            if (str(m, "model")) |model| st.model = try arena.dupe(u8, model);
            usage.addMessage(m);
            const content = (if (m == .object) m.object.get("content") else null) orelse continue;
            if (content != .array) continue;
            var text_seen: ?[]const u8 = null;
            var tool_seen: ?[]const u8 = null;
            for (content.array.items) |block| {
                const bt = str(block, "type") orelse "";
                if (std.mem.eql(u8, bt, "text")) {
                    if (text_seen == null) text_seen = str(block, "text");
                } else if (std.mem.eql(u8, bt, "tool_use")) {
                    if (tool_seen == null) tool_seen = str(block, "name") orelse "?";
                    if (str(block, "id")) |id| {
                        const key = try arena.dupe(u8, id);
                        try pending.put(arena, key, {});
                    }
                }
            }
            if (text_seen) |tx| st.last_assistant_msg = try arena.dupe(u8, firstLine(tx, msg_cap));
            if (tool_seen) |name| {
                st.last_tool_name = try arena.dupe(u8, name);
                st.last_was_tool_call = true;
                if (text_seen == null) st.last_assistant_msg = try std.fmt.allocPrint(arena, "(tool_use: {s})", .{name});
            }
        } else if (std.mem.eql(u8, ty, "user")) {
            const m = msg orelse continue;
            const content = (if (m == .object) m.object.get("content") else null) orelse continue;
            switch (content) {
                .string => |s| if (!std.mem.startsWith(u8, s, "<system-reminder>")) {
                    st.last_user_msg = try arena.dupe(u8, firstLine(s, msg_cap));
                    noteFirst(&st);
                    st.last_was_tool_call = false;
                },
                .array => |arr| for (arr.items) |block| {
                    const bt = str(block, "type") orelse "";
                    if (std.mem.eql(u8, bt, "tool_result")) {
                        if (str(block, "tool_use_id")) |id| _ = pending.remove(id);
                        st.last_was_tool_call = false;
                    } else if (std.mem.eql(u8, bt, "text")) {
                        if (str(block, "text")) |s| if (!std.mem.startsWith(u8, s, "<system-reminder>")) {
                            st.last_user_msg = try arena.dupe(u8, firstLine(s, msg_cap));
                            noteFirst(&st);
                            st.last_was_tool_call = false;
                        };
                    }
                },
                else => {},
            }
        }
    }
    st.pending_tool_uses = pending.count();
    st.usage = usage;
    st.tokens = usage.tokens;
    st.input_tokens = usage.input_tokens;
    st.output_tokens = usage.output_tokens;
    st.cache_create_tokens = usage.cache_create_tokens;
    st.cache_read_tokens = usage.cache_read_tokens;
    return st;
}

/// Codex's rollout JSONL: `session_meta` / `turn_context` carry the cwd
/// and model, `response_item` the turns, `event_msg` the token counts.
pub fn parseCodex(arena: Allocator, text: []const u8) Allocator.Error!Stats {
    var st: Stats = .{};
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    var pending: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        st.event_count += 1;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        if (v != .object) continue;
        const ty = str(v, "type") orelse "";
        const payload = v.object.get("payload") orelse continue;
        if (std.mem.eql(u8, ty, "session_meta") or std.mem.eql(u8, ty, "turn_context")) {
            if (str(payload, "cwd")) |c| st.cwd = try arena.dupe(u8, c);
            if (str(payload, "model")) |m| st.model = try arena.dupe(u8, m);
        } else if (std.mem.eql(u8, ty, "response_item")) {
            const inner = str(payload, "type") orelse "";
            if (std.mem.eql(u8, inner, "function_call")) {
                pending += 1;
                st.last_was_tool_call = true;
                st.last_tool_name = try arena.dupe(u8, str(payload, "name") orelse "exec_command");
            } else if (std.mem.eql(u8, inner, "function_call_output")) {
                pending -|= 1;
                st.last_was_tool_call = false;
            } else if (std.mem.eql(u8, inner, "message")) {
                const role = str(payload, "role") orelse "";
                const content = payload.object.get("content") orelse continue;
                var first: ?[]const u8 = null;
                switch (content) {
                    .array => |arr| for (arr.items) |block| {
                        if (first == null) first = str(block, "text");
                    },
                    .string => |s| first = s,
                    else => {},
                }
                const line_text = firstLine(first orelse continue, msg_cap);
                if (std.mem.eql(u8, role, "user")) {
                    st.last_user_msg = try arena.dupe(u8, line_text);
                    noteFirst(&st);
                } else if (std.mem.eql(u8, role, "assistant")) {
                    st.last_assistant_msg = try arena.dupe(u8, line_text);
                    st.last_was_tool_call = false;
                }
            }
        } else if (std.mem.eql(u8, ty, "event_msg")) {
            // `token_count` events carry the running totals; keep the last.
            if (payload == .object) if (payload.object.get("info")) |info| {
                if (info == .object) if (info.object.get("total_token_usage")) |u| {
                    const i = int(u, "input_tokens");
                    const o = int(u, "output_tokens");
                    st.input_tokens = i;
                    st.output_tokens = o;
                    st.cache_read_tokens = int(u, "cached_input_tokens");
                    st.tokens = i + o;
                };
            };
        }
    }
    st.pending_tool_uses = pending;
    return st;
}

/// The last user message is the first prompt when none was seen yet —
/// unless it is the CLI talking rather than the user: Codex's
/// `<environment_context>` / `<user_instructions>` preamble, Claude
/// Code's `<command-name>` slash-command echo and its `Caveat:` note.
fn noteFirst(st: *Stats) void {
    if (st.first_user_msg != null) return;
    const m = st.last_user_msg orelse return;
    const line = std.mem.trim(u8, m, " \t\r\n");
    if (line.len == 0 or line[0] == '<' or std.mem.startsWith(u8, line, "Caveat:")) return;
    st.first_user_msg = m;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn boolean(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const b = v.object.get(key) orelse return false;
    return b == .bool and b.bool;
}

fn int(v: std.json.Value, key: []const u8) u64 {
    if (v != .object) return 0;
    const f = v.object.get(key) orelse return 0;
    return switch (f) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |x| if (x < 0) 0 else @intFromFloat(x),
        else => 0,
    };
}

/// The first line of `s`, at most `cap` bytes, cut on a glyph boundary.
pub fn firstLine(s: []const u8, cap: usize) []const u8 {
    var end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    if (end > cap) {
        end = cap;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    }
    return std.mem.trim(u8, s[0..end], " \t\r");
}

/// `-Users-foo-Projects-bar` → `bar`: the last path segment of the
/// encoded workspace directory.
pub fn decodeWorkspaceLabel(encoded: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, encoded, "-");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '-')) |i| return trimmed[i + 1 ..];
    return trimmed;
}

/// The last `cap` bytes of a file, starting at the first complete line.
/// Owned by the caller.
/// The first `cap` bytes of `name`, cut back to the last whole line —
/// where a transcript too long for `readTail` keeps its first prompt.
pub fn readHead(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, cap: usize) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const len = try file.length(io);
    const want: usize = @intCast(@min(len, cap));
    const buf = try gpa.alloc(u8, want);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    var slice = buf[0..n];
    if (n < len) slice = if (std.mem.lastIndexOfScalar(u8, slice, '\n')) |nl| slice[0 .. nl + 1] else slice[0..0];
    if (slice.len == buf.len) return buf;
    const out = try gpa.dupe(u8, slice);
    gpa.free(buf);
    return out;
}

pub fn readTail(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, cap: usize) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const len = try file.length(io);
    const start: u64 = if (len > cap) len - cap else 0;
    const want: usize = @intCast(len - start);
    const buf = try gpa.alloc(u8, want);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, start);
    var slice = buf[0..n];
    if (start > 0) {
        if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| slice = slice[nl + 1 ..];
    }
    if (slice.len == buf.len) return buf;
    const out = try gpa.dupe(u8, slice);
    gpa.free(buf);
    return out;
}

// ─── pricing ────────────────────────────────────────────────────────────

/// Dollars per million tokens: input, output, cache write, cache read;
/// zeros for a model the table does not know (`knownPrice` says which).
pub fn pricePerMt(model: []const u8) [4]f64 {
    return knownPrice(model) orelse .{ 0, 0, 0, 0 };
}

/// The price row for `model_in`, null when the table has none. Anthropic's
/// public list: cache writes (5 min) are 1.25× input and cache reads
/// 0.1× input, except where the list names its own read price.
pub fn knownPrice(model_in: []const u8) ?[4]f64 {
    // `claude-haiku-4-5-20251001` → `claude-haiku-4-5`: a trailing
    // all-digit segment of six or more is a date.
    var model = model_in;
    if (std.mem.lastIndexOfScalar(u8, model, '-')) |i| {
        const tail = model[i + 1 ..];
        var digits = tail.len >= 6;
        for (tail) |c| if (!std.ascii.isDigit(c)) {
            digits = false;
        };
        if (digits) model = model[0..i];
    }
    const Row = struct { name: []const u8, price: [4]f64 };
    const table = [_]Row{
        .{ .name = "claude-fable-5-1", .price = .{ 10.0, 50.0, 12.50, 0.25 } },
        .{ .name = "claude-fable-5", .price = .{ 10.0, 50.0, 12.50, 1.00 } },
        .{ .name = "claude-opus-5-5", .price = .{ 4.0, 20.0, 5.00, 0.20 } },
        .{ .name = "claude-opus-5", .price = .{ 5.0, 25.0, 6.25, 0.50 } },
        .{ .name = "claude-sonnet-5", .price = .{ 2.0, 10.0, 2.50, 0.20 } },
        .{ .name = "claude-opus-4-8", .price = .{ 5.0, 25.0, 6.25, 0.50 } },
        .{ .name = "claude-opus-4-7", .price = .{ 5.0, 25.0, 6.25, 0.50 } },
        .{ .name = "claude-opus-4-6", .price = .{ 5.0, 25.0, 6.25, 0.50 } },
        .{ .name = "claude-sonnet-4-6", .price = .{ 3.0, 15.0, 3.75, 0.30 } },
        .{ .name = "claude-sonnet-4-5", .price = .{ 3.0, 15.0, 3.75, 0.30 } },
        .{ .name = "claude-haiku-4-5", .price = .{ 1.0, 5.0, 1.25, 0.10 } },
        .{ .name = "claude-haiku-4-4", .price = .{ 1.0, 5.0, 1.25, 0.10 } },
        .{ .name = "gpt-5", .price = .{ 5.0, 30.0, 0.0, 0.50 } },
        .{ .name = "gpt-5.5", .price = .{ 5.0, 30.0, 0.0, 0.50 } },
        .{ .name = "gpt-5-mini", .price = .{ 0.50, 2.0, 0.0, 0.05 } },
        .{ .name = "gpt-5.5-mini", .price = .{ 0.50, 2.0, 0.0, 0.05 } },
        .{ .name = "gpt-4o", .price = .{ 2.50, 10.0, 0.0, 1.25 } },
        .{ .name = "gpt-4o-mini", .price = .{ 0.15, 0.60, 0.0, 0.075 } },
    };
    for (table) |row| if (std.mem.eql(u8, row.name, model)) return row.price;
    return null;
}

pub fn estimateCost(model: []const u8, input: u64, output: u64, cache_create: u64, cache_read: u64) f64 {
    return costAt(pricePerMt(model), input, output, cache_create, cache_read);
}

fn costAt(p: [4]f64, input: u64, output: u64, cache_create: u64, cache_read: u64) f64 {
    const f = struct {
        fn mt(n: u64) f64 {
            return @as(f64, @floatFromInt(n)) / 1_000_000.0;
        }
    };
    return f.mt(input) * p[0] + f.mt(output) * p[1] + f.mt(cache_create) * p[2] + f.mt(cache_read) * p[3];
}

/// `12.3k` / `1.2M` / `987`.
pub fn fmtTokens(buf: []u8, n: u64) []const u8 {
    if (n >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1_000_000.0}) catch "?";
    if (n >= 1_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{@as(f64, @floatFromInt(n)) / 1_000.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

pub const claude_fixture =
    \\{"type":"user","cwd":"/Users/me/Projects/mnml","gitBranch":"main","message":{"role":"user","content":"fix the build"}}
    \\{"type":"assistant","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1200,"output_tokens":300,"cache_creation_input_tokens":50,"cache_read_input_tokens":4000},"content":[{"type":"text","text":"Looking now.\nSecond line."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"zig build"}}]}}
    \\not json at all
    \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
    \\{"type":"assistant","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"a.zig"}}]}}
;

test "parseClaude: an API error turn or an is_error result marks the transcript failed; a later assistant text clears it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const failed =
        \\{"type":"user","message":{"role":"user","content":"go"}}
        \\{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 529 overloaded"}]}}
    ;
    try t.expect((try parseClaude(arena.allocator(), failed)).last_error);
    const result_err =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        \\{"type":"result","is_error":true,"subtype":"error_max_turns"}
    ;
    try t.expect((try parseClaude(arena.allocator(), result_err)).last_error);
    const recovered = failed ++ "\n" ++
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Back."}]}}
    ;
    try t.expect(!(try parseClaude(arena.allocator(), recovered)).last_error);
    try t.expect(!(try parseClaude(arena.allocator(), claude_fixture)).last_error);
}

test "parseClaude: tokens sum across assistant events, the last messages and the pending tool are kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try parseClaude(arena.allocator(), claude_fixture);
    try t.expectEqual(@as(usize, 5), s.event_count);
    try t.expectEqualStrings("/Users/me/Projects/mnml", s.cwd.?);
    try t.expectEqualStrings("main", s.git_branch.?);
    try t.expectEqualStrings("claude-sonnet-4-5-20250929", s.model.?);
    try t.expectEqual(@as(u64, 1620), s.tokens);
    try t.expectEqual(@as(u64, 1300), s.input_tokens);
    try t.expectEqual(@as(u64, 320), s.output_tokens);
    try t.expectEqual(@as(u64, 50), s.cache_create_tokens);
    try t.expectEqual(@as(u64, 4000), s.cache_read_tokens);
    try t.expectEqualStrings("fix the build", s.last_user_msg.?);
    try t.expectEqualStrings("(tool_use: Edit)", s.last_assistant_msg.?);
    try t.expect(s.last_was_tool_call);
    try t.expectEqualStrings("Edit", s.last_tool_name.?);
    try t.expectEqual(@as(usize, 1), s.pending_tool_uses);
    // 1300 in @ $3, 320 out @ $15, 50 cw @ $3.75, 4000 cr @ $0.30 per MT.
    const cost = s.costUsd();
    try t.expect(cost > 0.0100 and cost < 0.0102);
    try t.expect(s.priced());
}

test "parseClaude: a message split over several lines counts once; each message is priced at its own model; an unknown model's tokens make the cost n/a" {
    // sess-table-tokens-cost-wrong: Claude Code writes one message as a
    // line per content block, each repeating the id and the whole usage.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const u = "\"usage\":{\"input_tokens\":1000,\"output_tokens\":200}";
    const split =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"go\"}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_a1\",\"model\":\"claude-opus-4-7\"," ++ u ++ ",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hm\"}]}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_a1\",\"model\":\"claude-opus-4-7\"," ++ u ++ ",\"content\":[{\"type\":\"text\",\"text\":\"one\"}]}}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"ok\"}]}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_a1\",\"model\":\"claude-opus-4-7\"," ++ u ++ ",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_b2\",\"model\":\"claude-fable-5-1\"," ++ u ++ ",\"content\":[{\"type\":\"text\",\"text\":\"three\"}]}}\n";
    const s = try parseClaude(arena.allocator(), split);
    try t.expectEqual(@as(u64, 2400), s.tokens);
    try t.expectEqual(@as(u64, 2000), s.input_tokens);
    // opus-4-7: 1000 × $5 + 200 × $25 per MT = $0.010; fable-5-1:
    // 1000 × $10 + 200 × $50 = $0.020.
    try t.expectApproxEqAbs(@as(f64, 0.030), s.costUsd(), 1e-9);
    try t.expect(s.priced());
    // Fed in two pieces, the same totals: the ids carry over.
    var piece: Usage = .{};
    const cut = std.mem.indexOf(u8, split, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[").?;
    piece.addText(t.allocator, split[0..cut]);
    piece.addText(t.allocator, split[cut..]);
    try t.expectEqual(@as(u64, 2400), piece.tokens);
    try t.expectApproxEqAbs(@as(f64, 0.030), piece.cost_usd, 1e-9);
    // A model the table does not know: the tokens count, the cost is n/a.
    const unknown = "{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"model\":\"claude-next-9\"," ++ u ++ "}}\n";
    const n = try parseClaude(arena.allocator(), unknown);
    try t.expectEqual(@as(u64, 1200), n.tokens);
    try t.expect(!n.priced());
    // Zero usage under an unknown model (Claude Code's `<synthetic>`
    // turns) prices nothing and leaves the cost a number.
    const synthetic = "{\"type\":\"assistant\",\"message\":{\"id\":\"z\",\"model\":\"<synthetic>\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n";
    try t.expect((try parseClaude(arena.allocator(), synthetic)).priced());
}

test "parseClaude / parseCodex: the first prompt is the user's first words, past the CLI's own preamble" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const claude =
        \\{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        \\{"type":"user","message":{"role":"user","content":"Caveat: The messages below were generated by the user"}}
        \\{"type":"user","message":{"role":"user","content":"write the release notes for 0.3\nthen tag it"}}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"and the changelog"}]}}
    ;
    const s = try parseClaude(arena.allocator(), claude);
    try t.expectEqualStrings("write the release notes for 0.3", s.first_user_msg.?);
    try t.expectEqualStrings("and the changelog", s.last_user_msg.?);
    const codex =
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"run tests"}]}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"now lint"}]}}
    ;
    const c = try parseCodex(arena.allocator(), codex);
    try t.expectEqualStrings("run tests", c.first_user_msg.?);
    try t.expectEqualStrings("now lint", c.last_user_msg.?);
    // No user words at all: no first prompt.
    try t.expect((try parseClaude(arena.allocator(), "{\"type\":\"assistant\",\"message\":{}}")).first_user_msg == null);
}

pub const codex_fixture =
    \\{"type":"session_meta","payload":{"cwd":"/w/app","id":"0198"}}
    \\{"type":"turn_context","payload":{"cwd":"/w/app","model":"gpt-5"}}
    \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"run tests"}]}}
    \\{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c1","arguments":"{\"cmd\":\"npm test\"}"}}
    \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":40}}}}
;

test "parseCodex: cwd + model from the context, the pending exec, the running token totals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try parseCodex(arena.allocator(), codex_fixture);
    try t.expectEqualStrings("/w/app", s.cwd.?);
    try t.expectEqualStrings("gpt-5", s.model.?);
    try t.expectEqualStrings("run tests", s.last_user_msg.?);
    try t.expect(s.last_was_tool_call);
    try t.expectEqual(@as(usize, 1), s.pending_tool_uses);
    try t.expectEqual(@as(u64, 540), s.tokens);
    try t.expectEqual(@as(u64, 100), s.cache_read_tokens);
}

test "pricing strips the date suffix and unknown models cost nothing" {
    try t.expectEqual(@as(f64, 1.0), pricePerMt("claude-haiku-4-5-20251001")[0]);
    try t.expectEqual(@as(f64, 25.0), pricePerMt("claude-opus-4-7")[1]);
    try t.expectEqual(@as(f64, 0.0), pricePerMt("claude-2")[0]);
    try t.expect(knownPrice("claude-2") == null);
    // The models the user runs: Opus 5 / 5.5, Fable 5 / 5.1.
    try t.expectEqual(@as(f64, 5.0), knownPrice("claude-opus-5").?[0]);
    try t.expectEqual(@as(f64, 20.0), knownPrice("claude-opus-5-5").?[1]);
    try t.expectEqual(@as(f64, 50.0), knownPrice("claude-fable-5").?[1]);
    try t.expectEqual(@as(f64, 0.25), knownPrice("claude-fable-5-1").?[3]);
    try t.expectEqual(@as(f64, 0.0), estimateCost("", 1000, 1000, 0, 0));
    try t.expectEqualStrings("bar", decodeWorkspaceLabel("-Users-foo-Projects-bar"));
    try t.expectEqualStrings("plain", decodeWorkspaceLabel("plain"));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("1.2M", fmtTokens(&buf, 1_234_567));
    try t.expectEqualStrings("12.3k", fmtTokens(&buf, 12_345));
    try t.expectEqualStrings("987", fmtTokens(&buf, 987));
    try t.expectEqualStrings("héllo", firstLine("héllo\nworld", 50));
    try t.expectEqualStrings("hé", firstLine("héllo", 3));
}

test "readTail returns the last complete lines under the cap" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s.jsonl", .data = "line one\nline two\nline three\n" });
    const all = try readTail(t.allocator, t.io, tmp.dir, "s.jsonl", 1000);
    defer t.allocator.free(all);
    try t.expectEqualStrings("line one\nline two\nline three\n", all);
    const tail = try readTail(t.allocator, t.io, tmp.dir, "s.jsonl", 14);
    defer t.allocator.free(tail);
    try t.expectEqualStrings("line three\n", tail);
}
