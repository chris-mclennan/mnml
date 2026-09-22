//! Project runners: `cargo.*`, `npm.*`, `pytest.*`, `go.*`, `dotnet.*`,
//! the project-agnostic `test.*` (Rust / npm / Go / .NET / pytest / Zig),
//! and the tools picker. Each runs its command in a pty pane below the
//! active one — .NET and Zig in the TESTS pane (`tests_pane.zig`).
//!
//! Detection walks UP from the active editor's directory — so a file in
//! `packages/app/` finds `packages/app/package.json` before the root's —
//! and stops at the workspace root: it never looks above the folder the
//! user opened (`runners_dont_walk_up.test`). A missing manifest is a
//! toast named after the command id (`go.test: no go.mod …`), never the
//! subcommand string, and a missing binary offers its install command.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty_pane = @import("pty_pane.zig");
const pty = @import("pty");
const cmd_picker = @import("cmd_picker.zig");
const lsp_client = @import("../lsp/client.zig");
const dotnet = @import("dotnet.zig");
const tests_pane = @import("tests_pane.zig");
const Prompt = app_mod.Prompt;

pub const table = .{
    .@"cargo.test" = &cargoTest,
    .@"cargo.check" = &cargoCheck,
    .@"cargo.clippy" = &cargoClippy,
    .@"cargo.build" = &cargoBuild,
    .@"cargo.fmt" = &cargoFmt,
    .@"npm.test" = &npmTest,
    .@"npm.run" = &npmRun,
    .@"npm.run_script" = &npmRunScript,
    .@"npm.build" = &npmBuild,
    .@"npm.start" = &npmStart,
    .@"npm.install" = &npmInstall,
    .@"npm.lint" = &npmLint,
    .@"pytest.run" = &pytestRun,
    .@"pytest.failed" = &pytestFailed,
    .@"go.test" = &goTest,
    .@"go.build" = &goBuild,
    .@"go.vet" = &goVet,
    .@"go.run" = &goRun,
    .@"go.run_path" = &goRunPath,
    .@"dotnet.build" = &dotnetBuild,
    .@"dotnet.run" = &dotnetRun,
    .@"dotnet.test" = &dotnetTest,
    .@"dotnet.restore" = &dotnetRestore,
    .@"dotnet.watch" = &dotnetWatch,
    .@"test.run_all" = &testRunAll,
    .@"test.run_file" = &testRunFile,
    .@"test.run_at_cursor" = &testRunAtCursor,
    .@"test.rerun_failed" = &testRerunFailed,
    .@"tools.installer" = &toolsInstaller,
};

/// The last runner command, for `test.rerun_failed` in a project whose
/// tool has no "last failed" mode. Owned by the app's runner state.
pub const State = struct {
    last_cmdline: ?[]u8 = null,
    last_cwd: ?[]u8 = null,
    /// A `cargo test` whose filter may match nothing: read its tally
    /// when it exits (`onFrame`).
    probe: ?Probe = null,

    pub const Probe = struct { pane: PaneId, filter: []u8 };

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.last_cmdline) |c| gpa.free(c);
        if (self.last_cwd) |c| gpa.free(c);
        self.clearProbe(gpa);
    }

    fn clearProbe(self: *State, gpa: Allocator) void {
        if (self.probe) |pr| gpa.free(pr.filter);
        self.probe = null;
    }

    fn remember(self: *State, gpa: Allocator, cmdline: []const u8, cwd: []const u8) Allocator.Error!void {
        const c = try gpa.dupe(u8, cmdline);
        errdefer gpa.free(c);
        const d = try gpa.dupe(u8, cwd);
        if (self.last_cmdline) |old| gpa.free(old);
        if (self.last_cwd) |old| gpa.free(old);
        self.last_cmdline = c;
        self.last_cwd = d;
    }
};

// ─── detection ──────────────────────────────────────────────────────────

fn exists(io: Io, dir: []const u8, name: []const u8, buf: []u8) bool {
    return existsExt(io, dir, name, "", buf);
}

/// `<dir>/<name><ext>` is a file (or anything stat-able).
fn existsExt(io: Io, dir: []const u8, name: []const u8, ext: []const u8, buf: []u8) bool {
    const p = std.fmt.bufPrint(buf, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch return false;
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// The nearest directory at or above `start` holding one of `manifests`,
/// never above `workspace`. `start` must be inside the workspace (or be
/// it); anything else is treated as the workspace itself.
pub fn findManifestDir(io: Io, start: []const u8, manifests: []const []const u8, workspace: []const u8) ?[]const u8 {
    var cur: []const u8 = if (std.mem.startsWith(u8, start, workspace)) start else workspace;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        for (manifests) |m| if (exists(io, cur, m, &buf)) return cur;
        if (std.mem.eql(u8, cur, workspace)) return null;
        cur = std.fs.path.dirname(cur) orelse return null;
        if (cur.len < workspace.len) return null;
    }
}

/// Where a detection walk starts: the directory of the last editor the
/// user was in (a runner pane taking focus must not lose the monorepo
/// context), else the workspace.
pub fn startDir(app: *App) []const u8 {
    const id = app.last_editor orelse return app.workspace;
    const e = app.panes.editor(id) orelse return app.workspace;
    const path = e.buf.doc.path orelse return app.workspace;
    return std.fs.path.dirname(path) orelse app.workspace;
}

/// Is `bin` on the child's PATH?
pub fn onPath(app: *App, bin: []const u8) bool {
    return findOnPath(app.io, &app.env, bin);
}

/// The PATH walk behind `onPath`. A name with a directory in it is
/// checked as given. Otherwise every PATH entry is tried — split on the
/// platform's delimiter — first as the bare name, then, when `PATHEXT`
/// is set (Windows: `.COM;.EXE;.BAT;.CMD…`), with each of those
/// extensions, the way `CreateProcessW` and `cmd.exe` resolve `git`
/// to `git.exe` and `npm` to `npm.cmd`.
pub fn findOnPath(io: Io, env: *const std.process.Environ.Map, bin: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return pathOf(io, env, &buf, bin) != null;
}

/// Where `findOnPath` found `bin`: `<dir>/<bin><ext>` in `buf`, or the
/// name itself when it carries a directory. A worker that spawns
/// without a shell needs this — `std.process.run` resolves a bare
/// argv[0] against the process's own PATH, not the map it is given.
pub fn pathOf(io: Io, env: *const std.process.Environ.Map, buf: *[std.fs.max_path_bytes]u8, bin: []const u8) ?[]const u8 {
    if (std.fs.path.dirname(bin) != null) {
        _ = Io.Dir.cwd().statFile(io, bin, .{}) catch return null;
        return bin;
    }
    const path = env.get("PATH") orelse return null;
    const pathext = env.get("PATHEXT") orelse "";
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (exists(io, dir, bin, buf)) return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, bin }) catch null;
        var exts = std.mem.splitScalar(u8, pathext, ';');
        while (exts.next()) |ext| {
            if (ext.len == 0) continue;
            if (existsExt(io, dir, bin, ext, buf)) return std.fmt.bufPrint(buf, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, bin, ext }) catch null;
        }
    }
    return null;
}

// ─── running ────────────────────────────────────────────────────────────

/// Run `cmdline` through the platform's shell (`sh -c`, or `cmd /d /c`)
/// in a pane below, at `cwd`.
pub fn spawn(app: *App, label: []const u8, cmdline: []const u8, cwd: []const u8, kind: pty_pane.Kind) CommandError!PaneId {
    var shell_buf: [4][]const u8 = undefined;
    const id = try pty_pane.open(app, .{
        .argv = pty.shellArgv(&shell_buf, &app.env, cmdline),
        .cwd = cwd,
        .label = label,
        .placement = .below,
        .kind = kind,
    });
    try app.runners.remember(app.gpa, cmdline, cwd);
    return id;
}

