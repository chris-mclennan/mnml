const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const mem_report = @import("core/mem_report.zig");
const e2e = @import("e2e/root.zig");
const headless = @import("headless.zig");
const app_driver = @import("app/driver.zig");
const loop = @import("tui/loop.zig");
const Term = @import("tui/term.zig").Term;
const input = @import("input/mod.zig");
const config = @import("config/root.zig");
const profile = config.profile;
const http_cli = @import("http/cli.zig");
const broker_cli = @import("broker_cli.zig");
const sequence_editor = @import("git/sequence_editor.zig");

/// What `--version` prints: `-Dversion=` at build time, or the derived
/// dev string (see build.zig, the release block).
pub const version = build_options.version;

/// A crash prints its trace on a readable terminal, not inside the alt
/// screen with the mouse still reporting — on Windows, with the console
/// modes put back too.
pub const panic = Term.Panic;

/// The application's driver factory: the same App the terminal runs,
/// behind the `e2e.Driver` vtable for `test` and `--headless`.
pub const app_factory: ?e2e.Factory = app_driver.default_factory.factory();

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var out_buf: [4096]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &out.interface;

    // The git worker's editor child modes (`src/git/sequence_editor.zig`):
    // git runs `mnml-zig --rebase-todo <plan> <todo>` / `--commit-msg
    // <queue> <target>` and reads only the exit code.
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--rebase-todo") or std.mem.eql(u8, args[1], "--commit-msg"))) {
        var err_buf: [1024]u8 = undefined;
        var err_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const mode: sequence_editor.Mode = if (std.mem.eql(u8, args[1], "--rebase-todo")) .todo else .commit_msg;
        const code = sequence_editor.childMain(io, gpa, mode, args[2..], &err_w.interface);
        err_w.interface.flush() catch {};
        return code;
    }
    // `--profile dev|stable` is the flag spelling of `MNML_PROFILE`: it
    // goes into the environment before anything reads it (the way
    // `--startup-picker` does), so the data root, the session file, the
    // IPC mailbox, the marker and every integration this host spawns
    // all get the same answer (`src/config/profile.zig`).
    if (profile.fromArgs(args[1..])) |name| {
        if (profile.parse(name) == null) return usage(w, "--profile needs dev or stable");
        try env.put(profile.env_var, name);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "profile")) return profileSubcommand(gpa, io, env, args[2..], w);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "test")) return testSubcommand(gpa, io, env, args[2..], w);
    // The audit's table runs past the writer's buffer: flush, or its
    // summary and the NEW-uncovered list — the lines `--strict` fails
    // on — never reach the terminal.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "hover-audit")) {
        const code = try @import("app/info_view_audit.zig").main(gpa, io, env, args[2..], w);
        try w.flush();
        return code;
    }
    // `broker acquire` is how a shell script queues behind the panes
    // rather than taking a token out from under one.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "broker")) return brokerSubcommand(gpa, io, env, args[2..], w);
    if (args.len >= 2) if (httpSubcommand(gpa, io, env, args[1], args[2..], w)) |code| return code;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            try w.print("mnml-zig {s} ({s} profile)\n", .{ version, @tagName(profile.of(env)) });
            try w.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return usage(w, "mnml-zig [WORKSPACE] [FILE…] [--input vim|standard] [--ascii] [--config PATH] [--no-session] [--headless] [--startup-picker] [--profile dev|stable] | profile seed [--from stable] [--force] | test [PATH…] [--gate] [--sizes ladder|WxH,…] [--filter NAME] [--skip NAME] | hover-audit [--strict] [--write-todo PATH] | run FILE | chain run FILE | discover SPEC | sync | sync-check | proxy --url URL | broker acquire|status|serve | --rebase-todo PLAN TODO | --commit-msg QUEUE FILE");
    }
    if (parseInputFlag(args[1..], w)) |style| {
        app_driver.default_factory.input_style = style;
    } else |_| return 2;
    for (args[1..]) |a| if (std.mem.eql(u8, a, "--headless")) return headlessSubcommand(gpa, io, env, args[1..], w);
    return terminalMain(gpa, io, env, args[1..], w);
}

/// `--input vim|standard` / `--input=vim`, anywhere on the line; null
/// when absent (the config decides).
fn parseInputFlag(argv: []const [:0]const u8, w: *Io.Writer) !?input.Style {
    var style: ?input.Style = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        var value: ?[]const u8 = null;
        if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            if (i >= argv.len) {
                _ = try usage(w, "--input needs vim or standard");
                return error.Usage;
            }
            value = argv[i];
        } else if (std.mem.startsWith(u8, a, "--input=")) value = a["--input=".len..];
        const v = value orelse continue;
        if (std.mem.eql(u8, v, "vim")) {
            style = .vim;
        } else if (std.mem.eql(u8, v, "standard")) {
            style = .standard;
        } else {
            _ = try usage(w, "--input needs vim or standard");
            return error.Usage;
        }
    }
    return style;
}

