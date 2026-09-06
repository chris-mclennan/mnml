# The UI spec

`rust-120x40.txt` is the Rust editor's screen — every cell, glyphs
included — on the fixture workspace with the author's real config, at
120×40, after the first-run overlay is dismissed. It is what mnml-zig
must look like. `rust-80x24.txt` is the same screen at 80×24 — the
statusline's overflow rule (the branch chip clipped to `main …`). Both
are embedded into the test binary (`build.zig`, `ui_spec_rust_*`) so
the statusline tests compare the painted row with the spec's. Colours are not in the dump; for those the Rust source
under `src/ui/` is the reference, and a side-by-side screenshot in
ghostty is the final check.

Regenerate and compare with `tools/ui-diff.sh WS RS_DATA ZIG_DATA
STEPS` (see the script header). Out of scope until the Zig integrations
exist: the pinned integration launcher icons in the rail and palette
bar. Cut: now-playing / Sonos chips.

Glyphs are codepoints, not looks. The author's ghostty runs
`font-family = JetBrainsMono Nerd Font` with `font-codepoint-map =
U+F1B00-U+F20FF=MnmlSymbols` (mnml's own baked glyphs: integration
chips, spinners, the claude/codex marks, tree connectors). Paint the
exact codepoint the Rust painter uses — never a lookalike from another
Nerd Font family — and put nothing in U+F1B00–U+F20FF the Rust side does
not already bake (`mnml/assets/glyphs/`, the Rust glyph tables), or it
renders as a box.

Same look, Zig internals: the Rust modules are a behaviour reference,
not a template. Build on the component system (`Ui`, `HitMap`,
`Canvas`, `ListPanel`), register every click target in the same
statement that paints it, and add nothing the Rust screen does not show.

`rust-80x24.txt` is the same screen at 80×24 — the narrow rule: only
the brand menu fits before the ` » `, the browser chip is dropped from
the gap, the right cluster is the compact one. `src/ui/menu_bar.zig`
pins row 0 of both dumps as `rust_row_120` / `rust_row_80`.