/// `<bin> <subcmd>` at the nearest `manifest`. `slug` is the command's
/// identity in the toast (`build` for `npm.build`, which runs `npm run
/// build`); it cannot be read off `subcmd`.
fn runManifestCommand(app: *App, manifest: []const u8, bin: []const u8, slug: []const u8, subcmd: []const u8) CommandError!void {
    _ = try runManifestCommandId(app, manifest, bin, slug, subcmd);
}

/// `runManifestCommand`, handing back the pane it spawned (null when
/// the tool is missing and the installer was offered instead).
fn runManifestCommandId(app: *App, manifest: []const u8, bin: []const u8, slug: []const u8, subcmd: []const u8) CommandError!?PaneId {
    const arena = app.frame.allocator();
    const root = findManifestDir(app.io, startDir(app), &.{manifest}, app.workspace) orelse
        return app.diag.fail(arena, "{s}.{s}: no {s} found in {s} or any parent", .{ bin, slug, manifest, app.workspace });
    if (!onPath(app, bin)) {
        try offerInstall(app, bin);
        return null;
    }
    const cmdline = try std.fmt.allocPrint(arena, "{s} {s}", .{ bin, subcmd });
    return try spawn(app, cmdline, cmdline, root, .runner);
}

// ─── cargo ──────────────────────────────────────────────────────────────

fn runCargo(app: *App, subcmd: []const u8) CommandError!void {
    const slug = firstWord(subcmd);
    return runManifestCommand(app, "Cargo.toml", "cargo", slug, subcmd);
}

fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    return it.next() orelse s;
}

fn cargoTest(app: *App) CommandError!void {
    return runCargo(app, "test");
}
fn cargoCheck(app: *App) CommandError!void {
    return runCargo(app, "check");
}
fn cargoClippy(app: *App) CommandError!void {
    return runCargo(app, "clippy --all-targets");
}
fn cargoBuild(app: *App) CommandError!void {
    return runCargo(app, "build");
}
fn cargoFmt(app: *App) CommandError!void {
    return runCargo(app, "fmt");
}

// ─── npm ────────────────────────────────────────────────────────────────

/// `npm <subcmd>`. A `run <script>` is checked against the nearest
/// package.json's `scripts` first, so a missing script is a toast and not
/// an npm error buried in the pane.
fn runNpm(app: *App, slug: []const u8, subcmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (std.mem.startsWith(u8, subcmd, "run ")) {
        const script = std.mem.trim(u8, subcmd["run ".len..], " ");
        if (findManifestDir(app.io, startDir(app), &.{"package.json"}, app.workspace)) |dir| {
            if (try packageScripts(app, dir)) |scripts| {
                if (!scripts.has(script)) {
                    return app.diag.fail(arena, "npm.{s}: no `{s}` script in package.json — available: {s}", .{ slug, script, scripts.preview });
                }
            }
        }
    }
    return runManifestCommand(app, "package.json", "npm", slug, subcmd);
}

const Scripts = struct {
    names: []const []const u8,
    /// `test / build`, or `(none defined)`.
    preview: []const u8,

    fn has(self: Scripts, name: []const u8) bool {
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// The `scripts` names of `<dir>/package.json`, on the frame arena. Null
/// when the file does not parse or has no `scripts` object.
fn packageScripts(app: *App, dir: []const u8) Allocator.Error!?Scripts {
    const arena = app.frame.allocator();
    const path = try std.fs.path.join(arena, &.{ dir, "package.json" });
    const src = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(4 << 20)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch return null;
    if (parsed != .object) return null;
    const scripts = parsed.object.get("scripts") orelse return null;
    if (scripts != .object) return null;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = scripts.object.iterator();
    while (it.next()) |kv| try names.append(arena, kv.key_ptr.*);
    const preview = if (names.items.len == 0) "(none defined)" else try std.mem.join(arena, " / ", names.items);
    return .{ .names = names.items, .preview = preview };
}

fn npmTest(app: *App) CommandError!void {
    return runNpm(app, "test", "test");
}
fn npmRun(app: *App) CommandError!void {
    return runNpm(app, "run", "run dev");
}
fn npmBuild(app: *App) CommandError!void {
    return runNpm(app, "build", "run build");
}
fn npmStart(app: *App) CommandError!void {
    return runNpm(app, "start", "start");
}
fn npmInstall(app: *App) CommandError!void {
    return runNpm(app, "install", "install");
}
fn npmLint(app: *App) CommandError!void {
    return runNpm(app, "lint", "run lint");
}

/// `npm.run_script`: a prompt for the script name.
fn npmRunScript(app: *App) CommandError!void {
    if (findManifestDir(app.io, startDir(app), &.{"package.json"}, app.workspace) == null)
        return app.diag.fail(app.frame.allocator(), "npm.run_script: no package.json found", .{});
    openPrompt(app, "npm run: script name", .npm_run_script, null);
}

pub fn npmRunScriptAccept(app: *App, text: []const u8) CommandError!void {
    const script = std.mem.trim(u8, text, " \t");
    if (script.len == 0) return app.diag.fail(app.frame.allocator(), "npm.run_script: empty script name", .{});
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run {s}", .{script});
    return runNpm(app, script, subcmd);
}

fn openPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose, seed: ?[]const u8) void {
    app.overlay.deinit(app.gpa);
    var state = Prompt.init(app.gpa, title);
    if (seed) |s| state.setText(app.gpa, s) catch {};
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

// ─── pytest ─────────────────────────────────────────────────────────────

const py_manifests = [_][]const u8{ "pyproject.toml", "setup.py", "requirements.txt" };

fn isPytestFile(name: []const u8) bool {
    return (std.mem.startsWith(u8, name, "test_") and std.mem.endsWith(u8, name, ".py")) or std.mem.endsWith(u8, name, "_test.py");
}

/// `<dir>/tests` or `<dir>/test` holds a `test_*.py` / `*_test.py`, one
/// level deep — a bare `tests/` (every Rust repo has one) is not a
/// Python project.
fn hasPytestFiles(io: Io, root: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "tests", "test" }) |sub| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, sub }) catch continue;
        var dir = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (isPytestFile(entry.name)) return true;
            if (entry.kind != .directory) continue;
            var subdir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer subdir.close(io);
            var sit = subdir.iterate();
            while (sit.next(io) catch null) |e2| if (isPytestFile(e2.name)) return true;
        }
    }
    return false;
}

/// The Python project's root for the tests pane (`tests_pane.Runner.pytest`):
/// the nearest manifest's directory, else the workspace when it holds
/// real test files; and a pytest to run — the project's own venv (the
/// pane puts it first on PATH) or one on PATH, else the install box.
pub fn pytestRoot(app: *App) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const root = findManifestDir(app.io, startDir(app), &py_manifests, app.workspace) orelse app.workspace;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var has_manifest = false;
    for (py_manifests) |m| if (exists(app.io, root, m, &buf)) {
        has_manifest = true;
    };
    if (!has_manifest and !hasPytestFiles(app.io, root))
        return app.diag.fail(arena, "pytest: no pyproject.toml / setup.py / requirements.txt / test files at {s}", .{app.workspace});
    const venvs = [_][]const u8{ ".venv/bin/pytest", ".venv/Scripts/pytest.exe", "venv/bin/pytest", "venv/Scripts/pytest.exe" };
    var in_venv = false;
    for (venvs) |v| if (exists(app.io, root, v, &buf)) {
        in_venv = true;
    };
    if (!in_venv and !onPath(app, "pytest")) {
        try offerInstall(app, "pytest");
        return error.Failed;
    }
    return root;
}

fn pytestRun(app: *App) CommandError!void {
    return tests_pane.pytestAll(app);
}
fn pytestFailed(app: *App) CommandError!void {
    return tests_pane.pytestRerunFailed(app);
}

// ─── go ─────────────────────────────────────────────────────────────────

