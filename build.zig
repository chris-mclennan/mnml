const std = @import("std");

/// The symbols face's file name, spelled once (`src/glyph/builder.zig`
/// carries the same string for the app's own bake).
const symbols_font_name = "MnmlSymbols.ttf";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── terminal core: ghostty-vt ──
    // The emulator is ghostty's `ghostty-vt` Zig module, used as a plain
    // zon dependency (not the C ABI). `emit-lib-vt` keeps ghostty's build
    // in library-only mode. `simd` pulls in simdutf/highway C++ for the
    // UTF-8 fast path; it is a build option so the cross-compile story can
    // be measured both ways (`-Dpty-simd=true`).
    const pty_simd = b.option(
        bool,
        "pty-simd",
        "Build ghostty-vt with its simdutf/highway C++ fast paths (default: false)",
    ) orelse false;
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .simd = pty_simd,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    // ghostty instantiates exactly ONE `uucode` module (tables generated
    // from its `src/build/uucode_config.zig`) and imports it into
    // `ghostty-vt`. vaxis's `Parser.zig` also `@import("uucode")`. Two
    // uucode instances sharing one `root.zig` on disk is a compile error
    // (`file exists in modules 'uucode' and 'uucode0'`), so vaxis is built
    // with `external_uucode = true` and handed ghostty's module — exactly
    // what ghostty's own `SharedDeps.zig` does for its vaxis import.
    const uucode_mod = ghostty_vt.import_table.get("uucode") orelse
        @panic("ghostty-vt no longer imports 'uucode'; update the vaxis uucode wiring");

    // ── terminal layer: libvaxis ──
    // Screen (cell store), Parser, Vaxis.render (diff + output) and
    // Capabilities. We drive it on our own std.Io.Writer instead of its
    // Tty/Loop, so only the module is wired here.
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");
    vaxis_mod.addImport("uucode", uucode_mod);

    // ── pty ──
    // `pty` is the reusable library module: ring, session, grid read-out.
    // It links libc for openpty/fork/execve/ioctl — Zig 0.16's std.posix
    // does not declare those, so they are reached through std.c and a local
    // extern (see src/pty/session_posix.zig). On Windows the same module is
    // ConPTY (src/pty/session_windows.zig), picked in src/pty/root.zig.
    const pty_mod = b.addModule("pty", .{
        .root_source_file = b.path("src/pty/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pty_mod.addImport("ghostty-vt", ghostty_vt);

    // ── syntax: tree-sitter ──
    const ts = addTreeSitter(b, target, optimize);

    // ── lua ──
    // Lua 5.4 compiled from C inside this build, bound through zlua's
    // `src/lib.zig` (vendored under `vendor/zlua/`: its `build.zig` and
    // the translate-c package it pins fail analysis on 0.16.0, and the
    // build runner compiles every dependency's build.zig — the same
    // reason tree-sitter is vendored). The C sources come from the
    // `lua54` tarball, the headers go through `Step.TranslateC`, and the
    // `config` options zlua's lib reads are declared here. Nothing
    // outside `src/scripting/` imports `zlua`.
    const zlua_mod = addLua(b, target, optimize);

    // ── regex ──
    // Oniguruma, through ghostty's `pkg/oniguruma` package (the bindings
    // and the C build are ghostty's; the C source is its lazy `oniguruma`
    // dependency). Reached as a sub-dependency of the ghostty dependency
    // already fetched for the terminal core, so there is no second copy
    // and no new hash in build.zig.zon. `src/regex/` is the only importer:
    // it translates vim patterns (`\v`, `\<`, `\c`, `\{n,m}`) into
    // Oniguruma's syntax, so the find bar, `:s` and the grep filter never
    // see the C API. The static library is linked on the root module,
    // which the unit-test binary shares.
    const onig_dep = ghostty_dep.builder.lazyDependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    }) orelse @panic("ghostty no longer vendors pkg/oniguruma; update the regex wiring");
    const onig_mod = onig_dep.module("oniguruma");
    const onig_lib = onig_dep.artifact("oniguruma");
    // ── end regex ──

    // ── themes ──
    // `themes/root.zig` imports every `themes/*.zon` at comptime, so a
    // malformed palette fails the build. It is its own module because the
    // main module is rooted at `src/` and cannot reach a sibling directory.
    const themes_mod = b.createModule(.{
        .root_source_file = b.path("themes/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── data ──
    // `data/root.zig` embeds the data files the app carries (the Nerd
    // Font glyph catalog); its own module for the same reason as themes.
    const data_mod = b.createModule(.{
        .root_source_file = b.path("data/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── command table: -Dpartial ──
    // Downgrades "command id has no runner" from a compile error to a
    // runtime toast. The spike ships with it ON because only the todos
    // runners exist; parity flips it OFF so a missing runner fails the
    // build (D5).
    const partial = b.option(bool, "partial", "Allow command ids without runners (spike builds)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "partial", partial);
    // `-Dmem-report`: count live bytes (the app's allocator, tree-sitter's
    // malloc) and print where a headless session's memory was as it ends.
    const mem_report = b.option(bool, "mem-report", "Count live bytes per subsystem; a headless session prints the table to stderr as it ends") orelse false;
    build_options.addOption(bool, "mem_report", mem_report);
    // How much slower this build's HOST code is than the shipped one.
    // The `.test` runner's deadlines — how long a failing expectation is
    // retried, how long one file may take (`src/e2e/runner.zig`) — are
    // written for the shipped build and bound work that is mostly Zig.
    // Unoptimized that work is an order of magnitude slower (measured:
    // one `mnml.commands("")` costs ≤ 0.6 ms against ReleaseSafe and
    // 5–10 ms against Debug), so a fixed figure is not the same
    // allowance: the corpus passed 668/668 against ReleaseSafe and
    // failed four files against Debug, which is what `zig build e2e`
    // builds by default. A deadline is an amount of WORK; this is what
    // converts it to a clock.
    build_options.addOption(u64, "debug_slowdown", if (optimize == .Debug) 20 else 1);

    // ── the side-by-side names: -Dinstall-names ──
    // The two names a second mnml on one machine would collide on: the
    // file-IPC mailbox under `<ws>/.mnml/` and the running-instance
    // marker under TMPDIR. A shipped mnml owns `ipc` / `mnml-running-…`
    // (Rust mnml's names — it is frozen); this repo's own builds keep
    // `ipc-zig` / `mnml-zig-running-…` so a dev build and the installed
    // one can run side by side (docs/DESIGN.md, "Side-by-side
    // mechanics"). `run.sh install` and `release` pass -Dinstall-names.
    //
    // Both name the STABLE profile only: `MNML_PROFILE=dev` always
    // takes `ipc-zig` / `mnml-zig-running-…` (src/config/profile.zig),
    // so a dev launch of an installed mnml is still its own instance.
    const install_names = b.option(bool, "install-names", "Name the IPC mailbox and the marker the way a shipped mnml does (ipc, mnml-running-)") orelse false;
    const ipc_subdir_opt = b.option([]const u8, "ipc-subdir", "IPC directory name under <ws>/.mnml/ (default: ipc-zig; ipc with -Dinstall-names)");
    const ipc_subdir = ipc_subdir_opt orelse if (install_names) "ipc" else "ipc-zig";
    build_options.addOption([]const u8, "ipc_subdir", ipc_subdir);
    const marker_prefix_opt = b.option([]const u8, "marker-prefix", "Running-instance marker prefix under TMPDIR (default: mnml-zig-running-; mnml-running- with -Dinstall-names)");
    const marker_prefix = marker_prefix_opt orelse if (install_names) "mnml-running-" else "mnml-zig-running-";
    build_options.addOption([]const u8, "marker_prefix", marker_prefix);

    // ── main executable ──
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Io.Threaded can only interrupt a blocked tty read (cancelation
        // via pthread_kill(SIGIO)) when libc is linked.
        .link_libc = true,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "pty", .module = pty_mod },
            .{ .name = "tree_sitter", .module = ts.runtime },
            .{ .name = "highlight", .module = ts.highlight },
            .{ .name = "themes", .module = themes_mod },
            .{ .name = "data", .module = data_mod },
            .{ .name = "zlua", .module = zlua_mod },
            .{ .name = "oniguruma", .module = onig_mod },
        },
    });
    root_module.addOptions("build_options", build_options);
    root_module.linkLibrary(onig_lib);
    const exe = b.addExecutable(.{ .name = "mnml-zig", .root_module = root_module });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mnml-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── tests ──
    const test_step = b.step("test", "Run unit tests");
    // `zig build unit` runs every unit test binary and nothing else; `test`
    // is `unit` plus the e2e gate. `tools/break-check.sh` builds `unit`:
    // the gate rewinds the shared stderr, so a capture of `zig build test`
    // loses the unit lines the guard has to read.
    const unit_step = b.step("unit", "Run the unit tests only (every test binary, no e2e gate)");
    test_step.dependOn(unit_step);
    // `-Dtest-filter=<substring>` narrows the unit tests at compile time; a
    // file no reference block names is then never scanned, so prefer the
    // run-time `MNML_TEST_FILTER` below (docs/CONTRIBUTING.md, "Running one test").
    const test_filter = b.option([]const u8, "test-filter", "Run only the unit tests whose name contains this");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    // `-Dtest-trace` swaps in `tools/test_runner.zig`: every test's name is
    // printed before it runs (a wedged suite names its test), and
    // `MNML_TEST_FILTER=<substring>` filters at run time on the built binary.
    const test_trace = b.option(bool, "test-trace", "Print each unit test's name as it runs; MNML_TEST_FILTER filters at run time") orelse false;
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (test_trace) .{ .path = b.path("tools/test_runner.zig"), .mode = .simple } else null;
    const tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters, .test_runner = test_runner });
    const tests_run = b.addRunArtifact(tests);
    unit_step.dependOn(&tests_run.step);
    // ── e2e: the .test corpus under `zig build` ──
    // `zig build e2e [-- ARGS]` runs the whole corpus (tests/e2e)
    // through the runner with `shell` steps allowed;
    // `zig build test` also runs the Phase-0 gate subset, and
    // `-Dtest-filter` narrows the .test files by name as it narrows
    // the unit tests (`--filter`). `check` runs the full corpus, minus
    // the one file that asserts TOML by design (E1 / E2:
    // `settings_persist_to_workspace.test`; its Zig twin passes).
    const e2eRun = struct {
        fn make(bld: *std.Build, artifact: *std.Build.Step.Compile, name: []const u8, args: []const []const u8, filter: ?[]const u8) *std.Build.Step.Run {
            const r = bld.addRunArtifact(artifact);
            r.setName(name);
            r.addArg("test");
            r.addArgs(args);
            if (filter) |f| r.addArgs(&.{ "--filter", f });
            r.setEnvironmentVariable("MNML_E2E_ALLOW_SHELL", "1");
            r.setCwd(bld.path("."));
            r.has_side_effects = true;
            return r;
        }
    }.make;
    const e2e_step = b.step("e2e", "Run the .test corpus (tests/e2e) through the runner; `-- ARGS` reach `mnml-zig test`");
    const e2e_run = e2eRun(b, exe, "mnml-zig test (the corpus)", &.{}, test_filter);
    if (b.args) |args| e2e_run.addArgs(args);
    e2e_step.dependOn(&e2e_run.step);
    const gate_in_test = e2eRun(b, exe, "mnml-zig test --gate", &.{"--gate"}, test_filter);
    gate_in_test.step.dependOn(&tests_run.step);
    test_step.dependOn(&gate_in_test.step);
    // ── end e2e ──

    // src/ui is reached through its barrel (`src/ui/ui.zig`) from main.zig's
    // `test {}` block, so every component's tests run under `zig build test`
    // on std.testing.allocator (leak = failure). It is not its own test
    // module: the components import `src/core/{ids,panel,key}.zig`, which
    // a module rooted at `src/ui/` cannot reach.

    // ── tui tests ──
    // src/tui through its barrel: the input worker's key naming and parser
    // tests, and term.zig's capability detection. libc for the same reason
    // as the main executable (Io.Threaded cancelation of blocked reads).
    // Both the pty module and the terminal session have a POSIX and a
    // Windows backend, so their tests are part of the graph on every
    // target; tests that need a pty or a tty skip themselves on Windows
    // (`error.SkipZigTest`). The two demos are POSIX-only executables.
    const tui_tests = b.addTest(.{
        .filters = test_filters,
        .test_runner = test_runner,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/tui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    unit_step.dependOn(&b.addRunArtifact(tui_tests).step);
    const pty_tests = b.addTest(.{ .root_module = pty_mod, .filters = test_filters, .test_runner = test_runner });
    const pty_test_run = b.addRunArtifact(pty_tests);
    const pty_test_step = b.step("pty-test", "Run the pty module tests");
    pty_test_step.dependOn(&pty_test_run.step);
    unit_step.dependOn(&pty_test_run.step);
    const demos_supported = target.result.os.tag != .windows;

    const ts_tests = b.addTest(.{ .name = "tree-sitter-tests", .root_module = ts.runtime, .filters = test_filters, .test_runner = test_runner });
    const highlight_tests = b.addTest(.{ .name = "highlight-tests", .root_module = ts.highlight, .filters = test_filters, .test_runner = test_runner });
    unit_step.dependOn(&b.addRunArtifact(ts_tests).step);
    unit_step.dependOn(&b.addRunArtifact(highlight_tests).step);
    const highlight_test_step = b.step("highlight-test", "Run the highlight module's tests only (grammars, queries, the engine)");
    highlight_test_step.dependOn(&b.addRunArtifact(highlight_tests).step);

    // ── docs + check (cutover prep) ─────────────────────────────────────
    // `zig build docs` regenerates docs/commands.md from the comptime spec
    // table (E8). `zig build check` is the CI gate (E7): fmt, the unit
    // tests in Debug and ReleaseSafe, the Phase-0 e2e gate, the same gate
    // swept at 80x24 / 120x40 / 200x60, and defaults.test.
    const reference_mod = b.createModule(.{ .root_source_file = b.path("src/commands/reference.zig"), .target = target, .optimize = optimize });
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "reference", .module = reference_mod }},
    });
    const gen = b.addExecutable(.{ .name = "gen-commands", .root_module = gen_mod });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addArg(b.pathFromRoot("docs/commands.md"));
    gen_run.has_side_effects = true;
    const docs_step = b.step("docs", "Regenerate docs/commands.md from the command spec table");
    docs_step.dependOn(&gen_run.step);
    const gen_tests = b.addTest(.{ .root_module = gen_mod, .filters = test_filters, .test_runner = test_runner });
    unit_step.dependOn(&b.addRunArtifact(gen_tests).step);

    const check_step = b.step("check", "The safety gates: fmt, Debug + ReleaseSafe unit tests, the e2e gate, the width sweep, defaults.test");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "tools" }, .check = true });
    check_step.dependOn(&fmt_check.step);
    // Each optimize mode is its own nested build so the mode is explicit
    // whatever -Doptimize this invocation carries; they run in sequence.
    const debug_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "-Doptimize=Debug" });
    debug_tests.setName("zig build test -Doptimize=Debug");
    debug_tests.step.dependOn(&fmt_check.step);
    const safe_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "-Doptimize=ReleaseSafe" });
    safe_tests.setName("zig build test -Doptimize=ReleaseSafe");
    safe_tests.step.dependOn(&debug_tests.step);
    const gate_run = b.addRunArtifact(exe);
    gate_run.setName("mnml-zig test --gate");
    gate_run.addArgs(&.{ "test", "--gate" });
    gate_run.setCwd(b.path("."));
    gate_run.has_side_effects = true;
    gate_run.step.dependOn(&safe_tests.step);
    const sweep_run = b.addRunArtifact(exe);
    sweep_run.setName("mnml-zig test --gate --sizes 80x24,120x40,200x60");
    sweep_run.addArgs(&.{ "test", "--gate", "--sizes", "80x24,120x40,200x60" });
    sweep_run.setCwd(b.path("."));
    sweep_run.has_side_effects = true;
    sweep_run.step.dependOn(&gate_run.step);
    const defaults_run = b.addRunArtifact(exe);
    defaults_run.setName("mnml-zig test tests/e2e/defaults.test");
    defaults_run.addArgs(&.{ "test", "tests/e2e/defaults.test" });
    defaults_run.setCwd(b.path("."));
    defaults_run.has_side_effects = true;
    defaults_run.step.dependOn(&sweep_run.step);
    check_step.dependOn(&defaults_run.step);
    // ── e2e: the full corpus under `check` ──
    const corpus_run = e2eRun(b, exe, "mnml-zig test (the full corpus)", &.{}, null);
    corpus_run.step.dependOn(&defaults_run.step);
    check_step.dependOn(&corpus_run.step);
    // ── end e2e ──
    // ── end docs + check ────────────────────────────────────────────────

    // ── glyph audit ─────────────────────────────────────────────────────
    // `zig build glyph-audit`: bake `data/nerd-glyphnames.json` into a
    // compact codepoint/name table, then list every Nerd Font glyph
    // literal in src/ with its ASCII twin (`tools/glyph_audit.zig`);
    // `--strict` fails on a site without one. The tool's own tests walk
    // the same three trees under `zig build unit` and assert the same.
    const glyph_opts = b.addOptions();
    glyph_opts.addOptionPath("src_root", b.path("src"));
    glyph_opts.addOptionPath("sdk_root", b.path("sdk/mnml-sdk/src"));
    glyph_opts.addOptionPath("integrations_root", b.path("integrations"));
    glyph_opts.addOptionPath("glyph_json", b.path("data/nerd-glyphnames.json"));
    const glyph_mod = b.createModule(.{ .root_source_file = b.path("tools/glyph_audit.zig"), .target = target, .optimize = optimize });
    glyph_mod.addOptions("build_options", glyph_opts);
    // The app runs the same audit in-process (`integrations.audit_glyphs`,
    // `menu.glyph_audit`, the `bake_*` ids — `src/app/glyph_audit.zig`).
    root_module.addImport("glyph_audit", glyph_mod);
    // ── the UI spec ─────────────────────────────────────────────────────
    // The Rust editor's screen dumps (`docs/ui-spec/`), embedded so the
    // statusline tests compare the painted row with the spec's row.
    // `docs/CONFIG.md`, embedded: its per-key comments are the ZON view
    // pane's hover copy for a config file (`src/config/zon_schema.zig`).
    root_module.addAnonymousImport("config_md", .{ .root_source_file = b.path("docs/CONFIG.md") });
    // `docs/LUA.md`, embedded: `src/scripting/doc_check.zig` walks it
    // against `api.zig`'s registration list, so a function that is
    // registered and not written down — or written down and not
    // registered — fails the suite rather than shipping.
    root_module.addAnonymousImport("lua_md", .{ .root_source_file = b.path("docs/LUA.md") });
    // The hover-help audit's allow-list (`src/app/info_view_audit.zig`):
    // the targets known to have no curated entry yet, so the audit
    // fails only on a NEW one.
    root_module.addAnonymousImport("hover_help_todo", .{ .root_source_file = b.path("docs/hover-help-todo.txt") });
    root_module.addAnonymousImport("ui_spec_rust_120x40", .{ .root_source_file = b.path("docs/ui-spec/rust-120x40.txt") });
    root_module.addAnonymousImport("ui_spec_rust_80x24", .{ .root_source_file = b.path("docs/ui-spec/rust-80x24.txt") });
    root_module.addAnonymousImport("ui_spec_rust_sessions_120x40", .{ .root_source_file = b.path("docs/ui-spec/rust-sessions-120x40.txt") });
    const glyph_exe = b.addExecutable(.{ .name = "glyph-audit", .root_module = glyph_mod });
    const glyph_bake = b.addRunArtifact(glyph_exe);
    glyph_bake.addArg("bake");
    glyph_bake.addFileArg(b.path("data/nerd-glyphnames.json"));
    const glyph_table = glyph_bake.addOutputFileArg("nerd-glyphs.tsv");
    const glyph_audit = b.addRunArtifact(glyph_exe);
    glyph_audit.addArg("audit");
    glyph_audit.addFileArg(glyph_table);
    glyph_audit.addDirectoryArg(b.path("src"));
    // The pane toolkit too: a glyph with no `--ascii` twin is exactly
    // as broken in the chrome every integration paints through as it is
    // in mnml's own.
    glyph_audit.addDirectoryArg(b.path("sdk/mnml-sdk/src"));
    // And the official integrations, whose statusline chips and pane
    // rows are as much of the shipped screen as mnml's own chrome: a
    // chip that paints a Nerd Font glyph on an `--ascii` terminal is
    // tofu there too.
    glyph_audit.addDirectoryArg(b.path("integrations"));
    glyph_audit.addArg("--strict");
    glyph_audit.has_side_effects = true;
    glyph_audit.stdio = .inherit;
    const glyph_step = b.step("glyph-audit", "Every Nerd Font glyph literal in src/, the SDK and integrations/ against data/nerd-glyphnames.json, with its --ascii twin");
    glyph_step.dependOn(&glyph_audit.step);
    const glyph_tests = b.addTest(.{ .root_module = glyph_mod, .filters = test_filters, .test_runner = test_runner });
    unit_step.dependOn(&b.addRunArtifact(glyph_tests).step);
    // ── end glyph audit ─────────────────────────────────────────────────

    // ── the symbols font ────────────────────────────────────────────────
    // `MnmlSymbols.ttf`: the face mnml's own block is drawn from — the
    // Claude and Codex marks, the two tree connectors, and the terminal
    // icon (`src/glyph/`). It installs beside the Lua script set, as
    // `share/mnml/fonts/MnmlSymbols.ttf`, and `scripts/package.sh` and
    // `nfpm/mnml.yaml` carry it from there the same way. The builder is
    // the module the app itself runs for a custom terminal icon, so the
    // shipped face and a user's own bake cannot drift.
    const glyph_builder_mod = b.createModule(.{ .root_source_file = b.path("src/glyph/builder.zig"), .target = b.graph.host, .optimize = .Debug });
    glyph_builder_mod.addImport("data", data_mod);
    const font_mod = b.createModule(.{ .root_source_file = b.path("tools/build_font.zig"), .target = b.graph.host, .optimize = .Debug });
    font_mod.addImport("glyph", glyph_builder_mod);
    const font_exe = b.addExecutable(.{ .name = "build-font", .root_module = font_mod });
    const font_run = b.addRunArtifact(font_exe);
    const font_file = font_run.addOutputFileArg(symbols_font_name);
    const font_install = b.addInstallFile(font_file, "share/mnml/fonts/" ++ symbols_font_name);
    b.getInstallStep().dependOn(&font_install.step);
    // The catalogue travels beside the font, so an archive built from
    // `zig-out/` already carries the Marketplace tab's default source.
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("data/marketplace.zon"), "share/mnml/marketplace.zon").step);
    const font_step = b.step("font", "Build share/mnml/fonts/MnmlSymbols.ttf from data/glyphs/");
    font_step.dependOn(&font_install.step);
    // `zig build font-merge -Dfont-in=<installed.ttf> -Dfont-out=<dest>`:
    // this build's glyphs merged INTO an already-installed face, so an
    // older MnmlSymbols keeps the codepoints this repo has no source
    // for. `run.sh install-font` is the only caller; it is a build step
    // rather than a shipped binary because installing the font is a
    // thing you do from a checkout.
    const merge_in = b.option([]const u8, "font-in", "font-merge: the installed MnmlSymbols.ttf to merge into");
    const merge_out = b.option([]const u8, "font-out", "font-merge: where the merged face is written");
    const merge_run = b.addRunArtifact(font_exe);
    merge_run.addArg("merge");
    merge_run.addArg(merge_in orelse "");
    merge_run.addArg(merge_out orelse "");
    merge_run.has_side_effects = true;
    merge_run.stdio = .inherit;
    const merge_step = b.step("font-merge", "Merge this build's MnmlSymbols glyphs into an installed face (-Dfont-in, -Dfont-out)");
    merge_step.dependOn(&merge_run.step);
    // ── end the symbols font ────────────────────────────────────────────

    // ── the hover-help audit ────────────────────────────────────────────
    // `zig build hover-audit`: every hoverable target the app can produce
    // against the info view's dictionary (`src/app/info_view_copy/`),
    // failing on a new target without an entry (the backlog lives in
    // docs/hover-help-todo.txt). It runs inside the app, so it is a
    // subcommand of the exe rather than a tool of its own.
    const hover_run = b.addRunArtifact(exe);
    hover_run.addArgs(&.{ "hover-audit", "--strict" });
    hover_run.has_side_effects = true;
    hover_run.stdio = .inherit;
    const hover_step = b.step("hover-audit", "Every hoverable target against the info view's curated entries; fails on a new target without one");
    hover_step.dependOn(&hover_run.step);

    // ── the arena audit ─────────────────────────────────────────────────
    // `zig build arena-audit`: every place a string that dies at the next
    // frame reaches a consumer that outlives the frame (a menu label, a
    // prompt title, a confirm message, the screen's grapheme slices).
    // Its own unit test walks the real `src/` under `zig build test`, so
    // the seventh bug of that shape fails the suite rather than shipping.
    const arena_opts = b.addOptions();
    arena_opts.addOptionPath("src_root", b.path("src"));
    // The job-result rule travels where the frame-arena ones do not:
    // an integration has no menus and no screen, but it does have a
    // worker handing results back with their own arenas, which is the
    // shape the bitbucket chip shipped broken.
    arena_opts.addOptionPath("integrations_root", b.path("integrations"));
    arena_opts.addOptionPath("sdk_root", b.path("sdk"));
    const arena_mod = b.createModule(.{ .root_source_file = b.path("tools/arena_audit.zig"), .target = target, .optimize = optimize });
    arena_mod.addOptions("build_options", arena_opts);
    const arena_exe = b.addExecutable(.{ .name = "arena-audit", .root_module = arena_mod });
    const arena_run = b.addRunArtifact(arena_exe);
    arena_run.addDirectoryArg(b.path("src"));
    arena_run.addArg("--strict");
    arena_run.has_side_effects = true;
    arena_run.stdio = .inherit;
    const arena_step = b.step("arena-audit", "Frame-arena and stack strings reaching consumers that outlive the frame");
    arena_step.dependOn(&arena_run.step);
    // …and the same binary over the two roots that hold the other
    // shape: a job result's arena let go by the consumer that kept a
    // slice out of it.
    for ([_][]const u8{ "integrations", "sdk" }) |root| {
        const jr = b.addRunArtifact(arena_exe);
        jr.addDirectoryArg(b.path(root));
        jr.addArg("--job-results");
        jr.addArg("--strict");
        jr.has_side_effects = true;
        jr.stdio = .inherit;
        arena_step.dependOn(&jr.step);
    }
    // …and the third shape, over `src/` again: something a worker holds
    // the ADDRESS of — an `Io.Group`, a queue, an event, a mutex —
    // declared by value inside a `Pane` payload. Panes live in an
    // ArrayList, so opening a pane moves them, and a moved group's
    // `cancel` waits forever. Three panes shipped with one.
    const pg = b.addRunArtifact(arena_exe);
    pg.addDirectoryArg(b.path("src"));
    pg.addArg("--pane-groups");
    pg.addArg("--strict");
    pg.has_side_effects = true;
    pg.stdio = .inherit;
    arena_step.dependOn(&pg.step);
    const arena_tests = b.addTest(.{ .root_module = arena_mod, .filters = test_filters, .test_runner = test_runner });
    unit_step.dependOn(&b.addRunArtifact(arena_tests).step);
    // ── end arena audit ─────────────────────────────────────────────────

    // ── the chrome audit ────────────────────────────────────────────────
    // `zig build chrome-audit`: chrome a component already owns, drawn by
    // hand somewhere else — a box-drawing glyph as a whole literal
    // outside `ui/border.zig` / the SDK's `chrome.zig`, an
    // `if (ascii) "..." else "…"` pair a component already answers.
    // Its unit test walks the three real trees under `zig build unit`, so
    // the next fork fails the suite rather than shipping.
    const chrome_opts = b.addOptions();
    chrome_opts.addOptionPath("src_root", b.path("src"));
    chrome_opts.addOptionPath("sdk_root", b.path("sdk"));
    chrome_opts.addOptionPath("integrations_root", b.path("integrations"));
    const chrome_mod = b.createModule(.{ .root_source_file = b.path("tools/chrome_audit.zig"), .target = target, .optimize = optimize });
    chrome_mod.addOptions("build_options", chrome_opts);
    const chrome_exe = b.addExecutable(.{ .name = "chrome-audit", .root_module = chrome_mod });
    const chrome_run = b.addRunArtifact(chrome_exe);
    chrome_run.addDirectoryArg(b.path("src"));
    chrome_run.addDirectoryArg(b.path("sdk"));
    chrome_run.addDirectoryArg(b.path("integrations"));
    chrome_run.addArg("--strict");
    chrome_run.has_side_effects = true;
    chrome_run.stdio = .inherit;
    const chrome_step = b.step("chrome-audit", "Chrome a component owns, drawn by hand somewhere else (box literals, ascii twins)");
    chrome_step.dependOn(&chrome_run.step);
    const chrome_tests = b.addTest(.{ .root_module = chrome_mod, .filters = test_filters, .test_runner = test_runner });
    unit_step.dependOn(&b.addRunArtifact(chrome_tests).step);
    // ── end chrome audit ────────────────────────────────────────────────

    // ── mnml-drive: the real-terminal harness (tools/drive/) ────────────
    // A dev-only program that launches its OWN ghostty window, drives it
    // with CoreGraphics events posted AT that process, and reads pixels
    // back. It is not shipped — nothing in `run.sh install`, `release` or
    // `scripts/package.sh` mentions it — and it is only part of the build
    // graph under `-Ddrive` on a macOS host, so every other platform and
    // CI never compiles it. `docs/DRIVE.md`.
    const want_drive = b.option(bool, "drive", "Build mnml-drive, the dev-only macOS+ghostty harness (tools/drive/)") orelse false;
    if (want_drive) {
        if (target.result.os.tag != .macos) {
            std.debug.panic("-Ddrive is macOS-only (the harness is CoreGraphics + ghostty); target is {s}", .{@tagName(target.result.os.tag)});
        }
        // `key.zig` is the only thing shared with the app: it imports
        // nothing but std, so the harness speaks mnml's own Key / KeyCode
        // / Mods without linking the editor (tools/drive/keys.zig says
        // why the parser is not shared too).
        const key_mod = b.createModule(.{ .root_source_file = b.path("src/core/key.zig"), .target = target, .optimize = optimize });
        const drive_mod = b.createModule(.{
            .root_source_file = b.path("tools/drive/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "key", .module = key_mod }},
        });
        drive_mod.linkFramework("CoreGraphics", .{});
        drive_mod.linkFramework("CoreFoundation", .{});
        drive_mod.linkFramework("ApplicationServices", .{});
        const drive_exe = b.addExecutable(.{ .name = "mnml-drive", .root_module = drive_mod });
        b.installArtifact(drive_exe);
        const drive_step = b.step("drive", "Build mnml-drive (zig-out/bin/mnml-drive)");
        drive_step.dependOn(&b.addInstallArtifact(drive_exe, .{}).step);
        // Its tests join the unit suite only when it is being built, so
        // `zig build unit` is the same on every machine by default.
        unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = drive_mod, .filters = test_filters, .test_runner = test_runner })).step);
    }
    // ── end mnml-drive ──────────────────────────────────────────────────

    // ── e2e: gate-build ──
    // Compile the exe and every test binary for the selected target without
    // running them, installed under zig-out/gate/. The exe alone is not a
    // cross-compile gate for the foreign code — nothing in main references
    // the grammars yet — but the test binaries link all 43 of them, so
    // `zig build gate-build -Dtarget=…` is what proves a target builds.
    const gate_step = b.step("gate-build", "Compile the exe and all test binaries without running (cross-target gate)");
    const gate_dir: std.Build.InstallDir = .{ .custom = "gate" };
    const GateBin = struct { compile: *std.Build.Step.Compile, name: []const u8 };
    for ([_]GateBin{
        .{ .compile = exe, .name = "mnml-zig" },
        .{ .compile = tests, .name = "test-main" },
        .{ .compile = pty_tests, .name = "test-pty" },
        .{ .compile = tui_tests, .name = "test-tui" },
        .{ .compile = ts_tests, .name = "test-tree-sitter" },
        .{ .compile = highlight_tests, .name = "test-highlight" },
    }) |g| {
        const compile = g.compile;
        const suffix = if (target.result.os.tag == .windows) ".exe" else "";
        gate_step.dependOn(&b.addInstallArtifact(compile, .{
            .dest_dir = .{ .override = gate_dir },
            .dest_sub_path = b.fmt("{s}{s}", .{ g.name, suffix }),
        }).step);
    }

    // ── pty-demo ──
    // The spike's proving ground: a login shell in a ghostty-vt Terminal,
    // painted with plain ANSI (termios + ioctl: POSIX only). Throwaway once
    // vaxis hosts the pane.
    if (demos_supported) {
        const demo_mod = b.createModule(.{
            .root_source_file = b.path("src/pty_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        demo_mod.addImport("pty", pty_mod);
        const demo = b.addExecutable(.{ .name = "pty-demo", .root_module = demo_mod });
        const demo_install = b.addInstallArtifact(demo, .{});
        const demo_run = b.addRunArtifact(demo);
        demo_run.step.dependOn(&demo_install.step);
        if (b.args) |args| demo_run.addArgs(args);
        const demo_step = b.step("pty-demo", "Run the pty demo (a shell in a ghostty-vt Terminal)");
        demo_step.dependOn(&demo_run.step);

        const pty_step = b.step("pty", "Build the pty module, its tests and the demo without running");
        pty_step.dependOn(&pty_tests.step);
        pty_step.dependOn(&demo_install.step);
    }

    // ── canvas-demo ──
    // The terminal layer end to end: Term + input worker + Canvas
    // primitives on a real tty. `zig build canvas-demo` runs it.
    const canvas_demo_mod = b.createModule(.{
        .root_source_file = b.path("src/canvas_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "themes", .module = themes_mod },
        },
    });
    const canvas_demo = b.addExecutable(.{ .name = "canvas-demo", .root_module = canvas_demo_mod });
    const canvas_demo_install = b.addInstallArtifact(canvas_demo, .{});
    if (demos_supported) b.getInstallStep().dependOn(&canvas_demo_install.step);
    const canvas_demo_run = b.addRunArtifact(canvas_demo);
    canvas_demo_run.step.dependOn(&canvas_demo_install.step);
    const canvas_demo_step = b.step("canvas-demo", "Run the canvas demo (Term + Canvas on the real terminal)");
    canvas_demo_step.dependOn(&canvas_demo_run.step);

    // ── release ──
    // What ships. Three steps and one option:
    //
    //   -Dversion=X      the string `--version` prints. Absent, a dev build
    //                    derives it: build.zig.zon's `.version`, the git short
    //                    SHA, and `-dirty` when the tree has uncommitted changes
    //                    (`0.3.0-dev+g1a2b3c4-dirty`).
    //   release-one      this target's exe, installed as
    //                    zig-out/release/<rust-triple>/mnml[.exe]. The Rust
    //                    triple, not Zig's, because every downstream consumer —
    //                    the tap formula, winget, nfpm, the install scripts —
    //                    keys on the names cargo-dist used (E6).
    //   release          `release-one` for each of the five shipped targets,
    //                    through a nested `zig build` per target: ReleaseSafe,
    //                    `-Dcpu=baseline`, the same cache dirs and prefix. A
    //                    nested build is how the module graph above gets built
    //                    per target without being written out five times.
    //   dist             `release`, then scripts/package.sh: .tar.xz (.zip on
    //                    Windows) + .sha256 per target, sha256.sum, the two
    //                    installers, dist-manifest.json — all under zig-out/dist/.
    //
    // Completions and a man page would be installed here too; mnml-zig ships
    // neither yet, so the archives carry the binary, the licenses, the README
    // and the CHANGELOG.
    const version = b.option([]const u8, "version", "Version stamped into --version (default: build.zig.zon version + git SHA)") orelse deriveVersion(b);
    build_options.addOption([]const u8, "version", version);

    const triple = rustTriple(b, target.result);
    const release_one = b.step("release-one", "Install this target's exe as zig-out/release/<rust-triple>/mnml (what `release` runs per target)");
    release_one.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } },
        .dest_sub_path = if (target.result.os.tag == .windows) "mnml.exe" else "mnml",
    }).step);
    // MnmlSymbols.ttf beside the binary, in the layout the archive has
    // (`scripts/package.sh` reads it from there, and refuses without
    // it). The font is the same bytes on every target — the builder
    // runs on the host and the file is not machine code.
    release_one.dependOn(&b.addInstallFile(font_file, b.fmt("release/{s}/share/mnml/fonts/" ++ symbols_font_name, .{triple})).step);
    // The catalogue the same way — the Marketplace tab's default source
    // has to be in the archive or a packaged mnml lists nothing.
    release_one.dependOn(&b.addInstallFile(b.path("data/marketplace.zon"), b.fmt("release/{s}/share/mnml/marketplace.zon", .{triple})).step);

    const release_step = b.step("release", "Cross-compile ReleaseSafe exes for the five shipped targets into zig-out/release/<rust-triple>/");
    for (release_targets) |rt| {
        const nested = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "release-one",
            b.fmt("-Dtarget={s}", .{rt.zig}),
            "-Dcpu=baseline",
            "-Doptimize=ReleaseSafe",
            b.fmt("-Dversion={s}", .{version}),
            // A shipped mnml is the one you live in: it owns `ipc` and
            // `mnml-running-…` whatever this tree's own builds are
            // named. An explicit -Dipc-subdir / -Dmarker-prefix still
            // wins, and is forwarded below.
            "-Dinstall-names=true",
            b.fmt("-Dpartial={}", .{partial}),
            b.fmt("-Dpty-simd={}", .{pty_simd}),
            "--prefix",
            b.install_path,
            "--cache-dir",
            b.cache_root.path orelse ".zig-cache",
            "--global-cache-dir",
            b.graph.global_cache_root.path orelse ".",
        });
        if (ipc_subdir_opt) |v| nested.addArg(b.fmt("-Dipc-subdir={s}", .{v}));
        if (marker_prefix_opt) |v| nested.addArg(b.fmt("-Dmarker-prefix={s}", .{v}));
        nested.setCwd(b.path("."));
        nested.setName(b.fmt("zig build release-one ({s})", .{rt.rust}));
        // Its outputs land under the prefix, not in the cache — always run it.
        nested.has_side_effects = true;
        release_step.dependOn(&nested.step);
    }

    const dist_step = b.step("dist", "`release`, then package zig-out/release/ into zig-out/dist/ (archives, sha256s, installers, manifest)");
    const pack = b.addSystemCommand(&.{
        "sh",
        "scripts/package.sh",
        "--version",
        version,
        "--release-dir",
        b.pathJoin(&.{ b.install_path, "release" }),
        "--out",
        b.pathJoin(&.{ b.install_path, "dist" }),
    });
    pack.setCwd(b.path("."));
    pack.setName("scripts/package.sh");
    pack.has_side_effects = true;
    pack.step.dependOn(release_step);
    dist_step.dependOn(&pack.step);
    // ── sdk ──
    // `sdk/mnml-sdk` is the package an integration depends on; the host
    // imports the same module so the wire (`wire.zig`) and the manifest
    // schema (`manifest.zig`) have one definition. Its unit tests run
    // under `zig build test` as their own binary (`sdk-tests`).
    // `mnml-hello` is the sample integration: `zig build sdk-example`
    // installs it, and the host's integration test spawns it through a
    // real mount socket (the path travels as a build option).
    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/mnml-sdk/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("mnml_sdk", sdk_mod);
    // The SDK's own tests — `ratelimit.zig`'s shared bucket among them,
    // which no integration's test binary would reach on its own (tests
    // in a dependency module are not run).
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "sdk-tests", .root_module = sdk_mod, .filters = test_filters, .test_runner = test_runner })).step);
    const hello_mod = b.createModule(.{
        .root_source_file = b.path("sdk/examples/hello/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const hello = b.addExecutable(.{ .name = "mnml-hello", .root_module = hello_mod });
    const hello_install = b.addInstallArtifact(hello, .{});
    b.getInstallStep().dependOn(&hello_install.step);
    const sdk_example_step = b.step("sdk-example", "Build the sample integration (zig-out/bin/mnml-hello)");
    sdk_example_step.dependOn(&hello_install.step);
    build_options.addOption([]const u8, "sdk_example_exe", b.getInstallPath(.bin, if (target.result.os.tag == .windows) "mnml-hello.exe" else "mnml-hello"));
    tests_run.step.dependOn(&hello_install.step);
    gate_step.dependOn(&b.addInstallArtifact(hello, .{
        .dest_dir = .{ .override = gate_dir },
        .dest_sub_path = b.fmt("mnml-hello{s}", .{if (target.result.os.tag == .windows) ".exe" else ""}),
    }).step);

    // ── integrations/ ──
    // The official Zig integrations live in `integrations/<id>/`, each
    // with its own build.zig on the SDK by path. `mnml-sample`
    // (`integrations/sample/`) is the fixture that proves the host: it
    // is built here beside the exe, its path reaches the unit tests as
    // `build_options.sample_integration_exe` and the corpus as
    // `$MNML_SAMPLE_INTEGRATION` (main.zig's `test`), and its own tests
    // run under `zig build test`.
    const sample_mod = b.createModule(.{
        .root_source_file = b.path("integrations/sample/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const sample = b.addExecutable(.{ .name = "mnml-sample", .root_module = sample_mod });
    const sample_install = b.addInstallArtifact(sample, .{});
    b.getInstallStep().dependOn(&sample_install.step);
    const sample_exe_name = b.fmt("mnml-sample{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    const sample_step = b.step("sample-integration", "Build the sample integration (zig-out/bin/mnml-sample)");
    sample_step.dependOn(&sample_install.step);
    build_options.addOption([]const u8, "sample_integration_exe", b.getInstallPath(.bin, sample_exe_name));
    tests_run.step.dependOn(&sample_install.step);
    e2e_run.step.dependOn(&sample_install.step);
    gate_in_test.step.dependOn(&sample_install.step);
    corpus_run.step.dependOn(&sample_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sample_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(sample, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = sample_exe_name }).step);

    // `mnml-bitbucket` (`integrations/bitbucket/`) is the Bitbucket
    // Cloud pull-request pane, and `mnml-fake-bitbucket`
    // (`integrations/bitbucket/tools/fake_bitbucket/`) the deterministic
    // Bitbucket its tests and the corpus drive. Both are built beside
    // the exe and reach the corpus as `$MNML_BITBUCKET_INTEGRATION` and
    // `$MNML_FAKE_BITBUCKET` (main.zig's `test`).
    const bitbucket_mod = b.createModule(.{
        .root_source_file = b.path("integrations/bitbucket/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const bitbucket = b.addExecutable(.{ .name = "mnml-bitbucket", .root_module = bitbucket_mod });
    const bitbucket_install = b.addInstallArtifact(bitbucket, .{});
    b.getInstallStep().dependOn(&bitbucket_install.step);
    const bitbucket_exe_name = b.fmt("mnml-bitbucket{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    const bitbucket_step = b.step("bitbucket-integration", "Build the Bitbucket integration (zig-out/bin/mnml-bitbucket)");
    bitbucket_step.dependOn(&bitbucket_install.step);
    build_options.addOption([]const u8, "bitbucket_integration_exe", b.getInstallPath(.bin, bitbucket_exe_name));
    e2e_run.step.dependOn(&bitbucket_install.step);
    gate_in_test.step.dependOn(&bitbucket_install.step);
    corpus_run.step.dependOn(&bitbucket_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bitbucket_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(bitbucket, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = bitbucket_exe_name }).step);

    const fake_bitbucket_mod = b.createModule(.{
        .root_source_file = b.path("integrations/bitbucket/tools/fake_bitbucket/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fake_bitbucket = b.addExecutable(.{ .name = "mnml-fake-bitbucket", .root_module = fake_bitbucket_mod });
    const fake_bitbucket_install = b.addInstallArtifact(fake_bitbucket, .{});
    b.getInstallStep().dependOn(&fake_bitbucket_install.step);
    const fake_bitbucket_exe_name = b.fmt("mnml-fake-bitbucket{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    build_options.addOption([]const u8, "fake_bitbucket_exe", b.getInstallPath(.bin, fake_bitbucket_exe_name));
    bitbucket_step.dependOn(&fake_bitbucket_install.step);
    e2e_run.step.dependOn(&fake_bitbucket_install.step);
    gate_in_test.step.dependOn(&fake_bitbucket_install.step);
    corpus_run.step.dependOn(&fake_bitbucket_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_bitbucket_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_bitbucket, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_bitbucket_exe_name }).step);

    // `integrations/jira/` is the Jira ticket viewer: its own package on
    // the SDK, built here beside the exe the way the sample is, with its
    // offline server (`integrations/jira/tools/fake_jira/`) beside it so
    // the corpus never touches the network. Both paths reach the unit
    // tests as build options and `mnml-zig test` as `$MNML_JIRA` /
    // `$MNML_FAKE_JIRA`.
    const jira_mod = b.createModule(.{
        .root_source_file = b.path("integrations/jira/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const jira_exe = b.addExecutable(.{ .name = "mnml-jira", .root_module = jira_mod });
    const jira_install = b.addInstallArtifact(jira_exe, .{});
    b.getInstallStep().dependOn(&jira_install.step);
    const jira_exe_name = b.fmt("mnml-jira{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    const jira_step = b.step("jira-integration", "Build the Jira integration (zig-out/bin/mnml-jira)");
    jira_step.dependOn(&jira_install.step);
    build_options.addOption([]const u8, "jira_integration_exe", b.getInstallPath(.bin, jira_exe_name));
    tests_run.step.dependOn(&jira_install.step);
    e2e_run.step.dependOn(&jira_install.step);
    gate_in_test.step.dependOn(&jira_install.step);
    corpus_run.step.dependOn(&jira_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = jira_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(jira_exe, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = jira_exe_name }).step);

    const fake_jira_mod = b.createModule(.{
        .root_source_file = b.path("integrations/jira/tools/fake_jira/main.zig"),
        .target = target,
        .optimize = optimize,
        // `--pid-file` writes `std.c.getpid()`. macOS always links libc, so
        // the call compiles there without asking; every other target needs
        // the dependency spelled out or it is a compile error.
        .link_libc = true,
    });
    const fake_jira = b.addExecutable(.{ .name = "mnml-fake-jira", .root_module = fake_jira_mod });
    const fake_jira_install = b.addInstallArtifact(fake_jira, .{});
    b.getInstallStep().dependOn(&fake_jira_install.step);
    const fake_jira_exe_name = b.fmt("mnml-fake-jira{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    build_options.addOption([]const u8, "fake_jira_exe", b.getInstallPath(.bin, fake_jira_exe_name));
    jira_step.dependOn(&fake_jira_install.step);
    tests_run.step.dependOn(&fake_jira_install.step);
    e2e_run.step.dependOn(&fake_jira_install.step);
    gate_in_test.step.dependOn(&fake_jira_install.step);
    corpus_run.step.dependOn(&fake_jira_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_jira_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_jira, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_jira_exe_name }).step);

    // ── fake DAP adapter ──
    // `mnml-fake-dap` (tools/fake_dap/) is the deterministic debug adapter
    // the DAP client test and the `dap_session_*.test` scripts drive; it
    // is installed beside the exe, its path reaches the unit tests as a
    // build option and the corpus as `$MNML_FAKE_DAP` (main.zig's `test`).
    const fake_dap_mod = b.createModule(.{ .root_source_file = b.path("tools/fake_dap/main.zig"), .target = target, .optimize = optimize });
    const fake_dap = b.addExecutable(.{ .name = "mnml-fake-dap", .root_module = fake_dap_mod });
    const fake_dap_install = b.addInstallArtifact(fake_dap, .{});
    b.getInstallStep().dependOn(&fake_dap_install.step);
    const fake_dap_exe_name = b.fmt("mnml-fake-dap{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    build_options.addOption([]const u8, "fake_dap_exe", b.getInstallPath(.bin, fake_dap_exe_name));
    // `tools/shims/`: fake toolchains (`dotnet`) a `.test` puts first on
    // PATH with `# env: PATH=${MNML_SHIMS}:${PATH}`; `mnml-zig test`
    // exports the directory as `$MNML_SHIMS`.
    build_options.addOption([]const u8, "shims_dir", b.pathFromRoot("tools/shims"));
    // `launchers/`: mnml's own launcher manifests. The unit test in
    // `src/app/launchers.zig` parses every file; `mnml-zig test` exports
    // the folder as `$MNML_LAUNCHERS` so a `.test` can point
    // `MNML_MARKETPLACE_LOCAL` at it.
    build_options.addOption([]const u8, "launchers_dir", b.pathFromRoot("launchers"));
    // `tests/e2e/`: the corpus itself, so a unit test can read the
    // scripts as text. `src/e2e/corpus.zig` walks every `.test` file and
    // fails the build on a fake server started at a port somebody chose
    // — the thing that stops two worktrees running the corpus at once.
    build_options.addOption([]const u8, "e2e_corpus_dir", b.pathFromRoot("tests/e2e"));
    // `lua/`: the curated script set, in this repo the way `integrations/`
    // and `launchers/` are. A dev build lists it in the SCRIPTS section's
    // Marketplace tab with no config at all, because the folder's
    // absolute path is baked in here; a packaged build finds the same set
    // as `share/mnml/lua` beside the binary instead
    // (`src/app/scripts.zig`'s `shippedRoot`, `nfpm/mnml.yaml`,
    // `scripts/package.sh`).
    build_options.addOption([]const u8, "scripts_dir", b.pathFromRoot("lua"));
    // `data/marketplace.zon`: the mnml catalogue — the Marketplace
    // tab's default source, the same way `lua/` is the SCRIPTS tab's.
    // A dev build reads the checkout's copy (its absolute path is baked
    // in here); a packaged build finds it as `share/mnml/marketplace.zon`
    // beside the binary (`src/app/marketplace_catalogue.zig`'s `find`,
    // `nfpm/mnml.yaml`, `scripts/package.sh`) — which is also the
    // install below.
    build_options.addOption([]const u8, "marketplace_catalogue", b.pathFromRoot("data/marketplace.zon"));
    tests_run.step.dependOn(&fake_dap_install.step);
    e2e_run.step.dependOn(&fake_dap_install.step);
    gate_in_test.step.dependOn(&fake_dap_install.step);
    corpus_run.step.dependOn(&fake_dap_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_dap_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_dap, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_dap_exe_name }).step);

    // `mnml-fake-lsp` (tools/fake_lsp/) is the deterministic language
    // server the `lsp_fake_*.test` scripts and `src/app/lsp.zig`'s
    // integration test drive, reached the same two ways as the adapter:
    // `build_options.fake_lsp_exe` and `$MNML_FAKE_LSP`.
    const fake_lsp_mod = b.createModule(.{ .root_source_file = b.path("tools/fake_lsp/main.zig"), .target = target, .optimize = optimize });
    const fake_lsp = b.addExecutable(.{ .name = "mnml-fake-lsp", .root_module = fake_lsp_mod });
    const fake_lsp_install = b.addInstallArtifact(fake_lsp, .{});
    b.getInstallStep().dependOn(&fake_lsp_install.step);
    const fake_lsp_exe_name = b.fmt("mnml-fake-lsp{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    build_options.addOption([]const u8, "fake_lsp_exe", b.getInstallPath(.bin, fake_lsp_exe_name));
    tests_run.step.dependOn(&fake_lsp_install.step);
    e2e_run.step.dependOn(&fake_lsp_install.step);
    gate_in_test.step.dependOn(&fake_lsp_install.step);
    corpus_run.step.dependOn(&fake_lsp_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_lsp_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_lsp, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_lsp_exe_name }).step);

    // `mnml-fake-copilot` (tools/fake_copilot/) is the deterministic
    // stand-in for GitHub Copilot's language server, reached the same
    // two ways: `build_options.fake_copilot_exe` and
    // `$MNML_FAKE_COPILOT`. The `copilot_*.test` scripts drive it, and
    // its `--log` is how they prove that a workspace which has not
    // opted in sends NOTHING.
    const fake_copilot_mod = b.createModule(.{ .root_source_file = b.path("tools/fake_copilot/main.zig"), .target = target, .optimize = optimize });
    const fake_copilot = b.addExecutable(.{ .name = "mnml-fake-copilot", .root_module = fake_copilot_mod });
    const fake_copilot_install = b.addInstallArtifact(fake_copilot, .{});
    b.getInstallStep().dependOn(&fake_copilot_install.step);
    const fake_copilot_exe_name = b.fmt("mnml-fake-copilot{s}", .{if (target.result.os.tag == .windows) ".exe" else ""});
    build_options.addOption([]const u8, "fake_copilot_exe", b.getInstallPath(.bin, fake_copilot_exe_name));
    tests_run.step.dependOn(&fake_copilot_install.step);
    e2e_run.step.dependOn(&fake_copilot_install.step);
    gate_in_test.step.dependOn(&fake_copilot_install.step);
    corpus_run.step.dependOn(&fake_copilot_install.step);
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_copilot_mod, .filters = test_filters, .test_runner = test_runner })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_copilot, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_copilot_exe_name }).step);
    // ── end sdk ──

}

/// The shipped targets, Zig query on the left, the Rust triple the asset
/// names carry on the right. Windows is `-gnu`: ghostty marks msvc "doesn't
/// work yet", mingw-w64 is bundled with Zig, and an msvc cross build would
/// need a Windows SDK on the Linux runner (E6).
const ReleaseTarget = struct { zig: []const u8, rust: []const u8 };
const release_targets = [_]ReleaseTarget{
    .{ .zig = "aarch64-macos", .rust = "aarch64-apple-darwin" },
    .{ .zig = "x86_64-macos", .rust = "x86_64-apple-darwin" },
    .{ .zig = "x86_64-linux-gnu", .rust = "x86_64-unknown-linux-gnu" },
    .{ .zig = "aarch64-linux-gnu", .rust = "aarch64-unknown-linux-gnu" },
    .{ .zig = "x86_64-windows-gnu", .rust = "x86_64-pc-windows-gnu" },
};

/// The Rust triple for a resolved target: one of the five above, or Zig's own
/// triple for anything else (a `-Dtarget=x86_64-linux-musl` still installs
/// somewhere sensible; it just is not a shipped name).
fn rustTriple(b: *std.Build, t: std.Target) []const u8 {
    const fallback = t.zigTriple(b.allocator) catch @panic("OOM");
    const arch: []const u8 = switch (t.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return fallback,
    };
    return switch (t.os.tag) {
        .macos => b.fmt("{s}-apple-darwin", .{arch}),
        .linux => if (t.abi == .gnu) b.fmt("{s}-unknown-linux-gnu", .{arch}) else fallback,
        .windows => if (t.cpu.arch == .x86_64 and t.abi == .gnu) "x86_64-pc-windows-gnu" else fallback,
        else => fallback,
    };
}

/// `<zon version>+g<short sha>[-dirty]` — what a build without `-Dversion=`
/// prints. The zon file is read as text (a dev build should not fail because
/// the manifest grew a field); git is optional (a tarball checkout has none).
fn deriveVersion(b: *std.Build) []const u8 {
    const zon = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 20)) catch @panic("build.zig.zon unreadable");
    const key = ".version = \"";
    const start = (std.mem.indexOf(u8, zon, key) orelse @panic("build.zig.zon has no .version")) + key.len;
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"') orelse @panic("build.zig.zon .version is unterminated");
    const base = zon[start..end];

    var code: u8 = undefined;
    const sha_raw = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return base;
    const sha = std.mem.trim(u8, sha_raw, " \t\r\n");
    if (sha.len == 0) return base;
    const status = b.runAllowFail(&.{ "git", "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch "";
    const dirty = std.mem.trim(u8, status, " \t\r\n").len != 0;
    return b.fmt("{s}+g{s}{s}", .{ base, sha, if (dirty) "-dirty" else "" });
}

// ── lua ────────────────────────────────────────────────────────────────────

/// The `lang` option zlua's `src/lib.zig` switches on. Same field set as
/// zlua's `build.zig` `Language` so every prong in the lib resolves.
const LuaLanguage = enum { lua51, lua52, lua53, lua54, lua55, luajit, luau };

const lua54_sources = [_][]const u8{
    "src/lapi.c",     "src/lcode.c",    "src/lctype.c",  "src/ldebug.c",   "src/ldo.c",      "src/ldump.c",
    "src/lfunc.c",    "src/lgc.c",      "src/llex.c",    "src/lmem.c",     "src/lobject.c",  "src/lopcodes.c",
    "src/lparser.c",  "src/lstate.c",   "src/lstring.c", "src/ltable.c",   "src/ltm.c",      "src/lundump.c",
    "src/lvm.c",      "src/lzio.c",     "src/lauxlib.c", "src/lbaselib.c", "src/lcorolib.c", "src/ldblib.c",
    "src/liolib.c",   "src/lmathlib.c", "src/loadlib.c", "src/loslib.c",   "src/lstrlib.c",  "src/ltablib.c",
    "src/lutf8lib.c", "src/linit.c",
};

fn addLua(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const lua_root: std.Build.LazyPath = .{ .cwd_relative = packageRoot(b, "lua54") };
    const zlua_root: std.Build.LazyPath = b.path("vendor/zlua");

    // The interpreter, one static lib. `LUA_USE_APICHECK` in Debug turns
    // a misuse of the C API into an assertion instead of a heap scribble.
    const lib = b.addLibrary(.{
        .name = "lua",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    const os_flag: []const u8 = switch (target.result.os.tag) {
        .linux => "-DLUA_USE_LINUX",
        .macos => "-DLUA_USE_MACOSX",
        .windows => "-DLUA_USE_WINDOWS",
        else => "-DLUA_USE_POSIX",
    };
    const apicheck: []const u8 = if (optimize == .Debug) "-DLUA_USE_APICHECK" else "-DLUA_COMPAT_MATHLIB=0";
    lib.root_module.addCSourceFiles(.{
        .root = lua_root,
        .files = &lua54_sources,
        .flags = &.{ "-std=gnu99", os_flag, apicheck },
    });
    lib.root_module.addIncludePath(lua_root.path(b, "src"));

    // The headers as Zig: zlua's `lua_all.h` includes lua/lualib/lauxlib.
    const tc = b.addTranslateC(.{
        .root_source_file = zlua_root.path(b, "include/lua_all.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.addIncludePath(lua_root.path(b, "src"));
    const c_mod = tc.createModule();
    c_mod.linkLibrary(lib);

    const config = b.addOptions();
    config.addOption(LuaLanguage, "lang", .lua54);
    config.addOption(bool, "luau_use_4_vector", false);

    const zlua = b.createModule(.{
        .root_source_file = zlua_root.path(b, "src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zlua.addImport("c", c_mod);
    zlua.addOptions("config", config);
    zlua.linkLibrary(lib);
    return zlua;
}

// ── tree-sitter ──────────────────────────────────────────────────────────────
//
// Two static libs: the upstream runtime (one amalgamated `lib.c`) and every grammar's
// `parser.c` + `scanner.c` compiled straight from the crates.io tarballs pinned in
// `build.zig.zon`. Both are linked on the `tree_sitter` module so anything that
// imports it links them transitively. The grammars' `queries/*.scm` are copied to a
// stable `<lang>/<kind>.scm` layout and exposed through a generated `ts_queries`
// module that `@embedFile`s each one.

/// One grammar build. `name` is the language id used for the query directory and the
/// generated `ts_queries` identifiers (`<name>_<query>`); the C entry point is declared
/// in `src/highlight/table.zig`.
const Grammar = struct {
    name: []const u8,
    /// `build.zig.zon` dependency key.
    dep: []const u8,
    /// Directory holding `parser.c` (and `scanner.c`), relative to the dependency root.
    src: []const u8 = "src",
    scanner: bool = false,
    /// The scanner reaches `tree_sitter/parser.h` through a header outside `src/` (the
    /// shared `common/scanner.h` of typescript / php / ocaml) or with angle brackets
    /// (nix), so its own `src/` goes on that file's include path. Per file, not
    /// module-wide: every grammar ships its own generated `parser.h` and they differ.
    include_src: bool = false,
    /// Directory holding the `.scm` files, relative to the dependency root. Null when
    /// another entry (or a repo-local file) supplies this language's queries.
    query_dir: ?[]const u8 = "queries",
    /// Which `.scm` files to embed from `query_dir` (without the extension).
    queries: []const []const u8 = &.{"highlights"},
};

const grammars = [_]Grammar{
    .{ .name = "rust", .dep = "ts_rust", .scanner = true, .queries = &.{ "highlights", "injections" } },
    .{ .name = "javascript", .dep = "ts_javascript", .scanner = true, .queries = &.{ "highlights", "highlights-jsx", "injections" } },
    .{ .name = "typescript", .dep = "ts_typescript", .src = "typescript/src", .scanner = true, .include_src = true },
    .{ .name = "tsx", .dep = "ts_typescript", .src = "tsx/src", .scanner = true, .include_src = true, .query_dir = null },
    .{ .name = "python", .dep = "ts_python", .scanner = true },
    .{ .name = "json", .dep = "ts_json" },
    .{ .name = "go", .dep = "ts_go" },
    .{ .name = "toml", .dep = "ts_toml_ng", .scanner = true },
    // Markdown is two grammars: block structure, and the inline grammar injected into it.
    .{ .name = "markdown", .dep = "ts_md", .src = "tree-sitter-markdown/src", .scanner = true, .query_dir = "tree-sitter-markdown/queries", .queries = &.{ "highlights", "injections" } },
    .{ .name = "markdown_inline", .dep = "ts_md", .src = "tree-sitter-markdown-inline/src", .scanner = true, .query_dir = "tree-sitter-markdown-inline/queries", .queries = &.{ "highlights", "injections" } },
    .{ .name = "c", .dep = "ts_c" },
    .{ .name = "bash", .dep = "ts_bash", .scanner = true },
    .{ .name = "css", .dep = "ts_css", .scanner = true },
    .{ .name = "html", .dep = "ts_html", .scanner = true, .queries = &.{ "highlights", "injections" } },
    .{ .name = "cpp", .dep = "ts_cpp", .scanner = true },
    .{ .name = "ruby", .dep = "ts_ruby", .scanner = true },
    .{ .name = "java", .dep = "ts_java" },
    .{ .name = "yaml", .dep = "ts_yaml", .scanner = true },
    .{ .name = "c_sharp", .dep = "ts_c_sharp", .scanner = true },
    .{ .name = "lua", .dep = "ts_lua", .scanner = true },
    .{ .name = "scala", .dep = "ts_scala", .scanner = true },
    .{ .name = "elixir", .dep = "ts_elixir", .scanner = true, .queries = &.{ "highlights", "injections" } },
    // Its highlights query is shipped corrected from src/highlight/queries/ (see the file).
    .{ .name = "haskell", .dep = "ts_haskell", .scanner = true, .queries = &.{"injections"} },
    // php/ is the HTML-embedding grammar mnml uses; the crate's php_only/ is not built.
    .{ .name = "php", .dep = "ts_php", .src = "php/src", .scanner = true, .include_src = true, .queries = &.{ "highlights", "injections" } },
    .{ .name = "make", .dep = "ts_make" },
    .{ .name = "swift", .dep = "ts_swift", .scanner = true, .queries = &.{ "highlights", "injections" } },
    .{ .name = "zig", .dep = "ts_zig", .queries = &.{ "highlights", "injections" } },
    .{ .name = "nix", .dep = "ts_nix", .scanner = true, .include_src = true, .queries = &.{ "highlights", "injections" } },
    // ocaml and its .mli interface grammar share one highlights.scm at the crate root.
    .{ .name = "ocaml", .dep = "ts_ocaml", .src = "grammars/ocaml/src", .scanner = true, .include_src = true },
    .{ .name = "ocaml_interface", .dep = "ts_ocaml", .src = "grammars/interface/src", .scanner = true, .include_src = true, .query_dir = null },
    .{ .name = "dart", .dep = "ts_dart", .scanner = true },
    .{ .name = "sql", .dep = "ts_sequel", .scanner = true },
    .{ .name = "kotlin", .dep = "ts_kotlin_sg", .scanner = true },
    .{ .name = "regex", .dep = "ts_regex" },
    .{ .name = "containerfile", .dep = "ts_containerfile", .scanner = true, .queries = &.{ "highlights", "injections" } },
    // hcl ships no queries; proto ships one we replace; vue's live under queries/vue/ and
    // its build script never exposed them. All three come from src/highlight/queries/.
    .{ .name = "hcl", .dep = "ts_hcl", .scanner = true, .query_dir = null },
    .{ .name = "proto", .dep = "ts_proto", .query_dir = null },
    .{ .name = "diff", .dep = "ts_diff" },
    .{ .name = "vue", .dep = "ts_vue_next", .scanner = true, .query_dir = null },
    .{ .name = "svelte", .dep = "ts_svelte_ng", .scanner = true, .queries = &.{ "highlights", "injections" } },
    .{ .name = "astro", .dep = "ts_astro_next", .scanner = true, .queries = &.{ "highlights", "injections" } },
};

/// Queries mnml ships itself (`src/highlight/queries/`), for grammars whose crate has
/// none (hcl), has one we deliberately replace (proto), or hides them behind a build
/// script that never fires (vue).
const LocalQuery = struct {
    /// Destination inside the generated query tree, `<lang>/<kind>.scm`.
    out: []const u8,
    /// Source path in this repo.
    src: []const u8,
};

const local_queries = [_]LocalQuery{
    .{ .out = "haskell/highlights.scm", .src = "src/highlight/queries/haskell.scm" },
    // The crate's JavaScript query paints no decorator; this one, listed
    // after it for js / jsx / ts / tsx, does.
    .{ .out = "javascript/highlights-extra.scm", .src = "src/highlight/queries/javascript.extra.scm" },
    .{ .out = "hcl/highlights.scm", .src = "src/highlight/queries/hcl.scm" },
    .{ .out = "proto/highlights.scm", .src = "src/highlight/queries/proto.scm" },
    .{ .out = "vue/highlights.scm", .src = "src/highlight/queries/vue.scm" },
    .{ .out = "vue/injections.scm", .src = "src/highlight/queries/vue.injections.scm" },
};

// Grammar lexers and the runtime are C that Zig would otherwise build with
// UBSan in trap mode (Debug and ReleaseSafe alike). Optimized grammar code
// trips it — four parse tests died with SIGTRAP under ReleaseSafe — so the
// sanitizer is off for these units, as ghostty does for its vendored C.
const c_flags = [_][]const u8{ "-std=c11", "-fno-sanitize=undefined", "-fno-sanitize-trap=undefined" };

const TreeSitter = struct {
    /// `@import("tree_sitter")` — the runtime bindings, with both static libs linked.
    runtime: *std.Build.Module,
    /// `@import("ts_queries")` — every embedded `.scm`.
    queries: *std.Build.Module,
    /// `@import("highlight")` — the language table.
    highlight: *std.Build.Module,
};

fn addTreeSitter(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) TreeSitter {
    // Runtime.
    const ts_root: std.Build.LazyPath = b.path("vendor/tree-sitter");
    const runtime_lib = b.addLibrary(.{
        .name = "tree-sitter",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    runtime_lib.root_module.addCSourceFile(.{ .file = ts_root.path(b, "lib/src/lib.c"), .flags = &c_flags });
    runtime_lib.root_module.addIncludePath(ts_root.path(b, "lib/include"));
    runtime_lib.root_module.addIncludePath(ts_root.path(b, "lib/src"));
    runtime_lib.root_module.addCMacro("_POSIX_C_SOURCE", "200112L");
    runtime_lib.root_module.addCMacro("_DEFAULT_SOURCE", "");
    runtime_lib.root_module.addCMacro("_BSD_SOURCE", "");
    runtime_lib.root_module.addCMacro("_DARWIN_C_SOURCE", "");

    // Grammars + queries.
    const grammars_lib = b.addLibrary(.{
        .name = "ts-grammars",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const wf = b.addWriteFiles();
    var root_zig: std.Io.Writer.Allocating = .init(b.allocator);
    root_zig.writer.writeAll("//! Generated by build.zig — every tree-sitter query mnml-zig embeds.\n\n") catch @panic("OOM");

    for (grammars) |g| {
        const root = packageRoot(b, g.dep);
        const dep: std.Build.LazyPath = .{ .cwd_relative = root };
        const src = dep.path(b, g.src);
        grammars_lib.root_module.addCSourceFile(.{ .file = src.path(b, "parser.c"), .flags = &c_flags });
        if (g.scanner) {
            const flags: []const []const u8 = if (g.include_src)
                &.{ "-std=c11", b.fmt("-I{s}/{s}", .{ root, g.src }) }
            else
                &c_flags;
            grammars_lib.root_module.addCSourceFile(.{ .file = src.path(b, "scanner.c"), .flags = flags });
        }

        const query_dir = g.query_dir orelse continue;
        for (g.queries) |q| {
            const out = b.fmt("{s}/{s}.scm", .{ g.name, q });
            _ = wf.addCopyFile(dep.path(b, b.fmt("{s}/{s}.scm", .{ query_dir, q })), out);
            emitQueryDecl(&root_zig.writer, out);
        }
    }
    for (local_queries) |lq| {
        _ = wf.addCopyFile(b.path(lq.src), lq.out);
        emitQueryDecl(&root_zig.writer, lq.out);
    }

    const queries = b.createModule(.{
        .root_source_file = wf.add("root.zig", root_zig.written()),
        .target = target,
        .optimize = optimize,
    });

    const runtime = b.createModule(.{
        .root_source_file = b.path("src/tree_sitter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime.linkLibrary(runtime_lib);
    runtime.linkLibrary(grammars_lib);

    const highlight = b.createModule(.{
        .root_source_file = b.path("src/highlight/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = runtime },
            .{ .name = "ts_queries", .module = queries },
        },
    });

    return .{ .runtime = runtime, .queries = queries, .highlight = highlight };
}

/// The root of a `build.zig.zon` dependency *without* running its `build.zig`.
///
/// tree-sitter 0.26.8 ships a `build.zig` written for Zig ≤ 0.15 (`Compile.addCSourceFile`)
/// that fails analysis — and `b.dependency()` instantiates every package's build script,
/// so a single call anywhere would drag it in. The grammar crates have no `build.zig` at
/// all. We only want C sources and `.scm` files, so resolve the package root from the
/// build runner's dependency table the way `std.Build` itself does.
fn packageRoot(b: *std.Build, name: []const u8) []const u8 {
    const deps = @import("root").dependencies;
    const hash = for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], name)) break dep[1];
    } else std.debug.panic("no dependency named '{s}' in build.zig.zon", .{name});
    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        const pkg = @field(deps.packages, decl.name);
        if (@hasDecl(pkg, "build_root") and std.mem.eql(u8, decl.name, hash)) {
            return pkg.build_root;
        }
    }
    std.debug.panic("dependency '{s}' ({s}) is not fetched", .{ name, hash });
}

/// `rust/highlights.scm` → `pub const rust_highlights = @embedFile("rust/highlights.scm");`
fn emitQueryDecl(w: *std.Io.Writer, out: []const u8) void {
    w.writeAll("pub const ") catch @panic("OOM");
    const stem = out[0 .. out.len - ".scm".len];
    for (stem) |c| {
        const ident: u8 = switch (c) {
            '/', '-', '.' => '_',
            else => c,
        };
        w.writeByte(ident) catch @panic("OOM");
    }
    w.print(": []const u8 = @embedFile(\"{s}\");\n", .{out}) catch @panic("OOM");
}
