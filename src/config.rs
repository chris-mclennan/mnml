//! Configuration. Merged from (lowest → highest precedence): built-in defaults,
//! `~/.config/mnml/config.toml`, `<workspace>/.mnml/config.toml`, then `--config PATH`.
//!
//! P0 reads only `[editor]` and `[ui]`. The `[keys.*]`, `[lsp.*]`, `[ai]`, `[tools]`
//! sections are parsed-and-kept (so existing config files keep working) but unused
//! until their tracks land.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct Config {
    pub editor: EditorConfig,
    pub ui: UiConfig,
    /// `[keys.vim]` / `[keys.standard]` — command-id → key spec. Unused in P0.
    pub keys: BTreeMap<String, BTreeMap<String, String>>,
    /// `[lsp.<lang>]` — raw tables, validated by the LSP track later.
    pub lsp: BTreeMap<String, toml::Value>,
    /// `[ai]` / `[tools]` — raw tables, validated by the AI track later.
    pub ai: toml::Value,
    pub tools: toml::Value,
}

#[derive(Debug, Clone)]
pub struct EditorConfig {
    /// `"vim"` or `"standard"`. Anything else falls back to `"standard"` at handler-make time.
    pub input_style: String,
    pub tab_width: usize,
}

#[derive(Debug, Clone)]
pub struct UiConfig {
    pub theme: String,
    pub ascii_icons: bool,
    pub tree_width: u16,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            editor: EditorConfig {
                input_style: "standard".to_string(),
                tab_width: 4,
            },
            ui: UiConfig {
                theme: "onedark".to_string(),
                ascii_icons: false,
                tree_width: 30,
            },
            keys: BTreeMap::new(),
            lsp: BTreeMap::new(),
            ai: toml::Value::Table(Default::default()),
            tools: toml::Value::Table(Default::default()),
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
}

#[derive(Debug, Default, Deserialize)]
struct RawEditor {
    input_style: Option<String>,
    tab_width: Option<usize>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUi {
    theme: Option<String>,
    ascii_icons: Option<bool>,
    tree_width: Option<u16>,
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
        if let Some(v) = raw.ui.theme {
            self.ui.theme = v;
        }
        if let Some(v) = raw.ui.ascii_icons {
            self.ui.ascii_icons = v;
        }
        if let Some(v) = raw.ui.tree_width {
            self.ui.tree_width = v.clamp(10, 80);
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
    }
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
