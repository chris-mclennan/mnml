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
//! For bash (`data/shell-integration/bash/mnml.bash`): the shell starts
//! as `bash --init-file <that file>`, which bash reads in place of
//! `~/.bashrc`. `--init-file` is read only by a shell that is not a
//! login shell, so argv0 loses its `-` and `MNML_BASH_LOGIN=1` tells
//! the file to read what a login bash would (/etc/profile, then the
//! first of ~/.bash_profile, ~/.bash_login, ~/.profile) before adding
//! the marks.
//!
//! For fish (`data/shell-integration/fish/mnml.fish`): the login shell
//! it always was, with `--init-command` sourcing the file (its path in
//! `MNML_FISH_INIT`, so no quoting is at stake), which fish runs after
//! config.fish. fish 4.0 and later marks its prompts itself; the file
//! then stands aside.
//!
//! Only a plain shell pane (no argv) gets it, only when
//! `terminal.shell_integration` is on, only on POSIX, and only for a
//! shell in `shells` below — a new shell is its files plus a `point`
//! function.

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

/// How the shell is started, beyond its environment: what follows its
/// argv0, and whether argv0 is the login `-<name>`. What a shell pane
/// with no integration gets is the default.
pub const Launch = struct {
    /// On the arena `apply` was given.
    args: []const []const u8 = &.{},
    login: bool = true,
};

