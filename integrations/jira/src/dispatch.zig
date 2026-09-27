//! The Claude-Code dispatch queue — the reference's `dispatch.rs`. An
//! action on a ticket (Implement / Fix / Triage / Test, or Review on a
//! PR) is written two ways at once, each only when its directory exists
//! under `dispatch_workspace`: one JSON line appended to
//! `<ws>/.claude/queue.jsonl` for a watcher agent, and one mnml IPC line
//! appended to `<ws>/.mnml/ipc/command` asking the running mnml to open
//! a terminal pane with `claude` seeded by the prompt. The status line
//! says which channels fired.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model = @import("model.zig");

const Issue = model.Issue;

pub const Button = enum {
    implement,
    fix,
    triage,
    test_,
    review,

    pub fn label(b: Button) []const u8 {
        return switch (b) {
            .implement => "[ Implement ]",
            .fix => "[ Fix ]",
            .triage => "[ Triage ]",
            .test_ => "[ Test ]",
            .review => "[ Review ]",
        };
    }

    /// What lands in the queue line and picks the slash command.
    pub fn kind(b: Button) []const u8 {
        return switch (b) {
            .implement => "implement",
            .fix => "fix",
            .triage => "triage",
            .test_ => "test",
            .review => "review",
        };
    }

    pub fn fromKind(s: []const u8) ?Button {
        inline for (@typeInfo(Button).@"enum".fields) |f| {
            const b: Button = @enumFromInt(f.value);
            if (std.mem.eql(u8, b.kind(), s)) return b;
        }
        return null;
    }
};

// Chronological, the order the work happens in: triage a ticket, then
// implement or fix it, then test it. Every mnml pane that paints row
// buttons reads left to right in that order.
const implement_triage = [_]Button{ .triage, .implement };
const fix_triage = [_]Button{ .triage, .fix };
const test_only = [_]Button{.test_};
const review_only = [_]Button{.review};
const triage_only = [_]Button{.triage};

/// The reference's rules: Testing → Test; PR review → Review; a Story /
/// Task in To Do / Open / In Progress → Implement + Triage; a Bug there
/// → Fix + Triage; a reopened Bug → Triage; anything else nothing.
pub fn buttonsForTicket(iss: Issue) []const Button {
    const status = iss.status;
    if (std.ascii.eqlIgnoreCase(status, "testing")) return &test_only;
    const review = [_][]const u8{ "in pr review", "in code review", "code review", "pr review", "in review" };
    for (review) |r| if (std.ascii.eqlIgnoreCase(status, r)) return &review_only;
    const active = std.ascii.eqlIgnoreCase(status, "to do") or std.ascii.eqlIgnoreCase(status, "open") or std.ascii.eqlIgnoreCase(status, "in progress");
    const t = iss.issuetype;
    if ((std.ascii.eqlIgnoreCase(t, "story") or std.ascii.eqlIgnoreCase(t, "task")) and active) return &implement_triage;
    if (std.ascii.eqlIgnoreCase(t, "bug")) {
        if (active) return &fix_triage;
        if (std.ascii.eqlIgnoreCase(status, "reopened")) return &triage_only;
    }
    return &.{};
}

