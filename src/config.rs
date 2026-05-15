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
    pub browser: BrowserConfig,
}

#[derive(Debug, Clone)]
pub struct BrowserConfig {
    /// Launch Chrome with `--headless=new` (no window). The pane still
    /// receives network / console / DOM events; the user drives via `g`
    /// (navigate), `e` (eval), `s` (screenshot), etc. Default off — the
    /// visible window is what most users expect from `browser.open`.
    pub headless: bool,
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
                format_on_type: false,
                autosave_on_focus_loss: false,
                inlay_hints: true,
                code_lens: true,
                text_width: 80,
                ensure_trailing_newline: true,
            },
            ui: UiConfig {
                theme: "onedark".to_string(),
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
            browser: BrowserConfig { headless: false },
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
    browser: RawBrowser,
}

#[derive(Debug, Default, Deserialize)]
struct RawBrowser {
    headless: Option<bool>,
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
    format_on_type: Option<bool>,
    autosave_on_focus_loss: Option<bool>,
    inlay_hints: Option<bool>,
    code_lens: Option<bool>,
    text_width: Option<usize>,
    ensure_trailing_newline: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUi {
    theme: Option<String>,
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
        if let Some(v) = raw.editor.autosave_on_focus_loss {
            self.editor.autosave_on_focus_loss = v;
        }
        if let Some(v) = raw.editor.inlay_hints {
            self.editor.inlay_hints = v;
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
        if let Some(v) = raw.browser.headless {
            self.browser.headless = v;
        }
    }
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
