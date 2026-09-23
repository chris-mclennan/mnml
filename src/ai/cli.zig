//! The CLI backends: `claude -p` (print mode) and `codex exec`, one
//! shot each, run to completion on a worker. The argv builders are what
//! the tests pin; `run` is a thin wrap over `std.process.run` that
//! folds a non-zero exit into an error message.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const claude_binary = "claude";
pub const codex_binary = "codex";

/// `claude -p --output-format text [--session-id <id>] [--model <m>] <prompt>`.
pub fn claudeArgv(arena: Allocator, prompt: []const u8, session_id: ?[]const u8, model: ?[]const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ claude_binary, "-p", "--output-format", "text" });
    if (session_id) |sid| try argv.appendSlice(arena, &.{ "--session-id", sid });
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    try argv.append(arena, prompt);
    return argv.items;
}

/// `claude -p --output-format text [--session-id <id>] [--model <m>]`
/// with NO prompt argument: `claude -p` reads it from stdin. What a job
/// runs (`runJob` with `JobOpts.stdin`). A prompt in argv is capped by
/// the OS — 1 MiB for the whole argv on macOS, 128 KiB for one argument
/// on Linux — so a big file failed to spawn at all; and argv is what
/// `ps` shows every local user for the life of the call.
pub fn claudeStdinArgv(arena: Allocator, session_id: ?[]const u8, model: ?[]const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ claude_binary, "-p", "--output-format", "text" });
    if (session_id) |sid| try argv.appendSlice(arena, &.{ "--session-id", sid });
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    return argv.items;
}

/// `codex exec -`: the prompt on stdin, as `claudeStdinArgv`.
pub fn codexStdinArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ codex_binary, "exec", "-" });
}

/// `claude --resume <id>` — the interactive continuation of a one-shot.
pub fn claudeResumeArgv(arena: Allocator, session_id: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ claude_binary, "--resume", session_id });
}

/// `codex exec <prompt>`.
pub fn codexArgv(arena: Allocator, prompt: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ codex_binary, "exec", prompt });
}

/// The options `codex resume` takes that carry a value (`codex resume
/// --help`, CLI 0.146).
const codex_resume_value_flags = [_][]const u8{
    "-c",
    "--config",
    "--enable",
    "--disable",
    "--remote",
    "--remote-auth-token-env",
    "-i",
    "--image",
    "-m",
    "--model",
    "--local-provider",
    "-p",
    "--profile",
    "-s",
    "--sandbox",
    "-C",
    "--cd",
    "--add-dir",
    "-a",
    "--ask-for-approval",
};

/// The options `codex resume` takes that do not.
const codex_resume_bool_flags = [_][]const u8{
    "--strict-config",
    "--oss",
    "--dangerously-bypass-approvals-and-sandbox",
    "--dangerously-bypass-hook-trust",
    "--search",
    "--no-alt-screen",
};

fn inList(list: []const []const u8, a: []const u8) bool {
    for (list) |f| if (std.mem.eql(u8, f, a)) return true;
    return false;
}

/// Whether `a` is a `codex resume` option whose value is the NEXT argv
/// entry (`-m opus`, `--sandbox read-only`).
fn codexResumeTakesValue(a: []const u8) bool {
    return inList(&codex_resume_value_flags, a);
}

/// Whether `a` is a `codex resume` option that stands on its own — a
/// boolean (`--search`), a long option with its value attached
/// (`--model=opus`), or a short one with its value attached (`-mopus`).
fn codexResumeStandsAlone(a: []const u8) bool {
    if (inList(&codex_resume_bool_flags, a)) return true;
    if (std.mem.startsWith(u8, a, "--")) {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return false;
        return codexResumeTakesValue(a[0..eq]);
    }
    // `-mopus`: the first two characters name the option.
    if (a.len > 2 and a[0] == '-' and a[1] != '-') return codexResumeTakesValue(a[0..2]);
    return false;
}

