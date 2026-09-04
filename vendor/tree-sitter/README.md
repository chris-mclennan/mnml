# tree-sitter runtime (vendored)

`lib/src` + `lib/include` from tree-sitter **v0.26.8** (the version the
Rust lockfile resolves to), MIT — see `LICENSE`.

Vendored rather than fetched: Zig's build runner analyzes every
dependency's `build.zig` as soon as any `b.dependency()` call exists in
the graph, and tree-sitter's ships a pre-0.16 build script. We only need
the C sources. Bump by replacing `lib/` from the matching tag.
