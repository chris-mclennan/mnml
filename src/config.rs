//! Configuration. Merged from (lowest → highest precedence): built-in defaults,
//! `~/.config/mnml/config.toml`, `<workspace>/.mnml/config.toml`, then `--config PATH`.
//!
//! `[editor]`, `[ui]`, `[keys.*]`, `[tasks.*]`, `[startup]`, and `[snippets.*]`
//! are live. `[lsp.*]`, `[ai]`, `[tools]` are parsed-and-kept (so existing
//! config files keep working) but unused until their tracks land.
//!
//! `[tasks.<name>]` defines a shell command (`cmd = "..."`, optional `cwd`)
//! openable in a pty pane via the `task.run` command; `[startup] tasks = [...]`
//! lists task names auto-run in pty panes when a workspace opens.
//!
//! `[keys.*]` maps **key spec → command id**, like VSCode's `keybindings.json`
//! (the reverse direction is awkward — a key can only do one thing — and this way
//! `"ctrl+p" = "none"` cleanly unbinds a default). Sections: `[keys.global]`
//! applies always; `[keys.vim]` / `[keys.standard]` overlay it for that input
//! style. Unknown command ids are tolerated (they just never fire).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct Config {
    pub editor: EditorConfig,
    pub ui: UiConfig,
    pub session: SessionConfig,
    /// `[keys.<section>]` — key spec → command id. Sections: `global`, `vim`,
    /// `standard`. Resolved into an [`crate::input::keymap::Keymap`].
    pub keys: BTreeMap<String, BTreeMap<String, String>>,
    /// `[lsp.<lang>]` — raw tables, validated by the LSP track later.
    pub lsp: BTreeMap<String, toml::Value>,
    /// `[ai]` / `[tools]` — raw tables, validated by the AI track later.
    pub ai: toml::Value,
    pub tools: toml::Value,
    /// `[tasks.<name>]` — named shell commands openable in a pty pane (`task.run`).
    pub tasks: BTreeMap<String, TaskDef>,
    /// `[startup] tasks = [...]` — task names auto-run in pty panes on workspace open.
    pub startup_tasks: Vec<String>,
    /// `[snippets.<scope>]` — `<scope>` is a file extension (`"rs"`, `"py"`, …)
    /// or the literal `"global"`. Each entry is `<trigger> = "<expansion>"`;
    /// a single `$0` in the expansion picks the cursor landing spot. Resolved
    /// + expanded by [`crate::snippets`].
    pub snippets: BTreeMap<String, BTreeMap<String, String>>,
    /// `[abbr]` — vim abbreviations. Each entry is `<trigger> = "<expansion>"`;
    /// after the trigger word is followed by whitespace / punctuation while
    /// in Insert mode, the word is replaced with the expansion. Runtime
    /// `:ab` adds; `:una` removes.
    pub abbreviations: BTreeMap<String, String>,
    /// `[formatters.<ext>] cmd = "..."` (or a list of strings tried in
    /// order). External formatter command line(s) per file extension;
    /// the buffer is piped through `$SHELL -c <cmd>`. `{file}` in the
    /// template is substituted with the workspace-relative path (so
    /// `prettier --stdin-filepath {file}` picks the right rules).
    /// Config entries override the built-in `DEFAULT_FORMATTERS` table
    /// (`prettier` for js/ts/json/css/md, `ruff format -` for py, etc).
    pub formatters: BTreeMap<String, crate::formatter::FormatterEntry>,
    /// `[linters.<ext>] cmd = "..." parser = "eslint"` — external
    /// linters per file extension. Output goes through the named parser
    /// (`eslint` / `tsc` / `ruff` / `shellcheck` / `vimgrep` fallback)
    /// into LSP-shaped diagnostics that merge with the LSP set. Config
    /// entries override the built-in `DEFAULT_LINTERS` (eslint for
    /// js/ts, ruff for py, shellcheck for sh).
    pub linters: BTreeMap<String, crate::linter::LinterEntry>,
    /// `[dap.<lang>]` — debug adapter configs. Each entry is
    /// `cmd = "..."` + optional `args = [...]` + an optional
    /// `launch.*` sub-table that's substituted (`${file}`, `${workspace}`)
    /// and passed verbatim to the adapter on `launch`. Parsed into
    /// `crate::dap::AdapterConfig` at runtime via `dap::parse_adapters`.
    pub dap: BTreeMap<String, toml::Value>,
    pub browser: BrowserConfig,
    pub playwright: PlaywrightConfig,
    pub ci: CiConfig,
    // [gitlab] config moved to mnml-forge-gitlab.
    // [azdevops] config moved to mnml-forge-azdevops.
    /// `[[workspaces]]` — additional workspaces shown as sibling sections in
    /// the file-tree rail (alongside the launched workspace at the top).
    /// Each entry is a `(name, path)` pair; `~` is expanded.
    pub workspaces: Vec<WorkspaceConfig>,
}

/// One additional workspace surfaced alongside the launched one. Lets the
/// user keep a curated set of related repo groups visible together (e.g.
/// "work" + "mnml-family" in one mnml window). Each workspace gets its own
/// `Tree` rooted at `path`, its own discovered repos, and renders as a
/// collapsible section in the rail.
#[derive(Debug, Clone)]
pub struct WorkspaceConfig {
    /// Display name. Defaults to the path's basename when the config didn't
    /// supply one.
    pub name: String,
    /// Absolute path on disk. `~` is expanded at config-load time.
    pub path: PathBuf,
}

// Bitbucket + GitHub panes + config moved out of mnml core in
// 2026-06. Live dashboards now ship in the standalone
// mnml-forge-bitbucket / mnml-forge-github binaries, hosted via
// `:host.launch mnml-forge-bitbucket` / `:host.launch mnml-forge-github`.
// The integration icon strip seeds rows pointing at them.

/// Long-lived branches the per-branch pipelines view defaults to
/// when a repo's `branches` field is empty.
pub fn default_branches() -> &'static [&'static str] {
    &["main", "master", "develop", "staging"]
}

// `[gitlab]` panes + config moved to mnml-forge-gitlab in 2026-06.
// `[azdevops]` panes + config moved to mnml-forge-azdevops in 2026-06.

/// `[ci]` — Continuous-integration provider settings. The original
/// consumer (the in-tree AWS CodeBuild pane) moved to mnml-aws-codebuild
/// in 2026-06; the struct stays as scaffolding so existing user configs
/// don't error on the section. Unconditional in `Config` so lean
/// builds parse it cleanly.
///
/// ```toml
/// [ci]
/// provider = "codebuild"           # only "codebuild" recognized today
/// project  = "my-playwright"       # required for codebuild
/// region   = "us-east-1"           # optional; falls back to AWS CLI defaults
/// ```
#[derive(Debug, Clone, Default)]
pub struct CiConfig {
    pub provider: Option<String>,
    pub project: Option<String>,
    pub region: Option<String>,
}

/// `[playwright]` — settings used by the Playwright integration. Reserved
/// for future expansion (currently empty after `[playwright.docdb]` moved
/// out to a private blit-host integration).
#[derive(Debug, Clone, Default)]
pub struct PlaywrightConfig {}

#[derive(Debug, Clone)]
pub struct BrowserConfig {
    /// Launch Chrome with `--headless=new` (no window). The pane still
    /// receives network / console / DOM events; the user drives via `g`
    /// (navigate), `e` (eval), `s` (screenshot), etc. Default off — the
    /// visible window is what most users expect from `browser.open`.
    pub headless: bool,
    /// Where Chrome's `--user-data-dir` (cookies, localStorage, login
    /// state) is stored. `"workspace"` (default) ⇒
    /// `<workspace>/.mnml/chrome-profile/` — workspace-scoped, persists
    /// across `browser.open` and across mnml relaunches in the same
    /// workspace. `"shared"` ⇒ `$HOME/.mnml/chrome-profile/` — one
    /// profile across every workspace (handy when you sign into the
    /// same services from multiple repos). `"ephemeral"` ⇒ a fresh
    /// `tempfile::tempdir()` per open — clean-slate for login testing /
    /// fresh-eyes debugging; state vanishes when the pane closes.
    pub profile_mode: String,
}