/// `go <subcmd>`. `go run .` looks for `cmd/<app>/` at the module root:
/// one → run it; several → a picker; none → the literal `go run .`.
fn runGo(app: *App, subcmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (std.mem.eql(u8, subcmd, "run .")) {
        if (findManifestDir(app.io, startDir(app), &.{"go.mod"}, app.workspace)) |root| {
            const apps = try goCmdDirs(app, root);
            switch (apps.len) {
                0 => {},
                1 => return runManifestCommand(app, "go.mod", "go", "run", try std.fmt.allocPrint(arena, "run ./cmd/{s}", .{apps[0]})),
                else => return openGoRunPicker(app, apps),
            }
        }
    }
    return runManifestCommand(app, "go.mod", "go", firstWord(subcmd), subcmd);
}

/// The names under `<root>/cmd/`, sorted, on the frame arena.
fn goCmdDirs(app: *App, root: []const u8) Allocator.Error![]const []const u8 {
    const arena = app.frame.allocator();
    const p = try std.fs.path.join(arena, &.{ root, "cmd" });
    var dir = Io.Dir.cwd().openDir(app.io, p, .{ .iterate = true }) catch return &.{};
    defer dir.close(app.io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn openGoRunPicker(app: *App, apps: []const []const u8) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (apps) |a| try labels.append(gpa, try std.fmt.allocPrint(gpa, "cmd/{s}", .{a}));
    try cmd_picker.openPicker(app, "go run: pick a cmd/<app>", .go_run_cmd, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// The picker's choice: `cmd/<app>` → `go run ./cmd/<app>`.
pub fn goRunAccept(app: *App, label: []const u8) CommandError!void {
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run ./{s}", .{label});
    return runManifestCommand(app, "go.mod", "go", "run", subcmd);
}

fn goTest(app: *App) CommandError!void {
    return runGo(app, "test ./...");
}
fn goBuild(app: *App) CommandError!void {
    return runGo(app, "build ./...");
}
fn goVet(app: *App) CommandError!void {
    return runGo(app, "vet ./...");
}
fn goRun(app: *App) CommandError!void {
    return runGo(app, "run .");
}

fn goRunPath(app: *App) CommandError!void {
    if (findManifestDir(app.io, startDir(app), &.{"go.mod"}, app.workspace) == null)
        return app.diag.fail(app.frame.allocator(), "go.run_path: no go.mod found", .{});
    openPrompt(app, "go run: package path", .go_run_path, "./");
}

pub fn goRunPathAccept(app: *App, text: []const u8) CommandError!void {
    const path = std.mem.trim(u8, text, " \t");
    if (path.len == 0) return app.diag.fail(app.frame.allocator(), "go.run_path: empty path", .{});
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run {s}", .{path});
    return runManifestCommand(app, "go.mod", "go", "run", subcmd);
}

// ─── dotnet ─────────────────────────────────────────────────────────────

/// Which directory a `dotnet` verb runs in (`dotnet.Project`).
const DotnetRoot = enum { build, run };

/// `dotnet <subcmd>` at the nearest project / solution. `slug` names
/// the command in the toast (`dotnet.watch` runs `watch run`).
fn runDotnet(app: *App, slug: []const u8, subcmd: []const u8, root_kind: DotnetRoot) CommandError!void {
    const arena = app.frame.allocator();
    const proj = (try dotnet.find(app.io, arena, startDir(app), app.workspace)) orelse
        return app.diag.fail(arena, "dotnet.{s}: no *.csproj / *.sln found in {s} or any parent", .{ slug, app.workspace });
    if (!onPath(app, "dotnet")) return offerInstall(app, "dotnet");
    const root = switch (root_kind) {
        .build => proj.buildRoot(),
        .run => proj.runRoot(),
    };
    const cmdline = try std.fmt.allocPrint(arena, "dotnet {s}", .{subcmd});
    _ = try spawn(app, cmdline, cmdline, root, .runner);
}

fn dotnetBuild(app: *App) CommandError!void {
    return runDotnet(app, "build", "build", .build);
}
fn dotnetRun(app: *App) CommandError!void {
    return runDotnet(app, "run", "run", .run);
}
/// `dotnet.test`: the results pane (`tests_pane.zig`), not a pty.
fn dotnetTest(app: *App) CommandError!void {
    return tests_pane.dotnetAll(app);
}
fn dotnetRestore(app: *App) CommandError!void {
    return runDotnet(app, "restore", "restore", .build);
}
fn dotnetWatch(app: *App) CommandError!void {
    return runDotnet(app, "watch", "watch run", .run);
}

/// The test the cursor is in: the grammar's outline when the file has
/// one, the line patterns otherwise.
pub fn dotnetTestAtCursor(app: *App) CommandError!?dotnet.TestId {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return null;
    const ed = e.buf.editor;
    if (try e.syntax.symbols(ed, arena)) |syms| return dotnet.testAt(syms, ed.cursor);
    return dotnet.testAtText(arena, ed.bytes(), ed.cursor);
}

/// `--filter "FullyQualifiedName~A|FullyQualifiedName~B"` for the
/// classes of the active file; null when it declares none.
pub fn dotnetFileFilter(app: *App) CommandError!?[]const u8 {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return null;
    const syms = (try e.syntax.symbols(e.buf.editor, arena)) orelse return null;
    return dotnet.fileFilterArg(arena, syms);
}

// ─── test.* — whichever project this is ─────────────────────────────────

pub const Project = enum { cargo, npm, go, dotnet, pytest, zig };

/// The project kind at or above the active file: the nearest manifest
/// decides, a Python layout without one counts when it has test files.
/// A `.cs` file asks for its project first, so a repo with a frontend's
/// `package.json` at the root still tests with `dotnet`; a `.zig` file
/// asks for its `build.zig` the same way (this repo has a `package.json`
/// under `site/`, and mnml-zig's own tests are `zig build test`).
pub fn detectProject(app: *App) ?Project {
    const start = startDir(app);
    if (activeExtIs(app, ".cs") and hasDotnetProject(app, start)) return .dotnet;
    if (activeExtIs(app, ".zig") and findManifestDir(app.io, start, &.{"build.zig"}, app.workspace) != null) return .zig;
    if (findManifestDir(app.io, start, &.{"Cargo.toml"}, app.workspace) != null) return .cargo;
    if (findManifestDir(app.io, start, &.{"package.json"}, app.workspace) != null) return .npm;
    if (findManifestDir(app.io, start, &.{"go.mod"}, app.workspace) != null) return .go;
    if (hasDotnetProject(app, start)) return .dotnet;
    if (findManifestDir(app.io, start, &.{"build.zig"}, app.workspace) != null) return .zig;
    if (findManifestDir(app.io, start, &py_manifests, app.workspace) != null) return .pytest;
    if (hasPytestFiles(app.io, app.workspace)) return .pytest;
    return null;
}

/// The last editor's file has this extension (case-insensitive).
fn activeExtIs(app: *App, ext: []const u8) bool {
    const id = app.last_editor orelse return false;
    const e = app.panes.editor(id) orelse return false;
    const p = e.buf.doc.path orelse return false;
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(p), ext);
}

fn hasDotnetProject(app: *App, start: []const u8) bool {
    return (dotnet.find(app.io, app.frame.allocator(), start, app.workspace) catch null) != null;
}

fn requireProject(app: *App) CommandError!Project {
    return detectProject(app) orelse app.diag.fail(app.frame.allocator(), "test: no Cargo.toml / package.json / go.mod / *.csproj / build.zig / Python project at {s}", .{app.workspace});
}

/// `test.run_all`: the project's own runner — in the results pane when
/// it is one the pane parses (dotnet, vitest, pytest), a pty otherwise.
fn testRunAll(app: *App) CommandError!void {
    switch (try requireProject(app)) {
        .cargo => return runCargo(app, "test"),
        .npm => return if (tests_pane.vitestProject(app) != null) tests_pane.vitestAll(app) else runNpm(app, "test", "test"),
        .go => return runGo(app, "test ./..."),
        .dotnet => return tests_pane.dotnetAll(app),
        .pytest => return tests_pane.pytestAll(app),
        .zig => return tests_pane.zigAll(app),
    }
}

/// The active file, workspace-relative.
fn activeRel(app: *App) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "open a test file first", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "open a saved test file first", .{});
    return app.relPath(path);
}

