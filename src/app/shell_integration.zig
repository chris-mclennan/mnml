//! Shell integration: a shell pane's shell marks its prompts (OSC 133)
//! and reports its directory (OSC 7) without the user's dotfiles
//! changing, as ghostty, kitty, WezTerm and VS Code do for theirs.
//!
//! The marks are what lets the terminal blank a prompt before a resize
//! reflows it (`pty/common.zig`, `resizeGrid`), so zsh's own redraw
//! lands on it: without them a prompt of several lines whose middle
//! line wraps (starship's, powerlevel10k's) leaves a row behind per
//! narrowing. They also feed `term.prev_prompt` / `term.next_prompt`.
//!
//! How it is loaded, for zsh: the files under `data/shell-integration/
//! zsh/` are written into `<data root>/shell-integration/zsh/`, and the
//! pane's shell starts with `ZDOTDIR` pointing there (the user's own
//! ZDOTDIR, if any, rides along as `MNML_ZSH_ZDOTDIR`). zsh reads that
//! directory's `.zshenv` first; it puts the user's ZDOTDIR back, reads
//! the user's `.zshenv`, and sources `mnml-integration.zsh`, which waits
//! for the first prompt — after `.zshrc` — to add the marks.
//!
//! Only a plain shell pane (no argv) gets it, only when
//! `terminal.shell_integration` is on, only on POSIX, and only for a
//! shell in `shells` below. zsh is the one there; bash and fish are
//! not yet — a new shell is its files plus a `point` function.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const data = @import("data");

/// Set in the shell's environment when mnml loads its integration, so a
/// user's rc file can tell (and skip sourcing another terminal's).
pub const env_flag = "MNML_SHELL_INTEGRATION";

const File = struct { name: []const u8, text: []const u8 };

const Shell = struct {
    /// `$SHELL`'s basename.
    name: []const u8,
    /// Written into `<data root>/shell-integration/<name>/`.
    files: []const File,
    /// Point the shell's environment at that directory.
    point: *const fn (arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!void,
};

pub const shells = [_]Shell{
    .{
        .name = "zsh",
        .files = &.{
            .{ .name = ".zshenv", .text = data.zsh_integration.zshenv },
            .{ .name = "mnml-integration.zsh", .text = data.zsh_integration.script },
        },
        .point = pointZsh,
    },
};

/// zsh reads its startup files from `$ZDOTDIR`: point it at mnml's
/// directory, and hand the user's own (if set) to mnml's `.zshenv`,
/// which puts it back before any other file is read.
fn pointZsh(arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!void {
    if (env.get("ZDOTDIR")) |z| {
        try env.put("MNML_ZSH_ZDOTDIR", try arena.dupe(u8, z));
    } else _ = env.swapRemove("MNML_ZSH_ZDOTDIR");
    try env.put("ZDOTDIR", dir);
}

/// The table entry for the shell `env` will start (`$SHELL`, as the
/// session reads it), or null.
pub fn shellFor(env: *const Map) ?*const Shell {
    const path = env.get("SHELL") orelse return null;
    const base = std.fs.path.basename(path);
    for (&shells) |*sh| if (std.mem.eql(u8, sh.name, base)) return sh;
    return null;
}

/// Arrange for the shell `env` starts to load mnml's integration: write
/// its files under `data_root` (rewritten when this build's differ) and
/// point the environment at them. Does nothing when `on` is false, on
/// Windows, with no data root, for a shell the table does not know, or
/// when the files cannot be written — the shell then starts as it
/// would have. Paths are on `arena`.
pub fn apply(io: Io, arena: Allocator, env: *Map, data_root: []const u8, on: bool) Allocator.Error!void {
    if (!on or builtin.os.tag == .windows or data_root.len == 0) return;
    const sh = shellFor(env) orelse return;
    const dir = try std.fs.path.join(arena, &.{ data_root, "shell-integration", sh.name });
    install(io, arena, dir, sh.files) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try sh.point(arena, env, dir);
    try env.put(env_flag, "1");
}

fn install(io: Io, arena: Allocator, dir: []const u8, files: []const File) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    for (files) |f| {
        const path = try std.fs.path.join(arena, &.{ dir, f.name });
        const same = if (cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024))) |have|
            std.mem.eql(u8, have, f.text)
        else |_|
            false;
        if (!same) try cwd.writeFile(io, .{ .sub_path = path, .data = f.text });
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "shell integration: ZDOTDIR points at the installed files, the user's own rides along; off, Windows-less, or another shell: untouched" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/zsh");
    try env.put("ZDOTDIR", "/home/me/.config/zsh");
    try apply(t.io, arena, &env, root, false);
    try t.expectEqualStrings("/home/me/.config/zsh", env.get("ZDOTDIR").?);
    try t.expect(env.get(env_flag) == null);

    try apply(t.io, arena, &env, root, true);
    if (builtin.os.tag == .windows) return;
    const dir = try std.fs.path.join(arena, &.{ root, "shell-integration", "zsh" });
    try t.expectEqualStrings(dir, env.get("ZDOTDIR").?);
    try t.expectEqualStrings("/home/me/.config/zsh", env.get("MNML_ZSH_ZDOTDIR").?);
    try t.expectEqualStrings("1", env.get(env_flag).?);
    const zshenv = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ dir, ".zshenv" }), arena, .limited(1 << 20));
    try t.expectEqualStrings(data.zsh_integration.zshenv, zshenv);

    // No ZDOTDIR of the user's: none rides along.
    var bare: Map = .init(t.allocator);
    defer bare.deinit();
    try bare.put("SHELL", "/usr/local/bin/zsh");
    try apply(t.io, arena, &bare, root, true);
    try t.expectEqualStrings(dir, bare.get("ZDOTDIR").?);
    try t.expect(bare.get("MNML_ZSH_ZDOTDIR") == null);

    var fish: Map = .init(t.allocator);
    defer fish.deinit();
    try fish.put("SHELL", "/opt/homebrew/bin/fish");
    try apply(t.io, arena, &fish, root, true);
    try t.expect(fish.get("ZDOTDIR") == null);
    try t.expect(fish.get(env_flag) == null);
}