/// `codex resume <id>` on `exe`, carrying over the options of `from`
/// (the pane's own command line) that `resume` accepts.
///
/// Codex has no `--session-id`: a session names itself in the rollout
/// it writes, and the id is looked up afterwards
/// (`ai/codex_rollout.zig`). So the restored line is BUILT here rather
/// than patched in place the way a Claude line is, and `exe` is the
/// pane's own binary — a profile shim keeps its shim.
///
/// What is dropped, and why: every positional — `from`'s own prompt,
/// which `codex resume [SESSION_ID] [PROMPT]` would re-send, and the
/// `resume <id>` this function writes itself, so a line it already
/// built is safe to pass back in — and the three options that PICK a
/// session, `--last` / `--all` / `--include-non-interactive`, which
/// would argue with the id this call exists to pass. Everything else
/// `resume` takes rides along, so a pane opened with `--search` or
/// `-m` comes back the same way. Pass `&.{}` for `from` when there is
/// nothing to carry.
pub fn codexResumeArgv(
    arena: Allocator,
    exe: []const u8,
    session_id: []const u8,
    from: []const []const u8,
) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "resume", session_id });
    // `from[0]` is the binary, which `exe` already is.
    var i: usize = @intFromBool(from.len > 0);
    while (i < from.len) : (i += 1) {
        const a = from[i];
        if (codexResumeTakesValue(a)) {
            if (i + 1 < from.len) {
                try argv.appendSlice(arena, &.{ a, from[i + 1] });
                i += 1;
            }
            continue;
        }
        if (codexResumeStandsAlone(a)) try argv.append(arena, a);
    }
    return argv.items;
}

pub const Outcome = struct {
    ok: bool,
    /// stdout on success, the trimmed stderr (or a fallback) on failure. Owned.
    text: []u8,
    /// `runJob`: the process could not be started at all; `text` is the
    /// OS's reason as an error name (`FileNotFound`, `AccessDenied`…),
    /// said as it is rather than guessed at.
    spawn_failed: bool = false,
};

/// Run `argv` in `cwd` and collect what it printed. `error.Failed`
/// only when the process could not be started; a non-zero exit is an
/// `Outcome` with `ok = false`.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) error{ OutOfMemory, Canceled, Failed }!Outcome {
    return runWithin(gpa, io, argv, cwd, env, null) catch |err| switch (err) {
        error.TimedOut => unreachable, // no budget was asked for
        else => |e| return e,
    };
}

/// `argv` with a bare `argv[0]` replaced by its absolute path, looked
/// up on the PATH of `env`.
///
/// `std.process.run` resolves `argv[0]` against the PARENT process's
/// environment — explicitly, and whatever `environ_map` says. So a
/// caller that hands mnml a PATH (a `.test` script's
/// `# env: PATH=${MNML_SHIMS}/…`, a launch profile's `env`) got the
/// environment it asked for everywhere EXCEPT in the one decision that
/// picks which binary runs: the fake was on the child's PATH and the
/// real `claude` was the one that answered. Resolving here is what
/// makes a shim a shim.
///
/// Anything not found is left alone, so the failure still comes back
/// as the spawn error the caller already words ("is it installed?").
fn resolveArgv(arena: Allocator, io: Io, argv: []const []const u8, env: ?*const std.process.Environ.Map) Allocator.Error![]const []const u8 {
    if (argv.len == 0) return argv;
    const name = argv[0];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return argv;
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, name, '\\') != null) return argv;
    const path = (env orelse return argv).get("PATH") orelse return argv;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(arena, &.{ dir, name }) catch return error.OutOfMemory;
        // Executable-or-not is the OS's call at spawn; existence is
        // all this needs to know to prefer an earlier PATH entry.
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        const out = try arena.dupe([]const u8, argv);
        out[0] = full;
        return out;
    }
    return argv;
}

/// `run` with a wall-clock budget. Past `timeout_ms` the child is
/// killed and `error.TimedOut` comes back. Ghost text asks for one
/// (`[ai] suggest_timeout_ms`): a `claude -p` that stalls would
/// otherwise hold the single in-flight slot until it felt like
/// answering, and the typist would have no way to tell that from a
/// backend that is merely slow. The kill is `std.process.run`'s own
/// `defer child.kill`, the same unwind a cancel takes.
pub fn runWithin(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
    timeout_ms: ?u64,
) error{ OutOfMemory, Canceled, Failed, TimedOut }!Outcome {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const resolved = try resolveArgv(scratch.allocator(), io, argv, env);
    const result = std.process.run(gpa, io, .{
        .argv = resolved,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = if (timeout_ms) |ms| .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(@min(ms, @as(u64, std.math.maxInt(i32))))),
            .clock = .awake,
        } } else .none,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.Timeout => return error.TimedOut,
        else => return error.Failed,
    };
    const ok = result.term == .exited and result.term.exited == 0;
    if (ok) {
        gpa.free(result.stderr);
        return .{ .ok = true, .text = result.stdout };
    }
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const err_text = std.mem.trim(u8, result.stderr, " \t\r\n");
    const msg = if (err_text.len > 0) err_text else if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) std.mem.trim(u8, result.stdout, " \t\r\n") else "the command failed";
    return .{ .ok = false, .text = try gpa.dupe(u8, msg[0..@min(msg.len, 400)]) };
}

