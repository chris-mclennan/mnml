//! The local session scanner: every Claude Code / Codex transcript on
//! this machine — `~/.claude/projects/<encoded ws>/<sid>.jsonl` and
//! `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (the tail of each,
//! `transcript.zig`) — with `ps -axo pid=,command=` telling which are
//! alive, and one `git status --porcelain` per distinct cwd for the
//! done-but-dirty signal. The rows are `sessions.Item`, the one row
//! model behind the SESSIONS section and the sessions table
//! (`src/sessions.zig`, `src/app/sessions_table.zig`).
//!
//! // changed (sessions-merge): the Claude Agents dashboard
//! (`Pane.claude_agents`, `src/ui/agents_view.zig`) is gone — the
//! table pane on the same rows replaced it. This file keeps the walk,
//! the state derivation and the markdown export; `sessions.zig` owns
//! the scan worker, the snapshot and the commands.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const transcript = @import("../ai/transcript.zig");
const sessions = @import("../sessions.zig");

pub const Item = sessions.Item;

/// A file older than this is not listed (Rust: the 7-day window).
pub const max_age_s: i64 = 7 * 24 * 3600;
/// Bytes of a transcript's tail that are parsed.
pub const tail_cap: usize = 256 * 1024;
/// Bytes of a transcript's head read for its first prompt when the file
/// is longer than `tail_cap` (the tail no longer holds it).
pub const head_cap: usize = 64 * 1024;
/// Transcripts past this are skipped outright.
pub const max_file_bytes: u64 = 256 * 1024 * 1024;
/// Bytes of a Claude transcript the tokens and cost are summed over,
/// from its start (`totalsOf`). A longer one's totals are its first
/// `totals_cap` bytes' and the row says so (`Item.totals_capped`).
pub const totals_cap: u64 = 64 * 1024 * 1024;
/// A single JSONL line longer than this is skipped by the totals.
const line_cap: usize = 16 * 1024 * 1024;
const totals_chunk: usize = 1024 * 1024;

/// What the scan has already summed of each Claude transcript, by path:
/// a transcript only grows, so a rescan reads from where the last one
/// stopped rather than the whole file every `refresh_ms`. Owned by
/// `sessions.State` and touched only by the one scan worker in flight
/// (`sessions.refresh` cancels the last before starting the next).
pub const TotalsCache = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    pass: u32 = 0,

    pub const Entry = struct {
        /// Bytes summed so far, always at a line's end.
        offset: u64 = 0,
        usage: transcript.Usage = .{},
        /// A line past `line_cap` is being skipped at `offset`.
        skipping: bool = false,
        pass: u32 = 0,
    };

    pub fn deinit(self: *TotalsCache, gpa: Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.map.deinit(gpa);
    }

    /// Drop the transcripts this pass did not list (deleted, aged out).
    fn sweep(self: *TotalsCache, gpa: Allocator) void {
        var again = true;
        while (again) {
            again = false;
            var it = self.map.iterator();
            while (it.next()) |e| if (e.value_ptr.pass != self.pass) {
                const key = e.key_ptr.*;
                _ = self.map.remove(key);
                gpa.free(key);
                again = true;
                break;
            };
        }
    }
};

pub const Totals = struct { usage: transcript.Usage, capped: bool };

