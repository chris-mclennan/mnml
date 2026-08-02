# mnml-vt-sys

Raw FFI bindings to Ghostty's [libghostty-vt] C ABI, generated at build time
by `bindgen` against vendored headers under `vendor/libghostty-vt/include/`
(relative to the mnml workspace root).

This crate exists so mnml owns its Ghostty binding surface directly against
Ghostty's official C headers, rather than depending on a third-party
`libghostty-vt-sys` on crates.io.

## Linking

The default `pkg-config` feature consumes the vendored prebuilt static
`libghostty-vt.a` via pkg-config. mnml's `.cargo/config.toml` sets
`PKG_CONFIG_PATH` per target triple.

## Ergonomic wrapper

Application code should depend on [`mnml-vt`] (the safe wrapper), not this
sys crate directly.

## `[lib].name` is `libghostty_vt_sys`

The Cargo package is `mnml-vt-sys` but the Rust `[lib].name` is set to
`libghostty_vt_sys`, so `use libghostty_vt_sys::…` is the import path — not
`use mnml_vt_sys::…`. mnml itself masks this via `libghostty-vt-sys = {
package = "mnml-vt-sys", ... }` in its `Cargo.toml`; consumers reaching for
this crate directly (without the package rename) still need
`use libghostty_vt_sys::…`.

[libghostty-vt]: https://github.com/ghostty-org/ghostty/tree/main/include/ghostty
[`mnml-vt`]: ../mnml-vt