// ─── mnml-zig [WS] [FILE…] ──────────────────────────────────────────────

/// `--config PATH` / `--config=PATH`, anywhere on the line.
fn parseConfigFlag(argv: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--config")) {
            if (i + 1 < argv.len) return argv[i + 1];
            return null;
        }
        if (std.mem.startsWith(u8, a, "--config=")) return a["--config=".len..];
    }
    return null;
}

/// The three config layers for `workspace`, with the command line's
/// overrides applied, plus where mnml keeps its state. `loaded` is the
/// caller's to hand on (the App frees it).
const Startup = struct {
    loaded: config.Loaded,
    data_root: []u8,
    /// A line for the first frame to say — today, that the dev profile
    /// was just seeded. Owned by the caller.
    note: ?[]u8 = null,
};

fn loadConfig(gpa: Allocator, io: Io, env: *std.process.Environ.Map, workspace: []const u8, argv: []const [:0]const u8, ascii: bool) !Startup {
    const exe_dir: ?[]u8 = std.process.executableDirPathAlloc(io, gpa) catch null;
    defer if (exe_dir) |d| gpa.free(d);
    const cfg_env: config.data_root.Env = .{ .vars = env, .exe_dir = exe_dir };
    const data_root = try config.data_root.dataRoot(gpa, io, cfg_env);
    errdefer gpa.free(data_root);
    // The dev profile's first launch inherits your setup rather than
    // starting a stranger; every launch relinks the integrations built
    // beside this binary, so a rebuild moves the dev ones and leaves
    // the installed ones alone (`src/config/seed.zig`).
    const note: ?[]u8 = if (cfg_env.profile() == .dev) try seedDev(gpa, io, cfg_env, data_root, exe_dir) else null;
    errdefer if (note) |n| gpa.free(n);
    var loaded = try config.load.load(gpa, io, .{
        .explicit = parseConfigFlag(argv),
        .workspace = workspace,
        .trust = .ask,
        .data_root = data_root,
        .env = cfg_env,
    });
    if (ascii) loaded.config.ui.ascii_icons = true;
    if (hasNoSessionFlag(argv)) loaded.config.session.restore = false;
    if (app_driver.default_factory.input_style) |s| loaded.config.editor.input_style = @import("app.zig").App.configStyleOf(s);
    return .{ .loaded = loaded, .data_root = data_root, .note = note };
}

/// Seed `<data root>` from the stable profile when it has never run,
/// and link the integrations beside this binary into it either way.
/// Returns the toast for a seed that happened, else null.
fn seedDev(gpa: Allocator, io: Io, cfg_env: config.data_root.Env, dev_root: []const u8, exe_dir: ?[]const u8) Allocator.Error!?[]u8 {
    const stable = try config.data_root.stableDataRoot(gpa, io, cfg_env);
    defer gpa.free(stable);
    const report = try config.seed.seed(gpa, io, stable, dev_root, false);
    if (exe_dir) |d| _ = try config.seed.linkBeside(gpa, io, d, dev_root);
    if (report.outcome != .seeded) return null;
    return try std.fmt.allocPrint(gpa, "dev profile seeded from {s} ({d} files)", .{ stable, report.copied });
}

/// `mnml profile` — which one am I in — and `mnml profile seed
/// [--from DIR|stable] [--force]`, the re-seed.
fn profileSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    const exe_dir: ?[]u8 = std.process.executableDirPathAlloc(io, gpa) catch null;
    defer if (exe_dir) |d| gpa.free(d);
    const cfg_env: config.data_root.Env = .{ .vars = env, .exe_dir = exe_dir };
    const p = cfg_env.profile();
    const root = try config.data_root.dataRoot(gpa, io, cfg_env);
    defer gpa.free(root);

    var seed_it = false;
    var force = false;
    var from: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "seed")) {
            seed_it = true;
        } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= argv.len) return usage(w, "profile seed --from needs stable or a directory");
            from = argv[i];
        } else if (std.mem.startsWith(u8, a, "--from=")) {
            from = a["--from=".len..];
        } else if (std.mem.eql(u8, a, profile.flag) or std.mem.startsWith(u8, a, profile.flag ++ "=")) {
            if (std.mem.eql(u8, a, profile.flag)) i += 1; // already in the environment
        } else return usage(w, "mnml profile [seed [--from stable|DIR] [--force]]");
    }

    if (!seed_it) {
        try w.print("profile:  {s}\n", .{@tagName(p)});
        try w.print("data:     {s}\n", .{root});
        try w.print("session:  .mnml/{s}\n", .{std.fs.path.basename(@import("app/session.zig").relPath(p))});
        try w.print("ipc:      <workspace>/.mnml/{s}\n", .{profile.ipcSubdir(p)});
        const marker_path = try @import("tui/marker.zig").path(gpa, env);
        defer gpa.free(marker_path);
        try w.print("marker:   {s}\n", .{marker_path});
        try w.flush();
        return 0;
    }

    if (p != .dev) {
        try w.writeAll("mnml profile seed: only the dev profile is seeded (run it with --profile dev)\n");
        try w.flush();
        return 2;
    }
    const stable = if (from) |f|
        if (std.mem.eql(u8, f, "stable")) try config.data_root.stableDataRoot(gpa, io, cfg_env) else try gpa.dupe(u8, f)
    else
        try config.data_root.stableDataRoot(gpa, io, cfg_env);
    defer gpa.free(stable);
    const report = try config.seed.seed(gpa, io, stable, root, force);
    if (exe_dir) |d| {
        const n = try config.seed.linkBeside(gpa, io, d, root);
        if (n > 0) try w.print("linked {d} integration binaries from {s} into {s}/bin\n", .{ n, d, root });
    }
    switch (report.outcome) {
        .seeded => try w.print("seeded {s} from {s} ({d} files)\n", .{ root, stable, report.copied }),
        .already => try w.print("{s} already has state — `mnml profile seed --force` copies what is missing\n", .{root}),
        .no_source => try w.print("nothing to seed from: {s} does not exist\n", .{stable}),
    }
    try w.flush();
    return if (report.outcome == .no_source) 1 else 0;
}