/// The usage of the whole transcript `name` in `dir` (up to `cap`
/// bytes — the scan passes `totals_cap`), every message once, each at
/// its own model's price — read on from `cache`'s entry for `path` when
/// there is one.
pub fn totalsOf(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8, path: []const u8, size: u64, cap: u64, cache: ?*TotalsCache) ScanError!Totals {
    var fresh: TotalsCache.Entry = .{};
    const e: *TotalsCache.Entry = if (cache) |c| blk: {
        const gop = try c.map.getOrPut(gpa, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, path) catch |err| {
                _ = c.map.remove(path);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        break :blk gop.value_ptr;
    } else &fresh;
    if (cache) |c| e.pass = c.pass;
    // Shorter than what was summed: rewritten, not appended to.
    if (size < e.offset) e.* = .{ .pass = e.pass };
    const end = @min(size, cap);
    if (e.offset < end) {
        var file = dir.openFile(io, name, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return .{ .usage = e.usage, .capped = size > cap },
        };
        defer file.close(io);
        var buf = try gpa.alloc(u8, totals_chunk);
        defer gpa.free(buf);
        while (e.offset < end) {
            try io.checkCancel();
            const want: usize = @intCast(@min(@as(u64, buf.len), end - e.offset));
            const n = file.readPositionalAll(io, buf[0..want], e.offset) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => break,
            };
            if (n == 0) break;
            const got = buf[0..n];
            if (e.skipping) {
                // Past the rest of an overlong line.
                const nl = std.mem.indexOfScalar(u8, got, '\n') orelse {
                    e.offset += n;
                    continue;
                };
                e.offset += nl + 1;
                e.skipping = false;
                continue;
            }
            const nl = std.mem.lastIndexOfScalar(u8, got, '\n') orelse {
                // No line end in the buffer: the line is still being
                // written (at the end), longer than the buffer (grow
                // it), or longer than any line worth parsing (skip).
                if (e.offset + n >= size) break;
                if (buf.len >= line_cap) {
                    e.offset += n;
                    e.skipping = true;
                } else buf = try gpa.realloc(buf, buf.len * 4);
                continue;
            };
            e.usage.addText(gpa, got[0 .. nl + 1]);
            e.offset += nl + 1;
        }
    }
    return .{ .usage = e.usage, .capped = size > cap };
}
/// A session whose file moved within this many seconds is `streaming`.
pub const fresh_s: i64 = 60;
/// A tool use without its result, and the file quiet this long: the
/// confirmation prompt is up — the session is `waiting`.
pub const waiting_quiet_s: i64 = 15;
/// The dirty scan skips a session that ended longer ago than this (the
/// table hides it by default; its cwd may well be gone).
pub const dirty_window_s: i64 = 2 * 24 * 3600;

pub const Source = enum {
    claude,
    codex,

    // No `glyph` here any more: a session wears its PRODUCT's own mark
    // now — the one `ui.claude_mark` names for Claude, and the same
    // the pty tab and the tab bar's cluster wear
    // (`ui/sessions_table_view.zig`'s `sourceGlyph`). A neutral pair
    // of this enum's own would only be a second, wrong answer to
    // "which mark is Claude's", waiting to be used.

    pub fn label(s: Source) []const u8 {
        return @tagName(s);
    }
};

/// The states, in sort order: a session that needs input first, then
/// the ones with a process, then the ended ones — `failed` before
/// `done` so what broke is not hidden under what finished.
/// // changed (sessions-merge): `waiting` is first-class (was the
/// `needs_approval` flag); `ended` split into `done` / `failed`.
pub const AgentState = enum {
    waiting,
    streaming,
    tool_call,
    idle,
    failed,
    done,

    pub fn badge(s: AgentState, ascii: bool) []const u8 {
        return switch (s) {
            .waiting => if (ascii) "! wait" else "⚠ wait",
            .streaming => if (ascii) "* live" else "● live",
            .tool_call => if (ascii) "> tool" else "▸ tool",
            .idle => if (ascii) "o idle" else "○ idle",
            .failed => if (ascii) "x fail" else "✗ fail",
            .done => if (ascii) ". done" else "· done",
        };
    }
    pub fn rank(s: AgentState) u8 {
        return @intFromEnum(s);
    }
    /// No process behind it any more.
    pub fn ended(s: AgentState) bool {
        return s == .done or s == .failed;
    }
    /// The state filter's word (`f` cycles them).
    pub fn label(s: AgentState) []const u8 {
        return switch (s) {
            .waiting => "waiting",
            .streaming => "live",
            .tool_call => "tool",
            .idle => "idle",
            .failed => "failed",
            .done => "done",
        };
    }
    pub fn next(s: ?AgentState) ?AgentState {
        return switch (s orelse return .waiting) {
            .waiting => .streaming,
            .streaming => .tool_call,
            .tool_call => .idle,
            .idle => .failed,
            .failed => .done,
            .done => null,
        };
    }
};

pub const ScanError = Io.Cancelable || Allocator.Error;

pub const Pid = struct { pid: u32, session_id: ?[]const u8, exe: Source, pgid: i32 = 0 };

/// `MNML_AGENTS_PGID`: a process group the process scan is limited to.
///
/// The scan is `ps` over the whole machine, which is right for a person
/// — every Claude on the machine is theirs — and wrong for a test: two
/// copies of one `.test` file running at once start fake `claude`
/// processes with the SAME session ids, and each run found (and batch
/// killed) the other's. The `.test` runner starts every `shell` step of
/// a file in one process group of its own and names it here, so a run
/// sees the processes its own file started and nothing else. Processes
/// descended from this one — a session a pane of this App spawned —
/// are always in scope.
pub const scope_env = "MNML_AGENTS_PGID";