pub const Dispatch = struct {
    kind: []const u8,
    issue_key: []const u8,
    issue_type: []const u8,
    summary: []const u8,
    jira_url: []const u8,
    pr_url: ?[]const u8 = null,
    /// ISO-8601 UTC, supplied by the caller (the clock is theirs).
    queued_at: []const u8,

    pub fn forTicket(kind: []const u8, iss: Issue, jira_url: []const u8, queued_at: []const u8) Dispatch {
        return .{ .kind = kind, .issue_key = iss.key, .issue_type = iss.issuetype, .summary = iss.summary, .jira_url = jira_url, .queued_at = queued_at };
    }

    pub fn forPr(iss: Issue, jira_url: []const u8, pr_url: []const u8, queued_at: []const u8) Dispatch {
        return .{ .kind = "review", .issue_key = iss.key, .issue_type = iss.issuetype, .summary = iss.summary, .jira_url = jira_url, .pr_url = pr_url, .queued_at = queued_at };
    }

    /// The prompt the terminal pane seeds `claude` with.
    pub fn prompt(d: Dispatch, arena: Allocator) Allocator.Error![]const u8 {
        const slash = if (std.mem.eql(u8, d.kind, "implement") or std.mem.eql(u8, d.kind, "fix") or std.mem.eql(u8, d.kind, "triage"))
            try std.fmt.allocPrint(arena, "/agents:developer {s}", .{d.issue_key})
        else if (std.mem.eql(u8, d.kind, "review"))
            try std.fmt.allocPrint(arena, "/agents:reviewer {s}", .{d.pr_url orelse d.issue_key})
        else if (std.mem.eql(u8, d.kind, "test"))
            try std.fmt.allocPrint(arena, "/agents:tester {s} mode=ticket", .{d.issue_key})
        else
            try std.fmt.allocPrint(arena, "/agents:{s} {s}", .{ d.kind, d.issue_key });
        const pr_line = if (d.pr_url) |u| try std.fmt.allocPrint(arena, "pr: {s}\n", .{u}) else "";
        return std.fmt.allocPrint(arena, "{s}\n\n<!-- context -->\nkind: {s}\nticket: {s} ({s}) — {s}\nurl: {s}\n{s}", .{ slash, d.kind, d.issue_key, d.issue_type, d.summary, d.jira_url, pr_line });
    }

    /// The queue line (no trailing newline).
    pub fn queueLine(d: Dispatch, arena: Allocator) Allocator.Error![]const u8 {
        return std.json.Stringify.valueAlloc(arena, d, .{ .emit_null_optional_fields = false });
    }

    /// The mnml IPC line: `{"cmd":"term","args":["sh","-c","claude <<'MNML_EOF'\n…\nMNML_EOF"]}`.
    pub fn termLine(d: Dispatch, arena: Allocator) Allocator.Error![]const u8 {
        const shell = try std.fmt.allocPrint(arena, "claude <<'MNML_EOF'\n{s}\nMNML_EOF", .{try d.prompt(arena)});
        const args = [_][]const u8{ "sh", "-c", shell };
        return std.json.Stringify.valueAlloc(arena, .{ .cmd = "term", .args = &args }, .{});
    }
};

pub const Paths = struct {
    /// `<ws>/.claude`, when it exists.
    queue_dir: ?[]const u8 = null,
    /// The IPC directory of the mnml that will actually run the `term`
    /// line, when there is one.
    ipc_dir: ?[]const u8 = null,
};

/// The channel-directory name a Zig mnml uses under `<ws>/.mnml/`. The
/// Rust host's is `ipc`; writing there from inside a Zig host is how a
/// dispatch used to land in a file nothing was reading.
pub const ipc_subdir = "ipc-zig";

/// Where the two channels are.
///
///   * the queue: `<dispatch_workspace>/.claude`, when it exists.
///   * the pane: **`$MNML_IPC_DIR` first** — the host sets it for every
///     integration it spawns, and it names the channel of the mnml this
///     pane is running inside, which is the only mnml that will act on
///     a `term` line. Failing that, `<dispatch_workspace>/.mnml/ipc-zig`,
///     for a run started outside a host.
///
/// It used to be `<dispatch_workspace>/.mnml/ipc` unconditionally: the
/// Rust host's directory name, on a workspace no Zig instance was
/// running. The line was written, nothing read it, and Triage looked
/// like it did nothing.
pub fn workspacePaths(arena: Allocator, io: Io, root: []const u8, ipc_override: []const u8) Allocator.Error!Paths {
    var out: Paths = .{};
    if (root.len > 0) {
        const q = try std.fs.path.join(arena, &.{ root, ".claude" });
        if (dirExists(io, q)) out.queue_dir = q;
    }
    if (ipc_override.len > 0 and dirExists(io, ipc_override)) {
        out.ipc_dir = try arena.dupe(u8, ipc_override);
    } else if (root.len > 0) {
        const i = try std.fs.path.join(arena, &.{ root, ".mnml", ipc_subdir });
        if (dirExists(io, i)) out.ipc_dir = i;
    }
    return out;
}