fn testRunFile(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const rel = try activeRel(app);
    switch (try requireProject(app)) {
        .cargo => {
            // Relative to the crate's own manifest, not the workspace:
            // `crates/x/src/lib.rs` is `src/lib.rs` to its `cargo`.
            const abs = app.activeEditor().?.buf.doc.path.?;
            const root = findManifestDir(app.io, startDir(app), &.{"Cargo.toml"}, app.workspace) orelse app.workspace;
            const in_crate = if (abs.len > root.len + 1 and std.mem.startsWith(u8, abs, root)) abs[root.len + 1 ..] else rel;
            const args = try cargoTestArgs(arena, in_crate);
            const pane = (try runManifestCommandId(app, "Cargo.toml", "cargo", "test", try std.fmt.allocPrint(arena, "test {s}", .{args}))) orelse return;
            // A name filter can match nothing and still exit 0: watch
            // the tally.
            if (args.len > 0 and args[0] != '-') {
                app.runners.clearProbe(app.gpa);
                app.runners.probe = .{ .pane = pane, .filter = try app.gpa.dupe(u8, args) };
            }
        },
        .npm => return if (tests_pane.vitestProject(app) != null) tests_pane.vitestFile(app) else runNpm(app, "test", try std.fmt.allocPrint(arena, "test -- {s}", .{rel})),
        .go => return runGo(app, try std.fmt.allocPrint(arena, "test ./{s}", .{std.fs.path.dirname(rel) orelse "."})),
        .dotnet => return tests_pane.dotnetFile(app),
        .pytest => return tests_pane.pytestFile(app),
        .zig => return tests_pane.zigFile(app),
    }
}

/// `cargo test`'s argument for "the tests in this file". cargo has no
/// such selector: its positional is a test-NAME filter, and `cargo test
/// main` on `src/main.rs` matched nothing, ran 0 tests and said `ok`.
/// The file's role picks the target instead — `src/lib.rs` → `--lib`,
/// `src/main.rs` → `--bins`, `src/bin/x.rs` → `--bin x`, `tests/x.rs`
/// → `--test x`, `examples/x.rs` → `--example x`, `benches/x.rs` →
/// `--bench x` — and any other `src/a/b.rs` (or `src/a/b/mod.rs`)
/// filters on its module path, `a::b::`, which is what a `mod tests`
/// inside it is named under. `rel` is relative to the crate's manifest.
pub fn cargoTestArgs(arena: Allocator, rel: []const u8) Allocator.Error![]const u8 {
    const path = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, path, '\\', '/');
    const stem = std.fs.path.stem(path);
    if (std.mem.eql(u8, path, "src/lib.rs")) return "--lib";
    if (std.mem.eql(u8, path, "src/main.rs")) return "--bins";
    const Target = struct { dir: []const u8, flag: []const u8 };
    for ([_]Target{ .{ .dir = "src/bin/", .flag = "--bin" }, .{ .dir = "tests/", .flag = "--test" }, .{ .dir = "examples/", .flag = "--example" }, .{ .dir = "benches/", .flag = "--bench" } }) |tg| {
        if (std.mem.startsWith(u8, path, tg.dir)) {
            const inner = path[tg.dir.len..];
            // `src/bin/x/main.rs` is the bin `x`; `tests/x/main.rs` the test `x`.
            const name = if (std.mem.indexOfScalar(u8, inner, '/')) |slash| inner[0..slash] else stem;
            return std.fmt.allocPrint(arena, "{s} {s}", .{ tg.flag, name });
        }
    }
    var mod = path;
    if (std.mem.startsWith(u8, mod, "src/")) mod = mod["src/".len..];
    if (std.mem.endsWith(u8, mod, ".rs")) mod = mod[0 .. mod.len - ".rs".len];
    if (std.mem.endsWith(u8, mod, "/mod")) mod = mod[0 .. mod.len - "/mod".len];
    if (mod.len == 0) return "";
    const out = try std.mem.replaceOwned(u8, arena, mod, "/", "::");
    return std.fmt.allocPrint(arena, "{s}::", .{out});
}

/// The tally of a `test result:` line — `ok. 2 passed; 1 failed; …`.
pub fn cargoResultCounts(line: []const u8) ?struct { passed: u64, failed: u64 } {
    const at = std.mem.indexOf(u8, line, "test result:") orelse return null;
    const rest = line[at + "test result:".len ..];
    return .{ .passed = countBefore(rest, " passed") orelse return null, .failed = countBefore(rest, " failed") orelse 0 };
}

fn countBefore(s: []const u8, word: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, s, word) orelse return null;
    var start = at;
    while (start > 0 and std.ascii.isDigit(s[start - 1])) start -= 1;
    if (start == at) return null;
    return std.fmt.parseInt(u64, s[start..at], 10) catch null;
}

/// Each frame: a probed `cargo test` that has exited is read off its
/// grid — every `test result:` row's tally — and 0 tests over a green
/// `ok` is said out loud. The pane keeps cargo's own output; the toast
/// is what stops "0 passed; 3 filtered out" reading as a pass.
pub fn onFrame(app: *App) void {
    const probe = app.runners.probe orelse return;
    const p = app.panes.pty(probe.pane) orelse return app.runners.clearProbe(app.gpa);
    if (p.exit == null) return;
    var results: usize = 0;
    var ran: u64 = 0;
    var line: [512]u8 = undefined;
    var y: u16 = 0;
    while (y < p.grid.rows()) : (y += 1) {
        var n: usize = 0;
        var x: u16 = 0;
        while (x < p.grid.cols() and n < line.len) : (x += 1) {
            const cp = p.grid.cell(x, y).cp;
            line[n] = if (cp == 0) ' ' else if (cp < 128) @intCast(cp) else '?';
            n += 1;
        }
        const counts = cargoResultCounts(line[0..n]) orelse continue;
        results += 1;
        ran += counts.passed + counts.failed;
    }
    // The grid paints a frame after the exit; no tally yet means wait.
    if (results == 0) {
        if (app.now_ms - (p.exited_at_ms orelse app.now_ms) > 2000) app.runners.clearProbe(app.gpa);
        return;
    }
    if (ran == 0) app.toast("cargo test: 0 tests matched `{s}` — nothing ran", .{probe.filter});
    app.runners.clearProbe(app.gpa);
}

/// The nearest test name above the cursor: a Rust `fn` under a
/// `#[test]`-style attribute, `def test_x`, `func TestX`, `it("x"` /
/// `test("x"`, Zig's `test "x" {`.
pub fn testNameAt(text: []const u8, cursor: usize) ?[]const u8 {
    const at = @min(cursor, text.len);
    // The cursor's own line, whole.
    var end = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |i| i else text.len;
    while (true) {
        const line_end = end;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..line_end], '\n')) |i| i + 1 else 0;
        const line = std.mem.trimStart(u8, text[line_start..line_end], " \t");
        const above: []const u8 = if (line_start == 0) "" else blk: {
            const prev_end = line_start - 1;
            const prev_start = if (std.mem.lastIndexOfScalar(u8, text[0..prev_end], '\n')) |i| i + 1 else 0;
            break :blk std.mem.trimStart(u8, text[prev_start..prev_end], " \t");
        };
        if (testNameIn(line, above)) |n| return n;
        if (line_start == 0) return null;
        end = line_start - 1;
    }
}

fn identAt(s: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
    return if (n > 0) s[0..n] else null;
}

