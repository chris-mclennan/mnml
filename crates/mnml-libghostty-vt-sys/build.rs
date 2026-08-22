//! Build script for `mnml-libghostty-vt-sys`.
//!
//! Two responsibilities:
//! 1. Locate a `libghostty-vt.a` and tell cargo how to link it.
//! 2. Generate Rust bindings via bindgen against the vendored `vt.h`.
//!
//! # Link paths
//!
//! Two features gate WHERE the `.a` comes from. Both are default so the
//! build "just works" on every host:
//!
//! - **`source-build`** — git-clone ghostty at [`GHOSTTY_COMMIT`] into
//!   `OUT_DIR` and run `zig build`. Requires zig 0.16.0 + git on PATH.
//!   This is the live default on every target as of 2026-08-02 —
//!   there's no vendored `.pc` or `.a` checked in.
//! - **`pkg-config`** — resolve `libghostty-vt-static` via
//!   `PKG_CONFIG_PATH`. Present so a future prebuilt setup can plug in
//!   without changing the crate; currently a no-op since no `.pc` ships
//!   in the tree. Downstream callers who bring their own prebuilt can
//!   still opt in.
//!
//! When both features are on, pkg-config is tried first; if it can't
//! find a `.pc`, source-build kicks in and emits a `cargo:warning=` so
//! unintentional slow builds are visible.
//!
//! # Bindings
//!
//! Bindings are always generated against the vendored headers under
//! `vendor/libghostty-vt/include/ghostty/`. That header set matches the
//! ABI of the prebuilt `.a` files under `vendor/libghostty-vt/lib-*`.
//! When we bump [`GHOSTTY_COMMIT`], the vendored headers get re-vendored
//! from the same commit so bindgen + link ABI stay in lock-step.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The upstream ghostty commit our source-build path checks out. Also
/// the commit the vendored headers under `vendor/libghostty-vt/include/`
/// come from — bindgen and link ABI must match.
const GHOSTTY_REPO: &str = "https://github.com/ghostty-org/ghostty.git";
// 2026-08-02 bumped from `a887df42` (0.2.1) to origin/main HEAD after
// research turned up specific upstream Windows fixes that landed between
// July 26 and Aug 2 2026:
//
//   24f7fb983  build: fix static libghostty-vt linking on Windows (#13452)
//              — the direct linking fix, discovered via Neovim's zig build
//   84254a9d8  build: avoid MSVC C++ runtime in no-libcxx builds
//   1fe1b2d23  build: fix static libghostty-vt linking on Windows
//   a062c16e1  libghostty: pass pointer options directly to terminal_set
//              — same bug our code-reviewer caught in mnml-vt; upstream
//                also had a mirrored version that ghostty had to fix
//                on their side
//   7114721bd  build: fix C++ linking and enum signedness on MSVC
//
// Plus the full March 2026 MSVC compatibility sweep. Our previous pin
// predated all of these — Windows CI reproduced the STATUS_ACCESS_VIOLATION
// exactly, on the SAME test, with the exact same `mnml-<hash>.exe` binary
// hash both times, meaning nothing in the 14-commit `fdbf9ff → a887df42`
// delta touched the crash path.
//
// Re-sync vendored headers under `vendor/libghostty-vt/include/` when
// bumping this constant (see vendor README's "Regenerating headers"
// section).
const GHOSTTY_COMMIT: &str = "6837d7027f226355db661e8215a3ad24ffaf4eb5";

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // Workspace root is two levels up: crates/mnml-libghostty-vt-sys/ → workspace root.
    let workspace_root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root two levels above crate manifest");
    let vendor_include = workspace_root.join("vendor/libghostty-vt/include");
    let vt_h = vendor_include.join("ghostty/vt.h");

    if !vt_h.exists() {
        panic!(
            "vendored vt.h not found at {}. Re-vendor the ghostty headers \
             matching GHOSTTY_COMMIT (see vendor/libghostty-vt/README.md).",
            vt_h.display()
        );
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", vt_h.display());
    println!(
        "cargo:rerun-if-changed={}",
        vendor_include.join("ghostty/vt").display()
    );
    println!("cargo:rerun-if-env-changed=GHOSTTY_SOURCE_DIR");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");

    // ---- 1. Locate / link the `.a` ---------------------------------------
    link_ghostty_vt();

    // ---- 2. Generate bindings --------------------------------------------
    generate_bindings(&vt_h, &vendor_include);
}

