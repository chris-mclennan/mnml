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
//!     label: "Slack".into(),
//!     description: Some("Slack browse + post".into()),
//!     version: Some(env!("CARGO_PKG_VERSION").into()),
//!     binary: "mnml-msg-slack".into(),
//!     category: Some("msg".into()),
//!     chip: Some(ChipSpec {
//!         glyph: "\u{F0839}".into(),
//!         fallback: "Sk".into(),
//!         color: "purple".into(),
//!         enabled: true,
//!         in_palette_bar: false,
//!         badge_key: Some("slack".into()),
//!         ..Default::default()
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
/// file. Only `id`, `label`, and `binary` are required —
/// everything else defaults to sensible empty values.
///
/// 2026-08-01 — the identity strings live here at the top level:
///   * `label` — short display name (chip hover, tree row, picker,
///     detail-pane header). Required. ~20 chars max.
///   * `description` — one-sentence longer form for the detail
///     pane subtitle. ~80 chars.
///
/// The old `name` field was dead code (never rendered); dropped.
/// The old `chip.tooltip` field is folded into top-level `label`.
#[derive(Debug, Clone, Default, Serialize)]
pub struct IntegrationSpec {
    pub id: String,
    pub label: String,
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
    /// Auth fields the integration needs configured before its
    /// commands can talk to their backend — tokens, base URLs, an
    /// email, etc. mnml's per-integration Settings pane renders one
    /// form control per entry (secrets are masked as `•••`) and
    /// writes the user's answers back to the manifest TOML under
    /// `[auth_values]`.
    ///
    /// When a command from this integration fires without a required
    /// field set (and its `env_fallback` env var also unset), mnml
    /// intercepts the dispatch and opens the Settings pane instead
    /// of silently failing. Added in 0.7.0 (2026-08-11).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub auth: Vec<AuthField>,
}

/// One user-configurable field the integration needs before it can
/// operate. Declared in `IntegrationSpec::auth`; rendered by mnml's
/// per-integration Settings pane; persisted to `[auth_values]` in
/// the same manifest TOML. Added in 0.7.0 (2026-08-11).
///
/// Example:
///
/// ```
/// use mnml_bridge::AuthField;
/// let f = AuthField {
///     key: "bot_token".into(),
///     label: "Slack bot token".into(),
///     kind: "secret".into(),
///     env_fallback: Some("SLACK_BOT_TOKEN".into()),
///     help_url: Some("https://api.slack.com/apps".into()),
///     help: Some("Create a Slack app + install to workspace + copy the token.".into()),
///     required: true,
/// };
/// # let _ = f;
/// ```
#[derive(Debug, Clone, Default, Serialize)]
pub struct AuthField {
    /// Key the user's answer is written under in `[auth_values]`.
    /// e.g. `"bot_token"`.
    pub key: String,
    /// Human label rendered next to the input.
    pub label: String,
    /// One of `"secret"` (masked in UI, keychain-backed in a future
    /// mnml phase), `"text"`, `"number"`, `"url"`, `"email"`.
    pub kind: String,
    /// Env-var name to fall back to when `[auth_values]` doesn't
    /// have a stored value. Backward-compatibility hatch for
    /// integrations whose users have already set `$SLACK_BOT_TOKEN`
    /// etc. in their shell profile.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env_fallback: Option<String>,
    /// One-line link rendered as "Get one: <url>" under the input.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub help_url: Option<String>,
    /// Short inline help sentence under the label.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
    /// When true, an integration action fired without a value here
    /// AND no env_fallback env var set triggers mnml's first-hit
    /// auth prompt: the Settings pane opens instead of the action.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub required: bool,
}