/// How a one-shot job's child is run (`runJob`).
pub const JobOpts = struct {
    /// Wall-clock budget for the whole run; null is none. Past it the
    /// child is killed and `error.TimedOut` comes back.
    timeout_ms: ?u64 = null,
    /// Set by the UI (cancel, the pane closed, a re-ask): the child is
    /// killed within `poll_ms` and `error.Aborted` comes back.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// How often the flag and the clock are looked at while the child
    /// is quiet.
    poll_ms: u32 = 100,
    /// Written to the child's stdin, which is then closed — the prompt.
    /// Null: stdin is /dev/null.
    stdin: ?[]const u8 = null,
};

pub const JobError = error{ OutOfMemory, Canceled, Failed, TimedOut, Aborted };

/// One `claude -p` / `codex exec` for a job: the child is OURS until it
/// is reaped. It is killed — and reaped, by `Child.kill`, which waits —
/// when the job's cancel flag is set, when the budget runs out, and on
/// any other way out of this function. Never `wait` after `kill`: the
/// kill already reaped it.
///
/// `std.process.run` could not do this: it blocks in its read loop
/// until the child exits or the task is cancelled, and a job's worker
/// shares its `Io.Group` with every other job, so a cancel there would
/// have taken them all. The read loop here wakes every `poll_ms` to
/// look at the job's own flag instead.
pub fn runJob(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
    opts: JobOpts,
) JobError!Outcome {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const resolved = try resolveArgv(scratch.allocator(), io, argv, env);
    const t0 = Io.Timestamp.now(io, .awake);
    var child = std.process.spawn(io, .{
        .argv = resolved,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = if (opts.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .{ .ok = false, .text = try gpa.dupe(u8, @errorName(err)), .spawn_failed = true },
    };
    // The prompt goes in on a task of its own: a child that is slow to
    // read (or never reads) must not park this loop, which is the one
    // that watches the cancel flag. The file is the feeder's — taken off
    // the child so its kill does not close it under the write.
    var feeder: ?Io.Future(void) = null;
    if (opts.stdin) |text| {
        const in = child.stdin.?;
        child.stdin = null;
        feeder = io.concurrent(feed, .{ io, in, text }) catch blk: {
            // No second task to be had: write it here. A child that
            // reads its prompt first (both CLIs do) takes it all.
            feed(io, in, text);
            break :blk null;
        };
    }
    // Kills and reaps on every early return (a no-op after `wait`), and
    // only then collects the feeder: the kill is what unblocks a write
    // into a pipe nobody reads.
    defer {
        child.kill(io);
        if (feeder) |*f| f.await(io);
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_limit: usize = 8 * 1024 * 1024;
    const stderr_limit: usize = 1024 * 1024;
    const poll: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@max(opts.poll_ms, 1)), .clock = .awake } };
    while (true) {
        if (opts.cancel) |c| if (c.load(.acquire)) return error.Aborted;
        if (opts.timeout_ms) |ms| if (t0.untilNow(io, .awake).toMilliseconds() >= @as(i64, @intCast(@min(ms, std.math.maxInt(i63))))) return error.TimedOut;
        multi_reader.fill(64, poll) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => continue,
            error.Canceled => return error.Canceled,
            else => return error.Failed,
        };
        if (multi_reader.reader(0).buffered().len > stdout_limit or multi_reader.reader(1).buffered().len > stderr_limit) return error.Failed;
    }
    multi_reader.checkAnyError() catch return error.Failed;
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Failed,
    };
    const stdout = multi_reader.reader(0).buffered();
    const stderr = multi_reader.reader(1).buffered();
    if (term == .exited and term.exited == 0) return .{ .ok = true, .text = try gpa.dupe(u8, stdout) };
    const err_text = std.mem.trim(u8, stderr, " \t\r\n");
    const out_text = std.mem.trim(u8, stdout, " \t\r\n");
    const msg = if (err_text.len > 0) err_text else if (out_text.len > 0) out_text else "the command failed";
    return .{ .ok = false, .text = try gpa.dupe(u8, msg[0..@min(msg.len, 400)]) };
}