/// `--no-session`: launch without restoring the session (`run.sh
/// fresh`) — the escape hatch when a restored pane wedges the app and a
/// restart would only reopen it. `session.zon` is left alone, so the
/// next plain launch restores as usual.
fn hasNoSessionFlag(argv: []const [:0]const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, "--no-session")) return true;
    return false;
}

/// `argv[i]` is a flag whose value is the next argument — the value must
/// not be read as a workspace or a file.
fn takesValue(a: []const u8) bool {
    return std.mem.eql(u8, a, "--input") or std.mem.eql(u8, a, "--config") or std.mem.eql(u8, a, profile.flag);
}

/// `--startup-picker` is the flag spelling of `MNML_STARTUP_PICKER=1`:
/// the picker reads the environment (`startup_picker.wanted`), so the
/// flag sets the variable for this process. True when it was on the line.
fn applyStartupPickerFlag(env: *std.process.Environ.Map, argv: []const []const u8) Allocator.Error!bool {
    for (argv) |a| if (std.mem.eql(u8, a, "--startup-picker")) {
        try env.put("MNML_STARTUP_PICKER", "1");
        return true;
    };
    return false;
}

/// The terminal: the first non-flag argument that is a directory is the
/// workspace (default: cwd); every other non-flag argument is opened.
fn terminalMain(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var workspace: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var ascii = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (takesValue(a)) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--ascii")) {
            ascii = true;
            continue;
        }
        if (a.len > 0 and a[0] == '-') continue;
        const st = Io.Dir.cwd().statFile(io, a, .{}) catch {
            try files.append(arena, a);
            continue;
        };
        if (st.kind == .directory and workspace == null) workspace = a else try files.append(arena, a);
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_len = Io.Dir.cwd().realPathFile(io, workspace orelse ".", &cwd_buf) catch return usage(w, "workspace is not a directory");
    const ws_abs = cwd_buf[0..ws_len];
    {
        const plain = try arena.alloc([]const u8, argv.len);
        for (argv, 0..) |a, k| plain[k] = a;
        _ = try applyStartupPickerFlag(env, plain);
    }
    const startup = try loadConfig(gpa, io, env, ws_abs, argv, ascii);
    defer gpa.free(startup.data_root);
    defer if (startup.note) |n| gpa.free(n);
    const cfg: loop.Options = .{
        .loaded = startup.loaded,
        .workspace = ws_abs,
        .data_root = startup.data_root,
        .files = files.items,
        .note = startup.note,
    };
    return loop.run(gpa, io, env, cfg) catch |err| switch (err) {
        error.NotATty => return usage(w, "stdout is not a terminal (use --headless)"),
        else => return err,
    };
}

// ─── mnml-zig run / chain / discover / sync / proxy ─────────────────────

/// The HTTP client's subcommands, when `verb` is one of them.
fn httpSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, verb: []const u8, rest: []const [:0]const u8, w: *Io.Writer) ?u8 {
    var err_buf: [4096]u8 = undefined;
    var err_file: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const std_: http_cli.Std = .{ .out = w, .err = &err_file.interface };
    var argv_buf: [64][]const u8 = undefined;
    const n = @min(rest.len, argv_buf.len);
    for (rest[0..n], 0..) |a, i| argv_buf[i] = a;
    const argv = argv_buf[0..n];
    const result: anyerror!u8 = if (std.mem.eql(u8, verb, "run"))
        http_cli.run(gpa, io, env, argv, std_)
    else if (std.mem.eql(u8, verb, "chain"))
        http_cli.chainRun(gpa, io, env, argv, std_)
    else if (std.mem.eql(u8, verb, "discover"))
        http_cli.discoverCmd(gpa, io, argv, std_)
    else if (std.mem.eql(u8, verb, "sync"))
        http_cli.syncCmd(gpa, io, argv, std_, false)
    else if (std.mem.eql(u8, verb, "sync-check"))
        http_cli.syncCmd(gpa, io, argv, std_, true)
    else if (std.mem.eql(u8, verb, "proxy"))
        http_cli.proxyCmd(gpa, io, env, argv, std_)
    else
        return null;
    const code = result catch 1;
    err_file.interface.flush() catch {};
    w.flush() catch {};
    return code;
}