/// Which processes the scan may attribute: null is the whole machine.
pub const Scope = ?Filter;

pub const Filter = struct {
    /// Only processes in this process group…
    pgid: i32,
    /// …or descended from this pid (the App's own process).
    self_pid: i32,
};

/// `MNML_AGENTS_PGID` from an environment, with this process as the
/// ancestor that is always in scope. Null when unset or not a number.
pub fn scopeFrom(env: *const std.process.Environ.Map) Scope {
    const v = env.get(scope_env) orelse return null;
    const pgid = std.fmt.parseInt(i32, std.mem.trim(u8, v, " \t"), 10) catch return null;
    return .{ .pgid = pgid, .self_pid = selfPid() };
}

fn selfPid() i32 {
    if (@import("builtin").os.tag == .windows) return 0;
    return @intCast(std.c.getpid());
}

/// `ps -axo pid=,ppid=,pgid=,command=` → the claude / codex processes,
/// with the `--session-id <uuid>` a Claude line carries. With a scope,
/// only the processes it admits (`Filter`).
pub fn parsePs(arena: Allocator, text: []const u8, scope: Scope) Allocator.Error![]Pid {
    const Row = struct { pid: u32, ppid: u32 };
    // Every process's parent, for the "descended from this App" rule.
    var parents: std.ArrayListUnmanaged(Row) = .empty;
    var out: std.ArrayListUnmanaged(Pid) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var rest = std.mem.trimStart(u8, raw, " \t");
        var nums: [3]u32 = undefined;
        var ok = true;
        for (&nums) |*n| {
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse {
                ok = false;
                break;
            };
            n.* = std.fmt.parseInt(u32, rest[0..sp], 10) catch {
                ok = false;
                break;
            };
            rest = std.mem.trimStart(u8, rest[sp + 1 ..], " \t");
        }
        if (!ok) continue;
        const pid = nums[0];
        if (scope != null) try parents.append(arena, .{ .pid = pid, .ppid = nums[1] });
        const cmd = rest;
        const exe_end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        const exe = std.fs.path.basename(cmd[0..exe_end]);
        const source: Source = if (std.mem.eql(u8, exe, "claude")) .claude else if (std.mem.eql(u8, exe, "codex")) .codex else continue;
        var sid: ?[]const u8 = null;
        if (std.mem.indexOf(u8, cmd, "--session-id ")) |at| {
            const r = cmd[at + "--session-id ".len ..];
            const end = std.mem.indexOfScalar(u8, r, ' ') orelse r.len;
            if (end == 36) sid = try arena.dupe(u8, r[0..end]);
        } else if (std.mem.indexOf(u8, cmd, "--resume ")) |at| {
            const r = cmd[at + "--resume ".len ..];
            const end = std.mem.indexOfScalar(u8, r, ' ') orelse r.len;
            if (end == 36) sid = try arena.dupe(u8, r[0..end]);
        }
        try out.append(arena, .{ .pid = pid, .session_id = sid, .exe = source, .pgid = @intCast(nums[2]) });
    }
    const f = scope orelse return out.items;
    var kept: usize = 0;
    for (out.items) |p| {
        if (p.pgid == f.pgid or descends(parents.items, p.pid, f.self_pid)) {
            out.items[kept] = p;
            kept += 1;
        }
    }
    return out.items[0..kept];
}

/// Whether `pid`'s ancestry reaches `ancestor`, through `rows`. Bounded,
/// so a table read mid-fork with a cycle in it cannot spin.
fn descends(rows: anytype, pid: u32, ancestor: i32) bool {
    if (ancestor <= 0) return false;
    var cur = pid;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const parent = for (rows) |r| {
            if (r.pid == cur) break r.ppid;
        } else return false;
        if (parent == @as(u32, @intCast(ancestor))) return true;
        if (parent <= 1) return false;
        cur = parent;
    }
    return false;
}

fn runningPids(io: Io, gpa: Allocator, arena: Allocator, scope: Scope) ScanError![]Pid {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "ps", "-axo", "pid=,ppid=,pgid=,command=" }, .stdout_limit = .limited(4 * 1024 * 1024) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return &.{},
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return parsePs(arena, result.stdout, scope);
}