#[derive(Debug, Clone)]
pub struct TaskDef {
    /// The shell command line (run via `$SHELL -c`).
    pub cmd: String,
    /// Working directory — relative paths are resolved against the workspace; `None` ⇒ workspace.
    pub cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EditorConfig {
    /// `"vim"` or `"standard"`. Anything else falls back to `"standard"` at handler-make time.
    pub input_style: String,
    pub tab_width: usize,
    /// Auto-save a dirty buffer this many seconds after its last edit. `0` ⇒ off.
    pub autosave_secs: u64,
    /// When true, `Buffer::save_to_disk` strips trailing whitespace from each
    /// line before writing. Off by default (a non-destructive default —
    /// trailing-ws diff noise can be useful on someone else's repo).
    pub trim_trailing_ws_on_save: bool,
    /// When true, each editor pane shows the file's workspace-relative path
    /// as a dim one-row header above its body. Especially useful with splits
    /// (you can tell which pane is which without looking at the bufferline).
    pub breadcrumb: bool,
    /// Typing `(` `[` `{` `"` `'` `` ` `` also inserts the matching close
    /// char (cursor between). Off by default — surprises users who haven't
    /// opted in. `[editor] auto_pair = true` to enable.
    pub auto_pair: bool,
    /// On Enter, carry forward the previous line's leading whitespace. On by
    /// default — most users expect this from a modern editor.
    pub auto_indent: bool,
    /// Run `textDocument/formatting` before each save. Off by default — many
    /// repos don't want their files re-formatted; you opt in per-config /
    /// per-workspace when you do. If the LSP isn't attached (or doesn't
    /// implement formatting), the save proceeds normally.
    pub format_on_save: bool,
    /// Fire `textDocument/willSaveWaitUntil` before each save and apply
    /// the server-returned `TextEdit[]` *before* the file hits disk. Off
    /// by default — most servers don't register this; the ones that do
    /// (eslint --fix, organizeImports-on-save) use it as their canonical
    /// pre-save hook. Fires *before* `format_on_save`, so an
    /// organize-imports pass and a format pass can both run in order.
    pub will_save_wait_until: bool,
    /// When true, fire `textDocument/onTypeFormatting` after each typed
    /// trigger char (`}` / `;` / `\n`) and apply the resulting edits.
    /// Off by default — can be surprising to have an LSP rewrite your
    /// half-typed code. Vim canonical name is `formatoptions`; we keep
    /// the explicit `format_on_type` for parity with `format_on_save`.
    pub format_on_type: bool,
    /// Save dirty buffers automatically when they lose focus (switching
    /// to another buffer / pane). Off by default. Useful for the "never
    /// lose work" workflow but surprising for users who use buffer-switching
    /// for "compare-then-discard" gestures.
    pub autosave_on_focus_loss: bool,
    /// Show LSP inlay hints (type / parameter chips). Default `true` —
    /// painted in dim color at the end of each line that has hints. The
    /// LSP request is fired on open + save; hints persist on the buffer
    /// until refreshed.
    pub inlay_hints: bool,
    /// Use `semanticTokens/range` for just the visible viewport (instead
    /// of `full` / `full/delta` for the whole file). Off by default — only
    /// useful for very large files where full / delta is expensive. When
    /// on, the App re-fires range on scroll (debounced by per-buffer
    /// viewport diff). Requires server support for the `range` request;
    /// servers that only support full / delta are unaffected by this flag.
    pub semantic_tokens_viewport: bool,
    /// Show LSP code lenses (`5 references` / `Run | Debug`) as dim
    /// purple end-of-line chips. Default `true`. The MVP renderer is
    /// display-only — clicks aren't yet routed back to the server.
    pub code_lens: bool,
    /// Target line width for `editor.reflow_paragraph` (vim `gqq`) — greedy
    /// word-wrap at this many chars. Default 80.
    pub text_width: usize,
    /// On save, append a `\n` to the buffer if it doesn't already end with
    /// one (POSIX text file convention). On by default — flip with
    /// `[editor] ensure_trailing_newline = false` for files that need a
    /// strictly-no-trailing-newline format.
    pub ensure_trailing_newline: bool,
}

#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// On quit, save the open editor buffers + cursors to `.mnml/session.json`,
    /// and re-open them on the next launch in the same workspace.
    pub restore: bool,
}