/// `mnml-zig broker acquire|status …` — the batch class, from a shell.
fn brokerSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, rest: []const [:0]const u8, w: *Io.Writer) u8 {
    var err_buf: [4096]u8 = undefined;
    var err_file: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const std_: broker_cli.Std = .{ .out = w, .err = &err_file.interface };
    var argv_buf: [32][]const u8 = undefined;
    const n = @min(rest.len, argv_buf.len);
    for (rest[0..n], 0..) |a, i| argv_buf[i] = a;
    const code = broker_cli.subcommand(gpa, io, env, argv_buf[0..n], std_) orelse 2;
    err_file.interface.flush() catch {};
    w.flush() catch {};
    return code;
}

// ─── mnml-zig test ──────────────────────────────────────────────────────

/// `mnml-fake-dap` beside this executable, else the path `zig build`
/// installs it at; null when neither exists. Owned.
fn fakeDapPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-fake-dap", build_options.fake_dap_exe);
}

fn fakeLspPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-fake-lsp", build_options.fake_lsp_exe);
}

fn fakeCopilotPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-fake-copilot", build_options.fake_copilot_exe);
}

fn sampleIntegrationPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-sample", build_options.sample_integration_exe);
}

fn bitbucketIntegrationPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-bitbucket", build_options.bitbucket_integration_exe);
}

fn fakeBitbucketPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-fake-bitbucket", build_options.fake_bitbucket_exe);
}

fn jiraIntegrationPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-jira", build_options.jira_integration_exe);
}

fn fakeJiraPath(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    return fakeToolPath(gpa, io, "mnml-fake-jira", build_options.fake_jira_exe);
}

/// A fake tool built beside this binary (`zig build`), or at the
/// build's install path when the runner is elsewhere.
fn fakeToolPath(gpa: Allocator, io: Io, base: []const u8, installed: []const u8) Allocator.Error!?[]u8 {
    const ext = if (@import("builtin").os.tag == .windows) ".exe" else "";
    if (std.process.executableDirPathAlloc(io, gpa)) |dir| {
        defer gpa.free(dir);
        const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, ext });
        defer gpa.free(name);
        const beside = try std.fs.path.join(gpa, &.{ dir, name });
        if (Io.Dir.cwd().access(io, beside, .{})) |_| return beside else |_| gpa.free(beside);
    } else |_| {}
    if (Io.Dir.cwd().access(io, installed, .{})) |_| return try gpa.dupe(u8, installed) else |_| return null;
}

