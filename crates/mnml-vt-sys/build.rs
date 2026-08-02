//! Build script for `mnml-vt-sys`.
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
    // Workspace root is two levels up: crates/mnml-vt-sys/ → workspace root.
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
            let p = PathBuf::from(dir);
            assert!(
                p.join("build.zig").exists(),
                "GHOSTTY_SOURCE_DIR does not contain build.zig: {}",
                p.display()
            );
            p
        }
        Err(_) => fetch_ghostty(&out_dir),
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
    if target != host {
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
    // Windows artifact naming splits on ABI:
    //   -windows-msvc → `ghostty-vt-static.lib` (MSVC convention)
    //   -windows-gnu  → `libghostty-vt.a`      (MinGW/Unix convention)
    // Everything else uses the Unix `libghostty-vt.a` name too. Getting
    // this wrong produces `error: could not find native static library
    // 'ghostty-vt', perhaps an -L flag is missing?` from Rust's linker.
    let a_name = if target.contains("windows-msvc") {
        "ghostty-vt-static.lib"
    } else {
        "libghostty-vt.a"
    };
    assert!(
        search_dirs.iter().any(|d| d.join(a_name).exists()),
        "expected {a_name} in one of {search_dirs:?} after zig build"
    );

    for dir in &search_dirs {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }
    println!("cargo:rustc-link-lib=static=ghostty-vt");
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

    eprintln!("mnml-vt-sys: cloning ghostty @ {GHOSTTY_COMMIT}");

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
        other => panic!("mnml-vt-sys: unsupported target for source-build: {other}"),
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