#[derive(Debug, Clone)]
pub struct UiConfig {
    pub theme: String,
    /// Optional alternate theme name. When set, the bufferline's theme-toggle
    /// slider swaps between `theme` ↔ `theme_toggle` (NvChad convention —
    /// users configure a light+dark pair, the button is a 1-press flip).
    /// When `None`, slider click falls back to opening the full theme picker.
    pub theme_toggle: Option<String>,
    pub ascii_icons: bool,
    pub tree_width: u16,
    /// Hybrid relative line numbers — the cursor line shows its absolute number,
    /// every other line the distance from the cursor. `:set relativenumber`.
    pub relative_line_numbers: bool,
    /// Master switch for the line-number gutter. Default `true`. When
    /// `false`, the gutter is hidden entirely and the editor expands to
    /// fill the freed columns. `:set [no]number` runtime toggle.
    pub line_numbers: bool,
    /// Paint a subtle background tint on the cursor's row (vim
    /// `:set cursorline`). Off by default — some users find it noisy.
    pub cursor_line: bool,
    /// Vim `:set scrolloff=N` — keep the cursor at least N lines from
    /// the viewport's top / bottom edge (auto-scroll). Default 0
    /// (vim canonical default; many users set it to 5–10).
    pub scrolloff: usize,
    /// Vim `:set sidescrolloff=N` — horizontal counterpart. Keep cursor
    /// at least N columns from the viewport's left / right edge.
    pub sidescrolloff: usize,
    /// Show visible markers for whitespace (`·` for space, `→` for tab) in the
    /// editor. `:set list` / `:set nolist`. Off by default.
    pub show_whitespace: bool,
    /// Paint matched `()[]{}` brackets in cycling depth colors. `:set rainbow`
    /// / `:set norainbow`. Off by default.
    pub bracket_rainbow: bool,
    /// Master switch for tree-sitter syntax highlighting. `true` (default)
    /// runs the highlighter as usual; `false` paints all editor text in
    /// the theme's foreground color. `:syntax on` / `:syntax off` toggles
    /// at runtime.
    pub syntax: bool,
    /// Show a 1-column vertical scrollbar on the right edge of each editor
    /// pane (track + proportional thumb). `:set [no]scrollbar`. On by default
    /// — costs one column of usable text width.
    pub scrollbar: bool,
    /// Paint trailing whitespace cells with a red background so they're
    /// impossible to miss. `:set [no]trailing`. Off by default — many
    /// codebases intentionally use trailing whitespace (markdown line
    /// breaks, fixtures). Pair with `[editor] trim_trailing_ws_on_save`
    /// for the full "see and strip" loop.
    pub highlight_trailing_ws: bool,
    /// Show a `HH:MM` clock chip in the statusline. Default `true`.
    /// `:set [no]clock` toggles at runtime. Local-time offset is read
    /// from `$TZ_OFFSET_HOURS` (default 0 = UTC).
    pub clock: bool,
    /// When the cursor is on an identifier (`[A-Za-z0-9_]+`), paint other
    /// occurrences of the same word in the visible viewport with a subtle
    /// background tint. Off by default — can be noisy in dense files.
    /// `:set [no]hlword` / `view.toggle_highlight_word`.
    pub highlight_word_under_cursor: bool,
    /// Auto-open the rendered-markdown preview alongside any markdown file
    /// when it's first opened (the same flow as `markdown.preview` /
    /// right-click → "Preview markdown"). Off by default — opt in via
    /// `[ui] auto_md_preview = true` for a writing-focused workflow.
    pub auto_md_preview: bool,
    /// Paint a subtle column marker (the theme's `bg2` background) at this
    /// 1-based column on every line. `0` = off (default); `80` for the
    /// classic line-length hint. Vim's `:set colorcolumn=N` / `:set cc=N`.
    /// Toggles at runtime via `view.toggle_color_column`.
    pub color_column: usize,
    /// When true, render long lines wrapped to multiple visual rows
    /// instead of clipping at the viewport's right edge. Vim's `:set wrap`
    /// / `:set nowrap` / `:set wrap!`. Char-break (no word-boundary
    /// heuristic) — the simplest correct mode. `h_scroll` is forced to
    /// 0 when wrap is on.
    pub wrap: bool,
    /// When true, paint `TODO` / `FIXME` / `HACK` / `XXX` keywords in
    /// bright red/bold across every visible line. Whole-word match. Off
    /// by default (some users find it noisy). `:set [no]todohl` /
    /// `view.toggle_todo_highlight`.
    pub highlight_todo_keywords: bool,
    /// When true, paint inline markdown decorations (heading-line bold +
    /// colored, `**bold**` rendered bold with markers dimmed, `*italic*`
    /// italic with markers dimmed, `` `code` `` with bg2 background,
    /// `[text](url)` rendered as just `text` colored as a link) IN the
    /// editor pane — render-markdown.nvim style. Off by default — the
    /// markdown preview pane (`Pane::MdPreview`) is the canonical
    /// rendering. `:set [no]rendermarkdown` / `view.toggle_render_markdown`.
    pub render_markdown: bool,
    /// Sticky scope context — when on, paints the enclosing scope chain
    /// (functions / classes / methods that contain the cursor's line) as
    /// dim header rows at the top of each editor pane. Reuses
    /// `regex_outline::extract_symbols` so it works on rust/py/js/ts/go/
    /// rb/c/cpp without an LSP. Off by default — useful in long files but
    /// noisy for short ones. `:set [no]stickycontext` / `:set stickycontext!` /
    /// `view.toggle_sticky_context`.
    pub sticky_context: bool,
    /// Number of rows reserved for inline image embeds in markdown
    /// preview (`![alt](path)`). Default 12 — picked to be unobtrusive
    /// inside paragraphs. Bump for note files with screenshots; reduce
    /// for terse docs with many small thumbnails.
    pub md_image_rows: u16,
    /// Override the auto-sized branch/tag column width in `Pane::GitGraph`.
    /// `None` ⇒ size to fit visible refs (clamped 10..=35). `Some(0)`
    /// disables the column entirely.
    pub git_graph_branch_col: Option<usize>,
    /// Override the auto-sized author column width. `None` ⇒ size to fit
    /// visible authors (clamped 8..=22). `Some(0)` disables it.
    pub git_graph_author_col: Option<usize>,
    /// Override the right-side detail panel width. `None` ⇒ 40% of pane
    /// width (clamped 30..=70). The list area gets `pane_width - detail`.
    pub git_graph_detail_col: Option<usize>,
    /// Where the fuzzy picker / command palette anchors. `"center"`
    /// (default) floats it a bit above center; `"top"` drops it flush
    /// with the top edge — the common modern quick-open convention
    /// (palette appears where your eyes reach for it, and
    /// doesn't cover the code below). Any other value falls back to
    /// `"center"`.
    pub picker_position: String,
    /// Configurable launcher-icon strip on the right side of the
    /// bufferline. Each entry renders as a 4-cell colored chip that
    /// runs `command` on click. Default has Claude Code + Codex; users
    /// can append entries via `[[ui.launcher_icon]]` in their config to
    /// add `host.launch <binary>` shortcuts for blit-host integrations
    /// (database viewers, ticket viewers, etc.) or any registered
    /// command. See [`LauncherIcon`].
    pub launcher_icons: Vec<LauncherIcon>,
    /// Plain-glyph icons stacked in the rail's INTEGRATIONS section
    /// (under GIT). Each runs `command` on click; no chip background.
    /// Defaults empty — populate via `[[ui.integration_icon]]` entries
    /// for shortcuts to Jira, Bitbucket, GitHub Actions, DB viewers,
    /// etc. See [`IntegrationIcon`].
    pub integration_icons: Vec<IntegrationIcon>,
    /// Per-project ticket-key prefixes — when set, pty session tabs
    /// (Claude Code / shell / Codex / etc.) WITHOUT a user-set name get
    /// their label auto-filled from the most-recently-mentioned ticket
    /// token in the session's visible scrollback. E.g. with
    /// `["TE-", "PROJ-"]`, a Claude Code session discussing `TE-1234`
    /// shows `TE-1234` as its tab label. The user's explicit `:rename`
    /// always wins.
    ///
    /// Empty (default) disables auto-naming entirely. Format: `["PFX-"]`
    /// — the prefix as it appears in tickets (including the trailing
    /// hyphen, since the digits follow it).
    ///
    /// ```toml
    /// [ui]
    /// ticket_prefixes = ["TE-", "MIX-", "PROJ-"]
    /// ```
    pub ticket_prefixes: Vec<String>,

    /// When true, mnml pings the GitHub releases API in the
    /// background on launch and shows a one-shot toast if a
    /// newer tag exists than the running version. Disabled by
    /// default in dev builds (Cargo.toml version often runs
    /// ahead of the latest tag).
    ///
    /// ```toml
    /// [ui]
    /// check_updates = false  # opt out of the network call
    /// ```
    pub check_updates: bool,

    /// File-tree hover-preview: paint a small thumbnail card at the
    /// bottom of the rail when the tree cursor sits on an image file
    /// (PNG / JPEG / GIF / WebP / BMP) for ≥250 ms. Requires a
    /// terminal that speaks Kitty graphics, iTerm2 inline images, or
    /// sixel (mnml auto-detects; force a protocol via
    /// `$MNML_IMAGE_PROTOCOL`). Default on; set to `false` to skip
    /// the decode + paint entirely.
    pub tree_image_preview: bool,

    /// Which source the statusline `♪` miniplayer reads from.
    /// `"auto"` (default) — mixr first, then macOS Music / Spotify.
    /// `"mixr"` — only the sibling mixr DJ app (`~/.mixr/quick.txt`).
    /// `"macos"` — only macOS Music / Spotify via AppleScript.
    ///
    /// Use `"mixr"` or `"macos"` to skip the other source's poll —
    /// noticeable when the macOS variant is the slow one (`osascript`
    /// shell-out) and you're not playing through Music / Spotify.
    ///
    /// ```toml
    /// [ui]
    /// now_playing_source = "mixr"
    /// ```
    pub now_playing_source: String,
}