/// `mnml-zig test [PATH…] [--gate] [--sizes 80x24,120x40] [--filter NAME] [--skip NAME] [--parse] [--stub]`
///
/// Runs `.test` scripts (default `tests/e2e`). `--gate` runs the Phase-0
/// gate list from `tools/gate.txt`. `--filter` keeps the files whose
/// name contains it (what `zig build test -Dtest-filter=…` passes);
/// `--skip` (repeatable) leaves a file out and says so. `--parse` only
/// parses. `--stub` drives the recording stub instead of the App —
/// exercises the harness, proves nothing about the editor. Exit 1 on
/// any failure.
fn testSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var sizes: std.ArrayList(e2e.Size) = .empty;
    defer sizes.deinit(gpa);
    var skips: std.ArrayList([]const u8) = .empty;
    defer skips.deinit(gpa);
    var name_filter: ?[]const u8 = null;
    var gate = false;
    var parse_only = false;
    var use_stub = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--gate")) {
            gate = true;
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--filter needs a name");
            name_filter = argv[i];
        } else if (std.mem.startsWith(u8, a, "--filter=")) {
            name_filter = a["--filter=".len..];
        } else if (std.mem.eql(u8, a, "--skip")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--skip needs a name");
            try skips.append(gpa, argv[i]);
        } else if (std.mem.startsWith(u8, a, "--skip=")) {
            try skips.append(gpa, a["--skip=".len..]);
        } else if (std.mem.eql(u8, a, "--parse")) {
            parse_only = true;
        } else if (std.mem.eql(u8, a, "--stub")) {
            use_stub = true;
        } else if (std.mem.eql(u8, a, "--sizes")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--sizes needs a list like 80x24,120x40 (or `ladder`)");
            if (!(try appendSizes(gpa, &sizes, argv[i]))) return usage(w, "bad size (want WxH, or `ladder`)");
        } else if (std.mem.startsWith(u8, a, "--sizes=")) {
            if (!(try appendSizes(gpa, &sizes, a["--sizes=".len..]))) return usage(w, "bad size (want WxH, or `ladder`)");
        } else if (a.len > 0 and a[0] == '-') {
            // Unknown flags are ignored, as the Rust runner ignores them.
        } else try paths.append(gpa, a);
    }

    var gate_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (gate_paths.items) |p| gpa.free(p);
        gate_paths.deinit(gpa);
    }
    if (gate) {
        const list = Io.Dir.cwd().readFileAlloc(io, "tools/gate.txt", gpa, .unlimited) catch return usage(w, "--gate needs tools/gate.txt");
        defer gpa.free(list);
        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r");
            if (name.len == 0 or name[0] == '#') continue;
            const p = try std.fmt.allocPrint(gpa, "tests/e2e/{s}.test", .{name});
            try gate_paths.append(gpa, p);
            try paths.append(gpa, p);
        }
    }
    if (paths.items.len == 0) {
        try paths.append(gpa, "tests/e2e");
    }

    if (parse_only) return parseOnly(gpa, io, paths.items, w);

    // `mnml-zig test` is typed by the user, so `shell` steps are allowed
    // unless the variable says otherwise; the gate exists for discovery
    // paths on a cloned repo, not for explicit invocations.
    const allow_shell = std.mem.eql(u8, env.get("MNML_E2E_ALLOW_SHELL") orelse "1", "1");
    const network = std.mem.eql(u8, env.get("MNML_E2E_NETWORK") orelse "0", "1");
    // The default follows the build (`e2e.runner.debug_slowdown`): an
    // unoptimized app needs the same multiple of wall clock the expect
    // budget now gets, or a file is cut off mid-retry.
    const default_timeout: u64 = e2e.runner.default_file_timeout_secs;
    const timeout: u64 = if (env.get("MNML_E2E_FILE_TIMEOUT_SECS")) |v| std.fmt.parseInt(u64, v, 10) catch default_timeout else default_timeout;
    const heartbeat: u64 = if (env.get("MNML_E2E_HEARTBEAT_SECS")) |v| std.fmt.parseInt(u64, v, 10) catch 60 else 60;
    // `TMPDIR` is the POSIX spelling, `TEMP` / `TMP` Windows's.
    const tmp_root = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    const data_root = try e2e.runner.makeTempDir(gpa, io, tmp_root);
    defer {
        Io.Dir.cwd().deleteTree(io, data_root) catch {};
        gpa.free(data_root);
    }
    // The `dap_session_*` scripts seed a `.dap` adapter whose `cmd` is
    // `$MNML_FAKE_DAP`: the fake adapter installed beside this binary
    // (`zig build`), or the build's install path when the runner is
    // elsewhere. An operator's own value wins.
    if (env.get("MNML_FAKE_DAP") == null) {
        if (try fakeDapPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_FAKE_DAP", p);
        }
    }
    // `$MNML_SHIMS`: `tools/shims/` — the fake `dotnet` the `dotnet_*`
    // scripts put first on PATH (`# env: PATH=${MNML_SHIMS}:${PATH}`).
    if (env.get("MNML_SHIMS") == null) {
        if (Io.Dir.cwd().access(io, build_options.shims_dir, .{})) |_| {
            try env.put("MNML_SHIMS", build_options.shims_dir);
        } else |_| {}
    }
    // `$MNML_LAUNCHERS`: the repo's `launchers/`, for the `launchers_*`
    // scripts (`# env: MNML_MARKETPLACE_LOCAL=${MNML_LAUNCHERS}`).
    if (env.get("MNML_LAUNCHERS") == null) {
        if (Io.Dir.cwd().access(io, build_options.launchers_dir, .{})) |_| {
            try env.put("MNML_LAUNCHERS", build_options.launchers_dir);
        } else |_| {}
    }
    // `$MNML_FAKE_LSP` the same way, for the `lsp_fake_*` scripts.
    if (env.get("MNML_FAKE_LSP") == null) {
        if (try fakeLspPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_FAKE_LSP", p);
        }
    }
    // `$MNML_FAKE_COPILOT`, for the `copilot_*` scripts.
    if (env.get("MNML_FAKE_COPILOT") == null) {
        if (try fakeCopilotPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_FAKE_COPILOT", p);
        }
    }
    // `$MNML_SAMPLE_INTEGRATION`: the prebuilt sample integration
    // (`integrations/sample/`), for the `integrations_*` scripts — a
    // manifest whose `binary` is that variable resolves to it, so the
    // corpus installs and mounts the sample without building anything.
    if (env.get("MNML_SAMPLE_INTEGRATION") == null) {
        if (try sampleIntegrationPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_SAMPLE_INTEGRATION", p);
        }
    }
    // `$MNML_BITBUCKET_INTEGRATION` and `$MNML_FAKE_BITBUCKET`: the
    // Bitbucket pane and the deterministic Bitbucket it talks to, for
    // the `integrations_bitbucket_*` scripts. The script starts the
    // fake server itself and points the pane at it with
    // `BITBUCKET_BASE_URL=@<file>`, so no port is ever chosen.
    if (env.get("MNML_BITBUCKET_INTEGRATION") == null) {
        if (try bitbucketIntegrationPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_BITBUCKET_INTEGRATION", p);
        }
    }
    if (env.get("MNML_FAKE_BITBUCKET") == null) {
        if (try fakeBitbucketPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_FAKE_BITBUCKET", p);
        }
    }
    // `$MNML_JIRA` and `$MNML_FAKE_JIRA`: the Jira integration and its
    // offline server, for the `integrations_jira_*` scripts — a manifest
    // whose `binary` is that variable resolves to it, and a `config.zon`
    // whose `jira.url` points at the fake server needs no network.
    if (env.get("MNML_JIRA") == null) {
        if (try jiraIntegrationPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_JIRA", p);
        }
    }
    if (env.get("MNML_FAKE_JIRA") == null) {
        if (try fakeJiraPath(gpa, io)) |p| {
            defer gpa.free(p);
            try env.put("MNML_FAKE_JIRA", p);
        }
    }
    try reportHarness(env, w);
    const opts: e2e.Options = .{
        .allow_shell = allow_shell,
        .network = network,
        .file_timeout_secs = timeout,
        .heartbeat_secs = heartbeat,
        .sizes = if (sizes.items.len > 0) sizes.items else &.{e2e.runner.content_size},
        .shell = env.get("SHELL") orelse "/bin/sh",
        .tmp_root = tmp_root,
        .data_root = data_root,
        .name_filter = name_filter,
        .skip = skips.items,
        .env = env,
    };

    var stub_factory: e2e.driver.StubFactory = .{};
    var no_app: u8 = 0;
    const factory: e2e.Factory = if (use_stub)
        stub_factory.factory()
    else
        app_factory orelse blk: {
            try w.writeAll("mnml-zig test: no App driver yet — every file FAILs (use --parse to check scripts, --stub to exercise the harness)\n");
            break :blk .{ .ptr = &no_app, .create = noAppDriver };
        };
    // A path that is not there is a hard error, never a green `0/0`:
    // the runner has already named it on `w`.
    const stats = e2e.runner.runPaths(gpa, io, factory, paths.items, opts, w) catch |err| switch (err) {
        error.PathNotFound => return 2,
        else => return err,
    };
    if (stats.failed != 0) try reportHarness(env, w);
    return if (stats.failed == 0) 0 else 1;
}

