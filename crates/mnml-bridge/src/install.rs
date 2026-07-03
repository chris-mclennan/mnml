//! Integration manifest install helpers — sibling-authored
//! self-registration for the rail chip, palette commands, chord
//! bindings, context menu additions, menu-bar entries,
//! statusline segments, settings pages, and OS notification
//! policy. Writes a single TOML file per integration:
//!
//!   `~/.config/mnml/integrations/<id>.toml`
//!
//! mnml picks the file up on startup + on the
//! `integrations.refresh` palette command. Uninstall = delete
//! the file. No IPC required — the fs is the interface.
//!
//! ```no_run
//! use mnml_bridge::install::{
//!     ChipSpec, CommandSpec, IntegrationSpec, install_integration,
//! };
//!
//! install_integration(&IntegrationSpec {
//!     id: "slack".into(),
//!     name: "Slack".into(),
//!     description: Some("Slack browse + post".into()),
//!     version: Some(env!("CARGO_PKG_VERSION").into()),
//!     binary: "mnml-msg-slack".into(),
//!     category: Some("msg".into()),
//!     chip: Some(ChipSpec {
//!         glyph: "\u{F0839}".into(),
//!         fallback: "Sk".into(),
//!         color: "purple".into(),
//!         tooltip: Some("Slack".into()),
//!         enabled: true,
//!         in_palette_bar: false,
//!         badge_key: Some("slack".into()),
//!     }),
//!     commands: vec![CommandSpec {
//!         id: "slack.open".into(),
//!         title: "Slack: open".into(),
//!         group: Some("integrations".into()),
//!         keys: vec!["<leader>iS".into()],
//!         run: ":term mnml-msg-slack".into(),
//!     }],
//!     ..Default::default()
//! }).ok();
//! ```

use serde::Serialize;
use std::fs;
use std::io;
use std::path::PathBuf;

/// Complete integration description written to the manifest
/// file. Only `id`, `name`, and `binary` are required — everything
/// else defaults to sensible empty values.
#[derive(Debug, Clone, Default, Serialize)]
pub struct IntegrationSpec {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub binary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub chip: Option<ChipSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub commands: Vec<CommandSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub context_menu: Vec<ContextMenuEntry>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub menu_bar: Vec<MenuBarEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub statusline: Option<StatuslineSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub settings: Vec<SettingsPage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notifications: Option<NotificationsSpec>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requires: Option<Requires>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChipSpec {
    pub glyph: String,
    pub fallback: String,
    pub color: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tooltip: Option<String>,
    pub enabled: bool,
    pub in_palette_bar: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge_key: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CommandSpec {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keys: Vec<String>,
    pub run: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ContextMenuEntry {
    /// `tree.file` | `tree.dir` | `tab` | `agent.row` | `pane`.
    pub target: String,
    pub title: String,
    pub command: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MenuBarEntry {
    /// Slash-separated path like `"File > Send via Slack"`.
    pub path: String,
    pub command: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct StatuslineSpec {
    /// `"left"` | `"right"`.
    pub side: String,
    pub segment_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub initial_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initial_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub click_command: Option<String>,
    pub priority: u8,
    pub min_width: u16,
    pub max_width: u16,
}

#[derive(Debug, Clone, Serialize)]
pub struct SettingsPage {
    pub section: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OsNotifyPolicy {
    #[default]
    Never,
    ErrorOnly,
    Always,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotificationsSpec {
    pub os_notify_on: OsNotifyPolicy,
    pub os_rate_limit_sec: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Requires {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binary: Option<String>,
}

// ── Filesystem operations ─────────────────────────────

/// Serialize `spec` and write to
/// `~/.config/mnml/integrations/<id>.toml`. Creates the parent
/// directory if needed. Overwrites any existing file with the
/// same id. Returns the path written.
///
/// Fails if `spec.id` contains `/` or `\` (dir traversal
/// protection), or if the fs operation itself fails.
pub fn install_integration(spec: &IntegrationSpec) -> io::Result<PathBuf> {
    validate_id(&spec.id)?;
    let dir = user_integration_dir()?;
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}.toml", spec.id));
    let toml = toml_serialize(spec)?;
    fs::write(&path, toml)?;
    Ok(path)
}

/// Delete the manifest at `~/.config/mnml/integrations/<id>.toml`.
/// Returns `Ok(true)` if the file was removed, `Ok(false)` if
/// the file didn't exist (already uninstalled). Fails on other
/// fs errors.
pub fn uninstall_integration(id: &str) -> io::Result<bool> {
    validate_id(id)?;
    let path = integration_manifest_path(id)?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// List installed integrations by id — reads the manifest
/// directory + strips the `.toml` suffix. Returns an empty vec
/// if the dir doesn't exist.
pub fn list_installed_integrations() -> io::Result<Vec<String>> {
    let dir = user_integration_dir()?;
    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut out: Vec<String> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if let Some(id) = name.strip_suffix(".toml")
            && !id.is_empty()
        {
            out.push(id.to_string());
        }
    }
    out.sort();
    Ok(out)
}

/// Path to a specific integration's manifest file. Doesn't check
/// whether the file exists.
pub fn integration_manifest_path(id: &str) -> io::Result<PathBuf> {
    validate_id(id)?;
    Ok(user_integration_dir()?.join(format!("{id}.toml")))
}

fn user_integration_dir() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "$HOME is not set"))?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("mnml")
        .join("integrations"))
}

fn validate_id(id: &str) -> io::Result<()> {
    if id.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "id is empty"));
    }
    if id.contains(['/', '\\', '\0']) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("id contains path characters: {id}"),
        ));
    }
    Ok(())
}

