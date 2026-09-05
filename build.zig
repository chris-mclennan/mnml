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
    // extern (see src/pty/session.zig).
    const pty_mod = b.addModule("pty", .{
        .root_source_file = b.path("src/pty/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pty_mod.addImport("ghostty-vt", ghostty_vt);

    // ── syntax: tree-sitter ──
    const ts = addTreeSitter(b, target, optimize);

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
        },
    });
    root_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{ .name = "mnml-zig", .root_module = root_module });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mnml-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── tests ──
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // src/ui is reached through its barrel (`src/ui/ui.zig`) from main.zig's
    // `test {}` block, so every component's tests run under `zig build test`
    // on std.testing.allocator (leak = failure). It is not its own test
    // module: the components import `src/core/{ids,panel,key}.zig`, which
    // a module rooted at `src/ui/` cannot reach.

    // ── tui tests ──
    // src/tui through its barrel: the input worker's key naming and parser
    // tests, and term.zig's capability detection. libc for the same reason
    // as the main executable (Io.Threaded cancelation of blocked reads).
    // The pty module and the terminal session are POSIX (openpty / fork /
    // poll / termios / a SIGWINCH self-pipe) until ConPTY lands in Phase 8,
    // so their tests and demos are only part of the graph on non-Windows
    // targets; the exe still links both modules everywhere and gates the
    // interactive loop at runtime.
    const pty_supported = target.result.os.tag != .windows;
    const tui_tests: ?*std.Build.Step.Compile = if (pty_supported) b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/tui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    }) else null;
    if (tui_tests) |t| test_step.dependOn(&b.addRunArtifact(t).step);
    const pty_tests: ?*std.Build.Step.Compile = if (pty_supported) b.addTest(.{ .root_module = pty_mod }) else null;
    if (pty_tests) |t| {
        const pty_test_run = b.addRunArtifact(t);
        const pty_test_step = b.step("pty-test", "Run the pty module tests");
        pty_test_step.dependOn(&pty_test_run.step);
        test_step.dependOn(&pty_test_run.step);
    }

    const ts_tests = b.addTest(.{ .name = "tree-sitter-tests", .root_module = ts.runtime });
    const highlight_tests = b.addTest(.{ .name = "highlight-tests", .root_module = ts.highlight });
    test_step.dependOn(&b.addRunArtifact(ts_tests).step);
    test_step.dependOn(&b.addRunArtifact(highlight_tests).step);

    // ── e2e: gate-build ──
    // Compile the exe and every test binary for the selected target without
    // running them, installed under zig-out/gate/. The exe alone is not a
    // cross-compile gate for the foreign code — nothing in main references
    // the grammars yet — but the test binaries link all 43 of them, so
    // `zig build gate-build -Dtarget=…` is what proves a target builds.
    const gate_step = b.step("gate-build", "Compile the exe and all test binaries without running (cross-target gate)");
    const gate_dir: std.Build.InstallDir = .{ .custom = "gate" };
    const GateBin = struct { compile: ?*std.Build.Step.Compile, name: []const u8 };
    for ([_]GateBin{
        .{ .compile = exe, .name = "mnml-zig" },
        .{ .compile = tests, .name = "test-main" },
        .{ .compile = pty_tests, .name = "test-pty" },
        .{ .compile = ts_tests, .name = "test-tree-sitter" },
        .{ .compile = highlight_tests, .name = "test-highlight" },
    }) |g| {
        const compile = g.compile orelse continue;
        const suffix = if (target.result.os.tag == .windows) ".exe" else "";
        gate_step.dependOn(&b.addInstallArtifact(compile, .{
            .dest_dir = .{ .override = gate_dir },
            .dest_sub_path = b.fmt("{s}{s}", .{ g.name, suffix }),
        }).step);
    }

    // ── pty-demo ──
    // The spike's proving ground: a login shell in a ghostty-vt Terminal,
    // painted with plain ANSI. Throwaway once vaxis hosts the pane.
    if (pty_tests) |t| {
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
        pty_step.dependOn(&t.step);
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
    if (pty_supported) b.getInstallStep().dependOn(&canvas_demo_install.step);
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