/// The two things about the HARNESS that turn a `.test` failure into a
/// puzzle, said before the run and again after a failing one.
///
/// A missing helper binary is silent otherwise: `$MNML_JIRA` expands to
/// nothing, the manifest a script writes names no binary, no pane
/// mounts, and the file fails on the pane's title. And a Debug build is
/// worse than silent — the corpus passes 668/668 against a shipped
/// build and the same files fail against an unoptimized one, because
/// the app is an order of magnitude slower (`debug_slowdown` moves the
/// deadlines, but a `wait <ms>` a script spells out does not move).
fn reportHarness(env: *const std.process.Environ.Map, w: *Io.Writer) !void {
    const helpers = [_]struct { name: []const u8, step: []const u8 }{
        .{ .name = "MNML_JIRA", .step = "jira-integration" },
        .{ .name = "MNML_FAKE_JIRA", .step = "jira-integration" },
        .{ .name = "MNML_BITBUCKET_INTEGRATION", .step = "bitbucket-integration" },
        .{ .name = "MNML_FAKE_BITBUCKET", .step = "bitbucket-integration" },
        .{ .name = "MNML_SAMPLE_INTEGRATION", .step = "sample-integration" },
        .{ .name = "MNML_FAKE_DAP", .step = "install" },
        .{ .name = "MNML_FAKE_LSP", .step = "install" },
        .{ .name = "MNML_FAKE_COPILOT", .step = "install" },
    };
    for (helpers) |h| {
        // Empty counts as unset: that is what a `.binary = "$MNML_JIRA"`
        // manifest ends up with, and it is the shape that fails silently.
        const value: []const u8 = env.get(h.name) orelse "";
        if (value.len != 0) continue;
        try w.print(
            "mnml-zig test: ${s} is unset and no binary was found beside this exe or at its install path — the scripts that need it will fail on whatever they open first. Build it: `zig build {s}`.\n",
            .{ h.name, h.step },
        );
    }
    if (@import("builtin").mode == .Debug) {
        try w.print(
            "mnml-zig test: this is a DEBUG build. The corpus's timings assume the shipped one; the deadlines are scaled {d}× here, but a script's own `wait <ms>` is not, so the heaviest files (an integration pane mounting, a live Lua picker) can still fail on time alone. Re-run a timing failure with `zig build e2e -Doptimize=ReleaseSafe` before believing it.\n",
            .{e2e.runner.debug_slowdown},
        );
    }
    try w.flush();
}

