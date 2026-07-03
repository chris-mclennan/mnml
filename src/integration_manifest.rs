//! Manifest loader for third-party integration siblings.
//!
//! Mirrors [`mount_manifest`] but for the Pty-launcher-style
//! integration icons (things that live in the rail's INTEGRATIONS
//! section — Bitbucket, GitHub, Slack, Datadog, …). Instead of
//! forcing every user to hand-write `[[ui.integration_icon]]`
//! entries in `config.toml`, a sibling ships a manifest and
//! auto-installs it on `<sibling> --install`.
//!
//! ## Where manifests live
//!
//!   1. `<workspace>/.mnml/integrations/<id>.toml` — workspace-local.
//!   2. `~/.config/mnml/integrations/<id>.toml` — user-global.
//!
//! Workspace manifests override user-global on id collision.
//! Explicit `[[ui.integration_icon]]` entries in user config
//! override BOTH (users always win over sibling-authored defaults).
//!
//! ## Full schema
//!
//! ```toml
//! # ── Identity ────────────────────────
//! id          = "slack"                     # unique stable slug
//! name        = "Slack"                     # display
//! description = "Slack browse + post"       # optional
//! version     = "0.1.0"                     # semver — optional
//! binary      = "mnml-msg-slack"            # PATH or absolute
//! category    = "msg"                       # msg/forge/tracker/aws/db/…
//!
//! # ── Rail chip ──────────────────────
//! [chip]
//! glyph          = "9"                # Nerd Font glyph
//! fallback       = "Sk"                     # 2-char text
//! color          = "purple"                 # theme color name
//! tooltip        = "Slack"
//! enabled        = true                     # rendered by default
//! in_palette_bar = false                    # false → INTEGRATIONS section
//! badge_key      = "slack"                  # section id for badges
//!
//! # ── Palette commands ───────────────
//! [[commands]]
//! id    = "slack.open"
//! title = "Slack: open"
//! group = "integrations"                    # optional
//! keys  = ["<leader>iS"]                    # optional; multiple allowed
//! run   = ":term mnml-msg-slack"            # ex-command line
//!
//! # ── Context menu additions ─────────
//! [[context_menu]]
//! target  = "tree.file"                     # tree.file|tree.dir|tab|agent.row|pane
//! title   = "Send via Slack"
//! command = "slack.send_file"
//!
//! # ── Menu-bar entries ───────────────
//! [[menu_bar]]
//! path    = "File > Send via Slack"
//! command = "slack.send_file"
//!
//! # ── Statusline segment (static) ────
//! [statusline]
//! side          = "right"
//! segment_id    = "slack"
//! initial_text  = "◇ slack"
//! initial_color = "comment"
//! click_command = "slack.open"
//!
//! # ── OS notification policy ─────────
//! [notifications]
//! os_notify_on      = "error_only"          # never|error_only|always
//! os_rate_limit_sec = 5                     # min secs between OS pings
//!
//! # ── Environment / preconditions ────
//! [requires]
//! env    = ["SLACK_TOKEN"]                  # dim chip if missing
//! binary = "mnml-msg-slack"                 # PATH-verified at discovery
//! ```

use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Named theme colors the manifest accepts. Unknown values fall
/// back to `cyan` on render. Keeping this small keeps
/// theme-implementation details out of the public manifest
/// surface (same rule mount manifests use).
pub const ALLOWED_COLORS: &[&str] = &[
    "red", "orange", "yellow", "green", "blue", "cyan", "teal", "purple", "pink", "comment",
    "magenta", "fg", "bg2",
];

/// OS notification escalation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OsNotifyPolicy {
    /// OS notifications disabled for this integration.
    #[default]
    Never,
    /// Fire OS notification only when the sibling calls `notify`
    /// with `Level::Error`, or via the auto-escalation rule
    /// (persistent-error → auto-notify).
    ErrorOnly,
    /// Fire OS notification for every `notify` call the sibling
    /// makes, regardless of level. Rate-limited by
    /// `os_rate_limit_sec`.
    Always,
}

/// A whole integration manifest, parsed from one TOML file.
#[derive(Debug, Clone, Deserialize)]
pub struct IntegrationManifest {
    // ── Identity ───────────────────────────────
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    pub binary: String,
    #[serde(default)]
    pub category: Option<String>,

    // ── Registered surfaces ────────────────────
    #[serde(default)]
    pub chip: Option<ChipSpec>,
    #[serde(default)]
    pub commands: Vec<CommandSpec>,
    #[serde(default)]
    pub context_menu: Vec<ContextMenuEntry>,
    #[serde(default)]
    pub menu_bar: Vec<MenuBarEntry>,
    #[serde(default)]
    pub statusline: Option<StatuslineSpec>,
    #[serde(default)]
    pub settings: Vec<SettingsPage>,
    #[serde(default)]
    pub notifications: Option<NotificationsSpec>,
    #[serde(default)]
    pub requires: Option<Requires>,