/// One entry in the rail's INTEGRATIONS section. Same shape as
/// [`LauncherIcon`] but rendered as a plain monochrome glyph instead
/// of a colored chip — fits the muted "quick-launch row" aesthetic.
///
/// ```toml
/// [[ui.integration_icon]]
/// id       = "jira"
/// glyph    = "\U000F0411"            # nf-md-jira (TOML 8-digit form)
/// fallback = "J"
/// command  = ":host.launch jira-viewer"
/// color    = "blue"
/// tooltip  = "Open Jira board"
/// ```
///
/// **TOML escape syntax for nerd-font codepoints**: TOML uses
/// `"\uXXXX"` (4 hex digits, BMP only) or `"\UXXXXXXXX"` (8 hex
/// digits, full Unicode, zero-padded). Do NOT use Rust's
/// `"\u{XXXXX}"` brace form — TOML will reject it as `invalid
/// unicode 4-digit hex code`. Nerd-Fonts v3 codepoints land in the
/// supplemental range (U+F0000–U+F1FFF), so they almost always
/// need the 8-digit form: `nf-md-jira` = `"\U000F0411"`,
/// `nf-md-music` = `"\U000F1011"`, etc.
#[derive(Debug, Clone)]
pub struct IntegrationIcon {
    pub id: String,
    pub glyph: String,
    pub fallback: String,
    pub command: String,
    pub color: String,
    pub tooltip: Option<String>,
}