/// The state from what the scan can see: no process is `done` (or
/// `failed` when the transcript ends on an error); a tool use without
/// its result and the file quiet for `waiting_quiet_s` is `waiting`;
/// the last turn a tool call is `tool_call`; a file that moved within
/// `fresh_s` is `streaming`, else `idle`.
pub fn deriveState(has_pid: bool, age_s: i64, last_was_tool_call: bool, pending_tool_uses: usize, last_error: bool) AgentState {
    if (!has_pid) return if (last_error) .failed else .done;
    if (pending_tool_uses > 0 and age_s >= waiting_quiet_s) return .waiting;
    if (last_was_tool_call) return .tool_call;
    return if (age_s < fresh_s) .streaming else .idle;
}

/// Walk both roots and append this machine's sessions to `rows`, every
/// slice on `arena`.
pub fn scanInto(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, scope: Scope, rows: *std.ArrayListUnmanaged(Item), totals: ?*TotalsCache) ScanError!void {
    if (totals) |c| c.pass +%= 1;
    const pids = try runningPids(io, gpa, arena, scope);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    // Claude: <home>/.claude/projects/<encoded>/<sid>.jsonl
    const projects = try std.fs.path.join(arena, &.{ home, ".claude", "projects" });
    if (Io.Dir.cwd().openDir(io, projects, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var dirs = root.iterate();
        while (dirs.next(io) catch null) |d| {
            if (d.kind != .directory) continue;
            try io.checkCancel();
            var sub = root.openDir(io, d.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const ws_label = try arena.dupe(u8, transcript.decodeWorkspaceLabel(d.name));
            var files = sub.iterate();
            while (files.next(io) catch null) |f| {
                if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".jsonl")) continue;
                const st = sub.statFile(io, f.name, .{}) catch continue;
                const mtime = st.mtime.toSeconds();
                if (now - mtime > max_age_s or st.size > max_file_bytes) continue;
                try io.checkCancel();
                const tail = transcript.readTail(gpa, io, sub, f.name, tail_cap) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                defer gpa.free(tail);
                const stats = try transcript.parseClaude(arena, tail);
                const first = if (st.size > tail_cap) try firstPrompt(gpa, io, arena, sub, f.name, .claude) else stats.first_user_msg;
                const path = try std.fs.path.join(arena, &.{ projects, d.name, f.name });
                // The tail names the state; the tokens and cost are the
                // whole transcript's.
                const sum: Totals = if (st.size <= tail_cap) .{ .usage = stats.usage.?, .capped = false } else try totalsOf(io, gpa, sub, f.name, path, st.size, totals_cap, totals);
                const sid = try arena.dupe(u8, f.name[0 .. f.name.len - ".jsonl".len]);
                var pid: ?u32 = null;
                for (pids) |p| if (p.session_id) |s| if (std.mem.eql(u8, s, sid)) {
                    pid = p.pid;
                };
                try rows.append(arena, .{
                    .source = .claude,
                    .session_id = sid,
                    .workspace = ws_label,
                    .cwd = stats.cwd,
                    .model = stats.model,
                    .transcript_path = path,
                    .state = deriveState(pid != null, now - mtime, stats.last_was_tool_call, stats.pending_tool_uses, stats.last_error),
                    .pid = pid,
                    .tokens = sum.usage.tokens,
                    .cost_usd = sum.usage.cost_usd,
                    .cost_known = !sum.usage.unpriced,
                    .totals_capped = sum.capped,
                    .last_activity_s = mtime,
                    .first_user_msg = first,
                    .last_user_msg = stats.last_user_msg,
                    .last_assistant_msg = stats.last_assistant_msg,
                    .current_tool = stats.last_tool_name,
                    .pending_tool_uses = stats.pending_tool_uses,
                    .git_branch = stats.git_branch,
                });
            }
        }
    } else |_| {}
    // Codex: <home>/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl
    const sessions_dir = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    if (Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var walker = root.walk(gpa) catch return error.OutOfMemory;
        defer walker.deinit();
        var claimed: std.ArrayListUnmanaged(u32) = .empty;
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.basename, "rollout-") or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            try io.checkCancel();
            const stem = entry.basename[0 .. entry.basename.len - ".jsonl".len];
            if (stem.len < 36) continue;
            const sid = try arena.dupe(u8, stem[stem.len - 36 ..]);
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const mtime = st.mtime.toSeconds();
            if (now - mtime > max_age_s or st.size > max_file_bytes) continue;
            const tail = transcript.readTail(gpa, io, entry.dir, entry.basename, tail_cap) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer gpa.free(tail);
            const stats = try transcript.parseCodex(arena, tail);
            const first = if (st.size > tail_cap) try firstPrompt(gpa, io, arena, entry.dir, entry.basename, .codex) else stats.first_user_msg;
            // Codex carries no session id on its command line: the first
            // unclaimed codex process is this session's, newest file first.
            var pid: ?u32 = null;
            if (now - mtime < 3600) for (pids) |p| {
                if (p.exe != .codex) continue;
                if (std.mem.indexOfScalar(u32, claimed.items, p.pid) != null) continue;
                pid = p.pid;
                try claimed.append(arena, p.pid);
                break;
            };
            try rows.append(arena, .{
                .source = .codex,
                .session_id = sid,
                .workspace = if (stats.cwd) |c| std.fs.path.basename(c) else "?",
                .cwd = stats.cwd,
                .model = stats.model,
                .transcript_path = try std.fs.path.join(arena, &.{ sessions_dir, entry.path }),
                .state = deriveState(pid != null, now - mtime, stats.last_was_tool_call, stats.pending_tool_uses, stats.last_error),
                .pid = pid,
                .tokens = stats.tokens,
                .cost_usd = stats.costUsd(),
                .cost_known = stats.priced(),
                .last_activity_s = mtime,
                .first_user_msg = first,
                .last_user_msg = stats.last_user_msg,
                .last_assistant_msg = stats.last_assistant_msg,
                .current_tool = stats.last_tool_name,
                .pending_tool_uses = stats.pending_tool_uses,
                .git_branch = stats.git_branch,
            });
        }
    } else |_| {}
    // A whole pass: what it did not list is gone (a cancelled pass
    // sweeps nothing).
    if (totals) |c| c.sweep(gpa);
}

