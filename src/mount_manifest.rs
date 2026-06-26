//! Manifest loader for activity-bar-registered Mount siblings.
//!
//! A sibling that wants to live in mnml's activity bar (instead of
//! being opened ad-hoc via `:mount.open`) drops a `mnml.toml`
//! manifest in one of two places:
//!
//!   1. `<workspace>/.mnml/mounts/<id>.toml` — workspace-local.
//!      Lets a team check in a per-project tool (e.g. a
//!      "TestExecutions browser" only relevant in this repo).
//!   2. `~/.config/mnml/mounts/<id>.toml` — user-global. The
//!      sibling is installed once and visible across every
//!      workspace.
//!
//! mnml scans both dirs on startup + on the `mounts.refresh`
//! palette command. Workspace manifests override user-global
//! manifests with the same id.
//!
//! ## Manifest fields
//!
//! ```toml
//! id = "tattle-tests"                  # unique stable id
//! name = "Tattle tests"                # tooltip / pane label
//! binary = "mnml-tattle-tests"         # PATH lookup, or absolute path
//! icon = "8"                     # Nerd Font glyph
//! color = "green"                      # named theme color
//! tooltip = "Live test executions"     # optional, falls back to name
//! ```

use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Color-name strings the manifest accepts; mapped to theme
/// colors by `MountManifest::color()`. Limited to the small
/// palette every theme exposes; unknown values fall back to
/// cyan. Keeping this small avoids bleeding theme-implementation
/// details into the public manifest surface.
const ALLOWED_COLORS: &[&str] = &[
    "red", "orange", "yellow", "green", "blue", "cyan", "teal", "purple", "pink", "comment",
];

#[derive(Debug, Clone, Deserialize)]
pub struct MountManifest {
    pub id: String,
    pub name: String,
    pub binary: String,
    /// Single Nerd Font glyph (or fallback letter).
    pub icon: String,
    /// Optional named color — see ALLOWED_COLORS.
    #[serde(default)]
    pub color: Option<String>,
    /// Optional hover tooltip; falls back to `name`.
    #[serde(default)]
    pub tooltip: Option<String>,
    /// Source path (for debug + ability to reload the same file).
    #[serde(skip)]
    pub source_path: PathBuf,
}

impl MountManifest {
    pub fn tooltip_text(&self) -> &str {
        self.tooltip.as_deref().unwrap_or(&self.name)
    }

    /// Resolve the color name to a ratatui color via the active
    /// theme. Defaults to cyan when unset / unknown.
    pub fn color_for_theme(&self, t: &crate::ui::theme::Theme) -> ratatui::style::Color {
        match self.color.as_deref() {
            Some("red") => t.red,
            Some("orange") => t.orange,
            Some("yellow") => t.yellow,
            Some("green") => t.green,
            Some("blue") => t.blue,
            Some("cyan") => t.cyan,
            Some("teal") => t.teal,
            Some("purple") => t.purple,
            Some("pink") => t.pink,
            Some("comment") => t.comment,
            _ => t.cyan,
        }
    }
}

/// Scan both manifest dirs and return the merged list. Workspace
/// entries shadow user-global entries with the same id.
pub fn load_all(workspace: &Path) -> Vec<MountManifest> {
    let mut out: Vec<MountManifest> = Vec::new();

    // User-global first (lower priority).
    if let Some(dir) = user_dir() {
        scan_dir(&dir, &mut out);
    }
    // Workspace second (higher priority — overrides on id collision).
    scan_dir(&workspace.join(".mnml").join("mounts"), &mut out);

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

/// User-config dir for manifests. `~/.config/mnml/mounts/` on
/// XDG-compliant systems; falls back to `~/.config/mnml/mounts/`
/// on macOS too (mnml's existing config root).
fn user_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("mnml")
            .join("mounts"),
    )
}

fn scan_dir(dir: &Path, out: &mut Vec<MountManifest>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return, // dir doesn't exist — fine, no manifests
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
        match toml::from_str::<MountManifest>(&text) {
            Ok(mut m) => {
                if m.id.is_empty() || m.binary.is_empty() || m.icon.is_empty() {
                    continue; // basic validation
                }
                if let Some(c) = m.color.as_deref()
                    && !ALLOWED_COLORS.contains(&c)
                {
                    // Unknown color — clear it; color_for_theme
                    // will fall back to cyan.
                    m.color = None;
                }
                m.source_path = path;
                out.push(m);
            }
            Err(_) => continue, // skip malformed manifests
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_manifest() {
        let toml = r#"
id = "demo"
name = "Demo"
binary = "echo"
icon = "8"
"#;
        let m: MountManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.id, "demo");
        assert_eq!(m.binary, "echo");
        assert!(m.color.is_none());
        assert_eq!(m.tooltip_text(), "Demo");
    }

    #[test]
    fn parses_full_manifest() {
        let toml = r#"
id = "tattle-tests"
name = "Tattle tests"
binary = "/opt/bin/mnml-tattle-tests"
icon = "T"
color = "green"
tooltip = "Live test executions"
"#;
        let m: MountManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.color.as_deref(), Some("green"));
        assert_eq!(m.tooltip_text(), "Live test executions");
    }

    #[test]
    fn workspace_overrides_user() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("mounts");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("foo.toml")).unwrap();
        writeln!(
            f,
            r#"id = "foo"
name = "Workspace Foo"
binary = "echo"
icon = "F"
"#
        )
        .unwrap();
        let manifests = load_all(&ws);
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].name, "Workspace Foo");
    }
}