    // ── Source tracking ────────────────────────
    #[serde(skip)]
    pub source_path: PathBuf,
}

/// The rail chip — what shows up in the INTEGRATIONS section (or
/// the palette bar when `in_palette_bar = true`).
#[derive(Debug, Clone, Deserialize)]
pub struct ChipSpec {
    pub glyph: String,
    pub fallback: String,
    pub color: String,
    #[serde(default)]
    pub tooltip: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub in_palette_bar: bool,
    #[serde(default)]
    pub badge_key: Option<String>,
}

fn default_enabled() -> bool {
    true
}

/// One palette command the integration provides.
#[derive(Debug, Clone, Deserialize)]
pub struct CommandSpec {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub keys: Vec<String>,
    /// Ex-command line to execute when the command fires
    /// (e.g. `":term mnml-msg-slack"` or `"slack.internal_action"`).
    pub run: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ContextMenuEntry {
    /// Target entity — `tree.file`, `tree.dir`, `tab`,
    /// `agent.row`, `pane`. Unknown values ignored at merge time.
    pub target: String,
    pub title: String,
    pub command: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MenuBarEntry {
    /// Slash-separated path like `"File > Send via Slack"`.
    pub path: String,
    pub command: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StatuslineSpec {
    /// `"left"` | `"right"`.
    #[serde(default = "default_side")]
    pub side: String,
    pub segment_id: String,
    #[serde(default)]
    pub initial_text: String,
    #[serde(default)]
    pub initial_color: Option<String>,
    #[serde(default)]
    pub click_command: Option<String>,
    /// Priority for overflow truncation — higher wins. 100 by
    /// default; 200 = "always show", 50 = "nice to have".
    #[serde(default = "default_priority")]
    pub priority: u8,
    /// Minimum width before the segment is dropped entirely.
    #[serde(default = "default_min_width")]
    pub min_width: u16,
    /// Maximum width; longer content gets truncated.
    #[serde(default = "default_max_width")]
    pub max_width: u16,
}

fn default_side() -> String {
    "right".to_string()
}
fn default_priority() -> u8 {
    100
}
fn default_min_width() -> u16 {
    4
}
fn default_max_width() -> u16 {
    30
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingsPage {
    pub section: String,
    pub label: String,
    #[serde(default)]
    pub help: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotificationsSpec {
    #[serde(default)]
    pub os_notify_on: OsNotifyPolicy,
    #[serde(default = "default_rate_limit")]
    pub os_rate_limit_sec: u64,
}

fn default_rate_limit() -> u64 {
    5
}

#[derive(Debug, Clone, Deserialize)]
pub struct Requires {
    #[serde(default)]
    pub env: Vec<String>,
    #[serde(default)]
    pub binary: Option<String>,
}

// ── Loader ──────────────────────────────────────────

/// Scan both manifest dirs and return the merged list. Workspace
/// entries shadow user-global entries with the same id.
pub fn load_all(workspace: &Path) -> Vec<IntegrationManifest> {
    load_all_with_user_base(workspace, user_dir())
}

/// Same as `load_all` but with an explicit user-config base
/// directory (used by tests to isolate from `~/.config/mnml/`).
/// Pass `None` to skip the user-global scan entirely.
pub fn load_all_with_user_base(
    workspace: &Path,
    user_base: Option<PathBuf>,
) -> Vec<IntegrationManifest> {
    let mut out: Vec<IntegrationManifest> = Vec::new();

    // User-global first (lower priority).
    if let Some(dir) = user_base {
        scan_dir(&dir, &mut out);
    }
    // Workspace second (higher priority).
    scan_dir(&workspace.join(".mnml").join("integrations"), &mut out);

    // Dedup by id, keeping the LAST occurrence (workspace wins).
    let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut keep = vec![true; out.len()];
    for (i, m) in out.iter().enumerate() {
        if let Some(&prev) = seen.get(&m.id) {
            keep[prev] = false;
        }
        seen.insert(m.id.clone(), i);
    }
    out.into_iter()
        .enumerate()
        .filter_map(|(i, m)| if keep[i] { Some(m) } else { None })
        .collect()
}

/// User-config dir for integration manifests.
pub fn user_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("mnml")
            .join("integrations"),
    )
}

fn scan_dir(dir: &Path, out: &mut Vec<IntegrationManifest>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        match toml::from_str::<IntegrationManifest>(&text) {
            Ok(mut m) => {
                if m.id.is_empty() || m.name.is_empty() || m.binary.is_empty() {
                    continue;
                }
                // Sanitize unknown chip color → None (renderer
                // will fall back to cyan).
                if let Some(chip) = m.chip.as_mut()
                    && !ALLOWED_COLORS.contains(&chip.color.as_str())
                {
                    chip.color = "cyan".to_string();
                }
                m.source_path = path;
                out.push(m);
            }
            Err(_) => continue,
        }
    }
}

impl IntegrationManifest {
    /// True if this integration's `[requires]` predicates are all
    /// satisfied on the current machine. Used by the discovery
    /// overlay to dim chips whose backing sibling isn't ready
    /// (missing env var, binary not on PATH).
    pub fn is_ready(&self) -> bool {
        let Some(req) = &self.requires else {
            return true;
        };
        for name in &req.env {
            if std::env::var_os(name).is_none() {
                return false;
            }
        }
        if let Some(bin) = &req.binary
            && !binary_on_path(bin)
        {
            return false;
        }
        true
    }
}

fn binary_on_path(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        if dir.join(name).is_file() {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_manifest() {
        let toml = r#"
id = "slack"
name = "Slack"
binary = "mnml-msg-slack"
"#;
        let m: IntegrationManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.id, "slack");
        assert_eq!(m.name, "Slack");
        assert_eq!(m.binary, "mnml-msg-slack");
        assert!(m.chip.is_none());
        assert!(m.commands.is_empty());
        assert!(m.notifications.is_none());
    }

    #[test]
    fn parses_full_manifest() {
        let toml = r#"
id = "slack"
name = "Slack"
description = "Slack browse + post"
version = "0.1.0"
binary = "mnml-msg-slack"
category = "msg"

[chip]
glyph = "S"
fallback = "Sk"
color = "purple"
tooltip = "Slack"
enabled = true
in_palette_bar = false
badge_key = "slack"

[[commands]]
id = "slack.open"
title = "Slack: open"
group = "integrations"
keys = ["<leader>iS"]
run = ":term mnml-msg-slack"

[[context_menu]]
target = "tree.file"
title = "Send via Slack"
command = "slack.send_file"

[statusline]
side = "right"
segment_id = "slack"
initial_text = "◇ slack"
initial_color = "comment"
click_command = "slack.open"

[notifications]
os_notify_on = "error_only"
os_rate_limit_sec = 5

[requires]
env = ["SLACK_TOKEN"]
binary = "mnml-msg-slack"
"#;
        let m: IntegrationManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.id, "slack");
        assert_eq!(m.chip.as_ref().unwrap().glyph, "S");
        assert_eq!(m.commands.len(), 1);
        assert_eq!(m.commands[0].id, "slack.open");
        assert_eq!(m.context_menu.len(), 1);
        assert_eq!(m.statusline.as_ref().unwrap().segment_id, "slack");
        assert_eq!(
            m.notifications.as_ref().unwrap().os_notify_on,
            OsNotifyPolicy::ErrorOnly
        );
        assert_eq!(m.requires.as_ref().unwrap().env, vec!["SLACK_TOKEN"]);
    }

    #[test]
    fn workspace_overrides_user() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("foo.toml")).unwrap();
        writeln!(
            f,
            r#"id = "foo"
name = "Workspace Foo"
binary = "mnml-foo"
"#
        )
        .unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].name, "Workspace Foo");
    }

    #[test]
    fn unknown_chip_color_falls_back() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("foo.toml")).unwrap();
        writeln!(
            f,
            r#"id = "foo"
name = "Foo"
binary = "mnml-foo"

[chip]
glyph = "F"
fallback = "F"
color = "nonsense-neon"
"#
        )
        .unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].chip.as_ref().unwrap().color, "cyan");
    }

    #[test]
    fn drops_manifest_missing_required_id() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("bad.toml")).unwrap();
        writeln!(f, r#"name = "No Id" # missing id"#).unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert!(manifests.is_empty());
    }

    #[test]
    fn is_ready_checks_env_and_binary() {
        // No requires → always ready.
        let m = IntegrationManifest {
            id: "x".into(),
            name: "X".into(),
            description: None,
            version: None,
            binary: "mnml-x".into(),
            category: None,
            chip: None,
            commands: vec![],
            context_menu: vec![],
            menu_bar: vec![],
            statusline: None,
            settings: vec![],
            notifications: None,
            requires: None,
            source_path: PathBuf::new(),
        };
        assert!(m.is_ready());

        // Missing env → not ready.
        let m = IntegrationManifest {
            requires: Some(Requires {
                env: vec!["DEFINITELY_NOT_SET_ENV_12345".to_string()],
                binary: None,
            }),
            ..m
        };
        assert!(!m.is_ready());
    }
}