/// The first prompt of a transcript too long for its tail to hold it:
/// the head's, on `arena`. A head that cannot be read has none.
fn firstPrompt(gpa: Allocator, io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, kind: Source) ScanError!?[]const u8 {
    const head = transcript.readHead(gpa, io, dir, name, head_cap) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(head);
    const stats = switch (kind) {
        .claude => try transcript.parseClaude(arena, head),
        .codex => try transcript.parseCodex(arena, head),
    };
    return stats.first_user_msg;
}

// ─── the dirty signal ───────────────────────────────────────────────────

/// The number of entries `git status --porcelain` lists.
pub fn countPorcelain(text: []const u8) u32 {
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.trim(u8, line, " \r\t").len > 0) {
        n += 1;
    };
    return n;
}

/// One `git status --porcelain` per distinct cwd of the local rows that
/// are running or ended within `dirty_window_s`; every row of that cwd
/// gets the count. A cwd that is gone or not a repository stays null.
pub fn dirtyScan(io: Io, gpa: Allocator, arena: Allocator, rows: []Item, now: i64) ScanError!void {
    var seen: std.StringHashMapUnmanaged(?u32) = .empty;
    defer seen.deinit(gpa);
    for (rows) |*r| {
        if (r.where != .local) continue;
        const cwd = r.cwd orelse continue;
        if (r.state.ended() and now - r.last_activity_s > dirty_window_s) continue;
        try io.checkCancel();
        const gop = try seen.getOrPut(gpa, cwd);
        if (!gop.found_existing) {
            gop.value_ptr.* = null;
            const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "-C", cwd, "status", "--porcelain" }, .stdout_limit = .limited(4 * 1024 * 1024) }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => continue,
            };
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            if (result.term == .exited and result.term.exited == 0) gop.value_ptr.* = countPorcelain(result.stdout);
        }
        r.dirty = gop.value_ptr.*;
    }
    _ = arena;
}

// ─── the markdown export ────────────────────────────────────────────────

