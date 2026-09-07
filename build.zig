const std = @import("std");

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

    // ── command table: -Dpartial ──
    // Downgrades "command id has no runner" from a compile error to a
    // runtime toast. The spike ships with it ON because only the todos
    // runners exist; parity flips it OFF so a missing runner fails the
    // build (D5).
    const partial = b.option(bool, "partial", "Allow command ids without runners (spike builds)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "partial", partial);

    // ── e2e: IPC namespacing ──
    // Where the file-IPC channel lives under `<ws>/.mnml/`. Rust mnml owns
    // `ipc`; dev builds of the Zig host use `ipc-zig` so both can run on
    // one workspace until cutover, when the default flips back.
    const ipc_subdir = b.option([]const u8, "ipc-subdir", "IPC directory name under <ws>/.mnml/ (default: ipc-zig)") orelse "ipc-zig";
    build_options.addOption([]const u8, "ipc_subdir", ipc_subdir);

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
    // `-Dtest-filter=<substring>` runs the matching tests only — what
    // `tools/break-check.sh` uses to run one test against a broken copy.
    const test_filter = b.option([]const u8, "test-filter", "Run only the unit tests whose name contains this");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);
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
    test_step.dependOn(&b.addRunArtifact(tui_tests).step);
    const pty_tests = b.addTest(.{ .root_module = pty_mod, .filters = test_filters });
    const pty_test_run = b.addRunArtifact(pty_tests);
    const pty_test_step = b.step("pty-test", "Run the pty module tests");
    pty_test_step.dependOn(&pty_test_run.step);
    test_step.dependOn(&pty_test_run.step);
    const demos_supported = target.result.os.tag != .windows;

    const ts_tests = b.addTest(.{ .name = "tree-sitter-tests", .root_module = ts.runtime, .filters = test_filters });
    const highlight_tests = b.addTest(.{ .name = "highlight-tests", .root_module = ts.highlight, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(ts_tests).step);
    test_step.dependOn(&b.addRunArtifact(highlight_tests).step);

    // ── docs + check (cutover prep) ─────────────────────────────────────
    // `zig build docs` regenerates docs/commands.md from the comptime spec
    // table (E8). `zig build check` is the CI gate (E7): fmt, the unit
    // tests in Debug and ReleaseSafe, the Phase-0 e2e gate, the same gate
    // swept at 80x24 / 120x40 / 200x60, and defaults.test.
    const specs_mod = b.createModule(.{ .root_source_file = b.path("src/commands/specs.zig"), .target = target, .optimize = optimize });
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "specs", .module = specs_mod }},
    });
    const gen = b.addExecutable(.{ .name = "gen-commands", .root_module = gen_mod });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addArg(b.pathFromRoot("docs/commands.md"));
    gen_run.has_side_effects = true;
    const docs_step = b.step("docs", "Regenerate docs/commands.md from the command spec table");
    docs_step.dependOn(&gen_run.step);
    const gen_tests = b.addTest(.{ .root_module = gen_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);

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
    // src/ under `zig build test` and assert the same.
    const glyph_opts = b.addOptions();
    glyph_opts.addOptionPath("src_root", b.path("src"));
    glyph_opts.addOptionPath("glyph_json", b.path("data/nerd-glyphnames.json"));
    const glyph_mod = b.createModule(.{ .root_source_file = b.path("tools/glyph_audit.zig"), .target = target, .optimize = optimize });
    glyph_mod.addOptions("build_options", glyph_opts);
    // The app runs the same audit in-process (`integrations.audit_glyphs`,
    // `menu.glyph_audit`, the `bake_*` ids — `src/app/glyph_audit.zig`).
    root_module.addImport("glyph_audit", glyph_mod);
    // ── the UI spec ─────────────────────────────────────────────────────
    // The Rust editor's screen dumps (`docs/ui-spec/`), embedded so the
    // statusline tests compare the painted row with the spec's row.
    root_module.addAnonymousImport("ui_spec_rust_120x40", .{ .root_source_file = b.path("docs/ui-spec/rust-120x40.txt") });
    root_module.addAnonymousImport("ui_spec_rust_80x24", .{ .root_source_file = b.path("docs/ui-spec/rust-80x24.txt") });
    const glyph_exe = b.addExecutable(.{ .name = "glyph-audit", .root_module = glyph_mod });
    const glyph_bake = b.addRunArtifact(glyph_exe);
    glyph_bake.addArg("bake");
    glyph_bake.addFileArg(b.path("data/nerd-glyphnames.json"));
    const glyph_table = glyph_bake.addOutputFileArg("nerd-glyphs.tsv");
    const glyph_audit = b.addRunArtifact(glyph_exe);
    glyph_audit.addArg("audit");
    glyph_audit.addFileArg(glyph_table);
    glyph_audit.addDirectoryArg(b.path("src"));
    glyph_audit.addArg("--strict");
    glyph_audit.has_side_effects = true;
    glyph_audit.stdio = .inherit;
    const glyph_step = b.step("glyph-audit", "Every Nerd Font glyph literal in src/ against data/nerd-glyphnames.json, with its --ascii twin");
    glyph_step.dependOn(&glyph_audit.step);
    const glyph_tests = b.addTest(.{ .root_module = glyph_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(glyph_tests).step);
    // ── end glyph audit ─────────────────────────────────────────────────

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
            b.fmt("-Dipc-subdir={s}", .{ipc_subdir}),
            b.fmt("-Dpartial={}", .{partial}),
            b.fmt("-Dpty-simd={}", .{pty_simd}),
            "--prefix",
            b.install_path,
            "--cache-dir",
            b.cache_root.path orelse ".zig-cache",
            "--global-cache-dir",
            b.graph.global_cache_root.path orelse ".",
        });
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
    // under `zig build test` through `src/bridge/wire.zig`'s test block.
    // `mnml-hello` is the sample integration: `zig build sdk-example`
    // installs it, and the host's integration test spawns it through a
    // real mount socket (the path travels as a build option).
    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/mnml-sdk/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("mnml_sdk", sdk_mod);
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
    tests_run.step.dependOn(&fake_dap_install.step);
    e2e_run.step.dependOn(&fake_dap_install.step);
    gate_in_test.step.dependOn(&fake_dap_install.step);
    corpus_run.step.dependOn(&fake_dap_install.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_dap_mod, .filters = test_filters })).step);
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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_lsp_mod, .filters = test_filters })).step);
    gate_step.dependOn(&b.addInstallArtifact(fake_lsp, .{ .dest_dir = .{ .override = gate_dir }, .dest_sub_path = fake_lsp_exe_name }).step);
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
    .{ .name = "haskell", .dep = "ts_haskell", .scanner = true, .queries = &.{ "highlights", "injections" } },
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