const Shell = struct {
    /// `$SHELL`'s basename.
    name: []const u8,
    /// Written into `<data root>/shell-integration/<name>/`.
    files: []const File,
    /// Point the shell at that directory: its environment, and how it
    /// is started.
    point: *const fn (arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!Launch,
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
    .{
        .name = "bash",
        .files = &.{.{ .name = "mnml.bash", .text = data.bash_integration.init }},
        .point = pointBash,
    },
    .{
        .name = "fish",
        .files = &.{.{ .name = "mnml.fish", .text = data.fish_integration.init }},
        .point = pointFish,
    },
};

/// zsh reads its startup files from `$ZDOTDIR`: point it at mnml's
/// directory, and hand the user's own (if set) to mnml's `.zshenv`,
/// which puts it back before any other file is read.
fn pointZsh(arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!Launch {
    if (env.get("ZDOTDIR")) |z| {
        try env.put("MNML_ZSH_ZDOTDIR", try arena.dupe(u8, z));
    } else _ = env.swapRemove("MNML_ZSH_ZDOTDIR");
    try env.put("ZDOTDIR", dir);
    return .{};
}

/// `bash --init-file <dir>/mnml.bash`, not a login shell (bash ignores
/// the flag in one), with the file told to read the login files.
fn pointBash(arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!Launch {
    try env.put("MNML_BASH_LOGIN", "1");
    const args = try arena.alloc([]const u8, 2);
    args[0] = "--init-file";
    args[1] = try std.fs.path.join(arena, &.{ dir, "mnml.bash" });
    return .{ .args = args, .login = false };
}

/// `-fish --init-command 'source "$MNML_FISH_INIT"…'`: still a login
/// shell; fish runs the command after its config.
fn pointFish(arena: Allocator, env: *Map, dir: []const u8) Allocator.Error!Launch {
    try env.put("MNML_FISH_INIT", try std.fs.path.join(arena, &.{ dir, "mnml.fish" }));
    const args = try arena.alloc([]const u8, 2);
    args[0] = "--init-command";
    args[1] = "source \"$MNML_FISH_INIT\"; set -e MNML_FISH_INIT";
    return .{ .args = args };
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
/// its files under `data_root` (rewritten when this build's differ),
/// point the environment at them, and say how the shell is to be
/// started. Does nothing (the default `Launch`) when `on` is false, on
/// Windows, with no data root, for a shell the table does not know, or
/// when the files cannot be written — the shell then starts as it
/// would have. Paths are on `arena`.
pub fn apply(io: Io, arena: Allocator, env: *Map, data_root: []const u8, on: bool) Allocator.Error!Launch {
    if (!on or builtin.os.tag == .windows or data_root.len == 0) return .{};
    const sh = shellFor(env) orelse return .{};
    const dir = try std.fs.path.join(arena, &.{ data_root, "shell-integration", sh.name });
    install(io, arena, dir, sh.files) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    const launch = try sh.point(arena, env, dir);
    try env.put(env_flag, "1");
    return launch;
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
    _ = try apply(t.io, arena, &env, root, false);
    try t.expectEqualStrings("/home/me/.config/zsh", env.get("ZDOTDIR").?);
    try t.expect(env.get(env_flag) == null);

    const launch = try apply(t.io, arena, &env, root, true);
    if (builtin.os.tag == .windows) return;
    // zsh is started as it always was: a login shell, no arguments.
    try t.expect(launch.login);
    try t.expectEqual(@as(usize, 0), launch.args.len);
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
    _ = try apply(t.io, arena, &bare, root, true);
    try t.expectEqualStrings(dir, bare.get("ZDOTDIR").?);
    try t.expect(bare.get("MNML_ZSH_ZDOTDIR") == null);

    var other: Map = .init(t.allocator);
    defer other.deinit();
    try other.put("SHELL", "/bin/tcsh");
    const plain = try apply(t.io, arena, &other, root, true);
    try t.expect(plain.login and plain.args.len == 0);
    try t.expect(other.get("ZDOTDIR") == null);
    try t.expect(other.get(env_flag) == null);
}

test "shell integration: bash starts with --init-file on the installed file and no login dash; fish stays a login shell with --init-command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bash: Map = .init(t.allocator);
    defer bash.deinit();
    try bash.put("SHELL", "/bin/bash");
    const b = try apply(t.io, arena, &bash, root, true);
    try t.expect(!b.login);
    try t.expectEqual(@as(usize, 2), b.args.len);
    try t.expectEqualStrings("--init-file", b.args[0]);
    const init_file = try std.fs.path.join(arena, &.{ root, "shell-integration", "bash", "mnml.bash" });
    try t.expectEqualStrings(init_file, b.args[1]);
    try t.expectEqualStrings(data.bash_integration.init, try Io.Dir.cwd().readFileAlloc(t.io, init_file, arena, .limited(1 << 20)));
    try t.expectEqualStrings("1", bash.get("MNML_BASH_LOGIN").?);
    try t.expectEqualStrings("1", bash.get(env_flag).?);

    var fish: Map = .init(t.allocator);
    defer fish.deinit();
    try fish.put("SHELL", "/opt/homebrew/bin/fish");
    const f = try apply(t.io, arena, &fish, root, true);
    try t.expect(f.login);
    try t.expectEqualStrings("--init-command", f.args[0]);
    const fish_file = try std.fs.path.join(arena, &.{ root, "shell-integration", "fish", "mnml.fish" });
    try t.expectEqualStrings(fish_file, fish.get("MNML_FISH_INIT").?);
    try t.expectEqualStrings(data.fish_integration.init, try Io.Dir.cwd().readFileAlloc(t.io, fish_file, arena, .limited(1 << 20)));

    // Off: neither is touched.
    var off: Map = .init(t.allocator);
    defer off.deinit();
    try off.put("SHELL", "/bin/bash");
    const o = try apply(t.io, arena, &off, root, false);
    try t.expect(o.login and o.args.len == 0);
    try t.expect(off.get("MNML_BASH_LOGIN") == null);
}

const Kind = enum { zsh, bash, fish };

/// The shell binary a real-pty test runs: `MNML_TEST_<SHELL>` when set
/// (a build outside the usual places), else the first of the usual
/// places; null skips the test.
fn shellPath(kind: Kind) ?[]const u8 {
    const override: ?[*:0]const u8 = switch (kind) {
        .zsh => std.c.getenv("MNML_TEST_ZSH"),
        .bash => std.c.getenv("MNML_TEST_BASH"),
        .fish => std.c.getenv("MNML_TEST_FISH"),
    };
    if (override) |o| return std.mem.span(o);
    const places: []const []const u8 = switch (kind) {
        .zsh => &.{ "/bin/zsh", "/usr/bin/zsh" },
        .bash => &.{ "/bin/bash", "/usr/bin/bash" },
        .fish => &.{ "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish" },
    };
    for (places) |p| {
        Io.Dir.cwd().access(t.io, p, .{}) catch continue;
        return p;
    }
    return null;
}

/// What a shell started the mnml way wrote to its terminal, byte for
/// byte: a private HOME whose rc file is `rc` (its prompt must print
/// `MIDDLE`; zsh's `.zshrc`, bash's `.bashrc` — which a `.bash_profile`
/// sources, as a login setup does — fish's `config.fish`), the
/// environment and arguments `apply` makes of it plus `extra_env`, one
/// command typed at the first prompt, then `exit`. `script(1)` sits
/// between the pane's pty and the shell and records the raw bytes (the
/// terminal keeps only what they drew). Every wait is on something the
/// shell did, with a bound.
fn rawShell(arena: Allocator, root: []const u8, kind: Kind, on: bool, rc: []const u8, extra_env: []const [2][]const u8) ![]const u8 {
    const pty = @import("pty");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const cwd = Io.Dir.cwd();
    const shell = shellPath(kind) orelse return error.SkipZigTest;
    cwd.access(t.io, "/usr/bin/script", .{}) catch return error.SkipZigTest;

    const home = try std.fs.path.join(arena, &.{ root, "home" });
    try cwd.createDirPath(t.io, home);
    switch (kind) {
        .zsh => try cwd.writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ home, ".zshrc" }), .data = rc }),
        .bash => {
            try cwd.writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ home, ".bashrc" }), .data = rc });
            try cwd.writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ home, ".bash_profile" }), .data = "[ -r ~/.bashrc ] && . ~/.bashrc\n" });
        },
        .fish => {
            const conf = try std.fs.path.join(arena, &.{ home, ".config", "fish" });
            try cwd.createDirPath(t.io, conf);
            try cwd.writeFile(t.io, .{ .sub_path = try std.fs.path.join(arena, &.{ conf, "config.fish" }), .data = rc });
        },
    }
    const log = try std.fs.path.join(arena, &.{ root, "raw.log" });

    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", home);
    try env.put("SHELL", shell);
    // macOS's bash 3.2 says zsh is the default now, before any prompt.
    try env.put("BASH_SILENCE_DEPRECATION_WARNING", "1");
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    const launch = try apply(t.io, arena, &env, try std.fs.path.join(arena, &.{ root, "data" }), on);
    try t.expectEqual(on, env.get(env_flag) != null);

    // The shell's command line as the pane would run it — the handoff's
    // arguments first (bash wants its long options before `-i`), then
    // interactive, and login where argv0 would carry the dash.
    var words: std.ArrayList([]const u8) = .empty;
    try words.append(arena, shell);
    try words.appendSlice(arena, launch.args);
    try words.append(arena, "-i");
    if (launch.login) try words.append(arena, "-l");
    var argv: std.ArrayList([]const u8) = .empty;
    if (builtin.os.tag == .macos) {
        try argv.appendSlice(arena, &.{ "/usr/bin/script", "-q", log });
        try argv.appendSlice(arena, words.items);
    } else {
        var line: std.ArrayList(u8) = .empty;
        for (words.items, 0..) |w, i| {
            if (i > 0) try line.append(arena, ' ');
            try line.append(arena, '\'');
            for (w) |c| if (c == '\'') try line.appendSlice(arena, "'\\''") else try line.append(arena, c);
            try line.append(arena, '\'');
        }
        try argv.appendSlice(arena, &.{ "/usr/bin/script", "-q", "-c", line.items, log });
    }
    const s = try pty.Session.spawn(t.allocator, t.io, .{ .cols = 80, .rows = 24, .env = &env, .argv = argv.items, .cwd = home });
    defer s.deinit();

    // The first prompt, then the command's output and the next prompt.
    try waitScreen(s, "MIDDLE", 1);
    s.write(switch (kind) {
        .fish => "echo hi-(math 6 \\* 7)\r",
        else => "echo hi-$((6*7))\r",
    });
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

