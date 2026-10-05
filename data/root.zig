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

/// The four Atlassian marks the Bitbucket and Jira chips wear — the
/// icons Bitbucket's and Jira's own sidebars draw for pull requests,
/// pipelines, boards and releases. Atlassian's design-system SVGs,
/// unmodified (16-unit grid, one filled path each, holes by
/// `evenodd`): `pull-request`, `board` and `release` from
/// `@atlaskit/icon` 38.0.2's `svgs/core/`, `pipeline` from
/// `@atlaskit/icon-lab` 7.11.0's (the core set has no pipelines mark).
/// Apache-2.0, Atlassian's copyright; `glyphs/NOTICE` carries both.
pub const atlassian_pull_request_svg = @embedFile("glyphs/atlassian-pull-request.svg");
pub const atlassian_pipeline_svg = @embedFile("glyphs/atlassian-pipeline.svg");
pub const atlassian_board_svg = @embedFile("glyphs/atlassian-board.svg");
pub const atlassian_release_svg = @embedFile("glyphs/atlassian-release.svg");
/// The Jira Work chip's mark: `work-items` from the same `svgs/core/`
/// (a card with a check, a second card's edge behind it).
pub const atlassian_work_items_svg = @embedFile("glyphs/atlassian-work-items.svg");

/// The Beatport "B" — the round mark beside the wordmark in Beatport's
/// own logo, the wordmark's letters dropped — that the statusline's
/// now-playing cluster wears for mixr (`ui/statusline.zig`,
/// `cluster_brand_glyph`). One filled path; the disc's counter is a
/// hole by nesting. The mnml Rust editor carried it in its own face at
/// the same codepoint; this is that drawing.
pub const beatport_svg = @embedFile("glyphs/beatport.svg");

/// The shell integration a shell pane's shell loads
/// (`src/app/shell_integration.zig`): the files mnml writes into its
/// data root, per shell, by the name each is installed under.
pub const zsh_integration = .{
    .zshenv = @embedFile("shell-integration/zsh/zshenv"),
    .script = @embedFile("shell-integration/zsh/mnml-integration.zsh"),
};
pub const bash_integration = .{
    .init = @embedFile("shell-integration/bash/mnml.bash"),
};
pub const fish_integration = .{
    .init = @embedFile("shell-integration/fish/mnml.fish"),
};

/// `mnml --demo` (`src/config/demo.zig`). `tour/` is the fixture the
/// real-screen tour and the site recordings build too
/// (`tools/tour/workspace.py` reads these same files): a small Zig
/// project with history, a dirty working tree, a note, a finding and
/// the Jira / Bitbucket configs for the offline fakes. The rest is the
/// demo's own: request files for the fakes, a second branch's file, the
/// throwaway home's config and `init.lua` (the first screen), and the
/// stand-in `claude` / `codex` put first on its `PATH`.
pub const demo = struct {
    pub const readme = @embedFile("demo/tour/README.md");
    pub const gitignore = @embedFile("demo/tour/gitignore");
    pub const main_v1 = @embedFile("demo/tour/main-v1.zig");
    pub const main_v2 = @embedFile("demo/tour/main-v2.zig");
    pub const util = @embedFile("demo/tour/util.zig");
    pub const util_dirty = @embedFile("demo/tour/util-dirty.zig");
    pub const docs_notes = @embedFile("demo/tour/docs-notes.md");
    pub const changelog = @embedFile("demo/tour/CHANGELOG.md");
    pub const workspace_config = @embedFile("demo/tour/config.zon");
    pub const note_release = @embedFile("demo/tour/note-release.md");
    pub const finding = @embedFile("demo/tour/finding-tour-clock.md");
    pub const zshrc = @embedFile("demo/tour/zshrc");
    pub const jira_config = @embedFile("demo/tour/jira-config.zon");
    pub const bitbucket_config = @embedFile("demo/tour/bitbucket-config.zon");

    pub const jira_http = @embedFile("demo/requests/jira.http");
    pub const bitbucket_http = @embedFile("demo/requests/bitbucket.http");
    pub const args_zig = @embedFile("demo/args.zig");
    pub const home_config = @embedFile("demo/home-config.zon");
    pub const init_lua = @embedFile("demo/init.lua");
    pub const claude_shim = @embedFile("demo/bin/claude");
    pub const codex_shim = @embedFile("demo/bin/codex");
};