/// The transcript's user / assistant turns as markdown.
pub fn transcriptMarkdown(arena: Allocator, row: Item, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "# {s} session {s}\n\n_workspace: {s} · state: {s} · model: {s}_\n\n", .{ row.source.label(), row.session_id[0..@min(8, row.session_id.len)], row.workspace, @tagName(row.state), row.model orelse "?" });
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        if (v != .object) continue;
        const ty = (v.object.get("type") orelse continue);
        if (ty != .string) continue;
        const msg = v.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (std.mem.eql(u8, ty.string, "user")) {
            const txt: ?[]const u8 = switch (content) {
                .string => |s| s,
                .array => |arr| blk: {
                    for (arr.items) |b| if (b == .object) if (b.object.get("type")) |bt| if (bt == .string and std.mem.eql(u8, bt.string, "text")) if (b.object.get("text")) |tx| if (tx == .string) break :blk tx.string;
                    break :blk null;
                },
                else => null,
            };
            const s = txt orelse continue;
            if (std.mem.startsWith(u8, s, "<system-reminder>")) continue;
            try out.print(arena, "## User\n\n{s}\n\n", .{s});
        } else if (std.mem.eql(u8, ty.string, "assistant")) {
            if (content != .array) continue;
            var header = false;
            for (content.array.items) |b| {
                if (b != .object) continue;
                const bt = b.object.get("type") orelse continue;
                if (bt != .string) continue;
                if (std.mem.eql(u8, bt.string, "text")) {
                    const tx = b.object.get("text") orelse continue;
                    if (tx != .string) continue;
                    if (!header) {
                        try out.appendSlice(arena, "## Assistant\n\n");
                        header = true;
                    }
                    try out.print(arena, "{s}\n\n", .{tx.string});
                } else if (std.mem.eql(u8, bt.string, "tool_use")) {
                    const name = b.object.get("name") orelse continue;
                    if (name != .string) continue;
                    if (!header) {
                        try out.appendSlice(arena, "## Assistant\n\n");
                        header = true;
                    }
                    try out.print(arena, "_tool: {s}_\n\n", .{name.string});
                }
            }
        }
    }
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "parsePs picks claude / codex processes and the --session-id they carry" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ps =
        \\  123     1   123 /usr/bin/zsh -l
        \\  456   123   456 claude --session-id 11111111-2222-3333-4444-555555555555 -p hi
        \\  789   123   789 /opt/homebrew/bin/codex exec fix
        \\  790   123   790 node /x/claude-thing
        \\  791     1   791 claude --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    ;
    const pids = try parsePs(arena.allocator(), ps, null);
    try t.expectEqual(@as(usize, 3), pids.len);
    try t.expectEqual(@as(u32, 456), pids[0].pid);
    try t.expectEqualStrings("11111111-2222-3333-4444-555555555555", pids[0].session_id.?);
    try t.expectEqual(Source.codex, pids[1].exe);
    try t.expect(pids[1].session_id == null);
    try t.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", pids[2].session_id.?);
}

/// A scope no process is in: a unit test's fixture sessions must read
/// as ended whatever `claude` / `codex` the machine happens to be
/// running.
const nobody: Scope = .{ .pgid = -1, .self_pid = 0 };

test "parsePs with a scope keeps its own process group and this App's descendants, and nobody else's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // 100 is this App. 200 is another run's fake claude with the SAME
    // session id as ours (the same `.test` file, run twice at once);
    // 201 is ours, in the group the runner made; 301 is a codex a pane
    // of this App started, two hops down.
    const ps =
        \\  100     1   100 /x/mnml-zig test
        \\  200     1   555 claude --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        \\  201     1   777 claude --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        \\  300   100   300 /bin/bash -l
        \\  301   300   301 codex exec fix
    ;
    const all = try parsePs(arena.allocator(), ps, null);
    try t.expectEqual(@as(usize, 3), all.len);
    const ours = try parsePs(arena.allocator(), ps, .{ .pgid = 777, .self_pid = 100 });
    try t.expectEqual(@as(usize, 2), ours.len);
    try t.expectEqual(@as(u32, 201), ours[0].pid);
    try t.expectEqual(@as(u32, 301), ours[1].pid);
    try t.expectEqual(Source.codex, ours[1].exe);
    // Nobody's scope: nothing, however many there are.
    try t.expectEqual(@as(usize, 0), (try parsePs(arena.allocator(), ps, nobody)).len);
}

test "the scope is read from MNML_AGENTS_PGID, and absent or garbled is the whole machine" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try t.expect(scopeFrom(&env) == null);
    try env.put(scope_env, "4242");
    const s = scopeFrom(&env).?;
    try t.expectEqual(@as(i32, 4242), s.pgid);
    try env.put(scope_env, "soon");
    try t.expect(scopeFrom(&env) == null);
}

