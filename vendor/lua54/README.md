# lua54 (patched files)

Files here replace their namesakes from the `lua54` tarball pinned in
`build.zig.zon` (Lua 5.4.9, MIT — the copyright notice is in the
tarball's `lua.h`). `build.zig`'s `addLua` compiles the tarball's list
minus these, plus these.

- `lstrlib.c` — upstream's, plus a step counter in the pattern matcher
  that asks the host (`mnml_lstr_budget`, set by
  `src/scripting/lua.zig`) whether the script budget is spent. The
  change is marked `mnml:` in the file; everything else is verbatim.