fn dirExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// What one fire did: the sentence for the status line, and whether a
/// session was actually started — which is what turns a row's button
/// into `[ view ]` rather than a red cross.
pub const Outcome = struct { text: []const u8, fired: bool };

/// Fire both channels. Returns the status-line summary:
/// `implement → queue + pane`, `… (also: pane: …)`, `… failed: …`, or
/// `…: nothing to dispatch to — …` naming both channels it looked for.
pub fn fire(arena: Allocator, io: Io, d: Dispatch, paths: Paths) Allocator.Error![]const u8 {
    return (try fireOutcome(arena, io, d, paths)).text;
}

/// Fire a prompt that is not a ticket dispatch — the merge confirm's,
/// which names a pull request rather than an issue. Only the pane
/// channel: `queue.jsonl` is a ticket queue, and a merge is not a
/// ticket.
pub fn firePrompt(arena: Allocator, io: Io, kind: []const u8, prompt_text: []const u8, paths: Paths) Allocator.Error!Outcome {
    const dir = paths.ipc_dir orelse return .{
        .fired = false,
        .text = try std.fmt.allocPrint(arena, "{s}: no mnml IPC channel ($MNML_IPC_DIR, else <ws>/.mnml/" ++ ipc_subdir ++ ")", .{kind}),
    };
    const cmd = try std.fs.path.join(arena, &.{ dir, "command" });
    if (!fileExists(io, cmd)) return .{ .fired = false, .text = try std.fmt.allocPrint(arena, "{s}: no mnml IPC command file at {s}", .{ kind, cmd }) };
    const shell = try std.fmt.allocPrint(arena, "claude <<'MNML_EOF'\n{s}\nMNML_EOF", .{prompt_text});
    const args = [_][]const u8{ "sh", "-c", shell };
    const line = try std.json.Stringify.valueAlloc(arena, .{ .cmd = "term", .args = &args }, .{});
    appendLine(arena, io, dir, "command", line) catch |err| {
        return .{ .fired = false, .text = try std.fmt.allocPrint(arena, "{s} failed: {s}", .{ kind, @errorName(err) }) };
    };
    return .{ .fired = true, .text = try std.fmt.allocPrint(arena, "{s} \u{2192} pane", .{kind}) };
}