test "deriveState: done / failed without a process; waiting on a quiet pending tool; tool, live, idle with one" {
    try t.expectEqual(AgentState.done, deriveState(false, 0, true, 1, false));
    try t.expectEqual(AgentState.failed, deriveState(false, 0, false, 0, true));
    try t.expectEqual(AgentState.tool_call, deriveState(true, 0, true, 1, false));
    try t.expectEqual(AgentState.waiting, deriveState(true, waiting_quiet_s, true, 1, false));
    try t.expectEqual(AgentState.waiting, deriveState(true, 600, false, 2, false));
    try t.expectEqual(AgentState.streaming, deriveState(true, 10, false, 0, false));
    try t.expectEqual(AgentState.idle, deriveState(true, 600, false, 0, false));
    try t.expect(AgentState.done.ended() and AgentState.failed.ended() and !AgentState.idle.ended());
    try t.expect(AgentState.waiting.rank() < AgentState.streaming.rank());
    try t.expect(AgentState.failed.rank() < AgentState.done.rank());
    // The filter cycle: every → waiting → … → done → every.
    var s: ?AgentState = null;
    var n: usize = 0;
    while (true) {
        s = AgentState.next(s);
        if (s == null) break;
        n += 1;
    }
    try t.expectEqual(@as(usize, 6), n);
}

test "the totals: a transcript past the tail is summed whole, each split message once; a rescan reads only what was appended; a cap is said" {
    // sess-table-tokens-cost-wrong.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, ".claude/projects/-tmp-p-long");
    const rel = ".claude/projects/-tmp-p-long/e2e0000a-0000-4000-8000-00000000a002.jsonl";
    // 300 turns of 1000 in / 200 out, each written as two lines that
    // repeat the id and the usage — ~600 KB, past `tail_cap`.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.appendSlice(t.allocator, "{\"type\":\"user\",\"cwd\":\"/tmp/p-long\",\"message\":{\"role\":\"user\",\"content\":\"long session\"}}\n");
    const pad = "x" ** 900;
    var i: usize = 0;
    while (i < 300) : (i += 1) for (0..2) |_| try text.print(t.allocator, "{{\"type\":\"assistant\",\"message\":{{\"id\":\"msg_l{d}\",\"model\":\"claude-opus-4-7\",\"usage\":{{\"input_tokens\":1000,\"output_tokens\":200}},\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}\n", .{ i, pad });
    try t.expect(text.items.len > tail_cap);
    try tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = text.items });
    var cache: TotalsCache = .{};
    defer cache.deinit(t.allocator);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var rows: std.ArrayListUnmanaged(Item) = .empty;
    try scanInto(t.io, t.allocator, arena.allocator(), home, nobody, &rows, &cache);
    try t.expectEqual(@as(usize, 1), rows.items.len);
    try t.expectEqual(@as(u64, 360_000), rows.items[0].tokens);
    // 300 × (1000 × $5 + 200 × $25) per MT.
    try t.expectApproxEqAbs(@as(f64, 3.0), rows.items[0].cost_usd, 1e-9);
    try t.expect(rows.items[0].cost_known and !rows.items[0].totals_capped);
    try t.expectEqual(@as(usize, 1), cache.map.count());
    var vi = cache.map.valueIterator();
    const summed = vi.next().?.offset;
    try t.expectEqual(@as(u64, text.items.len), summed);
    // One more turn, in the unknown model: the rescan reads just it.
    var f = try tmp.dir.openFile(t.io, rel, .{ .mode = .read_write });
    const more = "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_n\",\"model\":\"claude-next-9\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n";
    try f.writePositionalAll(t.io, more, text.items.len);
    f.close(t.io);
    rows = .empty;
    try scanInto(t.io, t.allocator, arena.allocator(), home, nobody, &rows, &cache);
    try t.expectEqual(@as(u64, 360_010), rows.items[0].tokens);
    try t.expect(!rows.items[0].cost_known);
    vi = cache.map.valueIterator();
    try t.expectEqual(summed + more.len, vi.next().?.offset);
    // A cap under the file's size: a floor, and said.
    var dir = try tmp.dir.openDir(t.io, ".claude/projects/-tmp-p-long", .{});
    defer dir.close(t.io);
    const capped = try totalsOf(t.io, t.allocator, dir, std.fs.path.basename(rel), rel, text.items.len, 64 * 1024, null);
    try t.expect(capped.capped);
    try t.expect(capped.usage.tokens > 0 and capped.usage.tokens < 360_000);
    // The file gone: the next pass drops its entry.
    try tmp.dir.deleteFile(t.io, rel);
    rows = .empty;
    try scanInto(t.io, t.allocator, arena.allocator(), home, nobody, &rows, &cache);
    try t.expectEqual(@as(usize, 0), cache.map.count());
}

