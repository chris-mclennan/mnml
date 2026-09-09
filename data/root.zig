//! The data files the app carries inside the binary. The main module is
//! rooted at `src/` and cannot reach a sibling directory, so this is
//! its own module (the `data` import), as `themes/root.zig` is.

/// ryanoasis/nerd-fonts' `glyphnames.json` (~545 KB): every Nerd Font
/// glyph's name by codepoint. The glyph audit and the bake read it from
/// here, so both work in any workspace, not only the mnml-zig tree.
/// Refresh with `curl -L https://raw.githubusercontent.com/ryanoasis/nerd-fonts/HEAD/glyphnames.json`.
pub const nerd_glyphnames = @embedFile("nerd-glyphnames.json");