/// What a zsh started the mnml way wrote to its terminal, byte for byte:
/// a private HOME whose `.zshrc` is `zshrc` (its prompt must print
/// `MIDDLE`), the environment `apply` makes of it, one command typed at
/// the first prompt, then `exit`. `script(1)` sits between the pane's
/// pty and zsh and records the raw bytes (the terminal keeps only what
/// they drew). Every wait is on something the shell did, with a bound.
fn rawZsh(arena: Allocator, root: []const u8, on: bool, zshrc: []const u8) ![]const u8 {
    const pty = @import("pty");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const cwd = Io.Dir.cwd();
    const zsh = for ([_][]const u8{ "/bin/zsh", "/usr/bin/zsh" }) |p| {
        cwd.access(t.io, p, .{}) catch continue;
        break p;
    } else return error.SkipZigTest;
    cwd.access(t.io, "/usr/bin/script", .{}) catch return error.SkipZigTest;

    const home = try std.fs.path.join(arena, &.{ root, "home" });
    try cwd.createDirPath(t.io, home);
    try cwd.writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ home, ".zshrc" }), .data = zshrc });
    const log = try std.fs.path.join(arena, &.{ root, "raw.log" });

    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", home);
    try env.put("SHELL", zsh);
    try apply(t.io, arena, &env, try std.fs.path.join(arena, &.{ root, "data" }), on);
    try t.expectEqual(on, env.get("ZDOTDIR") != null);

    const login = try std.fmt.allocPrint(arena, "{s} -il", .{zsh});
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "/usr/bin/script", "-q", log, zsh, "-il" }
    else
        &.{ "/usr/bin/script", "-q", "-c", login, log };
    const s = try pty.Session.spawn(t.allocator, t.io, .{ .cols = 80, .rows = 24, .env = &env, .argv = argv, .cwd = home });
    defer s.deinit();

    // The first prompt, then the command's output and the next prompt.
    try waitScreen(s, "MIDDLE", 1);
    s.write("echo hi-$((6*7))\r");
    try waitScreen(s, "MIDDLE", 2);
    s.write("exit\r");
    var waited: u32 = 0;
    while (!s.eof()) : (waited += 5) {
        if (waited > 10_000) return error.ShellDidNotExit;
        _ = s.pump();
        t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return cwd.readFileAlloc(t.io, log, arena, .limited(1 << 20));
}

/// Pump until the screen shows `needle` at least `n` times.
fn waitScreen(s: anytype, needle: []const u8, n: usize) !void {
    var waited: u32 = 0;
    while (waited <= 10_000) : (waited += 5) {
        _ = s.pump();
        const text = try s.terminal().plainString(t.allocator);
        defer t.allocator.free(text);
        if (std.mem.count(u8, text, needle) >= n) return;
        t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return error.ScreenNeverShowed;
}

/// `needles` appear in `hay` in this order; the index after the last.
fn expectInOrder(hay: []const u8, needles: []const []const u8) !void {
    var at: usize = 0;
    for (needles) |n| {
        const i = std.mem.indexOfPos(u8, hay, at, n) orelse {
            std.debug.print("missing (in order) {s}\nraw: {f}\n", .{ n, std.zig.fmtString(hay) });
            return error.TestExpectedInOrder;
        };
        at = i + n.len;
    }
}

const three_line_prompt =
    \\unset HISTFILE
    \\PROMPT=$'first\nMIDDLE-0123456789\n> '
    \\
;

test "shell integration: a zsh started the mnml way marks a three-line prompt it never marked itself: A before it, B after it, C and D around a command" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const raw = try rawZsh(arena_state.allocator(), root, true, three_line_prompt);
    try expectInOrder(raw, &.{
        "\x1b]133;A;redraw=1\x07first", "MIDDLE-0123456789",            "> \x1b]133;B\x07",
        "echo hi-",                     "\x1b]133;C\x07",               "hi-42",
        "\x1b]133;D;0\x07",             "\x1b]133;A;redraw=1\x07first",
    });
    // The directory, where the shell is.
    try expectInOrder(raw, &.{"\x1b]7;file://"});
}

test "shell integration: with terminal.shell_integration off the shell writes no OSC 133 at all" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const raw = try rawZsh(arena_state.allocator(), root, false, three_line_prompt);
    try expectInOrder(raw, &.{ "MIDDLE-0123456789", "hi-42" });
    try t.expect(std.mem.indexOf(u8, raw, "133;") == null);
}

test "shell integration: a .zshrc that already marks its prompts is left to do it alone: one A per prompt, none of mnml's" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const raw = try rawZsh(arena_state.allocator(), root, true, three_line_prompt ++
        \\autoload -Uz add-zsh-hook
        \\my_marks() { print -rn -- $'\e]133;A\a' }
        \\add-zsh-hook precmd my_marks
        \\
    );
    try expectInOrder(raw, &.{ "\x1b]133;A\x07", "MIDDLE-0123456789", "hi-42", "\x1b]133;A\x07", "MIDDLE-0123456789" });
    // Two prompts before `exit`, maybe a third as the shell leaves: never
    // a second mark per prompt, and never mnml's own.
    try t.expect(std.mem.count(u8, raw, "133;A") == std.mem.count(u8, raw, "MIDDLE-0123456789"));
    try t.expect(std.mem.indexOf(u8, raw, "redraw=1") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;B") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;C") == null);
}