test "scanInto reads a fixture home: claude and codex sessions, the tail stats, done without a pid, the branch kept" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const home = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".claude/projects/-Users-me-Projects-mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".claude/projects/-Users-me-Projects-mnml/aaaaaaaa-0000-4000-8000-000000000001.jsonl", .data = transcript.claude_fixture });
    try tmp.dir.createDirPath(t.io, ".codex/sessions/2026/09/04");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".codex/sessions/2026/09/04/rollout-2026-09-04T10-00-00-bbbbbbbb-0000-4000-8000-000000000002.jsonl", .data = transcript.codex_fixture });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var rows: std.ArrayListUnmanaged(Item) = .empty;
    try scanInto(t.io, t.allocator, arena.allocator(), home, nobody, &rows, null);
    try t.expectEqual(@as(usize, 2), rows.items.len);
    var claude_seen = false;
    var codex_seen = false;
    for (rows.items) |row| switch (row.source) {
        .claude => {
            claude_seen = true;
            try t.expectEqualStrings("mnml", row.workspace);
            try t.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000001", row.session_id);
            try t.expectEqual(@as(u64, 1620), row.tokens);
            try t.expectEqual(AgentState.done, row.state);
            try t.expectEqualStrings("fix the build", row.last_user_msg.?);
            try t.expectEqualStrings("main", row.git_branch.?);
            try t.expectEqual(sessions.Where.local, row.where);
        },
        .codex => {
            codex_seen = true;
            try t.expectEqualStrings("app", row.workspace);
            try t.expectEqualStrings("bbbbbbbb-0000-4000-8000-000000000002", row.session_id);
            try t.expectEqualStrings("gpt-5", row.model.?);
        },
    };
    try t.expect(claude_seen and codex_seen);
}

test "countPorcelain counts the entries; dirtyScan asks git once per cwd and leaves a cwd that is no repository null" {
    try t.expectEqual(@as(u32, 0), countPorcelain(""));
    try t.expectEqual(@as(u32, 2), countPorcelain(" M src/a.zig\n?? notes.md\n"));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const dir = buf[0..n];
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A fresh repository with one untracked file.
    const init = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "-C", dir, "init", "-q" } });
    t.allocator.free(init.stdout);
    t.allocator.free(init.stderr);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "x" });
    var rows = [_]Item{
        sessions.testItem("a", .idle, 100, "ws", null),
        sessions.testItem("b", .done, 100, "ws", null),
        sessions.testItem("old", .done, 0, "ws", null),
        sessions.testItem("gone", .idle, 100, "ws", null),
    };
    rows[0].cwd = dir;
    rows[1].cwd = dir;
    rows[2].cwd = dir;
    rows[3].cwd = "/nonexistent/mnml-sessions-merge-test";
    try dirtyScan(t.io, t.allocator, a, &rows, 100 + dirty_window_s);
    // Both rows of the cwd get the one count; the old ended one was not
    // asked; a cwd that is gone stays unknown.
    try t.expectEqual(@as(?u32, 1), rows[0].dirty);
    try t.expectEqual(@as(?u32, 1), rows[1].dirty);
    try t.expect(rows[2].dirty == null and rows[3].dirty == null);
    try t.expect(rows[1].dirtyEnded() and !rows[0].dirtyEnded());
}

test "transcriptMarkdown renders the turns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var row = sessions.testItem("abcdefgh-1", .done, 0, "mnml", "please fix the build");
    row.model = "claude-sonnet-4-5";
    const md = try transcriptMarkdown(arena.allocator(), row, transcript.claude_fixture);
    try t.expect(std.mem.startsWith(u8, md, "# claude session abcdefgh"));
    try t.expect(std.mem.indexOf(u8, md, "## User\n\nfix the build") != null);
    try t.expect(std.mem.indexOf(u8, md, "## Assistant\n\nLooking now.") != null);
    try t.expect(std.mem.indexOf(u8, md, "_tool: Bash_") != null);
}