fn testNameIn(line: []const u8, above: []const u8) ?[]const u8 {
    // Zig: `test "rect area" {` — the string is the name.
    if (std.mem.startsWith(u8, line, "test \"")) {
        const rest = line["test \"".len..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return if (close > 0) rest[0..close] else null;
    }
    // Rust: the attribute names the test, the fn carries the name.
    if (std.mem.startsWith(u8, above, "#[") and std.mem.indexOf(u8, above, "test") != null) {
        for ([_][]const u8{ "pub async fn ", "pub fn ", "async fn ", "fn " }) |p| if (std.mem.startsWith(u8, line, p)) return identAt(line[p.len..]);
    }
    const prefixes = [_][]const u8{ "fn test_", "async fn test_", "def test_", "async def test_", "func Test" };
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) {
        const from = p.len - (if (std.mem.endsWith(u8, p, "test_")) @as(usize, 5) else 4);
        return identAt(line[from..]);
    };
    for ([_][]const u8{ "it(", "test(", "it.only(", "test.only(" }) |p| if (std.mem.startsWith(u8, line, p)) {
        const rest = line[p.len..];
        if (rest.len < 2) return null;
        const q = rest[0];
        if (q != '"' and q != '\'' and q != '`') return null;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, q) orelse return null;
        return rest[1..close];
    };
    return null;
}

fn testRunAtCursor(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const rel = try activeRel(app);
    const project = try requireProject(app);
    if (project == .dotnet) return tests_pane.dotnetAtCursor(app);
    if (project == .zig) return tests_pane.zigAtCursor(app);
    const e = app.activeEditor().?;
    const name = testNameAt(e.buf.editor.bytes(), e.buf.editor.cursor) orelse
        return app.diag.fail(arena, "no test above the cursor", .{});
    switch (project) {
        .cargo => return runCargo(app, try std.fmt.allocPrint(arena, "test {s}", .{name})),
        .npm => return if (tests_pane.vitestProject(app) != null) tests_pane.vitestAtCursor(app, rel, name) else runNpm(app, "test", try std.fmt.allocPrint(arena, "test -- -t '{s}'", .{name})),
        .go => return runGo(app, try std.fmt.allocPrint(arena, "test ./{s} -run '^{s}$'", .{ std.fs.path.dirname(rel) orelse ".", name })),
        .pytest => return tests_pane.pytestAtCursor(app, rel, name),
        .dotnet, .zig => unreachable,
    }
}

/// The results pane's runners re-run the last run's failures by name
/// (dotnet's `--filter`, vitest's `-t` regex, pytest's node ids — `--lf`
/// before a run); the others re-run the last command.
fn testRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const project = detectProject(app);
    if (project == .pytest) return tests_pane.pytestRerunFailed(app);
    if (project == .dotnet) return tests_pane.dotnetRerunFailed(app);
    if (project == .zig) return tests_pane.zigRerunFailed(app);
    if (project == .npm and tests_pane.vitestProject(app) != null) return tests_pane.vitestRerunFailed(app);
    const cmdline = app.runners.last_cmdline orelse return app.diag.fail(arena, "nothing has run yet", .{});
    const cwd = app.runners.last_cwd orelse app.workspace;
    const c = try arena.dupe(u8, cmdline);
    const d = try arena.dupe(u8, cwd);
    _ = try spawn(app, c, c, d, .runner);
}

// ─── tools ──────────────────────────────────────────────────────────────

pub const ToolKind = enum {
    lsp,
    formatter,
    linter,
    runner,

    pub fn label(k: ToolKind) []const u8 {
        return switch (k) {
            .lsp => "lsp",
            .formatter => "fmt",
            .linter => "lint",
            .runner => "run",
        };
    }
};

pub const Tool = struct {
    name: []const u8,
    kind: ToolKind,
    /// The binary looked for on PATH.
    bin: []const u8,
    description: []const u8,
    /// Shell line that installs it, per platform.
    brew: []const u8,
    apt: []const u8,

    pub fn install(self: Tool) []const u8 {
        return switch (builtin.os.tag) {
            .macos => self.brew,
            .linux => self.apt,
            else => self.brew,
        };
    }
};

pub const known_tools = [_]Tool{
    .{ .name = "rust-analyzer", .kind = .lsp, .bin = "rust-analyzer", .description = "Rust language server", .brew = "rustup component add rust-analyzer", .apt = "rustup component add rust-analyzer" },
    .{ .name = "typescript-language-server", .kind = .lsp, .bin = "typescript-language-server", .description = "TypeScript / JavaScript language server", .brew = "npm i -g typescript typescript-language-server", .apt = "npm i -g typescript typescript-language-server" },
    .{ .name = "pyright", .kind = .lsp, .bin = "pyright-langserver", .description = "Python language server", .brew = "npm i -g pyright", .apt = "npm i -g pyright" },
    .{ .name = "gopls", .kind = .lsp, .bin = "gopls", .description = "Go language server", .brew = "go install golang.org/x/tools/gopls@latest", .apt = "go install golang.org/x/tools/gopls@latest" },
    .{ .name = "clangd", .kind = .lsp, .bin = "clangd", .description = "C / C++ language server", .brew = "brew install llvm", .apt = "sudo apt install -y clangd" },
    .{ .name = "zls", .kind = .lsp, .bin = "zls", .description = "Zig language server", .brew = "brew install zls", .apt = "sudo apt install -y zls" },
    .{ .name = "lua-language-server", .kind = .lsp, .bin = "lua-language-server", .description = "Lua language server", .brew = "brew install lua-language-server", .apt = "sudo apt install -y lua-language-server" },
    // // changed (lsp-defaults): the default rows `lsp/client.zig` gained;
    // the install lines are `client.installHint`'s.
    .{ .name = "vscode-json-language-server", .kind = .lsp, .bin = "vscode-json-language-server", .description = "JSON language server", .brew = "npm i -g vscode-langservers-extracted", .apt = "npm i -g vscode-langservers-extracted" },
    .{ .name = "yaml-language-server", .kind = .lsp, .bin = "yaml-language-server", .description = "YAML language server", .brew = "npm i -g yaml-language-server", .apt = "npm i -g yaml-language-server" },
    .{ .name = "vscode-html-language-server", .kind = .lsp, .bin = "vscode-html-language-server", .description = "HTML language server", .brew = "npm i -g vscode-langservers-extracted", .apt = "npm i -g vscode-langservers-extracted" },
    .{ .name = "vscode-css-language-server", .kind = .lsp, .bin = "vscode-css-language-server", .description = "CSS / SCSS / Less language server", .brew = "npm i -g vscode-langservers-extracted", .apt = "npm i -g vscode-langservers-extracted" },
    .{ .name = "csharp-ls", .kind = .lsp, .bin = "csharp-ls", .description = "C# language server (dotnet tool)", .brew = "dotnet tool install -g csharp-ls", .apt = "dotnet tool install -g csharp-ls" },
    .{ .name = "prettier", .kind = .formatter, .bin = "prettier", .description = "JS / TS / CSS / Markdown formatter", .brew = "npm i -g prettier", .apt = "npm i -g prettier" },
    .{ .name = "black", .kind = .formatter, .bin = "black", .description = "Python formatter", .brew = "pip install black", .apt = "pip install black" },
    .{ .name = "rustfmt", .kind = .formatter, .bin = "rustfmt", .description = "Rust formatter", .brew = "rustup component add rustfmt", .apt = "rustup component add rustfmt" },
    .{ .name = "eslint", .kind = .linter, .bin = "eslint", .description = "JS / TS linter", .brew = "npm i -g eslint", .apt = "npm i -g eslint" },
    .{ .name = "ruff", .kind = .linter, .bin = "ruff", .description = "Python linter + formatter", .brew = "brew install ruff", .apt = "pip install ruff" },
    .{ .name = "golangci-lint", .kind = .linter, .bin = "golangci-lint", .description = "Go linter aggregator", .brew = "brew install golangci-lint", .apt = "go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest" },
    .{ .name = "shellcheck", .kind = .linter, .bin = "shellcheck", .description = "Shell script linter", .brew = "brew install shellcheck", .apt = "sudo apt install -y shellcheck" },
    .{ .name = "cargo", .kind = .runner, .bin = "cargo", .description = "Rust build tool", .brew = "brew install rustup && rustup-init -y", .apt = "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" },
    .{ .name = "zig", .kind = .runner, .bin = "zig", .description = "Zig compiler + build system (`zig build test`)", .brew = "brew install zig", .apt = "sudo snap install zig --classic --beta" },
    .{ .name = "npm", .kind = .runner, .bin = "npm", .description = "Node package manager", .brew = "brew install node", .apt = "sudo apt install -y nodejs npm" },
    .{ .name = "go", .kind = .runner, .bin = "go", .description = "Go toolchain", .brew = "brew install go", .apt = "sudo apt install -y golang-go" },
    .{ .name = "pytest", .kind = .runner, .bin = "pytest", .description = "Python test runner", .brew = "pip install pytest", .apt = "pip install pytest" },
    .{ .name = "dotnet", .kind = .runner, .bin = "dotnet", .description = ".NET SDK (build / run / test)", .brew = "brew install --cask dotnet-sdk", .apt = "sudo apt install -y dotnet-sdk-8.0" },
};