/// Write `text` to a child's stdin and close it. A child that exits (or
/// is killed) before reading it all ends the write with a broken pipe,
/// which is not this function's to report.
fn feed(io: Io, file: Io.File, text: []const u8) void {
    file.writeStreamingAll(io, text) catch {};
    file.close(io);
}

/// A UUID v4 for `--session-id`.
pub fn genSessionId(io: Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 0xf];
        o += 2;
    }
    return out;
}

/// The first fenced code block of a markdown answer, without the fence.
pub fn firstCodeBlock(md: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, md, "```") orelse return null;
    const after_lang = std.mem.indexOfScalarPos(u8, md, open + 3, '\n') orelse return null;
    const start = after_lang + 1;
    const close = std.mem.indexOfPos(u8, md, start, "\n```") orelse return null;
    return md[start..close];
}

/// The prompt for `ai.explain` / `fix` / `refactor` / `write_tests`.
pub fn actionPrompt(arena: Allocator, what: []const u8, code: []const u8, lang: []const u8) Allocator.Error![]u8 {
    const ask: []const u8 = if (std.mem.eql(u8, what, "explain"))
        "Explain what this code does, concisely."
    else if (std.mem.eql(u8, what, "fix"))
        "Find bugs in this code and return the corrected code in one fenced block, then a short list of what changed."
    else if (std.mem.eql(u8, what, "refactor"))
        "Refactor this code for clarity without changing behaviour. Return the full result in one fenced block, then a short list of what changed."
    else if (std.mem.eql(u8, what, "write_tests"))
        "Write unit tests for this code in the same language, in one fenced block."
    else
        what;
    return std.fmt.allocPrint(arena, "{s}\n\n```{s}\n{s}\n```\n", .{ ask, lang, code });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "argv builders" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try claudeArgv(a, "hello there", "abc", null);
    try t.expectEqualSlices([]const u8, &.{ "claude", "-p", "--output-format", "text", "--session-id", "abc", "hello there" }, argv);
    const with_model = try claudeArgv(a, "p", null, "haiku");
    try t.expectEqualStrings("--model", with_model[4]);
    try t.expectEqualStrings("p", with_model[with_model.len - 1]);
    try t.expectEqualSlices([]const u8, &.{ "codex", "exec", "p" }, try codexArgv(a, "p"));
    try t.expectEqualSlices([]const u8, &.{ "claude", "--resume", "s" }, try claudeResumeArgv(a, "s"));
}

test "codexResumeArgv: the id, the pane's own binary, the flags resume takes — and nothing that would pick a different session" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The plain case: a pane opened as bare `codex`.
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9" }, try codexResumeArgv(a, "codex", "sid-9", &.{"codex"}));
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9" }, try codexResumeArgv(a, "codex", "sid-9", &.{}));

    // The binary is the pane's, so a launch profile keeps its shim.
    const shim = try codexResumeArgv(a, "/d/mnml-ai-work", "sid-9", &.{"/d/mnml-ai-work"});
    try t.expectEqualStrings("/d/mnml-ai-work", shim[0]);

    // The flags `resume` takes ride along, in either spelling.
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9", "-m", "gpt-5", "--search", "--sandbox", "read-only" }, try codexResumeArgv(a, "codex", "sid-9", &.{ "codex", "-m", "gpt-5", "--search", "--sandbox", "read-only" }));
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9", "--model=gpt-5", "-mgpt-5" }, try codexResumeArgv(a, "codex", "sid-9", &.{ "codex", "--model=gpt-5", "-mgpt-5" }));

    // The prompt is a positional and is NOT re-sent; neither are the
    // three options that would pick a session of their own, nor
    // anything `resume` does not know.
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9" }, try codexResumeArgv(a, "codex", "sid-9", &.{ "codex", "fix the tests" }));
    try t.expectEqualSlices([]const u8, &.{ "codex", "resume", "sid-9" }, try codexResumeArgv(a, "codex", "sid-9", &.{ "codex", "--last", "--all", "--include-non-interactive", "--full-auto" }));

    // A line this function already built comes back unchanged: the
    // `resume` and the id are positionals, so the restore is idempotent.
    const once = try codexResumeArgv(a, "codex", "sid-9", &.{ "codex", "--search" });
    try t.expectEqualSlices([]const u8, once, try codexResumeArgv(a, "codex", "sid-9", once));
}