fn noAppDriver(_: *anyopaque, _: Allocator, _: Io, _: e2e.driver.Config) anyerror!e2e.Driver {
    return error.NoAppDriverYet;
}

/// `--sizes` takes a comma list of `WxH`, and the word `ladder` for the
/// breakpoint sweep (`e2e.runner.ladder`) — the same preset the ghostty
/// harness takes, so one script can be swept identically in either.
fn appendSizes(gpa: Allocator, out: *std.ArrayList(e2e.Size), spec: []const u8) !bool {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "ladder")) {
            try out.appendSlice(gpa, e2e.runner.ladder);
            continue;
        }
        try out.append(gpa, parseSize(tok) orelse return false);
    }
    return out.items.len > 0;
}

fn parseSize(tok: []const u8) ?e2e.Size {
    const x = std.mem.indexOfScalar(u8, tok, 'x') orelse return null;
    const cols = std.fmt.parseInt(u16, tok[0..x], 10) catch return null;
    const rows = std.fmt.parseInt(u16, tok[x + 1 ..], 10) catch return null;
    if (cols < 10 or rows < 10) return null;
    return .{ .cols = cols, .rows = rows };
}

fn usage(w: *Io.Writer, msg: []const u8) !u8 {
    try w.print("mnml-zig test: {s}\n", .{msg});
    try w.flush();
    return 2;
}

/// Parse every file and report; the way to validate the corpus before
/// there is an App to run it against.
fn parseOnly(gpa: Allocator, io: Io, roots: []const []const u8, w: *Io.Writer) !u8 {
    var total: usize = 0;
    var failed: usize = 0;
    for (roots) |root| {
        const files = e2e.runner.collectFiles(gpa, io, root) catch |err| switch (err) {
            error.PathNotFound => {
                try w.print("mnml-zig test: no such path: {s}\n", .{root});
                try w.flush();
                return 2;
            },
            else => return err,
        };
        defer {
            for (files) |p| gpa.free(p);
            gpa.free(files);
        }
        for (files) |path| {
            total += 1;
            const name = std.fs.path.basename(path);
            const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
                failed += 1;
                try w.print("  FAIL {s} — can't read: {s}\n", .{ name, @errorName(e) });
                continue;
            };
            defer gpa.free(text);
            var diag: e2e.parser.Diagnostic = .{};
            var script = e2e.parser.parse(gpa, text, &diag) catch |e| switch (e) {
                error.Syntax => {
                    failed += 1;
                    try w.print("  FAIL {s} — {s}\n", .{ name, diag.message() });
                    continue;
                },
                else => return e,
            };
            script.deinit();
            try w.print("  ok   {s}\n", .{name});
        }
    }
    try w.print("\n{d}/{d} passed\n", .{ total - failed, total });
    try w.flush();
    return if (failed == 0) 0 else 1;
}

// ─── mnml-zig [WS] --headless ───────────────────────────────────────────

/// `mnml-zig [WORKSPACE] --headless [--stub]` — the virtual screen driven
/// through `<ws>/.mnml/<subdir>/`. `MNML_COLS` / `MNML_ROWS` size it,
/// `MNML_IPC_DIR` relocates the channel. Exit 75 asks the wrapper to
/// rebuild and relaunch.
fn headlessSubcommand(gpa_in: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    // `-Dmem-report`: every byte of the session goes through the counter.
    var counting: mem_report.Counting = .{ .child = gpa_in };
    const gpa = if (mem_report.enabled) counting.allocator() else gpa_in;
    if (mem_report.enabled) mem_report.installTreeSitter();
    var use_stub = false;
    var workspace: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (takesValue(a)) {
            i += 1; // `--input vim`: the value is not a workspace
        } else if (std.mem.eql(u8, a, "--stub")) {
            use_stub = true;
        } else if (a.len > 0 and a[0] != '-') workspace = a;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_rel = workspace orelse ".";
    const ws = Io.Dir.cwd().realPathFile(io, ws_rel, &cwd_buf) catch return usage(w, "workspace is not a directory");
    const ws_abs = cwd_buf[0..ws];

    const size = headless.sizeFromEnv(env.get("MNML_COLS"), env.get("MNML_ROWS"));
    const opts: headless.Options = .{
        .size = size,
        .ipc = .{ .dir_override = env.get("MNML_IPC_DIR"), .subdir = profile.ipcSubdir(profile.of(env)) },
    };
    var stub_factory: e2e.driver.StubFactory = .{};
    const factory: e2e.Factory = if (use_stub) stub_factory.factory() else app_factory orelse {
        try w.writeAll("mnml-zig --headless: no App driver yet (use --stub to drive the recording stub)\n");
        try w.flush();
        return 2;
    };
    const startup = try loadConfig(gpa, io, env, ws_abs, argv, false);
    defer gpa.free(startup.data_root);
    // Headless has no first frame to toast on; the seed still happened.
    defer if (startup.note) |n| gpa.free(n);
    // `make` owns `loaded` from here, whatever it returns.
    const cfg: e2e.driver.Config = .{ .workspace = ws_abs, .data_root = startup.data_root, .cols = size.cols, .rows = size.rows, .cfg = startup.loaded.config, .loaded = startup.loaded, .startup_hook = true };
    const driver = try factory.make(gpa, io, cfg);
    defer driver.deinit();
    const restart = try headless.run(gpa, io, driver, ws_abs, opts);
    return if (restart) 75 else 0;
}