pub fn toolByBin(bin: []const u8) ?u16 {
    for (known_tools, 0..) |tool, i| if (std.mem.eql(u8, tool.bin, bin)) return @intCast(i);
    return null;
}

fn toolByName(name: []const u8) ?u16 {
    for (known_tools, 0..) |tool, i| if (std.mem.eql(u8, tool.name, name)) return @intCast(i);
    return null;
}

/// A runner's binary is missing: say so, and offer to run its install
/// command in a pane. An unknown binary only gets the toast.
pub fn offerInstall(app: *App, bin: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const idx = toolByBin(bin) orelse return app.diag.fail(arena, "{s} is not on PATH", .{bin});
    try openInstallConfirm(app, idx);
}

/// // changed (lsp-defaults): the LSP chip menu's *Install <binary>…* —
/// a known tool gets the install box; a binary the tools table does
/// not know but `client.installHint` does runs its line straight into
/// a pane; one neither knows is a diag.
pub fn installBin(app: *App, bin: []const u8) CommandError!void {
    if (toolByBin(bin)) |idx| {
        if (onPath(app, bin)) {
            app.toast("{s} is installed", .{bin});
            return;
        }
        return openInstallConfirm(app, idx);
    }
    const arena = app.frame.allocator();
    const hint = lsp_client.installHint(bin) orelse return app.diag.fail(arena, "{s}: no install command known — put it on PATH", .{bin});
    const label = try std.fmt.allocPrint(arena, "install {s}", .{bin});
    _ = try spawn(app, label, hint, app.workspace, .command);
}

pub const install_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'i', .label = "Install" }, .{ .key = 'c', .label = "Copy command" }, .{ .key = 'n', .label = "Not now" } };

fn openInstallConfirm(app: *App, idx: u16) CommandError!void {
    const tool = known_tools[idx];
    const msg = try std.fmt.allocPrint(app.gpa, "  {s} is not installed.\n  {s}", .{ tool.bin, tool.install() });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Missing tool", .message = msg, .choices = &install_choices },
        .purpose = .{ .install_tool = idx },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The install box's answer.
pub fn installAccept(app: *App, idx: u16, choice: usize) CommandError!void {
    const tool = known_tools[idx];
    switch (choice) {
        0 => {
            const label = try std.fmt.allocPrint(app.frame.allocator(), "install {s}", .{tool.name});
            _ = try spawn(app, label, tool.install(), app.workspace, .command);
        },
        1 => {
            try app.clipboard.setYank(tool.install(), false);
            app.toast("copied: {s}", .{tool.install()});
        },
        else => {},
    }
}

/// `tools.installer`: every known tool with its install state; missing
/// ones first. Enter opens the install box (or says it is installed).
fn toolsInstaller(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for ([_]bool{ false, true }) |want_installed| {
        for (known_tools) |tool| {
            const installed = onPath(app, tool.bin);
            if (installed != want_installed) continue;
            const mark: []const u8 = if (installed) (if (app.cfg.ui.ascii_icons) "+" else "✓") else (if (app.cfg.ui.ascii_icons) "x" else "✗");
            try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} [{s}] {s} — {s}", .{ mark, tool.kind.label(), tool.name, tool.description }));
        }
    }
    try cmd_picker.openPicker(app, "External tools (Enter = install)", .tools, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// The tools picker's choice. The label carries the name after the kind chip.
pub fn toolAccept(app: *App, label: []const u8) CommandError!void {
    const after = std.mem.indexOf(u8, label, "] ") orelse return;
    const rest = label[after + 2 ..];
    const name = rest[0 .. std.mem.indexOf(u8, rest, " —") orelse rest.len];
    const idx = toolByName(name) orelse return;
    if (onPath(app, known_tools[idx].bin)) {
        app.toast("{s} is installed", .{name});
        return;
    }
    try openInstallConfirm(app, idx);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        // A workspace that is itself inside a Cargo project: the walk
        // must never see the parent's manifest.
        const app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn file(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn open(f: *Fixture, rel: []const u8) !void {
        const abs = try std.fs.path.join(t.allocator, &.{ f.root, rel });
        defer t.allocator.free(abs);
        _ = try f.app.openPath(abs);
    }

    fn run(f: *Fixture, id: command.CommandId) void {
        command.run(&f.app, .{ .static = id }) catch {};
    }

    fn toast(f: *Fixture) []const u8 {
        return f.app.lastToast() orelse "";
    }

    fn activeIsPty(f: *Fixture) bool {
        const id = f.app.active orelse return false;
        return f.app.panes.pty(id) != null;
    }
};

test "detection walks up from the file to the workspace root and no further" {
    var f = try Fixture.init();
    defer f.deinit();
    // The tmp root's parents have no go.mod, but plant one ABOVE by
    // pretending the workspace is a subdirectory.
    try f.file("go.mod", "module x\n");
    try f.file("sub/pkg/a.go", "package pkg\n");
    const sub = try std.fs.path.join(t.allocator, &.{ f.root, "sub" });
    defer t.allocator.free(sub);
    const pkg = try std.fs.path.join(t.allocator, &.{ f.root, "sub", "pkg" });
    defer t.allocator.free(pkg);
    // Workspace = root: found at the root.
    try t.expectEqualStrings(f.root, findManifestDir(t.io, pkg, &.{"go.mod"}, f.root).?);
    // Workspace = sub: the root's go.mod is above the workspace — not found.
    try t.expect(findManifestDir(t.io, pkg, &.{"go.mod"}, sub) == null);
    // A start outside the workspace is treated as the workspace.
    try t.expect(findManifestDir(t.io, "/", &.{"go.mod"}, sub) == null);
}

test "go/npm/pytest/cargo toast their id, not the subcommand, when the manifest is missing" {
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"go.test");
    try t.expect(std.mem.startsWith(u8, f.toast(), "go.test: no go.mod found in "));
    f.run(.@"npm.build");
    try t.expect(std.mem.startsWith(u8, f.toast(), "npm.build: no package.json found in "));
    f.run(.@"cargo.clippy");
    try t.expect(std.mem.startsWith(u8, f.toast(), "cargo.clippy: no Cargo.toml found in "));
    f.run(.@"pytest.run");
    try t.expect(std.mem.startsWith(u8, f.toast(), "pytest: no pyproject.toml / setup.py / requirements.txt / test files at "));
    try t.expect(!f.activeIsPty());
}

test "npm run validates the script against the nearest package.json, walking up from the open file" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("packages/app/package.json", "{\"name\":\"app\",\"scripts\":{\"test\":\"jest\",\"build\":\"tsc\"}}");
    try f.file("packages/app/src/index.ts", "export const x = 1;");
    try f.open("packages/app/src/index.ts");
    f.run(.@"npm.run");
    try t.expectEqualStrings("npm.run: no `dev` script in package.json — available: test / build", f.toast());
    try t.expect(!f.activeIsPty());
    f.run(.@"npm.lint");
    try t.expectEqualStrings("npm.lint: no `lint` script in package.json — available: test / build", f.toast());
    if (!pty_pane.supported or !onPath(&f.app, "npm")) return;
    f.run(.@"npm.build");
    try t.expect(f.activeIsPty());
    try t.expectEqualStrings("npm run build", f.app.panes.get(f.app.active.?).?.title());
    // The pane's cwd is the sub-package, and the context survives the
    // pty taking focus: a second runner still finds packages/app.
    const p = f.app.panes.pty(f.app.active.?).?;
    try t.expect(std.mem.endsWith(u8, p.cwd.?, "packages/app"));
    try t.expectEqualStrings("npm run build", f.app.runners.last_cmdline.?);
    f.run(.@"npm.run");
    try t.expectEqualStrings("npm.run: no `dev` script in package.json — available: test / build", f.toast());
}

test "pytest detection: a bare tests/ dir is not a project; test_*.py one level deep is; requirements.txt is" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("tests/integration.rs", "// rust");
    f.run(.@"pytest.run");
    try t.expect(std.mem.startsWith(u8, f.toast(), "pytest: no pyproject.toml"));
    try f.file("tests/unit/test_basic.py", "def test_basic(): pass");
    try t.expect(hasPytestFiles(t.io, f.root));
    try t.expectEqual(Project.pytest, detectProject(&f.app).?);
    var g = try Fixture.init();
    defer g.deinit();
    try g.file("requirements.txt", "pytest\n");
    try t.expectEqual(Project.pytest, detectProject(&g.app).?);
    try t.expect(!hasPytestFiles(t.io, g.root));
}