/// Try each configured link path in order and emit `rustc-link-*` metadata
/// once one succeeds.
fn link_ghostty_vt() {
    // Local dev override — an explicit ghostty checkout always wins.
    if env::var_os("GHOSTTY_SOURCE_DIR").is_some() {
        #[cfg(feature = "source-build")]
        {
            source_build();
            return;
        }
        #[cfg(not(feature = "source-build"))]
        panic!(
            "GHOSTTY_SOURCE_DIR is set but the `source-build` feature is disabled. \
             Either drop the env var or enable the feature."
        );
    }

    #[cfg(feature = "pkg-config")]
    {
        if try_pkg_config() {
            return;
        }
    }

    #[cfg(feature = "source-build")]
    {
        println!(
            "cargo:warning=libghostty-vt: pkg-config unavailable, falling back to zig source-build \
             (needs zig 0.16.0 + git on PATH)"
        );
        source_build();
    }

    #[cfg(not(feature = "source-build"))]
    panic!(
        "libghostty-vt: no link path succeeded. Enable `source-build` or set PKG_CONFIG_PATH to \
         point at a `libghostty-vt.pc` — see workspace `.cargo/config.toml`."
    );
}

#[cfg(feature = "pkg-config")]
fn try_pkg_config() -> bool {
    let lib = match pkg_config::Config::new()
        .statik(true)
        .cargo_metadata(false)
        .probe("libghostty-vt-static")
        .or_else(|_| {
            pkg_config::Config::new()
                .statik(true)
                .cargo_metadata(false)
                .probe("libghostty-vt")
        }) {
        Ok(l) => l,
        Err(_) => return false,
    };

    for path in &lib.link_paths {
        println!("cargo:rustc-link-search=native={}", path.display());
    }
    // Our vendored `.pc` uses `Libs: ${libdir}/libghostty-vt.a` (direct
    // path, not `-L… -l…`) so pkg-config populates `link_files` — take
    // the parent as an extra search dir.
    for file in &lib.link_files {
        if let Some(parent) = file.parent() {
            println!("cargo:rustc-link-search=native={}", parent.display());
        }
    }
    println!("cargo:rustc-link-lib=static=ghostty-vt");
    for l in &lib.libs {
        if l != "ghostty-vt" {
            println!("cargo:rustc-link-lib={l}");
        }
    }
    emit_platform_link_libs();
    true
}