test {
    _ = @import("config/root.zig");
    _ = @import("core/alloc.zig");
    _ = @import("core/key.zig");
    _ = @import("core/event.zig");
    _ = @import("commands/specs.zig");
    _ = @import("commands/reference.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/command.zig");
    _ = @import("core/panel.zig");
    _ = @import("core/hooks.zig");
    _ = @import("core/clipboard_os.zig");
    _ = @import("core/child.zig");
    _ = @import("app.zig");
    _ = @import("regex/regex.zig");
    _ = @import("ipc/root.zig");
    _ = @import("e2e/root.zig");
    _ = @import("headless.zig");
    _ = @import("broker_cli.zig");
    _ = @import("tui/marker.zig");
    _ = @import("editor/edit_op.zig");
    _ = @import("editor/clipboard.zig");
    _ = @import("editor/editor.zig");
    _ = @import("editor/editorconfig.zig");
    _ = @import("editor/undo.zig");
    _ = @import("editor/saved.zig");
    _ = @import("editor/motion.zig");
    _ = @import("editor/insert.zig");
    _ = @import("editor/delete.zig");
    _ = @import("editor/select.zig");
    _ = @import("editor/line.zig");
    _ = @import("editor/register.zig");
    _ = @import("editor/apply.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("input/mod.zig");
    _ = @import("input/standard.zig");
    _ = @import("input/vim.zig");
    _ = @import("app/driver.zig");
    _ = @import("scripting/lua.zig");
    _ = @import("scripting/doc_check.zig");
    _ = @import("app/smoke_test.zig");
    _ = @import("http/cli.zig");
    _ = @import("http/multipart.zig");
    _ = @import("http/body.zig");
    _ = @import("http/proxy.zig");
    _ = @import("http/yaml.zig");
    _ = @import("http/discover.zig");
    _ = @import("http/sources.zig");
    _ = @import("tui/loop.zig");
    _ = @import("ui/ui.zig");
    _ = @import("glyph/svg.zig");
    _ = @import("glyph/ttf.zig");
    _ = @import("glyph/builder.zig");
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}

test "size flags parse WxH and reject anything under 10" {
    try std.testing.expectEqual(e2e.Size{ .cols = 80, .rows = 24 }, parseSize("80x24").?);
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("80"));
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("8x24"));
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("axb"));
}

test "--startup-picker is MNML_STARTUP_PICKER=1 for this process" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!try applyStartupPickerFlag(&env, &.{ "ws", "--ascii" }));
    try std.testing.expect(env.get("MNML_STARTUP_PICKER") == null);
    try std.testing.expect(try applyStartupPickerFlag(&env, &.{ "--startup-picker", "ws" }));
    try std.testing.expectEqualStrings("1", env.get("MNML_STARTUP_PICKER").?);
}

test "the harness report names the build step for every helper binary that is missing" {
    // A missing helper binary is otherwise silent: `$MNML_JIRA` expands
    // to nothing, the manifest a script writes names no binary, no pane
    // mounts, and the file fails on the pane's title — which is a long
    // way from "you have not built it yet".
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("MNML_JIRA", "/built/mnml-jira");
    // Empty counts as missing: that is what a `.binary = "$MNML_JIRA"`
    // manifest ends up with, and it is the shape that fails silently.
    try env.put("MNML_FAKE_JIRA", "");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try reportHarness(&env, &out.writer);
    const said = out.written();
    try std.testing.expect(std.mem.indexOf(u8, said, "$MNML_JIRA is unset") == null);
    try std.testing.expect(std.mem.indexOf(u8, said, "$MNML_FAKE_JIRA is unset") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "`zig build jira-integration`") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "$MNML_BITBUCKET_INTEGRATION is unset") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "`zig build bitbucket-integration`") != null);
    // And a Debug build says so, because the corpus's timings are the
    // shipped build's (`src/e2e/runner.zig`'s `debug_slowdown`).
    try std.testing.expectEqual(@import("builtin").mode == .Debug, std.mem.indexOf(u8, said, "DEBUG build") != null);
}

test "--no-session is the flag run.sh fresh passes; --input's value is never a workspace" {
    try std.testing.expect(hasNoSessionFlag(&.{ "ws", "--no-session" }));
    try std.testing.expect(!hasNoSessionFlag(&.{ "ws", "--ascii" }));
    try std.testing.expect(takesValue("--input") and takesValue("--config"));
    try std.testing.expect(!takesValue("--no-session") and !takesValue("--ascii"));
}
