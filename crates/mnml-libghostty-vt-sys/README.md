# mnml-libghostty-vt-sys

Raw FFI bindings to Ghostty's [libghostty-vt] C ABI, generated at build time
by `bindgen` against vendored headers under `vendor/libghostty-vt/include/`
(relative to the mnml workspace root).

This crate exists so mnml owns its Ghostty binding surface directly against
Ghostty's official C headers, rather than depending on a third-party
`libghostty-vt-sys` on crates.io.

## Linking

`build.rs` clones ghostty at the pinned `GHOSTTY_COMMIT` (kept in
lock-step with the vendored headers) and runs `zig build -Demit-lib-vt`,
then links the produced static `.a`. Needs zig 0.16.0 + git on PATH;
the resulting `.a` is cached under `target/` between cargo runs.

A `pkg-config` feature is default-on and tried first — if a
`libghostty-vt-static.pc` shows up on `PKG_CONFIG_PATH` (e.g. a future
prebuilt setup), that path wins and zig isn't invoked. As of 2026-08-02
no such `.pc` is checked in, so every host source-builds by default.

## Ergonomic wrapper

Application code should depend on [`mnml-libghostty-vt`] (the safe wrapper), not this
sys crate directly.

## `[lib].name` is `libghostty_vt_sys`

The Cargo package is `mnml-libghostty-vt-sys` but the Rust `[lib].name` is
set to `libghostty_vt_sys`, so `use libghostty_vt_sys::…` is the import
path. mnml itself masks the mnml-prefixed package name via a workspace
alias `libghostty-vt-sys = { package = "mnml-libghostty-vt-sys", ... }`
in its `Cargo.toml`; consumers reaching for this crate directly still
write `use libghostty_vt_sys::…`.

[libghostty-vt]: https://github.com/ghostty-org/ghostty/tree/main/include/ghostty
[`mnml-libghostty-vt`]: ../mnml-libghostty-vt
