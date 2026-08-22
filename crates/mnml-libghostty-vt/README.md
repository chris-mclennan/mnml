# mnml-libghostty-vt

Safe wrapper around Ghostty's [libghostty-vt] C ABI — built on top of the
[`mnml-libghostty-vt-sys`](../mnml-libghostty-vt-sys) bindgen crate. Covers
the surface mnml consumes: `Terminal` + `TerminalOptions`, `RenderState` +
snapshot iteration (with lending row/cell iterators), plus the small value
types in `style` and `screen`.

## `[lib].name` is `libghostty_vt`

The Cargo package is `mnml-libghostty-vt` but the Rust `[lib].name` is
`libghostty_vt`, so callers write `use libghostty_vt::…`. mnml itself
masks the mnml-prefixed package name via a workspace alias in its
`Cargo.toml`:

```toml
libghostty-vt = { package = "mnml-libghostty-vt", path = "crates/mnml-libghostty-vt", version = "0.2.2" }
```

Downstream consumers reaching for this crate directly still write
`use libghostty_vt::…` for the import path.

[libghostty-vt]: https://github.com/ghostty-org/ghostty/tree/main/include/ghostty