/// A private tmp dir and an arena, for one real-pty run.
const Run = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Run {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator), .arena = .init(t.allocator) };
    }
    fn deinit(self: *Run) void {
        self.arena.deinit();
        t.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn raw(self: *Run, kind: Kind, on: bool, rc: []const u8, extra_env: []const [2][]const u8) ![]const u8 {
        return rawShell(self.arena.allocator(), self.root, kind, on, rc, extra_env);
    }
};

const three_line_prompt =
    \\unset HISTFILE
    \\PROMPT=$'first\nMIDDLE-0123456789\n> '
    \\
;

test "shell integration: a zsh started the mnml way marks a three-line prompt it never marked itself: A before it, B after it, C and D around a command" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.zsh, true, three_line_prompt, &.{});
    try expectInOrder(raw, &.{
        "\x1b]133;A;redraw=1\x07first", "MIDDLE-0123456789",            "> \x1b]133;B\x07",
        "echo hi-",                     "\x1b]133;C\x07",               "hi-42",
        "\x1b]133;D;0\x07",             "\x1b]133;A;redraw=1\x07first",
    });
    // The directory, where the shell is.
    try expectInOrder(raw, &.{"\x1b]7;file://"});
}

test "shell integration: with terminal.shell_integration off the shell writes no OSC 133 at all" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.zsh, false, three_line_prompt, &.{});
    try expectInOrder(raw, &.{ "MIDDLE-0123456789", "hi-42" });
    try t.expect(std.mem.indexOf(u8, raw, "133;") == null);
}

test "shell integration: a .zshrc that already marks its prompts is left to do it alone: one A per prompt, none of mnml's" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.zsh, true, three_line_prompt ++
        \\autoload -Uz add-zsh-hook
        \\my_marks() { print -rn -- $'\e]133;A\a' }
        \\add-zsh-hook precmd my_marks
        \\
    , &.{});
    try expectInOrder(raw, &.{ "\x1b]133;A\x07", "MIDDLE-0123456789", "hi-42", "\x1b]133;A\x07", "MIDDLE-0123456789" });
    // Two prompts before `exit`, maybe a third as the shell leaves: never
    // a second mark per prompt, and never mnml's own.
    try t.expect(std.mem.count(u8, raw, "133;A") == std.mem.count(u8, raw, "MIDDLE-0123456789"));
    try t.expect(std.mem.indexOf(u8, raw, "redraw=1") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;B") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;C") == null);
}