test "session ids are v4 uuids and distinct" {
    const a = genSessionId(t.io);
    const b = genSessionId(t.io);
    try t.expect(!std.mem.eql(u8, &a, &b));
    try t.expectEqual(@as(u8, '-'), a[8]);
    try t.expectEqual(@as(u8, '4'), a[14]);
    try t.expect(a[19] == '8' or a[19] == '9' or a[19] == 'a' or a[19] == 'b');
}

test "first code block and the action prompt" {
    try t.expectEqualStrings("fn x() {}", firstCodeBlock("Here:\n\n```zig\nfn x() {}\n```\n\n- changed").?);
    try t.expect(firstCodeBlock("no fence") == null);
    try t.expect(firstCodeBlock("```zig\nunterminated") == null);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try actionPrompt(arena.allocator(), "explain", "x = 1", "py");
    try t.expect(std.mem.startsWith(u8, p, "Explain what this code does"));
    try t.expect(std.mem.indexOf(u8, p, "```py\nx = 1\n```") != null);
}

test "run: a shell that exits 0 hands back stdout; a failure hands back stderr" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const ok = try run(t.allocator, t.io, &.{ "/bin/sh", "-c", "printf hello" }, "/tmp", null);
    defer t.allocator.free(ok.text);
    try t.expect(ok.ok);
    try t.expectEqualStrings("hello", ok.text);
    const bad = try run(t.allocator, t.io, &.{ "/bin/sh", "-c", "echo boom >&2; exit 3" }, "/tmp", null);
    defer t.allocator.free(bad.text);
    try t.expect(!bad.ok);
    try t.expectEqualStrings("boom", bad.text);
    try t.expectError(error.Failed, run(t.allocator, t.io, &.{"/definitely/not/a/binary"}, "/tmp", null));
}

test "the binary is resolved on the caller's PATH, not the parent process's" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // The whole point of a shim: a `.test` that puts a fake `claude`
    // first on PATH must get the fake. `std.process.run` resolves
    // `argv[0]` against the PARENT environment whatever `environ_map`
    // says, so without `resolveArgv` the user's real CLI answers — and
    // the corpus quietly drives their actual Claude account.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "git", .data = "#!/bin/sh\nprintf SHIMMED\n" });
    try tmp.dir.setFilePermissions(t.io, "git", .fromMode(0o755), .{});

    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("PATH", dir);
    const out = try run(t.allocator, t.io, &.{ "git", "--version" }, "/tmp", &env);
    defer t.allocator.free(out.text);
    try t.expectEqualStrings("SHIMMED", out.text);

    // An absolute argv[0] is left alone, and so is a name nothing on
    // that PATH provides — the spawn failure is still the caller's to
    // word.
    const abs = try run(t.allocator, t.io, &.{ "/bin/sh", "-c", "printf REAL" }, "/tmp", &env);
    defer t.allocator.free(abs.text);
    try t.expectEqualStrings("REAL", abs.text);
    try t.expectError(error.Failed, run(t.allocator, t.io, &.{"definitely-not-a-binary"}, "/tmp", &env));
}

test "runWithin: a child that sleeps past the budget is killed, and the call comes back inside it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // The evidence that the CHILD dies and not just our interest in it:
    // `sleep 30` would hold the call for 30 s if the budget only
    // dropped the result. `process.run`'s `defer child.kill` is what
    // makes the return prompt.
    const t0 = Io.Timestamp.now(t.io, .awake);
    try t.expectError(error.TimedOut, runWithin(t.allocator, t.io, &.{ "/bin/sh", "-c", "sleep 30" }, "/tmp", null, 200));
    const elapsed = t0.untilNow(t.io, .awake).toMilliseconds();
    try t.expect(elapsed < 5_000);
    // A budget the command finishes inside of is not a timeout.
    const ok = try runWithin(t.allocator, t.io, &.{ "/bin/sh", "-c", "printf quick" }, "/tmp", null, 10_000);
    defer t.allocator.free(ok.text);
    try t.expectEqualStrings("quick", ok.text);
}