/// Visual + interaction settings for the sibling's chip. Display
/// strings (label, description) live at `IntegrationSpec` top
/// level, not here — the chip is about rendering, not identity.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ChipSpec {
    pub glyph: String,
    pub fallback: String,
    pub color: String,
    pub enabled: bool,
    pub in_palette_bar: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge_key: Option<String>,
    /// SVG bytes for the integration's icon — typically produced
    /// by `include_bytes!("assets/icons/<id>.svg").to_vec()` at the
    /// integration binary's build time.
    ///
    /// On [`install_integration`], the bytes are written to
    /// `~/.cache/mnml/pending-glyphs/<id>.svg`. mnml bakes any
    /// pending SVGs into `~/Library/Fonts/MnmlSymbols.ttf` at the
    /// next startup and DELETES the pending file so there's no
    /// permanent glyph state under `~/.config/mnml/`. `glyph_codepoint`
    /// (if set) pins the codepoint the integration wants; otherwise
    /// mnml auto-assigns from the `U+F1C00–U+F1CFF` range.
    ///
    /// Never serialized to the manifest TOML — bytes are consumed
    /// at install time and discarded.
    #[serde(skip)]
    #[serde(default)]
    pub glyph_svg_bytes: Option<Vec<u8>>,
    /// Optional explicit codepoint the sibling wants (uppercase
    /// hex, no `U+` prefix — e.g. `"F1C05"`). When set, mnml uses
    /// this codepoint verbatim for the sibling's SVG bake instead
    /// of auto-assigning one from the sibling PUA range
    /// (`U+F1C00–U+F1CFF`). Useful for migration cases where a
    /// sibling wants to keep the codepoint mnml core baked before
    /// this SDK feature landed. Trusted — no range validation
    /// beyond "parses as u32"; the manifest author is expected to
    /// stay inside mnml's PUA layout documented in
    /// `src/icon_catalog.rs`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub glyph_codepoint: Option<String>,
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
/// If `spec.chip.glyph_svg_bytes` is set, writes the bytes to
/// `~/.cache/mnml/pending-glyphs/<id>.svg`. mnml bakes on next
/// startup + deletes the pending file. Nothing persistent under
/// `~/.config/mnml/`.
///
/// Fails if `spec.id` contains `/` or `\` (dir traversal
/// protection), or if the manifest fs write itself fails.
pub fn install_integration(spec: &IntegrationSpec) -> io::Result<PathBuf> {
    validate_id(&spec.id)?;
    let dir = user_integration_dir()?;
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}.toml", spec.id));
    let toml = toml_serialize(spec)?;
    fs::write(&path, toml)?;
    if let Some(chip) = &spec.chip
        && let Some(bytes) = chip.glyph_svg_bytes.as_deref()
    {
        match write_pending_glyph(&spec.id, bytes) {
            Ok(dest) => eprintln!(
                "mnml-bridge: queued glyph → {} (mnml bakes + deletes on next startup)",
                dest.display()
            ),
            Err(e) => eprintln!(
                "mnml-bridge: WARN failed to queue glyph for {}: {e}",
                spec.id
            ),
        }
    }
    Ok(path)
}

/// Dump `bytes` to `~/.cache/mnml/pending-glyphs/<id>.svg`. mnml's
/// startup path bakes these into `MnmlSymbols.ttf`, then deletes
/// the pending file. Nothing lands under `~/.config/mnml/glyphs/`.
fn write_pending_glyph(id: &str, bytes: &[u8]) -> io::Result<PathBuf> {
    validate_id(id)?;
    let dir = pending_glyphs_dir()?;
    fs::create_dir_all(&dir)?;
    let dest = dir.join(format!("{id}.svg"));
    fs::write(&dest, bytes)?;
    Ok(dest)
}

/// `~/.cache/mnml/pending-glyphs/` — handoff location for
/// integration-shipped SVGs. mnml bakes + deletes at startup.
/// Nothing here is expected to persist across a launch cycle.
pub fn pending_glyphs_dir() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "$HOME is not set"))?;
    Ok(PathBuf::from(home)
        .join(".cache")
        .join("mnml")
        .join("pending-glyphs"))
}