// ── bash ──

/// In `.bashrc`, which the login files source: what a user's setup
/// would look like, and what proves the login files were read.
const bash_three_line_prompt =
    \\unset HISTFILE
    \\PS1='first\nMIDDLE-0123456789\n> '
    \\
;

test "shell integration: a bash started the mnml way reads the login files and marks a three-line prompt: A;redraw=last before it, B after it, C and D around a command" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.bash, true, bash_three_line_prompt, &.{});
    try expectInOrder(raw, &.{
        "\x1b]133;A;redraw=last\x07first", "MIDDLE-0123456789",               "> \x1b]133;B\x07",
        "echo hi-",                        "\x1b]133;C\x07",                  "hi-42",
        "\x1b]133;D;0\x07",                "\x1b]133;A;redraw=last\x07first",
    });
    try expectInOrder(raw, &.{"\x1b]7;file://"});
    // An empty line is not a command: exactly one C before `exit`'s.
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "133;C"));
}

test "shell integration: bash with terminal.shell_integration off writes no OSC 133, and still reads its login files" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.bash, false, bash_three_line_prompt, &.{});
    try expectInOrder(raw, &.{ "MIDDLE-0123456789", "hi-42" });
    try t.expect(std.mem.indexOf(u8, raw, "133;") == null);
}

test "shell integration: a .bashrc whose PROMPT_COMMAND already marks prompts is left to do it alone" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.bash, true, bash_three_line_prompt ++
        \\my_marks() { printf '\033]133;A\007'; }
        \\PROMPT_COMMAND=my_marks
        \\
    , &.{});
    try expectInOrder(raw, &.{ "\x1b]133;A\x07", "MIDDLE-0123456789", "hi-42", "\x1b]133;A\x07", "MIDDLE-0123456789" });
    try t.expect(std.mem.count(u8, raw, "133;A") == std.mem.count(u8, raw, "MIDDLE-0123456789"));
    try t.expect(std.mem.indexOf(u8, raw, "redraw=last") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;B") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;C") == null);
}

// ── fish ──

const fish_three_line_prompt =
    \\function fish_prompt
    \\    printf 'first\nMIDDLE-0123456789\n> '
    \\end
    \\
;

/// fish 4.0 and later marks its own prompts unless told not to; this is
/// how a test gets the fish the integration is for.
const no_fish_marks = [_][2][]const u8{.{ "fish_features", "no-mark-prompt" }};

test "shell integration: a fish that does not mark its prompts, started the mnml way, is marked: A;redraw=1 before the prompt, B after it, C and D around a command" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.fish, true, fish_three_line_prompt, &no_fish_marks);
    try expectInOrder(raw, &.{
        "\x1b]133;A;redraw=1\x07first", "MIDDLE-0123456789", "> \x1b]133;B\x07",
        "\x1b]133;C\x07",               "hi-42",             "\x1b]133;D;0\x07",
        "\x1b]133;A;redraw=1\x07first",
    });
    try expectInOrder(raw, &.{"\x1b]7;file://"});
}

test "shell integration: fish with terminal.shell_integration off (and its own marks off) writes no OSC 133" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.fish, false, fish_three_line_prompt, &no_fish_marks);
    try expectInOrder(raw, &.{ "MIDDLE-0123456789", "hi-42" });
    try t.expect(std.mem.indexOf(u8, raw, "133;") == null);
}

test "shell integration: a fish that marks its own prompts — fish 4's default — is left to it: none of mnml's marks" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.fish, true, fish_three_line_prompt, &.{});
    try expectInOrder(raw, &.{ "MIDDLE-0123456789", "hi-42" });
    try t.expect(std.mem.indexOf(u8, raw, "redraw=1") == null);
    // A fish too old to mark its prompts, with nothing else marking
    // them, has mnml's — the test above.
}

test "shell integration: a fish_prompt that already marks itself is left alone" {
    var run: Run = try .init();
    defer run.deinit();
    const raw = try run.raw(.fish, true,
        \\function fish_prompt
        \\    printf '\e]133;A\a'
        \\    printf 'first\nMIDDLE-0123456789\n> '
        \\end
        \\
    , &no_fish_marks);
    try expectInOrder(raw, &.{ "\x1b]133;A\x07", "MIDDLE-0123456789", "hi-42", "\x1b]133;A\x07", "MIDDLE-0123456789" });
    try t.expect(std.mem.indexOf(u8, raw, "redraw=1") == null);
    try t.expect(std.mem.indexOf(u8, raw, "133;C") == null);
}