pub fn fireOutcome(arena: Allocator, io: Io, d: Dispatch, paths: Paths) Allocator.Error!Outcome {
    var fired: std.ArrayList([]const u8) = .empty;
    var errors: std.ArrayList([]const u8) = .empty;
    if (paths.queue_dir) |dir| {
        if (appendLine(arena, io, dir, "queue.jsonl", try d.queueLine(arena))) {
            try fired.append(arena, "queue");
        } else |err| try errors.append(arena, try std.fmt.allocPrint(arena, "queue: {s}", .{@errorName(err)}));
    }
    if (paths.ipc_dir) |dir| {
        const cmd = try std.fs.path.join(arena, &.{ dir, "command" });
        if (!fileExists(io, cmd)) {
            try errors.append(arena, try std.fmt.allocPrint(arena, "pane: no mnml IPC command file at {s}", .{cmd}));
        } else if (appendLine(arena, io, dir, "command", try d.termLine(arena))) {
            try fired.append(arena, "pane");
        } else |err| try errors.append(arena, try std.fmt.allocPrint(arena, "pane: {s}", .{@errorName(err)}));
    }
    const fired_s = try std.mem.join(arena, " + ", fired.items);
    const errors_s = try std.mem.join(arena, "; ", errors.items);
    // A session was started only when the PANE channel took the line:
    // the queue on its own is a note for a watcher agent, not something
    // this mnml can bring to the front.
    var started = false;
    for (fired.items) |f| if (std.mem.eql(u8, f, "pane")) {
        started = true;
    };
    if (fired.items.len > 0 and errors.items.len == 0) return .{ .fired = started, .text = try std.fmt.allocPrint(arena, "{s} → {s}", .{ d.kind, fired_s }) };
    if (fired.items.len > 0) return .{ .fired = started, .text = try std.fmt.allocPrint(arena, "{s} → {s} (also: {s})", .{ d.kind, fired_s, errors_s }) };
    if (errors.items.len > 0) return .{ .fired = false, .text = try std.fmt.allocPrint(arena, "{s} failed: {s}", .{ d.kind, errors_s }) };
    // Neither channel is there. Say which two were looked for, because
    // "nothing happened" with no reason is what this used to look like.
    return .{ .fired = false, .text = try std.fmt.allocPrint(arena, "{s}: nothing to dispatch to — no `.claude/` under the dispatch workspace and no mnml IPC channel ($MNML_IPC_DIR, else <ws>/.mnml/" ++ ipc_subdir ++ ")", .{d.kind}) };
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn appendLine(arena: Allocator, io: Io, dir: []const u8, name: []const u8, line: []const u8) !void {
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    const with_nl = try std.mem.concat(arena, u8, &.{ line, "\n" });
    try file.writePositionalAll(io, with_nl, end);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn issue(key: []const u8, status: []const u8, t: []const u8, summary: []const u8) Issue {
    return .{ .key = key, .status = status, .issuetype = t, .summary = summary };
}

test "the buttons follow the reference's type + status table" {
    try testing.expectEqualSlices(Button, &.{ .triage, .implement }, buttonsForTicket(issue("TE-1", "To Do", "Story", "s")));
    try testing.expectEqualSlices(Button, &.{ .triage, .implement }, buttonsForTicket(issue("TE-1", "In Progress", "Task", "t")));
    try testing.expectEqualSlices(Button, &.{ .triage, .fix }, buttonsForTicket(issue("TE-1", "To Do", "Bug", "b")));
    try testing.expectEqualSlices(Button, &.{.test_}, buttonsForTicket(issue("TE-1", "Testing", "Bug", "b")));
    try testing.expectEqualSlices(Button, &.{.review}, buttonsForTicket(issue("TE-1", "In PR Review", "Bug", "b")));
    try testing.expectEqualSlices(Button, &.{.triage}, buttonsForTicket(issue("TE-1", "Reopened", "Bug", "b")));
    try testing.expectEqual(@as(usize, 0), buttonsForTicket(issue("TE-1", "Done", "Story", "s")).len);
    try testing.expectEqual(@as(usize, 0), buttonsForTicket(issue("TE-1", "Cancelled", "Task", "s")).len);
    try testing.expectEqual(Button.fix, Button.fromKind("fix").?);
    try testing.expect(Button.fromKind("nope") == null);
    try testing.expectEqualStrings("[ Implement ]", Button.implement.label());
}

test "a dispatch carries the ticket, its prompt picks the agent, and the two lines are the reference's shapes" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const iss = issue("ENG-14337", "To Do", "Story", "add data-cy");
    const d = Dispatch.forTicket("implement", iss, "https://x/browse/ENG-14337", "2026-09-15T10:00:00Z");
    try testing.expectEqualStrings("implement", d.kind);
    try testing.expect(d.pr_url == null);
    const p = try d.prompt(arena);
    try testing.expect(std.mem.startsWith(u8, p, "/agents:developer ENG-14337\n\n<!-- context -->\nkind: implement\nticket: ENG-14337 (Story) — add data-cy\nurl: https://x/browse/ENG-14337\n"));
    const q = try d.queueLine(arena);
    try testing.expectEqualStrings("{\"kind\":\"implement\",\"issue_key\":\"ENG-14337\",\"issue_type\":\"Story\",\"summary\":\"add data-cy\",\"jira_url\":\"https://x/browse/ENG-14337\",\"queued_at\":\"2026-09-15T10:00:00Z\"}", q);
    const t = try d.termLine(arena);
    try testing.expect(std.mem.startsWith(u8, t, "{\"cmd\":\"term\",\"args\":[\"sh\",\"-c\",\"claude <<'MNML_EOF'\\n/agents:developer ENG-14337"));
    try testing.expect(std.mem.endsWith(u8, t, "\\nMNML_EOF\"]}"));
    const r = Dispatch.forPr(iss, "https://x/browse/ENG-14337", "https://bitbucket.org/acme/foo/pull-requests/2023", "now");
    try testing.expect(std.mem.startsWith(u8, try r.prompt(arena), "/agents:reviewer https://bitbucket.org/acme/foo/pull-requests/2023"));
    try testing.expect(std.mem.indexOf(u8, try r.prompt(arena), "pr: https://bitbucket.org/acme/foo/pull-requests/2023\n") != null);
    try testing.expect(std.mem.indexOf(u8, try r.queueLine(arena), "\"pr_url\":\"https://bitbucket.org") != null);
    const tst = Dispatch.forTicket("test", iss, "u", "now");
    try testing.expect(std.mem.startsWith(u8, try tst.prompt(arena), "/agents:tester ENG-14337 mode=ticket"));
}

test "fire writes the queue line and the IPC line where the directories exist, and says what it did" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const d = Dispatch.forTicket("implement", issue("TE-1", "To Do", "Story", "s"), "https://x/browse/TE-1", "now");
    // Nothing there: no channels, and the line says which two it looked for.
    const none = try fire(arena, io, d, try workspacePaths(arena, io, root, ""));
    try testing.expect(std.mem.startsWith(u8, none, "implement: nothing to dispatch to"));
    try testing.expect(std.mem.indexOf(u8, none, "MNML_IPC_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, none, ipc_subdir) != null);
    try testing.expect(std.mem.startsWith(u8, try fire(arena, io, d, try workspacePaths(arena, io, "", "")), "implement: nothing to dispatch to"));
    // The queue dir: one line per fire.
    try tmp.dir.createDirPath(io, ".claude");
    try testing.expectEqualStrings("implement → queue", try fire(arena, io, d, try workspacePaths(arena, io, root, "")));
    _ = try fire(arena, io, d, try workspacePaths(arena, io, root, ""));
    const q = try tmp.dir.readFileAlloc(io, ".claude/queue.jsonl", arena, .unlimited);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, q, "\n"));
    try testing.expect(std.mem.indexOf(u8, q, "\"issue_key\":\"TE-1\"") != null);
    // The Rust host's directory name is NOT the fallback: a `.mnml/ipc`
    // is what a Rust mnml reads, and writing there from inside a Zig
    // host is the bug this test exists for.
    try tmp.dir.createDirPath(io, ".mnml/ipc");
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/ipc/command", .data = "" });
    try testing.expectEqualStrings("implement → queue", try fire(arena, io, d, try workspacePaths(arena, io, root, "")));
    // The IPC dir without a command file: the pane channel says so.
    try tmp.dir.createDirPath(io, ".mnml/" ++ ipc_subdir);
    const partial = try fire(arena, io, d, try workspacePaths(arena, io, root, ""));
    try testing.expect(std.mem.startsWith(u8, partial, "implement → queue (also: pane: no mnml IPC command file"));
    // With the file, both fire.
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/" ++ ipc_subdir ++ "/command", .data = "" });
    try testing.expectEqualStrings("implement → queue + pane", try fire(arena, io, d, try workspacePaths(arena, io, root, "")));
    const c = try tmp.dir.readFileAlloc(io, ".mnml/" ++ ipc_subdir ++ "/command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, c, "\"cmd\":\"term\"") != null);

    // Inside a host, `$MNML_IPC_DIR` is the channel — the only one the
    // mnml running this pane is reading.
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/command", .data = "" });
    const override = try std.fs.path.join(arena, &.{ root, "elsewhere" });
    try testing.expectEqualStrings("implement → queue + pane", try fire(arena, io, d, try workspacePaths(arena, io, root, override)));
    const e = try tmp.dir.readFileAlloc(io, "elsewhere/command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, e, "\"cmd\":\"term\"") != null);
    // …and the workspace's own channel did not get a second copy.
    const c2 = try tmp.dir.readFileAlloc(io, ".mnml/" ++ ipc_subdir ++ "/command", arena, .unlimited);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, c2, "\n"));
}