/// git-clone ghostty at [`GHOSTTY_COMMIT`] into OUT_DIR and run
/// `zig build -Demit-lib-vt`, then link the resulting `.a`.
#[cfg(feature = "source-build")]
fn source_build() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR set by cargo"));
    let target = env::var("TARGET").expect("TARGET set by cargo");
    let host = env::var("HOST").expect("HOST set by cargo");

    // Where's the ghostty source? Env override wins; otherwise clone.
    let ghostty_dir = match env::var("GHOSTTY_SOURCE_DIR") {
        Ok(dir) => {
            // Env override — user supplied their own checkout, we just need
            // zig itself. Don't require git.
            require_tool_or_die("zig", ZIG_MISSING_HELP);
            let p = PathBuf::from(dir);
            assert!(
                p.join("build.zig").exists(),
                "GHOSTTY_SOURCE_DIR does not contain build.zig: {}",
                p.display()
            );
            p
        }
        Err(_) => {
            // Default path — need both git (to clone ghostty) and zig
            // (to build it). Check both up front so cargo install prints
            // one clear error instead of a raw "No such file or directory".
            require_tool_or_die("zig", ZIG_MISSING_HELP);
            require_tool_or_die("git", GIT_MISSING_HELP);
            fetch_ghostty(&out_dir)
        }
    };

    let install_prefix = out_dir.join("ghostty-install");
    let zig_cache_dir = out_dir.join("zig-cache");
    let optimize = zig_optimize_mode();

    let mut build = Command::new("zig");
    build
        .arg("build")
        .arg("-Demit-lib-vt")
        .arg(format!("-Doptimize={optimize}"))
        .arg("-Demit-xcframework=false")
        .arg("-Dapp-runtime=none")
        .arg("--prefix")
        .arg(&install_prefix)
        .arg("--cache-dir")
        .arg(&zig_cache_dir)
        .current_dir(&ghostty_dir);

    // Pass zig an explicit `-Dtarget` only on genuine cross-compiles.
    // For same-target-as-host, let zig auto-detect — matches what
    // upstream ghostty does in its own CI (build-libghostty-vt-windows
    // in test.yml runs `zig build -Demit-lib-vt` with no -Dtarget).
    //
    // 2026-08-02: earlier code added `|| target.contains("windows-msvc")`
    // to force MSVC ABI on the Windows runner. That was based on the
    // hypothesis that zig defaults to gnu on Windows hosts, causing an
    // ABI mismatch with Rust's default msvc. Turned out upstream ghostty
    // explicitly marks `x86_64-windows-msvc` as "doesn't work yet, we
    // need a way to find msvc libc/c++ headers" in their CI matrix —
    // the SUPPORTED Windows path is `x86_64-windows-gnu`. Reverted the
    // msvc-forcing; CI now builds Rust for the gnu target too.
    // 2026-08-10: Windows can't use the auto-detect path at all. Zig resolves
    // a native Windows target to the *msvc* ABI — the build log prints
    // `-target native-native-msvc` — no matter which ABI the Rust target uses.
    // Two consequences, both bad:
    //
    //   1. On a machine without Visual Studio, compiling ghostty's C++ deps
    //      (simdutf, highway) dies with `failed to find libc installation:
    //      WindowsSdkNotFound`. GitHub's windows runners ship MSVC, so CI is
    //      green while a plain `cargo build` on a dev box fails.
    //   2. Where it does succeed it produces an msvc-ABI static lib and hands
    //      it to a `-gnu` Rust target.
    //
    // So on Windows always be explicit, and derive the ABI from the Rust
    // target. Note this is NOT the reverted msvc-forcing described above:
    // that pinned zig to msvc regardless of the Rust target, whereas this
    // just stops zig from guessing an ABI that contradicts the one Rust is
    // already building for.
    if target != host || target.contains("windows") {
        let zig_target = zig_target(&target);
        build.arg(format!("-Dtarget={zig_target}"));
    }

    // Log the exact zig invocation so CI logs make it obvious which
    // target zig actually built for (auto-detected vs explicit) — the
    // Windows AV debug hunt needs to see whether -Dtarget=…-msvc
    // reached zig or was silently dropped. `cargo:warning=` is the only
    // build.rs output cargo surfaces on SUCCESS; eprintln! gets dropped
    // (learned this the hard way — the previous CI push had eprintln
    // here and it was invisible in the log).
    println!("cargo:warning=zig invocation: {build:?}");

    run(build, "zig build libghostty-vt");

    let lib_dir = install_prefix.join("lib");
    let mut search_dirs = vec![lib_dir.clone()];
    if target.contains("windows") {
        search_dirs.push(install_prefix.join("bin"));
    }

    // Scan the install dirs for anything ghostty-vt-shaped rather than
    // hardcode a single name — zig emits a different filename per
    // (ABI, linkage) combination and the tree isn't documented anywhere
    // we can grep:
    //   Linux/macOS:     `libghostty-vt.a`
    //   -windows-msvc:   `ghostty-vt-static.lib` + `ghostty-vt.lib` (DLL import stub)
    //   -windows-gnu:    empirically NEITHER of the above — CI hit the
    //                    assert. Log what's actually there so future
    //                    contributors don't have to re-guess.
    //
    // The MSVC case matters: a bare `.lib` extension is used both for
    // real static libs AND for DLL import stubs — the extension alone
    // can't distinguish them. So we collect ALL matches, then explicitly
    // prefer names containing `-static` (matches ghostty's actual naming
    // convention) so we never silently pick the DLL-import stub.
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut all_files: Vec<String> = Vec::new();
    for dir in &search_dirs {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    all_files.push(format!("{}/{}", dir.display(), name));
                    let is_static = name.ends_with(".a") || name.ends_with(".lib");
                    // Anchor on `ghostty-vt` as a token (start of the
                    // stem, after optional `lib` prefix) — avoids false
                    // matches on hypothetical names like
                    // `libghostty-vtable-support.a`.
                    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
                    let unprefixed = stem.strip_prefix("lib").unwrap_or(stem);
                    let is_ghostty_vt = unprefixed == "ghostty-vt"
                        || unprefixed.starts_with("ghostty-vt-")
                        || unprefixed.starts_with("ghostty-vt.");
                    // MinGW DLL import libs are named e.g.
                    // `libghostty-vt.dll.a` — extension-check misses
                    // them; substring match is the reliable exclusion.
                    let is_import_stub = name.contains(".dll.") || name.contains(".dylib");
                    if is_static && is_ghostty_vt && !is_import_stub {
                        candidates.push(path);
                    }
                }
            }
        }
    }

    if candidates.is_empty() {
        panic!(
            "no ghostty-vt static library found after zig build. \
             search_dirs: {search_dirs:?}. all files seen: {all_files:?}"
        );
    }

    // Prefer names containing `-static` — on MSVC we get BOTH
    // `ghostty-vt-static.lib` (real) and `ghostty-vt.lib` (DLL import
    // stub); picking the wrong one would silently link against the
    // stub and produce a binary that expects ghostty-vt.dll at runtime.
    candidates.sort_by_key(|p| {
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        // `false` sorts BEFORE `true`, so `!contains("static")` puts
        // static-containing names FIRST.
        !name.contains("-static")
    });
    if candidates.len() > 1 {
        println!(
            "cargo:warning=multiple ghostty-vt static candidates found ({}); \
             using the first after -static preference. all matches: {candidates:?}",
            candidates.len()
        );
    }
    let a_path = candidates
        .into_iter()
        .next()
        .expect("checked non-empty above");
    println!(
        "cargo:warning=libghostty-vt static artifact: {}",
        a_path.display()
    );

    for dir in &search_dirs {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }

    // Tell cargo how to link the artifact. Two shapes:
    //
    // A) Bare name (`static=NAME`) — cargo transforms per target convention:
    //    Unix/MinGW → `libNAME.a`, MSVC → `NAME.lib`. Works when zig
    //    emitted a filename matching the target's convention.
    // B) Verbatim (`static:+verbatim=FULL.FILENAME.EXT`) — cargo passes
    //    the literal filename to the linker with no transformation.
    //    Needed when zig's filename doesn't match the target convention.
    //
    // Zig on `-Dtarget=x86_64-windows-gnu` empirically emits
    // `ghostty-vt-static.lib` (MSVC-style), NOT `libghostty-vt-static.a`
    // (MinGW-style). Rust's `windows-gnu` target expects the MinGW
    // shape via bare-name lookup, so `static=ghostty-vt-static` fails
    // with "could not find native static library". Fix: detect the
    // mismatch (artifact file extension vs. Rust target ABI) and use
    // verbatim in that case. Same-convention cases stay on bare name
    // so we don't lose the cross-platform simplicity elsewhere.
    let a_filename = a_path
        .file_name()
        .and_then(|s| s.to_str())
        .expect("artifact path has no filename");
    let target_wants_lib = target.contains("windows-msvc");
    let target_wants_a = !target.contains("windows-msvc");
    let file_is_lib = a_filename.ends_with(".lib");
    let file_is_a = a_filename.ends_with(".a");
    let convention_mismatch = (target_wants_lib && file_is_a) || (target_wants_a && file_is_lib);

    if convention_mismatch {
        println!("cargo:rustc-link-lib=static:+verbatim={a_filename}");
    } else {
        // Strip `lib` prefix + `.a`/`.lib` extension to get the bare
        // symbol name cargo will re-transform per target.
        let link_name = a_path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.strip_prefix("lib").unwrap_or(s))
            .expect("artifact path has no filename stem");
        println!("cargo:rustc-link-lib=static={link_name}");
    }
    emit_platform_link_libs();
}