test "runJob: the cancel flag kills the child and reaps it, and the call comes back at once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    // The child writes its own pid, then sleeps far past the test.
    const script = try std.fmt.allocPrint(t.allocator, "echo $$ > {s}/pid; exec sleep 30", .{dir});
    defer t.allocator.free(script);
    var cancel: std.atomic.Value(bool) = .init(false);
    const Canceller = struct {
        fn run(io: Io, flag: *std.atomic.Value(bool)) Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(300), .awake);
            flag.store(true, .release);
        }
    };
    var group: Io.Group = .init;
    defer group.cancel(t.io);
    try group.concurrent(t.io, Canceller.run, .{ t.io, &cancel });
    const t0 = Io.Timestamp.now(t.io, .awake);
    try t.expectError(error.Aborted, runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", script }, dir, null, .{ .cancel = &cancel }));
    try t.expect(t0.untilNow(t.io, .awake).toMilliseconds() < 5_000);
    // The pid it wrote is gone: killed AND reaped (a zombie would still
    // answer signal 0).
    const pid_text = try tmp.dir.readFileAlloc(t.io, "pid", t.allocator, .limited(64));
    defer t.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
    try t.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

test "runJob: past the budget the child is killed and TimedOut comes back; a quick one answers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const t0 = Io.Timestamp.now(t.io, .awake);
    try t.expectError(error.TimedOut, runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", "sleep 30" }, "/tmp", null, .{ .timeout_ms = 300 }));
    try t.expect(t0.untilNow(t.io, .awake).toMilliseconds() < 5_000);
    const ok = try runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", "printf quick" }, "/tmp", null, .{ .timeout_ms = 10_000 });
    defer t.allocator.free(ok.text);
    try t.expect(ok.ok);
    try t.expectEqualStrings("quick", ok.text);
    const bad = try runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", "echo boom >&2; exit 3" }, "/tmp", null, .{});
    defer t.allocator.free(bad.text);
    try t.expect(!bad.ok);
    try t.expectEqualStrings("boom", bad.text);
}

test "runJob: the prompt goes in on stdin, however big — nothing of it in argv" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // 2 MiB: past macOS's whole-argv limit and Linux's per-argument one.
    const big = try t.allocator.alloc(u8, 2 * 1024 * 1024);
    defer t.allocator.free(big);
    @memset(big, 'x');
    big[big.len - 1] = '!';
    const out = try runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", "wc -c | tr -d ' '; echo \"argc=$#\"" }, "/tmp", null, .{ .stdin = big });
    defer t.allocator.free(out.text);
    try t.expect(out.ok);
    try t.expectEqualStrings("2097152\nargc=0\n", out.text);
    // A child that never reads its stdin still ends on the budget: the
    // feeder is unblocked by the kill, not left behind.
    try t.expectError(error.TimedOut, runJob(t.allocator, t.io, &.{ "/bin/sh", "-c", "exec sleep 30" }, "/tmp", null, .{ .stdin = big, .timeout_ms = 300 }));
}

test "runJob: a binary that cannot be started says why, in the OS's words" {
    const out = try runJob(t.allocator, t.io, &.{"/definitely/not/a/binary"}, "/tmp", null, .{ .stdin = "hi" });
    defer t.allocator.free(out.text);
    try t.expect(!out.ok);
    try t.expect(out.spawn_failed);
    try t.expectEqualStrings("FileNotFound", out.text);
}

test "the stdin argv builders carry no prompt" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualSlices([]const u8, &.{ "claude", "-p", "--output-format", "text", "--session-id", "s", "--model", "m" }, try claudeStdinArgv(a, "s", "m"));
    try t.expectEqualSlices([]const u8, &.{ "claude", "-p", "--output-format", "text" }, try claudeStdinArgv(a, null, null));
    try t.expectEqualSlices([]const u8, &.{ "codex", "exec", "-" }, try codexStdinArgv(a));
}
