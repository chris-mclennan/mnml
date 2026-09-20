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
///
/// `claude-code.svg` is the Claude Code figure, not the Anthropic
/// spark: the mnml editor swapped its own `claude-spark.svg` for this
/// on 2026-08-08 and this file is that one, byte for byte. Its two
/// small rectangles are the figure's eyes — holes, which `ttf.place`
/// works out by nesting depth, since `fill-rule="evenodd"` on the path
/// is exactly the rule it applies.
/// `claude-spark.svg` is that earlier spark, kept as the ALTERNATE the
/// chrome offers (`ui.claude_mark = .spark`, `app/claude_mark.zig`): it
/// is baked one codepoint along from the figure, so both marks are in
/// the face at once and picking one is a repaint, not a re-bake.
pub const claude_svg = @embedFile("glyphs/claude-code.svg");
pub const claude_spark_svg = @embedFile("glyphs/claude-spark.svg");
pub const codex_svg = @embedFile("glyphs/codex.svg");
pub const ghostty_svg = @embedFile("glyphs/ghostty.svg");