test "go run: one cmd/ dir is picked, two open the picker, none means the literal target" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("go.mod", "module x\n");
    try f.file("cmd/server/main.go", "package main");
    const one = try goCmdDirs(&f.app, f.root);
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expectEqualStrings("server", one[0]);
    try f.file("cmd/worker/main.go", "package main");
    f.run(.@"go.run");
    try t.expect(f.app.overlay == .picker);
    try t.expectEqualStrings("go run: pick a cmd/<app>", f.app.overlay.picker.state.title);
    try t.expectEqualStrings("cmd/server", f.app.overlay.picker.labels[0]);
    try t.expectEqualStrings("cmd/worker", f.app.overlay.picker.labels[1]);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try t.expect(f.app.overlay == .none);
}

test "test.* picks the project; the test name above the cursor is found for five languages" {
    try t.expectEqualStrings("adds", testNameAt("fn other() {}\n#[test]\nfn adds() {\n  x\n}", 30).?);
    try t.expectEqualStrings("test_it", testNameAt("def test_it():\n    assert True\n", 20).?);
    try t.expectEqualStrings("TestSum", testNameAt("func TestSum(t *testing.T) {\n}", 10).?);
    try t.expectEqualStrings("adds up", testNameAt("describe('x', () => {\n  it('adds up', () => {\n  });\n});", 40).?);
    try t.expectEqualStrings("rect area", testNameAt("const std = @import(\"std\");\ntest \"rect area\" {\n    try std.testing.expect(true);\n}\n", 50).?);
    try t.expect(testNameAt("test \"\" {}", 5) == null);
    try t.expect(testNameAt("nothing here", 5) == null);
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"test.run_all");
    try t.expect(std.mem.startsWith(u8, f.toast(), "test: no Cargo.toml / package.json / go.mod / *.csproj / build.zig / Python project at "));
    try f.file("Cargo.toml", "[package]\nname = \"x\"\n");
    try t.expectEqual(Project.cargo, detectProject(&f.app).?);
    f.run(.@"test.rerun_failed");
    try t.expectEqualStrings("nothing has run yet", f.toast());
}

test "a build.zig makes test.* a Zig project; a .zig file asks for it first, past a package.json at the root" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("build.zig", "const std = @import(\"std\");\npub fn build(b: *std.Build) void { _ = b; }\n");
    try f.file("src/a.zig", "test \"one\" {}\n");
    // Compared as optionals: a missing kind is a failed assertion, not
    // an unwrap panic (so `tools/break-check.sh` can read the verdict).
    try t.expectEqual(@as(?Project, .zig), detectProject(&f.app));
    // A frontend's manifest at the root does not take a .zig file away
    // from its build.zig; a .txt file is the manifest's.
    try f.file("package.json", "{}");
    try f.open("src/a.zig");
    try t.expectEqual(@as(?Project, .zig), detectProject(&f.app));
    try f.file("notes.txt", "x");
    try f.open("notes.txt");
    try t.expectEqual(@as(?Project, .npm), detectProject(&f.app));
    // `test.rerun_failed` on a Zig project with no pane yet says so.
    try f.open("src/a.zig");
    f.run(.@"test.rerun_failed");
    try t.expectEqualStrings("no Zig test run to re-run yet", f.toast());
}

test "dotnet: the toast names the id when no project is found; the sln builds and the csproj runs; a .cs file makes test.* a dotnet project" {
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"dotnet.build");
    try t.expect(std.mem.startsWith(u8, f.toast(), "dotnet.build: no *.csproj / *.sln found in "));
    f.run(.@"dotnet.watch");
    try t.expect(std.mem.startsWith(u8, f.toast(), "dotnet.watch: no *.csproj / *.sln found in "));
    try t.expect(!f.activeIsPty());
    // A .cs file with no project around it: the same toast, and test.* has no project.
    try f.file("src/Lonely.cs", "class A {}\n");
    try f.open("src/Lonely.cs");
    f.run(.@"dotnet.test");
    try t.expect(std.mem.startsWith(u8, f.toast(), "dotnet.test: no *.csproj / *.sln found in "));
    try t.expect(detectProject(&f.app) == null);
    // A solution at the root, a project below, a package.json at the root too.
    try f.file("All.sln", "");
    try f.file("package.json", "{}");
    try f.file("src/App/App.csproj", "<Project/>");
    try f.file("src/App/Program.cs", "class Program { static void Main() {} }\n");
    try f.open("src/App/Program.cs");
    try t.expectEqual(Project.dotnet, detectProject(&f.app).?);
    try f.file("src/notes.txt", "x");
    try f.open("src/notes.txt");
    try t.expectEqual(Project.npm, detectProject(&f.app).?);
    try f.open("src/App/Program.cs");
    if (!pty_pane.supported or builtin.os.tag == .windows) return;
    // A `dotnet` of our own on PATH: the pane opens with the verb as its
    // title, the build at the solution, the run at the project.
    try f.file("bin/dotnet", "#!/bin/sh\necho fake dotnet \"$@\"\n");
    const bin = try std.fs.path.join(t.allocator, &.{ f.root, "bin" });
    defer t.allocator.free(bin);
    const exe = try std.fs.path.join(t.allocator, &.{ bin, "dotnet" });
    defer t.allocator.free(exe);
    try Io.Dir.cwd().setFilePermissions(t.io, exe, .fromMode(0o755), .{});
    const path = try std.fmt.allocPrint(t.allocator, "{s}:/usr/bin:/bin", .{bin});
    defer t.allocator.free(path);
    try f.app.env.put("PATH", path);
    f.run(.@"dotnet.build");
    try t.expect(f.activeIsPty());
    try t.expectEqualStrings("dotnet build", f.app.panes.get(f.app.active.?).?.title());
    try t.expectEqualStrings(f.root, f.app.panes.pty(f.app.active.?).?.cwd.?);
    f.run(.@"dotnet.run");
    try t.expectEqualStrings("dotnet run", f.app.runners.last_cmdline.?);
    try t.expect(std.mem.endsWith(u8, f.app.runners.last_cwd.?, "src/App"));
    f.run(.@"dotnet.watch");
    try t.expectEqualStrings("dotnet watch run", f.app.runners.last_cmdline.?);
    // test.run_all and dotnet.test are the results pane, at the solution.
    f.run(.@"test.run_all");
    const tests_id = tests_pane.find(&f.app).?;
    const tp = &f.app.panes.get(tests_id).?.tests;
    try t.expectEqual(tests_pane.Runner.dotnet, tp.runner);
    try t.expectEqualStrings(f.root, tp.cwd.?);
    try t.expectEqual(@as(usize, 0), tp.last_args.len);
    tp.group.cancel(t.io);
    try f.open("src/App/Program.cs");
    f.run(.@"dotnet.test");
    try t.expectEqual(tests_id, tests_pane.find(&f.app).?);
    tp.group.cancel(t.io);
}