fn toml_serialize<T: Serialize>(v: &T) -> io::Result<String> {
    // Use serde_json → toml conversion since we don't ship the
    // toml crate as a dep (keeps mnml-bridge's dep tree tight).
    // Instead: format the manifest by hand for the common shape.
    // For fidelity, we use serde_json and let the reader (mnml)
    // parse the TOML directly. But since we're WRITING TOML, we
    // need actual TOML serialization.
    //
    // The simplest path: use serde_json to reflect the struct,
    // then hand-convert to TOML. Given the flat + list shape of
    // IntegrationSpec, this is straightforward.
    let json = serde_json::to_value(v)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("serialize: {e}")))?;
    Ok(json_to_toml(&json))
}

/// Best-effort JSON → TOML for the IntegrationSpec shape.
/// Handles top-level scalar fields + nested tables +
/// arrays-of-tables. Not a general JSON→TOML converter — but
/// sufficient for the shapes this SDK emits.
fn json_to_toml(v: &serde_json::Value) -> String {
    let mut out = String::new();
    let Some(map) = v.as_object() else {
        return out;
    };
    // Emit top-level scalars first.
    for (k, val) in map {
        if val.is_object() || val.is_array() {
            continue;
        }
        push_kv(&mut out, k, val);
    }
    // Then arrays-of-tables and tables.
    for (k, val) in map {
        match val {
            serde_json::Value::Object(_) => {
                out.push_str(&format!("\n[{k}]\n"));
                for (inner_k, inner_v) in val.as_object().unwrap() {
                    if inner_v.is_object() || inner_v.is_array() {
                        continue;
                    }
                    push_kv(&mut out, inner_k, inner_v);
                }
            }
            serde_json::Value::Array(arr) => {
                for item in arr {
                    if let Some(obj) = item.as_object() {
                        out.push_str(&format!("\n[[{k}]]\n"));
                        for (inner_k, inner_v) in obj {
                            push_kv(&mut out, inner_k, inner_v);
                        }
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn push_kv(out: &mut String, k: &str, v: &serde_json::Value) {
    match v {
        serde_json::Value::String(s) => {
            out.push_str(&format!("{k} = {}\n", toml_str(s)));
        }
        serde_json::Value::Number(n) => {
            out.push_str(&format!("{k} = {n}\n"));
        }
        serde_json::Value::Bool(b) => {
            out.push_str(&format!("{k} = {b}\n"));
        }
        serde_json::Value::Array(arr) => {
            let items: Vec<String> = arr
                .iter()
                .filter_map(|x| x.as_str().map(toml_str))
                .collect();
            out.push_str(&format!("{k} = [{}]\n", items.join(", ")));
        }
        _ => {}
    }
}

fn toml_str(s: &str) -> String {
    // Basic TOML string escape — quote + escape backslash + quote.
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_id_rejects_dangerous_chars() {
        assert!(validate_id("").is_err());
        assert!(validate_id("../foo").is_err());
        assert!(validate_id("a/b").is_err());
        assert!(validate_id("a\\b").is_err());
        assert!(validate_id("valid_id-123").is_ok());
    }

    #[test]
    fn serializes_minimal_spec_to_toml() {
        let spec = IntegrationSpec {
            id: "slack".into(),
            name: "Slack".into(),
            binary: "mnml-msg-slack".into(),
            ..Default::default()
        };
        let toml = toml_serialize(&spec).unwrap();
        assert!(toml.contains("id = \"slack\""));
        assert!(toml.contains("name = \"Slack\""));
        assert!(toml.contains("binary = \"mnml-msg-slack\""));
    }

    #[test]
    fn serializes_full_spec_with_chip_and_commands() {
        let spec = IntegrationSpec {
            id: "slack".into(),
            name: "Slack".into(),
            binary: "mnml-msg-slack".into(),
            chip: Some(ChipSpec {
                glyph: "S".into(),
                fallback: "Sk".into(),
                color: "purple".into(),
                tooltip: None,
                enabled: true,
                in_palette_bar: false,
                badge_key: None,
            }),
            commands: vec![CommandSpec {
                id: "slack.open".into(),
                title: "Slack: open".into(),
                group: Some("integrations".into()),
                keys: vec!["<leader>iS".into()],
                run: ":term mnml-msg-slack".into(),
            }],
            ..Default::default()
        };
        let toml = toml_serialize(&spec).unwrap();
        assert!(toml.contains("[chip]"));
        assert!(toml.contains("glyph = \"S\""));
        assert!(toml.contains("[[commands]]"));
        assert!(toml.contains("id = \"slack.open\""));
        assert!(toml.contains("keys = [\"<leader>iS\"]"));
    }

    #[test]
    fn install_and_uninstall_round_trip() {
        // Redirect HOME to a tempdir so we don't scribble in the
        // real user config.
        let tmp = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("HOME", tmp.path()) };

        let spec = IntegrationSpec {
            id: "roundtrip".into(),
            name: "Round Trip".into(),
            binary: "mnml-rt".into(),
            ..Default::default()
        };
        let p = install_integration(&spec).unwrap();
        assert!(p.exists());
        assert_eq!(p.file_name().unwrap(), "roundtrip.toml");

        let ids = list_installed_integrations().unwrap();
        assert!(ids.contains(&"roundtrip".to_string()));

        let removed = uninstall_integration("roundtrip").unwrap();
        assert!(removed);
        assert!(!p.exists());

        // Second uninstall is a no-op (already gone).
        let removed2 = uninstall_integration("roundtrip").unwrap();
        assert!(!removed2);
    }
}
