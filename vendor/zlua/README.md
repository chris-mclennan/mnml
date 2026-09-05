# zlua (vendored)

`src/lib.zig` (+ `define.zig`) is zlua's Lua binding, MIT — see `LICENSE`. Taken verbatim from
https://github.com/natecraddock/ziglua at `c046b3fd69a4488367847d5c44b1aa0a26cfdf03`
(main, 2026-09). Vendored, not a `build.zig.zon` dependency, for the reason
tree-sitter is: the package's `build.zig` (and the `translate_c` package it pins)
fail analysis on Zig 0.16.0 (`Run.addPassthruArgs`, `OptimizeMode.debug`), and
the build runner compiles every dependency's `build.zig` whether or not it is
called. The lib itself builds on 0.16.0. `build.zig`'s `addLua` compiles Lua 5.4
from the `lua54` tarball, translates `include/lua_all.h`, and hands the lib the
`config` options its `build.zig` would have.