/// One entry in the bufferline's right-side launcher-icon strip.
///
/// ```toml
/// # An icon for a private blit-host binary you've built locally:
/// [[ui.launcher_icon]]
/// id       = "myapp"
/// glyph    = "\U000F0668"       # nf-md-test-tube (TOML 8-digit form)
/// fallback = "MA"               # when --ascii / [ui] ascii_icons = true
/// command  = ":host.launch myapp"  # leading `:` ⇒ ex-cmdline string
/// color    = "teal"             # theme slot name for the chip bg
/// tooltip  = "My private blit-host app"
///
/// # Or fire any registered command directly (no leading `:`):
/// [[ui.launcher_icon]]
/// id       = "mixr"
/// glyph    = "\U000F1011"       # nf-md-music (TOML 8-digit form)
/// fallback = "♪"
/// command  = "mixr.show"
/// color    = "purple"
/// ```
#[derive(Debug, Clone)]
pub struct LauncherIcon {
    /// Stable identifier — used for the hover-tooltip rect key + as a
    /// debug hint. Should be unique within the strip.
    pub id: String,
    /// Nerd-Font glyph (single char, e.g. `"\u{F0E2D}"`). The 4-cell
    /// chip paints the glyph centred on a colored background.
    pub glyph: String,
    /// ASCII fallback when `[ui] ascii_icons = true` or `--ascii` is on.
    /// Typically 1-2 chars (e.g. `"CC"`).
    pub fallback: String,
    /// What to fire on click. Either a registered command id
    /// (`"ai.claude_code"`, `"mixr.show"`) or a colon-prefixed cmdline
    /// string that goes through `run_ex_command` (`":host.launch /bin"`).
    pub command: String,
    /// Theme slot name for the chip background. Recognized: `"orange"`,
    /// `"cyan"`, `"blue"`, `"green"`, `"yellow"`, `"purple"`, `"red"`,
    /// `"teal"`, `"bg2"`. Anything else falls back to `bg2` (dark chip).
    pub color: String,
    /// Optional hover-tooltip text. When `None`, the tooltip shows
    /// the `command` string verbatim as a debug hint.
    pub tooltip: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            editor: EditorConfig {
                input_style: "standard".to_string(),
                tab_width: 4,
                autosave_secs: 0,
                trim_trailing_ws_on_save: false,
                breadcrumb: true,
                auto_pair: false,
                auto_indent: true,
                format_on_save: false,
                will_save_wait_until: false,
                format_on_type: false,
                autosave_on_focus_loss: false,
                inlay_hints: true,
                semantic_tokens_viewport: false,
                code_lens: true,
                text_width: 80,
                ensure_trailing_newline: true,
            },
            ui: UiConfig {
                theme: "onedark".to_string(),
                theme_toggle: None,
                ascii_icons: false,
                tree_width: 30,
                relative_line_numbers: false,
                line_numbers: true,
                cursor_line: false,
                scrolloff: 0,
                sidescrolloff: 0,
                show_whitespace: false,
                syntax: true,
                bracket_rainbow: false,
                scrollbar: true,
                highlight_trailing_ws: false,
                clock: true,
                highlight_word_under_cursor: false,
                auto_md_preview: false,
                color_column: 0,
                wrap: false,
                highlight_todo_keywords: false,
                render_markdown: false,
                sticky_context: false,
                md_image_rows: 12,
                git_graph_branch_col: None,
                git_graph_author_col: None,
                git_graph_detail_col: None,
                picker_position: "center".to_string(),
                // Launcher chips on the bufferline-right are empty by
                // default now — Claude + Codex moved into INTEGRATIONS
                // (rail) below. Users can still add chips here via
                // `[[ui.launcher_icon]]`.
                launcher_icons: vec![],
                // Default INTEGRATIONS row — Claude / Codex / Bitbucket /
                // GitHub. Replace or extend via `[[ui.integration_icon]]`
                // in user config; empty array there removes the section.
                // Only Claude + Codex are mnml-patched-only glyphs (PUA
                // U+F8B0 / U+F8B1) — users on vanilla JetBrainsMono Nerd
                // Font see blank cells there, so their fallbacks evoke
                // the brand with basic Unicode. The other entries
                // (Bitbucket E703, HTTP F1D8B, Playwright F0668,
                // CodeBuild F0492, GitHub F02A4) all ship with stock
                // Nerd Fonts; their `fallback` is just `--ascii`-mode
                // text and stays the boring single-char form.
                integration_icons: vec![
                    IntegrationIcon {
                        id: "claude_code".to_string(),
                        // Branded Claude Spark glyph patched into the
                        // user's Nerd Font at U+F8B0 by
                        // `scripts/patch_nerd_font.py`. Fallback `✻` is
                        // the heavy-teardrop-spoked asterisk Claude's
                        // CLI prints while thinking — Claude-recognizable
                        // shape with no Nerd Font required.
                        glyph: "\u{F8B0}".to_string(),
                        fallback: "\u{273B}".to_string(),
                        command: "ai.claude_code".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Claude Code".to_string()),
                    },
                    IntegrationIcon {
                        id: "codex".to_string(),
                        // Branded Codex glyph (cloud + `>_`) patched at
                        // U+F8B1. Fallback `▶_` evokes a terminal cursor
                        // — the OpenAI Codex CLI brand has the same
                        // `>_` motif in its wordmark.
                        glyph: "\u{F8B1}".to_string(),
                        fallback: "\u{25B8}_".to_string(),
                        command: "ai.codex".to_string(),
                        color: "cyan".to_string(),
                        tooltip: Some("Codex".to_string()),
                    },
                    IntegrationIcon {
                        id: "bitbucket".to_string(),
                        glyph: "\u{E703}".to_string(), // nf-dev-bitbucket
                        fallback: "B".to_string(),
                        // Launches the standalone mnml-forge-bitbucket
                        // viewer as a blit-host pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-bitbucket`).
                        command: ":host.launch mnml-forge-bitbucket".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Bitbucket pipelines + PRs".to_string()),
                    },
                    IntegrationIcon {
                        id: "jira".to_string(),
                        glyph: "\u{F0411}".to_string(), // nf-md-jira
                        fallback: "J".to_string(),
                        // Launches the standalone mnml-tracker-jira
                        // viewer as a blit-host pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-tracker-jira`)
                        // and a populated `~/.config/mnml-tracker-jira{.toml,/token}`.
                        command: ":host.launch mnml-tracker-jira".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Jira tracker".to_string()),
                    },
                    IntegrationIcon {
                        id: "http".to_string(),
                        // `\u{F1D8}` (nf-fa-paper_plane) is in every
                        // Nerd Font variant — was using `\u{F1D8B}`
                        // (nf-md-send) which is only in newer MDI
                        // ranges and missing from some standard Nerd
                        // Font Mono builds (renders as tofu / ?).
                        glyph: "\u{F1D8}".to_string(),
                        fallback: "→".to_string(),
                        command: "http.send".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("HTTP: send active request".to_string()),
                    },
                    IntegrationIcon {
                        id: "codebuild".to_string(),
                        glyph: "\u{F0492}".to_string(), // nf-md-hammer-wrench
                        fallback: "C".to_string(),
                        // Launches the standalone mnml-aws-codebuild
                        // viewer as a blit-host pane. User must have
                        // it installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-aws-codebuild`).
                        command: ":host.launch mnml-aws-codebuild".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("AWS CodeBuild + logs".to_string()),
                    },
                    IntegrationIcon {
                        id: "github".to_string(),
                        glyph: "\u{F02A4}".to_string(), // nf-md-github
                        fallback: "G".to_string(),
                        // Launches the standalone mnml-forge-github
                        // viewer as a blit-host pane. User must have
                        // it installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-github`).
                        command: ":host.launch mnml-forge-github".to_string(),
                        color: "fg".to_string(),
                        tooltip: Some("GitHub Actions + PRs".to_string()),
                    },
                    IntegrationIcon {
                        id: "azdevops".to_string(),
                        glyph: "\u{EBE8}".to_string(), // nf-cod-azure
                        fallback: "A".to_string(),
                        // Launches the standalone mnml-forge-azdevops
                        // viewer as a blit-host pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-azdevops`).
                        command: ":host.launch mnml-forge-azdevops".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Azure DevOps PRs + builds".to_string()),
                    },
                    IntegrationIcon {
                        id: "gitlab".to_string(),
                        glyph: "\u{F296}".to_string(), // nf-fa-gitlab
                        fallback: "L".to_string(),
                        // Launches the standalone mnml-forge-gitlab
                        // viewer as a blit-host pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-gitlab`).
                        command: ":host.launch mnml-forge-gitlab".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("GitLab MRs + Pipelines".to_string()),
                    },
                    IntegrationIcon {
                        id: "s3".to_string(),
                        glyph: "\u{F0EBC}".to_string(), // nf-md-aws
                        fallback: "S3".to_string(),
                        // Launches the standalone mnml-fs-s3 viewer
                        // as a blit-host pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-fs-s3`).
                        command: ":host.launch mnml-fs-s3".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Amazon S3 browser".to_string()),
                    },
                    IntegrationIcon {
                        id: "azure_blob".to_string(),
                        glyph: "\u{F0805}".to_string(), // nf-md-microsoft_azure
                        fallback: "Az".to_string(),
                        command: ":host.launch mnml-fs-azure-blob".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Azure Blob Storage browser".to_string()),
                    },
                    // Terminal-native diagnostic tools. Under tmnl
                    // they spawn as sibling tabs; standalone they
                    // open as Pty panes inside mnml's layout. The
                    // sidebar filter shows them only when the binary
                    // is on PATH (`integration_detect`).
                    IntegrationIcon {
                        id: "htop".to_string(),
                        glyph: "\u{F085A}".to_string(), // nf-md-monitor_dashboard
                        fallback: "ht".to_string(),
                        command: ":tools.htop".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("htop — interactive process viewer".to_string()),
                    },
                    IntegrationIcon {
                        id: "iftop".to_string(),
                        glyph: "\u{F048D}".to_string(), // nf-md-network
                        fallback: "if".to_string(),
                        command: ":tools.iftop".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "iftop — interactive bandwidth monitor (needs raw-socket privs)"
                                .to_string(),
                        ),
                    },
                    IntegrationIcon {
                        id: "datadog".to_string(),
                        glyph: "\u{F1A0F}".to_string(), // nf-md-dog
                        fallback: "Dd".to_string(),
                        command: ":host.launch mnml-obs-datadog".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some(
                            "Datadog — monitors + dashboards + logs + incidents".to_string(),
                        ),
                    },
                    IntegrationIcon {
                        id: "buttondown".to_string(),
                        glyph: "\u{F0EB1}".to_string(), // nf-md-email_newsletter
                        fallback: "Bd".to_string(),
                        command: ":host.launch mnml-msg-buttondown".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("Buttondown — drafts + sent + subscribers".to_string()),
                    },
                    IntegrationIcon {
                        id: "cloudwatch_logs".to_string(),
                        glyph: "\u{F0E5C}".to_string(), // nf-md-text-box-search
                        fallback: "CW".to_string(),
                        command: ":host.launch mnml-aws-cloudwatch-logs".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("CloudWatch Logs live tail".to_string()),
                    },
                    IntegrationIcon {
                        id: "amplify".to_string(),
                        glyph: "\u{F087D}".to_string(), // nf-md-rocket-launch
                        fallback: "Am".to_string(),
                        command: ":host.launch mnml-aws-amplify".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some("Amplify apps + deploys".to_string()),
                    },
                    IntegrationIcon {
                        id: "dynamodb".to_string(),
                        glyph: "\u{F1C0}".to_string(), // nf-fa-database
                        fallback: "Dy".to_string(),
                        command: ":host.launch mnml-db-dynamodb".to_string(),
                        color: "teal".to_string(),
                        tooltip: Some("DynamoDB table browser".to_string()),
                    },
                    IntegrationIcon {
                        id: "lambda".to_string(),
                        glyph: "\u{F0EBF}".to_string(), // nf-md-lambda
                        fallback: "La".to_string(),
                        command: ":host.launch mnml-aws-lambda".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Lambda function browser".to_string()),
                    },
                    IntegrationIcon {
                        id: "eventbridge".to_string(),
                        glyph: "\u{F0CE0}".to_string(), // nf-md-bus
                        fallback: "EB".to_string(),
                        command: ":host.launch mnml-aws-eventbridge".to_string(),
                        color: "pink".to_string(),
                        tooltip: Some("EventBridge buses + rules".to_string()),
                    },
                    IntegrationIcon {
                        id: "rds".to_string(),
                        glyph: "\u{F1C0}".to_string(), // nf-fa-database
                        fallback: "RD".to_string(),
                        command: ":host.launch mnml-aws-rds".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("RDS database browser".to_string()),
                    },
                    IntegrationIcon {
                        id: "ecs".to_string(),
                        glyph: "\u{F0F12}".to_string(), // nf-md-server
                        fallback: "EC".to_string(),
                        command: ":host.launch mnml-aws-ecs".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("ECS clusters + services".to_string()),
                    },
                    IntegrationIcon {
                        id: "ecr".to_string(),
                        glyph: "\u{F03D7}".to_string(), // nf-md-archive
                        fallback: "ER".to_string(),
                        command: ":host.launch mnml-aws-ecr".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some("ECR container registry".to_string()),
                    },
                    IntegrationIcon {
                        id: "cognito".to_string(),
                        glyph: "\u{F0004}".to_string(), // nf-md-account_circle
                        fallback: "Co".to_string(),
                        command: ":host.launch mnml-aws-cognito".to_string(),
                        color: "cyan".to_string(),
                        tooltip: Some("Cognito User Pools + users".to_string()),
                    },
                    IntegrationIcon {
                        id: "sqs".to_string(),
                        glyph: "\u{F09FE}".to_string(), // nf-md-mailbox_outline
                        fallback: "Sq".to_string(),
                        command: ":host.launch mnml-aws-sqs".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("SQS queues".to_string()),
                    },
                    IntegrationIcon {
                        id: "sns".to_string(),
                        glyph: "\u{F0A0F}".to_string(), // nf-md-bullhorn_outline
                        fallback: "Sn".to_string(),
                        command: ":host.launch mnml-aws-sns".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("SNS topics + subscriptions".to_string()),
                    },
                    // mixr is family — the rail chip launches it as a
                    // docked panel via the `mixr.show` palette command
                    // (uses the mixr_host code path, not the generic
                    // blit-host `:host.launch`).
                    IntegrationIcon {
                        id: "mixr".to_string(),
                        glyph: "\u{F075A}".to_string(), // nf-md-music_note
                        fallback: "♪".to_string(),
                        command: ":mixr.show".to_string(),
                        color: "pink".to_string(),
                        tooltip: Some("mixr DJ panel".to_string()),
                    },
                    // HTTP client is built into mnml core. The rail
                    // chip fires `:http.send` which targets the
                    // focused buffer (open a .http / .curl / .rest
                    // file first); the user's muscle memory is the
                    // existing `<leader>h` chord set.
                    IntegrationIcon {
                        id: "http".to_string(),
                        glyph: "\u{F0590}".to_string(), // nf-md-web
                        fallback: "ht".to_string(),
                        command: ":http.send".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("HTTP client (built-in)".to_string()),
                    },
                ],
                ticket_prefixes: Vec::new(),
                check_updates: true,
                tree_image_preview: true,
                now_playing_source: "auto".to_string(),
            },
            session: SessionConfig { restore: true },
            keys: BTreeMap::new(),
            lsp: BTreeMap::new(),
            ai: toml::Value::Table(Default::default()),
            tools: toml::Value::Table(Default::default()),
            tasks: BTreeMap::new(),
            startup_tasks: Vec::new(),
            snippets: BTreeMap::new(),
            abbreviations: BTreeMap::new(),
            formatters: BTreeMap::new(),
            linters: BTreeMap::new(),
            dap: BTreeMap::new(),
            browser: BrowserConfig {
                headless: false,
                profile_mode: "workspace".to_string(),
            },
            playwright: PlaywrightConfig::default(),
            ci: CiConfig::default(),
            workspaces: Vec::new(),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct RawConfig {
    #[serde(default)]
    editor: RawEditor,
    #[serde(default)]
    ui: RawUi,
    #[serde(default)]
    keys: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    lsp: BTreeMap<String, toml::Value>,
    #[serde(default)]
    ai: Option<toml::Value>,
    #[serde(default)]
    tools: Option<toml::Value>,
    #[serde(default)]
    tasks: BTreeMap<String, RawTask>,
    #[serde(default)]
    startup: RawStartup,
    #[serde(default)]
    session: RawSession,
    #[serde(default)]
    snippets: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    abbr: BTreeMap<String, String>,
    #[serde(default)]
    formatters: BTreeMap<String, crate::formatter::FormatterEntry>,
    #[serde(default)]
    linters: BTreeMap<String, crate::linter::LinterEntry>,
    #[serde(default)]
    dap: BTreeMap<String, toml::Value>,
    #[serde(default)]
    browser: RawBrowser,
    #[serde(default)]
    ci: RawCi,
    #[serde(default)]
    workspaces: Vec<RawWorkspace>,
}

