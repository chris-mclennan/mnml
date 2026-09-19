//! The data files the app carries inside the binary. The main module is
//! rooted at `src/` and cannot reach a sibling directory, so this is
//! its own module (the `data` import), as `themes/root.zig` is.

/// ryanoasis/nerd-fonts' `glyphnames.json` (~545 KB): every Nerd Font
/// glyph's name by codepoint. The glyph audit and the bake read it from
/// here, so both work in any workspace, not only the mnml-zig tree.
/// Refresh with `curl -L https://raw.githubusercontent.com/ryanoasis/nerd-fonts/HEAD/glyphnames.json`.
pub const nerd_glyphnames = @embedFile("nerd-glyphnames.json");

/// The SVGs mnml bakes into its own symbols face (`src/glyph/
/// builder.zig`). Each is a monochrome silhouette: a font glyph has one
/// colour, so a mark's layers are reduced to an outline and its holes.
///
/// `ghostty.svg` is Ghostty's own ghost, reduced that way — the
/// silhouette with the `>_` prompt cut out of it.
pub const claude_svg = @embedFile("glyphs/claude-spark.svg");
pub const codex_svg = @embedFile("glyphs/codex.svg");
pub const ghostty_svg = @embedFile("glyphs/ghostty.svg");
