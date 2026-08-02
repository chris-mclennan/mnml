//! Build script for `mnml-vt-sys`.
//!
//! Runs bindgen against Ghostty's official `vt.h` header (vendored under
//! the workspace at `vendor/libghostty-vt/include/`), and — when the
//! `pkg-config` feature is on — locates the prebuilt `libghostty-vt.a`
//! via pkg-config so cargo can link it.
//!
//! # Vendored header set
//!
//! The header tree matches the one shipped by the pinned ghostty commit
//! that produced the prebuilt `.a` files under
//! `vendor/libghostty-vt/lib-*`. Bumping the .a requires re-vendoring the
//! headers in lock-step (bindgen re-runs on `cargo build`).
//!
//! # Feature flags
//!
//! - `pkg-config` (default) — consume the vendored prebuilt via
//!   `PKG_CONFIG_PATH` (mnml's `.cargo/config.toml` sets this per-target).
//!   No Zig toolchain required.
//!
//! Source-built (`zig build`) mode is deliberately NOT implemented here —
//! Ghostty pins Zig 0.15.2, which can't link on macOS 26. We ship
//! prebuilts and let bindgen re-generate against the frozen headers.

use std::env;
use std::path::PathBuf;

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
            "vendored vt.h not found at {}. Re-run vendor/libghostty-vt/fetch-prebuilts.sh.",
            vt_h.display()
        );
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", vt_h.display());
    // Re-run on any header change under the vendored tree.
    println!(
        "cargo:rerun-if-changed={}",
        vendor_include.join("ghostty/vt").display()
    );

    // ---- 1. Locate / link the prebuilt `.a` --------------------------------

    #[cfg(feature = "pkg-config")]
    {
        // `.cargo/config.toml` sets PKG_CONFIG_PATH per target triple. The
        // static feature exposes the .a directly so we don't need shared-lib
        // rpath handling.
        let lib = pkg_config::Config::new()
            .statik(true)
            .probe("libghostty-vt-static")
            .or_else(|_| {
                pkg_config::Config::new()
                    .statik(true)
                    .probe("libghostty-vt")
            })
            .expect(
                "pkg-config could not locate libghostty-vt. \
                 Ensure PKG_CONFIG_PATH points at vendor/libghostty-vt/pkgconfig-<host>/ \
                 (see workspace `.cargo/config.toml`).",
            );
        // Emit link + search-path lines from what pkg-config reported.
        for path in &lib.link_paths {
            println!("cargo:rustc-link-search=native={}", path.display());
        }
        for l in &lib.libs {
            println!("cargo:rustc-link-lib=static={l}");
        }
        // The vendored .a uses a handful of platform C++ / system symbols
        // (libunwind on Linux, Foundation on macOS). Belt-and-suspenders:
        // pkg-config's `Requires.private` / `Libs.private` usually cover
        // these, but link them explicitly on macOS where the vendored .pc
        // is minimal.
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
    }

    // ---- 2. Generate bindings ---------------------------------------------

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let bindings_out = out_dir.join("bindings.rs");

    let mut builder = bindgen::Builder::default()
        .header(vt_h.to_string_lossy())
        .clang_arg(format!("-I{}", vendor_include.display()))
        // libghostty-vt is a pure C API; force C mode so bindgen skips C++
        // decls (there are none).
        .clang_arg("-xc")
        .clang_arg("-std=c11")
        // Only pull in ghostty-owned decls; skip stdint / stddef spam.
        .allowlist_type("GhosttyVt.*")
        .allowlist_type("Ghostty.*")
        .allowlist_function("ghostty_.*")
        .allowlist_var("GHOSTTY_.*")
        .allowlist_var("Ghostty.*")
        // Recursively include types referenced by the above.
        .allowlist_recursively(true)
        // Layout tests would need the .a to run — skip.
        .layout_tests(false)
        // Newtype enums so we get exhaustive matches on Rust side but retain
        // fwd-compat if ghostty adds a variant.
        .default_enum_style(bindgen::EnumVariation::NewType {
            is_bitfield: false,
            is_global: false,
        })
        // ghostty's typedef'd struct handles are pointer-shaped opaque —
        // bindgen would emit them as `[u8; 0]` blocks otherwise, which
        // breaks null-checks. Force pointer-sized opaques.
        .blocklist_type("__.*")
        .generate_comments(true)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));

    // macOS SDK path — bindgen needs the sysroot to resolve `<stddef.h>`,
    // etc. when clang isn't preconfigured with it (common on CI).
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
