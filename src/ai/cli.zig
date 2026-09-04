//! The CLI backends: `claude -p` (print mode) and `codex exec`, one
//! shot each, run to completion on a worker. The argv builders are what
//! the tests pin; `run` is a thin wrap over `std.process.run` that
//! folds a non-zero exit into an error message.

const std = @import("std");
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

/// `claude --resume <id>` — the interactive continuation of a one-shot.
pub fn claudeResumeArgv(arena: Allocator, session_id: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ claude_binary, "--resume", session_id });
}

/// `codex exec <prompt>`.
pub fn codexArgv(arena: Allocator, prompt: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ codex_binary, "exec", prompt });
}

pub const Outcome = struct {
    ok: bool,
    /// stdout on success, the trimmed stderr (or a fallback) on failure. Owned.
    text: []u8,
};

/// Run `argv` in `cwd` and collect what it printed. `error.Failed`
/// only when the process could not be started; a non-zero exit is an
/// `Outcome` with `ok = false`.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) error{ OutOfMemory, Canceled, Failed }!Outcome {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
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
