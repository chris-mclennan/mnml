//! The Windows session's platform-neutral pieces: how argv becomes one
//! `CreateProcessW` command line, how an exit code becomes an `Exit`,
//! which shell to run. Pure functions, so they are tested on every host —
//! the only part of `session_windows.zig` that can be.
//!
//! The quoting is std's `argvToCommandLineWindows` (private in Zig 0.16's
//! `Io/Threaded.zig`), reproduced with its test vectors: `arg0` follows
//! `CreateProcessW`'s own rule (quotes only, no escaping, a `"` inside is
//! unrepresentable), the rest follow `CommandLineToArgvW`'s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Exit = @import("common.zig").Exit;

pub const CommandLineError = error{
    /// `argv[0]` contains a double quote, which `CreateProcessW` cannot
    /// be handed without it leaking into the next argument.
    InvalidArg0,
    InvalidWtf8,
} || Allocator.Error;

/// `argv` as the WTF-16 command line `CreateProcessW` takes. Caller owns.
pub fn commandLine(gpa: Allocator, argv: []const []const u8) CommandLineError![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendCommandLine(&buf, gpa, argv);
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, buf.items);
}

/// The same line as WTF-8, appended to `buf`.
pub fn appendCommandLine(buf: *std.ArrayList(u8), gpa: Allocator, argv: []const []const u8) CommandLineError!void {
    if (argv.len == 0) return;
    const arg0 = argv[0];
    // arg0: quoted when it has a space or a control character; never
    // escaped (backslashes mean nothing there), so a `"` is unrepresentable.
    var needs_quotes = arg0.len == 0;
    for (arg0) |ch| {
        if (ch <= ' ') needs_quotes = true else if (ch == '"') return error.InvalidArg0;
    }
    if (needs_quotes) try buf.append(gpa, '"');
    try buf.appendSlice(gpa, arg0);
    if (needs_quotes) try buf.append(gpa, '"');

    const cmd = isCmd(arg0);
    for (argv[1..], 1..) |arg, i| {
        try buf.append(gpa, ' ');
        // `cmd.exe` reads its own command line, not `CommandLineToArgvW`'s:
        // everything after `/c` is the command as it stands, and a `\"`
        // there is a backslash and a quote. So the command goes out as
        // `/s /c "<command>"` — `/s` makes cmd strip exactly that outer
        // pair — and is never escaped. (Escaped, a quoted program path
        // reached cmd as `\"D:\…\"` and "is not recognized".)
        if (cmd and std.ascii.eqlIgnoreCase(arg, "/c")) {
            try buf.appendSlice(gpa, "/s /c \"");
            for (argv[i + 1 ..], 0..) |part, k| {
                if (k > 0) try buf.append(gpa, ' ');
                try buf.appendSlice(gpa, part);
            }
            try buf.append(gpa, '"');
            return;
        }
        // The rest: quoted when empty or holding whitespace, a control
        // character or a quote; backslashes double only before a quote
        // (and at the end, where the closing quote follows).
        needs_quotes = for (arg) |ch| {
            if (ch <= ' ' or ch == '"') break true;
        } else arg.len == 0;
        if (!needs_quotes) {
            try buf.appendSlice(gpa, arg);
            continue;
        }
        try buf.append(gpa, '"');
        var backslashes: usize = 0;
        for (arg) |ch| switch (ch) {
            '\\' => backslashes += 1,
            '"' => {
                try buf.appendNTimes(gpa, '\\', backslashes * 2 + 1);
                try buf.append(gpa, '"');
                backslashes = 0;
            },
            else => {
                try buf.appendNTimes(gpa, '\\', backslashes);
                try buf.append(gpa, ch);
                backslashes = 0;
            },
        };
        try buf.appendNTimes(gpa, '\\', backslashes * 2);
        try buf.append(gpa, '"');
    }
}

/// `argv[0]` names cmd.exe (a bare `cmd`, `cmd.exe`, or a path to it).
fn isCmd(arg0: []const u8) bool {
    const base = arg0[if (std.mem.lastIndexOfAny(u8, arg0, "\\/")) |i| i + 1 else 0..];
    return std.ascii.eqlIgnoreCase(base, "cmd") or std.ascii.eqlIgnoreCase(base, "cmd.exe");
}

/// A process exit code as the pane sees it. Codes that fit a byte are
/// ordinary exits; the NTSTATUS-shaped ones a crash or a ctrl-C leave
/// (`0xC0000005`, `0xC000013A`) read as `signal`, the nearest analogue.
pub fn exitFromCode(code: u32) Exit {
    if (code <= 0xff) return .{ .code = @intCast(code) };
    return .{ .signal = code };
}