/// The prebuilt `.a` we ship uses platform-system symbols (Foundation +
/// friends on macOS, stdc++/m on Linux). Emit them regardless of which
/// link path found the archive.
fn emit_platform_link_libs() {
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=CoreText");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rustc-link-lib=framework=CoreServices");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=IOSurface");
        println!("cargo:rustc-link-lib=c++");
    }
    #[cfg(all(target_os = "linux", not(target_arch = "wasm32")))]
    {
        println!("cargo:rustc-link-lib=stdc++");
        println!("cargo:rustc-link-lib=m");
    }
    // Windows: zig's ghostty build links MSVCRT + advapi32 + userenv + ws2_32
    // implicitly via COFF directives in the .a; nothing to emit here.
}

#[cfg(feature = "source-build")]
fn fetch_ghostty(out_dir: &Path) -> PathBuf {
    let src_dir = out_dir.join("ghostty-src");
    let stamp = src_dir.join(".ghostty-commit");

    // Skip re-clone if the stamp says we're already on the right commit.
    if stamp.exists()
        && let Ok(existing) = std::fs::read_to_string(&stamp)
        && existing.trim() == GHOSTTY_COMMIT
    {
        return src_dir;
    }

    if src_dir.exists() {
        std::fs::remove_dir_all(&src_dir)
            .unwrap_or_else(|e| panic!("failed to remove {}: {e}", src_dir.display()));
    }

    eprintln!("mnml-libghostty-vt-sys: cloning ghostty @ {GHOSTTY_COMMIT}");

    let mut clone = Command::new("git");
    clone
        .arg("clone")
        .arg("--filter=blob:none")
        .arg("--no-checkout")
        .arg(GHOSTTY_REPO)
        .arg(&src_dir);
    run(clone, "git clone ghostty");

    let mut checkout = Command::new("git");
    checkout
        .arg("checkout")
        .arg(GHOSTTY_COMMIT)
        .current_dir(&src_dir);
    run(checkout, "git checkout ghostty commit");

    std::fs::write(&stamp, GHOSTTY_COMMIT)
        .unwrap_or_else(|e| panic!("failed to write commit stamp: {e}"));
    src_dir
}