#[derive(Debug, Default, Deserialize)]
struct RawWorkspace {
    name: Option<String>,
    path: String,
}

#[derive(Debug, Default, Deserialize)]
struct RawCi {
    provider: Option<String>,
    project: Option<String>,
    region: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawBrowser {
    headless: Option<bool>,
    profile_mode: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawSession {
    restore: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawTask {
    cmd: String,
    cwd: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawStartup {
    #[serde(default)]
    tasks: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawEditor {
    input_style: Option<String>,
    tab_width: Option<usize>,
    autosave_secs: Option<u64>,
    trim_trailing_ws_on_save: Option<bool>,
    breadcrumb: Option<bool>,
    auto_pair: Option<bool>,
    auto_indent: Option<bool>,
    format_on_save: Option<bool>,
    will_save_wait_until: Option<bool>,
    format_on_type: Option<bool>,
    autosave_on_focus_loss: Option<bool>,
    inlay_hints: Option<bool>,
    semantic_tokens_viewport: Option<bool>,
    code_lens: Option<bool>,
    text_width: Option<usize>,
    ensure_trailing_newline: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUi {
    theme: Option<String>,
    theme_toggle: Option<String>,
    ascii_icons: Option<bool>,
    tree_width: Option<u16>,
    relative_line_numbers: Option<bool>,
    line_numbers: Option<bool>,
    cursor_line: Option<bool>,
    scrolloff: Option<usize>,
    sidescrolloff: Option<usize>,
    show_whitespace: Option<bool>,
    syntax: Option<bool>,
    bracket_rainbow: Option<bool>,
    scrollbar: Option<bool>,
    highlight_trailing_ws: Option<bool>,
    clock: Option<bool>,
    highlight_word_under_cursor: Option<bool>,
    auto_md_preview: Option<bool>,
    color_column: Option<usize>,
    wrap: Option<bool>,
    highlight_todo_keywords: Option<bool>,
    render_markdown: Option<bool>,
    sticky_context: Option<bool>,
    md_image_rows: Option<u16>,
    git_graph_branch_col: Option<usize>,
    git_graph_author_col: Option<usize>,
    git_graph_detail_col: Option<usize>,
    picker_position: Option<String>,
    /// Array of `[[ui.launcher_icon]]` entries. When this key is present
    /// (even as `[]`), it **replaces** the built-in Claude+Codex defaults.
    /// Users who just want to *append* can copy the defaults from
    /// `LauncherIcon` docs and add their own entries.
    #[serde(default, rename = "launcher_icon")]
    launcher_icons: Option<Vec<RawLauncherIcon>>,
    /// Array of `[[ui.integration_icon]]` entries for the rail's
    /// INTEGRATIONS section. Replaces the built-in defaults (currently
    /// empty) when present.
    #[serde(default, rename = "integration_icon")]
    integration_icons: Option<Vec<RawLauncherIcon>>,
    /// Ticket prefixes for pty-tab auto-naming. See
    /// [`UiConfig::ticket_prefixes`].
    #[serde(default)]
    ticket_prefixes: Option<Vec<String>>,
    /// Statusline miniplayer source — `"auto"` / `"mixr"` / `"macos"`.
    /// See [`UiConfig::now_playing_source`].
    #[serde(default)]
    now_playing_source: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawLauncherIcon {
    id: Option<String>,
    glyph: Option<String>,
    fallback: Option<String>,
    command: Option<String>,
    color: Option<String>,
    tooltip: Option<String>,
}

impl Config {
    /// Load + merge. Never fails — a malformed file is reported on stderr and skipped.
    pub fn load(explicit: Option<&Path>, workspace: &Path) -> Config {
        let mut cfg = Config::default();
        if let Some(home) = home_config_path() {
            cfg.apply_file(&home);
        }
        cfg.apply_file(&workspace.join(".mnml").join("config.toml"));
        if let Some(p) = explicit {
            cfg.apply_file(p);
        }
        cfg
    }

    /// Public entry to re-apply a single config file at runtime — `:source
    /// <path>` (vim convention). Layered on top of the current config so
    /// previous values stick if the file omits a key.
    pub fn apply_file_pub(&mut self, path: &Path) {
        self.apply_file(path);
    }

    fn apply_file(&mut self, path: &Path) {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => return, // absent — fine
        };
        let raw: RawConfig = match toml::from_str(&text) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("mnml: ignoring bad config {}: {e}", path.display());
                return;
            }
        };
        if let Some(v) = raw.editor.input_style {
            self.editor.input_style = v;
        }
        if let Some(v) = raw.editor.tab_width {
            self.editor.tab_width = v.max(1);
        }
        if let Some(v) = raw.editor.autosave_secs {
            self.editor.autosave_secs = v;
        }
        if let Some(v) = raw.editor.trim_trailing_ws_on_save {
            self.editor.trim_trailing_ws_on_save = v;
        }
        if let Some(v) = raw.editor.breadcrumb {
            self.editor.breadcrumb = v;
        }
        if let Some(v) = raw.editor.auto_pair {
            self.editor.auto_pair = v;
        }
        if let Some(v) = raw.editor.auto_indent {
            self.editor.auto_indent = v;
        }
        if let Some(v) = raw.editor.format_on_type {
            self.editor.format_on_type = v;
        }
        if let Some(v) = raw.editor.format_on_save {
            self.editor.format_on_save = v;
        }
        if let Some(v) = raw.editor.will_save_wait_until {
            self.editor.will_save_wait_until = v;
        }
        if let Some(v) = raw.editor.autosave_on_focus_loss {
            self.editor.autosave_on_focus_loss = v;
        }
        if let Some(v) = raw.editor.inlay_hints {
            self.editor.inlay_hints = v;
        }
        if let Some(v) = raw.editor.semantic_tokens_viewport {
            self.editor.semantic_tokens_viewport = v;
        }
        if let Some(v) = raw.editor.code_lens {
            self.editor.code_lens = v;
        }
        if let Some(v) = raw.editor.text_width {
            self.editor.text_width = v.max(8);
        }
        if let Some(v) = raw.editor.ensure_trailing_newline {
            self.editor.ensure_trailing_newline = v;
        }
        if let Some(v) = raw.ui.theme {
            self.ui.theme = v;
        }
        if let Some(v) = raw.ui.theme_toggle {
            self.ui.theme_toggle = Some(v);
        }
        if let Some(v) = raw.ui.ascii_icons {
            self.ui.ascii_icons = v;
        }
        if let Some(v) = raw.ui.tree_width {
            self.ui.tree_width = v.clamp(10, 80);
        }
        if let Some(v) = raw.ui.relative_line_numbers {
            self.ui.relative_line_numbers = v;
        }
        if let Some(v) = raw.ui.line_numbers {
            self.ui.line_numbers = v;
        }
        if let Some(v) = raw.ui.cursor_line {
            self.ui.cursor_line = v;
        }
        if let Some(v) = raw.ui.scrolloff {
            self.ui.scrolloff = v;
        }
        if let Some(v) = raw.ui.sidescrolloff {
            self.ui.sidescrolloff = v;
        }
        if let Some(v) = raw.ui.show_whitespace {
            self.ui.show_whitespace = v;
        }
        if let Some(v) = raw.ui.syntax {
            self.ui.syntax = v;
        }
        if let Some(v) = raw.ui.bracket_rainbow {
            self.ui.bracket_rainbow = v;
        }
        if let Some(v) = raw.ui.scrollbar {
            self.ui.scrollbar = v;
        }
        if let Some(v) = raw.ui.highlight_trailing_ws {
            self.ui.highlight_trailing_ws = v;
        }
        if let Some(v) = raw.ui.clock {
            self.ui.clock = v;
        }
        if let Some(v) = raw.ui.highlight_word_under_cursor {
            self.ui.highlight_word_under_cursor = v;
        }
        if let Some(v) = raw.ui.auto_md_preview {
            self.ui.auto_md_preview = v;
        }
        if let Some(v) = raw.ui.color_column {
            self.ui.color_column = v;
        }
        if let Some(v) = raw.ui.wrap {
            self.ui.wrap = v;
        }
        if let Some(v) = raw.ui.highlight_todo_keywords {
            self.ui.highlight_todo_keywords = v;
        }
        if let Some(v) = raw.ui.render_markdown {
            self.ui.render_markdown = v;
        }
        if let Some(v) = raw.ui.sticky_context {
            self.ui.sticky_context = v;
        }
        if let Some(v) = raw.ui.md_image_rows {
            self.ui.md_image_rows = v.clamp(2, 100);
        }
        if raw.ui.git_graph_branch_col.is_some() {
            self.ui.git_graph_branch_col = raw.ui.git_graph_branch_col;
        }
        if raw.ui.git_graph_author_col.is_some() {
            self.ui.git_graph_author_col = raw.ui.git_graph_author_col;
        }
        if raw.ui.git_graph_detail_col.is_some() {
            self.ui.git_graph_detail_col = raw.ui.git_graph_detail_col;
        }
        if let Some(v) = raw.ui.picker_position {
            self.ui.picker_position = v;
        }
        // `[[ui.launcher_icon]]` replaces the built-in defaults entirely
        // when set — that lets users start from scratch. Empty array is
        // valid and means "no launcher icons at all."
        if let Some(raws) = raw.ui.launcher_icons {
            self.ui.launcher_icons = raws
                .into_iter()
                .filter_map(|r| {
                    let glyph = r.glyph?;
                    let command = r.command?;
                    // Generate a stable id from the command if not given.
                    let id = r.id.unwrap_or_else(|| {
                        command
                            .trim_start_matches(':')
                            .split_whitespace()
                            .next()
                            .unwrap_or("launcher")
                            .to_string()
                    });
                    Some(LauncherIcon {
                        id,
                        glyph,
                        fallback: r.fallback.unwrap_or_else(|| "*".to_string()),
                        command,
                        color: r.color.unwrap_or_else(|| "bg2".to_string()),
                        tooltip: r.tooltip,
                    })
                })
                .collect();
        }
        // `[[ui.integration_icon]]` — rail INTEGRATIONS section. Same
        // shape, same merge rule (presence replaces defaults).
        if let Some(raws) = raw.ui.integration_icons {
            self.ui.integration_icons = raws
                .into_iter()
                .filter_map(|r| {
                    let glyph = r.glyph?;
                    let command = r.command?;
                    let id = r.id.unwrap_or_else(|| {
                        command
                            .trim_start_matches(':')
                            .split_whitespace()
                            .next()
                            .unwrap_or("integration")
                            .to_string()
                    });
                    Some(IntegrationIcon {
                        id,
                        glyph,
                        fallback: r.fallback.unwrap_or_else(|| "*".to_string()),
                        command,
                        color: r.color.unwrap_or_else(|| "fg".to_string()),
                        tooltip: r.tooltip,
                    })
                })
                .collect();
        }
        // `ticket_prefixes` — pty-tab auto-naming from scrollback.
        // Replaces the default (empty list) when set. Blank entries are
        // stripped at load time so users don't have to worry about it.
        if let Some(raws) = raw.ui.ticket_prefixes {
            self.ui.ticket_prefixes = raws
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        // `now_playing_source` — `"auto"` (default) / `"mixr"` / `"macos"`.
        // Unknown values fall back to the existing setting (so a typo
        // doesn't silently switch the source).
        if let Some(s) = raw.ui.now_playing_source {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "auto" | "mixr" | "macos") {
                self.ui.now_playing_source = normalized;
            }
        }
        if let Some(v) = raw.session.restore {
            self.session.restore = v;
        }
        for (k, v) in raw.keys {
            self.keys.entry(k).or_default().extend(v);
        }
        for (k, v) in raw.lsp {
            self.lsp.insert(k, v);
        }
        if let Some(v) = raw.ai {
            self.ai = v;
        }
        if let Some(v) = raw.tools {
            self.tools = v;
        }
        for (k, v) in raw.tasks {
            self.tasks.insert(
                k,
                TaskDef {
                    cmd: v.cmd,
                    cwd: v.cwd,
                },
            );
        }
        self.startup_tasks.extend(raw.startup.tasks);
        for (scope, map) in raw.snippets {
            self.snippets.entry(scope).or_default().extend(map);
        }
        for (k, v) in raw.abbr {
            self.abbreviations.insert(k, v);
        }
        for (ext, entry) in raw.formatters {
            self.formatters.insert(ext, entry);
        }
        for (ext, entry) in raw.linters {
            self.linters.insert(ext, entry);
        }
        for (name, v) in raw.dap {
            self.dap.insert(name, v);
        }
        if let Some(v) = raw.browser.headless {
            self.browser.headless = v;
        }
        if let Some(v) = raw.browser.profile_mode {
            // Validate the enum; unknown values silently fall back to
            // the default ("workspace") rather than rejecting the
            // whole config file.
            self.browser.profile_mode = match v.as_str() {
                "workspace" | "shared" | "ephemeral" => v,
                _ => "workspace".to_string(),
            };
        }
        if let Some(v) = raw.ci.provider {
            self.ci.provider = Some(v);
        }
        if let Some(v) = raw.ci.project {
            self.ci.project = Some(v);
        }
        if let Some(v) = raw.ci.region {
            self.ci.region = Some(v);
        }
        // `[bitbucket]` section is silently ignored — Bitbucket panes
        // moved to the standalone mnml-forge-bitbucket binary in
        // 2026-06; existing user configs may still mention it.
        // `[github]` section is silently ignored — GitHub panes
        // moved to the standalone mnml-forge-github binary in
        // 2026-06; existing user configs may still mention it.
        // `[gitlab]` section is silently ignored — GitLab panes
        // moved to mnml-forge-gitlab in 2026-06.
        // `[azdevops]` section is silently ignored — Azure DevOps
        // panes moved to mnml-forge-azdevops in 2026-06.
        // `[[workspaces]]` — additional sibling workspaces. Append (rather
        // than replace) so a workspace-local file can extend the homedir
        // set. Tilde-expanded so users can write `~/Projects/foo`. Missing
        // dirs are tolerated at config-load time (App::new logs + skips
        // the unloadable ones).
        for w in raw.workspaces {
            let expanded = expand_tilde(&w.path);
            let name = w.name.unwrap_or_else(|| {
                expanded
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| w.path.clone())
            });
            self.workspaces.push(WorkspaceConfig {
                name,
                path: expanded,
            });
        }
    }
}

fn expand_tilde(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(s)
}

/// Public counterpart of [`home_config_path`] — exposed so `file.open_settings`
/// can resolve the same path as [`Config::load`].
pub fn user_config_path() -> Option<PathBuf> {
    home_config_path()
}

fn home_config_path() -> Option<PathBuf> {
    // Respect $XDG_CONFIG_HOME, else ~/.config.
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return Some(PathBuf::from(xdg).join("mnml").join("config.toml"));
    }
    std::env::var_os("HOME").map(|h| {
        PathBuf::from(h)
            .join(".config")
            .join("mnml")
            .join("config.toml")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn workspaces_config_parses_and_appends() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[[workspaces]]
name = "work"
path = "/tmp/work-stuff"

[[workspaces]]
path = "/tmp/mnml-stuff"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(cfg.workspaces.len(), 2);
        assert_eq!(cfg.workspaces[0].name, "work");
        assert_eq!(
            cfg.workspaces[0].path,
            std::path::PathBuf::from("/tmp/work-stuff")
        );
        // Missing `name` defaults to the path's basename.
        assert_eq!(cfg.workspaces[1].name, "mnml-stuff");

        // A second config file appends (rather than replaces).
        let cfg_path2 = dir.path().join("local.toml");
        let mut f2 = std::fs::File::create(&cfg_path2).unwrap();
        writeln!(
            f2,
            r#"
[[workspaces]]
name  = "extra"
path  = "/tmp/extra"
"#
        )
        .unwrap();
        cfg.apply_file_pub(&cfg_path2);
        assert_eq!(cfg.workspaces.len(), 3);
        assert_eq!(cfg.workspaces[2].name, "extra");
    }

    #[test]
    fn bitbucket_section_silently_ignored() {
        // Bitbucket panes moved to mnml-forge-bitbucket — existing user
        // configs may still mention `[bitbucket]`; parser should not
        // error on the unknown section.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[bitbucket]
auth_env  = "BB_TOKEN"
poll_secs = 60

[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "example-api"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // No assertion needed — the test passes if apply_file_pub
        // didn't panic on the unknown `[bitbucket]` section.
        let _ = cfg;
    }

    #[test]
    fn azdevops_section_silently_ignored() {
        // Azure DevOps panes moved to mnml-forge-azdevops — parser
        // should not error on `[azdevops]` sections in existing user
        // configs.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[azdevops]
auth_env   = "AZDO_TOKEN"

[[azdevops.projects]]
org     = "exampleorg"
project = "Example"
repo    = "api"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        let _ = cfg;
    }

    #[test]
    fn github_section_silently_ignored() {
        // GitHub panes moved to mnml-forge-github — parser should not
        // error on `[github]` sections in existing user configs.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[github]
auth_env  = "GH_TOKEN"
poll_secs = 45

[[github.repos]]
owner = "exampleorg"
repo  = "example-knowledge"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // No assertion needed — passes if apply_file_pub didn't panic.
        let _ = cfg;
    }

    #[test]
    fn default_integration_icons_has_claude_codex_bitbucket_github() {
        // Claude + Codex moved from the bufferline `launcher_icons` to
        // the rail's INTEGRATIONS row (`integration_icons`) so they sit
        // alongside Bitbucket / HTTP / Playwright / CodeBuild / GitHub
        // — see commit bf5c874 for the rail reorg. Launcher icons are
        // now empty by default; integration icons carry the AI + git
        // host defaults.
        let cfg = Config::default();
        assert!(
            cfg.ui.launcher_icons.is_empty(),
            "launcher_icons (bufferline chips) default to empty now"
        );
        let ids: Vec<&str> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        assert!(
            ids.contains(&"claude_code"),
            "integration_icons must include claude_code"
        );
        assert!(
            ids.contains(&"codex"),
            "integration_icons must include codex"
        );
        assert!(
            ids.contains(&"bitbucket"),
            "integration_icons must include bitbucket"
        );
        assert!(
            ids.contains(&"github"),
            "integration_icons must include github"
        );
        // Spot-check the Claude entry to catch glyph/color regressions.
        let claude = cfg
            .ui
            .integration_icons
            .iter()
            .find(|i| i.id == "claude_code")
            .unwrap();
        assert_eq!(claude.command, "ai.claude_code");
        assert_eq!(claude.color, "orange");
    }

    #[test]
    fn launcher_icons_config_replaces_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[[ui.launcher_icon]]
glyph    = "M"
fallback = "MA"
command  = ":host.launch myapp"
color    = "teal"
tooltip  = "myapp browser"

[[ui.launcher_icon]]
id       = "db"
glyph    = "D"
fallback = "DB"
command  = "host.launch psql-viewer"
color    = "purple"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // Setting `[[ui.launcher_icon]]` replaces, not appends — built-in
        // Claude+Codex defaults are gone.
        assert_eq!(cfg.ui.launcher_icons.len(), 2);
        // First entry — id auto-derived from the command's first token
        // when omitted (`host.launch` here, leading `:` stripped).
        assert_eq!(cfg.ui.launcher_icons[0].id, "host.launch");
        assert_eq!(cfg.ui.launcher_icons[0].command, ":host.launch myapp");
        assert_eq!(cfg.ui.launcher_icons[0].color, "teal");
        assert_eq!(
            cfg.ui.launcher_icons[0].tooltip.as_deref(),
            Some("myapp browser")
        );
        // Second entry — explicit id, no leading `:` on command.
        assert_eq!(cfg.ui.launcher_icons[1].id, "db");
        assert_eq!(cfg.ui.launcher_icons[1].command, "host.launch psql-viewer");
        assert!(cfg.ui.launcher_icons[1].tooltip.is_none());
    }

    #[test]
    fn launcher_icons_empty_array_clears_defaults() {
        // `launcher_icon = []` would be ambiguous in TOML; the proper
        // form is no `[[ui.launcher_icon]]` blocks at all + the key
        // set explicitly to an empty array. Verify we accept it.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        // `launcher_icon = []` under `[ui]`.
        writeln!(
            f,
            r#"
[ui]
launcher_icon = []
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert!(cfg.ui.launcher_icons.is_empty());
    }
}