/// Delete the manifest at `~/.config/mnml/integrations/<id>.toml`.
/// Returns `Ok(true)` if the file was removed, `Ok(false)` if
/// the file didn't exist (already uninstalled). Fails on other
/// fs errors.
pub fn uninstall_integration(id: &str) -> io::Result<bool> {
    validate_id(id)?;
    let path = integration_manifest_path(id)?;
    // Drop any leftover pending-glyph SVG for this id (rare — the
    // startup auto-purge already deletes baked ones, but a fresh
    // install that hasn't been baked yet would still have the file).
    // The codepoint assignment persists in
    // `~/.config/mnml/integration-glyphs.toml` so re-installing later
    // gets the same codepoint back.
    if let Ok(pending) = pending_glyphs_dir() {
        let _ = fs::remove_file(pending.join(format!("{id}.svg")));
    }
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

    // HOME-mutating tests share a single tempdir path. Rust runs
    // tests in the same process on multiple threads by default, and
    // set_var("HOME", …) leaks across threads — without a mutex,
    // one test's tempdir can shadow another mid-run. Serialize
    // every HOME-touching test through this lock.
    fn home_lock() -> &'static std::sync::Mutex<()> {
        static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
    }

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
            label: "Slack".into(),
            binary: "mnml-msg-slack".into(),
            ..Default::default()
        };
        let toml = toml_serialize(&spec).unwrap();
        assert!(toml.contains("id = \"slack\""));
        assert!(toml.contains("label = \"Slack\""));
        assert!(toml.contains("binary = \"mnml-msg-slack\""));
    }

    #[test]
    fn serializes_full_spec_with_chip_and_commands() {
        let spec = IntegrationSpec {
            id: "slack".into(),
            label: "Slack".into(),
            binary: "mnml-msg-slack".into(),
            chip: Some(ChipSpec {
                glyph: "S".into(),
                fallback: "Sk".into(),
                color: "purple".into(),
                enabled: true,
                in_palette_bar: false,
                badge_key: None,
                glyph_svg_bytes: None,
                glyph_codepoint: None,
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
    fn glyph_codepoint_serializes_when_set() {
        let spec = IntegrationSpec {
            id: "amplify".into(),
            label: "Amplify".into(),
            binary: "mnml-aws-amplify".into(),
            chip: Some(ChipSpec {
                glyph: "\u{F1B00}".into(),
                fallback: "Am".into(),
                color: "purple".into(),
                enabled: true,
                in_palette_bar: false,
                badge_key: None,
                glyph_svg_bytes: None,
                glyph_codepoint: Some("F1B00".into()),
            }),
            ..Default::default()
        };
        let toml = toml_serialize(&spec).unwrap();
        assert!(toml.contains("glyph_codepoint = \"F1B00\""));
        // glyph_svg_bytes is #[serde(skip)] — must not appear in TOML.
        assert!(!toml.contains("glyph_svg_bytes"));
    }

    #[test]
    fn install_writes_glyph_bytes_to_pending_dir() {
        let _lk = home_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("HOME", tmp.path()) };

        let spec = IntegrationSpec {
            id: "amplify".into(),
            label: "Amplify".into(),
            binary: "mnml-aws-amplify".into(),
            chip: Some(ChipSpec {
                glyph: "A".into(),
                fallback: "Am".into(),
                color: "purple".into(),
                enabled: true,
                in_palette_bar: false,
                badge_key: None,
                glyph_svg_bytes: Some(b"<svg/>".to_vec()),
                glyph_codepoint: Some("F1B00".into()),
            }),
            ..Default::default()
        };
        install_integration(&spec).unwrap();

        let dest = pending_glyphs_dir().unwrap().join("amplify.svg");
        assert!(dest.exists(), "glyph SVG bytes should land at {dest:?}");
        assert_eq!(fs::read(&dest).unwrap(), b"<svg/>");
        // Uninstall removes the pending SVG alongside the manifest.
        uninstall_integration("amplify").unwrap();
        assert!(
            !dest.exists(),
            "pending glyph SVG should be removed on uninstall"
        );
    }

    #[test]
    fn install_survives_missing_glyph_svg_source() {
        let _lk = home_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("HOME", tmp.path()) };

        let spec = IntegrationSpec {
            id: "broken".into(),
            label: "Broken".into(),
            binary: "mnml-broken".into(),
            chip: Some(ChipSpec {
                glyph: "B".into(),
                fallback: "Br".into(),
                color: "red".into(),
                enabled: true,
                in_palette_bar: false,
                badge_key: None,
                glyph_svg_bytes: None,
                glyph_codepoint: None,
            }),
            ..Default::default()
        };
        // A chip with no glyph_svg_bytes is fine — the manifest
        // still gets written so `--install` succeeds even when the
        // sibling packager forgot to bundle the SVG.
        install_integration(&spec).unwrap();
        let manifest = integration_manifest_path("broken").unwrap();
        assert!(manifest.exists());
    }

    #[test]
    fn install_and_uninstall_round_trip() {
        // Redirect HOME to a tempdir so we don't scribble in the
        // real user config.
        let _lk = home_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("HOME", tmp.path()) };

        let spec = IntegrationSpec {
            id: "roundtrip".into(),
            label: "Round Trip".into(),
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
