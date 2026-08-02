# mnml-vt

Safe wrapper around Ghostty's [libghostty-vt] C ABI — built on top of the
[`mnml-vt-sys`](../mnml-vt-sys) bindgen crate. Covers the surface mnml
consumes: `Terminal` + `TerminalOptions`, `RenderState` + snapshot iteration
(with lending row/cell iterators), plus the small value types in `style`
and `screen`.

## `[lib].name` is `libghostty_vt`

The Cargo package is `mnml-vt` but the Rust `[lib].name` is
`libghostty_vt`, so callers write `use libghostty_vt::…` — not
`use mnml_vt::…`. mnml itself masks this via a package rename in its
`Cargo.toml`:

```toml
libghostty-vt = { package = "mnml-vt", path = "crates/mnml-vt", version = "0.2.0" }
```

Downstream consumers reaching for this crate directly still need
`use libghostty_vt::…` for the import path.

[libghostty-vt]: https://github.com/ghostty-org/ghostty/tree/main/include/ghostty