/// `%COMSPEC%` — `cmd.exe` on every Windows since NT — or the bare name
/// for `CreateProcessW` to find on PATH. `$SHELL` is ignored on purpose:
/// Git Bash and MSYS export a `/usr/bin/bash` no Win32 call can resolve.
pub fn defaultShell(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("COMSPEC")) |c| if (c.len > 0) return c;
    return "cmd.exe";
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn expectLine(argv: []const []const u8, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendCommandLine(&buf, testing.allocator, argv);
    try testing.expectEqualStrings(expected, buf.items);
    // The WTF-16 form round-trips.
    const wide = try commandLine(testing.allocator, argv);
    defer testing.allocator.free(wide);
    const back = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, wide);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(expected, back);
}

test "commandLine: std's own vectors — spaces, quotes, backslashes before quotes" {
    try expectLine(&.{
        \\C:\Program Files\zig\zig.exe
        ,
        \\run
        ,
        \\.\src\main.zig
        ,
        \\-target
        ,
        \\x86_64-windows-gnu
        ,
        \\--eval=new Regex("Dwayne \"The Rock\" Johnson")
        ,
    },
        \\"C:\Program Files\zig\zig.exe" run .\src\main.zig -target x86_64-windows-gnu "--eval=new Regex(\"Dwayne \\\"The Rock\\\" Johnson\")"
    );
    try expectLine(&.{}, "");
    try expectLine(&.{""}, "\"\"");
    try expectLine(&.{" "}, "\" \"");
    try expectLine(&.{"\t"}, "\"\t\"");
    try expectLine(&.{"🦎"}, "🦎");
    try expectLine(
        &.{ "zig", "aa aa", "bb\tbb", "cc\ncc", "dd\r\ndd", "ee\x7Fee" },
        "zig \"aa aa\" \"bb\tbb\" \"cc\ncc\" \"dd\r\ndd\" ee\x7Fee",
    );
    try expectLine(
        &.{ "\\\\foo bar\\foo bar\\", "\\\\zig zag\\zig zag\\" },
        "\"\\\\foo bar\\foo bar\\\" \"\\\\zig zag\\zig zag\\\\\"",
    );
}

test "commandLine: a quote in arg0 is refused, anywhere else it is escaped" {
    try testing.expectError(error.InvalidArg0, commandLine(testing.allocator, &.{"\"quotes\"quotes\""}));
    try testing.expectError(error.InvalidArg0, commandLine(testing.allocator, &.{"quotes\"quotes"}));
}

test "commandLine: cmd.exe's command goes out whole after /s /c, quotes and all, never escaped" {
    try expectLine(&.{ "cmd.exe", "/d", "/c", "echo \"hi\"" }, "cmd.exe /d /s /c \"echo \"hi\"\"");
    try expectLine(
        &.{ "C:\\Windows\\system32\\CMD.EXE", "/d", "/c", "\"D:\\a b\\mnml-sample.exe\" --install" },
        "C:\\Windows\\system32\\CMD.EXE /d /s /c \"\"D:\\a b\\mnml-sample.exe\" --install\"",
    );
    // Not cmd: the ordinary rules still apply to a `/c` argument.
    try expectLine(&.{ "prog", "/c", "a \"b\"" }, "prog /c \"a \\\"b\\\"\"");
}

test "exitFromCode: bytes are codes, NTSTATUS values read as a signal" {
    try testing.expectEqual(Exit{ .code = 0 }, exitFromCode(0));
    try testing.expect(exitFromCode(0).ok());
    try testing.expectEqual(Exit{ .code = 3 }, exitFromCode(3));
    try testing.expectEqual(Exit{ .code = 255 }, exitFromCode(255));
    try testing.expectEqual(Exit{ .signal = 0xC0000005 }, exitFromCode(0xC0000005));
    try testing.expect(!exitFromCode(0xC000013A).ok());
}

test "defaultShell: COMSPEC when set and non-empty, else cmd.exe; SHELL is ignored" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/usr/bin/bash");
    try testing.expectEqualStrings("cmd.exe", defaultShell(&env));
    try env.put("COMSPEC", "");
    try testing.expectEqualStrings("cmd.exe", defaultShell(&env));
    try env.put("COMSPEC", "C:\\Windows\\system32\\cmd.exe");
    try testing.expectEqualStrings("C:\\Windows\\system32\\cmd.exe", defaultShell(&env));
}