test "dotnet test.run_at_cursor / run_file: the enclosing Class.Method and the file's classes become --filter arguments" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("Tests/Tests.csproj", "<Project/>");
    try f.file("Tests/CalcTests.cs", "using Xunit;\n\npublic class CalcTests\n{\n    [Fact]\n    public void Adds()\n    {\n        Assert.Equal(2, 1 + 1);\n    }\n}\n\npublic class OtherTests\n{\n}\n");
    try f.open("Tests/CalcTests.cs");
    try t.expectEqual(Project.dotnet, detectProject(&f.app).?);
    const e = f.app.activeEditor().?;
    e.buf.editor.cursor = std.mem.indexOf(u8, e.buf.editor.bytes(), "Assert").?;
    const id = (try dotnetTestAtCursor(&f.app)).?;
    try t.expectEqualStrings("CalcTests", id.class);
    try t.expectEqualStrings("Adds", id.method);
    try t.expectEqualStrings("FullyQualifiedName~CalcTests|FullyQualifiedName~OtherTests", (try dotnetFileFilter(&f.app)).?);
    // Outside every method: the toast, no pane.
    e.buf.editor.cursor = 0;
    f.run(.@"test.run_at_cursor");
    try t.expectEqualStrings("no test method around the cursor", f.toast());
    try t.expect(tests_pane.find(&f.app) == null);
    if (builtin.os.tag == .windows) return;
    // With a `dotnet` on PATH the pane opens at the project with the filter.
    try f.file("bin/dotnet", "#!/bin/sh\necho fake dotnet \"$@\"\n");
    const bin = try std.fs.path.join(t.allocator, &.{ f.root, "bin" });
    defer t.allocator.free(bin);
    const exe = try std.fs.path.join(t.allocator, &.{ bin, "dotnet" });
    defer t.allocator.free(exe);
    try Io.Dir.cwd().setFilePermissions(t.io, exe, .fromMode(0o755), .{});
    const path = try std.fmt.allocPrint(t.allocator, "{s}:/usr/bin:/bin", .{bin});
    defer t.allocator.free(path);
    try f.app.env.put("PATH", path);
    e.buf.editor.cursor = std.mem.indexOf(u8, e.buf.editor.bytes(), "Assert").?;
    f.run(.@"test.run_at_cursor");
    const tp = &f.app.panes.get(tests_pane.find(&f.app).?).?.tests;
    try t.expect(std.mem.endsWith(u8, tp.cwd.?, "Tests"));
    try t.expectEqualStrings("--filter", tp.last_args[0]);
    try t.expectEqualStrings("FullyQualifiedName~CalcTests.Adds", tp.last_args[1]);
    tp.group.cancel(t.io);
    try f.open("Tests/CalcTests.cs");
    f.run(.@"test.run_file");
    try t.expectEqualStrings("FullyQualifiedName~CalcTests|FullyQualifiedName~OtherTests", tp.last_args[1]);
    tp.group.cancel(t.io);
}

test "tools: the picker lists every known tool with a kind chip; a missing tool opens the install box" {
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"tools.installer");
    try t.expect(f.app.overlay == .picker);
    try t.expectEqualStrings("External tools (Enter = install)", f.app.overlay.picker.state.title);
    try t.expectEqual(known_tools.len, f.app.overlay.picker.labels.len);
    var has_lsp = false;
    for (f.app.overlay.picker.labels) |l| if (std.mem.indexOf(u8, l, "[lsp]") != null) {
        has_lsp = true;
    };
    try t.expect(has_lsp);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // A binary that cannot be on PATH.
    try t.expect(!onPath(&f.app, "definitely-not-a-binary-xyz"));
    try t.expect(toolByBin("go") != null);
    try installAccept(&f.app, toolByBin("go").?, 1);
    try t.expect(std.mem.startsWith(u8, f.toast(), "copied: "));
    try t.expectEqualStrings(known_tools[toolByBin("go").?].install(), f.app.clipboard.text());
}

test "findOnPath: the platform delimiter splits PATH; PATHEXT adds the Windows extensions" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "plain", .data = "" });
    // Both spellings: on a case-insensitive filesystem (macOS, Windows)
    // the second write lands on the first file and there is one `tool.cmd`
    // that the upper-cased PATHEXT entry still finds; on a case-sensitive
    // one (Linux) there are two files, and `.CMD` finds the one it names.
    // With only the lower-cased file, the `.CMD` lookup below passed on
    // macOS and failed on Linux.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool.cmd", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool.CMD", .data = "" });

    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    // An empty entry and a missing directory ahead of the real one.
    const path = try std.fmt.allocPrint(t.allocator, "{c}{s}{c}{s}", .{ std.fs.path.delimiter, "/nonexistent-mnml", std.fs.path.delimiter, root });
    defer t.allocator.free(path);
    try env.put("PATH", path);
    try t.expect(findOnPath(t.io, &env, "plain"));
    try t.expect(!findOnPath(t.io, &env, "nope"));
    // No PATHEXT: `tool` is not `tool.cmd`.
    try t.expect(!findOnPath(t.io, &env, "tool"));
    try env.put("PATHEXT", ".COM;.EXE;.BAT;.CMD");
    try t.expect(findOnPath(t.io, &env, "tool"));
    try t.expect(!findOnPath(t.io, &env, "nope"));
    // A path with a directory in it is checked as given, PATH or not.
    const abs = try std.fs.path.join(t.allocator, &.{ root, "plain" });
    defer t.allocator.free(abs);
    try t.expect(findOnPath(t.io, &env, abs));
    // `pathOf` says where: the directory it was found in, the extension it took.
    var where: [std.fs.max_path_bytes]u8 = undefined;
    try t.expectEqualStrings(abs, pathOf(t.io, &env, &where, "plain").?);
    // The PATHEXT spelling comes back (`tool.CMD`), whichever of the two
    // files the filesystem resolved it to.
    const cmd = try std.fs.path.join(t.allocator, &.{ root, "tool.cmd" });
    defer t.allocator.free(cmd);
    try t.expect(std.ascii.eqlIgnoreCase(cmd, pathOf(t.io, &env, &where, "tool").?));
    try t.expect(pathOf(t.io, &env, &where, "nope") == null);
}

test "cargo run_file: the file's role picks the target, a module file its path filter; a tally line's counts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("--lib", try cargoTestArgs(a, "src/lib.rs"));
    try t.expectEqualStrings("--bins", try cargoTestArgs(a, "src/main.rs"));
    try t.expectEqualStrings("--bin tool", try cargoTestArgs(a, "src/bin/tool.rs"));
    try t.expectEqualStrings("--bin tool", try cargoTestArgs(a, "src/bin/tool/main.rs"));
    try t.expectEqualStrings("--test smoke", try cargoTestArgs(a, "tests/smoke.rs"));
    try t.expectEqualStrings("--example demo", try cargoTestArgs(a, "examples/demo.rs"));
    try t.expectEqualStrings("--bench speed", try cargoTestArgs(a, "benches/speed.rs"));
    try t.expectEqualStrings("shapes::", try cargoTestArgs(a, "src/shapes.rs"));
    try t.expectEqualStrings("net::http::", try cargoTestArgs(a, "src/net/http.rs"));
    try t.expectEqualStrings("net::", try cargoTestArgs(a, "src/net/mod.rs"));
    try t.expectEqualStrings("net::http::", try cargoTestArgs(a, "src\\net\\http.rs"));
    const c = cargoResultCounts("test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s").?;
    try t.expectEqual(@as(u64, 2), c.passed);
    try t.expectEqual(@as(u64, 1), c.failed);
    const z = cargoResultCounts("test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 3 filtered out; finished in 0.00s").?;
    try t.expectEqual(@as(u64, 0), z.passed + z.failed);
    try t.expect(cargoResultCounts("running 0 tests") == null);
}