#[cfg(feature = "source-build")]
fn zig_optimize_mode() -> &'static str {
    // Match cargo's profile choice so dev builds are debuggable.
    if env::var("DEBUG").as_deref() == Ok("true") {
        "Debug"
    } else {
        match env::var("OPT_LEVEL").as_deref() {
            Ok("s") | Ok("z") => "ReleaseSmall",
            _ => "ReleaseFast",
        }
    }
}

/// Convert a Rust target triple to the zig triple ghostty's build.zig
/// understands. Covers the four we ship (linux + darwin + windows).
#[cfg(feature = "source-build")]
fn zig_target(target: &str) -> String {
    let v = match target {
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "aarch64-apple-darwin" => "aarch64-macos-none",
        "x86_64-apple-darwin" => "x86_64-macos-none",
        "x86_64-pc-windows-gnu" => "x86_64-windows-gnu",
        "aarch64-pc-windows-gnullvm" => "aarch64-windows-gnu",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        "aarch64-pc-windows-msvc" => "aarch64-windows-msvc",
        other => panic!("mnml-libghostty-vt-sys: unsupported target for source-build: {other}"),
    };
    v.to_owned()
}

#[cfg(feature = "source-build")]
fn run(mut command: Command, context: &str) {
    let status = command
        .status()
        .unwrap_or_else(|e| panic!("failed to execute {context}: {e}"));
    assert!(status.success(), "{context} failed with status {status}");
}

/// Verify a build tool is on PATH; panic with a formatted install-help
/// message if not. Checks whether the binary can be spawned — a spawn
/// Err (ENOENT) means the tool isn't on PATH; a non-zero exit code
/// means it's there and complained about the args, which is fine for
/// our purposes. Different tools want different flags for their
/// version subcommand (zig wants `version` — no dashes — while git
/// wants `--version`), so probing for existence is more portable
/// than trying to run any particular subcommand.
///
/// This runs before any zig/git invocation so `cargo install mnml-rs`
/// on a machine without the prereqs prints one clear error instead of
/// a cryptic "No such file or directory (os error 2)" from deep inside
/// the source-build path.
#[cfg(feature = "source-build")]
fn require_tool_or_die(tool: &str, help: &str) {
    let present = Command::new(tool).arg("--version").output().is_ok();
    if !present {
        // Emit as a cargo:warning first so the message is unmissable in
        // the cargo-install output, then panic to actually fail the build.
        println!("cargo:warning=mnml-libghostty-vt-sys: `{tool}` not found on PATH");
        panic!("\n\n{help}\n");
    }
}

#[cfg(feature = "source-build")]
const ZIG_MISSING_HELP: &str = "\
mnml-libghostty-vt-sys requires the Zig compiler (0.16.0) to build.

Install it:
  macOS:   brew install zig
  Linux:   snap install zig --classic --edge
  Windows: scoop install zig
  Any OS:  download from https://ziglang.org/download/ and put it on PATH

Then re-run: cargo install mnml-rs

If you already have a libghostty-vt.a built elsewhere, set PKG_CONFIG_PATH
to point at a directory containing libghostty-vt.pc and this build will
use it instead of source-building. Local ghostty checkout? Set
GHOSTTY_SOURCE_DIR=/path/to/ghostty.

Or install mnml via one of the prebuilt channels which don't need zig:
  brew install chris-mclennan/tap/mnml         (macOS / Linux)
  scoop install mnml                            (Windows)
  https://github.com/chris-mclennan/mnml/releases  (all platforms)";

#[cfg(feature = "source-build")]
const GIT_MISSING_HELP: &str = "\
mnml-libghostty-vt-sys requires `git` on PATH to clone ghostty's source
during the build. Install git via your package manager:

  macOS:   brew install git       (or xcode-select --install)
  Linux:   apt install git         (or your distro's equivalent)
  Windows: winget install Git.Git  (or scoop install git)

Then re-run: cargo install mnml-rs

Already have a ghostty checkout locally? Point at it with
GHOSTTY_SOURCE_DIR=/path/to/ghostty to skip the clone entirely.";

fn generate_bindings(vt_h: &Path, vendor_include: &Path) {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let bindings_out = out_dir.join("bindings.rs");

    // `mut` only used on macOS (SDK-path override); silenced on other targets.
    #[allow(unused_mut)]
    let mut builder = bindgen::Builder::default()
        .header(vt_h.to_string_lossy())
        .clang_arg(format!("-I{}", vendor_include.display()))
        .clang_arg("-xc")
        .clang_arg("-std=c11")
        .allowlist_type("GhosttyVt.*")
        .allowlist_type("Ghostty.*")
        .allowlist_function("ghostty_.*")
        .allowlist_var("GHOSTTY_.*")
        .allowlist_var("Ghostty.*")
        .allowlist_recursively(true)
        .layout_tests(false)
        .default_enum_style(bindgen::EnumVariation::NewType {
            is_bitfield: false,
            is_global: false,
        })
        .blocklist_type("__.*")
        .generate_comments(true)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));

    // macOS SDK path so clang can resolve `<stddef.h>` etc.
    #[cfg(target_os = "macos")]
    if let Ok(sdk) = std::process::Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        && sdk.status.success()
    {
        let sdk_path = String::from_utf8_lossy(&sdk.stdout).trim().to_string();
        if !sdk_path.is_empty() {
            builder = builder.clang_arg(format!("-isysroot{sdk_path}"));
        }
    }

    let bindings = builder
        .generate()
        .expect("bindgen failed to generate bindings for ghostty/vt.h");
    bindings
        .write_to_file(&bindings_out)
        .expect("failed to write bindings.rs");
}
